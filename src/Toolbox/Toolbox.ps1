# src/Toolbox/Toolbox.ps1
# The BenTech Toolbox window (toolbox spec 4 and 5): a dark WPF window that replaces the console start screen.
# Ben picks a profile, adjusts the options, the tweaks and the restore point, in English or Hebrew; the right-hand
# column always shows what will happen.
#
# This file builds and renders the window: the string table the window reads (New-ToolboxStringTable,
# Get-ToolboxString), the window itself (New-ToolboxWindow, which parses Xaml.ps1's $script:ToolboxXaml), the
# language walk (Set-ToolboxLanguage) and the view (Update-ToolboxView), which renders the pure model of
# SetupPlanner.ps1.
#
# And it runs the window (Task 3): the handlers (Register-ToolboxHandlers), the one function every handler calls
# (Invoke-ToolboxAction: the model changes through Update-ToolboxModel, then the view follows), the outcome
# (Close-ToolboxWindow: Start, Cancel or Failed; a failure is never read as Cancel), the dispatcher backstop
# (Invoke-ToolboxUnhandled), the work-area clamp (Set-ToolboxWindowSize), the power timer (New-ToolboxPowerTimer)
# and the dialog itself (Show-ToolboxWindow, which never throws and shows the window only through its -ShowDialog
# seam).
#
# And the seam (Task 4): Test-ToolboxHost (can this process show a WPF window at all?) and Get-SetupChoices, which
# Main.ps1 calls where it called Show-StartScreen: the window, or the console start screen when the host check or
# the window fails (with -NoAutoStart: it waits for Enter, ruling TB-R8), with the same parameters and the same
# return contract (Choices, or $null for Cancel). It is also the one place that stops WPF once the window is gone.
#
# The WPF rules (spec 5.1; the plan's Global Constraints), which every later addition keeps:
#   - The window's state lives in $window.Tag (the plan's "Toolbox model and window state"). Every handler is one
#     line, { Invoke-ToolboxAction -Sender $this }: no closures over outer variables.
#   - Every .NET call's output goes to $null, so every function returns exactly one value or nothing.
#   - Start is never the default button (IsDefault False, Focusable False) and Esc is unbound: the XAML has no
#     IsCancel, no key bindings, no event attributes and no x:Class.
#   - All colours are hex values in the one <Window.Resources> dictionary; the font sizes are resources there too.
#     Text is Segoe UI, icons are glyphs from "Segoe Fluent Icons, Segoe MDL2 Assets" (so they also show on
#     Windows 10). No image files, nothing downloaded; the "B" logo is drawn.
#   - Every visible text is a TextBlock. Fixed texts carry Tag="t:<key>" and come from the string table; a
#     clickable element carries Tag="a:<Action>:<Value>" (Task 3 reads it). The two kinds never meet on one element.
#   - Hebrew turns the window right-to-left; the machine values stay left-to-right. The plan rows follow the
#     language: their step names are the string table's step.<id> (ruling TB-R5), while the console, setup.log and
#     the report keep the catalog's English titles.
#   - Nothing here writes to the console (no Write-Host) or sleeps. setup.log gets English ASCII only: every
#     exception message and every free value goes through ConvertTo-ScreenText first.
#   - Only Show-ToolboxWindow's -ShowDialog default opens the window as a dialog, and only Get-SetupChoices'
#     -ShutdownDispatcher default stops WPF; no test does either (both are seams, and a static test pins that).
#
# Needs: Toolbox\Strings.ps1 ($script:ToolboxStrings), Toolbox\Xaml.ps1 ($script:ToolboxXaml),
# Toolbox\SetupPlanner.ps1 (Get-SetupProfiles, New-ToolboxModel, Update-ToolboxModel, ConvertTo-ValidChoices,
# Get-ToolboxPlanLines), Engine\Catalog.ps1 (Get-TweakCatalog, Test-TweakAllowed, Get-RemoteChoice,
# Get-WindowsUpdateChoice, $script:StepCatalog), UI\StartScreen.ps1 (Format-PreviousRun, ConvertTo-ScreenText, and
# Show-StartScreen: Get-SetupChoices' console fallback), Common\Logging.ps1
# (Write-SetupLog), Detect\Detection.ps1 (Test-OnACPower, Test-AdminProtection: Show-ToolboxWindow's seam
# defaults) and WPF (PresentationFramework, PresentationCore, WindowsBase), loaded by the caller. The bundle holds
# every file.

# The window that is open, for the dispatcher backstop only: the dispatcher's event has no window (the plan's one
# exception to "no outer variables"). Show-ToolboxWindow sets it around the dialog and clears it after.
$script:ToolboxOpenWindow = $null

# Display problems already logged (TB-R7): the window redraws on every click and every power tick, so the same
# problem is logged once, not on every redraw. Diagnostics only; no decision depends on it.
$script:ToolboxWarned = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)

function Write-ToolboxWarningOnce {
  # Private. One WARN line in setup.log per -Id for the life of the process. The caller passes ASCII text. Never
  # throws (Write-SetupLog never does once its arguments bind).
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Message,
    [hashtable]$Data
  )

  if ($script:ToolboxWarned.Add($Id)) { Write-SetupLog -Level WARN -Message $Message -Data $Data }
}

