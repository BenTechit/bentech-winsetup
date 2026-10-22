# tests/ToolChecks.Tests.ps1
# Repair & diagnostics Task 2 (repair spec 5, 6.1): the language-independent checks (src\Repair\ToolChecks.ps1), the
# safety strip child (src\Repair\ToolSafety.ps1) and the read-only Health check, end to end on the child side.
#
# SAFETY: this runs on Ben's real PC. For real, these checks start PowerShell grandchildren (Repair-Volume -Scan,
# Repair-WindowsImage -CheckHealth / -ScanHealth, Get-PhysicalDisk, Get-StorageReliabilityCounter, Get-PnpDevice, the
# BCD store, SoftwareLicensingProduct), run sfc.exe /verifyonly, read CIM (BitLocker, the dirty bit), the System event
# log, CBS.log, ReAgent.xml, the registry and the system drive's free space, and open TCP and HTTPS connections. Here
# nothing is started, nothing is changed and no answer comes from this PC:
#   - Invoke-ToolJsonChild answers from $script:gc (a healthy PC unless a test changes it; $script:gcFail makes a
#     grandchild fail or time out); Invoke-ToolNative is mocked; Invoke-External and Invoke-PowerShellChild are never
#     reached (their mocks record the call in $script:blocked and throw); Wait-SetupDelay does not sleep;
#   - Get-ServicingRebootSignals and Get-WinEvent are mocked in every BeforeEach; Get-CimInstance, Invoke-CimMethod,
#     Get-RebootRegistryValue (the registry) and Get-ToolDriveSpace (the drive's bytes) record an unexpected call in
#     $script:blocked and throw, unless a test replaces them;
#   - Test-ToolInternet always gets its two seams, or is mocked; ReAgent.xml and CBS.log come from tests\fixtures or
#     $TestDrive, or their readers are mocked;
#   - safety nets as in ToolEngine.Tests: Start-BackgroundExternal, Stop-ProcessTree, Start-Process, Restart-Computer,
#     Stop-Service, Start-Service, Rename-Item, Remove-BitsTransfer, Set-NetIPInterface, New-NetIPAddress,
#     Set-DnsClientServerAddress, Optimize-Volume, Repair-Volume, Repair-WindowsImage, Set-ItemProperty,
#     New-ItemProperty and Remove-ItemProperty record their name in $script:blocked, then throw; AfterEach asserts that
#     nothing was blocked;
#   - every file a test writes is under $TestDrive.
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Common\Config', 'State\State', 'Steps\Winget', 'Engine\Reboot',
                 'UI\StartScreen', 'Toolbox\Strings', 'Entry\Cleanup', 'Detect\PcName', 'Report\Report', 'Repair\ToolEngine',
                 'Repair\ToolChecks', 'Repair\ToolSafety') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:root = Join-Path $TestDrive 'Root'
  $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
  $script:systemLetter = $env:SystemDrive.Substring(0, 1)
  # Windows' own verify block of the day before: dated 2026-10-21, before any -Since of these tests.
  $script:old = @(
    '2026-10-21 03:12:40, Info                  CSI    00000041 [SR] Verifying 100 components'
    '2026-10-21 03:12:42, Info                  CSI    00000042 [SR] Cannot repair member file [l:7]''old.dll'' of x in the store, hash mismatch'
    '2026-10-21 03:12:43, Info                  CSI    00000043 [SR] Repairing 1 components'
    '2026-10-21 03:12:44, Info                  CSI    00000045 [SR] Verify complete') -join "`r`n"

  function New-TestArgs {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$RunId, [double]$BudgetMinutes = 600)
    @{ Version = 1; Action = $Action; RunId = $RunId
       DeadlineUtc = [datetime]::UtcNow.AddMinutes($BudgetMinutes).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
       BudgetSeconds = $BudgetMinutes * 60; SessionDir = ''; StickRoot = ''; Complaint = ''; Done = @()
       Identity = @{ Key = 'SN-SN123'; FolderPart = 'SN123'; ComputerName = 'PC1' }; Options = @{} }
  }

  # A run of -Action in a fresh run folder: a catalog action ('safety', 'health'), or the fake action 'test' whose
  # steps are -Steps (real step ids, so one step can run on its own).
  function New-TestRun {
    param([string[]]$Steps, [string]$Action = 'test')
    if ($Action -eq 'test') {
      $script:ToolActionCatalog['test'] = @{ Kind = 'readonly'; Confirm = 'none'; NeedsStick = $false; LogLocal = $true; Steps = [string[]]$Steps }
    }
    $runId = '20261022-101500-' + $Action
    $dir = Join-Path $script:root "Tool\$runId"
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $dir -Force
    New-ToolRun -ToolArgs (New-TestArgs -Action $Action -RunId $runId) -Config $script:cfg -Root $script:root
  }

  # A run of the real health action (Invoke-ToolNative, the grandchildren and the SFC reader are mocked per test).
  function New-HealthRun { New-TestRun -Action 'health' }

  # What every grandchild answers on a healthy PC (the Data of Invoke-ToolJsonChild, by grandchild name).
  function Get-HealthyAnswers {
    @{
      volumeScan  = @{ Result = 'NoErrorsFound' }
      imageCheck  = @{ State = 'Healthy' }
      imageScan   = @{ State = 'Healthy' }
      bcd         = @{ RecoveryEnabled = $true; RecoverySequence = @('{0a1b2c3d-1111-2222-3333-444455556666}'); SafeBoot = $null }
      devices     = @{ Items = @() }
      activation  = @{ Statuses = @(1) }
      disks       = @{ Items = @(@{ DeviceId = '0'; FriendlyName = 'Samsung SSD 980 1TB'; MediaType = 'SSD'; BusType = 'NVMe'; HealthStatus = 'Healthy'; Size = 1000204886016 }) }
      reliability = @{ Items = @(@{ DeviceId = '0'; Wear = 3; Temperature = 38; ReadErrorsUncorrected = 0; WriteErrorsUncorrected = 0 }) }
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

  # The disk chip's inputs: one healthy SSD changed by $Set (Health, ReadErrorsUncorrected, Wear, Temperature), a
  # grandchild that times out (TimedOut = <name>), and the one event Get-WinEvent returns (Event = '<provider>/<id>').
  function Set-DiskMocks {
    param([hashtable]$Set)
    $disk = $script:gc['disks']['Items'][0]; $counters = $script:gc['reliability']['Items'][0]
    if ($Set.ContainsKey('Health')) { $disk['HealthStatus'] = $Set['Health'] }
    foreach ($k in 'ReadErrorsUncorrected', 'WriteErrorsUncorrected', 'Wear', 'Temperature') { if ($Set.ContainsKey($k)) { $counters[$k] = $Set[$k] } }
    if ($Set.ContainsKey('TimedOut')) { $script:gcFail[$Set['TimedOut']] = 'timed out' }
    if ($Set.ContainsKey('Event')) { $script:diskEvent = $Set['Event'] }
  }

  function Get-AllSignalsOff {
    @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $false; ComputerRenamePending = $false }
  }

  function New-TestChip { param([string]$Level = 'ok') @{ Level = $Level; Args = [string[]]@(); Detail = @{} } }

  function Get-FindingRows { param($Run) @(foreach ($f in $Run.Findings) { '{0}|{1}' -f $f.Level, $f.Code }) }
}

