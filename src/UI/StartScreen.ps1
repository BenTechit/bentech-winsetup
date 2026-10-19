# src/UI/StartScreen.ps1
# The start screen (spec 8.1): detection results, the L / D / Z / O toggles and a 10-second countdown.
#
# Split in two on purpose:
#   * Format-StartScreen, Update-StartChoices and New-DefaultChoices are pure (values in, values out).
#   * Show-StartScreen is the interactive loop. It reaches the console, the clock and the power state
#     only through injectable script blocks with production defaults, so the tests drive it with a fake
#     clock and scripted keys (see tests/Screens.Tests.ps1).
#
# This file also holds the few helpers the progress and final screens share. All screen text is
# English and ASCII only: conhost cannot reliably show anything else.

$script:StartCountdownSeconds = 10
$script:OfficeChoices = @('OFF', 'BUSINESS', 'HOME')
# The direction and format marks Hebrew Windows adds around some values (spec 9.5): U+200E, U+200F,
# U+202A-U+202E and U+2066-U+2069, as a regex character class built from the code points so that this
# file stays ASCII.
$script:DirectionMarksPattern = '[' + (-join (@(0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069) | ForEach-Object { [char]$_ })) + ']'

function ConvertTo-ScreenText {
  # One line of plain ASCII: direction marks are dropped, line breaks and tabs become a space, every
  # other character outside 0x20-0x7E becomes '?'. Used for every free-text value that reaches a
  # screen (model names, step messages), because a Hebrew Windows can put Hebrew into those.
  # The direction marks go first, so they cannot turn into '?': Hebrew Windows wraps some values in
  # them (the Windows caption came out as '??Microsoft Windows 11 Home').
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()]$Text)

  if ($null -eq $Text) { return '' }
  $clean = [regex]::Replace([string]$Text, $script:DirectionMarksPattern, '')
  $flat = [regex]::Replace($clean, '[\r\n\t]+', ' ')
  return ([regex]::Replace($flat, '[^\x20-\x7E]', '?')).Trim()
}

function Limit-ScreenLine {
  # Cuts a line to MaxLength characters ending in '...', so one long message cannot wrap and push
  # the rest of the screen off the console.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [int]$MaxLength = 79
  )

  if ($Text.Length -le $MaxLength) { return $Text }
  return $Text.Substring(0, $MaxLength - 3) + '...'
}

function ConvertFrom-StateTime {
  # A state timestamp as a [datetime], or $null. State holds ISO strings (yyyy-MM-ddTHH:mm:ss), and
  # Windows PowerShell 5.1's ConvertFrom-Json leaves them as strings when state.json is read back. A
  # [datetime] is accepted too (a caller or a test may pass one). Never throws.
  [CmdletBinding()]
  [OutputType([datetime])]
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value }
  $parsed = [datetime]::MinValue
  if ([datetime]::TryParseExact([string]$Value, 's', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function Format-HoursMinutes {
  # h:mm, hours not wrapped at 24. A negative span counts as zero.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][timespan]$Span)

  if ($Span -lt [timespan]::Zero) { $Span = [timespan]::Zero }
  return ('{0}:{1:00}' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes)
}

function New-DefaultChoices {
  <#
  .SYNOPSIS
    The choices the start screen opens with: mode from the detected machine, 7-Zip and Office from
    config.defaults.
  .DESCRIPTION
    LAPTOP only for a laptop that is not a virtual machine. An Office default that is not OFF,
    BUSINESS or HOME becomes OFF (nothing gets installed that nobody asked for).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config
  )

  $mode = if (($Machine['IsLaptop'] -eq $true) -and ($Machine['IsVM'] -ne $true)) { 'LAPTOP' } else { 'DESKTOP' }
  $office = ([string]$Config.defaults.office).ToUpperInvariant()
  if ($script:OfficeChoices -notcontains $office) { $office = 'OFF' }

  return @{ Mode = $mode; SevenZip = [bool]$Config.defaults.sevenZip; Office = $office }
}

function Update-StartChoices {
  <#
  .SYNOPSIS
    Applies one key press to the choices. Returns @{ Choices; Action; ResetCountdown }.
  .DESCRIPTION
    Key names are [ConsoleKey] names ('L', 'Enter', 'Escape'), matched case-insensitively.
    L / D set the mode, Z toggles 7-Zip, O cycles Office OFF -> BUSINESS -> HOME -> OFF; each of them
    resets the countdown. Enter returns Action 'Start', Escape returns 'Cancel'. Any other key does
    nothing. The input table is never changed: Choices is a copy.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Choices,
    [AllowNull()][AllowEmptyString()][string]$Key
  )

  $next = $Choices.Clone()
  $action = 'None'
  $reset = $false

  switch ($Key) {
    'L' { $next['Mode'] = 'LAPTOP'; $reset = $true }
    'D' { $next['Mode'] = 'DESKTOP'; $reset = $true }
    'Z' { $next['SevenZip'] = -not [bool]$next['SevenZip']; $reset = $true }
    'O' {
      $at = [array]::IndexOf($script:OfficeChoices, [string]$next['Office'])
      $next['Office'] = $script:OfficeChoices[($at + 1) % $script:OfficeChoices.Count]
      $reset = $true
    }
    'Enter'  { $action = 'Start' }
    'Escape' { $action = 'Cancel' }
  }

  return @{ Choices = $next; Action = $action; ResetCountdown = $reset }
}

