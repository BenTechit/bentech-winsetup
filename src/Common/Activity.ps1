# src/Common/Activity.ps1
# Live-status plumbing for the progress screen (spec 4.3, 4.4). Needs Logging.ps1 (Write-SetupLog).
# Nothing here draws: it holds the data the screen reads.
#   - the activity feed: Logs\activity.txt plus the newest 50 lines in memory,
#   - the tick: one handler, called at most once a second, and Wait-SetupDelay (a Start-Sleep that ticks),
#   - the NOW state: the title, sub-title, detail provider and wait stack the running step publishes.
# No function here throws: a display problem must never stop the run. Console writes are not used.

# --- Activity feed -----------------------------------------------------------------------------------
$script:SetupActivityPath = $null
$script:SetupActivityRecent = New-Object System.Collections.Generic.List[object]   # newest first, at most 50
$script:SetupActivityMax = 50
$script:SetupActivityWriteWarned = $false

function ConvertTo-SetupActivityText {
  # Private. One line: CR, LF and TAB (runs of them) become a single space.
  param([AllowNull()][AllowEmptyString()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  return ($Text -replace '[\r\n\t]+', ' ')
}

function ConvertFrom-SetupActivityLine {
  # Private. "yyyy-MM-dd HH:mm:ss<TAB>text" -> @{ Time; Text }, or $null for a line that does not fit.
  param([string]$Line)
  if ($null -eq $Line -or $Line.Length -lt 21 -or $Line[19] -ne "`t") { return $null }
  $time = [datetime]::MinValue
  if (-not [datetime]::TryParseExact($Line.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::None, [ref]$time)) { return $null }
  $text = $Line.Substring(20)
  if ($text.Length -eq 0) { return $null }
  return [pscustomobject]@{ Time = $time; Text = $text }
}

function Read-FileTail {
  <#
  .SYNOPSIS
    Reads at most the last MaxBytes of a text file that another process may hold open. Returns $null
    when the file is missing or cannot be read.
  .DESCRIPTION
    Opened with FileShare ReadWrite + Delete, so a log a vendor tool is writing can be read. A file that
    starts with FF FE is decoded as UTF-16LE (vendor logs), anything else as UTF-8; a BOM is dropped.
    When the read started in the middle of the file, the first (probably cut) line is dropped.
    Never throws.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [int]$MaxBytes = 65536
  )

  $stream = $null
  try {
    if (-not [IO.File]::Exists($Path)) { return $null }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    $length = $stream.Length

    $head = New-Object byte[] 3
    $got = 0
    while ($got -lt 3) {
      $n = $stream.Read($head, $got, 3 - $got)
      if ($n -le 0) { break }
      $got += $n
    }
    $utf16 = ($got -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE)
    $bomLength = 0
    if ($utf16) { $bomLength = 2 }
    elseif ($got -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) { $bomLength = 3 }

    $start = [math]::Max([long]$bomLength, $length - $MaxBytes)
    if ($utf16 -and ($start % 2) -ne 0) { $start++ }   # UTF-16 characters start on even offsets
    $count = $length - $start
    if ($count -le 0) { return '' }
    $partial = ($start -gt $bomLength)

    [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
    $bytes = New-Object byte[] ([int]$count)
    $total = 0
    while ($total -lt $count) {
      $n = $stream.Read($bytes, $total, [int]$count - $total)
      if ($n -le 0) { break }
      $total += $n
    }
    if ($utf16 -and ($total % 2) -ne 0) { $total-- }

    if ($utf16) { $text = [Text.Encoding]::Unicode.GetString($bytes, 0, $total) }
    else { $text = (New-Object Text.UTF8Encoding $false).GetString($bytes, 0, $total) }

    if ($partial) {
      $lf = $text.IndexOf("`n")
      if ($lf -lt 0) { return '' }
      $text = $text.Substring($lf + 1)
    }
    return $text
  } catch {
    return $null
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Initialize-SetupActivity {
  <#
  .SYNOPSIS
    Points the feed at <LogDirectory>\activity.txt and seeds the in-memory list from the last 64 KB of
    that file, so the history survives a restart. Does not create the directory.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$LogDirectory)

  $script:SetupActivityRecent.Clear()
  $script:SetupActivityWriteWarned = $false
  try {
    $script:SetupActivityPath = [IO.Path]::Combine($LogDirectory, 'activity.txt')
    $tail = Read-FileTail -Path $script:SetupActivityPath
    if ([string]::IsNullOrEmpty($tail)) { return }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($tail -split "\r?\n")) {
      $entry = ConvertFrom-SetupActivityLine -Line $line
      if ($null -ne $entry) { $entries.Add($entry) }
    }
    $from = [math]::Max(0, $entries.Count - $script:SetupActivityMax)
    for ($i = $entries.Count - 1; $i -ge $from; $i--) { $script:SetupActivityRecent.Add($entries[$i]) }
  } catch {
    Write-SetupLog -Level WARN -Message 'Could not read the activity history; continuing' -Data @{ error = $_.Exception.Message }
  }
}

function Reset-SetupActivityLog {
  <#
  .SYNOPSIS
    Starts a new run's feed: an existing activity.txt is renamed to activity-<PreviousRunId>.txt (no id:
    the file's LastWriteTime as yyyyMMdd-HHmmss; a taken name gets -2, -3, ...), the in-memory list is
    emptied and the path is set. Never throws.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$LogDirectory,
    [string]$PreviousRunId
  )

  $script:SetupActivityRecent.Clear()
  $script:SetupActivityWriteWarned = $false
  try {
    $path = [IO.Path]::Combine($LogDirectory, 'activity.txt')
    $script:SetupActivityPath = $path
    if ([IO.File]::Exists($path)) {
      if ([string]::IsNullOrWhiteSpace($PreviousRunId)) {
        $suffix = [IO.File]::GetLastWriteTime($path).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
      } else {
        $suffix = $PreviousRunId.Trim() -replace '[^0-9A-Za-z._-]', '_'
      }
      $target = [IO.Path]::Combine($LogDirectory, "activity-$suffix.txt")
      $n = 2
      while ([IO.File]::Exists($target)) {
        $target = [IO.Path]::Combine($LogDirectory, "activity-$suffix-$n.txt")
        $n++
      }
      Move-Item -LiteralPath $path -Destination $target -ErrorAction Stop
    }
  } catch {
    Write-SetupLog -Level WARN -Message 'Could not archive the previous activity file; continuing' -Data @{ error = $_.Exception.Message }
  }
}

function Add-SetupActivity {
  <#
  .SYNOPSIS
    Adds one line to the activity feed: appended to activity.txt, kept in the in-memory list (shown by
    the next tick) and logged to setup.log as "Activity: <text>". Never throws.
  .DESCRIPTION
    -LogText is what setup.log gets when it must differ from the screen text (the AnyDesk ID goes to the
    screen and activity.txt, never to setup.log).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Text,
    [string]$LogText
  )

  try {
    $clean = ConvertTo-SetupActivityText -Text $Text
    if ($clean.Length -eq 0) { return }
    $now = Get-Date
    $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)

    if ($script:SetupActivityPath) {
      try {
        [IO.File]::AppendAllText($script:SetupActivityPath, ($stamp + "`t" + $clean + "`r`n"), (New-Object Text.UTF8Encoding $false))
      } catch {
        if (-not $script:SetupActivityWriteWarned) {
          $script:SetupActivityWriteWarned = $true
          Write-SetupLog -Level WARN -Message 'Could not write the activity file; continuing' -Data @{ error = $_.Exception.Message }
        }
      }
    }

    $script:SetupActivityRecent.Insert(0, [pscustomobject]@{ Time = $now; Text = $clean })
    if ($script:SetupActivityRecent.Count -gt $script:SetupActivityMax) {
      $script:SetupActivityRecent.RemoveRange($script:SetupActivityMax, $script:SetupActivityRecent.Count - $script:SetupActivityMax)
    }

    $logLine = ConvertTo-SetupActivityText -Text $LogText
    if ($logLine.Length -eq 0) { $logLine = $clean }
    Write-SetupLog -Message ('Activity: ' + $logLine)
  } catch {
    Write-SetupLog -Level WARN -Message 'Could not add an activity line; continuing' -Data @{ error = $_.Exception.Message }
  }
}

