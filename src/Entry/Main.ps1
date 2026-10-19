# src/Entry/Main.ps1
# Start-BenTechSetup: the entry point of the bundled setup.ps1. It runs three ways:
#   - from the launcher (first run): the start screen, then the run;
#   - from the logon resume task (-Resume): straight back into the saved run;
#   - as the Windows Update child process the windows-update step starts (-WuRound -ResultPath <p>):
#     one round, no lock, no screen.
#
# The call itself, `exit (Start-BenTechSetup ...)`, is not in this file: it is src/Entry/Run.ps1, which
# only tools\Build-Bundle.ps1 appends, as the bundle's last statement. That keeps this file safe to
# dot-source in tests (it only defines functions).

function Get-PreviousRunSummary {
  # Private. The @{ StartedAt; Color } summary of an earlier run that the start screen shows and the new
  # state keeps as PreviousRun: the verdict colour of a run that ended, 'UNFINISHED' for one that never
  # did, $null when there was no earlier run. An old state whose verdict cannot be computed (a damaged or
  # older shape) is logged and shown as 'UNKNOWN', so a strange state.json can never block a new run.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()][hashtable]$State)

  if ($null -eq $State) { return $null }
  $color = 'UNFINISHED'
  if ($State['EndedAt']) {
    try {
      $color = [string](Get-RunVerdict -State $State).Color
    } catch {
      Write-SetupLog -Level WARN -Message 'The result of the previous run could not be computed' -Data @{ error = $_.Exception.Message }
      $color = 'UNKNOWN'
    }
  }
  return @{ StartedAt = $State['StartedAt']; Color = $color }
}

function Test-SetupMachineFresh {
  # Private. Whether this machine looks like a fresh install, so the start screen may count down and
  # start by itself. Whatever cannot be judged is "not fresh", the safe side (the screen then waits for
  # Enter): an empty or unparseable InstallDate, or any error measuring the user data. Never throws.
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config
  )

  try {
    $text = [string]$Machine['InstallDate']
    $installDate = [datetime]::MinValue
    $parsed = (-not [string]::IsNullOrWhiteSpace($text)) -and
      [datetime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$installDate)
    if (-not $parsed) {
      Write-SetupLog -Level WARN -Message 'Windows install date unknown; treating the machine as not fresh' -Data @{ installDate = $text }
      return $false
    }
    $fresh = Test-FreshInstall -InstallDate $installDate -UserDataBytes (Get-UserDataBytes) `
      -MaxAgeDays ([int]$Config.freshInstall.maxInstallAgeDays) -MaxUserDataGB ([double]$Config.freshInstall.maxUserDataGB)
    return ($fresh -eq $true)
  } catch {
    Write-SetupLog -Level WARN -Message 'Fresh-install check failed; treating the machine as not fresh' -Data @{ error = $_.Exception.Message }
    return $false
  }
}

function Get-NoQuickEditConsoleMode {
  # Pure. A console input mode with ENABLE_EXTENDED_FLAGS (0x80) set and ENABLE_QUICK_EDIT_MODE (0x40)
  # cleared; every other bit is kept. (The extended flag must be set for the QuickEdit bit to count.)
  [CmdletBinding()]
  [OutputType([uint32])]
  param([Parameter(Mandatory)][uint32]$Mode)

  $result = [uint32]($Mode -bor [uint32]0x80)
  if (($result -band [uint32]0x40) -ne 0) { $result = [uint32]($result - [uint32]0x40) }
  return $result
}

function Disable-ConsoleQuickEdit {
  <#
  .SYNOPSIS
    Turns QuickEdit off for this process's console. Returns $true when the console mode now has it off,
    $false otherwise. Never throws.
  .DESCRIPTION
    Final review I3: in the classic console host QuickEdit is on by default, and one click into the
    window starts a selection; every console write then blocks until Enter or Esc, so the run would stop
    and wait (spec 4). GetStdHandle(STD_INPUT_HANDLE = -10), GetConsoleMode, then SetConsoleMode with
    Get-NoQuickEditConsoleMode. Under Windows Terminal this changes nothing visible. No console (stdin is a
    pipe or a file) is $false, logged at INFO; any other failure is a WARN. The P/Invoke type is
    compiled once per process (BenTechSetup.ConsoleModeV1, a name nothing else uses).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  try {
    $type = 'BenTechSetup.ConsoleModeV1' -as [type]
    if ($null -eq $type) {
      Add-Type -Namespace 'BenTechSetup' -Name 'ConsoleModeV1' -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
      $type = 'BenTechSetup.ConsoleModeV1' -as [type]
    }
    $handle = $type::GetStdHandle(-10)
    $mode = [uint32]0
    if (-not $type::GetConsoleMode($handle, [ref]$mode)) {
      Write-SetupLog -Message 'No console input to change (QuickEdit left as it is)'
      return $false
    }
    $wanted = Get-NoQuickEditConsoleMode -Mode $mode
    if ($wanted -ne $mode -and -not $type::SetConsoleMode($handle, $wanted)) {
      Write-SetupLog -Level WARN -Message 'Could not turn QuickEdit off; a click into the window can pause the run' -Data @{ mode = ('0x{0:X}' -f $mode) }
      return $false
    }
    return $true
  } catch {
    Write-SetupLog -Level WARN -Message 'Could not turn QuickEdit off; a click into the window can pause the run' -Data @{ error = $_.Exception.Message }
    return $false
  }
}

function Invoke-SetupWuRoundProcess {
  # Private. The -WuRound child process: one Windows Update round for the windows-update step. The parent
  # holds the run lock and owns the screen, so this takes no lock and shows nothing. Returns 0 when the
  # round ran (its outcome is in the result JSON Invoke-WuRound writes) and 1 when it could not run (the
  # error is logged; the parent treats a missing result JSON as a failed round).
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)][string]$Root,
    [AllowNull()][AllowEmptyString()][string]$ResultPath,
    [bool]$SearchOnly
  )

  try {
    $null = Initialize-SetupLog -LogDirectory (Join-Path $Root 'Logs')
    $config = Read-SetupConfig -Path (Join-Path $Root 'config.json')
    # Read only for the machine facts; the parent saved this state right before it started this process.
    $runState = Read-RunState -Root $Root
    $isWindows10 = $false
    if ($null -ne $runState -and $runState['Machine'] -is [System.Collections.IDictionary]) {
      $isWindows10 = ($runState['Machine']['IsWindows10'] -eq $true)
    }
    # A missing state is not checked here: Invoke-WuRound reports it in the result JSON.
    $null = Invoke-WuRound -StatePath (Join-Path $Root 'state.json') -ResultPath $ResultPath `
      -FailuresBeforeHide ([int]$config.caps.wuFailuresBeforeHide) -IsWindows10 $isWindows10 -SearchOnly:$SearchOnly
    return 0
  } catch {
    Write-SetupLog -Level ERROR -Message 'Windows Update round process failed' -Data @{ error = $_.Exception.Message; resultPath = $ResultPath }
    return 1
  }
}

