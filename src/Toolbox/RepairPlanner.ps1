# src/Toolbox/RepairPlanner.ps1
# The Repair & diagnostics page's rules (repair spec 4, 5; repair plan "The repair model" and "Safety strip, chips and
# gates"): the page's model (New-RepairModel), the safety strip made from the safety child's chips
# (ConvertTo-RepairStrip), the gate of every action (Get-RepairGate), the chips as the window shows them
# (Get-RepairChips), the YES check (Test-RepairYes) and whether an open confirmation may be confirmed
# (Test-RepairConfirmReady). RepairPage.ps1 renders it; the toolbox model holds it as Model.Repair.
# Task 4: the run in the model: a run started (New-RepairRunModel), brought up to date from the child's progress
# (Update-RepairRunModel), ended on its result (Complete-RepairRunModel), and the result the window writes itself
# when the child gave none (New-RepairWindowResult).
# Task 5: the page at work (Update-RepairModel): a tile clicked (an action to start now, or a confirmation of the
# catalog's kind), YES typed, the at-PC and backed-up ticks, the ghost ticks, the complaint, the hovered tile, the DISM
# offer, and the answers of the info children (netInfo, ghostList) that the Network reset and Ghost devices
# confirmations wait for.
#
# Pure: no logging, no I/O, no window, no clock. Values in, values out. Needs Repair\ToolEngine.ps1's
# $script:ToolActionCatalog for the actions this version has and Get-ToolText for a finding's English text, and
# UI\StartScreen.ps1's ConvertTo-ScreenText; the bundle holds every file.
#
# The gate table (plan "Gates"; the first rule that fires wins, a warn adds a line to the confirmation):
#   every action          reason.running (an action runs); reason.noScript (no setup files to run a child from);
#                         reason.unavailable (not in Repair.Available)
#   standard, postClone,  reason.checking (the strip is loading); reason.restart (Restart crit); reason.battery (a
#   dismSource            laptop on battery); reason.diskFailing (Disk crit, not ticked backed up)
#                         warns: warn.lowSpace (Free crit), warn.diskFailing (Disk crit, ticked), confirm.noStickLog
#   wuReset               reason.checking; reason.restart; warns: warn.noRescan (Internet crit), confirm.noStickLog
#   diskCheck             reason.checking; reason.restart; reason.diskFailing; warns: confirm.noStickLog
#   netReset, ghosts      reason.noStickBackup (the backup must survive the restart)
#   netRestore            hidden without a saved backup (Repair.NetBackup); reason.noStickBackup
#   quickReport,          reason.noStickReport
#   fullReport
#   compare               reason.noStickReport; reason.noEarlier (no earlier report of this PC on the stick)
#   health                warns: confirm.noStickLog
#   restart (Restart PC)  reason.running only
# Unknown chips block nothing (spec 5). Read-only actions never wait for the strip.

# The tiles of the page, row by row (spec 4.1).
$script:RepairTileRows = [ordered]@{
  check    = @('health', 'quickReport')
  repair   = @('standard', 'postClone')
  advanced = @('wuReset', 'netReset', 'diskCheck', 'ghosts')
  report   = @('fullReport', 'compare')
}

# A tile that starts more than one action of the catalog is available when every one of them is: Ghost devices lists
# (ghostList), then removes (ghostRemove); Network reset reads the settings (netInfo), then resets (netReset).
$script:RepairTileActions = [ordered]@{
  ghosts   = @('ghostList', 'ghostRemove')
  netReset = @('netInfo', 'netReset')
}

# The safety child's five chips (plan "Safety strip"), in the strip's order. Power and Stick are the window's own.
$script:RepairChipNames = @('Restart', 'Free', 'BitLocker', 'Internet', 'Disk')

# Each chip's glyph (Segoe Fluent Icons / MDL2 Assets code points) and the part of its string keys.
$script:RepairChipGlyphs = @{ Restart = 0xE777; Free = 0xE8B7; BitLocker = 0xE72E; Internet = 0xE774; Disk = 0xEDA2; Stick = 0xE88E }

# The Hebrew-layout YES: the three keys Y, E, S typed on a Hebrew keyboard (spec 4.2), written as code points so this
# file stays ASCII (plan call).
$script:RepairHebrewYes = [string]::new([char[]]@(0x05D8, 0x05E7, 0x05D3))

function Get-RepairAvailable {
  <#
  .SYNOPSIS
    The action and tile ids this version can run: every id of -Catalog (the action catalog), then each tile of
    $script:RepairTileActions whose actions are all in it, each id once. A tile of that table is available only when
    every action it starts is in the catalog, also when its own id is a catalog id (Network reset without netInfo is
    not available; review M1). Pure; emitted one by one (wrap the call in @()).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Catalog)

  if ($Catalog -isnot [System.Collections.IDictionary]) { return }
  $ids = @(foreach ($key in $Catalog.Keys) { [string]$key })
  $complete = @{}
  foreach ($tile in $script:RepairTileActions.Keys) {
    $all = $true
    foreach ($action in $script:RepairTileActions[$tile]) { if ($ids -cnotcontains $action) { $all = $false } }
    $complete[$tile] = $all
  }
  $emitted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($id in $ids) {
    if ($complete.ContainsKey($id) -and -not $complete[$id]) { continue }
    if ($emitted.Add($id)) { $id }
  }
  foreach ($tile in $script:RepairTileActions.Keys) {
    if ($complete[$tile] -and $emitted.Add($tile)) { $tile }
  }
}

function New-RepairModel {
  <#
  .SYNOPSIS
    The repair page's model (plan "The repair model"): what the page shows, as plain values. Pure.
  .DESCRIPTION
    @{ Available (Get-RepairAvailable of the action catalog); CanRun (the setup files are there to start a child from);
       IsLaptop; OsBuild (the PC's build, for the DISM offer's warning); SessionStamp ('yyyy-MM-dd_HHmm', the visit's
       folder stamp); Strip (loading, no chip yet);
       Stick = @{ Root; Drive } (none until the window finds it); DiskCheck = @{ Dirty; Excluded }; NetBackup ($null);
       HasEarlierReport; BackedUp; Complaint; Selected; CloseRefused; Done; Pending; Confirm; Run; Result }.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)][AllowEmptyString()][string]$SessionStamp,
    [bool]$CanRun = $false
  )

  return @{
    Available        = [string[]]@(Get-RepairAvailable -Catalog $script:ToolActionCatalog)
    CanRun           = $CanRun
    IsLaptop         = ($Machine['IsLaptop'] -eq $true)
    OsBuild          = [string]$Machine['OsBuild']
    SessionStamp     = $SessionStamp
    Strip            = (ConvertTo-RepairStrip -Chips $null)
    Stick            = @{ Root = $null; Drive = $null }
    DiskCheck        = @{ Dirty = $null; Excluded = $false }
    NetBackup        = $null
    HasEarlierReport = $false
    BackedUp         = $false
    Complaint        = ''
    Selected         = ''
    CloseRefused     = $false
    Done             = @()
    Pending          = $null
    Confirm          = $null
    Run              = $null
    Result           = $null
  }
}

