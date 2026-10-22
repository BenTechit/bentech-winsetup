# tests/Runner.Tests.ps1
BeforeAll {
  foreach ($f in 'Common\StepResult','Common\Logging','Common\Activity','Common\Process','State\State','Engine\Reboot','Engine\Runner','Steps\Office','UI\StartScreen') { . "$PSScriptRoot\..\src\$f.ps1" }
  function New-Ctx([string[]]$plan) {
    $root = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory "$root\Logs" -Force | Out-Null
    $st = New-RunState -Machine @{} -Choices @{} -Plan $plan -Version 'v'
    $cfg = [pscustomobject]@{ caps = [pscustomobject]@{ maxReboots = 2; maxStepAttempts = 3 } }
    New-SetupContext -Config $cfg -State $st -Root $root -ScriptPath "$root\setup.ps1"
  }
  $script:cat = @(@{Id='a';Title='A';Function='Step-A'}, @{Id='b';Title='B';Function='Step-B'})
}
Describe 'Invoke-SetupRun' {
  BeforeEach { $script:calls = @(); $script:restarts = 0; $script:rs = { $script:restarts++ } }
  It 'runs in order and completes' {
    function Step-A { param($Context) $script:calls += 'a'; New-StepResult -Status Done }
    function Step-B { param($Context) $script:calls += 'b'; New-StepResult -Status Skipped -Message 'n/a' }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $calls -join '' | Should -Be 'ab'; $c.State.Steps.b.Status | Should -Be 'Skipped'
  }
  It 'saves running + attempt before invoking' {
    function Step-A { param($Context) $d = Get-Content "$($Context.Root)\state.json" -Raw | ConvertFrom-Json; $script:seen = $d.Steps.a; New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $seen.Status | Should -Be 'running'; $seen.Attempts | Should -Be 1
  }
  It 'turns an exception into Failed and continues' {
    function Step-A { param($Context) throw 'boom' }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Match 'boom'; $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'fails a step stuck running at the attempt cap without invoking it' {
    function Step-A { param($Context) $script:calls += 'a'; New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.Steps.a.Status = 'running'; $c.State.Steps.a.Attempts = 3
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $calls | Should -BeNullOrEmpty; $c.State.Steps.a.Message | Should -Be 'attempt cap reached'
  }
  It 'loops on Continue without reboot' {
    $script:n = 0; function Step-A { param($Context) $script:n++; if ($script:n -lt 3) { New-StepResult -Status Continue } else { New-StepResult -Status Done } }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $n | Should -Be 3; $c.State.Steps.a.Status | Should -Be 'Done'
  }
  It 'reboots on Continue+Now and leaves the step pending' {
    function Step-A { param($Context) New-StepResult -Status Continue -Reboot Now }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Rebooting'
    $restarts | Should -Be 1; $c.State.Steps.a.Status | Should -Be 'pending'; $c.State.RebootCount | Should -Be 1
  }
  It 'fails the step when the reboot cap is reached' {
    function Step-A { param($Context) New-StepResult -Status Continue -Reboot Now }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.RebootCount = 2
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $restarts | Should -Be 0; $c.State.RebootCapHit | Should -BeTrue; $c.State.Steps.a.Message | Should -Be 'reboot cap reached'
  }
}
Describe 'Test-PendingReboot' {
  It 'any signal' { Test-PendingReboot -Signals @{CbsRebootPending=$false;WuRebootRequired=$false;PendingFileRename=$false;ComputerRenamePending=$true} | Should -BeTrue }
  It 'none' { Test-PendingReboot -Signals @{CbsRebootPending=$false;WuRebootRequired=$false;PendingFileRename=$false;ComputerRenamePending=$false} | Should -BeFalse }
}

# ---- Controller decisions (beyond the brief's tests) ----

Describe 'Invoke-SetupRun results and robustness' {
  BeforeEach { $script:calls = @(); $script:restarts = 0; $script:rs = { $script:restarts++ } }
  It 'stores (no details) when a Skipped or Failed step gives no message' {
    function Step-A { param($Context) New-StepResult -Status Skipped }
    function Step-B { param($Context) New-StepResult -Status Failed }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $c.State.Steps.a.Message | Should -Be '(no details)'; $c.State.Steps.b.Message | Should -Be '(no details)'
  }
  It 'keeps an empty message on a Done step' {
    function Step-A { param($Context) New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done -Message 'ok' }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $c.State.Steps.a.Message | Should -Be ''; $c.State.Steps.b.Message | Should -Be 'ok'
  }
  It 'fails a step whose function does not exist, and continues' {
    function Step-B { param($Context) New-StepResult -Status Done }
    $missing = @(@{Id='a';Title='A';Function='Step-DoesNotExist'}, @{Id='b';Title='B';Function='Step-B'})
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $missing -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'step function not found: Step-DoesNotExist'
    $c.State.Steps.a.Attempts | Should -Be 0
    $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'fails a plan id that has no catalog entry, and continues' {
    function Step-A { param($Context) New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','zz','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $c.State.Steps.zz.Status | Should -Be 'Failed'; $c.State.Steps.zz.Message | Should -Be 'step not in catalog: zz'
    $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'skips a plan id with no step entry instead of crashing' {
    function Step-A { param($Context) $script:calls += 'a'; New-StepResult -Status Done }
    function Step-B { param($Context) $script:calls += 'b'; New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.Steps.Remove('a')
    { Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 } | Should -Not -Throw
    $calls -join '' | Should -Be 'b'
  }
  It 'fails a step that keeps asking to continue after 50 rounds, and continues' {
    $script:n = 0; function Step-A { param($Context) $script:n++; New-StepResult -Status Continue }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $n | Should -Be 50
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'step kept asking to continue'
    $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'resets the attempts on Continue, so each round starts at attempt 1' {
    $script:n = 0; function Step-A { param($Context) $script:n++; if ($script:n -lt 3) { New-StepResult -Status Continue -Message "round $script:n" } else { New-StepResult -Status Done } }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $c.State.Steps.a.Attempts | Should -Be 1
  }
  It 'runs a step again after a crash below the attempt cap' {
    function Step-A { param($Context) $script:calls += 'a'; New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.Steps.a.Status = 'running'; $c.State.Steps.a.Attempts = 2
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $calls -join '' | Should -Be 'a'; $c.State.Steps.a.Status | Should -Be 'Done'; $c.State.Steps.a.Attempts | Should -Be 3
  }
  It 'appends Notes and Errors to the State, merges Data into the step, and saves them' {
    function Step-A { param($Context) New-StepResult -Status Done -Notes @('n1', 'n2') -Errors @('e1') -Data @{ k = 'v' } }
    function Step-B { param($Context) New-StepResult -Status Failed -Message 'broke' -Notes @('n3') }
    $c = New-Ctx @('a','b'); $c.State.Notes = @('old'); $c.State.Steps.a.Data = @{ keep = 1 }
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    @($c.State.Notes) -join ',' | Should -Be 'old,n1,n2,n3'
    @($c.State.Errors) -join ',' | Should -Be 'e1'   # a Failed message is not copied into Errors
    $c.State.Steps.a.Data.k | Should -Be 'v'; $c.State.Steps.a.Data.keep | Should -Be 1
    $disk = Read-RunState -Root $c.Root
    @($disk.Notes) -join ',' | Should -Be 'old,n1,n2,n3'; @($disk.Errors) -join ',' | Should -Be 'e1'
    $disk.Steps.a.Data.k | Should -Be 'v'; $disk.Steps.b.Status | Should -Be 'Failed'
  }
  It 'records the result of a step that also leaks other output' {
    function Step-A { param($Context) 'stray output'; 42; New-StepResult -Status Done -Message 'ok' }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $c.State.Steps.a.Status | Should -Be 'Done'; $c.State.Steps.a.Message | Should -Be 'ok'
  }
  It 'fails a step that returns no result' {
    function Step-A { param($Context) }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'step returned no valid result'
  }
}

Describe 'Invoke-SetupRun default catalog' {
  BeforeAll { . "$PSScriptRoot\..\src\Engine\Catalog.ps1" }
  It 'uses $script:StepCatalog when -Catalog is not given (as the entry point calls it)' {
    function Invoke-StepPrepare { param($Context) New-StepResult -Status Done -Message 'prepared' }
    $c = New-Ctx @('prepare','bitlocker')
    Invoke-SetupRun -Context $c -RestartAction { } -CountdownSeconds 0 | Should -Be 'Completed'
    $c.State.Steps.prepare.Status | Should -Be 'Done'; $c.State.Steps.prepare.Message | Should -Be 'prepared'
    $c.State.Steps.bitlocker.Message | Should -Be 'step function not found: Invoke-StepBitLocker'
  }
}

Describe 'Invoke-SetupRun reboots' {
  BeforeEach { $script:calls = @(); $script:restarts = 0; $script:rs = { $script:restarts++ } }
  It 'reboots after Done + Now without running the next step' {
    function Step-A { param($Context) New-StepResult -Status Done -Reboot Now }
    function Step-B { param($Context) $script:calls += 'b'; New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Rebooting'
    $restarts | Should -Be 1; $calls | Should -BeNullOrEmpty
    $c.State.Steps.a.Status | Should -Be 'Done'; $c.State.Steps.b.Status | Should -Be 'pending'
    (Read-RunState -Root $c.Root).Steps.a.Status | Should -Be 'Done'
  }
  It 'moves on to the next step when the cap blocks a reboot after Done + Now' {
    function Step-A { param($Context) New-StepResult -Status Done -Reboot Now -Message 'renamed' }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.RebootCount = 2
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $restarts | Should -Be 0; $c.State.RebootCapHit | Should -BeTrue
    $c.State.Steps.a.Status | Should -Be 'Done'; $c.State.Steps.a.Message | Should -Be 'renamed'
    $c.State.Steps.b.Status | Should -Be 'Done'
  }
}

Describe 'Invoke-SetupRun OnProgress' {
  BeforeEach { $script:restarts = 0; $script:rs = { $script:restarts++ }; $script:progress = 0 }
  It 'is called after every saved transition and its output never leaks into the result' {
    function Step-A { param($Context) New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 -OnProgress { $script:progress++; 'noise' } | Should -Be 'Completed'
    $progress | Should -Be 4   # a running, a Done, b running, b Done
  }
  It 'logs and ignores an OnProgress that throws' {
    function Step-A { param($Context) New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Initialize-SetupLog -LogDirectory $c.LogDir
    try {
      Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 -OnProgress { throw 'screen broke' } | Should -Be 'Completed'
    } finally { $script:SetupLogPath = $null }
    $c.State.Steps.a.Status | Should -Be 'Done'; $c.State.Steps.b.Status | Should -Be 'Done'
    Get-Content (Join-Path $c.LogDir 'setup.log') -Raw | Should -Match 'screen broke'
  }
}

Describe 'Activity feed and NOW state from the runner' {
  BeforeEach { $script:act = New-Object System.Collections.ArrayList; Mock Add-SetupActivity { [void]$script:act.Add($Text) } }
  It 'writes "`<Title`> started" once and the final result once, nothing for Continue' {   # `< `> : a literal name, not a Pester template
    $script:n = 0; function Step-A { param($Context) $script:n++; if ($script:n -lt 3) { New-StepResult -Status Continue -Message 'round' } else { New-StepResult -Status Done -Message 'all good' } }
    function Step-B { param($Context) New-StepResult -Status Skipped -Message 'n/a' }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction { } -CountdownSeconds 0 | Out-Null
    @($act) | Should -Be @('A started', 'A done - all good', 'B started', 'B skipped - n/a')
  }
  It 'writes FAILED with the reason, also for the attempt cap' {
    function Step-A { param($Context) throw 'boom' }; function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.Steps.b.Status = 'running'; $c.State.Steps.b.Attempts = 3; $c.State.Steps.b.StartedAt = '2026-10-20T10:00:00'
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction { } -CountdownSeconds 0 | Out-Null
    $act | Should -Contain 'A FAILED - boom'; $act | Should -Contain 'B FAILED - attempt cap reached'
  }
  It 'no started line when the step already ran before (resume)' {
    function Step-A { param($Context) New-StepResult -Status Done }; function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.Steps.a.StartedAt = '2026-10-20T10:00:00'
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction { } -CountdownSeconds 0 | Out-Null
    $act | Should -Not -Contain 'A started'; $act | Should -Contain 'A done'
  }
  It 'clears the NOW state before and after every step' {
    function Step-A { param($Context) $script:seenA = (Get-SetupNow).SubTitle; Set-SetupNow -SubTitle 'tool A'; New-StepResult -Status Done }
    function Step-B { param($Context) $script:seenB = (Get-SetupNow).SubTitle; New-StepResult -Status Done }
    Set-SetupNow -SubTitle 'left over'; $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction { } -CountdownSeconds 0 | Out-Null
    $seenA | Should -BeNullOrEmpty; $seenB | Should -BeNullOrEmpty; (Get-SetupNow).SubTitle | Should -BeNullOrEmpty
  }
  It 'Invoke-ControlledReboot writes "Restarting (restart N)" after the count is saved' {
    $c = New-Ctx @('a'); $c.State.RebootCount = 1
    Mock Add-SetupActivity { [void]$script:act.Add(@($Text, (Read-RunState -Root $c.Root).RebootCount)) }
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { } | Should -BeTrue
    $act[0][0] | Should -Be 'Restarting (restart 2)'; $act[0][1] | Should -Be 2
  }
}

Describe 'Invoke-ControlledReboot' {
  BeforeEach { $script:restarts = 0 }
  It 'saves the incremented RebootCount before calling the restart action' {
    $c = New-Ctx @('a')
    $action = { $script:restarts++; $script:countOnDisk = (Read-RunState -Root $c.Root).RebootCount }
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $action | Should -BeTrue
    $restarts | Should -Be 1; $countOnDisk | Should -Be 1; $c.State.RebootCount | Should -Be 1
  }
  It 'at the cap: sets RebootCapHit, saves, and does not restart' {
    $c = New-Ctx @('a'); $c.State.RebootCount = 2
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { $script:restarts++ } | Should -BeFalse
    $restarts | Should -Be 0; $c.State.RebootCount | Should -Be 2
    $disk = Read-RunState -Root $c.Root; $disk.RebootCapHit | Should -BeTrue; $disk.RebootCount | Should -Be 2
  }
  It 'shows the countdown once per second only when CountdownSeconds is above zero' {
    Mock Write-Host {}
    Mock Start-Sleep {}
    $c = New-Ctx @('a')
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { } | Out-Null
    Should -Invoke Write-Host -Times 0 -Exactly
    Invoke-ControlledReboot -Context $c -CountdownSeconds 3 -RestartAction { } | Out-Null
    Should -Invoke Write-Host -Times 3 -Exactly
    Should -Invoke Write-Host -Times 3 -Exactly -ParameterFilter { $ForegroundColor -eq 'White' -and $BackgroundColor -eq 'Black' }
    Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'Restarting in 3 s ...' }
    Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'Restarting in 1 s ...' }
    Should -Invoke Start-Sleep -Times 3 -Exactly
  }
}

# Task 13: every controlled restart first waits for a background Microsoft 365 setup (spec 4.6).
Describe 'Invoke-ControlledReboot and Office' {
  It 'waits for Office before counting and restarting' {
    $script:order = New-Object System.Collections.ArrayList
    Mock Wait-OfficeBackground { [void]$script:order.Add("wait $($Context.State.RebootCount) $Purpose"); @{ Outcome = 'Exited'; ExitCode = 0 } }
    $c = New-Ctx @('office'); Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { [void]$script:order.Add('restart') } | Should -BeTrue
    @($script:order) | Should -Be @('wait 0 Restart', 'restart')
    $c.State.RebootCount | Should -Be 1
  }
  It 'never waits when the restart is refused (cap, no resume task)' {
    Mock Wait-OfficeBackground { @{ Outcome = 'None' } }
    $c = New-Ctx @('office'); $c.State.RebootCount = 2; Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { } | Should -BeFalse
    $c2 = New-Ctx @('office'); $c2.State.ResumeTaskMissing = $true; Invoke-ControlledReboot -Context $c2 -CountdownSeconds 0 -RestartAction { } | Should -BeFalse
    Should -Invoke Wait-OfficeBackground -Times 0 -Exactly
  }
  It 'still restarts after Office was killed at its deadline' { Mock Wait-OfficeBackground { @{ Outcome = 'Killed' } }; $script:restarts = 0; $c = New-Ctx @('office'); Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { $script:restarts++ } | Should -BeTrue; $script:restarts | Should -Be 1 }
  It 'still restarts when the Office wait fails unexpectedly' {
    Mock Wait-OfficeBackground { throw 'unexpected' }; Mock Write-SetupLog { }
    $script:restarts = 0; $c = New-Ctx @('office')
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { $script:restarts++ } | Should -BeTrue
    $script:restarts | Should -Be 1
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
  }
  It 'without a background Office the restart does not wait (the real wait is a no-op)' {
    Mock Wait-SetupDelay { throw 'must not wait' }; Mock Get-Process { throw 'must not look' }
    $script:restarts = 0; $c = New-Ctx @('a')
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { $script:restarts++ } | Should -BeTrue
    $script:restarts | Should -Be 1
  }
}

# Ruling R10: a restart must never fail silently. Every test below injects BOTH restart actions (or
# mocks Start-Process with WINDIR pointed at TestDrive), so no test can ever reach a real restart.
Describe 'Restart failures (R10)' {
  BeforeEach {
    $script:restarts = 0; $script:fallbacks = 0
    $script:throwRestart = { $script:restarts++; throw 'Access is denied' }
    $script:okFallback = { $script:fallbacks++ }
    $script:badFallback = { $script:fallbacks++; throw 'shutdown.exe exited with code 5' }
  }
  It 'Invoke-ControlledReboot: the fallback restarts when the primary action throws' {
    $c = New-Ctx @('a')
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $throwRestart -FallbackRestartAction $okFallback | Should -BeTrue
    $restarts | Should -Be 1; $fallbacks | Should -Be 1
    $c.State.RebootCount | Should -Be 1; @($c.State.Errors).Count | Should -Be 0; $c.State.RebootCapHit | Should -BeFalse
  }
  It 'Invoke-ControlledReboot: both fail -> Errors gets "Restart failed:", saved, no cap flag, count kept' {
    $c = New-Ctx @('a')
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $throwRestart -FallbackRestartAction $badFallback | Should -BeFalse
    $restarts | Should -Be 1; $fallbacks | Should -Be 1
    @($c.State.Errors | Where-Object { $_ -like 'Restart failed:*' }).Count | Should -Be 1
    $c.State.RebootCapHit | Should -BeFalse; $c.State.RebootCount | Should -Be 1
    $disk = Read-RunState -Root $c.Root
    @($disk.Errors | Where-Object { $_ -like 'Restart failed:*' }).Count | Should -Be 1; $disk.RebootCount | Should -Be 1
  }
  It 'Invoke-SetupRun: Continue+Now, primary throws, fallback succeeds -> Rebooting' {
    function Step-A { param($Context) New-StepResult -Status Continue -Reboot Now }
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $throwRestart -FallbackRestartAction $okFallback -CountdownSeconds 0 | Should -Be 'Rebooting'
    $fallbacks | Should -Be 1; $c.State.Steps.a.Status | Should -Be 'pending'; $c.State.RebootCount | Should -Be 1
  }
  It 'Invoke-SetupRun: Continue+Now, both fail -> step Failed(restart failed), error recorded, no cap flag' {
    function Step-A { param($Context) New-StepResult -Status Continue -Reboot Now }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $throwRestart -FallbackRestartAction $badFallback -CountdownSeconds 0 | Should -Be 'Completed'
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'restart failed'
    @($c.State.Errors | Where-Object { $_ -like 'Restart failed:*' }).Count | Should -Be 1
    $c.State.RebootCapHit | Should -BeFalse
    $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'the default fallback runs shutdown.exe /r /t 5 /f and treats any exit code other than 0/1115/1190 as failure' {
    $savedWindir = $env:windir
    $env:windir = Join-Path $TestDrive 'fake-windows'   # even an unmocked Start-Process cannot find shutdown.exe
    try {
      Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
      $c = New-Ctx @('a')
      Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $throwRestart | Should -BeTrue
      Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
        $FilePath -eq (Join-Path $TestDrive 'fake-windows\System32\shutdown.exe') -and (@($ArgumentList) -join ' ') -eq '/r /t 5 /f' -and $Wait -and $PassThru -and $NoNewWindow
      }
      Mock Start-Process { [pscustomobject]@{ ExitCode = 5 } }   # ERROR_ACCESS_DENIED
      $c = New-Ctx @('a')
      Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $throwRestart | Should -BeFalse
      @($c.State.Errors | Where-Object { $_ -like 'Restart failed:*code 5*' }).Count | Should -Be 1
    } finally { $env:windir = $savedWindir }
  }
  It 'Invoke-SetupRun: shutdown.exe exit code <Code> (<Meaning>) counts as a restart' -ForEach @(
    @{ Code = 1190; Meaning = 'ERROR_SHUTDOWN_IS_SCHEDULED' }
    @{ Code = 1115; Meaning = 'ERROR_SHUTDOWN_IN_PROGRESS' }
  ) {
    function Step-A { param($Context) New-StepResult -Status Continue -Reboot Now }
    $savedWindir = $env:windir
    $env:windir = Join-Path $TestDrive 'fake-windows'   # even an unmocked Start-Process cannot find shutdown.exe
    try {
      $script:mockExitCode = $Code
      Mock Start-Process { [pscustomobject]@{ ExitCode = $script:mockExitCode } }
      $c = New-Ctx @('a','b')
      Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $throwRestart -CountdownSeconds 0 | Should -Be 'Rebooting'
      Should -Invoke Start-Process -Times 1 -Exactly
      @($c.State.Errors).Count | Should -Be 0
      $c.State.Steps.a.Status | Should -Be 'pending'; $c.State.RebootCapHit | Should -BeFalse
    } finally { $env:windir = $savedWindir }
  }
  It 'the default restart action throws on failure (Restart-Computer -Force -ErrorAction Stop)' {
    $ast = (Get-Command Invoke-ControlledReboot).ScriptBlock.Ast
    if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $ast = $ast.Body }
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RestartAction' }
    $param.DefaultValue.Extent.Text | Should -Be '{ Restart-Computer -Force -ErrorAction Stop }'
  }
}

# Ruling R15: without the logon task a restart ends the run for good, so no restart is ever made.
# Both restart actions are injected, so no test can reach a real restart.
Describe 'No restart without a resume task (R15)' {
  BeforeEach {
    $script:restarts = 0; $script:fallbacks = 0
    $script:countRestart = { $script:restarts++ }
    $script:countFallback = { $script:fallbacks++ }
  }
  It 'Invoke-ControlledReboot: neither restart action runs, RebootCount is unchanged, the error is recorded and saved, result is $false' {
    $c = New-Ctx @('a'); $c.State.ResumeTaskMissing = $true; $c.State.RebootCount = 1
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $countRestart -FallbackRestartAction $countFallback | Should -BeFalse
    $restarts | Should -Be 0; $fallbacks | Should -Be 0
    $c.State.RebootCount | Should -Be 1
    $c.State.RebootCapHit | Should -BeFalse
    @($c.State.Errors | Where-Object { $_ -eq 'Restart skipped: no resume task' }).Count | Should -Be 1
    $disk = Read-RunState -Root $c.Root
    $disk.RebootCount | Should -Be 1
    @($disk.Errors | Where-Object { $_ -eq 'Restart skipped: no resume task' }).Count | Should -Be 1
  }
  It 'Invoke-ControlledReboot: asked twice, the error is added only once' {
    $c = New-Ctx @('a'); $c.State.ResumeTaskMissing = $true
    1..2 | ForEach-Object { Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $countRestart -FallbackRestartAction $countFallback | Should -BeFalse }
    $restarts | Should -Be 0; $fallbacks | Should -Be 0
    @($c.State.Errors | Where-Object { $_ -eq 'Restart skipped: no resume task' }).Count | Should -Be 1
    $c.State.RebootCount | Should -Be 0
  }
  It 'Invoke-ControlledReboot: keeps the errors that were already there' {
    $c = New-Ctx @('a'); $c.State.ResumeTaskMissing = $true; $c.State.Errors = @('Could not register the resume task')
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $countRestart | Should -BeFalse
    @($c.State.Errors).Count | Should -Be 2
    $c.State.Errors | Should -Contain 'Could not register the resume task'
  }
  It 'Invoke-ControlledReboot: logs an ERROR' {
    $c = New-Ctx @('a'); $c.State.ResumeTaskMissing = $true
    Initialize-SetupLog -LogDirectory $c.LogDir
    try { Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $countRestart | Out-Null } finally { $script:SetupLogPath = $null }
    Get-Content (Join-Path $c.LogDir 'setup.log') -Raw | Should -Match '\[ERROR\] Restart skipped'
  }
  It 'Invoke-ControlledReboot: restarts as before when the flag is absent or false' {
    $c = New-Ctx @('a')
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $countRestart | Should -BeTrue
    $c.State.ResumeTaskMissing = $false
    Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction $countRestart | Should -BeTrue
    $restarts | Should -Be 2; @($c.State.Errors).Count | Should -Be 0
  }
  It 'Invoke-SetupRun: Continue+Now ends the step Failed(restart failed), the run carries on and completes without rebooting' {
    function Step-A { param($Context) New-StepResult -Status Continue -Reboot Now }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.ResumeTaskMissing = $true
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $countRestart -FallbackRestartAction $countFallback -CountdownSeconds 0 | Should -Be 'Completed'
    $restarts | Should -Be 0; $fallbacks | Should -Be 0
    $c.State.RebootCount | Should -Be 0; $c.State.RebootCapHit | Should -BeFalse
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'restart failed'
    $c.State.Steps.b.Status | Should -Be 'Done'
    @($c.State.Errors | Where-Object { $_ -eq 'Restart skipped: no resume task' }).Count | Should -Be 1
  }
}

# Review round 1. The leak tests carry a runaway bound (the step returns Done after 20 calls,
# OnProgress throws after 50) so that, before the fix, a leaked continue cannot loop forever.
Describe 'Flow-control leaks, mixed results and interruptions' {
  BeforeEach { $script:restarts = 0; $script:rs = { $script:restarts++ }; $script:n = 0; $script:progress = 0; $script:snap = $null }
  It 'fails a step that uses break outside a loop, and does not leave it running' {
    function Step-A { param($Context) $script:n++; if ($script:n -gt 20) { return New-StepResult -Status Done -Message 'runaway' }; break }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $n | Should -Be 1
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'step used break/continue outside a loop'
    (Read-RunState -Root $c.Root).Steps.a.Status | Should -Be 'Failed'
    $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'fails a step that uses continue outside a loop (inside ForEach-Object), invoking it once' {
    function Step-A { param($Context) $script:n++; if ($script:n -gt 20) { return New-StepResult -Status Done -Message 'runaway' }; 1 | ForEach-Object { continue } }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $n | Should -Be 1; $c.State.Steps.a.Attempts | Should -Be 1
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'step used break/continue outside a loop'
    $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'logs and ignores an OnProgress that uses continue outside a loop' {
    function Step-A { param($Context) $script:n++; New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b')
    Initialize-SetupLog -LogDirectory $c.LogDir
    try {
      Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 -OnProgress { $script:progress++; if ($script:progress -gt 50) { throw 'runaway' }; continue } | Should -Be 'Completed'
    } finally { $script:SetupLogPath = $null }
    $progress | Should -Be 4; $n | Should -Be 1
    $c.State.Steps.a.Status | Should -Be 'Done'; $c.State.Steps.a.Attempts | Should -Be 1; $c.State.Steps.b.Status | Should -Be 'Done'
    Get-Content (Join-Path $c.LogDir 'setup.log') -Raw | Should -Match 'break/continue'
  }
  It 'when a step emits several results, an earlier Failed wins over a later Done' {
    function Step-A { param($Context) New-StepResult -Status Failed -Message 'precheck failed'; New-StepResult -Status Done -Message 'all good' }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'precheck failed'
  }
  It 'counts each time a step is found running as an interruption and a reboot, and still runs it' {
    # The step snapshots state.json while it runs: that is what the next start finds if the machine
    # restarts mid-step.
    function Step-A { param($Context) $script:n++; $script:snap = Read-RunState -Root $Context.Root; New-StepResult -Status Done }
    $c = New-Ctx @('a'); $c.State.Steps.a.Status = 'running'; $c.State.Steps.a.Attempts = 1
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $c2 = New-SetupContext -Config $c.Config -State $script:snap -Root $c.Root -ScriptPath $c.ScriptPath
    Invoke-SetupRun -Context $c2 -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $n | Should -Be 2
    $c2.State.Steps.a.Data.Interruptions | Should -Be 2; $c2.State.RebootCount | Should -Be 2
    $c2.State.Steps.a.Status | Should -Be 'Done'
    $disk = Read-RunState -Root $c.Root; $disk.Steps.a.Data.Interruptions | Should -Be 2; $disk.RebootCount | Should -Be 2
  }
  It 'fails a step found running for the third time without invoking it' {
    function Step-A { param($Context) $script:n++; New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.Steps.a.Status = 'running'; $c.State.Steps.a.Attempts = 1; $c.State.Steps.a.Data = @{ Interruptions = 2 }
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $n | Should -Be 0
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Be 'interrupted 3 times (crash or unexpected restart)'
    $c.State.Steps.a.Data.Interruptions | Should -Be 3; $c.State.RebootCount | Should -Be 1
    $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'a Continue resets Attempts but not Interruptions, so repeated interruptions still hit the cap' {
    function Step-A { param($Context) $script:n++
      if ($script:n -eq 1) { New-StepResult -Status Continue } else { $script:snap = Read-RunState -Root $Context.Root; New-StepResult -Status Done } }
    $c = New-Ctx @('a'); $c.State.Steps.a.Status = 'running'; $c.State.Steps.a.Attempts = 1; $c.State.Steps.a.Data = @{ Interruptions = 1 }
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $snap.Steps.a.Attempts | Should -Be 1                # reset by the Continue, then this round's attempt
    $snap.Steps.a.Data.Interruptions | Should -Be 2      # untouched by the Continue
    # That round was interrupted too: the next start resumes from what was on disk during it.
    $c2 = New-SetupContext -Config $c.Config -State $snap -Root $c.Root -ScriptPath $c.ScriptPath
    Invoke-SetupRun -Context $c2 -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $n | Should -Be 2
    $c2.State.Steps.a.Status | Should -Be 'Failed'; $c2.State.Steps.a.Message | Should -Be 'interrupted 3 times (crash or unexpected restart)'
  }
}

Describe 'Get-PendingRebootSignals' {
  It 'returns the four signals as booleans without throwing (real registry)' {
    $s = Get-PendingRebootSignals
    @($s.Keys | Sort-Object) -join ',' | Should -Be 'CbsRebootPending,ComputerRenamePending,PendingFileRename,WuRebootRequired'
    foreach ($v in $s.Values) { $v | Should -BeOfType [bool] }
  }
  It 'reports each signal from the registry' {
    Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*Component Based Servicing\RebootPending' }
    Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*WindowsUpdate\Auto Update\RebootRequired' }
    Mock Get-ItemProperty { [pscustomobject]@{ PendingFileRenameOperations = [string[]]@('\??\C:\Windows\Temp\x.tmp', '') } } -ParameterFilter { $Name -eq 'PendingFileRenameOperations' }
    Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'DELL-7HX2K93' } } -ParameterFilter { $LiteralPath -like '*\ComputerName\ComputerName' }
    Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'DESKTOP-AB12' } } -ParameterFilter { $LiteralPath -like '*\ComputerName\ActiveComputerName' }
    $s = Get-PendingRebootSignals
    $s.CbsRebootPending | Should -BeTrue; $s.WuRebootRequired | Should -BeTrue
    $s.PendingFileRename | Should -BeTrue; $s.ComputerRenamePending | Should -BeTrue
  }
  It 'treats missing keys and values as false and never throws' {
    Mock Test-Path { $false }
    Mock Get-ItemProperty { throw 'Property does not exist' }
    { Get-PendingRebootSignals } | Should -Not -Throw
    $s = Get-PendingRebootSignals
    $s.CbsRebootPending | Should -BeFalse; $s.WuRebootRequired | Should -BeFalse
    $s.PendingFileRename | Should -BeFalse; $s.ComputerRenamePending | Should -BeFalse
  }
  It 'ignores an all-empty rename list and a name that differs only in case' {
    Mock Test-Path { $false }
    Mock Get-ItemProperty { [pscustomobject]@{ PendingFileRenameOperations = [string[]]@('', '') } } -ParameterFilter { $Name -eq 'PendingFileRenameOperations' }
    Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'DELL-7HX2K93' } } -ParameterFilter { $LiteralPath -like '*\ComputerName\ComputerName' }
    Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'dell-7hx2k93' } } -ParameterFilter { $LiteralPath -like '*\ComputerName\ActiveComputerName' }
    $s = Get-PendingRebootSignals
    $s.PendingFileRename | Should -BeFalse; $s.ComputerRenamePending | Should -BeFalse
  }
}

# Repair Task 1 (repair spec 5): only the signals that break servicing block DISM and SFC.
Describe 'Get-ServicingRebootSignals' {
  It 'returns the six signals as booleans without throwing (real registry, read only)' {
    $s = Get-ServicingRebootSignals
    @($s.Keys | Sort-Object) -join ',' | Should -Be 'CbsPackagesPending,CbsRebootPending,ComputerRenamePending,PendingFileRename,PendingXml,WuRebootRequired'
    foreach ($v in $s.Values) { $v | Should -BeOfType [bool] }
  }
  It 'reads the PackagesPending key and WinSxS\pending.xml besides the four reboot signals' {
    Mock Test-Path { $false }
    Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*Component Based Servicing\PackagesPending' }
    Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*\WinSxS\pending.xml' -and $PathType -eq 'Leaf' }
    Mock Get-ItemProperty { throw 'Property does not exist' }
    $s = Get-ServicingRebootSignals
    $s.CbsPackagesPending | Should -BeTrue; $s.PendingXml | Should -BeTrue
    $s.CbsRebootPending | Should -BeFalse; $s.WuRebootRequired | Should -BeFalse; $s.PendingFileRename | Should -BeFalse; $s.ComputerRenamePending | Should -BeFalse
    Should -Invoke Test-Path -ParameterFilter { $LiteralPath -eq (Join-Path $env:windir 'WinSxS\pending.xml') }
  }
  It 'passes the four reboot signals through' {
    Mock Get-PendingRebootSignals { @{ CbsRebootPending = $true; WuRebootRequired = $true; PendingFileRename = $true; ComputerRenamePending = $true } }
    Mock Test-Path { $false }
    $s = Get-ServicingRebootSignals
    $s.CbsRebootPending | Should -BeTrue; $s.WuRebootRequired | Should -BeTrue; $s.PendingFileRename | Should -BeTrue; $s.ComputerRenamePending | Should -BeTrue
    $s.CbsPackagesPending | Should -BeFalse; $s.PendingXml | Should -BeFalse
  }
  It 'never throws: a failed read is no signal' {
    Mock Get-PendingRebootSignals { throw 'registry gone' }
    Mock Test-Path { throw 'access denied' }
    { Get-ServicingRebootSignals } | Should -Not -Throw
    $s = Get-ServicingRebootSignals
    @($s.Values | Where-Object { $_ -ne $false }).Count | Should -Be 0; $s.Count | Should -Be 6
  }
  It 'logs a failed read as ASCII: a localized (Hebrew) message never reaches setup.log' {
    Mock Get-PendingRebootSignals { throw 'שגיאה ברישום' }
    Mock Test-Path { $false }
    Mock Write-SetupLog { }
    $null = Get-ServicingRebootSignals
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Data.error -ceq '????? ??????' }
  }
}

Describe 'Test-ServicingRebootPending' {
  BeforeAll {
    function New-Signals { param([string]$On) $s = @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $false; ComputerRenamePending = $false }; if ($On) { $s[$On] = $true }; $s }
  }
  It '<On> blocks servicing' -ForEach @(@{ On = 'CbsRebootPending' }, @{ On = 'CbsPackagesPending' }, @{ On = 'PendingXml' }, @{ On = 'WuRebootRequired' }) {
    Test-ServicingRebootPending -Signals (New-Signals $On) | Should -BeTrue
  }
  It '<On> alone is a note only, never a block' -ForEach @(@{ On = 'PendingFileRename' }, @{ On = 'ComputerRenamePending' }, @{ On = '' }) {
    Test-ServicingRebootPending -Signals (New-Signals $On) | Should -BeFalse
  }
}

Describe 'New-SetupContext' {
  It 'builds the Context shape' {
    $cfg = [pscustomobject]@{ caps = $null }; $st = @{ Plan = @() }
    $c = New-SetupContext -Config $cfg -State $st -Root 'C:\BenTech\Setup' -ScriptPath 'C:\BenTech\Setup\setup.ps1'
    @($c.Keys | Sort-Object) -join ',' | Should -Be 'Config,DownloadDir,LogDir,Root,ScriptPath,State,StatePath'
    $c.Root | Should -Be 'C:\BenTech\Setup'; $c.LogDir | Should -Be 'C:\BenTech\Setup\Logs'
    $c.DownloadDir | Should -Be 'C:\BenTech\Setup\Downloads'; $c.StatePath | Should -Be 'C:\BenTech\Setup\state.json'
    $c.ScriptPath | Should -Be 'C:\BenTech\Setup\setup.ps1'
    [object]::ReferenceEquals($c.State, $st) | Should -BeTrue; [object]::ReferenceEquals($c.Config, $cfg) | Should -BeTrue
  }
}
