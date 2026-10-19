# tests/Entry.Tests.ps1
# Task 17: Start-BenTechSetup, the entry point of the bundled setup.ps1.
#
# SAFETY: this runs on Ben's real PC. For real, Start-BenTechSetup takes the run lock, starts a transcript,
# reads and writes state.json, shows console screens, runs every setup step, removes the resume task and
# runs Windows Update rounds. Here every call passes -Root $TestDrive (never C:\BenTech\Setup), -NoWait
# and a recording -CrashScreen, and BeforeEach mocks every collaborator it calls: the logger, the
# transcript, Write-Host, the lock, config and state I/O, machine detection, the screens, the plan, the
# runner, the verdict, the finalization, the resume task and the Windows Update round. As a safety net,
# Register-ScheduledTask, Unregister-ScheduledTask, Restart-Computer and Start-Process throw.
BeforeAll {
  foreach ($f in 'Common\StepResult', 'Common\Logging', 'Common\Config', 'State\State', 'Detect\PcName', 'Detect\Detection',
                 'Engine\Catalog', 'Engine\Verdict', 'Engine\Reboot', 'Engine\Runner', 'Report\Report',
                 'Steps\Prepare', 'Steps\WindowsUpdate', 'Steps\Finalize',
                 'UI\StartScreen', 'UI\ProgressScreen', 'UI\FinalScreen', 'Entry\Main') {
    . "$PSScriptRoot\..\src\$f.ps1"
  }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"

  # Runs the entry point against $TestDrive. The crash screen only records what it was asked to show.
  function Invoke-Entry {
    param(
      [bool]$Resume = $false,
      [bool]$WuRound = $false,
      [bool]$SearchOnly = $false,
      [string]$ResultPath = '',
      [scriptblock]$CrashScreen = { param($text) $null = $script:crashes.Add($text) }
    )
    Start-BenTechSetup -Resume $Resume -WuRound $WuRound -SearchOnly $SearchOnly -ResultPath $ResultPath -Root $TestDrive -NoWait -CrashScreen $CrashScreen
  }

  # A run state as Read-RunState returns it (only the fields the entry point reads).
  function New-FakeState {
    param([string]$RunId = 'resumed-run', [string]$FinalizeStatus = 'pending', $EndedAt = $null)
    @{ RunId = $RunId; StartedAt = '2026-10-17T09:00:00'; EndedAt = $EndedAt; Plan = @('prepare', 'finalize')
       Steps = @{ prepare = @{ Status = 'Done' }; finalize = @{ Status = $FinalizeStatus } }
       Machine = @{ IsWindows10 = $false }; PreviousRun = $null; HiddenUpdateIds = @() }
  }
}