function Get-RepairEntry {
  # Private. -Name of a hashtable or of an object read from JSON (a property), else $null.
  [CmdletBinding()]
  param([AllowNull()]$From, [Parameter(Mandatory)][string]$Name)

  if ($null -eq $From) { return $null }
  if ($From -is [System.Collections.IDictionary]) { if ($From.Contains($Name)) { return $From[$Name] } else { return $null } }
  $property = $From.PSObject.Properties[$Name]
  if ($null -ne $property) { return $property.Value }
  return $null
}

function ConvertTo-RepairStrip {
  <#
  .SYNOPSIS
    The strip from a (partial) safety result: @{ State; Restart; Free; BitLocker; Internet; Disk }. Pure.
  .DESCRIPTION
    -Chips is the safety child's Data.Chips (or progress.Partial.Chips), a hashtable or an object read from JSON, or
    $null. Each chip it has becomes @{ Level; Args = [string[]]; Detail }, its Level 'ok', 'warn', 'crit' or 'unknown'
    (anything else is 'unknown'). A chip it does not have is $null and State is 'loading'; with -Final $true (the safety
    child ended or was killed) every missing chip becomes @{ Level = 'unknown' } and State is 'ready' (spec 5: a chip
    that could not be read in time is unknown, yellow, and blocks nothing).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()]$Chips,
    [bool]$Final = $false
  )

  $strip = @{ State = $(if ($Final) { 'ready' } else { 'loading' }) }
  foreach ($name in $script:RepairChipNames) {
    $chip = Get-RepairEntry -From $Chips -Name $name
    if ($null -eq $chip) {
      $strip[$name] = $(if ($Final) { @{ Level = 'unknown'; Args = [string[]]@(); Detail = @{} } } else { $null })
      continue
    }
    $level = [string](Get-RepairEntry -From $chip -Name 'Level')
    if ($level -cnotin 'ok', 'warn', 'crit', 'unknown') { $level = 'unknown' }
    $detail = Get-RepairEntry -From $chip -Name 'Detail'
    if ($null -eq $detail) { $detail = @{} }
    $strip[$name] = @{ Level = $level; Args = [string[]]@(foreach ($a in @(Get-RepairEntry -From $chip -Name 'Args')) { if ($null -ne $a) { [string]$a } }); Detail = $detail }
  }
  return $strip
}

function Get-RepairChipLevel {
  # Private. A strip chip's level, or '' when the strip has no such chip (yet).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Repair, [Parameter(Mandatory)][string]$Name)

  $chip = $Repair['Strip'][$Name]
  if ($chip -is [System.Collections.IDictionary]) { return [string]$chip['Level'] }
  return ''
}

function Test-RepairStick {
  # Private. $true when the page has found the BenTech stick.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$Repair)

  $stick = $Repair['Stick']
  return ($stick -is [System.Collections.IDictionary] -and -not [string]::IsNullOrEmpty([string]$stick['Root']))
}

function Get-RepairGate {
  <#
  .SYNOPSIS
    Whether the page may start -ActionId now (the gate table in this file's header): @{ Enabled; Visible; Reason;
    Warns }. Pure.
  .DESCRIPTION
    -Model is the toolbox model (its OnAC and its Repair). -ActionId is a tile id, 'netRestore', 'dismSource' or
    'restart' (Restart PC). Reason is the string key of the first rule that blocks it ('' when enabled); Warns are the
    string keys a confirmation adds (they never block). Visible is $false only for Restore network settings without a
    saved backup.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Model,
    [Parameter(Mandatory)][string]$ActionId
  )

  $repair = $Model['Repair']
  $stick = Test-RepairStick -Repair $repair
  $loading = ([string]$repair['Strip']['State'] -cne 'ready')
  $restart = ((Get-RepairChipLevel -Repair $repair -Name 'Restart') -ceq 'crit')
  $diskFailing = ((Get-RepairChipLevel -Repair $repair -Name 'Disk') -ceq 'crit')
  $backedUp = ($repair['BackedUp'] -eq $true)
  $battery = ($repair['IsLaptop'] -eq $true -and $Model['OnAC'] -ne $true)
  $visible = ($ActionId -cne 'netRestore' -or $null -ne $repair['NetBackup'])

  $warns = New-Object System.Collections.Generic.List[string]
  $rules = New-Object System.Collections.Generic.List[object]   # @(<blocks>, <reason key>), in order
  $rules.Add(@(($null -ne $repair['Run']), 'reason.running'))
  if ($ActionId -cne 'restart') {
    $rules.Add(@(($repair['CanRun'] -ne $true), 'reason.noScript'))
    $rules.Add(@((@($repair['Available']) -cnotcontains $ActionId), 'reason.unavailable'))
  }
  switch -CaseSensitive ($ActionId) {
    { $_ -cin 'standard', 'postClone', 'dismSource' } {
      $rules.Add(@($loading, 'reason.checking')); $rules.Add(@($restart, 'reason.restart'))
      $rules.Add(@($battery, 'reason.battery')); $rules.Add(@(($diskFailing -and -not $backedUp), 'reason.diskFailing'))
      if ((Get-RepairChipLevel -Repair $repair -Name 'Free') -ceq 'crit') { $warns.Add('warn.lowSpace') }
      if ($diskFailing -and $backedUp) { $warns.Add('warn.diskFailing') }
      if (-not $stick) { $warns.Add('confirm.noStickLog') }
    }
    'wuReset' {
      $rules.Add(@($loading, 'reason.checking')); $rules.Add(@($restart, 'reason.restart'))
      if ((Get-RepairChipLevel -Repair $repair -Name 'Internet') -ceq 'crit') { $warns.Add('warn.noRescan') }
      if (-not $stick) { $warns.Add('confirm.noStickLog') }
    }
    'diskCheck' {
      $rules.Add(@($loading, 'reason.checking')); $rules.Add(@($restart, 'reason.restart')); $rules.Add(@(($diskFailing -and -not $backedUp), 'reason.diskFailing'))
      if (-not $stick) { $warns.Add('confirm.noStickLog') }
    }
    { $_ -cin 'netReset', 'ghosts', 'netRestore' } { $rules.Add(@((-not $stick), 'reason.noStickBackup')) }
    { $_ -cin 'quickReport', 'fullReport' } { $rules.Add(@((-not $stick), 'reason.noStickReport')) }
    'compare' { $rules.Add(@((-not $stick), 'reason.noStickReport')); $rules.Add(@(($repair['HasEarlierReport'] -ne $true), 'reason.noEarlier')) }
    'health' { if (-not $stick) { $warns.Add('confirm.noStickLog') } }
  }

  $reason = ''
  foreach ($rule in $rules) { if ($rule[0] -eq $true) { $reason = $rule[1]; break } }
  return @{ Enabled = ($visible -and $reason -eq ''); Visible = $visible; Reason = $reason; Warns = [string[]]$warns.ToArray() }
}

