# tests/SystemSteps.Tests.ps1
# Task 11: BitLocker, region, desktop icons, bloatware and rename steps.
#
# SAFETY: this runs on a real PC, and the steps decrypt the disk, rename the machine, change the time
# zone and language list and remove apps. Nothing here may do any of that. Every test that reaches a
# system command runs after Initialize-SystemMocks (each Describe calls it from BeforeEach), which
# replaces EVERY command the five steps can use with a recorder: CIM, the registry cmdlets, time zone,
# services, language list, Appx, Rename-Computer, Invoke-External, and also Stop-Process, Start-Process
# and Restart-Computer so that "no Explorer restart / no reboot" can be asserted. The only code that
# really runs is in-memory: the CimInstance and WinUserLanguage objects are built without touching
# WMI or the language settings, and Start-Sleep is real but only for a few milliseconds.
BeforeAll {
  foreach ($f in 'StepResult', 'Logging', 'Process') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
  # Set-RegistryDword (the "create the key if missing, then write the DWord" helper) lives in
  # Prepare.ps1. The bundle holds every file, so the steps below use it directly.
  foreach ($f in 'Prepare', 'BitLocker', 'Region', 'Desktop', 'Bloatware', 'Rename') { . "$PSScriptRoot\..\src\Steps\$f.ps1" }
  # Loads the WinUserLanguage type used to build fake language lists. Read-only.
  Import-Module International -ErrorAction Stop

  # A hex literal above 0x7FFFFFFF is a negative Int32 in Windows PowerShell 5.1; CIM return values are UInt32.
  $script:FveLockedVolume = [Convert]::ToUInt32('80310000', 16)
  $script:BitLockerNs = 'root\cimv2\Security\MicrosoftVolumeEncryption'
  $script:BitLockerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
  $script:PendingNameKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
  $script:ConfigFile = "$PSScriptRoot\..\config\config.json"

  function New-SysContext {
    param(
      [string]$NewName = 'DELL-7HX2K93',
      [string[]]$Remove = @('king.com.*', 'MicrosoftTeams'),
      [string[]]$Protect = @('Microsoft.WindowsCalculator', 'MSTeams'),
      [switch]$NoMachine
    )
    $state = if ($NoMachine) { @{} } else { @{ Machine = @{ NewName = $NewName } } }
    @{
      Config      = [pscustomobject]@{ bloatware = [pscustomobject]@{ remove = $Remove; protect = $Protect } }
      State       = $state
      Root        = 'C:\BenTech\Setup'
      LogDir      = 'C:\BenTech\Setup\Logs'
      DownloadDir = 'C:\BenTech\Setup\Downloads'
      ScriptPath  = 'C:\BenTech\Setup\setup.ps1'
      StatePath   = 'C:\BenTech\Setup\state.json'
    }
  }

  # A real CimInstance, built in memory only (no WMI call). Invoke-CimMethod's -InputObject is typed,
  # so a pscustomobject would not bind to the mock.
  function New-FakeVolume {
    [Microsoft.Management.Infrastructure.CimInstance]::new('Win32_EncryptableVolume', $script:BitLockerNs)
  }

  # What Get-AppxPackage returns, as far as the pipeline into Remove-AppxPackage cares: that cmdlet's
  # -Package is a [string] bound by value, and a real AppxPackage converts to its PackageFullName.
  function New-FakeAppx {
    param([string]$Name)
    $o = [pscustomobject]@{ Name = $Name; PackageFullName = "${Name}_1.0.0.0_x64__8wekyb3d8bbwe" }
    $o | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.PackageFullName } -Force
    return $o
  }

  function New-FakeLanguageList {
    param([string[]]$Tags)
    $l = New-Object 'System.Collections.Generic.List[Microsoft.InternationalSettings.Commands.WinUserLanguage]'
    foreach ($t in $Tags) { $l.Add([Microsoft.InternationalSettings.Commands.WinUserLanguage]::new($t)) }
    # Unary comma: a List must not be enumerated on its way out.
    return , $l
  }

  # Turns every command the steps can reach into a recorder. Call from BeforeEach.
  #   $script:calls        ordered, human-readable log of every mocked call
  #   $script:regValues    one hashtable per New-ItemProperty call; $script:regKeys the New-Item paths
  #   $script:logs         one hashtable per Write-SetupLog call
  #   $script:cimGet       the arguments of each Get-CimInstance call
  #   $script:cimCalls     one hashtable per Invoke-CimMethod call (Method, Arguments)
  #   $script:ext          one hashtable per Invoke-External call
  #   $script:statusSeq    GetConversionStatus answers, one per call; the last one repeats forever
  function Initialize-SystemMocks {
    $script:calls = New-Object System.Collections.ArrayList
    $script:regValues = New-Object System.Collections.ArrayList
    $script:regKeys = New-Object System.Collections.ArrayList
    $script:logs = New-Object System.Collections.ArrayList
    $script:cimGet = New-Object System.Collections.ArrayList
    $script:cimCalls = New-Object System.Collections.ArrayList
    $script:ext = New-Object System.Collections.ArrayList
    $script:existingKeys = @()
    $script:throwRegName = @()                  # New-ItemProperty throws for these value names

    # BitLocker
    $script:volume = New-FakeVolume             # what Get-CimInstance returns; $null = no volume
    $script:cimGetThrows = $false               # an invalid namespace / class
    $script:statusSeq = @(0)
    $script:statusCalls = 0
    $script:statusReturnValue = 0
    $script:decryptReturnValue = 0
    $script:decryptThrows = $false
    $script:disableReturnValue = 0
    $script:disableThrows = $false

    # Region
    $script:tzIds = New-Object System.Collections.ArrayList
    $script:tzThrows = $false
    $script:w32Status = 'Running'
    $script:startServiceThrows = $false
    $script:getServiceThrows = $false
    $script:w32ExitCode = 0
    $script:w32Throws = $false
    $script:langTags = @('he-IL', 'en-US')      # the "system" language list
    $script:langSets = New-Object System.Collections.ArrayList
    $script:langAdds = New-Object System.Collections.ArrayList
    $script:langGetThrows = $false
    $script:langSetThrowsFor = @()              # Set-WinUserLanguageList throws when this tag is in the new list

    # Bloatware
    $script:installed = @()                     # Get-AppxPackage names
    $script:provisioned = @()                   # Get-AppxProvisionedPackage display names
    $script:appxListThrows = $false
    $script:provListThrows = $false
    $script:failUserRemoval = @()               # names whose Remove-AppxPackage throws
    $script:failProvRemoval = @()               # names whose Remove-AppxProvisionedPackage throws
    $script:removedUser = New-Object System.Collections.ArrayList
    $script:removedProv = New-Object System.Collections.ArrayList
    $script:provOnlineFlags = New-Object System.Collections.ArrayList

    # Rename
    $script:pendingName = 'DESKTOP-ABC123'
    $script:pendingPaths = New-Object System.Collections.ArrayList
    $script:pendingThrows = $false
    $script:renames = New-Object System.Collections.ArrayList
    $script:renameThrows = $null

    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }

    # Registry: Set-RegistryDword uses Test-Path, New-Item and New-ItemProperty.
    Mock Test-Path { return ($script:existingKeys -contains $LiteralPath) }
    Mock New-Item { [void]$script:calls.Add("regkey $Path"); [void]$script:regKeys.Add([string]$Path); $script:existingKeys += [string]$Path }   # the key exists from now on, as in the registry
    Mock New-ItemProperty {
      [void]$script:calls.Add("regvalue $Name")
      if ($script:throwRegName -contains $Name) { throw 'Requested registry access is not allowed' }
      [void]$script:regValues.Add(@{ Path = [string]$LiteralPath; Name = $Name; Value = $Value; Type = [string]$PropertyType })
    }
    Mock Get-ItemProperty {
      [void]$script:pendingPaths.Add(@{ Path = [string]$LiteralPath; Name = ($Name -join ',') })
      if ($script:pendingThrows) { throw 'Cannot find path' }
      [pscustomobject]@{ ComputerName = $script:pendingName }
    }

    # BitLocker
    Mock Get-CimInstance {
      [void]$script:calls.Add('cim-get')
      [void]$script:cimGet.Add(@{ Namespace = $Namespace; ClassName = $ClassName; Filter = $Filter })
      if ($script:cimGetThrows) { throw 'Invalid namespace' }
      return $script:volume
    }
    Mock Invoke-CimMethod {
      [void]$script:calls.Add("cim-method $MethodName")
      [void]$script:cimCalls.Add(@{ Method = $MethodName; Arguments = $Arguments; Target = $InputObject })
      switch ($MethodName) {
        'GetConversionStatus' {
          $i = [Math]::Min($script:statusCalls, $script:statusSeq.Count - 1)
          $script:statusCalls++
          return [pscustomobject]@{ ReturnValue = [uint32]$script:statusReturnValue; ConversionStatus = [uint32]$script:statusSeq[$i] }
        }
        'Decrypt' {
          if ($script:decryptThrows) { throw 'Decrypt failed' }
          return [pscustomobject]@{ ReturnValue = [uint32]$script:decryptReturnValue }
        }
        'DisableKeyProtectors' {
          if ($script:disableThrows) { throw 'DisableKeyProtectors failed' }
          return [pscustomobject]@{ ReturnValue = [uint32]$script:disableReturnValue }
        }
        default { throw "UNEXPECTED CIM method $MethodName" }
      }
    }

    # Region
    Mock Set-TimeZone { [void]$script:calls.Add("timezone $Id"); [void]$script:tzIds.Add($Id); if ($script:tzThrows) { throw 'Access denied' } }
    Mock Get-Service {
      [void]$script:calls.Add("get-service $Name")
      if ($script:getServiceThrows) { throw 'Cannot find any service' }
      [pscustomobject]@{ Name = $Name; Status = $script:w32Status }
    }
    Mock Start-Service { [void]$script:calls.Add("start-service $Name"); if ($script:startServiceThrows) { throw 'Cannot start service' } }
    Mock Invoke-External {
      [void]$script:calls.Add("external $FilePath $ArgumentList")
      [void]$script:ext.Add(@{ File = $FilePath; Args = $ArgumentList; Timeout = $TimeoutMinutes; Capture = [bool]$CaptureOutput })
      if ($script:w32Throws) { throw "cannot start $FilePath" }
      return @{ ExitCode = $script:w32ExitCode; TimedOut = $false; Output = '' }
    }
    Mock Get-WinUserLanguageList {
      [void]$script:calls.Add('lang-get')
      if ($script:langGetThrows) { throw 'International settings unavailable' }
      return New-FakeLanguageList -Tags $script:langTags
    }
    Mock Set-WinUserLanguageList {
      $tags = @($LanguageList | ForEach-Object { $_.LanguageTag })
      [void]$script:calls.Add("lang-set $($tags -join ',')")
      [void]$script:langSets.Add(@{ Tags = $tags; Force = [bool]$Force })
      foreach ($bad in $script:langSetThrowsFor) { if ($tags -contains $bad) { throw "cannot add $bad" } }
      $script:langTags = $tags
    }

    # Bloatware
    Mock Get-AppxPackage {
      [void]$script:calls.Add("appx-list $Name")
      if ($script:appxListThrows) { throw 'Appx service unavailable' }
      foreach ($n in $script:installed) { if ((-not $Name) -or ($n -like $Name)) { New-FakeAppx -Name $n } }
    }
    Mock Get-AppxProvisionedPackage {
      [void]$script:calls.Add('prov-list')
      if ($script:provListThrows) { throw 'DISM unavailable' }
      foreach ($n in $script:provisioned) { [pscustomobject]@{ DisplayName = $n; PackageName = "${n}_1.0.0.0_neutral_~_8wekyb3d8bbwe" } }
    }
    Mock Remove-AppxPackage {
      $full = [string]$Package
      $short = ($full -split '_')[0]
      [void]$script:calls.Add("appx-remove $short")
      [void]$script:removedUser.Add($short)
      if ($script:failUserRemoval -contains $short) { throw "0x80073CFA removing $short" }
    }
    Mock Remove-AppxProvisionedPackage {
      $short = ($PackageName -split '_')[0]
      [void]$script:calls.Add("prov-remove $short")
      [void]$script:removedProv.Add($short)
      [void]$script:provOnlineFlags.Add([bool]$Online)
      if ($script:failProvRemoval -contains $short) { throw "0x80070002 removing $short" }
    }

    # Rename
    Mock Rename-Computer {
      [void]$script:calls.Add("rename $NewName")
      [void]$script:renames.Add(@{ NewName = $NewName; Force = [bool]$Force })
      if ($script:renameThrows) { throw $script:renameThrows }
    }

    # Things the steps must NOT do. Mocked so that a bug cannot touch the real machine.
    Mock Stop-Process { [void]$script:calls.Add('stop-process') }
    Mock Start-Process { [void]$script:calls.Add('start-process') }
    Mock Restart-Computer { [void]$script:calls.Add('restart-computer') }
    Mock Stop-Computer { [void]$script:calls.Add('stop-computer') }
  }

  function Get-CallIndex {
    param([string]$Pattern)
    for ($i = 0; $i -lt $script:calls.Count; $i++) { if ($script:calls[$i] -match $Pattern) { return $i } }
    return -1
  }
  function Get-RegWrite {
    param([string]$Name)
    @($script:regValues | Where-Object { $_.Name -eq $Name })
  }
  function Get-CimMethodCall {
    param([string]$Method)
    @($script:cimCalls | Where-Object { $_.Method -eq $Method })
  }
  function Get-LogEntry {
    param([string]$Level)
    @($script:logs | Where-Object { $_.Level -eq $Level })
  }
}

