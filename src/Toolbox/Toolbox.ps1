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
#   - Nothing here writes to the console (no Write-Host) or sleeps.
#   - Nothing here opens the window as a dialog or stops WPF; no test does either.
#
# Needs: Toolbox\Strings.ps1 ($script:ToolboxStrings), Toolbox\Xaml.ps1 ($script:ToolboxXaml),
# Toolbox\SetupPlanner.ps1 (Get-SetupProfiles, Get-ToolboxPlanLines), Engine\Catalog.ps1 (Get-TweakCatalog,
# Test-TweakAllowed, Get-RemoteChoice, $script:StepCatalog), UI\StartScreen.ps1 (Format-PreviousRun) and WPF
# (PresentationFramework, PresentationCore, WindowsBase), loaded by the caller. The bundle holds every file.

# The window that is open, for the dispatcher backstop only (Task 3): the dispatcher's event has no window.
$script:ToolboxOpenWindow = $null

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
    an empty space). A text that does not format with the arguments is returned unformatted.
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
    # Best effort: the text as found so far (a bad format string must never break the window).
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
    Choices and Error $null, Closing $false, Timer $null) and calls Update-ToolboxView. No handlers (Task 3).
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
    ReadOnAC = $ReadOnAC; Timer = $null
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
  # exactly '{0,2}  {1}'. Never throws (0 when it cannot be measured).
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
    return [double]0
  }
}

function Update-ToolboxView {
  <#
  .SYNOPSIS
    Renders Tag.Model into the window (spec 4.1). Returns nothing.
  .DESCRIPTION
    The language (Set-ToolboxLanguage); every tile's IsChecked (profiles, Type, Office, Remote, EN | HE) and both
    switches; each tweak row's visibility (Test-TweakAllowed) and switch; the ScreenConnect reminder (Remote is not
    ANYDESK); the yellow banner, one line per warning (not fresh, the previous run through Format-PreviousRun with
    the fallback words in the window's language, on battery), collapsed when there is none; the red
    Administrator-protection banner and Start (disabled when protection is On); the power chip; the plan column,
    rebuilt from Get-ToolboxPlanLines with the language's step names, its rows in the language's direction. The
    machine values are New-ToolboxWindow's, set once.
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
  $office = ([string]$choices['Office']).ToUpperInvariant()
  $checks = @{
    TypeLaptop = ($choices['Mode'] -eq 'LAPTOP'); TypeDesktop = ($choices['Mode'] -eq 'DESKTOP')
    OfficeCraft = ($office -eq 'CRAFT'); OfficeBusiness = ($office -eq 'BUSINESS'); OfficeHome = ($office -eq 'HOME'); OfficeOff = ($office -eq 'OFF')
    RemoteAnyDesk = ($remote -eq 'ANYDESK'); RemoteScreenConnect = ($remote -eq 'SCREENCONNECT'); RemoteBoth = ($remote -eq 'BOTH')
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
