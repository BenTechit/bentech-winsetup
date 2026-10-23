# src/Repair/ToolCollect.ps1
# Repair & diagnostics, the report sections 01-12 (repair spec 6.8; repair Task 8): one collector per section,
# Get-ReportData<NN> -Run -Quick <bool>, and its step Invoke-ToolStepReport<NN>, which stores the section in
# $Run.Data.Report['<NN>']. ToolReport.ps1 turns the sections into the report.
#
# A section: @{ Id = '<NN>'; Title; Facts = [ordered] name -> value (English names, the values as read: a Hebrew
# program or volume name keeps its real text); Groups = [string[]] (the details, grouped and counted); Items = [ordered]
# (structured values, for the flags and the data JSON: ToolReport.ps1 lists them); Raw = [string[]] (file names under
# raw_<stamp>\); Missing = @( @{ What; Why } ) }.
#
# The rules (repair plan, Global Constraints; spec 6.8):
#   - every source is language-independent: CIM and registry values, enum names, event providers, IDs and their
#     data fields, SIDs; never a tool's text. The tools that only feed raw\ (systeminfo, vssadmin, gpresult, dsregcmd,
#     powercfg, wevtutil, msinfo32) are run, never read; Full only;
#   - every source is bounded: CIM with -OperationTimeoutSec 30, every cmdlet that can hang (the Administrators group's
#     member lookups among them) and every event query (the disk events too) in a grandchild (Invoke-ToolJsonChild)
#     with its toolStep timeout, every native tool through Invoke-ToolNative (review M4: a stall loses its source,
#     never the report);
#   - a source that fails or runs out of time is a Missing entry (notCollected), never a failed section: each source
#     is caught on its own (Invoke-ReportSource), and a collector never throws. Its reason is a fixed English code
#     (ConvertTo-ReportReason, review M11), never Windows' own (localized) message, which only the log keeps;
#   - Quick skips every slow source (the table of the brief) and runs one connectivity test, the internet check of
#     section 01, which section 09 reuses ($Run.Data.Internet);
#   - the report reads; it changes nothing and scans no disk (the read-only volume state of the Health check, ruling
#     RD-R12; the online volume scan belongs to the repairs);
#   - a scheduled task, a service or a startup item is named by its executable only, never its arguments (review
#     section 3: arguments hold tokens); personal values stay in Items under the names ToolReport.ps1 lists, for the
#     privacy-safe copy (Task 9);
#   - the signed-in user's own hive (HKEY_USERS\<SID>), never the elevated process's HKCU (review I-12).
#
# Needs ToolEngine (Invoke-ToolJsonChild, Invoke-ToolNative, Add-ToolLog, Format-ToolExitCode,
# ConvertTo-ToolDisplayText), ToolChecks (Get-ToolWinReState, Get-ToolVolumeState, Get-ToolProblemDevices,
# Get-ToolActivation, Get-ToolCheckError, Get-ToolSystemLetter, ConvertFrom-CbsSrText, Read-ToolCbsLog), ToolSafety
# (Test-ToolInternet, Get-ToolDiskEventSplit, Get-ToolBitLockerChip, Get-ToolRepairNumber), ToolRepairs
# (Get-ToolSystemTool, Get-ToolUserSid, Get-ToolOemLeftovers, $script:ToolMachineUninstallKeys), ToolAdvanced
# (Get-ToolNetSettings), ToolReport (ConvertTo-EventGroups, Get-ToolReportRawDir, Copy-ToolRawFile, Read-ToolLogErrors,
# ConvertTo-ReportNumber, Format-ReportNumber, ConvertTo-ReportDateTime), Reboot (Get-RebootRegistryValue,
# Get-ServicingRebootSignals), Detection (Get-SignedInUserName, Resolve-Brand), Report (Format-ReportDate,
# Get-SmartAppControlState), Activity (Read-FileTail, Wait-SetupDelay), Winget (ConvertTo-PowerShellLiteral), Logging
# and StartScreen (ConvertTo-ScreenText). The bundle holds every file.

$script:ReportSectionTitles = [ordered]@{
  '01' = 'System'; '02' = 'Hardware'; '03' = 'Storage'; '04' = 'Boot and recovery'; '05' = 'Windows Update'; '06' = 'Drivers and devices'
  '07' = 'Events and crashes'; '08' = 'Performance and power'; '09' = 'Network'; '10' = 'Software'; '11' = 'Security'; '12' = 'msinfo32'
}

# The files the collectors list or copy (tests point them at $TestDrive).
$script:ToolReportPaths = @{
  Minidump      = [IO.Path]::Combine([string]$env:SystemRoot, 'Minidump')
  MemoryDump    = [IO.Path]::Combine([string]$env:SystemRoot, 'MEMORY.DMP')
  Hosts         = [IO.Path]::Combine([string]$env:SystemRoot, 'System32\drivers\etc\hosts')
  CbsLog        = [IO.Path]::Combine([string]$env:SystemRoot, 'Logs\CBS\CBS.log')
  DismLog       = [IO.Path]::Combine([string]$env:SystemRoot, 'Logs\DISM\dism.log')
  SetupApiLog   = [IO.Path]::Combine([string]$env:SystemRoot, 'INF\setupapi.dev.log')
  CommonStartup = [IO.Path]::Combine([string]$env:ProgramData, 'Microsoft\Windows\Start Menu\Programs\StartUp')
  WindowsFolder = [string]$env:SystemRoot
}

# The connectivity test of a Full report (TCP 443, all started together, 3 s each).
$script:ReportTcpHosts = @('login.microsoftonline.com', 'outlook.office365.com', 'update.microsoft.com', 'download.windowsupdate.com', 'www.google.com')

# Automatic services that are often stopped on purpose (the old kit's list): never reported as "not running".
$script:ReportServiceIgnore = '^(sppsvc|RemoteRegistry|MapsBroker|WbioSrvc|edgeupdate.*|gupdate.*|GoogleUpdater.*|BITS|wuauserv|TrustedInstaller|CDPSvc|tiledatamodelsvc|SharedAccess)$'

# Driver classes whose third-party drivers matter most when they are old (more than six years).
$script:ReportCoreDriverClasses = @('System', 'SCSIAdapter', 'HDC', 'Net', 'Display', 'Bluetooth', 'USB', 'MEDIA', 'Firmware')

# GPT partition types (MSFT_Partition.GptType) and the MBR recovery type.
$script:ReportGptEfi = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:ReportGptRecovery = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$script:ReportGptMsr = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

# Windows' power plans by GUID, and Office's update channels by the GUID in CDNBaseUrl.
$script:ReportPowerPlans = @{
  '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'; '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
  'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'; 'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Ultimate performance'
}
$script:ReportOfficeChannels = @{
  '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current'; '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Preview'
  '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise'; '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise'
  'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Preview'; '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta'
}

# --- The grandchildren's commands (each returns one hashtable; read by key, never by text) --------------------------

# The physical disks with their serials, and the system volume's disk numbers (<L> is its letter): enum names.
$script:ReportDiskInfoCommand = @'
@{ SystemDisks = @(Get-Partition -DriveLetter '<L>' | ForEach-Object { [int]$_.DiskNumber } | Sort-Object -Unique)
   Items = @(Get-PhysicalDisk | ForEach-Object {
  @{ DeviceId = [string]$_.DeviceId; Model = [string]$_.FriendlyName; Serial = ([string]$_.SerialNumber).Trim(); Media = [string]$_.MediaType
     Bus = [string]$_.BusType; Health = [string]$_.HealthStatus; Size = [long]$_.Size; Firmware = [string]$_.FirmwareVersion } }) }
'@

# Each disk's reliability counters ($null values for a disk that reports none: USB, some RAID and virtual disks).
$script:ReportDiskCountersCommand = @'
@{ Items = @(Get-PhysicalDisk | ForEach-Object {
  $disk = $_
  $c = $null
  try { $c = $disk | Get-StorageReliabilityCounter } catch { $c = $null }
  @{ DeviceId = [string]$disk.DeviceId; Wear = $c.Wear; Temperature = $c.Temperature; TemperatureMax = $c.TemperatureMax
     ReadErrors = $c.ReadErrorsUncorrected; WriteErrors = $c.WriteErrorsUncorrected; PowerOnHours = $c.PowerOnHours } }) }
'@

# Every partition with its GPT or MBR type (MSFT_Partition through Get-Partition).
$script:ReportPartitionsCommand = @'
@{ Items = @(Get-Partition | ForEach-Object {
  $letter = [string]$_.DriveLetter
  if ($letter -notmatch '^[A-Za-z]$') { $letter = '' }
  @{ Disk = [int]$_.DiskNumber; Number = [int]$_.PartitionNumber; GptType = [string]$_.GptType; MbrType = $_.MbrType; Size = [long]$_.Size
     Letter = $letter; IsSystem = [bool]$_.IsSystem; IsBoot = [bool]$_.IsBoot } }) }
'@

# Event queries (<SPECS>: a JSON list, as a literal). Each spec: Name; Log; Days; Max (MaxEvents); Ids; Levels;
# Provider (in the filter: a provider that is always registered); Providers (checked after the query: one missing on
# this PC would fail the whole query); Mode 'groups' (provider + ID + level counted here, at most Keep groups, the
# newest event's message cut to 300) or 'rows' (at most Keep events, with the named EventData fields Names and the
# Properties at the indexes Props). The answer per spec: @{ Error; Total; Capped (the query read Max events, so Total
# is a lower bound: review M6); Unreadable; Rows; Groups }. Messages are display only.
$script:ReportEventsCommand = @'
$specs = ConvertFrom-Json -InputObject <SPECS>
$invariant = [Globalization.CultureInfo]::InvariantCulture
$answer = @{}
foreach ($s in @($specs)) {
  $filter = @{ LogName = [string]$s.Log; StartTime = (Get-Date).AddDays(-[double]$s.Days) }
  if (@($s.Ids).Count -gt 0) { $filter['Id'] = [int[]]@($s.Ids) }
  if (@($s.Levels).Count -gt 0) { $filter['Level'] = [int[]]@($s.Levels) }
  if ([string]$s.Provider -ne '') { $filter['ProviderName'] = [string]$s.Provider }
  $events = @()
  $problem = ''
  try {
    $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents ([int]$s.Max) -ErrorAction Stop)
  } catch {
    if ([string]$_.FullyQualifiedErrorId -notlike 'NoMatching*') { $problem = [string]$_.Exception.Message }
  }
  $providers = @(foreach ($p in @($s.Providers)) { [string]$p })
  $names = @(foreach ($n in @($s.Names)) { [string]$n })
  $keep = [int]$s.Keep
  $rows = New-Object System.Collections.Generic.List[object]
  $groups = @{}
  $order = New-Object System.Collections.Generic.List[string]
  $total = 0
  $unreadable = 0
  foreach ($e in $events) {
    $provider = [string]$e.ProviderName
    if ($providers.Count -gt 0 -and $providers -notcontains $provider) { continue }
    $total++
    try {
      $time = $e.TimeCreated.ToString('yyyy-MM-ddTHH:mm:ss', $invariant)
      if ([string]$s.Mode -eq 'rows') {
        if ($rows.Count -ge $keep) { continue }
        $data = @{}
        if ($names.Count -gt 0) {
          foreach ($d in @(([xml]$e.ToXml()).Event.EventData.Data)) {
            if ($d -is [Xml.XmlElement] -and $names -contains $d.GetAttribute('Name')) { $data[$d.GetAttribute('Name')] = [string]$d.InnerText }
          }
        }
        $props = @(foreach ($i in @($s.Props)) { if ($e.Properties.Count -gt [int]$i) { [string]$e.Properties[[int]$i].Value } else { '' } })
        $rows.Add(@{ Provider = $provider; Id = [int]$e.Id; Level = [int]$e.Level; Time = $time; Data = $data; Props = $props })
      } else {
        $key = '{0}|{1}|{2}' -f $provider, [int]$e.Id, [int]$e.Level
        $g = $groups[$key]
        if ($null -eq $g) {
          if ($groups.Count -ge $keep) { continue }
          $message = ''
          try { $message = [string]$e.Message } catch { $message = '' }
          $message = ($message -replace '\s+', ' ').Trim()
          if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
          $g = @{ Provider = $provider; Id = [int]$e.Id; Level = [int]$e.Level; Count = 0; First = $time; Last = $time; Message = $message }
          $groups[$key] = $g
          $order.Add($key)
        }
        $g.Count++
        $g.First = $time
      }
    } catch {
      $unreadable++
    }
  }
  $answer[[string]$s.Name] = @{ Error = $problem; Total = $total; Capped = ($events.Count -ge [int]$s.Max); Unreadable = $unreadable; Rows = $rows.ToArray()
                                Groups = @(foreach ($k in $order) { $groups[$k] }) }
}
$answer
'@

