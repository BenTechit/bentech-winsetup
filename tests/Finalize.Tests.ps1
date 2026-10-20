# tests/Finalize.Tests.ps1
# Task 16: the Finalize step (spec 8.3 step 17, 8.4, 12) and the setup report (spec 8.7).
#
# SAFETY: this runs on Ben's real PC, and Finalize changes power settings, removes registry policy
# values, unregisters the resume task, reads BitLocker and activation, and deletes files. Nothing here
# may do any of that outside $TestDrive. Every Finalize test runs after Initialize-FinalizeMocks (each
# Describe calls it from BeforeEach), which replaces every system command the step can reach with a
# recorder: Restore-FinalPowerSettings, Get-PendingRebootSignals, Get-LastBootUtc, Test-ChromeInstalled,
# Get-DefaultBrowserProgId, Get-DefaultAssociationsPath (pointed into $TestDrive),
# Remove-LenovoAdminCommandLine, Get-ActivationStatus, Get-SmartAppControlState, Get-BitLockerState, Unregister-ResumeTask,
# Get-InstalledAppVersions, Get-ItemProperty, Remove-ItemProperty, Start-Sleep, the read-only
# SoftwareLicensingProduct query and Write-SetupLog. As a safety net, New-Item, New-ItemProperty,
# Set-ItemProperty, Invoke-External, Invoke-PowerShellChild (the activation attempt), Register-ScheduledTask,
# Unregister-ScheduledTask, Restart-Computer, any other Get-CimInstance and Invoke-CimMethod throw (and are
# recorded), and so does Remove-Item for any path outside $TestDrive; AfterEach asserts that nothing
# was blocked. The only real file I/O is inside $TestDrive: the fake working folder (Downloads,
# setup.ps1, config.json, state.json, Logs), the fake ProgramData XML and the report.
# The collector tests (Get-ActivationStatus, Get-InstalledAppVersions, Get-LastBootUtc) mock
# Get-CimInstance / Get-ItemProperty themselves, so they read nothing real either.
BeforeAll { foreach ($f in 'Common\StepResult','State\State','Engine\Catalog','Engine\Verdict','Engine\Reboot','Report\Report','Steps\Finalize') { . "$PSScriptRoot\..\src\$f.ps1" }
  # The helpers Finalize and the report reuse (the bundle holds every file), and the runner for the end-to-end tests.
  foreach ($f in 'Common\Logging','Common\Activity','Common\Process','Engine\Runner','UI\StartScreen','Steps\Prepare','Steps\Apps','Steps\Office','Steps\DefaultBrowser','Steps\BitLocker','Steps\Vendor','Steps\Winget') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:st = New-RunState -Machine @{ Manufacturer='Dell Inc.'; FriendlyModel='Latitude 5440'; Serial='7HX2K93'; ComputerName='DESKTOP-AB12'; NewName='DELL-7HX2K93'; OsCaption='Windows 11 Pro'; OsDisplayVersion='25H2'; OsBuild=26200; Arch='x64'; IsLaptop=$true; IsVM=$false } -Choices @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'} -Plan @('chrome') -Version '2026.10.18.1'
  $st.StartedAt = '2026-10-18T09:05:00'; $st.EndedAt = '2026-10-18T10:17:00'; $st.AnyDeskId = '123456789'; $st.Steps.chrome.Status = 'Done'

  $script:AuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  $script:SystemPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
  $script:Hebrew = [string]::new([char[]]@(0x05E2, 0x05D3, 0x05DB, 0x05D5))   # four Hebrew letters
  $script:noSignals = @{ CbsRebootPending = $false; WuRebootRequired = $false; PendingFileRename = $false; ComputerRenamePending = $false }

  # The machine of every Finalize test: a Dell laptop on Windows 11.
  $script:fm = @{ Manufacturer = 'Dell Inc.'; FriendlyModel = 'Latitude 5440'; Serial = '7HX2K93'; Brand = 'DELL'; ComputerName = 'DESKTOP-AB12'
    NewName = 'DELL-7HX2K93'; OsCaption = 'Windows 11 Pro'; OsDisplayVersion = '25H2'; OsBuild = 26200; Arch = 'x64'
    IsLaptop = $true; IsVM = $false; IsWindows10 = $false }

  # $true when Path is inside the current $TestDrive. A registry path (HKLM:\...) is not.
  function Test-InTestDrive {
    param($Path)
    if ([string]::IsNullOrEmpty([string]$Path)) { return $false }
    try {
      $rootPath = [IO.Path]::GetFullPath($TestDrive).TrimEnd('\') + '\'
      return [IO.Path]::GetFullPath([string]$Path).StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
  }

  # A fake working folder in $TestDrive with Downloads (nested), setup.ps1, config.json, state.json and
  # Logs, and a run state whose plan steps are all Done except finalize (running, as the runner leaves
  # it). -PhaseB starts with FinalRebootDone set, so the call goes straight to Phase B.
  function New-FinalizeContext {
    param(
      [hashtable]$Machine = $script:fm,
      [string[]]$Plan = @('chrome', 'finalize'),
      [switch]$PhaseB,
      [int]$RebootCount = 0,
      [int]$MaxReboots = 12
    )
    $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    foreach ($d in 'Logs', 'Downloads\sub') { [void][IO.Directory]::CreateDirectory((Join-Path $dir $d)) }
    foreach ($f in 'Downloads\ChromeSetup.msi', 'Downloads\sub\odt.exe', 'setup.ps1', 'config.json', 'Logs\setup.log') {
      [IO.File]::WriteAllText((Join-Path $dir $f), 'x')
    }
    $state = New-RunState -Machine $Machine.Clone() -Choices @{ Mode = 'LAPTOP'; SevenZip = $false; Office = 'OFF' } -Plan $Plan -Version '2026.10.18.1'
    foreach ($id in $Plan) {
      if ($id -ne 'finalize') { $state.Steps[$id].Status = 'Done'; $state.Steps[$id].Message = 'ok' }
    }
    $state.Steps['finalize'].Status = 'running'
    $state.RebootCount = $RebootCount
    $state.FinalRebootDone = [bool]$PhaseB
    Save-RunState -State $state -Root $dir
    @{
      Config      = [pscustomobject]@{
        caps  = [pscustomobject]@{ maxReboots = $MaxReboots; maxStepAttempts = 3 }
        power = [pscustomobject]@{ finalAcMonitorMinutes = 15 }
      }
      State       = $state
      Root        = $dir
      LogDir      = (Join-Path $dir 'Logs')
      DownloadDir = (Join-Path $dir 'Downloads')
      ScriptPath  = (Join-Path $dir 'setup.ps1')
      StatePath   = (Join-Path $dir 'state.json')
    }
  }

  # The report Finalize wrote, as lines (the BOM is dropped by ReadAllLines).
  function Get-ReportLines {
    param([Parameter(Mandatory)][hashtable]$Context)
    [IO.File]::ReadAllLines((Join-Path $Context.LogDir 'Setup-Report.txt'), [Text.Encoding]::UTF8)
  }

  # Replaces every system command Finalize can reach with a recorder. Call from BeforeEach.
  #   $script:logs            one hashtable per Write-SetupLog call
  #   $script:restoreResult   what Restore-FinalPowerSettings answers ($script:restoreThrows: it throws); $script:restoreCalls counts
  #   $script:signals         what Get-PendingRebootSignals answers
  #   $script:lastBoot        what Get-LastBootUtc answers (UTC)
  #   $script:chromeInstalled / $script:progId   Test-ChromeInstalled / Get-DefaultBrowserProgId
  #   $script:assocPath       Get-DefaultAssociationsPath (a fresh folder in $TestDrive)
  #   $script:lenovoCalls / $script:unregisterCalls   Remove-LenovoAdminCommandLine / Unregister-ResumeTask calls
  #   $script:unregisterResult  what Unregister-ResumeTask answers ($true: the task is gone)
  #   $script:activation      what Get-ActivationStatus answers
  #   $script:smartAppControl what Get-SmartAppControlState answers
  #   $script:bitlocker       what Get-BitLockerState answers ($script:bitlockerThrows: it throws)
  #   $script:apps            what Get-InstalledAppVersions answers
  #   $script:regPresent      registry path -> hashtable of values, for Get-ItemProperty
  #   $script:regRemoved      one @{ Path; Name } per Remove-ItemProperty call ($script:regRemoveThrows: it throws)
  #   $script:sleeps          one Seconds value per Start-Sleep call (nothing here ever waits)
  #   $script:licensingProducts what the read-only SoftwareLicensingProduct query answers (default: no
  #                           product key, so the activation attempt has nothing to do)
  #   $script:blocked         every call the safety net refused (must stay empty)
  function Initialize-FinalizeMocks {
    $script:logs = New-Object System.Collections.ArrayList
    $script:restoreResult = $true
    $script:restoreThrows = $false
    $script:restoreCalls = 0
    $script:signals = $script:noSignals.Clone()
    $script:lastBoot = [datetime]::new(2026, 10, 18, 6, 0, 0, [DateTimeKind]::Utc)
    $script:chromeInstalled = $true
    $script:progId = 'ChromeHTML'
    $script:assocPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\BenTech\DefaultAssociations.xml')
    $script:lenovoCalls = 0
    $script:unregisterCalls = 0
    $script:unregisterResult = $true
    $script:activation = 'Activated'
    $script:smartAppControl = 'Off'
    $script:bitlocker = @{ Presence = 'Present'; Volume = $null; Status = 0 }
    $script:bitlockerThrows = $false
    $script:apps = @{ 'Google Chrome' = '155.0.8059.85'; 'AnyDesk' = '9.5.3' }
    $script:regPresent = @{}
    $script:regRemoved = New-Object System.Collections.ArrayList
    $script:regRemoveThrows = $false
    $script:sleeps = New-Object System.Collections.ArrayList
    $script:licensingProducts = @()
    $script:blocked = New-Object System.Collections.ArrayList

    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    Mock Start-Sleep { [void]$script:sleeps.Add($Seconds) }
    Mock Restore-FinalPowerSettings {
      $script:restoreCalls++
      if ($script:restoreThrows) { throw 'powercfg exploded' }
      return $script:restoreResult
    }
    Mock Get-PendingRebootSignals { return $script:signals.Clone() }
    Mock Get-LastBootUtc { return $script:lastBoot }
    Mock Test-ChromeInstalled { return $script:chromeInstalled }
    Mock Get-DefaultBrowserProgId { return $script:progId }
    Mock Get-DefaultAssociationsPath { return $script:assocPath }
    Mock Remove-LenovoAdminCommandLine { $script:lenovoCalls++ }
    Mock Get-ActivationStatus { return $script:activation }
    Mock Get-SmartAppControlState { return $script:smartAppControl }
    Mock Get-BitLockerState {
      if ($script:bitlockerThrows) { throw 'WMI is down' }
      return $script:bitlocker
    }
    Mock Unregister-ResumeTask { $script:unregisterCalls++; return $script:unregisterResult }
    Mock Get-InstalledAppVersions { return $script:apps }
    Mock Get-ItemProperty {
      $values = $script:regPresent[[string]$LiteralPath]
      $wanted = [string]@($Name)[0]
      if ($null -eq $values -or -not $values.ContainsKey($wanted)) { return $null }
      return [pscustomobject]$values
    }
    Mock Remove-ItemProperty {
      if ($script:regRemoveThrows) { Write-Error -Message 'Requested registry access is not allowed' -Category PermissionDenied; return }
      [void]$script:regRemoved.Add(@{ Path = [string]$LiteralPath; Name = [string]@($Name)[0] })
      $values = $script:regPresent[[string]$LiteralPath]
      if ($null -ne $values) { $values.Remove([string]@($Name)[0]) }
    }

    # The safety net: anything below is a bug in the code under test (or a missing mock).
    # Pester 6 never falls through to the real command, so deletions inside $TestDrive are forwarded
    # to the real cmdlet explicitly; the filtered mock below refuses every other path.
    Mock Remove-Item { & (Get-Command Remove-Item -CommandType Cmdlet) @PesterBoundParameters }
    Mock Remove-Item { [void]$script:blocked.Add("Remove-Item $(@($LiteralPath) + @($Path) -join ', ')"); throw 'blocked by the test: outside TestDrive' } -ParameterFilter {
      $all = @(@($LiteralPath) + @($Path) | Where-Object { $_ })
      ($all.Count -eq 0) -or (@($all | Where-Object { -not (Test-InTestDrive $_) }).Count -gt 0)
    }
    Mock New-Item { [void]$script:blocked.Add("New-Item $Path"); throw 'blocked by the test' }
    Mock New-ItemProperty { [void]$script:blocked.Add("New-ItemProperty $LiteralPath $Name"); throw 'blocked by the test' }
    Mock Set-ItemProperty { [void]$script:blocked.Add("Set-ItemProperty $LiteralPath $Name"); throw 'blocked by the test' }
    Mock Invoke-External { [void]$script:blocked.Add("Invoke-External $FilePath"); throw 'blocked by the test' }
    Mock Register-ScheduledTask { [void]$script:blocked.Add('Register-ScheduledTask'); throw 'blocked by the test' }
    Mock Unregister-ScheduledTask { [void]$script:blocked.Add('Unregister-ScheduledTask'); throw 'blocked by the test' }
    Mock Restart-Computer { [void]$script:blocked.Add('Restart-Computer'); throw 'blocked by the test' }
    Mock Get-CimInstance { [void]$script:blocked.Add("Get-CimInstance $ClassName"); throw 'blocked by the test' }
    # Read-only: whether a Windows product key is installed (the activation attempt asks before it runs).
    Mock Get-CimInstance { return $script:licensingProducts } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
    Mock Invoke-CimMethod { [void]$script:blocked.Add("Invoke-CimMethod $MethodName"); throw 'blocked by the test' }
    Mock Invoke-PowerShellChild { [void]$script:blocked.Add('Invoke-PowerShellChild'); throw 'blocked by the test' }
  }
}

Describe 'Format-SetupReport' {
  BeforeAll { $script:l = Format-SetupReport -State $st -Verdict (Get-RunVerdict -State $st) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{ 'Google Chrome' = '155.0.8059.85' } }
  It 'uses Israeli dates' { $l | Should -Contain 'Started      : 18/10/2026 09:05'; $l | Should -Contain 'Duration     : 1:12' }
  It 'has identity and AnyDesk' { $l | Should -Contain 'PC name      : DESKTOP-AB12 -> DELL-7HX2K93'; $l | Should -Contain 'AnyDesk ID   : 123456789' }
  It 'has the version and result' { $l | Should -Contain 'Tool version : 2026.10.18.1'; $l | Should -Contain 'Result       : SETUP COMPLETE' }
}

Describe 'Format-SetupReport content' {
  BeforeAll {
    $script:green = @(Format-SetupReport -State $st -Verdict (Get-RunVerdict -State $st) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{ 'Google Chrome' = '155.0.8059.85' })

    $m = $script:fm.Clone()
    $m.OsCaption = "Windows 11 Pro $script:Hebrew"
    $script:rs = New-RunState -Machine $m -Choices @{ Mode = 'DESKTOP'; SevenZip = $true; Office = 'OFF' } -Plan @('prepare', 'windows-update', 'vendor-pass1') -Version '2026.10.18.1'
    $rs.StartedAt = '2026-10-18T22:50:00'; $rs.EndedAt = '2026-10-19T01:05:00'
    $rs.Steps['prepare'].Status = 'Done'; $rs.Steps['prepare'].Message = 'Machine prepared'
    $rs.Steps['prepare'].EndedAt = '2026-10-18T22:52:00'   # no StartedAt: no time on its line
    $rs.Steps['windows-update'].Status = 'Done'; $rs.Steps['windows-update'].Message = 'Installed 7 updates in 3 rounds'
    $rs.Steps['windows-update'].StartedAt = '2026-10-18T23:00:00'; $rs.Steps['windows-update'].EndedAt = '2026-10-18T23:41:07'
    $rs.Steps['vendor-pass1'].StartedAt = '2026-10-18T22:50:00'; $rs.Steps['vendor-pass1'].EndedAt = '2026-10-18T23:52:03'
    $rs.Steps['windows-update'].Data = @{ Rounds = 3; Installed = 7; FailedTitles = @{ 'id-1' = "Cumulative Update KB5050001 $script:Hebrew"; 'id-3' = 'Not hidden' }; InstalledLines = @('Round 1: KB5070001 Cumulative', "Round 2: KB5070002 $script:Hebrew") }
    $rs.HiddenUpdateIds = @('id-1', 'id-2')
    $rs.Steps['vendor-pass1'].Status = 'Failed'; $rs.Steps['vendor-pass1'].Message = "DCU exited 3001 $script:Hebrew"
    $rs.Notes = @('Windows not activated')
    $script:red = @(Format-SetupReport -State $rs -Verdict (Get-RunVerdict -State $rs) -Activation 'Not activated' -BitLockerText 'Decrypting' -AppVersions @{ 'Google Chrome' = '155.0.8059.85'; '7-Zip' = '24.08' })
  }
  It 'starts with the title and lists the header lines in order' {
    $expected = 'BenTech Windows Setup - Report', 'Tool version : ', 'Result       : ', 'Started      : ', 'Finished     : ', 'Duration     : ',
      'Machine      : ', 'PC name      : ', 'Mode         : ', 'Windows      : ', 'Activation   : ', 'BitLocker    : ', 'Smart App Control : ', 'AnyDesk ID   : '
    for ($i = 0; $i -lt $expected.Count; $i++) { $green[$i] | Should -BeLike ($expected[$i] + '*') }
  }
  It 'shows Smart App Control as given, and Unknown when it was not passed (M8)' {
    $green | Should -Contain 'Smart App Control : Unknown'
    $l = @(Format-SetupReport -State $st -Verdict (Get-RunVerdict -State $st) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{} -SmartAppControl 'Evaluation')
    $l | Should -Contain 'Smart App Control : Evaluation'
  }
  It 'shows the machine, mode and Windows lines' {
    $green | Should -Contain 'Machine      : Dell Inc. Latitude 5440   SN: 7HX2K93'
    $green | Should -Contain 'Mode         : LAPTOP (detected: LAPTOP)'
    $green | Should -Contain 'Windows      : Windows 11 Pro 25H2 (26200) x64'
    $red | Should -Contain 'Mode         : DESKTOP (detected: LAPTOP)'
  }
  It 'detects a VM and a desktop' {
    $vm = $st.Clone(); $vm.Machine = $st.Machine.Clone(); $vm.Machine.IsVM = $true; $vm.Machine.IsLaptop = $false
    (Format-SetupReport -State $vm -Verdict (Get-RunVerdict -State $vm) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain 'Mode         : LAPTOP (detected: VM)'
    $vm.Machine.IsVM = $false
    (Format-SetupReport -State $vm -Verdict (Get-RunVerdict -State $vm) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain 'Mode         : LAPTOP (detected: DESKTOP)'
  }
  It 'shows the finish time and a duration across midnight' {
    $red | Should -Contain 'Finished     : 19/10/2026 01:05'
    $red | Should -Contain 'Duration     : 2:15'
  }
  It 'shows activation, BitLocker and a missing AnyDesk ID' {
    $red | Should -Contain 'Activation   : Not activated'
    $red | Should -Contain 'BitLocker    : Decrypting'
    $red | Should -Contain 'AnyDesk ID   : not available'
  }
  It 'lists the apps by name' {
    $i = [array]::IndexOf($red, 'Apps:')
    $i | Should -BeGreaterThan 0
    $red[$i + 1] | Should -Be '  7-Zip 24.08'
    $red[$i + 2] | Should -Be '  Google Chrome 155.0.8059.85'
  }
  It 'says none when no app version was found' {
    $lines = @(Format-SetupReport -State $st -Verdict (Get-RunVerdict -State $st) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{})
    $lines[[array]::IndexOf($lines, 'Apps:') + 1] | Should -Be '  none'
  }
  It 'summarises Windows Update with hidden updates by title, else by id' {
    $red | Should -Contain 'Windows Update: 3 rounds, 7 installed, hidden: Cumulative Update KB5050001 ????, id-2'
    $green | Should -Contain 'Windows Update: 0 rounds, 0 installed, hidden: none'
  }
  It 'lists Windows updates installed per round, and none when there are none' {
    $red | Should -Contain 'Windows updates installed:'
    $i = [array]::IndexOf($red, 'Windows updates installed:')
    $red[$i - 2] | Should -BeLike 'Windows Update: 3 rounds*'
    $red[$i - 1] | Should -Be ''
    $red[$i + 1] | Should -Be '  Round 1: KB5070001 Cumulative'
    $red[$i + 2] | Should -Be '  Round 2: KB5070002 ????'
    $red[$i + 3] | Should -Be ''
    $red[$i + 4] | Should -Be 'Steps:'
    $green | Should -Contain 'Windows updates installed:'
    $green[[array]::IndexOf($green, 'Windows updates installed:') + 1] | Should -Be '  none'
  }
  It 'lists every plan step with its padded status, title, message and time' {
    $i = [array]::IndexOf($red, 'Steps:')
    $red[$i + 1] | Should -Be '  Done     Prepare machine - Machine prepared'
    $red[$i + 2] | Should -Be '  Done     Windows Update - Installed 7 updates in 3 rounds (41:07)'
    $red[$i + 3] | Should -Be '  Failed   Vendor drivers + BIOS (pass 1) - DCU exited 3001 ???? (1:02:03)'
    $green | Should -Contain '  Done     Google Chrome'
  }
  It 'adds m:ss to a step with a start and an end, also without a message' {
    $copy = $st.Clone(); $copy.Steps = @{ chrome = $st.Steps.chrome.Clone() }
    $copy.Steps.chrome.StartedAt = '2026-10-18T09:10:00'; $copy.Steps.chrome.EndedAt = '2026-10-18T09:10:45'
    (Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain '  Done     Google Chrome (0:45)'
    $copy.Steps.chrome.Message = 'Installed'; $copy.Steps.chrome.EndedAt = '2026-10-18T10:09:59'
    (Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain '  Done     Google Chrome - Installed (59:59)'
  }
  It 'uses h:mm:ss from one hour on' {
    $copy = $st.Clone(); $copy.Steps = @{ chrome = $st.Steps.chrome.Clone() }
    $copy.Steps.chrome.StartedAt = '2026-10-18T09:10:00'; $copy.Steps.chrome.EndedAt = '2026-10-18T10:10:00'
    (Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain '  Done     Google Chrome (1:00:00)'
    $copy.Steps.chrome.EndedAt = '2026-10-19T11:15:09'
    (Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain '  Done     Google Chrome (26:05:09)'
  }
  It 'leaves the line unchanged when the start or the end is missing' {
    $copy = $st.Clone(); $copy.Steps = @{ chrome = $st.Steps.chrome.Clone() }
    $copy.Steps.chrome.Message = 'Installed'; $copy.Steps.chrome.StartedAt = '2026-10-18T09:10:00'; $copy.Steps.chrome.EndedAt = $null
    (Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain '  Done     Google Chrome - Installed'
    $copy.Steps.chrome.StartedAt = 'not a time'; $copy.Steps.chrome.EndedAt = '2026-10-18T09:10:45'
    (Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain '  Done     Google Chrome - Installed'
  }
  It 'reads step times that came back from JSON as [datetime]' {
    $copy = $st.Clone(); $copy.Steps = @{ chrome = $st.Steps.chrome.Clone() }
    $copy.Steps.chrome.StartedAt = [datetime]'2026-10-18T09:10:00'; $copy.Steps.chrome.EndedAt = [datetime]'2026-10-18T09:51:07'
    (Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) | Should -Contain '  Done     Google Chrome (41:07)'
  }
  It 'adds Failures and Notes sections only when there are some' {
    $red | Should -Contain 'Failures:'
    $red | Should -Contain '  Vendor drivers + BIOS (pass 1): DCU exited 3001 ????'
    $red | Should -Contain '  Windows update hidden after repeated failures: id-2'
    $red | Should -Contain 'Notes:'
    $red | Should -Contain '  Windows not activated'
    $green | Should -Not -Contain 'Failures:'
    $green | Should -Not -Contain 'Notes:'
  }
  It 'is plain ASCII: Hebrew becomes ?' {
    $red | Should -Contain 'Windows      : Windows 11 Pro ???? 25H2 (26200) x64'
    foreach ($line in $red) { $line | Should -Match '^[\x20-\x7E]*$' }
  }
  It 'shows the Windows caption without the direction marks Hebrew Windows adds' {
    $marked = $script:st.Clone(); $marked.Machine = $script:fm.Clone()
    $marked.Machine.OsCaption = [string][char]0x200F + [string][char]0x200E + 'Microsoft Windows 11 Home'
    $marked.Machine.OsDisplayVersion = '25H2'; $marked.Machine.OsBuild = 26200; $marked.Machine.Arch = 'x64'
    $l = @(Format-SetupReport -State $marked -Verdict (Get-RunVerdict -State $marked) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{})
    $l | Should -Contain 'Windows      : Microsoft Windows 11 Home 25H2 (26200) x64'
  }
  It 'reads times that came back from JSON as [datetime]' {
    $copy = $st.Clone(); $copy.StartedAt = [datetime]'2026-10-18T09:05:00'; $copy.EndedAt = [datetime]'2026-10-18T10:17:00'
    $lines = Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}
    $lines | Should -Contain 'Started      : 18/10/2026 09:05'
    $lines | Should -Contain 'Duration     : 1:12'
  }
  It 'says unknown for a missing end time' {
    $copy = $st.Clone(); $copy.EndedAt = $null
    $lines = Format-SetupReport -State $copy -Verdict (Get-RunVerdict -State $copy) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}
    $lines | Should -Contain 'Finished     : unknown'
    $lines | Should -Contain 'Duration     : unknown'
  }
}

Describe 'Test-FinalRebootNeeded' {
  BeforeAll {
    $script:none = @{CbsRebootPending=$false;WuRebootRequired=$false;PendingFileRename=$false;ComputerRenamePending=$false}
    $script:boot = [datetime]::new(2026, 10, 18, 8, 0, 0, [DateTimeKind]::Utc)
    function New-BrowserState {
      param([string]$Status = 'Done', $SetAtUtc, [switch]$NoData)
      $step = @{ Status = $Status; Data = @{ RebootCountAtSet = 4; SetAtUtc = $SetAtUtc } }
      if ($NoData) { $step.Data = @{} }
      @{ Steps = @{ 'default-browser' = $step }; RebootCount = 4 }
    }
  }
  BeforeEach {
    Mock Write-SetupLog { }
    Mock Get-CimInstance { throw 'blocked by the test: no CIM here' }
    Mock Get-LastBootUtc { throw 'blocked by the test: pass -LastBootUtc' }
  }
  It 'needs no reboot without signals and without the default-browser step' {
    Test-FinalRebootNeeded -Signals $none -State @{ Steps = @{}; RebootCount = 4 } -LastBootUtc $boot | Should -BeFalse
  }
  It 'reboots for a pending rename' {
    $sig = $none.Clone(); $sig.ComputerRenamePending = $true
    Test-FinalRebootNeeded -Signals $sig -State @{ Steps = @{}; RebootCount = 4 } -LastBootUtc $boot | Should -BeTrue
  }
  It 'reboots when the browser policy was set after the last boot (nobody signed in since)' {
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc $boot.AddMinutes(30).ToString('o')) -LastBootUtc $boot | Should -BeTrue
  }
  It 'skips the reboot when the machine booted after the policy was set' {
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc $boot.AddMinutes(-30).ToString('o')) -LastBootUtc $boot | Should -BeFalse
  }
  It 'needs no reboot for a Skipped default-browser step' {
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -Status Skipped -SetAtUtc $boot.AddMinutes(30).ToString('o')) -LastBootUtc $boot | Should -BeFalse
  }
  It 'needs no reboot for a Done step without SetAtUtc' {
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -NoData) -LastBootUtc $boot | Should -BeFalse
  }
  It 'needs no reboot for an unreadable SetAtUtc' {
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc 'yesterday') -LastBootUtc $boot | Should -BeFalse
  }
  It 'counts a policy set in the same instant as the boot as not applied' {
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc $boot.ToString('o')) -LastBootUtc $boot | Should -BeTrue
  }
  It 'compares in UTC whatever the SetAtUtc offset' {
    # 10:30 at +03:00 is 07:30 UTC: before the 08:00 UTC boot.
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc '2026-10-18T10:30:00.0000000+03:00') -LastBootUtc $boot | Should -BeFalse
  }
  It 'accepts a SetAtUtc that came back from JSON as a [datetime]' {
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc $boot.AddMinutes(30)) -LastBootUtc $boot | Should -BeTrue
  }
  It 'reads the last boot time itself when it is not given' {
    Mock Get-LastBootUtc { return $script:boot }
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc $boot.AddMinutes(30).ToString('o')) | Should -BeTrue
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc $boot.AddMinutes(-30).ToString('o')) | Should -BeFalse
    Should -Invoke Get-LastBootUtc -Times 2 -Exactly
  }
  It 'reboots for a Done step when the last boot time cannot be read' {
    Mock Get-LastBootUtc { return $null }
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -SetAtUtc $boot.AddMinutes(-30).ToString('o')) | Should -BeTrue
  }
  It 'does not read the boot time when the step is not Done' {
    Mock Get-LastBootUtc { return $null }
    Test-FinalRebootNeeded -Signals $none -State (New-BrowserState -Status Skipped) | Should -BeFalse
    Should -Invoke Get-LastBootUtc -Times 0 -Exactly
  }
}

