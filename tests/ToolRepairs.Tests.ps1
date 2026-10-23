# tests/ToolRepairs.Tests.ps1
# Repair & diagnostics Task 6 (repair spec 6.2, 6.3; builder check 6; ruling RD-R13): Standard repair, Post-clone and
# the DISM retry with a local source (src\Repair\ToolRepairs.ps1 and their catalog rows), end to end on the child side.
#
# SAFETY: this runs on Ben's real PC. For real, these steps run sc.exe start w32time, w32tm.exe /resync, dism.exe
# /RestoreHealth, sfc.exe /scannow, reagentc.exe /enable and pnputil.exe /scan-devices, start PowerShell grandchildren
# (Repair-Volume -Scan, Get-PnpDevice, Get-WindowsImage, Get-PhysicalDisk, Optimize-Volume, Repair-WindowsImage
# -StartComponentCleanup, a Windows Update search), and read services, CIM, the registry, the BCD, ReAgent.xml and the
# drives. Here nothing is started, nothing is changed and no answer comes from this PC:
#   - Invoke-ToolNative answers from $script:exit (by file name, 0 by default; $null is a timeout) and records the
#     file name in $script:native, '<file name> <args>' in $script:nativeLines and the arguments in $script:nativeArgs;
#     Invoke-ToolJsonChild answers from $script:gc (by grandchild name; $script:gcFail makes one fail or time out) and
#     records each command in $script:gcCommands; Invoke-External and Invoke-PowerShellChild are never reached (their
#     mocks record the call in $script:blocked and throw); Wait-SetupDelay does not sleep;
#   - Read-ToolSfcResult answers $script:sfc (one result per pass); Get-ServicingRebootSignals reads $script:pending,
#     which $script:pendingAfter = '<step>' turns on once that step has run; Get-Service answers $script:services;
#     Test-ToolInternet answers ClockOffsetSeconds = $script:offsetSeconds; Get-ItemProperty reads $script:reg (by
#     value name); Get-ToolBcdState answers $script:bcd (one state per read, the last one repeated) and
#     Get-ToolReAgentState $script:reagent; Get-CimInstance answers Win32_PageFileSetting from $script:pageFiles;
#     Test-Path answers from $script:existing; Get-ToolInstalledPrograms answers $script:programs;
#     Get-SignedInUserName is blocked unless a test replaces it;
#   - Set-ItemProperty, New-ItemProperty and New-Item are recorders (these steps never write the registry or create an
#     item: $script:written stays empty);
#   - safety nets as in ToolEngine.Tests: Start-BackgroundExternal, Stop-ProcessTree, Start-Process, Restart-Computer,
#     Stop-Service, Start-Service, Rename-Item, Remove-BitsTransfer, Set-NetIPInterface, New-NetIPAddress,
#     Set-DnsClientServerAddress, Optimize-Volume, Repair-Volume, Repair-WindowsImage and Remove-ItemProperty record
#     their name in $script:blocked, then throw; AfterEach asserts that nothing was blocked and nothing was written;
#   - every file a test writes is under $TestDrive (the run folders under $TestDrive\Root\Tool).
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Common\Config', 'State\State', 'Steps\Winget', 'Engine\Reboot',
                 'UI\StartScreen', 'Toolbox\Strings', 'Entry\Cleanup', 'Detect\Detection', 'Detect\PcName', 'Report\Report', 'Repair\ToolEngine',
                 'Repair\ToolChecks', 'Repair\ToolSafety', 'Repair\ToolRepairs') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:root = Join-Path $TestDrive 'Root'
  $script:repairsFile = "$PSScriptRoot\..\src\Repair\ToolRepairs.ps1"
  # The real code of two mocked functions, for the tests that run it (Pester 6 never falls through to the original).
  $script:realSfcResult = ${function:Read-ToolSfcResult}
  $script:realSourceRoots = ${function:Get-ToolInstallSourceRoots}

  # The args the window writes for -Action on a Dell laptop, stick E:\, every chip ok (Options per test).
  function New-TestArgs {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$RunId, [hashtable]$Options = @{})
    @{ Version = 1; Action = $Action; RunId = $RunId
       DeadlineUtc = [datetime]::UtcNow.AddMinutes(600).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
       BudgetSeconds = 36000; SessionDir = ''; StickRoot = 'E:\'; Complaint = ''; Done = @()
       Identity = @{ Key = 'SN-7HX2K93'; FolderPart = '7HX2K93'; Serial = '7HX2K93'; BiosUuid = ''; ComputerName = 'PC1'
                     Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; Brand = 'DELL' }
       Machine = @{ IsLaptop = $true; OsBuild = 26200; Arch = 'x64' }
       Strip = @{ Restart = 'ok'; Free = 'ok'; BitLocker = 'ok'; Internet = 'ok'; Disk = 'ok' }
       Options = $Options }
  }

  # A run of the catalog action -Action in a fresh run folder; it is also the run the servicing-signal mock watches.
  function New-ActionRun {
    param([Parameter(Mandatory)][string]$Action, [hashtable]$Options = @{})
    $runId = '20261022-101500-' + $Action
    $dir = Join-Path $script:root "Tool\$runId"
    if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    [void][IO.Directory]::CreateDirectory($dir)
    $script:currentRun = New-ToolRun -ToolArgs (New-TestArgs -Action $Action -RunId $runId -Options $Options) -Config $script:cfg -Root $script:root
    $script:currentRun
  }

  # What every grandchild answers on a healthy PC (the Data of Invoke-ToolJsonChild, by grandchild name).
  function Get-HealthyAnswers {
    @{
      volumeScan       = @{ Result = 'NoErrorsFound' }
      devices          = @{ Items = @() }
      activation       = @{ Statuses = @(1) }
      media            = @{ Media = @('SSD') }
      retrim           = @{ Done = $true }
      componentCleanup = @{ Done = $true; RestartNeeded = $false }
      wuScan           = @{ ResultCode = 2; Count = 0 }
      # One install.wim: index 1 Core x64, index 6 Professional x64 en-US build 26100, index 7 Professional ARM64
      # (the architecture as the DISM module gives it: a number or the enum's name).
      installImage     = @{ Items = @(
          @{ Index = 1; Name = 'Windows 11 Home'; EditionId = 'Core'; Architecture = '9'; Languages = @('en-US'); Version = '10.0.26100.1742' }
          @{ Index = 6; Name = 'Windows 11 Pro'; EditionId = 'Professional'; Architecture = 'x64'; Languages = @('en-US (Default)'); Version = '10.0.26100.1742' }
          @{ Index = 7; Name = 'Windows 11 Pro'; EditionId = 'Professional'; Architecture = '12'; Languages = @('en-US'); Version = '10.0.26100.1742' }) }
    }
  }

  # The mocked Invoke-ToolJsonChild's answer: the data goes through JSON and back, as the real grandchild's file does.
  function Get-TestChildAnswer {
    param([string]$Name)
    if ($script:gcFail.ContainsKey($Name)) {
      $e = [string]$script:gcFail[$Name]
      return @{ Ok = $false; TimedOut = ($e -eq 'timed out'); Data = $null; Error = $e }
    }
    if (-not $script:gc.ContainsKey($Name)) { return @{ Ok = $false; TimedOut = $false; Data = $null; Error = "no answer for $Name" } }
    $json = ConvertTo-Json -InputObject $script:gc[$Name] -Depth 6 -Compress
    @{ Ok = $true; TimedOut = $false; Data = (ConvertTo-HashtableDeep -InputObject (ConvertFrom-Json -InputObject $json)); Error = $null }
  }

  # The offer Find-ToolInstallSource gives for the install.wim above on a Professional x64 he-IL PC of build 26200.
  function Get-TestOffer {
    @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = 6; Edition = 'Professional'; Arch = 'x64'; Languages = @('en-US'); Build = '26100'
       BuildDiffers = $true; LanguageDiffers = $true; PcLanguage = 'he-IL' }
  }

  function Get-FindingRows { param($Run) @(foreach ($f in $Run.Findings) { '{0}|{1}' -f $f.Level, $f.Code }) }
  function Get-FindingCodes { param($Run) @(foreach ($f in $Run.Findings) { [string]$f.Code }) }
  function Get-FindingArgs { param($Run, [string]$Code) @(foreach ($f in $Run.Findings) { if ($f.Code -eq $Code) { $f.Args } }) }
  function Get-StepStatus { param($Run, [string]$Id) foreach ($s in $Run.Steps) { if ($s.Id -eq $Id) { return $s.Status } } }
  function Get-FindingCount { param($Run, [string]$Code) @(foreach ($f in $Run.Findings) { if ($f.Code -eq $Code) { $f } }).Count }

  # One CBS.log line as Windows writes it (the stamp floored to the second, invariant culture), appended to
  # $script:cbsLog.
  function Add-CbsLine {
    param([datetime]$At, [string]$Text)
    $line = '{0}, Info                  CSI    00000001 {1}' -f $At.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $Text
    [IO.File]::AppendAllText($script:cbsLog, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
  }
}

