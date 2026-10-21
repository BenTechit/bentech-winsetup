# src/Engine/Catalog.ps1
# The ordered list of setup steps and the rules that pick which of them apply to one machine.
#
# Only the step *names* live here as strings. The Invoke-Step* functions are defined by the files in
# src/Steps/ and are resolved by the runner at call time (the bundle test in Task 17 asserts that
# every Function below exists).

# Defined at file scope on purpose: dot-sourcing this file, or bundling it into one script, makes
# $script:StepCatalog visible to Get-StepPlan, Get-RunVerdict and the runner.
#
# Title is what the verdict and the report print; Short (at most 20 characters) is what the progress
# screen's checklist and NOW line print (v2 spec 4.2).
#
# Microsoft 365 (v2 spec 4.6): office starts setup.exe in the background right after vendor-pass1, so
# every Windows Installer install and every restart a vendor tool forces happen before it; it runs
# alongside Windows Update round 1. office-finish, right after windows-update, collects its result. The
# progress screen folds office-finish into the office line.
#
# Craft apps (craft spec 3.2): the free office suite runs right after 7zip, so its MSI installs come before
# the vendor tools. It replaces office and office-finish: no plan holds both.
#
# Remote access (screenconnect spec 4.2): screenconnect runs right after anydesk. Choices.Remote, read through
# Get-RemoteChoice, picks anydesk (ANYDESK or BOTH), screenconnect (SCREENCONNECT or BOTH) or both.
#
# System tweaks (toolbox spec 5.3): tweaks runs right after desktop-icons, before the first restart, so Explorer
# picks the values up at the next sign-in. It is planned only when Get-EffectiveTweaks (below) names at least one
# tweak: Choices.Tweaks holds the selection, and the catalog's rules (desktopOnly, office365Only, minBuild) decide
# what of it applies to this Type, Office and Windows build. A Choices without Tweaks (an older state) plans none.
$script:StepCatalog = @(
  @{ Id = 'prepare';         Title = 'Prepare machine';                 Short = 'Prepare';              Function = 'Invoke-StepPrepare' }
  @{ Id = 'bitlocker';       Title = 'Turn off BitLocker';              Short = 'BitLocker off';        Function = 'Invoke-StepBitLocker' }
  @{ Id = 'region';          Title = 'Time zone + Hebrew keyboard';     Short = 'Time zone + keyboard'; Function = 'Invoke-StepRegion' }
  @{ Id = 'desktop-icons';   Title = 'Desktop icons';                   Short = 'Desktop icons';        Function = 'Invoke-StepDesktopIcons' }
  @{ Id = 'tweaks';          Title = 'System tweaks';                   Short = 'Tweaks';               Function = 'Invoke-StepTweaks' }
  @{ Id = 'bloatware';       Title = 'Remove bloatware';                Short = 'Remove bloatware';     Function = 'Invoke-StepBloatware' }
  @{ Id = 'rename';          Title = 'Rename PC';                       Short = 'Rename PC';            Function = 'Invoke-StepRename' }
  @{ Id = 'winget';          Title = 'Prepare winget';                  Short = 'winget';               Function = 'Invoke-StepWinget' }
  @{ Id = 'chrome';          Title = 'Google Chrome';                   Short = 'Chrome';               Function = 'Invoke-StepChrome' }
  @{ Id = 'anydesk';         Title = 'AnyDesk';                         Short = 'AnyDesk';              Function = 'Invoke-StepAnyDesk' }
  @{ Id = 'screenconnect';   Title = 'ScreenConnect';                   Short = 'ScreenConnect';        Function = 'Invoke-StepScreenConnect' }
  @{ Id = '7zip';            Title = '7-Zip';                           Short = '7-Zip';                Function = 'Invoke-StepSevenZip' }
  @{ Id = 'craft-apps';      Title = 'Craft apps';                      Short = 'Craft apps';           Function = 'Invoke-StepCraftApps' }
  @{ Id = 'default-browser'; Title = 'Chrome as default browser';       Short = 'Default browser';      Function = 'Invoke-StepDefaultBrowser' }
  @{ Id = 'vendor-pass1';    Title = 'Vendor drivers + BIOS (pass 1)';  Short = 'Drivers (pass 1)';     Function = 'Invoke-StepVendorPass1' }
  @{ Id = 'office';          Title = 'Microsoft 365';                   Short = 'Microsoft 365';        Function = 'Invoke-StepOffice' }
  @{ Id = 'windows-update';  Title = 'Windows Update';                  Short = 'Windows Update';       Function = 'Invoke-StepWindowsUpdate' }
  @{ Id = 'office-finish';   Title = 'Microsoft 365 (finish)';          Short = 'Microsoft 365';        Function = 'Invoke-StepOfficeFinish' }
  @{ Id = 'vendor-pass2';    Title = 'Vendor drivers + BIOS (pass 2)';  Short = 'Drivers (pass 2)';     Function = 'Invoke-StepVendorPass2' }
  @{ Id = 'consumer-app';    Title = 'Vendor app';                      Short = 'Laptop app';           Function = 'Invoke-StepConsumerApp' }
  @{ Id = 'vendor-cleanup';  Title = 'Remove business updater';         Short = 'Remove updater';       Function = 'Invoke-StepVendorCleanup' }
  @{ Id = 'finalize';        Title = 'Finalize';                        Short = 'Finish';               Function = 'Invoke-StepFinalize' }
)

