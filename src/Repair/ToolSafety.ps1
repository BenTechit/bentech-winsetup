# src/Repair/ToolSafety.ps1
# Repair & diagnostics: the safety strip (repair spec 5), computed by the safety action's child, never on the
# window's thread: Get-PhysicalDisk and the like can hang on exactly the failing disks this is for (Review Focus 1).
#
# Each chip is @{ Level = 'ok'|'warn'|'crit'|'unknown'; Args = [string[]] (ASCII); Detail = @{...} } (repair plan,
# "Safety strip, chips and gates"). The safety steps (Invoke-ToolStepSafety*) store each chip in $Run.Data.Chips and
# $Run.Partial.Chips and write the progress at once, so the window shows a chip as soon as it is known; a chip that
# could not be read in time is 'unknown' (yellow) and blocks nothing. A chip reader never throws, and a step whose
# reader fails anyway stores an unknown chip: the safety action never ends red because of a chip.
#
#   Restart   : the servicing signals only (CBS RebootPending / PackagesPending, pending.xml, WU RebootRequired) are
#               red; a pending file or computer rename is a grey note.
#   Free      : the system drive under freeSpace.minPercent % or under freeSpace.minGB GB is red.
#   BitLocker : CIM Win32_EncryptableVolume, protection status and protector TYPES only (never a key or password).
#   Internet  : TCP 443 to repair.internet.host, then an HTTPS GET of repair.internet.url (5 s each); its Date header
#               gives the clock offset.
#   Disk      : Get-PhysicalDisk and Get-StorageReliabilityCounter in grandchildren, and the System log's disk 7, 51,
#               153 and NTFS 55 events of the last diskEventDays.
# Plus the disk check state: the system volume's dirty bit, and whether BootExecute excludes the drive (/k:).
#
# Every threshold comes from config.json's repair section; a missing key falls back to the values the spec pins
# (repair is not a required config key). Needs ToolEngine (Invoke-ToolJsonChild, Add-ToolLog, Write-ToolProgress),
# Reboot (Get-ServicingRebootSignals, Test-ServicingRebootPending, Get-RebootRegistryValue), Logging and StartScreen
# (ConvertTo-ScreenText). The bundle holds every file.

# Get-PhysicalDisk: one row per disk. HealthStatus and MediaType are enum names (Healthy, Warning, Unhealthy,
# Unknown; SSD, HDD), never localized.
$script:ToolDisksCommand = @'
@{ Items = @(Get-PhysicalDisk | ForEach-Object {
  @{ DeviceId = [string]$_.DeviceId; FriendlyName = [string]$_.FriendlyName; MediaType = [string]$_.MediaType
     BusType = [string]$_.BusType; HealthStatus = [string]$_.HealthStatus; Size = [long]$_.Size } }) }
'@

# Get-StorageReliabilityCounter of each disk (wear %, temperature in C, uncorrected read and write errors). A disk
# that reports no counters (USB, some RAID and virtual disks) gives $null values, not a failure.
$script:ToolReliabilityCommand = @'
@{ Items = @(Get-PhysicalDisk | ForEach-Object {
  $disk = $_
  $counter = $null
  try { $counter = $disk | Get-StorageReliabilityCounter } catch { $counter = $null }
  @{ DeviceId = [string]$disk.DeviceId; Wear = $counter.Wear; Temperature = $counter.Temperature
     ReadErrorsUncorrected = $counter.ReadErrorsUncorrected; WriteErrorsUncorrected = $counter.WriteErrorsUncorrected } }) }
'@

$script:ToolBitLockerNamespace = 'root\cimv2\Security\MicrosoftVolumeEncryption'

# Win32_EncryptableVolume.GetKeyProtectorType -> the type names Get-BitLockerVolume uses. Only the TYPES are read.
$script:ToolKeyProtectorTypes = @{
  0 = 'Unknown'; 1 = 'Tpm'; 2 = 'ExternalKey'; 3 = 'RecoveryPassword'; 4 = 'TpmPin'; 5 = 'TpmStartupKey'
  6 = 'TpmPinStartupKey'; 7 = 'PublicKey'; 8 = 'Password'; 9 = 'TpmNetworkKey'; 10 = 'AdAccountOrGroup'
}

