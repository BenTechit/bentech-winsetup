# src/Repair/ToolAdvanced.ps1
# Repair & diagnostics, the ADVANCED row (repair spec 6.4 to 6.7; repair Task 7): Windows Update reset, Disk check at
# restart, Network reset with its backup and restore, and Ghost devices.
#
# Each of them changes the PC, so each fails safe:
#   - Windows Update reset (spec 6.4): the six update services are stopped (sc.exe; their state is recorded first),
#     the update folders SoftwareDistribution and catroot2 are RENAMED (nothing is deleted), only the BITS jobs whose
#     files lie under SoftwareDistribution are removed (the old kit removed every user's jobs), and the services that
#     ran before start again: wuServicesStart always runs, also after a Stop or the deadline (its catalog row has
#     AlwaysRun; review I-2: the kit could leave Windows Update stopped). A Disabled service is reported, never changed
#     (review I-13). Then Task 6's wuScan.
#   - Disk check at restart (spec 6.5, ruling RD-R1): fsutil marks the system volume dirty, and
#     Win32_Volume.DirtyBitSet must say so afterwards. There is no cancel: the toolbox never edits the start-up
#     check's exclusion list.
#   - Network reset (spec 6.6): every adapter's static IP, gateway and DNS settings go to the stick as JSON and are
#     read back first; no verified backup on the stick, no reset (netBackup ends the action through Data.Abort). Then
#     Winsock and TCP/IP (v4 and v6) are reset and the DNS cache cleared. No lease is given back or asked for: the
#     restart that follows does that. Restore network settings applies a saved file only when its SHA-256 is the one
#     the window showed, parses the very bytes it hashed, and puts back only the static values, per adapter, as
#     literals that Test-ToolNetBackup checked.
#   - Ghost devices (spec 6.7): the non-present devices, with Bluetooth (by enumerator, class, or a Bluetooth
#     ancestor), audio endpoints, printers and print queues, and WSD and IPP devices always left out; the list goes to
#     the stick as a UTF-8 CSV first (no saved list, nothing removed: ghostCsv ends the action), then pnputil removes
#     the ticked devices that are still non-present and not left out.
#
# The rules (repair plan, Global Constraints): no decision comes from a tool's text (exit codes; the names of
# ServiceControllerStatus and ServiceStartMode; the NetTCPIP enums Dhcp, PrefixOrigin and AddressFamily; PnP property
# keys; CIM). Every native tool runs through Invoke-ToolNative, every cmdlet that can hang (BITS, NetAdapter, NetTCPIP,
# DnsClient, PnpDevice) in a bounded grandchild (Invoke-ToolJsonChild) whose command returns one hashtable. Nothing
# waits without a deadline (counted Wait-SetupDelay slices). result.json stays ASCII bytes: the display-only names (a
# device's name and class, an adapter's alias) keep their real text (ConvertTo-ToolDisplayText) and are written as
# \uXXXX escapes (ConvertTo-ToolAsciiJson; ruling RD-R21), every other value and every log line is ASCII
# (ConvertTo-ScreenText). result.json stays under 1 MB (the ghost list has a count cap and a byte budget, and says
# so). Nothing on the stick is written or read through a link (Test-StickReparsePoint).
#
# Needs ToolEngine (Invoke-ToolNative, Invoke-ToolJsonChild, Add-ToolFinding, Add-ToolLog, Write-ToolJsonFile,
# Read-ToolJsonFile, Get-ToolStepTimeout, Get-ToolRemainingSeconds, Get-ToolStepName, Format-ToolExitCode,
# Test-ToolFindingCode), ToolChecks (Set-ToolCheckError, Get-ToolCheckError, Test-ToolCheckTimedOut,
# Get-ToolSystemLetter), ToolSafety (Get-ToolDiskCheckState), ToolRepairs (Get-ToolSystemTool, Get-ToolServiceState,
# Get-ToolArgsEntry), Cleanup (Test-StickReparsePoint), Winget (ConvertTo-PowerShellLiteral), State
# (ConvertTo-HashtableDeep), Activity (Wait-SetupDelay), Logging and StartScreen (ConvertTo-ScreenText). The bundle
# holds every file.

# The Windows Update services, in the order they are stopped (and started again in reverse). Only the first four are
# reported when Disabled: Delivery Optimization and Windows Installer are often Disabled on purpose, and Windows
# Update works without them running.
$script:WuResetServices = @('wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc', 'dosvc')
$script:WuDisabledReported = @('wuauserv', 'bits', 'cryptsvc', 'usosvc')
$script:WuRenameTries = 3
$script:WuRenamePauseSeconds = 3
# A rename is not tried again with this little of the action's time left: the retry stops the services again, and
# wuServicesStart (AlwaysRun) still needs its share before the window's kill (review M6).
$script:WuRenameReserveSeconds = 180
# Win32 errors (as HRESULTs) that mean the folder is in use: a sharing violation and a lock violation (review M8).
$script:WuRenameLockedCodes = @(0x80070020, 0x80070021)

# Ghost devices that are always left out (spec 6.7, builder check 8): Bluetooth by enumerator (a turned-off headset
# is not present, yet still paired), audio endpoints (per-device audio settings), print queues and WSD printers; and by
# class. Test-GhostExcluded also leaves out the children of any Bluetooth device, and every device whose first or
# second InstanceId segment names WSD or IPP.
$script:GhostExcludedPrefixes = @('BTHENUM\', 'BTHLE\', 'BTHLEDEVICE\', 'BTHHFENUM\', 'SWD\MMDEVAPI\', 'SWD\PRINTENUM\', 'WSDPRINT\')
$script:GhostExcludedClasses = @('Bluetooth', 'Printer', 'PrintQueue', 'AudioEndpoint')
$script:GhostBluetoothPrefixes = @('BTHENUM\', 'BTHLE\', 'BTHLEDEVICE\', 'BTHHFENUM\')
$script:GhostAncestorLevels = 10
# The grandchild answers at most GhostQueryMax ghosts (its answer stays under Invoke-ToolJsonChild's 1 MB), and the
# window gets at most GhostListMax of them, and only as many as fit GhostListBudgetBytes (review M4): each row is
# counted as GhostRowOverheadBytes (its keys and indentation in result.json; about 290 measured) plus its values as
# they are written (Measure-ToolJsonText: six bytes for each \u escape). So result.json stays under the 1 MB the
# window reads whatever the names, with room for the rest of it. A name is cut to GhostNameMax and a class to
# GhostClassMax UTF-16 code units before its escapes (RD-R21: they keep their real text).
$script:GhostQueryMax = 2000
$script:GhostListMax = 1000
$script:GhostListBudgetBytes = 800KB
$script:GhostRowOverheadBytes = 320
$script:GhostNameMax = 128
$script:GhostClassMax = 64
# An adapter's alias is cut to this many UTF-16 code units (it keeps its real text, RD-R21).
$script:NetAliasMax = 64

# A saved network backup holds at most this many adapters (Test-ToolNetBackup), each at most this many addresses,
# gateways and DNS servers.
$script:NetBackupMaxAdapters = 16
$script:NetBackupMaxAddresses = 32
$script:NetBackupMaxGateways = 8
$script:NetBackupMaxDns = 16

# The BITS jobs of Windows Update (<R> is the SoftwareDistribution folder with its final backslash, as a literal): a job
# goes only when one of its files lies under it. Matched by the files' paths, never by a job's (localized) name.
$script:ToolWuBitsCommand = @'
$root = <R>
$removed = 0
$failed = 0
$errors = New-Object System.Collections.Generic.List[string]
foreach ($job in @(Get-BitsTransfer -AllUsers)) {
  $ours = $false
  foreach ($file in @($job.FileList)) {
    $local = [string]$file.LocalName
    if ($local -ne '' -and $local.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $ours = $true }
  }
  if (-not $ours) { continue }
  try {
    Remove-BitsTransfer -BitsJob $job -ErrorAction Stop
    $removed++
  } catch {
    $failed++
    if ($errors.Count -lt 3) { $errors.Add([string]$_.Exception.Message) }
  }
}
@{ Removed = $removed; Failed = $failed; Errors = $errors.ToArray() }
'@

# Every adapter's settings (spec 6.6): the addresses and the default routes kept in the persistent store (the ones set
# by hand; review M1: the persistent store also holds them for an adapter whose cable is out, which has no active
# address), the DNS servers set by hand (the NameServer value of the adapter's Tcpip and Tcpip6 interface keys; DHCP's
# own servers are DhcpNameServer, never saved), and whether DHCP is on per address family. Enum names only. A failure
# other than "nothing found" fails the whole read: no verified backup, no reset.
$script:ToolNetSettingsCommand = @'
$dhcp = @{}
foreach ($i in @(Get-NetIPInterface)) { $dhcp[('{0}|{1}' -f [int]$i.ifIndex, [string]$i.AddressFamily)] = [string]$i.Dhcp }
$manual = @()
try {
  $manual = @(Get-NetIPAddress -PolicyStore PersistentStore -ErrorAction Stop)
} catch {
  if ([string]$_.CategoryInfo.Category -cne 'ObjectNotFound') { throw }
}
$routes = @()
try {
  $routes = @(Get-NetRoute -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { [string]$_.DestinationPrefix -in '0.0.0.0/0', '::/0' })
} catch {
  if ([string]$_.CategoryInfo.Category -cne 'ObjectNotFound') { throw }
}
@{ Items = @(foreach ($a in @(Get-NetAdapter)) {
  $index = [int]$a.ifIndex
  $guid = [string]$a.InterfaceGuid
  $dns = New-Object System.Collections.Generic.List[string]
  foreach ($stack in 'Tcpip', 'Tcpip6') {
    $value = [Microsoft.Win32.Registry]::GetValue(('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\{0}\Parameters\Interfaces\{1}' -f $stack, $guid), 'NameServer', $null)
    foreach ($server in ([string]$value -split '[ ,;]+')) { if ($server -ne '') { $dns.Add($server) } }
  }
  @{ Alias = [string]$a.Name; Guid = $guid; Mac = [string]$a.MacAddress; Index = $index
     Ipv4Dhcp = ($dhcp[('{0}|IPv4' -f $index)] -ceq 'Enabled'); Ipv6Dhcp = ($dhcp[('{0}|IPv6' -f $index)] -ceq 'Enabled')
     Addresses = @(foreach ($x in $manual) { if ([int]$x.InterfaceIndex -eq $index) { @{ Ip = [string]$x.IPAddress; Prefix = [int]$x.PrefixLength } } })
     Gateways = @(foreach ($r in $routes) { if ([int]$r.InterfaceIndex -eq $index) { [string]$r.NextHop } })
     Dns = $dns.ToArray() } }) }
'@

# The adapters as they are now, to match a saved one (by its GUID, else its MAC) to its interface index.
$script:ToolNetAdaptersCommand = @'
@{ Items = @(foreach ($a in @(Get-NetAdapter)) { @{ Alias = [string]$a.Name; Guid = [string]$a.InterfaceGuid; Mac = [string]$a.MacAddress; Index = [int]$a.ifIndex } }) }
'@

# The non-present devices (spec 6.7) with their parent chain, read through the full device list: each ghost's parent
# (DEVPKEY_Device_Parent, else DEVPKEY_Device_LastKnownParent, which Windows keeps for a device that is gone), then
# that parent's, up to <Levels> levels. Items are the ghosts (at most <Max>; Total counts them all), Nodes the
# ancestors that are not ghosts themselves. A property read that fails for another reason than a device gone
# meanwhile fails the whole list: an unread parent could hide a Bluetooth ancestor.
$script:ToolGhostCommand = @'
$all = @(Get-PnpDevice)
$class = @{}
foreach ($d in $all) { $class[[string]$d.InstanceId] = [string]$d.Class }
$ghosts = @($all | Where-Object { $_.Present -eq $false })
$total = $ghosts.Count
$ghosts = @($ghosts | Select-Object -First <Max>)
$parent = @{}
$todo = @(foreach ($g in $ghosts) { [string]$g.InstanceId })
for ($level = 0; $level -lt <Levels> -and $todo.Count -gt 0; $level++) {
  $found = @{}
  foreach ($key in 'DEVPKEY_Device_Parent', 'DEVPKEY_Device_LastKnownParent') {
    $ask = @(foreach ($id in $todo) { if (-not $found.ContainsKey($id)) { $id } })
    if ($ask.Count -eq 0) { break }
    $failures = $null
    $read = @(Get-PnpDeviceProperty -InstanceId $ask -KeyName $key -ErrorAction SilentlyContinue -ErrorVariable failures)
    foreach ($f in @($failures)) { if ($null -ne $f -and [string]$f.CategoryInfo.Category -cne 'ObjectNotFound') { throw $f.Exception } }
    foreach ($p in $read) { if ([string]$p.Type -cne 'Empty' -and -not [string]::IsNullOrEmpty([string]$p.Data)) { $found[[string]$p.InstanceId] = [string]$p.Data } }
  }
  $next = New-Object System.Collections.Generic.List[string]
  foreach ($id in $todo) {
    $up = ''
    if ($found.ContainsKey($id)) { $up = $found[$id] }
    $parent[$id] = $up
    if ($up -ne '' -and $class.ContainsKey($up) -and -not $parent.ContainsKey($up) -and -not $next.Contains($up)) { $next.Add($up) }
  }
  $todo = $next.ToArray()
}
foreach ($id in $todo) { if (-not $parent.ContainsKey($id)) { $parent[$id] = '' } }
$isGhost = @{}
foreach ($g in $ghosts) { $isGhost[[string]$g.InstanceId] = $true }
@{ Total = $total
   Items = @(foreach ($g in $ghosts) { $id = [string]$g.InstanceId; @{ InstanceId = $id; Class = [string]$g.Class; Name = [string]$g.FriendlyName; Parent = [string]$parent[$id] } })
   Nodes = @(foreach ($id in @($parent.Keys)) { if (-not $isGhost.ContainsKey($id)) { @{ InstanceId = $id; Class = [string]$class[$id]; Parent = [string]$parent[$id] } } }) }
'@

# --- Windows Update reset (spec 6.4) -------------------------------------------------------------------------------

function Get-ToolWuFolders {
  # Seam. The two update folders the reset renames: @( @{ Name = 'SoftwareDistribution'; Path }, @{ Name = 'catroot2';
  # Path } ) under %windir%.
  [CmdletBinding()]
  param()

  return @(
    @{ Name = 'SoftwareDistribution'; Path = [IO.Path]::Combine([string]$env:windir, 'SoftwareDistribution') }
    @{ Name = 'catroot2'; Path = [IO.Path]::Combine([string]$env:windir, 'System32', 'catroot2') }
  )
}

function Wait-ToolServiceStatus {
  # Private. Up to toolStep.service minutes (Get-ToolStepTimeout) for service -Name to read one of -Status, in 2 s
  # Wait-SetupDelay slices (counted, never the wall clock). $true when it does.
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string[]]$Status
  )

  $slices = [int][math]::Ceiling((Get-ToolStepTimeout -Run $Run -Name 'service') * 60 / 2)
  for ($i = 0; $i -le $slices; $i++) {
    if ($i -gt 0) { Wait-SetupDelay -Seconds 2 }
    $state = Get-ToolServiceState -Name $Name
    if ($null -ne $state -and $state.Status -cin $Status) { return $true }
  }
  return $false
}

