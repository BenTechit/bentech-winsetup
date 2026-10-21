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
# Toolbox Task 4: the start screen is Get-SetupChoices (the toolbox window, the console start screen when it
# fails), mocked here. As a second safety net Show-ToolboxWindow and Test-ToolboxHost throw: this suite can never
# open a window.
# Task 15: Invoke-SetupCleanup deletes the parent of -Root (here the temp folder above $TestDrive), so
# BeforeEach always mocks it, and Get-LauncherInfo (no CIM query from these tests).
BeforeAll {
  foreach ($f in 'Common\StepResult', 'Common\Logging', 'Common\Activity', 'Common\Config', 'State\State', 'Detect\PcName', 'Detect\Detection',
                 'Engine\Catalog', 'Engine\Verdict', 'Engine\Reboot', 'Engine\Runner', 'Report\Report',
                 'Steps\Prepare', 'Steps\WindowsUpdate', 'Steps\Finalize',
                 'UI\ConsoleFrame', 'UI\StartScreen', 'UI\ProgressScreen', 'UI\FinalScreen',
                 'Toolbox\Strings', 'Toolbox\SetupPlanner', 'Toolbox\Xaml', 'Toolbox\Toolbox', 'Entry\Cleanup', 'Entry\Main') {
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
      [bool]$WuUnhide = $false,
      [string]$UpdateIds = '',
      [scriptblock]$CrashScreen = { param($text) $null = $script:crashes.Add($text) }
    )
    Start-BenTechSetup -Resume $Resume -WuRound $WuRound -SearchOnly $SearchOnly -ResultPath $ResultPath -WuUnhide $WuUnhide -UpdateIds $UpdateIds -Root $TestDrive -NoWait -CrashScreen $CrashScreen
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
    Mock Get-SetupChoices { $script:choices }
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
    Mock Test-OnACPower { $true }                 # the -WuRound child reads the power status; never the real one here
    Mock Disable-ConsoleQuickEdit { $true }       # never changes the console the tests run in
    Mock Resize-SetupConsole { $true }            # never resizes the console the tests run in
    Mock Initialize-SetupActivity { }
    Mock Reset-SetupActivityLog { }
    Mock Add-SetupActivity { }
    Mock Register-ScheduledTask { throw 'blocked: Register-ScheduledTask' }
    Mock Unregister-ScheduledTask { throw 'blocked: Unregister-ScheduledTask' }
    Mock Restart-Computer { throw 'blocked: Restart-Computer' }
    Mock Start-Process { throw 'blocked: Start-Process' }
    Mock Invoke-SetupCleanup { }                  # SAFETY: the real one deletes the parent of -Root
    Mock Get-LauncherInfo { @{ Path = 'E:\BenTechSetup.cmd'; Drive = 'E:'; VolumeSerial = '1A2B3C4D' } }
    # SAFETY (toolbox Task 4): Get-SetupChoices is mocked, so neither is ever reached; if a test ever lets the real
    # one through, it stops at these instead of opening a real window.
    Mock Show-ToolboxWindow { throw 'blocked: Show-ToolboxWindow' }
    Mock Test-ToolboxHost { throw 'blocked: Test-ToolboxHost' }
  }

  AfterEach {
    Remove-Variable -Name SetupVersion -Scope Script -ErrorAction SilentlyContinue
    # A test that mocks Unregister-SetupTick leaves the real tick registered: drop it, so no later test
    # inherits a handler.
    $script:SetupTickHandler = $null
    $script:SetupTickContext = $null
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
    It 'cannot open a toolbox window: the real window functions are blocked here, and Main.ps1 asks Get-SetupChoices (toolbox Task 4)' {
      { Test-ToolboxHost } | Should -Throw '*blocked: Test-ToolboxHost*'
      { Show-ToolboxWindow -Machine $script:machine -Config $script:cfg -Version 'x' -Previous $null -IsFresh $true } | Should -Throw '*blocked: Show-ToolboxWindow*'
      $main = Get-Content "$PSScriptRoot\..\src\Entry\Main.ps1" -Raw
      $main | Should -Match '\$choices = Get-SetupChoices -Machine \$machine -Config \$config -Version \$Version -Previous \$previousSummary -IsFresh \$fresh'
      $main | Should -Not -Match '= Show-StartScreen'
    }
    It 'returns 2 and changes nothing when another run holds the lock' {
      Mock Enter-RunLock { $false }
      Invoke-Entry | Should -Be 2
      Should -Invoke Enter-RunLock -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive }
      Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'Setup is already running on this machine' -and $ForegroundColor -eq 'Yellow' -and $BackgroundColor -eq 'Black' }
      Should -Invoke Read-SetupConfig -Times 0 -Exactly
      Should -Invoke Read-RunState -Times 0 -Exactly
      Should -Invoke Get-SetupChoices -Times 0 -Exactly
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
      Mock Get-SetupChoices { $null }
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
      Should -Invoke Get-SetupChoices -Times 1 -Exactly -ParameterFilter {
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
      Should -Invoke Get-SetupChoices -Times 1 -Exactly -ParameterFilter { $Previous.StartedAt -eq '2026-10-17T09:00:00' -and $Previous.Color -eq 'YELLOW' }
      Should -Invoke Backup-RunState -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive -and $LogDir -eq (Join-Path $TestDrive 'Logs') }
      Should -Invoke New-RunState -Times 1 -Exactly -ParameterFilter { $Previous.RunId -eq 'old-run' }
      Should -Invoke Save-RunState -Times 1 -Exactly -ParameterFilter { $State.PreviousRun.Color -eq 'YELLOW' -and $State.PreviousRun.StartedAt -eq '2026-10-17T09:00:00' }
    }
    It 'an earlier run that never ended is UNFINISHED (no verdict is computed for it)' {
      Mock Read-RunState { New-FakeState -RunId 'old-run' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Get-SetupChoices -Times 1 -Exactly -ParameterFilter { $Previous.Color -eq 'UNFINISHED' }
      Should -Invoke Get-RunVerdict -Times 0 -Exactly -ParameterFilter { $State.RunId -eq 'old-run' }
      Should -Invoke Backup-RunState -Times 1 -Exactly
    }
    It 'an earlier state whose verdict cannot be computed does not stop the new run' {
      Mock Read-RunState { New-FakeState -RunId 'old-run' -EndedAt '2026-10-17T10:00:00' }
      Mock Get-RunVerdict { throw 'odd old state' } -ParameterFilter { $State.RunId -eq 'old-run' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Get-SetupChoices -Times 1 -Exactly -ParameterFilter { $Previous.Color -eq 'UNKNOWN' }
      Should -Invoke Invoke-SetupRun -Times 1 -Exactly
      $crashes.Count | Should -Be 0
    }
  }

  Context 'fresh-install check' {
    It 'an empty InstallDate is not fresh' {
      $machine.InstallDate = ''
      Invoke-Entry | Should -Be 0
      Should -Invoke Get-SetupChoices -Times 1 -Exactly -ParameterFilter { $IsFresh -eq $false }
      Should -Invoke Test-FreshInstall -Times 0 -Exactly
    }
    It 'an unparseable InstallDate is not fresh' {
      $machine.InstallDate = 'not a date'
      Invoke-Entry | Should -Be 0
      Should -Invoke Get-SetupChoices -Times 1 -Exactly -ParameterFilter { $IsFresh -eq $false }
      Should -Invoke Test-FreshInstall -Times 0 -Exactly
    }
    It 'a failure measuring the user data is not fresh' {
      Mock Get-UserDataBytes { throw 'access denied' }
      Invoke-Entry | Should -Be 0
      Should -Invoke Get-SetupChoices -Times 1 -Exactly -ParameterFilter { $IsFresh -eq $false }
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
      Should -Invoke Get-SetupChoices -Times 1 -Exactly -ParameterFilter { $IsFresh -eq $answer }
    }
  }

  Context 'resume' {
    It 'with no state removes the resume task and returns 0' {
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Unregister-ResumeTask -Times 1 -Exactly
      Should -Invoke Get-SetupChoices -Times 0 -Exactly
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
      Should -Invoke Get-SetupChoices -Times 0 -Exactly
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
    It 'the production crash screen paints White on DarkRed (spec 9.1)' {
      # It would repaint the console running the tests, so read the -CrashScreen default out of the param block.
      $param = (Get-Command Start-BenTechSetup).ScriptBlock.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CrashScreen' }
      $text = $param.DefaultValue.Extent.Text
      $text | Should -Match "RawUI\.BackgroundColor = 'DarkRed'"
      $text | Should -Match "RawUI\.ForegroundColor = 'White'"
      $text | Should -Match "-ForegroundColor White -BackgroundColor DarkRed"
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
      Should -Invoke Get-SetupChoices -Times 0 -Exactly
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
    # Spec 9.2: firmware is installed only on mains power, read at the start of every round.
    It '-WuRound reads the power and passes -OnAC; a failed read counts as battery' {
      Mock Test-OnACPower { $true }; Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null
      Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $OnAC -eq $true }
      Mock Test-OnACPower { throw 'no power status' }; Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null
      Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $OnAC -eq $false }
    }
    It '-WuRound on battery passes -OnAC $false; a failed read is a WARN, not a failed round' {
      Mock Test-OnACPower { $false }; Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Should -Be 0
      Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $OnAC -is [bool] -and $OnAC -eq $false }
      Mock Test-OnACPower { throw 'no power status' }; Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Should -Be 0
      Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Data.error -eq 'no power status' }
    }
    # Spec 4.5: the config switch between one update at a time (default) and v1's batch install.
    It '-WuRound passes the configured install mode' { Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null; Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $InstallMode -eq 'OneAtATime' } }
    It '-WuRound passes Batch when the config asks for it' {
      $script:batchCfg = $script:cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $script:batchCfg.windowsUpdate.installMode = 'Batch'
      Mock Read-SetupConfig { $script:batchCfg }
      Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null
      Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $InstallMode -eq 'Batch' }
    }
  }

  # Final review C1: the end-of-run un-hide child (WUA COM mocked: New-WuSession and Invoke-WuUnhide).
  Context '-WuUnhide' {
    BeforeAll {
      $script:u1 = '11111111-aaaa-4bbb-8ccc-000000000001'; $script:u2 = '22222222-aaaa-4bbb-8ccc-000000000002'
    }
    BeforeEach {
      Mock New-WuSession { [pscustomobject]@{ Name = 'fake session' } }
      Mock Invoke-WuUnhide { @{ Unhidden = @($script:u1); UnhideFailed = @($script:u2) } }
      Mock Register-SetupTick { }
    }
    It 'dispatches to Invoke-WuUnhide with the ids exactly and writes { Unhidden; UnhideFailed } (UTF-8, no BOM)' {
      $resultPath = Join-Path $TestDrive 'Logs\wu-unhide.json'
      Invoke-Entry -WuUnhide $true -ResultPath $resultPath -UpdateIds ('{0},{1}' -f $script:u1, $script:u2) | Should -Be 0
      Should -Invoke Invoke-WuUnhide -Times 1 -Exactly -ParameterFilter { ($Ids -join '|') -eq ('{0}|{1}' -f $script:u1, $script:u2) -and $Session.Name -eq 'fake session' }
      $bytes = [IO.File]::ReadAllBytes($resultPath); ($bytes[0] -eq 0xEF) | Should -BeFalse
      $r = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
      @($r.Unhidden) | Should -Be @($script:u1); @($r.UnhideFailed) | Should -Be @($script:u2)
      Should -Invoke Initialize-SetupLog -Times 1 -Exactly -ParameterFilter { $LogDirectory -eq (Join-Path $TestDrive 'Logs') }
    }
    It 'runs with no lock, no screen, no tick, no activity feed and no state' {
      Invoke-Entry -WuUnhide $true -ResultPath "$TestDrive\u.json" -UpdateIds $script:u1 | Should -Be 0
      foreach ($c in 'Enter-RunLock', 'Start-Transcript', 'Get-SetupChoices', 'Invoke-SetupRun', 'Register-SetupTick', 'Initialize-SetupActivity',
                     'Disable-ConsoleQuickEdit', 'Resize-SetupConsole', 'Read-RunState', 'Save-RunState', 'Invoke-WuRound', 'Invoke-SetupCleanup') {
        Should -Invoke $c -Times 0 -Exactly -Because $c
      }
    }
    It 'a failing search lists every id as UnhideFailed, still writes the result and returns 0' {
      Mock Invoke-WuUnhide { throw 'Windows Update search failed' }
      Invoke-Entry -WuUnhide $true -ResultPath "$TestDrive\u.json" -UpdateIds ('{0},{1}' -f $script:u1, $script:u2) | Should -Be 0
      $r = Get-Content "$TestDrive\u.json" -Raw | ConvertFrom-Json
      @($r.Unhidden).Count | Should -Be 0; @($r.UnhideFailed) | Should -Be @($script:u1, $script:u2)
      Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'ERROR' -and $Data.error -eq 'Windows Update search failed' }
    }
    It 'passes only GUID-shaped ids on; anything else is UnhideFailed without a search for it' {
      Invoke-Entry -WuUnhide $true -ResultPath "$TestDrive\u.json" -UpdateIds (' {0} ,,not-a-guid' -f $script:u1) | Should -Be 0
      Should -Invoke Invoke-WuUnhide -Times 1 -Exactly -ParameterFilter { ($Ids -join '|') -eq $script:u1 }
      @((Get-Content "$TestDrive\u.json" -Raw | ConvertFrom-Json).UnhideFailed) | Should -Contain 'not-a-guid'
    }
    It 'returns 1 when the result cannot be written' {
      Invoke-Entry -WuUnhide $true -ResultPath '' -UpdateIds $script:u1 | Should -Be 1
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
      Mock Get-SetupChoices { $null = $script:order.Add('start-screen'); $script:choices }
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

  # v2 spec 4.3, 4.4: the activity feed, the tick that redraws the progress screen, the console size.
  Context 'activity feed, tick and console size' {
    It 'initializes the activity feed in Root\Logs and resizes the console once' {
      Invoke-Entry | Out-Null
      Should -Invoke Initialize-SetupActivity -Times 1 -Exactly -ParameterFilter { $LogDirectory -eq (Join-Path $TestDrive 'Logs') }
      Should -Invoke Resize-SetupConsole -Times 1 -Exactly
    }
    It 'a new run archives the previous activity under its RunId, after the start screen' {
      $script:order = New-Object System.Collections.ArrayList
      Mock Read-RunState { New-FakeState -RunId '20261019-090000' -EndedAt '2026-10-19T11:00:00' }
      Mock Get-SetupChoices { [void]$script:order.Add('start'); $script:choices }
      Mock Reset-SetupActivityLog { [void]$script:order.Add('archive') }
      Invoke-Entry | Out-Null
      @($order) | Should -Be @('start', 'archive')
      Should -Invoke Reset-SetupActivityLog -Times 1 -Exactly -ParameterFilter { $PreviousRunId -eq '20261019-090000' }
    }
    It 'Escape archives nothing' { Mock Get-SetupChoices { $null }; Invoke-Entry | Out-Null; Should -Invoke Reset-SetupActivityLog -Times 0 -Exactly }
    It 'a resume writes "Back after restart N"' {
      Mock Read-RunState { $s = New-FakeState; $s.RebootCount = 3; $s }
      Invoke-Entry -Resume $true | Out-Null
      Should -Invoke Add-SetupActivity -Times 1 -Exactly -ParameterFilter { $Text -eq 'Back after restart 3' }
    }
    It 'registers the tick with the context before the run and unregisters it before the final screen' {
      $script:order = New-Object System.Collections.ArrayList
      Mock Register-SetupTick { [void]$script:order.Add('register'); $script:tickCtx = $Context }
      Mock Invoke-SetupRun { [void]$script:order.Add('run'); 'Completed' }
      Mock Unregister-SetupTick { [void]$script:order.Add('unregister') }
      Mock Show-FinalScreen { [void]$script:order.Add('final') }
      Invoke-Entry | Out-Null
      $order.IndexOf('register') | Should -BeLessThan $order.IndexOf('run')
      $order.IndexOf('unregister') | Should -BeLessThan $order.IndexOf('final')
      $tickCtx.State.RunId | Should -Be 'new-run'
    }
    It 'a crash unregisters the tick before the crash screen' {
      $script:order = New-Object System.Collections.ArrayList
      Mock Invoke-SetupRun { throw 'boom' }; Mock Unregister-SetupTick { [void]$script:order.Add('unregister') }
      Invoke-Entry -CrashScreen { param($t) [void]$script:order.Add('crash') } | Out-Null
      $order[0] | Should -Be 'unregister'; $order | Should -Contain 'crash'
    }
    It '-WuRound: no tick, no resize, no activity feed' {
      Mock Register-SetupTick { }
      Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null
      Should -Invoke Register-SetupTick -Times 0 -Exactly; Should -Invoke Resize-SetupConsole -Times 0 -Exactly; Should -Invoke Initialize-SetupActivity -Times 0 -Exactly
    }
  }

  # v2 spec 10: no leftover folder.
  Context 'cleanup' {
    It 'a new run records the launcher; a resume does not' {
      $env:BT_SELF = 'E:\BenTechSetup.cmd'
      try { Invoke-Entry | Out-Null; Should -Invoke Get-LauncherInfo -Times 1 -Exactly -ParameterFilter { $Path -eq 'E:\BenTechSetup.cmd' }; $script:newState.Launcher.VolumeSerial | Should -Be '1A2B3C4D' } finally { Remove-Item Env:\BT_SELF }
      Mock Read-RunState { New-FakeState }; Invoke-Entry -Resume $true | Out-Null; Should -Invoke Get-LauncherInfo -Times 1 -Exactly
    }
    It 'records the launcher before the new state is saved' {
      Invoke-Entry | Out-Null
      Should -Invoke Save-RunState -Times 1 -Exactly -ParameterFilter { $State.Launcher.Path -eq 'E:\BenTechSetup.cmd' }
    }
    It 'a finished run cleans up after the lock is released and the transcript stopped' {
      $script:order = New-Object System.Collections.ArrayList
      Mock Exit-RunLock { [void]$script:order.Add('unlock') }; Mock Stop-Transcript { [void]$script:order.Add('transcript') }
      Mock Invoke-SetupCleanup { [void]$script:order.Add("cleanup $Mode"); $script:cleanState = $State }
      Invoke-Entry | Out-Null
      $order.IndexOf('cleanup Finish') | Should -BeGreaterThan $order.IndexOf('unlock'); $order.IndexOf('cleanup Finish') | Should -BeGreaterThan $order.IndexOf('transcript')
      $cleanState.RunId | Should -Be 'new-run'
      Should -Invoke Invoke-SetupCleanup -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive }
    }
    It 'a finished resumed run cleans up too, and the exit code stays 0' {
      Mock Read-RunState { New-FakeState -FinalizeStatus 'Done' }
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Invoke-SetupCleanup -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Finish' -and $State.RunId -eq 'resumed-run' }
    }
    It 'Escape with no earlier run cleans up (Cancel); after an unfinished earlier run it keeps the folder' {
      Mock Get-SetupChoices { $null }; Invoke-Entry | Out-Null; Should -Invoke Invoke-SetupCleanup -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Cancel' }
      Mock Read-RunState { New-FakeState }; Invoke-Entry | Out-Null; Should -Invoke Invoke-SetupCleanup -Times 1 -Exactly
    }
    It 'a crash, a restart or a held lock cleans nothing' {
      Mock Invoke-SetupRun { throw 'boom' }; Invoke-Entry | Out-Null
      Mock Invoke-SetupRun { 'Rebooting' }; Invoke-Entry | Out-Null
      Mock Enter-RunLock { $false }; Invoke-Entry | Out-Null
      Should -Invoke Invoke-SetupCleanup -Times 0 -Exactly
    }
    It 'a resume without a state cleans nothing' {
      Invoke-Entry -Resume $true | Should -Be 0
      Should -Invoke Invoke-SetupCleanup -Times 0 -Exactly
    }
    It 'a crash on the final screen keeps the folder' {
      Mock Show-FinalScreen { throw 'console went away' }
      Invoke-Entry | Should -Be 1
      Should -Invoke Invoke-SetupCleanup -Times 0 -Exactly
    }
    It 'a cleanup that throws anyway does not change the exit code' {
      Mock Invoke-SetupCleanup { throw 'unexpected' }
      Invoke-Entry | Should -Be 0
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
