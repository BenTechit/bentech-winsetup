# tests/Vendor.Tests.ps1
# Task 13: vendor driver/BIOS passes (Dell Command Update, Lenovo System Update, HP Image Assistant), the
# vendor's consumer app, and removal of the business updater.
#
# SAFETY: this runs on Ben's ThinkPad. The code under test installs and runs vendor updaters that can
# flash a BIOS, writes the Lenovo System Update policy, suspends BitLocker, kills processes and starts
# services. NOTHING here may do any of that, and nothing here may run tvsu, dcu-cli, HPIA or winget.
# Every test that reaches a system command runs after Initialize-VendorMocks (each Describe calls it from
# BeforeEach), which replaces EVERY command the steps can reach with a recorder:
#   Invoke-External, Invoke-WingetInstall, Invoke-WingetUninstall, Get-RemoteFile, Get-RemoteText,
#   Test-FileSignature, Wait-BitLockerDecrypted, Suspend-BitLockerOnce, Test-OnACPower, Test-Path,
#   New-Item, New-ItemProperty, Get-ItemProperty, Remove-ItemProperty, Remove-Item, Copy-Item,
#   Get-Process, Stop-Process, Start-Service, Get-Service, Get-CimInstance, Start-Sleep and Write-SetupLog.
# The only real file I/O is the placeholder "download" the Get-RemoteFile mock writes inside $TestDrive.
# The pure functions (exit-code mappers, argument builders, the cleanup rule, the Lenovo record
# conversion) need no mocks; the CimInstance used there is built in memory, without any WMI call.
BeforeAll {
  . "$PSScriptRoot\..\src\Steps\Vendor.ps1"
  foreach ($f in 'StepResult', 'Logging', 'Process', 'Download', 'Config') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
  . "$PSScriptRoot\..\src\Detect\Detection.ps1"
  foreach ($f in 'Winget', 'BitLocker') { . "$PSScriptRoot\..\src\Steps\$f.ps1" }

  # The config text is read once here: the steps get a fresh object per test (New-VendorContext), so a
  # test can change a timeout or a tool entry without touching the others.
  $script:ConfigJson = [IO.File]::ReadAllText("$PSScriptRoot\..\config\config.json", [Text.Encoding]::UTF8)
  $script:HpiaHtml = [IO.File]::ReadAllText("$PSScriptRoot\fixtures\hpia.html", [Text.Encoding]::UTF8)
  # The policy goes into both registry views (ruling R19): tvsu.exe is 32-bit.
  $script:LenovoPolicyKey = 'HKLM:\SOFTWARE\Policies\Lenovo\System Update\UserSettings\General'
  $script:LenovoWowPolicyKey = 'HKLM:\SOFTWARE\WOW6432Node\Policies\Lenovo\System Update\UserSettings\General'

  function New-VendorContext {
    param([string]$Brand = 'DELL', [string]$Mode = 'LAPTOP')
    $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    @{
      Config      = ($script:ConfigJson | ConvertFrom-Json)
      State       = @{
        Machine     = @{ Brand = $Brand; Arch = 'x64' }
        Choices     = @{ Mode = $Mode; SevenZip = $true; Office = 'OFF' }
        Steps       = @{}
        RebootCount = 0
      }
      Root        = $dir
      LogDir      = (Join-Path $dir 'Logs')
      DownloadDir = (Join-Path $dir 'Downloads')
      ScriptPath  = (Join-Path $dir 'setup.ps1')
      StatePath   = (Join-Path $dir 'state.json')
    }
  }

  function New-FakeProcess {
    param([int]$Id, [string]$Name)
    [pscustomobject]@{ Id = $Id; Name = $Name }
  }

  # A Lenovo_Updates record as Get-CimInstance would return it, built in memory (no WMI call).
  function New-FakeLenovoUpdate {
    param([string]$Status)
    $ci = [Microsoft.Management.Infrastructure.CimInstance]::new('Lenovo_Updates', 'root\Lenovo')
    $ci.CimInstanceProperties.Add([Microsoft.Management.Infrastructure.CimProperty]::Create('Status', $Status, [Microsoft.Management.Infrastructure.CimFlags]::None))
    return $ci
  }

  # Turns every command the steps can reach into a recorder. Call from BeforeEach.
  #   $script:order          the names of the gate/tool commands, in the order they were called
  #   $script:logs           one hashtable per Write-SetupLog call
  #   $script:sleeps         one hashtable per Start-Sleep call (Seconds, Milliseconds)
  #   $script:ext            one hashtable per Invoke-External call; $script:extHandler answers it
  #   $script:existing       the paths Test-Path answers $true for (files, folders, registry keys)
  #   $script:downloads      one hashtable per Get-RemoteFile call; a placeholder file is created at Destination
  #   $script:sigCalls       one hashtable per Test-FileSignature call; $script:sigBad lists the file names that fail
  #   $script:wingetCalls    one hashtable per Invoke-WingetInstall call; $script:wingetResult is its answer and
  #                          $script:wingetInstalls the paths that exist once it has run
  #   $script:uninstallCalls one id per Invoke-WingetUninstall call; $script:uninstallResult is its answer
  #   $script:waitCalls      one TimeoutMinutes per Wait-BitLockerDecrypted call
  #   $script:onAC           what Test-OnACPower answers; $script:onACSeq, when set, answers call by call
  #                          (the last one repeats); $script:acCalls counts the calls
  #   $script:regWriteThrowsFor / $script:regRemoveThrowsFor   registry paths whose write / removal throws
  #   $script:regKeys / $script:regValues / $script:regRemoved   New-Item paths / New-ItemProperty / Remove-ItemProperty calls
  #   $script:regPresent     registry path -> hashtable of values for Get-ItemProperty
  #   $script:procPolls      Get-Process calls so far; it reports $script:procList while procPolls <= $script:procRunningPolls
  #   $script:stopped        the ids Stop-Process was called for
  #   $script:copies         one hashtable per Copy-Item call
  #   $script:cimCalls       one hashtable per Get-CimInstance call; $script:lenovoRecords is its answer
  #   $script:serviceStarts  one name per Start-Service call (must stay empty)
  #   $script:svc*           the fake Dell service behind Get-Service (see the mock)
  #   $script:removed        one path per Remove-Item call
  function Initialize-VendorMocks {
    $script:order = New-Object System.Collections.ArrayList
    $script:logs = New-Object System.Collections.ArrayList
    $script:sleeps = New-Object System.Collections.ArrayList
    $script:ext = New-Object System.Collections.ArrayList
    $script:extHandler = { param($c) @{ ExitCode = 0; TimedOut = $false; Output = '' } }
    $script:existing = @()
    $script:downloads = New-Object System.Collections.ArrayList
    $script:downloadError = $null
    $script:pageHtml = ''
    $script:pageError = $null
    $script:pageCalls = New-Object System.Collections.ArrayList
    $script:sigCalls = New-Object System.Collections.ArrayList
    $script:sigBad = @()
    $script:wingetCalls = New-Object System.Collections.ArrayList
    $script:wingetResult = New-StepResult -Status Done -Message 'x: installed'
    $script:wingetInstalls = @()
    $script:uninstallCalls = New-Object System.Collections.ArrayList
    $script:uninstallResult = New-StepResult -Status Done -Message 'x: uninstalled'
    $script:bitlockerDecrypted = $true
    $script:suspendOk = $true
    $script:onAC = $true
    $script:onACSeq = $null
    $script:acCalls = 0
    $script:waitCalls = New-Object System.Collections.ArrayList
    $script:regKeys = New-Object System.Collections.ArrayList
    $script:regValues = New-Object System.Collections.ArrayList
    $script:regWriteThrows = $false
    $script:regWriteThrowsFor = @()
    $script:regRemoved = New-Object System.Collections.ArrayList
    $script:regRemoveThrows = $false
    $script:regRemoveThrowsFor = @()
    $script:regPresent = @{}
    $script:procPolls = 0
    $script:procRunningPolls = 0
    $script:procList = @((New-FakeProcess -Id 4101 -Name 'tvsu'), (New-FakeProcess -Id 4102 -Name 'Tvsukernel'))
    $script:procNames = New-Object System.Collections.ArrayList
    $script:stopped = New-Object System.Collections.ArrayList
    $script:copies = New-Object System.Collections.ArrayList
    $script:copyThrows = $false
    $script:cimCalls = New-Object System.Collections.ArrayList
    $script:cimThrows = $false
    $script:lenovoRecords = @()
    $script:serviceStarts = New-Object System.Collections.ArrayList
    $script:svcNames = New-Object System.Collections.ArrayList
    $script:svcStatus = 'Stopped'
    $script:svcStarts = 0
    $script:svcStartThrows = $false
    $script:svcWaits = New-Object System.Collections.ArrayList
    $script:svcWaitThrows = $false
    $script:svcGetThrows = $false
    $script:removed = New-Object System.Collections.ArrayList

    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    Mock Start-Sleep { [void]$script:sleeps.Add(@{ Seconds = $Seconds; Milliseconds = $Milliseconds }) }
    Mock Test-Path { return ($script:existing -contains $LiteralPath) }
    Mock Invoke-External {
      [void]$script:order.Add('Invoke-External')
      $call = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes; CaptureOutput = [bool]$CaptureOutput }
      [void]$script:ext.Add($call)
      & $script:extHandler $call
    }
    Mock Get-RemoteFile {
      [void]$script:downloads.Add(@{ Url = $Url; Destination = $Destination })
      if ($script:downloadError) { throw $script:downloadError }
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
      [IO.File]::WriteAllText($Destination, 'placeholder')
      return $Destination
    }
    Mock Get-RemoteText {
      [void]$script:pageCalls.Add($Url)
      if ($script:pageError) { throw $script:pageError }
      return $script:pageHtml
    }
    Mock Test-FileSignature {
      [void]$script:sigCalls.Add(@{ Path = $Path; Signers = @($AllowedSigners) })
      return (-not ($script:sigBad -contains (Split-Path -Leaf $Path)))
    }
    Mock Invoke-WingetInstall {
      [void]$script:order.Add('Invoke-WingetInstall')
      [void]$script:wingetCalls.Add(@{ Id = $Id; Source = $Source })
      $script:existing += $script:wingetInstalls
      return $script:wingetResult
    }
    Mock Invoke-WingetUninstall {
      [void]$script:uninstallCalls.Add($Id)
      return $script:uninstallResult
    }
    Mock Wait-BitLockerDecrypted {
      [void]$script:order.Add('Wait-BitLockerDecrypted')
      [void]$script:waitCalls.Add($TimeoutMinutes)
      return $script:bitlockerDecrypted
    }
    Mock Suspend-BitLockerOnce { [void]$script:order.Add('Suspend-BitLockerOnce'); return $script:suspendOk }
    Mock Test-OnACPower {
      [void]$script:order.Add('Test-OnACPower')
      $script:acCalls++
      if ($null -ne $script:onACSeq) { return [bool]$script:onACSeq[[Math]::Min($script:acCalls - 1, $script:onACSeq.Count - 1)] }
      return $script:onAC
    }
    Mock New-Item { [void]$script:regKeys.Add([string]$Path); $script:existing += [string]$Path }
    Mock New-ItemProperty {
      # Write-Error, not throw: the registry provider reports a refusal as a non-terminating error (I1).
      if ($script:regWriteThrows -or ($script:regWriteThrowsFor -contains [string]$LiteralPath)) { Write-Error -Message 'Requested registry access is not allowed' -Category PermissionDenied; return }
      [void]$script:regValues.Add(@{ Path = [string]$LiteralPath; Name = $Name; Value = $Value; Type = [string]$PropertyType })
      # What was written is there to read back (and to remove) afterwards.
      if ($null -eq $script:regPresent[[string]$LiteralPath]) { $script:regPresent[[string]$LiteralPath] = @{} }
      $script:regPresent[[string]$LiteralPath][$Name] = $Value
    }
    Mock Get-ItemProperty {
      $values = $script:regPresent[[string]$LiteralPath]
      if ($null -eq $values) { return $null }
      return [pscustomobject]$values
    }
    Mock Remove-ItemProperty {
      if ($script:regRemoveThrows -or ($script:regRemoveThrowsFor -contains [string]$LiteralPath)) { Write-Error -Message 'Requested registry access is not allowed' -Category PermissionDenied; return }
      [void]$script:order.Add('Remove-ItemProperty')
      [void]$script:regRemoved.Add(@{ Path = [string]$LiteralPath; Name = @($Name) })
      $values = $script:regPresent[[string]$LiteralPath]
      if ($null -ne $values) {
        foreach ($n in @($Name)) { $values.Remove($n) }
        if ($values.Count -eq 0) { $script:regPresent.Remove([string]$LiteralPath) }
      }
    }
    Mock Remove-Item { [void]$script:removed.Add([string]$LiteralPath) }
    Mock Copy-Item {
      if ($script:copyThrows) { Write-Error -Message 'The process cannot access the file' -Category WriteError; return }
      [void]$script:copies.Add(@{ Path = @($Path); Destination = [string]$Destination })
    }
    Mock Get-Process {
      [void]$script:order.Add('Get-Process')
      [void]$script:procNames.Add(@($Name))
      $script:procPolls++
      if ($script:procPolls -le $script:procRunningPolls) { return $script:procList }
    }
    Mock Stop-Process { foreach ($i in @($Id)) { [void]$script:stopped.Add($i) } }
    Mock Get-CimInstance {
      [void]$script:cimCalls.Add(@{ Namespace = $Namespace; ClassName = $ClassName; OperationTimeoutSec = $OperationTimeoutSec })
      if ($script:cimThrows) { throw 'Invalid namespace' }
      return $script:lenovoRecords
    }
    # Start-Service must never be used (it can wait forever on a StartPending service); this mock only
    # records, so a test can assert it was not called.
    Mock Start-Service { [void]$script:serviceStarts.Add([string]$Name) }
    # A fake ServiceController: Status from $script:svcStatus; Start() and WaitForStatus() are recorded,
    # and WaitForStatus throws (as the real one does when its time runs out) when $script:svcWaitThrows.
    Mock Get-Service {
      [void]$script:svcNames.Add([string]$Name)
      if ($script:svcGetThrows) { throw "Cannot find any service with service name '$Name'." }
      $service = [pscustomobject]@{ Name = [string]$Name; Status = $script:svcStatus }
      $service | Add-Member -MemberType ScriptMethod -Name Start -Value {
        $script:svcStarts++
        if ($script:svcStartThrows) { throw 'Cannot start service.' }
      }
      $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($Desired, $Timeout)
        [void]$script:svcWaits.Add(@{ Status = [string]$Desired; Timeout = $Timeout })
        if ($script:svcWaitThrows) { throw 'Time out has expired and the operation has not been completed.' }
      }
      return $service
    }
  }

  # Ext handler for one tool run: $script:toolCodes holds one answer per run (an exit code or 'timeout');
  # the last one repeats. Calls whose ArgumentList matches $script:otherPattern get $script:otherCode.
  function Set-ToolCodes {
    param([object[]]$Codes, [string]$OtherPattern = '^$', $OtherCode = 0)
    $script:toolCodes = $Codes
    $script:toolRuns = 0
    $script:otherPattern = $OtherPattern
    $script:otherCode = $OtherCode
    $script:extHandler = {
      param($c)
      if ([string]$c.ArgumentList -match $script:otherPattern) {
        if ($script:otherCode -is [string] -and $script:otherCode -eq 'timeout') { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
        if ($script:otherCode -is [string] -and $script:otherCode -eq 'throw') { throw 'Cannot start the program' }
        return @{ ExitCode = $script:otherCode; TimedOut = $false; Output = '' }
      }
      $i = [Math]::Min($script:toolRuns, $script:toolCodes.Count - 1)
      $script:toolRuns++
      $code = $script:toolCodes[$i]
      if ($code -is [string] -and $code -eq 'timeout') { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
      if ($code -is [string] -and $code -eq 'throw') { throw 'Cannot start the program' }
      return @{ ExitCode = $code; TimedOut = $false; Output = '' }
    }
  }

  function Get-ToolRuns {
    # The Invoke-External calls that are tool runs (not the DCU /configure or the HPIA extract).
    @($script:ext | Where-Object { [string]$_.ArgumentList -notmatch $script:otherPattern })
  }
}

# --- the brief's own tests (verbatim) ---------------------------------------------------------
Describe 'exit codes' {
  It 'DCU <c> -> <r>' -ForEach @(@{c=0;r='Done'},@{c=500;r='Done'},@{c=1;r='DoneReboot'},@{c=5;r='DoneReboot'},@{c=3;r='Skipped'},@{c=7;r='Skipped'},@{c=3001;r='RetryService'},@{c=2;r='Failed'}) { Convert-DcuExitCode -ExitCode $c | Should -Be $r }
  It 'HPIA <c> -> <r>' -ForEach @(@{c=0;r='Done'},@{c=256;r='Done'},@{c=257;r='Done'},@{c=3010;r='DoneReboot'},@{c=3011;r='DoneWarning'},@{c=3020;r='Failed'},@{c=4096;r='Skipped'},@{c=4098;r='Retry'},@{c=8192;r='Failed'}) { Convert-HpiaExitCode -ExitCode $c | Should -Be $r }
}
Describe 'battery never flashes BIOS/firmware' {
  It 'DCU on AC has no filter' { Get-DcuApplyArgs -LogPath 'C:\L\d.log' -OnAC $true | Should -Be '/applyUpdates -silent -reboot=disable -outputLog="C:\L\d.log"' }
  It 'DCU on battery excludes bios/firmware' { $a = Get-DcuApplyArgs -LogPath 'C:\L\d.log' -OnAC $false; $a | Should -Match '-updateType=driver,application,others'; $a | Should -Not -Match 'bios|firmware' }
  It 'HPIA on battery' { $a = Get-HpiaArgs -ReportFolder 'C:\r' -DownloadFolder 'C:\d' -OnAC $false; $a | Should -Match '/Category:Drivers,Software'; $a | Should -Not -Match 'Category:All' }
  It 'Lenovo on battery drops type 5' { Get-LenovoAdminCommandLine -OnAC $false | Should -Match '-includerebootpackages 1,3 ' }
  It 'Lenovo on AC never includes type 4 (shutdown)' { Get-LenovoAdminCommandLine -OnAC $true | Should -Match '-includerebootpackages 1,3,5 ' }
}
Describe 'cleanup rule' {
  It 'laptop + Dell + app installed' { Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand DELL -ConsumerAppStatus Done | Should -BeTrue }
  It 'keeps the tool when the app was skipped' { Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand DELL -ConsumerAppStatus Skipped | Should -BeFalse }
  It 'keeps it on desktops' { Test-ShouldRemoveBusinessTool -Mode DESKTOP -Brand HP -ConsumerAppStatus Done | Should -BeFalse }
}

# --- pure helpers -----------------------------------------------------------------------------
Describe 'exit-code edge cases' {
  It 'DCU maps every service code 3000-3005 to RetryService' {
    foreach ($c in 3000..3005) { Convert-DcuExitCode -ExitCode $c | Should -Be 'RetryService' }
  }
  It 'DCU fails on the codes either side of the service range' {
    Convert-DcuExitCode -ExitCode 2999 | Should -Be 'Failed'
    Convert-DcuExitCode -ExitCode 3006 | Should -Be 'Failed'
  }
  It 'a timed-out run (exit code $null) is Failed, never Done' {
    Convert-DcuExitCode -ExitCode $null | Should -Be 'Failed'
    Convert-HpiaExitCode -ExitCode $null | Should -Be 'Failed'
  }
  It 'a value that is not a number is Failed' {
    Convert-DcuExitCode -ExitCode 'abc' | Should -Be 'Failed'
    Convert-HpiaExitCode -ExitCode '' | Should -Be 'Failed'
  }
  It 'HPIA fails on the codes next to its known ones' {
    foreach ($c in 1, 255, 258, 3009, 3012, 4097, 4099) { Convert-HpiaExitCode -ExitCode $c | Should -Be 'Failed' }
  }
}

Describe 'argument builders (exact text)' {
  It 'DCU on battery' {
    Get-DcuApplyArgs -LogPath 'C:\L\d.log' -OnAC $false | Should -Be '/applyUpdates -silent -reboot=disable -outputLog="C:\L\d.log" -updateType=driver,application,others'
  }
  It 'DCU keeps a log path with spaces in one quoted argument' {
    Get-DcuApplyArgs -LogPath 'C:\Ben Tech\Logs\dcu-pass1.log' -OnAC $true | Should -Be '/applyUpdates -silent -reboot=disable -outputLog="C:\Ben Tech\Logs\dcu-pass1.log"'
  }
  It 'HPIA on AC' {
    Get-HpiaArgs -ReportFolder 'C:\r' -DownloadFolder 'C:\d' -OnAC $true | Should -Be '/Operation:Analyze /Category:All /Selection:All /Action:Install /Silent /ReportFolder:"C:\r" /SoftpaqDownloadFolder:"C:\d" /AutoCleanup'
  }
  It 'HPIA on battery' {
    Get-HpiaArgs -ReportFolder 'C:\r' -DownloadFolder 'C:\d' -OnAC $false | Should -Be '/Operation:Analyze /Category:Drivers,Software /Selection:All /Action:Install /Silent /ReportFolder:"C:\r" /SoftpaqDownloadFolder:"C:\d" /AutoCleanup'
  }
  It 'HPIA drops a trailing backslash, which would escape the closing quote' {
    Get-HpiaArgs -ReportFolder 'C:\r\' -DownloadFolder 'C:\d\' -OnAC $true | Should -Match '/ReportFolder:"C:\\r" /SoftpaqDownloadFolder:"C:\\d" '
  }
  It 'Lenovo on AC' {
    Get-LenovoAdminCommandLine -OnAC $true | Should -Be '/CM -search A -action INSTALL -includerebootpackages 1,3,5 -noreboot -noicon -nolicense -exporttowmi'
  }
  It 'Lenovo on battery: reboot types 1,3 and package types 1,2 (applications, drivers) only (R21)' {
    Get-LenovoAdminCommandLine -OnAC $false | Should -Be '/CM -search A -action INSTALL -includerebootpackages 1,3 -packagetypes 1,2 -noreboot -noicon -nolicense -exporttowmi'
  }
  It 'Lenovo on AC has no package-type filter' {
    Get-LenovoAdminCommandLine -OnAC $true | Should -Not -Match 'packagetypes'
  }
  It 'Lenovo never includes reboot type 4 (forces a shutdown)' {
    foreach ($ac in $true, $false) {
      $m = [regex]::Match((Get-LenovoAdminCommandLine -OnAC $ac), '-includerebootpackages (\S+)')
      $m.Success | Should -BeTrue
      @($m.Groups[1].Value -split ',') | Should -Not -Contain '4'
    }
  }
}

Describe 'Test-ShouldRemoveBusinessTool' {
  It 'is true for LENOVO and HP laptops whose app installed' {
    Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand LENOVO -ConsumerAppStatus Done | Should -BeTrue
    Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand HP -ConsumerAppStatus Done | Should -BeTrue
  }
  It 'is false for a brand without a business tool' {
    Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand ASUS -ConsumerAppStatus Done | Should -BeFalse
  }
  It 'is false when the app failed, or its status is missing' {
    Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand LENOVO -ConsumerAppStatus Failed | Should -BeFalse
    Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand LENOVO -ConsumerAppStatus $null | Should -BeFalse
    Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand LENOVO -ConsumerAppStatus '' | Should -BeFalse
    Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand LENOVO -ConsumerAppStatus pending | Should -BeFalse
  }
  It 'is false when the mode or brand is missing' {
    Test-ShouldRemoveBusinessTool -Mode $null -Brand DELL -ConsumerAppStatus Done | Should -BeFalse
    Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand $null -ConsumerAppStatus Done | Should -BeFalse
  }
}

Describe 'Convert-LenovoUpdateRecords' {
  It 'no records is Done' {
    Convert-LenovoUpdateRecords -Records @() | Should -Be 'Done'
    Convert-LenovoUpdateRecords -Records $null | Should -Be 'Done'
  }
  It 'installed records are Done' {
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Installed'), (New-FakeLenovoUpdate 'Installed')) | Should -Be 'Done'
  }
  It 'a reboot or restart status is DoneReboot' {
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Installed'), (New-FakeLenovoUpdate 'Installed, reboot required')) | Should -Be 'DoneReboot'
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Restart pending')) | Should -Be 'DoneReboot'
  }
  It 'a failed record without any restart is Failed, whatever the order' {
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Install failed'), (New-FakeLenovoUpdate 'Installed')) | Should -Be 'Failed'
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Installed'), (New-FakeLenovoUpdate 'Download FAILED')) | Should -Be 'Failed'
  }
  It 'a failure next to a restart is FailedReboot, whatever the order' {
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Install failed'), (New-FakeLenovoUpdate 'Reboot required')) | Should -Be 'FailedReboot'
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Reboot required'), (New-FakeLenovoUpdate 'Download FAILED')) | Should -Be 'FailedReboot'
  }
  It 'one record that both failed and needs a restart is FailedReboot' {
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Install failed, restart required')) | Should -Be 'FailedReboot'
  }
  It 'matches the status text case-insensitively' {
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'REBOOT')) | Should -Be 'DoneReboot'
  }
  It 'ignores $null records' {
    Convert-LenovoUpdateRecords -Records @($null, $null) | Should -Be 'Done'
    Convert-LenovoUpdateRecords -Records @($null, (New-FakeLenovoUpdate 'Installed')) | Should -Be 'Done'
  }
  # Final review I4 (interim until SPIKE#4): records that say nothing the parser knows must never be a
  # silent success. Known: "fail", "reboot"/"restart", or a whole-status success word.
  It 'records whose Status matches no known token are Unverified: <Case>' -ForEach @(
    @{ Case = 'unknown English text'; Records = { @((New-FakeLenovoUpdate 'Pending'), (New-FakeLenovoUpdate 'Downloaded')) } }
    @{ Case = 'no Status at all'; Records = { @([pscustomobject]@{ Name = 'x' }, @{ Title = 'y' }) } }
    @{ Case = 'an empty Status'; Records = { @((New-FakeLenovoUpdate ''), (New-FakeLenovoUpdate '  ')) } }
    @{ Case = 'Hebrew text'; Records = { @((New-FakeLenovoUpdate ([string]::new([char[]]@(0x05D4, 0x05D5, 0x05EA, 0x05E7, 0x05DF))))) } }
    @{ Case = '"Not installed" (a success word inside other text)'; Records = { @((New-FakeLenovoUpdate 'Not installed')) } }
  ) {
    Convert-LenovoUpdateRecords -Records (& $Records) | Should -Be 'Unverified'
  }
  It 'one recognized record is enough: <Status> next to an unknown one' -ForEach @(
    @{ Status = 'Installed'; Expected = 'Done' }
    @{ Status = 'Success'; Expected = 'Done' }
    @{ Status = 'Completed'; Expected = 'Done' }
    @{ Status = 'Reboot required'; Expected = 'DoneReboot' }
    @{ Status = 'Install failed'; Expected = 'Failed' }
  ) {
    Convert-LenovoUpdateRecords -Records @((New-FakeLenovoUpdate 'Something new'), (New-FakeLenovoUpdate $Status)) | Should -Be $Expected
  }
  It 'reads plain objects and hashtables too' {
    Convert-LenovoUpdateRecords -Records @([pscustomobject]@{ Status = 'Failed' }) | Should -Be 'Failed'
    Convert-LenovoUpdateRecords -Records @(@{ Status = 'reboot' }) | Should -Be 'DoneReboot'
  }
}

