# src/Toolbox/SetupPlanner.ps1
# The BenTech Toolbox's planning rules (toolbox spec 5.2, 10b.5, 10b.6): the profiles of config.json, the
# choices a profile fills in, the check every Choices table passes before a run starts, and whether a run's
# choices still match its profile (the report's "(changed)").
#
# Pure: no logging, no I/O, no console. Values in, values out; the callers log (ConvertTo-ValidChoices returns
# the dropped tweak ids for that). Needs Catalog.ps1 (Get-TweakCatalog, Get-EffectiveTweaks, Get-RemoteChoice,
# $script:RemoteChoices) and StartScreen.ps1 (New-DefaultChoices, $script:OfficeChoices); the bundle holds every
# file.
#
# A profile only fills in the options (spec 5.2): Office, Remote, 7-Zip, the tweak selection and the restore
# point. The Type (laptop or desktop) is never part of a profile: it is detected. Choices keep ASCII ids only, so
# nothing Hebrew reaches state.json or setup.log; the Hebrew names stay in the profile.

function Get-SetupProfiles {
  <#
  .SYNOPSIS
    The valid profiles of Config.profiles, in config order, one hashtable each. Never throws.
  .DESCRIPTION
    Each: @{ Id; Name = @{ en; he }; Office; Remote; SevenZip; RestorePoint; Tweaks = [string[]] }.
    Left out: an id that does not match ^[a-z][a-z0-9-]{0,31}$, an id an earlier profile already has, an empty
    name.en. A bad value is repaired, never a reason to drop the profile:
      - Office is upper-cased; outside $script:OfficeChoices it is defaults.office, or OFF when that is no
        better (nothing gets installed that nobody asked for);
      - Remote goes through Get-RemoteChoice (missing or unknown is ANYDESK);
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

    @{
      Id           = $id
      Name         = @{ en = $nameEn; he = [string]$entry.name.he }
      Office       = $office
      Remote       = (Get-RemoteChoice -Choices @{ Remote = [string]$entry.remote })
      SevenZip     = $(if ($entry.sevenZip -is [bool]) { $entry.sevenZip } else { $defaultSevenZip })
      RestorePoint = $(if ($entry.restorePoint -is [bool]) { $entry.restorePoint } else { $true })
      Tweaks       = [string[]]@(foreach ($tweak in $catalog) { if ($wanted.Contains($tweak.Id)) { $tweak.Id } })
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
    The choices a profile fills in: @{ Profile; Office; Remote; SevenZip; RestorePoint; Tweaks }, or $null for
    an id that names no valid profile. Never throws. Mode is not among them: the Type is detected.
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
      return @{ Profile = $p.Id; Office = $p.Office; Remote = $p.Remote; SevenZip = $p.SevenZip; RestorePoint = $p.RestorePoint; Tweaks = [string[]]@($p.Tweaks) }
    }
  }
  return $null
}

function ConvertTo-ValidChoices {
  <#
  .SYNOPSIS
    Checks every key of a Choices table against the whitelists (spec 5.2). Returns @{ Choices; Dropped }.
  .DESCRIPTION
    Choices is a new table with exactly Mode, Office, Remote, SevenZip, RestorePoint, Profile and Tweaks. A bad
    value takes New-DefaultChoices' value for that key:
      - Mode must be LAPTOP or DESKTOP (upper-cased);
      - Office must be in $script:OfficeChoices (upper-cased);
      - Remote goes through Get-RemoteChoice (missing or unknown is ANYDESK, as every reader decides);
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
    Mode         = $mode
    Office       = $office
    Remote       = (Get-RemoteChoice -Choices $given)
    SevenZip     = $(if ($given['SevenZip'] -is [bool]) { $given['SevenZip'] } else { $defaults.SevenZip })
    RestorePoint = $(if ($given['RestorePoint'] -is [bool]) { $given['RestorePoint'] } else { $defaults.RestorePoint })
    Profile      = $profileId
    Tweaks       = $(if ($given.Contains('Tweaks')) { $given['Tweaks'] } else { $null })
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
    [bool]RestorePoint, or the effective tweak list, the profile's selection being evaluated with the run's Mode
    (so a Desktop that brings NumLock in is no change). Mode never counts: the Type is not part of a profile.
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

  $run = @(Get-EffectiveTweaks -Choices $c -Config $Config -Machine $Machine) -join ','
  $fill = @(Get-EffectiveTweaks -Choices @{ Mode = $c['Mode']; Office = $profileChoices.Office; Tweaks = $profileChoices.Tweaks } -Config $Config -Machine $Machine) -join ','
  return ($run -cne $fill)
}