function Get-SetupActivityLines {
  <#
  .SYNOPSIS
    The newest activity lines, newest first, at most Count: objects with Time and Text. Callers wrap the
    call in @() (the lines are emitted one by one, so none and one are not arrays on their own).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][int]$Count)

  $n = [math]::Min($Count, $script:SetupActivityRecent.Count)
  for ($i = 0; $i -lt $n; $i++) { $script:SetupActivityRecent[$i] }
}

# --- Tick ----------------------------------------------------------------------------------------------
$script:SetupTickHandler = $null
$script:SetupTickContext = $null
$script:SetupTickClock = $null          # test seam: a scriptblock returning elapsed milliseconds
$script:SetupTickStopwatch = $null      # the default clock
$script:SetupTickLastRun = $null
$script:SetupTickLastWarn = $null
$script:SetupTickRunning = $false
$script:SetupTickMinGapMs = 1000
$script:SetupTickWarnGapMs = 60000

function Get-SetupTickMs {
  # Private. Elapsed milliseconds from the Clock seam, else from the process Stopwatch.
  if ($null -ne $script:SetupTickClock) { return [long](& $script:SetupTickClock) }
  if ($null -eq $script:SetupTickStopwatch) { $script:SetupTickStopwatch = [Diagnostics.Stopwatch]::StartNew() }
  return [long]$script:SetupTickStopwatch.ElapsedMilliseconds
}