# Windows Update's last successful search and install (the WUA AutoUpdate results; UTC, shown in local time).
$script:ReportWuResultsCommand = @'
$results = (New-Object -ComObject 'Microsoft.Update.AutoUpdate').Results
$invariant = [Globalization.CultureInfo]::InvariantCulture
$stamp = { param($d) if ($d -is [datetime] -and $d.Year -gt 1601) { [datetime]::SpecifyKind($d, 'Utc').ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ss', $invariant) } else { '' } }
@{ LastSearch = (& $stamp $results.LastSearchSuccessDate); LastInstall = (& $stamp $results.LastInstallationSuccessDate) }
'@

# The disconnected (non-present) devices, counted by class.
$script:ReportGhostCountCommand = @'
$counts = @{}
foreach ($d in @(Get-PnpDevice | Where-Object { $_.Present -eq $false })) { $c = [string]$d.Class; if ($c -eq '') { $c = '(none)' }; $counts[$c] = 1 + [int]$counts[$c] }
@{ Items = @(foreach ($k in $counts.Keys) { @{ Class = $k; Count = $counts[$k] } }) }
'@

# The third-party drivers in the driver store (Get-WindowsDriver: ClassName is the INF's class, never localized).
$script:ReportDriversCommand = @'
$invariant = [Globalization.CultureInfo]::InvariantCulture
@{ Items = @(Get-WindowsDriver -Online | ForEach-Object {
  $date = ''
  if ($_.Date -is [datetime]) { $date = $_.Date.ToString('yyyy-MM-dd', $invariant) }
  @{ Driver = [string]$_.Driver; Original = [IO.Path]::GetFileName([string]$_.OriginalFileName); Provider = [string]$_.ProviderName
     Class = [string]$_.ClassName; Version = [string]$_.Version; Date = $date } }) }
'@

# Reliability Monitor's records of the last <DAYS> days (a WQL filter on TimeGenerated), at most 1000.
$script:ReportReliabilityCommand = @'
$since = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddDays(-<DAYS>))
$invariant = [Globalization.CultureInfo]::InvariantCulture
$rows = @(Get-CimInstance -ClassName Win32_ReliabilityRecords -Filter ("TimeGenerated > '{0}'" -f $since) -OperationTimeoutSec 240 | Select-Object -First 1000)
@{ Items = @(foreach ($r in $rows) {
  $message = ([string]$r.Message -replace '\s+', ' ').Trim()
  if ($message.Length -gt 200) { $message = $message.Substring(0, 200) }
  $time = ''
  if ($r.TimeGenerated -is [datetime]) { $time = $r.TimeGenerated.ToString('yyyy-MM-ddTHH:mm:ss', $invariant) }
  @{ Source = [string]$r.SourceName; EventId = [int]$r.EventIdentifier; Product = [string]$r.ProductName; Time = $time; Message = $message } }) }
'@

# The network as it is now: connection profiles, firewall profiles (the active store, group policy applied), the
# addresses in use, the default routes and the DNS servers in use. Each part on its own: one that fails is named in
# Errors, the others still answer.
$script:ReportNetStateCommand = @'
$errors = New-Object System.Collections.Generic.List[string]
$profiles = @(); $firewall = @(); $addresses = @(); $gateways = @(); $dns = @()
try { $profiles = @(Get-NetConnectionProfile | ForEach-Object { @{ Name = [string]$_.Name; Alias = [string]$_.InterfaceAlias; Category = [string]$_.NetworkCategory; Ipv4 = [string]$_.IPv4Connectivity; Ipv6 = [string]$_.IPv6Connectivity } }) } catch { $errors.Add('connection profiles: ' + $_.Exception.Message) }
try { $firewall = @(Get-NetFirewallProfile -PolicyStore ActiveStore | ForEach-Object { @{ Name = [string]$_.Name; Enabled = [string]$_.Enabled } }) } catch { $errors.Add('firewall profiles: ' + $_.Exception.Message) }
try { $addresses = @(Get-NetIPAddress | Where-Object { [string]$_.AddressState -eq 'Preferred' -and [string]$_.IPAddress -notin '127.0.0.1', '::1' } | ForEach-Object { @{ Alias = [string]$_.InterfaceAlias; Ip = [string]$_.IPAddress; Prefix = [int]$_.PrefixLength; Origin = [string]$_.PrefixOrigin } }) } catch { $errors.Add('addresses: ' + $_.Exception.Message) }
try { $gateways = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0', '::/0' -ErrorAction SilentlyContinue | ForEach-Object { @{ Alias = [string]$_.InterfaceAlias; NextHop = [string]$_.NextHop; Metric = [int]$_.RouteMetric } }) } catch { $errors.Add('default routes: ' + $_.Exception.Message) }
try { $dns = @(Get-DnsClientServerAddress | Where-Object { @($_.ServerAddresses).Count -gt 0 } | ForEach-Object { @{ Alias = [string]$_.InterfaceAlias; Servers = @(foreach ($a in $_.ServerAddresses) { [string]$a }) } }) } catch { $errors.Add('DNS servers: ' + $_.Exception.Message) }
@{ Profiles = $profiles; Firewall = $firewall; Addresses = $addresses; Gateways = $gateways; Dns = $dns; Errors = $errors.ToArray() }
'@

# The TCP connections counted by owning process (its name) and state (an enum name): no addresses.
$script:ReportTcpCommand = @'
$names = @{}
foreach ($p in @(Get-Process)) { $names[[int]$p.Id] = [string]$p.ProcessName }
$counts = @{}
foreach ($c in @(Get-NetTCPConnection)) {
  $name = [string]$names[[int]$c.OwningProcess]
  if ($name -eq '') { $name = 'pid ' + [int]$c.OwningProcess }
  $key = $name + '|' + [string]$c.State
  $counts[$key] = 1 + [int]$counts[$key]
}
@{ Items = @(foreach ($k in $counts.Keys) { $parts = $k -split '\|', 2; @{ Process = $parts[0]; State = $parts[1]; Count = $counts[$k] } }) }
'@

# The scheduled tasks outside \Microsoft\, by their programs only: an action's arguments are never read (they may
# hold tokens).
$script:ReportTasksCommand = @'
@{ Items = @(Get-ScheduledTask | Where-Object { -not ([string]$_.TaskPath).StartsWith('\Microsoft\', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 300 | ForEach-Object {
  @{ Name = [string]$_.TaskName; Path = [string]$_.TaskPath; State = [string]$_.State; Execute = @(foreach ($a in @($_.Actions)) { [string]$a.Execute }) } }) }
'@

$script:ReportAppxCommand = @'
@{ Items = @(Get-AppxPackage -AllUsers | Where-Object { -not $_.IsFramework } | ForEach-Object { @{ Name = [string]$_.Name; Version = [string]$_.Version; NonRemovable = [bool]$_.NonRemovable } }) }
'@

$script:ReportFeaturesCommand = @'
@{ Items = @(Get-WindowsOptionalFeature -Online | Where-Object { [string]$_.State -eq 'Enabled' } | ForEach-Object { [string]$_.FeatureName }) }
'@

$script:ReportPrintersCommand = @'
@{ Items = @(Get-Printer | ForEach-Object { @{ Name = [string]$_.Name; Driver = [string]$_.DriverName; Port = [string]$_.PortName; Shared = [bool]$_.Shared; Type = [string]$_.Type } }) }
'@

$script:ReportDefenderCommand = @'
$s = Get-MpComputerStatus
@{ RealTime = [bool]$s.RealTimeProtectionEnabled; AntivirusEnabled = [bool]$s.AntivirusEnabled; AMServiceEnabled = [bool]$s.AMServiceEnabled
   SignatureAge = [int]$s.AntivirusSignatureAge; Mode = [string]$s.AMRunningMode; Tamper = [bool]$s.IsTamperProtected; SignatureVersion = [string]$s.AntivirusSignatureVersion }
'@

# The local Administrators group by its SID (S-1-5-32-544), in a grandchild because the member lookups can stall (a
# domain laptop away from its domain controller; review M4). Get-LocalGroupMember fails on a group that holds an
# orphaned domain account: then ADSI (the WinNT provider) on the group's translated (localized) name. LocalError is
# Get-LocalGroupMember's message, for the log only.
$script:ReportAdminsCommand = @'
$source = 'Get-LocalGroupMember'
$localError = ''
$items = @()
try {
  $items = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | ForEach-Object { @{ Name = [string]$_.Name; Sid = [string]$_.SID; Source = [string]$_.PrincipalSource } })
} catch {
  $source = 'ADSI'
  $localError = [string]$_.Exception.Message
  $account = ([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value
  $group = [ADSI]('WinNT://./{0},group' -f ($account -split '\\')[-1])
  $items = @(foreach ($member in @($group.psbase.Invoke('Members'))) {
    $name = [string]$member.GetType().InvokeMember('Name', 'GetProperty', $null, $member, $null)
    $sid = ''
    try { $sid = (New-Object Security.Principal.SecurityIdentifier($member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $member, $null), 0)).Value } catch { $sid = '' }
    @{ Name = $name; Sid = $sid; Source = 'ADSI' } })
}
@{ Source = $source; LocalError = $localError; Items = $items }
'@

# Windows Update's ETW traces merged into a text log in raw\ (<P>: the file, as a literal).
$script:ReportWuLogCommand = @'
$null = Get-WindowsUpdateLog -LogPath <P>
@{ Done = $true }
'@

# --- Sections and sources ------------------------------------------------------------------------------------------

function New-ReportSection {
  # A new, empty section -Id: @{ Id; Title; Facts = [ordered]; Groups, Raw, Missing = lists; Items = [ordered] }.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][string]$Id)

  return @{
    Id      = $Id
    Title   = [string]$script:ReportSectionTitles[$Id]
    Facts   = [ordered]@{}
    Groups  = (New-Object System.Collections.Generic.List[string])
    Items   = [ordered]@{}
    Raw     = (New-Object System.Collections.Generic.List[string])
    Missing = (New-Object System.Collections.Generic.List[object])
  }
}

function Complete-ReportSection {
  # Private. The section with its lists as arrays (Groups and Raw [string[]], Missing an array), as the report keeps it.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Section)

  foreach ($name in 'Groups', 'Raw') {
    if ($Section[$name] -is [System.Collections.Generic.List[string]]) { $Section[$name] = [string[]]$Section[$name].ToArray() }
  }
  if ($Section['Missing'] -is [System.Collections.Generic.List[object]]) { $Section['Missing'] = $Section['Missing'].ToArray() }
  return $Section
}

# The reasons a source may be "not collected" for (review M11): fixed English codes, so a Hebrew PC's message never
# reaches the report as '????' and the AI reads the same words on every PC.
$script:ReportReasonPattern = '\A(timed out|failed|no result|no answer|output too large|access denied|not found|not supported|is a link|no system drive letter|no signed-in user|no SID for the user|not enough time left|not run: the report was stopped or ran out of time|exit 0x[0-9A-F]{8}|no file \(exit 0x[0-9A-F]{8}\))\z'

function ConvertTo-ReportReason {
  <#
  .SYNOPSIS
    Private, pure. Why a source was not collected, as one of the fixed English reasons ($script:ReportReasonPattern,
    review M11): -Why, or -Exception's message, when it already is one ('timed out' from a grandchild, a chip or a
    helper; '<file> is a link' is 'is a link'); else by -Exception's type (also its inner exceptions): access denied
    (UnauthorizedAccessException, SecurityException), not found (an item, file or folder), not supported
    (NotSupportedException and PlatformNotSupportedException), timed out (TimeoutException); else 'failed' ('no result'
    when there is nothing at all). Windows' and the tools' own text, localized on a Hebrew PC, never becomes a reason:
    Add-ReportMissing logs it.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Why, [AllowNull()][Exception]$Exception)

  foreach ($text in $Why, $(if ($null -ne $Exception) { $Exception.Message } else { '' })) {
    $candidate = ([string]$text).Trim()
    if ($candidate -ne '' -and $candidate -cmatch $script:ReportReasonPattern) { return $candidate }
    # This code's own refusals name the file: '<file> is a link' (V2-R13).
    if ($candidate -cmatch ' is a link\z') { return 'is a link' }
  }
  $e = $Exception
  while ($null -ne $e) {
    if ($e -is [UnauthorizedAccessException] -or $e -is [Security.SecurityException]) { return 'access denied' }
    if ($e -is [Management.Automation.ItemNotFoundException] -or $e -is [IO.FileNotFoundException] -or $e -is [IO.DirectoryNotFoundException]) { return 'not found' }
    if ($e -is [NotSupportedException]) { return 'not supported' }
    if ($e -is [TimeoutException]) { return 'timed out' }
    $e = $e.InnerException
  }
  if ($null -eq $Exception -and [string]::IsNullOrWhiteSpace($Why)) { return 'no result' }
  return 'failed'
}

function Add-ReportMissing {
  # A source of -Section that was not collected: @{ What (English); Why (ConvertTo-ReportReason of -Why and
  # -Exception: a fixed English reason) }, and a WARN in the log with the original text (ASCII, at most 300
  # characters). The report lists it and adds the INFO finding notCollected.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Section,
    [Parameter(Mandatory)][string]$What,
    [AllowNull()][AllowEmptyString()][string]$Why,
    [AllowNull()][Exception]$Exception
  )

  $reason = ConvertTo-ReportReason -Why $Why -Exception $Exception
  $Section['Missing'].Add(@{ What = $What; Why = $reason })
  $detail = ConvertTo-ScreenText -Text $(if ($null -ne $Exception) { $Exception.Message } else { $Why })
  if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
  Write-SetupLog -Level WARN -Message 'A report source was not collected' -Data @{ section = $Section['Id']; source = $What; reason = $reason; error = $detail }
}

function Invoke-ReportSource {
  <#
  .SYNOPSIS
    Private. Runs one source of a section (-Script fills the caller's section) and turns an exception into a Missing
    entry (-What), so one failing fact never loses its section. Returns what -Script returns.
  .DESCRIPTION
    -Script runs in a child scope of its caller: it fills hashtables it can see (the section) and returns values;
    a variable it assigns stays inside it.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Section,
    [Parameter(Mandatory)][string]$What,
    [Parameter(Mandatory)][scriptblock]$Script
  )

  try {
    & $Script
  } catch {
    Add-ReportMissing -Section $Section -What $What -Exception $_.Exception
  }
}

function Get-ReportCim {
  # Private. The instances of a CIM class (-Namespace, -Filter), bounded by -OperationTimeoutSec 30. Throws on failure.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ClassName,
    [string]$Namespace,
    [string]$Filter
  )

  $parameters = @{ ClassName = $ClassName; OperationTimeoutSec = 30; ErrorAction = 'Stop' }
  if (-not [string]::IsNullOrEmpty($Namespace)) { $parameters['Namespace'] = $Namespace }
  if (-not [string]::IsNullOrEmpty($Filter)) { $parameters['Filter'] = $Filter }
  @(Get-CimInstance @parameters)
}

function Get-ReportChild {
  # Private. A grandchild's Data (Invoke-ToolJsonChild, -StepTimeout), or $null with a Missing entry (-What) when it
  # failed or timed out.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][hashtable]$Section,
    [Parameter(Mandatory)][string]$What,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Command,
    [string]$StepTimeout = 'grandchild'
  )

  $child = Invoke-ToolJsonChild -Run $Run -Name $Name -Command $Command -StepTimeout $StepTimeout
  if (-not $child.Ok -or $child.Data -isnot [System.Collections.IDictionary]) {
    Add-ReportMissing -Section $Section -What $What -Why $child.Error
    return $null
  }
  return $child.Data
}

function New-ReportEventSpec {
  # Private. One event query of $script:ReportEventsCommand (see there).
  [CmdletBinding()]
  [OutputType([System.Collections.Specialized.OrderedDictionary])]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Log,
    [Parameter(Mandatory)][int]$Days,
    [Parameter(Mandatory)][int]$Max,
    [Parameter(Mandatory)][ValidateSet('groups', 'rows')][string]$Mode,
    [Parameter(Mandatory)][int]$Keep,
    [int[]]$Ids = @(),
    [int[]]$Levels = @(),
    [string]$Provider = '',
    [string[]]$Providers = @(),
    [string[]]$Names = @(),
    [int[]]$Props = @()
  )

  return [ordered]@{ Name = $Name; Label = $Label; Log = $Log; Days = $Days; Max = $Max; Mode = $Mode; Keep = $Keep; Ids = $Ids; Levels = $Levels
                     Provider = $Provider; Providers = $Providers; Names = $Names; Props = $Props }
}

function Get-ReportEvents {
  <#
  .SYNOPSIS
    Private. Runs -Specs (New-ReportEventSpec) in one grandchild (-Name, toolStep.events) and returns its answer: spec
    name -> @{ Error; Total; Rows; Groups }; $null (with a Missing entry -What) when the grandchild failed or timed out.
    A query that failed on its own is a Missing entry with its Label, and its answer is $null.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][hashtable]$Section,
    [Parameter(Mandatory)][string]$What,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][object[]]$Specs
  )

  $json = ConvertTo-Json -InputObject @($Specs) -Depth 5 -Compress
  $command = $script:ReportEventsCommand.Replace('<SPECS>', (ConvertTo-PowerShellLiteral -Text $json))
  $data = Get-ReportChild -Run $Run -Section $Section -What $What -Name $Name -Command $command -StepTimeout 'events'
  if ($null -eq $data) { return $null }
  foreach ($spec in $Specs) {
    $answer = $data[$spec['Name']]
    if ($answer -isnot [System.Collections.IDictionary]) {
      Add-ReportMissing -Section $Section -What $spec['Label'] -Why 'no answer'
      $data[$spec['Name']] = $null
    } elseif ([string]$answer['Error'] -ne '') {
      Add-ReportMissing -Section $Section -What $spec['Label'] -Why ([string]$answer['Error'])
      $data[$spec['Name']] = $null
    }
  }
  return $data
}

function Get-ReportEventRows {
  # Private. The Rows (or Groups) of one answer of Get-ReportEvents, as an array (none for a failed query).
  [CmdletBinding()]
  param([AllowNull()]$Events, [Parameter(Mandatory)][string]$Name, [ValidateSet('Rows', 'Groups')][string]$Part = 'Rows')

  if ($Events -isnot [System.Collections.IDictionary]) { return , @() }
  $answer = $Events[$Name]
  if ($answer -isnot [System.Collections.IDictionary]) { return , @() }
  return , @(foreach ($r in @($answer[$Part])) { if ($r -is [System.Collections.IDictionary]) { $r } })
}

function Get-ReportEventTotal {
  <#
  .SYNOPSIS
    Private. How many events one query of Get-ReportEvents counted (-Spec, New-ReportEventSpec): @{ Count; Capped;
    Text }. Count is its Total (at least -Least: the rows the caller kept). Capped: the query read its Max events (the
    grandchild's Capped, or a Total at Max), so there may be more: Text is '<n>+' (review M6), else '<n>'.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Events, [Parameter(Mandatory)][System.Collections.IDictionary]$Spec, [int]$Least = 0)

  $count = 0
  $capped = $false
  if ($Events -is [System.Collections.IDictionary] -and $Events[$Spec['Name']] -is [System.Collections.IDictionary]) {
    $answer = $Events[$Spec['Name']]
    $total = ConvertTo-ReportNumber -Value $answer['Total']
    if ($null -ne $total) { $count = [int]$total }
    $capped = ($answer['Capped'] -eq $true) -or ($count -ge [int]$Spec['Max'])
  }
  if ($Least -gt $count) { $count = $Least }
  return @{ Count = $count; Capped = $capped; Text = $(if ($capped) { '{0}+' -f $count } else { [string]$count }) }
}

function Invoke-ReportNative {
  <#
  .SYNOPSIS
    Private. A tool that only feeds raw_<stamp>\ (Full), bounded by toolStep (-StepTimeout, 'native' by default). With
    -OutputName its console output goes to raw\<name>-<time>.txt; else it writes -File in raw\ itself. The file's name
    goes into the section's Raw; a timeout, a tool that could not run or no file is a Missing entry (-What). Nothing
    reads what it wrote; its exit code is only logged.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][hashtable]$Section,
    [Parameter(Mandatory)][string]$What,
    [Parameter(Mandatory)][string]$FilePath,
    [AllowEmptyString()][string]$ArgumentList = '',
    [string]$OutputName,
    [string]$File,
    [string]$StepTimeout = 'native'
  )

  try {
    $raw = Get-ToolReportRawDir -Run $Run
    if (-not [string]::IsNullOrEmpty($OutputName)) {
      $result = Invoke-ToolNative -Run $Run -FilePath $FilePath -ArgumentList $ArgumentList -StepTimeout $StepTimeout -OutputName $OutputName -OutputFolder $raw
      $path = [string]$result.OutputPath
    } else {
      $result = Invoke-ToolNative -Run $Run -FilePath $FilePath -ArgumentList ($ArgumentList.Replace('<RAW>', $raw)) -StepTimeout $StepTimeout
      $path = [IO.Path]::Combine($raw, $File)
    }
    if ($result.TimedOut) {
      Add-ReportMissing -Section $Section -What $What -Why 'timed out'
      return
    }
    if ($path -ne '' -and [IO.File]::Exists($path)) {
      $Section['Raw'].Add([IO.Path]::GetFileName($path))
      if ($result.ExitCode -ne 0) { Write-SetupLog -Message 'A raw report tool ended with an exit code' -Data @{ tool = $What; exitCode = (Format-ToolExitCode -ExitCode $result.ExitCode) } }
    } else {
      Add-ReportMissing -Section $Section -What $What -Why ('no file (exit {0})' -f (Format-ToolExitCode -ExitCode $result.ExitCode))
    }
  } catch {
    Add-ReportMissing -Section $Section -What $What -Exception $_.Exception
  }
}

function Get-ReportInternet {
  <#
  .SYNOPSIS
    Private. The internet check (Test-ToolInternet: TCP 443, HTTPS and the captive-portal probe, ruling RD-R11), run
    once per report: $Run.Data.Internet = @{ Tcp; Https; Probe; ClockOffsetSeconds; Clock } (section 09 reads it, so a
    Quick report makes one connectivity test). A check that throws is a Missing entry of -Section and $null.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][hashtable]$Section)

  if ($Run.Data.ContainsKey('Internet')) { return $Run.Data['Internet'] }
  $value = $null
  try {
    $check = Test-ToolInternet -Config $Run.Config
    if ($check -is [System.Collections.IDictionary]) {
      $value = @{ Tcp = ($check['Tcp'] -eq $true); Https = ($check['Https'] -eq $true); Probe = [string]$check['Probe']
                  ClockOffsetSeconds = (ConvertTo-ReportNumber -Value $check['ClockOffsetSeconds']); Clock = ($check['Clock'] -eq $true) }
    }
  } catch {
    Add-ReportMissing -Section $Section -What 'Internet check' -Exception $_.Exception
  }
  $Run.Data['Internet'] = $value
  return $value
}

function Get-ReportUser {
  <#
  .SYNOPSIS
    Private. The user signed in at the console (Get-SignedInUserName) and that account's SID (Get-ToolUserSid): its own
    hive, HKEY_USERS\<SID>, is read; never the elevated process's HKCU, which may be another account's (review I-12).
    @{ Name; Sid; Error (a fixed reason, ConvertTo-ReportReason) }, read once per run ($Run.Data.ReportUser; it stays
    out of result.json). The sections keep the SID as Items.SignedInSid (review M3: the privacy-safe copy masks it).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $known = $Run.Data['ReportUser']
  if ($known -is [System.Collections.IDictionary]) { return $known }
  $user = @{ Name = ''; Sid = ''; Error = '' }
  try {
    $user['Name'] = ([string](Get-SignedInUserName)).Trim()
    if ($user['Name'] -eq '') {
      $user['Error'] = 'no signed-in user'
    } else {
      $sid = [string](Get-ToolUserSid -Run $Run -UserName $user['Name'])
      if ($sid -match '^S-1-[0-9]+(-[0-9]+)+\z') { $user['Sid'] = $sid } else { $user['Error'] = 'no SID for the user' }
    }
  } catch {
    $user['Error'] = ConvertTo-ReportReason -Exception $_.Exception
    Write-SetupLog -Level WARN -Message 'The signed-in user could not be read for the report' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  $Run.Data['ReportUser'] = $user
  return $user
}

function Read-ToolRegistryKey {
  # Seam. Every value of one registry key (name -> data), or $null when the key does not exist; throws when it cannot
  # be read. Never used on a key that may hold a secret (Winlogon's values are read one by one, by name).
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return $null }
  $key = Get-Item -LiteralPath $Path -ErrorAction Stop
  $values = @{}
  foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) }
  return $values
}

