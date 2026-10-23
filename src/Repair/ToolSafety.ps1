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
#   BitLocker : CIM Win32_EncryptableVolume: protection status, conversion status and protector TYPES only (never a
#               key or a password).
#   Internet  : ruling RD-R11: TCP 443 to repair.internet.host (www.microsoft.com), an HTTPS HEAD of repair.internet.url
#               (https://www.microsoft.com/; its Date header gives the clock offset), then Windows' own captive-portal
#               probe over plain HTTP (repair.internet.probeUrl, expecting repair.internet.probeContent). 5 s each.
#   Disk      : ruling RD-R10: only the physical disk(s) holding the system volume. Get-PhysicalDisk and
#               Get-StorageReliabilityCounter in grandchildren, the System log's disk 7, 51 and 153 events of that
#               disk (\Device\Harddisk<N>\) and NTFS 55 of the system volume, in the last diskEventDays. Other disks
#               (the BenTech stick among them) are only recorded in Detail, for the report.
# Plus the disk check state: the system volume's dirty bit, and whether BootExecute excludes the drive (/k:).
# Plus (repair Task 7) the saved network backup: this PC's newest valid one on the stick (Find-ToolNetBackup,
# ToolAdvanced.ps1), for the Restore network settings button; and (Task 9) whether the stick holds an earlier report of
# this PC (Find-ToolEarlierReport, ToolCompare.ps1), for the Compare with last visit tile.
#
# Every threshold comes from config.json's repair section; a missing key falls back to the values the spec pins
# (repair is not a required config key). Needs ToolEngine (Invoke-ToolJsonChild, Add-ToolLog, Write-ToolProgress),
# ToolChecks (Get-ToolSystemLetter), Reboot (Get-ServicingRebootSignals, Test-ServicingRebootPending,
# Get-RebootRegistryValue), Logging and StartScreen (ConvertTo-ScreenText). The bundle holds every file.