# --- Invoke-VendorPass: the BitLocker and power gate ------------------------------------------
Describe 'Invoke-VendorPass: BitLocker and power gate' {
  BeforeEach {
    Initialize-VendorMocks
    $script:ctx = New-VendorContext -Brand DELL
    $script:dcu = [string]$script:ctx.Config.vendors.DELL.tool.exeCandidates[0]
    $script:existing = @($script:dcu)
    Set-ToolCodes -Codes @(0) -OtherPattern '^/configure'
    $script:logPath = Join-Path $script:ctx.LogDir 'dcu-pass1.log'
    $script:acArgs = "/applyUpdates -silent -reboot=disable -outputLog=`"$($script:logPath)`""
    $script:noBiosArgs = $script:acArgs + ' -updateType=driver,application,others'
  }
  It 'decrypted and on AC: BIOS allowed, nothing suspended, no notes' {
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $r.Notes.Count | Should -Be 0
    Should -Invoke -CommandName Suspend-BitLockerOnce -Times 0 -Exactly
    @(Get-ToolRuns)[0].ArgumentList | Should -Be $script:acArgs
  }
  It 'waits for decryption with the configured bitlockerDecrypt timeout' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:waitCalls.Count | Should -Be 1
    $script:waitCalls[0] | Should -Be 120
  }
  It 'still decrypting and suspended: BIOS allowed, with a Note' {
    $script:bitlockerDecrypted = $false
    $script:suspendOk = $true
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $r.Notes | Should -Contain 'BitLocker still decrypting: suspended for BIOS update'
    $r.Notes | Should -Not -Contain 'BitLocker could not be suspended: BIOS/firmware updates skipped'
    Should -Invoke -CommandName Suspend-BitLockerOnce -Times 1 -Exactly
    @(Get-ToolRuns)[0].ArgumentList | Should -Be $script:acArgs
  }
  It 'suspend failed: the no-BIOS arguments are forced, with a Note' {
    $script:bitlockerDecrypted = $false
    $script:suspendOk = $false
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $r.Notes | Should -Contain 'BitLocker could not be suspended: BIOS/firmware updates skipped'
    $r.Notes | Should -Not -Contain 'BitLocker still decrypting: suspended for BIOS update'
    $r.Notes | Should -Not -Contain 'On battery: BIOS/firmware updates skipped'
    @(Get-ToolRuns)[0].ArgumentList | Should -Be $script:noBiosArgs
  }
  It 'on battery: the no-BIOS arguments are forced, with a Note' {
    $script:onAC = $false
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
    @(Get-ToolRuns)[0].ArgumentList | Should -Be $script:noBiosArgs
  }
  It 'on battery: the BitLocker gate is skipped entirely, even when the drive is not decrypted (R20)' {
    $script:onAC = $false
    $script:bitlockerDecrypted = $false
    $script:suspendOk = $false
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    Should -Invoke -CommandName Wait-BitLockerDecrypted -Times 0 -Exactly
    Should -Invoke -CommandName Suspend-BitLockerOnce -Times 0 -Exactly
    @($r.Notes) | Should -Be @('On battery: BIOS/firmware updates skipped')
    @(Get-ToolRuns)[0].ArgumentList | Should -Be $script:noBiosArgs
    $script:acCalls | Should -Be 1
  }
  It 'HP: an AC loss before the 4098 retry leaves BIOS out of the retry' {
    $script:ctx = New-VendorContext -Brand HP
    $script:existing = @(Join-Path $script:ctx.DownloadDir 'HPIA\HPImageAssistant.exe')
    Set-ToolCodes -Codes @(4098, 0) -OtherPattern '^/s /e /f '
    $script:onACSeq = @($true, $true, $false)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:ext[0].ArgumentList | Should -Match '/Category:All '
    $script:ext[1].ArgumentList | Should -Match '/Category:Drivers,Software '
    $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
  }
  It 'on AC: power first, then the gate, then /configure, then power again right before the apply' {
    $script:bitlockerDecrypted = $false
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $firstPower = $script:order.IndexOf('Test-OnACPower')
    $wait = $script:order.IndexOf('Wait-BitLockerDecrypted')
    $suspend = $script:order.IndexOf('Suspend-BitLockerOnce')
    $configure = $script:order.IndexOf('Invoke-External')
    $lastPower = $script:order.LastIndexOf('Test-OnACPower')
    $apply = $script:order.LastIndexOf('Invoke-External')
    $firstPower | Should -Be 0
    $wait | Should -BeGreaterThan $firstPower
    $suspend | Should -BeGreaterThan $wait
    $configure | Should -BeGreaterThan $suspend
    $lastPower | Should -BeGreaterThan $configure
    $apply | Should -BeGreaterThan $lastPower
    $script:ext[0].ArgumentList | Should -Match '^/configure'
    $script:acCalls | Should -Be 2
  }
  It 'Dell: AC lost after the gate and /configure: no BIOS, with the battery Note' {
    $script:onACSeq = @($true, $false)
    $script:bitlockerDecrypted = $false
    $script:suspendOk = $true
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    Should -Invoke -CommandName Wait-BitLockerDecrypted -Times 1 -Exactly
    $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
    @($r.Notes | Where-Object { $_ -eq 'On battery: BIOS/firmware updates skipped' }).Count | Should -Be 1
    @(Get-ToolRuns)[0].ArgumentList | Should -Be $script:noBiosArgs
  }
  It 'Dell: AC lost during the service-retry wait: the retry leaves BIOS out' {
    $script:onACSeq = @($true, $true, $false)
    Set-ToolCodes -Codes @(3001, 0) -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    @(Get-ToolRuns)[0].ArgumentList | Should -Be $script:acArgs
    @(Get-ToolRuns)[1].ArgumentList | Should -Be $script:noBiosArgs
    $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
  }
  It 'does not read power again when BIOS is already ruled out (BitLocker not suspended)' {
    $script:bitlockerDecrypted = $false
    $script:suspendOk = $false
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:acCalls | Should -Be 1
  }
  It 'Lenovo: a failed suspend leaves type 5 out of AdminCommandLine, in both registry views' {
    $script:ctx = New-VendorContext -Brand LENOVO
    $script:existing = @([string]$script:ctx.Config.vendors.LENOVO.tool.exeCandidates[0])
    $script:bitlockerDecrypted = $false
    $script:suspendOk = $false
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:regValues.Count | Should -Be 2
    foreach ($v in $script:regValues) { $v.Value | Should -Be (Get-LenovoAdminCommandLine -OnAC $false) }
  }
  It 'Lenovo: AC lost after the install: the restricted policy is written, with the battery Note' {
    $script:ctx = New-VendorContext -Brand LENOVO
    $tvsu = [string]$script:ctx.Config.vendors.LENOVO.tool.exeCandidates[0]
    $script:wingetInstalls = @($tvsu)
    $script:onACSeq = @($true, $false)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:order.IndexOf('Invoke-WingetInstall') | Should -BeLessThan $script:order.LastIndexOf('Test-OnACPower')
    $script:regValues.Count | Should -Be 2
    foreach ($v in $script:regValues) { $v.Value | Should -Be (Get-LenovoAdminCommandLine -OnAC $false) }
    $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
  }
  It 'HP: AC lost after the download and extract: no BIOS, with the battery Note' {
    $script:ctx = New-VendorContext -Brand HP
    $hpiaDir = Join-Path $script:ctx.DownloadDir 'HPIA'
    $hpia = Join-Path $hpiaDir 'HPImageAssistant.exe'
    $installer = Join-Path $script:ctx.DownloadDir 'hp-hpia.exe'
    $script:pageHtml = $script:HpiaHtml
    $script:extHandler = {
      param($c)
      if ($c.FilePath -like '*hp-hpia.exe') { $script:existing += (Join-Path (Split-Path -Parent $c.FilePath) 'HPIA\HPImageAssistant.exe') }
      @{ ExitCode = 0; TimedOut = $false; Output = '' }
    }
    $script:onACSeq = @($true, $false)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:ext[0].FilePath | Should -Be $installer
    $script:order.IndexOf('Invoke-External') | Should -BeLessThan $script:order.LastIndexOf('Test-OnACPower')
    $script:ext[1].FilePath | Should -Be $hpia
    $script:ext[1].ArgumentList | Should -Match '/Category:Drivers,Software '
    $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
  }
  It 'HP: on battery HPIA gets /Category:Drivers,Software' {
    $script:ctx = New-VendorContext -Brand HP
    $hpia = Join-Path $script:ctx.DownloadDir 'HPIA\HPImageAssistant.exe'
    $script:existing = @($hpia)
    $script:onAC = $false
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:ext[0].ArgumentList | Should -Match '/Category:Drivers,Software '
    $script:ext[0].ArgumentList | Should -Not -Match 'Category:All'
  }
}

Describe 'Invoke-VendorPass: brands and config' {
  BeforeEach { Initialize-VendorMocks }
  It 'is Skipped for a brand that has no vendor tool, without waiting or running anything' {
    $ctx = New-VendorContext -Brand ASUS
    $r = Invoke-VendorPass -Context $ctx -Pass 1
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'No vendor tool for ASUS'
    Should -Invoke -CommandName Wait-BitLockerDecrypted -Times 0 -Exactly
    Should -Invoke -CommandName Invoke-External -Times 0 -Exactly
    Should -Invoke -CommandName Invoke-WingetInstall -Times 0 -Exactly
  }
  It 'is Skipped for a brand with no vendors entry at all' {
    $r = Invoke-VendorPass -Context (New-VendorContext -Brand OTHER) -Pass 1
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'No vendor tool for OTHER'
  }
  It 'fails, running nothing, for an unknown tool kind' {
    $ctx = New-VendorContext -Brand DELL
    $ctx.Config.vendors.DELL.tool.kind = 'mystery'
    $r = Invoke-VendorPass -Context $ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match 'mystery'
    Should -Invoke -CommandName Invoke-External -Times 0 -Exactly
  }
  It 'Invoke-StepVendorPass1 and 2 run pass 1 and pass 2' {
    $ctx = New-VendorContext -Brand DELL
    $script:existing = @([string]$ctx.Config.vendors.DELL.tool.exeCandidates[0])
    Set-ToolCodes -Codes @(0) -OtherPattern '^/configure'
    (Invoke-StepVendorPass1 -Context $ctx).Data.Pass | Should -Be 1
    @(Get-ToolRuns)[0].ArgumentList | Should -Match 'dcu-pass1\.log'
    (Invoke-StepVendorPass2 -Context $ctx).Data.Pass | Should -Be 2
    @(Get-ToolRuns)[1].ArgumentList | Should -Match 'dcu-pass2\.log'
  }
}

# --- Dell Command Update ----------------------------------------------------------------------
Describe 'Dell Command Update' {
  BeforeEach {
    Initialize-VendorMocks
    $script:ctx = New-VendorContext -Brand DELL
    $script:dcu = [string]$script:ctx.Config.vendors.DELL.tool.exeCandidates[0]
    $script:dcuX86 = [string]$script:ctx.Config.vendors.DELL.tool.exeCandidates[1]
    $script:existing = @($script:dcu)
    Set-ToolCodes -Codes @(0) -OtherPattern '^/configure'
  }
  It 'uses an installed dcu-cli.exe without calling winget' {
    $script:existing = @($script:dcuX86)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:wingetCalls.Count | Should -Be 0
    $script:ext[0].FilePath | Should -Be $script:dcuX86
  }
  It 'installs Dell.CommandUpdate.Universal with winget when DCU is missing, then uses it' {
    $script:existing = @()
    $script:wingetInstalls = @($script:dcu)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:wingetCalls.Count | Should -Be 1
    $script:wingetCalls[0].Id | Should -Be 'Dell.CommandUpdate.Universal'
    $script:wingetCalls[0].Source | Should -Be 'winget'
    $script:ext[0].FilePath | Should -Be $script:dcu
  }
  It 'is Skipped when winget has no installer for this system' {
    $script:existing = @()
    $script:wingetResult = New-StepResult -Status Skipped -Message 'Dell.CommandUpdate.Universal: no package or installer for this system'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Dell Command Update: no installer for this system'
    $script:ext.Count | Should -Be 0
  }
  It 'fails when DCU is still missing after winget' {
    $script:existing = @()
    $script:wingetResult = New-StepResult -Status Failed -Message 'winget unavailable'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^Dell Command Update not found'
    $script:ext.Count | Should -Be 0
  }
  It 'checks the Dell signature of dcu-cli.exe' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:sigCalls.Count | Should -Be 1
    $script:sigCalls[0].Path | Should -Be $script:dcu
    $script:sigCalls[0].Signers | Should -Contain 'Dell Inc'
  }
  It 'never runs a dcu-cli.exe whose signature is wrong' {
    $script:sigBad = @('dcu-cli.exe')
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Dell Command Update signature check failed'
    $script:ext.Count | Should -Be 0
  }
  It 'configures BitLocker auto-suspend first, limited to 5 minutes' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:ext[0].FilePath | Should -Be $script:dcu
    $script:ext[0].ArgumentList | Should -Be '/configure -silent -autoSuspendBitLocker=enable'
    $script:ext[0].TimeoutMinutes | Should -Be 5
  }
  It 'then applies with the pass log and the vendor timeout' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:ext.Count | Should -Be 2
    $script:ext[1].FilePath | Should -Be $script:dcu
    $script:ext[1].ArgumentList | Should -Be (Get-DcuApplyArgs -LogPath (Join-Path $script:ctx.LogDir 'dcu-pass1.log') -OnAC $true)
    $script:ext[1].TimeoutMinutes | Should -Be 60
  }
  It 'goes on, with a WARN, when /configure <What>' -ForEach @(@{ What = 'fails'; Code = 1 }, @{ What = 'times out'; Code = 'timeout' }, @{ What = 'cannot be started'; Code = 'throw' }) {
    Set-ToolCodes -Codes @(0) -OtherPattern '^/configure' -OtherCode $Code
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    @(Get-ToolRuns).Count | Should -Be 1
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -match 'configure' }).Count | Should -BeGreaterThan 0
  }
  It 'maps exit <Code> to <Status> (reboot <Reboot>)' -ForEach @(
    @{ Code = 0; Status = 'Done'; Reboot = 'None'; Message = 'Dell Command Update finished' }
    @{ Code = 500; Status = 'Done'; Reboot = 'None'; Message = 'Dell Command Update finished' }
    @{ Code = 1; Status = 'Done'; Reboot = 'Now'; Message = 'Dell Command Update finished, restart needed' }
    @{ Code = 5; Status = 'Done'; Reboot = 'Now'; Message = 'Dell Command Update finished, restart needed' }
    @{ Code = 3; Status = 'Skipped'; Reboot = 'None'; Message = 'Dell Command Update does not support this model' }
    @{ Code = 7; Status = 'Skipped'; Reboot = 'None'; Message = 'Dell Command Update does not support this model' }
    @{ Code = 2; Status = 'Failed'; Reboot = 'None'; Message = 'Dell Command Update failed (exit 2)' }
    @{ Code = 1603; Status = 'Failed'; Reboot = 'None'; Message = 'Dell Command Update failed (exit 1603)' }
  ) {
    Set-ToolCodes -Codes @($Code) -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be $Status
    $r.Reboot | Should -Be $Reboot
    $r.Message | Should -Be $Message
    $r.Data.ExitCode | Should -Be $Code
  }
  It 'keeps Data shallow: the pass and the exit code, never Interruptions' {
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Data.Pass | Should -Be 1
    $r.Data.ExitCode | Should -Be 0
    $r.Data.Keys | Should -Not -Contain 'Interruptions'
    foreach ($key in @($r.Data.Keys)) { $r.Data[$key] | Should -Not -BeOfType [System.Collections.IDictionary] }
  }
  It 'fails as timed out when dcu-cli runs past the vendor timeout' {
    Set-ToolCodes -Codes @('timeout') -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Dell Command Update timed out'
    $r.Data.Keys | Should -Not -Contain 'ExitCode'
  }
  It 'fails when dcu-cli cannot be started' {
    Set-ToolCodes -Codes @('throw') -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Dell Command Update could not be started'
  }
  It 'service not running (3000-3005): starts the Dell service, waits 30 s and retries once' {
    Set-ToolCodes -Codes @(3001, 0) -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    @(Get-ToolRuns).Count | Should -Be 2
    @($script:svcNames) | Should -Be @('DellClientManagementService')
    $script:svcStarts | Should -Be 1
    $script:sleeps.Count | Should -Be 1
    $script:sleeps[0].Seconds | Should -Be 30
    $r.Data.ExitCode | Should -Be 0
  }
  It 'bounds the service start: waits at most 60 s for Running, and never uses Start-Service' {
    Set-ToolCodes -Codes @(3000, 0) -OtherPattern '^/configure'
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:svcWaits.Count | Should -Be 1
    $script:svcWaits[0].Status | Should -Be 'Running'
    $script:svcWaits[0].Timeout | Should -Be ([TimeSpan]::FromSeconds(60))
    Should -Invoke -CommandName Start-Service -Times 0 -Exactly
  }
  It 'a service still not Running after 60 s is a WARN, and the retry still happens' {
    $script:svcWaitThrows = $true
    Set-ToolCodes -Codes @(3003, 0) -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    @(Get-ToolRuns).Count | Should -Be 2
    $script:sleeps.Count | Should -Be 1
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'The Dell service could not be started; retrying anyway' }).Count | Should -Be 1
  }
  It 'only waits for a service that is already StartPending (Start() would throw)' {
    $script:svcStatus = 'StartPending'
    Set-ToolCodes -Codes @(3005, 0) -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:svcStarts | Should -Be 0
    $script:svcWaits.Count | Should -Be 1
  }
  It 'leaves a service that is already Running alone, and still retries' {
    $script:svcStatus = 'Running'
    Set-ToolCodes -Codes @(3004, 0) -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:svcStarts | Should -Be 0
    $script:svcWaits.Count | Should -Be 0
    @(Get-ToolRuns).Count | Should -Be 2
  }
  It 'does not wait when no retry is needed' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:sleeps.Count | Should -Be 0
  }
  It 'makes the wait before the Dell retry injectable' {
    Set-ToolCodes -Codes @(3004, 0) -OtherPattern '^/configure'
    $o = Invoke-DellUpdate -Context $script:ctx -Tool $script:ctx.Config.vendors.DELL.tool -OnAC $true -Pass 1 -RetrySeconds 3
    $o.Outcome | Should -Be 'Done'
    $script:sleeps.Count | Should -Be 1
    $script:sleeps[0].Seconds | Should -Be 3
  }
  It 'service code again on the retry: Failed with the exit code' {
    Set-ToolCodes -Codes @(3005) -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Dell Command Update failed (exit 3005)'
    @(Get-ToolRuns).Count | Should -Be 2
    $script:svcStarts | Should -Be 1
  }
  It 'still waits and retries when the service <Why>' -ForEach @(@{ Why = 'cannot be found'; Get = $true; Start = $false }, @{ Why = 'refuses to start'; Get = $false; Start = $true }) {
    $script:svcGetThrows = $Get
    $script:svcStartThrows = $Start
    Set-ToolCodes -Codes @(3000, 500) -OtherPattern '^/configure'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    @(Get-ToolRuns).Count | Should -Be 2
    $script:sleeps.Count | Should -Be 1
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'The Dell service could not be started; retrying anyway' }).Count | Should -Be 1
  }
}

# --- Lenovo System Update ---------------------------------------------------------------------
Describe 'Lenovo System Update' {
  BeforeEach {
    Initialize-VendorMocks
    $script:ctx = New-VendorContext -Brand LENOVO
    $script:tool = $script:ctx.Config.vendors.LENOVO.tool
    $script:tvsu = [string]$script:tool.exeCandidates[0]
    $script:existing = @($script:tvsu)
    $script:lenovoLogs = Join-Path $env:ProgramData 'Lenovo\SystemUpdate\logs'
    Set-ToolCodes -Codes @(0)
  }
  It 'uses an installed tvsu.exe without calling winget' {
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:wingetCalls.Count | Should -Be 0
    $script:ext[0].FilePath | Should -Be $script:tvsu
  }
  It 'installs Lenovo.SystemUpdate with winget when tvsu.exe is missing, then uses it' {
    $script:existing = @()
    $script:wingetInstalls = @($script:tvsu)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:wingetCalls[0].Id | Should -Be 'Lenovo.SystemUpdate'
    $script:wingetCalls[0].Source | Should -Be 'winget'
    $script:ext[0].FilePath | Should -Be $script:tvsu
  }
  It 'is Skipped when winget has no installer for this system' {
    $script:existing = @()
    $script:wingetResult = New-StepResult -Status Skipped -Message 'Lenovo.SystemUpdate: no package or installer for this system'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Lenovo System Update: no installer for this system'
    $script:ext.Count | Should -Be 0
    $script:regValues.Count | Should -Be 0
  }
  It 'fails when tvsu.exe is still missing after winget' {
    $script:existing = @()
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^Lenovo System Update not found'
    $script:ext.Count | Should -Be 0
  }
  It 'never runs, or configures, a tvsu.exe whose Lenovo signature is wrong' {
    $script:sigBad = @('tvsu.exe')
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo System Update signature check failed'
    $script:sigCalls[0].Path | Should -Be $script:tvsu
    $script:sigCalls[0].Signers | Should -Contain 'Lenovo'
    $script:ext.Count | Should -Be 0
    $script:regValues.Count | Should -Be 0
  }
  It 'writes AdminCommandLine as REG_SZ into both registry views, creating each key when it is missing (R19)' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:regKeys | Should -Contain $script:LenovoPolicyKey
    $script:regKeys | Should -Contain $script:LenovoWowPolicyKey
    $script:regValues.Count | Should -Be 2
    @($script:regValues | ForEach-Object { $_.Path }) | Should -Be @($script:LenovoPolicyKey, $script:LenovoWowPolicyKey)
    foreach ($v in $script:regValues) {
      $v.Name | Should -Be 'AdminCommandLine'
      $v.Type | Should -Be 'String'
      $v.Value | Should -Be (Get-LenovoAdminCommandLine -OnAC $true)
    }
  }
  It 'does not recreate policy keys that exist' {
    $script:existing += @($script:LenovoPolicyKey, $script:LenovoWowPolicyKey)
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    Should -Invoke -CommandName New-Item -Times 0 -Exactly
    $script:regValues.Count | Should -Be 2
  }
  It 'creates only the key that is missing' {
    $script:existing += $script:LenovoPolicyKey
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    @($script:regKeys) | Should -Be @($script:LenovoWowPolicyKey)
    $script:regValues.Count | Should -Be 2
  }
  It 'on battery the policy leaves type 5 (BIOS/firmware) out, in both views' {
    $script:onAC = $false
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:regValues.Count | Should -Be 2
    foreach ($v in $script:regValues) { $v.Value | Should -Be (Get-LenovoAdminCommandLine -OnAC $false) }
    $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
  }
  It 'fails, and never runs tvsu, when the policy cannot be written' {
    $script:regWriteThrows = $true
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo System Update settings could not be written'
    $script:ext.Count | Should -Be 0
  }
  It 'fails, and never runs tvsu, when only the <View> view cannot be written' -ForEach @(@{ View = 'native' }, @{ View = '32-bit (WOW6432Node)' }) {
    $script:regWriteThrowsFor = if ($View -eq 'native') { @($script:LenovoPolicyKey) } else { @($script:LenovoWowPolicyKey) }
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo System Update settings could not be written'
    $script:regValues.Count | Should -Be 1
    $script:ext.Count | Should -Be 0
  }
  It 'runs tvsu.exe /CM with the vendor timeout' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:ext.Count | Should -Be 1
    $script:ext[0].ArgumentList | Should -Be '/CM'
    $script:ext[0].TimeoutMinutes | Should -Be 60
  }
  It 'waits until no tvsu or Tvsukernel process is left, polling every 10 s' {
    $script:procRunningPolls = 2
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:procPolls | Should -Be 3
    @($script:procNames[0]) | Should -Be @('tvsu', 'Tvsukernel')
    $script:sleeps.Count | Should -Be 3
    foreach ($s in $script:sleeps) { $s.Milliseconds | Should -Be 10000 }
    Should -Invoke -CommandName Stop-Process -Times 0 -Exactly
  }
  It 'waits one interval before the first check, so a Tvsukernel that starts late is not missed' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:sleeps.Count | Should -Be 1
    $script:procPolls | Should -Be 1
  }
  It 'makes the poll interval injectable' {
    $script:procRunningPolls = 1
    $o = Invoke-LenovoUpdate -Context $script:ctx -Tool $script:tool -OnAC $true -Pass 1 -PollSeconds 2
    $o.Outcome | Should -Be 'Done'
    foreach ($s in $script:sleeps) { $s.Milliseconds | Should -Be 2000 }
  }
  It 'kills what is left and fails when the processes outlive the vendor timeout' {
    $script:ctx.Config.timeoutsMinutes.vendor = 0.001
    $script:procRunningPolls = [int]::MaxValue
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo System Update timed out'
    $script:stopped | Should -Contain 4101
    $script:stopped | Should -Contain 4102
    Should -Invoke -CommandName Stop-Process -ParameterFilter { $Force } -Times 2 -Exactly
    Should -Invoke -CommandName Get-CimInstance -Times 0 -Exactly
  }
  It 'fails, and kills any leftover process, when tvsu.exe itself times out' {
    Set-ToolCodes -Codes @('timeout')
    $script:procRunningPolls = 1
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo System Update timed out'
    $script:stopped.Count | Should -Be 2
  }
  It 'fails when tvsu.exe cannot be started' {
    Set-ToolCodes -Codes @('throw')
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo System Update could not be started'
  }
  It 'copies the System Update logs to Logs\lenovo-pass<N>' {
    $script:existing += $script:lenovoLogs
    $null = Invoke-VendorPass -Context $script:ctx -Pass 2
    $script:copies.Count | Should -Be 1
    $script:copies[0].Path | Should -Be @(Join-Path $script:lenovoLogs '*')
    $script:copies[0].Destination | Should -Be (Join-Path $script:ctx.LogDir 'lenovo-pass2')
  }
  It 'copies the logs after a timeout too' {
    $script:existing += $script:lenovoLogs
    Set-ToolCodes -Codes @('timeout')
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:copies.Count | Should -Be 1
  }
  It 'a failed log copy does not fail the step' {
    $script:existing += $script:lenovoLogs
    $script:copyThrows = $true
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    @($script:logs | Where-Object { $_.Level -eq 'WARN' }).Count | Should -BeGreaterThan 0
  }
  It 'skips the copy when System Update wrote no logs' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:copies.Count | Should -Be 0
  }
  It 'reads the result from root\Lenovo Lenovo_Updates, with a 30 s limit' {
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:cimCalls.Count | Should -Be 1
    $script:cimCalls[0].Namespace | Should -Be 'root\Lenovo'
    $script:cimCalls[0].ClassName | Should -Be 'Lenovo_Updates'
    $script:cimCalls[0].OperationTimeoutSec | Should -Be 30
  }
  It 'no records from a query that worked: a plain Done(No Lenovo updates reported)' {
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'No Lenovo updates reported'
    $r.Reboot | Should -Be 'None'
    $r.Notes.Count | Should -Be 0
  }
  It 'keeps the tvsu exit code in the step Data' {
    Set-ToolCodes -Codes @(7)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 2
    $r.Status | Should -Be 'Done'
    $r.Data.Pass | Should -Be 2
    $r.Data.ExitCode | Should -Be 7
  }
  It 'keeps the tvsu exit code when the processes outlive the timeout' {
    $script:ctx.Config.timeoutsMinutes.vendor = 0.001
    $script:procRunningPolls = [int]::MaxValue
    Set-ToolCodes -Codes @(0)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Message | Should -Be 'Lenovo System Update timed out'
    $r.Data.ExitCode | Should -Be 0
  }
  It 'a failed record: Failed, without a reboot' {
    $script:lenovoRecords = @((New-FakeLenovoUpdate 'Installed'), (New-FakeLenovoUpdate 'Install failed'))
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo System Update reported failed updates'
    $r.Reboot | Should -Be 'None'
  }
  It 'a failed record next to one that needs a restart: Failed WITH Reboot Now' {
    $script:lenovoRecords = @((New-FakeLenovoUpdate 'Install failed'), (New-FakeLenovoUpdate 'Installed, reboot required'))
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo System Update reported failed updates'
    $r.Reboot | Should -Be 'Now'
  }
  It 'a record that needs a restart: Done with Reboot Now' {
    $script:lenovoRecords = @((New-FakeLenovoUpdate 'Installed'), (New-FakeLenovoUpdate 'Installed, reboot required'))
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'Now'
  }
  It 'installed records: Done without a reboot' {
    $script:lenovoRecords = @((New-FakeLenovoUpdate 'Installed'))
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Lenovo System Update finished'
    $r.Reboot | Should -Be 'None'
  }
  It 'records it cannot interpret: Done WITH the Note naming that pass''s logs, never a silent success (I4 interim)' -ForEach @(
    @{ Pass = 1 }
    @{ Pass = 2 }
  ) {
    $script:lenovoRecords = @((New-FakeLenovoUpdate 'Pending'), [pscustomobject]@{ Title = 'no status' })
    $r = Invoke-VendorPass -Context $script:ctx -Pass $Pass
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    $r.Notes | Should -Contain "Lenovo System Update result could not be verified; see Logs\lenovo-pass$Pass"
  }
  It 'an unreadable WMI result is Done WITH the Note, never a silent success' {
    $script:cimThrows = $true
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Not -Be 'No Lenovo updates reported'
    $r.Notes | Should -Contain 'Lenovo System Update result could not be read'
    $r.Data.ExitCode | Should -Be 0
    @($script:logs | Where-Object { $_.Level -eq 'WARN' }).Count | Should -BeGreaterThan 0
  }
  It 'an unreadable result keeps the gate Notes too' {
    $script:cimThrows = $true
    $script:bitlockerDecrypted = $false
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Notes | Should -Contain 'BitLocker still decrypting: suspended for BIOS update'
    $r.Notes | Should -Contain 'Lenovo System Update result could not be read'
  }

  # Ruling R22: the policy never outlives the tvsu run.
  It 'removes AdminCommandLine from both views after <Case>' -ForEach @(
    @{ Case = 'a success'; Expected = 'No Lenovo updates reported'; Setup = { } }
    @{ Case = 'reported failures'; Expected = 'Lenovo System Update reported failed updates'; Setup = { $script:lenovoRecords = @((New-FakeLenovoUpdate 'Install failed')) } }
    @{ Case = 'a tvsu timeout'; Expected = 'Lenovo System Update timed out'; Setup = { Set-ToolCodes -Codes @('timeout') } }
    @{ Case = 'a process-wait timeout'; Expected = 'Lenovo System Update timed out'; Setup = { $script:ctx.Config.timeoutsMinutes.vendor = 0.001; $script:procRunningPolls = [int]::MaxValue } }
    @{ Case = 'tvsu could not be started'; Expected = 'Lenovo System Update could not be started'; Setup = { Set-ToolCodes -Codes @('throw') } }
  ) {
    . $Setup
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Message | Should -Be $Expected
    $script:regValues.Count | Should -Be 2
    $script:regRemoved.Count | Should -Be 2
    @($script:regRemoved | ForEach-Object { $_.Path }) | Should -Be @($script:LenovoPolicyKey, $script:LenovoWowPolicyKey)
    foreach ($removal in $script:regRemoved) { @($removal.Name) | Should -Be @('AdminCommandLine') }
    $script:regPresent.Count | Should -Be 0
    Should -Invoke -CommandName Remove-Item -Times 0 -Exactly
  }
  It 'removes the value only after tvsu and its processes are done' {
    $script:procRunningPolls = 2
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    Should -Invoke -CommandName Remove-ItemProperty -Times 2 -Exactly
    $script:procPolls | Should -Be 3
    $script:order.IndexOf('Remove-ItemProperty') | Should -BeGreaterThan $script:order.LastIndexOf('Get-Process')
    $script:order.IndexOf('Remove-ItemProperty') | Should -BeGreaterThan $script:order.IndexOf('Invoke-External')
  }
  It 'kills leftover processes before it removes the value' {
    $script:ctx.Config.timeoutsMinutes.vendor = 0.001
    $script:procRunningPolls = [int]::MaxValue
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $script:stopped.Count | Should -Be 2
    $script:order.IndexOf('Remove-ItemProperty') | Should -BeGreaterThan $script:order.LastIndexOf('Get-Process')
  }
  It 'removes a half-written policy when the other view could not be written' {
    $script:regWriteThrowsFor = @($script:LenovoWowPolicyKey)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $script:regRemoved.Count | Should -Be 1
    $script:regRemoved[0].Path | Should -Be $script:LenovoPolicyKey
    $script:regPresent.Count | Should -Be 0
  }
}

# --- HP Image Assistant -----------------------------------------------------------------------
Describe 'HP Image Assistant' {
  BeforeEach {
    Initialize-VendorMocks
    $script:ctx = New-VendorContext -Brand HP
    $script:tool = $script:ctx.Config.vendors.HP.tool
    $script:hpiaDir = Join-Path $script:ctx.DownloadDir 'HPIA'
    $script:hpiaExe = Join-Path $script:hpiaDir 'HPImageAssistant.exe'
    $script:installer = Join-Path $script:ctx.DownloadDir 'hp-hpia.exe'
    $script:pageHtml = $script:HpiaHtml
    $script:extractCode = 0
    Set-ToolCodes -Codes @(0) -OtherPattern '^/s /e /f '
    # The extractor puts HPImageAssistant.exe in place when it succeeds.
    $script:toolHandler = $script:extHandler
    $script:extHandler = {
      param($c)
      if ($c.FilePath -eq $script:installer) {
        if ($script:extractCode -is [string] -and $script:extractCode -eq 'timeout') { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
        if ($script:extractCode -eq 0) { $script:existing += $script:hpiaExe }
        return @{ ExitCode = $script:extractCode; TimedOut = $false; Output = '' }
      }
      & $script:toolHandler $c
    }
  }
  It 'uses an HPImageAssistant.exe already extracted (pass 2), without downloading' {
    $script:existing = @($script:hpiaExe)
    $r = Invoke-VendorPass -Context $script:ctx -Pass 2
    $r.Status | Should -Be 'Done'
    $script:pageCalls.Count | Should -Be 0
    $script:downloads.Count | Should -Be 0
    $script:sigCalls[0].Path | Should -Be $script:hpiaExe
    $script:ext.Count | Should -Be 1
    $script:ext[0].FilePath | Should -Be $script:hpiaExe
  }
  It 'downloads the newest HPIA from the page, checks it, extracts it and checks the extracted exe' {
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:wingetCalls.Count | Should -Be 0
    $script:pageCalls[0] | Should -Be $script:tool.page
    $script:downloads[0].Url | Should -Be 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.7.exe'
    $script:downloads[0].Destination | Should -Be $script:installer
    $script:sigCalls[0].Path | Should -Be $script:installer
    $script:sigCalls[0].Signers | Should -Contain 'HP Inc'
    $script:ext[0].FilePath | Should -Be $script:installer
    $script:ext[0].ArgumentList | Should -Be "/s /e /f `"$($script:hpiaDir)`""
    $script:ext[0].TimeoutMinutes | Should -Be 30
    $script:sigCalls[1].Path | Should -Be $script:hpiaExe
    $script:sigCalls[1].Signers | Should -Contain 'HP Inc'
    $script:ext[1].FilePath | Should -Be $script:hpiaExe
  }
  It 'runs HPIA with the pass report folder, the softpaq folder and the vendor timeout' {
    $script:existing = @($script:hpiaExe)
    $null = Invoke-VendorPass -Context $script:ctx -Pass 1
    $expected = Get-HpiaArgs -ReportFolder (Join-Path $script:ctx.LogDir 'HPIA-pass1') -DownloadFolder (Join-Path $script:ctx.DownloadDir 'HPIA-softpaqs') -OnAC $true
    $script:ext[0].ArgumentList | Should -Be $expected
    $script:ext[0].TimeoutMinutes | Should -Be 60
  }
  It 'fails when the download page cannot be read' {
    $script:pageError = 'download failed after 3 attempts: https://ftp.ext.hp.com'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^HP Image Assistant page could not be read'
    $script:ext.Count | Should -Be 0
  }
  It 'fails when the page has no HPIA link' {
    $script:pageHtml = '<html>nothing here</html>'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP Image Assistant download link not found'
    $script:downloads.Count | Should -Be 0
  }
  It 'fails when the download fails' {
    $script:downloadError = 'download failed after 3 attempts: x'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^HP Image Assistant download failed'
    $script:ext.Count | Should -Be 0
  }
  It 'rejects a downloaded installer with a bad signature, deletes it and runs nothing' {
    $script:sigBad = @('hp-hpia.exe')
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP Image Assistant signature check failed'
    $script:removed | Should -Contain $script:installer
    $script:ext.Count | Should -Be 0
  }
  It 'fails with the exit code when the extract fails' {
    $script:extractCode = 5
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP Image Assistant extract failed (exit 5)'
    $script:ext.Count | Should -Be 1
  }
  It 'fails when the extract times out' {
    $script:extractCode = 'timeout'
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP Image Assistant extract timed out'
  }
  It 'fails when the extract leaves no HPImageAssistant.exe' {
    $script:extHandler = { param($c) @{ ExitCode = 0; TimedOut = $false; Output = '' } }
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP Image Assistant not found after extract'
    $script:ext.Count | Should -Be 1
  }
  It 'never runs an HPImageAssistant.exe whose signature is wrong' {
    $script:existing = @($script:hpiaExe)
    $script:sigBad = @('HPImageAssistant.exe')
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP Image Assistant signature check failed'
    $script:ext.Count | Should -Be 0
  }
  It 'maps exit <Code> to <Status> (reboot <Reboot>)' -ForEach @(
    @{ Code = 0; Status = 'Done'; Reboot = 'None'; Message = 'HP Image Assistant finished' }
    @{ Code = 256; Status = 'Done'; Reboot = 'None'; Message = 'HP Image Assistant finished' }
    @{ Code = 257; Status = 'Done'; Reboot = 'None'; Message = 'HP Image Assistant finished' }
    @{ Code = 3010; Status = 'Done'; Reboot = 'Now'; Message = 'HP Image Assistant finished, restart needed' }
    @{ Code = 3011; Status = 'Done'; Reboot = 'None'; Message = 'HP Image Assistant finished' }
    @{ Code = 4096; Status = 'Skipped'; Reboot = 'None'; Message = 'HP Image Assistant does not support this model' }
    @{ Code = 3020; Status = 'Failed'; Reboot = 'None'; Message = 'HP Image Assistant failed (exit 3020)' }
    @{ Code = 8192; Status = 'Failed'; Reboot = 'None'; Message = 'HP Image Assistant failed (exit 8192)' }
  ) {
    $script:existing = @($script:hpiaExe)
    Set-ToolCodes -Codes @($Code) -OtherPattern '^/s /e /f '
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be $Status
    $r.Reboot | Should -Be $Reboot
    $r.Message | Should -Be $Message
    $r.Data.ExitCode | Should -Be $Code
  }
  It '3011 adds the manual-install Note' {
    $script:existing = @($script:hpiaExe)
    Set-ToolCodes -Codes @(3011) -OtherPattern '^/s /e /f '
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Notes | Should -Contain 'HP Image Assistant: some updates need manual install'
  }
  It 'fails as timed out when HPIA runs past the vendor timeout' {
    $script:existing = @($script:hpiaExe)
    Set-ToolCodes -Codes @('timeout') -OtherPattern '^/s /e /f '
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP Image Assistant timed out'
  }
  It '4098 (no internet): waits 30 s and retries once' {
    $script:existing = @($script:hpiaExe)
    Set-ToolCodes -Codes @(4098, 0) -OtherPattern '^/s /e /f '
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Done'
    $script:ext.Count | Should -Be 2
    $script:sleeps.Count | Should -Be 1
    $script:sleeps[0].Seconds | Should -Be 30
  }
  It '4098 again on the retry: Failed with the exit code' {
    $script:existing = @($script:hpiaExe)
    Set-ToolCodes -Codes @(4098) -OtherPattern '^/s /e /f '
    $r = Invoke-VendorPass -Context $script:ctx -Pass 1
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP Image Assistant failed (exit 4098)'
    $script:ext.Count | Should -Be 2
  }
  It 'makes the retry wait injectable' {
    $script:existing = @($script:hpiaExe)
    Set-ToolCodes -Codes @(4098, 0) -OtherPattern '^/s /e /f '
    $o = Invoke-HpUpdate -Context $script:ctx -Tool $script:tool -OnAC $true -Pass 1 -RetrySeconds 3
    $o.Outcome | Should -Be 'Done'
    $script:sleeps[0].Seconds | Should -Be 3
  }
}