function Read-ToolRegistrySubkeys {
  # Seam. The subkeys of a registry key, each @{ Name (its leaf); Values (name -> data) }, as one array (empty when the
  # key does not exist); throws when it cannot be read. Assign the result before iterating it.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return , @() }
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($key in @(Get-ChildItem -LiteralPath $Path -ErrorAction Stop)) {
    $values = @{}
    foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) }
    $rows.Add(@{ Name = [string]$key.PSChildName; Values = $values })
  }
  return , $rows.ToArray()
}

function Get-ToolCommandExecutable {
  <#
  .SYNOPSIS
    The program of a command line, never its arguments (a task's, a service's or a startup item's arguments may hold
    tokens): the quoted part when it starts with a quote; else, when it starts like a path (a drive, \\ or an
    %variable%), up to the first .exe, .com, .bat, .cmd, .ps1, .vbs, .js, .dll, .msc or .scr (an unquoted path may
    hold spaces), unless that part holds a switch (' -' or ' /': then the extension belongs to an argument; review
    I1); else its first word. Pure.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Command)

  $text = ([string]$Command).Trim()
  if ($text -eq '') { return '' }
  if ($text.StartsWith('"')) {
    $end = $text.IndexOf('"', 1)
    if ($end -gt 1) { return $text.Substring(1, $end - 1) }
    return $text.Trim('"')
  }
  $match = [regex]::Match($text, '^((?:[A-Za-z]:\\|\\\\|%[^%\s]+%).*?\.(exe|com|bat|cmd|ps1|vbs|js|dll|msc|scr))(\s|,|$)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($match.Success -and $match.Groups[1].Value -notmatch '\s[-/]') { return $match.Groups[1].Value }
  return ($text -split '\s+', 2)[0]
}

function Format-ReportGB {
  # Private, pure. Bytes as '<n.n> GB', or '<n> MB' under 1 GB (invariant).
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Bytes)

  $number = ConvertTo-ReportNumber -Value $Bytes
  if ($null -eq $number) { return '?' }
  if ($number -lt 1GB) { return ('{0} MB' -f (Format-ReportNumber -Value ($number / 1MB) -Format '0')) }
  return ('{0} GB' -f (Format-ReportNumber -Value ($number / 1GB) -Format '0.0'))
}

function ConvertFrom-ReportWmiDate {
  # Private. A CIM DMTF date ('yyyyMMddHHmmss.ffffff+zzz') as a local [datetime], or $null.
  [CmdletBinding()]
  param([AllowNull()]$Text)

  if ($Text -is [datetime]) { return $Text }
  try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Text) } catch { return $null }
}

function Get-ReportDays {
  # Private. A whole number of days from repair.thresholds.<Name>, else -Default.
  [CmdletBinding()]
  [OutputType([int])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Default)

  return [int](Get-ToolRepairNumber -Config $Run.Config -Path 'thresholds', $Name -Default $Default)
}

# --- 01 System -----------------------------------------------------------------------------------------------------