function New-ToolboxStringTable {
  <#
  .SYNOPSIS
    The window's string table: @{ en = hashtable; he = hashtable }, the same keys in both. Never throws.
  .DESCRIPTION
    A copy of $script:ToolboxStrings plus the keys built from config.json: profile.<id> (the profile's name),
    tweak.<id>.title and tweak.<id>.desc (Get-SetupProfiles, Get-TweakCatalog). A missing Hebrew text takes the
    English one. A catalog step without a step.<id> name in Strings.ps1 takes the catalog's English Title.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Config)

  $en = @{}
  $he = @{}
  foreach ($key in $script:ToolboxStrings.en.Keys) { $en[$key] = $script:ToolboxStrings.en[$key] }
  foreach ($key in $script:ToolboxStrings.he.Keys) { $he[$key] = $script:ToolboxStrings.he[$key] }
  foreach ($step in $script:StepCatalog) {
    $key = "step.$($step.Id)"
    foreach ($table in $en, $he) { if ([string]::IsNullOrWhiteSpace([string]$table[$key])) { $table[$key] = $step.Title } }
  }

  $fromConfig = New-Object System.Collections.Generic.List[object]
  foreach ($p in @(Get-SetupProfiles -Config $Config)) { $fromConfig.Add(@("profile.$($p.Id)", $p.Name)) }
  foreach ($t in @(Get-TweakCatalog -Config $Config)) {
    $fromConfig.Add(@("tweak.$($t.Id).title", $t.Title))
    $fromConfig.Add(@("tweak.$($t.Id).desc", $t.Description))
  }
  foreach ($entry in $fromConfig) {
    $key = $entry[0]; $text = $entry[1]
    $en[$key] = [string]$text.en
    $he[$key] = $(if ([string]::IsNullOrWhiteSpace([string]$text.he)) { [string]$text.en } else { [string]$text.he })
  }
  return @{ en = $en; he = $he }
}

function Get-ToolboxString {
  <#
  .SYNOPSIS
    One text of the string table in a language, formatted with -Arguments. Never throws.
  .DESCRIPTION
    The language's text, else the English one, else the key itself (so a missing key shows on screen instead of
    an empty space). A text that does not format with the arguments is returned unformatted, and logged once per
    key (WARN 'Toolbox text could not be formatted').
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()][hashtable]$Table,
    [AllowNull()][AllowEmptyString()][string]$Language,
    [AllowNull()][AllowEmptyString()][string]$Key,
    [AllowNull()][object[]]$Arguments
  )

  $text = [string]$Key
  try {
    if ($null -ne $Table -and -not [string]::IsNullOrEmpty($Key)) {
      foreach ($lang in @($Language, 'en')) {
        if ([string]::IsNullOrEmpty($lang)) { continue }
        $part = $Table[$lang]
        if ($part -is [System.Collections.IDictionary] -and $part.Contains($Key) -and -not [string]::IsNullOrEmpty([string]$part[$Key])) {
          $text = [string]$part[$Key]
          break
        }
      }
    }
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) { $text = $text -f $Arguments }
  } catch {
    # The text as found so far: a bad format string must never break the window.
    Write-ToolboxWarningOnce -Id "text:$Key" -Message 'Toolbox text could not be formatted' `
      -Data @{ key = (ConvertTo-ScreenText -Text $Key); error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  return $text
}

function New-ToolboxParserContext {
  # Private. The XAML parser context: the WPF presentation namespace as the default one and the XAML language
  # namespace as x:, so $script:ToolboxXaml itself holds no URL (spec 4.2: nothing is downloaded).
  [CmdletBinding()]
  [OutputType([System.Windows.Markup.ParserContext])]
  param()

  $context = New-Object System.Windows.Markup.ParserContext
  $context.XmlnsDictionary.Add('', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
  $context.XmlnsDictionary.Add('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
  return $context
}

function ConvertTo-ToolboxGlyph {
  # Private. A config icon code ('E765') as its glyph character, or '' when it is not a hex code in the Private
  # Use Area the icon fonts use (U+E000-U+F8FF). Never throws.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Code)

  $value = 0
  if ([int]::TryParse([string]$Code, [Globalization.NumberStyles]::AllowHexSpecifier, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and
      $value -ge 0xE000 -and $value -le 0xF8FF) {
    return [string][char]$value
  }
  return ''
}

function New-ToolboxTextBlock {
  # Private. A TextBlock with a style from the window's resources (or none) and a Tag (t:<key>, or nothing).
  [CmdletBinding()]
  [OutputType([System.Windows.Controls.TextBlock])]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [AllowEmptyString()][string]$Style = '',
    [AllowEmptyString()][string]$Tag = ''
  )

  $block = New-Object System.Windows.Controls.TextBlock
  if ($Style -ne '') { $block.Style = $Window.FindResource($Style) }
  if ($Tag -ne '') { $block.Tag = $Tag }
  return $block
}

function New-ToolboxTweakRow {
  # Private. One tweak row (toolbox spec 4.1): a switch, the tweak's icon, its title and, below it, its description
  # (trimmed), the whole row clickable; the full description is in the row's tooltip. Returns @{ Row; Switch }.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][hashtable]$Tweak
  )

  $id = $Tweak.Id
  $glyph = New-ToolboxTextBlock -Window $Window -Style 'TweakGlyphStyle'
  $glyph.Text = ConvertTo-ToolboxGlyph -Code $Tweak.Icon
  [System.Windows.Controls.DockPanel]::SetDock($glyph, [System.Windows.Controls.Dock]::Left)

  $texts = New-Object System.Windows.Controls.StackPanel
  $texts.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $null = $texts.Children.Add((New-ToolboxTextBlock -Window $Window -Style 'TweakTitleStyle' -Tag "t:tweak.$id.title"))
  $null = $texts.Children.Add((New-ToolboxTextBlock -Window $Window -Style 'TweakDescStyle' -Tag "t:tweak.$id.desc"))

  $content = New-Object System.Windows.Controls.DockPanel
  $null = $content.Children.Add($glyph)
  $null = $content.Children.Add($texts)

  $switch = New-Object System.Windows.Controls.CheckBox
  $switch.Style = $Window.FindResource('SwitchStyle')
  $switch.Tag = "a:Tweak:$id"
  $switch.Content = $content

  $row = New-Object System.Windows.Controls.Border
  $row.Style = $Window.FindResource('TweakRowStyle')
  $row.Child = $switch
  $row.ToolTip = New-ToolboxTextBlock -Window $Window -Style 'TipTextStyle' -Tag "t:tweak.$id.desc"
  return @{ Row = $row; Switch = $switch }
}

function New-ToolboxWindow {
  <#
  .SYNOPSIS
    Builds the toolbox window from $script:ToolboxXaml and renders the model once. Returns the Window; shows nothing.
  .DESCRIPTION
    Adds one profile tile per Get-SetupProfiles entry to ProfilePanel and one tweak row per Get-TweakCatalog entry to
    TweakPanel (Update-ToolboxView hides the rows the rules rule out), fills the machine values once (shown as
    read, left-to-right), puts the window state in Tag (the plan's "Toolbox model and window state": Outcome,
    Choices and Error $null, Closing $false, Timer $null; PowerWarned $false until a failed power read is logged,
    review M2) and calls Update-ToolboxView. No handlers (Task 3).
    -ReadOnAC is what the power timer will call (Task 3).
  #>
  [CmdletBinding()]
  [OutputType([System.Windows.Window])]
  param(
    [Parameter(Mandatory)][hashtable]$Model,
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
    [scriptblock]$ReadOnAC = { Test-OnACPower }
  )

  $window = [System.Windows.Markup.XamlReader]::Parse($script:ToolboxXaml, (New-ToolboxParserContext))

  $tiles = @{}
  $profilePanel = $window.FindName('ProfilePanel')
  foreach ($p in @(Get-SetupProfiles -Config $Config)) {
    $tile = New-Object System.Windows.Controls.RadioButton
    $tile.Style = $window.FindResource('TileStyle')
    $tile.Tag = "a:Profile:$($p.Id)"
    $tile.Content = New-ToolboxTextBlock -Window $window -Tag "t:profile.$($p.Id)"
    $null = $profilePanel.Children.Add($tile)
    $tiles[$p.Id] = $tile
  }

  $rows = @{}
  $tweakPanel = $window.FindName('TweakPanel')
  foreach ($t in @(Get-TweakCatalog -Config $Config)) {
    $row = New-ToolboxTweakRow -Window $window -Tweak $t
    $null = $tweakPanel.Children.Add($row.Row)
    $rows[$t.Id] = $row
  }

  # The machine values, once: as read (no ASCII folding), always left-to-right.
  $friendly = if ([string]::IsNullOrWhiteSpace([string]$Machine['FriendlyModel'])) { $Machine['Model'] } else { $Machine['FriendlyModel'] }
  $window.FindName('MachineModel').Text = ('{0} {1}' -f $Machine['Manufacturer'], $friendly).Trim()
  $window.FindName('MachineSerial').Text = [string]$Machine['Serial']
  $window.FindName('MachineNewName').Text = [string]$Machine['NewName']
  $window.FindName('MachineGlyph').Text = $(if ($Machine['IsLaptop'] -eq $true) { [string][char]0xE7F8 } else { [string][char]0xE7F4 })
  $window.FindName('VersionText').Text = $(if ($Version -match '^[vV]' -or $Version -eq '') { $Version } else { 'v' + $Version })

  $window.Tag = @{
    Model = $Model; Machine = $Machine; Config = $Config; Version = $Version
    Strings = (New-ToolboxStringTable -Config $Config)
    ProfileTiles = $tiles; TweakRows = $rows
    ReadOnAC = $ReadOnAC; Timer = $null; PowerWarned = $false
    Outcome = $null; Choices = $null; Error = $null; Closing = $false
  }
  Update-ToolboxView -Window $window
  return $window
}

function Set-ToolboxLanguage {
  <#
  .SYNOPSIS
    Puts every tagged text into the model's language and turns the window right-to-left for Hebrew (spec 4.3).
  .DESCRIPTION
    Walks the logical tree from the window (and each element's ToolTip when that is an element, which is outside
    the tree) and sets TextBlock.Text for every Tag that starts 't:'. Window.FlowDirection is RightToLeft for 'he',
    else LeftToRight; the machine values and the plan rows set LeftToRight themselves. A tooltip follows the
    window's direction (it is not in the tree, so it cannot inherit it).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $language = [string]$state.Model.Language
  $direction = if ($language -eq 'he') { [System.Windows.FlowDirection]::RightToLeft } else { [System.Windows.FlowDirection]::LeftToRight }
  $Window.FlowDirection = $direction

  $pending = New-Object System.Collections.Stack
  $pending.Push($Window)
  while ($pending.Count -gt 0) {
    $node = $pending.Pop()
    if ($node -is [System.Windows.Controls.TextBlock] -and $node.Tag -is [string] -and $node.Tag.StartsWith('t:')) {
      $node.Text = Get-ToolboxString -Table $state.Strings -Language $language -Key $node.Tag.Substring(2)
    }
    if ($node -is [System.Windows.FrameworkElement] -and $node.ToolTip -is [System.Windows.FrameworkElement]) {
      $node.ToolTip.FlowDirection = $direction
      $pending.Push($node.ToolTip)
    }
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
      if ($child -is [System.Windows.DependencyObject]) { $pending.Push($child) }
    }
  }
}

function Get-ToolboxDigitIndent {
  # Private. How much wider a digit is than a space in the plan rows' font: a row numbered 1 to 9 (' 1  ...') is
  # moved in by this much, so its number and title line up with the rows numbered 10 and up. The row's Text stays
  # exactly '{0,2}  {1}'. Never throws: 0 when it cannot be measured, logged once (WARN).
  [CmdletBinding()]
  [OutputType([double])]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][double]$FontSize
  )

  try {
    $typeface = New-Object System.Windows.Media.Typeface($Window.FontFamily, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)
    $widths = @(foreach ($text in '0', ' ') {
      [System.Windows.Media.FormattedText]::new($text, [Globalization.CultureInfo]::InvariantCulture, [System.Windows.FlowDirection]::LeftToRight, $typeface, $FontSize,
        [System.Windows.Media.Brushes]::Black, $null, [System.Windows.Media.TextFormattingMode]::Display, 1.0).WidthIncludingTrailingWhitespace
    })
    return [double][math]::Max(0, $widths[0] - $widths[1])
  } catch {
    Write-ToolboxWarningOnce -Id 'indent' -Message 'Toolbox plan indent could not be measured' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    return [double]0
  }
}

function Update-ToolboxView {
  <#
  .SYNOPSIS
    Renders Tag.Model into the window (spec 4.1). Returns nothing.
  .DESCRIPTION
    The language (Set-ToolboxLanguage); every tile's IsChecked (profiles, Type, Office, Remote, Updates through
    Get-WindowsUpdateChoice, EN | HE) and both switches; each tweak row's visibility (Test-TweakAllowed) and
    switch; the ScreenConnect reminder (Remote is not ANYDESK); the yellow banner, one line per warning (not
    fresh, the previous run through Format-PreviousRun with the fallback words in the window's language, on
    battery), collapsed when there is none; the red Administrator-protection banner and Start (disabled when
    protection is On); the power chip; the plan column, rebuilt from Get-ToolboxPlanLines with the language's step
    names (plus step.windows-update.drivers, the step's name on Drivers only: wu spec 3.1), its rows in the
    language's direction. The machine values are New-ToolboxWindow's, set once.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $model = $state.Model
  $choices = $model.Choices
  $language = [string]$model.Language
  $visible = [System.Windows.Visibility]::Visible
  $collapsed = [System.Windows.Visibility]::Collapsed

  Set-ToolboxLanguage -Window $Window

  foreach ($id in @($state.ProfileTiles.Keys)) { $state.ProfileTiles[$id].IsChecked = ([string]$choices['Profile'] -ceq $id) }
  $remote = Get-RemoteChoice -Choices $choices
  $updates = Get-WindowsUpdateChoice -Choices $choices
  $office = ([string]$choices['Office']).ToUpperInvariant()
  $checks = @{
    TypeLaptop = ($choices['Mode'] -eq 'LAPTOP'); TypeDesktop = ($choices['Mode'] -eq 'DESKTOP')
    OfficeCraft = ($office -eq 'CRAFT'); OfficeBusiness = ($office -eq 'BUSINESS'); OfficeHome = ($office -eq 'HOME'); OfficeOff = ($office -eq 'OFF')
    RemoteAnyDesk = ($remote -eq 'ANYDESK'); RemoteScreenConnect = ($remote -eq 'SCREENCONNECT'); RemoteBoth = ($remote -eq 'BOTH')
    UpdatesFull = ($updates -eq 'FULL'); UpdatesDrivers = ($updates -eq 'DRIVERS')
    SevenZipSwitch = ($choices['SevenZip'] -eq $true); RestoreSwitch = ($choices['RestorePoint'] -eq $true)
    LangEn = ($language -ne 'he'); LangHe = ($language -eq 'he')
  }
  foreach ($name in $checks.Keys) { $Window.FindName($name).IsChecked = $checks[$name] }

  $selected = @($choices['Tweaks'] | ForEach-Object { [string]$_ })
  foreach ($tweak in @(Get-TweakCatalog -Config $state.Config)) {
    $row = $state.TweakRows[$tweak.Id]
    if ($null -eq $row) { continue }
    $row.Row.Visibility = $(if (Test-TweakAllowed -Tweak $tweak -Choices $choices -Machine $state.Machine) { $visible } else { $collapsed })
    $row.Switch.IsChecked = ($selected -ccontains $tweak.Id)
  }

  $Window.FindName('ScreenConnectWarn').Visibility = $(if ($remote -ne 'ANYDESK') { $visible } else { $collapsed })

  $warnings = New-Object System.Collections.Generic.List[string]
  if ($model.IsFresh -ne $true) { $warnings.Add((Get-ToolboxString -Table $state.Strings -Language $language -Key 'warn.notFresh' -Arguments @($model.MaxAgeDays))) }
  if ($null -ne $model.Previous) {
    # The console's formatting (Format-PreviousRun), with the fallback words in the window's language.
    $run = Format-PreviousRun -Previous $model.Previous -UnknownDate (Get-ToolboxString -Table $state.Strings -Language $language -Key 'previous.unknownDate') `
      -Unfinished (Get-ToolboxString -Table $state.Strings -Language $language -Key 'previous.unfinished')
    $warnings.Add((Get-ToolboxString -Table $state.Strings -Language $language -Key 'warn.previous' -Arguments @($run.When, $run.Color)))
  }
  if ($model.OnAC -ne $true) { $warnings.Add((Get-ToolboxString -Table $state.Strings -Language $language -Key 'warn.battery')) }
  $Window.FindName('WarnText').Text = ($warnings -join "`n")
  $Window.FindName('WarnPanel').Visibility = $(if ($warnings.Count -gt 0) { $visible } else { $collapsed })

  $blocked = ($model.AdminProtection -eq 'On')
  $Window.FindName('AdminBanner').Visibility = $(if ($blocked) { $visible } else { $collapsed })
  $Window.FindName('StartButton').IsEnabled = (-not $blocked)

  $onAC = ($model.OnAC -eq $true)
  $Window.FindName('MachinePower').Text = Get-ToolboxString -Table $state.Strings -Language $language -Key $(if ($onAC) { 'power.ac' } else { 'power.battery' })
  $Window.FindName('MachinePowerGlyph').Text = $(if ($onAC) { [string][char]0xE83E } else { [string][char]0xE83F })
  [System.Windows.Documents.TextElement]::SetForeground($Window.FindName('PowerChip'), $Window.FindResource($(if ($onAC) { 'SubtleTextBrush' } else { 'WarnBrush' })))

  $plan = $Window.FindName('PlanList')
  $plan.Children.Clear()
  $lineStyle = $Window.FindResource('PlanLineStyle')
  $numberBrush = $Window.FindResource('DimTextBrush')
  $indent = Get-ToolboxDigitIndent -Window $Window -FontSize ([double]$Window.FindResource('BaseFontSize'))
  # The step names of the window's language (TB-R5); the rows read in that language's direction, so a Hebrew row
  # shows its number on the right and the name to its left.
  $stepNames = @{}
  foreach ($step in $script:StepCatalog) { $stepNames[$step.Id] = Get-ToolboxString -Table $state.Strings -Language $language -Key "step.$($step.Id)" }
  $stepNames['windows-update.drivers'] = Get-ToolboxString -Table $state.Strings -Language $language -Key 'step.windows-update.drivers'
  $rowDirection = if ($language -eq 'he') { [System.Windows.FlowDirection]::RightToLeft } else { [System.Windows.FlowDirection]::LeftToRight }
  foreach ($line in @(Get-ToolboxPlanLines -Model $model -Machine $state.Machine -Config $state.Config -Titles $stepNames)) {
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Style = $lineStyle
    $block.FlowDirection = $rowDirection
    $block.Text = $line
    if ($line.StartsWith(' ')) { $block.Margin = New-Object System.Windows.Thickness($indent, 0, 0, 0) }
    # The step number in a dimmer colour; the text itself stays exactly the line.
    $number = New-Object System.Windows.Media.TextEffect
    $number.PositionStart = 0
    $number.PositionCount = 2
    $number.Foreground = $numberBrush
    $block.TextEffects = New-Object System.Windows.Media.TextEffectCollection
    $null = $block.TextEffects.Add($number)
    $null = $plan.Children.Add($block)
  }
}