function Send-ToolServiceStop {
  # Private. sc.exe stop -Name (toolStep.service): @{ Ok (exit 0, or 1062 "not started"); Exit (as 0x...) }. A service
  # that cannot take a control now (1061: it is starting) is waited for until it runs or stops (toolStep.service), then
  # asked once more (review M7).
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$Name)

  $sc = Get-ToolSystemTool -Name 'sc.exe'
  $stop = Invoke-ToolNative -Run $Run -FilePath $sc -ArgumentList ('stop ' + $Name) -StepTimeout 'service'
  if (-not $stop.TimedOut -and $stop.ExitCode -eq 1061) {
    $null = Wait-ToolServiceStatus -Run $Run -Name $Name -Status 'Running', 'Stopped'
    $state = Get-ToolServiceState -Name $Name
    if ($null -ne $state -and $state.Status -ceq 'Stopped') { return @{ Ok = $true; Exit = 'stopped meanwhile' } }
    $stop = Invoke-ToolNative -Run $Run -FilePath $sc -ArgumentList ('stop ' + $Name) -StepTimeout 'service'
  }
  return @{ Ok = ((-not $stop.TimedOut) -and ($stop.ExitCode -eq 0 -or $stop.ExitCode -eq 1062)); Exit = (Format-ToolExitCode -ExitCode $stop.ExitCode) }
}

function Stop-ToolWuServices {
  # Private. sc.exe stop for each update service that is not Stopped now, in the list's order (Send-ToolServiceStop),
  # then up to toolStep.service minutes for Stopped. One already stopping (StopPending) is only waited for; one still
  # starting (StartPending) is first waited for until it runs (review M7). Returns the names that did not stop.
  [CmdletBinding()]
  [OutputType([string[]])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $failed = New-Object System.Collections.Generic.List[string]
  foreach ($name in $script:WuResetServices) {
    $state = Get-ToolServiceState -Name $name
    if ($null -ne $state -and $state.Status -ceq 'StartPending') {
      $null = Wait-ToolServiceStatus -Run $Run -Name $name -Status 'Running', 'Stopped'
      $state = Get-ToolServiceState -Name $name
    }
    if ($null -eq $state -or $state.Status -ceq 'Stopped') { continue }
    $exit = 'not sent'
    $ok = $true
    if ($state.Status -cne 'StopPending') {
      $stop = Send-ToolServiceStop -Run $Run -Name $name
      $exit = $stop.Exit
      $ok = $stop.Ok
    }
    if ($ok) { $ok = Wait-ToolServiceStatus -Run $Run -Name $name -Status 'Stopped' }
    if (-not $ok) {
      Write-SetupLog -Level WARN -Message 'An update service did not stop' -Data @{ service = $name; exit = $exit }
      $failed.Add($name)
    }
  }
  return , [string[]]$failed.ToArray()
}

function Invoke-ToolStepWuServicesStop {
  <#
  .SYNOPSIS
    Step wuServicesStop (spec 6.4.1): records each update service's Status and StartType ($Run.Data.Services =
    @{ <name> = @{ Status; StartType; WasRunning } }, enum names; a service that cannot be read is recorded empty),
    reports a Disabled wuauserv, bits, cryptsvc or usosvc (WARN wuServiceDisabled: never changed, review I-13), then
    stops every one that runs (Stop-ToolWuServices): WARN wuServiceStopFailed for each that does not stop. 'warn' when
    a WARN was added, else 'done'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $services = [ordered]@{}
  foreach ($name in $script:WuResetServices) {
    $state = Get-ToolServiceState -Name $name
    if ($null -eq $state) {
      $services[$name] = @{ Status = ''; StartType = ''; WasRunning = $false }
    } else {
      $services[$name] = @{ Status = (ConvertTo-ScreenText -Text $state.Status); StartType = (ConvertTo-ScreenText -Text $state.StartType)
                            WasRunning = ($state.Status -cin 'Running', 'StartPending') }
    }
  }
  $Run.Data['Services'] = $services
  $status = 'done'
  foreach ($name in $script:WuDisabledReported) {
    if ([string]$services[$name]['StartType'] -ceq 'Disabled') {
      Add-ToolFinding -Run $Run -Level WARN -Code 'wuServiceDisabled' -Arguments @($name)
      $status = 'warn'
    }
  }
  foreach ($name in (Stop-ToolWuServices -Run $Run)) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'wuServiceStopFailed' -Arguments @($name)
    $status = 'warn'
  }
  $running = @(foreach ($name in $script:WuResetServices) { if ($services[$name]['WasRunning'] -eq $true) { $name } })
  Add-ToolLog -Run $Run -Text ('Update services that were running: {0}' -f $(if ($running.Count -gt 0) { $running -join ', ' } else { 'none' }))
  return $status
}

function Get-ToolErrorCode {
  # Private. The HRESULT of the innermost exception of -Exception's chain that carries a Win32 one (0x8007....), else
  # of -Exception itself; $null without an exception. Language-independent, unlike the message.
  [CmdletBinding()]
  param([AllowNull()][Exception]$Exception)

  if ($null -eq $Exception) { return $null }
  $code = $Exception.HResult
  $e = $Exception
  while ($null -ne $e) {
    if (($e.HResult -band 0xFFFF0000) -eq (0x80070000 -band 0xFFFF0000)) { $code = $e.HResult }
    $e = $e.InnerException
  }
  return $code
}

function Invoke-ToolStepWuRename {
  <#
  .SYNOPSIS
    Step wuRename (spec 6.4.2): SoftwareDistribution and catroot2 (Get-ToolWuFolders) are renamed to
    <name>.bak-<yyyyMMdd-HHmmss> (Rename-Item -LiteralPath -NewName -ErrorAction Stop). Nothing is deleted.
  .DESCRIPTION
    Up to three tries, 3 s apart, the update services stopped again before each retry (a trigger may have started
    one, and it locks the folder); no retry once 3 minutes or less of the action's time are left (review M6:
    wuServicesStart still needs its share). A name already taken gets -2, -3, ... (review M10). Renamed: INFO
    wuRenamed (the old and the new name). Not renamed: WARN wuRenameLocked when the last error's HRESULT is a sharing
    or lock violation, else WARN wuRenameFailed with the HRESULT as 0x... (review M8; never the error's localized
    text). A folder that is a reparse point is never renamed (WARN wuRenameLink); a folder that is not there is skipped
    (logged). $Run.Data.WuRename = @{ <name> = <new name or ''> }.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $status = 'done'
  $result = @{}
  foreach ($folder in @(Get-ToolWuFolders)) {
    $name = [string]$folder['Name']
    $path = [string]$folder['Path']
    $result[$name] = ''
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
      Add-ToolLog -Run $Run -Text ('{0}: not found, nothing to rename' -f $name)
      continue
    }
    if (Test-StickReparsePoint -Path $path) {
      Write-SetupLog -Level WARN -Message 'An update folder is a reparse point; it was not renamed' -Data @{ folder = (ConvertTo-ScreenText -Text $path) }
      Add-ToolFinding -Run $Run -Level WARN -Code 'wuRenameLink' -Arguments @($name)
      $status = 'warn'
      continue
    }
    $newName = ''
    $lastError = ''
    $lastCode = $null
    $parent = [IO.Path]::GetDirectoryName($path)
    for ($try = 1; $try -le $script:WuRenameTries; $try++) {
      if ($try -gt 1) {
        if ((Get-ToolRemainingSeconds -Run $Run) -le $script:WuRenameReserveSeconds) {
          Write-SetupLog -Level WARN -Message 'No more rename tries: the action is short of time' -Data @{ folder = $name; tries = ($try - 1) }
          break
        }
        $null = Stop-ToolWuServices -Run $Run
        Wait-SetupDelay -Seconds $script:WuRenamePauseSeconds
      }
      $stamp = '{0}.bak-{1}' -f $name, (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
      $candidate = $stamp
      for ($n = 2; $n -le 9 -and (Test-Path -LiteralPath ([IO.Path]::Combine($parent, $candidate))); $n++) { $candidate = '{0}-{1}' -f $stamp, $n }
      try {
        Rename-Item -LiteralPath $path -NewName $candidate -ErrorAction Stop
        $newName = $candidate
        break
      } catch {
        $lastError = ConvertTo-ScreenText -Text $_.Exception.Message
        $lastCode = Get-ToolErrorCode -Exception $_.Exception
      }
    }
    if ($newName -ne '') {
      $result[$name] = $newName
      Add-ToolFinding -Run $Run -Level INFO -Code 'wuRenamed' -Arguments @($name, $newName)
    } else {
      Write-SetupLog -Level WARN -Message 'An update folder could not be renamed' -Data @{ folder = $name; code = (Format-ToolExitCode -ExitCode $lastCode); error = $lastError }
      if ($null -ne $lastCode -and $script:WuRenameLockedCodes -contains $lastCode) {
        Add-ToolFinding -Run $Run -Level WARN -Code 'wuRenameLocked' -Arguments @($name)
      } else {
        Add-ToolFinding -Run $Run -Level WARN -Code 'wuRenameFailed' -Arguments @($name, (Format-ToolExitCode -ExitCode $lastCode))
      }
      $status = 'warn'
    }
  }
  $Run.Data['WuRename'] = $result
  return $status
}