# ---------------------------------------------------------------------------------------------
# BitLocker
# ---------------------------------------------------------------------------------------------
Describe 'Get-BitLockerAction' {
  It '<s> -> <a>' -ForEach @(@{s=0;a='None'},@{s=1;a='Decrypt'},@{s=2;a='Decrypt'},@{s=3;a='Wait'},@{s=4;a='Decrypt'},@{s=5;a='Decrypt'}) { Get-BitLockerAction -ConversionStatus $s | Should -Be $a }
  It 'treats an unknown status as Decrypt, so the CIM return value decides rather than a silent skip' {
    Get-BitLockerAction -ConversionStatus 9 | Should -Be 'Decrypt'
  }
}

Describe 'Get-BitLockerConversionStatus' {
  BeforeEach { Initialize-SystemMocks }

  It 'queries the BitLocker namespace, Win32_EncryptableVolume and C:' {
    $script:statusSeq = @(1)
    Get-BitLockerConversionStatus | Should -Be 1
    $script:cimGet.Count | Should -Be 1
    $script:cimGet[0].Namespace | Should -Be 'root\cimv2\Security\MicrosoftVolumeEncryption'
    $script:cimGet[0].ClassName | Should -Be 'Win32_EncryptableVolume'
    $script:cimGet[0].Filter | Should -Be "DriveLetter='C:'"
  }
  It 'asks GetConversionStatus of that volume and returns the status as an int' {
    $script:statusSeq = @(3)
    $r = Get-BitLockerConversionStatus
    $r | Should -BeOfType [int]
    $r | Should -Be 3
    $calls = @(Get-CimMethodCall -Method 'GetConversionStatus')
    $calls.Count | Should -Be 1
    $calls[0].Target | Should -Be $script:volume
  }
  It 'returns 0 for a decrypted volume (0 is a status, not "missing")' {
    $script:statusSeq = @(0)
    $r = Get-BitLockerConversionStatus
    $null -eq $r | Should -BeFalse
    $r | Should -Be 0
  }
  It 'returns $null when the namespace or class is missing (the query throws)' {
    $script:cimGetThrows = $true
    $null -eq (Get-BitLockerConversionStatus) | Should -BeTrue
    @(Get-CimMethodCall -Method 'GetConversionStatus').Count | Should -Be 0
  }
  It 'returns $null when there is no matching volume' {
    $script:volume = $null
    $null -eq (Get-BitLockerConversionStatus) | Should -BeTrue
    $script:cimCalls.Count | Should -Be 0
  }
  It 'returns $null and logs a WARN when GetConversionStatus reports a non-zero ReturnValue' {
    $script:statusSeq = @(1)
    $script:statusReturnValue = $script:FveLockedVolume
    $null -eq (Get-BitLockerConversionStatus) | Should -BeTrue
    @(Get-LogEntry -Level 'WARN').Count | Should -BeGreaterThan 0
  }
}

