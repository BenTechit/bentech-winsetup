# src/Repair/ToolReport.ps1
# Repair & diagnostics, the Quick and Full reports (repair spec 6.8; repair Task 8): the flags, the event grouping, the
# AI-ready core and its size limit, the data JSON, raw_<stamp>\ and the zip. The sections themselves are collected by
# ToolCollect.ps1 into $Run.Data.Report ('01' ... '12').
#
# The report (New-ToolReport, the input of everything here; pure functions take it as a hashtable):
#   @{ Version = 1; Kind = 'quick'|'full'; CreatedAt (the run's start, local 'yyyy-MM-ddTHH:mm:ss'); ToolVersion;
#      Identity (the args' Identity: Key, FolderPart, Serial, BiosUuid, ComputerName, Manufacturer, Model, Brand);
#      Complaint (as typed); Done (the visit's earlier actions: Action, Outcome, Color, EndedAt);
#      Sections = [ordered] '<NN>' -> @{ Id; Title; Facts = [ordered] name -> value; Groups = [string[]]; Items; Raw = [string[]];
#                                        Missing = @( @{ What; Why } ) };
#      Items (every section's Items in one table: the names are unique); Findings (Get-ReportFlags) }
# Items that hold personal values, for the privacy-safe copy (Task 9 masks the parsed values, never the JSON text;
# review M3; ToolPrivacy.ps1's Get-ReportIdentifiers reads them):
#   01 ComputerName, Serial, BiosUuid, Domain (a domain PC only), Workgroup; 02 BoardSerial, RamSerials, MonitorSerials,
#      BatterySerials; 03 Disks[].Serial;
#   06 ProblemDevices[] (Id: a USB instance ID holds the device's serial; Name: a Bluetooth name may hold its owner's);
#   09 Adapters[] (Mac, Addresses, Gateways, Dns), CurrentAddresses, Gateways, DnsServers, Ssids, NetworkProfiles[].Name,
#      UserProxy;
#   10 SignedInUser, SignedInSid, OneDriveEmails, Programs, Tasks[] (Name and Execute: OneDrive's and Google Update's
#      task names hold the user's SID, a program a profile path), Startup[].Program, Services[].Program;
#   11 Users, Admins[].Name, Admins[].Sid, Profiles, SignedInUser, SignedInSid.
# Free text that can hold them too, in Groups and Facts: event and reliability messages (DOMAIN\user, SIDs, profile
# paths, MACs, SSIDs, host names), volume labels (03), device names (06), hosts lines (09), printer names and ports
# (10), and the complaint.
#
# The rules (repair plan, Global Constraints; spec 6.8, 10):
#   - the core and every file Ben reads on the stick are UTF-8 and may hold Hebrew (event messages, program names, the
#     complaint): the core with a BOM (Notepad shows Hebrew right), the data JSON as plain UTF-8 (ruling RD-R23);
#   - headings, fact names and flags are English and ASCII; a flag's arguments go through ConvertTo-ScreenText;
#   - dates are dd/MM/yyyy HH:mm (Format-ReportDate, the invariant culture: a Hebrew calendar changes nothing);
#   - the core stays under repair.reportMaxKB (150 KB): grouped lines are cut, largest section first, never the
#     header, the summary, the facts or the findings; the uncut text goes to raw_<stamp>\report-full.txt;
#   - nothing on the stick is written through a link (V2-R13); result.json holds the findings and the paths only
#     (the sections stay in the child: $script:ToolResultHiddenData, ruling RD-R21).
# Task 9: reportWrite also writes the privacy-safe copy REPORT_SAFE_<stamp>.txt (ToolPrivacy.ps1: the core through one
# masker; no PC name in its file name, ruling RD-R4) and, when the stick holds an earlier report of this PC, puts the
# SINCE LAST VISIT section (ToolCompare.ps1) right after section 00.
#
# Needs ToolEngine (Add-ToolFinding, Add-ToolLog, Get-ToolText, Write-ToolJsonFile, Format-ToolTime,
# ConvertTo-ToolDisplayText, Invoke-ToolJsonChild, Get-ToolRemainingSeconds), ToolCollect (New-ReportSection,
# ConvertTo-ReportReason, $script:ReportSectionTitles), ToolSafety (Get-ToolRepairNumber), Report (Format-ReportDate),
# Activity (Read-FileTail), Winget (ConvertTo-PowerShellLiteral), Cleanup (Test-StickReparsePoint), ToolCompare
# (Get-ToolRunSinceLastVisit), ToolPrivacy (Save-ToolSafeCopy), Logging and StartScreen (ConvertTo-ScreenText). The
# bundle holds every file.

# The facts of section 00, in order: '<section>|<fact name>' (a fact a section did not collect is left out).
$script:ReportSummaryFacts = @(
  '01|Windows', '01|Build', '01|Model', '01|Serial', '01|Uptime', '01|Activation', '02|CPU', '02|RAM', '02|Battery', '03|System disk',
  '03|Free space', '09|Internet', '11|Antivirus')

# Disk events that count (spec 5): disk 7, 51 and 153, NTFS 55 (under either provider name), as '<provider>/<id>'.
$script:ReportDiskEventIds = @('disk/7', 'disk/51', 'disk/153', 'Ntfs/55', 'Microsoft-Windows-Ntfs/55')
# WHEA (review I-10): fatal by ID or a Critical/Error level, corrected by ID (a WARN, never red).
$script:ReportWheaFatalIds = @(1, 18, 20, 46)
$script:ReportWheaCorrectedIds = @(17, 19, 47)

# The English lines Read-ToolLogErrors keeps from CBS.log and dism.log (always English).
$script:ReportLogErrorPatterns = @(', Error', 'HRESULT = 0x8', '[SR] Cannot repair')

# The fixed paragraph at the end of the core, for the AI (Plan call, review 4.7).
$script:ReportHowToUse = @(
  'This is a BenTech Toolbox report of one Windows PC, written to be pasted into an AI chat. Read the CUSTOMER'
  'COMPLAINT first: it is the reason for the visit. THIS VISIT lists what the technician already ran today; do not'
  'suggest it again unless it failed. Section 00 sums the PC up and lists every finding, CRIT before WARN before INFO,'
  'with the section that holds its evidence. Each section gives its facts (name = value), its findings, then its'
  'details, grouped and counted: "3x Provider/ID [level] first - last  message" is one kind of event seen three times'
  '(levels: 1 critical, 2 error, 3 warning, 4 information). Dates are dd/MM/yyyy HH:mm, local time. Event messages'
  'and program names may be in Hebrew: they are Windows'' own text. "Not collected" means a source failed or ran out'
  'of time: that is no evidence either way. When a section says lines were cut, ask for the named raw file.')

# --- Text ----------------------------------------------------------------------------------------------------------

# A report value keeps its real (Hebrew) text through ConvertTo-ToolDisplayText (ToolEngine: direction marks dropped,
# control characters as spaces, a surrogate-safe cut; review M11). A message whose white space should collapse (an
# event's, a log line's) is collapsed first ([regex]::Replace(..., '\s+', ' ')).

function Get-ReportEntry {
  # Private. -Name of -From: a dictionary's key or an object's property; $null when there is none.
  [CmdletBinding()]
  param([AllowNull()]$From, [Parameter(Mandatory)][string]$Name)

  if ($null -eq $From) { return $null }
  if ($From -is [System.Collections.IDictionary]) {
    if ($From.Contains($Name)) { return $From[$Name] }
    return $null
  }
  $property = $From.PSObject.Properties[$Name]
  if ($null -ne $property) { return $property.Value }
  return $null
}

function ConvertTo-ReportNumber {
  # Private, pure. A number (or numeric text, invariant) as a [double]; $null for $null, '' or anything else.
  [CmdletBinding()]
  param([AllowNull()]$Value)

  if ($null -eq $Value -or $Value -is [bool]) { return $null }
  $number = 0.0
  if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
  return $null
}

