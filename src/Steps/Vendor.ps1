# src/Steps/Vendor.ps1
# Steps 12 and 14 (vendor silent updater, passes 1 and 2), 15 (vendor consumer app) and 16 (remove the
# business updater), spec 8.3 and 9.2. Needs StepResult.ps1, Logging.ps1, Process.ps1, Download.ps1,
# Config.ps1 (Get-Signers), Winget.ps1 (Invoke-WingetInstall, Invoke-WingetUninstall), BitLocker.ps1
# (Wait-BitLockerDecrypted, Suspend-BitLockerOnce) and Detection.ps1 (Test-OnACPower); the bundle holds
# every file.
#
# The business tools (Dell Command Update, Lenovo System Update, HP Image Assistant) apply EVERYTHING
# they recommend for the model (Q18), BIOS and firmware included. A BIOS flash on battery, or on a drive
# that BitLocker still protects, can leave a laptop dead or asking for a recovery key. So every pass
# first decides whether firmware is allowed at all (Invoke-VendorPass):
#   - Power, first: on battery, firmware is NOT allowed and the BitLocker gate is skipped (ruling R20).
#   - BitLocker (on AC only): decrypted (or absent) is fine. Still encrypted: it is suspended for one
#     restart; if that fails, firmware is NOT allowed.
#   - Power again, inside each tool function right before it applies anything (after its install,
#     download, extract or /configure): the BitLocker wait and that setup can be long, and the charger
#     may have been pulled meanwhile.
# When it is not allowed, the argument builders leave BIOS/firmware out (Review Focus #3).
#
# No vendor output text is ever parsed (Windows may be Hebrew). DCU and HPIA report through exit codes;
# Lenovo System Update has no documented exit codes, so its result comes from its WMI export.

$script:VendorToolNames = @{ dcu = 'Dell Command Update'; lsu = 'Lenovo System Update'; hpia = 'HP Image Assistant' }

# The brands whose business tool runs (steps 12/14) and is removed on laptops (step 16).
$script:VendorToolBrands = @('DELL', 'LENOVO', 'HP')

$script:BatteryNote = 'On battery: BIOS/firmware updates skipped'

$script:DcuConfigureArgs = '/configure -silent -autoSuspendBitLocker=enable'
$script:DcuConfigureTimeoutMinutes = 5
$script:DcuServiceName = 'DellClientManagementService'
$script:DcuServiceStartSeconds = 60

# tvsu.exe is a 32-bit program and this script runs as 64-bit PowerShell, so the policy is written to
# both registry views, the native one and the WOW6432Node one (ruling R19).
$script:LenovoPolicyKeys = @(
  'HKLM:\SOFTWARE\Policies\Lenovo\System Update\UserSettings\General'
  'HKLM:\SOFTWARE\WOW6432Node\Policies\Lenovo\System Update\UserSettings\General'
)
$script:LenovoPolicyValueName = 'AdminCommandLine'
$script:LenovoProcessNames = @('tvsu', 'Tvsukernel')

# --- exit codes -------------------------------------------------------------------------------