# Brands whose vendor tool (Dell Command | Update, Lenovo System Update, HP Image Assistant) the
# tool runs for drivers + BIOS, and whose pre-installed business updater is removed on laptops.
$script:BusinessUpdaterBrands = @('DELL', 'LENOVO', 'HP')

# The remote-access choices (ScreenConnect spec 4.1), in the order the R key cycles them. ANYDESK is the
# default and what a missing or invalid value means.
$script:RemoteChoices = @('ANYDESK', 'SCREENCONNECT', 'BOTH')

function Get-RemoteChoice {
  <#
  .SYNOPSIS
    The remote-access choice in a Choices table: ANYDESK, SCREENCONNECT or BOTH. Never anything else.
  .DESCRIPTION
    Missing, empty, unknown or null all mean ANYDESK, which is what a run started by a version without
    this choice did (ScreenConnect spec 4.1). The value is matched case-insensitively and returned in
    upper case. Every reader (the start screen, the plan, the final screen and the report) decides
    through this function, never from the plan list, so they cannot disagree. AnyDesk is wanted when the
    result is not SCREENCONNECT; ScreenConnect when it is not ANYDESK. Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Choices)

  if ($Choices -is [System.Collections.IDictionary] -and $Choices.Contains('Remote')) {
    $value = ([string]$Choices['Remote']).ToUpperInvariant()
    if ($script:RemoteChoices -contains $value) { return $value }
  }
  return 'ANYDESK'
}

function Test-HasConsumerApp {
  # True when config.vendors has an entry for this brand and that entry has a consumerApp.
  # Uses PSObject.Properties so a missing brand or a missing consumerApp is $false, not an error
  # (VM, OTHER and SAMSUNG have no vendors entry; ASUS/ACER/MSI/SURFACE have no tool section).
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()]$Config,
    [AllowNull()][AllowEmptyString()][string]$Brand
  )

  if ($null -eq $Config -or [string]::IsNullOrEmpty($Brand)) { return $false }
  $vendors = $Config.PSObject.Properties['vendors']
  if ($null -eq $vendors -or $null -eq $vendors.Value) { return $false }
  $entry = $vendors.Value.PSObject.Properties[$Brand]
  if ($null -eq $entry -or $null -eq $entry.Value) { return $false }
  $consumerApp = $entry.Value.PSObject.Properties['consumerApp']
  return ($null -ne $consumerApp -and $null -ne $consumerApp.Value)
}

function Test-HasDriverTool {
  # True when the vendor tool (Dell Command | Update, Lenovo System Update, HP Image Assistant) runs on
  # this machine: the brand is one of BusinessUpdaterBrands and it is not a virtual machine. Resolve-Brand
  # already reports a VM as 'VM'; checking IsVM too keeps "a VM never gets a vendor step" true even if the
  # two fields ever disagree. The start screen and Get-StepPlan both ask this.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$Machine)

  $brand = [string]$Machine['Brand']
  $isVm = ($brand -eq 'VM') -or ($Machine['IsVM'] -eq $true)
  return ((-not $isVm) -and ($script:BusinessUpdaterBrands -contains $brand))
}