# --- Config and chips ---------------------------------------------------------------------------------------------

function Get-ToolRepairSetting {
  # Private. config.repair.<Path...> (JSON objects or hashtables), or -Default when any part is missing or $null.
  [CmdletBinding()]
  param(
    [AllowNull()]$Config,
    [Parameter(Mandatory)][string[]]$Path,
    [AllowNull()]$Default
  )

  $node = $Config
  foreach ($name in @('repair') + $Path) {
    if ($null -eq $node) { return $Default }
    if ($node -is [System.Collections.IDictionary]) {
      if (-not $node.Contains($name)) { return $Default }
      $node = $node[$name]
    } else {
      $property = $node.PSObject.Properties[$name]
      if ($null -eq $property) { return $Default }
      $node = $property.Value
    }
  }
  if ($null -eq $node) { return $Default }
  return $node
}

function Get-ToolRepairNumber {
  # Private. A number above 0 at config.repair.<Path...> (Get-ToolRepairSetting), else -Default.
  [CmdletBinding()]
  [OutputType([double])]
  param(
    [AllowNull()]$Config,
    [Parameter(Mandatory)][string[]]$Path,
    [Parameter(Mandatory)][double]$Default
  )

  $value = Get-ToolRepairSetting -Config $Config -Path $Path -Default $null
  $number = 0.0
  if ($null -ne $value -and [double]::TryParse([string]$value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -gt 0) {
    return $number
  }
  return $Default
}

function ConvertTo-ToolNumber {
  # Private. A JSON number (or numeric text) as a [double]; $null for $null or anything else.
  [CmdletBinding()]
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $null }
  $number = 0.0
  if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
  return $null
}

function New-ToolChip {
  # Private. A chip: @{ Level; Args = [string[]] (ASCII); Detail }.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'crit', 'unknown')][string]$Level,
    [AllowNull()][object[]]$Arguments,
    [AllowNull()][hashtable]$Detail
  )

  $values = [string[]]@()
  if ($null -ne $Arguments) { $values = [string[]]@(foreach ($a in $Arguments) { ConvertTo-ScreenText -Text $a }) }
  if ($null -eq $Detail) { $Detail = @{} }
  return @{ Level = $Level; Args = $values; Detail = $Detail }
}

function New-ToolUnknownChip {
  # Private. An 'unknown' chip for a reader that failed: the reason (ASCII) in Detail.Error, logged as a WARN.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$Name,
    [AllowNull()][AllowEmptyString()][string]$Reason,
    [AllowNull()][object[]]$Arguments
  )

  $text = ConvertTo-ScreenText -Text $Reason
  Write-SetupLog -Level WARN -Message 'A safety chip could not be read' -Data @{ chip = $Name; error = $text }
  return (New-ToolChip -Level 'unknown' -Arguments $Arguments -Detail @{ Error = $text })
}

# --- The chip readers ---------------------------------------------------------------------------------------------

function Get-ToolRestartChip {
  <#
  .SYNOPSIS
    The Restart chip (spec 5): 'crit' when a servicing restart is pending (Test-ServicingRebootPending), else 'ok';
    'unknown' when the signals cannot be read. Never throws.
  .DESCRIPTION
    Detail.Signals names the servicing signals that are set (CbsRebootPending, CbsPackagesPending, PendingXml,
    WuRebootRequired); Detail.Notes the grey notes (PendingFileRename, ComputerRenamePending), which are set on most
    PCs and never make the chip red.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  try {
    $signals = Get-ServicingRebootSignals
    $set = [string[]]@(foreach ($name in 'CbsRebootPending', 'CbsPackagesPending', 'PendingXml', 'WuRebootRequired') { if ($signals[$name] -eq $true) { $name } })
    $notes = [string[]]@(foreach ($name in 'PendingFileRename', 'ComputerRenamePending') { if ($signals[$name] -eq $true) { $name } })
    $level = if (Test-ServicingRebootPending -Signals $signals) { 'crit' } else { 'ok' }
    return (New-ToolChip -Level $level -Detail @{ Signals = $set; Notes = $notes })
  } catch {
    return (New-ToolUnknownChip -Name 'Restart' -Reason $_.Exception.Message)
  }
}

