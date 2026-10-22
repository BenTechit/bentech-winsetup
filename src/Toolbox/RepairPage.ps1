# src/Toolbox/RepairPage.ps1
# The Repair & diagnostics page's view (repair spec 4.1-4.4, 5; repair plan "XAML contract additions"):
# Update-RepairView renders the toolbox model's Page and Repair (RepairPlanner.ps1) into the window that
# New-ToolboxWindow (Toolbox.ps1) built from Xaml.ps1. Update-ToolboxView calls it last, on every render.
#
# The rules of Toolbox.ps1 hold here too: the model decides every state (a control never decides its own); every
# .NET call's output goes to $null, so each function returns exactly one value or nothing; no console, no sleep, no
# closures, no handler (the one exception: the run timer's one-line Tick, which calls Invoke-ToolboxAction as the
# power timer's does); colours come from the window's one resource dictionary. Texts come from the string table in
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
# Task 4: it also runs the actions (the section "Running actions"): each in a hidden child process started
# without waiting, polled every 500 ms, killed at its deadline on its own Stopwatch, stopped between steps on request,
# and every child it started killed before the window closes (Stop-ToolboxChildren).
# Task 5 (the section "The page at work" at the end): the action the model asks for (Start-ToolboxPendingRun), the
# info child an open confirmation waits for and its answer (Start-ToolboxInfoRun, Complete-ToolboxInfoRun), the stick
# re-checked on the page (Get-ToolboxStickPresence, Update-ToolboxStick; ruling RD-R3) and Open folder
# (Open-ToolboxFolder).
#
# Needs Toolbox.ps1 (Get-ToolboxString, New-ToolboxTextBlock, Write-ToolboxWarningOnce, Invoke-ToolboxAction),
# RepairPlanner.ps1 (Get-RepairGate, Get-RepairChips, Test-RepairConfirmReady, Format-RepairElapsed, the run in the
# model, $script:RepairTileRows), State.ps1 (ConvertTo-HashtableDeep), StartScreen.ps1 (ConvertTo-ScreenText),
# Repair\ToolEngine.ps1 (Read-ToolJsonFile, Write-ToolJsonFile, Get-ToolConfigMinutes, Format-ToolTime,
# $script:ToolActionCatalog), Detect\PcName.ps1 (Get-MachineIdentity), Common\Process.ps1 (Stop-ProcessTree; the
# StartChild seam's Start-BackgroundExternal), Common\Logging.ps1 and WPF; the bundle holds every file.

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
                                                "This will change:"), a warning (warn.*, confirm.noStickLog and the DISM
                                                file's result.buildDiffers / result.languageDiffers: yellow), a line of
                                                machine values (confirm.static, an adapter's settings, and
                                                result.offerDism, the DISM file: a left-to-right value line in
                                                ConfirmItems) or a plain line (confirm.ghostCount, confirm.noStatic ...);
      @{ Ltr = '<machine value>' }              a value line in ConfirmItems, left-to-right.
    An entry that is neither, or whose Key the string table lacks, is skipped and logged once (WARN 'Toolbox repair
    row skipped'). Confirm.Items (Ghost devices) are switches, all left-to-right, each clicking GhostTick <index>
    (repair Task 5: they are made here, after Register-ToolboxHandlers, so each gets its one-line Click handler
    here). Network reset always shows the at-PC switch (ruling RD-R2) and the warning that the reset cuts remote
    sessions, red when an RDP session was detected (Confirm.Remote.Rdp); so does any confirmation with a Remote.
    ConfirmItems is rebuilt only when what it shows changed (Tag.RepairItemsShape: the language, the action, its value
    lines and its devices; not the ticks): the run timer renders every 500 ms while a strip read runs, and a switch
    replaced under the mouse would lose its click and its scroll position. A tick sets the switches in place.
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

  $Window.FindName('ConfirmTitle').Text = $(if ($action -ceq 'restart') { Get-ToolboxString -Table $state.Strings -Language $language -Key 'confirm.restart' } else { Get-RepairActionTitle -State $state -Id $action })
  $Window.FindName('ConfirmGoText').Text = Get-ToolboxString -Table $state.Strings -Language $language -Key $(if ($action -ceq 'restart') { 'confirm.restartGo' } else { 'confirm.go' })

  if ($confirm['Loading'] -eq $true) {
    $null = $lines.Children.Add((New-RepairLineRow -Window $Window -Text (Get-ToolboxString -Table $state.Strings -Language $language -Key 'confirm.loading') -Brush 'SubtleTextBrush' -Glyph 0xE895))
  }
  $values = New-Object System.Collections.Generic.List[string]   # the value lines of ConfirmItems, in order
  foreach ($line in @(ConvertTo-RepairRows -Rows $confirm['Lines'] -List 'lines')) {
    $key = [string]$line['Key']
    $ltr = [string]$line['Ltr']
    $lineArgs = @(@($line['Args']) | Where-Object { $null -ne $_ })
    if ($key -eq '' -and $ltr -ne '') {
      $values.Add($ltr)
      continue
    }
    if ($key -eq '' -or -not $state.Strings['en'].ContainsKey($key)) {
      Write-ToolboxWarningOnce -Id 'repairRow:lines' -Message 'Toolbox repair row skipped' -Data @{ list = 'lines'; key = (ConvertTo-ScreenText -Text $key) }
      continue
    }
    if ($key -cin 'confirm.static', 'result.offerDism') {
      # Machine values only (an adapter's settings, the DISM file): the whole line left-to-right.
      $values.Add((Get-ToolboxString -Table $state.Strings -Language 'en' -Key $key -Arguments $lineArgs))
      continue
    }
    $text = Format-RepairText -State $state -Key $key -Arguments $lineArgs
    if ($key -like 'tile.*.changes') {
      $header = New-ToolboxTextBlock -Window $Window -Style 'SectionTitleStyle'
      $header.Text = Get-ToolboxString -Table $state.Strings -Language $language -Key 'confirm.changes'
      $header.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
      $null = $lines.Children.Add($header)
      foreach ($part in ($text -split "`n")) { $null = $lines.Children.Add((New-RepairLineRow -Window $Window -Text $part)) }
    } elseif ($key -like 'warn.*' -or $key -cin 'confirm.noStickLog', 'result.buildDiffers', 'result.languageDiffers') {
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

  $devices = @(ConvertTo-RepairRows -Rows $confirm['Items'] -List 'items')
  $shape = New-Object System.Text.StringBuilder
  $null = $shape.Append($language).Append([char]0x1F).Append($action)
  foreach ($value in $values) { $null = $shape.Append([char]0x1E).Append($value) }
  foreach ($item in $devices) { $null = $shape.Append([char]0x1D).Append([string]$item['InstanceId']).Append([char]0x1F).Append([string]$item['Name']).Append([char]0x1F).Append([string]$item['Class']) }
  if ($shape.ToString() -cne [string]$state['RepairItemsShape']) {
    $items.Children.Clear()
    foreach ($value in $values) { $null = $items.Children.Add((New-RepairValueBox -Window $Window -Text $value)) }
    $index = 0
    foreach ($item in $devices) {
      $box = New-Object System.Windows.Controls.CheckBox
      $box.Style = $Window.FindResource('SwitchStyle')
      $box.Tag = "a:GhostTick:$index"
      $box.IsChecked = ($item['Ticked'] -eq $true)
      $box.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
      $box.FlowDirection = [System.Windows.FlowDirection]::LeftToRight
      $label = New-ToolboxTextBlock -Window $Window -Style 'PanelSmallTextStyle'
      $label.Text = ('{0} ({1})' -f [string]$item['Name'], [string]$item['Class'])
      $box.Content = $label
      $box.Add_Click({ Invoke-ToolboxAction -Sender $this })
      $null = $items.Children.Add($box)
      $index++
    }
    $state['RepairItemsShape'] = $shape.ToString()
  } else {
    # The same devices: only their ticks, on the switches already there.
    foreach ($box in @($items.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })) {
      $at = [int]([string]$box.Tag).Substring('a:GhostTick:'.Length)
      $box.IsChecked = ($at -lt $devices.Count -and $devices[$at]['Ticked'] -eq $true)
    }
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
  # The key first: emptying the YES box raises its TextChanged (Task 5), which must find this confirmation known.
  $newConfirm = ($confirmKey -ne '' -and $confirmKey -cne [string]$state['RepairConfirmKey'])
  $state['RepairConfirmKey'] = $confirmKey
  if ($newConfirm) { $Window.FindName('YesBox').Text = '' }
  if ($panel -cne 'ConfirmPanel') { $state['RepairItemsShape'] = '' }   # a confirmation opened again is drawn afresh

  switch -CaseSensitive ($panel) {
    'WhatPanel' { Set-RepairWhatPanel -Window $Window }
    'ConfirmPanel' { Set-RepairConfirmPanel -Window $Window }
    'RunPanel' { Set-RepairRunPanel -Window $Window }
    'ResultPanel' { Set-RepairResultPanel -Window $Window }
  }
}

# --- Running actions (repair Task 4; repair spec 4.3, 4.4, 7) --------------------------------------------------------
# Each action runs in its own hidden child process of the same setup.ps1 (-ToolAction <id> -ToolArgs <args.json>),
# started through the window's StartChild seam (Start-BackgroundExternal: no wait, the second named exception to
# "every child goes through Invoke-External"). Two slots: Action (the action the technician started; the run panel
# shows it) and Safety (the safety strip's child). Tag.Runs.<Slot> = @{ ActionId; RunId; Process; Dir; StartedUtc;
# DeadlineUtc; Clock; BudgetSeconds; Chips }. The run timer (500 ms) polls each busy slot's progress.json and, once its
# process has exited, its result.json. The window kills a child that is still running at its budget + 3 minutes,
# measured on the run's own Stopwatch (rulings RD-R8, RD-R9: never the wall clock, which the time sync moves; the
# child's own Stopwatch starts only after PowerShell's start-up and the bundle's parsing, so it stops itself first).
# Stop only asks (stop.flag): the child stops between steps (spec 4.3). Nothing here waits on a process or sleeps.

# The processes the window started, so Get-SetupChoices' finally can kill them once the window is gone (a script-scope
# exception to "no outer variables", plan WPF rules; no handler reads it).
$script:ToolboxChildren = New-Object 'System.Collections.Generic.List[object]'

# How long past its budget a child may still run before the window kills its process tree (ruling RD-R9).
$script:ToolboxKillGraceSeconds = 180

function Test-ToolboxActionRunning {
  # $true while the Action slot is busy: an action's child runs (spec 4.4: no close, no page change, no Start, no
  # Restart PC). The safety child alone holds nothing. Never throws.
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()]$State)

  return ($State -is [System.Collections.IDictionary] -and $State['Runs'] -is [System.Collections.IDictionary] -and $null -ne $State['Runs']['Action'])
}

function Set-ToolboxRepair {
  # Private. Model.Repair with -Values set, as a copy: the repair model is replaced, never changed in place.
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Values)

  $next = $State.Model['Repair'].Clone()
  foreach ($key in @($Values.Keys)) { $next[$key] = $Values[$key] }
  $State.Model['Repair'] = $next
}