function Format-ReportNumber {
  # Private, pure. -Value formatted with -Format in the invariant culture ('' for $null).
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Value, [string]$Format = '0.#')

  $number = ConvertTo-ReportNumber -Value $Value
  if ($null -eq $number) { return '' }
  return $number.ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-ReportDateTime {
  # Private, pure. A [datetime], or a 'yyyy-MM-ddTHH:mm:ss' / round-trip text (invariant), as a [datetime]; else $null.
  [CmdletBinding()]
  param([AllowNull()]$Value)

  if ($Value -is [datetime]) { return $Value }
  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
  $parsed = [datetime]::MinValue
  $formats = [string[]]@('yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ss.FFFFFFF', 'o', 'yyyy-MM-dd')
  if ([datetime]::TryParseExact($Value.Trim(), $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
  return $null
}

function ConvertTo-ReportList {
  # Private. -Value's items, one by one (callers wrap the call in @()): $null none, a string or a dictionary itself, a
  # list its items.
  [CmdletBinding()]
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return }
  if ($Value -is [string] -or $Value -is [System.Collections.IDictionary] -or $Value -isnot [System.Collections.IEnumerable]) { return $Value }
  foreach ($v in $Value) { $v }
}

# --- Event groups --------------------------------------------------------------------------------------------------

function ConvertTo-EventGroups {
  <#
  .SYNOPSIS
    Events grouped by provider + ID + level, newest group first, as lines
    '<count>x <provider>/<id> [<level>] <first> - <last>  <message>' (dates dd/MM/yyyy HH:mm; the newest event's
    message, white space collapsed, cut to 200 characters). Pure.
  .DESCRIPTION
    An event is a dictionary or an object with Provider (or ProviderName), Id, Level, Time (or TimeCreated) and
    Message; a row that is already a group (the events grandchild groups in its own process) has Count, First and
    Last instead of Time, and is merged with the others of its key. Groups are ordered by their last event, newest
    first, then by count.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param([AllowNull()][AllowEmptyCollection()][object[]]$Events)

  $groups = @{}
  foreach ($e in @($Events)) {
    if ($null -eq $e) { continue }
    $provider = [string](Get-ReportEntry -From $e -Name 'Provider')
    if ($provider -eq '') { $provider = [string](Get-ReportEntry -From $e -Name 'ProviderName') }
    $id = [string](Get-ReportEntry -From $e -Name 'Id')
    $level = [string](Get-ReportEntry -From $e -Name 'Level')
    $count = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $e -Name 'Count')
    if ($null -eq $count -or $count -lt 1) { $count = 1 }
    $time = Get-ReportEntry -From $e -Name 'Time'
    if ($null -eq $time) { $time = Get-ReportEntry -From $e -Name 'TimeCreated' }
    $first = ConvertTo-ReportDateTime -Value (Get-ReportEntry -From $e -Name 'First')
    $last = ConvertTo-ReportDateTime -Value (Get-ReportEntry -From $e -Name 'Last')
    if ($null -eq $first) { $first = ConvertTo-ReportDateTime -Value $time }
    if ($null -eq $last) { $last = ConvertTo-ReportDateTime -Value $time }
    $message = [string](Get-ReportEntry -From $e -Name 'Message')
    $key = '{0}|{1}|{2}' -f $provider, $id, $level
    $g = $groups[$key]
    if ($null -eq $g) {
      $g = @{ Key = $key; Provider = $provider; Id = $id; Level = $level; Count = 0; First = $first; Last = $last; Message = $message; MessageAt = $last }
      $groups[$key] = $g
    }
    $g.Count += [long]$count
    if ($null -ne $first -and ($null -eq $g.First -or $first -lt $g.First)) { $g.First = $first }
    if ($null -ne $last -and ($null -eq $g.Last -or $last -gt $g.Last)) { $g.Last = $last }
    $newer = ($null -ne $last -and ($null -eq $g.MessageAt -or $last -gt $g.MessageAt))
    if (($newer -and $message.Trim() -ne '') -or ($g.Message.Trim() -eq '' -and $message.Trim() -ne '')) {
      $g.Message = $message
      $g.MessageAt = $last
    }
  }
  $sorted = @($groups.Values | Sort-Object -Property @{ Expression = { if ($null -eq $_.Last) { [datetime]::MinValue } else { $_.Last } }; Descending = $true },
                                                   @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Key }; Descending = $false })
  foreach ($g in $sorted) {
    ('{0}x {1}/{2} [{3}] {4} - {5}  {6}' -f $g.Count, (ConvertTo-ToolDisplayText -Text $g.Provider -MaxLength 100), $g.Id, $g.Level,
      (Format-ReportDate -When $g.First), (Format-ReportDate -When $g.Last), (ConvertTo-ToolDisplayText -Text ([regex]::Replace([string]$g.Message, '\s+', ' ')) -MaxLength 200)).TrimEnd()
  }
}

# --- Flags ---------------------------------------------------------------------------------------------------------

function Add-ReportFlag {
  # Private. Adds one finding to -List: @{ Code; Level; Args (ASCII text); Section; Text (the English finding.<Code>) }.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
    [Parameter(Mandatory)][string]$Code,
    [Parameter(Mandatory)][ValidateSet('CRIT', 'WARN', 'INFO')][string]$Level,
    [Parameter(Mandatory)][string]$Section,
    [AllowNull()][object[]]$Arguments
  )

  $values = [string[]]@()
  if ($null -ne $Arguments) { $values = [string[]]@(foreach ($a in $Arguments) { ConvertTo-ScreenText -Text $a }) }
  $List.Add([ordered]@{ Code = $Code; Level = $Level; Args = $values; Section = $Section; Text = (Get-ToolText -Key ('finding.' + $Code) -Arguments $values) })
}

function Format-ReportShortList {
  # Private, pure. Up to -Max texts joined with ', ', then ' and <n> more' (ASCII).
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][object[]]$Values, [int]$Max = 5)

  $all = @(foreach ($v in @($Values)) { if ($null -ne $v -and [string]$v -ne '') { ConvertTo-ScreenText -Text $v } })
  $text = (@($all | Select-Object -First $Max) -join ', ')
  if ($all.Count -gt $Max) { $text += ' and {0} more' -f ($all.Count - $Max) }
  return $text
}

