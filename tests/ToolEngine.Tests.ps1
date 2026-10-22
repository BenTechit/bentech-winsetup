# tests/ToolEngine.Tests.ps1
# Repair & diagnostics Task 1 (repair spec 4.3, 5, 7, 10): the engine of the action child (src\Repair\ToolEngine.ps1):
# the args, progress and result files, the step runner, the bounded native and grandchild runners, and the child
# entry Invoke-SetupToolProcess.
#
# SAFETY: this runs on Ben's real PC. For real, the engine starts repair tools (dism.exe, sfc, ...) through cmd.exe,
# starts PowerShell grandchildren and reads the servicing-restart signals. Here nothing is started and nothing is
# changed:
#   - Invoke-External, Invoke-PowerShellChild and Get-ServicingRebootSignals are mocked in every BeforeEach (a test
#     that checks a call replaces the mock with its own recorder); Start-BackgroundExternal and Stop-ProcessTree throw;
#   - safety nets: Start-Process, Restart-Computer, Stop-Service, Start-Service, Rename-Item, Remove-BitsTransfer,
#     Set-NetIPInterface, New-NetIPAddress, Set-DnsClientServerAddress, Optimize-Volume, Repair-Volume,
#     Repair-WindowsImage, Set-ItemProperty, New-ItemProperty and Remove-ItemProperty record their name in
#     $script:blocked, then throw; AfterEach asserts that nothing was blocked;
#   - the steps are fake functions defined here (Invoke-ToolStepFakeA, -FakeB, -FakeS);
#   - every file a test writes is under $TestDrive: the run folder $TestDrive\Root\Tool\<RunId>, the "stick"
#     $TestDrive\Stick and $TestDrive\elsewhere. The log is pointed back at nothing after every test.
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Common\Config', 'State\State', 'Steps\Winget', 'Engine\Reboot',
                 'UI\StartScreen', 'Toolbox\Strings', 'Entry\Cleanup', 'Repair\ToolEngine') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:root = Join-Path $TestDrive 'Root'
  $script:runId = '20261022-101500-test'
  $script:runDir = Join-Path $script:root "Tool\$script:runId"
  $script:sessionDir = Join-Path $TestDrive 'Stick\BenTech-Reports\PC1_SN123_2026-10-22_1015'

  # The fake steps: each records its call in $script:calls, runs $script:onCall (with its id), throws when named in
  # $script:stepThrows, and returns $script:stepResults[<id>] or 'done'.
  function Invoke-FakeStep {
    param([string]$Id, $Run)
    [void]$script:calls.Add($Id)
    if ($null -ne $script:onCall) { $null = & $script:onCall $Id }
    if ($script:stepThrows -contains $Id) { throw "fake failure in $Id" }
    if ($script:stepResults.ContainsKey($Id)) { return $script:stepResults[$Id] }
    'done'
  }
  function Invoke-ToolStepFakeA { param($Run) Invoke-FakeStep -Id 'fakeA' -Run $Run }
  function Invoke-ToolStepFakeB { param($Run) Invoke-FakeStep -Id 'fakeB' -Run $Run }
  function Invoke-ToolStepFakeS { param($Run) Invoke-FakeStep -Id 'fakeS' -Run $Run }
  function Invoke-ToolStepFakeR { param($Run) Invoke-FakeStep -Id 'fakeR' -Run $Run }

  # Registers the fake steps (fakeS is a servicing step, fakeR always runs: repair Task 7) and the fake action 'test'
  # (readonly, logs to the session).
  function Register-TestAction {
    param([string[]]$Steps, [bool]$LogLocal = $false)
    $script:ToolSteps['fakeA'] = @{ Function = 'Invoke-ToolStepFakeA'; Servicing = $false }
    $script:ToolSteps['fakeB'] = @{ Function = 'Invoke-ToolStepFakeB'; Servicing = $false }
    $script:ToolSteps['fakeS'] = @{ Function = 'Invoke-ToolStepFakeS'; Servicing = $true }
    $script:ToolSteps['fakeR'] = @{ Function = 'Invoke-ToolStepFakeR'; Servicing = $false; AlwaysRun = $true }
    $script:ToolActionCatalog['test'] = @{ Kind = 'readonly'; Confirm = 'none'; NeedsStick = $false; LogLocal = $LogLocal; Steps = [string[]]$Steps }
  }

  # A valid args hashtable for 'test', as the window writes it.
  function New-TestArgs {
    param([double]$BudgetMinutes = 600)
    @{ Version = 1; Action = 'test'; RunId = $script:runId
       DeadlineUtc = [datetime]::UtcNow.AddMinutes($BudgetMinutes).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
       BudgetSeconds = $BudgetMinutes * 60
       SessionDir = $script:sessionDir; StickRoot = (Join-Path $TestDrive 'Stick') + '\'; Complaint = ''; Done = @()
       Identity = @{ Key = 'SN-SN123'; FolderPart = 'SN123'; ComputerName = 'PC1' }; Options = @{} }
  }

  # An empty run folder (the window creates it before it starts the child).
  function Reset-TestRunDir {
    $null = New-Item -ItemType Directory -Path $script:runDir -Force
    foreach ($n in 'stop.flag', 'progress.json', 'result.json', 'args.json') {
      $p = Join-Path $script:runDir $n
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
  }

  function New-TestRun {
    param([string[]]$Steps, [double]$BudgetMinutes = 600)
    Register-TestAction -Steps $Steps
    Reset-TestRunDir
    New-ToolRun -ToolArgs (New-TestArgs -BudgetMinutes $BudgetMinutes) -Config $script:cfg -Root $script:root
  }

  # Writes args.json for 'test' (changed by -Mutate) in the run folder, or with -Outside in $TestDrive\elsewhere.
  function Write-TestArgs {
    param([scriptblock]$Mutate, [switch]$Outside)
    $a = New-TestArgs
    if ($null -ne $Mutate) { $null = & $Mutate $a }
    $dir = if ($Outside) { Join-Path $TestDrive 'elsewhere' } else { $script:runDir }
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path $dir 'args.json'
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $a -Depth 6), (New-Object Text.UTF8Encoding $false))
    $path
  }

  function Get-AllSignalsOff {
    @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $false; ComputerRenamePending = $false }
  }
}

