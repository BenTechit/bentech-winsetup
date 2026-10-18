# src/Engine/Runner.ps1
# The step runner: runs every pending plan step in order, persists the state around each call,
# survives crashes and forced reboots (attempt cap), loops on Continue (with a guard), and reboots
# only through Invoke-ControlledReboot (reboot cap). Needs State.ps1, StepResult.ps1, Logging.ps1
# and Reboot.ps1; the default catalog comes from Catalog.ps1.
#
# Callbacks (OnProgress, RestartAction) run in a child scope of the runner, so they see the runner's
# variables first. The runner therefore avoids the generic names a caller is likely to capture
# ($ctx, $state, $config, $root); OnProgress also receives the Context as its first argument.

function New-SetupContext {
  <#
  .SYNOPSIS
    Builds the Context hashtable passed to every step (see "Shared shapes" in the plan).
  .DESCRIPTION
    Pure: creates no folders. The entry point creates Logs\ (Initialize-SetupLog) and the steps
    that download create Downloads\.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ScriptPath
  )

  @{
    Config      = $Config
    State       = $State
    Root        = $Root
    LogDir      = Join-Path $Root 'Logs'
    DownloadDir = Join-Path $Root 'Downloads'
    ScriptPath  = $ScriptPath
    StatePath   = Join-Path $Root 'state.json'
  }
}

function Save-SetupProgress {
  # Private. Saves the state, then calls OnProgress (if given) with the Context. A throwing
  # OnProgress is logged and ignored: the display must never stop the run. Its output is discarded
  # so it can never leak into Invoke-SetupRun's return value. A failed save is NOT caught: without
  # a persisted state the run cannot resume safely, so the entry point's crash handler must see it.
  # The call runs inside a one-shot loop: try/catch does not stop break/continue, which would
  # otherwise travel up the call stack into the runner's own loops.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [scriptblock]$OnProgress
  )

  Save-RunState -State $Context.State -Root $Context.Root
  if ($null -eq $OnProgress) { return }
  $finished = $false
  foreach ($once in 1) {
    try {
      & $OnProgress $Context | Out-Null
    } catch {
      Write-SetupLog -Level WARN -Message 'Progress display failed; continuing' -Data @{ error = $_.Exception.Message }
    }
    $finished = $true
  }
  if (-not $finished) {
    Write-SetupLog -Level WARN -Message 'Progress display used break/continue outside a loop; ignored'
  }
}

function Invoke-SetupStepFunction {
  # Private. Calls one step function and returns exactly one StepResult. Never throws.
  # - An exception becomes Failed(<exception message>), logged at ERROR.
  # - break/continue used outside a loop: try/catch does not stop them, so the call runs inside a
  #   one-shot loop that absorbs them; the step becomes Failed('step used break/continue outside
  #   a loop') instead of escaping into the runner's loops (re-running or abandoning the step).
  # - Extra pipeline output (a classic PowerShell slip) is tolerated, with a WARN. When several
  #   StepResults come out, the worst wins: the last Failed if there is one, otherwise the last
  #   result, so a later Done can never hide a Failed.
  # - No StepResult at all becomes Failed('step returned no valid result').
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)][string]$StepId,
    [Parameter(Mandatory)][string]$FunctionName
  )

  $output = @()
  $finished = $false
  foreach ($once in 1) {
    try {
      $output = @(& $FunctionName -Context $Context)
    } catch {
      $reason = $_.Exception.Message
      Write-SetupLog -Level ERROR -Message 'Step failed' -Data @{ step = $StepId; error = $reason }
      return New-StepResult -Status Failed -Message $reason
    }
    $finished = $true
  }
  if (-not $finished) {
    Write-SetupLog -Level ERROR -Message 'Step used break/continue outside a loop' -Data @{ step = $StepId }
    return New-StepResult -Status Failed -Message 'step used break/continue outside a loop'
  }

  $results = @($output | Where-Object {
      $null -ne $_ -and $null -ne $_.PSObject.Properties['Status'] -and
      ([string]$_.Status) -in 'Done', 'Skipped', 'Failed', 'Continue'
    })
  if ($results.Count -eq 0) {
    Write-SetupLog -Level ERROR -Message 'Step returned no valid result' -Data @{ step = $StepId; items = $output.Count }
    return New-StepResult -Status Failed -Message 'step returned no valid result'
  }
  if ($output.Count -gt 1) {
    Write-SetupLog -Level WARN -Message 'Step emitted extra output; using its worst result' -Data @{ step = $StepId; items = $output.Count; results = $results.Count }
  }
  $failed = @($results | Where-Object { ([string]$_.Status) -eq 'Failed' })
  if ($failed.Count -gt 0) { return $failed[-1] }
  return $results[-1]
}