Describe 'Invoke-StepBitLocker' {
  BeforeEach { Initialize-SystemMocks }

  It 'writes PreventDeviceEncryption = 1 (DWord) to the BitLocker policy key before it looks at the volume' {
    $script:volume = $null
    $null = Invoke-StepBitLocker -Context (New-SysContext)
    $w = @(Get-RegWrite -Name 'PreventDeviceEncryption')
    $w.Count | Should -Be 1
    $w[0].Path | Should -Be 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
    $w[0].Value | Should -Be 1
    $w[0].Type | Should -Be 'DWord'
    $script:calls.IndexOf('regvalue PreventDeviceEncryption') | Should -BeGreaterOrEqual 0
    $script:calls.IndexOf('cim-get') | Should -BeGreaterThan $script:calls.IndexOf('regvalue PreventDeviceEncryption')
    $script:calls[0] | Should -Be 'regkey HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'     # the registry comes first, nothing else before it
  }
  It 'creates the key only when it is missing' {
    $script:volume = $null
    $null = Invoke-StepBitLocker -Context (New-SysContext)
    $script:regKeys | Should -Contain $script:BitLockerKey
    Initialize-SystemMocks
    $script:volume = $null
    $script:existingKeys = @($script:BitLockerKey)
    $null = Invoke-StepBitLocker -Context (New-SysContext)
    $script:regKeys.Count | Should -Be 0
    @(Get-RegWrite -Name 'PreventDeviceEncryption').Count | Should -Be 1
  }
  It 'no BitLocker on the machine -> Done "BitLocker not present"; the registry value is still written' {
    $script:cimGetThrows = $true
    $r = Invoke-StepBitLocker -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'BitLocker not present'
    $r.Reboot | Should -Be 'None'
    @(Get-RegWrite -Name 'PreventDeviceEncryption').Count | Should -Be 1
    @(Get-CimMethodCall -Method 'Decrypt').Count | Should -Be 0
  }
  It 'status 0 (decrypted) -> Done "Not encrypted" and Decrypt is never called' {
    $script:statusSeq = @(0)
    $r = Invoke-StepBitLocker -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Not encrypted'
    @(Get-CimMethodCall -Method 'Decrypt').Count | Should -Be 0
    @(Get-RegWrite -Name 'PreventDeviceEncryption').Count | Should -Be 1
  }
  It 'status <s> -> Decrypt through CIM, Done "Decryption started"' -ForEach @(@{ s = 1 }, @{ s = 2 }, @{ s = 4 }, @{ s = 5 }) {
    $script:statusSeq = @($s)
    $r = Invoke-StepBitLocker -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Decryption started'
    $r.Reboot | Should -Be 'None'
    $d = @(Get-CimMethodCall -Method 'Decrypt')
    $d.Count | Should -Be 1
    $d[0].Target | Should -Be $script:volume
    @(Get-RegWrite -Name 'PreventDeviceEncryption').Count | Should -Be 1
  }
  It 'status 3 (already decrypting) -> Done "Decryption in progress" and Decrypt is not called again' {
    $script:statusSeq = @(3)
    $r = Invoke-StepBitLocker -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Decryption in progress'
    @(Get-CimMethodCall -Method 'Decrypt').Count | Should -Be 0
  }
  It 'a non-zero Decrypt ReturnValue -> Failed "BitLocker decrypt failed (0x80310000)"; the registry value was written first' {
    $script:statusSeq = @(1)
    $script:decryptReturnValue = $script:FveLockedVolume
    $r = Invoke-StepBitLocker -Context (New-SysContext)
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'BitLocker decrypt failed (0x80310000)'
    @(Get-RegWrite -Name 'PreventDeviceEncryption').Count | Should -Be 1
  }
  It 'a Decrypt call that throws -> Failed, not an exception' {
    $script:statusSeq = @(1)
    $script:decryptThrows = $true
    $r = Invoke-StepBitLocker -Context (New-SysContext)
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -BeLike 'BitLocker decrypt failed*'
  }
  It 'a registry write that is refused does not stop the step: it is a Note and BitLocker is still handled' {
    $script:throwRegName = @('PreventDeviceEncryption')
    $script:statusSeq = @(1)
    $r = Invoke-StepBitLocker -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Decryption started'
    @($r.Notes).Count | Should -Be 1
    @(Get-CimMethodCall -Method 'Decrypt').Count | Should -Be 1
  }
  It 'never restarts anything' {
    $script:statusSeq = @(1)
    $null = Invoke-StepBitLocker -Context (New-SysContext)
    ($script:calls -match 'restart|stop-computer').Count | Should -Be 0
  }
}

