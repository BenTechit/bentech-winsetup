# src/UI/FinalScreen.ps1
# The final screen (spec 8.6): the whole console turns green, yellow or red, the AnyDesk ID is shown
# in big digits (Ben reads it from across the room) and the screen waits for a key. Every colour is
# named outright, foreground and background (spec 9.1): the powershell.exe console profile remaps
# DarkYellow to near white, so a YELLOW screen of white text on DarkYellow could not be read.
#
# Format-BigDigits and Format-FinalScreen are pure. Show-FinalScreen reaches the console, the keyboard,
# the clock, the USB stick and the launcher only through injectable script blocks with production
# defaults, so the tests drive it with a scripted key sequence and a fake clock. Uses ConvertTo-ScreenText,
# Limit-ScreenLine, ConvertFrom-StateTime and Format-HoursMinutes from StartScreen.ps1, the console frame
# writer from ConsoleFrame.ps1, Find-SetupStick and Format-StickLine from Entry\Cleanup.ps1, and the
# default-browser helpers from DefaultBrowser.ps1 and Apps.ps1.

$script:FinalScreenWidth = 80
# Triage 240, v2 spec 10: with both lists over their caps, the Chrome hint, the USB stick line and a
# 10-digit AnyDesk ID, the screen is 29 lines. The frame writer keeps the last row of the window free, so
# that fits a default 30-row console window without scrolling the banner away.
$script:FinalMaxFailures = 3
$script:FinalMaxNotes = 2

# A 5x5 font for the AnyDesk ID. Every glyph is exactly 5 columns wide and 5 rows tall.
$script:BigDigitFont = @{
  '0' = @('#####', '#   #', '#   #', '#   #', '#####')
  '1' = @('  #  ', ' ##  ', '  #  ', '  #  ', ' ### ')
  '2' = @('#####', '    #', '#####', '#    ', '#####')
  '3' = @('#####', '    #', '#####', '    #', '#####')
  '4' = @('#   #', '#   #', '#####', '    #', '    #')
  '5' = @('#####', '#    ', '#####', '    #', '#####')
  '6' = @('#####', '#    ', '#####', '#   #', '#####')
  '7' = @('#####', '    #', '   # ', '  #  ', '  #  ')
  '8' = @('#####', '#   #', '#####', '#   #', '#####')
  '9' = @('#####', '#   #', '#####', '    #', '#####')
  ' ' = @('     ', '     ', '     ', '     ', '     ')
}

function Format-BigDigits {
  <#
  .SYNOPSIS
    Draws the text as 5 rows of '#' characters, one glyph per character.
  .DESCRIPTION
    Handles 0-9 and space; any other character is drawn as a space. Each glyph is 5 columns wide and
    glyphs are separated by one blank column (no trailing gap), so a row is 6n-1 columns for n
    characters. Always returns exactly 5 rows (empty strings for empty text).
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  $rows = for ($r = 0; $r -lt 5; $r++) {
    $parts = foreach ($ch in $Text.ToCharArray()) {
      $glyph = $script:BigDigitFont[[string]$ch]
      if ($null -eq $glyph) { $glyph = $script:BigDigitFont[' '] }
      $glyph[$r]
    }
    @($parts) -join ' '
  }
  return [string[]]@($rows)
}

function ConvertTo-DigitGroups {
  # The digits of an ID in groups of three, e.g. 123456789 -> '123 456 789' and 1234567890 ->
  # '123 456 7890' (a lone trailing digit joins the group before it). Anything but digits is dropped.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Id)

  $digits = [regex]::Replace([string]$Id, '[^0-9]', '')
  if ($digits.Length -eq 0) { return '' }
  $groups = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $digits.Length; $i += 3) {
    $groups.Add($digits.Substring($i, [math]::Min(3, $digits.Length - $i)))
  }
  if ($groups.Count -gt 1 -and $groups[$groups.Count - 1].Length -eq 1) {
    $groups[$groups.Count - 2] += $groups[$groups.Count - 1]
    $groups.RemoveAt($groups.Count - 1)
  }
  return ($groups.ToArray() -join ' ')
}

