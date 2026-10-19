# src/Steps/Finalize.ps1
# Step 17, "Finalize" (spec 8.3 step 17, 8.4, 8.7 and 12): the last step. It runs in two phases.
#   Phase A (State.FinalRebootDone is $false): the final power settings, the no-auto-reboot policy
#     value removed, FinalRebootDone saved, then ONE final restart when something needs it
#     (Test-FinalRebootNeeded) and a restart is possible.
#   Phase B (after that restart, or at once when none is needed or possible): the default-browser
#     check, the temporary policies and files removed, activation and BitLocker checked, the resume
#     task removed, the downloads and the pinned script deleted, EndedAt, and the report. This is
#     Complete-SetupFinalization, which the entry point (Task 17) also calls on its own when a run
#     ends with finalize not Done (the final restart failed), so no run is left without a report or
#     with the resume task still registered (ruling R26). The entry point then shows the final screen.
# Needs StepResult.ps1, Logging.ps1, State.ps1, Catalog.ps1 + Verdict.ps1, Reboot.ps1, Prepare.ps1,
# Apps.ps1, DefaultBrowser.ps1, BitLocker.ps1, Vendor.ps1 and Report.ps1; the bundle holds every file.
#
# Notes and errors: Finalize writes its own straight into State.Notes / State.Errors
# (Add-FinalizeMessage), and its results never carry any. Phase B must have them in the State before
# it computes the verdict for the report, and the runner appends whatever a result carries, so a
# result that carried them too would list every one twice. Phase A's note is saved with
# FinalRebootDone, so it survives the final restart.

$script:FinalizeStepId = 'finalize'
$script:WindowsUpdatePolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:NoAutoRebootValueName = 'NoAutoRebootWithLoggedOnUsers'
$script:SetupReportFileName = 'Setup-Report.txt'

function Add-FinalizeMessage {
  # Private. Appends Text to State.Notes or State.Errors (kept an array), unless it is already there:
  # Phase B can run twice (a crash before the runner saved its result), and must not list a note twice.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][ValidateSet('Notes', 'Errors')][string]$Field,
    [Parameter(Mandatory)][string]$Text
  )

  $existing = @(@($State[$Field]) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
  if ($existing -contains $Text) { return }
  $State[$Field] = @($existing + $Text)
  $level = if ($Field -eq 'Errors') { 'ERROR' } else { 'WARN' }
  Write-SetupLog -Message "Finalize: $Text" -Level $level
}

function ConvertTo-UtcDateTime {
  # Private. A [datetime], or an ISO 8601 string (parsed with the invariant culture, keeping its
  # offset or 'Z'), as a UTC [datetime]; $null when it is neither. A value without any zone counts as
  # UTC already (SetAtUtc is written in UTC).
  [CmdletBinding()]
  [OutputType([datetime])]
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) {
    $when = [datetime]$Value
  } else {
    $when = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::RoundtripKind
    if (-not [datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$when)) { return $null }
  }
  if ($when.Kind -eq [DateTimeKind]::Local) { return $when.ToUniversalTime() }
  if ($when.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($when, [DateTimeKind]::Utc) }
  return $when
}

function Get-LastBootUtc {
  <#
  .SYNOPSIS
    When Windows last started (Win32_OperatingSystem.LastBootUpTime), in UTC; $null when it cannot be
    read (logged as WARN). Read-only; never throws.
  #>
  [CmdletBinding()]
  [OutputType([datetime])]
  param()

  try {
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    if ($boot -isnot [datetime]) { throw 'LastBootUpTime is missing' }
    return $boot.ToUniversalTime()
  } catch {
    Write-SetupLog -Message 'The last boot time could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
    return $null
  }
}

