# src/Toolbox/SetupPlanner.ps1
# The BenTech Toolbox's planning rules (toolbox spec 5.2, 10b.5, 10b.6): the profiles of config.json, the
# choices a profile fills in, the check every Choices table passes before a run starts, and whether a run's
# choices still match its profile (the report's "(changed)"). Also the toolbox window's model (New-ToolboxModel),
# how one click changes it (Update-ToolboxModel) and its "What will happen" lines (Get-ToolboxPlanLines), which
# Toolbox.ps1 renders (toolbox spec 4.1).
#
# Pure: no logging, no I/O, no console. Values in, values out; the callers log (ConvertTo-ValidChoices returns
# the dropped tweak ids for that). Needs Catalog.ps1 (Get-TweakCatalog, Get-EffectiveTweaks, Get-RemoteChoice,
# Get-WindowsUpdateChoice, Test-ZoomChosen, Get-StepPlan, $script:RemoteChoices, $script:StepCatalog),
# StartScreen.ps1 (New-DefaultChoices, $script:OfficeChoices) and RepairPlanner.ps1 (New-RepairModel: the repair
# page's part of the model); the bundle holds every file.
#
# A profile only fills in the options (spec 5.2): Office, Remote, 7-Zip, the tweak selection and the restore
# point, the Windows Update choice only when it sets windowsUpdate (wu spec 3.1), and Zoom only when it sets
# zoom (zoom spec 3.1). The Type (laptop or
# desktop) is never part of a profile: it is detected. Choices keep ASCII ids only, so
# nothing Hebrew reaches state.json or setup.log; the Hebrew names stay in the profile.

# The windows-update step's title in the "What will happen" column when the UPDATES row is on Drivers only (wu spec
# 3.1); the window passes its language's step.windows-update.drivers instead (Get-ToolboxPlanLines -Titles).
$script:WindowsUpdateDriversTitle = 'Windows Update (drivers only)'

