function ConvertTo-UInt32ExitCode {
  <#
  .SYNOPSIS
    Returns an exit code as its unsigned 32-bit value, whichever form it arrives in.
  .DESCRIPTION
    Process.ExitCode is an Int32, so winget's 0x8A15xxxx codes arrive negative (0x8A150061 is
    -1978335135), and a hex literal in Windows PowerShell 5.1 is that same negative Int32. Values
    inside the Int32 range are re-read bit for bit; a value above Int32.MaxValue is already the
    unsigned form and is cast directly. Anything outside 0..4294967295 / -2147483648..-1 throws.
  #>
  [CmdletBinding()]
  [OutputType([uint32])]
  param([Parameter(Mandatory)][long]$ExitCode)

  if ($ExitCode -ge [int]::MinValue -and $ExitCode -le [int]::MaxValue) {
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$ExitCode), 0)
  }
  return [uint32]$ExitCode
}

function Convert-WingetExitCode {
  <#
  .SYNOPSIS
    Maps a winget exit code to Done, DoneReboot, Skipped, SourceReset or Failed.
  .DESCRIPTION
    0 and 0x8A150061 (already installed)       -> Done
    0x8A150109, 0x8A15010B (reboot needed)      -> DoneReboot
    0x8A150014, 0x8A150010 (nothing to install) -> Skipped
    0x8A15000F (source data missing)            -> SourceReset
    anything else                               -> Failed

    The parameter is untyped on purpose. Invoke-External returns ExitCode = $null for a timed-out
    run, and a typed parameter would silently turn that $null into 0, i.e. 'Done'. A null,
    non-numeric or out-of-range value is 'Failed'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param($ExitCode)

  # A number is converted as a number. Going through [string] would break a numeric literal typed
  # in command-argument mode (0x8A15000F), which PowerShell keeps together with its source text.
  $n = [long]0
  if ($null -eq $ExitCode) { return 'Failed' }
  if ($ExitCode -is [string]) {
    if (-not [long]::TryParse($ExitCode, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return 'Failed' }
  } else {
    try { $n = [long]$ExitCode } catch { return 'Failed' }
  }
  try {
    $code = ConvertTo-UInt32ExitCode -ExitCode $n
  } catch {
    return 'Failed'
  }
  # Compared as text so no signed/unsigned literal can be mistaken for another.
  switch ('{0:X8}' -f $code) {
    '00000000' { return 'Done' }
    '8A150061' { return 'Done' }
    '8A150109' { return 'DoneReboot' }
    '8A15010B' { return 'DoneReboot' }
    '8A150014' { return 'Skipped' }
    '8A150010' { return 'Skipped' }
    '8A15000F' { return 'SourceReset' }
    default { return 'Failed' }
  }
}

function Test-WingetPackageId {
  <#
  .SYNOPSIS
    $true when Id looks like a winget package id: letters, digits, '.', '_' and '-', starting with a
    letter or digit.
  .DESCRIPTION
    The id is spliced into a command line, so anything else (a space, a quote, ';', '&', a leading
    '-' that would read as an option) is refused. \z, not $, so a trailing newline does not pass.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()][AllowEmptyString()][string]$Id)

  return ($Id -match '^[A-Za-z0-9][A-Za-z0-9._-]*\z')
}

function Get-WingetInstallArgs {
  <#
  .SYNOPSIS
    The winget command line for a silent, non-interactive install. Throws for an id that is not a
    plain package id.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Id,
    [ValidateSet('winget', 'msstore')][string]$Source = 'winget'
  )

  if (-not (Test-WingetPackageId -Id $Id)) { throw "invalid winget package id '$Id'" }
  return "install --id $Id -e --source $Source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
}

function Get-WingetUninstallArgs {
  <#
  .SYNOPSIS
    The winget command line for a silent, non-interactive uninstall. Throws for an id that is not a
    plain package id.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Id)

  if (-not (Test-WingetPackageId -Id $Id)) { throw "invalid winget package id '$Id'" }
  return "uninstall --id $Id -e --silent --disable-interactivity --accept-source-agreements"
}

