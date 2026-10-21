# src/Steps/Finalize.ps1
# Step 17, "Finalize" (spec 8.3 step 17, 8.4, 8.7 and 12): the last step. It runs in two phases.
#   Both start by waiting for a Microsoft 365 setup still running in the background (Wait-OfficeBackground,
#     v2 spec 4.6; a no-op without one): Phase A restores power settings and Phase B deletes Downloads\
#     (the ODT and office.xml), so neither may race a live install. Phase B then un-hides the Windows
#     updates the run hid (Restore-WuHiddenUpdates, final review C1).
#   Phase A (State.FinalRebootDone is $false): the final power settings, the no-auto-reboot policy
#     value removed, FinalRebootDone saved, one attempt to activate Windows (spec 9.5), then ONE
#     final restart when something needs it (Test-FinalRebootNeeded) and a restart is possible.
#   Phase B (after that restart, or at once when none is needed or possible): the default-browser
#     check (waiting up to 120 s for Chrome when someone has signed in since its policy was set,
#     spec 9.4), the temporary policies and files removed, activation and BitLocker checked, the
#     resume task removed, the downloads and the pinned script deleted, the restore point (toolbox spec
#     5.4: a snapshot of the finished PC, when Choices.RestorePoint), EndedAt, and the report. This is
#     Complete-SetupFinalization, which the entry point (Task 17) also calls on its own when a run
#     ends with finalize not Done (the final restart failed), so no run is left without a report or
#     with the resume task still registered (ruling R26). The entry point then shows the final screen.
# Needs StepResult.ps1, Logging.ps1, Activity.ps1 (Set-SetupNow, Add-SetupActivity), State.ps1, Catalog.ps1 +
# Verdict.ps1, Reboot.ps1, Prepare.ps1 (Set-RegistryDword, Get-RegistryValue), Apps.ps1, DefaultBrowser.ps1,
# BitLocker.ps1, Vendor.ps1, Winget.ps1 (Invoke-PowerShellChild, Get-OutputTail), Office.ps1
# (Wait-OfficeBackground), WindowsUpdate.ps1 (Restore-WuHiddenUpdates), StartScreen.ps1 (ConvertTo-ScreenText),
# Report.ps1 and Toolbox\SetupPlanner.ps1 (the report's profile line); the bundle holds every file.
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

# Spec 9.5: the child that asks Windows to activate. Each Windows licensing product with a product key
# that is not licensed gets Activate(); a ReturnValue other than 0 is exit 2, and an error (Activate
# throws on a refusal, Stop makes it end the child) is exit 1. Same ApplicationID as Report.ps1's
# $script:WindowsLicensingApplicationId.
$script:WindowsActivationCommand = @'
$ErrorActionPreference = 'Stop'; $f = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL AND LicenseStatus <> 1"
foreach ($p in @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $f)) { $r = Invoke-CimMethod -InputObject $p -MethodName Activate; if ($r.ReturnValue -ne 0) { exit 2 } }
'@
$script:WindowsActivationTimeoutMinutes = 3

# Toolbox spec 5.4: the restore point at the very end of the run. Windows silently skips a second restore point
# within SystemRestorePointCreationFrequency minutes (24 hours when the value is absent), so the main process
# sets it to 0 for the attempt and always puts it back (or removes it again) afterwards.
$script:SystemRestoreKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$script:RestorePointFrequencyName = 'SystemRestorePointCreationFrequency'
$script:RestorePointTimeoutMinutes = 10
# The child (Invoke-PowerShellChild prepends $ProgressPreference): System Protection on for the system drive,
# the newest restore point's sequence number, one checkpoint, the number again. Exit 0 = a new point is
# confirmed; 1 = an error stopped it; 3 = no new point. Decided by numbers and the exit code, never by text.
$script:RestorePointCommand = @'
$ErrorActionPreference = 'Stop'; $d = $env:SystemDrive + '\'
Enable-ComputerRestore -Drive $d
$b = [long](@(@(Get-ComputerRestorePoint | ForEach-Object { [long]$_.SequenceNumber }) + 0) | Measure-Object -Maximum).Maximum
Checkpoint-Computer -Description 'BenTech setup' -RestorePointType MODIFY_SETTINGS
$a = [long](@(@(Get-ComputerRestorePoint | ForEach-Object { [long]$_.SequenceNumber }) + 0) | Measure-Object -Maximum).Maximum
if ($a -gt $b) { exit 0 } else { exit 3 }
'@

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