function ConvertTo-VendorExitCode {
  # Private. The exit code as an [int], or $null when it is $null or not a whole number in the Int32
  # range. Invariant culture, so the machine's regional settings cannot change how it reads.
  [CmdletBinding()]
  param($ExitCode)

  if ($null -eq $ExitCode) { return $null }
  $n = 0
  if ([int]::TryParse([string]$ExitCode, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
  return $null
}

function Convert-DcuExitCode {
  <#
  .SYNOPSIS
    Maps a dcu-cli exit code to Done, DoneReboot, Skipped, RetryService or Failed.
  .DESCRIPTION
    0 (updates applied) and 500 (nothing to apply)                   -> Done
    1 and 5 (a restart finishes the job)                             -> DoneReboot
    3 and 7 (this model is not supported)                            -> Skipped
    3000-3005 (the Dell Client Management Service is not running,
               disabled, busy or updating itself)                    -> RetryService
    anything else                                                    -> Failed
    The parameter is untyped on purpose, like Convert-MsiExitCode: a timed-out run has ExitCode
    $null, which an [int] parameter would silently turn into 0 (Done). $null or a non-number is Failed.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param($ExitCode)

  $n = ConvertTo-VendorExitCode -ExitCode $ExitCode
  if ($null -eq $n) { return 'Failed' }
  if ($n -eq 0 -or $n -eq 500) { return 'Done' }
  if ($n -eq 1 -or $n -eq 5) { return 'DoneReboot' }
  if ($n -eq 3 -or $n -eq 7) { return 'Skipped' }
  if ($n -ge 3000 -and $n -le 3005) { return 'RetryService' }
  return 'Failed'
}

function Convert-HpiaExitCode {
  <#
  .SYNOPSIS
    Maps an HP Image Assistant exit code to Done, DoneReboot, DoneWarning, Skipped, Retry or Failed.
  .DESCRIPTION
    0, 256 (no recommendations) and 257 (none selected)   -> Done
    3010 (installed, a restart is needed)                 -> DoneReboot
    3011 (some updates need a manual install)             -> DoneWarning
    4096 (platform not supported: a consumer model)       -> Skipped
    4098 (no internet connection)                         -> Retry
    anything else, including 3020 (some installs failed)  -> Failed
    Untyped for the same reason as Convert-DcuExitCode: $null (a timeout) is Failed.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param($ExitCode)

  $n = ConvertTo-VendorExitCode -ExitCode $ExitCode
  if ($null -eq $n) { return 'Failed' }
  if ($n -eq 0 -or $n -eq 256 -or $n -eq 257) { return 'Done' }
  if ($n -eq 3010) { return 'DoneReboot' }
  if ($n -eq 3011) { return 'DoneWarning' }
  if ($n -eq 4096) { return 'Skipped' }
  if ($n -eq 4098) { return 'Retry' }
  return 'Failed'
}

# --- argument builders (OnAC $false = no BIOS/firmware) ---------------------------------------

function Get-DcuApplyArgs {
  <#
  .SYNOPSIS
    The dcu-cli /applyUpdates command line. OnAC $false limits it to drivers, applications and others,
    so no BIOS or firmware is flashed.
  .DESCRIPTION
    -reboot=disable: the runner does a controlled restart when the exit code asks for one. The log
    path is quoted so a path with spaces stays one argument.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$LogPath,
    [Parameter(Mandatory)][bool]$OnAC
  )

  $text = "/applyUpdates -silent -reboot=disable -outputLog=`"$LogPath`""
  if (-not $OnAC) { $text += ' -updateType=driver,application,others' }
  return $text
}

function Get-HpiaArgs {
  <#
  .SYNOPSIS
    The HPImageAssistant.exe command line: analyze, then install every recommendation silently.
    OnAC $false narrows /Category:All to /Category:Drivers,Software, so no BIOS or firmware is flashed.
  .DESCRIPTION
    Both folders are quoted, with any trailing backslash dropped (\" would escape the closing quote).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$ReportFolder,
    [Parameter(Mandatory)][string]$DownloadFolder,
    [Parameter(Mandatory)][bool]$OnAC
  )

  $category = if ($OnAC) { 'All' } else { 'Drivers,Software' }
  return ('/Operation:Analyze /Category:{0} /Selection:All /Action:Install /Silent /ReportFolder:"{1}" /SoftpaqDownloadFolder:"{2}" /AutoCleanup' -f
    $category, $ReportFolder.TrimEnd('\'), $DownloadFolder.TrimEnd('\'))
}

function Get-LenovoAdminCommandLine {
  <#
  .SYNOPSIS
    The AdminCommandLine policy value that `tvsu.exe /CM` runs with: search all, install, no prompts,
    results exported to WMI.
  .DESCRIPTION
    -includerebootpackages picks the reboot types System Update may install: 1 (restart needed),
    3 (no restart needed) and 5 (BIOS/firmware; Lenovo forces its own restart after a countdown). Type 4
    (forces a SHUTDOWN) is never included: a powered-off machine would stall the run.
    OnAC $false (ruling R21) leaves type 5 out AND adds -packagetypes 1,2 (1 = application, 2 =
    driver): the reboot type alone does not keep out firmware, or an older BIOS package, that carries
    reboot type 1 or 3. The AC variant has no package-type filter (Q18: everything recommended).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][bool]$OnAC)

  if ($OnAC) { return '/CM -search A -action INSTALL -includerebootpackages 1,3,5 -noreboot -noicon -nolicense -exporttowmi' }
  return '/CM -search A -action INSTALL -includerebootpackages 1,3 -packagetypes 1,2 -noreboot -noicon -nolicense -exporttowmi'
}

# --- rules ------------------------------------------------------------------------------------

function Test-ShouldRemoveBusinessTool {
  <#
  .SYNOPSIS
    $true only for a LAPTOP of a business-tool brand (DELL, LENOVO, HP) whose consumer app is Done.
  .DESCRIPTION
    A consumer app that was Skipped or Failed (or never ran) keeps the business tool, so the machine
    keeps an updater. Branded desktops always keep it (spec 8.3 step 16).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Mode,
    [AllowNull()][AllowEmptyString()][string]$Brand,
    [AllowNull()][AllowEmptyString()][string]$ConsumerAppStatus
  )

  return ($Mode -eq 'LAPTOP') -and ($script:VendorToolBrands -contains $Brand) -and ($ConsumerAppStatus -eq 'Done')
}

function Convert-LenovoUpdateRecords {
  <#
  .SYNOPSIS
    Turns the Lenovo_Updates records System Update exported to WMI into 'Done', 'DoneReboot', 'Failed'
    or 'FailedReboot'.
  .DESCRIPTION
    Provisional until SPIKE#4 shows the real property names and values (the spike dumps every
    property). Every record is looked at: a Status text containing "fail" marks a failure, one
    containing "reboot" or "restart" marks a needed restart (one record can mark both).
      failure and restart -> FailedReboot (the updates that did install still get their restart)
      failure only        -> Failed
      restart only        -> DoneReboot
      neither, or no records -> Done
    Matching is case-insensitive. $null records and records without a Status are ignored. Accepts
    CimInstances, plain objects and hashtables.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyCollection()][object[]]$Records)

  $failed = $false
  $reboot = $false
  foreach ($record in @($Records)) {
    if ($null -eq $record) { continue }
    $status = $null
    if ($record -is [System.Collections.IDictionary]) {
      $status = $record['Status']
    } else {
      $property = $record.PSObject.Properties['Status']
      if ($null -ne $property) { $status = $property.Value }
    }
    $text = [string]$status
    if ($text -match 'fail') { $failed = $true }
    if ($text -match 'reboot|restart') { $reboot = $true }
  }
  if ($failed -and $reboot) { return 'FailedReboot' }
  if ($failed) { return 'Failed' }
  if ($reboot) { return 'DoneReboot' }
  return 'Done'
}

# --- shared plumbing --------------------------------------------------------------------------

function Get-VendorSetting {
  # Private. Config.vendors.<Brand>.<Name>, or $null when the brand, its entry or the setting is missing.
  [CmdletBinding()]
  param(
    [AllowNull()]$Config,
    [AllowNull()][AllowEmptyString()][string]$Brand,
    [Parameter(Mandatory)][string]$Name
  )

  if ($null -eq $Config -or [string]::IsNullOrEmpty($Brand)) { return $null }
  $vendors = $Config.PSObject.Properties['vendors']
  if ($null -eq $vendors -or $null -eq $vendors.Value) { return $null }
  $entry = $vendors.Value.PSObject.Properties[$Brand]
  if ($null -eq $entry -or $null -eq $entry.Value) { return $null }
  $setting = $entry.Value.PSObject.Properties[$Name]
  if ($null -eq $setting) { return $null }
  return $setting.Value
}

function New-VendorOutcome {
  <#
  .SYNOPSIS
    Private. What one vendor tool run came to, before Invoke-VendorPass turns it into a StepResult:
    @{ Outcome; ExitCode = <int|$null>; Message = <string|$null>; Notes = <string[]> }.
  .DESCRIPTION
    Outcome is Done, DoneReboot, DoneWarning, Skipped, Failed, FailedReboot or TimedOut. A Message
    replaces the default text for that outcome (see ConvertTo-VendorStepResult). Notes are the tool
    run's own yellow notes (power lost right before the apply, an unreadable Lenovo result).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][ValidateSet('Done', 'DoneReboot', 'DoneWarning', 'Skipped', 'Failed', 'FailedReboot', 'TimedOut')][string]$Outcome,
    $ExitCode = $null,
    [string]$Message,
    [AllowEmptyCollection()][string[]]$Notes = @()
  )

  return @{ Outcome = $Outcome; ExitCode = (ConvertTo-VendorExitCode -ExitCode $ExitCode); Message = $Message; Notes = [string[]]@($Notes) }
}

function Resolve-VendorFirmwareAllowed {
  <#
  .SYNOPSIS
    Private. Reads AC power once more right before a tool applies updates (spec 9.2: the step
    re-checks power right before it runs) and returns whether BIOS/firmware is still allowed.
  .DESCRIPTION
    OnAC $false stays $false without a read (battery at the first read, or BitLocker not suspended).
    OnAC $true and still on AC: $true. AC lost since the first read (after an install, download,
    extract, /configure or a retry wait): $false, a WARN, and the battery Note is added to Notes once.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][bool]$OnAC,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Notes
  )

  if (-not $OnAC) { return $false }
  if ([bool](Test-OnACPower)) { return $true }
  Write-SetupLog -Message 'AC power lost right before the vendor tool; BIOS/firmware left out' -Level WARN
  if (-not $Notes.Contains($script:BatteryNote)) { $Notes.Add($script:BatteryNote) }
  return $false
}

function ConvertTo-VendorStepResult {
  <#
  .SYNOPSIS
    Private. Turns a vendor outcome into the pass's StepResult. Notes are the gate's notes (BitLocker,
    battery), followed by the outcome's own Notes (no text twice); Data is @{ Pass; ExitCode }
    (ExitCode only when the tool returned one).
  .DESCRIPTION
    Done        -> Done('<tool> finished')
    DoneReboot  -> Done('<tool> finished, restart needed') with Reboot 'Now'
    DoneWarning -> Done('<tool> finished') + Note '<tool>: some updates need manual install'
    Skipped     -> Skipped('<tool> does not support this model')
    TimedOut    -> Failed('<tool> timed out')
    Failed      -> Failed('<tool> failed (exit <code>)')
    FailedReboot -> the same Failed, with Reboot 'Now' (the runner restarts after a Failed + Now too)
    The outcome's own Message, when it has one, replaces the text above (not for TimedOut).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][hashtable]$Outcome,
    [Parameter(Mandatory)][int]$Pass,
    [AllowEmptyCollection()][string[]]$Notes = @()
  )

  $allNotes = New-Object 'System.Collections.Generic.List[string]'
  foreach ($n in (@($Notes) + @($Outcome.Notes))) {
    if ($n -and -not $allNotes.Contains([string]$n)) { $allNotes.Add([string]$n) }
  }
  $data = @{ Pass = $Pass }
  if ($null -ne $Outcome.ExitCode) { $data['ExitCode'] = [int]$Outcome.ExitCode }
  $text = [string]$Outcome.Message
  $hasText = -not [string]::IsNullOrEmpty($text)

  $kind = [string]$Outcome.Outcome
  if ($kind -eq 'Done') {
    return New-StepResult -Status Done -Message $(if ($hasText) { $text } else { "$Name finished" }) -Notes $allNotes.ToArray() -Data $data
  }
  if ($kind -eq 'DoneReboot') {
    return New-StepResult -Status Done -Message $(if ($hasText) { $text } else { "$Name finished, restart needed" }) -Reboot Now -Notes $allNotes.ToArray() -Data $data
  }
  if ($kind -eq 'DoneWarning') {
    $allNotes.Add("${Name}: some updates need manual install")
    return New-StepResult -Status Done -Message $(if ($hasText) { $text } else { "$Name finished" }) -Notes $allNotes.ToArray() -Data $data
  }
  if ($kind -eq 'Skipped') {
    return New-StepResult -Status Skipped -Message $(if ($hasText) { $text } else { "$Name does not support this model" }) -Notes $allNotes.ToArray() -Data $data
  }
  if ($kind -eq 'TimedOut') {
    return New-StepResult -Status Failed -Message "$Name timed out" -Notes $allNotes.ToArray() -Data $data
  }
  if (-not $hasText) {
    $code = if ($null -ne $Outcome.ExitCode) { "exit $($Outcome.ExitCode)" } else { 'no exit code' }
    $text = "$Name failed ($code)"
  }
  $reboot = if ($kind -eq 'FailedReboot') { 'Now' } else { 'None' }
  return New-StepResult -Status Failed -Message $text -Reboot $reboot -Notes $allNotes.ToArray() -Data $data
}

function Find-VendorToolExe {
  # Private. The first of Tool.exeCandidates that exists as a file, or $null.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)]$Tool)

  foreach ($candidate in @($Tool.exeCandidates)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    if (Test-Path -LiteralPath ([string]$candidate) -PathType Leaf) { return [string]$candidate }
  }
  return $null
}

function Get-VendorToolExe {
  <#
  .SYNOPSIS
    Private. Makes a winget-installed business tool (DCU, Lenovo System Update) available and checks
    its signature. Returns @{ Exe = <path|$null>; Outcome = <vendor outcome|$null> }: Exe to run, or the
    Outcome to report instead.
  .DESCRIPTION
    1. The first existing Tool.exeCandidates entry (it may be pre-installed, or left by pass 1).
    2. Otherwise winget installs Tool.wingetId and the candidates are looked at again. A winget
       Skipped (no installer for this system, e.g. ARM64) is Skipped('<tool>: no installer for this
       system'); an exe that is still missing is Failed('<tool> not found'), with winget's reason when
       winget did not succeed.
    3. The exe must be Authenticode-signed by one of the brand's signers (config signers.<Tool.signer>)
       BEFORE it runs: otherwise Failed('<tool> signature check failed') and nothing runs.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]$Tool,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][hashtable]$Context
  )

  $exe = Find-VendorToolExe -Tool $Tool
  if (-not $exe) {
    Write-SetupLog -Message "$Name not found; installing it with winget" -Data @{ id = [string]$Tool.wingetId }
    $winget = Invoke-WingetInstall -Id ([string]$Tool.wingetId) -Source winget -Context $Context
    if ($winget.Status -eq 'Skipped') {
      return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Skipped -Message "${Name}: no installer for this system") }
    }
    if ($winget.Status -ne 'Done') {
      Write-SetupLog -Message "$Name was not installed by winget" -Level WARN -Data @{ status = [string]$winget.Status; message = [string]$winget.Message }
    }
    $exe = Find-VendorToolExe -Tool $Tool
    if (-not $exe) {
      $text = "$Name not found"
      if ($winget.Status -ne 'Done' -and $winget.Message) { $text += " ($($winget.Message))" }
      Write-SetupLog -Message "$Name not found after the winget install" -Level ERROR -Data @{ candidates = @($Tool.exeCandidates) }
      return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message $text) }
    }
  }

  $signers = Get-Signers -Config $Context.Config -Key ([string]$Tool.signer)
  if (-not (Test-FileSignature -Path $exe -AllowedSigners $signers)) {
    return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message "$Name signature check failed") }
  }
  return @{ Exe = $exe; Outcome = $null }
}

# --- Dell Command Update ----------------------------------------------------------------------

function Invoke-DellUpdate {
  <#
  .SYNOPSIS
    Runs Dell Command Update for one pass. Returns a vendor outcome (see New-VendorOutcome).
  .DESCRIPTION
    1. dcu-cli.exe through Get-VendorToolExe (exeCandidates, else winget Tool.wingetId; Dell signer).
    2. `/configure -silent -autoSuspendBitLocker=enable`, limited to 5 minutes. A failure (non-zero
       exit, timeout, cannot start) is only a WARN: the apply still runs.
    3. Right before each apply, AC power is read again (Resolve-VendorFirmwareAllowed): lost AC means
       no BIOS/firmware and the battery Note.
    4. `/applyUpdates` (Get-DcuApplyArgs; OnAC $false = no BIOS/firmware) with the log
       <Logs>\dcu-pass<Pass>.log and timeoutsMinutes.vendor.
    5. Exit codes 3000-3005 (the Dell service is not running, busy or updating itself):
       Start-DellClientService (bounded to 60 s), wait RetrySeconds (30) so a service that is starting
       or updating can settle, and apply once more; a second such code is Failed.
    A timeout is TimedOut; a dcu-cli that cannot be started is Failed('Dell Command Update could not
    be started').
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)]$Tool,
    [Parameter(Mandatory)][bool]$OnAC,
    [Parameter(Mandatory)][ValidateRange(1, 9)][int]$Pass,
    [ValidateRange(0, 3600)][int]$RetrySeconds = 30
  )

  $name = $script:VendorToolNames['dcu']
  $ready = Get-VendorToolExe -Tool $Tool -Name $name -Context $Context
  if ($null -ne $ready.Outcome) { return $ready.Outcome }
  $exe = $ready.Exe

  try {
    $configure = Invoke-External -FilePath $exe -ArgumentList $script:DcuConfigureArgs -TimeoutMinutes $script:DcuConfigureTimeoutMinutes
    if ($configure.TimedOut -or $null -eq $configure.ExitCode -or $configure.ExitCode -ne 0) {
      Write-SetupLog -Message 'DCU /configure did not succeed; applying updates anyway' -Level WARN -Data @{ exitCode = $configure.ExitCode; timedOut = [bool]$configure.TimedOut }
    }
  } catch {
    Write-SetupLog -Message 'DCU /configure could not be started; applying updates anyway' -Level WARN -Data @{ error = $_.Exception.Message }
  }

  $logPath = Join-Path $Context.LogDir "dcu-pass$Pass.log"
  $timeout = [double]$Context.Config.timeoutsMinutes.vendor
  $notes = New-Object 'System.Collections.Generic.List[string]'
  $maxTries = 2
  for ($try = 1; $try -le $maxTries; $try++) {
    $OnAC = Resolve-VendorFirmwareAllowed -OnAC $OnAC -Notes $notes
    $arguments = Get-DcuApplyArgs -LogPath $logPath -OnAC $OnAC
    try {
      $run = Invoke-External -FilePath $exe -ArgumentList $arguments -TimeoutMinutes $timeout
    } catch {
      Write-SetupLog -Message 'dcu-cli could not be started' -Level ERROR -Data @{ file = $exe; error = $_.Exception.Message }
      return New-VendorOutcome -Outcome Failed -Message "$name could not be started" -Notes $notes.ToArray()
    }
    if ($run.TimedOut) { return New-VendorOutcome -Outcome TimedOut -Notes $notes.ToArray() }

    $mapped = Convert-DcuExitCode -ExitCode $run.ExitCode
    if ($mapped -eq 'RetryService' -and $try -lt $maxTries) {
      Write-SetupLog -Message 'The Dell service is not ready; starting it, waiting and applying once more' -Level WARN -Data @{ exitCode = $run.ExitCode; service = $script:DcuServiceName; waitSeconds = $RetrySeconds }
      Start-DellClientService
      Start-Sleep -Seconds $RetrySeconds
      continue
    }
    if ($mapped -eq 'RetryService') { $mapped = 'Failed' }
    return New-VendorOutcome -Outcome $mapped -ExitCode $run.ExitCode -Notes $notes.ToArray()
  }
}

function Start-DellClientService {
  <#
  .SYNOPSIS
    Private. Starts DellClientManagementService when it is not running and waits at most 60 s for it
    to reach Running. Never throws: a missing service, a refused start or the 60 s running out is a
    WARN, and the caller retries anyway.
  .DESCRIPTION
    Not Start-Service: in Windows PowerShell it keeps waiting, with no limit, while a service stays
    StartPending. A service that is already StartPending is only waited for (Start() would throw).
  #>
  [CmdletBinding()]
  param()

  try {
    $service = Get-Service -Name $script:DcuServiceName -ErrorAction Stop
    if ([string]$service.Status -ne 'Running') {
      if ([string]$service.Status -ne 'StartPending') { $service.Start() }
      $service.WaitForStatus('Running', [TimeSpan]::FromSeconds($script:DcuServiceStartSeconds))
    }
  } catch {
    Write-SetupLog -Message 'The Dell service could not be started; retrying anyway' -Level WARN -Data @{ service = $script:DcuServiceName; waitSeconds = $script:DcuServiceStartSeconds; error = $_.Exception.Message }
  }
}

# --- Lenovo System Update ---------------------------------------------------------------------

function Set-LenovoAdminCommandLine {
  # Private. Writes the AdminCommandLine policy (REG_SZ) into BOTH registry views (ruling R19), creating
  # each key when it is missing. $true only when both writes succeeded; any refused write is an ERROR
  # in the log and makes it $false, because a view left with an older value could still allow a BIOS
  # flash. Both views are always tried. New-Item runs only for a missing key: -Force on an existing
  # key could clear what it holds. Both writes use -ErrorAction Stop: a refused registry write is a
  # non-terminating error, and without it the R19 guard (no tvsu run) would never fire (final review I1).
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Value)

  $allOk = $true
  foreach ($key in $script:LenovoPolicyKeys) {
    try {
      if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
      New-ItemProperty -LiteralPath $key -Name $script:LenovoPolicyValueName -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
      Write-SetupLog -Message 'Lenovo System Update policy written' -Data @{ key = $key; value = $Value }
    } catch {
      Write-SetupLog -Message 'Lenovo System Update policy could not be written' -Level ERROR -Data @{ key = $key; error = $_.Exception.Message }
      $allOk = $false
    }
  }
  return $allOk
}

function Wait-LenovoProcessExit {
  <#
  .SYNOPSIS
    Private. Waits until no tvsu or Tvsukernel process is left. $true when they are gone, $false when
    TimeoutSeconds ran out first.
  .DESCRIPTION
    `tvsu.exe /CM` returns while Tvsukernel does the work, and Tvsukernel may appear a moment after
    tvsu.exe is gone. So each round sleeps first (PollSeconds, cut short at the deadline) and then
    looks; there is always at least one look. Get-Process finding no such process is the normal end.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][double]$TimeoutSeconds,
    [Parameter(Mandatory)][double]$PollSeconds
  )

  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
    if ($remaining -gt 0) {
      Start-Sleep -Milliseconds ([int][Math]::Max(1, [Math]::Ceiling([Math]::Min($PollSeconds, $remaining) * 1000)))
    }
    $running = @(Get-Process -Name $script:LenovoProcessNames -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return $true }
    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $false }
  }
}

function Stop-LenovoProcess {
  # Private. Force-kills every tvsu and Tvsukernel process that is still running. Never throws; a
  # process that cannot be killed is a WARN.
  [CmdletBinding()]
  param()

  foreach ($process in @(Get-Process -Name $script:LenovoProcessNames -ErrorAction SilentlyContinue)) {
    try {
      Stop-Process -Id $process.Id -Force -ErrorAction Stop
      Write-SetupLog -Message 'Lenovo System Update process killed' -Level WARN -Data @{ name = [string]$process.Name; processId = $process.Id }
    } catch {
      Write-SetupLog -Message 'Lenovo System Update process could not be killed' -Level WARN -Data @{ name = [string]$process.Name; processId = $process.Id; error = $_.Exception.Message }
    }
  }
}

function Copy-LenovoLog {
  # Private. Best effort: copies %ProgramData%\Lenovo\SystemUpdate\logs\* to <Logs>\lenovo-pass<Pass>.
  # No logs is an INFO; a failed copy is a WARN. Never throws.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)][int]$Pass
  )

  $source = Join-Path $env:ProgramData 'Lenovo\SystemUpdate\logs'
  $target = Join-Path $Context.LogDir "lenovo-pass$Pass"
  try {
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
      Write-SetupLog -Message 'Lenovo System Update wrote no logs to copy' -Data @{ source = $source }
      return
    }
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null }
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force -ErrorAction Stop
  } catch {
    Write-SetupLog -Message 'Lenovo System Update logs could not be copied' -Level WARN -Data @{ source = $source; target = $target; error = $_.Exception.Message }
  }
}

function Read-LenovoUpdateRecords {
  # Private. @{ Readable = <bool>; Records = <object[]> } from root\Lenovo Lenovo_Updates, the query
  # limited to 30 s. A query that worked and found nothing is Readable with no Records. A query that
  # failed (namespace or class missing, WMI error, timeout) is NOT Readable, with a WARN: the caller
  # must not report that as a clean result.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  try {
    $records = @(Get-CimInstance -Namespace 'root\Lenovo' -ClassName 'Lenovo_Updates' -OperationTimeoutSec 30 -ErrorAction Stop)
    return @{ Readable = $true; Records = $records }
  } catch {
    Write-SetupLog -Message 'Lenovo update results could not be read from WMI' -Level WARN -Data @{ error = $_.Exception.Message }
    return @{ Readable = $false; Records = @() }
  }
}

function Invoke-LenovoUpdate {
  <#
  .SYNOPSIS
    Runs Lenovo System Update for one pass. Returns a vendor outcome (see New-VendorOutcome).
  .DESCRIPTION
    1. tvsu.exe through Get-VendorToolExe (exeCandidates, else winget Tool.wingetId; Lenovo signer).
    2. AC power is read again (Resolve-VendorFirmwareAllowed), because the policy written next decides
       whether BIOS packages are installed. Lost AC means the restricted policy and the battery Note.
    3. The AdminCommandLine policy = Get-LenovoAdminCommandLine (OnAC $false = no type 5, applications
       and drivers only), in both registry views. If either write fails, tvsu does NOT run (an older
       value could still allow a BIOS flash): Failed.
    4. `tvsu.exe /CM` with timeoutsMinutes.vendor, then Wait-LenovoProcessExit for whatever is left of
       that same budget, polling every PollSeconds (10). Either running out is TimedOut, after every
       tvsu/Tvsukernel process left has been killed.
    5. Whatever happened in 3-4, the AdminCommandLine value is then removed from both views (ruling
       R22, in a finally): left in place, System Update's own scheduled runs could later install a
       BIOS unattended, outside this step's power and BitLocker checks. Each pass writes it again.
    6. Logs\lenovo-pass<Pass>\ gets a copy of System Update's logs (best effort, also after a timeout).
    7. The result comes from root\Lenovo Lenovo_Updates (SPIKE#4 will refine this). Unreadable ->
       Done with the Note 'Lenovo System Update result could not be read'. No record ->
       Done('No Lenovo updates reported'). Otherwise Convert-LenovoUpdateRecords decides Done,
       DoneReboot, or Failed('Lenovo System Update reported failed updates'), the latter with a
       restart (FailedReboot) when another record needs one. tvsu's own exit code (undocumented) is
       kept in the outcome for the step Data and decides nothing.
    A BIOS (type 5) update forces its own restart in the middle of this (the finally does not run
    then); the runner re-runs the step after it, which writes and removes the value again. If SPIKE#4
    shows that consumer models are not covered, LSUClient replaces steps 1-7 here and this function
    keeps its signature (spec 9.2).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)]$Tool,
    [Parameter(Mandatory)][bool]$OnAC,
    [Parameter(Mandatory)][ValidateRange(1, 9)][int]$Pass,
    [ValidateRange(0.001, 3600)][double]$PollSeconds = 10
  )

  $name = $script:VendorToolNames['lsu']
  $ready = Get-VendorToolExe -Tool $Tool -Name $name -Context $Context
  if ($null -ne $ready.Outcome) { return $ready.Outcome }
  $exe = $ready.Exe
  $notes = New-Object 'System.Collections.Generic.List[string]'

  $OnAC = Resolve-VendorFirmwareAllowed -OnAC $OnAC -Notes $notes
  $timeoutMinutes = [double]$Context.Config.timeoutsMinutes.vendor
  $run = $null
  $finished = $false
  try {
    if (-not (Set-LenovoAdminCommandLine -Value (Get-LenovoAdminCommandLine -OnAC $OnAC))) {
      return New-VendorOutcome -Outcome Failed -Message "$name settings could not be written" -Notes $notes.ToArray()
    }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
      $run = Invoke-External -FilePath $exe -ArgumentList '/CM' -TimeoutMinutes $timeoutMinutes
    } catch {
      Write-SetupLog -Message 'tvsu.exe could not be started' -Level ERROR -Data @{ file = $exe; error = $_.Exception.Message }
      return New-VendorOutcome -Outcome Failed -Message "$name could not be started" -Notes $notes.ToArray()
    }

    $finished = -not $run.TimedOut
    if ($finished) {
      $finished = Wait-LenovoProcessExit -TimeoutSeconds ($timeoutMinutes * 60 - $clock.Elapsed.TotalSeconds) -PollSeconds $PollSeconds
    }
    if (-not $finished) {
      Write-SetupLog -Message 'Lenovo System Update timed out; killing what is left of it' -Level WARN -Data @{ timeoutMinutes = $timeoutMinutes }
      Stop-LenovoProcess
    }
  } finally {
    # Ruling R22: never leave the policy behind, whatever happened above.
    Remove-LenovoAdminCommandLine
  }

  Copy-LenovoLog -Context $Context -Pass $Pass
  $exitCode = $run.ExitCode
  if (-not $finished) { return New-VendorOutcome -Outcome TimedOut -ExitCode $exitCode -Notes $notes.ToArray() }

  $read = Read-LenovoUpdateRecords
  $records = @($read.Records)
  Write-SetupLog -Message 'Lenovo update results read' -Data @{ readable = [bool]$read.Readable; records = $records.Count; tvsuExitCode = $exitCode }
  if (-not $read.Readable) {
    $notes.Add('Lenovo System Update result could not be read')
    return New-VendorOutcome -Outcome Done -ExitCode $exitCode -Notes $notes.ToArray()
  }
  if ($records.Count -eq 0) { return New-VendorOutcome -Outcome Done -ExitCode $exitCode -Message 'No Lenovo updates reported' -Notes $notes.ToArray() }

  $verdict = Convert-LenovoUpdateRecords -Records $records
  if ($verdict -eq 'Failed' -or $verdict -eq 'FailedReboot') {
    return New-VendorOutcome -Outcome $verdict -ExitCode $exitCode -Message "$name reported failed updates" -Notes $notes.ToArray()
  }
  return New-VendorOutcome -Outcome $verdict -ExitCode $exitCode -Notes $notes.ToArray()
}

# --- HP Image Assistant -----------------------------------------------------------------------

function Get-HpiaExe {
  <#
  .SYNOPSIS
    Private. Downloads and extracts HP Image Assistant. Returns @{ Exe = <path|$null>; Outcome =
    <vendor outcome|$null> }.
  .DESCRIPTION
    Deviation from spec 9.1 (Ben has been told): HPIA comes from its download page, not winget. It is
    a portable tool, so the path is known and removing it is just deleting Downloads.
    Tool.page -> the first Tool.linkPattern match -> <Downloads>\hp-hpia.exe -> HP signer (a bad file
    is deleted and never run) -> `/s /e /f "<Downloads>\HPIA"` (timeoutsMinutes.default) ->
    <Downloads>\HPIA\HPImageAssistant.exe. The caller checks that exe's signature.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)]$Tool,
    [Parameter(Mandatory)][string]$Folder,
    [Parameter(Mandatory)][string[]]$Signers
  )

  $name = $script:VendorToolNames['hpia']
  try {
    $html = Get-RemoteText -Url ([string]$Tool.page)
  } catch {
    Write-SetupLog -Message 'HPIA download page could not be read' -Level ERROR -Data @{ url = [string]$Tool.page; error = $_.Exception.Message }
    return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message "$name page could not be read: $($_.Exception.Message)") }
  }
  $link = Find-LatestLink -Html $html -Pattern ([string]$Tool.linkPattern)
  if (-not $link) { return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message "$name download link not found") } }

  try {
    $installer = [string](Get-RemoteFile -Url $link -Destination (Join-Path $Context.DownloadDir 'hp-hpia.exe'))
  } catch {
    Write-SetupLog -Message 'HPIA download failed' -Level ERROR -Data @{ url = $link; error = $_.Exception.Message }
    return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message "$name download failed: $($_.Exception.Message)") }
  }
  if (-not (Test-FileSignature -Path $installer -AllowedSigners $Signers)) {
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message "$name signature check failed") }
  }

  try {
    $run = Invoke-External -FilePath $installer -ArgumentList "/s /e /f `"$($Folder.TrimEnd('\'))`"" -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.default)
  } catch {
    Write-SetupLog -Message 'HPIA extractor could not be started' -Level ERROR -Data @{ error = $_.Exception.Message }
    return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message "$name extract could not be started") }
  }
  if ($run.TimedOut) { return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message "$name extract timed out") } }
  if ($null -eq $run.ExitCode -or $run.ExitCode -ne 0) {
    return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -ExitCode $run.ExitCode -Message "$name extract failed (exit $($run.ExitCode))") }
  }

  $exe = Join-Path $Folder 'HPImageAssistant.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    return @{ Exe = $null; Outcome = (New-VendorOutcome -Outcome Failed -Message "$name not found after extract") }
  }
  return @{ Exe = $exe; Outcome = $null }
}