function Get-RepairDriveLetter {
  # Private. A drive's letter without its colon ('E:' -> 'E'); anything else as it is.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Drive)

  return ([string]$Drive).TrimEnd(':', '\')
}

function Get-RepairChips {
  <#
  .SYNOPSIS
    The strip as the window shows it (spec 5): one row per chip, in order Restart, Free, BitLocker, Internet, Disk,
    Power, Stick. Pure.
  .DESCRIPTION
    Each row: @{ Name; Level = 'ok'|'warn'|'crit'|'unknown'|'loading'; TextKey; Args = [string[]]; Glyph (a code
    point); Tips = [string[]] (string keys, joined in the tooltip; none for a plain green chip); Visible }.
      - The five read chips say chip.loading until the safety child has read them.
      - Free shows chip.free.level at every known level, with Args = @(<drive 'C:'>, <percent>, <letter 'C'>).
      - Restart ok with a pending file or computer rename (Detail.Notes) keeps its green and adds tip.restart.note.
      - Power (laptops only, the window's own reading): ok on charger, crit on battery.
      - Stick: ok chip.stick.ok with Args = @(<drive 'E:'>, <letter 'E'>), crit 'No stick' (spec 8: a red chip).
    The letter without its colon is for the Hebrew texts (ruling RD-R14): in a right-to-left line the colon of 'E:'
    is met before the letter, so the Hebrew chips name the drive by its letter alone.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Model)

  $repair = $Model['Repair']
  foreach ($name in $script:RepairChipNames) {
    $chip = $repair['Strip'][$name]
    $row = @{ Name = $name; Glyph = $script:RepairChipGlyphs[$name]; Args = [string[]]@(); Tips = [string[]]@(); Visible = $true }
    if ($chip -isnot [System.Collections.IDictionary]) {
      $row.Level = 'loading'; $row.TextKey = 'chip.loading'
      $row; continue
    }
    $level = [string]$chip['Level']
    if ($level -cnotin 'ok', 'warn', 'crit', 'unknown') { $level = 'unknown' }
    $row.Level = $level
    $part = $name.ToLowerInvariant()
    $row.TextKey = "chip.$part.$level"
    if ($name -ceq 'Free' -and $level -cne 'unknown') {
      $values = [string[]]@($chip['Args'])
      $drive = $(if ($values.Count -gt 0) { $values[0] } else { '' })
      $percent = $(if ($values.Count -gt 1) { $values[1] } else { '' })
      $row.TextKey = 'chip.free.level'
      $row.Args = [string[]]@($drive, $percent, (Get-RepairDriveLetter -Drive $drive))
    }
    $tips = New-Object System.Collections.Generic.List[string]
    if ($level -ceq 'unknown') { $tips.Add('tip.unknown') }
    elseif ($level -cne 'ok') { $tips.Add("tip.$part.$level") }
    if ($name -ceq 'Restart' -and $level -ceq 'ok') {
      $notes = Get-RepairEntry -From $chip['Detail'] -Name 'Notes'
      if (@($notes | Where-Object { -not [string]::IsNullOrEmpty([string]$_) }).Count -gt 0) { $tips.Add('tip.restart.note') }
    }
    $row.Tips = [string[]]$tips.ToArray()
    $row
  }

  $onAC = ($Model['OnAC'] -eq $true)
  @{ Name = 'Power'; Level = $(if ($onAC) { 'ok' } else { 'crit' }); TextKey = $(if ($onAC) { 'chip.power.ac' } else { 'chip.power.battery' })
     Args = [string[]]@(); Glyph = $(if ($onAC) { 0xE83E } else { 0xE83F }); Tips = [string[]]@($(if (-not $onAC) { 'tip.power.battery' }))
     Visible = ($repair['IsLaptop'] -eq $true) }

  $stick = Test-RepairStick -Repair $repair
  @{ Name = 'Stick'; Level = $(if ($stick) { 'ok' } else { 'crit' }); TextKey = $(if ($stick) { 'chip.stick.ok' } else { 'chip.stick.none' })
     Args = [string[]]@($(if ($stick) { [string]$repair['Stick']['Drive']; Get-RepairDriveLetter -Drive ([string]$repair['Stick']['Drive']) }))
     Glyph = $script:RepairChipGlyphs['Stick']
     Tips = [string[]]@($(if (-not $stick) { 'tip.stick.none' })); Visible = $true }
}

function Test-RepairYes {
  <#
  .SYNOPSIS
    $true when -Text is YES (spec 4.2): the trimmed text is YES in any case, or exactly the same three keys on a
    Hebrew keyboard layout (U+05D8 U+05E7 U+05D3). Pure.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  $t = ([string]$Text).Trim()
  return ($t -ieq 'YES' -or $t -ceq $script:RepairHebrewYes)
}

function Test-RepairConfirmReady {
  <#
  .SYNOPSIS
    $true when the open confirmation (Model.Repair.Confirm) may be confirmed now. Pure.
  .DESCRIPTION
    $false with no confirmation, or while it is loading (Network reset and Ghost devices wait for their info child).
    Otherwise all of these: the action's gate still allows it (Get-RepairGate; 'restart' for Restart PC); a 'yes'
    confirmation holds YES (Test-RepairYes); Network reset has the at-PC tick, always (ruling RD-R2: AnyDesk and
    ScreenConnect run on every PC Ben sets up, so the tick is asked whatever is detected), and so does any confirmation
    whose Remote reports a session; a confirmation with device items has at least one ticked, and Ghost devices always
    need one (a list with nothing to remove has nothing to confirm).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$Model)

  $confirm = $Model['Repair']['Confirm']
  if ($confirm -isnot [System.Collections.IDictionary] -or $confirm['Loading'] -eq $true) { return $false }
  $action = [string]$confirm['Action']
  if (-not (Get-RepairGate -Model $Model -ActionId $action).Enabled) { return $false }
  if ([string]$confirm['Kind'] -ceq 'yes' -and -not (Test-RepairYes -Text ([string]$confirm['Typed']))) { return $false }
  $session = @((ConvertTo-RepairFlags -Value $confirm['Remote']).Values) -contains $true
  if (($action -ceq 'netReset' -or $session) -and $confirm['AtPc'] -ne $true) { return $false }
  $items = @($confirm['Items'] | Where-Object { $null -ne $_ })
  $ticked = @($items | Where-Object { (Get-RepairEntry -From $_ -Name 'Ticked') -eq $true }).Count
  if (($items.Count -gt 0 -or $action -ceq 'ghosts') -and $ticked -eq 0) { return $false }
  return $true
}