Describe 'Get-LastBootUtc' {
  BeforeEach { $script:logs = New-Object System.Collections.ArrayList; Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level }) } }
  It 'returns Win32_OperatingSystem.LastBootUpTime in UTC' {
    $script:bootLocal = [datetime]::new(2026, 10, 18, 9, 0, 0, [DateTimeKind]::Local)
    Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = $script:bootLocal } } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
    $r = Get-LastBootUtc
    $r | Should -Be $script:bootLocal.ToUniversalTime()
    $r.Kind | Should -Be ([DateTimeKind]::Utc)
  }
  It 'returns $null and warns when CIM fails' {
    Mock Get-CimInstance { throw 'RPC server unavailable' }
    Get-LastBootUtc | Should -BeNullOrEmpty
    @($script:logs | Where-Object { $_.Level -eq 'WARN' }).Count | Should -Be 1
  }
}

Describe 'Get-ActivationStatus' {
  BeforeEach { Mock Write-SetupLog { } }
  It 'is Activated for LicenseStatus 1, from the Windows licensing product with a key' {
    Mock Get-CimInstance { [pscustomobject]@{ LicenseStatus = 1 } } -ParameterFilter {
      $ClassName -eq 'SoftwareLicensingProduct' -and $Filter -eq "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
    }
    Mock Get-CimInstance { throw 'wrong query' }
    Get-ActivationStatus | Should -Be 'Activated'
  }
  It 'is Not activated for any other LicenseStatus' {
    Mock Get-CimInstance { [pscustomobject]@{ LicenseStatus = 5 } }
    Get-ActivationStatus | Should -Be 'Not activated'
  }
  It 'is Not activated when no product has a key' {
    Mock Get-CimInstance { }
    Get-ActivationStatus | Should -Be 'Not activated'
  }
  It 'is Activated when one of several products is licensed' {
    Mock Get-CimInstance { [pscustomobject]@{ LicenseStatus = 0 }; [pscustomobject]@{ LicenseStatus = 1 } }
    Get-ActivationStatus | Should -Be 'Activated'
  }
  It 'is Unknown when CIM fails' {
    Mock Get-CimInstance { throw 'Access denied' }
    Get-ActivationStatus | Should -Be 'Unknown'
  }
}