function ConvertTo-ToolFreeChip {
  <#
  .SYNOPSIS
    The Free chip from a drive's bytes (pure): 'crit' when the free space is under repair.freeSpace.minPercent % (10)
    or under repair.freeSpace.minGB GB (15), else 'ok'; 'unknown' for a size of 0. Args = @(<drive>, <whole
    percent free, rounded down>), e.g. @('C:', '41').
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][long]$FreeBytes,
    [Parameter(Mandatory)][long]$TotalBytes,
    [Parameter(Mandatory)][AllowNull()]$Config,
    [string]$Drive = 'C:'
  )

  if ($TotalBytes -le 0 -or $FreeBytes -lt 0) {
    return (New-ToolChip -Level 'unknown' -Arguments @($Drive) -Detail @{ FreeBytes = $FreeBytes; TotalBytes = $TotalBytes })
  }
  $minPercent = Get-ToolRepairNumber -Config $Config -Path 'freeSpace', 'minPercent' -Default 10
  $minGB = Get-ToolRepairNumber -Config $Config -Path 'freeSpace', 'minGB' -Default 15
  $percent = [double]$FreeBytes * 100 / [double]$TotalBytes
  $gigabytes = [double]$FreeBytes / 1GB
  $level = if ($percent -lt $minPercent -or $gigabytes -lt $minGB) { 'crit' } else { 'ok' }
  $whole = ([long][math]::Floor($percent)).ToString([Globalization.CultureInfo]::InvariantCulture)
  return (New-ToolChip -Level $level -Arguments @($Drive, $whole) -Detail @{
      FreeBytes = $FreeBytes; TotalBytes = $TotalBytes; FreeGB = [math]::Round($gigabytes, 1) })
}

function Get-ToolDriveSpace {
  # Private seam (tests mock it). The free and total bytes of -Drive ('C:') from [IO.DriveInfo]; throws when the
  # drive is not ready.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][string]$Drive)

  $info = New-Object IO.DriveInfo $Drive
  if (-not $info.IsReady) { throw ('Drive {0} is not ready' -f $Drive) }
  return @{ FreeBytes = [long]$info.AvailableFreeSpace; TotalBytes = [long]$info.TotalSize }
}

function Get-ToolFreeSpaceChip {
  <#
  .SYNOPSIS
    The Free chip of the system drive ($env:SystemDrive): its drive info (Get-ToolDriveSpace), then
    ConvertTo-ToolFreeChip. 'unknown' (Args = @(<drive>)) when the drive cannot be read. Never throws.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][AllowNull()]$Config)

  $drive = [string]$env:SystemDrive
  try {
    $space = Get-ToolDriveSpace -Drive $drive
    return (ConvertTo-ToolFreeChip -FreeBytes $space['FreeBytes'] -TotalBytes $space['TotalBytes'] -Config $Config -Drive $drive)
  } catch {
    return (New-ToolUnknownChip -Name 'Free' -Reason $_.Exception.Message -Arguments @($drive))
  }
}