function Format-RepairElapsed {
  <#
  .SYNOPSIS
    Seconds as the run panel shows them: 'm:ss', or 'h:mm:ss' from an hour up (754 -> '12:34'). Pure.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([int]$Seconds)

  $s = [math]::Max(0, $Seconds)
  $hours = [math]::Floor($s / 3600)
  $minutes = [math]::Floor(($s % 3600) / 60)
  $rest = $s % 60
  $culture = [Globalization.CultureInfo]::InvariantCulture
  if ($hours -gt 0) { return [string]::Format($culture, '{0}:{1:00}:{2:00}', [int]$hours, [int]$minutes, [int]$rest) }
  return [string]::Format($culture, '{0}:{1:00}', [int]$minutes, [int]$rest)
}

# --- The run (repair Task 4) ---------------------------------------------------------------------------------------
# The window (RepairPage.ps1) runs one action at a time in a child process and polls its progress.json; these turn
# what it reads into the page's model. Pure, like the rest of this file: each returns a copy, the input is unchanged.

# A step's status as the run panel knows it (plan "The files of one run": progress Steps.Status).
$script:RepairStepStatuses = @('pending', 'running', 'done', 'warn', 'failed', 'skipped', 'timedout')

function ConvertTo-RepairPercent {
  # Private. A percent read from progress.json as a [double], or $null when it is no number.
  [CmdletBinding()]
  param([AllowNull()]$Value)

  if ($null -eq $Value -or $Value -is [bool]) { return $null }
  $number = 0.0
  if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
  return $null
}

function Test-RepairObject {
  # Private. $true for a hashtable or an object read from JSON: a row the run model can read fields from.
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()]$Value)

  return ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject])
}

function ConvertTo-RepairIndex {
  # Private. progress.json's Current as an [int], or -1 when it is no whole number in Int32's range (text, a fraction,
  # 1e12, a bool, a list, an object): a malformed field never ends the window (Task 4 review M1, ruling RD-R16).
  [CmdletBinding()]
  [OutputType([int])]
  param([AllowNull()]$Value)

  $index = 0
  if ($null -eq $Value -or $Value -is [bool] -or (Test-RepairObject -Value $Value) -or ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string])) { return -1 }
  if ([int]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$index)) { return $index }
  return -1
}

function New-RepairRunModel {
  <#
  .SYNOPSIS
    -Repair with -ActionId's run started (plan "The repair model": Run). Pure; returns a copy.
  .DESCRIPTION
    Run = @{ Action; RunId; Steps = every step of the catalog's action, each @{ Id; Status = 'pending'; Percent = $null };
    Current = -1; Percent = $null; Log = @(); ElapsedSeconds = 0; Stopping = $false }. CloseRefused is $false again.
    The confirmation, the result and the strip are left as they are (the run panel comes before the result).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Repair,
    [Parameter(Mandatory)][string]$ActionId,
    [AllowEmptyString()][string]$RunId = ''
  )

  $entry = $script:ToolActionCatalog[$ActionId]
  $ids = if ($entry -is [System.Collections.IDictionary]) { @($entry['Steps']) } else { @() }
  $next = $Repair.Clone()
  $next['Run'] = @{
    Action         = $ActionId
    RunId          = $RunId
    Steps          = @(foreach ($id in $ids) { @{ Id = [string]$id; Status = 'pending'; Percent = $null } })
    Current        = -1
    Percent        = $null
    Log            = @()
    ElapsedSeconds = 0
    Stopping       = $false
  }
  $next['CloseRefused'] = $false
  return $next
}

function Update-RepairRunModel {
  <#
  .SYNOPSIS
    -Repair with its run brought up to date from the child's progress.json (-Progress) and the window's clock
    (-ElapsedSeconds, the run's own Stopwatch). Pure; returns a copy.
  .DESCRIPTION
    Without a run, -Repair as it is. -Progress (a hashtable, or an object read from JSON, or $null when there is none
    yet) counts only when its Action is the run's, and its RunId too when both have one; then:
      - Steps: its rows @{ Id; Status; Percent } (a status this page does not know is 'pending'; a percent that is no
        number is $null; a row that is no object or has no Id is left out); a progress without a usable row keeps
        the run's;
      - Current: its index (-1 when it has none or it is no whole Int32: ConvertTo-RepairIndex); Percent: the running
        step's percent ($null when unknown);
      - Log: its last 12 lines, as text (an object in the list is left out).
    ElapsedSeconds is always taken; Action, RunId and Stopping (Stop already pressed) stay. A field of the wrong type
    never throws (Task 4 review M1).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Repair,
    [AllowNull()]$Progress,
    [int]$ElapsedSeconds = 0
  )

  $run = $Repair['Run']
  if ($run -isnot [System.Collections.IDictionary]) { return $Repair }
  $nextRun = @{}
  foreach ($key in @($run.Keys)) { $nextRun[$key] = $run[$key] }
  $nextRun['ElapsedSeconds'] = [math]::Max(0, $ElapsedSeconds)

  $action = [string](Get-RepairEntry -From $Progress -Name 'Action')
  $runId = [string](Get-RepairEntry -From $Progress -Name 'RunId')
  $ours = ($null -ne $Progress) -and ($action -ceq [string]$run['Action']) -and
    ($runId -eq '' -or [string]$run['RunId'] -eq '' -or $runId -ceq [string]$run['RunId'])
  if ($ours) {
    $steps = @(foreach ($row in @(Get-RepairEntry -From $Progress -Name 'Steps')) {
        if (-not (Test-RepairObject -Value $row)) { continue }
        $id = [string](Get-RepairEntry -From $row -Name 'Id')
        if ($id -eq '') { continue }
        $status = [string](Get-RepairEntry -From $row -Name 'Status')
        if ($script:RepairStepStatuses -cnotcontains $status) { $status = 'pending' }
        @{ Id = $id; Status = $status; Percent = (ConvertTo-RepairPercent -Value (Get-RepairEntry -From $row -Name 'Percent')) }
      })
    if ($steps.Count -gt 0) { $nextRun['Steps'] = $steps }
    $nextRun['Current'] = ConvertTo-RepairIndex -Value (Get-RepairEntry -From $Progress -Name 'Current')
    $percent = $null
    foreach ($step in @($nextRun['Steps'])) { if ($step['Status'] -ceq 'running' -and $null -ne $step['Percent']) { $percent = $step['Percent'] } }
    $nextRun['Percent'] = $percent
    $log = @(foreach ($line in @(Get-RepairEntry -From $Progress -Name 'Log')) { if ($null -ne $line -and -not (Test-RepairObject -Value $line)) { [string]$line } })
    if ($log.Count -gt 12) { $log = $log[($log.Count - 12)..($log.Count - 1)] }
    $nextRun['Log'] = $log
  }

  $next = $Repair.Clone()
  $next['Run'] = $nextRun
  return $next
}