# Get-PhysicalDisk: one row per disk, plus the disk number(s) of the system volume's partition(s) (<L> is its
# letter), which a physical disk's DeviceId names. HealthStatus and MediaType are enum names (Healthy, Warning,
# Unhealthy, Unknown; SSD, HDD), never localized.
$script:ToolDisksCommand = @'
@{ SystemDisks = @(Get-Partition -DriveLetter '<L>' | ForEach-Object { [int]$_.DiskNumber } | Sort-Object -Unique)
   Items = @(Get-PhysicalDisk | ForEach-Object {
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

# Win32_EncryptableVolume.GetKeyProtectorType -> the BitLocker module's type names. Only the TYPES are read; the one
# constant below that names the numerical password protector is the only place its name may appear in src\Repair
# (tests\RepairStatic.Tests.ps1).
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
    The BitLocker chip of -Drive (the system drive): 'warn' when the volume is protected or encrypted (the reminder:
    have the recovery key before BIOS or board work), 'ok' when protection is off and the volume is fully decrypted,
    'unknown' when it cannot be read in 15 s. Never throws.
  .DESCRIPTION
    CIM Win32_EncryptableVolume (root\cimv2\Security\MicrosoftVolumeEncryption) with -OperationTimeoutSec 15:
      - ProtectionStatus: 0 off, 1 on, anything else unknown;
      - ConversionStatus (review M6): anything but 0 (fully decrypted) means the volume is encrypted, or partly so.
        Protection suspended (after a vendor BIOS update) and Device Encryption waiting for activation report
        protection off on an encrypted volume, and protection comes back on later, so they warn too;
      - GetKeyProtectors, and GetKeyProtectorType for each id.
    Detail = @{ ProtectionStatus; ConversionStatus (<int|$null>); Protectors = the type names (Tpm, ExternalKey, ...) }.
    No method that returns a key or a password is ever called.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([string]$Drive = $env:SystemDrive)

  try {
    $volume = @(Get-CimInstance -Namespace $script:ToolBitLockerNamespace -ClassName 'Win32_EncryptableVolume' -Filter ("DriveLetter='{0}'" -f $Drive) -OperationTimeoutSec 15 -ErrorAction Stop) |
      Select-Object -First 1
    if ($null -eq $volume) { return (New-ToolUnknownChip -Name 'BitLocker' -Reason ('no encryptable volume {0}' -f $Drive)) }
    $status = [int]$volume.ProtectionStatus
    $conversion = $null
    if ($null -ne $volume.ConversionStatus) { $conversion = [int]$volume.ConversionStatus }
    $answer = Invoke-CimMethod -InputObject $volume -MethodName 'GetKeyProtectors' -Arguments @{ KeyProtectorType = [uint32]0 } -OperationTimeoutSec 15 -ErrorAction Stop
    if ($null -ne $answer.ReturnValue -and [long]$answer.ReturnValue -ne 0) { throw ('GetKeyProtectors returned {0}' -f [long]$answer.ReturnValue) }
    $types = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($answer.VolumeKeyProtectorID)) {
      if ([string]::IsNullOrEmpty([string]$id)) { continue }
      $type = Invoke-CimMethod -InputObject $volume -MethodName 'GetKeyProtectorType' -Arguments @{ VolumeKeyProtectorID = [string]$id } -OperationTimeoutSec 15 -ErrorAction Stop
      $number = [int]$type.KeyProtectorType
      if ($script:ToolKeyProtectorTypes.ContainsKey($number)) { $types.Add($script:ToolKeyProtectorTypes[$number]) } else { $types.Add('Unknown') }
    }
    $encrypted = ($null -ne $conversion -and $conversion -ne 0)
    $level = 'unknown'
    if ($status -eq 1 -or $encrypted) { $level = 'warn' } elseif ($status -eq 0) { $level = 'ok' }
    return (New-ToolChip -Level $level -Detail @{ ProtectionStatus = $status; ConversionStatus = $conversion; Protectors = $types.ToArray() })
  } catch {
    return (New-ToolUnknownChip -Name 'BitLocker' -Reason $_.Exception.Message)
  }
}

# --- Internet (ruling RD-R11) -------------------------------------------------------------------------------------

function ConvertFrom-ToolHttpDate {
  # Private, pure. An HTTP Date header (RFC 1123, 'r': "Thu, 22 Oct 2026 11:42:50 GMT") as a UTC [datetime], or
  # $null. Invariant culture, so a Hebrew calendar on the thread changes nothing.
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  $parsed = [datetime]::MinValue
  if (-not [string]::IsNullOrWhiteSpace($Text) -and [datetime]::TryParseExact($Text.Trim(), 'r', [Globalization.CultureInfo]::InvariantCulture,
      ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function Test-ToolTcpPort {
  # Private: Test-ToolInternet's default -Connect. $true when a TCP connection to -HostName port 443 opens within
  # -Milliseconds (DNS included: ConnectAsync resolves the name inside the bound). Never throws.
  [CmdletBinding()]
  [OutputType([bool])]
  param([string]$HostName, [int]$Milliseconds)

  $client = New-Object Net.Sockets.TcpClient
  try {
    return [bool]$client.ConnectAsync($HostName, 443).Wait($Milliseconds)
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Invoke-ToolHttpsHead {
  <#
  .SYNOPSIS
    Private: Test-ToolInternet's default -Fetch. An HTTPS HEAD of -Url with TLS 1.2, Timeout and ReadWriteTimeout
    -Milliseconds, no redirect followed: @{ Ok; Date (UTC or $null) }. Never throws.
  .DESCRIPTION
    Ok means an HTTP answer came back over a TLS session whose certificate was validated: any status counts (a 403 or
    a 302 from the server still proves the connection works; review C1), read from the WebException's Response when
    the status is not a success. A certificate, name, DNS, timeout or connection failure has no Response: Ok = $false.
    The Date header of that answer gives the clock offset. Plan call: HttpWebRequest because WebClient has no
    timeout; never Invoke-WebRequest.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([string]$Url, [int]$Milliseconds)

  $response = $null
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
    $request.Method = 'HEAD'
    $request.Timeout = $Milliseconds
    $request.ReadWriteTimeout = $Milliseconds
    $request.AllowAutoRedirect = $false
    try {
      $response = $request.GetResponse()
    } catch [Net.WebException] {
      $response = $_.Exception.Response
    }
    if ($null -eq $response) { return @{ Ok = $false; Date = $null } }
    return @{ Ok = $true; Date = (ConvertFrom-ToolHttpDate -Text ([string]$response.Headers['Date'])) }
  } catch {
    return @{ Ok = $false; Date = $null }
  } finally {
    if ($null -ne $response) { $response.Close() }
  }
}

function Invoke-ToolHttpProbe {
  <#
  .SYNOPSIS
    Private: Test-ToolInternet's default -Probe. A plain HTTP GET of -Url (Windows' captive-portal test page) with
    Timeout and ReadWriteTimeout -Milliseconds, no redirect followed: @{ Answered; Content = the first 4 KB as ASCII;
    Date = the Date header (UTC) or $null }. Never throws.
  .DESCRIPTION
    Any HTTP answer counts as answered (a portal's redirect too; its body is then compared and differs). The body is
    a fixed English page from Microsoft, compared whole; at most 4 KB of it is read.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([string]$Url, [int]$Milliseconds)

  $response = $null
  try {
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.Timeout = $Milliseconds
    $request.ReadWriteTimeout = $Milliseconds
    $request.AllowAutoRedirect = $false
    try {
      $response = $request.GetResponse()
    } catch [Net.WebException] {
      $response = $_.Exception.Response
    }
    if ($null -eq $response) { return @{ Answered = $false; Content = ''; Date = $null } }
    $date = ConvertFrom-ToolHttpDate -Text ([string]$response.Headers['Date'])
    $stream = $response.GetResponseStream()
    $buffer = New-Object byte[] 4096
    $total = 0
    while ($total -lt $buffer.Length) {
      $count = $stream.Read($buffer, $total, $buffer.Length - $total)
      if ($count -le 0) { break }
      $total += $count
    }
    return @{ Answered = $true; Content = [Text.Encoding]::ASCII.GetString($buffer, 0, $total); Date = $date }
  } catch {
    return @{ Answered = $false; Content = ''; Date = $null }
  } finally {
    if ($null -ne $response) { $response.Close() }
  }
}

function Test-ToolInternet {
  <#
  .SYNOPSIS
    The internet check (spec 5, ruling RD-R11): @{ Tcp; Https; Probe = 'ok'|'different'|'failed'|'skipped';
    ClockOffsetSeconds; Clock; Chip }. Never throws.
  .DESCRIPTION
    1. TCP 443 to repair.internet.host (www.microsoft.com). When it fails, nothing more is tried.
    2. An HTTPS HEAD of repair.internet.url (https://www.microsoft.com/, a valid certificate): any answer over a
       validated TLS session proves HTTPS works; its Date header gives ClockOffsetSeconds = this PC's UTC time minus
       the server's (positive: the PC is ahead), $null without it.
    3. Windows' own captive-portal probe over plain HTTP: repair.internet.probeUrl
       (http://www.msftconnecttest.com/connecttest.txt) must answer exactly repair.internet.probeContent
       (Microsoft Connect Test). Probe is 'ok', 'different' (another page: a captive portal or a proxy), or 'failed'
       (no answer). It runs after TCP even when HTTPS failed, so the detail can tell a portal from no internet.
    Each is bounded by repair.internet.seconds (5).
    The clock (review M3, ruling RD-R20): when HTTPS gave no Date (it failed, or its answer had none) and the probe
    answered Microsoft's own page ('ok'), the probe's Date header gives ClockOffsetSeconds instead (plain HTTP has no
    certificate). A clock days off (a dead BIOS battery) makes every certificate look not yet valid or expired, so HTTPS
    fails while plain HTTP works: when HTTPS failed and that offset is above repair.thresholds.clockWrongMinutes (60;
    final wave item 14: not the 2-minute clockOffsetMinutes, since a clock minutes off breaks no certificate, so a
    TLS-breaking proxy on a slightly-off clock stays "No internet"), Clock is $true and the chip is 'warn' with
    Detail.Clock (the window says "Clock wrong", never "No internet"; the time sync runs first in Standard repair and is
    never blocked by this chip).
    The chip: 'crit' when TCP failed, or HTTPS failed without the clock reason; 'warn' for the clock, or when the probe
    was not 'ok' ("captive portal or proxy", the captivePortal finding's text); else 'ok'. Detail = @{ Tcp; Https;
    Probe; ClockOffsetSeconds; Clock }.
    The three seams (tests pass their own; the defaults are Test-ToolTcpPort, Invoke-ToolHttpsHead and
    Invoke-ToolHttpProbe):
      -Connect { param($HostName, $Milliseconds) } -> bool
      -Fetch   { param($Url, $Milliseconds) } -> @{ Ok; Date (UTC [datetime] or $null) }
      -Probe   { param($Url, $Milliseconds) } -> @{ Answered; Content; Date (UTC [datetime] or $null; optional) }
    A seam that throws or answers anything else counts as failed.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][AllowNull()]$Config,
    [scriptblock]$Connect = { param($HostName, $Milliseconds) Test-ToolTcpPort -HostName $HostName -Milliseconds $Milliseconds },
    [scriptblock]$Fetch = { param($Url, $Milliseconds) Invoke-ToolHttpsHead -Url $Url -Milliseconds $Milliseconds },
    [scriptblock]$Probe = { param($Url, $Milliseconds) Invoke-ToolHttpProbe -Url $Url -Milliseconds $Milliseconds }
  )

  $hostName = [string](Get-ToolRepairSetting -Config $Config -Path 'internet', 'host' -Default 'www.microsoft.com')
  $url = [string](Get-ToolRepairSetting -Config $Config -Path 'internet', 'url' -Default 'https://www.microsoft.com/')
  $probeUrl = [string](Get-ToolRepairSetting -Config $Config -Path 'internet', 'probeUrl' -Default 'http://www.msftconnecttest.com/connecttest.txt')
  $probeContent = [string](Get-ToolRepairSetting -Config $Config -Path 'internet', 'probeContent' -Default 'Microsoft Connect Test')
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
  $probeResult = 'skipped'
  $probeDate = $null
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
    $probeResult = 'failed'
    try {
      $answer = @(& $Probe $probeUrl $milliseconds)
      if ($answer.Count -eq 1 -and $answer[0] -is [System.Collections.IDictionary] -and $answer[0]['Answered'] -eq $true) {
        $probeResult = 'different'
        if (([string]$answer[0]['Content']).Trim() -ceq $probeContent) { $probeResult = 'ok' }
        if ($answer[0]['Date'] -is [datetime]) { $probeDate = $answer[0]['Date'] }
      }
    } catch {
      $probeResult = 'failed'
    }
  }
  # The clock from Microsoft's own HTTP page when HTTPS gave none (review M3).
  if ($null -eq $offset -and $probeResult -ceq 'ok' -and $null -ne $probeDate) {
    if ($probeDate.Kind -eq [DateTimeKind]::Local) { $probeDate = $probeDate.ToUniversalTime() }
    $offset = [math]::Round(([datetime]::UtcNow - [datetime]::SpecifyKind($probeDate, [DateTimeKind]::Utc)).TotalSeconds, 1)
  }
  $clockLimit = Get-ToolRepairNumber -Config $Config -Path 'thresholds', 'clockWrongMinutes' -Default 60
  $clock = $tcp -and -not $https -and $null -ne $offset -and ([math]::Abs([double]$offset) / 60) -gt $clockLimit
  $level = 'ok'
  if (-not $tcp -or (-not $https -and -not $clock)) { $level = 'crit' } elseif ($clock -or $probeResult -ne 'ok') { $level = 'warn' }
  Write-SetupLog -Message 'Internet check' -Data @{ tcp = $tcp; https = $https; probe = $probeResult; clockOffsetSeconds = $offset; clock = $clock }
  return @{
    Tcp                = $tcp
    Https              = $https
    Probe              = $probeResult
    ClockOffsetSeconds = $offset
    Clock              = $clock
    Chip               = (New-ToolChip -Level $level -Detail @{ Tcp = $tcp; Https = $https; Probe = $probeResult; ClockOffsetSeconds = $offset; Clock = $clock })
  }
}

# --- Disk (ruling RD-R10) -----------------------------------------------------------------------------------------

function Get-ToolDiskEventCount {
  <#
  .SYNOPSIS
    The listed disk events of the last -Days days, split by where they happened: @{ Ok; Count (on the system disk or
    volume); Other (elsewhere: the stick, another disk or volume); Ids = [string[]] ('<provider>/<id>' of the counted
    ones) }. Never throws.
  .DESCRIPTION
    Get-WinEvent -FilterHashtable on the System log by ID (7, 51, 153, 55) and start time, then by provider: 'disk'
    with 7, 51 or 153, and 'Ntfs' or 'Microsoft-Windows-Ntfs' with 55 (an event's provider name is never localized).
    The providers are checked after the query because a ProviderName that is not registered on a PC fails the whole
    query (NoMatchingProvidersFound).
    Ruling RD-R10, where the event happened, from its first property (a device path or a drive name, never
    localized):
      - a disk event counts when it is \Device\Harddisk<N>\... with N one of -SystemDisks;
      - NTFS 55 counts when its DriveName is -SystemDrive ('C:').
    NoMatchingEventsFound is 0 events; any other error is Ok = $false.
    -ClockOffsetSeconds (final review Minor 5): this PC's clock minus Microsoft's (the Internet step's measure; $null when
    none). A clock ahead would start the window after the real last -Days days (a clock years ahead counts nothing: "Disk
    OK" on a failing disk), so the window starts that much earlier. A clock behind keeps the wall clock's start, which
    already reaches further back (it can only count more: red, never a missed failure).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][int]$Days,
    [AllowNull()][int[]]$SystemDisks,
    [AllowNull()][AllowEmptyString()][string]$SystemDrive,
    [AllowNull()]$ClockOffsetSeconds
  )

  if ($null -eq $SystemDisks) { $SystemDisks = [int[]]@() }
  $drive = ([string]$SystemDrive).Trim().TrimEnd('\')
  $ahead = 0.0
  if ($null -ne $ClockOffsetSeconds) {
    $number = 0.0
    if ([double]::TryParse([string]$ClockOffsetSeconds, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
        -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -gt 0) { $ahead = [math]::Min($number, 3650 * 86400.0) }
  }
  $events = @()
  try {
    $filter = @{ LogName = 'System'; Id = @(7, 51, 153, 55); StartTime = (Get-Date).AddSeconds(-$ahead).AddDays(-$Days) }
    $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 5000 -ErrorAction Stop)
  } catch {
    if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @{ Ok = $true; Count = 0; Other = 0; Ids = [string[]]@() } }
    $reason = ConvertTo-ScreenText -Text $_.Exception.Message
    Write-SetupLog -Level WARN -Message 'The disk events could not be read' -Data @{ error = $reason }
    return @{ Ok = $false; Count = $null; Other = $null; Ids = [string[]]@(); Error = $reason }
  }
  $rows = @(foreach ($e in $events) {
      $first = ''
      $properties = $e.Properties
      if ($null -ne $properties -and $properties.Count -gt 0 -and $null -ne $properties[0]) { $first = [string]$properties[0].Value }
      @{ Provider = [string]$e.ProviderName; Id = [int]$e.Id; First = $first } })
  $split = Get-ToolDiskEventSplit -Events $rows -SystemDisks $SystemDisks -SystemDrive $drive
  return @{ Ok = $true; Count = $split['Count']; Other = $split['Other']; Ids = $split['Ids'] }
}

function Get-ToolDiskEventSplit {
  <#
  .SYNOPSIS
    Ruling RD-R10's split of disk events, pure (Get-ToolDiskEventCount here; the report reads the same events in a
    grandchild, review M4): -Events are rows @{ Provider; Id; First (the event's first property: a device path or a
    drive name, never localized) }. A disk 7, 51 or 153 counts when First is \Device\Harddisk<N>\... with N one of
    -SystemDisks; an NTFS 55 ('Ntfs' or 'Microsoft-Windows-Ntfs') when First is -SystemDrive ('C:'); any other row is
    ignored. @{ Count (on the system disk or volume); Other (elsewhere); Ids = [string[]] ('<provider>/<id>' of the
    counted ones, sorted, unique) }.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()][AllowEmptyCollection()][object[]]$Events,
    [AllowNull()][int[]]$SystemDisks,
    [AllowNull()][AllowEmptyString()][string]$SystemDrive
  )

  if ($null -eq $SystemDisks) { $SystemDisks = [int[]]@() }
  $drive = ([string]$SystemDrive).Trim().TrimEnd('\')
  $counted = New-Object System.Collections.Generic.List[string]
  $other = 0
  foreach ($e in @($Events)) {
    if ($e -isnot [System.Collections.IDictionary]) { continue }
    $provider = [string]$e['Provider']
    $id = 0
    if (-not [int]::TryParse([string]$e['Id'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$id)) { continue }
    $first = ([string]$e['First']).Trim()
    $onSystem = $false
    if ($provider -eq 'disk' -and $id -in 7, 51, 153) {
      $device = [regex]::Match($first, '^\\Device\\Harddisk([0-9]{1,4})\\', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
      $onSystem = $device.Success -and ($SystemDisks -contains [int]$device.Groups[1].Value)
    } elseif ($provider -in 'Ntfs', 'Microsoft-Windows-Ntfs' -and $id -eq 55) {
      $onSystem = ($drive -ne '' -and $first.TrimEnd('\') -eq $drive)
    } else {
      continue
    }
    if ($onSystem) { $counted.Add(('{0}/{1}' -f $provider, $id)) } else { $other++ }
  }
  return @{ Count = $counted.Count; Other = $other; Ids = [string[]]@($counted.ToArray() | Sort-Object -Unique) }
}

function Get-ToolDiskChip {
  <#
  .SYNOPSIS
    The Disk chip (spec 5, ruling RD-R10): the physical disk(s) holding the system volume. Never throws.
  .DESCRIPTION
    Sources: the grandchild 'disks' (Get-PhysicalDisk, and the system volume's disk numbers from Get-Partition), the
    grandchild 'reliability' (Get-StorageReliabilityCounter; run only when the disk list came back with disks, as it
    would hang or fail the same way), both bounded by toolStep.disks (review M7: a hung disk must not keep the strip
    loading for minutes), and Get-ToolDiskEventCount for repair.thresholds.diskEventDays (30; the window moved back by
    a clock ahead, $Run.Data.ClockOffsetSeconds from the Internet step: final review Minor 5).
    Only the system disk(s) are judged:
      crit    : HealthStatus Warning or Unhealthy, uncorrected read or write errors above 0, or a listed event on the
                system disk or volume (the reason 'health', 'errors' or 'events');
      warn    : wear at or above thresholds.diskWearPercent (80) or a temperature at or above
                thresholds.diskTemperatureC (60) ('wear', 'temperature');
      unknown : a HealthStatus that is empty, Unknown or anything else ('health' in Detail.Failed), a source that
                failed or timed out ('disks', 'reliability', 'events'), or no system disk found ('systemDisk'), and
                nothing above;
      ok      : else.
    A known problem wins over a source that failed. Other disks (the stick) and their events are only recorded:
    Detail = @{ Reasons; Failed; Events (system); OtherEvents; EventIds; SystemDisks; Disks = @( @{ DeviceId; System;
    FriendlyName; MediaType; BusType; Health; Wear; Temperature; ReadErrorsUncorrected; WriteErrorsUncorrected } ) }
    (ASCII).
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
    $letter = Get-ToolSystemLetter

    $disks = @()
    $systemDisks = [int[]]@()
    $list = @{ Ok = $false; TimedOut = $false; Data = $null; Error = 'no system drive letter' }
    if ($letter -ne '') {
      $list = Invoke-ToolJsonChild -Run $Run -Name 'disks' -Command ($script:ToolDisksCommand.Replace('<L>', $letter)) -StepTimeout 'disks'
    }
    if ($list.Ok -and $list.Data.ContainsKey('Items')) {
      $disks = @(foreach ($d in @($list.Data['Items'])) { if ($d -is [System.Collections.IDictionary]) { $d } })
      $systemDisks = [int[]]@(foreach ($n in @($list.Data['SystemDisks'])) {
          $number = 0
          if ($null -ne $n -and [int]::TryParse([string]$n, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { $number }
        })
    } else {
      $failed.Add('disks')
    }
    $counters = @{}
    if ($disks.Count -gt 0) {
      $reliability = Invoke-ToolJsonChild -Run $Run -Name 'reliability' -Command $script:ToolReliabilityCommand -StepTimeout 'disks'
      if ($reliability.Ok -and $reliability.Data.ContainsKey('Items')) {
        foreach ($c in @($reliability.Data['Items'])) { if ($c -is [System.Collections.IDictionary]) { $counters[[string]$c['DeviceId']] = $c } }
      } else {
        $failed.Add('reliability')
      }
    } else {
      Add-ToolLog -Run $Run -Text 'No disk list: the disk counters were skipped'
      $failed.Add('reliability')
    }
    $systemDrive = ''
    if ($letter -ne '') { $systemDrive = $letter + ':' }
    # The Internet step ran first and kept its clock offset: a clock ahead moves the event window back (final review
    # Minor 5); without internet the wall clock decides (docs\testing.md 1.21).
    $offset = $Run.Data['ClockOffsetSeconds']
    if ($null -ne $offset -and [double]$offset -gt 0) {
      Add-ToolLog -Run $Run -Text ('The clock is {0} min ahead: the disk events are counted from Microsoft''s time' -f ([math]::Round([double]$offset / 60, 1)).ToString([Globalization.CultureInfo]::InvariantCulture))
    }
    $events = Get-ToolDiskEventCount -Days $days -SystemDisks $systemDisks -SystemDrive $systemDrive -ClockOffsetSeconds $offset
    if (-not $events.Ok) { $failed.Add('events') } elseif ($events.Count -gt 0) { $reasons.Add('events') }

    $rows = New-Object System.Collections.Generic.List[object]
    $systemSeen = 0
    foreach ($d in $disks) {
      $id = [string]$d['DeviceId']
      $number = -1
      $isSystem = [int]::TryParse($id, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and ($systemDisks -contains $number)
      $c = $counters[$id]
      if ($c -isnot [System.Collections.IDictionary]) { $c = @{} }
      $health = [string]$d['HealthStatus']
      $wear = ConvertTo-ToolNumber -Value $c['Wear']
      $heat = ConvertTo-ToolNumber -Value $c['Temperature']
      $readErrors = ConvertTo-ToolNumber -Value $c['ReadErrorsUncorrected']
      $writeErrors = ConvertTo-ToolNumber -Value $c['WriteErrorsUncorrected']
      if ($isSystem) {
        $systemSeen++
        if ($health -cin 'Warning', 'Unhealthy') {
          if (-not $reasons.Contains('health')) { $reasons.Add('health') }
        } elseif ($health -cne 'Healthy' -and -not $failed.Contains('health')) {
          $failed.Add('health')
        }
        if ((($null -ne $readErrors -and $readErrors -gt 0) -or ($null -ne $writeErrors -and $writeErrors -gt 0)) -and -not $reasons.Contains('errors')) { $reasons.Add('errors') }
        if ($null -ne $wear -and $wear -ge $wearLimit -and -not $reasons.Contains('wear')) { $reasons.Add('wear') }
        if ($null -ne $heat -and $heat -ge $heatLimit -and -not $reasons.Contains('temperature')) { $reasons.Add('temperature') }
      }
      $rows.Add(@{
          DeviceId = (ConvertTo-ScreenText -Text $id); System = [bool]$isSystem; FriendlyName = (ConvertTo-ScreenText -Text $d['FriendlyName'])
          MediaType = (ConvertTo-ScreenText -Text $d['MediaType']); BusType = (ConvertTo-ScreenText -Text $d['BusType'])
          Health = (ConvertTo-ScreenText -Text $health); Wear = $wear; Temperature = $heat
          ReadErrorsUncorrected = $readErrors; WriteErrorsUncorrected = $writeErrors })
    }
    if ($list.Ok -and $systemSeen -eq 0) { $failed.Add('systemDisk') }

    $level = 'ok'
    if ($reasons.Contains('health') -or $reasons.Contains('errors') -or $reasons.Contains('events')) {
      $level = 'crit'
    } elseif ($reasons.Contains('wear') -or $reasons.Contains('temperature')) {
      $level = 'warn'
    } elseif ($failed.Count -gt 0) {
      $level = 'unknown'
    }
    return (New-ToolChip -Level $level -Detail @{
        Reasons = $reasons.ToArray(); Failed = $failed.ToArray(); Events = $events.Count; OtherEvents = $events.Other
        EventIds = $events.Ids; SystemDisks = $systemDisks; Disks = $rows.ToArray() })
  } catch {
    return (New-ToolUnknownChip -Name 'Disk' -Reason $_.Exception.Message)
  }
}

function Get-ToolDiskCheckState {
  <#
  .SYNOPSIS
    The disk check state of -Drive (the system drive): @{ Dirty = <bool|$null>; Excluded = <bool>;
    ExcludedUnknown = <bool> }. Never throws.
  .DESCRIPTION
    Dirty: Win32_Volume.DirtyBitSet (CIM, -OperationTimeoutSec 15); $null when it cannot be read. Excluded: the
    Session Manager's BootExecute holds /k:<letter> (someone excluded the drive from the start-up check on this PC:
    autochk skips it at every start). ExcludedUnknown: BootExecute could not be read (Windows always has one, so a
    missing value is a read that failed; repair Task 7 review M5): Excluded is then $false but unconfirmed. Read
    only: the toolbox never sets or clears an exclusion (ruling RD-R1).
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
  $unknown = $false
  try {
    $letter = $Drive.TrimEnd(':')
    if ($letter -match '^[A-Za-z]\z') {
      $value = Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'BootExecute'
      if ($null -eq $value) {
        $unknown = $true
        Write-SetupLog -Level WARN -Message 'BootExecute could not be read: whether the drive is excluded from the start-up check is unknown'
      }
      foreach ($line in @($value)) {
        if ([string]$line -match ('(?i)/k:[A-Z]*' + $letter)) { $excluded = $true }
      }
    }
  } catch {
    $unknown = $true
    Write-SetupLog -Level WARN -Message 'BootExecute could not be read' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  return @{ Dirty = $dirty; Excluded = $excluded; ExcludedUnknown = $unknown }
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
  # Step safetyInternet: the Internet chip (Test-ToolInternet with the default seams). The clock offset it measured
  # goes to $Run.Data.ClockOffsetSeconds for the Disk step's event window (final review Minor 5); none, none kept.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try {
    $check = Test-ToolInternet -Config $Run.Config
    $chip = $check['Chip']
    if ($null -ne $check['ClockOffsetSeconds']) { $Run.Data['ClockOffsetSeconds'] = [double]$check['ClockOffsetSeconds'] }
  } catch {
    $chip = New-ToolUnknownChip -Name 'Internet' -Reason $_.Exception.Message
  }
  return (Set-ToolChip -Run $Run -Name 'Internet' -Chip $chip)
}

function Invoke-ToolStepSafetyDisk {
  # Step safetyDisk: the Disk chip (Get-ToolDiskChip, its grandchildren bounded by toolStep.disks).
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

function Invoke-ToolStepSafetyNetBackup {
  <#
  .SYNOPSIS
    Step safetyNetBackup (repair Task 7, spec 6.6): this PC's newest valid network backup on the stick
    (Find-ToolNetBackup, ToolAdvanced.ps1, under Args.StickRoot for Args.Identity.Key) in $Run.Data.NetBackup =
    @{ Path; Sha256; CreatedAt; Adapters }, or $null (no stick, no identity key, no backup, or a read that failed: a
    WARN in the log). The window shows Restore network settings only with one. Always 'done': the safety action never
    ends red because of it.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $backup = $null
  $stickRoot = [string]$Run.Args['StickRoot']
  $identity = $Run.Args['Identity']
  $key = ''
  if ($identity -is [System.Collections.IDictionary]) { $key = [string]$identity['Key'] }
  if ($stickRoot -ne '' -and $key -ne '') {
    try {
      $backup = Find-ToolNetBackup -StickRoot $stickRoot -IdentityKey $key
    } catch {
      $backup = $null
      Write-SetupLog -Level WARN -Message 'The saved network settings could not be looked for' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
  }
  $Run.Data['NetBackup'] = $backup
  if ($null -eq $backup) {
    Add-ToolLog -Run $Run -Text 'Saved network settings: none'
  } else {
    Add-ToolLog -Run $Run -Text ('Saved network settings: {0}' -f $backup['Path'])
  }
  Write-ToolProgress -Run $Run
  return 'done'
}

function Invoke-ToolStepSafetyEarlier {
  <#
  .SYNOPSIS
    Step safetyEarlier (repair Task 9, spec 6.8): $Run.Data.HasEarlierReport = $true when the stick (Args.StickRoot) holds
    an earlier report of this PC (Args.Identity.Key) outside this visit's folder (Args.SessionDir): one Find-ToolEarlierReport
    (ToolCompare.ps1) can read, or one of this PC it cannot read (Compare then says why: never a silent "none", RD-R23).
    $false without a stick, without an identity key, or when the search fails (a WARN in the log). The window enables
    Compare with last visit only with it. Always 'done': the safety action never ends red because of it.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $has = $false
  $stickRoot = [string]$Run.Args['StickRoot']
  $identity = $Run.Args['Identity']
  $key = ''
  if ($identity -is [System.Collections.IDictionary]) { $key = [string]$identity['Key'] }
  if ($stickRoot -ne '' -and $key -ne '') {
    try {
      $skipped = New-Object System.Collections.Generic.List[string]
      $earlier = Find-ToolEarlierReport -StickRoot $stickRoot -IdentityKey $key -CurrentSessionDir ([string]$Run.Args['SessionDir']) -Skipped $skipped
      $has = ($null -ne $earlier) -or ($skipped.Count -gt 0)
    } catch {
      $has = $false
      Write-SetupLog -Level WARN -Message 'Earlier reports could not be looked for' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
  }
  $Run.Data['HasEarlierReport'] = $has
  Add-ToolLog -Run $Run -Text ('Earlier report of this PC: {0}' -f $(if ($has) { 'found' } else { 'none' }))
  Write-ToolProgress -Run $Run
  return 'done'
}