function Format-StartScreen {
  <#
  .SYNOPSIS
    The start screen as lines of text (spec 8.1). Pure: no console access.
  .DESCRIPTION
    With -IsFresh the countdown line shows SecondsLeft; without it the countdown line is replaced by
    the "doesn't look like a fresh install" line and the screen never counts down. -Previous is the
    @{ StartedAt; Color } summary of an earlier run, or $null.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)][hashtable]$Choices,
    [Parameter(Mandatory)][int]$SecondsLeft,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][bool]$OnAC,
    [Parameter(Mandatory)][bool]$IsFresh,
    [AllowNull()][hashtable]$Previous
  )

  $frame = ' ' + ('=' * 64)
  $versionText = if ($Version -match '^[vV]') { $Version } else { 'v' + $Version }
  $detected = if ($Machine['IsVM'] -eq $true) { 'VM' } elseif ($Machine['IsLaptop'] -eq $true) { 'LAPTOP' } else { 'DESKTOP' }
  $power = if ($OnAC) { 'ON CHARGER' } else { 'ON BATTERY' }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add($frame)
  $lines.Add('   BENTECH WINDOWS SETUP                    ' + (ConvertTo-ScreenText $versionText))
  $lines.Add($frame)
  $lines.Add(('   Machine  : {0}  {1}        SN: {2}' -f (ConvertTo-ScreenText $Machine['Manufacturer']), (ConvertTo-ScreenText $Machine['FriendlyModel']), (ConvertTo-ScreenText $Machine['Serial'])))
  $lines.Add('   Detected : ' + $detected)
  $lines.Add(('   Windows  : {0} {1} ({2})   {3}' -f (ConvertTo-ScreenText $Machine['OsCaption']), (ConvertTo-ScreenText $Machine['OsDisplayVersion']), (ConvertTo-ScreenText $Machine['OsBuild']), (ConvertTo-ScreenText $Machine['Arch'])))
  $lines.Add('   Power    : ' + $power)
  $lines.Add('   New name : ' + (ConvertTo-ScreenText $Machine['NewName']))
  $lines.Add('')

  if ($Choices['Mode'] -eq 'LAPTOP') { $lines.Add('   MODE   [L] Laptop  <==        [D] Desktop') }
  else { $lines.Add('   MODE   [L] Laptop           [D] Desktop  <==') }
  $lines.Add('   APPS   Chrome, AnyDesk          always')
  $lines.Add('          [Z] 7-Zip                ' + $(if ($Choices['SevenZip']) { 'ON' } else { 'OFF' }))
  $lines.Add(('          [O] Office 365 (HE+EN)   {0}   (OFF/BUSINESS/HOME)' -f (ConvertTo-ScreenText $Choices['Office'])))
  $lines.Add('')

  if (-not $OnAC) {
    $lines.Add('   ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery.')
  }
  if ($null -ne $Previous) {
    $started = ConvertFrom-StateTime $Previous['StartedAt']
    $when = if ($null -ne $started) { $started.ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { 'unknown date' }
    $color = ConvertTo-ScreenText $Previous['Color']
    if ($color -eq '') { $color = 'unfinished' }
    $lines.Add(('   Previous run: {0} - {1}' -f $when, $color))
  }

  if ($IsFresh) {
    $lines.Add(('   Starting in {0}s ...  [Enter] start now   [Esc] cancel' -f $SecondsLeft))
    $lines.Add(('   (any toggle resets the countdown to {0}s)' -f $script:StartCountdownSeconds))
  } else {
    $lines.Add("   This doesn't look like a fresh install: press Enter to run anyway")
  }
  $lines.Add($frame)

  return $lines.ToArray()
}

