# tests/Toolbox.Tests.ps1
# BenTech Toolbox, Task 2: the window's look (toolbox spec 4.1-4.3): the XAML, the string table, the view and the
# preview tool.
#
# SAFETY: the window is only parsed, never shown. No ShowDialog, no Dispatcher.InvokeShutdown (it would stop WPF
# for the rest of the test run), no registry, no CIM: the model gets its power and Administrator-protection values
# as plain arguments. The preview tool writes its PNGs only into $TestDrive.
BeforeAll {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
  foreach ($f in 'Common\Config', 'Common\Logging', 'Common\Activity', 'Detect\Detection', 'Engine\Catalog', 'UI\StartScreen',
                 'Toolbox\Strings', 'Toolbox\SetupPlanner', 'Toolbox\Toolbox') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  # The Dell sample machine of tools\Preview-Toolbox.ps1.
  $script:m = @{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; FriendlyModel = 'Latitude 5440'; Serial = '7HX2K93'; NewName = 'DELL-7HX2K93'
                 Brand = 'DELL'; IsLaptop = $true; IsVM = $false; OsBuild = 26200 }

  # A window on a model from New-ToolboxModel (not fresh, on AC): each $Set key goes into Model.Choices, Language
  # into the Model itself.
  function New-TestWindow([hashtable]$Set = @{}, [string]$Protection = 'Off') {
    $model = New-ToolboxModel -Machine $script:m -Config $script:cfg -IsFresh $false -OnAC $true -AdminProtection $Protection
    foreach ($key in $Set.Keys) { if ($key -eq 'Language') { $model.Language = $Set[$key] } else { $model.Choices[$key] = $Set[$key] } }
    New-ToolboxWindow -Model $model -Machine $script:m -Config $script:cfg -Version '2026.10.21.1'
  }
}
Describe 'the toolbox look (toolbox spec 4.1-4.3)' {
  It 'New-ToolboxWindow returns exactly one Window and the view returns nothing (Review Focus 2)' {
    $r = @(New-TestWindow); $r.Count | Should -Be 1; $r[0] | Should -BeOfType [Windows.Window]; @(Update-ToolboxView -Window $r[0]).Count | Should -Be 0 }
  It 'has every named element, the size, the fonts and no default or cancel button' {
    $w = New-TestWindow
    foreach ($n in 'RootBorder','TitleBar','LangEn','LangHe','CloseButton','NavSetup','ContentScroll','MachineModel','MachineSerial','MachineNewName','MachinePower',
      'WarnPanel','WarnText','AdminBanner','ProfilePanel','TypeLaptop','TypeDesktop','OfficeCraft','OfficeBusiness','OfficeHome','OfficeOff','RemoteAnyDesk',
      'RemoteScreenConnect','RemoteBoth','ScreenConnectWarn','SevenZipSwitch','TweakPanel','RestoreSwitch','PlanList','StartButton','CancelButton') { $w.FindName($n) | Should -Not -BeNullOrEmpty -Because $n }
    $w.Width | Should -Be 1000; $w.Height | Should -Be 680; $w.Topmost | Should -BeTrue; $w.WindowStyle | Should -Be 'None'; $w.FontFamily.Source | Should -Be 'Segoe UI'
    $s = $w.FindName('StartButton'); $s.IsDefault | Should -BeFalse; $s.Focusable | Should -BeFalse
    foreach ($b in 'StartButton','CancelButton','CloseButton') { $w.FindName($b).IsCancel | Should -BeFalse }
    $w.InputBindings.Count | Should -Be 0 }
  It 'keeps colours as hex values in one resource dictionary, and uses no image or download' {
    ([regex]::Matches($script:ToolboxXaml, '<Window\.Resources>')).Count | Should -Be 1
    $outside = $script:ToolboxXaml -replace '(?s)<Window\.Resources>.*</Window\.Resources>', ''
    $outside | Should -Not -Match '#[0-9A-Fa-f]{6}'
    foreach ($c in '#1E1E1E', '#252526', '#F0F0F0', '#2D7DD2', '#FFC83D') { $script:ToolboxXaml | Should -Match $c }
    $script:ToolboxXaml | Should -Match 'Segoe Fluent Icons, Segoe MDL2 Assets'; $script:ToolboxXaml | Should -Not -Match '(?i)<Image|Source=|https?:' }
  It 'one profile tile and one tweak row per config entry; the rows follow the rules' {
    $w = New-TestWindow; $t = $w.Tag
    @($t.ProfileTiles.Keys | Sort-Object) | Should -Be @('business', 'clean', 'home'); $t.TweakRows.Count | Should -Be 9
    $t.TweakRows['numLock'].Row.Visibility | Should -Be 'Collapsed'; $t.TweakRows['classicOutlook'].Row.Visibility | Should -Be 'Collapsed'
    $d = New-TestWindow @{ Mode = 'DESKTOP'; Office = 'HOME' }
    $d.Tag.TweakRows['numLock'].Row.Visibility | Should -Be 'Visible'; $d.Tag.TweakRows['numLock'].Switch.IsChecked | Should -BeTrue
    $d.Tag.TweakRows['classicOutlook'].Row.Visibility | Should -Be 'Visible'; $d.Tag.TweakRows['fileExtensions'].Switch.IsChecked | Should -BeFalse }
  It 'every t: key exists in both languages, and both tables have the same keys' {
    $keys = [regex]::Matches($script:ToolboxXaml, 'Tag="t:([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    foreach ($k in $keys) { $script:ToolboxStrings.en.Keys | Should -Contain $k; $script:ToolboxStrings.he.Keys | Should -Contain $k }
    @($script:ToolboxStrings.en.Keys | Sort-Object) | Should -Be @($script:ToolboxStrings.he.Keys | Sort-Object)
    @($script:ToolboxStrings.he.Values | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 0 }
  It 'Hebrew turns the window right-to-left and keeps machine values and the plan left-to-right' {
    $w = New-TestWindow @{ Language = 'he' }
    $w.FlowDirection | Should -Be 'RightToLeft'
    foreach ($n in 'MachineModel', 'MachineSerial', 'MachineNewName') { $w.FindName($n).FlowDirection | Should -Be 'LeftToRight' }
    @($w.FindName('PlanList').Children | Where-Object { $_.FlowDirection -ne 'LeftToRight' }).Count | Should -Be 0
    @($w.FindName('PlanList').Children)[0].Text | Should -BeExactly ' 1  Prepare machine'
    $w.Tag.TweakRows['accessKeys'].Row.ToolTip.Text | Should -Match '[א-ת]' }
  It 'shows the warnings, the ScreenConnect reminder and the Administrator-protection banner' {
    $w = New-TestWindow @{ Remote = 'BOTH' }
    $w.FindName('WarnText').Text | Should -Match 'older than 14 days'; $w.FindName('ScreenConnectWarn').Visibility | Should -Be 'Visible'
    $w.FindName('AdminBanner').Visibility | Should -Be 'Collapsed'; $w.FindName('StartButton').IsEnabled | Should -BeTrue
    $b = New-TestWindow -Protection 'On'; $b.FindName('AdminBanner').Visibility | Should -Be 'Visible'; $b.FindName('StartButton').IsEnabled | Should -BeFalse }
}
Describe 'tools\Preview-Toolbox.ps1' {
  It 'renders the four PNGs at 1000x680 without showing a window' {
    $out = Join-Path $TestDrive 'preview'; & "$PSScriptRoot\..\tools\Preview-Toolbox.ps1" -OutDir $out | Out-Null
    foreach ($f in 'toolbox-en.png', 'toolbox-he.png', 'toolbox-en-business-desktop.png', 'toolbox-en-blocked.png') {
      $s = [IO.File]::OpenRead((Join-Path $out $f))
      try { $frame = [Windows.Media.Imaging.BitmapDecoder]::Create($s, 'None', 'OnLoad').Frames[0]; $frame.PixelWidth | Should -Be 1000; $frame.PixelHeight | Should -Be 680 }
      finally { $s.Dispose() } } }
  It 'never shows or shuts down WPF' { $t = Get-Content "$PSScriptRoot\..\tools\Preview-Toolbox.ps1" -Raw; $t | Should -Not -Match 'ShowDialog|InvokeShutdown|\.Show\(' }
}
