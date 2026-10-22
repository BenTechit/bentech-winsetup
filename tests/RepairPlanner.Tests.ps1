# tests/RepairPlanner.Tests.ps1
# Repair Task 3: the repair page's pure model (repair spec 4, 5; repair plan "The repair model" and "Safety strip,
# chips and gates"): New-RepairModel, ConvertTo-RepairStrip, Get-RepairGate, Get-RepairChips, Test-RepairYes,
# Test-RepairConfirmReady and Format-RepairElapsed. RepairPlanner.ps1 is pure (no logging, no I/O, no window), so
# nothing here needs a mock: it only reads config.json and the catalogs.
BeforeAll {
  foreach ($f in 'Common\Config', 'Engine\Catalog', 'UI\StartScreen', 'Detect\PcName', 'Repair\ToolEngine', 'Toolbox\Strings', 'Toolbox\SetupPlanner',
                 'Toolbox\RepairPlanner') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  # The Dell sample machine of tools\Preview-Toolbox.ps1.
  $script:m = @{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; FriendlyModel = 'Latitude 5440'; Serial = '7HX2K93'; NewName = 'DELL-7HX2K93'
                 Brand = 'DELL'; IsLaptop = $true; IsVM = $false; OsBuild = 26200; ComputerName = 'DESKTOP-4F7K2LQ' }
  . "$PSScriptRoot\fixtures\RepairSamples.ps1"
}

Describe 'New-RepairModel (repair plan, The repair model)' {
  It 'opens loading, with the catalog''s ids, the machine''s type, no stick and nothing selected' {
    $r = New-RepairModel -Machine $m -SessionStamp '2026-10-22_1015'
    $r.Strip.State | Should -Be 'loading'; foreach ($c in 'Restart', 'Free', 'BitLocker', 'Internet', 'Disk') { $r.Strip[$c] | Should -BeNullOrEmpty -Because $c }
    @($r.Available) | Should -Contain 'health'; @($r.Available) | Should -Contain 'safety'; @($r.Available) | Should -Not -Contain 'ghosts'
    $r.CanRun | Should -BeFalse; $r.IsLaptop | Should -BeTrue; $r.SessionStamp | Should -Be '2026-10-22_1015'
    $r.Stick.Root | Should -BeNullOrEmpty; $r.Selected | Should -BeExactly ''; $r.Complaint | Should -BeExactly ''; $r.BackedUp | Should -BeFalse
    foreach ($k in 'Confirm', 'Run', 'Result', 'Pending', 'NetBackup') { $r[$k] | Should -BeNullOrEmpty -Because $k }
    (New-RepairModel -Machine @{ IsLaptop = $false } -SessionStamp 'x' -CanRun $true).CanRun | Should -BeTrue }
  It 'a tile is available when every action it starts is in the catalog (Ghost devices, Network reset)' {
    @(Get-RepairAvailable -Catalog ([ordered]@{ health = @{}; ghostList = @{}; ghostRemove = @{}; netInfo = @{}; netReset = @{} })) | Should -Be @('health', 'ghostList', 'ghostRemove', 'netInfo', 'netReset', 'ghosts')
    @(Get-RepairAvailable -Catalog $null).Count | Should -Be 0 }
  It 'a tile whose own id is a catalog id still needs every action it starts: no Network reset without netInfo (review M1)' {
    $a = @(Get-RepairAvailable -Catalog ([ordered]@{ health = @{}; netReset = @{}; ghostList = @{} }))
    $a | Should -Be @('health', 'ghostList'); $a | Should -Not -Contain 'netReset'; $a | Should -Not -Contain 'ghosts'
    @(Get-RepairAvailable -Catalog ([ordered]@{ netReset = @{}; netInfo = @{} }) | Where-Object { $_ -ceq 'netReset' }).Count | Should -Be 1 }
}