Describe 'Get-SmartAppControlState (M8)' {
  BeforeEach {
    $script:logs = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level }) }
  }
  It 'reads VerifiedAndReputablePolicyState under CI\Policy: <Value> -> <Expected>' -ForEach @(
    @{ Value = 0; Expected = 'Off' }
    @{ Value = 1; Expected = 'On' }
    @{ Value = 2; Expected = 'Evaluation' }
    @{ Value = 3; Expected = 'Unknown' }
    @{ Value = 'abc'; Expected = 'Unknown' }
  ) {
    $script:sacValue = $Value
    Mock Get-ItemProperty { [pscustomobject]@{ VerifiedAndReputablePolicyState = $script:sacValue } } -ParameterFilter {
      $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -and @($Name) -contains 'VerifiedAndReputablePolicyState'
    }
    Mock Get-ItemProperty { throw 'wrong registry read' }
    Get-SmartAppControlState | Should -Be $Expected
  }
  It 'is Unknown, without throwing, when the value is missing' {
    Mock Get-ItemProperty { Write-Error -Message 'Property VerifiedAndReputablePolicyState does not exist' -Category InvalidArgument }
    { $script:sac = Get-SmartAppControlState } | Should -Not -Throw
    $script:sac | Should -Be 'Unknown'
  }
  It 'is Unknown, without throwing, when the key cannot be read' {
    Mock Get-ItemProperty { throw 'Requested registry access is not allowed' }
    { $script:sac = Get-SmartAppControlState } | Should -Not -Throw
    $script:sac | Should -Be 'Unknown'
  }
  It 'is Unknown when the read returns nothing' {
    Mock Get-ItemProperty { }
    Get-SmartAppControlState | Should -Be 'Unknown'
  }
}