function Complete-SetupRun {
  # Private. After a 'Completed' run: finishes the finalization when the finalize step is not Done
  # (ruling R26: a failed final restart, or a finalize that failed or never finished, would otherwise
  # leave the resume task, the setup policies and no report), removes the resume task in any case, and
  # shows the final screen.
  # A finalization (or the save after it) that throws is not a crash: it is logged, recorded as the Error
  # 'Finalization failed: <message>' (so the final screen is red), and the final screen still shows the
  # AnyDesk ID. The resume task is removed in a finally block: left behind, the same error would come
  # back at every logon, and nothing (not the runner's caps) would ever stop it.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)][string]$Root
  )

  try {
    $finalize = $null
    if ($Context.State.Steps -is [System.Collections.IDictionary]) { $finalize = $Context.State.Steps['finalize'] }
    $finalizeStatus = if ($null -ne $finalize) { [string]$finalize['Status'] } else { '' }
    if ($finalizeStatus -ne 'Done') {
      Write-SetupLog -Level WARN -Message 'Run completed without a finished finalize step; completing the finalization' -Data @{ finalizeStatus = $finalizeStatus }
      try {
        $null = Complete-SetupFinalization -Context $Context
        $null = Save-RunState -State $Context.State -Root $Root
      } catch {
        $message = $_.Exception.Message
        Write-SetupLog -Level ERROR -Message 'Completing the finalization failed' -Data @{ error = $message; stack = $_.ScriptStackTrace }
        $errorText = "Finalization failed: $message"
        $errors = @(@($Context.State['Errors']) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
        if ($errors -notcontains $errorText) { $Context.State['Errors'] = @($errors + $errorText) }
      }
    }
  } finally {
    # Defensive: Finalize normally removes it already. A task left behind would re-open setup at every logon.
    # Its bool is ignored here: Finalize has already reported a removal that failed (a Note).
    $null = Unregister-ResumeTask
  }

  $verdict = Get-RunVerdict -State $Context.State
  Write-SetupLog -Message 'Setup finished' -Data @{ result = $verdict['Color'] }
  $null = Show-FinalScreen -State $Context.State -Verdict $verdict -ReportPath (Join-Path $Root 'Logs\Setup-Report.txt')
}