Describe 'Get-RepairGate (spec 5, 6.6, 6.7, 8)' {
  It '<A> is <E> (<Why>)' -ForEach @(
    @{ Why = 'restart pending blocks DISM and SFC';        Set = @{ Restart = 'crit' };                 A = 'standard';  E = 'reason.restart' }
    @{ Why = 'restart pending blocks the WU reset';         Set = @{ Restart = 'crit' };                 A = 'wuReset';   E = 'reason.restart' }
    @{ Why = 'read-only actions still run';                 Set = @{ Restart = 'crit' };                 A = 'health';    E = '' }
    @{ Why = 'Network reset still runs';                     Set = @{ Restart = 'crit' };                 A = 'netReset';  E = '' }
    @{ Why = 'a laptop on battery';                          Set = @{ OnAC = $false };                    A = 'postClone'; E = 'reason.battery' }
    @{ Why = 'a desktop on "battery" is no laptop';          Set = @{ OnAC = $false; IsLaptop = $false }; A = 'standard';  E = '' }
    @{ Why = 'a failing disk until backed up';               Set = @{ Disk = 'crit' };                    A = 'diskCheck'; E = 'reason.diskFailing' }
    @{ Why = 'backed up unlocks it';                         Set = @{ Disk = 'crit'; BackedUp = $true };  A = 'standard';  E = '' }
    @{ Why = 'unknown chips block nothing';                  Set = @{ Restart = 'unknown'; Disk = 'unknown' }; A = 'standard'; E = '' }
    @{ Why = 'strip still loading holds the repairs';        Set = @{ State = 'loading' };                A = 'standard';  E = 'reason.checking' }
    @{ Why = 'no stick: reports';                             Set = @{ Stick = $null };                    A = 'fullReport'; E = 'reason.noStickReport' }
    @{ Why = 'an action running';                             Set = @{ Running = $true };                  A = 'health';    E = 'reason.running' }
    @{ Why = 'not in this version';                           Set = @{ Available = @('health') };          A = 'ghosts';    E = 'reason.unavailable' }
    @{ Why = 'compare without an earlier report';             Set = @{};                                   A = 'compare';   E = 'reason.noEarlier' }
  ) { $g = Get-RepairGate -Model (New-TestModel $Set) -ActionId $A; $g.Reason | Should -BeExactly $E; $g.Enabled | Should -Be ($E -eq '') }
  It 'low space and an internet outage only warn' { (Get-RepairGate -Model (New-TestModel @{ Free = 'crit'; Internet = 'crit' }) -ActionId 'standard').Warns | Should -Contain 'warn.lowSpace'
    (Get-RepairGate -Model (New-TestModel @{ Internet = 'crit' }) -ActionId 'wuReset').Warns | Should -Contain 'warn.noRescan' }
  It 'there is no Cancel scheduled disk check action (RD-R1)' { $script:ToolActionCatalog.Keys | Should -Not -Contain 'diskCheckCancel' }
  It 'more rules of the table: no stick, no script, a ticked failing disk, the loading strip' {
    $g = Get-RepairGate -Model (New-TestModel @{ Stick = $null }) -ActionId 'netReset'; $g.Reason | Should -BeExactly 'reason.noStickBackup'
    (Get-RepairGate -Model (New-TestModel @{ Stick = $null }) -ActionId 'ghosts').Reason | Should -BeExactly 'reason.noStickBackup'
    (Get-RepairGate -Model (New-TestModel @{ Stick = $null }) -ActionId 'compare').Reason | Should -BeExactly 'reason.noStickReport'
    $h = Get-RepairGate -Model (New-TestModel @{ Stick = $null }) -ActionId 'health'; $h.Enabled | Should -BeTrue; @($h.Warns) | Should -Be @('confirm.noStickLog')
    (Get-RepairGate -Model (New-TestModel @{ CanRun = $false }) -ActionId 'health').Reason | Should -BeExactly 'reason.noScript'
    @((Get-RepairGate -Model (New-TestModel @{ Disk = 'crit'; BackedUp = $true }) -ActionId 'postClone').Warns) | Should -Be @('warn.diskFailing')
    (Get-RepairGate -Model (New-TestModel @{ State = 'loading' }) -ActionId 'health').Enabled | Should -BeTrue      # read-only actions never wait for the strip
    (Get-RepairGate -Model (New-TestModel @{ State = 'loading' }) -ActionId 'netReset').Enabled | Should -BeTrue
    (Get-RepairGate -Model (New-TestModel @{ HasEarlierReport = $true }) -ActionId 'compare').Enabled | Should -BeTrue }
  It 'Restart PC is refused only while an action runs; Restore network settings shows only with a saved backup' {
    (Get-RepairGate -Model (New-TestModel @{ CanRun = $false; Available = @() }) -ActionId 'restart').Enabled | Should -BeTrue
    (Get-RepairGate -Model (New-TestModel @{ Running = $true }) -ActionId 'restart').Reason | Should -BeExactly 'reason.running'
    $hidden = Get-RepairGate -Model (New-TestModel @{}) -ActionId 'netRestore'; $hidden.Visible | Should -BeFalse; $hidden.Enabled | Should -BeFalse
    $backup = @{ Path = 'E:\BenTech-Reports\x\network.json'; Sha256 = 'AB'; CreatedAt = '2026-10-20T09:05:00'; Adapters = 1 }
    (Get-RepairGate -Model (New-TestModel @{ NetBackup = $backup }) -ActionId 'netRestore').Enabled | Should -BeTrue
    $nostick = Get-RepairGate -Model (New-TestModel @{ NetBackup = $backup; Stick = $null }) -ActionId 'netRestore'; $nostick.Visible | Should -BeTrue; $nostick.Reason | Should -BeExactly 'reason.noStickBackup' }
}