function Get-ToolBitLockerChip {
  <#
  .SYNOPSIS
    The BitLocker chip of -Drive (the system drive): 'ok' when protection is off, 'warn' when it is on (the
    reminder: have the recovery key before BIOS or board work), 'unknown' when it cannot be read in 15 s. Never
    throws.
  .DESCRIPTION
    CIM Win32_EncryptableVolume (root\cimv2\Security\MicrosoftVolumeEncryption) with -OperationTimeoutSec 15: its
    ProtectionStatus (0 off, 1 on, anything else unknown), GetKeyProtectors and GetKeyProtectorType for each id.
    Detail = @{ ProtectionStatus; Protectors = the type names (Tpm, RecoveryPassword, ...) }. No method that returns
    a key or a password is ever called.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([string]$Drive = $env:SystemDrive)

  try {
    $volume = @(Get-CimInstance -Namespace $script:ToolBitLockerNamespace -ClassName 'Win32_EncryptableVolume' -Filter ("DriveLetter='{0}'" -f $Drive) -OperationTimeoutSec 15 -ErrorAction Stop) |
      Select-Object -First 1
    if ($null -eq $volume) { return (New-ToolUnknownChip -Name 'BitLocker' -Reason ('no encryptable volume {0}' -f $Drive)) }
    $status = [int]$volume.ProtectionStatus
    $answer = Invoke-CimMethod -InputObject $volume -MethodName 'GetKeyProtectors' -Arguments @{ KeyProtectorType = [uint32]0 } -OperationTimeoutSec 15 -ErrorAction Stop
    if ($null -ne $answer.ReturnValue -and [long]$answer.ReturnValue -ne 0) { throw ('GetKeyProtectors returned {0}' -f [long]$answer.ReturnValue) }
    $types = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($answer.VolumeKeyProtectorID)) {
      if ([string]::IsNullOrEmpty([string]$id)) { continue }
      $type = Invoke-CimMethod -InputObject $volume -MethodName 'GetKeyProtectorType' -Arguments @{ VolumeKeyProtectorID = [string]$id } -OperationTimeoutSec 15 -ErrorAction Stop
      $number = [int]$type.KeyProtectorType
      if ($script:ToolKeyProtectorTypes.ContainsKey($number)) { $types.Add($script:ToolKeyProtectorTypes[$number]) } else { $types.Add('Unknown') }
    }
    $level = 'unknown'
    if ($status -eq 0) { $level = 'ok' } elseif ($status -eq 1) { $level = 'warn' }
    return (New-ToolChip -Level $level -Detail @{ ProtectionStatus = $status; Protectors = $types.ToArray() })
  } catch {
    return (New-ToolUnknownChip -Name 'BitLocker' -Reason $_.Exception.Message)
  }
}