function Register-ToolboxHandlers {
  <#
  .SYNOPSIS
    Wires the window's handlers (spec 5.1). Each is one line that calls Invoke-ToolboxAction. Returns nothing.
  .DESCRIPTION
    - Click on every element whose Tag starts 'a:': the tiles, the switches, EN | HE, Start, Cancel and the X,
      the generated profile tiles and tweak switches too;
    - MouseLeftButtonDown on the title bar (Drag; a button in the bar handles its own press first);
    - PreviewMouseWheel on the plan's scroller (Wheel: the wheel passes on to the body when the plan cannot
      scroll, TB-R7);
    - ContentRendered (Rendered) and Closing (Closing) on the window.
    No key handler and no key binding: Esc and Enter do nothing (spec 4.1). The handlers use no outer variable:
    the window's state is in its Tag, and the sender ($this) leads back to the window.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $pending = New-Object System.Collections.Stack
  $pending.Push($Window)
  while ($pending.Count -gt 0) {
    $node = $pending.Pop()
    if ($node -is [System.Windows.FrameworkElement] -and $node.Tag -is [string] -and $node.Tag.StartsWith('a:', [StringComparison]::Ordinal)) {
      $node.Add_Click({ Invoke-ToolboxAction -Sender $this })
    }
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
      if ($child -is [System.Windows.DependencyObject]) { $pending.Push($child) }
    }
  }
  $Window.FindName('TitleBar').Add_MouseLeftButtonDown({ Invoke-ToolboxAction -Sender $this -Action 'Drag' })
  $Window.FindName('PlanScroll').Add_PreviewMouseWheel({ Invoke-ToolboxAction -Sender $this -Action 'Wheel' -EventArgs $_ })
  $Window.Add_ContentRendered({ Invoke-ToolboxAction -Sender $this -Action 'Rendered' })
  $Window.Add_Closing({ Invoke-ToolboxAction -Sender $this -Action 'Closing' })
}

