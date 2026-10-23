# src/Steps/Apps.ps1
# Steps 7-9 (spec 8.3): Google Chrome, AnyDesk and 7-Zip, and the optional Zoom (zoom spec 3.2, winget like 7-Zip).
# Needs StepResult.ps1, Logging.ps1, Process.ps1, Download.ps1, Config.ps1 (Get-Signers) and Winget.ps1
# (Invoke-WingetInstall, Get-WingetPath, Get-WingetVersion); the bundle holds every file.
# Office.ps1 and DefaultBrowser.ps1 also use Test-ChromeInstalled and Write-TextFileUtf8NoBom from here.
#
# Chrome and AnyDesk come from vendor permalinks that always serve the newest build; both are
# Authenticode-checked against the signer in config before they run (spec 9.1). 7-Zip and Zoom go through winget.
#
# Each of the four also writes one fact to the activity feed (Add-SetupActivity, Activity.ps1): the version
# that was installed, read with Get-InstalledAppVersions (Report.ps1; the bundle holds every file), or for a
# Zoom that winget found already installed, 'Zoom already installed'. That line is display only, so a version
# that cannot be read never changes a step's result.

function Write-TextFileUtf8NoBom {
  <#
  .SYNOPSIS
    Writes Text to Path as UTF-8 WITHOUT a byte-order mark, creating the folder if needed. Throws on failure.
  .DESCRIPTION
    Office's setup.exe and the Windows default-associations policy both read these files, and a BOM in
    front of the XML declaration is a needless risk (Set-Content -Encoding UTF8 writes one in Windows
    PowerShell 5.1). The path is resolved against PowerShell's location, because [IO.File] uses the
    process's current directory.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text
  )

  $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $folder = Split-Path -Parent $target
  if ($folder) { [void][IO.Directory]::CreateDirectory($folder) }
  [IO.File]::WriteAllText($target, $Text, (New-Object Text.UTF8Encoding $false))
}

# --- activity facts ---------------------------------------------------------------------------

function Get-AppVersionText {
  <#
  .SYNOPSIS
    Private. The installed version of one of the apps this tool installs, for the activity feed: the
    value Get-InstalledAppVersions reports under Name ('Google Chrome', 'AnyDesk', '7-Zip', 'Zoom'), or '' when
    the app is not listed or the lookup fails (a WARN). Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Name)

  try {
    $versions = Get-InstalledAppVersions
    if ($versions -is [System.Collections.IDictionary] -and $versions.Contains($Name)) { return ([string]$versions[$Name]).Trim() }
  } catch {
    Write-SetupLog -Message 'An installed app version could not be read' -Level WARN -Data @{ app = $Name; error = $_.Exception.Message }
  }
  return ''
}

function Get-AppLabel {
  # Private. '<Name> <version>' for the activity feed, or just Name when the version is not known.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Name)

  $version = Get-AppVersionText -Name $Name
  if ($version -ne '') { return "$Name $version" }
  return $Name
}

# --- Chrome (step 7) --------------------------------------------------------------------------

function Get-ChromeMsiUrl {
  <#
  .SYNOPSIS
    The enterprise MSI permalink for an architecture ('x64' or 'ARM64'), from config apps.chrome.msi.
    Throws for an architecture the config does not list.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Arch
  )

  $entry = $Config.apps.chrome.msi.PSObject.Properties[$Arch]
  if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
    throw "config has no Chrome MSI for architecture: $Arch"
  }
  return [string]$entry.Value
}

function Test-ChromeInstalled {
  <#
  .SYNOPSIS
    $true when chrome.exe exists under Program Files or Program Files (x86).
  .DESCRIPTION
    The enterprise MSI installs system-wide under Program Files; the x86 folder is checked too for a
    32-bit Chrome. Used by the Chrome step ("already installed") and the default-browser step.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ([string]::IsNullOrEmpty($base)) { continue }
    if (Test-Path -LiteralPath (Join-Path $base 'Google\Chrome\Application\chrome.exe') -PathType Leaf) { return $true }
  }
  return $false
}