function Add-ScreenList {
  # Adds up to Max items to Lines, each as "<Prefix><text>" cut to fit the console, then a
  # "... and N more" line for the rest, so a long list can never push the banner and the ID off
  # the top of the screen.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Lines,
    [AllowNull()]$Items,
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory)][int]$Max
  )

  $texts = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Items)) {
    $text = ConvertTo-ScreenText $item
    if ($text -ne '') { $texts.Add($text) }
  }
  for ($i = 0; $i -lt [math]::Min($Max, $texts.Count); $i++) {
    $Lines.Add((Limit-ScreenLine ($Prefix + $texts[$i])))
  }
  if ($texts.Count -gt $Max) {
    $Lines.Add(('{0}... and {1} more: see the report' -f $Prefix, ($texts.Count - $Max)))
  }
}

function Format-FinalScreen {
  <#
  .SYNOPSIS
    The final screen as lines of text. Pure apart from the optional -Now default (the current time).
  .DESCRIPTION
    In order: the banner centred in an 80-column frame of '=', the machine and new name, the AnyDesk
    ID in big digits grouped 3-3-3 (or "not available"), the total time and reboot count, each
    failure ("  X  ..."), each note ("  !  ..."), the Chrome hint when Chrome is not the default
    browser, the -StickLine (right above the report line; left out when empty), and the report line.
    The total time runs from State.StartedAt to State.EndedAt, or to -Now while the run has no end
    time. At most 3 failures and 2 notes are listed (then "... and N more"), and each is cut to 79
    columns, so the worst case is 29 lines (a 30-row window less the row the frame writer keeps free).
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][hashtable]$Verdict,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][bool]$DefaultBrowserIsChrome,
    [datetime]$Now = (Get-Date),
    [AllowNull()][AllowEmptyString()][string]$StickLine = ''
  )

  $machine = if ($State['Machine'] -is [hashtable]) { $State['Machine'] } else { @{} }
  $frame = '=' * $script:FinalScreenWidth
  $banner = ConvertTo-ScreenText $Verdict['Banner']
  $indent = [math]::Max(0, [int][math]::Floor(($script:FinalScreenWidth - $banner.Length) / 2))

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add($frame)
  $lines.Add('')
  $lines.Add((' ' * $indent) + $banner)
  $lines.Add('')
  $lines.Add($frame)
  $lines.Add('')
  $lines.Add(('  Machine  : {0}  {1}        SN: {2}' -f (ConvertTo-ScreenText $machine['Manufacturer']), (ConvertTo-ScreenText $machine['FriendlyModel']), (ConvertTo-ScreenText $machine['Serial'])))
  $lines.Add('  New name : ' + (ConvertTo-ScreenText $machine['NewName']))
  $lines.Add('')

  $groups = ConvertTo-DigitGroups ([string]$State['AnyDeskId'])
  if ($groups -eq '') {
    $lines.Add('  AnyDesk ID: not available')
  } else {
    $lines.Add('  AnyDesk ID:')
    foreach ($row in (Format-BigDigits -Text $groups)) { $lines.Add('    ' + $row) }
  }
  $lines.Add('')

  $started = ConvertFrom-StateTime $State['StartedAt']
  $ended = ConvertFrom-StateTime $State['EndedAt']
  if ($null -eq $ended) { $ended = $Now }
  $total = if ($null -ne $started) { $ended - $started } else { [timespan]::Zero }
  $lines.Add(('  Total time: {0}   Reboots: {1}' -f (Format-HoursMinutes $total), [int]$State['RebootCount']))

  $problems = New-Object System.Collections.Generic.List[string]
  Add-ScreenList -Lines $problems -Items $Verdict['Failures'] -Prefix '  X  ' -Max $script:FinalMaxFailures
  Add-ScreenList -Lines $problems -Items $Verdict['Notes'] -Prefix '  !  ' -Max $script:FinalMaxNotes
  if ($problems.Count -gt 0) {
    $lines.Add('')
    $lines.AddRange($problems)
  }

  $lines.Add('')
  if (-not $DefaultBrowserIsChrome) {
    $lines.Add("  Chrome is not the default browser: press B to open Default Apps, then click 'Set default'")
  }
  if (-not [string]::IsNullOrEmpty($StickLine)) { $lines.Add($StickLine) }
  $lines.Add(('  Report: {0}   [R] open report   [ENTER] finish' -f $ReportPath))

  return $lines.ToArray()
}