function Invoke-ToolboxAction {
  <#
  .SYNOPSIS
    Runs one window action. Every handler of the window calls this and nothing else (spec 5.1). Never throws.
  .DESCRIPTION
    The window is the sender itself (a Window), the sender's Tag (the power timer's) or the window the sender is
    in ([Windows.Window]::GetWindow); only a window whose Tag is the toolbox state counts. The action and its value
    are -Action and -Value, else the sender's a:<Action>:<Value> Tag. -EventArgs is the event's arguments, for
    the one action that needs them (Wheel).
      - Start: refused while Administrator protection is On, with WARN 'Start refused: Administrator protection
        is on' (spec 5.3; a click raised on the disabled button still lands here). Otherwise Tag.Choices is the
        validated Choices (ConvertTo-ValidChoices; dropped tweak ids are logged WARN) and the window closes as
        Start.
      - Cancel: the window closes as Cancel (the Cancel button and the X).
      - Closing: Tag.Closing = $true; a window that closes without an outcome (Alt+F4) is Cancel.
      - Rendered: the window is activated, then no longer Topmost (it opens Topmost so it never opens behind the
        console after UAC; spec 5.1).
      - Drag: DragMove(). Its InvalidOperationException (the button is already up) is ignored: the one benign
        exception.
      - Power: Tag.ReadOnAC. A read that throws keeps the last value and logs WARN 'Could not read the power
        state for the toolbox', once per window (Tag.PowerWarned; review M2: not on every 5-second tick);
        otherwise the model (Update-ToolboxModel -Action Power), then the view.
      - Wheel: when the plan cannot scroll in the wheel's direction (it fits, or it is at that end), the wheel is
        handled here and raised on the body (ContentScroll) instead, so the body scrolls (TB-R7).
      - Any other action (Profile, Mode, Office, Remote, WindowsUpdate, SevenZip, RestorePoint, Tweak, Language):
        Update-ToolboxModel, then Update-ToolboxView. A control never decides its own state: the model does.
    Any exception: the window closes as Failed with the message in ASCII (Close-ToolboxWindow), and setup.log
    gets one ERROR line 'Toolbox action failed' with @{ action; error; type } (ASCII; type is the exception's
    .NET type name, review M3). A failure is never read as Cancel (spec 5.1).
  #>
  [CmdletBinding()]
  param(
    [AllowNull()]$Sender,
    [AllowEmptyString()][string]$Action = '',
    [AllowEmptyString()][string]$Value = '',
    [AllowNull()]$EventArgs
  )

  $window = $null
  try {
    $found = $null
    if ($Sender -is [System.Windows.Window]) { $found = $Sender }
    elseif ($Sender -is [System.Windows.Threading.DispatcherTimer]) { $found = $Sender.Tag }
    elseif ($Sender -is [System.Windows.DependencyObject]) { $found = [System.Windows.Window]::GetWindow($Sender) }
    if ($found -isnot [System.Windows.Window] -or $found.Tag -isnot [hashtable]) { throw 'The event did not come from a toolbox window' }
    $window = $found
    $state = $window.Tag

    if ([string]::IsNullOrEmpty($Action)) {
      $parts = ([string]$Sender.Tag).Split([char]':', 3)
      if ($parts.Count -ne 3 -or $parts[0] -cne 'a') { throw 'The element has no a:<Action>:<Value> tag' }
      $Action = $parts[1]
      $Value = $parts[2]
    }

    switch -CaseSensitive ($Action) {
      'Start' {
        if ($state.Model.AdminProtection -eq 'On') {
          Write-SetupLog -Level WARN -Message 'Start refused: Administrator protection is on'
        } else {
          $valid = ConvertTo-ValidChoices -Choices $state.Model.Choices -Config $state.Config -Machine $state.Machine
          if (@($valid.Dropped).Count -gt 0) {
            Write-SetupLog -Level WARN -Message 'Unknown tweak ids dropped' -Data @{ tweaks = @($valid.Dropped | ForEach-Object { ConvertTo-ScreenText -Text $_ }) }
          }
          $state.Choices = $valid.Choices
          Close-ToolboxWindow -Window $window -Outcome 'Start'
        }
      }
      'Cancel' { Close-ToolboxWindow -Window $window -Outcome 'Cancel' }
      'Closing' {
        $state.Closing = $true
        if ($null -eq $state.Outcome) { $state.Outcome = 'Cancel' }
      }
      'Rendered' {
        $null = $window.Activate()
        $window.Topmost = $false
      }
      'Drag' {
        try { $window.DragMove() }
        catch [System.InvalidOperationException] { <# the button is already up: nothing to drag (the one benign exception) #> }
      }
      'Power' {
        $onAC = $null
        try {
          $onAC = [bool](& $state.ReadOnAC)
        } catch {
          if ($state.PowerWarned -ne $true) {
            $state.PowerWarned = $true
            Write-SetupLog -Level WARN -Message 'Could not read the power state for the toolbox' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
          }
        }
        if ($null -ne $onAC) {
          $state.Model = Update-ToolboxModel -Model $state.Model -Action 'Power' -Value ([string]$onAC) -Config $state.Config
          Update-ToolboxView -Window $window
        }
      }
      'Wheel' {
        $wheel = [System.Windows.Input.MouseWheelEventArgs]$EventArgs
        $plan = $window.FindName('PlanScroll')
        $canScroll = if ($wheel.Delta -lt 0) { $plan.VerticalOffset -lt $plan.ScrollableHeight } else { $plan.VerticalOffset -gt 0 }
        if (-not $canScroll) {
          $wheel.Handled = $true
          $forward = New-Object System.Windows.Input.MouseWheelEventArgs($wheel.MouseDevice, $wheel.Timestamp, $wheel.Delta)
          $forward.RoutedEvent = [System.Windows.UIElement]::MouseWheelEvent
          $window.FindName('ContentScroll').RaiseEvent($forward)
        }
      }
      default {
        $state.Model = Update-ToolboxModel -Model $state.Model -Action $Action -Value $Value -Config $state.Config
        Update-ToolboxView -Window $window
      }
    }
  } catch {
    $message = ConvertTo-ScreenText -Text $_.Exception.Message
    Write-SetupLog -Level ERROR -Message 'Toolbox action failed' -Data @{ action = (ConvertTo-ScreenText -Text $Action); error = $message
      type = (ConvertTo-ScreenText -Text $_.Exception.GetType().FullName) }
    if ($null -ne $window) { Close-ToolboxWindow -Window $window -Outcome 'Failed' -ErrorText $message }
  }
}

