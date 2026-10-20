# src/Steps/Apps.ps1
# Steps 7-9 (spec 8.3): Google Chrome, AnyDesk and 7-Zip. Needs StepResult.ps1, Logging.ps1, Process.ps1,
# Download.ps1, Config.ps1 (Get-Signers) and Winget.ps1 (Invoke-WingetInstall); the bundle holds every file.
# Office.ps1 and DefaultBrowser.ps1 also use Test-ChromeInstalled and Write-TextFileUtf8NoBom from here.
#
# Chrome and AnyDesk come from vendor permalinks that always serve the newest build; both are
# Authenticode-checked against the signer in config before they run (spec 9.1). 7-Zip goes through winget.

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
    if ($outcome -eq 'Done') { return New-StepResult -Status Done -Message 'Chrome installed' }
    if ($outcome -eq 'DoneReboot') { return New-StepResult -Status Done -Message 'Chrome installed (reboot needed)' }
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
# final screen and in the report; it is never written to the log and never put in a step message.

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

  return Invoke-WingetInstall -Id ([string]$Context.Config.apps.sevenZip.wingetId) -Source winget -Context $Context
}