function Add-StepResultMessages {
  # Private. Appends the result's Notes to State.Notes and its Errors to State.Errors, always as
  # arrays and skipping $null / empty entries.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)]$Result
  )

  foreach ($field in 'Notes', 'Errors') {
    $property = $Result.PSObject.Properties[$field]
    if ($null -eq $property) { continue }
    $added = @(@($property.Value) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
    if ($added.Count -eq 0) { continue }
    $existing = @(@($State[$field]) | Where-Object { $null -ne $_ })
    $State[$field] = @($existing + $added)
  }
}

function Get-StepResultData {
  # Private. The result's Data as a fresh shallow hashtable, or $null when there is none.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Result,
    [Parameter(Mandatory)][string]$StepId
  )

  $property = $Result.PSObject.Properties['Data']
  if ($null -eq $property -or $null -eq $property.Value) { return $null }
  $raw = $property.Value
  if ($raw -isnot [System.Collections.IDictionary]) {
    Write-SetupLog -Level WARN -Message 'Step Data is not a hashtable; ignored' -Data @{ step = $StepId }
    return $null
  }
  if ($raw.Count -eq 0) { return $null }
  $copy = @{}
  foreach ($key in @($raw.Keys)) { $copy[$key] = $raw[$key] }
  return $copy
}

function Save-StepOutcome {
  # Private. Records a step's new status (pending after Continue, or Done/Skipped/Failed), merges
  # Data, saves and reports progress. A Skipped or Failed step never gets an empty message, so the
  # verdict never shows "Title: ".
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [scriptblock]$OnProgress,
    [Parameter(Mandatory)][string]$StepId,
    [Parameter(Mandatory)][ValidateSet('pending', 'Done', 'Skipped', 'Failed')][string]$Status,
    [string]$Message = '',
    [hashtable]$Data,
    [switch]$ResetAttempts
  )

  if (($Status -in 'Skipped', 'Failed') -and [string]::IsNullOrWhiteSpace($Message)) { $Message = '(no details)' }

  $fields = @{ State = $Context.State; StepId = $StepId; Status = $Status; Message = $Message }
  if ($null -ne $Data -and $Data.Count -gt 0) { $fields['Data'] = $Data }
  if ($ResetAttempts) { $fields['ResetAttempts'] = $true }
  Set-StepState @fields
  Save-SetupProgress -Context $Context -OnProgress $OnProgress

  $level = if ($Status -eq 'Failed') { 'WARN' } else { 'INFO' }
  Write-SetupLog -Level $level -Message 'Step result recorded' -Data @{ step = $StepId; status = $Status; message = $Message }
}