function Close-ToolboxWindow {
  <#
  .SYNOPSIS
    Records the window's outcome in its Tag and closes it. Returns nothing; never throws.
  .DESCRIPTION
    Tag.Outcome becomes -Outcome, except that Failed always wins: once Failed, the outcome stays Failed and keeps
    its first Error (the cause, not a later consequence). Failed sets Tag.Error to -ErrorText (ASCII).
    Close() is called only while Tag.Closing is $false (a Close() while the window is closing would throw), inside
    try: a Close() that fails anyway is logged WARN. The Closing handler then marks the window as closing.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][ValidateSet('Start', 'Cancel', 'Failed')][string]$Outcome,
    [AllowEmptyString()][string]$ErrorText = ''
  )

  $state = $Window.Tag
  if ($Outcome -eq 'Failed') {
    if ($state.Outcome -ne 'Failed') { $state.Error = $ErrorText }
    $state.Outcome = 'Failed'
  } elseif ($state.Outcome -ne 'Failed') {
    $state.Outcome = $Outcome
  }
  if ($state.Closing -ne $true) {
    try {
      $Window.Close()
    } catch {
      Write-SetupLog -Level WARN -Message 'Could not close the toolbox window' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
  }
}

function Invoke-ToolboxUnhandled {
  <#
  .SYNOPSIS
    The dispatcher backstop (spec 5.1): an exception no handler caught (layout, rendering, WPF itself). Never throws.
  .DESCRIPTION
    Marks the exception handled, so WPF does not end the process. When a toolbox window is open
    ($script:ToolboxOpenWindow), closes it as Failed with the message in ASCII. Logs ERROR 'Toolbox error' with
    @{ error; type } (ASCII; type is the exception's .NET type name, review M3).
  #>
  [CmdletBinding()]
  param([AllowNull()]$EventArgs)

  try {
    $message = ''
    $type = ''
    if ($null -ne $EventArgs) {
      $EventArgs.Handled = $true
      $message = ConvertTo-ScreenText -Text $EventArgs.Exception.Message
      if ($null -ne $EventArgs.Exception) { $type = ConvertTo-ScreenText -Text $EventArgs.Exception.GetType().FullName }
    }
    $open = $script:ToolboxOpenWindow
    if ($null -ne $open) { Close-ToolboxWindow -Window $open -Outcome 'Failed' -ErrorText $message }
    Write-SetupLog -Level ERROR -Message 'Toolbox error' -Data @{ error = $message; type = $type }
  } catch {
    Write-SetupLog -Level ERROR -Message 'Toolbox error' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message)
      type = (ConvertTo-ScreenText -Text $_.Exception.GetType().FullName) }
  }
}