function ConvertTo-ReportBugcheck {
  # Private, pure. A bugcheck code (decimal, or text starting 0x...) as '0x' and at least 8 upper-case hex digits;
  # '' when it is none or 0.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return '' }
  $text = ([string]$Value).Trim()
  $number = [uint64]0
  $hex = [regex]::Match($text, '^0[xX]([0-9A-Fa-f]{1,16})')
  if ($hex.Success) {
    if (-not [uint64]::TryParse($hex.Groups[1].Value, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return '' }
  } elseif (-not [uint64]::TryParse($text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
    return ''
  }
  if ($number -eq 0) { return '' }
  return ('0x{0:X8}' -f $number)
}

function Get-ReportFlags {
  <#
  .SYNOPSIS
    The report's findings from its Items and the thresholds of -Config (repair.thresholds, repair.freeSpace): every Task 8
    finding of the plan's table, the Health check's codes the sections reproduce (volumeState*, volumeDirty, winre*,
    notActivated, devicesProblem, oemLeftover, trimOff, pageFile*), clockWrong and captivePortal (RD-R13, RD-R20), and
    one notCollected per Missing source. Each names its section. CRIT before WARN before INFO, then by section. Pure.
  .DESCRIPTION
    The thresholds: kernelPower at kernelPowerWarn or more (power losses: the Kernel-Power 41 events whose
    BugcheckCode is 0 or absent; a 41 that carries a code was a blue screen), appCrashes at appCrashesWarn, lowRam under
    ramMinGB, ghostDevicesMany above ghostDevicesInfo, uptimeLong above uptimeDays, batteryWear at batteryWearPercent,
    defenderSignatureOld above defenderSignatureDays, clockWrong above clockOffsetMinutes, diskWear at
    diskWearPercent, diskTemp at diskTemperatureC, lowSpace under freeSpace.minPercent % or minGB GB. A clock that
    breaks HTTPS (the Internet item's Clock, ruling RD-R20) is clockWrong, never noInternet. clockWrong is the report's
    own code (review M2): a report syncs nothing, and Task 6's clockOff means "still off after the time sync".
    A count whose Item is in Items.CappedCounts (its query read its Max events) is a lower bound: '<n>+' (review M6).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Report,
    [AllowNull()]$Config
  )

  $items = Get-ReportEntry -From $Report -Name 'Items'
  if ($null -eq $items) { $items = @{} }
  $flags = New-Object System.Collections.Generic.List[object]
  $limit = { param($name, $default) Get-ToolRepairNumber -Config $Config -Path 'thresholds', $name -Default $default }
  $crashDays = [int](& $limit 'crashDays' 60)
  $item = { param($name) Get-ReportEntry -From $items -Name $name }
  $number = { param($name) ConvertTo-ReportNumber -Value (Get-ReportEntry -From $items -Name $name) }
  $cappedItems = @(foreach ($c in (ConvertTo-ReportList -Value (Get-ReportEntry -From $items -Name 'CappedCounts'))) { [string]$c })
  # A count as text, '<n>+' when the Item's query stopped at its Max (review M6).
  $countText = { param($value, $name) $text = Format-ReportNumber -Value $value -Format '0'; if ($cappedItems -contains $name) { $text + '+' } else { $text } }

  # 01 System
  $build = & $number 'OsBuild'
  if ($null -ne $build -and $build -gt 0 -and $build -lt 22000) {
    $text = [string](& $item 'OsBuildText')
    if ($text -eq '') { $text = Format-ReportNumber -Value $build -Format '0' }
    Add-ReportFlag -List $flags -Code 'windows10' -Level WARN -Section '01' -Arguments @($text)
  }
  $uptime = & $number 'UptimeDays'
  if ($null -ne $uptime -and $uptime -gt (& $limit 'uptimeDays' 7)) { Add-ReportFlag -List $flags -Code 'uptimeLong' -Level INFO -Section '01' -Arguments @([math]::Floor($uptime)) }
  $clock = & $number 'ClockOffsetMinutes'
  if ($null -ne $clock -and [math]::Abs($clock) -gt (& $limit 'clockOffsetMinutes' 2)) {
    Add-ReportFlag -List $flags -Code 'clockWrong' -Level WARN -Section '01' -Arguments @(Format-ReportNumber -Value ([math]::Abs($clock)) -Format '0.0')
  }
  if ([string](& $item 'Activation') -ceq 'Not activated') { Add-ReportFlag -List $flags -Code 'notActivated' -Level WARN -Section '01' }

  # 02 Hardware
  $ram = & $number 'RamGB'
  if ($null -ne $ram -and $ram -gt 0 -and $ram -lt (& $limit 'ramMinGB' 8)) { Add-ReportFlag -List $flags -Code 'lowRam' -Level WARN -Section '02' -Arguments @(Format-ReportNumber -Value $ram) }
  $battery = & $number 'BatteryWear'
  if ($null -ne $battery -and $battery -ge (& $limit 'batteryWearPercent' 40)) { Add-ReportFlag -List $flags -Code 'batteryWear' -Level WARN -Section '02' -Arguments @(Format-ReportNumber -Value $battery -Format '0') }
  if ((& $item 'BasicDisplay') -eq $true) { Add-ReportFlag -List $flags -Code 'basicDisplay' -Level WARN -Section '02' }
  if ([string](& $item 'SecureBoot') -cin 'Off', 'Unsupported') { Add-ReportFlag -List $flags -Code 'secureBootOff' -Level INFO -Section '02' }
  if ((& $item 'TpmReady') -eq $false) { Add-ReportFlag -List $flags -Code 'tpmMissing' -Level INFO -Section '02' }

  # 03 Storage (the system disk, ruling RD-R10; other disks are listed only)
  $diskName = ConvertTo-ScreenText -Text (& $item 'SystemDisk')
  if ($diskName -eq '') { $diskName = 'system disk' }
  $health = [string](& $item 'DiskHealth')
  if ($health -cin 'Warning', 'Unhealthy') { Add-ReportFlag -List $flags -Code 'diskUnhealthy' -Level CRIT -Section '03' -Arguments @($diskName, $health) }
  $errors = & $number 'DiskErrors'
  if ($null -ne $errors -and $errors -gt 0) { Add-ReportFlag -List $flags -Code 'diskErrors' -Level CRIT -Section '03' -Arguments @($diskName, (Format-ReportNumber -Value $errors -Format '0')) }
  $wear = & $number 'Wear'
  if ($null -ne $wear -and $wear -ge (& $limit 'diskWearPercent' 80)) { Add-ReportFlag -List $flags -Code 'diskWear' -Level WARN -Section '03' -Arguments @($diskName, (Format-ReportNumber -Value $wear -Format '0')) }
  $heat = & $number 'Temperature'
  if ($null -ne $heat -and $heat -ge (& $limit 'diskTemperatureC' 60)) { Add-ReportFlag -List $flags -Code 'diskTemp' -Level WARN -Section '03' -Arguments @($diskName, (Format-ReportNumber -Value $heat -Format '0')) }
  $listed = @(foreach ($id in (ConvertTo-ReportList -Value (& $item 'DiskEvents'))) {
      foreach ($known in $script:ReportDiskEventIds) { if ([string]::Equals([string]$id, $known, [StringComparison]::OrdinalIgnoreCase)) { [string]$id } } })
  if ($listed.Count -gt 0) {
    Add-ReportFlag -List $flags -Code 'diskEvents' -Level CRIT -Section '03' -Arguments @([int](& $limit 'diskEventDays' 30), (@($listed | Sort-Object -Unique) -join ', '))
  }
  $freeGB = & $number 'FreeGB'
  $freePercent = & $number 'FreePercent'
  if ($null -ne $freeGB -and $null -ne $freePercent) {
    $minPercent = Get-ToolRepairNumber -Config $Config -Path 'freeSpace', 'minPercent' -Default 10
    $minGB = Get-ToolRepairNumber -Config $Config -Path 'freeSpace', 'minGB' -Default 15
    if ($freeGB -lt $minGB -or $freePercent -lt $minPercent) {
      $drive = [string](& $item 'SystemDrive')
      if ($drive -eq '') { $drive = 'C:' }
      Add-ReportFlag -List $flags -Code 'lowSpace' -Level WARN -Section '03' -Arguments @($drive, (Format-ReportNumber -Value $freeGB -Format '0.0'), (Format-ReportNumber -Value $freePercent -Format '0'))
    }
  }
  switch -CaseSensitive ([string](& $item 'VolumeState')) {
    'SpotFixNeeded' { Add-ReportFlag -List $flags -Code 'volumeStateSpotFix' -Level CRIT -Section '03' }
    'FullRepairNeeded' { Add-ReportFlag -List $flags -Code 'volumeStateFullRepair' -Level CRIT -Section '03' }
    'ScanNeeded' { Add-ReportFlag -List $flags -Code 'volumeStateScan' -Level WARN -Section '03' }
    'Unknown' { Add-ReportFlag -List $flags -Code 'volumeStateUnknown' -Level WARN -Section '03' -Arguments @([string](& $item 'VolumeStateError')) }
  }
  if ((& $item 'Dirty') -eq $true) { Add-ReportFlag -List $flags -Code 'volumeDirty' -Level WARN -Section '03' }
  $trim = [string](& $item 'TrimDisabled')
  if ($trim -ne '' -and $trim -ne '0') { Add-ReportFlag -List $flags -Code 'trimOff' -Level WARN -Section '03' -Arguments @($trim) }
  $bitLocker = & $item 'BitLocker'
  if ($null -ne $bitLocker) {
    $protection = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $bitLocker -Name 'ProtectionStatus')
    $conversion = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $bitLocker -Name 'ConversionStatus')
    if ($protection -eq 1 -or ($null -ne $conversion -and $conversion -ne 0)) { Add-ReportFlag -List $flags -Code 'bitlockerOn' -Level INFO -Section '03' }
  }
  $pageFile = & $item 'PageFile'
  if ($null -ne $pageFile) {
    $problem = [string](Get-ReportEntry -From $pageFile -Name 'Error')
    $missing = @(ConvertTo-ReportList -Value (Get-ReportEntry -From $pageFile -Name 'MissingDrives'))
    if ($problem -ne '') { Add-ReportFlag -List $flags -Code 'pageFileUnknown' -Level WARN -Section '03' -Arguments @($problem) }
    elseif ($missing.Count -gt 0) { Add-ReportFlag -List $flags -Code 'pageFileMissingDrive' -Level WARN -Section '03' -Arguments @($missing -join ', ') }
  }

  # 04 Boot and recovery (the BCD decides; ReAgent.xml supports: Resolve-WinReVerdict)
  $winRe = & $item 'WinRe'
  if ($null -ne $winRe) {
    $reason = [string](Get-ReportEntry -From $winRe -Name 'Error')
    if ($reason -eq '') { $reason = 'no result' }
    if ([string](Get-ReportEntry -From $winRe -Name 'Bcd') -ceq 'Unknown') { Add-ReportFlag -List $flags -Code 'winreUnreadable' -Level WARN -Section '04' -Arguments @($reason) }
    elseif ([string](Get-ReportEntry -From $winRe -Name 'Verdict') -ceq 'Off') { Add-ReportFlag -List $flags -Code 'winreOff' -Level WARN -Section '04' }
    elseif ([string](Get-ReportEntry -From $winRe -Name 'Verdict') -ceq 'Unknown') { Add-ReportFlag -List $flags -Code 'winreUnknown' -Level WARN -Section '04' }
  }
  if ($null -ne (& $item 'SafeBoot')) { Add-ReportFlag -List $flags -Code 'safeBootSet' -Level WARN -Section '04' }

  # 05 Windows Update
  $wuauserv = Get-ReportEntry -From (& $item 'WuServices') -Name 'wuauserv'
  if ([string](Get-ReportEntry -From $wuauserv -Name 'StartType') -ceq 'Disabled') { Add-ReportFlag -List $flags -Code 'wuDisabled' -Level WARN -Section '05' }

  # 06 Drivers and devices (a disabled device, CM 22, is never a problem: review I-10)
  $problems = & $number 'DevicesProblem'
  if ($null -ne $problems -and $problems -gt 0) {
    $codes = @(foreach ($c in (ConvertTo-ReportList -Value (& $item 'ProblemCodes'))) { [string]$c }) | Sort-Object -Unique
    Add-ReportFlag -List $flags -Code 'devicesProblem' -Level WARN -Section '06' -Arguments @((Format-ReportNumber -Value $problems -Format '0'), (@($codes) -join ', '))
  }
  $ghosts = & $number 'GhostCount'
  if ($null -ne $ghosts -and $ghosts -gt (& $limit 'ghostDevicesInfo' 150)) { Add-ReportFlag -List $flags -Code 'ghostDevicesMany' -Level INFO -Section '06' -Arguments @(Format-ReportNumber -Value $ghosts -Format '0') }

  # 07 Events and crashes
  $rows41 = @(ConvertTo-ReportList -Value (& $item 'KernelPower41Events'))
  $total41 = & $number 'KernelPower41'
  if ($null -eq $total41 -or $total41 -lt $rows41.Count) { $total41 = $rows41.Count }
  $blue41 = @(foreach ($r in $rows41) { $code = ConvertTo-ReportBugcheck -Value (Get-ReportEntry -From $r -Name 'BugcheckCode'); if ($code -ne '') { $code } })
  $powerLosses = $total41 - $blue41.Count
  if ($powerLosses -ge (& $limit 'kernelPowerWarn' 3)) { Add-ReportFlag -List $flags -Code 'kernelPower' -Level WARN -Section '07' -Arguments @((& $countText $powerLosses 'KernelPower41'), $crashDays) }
  $blue = @(foreach ($r in (ConvertTo-ReportList -Value (& $item 'BugChecks'))) { $code = ConvertTo-ReportBugcheck -Value (Get-ReportEntry -From $r -Name 'Code'); if ($code -eq '') { 'unknown' } else { $code } })
  if ($blue.Count -eq 0) { $blue = $blue41 }
  if ($blue.Count -gt 0) {
    $byCode = @($blue | Group-Object | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
        ForEach-Object { if ($_.Count -gt 1) { '{0} x{1}' -f $_.Name, $_.Count } else { $_.Name } })
    Add-ReportFlag -List $flags -Code 'bugchecks' -Level CRIT -Section '07' -Arguments @((& $countText $blue.Count 'BugChecks'), $crashDays, ($byCode -join ', '))
  }
  $fatal = 0
  $corrected = 0
  foreach ($w in (ConvertTo-ReportList -Value (& $item 'Whea'))) {
    $id = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $w -Name 'Id')
    $level = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $w -Name 'Level')
    if (($null -ne $id -and $script:ReportWheaFatalIds -contains [int]$id) -or ($null -ne $level -and $level -ge 1 -and $level -le 2)) { $fatal++ }
    elseif ($null -ne $id -and $script:ReportWheaCorrectedIds -contains [int]$id) { $corrected++ }
  }
  if ($fatal -gt 0) { Add-ReportFlag -List $flags -Code 'wheaFatal' -Level CRIT -Section '07' -Arguments @((& $countText $fatal 'Whea'), $crashDays) }
  if ($corrected -gt 0) { Add-ReportFlag -List $flags -Code 'wheaCorrected' -Level WARN -Section '07' -Arguments @((& $countText $corrected 'Whea'), $crashDays) }
  $dumps = & $number 'Minidumps'
  if ($null -ne $dumps -and $dumps -gt 0) { Add-ReportFlag -List $flags -Code 'minidumps' -Level WARN -Section '07' -Arguments @((Format-ReportNumber -Value $dumps -Format '0'), $crashDays) }
  $crashes = & $number 'AppCrashes'
  if ($null -ne $crashes -and $crashes -ge (& $limit 'appCrashesWarn' 10)) {
    Add-ReportFlag -List $flags -Code 'appCrashes' -Level WARN -Section '07' -Arguments @((& $countText $crashes 'AppCrashes'), $crashDays, [string](& $item 'AppCrashTop'))
  }

  # 09 Network
  $internet = & $item 'Internet'
  if ($null -ne $internet) {
    $tcp = ((Get-ReportEntry -From $internet -Name 'Tcp') -eq $true)
    $https = ((Get-ReportEntry -From $internet -Name 'Https') -eq $true)
    $clockWrong = ((Get-ReportEntry -From $internet -Name 'Clock') -eq $true)
    $probe = [string](Get-ReportEntry -From $internet -Name 'Probe')
    if (-not $tcp -or (-not $https -and -not $clockWrong)) { Add-ReportFlag -List $flags -Code 'noInternet' -Level CRIT -Section '09' }
    if ($tcp -and ($probe -ceq 'different' -or ($https -and $probe -ceq 'failed'))) { Add-ReportFlag -List $flags -Code 'captivePortal' -Level WARN -Section '09' }
  }
  $off = @(ConvertTo-ReportList -Value (& $item 'FirewallOff'))
  if ($off.Count -gt 0) { Add-ReportFlag -List $flags -Code 'firewallOff' -Level WARN -Section '09' -Arguments @($off -join ', ') }
  $proxy = [string](& $item 'UserProxy')
  if ($proxy -ne '') { Add-ReportFlag -List $flags -Code 'userProxy' -Level WARN -Section '09' -Arguments @($proxy) }
  $hosts = & $number 'HostsEntries'
  if ($null -ne $hosts -and $hosts -gt 0) { Add-ReportFlag -List $flags -Code 'hostsEntries' -Level WARN -Section '09' -Arguments @(Format-ReportNumber -Value $hosts -Format '0') }
  if ((& $item 'Smb1') -eq $true) { Add-ReportFlag -List $flags -Code 'smb1On' -Level WARN -Section '09' }

  # 10 Software
  $leftovers = @(ConvertTo-ReportList -Value (& $item 'OemLeftovers'))
  if ($leftovers.Count -gt 0) { Add-ReportFlag -List $flags -Code 'oemLeftover' -Level WARN -Section '10' -Arguments @(Format-ReportShortList -Values $leftovers) }
  $stopped = @(ConvertTo-ReportList -Value (& $item 'AutoStopped'))
  if ($stopped.Count -gt 0) { Add-ReportFlag -List $flags -Code 'autoServicesStopped' -Level INFO -Section '10' -Arguments @($stopped.Count, (Format-ReportShortList -Values $stopped)) }

  # 11 Security
  $defender = & $item 'Defender'
  $realTime = Get-ReportEntry -From $defender -Name 'RealTime'
  if ($realTime -eq $false) {
    $other = @(foreach ($p in (ConvertTo-ReportList -Value (& $item 'AvProducts'))) {
        if ((Get-ReportEntry -From $p -Name 'Enabled') -eq $true -and (Get-ReportEntry -From $p -Name 'Defender') -ne $true) { $p } })
    if ($other.Count -eq 0) { Add-ReportFlag -List $flags -Code 'defenderOff' -Level CRIT -Section '11' }
  }
  $age = & $number 'SignatureAgeDays'
  if ($realTime -ne $false -and $null -ne $age -and $age -gt (& $limit 'defenderSignatureDays' 7)) {
    Add-ReportFlag -List $flags -Code 'defenderSignatureOld' -Level WARN -Section '11' -Arguments @(Format-ReportNumber -Value $age -Format '0')
  }
  $lua = ConvertTo-ReportNumber -Value (Get-ReportEntry -From (& $item 'Uac') -Name 'EnableLUA')
  if ($null -ne $lua -and $lua -eq 0) { Add-ReportFlag -List $flags -Code 'uacOff' -Level CRIT -Section '11' }
  if ((& $item 'GuestEnabled') -eq $true) { Add-ReportFlag -List $flags -Code 'guestEnabled' -Level WARN -Section '11' }
  if ((& $item 'AutoLogon') -eq $true) { Add-ReportFlag -List $flags -Code 'autoLogon' -Level WARN -Section '11' }
  $rdp = & $item 'Rdp'
  if ((Get-ReportEntry -From $rdp -Name 'Enabled') -eq $true -and (Get-ReportEntry -From $rdp -Name 'Nla') -eq $false) { Add-ReportFlag -List $flags -Code 'rdpNoNla' -Level WARN -Section '11' }

  # A source that failed or ran out of time (spec 6.8: never a failed section).
  $sections = Get-ReportEntry -From $Report -Name 'Sections'
  if ($sections -is [System.Collections.IDictionary]) {
    foreach ($id in @(@($sections.Keys) | ForEach-Object { [string]$_ } | Sort-Object)) {
      foreach ($m in (ConvertTo-ReportList -Value (Get-ReportEntry -From $sections[$id] -Name 'Missing'))) {
        Add-ReportFlag -List $flags -Code 'notCollected' -Level INFO -Section $id -Arguments @([string](Get-ReportEntry -From $m -Name 'What'), [string](Get-ReportEntry -From $m -Name 'Why'))
      }
    }
  }

  $rank = @{ CRIT = 0; WARN = 1; INFO = 2 }
  $index = 0
  $rows = @(foreach ($f in $flags) { [pscustomobject]@{ Rank = $rank[$f.Level]; Section = $f.Section; Index = $index++; Flag = $f } })
  foreach ($row in @($rows | Sort-Object -Property Rank, Section, Index)) { $row.Flag }
}

