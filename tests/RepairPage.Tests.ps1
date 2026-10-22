# tests/RepairPage.Tests.ps1
# Repair Task 3: the repair page's look (repair spec 4.1-4.4, 5; repair plan "XAML contract additions"): the XAML,
# the strings and the view (Update-RepairView) on the pure model of RepairPlanner.ps1.
#
# SAFETY: as Toolbox.Tests, the window is only parsed, never shown. No ShowDialog, no Dispatcher.InvokeShutdown, no
# registry, no CIM, no child process: the model is built from plain sample values (tests\fixtures\RepairSamples.ps1),
# setup.log goes to $script:logs and the power state is never read for real. Clicks are raised in code (RaiseEvent).
BeforeAll {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
  foreach ($f in 'Common\Config', 'Common\Logging', 'Common\Activity', 'Detect\Detection', 'Detect\PcName', 'State\State', 'Engine\Catalog', 'UI\StartScreen', 'Repair\ToolEngine',
                 'Toolbox\Strings', 'Toolbox\SetupPlanner', 'Toolbox\RepairPlanner', 'Toolbox\Xaml', 'Toolbox\Toolbox', 'Toolbox\RepairPage') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  # The Dell sample machine of tools\Preview-Toolbox.ps1.
  $script:m = @{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; FriendlyModel = 'Latitude 5440'; Serial = '7HX2K93'; NewName = 'DELL-7HX2K93'
                 Brand = 'DELL'; IsLaptop = $true; IsVM = $false; OsBuild = 26200; ComputerName = 'DESKTOP-4F7K2LQ' }
  . "$PSScriptRoot\fixtures\RepairSamples.ps1"

  function New-RepairWindow([hashtable]$Set = @{}) { New-ToolboxWindow -Model (New-TestModel $Set) -Machine $script:m -Config $script:cfg -Version '2026.10.22.1' }
  function Set-TestLayout($w, [double]$Width, [double]$Height) {
    $w.Content.Measure((New-Object Windows.Size $Width, $Height)); $w.Content.Arrange((New-Object Windows.Rect 0, 0, $Width, $Height)); $w.Content.UpdateLayout()
  }
  # Copied from Toolbox.Tests: a click raised in code, on a named element or on the first element with a Tag.
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
  # Every text in an element's logical tree, joined (the generated rows hold their text in TextBlocks).
  function Get-AllText($root) {
    $texts = New-Object Collections.Generic.List[string]; $pending = New-Object Collections.Stack; $pending.Push($root)
    while ($pending.Count -gt 0) {
      $node = $pending.Pop()
      if ($node -is [Windows.Controls.TextBlock]) { $texts.Add($node.Text) }
      foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($node)) { if ($child -is [Windows.DependencyObject]) { $pending.Push($child) } }
    }
    $texts -join "`n"
  }

  # Every name of the XAML contract additions (repair plan), plus the page's own parts.
  $chips = foreach ($c in 'Restart', 'Free', 'BitLocker', 'Internet', 'Disk', 'Power', 'Stick') { "Chip$c"; "Chip${c}Glyph"; "Chip${c}Text" }
  $script:contractNames = @('NavSetup', 'NavRepair', 'CenterPanel', 'SetupOptions', 'RepairCenter', 'SetupRight', 'RepairRight', 'StripPanel') + @($chips) + @(
    'ChipRestartButton', 'BackedUpSwitch', 'NoStickBanner', 'TileHealth', 'TileQuickReport', 'TileStandard', 'TilePostClone', 'TileWuReset', 'TileNetReset',
    'TileDiskCheck', 'TileGhosts', 'TileFullReport', 'TileCompare', 'NetRestoreButton', 'ComplaintBox',
    'WhatPanel', 'WhatText', 'ConfirmPanel', 'ConfirmTitle', 'ConfirmLines', 'ConfirmScroll', 'ConfirmItems', 'AtPcSwitch', 'YesPanel', 'YesBox', 'ConfirmButton',
    'ConfirmCancelButton', 'RunPanel', 'RunTitle', 'RunSteps', 'RunBar', 'RunElapsed', 'RunLog', 'StopButton', 'StoppingText', 'ResultPanel', 'ResultBanner',
    'ResultOutcome', 'ResultFindings', 'ResultRestartNeeded', 'OfferDiskCheckButton', 'OfferDismButton', 'OfferDismText', 'ResultFiles', 'OpenFolderButton',
    'RestartButton', 'CloseRefusedText')
  $script:dismOffer = @{ Path = 'E:\sources\install.wim'; Type = 'wim'; Index = 6; Edition = 'Professional'; Arch = 'x64'; Languages = @('he-IL'); Build = '26100'
                         BuildDiffers = $true; LanguageDiffers = $false }
  # Every Describe's BeforeEach (Pester has no root BeforeEach): setup.log goes to $script:logs, the power state is
  # never read for real, and $w is a fresh window on the default sample.
  function Set-RepairTestMocks {
    $script:logs = New-Object Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    Mock Test-OnACPower { $true }
    $script:w = New-RepairWindow @{}
  }
}

