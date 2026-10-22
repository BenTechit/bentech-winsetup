# src/Report/Report.ps1
# The setup report (spec 8.7): C:\BenTech\Setup\Logs\Setup-Report.txt. Finalize (Finalize.ps1) writes it,
# and R on the final screen opens it. Format-SetupReport is pure. Get-ActivationStatus,
# Get-SmartAppControlState and Get-InstalledAppVersions are the read-only collectors it needs; Finalize
# calls them. Get-InstalledAppVersions also reports the Craft apps (apps.craft.items of the config it is
# given) and reads the per-user Uninstall view, where the ArtCraft Launcher registers. With the same
# Config it reports ScreenConnect by apps.screenconnect.serviceName, and Format-SetupReport shows the
# remote tools (AnyDesk ID, ScreenConnect) by Choices.Remote. With the Config, Format-SetupReport also names
# the run's profile (toolbox spec 5.5); the tweaks and restore point lines come from the State.
# Needs Catalog.ps1 (Get-RemoteChoice, Get-WindowsUpdateChoice) + Verdict.ps1 (Get-StepTitle), StartScreen.ps1
# (ConvertTo-ScreenText, ConvertFrom-StateTime, Format-HoursMinutes), Toolbox\SetupPlanner.ps1 (Get-SetupProfiles,
# Test-ProfileChanged), DefaultBrowser.ps1 (Read-RegistryStringValue), Office.ps1 ($script:OfficeReleaseKey)
# and Logging.ps1; the bundle holds every file.
#
# The report is plain ASCII. Every free-text value (model names, step messages, update titles) goes
# through ConvertTo-ScreenText, which turns anything outside printable ASCII (Hebrew) into '?'. Dates
# are dd/MM/yyyy HH:mm in the invariant culture, so a Hebrew locale cannot change them.

# The Windows licensing application id: the SoftwareLicensingProduct rows of Windows itself, as
# opposed to Office and other products that also license through SPP.
$script:WindowsLicensingApplicationId = '55c92734-d682-4d71-983e-d6ec3f16059f'

# Both machine registry views (a 32-bit installer such as AnyDesk registers under WOW6432Node), then the
# per-user one (an MSI installed for the user only, such as the ArtCraft Launcher, registers under HKCU).
$script:UninstallRegistryKeys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)

# The name the report uses -> the DisplayName pattern of its Uninstall entry.
$script:ReportedUninstallApps = [ordered]@{
  'Google Chrome' = 'Google Chrome*'
  'AnyDesk'       = 'AnyDesk*'
  '7-Zip'         = '7-Zip*'
}
$script:ReportedOfficeName = 'Microsoft 365'

function Get-ActivationStatus {
  <#
  .SYNOPSIS
    Windows activation: 'Activated', 'Not activated' or 'Unknown'. Read-only; never throws.
  .DESCRIPTION
    CIM SoftwareLicensingProduct rows of Windows (ApplicationID 55c92734-...) that hold a product key.
    LicenseStatus 1 (licensed) on any of them is 'Activated'; any other status, or no such row, is
    'Not activated'. A query that fails is 'Unknown' (logged as WARN), never "not activated".
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  try {
    $filter = "ApplicationID='{0}' AND PartialProductKey IS NOT NULL" -f $script:WindowsLicensingApplicationId
    $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop)
    foreach ($product in $products) {
      if ($null -ne $product -and [int]$product.LicenseStatus -eq 1) { return 'Activated' }
    }
    return 'Not activated'
  } catch {
    Write-SetupLog -Message 'Windows activation status could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
    return 'Unknown'
  }
}