function Invoke-HpUpdate {
  <#
  .SYNOPSIS
    Runs HP Image Assistant for one pass. Returns a vendor outcome (see New-VendorOutcome).
  .DESCRIPTION
    1. <Downloads>\HPIA\HPImageAssistant.exe when it is already there (pass 2), else Get-HpiaExe.
    2. That exe must carry the HP signature, every time, before it runs.
    3. Right before each run, AC power is read again (Resolve-VendorFirmwareAllowed): lost AC means no
       BIOS/firmware and the battery Note.
    4. Get-HpiaArgs (OnAC $false = no BIOS/firmware) with ReportFolder <Logs>\HPIA-pass<Pass> and
       SoftpaqDownloadFolder <Downloads>\HPIA-softpaqs, timeoutsMinutes.vendor.
    5. Exit 4098 (no internet): wait RetrySeconds (30) and run once more; a second 4098 is Failed.
    A timeout is TimedOut; an exe that cannot be started is Failed('HP Image Assistant could not be
    started').
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)]$Tool,
    [Parameter(Mandatory)][bool]$OnAC,
    [Parameter(Mandatory)][ValidateRange(1, 9)][int]$Pass,
    [ValidateRange(0, 3600)][int]$RetrySeconds = 30
  )

  $name = $script:VendorToolNames['hpia']
  $folder = Join-Path $Context.DownloadDir 'HPIA'
  $exe = Join-Path $folder 'HPImageAssistant.exe'
  $signers = Get-Signers -Config $Context.Config -Key ([string]$Tool.signer)

  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    $fetched = Get-HpiaExe -Context $Context -Tool $Tool -Folder $folder -Signers $signers
    if ($null -ne $fetched.Outcome) { return $fetched.Outcome }
    $exe = $fetched.Exe
  }
  if (-not (Test-FileSignature -Path $exe -AllowedSigners $signers)) {
    return New-VendorOutcome -Outcome Failed -Message "$name signature check failed"
  }

  $reportFolder = Join-Path $Context.LogDir "HPIA-pass$Pass"
  $softpaqFolder = Join-Path $Context.DownloadDir 'HPIA-softpaqs'
  $timeout = [double]$Context.Config.timeoutsMinutes.vendor
  $notes = New-Object 'System.Collections.Generic.List[string]'
  $maxTries = 2
  for ($try = 1; $try -le $maxTries; $try++) {
    $OnAC = Resolve-VendorFirmwareAllowed -OnAC $OnAC -Notes $notes
    $arguments = Get-HpiaArgs -ReportFolder $reportFolder -DownloadFolder $softpaqFolder -OnAC $OnAC
    try {
      $run = Invoke-External -FilePath $exe -ArgumentList $arguments -TimeoutMinutes $timeout
    } catch {
      Write-SetupLog -Message 'HPImageAssistant.exe could not be started' -Level ERROR -Data @{ file = $exe; error = $_.Exception.Message }
      return New-VendorOutcome -Outcome Failed -Message "$name could not be started" -Notes $notes.ToArray()
    }
    if ($run.TimedOut) { return New-VendorOutcome -Outcome TimedOut -Notes $notes.ToArray() }

    $mapped = Convert-HpiaExitCode -ExitCode $run.ExitCode
    if ($mapped -eq 'Retry' -and $try -lt $maxTries) {
      Write-SetupLog -Message 'HPIA has no internet connection; waiting and trying once more' -Level WARN -Data @{ exitCode = $run.ExitCode; waitSeconds = $RetrySeconds }
      Start-Sleep -Seconds $RetrySeconds
      continue
    }
    if ($mapped -eq 'Retry') { $mapped = 'Failed' }
    return New-VendorOutcome -Outcome $mapped -ExitCode $run.ExitCode -Notes $notes.ToArray()
  }
}