function Get-SetupProfiles {
  <#
  .SYNOPSIS
    The valid profiles of Config.profiles, in config order, one hashtable each. Never throws.
  .DESCRIPTION
    Each: @{ Id; Name = @{ en; he }; Office; Remote; SevenZip; RestorePoint; Tweaks = [string[]]; WindowsUpdate; Zoom }.
    Left out: an id that does not match ^[a-z][a-z0-9-]{0,31}$, an id an earlier profile already has, an empty
    name.en. A bad value is repaired, never a reason to drop the profile:
      - Office is upper-cased; outside $script:OfficeChoices it is defaults.office, or OFF when that is no
        better (nothing gets installed that nobody asked for);
      - Remote goes through Get-RemoteChoice (missing or unknown is ANYDESK);
      - WindowsUpdate (wu spec 3.1) is '' when the entry has no windowsUpdate or it is $null, empty or
        whitespace (the profile does not set it); otherwise it goes through Get-WindowsUpdateChoice (an invalid
        value is FULL);
      - Zoom (zoom spec 3.1) is the entry's zoom when it is a bool, else $null (the profile does not set it);
      - sevenZip and restorePoint must be bools; otherwise defaults.sevenZip and $true (spec 10b.5);
      - Tweaks: the profile's tweaks when it has that property (an empty list is a choice), else every catalog
        entry with Default; plus tweaksAdd. Only catalog ids, in catalog order, each once. This is the
        selection: Get-EffectiveTweaks applies the Type, Office and build rules later.
    Emitted one by one: wrap the call in @().
  #>
  [CmdletBinding()]
  param([AllowNull()]$Config)

  if ($null -eq $Config) { return }
  $section = $Config.PSObject.Properties['profiles']
  if ($null -eq $section -or $null -eq $section.Value) { return }

  $defaultOffice = ([string]$Config.defaults.office).ToUpperInvariant()
  if ($script:OfficeChoices -notcontains $defaultOffice) { $defaultOffice = 'OFF' }
  $defaultSevenZip = [bool]$Config.defaults.sevenZip
  $catalog = @(Get-TweakCatalog -Config $Config)

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($entry in @($section.Value)) {
    if ($null -eq $entry) { continue }
    $id = $entry.id
    if ($id -isnot [string] -or $id -cnotmatch '^[a-z][a-z0-9-]{0,31}\z') { continue }
    $nameEn = $entry.name.en
    if ($nameEn -isnot [string] -or [string]::IsNullOrWhiteSpace($nameEn)) { continue }
    if (-not $seen.Add($id)) { continue }

    $office = ([string]$entry.office).ToUpperInvariant()
    if ($script:OfficeChoices -notcontains $office) { $office = $defaultOffice }

    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ($null -ne $entry.PSObject.Properties['tweaks']) {
      foreach ($t in @($entry.tweaks)) { if ($null -ne $t) { $null = $wanted.Add([string]$t) } }
    } else {
      foreach ($tweak in $catalog) { if ($tweak.Default) { $null = $wanted.Add($tweak.Id) } }
    }
    foreach ($t in @($entry.tweaksAdd)) { if ($null -ne $t) { $null = $wanted.Add([string]$t) } }

    $windowsUpdate = ''
    $wuProperty = $entry.PSObject.Properties['windowsUpdate']
    if ($null -ne $wuProperty -and -not [string]::IsNullOrWhiteSpace([string]$wuProperty.Value)) { $windowsUpdate = Get-WindowsUpdateChoice -Choices @{ WindowsUpdate = [string]$wuProperty.Value } }

    @{
      Id            = $id
      Name          = @{ en = $nameEn; he = [string]$entry.name.he }
      Office        = $office
      Remote        = (Get-RemoteChoice -Choices @{ Remote = [string]$entry.remote })
      SevenZip      = $(if ($entry.sevenZip -is [bool]) { $entry.sevenZip } else { $defaultSevenZip })
      RestorePoint  = $(if ($entry.restorePoint -is [bool]) { $entry.restorePoint } else { $true })
      Tweaks        = [string[]]@(foreach ($tweak in $catalog) { if ($wanted.Contains($tweak.Id)) { $tweak.Id } })
      WindowsUpdate = $windowsUpdate
      Zoom          = $(if ($entry.zoom -is [bool]) { $entry.zoom } else { $null })
    }
  }
}

function Get-DefaultProfileId {
  <#
  .SYNOPSIS
    defaults.profile when it names a valid profile (Get-SetupProfiles), else ''. Never throws.
  .DESCRIPTION
    An unknown default means no profile: New-DefaultChoices then opens on defaults.* and the catalog defaults
    (spec 5.2: a profile that names an unknown profile id is skipped).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Config)

  if ($null -eq $Config) { return '' }
  $wanted = $Config.defaults.profile
  if ($wanted -isnot [string] -or $wanted -eq '') { return '' }
  foreach ($p in @(Get-SetupProfiles -Config $Config)) { if ($p.Id -ceq $wanted) { return $p.Id } }
  return ''
}

function Get-ProfileChoices {
  <#
  .SYNOPSIS
    The choices a profile fills in: @{ Profile; Office; Remote; SevenZip; RestorePoint; Tweaks }, plus
    WindowsUpdate only when the profile sets it (wu spec 3.1) and Zoom only when it sets zoom (zoom spec 3.1), or
    $null for an id that names no valid profile. Never throws. Mode is not among them: the Type is detected.
    New-DefaultChoices and Update-ToolboxModel's Profile click copy every key returned, so a profile without
    windowsUpdate or zoom leaves that choice as it is.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()]$Config,
    [AllowNull()][AllowEmptyString()][string]$ProfileId
  )

  if ([string]::IsNullOrEmpty($ProfileId)) { return $null }
  foreach ($p in @(Get-SetupProfiles -Config $Config)) {
    if ($p.Id -ceq $ProfileId) {
      $fill = @{ Profile = $p.Id; Office = $p.Office; Remote = $p.Remote; SevenZip = $p.SevenZip; RestorePoint = $p.RestorePoint; Tweaks = [string[]]@($p.Tweaks) }
      if ($p.WindowsUpdate -ne '') { $fill['WindowsUpdate'] = $p.WindowsUpdate }
      if ($p.Zoom -is [bool]) { $fill['Zoom'] = $p.Zoom }
      return $fill
    }
  }
  return $null
}

