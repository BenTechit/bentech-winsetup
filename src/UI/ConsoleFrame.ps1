# src/UI/ConsoleFrame.ps1
# Flicker-free screen drawing through the [Console] class (v2 spec 4.2, 9.1). Needs Logging.ps1.
#
# The v2 screens never use Write-Host or Clear-Host: the transcript records every Write-Host, and a
# Clear-Host every second flickers. Instead a frame is drawn row by row over the old one, each row padded
# to the window width, and the window is cleared only when its size changed.
#
# New-ConsoleWriter is the only drawing code that touches [Console]; everything else takes the writer
# (a hashtable of four script blocks) as a parameter, so the tests pass a fake one. Resize-SetupConsole
# also reads and sets the window size through [Console].

$script:ConsoleFrameLastSize = $null

function New-ConsoleWriter {
  <#
  .SYNOPSIS
    The production writer: @{ GetSize; Clear; MoveTo; Write } over [Console].
  .DESCRIPTION
    GetSize           -> @{ Width; Height; Top } of the visible window.
    Clear $background -> the whole window in that colour.
    MoveTo $row       -> the cursor to column 0 of that buffer row.
    Write $text $foreground $background -> the text in exactly those two colours (spec 9.1: every write
                         names both), then the console's own colours again.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  return @{
    GetSize = { @{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight; Top = [Console]::WindowTop } }
    Clear   = { param($background) [Console]::BackgroundColor = $background; [Console]::Clear() }
    MoveTo  = { param($row) [Console]::SetCursorPosition(0, $row) }
    Write   = {
      param($text, $foreground, $background)
      [Console]::ForegroundColor = $foreground
      [Console]::BackgroundColor = $background
      [Console]::Write($text)
      [Console]::ResetColor()
    }
  }
}

function ConvertTo-ConsoleFrame {
  <#
  .SYNOPSIS
    Exactly Height rows of exactly Width characters: each line padded with spaces or cut, missing rows
    blank, extra lines dropped. Pure. Rows are emitted one by one: wrap the call in @().
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
    [Parameter(Mandatory)][int]$Width,
    [Parameter(Mandatory)][int]$Height
  )

  $w = [math]::Max(0, $Width)
  for ($r = 0; $r -lt $Height; $r++) {
    $text = ''
    if ($r -lt $Lines.Count -and $null -ne $Lines[$r]) { $text = [string]$Lines[$r] }
    if ($text.Length -gt $w) { $text.Substring(0, $w) } else { $text.PadRight($w) }
  }
}

function Reset-ConsoleFrame {
  # Forgets the last frame's size, so the next Write-ConsoleFrame clears the window first.
  [CmdletBinding()]
  param()

  $script:ConsoleFrameLastSize = $null
}

function Write-ConsoleFrame {
  <#
  .SYNOPSIS
    Draws the lines over the visible window through -Writer, without flicker.
  .DESCRIPTION
    Reads the window size, clears the window in -Background only when its width or height differs from
    the last frame (or after Reset-ConsoleFrame), then writes Height - 1 rows of Width - 1 characters
    from the window's top row: never the last column or row, so nothing wraps and nothing scrolls. Every
    row is written in full, so the rows of the previous frame disappear. The cursor is parked on the last
    row.

    -Colorize turns one row into segments @{ Text; Color; Background } (both colours optional); a
    segment without Color is written in -Foreground, one without Background in -Background, so every
    write names both colours (spec 9.1). Without -Colorize a row is one segment.

    A writer that throws is not caught here: the caller (the tick) logs it, and the next frame clears.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
    [Parameter(Mandatory)][hashtable]$Writer,
    [scriptblock]$Colorize,
    [string]$Foreground = 'Gray',
    [string]$Background = 'Black'
  )

  $size = & $Writer['GetSize']
  $width = [int]$size.Width
  $height = [int]$size.Height
  $top = [int]$size.Top

  $sizeKey = '{0}x{1}' -f $width, $height
  if ($script:ConsoleFrameLastSize -ne $sizeKey) {
    $null = & $Writer['Clear'] $Background
    $script:ConsoleFrameLastSize = $sizeKey
  }

  $rows = @(ConvertTo-ConsoleFrame -Lines $Lines -Width ($width - 1) -Height ($height - 1))
  for ($r = 0; $r -lt $rows.Count; $r++) {
    $null = & $Writer['MoveTo'] ($top + $r)
    $segments = @()
    if ($null -ne $Colorize) { $segments = @(& $Colorize $rows[$r]) }
    if ($segments.Count -eq 0) { $segments = @(@{ Text = $rows[$r] }) }
    foreach ($segment in $segments) {
      $text = [string]$segment.Text
      if ($text.Length -eq 0) { continue }
      $fore = if ($segment.Color) { [string]$segment.Color } else { $Foreground }
      $back = if ($segment.Background) { [string]$segment.Background } else { $Background }
      $null = & $Writer['Write'] $text $fore $back
    }
  }
  $null = & $Writer['MoveTo'] ($top + $height - 1)
}

function Get-ConsoleTargetSize {
  <#
  .SYNOPSIS
    The window and buffer size to ask for (spec 4.2: about 100 x 45, within the screen). Pure.
  .DESCRIPTION
    Per axis: window = max(current window, min(wanted, largest the screen allows)); buffer = max(current
    buffer, window). Nothing ever shrinks, and the buffer is never smaller than the window.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Current,
    [Parameter(Mandatory)][hashtable]$Largest,
    [int]$WantedWidth = 100,
    [int]$WantedHeight = 45
  )

  $windowWidth = [math]::Max([int]$Current['Width'], [math]::Min($WantedWidth, [int]$Largest['Width']))
  $windowHeight = [math]::Max([int]$Current['Height'], [math]::Min($WantedHeight, [int]$Largest['Height']))
  return @{
    WindowWidth  = $windowWidth
    WindowHeight = $windowHeight
    BufferWidth  = [math]::Max([int]$Current['BufferWidth'], $windowWidth)
    BufferHeight = [math]::Max([int]$Current['BufferHeight'], $windowHeight)
  }
}

function Resize-SetupConsole {
  <#
  .SYNOPSIS
    Tries to enlarge the console window to about 100 x 45 (Get-ConsoleTargetSize). $true when the
    console accepted the size (or already had it), $false when it refused. Never throws.
  .DESCRIPTION
    The buffer grows first (a window cannot be larger than its buffer), then the window; a call that
    would change nothing is left out. Windows Terminal, the default console on many Windows 11 machines,
    refuses: that is logged at INFO, since the screen fits whatever size it gets.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  try {
    $current = @{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight; BufferWidth = [Console]::BufferWidth; BufferHeight = [Console]::BufferHeight }
    $largest = @{ Width = [Console]::LargestWindowWidth; Height = [Console]::LargestWindowHeight }
    $target = Get-ConsoleTargetSize -Current $current -Largest $largest
    if ($target.BufferWidth -ne $current.BufferWidth -or $target.BufferHeight -ne $current.BufferHeight) {
      [Console]::SetBufferSize($target.BufferWidth, $target.BufferHeight)
    }
    if ($target.WindowWidth -ne $current.Width -or $target.WindowHeight -ne $current.Height) {
      [Console]::SetWindowSize($target.WindowWidth, $target.WindowHeight)
    }
    return $true
  } catch {
    Write-SetupLog -Level INFO -Message 'Could not resize the console window; the screen fits the size it has' -Data @{ error = $_.Exception.Message }
    return $false
  }
}