function Invoke-ToolStepWuBits {
  <#
  .SYNOPSIS
    Step wuBits (spec 6.4.3): the grandchild wuBits (toolStep.grandchild) removes only the Get-BitsTransfer -AllUsers
    jobs with a file under SoftwareDistribution (by its LocalName, never the job's localized name; Plan call). INFO
    wuBitsCleared with the count; a grandchild that fails, or jobs that could not be removed: WARN wuBitsFailed.
    $Run.Data.WuBits = @{ Removed; Failed }.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $root = ''
  foreach ($folder in @(Get-ToolWuFolders)) { if ([string]$folder['Name'] -ceq 'SoftwareDistribution') { $root = [string]$folder['Path'] } }
  if ($root -eq '') {
    Add-ToolFinding -Run $Run -Level WARN -Code 'wuBitsFailed' -Arguments @('no SoftwareDistribution folder')
    return 'warn'
  }
  $root = $root.TrimEnd('\') + '\'
  $command = $script:ToolWuBitsCommand.Replace('<R>', (ConvertTo-PowerShellLiteral -Text $root))
  $bits = Invoke-ToolJsonChild -Run $Run -Name 'wuBits' -Command $command -StepTimeout 'grandchild'
  if (-not $bits.Ok) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'wuBitsFailed' -Arguments @($bits.Error)
    if ($bits.TimedOut) { return 'timedout' }
    return 'warn'
  }
  $removed = 0
  $failed = 0
  $null = [int]::TryParse([string]$bits.Data['Removed'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$removed)
  $null = [int]::TryParse([string]$bits.Data['Failed'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$failed)
  $Run.Data['WuBits'] = @{ Removed = $removed; Failed = $failed }
  Add-ToolFinding -Run $Run -Level INFO -Code 'wuBitsCleared' -Arguments @($removed)
  if ($failed -gt 0) {
    $first = @(foreach ($e in @($bits.Data['Errors'])) { if ($null -ne $e) { [string]$e } }) | Select-Object -First 1
    Add-ToolFinding -Run $Run -Level WARN -Code 'wuBitsFailed' -Arguments @(('{0} jobs: {1}' -f $failed, [string]$first))
    return 'warn'
  }
  return 'done'
}

function Invoke-ToolStepWuServicesStart {
  <#
  .SYNOPSIS
    Step wuServicesStart (spec 6.4.4; AlwaysRun: it runs after a Stop, an Abort or the deadline too, review I-2):
    starts again, in reverse order, every update service that was running before wuServicesStop and is not Disabled
    (sc.exe start: exit 0, or 1056 "already running"; then up to toolStep.service minutes for Running). One that does
    not run: CRIT wuServiceStartFailed, 'failed'. Nothing recorded (the action stopped before wuServicesStop ran):
    nothing to start, 'skipped'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $services = $Run.Data['Services']
  if ($services -isnot [System.Collections.IDictionary]) {
    Add-ToolLog -Run $Run -Text 'Update services: none was stopped, none to start'
    return 'skipped'
  }
  $status = 'done'
  $started = New-Object System.Collections.Generic.List[string]
  for ($i = $script:WuResetServices.Count - 1; $i -ge 0; $i--) {
    $name = $script:WuResetServices[$i]
    $record = $services[$name]
    if ($record -isnot [System.Collections.IDictionary] -or $record['WasRunning'] -ne $true -or [string]$record['StartType'] -ceq 'Disabled') { continue }
    $start = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'sc.exe') -ArgumentList ('start ' + $name) -StepTimeout 'service'
    $ok = (-not $start.TimedOut) -and ($start.ExitCode -eq 0 -or $start.ExitCode -eq 1056)
    if ($ok) { $ok = Wait-ToolServiceStatus -Run $Run -Name $name -Status 'Running' }
    if ($ok) {
      $started.Add($name)
    } else {
      Write-SetupLog -Level WARN -Message 'An update service did not start again' -Data @{ service = $name; exit = (Format-ToolExitCode -ExitCode $start.ExitCode) }
      Add-ToolFinding -Run $Run -Level CRIT -Code 'wuServiceStartFailed' -Arguments @($name)
      $status = 'failed'
    }
  }
  Add-ToolLog -Run $Run -Text ('Update services started again: {0}' -f $(if ($started.Count -gt 0) { $started.ToArray() -join ', ' } else { 'none' }))
  return $status
}

# --- Disk check at restart (spec 6.5, ruling RD-R1) ----------------------------------------------------------------

function Invoke-ToolStepDiskCheckSchedule {
  <#
  .SYNOPSIS
    Step diskCheckSchedule (spec 6.5): fsutil.exe dirty set <system drive> (toolStep.native); scheduled only when the
    exit code is 0 AND Win32_Volume.DirtyBitSet reads $true afterwards (Get-ToolDiskCheckState): INFO
    diskCheckScheduled and RestartRequired. A timeout, another exit code or a dirty bit that reads $false is CRIT
    diskCheckNotScheduled with the reason.
  .DESCRIPTION
    A drive this PC excludes from the start-up check (Session Manager BootExecute /k:, Get-ToolDiskCheckState) is not
    marked: autochk would skip it at every start, so the check would never run (CRIT, the reason says so). The
    exclusion is only read, never changed (ruling RD-R1: no cancel).
    What cannot be read is never read as an answer (review M5): exit 0 with a dirty bit that cannot be read, or a
    marked volume whose start-up check list (BootExecute) cannot be read, is WARN diskCheckUnconfirmed ("probably
    scheduled", with what could not be read) and RestartRequired (the volume is probably marked, and there is no
    cancel). $Run.Data.DiskCheck = @{ Drive; ExitCode; Dirty; Excluded; ExcludedUnknown }.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $letter = Get-ToolSystemLetter
  if ($letter -eq '') {
    Add-ToolFinding -Run $Run -Level CRIT -Code 'diskCheckNotScheduled' -Arguments @('no system drive letter')
    return 'failed'
  }
  $drive = $letter + ':'
  $before = Get-ToolDiskCheckState -Drive $drive
  $record = @{ Drive = $drive; ExitCode = $null; Dirty = $before['Dirty']; Excluded = ($before['Excluded'] -eq $true)
              ExcludedUnknown = ($before['ExcludedUnknown'] -eq $true) }
  $Run.Data['DiskCheck'] = $record
  if ($record['Excluded']) {
    Add-ToolFinding -Run $Run -Level CRIT -Code 'diskCheckNotScheduled' -Arguments @(('{0} is excluded from the start-up check on this PC' -f $drive))
    return 'failed'
  }
  $native = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'fsutil.exe') -ArgumentList ('dirty set ' + $drive) -StepTimeout 'native'
  $record['ExitCode'] = $native.ExitCode
  if ($native.TimedOut) {
    Add-ToolFinding -Run $Run -Level CRIT -Code 'diskCheckNotScheduled' -Arguments @('fsutil timed out')
    return 'timedout'
  }
  Add-ToolLog -Run $Run -Text ('fsutil dirty set {0}: {1}' -f $drive, (Format-ToolExitCode -ExitCode $native.ExitCode))
  if ($native.ExitCode -ne 0) {
    Add-ToolFinding -Run $Run -Level CRIT -Code 'diskCheckNotScheduled' -Arguments @(('fsutil returned {0}' -f (Format-ToolExitCode -ExitCode $native.ExitCode)))
    return 'failed'
  }
  $after = Get-ToolDiskCheckState -Drive $drive
  $record['Dirty'] = $after['Dirty']
  $unknownList = ($record['ExcludedUnknown'] -eq $true)
  if ($null -eq $after['Dirty'] -or ($after['Dirty'] -eq $true -and $unknownList)) {
    $what = if ($null -eq $after['Dirty']) { 'the dirty bit could not be read' } else { 'the start-up check list could not be read' }
    Add-ToolFinding -Run $Run -Level WARN -Code 'diskCheckUnconfirmed' -Arguments @($what)
    $Run.RestartRequired = $true
    return 'warn'
  }
  if ($after['Dirty'] -eq $true) {
    Add-ToolFinding -Run $Run -Level INFO -Code 'diskCheckScheduled'
    $Run.RestartRequired = $true
    return 'done'
  }
  Add-ToolFinding -Run $Run -Level CRIT -Code 'diskCheckNotScheduled' -Arguments @('the volume is not marked dirty')
  return 'failed'
}

# --- Network settings (spec 6.6) -----------------------------------------------------------------------------------

function ConvertTo-ToolIpText {
  <#
  .SYNOPSIS
    Private. -Value as an IP address in canonical form, or '' when it is not one. Pure.
  .DESCRIPTION
    IPv4: a dotted quad of 0..255 with no leading zero (192.168.1.300, 192.168.01.10 and 192.168.1 are refused:
    [ipaddress] alone takes the last two as other addresses). IPv6: hex digits, colons and dots only, parsed by
    [ipaddress] and re-rendered. -StripZone drops an IPv6 zone (%12) first (Windows' own answers); otherwise a zone
    makes it no address. Text only: a number or an object is no address.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Value, [switch]$StripZone)

  if ($Value -isnot [string]) { return '' }
  $text = $Value.Trim()
  if ($StripZone) {
    $cut = $text.IndexOf('%')
    if ($cut -ge 0) { $text = $text.Substring(0, $cut) }
  }
  $ip = $null
  $octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  if ($text -cmatch ('^' + $octet + '(\.' + $octet + '){3}\z')) {
    if ([ipaddress]::TryParse($text, [ref]$ip)) { return $ip.ToString() }
    return ''
  }
  if ($text.Contains(':') -and $text -cmatch '^[0-9A-Fa-f:.]{2,45}\z') {
    if ([ipaddress]::TryParse($text, [ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { return $ip.ToString() }
  }
  return ''
}

function Get-ToolNetList {
  # Private. A list read from JSON or built here, as an array (missing = empty), or $null when it is no list (text, an
  # object, a number). Wrapped: an empty or one-item array survives the return.
  [CmdletBinding()]
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return , @() }
  if ($Value -is [string] -or $Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject] -or
      $Value -isnot [System.Collections.IEnumerable]) { return $null }
  return , @(foreach ($v in $Value) { $v })
}

function ConvertTo-ToolNetAdapter {
  <#
  .SYNOPSIS
    Private. One adapter's settings, checked and in canonical form: @{ Alias (ASCII); Guid ('{...}', upper case); Mac
    ('' or AA-BB-CC-DD-EE-FF); Ipv4Dhcp; Ipv6Dhcp; Addresses = @( @{ Ip; Prefix } ); Gateways = [string[]];
    Dns = [string[]] }, or $null.
  .DESCRIPTION
    -Strict (a saved file, Test-ToolNetBackup): every value must be right or the adapter is $null: the GUID a GUID,
    the MAC empty or the dash form, the DHCP flags booleans, every IP a canonical-able address (ConvertTo-ToolIpText,
    no zone), every prefix a whole number in its family's range (0..32, 0..128), no unspecified gateway or DNS server
    (0.0.0.0, ::), at most 32 addresses, 8 gateways and 16 DNS servers, the lists lists.
    Without it (Windows' own answer, Get-ToolNetSettings): the GUID must still be one; a MAC that is no MAC (a tunnel
    adapter's) becomes '', an IPv6 zone is dropped, the unspecified gateways (on-link routes) are no gateways, and a
    value that still is no address is dropped and logged. Repeats go in both.
  #>
  [CmdletBinding()]
  param([AllowNull()]$Row, [switch]$Strict)

  if ($Row -isnot [System.Collections.IDictionary]) { return $null }
  $guid = [guid]::Empty
  if ($Row['Guid'] -isnot [string] -or -not [guid]::TryParse($Row['Guid'], [ref]$guid)) { return $null }
  $mac = $Row['Mac']
  if ($null -eq $mac) { $mac = '' }
  if ($mac -isnot [string]) { return $null }
  $mac = $mac.Trim().ToUpperInvariant()
  if ($mac -ne '' -and $mac -cnotmatch '^([0-9A-F]{2}-){5}[0-9A-F]{2}\z') {
    if ($Strict) { return $null }
    $mac = ''
  }
  $flags = @{}
  foreach ($key in 'Ipv4Dhcp', 'Ipv6Dhcp') {
    if ($Strict -and $Row[$key] -isnot [bool]) { return $null }
    $flags[$key] = ($Row[$key] -eq $true)
  }
  $alias = ConvertTo-ToolDisplayText -Text $Row['Alias'] -MaxLength $script:NetAliasMax

  $addressList = Get-ToolNetList -Value $Row['Addresses']
  $gatewayList = Get-ToolNetList -Value $Row['Gateways']
  $dnsList = Get-ToolNetList -Value $Row['Dns']
  if ($null -eq $addressList -or $null -eq $gatewayList -or $null -eq $dnsList) { return $null }

  $addresses = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($entry in $addressList) {
    $ip = ''
    $prefix = $null
    if ($entry -is [System.Collections.IDictionary]) {
      $ip = ConvertTo-ToolIpText -Value $entry['Ip'] -StripZone:(-not $Strict)
      $prefix = $entry['Prefix']
    }
    $whole = ($prefix -is [int] -or $prefix -is [long] -or $prefix -is [byte] -or $prefix -is [int16])
    $max = if ($ip.Contains(':')) { 128 } else { 32 }
    if ($ip -eq '' -or -not $whole -or [long]$prefix -lt 0 -or [long]$prefix -gt $max) {
      if ($Strict) { return $null }
      Write-SetupLog -Level WARN -Message 'An adapter address was not read' -Data @{ adapter = (ConvertTo-ScreenText -Text $alias) }
      continue
    }
    if ($seen.ContainsKey($ip)) { continue }
    $seen[$ip] = $true
    $addresses.Add(@{ Ip = $ip; Prefix = [int]$prefix })
  }

  $lists = @{}
  foreach ($kind in 'Gateways', 'Dns') {
    $values = New-Object System.Collections.Generic.List[string]
    $source = if ($kind -ceq 'Gateways') { $gatewayList } else { $dnsList }
    foreach ($entry in $source) {
      $ip = ConvertTo-ToolIpText -Value $entry -StripZone:(-not $Strict)
      if ($ip -eq '' -or $ip -ceq '0.0.0.0' -or $ip -ceq '::') {
        if ($Strict) { return $null }
        if ($ip -eq '') { Write-SetupLog -Level WARN -Message 'An adapter gateway or DNS server was not read' -Data @{ adapter = (ConvertTo-ScreenText -Text $alias); kind = $kind } }
        continue
      }
      if (-not $values.Contains($ip)) { $values.Add($ip) }
    }
    $lists[$kind] = $values
  }
  if ($Strict -and ($addresses.Count -gt $script:NetBackupMaxAddresses -or $lists['Gateways'].Count -gt $script:NetBackupMaxGateways -or
                    $lists['Dns'].Count -gt $script:NetBackupMaxDns)) { return $null }

  return @{ Alias = $alias; Guid = $guid.ToString('B').ToUpperInvariant(); Mac = $mac; Ipv4Dhcp = $flags['Ipv4Dhcp']; Ipv6Dhcp = $flags['Ipv6Dhcp']
            Addresses = $addresses.ToArray(); Gateways = [string[]]$lists['Gateways'].ToArray(); Dns = [string[]]$lists['Dns'].ToArray() }
}

function Test-ToolNetStatic {
  # Private. $true when an adapter row (ConvertTo-ToolNetAdapter) has any static value: an address, a gateway or a DNS
  # server. The window lists exactly these (DNS-only too), and Restore applies exactly these; a DHCP-only adapter is
  # left alone.
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()]$Adapter)

  if ($Adapter -isnot [System.Collections.IDictionary]) { return $false }
  foreach ($key in 'Addresses', 'Gateways', 'Dns') {
    foreach ($value in @($Adapter[$key])) { if ($null -ne $value -and [string]$value -ne '') { return $true } }
  }
  return $false
}