function Register-SetupTick {
  <#
  .SYNOPSIS
    Registers the one tick handler: Invoke-SetupTick calls `& $Handler $Context`. -Clock (a scriptblock
    returning elapsed milliseconds) replaces the default Stopwatch; tests use it.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][scriptblock]$Handler,
    [Parameter(Mandatory)][hashtable]$Context,
    [scriptblock]$Clock
  )

  $script:SetupTickHandler = $Handler
  $script:SetupTickContext = $Context
  $script:SetupTickClock = $Clock
  $script:SetupTickStopwatch = [Diagnostics.Stopwatch]::StartNew()
  $script:SetupTickLastRun = $null
  $script:SetupTickLastWarn = $null
  $script:SetupTickRunning = $false
}

function Unregister-SetupTick {
  [CmdletBinding()]
  param()

  $script:SetupTickHandler = $null
  $script:SetupTickContext = $null
  $script:SetupTickClock = $null
  $script:SetupTickStopwatch = $null
  $script:SetupTickLastRun = $null
  $script:SetupTickLastWarn = $null
  $script:SetupTickRunning = $false
}

function Invoke-SetupTick {
  <#
  .SYNOPSIS
    Calls the registered handler (the progress screen's redraw). Never throws.
  .DESCRIPTION
    No handler: returns. Less than 1000 ms since the last run (unless -Force): returns. Called from
    inside the handler: returns. The handler's output is discarded. It runs inside a one-shot loop,
    because try/catch does not stop break/continue, which would otherwise travel up the call stack into
    the caller's own loops (same pattern as Save-SetupProgress). A failure is logged at WARN, at most
    once per 60 000 ms of the Clock; the run goes on.
  #>
  [CmdletBinding()]
  param([switch]$Force)

  $handler = $script:SetupTickHandler
  if ($null -eq $handler -or $script:SetupTickRunning) { return }
  $script:SetupTickRunning = $true
  $now = $null
  $failure = $null
  $finished = $false
  foreach ($once in 1) {
    try {
      $now = Get-SetupTickMs
      $last = $script:SetupTickLastRun
      # A clock that went backwards counts as "long ago": it must not freeze the display.
      $tooSoon = (-not $Force) -and ($null -ne $last) -and ($now -ge $last) -and (($now - $last) -lt $script:SetupTickMinGapMs)
      if (-not $tooSoon) {
        $script:SetupTickLastRun = $now
        & $handler $script:SetupTickContext | Out-Null
      }
      $finished = $true
    } catch {
      $failure = $_.Exception.Message
      $finished = $true
    } finally {
      $script:SetupTickRunning = $false
    }
  }
  if ($finished -and $null -eq $failure) { return }

  $lastWarn = $script:SetupTickLastWarn
  $due = ($null -eq $now) -or ($null -eq $lastWarn) -or ($now -lt $lastWarn) -or (($now - $lastWarn) -ge $script:SetupTickWarnGapMs)
  if (-not $due) { return }
  if ($null -ne $now) { $script:SetupTickLastWarn = $now }
  if ($null -ne $failure) {
    Write-SetupLog -Level WARN -Message 'Progress display failed; continuing' -Data @{ error = $failure }
  } else {
    Write-SetupLog -Level WARN -Message 'Progress display used break/continue outside a loop; ignored'
  }
}

function Wait-SetupDelay {
  <#
  .SYNOPSIS
    Start-Sleep that keeps the progress screen alive. Step code calls this, never Start-Sleep.
  .DESCRIPTION
    No tick registered: exactly one Start-Sleep with the same parameter and value (the run without a
    screen behaves as before; Start-Sleep -Seconds takes whole seconds on Windows PowerShell 5.1, so use
    -Milliseconds for a fraction). With a tick: Start-Sleep -Milliseconds slices of at most 250, and
    Invoke-SetupTick after each. It ends when the Clock or the sum of the slices reaches the total, so a
    clock that stands still or jumps back cannot stretch it.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ParameterSetName = 'Seconds')][double]$Seconds,
    [Parameter(Mandatory, ParameterSetName = 'Milliseconds')][int]$Milliseconds
  )

  if ($null -eq $script:SetupTickHandler) {
    if ($PSCmdlet.ParameterSetName -eq 'Seconds') { Start-Sleep -Seconds $Seconds }
    else { Start-Sleep -Milliseconds $Milliseconds }
    return
  }

  if ($PSCmdlet.ParameterSetName -eq 'Seconds') { $totalMs = [long][math]::Ceiling($Seconds * 1000) }
  else { $totalMs = [long]$Milliseconds }
  $startedMs = Get-SetupTickMs
  $slept = [long]0
  while ($slept -lt $totalMs) {
    $slice = [int][math]::Min(250, $totalMs - $slept)
    Start-Sleep -Milliseconds $slice
    $slept += $slice
    Invoke-SetupTick
    if (((Get-SetupTickMs) - $startedMs) -ge $totalMs) { break }
  }
}

