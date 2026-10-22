# src/Toolbox/RepairPage.ps1
# The Repair & diagnostics page's view (repair spec 4.1-4.4, 5; repair plan "XAML contract additions"):
# Update-RepairView renders the toolbox model's Page and Repair (RepairPlanner.ps1) into the window that
# New-ToolboxWindow (Toolbox.ps1) built from Xaml.ps1. Update-ToolboxView calls it last, on every render.
#
# The rules of Toolbox.ps1 hold here too: the model decides every state (a control never decides its own); every
# .NET call's output goes to $null, so each function returns exactly one value or nothing; no console, no sleep, no
# closures, no handler; colours come from the window's one resource dictionary. Texts come from the string table in
# the model's language (Format-RepairText over Get-ToolboxString); machine values, the log tail, file paths and
# adapter lines stay left-to-right in Hebrew (ruling RD-R14: a value inside a Hebrew line is wrapped in
# left-to-right marks; a whole machine-value line is a left-to-right element).
#
# It never writes the complaint box or the YES box: a re-render must not move the caret (plan call). The one
# exception: the YES box is emptied when a new confirmation opens. A tooltip is replaced only when its text changed
# (the 5-second power tick re-renders, and must not close a tooltip being read: review M5).
#
# The lists it renders (Run.Steps, Result.Findings, Confirm.Items, Confirm.Lines) may hold hashtables or objects
# read from JSON; each row becomes a hashtable once (ConvertTo-RepairRows) and a row that is neither is skipped and
# logged once (review M4). Confirm.Lines entries are @{ Key = '<string key>'; Args = @(...) } (a text of the window's
# language) or @{ Ltr = '<machine value>' } (a left-to-right value line; review M2).
#
# Needs Toolbox.ps1 (Get-ToolboxString, New-ToolboxTextBlock, Write-ToolboxWarningOnce), RepairPlanner.ps1
# (Get-RepairGate, Get-RepairChips, Test-RepairConfirmReady, Format-RepairElapsed, $script:RepairTileRows),
# State.ps1 (ConvertTo-HashtableDeep), StartScreen.ps1 (ConvertTo-ScreenText) and WPF; the bundle holds every file.

# The glyph and the colours of a run step's status (plan, Glyphs; pending is a ring, EA3A, rather than the plan's
# filled E91F: an empty circle reads as "still to come" on the screenshots).
$script:RepairStepLooks = @{
  done     = @{ Glyph = 0xE73E; Brush = 'OkBrush'; Text = 'TextBrush' }
  running  = @{ Glyph = 0xE768; Brush = 'AccentBrush'; Text = 'TextBrush' }
  failed   = @{ Glyph = 0xE711; Brush = 'CritBrush'; Text = 'TextBrush' }
  timedout = @{ Glyph = 0xE711; Brush = 'CritBrush'; Text = 'TextBrush' }
  warn     = @{ Glyph = 0xE7BA; Brush = 'WarnBrush'; Text = 'TextBrush' }
  skipped  = @{ Glyph = 0xE738; Brush = 'DimTextBrush'; Text = 'DimTextBrush' }
  pending  = @{ Glyph = 0xEA3A; Brush = 'DimTextBrush'; Text = 'SubtleTextBrush' }
}

# A chip's background and glyph colour by level (spec 5: green, yellow, red; unknown is yellow; grey while loading).
$script:RepairChipBacks = @{ ok = 'OkBackBrush'; warn = 'WarnBackBrush'; crit = 'DangerBackBrush'; unknown = 'WarnBackBrush'; loading = 'TileBrush' }
$script:RepairChipFores = @{ ok = 'OkBrush'; warn = 'WarnBrush'; crit = 'CritBrush'; unknown = 'WarnBrush'; loading = 'DimTextBrush' }

function Get-RepairElementName {
  # Private. The element name of a tile id: 'quickReport' -> 'TileQuickReport'.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Id)

  return ('Tile' + $Id.Substring(0, 1).ToUpperInvariant() + $Id.Substring(1))
}

function Get-RepairActionTitle {
  # Private. An action's name in the window's language: its tile's title, else its step name, else the id. With
  # -Step (the run panel's step rows) the step name comes first and the tile's title is the fallback (review M3:
  # dismSource and netRestore are both a tile and a step).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$State, [AllowEmptyString()][string]$Id, [switch]$Step)

  $language = [string]$State.Model.Language
  $keys = if ($Step) { "tool.step.$Id", "tile.$Id.title" } else { "tile.$Id.title", "tool.step.$Id" }
  foreach ($key in $keys) {
    if ($State.Strings['en'].ContainsKey($key)) { return (Get-ToolboxString -Table $State.Strings -Language $language -Key $key) }
  }
  return $Id
}

