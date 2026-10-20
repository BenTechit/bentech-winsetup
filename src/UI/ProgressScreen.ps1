# src/UI/ProgressScreen.ps1
# The v2 progress screen (v2 spec 4.2), redrawn by the tick at most once a second:
#
#   BENTECH WINDOWS SETUP - working, do not turn off   /   Total 01:12:40   Restarts 2
#   ------------------------------------------------------------------------------------
#   [OK] Prepare          [OK] AnyDesk             [>>] Microsoft 365 (bg) 13:40      <- checklist, in columns
#   ------------------------------------------------------------------------------------
#   NOW  Drivers (pass 1) - Dell Command Update   /   12:40 (of max 60 min)
#        Log: Installing Intel Chipset                                                <- NOW detail
#   ------------------------------------------------------------------------------------
#   JUST HAPPENED
#   12:31  Microsoft 365 started installing in the background                         <- activity feed
#
# Everything here is pure except Get-ProgressNowView (reads the NOW state, calls its provider) and
# Show-ProgressScreen (draws through the console writer, ConsoleFrame.ps1). Nothing uses Write-Host or
# Clear-Host. Uses ConvertTo-ScreenText, Limit-ScreenLine and ConvertFrom-StateTime (StartScreen.ps1),
# Get-SetupNow and Get-SetupActivityLines (Activity.ps1). The markers are plain ASCII because conhost
# cannot reliably show check marks and arrows.