function Get-SmartAppControlState {
  <#
  .SYNOPSIS
    Smart App Control: 'Off', 'On', 'Evaluation' or 'Unknown'. Read-only; never throws.
  .DESCRIPTION
    Spec 16 (M8): the report records it. HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy,
    VerifiedAndReputablePolicyState: 0 Off, 1 On, 2 Evaluation. Anything else, a missing value (Windows 10,
    older builds) or a read that fails is 'Unknown'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  try {
    $item = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop
    if ($null -eq $item) { return 'Unknown' }
    $property = $item.PSObject.Properties['VerifiedAndReputablePolicyState']
    if ($null -eq $property) { return 'Unknown' }
    $value = 0
    if (-not [int]::TryParse([string]$property.Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return 'Unknown' }
    switch ($value) {
      0 { return 'Off' }
      1 { return 'On' }
      2 { return 'Evaluation' }
    }
    return 'Unknown'
  } catch {
    Write-SetupLog -Message 'Smart App Control state could not be read' -Data @{ error = $_.Exception.Message }
    return 'Unknown'
  }
}

function Get-InstalledAppVersions {
  <#
  .SYNOPSIS
    The versions of the apps this tool installs, as @{ <name> = <version> }. Read-only; never throws.
  .DESCRIPTION
    Google Chrome, AnyDesk and 7-Zip: DisplayVersion of the first Uninstall entry (64-bit view, then
    the 32-bit WOW6432Node view, then the per-user HKCU view) whose DisplayName matches 'Google Chrome*',
    'AnyDesk*' or '7-Zip*' and that has a version. Microsoft 365: VersionToReport under
    ClickToRun\Configuration. An app that is not found is left out. A registry view that cannot be read
    is a WARN; the rest is still read.

    With Config, the Craft apps too: each item of apps.craft.items is reported under its name, from the
    first Uninstall entry that has a version and whose DisplayName matches (-match, case-insensitive) the
    item's displayName regex. Without Config, or without apps.craft in it, no Craft app is reported.

    With Config, ScreenConnect too: the first Uninstall entry that has a version and whose DisplayName
    equals (case-insensitive, not a pattern) apps.screenconnect.serviceName. Without Config, or without
    that name in it, no ScreenConnect is reported.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Config)

  $craftItems = @()
  if ($null -ne $Config) { $craftItems = @($Config.apps.craft.items | Where-Object { $null -ne $_ -and -not [string]::IsNullOrEmpty([string]$_.name) -and -not [string]::IsNullOrEmpty([string]$_.displayName) }) }

  # ScreenConnect registers its product under the same name as its service (spec 3), with a suffix that
  # belongs to Ben's instance: the name comes from apps.screenconnect.serviceName, so a new suffix is one
  # config edit (spec 4.5). Without Config no ScreenConnect is reported.
  $screenConnectName = ''
  if ($null -ne $Config) { $screenConnectName = [string]$Config.apps.screenconnect.serviceName }

  $versions = @{}
  foreach ($key in $script:UninstallRegistryKeys) {
    try {
      foreach ($entry in @(Get-ItemProperty -Path (Join-Path $key '*') -ErrorAction SilentlyContinue)) {
        if ($null -eq $entry) { continue }
        $nameProperty = $entry.PSObject.Properties['DisplayName']
        $versionProperty = $entry.PSObject.Properties['DisplayVersion']
        if ($null -eq $nameProperty -or $null -eq $versionProperty) { continue }
        $version = ([string]$versionProperty.Value).Trim()
        if ($version -eq '') { continue }
        foreach ($app in $script:ReportedUninstallApps.Keys) {
          if (-not $versions.ContainsKey($app) -and [string]$nameProperty.Value -like $script:ReportedUninstallApps[$app]) {
            $versions[$app] = $version
          }
        }
        foreach ($item in $craftItems) {
          if (-not $versions.ContainsKey([string]$item.name) -and [string]$nameProperty.Value -match [string]$item.displayName) {
            $versions[[string]$item.name] = $version
          }
        }
        if ($screenConnectName -ne '' -and -not $versions.ContainsKey('ScreenConnect') -and [string]$nameProperty.Value -eq $screenConnectName) {
          $versions['ScreenConnect'] = $version
        }
      }
    } catch {
      Write-SetupLog -Message 'Installed programs could not be read' -Level WARN -Data @{ key = $key; error = $_.Exception.Message }
    }
  }

  try {
    $office = Read-RegistryStringValue -Path $script:OfficeReleaseKey -Name 'VersionToReport'
    if (-not [string]::IsNullOrWhiteSpace($office)) { $versions[$script:ReportedOfficeName] = $office.Trim() }
  } catch {
    Write-SetupLog -Message 'The Office version could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
  }
  return $versions
}