function Get-BrowserPolicySignIn {
  <#
  .SYNOPSIS
    Private. Whether anyone has signed in since the default-browser step set its policy. Returns
    @{ Result; SetAtUtc; LastBootUtc } (both UTC [datetime], or $null when not read). Never throws.
  .DESCRIPTION
    The DefaultAssociationsConfiguration policy only applies at a sign-in (ruling R16), and a boot
    after the set time means one happened (RebootCount cannot tell: interruptions also raise it).
    Result:
      NotSet   - the default-browser step is not Done, or has no readable Data.SetAtUtc (a WARN when
                 it is there but unreadable): there is no policy to apply.
      Pending  - SetAtUtc is at or after the last boot: nobody has signed in since.
      SignedIn - the last boot came after SetAtUtc.
      Unknown  - the last boot time could not be read.
    LastBootUtc defaults to Get-LastBootUtc, read only for a Done step with a readable SetAtUtc. Used
    by Test-FinalRebootNeeded (restart for it) and Complete-SetupFinalization (wait for it, spec 9.4).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [datetime]$LastBootUtc
  )

  $answer = @{ Result = 'NotSet'; SetAtUtc = $null; LastBootUtc = $null }
  $step = $null
  if ($State['Steps'] -is [System.Collections.IDictionary]) { $step = $State['Steps']['default-browser'] }
  if ($step -isnot [System.Collections.IDictionary] -or [string]$step['Status'] -ne 'Done') { return $answer }
  $data = $step['Data']
  if ($data -isnot [System.Collections.IDictionary] -or $null -eq $data['SetAtUtc']) { return $answer }
  $setAt = ConvertTo-UtcDateTime $data['SetAtUtc']
  if ($null -eq $setAt) {
    Write-SetupLog -Message 'The default-browser set time is unreadable; treated as no policy set' -Level WARN -Data @{ setAtUtc = [string]$data['SetAtUtc'] }
    return $answer
  }
  $answer.SetAtUtc = $setAt

  $boot = if ($PSBoundParameters.ContainsKey('LastBootUtc')) { ConvertTo-UtcDateTime $LastBootUtc } else { Get-LastBootUtc }
  if ($null -eq $boot) {
    $answer.Result = 'Unknown'
    return $answer
  }
  $answer.LastBootUtc = $boot
  $answer.Result = if ($setAt -ge $boot) { 'Pending' } else { 'SignedIn' }
  return $answer
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
        at a sign-in (Get-BrowserPolicySignIn says Pending).
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

  $check = @{ State = $State }
  if ($PSBoundParameters.ContainsKey('LastBootUtc')) { $check['LastBootUtc'] = $LastBootUtc }
  $signIn = Get-BrowserPolicySignIn @check
  if ($signIn.Result -eq 'NotSet') { return $false }
  if ($signIn.Result -eq 'Unknown') {
    Write-SetupLog -Message 'Final restart needed: the last boot time is unknown, so the browser policy may not have applied'
    return $true
  }

  $needed = ($signIn.Result -eq 'Pending')
  Write-SetupLog -Message 'Final restart check for the browser policy' -Data @{
    setAtUtc = $signIn.SetAtUtc.ToString('o'); lastBootUtc = $signIn.LastBootUtc.ToString('o'); needed = $needed
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

function Wait-ChromeDefault {
  <#
  .SYNOPSIS
    $true as soon as Chrome (ChromeHTML) is the default browser; $false when it still is not after the
    last read. Spec 9.4: right after the final restart, Windows may not have applied the policy yet.
  .DESCRIPTION
    Reads Get-DefaultBrowserProgId at once and again after each wait of PollSeconds: Attempts reads
    and Attempts - 1 waits (the defaults: 25 reads, 24 waits of 5 s = 120 s). It counts reads, not
    clock time, so it always ends. Never throws (Get-DefaultBrowserProgId never does).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [ValidateRange(1, 1000)][int]$Attempts = 25,
    [ValidateRange(0, 3600)][int]$PollSeconds = 5
  )

  Enter-SetupWait -LimitMinutes (($Attempts - 1) * $PollSeconds / 60)
  try {
    for ($read = 1; $read -le $Attempts; $read++) {
      if ((Get-DefaultBrowserProgId) -eq 'ChromeHTML') {
        Write-SetupLog -Message 'Chrome is the default browser' -Data @{ reads = $read; waitedSeconds = ($read - 1) * $PollSeconds }
        return $true
      }
      if ($read -lt $Attempts) { Wait-SetupDelay -Seconds $PollSeconds }
    }
  } finally {
    Exit-SetupWait
  }
  Write-SetupLog -Message 'Chrome is still not the default browser after the wait' -Level WARN -Data @{ reads = $Attempts; waitedSeconds = ($Attempts - 1) * $PollSeconds }
  return $false
}