# The registry roots a tweak value may write (toolbox spec 5.3): the setup account (the customer's account),
# the machine, and the sign-in screen's own profile. PowerShell has no HKU: drive, so HKU\.DEFAULT is written
# with the Registry:: provider prefix.
$script:TweakPathPrefixes = @('HKCU:\', 'HKLM:\', 'Registry::HKEY_USERS\.DEFAULT\')

function ConvertTo-TweakValueEntry {
  # Private. One entry of a tweak's "values" as @{ Path; Name; Type; Op; Bit; Value }, or $null when it breaks
  # a rule of toolbox spec 5.3 (see Get-TweakCatalog). Bit is the mask to clear ([long]) for clearBit, else $null.
  # Value is an [int] for a DWord set and a [string] otherwise. Never throws.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $null }
  $path = $Value.path; $name = $Value.name; $type = $Value.type; $op = $Value.op; $data = $Value.value
  if ($path -isnot [string] -or $name -isnot [string] -or $type -isnot [string] -or $op -isnot [string]) { return $null }

  $rooted = $false
  foreach ($prefix in $script:TweakPathPrefixes) { if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $rooted = $true } }
  # No \Policies\ path: a policy makes Settings say "managed by your organization".
  if (-not $rooted -or $path.IndexOf('\Policies\', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $null }
  if (($type -cnotin 'String', 'DWord') -or ($op -cnotin 'set', 'clearBit')) { return $null }
  if ($name -eq '' -and -not ($type -ceq 'String' -and $op -ceq 'set')) { return $null }

  $bit = $null
  if ($op -ceq 'clearBit') {
    # A REG_SZ number: a power-of-two mask up to 0x80000000 (written in decimal: 0x80000000 is a negative
    # [int] in Windows PowerShell 5.1) and a fresh-install value made of decimal digits only.
    $fresh = [uint32]0
    if ($type -cne 'String' -or $data -isnot [string] -or $data -cnotmatch '^[0-9]+\z' -or
        -not [uint32]::TryParse($data, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$fresh)) { return $null }
    $mask = $Value.bit
    if (-not ($mask -is [int] -or $mask -is [long])) { return $null }
    $bit = [long]$mask
    if ($bit -lt 1 -or $bit -gt 2147483648 -or ($bit -band ($bit - 1)) -ne 0) { return $null }
  } elseif ($type -ceq 'DWord') {
    if (-not ($data -is [int] -or $data -is [long]) -or $data -lt 0 -or $data -gt 2147483647) { return $null }
    $data = [int]$data
  } elseif ($data -isnot [string]) {
    return $null
  }
  return @{ Path = $path; Name = $name; Type = $type; Op = $op; Bit = $bit; Value = $data }
}

function ConvertTo-TweakEntry {
  # Private. One config.tweaks entry as Get-TweakCatalog's hashtable, or $null when it breaks a rule. A rule
  # field (desktopOnly, office365Only, minBuild) that is there but cannot be read leaves the entry out too: a
  # tweak whose rules are unknown is never applied (NumLock on a laptop would type digits into the password).
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Entry)

  if ($null -eq $Entry) { return $null }
  $id = $Entry.id
  if ($id -isnot [string] -or $id -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,31}\z') { return $null }
  $titleEn = $Entry.title.en
  if ($titleEn -isnot [string] -or [string]::IsNullOrWhiteSpace($titleEn)) { return $null }

  foreach ($flag in $Entry.desktopOnly, $Entry.office365Only) { if ($null -ne $flag -and $flag -isnot [bool]) { return $null } }
  $minBuild = $Entry.minBuild
  if ($null -eq $minBuild) { $minBuild = 0 }
  if (-not ($minBuild -is [int] -or $minBuild -is [long]) -or $minBuild -lt 0 -or $minBuild -gt [int]::MaxValue) { return $null }

  $values = New-Object System.Collections.Generic.List[hashtable]
  foreach ($v in @($Entry.values)) {
    $value = ConvertTo-TweakValueEntry -Value $v
    if ($null -eq $value) { return $null }
    $values.Add($value)
  }
  if ($values.Count -eq 0) { return $null }

  return @{
    Id            = $id
    Default       = ($Entry.default -is [bool]) -and $Entry.default
    DesktopOnly   = ($Entry.desktopOnly -eq $true)
    Office365Only = ($Entry.office365Only -eq $true)
    MinBuild      = [int]$minBuild
    Icon          = [string]$Entry.icon
    Title         = @{ en = $titleEn; he = [string]$Entry.title.he }
    Description   = @{ en = [string]$Entry.description.en; he = [string]$Entry.description.he }
    Values        = $values.ToArray()
  }
}

function Get-TweakCatalog {
  <#
  .SYNOPSIS
    The valid entries of Config.tweaks (toolbox spec 6.2), one hashtable each, in config order. Never throws.
  .DESCRIPTION
    Each entry: @{ Id; Default; DesktopOnly; Office365Only; MinBuild (0 = none); Icon; Title = @{ en; he };
    Description = @{ en; he }; Values = @( @{ Path; Name; Type = 'String'|'DWord'; Op = 'set'|'clearBit'; Bit; Value } ) }.
    An entry is left out, silently, when (tests\Config.Tests.ps1 proves the shipped entries all pass):
      - its id does not match ^[A-Za-z][A-Za-z0-9]{0,31}$, or an earlier entry has the same id (any case);
      - title.en is empty, or values is empty;
      - a value's path does not start with HKCU:\, HKLM:\ or Registry::HKEY_USERS\.DEFAULT\ (any case), or it
        contains \Policies\;
      - a value's type is not String or DWord, or its op not set or clearBit;
      - a clearBit value is not a String with a power-of-two bit in 1..0x80000000 and a decimal-digit value;
      - a DWord set value is not an integer in 0..0x7FFFFFFF; a String value is not a string (it may be empty);
      - a value's name is not a string, or is empty for anything but a String set (the key's default value);
      - desktopOnly or office365Only is there but not a bool, or minBuild is there but not a whole number.
    No Config, or no tweaks in it, is no catalog. Emitted one by one: wrap the call in @().
  #>
  [CmdletBinding()]
  param([AllowNull()]$Config)

  if ($null -eq $Config) { return }
  $section = $Config.PSObject.Properties['tweaks']
  if ($null -eq $section -or $null -eq $section.Value) { return }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($section.Value)) {
    $tweak = ConvertTo-TweakEntry -Entry $entry
    if ($null -eq $tweak -or -not $seen.Add($tweak.Id)) { continue }
    $tweak
  }
}

