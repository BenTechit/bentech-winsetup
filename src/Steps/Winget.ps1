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

function Test-WingetCustomToken {
  <#
  .SYNOPSIS
    $true when Token may travel on winget's --custom argument: NAME=VALUE, a name of letters, digits and
    '_', a value of letters, digits, '_', '=' and ';' (zoom spec 3.2).
  .DESCRIPTION
    The tokens are spliced into one quoted command-line value, so anything else (a quote, a space, '&', a
    leading '-', a non-ASCII letter) is refused. -cmatch, not -match: a case-insensitive [A-Za-z] also
    takes the Kelvin sign (U+212A) for a k. \z, not $, so a trailing newline does not pass.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()][AllowEmptyString()][string]$Token)

  return ($Token -cmatch '^[A-Za-z0-9_]+=[A-Za-z0-9_=;]+\z')
}

function Get-WingetInstallArgs {
  <#
  .SYNOPSIS
    The winget command line for a silent, non-interactive install. Throws for an id that is not a
    plain package id, or for a custom token that fails Test-WingetCustomToken.
  .DESCRIPTION
    Custom (zoom spec 3.2): tokens from the signed config that winget adds to the installer's command
    line. Joined with one space and passed as one quoted value, ` --custom "<tokens>"`, only when at
    least one token is given; without them the command line is exactly what it always was. The error
    never repeats a refused token.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Id,
    [ValidateSet('winget', 'msstore')][string]$Source = 'winget',
    [string[]]$Custom
  )

  if (-not (Test-WingetPackageId -Id $Id)) { throw "invalid winget package id '$Id'" }
  $line = "install --id $Id -e --source $Source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
  if ($null -eq $Custom -or $Custom.Count -eq 0) { return $line }
  foreach ($token in $Custom) {
    if (-not (Test-WingetCustomToken -Token $token)) { throw 'invalid winget custom argument' }
  }
  return $line + ' --custom "' + ($Custom -join ' ') + '"'
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
    The timeout is TimeoutMinutes when given, else timeoutsMinutes.default. Output is captured only so
    a short tail can be logged when the run fails; it is never parsed (Windows may be Hebrew).
    0x8A15000F ("source data missing") runs `winget source reset --force` once (same timeout) and
    repeats the command once; a second 0x8A15000F is a failure. A "done, reboot needed" is Done with
    Reboot 'None': the Windows Update loop reboots. A program that cannot be started is a Failed
    result, not a throw. Two answers carry Data for the caller (zoom spec 3.2): a Done from 0x8A150061
    (the package was already installed and winget ran nothing) has @{ AlreadyInstalled = $true }, and
    a run that timed out has @{ TimedOut = $true }.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][ValidateSet('install', 'uninstall')][string]$Verb,
    [Parameter(Mandatory)][string]$ArgumentList,
    [Parameter(Mandatory)][hashtable]$Context,
    [Nullable[double]]$TimeoutMinutes
  )

  $winget = Get-WingetPath
  if (-not $winget) { return New-StepResult -Status Failed -Message 'winget unavailable' }

  $timeout = [double]$Context.Config.timeoutsMinutes.default
  if ($null -ne $TimeoutMinutes) { $timeout = [double]$TimeoutMinutes }
  $resetDone = $false
  while ($true) {
    try {
      $run = Invoke-External -FilePath $winget -ArgumentList $ArgumentList -TimeoutMinutes $timeout -CaptureOutput
    } catch {
      Write-SetupLog -Message "winget $Verb could not be started" -Level ERROR -Data @{ id = $Id; winget = $winget; error = $_.Exception.Message }
      return New-StepResult -Status Failed -Message "${Id}: winget could not be started"
    }
    if ($run.TimedOut) { return New-StepResult -Status Failed -Message "${Id}: winget timed out" -Data @{ TimedOut = $true } }
    if ($null -eq $run.ExitCode) { return New-StepResult -Status Failed -Message "${Id}: winget returned no exit code" }

    $outcome = Convert-WingetExitCode -ExitCode $run.ExitCode
    if ($outcome -eq 'SourceReset' -and -not $resetDone) {
      $resetDone = $true
      Write-SetupLog -Message "winget $Verb needs its sources reset; resetting once and retrying" -Level WARN -Data @{ id = $Id }
      try {
        $reset = Invoke-External -FilePath $winget -ArgumentList 'source reset --force' -TimeoutMinutes $timeout -CaptureOutput
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
        # 0x8A150061: already installed, nothing ran (so no custom argument was applied). The message stays
        # as it always was; the caller that cares reads Data.
        $data = @{}
        if ((Format-WingetExitCode -ExitCode $run.ExitCode) -ceq '0x8A150061') { $data['AlreadyInstalled'] = $true }
        return New-StepResult -Status Done -Message "${Id}: $doneText" -Data $data
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
    Failed result and nothing is run. See Invoke-WingetOperation for the source-reset retry and the
    Data of an already-installed or timed-out answer.
    Custom and TimeoutMinutes (zoom spec 3.2): the tokens for winget's --custom argument
    (Get-WingetInstallArgs) and this call's own limit instead of timeoutsMinutes.default. A custom
    token that fails Test-WingetCustomToken is a Failed result and nothing is run (the message does not
    repeat it). Without them the call is exactly what it always was.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Id,
    [string]$Source = 'winget',
    [Parameter(Mandatory)][hashtable]$Context,
    [string[]]$Custom,
    [Nullable[double]]$TimeoutMinutes
  )

  if (-not (Test-WingetPackageId -Id $Id)) { return New-StepResult -Status Failed -Message "invalid winget package id '$Id'" }
  if ($Source -notin 'winget', 'msstore') { return New-StepResult -Status Failed -Message "${Id}: invalid winget source '$Source'" }
  foreach ($token in $Custom) {
    if (-not (Test-WingetCustomToken -Token $token)) { return New-StepResult -Status Failed -Message "${Id}: invalid winget custom argument" }
  }
  Invoke-WingetOperation -Id $Id -Verb install -ArgumentList (Get-WingetInstallArgs -Id $Id -Source $Source -Custom $Custom) -Context $Context -TimeoutMinutes $TimeoutMinutes
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

function ConvertTo-PowerShellLiteral {
  <#
  .SYNOPSIS
    Quotes text as a PowerShell single-quoted string literal.
  .DESCRIPTION
    Inside '...' the only special character is the single quote, which is doubled. PowerShell also
    treats the typographic quotes U+2018, U+2019, U+201A and U+201B as single quotes, so those are
    doubled too (a path with an apostrophe typed on a phone keyboard must not end the string).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

  # The apostrophe and the four typographic quotes, written as code points so this file stays ASCII.
  $quotes = -join ([char]0x27, [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B)
  return "'" + [regex]::Replace($Text, "[$quotes]", '$0$0') + "'"
}

function Invoke-PowerShellChild {
  <#
  .SYNOPSIS
    Runs a PowerShell command line in a child Windows PowerShell 5.1 process with a timeout.
    Returns @{ ExitCode = <int|$null>; TimedOut = <bool>; Output = <string> }.
  .DESCRIPTION
    Used for cmdlets that have no timeout of their own (Add-AppxPackage). The process is started
    through Invoke-External, which kills the whole tree on timeout. The command travels as
    -EncodedCommand (Base64 of UTF-16LE text), so no quoting of the command, or of a path inside
    it, can go wrong. $ProgressPreference is silenced so a captured pipe does not fill with
    progress records. The child's exit code is 0 for a command that finished and 1 when it
    stopped on an error, which is what callers should test. Output is never parsed.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][double]$TimeoutMinutes
  )

  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ProgressPreference = 'SilentlyContinue'; $Command"))
  $exe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $run = Invoke-External -FilePath $exe -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" -TimeoutMinutes $TimeoutMinutes -CaptureOutput
  return @{ ExitCode = $run.ExitCode; TimedOut = [bool]$run.TimedOut; Output = [string]$run.Output }
}

function Invoke-AppxChild {
  <#
  .SYNOPSIS
    Private. Runs an Add-AppxPackage command line in a child process (Invoke-PowerShellChild).
    $true on exit code 0. A timeout, a non-zero exit code or a child that cannot be started is a
    WARN in the log and $false; it never throws, so the caller goes on to its next stage.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$What,
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][double]$TimeoutMinutes
  )

  try {
    $run = Invoke-PowerShellChild -Command $Command -TimeoutMinutes $TimeoutMinutes
  } catch {
    Write-SetupLog -Message "$What failed: the child process could not be started" -Level WARN -Data @{ error = $_.Exception.Message }
    return $false
  }
  if ($run.TimedOut) {
    Write-SetupLog -Message "$What timed out" -Level WARN -Data @{ timeoutMinutes = $TimeoutMinutes }
    return $false
  }
  if ($null -eq $run.ExitCode -or $run.ExitCode -ne 0) {
    Write-SetupLog -Message "$What failed" -Level WARN -Data @{ exitCode = $run.ExitCode; tail = (Get-OutputTail -Output $run.Output) }
    return $false
  }
  return $true
}