function Invoke-WindowsActivation {
  <#
  .SYNOPSIS
    One attempt to activate Windows (spec 9.5). Returns 'NotNeeded', 'Activated' or 'Failed'. Never
    throws.
  .DESCRIPTION
    - Get-ActivationStatus other than 'Not activated' (Activated, or Unknown: it could not be read)
      -> NotNeeded.
    - No Windows SoftwareLicensingProduct row with a product key (a read-only CIM query, the filter
      Get-ActivationStatus uses) -> NotNeeded: there is nothing to activate with.
    - Otherwise $script:WindowsActivationCommand in a child PowerShell (Invoke-PowerShellChild,
      through Invoke-External) limited to 3 minutes: exit 0 -> Activated (INFO). A timeout, another
      exit code or a child that cannot start -> WARN 'Windows activation attempt failed' -> Failed.
      A product-key query that fails is a WARN too, and Failed.
    Nothing reads the answer to decide anything: Phase B reads the status again for the report, so a
    failed attempt keeps the Note 'Windows not activated'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $status = Get-ActivationStatus
  if ($status -ne 'Not activated') {
    Write-SetupLog -Message 'No Windows activation attempt needed' -Data @{ activation = [string]$status }
    return 'NotNeeded'
  }

  try {
    $filter = "ApplicationID='{0}' AND PartialProductKey IS NOT NULL" -f $script:WindowsLicensingApplicationId
    $keyed = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop | Where-Object { $null -ne $_ })
  } catch {
    Write-SetupLog -Message 'Windows product keys could not be read; no activation attempt' -Level WARN -Data @{ error = $_.Exception.Message }
    return 'Failed'
  }
  if ($keyed.Count -eq 0) {
    Write-SetupLog -Message 'No Windows activation attempt: no product key is installed'
    return 'NotNeeded'
  }

  Write-SetupLog -Message 'Trying to activate Windows' -Data @{ timeoutMinutes = $script:WindowsActivationTimeoutMinutes }
  try {
    $run = Invoke-PowerShellChild -Command $script:WindowsActivationCommand -TimeoutMinutes $script:WindowsActivationTimeoutMinutes
  } catch {
    Write-SetupLog -Message 'Windows activation attempt failed' -Level WARN -Data @{ error = $_.Exception.Message }
    return 'Failed'
  }
  if ($run.TimedOut -or $null -eq $run.ExitCode -or $run.ExitCode -ne 0) {
    Write-SetupLog -Message 'Windows activation attempt failed' -Level WARN -Data @{ exitCode = $run.ExitCode; timedOut = [bool]$run.TimedOut; tail = (Get-OutputTail -Output $run.Output) }
    return 'Failed'
  }
  Write-SetupLog -Message 'Windows activated'
  return 'Activated'
}

