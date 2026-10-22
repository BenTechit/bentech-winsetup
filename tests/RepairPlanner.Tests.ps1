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

Describe 'the action catalog''s confirmations (Task 5 review M3, ruling RD-R19)' {
  BeforeAll {
    # The ids of the rows whose confirmation is weaker than their kind: a destructive action asks for YES, a repair at
    # least for a confirmation.
    function Get-WeakConfirmRows($catalog) {
      @(foreach ($id in @($catalog.Keys)) {
          $kind = [string]$catalog[$id]['Kind']; $confirm = [string]$catalog[$id]['Confirm']
          if (($kind -eq 'destructive' -and $confirm -cne 'yes') -or ($kind -eq 'repair' -and $confirm -cnotin 'confirm', 'yes')) { $id } })
    }
  }
  It 'every destructive row of the catalog asks for YES and every repair row at least confirms (the check finds a weak row)' {
    @(Get-WeakConfirmRows ([ordered]@{ a = @{ Kind = 'destructive'; Confirm = 'none' }; b = @{ Kind = 'repair'; Confirm = 'none' }; c = @{ Kind = 'destructive'; Confirm = 'yes' }
                                       d = @{ Kind = 'readonly'; Confirm = 'none' }; e = @{ Kind = 'repair'; Confirm = 'yes' } })) | Should -Be @('a', 'b')
    @(Get-WeakConfirmRows $script:ToolActionCatalog).Count | Should -Be 0 }
  It 'Get-RepairConfirmKind floors the catalog''s Confirm by its Kind: <Kind>/<Confirm> is <E>' -ForEach @(
    @{ Kind = 'destructive'; Confirm = 'none'; E = 'yes' }, @{ Kind = 'destructive'; Confirm = 'confirm'; E = 'yes' }, @{ Kind = 'destructive'; Confirm = 'yes'; E = 'yes' }
    @{ Kind = 'repair'; Confirm = 'none'; E = 'confirm' }, @{ Kind = 'repair'; Confirm = 'confirm'; E = 'confirm' }, @{ Kind = 'repair'; Confirm = 'yes'; E = 'yes' }
    @{ Kind = 'readonly'; Confirm = 'none'; E = 'none' }, @{ Kind = 'info'; Confirm = 'none'; E = 'none' }, @{ Kind = 'readonly'; Confirm = 'odd'; E = 'yes' }
  ) {
    $script:ToolActionCatalog['floorTestRow'] = @{ Kind = $Kind; Confirm = $Confirm; NeedsStick = $false; LogLocal = $false; Steps = [string[]]@() }
    try { Get-RepairConfirmKind -ActionId 'floorTestRow' | Should -BeExactly $E } finally { $script:ToolActionCatalog.Remove('floorTestRow') } }
  It 'an action without a catalog row is confirmed with YES' { Get-RepairConfirmKind -ActionId 'noSuchRow' | Should -BeExactly 'yes' }
}

