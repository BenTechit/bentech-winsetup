# tests/State.Tests.ps1
BeforeAll { . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\State\State.ps1" }
Describe 'run state' {
  BeforeEach { $script:root = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory "$root\Logs" -Force | Out-Null }
  It 'round-trips through json as nested hashtables' {
    $s = New-RunState -Machine @{Brand='DELL'} -Choices @{Mode='LAPTOP';SevenZip=$true;Office='OFF'} -Plan @('prepare','finalize') -Version '2026.10.18.1'
    Save-RunState -State $s -Root $root; $r = Read-RunState -Root $root -LogDir "$root\Logs"
    $r.Steps['prepare'].Status | Should -Be 'pending'; $r.Machine.Brand | Should -Be 'DELL'; $r | Should -BeOfType [hashtable]
  }
  It 'archives truncated json and returns null (power cut mid-write)' {
    '{"SchemaVersion":1,"Steps":{"prep' | Set-Content "$root\state.json"
    Read-RunState -Root $root -LogDir "$root\Logs" | Should -BeNullOrEmpty
    Test-Path "$root\state.json" | Should -BeFalse; @(Get-ChildItem "$root\Logs\state.corrupt-*.json").Count | Should -Be 1
  }
  It 'leaves no tmp file after a save' { Save-RunState -State (New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v') -Root $root; Test-Path "$root\state.json.tmp" | Should -BeFalse }
  It 'counts attempts and stamps times' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'
    Set-StepState -State $s -StepId a -Status running -IncrementAttempt; Set-StepState -State $s -StepId a -Status Done -Message ok
    $s.Steps.a.Attempts | Should -Be 1; $s.Steps.a.EndedAt | Should -Not -BeNullOrEmpty
  }
  It 'carries hidden updates from the previous run' {
    $p = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'; $p.HiddenUpdateIds = @('u1')
    (New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v' -Previous $p).PreviousHiddenUpdateIds | Should -Be @('u1')
  }
}
Describe 'ConvertTo-HashtableDeep' {
  It 'turns nested objects into hashtables and keeps arrays as arrays' {
    $h = ConvertTo-HashtableDeep -InputObject ('{"a":{"b":[{"c":1}]},"d":[],"e":[5],"f":null,"g":"txt","h":[[1],[2,3]]}' | ConvertFrom-Json)
    $h | Should -BeOfType [hashtable]
    $h.a | Should -BeOfType [hashtable]
    ($h.a.b -is [array]) | Should -BeTrue; $h.a.b.Count | Should -Be 1; $h.a.b[0] | Should -BeOfType [hashtable]; $h.a.b[0].c | Should -Be 1
    ($h.d -is [array]) | Should -BeTrue; $h.d.Count | Should -Be 0
    ($h.e -is [array]) | Should -BeTrue; $h.e.Count | Should -Be 1; $h.e[0] | Should -Be 5
    $h.ContainsKey('f') | Should -BeTrue; $h.f | Should -BeNullOrEmpty
    $h.g | Should -BeOfType [string]
    $h.h.Count | Should -Be 2; ($h.h[0] -is [array]) | Should -BeTrue; $h.h[0].Count | Should -Be 1; $h.h[1].Count | Should -Be 2
  }
  It 'converts hashtable input recursively too' {
    $h = ConvertTo-HashtableDeep -InputObject @{ x = [pscustomobject]@{ y = @([pscustomobject]@{ z = 1 }) } }
    $h.x | Should -BeOfType [hashtable]; $h.x.y[0] | Should -BeOfType [hashtable]; $h.x.y[0].z | Should -Be 1
  }
  It 'returns null for null input' { ConvertTo-HashtableDeep -InputObject $null | Should -BeNullOrEmpty }
}
Describe 'run state persistence' {
  BeforeEach { $script:root = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory "$root\Logs" -Force | Out-Null }
  It 'builds the documented State shape with every plan step pending' {
    $s = New-RunState -Machine @{ Brand = 'HP' } -Choices @{ Mode = 'DESKTOP' } -Plan @('prepare', 'apps', 'finalize') -Version '9.9'
    $s.SchemaVersion | Should -Be 1; $s.Version | Should -Be '9.9'
    $s.RunId | Should -Not -BeNullOrEmpty
    $s.StartedAt | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'
    $s.EndedAt | Should -BeNullOrEmpty; $s.PreviousRun | Should -BeNullOrEmpty; $s.AnyDeskId | Should -BeNullOrEmpty
    @($s.Plan) | Should -Be @('prepare', 'apps', 'finalize')
    $s.Steps.Keys.Count | Should -Be 3
    foreach ($id in 'prepare', 'apps', 'finalize') {
      $st = $s.Steps[$id]
      $st.Status | Should -Be 'pending'; $st.Attempts | Should -Be 0; $st.Message | Should -Be ''
      $st.StartedAt | Should -BeNullOrEmpty; $st.EndedAt | Should -BeNullOrEmpty; $st.Data | Should -BeOfType [hashtable]
    }
    $s.RebootCount | Should -Be 0; $s.RebootCapHit | Should -BeFalse; $s.FinalRebootDone | Should -BeFalse
    $s.WuFailureCounts | Should -BeOfType [hashtable]; $s.Power.Original | Should -BeOfType [hashtable]
    foreach ($k in 'HiddenUpdateIds', 'PreviousHiddenUpdateIds', 'Notes', 'Errors') { ($s[$k] -is [array]) | Should -BeTrue; $s[$k].Count | Should -Be 0 }
  }
  It 'defaults PreviousHiddenUpdateIds to empty when there is no previous run' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'
    ($s.PreviousHiddenUpdateIds -is [array]) | Should -BeTrue; $s.PreviousHiddenUpdateIds.Count | Should -Be 0
  }
  It 'keeps one-element and empty arrays as arrays through save and read' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('only') -Version 'v'
    $s.Notes = @('n1'); $s.Errors = @(); $s.HiddenUpdateIds = @('u1')
    Save-RunState -State $s -Root $root; $r = Read-RunState -Root $root
    ($r.Plan -is [array]) | Should -BeTrue; $r.Plan.Count | Should -Be 1; $r.Plan[0] | Should -Be 'only'
    ($r.Notes -is [array]) | Should -BeTrue; $r.Notes.Count | Should -Be 1
    ($r.HiddenUpdateIds -is [array]) | Should -BeTrue; $r.HiddenUpdateIds.Count | Should -Be 1
    $null -eq $r.Errors | Should -BeFalse; ($r.Errors -is [array]) | Should -BeTrue; $r.Errors.Count | Should -Be 0
    ($r.PreviousHiddenUpdateIds -is [array]) | Should -BeTrue; $r.PreviousHiddenUpdateIds.Count | Should -Be 0
    $r.Steps['only'].Data | Should -BeOfType [hashtable]; $r.Steps['only'].Data.Count | Should -Be 0
    $r.Steps['only'].StartedAt | Should -BeNullOrEmpty
  }
  It 'writes UTF-8 without a BOM and round-trips Hebrew text' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'
    $hebrew = [string]::Join('', [char[]](0x05E9, 0x05DC, 0x05D5, 0x05DD))
    Set-StepState -State $s -StepId a -Status Failed -Message $hebrew
    Save-RunState -State $s -Root $root
    $bytes = [IO.File]::ReadAllBytes("$root\state.json")
    ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    (Read-RunState -Root $root).Steps.a.Message | Should -Be $hebrew
  }
  It 'replaces an existing state.json on a second save and leaves no tmp file' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v1'
    Save-RunState -State $s -Root $root
    $s.Version = 'v2'; Save-RunState -State $s -Root $root
    (Read-RunState -Root $root).Version | Should -Be 'v2'
    Test-Path "$root\state.json.tmp" | Should -BeFalse
  }
  It 'round-trips step Data holding nested hashtables and arrays' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'
    Set-StepState -State $s -StepId a -Status running -Data @{ round = 2; ids = @('u1'); rows = @(@{ kb = 'KB1'; ok = $true }) }
    Save-RunState -State $s -Root $root; $r = Read-RunState -Root $root
    $r.Steps.a.Data.round | Should -Be 2
    ($r.Steps.a.Data.ids -is [array]) | Should -BeTrue; $r.Steps.a.Data.ids.Count | Should -Be 1
    $r.Steps.a.Data.rows[0] | Should -BeOfType [hashtable]; $r.Steps.a.Data.rows[0].kb | Should -Be 'KB1'; $r.Steps.a.Data.rows[0].ok | Should -BeTrue
  }
  It 'creates the root folder when saving into a folder that does not exist yet' {
    $fresh = Join-Path $root 'new\nested'
    Save-RunState -State (New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v') -Root $fresh
    Test-Path "$fresh\state.json" | Should -BeTrue
  }
  It 'returns null when there is no state.json' { Read-RunState -Root $root | Should -BeNullOrEmpty }
  It 'logs a WARN when it archives a corrupt file' {
    Initialize-SetupLog -LogDirectory "$root\Logs"
    '{"broken' | Set-Content "$root\state.json"
    Read-RunState -Root $root -LogDir "$root\Logs" | Should -BeNullOrEmpty
    (Get-Content "$root\Logs\setup.log" -Raw) | Should -Match '\[WARN\].*state\.corrupt-'
  }
  It 'archives an empty state.json as corrupt' {
    New-Item -ItemType File "$root\state.json" | Out-Null
    Read-RunState -Root $root -LogDir "$root\Logs" | Should -BeNullOrEmpty
    Test-Path "$root\state.json" | Should -BeFalse; @(Get-ChildItem "$root\Logs\state.corrupt-*.json").Count | Should -Be 1
  }
  It 'archives valid json that is not an object as corrupt' {
    '[1,2,3]' | Set-Content "$root\state.json"
    Read-RunState -Root $root -LogDir "$root\Logs" | Should -BeNullOrEmpty
    Test-Path "$root\state.json" | Should -BeFalse; @(Get-ChildItem "$root\Logs\state.corrupt-*.json").Count | Should -Be 1
  }
  It 'defaults the corrupt-file folder to a Logs folder under the root and creates it' {
    $r2 = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory $r2 | Out-Null
    '{"x"' | Set-Content "$r2\state.json"
    Read-RunState -Root $r2 | Should -BeNullOrEmpty
    @(Get-ChildItem "$r2\Logs\state.corrupt-*.json").Count | Should -Be 1
  }
  It 'moves state.json to state-(RunId).json on backup' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'
    Save-RunState -State $s -Root $root
    Backup-RunState -Root $root -LogDir "$root\Logs"
    Test-Path "$root\state.json" | Should -BeFalse
    Test-Path "$root\Logs\state-$($s.RunId).json" | Should -BeTrue
  }
  It 'does nothing on backup when there is no state.json' {
    { Backup-RunState -Root $root -LogDir "$root\Logs" } | Should -Not -Throw
    @(Get-ChildItem "$root\Logs" -Filter 'state-*.json').Count | Should -Be 0
  }
  It 'does not overwrite an earlier archive with the same name' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'
    Save-RunState -State $s -Root $root; Backup-RunState -Root $root -LogDir "$root\Logs"
    Save-RunState -State $s -Root $root; Backup-RunState -Root $root -LogDir "$root\Logs"
    @(Get-ChildItem "$root\Logs" -Filter 'state-*.json').Count | Should -Be 2
  }
}
Describe 'Set-StepState' {
  BeforeEach { $script:s = New-RunState -Machine @{} -Choices @{} -Plan @('a', 'b') -Version 'v' }
  It 'stamps StartedAt on running and EndedAt on Done, Skipped and Failed' {
    Set-StepState -State $s -StepId a -Status running
    $s.Steps.a.Status | Should -Be 'running'; $s.Steps.a.StartedAt | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'; $s.Steps.a.EndedAt | Should -BeNullOrEmpty
    foreach ($st in 'Done', 'Skipped', 'Failed') {
      Set-StepState -State $s -StepId b -Status $st
      $s.Steps.b.Status | Should -Be $st; $s.Steps.b.EndedAt | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'
    }
  }
  It 'clears a stale EndedAt when a step starts running again' {
    Set-StepState -State $s -StepId a -Status Failed; Set-StepState -State $s -StepId a -Status running
    $s.Steps.a.EndedAt | Should -BeNullOrEmpty
  }
  It 'stores the status in its canonical case' {
    Set-StepState -State $s -StepId a -Status done
    $s.Steps.a.Status | Should -BeExactly 'Done'
  }
  It 'keeps the message unless one is given' {
    Set-StepState -State $s -StepId a -Status running -Message 'working'
    Set-StepState -State $s -StepId a -Status Done
    $s.Steps.a.Message | Should -Be 'working'
    Set-StepState -State $s -StepId a -Status Done -Message ''
    $s.Steps.a.Message | Should -Be ''
  }
  It 'increments attempts and resets them' {
    Set-StepState -State $s -StepId a -Status running -IncrementAttempt; Set-StepState -State $s -StepId a -Status running -IncrementAttempt
    $s.Steps.a.Attempts | Should -Be 2
    Set-StepState -State $s -StepId a -Status pending -ResetAttempts
    $s.Steps.a.Attempts | Should -Be 0
  }
  It 'merges Data into the step without dropping earlier keys' {
    Set-StepState -State $s -StepId a -Status running -Data @{ round = 1; kept = 'x' }
    Set-StepState -State $s -StepId a -Status running -Data @{ round = 2; extra = $true }
    $s.Steps.a.Data.round | Should -Be 2; $s.Steps.a.Data.kept | Should -Be 'x'; $s.Steps.a.Data.extra | Should -BeTrue
  }
  It 'throws for a step id that is not in the plan' {
    { Set-StepState -State $s -StepId nope -Status running } | Should -Throw
  }
  It 'rejects an unknown status' { { Set-StepState -State $s -StepId a -Status Maybe } | Should -Throw }
}
Describe 'run lock' {
  BeforeEach { $script:root = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory $root | Out-Null }
  It 'is held when the pid is this live powershell' { "$PID" | Set-Content "$root\run.lock"; Test-RunLockHeld -Root $root | Should -BeTrue; Enter-RunLock -Root $root | Should -BeFalse }
  It 'is not held for a dead pid' { '999999' | Set-Content "$root\run.lock"; Test-RunLockHeld -Root $root | Should -BeFalse; Enter-RunLock -Root $root | Should -BeTrue }
  It 'is not held for garbage' { 'abc' | Set-Content "$root\run.lock"; Test-RunLockHeld -Root $root | Should -BeFalse }
  It 'is not held when there is no lock file' { Test-RunLockHeld -Root $root | Should -BeFalse }
  It 'is not held for an empty lock file' { New-Item -ItemType File "$root\run.lock" | Out-Null; Test-RunLockHeld -Root $root | Should -BeFalse }
  It 'is not held when the pid belongs to a process that is not powershell' {
    "4" | Set-Content "$root\run.lock"   # PID 4 is the System process: alive, wrong name
    Test-RunLockHeld -Root $root | Should -BeFalse
  }
  It 'is not held when the pid was reused by a process that started after the lock was written' {
    "$PID" | Set-Content "$root\run.lock"
    (Get-Item "$root\run.lock").LastWriteTime = (Get-Process -Id $PID).StartTime.AddMinutes(-10)
    Test-RunLockHeld -Root $root | Should -BeFalse
    Enter-RunLock -Root $root | Should -BeTrue
  }
  It 'writes this pid and is then held' {
    Enter-RunLock -Root $root | Should -BeTrue
    (Get-Content "$root\run.lock" -Raw).Trim() | Should -Be "$PID"
    Test-RunLockHeld -Root $root | Should -BeTrue
    Test-Path "$root\run.lock.$PID.tmp" | Should -BeFalse
  }
  It 'refuses a second Enter-RunLock and leaves the first lock untouched' {
    Enter-RunLock -Root $root | Should -BeTrue
    Enter-RunLock -Root $root | Should -BeFalse
    (Get-Content "$root\run.lock" -Raw).Trim() | Should -Be "$PID"
  }
  It 'lets exactly one of several processes that race for the lock take it' {
    $repo = Split-Path -Parent $PSScriptRoot
    $child = Join-Path $root 'child.ps1'
    @'
param([string]$Repo, [string]$Root, [string]$Tag)
. (Join-Path $Repo 'src\Common\Logging.ps1')
. (Join-Path $Repo 'src\State\State.ps1')
New-Item -ItemType File (Join-Path $Root "ready-$Tag") | Out-Null
while (-not (Test-Path (Join-Path $Root 'go'))) { Start-Sleep -Milliseconds 2 }
$won = Enter-RunLock -Root $Root
Set-Content (Join-Path $Root "result-$Tag.txt") "$won"
if ($won) { Start-Sleep -Seconds 3 }   # keep the owner alive until every racer has answered
'@ | Set-Content $child
    $procs = @(1..4 | ForEach-Object {
        Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$child`"", "`"$repo`"", "`"$root`"", "t$_"
      })
    try {
      $deadline = (Get-Date).AddSeconds(60)
      while (@(Get-ChildItem $root -Filter 'ready-*').Count -lt 4 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
      New-Item -ItemType File "$root\go" | Out-Null   # release all racers at once
      $procs | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue
    } finally {
      $procs | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    $results = @(Get-ChildItem $root -Filter 'result-*.txt' | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() })
    $results.Count | Should -Be 4
    @($results | Where-Object { $_ -eq 'True' }).Count | Should -Be 1
  }
  It 'lets exactly one process take over a stale lock, round after round (post-reboot double start)' {
    $repo = Split-Path -Parent $PSScriptRoot
    $child = Join-Path $root 'child-stale.ps1'
    $rounds = 8
    @'
param([string]$Repo, [string]$Root, [string]$Tag, [int]$Rounds)
. (Join-Path $Repo 'src\Common\Logging.ps1')
. (Join-Path $Repo 'src\State\State.ps1')
New-Item -ItemType File (Join-Path $Root "ready-$Tag") | Out-Null
foreach ($r in 1..$Rounds) {
  while (-not (Test-Path (Join-Path $Root "go-$r"))) { Start-Sleep -Milliseconds 2 }
  $won = Enter-RunLock -Root $Root
  Set-Content (Join-Path $Root "result-$r-$Tag.txt") "$won"
}
# Stay alive until the parent has read every result: a winner that exits makes its lock look
# stale to a racer that is still deciding, which would be a harness artifact, not a bug.
$until = (Get-Date).AddSeconds(30)
while (-not (Test-Path (Join-Path $Root 'finished')) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 20 }
'@ | Set-Content $child
    $procs = @(1..4 | ForEach-Object {
        Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$child`"", "`"$repo`"", "`"$root`"", "t$_", "$rounds"
      })
    $winnersPerRound = @()
    try {
      $deadline = (Get-Date).AddSeconds(60)
      while (@(Get-ChildItem $root -Filter 'ready-*').Count -lt 4 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
      foreach ($r in 1..$rounds) {
        '999999' | Set-Content "$root\run.lock"   # a stale lock: no process has this pid
        New-Item -ItemType File "$root\go-$r" | Out-Null   # release all racers at once
        $deadline = (Get-Date).AddSeconds(60)
        while (@(Get-ChildItem $root -Filter "result-$r-*.txt").Count -lt 4 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 20 }
        $winnersPerRound += @(Get-ChildItem $root -Filter "result-$r-*.txt" | Where-Object { (Get-Content $_.FullName -Raw).Trim() -eq 'True' }).Count
      }
    } finally {
      New-Item -ItemType File "$root\finished" -Force | Out-Null
      $procs | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
      $procs | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    ($winnersPerRound -join ',') | Should -Be ((1..$rounds | ForEach-Object { 1 }) -join ',')
  }
  It 'returns false and logs a WARN, without throwing, when a stale lock cannot be deleted' {
    Initialize-SetupLog -LogDirectory "$root\Logs"
    '999999' | Set-Content "$root\run.lock"
    # An open handle without FileShare.Delete makes File.Delete fail with a sharing violation.
    $holder = [IO.File]::Open("$root\run.lock", 'Open', 'Read', 'Read')
    try {
      $script:entered = 'not run'
      { $script:entered = Enter-RunLock -Root $root } | Should -Not -Throw
      $script:entered | Should -BeFalse
    } finally { $holder.Dispose() }
    (Get-Content "$root\Logs\setup.log" -Raw) | Should -Match '\[WARN\] could not take run\.lock'
    Test-Path "$root\run.lock.$PID.tmp" | Should -BeFalse
    Enter-RunLock -Root $root | Should -BeTrue   # and it recovers once the file is free
  }
  It 'Exit-RunLock removes a lock that holds our pid' {
    Enter-RunLock -Root $root | Should -BeTrue
    Exit-RunLock -Root $root
    Test-Path "$root\run.lock" | Should -BeFalse
  }
  It 'Exit-RunLock leaves a lock that holds another pid' {
    '4242' | Set-Content "$root\run.lock"
    Exit-RunLock -Root $root
    Test-Path "$root\run.lock" | Should -BeTrue
  }
  It 'Exit-RunLock never throws: no lock, garbage lock, or an unreadable lock' {
    { Exit-RunLock -Root $root } | Should -Not -Throw
    'abc' | Set-Content "$root\run.lock"; { Exit-RunLock -Root $root } | Should -Not -Throw
    $lock = [IO.File]::Open("$root\run.lock", 'Open', 'Read', 'None')
    try { { Exit-RunLock -Root $root 3>$null } | Should -Not -Throw } finally { $lock.Dispose() }
  }
}