function Complete-RepairRunModel {
  <#
  .SYNOPSIS
    -Repair with its run ended on -Result (result.json, or the window's own: New-RepairWindowResult). Pure; returns a
    copy.
  .DESCRIPTION
    Run = $null; Result = -Result (the result panel shows it); Done gets @{ Action; Outcome; Color; EndedAt } (the
    visit's list, which the next child gets in its args); Strip.State = 'loading' with the chips kept (the window reads
    the strip again after every action: plan, "The strip ... again after every action"); CloseRefused = $false.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Repair,
    [AllowNull()]$Result
  )

  $action = [string](Get-RepairEntry -From $Result -Name 'Action')
  if ($action -eq '' -and $Repair['Run'] -is [System.Collections.IDictionary]) { $action = [string]$Repair['Run']['Action'] }
  $done = New-Object System.Collections.Generic.List[object]
  foreach ($entry in @($Repair['Done'])) { if ($null -ne $entry) { $done.Add($entry) } }
  $done.Add(@{ Action = $action; Outcome = [string](Get-RepairEntry -From $Result -Name 'Outcome'); Color = [string](Get-RepairEntry -From $Result -Name 'Color')
               EndedAt = [string](Get-RepairEntry -From $Result -Name 'EndedAt') })

  $strip = @{}
  if ($Repair['Strip'] -is [System.Collections.IDictionary]) { foreach ($key in @($Repair['Strip'].Keys)) { $strip[$key] = $Repair['Strip'][$key] } }
  $strip['State'] = 'loading'

  $next = $Repair.Clone()
  $next['Run'] = $null
  $next['Result'] = $Result
  $next['Done'] = $done.ToArray()
  $next['Strip'] = $strip
  $next['CloseRefused'] = $false
  return $next
}

function New-RepairWindowResult {
  <#
  .SYNOPSIS
    The result the window writes itself when the child gave none (plan "The files of one run": result). Pure.
  .DESCRIPTION
    For -Outcome TimedOut (the window killed the child at its deadline) and Failed (the child ended without a result,
    or could not start). The steps are the run's last ones (its last progress): the running step 'timedout'
    (TimedOut) or 'failed' (Failed), the pending ones 'skipped', the others as they were. One CRIT finding -Code with
    -Arguments in ASCII and its English text (Get-ToolText; the window shows finding.<Code> in its language). RED.
    @{ Action; RunId; Outcome; Color = 'RED'; Steps; Findings; RestartRequired = $false; Offers = @{ DiskCheck =
    $false; DismSource = $null }; Files = @{}; Data = @{}; StartedAt = ''; EndedAt = -EndedAt }.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Repair,
    [Parameter(Mandatory)][ValidateSet('TimedOut', 'Failed')][string]$Outcome,
    [Parameter(Mandatory)][string]$Code,
    [AllowNull()][object[]]$Arguments,
    [AllowEmptyString()][string]$EndedAt = ''
  )

  $run = $Repair['Run']
  if ($run -isnot [System.Collections.IDictionary]) { $run = @{} }
  $running = if ($Outcome -ceq 'TimedOut') { 'timedout' } else { 'failed' }
  $steps = @(foreach ($step in @($run['Steps'])) {
      if ($null -eq $step) { continue }
      $status = [string](Get-RepairEntry -From $step -Name 'Status')
      if ($status -ceq 'running') { $status = $running } elseif ($status -ceq 'pending') { $status = 'skipped' }
      @{ Id = [string](Get-RepairEntry -From $step -Name 'Id'); Status = $status; Percent = $null }
    })
  $values = [string[]]@(foreach ($a in @($Arguments)) { if ($null -ne $a) { ConvertTo-ScreenText -Text ([string]$a) } })
  $finding = @{ Level = 'CRIT'; Code = $Code; Text = (Get-ToolText -Key ('finding.' + $Code) -Arguments $values); Args = $values }
  return @{
    Action          = [string]$run['Action']
    RunId           = [string]$run['RunId']
    Outcome         = $Outcome
    Color           = 'RED'
    Steps           = $steps
    Findings        = @($finding)
    RestartRequired = $false
    Offers          = @{ DiskCheck = $false; DismSource = $null }
    Files           = @{}
    Data            = @{}
    StartedAt       = ''
    EndedAt         = $EndedAt
  }
}

# --- The page at work (repair Task 5) ------------------------------------------------------------------------------
# What a click, a tick or a key does to the page's model (Update-RepairModel). The window (Toolbox.ps1,
# RepairPage.ps1) starts what the model asks for (Repair.Pending, an action id, one-shot) and the info child an open
# Network reset or Ghost devices confirmation waits for. Pure, like the rest of this file: each call returns a copy.