Describe 'Get-InstalledAppVersions' {
  BeforeAll {
    $script:Uninstall64 = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $script:Uninstall32 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $script:C2R = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
  }
  BeforeEach {
    Mock Write-SetupLog { }
    Mock Get-ItemProperty { return $null }
    Mock Get-ItemProperty {
      [pscustomobject]@{ DisplayName = 'Google Chrome'; DisplayVersion = '155.0.8059.85' }
      [pscustomobject]@{ DisplayName = '7-Zip 24.08 (x64)'; DisplayVersion = '24.08' }
      [pscustomobject]@{ DisplayName = 'Realtek Audio Driver'; DisplayVersion = '6.0.9' }
      [pscustomobject]@{ SystemComponent = 1 }
    } -ParameterFilter { @($Path) -contains $script:Uninstall64 }
    Mock Get-ItemProperty {
      [pscustomobject]@{ DisplayName = 'AnyDesk'; DisplayVersion = '' }
      [pscustomobject]@{ DisplayName = 'AnyDesk'; DisplayVersion = '9.5.3' }
    } -ParameterFilter { @($Path) -contains $script:Uninstall32 }
    Mock Get-ItemProperty { [pscustomobject]@{ VersionToReport = '16.0.19127.20000' } } -ParameterFilter { $LiteralPath -eq $script:C2R }
  }
  It 'reads Chrome, AnyDesk and 7-Zip from both Uninstall views, and Office from Click-to-Run' {
    $v = Get-InstalledAppVersions
    $v['Google Chrome'] | Should -Be '155.0.8059.85'
    $v['AnyDesk'] | Should -Be '9.5.3'
    $v['7-Zip'] | Should -Be '24.08'
    $v['Microsoft 365'] | Should -Be '16.0.19127.20000'
    $v.Count | Should -Be 4
  }
  It 'leaves out what is not installed' {
    Mock Get-ItemProperty { return $null } -ParameterFilter { @($Path) -contains $script:Uninstall32 }
    Mock Get-ItemProperty { throw 'Property VersionToReport does not exist' } -ParameterFilter { $LiteralPath -eq $script:C2R }
    $v = Get-InstalledAppVersions
    $v.ContainsKey('AnyDesk') | Should -BeFalse
    $v.ContainsKey('Microsoft 365') | Should -BeFalse
    $v.Count | Should -Be 2
  }
  It 'never throws when the registry cannot be read' {
    Mock Get-ItemProperty { throw 'Requested registry access is not allowed' } -ParameterFilter { @($Path) -contains $script:Uninstall64 }
    $v = Get-InstalledAppVersions
    $v['AnyDesk'] | Should -Be '9.5.3'
    $v['Microsoft 365'] | Should -Be '16.0.19127.20000'
    $v.ContainsKey('Google Chrome') | Should -BeFalse
  }
}

Describe 'ConvertTo-BitLockerFinding' {
  It '<Case>' -ForEach @(
    @{ Case = 'Absent: not present';            In = @{ Presence = 'Absent'; Status = $null };  Text = 'Not present'; Note = $null; Err = $null }
    @{ Case = 'Unknown: could not be read';     In = @{ Presence = 'Unknown'; Status = $null }; Text = 'Unknown'; Note = 'BitLocker status could not be read'; Err = $null }
    @{ Case = 'Present without a status';       In = @{ Presence = 'Present'; Status = $null }; Text = 'Unknown'; Note = 'BitLocker status could not be read'; Err = $null }
    @{ Case = 'decrypted: off';                 In = @{ Presence = 'Present'; Status = 0 };     Text = 'Off'; Note = $null; Err = $null }
    @{ Case = 'decrypting: still running';      In = @{ Presence = 'Present'; Status = 3 };     Text = 'Decrypting'; Note = 'BitLocker decryption still running'; Err = $null }
    @{ Case = 'encrypted and not decrypting';   In = @{ Presence = 'Present'; Status = 1 };     Text = 'Encrypted'; Note = $null; Err = 'Drive still encrypted and not decrypting' }
    @{ Case = 'decryption paused';              In = @{ Presence = 'Present'; Status = 5 };     Text = 'Encrypted'; Note = $null; Err = 'Drive still encrypted and not decrypting' }
  ) {
    $f = ConvertTo-BitLockerFinding -BitLockerState $In
    $f.Text | Should -Be $Text
    $f.Note | Should -Be $Note
    $f.Error | Should -Be $Err
  }
}