function Test-TweakAllowed {
  <#
  .SYNOPSIS
    $true when a Get-TweakCatalog entry may apply to these choices on this machine (toolbox spec 5.3). Pure.
  .DESCRIPTION
    $false when any rule fails:
      - DesktopOnly (NumLock), and Choices.Mode is not DESKTOP;
      - Office365Only (classic Outlook), and Choices.Office (upper-cased) is not BUSINESS or HOME;
      - MinBuild above 0, and Machine.OsBuild is known (above 0) and below it. An unknown build does not
        filter: production always knows it.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][hashtable]$Tweak,
    [AllowNull()]$Choices,
    [AllowNull()]$Machine
  )

  $c = if ($Choices -is [System.Collections.IDictionary]) { $Choices } else { @{} }
  if ($Tweak['DesktopOnly'] -eq $true -and [string]$c['Mode'] -ne 'DESKTOP') { return $false }
  if ($Tweak['Office365Only'] -eq $true -and ([string]$c['Office']).ToUpperInvariant() -notin 'BUSINESS', 'HOME') { return $false }
  $minBuild = [int]$Tweak['MinBuild']
  if ($minBuild -gt 0 -and $Machine -is [System.Collections.IDictionary]) {
    $build = 0
    $null = [int]::TryParse([string]$Machine['OsBuild'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$build)
    if ($build -gt 0 -and $build -lt $minBuild) { return $false }
  }
  return $true
}

