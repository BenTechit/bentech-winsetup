# src/UI/FinalScreen.ps1
# The final screen (spec 8.6): the whole console turns green, yellow or red, the AnyDesk ID is shown
# in big digits (Ben reads it from across the room) and the screen waits for a key.
#
# Format-BigDigits and Format-FinalScreen are pure. Show-FinalScreen reaches the console, the keyboard
# and the launcher only through injectable script blocks with production defaults, so the tests drive
# it with a scripted key sequence. Uses ConvertTo-ScreenText, Limit-ScreenLine, ConvertFrom-StateTime
# and Format-HoursMinutes from StartScreen.ps1, and the default-browser helpers from
# DefaultBrowser.ps1 and Apps.ps1.

$script:FinalScreenWidth = 80
$script:FinalMaxFailures = 5
$script:FinalMaxNotes = 4

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
    browser, and the report line. The total time runs from State.StartedAt to State.EndedAt, or to
    -Now while the run has no end time. At most 5 failures and 4 notes are listed (then "... and N
    more"), and each is cut to 79 columns.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][hashtable]$Verdict,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][bool]$DefaultBrowserIsChrome,
    [datetime]$Now = (Get-Date)
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

  if (-not $DefaultBrowserIsChrome) {
    $lines.Add('')
    $lines.Add("  Chrome is not the default browser: press B to open Default Apps, then click 'Set default'")
  }
  $lines.Add('')
  $lines.Add(('  Report: {0}   [R] open report   [any other key] close' -f $ReportPath))

  return $lines.ToArray()
}

function Show-FinalScreen {
  <#
  .SYNOPSIS
    Paints the console green / yellow / red, draws the final screen and waits for a key.
  .DESCRIPTION
    B opens Settings > Default apps for Chrome, R opens the report in Notepad; both keep the screen
    up. Any other key returns. The Chrome hint is left out when Chrome is the default browser or is
    not installed. Keys already waiting in the console buffer are thrown away first, so a stray key
    pressed during the last step cannot close the screen before anyone has read the AnyDesk ID. The
    console colour is put back when the screen closes, also when something throws.

    The seams (production defaults shown):
      -ReadKey    waits for a key and returns its [ConsoleKey] name (nothing = treated as "any key")
      -SetColor   sets the console background to a colour name
      -ResetColor puts the console colours back (runs when the screen closes, also after an error)
      -Write      clears and draws the lines
      -Launch     starts a program or opens a URI: param($target, $arguments)
      -FlushInput throws away waiting key presses
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][hashtable]$Verdict,
    [Parameter(Mandatory)][string]$ReportPath,
    [scriptblock]$ReadKey = { [Console]::ReadKey($true).Key.ToString() },
    [scriptblock]$SetColor = { param($c) $Host.UI.RawUI.BackgroundColor = $c },
    [scriptblock]$ResetColor = { [Console]::ResetColor() },
    [scriptblock]$Write = { param($lines) Clear-Host; $lines | ForEach-Object { Write-Host $_ -ForegroundColor White } },
    [scriptblock]$Launch = {
      param($target, $arguments)
      if ([string]::IsNullOrEmpty($arguments)) { Start-Process -FilePath $target }
      else { Start-Process -FilePath $target -ArgumentList $arguments }
    },
    [scriptblock]$FlushInput = { while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) } }
  )

  $isChrome = if (Test-ChromeInstalled) { (Get-DefaultBrowserProgId) -eq 'ChromeHTML' } else { $true }
  $background = switch ([string]$Verdict['Color']) {
    'GREEN'  { 'DarkGreen' }
    'YELLOW' { 'DarkYellow' }
    default  { 'DarkRed' }   # RED, and anything unexpected: never look green by accident
  }
  $lines = @(Format-FinalScreen -State $State -Verdict $Verdict -ReportPath $ReportPath -DefaultBrowserIsChrome $isChrome)

  # Colours, input flushing and launching are conveniences: a failure there must not stop the
  # screen from showing the AnyDesk ID.
  $paint = {
    param($color)
    try { $null = & $SetColor $color }
    catch { Write-SetupLog -Message 'Could not set the console colour for the final screen' -Level WARN -Data @{ error = $_.Exception.Message } }
  }
  $open = {
    param($what, $target, $arguments)
    try { $null = & $Launch $target $arguments }
    catch { Write-SetupLog -Message "Could not open $what from the final screen" -Level WARN -Data @{ error = $_.Exception.Message } }
  }

  try {
    & $paint $background
    $null = & $Write $lines
    try { $null = & $FlushInput }
    catch { Write-SetupLog -Message 'Could not empty the console key buffer' -Level WARN -Data @{ error = $_.Exception.Message } }

    while ($true) {
      $key = [string](& $ReadKey)
      if ($key -eq 'B') {
        & $open 'Default Apps' ('ms-settings:defaultapps?registeredAppMachine=' + [Uri]::EscapeDataString((Get-ChromeRegisteredAppName))) $null
        continue
      }
      if ($key -eq 'R') {
        & $open 'the report' 'notepad.exe' ('"{0}"' -f $ReportPath)
        continue
      }
      return
    }
  } finally {
    try { $null = & $ResetColor }
    catch { Write-SetupLog -Message 'Could not restore the console colour after the final screen' -Level WARN -Data @{ error = $_.Exception.Message } }
  }
}
