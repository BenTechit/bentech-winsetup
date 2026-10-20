# src/UI/StartScreen.ps1
# The start screen (spec 8.1, v2 Q1): what was detected, what will happen, the L / D / Z / O toggles and
# a 30-second countdown that any key restarts. Needs ConsoleFrame.ps1 (the screen is drawn through a
# console writer, never Write-Host or Clear-Host) and Catalog.ps1 (Test-HasDriverTool).
#
# Split in two on purpose:
#   * Format-StartScreen, Get-StartScreenSegments, Update-StartChoices and New-DefaultChoices are pure
#     (values in, values out).
#   * Show-StartScreen is the interactive loop. It reaches the console, the clock and the power state
#     only through injectable script blocks with production defaults, so the tests drive it with a fake
#     clock and scripted keys (see tests/Screens.Tests.ps1).
#
# This file also holds the few helpers the progress and final screens share. All screen text is
# English and ASCII only: conhost cannot reliably show anything else.

$script:StartCountdownSeconds = 30
# The column where the right-hand "TO CHANGE IT, PRESS" help starts, and the width of the countdown bar.
$script:StartHelpColumn = 53
$script:StartBarWidth = 20
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
    resets the countdown. Enter returns Action 'Start', Escape returns 'Cancel'. Any other key (Q1: an
    unknown key too) changes nothing but resets the countdown, so a technician who is still reading
    does not get the run started under them. An empty or null key is no key at all. The input table is
    never changed: Choices is a copy.
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
    default  { if (-not [string]::IsNullOrEmpty($Key)) { $reset = $true } }
  }

  return @{ Choices = $next; Action = $action; ResetCountdown = $reset }
}

function Format-StartScreen {
  <#
  .SYNOPSIS
    The start screen as lines of text (spec 8.1, v2 Q1). Pure: no console access. At most 79 characters
    per line, so nothing is cut in an 80-column console (the battery line is the one exception, see below).
  .DESCRIPTION
    The machine, the new name, then WHAT WILL HAPPEN with the key that changes each choice on the right
    (from StartHelpColumn). -HasDriverTool says whether the brand has a vendor tool (Test-HasDriverTool);
    it only changes the words after the mode.

    With -IsFresh the last block is the countdown ("Starts by itself in N s" and a bar that empties over
    StartCountdownSeconds); without it the countdown is replaced by the two-line "older than N days" notice
    (-MaxAgeDays) and the screen never counts down. -Previous is the @{ StartedAt; Color } summary of an
    earlier run, or $null.
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
    [AllowNull()][hashtable]$Previous,
    [bool]$HasDriverTool = $true,
    [int]$MaxAgeDays = 14
  )

  $frame = ' ' + ('=' * 77)
  $versionText = if ($Version -match '^[vV]') { $Version } else { 'v' + $Version }
  $power = if ($OnAC) { 'ON CHARGER' } else { 'ON BATTERY' }
  $helpAt = $script:StartHelpColumn

  $isLaptop = ($Choices['Mode'] -eq 'LAPTOP')
  $typeText = if ($isLaptop) {
    if ($HasDriverTool) { 'LAPTOP (driver tool + laptop app)' } else { 'LAPTOP (no driver tool for this brand)' }
  } else {
    if ($HasDriverTool) { 'DESKTOP (no laptop app)' } else { 'DESKTOP (no driver tool for this brand)' }
  }
  $sevenZipText = if ($Choices['SevenZip']) { 'YES' } else { 'NO' }
  $officeText = switch ([string]$Choices['Office']) {
    'OFF'      { 'OFF' }
    'BUSINESS' { 'BUSINESS (Hebrew + English)' }
    'HOME'     { 'HOME (Hebrew + English)' }
    default    { ConvertTo-ScreenText $Choices['Office'] }
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add($frame)
  $lines.Add('   BENTECH WINDOWS SETUP' + (ConvertTo-ScreenText $versionText).PadLeft(54))
  $lines.Add($frame)
  $lines.Add(('   {0} {1}    SN: {2}    {3}' -f (ConvertTo-ScreenText $Machine['Manufacturer']), (ConvertTo-ScreenText $Machine['FriendlyModel']), (ConvertTo-ScreenText $Machine['Serial']), $power))
  $lines.Add('   New PC name: ' + (ConvertTo-ScreenText $Machine['NewName']))
  $lines.Add('')
  $lines.Add('   WHAT WILL HAPPEN'.PadRight($helpAt) + 'TO CHANGE IT, PRESS')
  $lines.Add(('   Type     ' + $typeText).PadRight($helpAt) + 'L = laptop   D = desktop')
  $lines.Add('   Chrome + AnyDesk   always')
  $lines.Add(('   7-Zip    ' + $sevenZipText).PadRight($helpAt) + 'Z = yes / no')
  $lines.Add(('   Office   ' + $officeText).PadRight($helpAt) + 'O = off / business / home')
  $lines.Add('')

  # This line is 85 characters (the v1 wording, kept): the frame cuts it in an 80-column console.
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
    $barWidth = $script:StartBarWidth
    $filled = [int][math]::Ceiling($barWidth * $SecondsLeft / [double]$script:StartCountdownSeconds)
    $filled = [math]::Min($barWidth, [math]::Max(0, $filled))
    $lines.Add(('   Starts by itself in {0} s   {1}{2}' -f $SecondsLeft, ('#' * $filled), ('.' * ($barWidth - $filled))))
    $lines.Add('   ENTER = start now           ESC = cancel, change nothing')
  } else {
    # Two lines, so neither is cut in an 80-column console.
    $lines.Add(('   This PC already has user files or is older than {0} days -' -f $MaxAgeDays))
    $lines.Add('   press ENTER to run anyway')
    $lines.Add('   ESC = cancel, change nothing')
  }
  $lines.Add($frame)

  return $lines.ToArray()
}