# --- NOW state -----------------------------------------------------------------------------------------
# What the running step publishes for the progress screen. Shape (Get-SetupNow):
#   @{ Title; SubTitle; Provider; ProviderArgument; Wait = $null | @{ StartedAt; LimitMinutes } }
# Wait is the top of the wait stack. The screen calls a provider as `& $Provider $ProviderArgument`; it is
# never turned into a closure (a closure's module scope cannot see the bundle's functions).
$script:SetupNowState = @{ Title = $null; SubTitle = $null; Provider = $null; ProviderArgument = $null }
$script:SetupWaitStack = New-Object System.Collections.Generic.List[object]

function Set-SetupNow {
  <#
  .SYNOPSIS
    Sets only the NOW fields that are passed. An empty Title or SubTitle clears that field.
  #>
  [CmdletBinding()]
  param(
    [string]$Title,
    [string]$SubTitle,
    [scriptblock]$Provider,
    [object]$ProviderArgument
  )

  if ($PSBoundParameters.ContainsKey('Title')) { $script:SetupNowState.Title = if ([string]::IsNullOrEmpty($Title)) { $null } else { $Title } }
  if ($PSBoundParameters.ContainsKey('SubTitle')) { $script:SetupNowState.SubTitle = if ([string]::IsNullOrEmpty($SubTitle)) { $null } else { $SubTitle } }
  if ($PSBoundParameters.ContainsKey('Provider')) { $script:SetupNowState.Provider = $Provider }
  if ($PSBoundParameters.ContainsKey('ProviderArgument')) { $script:SetupNowState.ProviderArgument = $ProviderArgument }
}

function Clear-SetupNow {
  [CmdletBinding()]
  param()

  $script:SetupNowState = @{ Title = $null; SubTitle = $null; Provider = $null; ProviderArgument = $null }
  $script:SetupWaitStack.Clear()
}

function Get-SetupNow {
  [CmdletBinding()]
  param()

  $wait = $null
  if ($script:SetupWaitStack.Count -gt 0) {
    $top = $script:SetupWaitStack[$script:SetupWaitStack.Count - 1]
    $wait = @{ StartedAt = $top.StartedAt; LimitMinutes = $top.LimitMinutes }
  }
  return @{
    Title            = $script:SetupNowState.Title
    SubTitle         = $script:SetupNowState.SubTitle
    Provider         = $script:SetupNowState.Provider
    ProviderArgument = $script:SetupNowState.ProviderArgument
    Wait             = $wait
  }
}

function Enter-SetupWait {
  <#
  .SYNOPSIS
    Pushes a bounded wait (its limit in minutes) on the wait stack; the screen shows the top one.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][double]$LimitMinutes,
    [datetime]$StartedAt
  )

  if (-not $PSBoundParameters.ContainsKey('StartedAt')) { $StartedAt = Get-Date }
  $script:SetupWaitStack.Add(@{ StartedAt = $StartedAt; LimitMinutes = $LimitMinutes })
}

function Exit-SetupWait {
  [CmdletBinding()]
  param()

  if ($script:SetupWaitStack.Count -gt 0) { $script:SetupWaitStack.RemoveAt($script:SetupWaitStack.Count - 1) }
}