function Write-StartScreenLines {
  # Production writer for the start screen: clear, then the lines in gray on black; the two warnings in
  # yellow on black (spec 8.1, 9.1). Both colours are named on every line, so no line depends on the
  # palette the console happens to have.
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

  Clear-Host
  foreach ($line in $Lines) {
    if ($line -like '*ON BATTERY: plug in*' -or $line -like "*doesn't look like a fresh install*") {
      Write-Host $line -ForegroundColor Yellow -BackgroundColor Black
    } else {
      Write-Host $line -ForegroundColor Gray -BackgroundColor Black
    }
  }
}

function Show-StartScreen {
  <#
  .SYNOPSIS
    Shows the start screen and returns the Choices to run with, or $null when the technician cancels.
  .DESCRIPTION
    Starts from New-DefaultChoices. Redraws once a second (re-reading the power state each time) and
    polls for a key every 100 ms. When -IsFresh it counts down from 10 and starts at 0; a toggle
    resets the count to 10. When not fresh it never starts by itself: only Enter does. Escape returns
    $null. -Previous is the @{ StartedAt; Color } summary of an earlier run, or $null.

    Keys already waiting in the console buffer are thrown away once, before the first draw: a stray
    Enter pressed while the launcher was downloading must not start the run (on a machine that does
    not look fresh, Enter is the only safeguard).

    The seams (production defaults shown):
      -ReadKey    returns the next key's [ConsoleKey] name, or nothing when no key is waiting
      -Now        the clock
      -Sleep      waits the given milliseconds
      -OnAC       $true when on mains power
      -Write      draws the lines
      -FlushInput throws away waiting key presses
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Version,
    [AllowNull()][hashtable]$Previous,
    [Parameter(Mandatory)][bool]$IsFresh,
    [scriptblock]$ReadKey = { if ([Console]::KeyAvailable) { [Console]::ReadKey($true).Key.ToString() } },
    [scriptblock]$Now = { Get-Date },
    [scriptblock]$Sleep = { param($ms) Start-Sleep -Milliseconds $ms },
    [scriptblock]$OnAC = { Test-OnACPower },
    [scriptblock]$Write = { param($lines) Write-StartScreenLines -Lines $lines },
    [scriptblock]$FlushInput = { while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) } }
  )

  $choices = New-DefaultChoices -Machine $Machine -Config $Config
  $secondsLeft = $script:StartCountdownSeconds
  $powerOnAC = $true

  # The power state is only a warning line, so a failed read keeps the last known value. Dot-sourced
  # (". $readPower") so the assignment lands in this function's scope.
  $readPower = {
    try { $powerOnAC = [bool](& $OnAC) }
    catch { Write-SetupLog -Message 'Could not read the power state for the start screen' -Level WARN -Data @{ error = $_.Exception.Message } }
  }
  $draw = {
    $lines = @(Format-StartScreen -Machine $Machine -Choices $choices -SecondsLeft $secondsLeft -Version $Version -OnAC $powerOnAC -IsFresh $IsFresh -Previous $Previous)
    $null = & $Write $lines
  }

  # Best effort: if the buffer cannot be emptied the screen still works, it just loses this guard.
  try { $null = & $FlushInput }
  catch { Write-SetupLog -Message 'Could not empty the console key buffer before the start screen' -Level WARN -Data @{ error = $_.Exception.Message } }

  . $readPower
  & $draw
  $lastTick = & $Now
  $sleptMs = 0
  while ($true) {
    $key = & $ReadKey
    if (-not [string]::IsNullOrEmpty([string]$key)) {
      $result = Update-StartChoices -Choices $choices -Key ([string]$key)
      $choices = $result.Choices
      if ($result.Action -eq 'Start') { return $choices }
      if ($result.Action -eq 'Cancel') { return $null }
      if ($result.ResetCountdown) {
        $secondsLeft = $script:StartCountdownSeconds
        $lastTick = & $Now
        $sleptMs = 0
        & $draw
      }
      continue
    }

    $null = & $Sleep 100
    $sleptMs += 100
    $current = & $Now
    # A second has passed when the clock says so or when the sleeps add up to it, whichever comes
    # first: a slow redraw does not stretch the countdown, and a clock that jumps backwards (time
    # sync) cannot freeze it.
    if ([math]::Max($sleptMs, ($current - $lastTick).TotalMilliseconds) -ge 1000) {
      $lastTick = $current
      $sleptMs = 0
      if ($IsFresh) {
        $secondsLeft--
        if ($secondsLeft -le 0) { return $choices }
      }
      . $readPower
      & $draw
    }
  }
}