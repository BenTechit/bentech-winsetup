# src/Steps/ScreenConnect.ps1
# The screenconnect step (screenconnect spec 4.3): installs Ben's own ScreenConnect client, the one unattended
# remote-access tool, and only when Ben chose it (Choices.Remote SCREENCONNECT or BOTH, Get-StepPlan; spec 4.6).
# Running Ben's installer is enough: it enrols the PC in his ScreenConnect list. The installer comes from this
# run's own GitHub release (apps.screenconnect.url, never 'latest').
#   Get-ScreenConnectUrl            the installer link of this release, or $null for an unknown version
#   Get-ScreenConnectServiceState   Running / NotRunning / Missing, read by the exact service name
#   Wait-ScreenConnectService       reads that state every 5 s until Running, at most a limit counted in polls
#   Get-SignerEndDateText           the end date of the certificate that signed a file, for the log
#   Test-ScreenConnectInstaller     the SHA-256 pin first, then the ConnectWise signature
#   Invoke-StepScreenConnect        the step
# Needs StepResult.ps1, Logging.ps1, Activity.ps1, Process.ps1, Download.ps1 and Config.ps1; the bundle holds
# every file.
#
# The security boundary is Test-ScreenConnectInstaller. A valid ConnectWise signature cannot prove the file is
# Ben's: every ScreenConnect installer has one, a scammer's too (spec 3). The SHA-256 pinned in the signed
# config.json is what proves it. The signature is checked as well, as a substring of the subject and never with
# -ExactCN: Windows quotes the name (CN="ConnectWise, LLC", ...), -ExactCN refuses every quoted subject by design,
# and the hash already pins the exact file.
#
# Nothing here is localized: the service is read by its name (service names are not translated) and its Status
# enum, the signature by its Status and Subject. The step writes nothing to the console: the progress screen shows
# its NOW titles and its activity line.

function Get-ScreenConnectUrl {
  <#
  .SYNOPSIS
    The installer link of this release: Template with '{version}' replaced by Version, or $null when Version
    is not a release version. Never throws.
  .DESCRIPTION
    A release version is Build-Bundle's own rule, yyyy.MM.dd.N ([0-9], not \d, which also takes other
    scripts' digits; \z, not $, which also matches before a final line break). So 'dev', an empty version or
    anything odd (a 'v' in front, a space, a path) never becomes part of a link. The link names this run's
    own release, never 'latest' (spec 4.3): a run never mixes a newer installer with its own config, and a
    rollback brings its own installer back.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Version
  )

  if ([string]$Version -cnotmatch '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+\z') { return $null }
  return $Template.Replace('{version}', $Version)
}

function Get-ScreenConnectServiceState {
  <#
  .SYNOPSIS
    'Running', 'NotRunning' or 'Missing': the state of the Windows service named exactly Name. Never throws.
  .DESCRIPTION
    Get-Service -Name, and only a service whose Name equals Name counts. A ScreenConnect client of another
    company has another suffix, 'ScreenConnect Client (<its own id>)', so it is Missing here and is never taken
    for Ben's (Review Focus 3). No such service is Missing; Status Running is Running; any other status
    (Stopped, StartPending, ...) is NotRunning. An error while reading it is Missing, logged at WARN.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Name)

  try {
    $found = @(Get-Service -Name $Name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ -and [string]$_.Name -eq $Name })
    if ($found.Count -eq 0) { return 'Missing' }
    foreach ($service in $found) {
      if ([string]$service.Status -eq 'Running') { return 'Running' }
    }
    return 'NotRunning'
  } catch {
    Write-SetupLog -Message 'The ScreenConnect service could not be read' -Level WARN -Data @{ service = $Name; error = $_.Exception.Message }
    return 'Missing'
  }
}

