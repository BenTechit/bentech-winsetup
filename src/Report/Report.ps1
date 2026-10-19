# src/Report/Report.ps1
# The setup report (spec 8.7): C:\BenTech\Setup\Logs\Setup-Report.txt. Finalize (Finalize.ps1) writes it,
# and R on the final screen opens it. Format-SetupReport is pure. Get-ActivationStatus and
# Get-InstalledAppVersions are the two read-only collectors it needs; Finalize calls them.
# Needs Catalog.ps1 + Verdict.ps1 (Get-StepTitle), StartScreen.ps1 (ConvertTo-ScreenText,
# ConvertFrom-StateTime, Format-HoursMinutes), DefaultBrowser.ps1 (Read-RegistryStringValue),
# Office.ps1 ($script:OfficeReleaseKey) and Logging.ps1; the bundle holds every file.
#
# The report is plain ASCII. Every free-text value (model names, step messages, update titles) goes
# through ConvertTo-ScreenText, which turns anything outside printable ASCII (Hebrew) into '?'. Dates
# are dd/MM/yyyy HH:mm in the invariant culture, so a Hebrew locale cannot change them.

# The Windows licensing application id: the SoftwareLicensingProduct rows of Windows itself, as
# opposed to Office and other products that also license through SPP.
$script:WindowsLicensingApplicationId = '55c92734-d682-4d71-983e-d6ec3f16059f'

# Both registry views: a 32-bit installer (AnyDesk) registers under WOW6432Node.
$script:UninstallRegistryKeys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
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

function Get-InstalledAppVersions {
  <#
  .SYNOPSIS
    The versions of the apps this tool installs, as @{ <name> = <version> }. Read-only; never throws.
  .DESCRIPTION
    Google Chrome, AnyDesk and 7-Zip: DisplayVersion of the first Uninstall entry (64-bit view, then
    the 32-bit WOW6432Node view) whose DisplayName matches 'Google Chrome*', 'AnyDesk*' or '7-Zip*'
    and that has a version. Microsoft 365: VersionToReport under ClickToRun\Configuration. An app that
    is not found is left out. A registry view that cannot be read is a WARN; the rest is still read.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

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
      BitLocker / AnyDesk ID ('not available' when there is none)
    then, each after a blank line:
      Apps:  '  <name> <version>' sorted by name ('  none' when empty)
      Windows Update: <rounds> rounds, <installed> installed, hidden: <titles, or ids, or 'none'>
      Steps: '  <Status padded to 8> <Title> - <Message> (<time>)' per plan step. ' - <Message>' is
             left out when there is no message. ' (<time>)' (m:ss, or h:mm:ss from an hour on) is
             added only when the step has both StartedAt and EndedAt (ruling R25). The runner sets
             StartedAt again on every call, so a step that ran in several calls (Windows Update
             rounds, Finalize across its restart) shows the time of its last call.
      Failures: / Notes: from the verdict, each section only when it has entries.
    Dates are dd/MM/yyyy HH:mm; a missing or unreadable time is 'unknown' (and so is the duration).
    Times may be ISO strings or [datetime] (state.json read back by ConvertFrom-Json).
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][hashtable]$Verdict,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Activation,
    [Parameter(Mandatory)][AllowEmptyString()][string]$BitLockerText,
    [Parameter(Mandatory)][AllowNull()][hashtable]$AppVersions
  )

  $machine = if ($State['Machine'] -is [System.Collections.IDictionary]) { $State['Machine'] } else { @{} }
  $choices = if ($State['Choices'] -is [System.Collections.IDictionary]) { $State['Choices'] } else { @{} }
  $steps = if ($State['Steps'] -is [System.Collections.IDictionary]) { $State['Steps'] } else { @{} }

  $started = ConvertFrom-StateTime $State['StartedAt']
  $ended = ConvertFrom-StateTime $State['EndedAt']
  $duration = if ($null -ne $started -and $null -ne $ended) { Format-HoursMinutes ($ended - $started) } else { 'unknown' }
  $detected = if ($machine['IsVM'] -eq $true) { 'VM' } elseif ($machine['IsLaptop'] -eq $true) { 'LAPTOP' } else { 'DESKTOP' }
  $anyDesk = ConvertTo-ScreenText $State['AnyDeskId']
  if ($anyDesk -eq '') { $anyDesk = 'not available' }

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
  $lines.Add('AnyDesk ID   : ' + $anyDesk)

  $lines.Add('')
  $lines.Add('Apps:')
  $apps = if ($null -ne $AppVersions) { @($AppVersions.Keys | Sort-Object) } else { @() }
  if ($apps.Count -eq 0) { $lines.Add('  none') }
  foreach ($name in $apps) {
    $lines.Add(('  {0} {1}' -f (ConvertTo-ScreenText $name), (ConvertTo-ScreenText $AppVersions[$name])))
  }

  # Hidden updates are listed by the title the Windows Update step recorded, else by their id.
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
  $lines.Add(('Windows Update: {0} rounds, {1} installed, hidden: {2}' -f [int]$wuData['Rounds'], [int]$wuData['Installed'], $hiddenText))

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