Describe 'Invoke-StepFinalize phase A' {
  BeforeEach { Initialize-FinalizeMocks }
  AfterEach { $script:blocked -join "; " | Should -BeNullOrEmpty }

  It 'restores the final power settings and removes only the no-auto-reboot value' {
    $script:regPresent[$script:AuKey] = @{ NoAutoRebootWithLoggedOnUsers = 1; AUOptions = 4 }
    $ctx = New-FinalizeContext
    Invoke-StepFinalize -Context $ctx | Out-Null
    $script:restoreCalls | Should -Be 1
    $script:regRemoved.Count | Should -Be 1
    $script:regRemoved[0].Path | Should -Be $script:AuKey
    $script:regRemoved[0].Name | Should -Be 'NoAutoRebootWithLoggedOnUsers'
    $script:regPresent[$script:AuKey].ContainsKey('AUOptions') | Should -BeTrue
  }
  It 'does not touch the registry when the no-auto-reboot value is already gone' {
    $ctx = New-FinalizeContext
    Invoke-StepFinalize -Context $ctx | Out-Null
    @($script:regRemoved | Where-Object { $_.Path -eq $script:AuKey }).Count | Should -Be 0
  }
  It 'keeps going when the no-auto-reboot value cannot be removed' {
    $script:regPresent[$script:AuKey] = @{ NoAutoRebootWithLoggedOnUsers = 1 }
    $script:regRemoveThrows = $true
    $ctx = New-FinalizeContext
    (Invoke-StepFinalize -Context $ctx).Status | Should -Be 'Done'
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Data.name -eq 'NoAutoRebootWithLoggedOnUsers' }).Count | Should -Be 1
  }
  It 'requests the final restart when one is needed, and leaves Phase B for the next call' {
    $script:signals.ComputerRenamePending = $true
    $ctx = New-FinalizeContext
    $r = Invoke-StepFinalize -Context $ctx
    $r.Status | Should -Be 'Continue'
    $r.Reboot | Should -Be 'Now'
    $script:unregisterCalls | Should -Be 0
    $ctx.State.EndedAt | Should -BeNullOrEmpty
    Test-Path (Join-Path $ctx.LogDir 'Setup-Report.txt') | Should -BeFalse
    Test-Path (Join-Path $ctx.Root 'setup.ps1') | Should -BeTrue
  }
  It 'requests the final restart when nobody has signed in since the browser policy was set' {
    $ctx = New-FinalizeContext -Plan @('default-browser', 'finalize')
    $ctx.State.Steps['default-browser'].Data = @{ RebootCountAtSet = 0; SetAtUtc = $script:lastBoot.AddMinutes(10).ToString('o') }
    $r = Invoke-StepFinalize -Context $ctx
    $r.Status | Should -Be 'Continue'
    $r.Reboot | Should -Be 'Now'
  }
  It 'sets FinalRebootDone and saves it before asking for the restart' {
    $script:signals.PendingFileRename = $true
    $ctx = New-FinalizeContext
    Invoke-StepFinalize -Context $ctx | Out-Null
    $ctx.State.FinalRebootDone | Should -BeTrue
    (Read-RunState -Root $ctx.Root).FinalRebootDone | Should -BeTrue
  }
  It 'falls through to Phase B when no restart is needed' {
    $ctx = New-FinalizeContext
    $r = Invoke-StepFinalize -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    $ctx.State.FinalRebootDone | Should -BeTrue
    $script:unregisterCalls | Should -Be 1
    Test-Path (Join-Path $ctx.LogDir 'Setup-Report.txt') | Should -BeTrue
  }
  It 'falls through to Phase B without a resume task (a restart would end the run)' {
    $script:signals.ComputerRenamePending = $true
    $ctx = New-FinalizeContext
    $ctx.State.ResumeTaskMissing = $true
    $r = Invoke-StepFinalize -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    $script:unregisterCalls | Should -Be 1
    @($ctx.State.Errors | Where-Object { $_ -eq 'Restart skipped: no resume task' }).Count | Should -Be 1
  }
  It 'falls through to Phase B at the reboot cap and reports the cap' {
    $script:signals.WuRebootRequired = $true
    $ctx = New-FinalizeContext -RebootCount 12 -MaxReboots 12
    $r = Invoke-StepFinalize -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    $ctx.State.RebootCapHit | Should -BeTrue
    $script:unregisterCalls | Should -Be 1
    Get-ReportLines -Context $ctx | Should -Contain '  Reboot limit reached'
  }
  It 'restarts one below the cap' {
    $script:signals.WuRebootRequired = $true
    $ctx = New-FinalizeContext -RebootCount 11 -MaxReboots 12
    (Invoke-StepFinalize -Context $ctx).Reboot | Should -Be 'Now'
    $ctx.State.RebootCapHit | Should -BeFalse
  }
  It 'notes power settings that could not be restored' {
    $script:restoreResult = $false
    $ctx = New-FinalizeContext
    Invoke-StepFinalize -Context $ctx | Out-Null
    @($ctx.State.Notes | Where-Object { $_ -eq 'Some power settings could not be restored' }).Count | Should -Be 1
  }
  It 'notes power settings that could not be restored when the restore throws' {
    $script:restoreThrows = $true
    $ctx = New-FinalizeContext
    (Invoke-StepFinalize -Context $ctx).Status | Should -Be 'Done'
    $ctx.State.Notes | Should -Contain 'Some power settings could not be restored'
  }
  It 'keeps the power note across the restart (saved in state.json, not carried by the result)' {
    $script:restoreResult = $false
    $script:signals.ComputerRenamePending = $true
    $ctx = New-FinalizeContext
    $r = Invoke-StepFinalize -Context $ctx
    @($r.Notes).Count | Should -Be 0
    (Read-RunState -Root $ctx.Root).Notes | Should -Contain 'Some power settings could not be restored'
  }
  It 'skips Phase A once FinalRebootDone is set' {
    $script:signals.ComputerRenamePending = $true
    $script:regPresent[$script:AuKey] = @{ NoAutoRebootWithLoggedOnUsers = 1 }
    $ctx = New-FinalizeContext -PhaseB
    $r = Invoke-StepFinalize -Context $ctx
    $r.Status | Should -Be 'Done'
    $script:restoreCalls | Should -Be 0
    @($script:regRemoved | Where-Object { $_.Path -eq $script:AuKey }).Count | Should -Be 0
  }
}