function Test-FinalRebootNeeded {
  <#
  .SYNOPSIS
    $true when the final restart is needed (spec 8.4: only restart when needed).
  .DESCRIPTION
    Either:
      - Windows says a restart is pending (Test-PendingReboot: CBS, Windows Update, file renames, a
        pending computer rename), or
      - the default-browser step is Done and its Data.SetAtUtc is at or after the last boot: nobody
        has signed in since the DefaultAssociationsConfiguration policy was set, and it only applies
        at a sign-in (ruling R16; RebootCount cannot tell, because interruptions also raise it).
    A default-browser step that is not Done, or has no readable SetAtUtc, needs no restart. LastBootUtc
    defaults to Get-LastBootUtc (read only when needed); when that cannot be read, a Done step is
    assumed to need the restart.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][hashtable]$Signals,
    [Parameter(Mandatory)][hashtable]$State,
    [datetime]$LastBootUtc
  )

  if (Test-PendingReboot -Signals $Signals) {
    Write-SetupLog -Message 'Final restart needed: Windows has a restart pending' -Data @{ signals = $Signals }
    return $true
  }

  $step = $null
  if ($State['Steps'] -is [System.Collections.IDictionary]) { $step = $State['Steps']['default-browser'] }
  if ($step -isnot [System.Collections.IDictionary] -or [string]$step['Status'] -ne 'Done') { return $false }
  $data = $step['Data']
  if ($data -isnot [System.Collections.IDictionary] -or $null -eq $data['SetAtUtc']) { return $false }
  $setAt = ConvertTo-UtcDateTime $data['SetAtUtc']
  if ($null -eq $setAt) {
    Write-SetupLog -Message 'The default-browser set time is unreadable; no restart for it' -Level WARN -Data @{ setAtUtc = [string]$data['SetAtUtc'] }
    return $false
  }

  if ($PSBoundParameters.ContainsKey('LastBootUtc')) {
    $boot = ConvertTo-UtcDateTime $LastBootUtc
  } else {
    $boot = Get-LastBootUtc
    if ($null -eq $boot) {
      Write-SetupLog -Message 'Final restart needed: the last boot time is unknown, so the browser policy may not have applied'
      return $true
    }
  }

  $needed = ($setAt -ge $boot)
  Write-SetupLog -Message 'Final restart check for the browser policy' -Data @{
    setAtUtc = $setAt.ToString('o'); lastBootUtc = $boot.ToString('o'); needed = $needed
  }
  return $needed
}

function Remove-RegistryValueIfPresent {
  # Private. Removes ONE registry value, never its key (other software or an administrator may keep
  # settings there). A value that is not there is fine. A refused removal is a WARN. Never throws.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name
  )

  try {
    $present = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $present) { return }
    Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    Write-SetupLog -Message 'Registry value removed' -Data @{ path = $Path; name = $Name }
  } catch {
    Write-SetupLog -Message 'Registry value could not be removed' -Level WARN -Data @{ path = $Path; name = $Name; error = $_.Exception.Message }
  }
}

function Remove-SetupItem {
  # Private. Best-effort delete of a file, or of a folder with everything in it. A path that is not
  # there is fine. A failure is a WARN. Never throws.
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyString()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    Write-SetupLog -Message 'Removed' -Data @{ path = $Path }
  } catch {
    Write-SetupLog -Message 'Could not remove' -Level WARN -Data @{ path = $Path; error = $_.Exception.Message }
  }
}

function Remove-DefaultAssociationsFile {
  # Private. Deletes the default-associations XML (Get-DefaultAssociationsPath), then its folder
  # (%ProgramData%\BenTech) only when nothing else is in it. Never throws.
  [CmdletBinding()]
  param()

  try {
    $file = Get-DefaultAssociationsPath
    Remove-SetupItem -Path $file
    $folder = Split-Path -Parent $file
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { return }
    if ($null -ne (Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop | Select-Object -First 1)) { return }
    # Not Remove-Item: on a folder that is not empty (something just arrived) it would prompt.
    # Directory.Delete without recursion throws instead, and that is only a WARN.
    [IO.Directory]::Delete($folder, $false)
    Write-SetupLog -Message 'Removed' -Data @{ path = $folder }
  } catch {
    Write-SetupLog -Message 'The default-associations file could not be cleaned up' -Level WARN -Data @{ error = $_.Exception.Message }
  }
}