function Get-VerdictColors {
  # The console colours of a verdict colour (spec 9.1): YELLOW is Black on Yellow, GREEN is White on
  # DarkGreen, and anything else (RED, or a name nobody expected) is White on DarkRed, so an unknown
  # verdict can never look green by accident. Neither DarkYellow nor DarkMagenta is ever used: the
  # powershell.exe console profile remaps both.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()][AllowEmptyString()][string]$Color)

  switch ($Color) {
    'YELLOW' { return @{ Background = 'Yellow'; Foreground = 'Black' } }
    'GREEN'  { return @{ Background = 'DarkGreen'; Foreground = 'White' } }
    default  { return @{ Background = 'DarkRed'; Foreground = 'White' } }
  }
}

function Show-FinalScreen {
  <#
  .SYNOPSIS
    Paints the console green / yellow / red, draws the final screen and waits for Enter.
  .DESCRIPTION
    Enter finishes (v2 spec 10.1: the caller then saves the logs and deletes C:\BenTech, so a stray key
    must not end the screen). B opens Settings > Default apps for Chrome, R opens the report in Notepad;
    both keep the screen up. Every other key is ignored. The Chrome hint is left out when Chrome is the
    default browser or is not installed.

    The screen has a live USB stick line: the stick is looked for again every second and the screen
    redrawn, so a stick plugged in while the screen waits shows within a second. A stick check that throws
    counts as no stick (one WARN). The key is polled every 100 ms; a second has passed when the clock says
    so or when the sleeps add up to it (the start screen's rule), so a clock that stands still or jumps
    back cannot stop the redraws. A draw that fails (the window resized mid-frame) is logged once and the
    next frame clears the window and draws everything again.

    Keys already waiting in the console buffer are thrown away after the first draw, so a stray key
    pressed during the last step cannot close the screen before anyone has read the AnyDesk ID. The
    console colour is put back when the screen closes, also when something throws; a -ReadKey that throws
    still propagates (a crash keeps the folder for diagnosis).

    The seams (production defaults shown):
      -ReadKey    returns the waiting key's [ConsoleKey] name, or nothing when no key is waiting
      -SetColor   sets the console colours: param($background, $foreground), colour names
      -ResetColor puts the console colours back (runs when the screen closes, also after an error)
      -Write      draws the lines in the given colours: param($lines, $foreground, $background). The
                  production writer draws over the window through the console frame writer: no flicker,
                  and nothing in the transcript
      -Launch     starts a program or opens a URI: param($target, $arguments)
      -FlushInput throws away waiting key presses
      -Stick      the USB stick: @{ Root; Drive } (Find-SetupStick with the launcher recorded in the state)
      -Now        the clock
      -Sleep      waits the given milliseconds
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][hashtable]$Verdict,
    [Parameter(Mandatory)][string]$ReportPath,
    [scriptblock]$ReadKey = { if ([Console]::KeyAvailable) { [Console]::ReadKey($true).Key.ToString() } },
    [scriptblock]$SetColor = { param($background, $foreground) $Host.UI.RawUI.BackgroundColor = $background; $Host.UI.RawUI.ForegroundColor = $foreground },
    [scriptblock]$ResetColor = { [Console]::ResetColor() },
    [scriptblock]$Write = { param($lines, $foreground, $background) Write-ConsoleFrame -Lines $lines -Writer (New-ConsoleWriter) -Foreground $foreground -Background $background },
    [scriptblock]$Launch = {
      param($target, $arguments)
      if ([string]::IsNullOrEmpty($arguments)) { Start-Process -FilePath $target }
      else { Start-Process -FilePath $target -ArgumentList $arguments }
    },
    [scriptblock]$FlushInput = { while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) } },
    [scriptblock]$Stick = { Find-SetupStick -Launcher $State['Launcher'] },
    [scriptblock]$Now = { Get-Date },
    [scriptblock]$Sleep = { param($ms) Start-Sleep -Milliseconds $ms }
  )

  # The clock runs with this function's own $Now out of the way: PowerShell finds a variable in the
  # callers' scopes, so a caller's `-Now { $now }` would otherwise get this parameter back.
  $clockBlock = $Now
  Remove-Variable -Name Now -Scope Local

  $isChrome = if (Test-ChromeInstalled) { (Get-DefaultBrowserProgId) -eq 'ChromeHTML' } else { $true }
  $colors = Get-VerdictColors -Color ([string]$Verdict['Color'])
  $stickInfo = @{ Root = $null; Drive = $null }
  $stickWarned = $false
  $drawWarned = $false

  # Colours, input flushing, launching, the stick check and drawing are conveniences: a failure there must
  # not stop the screen from showing the AnyDesk ID. $readStick and $draw are dot-sourced, so their
  # assignments land in this function's scope.
  $paint = {
    try { $null = & $SetColor $colors.Background $colors.Foreground }
    catch { Write-SetupLog -Message 'Could not set the console colour for the final screen' -Level WARN -Data @{ error = $_.Exception.Message } }
  }
  $open = {
    param($what, $target, $arguments)
    try { $null = & $Launch $target $arguments }
    catch { Write-SetupLog -Message "Could not open $what from the final screen" -Level WARN -Data @{ error = $_.Exception.Message } }
  }
  $readStick = {
    try {
      $found = & $Stick
      $stickInfo = if ($found -is [hashtable]) { $found } else { @{ Root = $null; Drive = $null } }
    } catch {
      $stickInfo = @{ Root = $null; Drive = $null }
      if (-not $stickWarned) {
        $stickWarned = $true
        Write-SetupLog -Message 'Could not look for the USB stick on the final screen' -Level WARN -Data @{ error = $_.Exception.Message }
      }
    }
  }
  $draw = {
    $lines = @(Format-FinalScreen -State $State -Verdict $Verdict -ReportPath $ReportPath -DefaultBrowserIsChrome $isChrome `
      -Now ([datetime](& $clockBlock)) -StickLine (Format-StickLine -Stick $stickInfo))
    try { $null = & $Write $lines $colors.Foreground $colors.Background }
    catch {
      # The next frame (a second later) clears the window and draws everything again.
      Reset-ConsoleFrame
      if (-not $drawWarned) {
        $drawWarned = $true
        Write-SetupLog -Message 'Could not draw the final screen' -Level WARN -Data @{ error = $_.Exception.Message }
      }
    }
  }

  try {
    & $paint
    . $readStick
    # The first frame clears the whole window in the verdict colour, also when the progress screen's last
    # frame had the same size.
    Reset-ConsoleFrame
    . $draw
    try { $null = & $FlushInput }
    catch { Write-SetupLog -Message 'Could not empty the console key buffer' -Level WARN -Data @{ error = $_.Exception.Message } }

    $lastTick = & $clockBlock
    $sleptMs = 0
    while ($true) {
      $key = [string](& $ReadKey)
      if ($key -eq 'Enter') { return }
      if ($key -eq 'B') {
        & $open 'Default Apps' ('ms-settings:defaultapps?registeredAppMachine=' + [Uri]::EscapeDataString((Get-ChromeRegisteredAppName))) $null
        continue
      }
      if ($key -eq 'R') {
        & $open 'the report' 'notepad.exe' ('"{0}"' -f $ReportPath)
        continue
      }
      # No key, or any other key (ignored): wait a moment, and once a second look for the stick and redraw.
      $null = & $Sleep 100
      $sleptMs += 100
      $current = & $clockBlock
      if ([math]::Max($sleptMs, ($current - $lastTick).TotalMilliseconds) -ge 1000) {
        $lastTick = $current
        $sleptMs = 0
        . $readStick
        . $draw
      }
    }
  } finally {
    try { $null = & $ResetColor }
    catch { Write-SetupLog -Message 'Could not restore the console colour after the final screen' -Level WARN -Data @{ error = $_.Exception.Message } }
  }
}