function Get-ToolNetSettings {
  <#
  .SYNOPSIS
    Every network adapter's settings, read in the grandchild netSettings (toolStep.grandchild): an array of
    ConvertTo-ToolNetAdapter rows (Get-NetAdapter's order; empty when there is none), or $null when they could not be
    read (the reason in $Run.Data.CheckErrors.netSettings). Never throws.
  .DESCRIPTION
    An adapter whose answer is no adapter (no GUID) fails the whole read: a backup must hold every adapter.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Run)

  $child = Invoke-ToolJsonChild -Run $Run -Name 'netSettings' -Command $script:ToolNetSettingsCommand -StepTimeout 'grandchild'
  if (-not $child.Ok) {
    Set-ToolCheckError -Run $Run -Name 'netSettings' -Reason $child.Error
    return $null
  }
  if (-not $child.Data.ContainsKey('Items')) {
    Set-ToolCheckError -Run $Run -Name 'netSettings' -Reason 'no adapter list in the answer'
    return $null
  }
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($item in @($child.Data['Items'])) {
    $row = ConvertTo-ToolNetAdapter -Row $item
    if ($null -eq $row) {
      Set-ToolCheckError -Run $Run -Name 'netSettings' -Reason 'an adapter without a GUID in the answer'
      return $null
    }
    $rows.Add($row)
  }
  return , $rows.ToArray()
}

function Test-ToolRemoteSession {
  <#
  .SYNOPSIS
    Whether this session is a Remote Desktop one: @{ Rdp }. Ruling RD-R2: only RDP is detected, and only to make the
    Network reset warning red; AnyDesk and ScreenConnect are never read as connected (their clients run on every PC
    Ben sets up), and the confirmation always asks for the at-PC tick. Never throws.
  .DESCRIPTION
    -TerminalServerSession is the seam: by default [System.Windows.Forms.SystemInformation]::TerminalServerSession.
    Only a [bool] $true counts; anything else, or a seam that throws (logged), is $false.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([scriptblock]$TerminalServerSession)

  if ($null -eq $TerminalServerSession) {
    $TerminalServerSession = {
      Add-Type -AssemblyName System.Windows.Forms
      [System.Windows.Forms.SystemInformation]::TerminalServerSession
    }
  }
  $rdp = $false
  try {
    $values = @(& $TerminalServerSession)
    $rdp = ($values.Count -gt 0 -and $values[-1] -is [bool] -and $values[-1])
  } catch {
    Write-SetupLog -Level WARN -Message 'The remote session could not be read' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  return @{ Rdp = [bool]$rdp }
}

function Invoke-ToolStepNetInfo {
  <#
  .SYNOPSIS
    Step netInfo (the info child the Network reset confirmation waits for): $Run.Data.NetInfo = @{ Adapters = <the
    adapters with a static value, Get-ToolNetSettings rows: Gateways and Dns plain IP strings>; Remote = @{ Rdp }
    (Test-ToolRemoteSession) }. Settings that cannot be read: CRIT stepFailed and no NetInfo (the window shows the
    failure, never "no static settings").
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $adapters = Get-ToolNetSettings -Run $Run
  if ($null -eq $adapters) {
    Add-ToolFinding -Run $Run -Level CRIT -Code 'stepFailed' -Arguments @((Get-ToolStepName -Id 'netInfo'), ('the network settings could not be read ({0})' -f (Get-ToolCheckError -Run $Run -Name 'netSettings')))
    if (Test-ToolCheckTimedOut -Run $Run -Name 'netSettings') { return 'timedout' }
    return 'failed'
  }
  $static = New-Object System.Collections.Generic.List[object]
  foreach ($adapter in $adapters) { if (Test-ToolNetStatic -Adapter $adapter) { $static.Add($adapter) } }
  $remote = Test-ToolRemoteSession
  $Run.Data['NetInfo'] = @{ Adapters = $static.ToArray(); Remote = $remote }
  Add-ToolLog -Run $Run -Text ('Network settings: {0} adapters, {1} with static settings; Remote Desktop {2}' -f @($adapters).Count, $static.Count, $remote['Rdp'])
  return 'done'
}

function ConvertTo-ToolSortedObject {
  # Private. -InputObject with every dictionary's keys in ordinal order, recursively (lists stay lists), so two copies
  # of the same data compare equal as JSON whatever order their hashtables enumerate in.
  [CmdletBinding()]
  param([AllowNull()]$InputObject)

  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [string]) { return $InputObject }
  if ($InputObject -is [System.Collections.IDictionary]) {
    $keys = [string[]]@(foreach ($k in $InputObject.Keys) { [string]$k })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $sorted = [ordered]@{}
    foreach ($key in $keys) { $sorted[$key] = ConvertTo-ToolSortedObject -InputObject $InputObject[$key] }
    return $sorted
  }
  if ($InputObject -is [System.Collections.IEnumerable]) { return , @(foreach ($item in $InputObject) { ConvertTo-ToolSortedObject -InputObject $item }) }
  return $InputObject
}