function ConvertTo-BitLockerFinding {
  <#
  .SYNOPSIS
    Pure. Get-BitLockerState's answer as @{ Text; Note; Error } for the report and the verdict.
  .DESCRIPTION
    Absent                                -> 'Not present'
    Unknown, or Present without a status  -> 'Unknown',    Note 'BitLocker status could not be read'
    decrypting (action Wait)              -> 'Decrypting', Note 'BitLocker decryption still running'
    encrypted, not decrypting (Decrypt)   -> 'Encrypted',  Error 'Drive still encrypted and not decrypting'
    decrypted (action None)               -> 'Off'
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()][hashtable]$BitLockerState)

  $presence = if ($null -ne $BitLockerState) { [string]$BitLockerState['Presence'] } else { 'Unknown' }
  if ($presence -eq 'Absent') { return @{ Text = 'Not present'; Note = $null; Error = $null } }
  $status = if ($null -ne $BitLockerState) { $BitLockerState['Status'] } else { $null }
  if ($presence -ne 'Present' -or $null -eq $status) {
    return @{ Text = 'Unknown'; Note = 'BitLocker status could not be read'; Error = $null }
  }

  $action = Get-BitLockerAction -ConversionStatus ([int]$status)
  if ($action -eq 'Wait') { return @{ Text = 'Decrypting'; Note = 'BitLocker decryption still running'; Error = $null } }
  if ($action -eq 'Decrypt') { return @{ Text = 'Encrypted'; Note = $null; Error = 'Drive still encrypted and not decrypting' } }
  return @{ Text = 'Off'; Note = $null; Error = $null }
}

function Write-SetupReport {
  # Private. Writes the lines with CRLF breaks (and a final CRLF) as UTF-8 WITH a BOM, creating the
  # folder if needed. Throws on failure.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
  )

  $folder = Split-Path -Parent $Path
  if ($folder) { [void][IO.Directory]::CreateDirectory($folder) }
  [IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $true))
}

function Restore-PostSetupSettings {
  <#
  .SYNOPSIS
    Private. Undoes what the run changed only for its own duration (Phase A steps 1-3). Saves nothing:
    the caller does. Never throws.
  .DESCRIPTION
    1. Restore-FinalPowerSettings; $false (or a throw) -> Note 'Some power settings could not be restored'.
    2. The NoAutoRebootWithLoggedOnUsers VALUE is removed (the AU key stays).
    3. FinalRebootDone = $true.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Context)

  $runState = $Context.State

  $restored = $false
  try {
    $restored = [bool](Restore-FinalPowerSettings -State $runState -Config $Context.Config)
  } catch {
    Write-SetupLog -Message 'Final power settings could not be restored' -Level WARN -Data @{ error = $_.Exception.Message }
  }
  if (-not $restored) { Add-FinalizeMessage -State $runState -Field Notes -Text 'Some power settings could not be restored' }

  Remove-RegistryValueIfPresent -Path $script:WindowsUpdatePolicyKey -Name $script:NoAutoRebootValueName

  $runState.FinalRebootDone = $true
}