function Invoke-SetupRun {
  <#
  .SYNOPSIS
    Runs every unfinished step of State.Plan in order. Returns 'Rebooting' or 'Completed'.
  .DESCRIPTION
    Per plan id:
    - Done / Skipped / Failed: skipped (already finished in an earlier process).
    - running with Attempts >= caps.maxStepAttempts (it crashed or was force-rebooted that often):
      Failed('attempt cap reached') without invoking it.
    - Otherwise still running (interrupted: a crash or an unexpected restart): Data.Interruptions
      (never reset, not even by Continue) and State.RebootCount go up by one; at Interruptions >=
      caps.maxStepAttempts it is Failed('interrupted <n> times (crash or unexpected restart)')
      without invoking it.
    - No catalog entry, or its function does not exist: Failed, without invoking it.
    - Otherwise: running + attempt, save, OnProgress; invoke; append Notes/Errors; merge Data.
      - Continue: pending with attempts reset, save. Reboot Now -> Invoke-ControlledReboot; when it
        restarts, return 'Rebooting'; when it is refused, Failed('reboot cap reached') if the cap
        blocked it, otherwise Failed('restart failed') (the restart and its fallback both failed;
        State.Errors already says why). Without a reboot, the step is called again; the 50th
        consecutive Continue without a reboot fails it with 'step kept asking to continue', so the
        run can never loop forever.
      - Done / Skipped / Failed: stored with the message, save. Reboot Now -> when the controlled
        reboot starts, return 'Rebooting'; when it is refused (cap or failed restart), go on with
        the next step.
    RestartAction / FallbackRestartAction are passed to Invoke-ControlledReboot only when given;
    its defaults (Restart-Computer -ErrorAction Stop, then shutdown.exe) are the production ones.
    Every saved state transition is followed by OnProgress (called with the Context; a throwing
    OnProgress is logged and ignored). After the last step, returns 'Completed'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [object[]]$Catalog = $script:StepCatalog,
    [scriptblock]$OnProgress,
    [scriptblock]$RestartAction,
    [scriptblock]$FallbackRestartAction,
    [int]$CountdownSeconds = 15
  )

  $maxContinueRounds = 50
  $runState = $Context.State
  $maxAttempts = [int]$Context.Config.caps.maxStepAttempts
  $outcome = @{ Context = $Context; OnProgress = $OnProgress }   # splatted into Save-StepOutcome
  # The restart actions are passed on only when given, so their production defaults live in one
  # place: Invoke-ControlledReboot.
  $reboot = @{ Context = $Context; CountdownSeconds = $CountdownSeconds }
  if ($PSBoundParameters.ContainsKey('RestartAction')) { $reboot['RestartAction'] = $RestartAction }
  if ($PSBoundParameters.ContainsKey('FallbackRestartAction')) { $reboot['FallbackRestartAction'] = $FallbackRestartAction }

  $entries = @{}
  foreach ($entry in @($Catalog)) {
    if ($null -ne $entry -and -not [string]::IsNullOrEmpty([string]$entry.Id)) { $entries[[string]$entry.Id] = $entry }
  }

  Write-SetupLog -Message 'Run started' -Data @{ steps = @($runState.Plan).Count; rebootCount = $runState.RebootCount }

  foreach ($stepId in @($runState.Plan)) {
    if ([string]::IsNullOrEmpty($stepId)) { continue }
    if ($null -eq $runState.Steps -or -not $runState.Steps.ContainsKey($stepId)) {
      # Set-StepState cannot record anything for it; the verdict reports it as "did not finish".
      Write-SetupLog -Level ERROR -Message 'Plan step has no state entry; skipping it' -Data @{ step = $stepId }
      continue
    }

    $stepState = $runState.Steps[$stepId]
    $status = [string]$stepState.Status
    if ($status -in 'Done', 'Skipped', 'Failed') { continue }

    if ($status -eq 'running' -and [int]$stepState.Attempts -ge $maxAttempts) {
      Save-StepOutcome @outcome -StepId $stepId -Status Failed -Message 'attempt cap reached'
      continue
    }

    if ($status -eq 'running') {
      # Found running on entry: the previous process never recorded a result (a crash, or a restart
      # nobody asked for, e.g. a BIOS update forcing one). Attempts is reset by every Continue, so
      # it cannot catch a multi-round step that keeps being interrupted; Interruptions never resets.
      # The interruption also counts toward the total reboot cap. Saved with the next transition.
      if ($stepState.Data -isnot [System.Collections.IDictionary]) { $stepState.Data = @{} }
      $interruptions = [int]$stepState.Data['Interruptions'] + 1
      $stepState.Data['Interruptions'] = $interruptions
      $runState.RebootCount = [int]$runState.RebootCount + 1
      Write-SetupLog -Level WARN -Message 'Step was interrupted (crash or unexpected restart)' -Data @{ step = $stepId; interruptions = $interruptions; rebootCount = $runState.RebootCount }
      if ($interruptions -ge $maxAttempts) {
        Save-StepOutcome @outcome -StepId $stepId -Status Failed -Message "interrupted $interruptions times (crash or unexpected restart)"
        continue
      }
    }

    $entry = $entries[$stepId]
    if ($null -eq $entry) {
      Save-StepOutcome @outcome -StepId $stepId -Status Failed -Message "step not in catalog: $stepId"
      continue
    }
    $functionName = [string]$entry.Function
    $command = $null
    if (-not [string]::IsNullOrWhiteSpace($functionName)) { $command = Get-Command -Name $functionName -ErrorAction SilentlyContinue }
    if ($null -eq $command) {
      Save-StepOutcome @outcome -StepId $stepId -Status Failed -Message "step function not found: $functionName"
      continue
    }

    $continueRounds = 0
    while ($true) {
      Set-StepState -State $runState -StepId $stepId -Status running -IncrementAttempt
      Save-SetupProgress -Context $Context -OnProgress $OnProgress
      Write-SetupLog -Message 'Step started' -Data @{ step = $stepId; attempt = $runState.Steps[$stepId].Attempts }

      $result = Invoke-SetupStepFunction -Context $Context -StepId $stepId -FunctionName $functionName
      Add-StepResultMessages -State $runState -Result $result
      $data = Get-StepResultData -Result $result -StepId $stepId
      $message = [string]$result.Message
      $rebootNow = ([string]$result.Reboot -eq 'Now')

      if ([string]$result.Status -eq 'Continue') {
        Save-StepOutcome @outcome -StepId $stepId -Status pending -Message $message -Data $data -ResetAttempts
        if ($rebootNow) {
          if (Invoke-ControlledReboot @reboot) { return 'Rebooting' }
          # Refused: either the cap (RebootCapHit set) or a restart that failed even with the fallback.
          $refusal = if ($runState.RebootCapHit -eq $true) { 'reboot cap reached' } else { 'restart failed' }
          Save-StepOutcome @outcome -StepId $stepId -Status Failed -Message $refusal
          break
        }
        $continueRounds++
        if ($continueRounds -ge $maxContinueRounds) {
          Save-StepOutcome @outcome -StepId $stepId -Status Failed -Message 'step kept asking to continue'
          break
        }
        continue
      }

      Save-StepOutcome @outcome -StepId $stepId -Status ([string]$result.Status) -Message $message -Data $data
      if ($rebootNow -and (Invoke-ControlledReboot @reboot)) { return 'Rebooting' }
      break
    }
  }

  Write-SetupLog -Message 'Run completed' -Data @{ rebootCount = $runState.RebootCount }
  return 'Completed'
}