function Set-ToolboxWindowSize {
  <#
  .SYNOPSIS
    Fits the window into the screen's work area (spec 4.1): at most 1000 x 680, centred. Returns nothing.
  .DESCRIPTION
    On a small screen (150% scaling at 1024x768) the window takes the whole work area and its content scrolls
    (ContentScroll). -WorkArea is in device-independent pixels, as [Windows.SystemParameters]::WorkArea gives it,
    and may start away from 0,0 (a second monitor, a taskbar at the top or the left). A work area whose width or
    height is not above 0 (Rect.Empty, a zero size) is ignored: the window keeps its 1000 x 680 (review M4: a
    zero-size modal window could never be seen, and it waits for Start).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][System.Windows.Rect]$WorkArea
  )

  if (-not ($WorkArea.Width -gt 0 -and $WorkArea.Height -gt 0)) { return }
  $width = [math]::Min(1000, $WorkArea.Width)
  $height = [math]::Min(680, $WorkArea.Height)
  $Window.Width = $width
  $Window.Height = $height
  $Window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  $Window.Left = $WorkArea.Left + ($WorkArea.Width - $width) / 2
  $Window.Top = $WorkArea.Top + ($WorkArea.Height - $height) / 2
}

function New-ToolboxPowerTimer {
  <#
  .SYNOPSIS
    The timer that re-reads the power state every 5 seconds (spec 4.1: "every few seconds"; Plan call). Not
    started.
  .DESCRIPTION
    Its Tag is the window, so its Tick handler (Invoke-ToolboxAction -Action Power) finds the window without an
    outer variable. It runs on the window's dispatcher, so it ticks only while the dialog runs.
  #>
  [CmdletBinding()]
  [OutputType([System.Windows.Threading.DispatcherTimer])]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $timer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Background, $Window.Dispatcher)
  $timer.Interval = [TimeSpan]::FromSeconds(5)
  $timer.Tag = $Window
  $timer.Add_Tick({ Invoke-ToolboxAction -Sender $this -Action 'Power' })
  return $timer
}