Describe 'Wait-BitLockerDecrypted' {
  BeforeEach { Initialize-SystemMocks }

  It 'is true at once when the volume is already decrypted (status 0)' {
    $script:statusSeq = @(0)
    Wait-BitLockerDecrypted -TimeoutMinutes 1 -PollSeconds 0.01 | Should -BeTrue
    $script:statusCalls | Should -Be 1
  }
  It 'is true at once when there is no BitLocker at all (status $null)' {
    $script:volume = $null
    Wait-BitLockerDecrypted -TimeoutMinutes 1 -PollSeconds 0.01 | Should -BeTrue
  }
  It 'polls while the status is 3 and is true as soon as it reaches 0' {
    $script:statusSeq = @(3, 3, 0)
    Wait-BitLockerDecrypted -TimeoutMinutes 1 -PollSeconds 0.01 | Should -BeTrue
    $script:statusCalls | Should -Be 3
  }
  It 'is false when the status stays 3 until the timeout' {
    $script:statusSeq = @(3)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Wait-BitLockerDecrypted -TimeoutMinutes 0.003 -PollSeconds 0.02 | Should -BeFalse
    $clock.Stop()
    $script:statusCalls | Should -BeGreaterThan 1
    $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
  }
  It 'is false at once, without polling again, when the status is <s> (not decrypting)' -ForEach @(@{ s = 1 }, @{ s = 2 }, @{ s = 4 }, @{ s = 5 }) {
    $script:statusSeq = @($s)
    Wait-BitLockerDecrypted -TimeoutMinutes 1 -PollSeconds 0.01 | Should -BeFalse
    $script:statusCalls | Should -Be 1
  }
  It 'is false when decryption starts (3) and then stops (4)' {
    $script:statusSeq = @(3, 4)
    Wait-BitLockerDecrypted -TimeoutMinutes 1 -PollSeconds 0.01 | Should -BeFalse
    $script:statusCalls | Should -Be 2
  }
  It 'polls every 30 seconds unless told otherwise' {
    $param = (Get-Command Wait-BitLockerDecrypted).ScriptBlock.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PollSeconds' }
    $param.DefaultValue.Extent.Text | Should -Be '30'
  }
}

