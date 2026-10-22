# tests/Toolbox.Tests.ps1
# BenTech Toolbox, Task 2: the window's look (toolbox spec 4.1-4.3): the XAML, the string table, the view and the
# preview tool. Task 3: the window's logic (toolbox spec 4.1, 5.1): the handlers, the actions, Start / Cancel /
# Failed, the dispatcher backstop, the power timer, the work-area clamp and Show-ToolboxWindow's seams.
#
# SAFETY: the window is only parsed, never shown. No ShowDialog (Show-ToolboxWindow always gets a -ShowDialog
# seam), no Dispatcher.InvokeShutdown (it would stop WPF for the rest of the test run), no registry, no CIM: the
# model gets its power and Administrator-protection values as plain arguments or seams. Events are raised in code
# (RaiseEvent) and Close() is called on never-shown windows, which is safe. The preview tool writes its PNGs only
# into $TestDrive.
BeforeAll {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
  foreach ($f in 'Common\Config', 'Common\Logging', 'Common\Activity', 'Detect\Detection', 'Engine\Catalog', 'UI\StartScreen',
                 'Toolbox\Strings', 'Toolbox\SetupPlanner', 'Toolbox\Xaml', 'Toolbox\Toolbox') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  # The Dell sample machine of tools\Preview-Toolbox.ps1.
  $script:m = @{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; FriendlyModel = 'Latitude 5440'; Serial = '7HX2K93'; NewName = 'DELL-7HX2K93'
                 Brand = 'DELL'; IsLaptop = $true; IsVM = $false; OsBuild = 26200 }

  # A window on a model from New-ToolboxModel (not fresh, on AC unless -OnAC $false, no previous run unless
  # -Previous): each $Set key goes into Model.Choices, Language into the Model itself.
  function New-TestWindow([hashtable]$Set = @{}, [string]$Protection = 'Off', [hashtable]$Previous = $null, [bool]$OnAC = $true, [bool]$IsFresh = $false) {
    $model = New-ToolboxModel -Machine $script:m -Config $script:cfg -Previous $Previous -IsFresh $IsFresh -OnAC $OnAC -AdminProtection $Protection
    foreach ($key in $Set.Keys) { if ($key -eq 'Language') { $model.Language = $Set[$key] } else { $model.Choices[$key] = $Set[$key] } }
    New-ToolboxWindow -Model $model -Machine $script:m -Config $script:cfg -Version '2026.10.21.1'
  }

  # Lays the window's content out offscreen at a size (what a clamped window would show); nothing is shown.
  function Set-TestLayout($w, [double]$Width, [double]$Height) {
    $w.Content.Measure((New-Object Windows.Size $Width, $Height)); $w.Content.Arrange((New-Object Windows.Rect 0, 0, $Width, $Height)); $w.Content.UpdateLayout()
  }

  # Task 3: a click raised in code (a disabled button still runs its handler), on a named element or on the first
  # logical descendant with a Tag (the generated tiles and switches); a window with its handlers.
  function Click($w, [string]$Name) { $w.FindName($Name).RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
  function Find-Tagged($w, [string]$Tag) {
    $pending = New-Object Collections.Stack; $pending.Push($w)
    while ($pending.Count -gt 0) {
      $node = $pending.Pop()
      if ($node -is [Windows.FrameworkElement] -and $node.Tag -is [string] -and $node.Tag -ceq $Tag) { return $node }
      foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($node)) { if ($child -is [Windows.DependencyObject]) { $pending.Push($child) } }
    }
    throw "no element tagged $Tag"
  }
  function ClickTag($w, [string]$Tag) { (Find-Tagged $w $Tag).RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
  function New-LiveWindow([hashtable]$Set = @{}) { $w = New-TestWindow $Set; Register-ToolboxHandlers -Window $w; $w }
  # One wheel notch over the first plan row, as WPF input raises it: PreviewMouseWheel (tunnelling), then
  # MouseWheel (bubbling) unless the preview was handled. Then a layout pass applies the scroll.
  function Send-Wheel($w, [int]$Delta) {
    $target = $w.FindName('PlanList').Children[0]
    $preview = New-Object Windows.Input.MouseWheelEventArgs ([Windows.Input.Mouse]::PrimaryDevice, 0, $Delta)
    $preview.RoutedEvent = [Windows.UIElement]::PreviewMouseWheelEvent; $target.RaiseEvent($preview)
    if (-not $preview.Handled) {
      $bubble = New-Object Windows.Input.MouseWheelEventArgs ([Windows.Input.Mouse]::PrimaryDevice, 0, $Delta)
      $bubble.RoutedEvent = [Windows.UIElement]::MouseWheelEvent; $target.RaiseEvent($bubble)
    }
    $w.Content.UpdateLayout()
  }
  # Every Describe's BeforeEach (Pester 6 has no root BeforeEach): setup.log goes to $script:logs, and the power
  # state is never read for real.
  function Set-ToolboxTestMocks {
    $script:logs = New-Object Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    Mock Test-OnACPower { $true }
  }
}
Describe 'the toolbox look (toolbox spec 4.1-4.3)' {
  BeforeEach { Set-ToolboxTestMocks }
  It 'New-ToolboxWindow returns exactly one Window and the view returns nothing (Review Focus 2)' {
    $r = @(New-TestWindow); $r.Count | Should -Be 1; $r[0] | Should -BeOfType [Windows.Window]; @(Update-ToolboxView -Window $r[0]).Count | Should -Be 0 }
  It 'has every named element, the size, the fonts and no default or cancel button' {
    $w = New-TestWindow
    foreach ($n in 'RootBorder','TitleBar','LangEn','LangHe','CloseButton','NavSetup','ContentScroll','MachineModel','MachineSerial','MachineNewName','MachinePower',
      'WarnPanel','WarnText','AdminBanner','ProfilePanel','TypeLaptop','TypeDesktop','OfficeCraft','OfficeBusiness','OfficeHome','OfficeOff','RemoteAnyDesk',
      'RemoteScreenConnect','RemoteBoth','ScreenConnectWarn','UpdatesFull','UpdatesDrivers','SevenZipSwitch','TweakPanel','RestoreSwitch','PlanList','StartButton','CancelButton') { $w.FindName($n) | Should -Not -BeNullOrEmpty -Because $n }
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
  It 'Hebrew turns the window right-to-left, keeps machine values left-to-right and names the steps in Hebrew (TB-R5)' {
    $w = New-TestWindow @{ Language = 'he' }
    $w.FlowDirection | Should -Be 'RightToLeft'
    foreach ($n in 'MachineModel', 'MachineSerial', 'MachineNewName') { $w.FindName($n).FlowDirection | Should -Be 'LeftToRight' }
    $rows = @($w.FindName('PlanList').Children)
    @($rows | Where-Object { $_.FlowDirection -ne 'RightToLeft' }).Count | Should -Be 0
    $rows[0].Text | Should -BeExactly (' 1  ' + $script:ToolboxStrings.he['step.prepare']); $rows[0].Text | Should -Match '[א-ת]'
    $rows[-1].Text | Should -Match ('^\d\d  ' + [regex]::Escape($script:ToolboxStrings.he['step.finalize']) + '$')
    $w.Tag.TweakRows['accessKeys'].Row.ToolTip.Text | Should -Match '[א-ת]' }
  It 'English plan rows stay left-to-right with the catalog titles (TB-R5)' {
    $rows = @((New-TestWindow).FindName('PlanList').Children)
    @($rows | Where-Object { $_.FlowDirection -ne 'LeftToRight' }).Count | Should -Be 0
    $rows[0].Text | Should -BeExactly ' 1  Prepare machine'; $rows[-1].Text | Should -Match '^\d\d  Finalize$' }
  It 'every catalog step has a name in both languages, the English one exactly the catalog title (TB-R5)' {
    foreach ($s in $script:StepCatalog) {
      $script:ToolboxStrings.en["step.$($s.Id)"] | Should -BeExactly $s.Title -Because $s.Id
      [string]$script:ToolboxStrings.he["step.$($s.Id)"] | Should -Match '\S' -Because $s.Id }
    $script:ToolboxStrings.he['step.prepare'] | Should -Match '[א-ת]' }
  It 'shows the warnings, the ScreenConnect reminder and the Administrator-protection banner' {
    $w = New-TestWindow @{ Remote = 'BOTH' }
    $w.FindName('WarnText').Text | Should -Match 'older than 14 days'; $w.FindName('ScreenConnectWarn').Visibility | Should -Be 'Visible'
    $w.FindName('AdminBanner').Visibility | Should -Be 'Collapsed'; $w.FindName('StartButton').IsEnabled | Should -BeTrue
    $b = New-TestWindow -Protection 'On'; $b.FindName('AdminBanner').Visibility | Should -Be 'Visible'; $b.FindName('StartButton').IsEnabled | Should -BeFalse }
  It 'one banner line each: the previous run with its date, colour and fallbacks, and the battery (review M3, M7)' {
    $w = New-TestWindow -Previous @{ StartedAt = '2026-10-20T09:05:00'; Color = 'YELLOW' } -OnAC $false
    @($w.FindName('WarnText').Text -split "`n") | Should -Be @('This PC already has user files or is older than 14 days',
      'Previous run: 20/10/2026 09:05 - YELLOW', 'On battery: BIOS updates will be skipped')
    $w.FindName('MachinePower').Text | Should -BeExactly 'On battery'
    (New-TestWindow -Previous @{ StartedAt = 'garbage'; Color = '' }).FindName('WarnText').Text | Should -Match '(?m)^Previous run: unknown date - unfinished$'
    $h = New-TestWindow @{ Language = 'he' } -Previous @{ StartedAt = $null; Color = $null } -OnAC $false
    $lines = @($h.FindName('WarnText').Text -split "`n")
    $lines[1] | Should -BeExactly ('הרצה קודמת: {0} - {1}' -f $script:ToolboxStrings.he['previous.unknownDate'], $script:ToolboxStrings.he['previous.unfinished'])
    $lines[2] | Should -BeExactly $script:ToolboxStrings.he['warn.battery']
    (New-TestWindow).FindName('WarnText').Text | Should -Not -Match 'Previous run|On battery' }
  It 'on a small clamped window every plan step can be scrolled to, and Start stays in the card (review I-1)' {
    $w = New-TestWindow; Set-TestLayout $w 683 512
    $scroll = $w.FindName('PlanScroll'); $rows = @($w.FindName('PlanList').Children)
    $rows[-1].Text | Should -Match 'Finalize$'; $scroll.ScrollableHeight | Should -BeGreaterThan 0
    $scroll.ScrollToBottom(); $w.Content.UpdateLayout()
    $bottom = $rows[-1].TranslatePoint((New-Object Windows.Point 0, $rows[-1].ActualHeight), $scroll).Y
    $bottom | Should -BeGreaterThan 0; $bottom | Should -BeLessOrEqual ($scroll.ViewportHeight + 0.5)
    $start = $w.FindName('StartButton'); ($start.TranslatePoint((New-Object Windows.Point 0, $start.ActualHeight), $w.Content).Y) | Should -BeLessOrEqual 512
    $big = New-TestWindow; Set-TestLayout $big 1000 680; $big.FindName('PlanScroll').ScrollableHeight | Should -Be 0 }   # the default size needs no scrolling
  It 'Get-ToolboxString: a missing key shows the key, Hebrew falls back to English, a bad format returns the text (TB-R7)' {
    $script:ToolboxWarned.Clear()
    $t = @{ en = @{ only = 'English only'; empty = 'English for empty'; arg = 'Hi {0}'; bad = 'Bad {0' }; he = @{ empty = ''; arg = 'Shalom {0}' } }
    Get-ToolboxString -Table $t -Language 'he' -Key 'no.such.key' | Should -BeExactly 'no.such.key'
    Get-ToolboxString -Table $t -Language 'he' -Key 'only' | Should -BeExactly 'English only'
    Get-ToolboxString -Table $t -Language 'he' -Key 'empty' | Should -BeExactly 'English for empty'
    Get-ToolboxString -Table $t -Language 'he' -Key 'arg' -Arguments @('x') | Should -BeExactly 'Shalom x'
    Get-ToolboxString -Table $null -Language 'en' -Key 'only' | Should -BeExactly 'only'
    $script:logs.Count | Should -Be 0
    foreach ($i in 1, 2) { Get-ToolboxString -Table $t -Language 'en' -Key 'bad' -Arguments @('x') | Should -BeExactly 'Bad {0' }
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox text could not be formatted' -and $_.Data.key -eq 'bad' }).Count | Should -Be 1   # once per key, not on every render
    (@($script:logs) | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match '[^\x00-\x7F]' }
  It 'the digit indent is 0, with one WARN, when the font cannot be measured (TB-R7)' {
    $script:ToolboxWarned.Clear(); $w = New-TestWindow
    Get-ToolboxDigitIndent -Window $w -FontSize 13 | Should -BeGreaterThan 0
    foreach ($i in 1, 2) { Get-ToolboxDigitIndent -Window $w -FontSize 0 | Should -Be 0 }
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox plan indent could not be measured' }).Count | Should -Be 1 }
  It 'after HE, a t: TextBlock in the tree holds the Hebrew text; EN brings the English back (TB-R7)' {
    $w = New-LiveWindow; Click $w 'LangHe'
    $label = Find-Tagged $w 't:row.profile'; $label | Should -BeOfType [Windows.Controls.TextBlock]
    $label.Text | Should -BeExactly $script:ToolboxStrings.he['row.profile']; $label.Text | Should -Match '[א-ת]'
    (Find-Tagged $w 't:tweak.accessKeys.title').Text | Should -BeExactly (@(Get-TweakCatalog -Config $cfg) | Where-Object { $_.Id -eq 'accessKeys' }).Title.he
    $w.FindName('LangHe').IsChecked | Should -BeTrue; $w.FindName('LangEn').IsChecked | Should -BeFalse
    Click $w 'LangEn'; $label.Text | Should -BeExactly 'PROFILE'; $w.FlowDirection | Should -Be 'LeftToRight'; $w.FindName('LangEn').IsChecked | Should -BeTrue }
  It 're-renders a changed model: tiles, rows, reminder, banner, Start and plan (TB-R7)' {
    $w = New-TestWindow; @($w.FindName('PlanList').Children).Text -join "`n" | Should -Not -Match 'Microsoft 365'
    $w.Tag.Model.Choices.Office = 'HOME'; $w.Tag.Model.Choices.Remote = 'SCREENCONNECT'; $w.Tag.Model.AdminProtection = 'On'
    Update-ToolboxView -Window $w
    $w.FindName('OfficeHome').IsChecked | Should -BeTrue; $w.FindName('OfficeCraft').IsChecked | Should -BeFalse; $w.FindName('RemoteScreenConnect').IsChecked | Should -BeTrue
    $w.Tag.TweakRows['classicOutlook'].Row.Visibility | Should -Be 'Visible'; $w.FindName('ScreenConnectWarn').Visibility | Should -Be 'Visible'
    $w.FindName('AdminBanner').Visibility | Should -Be 'Visible'; $w.FindName('StartButton').IsEnabled | Should -BeFalse
    (@($w.FindName('PlanList').Children).Text -join "`n") | Should -Match 'Microsoft 365' }
  # The row of a named control: the Grid.Row of its ancestor that is a direct child of the options grid (final wave 6).
  It 'the UPDATES row sits between REMOTE and APPS by Grid.Row, not by text order; Full is checked by default (wu spec 3.1)' {
    $w = New-TestWindow
    $rowOf = { param($name) $e = $w.FindName($name); while ($e.Parent -isnot [Windows.Controls.Grid]) { $e = $e.Parent }; [Windows.Controls.Grid]::GetRow($e) }
    $remote = & $rowOf 'RemoteAnyDesk'; $updates = & $rowOf 'UpdatesFull'; $apps = & $rowOf 'SevenZipSwitch'
    $remote | Should -BeLessThan $updates; $updates | Should -BeLessThan $apps
    (& $rowOf 'RemoteBoth') | Should -Be $remote; (& $rowOf 'UpdatesDrivers') | Should -Be $updates
    $w.FindName('UpdatesFull').IsChecked | Should -BeTrue; $w.FindName('UpdatesDrivers').IsChecked | Should -BeFalse }
  # Final wave 4 (WU-R4): the new 36 px UPDATES row made a one-warning view overflow the 680 px window by 1 px, so
  # it drew a scroll bar for nothing. A view with at most one warning (not fresh, on battery, an earlier run) fits.
  It 'a view with at most one warning fits the 1000 x 680 window: no scroll bar (<N>, <Lang>; WU-R4)' -ForEach @(
    @{ N = 'fresh, on charger, no earlier run'; Fresh = $true; AC = $true; Prev = $false; Lang = 'en' }
    @{ N = 'fresh, on charger, an earlier run'; Fresh = $true; AC = $true; Prev = $true; Lang = 'en' }
    @{ N = 'fresh, on battery'; Fresh = $true; AC = $false; Prev = $false; Lang = 'en' }
    @{ N = 'not fresh, on charger'; Fresh = $false; AC = $true; Prev = $false; Lang = 'en' }
    @{ N = 'fresh, on battery'; Fresh = $true; AC = $false; Prev = $false; Lang = 'he' }
    @{ N = 'not fresh, on charger'; Fresh = $false; AC = $true; Prev = $false; Lang = 'he' }) {
    $wopts = @{ Set = @{ Language = $Lang }; OnAC = $AC; IsFresh = $Fresh }
    if ($Prev) { $wopts.Previous = @{ StartedAt = '2026-10-20T09:05:00'; Color = 'YELLOW' } }
    $w = New-TestWindow @wopts; Set-TestLayout $w 1000 680
    $scroll = $w.FindName('ContentScroll'); $scroll.ViewportHeight | Should -BeGreaterThan 600
    $scroll.ScrollableHeight | Should -Be 0 -Because "the content is $($scroll.ExtentHeight) px high in a $($scroll.ViewportHeight) px viewport"
    $w.Close() }
}
Describe 'the toolbox logic (toolbox spec 4.1, 5.1)' {
  BeforeEach { Set-ToolboxTestMocks }
  It 'a click on Business fills the options, shows the reminder and updates the plan' {
    $w = New-LiveWindow; ClickTag $w 'a:Profile:business'
    $w.Tag.Model.Choices.Office | Should -Be 'BUSINESS'; $w.FindName('OfficeBusiness').IsChecked | Should -BeTrue
    $w.FindName('ScreenConnectWarn').Visibility | Should -Be 'Visible'; (@($w.FindName('PlanList').Children).Text -join "`n") | Should -Match 'Microsoft 365' }
  It 'a tweak switch toggles from the model, not from the control' {
    $w = New-LiveWindow; ClickTag $w 'a:Tweak:fileExtensions'
    $w.Tag.Model.Choices.Tweaks | Should -Contain 'fileExtensions'; $w.Tag.TweakRows['fileExtensions'].Switch.IsChecked | Should -BeTrue
    ClickTag $w 'a:Tweak:fileExtensions'; $w.Tag.Model.Choices.Tweaks | Should -Not -Contain 'fileExtensions' }
  It 'Desktop shows NumLock (on, from the profile); Laptop hides it again' {
    $w = New-LiveWindow; Click $w 'TypeDesktop'; $w.Tag.TweakRows['numLock'].Row.Visibility | Should -Be 'Visible'
    Click $w 'TypeLaptop'; $w.Tag.TweakRows['numLock'].Row.Visibility | Should -Be 'Collapsed' }
  It 'the other options go through the model too; a changed option keeps the profile (spec 5.2)' {
    $w = New-LiveWindow; Click $w 'SevenZipSwitch'; Click $w 'RestoreSwitch'; ClickTag $w 'a:Remote:SCREENCONNECT'; Click $w 'OfficeOff'
    $c = $w.Tag.Model.Choices; $c.SevenZip | Should -BeFalse; $c.RestorePoint | Should -BeFalse; $c.Remote | Should -Be 'SCREENCONNECT'; $c.Office | Should -Be 'OFF'
    $w.FindName('SevenZipSwitch').IsChecked | Should -BeFalse; $w.FindName('RestoreSwitch').IsChecked | Should -BeFalse; $w.FindName('ScreenConnectWarn').Visibility | Should -Be 'Visible'
    $c.Profile | Should -Be 'home'; $w.Tag.ProfileTiles['home'].IsChecked | Should -BeTrue
    (@($w.FindName('PlanList').Children).Text -join "`n") | Should -Not -Match '7-Zip|AnyDesk|Craft' }
  It 'HE switches every tagged text and the direction; the Choices stay ASCII' {
    $w = New-LiveWindow; Click $w 'LangHe'
    $w.FlowDirection | Should -Be 'RightToLeft'; $w.Tag.Model.Language | Should -Be 'he'
    Click $w 'StartButton'; ($w.Tag.Choices | ConvertTo-Json -Compress) | Should -Not -Match '[^\x00-\x7F]' }
  It 'Start returns the validated Choices and closes; Cancel and Close return Cancel' {
    $w = New-LiveWindow; Click $w 'TypeDesktop'; Click $w 'StartButton'
    $w.Tag.Outcome | Should -Be 'Start'; $w.Tag.Closing | Should -BeTrue
    @($w.Tag.Choices.Keys | Sort-Object) | Should -Be @('Mode', 'Office', 'Profile', 'Remote', 'RestorePoint', 'SevenZip', 'Tweaks', 'WindowsUpdate')
    $w.Tag.Choices.WindowsUpdate | Should -BeExactly 'FULL'
    @($w.Tag.Choices.Tweaks) | Should -Be @('accessKeys', 'numLock', 'startClean', 'noAds')
    foreach ($b in 'CancelButton', 'CloseButton') { $c = New-LiveWindow; Click $c $b; $c.Tag.Outcome | Should -Be 'Cancel'; $c.Tag.Choices | Should -BeNullOrEmpty }
    $x = New-LiveWindow; $x.Close(); $x.Tag.Outcome | Should -Be 'Cancel' }   # Alt+F4 and the window's X end in Closing
  It 'Drivers only: the tile, the plan line in both languages, a profile click keeps it, Start hands it over (wu spec 3.1)' {
    $w = New-LiveWindow; ClickTag $w 'a:WindowsUpdate:DRIVERS'
    $w.Tag.Model.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS'; $w.FindName('UpdatesDrivers').IsChecked | Should -BeTrue; $w.FindName('UpdatesFull').IsChecked | Should -BeFalse
    (@($w.FindName('PlanList').Children).Text -join "`n") | Should -Match '(?m)  Windows Update \(drivers only\)$'
    Click $w 'LangHe'; (@($w.FindName('PlanList').Children).Text -join "`n") | Should -Match ('(?m)  ' + [regex]::Escape($script:ToolboxStrings.he['step.windows-update.drivers']) + '$')
    ClickTag $w 'a:Profile:business'; $w.Tag.Model.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS'; $w.FindName('UpdatesDrivers').IsChecked | Should -BeTrue
    Click $w 'StartButton'; $w.Tag.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS' }
  It 'Administrator protection On: red banner, Start disabled, a raised click refused (Review Focus 4)' {
    $w = New-TestWindow -Protection 'On'; Register-ToolboxHandlers -Window $w
    $s = $w.FindName('StartButton'); $s.IsEnabled | Should -BeFalse; $w.FindName('AdminBanner').Visibility | Should -Be 'Visible'
    $e = { (New-Object Windows.Automation.Peers.ButtonAutomationPeer $s).GetPattern('Invoke').Invoke() } | Should -Throw -PassThru   # a user cannot press it
    $e.Exception.InnerException.GetType().Name | Should -Be 'ElementNotEnabledException'
    Click $w 'StartButton'; $w.Tag.Outcome | Should -BeNullOrEmpty; $w.Tag.Choices | Should -BeNullOrEmpty; $w.Tag.Closing | Should -BeFalse
    @($script:logs | Where-Object { $_.Message -eq 'Start refused: Administrator protection is on' }).Count | Should -Be 1 }
  It 'an exception inside an action closes the window as Failed, never as Cancel (Review Focus 1)' {
    $w = New-LiveWindow; Mock Update-ToolboxView { throw ('view broke ' + [char]0x05D0 + [char]0x05D1) }
    { ClickTag $w 'a:Office:HOME' } | Should -Not -Throw
    $w.Tag.Outcome | Should -Be 'Failed'; $w.Tag.Error | Should -BeExactly 'view broke ??'; $w.Tag.Closing | Should -BeTrue
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox action failed' -and $_.Data.action -eq 'Office' -and $_.Data.error -eq 'view broke ??' }).Count | Should -Be 1
    (@($script:logs) | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match '[^\x00-\x7F]' }
  It 'Failed always wins over a later Start or Cancel; a Start after Failed keeps Failed' {
    $w = New-LiveWindow; Close-ToolboxWindow -Window $w -Outcome 'Failed' -ErrorText 'first'
    Close-ToolboxWindow -Window $w -Outcome 'Cancel'; Close-ToolboxWindow -Window $w -Outcome 'Start'
    $w.Tag.Outcome | Should -Be 'Failed'; $w.Tag.Error | Should -BeExactly 'first' }
  It 'an element without an action, or a sender outside any window, is Failed or logged, never thrown' {
    $w = New-LiveWindow; { Invoke-ToolboxAction -Sender $w.FindName('TitleBar') } | Should -Not -Throw
    $w.Tag.Outcome | Should -Be 'Failed'
    { Invoke-ToolboxAction -Sender $null -Action 'Start' } | Should -Not -Throw
    { Invoke-ToolboxAction -Sender (New-Object Windows.Controls.Button) -Action 'Start' } | Should -Not -Throw
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox action failed' }).Count | Should -Be 3 }
  It 'the dispatcher backstop marks the error handled and fails the open window' {
    $w = New-LiveWindow; $script:ToolboxOpenWindow = $w; $e = [pscustomobject]@{ Handled = $false; Exception = [Exception]('layout ' + [char]0x05D0) }
    Invoke-ToolboxUnhandled -EventArgs $e; $e.Handled | Should -BeTrue; $w.Tag.Outcome | Should -Be 'Failed'; $w.Tag.Error | Should -BeExactly 'layout ?'
    $script:ToolboxOpenWindow = $null; $e2 = [pscustomobject]@{ Handled = $false; Exception = [Exception]'late' }
    { Invoke-ToolboxUnhandled -EventArgs $e2 } | Should -Not -Throw; $e2.Handled | Should -BeTrue
    { Invoke-ToolboxUnhandled -EventArgs $null } | Should -Not -Throw
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox error' }).Count | Should -Be 3
    (@($script:logs) | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match '[^\x00-\x7F]' }
  It 'ContentRendered activates the window and turns Topmost off; a stray drag is harmless' {
    $w = New-LiveWindow; Invoke-ToolboxAction -Sender $w -Action 'Rendered'; $w.Topmost | Should -BeFalse
    Invoke-ToolboxAction -Sender $w.FindName('TitleBar') -Action 'Drag'; $w.Tag.Outcome | Should -BeNullOrEmpty
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' }).Count | Should -Be 0 }
  It 'the power timer refreshes every 5 s; a failed read keeps the last value' {
    $w = New-LiveWindow; $t = New-ToolboxPowerTimer -Window $w; $t.Interval.TotalSeconds | Should -Be 5; $t.Tag | Should -Be $w; $t.IsEnabled | Should -BeFalse
    $w.Tag.ReadOnAC = { $false }; Invoke-ToolboxAction -Sender $t -Action 'Power'
    $w.Tag.Model.OnAC | Should -BeFalse; $w.FindName('WarnText').Text | Should -Match 'BIOS updates will be skipped'
    $w.Tag.ReadOnAC = { throw 'no power status' }; Invoke-ToolboxAction -Sender $t -Action 'Power'; $w.Tag.Model.OnAC | Should -BeFalse; $w.Tag.Outcome | Should -BeNullOrEmpty
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Could not read the power state for the toolbox' }).Count | Should -Be 1 }
  It 'a power read that keeps failing is one WARN per window, not one per 5-second tick (Task 3 M2)' {
    foreach ($ticks in 3, 2) {
      $w = New-LiveWindow; $t = New-ToolboxPowerTimer -Window $w; $w.Tag.ReadOnAC = { throw 'no power status' }
      foreach ($i in 1..$ticks) { Invoke-ToolboxAction -Sender $t -Action 'Power' }
      $w.Tag.Outcome | Should -BeNullOrEmpty }
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Could not read the power state for the toolbox' }).Count | Should -Be 2 }   # one per window
  It 'a zero or negative work area is ignored: the window keeps 1000 x 680 (Task 3 M4)' {
    foreach ($area in (New-Object Windows.Rect 0, 0, 0, 0), (New-Object Windows.Rect 0, 0, 1920, 0), (New-Object Windows.Rect 0, 0, 0, 1040), [Windows.Rect]::Empty) {
      $w = New-LiveWindow; { Set-ToolboxWindowSize -Window $w -WorkArea $area } | Should -Not -Throw
      $w.Width | Should -Be 1000; $w.Height | Should -Be 680 } }   # Rect.Empty is the negative case: its width and height are -Infinity
  It 'clamps the window to a small work area and lets the content scroll' {
    $w = New-LiveWindow; Set-ToolboxWindowSize -Window $w -WorkArea (New-Object Windows.Rect 0, 0, 683, 512)
    $w.Width | Should -Be 683; $w.Height | Should -Be 512; $w.Left | Should -Be 0
    Set-ToolboxWindowSize -Window $w -WorkArea (New-Object Windows.Rect 0, 0, 1024, 720); $w.Width | Should -Be 1000; $w.Height | Should -Be 680; $w.Left | Should -Be 12
    $w.Top | Should -Be 20; $w.WindowStartupLocation | Should -Be 'Manual'
    Set-ToolboxWindowSize -Window $w -WorkArea (New-Object Windows.Rect 1920, 40, 1920, 1000); $w.Left | Should -Be 2380; $w.Top | Should -Be 200   # a second monitor, a top taskbar
    $w.FindName('ContentScroll').VerticalScrollBarVisibility | Should -Be 'Auto' }
  It 'the wheel over a plan that fits scrolls the body (TB-R7)' {
    $w = New-LiveWindow; Set-TestLayout $w 1000 600
    $plan = $w.FindName('PlanScroll'); $body = $w.FindName('ContentScroll')
    $plan.ScrollableHeight | Should -Be 0; $body.ScrollableHeight | Should -BeGreaterThan 0   # the case: the plan fits, the body does not
    Send-Wheel $w -120; $body.VerticalOffset | Should -BeGreaterThan 0
    Send-Wheel $w 120; $body.VerticalOffset | Should -Be 0 }
  It 'the wheel scrolls a plan that can scroll, and passes on at its end (TB-R7)' {
    $w = New-LiveWindow; Set-TestLayout $w 683 512
    $plan = $w.FindName('PlanScroll'); $body = $w.FindName('ContentScroll'); $plan.ScrollableHeight | Should -BeGreaterThan 0
    Send-Wheel $w -120; $plan.VerticalOffset | Should -BeGreaterThan 0; $body.VerticalOffset | Should -Be 0
    foreach ($i in 1..10) { Send-Wheel $w -120 }
    $plan.VerticalOffset | Should -Be $plan.ScrollableHeight; $body.VerticalOffset | Should -BeGreaterThan 0
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' }).Count | Should -Be 0 }
}
Describe 'Show-ToolboxWindow (seams only; never ShowDialog)' {
  BeforeEach { Set-ToolboxTestMocks }
  BeforeAll { function Show([scriptblock]$Dialog, [string]$Protection = 'Off', [scriptblock]$OnAC = { $true }) {
      Show-ToolboxWindow -Machine $m -Config $cfg -Version '2026.10.21.1' -Previous $null -IsFresh $true -ShowDialog $Dialog -OnAC $OnAC `
        -AdminProtection ([scriptblock]::Create("'$Protection'")) -WorkArea { New-Object Windows.Rect 0, 0, 1920, 1040 } } }
  It 'returns exactly one hashtable with the Choices on Start (Review Focus 2)' {
    $r = @(Show { param($w) $script:shown = $w; Click $w 'StartButton' })
    $r.Count | Should -Be 1; $r[0] | Should -BeOfType [hashtable]; $r[0].Outcome | Should -Be 'Start'; $r[0].Choices.Profile | Should -Be 'home'
    $script:shown.Tag.Timer.IsEnabled | Should -BeFalse; $script:ToolboxOpenWindow | Should -BeNullOrEmpty
    [Windows.Media.RenderOptions]::ProcessRenderMode | Should -Be 'SoftwareOnly' }
  It 'opens with the timer running, the window registered for the backstop, clamped and centred' {
    $null = Show { param($w) $script:seen = @{ Timer = $w.Tag.Timer.IsEnabled; Open = [object]::ReferenceEquals($script:ToolboxOpenWindow, $w); Width = $w.Width; Left = $w.Left; Top = $w.Top } }
    $script:seen.Timer | Should -BeTrue; $script:seen.Open | Should -BeTrue; $script:seen.Width | Should -Be 1000; $script:seen.Left | Should -Be 460; $script:seen.Top | Should -Be 180 }
  It 'a dialog closed with nothing chosen is Cancel through Closing; one that throws is Failed' {
    (Show { param($w) $w.Close() }).Outcome | Should -Be 'Cancel'   # the X, Alt+F4: the window closes during the dialog
    $r = Show { param($w) throw 'dialog broke' }; $r.Outcome | Should -Be 'Failed'; $r.Error | Should -BeExactly 'dialog broke'
    $script:ToolboxOpenWindow | Should -BeNullOrEmpty }
  It 'a dialog that returns with the window still open is Failed, set before the cleanup Close(): never Cancel (Task 3 M1)' {
    $r = @(Show { param($w) $script:openAtReturn = ($w.Tag.Closing -ne $true) })
    $script:openAtReturn | Should -BeTrue   # the case: nothing closed the window during the dialog
    $r.Count | Should -Be 1; $r[0].Outcome | Should -Be 'Failed'; $r[0].Error | Should -Not -BeNullOrEmpty; $r[0].Choices | Should -BeNullOrEmpty }
  It 'an exception raised through the dispatcher ends as Failed through the backstop, which is removed afterwards (Task 3 M5)' {
    # Offscreen: the seam pumps one short dispatcher frame instead of a dialog (the window is never shown). The first
    # operation throws as a layout or render error would; the second ends the frame.
    $r = @(Show { param($w)
      $script:frame = New-Object Windows.Threading.DispatcherFrame
      $null = $w.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Normal, [action]{ throw ('layout boom ' + [char]0x05D0) })
      $null = $w.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [action]{ $script:frame.Continue = $false })
      [Windows.Threading.Dispatcher]::PushFrame($script:frame) })
    $r.Count | Should -Be 1; $r[0].Outcome | Should -Be 'Failed'; $r[0].Error | Should -BeExactly 'layout boom ?'   # the backstop's, not 'Exception calling "PushFrame"'
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox error' }).Count | Should -Be 1
    # Afterwards a dispatcher exception reaches only this test's own handler (which marks it handled): the toolbox's is gone.
    $d = [Windows.Threading.Dispatcher]::CurrentDispatcher; $script:late = 0
    $own = [Windows.Threading.DispatcherUnhandledExceptionEventHandler]{ param($s, $e) $e.Handled = $true; $script:late++ }
    $d.Add_UnhandledException($own)
    try {
      $script:frame = New-Object Windows.Threading.DispatcherFrame
      $null = $d.BeginInvoke([Windows.Threading.DispatcherPriority]::Normal, [action]{ throw 'late' })
      $null = $d.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [action]{ $script:frame.Continue = $false })
      [Windows.Threading.Dispatcher]::PushFrame($script:frame)
    } finally { $d.Remove_UnhandledException($own) }
    $script:late | Should -Be 1
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox error' }).Count | Should -Be 1 }
  It 'a failed first power read counts for the window: the ticks after it log nothing more (Task 3 M2)' {
    $r = Show { param($w) foreach ($i in 1..3) { Invoke-ToolboxAction -Sender $w.Tag.Timer -Action 'Power' }; $w.Close() } -OnAC { throw 'no power status' }
    $r.Outcome | Should -Be 'Cancel'
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Could not read the power state for the toolbox' }).Count | Should -Be 1 }
  It 'the error logs carry the exception type as well as the ASCII message (Task 3 M3)' {
    $w = New-LiveWindow; $open = New-LiveWindow   # both built before the view is made to throw
    Mock Update-ToolboxView { throw [InvalidOperationException]::new('view broke ' + [char]0x05D0) }
    ClickTag $w 'a:Office:HOME'
    $a = @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox action failed' })
    $a.Count | Should -Be 1; $a[0].Data.type | Should -BeExactly 'System.InvalidOperationException'; $a[0].Data.error | Should -BeExactly 'view broke ?'
    $script:ToolboxOpenWindow = $open
    try { Invoke-ToolboxUnhandled -EventArgs ([pscustomobject]@{ Handled = $false; Exception = [ArgumentException]::new('layout') }) } finally { $script:ToolboxOpenWindow = $null }
    $b = @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox error' })
    $b.Count | Should -Be 1; $b[0].Data.type | Should -BeExactly 'System.ArgumentException'; $b[0].Data.error | Should -BeExactly 'layout'
    Mock New-ToolboxWindow { throw [IO.IOException]::new('xaml broke') }
    $null = Show { param($w) throw 'must not open' }
    $c = @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox window failed' })
    $c.Count | Should -Be 1; $c[0].Data.type | Should -BeExactly 'System.IO.IOException'; $c[0].Data.error | Should -BeExactly 'xaml broke'
    (@($script:logs) | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match '[^\x00-\x7F]' }
  It 'an Outcome still empty after the dialog is Failed, never Cancel' {
    Mock Register-ToolboxHandlers { }   # no Closing handler, so nothing sets Cancel
    $r = Show { param($w) }; $r.Outcome | Should -Be 'Failed'; $r.Error | Should -Not -BeNullOrEmpty }
  It 'a failure before the dialog is Failed with an ASCII message, never thrown' {
    Mock New-ToolboxWindow { throw ('xaml broke ' + [char]0x05D0) }
    $r = @(Show { param($w) throw 'must not open' }); $r.Count | Should -Be 1; $r[0].Outcome | Should -Be 'Failed'; $r[0].Error | Should -BeExactly 'xaml broke ?'
    (@($script:logs) | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match '[^\x00-\x7F]' }
  It 'a power read that throws counts as on AC; protection that is not Off is logged and blocks Start' {
    $r = Show { param($w) $script:onAC = $w.Tag.Model.OnAC; Click $w 'StartButton' } -OnAC { throw 'no power status' }
    $script:onAC | Should -BeTrue; $r.Outcome | Should -Be 'Start'
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Could not read the power state for the toolbox' }).Count | Should -Be 1
    $b = Show { param($w) Click $w 'StartButton'; $script:refusedOpen = ($w.Tag.Closing -ne $true); Click $w 'CancelButton' } -Protection 'On'
    $script:refusedOpen | Should -BeTrue; $b.Outcome | Should -Be 'Cancel'   # refused (the window stayed open), then Cancel
    @($script:logs | Where-Object { $_.Message -eq 'Start refused: Administrator protection is on' }).Count | Should -Be 1
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Administrator protection is not off' -and $_.Data.state -eq 'On' }).Count | Should -Be 1 }
  It 'calls ShowDialog only through the seam; no key handlers, no closures (Toolbox.ps1 and Xaml.ps1, TB-R7, Task 3 M6)' {
    $src = Get-Content "$PSScriptRoot\..\src\Toolbox\Toolbox.ps1" -Raw
    ([regex]::Matches($src, '\.ShowDialog\(')).Count | Should -Be 1; $src | Should -Match '\$ShowDialog = \{ param\(\$w\) \$w\.ShowDialog\(\) \}'
    # Any key-handler wiring, in code or in XAML (Should -Match ignores case): an event or its routed event (KeyDown, PreviewKeyDown,
    # KeyUp, PreviewKeyUp, KeyDownEvent ...), a key binding, a default or a cancel button.
    $keyWiring = 'KeyDown|KeyUp|InputBindings|KeyBinding|IsDefault="True"|IsCancel="True"'
    foreach ($sample in 'Add_KeyDown(', 'Add_PreviewKeyDown(', 'Add_KeyUp(', '$w.AddHandler([Windows.UIElement]::KeyDownEvent, $h)', 'KeyDown="OnKey"',
                        'PreviewKeyUp="OnKey"', '$w.InputBindings.Add($b)', '<KeyBinding Key="Enter"/>', 'IsDefault="True"', 'IsCancel="true"') {
      $sample | Should -Match $keyWiring -Because 'the guard must catch every kind of key wiring' }
    foreach ($file in 'Toolbox', 'Xaml') {
      Get-Content "$PSScriptRoot\..\src\Toolbox\$file.ps1" -Raw | Should -Not -Match "$keyWiring|GetNewClosure" -Because $file }
    $script:ToolboxXaml | Should -Not -Match 'IsCancel|IsDefault="True"' }
}
Describe 'Test-ToolboxHost (toolbox spec 5.1)' {
  It '<Why>' -ForEach @(
    @{ Why = 'an MTA thread';     A = 'MTA'; I = $true;  S = 1; L = { };                     Want = 'not STA' }
    @{ Why = 'no desktop';        A = 'STA'; I = $false; S = 1; L = { };                     Want = 'not interactive' }
    @{ Why = 'session 0';         A = 'STA'; I = $true;  S = 0; L = { };                     Want = 'session 0' }
    @{ Why = 'WPF missing';       A = 'STA'; I = $true;  S = 1; L = { throw 'no PresentationFramework' }; Want = 'WPF could not be loaded: no PresentationFramework' }
  ) { $got = Test-ToolboxHost -ApartmentState $A -UserInteractive $I -SessionId $S -LoadWpf $L; $got.Ok | Should -BeFalse; $got.Reason | Should -BeExactly $Want }   # not $R: PowerShell variables are case-insensitive, $r would overwrite it
  It 'all good is Ok' { (Test-ToolboxHost -ApartmentState 'STA' -UserInteractive $true -SessionId 1 -LoadWpf { }).Ok | Should -BeTrue }
  It 'checks in order (the first failing check wins) and never loads WPF after an earlier failure' {
    $script:loads = 0
    $r = Test-ToolboxHost -ApartmentState 'MTA' -UserInteractive $false -SessionId 0 -LoadWpf { $script:loads++ }
    $r.Reason | Should -BeExactly 'not STA'; $script:loads | Should -Be 0
    (Test-ToolboxHost -ApartmentState 'STA' -UserInteractive $false -SessionId 0 -LoadWpf { $script:loads++ }).Reason | Should -BeExactly 'not interactive'
    (Test-ToolboxHost -ApartmentState 'STA' -UserInteractive $true -SessionId 0 -LoadWpf { $script:loads++ }).Reason | Should -BeExactly 'session 0'
    $script:loads | Should -Be 0 }
  It 'returns exactly one hashtable, and a WPF message in Hebrew becomes ASCII' {
    $r = @(Test-ToolboxHost -ApartmentState 'STA' -UserInteractive $true -SessionId 1 -LoadWpf { 'noise'; 42 })
    $r.Count | Should -Be 1; $r[0] | Should -BeOfType [hashtable]; $r[0].Ok | Should -BeTrue
    $h = Test-ToolboxHost -ApartmentState 'STA' -UserInteractive $true -SessionId 1 -LoadWpf { throw ('no wpf ' + [char]0x05D0) }
    $h.Reason | Should -BeExactly 'WPF could not be loaded: no wpf ?' }
  It 'with no seams it reads this thread, process and session, and never throws' {
    $r = Test-ToolboxHost -LoadWpf { }
    $r | Should -BeOfType [hashtable]; $r.Ok | Should -BeOfType [bool]
    if (-not $r.Ok) { $r.Reason | Should -BeIn 'not STA', 'not interactive', 'session 0' } }
}
Describe 'Get-SetupChoices (toolbox spec 5.1)' {
  BeforeAll {
    $script:prev = @{ StartedAt = '2026-10-20T09:05:00'; Color = 'YELLOW' }
    function Get([scriptblock]$Toolbox, [bool]$HostOk = $true, [scriptblock]$Console = { param($p) $script:consoleArgs = $p; New-DefaultChoices -Machine $p.Machine -Config $p.Config }) {
      $script:shutdowns = 0; $script:consoleArgs = $null
      Get-SetupChoices -Machine $m -Config $cfg -Version '2026.10.21.1' -Previous $prev -IsFresh $false -TestHost ([scriptblock]::Create("@{ Ok = `$$HostOk; Reason = 'session 0' }")) `
        -ShowToolbox $Toolbox -ShowConsole $Console -ShutdownDispatcher { $script:shutdowns++ } }
  }
  BeforeEach { Set-ToolboxTestMocks }   # setup.log into $script:logs; the power state is never read for real
  It 'Start returns the validated Choices, once, and stops WPF once (Review Focus 2)' {
    $r = @(Get { param($p) @{ Outcome = 'Start'; Choices = @{ Mode = 'DESKTOP'; Office = 'CRAFT'; Remote = 'ANYDESK'; SevenZip = $true; Profile = 'home'; RestorePoint = $true; Tweaks = @('numLock', 'widgets') } } })
    $r.Count | Should -Be 1; $r[0] | Should -BeOfType [hashtable]; @($r[0].Tweaks) | Should -Be @('numLock')
    $script:shutdowns | Should -Be 1; $script:consoleArgs | Should -BeNullOrEmpty
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox closed' -and $_.Level -eq 'INFO' -and $_.Data.outcome -eq 'Start' -and $_.Data.profile -eq 'home' }).Count | Should -Be 1
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Unknown tweak ids dropped' -and @($_.Data.tweaks) -ceq 'widgets' }).Count | Should -Be 1 }
  It 'Cancel returns $null and never opens the console' {
    $r = @(Get { param($p) @{ Outcome = 'Cancel' } }); $r.Count | Should -Be 1; $r[0] | Should -BeNullOrEmpty; $script:consoleArgs | Should -BeNullOrEmpty
    $script:shutdowns | Should -Be 1
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox closed' -and $_.Level -eq 'INFO' -and $_.Data.outcome -eq 'Cancel' }).Count | Should -Be 1 }
  It 'Failed falls back to the console; a throwing toolbox is Failed, never Cancel (Review Focus 1)' {
    foreach ($tb in { param($p) @{ Outcome = 'Failed'; Error = 'view broke' } }, { param($p) throw ('boom ' + [char]0x05D0) }, { param($p) @{ Outcome = $null } }) {
      $r = Get $tb; $r | Should -BeOfType [hashtable]; $script:consoleArgs | Should -Not -BeNullOrEmpty; $script:shutdowns | Should -Be 1 }
    (@($script:logs) | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match '[^\x00-\x7F]'
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox failed; using the console start screen' }).Count | Should -Be 3
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox failed; using the console start screen' -and $_.Data.error -ceq 'view broke' }).Count | Should -Be 1
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox failed; using the console start screen' -and $_.Data.error -ceq 'boom ?' }).Count | Should -Be 1 }
  It 'a Start with no usable Choices is Failed and falls back to the console (Task 3 review)' {
    foreach ($tb in { param($p) @{ Outcome = 'Start' } }, { param($p) @{ Outcome = 'Start'; Choices = $null } }, { param($p) @{ Outcome = 'Start'; Choices = 'not a table' } }) {
      $r = Get $tb; $r | Should -BeOfType [hashtable]; $script:consoleArgs | Should -Not -BeNullOrEmpty; $script:shutdowns | Should -Be 1 }
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox failed; using the console start screen' }).Count | Should -Be 3
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox closed' }).Count | Should -Be 0 }
  It 'a toolbox that returns no table, a stray extra value or an unknown outcome is Failed too' {
    foreach ($tb in { param($p) }, { param($p) 'noise'; @{ Outcome = 'Cancel' } }, { param($p) 'Start' }, { param($p) @{ Outcome = 'Maybe' } }) {
      $r = Get $tb; $r | Should -BeOfType [hashtable]; $script:consoleArgs | Should -Not -BeNullOrEmpty; $script:shutdowns | Should -Be 1 }
    @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox failed; using the console start screen' }).Count | Should -Be 4 }
  It 'no host: the console with Show-StartScreen''s exact parameters, no window, no shutdown' {
    $r = Get { param($p) throw 'must not open' } -HostOk $false
    [object]::ReferenceEquals($script:consoleArgs.Machine, $m) | Should -BeTrue; [object]::ReferenceEquals($script:consoleArgs.Config, $cfg) | Should -BeTrue
    $script:consoleArgs.Version | Should -Be '2026.10.21.1'
    $script:consoleArgs.Previous.Color | Should -Be 'YELLOW'; $script:consoleArgs.IsFresh | Should -BeFalse; $script:shutdowns | Should -Be 0
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox not available; using the console start screen' -and $_.Data.reason -eq 'session 0' }).Count | Should -Be 1 }
  It 'a console Escape is $null; a console exception is not swallowed' {
    Get { param($p) @{ Outcome = 'Failed' } } -Console { param($p) $null } | Should -BeNullOrEmpty
    { Get { param($p) @{ Outcome = 'Failed' } } -Console { param($p) throw 'console broke' } } | Should -Throw '*console broke*' }
  It 'the console fallback never counts down: its seam gets NoAutoStart, after a failed host check and after a failed window (TB-R8)' {
    $null = Get { param($p) throw 'must not open' } -HostOk $false
    $script:consoleArgs.NoAutoStart | Should -BeTrue; $script:consoleArgs.IsFresh | Should -BeFalse
    foreach ($tb in { param($p) @{ Outcome = 'Failed'; Error = 'view broke' } }, { param($p) throw 'boom' }) {
      $script:consoleArgs = $null; $null = Get $tb; $script:consoleArgs.NoAutoStart | Should -BeTrue }
    $null = Get { param($p) $script:toolboxArgs = $p; @{ Outcome = 'Cancel' } }
    $script:toolboxArgs.Contains('NoAutoStart') | Should -BeFalse   # the window gets Show-StartScreen's five parameters only
    # The real Show-StartScreen takes the splat (its other seams given, so it reads no console): Escape is $null.
    Get { param($p) @{ Outcome = 'Failed' } } -Console { param($p) Show-StartScreen @p -ReadKey { 'Escape' } -Now { [datetime]'2026-10-22' } -Sleep { } -OnAC { $true } -Write { } -FlushInput { } } |
      Should -BeNullOrEmpty }
  It 'a console result that is neither $null nor exactly one hashtable never starts a run: it throws (Task 4 review M1)' {
    foreach ($c in { param($p) 'Start' }, { param($p) @{ Mode = 'DESKTOP' }; @{ Mode = 'LAPTOP' } }, { param($p) [pscustomobject]@{ Mode = 'DESKTOP' } },
                   { param($p) 'noise'; $null }, { param($p) $null; $null }, { param($p) 'noise'; @{ Mode = 'DESKTOP' } }) {
      { Get { param($p) @{ Outcome = 'Failed' } } -Console $c } | Should -Throw 'Start screen returned an unexpected result' }
    Get { param($p) @{ Outcome = 'Failed' } } -Console { param($p) } | Should -BeNullOrEmpty   # no result at all is Escape, as $null is
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox closed' }).Count | Should -Be 0 }
  It 'a toolbox that throws is logged with the exception type (Task 3 M3)' {
    $null = Get { param($p) throw [InvalidOperationException]::new('boom ' + [char]0x05D0) }
    $e = @($script:logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -eq 'Toolbox failed; using the console start screen' })
    $e.Count | Should -Be 1; $e[0].Data.error | Should -BeExactly 'boom ?'; $e[0].Data.type | Should -BeExactly 'System.InvalidOperationException'
    $null = Get { param($p) @{ Outcome = 'Failed'; Error = 'view broke' } }   # no exception here: the window logged its own type
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox failed; using the console start screen' })[1].Data.Contains('type') | Should -BeFalse }
  It 'the console''s Choices pass ConvertTo-ValidChoices too: unknown tweak ids are dropped and logged' {
    $r = Get { param($p) @{ Outcome = 'Failed' } } -Console { param($p) @{ Mode = 'DESKTOP'; Office = 'CRAFT'; Remote = 'ANYDESK'; SevenZip = $true; Profile = 'home'; RestorePoint = $true; Tweaks = @('numLock', 'widgets') } }
    @($r.Tweaks) | Should -Be @('numLock')
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Unknown tweak ids dropped' -and @($_.Data.tweaks) -ceq 'widgets' }).Count | Should -Be 1 }
  It 'a dispatcher shutdown that throws is only a WARN: the Start result stands' {
    $r = @(Get-SetupChoices -Machine $m -Config $cfg -Version '2026.10.21.1' -Previous $null -IsFresh $true -TestHost { @{ Ok = $true; Reason = '' } } `
      -ShowToolbox { param($p) @{ Outcome = 'Start'; Choices = @{ Mode = 'DESKTOP'; Office = 'CRAFT'; Remote = 'ANYDESK'; SevenZip = $true; Profile = 'home'; RestorePoint = $true; Tweaks = @() } } } `
      -ShowConsole { param($p) throw 'must not open' } -ShutdownDispatcher { throw ('stop failed ' + [char]0x05D0) })
    $r.Count | Should -Be 1; $r[0] | Should -BeOfType [hashtable]; $r[0].Profile | Should -Be 'home'
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Could not stop the toolbox dispatcher' -and $_.Data.error -ceq 'stop failed ?' }).Count | Should -Be 1 }
  It 'the console and the window return the same tweaks for the same options (Review Focus 3)' {
    $console = Get { param($p) @{ Outcome = 'Failed' } }
    $window = Get { param($p) Show-ToolboxWindow @p -ShowDialog { param($w) Click $w 'StartButton' } -OnAC { $true } -AdminProtection { 'Off' } -WorkArea { New-Object Windows.Rect 0, 0, 1920, 1040 } }
    @($window.Tweaks) | Should -Be @($console.Tweaks); $window.Office | Should -Be $console.Office; $window.Profile | Should -Be $console.Profile }
  It 'InvokeShutdown appears once in src, as this seam''s default (no test can reach it)' {
    $hits = @(Get-ChildItem "$PSScriptRoot\..\src" -Recurse -Filter *.ps1 | Select-String -Pattern 'InvokeShutdown' -SimpleMatch)
    $hits.Count | Should -Be 1; $hits[0].Line | Should -Match '\$ShutdownDispatcher = \{ \[Windows\.Threading\.Dispatcher\]::CurrentDispatcher\.InvokeShutdown\(\) \}' }
}
Describe 'every test passes the WPF seams (final review M5)' {
  # A static guard over tests\*.ps1, read with the PowerShell parser rather than a regex, so a call split over lines with
  # backticks, or a name inside a string or a Should -Invoke, is judged correctly. Every command call of
  #   Show-ToolboxWindow passes -ShowDialog (else it would open a real modal window and hang the suite), and
  #   Get-SetupChoices passes -TestHost, -ShowToolbox, -ShowConsole and -ShutdownDispatcher (else it could load WPF, open a
  #     real window, read the real console or stop WPF for the rest of the run),
  # by name. A call without them is allowed only inside a Describe whose own BeforeEach or BeforeAll mocks that command
  # (Entry.Tests mocks both in its BeforeEach). A Mock inside one It covers only that It, so it does not count.
  BeforeAll {
    $script:seamsNeeded = @{ 'Show-ToolboxWindow' = @('ShowDialog'); 'Get-SetupChoices' = @('TestHost', 'ShowToolbox', 'ShowConsole', 'ShutdownDispatcher') }
    function Get-EnclosingCommand($Node, [string[]]$Names) {
      for ($n = $Node.Parent; $null -ne $n; $n = $n.Parent) {
        if ($n -is [Management.Automation.Language.CommandAst] -and $Names -contains $n.GetCommandName()) { return $n } }
      return $null }
    function Test-MockedForDescribe($Call, [string]$Name) {
      $describe = Get-EnclosingCommand $Call @('Describe')
      if ($null -eq $describe) { return $false }
      $mocks = $describe.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Mock' -and
        $n.CommandElements.Count -ge 2 -and $n.CommandElements[1].Extent.Text -eq $Name }, $true)
      foreach ($mock in $mocks) {
        $block = Get-EnclosingCommand $mock @('BeforeEach', 'BeforeAll', 'It', 'Context', 'Describe')
        if ($block.GetCommandName() -in 'BeforeEach', 'BeforeAll' -and [object]::ReferenceEquals((Get-EnclosingCommand $block @('Describe', 'Context')), $describe)) { return $true } }
      return $false }
    # One line per call that misses a seam and is not covered by a mock; $script:callsSeen counts every call looked at.
    function Get-SeamViolations([Management.Automation.Language.Ast]$Ast, [string]$File) {
      $calls = $Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $script:seamsNeeded.ContainsKey([string]$n.GetCommandName()) }, $true)
      foreach ($call in $calls) {
        $script:callsSeen++
        $name = $call.GetCommandName()
        $passed = @($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        $missing = @($script:seamsNeeded[$name] | Where-Object { $passed -notcontains $_ })
        if ($missing.Count -gt 0 -and -not (Test-MockedForDescribe $call $name)) { '{0}:{1} {2} without -{3}' -f $File, $call.Extent.StartLineNumber, $name, ($missing -join ', -') } } }
    function Read-Snippet([string]$Text) { [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null) }
  }
  It 'the check itself: it finds a missing seam, also over several lines, and accepts only a Describe-wide mock' {
    $script:callsSeen = 0
    @(Get-SeamViolations (Read-Snippet "Describe 'd' { It 'i' { Show-ToolboxWindow -Machine `$m ``
      -IsFresh `$true } }") 'a') | Should -Be @('a:1 Show-ToolboxWindow without -ShowDialog')
    @(Get-SeamViolations (Read-Snippet "Describe 'd' { It 'i' { Get-SetupChoices -TestHost { } -ShowToolbox { } -ShowConsole { } } }") 'b') |
      Should -Be @('b:1 Get-SetupChoices without -ShutdownDispatcher')
    @(Get-SeamViolations (Read-Snippet "Describe 'd' { BeforeEach { Mock Get-SetupChoices { } }; Context 'c' { It 'i' { Get-SetupChoices -IsFresh `$true } } }") 'c') | Should -BeNullOrEmpty
    @(Get-SeamViolations (Read-Snippet "Describe 'd' { It 'i' { Mock Get-SetupChoices { } }; It 'j' { Get-SetupChoices -IsFresh `$true } }") 'd').Count | Should -Be 1
    @(Get-SeamViolations (Read-Snippet "Describe 'd' { It 'i' { Should -Invoke Get-SetupChoices; `$x = 'Show-ToolboxWindow' } }") 'e') | Should -BeNullOrEmpty
    $script:callsSeen | Should -Be 4 }
  It 'every call in tests\*.ps1 passes the seams, or sits in a Describe that mocks the command' {
    $script:callsSeen = 0
    $found = foreach ($file in Get-ChildItem $PSScriptRoot -Filter *.ps1 -Recurse) {
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
      @($errors).Count | Should -Be 0 -Because $file.Name
      Get-SeamViolations $ast $file.Name }
    @($found) | Should -BeNullOrEmpty
    $script:callsSeen | Should -BeGreaterOrEqual 5 }   # not vacuous: it sees the real calls in Toolbox.Tests and Entry.Tests
}
Describe 'tools\Preview-Toolbox.ps1' {
  It 'renders the six PNGs at 1000x680 without showing a window' {
    $out = Join-Path $TestDrive 'preview'; & "$PSScriptRoot\..\tools\Preview-Toolbox.ps1" -OutDir $out | Out-Null
    foreach ($f in 'toolbox-en.png', 'toolbox-he.png', 'toolbox-en-business-desktop.png', 'toolbox-en-blocked.png', 'toolbox-en-drivers.png', 'toolbox-he-drivers.png') {
      $s = [IO.File]::OpenRead((Join-Path $out $f))
      try { $frame = [Windows.Media.Imaging.BitmapDecoder]::Create($s, 'None', 'OnLoad').Frames[0]; $frame.PixelWidth | Should -Be 1000; $frame.PixelHeight | Should -Be 680 }
      finally { $s.Dispose() } } }
  It 'never shows or shuts down WPF' { $t = Get-Content "$PSScriptRoot\..\tools\Preview-Toolbox.ps1" -Raw; $t | Should -Not -Match 'ShowDialog|InvokeShutdown|\.Show\(' }
}