function Test-WingetUsable {
  <#
  .SYNOPSIS
    $true when `<Path> --version` runs, does not time out and exits with 0. Never throws.
  .DESCRIPTION
    A winget.exe that exists is not necessarily a winget that runs: a stale App Execution Alias
    (alias file present, App Installer unregistered or broken) is found by Get-WingetPath but
    cannot start, or starts and fails. The probe waits at most one minute (Invoke-External kills
    the process tree on timeout). An exception, such as a program that cannot be started, is $false.
    The output is captured so a console is not written to, and is never read.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Path)

  try {
    $run = Invoke-External -FilePath $Path -ArgumentList '--version' -TimeoutMinutes 1 -CaptureOutput
    $usable = (-not $run.TimedOut) -and ($null -ne $run.ExitCode) -and ($run.ExitCode -eq 0)
    if (-not $usable) {
      Write-SetupLog -Message 'winget --version did not succeed' -Level WARN -Data @{ path = $Path; timedOut = [bool]$run.TimedOut; exitCode = $run.ExitCode }
    }
    return [bool]$usable
  } catch {
    Write-SetupLog -Message 'winget --version could not be run' -Level WARN -Data @{ path = $Path; error = $_.Exception.Message }
    return $false
  }
}

function Wait-WingetPath {
  <#
  .SYNOPSIS
    Private. Polls every PollSeconds until Get-WingetPath finds winget AND Test-WingetUsable passes
    for it, or TimeoutMinutes has passed. Returns the path, or $null. Always checks at least once,
    and the last sleep is cut short so the wait does not overshoot the timeout (a probe that
    hangs can add up to its own one-minute limit).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][double]$TimeoutMinutes,
    [Parameter(Mandatory)][double]$PollSeconds
  )

  $clock = [Diagnostics.Stopwatch]::StartNew()
  Enter-SetupWait -LimitMinutes $TimeoutMinutes
  try {
    while ($true) {
      $path = Get-WingetPath
      if ($path -and (Test-WingetUsable -Path $path)) { return $path }
      $remaining = $TimeoutMinutes * 60 - $clock.Elapsed.TotalSeconds
      if ($remaining -le 0) { return $null }
      Wait-SetupDelay -Milliseconds ([int][Math]::Ceiling([Math]::Min($PollSeconds, $remaining) * 1000))
    }
  } finally {
    Exit-SetupWait
  }
}