Describe 'Suspend-BitLockerOnce' {
  BeforeEach { Initialize-SystemMocks }

  It 'calls DisableKeyProtectors with DisableCount = [uint32]1 on an encrypted volume and returns $true' {
    $script:statusSeq = @(1)
    $r = Suspend-BitLockerOnce
    $r | Should -BeOfType [bool]
    $r | Should -BeTrue
    $d = @(Get-CimMethodCall -Method 'DisableKeyProtectors')
    $d.Count | Should -Be 1
    $d[0].Target | Should -Be $script:volume
    $d[0].Arguments.Count | Should -Be 1
    $d[0].Arguments['DisableCount'] | Should -BeOfType [uint32]
    $d[0].Arguments['DisableCount'] | Should -Be 1
  }
  It 'returns $false for a non-zero ReturnValue' {
    $script:statusSeq = @(1)
    $script:disableReturnValue = $script:FveLockedVolume
    Suspend-BitLockerOnce | Should -BeFalse
  }
  It 'returns $false and does not throw when the call throws' {
    $script:statusSeq = @(1)
    $script:disableThrows = $true
    { Suspend-BitLockerOnce } | Should -Not -Throw
    Suspend-BitLockerOnce | Should -BeFalse
  }
  It 'has nothing to suspend (and says so with $true) when there is no BitLocker' {
    $script:volume = $null
    Suspend-BitLockerOnce | Should -BeTrue
    @(Get-CimMethodCall -Method 'DisableKeyProtectors').Count | Should -Be 0
  }
  It 'has nothing to suspend on a decrypted volume' {
    $script:statusSeq = @(0)
    Suspend-BitLockerOnce | Should -BeTrue
    @(Get-CimMethodCall -Method 'DisableKeyProtectors').Count | Should -Be 0
  }
}

# ---------------------------------------------------------------------------------------------
# Region
# ---------------------------------------------------------------------------------------------
Describe 'Merge-LanguageTags' {
  It 'Hebrew-only Windows gets English appended' { Merge-LanguageTags -Existing @('he-IL') | Should -Be @('he-IL','en-US') }
  It 'English-only gets Hebrew appended' { Merge-LanguageTags -Existing @('en-US') | Should -Be @('en-US','he-IL') }
  It 'en-GB counts as English' { Merge-LanguageTags -Existing @('en-GB') | Should -Be @('en-GB','he-IL') }
  It 'no change when both exist' { Merge-LanguageTags -Existing @('he-IL','en-US') | Should -Be @('he-IL','en-US') }
  It 'keeps the existing order and appends English before Hebrew' { Merge-LanguageTags -Existing @('fr-FR', 'de-DE') | Should -Be @('fr-FR', 'de-DE', 'en-US', 'he-IL') }
  It 'an empty or null list gets both' {
    Merge-LanguageTags -Existing @() | Should -Be @('en-US', 'he-IL')
    Merge-LanguageTags -Existing $null | Should -Be @('en-US', 'he-IL')
  }
  It 'matches the language case-insensitively' { Merge-LanguageTags -Existing @('HE-il', 'EN-gb') | Should -Be @('HE-il', 'EN-gb') }
  It 'a bare language tag counts' { Merge-LanguageTags -Existing @('he', 'en') | Should -Be @('he', 'en') }
}