# --- The report and its core ---------------------------------------------------------------------------------------

function New-ToolReport {
  <#
  .SYNOPSIS
    The report of -Run (see the top of this file): its sections from $Run.Data.Report, in the order of the action's
    report steps; a section the run did not reach (a Stop, the deadline) is an empty one whose Missing says so. Items
    is every section's Items in one table; Findings is Get-ReportFlags.
  #>
  [CmdletBinding()]
  [OutputType([System.Collections.Specialized.OrderedDictionary])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $action = [string]$Run.Args['Action']
  $kind = if ($action -ceq 'fullReport') { 'full' } else { 'quick' }
  $ids = @()
  $entry = $script:ToolActionCatalog[$action]
  if ($null -ne $entry) { $ids = @(foreach ($step in $entry['Steps']) { if ([string]$step -match '^report([0-9]{2})\z') { $Matches[1] } }) }
  $collected = $Run.Data['Report']
  if ($collected -isnot [System.Collections.IDictionary]) { $collected = @{} }
  if ($ids.Count -eq 0) { $ids = @(@($collected.Keys) | ForEach-Object { [string]$_ } | Sort-Object) }

  $sections = [ordered]@{}
  $items = [ordered]@{}
  foreach ($id in $ids) {
    $section = $collected[$id]
    if ($section -isnot [System.Collections.IDictionary]) {
      $section = Complete-ReportSection -Section (New-ReportSection -Id $id)
      $section['Missing'] = @(@{ What = 'This section'; Why = 'not run: the report was stopped or ran out of time' })
    }
    $sections[$id] = $section
    $own = $section['Items']
    if ($own -is [System.Collections.IDictionary]) {
      foreach ($key in @($own.Keys)) { if (-not $items.Contains($key)) { $items[$key] = $own[$key] } }
    }
  }
  $version = [string]$script:SetupVersion
  if ($version -eq '') { $version = 'dev' }
  $identity = $Run.Args['Identity']
  if ($identity -isnot [System.Collections.IDictionary]) { $identity = @{} }
  $report = [ordered]@{
    Version     = 1
    Kind        = $kind
    CreatedAt   = (Format-ToolTime -Value $Run.StartedAt)
    ToolVersion = $version
    Identity    = $identity
    Complaint   = [string]$Run.Args['Complaint']
    Done        = @(ConvertTo-ReportList -Value $Run.Args['Done'])
    Sections    = $sections
    Items       = $items
    Findings    = @()
  }
  $report['Findings'] = @(Get-ReportFlags -Report $report -Config $Run.Config)
  return $report
}

function Format-ReportFactValue {
  # Private, pure. A fact's value as report text: a list joined with ', ', $true/$false as yes/no.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return '' }
  if ($Value -is [bool]) { if ($Value) { return 'yes' } else { return 'no' } }
  if ($Value -is [string]) { return (ConvertTo-ToolDisplayText -Text $Value -MaxLength 400) }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
    return (ConvertTo-ToolDisplayText -Text (@(foreach ($v in $Value) { [string]$v }) -join ', ') -MaxLength 400)
  }
  if ($null -ne (ConvertTo-ReportNumber -Value $Value)) { return (Format-ReportNumber -Value $Value -Format '0.##') }
  return (ConvertTo-ToolDisplayText -Text $Value -MaxLength 400)
}