function Wait-ScreenConnectService {
  <#
  .SYNOPSIS
    Waits for the service Name to run. Returns 'Running', or the last state read ('NotRunning' or 'Missing')
    once the limit is reached. Never throws.
  .DESCRIPTION
    The state is read at once (Get-ScreenConnectServiceState). While it is not Running, up to
    Ceiling(TimeoutMinutes * 60 / PollSeconds) times (36 for 3 minutes): Wait-SetupDelay -Seconds PollSeconds,
    which keeps the progress screen alive, then read again. The limit is counted in polls, not by the clock: a
    clock that jumps after the install cannot stretch it, and the tests stay deterministic. While the loop
    runs, the progress screen shows TimeoutMinutes as the wait limit (Enter-SetupWait; Exit-SetupWait in a
    finally).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][double]$TimeoutMinutes,
    [ValidateRange(1, 3600)][double]$PollSeconds = 5
  )

  $state = Get-ScreenConnectServiceState -Name $Name
  $polls = [math]::Ceiling($TimeoutMinutes * 60 / $PollSeconds)
  Enter-SetupWait -LimitMinutes $TimeoutMinutes
  try {
    for ($poll = 1; $poll -le $polls -and $state -ne 'Running'; $poll++) {
      Wait-SetupDelay -Seconds $PollSeconds
      $state = Get-ScreenConnectServiceState -Name $Name
    }
  } finally {
    Exit-SetupWait
  }
  return $state
}