function Invoke-StepChrome {
  <#
  .SYNOPSIS
    Step 7: installs Google Chrome from the enterprise MSI, silently. Done / Failed.
  .DESCRIPTION
    Already installed (chrome.exe present) is Done('Already installed'). Otherwise the MSI for the
    machine's architecture is downloaded to <Downloads>\chrome.msi, its signature is checked against
    the configured Google signer (a bad file is deleted and never run), and
    `msiexec /i "<msi>" /qn /norestart` runs with the configured msi timeout. 0 is Done; 3010 and
    1641 are Done too (the Windows Update loop does the reboot). 1618 ("another installation is
    running") waits RetrySeconds (60) and tries again, three tries in all. Any other exit code, a
    timeout or an msiexec that cannot be started is Failed('Chrome install failed (msiexec <code>)').
    RetrySeconds exists so tests need not wait.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [ValidateRange(0, 3600)][double]$RetrySeconds = 60
  )

  if (Test-ChromeInstalled) { return New-StepResult -Status Done -Message 'Already installed' }

  try {
    $url = Get-ChromeMsiUrl -Config $Context.Config -Arch ([string]$Context.State.Machine.Arch)
    $msi = [string](Get-RemoteFile -Url $url -Destination (Join-Path $Context.DownloadDir 'chrome.msi'))
  } catch {
    Write-SetupLog -Message 'Chrome download failed' -Level ERROR -Data @{ error = $_.Exception.Message }
    return New-StepResult -Status Failed -Message "Chrome download failed: $($_.Exception.Message)"
  }

  $signers = Get-Signers -Config $Context.Config -Key ([string]$Context.Config.apps.chrome.signer)
  if (-not (Test-FileSignature -Path $msi -AllowedSigners $signers)) {
    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    return New-StepResult -Status Failed -Message 'Chrome installer signature check failed'
  }

  $msiexec = Join-Path $env:windir 'System32\msiexec.exe'
  $arguments = "/i `"$msi`" /qn /norestart"
  $timeout = [double]$Context.Config.timeoutsMinutes.msi
  $maxTries = 3
  for ($try = 1; $try -le $maxTries; $try++) {
    try {
      $run = Invoke-External -FilePath $msiexec -ArgumentList $arguments -TimeoutMinutes $timeout
    } catch {
      Write-SetupLog -Message 'msiexec could not be started' -Level ERROR -Data @{ error = $_.Exception.Message }
      return New-StepResult -Status Failed -Message 'Chrome install failed (msiexec could not be started)'
    }
    if ($run.TimedOut) { return New-StepResult -Status Failed -Message 'Chrome install failed (msiexec timed out)' }

    $outcome = Convert-MsiExitCode -ExitCode $run.ExitCode
    if ($outcome -eq 'Done') {
      Add-SetupActivity -Text ((Get-AppLabel -Name 'Google Chrome') + ' installed')
      return New-StepResult -Status Done -Message 'Chrome installed'
    }
    if ($outcome -eq 'DoneReboot') {
      Add-SetupActivity -Text ((Get-AppLabel -Name 'Google Chrome') + ' installed')
      return New-StepResult -Status Done -Message 'Chrome installed (reboot needed)'
    }
    if ($outcome -eq 'Retry' -and $try -lt $maxTries) {
      Write-SetupLog -Message 'Another installation is running; waiting before trying Chrome again' -Level WARN -Data @{ attempt = $try; of = $maxTries; waitSeconds = $RetrySeconds }
      Wait-SetupDelay -Seconds $RetrySeconds
      continue
    }
    return New-StepResult -Status Failed -Message "Chrome install failed (msiexec $($run.ExitCode))"
  }
}

# --- AnyDesk (step 8) -------------------------------------------------------------------------
# The AnyDesk ID identifies the customer's machine to Ben. It is kept in State.AnyDeskId and shown on the
# progress screen and the final screen, and kept in activity.txt and the report; it is never written to
# setup.log (the activity line passes a LogText without it) and never put in a step message.

function Get-AnyDeskIdFromText {
  <#
  .SYNOPSIS
    The first line of `AnyDesk.exe --get-id` output that is exactly a 9-10 digit ID, or $null.
  .DESCRIPTION
    Whole lines only, so a banner or an error that merely contains digits is never taken for an ID.
    ASCII digits only ([0-9]; \d would also accept other scripts' digits).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  foreach ($line in ([string]$Text -split "`r`n|`r|`n")) {
    $m = [regex]::Match($line, '^\s*([0-9]{9,10})\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return $null
}

function Get-AnyDeskIdFromConf {
  <#
  .SYNOPSIS
    The ID from `ad.anynet.id=<9-10 digits>` in the text of %ProgramData%\AnyDesk\service.conf, or $null.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  $m = [regex]::Match([string]$Text, '(?m)^\s*ad\.anynet\.id=([0-9]{9,10})\s*$')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-AnyDeskInstallArgs {
  <#
  .SYNOPSIS
    The AnyDesk installer command line (spec Q8): a full install that starts with Windows, creates the
    shortcuts and updates itself. Deliberately NO password and NO unattended access: the customer must
    accept every connection.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$InstallDir)

  return "--install `"$InstallDir`" --start-with-win --create-shortcuts --create-desktop-icon --silent --update-auto"
}