function Format-RepairText {
  <#
  .SYNOPSIS
    Private. A text of the string table in the window's language, its -Arguments filled in. In Hebrew every value
    that is a machine value (no Hebrew letter, and not a plain number) is wrapped in left-to-right marks (U+200E), so
    a drive, a path, an IP or a code reads left-to-right inside the right-to-left line (ruling RD-R14; WPF ignores
    the isolate marks U+2066..U+2069). A plain number needs no mark, and a Hebrew value (a step name) none either.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Key, [AllowNull()][object[]]$Arguments)

  $language = [string]$State.Model.Language
  $values = @(foreach ($a in @($Arguments)) { if ($null -ne $a) { [string]$a } })
  if ($language -ceq 'he') {
    $mark = [string][char]0x200E
    $values = @(foreach ($v in $values) { if ($v -eq '' -or $v -match '^\d+$' -or $v -match '\p{IsHebrew}') { $v } else { $mark + $v + $mark } })
  }
  return (Get-ToolboxString -Table $State.Strings -Language $language -Key $Key -Arguments $values)
}

function Set-RepairTip {
  # Private. -Owner's tooltip: a wrapping TextBlock (TipTextStyle) holding -Text in the window's direction, or none
  # for an empty -Text. The tooltip is replaced only when its text changed, so a re-render (the 5-second power tick)
  # never closes a tooltip that is open (review M5); a changed direction (EN | HE) is set on the same tooltip. The
  # tooltip is outside the logical tree, so it does not inherit the window's direction.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][System.Windows.FrameworkElement]$Owner,
    [AllowEmptyString()][string]$Text = ''
  )

  if ($Text -eq '') {
    if ($null -ne $Owner.ToolTip) { $Owner.ToolTip = $null }
    return
  }
  $tip = $Owner.ToolTip
  if ($tip -is [System.Windows.Controls.TextBlock] -and $tip.Text -ceq $Text) {
    if ($tip.FlowDirection -ne $Window.FlowDirection) { $tip.FlowDirection = $Window.FlowDirection }
    return
  }
  $tip = New-ToolboxTextBlock -Window $Window -Style 'TipTextStyle'
  $tip.Text = $Text
  $tip.FlowDirection = $Window.FlowDirection
  $Owner.ToolTip = $tip
}

function ConvertTo-RepairRows {
  <#
  .SYNOPSIS
    Private. The rows of a list the view renders (-List names it: steps, findings, items, lines), each as a hashtable:
    a hashtable as it is, an object read from JSON converted once (ConvertTo-HashtableDeep). Anything else is skipped
    and logged once per list (WARN 'Toolbox repair row skipped' with @{ list; type }), never dropped silently (review
    M4). Emitted one by one: wrap the call in @().
  #>
  [CmdletBinding()]
  param([AllowNull()]$Rows, [Parameter(Mandatory)][string]$List)

  foreach ($row in @($Rows)) {
    if ($null -eq $row) { continue }
    if ($row -is [System.Collections.IDictionary]) { $row; continue }
    if ($row -is [System.Management.Automation.PSCustomObject]) { ConvertTo-HashtableDeep -InputObject $row; continue }
    Write-ToolboxWarningOnce -Id "repairRow:$List" -Message 'Toolbox repair row skipped' -Data @{ list = $List; type = (ConvertTo-ScreenText -Text $row.GetType().FullName) }
  }
}

function ConvertTo-RepairEntry {
  # Private. A panel's object (Run, Result, Confirm) as hashtables all the way down (ConvertTo-HashtableDeep), once
  # per render: a hashtable may hold objects read from JSON (Offers, Files, Remote, the rows). Anything that is neither
  # a hashtable nor such an object is $null.
  [CmdletBinding()]
  param([AllowNull()]$Entry)

  if ($Entry -is [System.Collections.IDictionary] -or $Entry -is [System.Management.Automation.PSCustomObject]) { return (ConvertTo-HashtableDeep -InputObject $Entry) }
  return $null
}