function ConvertTo-RepairFlags {
  # Private. A Remote reading (a hashtable or an object read from JSON) as @{ <name> = <bool> }: each value counts only
  # when it is $true. Anything else is an empty table.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Value)

  $flags = @{}
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in @($Value.Keys)) { $flags[[string]$key] = ($Value[$key] -eq $true) }
  } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
    foreach ($property in $Value.PSObject.Properties) { $flags[$property.Name] = ($property.Value -eq $true) }
  }
  return $flags
}

function Copy-RepairEntry {
  # Private. A one-level copy of a hashtable (an open confirmation, a device item), so the model is replaced, never
  # changed in place.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][System.Collections.IDictionary]$Entry)

  $copy = @{}
  foreach ($key in @($Entry.Keys)) { $copy[$key] = $Entry[$key] }
  return $copy
}

function Get-RepairStartAction {
  # Private. The catalog action a tile starts once it is confirmed: Ghost devices removes (ghostRemove), Network reset
  # resets (netReset; the last action of $script:RepairTileActions); every other tile is its own action.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowEmptyString()][string]$Id)

  if ($script:RepairTileActions.Contains($Id)) { return [string](@($script:RepairTileActions[$Id])[-1]) }
  return $Id
}

function Get-RepairInfoAction {
  # Private. The read-only child a tile's confirmation waits for before it can be confirmed: netInfo (Network reset),
  # ghostList (Ghost devices); the first action of $script:RepairTileActions. '' for every other tile.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowEmptyString()][string]$Id)

  if ($script:RepairTileActions.Contains($Id)) { return [string](@($script:RepairTileActions[$Id])[0]) }
  return ''
}

function Get-RepairConfirmKind {
  # Private. How the action catalog says -ActionId is confirmed: 'none', 'confirm' or 'yes'. An action without a row,
  # or a value this page does not know, is 'yes', the strictest (such a tile is not available anyway: its gate says
  # reason.unavailable).
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowEmptyString()][string]$ActionId)

  $kind = ''
  if ($null -ne $script:ToolActionCatalog -and $script:ToolActionCatalog.Contains($ActionId)) {
    $entry = $script:ToolActionCatalog[$ActionId]
    if ($entry -is [System.Collections.IDictionary]) { $kind = [string]$entry['Confirm'] }
  }
  if ($kind -cin 'none', 'confirm', 'yes') { return $kind }
  return 'yes'
}

function ConvertTo-RepairValues {
  # Private. The text values of a list read from a file (gateways, DNS servers, languages): every entry that is not
  # empty and not an object, as a string. Emitted one by one: wrap the call in @().
  [CmdletBinding()]
  param([AllowNull()]$Value)

  foreach ($entry in @($Value)) {
    if ($null -eq $entry -or (Test-RepairObject -Value $entry)) { continue }
    $text = [string]$entry
    if ($text -ne '') { $text }
  }
}

function ConvertTo-RepairAdapterLine {
  <#
  .SYNOPSIS
    Private. One adapter's static settings as a confirmation line (spec 6.6: every value shown), or $null when it has
    none: @{ Key = 'confirm.static'; Args = @(<alias>, '<ip>/<prefix>, ..., gateway <ip>, ..., DNS <ip>, ...') }.
  .DESCRIPTION
    -Adapter is a row of netInfo's Data.NetInfo.Adapters or of a saved backup (plan Task 7: @{ Alias; Guid; Mac;
    Addresses = @( @{ Ip; Prefix } ); Gateways = [string[]]; Dns = [string[]] }), a hashtable or an object read from
    JSON. The values are machine values: the view shows the line left-to-right. The alias names the adapter (its MAC
    when it has none).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Adapter)

  if (-not (Test-RepairObject -Value $Adapter)) { return $null }
  $addresses = @(foreach ($row in @(Get-RepairEntry -From $Adapter -Name 'Addresses')) {
      if (-not (Test-RepairObject -Value $row)) { continue }
      $ip = [string](Get-RepairEntry -From $row -Name 'Ip')
      if ($ip -eq '') { continue }
      $prefix = [string](Get-RepairEntry -From $row -Name 'Prefix')
      if ($prefix -ne '') { '{0}/{1}' -f $ip, $prefix } else { $ip }
    })
  $gateways = @(ConvertTo-RepairValues -Value (Get-RepairEntry -From $Adapter -Name 'Gateways'))
  $dns = @(ConvertTo-RepairValues -Value (Get-RepairEntry -From $Adapter -Name 'Dns'))
  $parts = New-Object System.Collections.Generic.List[string]
  if ($addresses.Count -gt 0) { $parts.Add(($addresses -join ', ')) }
  if ($gateways.Count -gt 0) { $parts.Add('gateway ' + ($gateways -join ', ')) }
  if ($dns.Count -gt 0) { $parts.Add('DNS ' + ($dns -join ', ')) }
  if ($parts.Count -eq 0) { return $null }
  $alias = [string](Get-RepairEntry -From $Adapter -Name 'Alias')
  if ($alias -eq '') { $alias = [string](Get-RepairEntry -From $Adapter -Name 'Mac') }
  if ($alias -eq '') { $alias = '?' }
  return @{ Key = 'confirm.static'; Args = @($alias, ($parts.ToArray() -join ', ')) }
}

function Limit-RepairText {
  # Private. -Text cut to -Length characters, never between the two halves of a surrogate pair.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Length)

  $value = [string]$Text
  if ($value.Length -le $Length) { return $value }
  $cut = $Length
  if ([char]::IsHighSurrogate($value[$cut - 1])) { $cut-- }
  return $value.Substring(0, $cut)
}

function New-RepairConfirm {
  # Private. An open confirmation (plan "The repair model": Confirm), its Typed and AtPc empty.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][string]$Kind,
    [AllowNull()][object[]]$Lines,
    [bool]$Loading = $false,
    [AllowNull()][hashtable]$Options
  )

  return @{ Action = $Action; Kind = $Kind; Typed = ''; AtPc = $false; Loading = $Loading; Lines = @($Lines | Where-Object { $null -ne $_ })
            Remote = $null; Items = @(); Options = $(if ($null -ne $Options) { $Options } else { @{} }) }
}