function New-ToolboxRunId {
  # Private. A run's id (plan "The files of one run"): 'yyyyMMdd-HHmmss-<action>' of -Time (local), invariant culture.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$ActionId, [Parameter(Mandatory)][datetime]$Time)

  return ('{0}-{1}' -f $Time.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture), $ActionId)
}

function Get-ToolboxBudgetSeconds {
  # Private. An action's whole time in seconds: config timeoutsMinutes.tool.<id> times 60, else 30 minutes (RD-R8).
  [CmdletBinding()]
  [OutputType([double])]
  param([AllowNull()]$Config, [Parameter(Mandatory)][string]$ActionId)

  $section = $null
  try { $section = $Config.timeoutsMinutes.tool } catch { $section = $null }
  $minutes = Get-ToolConfigMinutes -Section $section -Name $ActionId
  if ($null -eq $minutes) { $minutes = 30.0 }
  return [double]($minutes * 60)
}

function Get-ToolboxRunSeconds {
  <#
  .SYNOPSIS
    The seconds since the window started -Run's child, on the run's own Stopwatch (Run.Clock; rulings RD-R8, RD-R9:
    no deadline reads the wall clock). 0 without one. The deadline and the elapsed time shown both come from here;
    tests mock this seam.
  #>
  [CmdletBinding()]
  [OutputType([double])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $clock = $Run['Clock']
  if ($clock -is [Diagnostics.Stopwatch]) { return [double]$clock.Elapsed.TotalSeconds }
  return 0.0
}

function Get-ToolboxSessionDir {
  <#
  .SYNOPSIS
    The visit's folder (plan "Shared shapes", spec 8, ruling RD-R6): <stick>\BenTech-Reports\<PC>_<serial>_<stamp> with
    the stick, else <Root>\Logs\Repair\<PC>_<serial>_<stamp>.
  .DESCRIPTION
    <PC> is the computer name and <serial> Get-MachineIdentity's FolderPart, each reduced to [A-Za-z0-9-] ('PC' and
    'NOSERIAL' when nothing is left); <stamp> is the page's SessionStamp ('yyyy-MM-dd_HHmm', when the window opened),
    so every action of one visit writes to one folder. The child creates it (New-ToolSessionDir), never through a link.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$State)

  $repair = $State.Model['Repair']
  $machine = $State['Machine']
  if ($machine -isnot [hashtable]) { $machine = @{} }
  $identity = Get-MachineIdentity -Machine $machine
  $pc = ([string]$machine['ComputerName']) -creplace '[^A-Za-z0-9-]', ''
  if ($pc -eq '') { $pc = 'PC' }
  $serial = ([string]$identity['FolderPart']) -creplace '[^A-Za-z0-9-]', ''
  if ($serial -eq '') { $serial = 'NOSERIAL' }
  $stamp = ([string]$repair['SessionStamp']) -creplace '[^0-9_-]', ''
  if ($stamp -eq '') { $stamp = 'visit' }
  $name = '{0}_{1}_{2}' -f $pc, $serial, $stamp
  if (Test-RepairStick -Repair $repair) { return [IO.Path]::Combine([string]$repair['Stick']['Root'], 'BenTech-Reports', $name) }
  return [IO.Path]::Combine([string]$State['Root'], 'Logs', 'Repair', $name)
}