function New-RepairLineRow {
  # Private. One line of a list: a bullet (or a glyph) and the text beside it, wrapping under itself.
  [CmdletBinding()]
  [OutputType([System.Windows.Controls.Grid])]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [string]$Brush = 'TextBrush',
    [int]$Glyph = 0
  )

  $row = New-Object System.Windows.Controls.Grid
  $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 5)
  foreach ($width in [System.Windows.GridLength]::Auto, (New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star))) {
    $column = New-Object System.Windows.Controls.ColumnDefinition
    $column.Width = $width
    $null = $row.ColumnDefinitions.Add($column)
  }
  $mark = New-Object System.Windows.Controls.TextBlock
  if ($Glyph -gt 0) {
    $mark.Style = $Window.FindResource('GlyphStyle')
    $mark.FontSize = [double]$Window.FindResource('SmallGlyphFontSize')
    $mark.Text = [string][char]$Glyph
    $mark.Foreground = $Window.FindResource($Brush)
    $mark.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $mark.Margin = New-Object System.Windows.Thickness(0, 3, 8, 0)
  } else {
    $mark.Text = [string][char]0x2022
    $mark.Foreground = $Window.FindResource('SubtleTextBrush')
    $mark.Margin = New-Object System.Windows.Thickness(2, 0, 8, 0)
  }
  $block = New-ToolboxTextBlock -Window $Window -Style 'PanelTextStyle'
  $block.Text = $Text
  $block.Foreground = $Window.FindResource($Brush)
  [System.Windows.Controls.Grid]::SetColumn($block, 1)
  $null = $row.Children.Add($mark)
  $null = $row.Children.Add($block)
  return $row
}

function New-RepairValueBox {
  # Private. A machine value (an adapter's settings, a path) in a dark box, always left-to-right.
  [CmdletBinding()]
  [OutputType([System.Windows.Controls.Border])]
  param([Parameter(Mandatory)][System.Windows.Window]$Window, [Parameter(Mandatory)][string]$Text)

  $box = New-Object System.Windows.Controls.Border
  $box.Background = $Window.FindResource('BgBrush')
  $box.CornerRadius = New-Object System.Windows.CornerRadius(4)
  $box.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6)
  $box.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
  $box.FlowDirection = [System.Windows.FlowDirection]::LeftToRight
  $block = New-ToolboxTextBlock -Window $Window -Style 'PanelSmallTextStyle'
  $block.Text = $Text
  $box.Child = $block
  return $box
}

function Set-RepairChips {
  # Private. The safety strip (Get-RepairChips): each chip's text, glyph, colours, tooltip and visibility, and what
  # the chips bring: Restart PC beside a red restart chip, the backed-up switch with a failing disk, the no-stick banner.
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $model = $state.Model
  $language = [string]$model.Language
  $visible = [System.Windows.Visibility]::Visible
  $collapsed = [System.Windows.Visibility]::Collapsed

  foreach ($chip in @(Get-RepairChips -Model $model)) {
    $border = $Window.FindName('Chip' + $chip.Name)
    $border.Visibility = $(if ($chip.Visible) { $visible } else { $collapsed })
    $border.Background = $Window.FindResource($script:RepairChipBacks[$chip.Level])
    $glyph = $Window.FindName('Chip' + $chip.Name + 'Glyph')
    $glyph.Text = [string][char]$chip.Glyph
    $glyph.Foreground = $Window.FindResource($script:RepairChipFores[$chip.Level])
    $Window.FindName('Chip' + $chip.Name + 'Text').Text = Format-RepairText -State $state -Key $chip.TextKey -Arguments @($chip.Args)
    $tips = @(foreach ($key in @($chip.Tips)) { Get-ToolboxString -Table $state.Strings -Language $language -Key $key })
    Set-RepairTip -Window $Window -Owner $border -Text ($tips -join "`n")
    if ($chip.Name -ceq 'Restart') { $Window.FindName('ChipRestartButton').Visibility = $(if ($chip.Level -ceq 'crit') { $visible } else { $collapsed }) }
    if ($chip.Name -ceq 'Disk') { $Window.FindName('BackedUpSwitch').Visibility = $(if ($chip.Level -ceq 'crit') { $visible } else { $collapsed }) }
    if ($chip.Name -ceq 'Stick') { $Window.FindName('NoStickBanner').Visibility = $(if ($chip.Level -ceq 'crit') { $visible } else { $collapsed }) }
  }
  $Window.FindName('BackedUpSwitch').IsChecked = ($model.Repair['BackedUp'] -eq $true)
  $Window.FindName('ChipRestartButton').IsEnabled = (Get-RepairGate -Model $model -ActionId 'restart').Enabled
}