function Get-WingetPath {
  <#
  .SYNOPSIS
    The full path of winget.exe, or $null when it is not there.
  .DESCRIPTION
    Tried in order:
    1. Get-Command winget.exe (on PATH).
    2. The current user's App Execution Alias, %LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe. A
       process that was started before App Installer was registered does not see the new PATH
       entry, but the alias is already there.
    3. The newest %ProgramFiles%\WindowsApps\Microsoft.DesktopAppInstaller_<version>_(x64|arm64)__8wekyb3d8bbwe
       package folder that holds a winget.exe. "Newest" compares the version numbers, so 1.27 beats
       1.9. Listing WindowsApps is usually denied to non-SYSTEM accounts; that just means "not found".
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source) { return [string]$cmd.Source }

  if ($env:LOCALAPPDATA) {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias -PathType Leaf) { return $alias }
  }

  if ($env:ProgramFiles) {
    $apps = Join-Path $env:ProgramFiles 'WindowsApps'
    $folders = @(Get-ChildItem -LiteralPath $apps -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction SilentlyContinue)
    $found = foreach ($folder in $folders) {
      $m = [regex]::Match($folder.Name, '^Microsoft\.DesktopAppInstaller_(?<v>\d+(?:\.\d+){1,3})_(?:x64|arm64)__8wekyb3d8bbwe$')
      $version = $null
      if ($m.Success -and [version]::TryParse($m.Groups['v'].Value, [ref]$version)) {
        $exe = Join-Path $folder.FullName 'winget.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) { [pscustomobject]@{ Version = $version; Path = $exe } }
      }
    }
    $newest = @($found | Sort-Object -Property Version -Descending | Select-Object -First 1)
    if ($newest.Count -gt 0) { return [string]$newest[0].Path }
  }

  return $null
}

function Format-WingetExitCode {
  <#
  .SYNOPSIS
    An exit code as 0x + eight hex digits (0x8A15001E), however it arrived. A value that is not a
    32-bit code is returned as plain text so a report never has to fail over it.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param($ExitCode)

  try {
    return ('0x{0:X8}' -f (ConvertTo-UInt32ExitCode -ExitCode ([long]$ExitCode)))
  } catch {
    return [string]$ExitCode
  }
}