function New-ToolboxRunArgs {
  # Private. args.json of one run (plan "The files of one run"): everything the child needs, answered in the window.
  # Read-ToolArgs (the child) checks it; BudgetSeconds is required there (RD-R8), DeadlineUtc is for its log only.
  [CmdletBinding()]
  [OutputType([System.Collections.Specialized.OrderedDictionary])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][string]$ActionId,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][double]$BudgetSeconds,
    [Parameter(Mandatory)][string]$DeadlineUtc,
    [AllowNull()][hashtable]$Options
  )

  $repair = $State.Model['Repair']
  $machine = $State['Machine']
  if ($machine -isnot [hashtable]) { $machine = @{} }
  $identity = Get-MachineIdentity -Machine $machine
  $stickRoot = ''
  if (Test-RepairStick -Repair $repair) { $stickRoot = [string]$repair['Stick']['Root'] }
  $strip = @{}
  foreach ($name in $script:RepairChipNames) {
    $level = Get-RepairChipLevel -Repair $repair -Name $name
    $strip[$name] = $(if ($level -eq '') { 'unknown' } else { $level })
  }
  $complaint = [string]$repair['Complaint']
  if ($complaint.Length -gt 2000) { $complaint = $complaint.Substring(0, 2000) }
  $done = @(foreach ($entry in @($repair['Done'])) {
      if ($null -eq $entry) { continue }
      @{ Action = [string](Get-RepairEntry -From $entry -Name 'Action'); Outcome = [string](Get-RepairEntry -From $entry -Name 'Outcome')
         Color = [string](Get-RepairEntry -From $entry -Name 'Color'); EndedAt = [string](Get-RepairEntry -From $entry -Name 'EndedAt') }
    })
  return [ordered]@{
    Version       = 1
    Action        = $ActionId
    RunId         = $RunId
    DeadlineUtc   = $DeadlineUtc
    BudgetSeconds = $BudgetSeconds
    SessionDir    = (Get-ToolboxSessionDir -State $State)
    StickRoot     = $stickRoot
    Complaint     = $complaint
    Done          = $done
    Identity      = @{ Key = [string]$identity['Key']; FolderPart = [string]$identity['FolderPart']; Serial = [string]$identity['Serial']
                       BiosUuid = [string]$identity['BiosUuid']; ComputerName = [string]$machine['ComputerName']
                       Manufacturer = [string]$machine['Manufacturer']; Model = [string]$machine['Model']; Brand = [string]$machine['Brand'] }
    Machine       = @{ IsLaptop = ($machine['IsLaptop'] -eq $true); OsBuild = $machine['OsBuild']; Arch = [string]$machine['Arch'] }
    Strip         = $strip
    Options       = $(if ($null -ne $Options) { $Options } else { @{} })
  }
}

function Remove-ToolboxChild {
  # Private. -Process out of $script:ToolboxChildren (by reference): its run is over.
  [CmdletBinding()]
  param([AllowNull()]$Process)

  for ($i = $script:ToolboxChildren.Count - 1; $i -ge 0; $i--) {
    if ([object]::ReferenceEquals($script:ToolboxChildren[$i], $Process)) { $script:ToolboxChildren.RemoveAt($i) }
  }
}

function Stop-ToolboxChild {
  # Private. Kills -Process's tree (Stop-ProcessTree, which never throws) and returns $true when the process has ended:
  # it then leaves $script:ToolboxChildren. One that still runs (or whose state cannot be read) stays tracked, WARN
  # 'Toolbox child still running after the kill', so every later close retries it and Start-BenTechSetup removes no
  # folder under it (Test-ToolboxChildrenRunning; Task 4 review M3).
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()]$Process, [AllowEmptyString()][string]$Action = '')

  $id = $null
  try { $id = [int]$Process.Id } catch { $id = $null }
  if ($null -ne $id) { Stop-ProcessTree -ProcessId $id }
  $exited = $false
  try { $exited = [bool]$Process.HasExited } catch { $exited = $false }
  if ($exited) {
    Remove-ToolboxChild -Process $Process
    return $true
  }
  $tracked = $false
  foreach ($child in $script:ToolboxChildren.ToArray()) { if ([object]::ReferenceEquals($child, $Process)) { $tracked = $true } }
  if (-not $tracked) { $script:ToolboxChildren.Add($Process) }
  Write-SetupLog -Level WARN -Message 'Toolbox child still running after the kill' -Data @{ processId = $(if ($null -ne $id) { $id } else { 'unknown' }); action = $Action }
  return $false
}

function Start-ToolboxSafetyRun {
  # Private. A fresh read of the strip (the safety child). One that cannot even be asked for leaves the strip ready,
  # every chip unknown, so nothing stays blocked behind a strip that never loads.
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $null = Start-ToolboxRun -Window $Window -ActionId 'safety' -Slot 'Safety'
  if ($null -eq $state.Runs['Safety'] -and [string]$state.Model['Repair']['Strip']['State'] -cne 'ready') { Complete-ToolboxSafetyRun -Window $Window -Chips $null }
}

function Complete-ToolboxActionRun {
  # Private. An action's end (its result, or the window's own): the model (Complete-RepairRunModel: the result panel,
  # the visit's list, the strip loading), the one INFO line 'Toolbox action finished' (ASCII), and the strip read again
  # by a new safety child (Start-ToolboxSafetyRun). When a safety child still runs (it began before or during the
  # action), its reading is from before the action ended: it is marked Reread, its chips are no longer shown, and a
  # fresh one starts when it ends (Task 4 review M7). An info child's end (netInfo, ghostList: what an open
  # confirmation waits for) is Complete-ToolboxInfoRun's instead (repair Task 5).
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [AllowNull()]$Result,
    [Parameter(Mandatory)][string]$ActionId,
    [AllowEmptyString()][string]$RunId = '',
    [double]$Seconds = 0
  )

  if ($script:RepairInfoData.Contains($ActionId)) {
    Complete-ToolboxInfoRun -Window $Window -Result $Result -ActionId $ActionId -RunId $RunId
    return
  }
  $state = $Window.Tag
  $state.Model['Repair'] = Complete-RepairRunModel -Repair $state.Model['Repair'] -Result $Result
  $codes = @(foreach ($finding in @(Get-RepairEntry -From $Result -Name 'Findings')) {
      if (Test-RepairObject -Value $finding) { ConvertTo-ScreenText -Text ([string](Get-RepairEntry -From $finding -Name 'Code')) } })
  Write-SetupLog -Level INFO -Message 'Toolbox action finished' -Data @{
    action = (ConvertTo-ScreenText -Text $ActionId); runId = (ConvertTo-ScreenText -Text $RunId)
    outcome = (ConvertTo-ScreenText -Text ([string](Get-RepairEntry -From $Result -Name 'Outcome')))
    color = (ConvertTo-ScreenText -Text ([string](Get-RepairEntry -From $Result -Name 'Color')))
    minutes = [double][math]::Round([math]::Max(0, $Seconds) / 60, 1); findings = $codes }
  if ($null -eq $state.Runs['Safety']) {
    Start-ToolboxSafetyRun -Window $Window
  } else {
    $state.Runs['Safety']['Reread'] = $true
  }
}