# --- steps 12 and 14: vendor passes -----------------------------------------------------------

function Invoke-VendorPass {
  <#
  .SYNOPSIS
    One pass of the brand's business tool (drivers, BIOS/firmware, utilities). Returns a StepResult.
  .DESCRIPTION
    1. Config.vendors.<Brand>.tool missing -> Skipped('No vendor tool for <Brand>'), before anything
       else runs (the plan already leaves those brands out). An unknown tool kind is Failed.
    2. Test-OnACPower FIRST (ruling R20). On battery: the Note 'On battery: BIOS/firmware updates
       skipped', no BitLocker wait or suspension at all (no BIOS is flashed, so there is nothing to
       protect), and the tool runs without BIOS/firmware.
    3. On AC, the BitLocker gate: Wait-BitLockerDecrypted (timeoutsMinutes.bitlockerDecrypt). Not
       decrypted -> Suspend-BitLockerOnce: success is the Note 'BitLocker still decrypting: suspended
       for BIOS update'; failure is the Note 'BitLocker could not be suspended: BIOS/firmware updates
       skipped' and firmware is not allowed.
    4. The tool runs with -OnAC (on AC and BitLocker ok): Invoke-DellUpdate (dcu), Invoke-LenovoUpdate
       (lsu) or Invoke-HpUpdate (hpia). Each reads AC power once more right before it applies
       anything (after its install, download, extract or /configure; spec 9.2), because the wait and
       the setup can take long and the charger may have been pulled meanwhile.
    5. ConvertTo-VendorStepResult maps the outcome (DoneReboot -> Done + Reboot 'Now'; Skipped ->
       '<tool> does not support this model'; DoneWarning -> Done + Note) and adds the tool's own Notes.
       Data = @{ Pass; ExitCode }.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)][ValidateRange(1, 9)][int]$Pass
  )

  $brand = [string]$Context.State.Machine.Brand
  $tool = Get-VendorSetting -Config $Context.Config -Brand $brand -Name 'tool'
  if ($null -eq $tool) { return New-StepResult -Status Skipped -Message "No vendor tool for $brand" }
  $kind = [string]$tool.kind
  $name = $script:VendorToolNames[$kind]
  if ([string]::IsNullOrEmpty($kind) -or -not $name) {
    return New-StepResult -Status Failed -Message "Unknown vendor tool kind '$kind' for $brand"
  }

  $notes = New-Object 'System.Collections.Generic.List[string]'
  $allowFirmware = $false
  $gate = 'skipped (on battery)'
  if (-not [bool](Test-OnACPower)) {
    $notes.Add($script:BatteryNote)
  } else {
    $allowFirmware = [bool](Wait-BitLockerDecrypted -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.bitlockerDecrypt))
    $gate = 'decrypted'
    if (-not $allowFirmware) {
      if (Suspend-BitLockerOnce) {
        $notes.Add('BitLocker still decrypting: suspended for BIOS update')
        $allowFirmware = $true
        $gate = 'suspended'
      } else {
        $notes.Add('BitLocker could not be suspended: BIOS/firmware updates skipped')
        $gate = 'not suspended'
      }
    }
  }
  Write-SetupLog -Message 'Vendor pass starting' -Data @{ tool = $name; pass = $Pass; bitlocker = $gate; firmware = $allowFirmware }

  if ($kind -eq 'dcu') {
    $outcome = Invoke-DellUpdate -Context $Context -Tool $tool -OnAC $allowFirmware -Pass $Pass
  } elseif ($kind -eq 'lsu') {
    $outcome = Invoke-LenovoUpdate -Context $Context -Tool $tool -OnAC $allowFirmware -Pass $Pass
  } else {
    $outcome = Invoke-HpUpdate -Context $Context -Tool $tool -OnAC $allowFirmware -Pass $Pass
  }

  $result = ConvertTo-VendorStepResult -Name $name -Outcome $outcome -Pass $Pass -Notes $notes.ToArray()
  Write-SetupLog -Message 'Vendor pass finished' -Data @{ tool = $name; pass = $Pass; status = $result.Status; message = $result.Message; reboot = $result.Reboot }
  return $result
}