function Invoke-ToolStepNetBackup {
  <#
  .SYNOPSIS
    Step netBackup (spec 6.6.1): every adapter's settings (Get-ToolNetSettings) saved to
    <session>\network-backup-<yyyyMMdd-HHmmss>.json as @{ Version = 1; CreatedAt; Identity = @{ Key; ComputerName };
    Adapters } (Write-ToolJsonFile), then read back (Read-ToolJsonFile) and compared: ConvertTo-Json -Compress of both,
    their keys sorted, must be equal, and the copy must be a valid backup (ConvertFrom-ToolNetBackup). INFO
    netBackupSaved with the path; $Run.Files.NetBackup.
  .DESCRIPTION
    No verified backup, no reset (Review Focus 3): a session folder that is not the stick's (the local fallback: no
    stick, a link, or a folder that could not be made; Data.SessionIsLocal), settings that cannot be read, more than 16
    adapters with static settings, a file that cannot be written or reads back different: CRIT netBackupFailed and
    'failed'. $Run.Data.Abort is set before anything else and cleared only on success, so the runner ends the action
    (no reset step runs) after a failure, and after a step that throws too. Over 16 adapters, the DHCP-only
    ones are left out from the end (they hold nothing to restore). A PC without an identity key (no serial, no usable
    BIOS UUID) could never get a backup back (Test-ToolNetBackup never matches an empty key): CRIT netBackupNoIdentity,
    nothing read, saved or reset (review M3).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  # Abort first, cleared only at the very end: a step that throws (Invoke-ToolStep catches it) still ends the action.
  $Run.Data['Abort'] = $true
  $key = [string](Get-ToolArgsEntry -Run $Run -Section 'Identity' -Name 'Key')
  if ($key -eq '') {
    Write-SetupLog -Level WARN -Message 'This PC has no identity key: a backup could never be restored, so nothing is reset'
    Add-ToolFinding -Run $Run -Level CRIT -Code 'netBackupNoIdentity'
    return 'failed'
  }
  $problem = ''
  $path = ''
  $backup = $null
  if ($Run.Data['SessionIsLocal'] -ne $false -or [string]::IsNullOrEmpty([string]$Run.SessionDir)) { $problem = 'the session folder is not on the stick' }
  $adapters = $null
  if ($problem -eq '') {
    $adapters = Get-ToolNetSettings -Run $Run
    if ($null -eq $adapters) { $problem = 'the settings could not be read ({0})' -f (Get-ToolCheckError -Run $Run -Name 'netSettings') }
  }
  if ($problem -eq '') {
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in $adapters) { $kept.Add($adapter) }
    for ($i = $kept.Count - 1; $i -ge 0 -and $kept.Count -gt $script:NetBackupMaxAdapters; $i--) {
      if (-not (Test-ToolNetStatic -Adapter $kept[$i])) { $kept.RemoveAt($i) }
    }
    if ($kept.Count -gt $script:NetBackupMaxAdapters) { $problem = 'more than {0} adapters have static settings' -f $script:NetBackupMaxAdapters }
    $computer = ConvertTo-ScreenText -Text ([string](Get-ToolArgsEntry -Run $Run -Section 'Identity' -Name 'ComputerName'))
    $backup = [ordered]@{ Version = 1; CreatedAt = (Get-Date).ToString('s', [Globalization.CultureInfo]::InvariantCulture)
                          Identity = [ordered]@{ Key = $key; ComputerName = $computer }; Adapters = $kept.ToArray() }
  }
  if ($problem -eq '') {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $path = [IO.Path]::Combine([string]$Run.SessionDir, ('network-backup-{0}.json' -f $stamp))
    try {
      if (Test-StickReparsePoint -Path ([string]$Run.SessionDir)) { $problem = 'the session folder is a link' }
      elseif ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) { $problem = 'the file already exists' }
    } catch {
      $problem = ConvertTo-ScreenText -Text $_.Exception.Message
    }
  }
  if ($problem -eq '' -and -not (Write-ToolJsonFile -Path $path -InputObject $backup -Depth 8)) { $problem = 'the file could not be written' }
  if ($problem -eq '') {
    $back = Read-ToolJsonFile -Path $path
    $wrote = ConvertTo-Json -InputObject (ConvertTo-ToolSortedObject -InputObject $backup) -Depth 12 -Compress
    $read = if ($null -eq $back) { '' } else { ConvertTo-Json -InputObject (ConvertTo-ToolSortedObject -InputObject $back) -Depth 12 -Compress }
    if ($read -cne $wrote) { $problem = 'the file read back differs' }
    elseif ($null -eq (ConvertFrom-ToolNetBackup -Value $back)) { $problem = 'the file read back is not a valid backup' }
  }
  if ($problem -ne '') {
    Write-SetupLog -Level WARN -Message 'The network settings were not saved; nothing is reset' -Data @{ reason = (ConvertTo-ScreenText -Text $problem); path = (ConvertTo-ScreenText -Text $path) }
    Add-ToolFinding -Run $Run -Level CRIT -Code 'netBackupFailed'
    return 'failed'
  }
  $Run.Files['NetBackup'] = $path
  Add-ToolLog -Run $Run -Text ('Network settings of {0} adapters saved' -f @($backup['Adapters']).Count)
  Add-ToolFinding -Run $Run -Level INFO -Code 'netBackupSaved' -Arguments @($path)
  $Run.Data.Remove('Abort')
  return 'done'
}

function Invoke-ToolNetResetCommand {
  # Private. One reset tool (toolStep.native), judged by its exit code only: 0 is 'done'; another exit is WARN
  # netResetStepFailed ('<tool> <arguments>', the code as 0x...), 'warn'; a timeout the same with 'timed out',
  # 'timedout'. -NeedsRestart: RestartRequired and INFO restartRequired (once), whatever the exit code (the reset may
  # have begun).
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$Tool,
    [Parameter(Mandatory)][string]$Arguments,
    [switch]$NeedsRestart
  )

  $label = '{0} {1}' -f [IO.Path]::GetFileNameWithoutExtension($Tool), $Arguments
  $native = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name $Tool) -ArgumentList $Arguments -StepTimeout 'native'
  if ($NeedsRestart) {
    $Run.RestartRequired = $true
    if (-not (Test-ToolFindingCode -Run $Run -Code 'restartRequired')) { Add-ToolFinding -Run $Run -Level INFO -Code 'restartRequired' }
  }
  if ($native.TimedOut) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'netResetStepFailed' -Arguments @($label, 'timed out')
    return 'timedout'
  }
  Add-ToolLog -Run $Run -Text ('{0}: {1}' -f $label, (Format-ToolExitCode -ExitCode $native.ExitCode))
  if ($native.ExitCode -ne 0) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'netResetStepFailed' -Arguments @($label, (Format-ToolExitCode -ExitCode $native.ExitCode))
    return 'warn'
  }
  return 'done'
}

function Invoke-ToolStepWinsockReset {
  # Step winsockReset (spec 6.6.2): netsh.exe winsock reset; a restart is needed.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  return (Invoke-ToolNetResetCommand -Run $Run -Tool 'netsh.exe' -Arguments 'winsock reset' -NeedsRestart)
}

function Invoke-ToolStepIpReset {
  # Step ipReset (spec 6.6.2): netsh.exe int ip reset (IPv4); a restart is needed.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  return (Invoke-ToolNetResetCommand -Run $Run -Tool 'netsh.exe' -Arguments 'int ip reset' -NeedsRestart)
}

function Invoke-ToolStepIpv6Reset {
  # Step ipv6Reset (spec 6.6.2): netsh.exe int ipv6 reset; a restart is needed.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  return (Invoke-ToolNetResetCommand -Run $Run -Tool 'netsh.exe' -Arguments 'int ipv6 reset' -NeedsRestart)
}

function Invoke-ToolStepDnsFlush {
  # Step dnsFlush (spec 6.6.2): ipconfig.exe /flushdns, the DNS cache only (the leases are the restart's).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  return (Invoke-ToolNetResetCommand -Run $Run -Tool 'ipconfig.exe' -Arguments '/flushdns')
}

# --- Saved network backups and Restore (spec 6.6) ------------------------------------------------------------------

function ConvertFrom-ToolNetBackup {
  <#
  .SYNOPSIS
    Private. A saved network backup (a hashtable, or an object read from JSON) checked and in canonical form:
    @{ Version = 1; CreatedAt; Identity = @{ Key; ComputerName }; Adapters = <ConvertTo-ToolNetAdapter -Strict rows> },
    or $null. Pure. Test-ToolNetBackup adds the identity check.
  .DESCRIPTION
    Version is the number 1; Identity an object whose Key is text; CreatedAt and ComputerName text when present;
    Adapters a list of at most 16 adapters, every one valid (one bad value refuses the whole file).
  #>
  [CmdletBinding()]
  param([AllowNull()]$Value)

  if ($Value -is [System.Management.Automation.PSCustomObject]) { $Value = ConvertTo-HashtableDeep -InputObject $Value }
  if ($Value -isnot [System.Collections.IDictionary]) { return $null }
  $version = $Value['Version']
  if (-not (($version -is [int] -or $version -is [long]) -and $version -eq 1)) { return $null }
  $identity = $Value['Identity']
  if ($identity -isnot [System.Collections.IDictionary] -or $identity['Key'] -isnot [string]) { return $null }
  $computer = $identity['ComputerName']
  if ($null -ne $computer -and $computer -isnot [string]) { return $null }
  $created = $Value['CreatedAt']
  if ($null -ne $created -and $created -isnot [string]) { return $null }
  if (-not $Value.Contains('Adapters')) { return $null }
  $list = Get-ToolNetList -Value $Value['Adapters']
  if ($null -eq $list -or $list.Count -gt $script:NetBackupMaxAdapters) { return $null }
  $adapters = New-Object System.Collections.Generic.List[object]
  foreach ($entry in $list) {
    $row = ConvertTo-ToolNetAdapter -Row $entry -Strict
    if ($null -eq $row) { return $null }
    $adapters.Add($row)
  }
  $createdText = ConvertTo-ScreenText -Text ([string]$created)
  if ($createdText.Length -gt 40) { $createdText = $createdText.Substring(0, 40) }
  return @{ Version = 1; CreatedAt = $createdText; Identity = @{ Key = [string]$identity['Key']; ComputerName = (ConvertTo-ScreenText -Text ([string]$computer)) }
            Adapters = $adapters.ToArray() }
}

function Test-ToolNetBackup {
  <#
  .SYNOPSIS
    A saved network backup checked for this PC (pure): ConvertFrom-ToolNetBackup's canonical form when it is valid AND
    its Identity.Key equals -IdentityKey (ordinal), else $null. An empty key never matches (a PC without a serial or a
    usable BIOS UUID has nothing to go by).
  .DESCRIPTION
    Valid means: Version 1; at most 16 adapters; each Guid a GUID; each Mac empty or ([0-9A-F]{2}-){5}[0-9A-F]{2}; the
    DHCP flags booleans; every Ip, gateway and DNS server an IP address (re-rendered with [ipaddress].ToString(); no
    leading zeros, no zone, no unspecified address); each Prefix a whole number 0..32 (IPv4) or 0..128 (IPv6).
  #>
  [CmdletBinding()]
  param(
    [AllowNull()]$Value,
    [AllowNull()][AllowEmptyString()][string]$IdentityKey
  )

  if ([string]::IsNullOrEmpty($IdentityKey)) { return $null }
  $backup = ConvertFrom-ToolNetBackup -Value $Value
  if ($null -eq $backup) { return $null }
  if (-not [string]::Equals([string]$backup['Identity']['Key'], $IdentityKey, [StringComparison]::Ordinal)) { return $null }
  return $backup
}

function Test-ToolNetBackupPath {
  <#
  .SYNOPSIS
    Private. $true when -Path names a network backup on the stick: <StickRoot>BenTech-Reports\<one folder>\
    network-backup-<yyyyMMdd-HHmmss>.json, fully qualified, printable ASCII, already in its full form (no '..', no
    trailing dot), and neither BenTech-Reports, the folder nor the file is a reparse point (V2-R13). Never throws.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Path,
    [AllowNull()][AllowEmptyString()][string]$StickRoot
  )

  try {
    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($StickRoot)) { return $false }
    if ($Path -notmatch '^[A-Za-z]:\\' -or $StickRoot -notmatch '^[A-Za-z]:\\' -or $Path -cnotmatch '^[\x20-\x7E]+\z') { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($full, $Path, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $reports = [IO.Path]::Combine([IO.Path]::GetFullPath($StickRoot), 'BenTech-Reports').TrimEnd('\')
    $folder = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrEmpty($folder) -or -not [string]::Equals([IO.Path]::GetDirectoryName($folder), $reports, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ([IO.Path]::GetFileName($full) -cnotmatch '^network-backup-[0-9]{8}-[0-9]{6}\.json\z') { return $false }
    foreach ($part in $reports, $folder, $full) { if (Test-StickReparsePoint -Path $part) { return $false } }
    return $true
  } catch {
    return $false
  }
}

function Read-ToolNetBackupFile {
  <#
  .SYNOPSIS
    The network backup at -Path, read ONCE (Task 5 review): @{ Sha256 = <64 upper-case hex digits of those bytes>;
    Value = <those same bytes parsed as a JSON object, as hashtables; $null when they are no JSON object> }, or $null
    when the file is missing, empty, over 1 MB or a reparse point, or cannot be read. Never throws.
  .DESCRIPTION
    The hash the window showed and the values Restore applies come from one read of the file, so a file changed in
    between can never be applied with the old hash. UTF-8, with or without a BOM; invalid UTF-8 is no JSON.
  #>
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyString()][string]$Path)

  try {
    if ([string]::IsNullOrEmpty($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    if (Test-StickReparsePoint -Path $Path) { return $null }
    $info = New-Object IO.FileInfo $Path
    if ($info.Length -le 0 -or $info.Length -gt 1MB) { return $null }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -le 0 -or $bytes.Length -gt 1MB) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    $hex = ([BitConverter]::ToString($hash)).Replace('-', '')
    $value = $null
    try {
      $start = 0
      if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
      $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes, $start, $bytes.Length - $start)
      $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop
      if ($parsed -is [System.Management.Automation.PSCustomObject]) { $value = ConvertTo-HashtableDeep -InputObject $parsed }
    } catch {
      $value = $null
    }
    return @{ Sha256 = $hex; Value = $value }
  } catch {
    return $null
  }
}