function Format-ReportDate {
  # Private. dd/MM/yyyy HH:mm in the invariant culture ('/' stays '/'), or 'unknown'.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$When)

  if ($When -isnot [datetime]) { return 'unknown' }
  return $When.ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-StepDuration {
  # Private. How long a step took: m:ss below an hour (minutes not padded), h:mm:ss from an hour on
  # (ruling R25). A negative span (a clock correction) counts as zero.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][timespan]$Span)

  if ($Span -lt [timespan]::Zero) { $Span = [timespan]::Zero }
  if ($Span.TotalHours -ge 1) {
    return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
  }
  return ('{0}:{1:00}' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Format-SetupReport {
  <#
  .SYNOPSIS
    The setup report as lines of plain ASCII text. Pure.
  .DESCRIPTION
    In order:
      BenTech Windows Setup - Report
      Tool version / Result (the verdict banner) / Started / Finished / Duration (h:mm) / Machine /
      PC name (old -> new) / Mode (chosen, and detected LAPTOP|DESKTOP|VM) / Windows / Activation /
      BitLocker / Smart App Control (Off|On|Evaluation|Unknown; -SmartAppControl, 'Unknown' when not
      given) / AnyDesk ID ('not available' when there is none; 'not chosen' when Choices.Remote is
      SCREENCONNECT) / ScreenConnect / Profile / Tweaks / Restore point / Updates
    Choices.Remote is read with Get-RemoteChoice (a missing or invalid one is ANYDESK; ScreenConnect spec
    4.1). Updates (wu spec 3.3) is 'drivers only (other updates left to Windows)' when Get-WindowsUpdateChoice
    says DRIVERS, else 'full' (a missing or invalid Choices.WindowsUpdate, as in an older state, is FULL). The ScreenConnect line reads 'not chosen' (ANYDESK), 'installed (service running)' (the
    screenconnect step is Done and its Data.Service is Running), 'installed (service not running)' (Done
    with any other service state) or 'not installed' (the step failed or has no entry).
    Toolbox spec 5.5:
      Profile: '<name.en> (<id>)' for a profile of -Config, plus ' (changed)' when Test-ProfileChanged says
        so (spec 10b.6); an id the config does not know (or no -Config) shows the id alone; an empty or
        missing Choices.Profile (an older state) is 'none'.
      Tweaks: from the tweaks step's Data: '<n> applied', then ': <ids>' when n > 0, then
        '  (refused: <ids>)' and '  (skipped, Administrator protection: <ids>)' when those lists are not
        empty. 'none' when the State has no tweaks step; 'not applied' when that step is not Done.
      Restore point: 'created (System Protection is now on and reserves a few percent of the disk)' when
        State.RestorePointCreated; 'not chosen' when Choices.RestorePoint is not $true; else
        'could not be confirmed', followed by ' (System Protection may now be on)' when State.RestorePointTried
        (final review M4): the attempt sets Tried just before its child, whose first command turns System
        Protection on, so the customer is told about the disk space it may reserve. Tried is the one record of
        that (it survives a crash during the child), so the rare attempt that stopped before its child (the state
        could not be saved first) says "may" too. With no attempt (the original frequency value unreadable or
        not a DWORD) the line has no suffix.
    then, each after a blank line:
      Apps:  '  <name> <version>' sorted by name ('  none' when empty)
      Windows Update: <rounds> rounds, <installed> installed, failed repeatedly (left to Windows Update):
             <titles, or ids, or 'none'> (the updates the run hid, un-hidden again at its end)
      Windows updates installed: '  <Round N: KB title>' per Data.InstalledLines of the windows-update
             step, in the order they were installed ('  none' when there are none)
      Steps: '  <Status padded to 8> <Title> - <Message> (<time>)' per plan step. ' - <Message>' is
             left out when there is no message. ' (<time>)' (m:ss, or h:mm:ss from an hour on) is
             added only when the step has both StartedAt and EndedAt (ruling R25). The runner sets
             StartedAt again on every call, so a step that ran in several calls (Windows Update
             rounds, Finalize across its restart) shows the time of its last call.
      Failures: / Notes: from the verdict, each section only when it has entries.
    Dates are dd/MM/yyyy HH:mm; a missing or unreadable time is 'unknown' (and so is the duration).
    Times may be ISO strings (as state.json holds them) or [datetime] (ConvertFrom-StateTime takes both).
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][hashtable]$Verdict,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Activation,
    [Parameter(Mandatory)][AllowEmptyString()][string]$BitLockerText,
    [Parameter(Mandatory)][AllowNull()][hashtable]$AppVersions,
    [AllowNull()][AllowEmptyString()][string]$SmartAppControl = 'Unknown',
    [AllowNull()]$Config
  )

  $machine = if ($State['Machine'] -is [System.Collections.IDictionary]) { $State['Machine'] } else { @{} }
  $choices = if ($State['Choices'] -is [System.Collections.IDictionary]) { $State['Choices'] } else { @{} }
  $steps = if ($State['Steps'] -is [System.Collections.IDictionary]) { $State['Steps'] } else { @{} }

  $started = ConvertFrom-StateTime $State['StartedAt']
  $ended = ConvertFrom-StateTime $State['EndedAt']
  $duration = if ($null -ne $started -and $null -ne $ended) { Format-HoursMinutes ($ended - $started) } else { 'unknown' }
  $detected = if ($machine['IsVM'] -eq $true) { 'VM' } elseif ($machine['IsLaptop'] -eq $true) { 'LAPTOP' } else { 'DESKTOP' }
  # ScreenConnect spec 4.1: Choices.Remote decides (a missing or invalid one is ANYDESK), never the plan list.
  $remote = Get-RemoteChoice -Choices $choices
  $anyDesk = ConvertTo-ScreenText $State['AnyDeskId']
  if ($anyDesk -eq '') { $anyDesk = 'not available' }
  if ($remote -eq 'SCREENCONNECT') { $anyDesk = 'not chosen' }

  $screenConnect = 'not chosen'
  if ($remote -ne 'ANYDESK') {
    $screenConnect = 'not installed'
    $scStep = $steps['screenconnect']
    if ($scStep -is [System.Collections.IDictionary] -and [string]$scStep['Status'] -eq 'Done') {
      $scData = if ($scStep['Data'] -is [System.Collections.IDictionary]) { $scStep['Data'] } else { @{} }
      $screenConnect = if ([string]$scData['Service'] -eq 'Running') { 'installed (service running)' } else { 'installed (service not running)' }
    }
  }

  # Toolbox spec 5.5: the profile, the tweaks and the restore point. Every free text through ConvertTo-ScreenText.
  $profileText = 'none'
  $profileId = [string]$choices['Profile']
  if ($profileId -ne '') {
    $profileText = ConvertTo-ScreenText $profileId
    $known = @(Get-SetupProfiles -Config $Config | Where-Object { $_.Id -ceq $profileId })
    if ($known.Count -gt 0) {
      $profileText = '{0} ({1})' -f (ConvertTo-ScreenText $known[0].Name.en), $known[0].Id
      if (Test-ProfileChanged -Choices $choices -Config $Config -Machine $machine) { $profileText += ' (changed)' }
    }
  }

  $tweaksText = 'none'
  $tweaksStep = $steps['tweaks']
  if ($tweaksStep -is [System.Collections.IDictionary]) {
    $tweaksText = 'not applied'
    if ([string]$tweaksStep['Status'] -eq 'Done') {
      $tweaksData = if ($tweaksStep['Data'] -is [System.Collections.IDictionary]) { $tweaksStep['Data'] } else { @{} }
      $idsOf = { param($list) @(foreach ($item in @($list)) { $text = ConvertTo-ScreenText $item; if ($text -ne '') { $text } }) }
      $appliedIds = @(& $idsOf $tweaksData['Applied'])
      $refusedIds = @(& $idsOf $tweaksData['Refused'])
      $skippedIds = @(& $idsOf $tweaksData['Skipped'])
      $tweaksText = '{0} applied' -f $appliedIds.Count
      if ($appliedIds.Count -gt 0) { $tweaksText += ': ' + ($appliedIds -join ', ') }
      if ($refusedIds.Count -gt 0) { $tweaksText += '  (refused: ' + ($refusedIds -join ', ') + ')' }
      if ($skippedIds.Count -gt 0) { $tweaksText += '  (skipped, Administrator protection: ' + ($skippedIds -join ', ') + ')' }
    }
  }

  $restorePointText = 'could not be confirmed'
  if ($State['RestorePointTried'] -eq $true) { $restorePointText += ' (System Protection may now be on)' }
  if ($State['RestorePointCreated'] -eq $true) { $restorePointText = 'created (System Protection is now on and reserves a few percent of the disk)' }
  elseif (-not (($choices['RestorePoint'] -is [bool]) -and $choices['RestorePoint'])) { $restorePointText = 'not chosen' }

  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add('BenTech Windows Setup - Report')
  $lines.Add('Tool version : ' + (ConvertTo-ScreenText $State['Version']))
  $lines.Add('Result       : ' + (ConvertTo-ScreenText $Verdict['Banner']))
  $lines.Add('Started      : ' + (Format-ReportDate $started))
  $lines.Add('Finished     : ' + (Format-ReportDate $ended))
  $lines.Add('Duration     : ' + $duration)
  $lines.Add(('Machine      : {0} {1}   SN: {2}' -f (ConvertTo-ScreenText $machine['Manufacturer']), (ConvertTo-ScreenText $machine['FriendlyModel']), (ConvertTo-ScreenText $machine['Serial'])))
  $lines.Add(('PC name      : {0} -> {1}' -f (ConvertTo-ScreenText $machine['ComputerName']), (ConvertTo-ScreenText $machine['NewName'])))
  $lines.Add(('Mode         : {0} (detected: {1})' -f (ConvertTo-ScreenText $choices['Mode']), $detected))
  $lines.Add(('Windows      : {0} {1} ({2}) {3}' -f (ConvertTo-ScreenText $machine['OsCaption']), (ConvertTo-ScreenText $machine['OsDisplayVersion']), (ConvertTo-ScreenText $machine['OsBuild']), (ConvertTo-ScreenText $machine['Arch'])))
  $lines.Add('Activation   : ' + (ConvertTo-ScreenText $Activation))
  $lines.Add('BitLocker    : ' + (ConvertTo-ScreenText $BitLockerText))
  $smartAppControlText = ConvertTo-ScreenText $SmartAppControl
  if ($smartAppControlText -eq '') { $smartAppControlText = 'Unknown' }
  $lines.Add('Smart App Control : ' + $smartAppControlText)
  $lines.Add('AnyDesk ID   : ' + $anyDesk)
  $lines.Add('ScreenConnect: ' + $screenConnect)
  $lines.Add('Profile      : ' + $profileText)
  $lines.Add('Tweaks       : ' + $tweaksText)
  $lines.Add('Restore point: ' + $restorePointText)
  # Wu spec 3.3: named "Updates" so it is not mistaken for the "Windows Update: N rounds" line below.
  $lines.Add('Updates      : ' + $(if ((Get-WindowsUpdateChoice -Choices $choices) -eq 'DRIVERS') { 'drivers only (other updates left to Windows)' } else { 'full' }))

  $lines.Add('')
  $lines.Add('Apps:')
  $apps = if ($null -ne $AppVersions) { @($AppVersions.Keys | Sort-Object) } else { @() }
  if ($apps.Count -eq 0) { $lines.Add('  none') }
  foreach ($name in $apps) {
    $lines.Add(('  {0} {1}' -f (ConvertTo-ScreenText $name), (ConvertTo-ScreenText $AppVersions[$name])))
  }

  # The updates the run hid after repeated failures (Finalize un-hides them again, final review C1) are
  # listed by the title the Windows Update step recorded, else by their id.
  $wuStep = $steps['windows-update']
  $wuData = if ($wuStep -is [System.Collections.IDictionary] -and $wuStep['Data'] -is [System.Collections.IDictionary]) { $wuStep['Data'] } else { @{} }
  $titles = if ($wuData['FailedTitles'] -is [System.Collections.IDictionary]) { $wuData['FailedTitles'] } else { @{} }
  $hidden = New-Object 'System.Collections.Generic.List[string]'
  foreach ($id in @($State['HiddenUpdateIds'])) {
    $key = [string]$id
    if ($key -eq '') { continue }
    $title = if ($titles.Contains($key)) { [string]$titles[$key] } else { '' }
    $hidden.Add($(if ([string]::IsNullOrWhiteSpace($title)) { ConvertTo-ScreenText $key } else { ConvertTo-ScreenText $title }))
  }
  $hiddenText = if ($hidden.Count -gt 0) { $hidden.ToArray() -join ', ' } else { 'none' }
  $lines.Add('')
  $lines.Add(('Windows Update: {0} rounds, {1} installed, failed repeatedly (left to Windows Update): {2}' -f [int]$wuData['Rounds'], [int]$wuData['Installed'], $hiddenText))

  # The updates each round installed, one line per update (Data.InstalledLines, written by the Windows
  # Update step); the text is made ASCII here, like every free-text value of the report.
  $lines.Add('')
  $lines.Add('Windows updates installed:')
  $installedLines = @(foreach ($item in @($wuData['InstalledLines'])) { $text = ConvertTo-ScreenText $item; if ($text -ne '') { $text } })
  if ($installedLines.Count -eq 0) { $lines.Add('  none') }
  foreach ($text in $installedLines) { $lines.Add('  ' + $text) }

  $lines.Add('')
  $lines.Add('Steps:')
  foreach ($id in @($State['Plan'])) {
    if ([string]::IsNullOrEmpty($id)) { continue }
    $step = $steps[$id]
    $status = if ($step -is [System.Collections.IDictionary]) { ConvertTo-ScreenText $step['Status'] } else { 'missing' }
    $message = if ($step -is [System.Collections.IDictionary]) { ConvertTo-ScreenText $step['Message'] } else { '' }
    $line = '  {0} {1}' -f $status.PadRight(8), (ConvertTo-ScreenText (Get-StepTitle -Id $id))
    if ($message -ne '') { $line += ' - ' + $message }
    if ($step -is [System.Collections.IDictionary]) {
      $stepStarted = ConvertFrom-StateTime $step['StartedAt']
      $stepEnded = ConvertFrom-StateTime $step['EndedAt']
      if ($null -ne $stepStarted -and $null -ne $stepEnded) { $line += ' (' + (Format-StepDuration -Span ($stepEnded - $stepStarted)) + ')' }
    }
    $lines.Add($line)
  }

  foreach ($section in @(@{ Name = 'Failures'; Items = $Verdict['Failures'] }, @{ Name = 'Notes'; Items = $Verdict['Notes'] })) {
    $texts = @(foreach ($item in @($section.Items)) { $text = ConvertTo-ScreenText $item; if ($text -ne '') { $text } })
    if ($texts.Count -eq 0) { continue }
    $lines.Add('')
    $lines.Add($section.Name + ':')
    foreach ($text in $texts) { $lines.Add('  ' + $text) }
  }

  return $lines.ToArray()
}