function Invoke-StepVendorPass1 {
  <#
  .SYNOPSIS
    Step 12: the vendor tool's first pass, before Windows Update (vendor drivers win over generic ones).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  return Invoke-VendorPass -Context $Context -Pass 1
}

function Invoke-StepVendorPass2 {
  <#
  .SYNOPSIS
    Step 14: one more pass after Windows Update, for what only became applicable after it.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  return Invoke-VendorPass -Context $Context -Pass 2
}

# --- step 15: consumer app --------------------------------------------------------------------

function Invoke-StepConsumerApp {
  <#
  .SYNOPSIS
    Step 15: installs the brand's consumer app (Config.vendors.<Brand>.consumerApp) with winget.
  .DESCRIPTION
    No consumerApp -> Skipped('No vendor app for <Brand>'). Done -> Done('<name> installed').
    SPIKE#3 default: a Microsoft Store app (source msstore) whose install Failed is
    Skipped('<name>: Store install failed (<0x code>), install it from the Store'), because a Store
    install may need a Microsoft account sign-in; a failure without a code carries winget's reason
    instead. Any other result (a Skipped, a winget-source failure) is winget's own StepResult.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $brand = [string]$Context.State.Machine.Brand
  $app = Get-VendorSetting -Config $Context.Config -Brand $brand -Name 'consumerApp'
  if ($null -eq $app) { return New-StepResult -Status Skipped -Message "No vendor app for $brand" }

  $id = [string]$app.id
  $source = [string]$app.source
  $name = if ([string]::IsNullOrWhiteSpace([string]$app.name)) { $id } else { [string]$app.name }

  $result = Invoke-WingetInstall -Id $id -Source $source -Context $Context
  if ($result.Status -eq 'Done') { return New-StepResult -Status Done -Message "$name installed" }
  if ($source -eq 'msstore' -and $result.Status -eq 'Failed') {
    $message = [string]$result.Message
    $code = [regex]::Match($message, '0x[0-9A-Fa-f]{8}')
    $reason = if ($code.Success) { $code.Value } else { $message -replace ('^' + [regex]::Escape($id) + ':\s*'), '' }
    Write-SetupLog -Message 'Store install of the vendor app failed; leaving it to the customer' -Level WARN -Data @{ app = $name; id = $id; winget = $message }
    return New-StepResult -Status Skipped -Message "${name}: Store install failed ($reason), install it from the Store"
  }
  return $result
}