function Find-ToolNetBackup {
  <#
  .SYNOPSIS
    This PC's newest valid network backup on the stick: @{ Path; Sha256; CreatedAt; Adapters } (the adapters parsed from
    the very bytes that Sha256 covers), or $null. Never throws.
  .DESCRIPTION
    Looks at <StickRoot>BenTech-Reports\*\network-backup-<yyyyMMdd-HHmmss>.json, newest first by the stamp in the name
    (at most 64 files), and answers the first one that Test-ToolNetBackupPath accepts (no link, ASCII path),
    Read-ToolNetBackupFile can read (under 1 MB) and Test-ToolNetBackup accepts for -IdentityKey, and that holds at
    least one static value (Test-ToolNetStatic; review M2). Another PC's file, an invalid one and one with nothing to
    put back are passed over. No stick root, no key, no BenTech-Reports or a BenTech-Reports that is a link:
    $null. A failure is a WARN in the log and $null.
  #>
  [CmdletBinding()]
  param(
    [AllowNull()][AllowEmptyString()][string]$StickRoot,
    [AllowNull()][AllowEmptyString()][string]$IdentityKey
  )

  if ([string]::IsNullOrEmpty($StickRoot) -or [string]::IsNullOrEmpty($IdentityKey)) { return $null }
  try {
    $reports = [IO.Path]::Combine($StickRoot, 'BenTech-Reports')
    if (-not [IO.Directory]::Exists($reports) -or (Test-StickReparsePoint -Path $reports)) { return $null }
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($folder in [IO.Directory]::GetDirectories($reports)) {
      foreach ($file in [IO.Directory]::GetFiles($folder, 'network-backup-*.json')) {
        $name = [IO.Path]::GetFileName($file)
        if ($name -cmatch '^network-backup-([0-9]{8}-[0-9]{6})\.json\z') { $candidates.Add(@{ Path = $file; Stamp = $Matches[1] }) }
      }
    }
    $newest = @($candidates.ToArray() | Sort-Object -Property @{ Expression = { [string]$_['Stamp'] }; Descending = $true }, @{ Expression = { [string]$_['Path'] }; Descending = $true } |
      Select-Object -First 64)
    foreach ($candidate in $newest) {
      $path = [string]$candidate['Path']
      if (-not (Test-ToolNetBackupPath -Path $path -StickRoot $StickRoot)) { continue }
      $read = Read-ToolNetBackupFile -Path $path
      if ($null -eq $read -or $null -eq $read['Value']) { continue }
      $backup = Test-ToolNetBackup -Value $read['Value'] -IdentityKey $IdentityKey
      if ($null -eq $backup) { continue }
      # A backup without any static value has nothing to put back (a second reset on a PC already on DHCP): an older
      # one that has is the one to offer (review M2).
      if (@(foreach ($a in @($backup['Adapters'])) { if (Test-ToolNetStatic -Adapter $a) { $a } }).Count -eq 0) { continue }
      return @{ Path = $path; Sha256 = [string]$read['Sha256']; CreatedAt = [string]$backup['CreatedAt']; Adapters = $backup['Adapters'] }
    }
  } catch {
    Write-SetupLog -Level WARN -Message 'The saved network settings could not be looked for' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  return $null
}

function New-ToolNetApplyCommand {
  <#
  .SYNOPSIS
    The grandchild command that puts one saved adapter's static values back on interface -InterfaceIndex (pure):
    @{ Command (text; '' when there is nothing to apply); Problems = [string[]] (values that cannot be applied) }.
  .DESCRIPTION
    -Adapter is a Test-ToolNetBackup row, so every value is a checked IP address and prefix, written as a literal.
    Per address family that has a static address: Set-NetIPInterface -Dhcp Disabled, only when DHCP was off for that
    family in the backup (a family that was DHCP is never turned static), then New-NetIPAddress for each address, the
    first with -DefaultGateway (the family's first gateway). Then Set-DnsClientServerAddress with every DNS server.
    Each family and the DNS servers run in their own try, so one that fails does not stop the others; the command
    returns @{ Errors = [string[]] }. A gateway of a family without a static address, or a second one, cannot be put
    back this way: a Problem, never applied.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][int]$InterfaceIndex,
    [Parameter(Mandatory)][hashtable]$Adapter
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $problems = New-Object System.Collections.Generic.List[string]
  foreach ($family in 'IPv4', 'IPv6') {
    $v6 = ($family -ceq 'IPv6')
    $addresses = @(foreach ($a in @($Adapter['Addresses'])) { if ($a -is [System.Collections.IDictionary] -and ([string]$a['Ip']).Contains(':') -eq $v6) { $a } })
    $gateways = @(foreach ($g in @($Adapter['Gateways'])) { if ($null -ne $g -and ([string]$g).Contains(':') -eq $v6) { [string]$g } })
    if ($addresses.Count -eq 0) {
      foreach ($g in $gateways) { $problems.Add(('gateway {0} not restored: no static {1} address' -f $g, $family)) }
      continue
    }
    for ($i = 1; $i -lt $gateways.Count; $i++) { $problems.Add(('gateway {0} not restored: only one default gateway per address family' -f $gateways[$i])) }
    $lines.Add('try {')
    $dhcpKey = if ($v6) { 'Ipv6Dhcp' } else { 'Ipv4Dhcp' }
    if ($Adapter[$dhcpKey] -ne $true) { $lines.Add(('  Set-NetIPInterface -InterfaceIndex {0} -AddressFamily {1} -Dhcp Disabled' -f $InterfaceIndex, $family)) }
    for ($i = 0; $i -lt $addresses.Count; $i++) {
      $line = '  $null = New-NetIPAddress -InterfaceIndex {0} -IPAddress {1} -PrefixLength {2}' -f $InterfaceIndex, (ConvertTo-PowerShellLiteral -Text ([string]$addresses[$i]['Ip'])), [int]$addresses[$i]['Prefix']
      if ($i -eq 0 -and $gateways.Count -gt 0) { $line += ' -DefaultGateway ' + (ConvertTo-PowerShellLiteral -Text $gateways[0]) }
      $lines.Add($line)
    }
    $lines.Add(('}} catch {{ $errors.Add(''{0}: '' + [string]$_.Exception.Message) }}' -f $family))
  }
  $dns = @(foreach ($d in @($Adapter['Dns'])) { if ($null -ne $d -and [string]$d -ne '') { ConvertTo-PowerShellLiteral -Text ([string]$d) } })
  if ($dns.Count -gt 0) {
    $lines.Add('try {')
    $lines.Add(('  Set-DnsClientServerAddress -InterfaceIndex {0} -ServerAddresses @({1})' -f $InterfaceIndex, ($dns -join ', ')))
    $lines.Add('} catch { $errors.Add(''DNS: '' + [string]$_.Exception.Message) }')
  }
  if ($lines.Count -eq 0) { return @{ Command = ''; Problems = [string[]]$problems.ToArray() } }
  $all = New-Object System.Collections.Generic.List[string]
  $all.Add('$errors = New-Object System.Collections.Generic.List[string]')
  foreach ($l in $lines) { $all.Add($l) }
  $all.Add('@{ Errors = $errors.ToArray() }')
  return @{ Command = ($all.ToArray() -join "`r`n"); Problems = [string[]]$problems.ToArray() }
}

function Find-ToolNetAdapterMatch {
  # Private. The adapter of -Current (netAdapters rows: @{ Guid; Mac; Index; Alias }) that a saved -Adapter is: the one
  # with its GUID, else the only one with its MAC (a driver reinstall gives a new GUID). $null when none is.
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Adapter, [AllowNull()][object[]]$Current)

  $byMac = New-Object System.Collections.Generic.List[object]
  foreach ($now in @($Current)) {
    if ($now -isnot [System.Collections.IDictionary]) { continue }
    $guid = [guid]::Empty
    if ([guid]::TryParse([string]$now['Guid'], [ref]$guid) -and [string]::Equals($guid.ToString('B'), [string]$Adapter['Guid'], [StringComparison]::OrdinalIgnoreCase)) { return $now }
    if ([string]$Adapter['Mac'] -ne '' -and [string]::Equals(([string]$now['Mac']).Trim(), [string]$Adapter['Mac'], [StringComparison]::OrdinalIgnoreCase)) { $byMac.Add($now) }
  }
  if ($byMac.Count -eq 1) { return $byMac[0] }
  return $null
}