Describe 'Update-RepairModel (repair Task 5: tiles, confirmations, the complaint; spec 4.2, 6.6, 6.7)' {
  BeforeAll {
    # The catalog rows Tasks 6 to 9 add (plan "Actions and steps"), so every tile has its confirmation kind here; this
    # Describe's AfterAll removes them again.
    $script:laterRows = [ordered]@{
      standard    = @{ Kind = 'repair'; Confirm = 'confirm'; NeedsStick = $false; LogLocal = $false; Steps = [string[]]@('timeSync', 'volumeScan', 'dism', 'sfc', 'winreFix') }
      postClone   = @{ Kind = 'repair'; Confirm = 'confirm'; NeedsStick = $false; LogLocal = $false; Steps = [string[]]@('timeSync', 'volumeScan', 'dism', 'sfc', 'winreFix') }
      dismSource  = @{ Kind = 'repair'; Confirm = 'confirm'; NeedsStick = $false; LogLocal = $false; Steps = [string[]]@('dismSource', 'sfc') }
      wuReset     = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $false; LogLocal = $false; Steps = [string[]]@('wuServicesStop', 'wuRename', 'wuBits', 'wuServicesStart', 'wuScan') }
      diskCheck   = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $false; LogLocal = $false; Steps = [string[]]@('diskCheckSchedule') }
      netInfo     = @{ Kind = 'info'; Confirm = 'none'; NeedsStick = $false; LogLocal = $true; Steps = [string[]]@('netInfo') }
      netReset    = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $true; LogLocal = $false; Steps = [string[]]@('netBackup', 'winsockReset', 'ipReset', 'ipv6Reset', 'dnsFlush') }
      netRestore  = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $true; LogLocal = $false; Steps = [string[]]@('netRestore') }
      ghostList   = @{ Kind = 'info'; Confirm = 'none'; NeedsStick = $true; LogLocal = $true; Steps = [string[]]@('ghostList') }
      ghostRemove = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $true; LogLocal = $false; Steps = [string[]]@('ghostCsv', 'ghostRemove') }
      quickReport = @{ Kind = 'readonly'; Confirm = 'none'; NeedsStick = $true; LogLocal = $false; Steps = [string[]]@('reportWrite') }
      fullReport  = @{ Kind = 'readonly'; Confirm = 'none'; NeedsStick = $true; LogLocal = $false; Steps = [string[]]@('reportWrite') }
      compare     = @{ Kind = 'readonly'; Confirm = 'none'; NeedsStick = $true; LogLocal = $false; Steps = [string[]]@('compare') }
    }
    foreach ($k in $script:laterRows.Keys) { $script:ToolActionCatalog[$k] = $script:laterRows[$k] }
    # ghostList's Data.Ghosts (plan Task 7): an old network adapter, a Bluetooth headset (left out) and an old USB stick.
    $script:threeGhosts = @(
      @{ InstanceId = 'PCI\VEN_8086&DEV_15BC\3&11583659&0&FE'; Class = 'Net'; Name = 'Intel(R) Ethernet Connection'; Excluded = '' }
      @{ InstanceId = 'BTHENUM\{0000110b-0000-1000-8000-00805f9b34fb}_LOCALMFG&0002\7&1'; Class = 'Bluetooth'; Name = 'אוזניות של דנה'; Excluded = 'bluetooth' }
      @{ InstanceId = 'USB\VID_0781&PID_5567\4C53'; Class = 'USB'; Name = 'SanDisk Cruzer'; Excluded = '' }
    )
    function Set-NoStick($mo) { $mo.Repair.Stick = @{ Root = $null; Drive = $null }; $mo }
    # A saved backup found on the stick (plan Task 7, Find-ToolNetBackup): one static adapter and one on DHCP.
    function Set-NetBackup($mo) {
      $mo.Repair.NetBackup = @{ Path = 'E:\BenTech-Reports\DESKTOP-4F7K2LQ_7HX2K93_2026-10-20_0900\network-backup-20261020-090500.json'; Sha256 = ('AB' * 32)
        CreatedAt = '2026-10-20T09:05:00'
        Adapters = @(@{ Alias = 'Ethernet'; Guid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-56'; Ipv4Dhcp = $false; Ipv6Dhcp = $true
                        Addresses = @(@{ Ip = '192.168.1.10'; Prefix = 24 }); Gateways = @('192.168.1.1'); Dns = @('8.8.8.8', '8.8.4.4') }
                     @{ Alias = 'Wi-Fi'; Guid = '{5D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-57'; Ipv4Dhcp = $true; Ipv6Dhcp = $true
                        Addresses = @(); Gateways = @(); Dns = @() }) }
      $mo
    }
    function Get-LineKeys($n) { @($n.Repair.Confirm.Lines | ForEach-Object { [string]$_.Key }) }
    function Get-LineText($n) { (@($n.Repair.Confirm.Lines | ForEach-Object { '{0} {1}' -f $_.Key, (@($_.Args) -join ' ') }) -join "`n") }
  }
  AfterAll { foreach ($k in $script:laterRows.Keys) { $script:ToolActionCatalog.Remove($k) } }
  BeforeEach { $script:mo = New-TestModel @{} }

  It 'a read-only tile with a stick starts at once; without a stick it asks first' {
    $s = Update-RepairModel -Model $mo -Action Tile -Value health; $s.Repair.Pending | Should -Be 'health'; $s.Repair.Confirm | Should -BeNullOrEmpty
    $s.Repair.Selected | Should -Be 'health'
    $n = Update-RepairModel -Model (Set-NoStick $mo) -Action Tile -Value health; $n.Repair.Pending | Should -BeNullOrEmpty
    Get-LineKeys $n | Should -Contain 'confirm.noStickLog'; $n.Repair.Confirm.Kind | Should -Be 'confirm'; $n.Repair.Confirm.Loading | Should -BeFalse
    (Update-RepairModel -Model $n -Action Confirm).Repair.Pending | Should -Be 'health'
    $n.Repair.Pending | Should -BeNullOrEmpty; $s.Repair.Confirm | Should -BeNullOrEmpty }   # pure: each call returns a copy
  It 'a destructive tile needs YES, and a raised Confirm without it starts nothing' {
    $n = Update-RepairModel -Model $mo -Action Tile -Value wuReset; $n.Repair.Confirm.Kind | Should -Be 'yes'; Get-LineKeys $n | Should -Be @('tile.wuReset.changes')
    (Update-RepairModel -Model $n -Action Confirm).Repair.Pending | Should -BeNullOrEmpty
    $y = Update-RepairModel -Model $n -Action YesText -Value 'yes'; $y.Repair.Confirm.Typed | Should -BeExactly 'yes'; (Update-RepairModel -Model $y -Action Confirm).Repair.Pending | Should -Be 'wuReset'
    $h = Update-RepairModel -Model $n -Action YesText -Value ([string][char]0x05D8 + [char]0x05E7 + [char]0x05D3)   # the same keys on a Hebrew layout
    (Update-RepairModel -Model $h -Action Confirm).Repair.Pending | Should -Be 'wuReset'
    (Update-RepairModel -Model (Update-RepairModel -Model $n -Action YesText -Value 'YE') -Action Confirm).Repair.Pending | Should -BeNullOrEmpty
    $n.Repair.Confirm.Typed | Should -BeExactly '' }   # the input is not changed
  It 'a pending start is one-shot: the next change clears it' {
    $s = Update-RepairModel -Model $mo -Action Tile -Value health; (Update-RepairModel -Model $s -Action Hover -Value 'standard').Repair.Pending | Should -BeNullOrEmpty }
  It 'Network reset always demands the at-PC tick, with or without RDP (RD-R2)' {
    $o = Update-RepairModel -Model $mo -Action Tile -Value netReset; $o.Repair.Confirm.Loading | Should -BeTrue; $o.Repair.Pending | Should -BeNullOrEmpty
    (Update-RepairModel -Model (Update-RepairModel -Model $o -Action YesText -Value 'YES') -Action Confirm).Repair.Pending | Should -BeNullOrEmpty   # still loading
    $n = Update-RepairModel -Model $o -Action NetInfo -Value @{ Adapters = @(); Remote = @{ Rdp = $false } }
    $n.Repair.Confirm.Loading | Should -BeFalse; $n.Repair.Confirm.Remote.Rdp | Should -BeFalse; Get-LineKeys $n | Should -Contain 'confirm.noStatic'
    $n = Update-RepairModel -Model $n -Action YesText -Value 'YES'; (Update-RepairModel -Model $n -Action Confirm).Repair.Pending | Should -BeNullOrEmpty
    (Update-RepairModel -Model (Update-RepairModel -Model $n -Action AtPc) -Action Confirm).Repair.Pending | Should -Be 'netReset'
    $r = Update-RepairModel -Model $o -Action NetInfo -Value @{ Adapters = @(); Remote = @{ Rdp = $true } }; $r.Repair.Confirm.Remote.Rdp | Should -BeTrue
    $r = Update-RepairModel -Model (Update-RepairModel -Model $r -Action YesText -Value 'YES') -Action AtPc; (Update-RepairModel -Model $r -Action Confirm).Repair.Pending | Should -Be 'netReset'
    (Update-RepairModel -Model (Update-RepairModel -Model $r -Action AtPc) -Action Confirm).Repair.Pending | Should -BeNullOrEmpty }   # untick: refused again
  It 'Network reset shows each static adapter''s values as one line, alias first' {
    $info = @{ Remote = @{ Rdp = $false }; Adapters = @(@{ Alias = 'Ethernet'; Addresses = @(@{ Ip = '192.168.1.10'; Prefix = 24 }, @{ Ip = 'fd00::10'; Prefix = 64 }); Gateways = @('192.168.1.1'); Dns = @('8.8.8.8', '8.8.4.4') }
                                                   @{ Alias = 'Wi-Fi'; Addresses = @(); Gateways = @(); Dns = @('1.1.1.1') }
                                                   @{ Alias = 'Bluetooth'; Addresses = @(); Gateways = @(); Dns = @() }, 'junk') }
    $n = Update-RepairModel -Model (Update-RepairModel -Model $mo -Action Tile -Value netReset) -Action NetInfo -Value $info
    $static = @($n.Repair.Confirm.Lines | Where-Object { $_.Key -eq 'confirm.static' }); $static.Count | Should -Be 2
    @($static[0].Args) | Should -Be @('Ethernet', '192.168.1.10/24, fd00::10/64, gateway 192.168.1.1, DNS 8.8.8.8, 8.8.4.4')
    @($static[1].Args) | Should -Be @('Wi-Fi', 'DNS 1.1.1.1'); Get-LineKeys $n | Should -Not -Contain 'confirm.noStatic'
    # Read from JSON as objects, it is the same; an answer for no open Network reset confirmation, or a second one, is dropped.
    $j = Update-RepairModel -Model (Update-RepairModel -Model $mo -Action Tile -Value netReset) -Action NetInfo -Value ($info | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
    @(@($j.Repair.Confirm.Lines | Where-Object { $_.Key -eq 'confirm.static' })[0].Args) | Should -Be @($static[0].Args)
    (Update-RepairModel -Model $mo -Action NetInfo -Value $info).Repair.Confirm | Should -BeNullOrEmpty
    @((Update-RepairModel -Model $n -Action NetInfo -Value $info).Repair.Confirm.Lines).Count | Should -Be @($n.Repair.Confirm.Lines).Count
    (Update-RepairModel -Model (Update-RepairModel -Model $mo -Action Tile -Value netReset) -Action NetInfo -Value 'not an object').Repair.Confirm.Loading | Should -BeTrue }
  It 'ghosts: every item ticked, untick one, the options carry the ticked ids only; none ticked cannot confirm' {
    $o = Update-RepairModel -Model $mo -Action Tile -Value ghosts; $o.Repair.Confirm.Loading | Should -BeTrue
    $n = Update-RepairModel -Model $o -Action GhostItems -Value $threeGhosts   # 3 devices, one excluded (BTHENUM)
    @($n.Repair.Confirm.Items).Count | Should -Be 2; @($n.Repair.Confirm.Items.Ticked) | Should -Be @($true, $true); $n.Repair.Confirm.Loading | Should -BeFalse
    @($n.Repair.Confirm.Items.InstanceId) | Should -Not -Contain $threeGhosts[1].InstanceId
    @(@($n.Repair.Confirm.Lines | Where-Object { $_.Key -eq 'confirm.ghostCount' })[0].Args) | Should -Be @(2, 3, 1)
    $n = Update-RepairModel -Model (Update-RepairModel -Model $n -Action GhostTick -Value 0) -Action YesText -Value 'yes'
    @(@($n.Repair.Confirm.Lines | Where-Object { $_.Key -eq 'confirm.ghostCount' })[0].Args) | Should -Be @(1, 3, 1)
    $c = Update-RepairModel -Model $n -Action Confirm; $c.Repair.Pending | Should -Be 'ghostRemove'
    $c.Repair.Confirm.Options.Ids | Should -Be @('USB\VID_0781&PID_5567\4C53')
    (Update-RepairModel -Model (Update-RepairModel -Model $n -Action GhostTick -Value 1) -Action Confirm).Repair.Pending | Should -BeNullOrEmpty
    @((Update-RepairModel -Model $n -Action GhostTick -Value 7).Repair.Confirm.Items.Ticked) | Should -Be @($false, $true)   # no such item: nothing changes
    @($o.Repair.Confirm.Items).Count | Should -Be 0 }   # the input is not changed
  It 'ghosts: a list with nothing to remove cannot confirm; a device flagged excluded in any way is never an item' {
    $n = Update-RepairModel -Model (Update-RepairModel -Model $mo -Action Tile -Value ghosts) -Action GhostItems -Value @($threeGhosts[1], @{ InstanceId = 'SWD\MMDEVAPI\{0.0.1.00000000}'; Class = 'AudioEndpoint'; Name = 'Speakers'; Excluded = $true }, @{ Name = 'no id' })
    @($n.Repair.Confirm.Items).Count | Should -Be 0; @(@($n.Repair.Confirm.Lines | Where-Object { $_.Key -eq 'confirm.ghostCount' })[0].Args) | Should -Be @(0, 2, 2)
    (Update-RepairModel -Model (Update-RepairModel -Model $n -Action YesText -Value 'YES') -Action Confirm).Repair.Pending | Should -BeNullOrEmpty
    $e = Update-RepairModel -Model (Update-RepairModel -Model $mo -Action Tile -Value ghosts) -Action GhostItems -Value @()
    $e.Repair.Confirm.Loading | Should -BeFalse; @($e.Repair.Confirm.Items).Count | Should -Be 0 }
  It 'Restore network settings lists every value it will apply and needs YES' {
    $n = Update-RepairModel -Model (Set-NetBackup $mo) -Action Tile -Value netRestore
    (Get-LineText $n) | Should -Match '192\.168\.1\.10/24.*192\.168\.1\.1.*8\.8\.8\.8'; $n.Repair.Confirm.Kind | Should -Be 'yes'; $n.Repair.Confirm.Loading | Should -BeFalse
    @($n.Repair.Confirm.Lines | Where-Object { $_.Key -eq 'confirm.static' }).Count | Should -Be 1   # the DHCP adapter has nothing to put back
    $n.Repair.Confirm.Options.File | Should -BeExactly $mo.Repair.NetBackup.Path; $n.Repair.Confirm.Options.Sha256 | Should -BeExactly ('AB' * 32)
    (Update-RepairModel -Model $n -Action Confirm).Repair.Pending | Should -BeNullOrEmpty
    (Update-RepairModel -Model (Update-RepairModel -Model $n -Action YesText -Value 'YES') -Action Confirm).Repair.Pending | Should -Be 'netRestore'
    (Update-RepairModel -Model (New-TestModel @{}) -Action Tile -Value netRestore).Repair.Confirm | Should -BeNullOrEmpty }   # hidden without a backup: nothing opens
  It 'a gate that closed after the panel opened refuses the Confirm' {
    $n = Update-RepairModel -Model $mo -Action Tile -Value standard; $n.Repair.Confirm.Kind | Should -Be 'confirm'; $n.Repair.Strip.Restart = @{ Level = 'crit' }
    (Update-RepairModel -Model $n -Action Confirm).Repair.Pending | Should -BeNullOrEmpty }
  It 'a disabled tile changes nothing; the same tile again keeps its confirmation and what was typed' {
    $x = Update-RepairModel -Model (New-TestModel @{ Restart = 'crit' }) -Action Tile -Value standard; $x.Repair.Confirm | Should -BeNullOrEmpty; $x.Repair.Pending | Should -BeNullOrEmpty
    (Update-RepairModel -Model (New-TestModel @{ Running = $true }) -Action Tile -Value health).Repair.Pending | Should -BeNullOrEmpty
    $n = Update-RepairModel -Model (Update-RepairModel -Model $mo -Action Tile -Value wuReset) -Action YesText -Value 'YES'
    (Update-RepairModel -Model $n -Action Tile -Value wuReset).Repair.Confirm.Typed | Should -BeExactly 'YES'
    $d = Update-RepairModel -Model $n -Action Tile -Value diskCheck; $d.Repair.Confirm.Action | Should -Be 'diskCheck'; $d.Repair.Confirm.Typed | Should -BeExactly '' }
  It 'a catalog row weaker than its kind is confirmed by its kind at the tile: destructive asks for YES, a repair confirms (M3, RD-R19)' {
    $keepWu = $script:ToolActionCatalog['wuReset']; $keepStd = $script:ToolActionCatalog['standard']
    try {
      $script:ToolActionCatalog['wuReset'] = @{ Kind = 'destructive'; Confirm = 'none'; NeedsStick = $false; LogLocal = $false; Steps = [string[]]@('wuServicesStop') }
      $script:ToolActionCatalog['standard'] = @{ Kind = 'repair'; Confirm = 'none'; NeedsStick = $false; LogLocal = $false; Steps = [string[]]@('dism') }
      $n = Update-RepairModel -Model $mo -Action Tile -Value wuReset; $n.Repair.Pending | Should -BeNullOrEmpty; $n.Repair.Confirm.Kind | Should -Be 'yes'
      $s = Update-RepairModel -Model $mo -Action Tile -Value standard; $s.Repair.Pending | Should -BeNullOrEmpty; $s.Repair.Confirm.Kind | Should -Be 'confirm'
    } finally { $script:ToolActionCatalog['wuReset'] = $keepWu; $script:ToolActionCatalog['standard'] = $keepStd } }
  It 'the confirmation carries the gate''s warnings after the change list' {
    $n = Update-RepairModel -Model (Set-NoStick (New-TestModel @{ Free = 'crit' })) -Action Tile -Value standard
    Get-LineKeys $n | Should -Be @('tile.standard.changes', 'warn.lowSpace', 'confirm.noStickLog') }
  It 'the DISM offer opens a confirmation with the file''s details, the build and language warnings, and its options' {
    $offer = @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = 6; Edition = 'Professional'; Arch = 'x64'; Languages = @('he-IL', 'en-US'); Build = '26100'
                BuildDiffers = $true; LanguageDiffers = $true; PcLanguage = 'ru-RU' }
    $withOffer = New-TestModel @{ Result = @{ Action = 'standard'; Outcome = 'Done'; Color = 'RED'; Offers = @{ DiskCheck = $false; DismSource = $offer } } }
    $n = Update-RepairModel -Model $withOffer -Action Offer -Value dismSource
    $n.Repair.Confirm.Action | Should -Be 'dismSource'; $n.Repair.Confirm.Kind | Should -Be 'confirm'
    Get-LineKeys $n | Should -Be @('tile.dismSource.changes', 'result.offerDism', 'result.buildDiffers', 'result.languageDiffers')
    @($n.Repair.Confirm.Lines[1].Args) | Should -Be @('E:\sources\install.wim', 'Professional', 'x64', 'he-IL, en-US', '26100')
    @($n.Repair.Confirm.Lines[2].Args) | Should -Be @('26200'); @($n.Repair.Confirm.Lines[3].Args) | Should -Be @('he-IL, en-US', 'ru-RU')
    $c = Update-RepairModel -Model $n -Action Confirm; $c.Repair.Pending | Should -Be 'dismSource'
    $c.Repair.Confirm.Options.Path | Should -BeExactly 'E:\sources\install.wim'; $c.Repair.Confirm.Options.Type | Should -Be 'wim'; $c.Repair.Confirm.Options.Index | Should -Be 6
    (Update-RepairModel -Model $mo -Action Offer -Value dismSource).Repair.Confirm | Should -BeNullOrEmpty }   # no offer, no confirmation
  It 'hover selects a tile; AtPc and BackedUp toggle; ConfirmCancel closes; YES keeps its 8 characters' {
    (Update-RepairModel -Model $mo -Action Hover -Value 'wuReset').Repair.Selected | Should -Be 'wuReset'
    (Update-RepairModel -Model $mo -Action Hover -Value 'noSuchTile').Repair.Selected | Should -BeExactly ''
    $b = Update-RepairModel -Model $mo -Action BackedUp; $b.Repair.BackedUp | Should -BeTrue; (Update-RepairModel -Model $b -Action BackedUp).Repair.BackedUp | Should -BeFalse
    $n = Update-RepairModel -Model $mo -Action Tile -Value wuReset
    (Update-RepairModel -Model $n -Action AtPc).Repair.Confirm.AtPc | Should -BeTrue; (Update-RepairModel -Model $mo -Action AtPc).Repair.Confirm | Should -BeNullOrEmpty
    (Update-RepairModel -Model $n -Action YesText -Value 'YES YES YES').Repair.Confirm.Typed | Should -BeExactly 'YES YES '
    (Update-RepairModel -Model $n -Action ConfirmCancel).Repair.Confirm | Should -BeNullOrEmpty; $n.Repair.Confirm | Should -Not -BeNullOrEmpty
    (Update-RepairModel -Model $mo -Action YesText -Value 'YES').Repair.Confirm | Should -BeNullOrEmpty }   # no confirmation: nothing to type into
  It 'the complaint is kept to 2000 characters, Hebrew and all' {
    $t = ('ק' * 2100); $c = (Update-RepairModel -Model $mo -Action Complaint -Value $t).Repair.Complaint
    $c.Length | Should -Be 2000; $c[0] | Should -Be 'ק'
    $pair = ('a' * 1999) + [char]::ConvertFromUtf32(0x1F600) + 'b'   # never half a surrogate pair at the cut
    (Update-RepairModel -Model $mo -Action Complaint -Value $pair).Repair.Complaint | Should -BeExactly ('a' * 1999) }
  It 'Test-RepairConfirmReady: a remote session reported needs the at-PC tick for any confirmation; Ghost devices need a ticked device' {
    $c = @{ Action = 'wuReset'; Kind = 'yes'; Typed = 'YES'; AtPc = $false; Loading = $false; Lines = @(); Remote = @{ Rdp = $true }; Items = @(); Options = @{} }
    Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $c }) | Should -BeFalse
    $c.AtPc = $true; Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $c }) | Should -BeTrue
    $c.AtPc = $false; $c.Remote = @{ Rdp = $false }; Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $c }) | Should -BeTrue
    $g = @{ Action = 'ghosts'; Kind = 'yes'; Typed = 'YES'; AtPc = $false; Loading = $false; Lines = @(); Remote = $null; Items = @(); Options = @{} }
    Test-RepairConfirmReady -Model (New-TestModel @{ Confirm = $g }) | Should -BeFalse }
}