# --- step 16: remove the business updater -----------------------------------------------------

function Remove-LenovoAdminCommandLine {
  # Private. Removes ONLY the AdminCommandLine value, from both registry views (ruling R19), never a
  # policy key (other software or an administrator may keep settings there). Each view is handled on
  # its own: absent is fine, a refused removal is a WARN and the other view is still done. Never throws.
  [CmdletBinding()]
  param()

  foreach ($key in $script:LenovoPolicyKeys) {
    try {
      $present = Get-ItemProperty -LiteralPath $key -Name $script:LenovoPolicyValueName -ErrorAction SilentlyContinue
      if ($null -eq $present) { continue }
      Remove-ItemProperty -LiteralPath $key -Name $script:LenovoPolicyValueName -ErrorAction Stop
      Write-SetupLog -Message 'Lenovo System Update policy value removed' -Data @{ key = $key; name = $script:LenovoPolicyValueName }
    } catch {
      Write-SetupLog -Message 'Lenovo System Update policy value could not be removed' -Level WARN -Data @{ key = $key; error = $_.Exception.Message }
    }
  }
}

function Invoke-StepVendorCleanup {
  <#
  .SYNOPSIS
    Step 16: on a laptop whose consumer app installed, removes the business updater (Dell documents a
    conflict between DCU and SupportAssist, KB 000207301).
  .DESCRIPTION
    Test-ShouldRemoveBusinessTool false -> Skipped('Kept: consumer app not installed'), nothing removed.
    DCU / Lenovo System Update: winget uninstall of the tool's wingetId. Done -> Done('<tool> removed');
    Skipped (not installed) counts as Done('<tool> was not installed'); a failure is winget's Failed.
    Lenovo: the AdminCommandLine policy value is removed from both registry views after the
    uninstall, whatever its result; the keys stay.
    HPIA: Done('HPIA is portable; removed with Downloads') (Finalize deletes Downloads).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $state = $Context.State
  $brand = [string]$state.Machine.Brand
  $appStatus = $null
  if ($state.Steps -is [System.Collections.IDictionary] -and $state.Steps.Contains('consumer-app') -and $null -ne $state.Steps['consumer-app']) {
    $appStatus = [string]$state.Steps['consumer-app'].Status
  }
  if (-not (Test-ShouldRemoveBusinessTool -Mode ([string]$state.Choices.Mode) -Brand $brand -ConsumerAppStatus $appStatus)) {
    return New-StepResult -Status Skipped -Message 'Kept: consumer app not installed'
  }

  $tool = Get-VendorSetting -Config $Context.Config -Brand $brand -Name 'tool'
  if ($null -eq $tool) { return New-StepResult -Status Skipped -Message "No vendor tool for $brand" }
  $kind = [string]$tool.kind
  if ($kind -eq 'hpia') { return New-StepResult -Status Done -Message 'HPIA is portable; removed with Downloads' }
  $name = $script:VendorToolNames[$kind]
  if (-not $name) { return New-StepResult -Status Failed -Message "Unknown vendor tool kind '$kind' for $brand" }

  $result = Invoke-WingetUninstall -Id ([string]$tool.wingetId) -Context $Context
  if ($kind -eq 'lsu') { Remove-LenovoAdminCommandLine }
  if ($result.Status -eq 'Done') { return New-StepResult -Status Done -Message "$name removed" }
  if ($result.Status -eq 'Skipped') { return New-StepResult -Status Done -Message "$name was not installed" }
  return $result
}
