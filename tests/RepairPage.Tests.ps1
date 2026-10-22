# tests/RepairPage.Tests.ps1
# Repair Task 3: the repair page's look (repair spec 4.1-4.4, 5; repair plan "XAML contract additions"): the XAML,
# the strings and the view (Update-RepairView) on the pure model of RepairPlanner.ps1.
#
# Repair Task 4: the window runs actions (repair spec 4.3, 4.4, 6.9, 7): the background child, the 500 ms run timer,
# the deadline kill on the run's own Stopwatch (RD-R8, RD-R9), Stop, the close guard and Restart PC.
#
# SAFETY: as Toolbox.Tests, the window is only parsed, never shown. No ShowDialog, no Dispatcher.InvokeShutdown, no
# registry, no CIM, no child process: the model is built from plain sample values (tests\fixtures\RepairSamples.ps1),
# setup.log goes to $script:logs and the power state is never read for real. Clicks are raised in code (RaiseEvent).
# No process is ever started or killed: the run tests give every window a recording -StartChild seam that returns a
# fake process object (Id 4242, 4243, ...), and every BeforeEach mocks Start-BackgroundExternal, Stop-ProcessTree,
# Invoke-External, Start-Process and Restart-Computer to throw (the run tests replace Stop-ProcessTree with a
# recorder). The run folders are written under $TestDrive\Root only.
BeforeAll {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
  foreach ($f in 'Common\Config', 'Common\Logging', 'Common\Activity', 'Common\Process', 'Detect\Detection', 'Detect\PcName', 'State\State', 'Engine\Catalog',
                 'UI\StartScreen', 'Entry\Cleanup', 'Repair\ToolEngine', 'Toolbox\Strings', 'Toolbox\SetupPlanner', 'Toolbox\RepairPlanner', 'Toolbox\Xaml',
                 'Toolbox\Toolbox', 'Toolbox\RepairPage') { . "$PSScriptRoot\..\src\$f.ps1" }
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
    # Safety nets (Task 4): nothing here may start or kill a process, or restart this PC.
    Mock Start-BackgroundExternal { throw 'blocked by the test: Start-BackgroundExternal' }
    Mock Stop-ProcessTree { throw 'blocked by the test: Stop-ProcessTree' }
    Mock Invoke-External { throw 'blocked by the test: Invoke-External' }
    Mock Start-Process { throw 'blocked by the test: Start-Process' }
    Mock Restart-Computer { throw 'blocked by the test: Restart-Computer' }
    $script:w = New-RepairWindow @{}
  }

  # Task 4: the run tests' seams and windows. $script:startChild records each start as @{ File; Args; Process } in
  # $script:started and returns a fake process (Id 4242, 4243, ...), also kept in $script:fake (the latest one).
  function Set-RunTestMocks {
    Set-RepairTestMocks
    $script:killed = New-Object Collections.ArrayList
    $script:order = New-Object Collections.Generic.List[string]   # Add returns nothing: a seam that records into it returns only its own value
    $script:shown = $null; $script:closingAtKill = $null
    Mock Stop-ProcessTree {
      [void]$script:killed.Add($ProcessId); [void]$script:order.Add("kill:$ProcessId")
      if ($null -ne $script:shown) { $script:closingAtKill = $script:shown.Tag.Closing } }
    $script:ToolboxChildren.Clear()
    $script:started = New-Object Collections.ArrayList
    $script:nextId = 4242; $script:fake = $null
    $script:startChild = { param($file, $arguments)
      $p = [pscustomobject]@{ Id = $script:nextId; HasExited = $false; ExitCode = 0 }; $script:nextId++; $script:fake = $p
      [void]$script:started.Add(@{ File = $file; Args = $arguments; Process = $p }); $p }
    $script:findStick = { param($l) @{ Root = 'E:\'; Drive = 'E:' } }
    $script:showArgs = @{ Machine = $script:m; Config = $script:cfg; Version = '2026.10.22.1'; Previous = $null; IsFresh = $false
      Root = "$TestDrive\Root"; ScriptPath = "$TestDrive\Root\setup.ps1"; OnAC = { $true }; AdminProtection = { 'Off' }
      WorkArea = { New-Object Windows.Rect 0, 0, 1920, 1040 }; Launcher = { $null }; FindStick = $script:findStick; StartChild = $script:startChild }
    # Get-SetupChoices' five parameters, Root and ScriptPath; every call passes its four seams by name (Toolbox.Tests'
    # seam guard reads the calls, not the splat).
    $script:choiceArgs = @{ Machine = $script:m; Config = $script:cfg; Version = '2026.10.22.1'; Previous = $null; IsFresh = $false
      Root = "$TestDrive\Root"; ScriptPath = 'x' }
  }
  # A window that can run actions: the sample model on -Page with a ready strip, stick E:, the setup files under
  # $TestDrive\Root, the recording seams, its handlers and a run timer that is never started.
  function New-RunWindow([string]$Page = 'repair', [hashtable]$Set = @{}) {
    $model = New-TestModel $Set; $model.Page = $Page
    $w = New-ToolboxWindow -Model $model -Machine $script:m -Config $script:cfg -Version '2026.10.22.1' -Root "$TestDrive\Root" -ScriptPath "$TestDrive\Root\setup.ps1" `
      -Launcher $null -StartChild $script:startChild -FindStick $script:findStick
    $w.Tag.RunTimer = New-ToolboxRunTimer -Window $w
    Register-ToolboxHandlers -Window $w
    $w
  }
  function Send-RunTick($w) { Invoke-ToolboxAction -Sender $w.Tag.RunTimer -Action 'RunTick' }
  # The child's files, as it writes them (UTF-8, through a .tmp file): Health check's progress with the disk state
  # done and the image check running at -Percent, and a result.
  function Write-TestProgress($w, [int]$Percent = 30, [string[]]$Status = @('done', 'running', 'pending')) {
    $run = $w.Tag.Runs.Action; $ids = @('volumeState', 'imageCheck', 'imageScan')
    $steps = @(for ($i = 0; $i -lt $Status.Count; $i++) { @{ Id = $ids[$i]; Status = $Status[$i]; Percent = $(if ($Status[$i] -eq 'running') { $Percent } else { $null }) } })
    $null = Write-ToolJsonFile -Path (Join-Path $run.Dir 'progress.json') -InputObject @{ Action = $run.ActionId; RunId = $run.RunId; State = 'running'; Current = 1; Steps = $steps
      Log = @('Disk state: started', 'Disk state: done', 'Windows image check: started'); Partial = @{}; UpdatedAt = '2026-10-22T10:16:00' }
  }
  function Write-TestResult($w, [string]$Outcome = 'Done', [string]$Color = 'GREEN', [string]$Slot = 'Action', [hashtable]$Data = @{}) {
    $run = $w.Tag.Runs[$Slot]
    $null = Write-ToolJsonFile -Path (Join-Path $run.Dir 'result.json') -InputObject @{ Action = $run.ActionId; RunId = $run.RunId; Outcome = $Outcome; Color = $Color
      Steps = @(@{ Id = 'volumeState'; Status = 'done'; Percent = $null }); Findings = @(@{ Level = 'WARN'; Code = 'sfcCorrupt'; Text = 'System files: 3 integrity problems found (nothing repaired yet)'; Args = @('3') })
      RestartRequired = $false; Offers = @{ DiskCheck = $false; DismSource = $null }; Files = @{ Folder = 'E:\BenTech-Reports\DESKTOP-4F7K2LQ_7HX2K93_2026-10-22_1015' }
      Data = $Data; StartedAt = '2026-10-22T10:15:00'; EndedAt = '2026-10-22T10:20:00' }
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

Describe 'action runs (spec 7, 4.3, 4.4)' {
  BeforeEach { Set-RunTestMocks }

  It 'starts the child hidden and without waiting, with the args the child reads' {
    $w = New-RunWindow; Start-ToolboxRun -Window $w -ActionId 'health' | Should -BeTrue
    @($script:started).Count | Should -Be 1
    $script:started[0].File | Should -BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
    $script:started[0].File | Should -BeExactly "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    $script:started[0].Args | Should -BeLike '-NoProfile -ExecutionPolicy Bypass -File "*\Root\setup.ps1" -ToolAction health -ToolArgs "*\Root\Tool\*-health\args.json"'
    $a = Read-ToolJsonFile (Get-ChildItem "$TestDrive\Root\Tool" -Recurse -Filter args.json).FullName; $a.Action | Should -Be 'health'; $a.Identity.Key | Should -Be 'SN-7HX2K93'
    $script:ToolboxChildren | Should -Contain $script:fake; @($w.Tag.Model.Repair.Run.Steps.Status | Select-Object -Unique) | Should -Be @('pending')
    # The run: its own folder named after its RunId, its process and its own Stopwatch.
    $run = $w.Tag.Runs.Action; $run.ActionId | Should -Be 'health'; $run.RunId | Should -Match '^\d{8}-\d{6}-health$'
    $run.Dir | Should -Be (Join-Path "$TestDrive\Root\Tool" $run.RunId); [object]::ReferenceEquals($run.Process, $script:fake) | Should -BeTrue
    $run.Clock | Should -BeOfType [Diagnostics.Stopwatch]; $run.Clock.IsRunning | Should -BeTrue; $run.BudgetSeconds | Should -Be 9000
    $w.Tag.Runs.Safety | Should -BeNullOrEmpty; $w.Tag.Model.Repair.Run.RunId | Should -Be $run.RunId
    $w.FindName('RunPanel').Visibility | Should -Be 'Visible'; $w.FindName('RunTitle').Text | Should -Be 'Health check' }
  It 'args.json is the Shared shape: the budget in seconds (RD-R8), the visit folder on the stick, the page''s state; the child''s own check accepts it' {
    $w = New-RunWindow -Set @{ Disk = 'warn' }
    $w.Tag.Model.Repair.Complaint = 'Slow since the update'
    $w.Tag.Model.Repair.Done = @(@{ Action = 'health'; Outcome = 'Done'; Color = 'GREEN'; EndedAt = '2026-10-22T10:10:00' })
    $null = Start-ToolboxRun -Window $w -ActionId 'health' -Options @{ Answer = 42 }
    $argsPath = Join-Path $w.Tag.Runs.Action.Dir 'args.json'; $a = Read-ToolJsonFile $argsPath
    $a.Version | Should -Be 1; $a.RunId | Should -Be $w.Tag.Runs.Action.RunId; $a.BudgetSeconds | Should -Be 9000   # timeoutsMinutes.tool.health = 150
    $deadline = [datetime]::Parse($a.DeadlineUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    ($deadline.ToUniversalTime() - [datetime]::UtcNow).TotalMinutes | Should -BeGreaterThan 148   # for the child's log only
    $a.SessionDir | Should -BeExactly ('E:\BenTech-Reports\DESKTOP-4F7K2LQ_7HX2K93_' + $w.Tag.Model.Repair.SessionStamp); $a.StickRoot | Should -BeExactly 'E:\'
    $a.Complaint | Should -BeExactly 'Slow since the update'; @($a.Done).Count | Should -Be 1; $a.Done[0].Action | Should -Be 'health'
    $a.Identity.FolderPart | Should -Be '7HX2K93'; $a.Identity.Serial | Should -Be '7HX2K93'; $a.Identity.ComputerName | Should -Be 'DESKTOP-4F7K2LQ'
    $a.Identity.Brand | Should -Be 'DELL'; $a.Identity.Model | Should -Be 'Latitude 5440'; $a.Identity.Manufacturer | Should -Be 'Dell Inc.'
    $a.Machine.IsLaptop | Should -BeTrue; $a.Machine.OsBuild | Should -Be 26200
    $a.Strip.Disk | Should -Be 'warn'; $a.Strip.Restart | Should -Be 'ok'; $a.Strip.Free | Should -Be 'ok'; $a.Options.Answer | Should -Be 42
    (Read-ToolArgs -Path $argsPath -Root "$TestDrive\Root" -ActionId 'health').BudgetSeconds | Should -Be 9000 }
  It 'an action without a configured deadline gets 30 minutes; no stick puts the visit folder under Root\Logs\Repair; a strip not read yet is unknown' {
    $w = New-RunWindow -Set @{ Stick = $null; State = 'loading'; Disk = $null }
    $c = $script:cfg | ConvertTo-Json -Depth 12 | ConvertFrom-Json; $c.timeoutsMinutes.tool.PSObject.Properties.Remove('health'); $w.Tag.Config = $c
    $null = Start-ToolboxRun -Window $w -ActionId 'health'
    $a = Read-ToolJsonFile (Join-Path $w.Tag.Runs.Action.Dir 'args.json')
    $a.BudgetSeconds | Should -Be 1800; $w.Tag.Runs.Action.BudgetSeconds | Should -Be 1800; $a.StickRoot | Should -BeExactly ''; $a.Strip.Disk | Should -Be 'unknown'
    $a.SessionDir | Should -BeExactly (Join-Path "$TestDrive\Root\Logs\Repair" ('DESKTOP-4F7K2LQ_7HX2K93_' + $w.Tag.Model.Repair.SessionStamp)) }
  It 'the visit folder''s name keeps only letters, digits and dashes of the PC name and the serial (spec 8, RD-R6)' {
    $w = New-RunWindow; $w.Tag.Machine = $w.Tag.Machine.Clone(); $w.Tag.Machine.ComputerName = 'PC_' + [char]0x05D0 + ' 1'; $w.Tag.Machine.Serial = 'AB 12/34'
    Get-ToolboxSessionDir -State $w.Tag | Should -BeExactly ('E:\BenTech-Reports\PC1_AB1234_' + $w.Tag.Model.Repair.SessionStamp) }
  It 'refuses a busy slot, a window without its setup files and an action this version does not have: nothing starts' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'
    Start-ToolboxRun -Window $w -ActionId 'health' | Should -BeFalse
    $n = New-RunWindow; $n.Tag.ScriptPath = ''; Start-ToolboxRun -Window $n -ActionId 'health' | Should -BeFalse
    $n.Tag.Root = ''; $n.Tag.ScriptPath = "$TestDrive\Root\setup.ps1"; Start-ToolboxRun -Window $n -ActionId 'health' | Should -BeFalse
    $u = New-RunWindow; Start-ToolboxRun -Window $u -ActionId 'noSuchAction' | Should -BeFalse
    @($script:started).Count | Should -Be 1; $n.Tag.Model.Repair.Run | Should -BeNullOrEmpty; $u.Tag.Model.Repair.Run | Should -BeNullOrEmpty; $n.Tag.Runs.Action | Should -BeNullOrEmpty
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -like 'Toolbox action refused*' }).Count | Should -Be 4 }
  It 'a child that cannot start is a red Failed result with childStartFailed in ASCII; the strip is read again' {
    $w = New-RunWindow
    $w.Tag.StartChild = { param($file, $arguments) if ($arguments -match '-ToolAction health') { throw ('no powershell ' + [char]0x05D0) }; & $script:startChild $file $arguments }
    Start-ToolboxRun -Window $w -ActionId 'health' | Should -BeFalse
    $res = $w.Tag.Model.Repair.Result; $res.Outcome | Should -Be 'Failed'; $res.Color | Should -Be 'RED'; $res.Action | Should -Be 'health'
    $res.Findings[0].Code | Should -Be 'childStartFailed'; @($res.Findings[0].Args) | Should -Be @('no powershell ?')
    $w.Tag.Runs.Action | Should -BeNullOrEmpty; $w.Tag.Model.Repair.Run | Should -BeNullOrEmpty; $w.FindName('ResultPanel').Visibility | Should -Be 'Visible'
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox action could not start' }).Count | Should -Be 1
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox action finished' -and $_.Data.outcome -eq 'Failed' }).Count | Should -Be 1
    $script:started[-1].Args | Should -Match '-ToolAction safety'; $w.Tag.Model.Repair.Strip.State | Should -Be 'loading'
    ($script:logs | ConvertTo-Json -Depth 5) | Should -Not -Match '[^\x00-\x7F]' }
  It 'a run folder that is already there is never reused: a stale result in it is never read' {
    Mock New-ToolboxRunId { '20261022-101500-health' }
    $dir = "$TestDrive\Root\Tool\20261022-101500-health"; $null = New-Item -ItemType Directory -Path $dir -Force
    [IO.File]::WriteAllText("$dir\result.json", '{"Action":"health","Outcome":"Done","Color":"GREEN"}')
    $w = New-RunWindow; Start-ToolboxRun -Window $w -ActionId 'health' | Should -BeFalse
    $w.Tag.Model.Repair.Result.Outcome | Should -Be 'Failed'; $w.Tag.Model.Repair.Result.Findings[0].Code | Should -Be 'childStartFailed'
    @($script:started | Where-Object { $_.Args -match '-ToolAction health' }).Count | Should -Be 0; Test-Path "$dir\args.json" | Should -BeFalse }
  It 'the same action started again within the second gets the next second''s run folder' {
    $script:ids = @('20261022-111500-health', '20261022-111500-health', '20261022-111501-health'); $script:idCall = 0
    Mock New-ToolboxRunId { if ($ActionId -eq 'health') { $script:ids[$script:idCall++] } else { '20261022-111500-safety' } }
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'; $w.Tag.Runs.Action.RunId | Should -Be '20261022-111500-health'
    $script:fake.HasExited = $true; Send-RunTick $w   # it ended at once (no result); the strip's child starts
    Start-ToolboxRun -Window $w -ActionId 'health' | Should -BeTrue; $w.Tag.Runs.Action.RunId | Should -Be '20261022-111501-health'
    (Read-ToolJsonFile (Join-Path $w.Tag.Runs.Action.Dir 'args.json')).RunId | Should -Be '20261022-111501-health' }
  It 'polls progress into the run panel and ends on the result, with one ASCII log line' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'; $proc = $script:fake
    Write-TestProgress $w -Percent 30; Send-RunTick $w
    $w.FindName('RunBar').Value | Should -Be 30; $w.FindName('RunLog').Text | Should -Match 'Windows image check: started'
    @($w.Tag.Model.Repair.Run.Steps.Status) | Should -Be @('done', 'running', 'pending'); $w.Tag.Runs.Action | Should -Not -BeNullOrEmpty
    Write-TestResult $w; $proc.HasExited = $true; Send-RunTick $w
    $w.Tag.Model.Repair.Result.Outcome | Should -Be 'Done'; @($script:logs | Where-Object Message -eq 'Toolbox action finished').Count | Should -Be 1
    $script:started[-1].Args | Should -Match '-ToolAction safety'; ($script:logs | ConvertTo-Json -Depth 5) | Should -Not -Match '[^\x00-\x7F]'
    $w.Tag.Runs.Action | Should -BeNullOrEmpty; $w.Tag.Model.Repair.Run | Should -BeNullOrEmpty; $script:ToolboxChildren | Should -Not -Contain $proc
    $w.FindName('ResultPanel').Visibility | Should -Be 'Visible'; @($w.Tag.Model.Repair.Done).Count | Should -Be 1; $w.Tag.Model.Repair.Done[0].Color | Should -Be 'GREEN'
    $line = @($script:logs | Where-Object Message -eq 'Toolbox action finished')[0]
    $line.Level | Should -Be 'INFO'; $line.Data.action | Should -Be 'health'; $line.Data.runId | Should -Be $w.Tag.Model.Repair.Result.RunId
    $line.Data.outcome | Should -Be 'Done'; $line.Data.color | Should -Be 'GREEN'; @($line.Data.findings) | Should -Be @('sfcCorrupt'); $line.Data.minutes | Should -BeOfType [double]
    $w.Tag.Runs.Safety.ActionId | Should -Be 'safety'; $w.Tag.Model.Repair.Strip.State | Should -Be 'loading'; $script:ToolboxChildren | Should -Contain $script:fake }
  It 'kills the tree past the deadline and reports Timed out (red) with what was done' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'; $proc = $script:fake; Write-TestProgress $w; Send-RunTick $w
    Mock Get-ToolboxRunSeconds { 150 * 60 + 181 }   # the run's own Stopwatch, past the budget + 3 min (RD-R9)
    Invoke-ToolboxAction -Sender $w.Tag.RunTimer -Action 'RunTick'
    $script:killed | Should -Be @(4242); $w.Tag.Model.Repair.Result.Color | Should -Be 'RED'; $w.Tag.Model.Repair.Result.Steps.Status | Should -Be @('done','timedout','skipped')
    $res = $w.Tag.Model.Repair.Result; $res.Outcome | Should -Be 'TimedOut'; $res.Findings[0].Code | Should -Be 'actionTimedOut'; @($res.Findings[0].Args) | Should -Be @('150')
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox action killed at its deadline' }).Count | Should -Be 1
    $w.Tag.Runs.Action | Should -BeNullOrEmpty; $script:ToolboxChildren | Should -Not -Contain $proc; $w.FindName('ResultPanel').Visibility | Should -Be 'Visible'
    @($script:logs | Where-Object { $_.Message -eq 'Toolbox action finished' -and $_.Data.outcome -eq 'TimedOut' }).Count | Should -Be 1 }
  It 'the deadline is budget + 3 minutes on the run''s own Stopwatch, never the wall clock (RD-R8, RD-R9)' {
    $clock = [Diagnostics.Stopwatch]::StartNew(); $s = Get-ToolboxRunSeconds -Run @{ Clock = $clock }; $s | Should -BeGreaterOrEqual 0; $s | Should -BeLessThan 60
    Get-ToolboxRunSeconds -Run @{} | Should -Be 0
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'
    $w.Tag.Runs.Action.DeadlineUtc = [datetime]::UtcNow.AddHours(-5).ToString('o')   # the wall clock moved (a time sync): no kill
    $w.Tag.Runs.Action.StartedUtc = [datetime]::UtcNow.AddHours(-5).ToString('o')
    Send-RunTick $w; $script:killed | Should -BeNullOrEmpty
    Mock Get-ToolboxRunSeconds { 150 * 60 + 179 }; Send-RunTick $w; $script:killed | Should -BeNullOrEmpty   # 2 min 59 s over: the child may still be ending
    Mock Get-ToolboxRunSeconds { 150 * 60 + 181 }; Send-RunTick $w; $script:killed | Should -Be @(4242) }
  It 'the elapsed time shown comes from the same Stopwatch' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'
    Mock Get-ToolboxRunSeconds { 754 }; Send-RunTick $w
    $w.Tag.Model.Repair.Run.ElapsedSeconds | Should -Be 754; $w.FindName('RunElapsed').Text | Should -Be 'Elapsed 12:34' }
  It 'a child that exits without a result is Failed with childNoResult' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'; $script:fake.HasExited = $true; $script:fake.ExitCode = 1
    Invoke-ToolboxAction -Sender $w.Tag.RunTimer -Action 'RunTick'; $res = $w.Tag.Model.Repair.Result
    $res.Outcome | Should -Be 'Failed'; $res.Color | Should -Be 'RED'; $res.Findings[0].Code | Should -Be 'childNoResult'; $res.Findings[0].Args | Should -Be @('1')
    @($res.Steps.Status | Select-Object -Unique) | Should -Be @('skipped'); $script:killed | Should -BeNullOrEmpty
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox action ended without a result' }).Count | Should -Be 1 }
  It 'Stop writes the flag and never kills (only between steps)' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'; Write-TestProgress $w; Send-RunTick $w
    Click $w 'StopButton'; Test-Path "$($w.Tag.Runs.Action.Dir)\stop.flag" | Should -BeTrue; $script:killed | Should -BeNullOrEmpty; $w.FindName('StopButton').IsEnabled | Should -BeFalse
    $w.FindName('StoppingText').Text | Should -BeExactly ($script:ToolboxStrings.en['run.stopping'] -f $script:ToolboxStrings.en['tool.step.imageCheck'])
    Send-RunTick $w; $w.Tag.Model.Repair.Run.Stopping | Should -BeTrue; $w.FindName('StopButton').IsEnabled | Should -BeFalse; $w.Tag.Runs.Action | Should -Not -BeNullOrEmpty
    $idle = New-RunWindow; { Click $idle 'StopButton' } | Should -Not -Throw; $idle.Tag.Outcome | Should -BeNullOrEmpty
    @(Get-ChildItem "$TestDrive\Root\Tool" -Recurse -Filter stop.flag).Count | Should -Be 1 }
  It 'X, Alt+F4 and Cancel are refused while an action runs' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'; $proc = $script:fake
    $w.Close(); $w.Tag.Outcome | Should -BeNullOrEmpty; $w.Tag.Closing | Should -BeFalse; $w.FindName('CloseRefusedText').Visibility | Should -Be 'Visible'
    Click $w 'CloseButton'; $w.Tag.Outcome | Should -BeNullOrEmpty
    Click $w 'CancelButton'; $w.Tag.Outcome | Should -BeNullOrEmpty; $w.Tag.Closing | Should -BeFalse
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Close refused: an action is running' }).Count | Should -Be 3
    # Once the action has ended the window closes again; the safety child that then starts does not hold it.
    Write-TestResult $w; $proc.HasExited = $true; Send-RunTick $w; $w.Tag.Model.Repair.CloseRefused | Should -BeFalse; $w.Tag.Runs.Safety | Should -Not -BeNullOrEmpty
    $w.Close(); $w.Tag.Outcome | Should -Be 'Cancel'; $w.Tag.Closing | Should -BeTrue }
  It 'a running safety child does not block closing, and is killed with the window' {
    $w = New-RunWindow; Start-ToolboxRun -Window $w -ActionId 'safety' -Slot Safety | Should -BeTrue; $w.Close(); $w.Tag.Outcome | Should -Be 'Cancel'
    $script:ToolboxChildren.Clear()
    $r = Show-ToolboxWindow @showArgs -ShowDialog { param($w) $null = Start-ToolboxRun -Window $w -ActionId 'safety' -Slot Safety; $w.Close() }
    $r.Outcome | Should -Be 'Cancel'; $script:killed | Should -Be @(4243); $script:ToolboxChildren.Count | Should -Be 0 }
  It 'Start, the nav and Restart PC are refused while an action runs' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'
    Click $w 'StartButton'; $w.Tag.Outcome | Should -BeNullOrEmpty; $w.FindName('NavSetup').IsChecked = $true; Click $w 'NavSetup'; $w.Tag.Model.Page | Should -Be 'repair'
    Click $w 'RestartButton'; $w.Tag.Model.Repair.Confirm | Should -BeNullOrEmpty; Click $w 'ChipRestartButton'; $w.Tag.Model.Repair.Confirm | Should -BeNullOrEmpty
    $w.FindName('NavSetup').IsChecked | Should -BeFalse; $w.FindName('NavRepair').IsChecked | Should -BeTrue; $w.Tag.Closing | Should -BeFalse
    foreach ($msg in 'Start refused: an action is running', 'Page change refused: an action is running', 'Restart refused: an action is running') {
      @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq $msg }).Count | Should -BeGreaterThan 0 -Because $msg } }
  It 'Restart PC asks first; Cancel closes the question, Confirm closes the window as Restart' {
    $w = New-RunWindow; Click $w 'RestartButton'
    $w.Tag.Model.Repair.Confirm.Kind | Should -Be 'restart'; $w.FindName('ConfirmPanel').Visibility | Should -Be 'Visible'
    $w.FindName('ConfirmTitle').Text | Should -Be 'Restart this PC now?'; $w.FindName('ConfirmButton').IsEnabled | Should -BeTrue; $w.Tag.Outcome | Should -BeNullOrEmpty
    Click $w 'ConfirmCancelButton'; $w.Tag.Model.Repair.Confirm | Should -BeNullOrEmpty; $w.FindName('ConfirmPanel').Visibility | Should -Be 'Collapsed'; $w.Tag.Outcome | Should -BeNullOrEmpty
    Click $w 'ChipRestartButton'; Click $w 'ConfirmButton'; $w.Tag.Outcome | Should -Be 'Restart'; $w.Tag.Closing | Should -BeTrue }
  It 'a Restart question opened before an action started cannot be confirmed while it runs' {
    $w = New-RunWindow; Click $w 'RestartButton'; $null = Start-ToolboxRun -Window $w -ActionId 'health'
    Click $w 'ConfirmButton'; $w.Tag.Outcome | Should -BeNullOrEmpty; $w.Tag.Closing | Should -BeFalse }
  It 'a Failed window closes even while a child runs' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'
    Close-ToolboxWindow -Window $w -Outcome Failed -ErrorText 'x'; $w.Tag.Closing | Should -BeTrue; $w.Tag.Outcome | Should -Be 'Failed' }
  It 'a tick that throws closes the window as Failed, never thrown' {
    $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'; Mock Update-RepairRunModel { throw 'tick broke' }
    { Send-RunTick $w } | Should -Not -Throw; $w.Tag.Outcome | Should -Be 'Failed'; $w.Tag.Error | Should -BeExactly 'tick broke'; $w.Tag.Closing | Should -BeTrue }
  It 'the run timer ticks every 500 ms; with nothing running a tick does nothing, and a tick renders the repair page only' {
    $w = New-RunWindow; $t = New-ToolboxRunTimer -Window $w; $t.Interval.TotalMilliseconds | Should -Be 500; [object]::ReferenceEquals($t.Tag, $w) | Should -BeTrue; $t.IsEnabled | Should -BeFalse
    Mock Update-RepairView { }; Send-RunTick $w; Should -Invoke Update-RepairView -Times 0 -Exactly
    $null = Start-ToolboxRun -Window $w -ActionId 'health'; Mock Update-ToolboxView { throw 'not the whole window every 500 ms' }
    Send-RunTick $w; $w.Tag.Outcome | Should -BeNullOrEmpty; Should -Invoke Update-RepairView -Times 2 -Exactly }   # the start, then the tick
  It 'the safety child fills the strip chip by chip and makes it ready at the end; it is no action' {
    $w = New-RunWindow -Set @{ State = 'loading'; Restart = $null; Free = $null; BitLocker = $null; Internet = $null; Disk = $null }
    Start-ToolboxRun -Window $w -ActionId 'safety' -Slot Safety | Should -BeTrue; $w.Tag.Model.Repair.Run | Should -BeNullOrEmpty; $run = $w.Tag.Runs.Safety
    $run.BudgetSeconds | Should -Be 180
    $null = Write-ToolJsonFile -Path (Join-Path $run.Dir 'progress.json') -InputObject @{ Action = 'safety'; RunId = $run.RunId; State = 'running'; Current = 1; Steps = @(); Log = @()
      Partial = @{ Chips = @{ Restart = @{ Level = 'ok'; Args = @(); Detail = @{} } } } }
    Send-RunTick $w; $w.FindName('ChipRestartText').Text | Should -Be 'No restart pending'; $w.FindName('ChipDiskText').Text | Should -Be 'Checking...'
    $w.Tag.Model.Repair.Strip.State | Should -Be 'loading'
    $chips = @{ Restart = @{ Level = 'ok' }; Free = @{ Level = 'ok'; Args = @('C:', '41') }; BitLocker = @{ Level = 'ok' }; Internet = @{ Level = 'ok' }; Disk = @{ Level = 'warn' } }
    Write-TestResult $w -Slot Safety -Data @{ Chips = $chips; DiskCheck = @{ Dirty = $false; Excluded = $false } }; $script:fake.HasExited = $true; Send-RunTick $w
    $w.Tag.Model.Repair.Strip.State | Should -Be 'ready'; $w.Tag.Model.Repair.Strip.Disk.Level | Should -Be 'warn'; $w.FindName('ChipDiskText').Text | Should -Be 'Disk: check'
    $w.Tag.Model.Repair.DiskCheck.Dirty | Should -BeFalse; $w.Tag.Runs.Safety | Should -BeNullOrEmpty; $script:ToolboxChildren.Count | Should -Be 0
    $w.Tag.Model.Repair.Result | Should -BeNullOrEmpty; @($script:logs | Where-Object Message -eq 'Toolbox action finished').Count | Should -Be 0 }
  It 'a safety child killed at its deadline, or gone without a result, keeps the chips it read and leaves the rest unknown (spec 5)' {
    foreach ($case in 'deadline', 'noResult') {
      $script:killed.Clear()
      $w = New-RunWindow -Set @{ State = 'loading'; Restart = $null; Free = $null; BitLocker = $null; Internet = $null; Disk = $null }
      $null = Start-ToolboxRun -Window $w -ActionId 'safety' -Slot Safety; $run = $w.Tag.Runs.Safety
      $null = Write-ToolJsonFile -Path (Join-Path $run.Dir 'progress.json') -InputObject @{ Action = 'safety'; RunId = $run.RunId; State = 'running'; Current = 4; Steps = @(); Log = @()
        Partial = @{ Chips = @{ Restart = @{ Level = 'ok'; Args = @(); Detail = @{} } } } }
      Send-RunTick $w
      if ($case -eq 'deadline') { Mock Get-ToolboxRunSeconds { 3 * 60 + 181 } } else { $script:fake.HasExited = $true }
      Send-RunTick $w
      $script:killed.Count | Should -Be $(if ($case -eq 'deadline') { 1 } else { 0 }) -Because $case
      $s = $w.Tag.Model.Repair.Strip; $s.State | Should -Be 'ready'; $s.Restart.Level | Should -Be 'ok'; $s.Disk.Level | Should -Be 'unknown' -Because $case
      $w.FindName('TileStandard').IsEnabled | Should -BeTrue -Because 'an unknown chip blocks nothing'; $w.Tag.Runs.Safety | Should -BeNullOrEmpty
      Mock Get-ToolboxRunSeconds { 0 } }
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox action killed at its deadline' -and $_.Data.action -eq 'safety' }).Count | Should -Be 1
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Toolbox action ended without a result' -and $_.Data.action -eq 'safety' }).Count | Should -Be 1 }
}

Describe 'Show-ToolboxWindow and Get-SetupChoices with children' {
  BeforeEach { Set-RunTestMocks }

  It 'Show-ToolboxWindow kills its children before it closes the window' {   # the ShowDialog seam starts a run and returns; Stop-ProcessTree records whether the window was already closing
    $r = Show-ToolboxWindow @showArgs -ShowDialog { param($w) $script:shown = $w; $null = Start-ToolboxRun -Window $w -ActionId 'health' }
    $r.Outcome | Should -Be 'Failed'; $script:killed | Should -Be @(4242); $script:closingAtKill | Should -BeFalse; $script:shown.Tag.Closing | Should -BeTrue
    $script:ToolboxChildren.Count | Should -Be 0; $script:shown.Tag.RunTimer.IsEnabled | Should -BeFalse }
  It 'the window it shows can run actions: Root, ScriptPath, CanRun, the seams, the launcher and the 500 ms run timer' {
    $a = $script:showArgs.Clone(); $a.Launcher = { @{ Path = 'E:\BenTechSetup.cmd'; Drive = 'E:'; VolumeSerial = '1A2B3C4D' } }
    $r = Show-ToolboxWindow @a -ShowDialog { param($w) $script:shown = $w
      $script:seen = @{ Timer = $w.Tag.RunTimer.IsEnabled; Interval = $w.Tag.RunTimer.Interval.TotalMilliseconds; CanRun = $w.Tag.Model.Repair.CanRun }; $w.Close() }
    $r.Outcome | Should -Be 'Cancel'; $script:seen.Timer | Should -BeTrue; $script:seen.Interval | Should -Be 500; $script:seen.CanRun | Should -BeTrue
    $t = $script:shown.Tag; $t.Root | Should -Be "$TestDrive\Root"; $t.ScriptPath | Should -Be "$TestDrive\Root\setup.ps1"; $t.Launcher.VolumeSerial | Should -Be '1A2B3C4D'
    [object]::ReferenceEquals($t.StartChild, $script:startChild) | Should -BeTrue; [object]::ReferenceEquals($t.FindStick, $script:findStick) | Should -BeTrue
    $t.RunTimer.IsEnabled | Should -BeFalse; $t.Runs.Action | Should -BeNullOrEmpty
    $n = $script:showArgs.Clone(); $n.Root = ''; $n.Launcher = { throw ('no launcher ' + [char]0x05D0) }
    $r2 = Show-ToolboxWindow @n -ShowDialog { param($w) $script:shown = $w; $w.Close() }
    $r2.Outcome | Should -Be 'Cancel'; $script:shown.Tag.Model.Repair.CanRun | Should -BeFalse; $script:shown.Tag.Launcher | Should -BeNullOrEmpty
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Could not read the launcher for the toolbox' -and $_.Data.error -eq 'no launcher ?' }).Count | Should -Be 1 }
  It 'Restart PC is the window''s fourth outcome' {
    $r = Show-ToolboxWindow @showArgs -ShowDialog { param($w) Click $w 'RestartButton'; Click $w 'ConfirmButton' }
    $r.Outcome | Should -Be 'Restart'; $r.Choices | Should -BeNullOrEmpty }
  It 'a window that fails while a child runs kills it before the shutdown, the console and the cleanup (Review Focus 2)' {
    $script:fake = [pscustomobject]@{ Id = 4242; HasExited = $false; ExitCode = 0 }
    $r = Get-SetupChoices -Machine $m -Config $cfg -Version 'v' -Previous $null -IsFresh $false -Root "$TestDrive\Root" -ScriptPath 'x' -TestHost { @{ Ok = $true } } `
      -ShowToolbox { param($p) $script:ToolboxChildren.Add($script:fake); @{ Outcome = 'Failed'; Error = 'boom' } } -ShowConsole { param($p) $script:order.Add('console'); $null } -ShutdownDispatcher { $script:order.Add('shutdown') }
    $script:order | Should -Be @('kill:4242','shutdown','console'); $r | Should -BeNullOrEmpty; $script:ToolboxChildren.Count | Should -Be 0 }
  It 'Restart returns $null and records the request; Cancel does not' {
    Get-SetupChoices @choiceArgs -TestHost { @{ Ok = $true } } -ShowToolbox { param($p) @{ Outcome = 'Restart' } } -ShowConsole { param($p) throw 'must not open' } -ShutdownDispatcher { } |
      Should -BeNullOrEmpty
    Get-ToolboxRestartRequest | Should -BeTrue
    @($script:logs | Where-Object { $_.Level -eq 'INFO' -and $_.Message -eq 'Toolbox closed' -and $_.Data.outcome -eq 'Restart' }).Count | Should -Be 1
    Get-SetupChoices @choiceArgs -TestHost { @{ Ok = $true } } -ShowToolbox { param($p) @{ Outcome = 'Cancel' } } -ShowConsole { param($p) throw 'must not open' } -ShutdownDispatcher { } |
      Should -BeNullOrEmpty
    Get-ToolboxRestartRequest | Should -BeFalse
    $script:ToolboxRestartRequested = $true   # a request left from an earlier call is forgotten when the console answers too
    Get-SetupChoices @choiceArgs -TestHost { @{ Ok = $false; Reason = 'session 0' } } -ShowToolbox { param($p) throw 'must not open' } -ShowConsole { param($p) $null } -ShutdownDispatcher { } |
      Should -BeNullOrEmpty
    Get-ToolboxRestartRequest | Should -BeFalse }
  It 'the console still gets exactly Show-StartScreen''s parameters; the window gets Root and ScriptPath' {
    $null = Get-SetupChoices @choiceArgs -TestHost { @{ Ok = $true } } -ShowToolbox { param($p) $script:toolboxArgs = $p; @{ Outcome = 'Failed'; Error = 'x' } } `
      -ShowConsole { param($p) $script:consoleArgs = $p; $null } -ShutdownDispatcher { }
    @($script:consoleArgs.Keys | Sort-Object) | Should -Be @('Config','IsFresh','Machine','NoAutoStart','Previous','Version'); $script:toolboxArgs.Root | Should -Be "$TestDrive\Root"
    $script:toolboxArgs.ScriptPath | Should -Be 'x'; $script:toolboxArgs.Contains('NoAutoStart') | Should -BeFalse }
}