function Get-SignerEndDateText {
  <#
  .SYNOPSIS
    The end date of the certificate that signed Path, as dd/MM/yyyy HH:mm, or 'unknown'. Never throws.
  .DESCRIPTION
    For the log line of a refused signature. Beside the PC's own date it tells a wrong PC clock from an
    installer whose certificate has ended (Ben's ends on 19/02/2027 and has no timestamp, spec 3). The caller
    reads it while the file still exists. NotAfter is local time, like the PC date it is shown beside; the
    invariant culture keeps the '/' whatever the regional settings.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Path)

  try {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $end = $null
    if ($null -ne $signature -and $null -ne $signature.SignerCertificate) { $end = $signature.SignerCertificate.NotAfter }
    if ($end -is [datetime]) { return $end.ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
  } catch {
    Write-SetupLog -Message 'The certificate end date of the ScreenConnect installer could not be read' -Level WARN -Data @{ path = $Path; error = $_.Exception.Message }
  }
  return 'unknown'
}

function Test-ScreenConnectInstaller {
  <#
  .SYNOPSIS
    Checks a downloaded ScreenConnect installer. Returns '' when it passed both checks, else the name of the
    check that failed: 'SHA-256' or 'signature'. Never throws, and deletes nothing (the step does).
  .DESCRIPTION
    1. SHA-256: the file's hash must equal Sha256, letter case aside. This is the check that proves the file is
       Ben's. A mismatch, an empty pin or a file that cannot be read is logged at ERROR ('ScreenConnect
       installer check failed: SHA-256', with expected and actual), and the signature is then not checked: the
       file is not Ben's either way.
    2. Signature: Test-FileSignature with Signers, never -ExactCN (see the file header); only an exact $true
       passes. A refusal is logged at ERROR ('ScreenConnect installer check failed: signature', with pcDate,
       now, and certificateEnds, Get-SignerEndDateText), so a wrong clock and an ended installer look
       different: from 20/02/2027 Windows no longer reports Ben's current installer as Valid.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Sha256,
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Signers
  )

  $actual = ''
  $readError = $null
  try {
    $actual = [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
  } catch {
    $readError = $_.Exception.Message
  }
  if ([string]::IsNullOrEmpty($actual) -or -not [string]::Equals($actual, $Sha256, [StringComparison]::OrdinalIgnoreCase)) {
    $detail = @{ path = $Path; expected = $Sha256; actual = $actual }
    if ($null -ne $readError) { $detail['error'] = $readError }
    Write-SetupLog -Message 'ScreenConnect installer check failed: SHA-256' -Level ERROR -Data $detail
    return 'SHA-256'
  }

  $signed = Test-FileSignature -Path $Path -AllowedSigners $Signers
  if (-not ($signed -is [bool] -and $signed)) {
    $pcDate = (Get-Date).ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    Write-SetupLog -Message 'ScreenConnect installer check failed: signature' -Level ERROR -Data @{ path = $Path; pcDate = $pcDate; certificateEnds = (Get-SignerEndDateText -Path $Path) }
    return 'signature'
  }
  return ''
}

function Invoke-StepScreenConnect {
  <#
  .SYNOPSIS
    The screenconnect step (spec 4.3): installs Ben's ScreenConnect client from this release and waits for its
    service. Done / Failed, with a yellow Note and Data.Service ('Running', 'NotRunning' or 'Missing') once
    the service was waited for.
  .DESCRIPTION
    1. The config: apps.screenconnect with a url, a sha256 and a serviceName, and a signer key that signers
       holds with at least one name (Get-Signers). Anything missing is Failed('ScreenConnect is not
       configured'), with nothing read, downloaded or run.
    2. The service serviceName already there, in any state (Get-ScreenConnectServiceState not Missing), skips
       the install ('ScreenConnect already installed'): go to 7.
    3. The link: Get-ScreenConnectUrl with this bundle's version ($script:SetupVersion). None (a 'dev' run) is
       Failed('ScreenConnect: release version unknown'), with nothing downloaded.
    4. NOW 'ScreenConnect: downloading': Get-RemoteFile to <DownloadDir>\ScreenConnect.ClientSetup.exe. A
       failure is Failed('ScreenConnect download failed: <reason>').
    5. NOW 'ScreenConnect: checking': Test-ScreenConnectInstaller. A failed check deletes the file (V2-R13: the
       only file this step ever deletes) and is Failed('ScreenConnect installer check failed'); the log names
       the check.
    6. NOW 'ScreenConnect: installing': the file runs with no arguments (it asks for nothing, spec 3) through
       Invoke-External, with its own timeoutsMinutes.screenconnect (10, not default's 30: a window that waits
       costs 10 minutes). A program that cannot be started is Failed('ScreenConnect install failed (installer
       could not be started)') at once. The exit code and a timeout are logged ('ScreenConnect installer
       ended', WARN when it timed out) and decide nothing: the service does.
    7. NOW 'ScreenConnect: waiting for the service': Wait-ScreenConnectService for
       timeoutsMinutes.screenconnectService minutes, every PollSeconds seconds.
    8. Running is Done('ScreenConnect installed', or 'ScreenConnect already installed'). NotRunning is the same
       with the Note 'ScreenConnect service not running yet' (it starts with the next restart). Missing is
       Failed('ScreenConnect install timed out') when the installer timed out, else Failed('ScreenConnect
       install failed (service not found)'). Every Done writes the activity line 'ScreenConnect installed -
       this PC will appear in your ScreenConnect list'; a Failed writes none (the runner writes its line).
    The runner clears NOW after the step. PollSeconds (5) exists so tests need not wait.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [ValidateRange(1, 3600)][double]$PollSeconds = 5
  )

  # 1. The config.
  $settings = $Context.Config.apps.screenconnect
  $signers = @()
  if ($null -ne $settings) {
    try {
      $signers = @(Get-Signers -Config $Context.Config -Key ([string]$settings.signer) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
      Write-SetupLog -Message 'The ScreenConnect signer is not configured' -Level ERROR -Data @{ signer = [string]$settings.signer; error = $_.Exception.Message }
    }
  }
  $serviceName = [string]$settings.serviceName
  if ($null -eq $settings -or $signers.Count -eq 0 -or [string]::IsNullOrWhiteSpace($serviceName) -or
      [string]::IsNullOrWhiteSpace([string]$settings.url) -or [string]::IsNullOrWhiteSpace([string]$settings.sha256)) {
    Write-SetupLog -Message 'ScreenConnect is not configured (apps.screenconnect: url, sha256, serviceName, signer)' -Level ERROR
    return New-StepResult -Status Failed -Message 'ScreenConnect is not configured'
  }

  # 2. Already installed? Only the exact service name counts.
  $freshInstall = ((Get-ScreenConnectServiceState -Name $serviceName) -eq 'Missing')
  $timedOut = $false
  if ($freshInstall) {
    # 3. This release's link.
    $version = [string]$script:SetupVersion
    $url = Get-ScreenConnectUrl -Template ([string]$settings.url) -Version $version
    if ([string]::IsNullOrEmpty($url)) {
      Write-SetupLog -Message 'ScreenConnect: release version unknown; nothing downloaded' -Level ERROR -Data @{ version = $version }
      return New-StepResult -Status Failed -Message 'ScreenConnect: release version unknown'
    }

    # 4. Download.
    Set-SetupNow -Title 'ScreenConnect: downloading'
    try {
      $installer = [string](Get-RemoteFile -Url $url -Destination (Join-Path $Context.DownloadDir 'ScreenConnect.ClientSetup.exe'))
    } catch {
      Write-SetupLog -Message 'ScreenConnect download failed' -Level ERROR -Data @{ url = $url; error = $_.Exception.Message }
      return New-StepResult -Status Failed -Message "ScreenConnect download failed: $($_.Exception.Message)"
    }

    # 5. Check: anything but '' is a failed check.
    Set-SetupNow -Title 'ScreenConnect: checking'
    $failedCheck = Test-ScreenConnectInstaller -Path $installer -Sha256 ([string]$settings.sha256) -Signers $signers
    if ($failedCheck -isnot [string] -or $failedCheck.Length -ne 0) {
      Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
      return New-StepResult -Status Failed -Message 'ScreenConnect installer check failed'
    }

    # 6. Install.
    Set-SetupNow -Title 'ScreenConnect: installing'
    try {
      $run = Invoke-External -FilePath $installer -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.screenconnect)
    } catch {
      Write-SetupLog -Message 'ScreenConnect installer could not be started' -Level ERROR -Data @{ error = $_.Exception.Message }
      return New-StepResult -Status Failed -Message 'ScreenConnect install failed (installer could not be started)'
    }
    $timedOut = ($run.TimedOut -eq $true)
    $level = if ($timedOut) { 'WARN' } else { 'INFO' }
    Write-SetupLog -Message 'ScreenConnect installer ended' -Level $level -Data @{ exitCode = $run.ExitCode; timedOut = $timedOut }
  } else {
    Write-SetupLog -Message 'ScreenConnect already installed; install skipped' -Data @{ service = $serviceName }
  }

  # 7. The service decides.
  Set-SetupNow -Title 'ScreenConnect: waiting for the service'
  $service = Wait-ScreenConnectService -Name $serviceName -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.screenconnectService) -PollSeconds $PollSeconds

  # 8. The result.
  if ($service -eq 'Missing') {
    $message = if ($timedOut) { 'ScreenConnect install timed out' } else { 'ScreenConnect install failed (service not found)' }
    Write-SetupLog -Message 'ScreenConnect service not found after the wait' -Level ERROR -Data @{ service = $serviceName; timedOut = $timedOut }
    return New-StepResult -Status Failed -Message $message -Data @{ Service = 'Missing' }
  }

  $message = if ($freshInstall) { 'ScreenConnect installed' } else { 'ScreenConnect already installed' }
  Add-SetupActivity -Text 'ScreenConnect installed - this PC will appear in your ScreenConnect list'
  if ($service -eq 'Running') {
    Write-SetupLog -Message 'ScreenConnect service running' -Data @{ service = $serviceName }
    return New-StepResult -Status Done -Message $message -Data @{ Service = 'Running' }
  }
  Write-SetupLog -Message 'ScreenConnect service not running yet' -Level WARN -Data @{ service = $serviceName; state = $service }
  return New-StepResult -Status Done -Message $message -Notes @('ScreenConnect service not running yet') -Data @{ Service = 'NotRunning' }
}