Describe 'Invoke-StepRegion' {
  BeforeEach { Initialize-SystemMocks }

  It 'sets the time zone with exactly Set-TimeZone -Id "Israel Standard Time"' {
    $null = Invoke-StepRegion -Context (New-SysContext)
    $script:tzIds.Count | Should -Be 1
    $script:tzIds[0] | Should -Be 'Israel Standard Time'
  }
  It 'happy path: Done with no notes' {
    $r = Invoke-StepRegion -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    @($r.Notes).Count | Should -Be 0
  }
  It 'w32time already running: no Start-Service, then w32tm.exe /resync /force with a 2 minute limit' {
    $null = Invoke-StepRegion -Context (New-SysContext)
    ($script:calls -match '^start-service').Count | Should -Be 0
    $script:ext.Count | Should -Be 1
    $script:ext[0].File | Should -Be "$env:windir\System32\w32tm.exe"
    $script:ext[0].Args | Should -Be '/resync /force'
    $script:ext[0].Timeout | Should -Be 2
    $script:ext[0].Capture | Should -BeTrue
  }
  It 'w32time not running: Start-Service w32time first, then the resync' {
    $script:w32Status = 'Stopped'
    $null = Invoke-StepRegion -Context (New-SysContext)
    $start = $script:calls.IndexOf('start-service w32time')
    $start | Should -BeGreaterOrEqual 0
    $start | Should -BeLessThan (Get-CallIndex -Pattern '^external ')
  }
  It 'a non-zero w32tm exit code is logged only: still Done, no note' {
    $script:w32ExitCode = 1
    $r = Invoke-StepRegion -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes).Count | Should -Be 0
    @(Get-LogEntry -Level 'WARN').Count | Should -BeGreaterThan 0
  }
  It 'a time service that cannot be started or run is logged only, and the language step still runs' {
    $script:w32Status = 'Stopped'
    $script:startServiceThrows = $true
    $script:langTags = @('he-IL')
    $r = Invoke-StepRegion -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes).Count | Should -Be 0
    $script:langSets.Count | Should -Be 1
    Initialize-SystemMocks
    $script:w32Throws = $true
    $r = Invoke-StepRegion -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes).Count | Should -Be 0
  }
  It 'Hebrew + English already there: the language list is not touched' {
    $script:langTags = @('he-IL', 'en-US')
    $null = Invoke-StepRegion -Context (New-SysContext)
    $script:langSets.Count | Should -Be 0
  }
  It 'Hebrew-only: English is ADDED to the list that was read, keeping he-IL first; Set-WinUserLanguageList -Force' {
    $script:langTags = @('he-IL')
    $null = Invoke-StepRegion -Context (New-SysContext)
    $script:langSets.Count | Should -Be 1
    $script:langSets[0].Tags | Should -Be @('he-IL', 'en-US')
    $script:langSets[0].Force | Should -BeTrue
  }
  It 'English-only: Hebrew is appended' {
    $script:langTags = @('en-US')
    $null = Invoke-StepRegion -Context (New-SysContext)
    $script:langSets.Count | Should -Be 1
    $script:langSets[0].Tags | Should -Be @('en-US', 'he-IL')
  }
  It 'neither: each missing tag is added to a freshly read list, one Set call per tag, nothing rebuilt' {
    $script:langTags = @('fr-FR')
    $null = Invoke-StepRegion -Context (New-SysContext)
    $script:langSets.Count | Should -Be 2
    $script:langSets[0].Tags | Should -Be @('fr-FR', 'en-US')
    $script:langSets[1].Tags | Should -Be @('fr-FR', 'en-US', 'he-IL')
    $script:langTags | Should -Be @('fr-FR', 'en-US', 'he-IL')
  }
  It 'Set-TimeZone failing -> Done with the Note "Time zone could not be set"; the rest still runs' {
    $script:tzThrows = $true
    $script:langTags = @('he-IL')
    $r = Invoke-StepRegion -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes) | Should -Be @('Time zone could not be set')
    $script:ext.Count | Should -Be 1
    $script:langSets.Count | Should -Be 1
  }
  It 'the Hebrew keyboard failing -> Done with the Note "Hebrew keyboard could not be added"' {
    $script:langTags = @('en-US')
    $script:langSetThrowsFor = @('he-IL')
    $r = Invoke-StepRegion -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes) | Should -Be @('Hebrew keyboard could not be added')
  }
  It 'an unreadable language list -> Done with a Note, never Failed' {
    $script:langGetThrows = $true
    $r = Invoke-StepRegion -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes).Count | Should -Be 1
    $script:langSets.Count | Should -Be 0
  }
  It 'English failing while Hebrew is also missing: English gets its own Note and Hebrew is still tried' {
    $script:langTags = @('fr-FR')
    $script:langSetThrowsFor = @('en-US')
    $r = Invoke-StepRegion -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes) | Should -Be @('English keyboard could not be added')
    $script:langSets.Count | Should -Be 2
  }
}

# ---------------------------------------------------------------------------------------------
# Desktop icons
# ---------------------------------------------------------------------------------------------
Describe 'Invoke-StepDesktopIcons' {
  BeforeEach { Initialize-SystemMocks }

  It 'shows This PC and the user''s files under both NewStartPanel and ClassicStartMenu (HKCU DWord 0)' {
    $r = Invoke-StepDesktopIcons -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes).Count | Should -Be 0
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons'
    $script:regValues.Count | Should -Be 4
    foreach ($key in "$base\NewStartPanel", "$base\ClassicStartMenu") {
      foreach ($guid in '{20D04FE0-3AEA-1069-A2D8-08002B30309D}', '{59031a47-3f72-44a7-89c5-5595fe6b30ee}') {
        $w = @($script:regValues | Where-Object { $_.Path -eq $key -and $_.Name -eq $guid })
        $w.Count | Should -Be 1 -Because "$key $guid"
        $w[0].Value | Should -Be 0
        $w[0].Type | Should -Be 'DWord'
      }
    }
  }
  It 'creates a missing key and leaves an existing one alone' {
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons'
    $script:existingKeys = @("$base\NewStartPanel")
    $null = Invoke-StepDesktopIcons -Context (New-SysContext)
    @($script:regKeys) | Should -Be @("$base\ClassicStartMenu")
  }
  It 'does not restart Explorer or anything else' {
    $null = Invoke-StepDesktopIcons -Context (New-SysContext)
    ($script:calls -match '^(stop-process|start-process|restart-computer|stop-computer)').Count | Should -Be 0
  }
  It 'a refused write -> Done with the Note "Desktop icons could not be set"; every value is still tried' {
    $script:throwRegName = @('{20D04FE0-3AEA-1069-A2D8-08002B30309D}')
    $r = Invoke-StepDesktopIcons -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes) | Should -Be @('Desktop icons could not be set')
    $script:regValues.Count | Should -Be 2       # the two user's-files writes still happened
  }
}