Describe 'Invoke-StepFinalize phase B' {
  BeforeEach { Initialize-FinalizeMocks }
  AfterEach { $script:blocked -join "; " | Should -BeNullOrEmpty }

  It 'Chrome installed=<Installed>, default=<ProgId>: note=<Noted>' -ForEach @(
    @{ Installed = $true;  ProgId = 'MSEdgeHTM';  Noted = $true }
    @{ Installed = $true;  ProgId = $null;        Noted = $true }
    @{ Installed = $true;  ProgId = 'ChromeHTML'; Noted = $false }
    @{ Installed = $false; ProgId = 'MSEdgeHTM';  Noted = $false }
  ) {
    $script:chromeInstalled = $Installed
    $script:progId = $ProgId
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    (@($ctx.State.Notes) -contains 'Chrome is not the default browser') | Should -Be $Noted
  }
  It 'checks the default browser before removing its policy' {
    $script:regPresent[$script:SystemPolicyKey] = @{ DefaultAssociationsConfiguration = 'C:\ProgramData\BenTech\DefaultAssociations.xml' }
    $script:policyAtCheck = $null
    Mock Get-DefaultBrowserProgId { $script:policyAtCheck = $script:regPresent[$script:SystemPolicyKey].ContainsKey('DefaultAssociationsConfiguration'); 'ChromeHTML' }
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    $script:policyAtCheck | Should -BeTrue
  }
  It 'removes the default-browser policy value (never its key), the XML file and its empty folder' {
    $script:regPresent[$script:SystemPolicyKey] = @{ DefaultAssociationsConfiguration = $script:assocPath; EnableSmartScreen = 1 }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:assocPath))
    [IO.File]::WriteAllText($script:assocPath, '<DefaultAssociations />')
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    @($script:regRemoved | Where-Object { $_.Path -eq $script:SystemPolicyKey -and $_.Name -eq 'DefaultAssociationsConfiguration' }).Count | Should -Be 1
    $script:regPresent[$script:SystemPolicyKey].ContainsKey('EnableSmartScreen') | Should -BeTrue
    Test-Path -LiteralPath $script:assocPath | Should -BeFalse
    Test-Path -LiteralPath (Split-Path -Parent $script:assocPath) | Should -BeFalse
  }
  It 'keeps the ProgramData folder when something else is in it' {
    $folder = Split-Path -Parent $script:assocPath
    [void][IO.Directory]::CreateDirectory($folder)
    [IO.File]::WriteAllText($script:assocPath, '<DefaultAssociations />')
    [IO.File]::WriteAllText((Join-Path $folder 'agent.json'), '{}')
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    Test-Path -LiteralPath $script:assocPath | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $folder 'agent.json') | Should -BeTrue
  }
  It 'is fine when the XML and its folder were never written' {
    $ctx = New-FinalizeContext -PhaseB
    (Invoke-StepFinalize -Context $ctx).Status | Should -Be 'Done'
    @($script:logs | Where-Object { $_.Level -in 'WARN', 'ERROR' }).Count | Should -Be 0
  }
  It 'adds the Note "Resume task could not be removed" only when the removal failed (triage 250): removed=<Removed>' -ForEach @(
    @{ Removed = $true }
    @{ Removed = $false }
  ) {
    $script:unregisterResult = $Removed
    $ctx = New-FinalizeContext -PhaseB
    (Invoke-StepFinalize -Context $ctx).Status | Should -Be 'Done'
    $script:unregisterCalls | Should -Be 1
    (@($ctx.State.Notes) -contains 'Resume task could not be removed') | Should -Be (-not $Removed)
    if (-not $Removed) { Get-ReportLines -Context $ctx | Should -Contain '  Resume task could not be removed' }
  }
  It 'Complete-SetupFinalization on its own (R26) also notes a resume task it could not remove' {
    $script:unregisterResult = $false
    $ctx = New-FinalizeContext
    $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'restart failed'
    $null = Complete-SetupFinalization -Context $ctx
    @($ctx.State.Notes) | Should -Contain 'Resume task could not be removed'
  }
  It 'cleans the Lenovo System Update policy only on a <Brand>' -ForEach @(
    @{ Brand = 'LENOVO'; Calls = 1 }
    @{ Brand = 'DELL';   Calls = 0 }
    @{ Brand = 'HP';     Calls = 0 }
  ) {
    $m = $script:fm.Clone(); $m.Brand = $Brand
    $ctx = New-FinalizeContext -Machine $m -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    $script:lenovoCalls | Should -Be $Calls
  }
  It 'activation <Activation>: note <Note> (M5: an unreadable status is not "not activated")' -ForEach @(
    @{ Activation = 'Activated';     Note = $null }
    @{ Activation = 'Not activated'; Note = 'Windows not activated' }
    @{ Activation = 'Unknown';       Note = 'Windows activation status unknown' }
  ) {
    $script:activation = $Activation
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    $activationNotes = @(@($ctx.State.Notes) | Where-Object { $_ -match 'activat' })
    if ($null -eq $Note) { $activationNotes.Count | Should -Be 0 } else { $activationNotes | Should -Be @($Note) }
    Get-ReportLines -Context $ctx | Should -Contain "Activation   : $Activation"
  }
  It 'records Smart App Control in the report (M8): <State>' -ForEach @(
    @{ State = 'Off' }, @{ State = 'On' }, @{ State = 'Evaluation' }, @{ State = 'Unknown' }
  ) {
    $script:smartAppControl = $State
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    Should -Invoke Get-SmartAppControlState -Times 1 -Exactly
    Get-ReportLines -Context $ctx | Should -Contain "Smart App Control : $State"
  }
  It 'BitLocker <Presence>/<Status>: report <Text>' -ForEach @(
    @{ Presence = 'Absent';  Status = $null; Text = 'Not present'; Note = $null; Err = $null }
    @{ Presence = 'Unknown'; Status = $null; Text = 'Unknown';     Note = 'BitLocker status could not be read'; Err = $null }
    @{ Presence = 'Present'; Status = $null; Text = 'Unknown';     Note = 'BitLocker status could not be read'; Err = $null }
    @{ Presence = 'Present'; Status = 3;     Text = 'Decrypting';  Note = 'BitLocker decryption still running'; Err = $null }
    @{ Presence = 'Present'; Status = 1;     Text = 'Encrypted';   Note = $null; Err = 'Drive still encrypted and not decrypting' }
    @{ Presence = 'Present'; Status = 0;     Text = 'Off';         Note = $null; Err = $null }
  ) {
    $script:bitlocker = @{ Presence = $Presence; Volume = $null; Status = $Status }
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    Get-ReportLines -Context $ctx | Should -Contain "BitLocker    : $Text"
    $notes = @($ctx.State.Notes | Where-Object { $_ -like 'BitLocker*' })
    $errors = @($ctx.State.Errors | Where-Object { $_ -like 'Drive*' })
    if ($Note) { $notes.Count | Should -Be 1; $notes[0] | Should -Be $Note } else { $notes.Count | Should -Be 0 }
    if ($Err) { $errors.Count | Should -Be 1; $errors[0] | Should -Be $Err } else { $errors.Count | Should -Be 0 }
  }
  It 'turns the report red for a drive still encrypted' {
    $script:bitlocker = @{ Presence = 'Present'; Volume = $null; Status = 1 }
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    Get-ReportLines -Context $ctx | Should -Contain 'Result       : COMPLETED WITH ERRORS'
  }
  It 'treats a BitLocker read that throws as unknown' {
    $script:bitlockerThrows = $true
    $ctx = New-FinalizeContext -PhaseB
    (Invoke-StepFinalize -Context $ctx).Status | Should -Be 'Done'
    $ctx.State.Notes | Should -Contain 'BitLocker status could not be read'
    Get-ReportLines -Context $ctx | Should -Contain 'BitLocker    : Unknown'
  }
  It 'notes Windows 10 (IsWindows10=<Win10>)' -ForEach @(@{ Win10 = $true }, @{ Win10 = $false }) {
    $m = $script:fm.Clone(); $m.IsWindows10 = $Win10
    $ctx = New-FinalizeContext -Machine $m -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    (@($ctx.State.Notes) -contains 'Windows 10: no security updates') | Should -Be $Win10
  }
  It 'unregisters the resume task' {
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    $script:unregisterCalls | Should -Be 1
  }
  It 'deletes Downloads, setup.ps1 and config.json but keeps state.json and Logs' {
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    Test-Path -LiteralPath $ctx.DownloadDir | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $ctx.Root 'setup.ps1') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $ctx.Root 'config.json') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $ctx.Root 'state.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $ctx.LogDir 'setup.log') | Should -BeTrue
  }
  It 'keeps going when a file cannot be deleted' {
    $ctx = New-FinalizeContext -PhaseB
    $lock = [IO.File]::Open((Join-Path $ctx.Root 'config.json'), 'Open', 'Read', 'None')
    try {
      $r = Invoke-StepFinalize -Context $ctx
    } finally { $lock.Dispose() }
    $r.Status | Should -Be 'Done'
    Test-Path -LiteralPath (Join-Path $ctx.Root 'setup.ps1') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $ctx.Root 'config.json') | Should -BeTrue
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Data.path -like '*config.json' }).Count | Should -Be 1
  }
  It 'is fine when the downloads are already gone' {
    $ctx = New-FinalizeContext -PhaseB
    [IO.Directory]::Delete($ctx.DownloadDir, $true)
    (Invoke-StepFinalize -Context $ctx).Status | Should -Be 'Done'
    @($script:logs | Where-Object { $_.Level -in 'WARN', 'ERROR' }).Count | Should -Be 0
  }
  It 'sets EndedAt to now' {
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    $ctx.State.EndedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
    $ended = [datetime]::ParseExact($ctx.State.EndedAt, 's', [Globalization.CultureInfo]::InvariantCulture)
    [math]::Abs(((Get-Date) - $ended).TotalMinutes) | Should -BeLessThan 2
  }
  It 'writes the report as UTF-8 with a BOM and CRLF, ASCII after the BOM, with the verdict banner' {
    $m = $script:fm.Clone(); $m.FriendlyModel = "Latitude $script:Hebrew"
    $ctx = New-FinalizeContext -Machine $m -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    $bytes = [IO.File]::ReadAllBytes((Join-Path $ctx.LogDir 'Setup-Report.txt'))
    $bytes[0] | Should -Be 0xEF; $bytes[1] | Should -Be 0xBB; $bytes[2] | Should -Be 0xBF
    @($bytes[3..($bytes.Length - 1)] | Where-Object { $_ -gt 0x7E -or ($_ -lt 0x20 -and $_ -ne 0x0D -and $_ -ne 0x0A) }).Count | Should -Be 0
    $text = [Text.Encoding]::ASCII.GetString($bytes, 3, $bytes.Length - 3)
    $text | Should -Match "`r`n"
    ($text -replace "`r`n", '') | Should -Not -Match "`n"
    $text.EndsWith("`r`n") | Should -BeTrue
    $lines = Get-ReportLines -Context $ctx
    $lines[0] | Should -Be 'BenTech Windows Setup - Report'
    $lines | Should -Contain 'Result       : SETUP COMPLETE'
    $lines | Should -Contain 'Machine      : Dell Inc. Latitude ????   SN: 7HX2K93'
    $lines | Should -Contain '  AnyDesk 9.5.3'
  }
  It 'marks finalize Done before the verdict, so the report never says it did not finish' {
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    $ctx.State.Steps['finalize'].Status | Should -Be 'Done'
    $ctx.State.Steps['finalize'].Message | Should -Be 'Finalized'
    $lines = Get-ReportLines -Context $ctx
    ($lines -join "`n") | Should -Not -Match 'did not finish'
    $lines | Should -Contain '  Done     Finalize - Finalized'
    (Get-RunVerdict -State $ctx.State).Color | Should -Be 'GREEN'
  }
  It 'puts its notes and errors in the State and returns none, so the runner cannot add them twice' {
    $script:activation = 'Not activated'
    $script:bitlocker = @{ Presence = 'Present'; Volume = $null; Status = 1 }
    $ctx = New-FinalizeContext -PhaseB
    $r = Invoke-StepFinalize -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Finalized'
    @($r.Notes).Count | Should -Be 0
    @($r.Errors).Count | Should -Be 0
    $ctx.State.Notes | Should -Contain 'Windows not activated'
    $ctx.State.Errors | Should -Contain 'Drive still encrypted and not decrypting'
    $lines = Get-ReportLines -Context $ctx
    $lines | Should -Contain '  Windows not activated'
    $lines | Should -Contain '  Drive still encrypted and not decrypting'
  }
  It 'adds a note only once when Phase B runs again' {
    $script:activation = 'Not activated'
    $ctx = New-FinalizeContext -PhaseB
    Invoke-StepFinalize -Context $ctx | Out-Null
    Invoke-StepFinalize -Context $ctx | Out-Null
    @($ctx.State.Notes | Where-Object { $_ -eq 'Windows not activated' }).Count | Should -Be 1
  }
  It 'fails with a clear message when the report cannot be written' {
    $ctx = New-FinalizeContext -PhaseB
    $ctx.LogDir = Join-Path $ctx.Root 'state.json\Logs'   # a folder under a file cannot exist
    $r = Invoke-StepFinalize -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Setup report could not be written'
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' }).Count | Should -Be 1
    $script:unregisterCalls | Should -Be 1
  }
}

Describe 'Complete-SetupFinalization on its own (ruling R26)' {
  BeforeEach { Initialize-FinalizeMocks }
  AfterEach { $script:blocked -join "; " | Should -BeNullOrEmpty }

  It 'finishes a run whose final restart failed, without ever asking for a restart' {
    $script:signals.ComputerRenamePending = $true   # a restart is pending, and must still not be asked for
    $script:regPresent[$script:AuKey] = @{ NoAutoRebootWithLoggedOnUsers = 1 }
    $ctx = New-FinalizeContext
    $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'restart failed'
    $ctx.State.Errors = @('Restart failed: Access denied (fallback: shutdown.exe exited with code 5)')

    $r = Complete-SetupFinalization -Context $ctx

    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    $script:restoreCalls | Should -Be 1
    @($script:regRemoved | Where-Object { $_.Path -eq $script:AuKey -and $_.Name -eq 'NoAutoRebootWithLoggedOnUsers' }).Count | Should -Be 1
    $ctx.State.FinalRebootDone | Should -BeTrue
    $script:unregisterCalls | Should -Be 1
    $ctx.State.EndedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
    $ctx.State.Steps['finalize'].Status | Should -Be 'Done'
    $v = Get-RunVerdict -State $ctx.State
    $v.Color | Should -Be 'RED'
    @($v.Failures | Where-Object { $_ -like '*did not finish*' }).Count | Should -Be 0
    $lines = Get-ReportLines -Context $ctx
    $lines | Should -Contain 'Result       : COMPLETED WITH ERRORS'
    $lines | Should -Contain '  Restart failed: Access denied (fallback: shutdown.exe exited with code 5)'
    $lines | Should -Contain '  Finalize completed after an earlier failure: restart failed'
    ($lines -join "`n") | Should -Not -Match 'did not finish'
  }
  It 'saves what it did, because nobody else saves it when it is called on its own' {
    $ctx = New-FinalizeContext
    $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'restart failed'
    Complete-SetupFinalization -Context $ctx | Out-Null
    $saved = Read-RunState -Root $ctx.Root
    $saved.EndedAt | Should -Not -BeNullOrEmpty
    $saved.FinalRebootDone | Should -BeTrue
    $saved.Steps['finalize'].Status | Should -Be 'Done'
  }
  It 'does not restore the power settings again when Phase A already ran' {
    $ctx = New-FinalizeContext -PhaseB
    $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'restart failed'
    (Complete-SetupFinalization -Context $ctx).Status | Should -Be 'Done'
    $script:restoreCalls | Should -Be 0
  }
  It 'is never green after an earlier finalize failure that left no error' {
    $ctx = New-FinalizeContext -PhaseB
    $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'attempt cap reached'
    Complete-SetupFinalization -Context $ctx | Out-Null
    (Get-RunVerdict -State $ctx.State).Color | Should -Be 'YELLOW'
    $ctx.State.Notes | Should -Contain 'Finalize completed after an earlier failure: attempt cap reached'
  }
  It 'adds no such note on the normal path (finalize running)' {
    $ctx = New-FinalizeContext -PhaseB
    Complete-SetupFinalization -Context $ctx | Out-Null
    @($ctx.State.Notes).Count | Should -Be 0
    (Get-RunVerdict -State $ctx.State).Color | Should -Be 'GREEN'
  }
  It 'marks finalize Failed, and saves it, when the report cannot be written' {
    $ctx = New-FinalizeContext -PhaseB
    $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'restart failed'
    $ctx.LogDir = Join-Path $ctx.Root 'state.json\Logs'   # a folder under a file cannot exist
    $r = Complete-SetupFinalization -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Setup report could not be written'
    $ctx.State.Steps['finalize'].Status | Should -Be 'Failed'
    $ctx.State.Steps['finalize'].Message | Should -Be 'Setup report could not be written'
    (Read-RunState -Root $ctx.Root).Steps['finalize'].Status | Should -Be 'Failed'
    $script:unregisterCalls | Should -Be 1
  }
}

