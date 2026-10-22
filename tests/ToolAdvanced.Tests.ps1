# tests/ToolAdvanced.Tests.ps1
# Repair & diagnostics Task 7 (repair spec 6.4 to 6.7; rulings RD-R1, RD-R2): Windows Update reset, Disk check at
# restart, Network reset with its backup and restore, and Ghost devices (src\Repair\ToolAdvanced.ps1, the step
# safetyNetBackup in ToolSafety.ps1 and their catalog rows), end to end on the child side.
#
# SAFETY: this runs on Ben's real PC. For real, these steps stop and start the Windows Update services (sc.exe), rename
# SoftwareDistribution and catroot2, remove BITS jobs, mark the system volume dirty (fsutil.exe), reset Winsock and
# TCP/IP (netsh.exe), clear the DNS cache (ipconfig.exe), change adapters' IP settings, remove devices (pnputil.exe),
# and read this PC's services, adapters, devices, volumes and remote session. Here nothing is started, nothing is
# changed and no answer comes from this PC:
#   - Invoke-ToolNative answers from $script:exit (by file name, 0 by default; $null is a timeout) and records the file
#     name in $script:native and '<file name> <args>' in $script:nativeLines; sc.exe stop/start that succeeds changes
#     $script:services as the real service would; Invoke-ToolJsonChild answers from $script:gc (by grandchild name;
#     $script:gcFail makes one fail or time out) and records each command in $script:gcCommands; Invoke-External and
#     Invoke-PowerShellChild are never reached (their mocks record the call in $script:blocked and throw);
#     Wait-SetupDelay does not sleep;
#   - Get-Service answers $script:services; Rename-Item records @{ LiteralPath; NewName } in $script:renamed and fails
#     (Write-Error) unless $script:renameOk; Get-ToolWuFolders names two folders under $TestDrive; Get-CimInstance
#     answers Win32_Volume with DirtyBitSet = $script:dirty; Get-RebootRegistryValue answers BootExecute from
#     $script:bootExecute; Test-ToolRemoteSession answers Rdp = $script:rdp (its own test runs the real code with a
#     seam); Get-ServicingRebootSignals answers no signal;
#   - Invoke-ToolStep runs $script:onStep (with the step id) before each step, then the real step (the fake step
#     wrapper); Write-ToolJsonFile and Read-ToolJsonFile run the real code unless New-ActionRun -Break says the write
#     fails or the read-back differs;
#   - safety nets as in ToolEngine.Tests: Start-BackgroundExternal, Stop-ProcessTree, Start-Process, Restart-Computer,
#     Stop-Service, Start-Service, Remove-BitsTransfer, Set-NetIPInterface, New-NetIPAddress, Set-DnsClientServerAddress,
#     Get-NetAdapter, Get-PnpDevice, Optimize-Volume, Repair-Volume, Repair-WindowsImage, Set-ItemProperty,
#     New-ItemProperty and Remove-ItemProperty record their name in $script:blocked, then throw; AfterEach asserts that
#     nothing was blocked. The commands the grandchildren would run are only text here;
#   - every file a test writes is under $TestDrive: the run folders under $TestDrive\Root\Tool, the "stick"
#     $TestDrive\Stick (its BenTech-Reports, the session folder and an earlier visit's backup) and the two "Windows"
#     folders under $TestDrive\Windows.
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Common\Config', 'State\State', 'Steps\Winget', 'Engine\Reboot',
                 'UI\StartScreen', 'Toolbox\Strings', 'Entry\Cleanup', 'Detect\Detection', 'Detect\PcName', 'Report\Report', 'Repair\ToolEngine',
                 'Repair\ToolChecks', 'Repair\ToolSafety', 'Repair\ToolRepairs', 'Repair\ToolAdvanced') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:root = Join-Path $TestDrive 'Root'
  $script:stickRoot = (Join-Path $TestDrive 'Stick') + '\'
  $script:reports = Join-Path $TestDrive 'Stick\BenTech-Reports'
  $script:sessionDir = Join-Path $script:reports 'PC1_7HX2K93_2026-10-22_1015'
  $script:advancedFile = "$PSScriptRoot\..\src\Repair\ToolAdvanced.ps1"
  $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
  # The real code of the wrapped functions (Pester 6 never falls through to the original).
  $script:realInvokeStep = ${function:Invoke-ToolStep}
  $script:realWriteJson = ${function:Write-ToolJsonFile}
  $script:realReadJson = ${function:Read-ToolJsonFile}
  $script:realRemote = ${function:Test-ToolRemoteSession}

  # The args the window writes for -Action on a Dell laptop, the stick $TestDrive\Stick\, every chip ok.
  function New-TestArgs {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$RunId, [hashtable]$Options = @{})
    @{ Version = 1; Action = $Action; RunId = $RunId
       DeadlineUtc = [datetime]::UtcNow.AddMinutes(600).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
       BudgetSeconds = 36000; SessionDir = $script:sessionDir; StickRoot = $script:stickRoot; Complaint = ''; Done = @()
       Identity = @{ Key = 'SN-7HX2K93'; FolderPart = '7HX2K93'; Serial = '7HX2K93'; BiosUuid = ''; ComputerName = 'PC1'
                     Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; Brand = 'DELL' }
       Machine = @{ IsLaptop = $true; OsBuild = 26200; Arch = 'x64' }
       Strip = @{ Restart = 'ok'; Free = 'ok'; BitLocker = 'ok'; Internet = 'ok'; Disk = 'ok' }
       Options = $Options }
  }

  # A run of the catalog action -Action in a fresh run folder, with its session folder made on the fake stick (a
  # fresh one) unless the action logs locally. -Break: 'the write fails' (Write-ToolJsonFile answers $false), 'the
  # read-back differs' (Read-ToolJsonFile answers another object), 'no stick: the local fallback folder'
  # (Data.SessionIsLocal = $true).
  function New-ActionRun {
    param([Parameter(Mandatory)][string]$Action, [hashtable]$Options = @{}, [string]$Break = '')
    $runId = '20261022-101500-' + $Action
    $dir = Join-Path $script:root "Tool\$runId"
    if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    [void][IO.Directory]::CreateDirectory($dir)
    if ([IO.Directory]::Exists($script:sessionDir)) { [IO.Directory]::Delete($script:sessionDir, $true) }
    $script:break = $Break
    $run = New-ToolRun -ToolArgs (New-TestArgs -Action $Action -RunId $runId -Options $Options) -Config $script:cfg -Root $script:root
    if ($script:ToolActionCatalog[$Action]['LogLocal'] -ne $true) { $null = New-ToolSessionDir -Run $run }
    if ($Break -eq 'no stick: the local fallback folder') { $run.Data['SessionIsLocal'] = $true }
    $script:currentRun = $run
    $run
  }

  # The mocked Invoke-ToolJsonChild's answer: the data goes through JSON and back, as the real grandchild's file does.
  function Get-TestChildAnswer {
    param([string]$Name)
    if ($script:gcFail.ContainsKey($Name)) {
      $e = [string]$script:gcFail[$Name]
      return @{ Ok = $false; TimedOut = ($e -eq 'timed out'); Data = $null; Error = $e }
    }
    if (-not $script:gc.ContainsKey($Name)) { return @{ Ok = $false; TimedOut = $false; Data = $null; Error = "no answer for $Name" } }
    $json = ConvertTo-Json -InputObject $script:gc[$Name] -Depth 8 -Compress
    @{ Ok = $true; TimedOut = $false; Data = (ConvertTo-HashtableDeep -InputObject (ConvertFrom-Json -InputObject $json)); Error = $null }
  }

  # The ghost list the grandchild ghostList answers: an old USB stick and its disk (ghosts that may go), a Bluetooth
  # headset with a Hebrew name (left out by its enumerator), the HID keyboard of a Bluetooth keyboard (left out by its
  # parent) and a mouse collection two levels under a Bluetooth LE device (left out by its grandparent).
  function Get-GhostAnswer {
    @{ Total = 5
       Items = @(
         @{ InstanceId = 'USB\VID_0781&PID_5567\4C53'; Class = 'USB'; Name = 'SanDisk Cruzer'; Parent = 'USB\ROOT_HUB30\4&1' }
         @{ InstanceId = 'BTHENUM\{0000110b}_X\7&1'; Class = 'Bluetooth'; Name = 'אוזניות של דנה'; Parent = 'BTH\MS_BTHBRB\6&1' }
         @{ InstanceId = 'USBSTOR\DISK&VEN_SANDISK\4C53&0'; Class = 'DiskDrive'; Name = 'SanDisk Cruzer USB Device'; Parent = 'USB\VID_0781&PID_5567\4C53' }
         @{ InstanceId = 'HID\{00001124}_VID&0002046D\8&1'; Class = 'HIDClass'; Name = 'Bluetooth keyboard'; Parent = 'BTHENUM\{00001124}_VID&0002046D\7&2' }
         @{ InstanceId = 'HID\VID_046D&PID_B023&COL01\9&1'; Class = 'Mouse'; Name = 'HID-compliant mouse'; Parent = 'HID\VID_046D&PID_B023\8&2' })
       Nodes = @(
         @{ InstanceId = 'USB\ROOT_HUB30\4&1'; Class = 'USB'; Parent = 'PCI\VEN_8086&DEV_A36D\3&1' }
         @{ InstanceId = 'PCI\VEN_8086&DEV_A36D\3&1'; Class = 'USB'; Parent = '' }
         @{ InstanceId = 'BTH\MS_BTHBRB\6&1'; Class = 'Bluetooth'; Parent = '' }
         @{ InstanceId = 'BTHENUM\{00001124}_VID&0002046D\7&2'; Class = 'HIDClass'; Parent = 'BTH\MS_BTHBRB\6&1' }
         @{ InstanceId = 'HID\VID_046D&PID_B023\8&2'; Class = 'HIDClass'; Parent = 'XYZ\{00001812}_DEV\7&3' }
         @{ InstanceId = 'XYZ\{00001812}_DEV\7&3'; Class = 'Bluetooth'; Parent = '' }) }
  }

  # What every grandchild answers by default (the Data of Invoke-ToolJsonChild, by grandchild name).
  function Get-DefaultAnswers {
    @{
      netSettings = @{ Items = @(
          @{ Alias = 'Ethernet'; Guid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-56'; Index = 12; Ipv4Dhcp = $false; Ipv6Dhcp = $true
             Addresses = @(@{ Ip = '192.168.1.10'; Prefix = 24 }); Gateways = @('192.168.1.1', '0.0.0.0'); Dns = @('8.8.8.8', '8.8.4.4') }
          @{ Alias = 'Wi-Fi'; Guid = '{5D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-57'; Index = 7; Ipv4Dhcp = $true; Ipv6Dhcp = $true
             Addresses = @(); Gateways = @(); Dns = @() }
          @{ Alias = 'vEthernet (מתג)'; Guid = '{7D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = ''; Index = 30; Ipv4Dhcp = $true; Ipv6Dhcp = $true
             Addresses = @(@{ Ip = 'fe80::1%30'; Prefix = 64 }); Gateways = @(); Dns = @('fec0:0:0:ffff::1') }) }
      # The adapters now: Ethernet by its GUID; Wi-Fi with a new GUID (a driver reinstall), found by its MAC; Ethernet 2
      # (DHCP in the backup) is never touched.
      netAdapters = @{ Items = @(
          @{ Alias = 'Ethernet'; Guid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-56'; Index = 12 }
          @{ Alias = 'Wi-Fi'; Guid = '{9D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-57'; Index = 7 }
          @{ Alias = 'Ethernet 2'; Guid = '{6D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-58'; Index = 9 }) }
      'netApply-1' = @{ Errors = @() }
      'netApply-2' = @{ Errors = @() }
      wuBits = @{ Removed = 2; Failed = 0; Errors = @() }
      wuScan = @{ ResultCode = 2; Count = 0 }
      ghostList = (Get-GhostAnswer)
    }
  }

  # Every Windows Update service Running and Automatic, except msiserver Stopped and Manual.
  function Get-DefaultServices {
    $s = @{}
    foreach ($n in 'wuauserv', 'bits', 'cryptsvc', 'usosvc', 'dosvc') { $s[$n] = @{ Status = 'Running'; StartType = 'Automatic' } }
    $s['msiserver'] = @{ Status = 'Stopped'; StartType = 'Manual' }
    $s
  }

  # A deep copy of -Object (a parsed backup) with the value at -Path ('Adapters[0].Addresses[0].Ip') set to -Value.
  function Set-JsonValue {
    param($Object, [string]$Path, $Value)
    $copy = ConvertTo-HashtableDeep -InputObject (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Object -Depth 10))
    $parts = $Path -split '\.'
    $node = $copy
    for ($i = 0; $i -lt $parts.Count; $i++) {
      $m = [regex]::Match($parts[$i], '^(\w+)(?:\[(\d+)\])?$')
      $name = $m.Groups[1].Value
      $last = ($i -eq $parts.Count - 1)
      if ($m.Groups[2].Success) {
        if ($last) { $node[$name][[int]$m.Groups[2].Value] = $Value } else { $node = $node[$name][[int]$m.Groups[2].Value] }
      } else {
        if ($last) { $node[$name] = $Value } else { $node = $node[$name] }
      }
    }
    $copy
  }

  # A copy of the valid backup with -Count adapters, each with its own GUID and MAC.
  function New-ManyAdapters {
    param([int]$Count)
    $copy = Set-JsonValue $script:validObject 'Version' 1
    $copy['Adapters'] = @(for ($i = 0; $i -lt $Count; $i++) {
        $a = (Set-JsonValue $script:validObject 'Version' 1)['Adapters'][0]
        $a['Guid'] = '{' + ('4D36E972-E325-11CE-BFC1-0800{0:X8}' -f $i) + '}'
        $a['Mac'] = 'A4-BB-6D-12-34-{0:X2}' -f $i
        $a })
    $copy
  }

  function Get-FindingCodes { param($Run) @(foreach ($f in $Run.Findings) { [string]$f.Code }) }
  # The Args of every finding -Code, one string[] each, in order (index it: (Get-FindingArgs $r 'x')[0]).
  function Get-FindingArgs {
    param($Run, [string]$Code)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Run.Findings) { if ($f.Code -eq $Code) { $out.Add([string[]]@($f.Args)) } }
    , $out.ToArray()
  }
  function Get-StepStatus { param($Run, [string]$Id) foreach ($s in $Run.Steps) { if ($s.Id -eq $Id) { return $s.Status } } }
}