Describe 'ToolChecks and ToolSafety (repair Task 2)' {
  BeforeEach {
    $script:blocked = New-Object System.Collections.ArrayList
    $script:gc = Get-HealthyAnswers; $script:gcFail = @{}
    $script:gcCalls = New-Object System.Collections.ArrayList
    $script:diskEvent = $null
    Mock Invoke-ToolJsonChild { [void]$script:gcCalls.Add(@{ Name = $Name; Command = $Command; StepTimeout = $StepTimeout }); Get-TestChildAnswer -Name $Name }
    Mock Invoke-ToolNative { @{ ExitCode = 0; TimedOut = $false; OutputPath = $null } }
    Mock Wait-SetupDelay { }
    Mock Get-ServicingRebootSignals { Get-AllSignalsOff }
    Mock Get-WinEvent {
      if ($script:diskEvent) {
        $parts = $script:diskEvent -split '/'
        [pscustomobject]@{ ProviderName = $parts[0]; Id = [int]$parts[1]; TimeCreated = (Get-Date).AddDays(-2) }
      } else {
        Write-Error -Message 'No events were found that match the specified selection criteria.' -ErrorId 'NoMatchingEventsFound' -Category ObjectNotFound
      }
    }
    # Never reached: the runners above them are mocked.
    Mock Invoke-External { [void]$script:blocked.Add('Invoke-External'); throw 'blocked by the test: Invoke-External' }
    Mock Invoke-PowerShellChild { [void]$script:blocked.Add('Invoke-PowerShellChild'); throw 'blocked by the test: Invoke-PowerShellChild' }
    # Reads of this PC: a test that needs one replaces the mock.
    Mock Get-CimInstance { [void]$script:blocked.Add('Get-CimInstance'); throw 'not mocked: Get-CimInstance' }
    Mock Invoke-CimMethod { [void]$script:blocked.Add('Invoke-CimMethod'); throw 'not mocked: Invoke-CimMethod' }
    Mock Get-RebootRegistryValue { [void]$script:blocked.Add('Get-RebootRegistryValue'); throw 'not mocked: Get-RebootRegistryValue' }
    Mock Get-ToolDriveSpace { [void]$script:blocked.Add('Get-ToolDriveSpace'); throw 'not mocked: Get-ToolDriveSpace' }
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
    Mock Set-ItemProperty { [void]$script:blocked.Add('Set-ItemProperty'); throw 'blocked by the test: Set-ItemProperty' }
    Mock New-ItemProperty { [void]$script:blocked.Add('New-ItemProperty'); throw 'blocked by the test: New-ItemProperty' }
    Mock Remove-ItemProperty { [void]$script:blocked.Add('Remove-ItemProperty'); throw 'blocked by the test: Remove-ItemProperty' }
  }

  AfterEach {
    @($script:blocked) | Should -BeNullOrEmpty
    $script:SetupLogPath = $null
    Unregister-SetupTick
  }

  Describe 'the catalog rows (repair plan, Actions and steps)' {
    It 'safety is an info action that logs locally, with its six steps in order' {
      $a = $script:ToolActionCatalog['safety']
      $a.Kind | Should -Be 'info'; $a.Confirm | Should -Be 'none'; $a.NeedsStick | Should -BeFalse; $a.LogLocal | Should -BeTrue
      @($a.Steps) | Should -Be @('safetyRestart', 'safetyFree', 'safetyBitLocker', 'safetyInternet', 'safetyDisk', 'safetyDiskCheck')
    }
    It 'health is a read-only action that logs to the session, with its seven steps in order' {
      $a = $script:ToolActionCatalog['health']
      $a.Kind | Should -Be 'readonly'; $a.Confirm | Should -Be 'none'; $a.NeedsStick | Should -BeFalse; $a.LogLocal | Should -BeFalse
      @($a.Steps) | Should -Be @('volumeScan', 'imageCheck', 'imageScan', 'sfcVerify', 'winre', 'devices', 'activation')
    }
    It 'every step of both has its function; none is a servicing step (read-only actions run with a restart pending, spec 5)' {
      foreach ($id in @($script:ToolActionCatalog['safety'].Steps) + @($script:ToolActionCatalog['health'].Steps)) {
        $s = $script:ToolSteps[$id]
        $s | Should -Not -BeNullOrEmpty -Because $id
        $s.Function | Should -BeExactly ('Invoke-ToolStep' + $id.Substring(0, 1).ToUpperInvariant() + $id.Substring(1)) -Because $id
        (Get-Command -Name $s.Function -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because $id
        $s.Servicing | Should -BeFalse -Because $id
      }
    }
  }

  Describe 'the Task 2 findings (repair plan, Findings)' {
    It 'holds every Task 2 finding, exactly in English, and in Hebrew with the same arguments' {
      $expected = @{
        'finding.volumeSpotFix'      = 'Disk scan found errors that need a disk check at restart'
        'finding.volumeFullRepair'   = 'Disk scan found errors that need a full offline repair: back up first'
        'finding.volumeScanNeeded'   = 'Disk scan could not finish online: a full scan is needed'
        'finding.volumeUnknown'      = 'Disk scan gave no result ({0})'
        'finding.imageRepairable'    = 'The Windows image is corrupt but repairable: run Standard repair'
        'finding.imageNonRepairable' = 'The Windows image is corrupt and cannot be repaired online'
        'finding.imageUnknown'       = 'The Windows image check gave no result ({0})'
        'finding.sfcCorrupt'         = 'System files: {0} integrity problems found (nothing repaired yet)'
        'finding.sfcCannotRepair'    = 'System files: {0} files could not be repaired'
        'finding.sfcNotRun'          = 'SFC left no result in CBS.log: restart, then run it again'
        'finding.sfcTimedOut'        = 'SFC timed out and may still run in the background: restart before running it again'
        'finding.winreOff'           = 'Windows Recovery (WinRE) is off'
        'finding.winreUnknown'       = 'WinRE: the boot configuration and ReAgent.xml disagree (often after a clone); nothing was changed'
        'finding.devicesProblem'     = '{0} devices have a problem (codes {1})'
        'finding.devicesDisabled'    = '{0} devices are disabled'
        'finding.devicesUnknown'     = 'The device list could not be read ({0})'
        'finding.notActivated'       = 'Windows is not activated'
        'finding.activationUnknown'  = 'Activation could not be read'
      }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        ([regex]::Matches($script:ToolboxStrings.he[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',' |
          Should -Be (([regex]::Matches($expected[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',') -Because $k
      }
    }
  }

  Describe 'SFC from CBS.log (review I-3)' {
    It '<F>: Repaired <R>, CannotRepair <C>, Corrupt <K>' -ForEach @(
      @{ F = 'cbs-clean.log'; R = 0; C = 0; K = 0 }, @{ F = 'cbs-repaired.log'; R = 3; C = 0; K = 0 }
      @{ F = 'cbs-cannot-repair.log'; R = 0; C = 2; K = 2 }, @{ F = 'cbs-verify-corrupt.log'; R = 0; C = 0; K = 4 }) {
      $x = ConvertFrom-CbsSrText -Text ([IO.File]::ReadAllText("$PSScriptRoot\fixtures\$F")) -Since ([datetime]'2026-10-22 10:00:00')
      $x.Ran | Should -BeTrue; $x.Repaired | Should -Be $R; $x.CannotRepair | Should -Be $C; $x.Corrupt | Should -Be $K
      $x.VerifyComplete | Should -BeTrue
      @($x.Lines).Count | Should -Be ([math]::Max($K, [int]($R -gt 0)))
    }
    It 'lines before -Since (Windows'' own verify blocks) are ignored' {
      $x = ConvertFrom-CbsSrText -Text $script:old -Since ([datetime]'2026-10-22 10:00')
      $x.Ran | Should -BeFalse; $x.VerifyComplete | Should -BeFalse; $x.Repaired | Should -Be 0; $x.CannotRepair | Should -Be 0; $x.Corrupt | Should -Be 0
      @($x.Lines).Count | Should -Be 0
    }
    It 'a line up to 5 s before -Since still counts; one 6 s before does not' {
      $text = "2026-10-22 09:59:55, Info  CSI  00000001 [SR] Repairing 2 components`r`n2026-10-22 09:59:54, Info  CSI  00000002 [SR] Repairing 5 components"
      (ConvertFrom-CbsSrText -Text $text -Since ([datetime]'2026-10-22 10:00')).Repaired | Should -Be 2
    }
    It 'a Hebrew-calendar culture on the thread changes nothing' {
      $saved = [Threading.Thread]::CurrentThread.CurrentCulture
      try {
        $culture = New-Object Globalization.CultureInfo 'he-IL'
        $culture.DateTimeFormat.Calendar = New-Object Globalization.HebrewCalendar
        [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        $x = ConvertFrom-CbsSrText -Text ([IO.File]::ReadAllText("$PSScriptRoot\fixtures\cbs-repaired.log")) -Since ([datetime]'2026-10-22 10:00:00')
      } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture = $saved
      }
      $x.Repaired | Should -Be 3; $x.Ran | Should -BeTrue
    }
    It 'counts only [SR] lines, keeps at most 40 of the counted ones, and never throws on odd text' {
      $lines = @(foreach ($n in 1..45) { '2026-10-22 10:01:{0:00}, Info  CSI  {1:x8} [SR] Cannot repair member file [l:5]''f{1}.dll'' of x in the store, hash mismatch' -f ($n % 60), $n })
      $lines += '2026-10-22 10:02:00, Info  CSI  00000099 Hashes for file member [l:5]''g.dll'' do not match actual file'
      $x = ConvertFrom-CbsSrText -Text ($lines -join "`n") -Since ([datetime]'2026-10-22 10:00')
      $x.CannotRepair | Should -Be 45; $x.Corrupt | Should -Be 45; @($x.Lines).Count | Should -Be 40
      foreach ($t in '', "no date here [SR] Verify complete", '2026-13-45 99:99:99 [SR] Verify complete', 'short') {
        $y = ConvertFrom-CbsSrText -Text $t -Since ([datetime]'2026-10-22 10:00'); $y.Ran | Should -BeFalse
      }
    }
  }

  Describe 'Read-ToolCbsLog and Read-ToolSfcResult' {
    It 'reads the end of CBS.log and every CbsPersist log written after -Since, the rotated part first' {
      $dir = Join-Path $TestDrive 'CBS'; $null = New-Item -ItemType Directory -Path $dir -Force
      foreach ($f in @(@{ N = 'CbsPersist_20261021031200.log'; T = 'OLD PERSIST'; W = '2026-10-21 03:20' }, @{ N = 'CbsPersist_20261022100500.log'; T = 'ROTATED PART'; W = '2026-10-22 10:05' }, @{ N = 'CBS.log'; T = 'CURRENT PART'; W = '2026-10-22 10:20' })) {
        $p = Join-Path $dir $f.N; [IO.File]::WriteAllText($p, $f.T + "`r`n"); [IO.File]::SetLastWriteTime($p, [datetime]$f.W)
      }
      $t = Read-ToolCbsLog -Since ([datetime]'2026-10-22 10:00') -Folder $dir
      $t | Should -Match 'ROTATED PART'; $t | Should -Match 'CURRENT PART'; $t | Should -Not -Match 'OLD PERSIST'
      $t.IndexOf('ROTATED PART') | Should -BeLessThan $t.IndexOf('CURRENT PART')
    }
    It 'reads at most the last 16 MB of each file' {
      $dir = Join-Path $TestDrive 'CBS16'; $null = New-Item -ItemType Directory -Path $dir -Force
      [IO.File]::WriteAllText((Join-Path $dir 'CBS.log'), 'x')
      Mock Read-FileTail { 'tail' }
      Read-ToolCbsLog -Since ([datetime]'2026-10-22 10:00') -Folder $dir | Should -Match 'tail'
      Should -Invoke Read-FileTail -Times 1 -Exactly -ParameterFilter { $MaxBytes -eq 16MB -and $Path -like '*\CBS.log' }
    }
    It 'a missing folder is empty text, never a throw' {
      Read-ToolCbsLog -Since ([datetime]'2026-10-22 10:00') -Folder (Join-Path $TestDrive 'NoCBS') | Should -BeExactly ''
    }
    It 'waits in 2-second slices until Verify complete appears, then parses (CBS.log is written late)' {
      $script:cbsReads = 0
      Mock Read-ToolCbsLog {
        $script:cbsReads++
        if ($script:cbsReads -lt 3) { '2026-10-22 10:00:05, Info  CSI  00000001 [SR] Verifying 100 components' }
        else { [IO.File]::ReadAllText("$script:fixtures\cbs-verify-corrupt.log") }
      }
      $x = Read-ToolSfcResult -Run (New-TestRun 'sfcVerify') -Since ([datetime]'2026-10-22 10:00')
      $x.Corrupt | Should -Be 4; $x.VerifyComplete | Should -BeTrue; $script:cbsReads | Should -Be 3
      Should -Invoke Wait-SetupDelay -Times 2 -Exactly -ParameterFilter { $Seconds -eq 2 }
      Should -Invoke Read-ToolCbsLog -Times 3 -Exactly -ParameterFilter { $Since -eq [datetime]'2026-10-22 10:00' }
    }
    It 'gives up after 30 s (15 slices of 2 s) and returns what it found' {
      Mock Read-ToolCbsLog { '' }
      $x = Read-ToolSfcResult -Run (New-TestRun 'sfcVerify') -Since ([datetime]'2026-10-22 10:00')
      $x.Ran | Should -BeFalse; $x.VerifyComplete | Should -BeFalse
      Should -Invoke Wait-SetupDelay -Times 15 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }
  }

  Describe 'WinRE (spec 6.1, builder check 7)' {
    It 'BCD <B> + ReAgent <A> -> <V>, CanEnable <E>' -ForEach @(
      @{ B = 'On'; A = 'On'; V = 'On'; E = $false }, @{ B = 'On'; A = 'Missing'; V = 'On'; E = $false }, @{ B = 'On'; A = 'Unknown'; V = 'On'; E = $false }
      @{ B = 'On'; A = 'Off'; V = 'Unknown'; E = $false }
      @{ B = 'Off'; A = 'Off'; V = 'Off'; E = $true }
      @{ B = 'Off'; A = 'On'; V = 'Unknown'; E = $false }
      @{ B = 'Off'; A = 'Missing'; V = 'Off'; E = $false }, @{ B = 'Off'; A = 'Unknown'; V = 'Off'; E = $false }
      @{ B = 'Unknown'; A = 'On'; V = 'Unknown'; E = $false }, @{ B = 'Unknown'; A = 'Off'; V = 'Unknown'; E = $false }
      @{ B = 'Unknown'; A = 'Missing'; V = 'Unknown'; E = $false }, @{ B = 'Unknown'; A = 'Unknown'; V = 'Unknown'; E = $false }
      @{ B = 'garbage'; A = 'Off'; V = 'Unknown'; E = $false }) {
      $r = Resolve-WinReVerdict -Bcd $B -ReAgent $A; $r.Verdict | Should -BeExactly $V; $r.CanEnable | Should -Be $E
    }
    It 'reads ReAgent.xml by attribute, not text' {
      Get-ToolReAgentState -Path "$PSScriptRoot\fixtures\reagent-on.xml" | Should -Be 'On'
      Get-ToolReAgentState -Path "$PSScriptRoot\fixtures\reagent-off.xml" | Should -Be 'Off'
      Get-ToolReAgentState -Path "$TestDrive\none.xml" | Should -Be 'Missing'
    }
    It 'an unreadable or unexpected ReAgent.xml is Unknown: <Why>' -ForEach @(
      @{ Why = 'not XML'; Text = 'not xml at all' }
      @{ Why = 'no InstallState'; Text = '<WindowsRE version="2.0"><WinreBCD id=""/></WindowsRE>' }
      @{ Why = 'a state that is neither 0 nor 1'; Text = '<WindowsRE version="2.0"><InstallState state="2"/></WindowsRE>' }
      @{ Why = 'InstallState under another root'; Text = '<Other><InstallState state="1"/></Other>' }
      @{ Why = 'a DTD (never processed)'; Text = '<?xml version="1.0"?><!DOCTYPE WindowsRE [<!ENTITY s "1">]><WindowsRE><InstallState state="&s;"/></WindowsRE>' }) {
      $p = Join-Path $TestDrive 'odd-reagent.xml'; [IO.File]::WriteAllText($p, $Text)
      Get-ToolReAgentState -Path $p | Should -Be 'Unknown'
    }
    It 'the BCD: <Why> is <R>' -ForEach @(
      @{ Why = 'a recovery sequence with recoveryenabled true'; Data = @{ RecoveryEnabled = $true; RecoverySequence = @('{x}'); SafeBoot = $null }; R = 'On' }
      @{ Why = 'a recovery sequence with recoveryenabled absent (Plan call)'; Data = @{ RecoveryEnabled = $null; RecoverySequence = @('{x}'); SafeBoot = $null }; R = 'On' }
      @{ Why = 'recoveryenabled false'; Data = @{ RecoveryEnabled = $false; RecoverySequence = @('{x}'); SafeBoot = $null }; R = 'Off' }
      @{ Why = 'no recovery sequence'; Data = @{ RecoveryEnabled = $true; RecoverySequence = @(); SafeBoot = $null }; R = 'Off' }
      @{ Why = 'an answer without the recovery sequence key'; Data = @{ RecoveryEnabled = $true }; R = 'Unknown' }) {
      $script:gc['bcd'] = $Data
      (Get-ToolBcdState -Run (New-TestRun 'winre')).Recovery | Should -BeExactly $R
    }
    It 'a BCD grandchild that fails is Unknown; safeboot comes through as a number' {
      $script:gcFail['bcd'] = 'timed out'
      $s = Get-ToolBcdState -Run (New-TestRun 'winre'); $s.Recovery | Should -Be 'Unknown'; $s.SafeBoot | Should -BeNullOrEmpty
      $script:gcFail.Clear(); $script:gc['bcd'] = @{ RecoveryEnabled = $true; RecoverySequence = @('{x}'); SafeBoot = 1 }
      $s = Get-ToolBcdState -Run (New-TestRun 'winre'); $s.Recovery | Should -Be 'On'; $s.SafeBoot | Should -Be 1; $s.SafeBoot | Should -BeOfType [long]
    }
    It 'the BCD grandchild opens {current} in the WMI BcdStore, reads three elements and changes nothing' {
      $null = Get-ToolBcdState -Run (New-TestRun 'winre')
      $c = ($script:gcCalls | Where-Object { $_.Name -eq 'bcd' }).Command
      $c | Should -Match ([regex]::Escape('root\wmi:BcdStore')); $c | Should -Match ([regex]::Escape("OpenStore('')"))
      $c | Should -Match 'fa926493-6f1c-4193-a414-58f0b2456d1e'
      foreach ($e in '0x16000009', '0x14000008', '0x25000080') { $c | Should -Match $e }
      $c | Should -Not -Match '(?i)SetElement|DeleteElement|SetBoolean|SetInteger|CreateObject|DeleteObject|bcdedit|reagentc'
      $errors = $null; $null = [Management.Automation.Language.Parser]::ParseInput($c, [ref]$null, [ref]$errors); @($errors).Count | Should -Be 0
    }
  }

  Describe 'the safety strip (spec 5)' {
    It 'a pending file or computer rename is a grey note, never red' {
      Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $true; ComputerRenamePending = $true } }
      $c = Get-ToolRestartChip; $c.Level | Should -Be 'ok'; $c.Detail.Notes | Should -Be @('PendingFileRename', 'ComputerRenamePending')
      @($c.Detail.Signals).Count | Should -Be 0
    }
    It '<Signal> alone is red' -ForEach @(@{ Signal = 'CbsRebootPending' }, @{ Signal = 'CbsPackagesPending' }, @{ Signal = 'PendingXml' }, @{ Signal = 'WuRebootRequired' }) {
      $script:signal = $Signal
      Mock Get-ServicingRebootSignals { $s = Get-AllSignalsOff; $s[$script:signal] = $true; $s }
      $c = Get-ToolRestartChip; $c.Level | Should -Be 'crit'; $c.Detail.Signals | Should -Be @($Signal)
    }
    It 'no signal is ok; a read that throws is unknown' {
      (Get-ToolRestartChip).Level | Should -Be 'ok'
      Mock Get-ServicingRebootSignals { throw 'registry unreadable' }
      (Get-ToolRestartChip).Level | Should -Be 'unknown'
    }
    It 'free space: <Free> GB of <Size> GB is <L>' -ForEach @(@{ Free = 20; Size = 250; L = 'crit' }, @{ Free = 14; Size = 100; L = 'crit' }, @{ Free = 41; Size = 100; L = 'ok' }
      @{ Free = 15; Size = 150; L = 'ok' }, @{ Free = 14.9; Size = 149; L = 'crit' }) {
      (ConvertTo-ToolFreeChip -FreeBytes ([long]($Free * 1GB)) -TotalBytes ([long]($Size * 1GB)) -Config $script:cfg).Level | Should -Be $L
    }
    It 'free space: Args are the drive and the whole percent; a config without the repair section uses 10% and 15 GB' {
      $c = ConvertTo-ToolFreeChip -FreeBytes (41.7 * 1GB) -TotalBytes (100 * 1GB) -Config $script:cfg
      $c.Args | Should -Be @('C:', '41')
      (ConvertTo-ToolFreeChip -FreeBytes (9 * 1GB) -TotalBytes (100 * 1GB) -Config $script:cfg -Drive 'D:').Args | Should -Be @('D:', '9')
      $bare = [pscustomobject]@{ timeoutsMinutes = $script:cfg.timeoutsMinutes }
      (ConvertTo-ToolFreeChip -FreeBytes (16 * 1GB) -TotalBytes (100 * 1GB) -Config $bare).Level | Should -Be 'ok'
      (ConvertTo-ToolFreeChip -FreeBytes (14 * 1GB) -TotalBytes (100 * 1GB) -Config $bare).Level | Should -Be 'crit'
      (ConvertTo-ToolFreeChip -FreeBytes 0 -TotalBytes 0 -Config $script:cfg).Level | Should -Be 'unknown'
    }
    It 'free space of the system drive comes from its drive info; a failed read is unknown' {
      Mock Get-ToolDriveSpace { @{ FreeBytes = [long](20 * 1GB); TotalBytes = [long](250 * 1GB) } }
      $c = Get-ToolFreeSpaceChip -Config $script:cfg; $c.Level | Should -Be 'crit'; $c.Args | Should -Be @($env:SystemDrive, '8')
      Should -Invoke Get-ToolDriveSpace -Times 1 -Exactly -ParameterFilter { $Drive -eq $env:SystemDrive }
      Mock Get-ToolDriveSpace { throw 'device not ready' }
      $c = Get-ToolFreeSpaceChip -Config $script:cfg; $c.Level | Should -Be 'unknown'; $c.Args | Should -Be @($env:SystemDrive)
    }
    It 'disk: <Why> is <L>' -ForEach @(
      @{ Why = 'a disk in Warning health'; Set = @{ Health = 'Warning' }; L = 'crit' }, @{ Why = 'uncorrected read errors'; Set = @{ ReadErrorsUncorrected = 3 }; L = 'crit' }
      @{ Why = 'uncorrected write errors'; Set = @{ WriteErrorsUncorrected = 1 }; L = 'crit' }
      @{ Why = 'one disk event 153'; Set = @{ Event = 'disk/153' }; L = 'crit' }, @{ Why = 'NTFS 55'; Set = @{ Event = 'Ntfs/55' }; L = 'crit' }
      @{ Why = 'NTFS 55 under its manifest name'; Set = @{ Event = 'Microsoft-Windows-Ntfs/55' }; L = 'crit' }
      @{ Why = 'an event 153 of another provider'; Set = @{ Event = 'Microsoft-Windows-Kernel-Boot/153' }; L = 'ok' }
      @{ Why = '84% wear'; Set = @{ Wear = 84 }; L = 'warn' }, @{ Why = '80% wear (the threshold)'; Set = @{ Wear = 80 }; L = 'warn' }, @{ Why = '79% wear'; Set = @{ Wear = 79 }; L = 'ok' }
      @{ Why = '61 C'; Set = @{ Temperature = 61 }; L = 'warn' }, @{ Why = 'a grandchild that timed out'; Set = @{ TimedOut = 'disks' }; L = 'unknown' }
      @{ Why = 'the counters grandchild that timed out'; Set = @{ TimedOut = 'reliability' }; L = 'unknown' }
      @{ Why = 'a timed-out grandchild and a disk event'; Set = @{ TimedOut = 'disks'; Event = 'disk/7' }; L = 'crit' }
      @{ Why = 'counters a disk does not report'; Set = @{ Wear = $null; Temperature = $null; ReadErrorsUncorrected = $null }; L = 'ok' }
      @{ Why = 'all fine'; Set = @{}; L = 'ok' }) {
      Set-DiskMocks $Set
      (Get-ToolDiskChip -Run (New-TestRun 'safetyDisk')).Level | Should -Be $L
    }
    It 'disk: the events come from the System log by ID since diskEventDays, and the provider is checked' {
      Set-DiskMocks @{ Event = 'disk/51' }
      $c = Get-ToolDiskChip -Run (New-TestRun 'safetyDisk')
      $c.Detail.Events | Should -Be 1; $c.Detail.Reasons | Should -Contain 'events'
      Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter {
        $FilterHashtable.LogName -eq 'System' -and (@($FilterHashtable.Id) -join ',') -eq '7,51,153,55' -and
        [math]::Abs(((Get-Date) - $FilterHashtable.StartTime).TotalDays - 30) -lt 0.01 }
    }
    It 'disk: an event log that cannot be read is unknown, never a throw' {
      Mock Get-WinEvent { Write-Error -Message 'The RPC server is unavailable' -ErrorId 'RpcUnavailable' -Category ResourceUnavailable }
      $c = Get-ToolDiskChip -Run (New-TestRun 'safetyDisk'); $c.Level | Should -Be 'unknown'; $c.Detail.Failed | Should -Contain 'events'
    }
    It 'disk: no counters grandchild after the disk list timed out (it would hang the same way); both bounded' {
      Set-DiskMocks @{ TimedOut = 'disks' }
      $null = Get-ToolDiskChip -Run (New-TestRun 'safetyDisk')
      @($script:gcCalls.Name) | Should -Be @('disks')
      $script:gcFail.Clear(); $script:gcCalls.Clear()
      $c = Get-ToolDiskChip -Run (New-TestRun 'safetyDisk')
      @($script:gcCalls.Name) | Should -Be @('disks', 'reliability')
      ($script:gcCalls | Where-Object { $_.Name -eq 'disks' }).Command | Should -Match 'Get-PhysicalDisk'
      ($script:gcCalls | Where-Object { $_.Name -eq 'reliability' }).Command | Should -Match 'Get-StorageReliabilityCounter'
      $c.Detail.Disks[0].FriendlyName | Should -Be 'Samsung SSD 980 1TB'; $c.Detail.Disks[0].Wear | Should -Be 3
    }
    It 'BitLocker reports protector types and never asks for a key' {
      Mock Get-CimInstance { New-CimInstance -ClassName 'Win32_EncryptableVolume' -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClientOnly -Property @{ DriveLetter = 'C:'; ProtectionStatus = [uint32]1 } } -ParameterFilter { $ClassName -eq 'Win32_EncryptableVolume' }
      Mock Invoke-CimMethod {
        switch ($MethodName) {
          'GetKeyProtectors' { [pscustomobject]@{ VolumeKeyProtectorID = [string[]]@('{A}', '{B}'); ReturnValue = [uint32]0 } }
          'GetKeyProtectorType' { [pscustomobject]@{ KeyProtectorType = [uint32]$(if ($Arguments['VolumeKeyProtectorID'] -eq '{A}') { 1 } else { 3 }); ReturnValue = [uint32]0 } }
          default { throw "unexpected method $MethodName" }
        } }
      $c = Get-ToolBitLockerChip
      $c.Level | Should -Be 'warn'; $c.Detail.Protectors | Should -Be @('Tpm', 'RecoveryPassword'); $c.Detail.ProtectionStatus | Should -Be 1
      Should -Invoke Invoke-CimMethod -Times 0 -ParameterFilter { $MethodName -like '*NumericalPassword*' }
      Should -Invoke Invoke-CimMethod -Times 3 -Exactly -ParameterFilter { $OperationTimeoutSec -eq 15 }
      Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
        $Namespace -eq 'root\cimv2\Security\MicrosoftVolumeEncryption' -and $Filter -eq ("DriveLetter='{0}'" -f $env:SystemDrive) -and $OperationTimeoutSec -eq 15 }
    }
    It 'BitLocker: protection off is ok; no volume, a CIM failure or a timeout is unknown' {
      Mock Get-CimInstance { New-CimInstance -ClassName 'Win32_EncryptableVolume' -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClientOnly -Property @{ DriveLetter = 'C:'; ProtectionStatus = [uint32]0 } } -ParameterFilter { $ClassName -eq 'Win32_EncryptableVolume' }
      Mock Invoke-CimMethod { [pscustomobject]@{ VolumeKeyProtectorID = [string[]]@(); ReturnValue = [uint32]0 } }
      $c = Get-ToolBitLockerChip; $c.Level | Should -Be 'ok'; @($c.Detail.Protectors).Count | Should -Be 0
      Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'Win32_EncryptableVolume' }
      (Get-ToolBitLockerChip).Level | Should -Be 'unknown'
      Mock Get-CimInstance { Write-Error -Message 'The operation did not complete within the time allotted' -Category OperationTimeout } -ParameterFilter { $ClassName -eq 'Win32_EncryptableVolume' }
      (Get-ToolBitLockerChip).Level | Should -Be 'unknown'
    }
    It 'internet: TCP fails -> crit and no HTTPS attempt; both fine -> ok with the clock offset' {
      $script:fetched = 0
      $t = Test-ToolInternet -Config $script:cfg -Connect { param($h, $ms) $false } -Fetch { param($u, $ms) $script:fetched++; @{ Ok = $true; Date = [datetime]::UtcNow } }
      $t.Chip.Level | Should -Be 'crit'; $script:fetched | Should -Be 0; $t.Tcp | Should -BeFalse; $t.Https | Should -BeFalse
      $t = Test-ToolInternet -Config $script:cfg -Connect { param($h, $ms) $h -eq 'www.msftconnecttest.com' -and $ms -eq 5000 } -Fetch { param($u, $ms) @{ Ok = ($u -eq 'https://www.msftconnecttest.com/connecttest.txt' -and $ms -eq 5000); Date = [datetime]::UtcNow.AddMinutes(-3) } }
      $t.Chip.Level | Should -Be 'ok'; [math]::Round($t.ClockOffsetSeconds / 60) | Should -Be 3; $t.Tcp | Should -BeTrue; $t.Https | Should -BeTrue
      $t.Chip.Detail.ClockOffsetSeconds | Should -Be $t.ClockOffsetSeconds
    }
    It 'internet: <Why> is crit' -ForEach @(
      @{ Why = 'an HTTPS request that fails'; Connect = { param($h, $ms) $true }; Fetch = { param($u, $ms) @{ Ok = $false; Date = $null } } }
      @{ Why = 'a TCP seam that throws'; Connect = { param($h, $ms) throw 'no route' }; Fetch = { param($u, $ms) @{ Ok = $true; Date = $null } } }
      @{ Why = 'an HTTPS seam that throws'; Connect = { param($h, $ms) $true }; Fetch = { param($u, $ms) throw 'TLS failed' } }) {
      $t = Test-ToolInternet -Config $script:cfg -Connect $Connect -Fetch $Fetch
      $t.Chip.Level | Should -Be 'crit'; $t.ClockOffsetSeconds | Should -BeNullOrEmpty
    }
    It 'internet: a config without the repair section uses the pinned host, URL and 5 s' {
      $t = Test-ToolInternet -Config ([pscustomobject]@{}) -Connect { param($h, $ms) $h -eq 'www.msftconnecttest.com' -and $ms -eq 5000 } -Fetch { param($u, $ms) @{ Ok = ($u -eq 'https://www.msftconnecttest.com/connecttest.txt'); Date = $null } }
      $t.Chip.Level | Should -Be 'ok'; $t.ClockOffsetSeconds | Should -BeNullOrEmpty
    }
    It 'disk check state: the dirty bit from Win32_Volume, and Excluded when BootExecute holds /k:<letter>' {
      Mock Get-CimInstance { [pscustomobject]@{ DriveLetter = 'C:'; DirtyBitSet = $true } } -ParameterFilter { $ClassName -eq 'Win32_Volume' }
      Mock Get-RebootRegistryValue { @('autocheck autochk /k:C *') } -ParameterFilter { $Name -eq 'BootExecute' }
      $s = Get-ToolDiskCheckState -Drive 'C:'; $s.Dirty | Should -BeTrue; $s.Excluded | Should -BeTrue
      Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $Filter -eq "DriveLetter='C:'" -and $OperationTimeoutSec -eq 15 }
      Should -Invoke Get-RebootRegistryValue -Times 1 -Exactly -ParameterFilter { $Path -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' }
    }
    It 'disk check state: the default BootExecute or another drive is not excluded; a CIM failure leaves Dirty unknown' {
      Mock Get-CimInstance { [pscustomobject]@{ DriveLetter = 'C:'; DirtyBitSet = $false } } -ParameterFilter { $ClassName -eq 'Win32_Volume' }
      Mock Get-RebootRegistryValue { @('autocheck autochk *') } -ParameterFilter { $Name -eq 'BootExecute' }
      $s = Get-ToolDiskCheckState -Drive 'C:'; $s.Dirty | Should -BeFalse; $s.Excluded | Should -BeFalse
      Mock Get-RebootRegistryValue { @('autocheck autochk /k:D *') } -ParameterFilter { $Name -eq 'BootExecute' }
      (Get-ToolDiskCheckState -Drive 'C:').Excluded | Should -BeFalse
      Mock Get-CimInstance { Write-Error -Message 'Access denied' -Category PermissionDenied } -ParameterFilter { $ClassName -eq 'Win32_Volume' }
      $s = Get-ToolDiskCheckState -Drive 'C:'; $s.Dirty | Should -BeNullOrEmpty; $s.ContainsKey('Dirty') | Should -BeTrue
    }
    It 'each chip lands in progress.Partial as soon as it is known' {
      $script:gcFail['disks'] = 'timed out'
      $script:seen = $null
      Mock Invoke-ToolJsonChild {
        [void]$script:gcCalls.Add(@{ Name = $Name; Command = $Command; StepTimeout = $StepTimeout })
        if ($Name -eq 'disks') { $script:seen = Read-ToolJsonFile -Path $script:currentRun.ProgressPath }
        Get-TestChildAnswer -Name $Name }
      Mock Get-ToolFreeSpaceChip { New-TestChip 'ok' }
      Mock Get-ToolBitLockerChip { New-TestChip 'warn' }
      Mock Test-ToolInternet { @{ Tcp = $true; Https = $true; ClockOffsetSeconds = 1.5; Chip = (New-TestChip 'ok') } }
      Mock Get-ToolDiskCheckState { @{ Dirty = $false; Excluded = $false } }
      $r = New-TestRun -Action 'safety'; $script:currentRun = $r
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:seen.Partial.Chips.Restart.Level | Should -Be 'ok'
      @($script:seen.Partial.Chips.Keys | Sort-Object) | Should -Be @('BitLocker', 'Free', 'Internet', 'Restart')
      $p = Read-ToolJsonFile -Path $r.ProgressPath
      $p.Partial.Chips.Disk.Level | Should -Be 'unknown'; $p.Partial.DiskCheck.Dirty | Should -BeFalse
      @($r.Data.Chips.Keys | Sort-Object) | Should -Be @('BitLocker', 'Disk', 'Free', 'Internet', 'Restart')
      $r.Data.DiskCheck.Excluded | Should -BeFalse
      Should -Invoke Invoke-ToolJsonChild -Times 0 -Exactly -ParameterFilter { $Name -eq 'reliability' }
      @($r.Steps.Status) | Should -Be @('done', 'done', 'done', 'done', 'warn', 'done')
      $r.Findings.Count | Should -Be 0
    }
    It 'the safety result carries every chip and the disk check state, deep enough for the window' {
      Mock Get-ToolFreeSpaceChip { @{ Level = 'crit'; Args = [string[]]@('C:', '8'); Detail = @{ FreeBytes = 1 } } }
      Mock Get-ToolBitLockerChip { New-TestChip 'ok' }
      Mock Test-ToolInternet { @{ Tcp = $false; Https = $false; ClockOffsetSeconds = $null; Chip = (New-TestChip 'crit') } }
      Mock Get-ToolDiskCheckState { @{ Dirty = $true; Excluded = $false } }
      $r = New-TestRun -Action 'safety'
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; Write-ToolResult -Run $r -Outcome 'Done' | Should -BeTrue
      $res = Read-ToolJsonFile -Path $r.ResultPath
      $res.Data.Chips.Free.Level | Should -Be 'crit'; @($res.Data.Chips.Free.Args) | Should -Be @('C:', '8')
      $res.Data.Chips.Internet.Level | Should -Be 'crit'; $res.Data.Chips.Disk.Level | Should -Be 'ok'
      $res.Data.Chips.Disk.Detail.Disks[0].Wear | Should -Be 3; $res.Data.DiskCheck.Dirty | Should -BeTrue
      $res.Color | Should -Be 'GREEN'
      [IO.File]::ReadAllText($r.ResultPath) | Should -Not -Match '[^\x00-\x7F]'
    }
    It 'a chip reader that throws makes its chip unknown, never a red result' {
      Mock Get-ToolFreeSpaceChip { throw 'unexpected' }
      Mock Get-ToolBitLockerChip { New-TestChip 'ok' }
      Mock Test-ToolInternet { throw 'unexpected' }
      Mock Get-ToolDiskCheckState { throw 'unexpected' }
      $r = New-TestRun -Action 'safety'
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $r.Data.Chips.Free.Level | Should -Be 'unknown'; $r.Data.Chips.Internet.Level | Should -Be 'unknown'
      $r.Data.DiskCheck.ContainsKey('Dirty') | Should -BeTrue; $r.Data.DiskCheck.Dirty | Should -BeNullOrEmpty
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN'
    }
  }

  Describe 'Health check (spec 6.1)' {
    BeforeEach {
      $script:sfcOutput = 'Windows Resource Protection did not find any integrity violations.'
      $script:nativeAt = $null
      Mock Invoke-ToolNative {
        $script:nativeAt = Get-Date
        $p = Join-Path $Run.LogDir 'sfc-101500.txt'
        [IO.File]::WriteAllText($p, $script:sfcOutput, [Text.Encoding]::Unicode)
        @{ ExitCode = 0; TimedOut = $false; OutputPath = $p } }
      Mock Read-ToolSfcResult { @{ Ran = $true; VerifyComplete = $true; Repaired = 0; CannotRepair = 0; Corrupt = 0; Lines = @() } }
      $script:reagent = 'On'
      Mock Get-ToolReAgentState { $script:reagent }
    }
    It 'runs its seven steps in order and only reads' {
      $r = New-HealthRun
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      @($r.Steps.Status) | Should -Be @('done', 'done', 'done', 'done', 'done', 'done', 'done')
      @($script:gcCalls.Name) | Should -Be @('volumeScan', 'imageCheck', 'imageScan', 'bcd', 'devices', 'activation')
      Should -Invoke Invoke-ToolNative -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\sfc.exe' -and $ArgumentList -eq '/verifyonly' -and $OutputName -eq 'sfc' -and $StepTimeout -eq 'sfc' }
      Should -Invoke Invoke-ToolNative -Times 0 -ParameterFilter { $FilePath -match 'reagentc|pnputil|dism|fsutil' }
      # The grandchildren only read: no repair switch, no device rescan, no change to the boot configuration.
      foreach ($c in $script:gcCalls) {
        $c.Command | Should -Not -Match '(?i)RestoreHealth|StartComponentCleanup|-SpotFix|-OfflineScanAndFix|pnputil|scan-devices|reagentc|SetElement|Enable-|Disable-|Remove-|Set-' -Because $c.Name
      }
      $r.Findings.Count | Should -Be 0; Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN'
      $r.Data.VolumeScan | Should -Be 'NoErrorsFound'; $r.Data.ImageCheck | Should -Be 'Healthy'; $r.Data.ImageHealth | Should -Be 'Healthy'
      $r.Data.WinRe.Verdict | Should -Be 'On'; $r.Data.Activation | Should -Be 'Activated'; $r.Data.Sfc.Corrupt | Should -Be 0
      $r.Offers.DiskCheck | Should -BeFalse
    }
    It 'Health check verdicts come from enums, exit codes and English CBS.log; Hebrew tool text changes nothing (Review Focus 4)' {
      # sfc's own (Hebrew, UTF-16) output claims a successful repair; CBS.log says otherwise, and only CBS.log counts.
      $script:sfcOutput = 'הגנת המשאבים של Windows מצאה קבצים פגומים ותיקנה אותם בהצלחה. 100%'
      $script:gc['volumeScan'] = @{ Result = 'SpotFixNeeded' }
      $script:gc['imageCheck'] = @{ State = 'Repairable' }; $script:gc['imageScan'] = @{ State = 'Repairable' }
      $script:gc['devices'] = @{ Items = @(@{ InstanceId = 'USB\VID_0BDA&PID_8153\000001'; Class = 'Net'; Name = 'התקן לא ידוע'; Status = 'Error'; ConfigManagerErrorCode = 28 }) }
      $script:gc['activation'] = @{ Statuses = @(0) }
      $script:reagent = 'Off'    # the BCD says on, ReAgent.xml off: a clone
      Mock Read-ToolSfcResult { ConvertFrom-CbsSrText -Text ([IO.File]::ReadAllText("$script:fixtures\cbs-verify-corrupt.log")) -Since ([datetime]'2026-10-22 10:00') }
      $r = New-HealthRun; $null = Invoke-ToolSteps -Run $r
      @($r.Findings | ForEach-Object { '{0}|{1}' -f $_.Level, $_.Code }) | Should -Be @('CRIT|volumeSpotFix', 'WARN|imageRepairable', 'WARN|sfcCorrupt', 'WARN|winreUnknown', 'WARN|devicesProblem', 'WARN|notActivated')
      $r.Offers.DiskCheck | Should -BeTrue
      ($r.Findings | Where-Object { $_.Code -eq 'sfcCorrupt' }).Text | Should -BeExactly 'System files: 4 integrity problems found (nothing repaired yet)'
      ($r.Findings | Where-Object { $_.Code -eq 'devicesProblem' }).Text | Should -BeExactly '1 devices have a problem (codes 28)'
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
      # sfc's output file is there (the tick may show it) and nothing Hebrew reached the progress file or the data.
      (Get-ChildItem -LiteralPath $r.LogDir -Filter 'sfc-*.txt').Count | Should -Be 1
      [IO.File]::ReadAllText($r.ProgressPath) | Should -Not -Match '[^\x00-\x7F]'
      (ConvertTo-Json -InputObject $r.Data -Depth 8) | Should -Not -Match '[^\x00-\x7F]'
    }
    It 'a disabled device (CM 22) is INFO, never a problem' {
      $script:gc['devices'] = @{ Items = @(@{ InstanceId = 'PCI\VEN_8086&DEV_15F3\3&11583659&0&FE'; Class = 'Net'; Name = 'Intel(R) Ethernet Controller I225-V'; Status = 'Error'; ConfigManagerErrorCode = 22 }) }
      $r = New-HealthRun; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $r.Findings.Code | Should -Be @('devicesDisabled')
      $r.Findings[0].Level | Should -Be 'INFO'; @($r.Findings[0].Args) | Should -Be @('1')
      $r.Data.Devices.Disabled | Should -Be 1; $r.Data.Devices.Problem | Should -Be 0
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN'
    }
    It 'the disk scan: <Result> gives <Finding>' -ForEach @(
      @{ Result = 'NoErrorsFound'; Finding = @(); Offer = $false; Status = 'done' }
      @{ Result = 'SpotFixNeeded'; Finding = @('CRIT|volumeSpotFix'); Offer = $true; Status = 'warn' }
      @{ Result = 'FullRepairNeeded'; Finding = @('CRIT|volumeFullRepair'); Offer = $false; Status = 'warn' }
      @{ Result = 'ScanNeeded'; Finding = @('WARN|volumeScanNeeded'); Offer = $false; Status = 'warn' }
      @{ Result = 'Gibberish'; Finding = @('WARN|volumeUnknown'); Offer = $false; Status = 'warn' }) {
      $script:gc['volumeScan'] = @{ Result = $Result }
      $r = New-TestRun 'volumeScan'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Get-FindingRows $r | Should -Be $Finding
      $r.Offers.DiskCheck | Should -Be $Offer; @($r.Steps.Status) | Should -Be @($Status)
      $expected = if ($Result -eq 'Gibberish') { 'Unknown' } else { $Result }
      $r.Data.VolumeScan | Should -Be $expected
    }
    It 'the disk scan runs Repair-Volume -Scan on the system drive in a grandchild bounded by toolStep.volumeScan' {
      Get-ToolVolumeScan -Run (New-TestRun 'volumeScan') | Should -Be 'NoErrorsFound'
      $c = $script:gcCalls[0]; $c.Name | Should -Be 'volumeScan'; $c.StepTimeout | Should -Be 'volumeScan'
      $c.Command | Should -Match ([regex]::Escape("Repair-Volume -DriveLetter '$script:systemLetter' -Scan"))
    }
    It 'a disk scan that timed out is volumeUnknown (timed out): yellow, never a generic red' {
      $script:gcFail['volumeScan'] = 'timed out'
      $r = New-TestRun 'volumeScan'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Get-FindingRows $r | Should -Be @('WARN|volumeUnknown'); @($r.Findings[0].Args) | Should -Be @('timed out')
      @($r.Steps.Status) | Should -Be @('timedout'); Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'YELLOW'
    }
    It 'the image scan: <State> gives <Finding>' -ForEach @(
      @{ State = 'Healthy'; Finding = @(); Status = 'done' }
      @{ State = 'Repairable'; Finding = @('WARN|imageRepairable'); Status = 'warn' }
      @{ State = 'NonRepairable'; Finding = @('CRIT|imageNonRepairable'); Status = 'warn' }
      @{ State = 'Odd'; Finding = @('WARN|imageUnknown'); Status = 'warn' }) {
      $script:gc['imageScan'] = @{ State = $State }
      $r = New-TestRun 'imageScan'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Get-FindingRows $r | Should -Be $Finding; @($r.Steps.Status) | Should -Be @($Status)
    }
    It 'the check step only logs; an image scan that timed out is imageUnknown, yellow' {
      $script:gc['imageCheck'] = @{ State = 'NonRepairable' }; $script:gcFail['imageScan'] = 'timed out'
      $r = New-TestRun 'imageCheck', 'imageScan'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Get-FindingRows $r | Should -Be @('WARN|imageUnknown'); @($r.Findings[0].Args) | Should -Be @('timed out')
      @($r.Steps.Status) | Should -Be @('warn', 'timedout'); $r.Data.ImageCheck | Should -Be 'NonRepairable'; $r.Data.ImageHealth | Should -Be 'Unknown'
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'YELLOW'
      @($script:gcCalls | ForEach-Object { '{0}|{1}' -f $_.Name, $_.StepTimeout }) | Should -Be @('imageCheck|imageCheck', 'imageScan|imageScan')
      $script:gcCalls[0].Command | Should -Match 'Repair-WindowsImage -Online -CheckHealth'
      $script:gcCalls[1].Command | Should -Match 'Repair-WindowsImage -Online -ScanHealth'
      $script:gcCalls[1].Command | Should -Match 'ImageHealthState'
    }
    It 'SFC: <Why>' -ForEach @(
      @{ Why = 'a clean pass'; Sfc = @{ Ran = $true; VerifyComplete = $true; Repaired = 0; CannotRepair = 0; Corrupt = 0; Lines = @() }; TimedOut = $false; F = @(); Status = 'done' }
      @{ Why = 'integrity problems'; Sfc = @{ Ran = $true; VerifyComplete = $true; Repaired = 0; CannotRepair = 0; Corrupt = 2; Lines = @('x') }; TimedOut = $false
         F = @('WARN|sfcCorrupt|System files: 2 integrity problems found (nothing repaired yet)'); Status = 'warn' }
      @{ Why = 'no [SR] line since it started'; Sfc = @{ Ran = $false; VerifyComplete = $false; Repaired = 0; CannotRepair = 0; Corrupt = 0; Lines = @() }; TimedOut = $false
         F = @('WARN|sfcNotRun|SFC left no result in CBS.log: restart, then run it again'); Status = 'warn' }
      @{ Why = 'a timeout'; Sfc = $null; TimedOut = $true
         F = @('WARN|sfcTimedOut|SFC timed out and may still run in the background: restart before running it again'); Status = 'timedout' }) {
      $script:sfc = $Sfc; $script:sfcTimedOut = $TimedOut
      Mock Read-ToolSfcResult { $script:sfc }
      if ($TimedOut) { Mock Invoke-ToolNative { $script:nativeAt = Get-Date; @{ ExitCode = $null; TimedOut = $true; OutputPath = $null } } }
      $r = New-TestRun 'sfcVerify'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      @($r.Findings | ForEach-Object { '{0}|{1}|{2}' -f $_.Level, $_.Code, $_.Text }) | Should -Be $F
      @($r.Steps.Status) | Should -Be @($Status)
      if ($TimedOut) { Should -Invoke Read-ToolSfcResult -Times 0 -Exactly }
      else { Should -Invoke Read-ToolSfcResult -Times 1 -Exactly -ParameterFilter { $Since -le $script:nativeAt } }
      if ($F.Count -gt 0) { Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'YELLOW' }
    }
    It 'WinRE: BCD <B> and ReAgent <A> give <F>' -ForEach @(
      @{ B = $true; A = 'On'; F = @(); V = 'On'; E = $false; Status = 'done' }
      @{ B = $false; A = 'Off'; F = @('WARN|winreOff'); V = 'Off'; E = $true; Status = 'warn' }
      @{ B = $true; A = 'Off'; F = @('WARN|winreUnknown'); V = 'Unknown'; E = $false; Status = 'warn' }) {
      $script:gc['bcd'] = @{ RecoveryEnabled = $B; RecoverySequence = @('{x}'); SafeBoot = $null }
      $script:reagent = $A
      $r = New-TestRun 'winre'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Get-FindingRows $r | Should -Be $F; @($r.Steps.Status) | Should -Be @($Status)
      $r.Data.WinRe.Verdict | Should -Be $V; $r.Data.WinRe.CanEnable | Should -Be $E; $r.Data.WinRe.ReAgent | Should -Be $A
      Should -Invoke Invoke-ToolNative -Times 0 -Exactly
    }
    It 'devices: <Why>' -ForEach @(
      @{ Why = 'none with a problem'; Items = @(); Fail = $null; F = @(); FirstArgs = @() }
      @{ Why = 'two problems and a disabled one'; Fail = $null
         Items = @(@{ InstanceId = 'A'; Class = 'Net'; Name = 'a'; Status = 'Error'; ConfigManagerErrorCode = 28 }, @{ InstanceId = 'B'; Class = 'USB'; Name = 'b'; Status = 'Error'; ConfigManagerErrorCode = 10 }
                   @{ InstanceId = 'C'; Class = 'Net'; Name = 'c'; Status = 'Error'; ConfigManagerErrorCode = 22 })
         F = @('WARN|devicesProblem', 'INFO|devicesDisabled'); FirstArgs = @('2', '10, 28') }
      @{ Why = 'a list that could not be read'; Items = $null; Fail = 'timed out'; F = @('WARN|devicesUnknown'); FirstArgs = @('timed out') }) {
      if ($null -ne $Fail) { $script:gcFail['devices'] = $Fail } else { $script:gc['devices'] = @{ Items = $Items } }
      $r = New-TestRun 'devices'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Get-FindingRows $r | Should -Be $F
      if ($F.Count -gt 0) { @($r.Findings[0].Args) | Should -Be $FirstArgs }
      $script:gcCalls[0].Command | Should -Match 'Get-PnpDevice -PresentOnly'
      $script:gcCalls[0].Command | Should -Match 'ConfigManagerErrorCode'
    }
    It 'activation: <Why>' -ForEach @(
      @{ Why = 'a licensed Windows row'; Statuses = @(1); F = @(); State = 'Activated' }
      @{ Why = 'a licensed row among others'; Statuses = @(0, 5, 1); F = @(); State = 'Activated' }
      @{ Why = 'no licensed row'; Statuses = @(0, 5); F = @('WARN|notActivated'); State = 'Not activated' }
      @{ Why = 'no row with a product key'; Statuses = @(); F = @('WARN|notActivated'); State = 'Not activated' }
      @{ Why = 'a query that failed'; Statuses = $null; F = @('INFO|activationUnknown'); State = 'Unknown' }) {
      if ($null -eq $Statuses) { $script:gcFail['activation'] = 'timed out' } else { $script:gc['activation'] = @{ Statuses = $Statuses } }
      $r = New-TestRun 'activation'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Get-FindingRows $r | Should -Be $F; $r.Data.Activation | Should -Be $State
      if ($State -eq 'Unknown') { Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN' }
    }
    It 'activation runs Get-ActivationStatus''s query in a bounded grandchild' {
      $null = Get-ToolActivation -Run (New-TestRun 'activation')
      $c = $script:gcCalls[0].Command
      $c | Should -Match 'SoftwareLicensingProduct'; $c | Should -Match ([regex]::Escape($script:WindowsLicensingApplicationId)); $c | Should -Match 'PartialProductKey IS NOT NULL'
      $c | Should -Match 'LicenseStatus'
    }
  }
}