function Get-EffectiveTweaks {
  <#
  .SYNOPSIS
    The tweak ids that will run: the catalog entries named in Choices.Tweaks that pass Test-TweakAllowed. Pure.
  .DESCRIPTION
    Ids are matched case-sensitively after a [string] cast; unknown, empty and repeated ids are dropped. The
    result is in catalog order, each id once. Missing or $null Choices, Choices without Tweaks (a state.json from
    before the toolbox), or no catalog give nothing. Idempotent: the result passed back as Choices.Tweaks gives
    itself. Emitted one by one: wrap the call in @().
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()]$Choices,
    [AllowNull()]$Config,
    [AllowNull()]$Machine
  )

  if ($Choices -isnot [System.Collections.IDictionary] -or -not $Choices.Contains('Tweaks') -or $null -eq $Choices['Tweaks']) { return }
  $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($id in @($Choices['Tweaks'])) { if ($null -ne $id) { $null = $wanted.Add([string]$id) } }
  foreach ($tweak in @(Get-TweakCatalog -Config $Config)) {
    if ($wanted.Contains($tweak.Id) -and (Test-TweakAllowed -Tweak $tweak -Choices $Choices -Machine $Machine)) { $tweak.Id }
  }
}

function Get-StepPlan {
  <#
  .SYNOPSIS
    Returns the ids of the steps that apply to this machine, in catalog order.
  .DESCRIPTION
    Vendor passes: DELL/LENOVO/HP only. Vendor app: laptop mode and a configured consumerApp.
    Business-updater cleanup: laptop mode and DELL/LENOVO/HP. A VM never gets a vendor step.
    Choices.Office picks the office suite: CRAFT gives craft-apps and neither office nor office-finish;
    OFF gives none of the three; any other value (BUSINESS, HOME) gives office and office-finish and no
    craft-apps.
    Choices.Remote picks the remote-access tools, read through Get-RemoteChoice (screenconnect spec 4.1):
    anydesk unless it is SCREENCONNECT, screenconnect unless it is ANYDESK. A missing, empty or unknown
    Remote (a run started by an older version) is ANYDESK, which plans exactly what that version did.
    tweaks (toolbox spec 5.3) is planned only when Get-EffectiveTweaks names at least one tweak for these
    Choices on this Machine; Choices without Tweaks (an older state) plan exactly what that version did.
    The mode comes from Choices (what the technician picked), never from Machine.IsLaptop.
    The ids are emitted one by one, the normal PowerShell way, so `foreach`, the pipeline, `@(...)` and
    a `[string[]]` parameter such as New-RunState -Plan all see every id. A real plan always has at
    least 12 steps, so the single-element unrolling case cannot happen; the result is never wrapped
    with the comma operator.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)][hashtable]$Choices,
    [Parameter(Mandatory)]$Config
  )

  $brand = [string]$Machine['Brand']
  $isVm = ($brand -eq 'VM') -or ($Machine['IsVM'] -eq $true)
  $isLaptopMode = ($Choices['Mode'] -eq 'LAPTOP')
  $hasBusinessTool = Test-HasDriverTool -Machine $Machine
  $hasConsumerApp = (-not $isVm) -and (Test-HasConsumerApp -Config $Config -Brand $brand)

  $plan = New-Object System.Collections.Generic.List[string]
  foreach ($step in $script:StepCatalog) {
    $include = switch ($step.Id) {
      'vendor-pass1'   { $hasBusinessTool }
      'vendor-pass2'   { $hasBusinessTool }
      'consumer-app'   { $isLaptopMode -and $hasConsumerApp }
      'vendor-cleanup' { $isLaptopMode -and $hasBusinessTool }
      '7zip'           { [bool]$Choices['SevenZip'] }
      'craft-apps'     { $Choices['Office'] -eq 'CRAFT' }
      'office'         { $Choices['Office'] -notin 'OFF', 'CRAFT' }
      'office-finish'  { $Choices['Office'] -notin 'OFF', 'CRAFT' }
      'anydesk'        { (Get-RemoteChoice -Choices $Choices) -ne 'SCREENCONNECT' }
      'screenconnect'  { (Get-RemoteChoice -Choices $Choices) -ne 'ANYDESK' }
      'tweaks'         { @(Get-EffectiveTweaks -Choices $Choices -Config $Config -Machine $Machine).Count -gt 0 }
      default          { $true }
    }
    if ($include) { $plan.Add($step.Id) }
  }

  return $plan.ToArray()
}