function Test-ToolInternet {
  <#
  .SYNOPSIS
    The internet check (spec 5): @{ Tcp; Https; ClockOffsetSeconds; Chip }. Never throws.
  .DESCRIPTION
    First TCP 443 to repair.internet.host (www.msftconnecttest.com), then, only when that answered, an HTTPS GET of
    repair.internet.url (https://www.msftconnecttest.com/connecttest.txt), each bounded by repair.internet.seconds
    (5). The chip is 'ok' when both answered, else 'crit'. ClockOffsetSeconds is this PC's UTC time minus the
    response's Date header (positive: the PC is ahead), $null without it.
    The two seams (tests pass their own):
      -Connect { param($HostName, $Milliseconds) } -> bool: TcpClient.ConnectAsync(host, 443).Wait(ms).
      -Fetch   { param($Url, $Milliseconds) } -> @{ Ok; Date (UTC [datetime] or $null) }: [Net.HttpWebRequest] GET with
               Timeout and ReadWriteTimeout ms and TLS 1.2, no redirect followed; Ok for a 2xx status. Plan call:
               HttpWebRequest because WebClient has no timeout; never Invoke-WebRequest.
    A seam that throws or answers anything else counts as failed.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][AllowNull()]$Config,
    [scriptblock]$Connect = {
      param([string]$HostName, [int]$Milliseconds)
      $client = New-Object Net.Sockets.TcpClient
      try {
        return [bool]$client.ConnectAsync($HostName, 443).Wait($Milliseconds)
      } catch {
        return $false
      } finally {
        $client.Dispose()
      }
    },
    [scriptblock]$Fetch = {
      param([string]$Url, [int]$Milliseconds)
      $response = $null
      try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $Milliseconds
        $request.ReadWriteTimeout = $Milliseconds
        $request.AllowAutoRedirect = $false
        $response = [Net.HttpWebResponse]$request.GetResponse()
        $code = [int]$response.StatusCode
        $date = $null
        $parsed = [datetime]::MinValue
        $header = [string]$response.Headers['Date']
        if ($header -ne '' -and [datetime]::TryParseExact($header, 'r', [Globalization.CultureInfo]::InvariantCulture,
            ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$parsed)) {
          $date = $parsed
        }
        return @{ Ok = ($code -ge 200 -and $code -lt 300); Date = $date }
      } catch {
        return @{ Ok = $false; Date = $null }
      } finally {
        if ($null -ne $response) { $response.Close() }
      }
    }
  )

  $hostName = [string](Get-ToolRepairSetting -Config $Config -Path 'internet', 'host' -Default 'www.msftconnecttest.com')
  $url = [string](Get-ToolRepairSetting -Config $Config -Path 'internet', 'url' -Default 'https://www.msftconnecttest.com/connecttest.txt')
  $milliseconds = [int][math]::Round((Get-ToolRepairNumber -Config $Config -Path 'internet', 'seconds' -Default 5) * 1000)

  $tcp = $false
  try {
    $answer = @(& $Connect $hostName $milliseconds)
    $tcp = ($answer.Count -eq 1 -and $answer[0] -is [bool] -and $answer[0])
  } catch {
    $tcp = $false
  }
  $https = $false
  $offset = $null
  if ($tcp) {
    try {
      $answer = @(& $Fetch $url $milliseconds)
      if ($answer.Count -eq 1 -and $answer[0] -is [System.Collections.IDictionary]) {
        $https = ($answer[0]['Ok'] -eq $true)
        $date = $answer[0]['Date']
        if ($https -and $date -is [datetime]) {
          if ($date.Kind -eq [DateTimeKind]::Local) { $date = $date.ToUniversalTime() }
          $offset = [math]::Round(([datetime]::UtcNow - [datetime]::SpecifyKind($date, [DateTimeKind]::Utc)).TotalSeconds, 1)
        }
      }
    } catch {
      $https = $false
    }
  }
  $level = if ($tcp -and $https) { 'ok' } else { 'crit' }
  Write-SetupLog -Message 'Internet check' -Data @{ tcp = $tcp; https = $https; clockOffsetSeconds = $offset }
  return @{
    Tcp                = $tcp
    Https              = $https
    ClockOffsetSeconds = $offset
    Chip               = (New-ToolChip -Level $level -Detail @{ Tcp = $tcp; Https = $https; ClockOffsetSeconds = $offset })
  }
}

function Get-ToolDiskEventCount {
  <#
  .SYNOPSIS
    The listed disk events of the last -Days days: @{ Ok; Count; Ids = [string[]] ('<provider>/<id>') }. Never
    throws.
  .DESCRIPTION
    Get-WinEvent -FilterHashtable on the System log by ID (7, 51, 153, 55) and start time, then by provider: 'disk'
    with 7, 51 or 153, and 'Ntfs' or 'Microsoft-Windows-Ntfs' with 55 (an event's provider name is never localized).
    The providers are checked after the query because a ProviderName that is not registered on a PC fails the whole
    query (NoMatchingProvidersFound). NoMatchingEventsFound is 0 events; any other error is Ok = $false.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][int]$Days)

  $events = @()
  try {
    $filter = @{ LogName = 'System'; Id = @(7, 51, 153, 55); StartTime = (Get-Date).AddDays(-$Days) }
    $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 5000 -ErrorAction Stop)
  } catch {
    if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @{ Ok = $true; Count = 0; Ids = [string[]]@() } }
    $reason = ConvertTo-ScreenText -Text $_.Exception.Message
    Write-SetupLog -Level WARN -Message 'The disk events could not be read' -Data @{ error = $reason }
    return @{ Ok = $false; Count = $null; Ids = [string[]]@(); Error = $reason }
  }
  $hits = @(foreach ($e in $events) {
      $provider = [string]$e.ProviderName
      $id = [int]$e.Id
      if (($provider -eq 'disk' -and $id -in 7, 51, 153) -or ($provider -in 'Ntfs', 'Microsoft-Windows-Ntfs' -and $id -eq 55)) {
        '{0}/{1}' -f $provider, $id
      }
    })
  return @{ Ok = $true; Count = $hits.Count; Ids = [string[]]@($hits | Sort-Object -Unique) }
}