function Format-ReportHead {
  <#
  .SYNOPSIS
    The first lines of a report's core or of a comparison (Task 9): 'BENTECH TOOLBOX <Title> | dd/MM/yyyy HH:mm | version
    <v> | PC <name> | <maker> <model> | serial <serial>', an empty line, CUSTOMER COMPLAINT with the complaint as typed
    (each line two spaces in) or '  (none)', and an empty line. Pure.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)][string]$Title
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $identity = Get-ReportEntry -From $Report -Name 'Identity'
  $created = ConvertTo-ReportDateTime -Value (Get-ReportEntry -From $Report -Name 'CreatedAt')
  $lines.Add(('BENTECH TOOLBOX {0} | {1} | version {2} | PC {3} | {4} {5} | serial {6}' -f $Title, (Format-ReportDate -When $created),
      (ConvertTo-ToolDisplayText -Text (Get-ReportEntry -From $Report -Name 'ToolVersion') -MaxLength 40),
      (ConvertTo-ToolDisplayText -Text (Get-ReportEntry -From $identity -Name 'ComputerName') -MaxLength 64),
      (ConvertTo-ToolDisplayText -Text (Get-ReportEntry -From $identity -Name 'Manufacturer') -MaxLength 64),
      (ConvertTo-ToolDisplayText -Text (Get-ReportEntry -From $identity -Name 'Model') -MaxLength 64),
      (ConvertTo-ToolDisplayText -Text (Get-ReportEntry -From $identity -Name 'Serial') -MaxLength 64)))
  $lines.Add('')
  $lines.Add('CUSTOMER COMPLAINT')
  $complaint = [string](Get-ReportEntry -From $Report -Name 'Complaint')
  $complaintLines = @(foreach ($line in [regex]::Split($complaint, '\r?\n')) { $text = ConvertTo-ToolDisplayText -Text $line -MaxLength 2000; if ($text -ne '') { $text } })
  if ($complaintLines.Count -eq 0) { $lines.Add('  (none)') } else { foreach ($line in $complaintLines) { $lines.Add('  ' + $line) } }
  $lines.Add('')
  return $lines.ToArray()
}

function Format-ReportCore {
  <#
  .SYNOPSIS
    The AI-ready core (spec 6.8) as lines. Pure.
  .DESCRIPTION
    The header (kind, dd/MM/yyyy HH:mm, version, PC, model, serial); CUSTOMER COMPLAINT (as typed, or '(none)'); THIS
    VISIT (the visit's earlier actions: time, name, outcome, colour; review 4.2); == 00 SUMMARY == (the key facts, then
    every finding, CRIT > WARN > INFO, with its section); -SinceLastVisit (Task 9: the SINCE LAST VISIT lines, when the
    stick holds an earlier report of this PC); each section: == NN TITLE ==, its facts '  name = value', its
    findings (notCollected aside), '  Details:' with its grouped lines indented four spaces, and '  Not collected:
    <what> (<why>)'; then HOW TO USE, a fixed English paragraph for the AI (review 4.7). Headings, fact names and
    finding lines are ASCII; values, details and the complaint keep their real text.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)][ValidateSet('quick', 'full')][string]$Kind,
    [AllowNull()][AllowEmptyCollection()][string[]]$SinceLastVisit
  )

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($line in (Format-ReportHead -Report $Report -Title ('{0} REPORT' -f $Kind.ToUpperInvariant()))) { $lines.Add($line) }

  $lines.Add('THIS VISIT')
  $done = @(ConvertTo-ReportList -Value (Get-ReportEntry -From $Report -Name 'Done'))
  $visit = 0
  foreach ($entry in $done) {
    if ($null -eq $entry) { continue }
    $action = ConvertTo-ScreenText -Text (Get-ReportEntry -From $entry -Name 'Action')
    $title = Get-ToolText -Key ('tile.{0}.title' -f $action)
    if ($title -ceq ('tile.{0}.title' -f $action)) { $title = $action }
    $lines.Add(('  {0}  {1}: {2}, {3}' -f (Format-ReportDate -When (ConvertTo-ReportDateTime -Value (Get-ReportEntry -From $entry -Name 'EndedAt'))), $title,
        (ConvertTo-ScreenText -Text (Get-ReportEntry -From $entry -Name 'Outcome')), (ConvertTo-ScreenText -Text (Get-ReportEntry -From $entry -Name 'Color'))))
    $visit++
  }
  if ($visit -eq 0) { $lines.Add('  (nothing else yet)') }
  $lines.Add('')

  $sections = Get-ReportEntry -From $Report -Name 'Sections'
  if ($sections -isnot [System.Collections.IDictionary]) { $sections = @{} }
  $findings = @(ConvertTo-ReportList -Value (Get-ReportEntry -From $Report -Name 'Findings'))
  $lines.Add('== 00 SUMMARY ==')
  foreach ($pair in $script:ReportSummaryFacts) {
    $id, $name = $pair -split '\|', 2
    $facts = Get-ReportEntry -From $sections[$id] -Name 'Facts'
    if ($facts -is [System.Collections.IDictionary] -and $facts.Contains($name)) { $lines.Add(('  {0} = {1}' -f $name, (Format-ReportFactValue -Value $facts[$name]))) }
  }
  if ($findings.Count -eq 0) { $lines.Add('  (no findings)') }
  # The same finding of several sections (a stopped report's "not run" sections) is one line naming them all.
  $merged = [ordered]@{}
  foreach ($f in $findings) {
    $key = '{0}|{1}' -f $f.Level, (ConvertTo-ScreenText -Text $f.Text)
    if (-not $merged.Contains($key)) { $merged[$key] = @{ Level = [string]$f.Level; Text = (ConvertTo-ScreenText -Text $f.Text); Sections = (New-Object System.Collections.Generic.List[string]) } }
    if (-not $merged[$key].Sections.Contains([string]$f.Section)) { $merged[$key].Sections.Add([string]$f.Section) }
  }
  foreach ($m in $merged.Values) {
    $where = $(if ($m.Sections.Count -eq 1) { 'section ' + $m.Sections[0] } else { 'sections ' + ($m.Sections.ToArray() -join ', ') })
    $lines.Add(('  [{0}] {1} ({2})' -f $m.Level, $m.Text, $where))
  }
  if ($null -ne $SinceLastVisit -and $SinceLastVisit.Count -gt 0) {
    $lines.Add('')
    foreach ($line in $SinceLastVisit) { $lines.Add([string]$line) }
  }

  foreach ($id in @(@($sections.Keys) | ForEach-Object { [string]$_ } | Sort-Object)) {
    $section = $sections[$id]
    $title = [string](Get-ReportEntry -From $section -Name 'Title')
    if ($title -eq '' -and $null -ne $script:ReportSectionTitles) { $title = [string]$script:ReportSectionTitles[$id] }
    $lines.Add('')
    $lines.Add(('== {0} {1} ==' -f $id, (ConvertTo-ScreenText -Text $title).ToUpperInvariant()))
    $facts = Get-ReportEntry -From $section -Name 'Facts'
    if ($facts -is [System.Collections.IDictionary]) {
      foreach ($name in @($facts.Keys)) { $lines.Add(('  {0} = {1}' -f (ConvertTo-ScreenText -Text $name), (Format-ReportFactValue -Value $facts[$name]))) }
    }
    foreach ($f in $findings) { if ([string]$f.Section -ceq $id -and [string]$f.Code -cne 'notCollected') { $lines.Add(('  [{0}] {1}' -f $f.Level, (ConvertTo-ScreenText -Text $f.Text))) } }
    $groups = @(ConvertTo-ReportList -Value (Get-ReportEntry -From $section -Name 'Groups'))
    if ($groups.Count -gt 0) {
      $lines.Add('  Details:')
      foreach ($g in $groups) { $lines.Add('    ' + (ConvertTo-ToolDisplayText -Text $g -MaxLength 500)) }
    }
    foreach ($m in (ConvertTo-ReportList -Value (Get-ReportEntry -From $section -Name 'Missing'))) {
      $lines.Add(('  Not collected: {0} ({1})' -f (ConvertTo-ScreenText -Text (Get-ReportEntry -From $m -Name 'What')), (ConvertTo-ScreenText -Text (Get-ReportEntry -From $m -Name 'Why'))))
    }
  }
  $lines.Add('')
  $lines.Add('HOW TO USE')
  foreach ($line in $script:ReportHowToUse) { $lines.Add('  ' + $line) }
  return $lines.ToArray()
}