function Invoke-SetupMainFlow {
  # Private. Everything that runs while this process holds the run lock. Returns 'Cancelled' (Escape on
  # the start screen: a leftover resume task is removed, nothing else changes), 'NoState' (resumed
  # without a state), 'Rebooting' or 'Completed'. Exceptions propagate to Start-BenTechSetup's crash
  # handler.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][bool]$Resume,
    [Parameter(Mandatory)][string]$Version
  )

  $logDir = Join-Path $Root 'Logs'
  $configPath = Join-Path $Root 'config.json'

  if ($Resume) {
    # The state is read before the config: a resume without a state only has to remove its task, and
    # must not crash (and so stay registered) because config.json is gone too.
    $runState = Read-RunState -Root $Root -LogDir $logDir
    if ($null -eq $runState) {
      Write-SetupLog -Level WARN -Message 'Resumed at logon, but there is no run state; removing the resume task'
      $null = Unregister-ResumeTask
      return 'NoState'
    }
    $config = Read-SetupConfig -Path $configPath
    Write-SetupLog -Message 'Resuming the run' -Data @{ runId = $runState['RunId'] }
  } else {
    $config = Read-SetupConfig -Path $configPath
    $previous = Read-RunState -Root $Root -LogDir $logDir
    $previousSummary = Get-PreviousRunSummary -State $previous
    $machine = Get-MachineInfo
    $fresh = Test-SetupMachineFresh -Machine $machine -Config $config
    $choices = Show-StartScreen -Machine $machine -Config $config -Version $Version -Previous $previousSummary -IsFresh $fresh
    if ($null -eq $choices) {
      # Ruling R27 (spec 8.1, 8.5): cancel leaves no changes and no resume task, so a task left by an
      # earlier, unfinished run is removed too. No state is saved.
      Write-SetupLog -Message 'Cancelled on the start screen; removing any leftover resume task, nothing else is changed'
      $null = Unregister-ResumeTask
      return 'Cancelled'
    }
    if ($null -ne $previous) { $null = Backup-RunState -Root $Root -LogDir $logDir }
    $plan = @(Get-StepPlan -Machine $machine -Choices $choices -Config $config)
    $runState = New-RunState -Machine $machine -Choices $choices -Plan $plan -Version $Version -Previous $previous
    $runState.PreviousRun = $previousSummary
    $null = Save-RunState -State $runState -Root $Root
    Write-SetupLog -Message 'New run started' -Data @{ runId = $runState['RunId']; choices = $choices; steps = $plan.Count }
  }

  $ctx = New-SetupContext -Config $config -State $runState -Root $Root -ScriptPath $ScriptPath
  # The runner passes the Context to OnProgress, so the callback does not depend on variable lookup.
  $outcome = Invoke-SetupRun -Context $ctx -OnProgress { param($progressContext) Show-ProgressScreen -State $progressContext.State -Catalog $script:StepCatalog }
  if ($outcome -eq 'Rebooting') { return 'Rebooting' }

  $null = Complete-SetupRun -Context $ctx -Root $Root
  return 'Completed'
}