Describe 'ConvertTo-RepairStrip' {
  It 'keeps the chips it has and, at the end, makes the missing ones unknown' { $s = ConvertTo-RepairStrip -Chips @{ Restart = @{ Level = 'ok' } } -Final $true
    $s.State | Should -Be 'ready'; $s.Disk.Level | Should -Be 'unknown'; $s.Restart.Level | Should -Be 'ok' }
  It 'a partial result keeps loading; a level it does not know is unknown; the arguments stay strings' {
    $s = ConvertTo-RepairStrip -Chips @{ Free = @{ Level = 'crit'; Args = @('C:', 4) }; Disk = @{ Level = 'fine' } }
    $s.State | Should -Be 'loading'; $s.Restart | Should -BeNullOrEmpty; $s.Free.Level | Should -Be 'crit'; @($s.Free.Args) | Should -Be @('C:', '4')
    $s.Disk.Level | Should -Be 'unknown'
    $j = ConvertTo-RepairStrip -Chips ('{"Internet":{"Level":"warn","Args":[],"Detail":{"Probe":"different"}}}' | ConvertFrom-Json)   # as a JSON reader may give it
    $j.Internet.Level | Should -Be 'warn'; (ConvertTo-RepairStrip -Chips $null -Final $true).Restart.Level | Should -Be 'unknown' }
}