function Set-RepairGatedButton {
  # Private. A button that starts an action: shown, enabled and with its reason as its tooltip (or none) by the gate.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][System.Windows.Controls.Button]$Button,
    [Parameter(Mandatory)][string]$ActionId,
    [bool]$Show = $true
  )

  $state = $Window.Tag
  $gate = Get-RepairGate -Model $state.Model -ActionId $ActionId
  $Button.Visibility = $(if ($Show -and $gate.Visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
  $Button.IsEnabled = $gate.Enabled
  $reason = ''
  if (-not $gate.Enabled -and $gate.Reason -ne '') { $reason = Get-ToolboxString -Table $state.Strings -Language ([string]$state.Model.Language) -Key $gate.Reason }
  Set-RepairTip -Window $Window -Owner $Button -Text $reason
}

function Set-RepairWhatPanel {
  # Private. What the selected (or hovered) tile does: its glyph, title, paragraph and change list; a hint without one.
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $language = [string]$state.Model.Language
  $id = [string]$state.Model.Repair['Selected']
  $changes = $Window.FindName('WhatChanges')
  $changes.Children.Clear()
  $text = $Window.FindName('WhatText')
  $tile = $null
  if ($id -ne '' -and $state.Strings['en'].ContainsKey("tile.$id.what")) { $tile = $Window.FindName((Get-RepairElementName -Id $id)) }

  if ($null -eq $tile) {
    $Window.FindName('WhatHeader').Visibility = [System.Windows.Visibility]::Collapsed
    $text.Text = Get-ToolboxString -Table $state.Strings -Language $language -Key 'what.empty'
    $text.Foreground = $Window.FindResource('DimTextBrush')
    return
  }
  $Window.FindName('WhatHeader').Visibility = [System.Windows.Visibility]::Visible
  $Window.FindName('WhatGlyph').Text = [string]$tile.Content.Children[0].Text
  $Window.FindName('WhatTitle').Text = Get-RepairActionTitle -State $state -Id $id
  $text.Text = Get-ToolboxString -Table $state.Strings -Language $language -Key "tile.$id.what"
  $text.Foreground = $Window.FindResource('TextBrush')
  if ($state.Strings['en'].ContainsKey("tile.$id.changes")) {
    $header = New-ToolboxTextBlock -Window $Window -Style 'SectionTitleStyle'
    $header.Text = Get-ToolboxString -Table $state.Strings -Language $language -Key 'confirm.changes'
    $header.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    $null = $changes.Children.Add($header)
    foreach ($line in ((Get-ToolboxString -Table $state.Strings -Language $language -Key "tile.$id.changes") -split "`n")) {
      $null = $changes.Children.Add((New-RepairLineRow -Window $Window -Text $line))
    }
  }
}

function Set-RepairConfirmPanel {
  <#
  .SYNOPSIS
    Private. The confirmation (spec 4.2): its title, its lines, its items, the at-PC switch, YES and Confirm.
  .DESCRIPTION
    Confirm.Lines (review M2), each entry one of:
      @{ Key = '<string key>'; Args = @(...) }  a text of the window's language, its Args filled in (machine values
                                                left-to-right, Format-RepairText): a tile's change list (bullets under
                                                "This will change:"), a warning (warn.*, confirm.noStickLog: yellow), an
                                                adapter's settings (confirm.static: a left-to-right value line in
                                                ConfirmItems) or a plain line (confirm.ghostCount, confirm.noStatic ...);
      @{ Ltr = '<machine value>' }              a value line in ConfirmItems, left-to-right.
    An entry that is neither, or whose Key the string table lacks, is skipped and logged once (WARN 'Toolbox repair
    row skipped'). Confirm.Items (Ghost devices) are switches, all left-to-right. Network reset always shows the at-PC
    switch (ruling RD-R2) and the warning that the reset cuts remote sessions, red when an RDP session was detected
    (Confirm.Remote.Rdp).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $model = $state.Model
  $language = [string]$model.Language
  $visible = [System.Windows.Visibility]::Visible
  $collapsed = [System.Windows.Visibility]::Collapsed
  $confirm = ConvertTo-RepairEntry -Entry $model.Repair['Confirm']
  $action = [string]$confirm['Action']
  $lines = $Window.FindName('ConfirmLines')
  $items = $Window.FindName('ConfirmItems')
  $lines.Children.Clear()
  $items.Children.Clear()

  $Window.FindName('ConfirmTitle').Text = $(if ($action -ceq 'restart') { Get-ToolboxString -Table $state.Strings -Language $language -Key 'confirm.restart' } else { Get-RepairActionTitle -State $state -Id $action })
  $Window.FindName('ConfirmGoText').Text = Get-ToolboxString -Table $state.Strings -Language $language -Key $(if ($action -ceq 'restart') { 'confirm.restartGo' } else { 'confirm.go' })

  if ($confirm['Loading'] -eq $true) {
    $null = $lines.Children.Add((New-RepairLineRow -Window $Window -Text (Get-ToolboxString -Table $state.Strings -Language $language -Key 'confirm.loading') -Brush 'SubtleTextBrush' -Glyph 0xE895))
  }
  foreach ($line in @(ConvertTo-RepairRows -Rows $confirm['Lines'] -List 'lines')) {
    $key = [string]$line['Key']
    $ltr = [string]$line['Ltr']
    $lineArgs = @(@($line['Args']) | Where-Object { $null -ne $_ })
    if ($key -eq '' -and $ltr -ne '') {
      $null = $items.Children.Add((New-RepairValueBox -Window $Window -Text $ltr))
      continue
    }
    if ($key -eq '' -or -not $state.Strings['en'].ContainsKey($key)) {
      Write-ToolboxWarningOnce -Id 'repairRow:lines' -Message 'Toolbox repair row skipped' -Data @{ list = 'lines'; key = (ConvertTo-ScreenText -Text $key) }
      continue
    }
    if ($key -ceq 'confirm.static') {
      # An adapter's settings: machine values only, the whole line left-to-right.
      $null = $items.Children.Add((New-RepairValueBox -Window $Window -Text (Get-ToolboxString -Table $state.Strings -Language 'en' -Key $key -Arguments $lineArgs)))
      continue
    }
    $text = Format-RepairText -State $state -Key $key -Arguments $lineArgs
    if ($key -like 'tile.*.changes') {
      $header = New-ToolboxTextBlock -Window $Window -Style 'SectionTitleStyle'
      $header.Text = Get-ToolboxString -Table $state.Strings -Language $language -Key 'confirm.changes'
      $header.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
      $null = $lines.Children.Add($header)
      foreach ($part in ($text -split "`n")) { $null = $lines.Children.Add((New-RepairLineRow -Window $Window -Text $part)) }
    } elseif ($key -like 'warn.*' -or $key -ceq 'confirm.noStickLog') {
      $null = $lines.Children.Add((New-RepairLineRow -Window $Window -Text $text -Brush 'WarnBrush' -Glyph 0xE7BA))
    } else {
      $null = $lines.Children.Add((New-RepairLineRow -Window $Window -Text $text))
    }
  }

  $remote = $confirm['Remote']
  $atPc = ($action -ceq 'netReset' -or $null -ne $remote)
  if ($atPc) {
    $rdp = ($remote -is [System.Collections.IDictionary] -and $remote['Rdp'] -eq $true)
    $key = if ($rdp) { 'confirm.rdp' } else { 'confirm.remote' }
    $null = $lines.Children.Add((New-RepairLineRow -Window $Window -Text (Get-ToolboxString -Table $state.Strings -Language $language -Key $key) `
      -Brush $(if ($rdp) { 'CritBrush' } else { 'WarnBrush' }) -Glyph 0xE7BA))
  }
  $switch = $Window.FindName('AtPcSwitch')
  $switch.Visibility = $(if ($atPc) { $visible } else { $collapsed })
  $switch.IsChecked = ($confirm['AtPc'] -eq $true)

  $index = 0
  foreach ($item in @(ConvertTo-RepairRows -Rows $confirm['Items'] -List 'items')) {
    $box = New-Object System.Windows.Controls.CheckBox
    $box.Style = $Window.FindResource('SwitchStyle')
    $box.Tag = "a:GhostTick:$index"
    $box.IsChecked = ($item['Ticked'] -eq $true)
    $box.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
    $box.FlowDirection = [System.Windows.FlowDirection]::LeftToRight
    $label = New-ToolboxTextBlock -Window $Window -Style 'PanelSmallTextStyle'
    $label.Text = ('{0} ({1})' -f [string]$item['Name'], [string]$item['Class'])
    $box.Content = $label
    $null = $items.Children.Add($box)
    $index++
  }

  $Window.FindName('YesPanel').Visibility = $(if ([string]$confirm['Kind'] -ceq 'yes') { $visible } else { $collapsed })
  $Window.FindName('ConfirmButton').IsEnabled = (Test-RepairConfirmReady -Model $model)
}

function Set-RepairRunPanel {
  # Private. The running action (spec 4.1, 4.3): each step with its glyph, the bar after the running step when its
  # percent is known, the elapsed time, the log tail (the last 8 lines, left-to-right), Stop and its "Stopping
  # after <step>...", and the refused close.
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $model = $state.Model
  $language = [string]$model.Language
  $visible = [System.Windows.Visibility]::Visible
  $collapsed = [System.Windows.Visibility]::Collapsed
  $run = ConvertTo-RepairEntry -Entry $model.Repair['Run']
  $culture = [Globalization.CultureInfo]::InvariantCulture

  $Window.FindName('RunTitle').Text = Get-RepairActionTitle -State $state -Id ([string]$run['Action'])
  $steps = $Window.FindName('RunSteps')
  $barRow = $Window.FindName('RunBarRow')
  $steps.Children.Clear()
  $current = ''
  foreach ($step in @(ConvertTo-RepairRows -Rows $run['Steps'] -List 'steps')) {
    $id = [string]$step['Id']
    $status = [string]$step['Status']
    $look = $script:RepairStepLooks[$status]
    if ($null -eq $look) { $look = $script:RepairStepLooks['pending'] }

    $row = New-Object System.Windows.Controls.Grid
    foreach ($width in (New-Object System.Windows.GridLength(22)), (New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star))) {
      $column = New-Object System.Windows.Controls.ColumnDefinition
      $column.Width = $width
      $null = $row.ColumnDefinitions.Add($column)
    }
    $glyph = New-ToolboxTextBlock -Window $Window -Style 'GlyphStyle'
    $glyph.FontSize = [double]$Window.FindResource('SmallGlyphFontSize')
    $glyph.Text = [string][char]$look.Glyph
    $glyph.Foreground = $Window.FindResource($look.Brush)
    $name = New-ToolboxTextBlock -Window $Window -Style 'PlanLineStyle'
    $name.Text = Get-RepairActionTitle -State $state -Id $id -Step
    $name.Foreground = $Window.FindResource($look.Text)
    if ($status -ceq 'running') { $name.FontWeight = [System.Windows.FontWeights]::SemiBold; $current = $name.Text }
    [System.Windows.Controls.Grid]::SetColumn($name, 1)
    $null = $row.Children.Add($glyph)
    $null = $row.Children.Add($name)
    $null = $steps.Children.Add($row)

    $percent = $step['Percent']
    if ($status -ceq 'running' -and $null -eq $percent) { $percent = $run['Percent'] }
    if ($status -ceq 'running' -and $null -ne $percent) {
      $value = [math]::Max(0, [math]::Min(100, [double]$percent))
      $Window.FindName('RunBar').Value = $value
      $Window.FindName('RunPercent').Text = [string]::Format($culture, '{0:0}%', $value)
      $null = $steps.Children.Add($barRow)
    }
  }

  $Window.FindName('RunElapsed').Text = Format-RepairText -State $state -Key 'run.elapsed' -Arguments @(Format-RepairElapsed -Seconds ([int]$run['ElapsedSeconds']))
  $log = @($run['Log'] | ForEach-Object { [string]$_ })
  if ($log.Count -gt 8) { $log = $log[($log.Count - 8)..($log.Count - 1)] }
  $Window.FindName('RunLog').Text = ($log -join "`n")

  $stopping = ($run['Stopping'] -eq $true)
  $Window.FindName('StopButton').IsEnabled = (-not $stopping)
  $stoppingText = $Window.FindName('StoppingText')
  $stoppingText.Visibility = $(if ($stopping) { $visible } else { $collapsed })
  $stoppingText.Text = $(if ($stopping) { Get-ToolboxString -Table $state.Strings -Language $language -Key 'run.stopping' -Arguments @($current) } else { '' })
  $Window.FindName('CloseRefusedText').Visibility = $(if ($model.Repair['CloseRefused'] -eq $true) { $visible } else { $collapsed })
}

function Set-RepairResultPanel {
  # Private. The finished action (spec 4.1): the banner in the result's colour, the findings coloured by level in the
  # window's language (the child's English text for a code the table does not know), the restart line, the offers
  # (Disk check at restart, DISM from a local source), the folder of the logs and reports, Open folder and Restart PC.
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $model = $state.Model
  $language = [string]$model.Language
  $visible = [System.Windows.Visibility]::Visible
  $collapsed = [System.Windows.Visibility]::Collapsed
  $result = ConvertTo-RepairEntry -Entry $model.Repair['Result']

  $color = [string]$result['Color']
  $look = switch -CaseSensitive ($color) {
    'GREEN' { @{ Back = 'OkBackBrush'; Glyph = 0xE73E; Brush = 'OkBrush' } }
    'YELLOW' { @{ Back = 'WarnBackBrush'; Glyph = 0xE7BA; Brush = 'WarnBrush' } }
    default { @{ Back = 'DangerBackBrush'; Glyph = 0xE783; Brush = 'CritBrush' } }
  }
  $Window.FindName('ResultBanner').Background = $Window.FindResource($look.Back)
  $glyph = $Window.FindName('ResultGlyph')
  $glyph.Text = [string][char]$look.Glyph
  $glyph.Foreground = $Window.FindResource($look.Brush)
  $Window.FindName('ResultAction').Text = Get-RepairActionTitle -State $state -Id ([string]$result['Action'])
  $outcome = [string]$result['Outcome']
  $Window.FindName('ResultOutcome').Text = $(if ($state.Strings['en'].ContainsKey("result.outcome.$outcome")) { Get-ToolboxString -Table $state.Strings -Language $language -Key "result.outcome.$outcome" } else { $outcome })

  $findings = $Window.FindName('ResultFindings')
  $findings.Children.Clear()
  $levelBrush = @{ CRIT = 'CritBrush'; WARN = 'WarnBrush'; INFO = 'DimTextBrush' }
  foreach ($finding in @(ConvertTo-RepairRows -Rows $result['Findings'] -List 'findings')) {
    $code = [string]$finding['Code']
    $row = New-ToolboxTextBlock -Window $Window -Style 'PanelTextStyle'
    $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    if ($state.Strings['en'].ContainsKey("finding.$code")) {
      $row.Text = Format-RepairText -State $state -Key "finding.$code" -Arguments @(@($finding['Args']) | Where-Object { $null -ne $_ })
    } else {
      # The child's English text: left-to-right, so its brackets and codes read right in a Hebrew window too.
      $row.Text = [string]$finding['Text']
      $row.FlowDirection = [System.Windows.FlowDirection]::LeftToRight
    }
    $brush = $levelBrush[[string]$finding['Level']]
    $row.Foreground = $Window.FindResource($(if ($null -eq $brush) { 'TextBrush' } else { $brush }))
    if ([string]$finding['Level'] -ceq 'CRIT') { $row.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $null = $findings.Children.Add($row)
  }
  if ($findings.Children.Count -eq 0) {
    $none = New-ToolboxTextBlock -Window $Window -Style 'PanelTextStyle'
    $none.Text = Get-ToolboxString -Table $state.Strings -Language $language -Key 'result.none'
    $none.Foreground = $Window.FindResource('OkBrush')
    $null = $findings.Children.Add($none)
  }

  $restartNeeded = ($result['RestartRequired'] -eq $true)
  $Window.FindName('ResultRestartNeeded').Visibility = $(if ($restartNeeded) { $visible } else { $collapsed })
  $offers = $result['Offers']
  if ($offers -isnot [System.Collections.IDictionary]) { $offers = @{} }
  Set-RepairGatedButton -Window $Window -Button $Window.FindName('OfferDiskCheckButton') -ActionId 'diskCheck' -Show ($offers['DiskCheck'] -eq $true)
  $dism = $offers['DismSource']
  Set-RepairGatedButton -Window $Window -Button $Window.FindName('OfferDismButton') -ActionId 'dismSource' -Show ($dism -is [System.Collections.IDictionary])
  if ($dism -is [System.Collections.IDictionary]) {
    $Window.FindName('OfferDismText').Text = Get-ToolboxString -Table $state.Strings -Language $language -Key 'result.offerDism' `
      -Arguments @([string]$dism['Path'], [string]$dism['Edition'], [string]$dism['Arch'], (@($dism['Languages']) -join ', '), [string]$dism['Build'])
    $notes = New-Object System.Collections.Generic.List[string]
    if ($dism['BuildDiffers'] -eq $true) { $notes.Add((Format-RepairText -State $state -Key 'result.buildDiffers' -Arguments @([string]$state.Machine['OsBuild']))) }
    if ($dism['LanguageDiffers'] -eq $true) {
      $notes.Add((Format-RepairText -State $state -Key 'result.languageDiffers' -Arguments @((@($dism['Languages']) -join ', '), [string]$dism['PcLanguage'])))
    }
    $note = $Window.FindName('OfferDismNote')
    $note.Text = ($notes -join "`n")
    $note.Visibility = $(if ($notes.Count -gt 0) { $visible } else { $collapsed })
  }

  $files = $result['Files']
  $folder = if ($files -is [System.Collections.IDictionary]) { [string]$files['Folder'] } else { '' }
  $hasFolder = ($folder -ne '')
  foreach ($name in 'ResultFilesLabel', 'ResultFiles', 'OpenFolderButton') { $Window.FindName($name).Visibility = $(if ($hasFolder) { $visible } else { $collapsed }) }
  $Window.FindName('ResultFiles').Text = $folder
  $restart = $Window.FindName('RestartButton')
  $restart.Style = $Window.FindResource($(if ($restartNeeded) { 'AccentButtonStyle' } else { 'PlainButtonStyle' }))
  $restart.IsEnabled = (Get-RepairGate -Model $model -ActionId 'restart').Enabled
}

function Update-RepairView {
  <#
  .SYNOPSIS
    Renders the model's page into the window (repair spec 4.1). Returns nothing. Update-ToolboxView calls it last.
  .DESCRIPTION
    The page: NavSetup / NavRepair checked as Model.Page says, the chosen one's glyph in the accent colour; the setup
    page shows AdminBanner, WarnPanel (as Update-ToolboxView set them), SetupOptions, SetupRight, the new name and the
    power chip of the machine card; the repair page shows RepairCenter, RepairRight and the PC's present name instead
    (its strip has the power chip).
    Then, on the repair page only:
      - the chips (Get-RepairChips: text, glyph, colours by level, tooltip; ChipPower on laptops only), Restart PC
        beside a red restart chip, the backed-up switch with a failing disk, the no-stick banner;
      - every tile's IsEnabled, Visibility and ToolTip (the reason's text, or none when enabled) from Get-RepairGate,
        the selected tile outlined, Restore network settings shown with a saved backup;
      - the right column, one panel in this priority: the confirmation, the run, the result, what the tile does.
    The YES box is emptied when a new confirmation opens (another action than the one shown, or none before); it
    and the complaint box are never written otherwise.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $model = $state.Model
  $repair = $model['Repair']
  $visible = [System.Windows.Visibility]::Visible
  $collapsed = [System.Windows.Visibility]::Collapsed
  $onRepair = ($model['Page'] -ceq 'repair' -and $repair -is [System.Collections.IDictionary])

  $Window.FindName('NavSetup').IsChecked = (-not $onRepair)
  $Window.FindName('NavRepair').IsChecked = $onRepair
  $Window.FindName('NavSetupGlyph').Foreground = $Window.FindResource($(if ($onRepair) { 'SubtleTextBrush' } else { 'AccentBrush' }))
  $Window.FindName('NavRepairGlyph').Foreground = $Window.FindResource($(if ($onRepair) { 'AccentBrush' } else { 'SubtleTextBrush' }))
  foreach ($name in 'SetupOptions', 'SetupRight', 'MachineNewNamePart', 'PowerChip') { $Window.FindName($name).Visibility = $(if ($onRepair) { $collapsed } else { $visible }) }
  foreach ($name in 'RepairCenter', 'RepairRight', 'MachinePcNamePart') { $Window.FindName($name).Visibility = $(if ($onRepair) { $visible } else { $collapsed }) }
  if (-not $onRepair) { return }
  foreach ($name in 'AdminBanner', 'WarnPanel') { $Window.FindName($name).Visibility = $collapsed }

  Set-RepairChips -Window $Window

  $selected = [string]$repair['Selected']
  foreach ($id in @($script:RepairTileRows.Values | ForEach-Object { $_ })) {
    $tile = $Window.FindName((Get-RepairElementName -Id $id))
    Set-RepairGatedButton -Window $Window -Button $tile -ActionId $id
    $tile.BorderBrush = $Window.FindResource($(if ($id -ceq $selected) { 'AccentBrush' } else { 'LineBrush' }))
  }
  Set-RepairGatedButton -Window $Window -Button $Window.FindName('NetRestoreButton') -ActionId 'netRestore'

  $panel = 'WhatPanel'
  if ($null -ne $repair['Confirm']) { $panel = 'ConfirmPanel' } elseif ($null -ne $repair['Run']) { $panel = 'RunPanel' } elseif ($null -ne $repair['Result']) { $panel = 'ResultPanel' }
  foreach ($name in 'WhatPanel', 'ConfirmPanel', 'RunPanel', 'ResultPanel') { $Window.FindName($name).Visibility = $(if ($name -ceq $panel) { $visible } else { $collapsed }) }

  $confirmKey = ''
  $openConfirm = ConvertTo-RepairEntry -Entry $repair['Confirm']
  if ($null -ne $openConfirm) { $confirmKey = [string]$openConfirm['Action'] }
  if ($confirmKey -ne '' -and $confirmKey -cne [string]$state['RepairConfirmKey']) { $Window.FindName('YesBox').Text = '' }
  $state['RepairConfirmKey'] = $confirmKey

  switch -CaseSensitive ($panel) {
    'WhatPanel' { Set-RepairWhatPanel -Window $Window }
    'ConfirmPanel' { Set-RepairConfirmPanel -Window $Window }
    'RunPanel' { Set-RepairRunPanel -Window $Window }
    'ResultPanel' { Set-RepairResultPanel -Window $Window }
  }
}
