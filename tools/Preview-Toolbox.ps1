# tools/Preview-Toolbox.ps1
# Renders the BenTech Toolbox window offscreen to PNG files, for Ben's approval of the look (toolbox spec 4.2, Q25;
# repair spec 12.2) and whenever the look changes. Nothing is shown: the window is parsed, its content is laid out at
# 1000x680 and drawn into a bitmap. The window is never opened and WPF is never stopped.
#
# Loads only pure definitions: the config reader, the log writer, the step catalog, the start screen's helpers
# (New-DefaultChoices, ConvertTo-ScreenText, Format-PreviousRun), the identity helpers, the repair action catalog
# (data only: nothing of it runs) and the Toolbox files. No step, runner or entry file is loaded, nothing is
# installed, nothing is written but the PNGs.
#
# Four views of the setup page for one sample machine (a Dell Latitude 5440 laptop on Windows 11, not fresh, on
# battery, with a YELLOW previous run), so every banner and row is seen:
#   toolbox-en.png, toolbox-he.png        the default profile, in English and in Hebrew
#   toolbox-en-business-desktop.png       the Business profile as a desktop (ScreenConnect reminder, NumLock and
#                                         classic Outlook rows)
#   toolbox-en-blocked.png                Administrator protection on (red banner, Start disabled)
# Seven views of the Repair & diagnostics page for the same Dell (every tile of this version, the setup files there,
# the stick E:), with sample states (the actions are not built yet; nothing runs):
#   repair-en.png, repair-he.png          idle: restart ok, C: 41% free, BitLocker on, internet ok, the disk worn
#                                         (yellow), on charger; Standard repair selected (what it does); a complaint
#   repair-en-blocked.png                 a servicing restart pending, a failing disk (the backed-up switch, not
#                                         ticked), on battery, no stick: only the Health check can start. The reason
#                                         a tile is blocked is its tooltip: the one of Standard repair is drawn as on
#                                         a hover.
#   repair-en-confirm.png                 Network reset's confirmation: one adapter with a static IP, the at-PC
#                                         switch (always asked, ruling RD-R2), YES typed
#   repair-en-running.png,                Standard repair: time sync and disk scan done, DISM at 45%, SFC and WinRE
#   repair-he-running.png                 to come, 12:34 elapsed, the log tail, Stop
#   repair-en-result.png                  Standard repair finished RED (one CRIT, two WARN, one INFO), a restart
#                                         needed, the disk-check offer, the DISM local-source offer whose build
#                                         differs, the files on the stick, Open folder and Restart PC
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
foreach ($file in 'Common\Config', 'Common\Logging', 'Engine\Catalog', 'UI\StartScreen', 'Detect\PcName', 'State\State', 'Repair\ToolEngine', 'Toolbox\Strings',
                  'Toolbox\SetupPlanner', 'Toolbox\RepairPlanner', 'Toolbox\Xaml', 'Toolbox\Toolbox', 'Toolbox\RepairPage') {
  . (Join-Path $repoRoot "src\$file.ps1")
}

$config = Read-SetupConfig -Path (Join-Path $repoRoot 'config\config.json')
$machine = @{
  Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; FriendlyModel = 'Latitude 5440'; Brand = 'DELL'; Serial = '7HX2K93'
  NewName = 'DELL-7HX2K93'; IsLaptop = $true; IsVM = $false; OsBuild = 26200; ComputerName = 'DESKTOP-4F7K2LQ'
}
$previous = @{ StartedAt = '2026-10-20T09:05:00'; Color = 'YELLOW' }
$width = 1000
$height = 680

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# Lays the window's content out at 1000x680 and draws it (and, on top, -Overlay: a tooltip drawn as on a hover) into
# -File under $OutDir. Prints the path.
function Save-PreviewPng($Window, [string]$File, $Overlay = $null) {
  $Window.Width = $width
  $Window.Height = $height
  $content = $Window.Content
  $content.Measure((New-Object System.Windows.Size $width, $height))
  $content.Arrange((New-Object System.Windows.Rect 0, 0, $width, $height))
  $content.UpdateLayout()

  $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $width, $height, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
  $bitmap.Render($content)
  if ($null -ne $Overlay) { $bitmap.Render((& $Overlay $Window)) }
  $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
  $path = Join-Path $OutDir $File
  $stream = [IO.File]::Create($path)
  try { $encoder.Save($stream) } finally { $stream.Dispose() }
  $Window.Close()
  $path
}

# --- The setup page -------------------------------------------------------------------------------------------------