function ConvertTo-ValidChoices {
  <#
  .SYNOPSIS
    Checks every key of a Choices table against the whitelists (spec 5.2). Returns @{ Choices; Dropped }.
  .DESCRIPTION
    Choices is a new table with exactly nine keys: Mode, Office, Remote, SevenZip, RestorePoint, Profile, Tweaks,
    WindowsUpdate and Zoom. A bad value takes New-DefaultChoices' value for that key:
      - Mode must be LAPTOP or DESKTOP (upper-cased);
      - Office must be in $script:OfficeChoices (upper-cased);
      - Remote goes through Get-RemoteChoice (missing or unknown is ANYDESK, as every reader decides);
      - WindowsUpdate goes through Get-WindowsUpdateChoice (missing or unknown is FULL, not the default
        profile's value: wu spec 3.1, as every reader decides);
      - Zoom is Test-ZoomChosen (missing or not a bool is $false, as every reader decides: zoom spec 3.1);
      - SevenZip and RestorePoint must be [bool];
      - Profile must name a valid profile, else '' (no profile).
    Tweaks becomes the effective list (Get-EffectiveTweaks on the cleaned choices), so state.json records what
    will run; missing Tweaks is none. Dropped lists, in the order given and each once, the given tweak ids that
    are not catalog ids ('' and $null are dropped silently); the caller logs them. Ids a rule rules out (NumLock
    on a laptop) are not "dropped": they are simply not effective. Never throws for a loaded config.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()]$Choices,
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][hashtable]$Machine
  )

  $given = if ($Choices -is [System.Collections.IDictionary]) { $Choices } else { @{} }
  $defaults = New-DefaultChoices -Machine $Machine -Config $Config

  $mode = ([string]$given['Mode']).ToUpperInvariant()
  if ($mode -notin 'LAPTOP', 'DESKTOP') { $mode = $defaults.Mode }
  $office = ([string]$given['Office']).ToUpperInvariant()
  if ($script:OfficeChoices -notcontains $office) { $office = $defaults.Office }
  $profileId = ''
  if ($given['Profile'] -is [string] -and $null -ne (Get-ProfileChoices -Config $Config -ProfileId $given['Profile'])) { $profileId = $given['Profile'] }

  $clean = @{
    Mode          = $mode
    Office        = $office
    Remote        = (Get-RemoteChoice -Choices $given)
    SevenZip      = $(if ($given['SevenZip'] -is [bool]) { $given['SevenZip'] } else { $defaults.SevenZip })
    RestorePoint  = $(if ($given['RestorePoint'] -is [bool]) { $given['RestorePoint'] } else { $defaults.RestorePoint })
    Profile       = $profileId
    Tweaks        = $(if ($given.Contains('Tweaks')) { $given['Tweaks'] } else { $null })
    WindowsUpdate = (Get-WindowsUpdateChoice -Choices $given)
    Zoom          = (Test-ZoomChosen -Choices $given)
  }

  $catalogIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($tweak in @(Get-TweakCatalog -Config $Config)) { $null = $catalogIds.Add($tweak.Id) }
  $dropped = New-Object System.Collections.Generic.List[string]
  foreach ($id in @($clean.Tweaks)) {
    $text = [string]$id
    if ($null -eq $id -or $text -eq '' -or $catalogIds.Contains($text) -or $dropped.Contains($text)) { continue }
    $dropped.Add($text)
  }
  $clean.Tweaks = [string[]]@(Get-EffectiveTweaks -Choices $clean -Config $Config -Machine $Machine)

  return @{ Choices = $clean; Dropped = [string[]]$dropped.ToArray() }
}