# --- Invoke-StepConsumerApp -------------------------------------------------------------------
Describe 'Invoke-StepConsumerApp' {
  BeforeEach { Initialize-VendorMocks }
  It 'installs the configured app with its id and source' {
    $ctx = New-VendorContext -Brand LENOVO
    $null = Invoke-StepConsumerApp -Context $ctx
    $script:wingetCalls.Count | Should -Be 1
    $script:wingetCalls[0].Id | Should -Be '9WZDNCRFJ4MV'
    $script:wingetCalls[0].Source | Should -Be 'msstore'
  }
  It 'is Done with "<name> installed" when winget installs it' {
    $script:wingetResult = New-StepResult -Status Done -Message '9WZDNCRFJ4MV: installed'
    $r = Invoke-StepConsumerApp -Context (New-VendorContext -Brand LENOVO)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Lenovo Vantage installed'
  }
  It 'turns a failed Store install into Skipped with the winget code' {
    $script:wingetResult = New-StepResult -Status Failed -Message 'XPDCCXDN26VNBT: winget 0x8A15001E'
    $r = Invoke-StepConsumerApp -Context (New-VendorContext -Brand DELL)
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Dell SupportAssist: Store install failed (0x8A15001E), install it from the Store'
  }
  It 'gives the winget reason when a failed Store install has no code' {
    $script:wingetResult = New-StepResult -Status Failed -Message 'winget unavailable'
    $r = Invoke-StepConsumerApp -Context (New-VendorContext -Brand ASUS)
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'MyASUS: Store install failed (winget unavailable), install it from the Store'
  }
  It 'leaves the package id out of a reason that has no code' {
    $script:wingetResult = New-StepResult -Status Failed -Message '9WZDNCRFJ4MV: winget timed out'
    $r = Invoke-StepConsumerApp -Context (New-VendorContext -Brand LENOVO)
    $r.Message | Should -Be 'Lenovo Vantage: Store install failed (winget timed out), install it from the Store'
  }
  It 'passes a failed winget-source install through as Failed' {
    $script:wingetResult = New-StepResult -Status Failed -Message 'HP.SupportAssistant: winget 0x8A15001E'
    $r = Invoke-StepConsumerApp -Context (New-VendorContext -Brand HP)
    $script:wingetCalls[0].Source | Should -Be 'winget'
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'HP.SupportAssistant: winget 0x8A15001E'
  }
  It 'passes a winget Skipped (no package for this system) through' {
    $script:wingetResult = New-StepResult -Status Skipped -Message '9N7R5S6B0ZZH: no package or installer for this system'
    $r = Invoke-StepConsumerApp -Context (New-VendorContext -Brand ASUS)
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be '9N7R5S6B0ZZH: no package or installer for this system'
  }
  It 'is Skipped when the brand has no consumer app' {
    $r = Invoke-StepConsumerApp -Context (New-VendorContext -Brand SAMSUNG)
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'No vendor app for SAMSUNG'
    $script:wingetCalls.Count | Should -Be 0
  }
  It 'is Skipped when the brand entry has a tool but no consumerApp' {
    $ctx = New-VendorContext -Brand DELL
    $ctx.Config.vendors.DELL.PSObject.Properties.Remove('consumerApp')
    $r = Invoke-StepConsumerApp -Context $ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'No vendor app for DELL'
  }
}