$views = @(
  @{ File = 'toolbox-en.png'; Language = 'en'; Protection = 'Off'; Profile = ''; Mode = '' }
  @{ File = 'toolbox-he.png'; Language = 'he'; Protection = 'Off'; Profile = ''; Mode = '' }
  @{ File = 'toolbox-en-business-desktop.png'; Language = 'en'; Protection = 'Off'; Profile = 'business'; Mode = 'DESKTOP' }
  @{ File = 'toolbox-en-blocked.png'; Language = 'en'; Protection = 'On'; Profile = ''; Mode = '' }
)

foreach ($view in $views) {
  $model = New-ToolboxModel -Machine $machine -Config $config -Previous $previous -IsFresh $false -OnAC $false -AdminProtection $view.Protection
  $model.Language = $view.Language
  if ($view.Profile -ne '') {
    $fill = Get-ProfileChoices -Config $config -ProfileId $view.Profile
    foreach ($key in $fill.Keys) { $model.Choices[$key] = $fill[$key] }
  }
  if ($view.Mode -ne '') { $model.Choices.Mode = $view.Mode }

  $window = New-ToolboxWindow -Model $model -Machine $machine -Config $config -Version '2026.10.21.1' -ReadOnAC { $false }
  Save-PreviewPng $window $view.File
}

# --- The Repair & diagnostics page ---------------------------------------------------------------------------------

function New-PreviewChip([string]$Level, [string[]]$Arguments = @(), [hashtable]$Detail = @{}) { @{ Level = $Level; Args = $Arguments; Detail = $Detail } }

$readyStrip = @{
  Restart = (New-PreviewChip 'ok'); Free = (New-PreviewChip 'ok' @('C:', '41')); BitLocker = (New-PreviewChip 'warn')
  Internet = (New-PreviewChip 'ok'); Disk = (New-PreviewChip 'warn' @() @{ Reasons = @('wear') })
}
$blockedStrip = @{
  Restart = (New-PreviewChip 'crit' @() @{ Signals = @('CbsRebootPending'); Notes = @() }); Free = (New-PreviewChip 'ok' @('C:', '41'))
  BitLocker = (New-PreviewChip 'warn'); Internet = (New-PreviewChip 'ok'); Disk = (New-PreviewChip 'crit' @() @{ Reasons = @('events') })
}
$complaintEn = 'Very slow since the last Windows update, and it shuts down by itself twice a week.'
# Hebrew sample text, written as escapes so this file stays ASCII.
$complaintHe = [regex]::Unescape('\u05d4\u05de\u05d7\u05e9\u05d1 \u05d0\u05d9\u05d8\u05d9 \u05de\u05d0\u05d5\u05d3 \u05de\u05d0\u05d6 \u05d4\u05e2\u05d3\u05db\u05d5\u05df \u05d4\u05d0\u05d7\u05e8\u05d5\u05df \u05e9\u05dc Windows, \u05d5\u05e0\u05db\u05d1\u05d4 \u05dc\u05d1\u05d3 \u05e4\u05e2\u05de\u05d9\u05d9\u05dd \u05d1\u05e9\u05d1\u05d5\u05e2.')

$standardRun = @{
  Action = 'standard'; Current = 2; Percent = 45; ElapsedSeconds = 754; Stopping = $false
  Steps  = @(
    @{ Id = 'timeSync'; Status = 'done'; Percent = $null }
    @{ Id = 'volumeScan'; Status = 'done'; Percent = $null }
    @{ Id = 'dism'; Status = 'running'; Percent = 45 }
    @{ Id = 'sfc'; Status = 'pending'; Percent = $null }
    @{ Id = 'winreFix'; Status = 'pending'; Percent = $null }
  )
  Log    = @('Time sync: w32tm exit 0', 'Clock offset after the sync: 0.4 s', 'Disk scan: ScanNoErrorsFound', 'No servicing restart pending',
             'DISM /RestoreHealth started (limit 150 min)', 'DISM output: logs\dism-1027.txt')
}
$standardResult = @{
  Action = 'standard'; RunId = '20261022-101500-standard'; Outcome = 'Done'; Color = 'RED'
  Steps = @(@{ Id = 'timeSync'; Status = 'warn' }, @{ Id = 'volumeScan'; Status = 'warn' }, @{ Id = 'dism'; Status = 'failed' }, @{ Id = 'sfc'; Status = 'done' }, @{ Id = 'winreFix'; Status = 'done' })
  Findings = @(
    @{ Level = 'WARN'; Code = 'clockOff'; Text = 'The clock is still 4 min off after the time sync: downloads may fail'; Args = @('4') }
    @{ Level = 'CRIT'; Code = 'volumeSpotFix'; Text = 'Disk scan found errors that need a disk check at restart'; Args = @() }
    @{ Level = 'WARN'; Code = 'dismSourceMissing'; Text = 'DISM could not get repair files from Windows Update (0x800F081F)'; Args = @('0x800F081F') }
    @{ Level = 'INFO'; Code = 'winreEnabled'; Text = 'WinRE was turned on'; Args = @() }
  )
  RestartRequired = $true
  Offers = @{ DiskCheck = $true
              DismSource = @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = 6; Edition = 'Professional'; Arch = 'x64'; Languages = @('he-IL')
                              Build = '26100'; BuildDiffers = $true; LanguageDiffers = $false } }
  Files = @{ Folder = 'E:\BenTech-Reports\DESKTOP-4F7K2LQ_7HX2K93_2026-10-22_1015' }
}
$netResetConfirm = @{
  Action = 'netReset'; Kind = 'yes'; Typed = 'YES'; AtPc = $true; Loading = $false
  Lines = @(@{ Key = 'tile.netReset.changes' }, @{ Key = 'confirm.static'; Args = @('Ethernet', '192.168.1.10/24, gateway 192.168.1.1, DNS 8.8.8.8, 8.8.4.4') })
  Remote = @{ Rdp = $false }; Items = @(); Options = @{}
}