function Start-BenTechSetup {
  <#
  .SYNOPSIS
    The entry point of setup.ps1. Returns the process exit code: 0, 1 (crash, or a failed -WuRound
    child) or 2 (another run holds the lock).
  .DESCRIPTION
    -WuRound: one Windows Update round (Invoke-WuRound) with the config's wuFailuresBeforeHide and the
    state's Machine.IsWindows10; no lock, no transcript, no screen. 0 when the round ran, 1 when it could
    not (logged).

    Otherwise:
      1. Logging: Initialize-SetupLog <Root>\Logs; QuickEdit turned off for this console
         (Disable-ConsoleQuickEdit, best effort: a click into the window must not pause the run); a
         transcript in <Root>\Logs\transcript-<stamp>.txt (best effort), and the start line with the
         version ('dev' when unbundled).
      2. Lock: Enter-RunLock. Held by another live run: 'Setup is already running on this machine', 2.
      3. Not resuming: the previous run's summary, the machine facts, the fresh-install check, the start
         screen (Escape: a leftover resume task is removed (R27), nothing else changes, 0). Then the
         previous state is archived, the plan built, and the new state saved.
         Resuming: the saved state. None: the resume task is removed, 0.
      4. Invoke-SetupRun, drawing the progress screen on every transition.
         'Rebooting': 0, and the lock is kept: the restart ends the process, and the next start finds the
         lock stale.
         'Completed': the finalization is completed when the finalize step is not Done (R26); if that
         throws, the error is logged and added to State.Errors (red), not a crash. The resume task is
         removed in any case, and the final screen is shown. 0.
    The lock is released in a finally block (also on Ctrl+C on the start screen), except after
    'Rebooting'. The transcript is stopped in the same finally block.

    Any other unexpected exception is a crash: logged as ERROR, the red crash text "Setup crashed:
    <message> - see <Root>\Logs" (-CrashScreen), then a key press (skipped with -NoWait), and 1. The
    resume task stays registered, so the next logon retries. The runner's attempt caps bound only a
    crash inside a step (that step is failed after maxStepAttempts interruptions); a crash before or
    after the run (config, state, machine detection, screens) repeats at every logon until it is fixed.

    -Root, -ScriptPath, -CrashScreen and -NoWait exist for tests; production uses the defaults
    (C:\BenTech\Setup, <Root>\setup.ps1, the red console text, waiting for a key).
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [bool]$Resume,
    [bool]$WuRound,
    [bool]$SearchOnly,
    [AllowNull()][AllowEmptyString()][string]$ResultPath,
    [ValidateNotNullOrEmpty()][string]$Root = 'C:\BenTech\Setup',
    [AllowNull()][AllowEmptyString()][string]$ScriptPath,
    [scriptblock]$CrashScreen = {
      param($text)
      try {
        $Host.UI.RawUI.BackgroundColor = 'DarkRed'
        $Host.UI.RawUI.ForegroundColor = 'White'
        Clear-Host
      } catch {
        Write-SetupLog -Level WARN -Message 'Could not paint the crash screen red' -Data @{ error = $_.Exception.Message }
      }
      Write-Host $text -ForegroundColor White -BackgroundColor DarkRed
    },
    [switch]$NoWait
  )

  if ($WuRound) { return (Invoke-SetupWuRoundProcess -Root $Root -ResultPath $ResultPath -SearchOnly $SearchOnly) }

  if ([string]::IsNullOrEmpty($ScriptPath)) { $ScriptPath = Join-Path $Root 'setup.ps1' }
  $version = if ([string]::IsNullOrEmpty([string]$script:SetupVersion)) { 'dev' } else { [string]$script:SetupVersion }
  $logDir = Join-Path $Root 'Logs'

  $exitCode = 1
  $lockHeld = $false
  $keepLock = $false
  $transcriptStarted = $false
  try {
    $null = Initialize-SetupLog -LogDirectory $logDir
    # Final review I3: never on the -WuRound path above (that child has no screen of its own).
    $null = Disable-ConsoleQuickEdit
    try {
      $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
      $null = Start-Transcript -Path (Join-Path $logDir "transcript-$stamp.txt") -ErrorAction Stop
      $transcriptStarted = $true
    } catch {
      Write-SetupLog -Level WARN -Message 'Could not start the console transcript; continuing without it' -Data @{ error = $_.Exception.Message }
    }
    Write-SetupLog -Message "BenTech Windows Setup $version starting" -Data @{ resume = $Resume }

    if (-not (Enter-RunLock -Root $Root)) {
      Write-SetupLog -Level WARN -Message 'Setup is already running on this machine; exiting'
      Write-Host 'Setup is already running on this machine' -ForegroundColor Yellow -BackgroundColor Black
      $exitCode = 2
    } else {
      $lockHeld = $true
      $outcome = Invoke-SetupMainFlow -Root $Root -ScriptPath $ScriptPath -Resume $Resume -Version $version
      if ($outcome -eq 'Rebooting') {
        $keepLock = $true
        Write-SetupLog -Message 'Restarting; the run lock is kept until the machine restarts'
      }
      $exitCode = 0
    }
  } catch {
    $message = $_.Exception.Message
    Write-SetupLog -Level ERROR -Message 'Setup crashed' -Data @{
      error = $message; type = $_.Exception.GetType().FullName; stack = $_.ScriptStackTrace }
    try {
      $null = & $CrashScreen ('Setup crashed: {0} - see {1}' -f $message, $logDir)
    } catch {
      Write-SetupLog -Level WARN -Message 'Could not show the crash screen' -Data @{ error = $_.Exception.Message }
    }
    if (-not $NoWait) {
      try {
        # A key pressed earlier must not close the window before anyone has read the message.
        while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
        $null = [Console]::ReadKey($true)
      } catch {
        Write-SetupLog -Level WARN -Message 'Could not wait for a key after the crash' -Data @{ error = $_.Exception.Message }
      }
    }
    $exitCode = 1
  } finally {
    if ($lockHeld -and -not $keepLock) { $null = Exit-RunLock -Root $Root }
    if ($transcriptStarted) {
      try {
        $null = Stop-Transcript
      } catch {
        Write-SetupLog -Level WARN -Message 'Could not stop the console transcript' -Data @{ error = $_.Exception.Message }
      }
    }
  }
  return $exitCode
}