function Show-ToolboxWindow {
  <#
  .SYNOPSIS
    Shows the toolbox and returns @{ Outcome = 'Start'|'Cancel'|'Failed'; Choices; Error }. Never throws.
  .DESCRIPTION
    The same inputs as Show-StartScreen. In order:
      1. software rendering for the whole process (spec 5.1: the PC has no GPU driver yet);
      2. the power state (a read that throws counts as on AC, logged WARN, and the window's power timer then
         logs no second one: Tag.PowerWarned) and Administrator protection (logged WARN when it is not Off);
      3. the model, the window (its power timer reads -OnAC), the handlers and the work-area clamp;
      4. the power timer, started (Tag.Timer);
      5. the dispatcher backstop (Invoke-ToolboxUnhandled), for exceptions no handler caught;
      6. the dialog, through the -ShowDialog seam, with $script:ToolboxOpenWindow set for the backstop. A dialog
         that returns while the Outcome is still empty (the window was not closed: WPF's modal loop ended some
         other way) is Failed at once, BEFORE the cleanup below closes the window, so the Closing handler (which
         reads an empty Outcome as Cancel) can never turn it into Cancel (review M1: failure is never Cancel, by
         construction);
      7. finally: the timer stops, the backstop is removed, $script:ToolboxOpenWindow is cleared and the window
         is closed (a Close() that fails is logged WARN).
    The result is Tag's Outcome, Choices and Error. Any exception is Failed with its message in ASCII, logged
    ERROR 'Toolbox window failed' with @{ error; line; type }. WPF is not shut down here (Get-SetupChoices does
    that).

    The seams (production defaults shown):
      -ShowDialog       shows the window as a dialog; the only place that does
      -OnAC             $true when on mains power (also what the power timer reads)
      -AdminProtection  'On', 'Off' or 'Unknown'
      -WorkArea         the screen's work area, in device-independent pixels
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Version,
    [AllowNull()][hashtable]$Previous,
    [Parameter(Mandatory)][bool]$IsFresh,
    [scriptblock]$ShowDialog = { param($w) $w.ShowDialog() },
    [scriptblock]$OnAC = { Test-OnACPower },
    [scriptblock]$AdminProtection = { Test-AdminProtection },
    [scriptblock]$WorkArea = { [Windows.SystemParameters]::WorkArea }
  )

  try {
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly

    $onACNow = $true
    $powerWarned = $false
    try {
      $onACNow = [bool](& $OnAC)
    } catch {
      $powerWarned = $true
      Write-SetupLog -Level WARN -Message 'Could not read the power state for the toolbox' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
    $model = New-ToolboxModel -Machine $Machine -Config $Config -Previous $Previous -IsFresh $IsFresh -OnAC $onACNow -AdminProtection ([string](& $AdminProtection))
    if ($model.AdminProtection -ne 'Off') { Write-SetupLog -Level WARN -Message 'Administrator protection is not off' -Data @{ state = $model.AdminProtection } }

    $window = New-ToolboxWindow -Model $model -Machine $Machine -Config $Config -Version $Version -ReadOnAC $OnAC
    $window.Tag.PowerWarned = $powerWarned
    $timer = $null
    $backstop = { Invoke-ToolboxUnhandled -EventArgs $_ }
    try {
      Register-ToolboxHandlers -Window $window
      Set-ToolboxWindowSize -Window $window -WorkArea (& $WorkArea)
      $timer = New-ToolboxPowerTimer -Window $window
      $window.Tag.Timer = $timer
      $timer.Start()
      $window.Dispatcher.Add_UnhandledException($backstop)
      $script:ToolboxOpenWindow = $window
      $null = & $ShowDialog $window
      # Before the finally's Close(): its Closing handler would read an empty Outcome as Cancel (review M1).
      if ($null -eq $window.Tag.Outcome) {
        $window.Tag.Outcome = 'Failed'
        $window.Tag.Error = 'The toolbox dialog ended without an outcome'
      }
    } finally {
      if ($null -ne $timer) { $timer.Stop() }
      $window.Dispatcher.Remove_UnhandledException($backstop)
      $script:ToolboxOpenWindow = $null
      try {
        $window.Close()
      } catch {
        Write-SetupLog -Level WARN -Message 'Could not close the toolbox window' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
      }
    }

    $state = $window.Tag
    return @{ Outcome = $state.Outcome; Choices = $state.Choices; Error = $state.Error }
  } catch {
    $message = ConvertTo-ScreenText -Text $_.Exception.Message
    Write-SetupLog -Level ERROR -Message 'Toolbox window failed' -Data @{ error = $message; line = $_.InvocationInfo.ScriptLineNumber
      type = (ConvertTo-ScreenText -Text $_.Exception.GetType().FullName) }
    return @{ Outcome = 'Failed'; Choices = $null; Error = $message }
  }
}

function Test-ToolboxHost {
  <#
  .SYNOPSIS
    Whether this process can show the toolbox window (spec 5.1): @{ Ok = <bool>; Reason = <string> }. Never throws.
  .DESCRIPTION
    Four checks, in this order; the first one that fails gives Ok = $false with its reason, and the later ones
    do not run (WPF is not loaded after an earlier failure):
      - the thread is STA                      -> 'not STA'
      - the session is interactive             -> 'not interactive'
      - the session is not session 0           -> 'session 0'
      - WPF loads (PresentationFramework, PresentationCore, WindowsBase)
                                               -> 'WPF could not be loaded: <message in ASCII>'
    Anything else that goes wrong while checking gives Ok = $false with 'host check failed: <message in ASCII>':
    the console start screen then takes over, which is always safe. Ok = $true has an empty Reason.

    The seams (production defaults shown, each resolved in the body when not given):
      -ApartmentState  [Threading.Thread]::CurrentThread.GetApartmentState()
      -UserInteractive [Environment]::UserInteractive
      -SessionId       [Diagnostics.Process]::GetCurrentProcess().SessionId
      -LoadWpf         { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop }
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()]$ApartmentState,
    [AllowNull()]$UserInteractive,
    [AllowNull()]$SessionId,
    [scriptblock]$LoadWpf = { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop }
  )

  try {
    if ($null -eq $ApartmentState) { $ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState() }
    if ([string]$ApartmentState -ne 'STA') { return @{ Ok = $false; Reason = 'not STA' } }

    if ($null -eq $UserInteractive) { $UserInteractive = [System.Environment]::UserInteractive }
    if (-not $UserInteractive) { return @{ Ok = $false; Reason = 'not interactive' } }

    if ($null -eq $SessionId) { $SessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId }
    if ([int]$SessionId -eq 0) { return @{ Ok = $false; Reason = 'session 0' } }

    try {
      $null = & $LoadWpf
    } catch {
      return @{ Ok = $false; Reason = ('WPF could not be loaded: ' + (ConvertTo-ScreenText -Text $_.Exception.Message)) }
    }
    return @{ Ok = $true; Reason = '' }
  } catch {
    return @{ Ok = $false; Reason = ('host check failed: ' + (ConvertTo-ScreenText -Text $_.Exception.Message)) }
  }
}