function Get-ReportData01 {
  <#
  .SYNOPSIS
    Section 01, System: Windows from the registry (the name corrected by the build: the registry says Windows 10 on
    Windows 11), the computer, OS and BIOS (CIM), uptime, the clock offset (the report's one internet check), the
    servicing restart signals, .NET 4 and activation (grandchild activation). Full: systeminfo to raw.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '01'
  try {
    $nt = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $null = Invoke-ReportSource -Section $s -What 'Windows version (registry)' -Script {
      $build = ConvertTo-ReportNumber -Value (Get-RebootRegistryValue -Path $nt -Name 'CurrentBuild')
      if ($null -eq $build -or $build -le 0) { throw 'no build number in the registry' }
      $product = ConvertTo-ToolDisplayText -Text (Get-RebootRegistryValue -Path $nt -Name 'ProductName') -MaxLength 300
      if ($build -ge 22000) { $product = $product -replace 'Windows 10', 'Windows 11' }
      $buildText = Format-ReportNumber -Value $build -Format '0'
      $ubr = ConvertTo-ReportNumber -Value (Get-RebootRegistryValue -Path $nt -Name 'UBR')
      if ($null -ne $ubr) { $buildText += '.' + (Format-ReportNumber -Value $ubr -Format '0') }
      $s.Facts['Windows'] = ('{0} {1}' -f $product, (ConvertTo-ToolDisplayText -Text (Get-RebootRegistryValue -Path $nt -Name 'DisplayVersion') -MaxLength 300)).Trim()
      $s.Facts['Build'] = $buildText
      $s.Facts['Edition'] = ConvertTo-ToolDisplayText -Text (Get-RebootRegistryValue -Path $nt -Name 'EditionID') -MaxLength 300
      $installed = ConvertTo-ReportNumber -Value (Get-RebootRegistryValue -Path $nt -Name 'InstallDate')
      if ($null -ne $installed -and $installed -gt 0) { $s.Facts['Installed'] = Format-ReportDate -When ([DateTimeOffset]::FromUnixTimeSeconds([long]$installed).LocalDateTime) }
      $s.Items['OsBuild'] = [int]$build
      $s.Items['OsBuildText'] = $buildText
    }
    $null = Invoke-ReportSource -Section $s -What 'Operating system (CIM)' -Script {
      $os = @(Get-ReportCim -ClassName 'Win32_OperatingSystem') | Select-Object -First 1
      if ($null -eq $os) { throw 'no answer' }
      $s.Facts['Language'] = (@(foreach ($l in @($os.MUILanguages)) { [string]$l }) -join ', ')
      $s.Facts['Architecture'] = ConvertTo-ToolDisplayText -Text $os.OSArchitecture -MaxLength 300
      if ($os.LastBootUpTime -is [datetime]) {
        $days = ((Get-Date) - $os.LastBootUpTime).TotalDays
        $s.Facts['Last boot'] = Format-ReportDate -When $os.LastBootUpTime
        $s.Facts['Uptime'] = '{0} days' -f (Format-ReportNumber -Value $days -Format '0.0')
        $s.Items['UptimeDays'] = [math]::Round($days, 1)
      }
    }
    $null = Invoke-ReportSource -Section $s -What 'Computer (CIM)' -Script {
      $cs = @(Get-ReportCim -ClassName 'Win32_ComputerSystem') | Select-Object -First 1
      if ($null -eq $cs) { throw 'no answer' }
      $s.Facts['Computer'] = ConvertTo-ToolDisplayText -Text $cs.Name -MaxLength 300
      $s.Facts['Model'] = ('{0} {1}' -f (ConvertTo-ToolDisplayText -Text $cs.Manufacturer -MaxLength 300), (ConvertTo-ToolDisplayText -Text $cs.Model -MaxLength 300)).Trim()
      if ($cs.PartOfDomain -eq $true) {
        $s.Facts['Domain'] = '{0} (domain)' -f (ConvertTo-ToolDisplayText -Text $cs.Domain -MaxLength 300)
        # The domain's own name, for the privacy-safe copy (review M3); a workgroup has none.
        $s.Items['Domain'] = ([string]$cs.Domain).Trim()
      } else {
        $s.Facts['Domain'] = '{0} (workgroup)' -f (ConvertTo-ToolDisplayText -Text $cs.Workgroup -MaxLength 300)
        # A workgroup's own name (a family's or a firm's), for the privacy-safe copy (Task 9).
        $s.Items['Workgroup'] = ([string]$cs.Workgroup).Trim()
      }
      $s.Items['ComputerName'] = [string]$cs.Name
    }
    $null = Invoke-ReportSource -Section $s -What 'BIOS (CIM)' -Script {
      $bios = @(Get-ReportCim -ClassName 'Win32_BIOS') | Select-Object -First 1
      if ($null -eq $bios) { throw 'no answer' }
      $s.Facts['Serial'] = ConvertTo-ToolDisplayText -Text $bios.SerialNumber -MaxLength 300
      $s.Items['Serial'] = ([string]$bios.SerialNumber).Trim()
    }
    $identity = $Run.Args['Identity']
    if ($identity -is [System.Collections.IDictionary]) { $s.Items['BiosUuid'] = [string]$identity['BiosUuid'] }

    $internet = Get-ReportInternet -Run $Run -Section $s
    if ($internet -is [System.Collections.IDictionary] -and $null -ne $internet['ClockOffsetSeconds']) {
      $minutes = [double]$internet['ClockOffsetSeconds'] / 60
      $s.Facts['Clock offset'] = '{0} min (against Microsoft''s Date header; positive: this PC is ahead)' -f (Format-ReportNumber -Value $minutes -Format '+0.0;-0.0;0.0')
      $s.Items['ClockOffsetMinutes'] = [math]::Round($minutes, 1)
    } elseif ($internet -is [System.Collections.IDictionary]) {
      $s.Facts['Clock offset'] = 'not measured (no answer from Microsoft)'
    }
    $null = Invoke-ReportSource -Section $s -What 'Pending restart (registry)' -Script {
      $signals = Get-ServicingRebootSignals
      $set = @(foreach ($n in 'CbsRebootPending', 'CbsPackagesPending', 'PendingXml', 'WuRebootRequired') { if ($signals[$n] -eq $true) { $n } })
      $notes = @(foreach ($n in 'PendingFileRename', 'ComputerRenamePending') { if ($signals[$n] -eq $true) { $n } })
      $s.Facts['Servicing restart'] = $(if ($set.Count -gt 0) { $set -join ', ' } else { 'none' })
      if ($notes.Count -gt 0) { $s.Facts['Other pending'] = ($notes -join ', ') + ' (does not block repairs)' }
      $s.Items['RestartSignals'] = [string[]]$set
    }
    $release = ConvertTo-ReportNumber -Value (Get-RebootRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name 'Release')
    if ($null -ne $release) {
      $dotNet = '4.x'
      foreach ($pair in @(@(533320, '4.8.1'), @(528040, '4.8'), @(461808, '4.7.2'), @(461308, '4.7.1'), @(460798, '4.7'), @(394802, '4.6.2'))) {
        if ($release -ge $pair[0]) { $dotNet = $pair[1]; break }
      }
      $s.Facts['.NET Framework'] = '{0} ({1})' -f $dotNet, (Format-ReportNumber -Value $release -Format '0')
    }
    $activation = Get-ToolActivation -Run $Run
    if ($activation -ceq 'Unknown') {
      Add-ReportMissing -Section $s -What 'Activation' -Why (Get-ToolCheckError -Run $Run -Name 'activation')
    } else {
      $s.Facts['Activation'] = $activation
      $s.Items['Activation'] = $activation
    }
    if (-not $Quick) { Invoke-ReportNative -Run $Run -Section $s -What 'systeminfo' -FilePath (Get-ToolSystemTool -Name 'systeminfo.exe') -OutputName 'systeminfo' }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 02 Hardware ---------------------------------------------------------------------------------------------------

function Get-ReportData02 {
  <#
  .SYNOPSIS
    Section 02, Hardware (CIM): BIOS, board, CPU, the RAM modules' sum, the graphics (display.inf is Windows' basic
    display driver: no vendor driver), the batteries (root\wmi full and design capacity, per battery), Secure Boot
    (Confirm-SecureBootUEFI; legacy BIOS = not supported), the TPM and VBS. Full: the monitors (WmiMonitorID).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '02'
  try {
    $null = Invoke-ReportSource -Section $s -What 'BIOS (CIM)' -Script {
      $bios = @(Get-ReportCim -ClassName 'Win32_BIOS') | Select-Object -First 1
      if ($null -eq $bios) { throw 'no answer' }
      $date = ''
      if ($bios.ReleaseDate -is [datetime]) { $date = ' ({0})' -f $bios.ReleaseDate.ToString('dd/MM/yyyy', [Globalization.CultureInfo]::InvariantCulture) }
      $s.Facts['BIOS'] = ('{0} {1}{2}' -f (ConvertTo-ToolDisplayText -Text $bios.Manufacturer -MaxLength 300), (ConvertTo-ToolDisplayText -Text $bios.SMBIOSBIOSVersion -MaxLength 300), $date).Trim()
    }
    $null = Invoke-ReportSource -Section $s -What 'Board (CIM)' -Script {
      $board = @(Get-ReportCim -ClassName 'Win32_BaseBoard') | Select-Object -First 1
      if ($null -eq $board) { throw 'no answer' }
      $s.Facts['Board'] = ('{0} {1}' -f (ConvertTo-ToolDisplayText -Text $board.Manufacturer -MaxLength 300), (ConvertTo-ToolDisplayText -Text $board.Product -MaxLength 300)).Trim()
      $s.Items['BoardSerial'] = ([string]$board.SerialNumber).Trim()
    }
    $null = Invoke-ReportSource -Section $s -What 'CPU (CIM)' -Script {
      $cpus = @(Get-ReportCim -ClassName 'Win32_Processor')
      if ($cpus.Count -eq 0) { throw 'no answer' }
      $text = '{0} ({1} cores, {2} threads)' -f (ConvertTo-ToolDisplayText -Text $cpus[0].Name -MaxLength 300), [int]$cpus[0].NumberOfCores, [int]$cpus[0].NumberOfLogicalProcessors
      if ($cpus.Count -gt 1) { $text += ' x{0}' -f $cpus.Count }
      $s.Facts['CPU'] = $text
    }
    $null = Invoke-ReportSource -Section $s -What 'Memory modules (CIM)' -Script {
      $modules = @(Get-ReportCim -ClassName 'Win32_PhysicalMemory')
      if ($modules.Count -eq 0) { throw 'no memory modules in the answer' }
      [double]$bytes = 0
      foreach ($m in $modules) { $bytes += [double]$m.Capacity }
      $gb = [math]::Round($bytes / 1GB, 1)
      $speeds = @($modules | ForEach-Object { [int]$_.Speed } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
      $speedText = ''
      if ($speeds.Count -gt 0) { $speedText = ', {0} MHz' -f ($speeds -join '/') }
      $s.Facts['RAM'] = '{0} GB ({1} modules{2})' -f (Format-ReportNumber -Value $gb), $modules.Count, $speedText
      $s.Items['RamGB'] = $gb
      $s.Items['RamSerials'] = [string[]]@(foreach ($m in $modules) { $serial = ([string]$m.SerialNumber).Trim(); if ($serial -ne '') { $serial } })
    }
    $null = Invoke-ReportSource -Section $s -What 'Graphics (CIM)' -Script {
      $cards = @(Get-ReportCim -ClassName 'Win32_VideoController')
      $basic = $false
      foreach ($card in $cards) {
        $inf = [string]$card.InfFilename
        if ([string]::Equals($inf, 'display.inf', [StringComparison]::OrdinalIgnoreCase)) { $basic = $true }
        if ($cards.Count -gt 1 -or $basic) { $s.Groups.Add(('GPU: {0}, driver {1} ({2})' -f (ConvertTo-ToolDisplayText -Text $card.Name -MaxLength 300), (ConvertTo-ToolDisplayText -Text $card.DriverVersion -MaxLength 300), (ConvertTo-ToolDisplayText -Text $inf -MaxLength 300))) }
      }
      if ($cards.Count -gt 0) { $s.Facts['GPU'] = '{0} (driver {1})' -f (ConvertTo-ToolDisplayText -Text $cards[0].Name -MaxLength 300), (ConvertTo-ToolDisplayText -Text $cards[0].DriverVersion -MaxLength 300) }
      $s.Items['BasicDisplay'] = $basic
    }
    if (-not $Quick) {
      $null = Invoke-ReportSource -Section $s -What 'Monitors (CIM)' -Script {
        $decode = { param($codes) -join @(foreach ($c in @($codes)) { if ($null -ne $c -and [int]$c -gt 0) { [char][int]$c } }) }
        $serials = New-Object System.Collections.Generic.List[string]
        foreach ($m in @(Get-ReportCim -Namespace 'root\wmi' -ClassName 'WmiMonitorID')) {
          $serial = (& $decode $m.SerialNumberID).Trim()
          if ($serial -ne '') { $serials.Add($serial) }
          $s.Groups.Add(('Monitor: {0} {1}, year {2}' -f (& $decode $m.ManufacturerName), (& $decode $m.UserFriendlyName), [int]$m.YearOfManufacture))
        }
        $s.Items['MonitorSerials'] = [string[]]$serials.ToArray()
      }
    }
    $null = Invoke-ReportSource -Section $s -What 'Battery (CIM)' -Script {
      $batteries = @(Get-ReportCim -ClassName 'Win32_Battery')
      if ($batteries.Count -eq 0) {
        $s.Facts['Battery'] = 'none'
        return
      }
      $static = @(Get-ReportCim -Namespace 'root\wmi' -ClassName 'BatteryStaticData')
      $full = @(Get-ReportCim -Namespace 'root\wmi' -ClassName 'BatteryFullChargedCapacity')
      $texts = New-Object System.Collections.Generic.List[string]
      $serials = New-Object System.Collections.Generic.List[string]
      $worst = $null
      foreach ($b in $static) {
        $design = ConvertTo-ReportNumber -Value $b.DesignedCapacity
        $now = $null
        foreach ($f in $full) { if ([string]$f.InstanceName -eq [string]$b.InstanceName) { $now = ConvertTo-ReportNumber -Value $f.FullChargedCapacity } }
        $serial = ([string]$b.SerialNumber).Trim()
        if ($serial -ne '') { $serials.Add($serial) }
        if ($null -eq $design -or $design -le 0 -or $null -eq $now) { continue }
        $wear = [math]::Max(0, [math]::Round(100 - ($now * 100 / $design)))
        if ($null -eq $worst -or $wear -gt $worst) { $worst = $wear }
        $texts.Add(('wear {0}% (full {1} / design {2} mWh)' -f $wear, (Format-ReportNumber -Value $now -Format '0'), (Format-ReportNumber -Value $design -Format '0')))
      }
      $s.Facts['Battery'] = $(if ($texts.Count -gt 0) { $texts.ToArray() -join '; ' } else { 'present, capacity not reported' })
      if ($null -ne $worst) { $s.Items['BatteryWear'] = $worst }
      $s.Items['BatterySerials'] = [string[]]$serials.ToArray()
    }
    $secure = 'Unknown'
    try {
      $on = Confirm-SecureBootUEFI -ErrorAction Stop
      $secure = $(if ($on -eq $true) { 'On' } else { 'Off' })
    } catch {
      $exception = $_.Exception
      if ($exception -is [PlatformNotSupportedException] -or $exception.InnerException -is [PlatformNotSupportedException]) { $secure = 'Unsupported' }
      else { Add-ReportMissing -Section $s -What 'Secure Boot' -Exception $exception }
    }
    if ($secure -cne 'Unknown') {
      $s.Facts['Secure Boot'] = $(if ($secure -ceq 'Unsupported') { 'not supported (legacy BIOS)' } else { $secure })
      $s.Items['SecureBoot'] = $secure
    }
    $null = Invoke-ReportSource -Section $s -What 'TPM (CIM)' -Script {
      $tpm = @(Get-ReportCim -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm') | Select-Object -First 1
      if ($null -eq $tpm) {
        $s.Facts['TPM'] = 'none'
        $s.Items['TpmReady'] = $false
        return
      }
      $ready = ($tpm.IsEnabled_InitialValue -eq $true) -and ($tpm.IsActivated_InitialValue -eq $true)
      $version = ConvertTo-ToolDisplayText -Text ((([string]$tpm.SpecVersion) -split ',')[0]) -MaxLength 300
      $s.Facts['TPM'] = '{0} ({1})' -f $(if ($ready) { 'ready' } else { 'not ready' }), $version
      $s.Items['TpmReady'] = $ready
    }
    $null = Invoke-ReportSource -Section $s -What 'Virtualization-based security (CIM)' -Script {
      $guard = @(Get-ReportCim -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard') | Select-Object -First 1
      if ($null -eq $guard) { throw 'no answer' }
      $status = @{ 0 = 'off'; 1 = 'enabled, not running'; 2 = 'running' }[[int]$guard.VirtualizationBasedSecurityStatus]
      if ($null -eq $status) { $status = 'status ' + [int]$guard.VirtualizationBasedSecurityStatus }
      $names = @{ 1 = 'Credential Guard'; 2 = 'HVCI'; 3 = 'System Guard'; 4 = 'SMM protection' }
      $running = @(foreach ($n in @($guard.SecurityServicesRunning)) { if ($null -ne $n -and [int]$n -gt 0) { $(if ($names.ContainsKey([int]$n)) { $names[[int]$n] } else { 'service ' + [int]$n }) } })
      $s.Facts['VBS'] = $(if ($running.Count -gt 0) { '{0} ({1})' -f $status, ($running -join ', ') } else { $status })
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 03 Storage ----------------------------------------------------------------------------------------------------

function Get-ReportData03 {
  <#
  .SYNOPSIS
    Section 03, Storage: the physical disks with their serials and counters (grandchildren diskInfo and diskCounters,
    toolStep.disks; the system disk is judged, ruling RD-R10, every disk listed), the disk events of the system disk
    (grandchild diskEvents, toolStep.events, split by Get-ToolDiskEventSplit; review M4), the volumes (Win32_Volume:
    free space, dirty bit), TRIM, BitLocker's protection and
    protector types, the page file and the restore points. Full: the read-only volume state (Get-Volume, the Health
    check's; ruling RD-R12: the report never scans) and vssadmin's lists to raw.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '03'
  try {
    $letter = Get-ToolSystemLetter
    $drive = $(if ($letter -ne '') { $letter + ':' } else { '' })
    $s.Items['SystemDrive'] = $drive
    $systemDisks = [int[]]@()
    $info = $null
    if ($letter -ne '') {
      $info = Get-ReportChild -Run $Run -Section $s -What 'Physical disks' -Name 'diskInfo' -Command ($script:ReportDiskInfoCommand.Replace('<L>', $letter)) -StepTimeout 'disks'
    } else {
      Add-ReportMissing -Section $s -What 'Physical disks' -Why 'no system drive letter'
    }
    if ($null -ne $info) {
      $systemDisks = [int[]]@(foreach ($n in @($info['SystemDisks'])) { $v = ConvertTo-ReportNumber -Value $n; if ($null -ne $v) { [int]$v } })
      $counters = @{}
      $answer = Get-ReportChild -Run $Run -Section $s -What 'Disk counters' -Name 'diskCounters' -Command $script:ReportDiskCountersCommand -StepTimeout 'disks'
      if ($null -ne $answer) { foreach ($c in @($answer['Items'])) { if ($c -is [System.Collections.IDictionary]) { $counters[[string]$c['DeviceId']] = $c } } }
      $rows = New-Object System.Collections.Generic.List[object]
      $healthRank = @{ Unhealthy = 3; Warning = 2; Healthy = 0 }
      $systemHealth = ''
      $worstRank = -1
      foreach ($d in @($info['Items'])) {
        if ($d -isnot [System.Collections.IDictionary]) { continue }
        $number = ConvertTo-ReportNumber -Value $d['DeviceId']
        $isSystem = ($null -ne $number -and $systemDisks -contains [int]$number)
        $c = $counters[[string]$d['DeviceId']]
        if ($c -isnot [System.Collections.IDictionary]) { $c = @{} }
        $row = [ordered]@{
          Number = $(if ($null -ne $number) { [int]$number } else { $null }); System = $isSystem; Model = (ConvertTo-ToolDisplayText -Text $d['Model'] -MaxLength 100)
          Serial = ([string]$d['Serial']).Trim(); Media = [string]$d['Media']; Bus = [string]$d['Bus']
          SizeGB = [math]::Round([double](ConvertTo-ReportNumber -Value $d['Size']) / 1GB, 1); Health = [string]$d['Health']
          Wear = (ConvertTo-ReportNumber -Value $c['Wear']); Temperature = (ConvertTo-ReportNumber -Value $c['Temperature'])
          ReadErrors = (ConvertTo-ReportNumber -Value $c['ReadErrors']); WriteErrors = (ConvertTo-ReportNumber -Value $c['WriteErrors'])
          PowerOnHours = (ConvertTo-ReportNumber -Value $c['PowerOnHours'])
        }
        $rows.Add($row)
        $state = $row.Health
        if ($null -ne $row.Wear) { $state += ', wear {0}%' -f (Format-ReportNumber -Value $row.Wear -Format '0') }
        if ($null -ne $row.Temperature) { $state += ', {0} C' -f (Format-ReportNumber -Value $row.Temperature -Format '0') }
        $text = 'Disk {0}{1}: {2}, {3}, {4}, {5} GB, {6}' -f $row.Number, $(if ($isSystem) { ' (system)' } else { '' }), $row.Model, $row.Media, $row.Bus,
          (Format-ReportNumber -Value $row.SizeGB -Format '0.0'), $state
        if ($null -ne $row.ReadErrors -or $null -ne $row.WriteErrors) { $text += ', uncorrected errors {0}/{1}' -f (Format-ReportNumber -Value $row.ReadErrors -Format '0'), (Format-ReportNumber -Value $row.WriteErrors -Format '0') }
        if ($null -ne $row.PowerOnHours) { $text += ', {0} h powered on' -f (Format-ReportNumber -Value $row.PowerOnHours -Format '0') }
        $s.Groups.Add($text)
        if ($isSystem) {
          $rank = $healthRank[$row.Health]
          if ($null -eq $rank) { $rank = 1 }
          if ($rank -gt $worstRank) { $worstRank = $rank; $systemHealth = $row.Health }
          $s.Items['SystemDisk'] = $(if ([string]$s.Items['SystemDisk'] -ne '') { [string]$s.Items['SystemDisk'] + ', ' + $row.Model } else { $row.Model })
          foreach ($pair in @(@('Wear', $row.Wear), @('Temperature', $row.Temperature))) {
            if ($null -ne $pair[1] -and ($null -eq $s.Items[$pair[0]] -or $pair[1] -gt $s.Items[$pair[0]])) { $s.Items[$pair[0]] = $pair[1] }
          }
          if ($null -ne $row.ReadErrors -or $null -ne $row.WriteErrors) {
            $sum = [double]$row.ReadErrors + [double]$row.WriteErrors
            $s.Items['DiskErrors'] = [double]$s.Items['DiskErrors'] + $sum
          }
          $fact = '{0} ({1}, {2}), {3}' -f $row.Model, $row.Media, $row.Bus, $state
          $s.Facts['System disk'] = $(if ($s.Facts.Contains('System disk')) { [string]$s.Facts['System disk'] + '; ' + $fact } else { $fact })
        }
      }
      $s.Items['Disks'] = $rows.ToArray()
      if ($systemHealth -ne '') { $s.Items['DiskHealth'] = $systemHealth }
    }
    # The disk events (spec 5, ruling RD-R10) in a grandchild (review M4: Get-WinEvent can stall), split here.
    $diskDays = Get-ReportDays -Run $Run -Name 'diskEventDays' -Default 30
    $diskSpec = New-ReportEventSpec -Name 'disk' -Label 'Disk events' -Log 'System' -Ids @(7, 51, 153, 55) -Providers @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs') -Days $diskDays `
      -Max 5000 -Mode rows -Keep 5000 -Props @(0)
    $diskEvents = Get-ReportEvents -Run $Run -Section $s -What 'Disk events' -Name 'diskEvents' -Specs @($diskSpec)
    if ($null -ne $diskEvents -and $null -ne $diskEvents['disk']) {
      $rows = @(foreach ($r in (Get-ReportEventRows -Events $diskEvents -Name 'disk')) { @{ Provider = [string]$r['Provider']; Id = $r['Id']; First = [string]@($r['Props'])[0] } })
      $split = Get-ToolDiskEventSplit -Events $rows -SystemDisks $systemDisks -SystemDrive $drive
      $read = Get-ReportEventTotal -Events $diskEvents -Spec $diskSpec
      $s.Items['DiskEvents'] = [string[]]@($split['Ids'])
      $s.Facts['Disk events'] = '{0} on the system disk, {1} elsewhere ({2} days: disk 7, 51, 153, NTFS 55{3})' -f [int]$split['Count'], [int]$split['Other'], $diskDays,
        $(if ($read['Capped']) { '; the newest {0} read' -f $diskSpec['Max'] } else { '' })
    }
    $null = Invoke-ReportSource -Section $s -What 'Volumes (CIM)' -Script {
      foreach ($v in @(Get-ReportCim -ClassName 'Win32_Volume')) {
        $name = [string]$v.DriveLetter
        if ($name -eq '') { continue }
        $label = ConvertTo-ToolDisplayText -Text $v.Label -MaxLength 64
        $dirty = $(if ($v.DirtyBitSet -eq $true) { 'yes' } elseif ($v.DirtyBitSet -eq $false) { 'no' } else { 'unknown' })
        $s.Groups.Add(('Volume {0}{1} {2} {3}, {4} free, dirty {5}' -f $name, $(if ($label -ne '') { ' (' + $label + ')' } else { '' }), (ConvertTo-ToolDisplayText -Text $v.FileSystem -MaxLength 300),
            (Format-ReportGB -Bytes $v.Capacity), (Format-ReportGB -Bytes $v.FreeSpace), $dirty))
        if ([string]::Equals($name, $drive, [StringComparison]::OrdinalIgnoreCase)) {
          $total = ConvertTo-ReportNumber -Value $v.Capacity
          $free = ConvertTo-ReportNumber -Value $v.FreeSpace
          if ($null -ne $total -and $total -gt 0 -and $null -ne $free) {
            $s.Items['FreeGB'] = [math]::Round($free / 1GB, 1)
            $s.Items['FreePercent'] = [math]::Floor($free * 100 / $total)
            $s.Facts['Free space'] = '{0} {1} free of {2} ({3}%)' -f $name, (Format-ReportGB -Bytes $free), (Format-ReportGB -Bytes $total), $s.Items['FreePercent']
          }
          if ($v.DirtyBitSet -is [bool]) { $s.Items['Dirty'] = [bool]$v.DirtyBitSet }
          $s.Facts['Dirty bit'] = $dirty
        }
      }
    }
    if (-not $Quick) {
      $state = Get-ToolVolumeState -Run $Run
      $s.Items['VolumeState'] = [string]$state['Verdict']
      if ([string]$state['Verdict'] -ceq 'Unknown') { $s.Items['VolumeStateError'] = ConvertTo-ReportReason -Why (Get-ToolCheckError -Run $Run -Name 'volumeState') }
      if ($state['Dirty'] -is [bool]) { $s.Items['Dirty'] = [bool]$state['Dirty'] }
      $s.Facts['Volume state'] = '{0} (health {1})' -f $state['Verdict'], $(if ([string]$state['Health'] -ne '') { $state['Health'] } else { 'unknown' })
    }
    $trim = Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'DisableDeleteNotification'
    $s.Items['TrimDisabled'] = $(if ($null -eq $trim) { '' } else { ConvertTo-ScreenText -Text $trim })
    $s.Facts['TRIM'] = $(if ($null -eq $trim -or [string]$trim -eq '0') { 'on' } else { 'off (DisableDeleteNotification = {0})' -f (ConvertTo-ScreenText -Text $trim) })
    $null = Invoke-ReportSource -Section $s -What 'BitLocker' -Script {
      $chip = Get-ToolBitLockerChip -Drive $drive
      if ([string]$chip['Level'] -ceq 'unknown') { throw ([string]$chip['Detail']['Error']) }
      $detail = $chip['Detail']
      $protectors = [string[]]@($detail['Protectors'])
      $s.Items['BitLocker'] = @{ ProtectionStatus = $detail['ProtectionStatus']; ConversionStatus = $detail['ConversionStatus']; Protectors = $protectors }
      $on = ([int]$detail['ProtectionStatus'] -eq 1) -or ($null -ne $detail['ConversionStatus'] -and [int]$detail['ConversionStatus'] -ne 0)
      $s.Facts['BitLocker'] = $(if ($on) { 'on ({0})' -f ($protectors -join ', ') } else { 'off' })
    }
    try {
      $files = New-Object System.Collections.Generic.List[string]
      $missing = New-Object System.Collections.Generic.List[string]
      foreach ($setting in @(Get-ReportCim -ClassName 'Win32_PageFileSetting')) {
        $name = [string]$setting.Name
        $files.Add((ConvertTo-ScreenText -Text $name))
        if ($name -notmatch '^([A-Za-z]:)\\') { continue }
        $pageDrive = $Matches[1].ToUpperInvariant()
        if (-not $missing.Contains($pageDrive) -and -not (Test-Path -LiteralPath ($pageDrive + '\'))) { $missing.Add($pageDrive) }
      }
      $s.Items['PageFile'] = @{ Files = $files.ToArray(); MissingDrives = $missing.ToArray(); Error = '' }
      $usage = @(foreach ($u in @(Get-ReportCim -ClassName 'Win32_PageFileUsage')) { '{0} {1} MB (peak {2} MB)' -f (ConvertTo-ToolDisplayText -Text $u.Name -MaxLength 300), [int]$u.AllocatedBaseSize, [int]$u.PeakUsage })
      $s.Facts['Page file'] = '{0}{1}' -f $(if ($files.Count -eq 0) { 'system managed' } else { $files.ToArray() -join ', ' }), $(if ($usage.Count -gt 0) { ': ' + ($usage -join ', ') } else { '' })
    } catch {
      $s.Items['PageFile'] = @{ Files = @(); MissingDrives = @(); Error = (ConvertTo-ReportReason -Exception $_.Exception) }
      Write-SetupLog -Level WARN -Message 'The page file settings could not be read for the report' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
    $null = Invoke-ReportSource -Section $s -What 'Restore points (CIM)' -Script {
      $points = @(Get-ReportCim -Namespace 'root\default' -ClassName 'SystemRestore')
      $newest = $null
      foreach ($p in $points) {
        $when = ConvertFrom-ReportWmiDate -Text $p.CreationTime
        if ($null -ne $when -and ($null -eq $newest -or $when -gt $newest)) { $newest = $when }
      }
      $s.Facts['Restore points'] = $(if ($points.Count -eq 0) { 'none' } else { '{0}, newest {1}' -f $points.Count, (Format-ReportDate -When $newest) })
    }
    if (-not $Quick) {
      $vssadmin = Get-ToolSystemTool -Name 'vssadmin.exe'
      Invoke-ReportNative -Run $Run -Section $s -What 'Shadow copies' -FilePath $vssadmin -ArgumentList 'list shadows' -OutputName 'vssadmin-shadows'
      Invoke-ReportNative -Run $Run -Section $s -What 'Shadow copy storage' -FilePath $vssadmin -ArgumentList 'list shadowstorage' -OutputName 'vssadmin-storage'
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 04 Boot and recovery ------------------------------------------------------------------------------------------

function Get-ReportData04 {
  <#
  .SYNOPSIS
    Section 04, Boot and recovery: WinRE and safe boot from the BCD (WMI BcdStore, grandchild bcd) with ReAgent.xml as
    support (Get-ToolWinReState), the EFI, recovery and MSR partitions (grandchild partitions, by GPT type), the boot
    times (Diagnostics-Performance 100's BootTime field) and the start and stop events 6005, 6006, 6008, 41 and 1074
    (grandchild bootEvents).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '04'
  try {
    $winRe = Get-ToolWinReState -Run $Run
    $reason = ''
    if ([string]$winRe['Bcd'] -ceq 'Unknown') { $reason = ConvertTo-ReportReason -Why (Get-ToolCheckError -Run $Run -Name 'bcd') }
    $s.Items['WinRe'] = @{ Bcd = [string]$winRe['Bcd']; ReAgent = [string]$winRe['ReAgent']; Verdict = [string]$winRe['Verdict']; Error = $reason }
    $s.Items['SafeBoot'] = $winRe['SafeBoot']
    $s.Facts['WinRE'] = '{0} (boot configuration {1}, ReAgent.xml {2})' -f $winRe['Verdict'], $winRe['Bcd'], $winRe['ReAgent']
    $safeNames = @{ 0 = 'minimal'; 1 = 'network'; 2 = 'DsRepair' }
    $s.Facts['Safe boot'] = $(if ($null -eq $winRe['SafeBoot']) { 'not set' } elseif ($safeNames.ContainsKey([int]$winRe['SafeBoot'])) { 'set: ' + $safeNames[[int]$winRe['SafeBoot']] } else { 'set: ' + $winRe['SafeBoot'] })

    $parts = Get-ReportChild -Run $Run -Section $s -What 'Partitions' -Name 'partitions' -Command $script:ReportPartitionsCommand -StepTimeout 'disks'
    if ($null -ne $parts) {
      $efi = 0; $recovery = 0; $msr = 0
      [double]$recoveryBytes = 0
      foreach ($p in @($parts['Items'])) {
        if ($p -isnot [System.Collections.IDictionary]) { continue }
        $type = ([string]$p['GptType']).ToLowerInvariant()
        $kind = ''
        if ($type -eq $script:ReportGptEfi) { $kind = 'EFI'; $efi++ }
        elseif ($type -eq $script:ReportGptRecovery -or [string]$p['MbrType'] -eq '39') { $kind = 'Recovery'; $recovery++; $recoveryBytes += [double]$p['Size'] }
        elseif ($type -eq $script:ReportGptMsr) { $kind = 'MSR'; $msr++ }
        elseif ([string]$p['Letter'] -ne '') { $kind = 'Volume ' + [string]$p['Letter'] + ':' }
        else { $kind = 'Other' }
        $s.Groups.Add(('Disk {0} partition {1}: {2}, {3}' -f $p['Disk'], $p['Number'], $kind, (Format-ReportGB -Bytes $p['Size'])))
      }
      $s.Facts['Partitions'] = 'EFI {0}, recovery {1} ({2}), MSR {3}' -f $efi, $recovery, (Format-ReportGB -Bytes $recoveryBytes), $msr
    }

    $days = Get-ReportDays -Run $Run -Name 'eventDays' -Default 14
    $specs = @(
      (New-ReportEventSpec -Name 'boot' -Label 'Boot times' -Log 'Microsoft-Windows-Diagnostics-Performance/Operational' -Ids @(100) -Days 90 -Max 20 -Mode rows -Keep 5 -Names @('BootTime', 'MainPathBootTime', 'BootPostBootTime'))
      (New-ReportEventSpec -Name 'power' -Label 'Start and stop events' -Log 'System' -Ids @(6005, 6006, 6008, 41, 1074) -Days $days -Max 2000 -Mode groups -Keep 50))
    $events = Get-ReportEvents -Run $Run -Section $s -What 'Boot events' -Name 'bootEvents' -Specs $specs
    $boots = New-Object System.Collections.Generic.List[double]
    foreach ($row in (Get-ReportEventRows -Events $events -Name 'boot')) {
      $ms = ConvertTo-ReportNumber -Value $row['Data']['BootTime']
      if ($null -eq $ms) { continue }
      $boots.Add([math]::Round($ms / 1000, 1))
      $main = ConvertTo-ReportNumber -Value $row['Data']['MainPathBootTime']
      $s.Groups.Add(('Boot {0}: {1} s (main path {2} s)' -f (Format-ReportDate -When (ConvertTo-ReportDateTime -Value $row['Time'])), (Format-ReportNumber -Value ($ms / 1000) -Format '0.0'),
          (Format-ReportNumber -Value ([double]$main / 1000) -Format '0.0')))
    }
    if ($boots.Count -gt 0) { $s.Facts['Last boot time'] = '{0} s' -f (Format-ReportNumber -Value $boots[0] -Format '0.0') }
    $s.Items['BootTimes'] = $boots.ToArray()
    $power = Get-ReportEventRows -Events $events -Name 'power' -Part 'Groups'
    if ($null -ne $events -and $null -ne $events['power']) {
      $s.Facts['Starts and stops'] = '{0} ({1} days)' -f $(if ($power.Count -gt 0) { (@(foreach ($g in $power) { '{0}: {1}' -f $g['Id'], $g['Count'] }) -join ', ') } else { 'none' }), $days
      foreach ($line in @(ConvertTo-EventGroups -Events $power)) { $s.Groups.Add($line) }
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 05 Windows Update ---------------------------------------------------------------------------------------------

function Get-ReportData05 {
  <#
  .SYNOPSIS
    Section 05, Windows Update: the newest 40 installed updates (Win32_QuickFixEngineering), the last successful search
    and install (grandchild wuResults), the update policies (registry), the update services' start types and states
    (enum names), SFC's [SR] lines of the last 30 days in CBS.log (English) and the WindowsUpdateClient events
    (grandchild wuEvents). Full: CBS.log's and dism.log's error lines condensed (Read-ToolLogErrors), copies of both
    and Get-WindowsUpdateLog (grandchild wuLog) to raw.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '05'
  try {
    $null = Invoke-ReportSource -Section $s -What 'Installed updates (CIM)' -Script {
      $invariant = [Globalization.CultureInfo]::InvariantCulture
      $rows = @(foreach ($q in @(Get-ReportCim -ClassName 'Win32_QuickFixEngineering')) {
          $when = [datetime]::MinValue
          $parsed = [datetime]::TryParseExact(([string]$q.InstalledOn).Trim(), [string[]]@('M/d/yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd'), $invariant, [Globalization.DateTimeStyles]::None, [ref]$when)
          [pscustomobject]@{ Id = (ConvertTo-ScreenText -Text $q.HotFixID); When = $(if ($parsed) { $when } else { $null }); Kind = (ConvertTo-ToolDisplayText -Text $q.Description -MaxLength 60) }
        })
      $sorted = @($rows | Sort-Object -Property @{ Expression = { if ($null -eq $_.When) { [datetime]::MinValue } else { $_.When } }; Descending = $true })
      $s.Facts['Updates installed'] = [string]$rows.Count
      $s.Items['Hotfixes'] = [string[]]@(foreach ($r in $sorted) { $r.Id })
      foreach ($r in @($sorted | Select-Object -First 40)) {
        $s.Groups.Add(('Update {0} ({1}, {2})' -f $r.Id, $(if ($null -ne $r.When) { $r.When.ToString('dd/MM/yyyy', $invariant) } else { 'date unknown' }), $r.Kind))
      }
    }
    $results = Get-ReportChild -Run $Run -Section $s -What 'Last update search and install' -Name 'wuResults' -Command $script:ReportWuResultsCommand
    if ($null -ne $results) {
      foreach ($pair in @(@('Last search', 'LastSearch'), @('Last install', 'LastInstall'))) {
        $when = ConvertTo-ReportDateTime -Value $results[$pair[1]]
        $s.Facts[$pair[0]] = $(if ($null -ne $when) { Format-ReportDate -When $when } else { 'never' })
      }
    }
    $null = Invoke-ReportSource -Section $s -What 'Update policies (registry)' -Script {
      $policy = [ordered]@{}
      foreach ($key in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU') {
        $values = Read-ToolRegistryKey -Path $key
        if ($values -isnot [System.Collections.IDictionary]) { continue }
        foreach ($name in @($values.Keys | Sort-Object)) { if ([string]$name -ne '') { $policy[[string]$name] = ConvertTo-ScreenText -Text $values[$name] } }
      }
      $s.Items['WuPolicy'] = $policy
      $s.Facts['Policies'] = $(if ($policy.Count -eq 0) { 'none' } else { (@(foreach ($k in $policy.Keys) { '{0}={1}' -f $k, $policy[$k] }) -join ', ') })
    }
    $services = [ordered]@{}
    foreach ($name in 'wuauserv', 'bits', 'cryptsvc', 'usosvc', 'dosvc', 'msiserver', 'TrustedInstaller') {
      try {
        $service = @(Get-Service -Name $name -ErrorAction Stop) | Select-Object -First 1
        if ($null -eq $service) { continue }
        $services[$name] = @{ Status = [string]$service.Status; StartType = [string]$service.StartType }
        $s.Groups.Add(('Service {0}: {1}, {2}' -f $name, $service.StartType, $service.Status))
      } catch {
        Add-ReportMissing -Section $s -What ('Service ' + $name) -Exception $_.Exception
      }
    }
    $s.Items['WuServices'] = $services
    if ($services.Contains('wuauserv')) { $s.Facts['Windows Update service'] = '{0}, {1}' -f $services['wuauserv']['StartType'], $services['wuauserv']['Status'] }
    $null = Invoke-ReportSource -Section $s -What 'SFC in CBS.log' -Script {
      $now = Get-Date
      $cbs = ConvertFrom-CbsSrText -Text (Read-ToolCbsLog -Since $now -Folder ([IO.Path]::GetDirectoryName($script:ToolReportPaths['CbsLog']))) -Since $now.AddDays(-30)
      $s.Items['Sfc'] = @{ Ran = [bool]$cbs['Ran']; Corrupt = [int]$cbs['Corrupt']; Repaired = [int]$cbs['Repaired']; CannotRepair = [int]$cbs['CannotRepair'] }
      $s.Facts['SFC in CBS.log (30 days)'] = $(if (-not $cbs['Ran']) { 'no [SR] lines' } else {
          'verify complete {0}, {1} integrity problems, {2} repaired, {3} not repairable' -f $(if ($cbs['VerifyComplete']) { 'yes' } else { 'no' }), $cbs['Corrupt'], $cbs['Repaired'], $cbs['CannotRepair'] })
    }
    if (-not $Quick) {
      # The servicing logs' error lines come before the update events, so the size limit cuts the oldest events first
      # (review M1).
      foreach ($log in @(@('CBS.log', 'CbsLog'), @('dism.log', 'DismLog'))) {
        foreach ($line in @(Read-ToolLogErrors -Path ([string]$script:ToolReportPaths[$log[1]]) -MaxLines 40)) { $s.Groups.Add(('{0}: {1}' -f $log[0], $line)) }
      }
    }
    $days = Get-ReportDays -Run $Run -Name 'eventDays' -Default 14
    $wuSpec = New-ReportEventSpec -Name 'wu' -Label 'Windows Update events' -Log 'System' -Ids @(19, 20, 25, 31, 43, 44) -Providers @('Microsoft-Windows-WindowsUpdateClient') -Days $days -Max 2000 -Mode groups -Keep 100
    $specs = @(
      $wuSpec
      (New-ReportEventSpec -Name 'wuFailed' -Label 'Failed updates' -Log 'System' -Ids @(20) -Providers @('Microsoft-Windows-WindowsUpdateClient') -Days $days -Max 200 -Mode rows -Keep 20 -Props @(0, 1)))
    $events = Get-ReportEvents -Run $Run -Section $s -What 'Windows Update events' -Name 'wuEvents' -Specs $specs
    if ($null -ne $events) {
      foreach ($row in (Get-ReportEventRows -Events $events -Name 'wuFailed')) {
        $s.Groups.Add(('Update failed {0}: {1} {2}' -f (Format-ReportDate -When (ConvertTo-ReportDateTime -Value $row['Time'])), (ConvertTo-ScreenText -Text @($row['Props'])[0]),
            (ConvertTo-ToolDisplayText -Text @($row['Props'])[1] -MaxLength 150)))
      }
      $groups = Get-ReportEventRows -Events $events -Name 'wu' -Part 'Groups'
      $installed = 0; $failed = 0
      foreach ($g in $groups) { if ([int]$g['Id'] -eq 19) { $installed += [int]$g['Count'] } elseif ([int]$g['Id'] -eq 20) { $failed += [int]$g['Count'] } }
      $s.Facts['Update events'] = 'installed {0}, failed {1} ({2} days{3})' -f $installed, $failed, $days,
        $(if ((Get-ReportEventTotal -Events $events -Spec $wuSpec)['Capped']) { '; the newest {0} read' -f $wuSpec['Max'] } else { '' })
      foreach ($line in @(ConvertTo-EventGroups -Events $groups)) { $s.Groups.Add($line) }
    }
    if (-not $Quick) {
      foreach ($log in @(@('CBS.log', 'CbsLog', 32MB), @('dism.log', 'DismLog', 16MB))) {
        $path = [string]$script:ToolReportPaths[$log[1]]
        $null = Invoke-ReportSource -Section $s -What ('{0} copy' -f $log[0]) -Script {
          if (Copy-ToolRawFile -Source $path -Destination ([IO.Path]::Combine((Get-ToolReportRawDir -Run $Run), $log[0])) -MaxBytes $log[2]) { $s.Raw.Add($log[0]) }
        }
      }
      $null = Invoke-ReportSource -Section $s -What 'Windows Update log' -Script {
        $target = [IO.Path]::Combine((Get-ToolReportRawDir -Run $Run), 'WindowsUpdate.log')
        $answer = Get-ReportChild -Run $Run -Section $s -What 'Windows Update log' -Name 'wuLog' -Command ($script:ReportWuLogCommand.Replace('<P>', (ConvertTo-PowerShellLiteral -Text $target))) -StepTimeout 'wuLog'
        if ($null -ne $answer -and [IO.File]::Exists($target)) { $s.Raw.Add('WindowsUpdate.log') }
      }
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 06 Drivers and devices ----------------------------------------------------------------------------------------

function Get-ReportData06 {
  <#
  .SYNOPSIS
    Section 06, Drivers and devices: the present devices with a problem (Get-ToolProblemDevices, grandchild devices; a
    disabled device, CM 22, is counted apart and never a problem: review I-10), the disconnected devices by class
    (grandchild ghostCount) and the Kernel-PnP events (grandchild pnpEvents). Full: the third-party drivers
    (Get-WindowsDriver, grandchild drivers, toolStep.drivers) with the core ones older than six years, and
    setupapi.dev.log's '!!!' lines condensed, with a copy to raw.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '06'
  try {
    $devices = Get-ToolProblemDevices -Run $Run
    if ($null -eq $devices) {
      Add-ReportMissing -Section $s -What 'Devices with a problem' -Why (Get-ToolCheckError -Run $Run -Name 'devices')
    } else {
      $problem = New-Object System.Collections.Generic.List[object]
      $codes = New-Object System.Collections.Generic.List[int]
      $disabled = 0
      foreach ($d in $devices) {
        $code = ConvertTo-ReportNumber -Value $d['ConfigManagerErrorCode']
        if ($null -eq $code) { $code = 0 }
        $name = ConvertTo-ToolDisplayText -Text $d['Name'] -MaxLength 200
        if ($code -eq 22) { $disabled++; $s.Groups.Add(('Disabled device: {0} ({1})' -f $name, (ConvertTo-ToolDisplayText -Text $d['Class'] -MaxLength 300))); continue }
        if ($code -le 0) { continue }
        $codes.Add([int]$code)
        if ($problem.Count -lt 50) { $problem.Add([ordered]@{ Id = [string]$d['InstanceId']; Name = $name; Class = [string]$d['Class']; Code = [int]$code }) }
        $s.Groups.Add(('Problem device: {0} ({1}, code {2})' -f $name, (ConvertTo-ToolDisplayText -Text $d['Class'] -MaxLength 300), [int]$code))
      }
      $unique = @($codes.ToArray() | Sort-Object -Unique)
      $s.Items['ProblemDevices'] = $problem.ToArray()
      $s.Items['DevicesProblem'] = $codes.Count
      $s.Items['ProblemCodes'] = [int[]]$unique
      $s.Items['DevicesDisabled'] = $disabled
      $s.Facts['Devices with a problem'] = $(if ($codes.Count -gt 0) { '{0} (codes {1})' -f $codes.Count, ($unique -join ', ') } else { '0' })
      $s.Facts['Disabled devices'] = [string]$disabled
    }
    $ghosts = Get-ReportChild -Run $Run -Section $s -What 'Disconnected devices' -Name 'ghostCount' -Command $script:ReportGhostCountCommand
    if ($null -ne $ghosts) {
      $rows = @(foreach ($g in @($ghosts['Items'])) { if ($g -is [System.Collections.IDictionary]) { [pscustomobject]@{ Class = [string]$g['Class']; Count = [int]$g['Count'] } } })
      [int]$total = 0
      foreach ($r in $rows) { $total += $r.Count }
      $s.Items['GhostCount'] = $total
      $s.Facts['Disconnected devices'] = [string]$total
      if ($rows.Count -gt 0) {
        $s.Groups.Add(('Disconnected by class: {0}' -f (@($rows | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Class | ForEach-Object { '{0} {1}' -f (ConvertTo-ToolDisplayText -Text $_.Class -MaxLength 300), $_.Count }) -join ', ')))
      }
    }
    $days = Get-ReportDays -Run $Run -Name 'eventDays' -Default 14
    $events = Get-ReportEvents -Run $Run -Section $s -What 'Kernel-PnP events' -Name 'pnpEvents' -Specs @(
      (New-ReportEventSpec -Name 'pnp' -Label 'Kernel-PnP events' -Log 'System' -Levels @(1, 2, 3) -Provider 'Microsoft-Windows-Kernel-PnP' -Days $days -Max 1000 -Mode groups -Keep 50))
    foreach ($line in @(ConvertTo-EventGroups -Events (Get-ReportEventRows -Events $events -Name 'pnp' -Part 'Groups'))) { $s.Groups.Add($line) }
    if (-not $Quick) {
      $drivers = Get-ReportChild -Run $Run -Section $s -What 'Drivers' -Name 'drivers' -Command $script:ReportDriversCommand -StepTimeout 'drivers'
      if ($null -ne $drivers) {
        $limit = (Get-Date).AddYears(-6)
        $rows = @(foreach ($d in @($drivers['Items'])) { if ($d -is [System.Collections.IDictionary]) { $d } })
        $old = 0
        $s.Facts['Third-party drivers'] = [string]$rows.Count
        foreach ($d in @($rows | Sort-Object -Property @{ Expression = { [string]$_['Class'] } }, @{ Expression = { [string]$_['Provider'] } })) {
          $date = ConvertTo-ReportDateTime -Value $d['Date']
          $line = 'Driver {0} ({1}): {2}, {3} {4} ({5})' -f (ConvertTo-ScreenText -Text $d['Driver']), (ConvertTo-ScreenText -Text $d['Original']), (ConvertTo-ToolDisplayText -Text $d['Class'] -MaxLength 300),
            (ConvertTo-ToolDisplayText -Text $d['Provider'] -MaxLength 80), (ConvertTo-ScreenText -Text $d['Version']), (Format-ReportDate -When $date)
          if ($null -ne $date -and $date -lt $limit -and $script:ReportCoreDriverClasses -contains [string]$d['Class']) { $old++; $line = 'Old core ' + $line.Substring(0, 1).ToLowerInvariant() + $line.Substring(1) }
          $s.Groups.Add($line)
        }
        $s.Facts['Old core drivers (over 6 years)'] = [string]$old
        $s.Items['OldCoreDrivers'] = $old
      }
      $setupApi = [string]$script:ToolReportPaths['SetupApiLog']
      foreach ($line in @(Read-ToolLogErrors -Path $setupApi -MaxLines 30 -Patterns @('!!!'))) { $s.Groups.Add('setupapi: ' + $line) }
      $null = Invoke-ReportSource -Section $s -What 'setupapi.dev.log copy' -Script {
        if (Copy-ToolRawFile -Source $setupApi -Destination ([IO.Path]::Combine((Get-ToolReportRawDir -Run $Run), 'setupapi.dev.log')) -MaxBytes 16MB) { $s.Raw.Add('setupapi.dev.log') }
      }
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 07 Events and crashes -----------------------------------------------------------------------------------------

function Get-ReportData07 {
  <#
  .SYNOPSIS
    Section 07, Events and crashes (all by provider, ID, level and event data, never message text): the System and
    Application errors and warnings grouped (grandchild eventGroups; Quick quickEventDays, Full eventDays; at most 5000
    events each), and over crashDays (grandchild crashEvents): Kernel-Power 41 with its BugcheckCode (0 = power loss or
    hang), BugCheck 1001 by code, WHEA by ID and level, 6008, Application Error 1000 by app and module, Application
    Hang 1002; the crash dumps listed. Full: the newest 10 dumps copied, Reliability Monitor's records (grandchild
    reliability) and the System and Application logs of eventDays exported (wevtutil epl) to raw.
  .DESCRIPTION
    The details list the blue screens, WHEA, crashes, hangs, dumps and reliability records first and the System and
    Application event groups last, so the core's size limit, which cuts a section's details from their end, drops the
    oldest event groups before any crash line (review M1). A count whose query read its Max events (or kept fewer rows
    than it counted) is a lower bound: '<n>+' in the facts, and its Item is named in Items.CappedCounts, which the
    findings read (review M6).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '07'
  $eventLines = New-Object System.Collections.Generic.List[string]
  $capped = New-Object System.Collections.Generic.List[string]
  try {
    $eventDays = Get-ReportDays -Run $Run -Name 'eventDays' -Default 14
    $days = $(if ($Quick) { Get-ReportDays -Run $Run -Name 'quickEventDays' -Default 7 } else { $eventDays })
    $crashDays = Get-ReportDays -Run $Run -Name 'crashDays' -Default 60
    $logSpecs = @(
      (New-ReportEventSpec -Name 'system' -Label 'System log' -Log 'System' -Levels @(1, 2, 3) -Days $days -Max 5000 -Mode groups -Keep 400)
      (New-ReportEventSpec -Name 'application' -Label 'Application log' -Log 'Application' -Levels @(1, 2, 3) -Days $days -Max 5000 -Mode groups -Keep 400))
    $groups = Get-ReportEvents -Run $Run -Section $s -What 'Error and warning events' -Name 'eventGroups' -Specs $logSpecs
    foreach ($pair in @(@($logSpecs[0], 'System'), @($logSpecs[1], 'Application'))) {
      $spec = $pair[0]
      if ($null -eq $groups -or $null -eq $groups[$spec['Name']]) { continue }
      $total = Get-ReportEventTotal -Events $groups -Spec $spec
      $s.Facts[('{0} errors and warnings' -f $pair[1])] = '{0} in {1} days{2}' -f $total['Text'], $days, $(if ($total['Capped']) { ' (the newest {0} read)' -f $spec['Max'] } else { '' })
      foreach ($line in @(ConvertTo-EventGroups -Events (Get-ReportEventRows -Events $groups -Name $spec['Name'] -Part 'Groups'))) { $eventLines.Add($line) }
    }

    $crashSpecs = [ordered]@{
      kp41     = (New-ReportEventSpec -Name 'kp41' -Label 'Kernel-Power 41' -Log 'System' -Ids @(41) -Provider 'Microsoft-Windows-Kernel-Power' -Days $crashDays -Max 500 -Mode rows -Keep 200 -Names @('BugcheckCode'))
      bugcheck = (New-ReportEventSpec -Name 'bugcheck' -Label 'Blue screens (1001)' -Log 'System' -Ids @(1001) -Providers @('Microsoft-Windows-WER-SystemErrorReporting', 'BugCheck') -Days $crashDays -Max 500 -Mode rows -Keep 200 -Props @(0))
      whea     = (New-ReportEventSpec -Name 'whea' -Label 'WHEA' -Log 'System' -Provider 'Microsoft-Windows-WHEA-Logger' -Days $crashDays -Max 1000 -Mode rows -Keep 500)
      shutdown = (New-ReportEventSpec -Name 'shutdown' -Label 'Unexpected shutdowns (6008)' -Log 'System' -Ids @(6008) -Providers @('EventLog') -Days $crashDays -Max 200 -Mode rows -Keep 100)
      appError = (New-ReportEventSpec -Name 'appError' -Label 'Application crashes (1000)' -Log 'Application' -Ids @(1000) -Providers @('Application Error') -Days $crashDays -Max 1000 -Mode rows -Keep 500 -Props @(0, 3, 6))
      appHang  = (New-ReportEventSpec -Name 'appHang' -Label 'Application hangs (1002)' -Log 'Application' -Ids @(1002) -Providers @('Application Hang') -Days $crashDays -Max 500 -Mode rows -Keep 200 -Props @(0))
    }
    $crash = Get-ReportEvents -Run $Run -Section $s -What 'Crash events' -Name 'crashEvents' -Specs @($crashSpecs.Values)
    if ($null -ne $crash) {
      if ($null -ne $crash['kp41']) {
        $rows = Get-ReportEventRows -Events $crash -Name 'kp41'
        $events41 = @(foreach ($r in $rows) {
            $code = ConvertTo-ReportNumber -Value $r['Data']['BugcheckCode']
            [ordered]@{ Time = [string]$r['Time']; BugcheckCode = $(if ($null -ne $code) { [long]$code } else { $null }) } })
        $total = Get-ReportEventTotal -Events $crash -Spec $crashSpecs['kp41'] -Least $events41.Count
        $losses = @($events41 | Where-Object { $null -eq $_.BugcheckCode -or $_.BugcheckCode -eq 0 }).Count + ($total['Count'] - $events41.Count)
        $s.Items['KernelPower41'] = $total['Count']
        $s.Items['KernelPower41Events'] = $events41
        if ($total['Capped']) { $capped.Add('KernelPower41') }
        $s.Facts['Kernel-Power 41'] = '{0} in {1} days (power loss or hang: {2}{3})' -f $total['Text'], $crashDays, $losses, $(if ($total['Capped']) { '+' } else { '' })
      }
      if ($null -ne $crash['bugcheck']) {
        $blue = @(foreach ($r in (Get-ReportEventRows -Events $crash -Name 'bugcheck')) {
            $hex = [regex]::Match([string]@($r['Props'])[0], '0[xX][0-9A-Fa-f]{1,16}')
            [ordered]@{ Time = [string]$r['Time']; Code = $(if ($hex.Success) { ConvertTo-ReportBugcheck -Value $hex.Value } else { '' }) } })
        $total = Get-ReportEventTotal -Events $crash -Spec $crashSpecs['bugcheck'] -Least $blue.Count
        $s.Items['BugChecks'] = $blue
        if ($total['Capped'] -or $total['Count'] -gt $blue.Count) { $capped.Add('BugChecks') }
        $s.Facts['Blue screens'] = '{0} in {1} days' -f $total['Text'], $crashDays
        foreach ($b in $blue) { $s.Groups.Add(('Blue screen {0}: {1}' -f (Format-ReportDate -When (ConvertTo-ReportDateTime -Value $b.Time)), $(if ($b.Code -ne '') { $b.Code } else { 'code unknown' }))) }
      }
      if ($null -ne $crash['whea']) {
        $whea = @(foreach ($r in (Get-ReportEventRows -Events $crash -Name 'whea')) { [ordered]@{ Time = [string]$r['Time']; Id = [int]$r['Id']; Level = [int]$r['Level'] } })
        $total = Get-ReportEventTotal -Events $crash -Spec $crashSpecs['whea'] -Least $whea.Count
        $s.Items['Whea'] = $whea
        if ($total['Capped'] -or $total['Count'] -gt $whea.Count) { $capped.Add('Whea') }
        $s.Facts['WHEA'] = '{0} events in {1} days' -f $total['Text'], $crashDays
        foreach ($line in @(ConvertTo-EventGroups -Events @(foreach ($w in $whea) { @{ Provider = 'Microsoft-Windows-WHEA-Logger'; Id = $w.Id; Level = $w.Level; Time = $w.Time } }))) { $s.Groups.Add($line) }
      }
      if ($null -ne $crash['shutdown']) {
        $times = @(foreach ($r in (Get-ReportEventRows -Events $crash -Name 'shutdown')) { [string]$r['Time'] })
        $total = Get-ReportEventTotal -Events $crash -Spec $crashSpecs['shutdown'] -Least $times.Count
        $s.Items['UnexpectedShutdowns'] = $total['Count']
        if ($total['Capped']) { $capped.Add('UnexpectedShutdowns') }
        $s.Facts['Unexpected shutdowns (6008)'] = '{0} in {1} days' -f $total['Text'], $crashDays
      }
      if ($null -ne $crash['appError']) {
        $rows = Get-ReportEventRows -Events $crash -Name 'appError'
        $byApp = @{}
        $byPair = @{}
        foreach ($r in $rows) {
          $props = @($r['Props'])
          $app = ConvertTo-ToolDisplayText -Text $props[0] -MaxLength 80
          $module = ConvertTo-ToolDisplayText -Text $props[1] -MaxLength 80
          $byApp[$app] = 1 + [int]$byApp[$app]
          $pair = '{0} / {1}' -f $app, $module
          $byPair[$pair] = 1 + [int]$byPair[$pair]
        }
        $top = @($byApp.GetEnumerator() | Sort-Object -Property @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key } } | Select-Object -First 1)
        $total = Get-ReportEventTotal -Events $crash -Spec $crashSpecs['appError'] -Least $rows.Count
        $s.Items['AppCrashes'] = $total['Count']
        if ($total['Capped']) { $capped.Add('AppCrashes') }
        $s.Items['AppCrashTop'] = $(if ($top.Count -gt 0) { [string]$top[0].Key } else { '' })
        $s.Facts['Application crashes'] = '{0} in {1} days' -f $total['Text'], $crashDays
        foreach ($p in @($byPair.GetEnumerator() | Sort-Object -Property @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key } } | Select-Object -First 30)) {
          $s.Groups.Add(('Application crash: {0} x{1}' -f $p.Key, $p.Value))
        }
      }
      if ($null -ne $crash['appHang']) {
        $rows = Get-ReportEventRows -Events $crash -Name 'appHang'
        $byApp = @{}
        foreach ($r in $rows) { $app = ConvertTo-ToolDisplayText -Text @($r['Props'])[0] -MaxLength 80; $byApp[$app] = 1 + [int]$byApp[$app] }
        $total = Get-ReportEventTotal -Events $crash -Spec $crashSpecs['appHang'] -Least $rows.Count
        $s.Items['AppHangs'] = $total['Count']
        if ($total['Capped']) { $capped.Add('AppHangs') }
        $s.Facts['Application hangs'] = '{0} in {1} days' -f $total['Text'], $crashDays
        foreach ($p in @($byApp.GetEnumerator() | Sort-Object -Property @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key } } | Select-Object -First 20)) {
          $s.Groups.Add(('Application hang: {0} x{1}' -f $p.Key, $p.Value))
        }
      }
    }

    $null = Invoke-ReportSource -Section $s -What 'Crash dumps' -Script {
      $folder = [string]$script:ToolReportPaths['Minidump']
      $since = (Get-Date).AddDays(-$crashDays)
      $found = @()
      if ([IO.Directory]::Exists($folder)) {
        $found = @(foreach ($path in [IO.Directory]::GetFiles($folder, '*.dmp')) {
            $file = New-Object IO.FileInfo $path
            if ($file.LastWriteTime -ge $since) { $file } })
      }
      $sorted = @($found | Sort-Object -Property LastWriteTime -Descending)
      $s.Items['Minidumps'] = $sorted.Count
      $s.Items['MinidumpFiles'] = [string[]]@(foreach ($f in $sorted) { $f.Name })
      $s.Facts['Crash dumps'] = '{0} in {1} days' -f $sorted.Count, $crashDays
      foreach ($f in @($sorted | Select-Object -First 20)) { $s.Groups.Add(('Crash dump {0} ({1}, {2} KB)' -f $f.Name, (Format-ReportDate -When $f.LastWriteTime), [math]::Round($f.Length / 1KB))) }
      $memory = [string]$script:ToolReportPaths['MemoryDump']
      if ([IO.File]::Exists($memory)) {
        $info = New-Object IO.FileInfo $memory
        $s.Facts['Full memory dump'] = '{0}, {1}' -f (Format-ReportDate -When $info.LastWriteTime), (Format-ReportGB -Bytes $info.Length)
      }
      if (-not $Quick) {
        $copied = 0
        foreach ($f in @($sorted | Select-Object -First 10)) {
          $target = [IO.Path]::Combine((Get-ToolReportRawDir -Run $Run), 'Minidump')
          [void][IO.Directory]::CreateDirectory($target)
          if (Copy-ToolRawFile -Source $f.FullName -Destination ([IO.Path]::Combine($target, $f.Name))) { $copied++ }
        }
        if ($copied -gt 0) { $s.Raw.Add(('Minidump\ ({0} files)' -f $copied)) }
      }
    }

    if (-not $Quick) {
      $reliability = Get-ReportChild -Run $Run -Section $s -What 'Reliability records' -Name 'reliability' -Command ($script:ReportReliabilityCommand.Replace('<DAYS>', [string]$crashDays)) -StepTimeout 'events'
      if ($null -ne $reliability) {
        $records = @(foreach ($r in @($reliability['Items'])) { if ($r -is [System.Collections.IDictionary]) { $r } })
        $s.Facts['Reliability records'] = '{0}{1} in {2} days' -f $records.Count, $(if ($records.Count -ge 1000) { '+' } else { '' }), $crashDays
        foreach ($line in @(ConvertTo-EventGroups -Events @(foreach ($r in $records) { @{ Provider = ('Reliability ' + [string]$r['Source']); Id = $r['EventId']; Level = 0; Time = $r['Time']
                                                                                                Message = ('{0}: {1}' -f [string]$r['Product'], [string]$r['Message']) } }) | Select-Object -First 60)) {
          $s.Groups.Add($line)
        }
      }
      $milliseconds = [long]$eventDays * 86400000
      foreach ($log in 'System', 'Application') {
        Invoke-ReportNative -Run $Run -Section $s -What ('{0} log export' -f $log) -FilePath (Get-ToolSystemTool -Name 'wevtutil.exe') `
          -ArgumentList ('epl {0} "<RAW>\{0}.evtx" "/q:*[System[TimeCreated[timediff(@SystemTime) <= {1}]]]"' -f $log, $milliseconds) -File ('{0}.evtx' -f $log)
      }
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  # The event groups last (review M1), whatever else failed.
  foreach ($line in $eventLines) { $s.Groups.Add($line) }
  if ($capped.Count -gt 0) { $s.Items['CappedCounts'] = [string[]]$capped.ToArray() }
  return (Complete-ReportSection -Section $s)
}

# --- 08 Performance and power --------------------------------------------------------------------------------------

function Get-ReportPerfSample {
  # Private. One sample of the formatted performance classes (CIM): the CPU and disk totals, memory, the processes.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  return @{
    Cpu       = (@(Get-ReportCim -ClassName 'Win32_PerfFormattedData_PerfOS_Processor' -Filter "Name='_Total'") | Select-Object -First 1)
    Memory    = (@(Get-ReportCim -ClassName 'Win32_PerfFormattedData_PerfOS_Memory') | Select-Object -First 1)
    Disk      = (@(Get-ReportCim -ClassName 'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' -Filter "Name='_Total'") | Select-Object -First 1)
    Processes = @(Get-ReportCim -ClassName 'Win32_PerfFormattedData_PerfProc_Process')
  }
}

function Get-ReportData08 {
  <#
  .SYNOPSIS
    Section 08, Performance and power: the CPU, memory and disk counters and the top 15 processes by CPU and by memory
    (the formatted CIM performance classes, sampled twice one second apart and the second kept: the first sample of a
    rate is meaningless; review I-10) and the active power plan (its GUID, registry). Full: powercfg's battery, sleep
    study and energy reports to raw.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '08'
  try {
    $null = Invoke-ReportSource -Section $s -What 'Performance counters (CIM)' -Script {
      $null = Get-ReportPerfSample
      Wait-SetupDelay -Seconds 1
      $sample = Get-ReportPerfSample
      if ($null -ne $sample['Cpu']) { $s.Facts['CPU'] = '{0}%' -f [int]$sample['Cpu'].PercentProcessorTime }
      if ($null -ne $sample['Memory']) { $s.Facts['Memory'] = '{0} MB available, {1}% committed' -f [long]$sample['Memory'].AvailableMBytes, [int]$sample['Memory'].PercentCommittedBytesInUse }
      if ($null -ne $sample['Disk']) { $s.Facts['Disk busy'] = '{0}% (queue {1})' -f [int]$sample['Disk'].PercentDiskTime, [int]$sample['Disk'].AvgDiskQueueLength }
      $processes = @($sample['Processes'] | Where-Object { [string]$_.Name -notin '_Total', 'Idle' })
      $cpu = @($processes | Sort-Object -Property @{ Expression = { [double]$_.PercentProcessorTime }; Descending = $true } | Select-Object -First 15)
      $memory = @($processes | Sort-Object -Property @{ Expression = { [double]$_.WorkingSetPrivate }; Descending = $true } | Select-Object -First 15)
      if ($cpu.Count -gt 0) { $s.Groups.Add(('Top CPU (% of one core): {0}' -f (@(foreach ($p in $cpu) { '{0} {1}' -f (ConvertTo-ToolDisplayText -Text $p.Name -MaxLength 60), [int]$p.PercentProcessorTime }) -join ', '))) }
      if ($memory.Count -gt 0) { $s.Groups.Add(('Top memory (private MB): {0}' -f (@(foreach ($p in $memory) { '{0} {1}' -f (ConvertTo-ToolDisplayText -Text $p.Name -MaxLength 60), [math]::Round([double]$p.WorkingSetPrivate / 1MB) }) -join ', '))) }
    }
    $scheme = ([string](Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme')).Trim().ToLowerInvariant()
    if ($scheme -ne '') {
      $s.Facts['Power plan'] = $(if ($script:ReportPowerPlans.ContainsKey($scheme)) { $script:ReportPowerPlans[$scheme] } else { 'custom ({0})' -f (ConvertTo-ScreenText -Text $scheme) })
    }
    if (-not $Quick) {
      $powercfg = Get-ToolSystemTool -Name 'powercfg.exe'
      Invoke-ReportNative -Run $Run -Section $s -What 'Battery report' -FilePath $powercfg -ArgumentList '/batteryreport /output "<RAW>\battery-report.html"' -File 'battery-report.html'
      Invoke-ReportNative -Run $Run -Section $s -What 'Sleep study' -FilePath $powercfg -ArgumentList '/sleepstudy /output "<RAW>\sleepstudy.html"' -File 'sleepstudy.html'
      Invoke-ReportNative -Run $Run -Section $s -What 'Energy report' -FilePath $powercfg -ArgumentList '/energy /duration 30 /output "<RAW>\energy-report.html"' -File 'energy-report.html'
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 09 Network ----------------------------------------------------------------------------------------------------

function Get-ReportData09 {
  <#
  .SYNOPSIS
    Section 09, Network: every adapter's settings (Get-ToolNetSettings, grandchild netSettings), the network as it is
    (grandchild netState: connection and firewall profiles, addresses, default routes, DNS servers), the known network
    names (registry NetworkList profiles), the signed-in user's proxy (its own hive), the hosts file (its active lines:
    the one file this collector reads), the TCP connections counted by process and state (grandchild tcp: no
    addresses), SMBv1 (the mrxsmb10 start value) and the internet: Quick the report's one check (section 01's), Full
    also TCP 443 to five hosts at once, 3 s each (Test-ToolTcpHosts).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '09'
  try {
    $internet = Get-ReportInternet -Run $Run -Section $s
    if ($internet -is [System.Collections.IDictionary]) {
      $s.Items['Internet'] = @{ Tcp = $internet['Tcp']; Https = $internet['Https']; Probe = $internet['Probe']; Clock = $internet['Clock'] }
      $s.Facts['Internet'] = $(if (-not $internet['Tcp']) { 'no (TCP 443 failed)' }
        elseif ($internet['Clock']) { 'the clock is wrong: HTTPS fails (see the clock offset in section 01)' }
        elseif (-not $internet['Https']) { 'no (HTTPS failed)' }
        elseif ([string]$internet['Probe'] -cne 'ok') { 'OK, but a captive portal or proxy answers ({0})' -f $internet['Probe'] }
        else { 'OK (TCP 443 and HTTPS)' })
    }
    if (-not $Quick) {
      $null = Invoke-ReportSource -Section $s -What 'Microsoft 365 and update hosts' -Script {
        $answer = Test-ToolTcpHosts -Hosts $script:ReportTcpHosts -Seconds 3
        $s.Items['Hosts'] = $answer
        $s.Facts['Microsoft 365 and update hosts'] = (@(foreach ($h in $script:ReportTcpHosts) { '{0} {1}' -f $h, $(if ($answer[$h] -eq $true) { 'ok' } else { 'failed' }) }) -join ', ')
      }
    }
    $adapters = Get-ToolNetSettings -Run $Run
    if ($null -eq $adapters) {
      Add-ReportMissing -Section $s -What 'Adapter settings' -Why (Get-ToolCheckError -Run $Run -Name 'netSettings')
    } else {
      $rows = New-Object System.Collections.Generic.List[object]
      foreach ($a in $adapters) {
        $addresses = [string[]]@(foreach ($x in @($a['Addresses'])) { '{0}/{1}' -f $x['Ip'], $x['Prefix'] })
        $rows.Add([ordered]@{ Alias = [string]$a['Alias']; Mac = [string]$a['Mac']; Addresses = $addresses; Gateways = [string[]]@($a['Gateways']); Dns = [string[]]@($a['Dns']) })
        $s.Groups.Add(('Adapter {0} ({1}): DHCP v4 {2}, v6 {3}; static {4}; gateways {5}; DNS {6}' -f (ConvertTo-ToolDisplayText -Text $a['Alias'] -MaxLength 64), $a['Mac'],
            $(if ($a['Ipv4Dhcp']) { 'on' } else { 'off' }), $(if ($a['Ipv6Dhcp']) { 'on' } else { 'off' }), $(if ($addresses.Count) { $addresses -join ', ' } else { 'none' }),
            $(if (@($a['Gateways']).Count) { @($a['Gateways']) -join ', ' } else { 'none' }), $(if (@($a['Dns']).Count) { @($a['Dns']) -join ', ' } else { 'automatic' })))
      }
      $s.Items['Adapters'] = $rows.ToArray()
    }
    $state = Get-ReportChild -Run $Run -Section $s -What 'Network state' -Name 'netState' -Command $script:ReportNetStateCommand
    if ($null -ne $state) {
      # Each failed part is '<part>: <Windows' message>': the part names the source, the message goes to the log only.
      foreach ($e in @($state['Errors'])) {
        if ([string]$e -eq '') { continue }
        $part = ([string]$e -split ': ', 2)[0]
        if ($part -notmatch '^[A-Za-z ]{1,40}\z') { $part = 'a part' }
        Add-ReportMissing -Section $s -What ('Network state ({0})' -f $part) -Why ([string]$e)
      }
      $off = New-Object System.Collections.Generic.List[string]
      $firewall = @(foreach ($f in @($state['Firewall'])) {
          if ($f -isnot [System.Collections.IDictionary]) { continue }
          $on = ([string]$f['Enabled'] -eq 'True')
          if (-not $on) { $off.Add([string]$f['Name']) }
          '{0} {1}' -f $f['Name'], $(if ($on) { 'on' } else { 'off' }) })
      if ($firewall.Count -gt 0) { $s.Facts['Firewall'] = $firewall -join ', ' }
      $s.Items['FirewallOff'] = [string[]]$off.ToArray()
      foreach ($p in @($state['Profiles'])) {
        if ($p -is [System.Collections.IDictionary]) { $s.Groups.Add(('Connection {0} on {1}: {2}, IPv4 {3}, IPv6 {4}' -f (ConvertTo-ToolDisplayText -Text $p['Name'] -MaxLength 64), (ConvertTo-ToolDisplayText -Text $p['Alias'] -MaxLength 64), $p['Category'], $p['Ipv4'], $p['Ipv6'])) }
      }
      $current = [string[]]@(foreach ($x in @($state['Addresses'])) { if ($x -is [System.Collections.IDictionary]) { $s.Groups.Add(('Address {0}: {1}/{2} ({3})' -f (ConvertTo-ToolDisplayText -Text $x['Alias'] -MaxLength 64), $x['Ip'], $x['Prefix'], $x['Origin'])); [string]$x['Ip'] } })
      $gateways = [string[]]@(foreach ($g in @($state['Gateways'])) { if ($g -is [System.Collections.IDictionary]) { $s.Groups.Add(('Default route {0}: {1} (metric {2})' -f (ConvertTo-ToolDisplayText -Text $g['Alias'] -MaxLength 64), $g['NextHop'], $g['Metric'])); [string]$g['NextHop'] } })
      $servers = [string[]]@(foreach ($d in @($state['Dns'])) { if ($d -is [System.Collections.IDictionary]) { $s.Groups.Add(('DNS {0}: {1}' -f (ConvertTo-ToolDisplayText -Text $d['Alias'] -MaxLength 64), (@($d['Servers']) -join ', '))); foreach ($x in @($d['Servers'])) { [string]$x } } })
      $s.Items['CurrentAddresses'] = $current
      $s.Items['Gateways'] = $gateways
      $s.Items['DnsServers'] = $servers
    }
    $null = Invoke-ReportSource -Section $s -What 'Known networks (registry)' -Script {
      $profiles = Read-ToolRegistrySubkeys -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles'
      $known = New-Object System.Collections.Generic.List[object]
      $ssids = New-Object System.Collections.Generic.List[string]
      foreach ($p in @($profiles)) {
        $name = [string]$p['Values']['ProfileName']
        if ($name -eq '') { continue }
        $type = switch ([int](ConvertTo-ReportNumber -Value $p['Values']['NameType'])) { 71 { 'wireless' } 6 { 'wired' } 23 { 'VPN' } 243 { 'mobile' } default { 'other' } }
        $category = switch ([int](ConvertTo-ReportNumber -Value $p['Values']['Category'])) { 0 { 'Public' } 1 { 'Private' } 2 { 'Domain' } default { 'unknown' } }
        $known.Add([ordered]@{ Name = $name; Type = $type; Category = $category })
        if ($type -eq 'wireless') { $ssids.Add($name) }
        $s.Groups.Add(('Known network {0} ({1}, {2})' -f (ConvertTo-ToolDisplayText -Text $name -MaxLength 64), $type, $category))
      }
      $s.Items['NetworkProfiles'] = $known.ToArray()
      $s.Items['Ssids'] = [string[]]$ssids.ToArray()
      $s.Facts['Known networks'] = '{0} ({1} wireless)' -f $known.Count, $ssids.Count
    }
    $user = Get-ReportUser -Run $Run
    if ([string]$user['Sid'] -eq '') {
      Add-ReportMissing -Section $s -What 'User proxy' -Why $user['Error']
    } else {
      $settings = 'Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -f $user['Sid']
      $proxy = ''
      if ((ConvertTo-ReportNumber -Value (Get-RebootRegistryValue -Path $settings -Name 'ProxyEnable')) -eq 1) { $proxy = ConvertTo-ScreenText -Text (Get-RebootRegistryValue -Path $settings -Name 'ProxyServer') }
      $pac = ConvertTo-ScreenText -Text (Get-RebootRegistryValue -Path $settings -Name 'AutoConfigURL')
      if ($proxy -eq '' -and $pac -ne '') { $proxy = 'PAC ' + $pac }
      $s.Items['UserProxy'] = $proxy
      $s.Facts['Proxy'] = $(if ($proxy -eq '') { 'none' } else { $proxy })
    }
    $null = Invoke-ReportSource -Section $s -What 'hosts file' -Script {
      $text = Read-FileTail -Path ([string]$script:ToolReportPaths['Hosts']) -MaxBytes 4MB
      $active = @(foreach ($line in [regex]::Split([string]$text, '\r?\n')) {
          $clean = ($line -replace '#.*$', '').Trim()
          if ($clean -ne '') { $clean } })
      $s.Items['HostsEntries'] = $active.Count
      $s.Facts['Hosts file'] = '{0} active entries' -f $active.Count
      foreach ($line in @($active | Select-Object -First 20)) { $s.Groups.Add('hosts: ' + (ConvertTo-ToolDisplayText -Text $line -MaxLength 200)) }
    }
    $tcp = Get-ReportChild -Run $Run -Section $s -What 'TCP connections' -Name 'tcp' -Command $script:ReportTcpCommand
    if ($null -ne $tcp) {
      $byProcess = @{}
      foreach ($r in @($tcp['Items'])) {
        if ($r -isnot [System.Collections.IDictionary]) { continue }
        $name = ConvertTo-ToolDisplayText -Text $r['Process'] -MaxLength 60
        if (-not $byProcess.ContainsKey($name)) { $byProcess[$name] = @{ Total = 0; States = [ordered]@{} } }
        $byProcess[$name].Total += [int]$r['Count']
        $byProcess[$name].States[[string]$r['State']] = [int]$r['Count']
      }
      foreach ($p in @($byProcess.GetEnumerator() | Sort-Object -Property @{ Expression = { $_.Value.Total }; Descending = $true }, @{ Expression = { $_.Key } } | Select-Object -First 40)) {
        $s.Groups.Add(('TCP {0}: {1}' -f $p.Key, (@(foreach ($k in $p.Value.States.Keys) { '{0} {1}' -f $k, $p.Value.States[$k] }) -join ', ')))
      }
    }
    $smb = Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' -Name 'Start'
    $s.Items['Smb1'] = ($null -ne $smb -and [string]$smb -ne '4')
    $s.Facts['SMBv1'] = $(if ($null -eq $smb) { 'not installed' } elseif ([string]$smb -eq '4') { 'off' } else { 'on (start {0})' -f (ConvertTo-ScreenText -Text $smb) })
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 10 Software ---------------------------------------------------------------------------------------------------

function Get-ReportData10 {
  <#
  .SYNOPSIS
    Section 10, Software: the installed programs (the machine's Uninstall keys and the signed-in user's own; updates and
    system components left out), the installs of the last 30 days, another maker's system utilities
    (Get-ToolOemLeftovers), Office Click-to-Run (its version and channel by GUID), OneDrive (the user's hive: version and
    account e-mails), the startup items (Run keys, startup folders), the scheduled tasks outside \Microsoft\
    (grandchild tasks) and the services outside Windows' folder, each by its program only, and the automatic services
    that are not running (the old kit's ignore list). Full: Store apps of all users, optional features and printers
    (grandchildren appx, features, printers).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '10'
  try {
    $user = Get-ReportUser -Run $Run
    $userHive = $(if ([string]$user['Sid'] -ne '') { 'Registry::HKEY_USERS\' + $user['Sid'] } else { '' })
    if ([string]$user['Name'] -ne '') { $s.Items['SignedInUser'] = [string]$user['Name'] }
    # The SID is in task names and paths (OneDrive's and Google Update's tasks): the privacy-safe copy masks it (M3).
    if ([string]$user['Sid'] -ne '') { $s.Items['SignedInSid'] = [string]$user['Sid'] }

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($k in $script:ToolMachineUninstallKeys) { $keys.Add($k) }
    if ($userHive -ne '') { $keys.Add($userHive + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') }
    else { Add-ReportMissing -Section $s -What 'Programs of the signed-in user' -Why $user['Error'] }
    $programs = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($key in $keys) {
      try {
        $entries = Read-ToolRegistrySubkeys -Path $key
        foreach ($e in @($entries)) {
          $v = $e['Values']
          $name = ConvertTo-ToolDisplayText -Text $v['DisplayName'] -MaxLength 150
          if ($name -eq '' -or (ConvertTo-ReportNumber -Value $v['SystemComponent']) -eq 1 -or [string]$v['ParentKeyName'] -ne '') { continue }
          $version = ConvertTo-ToolDisplayText -Text $v['DisplayVersion'] -MaxLength 50
          $id = $name + '|' + $version
          if ($seen.ContainsKey($id)) { continue }
          $seen[$id] = $true
          $installed = ''
          $when = [datetime]::MinValue
          if ([datetime]::TryParseExact([string]$v['InstallDate'], 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)) {
            $installed = $when.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
          }
          $programs.Add([ordered]@{ Name = $name; Version = $version; Publisher = (ConvertTo-ToolDisplayText -Text $v['Publisher'] -MaxLength 100); InstallDate = $installed })
        }
      } catch {
        Add-ReportMissing -Section $s -What 'Installed programs' -Exception $_.Exception
      }
    }
    $sorted = @($programs.ToArray() | Sort-Object -Property @{ Expression = { $_.Name } })
    $s.Items['Programs'] = $sorted
    $s.Facts['Programs'] = [string]$sorted.Count
    $recentLimit = (Get-Date).AddDays(-30)
    $recent = @(foreach ($p in $sorted) { $when = ConvertTo-ReportDateTime -Value $p.InstallDate; if ($null -ne $when -and $when -ge $recentLimit.Date) { $p } })
    $s.Items['RecentInstalls'] = [string[]]@(foreach ($p in $recent) { $p.Name })
    $s.Facts['Installed in 30 days'] = [string]$recent.Count
    foreach ($p in $recent) { $s.Groups.Add(('Installed recently: {0} {1} ({2})' -f $p.Name, $p.Version, (ConvertTo-ReportDateTime -Value $p.InstallDate).ToString('dd/MM/yyyy', [Globalization.CultureInfo]::InvariantCulture))) }

    $identity = $Run.Args['Identity']
    $brand = ''
    if ($identity -is [System.Collections.IDictionary]) {
      $brand = [string]$identity['Brand']
      if ($brand -eq '') { $brand = Resolve-Brand -Manufacturer ([string]$identity['Manufacturer']) -Model ([string]$identity['Model']) }
    }
    $leftovers = [string[]]@(Get-ToolOemLeftovers -Programs ([string[]]@(foreach ($p in $sorted) { $p.Name })) -Brand $brand -Config $Run.Config)
    $s.Items['OemLeftovers'] = $leftovers
    $s.Facts['Other makers'' utilities'] = $(if ($leftovers.Count -gt 0) { $leftovers -join ', ' } else { 'none' })

    $c2r = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $office = ConvertTo-ScreenText -Text (Get-RebootRegistryValue -Path $c2r -Name 'VersionToReport')
    if ($office -ne '') {
      $channel = 'unknown channel'
      $guid = [regex]::Match([string](Get-RebootRegistryValue -Path $c2r -Name 'CDNBaseUrl'), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
      if ($guid.Success -and $script:ReportOfficeChannels.ContainsKey($guid.Value.ToLowerInvariant())) { $channel = $script:ReportOfficeChannels[$guid.Value.ToLowerInvariant()] }
      $s.Facts['Office'] = '{0} ({1})' -f $office, $channel
    } else {
      $s.Facts['Office'] = 'no Click-to-Run Office'
    }

    if ($userHive -ne '') {
      $null = Invoke-ReportSource -Section $s -What 'OneDrive' -Script {
        $version = ConvertTo-ScreenText -Text (Get-RebootRegistryValue -Path ($userHive + '\Software\Microsoft\OneDrive') -Name 'Version')
        $accounts = Read-ToolRegistrySubkeys -Path ($userHive + '\Software\Microsoft\OneDrive\Accounts')
        $emails = [string[]]@(foreach ($a in @($accounts)) { $mail = ([string]$a['Values']['UserEmail']).Trim(); if ($mail -ne '') { $mail } })
        $s.Items['OneDriveEmails'] = $emails
        $s.Facts['OneDrive'] = $(if ($version -eq '') { 'not installed for this user' } else { 'version {0}, signed-in accounts: {1}' -f $version, $emails.Count })
      }
    }

    $startup = New-Object System.Collections.Generic.List[object]
    $runKeys = @(@('HKLM Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'), @('HKLM Run (32-bit)', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'))
    if ($userHive -ne '') { $runKeys += , @('User Run', ($userHive + '\Software\Microsoft\Windows\CurrentVersion\Run')) }
    foreach ($pair in $runKeys) {
      try {
        $values = Read-ToolRegistryKey -Path $pair[1]
        if ($values -isnot [System.Collections.IDictionary]) { continue }
        foreach ($name in @($values.Keys | Sort-Object)) {
          if ([string]$name -eq '') { continue }
          $program = Get-ToolCommandExecutable -Command ([string]$values[$name])
          $startup.Add([ordered]@{ Name = (ConvertTo-ToolDisplayText -Text $name -MaxLength 100); Program = (ConvertTo-ToolDisplayText -Text $program -MaxLength 260); Where = $pair[0] })
        }
      } catch {
        Add-ReportMissing -Section $s -What ('Startup ' + $pair[0]) -Exception $_.Exception
      }
    }
    $folders = @(, @('Startup folder (all users)', [string]$script:ToolReportPaths['CommonStartup']))
    if ($userHive -ne '') {
      $profile = [string](Get-RebootRegistryValue -Path ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $user['Sid']) -Name 'ProfileImagePath')
      if ($profile -ne '') { $folders += , @('Startup folder (user)', [IO.Path]::Combine($profile, 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup')) }
    }
    foreach ($pair in $folders) {
      $null = Invoke-ReportSource -Section $s -What $pair[0] -Script {
        if ([IO.Directory]::Exists($pair[1])) {
          foreach ($path in [IO.Directory]::GetFiles($pair[1])) {
            $leaf = [IO.Path]::GetFileName($path)
            if ($leaf -ieq 'desktop.ini') { continue }
            $startup.Add([ordered]@{ Name = (ConvertTo-ToolDisplayText -Text $leaf -MaxLength 100); Program = ''; Where = $pair[0] })
          }
        }
      }
    }
    $s.Items['Startup'] = $startup.ToArray()
    $s.Facts['Startup items'] = [string]$startup.Count
    foreach ($item in $startup) { $s.Groups.Add(('Startup {0}: {1}{2}' -f $item.Where, $item.Name, $(if ($item.Program -ne '') { ': ' + $item.Program } else { '' }))) }

    $tasks = Get-ReportChild -Run $Run -Section $s -What 'Scheduled tasks' -Name 'tasks' -Command $script:ReportTasksCommand
    if ($null -ne $tasks) {
      $rows = @(foreach ($t in @($tasks['Items'])) {
          if ($t -isnot [System.Collections.IDictionary]) { continue }
          $programsOfTask = @(foreach ($x in @($t['Execute'])) { $p = Get-ToolCommandExecutable -Command ([string]$x); if ($p -ne '') { ConvertTo-ToolDisplayText -Text $p -MaxLength 260 } })
          [ordered]@{ Name = (ConvertTo-ToolDisplayText -Text $t['Name'] -MaxLength 150); Path = (ConvertTo-ToolDisplayText -Text $t['Path'] -MaxLength 150); State = [string]$t['State']; Execute = ($programsOfTask -join ', ') } })
      $s.Items['Tasks'] = $rows
      $s.Facts['Scheduled tasks (not Microsoft)'] = [string]$rows.Count
      foreach ($t in $rows) { $s.Groups.Add(('Task {0}{1}: {2} ({3})' -f $t.Path, $t.Name, $t.Execute, $t.State)) }
    }

    $null = Invoke-ReportSource -Section $s -What 'Services (CIM)' -Script {
      $windows = ([string]$script:ToolReportPaths['WindowsFolder']).TrimEnd('\') + '\'
      $own = New-Object System.Collections.Generic.List[object]
      $stopped = New-Object System.Collections.Generic.List[string]
      foreach ($service in @(Get-ReportCim -ClassName 'Win32_Service')) {
        $name = [string]$service.Name
        $program = Get-ToolCommandExecutable -Command ([string]$service.PathName)
        $expanded = [Environment]::ExpandEnvironmentVariables($program)
        if ([string]$service.StartMode -eq 'Auto' -and [string]$service.State -ne 'Running' -and $name -notmatch $script:ReportServiceIgnore) { $stopped.Add((ConvertTo-ScreenText -Text $name)) }
        if ($expanded -ne '' -and -not $expanded.StartsWith($windows, [StringComparison]::OrdinalIgnoreCase)) {
          $own.Add([ordered]@{ Name = (ConvertTo-ToolDisplayText -Text $name -MaxLength 100); StartMode = [string]$service.StartMode; State = [string]$service.State; Program = (ConvertTo-ToolDisplayText -Text $program -MaxLength 260) })
        }
      }
      $s.Items['Services'] = $own.ToArray()
      $s.Items['AutoStopped'] = [string[]]$stopped.ToArray()
      $s.Facts['Services (not Windows)'] = [string]$own.Count
      $s.Facts['Automatic services not running'] = $(if ($stopped.Count -gt 0) { '{0}: {1}' -f $stopped.Count, ($stopped.ToArray() -join ', ') } else { '0' })
      foreach ($x in $own) { $s.Groups.Add(('Service {0}: {1} ({2}, {3})' -f $x.Name, $x.Program, $x.StartMode, $x.State)) }
    }

    if (-not $Quick) {
      $appx = Get-ReportChild -Run $Run -Section $s -What 'Store apps' -Name 'appx' -Command $script:ReportAppxCommand
      if ($null -ne $appx) {
        $apps = @(foreach ($a in @($appx['Items'])) { if ($a -is [System.Collections.IDictionary]) { $a } })
        $s.Facts['Store apps'] = [string]$apps.Count
        foreach ($a in @($apps | Sort-Object -Property @{ Expression = { [string]$_['Name'] } })) { $s.Groups.Add(('App {0} {1}' -f (ConvertTo-ToolDisplayText -Text $a['Name'] -MaxLength 120), (ConvertTo-ScreenText -Text $a['Version']))) }
      }
      $features = Get-ReportChild -Run $Run -Section $s -What 'Optional features' -Name 'features' -Command $script:ReportFeaturesCommand
      if ($null -ne $features) {
        $names = @(foreach ($f in @($features['Items'])) { ConvertTo-ScreenText -Text $f })
        $s.Facts['Optional features on'] = [string]$names.Count
        $s.Groups.Add(('Optional features on: {0}' -f (@($names | Sort-Object) -join ', ')))
      }
      $printers = Get-ReportChild -Run $Run -Section $s -What 'Printers' -Name 'printers' -Command $script:ReportPrintersCommand -StepTimeout 'printers'
      if ($null -ne $printers) {
        $list = @(foreach ($p in @($printers['Items'])) { if ($p -is [System.Collections.IDictionary]) { $p } })
        $s.Facts['Printers'] = [string]$list.Count
        foreach ($p in $list) { $s.Groups.Add(('Printer {0} ({1}, {2}{3})' -f (ConvertTo-ToolDisplayText -Text $p['Name'] -MaxLength 120), (ConvertTo-ToolDisplayText -Text $p['Driver'] -MaxLength 120), (ConvertTo-ToolDisplayText -Text $p['Port'] -MaxLength 80), $(if ($p['Shared'] -eq $true) { ', shared' } else { '' }))) }
      }
    }
    foreach ($p in $sorted) { $s.Groups.Add(('Program {0} {1}{2}' -f $p.Name, $p.Version, $(if ($p.Publisher -ne '') { ' (' + $p.Publisher + ')' } else { '' }))) }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 11 Security ---------------------------------------------------------------------------------------------------

function Get-ReportData11 {
  <#
  .SYNOPSIS
    Section 11, Security: Defender (Get-MpComputerStatus, grandchild defender), the antivirus products Windows Security
    knows (root\SecurityCenter2; Defender by its windowsdefender:// path), UAC, Smart App Control, the local users
    (Win32_UserAccount; the Guest account by its SID, -501), the Administrators group by its SID S-1-5-32-544
    (grandchild admins: Get-LocalGroupMember -SID, else ADSI on the translated name; review M4), the signed-in user and
    their SID, the profiles, automatic sign-in (AutoAdminLogon only:
    its password is never read), Remote Desktop and NLA, and the join state (domain, Entra ID). Full: gpresult /h and
    dsregcmd /status to raw.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '11'
  try {
    $defender = Get-ReportChild -Run $Run -Section $s -What 'Defender' -Name 'defender' -Command $script:ReportDefenderCommand
    if ($null -ne $defender) {
      $s.Items['Defender'] = @{ RealTime = ($defender['RealTime'] -eq $true); Mode = [string]$defender['Mode']; AntivirusEnabled = ($defender['AntivirusEnabled'] -eq $true); Tamper = ($defender['Tamper'] -eq $true) }
      $age = ConvertTo-ReportNumber -Value $defender['SignatureAge']
      if ($null -ne $age) { $s.Items['SignatureAgeDays'] = [int]$age }
      $s.Facts['Defender'] = 'real-time {0}, signatures {1} days old, {2}{3}' -f $(if ($defender['RealTime'] -eq $true) { 'on' } else { 'off' }), (Format-ReportNumber -Value $age -Format '0'),
        (ConvertTo-ScreenText -Text $defender['Mode']), $(if ($defender['Tamper'] -eq $true) { ', tamper protection on' } else { '' })
    }
    $null = Invoke-ReportSource -Section $s -What 'Antivirus products (CIM)' -Script {
      $products = @(foreach ($p in @(Get-ReportCim -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct')) {
          $state = [long](ConvertTo-ReportNumber -Value $p.productState)
          [ordered]@{ Name = (ConvertTo-ToolDisplayText -Text $p.displayName -MaxLength 100); Defender = ([string]$p.pathToSignedProductExe).StartsWith('windowsdefender:', [StringComparison]::OrdinalIgnoreCase)
                      Enabled = ((($state -shr 12) -band 0xF) -eq 1); UpToDate = ((($state -shr 4) -band 0xF) -eq 0) } })
      $s.Items['AvProducts'] = $products
      $s.Facts['Antivirus'] = $(if ($products.Count -eq 0) { 'none registered' } else {
          (@(foreach ($p in $products) { '{0} ({1}, {2})' -f $p.Name, $(if ($p.Enabled) { 'on' } else { 'off' }), $(if ($p.UpToDate) { 'up to date' } else { 'out of date' }) }) -join '; ') })
    }
    $system = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $uac = [ordered]@{}
    foreach ($name in 'EnableLUA', 'ConsentPromptBehaviorAdmin', 'PromptOnSecureDesktop') { $uac[$name] = ConvertTo-ReportNumber -Value (Get-RebootRegistryValue -Path $system -Name $name) }
    $s.Items['Uac'] = $uac
    $s.Facts['UAC'] = '{0} (EnableLUA {1}, ConsentPromptBehaviorAdmin {2}, PromptOnSecureDesktop {3})' -f $(if ($uac['EnableLUA'] -eq 0) { 'off' } else { 'on' }),
      (Format-ReportNumber -Value $uac['EnableLUA'] -Format '0'), (Format-ReportNumber -Value $uac['ConsentPromptBehaviorAdmin'] -Format '0'), (Format-ReportNumber -Value $uac['PromptOnSecureDesktop'] -Format '0')
    $s.Facts['Smart App Control'] = Get-SmartAppControlState

    $null = Invoke-ReportSource -Section $s -What 'Local users (CIM)' -Script {
      $names = New-Object System.Collections.Generic.List[string]
      $builtin = New-Object System.Collections.Generic.List[string]
      $texts = New-Object System.Collections.Generic.List[string]
      $guest = $false
      foreach ($u in @(Get-ReportCim -ClassName 'Win32_UserAccount' -Filter 'LocalAccount=True')) {
        $name = ConvertTo-ToolDisplayText -Text $u.Name -MaxLength 100
        $sid = [string]$u.SID
        $names.Add($name)
        # Guest, DefaultAccount and WDAGUtilityAccount by SID (their names are localized, never a person's), so the
        # privacy-safe copy keeps them (Task 9). The built-in Administrator (-500) is left out: it may be renamed.
        if ($sid -match '-50[134]\z') { $builtin.Add($name) }
        if ($sid -match '-501\z' -and $u.Disabled -ne $true) { $guest = $true }
        $texts.Add(('{0}{1}' -f $name, $(if ($u.Disabled -eq $true) { ' (disabled)' } elseif ($sid -match '-50[01]\z') { ' (on)' } else { '' })))
      }
      $s.Items['Users'] = [string[]]$names.ToArray()
      $s.Items['BuiltinUsers'] = [string[]]$builtin.ToArray()
      $s.Items['GuestEnabled'] = $guest
      $s.Facts['Local users'] = $texts.ToArray() -join ', '
    }
    $group = Get-ReportChild -Run $Run -Section $s -What 'Administrators' -Name 'admins' -Command $script:ReportAdminsCommand
    if ($null -ne $group) {
      $viaAdsi = ([string]$group['Source'] -ceq 'ADSI')
      if ($viaAdsi) {
        Write-SetupLog -Level WARN -Message 'Get-LocalGroupMember failed; the Administrators were read through ADSI' -Data @{ error = (ConvertTo-ScreenText -Text $group['LocalError']) }
      }
      $admins = @(foreach ($m in @($group['Items'])) {
          if ($m -is [System.Collections.IDictionary]) { @{ Name = [string]$m['Name']; Sid = [string]$m['Sid']; Source = [string]$m['Source'] } } })
      $s.Items['Admins'] = $admins
      $s.Facts['Administrators'] = '{0}{1}' -f (@(foreach ($a in $admins) { ConvertTo-ToolDisplayText -Text $a['Name'] -MaxLength 100 }) -join ', '), $(if ($viaAdsi) { ' (read through ADSI)' } else { '' })
    }
    $null = Invoke-ReportSource -Section $s -What 'Profiles (registry)' -Script {
      $profiles = Read-ToolRegistrySubkeys -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
      # People's profiles: local and domain (S-1-5-21-...) and Azure AD (S-1-12-1-..., RD-R27), so their folder names are
      # known values for the privacy-safe copy; the system's own (S-1-5-18/19/20) are left out.
      $s.Items['Profiles'] = [string[]]@(foreach ($p in @($profiles)) { if ([string]$p['Name'] -match '^S-1-(?:5-21|12-1)-') { [string]$p['Values']['ProfileImagePath'] } })
    }
    $user = Get-ReportUser -Run $Run
    if ([string]$user['Name'] -ne '') { $s.Items['SignedInUser'] = [string]$user['Name']; $s.Facts['Signed in'] = ConvertTo-ToolDisplayText -Text $user['Name'] -MaxLength 100 }
    if ([string]$user['Sid'] -ne '') { $s.Items['SignedInSid'] = [string]$user['Sid'] }

    # Presence only: Winlogon's other values (the password among them) are never read.
    $s.Items['AutoLogon'] = ([string](Get-RebootRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoAdminLogon')).Trim() -eq '1'
    $s.Facts['Automatic sign-in'] = $(if ($s.Items['AutoLogon']) { 'yes' } else { 'no' })
    $deny = ConvertTo-ReportNumber -Value (Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections')
    $nla = ConvertTo-ReportNumber -Value (Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication')
    $rdpOn = ($null -ne $deny -and $deny -eq 0)
    $s.Items['Rdp'] = @{ Enabled = $rdpOn; Nla = ($null -eq $nla -or $nla -ne 0) }
    $s.Facts['Remote Desktop'] = $(if (-not $rdpOn) { 'off' } elseif ($null -ne $nla -and $nla -eq 0) { 'on, without NLA' } else { 'on, with NLA' })
    $null = Invoke-ReportSource -Section $s -What 'Join state' -Script {
      $cs = @(Get-ReportCim -ClassName 'Win32_ComputerSystem') | Select-Object -First 1
      $joined = Read-ToolRegistrySubkeys -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
      $domain = $(if ($null -ne $cs -and $cs.PartOfDomain -eq $true) { 'domain ' + (ConvertTo-ToolDisplayText -Text $cs.Domain -MaxLength 300) } else { 'workgroup' })
      $s.Facts['Join'] = '{0}, {1}' -f $domain, $(if (@($joined).Count -gt 0) { 'Entra ID joined' } else { 'not Entra ID joined' })
    }
    if (-not $Quick) {
      Invoke-ReportNative -Run $Run -Section $s -What 'Group policy report' -FilePath (Get-ToolSystemTool -Name 'gpresult.exe') -ArgumentList '/h "<RAW>\gpresult.html" /f' -File 'gpresult.html'
      Invoke-ReportNative -Run $Run -Section $s -What 'Device registration' -FilePath (Get-ToolSystemTool -Name 'dsregcmd.exe') -ArgumentList '/status' -OutputName 'dsregcmd'
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- 12 msinfo32 ---------------------------------------------------------------------------------------------------

function Get-ReportData12 {
  <#
  .SYNOPSIS
    Section 12, msinfo32 (Full only): msinfo32 /nfo and /report to raw, each bounded by toolStep.msinfo32. Quick runs
    nothing here (the Quick report has no section 12).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][bool]$Quick)

  $s = New-ReportSection -Id '12'
  try {
    if (-not $Quick) {
      $msinfo = Get-ToolSystemTool -Name 'msinfo32.exe'
      Invoke-ReportNative -Run $Run -Section $s -What 'msinfo32 /nfo' -FilePath $msinfo -ArgumentList '/nfo "<RAW>\msinfo32.nfo"' -File 'msinfo32.nfo' -StepTimeout 'msinfo32'
      Invoke-ReportNative -Run $Run -Section $s -What 'msinfo32 /report' -FilePath $msinfo -ArgumentList '/report "<RAW>\msinfo32.txt"' -File 'msinfo32.txt' -StepTimeout 'msinfo32'
      if ($s.Raw.Count -gt 0) { $s.Facts['msinfo32'] = $s.Raw.ToArray() -join ', ' }
    }
  } catch {
    Add-ReportMissing -Section $s -What 'This section' -Exception $_.Exception
  }
  return (Complete-ReportSection -Section $s)
}

# --- The connectivity test -----------------------------------------------------------------------------------------

function Test-ToolTcpHosts {
  <#
  .SYNOPSIS
    TCP 443 to each of -Hosts, all started together and each given at most -Seconds (one shared Stopwatch, so the
    whole test takes about -Seconds): host -> $true when its connection opened. Never throws.
  .DESCRIPTION
    -Connect { param($HostName) } starts one connection and returns @{ Client (disposed afterwards, or $null); Task };
    by default a TcpClient's ConnectAsync(<host>, 443). A seam that throws, a task that faults or one still running at
    the bound is $false.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string[]]$Hosts,
    [ValidateRange(1, 60)][int]$Seconds = 3,
    [scriptblock]$Connect = { param($HostName) $client = New-Object Net.Sockets.TcpClient; @{ Client = $client; Task = $client.ConnectAsync($HostName, 443) } }
  )

  $started = @{}
  $answer = @{}
  $clock = [Diagnostics.Stopwatch]::StartNew()
  try {
    foreach ($h in $Hosts) {
      try { $started[$h] = & $Connect $h } catch { $started[$h] = $null }
    }
    foreach ($h in $Hosts) {
      $ok = $false
      $attempt = $started[$h]
      if ($attempt -is [System.Collections.IDictionary] -and $attempt['Task'] -is [Threading.Tasks.Task]) {
        $left = [int][math]::Max(0, $Seconds * 1000 - $clock.ElapsedMilliseconds)
        try { $ok = [bool]$attempt['Task'].Wait($left) -and -not $attempt['Task'].IsFaulted } catch { $ok = $false }
      }
      $answer[$h] = $ok
    }
  } finally {
    foreach ($attempt in $started.Values) {
      if ($attempt -is [System.Collections.IDictionary] -and $attempt['Client'] -is [IDisposable]) { try { $attempt['Client'].Dispose() } catch { } }
    }
  }
  return $answer
}

# --- The steps -----------------------------------------------------------------------------------------------------

function Invoke-ToolReportSection {
  # Private. Collects section -Id (Get-ReportData<Id>, Quick unless the action is fullReport) into $Run.Data.Report.
  # 'warn' when a source was not collected, else 'done'.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$Id)

  $quick = ([string]$Run.Args['Action'] -cne 'fullReport')
  if ($Run.Data['Report'] -isnot [System.Collections.IDictionary]) { $Run.Data['Report'] = [ordered]@{} }
  $section = & ('Get-ReportData' + $Id) -Run $Run -Quick $quick
  $Run.Data['Report'][$Id] = $section
  $missing = @($section['Missing']).Count
  Add-ToolLog -Run $Run -Text ('Section {0}: {1} facts, {2} details, {3} not collected' -f $Id, $section['Facts'].Count, @($section['Groups']).Count, $missing)
  if ($missing -gt 0) { return 'warn' }
  return 'done'
}

function Invoke-ToolStepReport01 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '01' }
function Invoke-ToolStepReport02 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '02' }
function Invoke-ToolStepReport03 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '03' }
function Invoke-ToolStepReport04 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '04' }
function Invoke-ToolStepReport05 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '05' }
function Invoke-ToolStepReport06 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '06' }
function Invoke-ToolStepReport07 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '07' }
function Invoke-ToolStepReport08 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '08' }
function Invoke-ToolStepReport09 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '09' }
function Invoke-ToolStepReport10 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '10' }
function Invoke-ToolStepReport11 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '11' }
function Invoke-ToolStepReport12 { [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][hashtable]$Run) Invoke-ToolReportSection -Run $Run -Id '12' }