function Invoke-ToolStepNetRestore {
  <#
  .SYNOPSIS
    Step netRestore (spec 6.6, Restore network settings): Options = @{ File; Sha256 } (what the window showed). The file
    must be a network backup under the stick's BenTech-Reports (Test-ToolNetBackupPath; else CRIT netRestoreNotOnStick),
    readable (else CRIT netRestoreUnreadable), and its SHA-256, read once (Read-ToolNetBackupFile), must equal
    Options.Sha256 (else, or an Options.Sha256 that is no SHA-256, CRIT netRestoreRefused; review M8: each names its
    cause). Those same bytes must be a valid backup of this PC (Test-ToolNetBackup): else CRIT netRestoreInvalid.
    Nothing is applied in any of these cases.
  .DESCRIPTION
    Then the adapters with a static value (Test-ToolNetStatic: exactly the ones the confirmation listed; a DHCP-only
    adapter is left alone), each matched to an adapter of now (the grandchild netAdapters; by GUID, else MAC) and
    restored by its own grandchild netApply-<position in the file> (New-ToolNetApplyCommand). An adapter not found, a
    grandchild that fails, an error inside it, or a value that cannot be applied: WARN netRestoreFailed (the alias and
    why). INFO netRestored with the adapters restored in full. No adapter list: CRIT stepFailed. $Run.Data.NetRestore.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $options = $Run.Args['Options']
  $file = ''
  $sha = ''
  if ($options -is [System.Collections.IDictionary]) {
    if ($options['File'] -is [string]) { $file = $options['File'] }
    if ($options['Sha256'] -is [string]) { $sha = $options['Sha256'] }
  }
  $refused = ''
  $code = ''
  $read = $null
  if ($sha -cnotmatch '^[0-9A-Fa-f]{64}\z') {
    $refused = 'the hash it was shown with is no SHA-256'
    $code = 'netRestoreRefused'
  } elseif (-not (Test-ToolNetBackupPath -Path $file -StickRoot ([string]$Run.Args['StickRoot']))) {
    $refused = 'the file is not a network backup under BenTech-Reports on the stick, or a link is on its way'
    $code = 'netRestoreNotOnStick'
  } else {
    $read = Read-ToolNetBackupFile -Path $file
    if ($null -eq $read) {
      $refused = 'the file could not be read'
      $code = 'netRestoreUnreadable'
    } elseif (-not [string]::Equals([string]$read['Sha256'], $sha, [StringComparison]::OrdinalIgnoreCase)) {
      $refused = 'its SHA-256 is not the one shown'
      $code = 'netRestoreRefused'
    }
  }
  if ($refused -ne '') {
    Write-SetupLog -Level WARN -Message 'Network restore refused' -Data @{ reason = $refused; file = (ConvertTo-ScreenText -Text $file) }
    switch ($code) {
      'netRestoreNotOnStick' { Add-ToolFinding -Run $Run -Level CRIT -Code 'netRestoreNotOnStick' }
      'netRestoreUnreadable' { Add-ToolFinding -Run $Run -Level CRIT -Code 'netRestoreUnreadable' }
      default { Add-ToolFinding -Run $Run -Level CRIT -Code 'netRestoreRefused' }
    }
    return 'failed'
  }
  $backup = Test-ToolNetBackup -Value $read['Value'] -IdentityKey ([string](Get-ToolArgsEntry -Run $Run -Section 'Identity' -Name 'Key'))
  if ($null -eq $backup) {
    Write-SetupLog -Level WARN -Message 'Network restore refused: the backup is not valid for this PC' -Data @{ file = (ConvertTo-ScreenText -Text $file) }
    Add-ToolFinding -Run $Run -Level CRIT -Code 'netRestoreInvalid'
    return 'failed'
  }
  $adapters = @($backup['Adapters'])
  $targets = @(for ($i = 0; $i -lt $adapters.Count; $i++) { if (Test-ToolNetStatic -Adapter $adapters[$i]) { $i } })
  $Run.Data['NetRestore'] = @{ File = (ConvertTo-ScreenText -Text $file); Adapters = $targets.Count; Restored = 0 }
  if ($targets.Count -eq 0) {
    Add-ToolLog -Run $Run -Text 'Network restore: no static settings in the backup, nothing to apply'
    Add-ToolFinding -Run $Run -Level INFO -Code 'netRestored' -Arguments @(0)
    return 'done'
  }
  $current = Invoke-ToolJsonChild -Run $Run -Name 'netAdapters' -Command $script:ToolNetAdaptersCommand -StepTimeout 'grandchild'
  if (-not $current.Ok -or -not $current.Data.ContainsKey('Items')) {
    $why = if ($current.Ok) { 'no adapter list in the answer' } else { $current.Error }
    Add-ToolFinding -Run $Run -Level CRIT -Code 'stepFailed' -Arguments @((Get-ToolStepName -Id 'netRestore'), ('the network adapters could not be read ({0})' -f $why))
    if ($current.TimedOut) { return 'timedout' }
    return 'failed'
  }
  $now = @(foreach ($row in @($current.Data['Items'])) { if ($row -is [System.Collections.IDictionary]) { $row } })
  $status = 'done'
  $restored = 0
  foreach ($i in $targets) {
    $adapter = $adapters[$i]
    $alias = [string]$adapter['Alias']
    if ($alias -eq '') { $alias = if ([string]$adapter['Mac'] -ne '') { [string]$adapter['Mac'] } else { [string]$adapter['Guid'] } }
    $match = Find-ToolNetAdapterMatch -Adapter $adapter -Current $now
    if ($null -eq $match) {
      Add-ToolFinding -Run $Run -Level WARN -Code 'netRestoreFailed' -Arguments @($alias, 'adapter not found')
      $status = 'warn'
      continue
    }
    $index = 0
    if (-not [int]::TryParse([string]$match['Index'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$index) -or $index -le 0) {
      Add-ToolFinding -Run $Run -Level WARN -Code 'netRestoreFailed' -Arguments @($alias, 'adapter not found')
      $status = 'warn'
      continue
    }
    $apply = New-ToolNetApplyCommand -InterfaceIndex $index -Adapter $adapter
    $ok = $true
    if ($apply['Command'] -ne '') {
      $result = Invoke-ToolJsonChild -Run $Run -Name ('netApply-{0}' -f ($i + 1)) -Command $apply['Command'] -StepTimeout 'grandchild'
      if (-not $result.Ok) {
        Add-ToolFinding -Run $Run -Level WARN -Code 'netRestoreFailed' -Arguments @($alias, $result.Error)
        $ok = $false
      } else {
        foreach ($e in @($result.Data['Errors'])) {
          if ($null -ne $e -and [string]$e -ne '') {
            Add-ToolFinding -Run $Run -Level WARN -Code 'netRestoreFailed' -Arguments @($alias, [string]$e)
            $ok = $false
          }
        }
      }
    }
    foreach ($problem in $apply['Problems']) {
      Add-ToolFinding -Run $Run -Level WARN -Code 'netRestoreFailed' -Arguments @($alias, $problem)
      $ok = $false
    }
    if ($ok) { $restored++ } else { $status = 'warn' }
  }
  $Run.Data['NetRestore']['Restored'] = $restored
  Add-ToolLog -Run $Run -Text ('Network restore: {0} of {1} adapters restored' -f $restored, $targets.Count)
  Add-ToolFinding -Run $Run -Level INFO -Code 'netRestored' -Arguments @($restored)
  return $status
}

# --- Ghost devices (spec 6.7) --------------------------------------------------------------------------------------

function Get-GhostPrefixReason {
  # Private. Why an InstanceId's enumerator prefix leaves its device out: 'bluetooth', 'audio', 'printer' or 'wsd-ipp'
  # ($script:GhostExcludedPrefixes, any case); '' for none.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$InstanceId)

  foreach ($prefix in $script:GhostExcludedPrefixes) {
    if (-not ([string]$InstanceId).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    switch ($prefix) {
      'SWD\MMDEVAPI\' { return 'audio' }
      'SWD\PRINTENUM\' { return 'printer' }
      'WSDPRINT\' { return 'wsd-ipp' }
      default { return 'bluetooth' }
    }
  }
  return ''
}

function Test-GhostExcluded {
  <#
  .SYNOPSIS
    Why a ghost device is always left out (spec 6.7; pure): '' to keep it, else 'bluetooth', 'audio', 'printer' or
    'wsd-ipp'.
  .DESCRIPTION
    In this order: an enumerator prefix of $script:GhostExcludedPrefixes; a class of $script:GhostExcludedClasses
    (Bluetooth, Printer or PrintQueue, AudioEndpoint); an InstanceId whose first or second segment holds WSD or IPP
    (Plan call: wider than the exact enumerators, which are unknown until the VM test; leaving out more only removes
    less); an ancestor (-Ancestors, nearest first: @{ InstanceId; Class }) that is Bluetooth by its prefix or class.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Device,
    [AllowNull()][AllowEmptyCollection()][hashtable[]]$Ancestors
  )

  $id = [string]$Device['InstanceId']
  $reason = Get-GhostPrefixReason -InstanceId $id
  if ($reason -ne '') { return $reason }
  switch ([string]$Device['Class']) {
    'Bluetooth' { return 'bluetooth' }
    'Printer' { return 'printer' }
    'PrintQueue' { return 'printer' }
    'AudioEndpoint' { return 'audio' }
  }
  $segments = $id.Split('\')
  for ($i = 0; $i -lt [math]::Min(2, $segments.Count); $i++) {
    if ($segments[$i].IndexOf('WSD', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $segments[$i].IndexOf('IPP', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'wsd-ipp' }
  }
  foreach ($ancestor in @($Ancestors)) {
    if ($null -eq $ancestor) { continue }
    $up = [string]$ancestor['InstanceId']
    if ([string]$ancestor['Class'] -eq 'Bluetooth') { return 'bluetooth' }
    foreach ($prefix in $script:GhostBluetoothPrefixes) { if ($up.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return 'bluetooth' } }
  }
  return ''
}

function Get-ToolGhostDevices {
  <#
  .SYNOPSIS
    The non-present devices, read in the grandchild ghostList (toolStep.ghostList): @{ Ok; TimedOut; Error; Total;
    Items = @( @{ InstanceId; Class; Name (as Windows gives it); Excluded = '' | <Test-GhostExcluded reason> } ) }.
    Never throws.
  .DESCRIPTION
    Each ghost's ancestors are walked through the answer's parents (up to 10, a loop stops it); a parent the device list
    does not know is still checked by its InstanceId. The grandchild answers at most $script:GhostQueryMax ghosts;
    Total counts them all.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $command = $script:ToolGhostCommand.Replace('<Max>', [string]$script:GhostQueryMax).Replace('<Levels>', [string]$script:GhostAncestorLevels)
  $child = Invoke-ToolJsonChild -Run $Run -Name 'ghostList' -Command $command -StepTimeout 'ghostList'
  if (-not $child.Ok) { return @{ Ok = $false; TimedOut = [bool]$child.TimedOut; Error = [string]$child.Error; Total = 0; Items = @() } }
  if (-not $child.Data.ContainsKey('Items')) { return @{ Ok = $false; TimedOut = $false; Error = 'no device list in the answer'; Total = 0; Items = @() } }
  $map = @{}
  foreach ($row in @(@($child.Data['Nodes']) + @($child.Data['Items']))) {
    if ($row -isnot [System.Collections.IDictionary]) { continue }
    $id = [string]$row['InstanceId']
    if ($id -ne '') { $map[$id] = @{ Class = [string]$row['Class']; Parent = [string]$row['Parent'] } }
  }
  $devices = New-Object System.Collections.Generic.List[object]
  foreach ($row in @($child.Data['Items'])) {
    if ($row -isnot [System.Collections.IDictionary]) { continue }
    $id = [string]$row['InstanceId']
    if ($id -eq '') { continue }
    $ancestors = New-Object System.Collections.Generic.List[object]
    $seen = @{ $id = $true }
    $up = [string]$row['Parent']
    while ($up -ne '' -and $ancestors.Count -lt $script:GhostAncestorLevels -and -not $seen.ContainsKey($up)) {
      $seen[$up] = $true
      $node = $map[$up]
      $ancestors.Add(@{ InstanceId = $up; Class = $(if ($null -ne $node) { [string]$node['Class'] } else { '' }) })
      $up = if ($null -ne $node) { [string]$node['Parent'] } else { '' }
    }
    $reason = Test-GhostExcluded -Device @{ InstanceId = $id; Class = [string]$row['Class'] } -Ancestors $ancestors.ToArray()
    $devices.Add(@{ InstanceId = $id; Class = [string]$row['Class']; Name = [string]$row['Name']; Excluded = $reason })
  }
  $total = 0
  $null = [int]::TryParse([string]$child.Data['Total'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$total)
  return @{ Ok = $true; TimedOut = $false; Error = ''; Total = [math]::Max($total, $devices.Count); Items = $devices.ToArray() }
}

function Measure-ToolJsonText {
  # Private. An upper bound of the bytes -Text takes inside a string of an ASCII JSON file (ConvertTo-Json, then
  # ConvertTo-ToolAsciiJson): six for a character outside printable ASCII and for one ConvertTo-Json writes as \u00XX
  # (& ' < >), two for " and \, one for the rest. Pure.
  [CmdletBinding()]
  [OutputType([int])]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return 0 }
  return ($Text.Length + 5 * [regex]::Matches($Text, "[^\x20-\x7E]|[&'<>]").Count + [regex]::Matches($Text, '["\\]').Count)
}

function Invoke-ToolStepGhostList {
  <#
  .SYNOPSIS
    Step ghostList (the info child the Ghost devices confirmation waits for): $Run.Data.Ghosts = @( @{ InstanceId;
    Class; Name; Excluded } ) (Excluded '' for a device that may be removed, else the reason), the ones that may be
    removed first. No ghost is an empty list. $Run.Data.GhostCount = @{ Total; Listed; LeftOut }.
  .DESCRIPTION
    InstanceId and Excluded are ASCII; Name and Class keep their real text (ConvertTo-ToolDisplayText, RD-R21), cut to
    $script:GhostNameMax and $script:GhostClassMax UTF-16 code units BEFORE their \u escapes. The list holds at most
    $script:GhostListMax rows, and only as many as fit $script:GhostListBudgetBytes counted with Measure-ToolJsonText
    (review M4), so result.json stays under the 1 MB the window reads whatever the names; when the PC has more, INFO
    ghostListCapped says so. A list that cannot be read: CRIT stepFailed and no Ghosts (the window shows the failure).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $list = Get-ToolGhostDevices -Run $Run
  if (-not $list['Ok']) {
    Add-ToolFinding -Run $Run -Level CRIT -Code 'stepFailed' -Arguments @((Get-ToolStepName -Id 'ghostList'), ('the device list could not be read ({0})' -f $list['Error']))
    if ($list['TimedOut']) { return 'timedout' }
    return 'failed'
  }
  $keep = New-Object System.Collections.Generic.List[object]
  $leftOut = New-Object System.Collections.Generic.List[object]
  foreach ($device in $list['Items']) { if ([string]$device['Excluded'] -eq '') { $keep.Add($device) } else { $leftOut.Add($device) } }
  $rows = New-Object System.Collections.Generic.List[object]
  $bytes = 0
  foreach ($device in @($keep.ToArray() + $leftOut.ToArray())) {
    if ($rows.Count -ge $script:GhostListMax) { break }
    $row = @{ InstanceId = (ConvertTo-ScreenText -Text $device['InstanceId']); Class = (ConvertTo-ToolDisplayText -Text $device['Class'] -MaxLength $script:GhostClassMax)
              Name = (ConvertTo-ToolDisplayText -Text $device['Name'] -MaxLength $script:GhostNameMax); Excluded = [string]$device['Excluded'] }
    $size = $script:GhostRowOverheadBytes + (Measure-ToolJsonText -Text $row['InstanceId']) + (Measure-ToolJsonText -Text $row['Class']) +
      (Measure-ToolJsonText -Text $row['Name']) + (Measure-ToolJsonText -Text $row['Excluded'])
    if ($bytes + $size -gt $script:GhostListBudgetBytes) { break }
    $bytes += $size
    $rows.Add($row)
  }
  $Run.Data['Ghosts'] = $rows.ToArray()
  $Run.Data['GhostCount'] = @{ Total = $list['Total']; Listed = $rows.Count; LeftOut = $leftOut.Count }
  Add-ToolLog -Run $Run -Text ('Old devices: {0} found, {1} left out, {2} listed' -f $list['Total'], $leftOut.Count, $rows.Count)
  if ($list['Total'] -gt $rows.Count) { Add-ToolFinding -Run $Run -Level INFO -Code 'ghostListCapped' -Arguments @($rows.Count, $list['Total']) }
  return 'done'
}

function Test-ToolDeviceId {
  # Private. $true when -Id has the shape of a device instance id that can be quoted on pnputil's command line:
  # printable ASCII without a space, at most 512 characters, no double quote, not ending in a backslash (which would
  # escape the closing quote).
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()][AllowEmptyString()][string]$Id)

  return ($Id -cmatch '^[\x21-\x7E]{1,512}\z' -and -not $Id.Contains('"') -and -not $Id.EndsWith('\'))
}

function Get-ToolGhostTicks {
  # Private. The ticked devices of Options.Ids, in order, each once (any case): @( @{ Id; Valid } ) (Valid:
  # Test-ToolDeviceId). Ids that are no list of text give none.
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Run)

  $raw = $null
  $options = $Run.Args['Options']
  if ($options -is [System.Collections.IDictionary]) { $raw = $options['Ids'] }
  $items = @()
  if ($raw -is [string]) {
    $items = @($raw)
  } elseif ($null -ne $raw -and $raw -isnot [System.Collections.IDictionary] -and $raw -isnot [System.Management.Automation.PSCustomObject] -and $raw -is [System.Collections.IEnumerable]) {
    $items = @(foreach ($item in $raw) { $item })
  }
  $seen = @{}
  $ticks = New-Object System.Collections.Generic.List[object]
  foreach ($item in $items) {
    if ($item -isnot [string] -or $seen.ContainsKey($item)) { continue }
    $seen[$item] = $true
    $ticks.Add(@{ Id = $item; Valid = (Test-ToolDeviceId -Id $item) })
  }
  return , $ticks.ToArray()
}

function ConvertTo-ToolCsvText {
  # Private. A CSV cell that Excel would run as a formula (it starts with = + - or @) gets a leading apostrophe, so it
  # shows as text (review M9: a USB device chooses its own name). Control characters are already spaces. Pure.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  $value = [string]$Text
  if ($value -match '^[=+\-@]') { return "'" + $value }
  return $value
}

function Invoke-ToolStepGhostCsv {
  <#
  .SYNOPSIS
    Step ghostCsv (spec 6.7.4), before anything is removed: the devices listed again (Get-ToolGhostDevices) go to
    <session>\ghost-devices-<yyyyMMdd-HHmmss>.csv with a Status column ('remove': ticked and not left out; 'kept';
    'excluded (<reason>)'), through ConvertTo-Csv -NoTypeInformation, written UTF-8 WITH a BOM (Excel then shows Hebrew
    names; the old kit's ASCII CSV turned them into '?'), then read back: the text must be the same and hold one line
    per device plus the header. $Run.Files.GhostCsv.
  .DESCRIPTION
    No saved list, nothing removed (Review Focus 3): a session folder that is not the stick's (Data.SessionIsLocal), a
    list that cannot be read, a link or a file already there, or any failure: CRIT ghostCsvFailed and 'failed'.
    $Run.Data.Abort is set before anything else and cleared only on success, so ghostRemove never runs after a failure,
    nor after a step that throws. The names keep their real text here (a stick file, like the reports); a control
    character becomes a space, so every device is one line, and a name or class that starts with = + - or @ gets a
    leading apostrophe, so Excel shows it as text instead of running it (review M9).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  # Abort first, cleared only at the very end: a step that throws (Invoke-ToolStep catches it) still removes nothing.
  $Run.Data['Abort'] = $true
  $problem = ''
  $path = ''
  $list = $null
  if ($Run.Data['SessionIsLocal'] -ne $false -or [string]::IsNullOrEmpty([string]$Run.SessionDir)) { $problem = 'the session folder is not on the stick' }
  if ($problem -eq '') {
    $list = Get-ToolGhostDevices -Run $Run
    if (-not $list['Ok']) { $problem = 'the device list could not be read ({0})' -f $list['Error'] }
  }
  $counts = @{ Devices = 0; Remove = 0; Kept = 0; Excluded = 0 }
  if ($problem -eq '') {
    try {
      $ticked = @{}
      foreach ($tick in (Get-ToolGhostTicks -Run $Run)) { if ($tick['Valid']) { $ticked[[string]$tick['Id']] = $true } }
      $rows = New-Object System.Collections.Generic.List[object]
      foreach ($device in $list['Items']) {
        $reason = [string]$device['Excluded']
        if ($reason -ne '') { $rowStatus = 'excluded ({0})' -f $reason; $counts['Excluded']++ }
        elseif ($ticked.ContainsKey([string]$device['InstanceId'])) { $rowStatus = 'remove'; $counts['Remove']++ }
        else { $rowStatus = 'kept'; $counts['Kept']++ }
        $rows.Add([pscustomobject][ordered]@{ Status = $rowStatus; InstanceId = [string]$device['InstanceId']
                                               Class = (ConvertTo-ToolCsvText -Text ([regex]::Replace([string]$device['Class'], '[\x00-\x1F]', ' ')))
                                               Name = (ConvertTo-ToolCsvText -Text ([regex]::Replace([string]$device['Name'], '[\x00-\x1F]', ' '))) })
      }
      $counts['Devices'] = $rows.Count
      $lines = if ($rows.Count -gt 0) { @($rows.ToArray() | ConvertTo-Csv -NoTypeInformation) } else { @('"Status","InstanceId","Class","Name"') }
      $text = ($lines -join "`r`n") + "`r`n"
      $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
      $path = [IO.Path]::Combine([string]$Run.SessionDir, ('ghost-devices-{0}.csv' -f $stamp))
      if (Test-StickReparsePoint -Path ([string]$Run.SessionDir)) {
        $problem = 'the session folder is a link'
      } elseif ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        $problem = 'the file already exists'
      } else {
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $true))
        $back = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding $true))
        $count = @($back -split "`r`n" | Where-Object { $_ -ne '' }).Count
        if ($back -cne $text -or $count -ne $rows.Count + 1) { $problem = 'the saved list does not read back the same' }
      }
    } catch {
      $problem = ConvertTo-ScreenText -Text $_.Exception.Message
    }
  }
  if ($problem -ne '') {
    Write-SetupLog -Level WARN -Message 'The device list was not saved; nothing is removed' -Data @{ reason = (ConvertTo-ScreenText -Text $problem); path = (ConvertTo-ScreenText -Text $path) }
    Add-ToolFinding -Run $Run -Level CRIT -Code 'ghostCsvFailed'
    return 'failed'
  }
  $Run.Files['GhostCsv'] = $path
  $Run.Data['GhostCsv'] = $counts
  Add-ToolLog -Run $Run -Text ('Device list saved: {0} devices, {1} to remove, {2} kept, {3} left out' -f $counts['Devices'], $counts['Remove'], $counts['Kept'], $counts['Excluded'])
  $Run.Data.Remove('Abort')
  return 'done'
}