function Test-ProfileChanged {
  <#
  .SYNOPSIS
    $true when the run's choices no longer match the profile they started from (spec 10b.6). Never throws.
  .DESCRIPTION
    $false when Choices.Profile names no valid profile (empty, unknown or gone). Otherwise $true when any of
    these differs from Get-ProfileChoices: Office (upper-cased), Get-RemoteChoice, [bool]SevenZip,
    [bool]RestorePoint, Get-WindowsUpdateChoice (only when the profile sets windowsUpdate: wu spec 3.1, so
    DRIVERS is no change for a profile that leaves it alone), Test-ZoomChosen (only when the profile sets zoom:
    zoom spec 3.1, so Zoom on is no change for a profile that leaves it alone), or the effective tweak list, the
    profile's selection being evaluated with the run's Mode (so a Desktop that brings NumLock in is no change).
    Mode never counts: the Type is not part of a profile.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()]$Choices,
    [AllowNull()]$Config,
    [AllowNull()]$Machine
  )

  $c = if ($Choices -is [System.Collections.IDictionary]) { $Choices } else { @{} }
  $profileChoices = Get-ProfileChoices -Config $Config -ProfileId ([string]$c['Profile'])
  if ($null -eq $profileChoices) { return $false }

  if (([string]$c['Office']).ToUpperInvariant() -cne $profileChoices.Office) { return $true }
  if ((Get-RemoteChoice -Choices $c) -cne $profileChoices.Remote) { return $true }
  if ([bool]$c['SevenZip'] -ne [bool]$profileChoices.SevenZip) { return $true }
  if ([bool]$c['RestorePoint'] -ne [bool]$profileChoices.RestorePoint) { return $true }
  if ($profileChoices.Contains('WindowsUpdate') -and (Get-WindowsUpdateChoice -Choices $c) -cne $profileChoices.WindowsUpdate) { return $true }
  if ($profileChoices.Contains('Zoom') -and (Test-ZoomChosen -Choices $c) -ne [bool]$profileChoices.Zoom) { return $true }

  $run = @(Get-EffectiveTweaks -Choices $c -Config $Config -Machine $Machine) -join ','
  $fill = @(Get-EffectiveTweaks -Choices @{ Mode = $c['Mode']; Office = $profileChoices.Office; Tweaks = $profileChoices.Tweaks } -Config $Config -Machine $Machine) -join ','
  return ($run -cne $fill)
}