# Task 13: Phase A restores the power settings and Phase B deletes Downloads\ (the ODT and office.xml), so
# neither may race a Microsoft 365 setup still running in the background.
Describe 'Finalize waits for a background Microsoft 365 (Task 13)' {
  BeforeEach { Initialize-FinalizeMocks; $script:order = New-Object System.Collections.ArrayList }
  AfterEach { $script:blocked -join "; " | Should -BeNullOrEmpty }

  It 'waits for a live background Office first, in the step and in Complete-SetupFinalization (R26)' {
    Mock Wait-OfficeBackground { [void]$script:order.Add('office'); @{ Outcome = 'None' } }
    Mock Restore-FinalPowerSettings { [void]$script:order.Add('restore'); $true }
    Mock Invoke-WindowsActivation { [void]$script:order.Add('activate'); 'NotNeeded' }
    Mock Test-ChromeInstalled { [void]$script:order.Add('chrome'); $true }

    $null = Invoke-StepFinalize -Context (New-FinalizeContext)   # Phase A
    @($script:order)[0..1] | Should -Be @('office', 'restore')

    $script:order.Clear()   # the R26 path: Phase A never ran
    $ctx = New-FinalizeContext; $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'restart failed'
    $null = Complete-SetupFinalization -Context $ctx
    @($script:order)[0..1] | Should -Be @('office', 'activate')

    $script:order.Clear()   # Phase B after the final restart (through the step it waits twice; the second is a no-op)
    $null = Complete-SetupFinalization -Context (New-FinalizeContext -PhaseB)
    @($script:order)[0..1] | Should -Be @('office', 'chrome')

    Should -Invoke Wait-OfficeBackground -ParameterFilter { $Purpose -eq 'Finish' }
    Should -Invoke Wait-OfficeBackground -Times 0 -Exactly -ParameterFilter { $Purpose -ne 'Finish' }
  }
  It 'without a background Office the real wait does nothing' {
    Mock Wait-SetupDelay { throw 'must not wait' }; Mock Get-Process { throw 'must not look' }
    $ctx = New-FinalizeContext -PhaseB
    (Invoke-StepFinalize -Context $ctx).Status | Should -Be 'Done'
  }
}

Describe 'Invoke-StepFinalize through the runner' {
  BeforeEach { Initialize-FinalizeMocks }
  AfterEach { $script:blocked -join "; " | Should -BeNullOrEmpty }

  It 'lists each note and error once and finishes the finalize step' {
    $script:restoreResult = $false
    $script:activation = 'Not activated'
    $script:bitlocker = @{ Presence = 'Present'; Volume = $null; Status = 1 }
    $ctx = New-FinalizeContext
    $ctx.State.Steps['finalize'].Status = 'pending'
    Invoke-SetupRun -Context $ctx | Should -Be 'Completed'
    $ctx.State.Steps['finalize'].Status | Should -Be 'Done'
    $ctx.State.Steps['finalize'].Message | Should -Be 'Finalized'
    foreach ($note in 'Some power settings could not be restored', 'Windows not activated') {
      @($ctx.State.Notes | Where-Object { $_ -eq $note }).Count | Should -Be 1
    }
    @($ctx.State.Errors | Where-Object { $_ -eq 'Drive still encrypted and not decrypting' }).Count | Should -Be 1
    $v = Get-RunVerdict -State $ctx.State
    @($v.Notes | Where-Object { $_ -eq 'Windows not activated' }).Count | Should -Be 1
    @($v.Failures | Where-Object { $_ -like '*did not finish*' }).Count | Should -Be 0
    $lines = Get-ReportLines -Context $ctx
    @($lines | Where-Object { $_ -eq '  Windows not activated' }).Count | Should -Be 1
    @($lines | Where-Object { $_ -eq '  Drive still encrypted and not decrypting' }).Count | Should -Be 1
  }
  It 'restarts once in Phase A, then runs Phase B when the run resumes' {
    $script:signals.ComputerRenamePending = $true
    $ctx = New-FinalizeContext
    $ctx.State.Steps['finalize'].Status = 'pending'
    Invoke-SetupRun -Context $ctx -CountdownSeconds 0 -RestartAction { } | Should -Be 'Rebooting'
    $ctx.State.RebootCount | Should -Be 1
    $ctx.State.Steps['finalize'].Status | Should -Be 'pending'
    $script:unregisterCalls | Should -Be 0

    # The resume after the restart: a new process reads state.json.
    $resumed = $ctx.Clone(); $resumed.State = Read-RunState -Root $ctx.Root
    $resumed.State.FinalRebootDone | Should -BeTrue
    Invoke-SetupRun -Context $resumed -CountdownSeconds 0 -RestartAction { throw 'must not restart twice' } | Should -Be 'Completed'
    $resumed.State.Steps['finalize'].Status | Should -Be 'Done'
    $script:restoreCalls | Should -Be 1
    $script:unregisterCalls | Should -Be 1
    $resumed.State.RebootCount | Should -Be 1
    Test-Path -LiteralPath (Join-Path $ctx.LogDir 'Setup-Report.txt') | Should -BeTrue
  }
  It 'leaves a failed final restart to Complete-SetupFinalization, which finishes the run red' {
    $script:signals.ComputerRenamePending = $true
    $ctx = New-FinalizeContext
    $ctx.State.Steps['finalize'].Status = 'pending'
    Invoke-SetupRun -Context $ctx -CountdownSeconds 0 -RestartAction { throw 'Access denied' } -FallbackRestartAction { throw 'shutdown.exe exited with code 5' } |
      Should -Be 'Completed'
    # What the entry point finds: finalize Failed, no report, the resume task still registered.
    $ctx.State.Steps['finalize'].Status | Should -Be 'Failed'
    $ctx.State.Steps['finalize'].Message | Should -Be 'restart failed'
    Test-Path -LiteralPath (Join-Path $ctx.LogDir 'Setup-Report.txt') | Should -BeFalse
    $script:unregisterCalls | Should -Be 0

    $r = Complete-SetupFinalization -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    $script:restoreCalls | Should -Be 1   # Phase A already restored the power settings
    $script:unregisterCalls | Should -Be 1
    (Get-RunVerdict -State $ctx.State).Color | Should -Be 'RED'
    $lines = Get-ReportLines -Context $ctx
    $lines | Should -Contain 'Result       : COMPLETED WITH ERRORS'
    $lines | Should -Contain '  Restart failed: Access denied (fallback: shutdown.exe exited with code 5)'
  }
}