function Read-AnyDeskIdFromServiceConf {
  # Private. The ID from %ProgramData%\AnyDesk\service.conf, or $null when the file is missing,
  # unreadable or has no ID. Never throws.
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $path = Join-Path $env:ProgramData 'AnyDesk\service.conf'
  try {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-AnyDeskIdFromConf -Text (Get-Content -LiteralPath $path -Raw -ErrorAction Stop))
  } catch {
    Write-SetupLog -Message 'AnyDesk service.conf could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
    return $null
  }
}

function Find-AnyDeskId {
  <#
  .SYNOPSIS
    Private. Polls `AnyDesk.exe --get-id` every PollSeconds for up to TimeoutMinutes (always at least
    once) and returns the ID, or $null. Each round that gets no ID also tries service.conf.
  .DESCRIPTION
    A fresh install needs a few seconds before the service answers. Each --get-id run is limited to
    one minute. AnyDesk.exe is only run once it exists (the installer may return before the files are
    in place). Neither the ID nor the command output is logged.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][double]$TimeoutMinutes,
    [Parameter(Mandatory)][double]$PollSeconds
  )

  $limitSeconds = $TimeoutMinutes * 60
  $clock = [Diagnostics.Stopwatch]::StartNew()
  Enter-SetupWait -LimitMinutes $TimeoutMinutes
  try {
    while ($true) {
      $id = $null
      if (Test-Path -LiteralPath $Exe -PathType Leaf) {
        try {
          $run = Invoke-External -FilePath $Exe -ArgumentList '--get-id' -TimeoutMinutes 1 -CaptureOutput
          if (-not $run.TimedOut) { $id = Get-AnyDeskIdFromText -Text $run.Output }
        } catch {
          Write-SetupLog -Message 'AnyDesk --get-id could not be run' -Level WARN -Data @{ error = $_.Exception.Message }
        }
      }
      if (-not $id) { $id = Read-AnyDeskIdFromServiceConf }
      if ($id) { return $id }

      $remaining = $limitSeconds - $clock.Elapsed.TotalSeconds
      if ($remaining -le 0) { return $null }
      Wait-SetupDelay -Milliseconds ([int][Math]::Ceiling([Math]::Min($PollSeconds, $remaining) * 1000))
    }
  } finally {
    Exit-SetupWait
  }
}