function Limit-ReportCore {
  <#
  .SYNOPSIS
    -Lines (Format-ReportCore) cut to fit -MaxBytes: while their UTF-8 size (CRLF between lines) is above -MaxBytes minus
    2048 (room for the BOM and the SAFE copy's tokens), grouped lines are cut from the largest section first, from the
    end of its details (the oldest), and the section says '(<n> lines cut to fit; full text in <RawFile>)'. The header,
    the summary, the facts and the findings are never cut. Lines that already fit come back unchanged. Pure.
  .DESCRIPTION
    A section's details are the four-space lines after its '  Details:' line, inside '== <NN> ...' of a section that
    -Sections names (all sections when -Sections is $null).
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
    [AllowNull()]$Sections,
    [Parameter(Mandatory)][ValidateRange(4096, 1073741824)][int]$MaxBytes,
    [string]$RawFile = 'raw\report-full.txt'
  )

  $encoding = New-Object Text.UTF8Encoding $false
  $count = $Lines.Count
  $sizes = New-Object 'int[]' $count
  [long]$total = 0
  for ($i = 0; $i -lt $count; $i++) {
    $sizes[$i] = $encoding.GetByteCount([string]$Lines[$i])
    $total += $sizes[$i] + 2
  }
  if ($count -gt 0) { $total -= 2 }
  $budget = [long]$MaxBytes - 2048
  if ($total -le $budget) { return $Lines }

  # The details block of each section: its first line and how many lines it has.
  $blocks = New-Object System.Collections.Generic.List[object]
  $current = ''
  for ($i = 0; $i -lt $count; $i++) {
    $line = [string]$Lines[$i]
    $heading = [regex]::Match($line, '^== ([0-9]{2}) ')
    if ($heading.Success) { $current = $heading.Groups[1].Value; continue }
    if ($line -cne '  Details:' -or $current -eq '' -or $current -eq '00') { continue }
    if ($Sections -is [System.Collections.IDictionary] -and -not $Sections.Contains($current)) { continue }
    $start = $i + 1
    $end = $start
    [long]$bytes = 0
    while ($end -lt $count -and ([string]$Lines[$end]).StartsWith('    ', [StringComparison]::Ordinal)) {
      $bytes += $sizes[$end] + 2
      $end++
    }
    if ($end -gt $start) { $blocks.Add(@{ Start = $start; Kept = ($end - $start); Bytes = $bytes; Cut = 0 }) }
  }
  if ($blocks.Count -eq 0) { return $Lines }

  # Greedy: from the largest block (in bytes), drop its last line until it is no longer the largest or it all fits.
  $noteBytes = $encoding.GetByteCount(('    (999999 lines cut to fit; full text in {0})' -f $RawFile)) + 2
  while ($total -gt $budget) {
    $largest = $null
    $second = [long]0
    foreach ($b in $blocks) {
      if ($b.Kept -le 0) { continue }
      if ($null -eq $largest -or $b.Bytes -gt $largest.Bytes) {
        if ($null -ne $largest -and $largest.Bytes -gt $second) { $second = $largest.Bytes }
        $largest = $b
      } elseif ($b.Bytes -gt $second) {
        $second = $b.Bytes
      }
    }
    if ($null -eq $largest) { break }
    do {
      $last = $largest.Start + $largest.Kept - 1
      $largest.Kept--
      $largest.Bytes -= $sizes[$last] + 2
      $total -= $sizes[$last] + 2
      if ($largest.Cut -eq 0) { $total += $noteBytes }
      $largest.Cut++
    } while ($total -gt $budget -and $largest.Kept -gt 0 -and $largest.Bytes -ge $second)
  }

  $byStart = @{}
  foreach ($b in $blocks) { $byStart[$b.Start] = $b }
  $out = New-Object System.Collections.Generic.List[string]
  $i = 0
  while ($i -lt $count) {
    $b = $byStart[$i]
    if ($null -eq $b -or $b.Cut -eq 0) {
      $out.Add([string]$Lines[$i])
      $i++
      continue
    }
    for ($k = 0; $k -lt $b.Kept; $k++) { $out.Add([string]$Lines[$i + $k]) }
    $out.Add(('    ({0} lines cut to fit; full text in {1})' -f $b.Cut, $RawFile))
    $i += $b.Kept + $b.Cut
  }
  return $out.ToArray()
}