function Get-ToolDiskChip {
  <#
  .SYNOPSIS
    The Disk chip (spec 5). Never throws.
  .DESCRIPTION
    Sources: the grandchild 'disks' (Get-PhysicalDisk), the grandchild 'reliability' (Get-StorageReliabilityCounter;
    not run when the disk list failed, as it would hang or fail the same way) and Get-ToolDiskEventCount for
    repair.thresholds.diskEventDays (30).
      crit    : a disk whose HealthStatus is not Healthy, uncorrected read or write errors above 0, or any listed disk
                event (the reason 'health', 'errors' or 'events');
      warn    : wear at or above thresholds.diskWearPercent (80) or a temperature at or above
                thresholds.diskTemperatureC (60) ('wear', 'temperature');
      unknown : a source failed or timed out ('disks', 'reliability' or 'events' in Detail.Failed), or no disk was
                listed, and nothing above;
      ok      : else.
    A known problem wins over a source that failed. Detail = @{ Reasons; Failed; Events; EventIds; Disks = @( @{
    DeviceId; FriendlyName; MediaType; BusType; Health; Wear; Temperature; ReadErrorsUncorrected;
    WriteErrorsUncorrected } ) } (ASCII).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try {
    $wearLimit = Get-ToolRepairNumber -Config $Run.Config -Path 'thresholds', 'diskWearPercent' -Default 80
    $heatLimit = Get-ToolRepairNumber -Config $Run.Config -Path 'thresholds', 'diskTemperatureC' -Default 60
    $days = [int](Get-ToolRepairNumber -Config $Run.Config -Path 'thresholds', 'diskEventDays' -Default 30)
    $failed = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]

    $disks = @()
    $list = Invoke-ToolJsonChild -Run $Run -Name 'disks' -Command $script:ToolDisksCommand
    if ($list.Ok -and $list.Data.ContainsKey('Items')) {
      $disks = @(foreach ($d in @($list.Data['Items'])) { if ($d -is [System.Collections.IDictionary]) { $d } })
      if ($disks.Count -eq 0) { $failed.Add('disks') }
    } else {
      $failed.Add('disks')
    }
    $counters = @{}
    if ($list.Ok) {
      $reliability = Invoke-ToolJsonChild -Run $Run -Name 'reliability' -Command $script:ToolReliabilityCommand
      if ($reliability.Ok -and $reliability.Data.ContainsKey('Items')) {
        foreach ($c in @($reliability.Data['Items'])) { if ($c -is [System.Collections.IDictionary]) { $counters[[string]$c['DeviceId']] = $c } }
      } else {
        $failed.Add('reliability')
      }
    } else {
      Add-ToolLog -Run $Run -Text 'Disk list not read: the disk counters were skipped'
      $failed.Add('reliability')
    }
    $events = Get-ToolDiskEventCount -Days $days
    if (-not $events.Ok) { $failed.Add('events') } elseif ($events.Count -gt 0) { $reasons.Add('events') }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($d in $disks) {
      $id = [string]$d['DeviceId']
      $c = $counters[$id]
      if ($c -isnot [System.Collections.IDictionary]) { $c = @{} }
      $health = [string]$d['HealthStatus']
      $wear = ConvertTo-ToolNumber -Value $c['Wear']
      $heat = ConvertTo-ToolNumber -Value $c['Temperature']
      $readErrors = ConvertTo-ToolNumber -Value $c['ReadErrorsUncorrected']
      $writeErrors = ConvertTo-ToolNumber -Value $c['WriteErrorsUncorrected']
      if ($health -ne '' -and $health -ne 'Healthy' -and -not $reasons.Contains('health')) { $reasons.Add('health') }
      if ((($null -ne $readErrors -and $readErrors -gt 0) -or ($null -ne $writeErrors -and $writeErrors -gt 0)) -and -not $reasons.Contains('errors')) { $reasons.Add('errors') }
      if ($null -ne $wear -and $wear -ge $wearLimit -and -not $reasons.Contains('wear')) { $reasons.Add('wear') }
      if ($null -ne $heat -and $heat -ge $heatLimit -and -not $reasons.Contains('temperature')) { $reasons.Add('temperature') }
      $rows.Add(@{
          DeviceId = (ConvertTo-ScreenText -Text $id); FriendlyName = (ConvertTo-ScreenText -Text $d['FriendlyName'])
          MediaType = (ConvertTo-ScreenText -Text $d['MediaType']); BusType = (ConvertTo-ScreenText -Text $d['BusType'])
          Health = (ConvertTo-ScreenText -Text $health); Wear = $wear; Temperature = $heat
          ReadErrorsUncorrected = $readErrors; WriteErrorsUncorrected = $writeErrors })
    }

    $level = 'ok'
    if ($reasons.Contains('health') -or $reasons.Contains('errors') -or $reasons.Contains('events')) {
      $level = 'crit'
    } elseif ($reasons.Contains('wear') -or $reasons.Contains('temperature')) {
      $level = 'warn'
    } elseif ($failed.Count -gt 0) {
      $level = 'unknown'
    }
    return (New-ToolChip -Level $level -Detail @{
        Reasons = $reasons.ToArray(); Failed = $failed.ToArray(); Events = $events.Count; EventIds = $events.Ids; Disks = $rows.ToArray() })
  } catch {
    return (New-ToolUnknownChip -Name 'Disk' -Reason $_.Exception.Message)
  }
}