Describe 'Get-RepairChips (spec 5: the strip as the window shows it)' {
  It 'while loading the five read chips say Checking...; power and stick are the window''s and show at once' {
    $c = Get-RepairChips -Model (New-TestModel @{ State = 'loading'; Restart = $null; Free = $null; BitLocker = $null; Internet = $null; Disk = $null })
    @($c.Name) | Should -Be @('Restart', 'Free', 'BitLocker', 'Internet', 'Disk', 'Power', 'Stick')
    foreach ($x in @($c)[0..4]) { $x.Level | Should -Be 'loading'; $x.TextKey | Should -Be 'chip.loading' }
    ($c | Where-Object Name -eq 'Power').TextKey | Should -Be 'chip.power.ac'; ($c | Where-Object Name -eq 'Stick').Level | Should -Be 'ok' }
  It '<Name> <Level> reads <Key>' -ForEach @(
    @{ Name = 'Restart'; Set = @{ Restart = 'crit' }; Level = 'crit'; Key = 'chip.restart.crit'; Tip = 'tip.restart.crit' }
    @{ Name = 'Free'; Set = @{ Free = 'crit' }; Level = 'crit'; Key = 'chip.free.level'; Tip = 'tip.free.crit' }
    @{ Name = 'BitLocker'; Set = @{ BitLocker = 'warn' }; Level = 'warn'; Key = 'chip.bitlocker.warn'; Tip = 'tip.bitlocker.warn' }
    @{ Name = 'Internet'; Set = @{ Internet = 'warn' }; Level = 'warn'; Key = 'chip.internet.warn'; Tip = 'tip.internet.warn' }
    @{ Name = 'Internet'; Set = @{ Internet = 'crit' }; Level = 'crit'; Key = 'chip.internet.crit'; Tip = 'tip.internet.crit' }
    @{ Name = 'Disk'; Set = @{ Disk = 'warn' }; Level = 'warn'; Key = 'chip.disk.warn'; Tip = 'tip.disk.warn' }
    @{ Name = 'Disk'; Set = @{ Disk = 'unknown' }; Level = 'unknown'; Key = 'chip.disk.unknown'; Tip = 'tip.unknown' }
    @{ Name = 'Power'; Set = @{ OnAC = $false }; Level = 'crit'; Key = 'chip.power.battery'; Tip = 'tip.power.battery' }
    @{ Name = 'Stick'; Set = @{ Stick = $null }; Level = 'crit'; Key = 'chip.stick.none'; Tip = 'tip.stick.none' }
  ) { $c = Get-RepairChips -Model (New-TestModel $Set) | Where-Object Name -eq $Name
    $c.Level | Should -Be $Level; $c.TextKey | Should -Be $Key; @($c.Tips) | Should -Contain $Tip }
  It 'the free chip and the stick chip carry their values; a pending rename is a note on a green chip; power is for laptops only' {
    $c = @(Get-RepairChips -Model (New-TestModel @{}))
    @(($c | Where-Object Name -eq 'Free').Args) | Should -Be @('C:', '41', 'C'); @(($c | Where-Object Name -eq 'Stick').Args) | Should -Be @('E:', 'E')   # the letter alone for Hebrew (RD-R14)
    $n = New-TestModel @{}; $n.Repair.Strip.Restart = @{ Level = 'ok'; Args = @(); Detail = @{ Signals = @(); Notes = @('PendingFileRename') } }
    $r = Get-RepairChips -Model $n | Where-Object Name -eq 'Restart'; $r.Level | Should -Be 'ok'; @($r.Tips) | Should -Be @('tip.restart.note')
    (Get-RepairChips -Model (New-TestModel @{ IsLaptop = $false }) | Where-Object Name -eq 'Power').Visible | Should -BeFalse
    (@($c | Where-Object { $_.Name -ne 'Power' -and $_.Level -eq 'ok' }) | ForEach-Object { @($_.Tips).Count } | Measure-Object -Sum).Sum | Should -Be 0 }
}

Describe 'Test-RepairYes and Test-RepairConfirmReady (spec 4.2, RD-R2)' {
  It '<T> is <E>' -ForEach @(@{ T = 'YES'; E = $true }, @{ T = 'yes'; E = $true }, @{ T = ' yEs '; E = $true }, @{ T = ([string][char]0x05D8 + [char]0x05E7 + [char]0x05D3); E = $true }
    @{ T = 'YE'; E = $false }, @{ T = 'YESS'; E = $false }, @{ T = 'Y E S'; E = $false }, @{ T = ''; E = $false }, @{ T = $null; E = $false }) { Test-RepairYes -Text $T | Should -Be $E }
  It 'a YES confirmation needs YES; Network reset also needs the at-PC tick, RDP or not; a loading one never confirms' {
    $c = $script:confirmSample.Clone(); $m1 = New-TestModel @{ Confirm = $c }
    Test-RepairConfirmReady -Model $m1 | Should -BeFalse
    $c.Typed = 'yes'; Test-RepairConfirmReady -Model $m1 | Should -BeFalse          # RD-R2: no RDP, still the tick
    $c.AtPc = $true; Test-RepairConfirmReady -Model $m1 | Should -BeTrue
    $c.Loading = $true; Test-RepairConfirmReady -Model $m1 | Should -BeFalse }
  It 'a repair confirms at once; a gate that closed refuses; ghosts need one ticked device' {
    $std = @{ Action = 'standard'; Kind = 'confirm'; Typed = ''; AtPc = $false; Loading = $false; Lines = @(@{ Key = 'tile.standard.changes' }); Remote = $null; Items = @(); Options = @{} }
    Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $std }) | Should -BeTrue
    Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $std; Restart = 'crit' }) | Should -BeFalse
    $g = @{ Action = 'ghosts'; Kind = 'yes'; Typed = 'YES'; AtPc = $false; Loading = $false; Lines = @(); Remote = $null; Options = @{}
            Items = @(@{ InstanceId = 'USB\VID_0781&PID_5567\4C53'; Class = 'USB'; Name = 'SanDisk'; Ticked = $false }) }
    Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $g }) | Should -BeFalse
    $g.Items[0].Ticked = $true; Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $g }) | Should -BeTrue
    $restart = @{ Action = 'restart'; Kind = 'restart'; Typed = ''; AtPc = $false; Loading = $false; Lines = @(); Remote = $null; Items = @(); Options = @{} }
    Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $restart; CanRun = $false }) | Should -BeTrue
    Test-RepairConfirmReady -Model (New-TestModel @{}) | Should -BeFalse }
}