Describe 'ToolRepairs (repair Task 6)' {
  BeforeEach {
    $script:blocked = New-Object System.Collections.ArrayList
    $script:written = New-Object System.Collections.ArrayList
    $script:native = New-Object System.Collections.ArrayList
    $script:nativeLines = New-Object System.Collections.ArrayList
    $script:nativeArgs = New-Object System.Collections.ArrayList
    $script:exit = @{}
    $script:gc = Get-HealthyAnswers; $script:gcFail = @{}; $script:gcCommands = @{}
    $script:sfc = @(); $script:sfcCalls = 0
    $script:pending = $false; $script:pendingAfter = $null; $script:currentRun = $null
    $script:services = @{ w32time = @{ Status = 'Stopped'; StartType = 'Manual' } }
    $script:offsetSeconds = 4.2
    $script:reg = @{ EditionID = 'Professional'; InstallLanguage = '040D'; DisableDeleteNotification = 0 }
    $script:bcd = @('On'); $script:bcdCalls = 0; $script:reagent = 'On'
    $script:pageFiles = @(); $script:existing = @('C:\'); $script:programs = @(); $script:scStarts = $true
    $script:onNative = $null; $script:realCbs = $false; $script:sourceRoots = @('E:\', 'F:\')

    Mock Invoke-ToolNative {
      $file = [IO.Path]::GetFileName($FilePath)
      [void]$script:native.Add($file); [void]$script:nativeLines.Add(('{0} {1}' -f $file, $ArgumentList).Trim()); [void]$script:nativeArgs.Add($ArgumentList)
      $code = 0
      if ($script:exit.ContainsKey($file)) { $code = $script:exit[$file] }
      # sc.exe start w32time that succeeds starts the service (unless $script:scStarts is $false).
      if ($script:scStarts -and $file -eq 'sc.exe' -and $ArgumentList -eq 'start w32time' -and ($code -eq 0 -or $code -eq 1056) -and $null -ne $code -and $script:services.ContainsKey('w32time')) {
        $script:services['w32time']['Status'] = 'Running'
      }
      if ($null -ne $script:onNative) { & $script:onNative $file $ArgumentList }
      @{ ExitCode = $code; TimedOut = ($null -eq $code); OutputPath = $null }
    }
    Mock Invoke-ToolJsonChild { $script:gcCommands[$Name] = $Command; Get-TestChildAnswer -Name $Name }
    # $script:realCbs lets a test run the real CBS.log parser (Read-ToolSfcResult) on a synthetic log.
    Mock Read-ToolSfcResult {
      if ($script:realCbs) { return (& $script:realSfcResult -Run $Run -Since $Since) }
      $answer = @{ Ran = $true; VerifyStarted = 1; VerifyCompleted = 1; VerifyComplete = $true; SrLines = 3; Repaired = 0; CannotRepair = 0; Corrupt = 0; Lines = [string[]]@(); Settled = $true }
      $i = $script:sfcCalls; $script:sfcCalls++
      $queue = @($script:sfc)
      if ($i -lt $queue.Count) { foreach ($k in $queue[$i].Keys) { $answer[$k] = $queue[$i][$k] } }
      $answer
    }
    Mock Get-ServicingRebootSignals {
      $on = [bool]$script:pending
      if (-not $on -and $script:pendingAfter -and $null -ne $script:currentRun) {
        foreach ($s in $script:currentRun.Steps) { if ($s.Id -eq $script:pendingAfter -and $s.Status -notin 'pending', 'running') { $on = $true } }
      }
      @{ CbsRebootPending = $on; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $false; ComputerRenamePending = $false }
    }
    Mock Get-Service {
      $s = $script:services[[string]$Name]
      if ($null -eq $s) { Write-Error -Message "Cannot find any service with service name '$Name'." -ErrorId 'NoServiceFoundForGivenName' -Category ObjectNotFound; return }
      [pscustomobject]@{ Name = [string]$Name; Status = $s.Status; StartType = $s.StartType }
    }
    Mock Test-ToolInternet { @{ Tcp = $true; Https = $true; Probe = 'ok'; ClockOffsetSeconds = $script:offsetSeconds; Chip = @{ Level = 'ok'; Args = @(); Detail = @{} } } }
    Mock Get-ItemProperty { if ($Name -and $script:reg.ContainsKey([string]$Name)) { [pscustomobject]@{ ([string]$Name) = $script:reg[[string]$Name] } } }
    Mock Get-ToolBcdState { $i = [math]::Min($script:bcdCalls, @($script:bcd).Count - 1); $script:bcdCalls++; @{ Recovery = @($script:bcd)[$i]; SafeBoot = $null } }
    Mock Get-ToolReAgentState { $script:reagent }
    Mock Get-CimInstance {
      if ($ClassName -eq 'Win32_PageFileSetting') { foreach ($p in @($script:pageFiles)) { [pscustomobject]@{ Name = $p } }; return }
      [void]$script:blocked.Add('Get-CimInstance'); throw 'not mocked: Get-CimInstance'
    }
    Mock Test-Path { [bool](@($script:existing) -contains [string]$LiteralPath) }
    # The drives an install file may be on (the stick, a mounted ISO); a call that passes -Drives runs the real code.
    Mock Get-ToolInstallSourceRoots {
      if ($null -ne $Drives) { & $script:realSourceRoots -StickRoot $StickRoot -Drives $Drives } else { @($script:sourceRoots) }
    }
    Mock Get-WinEvent { [void]$script:blocked.Add('Get-WinEvent'); throw 'not mocked: Get-WinEvent' }
    Mock Get-SignedInUserName { [void]$script:blocked.Add('Get-SignedInUserName'); throw 'not mocked: Get-SignedInUserName' }
    Mock Wait-SetupDelay { }
    # Recorders: nothing here may write the registry or create an item.
    Mock Set-ItemProperty { [void]$script:written.Add('Set-ItemProperty') }
    Mock New-ItemProperty { [void]$script:written.Add('New-ItemProperty') }
    Mock New-Item { [void]$script:written.Add('New-Item') }
    # Never reached: the runners above them are mocked.
    Mock Invoke-External { [void]$script:blocked.Add('Invoke-External'); throw 'blocked by the test: Invoke-External' }
    Mock Invoke-PowerShellChild { [void]$script:blocked.Add('Invoke-PowerShellChild'); throw 'blocked by the test: Invoke-PowerShellChild' }
    # Safety nets.
    Mock Start-BackgroundExternal { [void]$script:blocked.Add('Start-BackgroundExternal'); throw 'blocked by the test: Start-BackgroundExternal' }
    Mock Stop-ProcessTree { [void]$script:blocked.Add('Stop-ProcessTree'); throw 'blocked by the test: Stop-ProcessTree' }
    Mock Start-Process { [void]$script:blocked.Add('Start-Process'); throw 'blocked by the test: Start-Process' }
    Mock Restart-Computer { [void]$script:blocked.Add('Restart-Computer'); throw 'blocked by the test: Restart-Computer' }
    Mock Stop-Service { [void]$script:blocked.Add('Stop-Service'); throw 'blocked by the test: Stop-Service' }
    Mock Start-Service { [void]$script:blocked.Add('Start-Service'); throw 'blocked by the test: Start-Service' }
    Mock Rename-Item { [void]$script:blocked.Add('Rename-Item'); throw 'blocked by the test: Rename-Item' }
    Mock Remove-BitsTransfer { [void]$script:blocked.Add('Remove-BitsTransfer'); throw 'blocked by the test: Remove-BitsTransfer' }
    Mock Set-NetIPInterface { [void]$script:blocked.Add('Set-NetIPInterface'); throw 'blocked by the test: Set-NetIPInterface' }
    Mock New-NetIPAddress { [void]$script:blocked.Add('New-NetIPAddress'); throw 'blocked by the test: New-NetIPAddress' }
    Mock Set-DnsClientServerAddress { [void]$script:blocked.Add('Set-DnsClientServerAddress'); throw 'blocked by the test: Set-DnsClientServerAddress' }
    Mock Optimize-Volume { [void]$script:blocked.Add('Optimize-Volume'); throw 'blocked by the test: Optimize-Volume' }
    Mock Repair-Volume { [void]$script:blocked.Add('Repair-Volume'); throw 'blocked by the test: Repair-Volume' }
    Mock Repair-WindowsImage { [void]$script:blocked.Add('Repair-WindowsImage'); throw 'blocked by the test: Repair-WindowsImage' }
    Mock Remove-ItemProperty { [void]$script:blocked.Add('Remove-ItemProperty'); throw 'blocked by the test: Remove-ItemProperty' }
  }

  AfterEach {
    @($script:blocked) | Should -BeNullOrEmpty
    @($script:written) | Should -BeNullOrEmpty
    $script:SetupLogPath = $null
    Unregister-SetupTick
  }

  Describe 'the catalog rows (repair plan, Actions and steps)' {
    It 'standard, postClone and dismSource are repairs with a confirmation that log to the session, their steps in the kit''s order' {
      foreach ($id in 'standard', 'postClone', 'dismSource') {
        $a = $script:ToolActionCatalog[$id]
        $a | Should -Not -BeNullOrEmpty -Because $id
        $a.Kind | Should -Be 'repair' -Because $id; $a.Confirm | Should -Be 'confirm' -Because $id
        $a.NeedsStick | Should -BeFalse -Because $id; $a.LogLocal | Should -BeFalse -Because $id
      }
      @($script:ToolActionCatalog['standard'].Steps) | Should -Be @('timeSync', 'volumeScan', 'dism', 'sfc', 'winreFix')
      @($script:ToolActionCatalog['postClone'].Steps) | Should -Be @('timeSync', 'volumeScan', 'dism', 'sfc', 'winreFix', 'pnpScan', 'devices', 'oemLeftovers',
                                                                     'pageFile', 'trim', 'activation', 'componentCleanup', 'wuScan')
      @($script:ToolActionCatalog['dismSource'].Steps) | Should -Be @('dismSource', 'sfc')
    }
    It 'every step has its function; dism, sfc, componentCleanup and dismSource are the servicing steps (spec 5)' {
      $all = @($script:ToolActionCatalog['postClone'].Steps) + @($script:ToolActionCatalog['dismSource'].Steps)
      foreach ($id in $all) {
        $s = $script:ToolSteps[$id]
        $s | Should -Not -BeNullOrEmpty -Because $id
        $s.Function | Should -BeExactly ('Invoke-ToolStep' + $id.Substring(0, 1).ToUpperInvariant() + $id.Substring(1)) -Because $id
        (Get-Command -Name $s.Function -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because $id
        $s.Servicing | Should -Be ($id -cin 'dism', 'sfc', 'componentCleanup', 'dismSource') -Because $id
      }
    }
    It 'every step timeout the repairs name is in config.json''s toolStep' {
      $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:repairsFile).Path, [ref]$null, [ref]$null)
      $names = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'StepTimeout' }, $true) | ForEach-Object {
          $i = $_.Parent.CommandElements.IndexOf($_); [string]$_.Parent.CommandElements[$i + 1].Value })
      $names.Count | Should -BeGreaterThan 5
      foreach ($n in $names) { @($script:cfg.timeoutsMinutes.toolStep.PSObject.Properties.Name) | Should -Contain $n -Because "toolStep.$n" }
    }
    It 'the source failure codes and the pending code are DISM''s HRESULTs, compared by their 32 bits' {
      @($script:DismSourceFailureCodes | ForEach-Object { Format-ToolExitCode -ExitCode $_ }) | Should -Be @('0x800F081F', '0x800F0906', '0x800F0950')
      Format-ToolExitCode -ExitCode $script:DismPendingCode | Should -Be '0x800F082F'
    }
  }

  Describe 'the Task 6 findings (repair plan, Findings; RD-R13)' {
    It 'holds every Task 6 finding, exactly in English, and in Hebrew with the same arguments' {
      $expected = @{
        'finding.clockOff'               = 'The clock is still {0} min off after the time sync: downloads may fail'
        'finding.clockUnknown'           = 'The clock offset could not be measured (no internet)'
        'finding.timeServiceDisabled'    = 'The Windows Time service is disabled: the clock was not synced'
        'finding.timeSyncFailed'         = 'Time sync failed ({0})'
        'finding.dismRestart'            = 'DISM finished; a restart is needed'
        'finding.dismSourceMissing'      = 'DISM could not get repair files from Windows Update ({0})'
        'finding.dismNoSource'           = 'No install.wim or install.esd on the stick or a mounted ISO'
        'finding.dismFailed'             = 'DISM RestoreHealth failed ({0})'
        'finding.sfcRepaired'            = 'SFC repaired files ({0} components); a second pass {1}'
        'finding.dismAndSfcFailed'       = 'DISM failed and SFC could not repair: supply a matching install.wim, or plan an in-place upgrade'
        'finding.winreEnabled'           = 'WinRE was turned on'
        'finding.winreEnableFailed'      = 'reagentc /enable failed ({0}): Winre.wim may be missing'
        'finding.winreNoAgreement'       = 'WinRE is off but ReAgent.xml does not confirm it: not turned on'
        'finding.pnpScanFailed'          = 'The device rescan failed ({0})'
        'finding.oemLeftover'            = 'Software from another manufacturer: {0}'
        'finding.oemSkipped'             = 'Manufacturer unknown or a whitebox: the leftover check was skipped'
        'finding.pageFileMissingDrive'   = 'The page file is set on a missing drive ({0})'
        'finding.trimOff'                = 'TRIM is off (DisableDeleteNotification = {0})'
        'finding.retrimFailed'           = 'ReTrim failed ({0})'
        'finding.componentCleanupFailed' = 'Component cleanup failed ({0})'
        'finding.updatesAvailable'       = '{0} updates are available'
        'finding.wuScanFailed'           = 'The Windows Update scan failed ({0})'
        'finding.wuScanSkipped'          = 'No internet: the Windows Update scan was skipped'
        # RD-R13: Repair-Volume -Scan asked to be run again.
        'finding.volumeScanRetry'        = 'Disk scan could not finish this time: run the scan again'
        # Ruling RD-R20 (the Task 6 review): M2, M5, M6 and the dead-clock Internet chip (M3).
        'finding.dismNoMatchingImage'    = 'An install.wim or install.esd was found, but none of its images matches this PC ({0}, {1})'
        'finding.trimMediaUnknown'       = 'The system disk''s type is not known ({0}): it was not optimized'
        'finding.analyzeFailed'          = 'Optimize-Volume -Analyze failed ({0})'
        'finding.pageFileUnknown'        = 'The page file settings could not be read ({0})'
        'chip.internet.clock'            = 'Clock wrong: HTTPS fails'
        'tip.internet.clock'             = 'The clock is so far off that secure connections fail. Standard repair syncs it first; if the sync fails, set the date and time by hand (a dead BIOS battery?).'
      }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        $script:ToolboxStrings.he[$k] | Should -Not -Match "'" -Because $k
        ([regex]::Matches($script:ToolboxStrings.he[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',' |
          Should -Be (([regex]::Matches($expected[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',') -Because $k
      }
    }
    It 'holds the final wave''s findings (item 14), exactly in English, and in Hebrew with the same arguments' {
      $expected = @{
        'finding.dismSourceUnreadable' = 'An install.wim or install.esd was found, but it could not be read: see the log'
        'finding.wuScanClockSkipped'   = 'The clock is wrong and the time sync failed: the Windows Update scan was skipped (it would fail)'
      }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        $script:ToolboxStrings.he[$k] | Should -Not -Match "'" -Because $k
        $script:ToolboxStrings.he[$k] | Should -Not -Match '\{\d\}' -Because $k
      }
    }
    It 'every finding code the checks and the repairs add has its text in English and Hebrew' {
      $codes = foreach ($file in 'ToolRepairs.ps1', 'ToolChecks.ps1') {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path "$PSScriptRoot\..\src\Repair\$file").Path, [ref]$null, [ref]$null)
        foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-ToolFinding' }, $true)) {
          $i = 0
          foreach ($e in $c.CommandElements) { if ($e -is [Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Code') { break }; $i++ }
          $c.CommandElements[$i + 1].Value
        }
      }
      @($codes).Count | Should -BeGreaterThan 30
      foreach ($code in $codes) {
        $script:ToolboxStrings.en.Keys | Should -Contain "finding.$code"
        $script:ToolboxStrings.he.Keys | Should -Contain "finding.$code"
      }
    }
  }

  Describe 'Standard repair (spec 6.2)' {
    BeforeEach { $script:installSource = Get-TestOffer; Mock Find-ToolInstallSource { $script:installSource } }

    It 'keeps the kit''s order: time, disk scan, DISM, SFC, WinRE' {
      $r = New-ActionRun standard
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:native | Should -Be @('sc.exe', 'w32tm.exe', 'dism.exe', 'sfc.exe')
      $script:nativeLines | Should -Be @('sc.exe start w32time', 'w32tm.exe /resync', 'dism.exe /Online /Cleanup-Image /RestoreHealth', 'sfc.exe /scannow')
      @($r.Steps.Status) | Should -Be @('done', 'done', 'done', 'done', 'done')
      $script:gcCommands['volumeScan'] | Should -Match 'Repair-Volume -DriveLetter .* -Scan'
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN'
      $r.Data.DismOk | Should -BeTrue
    }
    It 'DISM and SFC write their output for the progress tick; DISM runs under its own timeout' {
      $null = Invoke-ToolSteps -Run (New-ActionRun standard)
      Should -Invoke Invoke-ToolNative -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\System32\dism.exe' -and $StepTimeout -eq 'dism' -and $OutputName -eq 'dism' }
      Should -Invoke Invoke-ToolNative -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\System32\sfc.exe' -and $ArgumentList -eq '/scannow' -and $StepTimeout -eq 'sfc' -and $OutputName -eq 'sfc' }
    }
    It 'DISM exit <C> -> <F>' -ForEach @(
      @{ C = 0; F = ''; Restart = $false; S = 'done' }
      @{ C = 3010; F = 'dismRestart'; Restart = $true; S = 'done' }
      @{ C = -2146498529; F = 'dismSourceMissing'; Restart = $false; S = 'warn' }
      @{ C = 5; F = 'dismFailed'; Restart = $false; S = 'failed' }
      @{ C = $null; F = 'stepTimedOut'; Restart = $false; S = 'timedout' }) {
      $script:exit['dism.exe'] = $C; $r = New-ActionRun standard
      Invoke-ToolStepDism -Run $r | Should -Be $S
      (@($r.Findings | Where-Object { $_.Code -like 'dism*' -or $_.Code -eq 'stepTimedOut' } | ForEach-Object { $_.Code }) -join ',') | Should -Be $F
      $r.RestartRequired | Should -Be $Restart
      $r.Data.DismOk | Should -Be ($C -eq 0 -or $C -eq 3010)
    }
    It 'a failed DISM names its exit code; a timeout names the step and its minutes' {
      $script:exit['dism.exe'] = 5; $r = New-ActionRun standard; $null = Invoke-ToolStepDism -Run $r
      Get-FindingArgs $r 'dismFailed' | Should -Be @('0x00000005')
      $r.Findings[0].Text | Should -BeExactly 'DISM RestoreHealth failed (0x00000005)'
      $script:exit['dism.exe'] = $null; $r = New-ActionRun standard; $null = Invoke-ToolStepDism -Run $r
      $a = @(Get-FindingArgs $r 'stepTimedOut'); $a[0] | Should -Be 'Windows image (DISM)'; [double]$a[1] | Should -Be 150
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
    }
    It 'DISM 0x800F082F (a servicing restart pending) is "restart first"' {
      $script:exit['dism.exe'] = -2146498513; $r = New-ActionRun standard
      Invoke-ToolStepDism -Run $r | Should -Be 'warn'
      Get-FindingCodes $r | Should -Be @('restartFirst')
      $r.Data.DismOk | Should -BeFalse
    }
    It 'DISM saying a servicing restart is pending stops the action before SFC, even when the registry does not say so (review M1)' {
      $script:exit['dism.exe'] = -2146498513; $r = New-ActionRun standard
      Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'
      $script:native | Should -Not -Contain 'sfc.exe'
      @($r.Steps.Status) | Should -Be @('done', 'done', 'warn', 'skipped', 'skipped')
      Get-FindingCount $r 'restartFirst' | Should -Be 1
      Get-ToolResultColor -Outcome 'NeedsRestart' -Findings $r.Findings | Should -Be 'YELLOW'
    }
    It 'DISM''s pending code and the registry signals together still give one restartFirst (review M1)' {
      $script:exit['dism.exe'] = -2146498513; $script:pendingAfter = 'dism'; $r = New-ActionRun standard
      Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'
      Get-FindingCodes $r | Should -Be @('restartFirst')
    }
    It 'every source failure code (<Hex>) offers the found install.wim with its details and never retries by itself' -ForEach @(
      @{ Hex = '0x800F081F'; C = -2146498529 }, @{ Hex = '0x800F0906'; C = -2146498298 }, @{ Hex = '0x800F0950'; C = -2146498224 }) {
      $script:exit['dism.exe'] = $C; $r = New-ActionRun standard
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Get-FindingArgs $r 'dismSourceMissing' | Should -Be @($Hex)
      $r.Offers.DismSource.Path | Should -Be 'E:\sources\install.wim'
      $r.Offers.DismSource.Index | Should -Be 6
      @($script:native | Where-Object { $_ -eq 'dism.exe' }).Count | Should -Be 1
      @($script:nativeLines | Where-Object { $_ -like '*/Source*' -or $_ -like '*/LimitAccess*' }).Count | Should -Be 0
      $script:native | Should -Contain 'sfc.exe'   # DISM failing does not stop SFC (the kit's order)
      Should -Invoke Find-ToolInstallSource -Times 1 -Exactly
    }
    It 'no install.wim or install.esd found: dismNoSource and no offer' {
      $script:installSource = $null; $script:exit['dism.exe'] = -2146498529; $r = New-ActionRun standard
      $null = Invoke-ToolStepDism -Run $r
      Get-FindingRows $r | Should -Be @('WARN|dismSourceMissing', 'INFO|dismNoSource')
      $r.Offers.DismSource | Should -BeNullOrEmpty
    }
    It 'the offer survives result.json in the shape the window reads (Task 5: Path, Type, Index and the details)' {
      $script:exit['dism.exe'] = -2146498529; $r = New-ActionRun standard
      $null = Invoke-ToolSteps -Run $r; Write-ToolResult -Run $r -Outcome 'Done' | Should -BeTrue
      $o = (Read-ToolJsonFile -Path $r.ResultPath).Offers.DismSource
      foreach ($k in 'Path', 'Type', 'Index', 'Edition', 'Arch', 'Languages', 'Build', 'BuildDiffers', 'LanguageDiffers', 'PcLanguage') { $o.Keys | Should -Contain $k }
      $o.Index | Should -BeOfType [int]; $o.Type | Should -Be 'wim'
    }
    It 'DISM leaving a servicing restart pending stops before SFC with "restart first" (yellow)' {
      $script:pendingAfter = 'dism'; $r = New-ActionRun standard
      Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'
      $script:native | Should -Not -Contain 'sfc.exe'
      @($r.Steps.Status) | Should -Be @('done', 'done', 'done', 'skipped', 'skipped')
      Get-FindingCodes $r | Should -Be @('restartFirst')
      Get-ToolResultColor -Outcome 'NeedsRestart' -Findings $r.Findings | Should -Be 'YELLOW'
    }
    It 'SFC runs a second pass only when the first one repaired something (review I-3)' {
      $script:sfc = @(@{ Ran = $true; Repaired = 0; CannotRepair = 0 })
      $r = New-ActionRun standard; Invoke-ToolStepSfc -Run $r | Should -Be 'done'
      @($script:native -eq 'sfc.exe').Count | Should -Be 1; Get-FindingCodes $r | Should -BeNullOrEmpty
      $script:native.Clear(); $script:sfcCalls = 0
      $script:sfc = @(@{ Ran = $true; Repaired = 2 }, @{ Ran = $true; Repaired = 0 })
      $r = New-ActionRun standard; Invoke-ToolStepSfc -Run $r | Should -Be 'done'
      @($script:native -eq 'sfc.exe').Count | Should -Be 2
      Get-FindingRows $r | Should -Be @('INFO|sfcRepaired'); Get-FindingArgs $r 'sfcRepaired' | Should -Be @('2', 'ran clean')
      $r.Findings[0].Text | Should -BeExactly 'SFC repaired files (2 components); a second pass ran clean'
    }
    It 'a second pass that still repairs says so, and there is never a third' {
      $script:sfc = @(@{ Repaired = 4 }, @{ Repaired = 1 }, @{ Repaired = 1 })
      $r = New-ActionRun standard; $null = Invoke-ToolStepSfc -Run $r
      @($script:native -eq 'sfc.exe').Count | Should -Be 2
      Get-FindingArgs $r 'sfcRepaired' | Should -Be @('4', 'still repaired files')
    }
    It 'files SFC cannot repair are red, and with a failed DISM the in-place upgrade advice (<Why>)' -ForEach @(
      @{ Why = 'DISM failed'; DismOk = $false; Rows = @('CRIT|sfcCannotRepair', 'CRIT|dismAndSfcFailed') }
      @{ Why = 'DISM worked'; DismOk = $true; Rows = @('CRIT|sfcCannotRepair') }
      @{ Why = 'no DISM in this run'; DismOk = $null; Rows = @('CRIT|sfcCannotRepair') }) {
      $script:sfc = @(@{ CannotRepair = 3; Corrupt = 3 })
      $r = New-ActionRun standard; if ($null -ne $DismOk) { $r.Data['DismOk'] = $DismOk }
      Invoke-ToolStepSfc -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be $Rows; Get-FindingArgs $r 'sfcCannotRepair' | Should -Be @('3')
      @($script:native -eq 'sfc.exe').Count | Should -Be 1
    }
    It 'SFC that timed out is sfcTimedOut (yellow); SFC that left no result is sfcNotRun' {
      $script:exit['sfc.exe'] = $null; $r = New-ActionRun standard
      Invoke-ToolStepSfc -Run $r | Should -Be 'timedout'
      Get-FindingRows $r | Should -Be @('WARN|sfcTimedOut'); Should -Invoke Read-ToolSfcResult -Times 0
      $script:exit.Remove('sfc.exe'); $script:sfc = @(@{ Ran = $false; VerifyComplete = $false; Settled = $false })
      $r = New-ActionRun standard; Invoke-ToolStepSfc -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|sfcNotRun')
    }
    It 'the second SFC pass never reads the first pass''s CBS.log lines (review I1): the real parser, <Why>' -ForEach @(
      @{ Why = 'a second pass that ran clean'; Second = $true; Outcome = 'ran clean' }
      @{ Why = 'a second sfc.exe that wrote nothing'; Second = $false; Outcome = 'gave no result' }) {
      # The real Read-ToolSfcResult and ConvertFrom-CbsSrText read a synthetic CBS.log in $TestDrive; a fake clock moves
      # only when a wait or a scan takes time. The first pass ends with its repair lines, as SFC writes them.
      $script:realCbs = $true; $script:sfcPass = 0; $script:secondWrites = $Second
      $script:cbsLog = Join-Path $TestDrive 'CBS.log'; [IO.File]::WriteAllText($script:cbsLog, '')
      $script:fakeNow = [datetime]'2026-10-22 10:00:00'
      Mock Get-Date { $script:fakeNow }
      Mock Wait-SetupDelay { $script:fakeNow = $script:fakeNow.AddSeconds($Seconds) }
      Mock Read-ToolCbsLog { [IO.File]::ReadAllText($script:cbsLog) }
      $script:onNative = {
        param($file, $arguments)
        if ($file -ne 'sfc.exe') { return }
        $script:sfcPass++
        if ($script:sfcPass -eq 2 -and -not $script:secondWrites) { return }
        $start = $script:fakeNow; $script:fakeNow = $script:fakeNow.AddSeconds(90)
        Add-CbsLine $start '[SR] Verifying 100 components'
        Add-CbsLine $script:fakeNow.AddSeconds(-1) '[SR] Verify complete'
        if ($script:sfcPass -eq 1) { Add-CbsLine $script:fakeNow '[SR] Repairing 2 components'; Add-CbsLine $script:fakeNow '[SR] Repair complete' }
      }
      $r = New-ActionRun standard; $null = Invoke-ToolStepSfc -Run $r
      $script:sfcPass | Should -Be 2
      Get-FindingArgs $r 'sfcRepaired' | Should -Be @('2', $Outcome)
      $script:ToolCbsLookbackSeconds | Should -BeGreaterThan 0
      Should -Invoke Wait-SetupDelay -Times 1 -ParameterFilter { $Seconds -gt $script:ToolCbsLookbackSeconds }
    }
    It 'reagentc /enable runs only when the BCD and ReAgent.xml both say off: <Bcd> + <Agent> -> <Rows>' -ForEach @(
      @{ Bcd = @('Off', 'On'); Agent = 'Off'; Rows = @('INFO|winreEnabled'); Reagentc = $true; Status = 'done' }
      @{ Bcd = @('Off'); Agent = 'Missing'; Rows = @('WARN|winreNoAgreement'); Reagentc = $false; Status = 'warn' }
      @{ Bcd = @('Off'); Agent = 'Unknown'; Rows = @('WARN|winreNoAgreement'); Reagentc = $false; Status = 'warn' }
      @{ Bcd = @('On'); Agent = 'Off'; Rows = @('WARN|winreUnknown'); Reagentc = $false; Status = 'warn' }
      @{ Bcd = @('Off'); Agent = 'On'; Rows = @('WARN|winreUnknown'); Reagentc = $false; Status = 'warn' }
      @{ Bcd = @('Unknown'); Agent = 'Off'; Rows = @('WARN|winreUnreadable'); Reagentc = $false; Status = 'warn' }
      @{ Bcd = @('On'); Agent = 'On'; Rows = @(); Reagentc = $false; Status = 'done' }) {
      $script:bcd = $Bcd; $script:reagent = $Agent; $r = New-ActionRun standard
      Invoke-ToolStepWinreFix -Run $r | Should -Be $Status
      (Get-FindingRows $r) -join ',' | Should -Be ($Rows -join ',')
      ($script:nativeLines -contains 'reagentc.exe /enable') | Should -Be $Reagentc
      @($script:nativeLines | Where-Object { $_ -like 'reagentc*' -and $_ -ne 'reagentc.exe /enable' }).Count | Should -Be 0
    }
    It 'reagentc /enable that fails, or leaves the boot configuration off, is winreEnableFailed' {
      $script:bcd = @('Off'); $script:reagent = 'Off'; $script:exit['reagentc.exe'] = 2
      $r = New-ActionRun standard; Invoke-ToolStepWinreFix -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|winreEnableFailed'); Get-FindingArgs $r 'winreEnableFailed' | Should -Be @('0x00000002')
      $script:exit.Remove('reagentc.exe'); $script:bcd = @('Off', 'Off'); $script:bcdCalls = 0
      $r = New-ActionRun standard; Invoke-ToolStepWinreFix -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|winreEnableFailed'); @(Get-FindingArgs $r 'winreEnableFailed')[0] | Should -Match 'boot configuration'
    }
    It 'a disabled time service is reported, never changed; a clock still 3 min off warns' {
      $script:services['w32time'] = @{ Status = 'Stopped'; StartType = 'Disabled' }
      $r = New-ActionRun standard; Invoke-ToolStepTimeSync -Run $r | Should -Be 'warn'
      Get-FindingCodes $r | Should -Contain 'timeServiceDisabled'; $script:native | Should -BeNullOrEmpty
      Should -Invoke Test-ToolInternet -Times 1 -Exactly   # the clock is still measured
      $script:services['w32time'] = @{ Status = 'Running'; StartType = 'Manual' }; $script:offsetSeconds = 180
      $r = New-ActionRun standard; Invoke-ToolStepTimeSync -Run $r | Should -Be 'warn'
      $r.Findings | Where-Object Code -eq 'clockOff' | ForEach-Object { $_.Args } | Should -Be @('3.0')
      $script:nativeLines | Should -Be @('sc.exe start w32time', 'w32tm.exe /resync')
    }
    It 'a clock behind by 2.5 min warns too; 1.5 min does not; no measurement is clockUnknown (INFO)' {
      $script:offsetSeconds = -150; $r = New-ActionRun standard; $null = Invoke-ToolStepTimeSync -Run $r; Get-FindingArgs $r 'clockOff' | Should -Be @('2.5')
      $script:offsetSeconds = 90; $r = New-ActionRun standard; Invoke-ToolStepTimeSync -Run $r | Should -Be 'done'; Get-FindingCodes $r | Should -BeNullOrEmpty
      $script:offsetSeconds = $null; $r = New-ActionRun standard; Invoke-ToolStepTimeSync -Run $r | Should -Be 'done'; Get-FindingRows $r | Should -Be @('INFO|clockUnknown')
    }
    It 'a dead clock (HTTPS fails, the HTTP probe dates it two years off) is clockOff in minutes, never "no internet" (review M3)' {
      $script:exit['w32tm.exe'] = -2147023436
      Mock Test-ToolInternet { @{ Tcp = $true; Https = $false; Probe = 'ok'; ClockOffsetSeconds = -63072000.0; Chip = @{ Level = 'warn'; Args = @(); Detail = @{ Clock = $true } } } }
      $r = New-ActionRun standard; Invoke-ToolStepTimeSync -Run $r | Should -Be 'warn'
      Get-FindingCodes $r | Should -Be @('timeSyncFailed', 'clockOff'); Get-FindingArgs $r 'clockOff' | Should -Be @('1051200.0')
      Get-FindingCodes $r | Should -Not -Contain 'clockUnknown'
    }
    It 'the time sync fails when <Why>: timeSyncFailed, the clock still measured' -ForEach @(
      @{ Why = 'sc start is refused'; Exit = @{ 'sc.exe' = 5 }; Starts = $true; Service = @{ Status = 'Stopped'; StartType = 'Manual' }; Lines = @('sc.exe start w32time') }
      @{ Why = 'the service never runs'; Exit = @{ 'sc.exe' = 1056 }; Starts = $false; Service = @{ Status = 'StartPending'; StartType = 'Manual' }; Lines = @('sc.exe start w32time') }
      @{ Why = 'w32tm /resync fails'; Exit = @{ 'w32tm.exe' = -2147023436 }; Starts = $true; Service = @{ Status = 'Stopped'; StartType = 'Manual' }; Lines = @('sc.exe start w32time', 'w32tm.exe /resync') }
      @{ Why = 'w32tm /resync times out'; Exit = @{ 'w32tm.exe' = $null }; Starts = $true; Service = @{ Status = 'Running'; StartType = 'Automatic' }; Lines = @('sc.exe start w32time', 'w32tm.exe /resync') }
      @{ Why = 'the service cannot be read'; Exit = @{}; Starts = $true; Service = $null; Lines = @() }) {
      $script:exit = $Exit.Clone(); $script:scStarts = $Starts
      if ($null -eq $Service) { $script:services.Remove('w32time') } else { $script:services['w32time'] = $Service.Clone() }
      $r = New-ActionRun standard; Invoke-ToolStepTimeSync -Run $r | Should -Be 'warn'
      Get-FindingCodes $r | Should -Contain 'timeSyncFailed'
      (@($script:nativeLines) -join ',') | Should -Be ($Lines -join ',')
      Should -Invoke Test-ToolInternet -Times 1 -Exactly
    }
    It 'the wait for the time service is bounded by toolStep.service, in 2 s slices' {
      $script:services['w32time'] = @{ Status = 'StartPending'; StartType = 'Manual' }; $script:scStarts = $false
      $null = Invoke-ToolStepTimeSync -Run (New-ActionRun standard)
      Should -Invoke Wait-SetupDelay -Times 60 -Exactly -ParameterFilter { $Seconds -eq 2 }   # toolStep.service = 2 min
    }
    It 'a disk scan that asks to be run again is yellow; errors fixed online that still need a spot fix are red with the Disk-check offer (RD-R13)' {
      $script:gc['volumeScan'] = @{ Result = 'ScanNeedsRetry' }
      $r = New-ActionRun standard; Invoke-ToolStepVolumeScan -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|volumeScanRetry'); $r.Offers.DiskCheck | Should -BeFalse
      $script:gc['volumeScan'] = @{ Result = 'ScanErrorsFixedOnlineAlsoNeedSpotFix' }
      $r = New-ActionRun standard; Invoke-ToolStepVolumeScan -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('CRIT|volumeSpotFix'); $r.Offers.DiskCheck | Should -BeTrue
    }
  }

  Describe 'the installed programs (review I-12)' {
    It 'installed programs come from both machine views and the signed-in user''s own view, never the elevated HKCU (review I-12)' {
      Mock Get-SignedInUserName { 'PC1\dana' }
      Mock Get-ToolUserSid { 'S-1-5-21-1111111111-2222222222-3333333333-1001' }
      $script:paths = New-Object System.Collections.ArrayList
      Mock Get-ItemProperty -ParameterFilter { $Path -like '*Uninstall\`*' } {
        [void]$script:paths.Add([string]$Path)
        if ($Path -like 'Registry::HKEY_USERS\*') { [pscustomobject]@{ DisplayName = 'HP Smart' } }
        else { [pscustomobject]@{ DisplayName = 'Dell SupportAssist' }; [pscustomobject]@{ DisplayName = ' ' }; [pscustomobject]@{ NoName = 1 } }
      }
      @(Get-ToolInstalledPrograms) | Should -Be @('Dell SupportAssist', 'HP Smart')
      @($script:paths) | Should -Be @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                      'Registry::HKEY_USERS\S-1-5-21-1111111111-2222222222-3333333333-1001\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
      Should -Invoke Get-ToolUserSid -Times 1 -Exactly -ParameterFilter { $UserName -eq 'PC1\dana' }
    }
    It 'no signed-in user, or a name that does not translate: the machine views only' {
      $script:paths = New-Object System.Collections.ArrayList
      Mock Get-ItemProperty -ParameterFilter { $Path -like '*Uninstall\`*' } { [void]$script:paths.Add([string]$Path) }
      Mock Get-SignedInUserName { '' }
      $null = Get-ToolInstalledPrograms
      Mock Get-SignedInUserName { 'PC1\gone' }; Mock Get-ToolUserSid { '' }
      $null = Get-ToolInstalledPrograms
      @($script:paths | Where-Object { $_ -notlike 'HKLM:\*' }) | Should -BeNullOrEmpty
      @($script:paths).Count | Should -Be 4
    }
  }

  Describe 'Post-clone (spec 6.3)' {
    BeforeEach { Mock Find-ToolInstallSource { $null }; Mock Get-ToolInstalledPrograms { $script:programs } }

    It 'runs Standard''s steps, then the post-clone steps, with pnputil /scan-devices here' {
      $r = New-ActionRun postClone
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      @($r.Steps.Id) | Should -Be @('timeSync', 'volumeScan', 'dism', 'sfc', 'winreFix', 'pnpScan', 'devices', 'oemLeftovers', 'pageFile', 'trim', 'activation', 'componentCleanup', 'wuScan')
      $script:nativeLines | Should -Contain 'pnputil.exe /scan-devices'
      $script:native | Should -Be @('sc.exe', 'w32tm.exe', 'dism.exe', 'sfc.exe', 'pnputil.exe')
      @($script:gcCommands.Keys | Sort-Object) | Should -Be @('activation', 'componentCleanup', 'devices', 'media', 'retrim', 'volumeScan', 'wuScan')
      @($r.Steps.Status | Where-Object { $_ -ne 'done' }) | Should -BeNullOrEmpty
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN'
    }
    It 'a pending servicing restart before the component cleanup stops there' {
      $script:pendingAfter = 'activation'; $r = New-ActionRun postClone
      Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'
      Get-StepStatus $r 'componentCleanup' | Should -Be 'skipped'; Get-StepStatus $r 'wuScan' | Should -Be 'skipped'
      $script:gcCommands.Keys | Should -Not -Contain 'componentCleanup'
    }
    It 'DISM''s own pending code stops Post-clone before any later servicing step: no component cleanup, NeedsRestart, one restartFirst (review M1)' {
      $script:exit['dism.exe'] = -2146498513; $r = New-ActionRun postClone
      Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'
      $script:gcCommands.Keys | Should -Not -Contain 'componentCleanup'; $script:native | Should -Not -Contain 'sfc.exe'
      Get-StepStatus $r 'componentCleanup' | Should -Be 'skipped'
      Get-FindingCount $r 'restartFirst' | Should -Be 1
    }
    It 'the device rescan: exit <C> is <S>' -ForEach @(
      @{ C = 0; S = 'done'; Rows = @(); Restart = $false }, @{ C = 3010; S = 'done'; Rows = @(); Restart = $true }
      @{ C = 1; S = 'warn'; Rows = @('WARN|pnpScanFailed'); Restart = $false }, @{ C = $null; S = 'timedout'; Rows = @('WARN|pnpScanFailed'); Restart = $false }) {
      $script:exit['pnputil.exe'] = $C; $r = New-ActionRun postClone
      Invoke-ToolStepPnpScan -Run $r | Should -Be $S
      (Get-FindingRows $r) -join ',' | Should -Be ($Rows -join ','); $r.RestartRequired | Should -Be $Restart
    }
    It 'flags another brand''s system utility, never printer software, and skips a whitebox' {
      Get-ToolOemLeftovers -Programs @('HP Smart', 'HP Support Assistant', 'Dell Display Manager') -Brand 'DELL' -Config $script:cfg | Should -Be @('HP Support Assistant')
      Get-ToolOemLeftovers -Programs @('Dell SupportAssist') -Brand 'OTHER' -Config $script:cfg | Should -BeNullOrEmpty
      Get-ToolOemLeftovers -Programs @('Dell SupportAssist') -Brand 'VM' -Config $script:cfg | Should -BeNullOrEmpty
      Get-ToolOemLeftovers -Programs @('Dell SupportAssist') -Brand 'SAMSUNG' -Config $script:cfg | Should -BeNullOrEmpty
      Get-ToolOemLeftovers -Programs @('Dell SupportAssist', 'Lenovo Vantage Service') -Brand 'LENOVO' -Config $script:cfg | Should -Be @('Dell SupportAssist')
      Get-ToolOemLeftovers -Programs @('MyASUS', 'myasus', 'Dragon Center') -Brand 'SURFACE' -Config $script:cfg | Should -Be @('MyASUS', 'Dragon Center')
    }
    It 'the leftover step: <Why>' -ForEach @(
      @{ Why = 'a Dell with an HP and a Lenovo utility'; Maker = 'Dell Inc.'; Programs = @('HP Support Assistant', 'Lenovo Vantage', 'Dell SupportAssist', '7-Zip')
         Rows = @('WARN|oemLeftover'); Named = @('HP Support Assistant, Lenovo Vantage'); Status = 'warn' }
      @{ Why = 'seven leftovers name five and the rest as a count'; Maker = 'Dell Inc.'
         Programs = @('HP Sure Click', 'HP Wolf Security', 'HP Notifications', 'MyASUS', 'MSI Center', 'Acer Care Center', 'Lenovo Now')
         Rows = @('WARN|oemLeftover'); Named = @('HP Sure Click, HP Wolf Security, HP Notifications, MyASUS, MSI Center and 2 more'); Status = 'warn' }
      @{ Why = 'a Dell with only its own tools'; Maker = 'Dell Inc.'; Programs = @('Dell SupportAssist'); Rows = @(); Named = @(); Status = 'done' }
      @{ Why = 'a whitebox is skipped'; Maker = 'To Be Filled By O.E.M.'; Programs = @('HP Support Assistant'); Rows = @('INFO|oemSkipped'); Named = @(); Status = 'done' }) {
      $script:programs = $Programs; $r = New-ActionRun postClone; $r.Args.Identity.Manufacturer = $Maker
      Invoke-ToolStepOemLeftovers -Run $r | Should -Be $Status
      (Get-FindingRows $r) -join ',' | Should -Be ($Rows -join ',')
      (Get-FindingArgs $r 'oemLeftover') -join '|' | Should -Be ($Named -join '|')
      if ($Maker -like 'To Be*') { Should -Invoke Get-ToolInstalledPrograms -Times 0 }
    }
    It 'a page file on a missing drive is reported; a page file on any drive (?:) or on C: is not' {
      $script:pageFiles = @('C:\pagefile.sys', 'D:\pagefile.sys', '?:\pagefile.sys'); $script:existing = @('C:\')
      $r = New-ActionRun postClone; Invoke-ToolStepPageFile -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|pageFileMissingDrive'); Get-FindingArgs $r 'pageFileMissingDrive' | Should -Be @('D:')
      $script:pageFiles = @('C:\pagefile.sys'); $r = New-ActionRun postClone; Invoke-ToolStepPageFile -Run $r | Should -Be 'done'; Get-FindingCodes $r | Should -BeNullOrEmpty
    }
    It 'page-file settings that cannot be read are a WARN finding, never a yellow step with nothing (review M6)' {
      Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_PageFileSetting' } { Write-Error -Message 'Invalid class' -ErrorId 'HRESULT 0x80041010' -Category InvalidType }
      $r = New-ActionRun postClone; Invoke-ToolStepPageFile -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|pageFileUnknown'); @(Get-FindingArgs $r 'pageFileUnknown')[0] | Should -Match 'Invalid class'
    }
    It 'TRIM off is reported, the registry is never written; ReTrim on SSD, Analyze on HDD' {
      $script:reg['DisableDeleteNotification'] = 1; $script:gc['media'] = @{ Media = 'SSD' }
      $r = New-ActionRun postClone; Invoke-ToolStepTrim -Run $r | Should -Be 'warn'
      Get-FindingCodes $r | Should -Contain 'trimOff'; Get-FindingArgs $r 'trimOff' | Should -Be @('1')
      Should -Invoke Set-ItemProperty -Times 0; Should -Invoke New-ItemProperty -Times 0
      $script:gcCommands['retrim'] | Should -Match '-ReTrim'
      $script:gc['media'] = @{ Media = 'HDD' }; $script:reg['DisableDeleteNotification'] = 0
      $r = New-ActionRun postClone; Invoke-ToolStepTrim -Run $r | Should -Be 'done'; Get-FindingCodes $r | Should -BeNullOrEmpty
      $script:gcCommands['retrim'] | Should -Match '-Analyze'; $script:gcCommands['retrim'] | Should -Not -Match 'ReTrim'
    }
    It 'TRIM: a missing value is on; an unknown media type optimizes nothing and says so (review M5); a failed ReTrim is retrimFailed' {
      $script:reg.Remove('DisableDeleteNotification'); $script:gc['media'] = @{ Media = @('Unspecified') }
      $r = New-ActionRun postClone; Invoke-ToolStepTrim -Run $r | Should -Be 'done'
      Get-FindingRows $r | Should -Be @('INFO|trimMediaUnknown'); Get-FindingArgs $r 'trimMediaUnknown' | Should -Be @('Unspecified')
      $script:gcCommands.Keys | Should -Not -Contain 'retrim'
      $script:gcFail['media'] = 'timed out'; $r = New-ActionRun postClone; $null = Invoke-ToolStepTrim -Run $r
      Get-FindingRows $r | Should -Be @('INFO|trimMediaUnknown'); Get-FindingArgs $r 'trimMediaUnknown' | Should -Be @('timed out')
      $script:gcFail.Clear(); $script:gc['media'] = @{ Media = @('SSD') }; $script:gcFail['retrim'] = 'The volume does not support it'
      $r = New-ActionRun postClone; Invoke-ToolStepTrim -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|retrimFailed'); Get-FindingArgs $r 'retrimFailed' | Should -Be @('The volume does not support it')
      $script:gcFail['retrim'] = 'timed out'; $r = New-ActionRun postClone; Invoke-ToolStepTrim -Run $r | Should -Be 'timedout'
    }
    It 'an -Analyze that fails on an HDD is analyzeFailed, never "ReTrim failed" (review M5)' {
      $script:gc['media'] = @{ Media = @('HDD') }; $script:gcFail['retrim'] = 'Access denied'
      $r = New-ActionRun postClone; Invoke-ToolStepTrim -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|analyzeFailed'); Get-FindingArgs $r 'analyzeFailed' | Should -Be @('Access denied')
    }
    It 'component cleanup never resets the base' {
      $r = New-ActionRun postClone; Invoke-ToolStepComponentCleanup -Run $r | Should -Be 'done'
      $script:gcCommands['componentCleanup'] | Should -Match 'Repair-WindowsImage -Online -StartComponentCleanup'
      $script:gcCommands['componentCleanup'] | Should -Not -Match 'ResetBase'
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'componentCleanup' -and $StepTimeout -eq 'componentCleanup' }
    }
    It 'component cleanup that fails is componentCleanupFailed (yellow); one that needs a restart says so' {
      $script:gcFail['componentCleanup'] = 'The operation failed'
      $r = New-ActionRun postClone; Invoke-ToolStepComponentCleanup -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|componentCleanupFailed')
      $script:gcFail.Clear(); $script:gc['componentCleanup'] = @{ Done = $true; RestartNeeded = $true }
      $r = New-ActionRun postClone; $null = Invoke-ToolStepComponentCleanup -Run $r; $r.RestartRequired | Should -BeTrue
    }
    It 'no internet skips the update scan' {
      $r = New-ActionRun postClone; $r.Args.Strip.Internet = 'crit'
      Invoke-ToolStepWuScan -Run $r | Should -Be 'skipped'
      Get-FindingCodes $r | Should -Be @('wuScanSkipped'); Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'wuScan' }
    }
    It 'a clock too far off for HTTPS that the time sync could not fix skips the update scan (it would fail); synced, or only minutes off, still scans (final wave item 14)' {
      $r = New-ActionRun postClone; $r.Data['TimeSync'] = @{ Synced = $false; ClockOffsetSeconds = -63072000.0; StartType = 'Manual' }
      Invoke-ToolStepWuScan -Run $r | Should -Be 'skipped'
      Get-FindingCodes $r | Should -Be @('wuScanClockSkipped'); Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'wuScan' }
      foreach ($sync in @{ Synced = $true; ClockOffsetSeconds = -63072000.0 }, @{ Synced = $false; ClockOffsetSeconds = 300.0 }, @{ Synced = $false; ClockOffsetSeconds = $null }) {
        $script:gc['wuScan'] = @{ ResultCode = 2; Count = 0 }
        $r = New-ActionRun postClone; $r.Data['TimeSync'] = $sync; Invoke-ToolStepWuScan -Run $r | Should -Be 'done'
        Get-FindingCodes $r | Should -Not -Contain 'wuScanClockSkipped'
      }
      Should -Invoke Invoke-ToolJsonChild -Times 3 -Exactly -ParameterFilter { $Name -eq 'wuScan' }
      # No internet still wins (its own finding), and Windows Update reset (no time sync step) scans as before.
      $r = New-ActionRun postClone; $r.Args.Strip.Internet = 'crit'; $r.Data['TimeSync'] = @{ Synced = $false; ClockOffsetSeconds = -63072000.0 }
      $null = Invoke-ToolStepWuScan -Run $r; Get-FindingCodes $r | Should -Be @('wuScanSkipped')
    }
    It 'the update scan is a Windows Update search: <Why>' -ForEach @(
      @{ Why = '3 updates'; Answer = @{ ResultCode = 2; Count = 3 }; Fail = $null; Rows = @('INFO|updatesAvailable'); Status = 'done' }
      @{ Why = 'none'; Answer = @{ ResultCode = 2; Count = 0 }; Fail = $null; Rows = @(); Status = 'done' }
      @{ Why = 'a failed search'; Answer = @{ ResultCode = 4; Count = 0 }; Fail = $null; Rows = @('WARN|wuScanFailed'); Status = 'warn' }
      @{ Why = 'a grandchild error'; Answer = $null; Fail = 'Exception from HRESULT: 0x8024402C'; Rows = @('WARN|wuScanFailed'); Status = 'warn' }
      @{ Why = 'a timeout'; Answer = $null; Fail = 'timed out'; Rows = @('WARN|wuScanFailed'); Status = 'timedout' }) {
      if ($Fail) { $script:gcFail['wuScan'] = $Fail } else { $script:gc['wuScan'] = $Answer }
      $r = New-ActionRun postClone; Invoke-ToolStepWuScan -Run $r | Should -Be $Status
      (Get-FindingRows $r) -join ',' | Should -Be ($Rows -join ',')
      $script:gcCommands['wuScan'] | Should -Match 'Microsoft\.Update\.Session'
      $script:gcCommands['wuScan'] | Should -Match "IsInstalled=0 and IsHidden=0"
      $script:gcCommands['wuScan'] | Should -Not -Match '(?i)UsoClient|Install\(|Download\('
      if ($Why -eq '3 updates') { Get-FindingArgs $r 'updatesAvailable' | Should -Be @('3') }
    }
  }

  Describe 'DISM with a local source' {
    It 'runs /Source:wim:E:\sources\install.wim:6 /LimitAccess, then SFC' {
      $script:existing = @('E:\sources\install.wim')
      $r = New-ActionRun dismSource -Options @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = 6 }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:nativeArgs[0] | Should -Be '/Online /Cleanup-Image /RestoreHealth /Source:wim:E:\sources\install.wim:6 /LimitAccess'
      $script:native | Should -Be @('dism.exe', 'sfc.exe')
      Should -Invoke Invoke-ToolNative -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\System32\dism.exe' -and $StepTimeout -eq 'dism' -and $OutputName -eq 'dism' }
      $r.Data.DismOk | Should -BeTrue; Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN'
    }
    It 'an install.esd is passed as esd' {
      $script:existing = @('F:\sources\install.esd')
      $r = New-ActionRun dismSource -Options @{ Path = 'F:\sources\install.esd'; Type = 'esd'; Index = 2 }
      Invoke-ToolStepDismSource -Run $r | Should -Be 'done'
      $script:nativeArgs[0] | Should -Be '/Online /Cleanup-Image /RestoreHealth /Source:esd:F:\sources\install.esd:2 /LimitAccess'
    }
    It 'refuses options that are not a sources\install file on a drive root: <Why>' -ForEach @(
      @{ Why = 'another folder'; O = @{ Path = 'E:\x\install.wim'; Type = 'wim'; Index = 6 } }
      @{ Why = 'index 0'; O = @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = 0 } }
      @{ Why = 'index 100'; O = @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = 100 } }
      @{ Why = 'an index that is text'; O = @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = '6 /x' } }
      @{ Why = 'a split image'; O = @{ Path = 'E:\sources\install.swm'; Type = 'swm'; Index = 1 } }
      @{ Why = 'a type that is not the file''s'; O = @{ Path = 'E:\sources\install.wim'; Type = 'esd'; Index = 6 } }
      @{ Why = 'a path that climbs'; O = @{ Path = 'E:\sources\..\sources\install.wim'; Type = 'wim'; Index = 6 } }
      @{ Why = 'a network path'; O = @{ Path = '\\server\share\sources\install.wim'; Type = 'wim'; Index = 6 } }
      @{ Why = 'a file that is gone'; O = @{ Path = 'G:\sources\install.wim'; Type = 'wim'; Index = 6 } }
      @{ Why = 'no options'; O = @{} }) {
      $script:existing = @('E:\sources\install.wim', 'E:\sources\install.swm', 'E:\x\install.wim', 'E:\sources\..\sources\install.wim', '\\server\share\sources\install.wim')
      $r = New-ActionRun dismSource -Options $O
      $null = Invoke-ToolSteps -Run $r
      $script:native | Should -Not -Contain 'dism.exe'
      Get-StepStatus $r 'dismSource' | Should -Be 'failed'
      Get-FindingRows $r | Should -Contain 'CRIT|stepFailed'
    }
    It 'refuses an install file that is not on the stick or a mounted ISO: <Why> (spec 6.2, review M9)' -ForEach @(
      @{ Why = 'the system drive'; Path = 'C:\sources\install.wim' }
      @{ Why = 'a mapped network drive'; Path = 'Z:\sources\install.wim' }
      @{ Why = 'a fixed data disk'; Path = 'D:\sources\install.esd' }) {
      $script:existing = @($Path); $script:sourceRoots = @('E:\', 'F:\')
      $r = New-ActionRun dismSource -Options @{ Path = $Path; Type = $Path.Substring($Path.Length - 3); Index = 6 }
      $null = Invoke-ToolSteps -Run $r
      $script:native | Should -Not -Contain 'dism.exe'
      Get-StepStatus $r 'dismSource' | Should -Be 'failed'
      @(Get-FindingArgs $r 'stepFailed')[1] | Should -Match 'stick or a mounted ISO'
      Should -Invoke Get-ToolInstallSourceRoots -ParameterFilter { $StickRoot -eq 'E:\' }
    }
    It 'install files that hold no image for this PC are dismNoMatchingImage, not dismNoSource (review M2)' {
      $script:sourceRoots = @('E:\'); $script:existing = @('E:\sources\install.wim'); $script:exit['dism.exe'] = -2146498529
      $script:gc['installImage'] = @{ Items = @(@{ Index = 1; EditionId = 'Enterprise'; Architecture = '9'; Languages = @('en-US'); Version = '10.0.26200.1' }) }
      $r = New-ActionRun standard; Invoke-ToolStepDism -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|dismSourceMissing', 'INFO|dismNoMatchingImage')
      Get-FindingArgs $r 'dismNoMatchingImage' | Should -Be @('Professional', 'x64'); $r.Offers.DismSource | Should -BeNullOrEmpty
      $script:reg.Remove('EditionID'); $r = New-ActionRun standard; $null = Invoke-ToolStepDism -Run $r
      Get-FindingArgs $r 'dismNoMatchingImage' | Should -Be @('unknown', 'x64')
      $script:existing = @(); $r = New-ActionRun standard; $null = Invoke-ToolStepDism -Run $r
      Get-FindingRows $r | Should -Be @('WARN|dismSourceMissing', 'INFO|dismNoSource')
    }
    It 'install files of which none could be read are dismSourceUnreadable, never "none of its images matches" (final wave item 14)' {
      $script:sourceRoots = @('E:\', 'D:\'); $script:existing = @('E:\sources\install.wim', 'D:\sources\install.esd'); $script:exit['dism.exe'] = -2146498529
      $script:gcFail['installImage'] = 'The file is not a WIM'
      $r = New-ActionRun standard; Invoke-ToolStepDism -Run $r | Should -Be 'warn'
      Get-FindingRows $r | Should -Be @('WARN|dismSourceMissing', 'INFO|dismSourceUnreadable'); $r.Offers.DismSource | Should -BeNullOrEmpty
      $r.Data.DismSourceSearch.Unreadable | Should -Be 2
      # One read without a match and one unreadable: the one read decides (none of its images matches).
      $script:gcFail.Clear(); $script:gc['installImage'] = @{ Items = @(@{ Index = 1; EditionId = 'Enterprise'; Architecture = '9'; Languages = @('en-US'); Version = '10.0.26200.1' }) }
      Mock Invoke-ToolJsonChild { if ($Command -match 'D:\\sources') { @{ Ok = $false; TimedOut = $true; Data = $null; Error = 'timed out' } } else { @{ Ok = $true; TimedOut = $false; Data = $script:gc['installImage']; Error = $null } } } -ParameterFilter { $Name -eq 'installImage' }
      $r = New-ActionRun standard; $null = Invoke-ToolStepDism -Run $r
      Get-FindingRows $r | Should -Be @('WARN|dismSourceMissing', 'INFO|dismNoMatchingImage'); $r.Data.DismSourceSearch.Unreadable | Should -Be 1
    }
    It 'a source the retry cannot use is dismFailed, with no second offer' {
      $script:existing = @('E:\sources\install.wim'); $script:exit['dism.exe'] = -2146498529
      Mock Find-ToolInstallSource { Get-TestOffer }
      $r = New-ActionRun dismSource -Options @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = 6 }
      Invoke-ToolStepDismSource -Run $r | Should -Be 'failed'
      Get-FindingRows $r | Should -Be @('CRIT|dismFailed'); Get-FindingArgs $r 'dismFailed' | Should -Be @('0x800F081F')
      $r.Offers.DismSource | Should -BeNullOrEmpty; Should -Invoke Find-ToolInstallSource -Times 0
    }
    It 'Find-ToolInstallSource matches EditionID and architecture, and flags a build or language that differs' {
      # one install.wim on E: with index 1 Core x64, index 6 Professional x64 en-US build 26100, index 7 Professional ARM64; the PC: Professional x64 he-IL build 26200
      $script:sourceRoots = @('E:\')
      $script:existing = @('E:\sources\install.wim')
      $s = Find-ToolInstallSource -Run (New-ActionRun standard)
      $s.Path | Should -Be 'E:\sources\install.wim'; $s.Type | Should -Be 'wim'
      $s.Index | Should -Be 6; $s.Arch | Should -Be 'x64'; $s.Edition | Should -Be 'Professional'; $s.Build | Should -Be '26100'
      @($s.Languages) | Should -Be @('en-US'); $s.PcLanguage | Should -Be 'he-IL'
      $s.BuildDiffers | Should -BeTrue; $s.LanguageDiffers | Should -BeTrue
      $script:gcCommands['installImage'] | Should -Match ([regex]::Escape("Get-WindowsImage -ImagePath 'E:\sources\install.wim'"))
      # with only index 7 (ARM64): $null
      $script:gc['installImage'] = @{ Items = @(@{ Index = 7; EditionId = 'Professional'; Architecture = '12'; Languages = @('he-IL'); Version = '10.0.26200.1' }) }
      Find-ToolInstallSource -Run (New-ActionRun standard) | Should -BeNullOrEmpty
    }
    It 'the same build and language are not flagged; the stick''s file is looked at before a mounted ISO''s' {
      $script:sourceRoots = @('E:\', 'D:\')
      $script:existing = @('E:\sources\install.esd', 'D:\sources\install.wim')
      $script:gc['installImage'] = @{ Items = @(@{ Index = 3; EditionId = 'Professional'; Architecture = 'x64'; Languages = @('he-IL', 'en-US'); Version = '10.0.26200.6584' }) }
      $s = Find-ToolInstallSource -Run (New-ActionRun standard)
      $s.Path | Should -Be 'E:\sources\install.esd'; $s.Type | Should -Be 'esd'; $s.Index | Should -Be 3
      $s.BuildDiffers | Should -BeFalse; $s.LanguageDiffers | Should -BeFalse
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'installImage' }
    }
    It 'no candidate file, an unreadable image or an unknown edition: no offer' {
      $script:sourceRoots = @('E:\')
      $script:existing = @()
      Find-ToolInstallSource -Run (New-ActionRun standard) | Should -BeNullOrEmpty
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'installImage' }
      $script:existing = @('E:\sources\install.wim'); $script:gcFail['installImage'] = 'The file is not a WIM'
      Find-ToolInstallSource -Run (New-ActionRun standard) | Should -BeNullOrEmpty
      $script:gcFail.Clear(); $script:reg.Remove('EditionID')
      Find-ToolInstallSource -Run (New-ActionRun standard) | Should -BeNullOrEmpty
    }
    It 'Get-ToolInstallSourceRoots: the stick first, then every ready CD-ROM or removable drive, each once' {
      $drives = @(
        [pscustomobject]@{ Name = 'D:\'; DriveType = 'CDRom'; IsReady = $true }
        [pscustomobject]@{ Name = 'F:\'; DriveType = 'Removable'; IsReady = $false }
        [pscustomobject]@{ Name = 'G:\'; DriveType = 'Fixed'; IsReady = $true }
        [pscustomobject]@{ Name = 'H:\'; DriveType = 'Network'; IsReady = $true }
        [pscustomobject]@{ Name = 'e:\'; DriveType = 'Removable'; IsReady = $true }
        [pscustomobject]@{ Name = 'I:\'; DriveType = 'Removable'; IsReady = $true })
      Get-ToolInstallSourceRoots -StickRoot 'E:\' -Drives $drives | Should -Be @('E:\', 'D:\', 'I:\')
      Get-ToolInstallSourceRoots -StickRoot '' -Drives $drives | Should -Be @('D:\', 'E:\', 'I:\')
      Get-ToolInstallSourceRoots -StickRoot 'E:\x' -Drives @() | Should -BeNullOrEmpty
    }
  }
}