function Complete-ToolboxSafetyRun {
  # Private. The safety child's end: the strip from -Chips (its result's Data.Chips, else the last partial ones), every
  # chip it did not read unknown, and ready (spec 5: unknown is yellow and blocks nothing); -DiskCheck (Data.DiskCheck)
  # into the model. Chips or a DiskCheck that are no object are not read.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [AllowNull()]$Chips,
    [AllowNull()]$DiskCheck
  )

  if (-not (Test-RepairObject -Value $Chips)) { $Chips = $null }
  $values = @{ Strip = (ConvertTo-RepairStrip -Chips $Chips -Final $true) }
  if (Test-RepairObject -Value $DiskCheck) {
    $values['DiskCheck'] = @{ Dirty = (Get-RepairEntry -From $DiskCheck -Name 'Dirty'); Excluded = ((Get-RepairEntry -From $DiskCheck -Name 'Excluded') -eq $true) }
  }
  Set-ToolboxRepair -State $Window.Tag -Values $values
}

function Start-ToolboxRun {
  <#
  .SYNOPSIS
    Starts -ActionId's child in -Slot (Action or Safety) without waiting (spec 7). $true when it started. Never waits.
  .DESCRIPTION
    Refused ($false, WARN 'Toolbox action refused: ...', nothing changes): a busy slot, a window without its setup files
    (Tag.Root, Tag.ScriptPath), an action this version's catalog does not have.
    Otherwise, in order:
      1. the RunId (New-ToolboxRunId; when <Root>\Tool\<RunId> is already there, the next second's, up to a minute
         on) and, for the Action slot, Model.Repair.Run with every step of the catalog pending (New-RepairRunModel);
      2. the run folder <Root>\Tool\<RunId>\ (one that is already there is never reused: a stale result.json in it
         would be read as this run's) and args.json (New-ToolboxRunArgs: BudgetSeconds = timeoutsMinutes.tool.<id> * 60,
         30 minutes when missing, RD-R8; DeadlineUtc for the child's log only);
      3. the run's own Stopwatch, started before the child (RD-R9);
      4. Tag.StartChild "%windir%\System32\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -ExecutionPolicy Bypass
         -File "<ScriptPath>" -ToolAction <id> -ToolArgs "<args.json>"' (Start-BackgroundExternal: hidden, no wait);
         its process goes into $script:ToolboxChildren and the run into Tag.Runs.<Slot>.
    Any of 2-4 failing (the folder, the args, a StartChild that throws or gives no process) is WARN 'Toolbox action
    could not start' with the reason in ASCII and $false: for the Action slot a red Failed result with childStartFailed
    (as if it had ended: the INFO line, the strip read again); for the Safety slot the strip ready, every chip unknown.
    The repair page is rendered again (Update-RepairView).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][string]$ActionId,
    [AllowNull()][hashtable]$Options,
    [ValidateSet('Action', 'Safety')][string]$Slot = 'Action'
  )

  $state = $Window.Tag
  $action = ConvertTo-ScreenText -Text $ActionId
  $refusal = ''
  if ($state['Runs'] -isnot [System.Collections.IDictionary]) { $refusal = 'the window runs no actions' }
  elseif ($null -ne $state['Runs'][$Slot]) { $refusal = 'another one is running' }
  elseif ([string]::IsNullOrEmpty([string]$state['Root']) -or [string]::IsNullOrEmpty([string]$state['ScriptPath'])) { $refusal = 'no setup files to run it from' }
  elseif (@($script:ToolActionCatalog.Keys) -cnotcontains $ActionId) { $refusal = 'not an action of this version' }
  if ($refusal -ne '') {
    Write-SetupLog -Level WARN -Message ('Toolbox action refused: ' + $refusal) -Data @{ action = $action; slot = $Slot }
    return $false
  }

  # The run folder is new: one already there (the same action started again within a second) is never reused, since a
  # result.json in it would be read as this run's. The id moves on a second at a time (it names the run, not a time
  # of record).
  $now = Get-Date
  for ($offset = 0; $offset -lt 60; $offset++) {
    $runId = New-ToolboxRunId -ActionId $ActionId -Time $now.AddSeconds($offset)
    $dir = [IO.Path]::Combine([string]$state['Root'], 'Tool', $runId)
    if (-not [IO.Directory]::Exists($dir)) { break }
  }
  $argsPath = [IO.Path]::Combine($dir, 'args.json')
  $budget = Get-ToolboxBudgetSeconds -Config $state['Config'] -ActionId $ActionId
  $startedUtc = [datetime]::UtcNow
  $deadlineUtc = $startedUtc.AddSeconds($budget).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
  if ($Slot -ceq 'Action') { $state.Model['Repair'] = New-RepairRunModel -Repair $state.Model['Repair'] -ActionId $ActionId -RunId $runId }

  $process = $null
  $clock = $null
  $failure = $null
  try {
    if ([IO.Directory]::Exists($dir)) { throw 'the run folder already exists' }
    $null = [IO.Directory]::CreateDirectory($dir)
    $runArgs = New-ToolboxRunArgs -State $state -ActionId $ActionId -RunId $runId -BudgetSeconds $budget -DeadlineUtc $deadlineUtc -Options $Options
    if (-not (Write-ToolJsonFile -Path $argsPath -InputObject $runArgs -Depth 8)) { throw 'args.json could not be written' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ToolAction {1} -ToolArgs "{2}"' -f [string]$state['ScriptPath'], $ActionId, $argsPath
    $outputs = @(& $state['StartChild'] "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" $arguments)
    if ($outputs.Count -ne 1 -or $null -eq $outputs[0]) {
      # A stray value beside a process: every process among the outputs is tracked and killed, never left running
      # untracked (Task 4 review M5); one the kill does not end stays tracked.
      foreach ($stray in $outputs) {
        if ($stray -is [Diagnostics.Process]) { $script:ToolboxChildren.Add($stray); $null = Stop-ToolboxChild -Process $stray -Action $action }
      }
      throw ('the child start gave {0} values instead of one process' -f $outputs.Count)
    }
    $process = $outputs[0]
    $script:ToolboxChildren.Add($process)
  } catch {
    $failure = ConvertTo-ScreenText -Text $_.Exception.Message
  }

  if ($null -ne $failure) {
    Write-SetupLog -Level WARN -Message 'Toolbox action could not start' -Data @{ action = $action; slot = $Slot; runId = $runId; error = $failure }
    if ($Slot -ceq 'Action') {
      $result = New-RepairWindowResult -Repair $state.Model['Repair'] -Outcome 'Failed' -Code 'childStartFailed' -Arguments @($failure) -EndedAt (Format-ToolTime -Value (Get-Date))
      Complete-ToolboxActionRun -Window $Window -Result $result -ActionId $ActionId -RunId $runId
    } else {
      Complete-ToolboxSafetyRun -Window $Window -Chips $null
    }
    Update-RepairView -Window $Window
    return $false
  }

  $state['Runs'][$Slot] = @{
    ActionId = $ActionId; RunId = $runId; Process = $process; Dir = $dir
    StartedUtc = $startedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture); DeadlineUtc = $deadlineUtc
    Clock = $clock; BudgetSeconds = $budget; Chips = $null
  }
  Update-RepairView -Window $Window
  return $true
}