function Invoke-ToolStepGhostRemove {
  <#
  .SYNOPSIS
    Step ghostRemove (spec 6.7.5): the devices are listed again (Get-ToolGhostDevices), and of the ticked Options.Ids
    only those that are still non-present and not left out are removed: pnputil.exe /remove-device "<id>"
    (toolStep.pnputil). Exit 0 or 3010 is removed (3010 also RestartRequired); another exit or a timeout is WARN
    ghostRemoveFailed (the id, why). INFO ghostsRemoved with the count.
  .DESCRIPTION
    An id that is not a device id (Test-ToolDeviceId: one holding a double quote among them) is never passed on: WARN
    ghostRemoveFailed. A ticked id that is present again, left out or gone is skipped (logged). Less than a minute left
    of the action's time: the rest are not started (WARN ghostRemoveFailed with how many). A list that cannot be read
    again: CRIT stepFailed, nothing removed. When the PC has more ghosts than the window lists, INFO ghostListCapped.
    $Run.Data.GhostRemove = @{ Ticked; Removed; Skipped }.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $ticks = Get-ToolGhostTicks -Run $Run
  $status = 'done'
  $removed = 0
  $skipped = 0
  if ($ticks.Count -gt 0) {
    $list = Get-ToolGhostDevices -Run $Run
    if (-not $list['Ok']) {
      Add-ToolFinding -Run $Run -Level CRIT -Code 'stepFailed' -Arguments @((Get-ToolStepName -Id 'ghostRemove'), ('the device list could not be read again ({0})' -f $list['Error']))
      if ($list['TimedOut']) { return 'timedout' }
      return 'failed'
    }
    $eligible = @{}
    foreach ($device in $list['Items']) { if ([string]$device['Excluded'] -eq '') { $eligible[[string]$device['InstanceId']] = $true } }
    for ($n = 0; $n -lt $ticks.Count; $n++) {
      $id = [string]$ticks[$n]['Id']
      if (-not $ticks[$n]['Valid']) {
        Write-SetupLog -Level WARN -Message 'A ticked device id is not a device id; it was not passed on' -Data @{ id = (ConvertTo-ScreenText -Text $id) }
        Add-ToolFinding -Run $Run -Level WARN -Code 'ghostRemoveFailed' -Arguments @($id, 'not a device id')
        $status = 'warn'
        continue
      }
      if (-not $eligible.ContainsKey($id)) {
        $skipped++
        Add-ToolLog -Run $Run -Text ('Not removed (present again, left out or gone): {0}' -f $id)
        continue
      }
      if ((Get-ToolRemainingSeconds -Run $Run) -le 60) {
        Add-ToolFinding -Run $Run -Level WARN -Code 'ghostRemoveFailed' -Arguments @(('{0} more devices' -f ($ticks.Count - $n)), 'the action ran out of time')
        $status = 'warn'
        break
      }
      $native = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'pnputil.exe') -ArgumentList ('/remove-device "{0}"' -f $id) -StepTimeout 'pnputil'
      if ($native.TimedOut) {
        Add-ToolFinding -Run $Run -Level WARN -Code 'ghostRemoveFailed' -Arguments @($id, 'timed out')
        $status = 'warn'
      } elseif ($native.ExitCode -eq 0 -or $native.ExitCode -eq 3010) {
        $removed++
        if ($native.ExitCode -eq 3010) { $Run.RestartRequired = $true }
        Add-ToolLog -Run $Run -Text ('Removed: {0}' -f $id)
      } else {
        Add-ToolFinding -Run $Run -Level WARN -Code 'ghostRemoveFailed' -Arguments @($id, (Format-ToolExitCode -ExitCode $native.ExitCode))
        $status = 'warn'
      }
    }
    if ($list['Total'] -gt $script:GhostListMax) { Add-ToolFinding -Run $Run -Level INFO -Code 'ghostListCapped' -Arguments @($script:GhostListMax, $list['Total']) }
  }
  $Run.Data['GhostRemove'] = @{ Ticked = $ticks.Count; Removed = $removed; Skipped = $skipped }
  Add-ToolFinding -Run $Run -Level INFO -Code 'ghostsRemoved' -Arguments @($removed)
  return $status
}