function Invoke-StepAnyDesk {
  <#
  .SYNOPSIS
    Step 8: installs AnyDesk (when it is not installed yet) and records its ID in State.AnyDeskId.
  .DESCRIPTION
    Missing <installDir>\AnyDesk.exe means: download config apps.anydesk.url to <Downloads>\AnyDesk.exe,
    check its signature against the configured AnyDesk signer (MANDATORY: a bad file is deleted and
    never run), and run it with Get-AnyDeskInstallArgs (timeout: default). A non-zero exit is
    Failed('AnyDesk install failed (<code>)'). Then the ID is polled (Find-AnyDeskId) for
    timeoutsMinutes.anydeskId minutes. No ID is still Done, with the Note 'AnyDesk ID not available
    yet'; but a fresh install whose AnyDesk.exe never appears is Failed. PollSeconds (5) exists so
    tests need not wait.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [ValidateRange(0, 3600)][double]$PollSeconds = 5
  )

  $settings = $Context.Config.apps.anydesk
  $installDir = [string]$settings.installDir
  $exe = Join-Path $installDir 'AnyDesk.exe'
  $freshInstall = -not (Test-Path -LiteralPath $exe -PathType Leaf)

  if ($freshInstall) {
    try {
      $installer = [string](Get-RemoteFile -Url ([string]$settings.url) -Destination (Join-Path $Context.DownloadDir 'AnyDesk.exe'))
    } catch {
      Write-SetupLog -Message 'AnyDesk download failed' -Level ERROR -Data @{ error = $_.Exception.Message }
      return New-StepResult -Status Failed -Message "AnyDesk download failed: $($_.Exception.Message)"
    }

    $signers = Get-Signers -Config $Context.Config -Key ([string]$settings.signer)
    if (-not (Test-FileSignature -Path $installer -AllowedSigners $signers)) {
      Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
      return New-StepResult -Status Failed -Message 'AnyDesk installer signature check failed'
    }

    try {
      $run = Invoke-External -FilePath $installer -ArgumentList (Get-AnyDeskInstallArgs -InstallDir $installDir) -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.default)
    } catch {
      Write-SetupLog -Message 'AnyDesk installer could not be started' -Level ERROR -Data @{ error = $_.Exception.Message }
      return New-StepResult -Status Failed -Message 'AnyDesk install failed (installer could not be started)'
    }
    if ($run.TimedOut) { return New-StepResult -Status Failed -Message 'AnyDesk install timed out' }
    if ($run.ExitCode -ne 0) { return New-StepResult -Status Failed -Message "AnyDesk install failed ($($run.ExitCode))" }
  }

  $id = Find-AnyDeskId -Exe $exe -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.anydeskId) -PollSeconds $PollSeconds
  if ($id) {
    $Context.State.AnyDeskId = $id
    Write-SetupLog -Message 'AnyDesk ID read'
    # The ID is shown on the screen and kept in activity.txt, never in setup.log: LogText replaces it there.
    $label = Get-AppLabel -Name 'AnyDesk'
    Add-SetupActivity -Text "$label - ID $id" -LogText "$label - ID recorded"
    return New-StepResult -Status Done -Message $(if ($freshInstall) { 'AnyDesk installed' } else { 'AnyDesk already installed' })
  }

  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    return New-StepResult -Status Failed -Message 'AnyDesk install failed (AnyDesk.exe not found after install)'
  }
  Write-SetupLog -Message 'AnyDesk ID not available yet' -Level WARN
  return New-StepResult -Status Done -Message $(if ($freshInstall) { 'AnyDesk installed' } else { 'AnyDesk already installed' }) -Notes @('AnyDesk ID not available yet')
}

# --- 7-Zip (step 9) ---------------------------------------------------------------------------

function Invoke-StepSevenZip {
  <#
  .SYNOPSIS
    Step 9: installs 7-Zip with winget (it picks x64 or ARM64 itself). Returns winget's own StepResult.
  .DESCRIPTION
    7-Zip's installers are not Authenticode-signed, so winget's hash check against the manifest is the
    integrity check, and there is no direct-download fallback (spec 8.3).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $result = Invoke-WingetInstall -Id ([string]$Context.Config.apps.sevenZip.wingetId) -Source winget -Context $Context
  if ($result.Status -eq 'Done') { Add-SetupActivity -Text ((Get-AppLabel -Name '7-Zip') + ' installed') }
  return $result
}

# --- Zoom (zoom spec 3.2) ---------------------------------------------------------------------