function Update-ToolboxRuns {
  <#
  .SYNOPSIS
    The run timer's tick (every 500 ms, spec 7): each busy slot read and, when it is over, ended. Never waits.
  .DESCRIPTION
    Nothing runs: nothing happens (no render). For each slot busy when the tick began:
      - progress.json (Read-ToolJsonFile): the Action slot's into the run panel (Update-RepairRunModel, with the run's
        Stopwatch seconds); the Safety slot's Partial.Chips (an object) into the strip, still loading
        (ConvertTo-RepairStrip), unless that safety child is marked Reread;
      - its process has exited: the slot is cleared and the process leaves $script:ToolboxChildren; result.json is the
        result (Action: Complete-ToolboxActionRun, which hands an info child's answer to its open confirmation, Task 5;
        Safety: the strip from Data.Chips, ready). A result whose Outcome is none of the child's, or an info child's
        Done without its data, is no result (WARN 'Toolbox action result is not valid'); an unknown Color is RED. Without
        one: WARN 'Toolbox action ended without a result' with the exit code; Action: Failed, red, childNoResult with
        the exit code; Safety: the last partial chips, the others unknown;
      - still running past its budget + 3 minutes on the run's own Stopwatch (Get-ToolboxRunSeconds; RD-R8, RD-R9):
        Stop-ToolboxChild (a child the kill does not end stays tracked), WARN 'Toolbox action killed at its deadline',
        the slot cleared; Action: TimedOut, red, actionTimedOut with the budget's minutes, the running step timedout
        and the pending ones skipped (New-RepairWindowResult); Safety: the last partial chips, the others unknown
        (spec 5: blocks nothing).
      A safety child marked Reread (an action ended while it ran) is never the strip's reading: when it ends, a fresh
      one starts (Start-ToolboxSafetyRun; review M7). Malformed files never throw here (review M1, M6).
    Then the repair page alone is rendered again (Update-RepairView; plan call: not the whole window every 500 ms).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $runs = $state['Runs']
  if ($runs -isnot [System.Collections.IDictionary]) { return }
  # The slots busy now: a safety child an ending action starts below waits for the next tick.
  $busy = @(foreach ($slot in 'Action', 'Safety') { if ($null -ne $runs[$slot]) { @{ Slot = $slot; Run = $runs[$slot] } } })
  if ($busy.Count -eq 0) { return }

  foreach ($entry in $busy) {
    $slot = $entry.Slot
    $run = $entry.Run
    $action = ConvertTo-ScreenText -Text ([string]$run['ActionId'])
    $runId = ConvertTo-ScreenText -Text ([string]$run['RunId'])
    $seconds = Get-ToolboxRunSeconds -Run $run
    $progress = Read-ToolJsonFile -Path ([IO.Path]::Combine([string]$run['Dir'], 'progress.json'))
    if ($slot -ceq 'Action') {
      $state.Model['Repair'] = Update-RepairRunModel -Repair $state.Model['Repair'] -Progress $progress -ElapsedSeconds ([int][math]::Floor($seconds))
    } elseif ($run['Reread'] -ne $true) {
      # A safety child marked Reread began before an action ended: its chips are no longer shown (review M7).
      $chips = Get-RepairEntry -From (Get-RepairEntry -From $progress -Name 'Partial') -Name 'Chips'
      if (Test-RepairObject -Value $chips) {
        $run['Chips'] = $chips
        Set-ToolboxRepair -State $state -Values @{ Strip = (ConvertTo-RepairStrip -Chips $chips) }
      }
    }

    $exited = $false
    try { $exited = [bool]$run['Process'].HasExited } catch { $exited = $false }
    if ($exited) {
      $runs[$slot] = $null
      Remove-ToolboxChild -Process $run['Process']
      $result = Read-ToolJsonFile -Path ([IO.Path]::Combine([string]$run['Dir'], 'result.json'))
      if ($null -ne $result) {
        # A result whose Outcome is none of the child's is no result; an unknown colour is red (review M1, M6).
        $outcome = [string](Get-RepairEntry -From $result -Name 'Outcome')
        if ($outcome -cnotin 'Done', 'Stopped', 'TimedOut', 'NeedsRestart', 'Failed' -or
            ($slot -ceq 'Action' -and $outcome -ceq 'Done' -and $script:RepairInfoData.Contains([string]$run['ActionId']) -and
             -not (Get-ToolboxInfoAnswer -ActionId ([string]$run['ActionId']) -Result $result).Ok)) {
          # An info child that says Done without its data (Task 5) is no result either.
          Write-SetupLog -Level WARN -Message 'Toolbox action result is not valid' -Data @{ action = $action; runId = $runId }
          $result = $null
        } elseif ([string](Get-RepairEntry -From $result -Name 'Color') -cnotin 'GREEN', 'YELLOW', 'RED') {
          $result['Color'] = 'RED'
        }
      }
      $exitCode = 'unknown'
      if ($null -eq $result) {
        try { $exitCode = ConvertTo-ScreenText -Text ([string]$run['Process'].ExitCode) } catch { $exitCode = 'unknown' }
        if ($exitCode -eq '') { $exitCode = 'unknown' }
        Write-SetupLog -Level WARN -Message 'Toolbox action ended without a result' -Data @{ action = $action; runId = $runId; exitCode = $exitCode }
      }
      if ($slot -ceq 'Action') {
        if ($null -eq $result) {
          $result = New-RepairWindowResult -Repair $state.Model['Repair'] -Outcome 'Failed' -Code 'childNoResult' -Arguments @($exitCode) -EndedAt (Format-ToolTime -Value (Get-Date))
        }
        Complete-ToolboxActionRun -Window $Window -Result $result -ActionId ([string]$run['ActionId']) -RunId ([string]$run['RunId']) -Seconds $seconds
      } elseif ($run['Reread'] -eq $true) {
        Start-ToolboxSafetyRun -Window $Window   # its reading is from before an action ended: read again (review M7)
      } else {
        $data = Get-RepairEntry -From $result -Name 'Data'
        $finalChips = Get-RepairEntry -From $data -Name 'Chips'
        if (-not (Test-RepairObject -Value $finalChips)) { $finalChips = $run['Chips'] }
        Complete-ToolboxSafetyRun -Window $Window -Chips $finalChips -DiskCheck (Get-RepairEntry -From $data -Name 'DiskCheck')
      }
    } elseif ($seconds -gt ([double]$run['BudgetSeconds'] + $script:ToolboxKillGraceSeconds)) {
      # One the kill does not end stays tracked (Stop-ToolboxChild): the slot is free and the result timed out, but
      # every close retries the kill and no cleanup removes C:\BenTech under it (review M3).
      $null = Stop-ToolboxChild -Process $run['Process'] -Action $action
      $runs[$slot] = $null
      $minutes = [int][math]::Round([double]$run['BudgetSeconds'] / 60)
      Write-SetupLog -Level WARN -Message 'Toolbox action killed at its deadline' -Data @{ action = $action; runId = $runId; budgetMinutes = $minutes }
      if ($slot -ceq 'Action') {
        $result = New-RepairWindowResult -Repair $state.Model['Repair'] -Outcome 'TimedOut' -Code 'actionTimedOut' -Arguments @($minutes) -EndedAt (Format-ToolTime -Value (Get-Date))
        Complete-ToolboxActionRun -Window $Window -Result $result -ActionId ([string]$run['ActionId']) -RunId ([string]$run['RunId']) -Seconds $seconds
      } elseif ($run['Reread'] -eq $true) {
        Start-ToolboxSafetyRun -Window $Window
      } else {
        Complete-ToolboxSafetyRun -Window $Window -Chips $run['Chips']
      }
    }
  }
  Update-RepairView -Window $Window
}