Describe 'the repair page look (spec 4.1)' {
  BeforeEach { Set-RepairTestMocks }
  It 'has every named element of the contract, ten tiles tagged a:Tile:<id>, and no default or cancel button' {
    foreach ($n in $contractNames) { $w.FindName($n) | Should -Not -BeNullOrEmpty -Because $n }   # every name of the XAML contract additions
    foreach ($id in $script:RepairTileRows.Values | ForEach-Object { $_ }) { (Find-Tagged $w "a:Tile:$id") | Should -BeOfType [Windows.Controls.Button] }
    $script:ToolboxXaml | Should -Not -Match 'IsDefault="True"|IsCancel="True"|InputBindings' }
  It 'the complaint and YES boxes are TextBoxes with their limits' { $w.FindName('ComplaintBox').MaxLength | Should -Be 2000; $w.FindName('ComplaintBox').AcceptsReturn | Should -BeTrue; $w.FindName('YesBox').MaxLength | Should -Be 8 }
  It 'the nav switches the page; the machine card stays' { $w = New-RepairWindow @{}; $w.FindName('RepairCenter').Visibility | Should -Be 'Visible'; $w.FindName('SetupOptions').Visibility | Should -Be 'Collapsed'; $w.FindName('MachineModel').Text | Should -Match 'Latitude' }
  It 'chips take their level''s brush and the tooltip text; power shows on laptops only' { $w = New-RepairWindow @{ Restart = 'crit'; Disk = 'warn' }
    $w.FindName('ChipRestart').Background | Should -Be $w.FindResource('DangerBackBrush'); $w.FindName('ChipRestartButton').Visibility | Should -Be 'Visible'
    $w.FindName('ChipDisk').Background | Should -Be $w.FindResource('WarnBackBrush'); $w.FindName('ChipRestart').ToolTip.Text | Should -Match 'servicing restart'
    (New-RepairWindow @{ IsLaptop = $false }).FindName('ChipPower').Visibility | Should -Be 'Collapsed' }
  It 'a disabled tile carries its reason as its tooltip' { $w = New-RepairWindow @{ Restart = 'crit' }; $t = $w.FindName('TileStandard'); $t.IsEnabled | Should -BeFalse; $t.ToolTip.Text | Should -Be 'Restart pending: restart first' }
  It 'the right panel shows, in priority, the confirmation, the run, the result or what the tile does' {
    foreach ($c in @(@{ Set = @{ Selected = 'standard' }; P = 'WhatPanel' }, @{ Set = @{ Result = $resultSample }; P = 'ResultPanel' }, @{ Set = @{ Result = $resultSample; Run = $runSample }; P = 'RunPanel' }
                      @{ Set = @{ Run = $runSample; Confirm = $confirmSample }; P = 'ConfirmPanel' })) {
      $x = New-RepairWindow $c.Set; @('WhatPanel','ConfirmPanel','RunPanel','ResultPanel' | Where-Object { $x.FindName($_).Visibility -eq 'Visible' }) | Should -Be @($c.P) } }
  It 'a running action lists its steps with their glyphs, the percent bar and the log tail left-to-right' { $w = New-RepairWindow @{ Run = $runSample }
    $w.FindName('RunBar').Value | Should -Be 45; $w.FindName('RunLog').FlowDirection | Should -Be 'LeftToRight'
    $rows = @($w.FindName('RunSteps').Children); $rows.Count | Should -Be 6   # five steps and, after the running one, its percent bar
    [object]::ReferenceEquals($rows[3], $w.FindName('RunBar').Parent) | Should -BeTrue
    (Get-AllText $rows[2]) | Should -Match 'Windows image \(DISM\)'; (Get-AllText $rows[2]) | Should -Match ([string][char]0xE768)
    (Get-AllText $rows[0]) | Should -Match ([string][char]0xE73E); (Get-AllText $rows[5]) | Should -Match 'Recovery \(WinRE\)'
    $w.FindName('RunTitle').Text | Should -Be 'Standard repair'; $w.FindName('RunElapsed').Text | Should -Be 'Elapsed 12:34'
    @($w.FindName('RunLog').Text -split "`n").Count | Should -Be 6; $w.FindName('StopButton').IsEnabled | Should -BeTrue
    $w.FindName('StoppingText').Visibility | Should -Be 'Collapsed'; $w.FindName('CloseRefusedText').Visibility | Should -Be 'Collapsed' }
  It 'no known percent, no bar: the step rows alone (plan Task 5 counts seven for the Health check)' {
    $run = @{ Action = 'health'; Current = 1; Percent = $null; ElapsedSeconds = 5; Stopping = $false; Log = @()
              Steps = @(foreach ($id in $script:ToolActionCatalog['health'].Steps) { @{ Id = $id; Status = $(if ($id -eq 'volumeState') { 'done' } elseif ($id -eq 'imageCheck') { 'running' } else { 'pending' }); Percent = $null } }) }
    $w = New-RepairWindow @{ Run = $run }; $w.FindName('RunSteps').Children.Count | Should -Be 7 }
  It 'Stop pressed: the button is off and the window says after which step; a refused close says why' {
    $run = $runSample.Clone(); $run.Stopping = $true; $w = New-RepairWindow @{ Run = $run; CloseRefused = $true }
    $w.FindName('StopButton').IsEnabled | Should -BeFalse; $w.FindName('StoppingText').Visibility | Should -Be 'Visible'
    $w.FindName('StoppingText').Text | Should -Be 'Stopping after Windows image (DISM)...'; $w.FindName('CloseRefusedText').Visibility | Should -Be 'Visible' }
  It 'findings are coloured by level and use the language''s text' { $x = New-RepairWindow @{ Language = 'he'; Result = $resultSample }   # CRIT volumeSpotFix, WARN sfcCorrupt (Args '3'), INFO activationUnknown
    $rows = @($x.FindName('ResultFindings').Children); $rows[0].Foreground | Should -Be $x.FindResource('CritBrush'); $rows[2].Foreground | Should -Be $x.FindResource('DimTextBrush')
    $rows[1].Text | Should -BeExactly ($script:ToolboxStrings.he['finding.sfcCorrupt'] -f '3') }
  It 'Hebrew mirrors the page; every t: key of the page exists in both languages' { $x = New-RepairWindow @{ Language = 'he' }; $x.FlowDirection | Should -Be 'RightToLeft'
    foreach ($k in [regex]::Matches($script:ToolboxXaml, 'Tag="t:([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) { $script:ToolboxStrings.he.Keys | Should -Contain $k }
    foreach ($id in $script:ToolSteps.Keys) { $script:ToolboxStrings.en.Keys | Should -Contain "tool.step.$id"; $script:ToolboxStrings.he.Keys | Should -Contain "tool.step.$id" } }
  It 'the new colours live in the one resource dictionary' { ([regex]::Matches($script:ToolboxXaml, '<Window\.Resources>')).Count | Should -Be 1; foreach ($c in '#4CAF50','#1E3A24','#E04343') { $script:ToolboxXaml | Should -Match $c } }
  It 'Register-ToolboxHandlers leaves the TextBoxes alone' { { Register-ToolboxHandlers -Window (New-RepairWindow @{}) } | Should -Not -Throw }
}

Describe 'the repair page view (Update-RepairView)' {
  BeforeEach { Set-RepairTestMocks }
  It 'returns nothing, and the window is exactly one Window in every sample state (Review Focus 2)' {
    foreach ($s in @{}, @{ Run = $runSample }, @{ Result = $resultSample }, @{ Confirm = $confirmSample }, @{ Language = 'he'; Stick = $null; Restart = 'crit' }) {
      $r = @(New-RepairWindow $s); $r.Count | Should -Be 1; $r[0] | Should -BeOfType [Windows.Window]; @(Update-RepairView -Window $r[0]).Count | Should -Be 0 } }
  It 'the setup page shows its own parts only; the nav follows the model, also after a click' {
    $model = New-ToolboxModel -Machine $m -Config $cfg -Previous $null -IsFresh $false -OnAC $true -AdminProtection 'Off'; $model.Page | Should -Be 'setup'
    $s = New-ToolboxWindow -Model $model -Machine $m -Config $cfg -Version 'v'
    foreach ($n in 'RepairCenter', 'RepairRight') { $s.FindName($n).Visibility | Should -Be 'Collapsed' -Because $n }
    foreach ($n in 'SetupOptions', 'SetupRight', 'WarnPanel') { $s.FindName($n).Visibility | Should -Be 'Visible' -Because $n }
    $s.FindName('NavSetup').IsChecked | Should -BeTrue; $s.FindName('NavRepair').IsChecked | Should -BeFalse
    $s.FindName('NavSetupGlyph').Foreground | Should -Be $s.FindResource('AccentBrush'); $s.FindName('NavRepairGlyph').Foreground | Should -Be $s.FindResource('SubtleTextBrush')
    Register-ToolboxHandlers -Window $s; Click $s 'NavRepair'
    $s.Tag.Model.Page | Should -Be 'repair'; $s.FindName('NavRepair').IsChecked | Should -BeTrue; $s.FindName('NavSetup').IsChecked | Should -BeFalse
    $s.FindName('NavRepairGlyph').Foreground | Should -Be $s.FindResource('AccentBrush'); $s.FindName('NavSetupGlyph').Foreground | Should -Be $s.FindResource('SubtleTextBrush')
    foreach ($n in 'SetupOptions', 'SetupRight', 'WarnPanel', 'AdminBanner') { $s.FindName($n).Visibility | Should -Be 'Collapsed' -Because $n }
    $s.FindName('RepairRight').Visibility | Should -Be 'Visible'; $s.Tag.Outcome | Should -BeNullOrEmpty }
  It 'the machine card names the PC as it is on the repair page, its new name on the setup page; the strip has the power chip' {
    $w.FindName('MachinePcName').Text | Should -BeExactly 'DESKTOP-4F7K2LQ'; $w.FindName('MachinePcName').FlowDirection | Should -Be 'LeftToRight'
    $w.FindName('MachinePcNamePart').Visibility | Should -Be 'Visible'; $w.FindName('MachineNewNamePart').Visibility | Should -Be 'Collapsed'
    $w.FindName('PowerChip').Visibility | Should -Be 'Collapsed'
    $w.Tag.Model.Page = 'setup'; Update-ToolboxView -Window $w
    $w.FindName('MachinePcNamePart').Visibility | Should -Be 'Collapsed'; $w.FindName('MachineNewNamePart').Visibility | Should -Be 'Visible'; $w.FindName('PowerChip').Visibility | Should -Be 'Visible' }
  It 'the chips read the strip: texts with their values, loading, the stick and the switches it brings' {
    $w.FindName('ChipFreeText').Text | Should -Be 'C: 41% free'; $w.FindName('ChipStickText').Text | Should -Be 'Stick E:'; $w.FindName('ChipRestartText').Text | Should -Be 'No restart pending'
    $w.FindName('ChipRestart').Background | Should -Be $w.FindResource('OkBackBrush'); $w.FindName('ChipRestart').ToolTip | Should -BeNullOrEmpty
    foreach ($n in 'ChipRestartButton', 'BackedUpSwitch', 'NoStickBanner') { $w.FindName($n).Visibility | Should -Be 'Collapsed' -Because $n }
    $l = New-RepairWindow @{ State = 'loading'; Restart = $null; Free = $null; BitLocker = $null; Internet = $null; Disk = $null }
    $l.FindName('ChipDiskText').Text | Should -Be 'Checking...'; $l.FindName('ChipDisk').Background | Should -Be $l.FindResource('TileBrush')
    $b = New-RepairWindow @{ Disk = 'crit'; Stick = $null; Internet = 'warn' }
    $b.FindName('BackedUpSwitch').Visibility | Should -Be 'Visible'; $b.FindName('BackedUpSwitch').IsChecked | Should -BeFalse; $b.FindName('NoStickBanner').Visibility | Should -Be 'Visible'
    $b.FindName('ChipStickText').Text | Should -Be 'No stick'; $b.FindName('ChipInternetText').Text | Should -Be 'Captive portal or proxy'
    $b.FindName('ChipInternet').ToolTip.Text | Should -Match 'captive portal'
    (New-RepairWindow @{ Disk = 'crit'; BackedUp = $true }).FindName('BackedUpSwitch').IsChecked | Should -BeTrue }
  It 'tiles follow their gates: enabled ones have no tooltip, the selected one is outlined, Restore shows with a backup' {
    foreach ($id in $script:RepairTileRows.Values | ForEach-Object { $_ } | Where-Object { $_ -ne 'compare' }) {
      $t = Find-Tagged $w "a:Tile:$id"; $t.IsEnabled | Should -BeTrue -Because $id; $t.ToolTip | Should -BeNullOrEmpty -Because $id }
    $w.FindName('TileCompare').IsEnabled | Should -BeFalse   # no earlier report: the one disabled tile of a ready page
    [Windows.Controls.ToolTipService]::GetShowOnDisabled($w.FindName('TileCompare')) | Should -BeTrue
    $w.FindName('NetRestoreButton').Visibility | Should -Be 'Collapsed'
    $s = New-RepairWindow @{ Selected = 'standard'; NetBackup = @{ Path = 'E:\x\network.json'; Sha256 = 'AB'; CreatedAt = '2026-10-20T09:05:00'; Adapters = 1 } }
    $s.FindName('TileStandard').BorderBrush | Should -Be $s.FindResource('AccentBrush'); $s.FindName('TileHealth').BorderBrush | Should -Be $s.FindResource('LineBrush')
    $s.FindName('NetRestoreButton').Visibility | Should -Be 'Visible'
    $n = New-RepairWindow @{ Stick = $null }; $n.FindName('TileNetReset').ToolTip.Text | Should -Be 'Plug in the BenTech stick: the network and device backups are kept there'
    $n.FindName('TileGhosts').IsEnabled | Should -BeFalse; $n.FindName('TileHealth').IsEnabled | Should -BeTrue }
  It 'what it does: the selected tile''s title, text and change list; a hint without one' {
    $s = New-RepairWindow @{ Selected = 'wuReset' }
    $s.FindName('WhatText').Text | Should -BeExactly $script:ToolboxStrings.en['tile.wuReset.what']; $s.FindName('WhatText').Text | Should -Match 'SoftwareDistribution'
    $s.FindName('WhatTitle').Text | Should -Be 'Windows Update reset'; (Get-AllText $s.FindName('WhatChanges')) | Should -Match 'catroot2'
    $w.FindName('WhatText').Text | Should -BeExactly 'Point at a tile to see what it does.'; $w.FindName('WhatChanges').Children.Count | Should -Be 0 }
  It 'the confirmation: its title, the change list, the adapter left-to-right, the at-PC switch and YES; Confirm follows the model (RD-R2)' {
    $c = $confirmSample.Clone(); $x = New-RepairWindow @{ Confirm = $c; Language = 'he' }
    $x.FindName('ConfirmTitle').Text | Should -BeExactly $script:ToolboxStrings.he['tile.netReset.title']
    (Get-AllText $x.FindName('ConfirmLines')) | Should -Match ([regex]::Escape(($script:ToolboxStrings.he['tile.netReset.changes'] -split "`n")[0]))
    $row = @($x.FindName('ConfirmItems').Children)[0]; (Get-AllText $row) | Should -Match '192\.168\.1\.10/24'; $row.FlowDirection | Should -Be 'LeftToRight'
    $x.FindName('AtPcSwitch').Visibility | Should -Be 'Visible'; $x.FindName('YesPanel').Visibility | Should -Be 'Visible'; $x.FindName('ConfirmButton').IsEnabled | Should -BeFalse
    $c.Typed = 'YES'; $c.AtPc = $true; Update-ToolboxView -Window $x
    $x.FindName('ConfirmButton').IsEnabled | Should -BeTrue; $x.FindName('AtPcSwitch').IsChecked | Should -BeTrue
    $std = New-RepairWindow @{ Confirm = @{ Action = 'standard'; Kind = 'confirm'; Typed = ''; AtPc = $false; Loading = $false; Lines = @(@{ Key = 'tile.standard.changes' }, @{ Key = 'warn.lowSpace' }); Remote = $null; Items = @(); Options = @{} } }
    $std.FindName('YesPanel').Visibility | Should -Be 'Collapsed'; $std.FindName('AtPcSwitch').Visibility | Should -Be 'Collapsed'; $std.FindName('ConfirmButton').IsEnabled | Should -BeTrue
    (Get-AllText $std.FindName('ConfirmLines')) | Should -Match 'Low free space'
    $rdp = $confirmSample.Clone(); $rdp.Remote = @{ Rdp = $true }; (Get-AllText (New-RepairWindow @{ Confirm = $rdp }).FindName('ConfirmLines')) | Should -Match 'Remote Desktop session' }
  It 'a new confirmation clears YES; a re-render touches neither YES nor the complaint' {
    $x = New-RepairWindow @{ Confirm = $confirmSample.Clone() }
    $x.FindName('YesBox').Text = 'YES'; $x.FindName('ComplaintBox').Text = 'Slow since the update'; Update-ToolboxView -Window $x
    $x.FindName('YesBox').Text | Should -BeExactly 'YES'; $x.FindName('ComplaintBox').Text | Should -BeExactly 'Slow since the update'
    $x.Tag.Model.Repair.Confirm = $null; Update-ToolboxView -Window $x; $x.FindName('YesBox').Text | Should -BeExactly 'YES'
    $x.Tag.Model.Repair.Confirm = @{ Action = 'wuReset'; Kind = 'yes'; Typed = ''; AtPc = $false; Loading = $false; Lines = @(@{ Key = 'tile.wuReset.changes' }); Remote = $null; Items = @(); Options = @{} }
    Update-ToolboxView -Window $x; $x.FindName('YesBox').Text | Should -BeExactly ''; $x.FindName('ComplaintBox').Text | Should -BeExactly 'Slow since the update' }
  It 'the result: the banner''s colour, the restart line, the offers, the files left-to-right and Open folder' {
    $x = New-RepairWindow @{ Result = $resultSample }
    $x.FindName('ResultBanner').Background | Should -Be $x.FindResource('WarnBackBrush'); $x.FindName('ResultOutcome').Text | Should -Be 'Finished'
    $x.FindName('ResultRestartNeeded').Visibility | Should -Be 'Visible'; $x.FindName('OfferDiskCheckButton').Visibility | Should -Be 'Visible'; $x.FindName('OfferDismButton').Visibility | Should -Be 'Collapsed'
    $x.FindName('ResultFiles').Text | Should -BeExactly $resultSample.Files.Folder; $x.FindName('ResultFiles').FlowDirection | Should -Be 'LeftToRight'
    $x.FindName('OpenFolderButton').Visibility | Should -Be 'Visible'
    $r = $resultSample.Clone(); $r.Color = 'RED'; $r.Offers = @{ DiskCheck = $false; DismSource = $dismOffer }; $r.Files = @{}; $r.Findings = @(); $r.RestartRequired = $false
    $y = New-RepairWindow @{ Result = $r; Language = 'he' }
    $y.FindName('ResultBanner').Background | Should -Be $y.FindResource('DangerBackBrush'); $y.FindName('OfferDismButton').Visibility | Should -Be 'Visible'
    $y.FindName('OfferDismText').Text | Should -Match 'install\.wim.*Professional, x64, he-IL, build 26100'; $y.FindName('OfferDismText').FlowDirection | Should -Be 'LeftToRight'
    (Get-AllText $y.FindName('OfferDismButton')) | Should -Match '26200'; $y.FindName('OpenFolderButton').Visibility | Should -Be 'Collapsed'
    @($y.FindName('ResultFindings').Children)[0].Text | Should -BeExactly $script:ToolboxStrings.he['result.none'] }
  It 'a finding code the table does not know shows the child''s English text' {
    $r = $resultSample.Clone(); $r.Findings = @(@{ Level = 'WARN'; Code = 'noSuchCode'; Text = 'Something new happened'; Args = @() })
    $row = @((New-RepairWindow @{ Result = $r; Language = 'he' }).FindName('ResultFindings').Children)[0]
    $row.Text | Should -BeExactly 'Something new happened'; $row.FlowDirection | Should -Be 'LeftToRight' }
  It 'the page fits the 1000 x 680 window without scrolling, all green and with every blocking chip, its switch and the no-stick banner' {
    Set-TestLayout $w 1000 680; $w.FindName('ContentScroll').ScrollableHeight | Should -Be 0
    $b = New-RepairWindow @{ Restart = 'crit'; Disk = 'crit'; OnAC = $false; Stick = $null; BitLocker = 'warn' }
    Set-TestLayout $b 1000 680; $b.FindName('ContentScroll').ScrollableHeight | Should -Be 0 }
}

Describe 'the repair page review fixes (ruling RD-R14)' {
  BeforeAll {
    # Where each character of a TextBlock's text is drawn (its rectangle), in logical order (the window laid out
    # first). In a right-to-left element WPF measures from the element's right edge.
    function Get-CharacterRects($tb) {
      $rects = New-Object Collections.Generic.List[object]; $p = $tb.ContentStart
      while ($null -ne $p) {
        if ($p.GetPointerContext('Forward') -eq 'Text') {
          $run = $p.GetTextInRun('Forward')
          for ($i = 0; $i -lt $run.Length; $i++) { $rects.Add($p.GetPositionAtOffset($i).GetCharacterRect('Forward')) }
          $p = $p.GetPositionAtOffset($run.Length)
        } else { $p = $p.GetNextContextPosition('Forward') }
      }
      , $rects.ToArray()
    }
    # $true when -Value, inside the block's text, is drawn left-to-right: on each line, each character to the right of
    # the one before (a wrapped value starts again on the next line).
    function Test-ReadsLeftToRight($tb, [string]$Value) {
      $at = $tb.Text.IndexOf($Value); if ($at -lt 0) { return $false }
      $rects = Get-CharacterRects $tb; $sign = if ($tb.FlowDirection -eq 'RightToLeft') { -1 } else { 1 }; $pairs = 0
      for ($k = $at + 1; $k -lt $at + $Value.Length; $k++) {
        if ([math]::Abs($rects[$k].Y - $rects[$k - 1].Y) -gt 1) { continue }
        $pairs++; if ($sign * ($rects[$k].X - $rects[$k - 1].X) -le 0) { return $false } }
      ($pairs -gt 0)
    }
  }
  BeforeEach { Set-RepairTestMocks; $script:ToolboxWarned.Clear() }

  It 'Hebrew: drives, percentages, paths, codes and times read left-to-right inside the right-to-left lines (item 1)' {
    $r = $resultSample.Clone()
    $r.Findings = @(@{ Level = 'WARN'; Code = 'sessionLink'; Text = 'x'; Args = @('E:\BenTech-Reports') }
                    @{ Level = 'WARN'; Code = 'sessionCreateFailed'; Text = 'x'; Args = @('access denied', 'C:\BenTech\Setup\Logs\Repair\v1') }
                    @{ Level = 'CRIT'; Code = 'dismFailed'; Text = 'DISM RestoreHealth failed (0x800F081F)'; Args = @('0x800F081F') })
    $x = New-RepairWindow @{ Language = 'he'; Result = $r }; Set-TestLayout $x 1000 680
    $free = $x.FindName('ChipFreeText'); Test-ReadsLeftToRight $free '41%' | Should -BeTrue; $free.Text | Should -Not -Match 'C:'; $free.Text | Should -Match 'C'
    $stick = $x.FindName('ChipStickText'); $stick.Text | Should -Match 'E'; $stick.Text | Should -Not -Match ':'   # the letter alone: no colon met first
    $rows = @($x.FindName('ResultFindings').Children)
    Test-ReadsLeftToRight $rows[0] 'E:\BenTech-Reports' | Should -BeTrue
    Test-ReadsLeftToRight $rows[1] 'C:\BenTech\Setup\Logs\Repair\v1' | Should -BeTrue; Test-ReadsLeftToRight $rows[1] 'access denied' | Should -BeTrue
    Test-ReadsLeftToRight $rows[2] 'DISM RestoreHealth failed (0x800F081F)' | Should -BeTrue   # a code the table lacks: the child's text, left-to-right
    $y = New-RepairWindow @{ Language = 'he'; Run = $runSample }; Set-TestLayout $y 1000 680
    Test-ReadsLeftToRight $y.FindName('RunElapsed') '12:34' | Should -BeTrue
    # The mark is what keeps it so: the same Hebrew line without marks draws the drive's colon on the wrong side.
    $plain = New-Object Windows.Controls.TextBlock; $plain.FlowDirection = 'RightToLeft'; $plain.Text = ($script:ToolboxStrings.he['finding.sessionLink'] -f 'E:')
    $plain.Measure((New-Object Windows.Size 600, 100)); $plain.Arrange((New-Object Windows.Rect 0, 0, 600, 100)); Test-ReadsLeftToRight $plain 'E:' | Should -BeFalse
    # English is untouched by marks; a plain number and a Hebrew value never get one.
    (New-RepairWindow @{ Result = $r }).FindName('ResultFindings').Children[0].Text | Should -BeExactly 'BenTech-Reports on the stick is a link: the files were kept in E:\BenTech-Reports'
    Format-RepairText -State $x.Tag -Key 'finding.sfcCorrupt' -Arguments @('3') | Should -BeExactly ($script:ToolboxStrings.he['finding.sfcCorrupt'] -f '3')
    $hebrewStep = $script:ToolboxStrings.he['tool.step.dism']
    Format-RepairText -State $x.Tag -Key 'run.stopping' -Arguments @($hebrewStep) | Should -BeExactly ($script:ToolboxStrings.he['run.stopping'] -f $hebrewStep) }
  It 'Confirm.Lines: @{ Key; Args } in the window''s language, @{ Ltr } left-to-right, anything else skipped and logged once (item 3, M2)' {
    $c = @{ Action = 'ghosts'; Kind = 'yes'; Typed = ''; AtPc = $false; Loading = $false; Remote = $null; Options = @{}
            Items = @(@{ InstanceId = 'USB\VID_0781&PID_5567\4C53'; Class = 'USB'; Name = 'SanDisk Cruzer'; Ticked = $true })
            Lines = @(@{ Key = 'tile.ghosts.changes' }, @{ Key = 'confirm.ghostCount'; Args = @(1, 3, 2) }, @{ Ltr = 'USB\VID_0781&PID_5567\4C53' }, 'tile.ghosts.changes',
                      @{ Key = 'no.such.key' }, @{ Key = 'confirm.static'; Args = @('Wi-Fi', '10.0.0.5/24, gateway 10.0.0.1, DNS 1.1.1.1') }) }
    $x = New-RepairWindow @{ Language = 'he'; Confirm = $c }; Set-TestLayout $x 1000 680
    (Get-AllText $x.FindName('ConfirmLines')) | Should -Match ([regex]::Escape(($script:ToolboxStrings.he['confirm.ghostCount'] -f 1, 3, 2)))
    $boxes = @($x.FindName('ConfirmItems').Children | Where-Object { $_ -is [Windows.Controls.Border] })
    $boxes.Count | Should -Be 2; @($boxes | Where-Object { $_.FlowDirection -ne 'LeftToRight' }).Count | Should -Be 0
    $boxes[0].Child.Text | Should -BeExactly 'USB\VID_0781&PID_5567\4C53'; $boxes[1].Child.Text | Should -BeExactly 'Wi-Fi: 10.0.0.5/24, gateway 10.0.0.1, DNS 1.1.1.1'
    Test-ReadsLeftToRight $boxes[1].Child '10.0.0.5/24' | Should -BeTrue
    @($x.FindName('ConfirmItems').Children | Where-Object { $_ -is [Windows.Controls.CheckBox] }).Count | Should -Be 1   # the device switch
    (Get-AllText $x.FindName('ConfirmLines')) | Should -Not -Match 'no\.such\.key'
    Update-ToolboxView -Window $x
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox repair row skipped' -and $_.Data.list -eq 'lines' }).Count | Should -Be 1 }   # once, not per render
  It 'step rows name the step, the panel title the tile: DISM from a local source, Restore network settings (item 4, M3)' {
    $d = New-RepairWindow @{ Run = @{ Action = 'dismSource'; Current = 0; ElapsedSeconds = 5; Stopping = $false; Log = @()
                                      Steps = @(@{ Id = 'dismSource'; Status = 'running'; Percent = $null }, @{ Id = 'sfc'; Status = 'pending'; Percent = $null }) } }
    $d.FindName('RunTitle').Text | Should -BeExactly $script:ToolboxStrings.en['tile.dismSource.title']
    (Get-AllText @($d.FindName('RunSteps').Children)[0]) | Should -Match ([regex]::Escape($script:ToolboxStrings.en['tool.step.dismSource']))
    $n = New-RepairWindow @{ Run = @{ Action = 'netRestore'; Current = 0; ElapsedSeconds = 5; Stopping = $false; Log = @(); Steps = @(@{ Id = 'netRestore'; Status = 'running'; Percent = $null }) } }
    $n.FindName('RunTitle').Text | Should -BeExactly 'Restore network settings'
    (Get-AllText @($n.FindName('RunSteps').Children)[0]) | Should -Match 'Restore the network settings'
    (Get-AllText @((New-RepairWindow @{ Run = @{ Action = 'x'; Steps = @(@{ Id = 'compare'; Status = 'done' }) } }).FindName('RunSteps').Children)[0]) | Should -Match 'Compare with last visit' }
  It 'rows read from JSON render like hashtables; an unusable row is skipped and logged once (item 5, M4)' {
    $fromJson = $resultSample | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $x = New-RepairWindow @{ Result = $fromJson }
    $rows = @($x.FindName('ResultFindings').Children); $rows.Count | Should -Be 3; $rows[0].Foreground | Should -Be $x.FindResource('CritBrush')
    $rows[1].Text | Should -BeExactly 'System files: 3 integrity problems found (nothing repaired yet)'
    $x.FindName('OfferDiskCheckButton').Visibility | Should -Be 'Visible'; $x.FindName('ResultFiles').Text | Should -BeExactly $resultSample.Files.Folder
    $run = $runSample | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $y = New-RepairWindow @{ Run = $run }; $y.FindName('RunSteps').Children.Count | Should -Be 6; $y.FindName('RunBar').Value | Should -Be 45
    $mixed = $resultSample.Clone(); $mixed.Findings = @($resultSample.Findings[0], 'not a row', ($resultSample.Findings[1] | ConvertTo-Json | ConvertFrom-Json))
    $z = New-RepairWindow @{ Result = $mixed }; @($z.FindName('ResultFindings').Children).Count | Should -Be 2; Update-ToolboxView -Window $z
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox repair row skipped' -and $_.Data.list -eq 'findings' -and $_.Data.type -eq 'System.String' }).Count | Should -Be 1 }
  It 'an unchanged render keeps the very same tooltip objects; a changed text gets a new one (item 6, M5)' {
    $x = New-RepairWindow @{ Restart = 'crit' }
    $chipTip = $x.FindName('ChipRestart').ToolTip; $tileTip = $x.FindName('TileStandard').ToolTip
    $chipTip | Should -Not -BeNullOrEmpty; $tileTip | Should -Not -BeNullOrEmpty
    foreach ($i in 1, 2) { Invoke-ToolboxAction -Sender (New-ToolboxPowerTimer -Window $x) -Action 'Power' }   # the 5-second tick re-renders
    [object]::ReferenceEquals($x.FindName('ChipRestart').ToolTip, $chipTip) | Should -BeTrue
    [object]::ReferenceEquals($x.FindName('TileStandard').ToolTip, $tileTip) | Should -BeTrue
    $x.Tag.Model.Language = 'he'; Update-ToolboxView -Window $x
    [object]::ReferenceEquals($x.FindName('TileStandard').ToolTip, $tileTip) | Should -BeFalse
    $x.FindName('TileStandard').ToolTip.Text | Should -BeExactly $script:ToolboxStrings.he['reason.restart']; $x.FindName('TileStandard').ToolTip.FlowDirection | Should -Be 'RightToLeft'
    $x.Tag.Model.Repair.Strip.Restart = @{ Level = 'ok'; Args = @(); Detail = @{} }; Update-ToolboxView -Window $x
    $x.FindName('ChipRestart').ToolTip | Should -BeNullOrEmpty; $x.FindName('TileStandard').ToolTip | Should -BeNullOrEmpty }
  It 'Restore network settings without a stick says why in words that fit it (item 7, M11)' {
    $x = New-RepairWindow @{ Stick = $null; NetBackup = @{ Path = 'E:\x\network.json'; Sha256 = 'AB'; CreatedAt = '2026-10-20T09:05:00'; Adapters = 1 } }
    $x.FindName('NetRestoreButton').ToolTip.Text | Should -BeExactly 'Plug in the BenTech stick: the network and device backups are kept there'
    $script:ToolboxStrings.he['reason.noStickBackup'] | Should -Not -Match 'לשרוד' }
}