# ---------------------------------------------------------------------------------------------
# Bloatware
# ---------------------------------------------------------------------------------------------
Describe 'Select-BloatwareToRemove' {
  It 'removes junk, never protected' {
    $r = Select-BloatwareToRemove -PackageNames @('king.com.CandyCrushSaga','Microsoft.WindowsCalculator','Microsoft.XboxGamingOverlay','MicrosoftTeams','MSTeams') -RemovePatterns @('king.com.*','*CandyCrush*','MicrosoftTeams','Microsoft.Xbox*') -ProtectPatterns @('Microsoft.WindowsCalculator','Microsoft.Xbox*','MSTeams')
    $r | Should -Be @('king.com.CandyCrushSaga','MicrosoftTeams')
  }
  It 'keeps the input order' {
    $r = Select-BloatwareToRemove -PackageNames @('b.junk', 'a.junk', 'c.keep', 'z.junk') -RemovePatterns @('*.junk') -ProtectPatterns @()
    $r | Should -Be @('b.junk', 'a.junk', 'z.junk')
  }
  It 'returns a plain array of strings, and nothing for nothing' {
    $r = @(Select-BloatwareToRemove -PackageNames @('king.com.CandyCrushSaga') -RemovePatterns @('king.com.*') -ProtectPatterns @())
    $r.Count | Should -Be 1
    $r[0] | Should -BeOfType [string]
    @(Select-BloatwareToRemove -PackageNames @('Microsoft.WindowsCalculator') -RemovePatterns @('king.com.*') -ProtectPatterns @()).Count | Should -Be 0
    @(Select-BloatwareToRemove -PackageNames @() -RemovePatterns @('*') -ProtectPatterns @()).Count | Should -Be 0
    @(Select-BloatwareToRemove -PackageNames $null -RemovePatterns @('*') -ProtectPatterns $null).Count | Should -Be 0
  }
  It 'protect wins over remove, case-insensitively' {
    @(Select-BloatwareToRemove -PackageNames @('MICROSOFT.XBOXAPP') -RemovePatterns @('microsoft.xbox*') -ProtectPatterns @('Microsoft.Xbox*')).Count | Should -Be 0
  }
  It 'no remove patterns means nothing is removed' {
    @(Select-BloatwareToRemove -PackageNames @('king.com.CandyCrushSaga') -RemovePatterns @() -ProtectPatterns @()).Count | Should -Be 0
  }
}

Describe 'Invoke-StepBloatware' {
  BeforeEach { Initialize-SystemMocks }

  It 'removes the matching user and provisioned packages, never the protected ones, and counts them' {
    $script:installed = @('king.com.CandyCrushSaga', 'Microsoft.WindowsCalculator', 'MicrosoftTeams', 'MSTeams', 'Contoso.Keep')
    $script:provisioned = @('king.com.CandyCrushSaga', 'Microsoft.WindowsCalculator', 'MicrosoftTeams', 'MSTeams')
    $ctx = New-SysContext -Remove @('king.com.*', 'MicrosoftTeams', 'Microsoft.WindowsCalculator') -Protect @('Microsoft.WindowsCalculator', 'MSTeams')
    $r = Invoke-StepBloatware -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Removed 2 packages'
    @($r.Notes).Count | Should -Be 0
    @($script:removedUser) | Should -Be @('king.com.CandyCrushSaga', 'MicrosoftTeams')
    @($script:removedProv) | Should -Be @('king.com.CandyCrushSaga', 'MicrosoftTeams')
    $script:removedUser | Should -Not -Contain 'Microsoft.WindowsCalculator'
    $script:removedUser | Should -Not -Contain 'MSTeams'
    $script:removedProv | Should -Not -Contain 'Microsoft.WindowsCalculator'
    $script:removedProv | Should -Not -Contain 'MSTeams'
    $script:provOnlineFlags | Should -Not -Contain $false
  }
  It 'collects names from both lists, once each, and looks each one up by -Name' {
    $script:installed = @('king.com.CandyCrushSaga')
    $script:provisioned = @('king.com.CandyCrushSaga', 'MicrosoftTeams')
    $r = Invoke-StepBloatware -Context (New-SysContext)
    $r.Message | Should -Be 'Removed 2 packages'
    ($script:calls -match '^appx-list king\.com\.CandyCrushSaga$').Count | Should -Be 1
    ($script:calls -match '^appx-list MicrosoftTeams$').Count | Should -Be 1
    @($script:removedUser) | Should -Be @('king.com.CandyCrushSaga')           # MicrosoftTeams is provisioned only
    @($script:removedProv) | Should -Be @('king.com.CandyCrushSaga', 'MicrosoftTeams')
  }
  It 'with the shipping config, none of the protected apps is touched' {
    $cfg = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $keep = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.Windows.Photos', 'Microsoft.WindowsCalculator',
      'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.ScreenSketch', 'Microsoft.WindowsCamera', 'Microsoft.ZuneMusic',
      'Microsoft.WindowsTerminal', 'Microsoft.OutlookForWindows', 'Microsoft.MicrosoftEdge.Stable', 'Microsoft.Copilot',
      'Microsoft.XboxGamingOverlay', 'Microsoft.GamingApp', 'Microsoft.VCLibs.140.00', 'Microsoft.UI.Xaml.2.8',
      'Microsoft.NET.Native.Runtime.2.2', 'Microsoft.WindowsAppRuntime.1.5', 'MSTeams')
    $junk = @('king.com.CandyCrushSaga', 'SpotifyAB.SpotifyMusic', 'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'MicrosoftTeams')
    $script:installed = $keep + $junk
    $script:provisioned = $keep + $junk
    $ctx = New-SysContext
    $ctx.Config = $cfg
    $result = Invoke-StepBloatware -Context $ctx
    $result.Status | Should -Be 'Done'
    @($script:removedUser | Where-Object { $_ -in $keep }).Count | Should -Be 0
    @($script:removedProv | Where-Object { $_ -in $keep }).Count | Should -Be 0
    @($script:removedUser | Sort-Object) | Should -Be @($junk | Sort-Object)
    $result.Message | Should -Be "Removed $($junk.Count) packages"
  }
  It 'counts the packages that failed: Done, "Removed N packages" for the rest, and one Note' {
    $script:installed = @('king.com.CandyCrushSaga', 'king.com.Other', 'MicrosoftTeams')
    $script:provisioned = @('king.com.CandyCrushSaga', 'king.com.Other', 'MicrosoftTeams')
    $script:failUserRemoval = @('king.com.Other')
    $r = Invoke-StepBloatware -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Removed 2 packages'
    @($r.Notes) | Should -Be @('Bloatware: 1 packages could not be removed')
    @(Get-LogEntry -Level 'WARN').Count | Should -BeGreaterOrEqual 1
  }
  It 'a package that fails both ways is one failure, and the other packages are still removed' {
    $script:installed = @('king.com.A', 'king.com.B', 'MicrosoftTeams')
    $script:provisioned = @('king.com.A', 'king.com.B', 'MicrosoftTeams')
    $script:failUserRemoval = @('king.com.A')
    $script:failProvRemoval = @('king.com.A', 'MicrosoftTeams')
    $r = Invoke-StepBloatware -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Removed 1 packages'
    @($r.Notes) | Should -Be @('Bloatware: 2 packages could not be removed')
    $script:removedUser | Should -Contain 'king.com.B'
    @(Get-LogEntry -Level 'WARN').Count | Should -BeGreaterOrEqual 2          # one WARN per failure, none swallowed
  }
  It 'nothing to remove -> Done "Removed 0 packages", no Note, no removal call' {
    $script:installed = @('Microsoft.WindowsCalculator', 'Contoso.Keep')
    $script:provisioned = @('Microsoft.WindowsCalculator')
    $r = Invoke-StepBloatware -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Removed 0 packages'
    @($r.Notes).Count | Should -Be 0
    $script:removedUser.Count | Should -Be 0
    $script:removedProv.Count | Should -Be 0
  }
  It 'an unreadable app list is a Note, not a failure, and removes what the other list shows' {
    $script:appxListThrows = $true
    $script:provisioned = @('MicrosoftTeams', 'Contoso.Keep')
    $r = Invoke-StepBloatware -Context (New-SysContext)
    $r.Status | Should -Be 'Done'
    @($r.Notes).Count | Should -BeGreaterOrEqual 1
    @($script:removedProv) | Should -Be @('MicrosoftTeams')
  }
  It 'never restarts anything' {
    $script:installed = @('MicrosoftTeams')
    $null = Invoke-StepBloatware -Context (New-SysContext)
    ($script:calls -match '^(restart-computer|stop-computer|stop-process)').Count | Should -Be 0
  }
}