function Request-ToolboxStop {
  <#
  .SYNOPSIS
    Stop (spec 4.3): asks the running action to stop at its next safe point, between steps. Never kills.
  .DESCRIPTION
    Writes <run folder>\stop.flag and sets Run.Stopping (the Stop button goes off, StoppingText names the running
    step); INFO 'Toolbox action stop requested'. A flag that cannot be written is a WARN and changes nothing. With no
    action running there is nothing to stop. The repair page is rendered again.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $run = $null
  if ($state['Runs'] -is [System.Collections.IDictionary]) { $run = $state['Runs']['Action'] }
  if ($null -ne $run) {
    $action = ConvertTo-ScreenText -Text ([string]$run['ActionId'])
    try {
      [IO.File]::WriteAllText([IO.Path]::Combine([string]$run['Dir'], 'stop.flag'), 'stop', (New-Object Text.UTF8Encoding $false))
      $current = $state.Model['Repair']['Run']
      if ($current -is [System.Collections.IDictionary]) {
        $nextRun = @{}
        foreach ($key in @($current.Keys)) { $nextRun[$key] = $current[$key] }
        $nextRun['Stopping'] = $true
        Set-ToolboxRepair -State $state -Values @{ Run = $nextRun }
      }
      Write-SetupLog -Level INFO -Message 'Toolbox action stop requested' -Data @{ action = $action; runId = (ConvertTo-ScreenText -Text ([string]$run['RunId'])) }
    } catch {
      Write-SetupLog -Level WARN -Message 'Could not ask the toolbox action to stop' -Data @{ action = $action; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
  }
  Update-RepairView -Window $Window
}

function Stop-ToolboxChildren {
  <#
  .SYNOPSIS
    Kills the process tree of every child the window started that still runs (Stop-ToolboxChild). The ones that
    ended leave $script:ToolboxChildren; one the kill does not end stays in it. Never throws.
  .DESCRIPTION
    Show-ToolboxWindow's finally calls it before the window closes, Get-SetupChoices' finally before WPF stops (spec
    4.4, Review Focus 2): no child may run on while the console fallback or the Cancel cleanup removes C:\BenTech.
    Each kill that ends the child is INFO 'Toolbox child process stopped' (its id). A child still running afterwards
    stays tracked (WARN 'Toolbox child still running after the kill'): the next call retries it, and
    Start-BenTechSetup removes no folder while one runs (Test-ToolboxChildrenRunning; Task 4 review M3).
  #>
  [CmdletBinding()]
  param()

  try {
    if ($null -eq $script:ToolboxChildren) { return }
    foreach ($process in $script:ToolboxChildren.ToArray()) {
      $exited = ($null -eq $process)
      if (-not $exited) { try { $exited = [bool]$process.HasExited } catch { $exited = $false } }
      if ($exited) { Remove-ToolboxChild -Process $process; continue }
      $id = $null
      try { $id = [int]$process.Id } catch { $id = $null }
      if (Stop-ToolboxChild -Process $process) { Write-SetupLog -Level INFO -Message 'Toolbox child process stopped' -Data @{ processId = $id } }
    }
  } catch {
    Write-SetupLog -Level WARN -Message 'Could not stop the toolbox child processes' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
}

function New-ToolboxRunTimer {
  <#
  .SYNOPSIS
    The run timer (spec 7: the window polls every 500 ms). Not started: Show-ToolboxWindow starts it with the power
    timer and stops it in its finally.
  .DESCRIPTION
    Its Tag is the window, so its Tick handler (Invoke-ToolboxAction -Action RunTick: Update-ToolboxRuns) finds the
    window without an outer variable. It runs on the window's dispatcher, so it ticks only while the dialog runs.
  #>
  [CmdletBinding()]
  [OutputType([System.Windows.Threading.DispatcherTimer])]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $timer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Background, $Window.Dispatcher)
  $timer.Interval = [TimeSpan]::FromMilliseconds(500)
  $timer.Tag = $Window
  $timer.Add_Tick({ Invoke-ToolboxAction -Sender $this -Action 'RunTick' })
  return $timer
}

# --- The page at work (repair Task 5; repair spec 4.2, 5, 6.6, 6.7, 8) -----------------------------------------------
# What the window starts when the model asks (Repair.Pending, after Update-RepairModel), the info children an open
# Network reset or Ghost devices confirmation waits for, the stick re-checked on the page (ruling RD-R3), and Open
# folder. Every start re-checks its gate at that moment (a disabled button still raises its Click in code).

# The info children (plan "Actions and steps": Kind info, run in the Action slot): the result's Data key that holds
# their answer, and the Update-RepairModel action that hands it to the open confirmation.
$script:RepairInfoData = @{
  netInfo   = @{ Data = 'NetInfo'; Model = 'NetInfo' }
  ghostList = @{ Data = 'Ghosts'; Model = 'GhostItems' }
}

function Get-ToolboxInfoAnswer {
  # Private. An info child's answer in its result: @{ Ok; Value }. Ok when the result's Data holds its key (netInfo:
  # Data.NetInfo, an object; ghostList: Data.Ghosts, a list, also an empty one). Value is that entry, as read (an
  # empty list survives: it is returned inside the table, never unrolled).
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][string]$ActionId, [AllowNull()]$Result)

  $answer = @{ Ok = $false; Value = $null }
  $info = $script:RepairInfoData[$ActionId]
  $data = Get-RepairEntry -From $Result -Name 'Data'
  if ($null -eq $info -or -not (Test-RepairObject -Value $data)) { return $answer }
  $key = [string]$info['Data']
  $has = $false
  $value = $null
  if ($data -is [System.Collections.IDictionary]) {
    $has = $data.Contains($key)
    if ($has) { $value = $data[$key] }
  } else {
    $property = $data.PSObject.Properties[$key]
    $has = ($null -ne $property)
    if ($has) { $value = $property.Value }
  }
  if (-not $has) { return $answer }
  if ($ActionId -ceq 'netInfo' -and -not (Test-RepairObject -Value $value)) { return $answer }
  if ($ActionId -ceq 'ghostList' -and $null -eq $value) { return $answer }
  $answer['Ok'] = $true
  $answer['Value'] = $value
  return $answer
}