# The tooltip of a disabled tile, drawn below it as Windows shows it on a hover (the window's own ToolTip style).
$tileTip = {
  param($w)
  $tile = $w.FindName('TileStandard')
  $at = $tile.TranslatePoint((New-Object System.Windows.Point 60, $tile.ActualHeight), $w.Content)
  $text = New-Object System.Windows.Controls.TextBlock
  $text.Style = $w.FindResource('TipTextStyle')
  $text.Text = $tile.ToolTip.Text
  $tip = New-Object System.Windows.Controls.ToolTip
  $tip.Style = $w.FindResource([System.Windows.Controls.ToolTip])
  $tip.Content = $text
  $tip.Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
  $tip.Arrange((New-Object System.Windows.Rect ($at.X), ($at.Y + 4), $tip.DesiredSize.Width, $tip.DesiredSize.Height))
  $tip.UpdateLayout()
  $tip
}

$repairViews = @(
  @{ File = 'repair-en.png'; Language = 'en'; OnAC = $true; Strip = $readyStrip; Stick = $true; Selected = 'standard'; Complaint = $complaintEn }
  @{ File = 'repair-he.png'; Language = 'he'; OnAC = $true; Strip = $readyStrip; Stick = $true; Selected = 'standard'; Complaint = $complaintHe }
  @{ File = 'repair-en-blocked.png'; Language = 'en'; OnAC = $false; Strip = $blockedStrip; Stick = $false; Selected = 'health'; Complaint = ''; Overlay = $tileTip }
  @{ File = 'repair-en-confirm.png'; Language = 'en'; OnAC = $true; Strip = $readyStrip; Stick = $true; Selected = 'netReset'; Complaint = $complaintEn; Confirm = $netResetConfirm }
  @{ File = 'repair-en-running.png'; Language = 'en'; OnAC = $true; Strip = $readyStrip; Stick = $true; Selected = 'standard'; Complaint = $complaintEn; Run = $standardRun }
  @{ File = 'repair-he-running.png'; Language = 'he'; OnAC = $true; Strip = $readyStrip; Stick = $true; Selected = 'standard'; Complaint = $complaintHe; Run = $standardRun }
  @{ File = 'repair-en-result.png'; Language = 'en'; OnAC = $true; Strip = $readyStrip; Stick = $true; Selected = 'standard'; Complaint = $complaintEn; Result = $standardResult }
)

foreach ($view in $repairViews) {
  $model = New-ToolboxModel -Machine $machine -Config $config -Previous $previous -IsFresh $false -OnAC $view.OnAC -AdminProtection 'Off'
  $model.Language = $view.Language
  $model.Page = 'repair'
  $repair = $model.Repair
  $repair.CanRun = $true
  $repair.Available = [string[]](@($script:RepairTileRows.Values | ForEach-Object { $_ }) + @('netRestore', 'dismSource'))
  $repair.Strip = ConvertTo-RepairStrip -Chips $view.Strip -Final $true
  $repair.Stick = $(if ($view.Stick) { @{ Root = 'E:\'; Drive = 'E:' } } else { @{ Root = $null; Drive = $null } })
  $repair.Selected = $view.Selected
  $repair.Complaint = $view.Complaint
  foreach ($key in 'Confirm', 'Run', 'Result') { if ($view.ContainsKey($key)) { $repair[$key] = $view[$key] } }

  $window = New-ToolboxWindow -Model $model -Machine $machine -Config $config -Version '2026.10.22.1' -ReadOnAC { $true }
  # What the technician typed: the view never writes these boxes.
  $window.FindName('ComplaintBox').Text = $view.Complaint
  if ($view.ContainsKey('Confirm')) { $window.FindName('YesBox').Text = [string]$view.Confirm.Typed }
  Save-PreviewPng $window $view.File $view['Overlay']
}