function Get-OutputTail {
  <#
  .SYNOPSIS
    The last few meaningful lines of a captured output, joined with ' | ', for a log entry.
  .DESCRIPTION
    Only for logging. Lines without a letter or digit (winget's spinner and progress bar) are
    dropped and each line is cut to 200 characters. The text is never parsed or compared.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Output, [int]$Count = 5)

  if ([string]::IsNullOrEmpty($Output)) { return '' }
  $lines = @($Output -split "`r`n|`r|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '[\p{L}\p{N}]' })
  if ($lines.Count -gt $Count) { $lines = $lines[($lines.Count - $Count)..($lines.Count - 1)] }
  return (($lines | ForEach-Object { if ($_.Length -gt 200) { $_.Substring(0, 200) } else { $_ } }) -join ' | ')
}

function Invoke-WingetOperation {
  <#
  .SYNOPSIS
    Private. Runs one winget install or uninstall and turns its exit code into a StepResult.
  .DESCRIPTION
    The timeout is timeoutsMinutes.default. Output is captured only so a short tail can be logged
    when the run fails; it is never parsed (Windows may be Hebrew). 0x8A15000F ("source data
    missing") runs `winget source reset --force` once (5 minutes at most) and repeats the command
    once; a second 0x8A15000F is a failure. A "done, reboot needed" is Done with Reboot 'None': the
    Windows Update loop reboots. A program that cannot be started is a Failed result, not a throw.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][ValidateSet('install', 'uninstall')][string]$Verb,
    [Parameter(Mandatory)][string]$ArgumentList,
    [Parameter(Mandatory)][hashtable]$Context
  )

  $winget = Get-WingetPath
  if (-not $winget) { return New-StepResult -Status Failed -Message 'winget unavailable' }

  $timeout = [double]$Context.Config.timeoutsMinutes.default
  $resetDone = $false
  while ($true) {
    try {
      $run = Invoke-External -FilePath $winget -ArgumentList $ArgumentList -TimeoutMinutes $timeout -CaptureOutput
    } catch {
      Write-SetupLog -Message "winget $Verb could not be started" -Level ERROR -Data @{ id = $Id; winget = $winget; error = $_.Exception.Message }
      return New-StepResult -Status Failed -Message "${Id}: winget could not be started"
    }
    if ($run.TimedOut) { return New-StepResult -Status Failed -Message "${Id}: winget timed out" }
    if ($null -eq $run.ExitCode) { return New-StepResult -Status Failed -Message "${Id}: winget returned no exit code" }

    $outcome = Convert-WingetExitCode -ExitCode $run.ExitCode
    if ($outcome -eq 'SourceReset' -and -not $resetDone) {
      $resetDone = $true
      Write-SetupLog -Message "winget $Verb needs its sources reset; resetting once and retrying" -Level WARN -Data @{ id = $Id }
      try {
        $reset = Invoke-External -FilePath $winget -ArgumentList 'source reset --force' -TimeoutMinutes 5 -CaptureOutput
        if ($reset.TimedOut -or $reset.ExitCode -ne 0) {
          Write-SetupLog -Message 'winget source reset did not succeed; retrying anyway' -Level WARN -Data @{ id = $Id; timedOut = [bool]$reset.TimedOut; exitCode = $reset.ExitCode; tail = (Get-OutputTail -Output $reset.Output) }
        }
      } catch {
        Write-SetupLog -Message 'winget source reset could not be started; retrying anyway' -Level WARN -Data @{ id = $Id; error = $_.Exception.Message }
      }
      continue
    }

    switch ($outcome) {
      'Done' {
        $doneText = if ($Verb -eq 'install') { 'installed' } else { 'uninstalled' }
        return New-StepResult -Status Done -Message "${Id}: $doneText"
      }
      'DoneReboot' {
        $doneText = if ($Verb -eq 'install') { 'installed' } else { 'uninstalled' }
        return New-StepResult -Status Done -Message "${Id}: $doneText (reboot needed)"
      }
      'Skipped' {
        $skipText = if ($Verb -eq 'install') { 'no package or installer for this system' } else { 'not installed, nothing to remove' }
        return New-StepResult -Status Skipped -Message "${Id}: $skipText"
      }
      default {
        # Failed, or SourceReset again after the one reset.
        $hex = Format-WingetExitCode -ExitCode $run.ExitCode
        Write-SetupLog -Message "winget $Verb failed" -Level WARN -Data @{ id = $Id; exitCode = $hex; tail = (Get-OutputTail -Output $run.Output) }
        return New-StepResult -Status Failed -Message "${Id}: winget $hex"
      }
    }
  }
}

function Invoke-WingetInstall {
  <#
  .SYNOPSIS
    Installs one package with winget, silently. Returns a StepResult.
  .DESCRIPTION
    Failed('winget unavailable') when winget is missing; Failed('<id>: winget 0x<code>') for an
    unexpected exit code; Failed('<id>: winget timed out'); Skipped when winget has no package or
    installer for this system. A package id that is not a plain id (or an unknown source) is a
    Failed result and nothing is run. See Invoke-WingetOperation for the source-reset retry.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Id,
    [string]$Source = 'winget',
    [Parameter(Mandatory)][hashtable]$Context
  )

  if (-not (Test-WingetPackageId -Id $Id)) { return New-StepResult -Status Failed -Message "invalid winget package id '$Id'" }
  if ($Source -notin 'winget', 'msstore') { return New-StepResult -Status Failed -Message "${Id}: invalid winget source '$Source'" }
  Invoke-WingetOperation -Id $Id -Verb install -ArgumentList (Get-WingetInstallArgs -Id $Id -Source $Source) -Context $Context
}