function New-ToolboxModel {
  <#
  .SYNOPSIS
    The toolbox window's model (toolbox spec 4.1, 4.3): what the window shows, as plain values. Pure.
  .DESCRIPTION
    @{ Language; Choices; OnAC; AdminProtection; IsFresh; Previous; MaxAgeDays }:
      - Language is config.toolbox.language when it is 'en' or 'he', else 'en' (the switch lasts for one run);
      - Choices is New-DefaultChoices (the default profile; Tweaks holds its selection, not yet filtered by
        the Type, Office and build rules);
      - OnAC, IsFresh and Previous (@{ StartedAt; Color } or $null) are the values the console start screen
        shows; AdminProtection is Test-AdminProtection's answer ('On', 'Off' or 'Unknown'; anything else is
        'Unknown');
      - MaxAgeDays is freshInstall.maxInstallAgeDays, for the "older than N days" warning;
      - Page is 'setup' (the window opens on New PC setup) and Repair is the Repair & diagnostics page's model
        (New-RepairModel, RepairPlanner.ps1) with -CanRun ($false by default: Show-ToolboxWindow passes $true when
        it has the setup files an action's child runs from, repair Task 4) and -SessionStamp, the visit's folder
        stamp ('yyyy-MM-dd_HHmm', invariant; by default now, when the window opens).
    The window renders it (Update-ToolboxView); nothing here reads the machine.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config,
    [AllowNull()][hashtable]$Previous,
    [Parameter(Mandatory)][bool]$IsFresh,
    [Parameter(Mandatory)][bool]$OnAC,
    [Parameter(Mandatory)][AllowEmptyString()][string]$AdminProtection,
    [bool]$CanRun = $false,
    [AllowEmptyString()][string]$SessionStamp = ([datetime]::Now.ToString('yyyy-MM-dd_HHmm', [Globalization.CultureInfo]::InvariantCulture))
  )

  $language = 'en'
  $wanted = $Config.toolbox.language
  if ($wanted -is [string] -and $wanted -cin 'en', 'he') { $language = $wanted }
  $protection = 'Unknown'
  foreach ($value in 'On', 'Off') { if ($AdminProtection -eq $value) { $protection = $value } }

  return @{
    Language        = $language
    Choices         = (New-DefaultChoices -Machine $Machine -Config $Config)
    OnAC            = $OnAC
    AdminProtection = $protection
    IsFresh         = $IsFresh
    Previous        = $Previous
    MaxAgeDays      = [int]$Config.freshInstall.maxInstallAgeDays
    Page            = 'setup'
    Repair          = (New-RepairModel -Machine $Machine -SessionStamp $SessionStamp -CanRun $CanRun)
  }
}

function Update-ToolboxModel {
  <#
  .SYNOPSIS
    Applies one window action to the toolbox model and returns the new model. Pure, like Update-StartChoices.
  .DESCRIPTION
    The input is never changed: the model, its Choices and the Tweaks array are copies. Actions and values are
    matched exactly (case-sensitive), as the window's a:<Action>:<Value> tags write them:
      - Profile <id>: every key Get-ProfileChoices returns: that profile's Office, Remote, SevenZip, RestorePoint,
        Tweaks and Profile, WindowsUpdate only when the profile sets windowsUpdate and Zoom only when it sets
        zoom; a profile that does not leaves that choice as it is (wu spec 3.1, zoom spec 3.1). Mode stays (the
        Type is detected, never part of a profile). An unknown id changes nothing.
      - Mode LAPTOP | DESKTOP, Office (one of $script:OfficeChoices), Remote (one of $script:RemoteChoices),
        WindowsUpdate (one of $script:WindowsUpdateChoices: FULL | DRIVERS): set.
      - SevenZip, RestorePoint: toggled (the value is ignored).
      - Zoom: toggled from Test-ZoomChosen (the value is ignored; zoom spec 3.1), so anything that is not the bool
        $true counts as off and the result is always a bool.
      - Tweak <id>: that catalog id is toggled in the selection, which is then in catalog order, each id once.
        The selection is not filtered by the Type or Office rules (Get-EffectiveTweaks does that), so NumLock
        comes back with Desktop. An id that is not in the catalog changes nothing.
      - Language en | he.
      - Power: OnAC = ($Value -eq 'true').
      - Page setup | repair: the page the window shows (the left nav).
    Any other action or value changes nothing. A changed option never changes Profile (spec 5.2): the report
    shows the profile's name with "(changed)" (Test-ProfileChanged).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Model,
    [Parameter(Mandatory)][string]$Action,
    [AllowNull()][AllowEmptyString()][string]$Value = '',
    [Parameter(Mandatory)]$Config
  )

  $next = $Model.Clone()
  $choices = $Model['Choices'].Clone()
  if ($choices['Tweaks'] -is [array]) { $choices['Tweaks'] = $choices['Tweaks'].Clone() }
  $next['Choices'] = $choices

  switch -CaseSensitive ($Action) {
    'Profile' {
      $fill = Get-ProfileChoices -Config $Config -ProfileId $Value
      # Every key the profile fills in: WindowsUpdate only when it sets windowsUpdate (wu spec 3.1).
      if ($null -ne $fill) { foreach ($key in @($fill.Keys)) { $choices[$key] = $fill[$key] } }
    }
    'Mode' { if ($Value -cin 'LAPTOP', 'DESKTOP') { $choices['Mode'] = $Value } }
    'Office' { if ($script:OfficeChoices -ccontains $Value) { $choices['Office'] = $Value } }
    'Remote' { if ($script:RemoteChoices -ccontains $Value) { $choices['Remote'] = $Value } }
    'WindowsUpdate' { if ($script:WindowsUpdateChoices -ccontains $Value) { $choices['WindowsUpdate'] = $Value } }
    'SevenZip' { $choices['SevenZip'] = -not [bool]$choices['SevenZip'] }
    'Zoom' { $choices['Zoom'] = -not (Test-ZoomChosen -Choices $choices) }
    'RestorePoint' { $choices['RestorePoint'] = -not [bool]$choices['RestorePoint'] }
    'Tweak' {
      $catalog = @(Get-TweakCatalog -Config $Config)
      $known = $false
      foreach ($tweak in $catalog) { if ($tweak.Id -ceq $Value) { $known = $true } }
      if ($known) {
        $selected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($id in @($choices['Tweaks'])) { if ($null -ne $id) { $null = $selected.Add([string]$id) } }
        if (-not $selected.Remove($Value)) { $null = $selected.Add($Value) }
        $choices['Tweaks'] = [string[]]@(foreach ($tweak in $catalog) { if ($selected.Contains($tweak.Id)) { $tweak.Id } })
      }
    }
    'Language' { if ($Value -cin 'en', 'he') { $next['Language'] = $Value } }
    'Power' { $next['OnAC'] = ($Value -eq 'true') }
    'Page' { if ($Value -cin 'setup', 'repair') { $next['Page'] = $Value } }
  }
  return $next
}