function Complete-ToolboxInfoRun {
  <#
  .SYNOPSIS
    Private. An info child's end (netInfo, ghostList; repair Task 5): its answer goes to the open confirmation, not to
    the result panel.
  .DESCRIPTION
    Repair.Run is $null again either way (the gates open). No 'Toolbox action finished' line, no entry in the visit's
    list, no strip read: it changed nothing.
      - Done with its data (Get-ToolboxInfoAnswer): Update-RepairModel -Action NetInfo | GhostItems -Value <the data>;
        a confirmation that was closed meanwhile just does not take it.
      - Anything else: the confirmation closes and the result shows, WARN 'Toolbox info action failed' with
        @{ action; runId; outcome; findings } in ASCII. Failed and TimedOut are red (the child's colour rule, or the
        window's own result); a Done without its data becomes the window's own childNoResult (red); Stopped (Stop
        pressed after the confirmation was cancelled) shows as the child gave it.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [AllowNull()]$Result,
    [Parameter(Mandatory)][string]$ActionId,
    [AllowEmptyString()][string]$RunId = ''
  )

  $state = $Window.Tag
  $outcome = [string](Get-RepairEntry -From $Result -Name 'Outcome')
  $answer = Get-ToolboxInfoAnswer -ActionId $ActionId -Result $Result
  if ($outcome -ceq 'Done' -and $answer['Ok']) {
    Set-ToolboxRepair -State $state -Values @{ Run = $null; CloseRefused = $false }
    $state.Model = Update-RepairModel -Model $state.Model -Action ([string]$script:RepairInfoData[$ActionId]['Model']) -Value $answer['Value']
    return
  }
  if ($outcome -ceq 'Done' -or $outcome -eq '') {
    $Result = New-RepairWindowResult -Repair $state.Model['Repair'] -Outcome 'Failed' -Code 'childNoResult' -Arguments @('unknown') -EndedAt (Format-ToolTime -Value (Get-Date))
  }
  $codes = @(foreach ($finding in @(Get-RepairEntry -From $Result -Name 'Findings')) {
      if (Test-RepairObject -Value $finding) { ConvertTo-ScreenText -Text ([string](Get-RepairEntry -From $finding -Name 'Code')) } })
  Set-ToolboxRepair -State $state -Values @{ Run = $null; Confirm = $null; Result = $Result; CloseRefused = $false }
  Write-SetupLog -Level WARN -Message 'Toolbox info action failed' -Data @{ action = (ConvertTo-ScreenText -Text $ActionId); runId = (ConvertTo-ScreenText -Text $RunId)
    outcome = (ConvertTo-ScreenText -Text ([string](Get-RepairEntry -From $Result -Name 'Outcome'))); findings = $codes }
}

function Start-ToolboxPendingRun {
  <#
  .SYNOPSIS
    Starts the action the model asks for (Repair.Pending, set by Update-RepairModel's Tile or Confirm), with the
    confirmation's Options (ghostRemove: Ids; netRestore: File, Sha256; dismSource: Path, Type, Index). Never waits.
  .DESCRIPTION
    Pending and the confirmation are cleared first (Pending is one-shot). Then the gate of the tile is checked again at
    this moment (Get-RepairGate; every caller of Start-ToolboxRun does: Task 4 review): a closed gate, or an action
    already running, starts nothing (WARN 'Toolbox action refused: the gate is closed' with @{ action; reason }).
    Nothing pending: nothing happens.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $repair = $state.Model['Repair']
  $pending = [string]$repair['Pending']
  if ($pending -eq '') { return }
  $confirm = $repair['Confirm']
  $tile = $pending
  $options = @{}
  if ($confirm -is [System.Collections.IDictionary]) {
    $tile = [string]$confirm['Action']
    if ($confirm['Options'] -is [System.Collections.IDictionary]) { foreach ($key in @($confirm['Options'].Keys)) { $options[$key] = $confirm['Options'][$key] } }
  }
  Set-ToolboxRepair -State $state -Values @{ Pending = $null; Confirm = $null }
  $gate = Get-RepairGate -Model $state.Model -ActionId $tile
  if ((Test-ToolboxActionRunning -State $state) -or -not $gate.Enabled) {
    $reason = if ($gate.Reason -ne '') { $gate.Reason } else { 'reason.running' }
    Write-SetupLog -Level WARN -Message 'Toolbox action refused: the gate is closed' -Data @{ action = (ConvertTo-ScreenText -Text $pending); reason = $reason }
    return
  }
  $null = Start-ToolboxRun -Window $Window -ActionId $pending -Options $options
}

function Start-ToolboxInfoRun {
  <#
  .SYNOPSIS
    Starts the info child an open, loading confirmation waits for (Network reset: netInfo; Ghost devices: ghostList),
    in the Action slot. Never waits.
  .DESCRIPTION
    Nothing without a loading confirmation of such a tile, or while an action runs (its child is already asked). The
    tile's gate is checked again first. A start that is refused, or a closed gate, closes the confirmation (it would
    wait for nothing); a child that cannot start ends as a failed info child (Complete-ToolboxInfoRun: the
    confirmation closes, the red result shows).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $confirm = $state.Model['Repair']['Confirm']
  if ($confirm -isnot [System.Collections.IDictionary] -or $confirm['Loading'] -ne $true -or (Test-ToolboxActionRunning -State $state)) { return }
  $tile = [string]$confirm['Action']
  $info = Get-RepairInfoAction -Id $tile
  if ($info -eq '') { return }
  $started = $false
  $gate = Get-RepairGate -Model $state.Model -ActionId $tile
  if ($gate.Enabled) {
    $started = Start-ToolboxRun -Window $Window -ActionId $info
  } else {
    Write-SetupLog -Level WARN -Message 'Toolbox action refused: the gate is closed' -Data @{ action = (ConvertTo-ScreenText -Text $info); reason = $gate.Reason }
  }
  $now = $state.Model['Repair']['Confirm']
  if (-not $started -and $now -is [System.Collections.IDictionary] -and [string]$now['Action'] -ceq $tile -and $now['Loading'] -eq $true) {
    Set-ToolboxRepair -State $state -Values @{ Confirm = $null }
  }
}