function Invoke-WingetUninstall {
  <#
  .SYNOPSIS
    Uninstalls one package with winget, silently. Returns a StepResult, mapped like Invoke-WingetInstall.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Id,
    [Parameter(Mandatory)][hashtable]$Context
  )

  if (-not (Test-WingetPackageId -Id $Id)) { return New-StepResult -Status Failed -Message "invalid winget package id '$Id'" }
  Invoke-WingetOperation -Id $Id -Verb uninstall -ArgumentList (Get-WingetUninstallArgs -Id $Id) -Context $Context
}

function Wait-WingetPath {
  <#
  .SYNOPSIS
    Private. Polls Get-WingetPath every PollSeconds until it finds winget or TimeoutMinutes has
    passed. Returns the path, or $null. Always checks at least once, and the last sleep is cut
    short so the wait never overshoots the timeout.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][double]$TimeoutMinutes,
    [Parameter(Mandatory)][double]$PollSeconds
  )

  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $path = Get-WingetPath
    if ($path) { return $path }
    $remaining = $TimeoutMinutes * 60 - $clock.Elapsed.TotalSeconds
    if ($remaining -le 0) { return $null }
    Start-Sleep -Milliseconds ([int][Math]::Ceiling([Math]::Min($PollSeconds, $remaining) * 1000))
  }
}

function Invoke-StepWinget {
  <#
  .SYNOPSIS
    Step 6: makes sure winget is usable. Done / Failed('winget unavailable').
  .DESCRIPTION
    1. winget already there -> Done.
    2. Register the App Installer package that ships with Windows
       (Add-AppxPackage -RegisterByFamilyName), then poll for winget every PollSeconds (15) for up
       to timeoutsMinutes.wingetReady minutes.
    3. Otherwise download winget.bundleUrl to <Downloads>\AppInstaller.msixbundle and install it
       with Add-AppxPackage -Path (Windows enforces the package signature), then poll again.
    4. Otherwise Failed('winget unavailable'); the steps that need winget fail the same way and
       the direct-download steps still run.
    A registration, download or install error is logged at WARN and the next stage is tried.
    PollSeconds and ReadyTimeoutMinutes exist so tests need not wait; by default they are 15 and
    the configured wingetReady.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [ValidateRange(0, 3600)][double]$PollSeconds = 15,
    [Nullable[double]]$ReadyTimeoutMinutes
  )

  $present = Get-WingetPath
  if ($present) { return New-StepResult -Status Done -Message "winget ready: $present" }

  $readyMinutes = [double]$Context.Config.timeoutsMinutes.wingetReady
  if ($null -ne $ReadyTimeoutMinutes) { $readyMinutes = [double]$ReadyTimeoutMinutes }

  Write-SetupLog -Message 'winget not found; registering App Installer' -Data @{ readyMinutes = $readyMinutes }
  try {
    Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop | Out-Null
  } catch {
    Write-SetupLog -Message 'Registering App Installer failed' -Level WARN -Data @{ error = $_.Exception.Message }
  }
  $path = Wait-WingetPath -TimeoutMinutes $readyMinutes -PollSeconds $PollSeconds
  if ($path) { return New-StepResult -Status Done -Message "winget ready: $path" }

  $bundleUrl = [string]$Context.Config.winget.bundleUrl
  if ($bundleUrl) {
    Write-SetupLog -Message 'winget still missing; installing the App Installer bundle' -Level WARN -Data @{ url = $bundleUrl }
    try {
      $bundle = Get-RemoteFile -Url $bundleUrl -Destination (Join-Path $Context.DownloadDir 'AppInstaller.msixbundle')
      Add-AppxPackage -Path $bundle -ErrorAction Stop | Out-Null
    } catch {
      Write-SetupLog -Message 'Installing the App Installer bundle failed' -Level WARN -Data @{ url = $bundleUrl; error = $_.Exception.Message }
    }
    $path = Wait-WingetPath -TimeoutMinutes $readyMinutes -PollSeconds $PollSeconds
    if ($path) { return New-StepResult -Status Done -Message "winget ready: $path" }
  } else {
    Write-SetupLog -Message 'No winget.bundleUrl in the config; cannot install the bundle' -Level WARN
  }

  Write-SetupLog -Message 'winget is unavailable' -Level ERROR
  return New-StepResult -Status Failed -Message 'winget unavailable'
}