function Get-StartScreenSegments {
  <#
  .SYNOPSIS
    One start-screen row as coloured segments @{ Text; Color } for Write-ConsoleFrame -Colorize. Pure.
  .DESCRIPTION
    On the Type, 7-Zip and Office lines the chosen value (the word from column 12 to the next space) is
    Green, or DarkGray when it is NO or OFF, so the choices stand out. The battery line and the two
    not-fresh text lines are one Yellow segment. Every other row is one segment without a Color (the
    frame's Gray). No segment sets a background: the frame's Black applies. Emitted one by one: wrap the
    call in @().
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

  if ($Line -match '^   (ON BATTERY:|This PC already has user files|press ENTER to run anyway)') {
    return @{ Text = $Line; Color = 'Yellow' }
  }
  $choice = [regex]::Match($Line, '^(   (?:Type {5}|7-Zip {4}|Office {3}))(\S+)(.*)$')
  if (-not $choice.Success) { return @{ Text = $Line; Color = $null } }

  $value = $choice.Groups[2].Value
  @{ Text = $choice.Groups[1].Value; Color = $null }
  @{ Text = $value; Color = $(if ($value -eq 'NO' -or $value -eq 'OFF') { 'DarkGray' } else { 'Green' }) }
  if ($choice.Groups[3].Value.Length -gt 0) { @{ Text = $choice.Groups[3].Value; Color = $null } }
}

function Write-StartScreenLines {
  # Production writer for the start screen: the lines drawn over the console window through the console
  # writer (flicker-free, no Clear-Host, no Write-Host), the chosen values green and the warnings yellow
  # (Get-StartScreenSegments). The first frame clears the window to black, which also covers a console
  # whose profile paints the window blue. The writer is a parameter only so a test can hand in a fake one.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
    [hashtable]$Writer = (New-ConsoleWriter)
  )

  Write-ConsoleFrame -Lines $Lines -Writer $Writer -Colorize { param($l) Get-StartScreenSegments -Line $l }
}

function Show-StartScreen {
  <#
  .SYNOPSIS
    Shows the start screen and returns the Choices to run with, or $null when the technician cancels.
  .DESCRIPTION
    Starts from New-DefaultChoices. Redraws once a second (re-reading the power state each time) and
    polls for a key every 100 ms. When -IsFresh it counts down from 30 and starts at 0; any key other
    than Enter and Escape (a toggle, or an unknown key: Q1) resets the count to 30, so it starts by
    itself only when nobody touches it. When not fresh it never starts by itself: only Enter does.
    Escape returns $null. -Previous is the @{ StartedAt; Color } summary of an earlier run, or $null.
    The screen is drawn through the console writer, which can fail when the window is resized or closed
    in the middle of a frame; that is logged and the next frame starts over, it never stops the run.

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
  $hasDriverTool = Test-HasDriverTool -Machine $Machine
  $maxAgeDays = [int]$Config.freshInstall.maxInstallAgeDays
  $draw = {
    $lines = @(Format-StartScreen -Machine $Machine -Choices $choices -SecondsLeft $secondsLeft -Version $Version -OnAC $powerOnAC -IsFresh $IsFresh -Previous $Previous `
      -HasDriverTool $hasDriverTool -MaxAgeDays $maxAgeDays)
    try { $null = & $Write $lines }
    catch {
      # Best effort, like the power read: the next frame clears the window and draws everything again.
      Reset-ConsoleFrame
      Write-SetupLog -Message 'Could not draw the start screen' -Level WARN -Data @{ error = $_.Exception.Message }
    }
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