# ---------------------------------------------------------------------------------------------
# Rename
# ---------------------------------------------------------------------------------------------
Describe 'Get-PendingComputerName' {
  BeforeEach { Initialize-SystemMocks }

  It 'reads ComputerName from ComputerName\ComputerName (the NEXT name, not ActiveComputerName)' {
    $script:pendingName = 'DELL-7HX2K93'
    Get-PendingComputerName | Should -Be 'DELL-7HX2K93'
    $script:pendingPaths.Count | Should -Be 1
    $script:pendingPaths[0].Path | Should -Be 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
    $script:pendingPaths[0].Name | Should -Be 'ComputerName'
  }
  It 'falls back to the running name when the value cannot be read' {
    $script:pendingThrows = $true
    Get-PendingComputerName | Should -Be $env:COMPUTERNAME
    @(Get-LogEntry -Level 'WARN').Count | Should -BeGreaterThan 0
  }
}

Describe 'Invoke-StepRename' {
  BeforeEach { Initialize-SystemMocks }

  It 'no target name -> Skipped "No target name"' {
    foreach ($ctx in (New-SysContext -NewName ''), (New-SysContext -NoMachine)) {
      $r = Invoke-StepRename -Context $ctx
      $r.Status | Should -Be 'Skipped'
      $r.Message | Should -Be 'No target name'
    }
    $script:renames.Count | Should -Be 0
  }
  It 'name already pending -> Done "Name already set" and no rename (compared without case)' {
    $script:pendingName = 'dell-7hx2k93'
    $r = Invoke-StepRename -Context (New-SysContext -NewName 'DELL-7HX2K93')
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Name already set'
    $script:renames.Count | Should -Be 0
  }
  It 'a different name -> Rename-Computer -NewName <target> -Force, Done "Renamed to <target> (applies after restart)"' {
    $script:pendingName = 'DESKTOP-ABC123'
    $r = Invoke-StepRename -Context (New-SysContext -NewName 'DELL-7HX2K93')
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Renamed to DELL-7HX2K93 (applies after restart)'
    $r.Reboot | Should -Be 'None'
    $script:renames.Count | Should -Be 1
    $script:renames[0].NewName | Should -Be 'DELL-7HX2K93'
    $script:renames[0].Force | Should -BeTrue
  }
  It 'a rename that throws -> Failed "Rename failed: <message>"' {
    $script:renameThrows = 'The new name is not valid'
    $r = Invoke-StepRename -Context (New-SysContext -NewName 'DELL-7HX2K93')
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Rename failed: The new name is not valid'
  }
  It 'never restarts the machine itself' {
    $null = Invoke-StepRename -Context (New-SysContext -NewName 'DELL-7HX2K93')
    ($script:calls -match '^(restart-computer|stop-computer)').Count | Should -Be 0
  }
}