function Invoke-StepZoom {
  <#
  .SYNOPSIS
    Installs Zoom per-machine with winget (apps.zoom.wingetId), auto-update on. Returns a StepResult.
  .DESCRIPTION
    Like 7-Zip: winget's hash check against the manifest is the integrity check. The signed config's
    apps.zoom.custom tokens (Zoom's ZConfig MSI property, Q50) travel on winget's --custom argument; each
    is checked with Test-WingetCustomToken first, and one that fails is dropped and logged by its position,
    never by its text. The run waits at most timeoutsMinutes.zoom, so a msiexec help box from a wrong token
    costs minutes, not timeoutsMinutes.default (a missing or unusable timeoutsMinutes.zoom falls back to
    timeoutsMinutes.default, with a WARN).
      - A fresh install is Done (winget's result) with the activity line '<Zoom [version]> installed'. When no
        token that reaches winget carries AU2_EnableAutoUpdate (missing, dropped, or winget too old) Zoom still
        installs, with the yellow Note 'Zoom auto-update not set' (final review M3: another refused token
        alone is only a WARN).
      - --custom needs winget 1.5 or later (final review M2): before passing tokens the step reads winget's
        version (Get-WingetVersion, one minute at most). Below 1.5, or unreadable, Zoom installs without the
        tokens (a WARN), so with the Note.
      - Already installed (Data.AlreadyInstalled: winget 0x8A150061, or 0x8A15002B "no applicable update" for a
        Zoom that is up to date or installed per user, ruling Z-R3; nothing ran, so auto-update was not
        touched) is Done '<id>: already installed' with the Note 'Zoom was already installed: auto-update not
        changed' and the activity line 'Zoom already installed'. A customer's own per-user Zoom is left alone.
        An older per-machine Zoom is upgraded by `winget install`, with the tokens: that reads as a fresh install.
      - A timed-out install is Failed 'Zoom install timed out'.
      - Anything else (another Failed, Skipped) is winget's own result, unchanged; a failure is red.
    It never opens Zoom, signs in, or creates or removes shortcuts (Q52).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $zoom = $Context.Config.apps.zoom
  $id = [string]$zoom.wingetId
  $given = @()
  if ($null -ne $zoom) {
    $property = $zoom.PSObject.Properties['custom']
    if ($null -ne $property -and $null -ne $property.Value) { $given = @($property.Value) }
  }
  $custom = New-Object System.Collections.Generic.List[string]
  $dropped = New-Object System.Collections.Generic.List[int]
  for ($i = 0; $i -lt $given.Count; $i++) {
    if ($given[$i] -is [string] -and (Test-WingetCustomToken -Token $given[$i])) { $custom.Add($given[$i]) } else { $dropped.Add($i) }
  }
  if ($dropped.Count -gt 0) {
    Write-SetupLog -Message 'Zoom custom arguments refused by the token check; Zoom installs without them' -Level WARN -Data @{ given = $given.Count; droppedPositions = ($dropped.ToArray() -join ',') }
  }
  # Final review M2: winget's --custom needs winget 1.5 or later; an older one refuses the whole command line.
  # With no winget at all there is nothing to ask: Invoke-WingetInstall then says 'winget unavailable'.
  if ($custom.Count -gt 0) {
    $wingetPath = Get-WingetPath
    if ($wingetPath) {
      $wingetVersion = Get-WingetVersion -Path $wingetPath
      if ($null -eq $wingetVersion -or $wingetVersion -lt [version]'1.5') {
        Write-SetupLog -Message 'winget is older than 1.5, or its version could not be read: no --custom, so Zoom installs without its custom arguments' -Level WARN -Data @{ wingetVersion = [string]$wingetVersion }
        $custom.Clear()
      }
    }
  }
  # Final review M3: the Note says auto-update is not set only when no token that reaches winget carries the
  # auto-update key; another refused token alone is only the WARN above.
  $autoUpdateSet = $false
  foreach ($token in $custom) { if ($token.Contains('AU2_EnableAutoUpdate')) { $autoUpdateSet = $true } }
  if (-not $autoUpdateSet) {
    Write-SetupLog -Message 'No Zoom custom argument with AU2_EnableAutoUpdate reaches winget; Zoom installs without auto-update' -Level WARN -Data @{ given = $given.Count; passed = $custom.Count }
  }

  # Task 1 review M2: a limit that is missing or not a usable number of minutes (a broken config; Invoke-External
  # takes 0.001 to 10080) falls back to timeoutsMinutes.default, so Zoom still installs.
  $limit = 0.0
  $parsed = [double]::TryParse([string]$Context.Config.timeoutsMinutes.zoom, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$limit)
  if (-not ($parsed -and $limit -ge 0.001 -and $limit -le 10080)) {
    Write-SetupLog -Message 'timeoutsMinutes.zoom is missing or not a usable number of minutes; using timeoutsMinutes.default' -Level WARN
    $limit = [double]$Context.Config.timeoutsMinutes.default
  }

  $result = Invoke-WingetInstall -Id $id -Source winget -Context $Context -Custom $custom.ToArray() -TimeoutMinutes $limit
  $data = if ($result.Data -is [hashtable]) { $result.Data } else { @{} }

  if ($result.Status -eq 'Done' -and $data['AlreadyInstalled'] -eq $true) {
    Add-SetupActivity -Text 'Zoom already installed'
    return New-StepResult -Status Done -Message "${id}: already installed" -Notes @('Zoom was already installed: auto-update not changed') -Data @{ AlreadyInstalled = $true }
  }
  if ($result.Status -eq 'Done') {
    Add-SetupActivity -Text ((Get-AppLabel -Name 'Zoom') + ' installed')
    if ($autoUpdateSet) { return $result }
    return New-StepResult -Status Done -Message $result.Message -Reboot $result.Reboot -Notes (@($result.Notes) + 'Zoom auto-update not set') -Errors $result.Errors -Data $data
  }
  if ($result.Status -eq 'Failed' -and $data['TimedOut'] -eq $true) {
    return New-StepResult -Status Failed -Message 'Zoom install timed out' -Data @{ TimedOut = $true }
  }
  return $result
}