Describe 'ToolEngine (repair Task 1)' {
  BeforeEach {
    $script:calls = New-Object System.Collections.ArrayList
    $script:onCall = $null; $script:stepThrows = @(); $script:stepResults = @{}
    $script:blocked = New-Object System.Collections.ArrayList
    Mock Invoke-External { @{ ExitCode = 0; TimedOut = $false; Output = '' } }
    Mock Invoke-PowerShellChild { @{ ExitCode = 0; TimedOut = $false; Output = '' } }
    Mock Get-ServicingRebootSignals { Get-AllSignalsOff }
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

  Describe 'the string table and Get-ToolText (findings: repair plan, Shared shapes)' {
    It 'holds the Task 1 findings, exactly in English, and in Hebrew' {
      $expected = @{
        'finding.stepFailed'     = '{0} failed: {1}'
        'finding.stepTimedOut'   = '{0} timed out after {1} min'
        'finding.stopped'        = 'Stopped after {0}'
        'finding.actionTimedOut' = 'The action reached its deadline ({0} min) and was stopped'
        'finding.restartFirst'   = 'A Windows servicing restart is pending: restart, then run it again'
        'finding.sessionLink'    = 'BenTech-Reports on the stick is a link: the files were kept in {0}'
        'finding.sessionCreateFailed' = 'The session folder on the stick could not be created ({0}): the files were kept in {1}'
        'finding.stoppedBeforeStart'  = 'Stopped before the first step'
      }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        # The Hebrew text takes the same arguments.
        ([regex]::Matches($script:ToolboxStrings.he[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',' |
          Should -Be (([regex]::Matches($expected[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',') -Because $k
      }
    }
    It 'formats the English text with invariant numbers and ASCII only' {
      Get-ToolText -Key 'finding.stepFailed' -Arguments @('DISM', 'exit 0x800F081F') | Should -BeExactly 'DISM failed: exit 0x800F081F'
      Get-ToolText -Key 'finding.stepTimedOut' -Arguments @('SFC', 62.5) | Should -BeExactly 'SFC timed out after 62.5 min'
      Get-ToolText -Key 'finding.sessionLink' -Arguments @('C:\BenTech\Setup\Logs\Repair\מחשב') | Should -BeExactly 'BenTech-Reports on the stick is a link: the files were kept in C:\BenTech\Setup\Logs\Repair\????'
      Get-ToolText -Key 'finding.restartFirst' | Should -BeExactly 'A Windows servicing restart is pending: restart, then run it again'
    }
    It 'is the key itself when the key is missing or the text cannot be formatted; never throws' {
      Get-ToolText -Key 'finding.nope' | Should -BeExactly 'finding.nope'
      Get-ToolText -Key 'finding.stepFailed' -Arguments @('only one') | Should -BeExactly 'finding.stepFailed'
    }
  }

  Describe 'Write-ToolJsonFile and Read-ToolJsonFile' {
    BeforeEach { $script:dir = Join-Path $TestDrive 'json'; $null = New-Item -ItemType Directory -Path $script:dir -Force }
    It 'writes UTF-8 without a BOM through <file>.tmp, replaces an existing file, and reads it back as a hashtable' {
      $p = Join-Path $script:dir 'a.json'
      Write-ToolJsonFile -Path $p -InputObject @{ A = 1 } | Should -BeTrue
      Write-ToolJsonFile -Path $p -InputObject ([ordered]@{ A = 2; L = @('x'); N = $null; S = @{ Deep = 'y' } }) | Should -BeTrue
      $bytes = [IO.File]::ReadAllBytes($p); $bytes[0] | Should -Not -Be 0xEF
      Test-Path -LiteralPath "$p.tmp" | Should -BeFalse
      $r = Read-ToolJsonFile -Path $p
      $r | Should -BeOfType [hashtable]; $r.A | Should -Be 2; @($r.L) | Should -Be @('x'); $r.S.Deep | Should -Be 'y'; $r.ContainsKey('N') | Should -BeTrue
    }
    It 'replaces the file while a reader holds it open with FileShare Delete (the window polls it)' {
      $p = Join-Path $script:dir 'held.json'; Write-ToolJsonFile -Path $p -InputObject @{ A = 1 } | Should -BeTrue
      $held = [IO.File]::Open($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      try { Write-ToolJsonFile -Path $p -InputObject @{ A = 2 } | Should -BeTrue } finally { $held.Dispose() }
      (Read-ToolJsonFile -Path $p).A | Should -Be 2
    }
    It 'returns $false and never throws when the folder is missing' {
      Mock Write-SetupLog { }
      Write-ToolJsonFile -Path (Join-Path $TestDrive 'no\such\folder\a.json') -InputObject @{ A = 1 } | Should -BeFalse
      Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }
    It 'reads <Why> as $null' -ForEach @(
      @{ Why = 'a missing file'; Text = $null }, @{ Why = 'an empty file'; Text = '' }, @{ Why = 'whitespace'; Text = "  `r`n" }
      @{ Why = 'text that is not JSON'; Text = '{ not json' }, @{ Why = 'an array'; Text = '[1,2]' }, @{ Why = 'a string'; Text = '"x"' }
      @{ Why = 'null'; Text = 'null' }) {
      $p = Join-Path $script:dir 'r.json'; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
      if ($null -ne $Text) { [IO.File]::WriteAllText($p, $Text) }
      Read-ToolJsonFile -Path $p | Should -BeNullOrEmpty
    }
    It 'reads a file over -MaxBytes as $null, and a file with a BOM' {
      $p = Join-Path $script:dir 'big.json'; [IO.File]::WriteAllText($p, ('{"A":"' + ('x' * 2000) + '"}'), (New-Object Text.UTF8Encoding $false))
      Read-ToolJsonFile -Path $p -MaxBytes 1000 | Should -BeNullOrEmpty
      (Read-ToolJsonFile -Path $p).A.Length | Should -Be 2000
      $b = Join-Path $script:dir 'bom.json'; [IO.File]::WriteAllText($b, '{"A":"ok"}', (New-Object Text.UTF8Encoding $true))
      (Read-ToolJsonFile -Path $b).A | Should -Be 'ok'
    }
  }

  Describe 'New-ToolRun and the run''s files (plan: The files of one run)' {
    It 'builds the run shape from the args, with every path in the run folder under Root\Tool' {
      $r = New-TestRun 'fakeA', 'fakeB'
      $r.Dir | Should -Be $script:runDir; $r.ProgressPath | Should -Be "$script:runDir\progress.json"
      $r.ResultPath | Should -Be "$script:runDir\result.json"; $r.StopPath | Should -Be "$script:runDir\stop.flag"; $r.LogDir | Should -Be $script:runDir
      $r.SessionDir | Should -BeNullOrEmpty; $r.Deadline | Should -BeOfType [datetime]; $r.Deadline.Kind | Should -Be 'Utc'
      $r.BudgetSeconds | Should -Be 36000; $r.BudgetSeconds | Should -BeOfType [double]
      $r.Clock | Should -BeOfType [Diagnostics.Stopwatch]; $r.Clock.IsRunning | Should -BeTrue
      $clock = [Diagnostics.Stopwatch]::StartNew()
      [object]::ReferenceEquals((New-ToolRun -ToolArgs (New-TestArgs) -Config $script:cfg -Root $script:root -Clock $clock).Clock, $clock) | Should -BeTrue
      @($r.Steps | ForEach-Object { '{0}|{1}|{2}' -f $_.Id, $_.Status, $_.Percent }) | Should -Be @('fakeA|pending|', 'fakeB|pending|')
      $r.Current | Should -Be -1; $r.Findings.Count | Should -Be 0; $r.Log.Count | Should -Be 0
      $r.RestartRequired | Should -BeFalse; $r.Offers.DiskCheck | Should -BeFalse; $r.Offers.ContainsKey('DismSource') | Should -BeTrue
      $r.OutputPath | Should -BeNullOrEmpty; $r.StartedAt | Should -Not -BeNullOrEmpty; $r.Args.Action | Should -Be 'test'
    }
    It 'Test-ToolStopRequested is the window''s stop.flag' {
      $r = New-TestRun 'fakeA'; Test-ToolStopRequested -Run $r | Should -BeFalse
      'x' | Set-Content -LiteralPath $r.StopPath; Test-ToolStopRequested -Run $r | Should -BeTrue
    }
  }

  Describe 'Add-ToolFinding and Add-ToolLog' {
    It 'a finding holds its level, code, English text and ASCII string arguments' {
      $r = New-TestRun 'fakeA'
      Add-ToolFinding -Run $r -Level CRIT -Code 'stepFailed' -Arguments @('DISM', 5)
      Add-ToolFinding -Run $r -Level WARN -Code 'restartFirst'
      $r.Findings.Count | Should -Be 2
      $f = $r.Findings[0]; $f.Level | Should -Be 'CRIT'; $f.Code | Should -Be 'stepFailed'; $f.Text | Should -BeExactly 'DISM failed: 5'
      @($f.Args) | Should -Be @('DISM', '5'); $f.Args[1] | Should -BeOfType [string]
      @($r.Findings[1].Args).Count | Should -Be 0
      { Add-ToolFinding -Run $r -Level 'BAD' -Code 'x' } | Should -Throw
    }
    It 'the log keeps the last 12 lines, ASCII, and writes each to the child''s log' {
      $r = New-TestRun 'fakeA'; Mock Write-SetupLog { }
      foreach ($n in 1..15) { Add-ToolLog -Run $r -Text "line $n" }
      Add-ToolLog -Run $r -Text 'שלום'
      $r.Log.Count | Should -Be 12; $r.Log[0] | Should -Be 'line 5'; $r.Log[11] | Should -Be '????'
      Should -Invoke Write-SetupLog -Times 16 -Exactly -ParameterFilter { $Level -eq 'INFO' -and $Message -notmatch '[^\x00-\x7F]' }
    }
  }

  Describe 'Get-ToolResultColor (plan: Colour)' {
    It '<Outcome> with <Levels> is <Color>' -ForEach @(
      @{ Outcome = 'Done'; Levels = @(); Color = 'GREEN' }, @{ Outcome = 'Done'; Levels = @('INFO'); Color = 'GREEN' }
      @{ Outcome = 'Done'; Levels = @('INFO', 'WARN'); Color = 'YELLOW' }, @{ Outcome = 'Stopped'; Levels = @(); Color = 'YELLOW' }
      @{ Outcome = 'NeedsRestart'; Levels = @('WARN'); Color = 'YELLOW' }, @{ Outcome = 'Done'; Levels = @('WARN', 'CRIT'); Color = 'RED' }
      @{ Outcome = 'Stopped'; Levels = @('CRIT'); Color = 'RED' }, @{ Outcome = 'TimedOut'; Levels = @(); Color = 'RED' }
      @{ Outcome = 'Failed'; Levels = @(); Color = 'RED' }, @{ Outcome = 'Whatever'; Levels = @(); Color = 'RED' }) {
      $findings = New-Object System.Collections.Generic.List[object]
      foreach ($l in $Levels) { $findings.Add(@{ Level = $l; Code = 'x' }) }
      Get-ToolResultColor -Outcome $Outcome -Findings $findings | Should -BeExactly $Color
    }
  }

  Describe 'Get-ToolStepTimeout (plan: a step''s timeout)' {
    It 'is toolStep.<name>, else toolStep.native, else 3' {
      $r = New-TestRun 'fakeA'
      Get-ToolStepTimeout -Run $r -Name 'dism' | Should -Be 150
      Get-ToolStepTimeout -Run $r -Name 'nosuchstep' | Should -Be 3
      $r.Config = [pscustomobject]@{ timeoutsMinutes = [pscustomobject]@{ toolStep = [pscustomobject]@{ native = 7 } } }
      Get-ToolStepTimeout -Run $r -Name 'dism' | Should -Be 7
      $r.Config = [pscustomobject]@{ timeoutsMinutes = [pscustomobject]@{} }
      Get-ToolStepTimeout -Run $r -Name 'dism' | Should -Be 3
      $r.Config = $null
      Get-ToolStepTimeout -Run $r -Name 'dism' | Should -Be 3
    }
    It 'is capped at the action''s remaining time minus half a minute, and is at least 0.25' {
      $t = Get-ToolStepTimeout -Run (New-TestRun 'fakeA' -BudgetMinutes 10) -Name 'dism'
      $t | Should -BeLessOrEqual 9.5; $t | Should -BeGreaterThan 9.4
      Get-ToolStepTimeout -Run (New-TestRun 'fakeA' -BudgetMinutes 0.2) -Name 'dism' | Should -Be 0.25
      # The remaining time comes from the run's Stopwatch (the Get-ToolElapsedSeconds seam), never from the wall clock.
      $r = New-TestRun 'fakeA' -BudgetMinutes 600
      Mock Get-ToolElapsedSeconds { 595 * 60 }
      Get-ToolStepTimeout -Run $r -Name 'dism' | Should -Be 4.5
      Mock Get-ToolElapsedSeconds { 601 * 60 }
      Get-ToolStepTimeout -Run $r -Name 'dism' | Should -Be 0.25
    }
    It 'a wall clock that jumps by 12 hours (the time sync) leaves every step timeout as it was (RD-R8)' {
      $r = New-TestRun 'fakeA' -BudgetMinutes 300
      $r.Deadline = $r.Deadline.AddHours(-12); $r.Args.DeadlineUtc = $r.Deadline.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
      Get-ToolStepTimeout -Run $r -Name 'dism' | Should -Be 150
    }
  }

  Describe 'Invoke-ToolSteps (spec 4.3, 5, 7)' {
    It 'runs the steps in order and writes progress at every transition' {
      $r = New-TestRun 'fakeA', 'fakeB'
      $script:seen = New-Object System.Collections.ArrayList
      $script:onCall = { $p = Read-ToolJsonFile -Path $r.ProgressPath; [void]$script:seen.Add(('{0}:{1}' -f $p.Current, (@($p.Steps.Status) -join ','))) }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:calls | Should -Be @('fakeA', 'fakeB')
      @($script:seen) | Should -Be @('0:running,pending', '1:done,running')
      $p = Read-ToolJsonFile $r.ProgressPath; @($p.Steps.Status) | Should -Be @('done', 'done'); $p.Current | Should -Be -1
      $p.Action | Should -Be 'test'; $p.RunId | Should -Be $script:runId; $p.State | Should -Be 'running'; @($p.Log).Count | Should -BeGreaterThan 0
      Should -Invoke Get-ServicingRebootSignals -Times 0 -Exactly    # no servicing step, no signal read
    }
    It 'Stop is honoured only between steps: a stop raised during a step lets it finish' {
      $r = New-TestRun 'fakeA', 'fakeB'; $script:onCall = { if ($args[0] -eq 'fakeA') { 'x' | Set-Content $r.StopPath } }
      Invoke-ToolSteps -Run $r | Should -Be 'Stopped'; $script:calls | Should -Be @('fakeA'); @($r.Steps.Status) | Should -Be @('done', 'skipped')
      $r.Findings.Code | Should -Contain 'stopped'
      ($r.Findings | Where-Object { $_.Code -eq 'stopped' }).Level | Should -Be 'INFO'
      ($r.Findings | Where-Object { $_.Code -eq 'stopped' }).Args | Should -Be @('fakeA')    # no tool.step.* names before Task 3: the id
    }
    It 'a stop requested before the first step is honoured: Stopped, and no step runs' {
      $r = New-TestRun 'fakeA', 'fakeB'; 'x' | Set-Content $r.StopPath
      Invoke-ToolSteps -Run $r | Should -Be 'Stopped'; @($script:calls).Count | Should -Be 0
      @($r.Steps.Status) | Should -Be @('skipped', 'skipped')
      $f = $r.Findings | Where-Object { $_.Code -eq 'stoppedBeforeStart' }
      $f.Level | Should -Be 'INFO'; $f.Text | Should -BeExactly 'Stopped before the first step'; @($r.Findings.Code) | Should -Not -Contain 'stopped'
      Get-ToolResultColor -Outcome 'Stopped' -Findings $r.Findings | Should -Be 'YELLOW'
      Should -Invoke Get-ServicingRebootSignals -Times 0 -Exactly
    }
    It 'a wall clock that jumps forward by 12 hours mid-run (the time sync) does not trip the deadline (RD-R8)' {
      # After the sync the wall clock is 12 h later: seen from now, the window's DeadlineUtc lies 12 h in the past.
      $r = New-TestRun 'fakeA', 'fakeB' -BudgetMinutes 300
      $script:onCall = { if ($args[0] -eq 'fakeA') {
          $r.Deadline = $r.Deadline.AddHours(-12); $r.Args.DeadlineUtc = $r.Deadline.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; $script:calls | Should -Be @('fakeA', 'fakeB'); @($r.Findings.Code) | Should -Not -Contain 'actionTimedOut'
      # No deadline in the engine reads the wall clock at all.
      [IO.File]::ReadAllText("$PSScriptRoot\..\src\Repair\ToolEngine.ps1") | Should -Not -Match 'UtcNow'
    }
    It 'the budget spent on the run''s Stopwatch ends the action at the next safe point (RD-R8)' {
      $script:fakeElapsed = 0.0
      Mock Get-ToolElapsedSeconds { $script:fakeElapsed }
      $r = New-TestRun 'fakeA', 'fakeB' -BudgetMinutes 45
      $script:onCall = { if ($args[0] -eq 'fakeA') { $script:fakeElapsed = 45 * 60 + 1 } }
      Invoke-ToolSteps -Run $r | Should -Be 'TimedOut'; $script:calls | Should -Be @('fakeA'); @($r.Steps.Status) | Should -Be @('done', 'skipped')
      $f = $r.Findings | Where-Object { $_.Code -eq 'actionTimedOut' }
      $f.Level | Should -Be 'CRIT'; $f.Text | Should -BeExactly 'The action reached its deadline (45 min) and was stopped'
      Get-ToolResultColor -Outcome 'TimedOut' -Findings $r.Findings | Should -Be 'RED'
    }
    It 'the budget is never checked before the first step' {
      Mock Get-ToolElapsedSeconds { 10 * 3600 }
      $r = New-TestRun 'fakeA' -BudgetMinutes 1
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; $script:calls | Should -Be @('fakeA')
    }
    It 'a servicing restart pending before a servicing step stops the action (yellow), checked before the first step too' {
      Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $false; CbsPackagesPending = $true; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $true; ComputerRenamePending = $false } }
      $r = New-TestRun 'fakeA', 'fakeS', 'fakeB'; Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'; $script:calls | Should -Be @('fakeA')
      @($r.Steps.Status) | Should -Be @('done', 'skipped', 'skipped')
      ($r.Findings | Where-Object { $_.Code -eq 'restartFirst' }).Level | Should -Be 'WARN'
      Get-ToolResultColor -Outcome 'NeedsRestart' -Findings $r.Findings | Should -Be 'YELLOW'
      $first = New-TestRun 'fakeS', 'fakeA'; $script:calls.Clear()
      Invoke-ToolSteps -Run $first | Should -Be 'NeedsRestart'; @($script:calls).Count | Should -Be 0; @($first.Steps.Status) | Should -Be @('skipped', 'skipped')
    }
    It 'a step that saw DISM''s own pending code (Data.DismPending) stops the action before the next servicing step, with one restartFirst (review M1)' {
      # The registry says nothing; the step adds its own restartFirst, as the dism step does: the runner adds no second one.
      $r = New-TestRun 'fakeA', 'fakeB', 'fakeS', 'fakeB'
      $script:onCall = { if ($args[0] -eq 'fakeA') { $r.Data['DismPending'] = $true; Add-ToolFinding -Run $r -Level WARN -Code 'restartFirst' } }
      Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'
      $script:calls | Should -Be @('fakeA', 'fakeB')   # a step that is not servicing still runs
      @($r.Steps.Status) | Should -Be @('done', 'done', 'skipped', 'skipped')
      @($r.Findings | Where-Object { $_.Code -eq 'restartFirst' }).Count | Should -Be 1
      # Without a finding of the step's own, the runner adds it.
      $script:calls.Clear(); $q = New-TestRun 'fakeA', 'fakeS'
      $script:onCall = { if ($args[0] -eq 'fakeA') { $q.Data['DismPending'] = $true } }
      Invoke-ToolSteps -Run $q | Should -Be 'NeedsRestart'; @($q.Findings | Where-Object { $_.Code -eq 'restartFirst' }).Count | Should -Be 1
    }
    It 'a file rename alone never blocks' {
      Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $true; ComputerRenamePending = $true } }
      Invoke-ToolSteps -Run (New-TestRun 'fakeS') | Should -Be 'Done'
      Should -Invoke Get-ServicingRebootSignals -Times 1 -Exactly
    }
    It 'a step that throws is failed with stepFailed and the next step still runs' {
      $script:stepThrows = 'fakeA'; $r = New-TestRun 'fakeA', 'fakeB'
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; @($r.Steps.Status) | Should -Be @('failed', 'done'); Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
      $f = $r.Findings | Where-Object { $_.Code -eq 'stepFailed' }; $f.Level | Should -Be 'CRIT'; $f.Text | Should -BeExactly 'fakeA failed: fake failure in fakeA'
    }
    It 'an unknown result, extra output or a step with no function is failed with stepFailed' {
      $script:stepResults = @{ fakeA = 'great'; fakeB = @('noise', 'done') }
      $script:ToolSteps['ghost'] = @{ Function = 'Invoke-ToolStepThatDoesNotExist'; Servicing = $false }
      $r = New-TestRun 'fakeA', 'fakeB'; $r.Steps.Add(@{ Id = 'ghost'; Status = 'pending'; Percent = $null }); $r.Steps.Add(@{ Id = 'unlisted'; Status = 'pending'; Percent = $null })
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      @($r.Steps.Status) | Should -Be @('failed', 'failed', 'failed', 'failed')
      @($r.Findings | Where-Object { $_.Code -eq 'stepFailed' }).Count | Should -Be 4
    }
    It 'a step''s own warn, failed and skipped results are kept; a failure with its own finding gets no generic one' {
      $script:stepResults = @{ fakeA = 'warn'; fakeB = 'skipped'; fakeS = 'failed' }
      $r = New-TestRun 'fakeA', 'fakeB', 'fakeS'
      $script:onCall = { if ($args[0] -eq 'fakeS') { Add-ToolFinding -Run $r -Level WARN -Code 'restartFirst' } }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; @($r.Steps.Status) | Should -Be @('warn', 'skipped', 'failed')
      @($r.Findings.Code) | Should -Be @('restartFirst')
    }
    It 'a step that ends failed or timedout without a finding gets a generic CRIT finding, so the result is never GREEN' {
      $script:stepResults = @{ fakeA = 'failed'; fakeB = 'timedout' }
      $script:fakeElapsed = 0.0
      Mock Get-ToolElapsedSeconds { $script:fakeElapsed }
      $r = New-TestRun 'fakeA', 'fakeB'
      $script:onCall = { if ($args[0] -eq 'fakeB') { $script:fakeElapsed += 90 * 60 } }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; @($r.Steps.Status) | Should -Be @('failed', 'timedout')
      @($r.Findings | ForEach-Object { '{0}|{1}|{2}' -f $_.Level, $_.Code, $_.Text }) | Should -Be @(
        'CRIT|stepFailed|fakeA failed: see the log', 'CRIT|stepTimedOut|fakeB timed out after 90 min')
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
    }
    It 'a step that adds only an INFO finding and then fails or times out still gets the generic CRIT finding (never GREEN)' {
      $script:stepResults = @{ fakeA = 'failed'; fakeB = 'timedout' }
      $r = New-TestRun 'fakeA', 'fakeB'
      $script:onCall = { Add-ToolFinding -Run $r -Level INFO -Code 'stopped' -Arguments @($args[0]) }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; @($r.Steps.Status) | Should -Be @('failed', 'timedout')
      @($r.Findings | ForEach-Object { '{0}|{1}' -f $_.Level, $_.Code }) | Should -Be @('INFO|stopped', 'CRIT|stepFailed', 'INFO|stopped', 'CRIT|stepTimedOut')
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
    }
    It 'a WARN finding of its own, added before the step times out, keeps the result yellow (an intentional timeout, as SFC''s)' {
      $script:stepResults = @{ fakeA = 'timedout' }
      $r = New-TestRun 'fakeA'
      $script:onCall = { Add-ToolFinding -Run $r -Level WARN -Code 'restartFirst' }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      @($r.Findings.Code) | Should -Be @('restartFirst')
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'YELLOW'
    }
    It 'a step that sets Data.Abort ends the action like a Stop: the rest skipped, the outcome Done, red by its own CRIT (repair Task 7)' {
      $script:stepResults = @{ fakeA = 'failed' }
      $r = New-TestRun 'fakeA', 'fakeB', 'fakeR', 'fakeB'
      $script:onCall = { if ($args[0] -eq 'fakeA') { $r.Data['Abort'] = $true; Add-ToolFinding -Run $r -Level CRIT -Code 'stepFailed' -Arguments @('fakeA', 'no backup') } }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:calls | Should -Be @('fakeA', 'fakeR')   # the always-run step still runs
      @($r.Steps.Status) | Should -Be @('failed', 'skipped', 'done', 'skipped')
      @($r.Findings.Code) | Should -Be @('stepFailed')
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
      # Abort is read after a step only: an Abort already set before the run ends it after its first step.
      $script:calls.Clear(); $script:onCall = $null; $script:stepResults = @{}
      $q = New-TestRun 'fakeA', 'fakeB'; $q.Data['Abort'] = $true
      Invoke-ToolSteps -Run $q | Should -Be 'Done'; $script:calls | Should -Be @('fakeA'); @($q.Steps.Status) | Should -Be @('done', 'skipped')
    }
    It 'an always-run step still runs after a Stop, and the outcome stays Stopped (repair Task 7)' {
      $r = New-TestRun 'fakeA', 'fakeB', 'fakeR'; $script:onCall = { if ($args[0] -eq 'fakeA') { 'x' | Set-Content $r.StopPath } }
      Invoke-ToolSteps -Run $r | Should -Be 'Stopped'; $script:calls | Should -Be @('fakeA', 'fakeR'); @($r.Steps.Status) | Should -Be @('done', 'skipped', 'done')
      ($r.Findings | Where-Object { $_.Code -eq 'stopped' }).Args | Should -Be @('fakeA')
      # A stop before the first step: it still runs.
      $script:calls.Clear(); $script:onCall = $null
      $q = New-TestRun 'fakeA', 'fakeR'; 'x' | Set-Content $q.StopPath
      Invoke-ToolSteps -Run $q | Should -Be 'Stopped'; $script:calls | Should -Be @('fakeR'); @($q.Steps.Status) | Should -Be @('skipped', 'done')
    }
    It 'an always-run step still runs after the deadline, its timeout at the 0.25-minute floor, and the outcome stays TimedOut' {
      $script:fakeElapsed = 0.0
      Mock Get-ToolElapsedSeconds { $script:fakeElapsed }
      $r = New-TestRun 'fakeA', 'fakeB', 'fakeR' -BudgetMinutes 30
      $script:seenTimeout = $null
      $script:onCall = { if ($args[0] -eq 'fakeA') { $script:fakeElapsed = 30 * 60 + 5 }; if ($args[0] -eq 'fakeR') { $script:seenTimeout = Get-ToolStepTimeout -Run $r -Name 'native' } }
      Invoke-ToolSteps -Run $r | Should -Be 'TimedOut'; $script:calls | Should -Be @('fakeA', 'fakeR'); @($r.Steps.Status) | Should -Be @('done', 'skipped', 'done')
      $script:seenTimeout | Should -Be 0.25
      @($r.Findings | Where-Object { $_.Code -eq 'actionTimedOut' }).Count | Should -Be 1
    }
    It 'an always-run step still runs after a pending servicing restart stopped the action (NeedsRestart)' {
      Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $true; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $false; ComputerRenamePending = $false } }
      $r = New-TestRun 'fakeA', 'fakeS', 'fakeB', 'fakeR'
      Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'; $script:calls | Should -Be @('fakeA', 'fakeR'); @($r.Steps.Status) | Should -Be @('done', 'skipped', 'skipped', 'done')
    }
    It 'in a run that nothing ends, an always-run step runs once, in its place' {
      $r = New-TestRun 'fakeR', 'fakeA', 'fakeR'
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; $script:calls | Should -Be @('fakeR', 'fakeA', 'fakeR'); @($r.Steps.Status) | Should -Be @('done', 'done', 'done')
    }
    It 'a break in a step stays inside that step' {
      $script:onCall = { if ($args[0] -eq 'fakeA') { break } }
      $r = New-TestRun 'fakeA', 'fakeB'
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; $script:calls | Should -Be @('fakeA', 'fakeB'); @($r.Steps.Status) | Should -Be @('failed', 'done')
    }
  }

  Describe 'Invoke-ToolNative' {
    It 'redirects to a file through cmd /d /s /c, with the step timeout capped by the deadline' {
      $r = New-TestRun 'fakeA' -BudgetMinutes 10
      $null = Invoke-ToolNative -Run $r -FilePath 'C:\Windows\System32\dism.exe' -ArgumentList '/Online /Cleanup-Image /RestoreHealth' -StepTimeout 'dism' -OutputName 'dism'
      Should -Invoke Invoke-External -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\System32\cmd.exe' -and $ArgumentList -like '/d /s /c ""C:\Windows\System32\dism.exe" /Online /Cleanup-Image /RestoreHealth > "*\dism-*.txt" 2>&1"' -and $TimeoutMinutes -le 9.5 -and $TimeoutMinutes -gt 9 -and -not $CaptureOutput }
    }
    It 'returns the exit code and the output file in the log folder; OutputPath is set for the tick only during the call' {
      $script:currentRun = New-TestRun 'fakeA'
      Mock Invoke-External { $script:outputDuringCall = $script:currentRun.OutputPath; @{ ExitCode = -2146498529; TimedOut = $false; Output = '' } }
      $n = Invoke-ToolNative -Run $script:currentRun -FilePath 'C:\Windows\System32\dism.exe' -ArgumentList '/Online' -StepTimeout 'dism' -OutputName 'dism'
      $n.ExitCode | Should -Be -2146498529; $n.TimedOut | Should -BeFalse
      $n.OutputPath | Should -Match ('^' + [regex]::Escape($script:runDir) + '\\dism-\d{6}\.txt$')
      $script:outputDuringCall | Should -Be $n.OutputPath; $script:currentRun.OutputPath | Should -BeNullOrEmpty
    }
    It 'without -OutputName it runs the tool itself, its output discarded, with toolStep.native' {
      $n = Invoke-ToolNative -Run (New-TestRun 'fakeA') -FilePath 'C:\Windows\System32\w32tm.exe' -ArgumentList '/resync'
      Should -Invoke Invoke-External -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\Windows\System32\w32tm.exe' -and $ArgumentList -eq '/resync' -and $TimeoutMinutes -eq 3 -and -not $CaptureOutput }
      $n.OutputPath | Should -BeNullOrEmpty; $n.ExitCode | Should -Be 0
    }
    It 'a timeout is TimedOut with no exit code' {
      Mock Invoke-External { @{ ExitCode = $null; TimedOut = $true; Output = '' } }
      $n = Invoke-ToolNative -Run (New-TestRun 'fakeA') -FilePath 'C:\Windows\System32\sfc.exe' -ArgumentList '/scannow' -StepTimeout 'sfc' -OutputName 'sfc'
      $n.TimedOut | Should -BeTrue; $n.ExitCode | Should -BeNullOrEmpty; Format-ToolExitCode -ExitCode $n.ExitCode | Should -Be 'timed out'
    }
    It 'refuses a path with cmd metacharacters' { { Invoke-ToolNative -Run (New-TestRun 'fakeA') -FilePath 'C:\x&y.exe' -OutputName 'x' } | Should -Throw }
    It 'refuses <Why>' -ForEach @(@{ Why = 'an argument with a pipe'; File = 'C:\Windows\System32\dism.exe'; Arg = '/Online | x'; Name = 'dism' }
      @{ Why = 'an argument with a percent sign'; File = 'C:\Windows\System32\dism.exe'; Arg = '%TEMP%'; Name = 'dism' }
      @{ Why = 'a quote in the path'; File = 'C:\Windows\System32\"dism.exe'; Arg = ''; Name = 'dism' }
      @{ Why = 'an output name that is not a plain name'; File = 'C:\Windows\System32\dism.exe'; Arg = ''; Name = '..\x' }) {
      { Invoke-ToolNative -Run (New-TestRun 'fakeA') -FilePath $File -ArgumentList $Arg -OutputName $Name } | Should -Throw
      Should -Invoke Invoke-External -Times 0 -Exactly
    }
    It 'formats DISM''s HRESULT exit code' {
      Format-ToolExitCode -ExitCode -2146498529 | Should -Be '0x800F081F'; Format-ToolExitCode -ExitCode $null | Should -Be 'timed out'
      Format-ToolExitCode -ExitCode 0 | Should -Be '0x00000000'; Format-ToolExitCode -ExitCode 3010 | Should -Be '0x00000BC2'
    }
  }

  Describe 'Get-ToolPercent (display only)' {
    It '<Why>' -ForEach @(@{ Why = 'the DISM bar'; F = 'dism-progress-en.txt'; E = 45.0 }, @{ Why = 'Hebrew text around the bar'; F = 'dism-progress-he.txt'; E = 62.3 }) {
      Get-ToolPercent -Text ([IO.File]::ReadAllText("$PSScriptRoot\fixtures\$F")) | Should -Be $E }
    It 'none, or above 100, is $null' { Get-ToolPercent -Text 'no number' | Should -BeNullOrEmpty; Get-ToolPercent -Text '250%' | Should -BeNullOrEmpty; Get-ToolPercent -Text '[==100.0%==]' | Should -Be 100 }
    It 'reads a comma as the decimal point, never a digit run inside a longer number, and $null for no text' {
      Get-ToolPercent -Text '[=====   7,5 %   ]' | Should -Be 7.5
      Get-ToolPercent -Text 'build 1250%' | Should -BeNullOrEmpty
      Get-ToolPercent -Text $null | Should -BeNullOrEmpty; Get-ToolPercent -Text '' | Should -BeNullOrEmpty
    }
  }

  Describe 'Update-ToolTick (the child''s tick)' {
    It 'puts the running step''s percent from the tool''s output file into the progress file' {
      $r = New-TestRun 'fakeA', 'fakeB'; $r.Current = 1; $r.Steps[1].Status = 'running'
      $out = Join-Path $r.Dir 'dism-101500.txt'; Copy-Item -LiteralPath "$PSScriptRoot\fixtures\dism-progress-en.txt" -Destination $out
      $r.OutputPath = $out
      Update-ToolTick -Run $r
      $r.Steps[1].Percent | Should -Be 45.0; $r.Steps[0].Percent | Should -BeNullOrEmpty
      (Read-ToolJsonFile $r.ProgressPath).Steps[1].Percent | Should -Be 45
    }
    It 'without an output file it only writes the progress' {
      $r = New-TestRun 'fakeA'; $r.Current = 0; $r.Steps[0].Status = 'running'
      Update-ToolTick -Run $r
      (Read-ToolJsonFile $r.ProgressPath).Steps[0].Status | Should -Be 'running'
    }
    It 'never throws' { Mock Write-SetupLog { }; { Update-ToolTick -Run @{ Current = 5; OutputPath = 'C:\nope.txt' } } | Should -Not -Throw }
  }

  Describe 'Write-ToolProgress and Write-ToolResult' {
    It 'a failed progress write never throws and is logged once per run' {
      Mock Write-SetupLog { }
      $r = New-TestRun 'fakeA'; $r.ProgressPath = Join-Path $TestDrive 'no\such\progress.json'
      { Write-ToolProgress -Run $r; Write-ToolProgress -Run $r } | Should -Not -Throw
      Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }
    It 'writes the result shape, ASCII, with the colour, the files and the end time' {
      $r = New-TestRun 'fakeA', 'fakeB'; $r.Steps[0].Status = 'done'; $r.Steps[1].Status = 'skipped'
      Add-ToolFinding -Run $r -Level INFO -Code 'stopped' -Arguments @('fakeA'); $r.Data['X'] = 1
      Write-ToolResult -Run $r -Outcome 'Stopped' | Should -BeTrue
      $res = Read-ToolJsonFile $r.ResultPath
      @($res.Keys | Sort-Object) -join ',' | Should -Be 'Action,Color,Data,EndedAt,Files,Findings,Offers,Outcome,RestartRequired,RunId,StartedAt,Steps'
      $res.Outcome | Should -Be 'Stopped'; $res.Color | Should -Be 'YELLOW'; $res.Action | Should -Be 'test'; $res.RunId | Should -Be $script:runId
      @($res.Steps.Status) | Should -Be @('done', 'skipped'); $res.Findings[0].Code | Should -Be 'stopped'; @($res.Findings[0].Args) | Should -Be @('fakeA')
      $res.RestartRequired | Should -BeFalse; $res.Offers.DiskCheck | Should -BeFalse; $res.Data.X | Should -Be 1
      $res.Files.Folder | Should -Be $script:runDir; $res.Files.Log | Should -Be "$script:runDir\setup.log"
      $res.StartedAt | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'; $res.EndedAt | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'
      [IO.File]::ReadAllText($r.ResultPath) | Should -Not -Match '[^\x00-\x7F]'
      (Read-ToolJsonFile $r.ProgressPath).State | Should -Be 'done'
    }
    It 'a result that cannot be written is $false, never a throw' {
      Mock Write-SetupLog { }
      $r = New-TestRun 'fakeA'; $r.ResultPath = Join-Path $TestDrive 'no\such\result.json'
      Write-ToolResult -Run $r -Outcome 'Done' | Should -BeFalse
      Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'ERROR' }
    }
  }

  Describe 'Invoke-ToolJsonChild' {
    It 'wraps the command, bounds it, and returns its JSON' {
      Mock Invoke-PowerShellChild { [IO.File]::WriteAllText(($Command -replace "(?s).*\`$out = '([^']+)'.*", '$1'), '{"Result":"NoErrorsFound"}'); @{ ExitCode = 0; TimedOut = $false; Output = '' } }
      $g = Invoke-ToolJsonChild -Run (New-TestRun 'fakeA') -Name 'volumeScan' -Command "@{ Result = [string](Repair-Volume -DriveLetter 'C' -Scan) }" -StepTimeout 'volumeScan'
      $g.Ok | Should -BeTrue; $g.Data.Result | Should -Be 'NoErrorsFound'; Should -Invoke Invoke-PowerShellChild -ParameterFilter { $Command -match "ErrorActionPreference = 'Stop'" -and $TimeoutMinutes -eq 60 }
    }
    It 'the grandchild evaluates & { <Command> } and writes compressed JSON (depth 6, UTF-8 without a BOM) to gc-<Name>-<n>.json in the run folder' {
      Mock Invoke-PowerShellChild { [void]$script:commands.Add($Command); @{ ExitCode = 0; TimedOut = $false; Output = '' } }
      $script:commands = New-Object System.Collections.ArrayList
      $r = New-TestRun 'fakeA'
      $null = Invoke-ToolJsonChild -Run $r -Name 'disks' -Command '@{ Items = @(Get-PhysicalDisk) } # a trailing comment'
      $c = [string]$script:commands[0]
      $c | Should -Match ([regex]::Escape(("`$out = '{0}'" -f (Join-Path $r.Dir 'gc-disks-1.json'))))
      $c | Should -Match '& \{\r?\n@\{ Items = @\(Get-PhysicalDisk\) \} # a trailing comment\r?\n\}'
      $c | Should -Match 'ConvertTo-Json -InputObject \$\w+ -Depth 6 -Compress'
      $c | Should -Match 'UTF8Encoding \$false'
      $c | Should -Match 'exit 0'; $c | Should -Match 'exit 1'
      $tokens = $null; $errors = $null; $null = [Management.Automation.Language.Parser]::ParseInput($c, [ref]$tokens, [ref]$errors); @($errors).Count | Should -Be 0
      [IO.File]::WriteAllText((Join-Path $r.Dir 'gc-disks-1.json'), '{}')
      $null = Invoke-ToolJsonChild -Run $r -Name 'disks' -Command '@{}'
      [string]$script:commands[1] | Should -Match ([regex]::Escape('gc-disks-2.json'))
    }
    It 'without -StepTimeout it uses toolStep.grandchild' {
      $null = Invoke-ToolJsonChild -Run (New-TestRun 'fakeA') -Name 'x' -Command '@{}'
      Should -Invoke Invoke-PowerShellChild -Times 1 -Exactly -ParameterFilter { $TimeoutMinutes -eq 3 }
    }
    It 'a timeout, a non-zero exit or no file is not Ok, never a throw' {
      Mock Invoke-PowerShellChild { @{ ExitCode = $null; TimedOut = $true; Output = '' } }
      $g = Invoke-ToolJsonChild -Run (New-TestRun 'fakeA') -Name 'x' -Command '@{}'; $g.Ok | Should -BeFalse; $g.TimedOut | Should -BeTrue; $g.Error | Should -Be 'timed out'
    }
    It '<Why>' -ForEach @(
      @{ Why = 'the grandchild''s own error is the Error, in ASCII'; Exit = 1; Json = '{"Error":"Access denied \u05d0"}'; Expected = 'Access denied ?' }
      @{ Why = 'a non-zero exit without a file is the exit code'; Exit = -2146498529; Json = $null; Expected = 'exit 0x800F081F' }
      @{ Why = 'exit 0 without a file is no result'; Exit = 0; Json = $null; Expected = 'no result' }
      @{ Why = 'exit 0 with an array is no result'; Exit = 0; Json = '[1,2]'; Expected = 'no result' }) {
      $script:json = $Json; $script:exit = $Exit
      Mock Invoke-PowerShellChild {
        if ($null -ne $script:json) { [IO.File]::WriteAllText(($Command -replace "(?s).*\`$out = '([^']+)'.*", '$1'), $script:json) }
        @{ ExitCode = $script:exit; TimedOut = $false; Output = '' } }
      $g = Invoke-ToolJsonChild -Run (New-TestRun 'fakeA') -Name ('n' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Command '@{}'
      $g.Ok | Should -BeFalse; $g.TimedOut | Should -BeFalse; $g.Data | Should -BeNullOrEmpty; $g.Error | Should -BeExactly $Expected
    }
    It 'a result over 1 MB is "output too large", not "no result"' {
      Mock Invoke-PowerShellChild {
        [IO.File]::WriteAllText(($Command -replace "(?s).*\`$out = '([^']+)'.*", '$1'), ('{"Items":"' + ('x' * 1MB) + '"}'))
        @{ ExitCode = 0; TimedOut = $false; Output = '' } }
      $g = Invoke-ToolJsonChild -Run (New-TestRun 'fakeA') -Name 'big' -Command '@{ Items = @(Get-WindowsDriver -Online) }'
      $g.Ok | Should -BeFalse; $g.TimedOut | Should -BeFalse; $g.Data | Should -BeNullOrEmpty; $g.Error | Should -BeExactly 'output too large'
    }
    It 'a grandchild that cannot start is not Ok, never a throw' {
      Mock Invoke-PowerShellChild { throw "Cannot start 'powershell.exe': denied" }
      $g = Invoke-ToolJsonChild -Run (New-TestRun 'fakeA') -Name 'x' -Command '@{}'
      $g.Ok | Should -BeFalse; $g.Error | Should -Match 'denied'
    }
  }

  Describe 'Read-ToolArgs and Invoke-SetupToolProcess' {
    BeforeEach {
      Register-TestAction -Steps 'fakeA', 'fakeB'
      Reset-TestRunDir
      Copy-Item -LiteralPath "$PSScriptRoot\..\config\config.json" -Destination (Join-Path $script:root 'config.json') -Force
      foreach ($d in (Join-Path $TestDrive 'Stick'), (Join-Path $script:root 'Logs')) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
      foreach ($l in "$script:root\Tool\setup.log", "$script:runDir\setup.log") { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force } }
    }
    It 'refuses <Why>' -ForEach @(@{ Why = 'an args file outside Root\Tool'; Outside = $true; Mutate = { }; Message = '*not <Root>\Tool\<run>\args.json*' }, @{ Why = 'another action than -ToolAction'; Outside = $false; Mutate = { param($a) $a.Action = 'health' }; Message = '*another action*' }
      @{ Why = 'an action not in the catalog'; Outside = $false; Mutate = { param($a) $a.Action = 'format' }; Message = '*' }, @{ Why = 'a bad RunId'; Outside = $false; Mutate = { param($a) $a.RunId = '..\x' }; Message = '*RunId*' }
      @{ Why = 'a complaint over 2000 characters'; Outside = $false; Mutate = { param($a) $a.Complaint = 'x' * 2001 }; Message = '*2000*' }
      @{ Why = 'a RunId that is not the run folder''s name'; Outside = $false; Mutate = { param($a) $a.RunId = '20261022-101501-test' }; Message = '*RunId*' }
      @{ Why = 'a deadline that is not a round-trip date'; Outside = $false; Mutate = { param($a) $a.DeadlineUtc = '22/10/2026 10:15' }; Message = '*deadline*' }
      @{ Why = 'no budget'; Outside = $false; Mutate = { param($a) $a.Remove('BudgetSeconds') }; Message = '*BudgetSeconds*' }
      @{ Why = 'a budget of 0'; Outside = $false; Mutate = { param($a) $a.BudgetSeconds = 0 }; Message = '*BudgetSeconds*' }
      @{ Why = 'a budget given as text'; Outside = $false; Mutate = { param($a) $a.BudgetSeconds = '600' }; Message = '*BudgetSeconds*' }
      @{ Why = 'a budget over 7 days'; Outside = $false; Mutate = { param($a) $a.BudgetSeconds = 604801 }; Message = '*BudgetSeconds*' }
      @{ Why = 'a SessionDir that is not fully qualified'; Outside = $false; Mutate = { param($a) $a.SessionDir = 'BenTech-Reports\x' }; Message = '*SessionDir*' }
      @{ Why = 'a complaint that is not text'; Outside = $false; Mutate = { param($a) $a.Complaint = @{ x = 1 } }; Message = '*Complaint*' }
      @{ Why = 'Options that are not an object'; Outside = $false; Mutate = { param($a) $a.Options = 'x' }; Message = '*Options*' }
      @{ Why = 'an action that is not text'; Outside = $false; Mutate = { param($a) $a.Action = 5 }; Message = '*another action*' }) {
      $p = Write-TestArgs -Mutate $Mutate -Outside:$Outside; { Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw $Message }
    It 'refuses an action that is not in the catalog even when -ToolAction names it' {
      $p = Write-TestArgs -Mutate { param($a) $a.Action = 'format'; $a.RunId = '20261022-101500-test' }
      { Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'format' } | Should -Throw '*not a tool action*'
      { Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'FORMAT' } | Should -Throw
    }
    It 'refuses a relative or empty path, a file not named args.json, a missing, empty or too big file, and JSON that is not an object' {
      $p = Write-TestArgs
      { Read-ToolArgs -Path '' -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw '*No args file*'
      { Read-ToolArgs -Path 'Root\Tool\20261022-101500-test\args.json' -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw '*fully qualified*'
      Copy-Item -LiteralPath $p -Destination (Join-Path $script:runDir 'other.json')
      { Read-ToolArgs -Path (Join-Path $script:runDir 'other.json') -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw '*not <Root>\Tool*'
      { Read-ToolArgs -Path "$TestDrive\Root\Tool\20261022-101500-test\..\20261022-101500-test\args.json" -Root "$TestDrive\Root" -ActionId 'test' } | Should -Not -Throw
      foreach ($text in '', '[1]', ('{"A":"' + ('x' * 1MB) + '"}')) {
        [IO.File]::WriteAllText($p, $text); { Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw '*args.json*' }
      Remove-Item -LiteralPath $p; { Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw '*args.json*'
    }
    It 'refuses a run folder or Tool folder that is a link' {
      $p = Write-TestArgs
      Mock Test-StickReparsePoint { $Path -like '*\Tool\20261022-101500-test' }
      { Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw '*link*'
      Mock Test-StickReparsePoint { $Path -like '*\Root\Tool' }
      { Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw '*link*'
    }
    It 'returns the args as a hashtable; a missing complaint, session folder or options is empty' {
      $p = Write-TestArgs -Mutate { param($a) $a.Remove('Complaint'); $a.Remove('Options'); $a.Remove('SessionDir') }
      $a = Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'test'
      $a | Should -BeOfType [hashtable]; $a.Action | Should -BeExactly 'test'; $a.RunId | Should -Be $script:runId
      $a.Complaint | Should -BeExactly ''; $a.SessionDir | Should -BeExactly ''; $a.Options | Should -BeOfType [hashtable]; $a.Identity.FolderPart | Should -Be 'SN123'
    }
    It 'runs the steps, writes the result and returns 0; Hebrew in the complaint never reaches the log' {
      $argsPath = Write-TestArgs -Mutate { param($a) $a.Complaint = 'המחשב איטי' }
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath $argsPath | Should -Be 0
      $res = Read-ToolJsonFile "$script:runDir\result.json"
      $res.Outcome | Should -Be 'Done'; $res.Color | Should -Be 'GREEN'; @($res.Steps.Status) | Should -Be @('done', 'done'); $script:calls | Should -Be @('fakeA', 'fakeB')
      $res.Files.Folder | Should -Be $script:sessionDir; $res.Files.Log | Should -Be "$script:sessionDir\logs\setup.log"; $res.Data.SessionIsLocal | Should -BeFalse
      Test-Path -LiteralPath "$script:sessionDir\logs\setup.log" | Should -BeTrue
      [IO.File]::ReadAllText("$script:sessionDir\logs\setup.log") | Should -Match 'Tool action started'
      Get-ChildItem "$TestDrive\Root", "$TestDrive\Stick" -Recurse -Filter setup.log | ForEach-Object { [IO.File]::ReadAllText($_.FullName) | Should -Not -Match '[^\x00-\x7F]' }
      [IO.File]::ReadAllText("$script:runDir\result.json") | Should -Not -Match '[^\x00-\x7F]'
      [IO.File]::ReadAllText("$script:runDir\progress.json") | Should -Not -Match '[^\x00-\x7F]'
    }
    It 'invalid args: 1, an ERROR line, no step and no result' {
      $null = Write-TestArgs -Outside
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath "$TestDrive\elsewhere\args.json" | Should -Be 1; $script:calls | Should -BeNullOrEmpty
      Test-Path -LiteralPath "$script:runDir\result.json" | Should -BeFalse; Test-Path -LiteralPath "$script:runDir\progress.json" | Should -BeFalse
      [IO.File]::ReadAllText("$script:root\Tool\setup.log") | Should -Match '\[ERROR\] Tool action refused'
      Test-Path -LiteralPath (Join-Path $TestDrive 'Stick') | Should -BeFalse
      Test-Path -LiteralPath (Join-Path $TestDrive 'elsewhere\setup.log') | Should -BeFalse
    }
    It 'a missing Root creates nothing and returns 1' {
      Invoke-SetupToolProcess -Root "$TestDrive\NoRoot" -ActionId 'test' -ArgsPath "$TestDrive\NoRoot\Tool\x\args.json" | Should -Be 1
      Test-Path -LiteralPath "$TestDrive\NoRoot" | Should -BeFalse
    }
    It 'a session folder that is a link on the stick is not written through: local folder and sessionLink' {
      Mock Test-StickReparsePoint { $Path -like '*BenTech-Reports*' }
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath (Write-TestArgs) | Should -Be 0
      $res = Read-ToolJsonFile "$runDir\result.json"
      $res.Findings.Code | Should -Contain 'sessionLink'; $res.Findings.Code | Should -Not -Contain 'sessionCreateFailed'; $res.Color | Should -Be 'YELLOW'
      $local = Join-Path $script:root 'Logs\Repair\PC1_SN123_2026-10-22_1015'
      $res.Files.Folder | Should -Be $local; $res.Data.SessionIsLocal | Should -BeTrue
      ($res.Findings | Where-Object { $_.Code -eq 'sessionLink' }).Text | Should -BeExactly "BenTech-Reports on the stick is a link: the files were kept in $local"
      Test-Path -LiteralPath "$local\logs\setup.log" | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $TestDrive 'Stick') | Should -BeFalse
    }
    It 'a session folder that cannot be created on the stick falls back to the local folder' {
      $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:sessionDir) -Force
      [IO.File]::WriteAllText($script:sessionDir, 'a file where the folder should be')
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath (Write-TestArgs) | Should -Be 0
      $res = Read-ToolJsonFile "$runDir\result.json"
      $local = Join-Path $script:root 'Logs\Repair\PC1_SN123_2026-10-22_1015'
      $res.Findings.Code | Should -Not -Contain 'sessionLink'; $res.Files.Folder | Should -Be $local; $res.Data.SessionIsLocal | Should -BeTrue
      $f = $res.Findings | Where-Object { $_.Code -eq 'sessionCreateFailed' }
      $f.Level | Should -Be 'WARN'; @($f.Args).Count | Should -Be 2; $f.Args[0] | Should -Not -BeNullOrEmpty; $f.Args[1] | Should -Be $local
      $f.Text | Should -BeExactly ('The session folder on the stick could not be created ({0}): the files were kept in {1}' -f $f.Args[0], $local)
    }
    It 'a LogLocal action logs in the run folder and leaves nothing on the stick' {
      Register-TestAction -Steps 'fakeA' -LogLocal $true
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath (Write-TestArgs) | Should -Be 0
      Test-Path -LiteralPath "$script:runDir\setup.log" | Should -BeTrue; Test-Path -LiteralPath (Join-Path $TestDrive 'Stick') | Should -BeFalse
      (Read-ToolJsonFile "$runDir\result.json").Files.Folder | Should -Be $script:runDir
    }
    It 'a stop, a deadline or a pending servicing restart is written as the outcome' {
      Register-TestAction -Steps 'fakeA', 'fakeS'
      Mock Get-ServicingRebootSignals { $s = Get-AllSignalsOff; $s.WuRebootRequired = $true; $s }
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath (Write-TestArgs) | Should -Be 0
      $res = Read-ToolJsonFile "$runDir\result.json"; $res.Outcome | Should -Be 'NeedsRestart'; $res.Color | Should -Be 'YELLOW'; @($res.Steps.Status) | Should -Be @('done', 'skipped')
    }
    It 'an unreadable config.json is 1 with an ERROR, and no step runs' {
      [IO.File]::WriteAllText((Join-Path $script:root 'config.json'), '{ not json')
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath (Write-TestArgs) | Should -Be 1
      $script:calls | Should -BeNullOrEmpty
      [IO.File]::ReadAllText("$script:runDir\setup.log") | Should -Match '\[ERROR\] Tool action failed'    # the args were valid: the log is in the run folder
      Test-Path -LiteralPath "$script:runDir\result.json" | Should -BeFalse
    }
    It 'registers the tick for the run and unregisters it at the end' {
      Mock Register-SetupTick { $script:tickContext = $Context; $script:tickHandler = $Handler }
      Mock Unregister-SetupTick { }
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath (Write-TestArgs) | Should -Be 0
      Should -Invoke Register-SetupTick -Times 1 -Exactly; Should -Invoke Unregister-SetupTick -Times 1 -Exactly
      $script:tickContext.Args.RunId | Should -Be $script:runId; $script:tickContext.ProgressPath | Should -Be "$script:runDir\progress.json"
      # The child's Stopwatch started when it began, and its budget came from the args (RD-R8).
      $script:tickContext.Clock | Should -BeOfType [Diagnostics.Stopwatch]; $script:tickContext.Clock.IsRunning | Should -BeTrue
      $script:tickContext.BudgetSeconds | Should -Be 36000
      [string]$script:tickHandler | Should -Match 'Update-ToolTick'
    }
  }

  # Repair Task 4: the findings the window adds itself, and Restart PC's stateless restart (Reboot.ps1, spec 6.9).
  Describe 'the window''s findings (repair Task 4)' {
    It 'holds childNoResult and childStartFailed, exactly in English, and in Hebrew with the same arguments' {
      $expected = @{ 'finding.childNoResult' = 'The action ended without a result (exit {0})'; 'finding.childStartFailed' = 'The action could not start: {0}' }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '\{0\}' -Because $k
      }
    }
  }

  Describe 'Invoke-StatelessRestart (Restart PC, spec 6.9)' {
    BeforeEach { $script:hosts = New-Object System.Collections.ArrayList; Mock Write-Host { [void]$script:hosts.Add(@{ Text = "$Object"; Fore = "$ForegroundColor"; Back = "$BackgroundColor" }) } }
    It 'restarts with Restart-Computer -Force: no state, no countdown, no fallback' {
      $script:restarts = New-Object System.Collections.ArrayList
      Mock Restart-Computer { [void]$script:restarts.Add([bool]$Force) }   # replaces the safety net with a recorder: nothing restarts
      Invoke-StatelessRestart | Should -BeTrue
      @($script:restarts) | Should -Be @($true); Should -Invoke Invoke-External -Times 0 -Exactly; $script:hosts.Count | Should -Be 0
    }
    It 'Invoke-StatelessRestart falls back to shutdown.exe /r /t 5 /f and accepts 1190' {
      foreach ($code in 0, 1115, 1190) {
        Mock Invoke-External { @{ ExitCode = $script:code; TimedOut = $false; Output = '' } }; $script:code = $code
        Invoke-StatelessRestart -RestartAction { throw 'Restart-Computer failed' } | Should -BeTrue -Because "exit $code"
      }
      Should -Invoke Invoke-External -Times 3 -Exactly   # one fallback per case, nothing else
      Should -Invoke Invoke-External -Times 3 -Exactly -ParameterFilter { $FilePath -eq "$env:windir\System32\shutdown.exe" -and $ArgumentList -eq '/r /t 5 /f' -and $TimeoutMinutes -eq 1 }
      $script:hosts.Count | Should -Be 0
    }
    It 'both failing is $false and one White on DarkRed line' {
      foreach ($fallback in @{ ExitCode = 5; TimedOut = $false; Output = '' }, @{ ExitCode = $null; TimedOut = $true; Output = '' }) {
        $script:hosts.Clear(); $script:fallback = $fallback; Mock Invoke-External { $script:fallback }
        Invoke-StatelessRestart -RestartAction { throw ('no restart ' + [char]0x05D0) } | Should -BeFalse
        $script:hosts.Count | Should -Be 1; $script:hosts[0].Fore | Should -Be 'White'; $script:hosts[0].Back | Should -Be 'DarkRed'
        $script:hosts[0].Text | Should -BeLike 'Could not restart the PC: *'; $script:hosts[0].Text | Should -Not -Match '[^\x00-\x7F]'
      }
    }
    It 'never throws: a fallback that cannot start is $false too' {
      Mock Invoke-External { throw "Cannot start 'shutdown.exe'" }
      { Invoke-StatelessRestart -RestartAction { throw 'no' } } | Should -Not -Throw
      Invoke-StatelessRestart -RestartAction { throw 'no' } | Should -BeFalse
      Invoke-StatelessRestart -RestartAction { throw 'no' } -FallbackRestartAction { throw 'neither' } | Should -BeFalse
    }
  }
}