Describe 'Start-BenTechSetup' {
  BeforeEach {
    $script:crashes = New-Object System.Collections.ArrayList
    $script:machine = @{ Manufacturer = 'Dell Inc.'; Brand = 'DELL'; IsLaptop = $true; IsVM = $false; IsWindows10 = $false
                         InstallDate = '2026-10-17T08:00:00'; NewName = 'DELL-7HX2K93' }
    $script:choices = @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'BUSINESS' }
    $script:newState = @{ RunId = 'new-run'; Plan = @('prepare', 'finalize'); PreviousRun = $null
                          Steps = @{ prepare = @{ Status = 'pending' }; finalize = @{ Status = 'Done' } } }

    Mock Initialize-SetupLog { }
    Mock Write-SetupLog { }
    Mock Start-Transcript { }
    Mock Stop-Transcript { }
    Mock Write-Host { }
    Mock Enter-RunLock { $true }
    Mock Exit-RunLock { }
    Mock Read-SetupConfig { $script:cfg }
    Mock Read-RunState { $null }
    Mock Save-RunState { }
    Mock Backup-RunState { }
    Mock Get-MachineInfo { $script:machine }
    Mock Get-UserDataBytes { [long]1024 }
    Mock Test-FreshInstall { $true }
    Mock Show-StartScreen { $script:choices }
    Mock Get-StepPlan { 'prepare'; 'winget'; 'finalize' }
    Mock New-RunState { $script:newState }
    Mock New-SetupContext { @{ Config = $Config; State = $State; Root = $Root; ScriptPath = $ScriptPath; LogDir = (Join-Path $Root 'Logs') } }
    Mock Invoke-SetupRun { 'Completed' }
    Mock Show-ProgressScreen { }
    Mock Get-RunVerdict { @{ Color = 'GREEN' } }
    Mock Show-FinalScreen { }
    Mock Complete-SetupFinalization { [pscustomobject]@{ Status = 'Done'; Message = 'Finalized' } }
    Mock Unregister-ResumeTask { }
    Mock Invoke-WuRound { }
    Mock Disable-ConsoleQuickEdit { $true }       # never changes the console the tests run in
    Mock Register-ScheduledTask { throw 'blocked: Register-ScheduledTask' }
    Mock Unregister-ScheduledTask { throw 'blocked: Unregister-ScheduledTask' }
    Mock Restart-Computer { throw 'blocked: Restart-Computer' }
    Mock Start-Process { throw 'blocked: Start-Process' }
  }

  AfterEach {
    Remove-Variable -Name SetupVersion -Scope Script -ErrorAction SilentlyContinue
  }

  Context 'start-up and the run lock' {
    It 'initializes the log in Root\Logs, starts a transcript there and logs the start' {
      Invoke-Entry | Out-Null
      Should -Invoke Initialize-SetupLog -Times 1 -Exactly -ParameterFilter { $LogDirectory -eq (Join-Path $TestDrive 'Logs') }
      Should -Invoke Start-Transcript -Times 1 -Exactly -ParameterFilter {
        (Split-Path -Parent $Path) -eq (Join-Path $TestDrive 'Logs') -and (Split-Path -Leaf $Path) -match '^transcript-\d{8}-\d{6}\.txt$' }
      Should -Invoke Write-SetupLog -ParameterFilter { $Message -eq 'BenTech Windows Setup dev starting' -and $Data.resume -eq $false }
      Should -Invoke Stop-Transcript -Times 1 -Exactly
    }
    It 'logs the bundle version when one is stamped' {
      $script:SetupVersion = '2026.10.18.9'
      Invoke-Entry -Resume $true | Out-Null
      Should -Invoke Write-SetupLog -ParameterFilter { $Message -eq 'BenTech Windows Setup 2026.10.18.9 starting' -and $Data.resume -eq $true }
    }
    It 'returns 2 and changes nothing when another run holds the lock' {
      Mock Enter-RunLock { $false }
      Invoke-Entry | Should -Be 2
      Should -Invoke Enter-RunLock -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive }
      Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'Setup is already running on this machine' }
      Should -Invoke Read-SetupConfig -Times 0 -Exactly
      Should -Invoke Read-RunState -Times 0 -Exactly
      Should -Invoke Show-StartScreen -Times 0 -Exactly
      Should -Invoke Save-RunState -Times 0 -Exactly
      Should -Invoke Invoke-SetupRun -Times 0 -Exactly
      Should -Invoke Exit-RunLock -Times 0 -Exactly    # the lock belongs to the other run
      Should -Invoke Stop-Transcript -Times 1 -Exactly
    }
    It 'goes on without a transcript when it cannot start one' {
      Mock Start-Transcript { throw 'transcript unavailable' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Invoke-SetupRun -Times 1 -Exactly
      Should -Invoke Stop-Transcript -Times 0 -Exactly
      Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Data.error -eq 'transcript unavailable' }
    }
    It 'returns exactly one [int] (nothing else leaks into the exit code)' {
      $result = @(Invoke-Entry)
      $result.Count | Should -Be 1
      $result[0] | Should -BeOfType [int]
      $result[0] | Should -Be 0
    }
  }

  Context 'first run' {
    It 'Escape on the start screen returns 0, removes a leftover resume task (R27), saves nothing and releases the lock' {
      Mock Show-StartScreen { $null }
      Mock Read-RunState { New-FakeState -RunId 'old-run' }   # an unfinished earlier run: its task may still be registered
      Invoke-Entry | Should -Be 0
      Should -Invoke Unregister-ResumeTask -Times 1 -Exactly
      # INFO is Write-SetupLog's default level, which a mock does not bind: "not WARN or ERROR".
      Should -Invoke Write-SetupLog -ParameterFilter { $Message -match 'Cancelled on the start screen' -and $Level -notin 'WARN', 'ERROR' }
      Should -Invoke Backup-RunState -Times 0 -Exactly
      Should -Invoke New-RunState -Times 0 -Exactly
      Should -Invoke Save-RunState -Times 0 -Exactly
      Should -Invoke Invoke-SetupRun -Times 0 -Exactly
      Should -Invoke Exit-RunLock -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive }
    }
    It 'builds the state from the plan, saves it, and runs it' {
      $script:SetupVersion = '2026.10.18.9'
      Invoke-Entry | Should -Be 0
      Should -Invoke Show-StartScreen -Times 1 -Exactly -ParameterFilter {
        $Machine.NewName -eq 'DELL-7HX2K93' -and $Config -eq $script:cfg -and $Version -eq '2026.10.18.9' -and $null -eq $Previous -and $IsFresh -eq $true }
      Should -Invoke Get-StepPlan -Times 1 -Exactly -ParameterFilter { $Choices.Mode -eq 'LAPTOP' -and $Machine.Brand -eq 'DELL' -and $Config -eq $script:cfg }
      Should -Invoke New-RunState -Times 1 -Exactly -ParameterFilter {
        ($Plan -join ',') -eq 'prepare,winget,finalize' -and $Version -eq '2026.10.18.9' -and $Choices.Office -eq 'BUSINESS' -and
        $Machine.Brand -eq 'DELL' -and $null -eq $Previous }
      Should -Invoke Save-RunState -Times 1 -Exactly -ParameterFilter { $State.RunId -eq 'new-run' -and $Root -eq $TestDrive }
      Should -Invoke New-SetupContext -Times 1 -Exactly -ParameterFilter {
        $State.RunId -eq 'new-run' -and $Root -eq $TestDrive -and $ScriptPath -eq (Join-Path $TestDrive 'setup.ps1') -and $Config -eq $script:cfg }
      Should -Invoke Invoke-SetupRun -Times 1 -Exactly -ParameterFilter { $Context.State.RunId -eq 'new-run' -and $null -ne $OnProgress }
      Should -Invoke Backup-RunState -Times 0 -Exactly
    }
    It 'with a finished earlier run: shows its colour, archives it, and links the new state to it' {
      $previous = New-FakeState -RunId 'old-run' -EndedAt '2026-10-17T10:00:00'
      Mock Read-RunState { $previous }
      Mock Get-RunVerdict { @{ Color = 'YELLOW' } } -ParameterFilter { $State.RunId -eq 'old-run' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Show-StartScreen -Times 1 -Exactly -ParameterFilter { $Previous.StartedAt -eq '2026-10-17T09:00:00' -and $Previous.Color -eq 'YELLOW' }
      Should -Invoke Backup-RunState -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive -and $LogDir -eq (Join-Path $TestDrive 'Logs') }
      Should -Invoke New-RunState -Times 1 -Exactly -ParameterFilter { $Previous.RunId -eq 'old-run' }
      Should -Invoke Save-RunState -Times 1 -Exactly -ParameterFilter { $State.PreviousRun.Color -eq 'YELLOW' -and $State.PreviousRun.StartedAt -eq '2026-10-17T09:00:00' }
    }
    It 'an earlier run that never ended is UNFINISHED (no verdict is computed for it)' {
      Mock Read-RunState { New-FakeState -RunId 'old-run' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Show-StartScreen -Times 1 -Exactly -ParameterFilter { $Previous.Color -eq 'UNFINISHED' }
      Should -Invoke Get-RunVerdict -Times 0 -Exactly -ParameterFilter { $State.RunId -eq 'old-run' }
      Should -Invoke Backup-RunState -Times 1 -Exactly
    }
    It 'an earlier state whose verdict cannot be computed does not stop the new run' {
      Mock Read-RunState { New-FakeState -RunId 'old-run' -EndedAt '2026-10-17T10:00:00' }
      Mock Get-RunVerdict { throw 'odd old state' } -ParameterFilter { $State.RunId -eq 'old-run' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Show-StartScreen -Times 1 -Exactly -ParameterFilter { $Previous.Color -eq 'UNKNOWN' }
      Should -Invoke Invoke-SetupRun -Times 1 -Exactly
      $crashes.Count | Should -Be 0
    }
  }

  Context 'fresh-install check' {
    It 'an empty InstallDate is not fresh' {
      $machine.InstallDate = ''
      Invoke-Entry | Should -Be 0
      Should -Invoke Show-StartScreen -Times 1 -Exactly -ParameterFilter { $IsFresh -eq $false }
      Should -Invoke Test-FreshInstall -Times 0 -Exactly
    }
    It 'an unparseable InstallDate is not fresh' {
      $machine.InstallDate = 'not a date'
      Invoke-Entry | Should -Be 0
      Should -Invoke Show-StartScreen -Times 1 -Exactly -ParameterFilter { $IsFresh -eq $false }
      Should -Invoke Test-FreshInstall -Times 0 -Exactly
    }
    It 'a failure measuring the user data is not fresh' {
      Mock Get-UserDataBytes { throw 'access denied' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Show-StartScreen -Times 1 -Exactly -ParameterFilter { $IsFresh -eq $false }
      $crashes.Count | Should -Be 0
    }
    It 'passes the parsed date, the user data and the config limits to Test-FreshInstall, and its answer (<Answer>) on' -ForEach @(
      @{ Answer = $true }, @{ Answer = $false }
    ) {
      $answer = $Answer
      Mock Test-FreshInstall { $answer }
      Invoke-Entry | Should -Be 0
      Should -Invoke Test-FreshInstall -Times 1 -Exactly -ParameterFilter {
        $InstallDate -eq [datetime]'2026-10-17T08:00:00' -and $UserDataBytes -eq 1024 -and
        $MaxAgeDays -eq $script:cfg.freshInstall.maxInstallAgeDays -and $MaxUserDataGB -eq $script:cfg.freshInstall.maxUserDataGB }
      Should -Invoke Show-StartScreen -Times 1 -Exactly -ParameterFilter { $IsFresh -eq $answer }
    }
  }

  Context 'resume' {
    It 'with no state removes the resume task and returns 0' {
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Unregister-ResumeTask -Times 1 -Exactly
      Should -Invoke Show-StartScreen -Times 0 -Exactly
      Should -Invoke Get-MachineInfo -Times 0 -Exactly
      Should -Invoke Invoke-SetupRun -Times 0 -Exactly
      Should -Invoke Save-RunState -Times 0 -Exactly
      Should -Invoke Exit-RunLock -Times 1 -Exactly
      Should -Invoke Write-SetupLog -ParameterFilter { $Message -match 'no run state' }
    }
    It 'with a state runs it again without the start screen' {
      Mock Read-RunState { New-FakeState -FinalizeStatus 'Done' }
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Read-RunState -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive }
      Should -Invoke Invoke-SetupRun -Times 1 -Exactly -ParameterFilter { $Context.State.RunId -eq 'resumed-run' }
      Should -Invoke Show-StartScreen -Times 0 -Exactly
      Should -Invoke Get-MachineInfo -Times 0 -Exactly
      Should -Invoke New-RunState -Times 0 -Exactly
      Should -Invoke Backup-RunState -Times 0 -Exactly
    }
  }

  Context 'run outcome' {
    It 'Rebooting returns 0 and keeps the run lock until the restart' {
      Mock Invoke-SetupRun { 'Rebooting' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Exit-RunLock -Times 0 -Exactly
      Should -Invoke Show-FinalScreen -Times 0 -Exactly
      Should -Invoke Complete-SetupFinalization -Times 0 -Exactly
      Should -Invoke Unregister-ResumeTask -Times 0 -Exactly
      Should -Invoke Stop-Transcript -Times 1 -Exactly
    }
    It 'Completed with finalize Done: final screen, resume task removed, lock released' {
      Mock Read-RunState { New-FakeState -FinalizeStatus 'Done' }
      Mock Get-RunVerdict { @{ Color = 'GREEN'; Banner = 'ALL DONE' } } -ParameterFilter { $State.RunId -eq 'resumed-run' }
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Complete-SetupFinalization -Times 0 -Exactly
      Should -Invoke Save-RunState -Times 0 -Exactly
      Should -Invoke Unregister-ResumeTask -Times 1 -Exactly
      Should -Invoke Show-FinalScreen -Times 1 -Exactly -ParameterFilter {
        $State.RunId -eq 'resumed-run' -and $Verdict.Banner -eq 'ALL DONE' -and $ReportPath -eq (Join-Path $TestDrive 'Logs\Setup-Report.txt') }
      Should -Invoke Exit-RunLock -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive }
    }
    It 'Completed with finalize <Status>: completes the finalization (R26), saves, then shows the final screen' -ForEach @(
      @{ Status = 'Failed' }, @{ Status = 'pending' }, @{ Status = 'running' }
    ) {
      $status = $Status
      Mock Read-RunState { New-FakeState -FinalizeStatus $status }
      $script:order = New-Object System.Collections.ArrayList
      Mock Complete-SetupFinalization { $null = $script:order.Add('finalize'); $Context.State.Steps.finalize.Status = 'Done'; [pscustomobject]@{ Status = 'Done' } }
      Mock Save-RunState { $null = $script:order.Add('save') }
      Mock Unregister-ResumeTask { $null = $script:order.Add('unregister') }
      Mock Show-FinalScreen { $null = $script:order.Add('final') }
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Complete-SetupFinalization -Times 1 -Exactly -ParameterFilter { $Context.State.RunId -eq 'resumed-run' -and $Context.Root -eq $TestDrive }
      Should -Invoke Save-RunState -Times 1 -Exactly -ParameterFilter { $State.RunId -eq 'resumed-run' -and $Root -eq $TestDrive }
      ($script:order -join ',') | Should -Be 'finalize,save,unregister,final'
      Should -Invoke Exit-RunLock -Times 1 -Exactly
    }
    It 'Completed: a state that cannot be saved after the finalization is a red error, not a crash' {
      Mock Read-RunState { New-FakeState -FinalizeStatus 'Failed' }
      Mock Save-RunState { throw 'disk full' }
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Unregister-ResumeTask -Times 1 -Exactly
      Should -Invoke Show-FinalScreen -Times 1 -Exactly -ParameterFilter { @($State.Errors) -contains 'Finalization failed: disk full' }
      Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'ERROR' -and $Data.error -eq 'disk full' }
      $crashes.Count | Should -Be 0
    }
    It 'Completed: a finalization that throws still removes the resume task and shows a red final screen' {
      Mock Read-RunState { New-FakeState -FinalizeStatus 'Failed' }
      Mock Complete-SetupFinalization { throw 'report folder gone' }
      Mock Get-RunVerdict { @{ Color = 'RED' } } -ParameterFilter { $State.RunId -eq 'resumed-run' }
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Unregister-ResumeTask -Times 1 -Exactly
      Should -Invoke Get-RunVerdict -Times 1 -Exactly -ParameterFilter { @($State.Errors) -contains 'Finalization failed: report folder gone' }
      Should -Invoke Show-FinalScreen -Times 1 -Exactly -ParameterFilter {
        $Verdict.Color -eq 'RED' -and @($State.Errors) -contains 'Finalization failed: report folder gone' }
      Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'ERROR' -and $Data.error -eq 'report folder gone' }
      Should -Invoke Save-RunState -Times 0 -Exactly
      Should -Invoke Exit-RunLock -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive }
      $crashes.Count | Should -Be 0
    }
    It 'Completed: the finalization error is listed once, after the errors already there' {
      $existing = @('Restart failed: access denied', 'Finalization failed: report folder gone')
      Mock Read-RunState { $s = New-FakeState -FinalizeStatus 'Failed'; $s.Errors = $existing; $s }
      Mock Complete-SetupFinalization { throw 'report folder gone' }
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Show-FinalScreen -Times 1 -Exactly -ParameterFilter { ($State.Errors -join '|') -eq ($existing -join '|') }
    }
    It 'draws the progress screen with the run state from the progress callback' {
      Mock Invoke-SetupRun { & $OnProgress $Context; 'Completed' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Show-ProgressScreen -Times 1 -Exactly -ParameterFilter { $State.RunId -eq 'new-run' -and $Catalog.Count -eq $script:StepCatalog.Count }
    }
  }

  Context 'crash' {
    It 'an exception returns 1, logs ERROR, shows the crash screen with the message and releases the lock' {
      Mock Invoke-SetupRun { throw 'boom' }
      Invoke-Entry | Should -Be 1
      $crashes.Count | Should -Be 1
      $crashes[0] | Should -Be ('Setup crashed: boom - see {0}' -f (Join-Path $TestDrive 'Logs'))
      Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'ERROR' -and $Data.error -eq 'boom' }
      Should -Invoke Exit-RunLock -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive }
      Should -Invoke Unregister-ResumeTask -Times 0 -Exactly    # the next logon retries (caps bound only crashes inside a step)
      Should -Invoke Show-FinalScreen -Times 0 -Exactly
      Should -Invoke Stop-Transcript -Times 1 -Exactly
    }
    It 'a machine detection failure is a crash before anything is saved' {
      Mock Get-MachineInfo { throw 'CIM is broken' }
      Invoke-Entry | Should -Be 1
      $crashes[0] | Should -Match 'Setup crashed: CIM is broken'
      Should -Invoke Save-RunState -Times 0 -Exactly
      Should -Invoke Exit-RunLock -Times 1 -Exactly
    }
    It 'a crash screen that itself fails still returns 1 and releases the lock' {
      Mock Read-SetupConfig { throw 'config missing' }
      Invoke-Entry -CrashScreen { throw 'no console' } | Should -Be 1
      Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Data.error -eq 'no console' }
      Should -Invoke Exit-RunLock -Times 1 -Exactly
    }
  }

  Context '-WuRound' {
    It 'runs one round with a [bool] IsWindows10 and an [int] FailuresBeforeHide, and never takes the lock' {
      Mock Read-RunState { $s = New-FakeState; $s.Machine.IsWindows10 = $true; $s }
      $resultPath = Join-Path $TestDrive 'Logs\wu-round1.json'
      Invoke-Entry -WuRound $true -ResultPath $resultPath | Should -Be 0
      Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter {
        $StatePath -eq (Join-Path $TestDrive 'state.json') -and $ResultPath -eq $resultPath -and
        $IsWindows10 -is [bool] -and $IsWindows10 -eq $true -and
        $FailuresBeforeHide -is [int] -and $FailuresBeforeHide -eq $script:cfg.caps.wuFailuresBeforeHide -and -not $SearchOnly }
      Should -Invoke Initialize-SetupLog -Times 1 -Exactly -ParameterFilter { $LogDirectory -eq (Join-Path $TestDrive 'Logs') }
      Should -Invoke Read-SetupConfig -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $TestDrive 'config.json') }
      Should -Invoke Enter-RunLock -Times 0 -Exactly
      Should -Invoke Exit-RunLock -Times 0 -Exactly
      Should -Invoke Start-Transcript -Times 0 -Exactly
      Should -Invoke Show-StartScreen -Times 0 -Exactly
      Should -Invoke Invoke-SetupRun -Times 0 -Exactly
      Should -Invoke Save-RunState -Times 0 -Exactly
    }
    It 'passes -SearchOnly on' {
      Mock Read-RunState { New-FakeState }
      Invoke-Entry -WuRound $true -SearchOnly $true -ResultPath (Join-Path $TestDrive 'r.json') | Should -Be 0
      Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $SearchOnly -and $IsWindows10 -eq $false }
    }
    It 'a state without machine facts still passes IsWindows10 as $false (never $null)' {
      Mock Read-RunState { @{ RunId = 'x' } }
      Invoke-Entry -WuRound $true -ResultPath (Join-Path $TestDrive 'r.json') | Should -Be 0
      Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $IsWindows10 -is [bool] -and $IsWindows10 -eq $false }
    }
    It 'returns 1 and logs ERROR when the round cannot run' {
      Mock Read-RunState { New-FakeState }
      Mock Invoke-WuRound { throw 'COM failure' }
      Invoke-Entry -WuRound $true -ResultPath (Join-Path $TestDrive 'r.json') | Should -Be 1
      Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'ERROR' -and $Data.error -eq 'COM failure' }
      $crashes.Count | Should -Be 0    # no screen in the child process
    }
    It 'never touches the console mode (the child has no screen of its own)' {
      Mock Read-RunState { New-FakeState }
      Invoke-Entry -WuRound $true -ResultPath (Join-Path $TestDrive 'r.json') | Should -Be 0
      Should -Invoke Disable-ConsoleQuickEdit -Times 0 -Exactly
    }
  }

  # Final review I3: in the classic console host one click into the window starts a QuickEdit selection,
  # and every console write then blocks until Enter or Esc: the run would stop and wait.
  Context 'QuickEdit' {
    It 'is turned off once on a first run, after logging starts and before the lock and the start screen' {
      $script:order = New-Object System.Collections.ArrayList
      Mock Initialize-SetupLog { $null = $script:order.Add('log') }
      Mock Disable-ConsoleQuickEdit { $null = $script:order.Add('quickedit'); $true }
      Mock Enter-RunLock { $null = $script:order.Add('lock'); $true }
      Mock Show-StartScreen { $null = $script:order.Add('start-screen'); $script:choices }
      Invoke-Entry | Should -Be 0
      Should -Invoke Disable-ConsoleQuickEdit -Times 1 -Exactly
      @($script:order) | Should -Be @('log', 'quickedit', 'lock', 'start-screen')
    }
    It 'is turned off on a resume too' {
      Mock Read-RunState { New-FakeState }
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Disable-ConsoleQuickEdit -Times 1 -Exactly
    }
    It 'is turned off even when another run holds the lock (that window shows a message too)' {
      Mock Enter-RunLock { $false }
      Invoke-Entry | Should -Be 2
      Should -Invoke Disable-ConsoleQuickEdit -Times 1 -Exactly
    }
    It 'a console mode that cannot be changed changes nothing else' {
      Mock Disable-ConsoleQuickEdit { $false }
      Invoke-Entry | Should -Be 0
      Should -Invoke Invoke-SetupRun -Times 1 -Exactly
      $crashes.Count | Should -Be 0
    }
  }
}