function Invoke-StepWinget {
  <#
  .SYNOPSIS
    Step 6: makes sure winget is usable. Done / Failed('winget unavailable').
  .DESCRIPTION
    "Ready" always means Get-WingetPath finds winget.exe AND `winget --version` succeeds
    (Test-WingetUsable), so a stale alias does not count. This is checked at every point below.
    1. winget already there and working -> Done.
    2. Register the App Installer package that ships with Windows
       (Add-AppxPackage -RegisterByFamilyName), then poll for winget every PollSeconds (15) for up
       to timeoutsMinutes.wingetReady minutes.
    3. Otherwise download winget.bundleUrl to <Downloads>\AppInstaller.msixbundle and install it
       with Add-AppxPackage -Path (Windows enforces the package signature), then poll again.
    4. Otherwise Failed('winget unavailable'); the steps that need winget fail the same way and
       the direct-download steps still run.
    Both Add-AppxPackage calls run in a child powershell.exe (Invoke-PowerShellChild) limited to
    timeoutsMinutes.default, so a hung deployment is killed rather than stalling the run. A
    registration, download or install error, a non-zero exit or a timeout is logged at WARN and the
    next stage is tried.
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
  if ($present -and (Test-WingetUsable -Path $present)) { return New-StepResult -Status Done -Message "winget ready: $present" }

  $readyMinutes = [double]$Context.Config.timeoutsMinutes.wingetReady
  if ($null -ne $ReadyTimeoutMinutes) { $readyMinutes = [double]$ReadyTimeoutMinutes }

  # Each Add-AppxPackage runs in a child powershell.exe so a hung deployment is killed at the
  # default timeout instead of stalling the run; the same limit as any other installer.
  $appxMinutes = [double]$Context.Config.timeoutsMinutes.default

  Write-SetupLog -Message 'winget not found or not working; registering App Installer' -Data @{ readyMinutes = $readyMinutes; found = [string]$present }
  [void](Invoke-AppxChild -What 'Registering App Installer' -TimeoutMinutes $appxMinutes `
      -Command 'Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop')
  $path = Wait-WingetPath -TimeoutMinutes $readyMinutes -PollSeconds $PollSeconds
  if ($path) { return New-StepResult -Status Done -Message "winget ready: $path" }

  $bundleUrl = [string]$Context.Config.winget.bundleUrl
  if ($bundleUrl) {
    Write-SetupLog -Message 'winget still missing; installing the App Installer bundle' -Level WARN -Data @{ url = $bundleUrl }
    try {
      $bundle = Get-RemoteFile -Url $bundleUrl -Destination (Join-Path $Context.DownloadDir 'AppInstaller.msixbundle')
    } catch {
      $bundle = $null
      Write-SetupLog -Message 'Downloading the App Installer bundle failed' -Level WARN -Data @{ url = $bundleUrl; error = $_.Exception.Message }
    }
    if ($bundle) {
      [void](Invoke-AppxChild -What 'Installing the App Installer bundle' -TimeoutMinutes $appxMinutes `
          -Command ("Add-AppxPackage -Path {0} -ErrorAction Stop" -f (ConvertTo-PowerShellLiteral -Text ([string]$bundle))))
    }
    $path = Wait-WingetPath -TimeoutMinutes $readyMinutes -PollSeconds $PollSeconds
    if ($path) { return New-StepResult -Status Done -Message "winget ready: $path" }
  } else {
    Write-SetupLog -Message 'No winget.bundleUrl in the config; cannot install the bundle' -Level WARN
  }

  Write-SetupLog -Message 'winget is unavailable' -Level ERROR
  return New-StepResult -Status Failed -Message 'winget unavailable'
}