function Get-ToolDiskCheckState {
  <#
  .SYNOPSIS
    The disk check state of -Drive (the system drive): @{ Dirty = <bool|$null>; Excluded = <bool> }. Never throws.
  .DESCRIPTION
    Dirty: Win32_Volume.DirtyBitSet (CIM, -OperationTimeoutSec 15); $null when it cannot be read. Excluded: the
    Session Manager's BootExecute holds /k:<letter> (someone excluded the drive from the start-up check on this PC:
    autochk skips it at every start). Read only: the toolbox never sets or clears an exclusion (ruling RD-R1).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([string]$Drive = $env:SystemDrive)

  $dirty = $null
  try {
    $volume = @(Get-CimInstance -ClassName 'Win32_Volume' -Filter ("DriveLetter='{0}'" -f $Drive) -OperationTimeoutSec 15 -ErrorAction Stop) | Select-Object -First 1
    if ($null -ne $volume -and $volume.DirtyBitSet -is [bool]) { $dirty = [bool]$volume.DirtyBitSet }
  } catch {
    Write-SetupLog -Level WARN -Message 'The dirty bit could not be read' -Data @{ drive = $Drive; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  $excluded = $false
  try {
    $letter = $Drive.TrimEnd(':')
    if ($letter -match '^[A-Za-z]\z') {
      foreach ($line in @(Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'BootExecute')) {
        if ([string]$line -match ('(?i)/k:[A-Z]*' + $letter)) { $excluded = $true }
      }
    }
  } catch {
    Write-SetupLog -Level WARN -Message 'BootExecute could not be read' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  return @{ Dirty = $dirty; Excluded = $excluded }
}

# --- The safety action's steps ------------------------------------------------------------------------------------

function Set-ToolChip {
  # Private. Stores -Chip as chip -Name in $Run.Data.Chips and $Run.Partial.Chips, logs its level and writes the
  # progress at once (the window shows each chip as soon as it is known). 'warn' for an unknown chip, else 'done'.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$Name,
    [AllowNull()]$Chip
  )

  if ($Chip -isnot [System.Collections.IDictionary] -or [string]$Chip['Level'] -cnotin 'ok', 'warn', 'crit', 'unknown') {
    $Chip = New-ToolUnknownChip -Name $Name -Reason 'the chip reader gave no chip'
  }
  foreach ($bag in $Run.Data, $Run.Partial) {
    if ($bag['Chips'] -isnot [System.Collections.IDictionary]) { $bag['Chips'] = @{} }
    $bag['Chips'][$Name] = $Chip
  }
  Add-ToolLog -Run $Run -Text ('{0}: {1}' -f $Name, $Chip['Level'])
  Write-ToolProgress -Run $Run
  if ($Chip['Level'] -ceq 'unknown') { return 'warn' }
  return 'done'
}

function Invoke-ToolStepSafetyRestart {
  # Step safetyRestart: the Restart chip (Get-ToolRestartChip).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try { $chip = Get-ToolRestartChip } catch { $chip = New-ToolUnknownChip -Name 'Restart' -Reason $_.Exception.Message }
  return (Set-ToolChip -Run $Run -Name 'Restart' -Chip $chip)
}

function Invoke-ToolStepSafetyFree {
  # Step safetyFree: the Free chip of the system drive (Get-ToolFreeSpaceChip).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try { $chip = Get-ToolFreeSpaceChip -Config $Run.Config } catch { $chip = New-ToolUnknownChip -Name 'Free' -Reason $_.Exception.Message -Arguments @($env:SystemDrive) }
  return (Set-ToolChip -Run $Run -Name 'Free' -Chip $chip)
}

function Invoke-ToolStepSafetyBitLocker {
  # Step safetyBitLocker: the BitLocker chip (Get-ToolBitLockerChip).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try { $chip = Get-ToolBitLockerChip } catch { $chip = New-ToolUnknownChip -Name 'BitLocker' -Reason $_.Exception.Message }
  return (Set-ToolChip -Run $Run -Name 'BitLocker' -Chip $chip)
}

function Invoke-ToolStepSafetyInternet {
  # Step safetyInternet: the Internet chip (Test-ToolInternet with the default seams).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try {
    $check = Test-ToolInternet -Config $Run.Config
    $chip = $check['Chip']
  } catch {
    $chip = New-ToolUnknownChip -Name 'Internet' -Reason $_.Exception.Message
  }
  return (Set-ToolChip -Run $Run -Name 'Internet' -Chip $chip)
}