Describe 'Format-RepairElapsed' {
  It '<S> seconds is <E>' -ForEach @(@{ S = 0; E = '0:00' }, @{ S = 754; E = '12:34' }, @{ S = 3725; E = '1:02:05' }, @{ S = -5; E = '0:00' }) { Format-RepairElapsed -Seconds $S | Should -BeExactly $E }
}

Describe 'the run in the model (repair Task 4: New-RepairRunModel, Update-RepairRunModel, Complete-RepairRunModel, New-RepairWindowResult)' {
  BeforeAll {
    # Health check's progress as the child writes it (read back as hashtables): the disk state done, the image check at 30%.
    function New-HealthProgress([string]$RunId = '20261022-101500-health', [string]$Action = 'health') {
      @{ Action = $Action; RunId = $RunId; State = 'running'; Current = 1; Partial = @{}; UpdatedAt = '2026-10-22T10:16:00'
         Steps = @(@{ Id = 'volumeState'; Status = 'done'; Percent = $null }, @{ Id = 'imageCheck'; Status = 'running'; Percent = 30 }, @{ Id = 'imageScan'; Status = 'pending'; Percent = $null })
         Log = @(foreach ($i in 1..14) { "line $i" }) }
    }
  }
  It 'the toolbox model hands CanRun and the visit''s stamp to the page (stamped now by default)' {
    $mo = New-ToolboxModel -Machine $m -Config $cfg -Previous $null -IsFresh $true -OnAC $true -AdminProtection 'Off' -CanRun $true -SessionStamp '2026-10-22_1015'
    $mo.Repair.CanRun | Should -BeTrue; $mo.Repair.SessionStamp | Should -BeExactly '2026-10-22_1015'
    $d = (New-ToolboxModel -Machine $m -Config $cfg -Previous $null -IsFresh $true -OnAC $true -AdminProtection 'Off').Repair
    $d.CanRun | Should -BeFalse; $d.SessionStamp | Should -Match '^\d{4}-\d{2}-\d{2}_\d{4}$' }
  It 'a new run lists every step of the catalog''s action as pending, with no percent, no log and no refused close' {
    $r = New-TestModel @{ CloseRefused = $true }; $n = New-RepairRunModel -Repair $r.Repair -ActionId 'health' -RunId '20261022-101500-health'
    $n.Run.Action | Should -BeExactly 'health'; $n.Run.RunId | Should -BeExactly '20261022-101500-health'
    @($n.Run.Steps.Id) | Should -Be @($script:ToolActionCatalog['health'].Steps); @($n.Run.Steps.Status | Select-Object -Unique) | Should -Be @('pending')
    $n.Run.Current | Should -Be -1; $n.Run.Percent | Should -BeNullOrEmpty; @($n.Run.Log).Count | Should -Be 0; $n.Run.ElapsedSeconds | Should -Be 0; $n.Run.Stopping | Should -BeFalse
    $n.CloseRefused | Should -BeFalse; $r.Repair.Run | Should -BeNullOrEmpty; $r.Repair.CloseRefused | Should -BeTrue   # the input is not changed
    (Get-RepairGate -Model @{ Repair = $n; OnAC = $true } -ActionId 'standard').Reason | Should -BeExactly 'reason.running' }
  It 'progress fills the steps, the current step, its percent, the log and the elapsed time; Stop pressed stays pressed' {
    $r = (New-TestModel @{}).Repair; $r = New-RepairRunModel -Repair $r -ActionId 'health' -RunId '20261022-101500-health'; $r.Run.Stopping = $true
    $n = Update-RepairRunModel -Repair $r -Progress (New-HealthProgress) -ElapsedSeconds 75
    @($n.Run.Steps.Status) | Should -Be @('done', 'running', 'pending'); $n.Run.Current | Should -Be 1; $n.Run.Percent | Should -Be 30
    @($n.Run.Log).Count | Should -Be 12; @($n.Run.Log)[-1] | Should -BeExactly 'line 14'; $n.Run.ElapsedSeconds | Should -Be 75; $n.Run.Stopping | Should -BeTrue
    $r.Run.ElapsedSeconds | Should -Be 0   # a copy
    # Read from JSON as objects, it is the same.
    $j = Update-RepairRunModel -Repair $r -Progress ((New-HealthProgress) | ConvertTo-Json -Depth 5 | ConvertFrom-Json) -ElapsedSeconds 76
    @($j.Run.Steps.Status) | Should -Be @('done', 'running', 'pending'); $j.Run.Percent | Should -Be 30 }
  It 'no progress yet moves only the clock; another run''s progress or an unknown status changes no step' {
    $r = New-RepairRunModel -Repair (New-TestModel @{}).Repair -ActionId 'health' -RunId '20261022-101500-health'
    $n = Update-RepairRunModel -Repair $r -Progress $null -ElapsedSeconds 3; $n.Run.ElapsedSeconds | Should -Be 3; @($n.Run.Steps).Count | Should -Be 7
    (Update-RepairRunModel -Repair $r -Progress (New-HealthProgress -RunId '20261022-101400-health') -ElapsedSeconds 4).Run.Current | Should -Be -1
    (Update-RepairRunModel -Repair $r -Progress (New-HealthProgress -Action 'standard') -ElapsedSeconds 4).Run.Current | Should -Be -1
    $odd = New-HealthProgress; $odd.Steps[0].Status = 'exploded'
    @((Update-RepairRunModel -Repair $r -Progress $odd -ElapsedSeconds 5).Run.Steps.Status)[0] | Should -BeExactly 'pending'
    $none = (New-TestModel @{}).Repair; (Update-RepairRunModel -Repair $none -Progress (New-HealthProgress) -ElapsedSeconds 9).Run | Should -BeNullOrEmpty }
  It 'a Current, a step row or a log line of the wrong type is tolerated, never thrown (review M1, RD-R16)' {
    $r = New-RepairRunModel -Repair (New-TestModel @{}).Repair -ActionId 'health' -RunId '20261022-101500-health'
    foreach ($bad in 'x', 1e12, 2.5, $true, @(1, 2), @{ a = 1 }) {
      $p = New-HealthProgress; $p.Current = $bad
      $n = Update-RepairRunModel -Repair $r -Progress $p -ElapsedSeconds 5
      $n.Run.Current | Should -Be -1 -Because "Current = $bad"; @($n.Run.Steps.Status) | Should -Be @('done', 'running', 'pending') }
    $p = New-HealthProgress; $p.Current = '2'; (Update-RepairRunModel -Repair $r -Progress $p -ElapsedSeconds 5).Run.Current | Should -Be 2
    # Rows that are no object, or have no Id, are left out; a progress with no usable row keeps the run's steps.
    $p = New-HealthProgress; $p.Steps = @('junk', @{ Id = 'volumeState'; Status = 'done' }, @{ Status = 'done' }, 7)
    $n = Update-RepairRunModel -Repair $r -Progress $p -ElapsedSeconds 5; @($n.Run.Steps.Id) | Should -Be @('volumeState')
    $p = New-HealthProgress; $p.Steps = 'oops'; @((Update-RepairRunModel -Repair $r -Progress $p -ElapsedSeconds 5).Run.Steps).Count | Should -Be 7
    $p = New-HealthProgress; $p.Log = @('kept', @{ a = 1 }, 5); @((Update-RepairRunModel -Repair $r -Progress $p -ElapsedSeconds 5).Run.Log) | Should -Be @('kept', '5') }
  It 'the result ends the run: no run, the result shown, the visit''s list grows, the strip reloads and the refused close is forgotten' {
    $r = New-RepairRunModel -Repair (New-TestModel @{}).Repair -ActionId 'standard' -RunId '20261022-101500-standard'; $r.CloseRefused = $true
    $n = Complete-RepairRunModel -Repair $r -Result $script:resultSample
    $n.Run | Should -BeNullOrEmpty; $n.Result.Outcome | Should -Be 'Done'; $n.CloseRefused | Should -BeFalse
    @($n.Done).Count | Should -Be 1; $n.Done[0].Action | Should -Be 'standard'; $n.Done[0].Outcome | Should -Be 'Done'; $n.Done[0].Color | Should -Be 'YELLOW'
    $n.Strip.State | Should -Be 'loading'; $n.Strip.Free.Level | Should -Be 'ok'   # the chips stay until the safety child reads them again
    $r.Strip.State | Should -Be 'ready'; $r.Run | Should -Not -BeNullOrEmpty; @($r.Done).Count | Should -Be 0   # the input is not changed
    $twice = Complete-RepairRunModel -Repair $n -Result @{ Action = 'health'; Outcome = 'Stopped'; Color = 'YELLOW'; EndedAt = '2026-10-22T11:00:00' }
    @($twice.Done.Action) | Should -Be @('standard', 'health'); $twice.Done[1].EndedAt | Should -Be '2026-10-22T11:00:00' }
  It 'the window''s own result: <Outcome> marks the running step <Running>, the pending ones skipped, red, with the English finding' -ForEach @(
    @{ Outcome = 'TimedOut'; Code = 'actionTimedOut'; A = @(150); Running = 'timedout'; Text = 'The action reached its deadline (150 min) and was stopped' }
    @{ Outcome = 'Failed'; Code = 'childNoResult'; A = @(1); Running = 'failed'; Text = 'The action ended without a result (exit 1)' }
  ) {
    $r = New-RepairRunModel -Repair (New-TestModel @{}).Repair -ActionId 'health' -RunId '20261022-101500-health'
    $r = Update-RepairRunModel -Repair $r -Progress (New-HealthProgress) -ElapsedSeconds 9
    $res = New-RepairWindowResult -Repair $r -Outcome $Outcome -Code $Code -Arguments $A -EndedAt '2026-10-22T12:00:00'
    $res.Outcome | Should -Be $Outcome; $res.Color | Should -Be 'RED'; $res.Action | Should -Be 'health'; $res.RunId | Should -Be '20261022-101500-health'
    @($res.Steps.Status) | Should -Be @('done', $Running, 'skipped'); $res.EndedAt | Should -Be '2026-10-22T12:00:00'
    @($res.Findings).Count | Should -Be 1; $res.Findings[0].Level | Should -Be 'CRIT'; $res.Findings[0].Code | Should -Be $Code
    $res.Findings[0].Text | Should -BeExactly $Text; @($res.Findings[0].Args) | Should -Be @([string]$A[0])
    $res.RestartRequired | Should -BeFalse; $res.Offers.DiskCheck | Should -BeFalse }
  It 'a start that failed: every step skipped, the reason in ASCII' {
    $r = New-RepairRunModel -Repair (New-TestModel @{}).Repair -ActionId 'health' -RunId '20261022-101500-health'
    $res = New-RepairWindowResult -Repair $r -Outcome Failed -Code childStartFailed -Arguments @('no powershell ' + [char]0x05D0)
    @($res.Steps.Status | Select-Object -Unique) | Should -Be @('skipped'); $res.Findings[0].Text | Should -BeExactly 'The action could not start: no powershell ?'
    @($res.Findings[0].Args) | Should -Be @('no powershell ?') }
}