# --- Invoke-StepVendorCleanup -----------------------------------------------------------------
Describe 'Invoke-StepVendorCleanup' {
  BeforeAll {
    function New-CleanupContext {
      param([string]$Brand, [string]$Mode = 'LAPTOP', [string]$AppStatus = 'Done')
      $ctx = New-VendorContext -Brand $Brand -Mode $Mode
      if ($AppStatus) { $ctx.State.Steps['consumer-app'] = @{ Status = $AppStatus; Attempts = 1; Message = ''; Data = @{} } }
      return $ctx
    }
  }
  BeforeEach { Initialize-VendorMocks }
  It 'keeps the tool when the consumer app was <AppStatus>' -ForEach @(@{ AppStatus = 'Skipped' }, @{ AppStatus = 'Failed' }) {
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand DELL -AppStatus $AppStatus)
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Kept: consumer app not installed'
    $script:uninstallCalls.Count | Should -Be 0
  }
  It 'keeps the tool when the consumer-app step has no state' {
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand DELL -AppStatus '')
    $r.Status | Should -Be 'Skipped'
    $script:uninstallCalls.Count | Should -Be 0
  }
  It 'keeps the tool on a desktop' {
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand DELL -Mode DESKTOP)
    $r.Status | Should -Be 'Skipped'
    $script:uninstallCalls.Count | Should -Be 0
  }
  It 'Dell: uninstalls Dell.CommandUpdate.Universal' {
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand DELL)
    $script:uninstallCalls.Count | Should -Be 1
    $script:uninstallCalls[0] | Should -Be 'Dell.CommandUpdate.Universal'
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Dell Command Update removed'
    $script:regRemoved.Count | Should -Be 0
  }
  It 'counts an uninstall Skipped (not installed) as Done' {
    $script:uninstallResult = New-StepResult -Status Skipped -Message 'Dell.CommandUpdate.Universal: not installed, nothing to remove'
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand DELL)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Dell Command Update was not installed'
  }
  It 'reports a failed uninstall as Failed' {
    $script:uninstallResult = New-StepResult -Status Failed -Message 'Dell.CommandUpdate.Universal: winget 0x8A150001'
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand DELL)
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Dell.CommandUpdate.Universal: winget 0x8A150001'
  }
  It 'Lenovo: uninstalls Lenovo.SystemUpdate, then removes only the AdminCommandLine value, from both views (R19)' {
    $script:regPresent[$script:LenovoPolicyKey] = @{ AdminCommandLine = '/CM -search A' }
    $script:regPresent[$script:LenovoWowPolicyKey] = @{ AdminCommandLine = '/CM -search A' }
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand LENOVO)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Lenovo System Update removed'
    $script:uninstallCalls[0] | Should -Be 'Lenovo.SystemUpdate'
    $script:regRemoved.Count | Should -Be 2
    @($script:regRemoved | ForEach-Object { $_.Path }) | Should -Be @($script:LenovoPolicyKey, $script:LenovoWowPolicyKey)
    foreach ($removal in $script:regRemoved) { @($removal.Name) | Should -Be @('AdminCommandLine') }
    Should -Invoke -CommandName Remove-Item -Times 0 -Exactly
  }
  It 'Lenovo: removes the values when System Update was already gone' {
    $script:regPresent[$script:LenovoPolicyKey] = @{ AdminCommandLine = '/CM -search A' }
    $script:regPresent[$script:LenovoWowPolicyKey] = @{ AdminCommandLine = '/CM -search A' }
    $script:uninstallResult = New-StepResult -Status Skipped -Message 'Lenovo.SystemUpdate: not installed, nothing to remove'
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand LENOVO)
    $r.Status | Should -Be 'Done'
    $script:regRemoved.Count | Should -Be 2
  }
  It 'Lenovo: removes the value only from the view that has it' {
    $script:regPresent[$script:LenovoWowPolicyKey] = @{ AdminCommandLine = '/CM -search A' }
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand LENOVO)
    $r.Status | Should -Be 'Done'
    $script:regRemoved.Count | Should -Be 1
    $script:regRemoved[0].Path | Should -Be $script:LenovoWowPolicyKey
  }
  It 'Lenovo: leaves the registry alone when the value is in neither view' {
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand LENOVO)
    $r.Status | Should -Be 'Done'
    $script:regRemoved.Count | Should -Be 0
  }
  It 'Lenovo: a value that cannot be removed is a WARN, and the other view is still cleaned' {
    $script:regPresent[$script:LenovoPolicyKey] = @{ AdminCommandLine = '/CM -search A' }
    $script:regPresent[$script:LenovoWowPolicyKey] = @{ AdminCommandLine = '/CM -search A' }
    $script:regRemoveThrowsFor = @($script:LenovoPolicyKey)
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand LENOVO)
    $r.Status | Should -Be 'Done'
    @($script:logs | Where-Object { $_.Level -eq 'WARN' }).Count | Should -BeGreaterThan 0
    $script:regRemoved.Count | Should -Be 1
    $script:regRemoved[0].Path | Should -Be $script:LenovoWowPolicyKey
  }
  It 'HP: nothing to uninstall, HPIA goes with Downloads' {
    $r = Invoke-StepVendorCleanup -Context (New-CleanupContext -Brand HP)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'HPIA is portable; removed with Downloads'
    $script:uninstallCalls.Count | Should -Be 0
  }
}