function ConvertTo-ReportData {
  <#
  .SYNOPSIS
    The data JSON of a report (written plain UTF-8, RD-R23; Compare and the SAFE copy of Task 9 read it):
    [ordered]@{ Version = 1; Kind; CreatedAt; ToolVersion; Identity; Facts (section 00's key facts, name -> value);
    Findings = @( @{ Code; Level; Args; Section } ); Disks = [ordered] <serial, else 'Disk <n>'> -> @{ Number; System;
    Model; Health; Wear; Temperature; ReadErrors; WriteErrors; PowerOnHours }; FreeGB; FreePercent;
    ProblemDevices = @( @{ Id; Name; Code } ); Programs = @( '<name>|<version>' ); Crashes = @{ KernelPower; BugCheck;
    Whea } (each a list of 'yyyy-MM-ddTHH:mm:ss' event times) }. Pure.
  #>
  [CmdletBinding()]
  [OutputType([System.Collections.Specialized.OrderedDictionary])]
  param([Parameter(Mandatory)]$Report)

  $items = Get-ReportEntry -From $Report -Name 'Items'
  $sections = Get-ReportEntry -From $Report -Name 'Sections'
  $facts = [ordered]@{}
  foreach ($pair in $script:ReportSummaryFacts) {
    $id, $name = $pair -split '\|', 2
    $own = Get-ReportEntry -From (Get-ReportEntry -From $sections -Name $id) -Name 'Facts'
    if ($own -is [System.Collections.IDictionary] -and $own.Contains($name)) { $facts[$name] = Format-ReportFactValue -Value $own[$name] }
  }
  $disks = [ordered]@{}
  foreach ($d in (ConvertTo-ReportList -Value (Get-ReportEntry -From $items -Name 'Disks'))) {
    $serial = ([string](Get-ReportEntry -From $d -Name 'Serial')).Trim()
    if ($serial -eq '') { $serial = 'Disk ' + [string](Get-ReportEntry -From $d -Name 'Number') }
    $row = [ordered]@{}
    foreach ($k in 'Number', 'System', 'Model', 'Health', 'Wear', 'Temperature', 'ReadErrors', 'WriteErrors', 'PowerOnHours') { $row[$k] = Get-ReportEntry -From $d -Name $k }
    $disks[$serial] = $row
  }
  $times = {
    param($name)
    , @(foreach ($r in (ConvertTo-ReportList -Value (Get-ReportEntry -From $items -Name $name))) { $t = [string](Get-ReportEntry -From $r -Name 'Time'); if ($t -ne '') { $t } })
  }
  return [ordered]@{
    Version        = 1
    Kind           = [string](Get-ReportEntry -From $Report -Name 'Kind')
    CreatedAt      = [string](Get-ReportEntry -From $Report -Name 'CreatedAt')
    ToolVersion    = [string](Get-ReportEntry -From $Report -Name 'ToolVersion')
    Identity       = (Get-ReportEntry -From $Report -Name 'Identity')
    Facts          = $facts
    Findings       = @(foreach ($f in (ConvertTo-ReportList -Value (Get-ReportEntry -From $Report -Name 'Findings'))) {
        [ordered]@{ Code = [string]$f.Code; Level = [string]$f.Level; Args = [string[]]@($f.Args); Section = [string]$f.Section } })
    Disks          = $disks
    FreeGB         = (ConvertTo-ReportNumber -Value (Get-ReportEntry -From $items -Name 'FreeGB'))
    FreePercent    = (ConvertTo-ReportNumber -Value (Get-ReportEntry -From $items -Name 'FreePercent'))
    ProblemDevices = @(foreach ($p in (ConvertTo-ReportList -Value (Get-ReportEntry -From $items -Name 'ProblemDevices'))) {
        [ordered]@{ Id = [string](Get-ReportEntry -From $p -Name 'Id'); Name = [string](Get-ReportEntry -From $p -Name 'Name'); Code = (Get-ReportEntry -From $p -Name 'Code') } })
    Programs       = @(foreach ($p in (ConvertTo-ReportList -Value (Get-ReportEntry -From $items -Name 'Programs'))) {
        '{0}|{1}' -f [string](Get-ReportEntry -From $p -Name 'Name'), [string](Get-ReportEntry -From $p -Name 'Version') })
    Crashes        = [ordered]@{ KernelPower = (& $times 'KernelPower41Events'); BugCheck = (& $times 'BugChecks'); Whea = (& $times 'Whea') }
  }
}

# --- Files ---------------------------------------------------------------------------------------------------------

function Get-ToolReportPcName {
  # The PC part of the report's file names: Identity.ComputerName reduced to [A-Za-z0-9-] ('PC' when nothing is left).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $identity = $Run.Args['Identity']
  $name = ''
  if ($identity -is [System.Collections.IDictionary]) { $name = ([string]$identity['ComputerName']) -creplace '[^A-Za-z0-9-]', '' }
  if ($name -eq '') { $name = 'PC' }
  return $name
}

function Get-ToolReportFolder {
  # Private. Where the report's files go: the session folder (on the stick, or its local fallback), else the run folder.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  if (-not [string]::IsNullOrEmpty([string]$Run.SessionDir)) { return [string]$Run.SessionDir }
  return [string]$Run.Dir
}

function Get-ToolReportStamp {
  <#
  .SYNOPSIS
    The report's stamp: the run's start as 'yyyy-MM-dd_HHmm' (invariant), with '_2', '_3', ... when a file of that
    minute (<Prefix>_<PC>_<stamp>.txt, <Prefix>_SAFE_<stamp>.txt or raw_<stamp>) is already in the folder. -Prefix is
    REPORT (Quick and Full) or COMPARE (Task 9). Chosen once per run ($Run.Data.ReportStamp).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run, [ValidateSet('REPORT', 'COMPARE')][string]$Prefix = 'REPORT')

  $known = [string]$Run.Data['ReportStamp']
  if ($known -ne '') { return $known }
  $started = $Run.StartedAt
  if ($started -isnot [datetime]) { $started = Get-Date }
  $base = $started.ToString('yyyy-MM-dd_HHmm', [Globalization.CultureInfo]::InvariantCulture)
  $folder = Get-ToolReportFolder -Run $Run
  $pc = Get-ToolReportPcName -Run $Run
  $stamp = $base
  for ($n = 2; $n -le 99; $n++) {
    $taken = [IO.File]::Exists([IO.Path]::Combine($folder, ('{0}_{1}_{2}.txt' -f $Prefix, $pc, $stamp))) -or
      [IO.File]::Exists([IO.Path]::Combine($folder, ('{0}_SAFE_{1}.txt' -f $Prefix, $stamp))) -or [IO.Directory]::Exists([IO.Path]::Combine($folder, ('raw_' + $stamp)))
    if (-not $taken) { break }
    $stamp = '{0}_{1}' -f $base, $n
  }
  $Run.Data['ReportStamp'] = $stamp
  return $stamp
}

function Get-ToolReportRawDir {
  <#
  .SYNOPSIS
    The report's raw folder, <session>\raw_<stamp>\, created on first use ($Run.Data.ReportRawDir). Throws when it is a
    link (V2-R13, checked before and after the creation) or cannot be created; the callers catch.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $known = [string]$Run.Data['ReportRawDir']
  if ($known -ne '' -and [IO.Directory]::Exists($known)) { return $known }
  $dir = [IO.Path]::Combine((Get-ToolReportFolder -Run $Run), ('raw_' + (Get-ToolReportStamp -Run $Run)))
  if (Test-StickReparsePoint -Path $dir) { throw 'the raw folder is a link' }
  [void][IO.Directory]::CreateDirectory($dir)
  if (Test-StickReparsePoint -Path $dir) { throw 'the raw folder is a link' }
  $Run.Data['ReportRawDir'] = $dir
  return $dir
}

function Save-ToolReportText {
  # Private. Writes -Lines (CRLF) as UTF-8 with a BOM (Notepad shows Hebrew right). Throws when the file is a link
  # (V2-R13) or cannot be written.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

  if (Test-StickReparsePoint -Path $Path) { throw ('{0} is a link' -f [IO.Path]::GetFileName($Path)) }
  [IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $true))
}

function Copy-ToolRawFile {
  <#
  .SYNOPSIS
    Copies a file another process may hold open (CBS.log, a crash dump) to -Destination, at most its last -MaxBytes,
    for raw\ only: nothing reads or judges what it copies. $true when copied, $false when the source is missing. Throws
    when the copy fails or the destination exists or is a link.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [long]$MaxBytes = 64MB
  )

  if (-not [IO.File]::Exists($Source)) { return $false }
  if (Test-StickReparsePoint -Path $Destination) { throw ('{0} is a link' -f [IO.Path]::GetFileName($Destination)) }
  $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $from = New-Object IO.FileStream($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
  try {
    if ($from.Length -gt $MaxBytes) { [void]$from.Seek($from.Length - $MaxBytes, [IO.SeekOrigin]::Begin) }
    $to = New-Object IO.FileStream($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $from.CopyTo($to) } finally { $to.Dispose() }
  } finally {
    $from.Dispose()
  }
  return $true
}