function Invoke-ToolStepSafetyDisk {
  # Step safetyDisk: the Disk chip (Get-ToolDiskChip, its grandchildren bounded by the action's time).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try { $chip = Get-ToolDiskChip -Run $Run } catch { $chip = New-ToolUnknownChip -Name 'Disk' -Reason $_.Exception.Message }
  return (Set-ToolChip -Run $Run -Name 'Disk' -Chip $chip)
}

function Invoke-ToolStepSafetyDiskCheck {
  # Step safetyDiskCheck: the disk check state (Get-ToolDiskCheckState) in $Run.Data.DiskCheck and
  # $Run.Partial.DiskCheck; @{ Dirty = $null; Excluded = $false } when it cannot be read.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $state = $null
  try {
    $state = Get-ToolDiskCheckState
  } catch {
    Write-SetupLog -Level WARN -Message 'The disk check state could not be read' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  if ($state -isnot [System.Collections.IDictionary]) { $state = @{ Dirty = $null; Excluded = $false } }
  $Run.Data['DiskCheck'] = $state
  $Run.Partial['DiskCheck'] = $state
  Add-ToolLog -Run $Run -Text ('Disk check: dirty {0}, excluded {1}' -f $(if ($null -eq $state['Dirty']) { 'unknown' } else { $state['Dirty'] }), $state['Excluded'])
  Write-ToolProgress -Run $Run
  return 'done'
}