function Invoke-FinalizePhaseA {
  <#
  .SYNOPSIS
    Private. Phase A. Returns $true when the final restart should happen now.
  .DESCRIPTION
    1-3. Restore-PostSetupSettings: final power settings, the NoAutoRebootWithLoggedOnUsers value
       removed, FinalRebootDone = $true. Then the state is saved (a failed save throws: the restart
       must not happen without it), so the call after the restart goes straight to Phase B.
    4. A restart is asked for only when Test-FinalRebootNeeded says so AND it can happen. A restart the
       runner then refuses would mark this step Failed and leave Phase B (and the report) unrun, so
       the refusals are decided here, recorded the way Invoke-ControlledReboot records them, and
       Phase B runs at once instead:
         - no resume task (State.ResumeTaskMissing): Error 'Restart skipped: no resume task' (once);
         - RebootCount at caps.maxReboots: State.RebootCapHit = $true (the verdict says 'Reboot limit
           reached').
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $runState = $Context.State
  Restore-PostSetupSettings -Context $Context
  Save-RunState -State $runState -Root $Context.Root

  if (-not (Test-FinalRebootNeeded -Signals (Get-PendingRebootSignals) -State $runState)) {
    Write-SetupLog -Message 'No final restart needed'
    return $false
  }
  if ($runState.ResumeTaskMissing -eq $true) {
    Add-FinalizeMessage -State $runState -Field Errors -Text 'Restart skipped: no resume task'
    return $false
  }
  $maxReboots = [int]$Context.Config.caps.maxReboots   # a missing cap reads as 0: never restart
  if ([int]$runState.RebootCount -ge $maxReboots) {
    $runState.RebootCapHit = $true
    Write-SetupLog -Message 'Final restart skipped: reboot cap reached' -Level WARN -Data @{ rebootCount = [int]$runState.RebootCount; maxReboots = $maxReboots }
    return $false
  }
  Write-SetupLog -Message 'Final restart requested'
  return $true
}

function Complete-SetupFinalization {
  <#
  .SYNOPSIS
    Phase B: finishes the run and writes the report. Never restarts the machine. Returns
    Done('Finalized'), or Failed('Setup report could not be written').
  .DESCRIPTION
    Invoke-StepFinalize calls it for Phase B. The entry point also calls it on its own (ruling R26)
    when a run returns 'Completed' with the finalize step not Done (the final restart failed, or
    finalize ended Failed or stuck), so the resume task is still removed and the report still
    written. For that case:
      - FinalRebootDone not $true: Restore-PostSetupSettings first (final power settings, the
        no-auto-reboot value), but never a restart.
      - finalize found Failed: Note 'Finalize completed after an earlier failure: <its message>', so
        the run can never look green after a failure. A failed restart also keeps its 'Restart
        failed: ...' Error, so that run stays red.
      - the state is saved at the end (a failed save is a WARN; the runner saves again anyway).
    Then, in order:
      1. Chrome installed but not the default browser -> Note 'Chrome is not the default browser'
         (checked before its policy is removed).
      2. The DefaultAssociationsConfiguration policy value removed (the key stays), the XML deleted,
         and its folder too when it is empty.
      3. LENOVO: the AdminCommandLine policy values removed (a forced BIOS restart can skip the
         per-pass cleanup).
      4. Activation not 'Activated' -> Note 'Windows not activated'.
      5. BitLocker (ConvertTo-BitLockerFinding): a Note or an Error, and the report's BitLocker text.
      6. Windows 10 -> Note 'Windows 10: no security updates'.
      7. The resume task removed; a removal that fails -> Note 'Resume task could not be removed'.
      8. Downloads\, <Root>\setup.ps1 and <Root>\config.json deleted (best effort); state.json and
         Logs\ stay.
      9. State.EndedAt = now.
     10. Steps['finalize'] marked Done('Finalized') first, so the verdict cannot call this step "did
         not finish"; then the verdict, and the report in <LogDir>\Setup-Report.txt. A report that
         cannot be written marks finalize Failed('Setup report could not be written') instead.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $runState = $Context.State
  $machine = if ($runState.Machine -is [System.Collections.IDictionary]) { $runState.Machine } else { @{} }
  $hasFinalizeStep = ($runState.Steps -is [hashtable] -and $runState.Steps.ContainsKey($script:FinalizeStepId))
  $earlierStatus = if ($hasFinalizeStep) { [string]$runState.Steps[$script:FinalizeStepId].Status } else { '' }
  Write-SetupLog -Message 'Completing the setup' -Data @{ finalizeStatus = $earlierStatus; finalRebootDone = ($runState.FinalRebootDone -eq $true) }

  if ($runState.FinalRebootDone -ne $true) { Restore-PostSetupSettings -Context $Context }
  if ($earlierStatus -eq 'Failed') {
    $earlierMessage = [string]$runState.Steps[$script:FinalizeStepId].Message
    if ([string]::IsNullOrWhiteSpace($earlierMessage)) { $earlierMessage = '(no details)' }
    Add-FinalizeMessage -State $runState -Field Notes -Text "Finalize completed after an earlier failure: $earlierMessage"
  }

  if ((Test-ChromeInstalled) -and ((Get-DefaultBrowserProgId) -ne 'ChromeHTML')) {
    Add-FinalizeMessage -State $runState -Field Notes -Text 'Chrome is not the default browser'
  }

  Remove-RegistryValueIfPresent -Path $script:DefaultAssociationsPolicyKey -Name $script:DefaultAssociationsPolicyName
  Remove-DefaultAssociationsFile

  if ([string]$machine['Brand'] -eq 'LENOVO') { Remove-LenovoAdminCommandLine }

  $activation = Get-ActivationStatus
  if ($activation -ne 'Activated') { Add-FinalizeMessage -State $runState -Field Notes -Text 'Windows not activated' }

  try {
    $bitLocker = Get-BitLockerState
  } catch {
    Write-SetupLog -Message 'BitLocker state could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
    $bitLocker = @{ Presence = 'Unknown'; Volume = $null; Status = $null }
  }
  $finding = ConvertTo-BitLockerFinding -BitLockerState $bitLocker
  if ($finding.Note) { Add-FinalizeMessage -State $runState -Field Notes -Text $finding.Note }
  if ($finding.Error) { Add-FinalizeMessage -State $runState -Field Errors -Text $finding.Error }

  if ($machine['IsWindows10'] -eq $true) { Add-FinalizeMessage -State $runState -Field Notes -Text 'Windows 10: no security updates' }

  # Left behind, the task would start setup again at every logon (spec 4: no junk), so a failure is a Note.
  if ((Unregister-ResumeTask) -ne $true) { Add-FinalizeMessage -State $runState -Field Notes -Text 'Resume task could not be removed' }

  Remove-SetupItem -Path $Context.DownloadDir
  Remove-SetupItem -Path (Join-Path $Context.Root 'setup.ps1')
  Remove-SetupItem -Path (Join-Path $Context.Root 'config.json')

  $runState.EndedAt = Get-StateTimestamp

  if ($hasFinalizeStep) { Set-StepState -State $runState -StepId $script:FinalizeStepId -Status Done -Message 'Finalized' }
  $verdict = Get-RunVerdict -State $runState
  $reportPath = Join-Path $Context.LogDir $script:SetupReportFileName
  try {
    $lines = Format-SetupReport -State $runState -Verdict $verdict -Activation $activation -BitLockerText $finding.Text -AppVersions (Get-InstalledAppVersions)
    Write-SetupReport -Path $reportPath -Lines $lines
    Write-SetupLog -Message 'Setup report written' -Data @{ path = $reportPath; result = $verdict.Color }
    $result = New-StepResult -Status Done -Message 'Finalized'
  } catch {
    Write-SetupLog -Message 'Setup report could not be written' -Level ERROR -Data @{ path = $reportPath; error = $_.Exception.Message }
    $result = New-StepResult -Status Failed -Message 'Setup report could not be written'
    if ($hasFinalizeStep) { Set-StepState -State $runState -StepId $script:FinalizeStepId -Status Failed -Message $result.Message }
  }

  # Called on its own, nobody else saves this; through the runner it is saved again right after.
  try {
    Save-RunState -State $runState -Root $Context.Root
  } catch {
    Write-SetupLog -Message 'The run state could not be saved after finalizing' -Level WARN -Data @{ error = $_.Exception.Message }
  }
  return $result
}

function Invoke-StepFinalize {
  <#
  .SYNOPSIS
    Step 17: Phase A, then (after the final restart, or at once) Phase B. See the file header.
  .DESCRIPTION
    FinalRebootDone $false: Phase A. When it asks for the final restart, returns
    Continue('Restarting to finish setup') with Reboot 'Now'; the runner restarts, and the next call
    runs Phase B. Otherwise Phase B runs in this same call. FinalRebootDone $true: Phase B.
    Phase B is Complete-SetupFinalization: Done('Finalized'), or Failed('Setup report could not be
    written'). The results never carry Notes or Errors: they are already in the State (see the file
    header).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  if ($Context.State.FinalRebootDone -ne $true) {
    if (Invoke-FinalizePhaseA -Context $Context) {
      return New-StepResult -Status Continue -Message 'Restarting to finish setup' -Reboot Now
    }
  }
  return Complete-SetupFinalization -Context $Context
}