$script:ProgressSpinnerFrames = @('|', '/', '-', '\')
$script:ProgressSpinnerIndex = 0
$script:NowDetailMaxLines = 10
# The NOW provider that already logged its failure (one WARN per provider, see Get-ProgressNowView).
$script:ProgressNowWarnedProvider = $null

function Format-Elapsed {
  # HH:mm:ss, hours not wrapped at 24. A negative span counts as zero.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][timespan]$Span)

  if ($Span -lt [timespan]::Zero) { $Span = [timespan]::Zero }
  return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

function Format-MinutesSeconds {
  # mm:ss, minutes not wrapped at 60 (101:07). A negative span counts as zero.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][timespan]$Span)

  if ($Span -lt [timespan]::Zero) { $Span = [timespan]::Zero }
  return ('{0:00}:{1:00}' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Get-ProgressSince {
  # Private. Now minus a state timestamp (ISO string or [datetime]); zero when the timestamp is missing.
  param([AllowNull()]$Value, [datetime]$Now)

  $started = ConvertFrom-StateTime $Value
  if ($null -eq $started) { return [timespan]::Zero }
  return ($Now - $started)
}

function Get-ProgressStepEntry {
  # Private. The state entry of one step, or $null.
  param([hashtable]$State, [string]$Id)

  if ($null -eq $State['Steps']) { return $null }
  return $State['Steps'][$Id]
}

function Get-ProgressMarker {
  # Private. The checklist marker for a step status.
  param([AllowNull()][AllowEmptyString()][string]$Status)

  switch ($Status) {
    'Done'    { return '[OK]' }
    'running' { return '[>>]' }
    'Failed'  { return '[X ]' }
    'Skipped' { return '[--]' }
  }
  return '[..]'
}

function Get-ChecklistEntry {
  <#
  .SYNOPSIS
    One checklist entry: the step's marker, a space and its Short title. Pure.
  .DESCRIPTION
    [OK] Done, [>>] running, [X ] Failed, [--] Skipped, [..] anything else (pending, or no state entry).
    No reason and no timer: the reasons go to JUST HAPPENED (spec 4.2).

    The 'office' entry also stands for 'office-finish', which has no line of its own (spec 4.6):
      office Failed or Skipped           -> office's own marker
      office-finish Done/Failed/Skipped  -> office-finish's marker
      office-finish running              -> [>>] Microsoft 365
      office Done in the background (Data.Background) and office-finish not started:
        Data.Finished                    -> [..] Microsoft 365 (bg ended)
        else                             -> [>>] Microsoft 365 (bg) mm:ss   (since Data.StartedAt)
      anything else                      -> office's own marker
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Short,
    [Parameter(Mandatory)][datetime]$Now
  )

  $step = Get-ProgressStepEntry -State $State -Id $Id
  $status = if ($null -ne $step) { [string]$step['Status'] } else { '' }

  if ($Id -eq 'office') {
    $finish = Get-ProgressStepEntry -State $State -Id 'office-finish'
    $finishStatus = if ($null -ne $finish) { [string]$finish['Status'] } else { '' }
    if (@('Failed', 'Skipped') -contains $status) { return ('{0} {1}' -f (Get-ProgressMarker $status), $Short) }
    if (@('Done', 'Failed', 'Skipped') -contains $finishStatus) { return ('{0} {1}' -f (Get-ProgressMarker $finishStatus), $Short) }
    if ($finishStatus -eq 'running') { return ('[>>] {0}' -f $Short) }
    $data = if ($null -ne $step) { $step['Data'] } else { $null }
    if ($status -eq 'Done' -and $null -ne $data -and $data['Background'] -eq $true) {
      if ($data['Finished'] -eq $true) { return ('[..] {0} (bg ended)' -f $Short) }
      return ('[>>] {0} (bg) {1}' -f $Short, (Format-MinutesSeconds (Get-ProgressSince -Value $data['StartedAt'] -Now $Now)))
    }
  }

  return ('{0} {1}' -f (Get-ProgressMarker $status), $Short)
}

function Format-Checklist {
  <#
  .SYNOPSIS
    The checklist entries in columns, filled top to bottom. Pure.
  .DESCRIPTION
    Column width = the longest entry + 3; as many columns as fit in Width - 2 (at least one); rows =
    ceil(entries / columns). Each line starts with two spaces; trailing spaces are trimmed. Lines are not
    cut here.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Entries,
    [Parameter(Mandatory)][int]$Width
  )

  $count = $Entries.Count
  if ($count -eq 0) { return }
  $longest = 0
  foreach ($entry in $Entries) { if ($entry.Length -gt $longest) { $longest = $entry.Length } }
  $columnWidth = $longest + 3
  $columns = [math]::Max(1, [int][math]::Floor(($Width - 2) / $columnWidth))
  $rows = [int][math]::Ceiling($count / $columns)

  for ($r = 0; $r -lt $rows; $r++) {
    $line = New-Object System.Text.StringBuilder
    [void]$line.Append('  ')
    for ($c = 0; $c -lt $columns; $c++) {
      $i = $c * $rows + $r
      if ($i -lt $count) { [void]$line.Append($Entries[$i].PadRight($columnWidth)) }
    }
    $line.ToString().TrimEnd()
  }
}

function Limit-ProgressLine {
  # Private. Limit-ScreenLine for any width, a window too narrow for '...' included.
  param([AllowEmptyString()][string]$Text, [int]$MaxLength)

  if ($MaxLength -ge 4) { return (Limit-ScreenLine -Text $Text -MaxLength $MaxLength) }
  $max = [math]::Max(0, $MaxLength)
  if ($Text.Length -le $max) { return $Text }
  return $Text.Substring(0, $max)
}

function Format-ProgressScreen {
  <#
  .SYNOPSIS
    The progress screen as lines of text for a Width x Height window. Pure: no console access.
  .DESCRIPTION
    In order: the header (spinner, total time, restarts), a separator, the checklist (plan order, one
    entry per step, office-finish folded into the Microsoft 365 line), a separator, the NOW line, its
    detail lines, then a separator, JUST HAPPENED and the activity lines, newest first.

    NOW: -NowView.Title, else the running step's Short title, else '-'; then ' - SubTitle' when given;
    then the time: with a wait (-NowView.Wait) the time since the wait started and its limit, rounded up
    to whole minutes; else the running step's time; nothing running: no time. The detail lines are
    -NowView.Lines, else the newest activity line; at most $script:NowDetailMaxLines, and a cut list ends
    in '... and N more'.

    Free text goes through ConvertTo-ScreenText; every line is cut to Width - 1 and there are at most
    Height - 1 lines (the frame writer never uses the last column or row). When space runs out,
    JUST HAPPENED shrinks first (it is left out when fewer than 3 rows remain, or when there is no
    activity), then the NOW detail. The header, the checklist and the NOW line stay; only when those
    alone do not fit, the two separators go, then checklist rows from the bottom.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][object[]]$Catalog,
    [Parameter(Mandatory)][datetime]$Now,
    [Parameter(Mandatory)][int]$Width,
    [Parameter(Mandatory)][int]$Height,
    [string]$Spinner = '|',
    [hashtable]$NowView,
    [object[]]$Activity = @()
  )

  $maxLength = $Width - 1
  $maxLines = [math]::Max(0, $Height - 1)
  if ($null -eq $NowView) { $NowView = @{} }
  $activityItems = @($Activity | Where-Object { $null -ne $_ })

  $shorts = @{}
  foreach ($entry in $Catalog) {
    $name = [string]$entry.Short
    if ([string]::IsNullOrEmpty($name)) { $name = [string]$entry.Title }
    if ([string]::IsNullOrEmpty($name)) { $name = [string]$entry.Id }
    $shorts[[string]$entry.Id] = $name
  }
  $shortOf = { param($id) if ($shorts.ContainsKey($id)) { ConvertTo-ScreenText $shorts[$id] } else { ConvertTo-ScreenText $id } }

  # Header and separator.
  $total = Format-Elapsed (Get-ProgressSince -Value $State['StartedAt'] -Now $Now)
  $header = '  BENTECH WINDOWS SETUP - working, do not turn off   {0}   Total {1}   Restarts {2}' -f $Spinner, $total, [int]$State['RebootCount']
  $separator = '  ' + ('-' * [math]::Max(10, $Width - 4))

  # Checklist: plan order, office-finish folded into the office line. The running step is the one NOW
  # names when no title overrides it.
  $entries = New-Object System.Collections.Generic.List[string]
  $runningId = $null
  foreach ($id in @($State['Plan'])) {
    if ([string]::IsNullOrEmpty($id)) { continue }
    $step = Get-ProgressStepEntry -State $State -Id $id
    if ($null -eq $runningId -and $null -ne $step -and [string]$step['Status'] -eq 'running') { $runningId = [string]$id }
    if ($id -eq 'office-finish') { continue }
    $entries.Add((Get-ChecklistEntry -State $State -Id $id -Short (& $shortOf $id) -Now $Now))
  }
  $checklist = @(Format-Checklist -Entries $entries.ToArray() -Width $Width)

  # The NOW line.
  $title = ConvertTo-ScreenText $NowView['Title']
  if ($title -eq '' -and $null -ne $runningId) { $title = & $shortOf $runningId }
  if ($title -eq '') { $title = '-' }
  $nowLine = '  NOW  ' + $title
  $subTitle = ConvertTo-ScreenText $NowView['SubTitle']
  if ($subTitle -ne '') { $nowLine += ' - ' + $subTitle }
  $wait = $NowView['Wait']
  if ($null -ne $wait) {
    $limit = [math]::Max(0, [int][math]::Ceiling([double]$wait['LimitMinutes']))
    $nowLine += '   /   {0} (of max {1} min)' -f (Format-MinutesSeconds (Get-ProgressSince -Value $wait['StartedAt'] -Now $Now)), $limit
  } elseif ($null -ne $runningId) {
    $runningStep = Get-ProgressStepEntry -State $State -Id $runningId
    $nowLine += '   /   ' + (Format-MinutesSeconds (Get-ProgressSince -Value $runningStep['StartedAt'] -Now $Now))
  }

  # A window too small for the header, checklist and NOW line: the separators go first, then checklist
  # rows from the bottom.
  $useSeparators = $true
  if ((4 + $checklist.Count) -gt $maxLines) {
    $useSeparators = $false
    $keep = $maxLines - 2
    if ($checklist.Count -gt $keep) { $checklist = @($checklist | Select-Object -First ([math]::Max(0, $keep))) }
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add($header)
  if ($useSeparators) { $lines.Add($separator) }
  foreach ($line in $checklist) { $lines.Add($line) }
  if ($useSeparators) { $lines.Add($separator) }
  $lines.Add($nowLine)

  # NOW detail: the step's lines, else the newest activity line; the NOW list wins over JUST HAPPENED.
  $detail = New-Object System.Collections.Generic.List[string]
  if ($null -ne $NowView['Lines']) {
    foreach ($text in @($NowView['Lines'])) { if ($null -ne $text) { $detail.Add((ConvertTo-ScreenText $text)) } }
  }
  if ($detail.Count -eq 0 -and $activityItems.Count -gt 0) { $detail.Add((ConvertTo-ScreenText $activityItems[0].Text)) }
  $room = [math]::Min($script:NowDetailMaxLines, $maxLines - $lines.Count)
  if ($detail.Count -le $room) {
    foreach ($text in $detail) { $lines.Add('       ' + $text) }
  } elseif ($room -gt 0) {
    for ($i = 0; $i -lt $room - 1; $i++) { $lines.Add('       ' + $detail[$i]) }
    $lines.Add(('       ... and {0} more' -f ($detail.Count - ($room - 1))))
  }

  # JUST HAPPENED: whatever room is left, newest first.
  $room = $maxLines - $lines.Count
  if ($room -ge 3 -and $activityItems.Count -gt 0) {
    $lines.Add($separator)
    $lines.Add('  JUST HAPPENED')
    $count = [math]::Min($room - 2, $activityItems.Count)
    for ($i = 0; $i -lt $count; $i++) {
      $time = ConvertFrom-StateTime $activityItems[$i].Time
      $clock = if ($null -ne $time) { $time.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { '--:--' }
      $lines.Add(('  {0}  {1}' -f $clock, (ConvertTo-ScreenText $activityItems[$i].Text)))
    }
  }

  $result = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if ($result.Count -ge $maxLines) { break }
    $result.Add((Limit-ProgressLine -Text $line -MaxLength $maxLength))
  }
  return $result.ToArray()
}

function Split-ProgressLine {
  <#
  .SYNOPSIS
    One screen row as coloured segments @{ Text; Color } for Write-ConsoleFrame -Colorize. Pure.
  .DESCRIPTION
    The text before the first marker has no colour (the frame's foreground). Each marker starts a
    segment that runs to the next marker: [OK] Green, [>>] Cyan, [X ] Red, [--] DarkGray, [..] no colour.
    No segment sets a background: the frame's background (Black) applies. Emitted one by one: wrap the
    call in @().
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

  $colors = @{ '[OK]' = 'Green'; '[>>]' = 'Cyan'; '[X ]' = 'Red'; '[--]' = 'DarkGray'; '[..]' = $null }
  $found = [regex]::Matches($Line, '\[(?:OK|>>|X |--|\.\.)\]')
  if ($found.Count -eq 0) { return @{ Text = $Line; Color = $null } }

  if ($found[0].Index -gt 0) { @{ Text = $Line.Substring(0, $found[0].Index); Color = $null } }
  for ($i = 0; $i -lt $found.Count; $i++) {
    $end = if ($i + 1 -lt $found.Count) { $found[$i + 1].Index } else { $Line.Length }
    @{ Text = $Line.Substring($found[$i].Index, $end - $found[$i].Index); Color = $colors[$found[$i].Value] }
  }
}

function Get-ProgressNowView {
  <#
  .SYNOPSIS
    What NOW shows: @{ Title; SubTitle; Lines; Wait } from Get-SetupNow, Lines from its provider.
    Never throws.
  .DESCRIPTION
    The provider is called as `& $Provider $ProviderArgument`, inside a one-shot loop so that a stray
    break or continue cannot leave this function. A provider that fails gives Lines = @() and one WARN.
    Each provider is warned about once: Set-SetupNow -Provider { ... } passes a new script block every
    time, so after Clear-SetupNow and a new provider, a new failure is logged again.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $view = @{ Title = $null; SubTitle = $null; Lines = @(); Wait = $null }
  $provider = $null
  $failure = $null
  try {
    $nowState = Get-SetupNow
    $view.Title = $nowState.Title
    $view.SubTitle = $nowState.SubTitle
    $view.Wait = $nowState.Wait
    $provider = $nowState.Provider
    if ($null -ne $provider) {
      $failure = 'the provider used break or continue outside a loop'
      foreach ($once in 1) {
        $view.Lines = @(& $provider $nowState.ProviderArgument | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $failure = $null
      }
    }
  } catch {
    $failure = $_.Exception.Message
  }

  if ($null -ne $failure) {
    $view.Lines = @()
    if ($null -eq $provider -or -not [object]::ReferenceEquals($script:ProgressNowWarnedProvider, $provider)) {
      $script:ProgressNowWarnedProvider = $provider
      Write-SetupLog -Level WARN -Message 'The NOW detail could not be read; showing none' -Data @{ error = $failure; subTitle = [string]$view.SubTitle }
    }
  }
  return $view
}

function Show-ProgressScreen {
  <#
  .SYNOPSIS
    Draws the progress screen over the console window through the console writer.
  .DESCRIPTION
    Reads the window size from -Writer, advances the spinner one frame, reads NOW (Get-ProgressNowView)
    and the newest 50 activity lines, and draws Format-ProgressScreen with Write-ConsoleFrame, the
    checklist markers coloured (Split-ProgressLine). Never Write-Host or Clear-Host. A writer that throws
    propagates (the tick logs it).
    The seams (production defaults shown): -Now is the clock, -Writer the console writer.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [object[]]$Catalog = $script:StepCatalog,
    [scriptblock]$Now = { Get-Date },
    [hashtable]$Writer = (New-ConsoleWriter)
  )

  # The clock runs first, with this function's own $Now out of the way: PowerShell finds a variable in
  # the callers' scopes, so a caller's `-Now { $now }` would otherwise get this parameter back.
  $clockBlock = $Now
  Remove-Variable -Name Now -Scope Local
  $at = [datetime](& $clockBlock)

  $size = & $Writer['GetSize']
  $frames = $script:ProgressSpinnerFrames
  $spinner = $frames[$script:ProgressSpinnerIndex % $frames.Count]
  $script:ProgressSpinnerIndex = ($script:ProgressSpinnerIndex + 1) % $frames.Count

  $view = Get-ProgressNowView
  $activity = @(Get-SetupActivityLines -Count 50)
  $lines = @(Format-ProgressScreen -State $State -Catalog $Catalog -Now $at -Width ([int]$size.Width) -Height ([int]$size.Height) `
    -Spinner $spinner -NowView $view -Activity $activity)
  Write-ConsoleFrame -Lines $lines -Writer $Writer -Colorize { param($line) Split-ProgressLine -Line $line }
}