function Read-ToolLogErrors {
  <#
  .SYNOPSIS
    The error lines of an English servicing log (CBS.log, dism.log; setupapi.dev.log with -Patterns '!!!'), condensed:
    at most the last -MaxBytes (8 MB) are read, the lines holding one of -Patterns (', Error', 'HRESULT = 0x8',
    '[SR] Cannot repair') are kept without their leading time stamp, grouped by their text and counted, newest last,
    the last -MaxLines groups as '<n>x <text>'. Display only: no decision reads them. Empty when the file is missing or
    unreadable. Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [ValidateRange(1, 10000)][int]$MaxLines = 40,
    [string[]]$Patterns = $script:ReportLogErrorPatterns,
    [long]$MaxBytes = 8MB
  )

  try {
    $text = Read-FileTail -Path $Path -MaxBytes $MaxBytes
    if ([string]::IsNullOrEmpty($text)) { return }
    $groups = @{}
    $index = 0
    foreach ($line in [regex]::Split($text, '\r?\n')) {
      $index++
      $hit = $false
      foreach ($p in $Patterns) { if ($p -ne '' -and $line.IndexOf($p, [StringComparison]::Ordinal) -ge 0) { $hit = $true; break } }
      if (-not $hit) { continue }
      $body = [regex]::Replace($line, '^\s*[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?,?\s*', '')
      $body = ConvertTo-ToolDisplayText -Text ([regex]::Replace($body, '\s+', ' ')) -MaxLength 300
      if ($body -eq '') { continue }
      $g = $groups[$body]
      if ($null -eq $g) { $g = @{ Text = $body; Count = 0; Last = 0 }; $groups[$body] = $g }
      $g.Count++
      $g.Last = $index
    }
    $sorted = @($groups.Values | Sort-Object -Property @{ Expression = { $_.Last } })
    if ($sorted.Count -gt $MaxLines) { $sorted = @($sorted | Select-Object -Last $MaxLines) }
    foreach ($g in $sorted) { '{0}x {1}' -f $g.Count, $g.Text }
  } catch {
    Write-SetupLog -Level WARN -Message 'A log could not be condensed for the report' -Data @{ file = (ConvertTo-ScreenText -Text ([IO.Path]::GetFileName($Path))); error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
}

# --- The steps -----------------------------------------------------------------------------------------------------

function Invoke-ToolStepReportWrite {
  <#
  .SYNOPSIS
    Step reportWrite (Quick and Full; always runs, so a stopped report still writes what it collected): the report
    (New-ToolReport), its core cut to repair.reportMaxKB (150 KB) as REPORT_<PC>_<stamp>.txt (UTF-8 with a BOM), the
    uncut core as raw_<stamp>\report-full.txt, REPORT_<PC>_<stamp>_data.json (plain UTF-8, RD-R23) and (Task 9) the
    privacy-safe copy REPORT_SAFE_<stamp>.txt (Save-ToolSafeCopy: the cut core through one masker; no PC name in its
    name, RD-R4). The report's findings go into the run's findings (the window shows them). $Run.Files.Report, .Data,
    .Raw and .Safe.
  .DESCRIPTION
    When the stick holds an earlier report of this PC (Find-ToolEarlierReport, outside this visit's folder), the core
    has the SINCE LAST VISIT section right after section 00; an earlier report file of this PC that cannot be read is
    named there and is WARN earlierUnreadable (RD-R23: never a silent comparison with nothing).
    The core that cannot be written (a link, a pulled stick) is CRIT reportWriteFailed and 'failed'; a data file or a
    SAFE copy that cannot be written is WARN reportWriteFailed ('the data file ...', 'the privacy-safe copy ...'), the
    core stays; a SAFE copy is never written unmasked. Nothing is written through a link (V2-R13).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try {
    $report = New-ToolReport -Run $Run
    $data = ConvertTo-ReportData -Report $report
    $pc = Get-ToolReportPcName -Run $Run
    $stamp = Get-ToolReportStamp -Run $Run
    $folder = Get-ToolReportFolder -Run $Run
    $found = Get-ToolRunSinceLastVisit -Run $Run -Current $data
    $lines = [string[]]@(Format-ReportCore -Report $report -Kind $report['Kind'] -SinceLastVisit $found.Lines)
    $rawDir = $null
    $rawFile = 'raw_{0}\report-full.txt' -f $stamp
    try {
      $rawDir = Get-ToolReportRawDir -Run $Run
    } catch {
      $rawFile = 'the full text could not be kept'
      Write-SetupLog -Level WARN -Message 'The raw folder of the report could not be made' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
    $maxKB = Get-ToolRepairNumber -Config $Run.Config -Path 'reportMaxKB' -Default 150
    $core = [string[]]@(Limit-ReportCore -Lines $lines -Sections $report['Sections'] -MaxBytes ([int]($maxKB * 1024)) -RawFile $rawFile)
    $corePath = [IO.Path]::Combine($folder, ('REPORT_{0}_{1}.txt' -f $pc, $stamp))
    Save-ToolReportText -Path $corePath -Lines $core
    $Run.Files['Report'] = $corePath
    if ($null -ne $rawDir) {
      try {
        Save-ToolReportText -Path ([IO.Path]::Combine($rawDir, 'report-full.txt')) -Lines $lines
        $Run.Files['Raw'] = $rawDir
      } catch {
        Write-SetupLog -Level WARN -Message 'The full text of the report could not be kept' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
      }
    }
    $dataPath = [IO.Path]::Combine($folder, ('REPORT_{0}_{1}_data.json' -f $pc, $stamp))
    if (Test-StickReparsePoint -Path $dataPath) {
      Add-ToolFinding -Run $Run -Level WARN -Code 'reportWriteFailed' -Arguments @('the data file is a link')
    } elseif (Write-ToolJsonFile -Path $dataPath -InputObject $data -Depth 10 -Utf8) {
      $Run.Files['Data'] = $dataPath
    } else {
      Add-ToolFinding -Run $Run -Level WARN -Code 'reportWriteFailed' -Arguments @('the data file could not be written')
    }
    $safePath = [IO.Path]::Combine($folder, ('REPORT_SAFE_{0}.txt' -f $stamp))
    $why = Save-ToolSafeCopy -Path $safePath -Lines $core -Report $report -Earlier $found.Earlier
    if ($why -eq '') { $Run.Files['Safe'] = $safePath } else { Add-ToolFinding -Run $Run -Level WARN -Code 'reportWriteFailed' -Arguments @($why) }
    $skipped = @($found.Skipped)
    if ($skipped.Count -gt 0) { Add-ToolFinding -Run $Run -Level WARN -Code 'earlierUnreadable' -Arguments @($skipped.Count, (Format-ReportShortList -Values $skipped)) }
    # The window's list: each finding once (a stopped report's "not run" sections share one).
    $added = @{}
    foreach ($f in @($report['Findings'])) {
      $key = '{0}|{1}' -f $f.Code, (@($f.Args) -join '|')
      if ($added.ContainsKey($key)) { continue }
      $added[$key] = $true
      Add-ToolFinding -Run $Run -Level $f.Level -Code $f.Code -Arguments $f.Args
    }
    Add-ToolLog -Run $Run -Text ('Report written: {0} lines, {1} findings ({2})' -f $core.Count, @($report['Findings']).Count, [IO.Path]::GetFileName($corePath))
    return 'done'
  } catch {
    $reason = ConvertTo-ReportReason -Exception $_.Exception
    Write-SetupLog -Level ERROR -Message 'The report could not be written' -Data @{ reason = $reason; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    Add-ToolFinding -Run $Run -Level CRIT -Code 'reportWriteFailed' -Arguments @($reason)
    return 'failed'
  }
}

# The zip of raw_<stamp>\ (<FROM>, <TO>: literals), run in a grandchild bounded by toolStep.zip (review M5). It writes
# the temporary <zip>.partial, which the step renames once the grandchild ended well.
$script:ReportZipCommand = @'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory(<FROM>, <TO>, [IO.Compression.CompressionLevel]::Optimal, $false)
@{ Done = $true }
'@

# The least time left (seconds) the zip is started with; with less the raw folder stays as it is (review M5).
$script:ReportZipMinSeconds = 180

function Remove-ToolReportPartial {
  # Private. Deletes the zip's temporary file when it exists and is no link (V2-R13). Never throws: a file that stays
  # is logged (its name says it is not complete).
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  try {
    if ([IO.File]::Exists($Path) -and -not (Test-StickReparsePoint -Path $Path)) { [IO.File]::Delete($Path) }
  } catch {
    Write-SetupLog -Level WARN -Message 'The unfinished zip could not be deleted' -Data @{ file = (ConvertTo-ScreenText -Text ([IO.Path]::GetFileName($Path))); error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
}

function Invoke-ToolStepReportZip {
  <#
  .SYNOPSIS
    Step reportZip (Full): raw_<stamp>\ into REPORT_<PC>_<stamp>_raw.zip beside it; the folder stays. $Run.Files.Zip.
  .DESCRIPTION
    No raw folder: 'skipped'. Less than $script:ReportZipMinSeconds of the action's time left: WARN reportZipFailed
    ('not enough time left') and 'skipped'. Else the grandchild zip (System.IO.Compression.ZipFile.CreateFromDirectory,
    toolStep.zip, capped by the time left) writes <zip>.partial (a leftover one is deleted first), and only after the
    grandchild ended well is it renamed to the zip's name (review M5): a stall, a kill or a full stick never leaves a
    file that looks complete, and the partial file is deleted. A zip that cannot be made (a link, an existing zip, a
    full stick) is WARN reportZipFailed with a fixed reason (ConvertTo-ReportReason) and 'warn'; a timeout is the
    same finding and 'timedout'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $rawDir = [string]$Run.Data['ReportRawDir']
  if ($rawDir -eq '' -or -not [IO.Directory]::Exists($rawDir)) {
    Add-ToolLog -Run $Run -Text 'No raw files to zip'
    return 'skipped'
  }
  $zip = [IO.Path]::Combine((Get-ToolReportFolder -Run $Run), ('REPORT_{0}_{1}_raw.zip' -f (Get-ToolReportPcName -Run $Run), (Get-ToolReportStamp -Run $Run)))
  $partial = $zip + '.partial'
  if ((Get-ToolRemainingSeconds -Run $Run) -lt $script:ReportZipMinSeconds) {
    Add-ToolLog -Run $Run -Text 'Too little time left to zip the raw files'
    Add-ToolFinding -Run $Run -Level WARN -Code 'reportZipFailed' -Arguments @('not enough time left', $rawDir)
    return 'skipped'
  }
  try {
    foreach ($path in $zip, $partial) { if (Test-StickReparsePoint -Path $path) { throw ('{0} is a link' -f [IO.Path]::GetFileName($path)) } }
    if ([IO.File]::Exists($zip)) { throw 'the zip already exists' }
    if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
    $command = $script:ReportZipCommand.Replace('<FROM>', (ConvertTo-PowerShellLiteral -Text $rawDir)).Replace('<TO>', (ConvertTo-PowerShellLiteral -Text $partial))
    $child = Invoke-ToolJsonChild -Run $Run -Name 'zip' -Command $command -StepTimeout 'zip'
    if (-not $child.Ok -or -not [IO.File]::Exists($partial)) {
      Remove-ToolReportPartial -Path $partial
      $reason = ConvertTo-ReportReason -Why $(if ($child.Ok) { 'no result' } else { [string]$child.Error })
      Add-ToolFinding -Run $Run -Level WARN -Code 'reportZipFailed' -Arguments @($reason, $rawDir)
      if ($child.TimedOut) { return 'timedout' }
      return 'warn'
    }
    [IO.File]::Move($partial, $zip)
    $Run.Files['Zip'] = $zip
    Add-ToolLog -Run $Run -Text ('Raw files zipped: {0}' -f [IO.Path]::GetFileName($zip))
    return 'done'
  } catch {
    Remove-ToolReportPartial -Path $partial
    $reason = ConvertTo-ReportReason -Exception $_.Exception
    Write-SetupLog -Level WARN -Message 'The raw files could not be zipped' -Data @{ reason = $reason; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    Add-ToolFinding -Run $Run -Level WARN -Code 'reportZipFailed' -Arguments @($reason, $rawDir)
    return 'warn'
  }
}