Describe 'ToolAdvanced (repair Task 7)' {
  BeforeEach {
    $script:blocked = New-Object System.Collections.ArrayList
    $script:native = New-Object System.Collections.ArrayList
    $script:nativeLines = New-Object System.Collections.ArrayList
    $script:renamed = New-Object System.Collections.ArrayList
    $script:exit = @{}; $script:exitQueue = @{}
    $script:gc = Get-DefaultAnswers; $script:gcFail = @{}; $script:gcCommands = @{}
    $script:services = Get-DefaultServices
    $script:renameOk = $true; $script:renameError = 'locked'; $script:scStops = $true
    $script:dirty = $true; $script:bootExecute = @('autocheck autochk *')
    $script:rdp = $false; $script:onStep = $null; $script:break = ''; $script:currentRun = $null
    $script:remaining = $null

    # The two update folders, as real folders under $TestDrive (Rename-Item itself is a recorder).
    $script:wuRoot = Join-Path $TestDrive 'Windows'
    $script:softwareDistribution = Join-Path $script:wuRoot 'SoftwareDistribution'
    $script:catroot2 = Join-Path $script:wuRoot 'System32\catroot2'
    foreach ($d in $script:softwareDistribution, $script:catroot2) { [void][IO.Directory]::CreateDirectory($d) }

    # The backups an earlier visit left on the stick: a valid one and a bad one, in their own visit folder.
    $script:earlier = Join-Path $script:reports 'PC1_7HX2K93_2026-10-20_0900'
    if ([IO.Directory]::Exists($script:earlier)) { [IO.Directory]::Delete($script:earlier, $true) }
    [void][IO.Directory]::CreateDirectory($script:earlier)
    $script:valid = Join-Path $script:earlier 'network-backup-20261020-090500.json'
    $script:bad = Join-Path $script:earlier 'network-backup-20261020-090400.json'
    [IO.File]::Copy((Join-Path $script:fixtures 'netsaved-valid.json'), $script:valid, $true)
    [IO.File]::Copy((Join-Path $script:fixtures 'netsaved-bad.json'), $script:bad, $true)
    $script:validObject = ConvertTo-HashtableDeep -InputObject (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:valid)))

    Mock Invoke-ToolNative {
      $file = [IO.Path]::GetFileName($FilePath)
      [void]$script:native.Add($file); [void]$script:nativeLines.Add(('{0} {1}' -f $file, $ArgumentList).Trim())
      $code = 0
      if ($script:exit.ContainsKey($file)) { $code = $script:exit[$file] }
      $line = ('{0} {1}' -f $file, $ArgumentList).Trim()
      if ($script:exitQueue.ContainsKey($line) -and $script:exitQueue[$line].Count -gt 0) { $code = $script:exitQueue[$line].Dequeue() }
      if ($file -eq 'sc.exe' -and $null -ne $code) {
        $verb, $service = ([string]$ArgumentList) -split ' ', 2
        if ($script:services.ContainsKey($service)) {
          if ($verb -eq 'stop' -and $script:scStops -and ($code -eq 0 -or $code -eq 1062)) { $script:services[$service]['Status'] = 'Stopped' }
          if ($verb -eq 'start' -and ($code -eq 0 -or $code -eq 1056)) { $script:services[$service]['Status'] = 'Running' }
        }
      }
      @{ ExitCode = $code; TimedOut = ($null -eq $code); OutputPath = $null }
    }
    Mock Invoke-ToolJsonChild { $script:gcCommands[$Name] = $Command; Get-TestChildAnswer -Name $Name }
    Mock Get-Service {
      $s = $script:services[[string]$Name]
      if ($null -eq $s) { Write-Error -Message "Cannot find any service with service name '$Name'." -ErrorId 'NoServiceFoundForGivenName' -Category ObjectNotFound; return }
      [pscustomobject]@{ Name = [string]$Name; Status = $s.Status; StartType = $s.StartType }
    }
    Mock Get-ToolWuFolders { @(@{ Name = 'SoftwareDistribution'; Path = $script:softwareDistribution }, @{ Name = 'catroot2'; Path = $script:catroot2 }) }
    Mock Rename-Item {
      [void]$script:renamed.Add([pscustomobject]@{ LiteralPath = [string]$LiteralPath; NewName = [string]$NewName })
      if (-not $script:renameOk) {
        # As the FileSystem provider fails: a sharing violation (0x80070020), or access denied (0x80070005).
        $e = if ($script:renameError -eq 'locked') { New-Object IO.IOException('The process cannot access the file because it is being used by another process.', -2147024864) }
             else { New-Object UnauthorizedAccessException('Access to the path is denied.') }
        Write-Error -Exception $e -Category WriteError
      }
    }
    Mock Get-CimInstance {
      if ($ClassName -eq 'Win32_Volume') { return [pscustomobject]@{ DriveLetter = 'C:'; DirtyBitSet = $script:dirty } }
      [void]$script:blocked.Add('Get-CimInstance'); throw 'not mocked: Get-CimInstance'
    }
    Mock Get-RebootRegistryValue { if ($Name -eq 'BootExecute') { return $script:bootExecute }; $null }
    Mock Test-ToolRemoteSession { @{ Rdp = $script:rdp } }
    Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $false; ComputerRenamePending = $false } }
    Mock Test-ToolInternet { @{ Tcp = $true; Https = $true; Probe = 'ok'; ClockOffsetSeconds = 1.0; Chip = @{ Level = 'ok'; Args = @(); Detail = @{} } } }
    Mock Wait-SetupDelay { }
    # The fake step wrapper: $script:onStep sees each step's id before it runs.
    Mock Invoke-ToolStep {
      if ($null -ne $script:onStep) { $null = & $script:onStep ([string]$Run.Steps[$Index]['Id']) }
      & $script:realInvokeStep -Run $Run -Index $Index
    }
    Mock Write-ToolJsonFile {
      if ($script:break -eq 'the write fails') { return $false }
      if ($PSBoundParameters.ContainsKey('Depth')) { & $script:realWriteJson -Path $Path -InputObject $InputObject -Depth $Depth } else { & $script:realWriteJson -Path $Path -InputObject $InputObject }
    }
    Mock Read-ToolJsonFile {
      if ($script:break -eq 'the read-back differs') { return @{ Version = 1; CreatedAt = 'x'; Identity = @{ Key = 'SN-7HX2K93'; ComputerName = 'PC1' }; Adapters = @() } }
      if ($PSBoundParameters.ContainsKey('MaxBytes')) { & $script:realReadJson -Path $Path -MaxBytes $MaxBytes } else { & $script:realReadJson -Path $Path }
    }
    # Never reached: the runners above them are mocked.
    Mock Invoke-External { [void]$script:blocked.Add('Invoke-External'); throw 'blocked by the test: Invoke-External' }
    Mock Invoke-PowerShellChild { [void]$script:blocked.Add('Invoke-PowerShellChild'); throw 'blocked by the test: Invoke-PowerShellChild' }
    # Safety nets.
    Mock Start-BackgroundExternal { [void]$script:blocked.Add('Start-BackgroundExternal'); throw 'blocked by the test: Start-BackgroundExternal' }
    Mock Stop-ProcessTree { [void]$script:blocked.Add('Stop-ProcessTree'); throw 'blocked by the test: Stop-ProcessTree' }
    Mock Start-Process { [void]$script:blocked.Add('Start-Process'); throw 'blocked by the test: Start-Process' }
    Mock Restart-Computer { [void]$script:blocked.Add('Restart-Computer'); throw 'blocked by the test: Restart-Computer' }
    Mock Stop-Service { [void]$script:blocked.Add('Stop-Service'); throw 'blocked by the test: Stop-Service' }
    Mock Start-Service { [void]$script:blocked.Add('Start-Service'); throw 'blocked by the test: Start-Service' }
    Mock Remove-BitsTransfer { [void]$script:blocked.Add('Remove-BitsTransfer'); throw 'blocked by the test: Remove-BitsTransfer' }
    Mock Set-NetIPInterface { [void]$script:blocked.Add('Set-NetIPInterface'); throw 'blocked by the test: Set-NetIPInterface' }
    Mock New-NetIPAddress { [void]$script:blocked.Add('New-NetIPAddress'); throw 'blocked by the test: New-NetIPAddress' }
    Mock Set-DnsClientServerAddress { [void]$script:blocked.Add('Set-DnsClientServerAddress'); throw 'blocked by the test: Set-DnsClientServerAddress' }
    Mock Get-NetAdapter { [void]$script:blocked.Add('Get-NetAdapter'); throw 'blocked by the test: Get-NetAdapter' }
    Mock Get-PnpDevice { [void]$script:blocked.Add('Get-PnpDevice'); throw 'blocked by the test: Get-PnpDevice' }
    Mock Optimize-Volume { [void]$script:blocked.Add('Optimize-Volume'); throw 'blocked by the test: Optimize-Volume' }
    Mock Repair-Volume { [void]$script:blocked.Add('Repair-Volume'); throw 'blocked by the test: Repair-Volume' }
    Mock Repair-WindowsImage { [void]$script:blocked.Add('Repair-WindowsImage'); throw 'blocked by the test: Repair-WindowsImage' }
    Mock Set-ItemProperty { [void]$script:blocked.Add('Set-ItemProperty'); throw 'blocked by the test: Set-ItemProperty' }
    Mock New-ItemProperty { [void]$script:blocked.Add('New-ItemProperty'); throw 'blocked by the test: New-ItemProperty' }
    Mock Remove-ItemProperty { [void]$script:blocked.Add('Remove-ItemProperty'); throw 'blocked by the test: Remove-ItemProperty' }
  }

  AfterEach {
    @($script:blocked) | Should -BeNullOrEmpty
    $script:SetupLogPath = $null
    Unregister-SetupTick
  }

  Describe 'the catalog rows (repair plan, Actions and steps)' {
    It 'the eight actions: <Id>' -ForEach @(
      @{ Id = 'wuReset';     Kind = 'destructive'; Confirm = 'yes';  Stick = $false; Local = $false; Steps = @('wuServicesStop', 'wuRename', 'wuBits', 'wuServicesStart', 'wuScan') }
      @{ Id = 'diskCheck';   Kind = 'destructive'; Confirm = 'yes';  Stick = $false; Local = $false; Steps = @('diskCheckSchedule') }
      @{ Id = 'netInfo';     Kind = 'info';        Confirm = 'none'; Stick = $false; Local = $true;  Steps = @('netInfo') }
      @{ Id = 'netReset';    Kind = 'destructive'; Confirm = 'yes';  Stick = $true;  Local = $false; Steps = @('netBackup', 'winsockReset', 'ipReset', 'ipv6Reset', 'dnsFlush') }
      @{ Id = 'netRestore';  Kind = 'destructive'; Confirm = 'yes';  Stick = $true;  Local = $false; Steps = @('netRestore') }
      @{ Id = 'ghostList';   Kind = 'info';        Confirm = 'none'; Stick = $true;  Local = $true;  Steps = @('ghostList') }
      @{ Id = 'ghostRemove'; Kind = 'destructive'; Confirm = 'yes';  Stick = $true;  Local = $false; Steps = @('ghostCsv', 'ghostRemove') }
      @{ Id = 'safety';      Kind = 'info';        Confirm = 'none'; Stick = $false; Local = $true
         Steps = @('safetyRestart', 'safetyFree', 'safetyBitLocker', 'safetyInternet', 'safetyDisk', 'safetyDiskCheck', 'safetyNetBackup') }
    ) {
      $a = $script:ToolActionCatalog[$Id]
      $a | Should -Not -BeNullOrEmpty
      $a.Kind | Should -BeExactly $Kind; $a.Confirm | Should -BeExactly $Confirm; $a.NeedsStick | Should -Be $Stick; $a.LogLocal | Should -Be $Local
      @($a.Steps) | Should -Be $Steps
    }
    It 'every new step has its function, none is a servicing step, and only wuServicesStart always runs' {
      $ids = 'wuServicesStop', 'wuRename', 'wuBits', 'wuServicesStart', 'diskCheckSchedule', 'netInfo', 'netBackup', 'winsockReset', 'ipReset', 'ipv6Reset',
             'dnsFlush', 'netRestore', 'ghostList', 'ghostCsv', 'ghostRemove', 'safetyNetBackup'
      foreach ($id in $ids) {
        $s = $script:ToolSteps[$id]
        $s | Should -Not -BeNullOrEmpty -Because $id
        $s.Function | Should -BeExactly ('Invoke-ToolStep' + $id.Substring(0, 1).ToUpperInvariant() + $id.Substring(1)) -Because $id
        (Get-Command -Name $s.Function -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because $id
        $s.Servicing | Should -BeFalse -Because $id
        ($s['AlwaysRun'] -eq $true) | Should -Be ($id -ceq 'wuServicesStart') -Because $id
      }
    }
    It 'every step timeout this file names is in config.json''s toolStep' {
      $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:advancedFile).Path, [ref]$null, [ref]$null)
      $names = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'StepTimeout' }, $true) | ForEach-Object {
          $i = $_.Parent.CommandElements.IndexOf($_); [string]$_.Parent.CommandElements[$i + 1].Value })
      $names.Count | Should -BeGreaterThan 5
      foreach ($n in $names) { @($script:cfg.timeoutsMinutes.toolStep.PSObject.Properties.Name) | Should -Contain $n -Because "toolStep.$n" }
      foreach ($id in 'wuReset', 'diskCheck', 'netInfo', 'netReset', 'netRestore', 'ghostList', 'ghostRemove') {
        @($script:cfg.timeoutsMinutes.tool.PSObject.Properties.Name) | Should -Contain $id -Because "tool.$id" }
    }
  }

  Describe 'the Task 7 findings (repair plan, Findings)' {
    It 'holds every Task 7 finding, exactly in English, and in Hebrew with the same arguments' {
      $expected = @{
        'finding.wuServiceDisabled'     = '{0} is disabled (start type): Windows Update cannot work'
        'finding.wuServiceStopFailed'   = '{0} did not stop'
        'finding.wuServiceStartFailed'  = '{0} did not start again'
        'finding.wuRenamed'             = '{0} renamed to {1}'
        'finding.wuRenameFailed'        = '{0} could not be renamed (error {1}): restart, then run it again'
        'finding.wuRenameLocked'        = '{0} is in use and could not be renamed: restart, then run it again'
        'finding.wuRenameLink'          = '{0} is a link: it was not renamed'
        'finding.wuBitsCleared'         = '{0} Windows Update download jobs cleared'
        'finding.wuBitsFailed'          = 'The Windows Update download jobs could not be cleared ({0})'
        'finding.diskCheckScheduled'    = 'Disk check scheduled for the next start (it can take hours on a large HDD)'
        'finding.diskCheckNotScheduled' = 'The disk check could not be scheduled ({0})'
        'finding.diskCheckUnconfirmed'  = 'The disk check is probably scheduled for the next start, but it could not be confirmed ({0})'
        'finding.netBackupSaved'        = 'Network settings saved to {0}'
        'finding.netBackupFailed'       = 'The network settings could not be saved and checked: nothing was reset'
        'finding.netBackupNoIdentity'   = 'This PC has no serial number or usable BIOS UUID, so its saved settings could never be restored: nothing was reset'
        'finding.netResetStepFailed'    = '{0} returned {1}'
        'finding.netRestored'           = 'Network settings restored on {0} adapters'
        'finding.netRestoreFailed'      = '{0}: {1}'
        'finding.netRestoreRefused'     = 'The backup file does not match the one that was shown: nothing was applied'
        'finding.netRestoreUnreadable'  = 'The backup file could not be read (is the stick still plugged in?): nothing was applied'
        'finding.netRestoreNotOnStick'  = 'The backup file is not a network backup in BenTech-Reports on the stick, or it is a link: nothing was applied'
        'finding.netRestoreInvalid'     = 'The backup file is not valid: nothing was applied'
        'finding.ghostCsvFailed'        = 'The device list could not be saved: nothing was removed'
        'finding.ghostsRemoved'         = '{0} devices removed'
        'finding.ghostRemoveFailed'     = '{0} could not be removed ({1})'
        'finding.ghostListCapped'       = 'Only the first {0} of {1} old devices are listed: run Ghost devices again for the rest'
        'finding.restartRequired'       = 'Restart the PC to finish'
        # RD-R20 (Task 6): a dead clock fails Windows Update reset's rescan.
        'warn.clockNoRescan'            = 'The clock is wrong: the update rescan will fail until the date and time are fixed'
      }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        $script:ToolboxStrings.he[$k] | Should -Not -Match "'" -Because $k
        ([regex]::Matches($script:ToolboxStrings.he[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',' |
          Should -Be (([regex]::Matches($expected[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',') -Because $k
      }
    }
    It 'every finding code this file adds has its text in English and Hebrew' {
      $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:advancedFile).Path, [ref]$null, [ref]$null)
      $codes = foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-ToolFinding' }, $true)) {
        $i = 0
        foreach ($e in $c.CommandElements) { if ($e -is [Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Code') { break }; $i++ }
        $c.CommandElements[$i + 1].Value
      }
      @($codes).Count | Should -BeGreaterThan 15
      foreach ($code in $codes) {
        $script:ToolboxStrings.en.Keys | Should -Contain "finding.$code"
        $script:ToolboxStrings.he.Keys | Should -Contain "finding.$code"
      }
    }
  }

  Describe 'Windows Update reset (spec 6.4)' {
    It 'stops the running services, renames both folders, clears the update jobs, starts what was running, then scans' {
      $r = New-ActionRun wuReset
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      @($script:nativeLines | Where-Object { $_ -like 'sc.exe *' }) | Should -Be @('sc.exe stop wuauserv', 'sc.exe stop bits', 'sc.exe stop cryptsvc', 'sc.exe stop usosvc', 'sc.exe stop dosvc',
        'sc.exe start dosvc', 'sc.exe start usosvc', 'sc.exe start cryptsvc', 'sc.exe start bits', 'sc.exe start wuauserv')
      @($script:renamed).Count | Should -Be 2
      foreach ($x in $script:renamed) { $x.NewName | Should -Match '^(SoftwareDistribution|catroot2)\.bak-\d{8}-\d{6}$' }
      @($script:renamed.LiteralPath) | Should -Be @($script:softwareDistribution, $script:catroot2)
      $script:gcCommands.Keys | Should -Contain 'wuScan'
      @($r.Steps.Status) | Should -Be @('done', 'done', 'done', 'done', 'done')
      Get-FindingCodes $r | Should -Be @('wuRenamed', 'wuRenamed', 'wuBitsCleared')
      (Get-FindingArgs $r 'wuBitsCleared')[0] | Should -Be @('2')
      $r.Data.Services['msiserver'].Status | Should -Be 'Stopped'; $r.Data.Services['wuauserv'].StartType | Should -Be 'Automatic'
      # Nothing is deleted: the folders are renamed only (spec 6.4).
      [IO.File]::ReadAllText($script:advancedFile) | Should -Not -Match '(?i)Remove-Item|\.Delete\(|rd /s'
    }
    It 'a Disabled wuauserv is reported and left Disabled' {
      $script:services['wuauserv'] = @{ Status = 'Stopped'; StartType = 'Disabled' }
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Contain 'wuServiceDisabled'
      (Get-FindingArgs $r 'wuServiceDisabled')[0] | Should -Be @('wuauserv')
      $script:nativeLines | Should -Not -Contain 'sc.exe start wuauserv'; $script:nativeLines | Should -Not -Contain 'sc.exe stop wuauserv'
      @($script:nativeLines | Where-Object { $_ -like 'sc.exe config*' }).Count | Should -Be 0
      $script:services['wuauserv'].StartType | Should -Be 'Disabled'
    }
    It 'a Disabled dosvc or msiserver is not reported (only wuauserv, bits, cryptsvc and usosvc)' {
      $script:services['dosvc'] = @{ Status = 'Stopped'; StartType = 'Disabled' }
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Not -Contain 'wuServiceDisabled'; $script:nativeLines | Should -Not -Contain 'sc.exe start dosvc'
    }
    It 'a service that does not stop is a WARN; a service that does not start again is CRIT' {
      $script:scStops = $false
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      @(Get-FindingCodes $r | Where-Object { $_ -eq 'wuServiceStopFailed' }).Count | Should -Be 5
      Get-StepStatus $r 'wuServicesStop' | Should -Be 'warn'
      $script:scStops = $true; $script:exit['sc.exe'] = 5
      $q = New-ActionRun wuReset; $script:services = Get-DefaultServices
      $null = Invoke-ToolSteps -Run $q
      ($q.Findings | Where-Object { $_.Code -eq 'wuServiceStartFailed' }).Level | Should -Contain 'CRIT'
      Get-ToolResultColor -Outcome 'Done' -Findings $q.Findings | Should -Be 'RED'
    }
    It 'a service that is already stopping is waited for, not sent a stop' {
      $script:services['bits'] = @{ Status = 'StopPending'; StartType = 'Automatic' }
      Mock Wait-SetupDelay { foreach ($s in $script:services.Values) { if ($s.Status -eq 'StopPending') { $s.Status = 'Stopped' } } }
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -Not -Contain 'sc.exe stop bits'; Get-FindingCodes $r | Should -Not -Contain 'wuServiceStopFailed'
      $script:services['bits'].Status | Should -Be 'Stopped'; $script:nativeLines | Should -Not -Contain 'sc.exe start bits'   # it was not running
    }
    It 'the services start again even when the rename fails, and after a Stop' {
      $script:renameOk = $false
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -Contain 'sc.exe start wuauserv'
      @($script:renamed).Count | Should -Be 6    # three tries for each folder
      @(Get-FindingCodes $r | Where-Object { $_ -eq 'wuRenameLocked' }).Count | Should -Be 2   # a sharing violation names the cause (review M8)
      Should -Invoke Wait-SetupDelay -ParameterFilter { $Seconds -eq 3 } -Times 4 -Exactly
      $script:nativeLines.Clear(); $script:services = Get-DefaultServices
      $r = New-ActionRun wuReset; $script:onStep = { if ($args[0] -eq 'wuServicesStop') { 'x' | Set-Content $r.StopPath } }
      Invoke-ToolSteps -Run $r | Should -Be 'Stopped'
      $r.Steps | Where-Object Id -eq 'wuServicesStart' | ForEach-Object Status | Should -Be 'done'
      @($r.Steps.Status) | Should -Be @('done', 'skipped', 'skipped', 'done', 'skipped')
      $script:nativeLines | Should -Contain 'sc.exe start wuauserv'
    }
    It 'a rename refused for another reason names its error code, language-independent (review M8)' {
      $script:renameOk = $false; $script:renameError = 'denied'
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      @(Get-FindingCodes $r | Where-Object { $_ -eq 'wuRenameLocked' }).Count | Should -Be 0
      (Get-FindingArgs $r 'wuRenameFailed')[0] | Should -Be @('SoftwareDistribution', '0x80070005')
    }
    It 'a rename that fails is not retried when the action is short of time (review M6)' {
      Mock Get-ToolElapsedSeconds { 36000 - 120 }   # two minutes left of the budget
      $script:renameOk = $false
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      @($script:renamed).Count | Should -Be 2   # one try for each folder
      Should -Invoke Wait-SetupDelay -ParameterFilter { $Seconds -eq 3 } -Times 0 -Exactly
      @(Get-FindingCodes $r | Where-Object { $_ -eq 'wuRenameLocked' }).Count | Should -Be 2
      $script:nativeLines | Should -Contain 'sc.exe start wuauserv'
    }
    It 'a service still starting is waited for, then stopped; one that answers 1061 is waited for and asked once more (review M7)' {
      $script:services['bits'] = @{ Status = 'StartPending'; StartType = 'Automatic' }
      Mock Wait-SetupDelay { foreach ($s in $script:services.Values) { if ($s.Status -eq 'StartPending') { $s.Status = 'Running' } } }
      $script:exitQueue['sc.exe stop usosvc'] = New-Object Collections.Queue (, [object[]]@(1061, 0))
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      @($script:nativeLines | Where-Object { $_ -eq 'sc.exe stop bits' }).Count | Should -Be 1
      @($script:nativeLines | Where-Object { $_ -eq 'sc.exe stop usosvc' }).Count | Should -Be 2
      Get-FindingCodes $r | Should -Not -Contain 'wuServiceStopFailed'
      $script:nativeLines | Should -Contain 'sc.exe start bits'   # it was starting before: it runs again afterwards
    }
    It 'a rename whose target name is taken gets the next free name (review M10)' {
      Mock Get-Date { [datetime]::new(2026, 10, 22, 10, 15, 0) }
      $taken = Join-Path $script:wuRoot 'SoftwareDistribution.bak-20261022-101500'
      [void][IO.Directory]::CreateDirectory($taken)
      try {
        $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
        @($script:renamed.NewName) | Should -Be @('SoftwareDistribution.bak-20261022-101500-2', 'catroot2.bak-20261022-101500')
      } finally { [IO.Directory]::Delete($taken, $true) }
    }
    It 'the services start again after the deadline, with the 0.25-minute floor' {
      $script:elapsed = 0.0
      Mock Get-ToolElapsedSeconds { $script:elapsed }
      $r = New-ActionRun wuReset; $script:onStep = { if ($args[0] -eq 'wuRename') { $script:elapsed = 36000 + 60 } }
      Invoke-ToolSteps -Run $r | Should -Be 'TimedOut'
      @($r.Steps.Status) | Should -Be @('done', 'done', 'skipped', 'done', 'skipped')
      Should -Invoke Invoke-ToolNative -ParameterFilter { $ArgumentList -eq 'start wuauserv' } -Times 1 -Exactly
      Get-ToolStepTimeout -Run $r -Name 'service' | Should -Be 0.25
    }
    It 'a reparse point is never renamed' {
      Mock Test-StickReparsePoint { $Path -eq $script:catroot2 }
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      @($script:renamed.LiteralPath) | Should -Be @($script:softwareDistribution)
      Get-FindingCodes $r | Should -Contain 'wuRenameLink'
    }
    It 'clears only jobs whose files are under SoftwareDistribution' {
      $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      $script:gcCommands['wuBits'] | Should -Match ([regex]::Escape((Join-Path $script:softwareDistribution '') ))
      $script:gcCommands['wuBits'] | Should -Match 'LocalName'; $script:gcCommands['wuBits'] | Should -Match 'Get-BitsTransfer -AllUsers'
      $script:gcCommands['wuBits'] | Should -Not -Match 'DisplayName'
      $script:gcFail['wuBits'] = 'access denied'
      $q = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $q
      (Get-FindingArgs $q 'wuBitsFailed')[0] | Should -Be @('access denied'); Get-StepStatus $q 'wuBits' | Should -Be 'warn'
    }
  }

  Describe 'Disk check at restart (spec 6.5, ruling RD-R1)' {
    It 'fsutil dirty set, confirmed by DirtyBitSet: scheduled and a restart needed' {
      $script:dirty = $true; $r = New-ActionRun diskCheck; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:nativeLines | Should -Be @('fsutil.exe dirty set C:'); Get-FindingCodes $r | Should -Be @('diskCheckScheduled'); $r.RestartRequired | Should -BeTrue
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN'
    }
    It 'exit 0 but no dirty bit is not scheduled (CRIT)' {
      $script:dirty = $false; $r = New-ActionRun diskCheck; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Be @('diskCheckNotScheduled'); $r.RestartRequired | Should -BeFalse
      ($r.Findings | Where-Object Code -eq 'diskCheckNotScheduled').Level | Should -Be 'CRIT'
    }
    It 'a non-zero exit or a timeout is not scheduled, whatever the dirty bit says' {
      $script:exit['fsutil.exe'] = 1; $r = New-ActionRun diskCheck; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Be @('diskCheckNotScheduled'); (Get-FindingArgs $r 'diskCheckNotScheduled')[0] | Should -Match '0x00000001'
      $script:exit['fsutil.exe'] = $null; $q = New-ActionRun diskCheck; $null = Invoke-ToolSteps -Run $q
      Get-FindingCodes $q | Should -Be @('diskCheckNotScheduled'); $q.RestartRequired | Should -BeFalse
    }
    It 'exit 0 but a dirty bit that cannot be read: probably scheduled, could not confirm (WARN), a restart needed (review M5)' {
      $script:dirty = $null; $r = New-ActionRun diskCheck; $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -Be @('fsutil.exe dirty set C:'); Get-FindingCodes $r | Should -Be @('diskCheckUnconfirmed')
      ($r.Findings | Where-Object Code -eq 'diskCheckUnconfirmed').Level | Should -Be 'WARN'; $r.RestartRequired | Should -BeTrue
      Get-StepStatus $r 'diskCheckSchedule' | Should -Be 'warn'
    }
    It 'a start-up check list (BootExecute) that cannot be read: the drive is marked, but could not confirm, never "not excluded" (review M5)' {
      $script:bootExecute = $null; $script:dirty = $true; $r = New-ActionRun diskCheck; $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -Be @('fsutil.exe dirty set C:'); Get-FindingCodes $r | Should -Be @('diskCheckUnconfirmed')
      (Get-FindingArgs $r 'diskCheckUnconfirmed')[0] | Should -Match 'start-up check'; $r.RestartRequired | Should -BeTrue
      $r.Data.DiskCheck.ExcludedUnknown | Should -BeTrue
    }
    It 'a drive excluded from the start-up check on this PC is not marked: the check would never run' {
      $script:bootExecute = @('autocheck autochk /k:C *'); $r = New-ActionRun diskCheck; $null = Invoke-ToolSteps -Run $r
      @($script:nativeLines).Count | Should -Be 0; Get-FindingCodes $r | Should -Be @('diskCheckNotScheduled'); $r.RestartRequired | Should -BeFalse
    }
    It 'chkntfs appears nowhere in src (RD-R1)' {
      $tool = 'chk' + 'ntfs'
      @(Get-ChildItem "$PSScriptRoot\..\src" -Recurse -Filter *.ps1 | Select-String -Pattern $tool -SimpleMatch).Count | Should -Be 0
      $script:ToolActionCatalog.Keys | Should -Not -Contain 'diskCheckCancel'
    }
  }

  Describe 'Network reset and restore (spec 6.6)' {
    It 'saves the settings as JSON, checks them, then runs the four resets; never an IP release or renew' {
      $r = New-ActionRun netReset; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:nativeLines | Should -Be @('netsh.exe winsock reset', 'netsh.exe int ip reset', 'netsh.exe int ipv6 reset', 'ipconfig.exe /flushdns')
      $file = @(Get-ChildItem "$($r.SessionDir)\network-backup-*.json")
      $file.Count | Should -Be 1; $file[0].Name | Should -Match '^network-backup-\d{8}-\d{6}\.json$'
      $saved = Read-ToolJsonFile $file[0].FullName
      $saved.Adapters[0].Addresses[0].Ip | Should -Be '192.168.1.10'; @($saved.Adapters[0].Gateways) | Should -Be @('192.168.1.1')   # 0.0.0.0 is no gateway
      $saved.Version | Should -Be 1; $saved.Identity.Key | Should -Be 'SN-7HX2K93'; $saved.Identity.ComputerName | Should -Be 'PC1'
      # An IPv6 address with its zone is saved without it; a MAC that is no MAC is saved empty.
      $saved.Adapters[2].Addresses[0].Ip | Should -Be 'fe80::1'; $saved.Adapters[2].Mac | Should -BeExactly ''
      Test-ToolNetBackup -Value $saved -IdentityKey 'SN-7HX2K93' | Should -Not -BeNullOrEmpty
      # RD-R21: the Hebrew alias is kept, written as \u escapes (ASCII bytes), passes the read-back compare, the strict
      # decode and Test-ToolNetBackup, and the file's hash is stable.
      $saved.Adapters[2].Alias | Should -BeExactly 'vEthernet (מתג)'
      @([IO.File]::ReadAllBytes($file[0].FullName) | Where-Object { $_ -gt 0x7E }).Count | Should -Be 0
      $once = Read-ToolNetBackupFile -Path $file[0].FullName; $twice = Read-ToolNetBackupFile -Path $file[0].FullName
      $once.Sha256 | Should -BeExactly (Get-FileHash $file[0].FullName).Hash; $twice.Sha256 | Should -BeExactly $once.Sha256
      (Test-ToolNetBackup -Value $once.Value -IdentityKey 'SN-7HX2K93').Adapters[2].Alias | Should -BeExactly 'vEthernet (מתג)'
      $r.RestartRequired | Should -BeTrue; Get-FindingCodes $r | Should -Be @('netBackupSaved', 'restartRequired')
      $r.Files.NetBackup | Should -Be $file[0].FullName; $r.Data.ContainsKey('Abort') | Should -BeFalse
      [IO.File]::ReadAllText($script:advancedFile) | Should -Not -Match '(?i)/release|/renew'
    }
    It 'a backup step that throws resets nothing either (Abort is set first, cleared only on success)' {
      Mock Get-ToolNetSettings { throw 'unexpected' }
      $r = New-ActionRun netReset; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:nativeLines | Should -BeNullOrEmpty; Get-FindingCodes $r | Should -Be @('stepFailed')
      @($r.Steps.Status) | Should -Be @('failed', 'skipped', 'skipped', 'skipped', 'skipped'); $r.Data.Abort | Should -BeTrue
    }
    It 'reads the static addresses from the persistent store, as the gateways: an unplugged static adapter is saved too (review M1)' {
      $script:gc['netSettings']['Items'] += @{ Alias = 'Ethernet 3'; Guid = '{8D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-59'; Index = 31
                                               Ipv4Dhcp = $false; Ipv6Dhcp = $true; Addresses = @(@{ Ip = '10.1.1.5'; Prefix = 24 }); Gateways = @('10.1.1.1'); Dns = @() }
      $r = New-ActionRun netReset; $null = Invoke-ToolSteps -Run $r
      $command = $script:gcCommands['netSettings']
      $command | Should -Match 'Get-NetIPAddress -PolicyStore PersistentStore'; $command | Should -Match 'Get-NetRoute -PolicyStore PersistentStore'
      $command | Should -Not -Match 'PrefixOrigin'   # every address in the persistent store was set by hand; the active store has none for a cable that is out
      $saved = Read-ToolJsonFile -Path $r.Files.NetBackup
      @($saved.Adapters | Where-Object { $_.Alias -eq 'Ethernet 3' })[0].Addresses[0].Ip | Should -Be '10.1.1.5'
    }
    It 'without an identity key no backup could ever be restored: nothing is saved and nothing is reset (review M3)' {
      $r = New-ActionRun netReset; $r.Args['Identity']['Key'] = ''
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:nativeLines | Should -BeNullOrEmpty; Get-FindingCodes $r | Should -Be @('netBackupNoIdentity')
      ($r.Findings | Where-Object Code -eq 'netBackupNoIdentity').Level | Should -Be 'CRIT'; $r.Data.Abort | Should -BeTrue
      @(Get-ChildItem $r.SessionDir -Filter 'network-backup-*.json').Count | Should -Be 0; Should -Invoke Invoke-ToolJsonChild -Times 0 -Exactly
    }
    It 'no verified backup, no reset: nothing after the backup step runs (Review Focus 3, <Why>)' -ForEach @(
      @{ Why = 'the write fails' }, @{ Why = 'the read-back differs' }, @{ Why = 'no stick: the local fallback folder' }) {
      $r = New-ActionRun netReset -Break $Why; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:nativeLines | Should -BeNullOrEmpty
      Get-FindingCodes $r | Should -Contain 'netBackupFailed'
      @($r.Steps.Status)[1..4] | Should -Be @('skipped', 'skipped', 'skipped', 'skipped'); Get-StepStatus $r 'netBackup' | Should -Be 'failed'
      $r.Data.Abort | Should -BeTrue; $r.RestartRequired | Should -BeFalse
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
    }
    It 'a settings read that fails or times out resets nothing' {
      $script:gcFail['netSettings'] = 'timed out'; $r = New-ActionRun netReset; $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -BeNullOrEmpty; Get-FindingCodes $r | Should -Contain 'netBackupFailed'
      @(Get-ChildItem $r.SessionDir -Filter 'network-backup-*.json').Count | Should -Be 0
    }
    It 'netInfo answers the static adapters only, with plain IP strings and the RDP session (RD-R2), in an ASCII result' {
      $script:rdp = $true; $r = New-ActionRun netInfo; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $info = $r.Data.NetInfo
      @($info.Adapters).Count | Should -Be 2; @($info.Adapters.Alias) | Should -Be @('Ethernet', 'vEthernet (מתג)')
      @($info.Adapters[0].Gateways) | Should -Be @('192.168.1.1'); @($info.Adapters[0].Dns) | Should -Be @('8.8.8.8', '8.8.4.4')
      $info.Adapters[0].Gateways[0] | Should -BeOfType [string]
      @($info.Remote.Keys) | Should -Be @('Rdp'); $info.Remote.Rdp | Should -BeTrue
      $r.Files.ContainsKey('NetBackup') | Should -BeFalse; @($script:nativeLines).Count | Should -Be 0
      Write-ToolResult -Run $r -Outcome 'Done' | Should -BeTrue
      @([IO.File]::ReadAllBytes($r.ResultPath) | Where-Object { $_ -gt 0x7E }).Count | Should -Be 0   # ASCII bytes (RD-R21)
      $back = Read-ToolJsonFile $r.ResultPath
      $back.Data.NetInfo.Adapters[0].Addresses[0].Ip | Should -Be '192.168.1.10'; $back.Data.NetInfo.Adapters[1].Alias | Should -BeExactly 'vEthernet (מתג)'
      # A PC without static settings answers an empty list, not nothing.
      $script:gc['netSettings'] = @{ Items = @($script:gc['netSettings']['Items'][1]) }
      $q = New-ActionRun netInfo; $null = Invoke-ToolSteps -Run $q; $q.Data.NetInfo.Adapters.Count | Should -Be 0
      $null = Write-ToolResult -Run $q -Outcome 'Done'; [IO.File]::ReadAllText($q.ResultPath) | Should -Match '"Adapters":\s+\[\s*\]'
    }
    It 'the remote-session check names RDP only (RD-R2: AnyDesk and ScreenConnect are never read as connected)' {
      Mock Get-Process { [void]$script:blocked.Add('Get-Process'); throw 'blocked by the test: Get-Process' }
      $s = & $script:realRemote -TerminalServerSession { $false }; @($s.Keys) | Should -Be @('Rdp'); $s.Rdp | Should -BeFalse
      (& $script:realRemote -TerminalServerSession { $true }).Rdp | Should -BeTrue
      (& $script:realRemote -TerminalServerSession { throw 'no forms' }).Rdp | Should -BeFalse
      (& $script:realRemote -TerminalServerSession { 'yes' }).Rdp | Should -BeFalse
    }
    It 'restore refuses a file that changed after it was shown, or that is not valid' {
      $r = New-ActionRun netRestore -Options @{ File = $script:valid; Sha256 = ('0' * 64) }; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Be @('netRestoreRefused'); Should -Invoke Invoke-ToolJsonChild -Times 0 -Exactly
      $r = New-ActionRun netRestore -Options @{ File = $script:bad; Sha256 = (Get-FileHash $script:bad).Hash }; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Be @('netRestoreInvalid'); Should -Invoke Invoke-ToolJsonChild -Times 0 -Exactly
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
    }
    It 'restore refuses Options that do not name a backup under the stick''s BenTech-Reports, naming the cause (<Why>; review M8)' -ForEach @(
      @{ Why = 'a file elsewhere on the PC'; File = 'C:\Windows\Temp\network-backup-20261020-090500.json'; E = 'netRestoreNotOnStick' }
      @{ Why = 'a file at the stick''s root'; File = 'STICK\network-backup-20261020-090500.json'; E = 'netRestoreNotOnStick' }
      @{ Why = 'a path with ..'; File = 'REPORTS\PC1_7HX2K93_2026-10-20_0900\..\PC1_7HX2K93_2026-10-20_0900\network-backup-20261020-090500.json'; E = 'netRestoreNotOnStick' }
      @{ Why = 'another file name'; File = 'REPORTS\PC1_7HX2K93_2026-10-20_0900\settings.json'; E = 'netRestoreNotOnStick' }
      @{ Why = 'a relative path'; File = 'network-backup-20261020-090500.json'; E = 'netRestoreNotOnStick' }
      @{ Why = 'no file'; File = ''; E = 'netRestoreNotOnStick' }
      @{ Why = 'a file that is gone (the stick pulled)'; File = 'REPORTS\PC1_7HX2K93_2026-10-20_0900\network-backup-20261020-090600.json'; E = 'netRestoreUnreadable' }
      @{ Why = 'a Sha256 that is no hash'; File = 'VALID'; Sha256 = 'abc'; E = 'netRestoreRefused' }
    ) {
      $path = $File.Replace('STICK\', $script:stickRoot).Replace('REPORTS\', $script:reports + '\')
      if ($File -eq 'VALID') { $path = $script:valid }
      $hash = if ($Sha256) { $Sha256 } else { (Get-FileHash $script:valid).Hash }
      $r = New-ActionRun netRestore -Options @{ File = $path; Sha256 = $hash }; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Be @($E); Should -Invoke Invoke-ToolJsonChild -Times 0 -Exactly
      ($r.Findings | Where-Object Code -eq $E).Level | Should -Be 'CRIT'
    }
    It 'restore refuses a backup file that is a link' {
      Mock Test-StickReparsePoint { $Path -eq $script:valid }
      $r = New-ActionRun netRestore -Options @{ File = $script:valid; Sha256 = (Get-FileHash $script:valid).Hash }; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Be @('netRestoreNotOnStick'); Should -Invoke Invoke-ToolJsonChild -Times 0 -Exactly
    }
    It 'Test-ToolNetBackup rejects <Why>' -ForEach @(
      @{ Why = 'a bad IP'; Path = 'Adapters[0].Addresses[0].Ip'; V = '192.168.1.300' }
      @{ Why = 'an IPv4 with a leading zero'; Path = 'Adapters[0].Addresses[0].Ip'; V = '192.168.01.10' }
      @{ Why = 'a short IPv4'; Path = 'Adapters[0].Addresses[0].Ip'; V = '192.168.1' }
      @{ Why = 'prefix 33'; Path = 'Adapters[0].Addresses[0].Prefix'; V = 33 }
      @{ Why = 'a prefix as text'; Path = 'Adapters[0].Addresses[0].Prefix'; V = '24' }
      @{ Why = 'another PC''s key'; Path = 'Identity.Key'; V = 'SN-OTHER' }
      @{ Why = 'a MAC with colons'; Path = 'Adapters[0].Mac'; V = 'A4:BB:6D:12:34:56' }
      @{ Why = 'a GUID that is not one'; Path = 'Adapters[0].Guid'; V = 'x' }
      @{ Why = 'a gateway that carries code'; Path = 'Adapters[0].Gateways[0]'; V = "192.168.1.1'; Remove-Item C:\x; '" }
      @{ Why = 'a DNS server that is a name'; Path = 'Adapters[0].Dns[0]'; V = 'dns.google' }
      @{ Why = 'version 2'; Path = 'Version'; V = 2 }
      @{ Why = 'a DHCP flag as text'; Path = 'Adapters[0].Ipv4Dhcp'; V = 'false' }
      @{ Why = 'one adapter instead of a list'; Path = 'Adapters'; V = @{ Alias = 'x' } }
    ) {
      Test-ToolNetBackup -Value (Set-JsonValue $script:validObject $Path $V) -IdentityKey 'SN-7HX2K93' | Should -BeNullOrEmpty
    }
    It 'Test-ToolNetBackup accepts the valid fixture and 16 adapters, not 17; never an empty key' {
      $ok = Test-ToolNetBackup -Value $script:validObject -IdentityKey 'SN-7HX2K93'
      $ok | Should -Not -BeNullOrEmpty; @($ok.Adapters).Count | Should -Be 3; $ok.Adapters[1].Dns[1] | Should -Be '2606:4700:4700::1111'
      Test-ToolNetBackup -Value (New-ManyAdapters 16) -IdentityKey 'SN-7HX2K93' | Should -Not -BeNullOrEmpty
      Test-ToolNetBackup -Value (New-ManyAdapters 17) -IdentityKey 'SN-7HX2K93' | Should -BeNullOrEmpty
      Test-ToolNetBackup -Value (Set-JsonValue $script:validObject 'Identity.Key' '') -IdentityKey '' | Should -BeNullOrEmpty
      # An object read from JSON is checked like a hashtable.
      Test-ToolNetBackup -Value ([IO.File]::ReadAllText($script:valid) | ConvertFrom-Json) -IdentityKey 'SN-7HX2K93' | Should -Not -BeNullOrEmpty
    }
    It 'restore applies the static values per adapter by GUID, then MAC, as validated literals; DHCP adapters are left alone' {
      $r = New-ActionRun netRestore -Options @{ File = $script:valid; Sha256 = (Get-FileHash $script:valid).Hash }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $one = $script:gcCommands['netApply-1']
      $one | Should -Match "Set-NetIPInterface -InterfaceIndex 12 -AddressFamily IPv4 -Dhcp Disabled"
      $one | Should -Match "New-NetIPAddress -InterfaceIndex \d+ -IPAddress '192\.168\.1\.10' -PrefixLength 24 -DefaultGateway '192\.168\.1\.1'"
      $one | Should -Match "Set-DnsClientServerAddress -InterfaceIndex 12 -ServerAddresses @\('8\.8\.8\.8', '8\.8\.4\.4'\)"
      $one | Should -Not -Match 'IPv6'   # IPv6 was DHCP and had no static address: untouched
      # The DNS-only Wi-Fi (found by its MAC, index 7): its DNS servers only; DHCP is never turned off for it.
      $two = $script:gcCommands['netApply-2']
      $two | Should -Match "Set-DnsClientServerAddress -InterfaceIndex 7 -ServerAddresses @\('1\.1\.1\.1', '2606:4700:4700::1111'\)"
      $two | Should -Not -Match 'Set-NetIPInterface|New-NetIPAddress'
      $script:gcCommands.Keys | Should -Not -Contain 'netApply-3'
      $script:gcCommands['netAdapters'] | Should -Match 'Get-NetAdapter'
      Get-FindingCodes $r | Should -Be @('netRestored'); (Get-FindingArgs $r 'netRestored')[0] | Should -Be @('2')
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'GREEN'
    }
    It 'restore parses the very bytes it hashed: the values come from the file read once' {
      Mock Get-FileHash { [void]$script:blocked.Add('Get-FileHash'); throw 'blocked by the test: Get-FileHash' }
      $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($script:valid))).Replace('-', '')
      $r = New-ActionRun netRestore -Options @{ File = $script:valid; Sha256 = $hash.ToLowerInvariant() }; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Be @('netRestored')
      # The step reads the file through one reader that hashes and parses the same bytes.
      $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:advancedFile).Path, [ref]$null, [ref]$null)
      $restore = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ToolStepNetRestore' }, $true)
      $restore.Extent.Text | Should -Match 'Read-ToolNetBackupFile'; $restore.Extent.Text | Should -Not -Match 'Get-FileHash|Read-ToolJsonFile|ReadAll'
    }
    It 'per adapter: one not found, one whose grandchild fails, one with an error of its own; each a WARN, the rest applied' {
      $script:gc['netAdapters'] = @{ Items = @(@{ Alias = 'Ethernet'; Guid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-56'; Index = 12 }) }
      $script:gc['netApply-1'] = @{ Errors = @('IPv4: Instance MSFT_NetIPAddress already exists') }
      $r = New-ActionRun netRestore -Options @{ File = $script:valid; Sha256 = (Get-FileHash $script:valid).Hash }; $null = Invoke-ToolSteps -Run $r
      Get-FindingCodes $r | Should -Be @('netRestoreFailed', 'netRestoreFailed', 'netRestored')
      (Get-FindingArgs $r 'netRestoreFailed')[0] | Should -Be @('Ethernet', 'IPv4: Instance MSFT_NetIPAddress already exists')
      (Get-FindingArgs $r 'netRestoreFailed')[1] | Should -Be @('Wi-Fi', 'adapter not found')
      (Get-FindingArgs $r 'netRestored')[0] | Should -Be @('0'); Get-StepStatus $r 'netRestore' | Should -Be 'warn'
      $script:gcFail['netAdapters'] = 'timed out'; $script:gcCommands = @{}
      $q = New-ActionRun netRestore -Options @{ File = $script:valid; Sha256 = (Get-FileHash $script:valid).Hash }; $null = Invoke-ToolSteps -Run $q
      Get-ToolResultColor -Outcome 'Done' -Findings $q.Findings | Should -Be 'RED'; $script:gcCommands.Keys | Should -Not -Contain 'netApply-1'
    }
    It 'New-ToolNetApplyCommand: a gateway without a static address of its family, or a second one, is reported, never applied' {
      $a = @{ Alias = 'Lan'; Guid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = ''; Ipv4Dhcp = $false; Ipv6Dhcp = $false
              Addresses = @(@{ Ip = '10.0.0.5'; Prefix = 8 }, @{ Ip = '10.0.0.6'; Prefix = 8 }, @{ Ip = '2001:db8::5'; Prefix = 64 })
              Gateways = @('10.0.0.1', '10.0.0.2', 'fe80::1'); Dns = @() }
      $c = New-ToolNetApplyCommand -InterfaceIndex 4 -Adapter $a
      $c.Command | Should -Match "New-NetIPAddress -InterfaceIndex 4 -IPAddress '10\.0\.0\.5' -PrefixLength 8 -DefaultGateway '10\.0\.0\.1'"
      $c.Command | Should -Match "New-NetIPAddress -InterfaceIndex 4 -IPAddress '10\.0\.0\.6' -PrefixLength 8\r?\n"
      $c.Command | Should -Match "Set-NetIPInterface -InterfaceIndex 4 -AddressFamily IPv6 -Dhcp Disabled"
      $c.Command | Should -Match "New-NetIPAddress -InterfaceIndex 4 -IPAddress '2001:db8::5' -PrefixLength 64 -DefaultGateway 'fe80::1'"
      $c.Command | Should -Not -Match '10\.0\.0\.2'; $c.Command | Should -Not -Match 'Set-DnsClientServerAddress'
      @($c.Problems) | Should -Be @('gateway 10.0.0.2 not restored: only one default gateway per address family')
      $b = @{ Alias = 'Lan'; Guid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = ''; Ipv4Dhcp = $true; Ipv6Dhcp = $true; Addresses = @(); Gateways = @('10.0.0.1'); Dns = @() }
      $d = New-ToolNetApplyCommand -InterfaceIndex 4 -Adapter $b
      @($d.Problems) | Should -Be @('gateway 10.0.0.1 not restored: no static IPv4 address'); $d.Command | Should -Not -Match 'New-NetIPAddress|Set-NetIPInterface'
    }
    It 'Find-ToolNetBackup: the newest valid backup of this PC on the stick, its hash and its adapters from the same bytes' {
      # A newer file of another PC and a newer invalid one are passed over.
      $other = Join-Path $script:reports 'PC9_OTHER_2026-10-21_0800'; [void][IO.Directory]::CreateDirectory($other)
      $otherFile = Join-Path $other 'network-backup-20261021-080000.json'
      [IO.File]::WriteAllText($otherFile, ([IO.File]::ReadAllText($script:valid).Replace('SN-7HX2K93', 'SN-OTHER')))
      [IO.File]::Copy($script:bad, (Join-Path $script:earlier 'network-backup-20261020-100000.json'), $true)
      $found = Find-ToolNetBackup -StickRoot $script:stickRoot -IdentityKey 'SN-7HX2K93'
      $found.Path | Should -Be $script:valid; $found.Sha256 | Should -Be (Get-FileHash $script:valid).Hash; $found.CreatedAt | Should -Be '2026-10-20T09:05:00'
      @($found.Adapters).Count | Should -Be 3; $found.Adapters[0].Addresses[0].Ip | Should -Be '192.168.1.10'
      Find-ToolNetBackup -StickRoot $script:stickRoot -IdentityKey 'SN-OTHER' | ForEach-Object Path | Should -Be $otherFile
      Find-ToolNetBackup -StickRoot $script:stickRoot -IdentityKey '' | Should -BeNullOrEmpty
      Find-ToolNetBackup -StickRoot '' -IdentityKey 'SN-7HX2K93' | Should -BeNullOrEmpty
      Find-ToolNetBackup -StickRoot (Join-Path $TestDrive 'NoStick\') -IdentityKey 'SN-7HX2K93' | Should -BeNullOrEmpty
      Mock Test-StickReparsePoint { $Path -eq $script:reports }
      Find-ToolNetBackup -StickRoot $script:stickRoot -IdentityKey 'SN-7HX2K93' | Should -BeNullOrEmpty
      [IO.Directory]::Delete($other, $true)
    }
    It 'Find-ToolNetBackup offers the newest backup that holds a static value, not a newer one without (review M2)' {
      $later = Join-Path $script:reports 'PC1_7HX2K93_2026-10-21_0900'; [void][IO.Directory]::CreateDirectory($later)
      try {
        # A second reset on a PC already on DHCP saved a backup with nothing static in it: it is passed over.
        $dhcpOnly = Set-JsonValue $script:validObject 'Version' 1; $dhcpOnly['Adapters'] = @($dhcpOnly['Adapters'][2])
        $null = Write-ToolJsonFile -Path (Join-Path $later 'network-backup-20261021-090000.json') -InputObject $dhcpOnly
        (Find-ToolNetBackup -StickRoot $script:stickRoot -IdentityKey 'SN-7HX2K93').Path | Should -Be $script:valid
        # Two that hold static values: the newest.
        $newest = Join-Path $later 'network-backup-20261021-100000.json'
        $null = Write-ToolJsonFile -Path $newest -InputObject (Set-JsonValue $script:validObject 'Adapters[0].Addresses[0].Ip' '192.168.1.20')
        $found = Find-ToolNetBackup -StickRoot $script:stickRoot -IdentityKey 'SN-7HX2K93'
        $found.Path | Should -Be $newest; $found.Adapters[0].Addresses[0].Ip | Should -Be '192.168.1.20'
      } finally { [IO.Directory]::Delete($later, $true) }
    }
    It 'the safety child names the saved backup (safetyNetBackup), and none without a stick' {
      $r = New-ActionRun safety
      Invoke-ToolStepSafetyNetBackup -Run $r | Should -Be 'done'
      $r.Data.NetBackup.Path | Should -Be $script:valid; @($r.Data.NetBackup.Adapters).Count | Should -Be 3
      $r.Args['StickRoot'] = ''; Invoke-ToolStepSafetyNetBackup -Run $r | Should -Be 'done'; $r.Data.ContainsKey('NetBackup') | Should -BeTrue; $r.Data.NetBackup | Should -BeNullOrEmpty
      Mock Find-ToolNetBackup { throw 'stick pulled' }
      $r.Args['StickRoot'] = $script:stickRoot; Invoke-ToolStepSafetyNetBackup -Run $r | Should -Be 'done'; $r.Data.NetBackup | Should -BeNullOrEmpty
      $r.Findings.Count | Should -Be 0
    }
    It 'a reset step that fails is a WARN with its exit code; the next one still runs' {
      $script:exit['netsh.exe'] = 1
      $r = New-ActionRun netReset; $null = Invoke-ToolSteps -Run $r
      @($script:nativeLines).Count | Should -Be 4
      (Get-FindingArgs $r 'netResetStepFailed') | ForEach-Object { $_[1] } | Should -Be @('0x00000001', '0x00000001', '0x00000001')
      (Get-FindingArgs $r 'netResetStepFailed')[0][0] | Should -Be 'netsh winsock reset'
      @(Get-FindingCodes $r | Where-Object { $_ -eq 'restartRequired' }).Count | Should -Be 1
    }
  }

  Describe 'Ghost devices (spec 6.7)' {
    It 'leaves out <Why>' -ForEach @(
      @{ Why = 'BTHENUM'; Id = 'BTHENUM\{0000110b...}_LOCALMFG&0002\7&1'; R = 'bluetooth' }
      @{ Why = 'BTHLE'; Id = 'BTHLE\DEV_A1B2C3'; R = 'bluetooth' }
      @{ Why = 'BTHLEDEVICE'; Id = 'BTHLEDEVICE\{0000180f...}'; R = 'bluetooth' }
      @{ Why = 'BTHHFENUM'; Id = 'BTHHFENUM\BthHFPAudio\8&1'; R = 'bluetooth' }
      @{ Why = 'an audio endpoint'; Id = 'SWD\MMDEVAPI\{0.0.0.00000000}.{guid}'; R = 'audio' }
      @{ Why = 'a print queue'; Id = 'SWD\PRINTENUM\{guid}'; R = 'printer' }
      @{ Why = 'a WSD printer'; Id = 'WSDPRINT\HPOFFICEJET\1&2'; R = 'wsd-ipp' }
      @{ Why = 'an IPP device'; Id = 'SWD\IPPENUM\{guid}'; R = 'wsd-ipp' }
      @{ Why = 'a WSD device by its second segment'; Id = 'SWD\DAFWSDProvider\urn:uuid:1'; R = 'wsd-ipp' }
      @{ Why = 'the Bluetooth class'; Id = 'USB\VID_8087&PID_0026\5&1'; Class = 'Bluetooth'; R = 'bluetooth' }
      @{ Why = 'the Printer class'; Id = 'ROOT\PRINTER\0000'; Class = 'Printer'; R = 'printer' }
      @{ Why = 'the AudioEndpoint class'; Id = 'ROOT\X\0000'; Class = 'AudioEndpoint'; R = 'audio' }
      @{ Why = 'a HID child of a Bluetooth keyboard'; Id = 'HID\{00001124...}_VID&0002046D\8&1'; Parent = 'BTHENUM\{00001124...}'; R = 'bluetooth' }
      @{ Why = 'a child of a Bluetooth-class parent'; Id = 'HID\VID_046D\8&1'; Parent = 'USB\VID_8087\5&1'; ParentClass = 'Bluetooth'; R = 'bluetooth' }
    ) {
      $class = if ($Class) { $Class } else { 'HIDClass' }
      $parentClass = if ($ParentClass) { $ParentClass } else { 'Bluetooth' }
      Test-GhostExcluded -Device @{ InstanceId = $Id; Class = $class } -Ancestors @($(if ($Parent) { @{ InstanceId = $Parent; Class = $parentClass } })) | Should -BeExactly $R
    }
    It 'keeps an old USB disk and an old network adapter' {
      Test-GhostExcluded -Device @{ InstanceId = 'USBSTOR\DISK&VEN_SANDISK\4C53&0'; Class = 'DiskDrive' } -Ancestors @(@{ InstanceId = 'USB\VID_0781&PID_5567\4C53'; Class = 'USB' }) | Should -BeExactly ''
      Test-GhostExcluded -Device @{ InstanceId = 'PCI\VEN_8086&DEV_15BC\3&11583659&0&FE'; Class = 'Net' } -Ancestors @() | Should -BeExactly ''
      Test-GhostExcluded -Device @{ InstanceId = 'PCI\VEN_8086&DEV_15BC\3&1'; Class = 'Net' } -Ancestors $null | Should -BeExactly ''
    }
    It 'ghostList answers every non-present device with its reason, the ones that may go first, in ASCII bytes with the real names (Task 5''s shape, RD-R21)' {
      $r = New-ActionRun ghostList; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $g = @($r.Data.Ghosts)
      @($g.InstanceId) | Should -Be @('USB\VID_0781&PID_5567\4C53', 'USBSTOR\DISK&VEN_SANDISK\4C53&0', 'BTHENUM\{0000110b}_X\7&1', 'HID\{00001124}_VID&0002046D\8&1', 'HID\VID_046D&PID_B023&COL01\9&1')
      @($g.Excluded) | Should -Be @('', '', 'bluetooth', 'bluetooth', 'bluetooth')
      $g[0].Class | Should -Be 'USB'; $g[0].Name | Should -Be 'SanDisk Cruzer'; $g[2].Name | Should -BeExactly 'אוזניות של דנה'
      $script:gcCommands['ghostList'] | Should -Match 'Get-PnpDevice'; $script:gcCommands['ghostList'] | Should -Match 'DEVPKEY_Device_Parent'
      @($script:nativeLines).Count | Should -Be 0; $r.Findings.Count | Should -Be 0
      Write-ToolResult -Run $r -Outcome 'Done' | Should -BeTrue
      @([IO.File]::ReadAllBytes($r.ResultPath) | Where-Object { $_ -gt 0x7E }).Count | Should -Be 0
      [IO.File]::ReadAllText($r.ResultPath) | Should -Match '\\u05d0\\u05d5\\u05d6'
      @((Read-ToolJsonFile -Path $r.ResultPath).Data.Ghosts)[2].Name | Should -BeExactly 'אוזניות של דנה'
      # No ghost at all is an empty list, which the window accepts.
      $script:gc['ghostList'] = @{ Total = 0; Items = @(); Nodes = @() }
      $q = New-ActionRun ghostList; $null = Invoke-ToolSteps -Run $q; $null = Write-ToolResult -Run $q -Outcome 'Done'
      [IO.File]::ReadAllText($q.ResultPath) | Should -Match '"Ghosts":\s+\[\s*\]'
    }
    It 'a long list is capped so result.json stays under 1 MB, and it says so' {
      $items = @(for ($i = 0; $i -lt 1500; $i++) {
          @{ InstanceId = ('SWD\MMDEVAPI\{{0.0.1.00000000}}.{{38A66F1E-F6A6-45A6-B381-9CEB86AB{0:X4}}}' -f $i); Class = 'AudioEndpoint'; Name = ('Speakers ' * 6) + $i; Parent = '' } })
      $items += @(for ($i = 0; $i -lt 600; $i++) {
          @{ InstanceId = ('USB\VID_0781&PID_5567&MI_00\7&2B4F3A1C&0&{0:D4}_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' -f $i); Class = 'USB'; Name = ('USB Mass Storage Device ' * 3) + $i; Parent = '' } })
      $script:gc['ghostList'] = @{ Total = 6000; Items = $items; Nodes = @() }
      $r = New-ActionRun ghostList; $null = Invoke-ToolSteps -Run $r
      @($r.Data.Ghosts).Count | Should -Be $script:GhostListMax
      @($r.Data.Ghosts | Where-Object { $_.Excluded -eq '' }).Count | Should -Be 600   # the ones that may go come first
      @(@($r.Data.Ghosts)[0..599] | Where-Object { $_.Excluded -ne '' }).Count | Should -Be 0
      (Get-FindingArgs $r 'ghostListCapped')[0] | Should -Be @([string]$script:GhostListMax, '6000')
      $null = Write-ToolResult -Run $r -Outcome 'Done'; (Get-Item $r.ResultPath).Length | Should -BeLessThan 1MB
      (Read-ToolJsonFile $r.ResultPath).Data.Ghosts.Count | Should -Be $script:GhostListMax
    }
    It 'the worst case still fits: Hebrew names and classes as \u escapes, ids full of escaped characters (review M4)' {
      # Every character of these costs six bytes in result.json; the list stops at its byte budget, whatever the count.
      $pair = [char]::ConvertFromUtf32(0x1F3A7)
      $items = @(for ($i = 0; $i -lt 1500; $i++) {
          @{ InstanceId = ('USB\' + ('&' * 190) + ('{0:D5}' -f $i)); Class = ('ב' * 200); Name = (($pair + 'א') * 400); Parent = '' } })
      $script:gc['ghostList'] = @{ Total = 1500; Items = $items; Nodes = @() }
      $r = New-ActionRun ghostList; $null = Invoke-ToolSteps -Run $r
      $listed = @($r.Data.Ghosts).Count
      $listed | Should -BeGreaterThan 100; $listed | Should -BeLessThan $script:GhostListMax
      (Get-FindingArgs $r 'ghostListCapped')[0] | Should -Be @([string]$listed, '1500')
      $first = @($r.Data.Ghosts)[0]; $first.Name.Length | Should -BeLessOrEqual 128; $first.Class.Length | Should -BeLessOrEqual 64
      $null = Write-ToolResult -Run $r -Outcome 'Done'; (Get-Item $r.ResultPath).Length | Should -BeLessThan 1MB
      @((Read-ToolJsonFile -Path $r.ResultPath).Data.Ghosts).Count | Should -Be $listed
    }
    It 'a ghost name is cut to 128 characters before its escapes, never between the halves of a surrogate pair (review M4)' {
      $huge = ('א' * 127) + [char]::ConvertFromUtf32(0x1F3A7) + ('ב' * 10000)
      $script:gc['ghostList'] = @{ Total = 1; Items = @(@{ InstanceId = 'USB\VID_1234&PID_0001\1'; Class = 'USB'; Name = $huge; Parent = '' }); Nodes = @() }
      $r = New-ActionRun ghostList; $null = Invoke-ToolSteps -Run $r
      @($r.Data.Ghosts)[0].Name | Should -BeExactly ('א' * 127)
    }
    It 'a ghost list that cannot be read is no answer (the window shows the failure)' {
      $script:gcFail['ghostList'] = 'timed out'; $r = New-ActionRun ghostList; $null = Invoke-ToolSteps -Run $r
      $r.Data.ContainsKey('Ghosts') | Should -BeFalse; Get-StepStatus $r 'ghostList' | Should -Be 'timedout'
      Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED'
    }
    It 'writes the CSV as UTF-8 with BOM, Hebrew names intact, before anything is removed' {
      $r = New-ActionRun ghostRemove -Options @{ Ids = @('USB\VID_0781&PID_5567\4C53') }
      Invoke-ToolStepGhostCsv -Run $r | Should -Be 'done'
      $csv = @(Get-ChildItem $r.SessionDir -Filter 'ghost-devices-*.csv')
      $csv.Count | Should -Be 1; $csv[0].Name | Should -Match '^ghost-devices-\d{8}-\d{6}\.csv$'
      $b = [IO.File]::ReadAllBytes($csv[0].FullName); $b[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
      $text = [IO.File]::ReadAllText($csv[0].FullName); $text | Should -Match 'אוזניות של דנה'
      $rows = @(ConvertFrom-Csv -InputObject @($text -split "`r`n" | Where-Object { $_ }))
      $rows.Count | Should -Be 5
      ($rows | Where-Object InstanceId -eq 'USB\VID_0781&PID_5567\4C53').Status | Should -Be 'remove'
      ($rows | Where-Object InstanceId -eq 'USBSTOR\DISK&VEN_SANDISK\4C53&0').Status | Should -Be 'kept'
      ($rows | Where-Object InstanceId -eq 'BTHENUM\{0000110b}_X\7&1').Status | Should -Be 'excluded (bluetooth)'
      $script:nativeLines | Should -BeNullOrEmpty; Get-FindingCodes $r | Should -BeNullOrEmpty; $r.Files.GhostCsv | Should -Be $csv[0].FullName
    }
    It 'a device name or class that a spreadsheet would run as a formula is written as text (review M9)' {
      foreach ($bad in '=HYPERLINK("http://x","y")', '+SUM(1)', '-2+3', '@A1') {
        $script:gc['ghostList']['Items'] += @{ InstanceId = ('USB\VID_9999&PID_000{0}\X' -f $bad.Length); Class = $bad; Name = $bad; Parent = '' }
      }
      $r = New-ActionRun ghostRemove -Options @{ Ids = @() }
      Invoke-ToolStepGhostCsv -Run $r | Should -Be 'done'
      $text = [IO.File]::ReadAllText(@(Get-ChildItem $r.SessionDir -Filter 'ghost-devices-*.csv')[0].FullName)
      $rows = @(ConvertFrom-Csv -InputObject @($text -split "`r`n" | Where-Object { $_ }))
      foreach ($bad in '=HYPERLINK("http://x","y")', '+SUM(1)', '-2+3', '@A1') {
        $row = $rows | Where-Object { $_.InstanceId -eq ('USB\VID_9999&PID_000{0}\X' -f $bad.Length) }
        $row.Name | Should -BeExactly ("'" + $bad); $row.Class | Should -BeExactly ("'" + $bad)
      }
      ($rows | Where-Object InstanceId -eq 'USB\VID_0781&PID_5567\4C53').Name | Should -BeExactly 'SanDisk Cruzer'   # an ordinary name is unchanged
    }
    It 'a device list that cannot be saved removes nothing (Review Focus 3, <Why>)' -ForEach @(
      @{ Why = 'no stick: the local fallback folder' }, @{ Why = 'the list cannot be read' }) {
      if ($Why -eq 'the list cannot be read') { $script:gcFail['ghostList'] = 'access denied' }
      $r = New-ActionRun ghostRemove -Options @{ Ids = @('USB\VID_0781&PID_5567\4C53') } -Break $(if ($Why -like 'no stick*') { $Why } else { '' })
      $null = Invoke-ToolSteps -Run $r; $script:nativeLines | Should -BeNullOrEmpty; Get-FindingCodes $r | Should -Contain 'ghostCsvFailed'
      Get-StepStatus $r 'ghostRemove' | Should -Be 'skipped'; $r.Data.Abort | Should -BeTrue
      @(Get-ChildItem $r.SessionDir -Filter 'ghost-devices-*.csv' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
    It 'a device list step that throws removes nothing either (Abort is set first, cleared only on success)' {
      Mock ConvertTo-Csv { throw 'unexpected' }
      $r = New-ActionRun ghostRemove -Options @{ Ids = @('USB\VID_0781&PID_5567\4C53') }; $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -BeNullOrEmpty; Get-FindingCodes $r | Should -Be @('ghostCsvFailed'); Get-StepStatus $r 'ghostRemove' | Should -Be 'skipped'
      Mock Get-ToolGhostDevices { throw 'unexpected' }
      $q = New-ActionRun ghostRemove -Options @{ Ids = @('USB\VID_0781&PID_5567\4C53') }; $null = Invoke-ToolSteps -Run $q
      $script:nativeLines | Should -BeNullOrEmpty; Get-FindingCodes $q | Should -Be @('stepFailed'); Get-StepStatus $q 'ghostRemove' | Should -Be 'skipped'
      $q.Data.Abort | Should -BeTrue
    }
    It 'removes only ticked ids that are still non-present and not excluded; 3010 is success' {
      # The list: the USB stick (a ghost), a Bluetooth headset (left out), a device that is present again.
      $script:exit['pnputil.exe'] = 3010
      $r = New-ActionRun ghostRemove -Options @{ Ids = @('USB\VID_0781&PID_5567\4C53', 'BTHENUM\{0000110b}_X\7&1', 'PCI\VEN_10EC&DEV_8168\4&1') }
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:nativeLines | Should -Be @('pnputil.exe /remove-device "USB\VID_0781&PID_5567\4C53"')
      Get-FindingCodes $r | Should -Contain 'ghostsRemoved'; (Get-FindingArgs $r 'ghostsRemoved')[0] | Should -Be @('1'); $r.RestartRequired | Should -BeTrue
      Should -Invoke Invoke-ToolJsonChild -ParameterFilter { $Name -eq 'ghostList' } -Times 2 -Exactly   # the CSV's list, then listed again
    }
    It 'an id holding a quote, or that is no device id, is skipped; a failed removal is a WARN; 0 needs no restart' {
      $script:gc['ghostList']['Items'] += @{ InstanceId = 'ROOT\X"Y\1'; Class = 'System'; Name = 'odd'; Parent = '' }
      $r = New-ActionRun ghostRemove -Options @{ Ids = @('ROOT\X"Y\1', 'USB\VID_0781&PID_5567\4C53', 'USBSTOR\DISK&VEN_SANDISK\4C53&0', 'bad id\') }
      Mock Invoke-ToolNative {
        $file = [IO.Path]::GetFileName($FilePath); [void]$script:nativeLines.Add(('{0} {1}' -f $file, $ArgumentList).Trim())
        @{ ExitCode = $(if ($ArgumentList -like '*USBSTOR*') { 5 } else { 0 }); TimedOut = $false; OutputPath = $null } }
      $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -Be @('pnputil.exe /remove-device "USB\VID_0781&PID_5567\4C53"', 'pnputil.exe /remove-device "USBSTOR\DISK&VEN_SANDISK\4C53&0"')
      (Get-FindingArgs $r 'ghostRemoveFailed') | ForEach-Object { $_[0] } | Should -Be @('ROOT\X"Y\1', 'USBSTOR\DISK&VEN_SANDISK\4C53&0', 'bad id\')
      (Get-FindingArgs $r 'ghostsRemoved')[0] | Should -Be @('1'); $r.RestartRequired | Should -BeFalse
      Get-StepStatus $r 'ghostRemove' | Should -Be 'warn'
    }
    It 'Options that are no list of ids remove nothing' {
      $r = New-ActionRun ghostRemove -Options @{ Ids = @{ x = 1 } }; $null = Invoke-ToolSteps -Run $r
      @($script:nativeLines).Count | Should -Be 0; (Get-FindingArgs $r 'ghostsRemoved')[0] | Should -Be @('0')
    }
  }
}