function Invoke-SetupRestorePoint {
  <#
  .SYNOPSIS
    The restore point at the very end of the run (toolbox spec 5.4). Returns 'NotChosen', 'Created' or
    'NotConfirmed'. Never throws.
  .DESCRIPTION
    - Choices.RestorePoint not $true (not chosen, or an older state without it): 'NotChosen'; nothing is read.
    - State.RestorePointTried already $true (a repeated finalize): never a second attempt. 'Created' when
      State.RestorePointCreated is $true, else 'NotConfirmed' with the Note.
    - Otherwise RestorePointTried = $true (RestorePointCreated $false) is saved FIRST. A save that throws is
      'NotConfirmed' with the Note, and nothing else happens: no child, the frequency value untouched.
    Then, in order:
      1. the original SystemRestorePointCreationFrequency is recorded (logged: its value, or absent);
      2. it is set to 0 (a refusal is a WARN: the child still runs and its sequence check decides);
      3. the NOW sub-title 'Creating a restore point';
      4. $script:RestorePointCommand in one child (Invoke-PowerShellChild) limited to
         Config.timeoutsMinutes.restorePoint minutes (10 when missing or not above 0);
      5. whatever the child did (finally): an original that existed is written back, an absent one is removed
         again (Remove-RegistryValueIfPresent), and it is read back. A value that is not back is its own Note,
         'Restore point frequency value could not be put back', so a value stuck at 0 is never silent. The
         sub-title is cleared.
    Exit 0 without a timeout is 'Created' (RestorePointCreated = $true, activity 'Restore point created').
    A timeout, another or no exit code, or a child that cannot start is 'NotConfirmed' with the Note
    'Restore point could not be confirmed'. Notes go straight into State.Notes (Add-FinalizeMessage).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $runState = $Context.State
  $notConfirmed = 'Restore point could not be confirmed'
  $choices = if ($runState.Choices -is [System.Collections.IDictionary]) { $runState.Choices } else { @{} }
  if (-not (($choices['RestorePoint'] -is [bool]) -and $choices['RestorePoint'])) { return 'NotChosen' }

  if ($runState.RestorePointTried -eq $true) {
    if ($runState.RestorePointCreated -eq $true) { return 'Created' }
    Add-FinalizeMessage -State $runState -Field Notes -Text $notConfirmed
    return 'NotConfirmed'
  }

  $runState.RestorePointTried = $true
  $runState.RestorePointCreated = $false
  try {
    Save-RunState -State $runState -Root $Context.Root
  } catch {
    Write-SetupLog -Message 'No restore point: the attempt could not be saved first' -Level WARN -Data @{ error = (ConvertTo-ScreenText $_.Exception.Message) }
    Add-FinalizeMessage -State $runState -Field Notes -Text $notConfirmed
    return 'NotConfirmed'
  }

  $timeout = $script:RestorePointTimeoutMinutes
  $configured = 0.0
  if ([double]::TryParse([string]$Context.Config.timeoutsMinutes.restorePoint, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$configured) -and $configured -gt 0) {
    $timeout = $configured
  }

  $original = Get-RegistryValue -Path $script:SystemRestoreKey -Name $script:RestorePointFrequencyName
  $originalText = if ($original.Exists) { ConvertTo-ScreenText ([string]$original.Value) } else { 'absent' }
  Write-SetupLog -Message 'Restore point: creation frequency recorded' -Data @{ original = $originalText; timeoutMinutes = $timeout }
  if ((Set-RegistryDword -Path $script:SystemRestoreKey -Name $script:RestorePointFrequencyName -Value 0) -ne $true) {
    Write-SetupLog -Message 'Restore point: the creation frequency could not be set to 0; trying anyway' -Level WARN
  }

  $created = $false
  Set-SetupNow -SubTitle 'Creating a restore point'
  try {
    $run = Invoke-PowerShellChild -Command $script:RestorePointCommand -TimeoutMinutes $timeout
    $created = (-not $run.TimedOut) -and ($null -ne $run.ExitCode) -and ([int]$run.ExitCode -eq 0)
    if (-not $created) {
      Write-SetupLog -Message 'Restore point could not be confirmed' -Level WARN -Data @{ exitCode = $run.ExitCode; timedOut = [bool]$run.TimedOut; tail = (ConvertTo-ScreenText (Get-OutputTail -Output $run.Output)) }
    }
  } catch {
    Write-SetupLog -Message 'Restore point child could not run' -Level WARN -Data @{ error = (ConvertTo-ScreenText $_.Exception.Message) }
  } finally {
    # The value must never stay at 0 on the customer's PC, whatever the child did.
    if ($original.Exists) {
      $null = Set-RegistryDword -Path $script:SystemRestoreKey -Name $script:RestorePointFrequencyName -Value $original.Value
    } else {
      Remove-RegistryValueIfPresent -Path $script:SystemRestoreKey -Name $script:RestorePointFrequencyName
    }
    $after = Get-RegistryValue -Path $script:SystemRestoreKey -Name $script:RestorePointFrequencyName
    $back = if ($original.Exists) { $after.Exists -and ([string]$after.Value -ceq [string]$original.Value) } else { -not $after.Exists }
    if (-not $back) { Add-FinalizeMessage -State $runState -Field Notes -Text 'Restore point frequency value could not be put back' }
    Set-SetupNow -SubTitle ''
  }

  $runState.RestorePointCreated = $created
  if ($created) {
    Write-SetupLog -Message 'Restore point created'
    Add-SetupActivity -Text 'Restore point created'
    return 'Created'
  }
  Add-FinalizeMessage -State $runState -Field Notes -Text $notConfirmed
  return 'NotConfirmed'
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
    3b. Invoke-WindowsActivation (spec 9.5): one attempt, before the final restart. Phase B, after
       that restart, does not try again.
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
  $null = Invoke-WindowsActivation

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
      - FinalRebootDone not $true (Phase A never ran): Invoke-WindowsActivation (the one attempt
        Phase A would have made, spec 9.5), then Restore-PostSetupSettings (final power settings, the
        no-auto-reboot value), but never a restart.
      - finalize found Failed: Note 'Finalize completed after an earlier failure: <its message>', so
        the run can never look green after a failure. A failed restart also keeps its 'Restart
        failed: ...' Error, so that run stays red.
      - the state is saved at the end (a failed save is a WARN; the runner saves again anyway).
    Before anything else it waits for a background Microsoft 365 setup that is still running
    (Wait-OfficeBackground -Purpose Finish): step 8 deletes the ODT and office.xml.
    Right after that (final review C1, v1 spec 8.8), Restore-WuHiddenUpdates un-hides the Windows updates
    this run (or the previous one) hid, in a -WuUnhide child, before step 8 deletes setup.ps1; each update
    still hidden afterwards is an Error 'Windows update still hidden: <title> - un-hide it in Windows
    Update'. It runs once per run (State.HiddenUpdatesRestored).
    Then, in order:
      1. Chrome installed but not the default browser -> Note 'Chrome is not the default browser'
         (checked before its policy is removed). Spec 9.4: when the default-browser step set the
         policy and a sign-in has happened since (Get-BrowserPolicySignIn: SignedIn, i.e. after the
         final restart), Wait-ChromeDefault gives Windows up to 120 s to apply it. Otherwise (no
         policy, nobody signed in since: a refused or failed restart, or the boot time unknown) it is
         read once: without a sign-in the policy cannot apply, so waiting would be dead time.
      2. The DefaultAssociationsConfiguration policy value removed (the key stays), the XML deleted,
         and its folder too when it is empty.
      3. LENOVO: the AdminCommandLine policy values removed (a forced BIOS restart can skip the
         per-pass cleanup).
      4. Activation 'Not activated' -> Note 'Windows not activated'; 'Unknown' (it could not be read)
         -> Note 'Windows activation status unknown'.
      5. BitLocker (ConvertTo-BitLockerFinding): a Note or an Error, and the report's BitLocker text.
      6. Windows 10 -> Note 'Windows 10: no security updates'.
      7. The resume task removed; a removal that fails -> Note 'Resume task could not be removed'.
      8. Downloads\, <Root>\setup.ps1 and <Root>\config.json deleted (best effort); state.json and
         Logs\ stay.
      8b. The restore point (Invoke-SetupRestorePoint, toolbox spec 5.4), when Choices.RestorePoint: one
         bounded child, at most once per run, after everything above so the snapshot is the finished PC.
         A point that is not confirmed is the Note 'Restore point could not be confirmed'.
      9. State.EndedAt = now.
     10. Steps['finalize'] marked Done('Finalized') first, so the verdict cannot call this step "did
         not finish"; then the verdict, and the report in <LogDir>\Setup-Report.txt (with the Smart
         App Control state, Get-SmartAppControlState). A report that
         cannot be written marks finalize Failed('Setup report could not be written') instead.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $null = Wait-OfficeBackground -Context $Context -Purpose Finish
  $runState = $Context.State
  $machine = if ($runState.Machine -is [System.Collections.IDictionary]) { $runState.Machine } else { @{} }
  $hasFinalizeStep = ($runState.Steps -is [hashtable] -and $runState.Steps.ContainsKey($script:FinalizeStepId))
  $earlierStatus = if ($hasFinalizeStep) { [string]$runState.Steps[$script:FinalizeStepId].Status } else { '' }
  Write-SetupLog -Message 'Completing the setup' -Data @{ finalizeStatus = $earlierStatus; finalRebootDone = ($runState.FinalRebootDone -eq $true) }

  # Final review C1 (v1 spec 8.8): what the run hid is un-hidden again; whatever stays hidden is red.
  foreach ($text in @(Restore-WuHiddenUpdates -Context $Context)) { Add-FinalizeMessage -State $runState -Field Errors -Text $text }

  if ($runState.FinalRebootDone -ne $true) {
    $null = Invoke-WindowsActivation
    Restore-PostSetupSettings -Context $Context
  }
  if ($earlierStatus -eq 'Failed') {
    $earlierMessage = [string]$runState.Steps[$script:FinalizeStepId].Message
    if ([string]::IsNullOrWhiteSpace($earlierMessage)) { $earlierMessage = '(no details)' }
    Add-FinalizeMessage -State $runState -Field Notes -Text "Finalize completed after an earlier failure: $earlierMessage"
  }

  if (Test-ChromeInstalled) {
    $signIn = Get-BrowserPolicySignIn -State $runState
    if ($signIn.Result -eq 'SignedIn') {
      $chromeIsDefault = Wait-ChromeDefault
    } else {
      if ($signIn.Result -ne 'NotSet') {
        Write-SetupLog -Message 'No wait for Chrome as default: no sign-in is known since the browser policy was set' -Data @{ signIn = $signIn.Result }
      }
      $chromeIsDefault = ((Get-DefaultBrowserProgId) -eq 'ChromeHTML')
    }
    if (-not $chromeIsDefault) { Add-FinalizeMessage -State $runState -Field Notes -Text 'Chrome is not the default browser' }
  }

  Remove-RegistryValueIfPresent -Path $script:DefaultAssociationsPolicyKey -Name $script:DefaultAssociationsPolicyName
  Remove-DefaultAssociationsFile

  if ([string]$machine['Brand'] -eq 'LENOVO') { Remove-LenovoAdminCommandLine }

  $activation = Get-ActivationStatus
  # M5: a status that could not be read is not "not activated".
  if ($activation -eq 'Unknown') { Add-FinalizeMessage -State $runState -Field Notes -Text 'Windows activation status unknown' }
  elseif ($activation -ne 'Activated') { Add-FinalizeMessage -State $runState -Field Notes -Text 'Windows not activated' }

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

  # Toolbox spec 5.4: the snapshot is the finished PC, without the setup's files, policies or resume task.
  $null = Invoke-SetupRestorePoint -Context $Context

  $runState.EndedAt = Get-StateTimestamp

  if ($hasFinalizeStep) { Set-StepState -State $runState -StepId $script:FinalizeStepId -Status Done -Message 'Finalized' }
  $verdict = Get-RunVerdict -State $runState
  $reportPath = Join-Path $Context.LogDir $script:SetupReportFileName
  try {
    $lines = Format-SetupReport -State $runState -Verdict $verdict -Activation $activation -BitLockerText $finding.Text -AppVersions (Get-InstalledAppVersions -Config $Context.Config) -SmartAppControl (Get-SmartAppControlState) -Config $Context.Config
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
    First waits for a Microsoft 365 setup still running in the background (Wait-OfficeBackground
    -Purpose Finish; a no-op without one).
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

  $null = Wait-OfficeBackground -Context $Context -Purpose Finish
  if ($Context.State.FinalRebootDone -ne $true) {
    if (Invoke-FinalizePhaseA -Context $Context) {
      return New-StepResult -Status Continue -Message 'Restarting to finish setup' -Reboot Now
    }
  }
  return Complete-SetupFinalization -Context $Context
}
