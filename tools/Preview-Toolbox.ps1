# tools/Preview-Toolbox.ps1
# Renders the BenTech Toolbox window offscreen to PNG files, for Ben's approval of the look (toolbox spec 4.2, Q25)
# and whenever the look changes. Nothing is shown: the window is parsed, its content is laid out at 1000x680 and
# drawn into a bitmap. The window is never opened and WPF is never stopped.
#
# Loads only pure definitions: the config reader, the log writer, the step catalog, the start screen's helpers
# (New-DefaultChoices, ConvertTo-ScreenText, Format-PreviousRun) and the four Toolbox files. No step, runner or
# entry file is loaded, nothing is installed, nothing is written but the PNGs.
#
# Six views of one sample machine (a Dell Latitude 5440 laptop on Windows 11, not fresh, on battery, with a
# YELLOW previous run), so every banner and row is seen:
#   toolbox-en.png, toolbox-he.png        the default profile, in English and in Hebrew
#   toolbox-en-business-desktop.png       the Business profile as a desktop (ScreenConnect reminder, NumLock and
#                                         classic Outlook rows)
#   toolbox-en-blocked.png                Administrator protection on (red banner, Start disabled)
#   toolbox-en-drivers.png,               the default profile with UPDATES on Drivers only, in English and in Hebrew
#   toolbox-he-drivers.png                (the tile, and the plan's "Windows Update (drivers only)"; wu spec 3.1)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Preview-Toolbox.ps1 [-OutDir <folder>]
# The default folder is dist\toolbox-preview (dist\ is git-ignored). Prints each PNG's path.
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'

# Script-relative defaults are resolved here, not in the param block: $PSScriptRoot is empty in the param
# defaults of a [CmdletBinding()] script on Windows PowerShell 5.1.
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $repoRoot 'dist\toolbox-preview' }
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
foreach ($file in 'Common\Config', 'Common\Logging', 'Engine\Catalog', 'UI\StartScreen', 'Toolbox\Strings', 'Toolbox\SetupPlanner', 'Toolbox\Xaml', 'Toolbox\Toolbox') {
  . (Join-Path $repoRoot "src\$file.ps1")
}

$config = Read-SetupConfig -Path (Join-Path $repoRoot 'config\config.json')
$machine = @{
  Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; FriendlyModel = 'Latitude 5440'; Brand = 'DELL'; Serial = '7HX2K93'
  NewName = 'DELL-7HX2K93'; IsLaptop = $true; IsVM = $false; OsBuild = 26200
}
$previous = @{ StartedAt = '2026-10-20T09:05:00'; Color = 'YELLOW' }
$width = 1000
$height = 680

$views = @(
  @{ File = 'toolbox-en.png'; Language = 'en'; Protection = 'Off'; Profile = ''; Mode = ''; Updates = '' }
  @{ File = 'toolbox-he.png'; Language = 'he'; Protection = 'Off'; Profile = ''; Mode = ''; Updates = '' }
  @{ File = 'toolbox-en-business-desktop.png'; Language = 'en'; Protection = 'Off'; Profile = 'business'; Mode = 'DESKTOP'; Updates = '' }
  @{ File = 'toolbox-en-blocked.png'; Language = 'en'; Protection = 'On'; Profile = ''; Mode = ''; Updates = '' }
  @{ File = 'toolbox-en-drivers.png'; Language = 'en'; Protection = 'Off'; Profile = ''; Mode = ''; Updates = 'DRIVERS' }
  @{ File = 'toolbox-he-drivers.png'; Language = 'he'; Protection = 'Off'; Profile = ''; Mode = ''; Updates = 'DRIVERS' }
)

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

foreach ($view in $views) {
  $model = New-ToolboxModel -Machine $machine -Config $config -Previous $previous -IsFresh $false -OnAC $false -AdminProtection $view.Protection
  $model.Language = $view.Language
  if ($view.Profile -ne '') {
    $fill = Get-ProfileChoices -Config $config -ProfileId $view.Profile
    foreach ($key in $fill.Keys) { $model.Choices[$key] = $fill[$key] }
  }
  if ($view.Mode -ne '') { $model.Choices.Mode = $view.Mode }
  if ($view.Updates -ne '') { $model.Choices.WindowsUpdate = $view.Updates }

  $window = New-ToolboxWindow -Model $model -Machine $machine -Config $config -Version '2026.10.21.1' -ReadOnAC { $false }
  $window.Width = $width
  $window.Height = $height
  $content = $window.Content
  $content.Measure((New-Object System.Windows.Size $width, $height))
  $content.Arrange((New-Object System.Windows.Rect 0, 0, $width, $height))
  $content.UpdateLayout()

  $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $width, $height, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
  $bitmap.Render($content)
  $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
  $path = Join-Path $OutDir $view.File
  $stream = [IO.File]::Create($path)
  try { $encoder.Save($stream) } finally { $stream.Dispose() }
  $window.Close()
  $path
}