function Get-SetupChoices {
  <#
  .SYNOPSIS
    The start screen of a new run (Main.ps1): the toolbox window, or the console start screen when the window
    cannot be used. Returns the Choices to run with, or $null when the technician cancels.
  .DESCRIPTION
    The same parameters and the same return contract as Show-StartScreen, which it replaces at Main.ps1's
    call. Exactly one value is returned: a Choices hashtable (always through ConvertTo-ValidChoices) or $null.
      1. Host check (Test-ToolboxHost). Not Ok: WARN 'Toolbox not available; using the console start screen'
         with @{ reason }, then the console (step 4).
      2. The window (Show-ToolboxWindow), in try/finally. An exception becomes Failed (its message in ASCII).
         Whatever happens, the WPF dispatcher is stopped exactly once afterwards, so the main thread does not keep
         a hidden WPF window for the hours the run takes (spec 5.1); a failure of that stop is only a WARN.
      3. The outcome:
           Start   INFO 'Toolbox closed' with @{ outcome; profile }; the Choices are returned.
           Cancel  INFO 'Toolbox closed' with @{ outcome }; $null is returned (Esc on the console does the same).
           Failed  ERROR 'Toolbox failed; using the console start screen' with @{ error } (and type, the .NET
                   type name, when the window threw), then the console. So does anything else: no result, more
                   than one value, an unknown outcome, or a Start without Choices. A failure is never read as a
                   Cancel (spec 5.1).
      4. The console is Show-StartScreen with the same parameters plus -NoAutoStart (ruling TB-R8): the console
         fallback waits for Enter. It never counts down, not even on a fresh machine, because the window promised
         to wait (Q18) and a window that failed after it opened must not start a run nobody pressed Start for, on
         choices nobody made. Otherwise the console screen is unchanged. Its $null (Escape), or no result at all,
         is returned as $null; a single hashtable passes ConvertTo-ValidChoices. Anything else (a string, more
         than one value) throws 'Start screen returned an unexpected result': it never starts a run. That
         exception, like any from the console, is not caught here: it reaches the entry point's crash handler.
    ConvertTo-ValidChoices drops unknown tweak ids; they are logged WARN 'Unknown tweak ids dropped'.

    The seams (production defaults shown), so no test opens a window or stops WPF:
      -TestHost            { Test-ToolboxHost }
      -ShowToolbox         { param($p) Show-ToolboxWindow @p }
      -ShowConsole         { param($p) Show-StartScreen @p }
      -ShutdownDispatcher  stops the thread's WPF dispatcher; the only place in src that does
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Version,
    [AllowNull()][hashtable]$Previous,
    [Parameter(Mandatory)][bool]$IsFresh,
    [scriptblock]$TestHost = { Test-ToolboxHost },
    [scriptblock]$ShowToolbox = { param($p) Show-ToolboxWindow @p },
    [scriptblock]$ShowConsole = { param($p) Show-StartScreen @p },
    [scriptblock]$ShutdownDispatcher = { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }
  )

  $p = @{ Machine = $Machine; Config = $Config; Version = $Version; Previous = $Previous; IsFresh = $IsFresh }
  $raw = $null
  $fromToolbox = $false
  $thrownType = ''

  $hostCheck = & $TestHost
  if ($hostCheck -isnot [System.Collections.IDictionary] -or $hostCheck['Ok'] -ne $true) {
    $reason = if ($hostCheck -is [System.Collections.IDictionary]) { [string]$hostCheck['Reason'] } else { 'the host check returned no result' }
    Write-SetupLog -Level WARN -Message 'Toolbox not available; using the console start screen' -Data @{ reason = (ConvertTo-ScreenText -Text $reason) }
  } else {
    $result = $null
    try {
      $outputs = @(& $ShowToolbox $p)
      if ($outputs.Count -eq 1) { $result = $outputs[0] }
    } catch {
      $result = @{ Outcome = 'Failed'; Error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
      $thrownType = ConvertTo-ScreenText -Text $_.Exception.GetType().FullName
    } finally {
      try {
        $null = & $ShutdownDispatcher
      } catch {
        Write-SetupLog -Level WARN -Message 'Could not stop the toolbox dispatcher' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
      }
    }

    $failure = 'The toolbox returned no result'
    if ($result -is [hashtable]) {
      $outcome = $result['Outcome']
      if ($outcome -ceq 'Cancel') {
        Write-SetupLog -Level INFO -Message 'Toolbox closed' -Data @{ outcome = 'Cancel' }
        return $null
      } elseif ($outcome -ceq 'Start') {
        if ($result['Choices'] -is [System.Collections.IDictionary]) {
          $raw = $result['Choices']
          $fromToolbox = $true
        } else {
          $failure = 'The toolbox returned Start without Choices'
        }
      } elseif ($outcome -ceq 'Failed') {
        $failure = [string]$result['Error']
      } else {
        $failure = 'The toolbox returned an unknown outcome'
      }
    }
    if (-not $fromToolbox) {
      $data = @{ error = (ConvertTo-ScreenText -Text $failure) }
      if ($thrownType -ne '') { $data.type = $thrownType }
      Write-SetupLog -Level ERROR -Message 'Toolbox failed; using the console start screen' -Data $data
    }
  }

  if (-not $fromToolbox) {
    $console = $p.Clone()
    $console.NoAutoStart = $true   # TB-R8: the console fallback waits for Enter
    $fromConsole = @(& $ShowConsole $console)
    if ($fromConsole.Count -eq 0 -or ($fromConsole.Count -eq 1 -and $null -eq $fromConsole[0])) { return $null }
    if ($fromConsole.Count -ne 1 -or $fromConsole[0] -isnot [hashtable]) { throw 'Start screen returned an unexpected result' }
    $raw = $fromConsole[0]
  }

  $valid = ConvertTo-ValidChoices -Choices $raw -Config $Config -Machine $Machine
  if (@($valid.Dropped).Count -gt 0) {
    Write-SetupLog -Level WARN -Message 'Unknown tweak ids dropped' -Data @{ tweaks = @($valid.Dropped | ForEach-Object { ConvertTo-ScreenText -Text $_ }) }
  }
  if ($fromToolbox) {
    Write-SetupLog -Level INFO -Message 'Toolbox closed' -Data @{ outcome = 'Start'; profile = [string]$valid.Choices.Profile }
  }
  return $valid.Choices
}