function Get-ToolboxStickPresence {
  <#
  .SYNOPSIS
    The cheap stick presence check of the 5-second tick (ruling RD-R3): a text that changes when a BenTech stick is
    plugged in, pulled or swapped. No CIM, no WMI. Never throws.
  .DESCRIPTION
    [IO.DriveInfo]::GetDrives(): each ready Removable or Fixed drive other than the system drive that holds
    BenTechSetup.cmd in its root, or is the launcher's own drive (-Launcher.Drive: the stick it ran from, under any file
    name), as '<root>|<volume label>|<size>'; sorted, joined with ';'. Network, CD-ROM and other drives are skipped. A
    drive that cannot be read is skipped. The full search (Find-SetupStick, by volume serial) runs only when this text
    changes (Update-ToolboxStick).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()][hashtable]$Launcher,
    [AllowEmptyString()][string]$SystemDrive = $env:SystemDrive
  )

  $parts = New-Object System.Collections.Generic.List[string]
  try {
    $system = ([string]$SystemDrive).TrimEnd('\').ToUpperInvariant()
    $launcherDrive = if ($null -ne $Launcher) { ([string]$Launcher['Drive']).TrimEnd('\').ToUpperInvariant() } else { '' }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
      try {
        if ($drive.DriveType -ne [IO.DriveType]::Removable -and $drive.DriveType -ne [IO.DriveType]::Fixed) { continue }
        $letter = $drive.Name.TrimEnd('\').ToUpperInvariant()
        if ($letter -eq $system -or -not $drive.IsReady) { continue }
        if ($letter -ne $launcherDrive -and -not [IO.File]::Exists([IO.Path]::Combine($drive.Name, 'BenTechSetup.cmd'))) { continue }
        $parts.Add(('{0}|{1}|{2}' -f $drive.Name.ToUpperInvariant(), $drive.VolumeLabel, $drive.TotalSize))
      } catch {
        continue
      }
    }
  } catch {
    return ''
  }
  $parts.Sort([StringComparer]::Ordinal)
  return ($parts.ToArray() -join ';')
}

function Update-ToolboxStick {
  <#
  .SYNOPSIS
    The stick, checked again (spec 8, ruling RD-R3): on the power timer's 5-second tick and when the page opens. Only
    on the repair page, and never while an action runs. Returns nothing; never throws. Does not render.
  .DESCRIPTION
    Tag.StickPresent (Get-ToolboxStickPresence: [IO.DriveInfo], no CIM) answers first; only when its answer differs
    from the last one, or on the first check, Tag.FindStick (Find-SetupStick: the full search by the launcher's volume
    serial, one bounded CIM query) runs. A stick it finds on another root than the model's replaces Repair.Stick, and
    the change is logged once: INFO 'Toolbox stick changed' with @{ drive } ('none' when it is gone; ASCII). A presence
    check or a search that throws changes nothing and is logged once per window (WARN 'Could not check for the stick',
    'Could not look for the stick').
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  if ([string]$state.Model['Page'] -cne 'repair' -or (Test-ToolboxActionRunning -State $state)) { return }
  $presence = ''
  try {
    $presence = [string](& $state['StickPresent'] $state['Launcher'])
  } catch {
    if ($state['StickWarned'] -ne $true) {
      $state['StickWarned'] = $true
      Write-SetupLog -Level WARN -Message 'Could not check for the stick' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
    return
  }
  if ($state['StickChecked'] -eq $true -and $presence -ceq [string]$state['StickPresence']) { return }
  $state['StickChecked'] = $true
  $state['StickPresence'] = $presence

  $found = $null
  try {
    $outputs = @(& $state['FindStick'] $state['Launcher'])
    if ($outputs.Count -eq 1 -and $outputs[0] -is [System.Collections.IDictionary]) { $found = $outputs[0] }
  } catch {
    if ($state['StickSearchWarned'] -ne $true) {
      $state['StickSearchWarned'] = $true
      Write-SetupLog -Level WARN -Message 'Could not look for the stick' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
    return
  }
  $root = ''
  $drive = ''
  if ($null -ne $found -and -not [string]::IsNullOrEmpty([string]$found['Root'])) { $root = [string]$found['Root']; $drive = [string]$found['Drive'] }
  $before = $state.Model['Repair']['Stick']
  $beforeRoot = if ($before -is [System.Collections.IDictionary]) { [string]$before['Root'] } else { '' }
  if ($root -ceq $beforeRoot) { return }
  $stick = if ($root -ne '') { @{ Root = $root; Drive = $drive } } else { @{ Root = $null; Drive = $null } }
  Set-ToolboxRepair -State $state -Values @{ Stick = $stick }
  Write-SetupLog -Level INFO -Message 'Toolbox stick changed' -Data @{ drive = $(if ($drive -ne '') { ConvertTo-ScreenText -Text $drive } else { 'none' }) }
}

function Open-ToolboxFolder {
  <#
  .SYNOPSIS
    Open folder (spec 4.1): the shown result's folder (Result.Files.Folder) in Explorer. Returns nothing; never throws.
  .DESCRIPTION
    & Tag.StartChild "%windir%\explorer.exe" '"<folder>"' (Start-BackgroundExternal: no wait). Its process is never
    added to $script:ToolboxChildren: nobody waits for it, and it must hold neither the close guard nor the cleanup
    (Task 4 review); its Process object is disposed at once (that releases the handle, it does not end Explorer).
    Nothing without a folder; a folder that is not a full local path, holds a quote, or is not there
    (the stick was pulled) opens nothing. Those, and a start that throws, are WARN 'Could not open the folder' with
    the reason in ASCII.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $folder = [string](Get-RepairEntry -From (Get-RepairEntry -From $state.Model['Repair']['Result'] -Name 'Files') -Name 'Folder')
  if ($folder -eq '') { return }
  $problem = ''
  if ($folder -notmatch '^[A-Za-z]:\\' -or $folder.Contains('"')) { $problem = 'not a local folder path' }
  elseif (-not [IO.Directory]::Exists($folder)) { $problem = 'the folder is not there' }
  if ($problem -eq '') {
    try {
      foreach ($output in @(& $state['StartChild'] "$env:windir\explorer.exe" ('"{0}"' -f $folder))) {
        if ($output -is [System.Diagnostics.Process]) { $output.Dispose() }
      }
    } catch {
      $problem = ConvertTo-ScreenText -Text $_.Exception.Message
    }
  }
  if ($problem -ne '') { Write-SetupLog -Level WARN -Message 'Could not open the folder' -Data @{ folder = (ConvertTo-ScreenText -Text $folder); error = $problem } }
}