function Update-RepairModel {
  <#
  .SYNOPSIS
    One page action applied to the toolbox model (-Model, its Repair): the new model. Pure; returns a copy, the input
    is never changed.
  .DESCRIPTION
    Repair.Pending, the action the window must start now, is one-shot: every call starts with it $null, and only Tile
    and Confirm set it. -Value is a string for the clicks and keys, the info child's Data for NetInfo and GhostItems.
      - Tile <id>: nothing unless the tile's gate allows it (Get-RepairGate: a disabled tile's click, raised in code,
        changes nothing), and nothing when its own confirmation is already open (what was typed and ticked stays).
        A tile of the rows becomes Selected. Its action (Get-RepairStartAction: ghosts removes with ghostRemove) is
        confirmed as the catalog says (Get-RepairConfirmKind): 'none' with a stick is Pending at once (any open
        confirmation closes); otherwise a confirmation (Kind 'confirm' for a read-only action without a stick, spec
        8), its Lines @{ Key; Args }: tile.<id>.changes (not for a read-only action), then the gate's warnings.
        Network reset and Ghost devices open Loading until their info child answers (NetInfo, GhostItems). Restore
        network settings lists every value it will put back (spec 6.6: one confirm.static line per adapter of
        Repair.NetBackup.Adapters with a static value, else confirm.noStatic), Options = @{ File; Sha256 } (the child
        refuses a file that changed since). Tile dismSource is the DISM offer.
      - Offer dismSource: the confirmation of the DISM retry (spec 6.2) from Result.Offers.DismSource: the change
        list, the file's details (result.offerDism: path, edition, architecture, languages, build), result.buildDiffers
        (this PC's build) and result.languageDiffers (the file's languages, the PC's) when set, the gate's warnings;
        Options = @{ Path; Type; Index }. No offer, no confirmation.
      - YesText <text> (the first 8 characters, the YES box's length), AtPc (toggled), GhostTick <index> (toggled; the
        confirm.ghostCount line follows): the open confirmation's; nothing without one.
      - BackedUp (toggled), Complaint <text> (cut to 2000 characters), Hover <id> (Selected, a tile of the rows only),
        ConfirmCancel (Confirm $null).
      - NetInfo <Data.NetInfo>: an open Network reset confirmation that is loading stops loading, takes Remote
        (each reported session a flag) and one confirm.static line per adapter with a static value (or
        confirm.noStatic). GhostItems <Data.Ghosts>: an open Ghost devices confirmation that is loading gets one
        item @{ InstanceId; Class; Name; Ticked = $true } per device that is not excluded (Excluded empty or $false;
        a row without an InstanceId is skipped) and the line confirm.ghostCount @(<ticked>, <devices>, <left out>).
        An answer with no such confirmation open, a second answer, or a NetInfo that is no object, changes nothing.
      - Confirm: only when Test-RepairConfirmReady allows it now (the gate re-checked at this moment, YES for a 'yes'
        kind, the at-PC tick, a ticked device): Pending = the tile's action, the confirmation kept with its Options
        (Ghost devices: Ids = the ticked InstanceIds only) for the window to start it with. A Restart PC question is
        Toolbox.ps1's.
    Any other action changes nothing (but Pending).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Model,
    [Parameter(Mandatory)][string]$Action,
    [AllowNull()]$Value
  )

  $next = $Model.Clone()
  $repair = $Model['Repair'].Clone()
  $repair['Pending'] = $null
  $next['Repair'] = $repair
  $confirm = $repair['Confirm']
  $open = ($confirm -is [System.Collections.IDictionary])
  $text = if ($null -eq $Value -or (Test-RepairObject -Value $Value)) { '' } else { [string]$Value }
  $tileIds = @($script:RepairTileRows.Values | ForEach-Object { $_ })

  switch -CaseSensitive ($Action) {
    { $_ -ceq 'Tile' -and $text -cne 'dismSource' } {
      $gate = Get-RepairGate -Model $next -ActionId $text
      if (-not $gate.Enabled) { break }
      if ($open -and [string]$confirm['Action'] -ceq $text) { break }
      if ($tileIds -ccontains $text) { $repair['Selected'] = $text }
      $start = Get-RepairStartAction -Id $text
      $kind = Get-RepairConfirmKind -ActionId $start
      if ($kind -ceq 'none' -and (Test-RepairStick -Repair $repair)) {
        $repair['Confirm'] = $null
        $repair['Pending'] = $start
        break
      }
      $lines = New-Object System.Collections.Generic.List[object]
      $options = @{}
      if ($kind -cne 'none') { $lines.Add(@{ Key = "tile.$text.changes"; Args = @() }) }
      if ($text -ceq 'netRestore') {
        $backup = $repair['NetBackup']
        $shown = 0
        foreach ($adapter in @(Get-RepairEntry -From $backup -Name 'Adapters')) {
          $line = ConvertTo-RepairAdapterLine -Adapter $adapter
          if ($null -ne $line) { $lines.Add($line); $shown++ }
        }
        if ($shown -eq 0) { $lines.Add(@{ Key = 'confirm.noStatic'; Args = @() }) }
        $options = @{ File = [string](Get-RepairEntry -From $backup -Name 'Path'); Sha256 = [string](Get-RepairEntry -From $backup -Name 'Sha256') }
      }
      foreach ($warn in @($gate.Warns)) { $lines.Add(@{ Key = $warn; Args = @() }) }
      $repair['Confirm'] = New-RepairConfirm -Action $text -Kind $(if ($kind -ceq 'none') { 'confirm' } else { $kind }) -Lines $lines.ToArray() `
        -Loading ((Get-RepairInfoAction -Id $text) -ne '') -Options $options
    }
    { $_ -ceq 'Offer' -or ($_ -ceq 'Tile' -and $text -ceq 'dismSource') } {
      if ($text -cne 'dismSource') { break }
      $gate = Get-RepairGate -Model $next -ActionId 'dismSource'
      if (-not $gate.Enabled) { break }
      if ($open -and [string]$confirm['Action'] -ceq 'dismSource') { break }
      $offer = Get-RepairEntry -From (Get-RepairEntry -From $repair['Result'] -Name 'Offers') -Name 'DismSource'
      if (-not (Test-RepairObject -Value $offer)) { break }
      $languages = @(ConvertTo-RepairValues -Value (Get-RepairEntry -From $offer -Name 'Languages')) -join ', '
      $lines = New-Object System.Collections.Generic.List[object]
      $lines.Add(@{ Key = 'tile.dismSource.changes'; Args = @() })
      $lines.Add(@{ Key = 'result.offerDism'; Args = @([string](Get-RepairEntry -From $offer -Name 'Path'), [string](Get-RepairEntry -From $offer -Name 'Edition'),
                                                        [string](Get-RepairEntry -From $offer -Name 'Arch'), $languages, [string](Get-RepairEntry -From $offer -Name 'Build')) })
      if ((Get-RepairEntry -From $offer -Name 'BuildDiffers') -eq $true) { $lines.Add(@{ Key = 'result.buildDiffers'; Args = @([string]$repair['OsBuild']) }) }
      if ((Get-RepairEntry -From $offer -Name 'LanguageDiffers') -eq $true) {
        $lines.Add(@{ Key = 'result.languageDiffers'; Args = @($languages, [string](Get-RepairEntry -From $offer -Name 'PcLanguage')) })
      }
      foreach ($warn in @($gate.Warns)) { $lines.Add(@{ Key = $warn; Args = @() }) }
      $options = @{ Path = [string](Get-RepairEntry -From $offer -Name 'Path'); Type = [string](Get-RepairEntry -From $offer -Name 'Type')
                    Index = (Get-RepairEntry -From $offer -Name 'Index') }
      $repair['Confirm'] = New-RepairConfirm -Action 'dismSource' -Kind (Get-RepairConfirmKind -ActionId 'dismSource') -Lines $lines.ToArray() -Options $options
    }
    'YesText' {
      if (-not $open) { break }
      $c = Copy-RepairEntry -Entry $confirm
      $c['Typed'] = Limit-RepairText -Text $text -Length 8
      $repair['Confirm'] = $c
    }
    'AtPc' {
      if (-not $open) { break }
      $c = Copy-RepairEntry -Entry $confirm
      $c['AtPc'] = -not ($confirm['AtPc'] -eq $true)
      $repair['Confirm'] = $c
    }
    'GhostTick' {
      $index = 0
      if (-not $open -or -not [int]::TryParse($text, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$index)) { break }
      $items = @(foreach ($item in @($confirm['Items'])) { if ($item -is [System.Collections.IDictionary]) { Copy-RepairEntry -Entry $item } })
      if ($index -ge $items.Count) { break }
      $items[$index]['Ticked'] = -not ($items[$index]['Ticked'] -eq $true)
      $ticked = @($items | Where-Object { $_['Ticked'] -eq $true }).Count
      $c = Copy-RepairEntry -Entry $confirm
      $c['Items'] = $items
      $c['Lines'] = @(foreach ($line in @($confirm['Lines'])) {
          if ($line -is [System.Collections.IDictionary] -and [string]$line['Key'] -ceq 'confirm.ghostCount') {
            $counts = @($line['Args'])
            @{ Key = 'confirm.ghostCount'; Args = @($ticked, $(if ($counts.Count -gt 1) { $counts[1] } else { $items.Count }), $(if ($counts.Count -gt 2) { $counts[2] } else { 0 })) }
          } else { $line }
        })
      $repair['Confirm'] = $c
    }
    'BackedUp' { $repair['BackedUp'] = -not ($repair['BackedUp'] -eq $true) }
    'Complaint' { $repair['Complaint'] = Limit-RepairText -Text $text -Length 2000 }
    'Hover' { if ($tileIds -ccontains $text) { $repair['Selected'] = $text } }
    'ConfirmCancel' { $repair['Confirm'] = $null }
    'NetInfo' {
      if (-not $open -or [string]$confirm['Action'] -cne 'netReset' -or $confirm['Loading'] -ne $true -or -not (Test-RepairObject -Value $Value)) { break }
      $lines = New-Object System.Collections.Generic.List[object]
      foreach ($line in @($confirm['Lines'])) { if ($null -ne $line) { $lines.Add($line) } }
      $shown = 0
      foreach ($adapter in @(Get-RepairEntry -From $Value -Name 'Adapters')) {
        $line = ConvertTo-RepairAdapterLine -Adapter $adapter
        if ($null -ne $line) { $lines.Add($line); $shown++ }
      }
      if ($shown -eq 0) { $lines.Add(@{ Key = 'confirm.noStatic'; Args = @() }) }
      $c = Copy-RepairEntry -Entry $confirm
      $c['Loading'] = $false
      $c['Remote'] = ConvertTo-RepairFlags -Value (Get-RepairEntry -From $Value -Name 'Remote')
      $c['Lines'] = $lines.ToArray()
      $repair['Confirm'] = $c
    }
    'GhostItems' {
      if (-not $open -or [string]$confirm['Action'] -cne 'ghosts' -or $confirm['Loading'] -ne $true) { break }
      $items = New-Object System.Collections.Generic.List[object]
      $devices = 0
      $leftOut = 0
      foreach ($device in @($Value)) {
        if (-not (Test-RepairObject -Value $device)) { continue }
        $id = [string](Get-RepairEntry -From $device -Name 'InstanceId')
        if ($id -eq '') { continue }
        $devices++
        # Spec 6.7: a device the child left out (a reason, or any value but empty and $false) is never an item.
        $excluded = Get-RepairEntry -From $device -Name 'Excluded'
        $kept = ($null -eq $excluded) -or ($excluded -is [bool] -and -not $excluded) -or ($excluded -isnot [bool] -and [string]$excluded -eq '')
        if (-not $kept) { $leftOut++; continue }
        $items.Add(@{ InstanceId = $id; Class = [string](Get-RepairEntry -From $device -Name 'Class'); Name = [string](Get-RepairEntry -From $device -Name 'Name'); Ticked = $true })
      }
      $lines = New-Object System.Collections.Generic.List[object]
      foreach ($line in @($confirm['Lines'])) { if ($null -ne $line) { $lines.Add($line) } }
      $lines.Add(@{ Key = 'confirm.ghostCount'; Args = @($items.Count, $devices, $leftOut) })
      $c = Copy-RepairEntry -Entry $confirm
      $c['Loading'] = $false
      $c['Items'] = $items.ToArray()
      $c['Lines'] = $lines.ToArray()
      $repair['Confirm'] = $c
    }
    'Confirm' {
      if (-not $open -or [string]$confirm['Kind'] -ceq 'restart' -or -not (Test-RepairConfirmReady -Model $next)) { break }
      $tile = [string]$confirm['Action']
      $c = Copy-RepairEntry -Entry $confirm
      if ($tile -ceq 'ghosts') {
        $c['Options'] = @{ Ids = [string[]]@(foreach ($item in @($confirm['Items'])) { if ($null -ne $item -and (Get-RepairEntry -From $item -Name 'Ticked') -eq $true) { [string](Get-RepairEntry -From $item -Name 'InstanceId') } }) }
      } elseif ($c['Options'] -isnot [System.Collections.IDictionary]) {
        $c['Options'] = @{}
      }
      $repair['Confirm'] = $c
      $repair['Pending'] = Get-RepairStartAction -Id $tile
    }
  }
  return $next
}