Describe 'Get-NoQuickEditConsoleMode' {
  It 'sets ENABLE_EXTENDED_FLAGS (0x80) and clears ENABLE_QUICK_EDIT_MODE (0x40), keeping every other bit: <In> -> <Out>' -ForEach @(
    @{ In = 0x1F7; Out = 0x1B7 }     # the console host default: processed, line, echo, insert, quickedit, extended, auto-position
    @{ In = 0x0;   Out = 0x80 }
    @{ In = 0x40;  Out = 0x80 }
    @{ In = 0x87;  Out = 0x87 }
    @{ In = 0x2C7; Out = 0x287 }      # 0x200 (virtual terminal input) is kept
  ) {
    $r = Get-NoQuickEditConsoleMode -Mode ([uint32]$In)
    $r | Should -BeOfType [uint32]
    $r | Should -Be ([uint32]$Out)
  }
}

Describe 'Disable-ConsoleQuickEdit (in a child process, never in this console)' {
  BeforeAll {
    # Runs Disable-ConsoleQuickEdit in a child powershell.exe and returns what it wrote to a result file.
    # -OwnConsole: the child gets its own hidden console (no redirection, CreateNoWindow), the same kind of
    # console handle the real setup window has; otherwise its stdin is a pipe (no console mode at all).
    function Invoke-QuickEditChild {
      param([switch]$OwnConsole)
      $resultFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
      $src = (Resolve-Path "$PSScriptRoot\..\src").Path
      $script = @"
. '$src\Common\Logging.ps1'; . '$src\Entry\Main.ps1'
`$first = Disable-ConsoleQuickEdit
`$second = Disable-ConsoleQuickEdit
`$mode = [uint32]0
`$type = 'BenTechSetup.ConsoleModeV1' -as [type]
`$read = if (`$null -ne `$type) { `$type::GetConsoleMode(`$type::GetStdHandle(-10), [ref]`$mode) } else { `$false }
[IO.File]::WriteAllText('$resultFile', ('first={0} second={1} type={2} read={3} mode=0x{4:X}' -f `$first, `$second, (`$null -ne `$type), `$read, `$mode))
"@
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
      $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      if (-not $OwnConsole) { $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true }
      $p = [Diagnostics.Process]::Start($psi)
      try {
        if (-not $OwnConsole) { $p.StandardInput.Close(); $null = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync() }
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'the child did not finish' }
      } finally { $p.Dispose() }
      return [IO.File]::ReadAllText($resultFile)
    }
  }
  It 'clears QuickEdit on a real (hidden) console host console, and is safe to call twice' {
    $r = Invoke-QuickEditChild -OwnConsole
    $r | Should -Match '^first=True second=True type=True read=True mode=0x[0-9A-F]+$'
    $mode = [Convert]::ToUInt32(($r -replace '^.*mode=0x', ''), 16)
    ($mode -band 0x40) | Should -Be 0
    ($mode -band 0x80) | Should -Be 0x80
  }
  It 'returns $false, and never throws, when stdin is not a console' {
    Invoke-QuickEditChild | Should -Match '^first=False second=False type=True '
  }
}