function Get-ToolboxPlanLines {
  <#
  .SYNOPSIS
    The window's "What will happen" column: one line per planned step, '{0,2}  {1}' -f <n>, <step title>. Pure.
  .DESCRIPTION
    The plan is Get-StepPlan on the Choices that Start would hand over (ConvertTo-ValidChoices on the model's
    Choices), so the column shows exactly what the run will do. Each title is -Titles[<step id>] (the window passes
    its language's step.<id> names, ruling TB-R5), else the catalog's English Title; without -Titles the lines are
    the catalog's, which is what the console, setup.log and the report show. When those Choices' WindowsUpdate is
    DRIVERS (wu spec 3.1), the windows-update line is -Titles['windows-update.drivers'] when that is not empty,
    else $script:WindowsUpdateDriversTitle ('Windows Update (drivers only)'). Emitted one by one: wrap the call in
    @().
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Model,
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config,
    [AllowNull()][hashtable]$Titles
  )

  $choices = (ConvertTo-ValidChoices -Choices $Model['Choices'] -Config $Config -Machine $Machine).Choices
  $catalogTitles = @{}
  foreach ($step in $script:StepCatalog) { $catalogTitles[$step.Id] = $step.Title }
  $n = 0
  foreach ($id in @(Get-StepPlan -Machine $Machine -Choices $choices -Config $Config)) {
    $n++
    $key = $id
    $title = $catalogTitles[$id]
    if ($id -ceq 'windows-update' -and (Get-WindowsUpdateChoice -Choices $choices) -ceq 'DRIVERS') { $key = 'windows-update.drivers'; $title = $script:WindowsUpdateDriversTitle }
    if ($null -ne $Titles -and -not [string]::IsNullOrEmpty([string]$Titles[$key])) { $title = [string]$Titles[$key] }
    '{0,2}  {1}' -f $n, $title
  }
}