Describe 'Chrome as default: wait before the policy goes (spec 9.4)' {
  BeforeAll {
    # A run whose default-browser step is Done and set its policy SetMinutes after the last boot
    # ($script:lastBoot): negative = a boot (and so a sign-in) since, positive = nobody signed in since.
    # -NoSetAt leaves the step without SetAtUtc.
    function New-BrowserPolicyContext {
      param([int]$SetMinutes = -30, [switch]$NoSetAt, [switch]$PhaseB, [int]$RebootCount = 0)
      $ctx = New-FinalizeContext -PhaseB:$PhaseB -Plan @('default-browser', 'finalize') -RebootCount $RebootCount
      $ctx.State.Steps['default-browser'].Data = @{ RebootCountAtSet = 0 }
      if (-not $NoSetAt) { $ctx.State.Steps['default-browser'].Data['SetAtUtc'] = $script:lastBoot.AddMinutes($SetMinutes).ToString('o') }
      $ctx
    }
  }
  BeforeEach { Initialize-FinalizeMocks }
  AfterEach { $script:blocked -join "; " | Should -BeNullOrEmpty }

  It 'waits until Chrome is the default, then removes the policy' {
    $script:regPresent[$script:SystemPolicyKey] = @{ DefaultAssociationsConfiguration = $script:assocPath }
    $script:reads = 0
    $script:policyAtReads = New-Object System.Collections.ArrayList
    Mock Get-DefaultBrowserProgId {
      $script:reads++
      [void]$script:policyAtReads.Add($script:regPresent[$script:SystemPolicyKey].ContainsKey('DefaultAssociationsConfiguration'))
      if ($script:reads -ge 4) { 'ChromeHTML' } else { 'MSEdgeHTM' }
    }
    $ctx = New-BrowserPolicyContext -PhaseB -SetMinutes -30   # the final restart came after the policy
    $null = Complete-SetupFinalization -Context $ctx
    $script:reads | Should -Be 4
    Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 5 }
    $script:sleeps.Count | Should -Be 3
    (@($ctx.State.Notes) -contains 'Chrome is not the default browser') | Should -BeFalse
    # The policy was still there at every read, the 4th included, and was removed after it.
    @($script:policyAtReads) | Should -Be @($true, $true, $true, $true)
    @($script:regRemoved | Where-Object { $_.Path -eq $script:SystemPolicyKey -and $_.Name -eq 'DefaultAssociationsConfiguration' }).Count | Should -Be 1
  }
  It 'gives up after 120 s with the yellow Note' {
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    $ctx = New-BrowserPolicyContext -PhaseB -SetMinutes -30
    $null = Complete-SetupFinalization -Context $ctx
    Should -Invoke Get-DefaultBrowserProgId -Times 25 -Exactly
    Should -Invoke Start-Sleep -Times 24 -Exactly
    ($script:sleeps | Measure-Object -Sum).Sum | Should -Be 120
    $ctx.State.Notes | Should -Contain 'Chrome is not the default browser'
  }
  It 'reads once when the default-browser step did not set the policy' {
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    $ctx = New-FinalizeContext -PhaseB -Plan @('default-browser', 'finalize')
    $ctx.State.Steps['default-browser'].Status = 'Skipped'
    $null = Complete-SetupFinalization -Context $ctx
    Should -Invoke Get-DefaultBrowserProgId -Times 1 -Exactly
    $script:sleeps.Count | Should -Be 0
    $ctx.State.Notes | Should -Contain 'Chrome is not the default browser'
  }
  It 'reads once when the plan has no default-browser step' {
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    $ctx = New-FinalizeContext -PhaseB
    $null = Complete-SetupFinalization -Context $ctx
    Should -Invoke Get-DefaultBrowserProgId -Times 1 -Exactly
    $script:sleeps.Count | Should -Be 0
  }
  It 'never waits when Chrome is not installed' {
    $script:chromeInstalled = $false
    $ctx = New-BrowserPolicyContext -PhaseB -SetMinutes -30
    $null = Complete-SetupFinalization -Context $ctx
    Should -Invoke Get-DefaultBrowserProgId -Times 0 -Exactly
    $script:sleeps.Count | Should -Be 0
  }
  # Spec 9.4: the wait is only for the time right after the final restart's sign-in. Without a sign-in
  # since the policy was set, Windows cannot have applied it, so 120 s would be dead time.
  It 'reads once when nobody can be known to have signed in since the policy was set: <Case>' -ForEach @(
    @{ Case = 'policy set after the last boot'; SetMinutes = 30; NoSetAt = $false; BootUnknown = $false }
    @{ Case = 'no SetAtUtc';                    SetMinutes = 0;  NoSetAt = $true;  BootUnknown = $false }
    @{ Case = 'last boot time unknown';         SetMinutes = -30; NoSetAt = $false; BootUnknown = $true }
  ) {
    if ($BootUnknown) { Mock Get-LastBootUtc { $null } }
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    $ctx = New-BrowserPolicyContext -PhaseB -SetMinutes $SetMinutes -NoSetAt:$NoSetAt
    $null = Complete-SetupFinalization -Context $ctx
    Should -Invoke Get-DefaultBrowserProgId -Times 1 -Exactly
    $script:sleeps.Count | Should -Be 0
    $ctx.State.Notes | Should -Contain 'Chrome is not the default browser'
  }
  It 'reads once when the final restart was refused: <Case>' -ForEach @(
    @{ Case = 'no resume task'; ResumeTaskMissing = $true;  RebootCount = 0 }
    @{ Case = 'reboot cap';     ResumeTaskMissing = $false; RebootCount = 12 }
  ) {
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    # Phase A: the policy was set after the last boot, so the final restart is needed, and refused.
    $ctx = New-BrowserPolicyContext -SetMinutes 10 -RebootCount $RebootCount
    $ctx.State.ResumeTaskMissing = $ResumeTaskMissing
    $r = Invoke-StepFinalize -Context $ctx
    $r.Reboot | Should -Be 'None'
    Should -Invoke Get-DefaultBrowserProgId -Times 1 -Exactly
    $script:sleeps.Count | Should -Be 0
    $ctx.State.Notes | Should -Contain 'Chrome is not the default browser'
  }
  It 'reads once on the R26 path (the final restart failed, nobody signed in since)' {
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    $ctx = New-BrowserPolicyContext -SetMinutes 10
    $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'restart failed'
    $null = Complete-SetupFinalization -Context $ctx
    Should -Invoke Get-DefaultBrowserProgId -Times 1 -Exactly
    $script:sleeps.Count | Should -Be 0
  }
  It 'waits in the same call when Phase A needed no restart because a boot came after the policy' {
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    $ctx = New-BrowserPolicyContext -SetMinutes -30
    $null = Invoke-StepFinalize -Context $ctx
    Should -Invoke Get-DefaultBrowserProgId -Times 25 -Exactly
  }
}

Describe 'Wait-ChromeDefault' {
  BeforeEach { Initialize-FinalizeMocks }
  It 'is $true at once, without a wait, when Chrome already is the default' {
    Mock Get-DefaultBrowserProgId { 'ChromeHTML' }
    Wait-ChromeDefault | Should -BeTrue
    Should -Invoke Get-DefaultBrowserProgId -Times 1 -Exactly
    $script:sleeps.Count | Should -Be 0
  }
  It 'counts reads, not clock time: Attempts reads and one wait fewer' {
    Mock Get-DefaultBrowserProgId { $null }
    Wait-ChromeDefault -Attempts 3 -PollSeconds 2 | Should -BeFalse
    Should -Invoke Get-DefaultBrowserProgId -Times 3 -Exactly
    @($script:sleeps) | Should -Be @(2, 2)
  }
  It 'shows its 2-minute limit while it waits and removes it after' {
    Clear-SetupNow
    $script:limits = New-Object System.Collections.ArrayList
    Mock Get-DefaultBrowserProgId { [void]$script:limits.Add((Get-SetupNow).Wait.LimitMinutes); $null }
    Wait-ChromeDefault | Should -BeFalse
    $script:limits.Count | Should -Be 25; $script:limits[0] | Should -Be 2
    (Get-SetupNow).Wait | Should -BeNullOrEmpty
  }
}

Describe 'Windows activation attempt (spec 9.5)' {
  BeforeEach {
    Initialize-FinalizeMocks
    Mock Get-ActivationStatus { 'Not activated' }
    Mock Get-CimInstance { [pscustomobject]@{ LicenseStatus = 5 } } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
    Mock Invoke-PowerShellChild { @{ ExitCode = 0; TimedOut = $false; Output = '' } }
  }
  AfterEach { $script:blocked -join "; " | Should -BeNullOrEmpty }

  It 'activates in a 3-minute child when a key is installed but not activated' {
    Invoke-WindowsActivation | Should -Be 'Activated'
    Should -Invoke Invoke-PowerShellChild -Times 1 -Exactly -ParameterFilter { $TimeoutMinutes -eq 3 -and $Command -match "MethodName Activate" -and $Command -match '55c92734-d682-4d71-983e-d6ec3f16059f' }
  }
  It 'sends exactly the activation command of the brief' {
    $script:expectedCommand = (@(
        '$ErrorActionPreference = ''Stop''; $f = "ApplicationID=''55c92734-d682-4d71-983e-d6ec3f16059f'' AND PartialProductKey IS NOT NULL AND LicenseStatus <> 1"'
        'foreach ($p in @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $f)) { $r = Invoke-CimMethod -InputObject $p -MethodName Activate; if ($r.ReturnValue -ne 0) { exit 2 } }'
      ) -join "`n")
    $null = Invoke-WindowsActivation
    Should -Invoke Invoke-PowerShellChild -Times 1 -Exactly -ParameterFilter { ($Command -replace "`r`n", "`n") -ceq $script:expectedCommand }
  }
  It 'asks only for Windows product keys, read-only, with the filter Get-ActivationStatus uses' {
    $null = Invoke-WindowsActivation
    Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' -and $Filter -eq "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" }
    Should -Invoke Invoke-CimMethod -Times 0 -Exactly
  }
  It 'does nothing when activated, unknown, or without a product key' {
    Mock Get-ActivationStatus { 'Activated' }; Invoke-WindowsActivation | Should -Be 'NotNeeded'
    Mock Get-ActivationStatus { 'Unknown' }; Invoke-WindowsActivation | Should -Be 'NotNeeded'
    Mock Get-ActivationStatus { 'Not activated' }; Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }; Invoke-WindowsActivation | Should -Be 'NotNeeded'
    Should -Invoke Invoke-PowerShellChild -Times 0 -Exactly
  }
  It 'a timeout or a failure is a WARN and never throws' {
    Mock Invoke-PowerShellChild { @{ ExitCode = $null; TimedOut = $true; Output = '' } }; Invoke-WindowsActivation | Should -Be 'Failed'
    Mock Invoke-PowerShellChild { @{ ExitCode = 2; TimedOut = $false; Output = '' } }; Invoke-WindowsActivation | Should -Be 'Failed'
    Mock Invoke-PowerShellChild { throw 'cannot start' }; Invoke-WindowsActivation | Should -Be 'Failed'
    Should -Invoke Write-SetupLog -Times 3 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq 'Windows activation attempt failed' }
  }
  It 'a product-key query that fails is a WARN and Failed, without a child' {
    Mock Get-CimInstance { Write-Error -Message 'RPC server unavailable' -Category ResourceUnavailable } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
    Invoke-WindowsActivation | Should -Be 'Failed'
    Should -Invoke Invoke-PowerShellChild -Times 0 -Exactly
    @($script:logs | Where-Object { $_.Level -eq 'WARN' }).Count | Should -Be 1
  }
  It 'Phase A tries it before deciding the final restart; Phase B after the restart does not' {
    $script:order = New-Object System.Collections.ArrayList
    $ctx = New-FinalizeContext
    $script:activationRoot = $ctx.Root
    Mock Invoke-WindowsActivation {
      # Right after Restore-PostSetupSettings and its save.
      [void]$script:order.Add('activate'); $script:savedAtActivation = (Read-RunState -Root $script:activationRoot).FinalRebootDone; 'Activated'
    }
    Mock Test-FinalRebootNeeded { [void]$script:order.Add('restart?'); $true }
    $r = Invoke-StepFinalize -Context $ctx
    $r.Reboot | Should -Be 'Now'
    @($order) | Should -Be @('activate', 'restart?')
    $script:savedAtActivation | Should -BeTrue
    $script:restoreCalls | Should -Be 1
    $null = Invoke-StepFinalize -Context $ctx   # the call after the final restart = Phase B
    Should -Invoke Invoke-WindowsActivation -Times 1 -Exactly
  }
  It 'the R26 path without Phase A tries it once, before it restores the settings' {
    Mock Invoke-WindowsActivation { $script:restoreAtActivation = $script:restoreCalls; 'Failed' }
    $ctx = New-FinalizeContext
    $ctx.State.Steps['finalize'].Status = 'Failed'; $ctx.State.Steps['finalize'].Message = 'restart failed'
    $null = Complete-SetupFinalization -Context $ctx
    Should -Invoke Invoke-WindowsActivation -Times 1 -Exactly
    $script:restoreAtActivation | Should -Be 0
    $script:restoreCalls | Should -Be 1
    $ctx.State.Notes | Should -Contain 'Windows not activated'
  }
}
