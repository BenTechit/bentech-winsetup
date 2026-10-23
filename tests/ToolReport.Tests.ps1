# tests/ToolReport.Tests.ps1
# Repair & diagnostics Task 8 (repair spec 6.8; rulings RD-R12, RD-R13, RD-R20, RD-R21, RD-R23): the Quick and Full
# reports: the section collectors (src\Repair\ToolCollect.ps1), the flags, the event grouping, the AI-ready core, its
# size limit, the data JSON, raw\ and the zip (src\Repair\ToolReport.ps1), and their catalog rows.
#
# SAFETY: this runs on Ben's real PC. For real, the collectors read this PC's event logs, programs, drivers, devices,
# disks, network, services, users and CIM, start PowerShell grandchildren (Get-PhysicalDisk, Get-WinEvent,
# Get-WindowsDriver, Get-Printer, Get-MpComputerStatus, Get-NetTCPConnection, ...) and run systeminfo, vssadmin, gpresult,
# dsregcmd, powercfg, wevtutil and msinfo32. Here nothing is started, nothing is changed and no answer comes from this PC:
#   - Invoke-ToolJsonChild answers from $script:gc (by grandchild name: an answer's Data, or a whole answer when it has
#     an Ok key; $script:gcFail makes one fail or time out) and records each name and command; Invoke-ToolNative records
#     its calls in $script:native and answers exit 0; Invoke-External and Invoke-PowerShellChild are never reached;
#   - Get-CimInstance answers from $script:cim (by class name; a class it does not know is blocked); the registry is
#     read through Get-RebootRegistryValue ($script:reg, '<path>|<name>'), Read-ToolRegistryKey and
#     Read-ToolRegistrySubkeys ($script:regKeys, $script:regSubkeys); Get-Service answers $script:services;
#     Test-ToolInternet and Test-ToolTcpHosts are recorders; Get-ToolBcdState, Get-ToolReAgentState,
#     Get-ToolDiskEventCount, Get-ToolBitLockerChip, Confirm-SecureBootUEFI, Get-LocalGroupMember, Get-SignedInUserName,
#     Get-ToolUserSid, Get-SmartAppControlState, Get-ServicingRebootSignals and Read-ToolCbsLog answer fixed values;
#     Wait-SetupDelay does not sleep; the files the collectors list (crash dumps, hosts, logs, startup folders) are in
#     $TestDrive ($script:ToolReportPaths points there);
#   - safety nets as in ToolEngine.Tests, plus the hang-prone and event cmdlets a collector must never call in its own
#     process (Get-WinEvent, Get-PnpDevice, Get-NetAdapter, Get-NetTCPConnection, Get-Printer,
#     Get-WindowsDriver, Get-MpComputerStatus): each records its name in $script:blocked, then throws; AfterEach asserts
#     that nothing was blocked;
#   - every file a test writes is under $TestDrive (the run folders under $TestDrive\Root\Tool, the "stick"
#     $TestDrive\Stick with its BenTech-Reports and session folder).
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Common\Config', 'State\State', 'Steps\Winget', 'Engine\Reboot',
                 'UI\StartScreen', 'Toolbox\Strings', 'Entry\Cleanup', 'Detect\Detection', 'Detect\PcName', 'Report\Report', 'Repair\ToolEngine',
                 'Repair\ToolChecks', 'Repair\ToolSafety', 'Repair\ToolRepairs', 'Repair\ToolAdvanced', 'Repair\ToolCollect', 'Repair\ToolReport') {
    . "$PSScriptRoot\..\src\$f.ps1"
  }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:root = Join-Path $TestDrive 'Root'
  $script:stickRoot = (Join-Path $TestDrive 'Stick') + '\'
  $script:reports = Join-Path $TestDrive 'Stick\BenTech-Reports'
  $script:sessionDir = Join-Path $script:reports 'DELL-7HX2K93_7HX2K93_2026-10-23_1400'
  $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
  $script:collectFile = "$PSScriptRoot\..\src\Repair\ToolCollect.ps1"
  $script:reportFile = "$PSScriptRoot\..\src\Repair\ToolReport.ps1"
  $script:sid = 'S-1-5-21-1-2-3-1001'
  # The real code of a function the collectors' tests mock (Pester 6 never falls through to the original).
  $script:realTcpHosts = ${function:Test-ToolTcpHosts}
  # Hebrew built from code points, so a test can name it without depending on how this file is read.
  $script:hebStopped = -join ([char[]](0x05D4, 0x05E9, 0x05D9, 0x05E8, 0x05D5, 0x05EA))   # the service (as in the sample's 07 lines)
  $script:hebProgram = -join ([char[]](0x05D7, 0x05E9, 0x05D1, 0x05E9, 0x05D1, 0x05EA))   # a Hebrew accounting program's name

  # A JSON fixture as nested ordered dictionaries (Facts keep their order) and arrays (an empty or one-item array stays one).
  function ConvertTo-OrderedDeep {
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
      $table = [ordered]@{}
      foreach ($p in $InputObject.PSObject.Properties) { $table[$p.Name] = ConvertTo-OrderedDeep -InputObject $p.Value }
      return $table
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
      $table = [ordered]@{}
      foreach ($k in @($InputObject.Keys)) { $table[$k] = ConvertTo-OrderedDeep -InputObject $InputObject[$k] }
      return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable]) { return , @(foreach ($i in $InputObject) { ConvertTo-OrderedDeep -InputObject $i }) }
    return $InputObject
  }
  function Read-ReportFixture {
    param([string]$Name)
    ConvertTo-OrderedDeep -InputObject (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $script:fixtures $Name), [Text.Encoding]::UTF8)))
  }
  # A deep copy of -Report with Items.<Item> set to -Value.
  function Set-ReportItem {
    param($Report, [string]$Item, $Value)
    $copy = ConvertTo-OrderedDeep -InputObject (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Report -Depth 30 -Compress))
    $copy['Items'][$Item] = $Value
    $copy
  }

  $script:sample = Read-ReportFixture 'report-sections-sample.json'
  $script:sample['Findings'] = @(Get-ReportFlags -Report $script:sample -Config $script:cfg)
  $script:huge = Read-ReportFixture 'report-sections-huge.json'
  $script:huge['Findings'] = @(Get-ReportFlags -Report $script:huge -Config $script:cfg)
  $script:core = Format-ReportCore -Report $script:sample -Kind full

  function New-TestArgs {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$RunId)
    @{ Version = 1; Action = $Action; RunId = $RunId
       DeadlineUtc = [datetime]::UtcNow.AddMinutes(600).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
       BudgetSeconds = 36000; SessionDir = $script:sessionDir; StickRoot = $script:stickRoot; Complaint = ''; Done = @()
       Identity = @{ Key = 'SN-7HX2K93'; FolderPart = '7HX2K93'; Serial = '7HX2K93'; BiosUuid = '4C4C4544-0048-5810-8032-B7C04F4B3933'
                     ComputerName = 'DELL-7HX2K93'; Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; Brand = 'DELL' }
       Machine = @{ IsLaptop = $true; OsBuild = 26100; Arch = 'x64' }
       Strip = @{ Restart = 'ok'; Free = 'ok'; BitLocker = 'warn'; Internet = 'ok'; Disk = 'ok' }
       Options = @{} }
  }

  # A run of -Action (quickReport or fullReport) in a fresh run folder, with a fresh session folder on the fake stick,
  # started at 23/10/2026 14:05:30. -SameMinute <run>: the same session folder and start minute as that run (the
  # folder is kept).
  function New-ActionRun {
    param([Parameter(Mandatory)][string]$Action, [hashtable]$SameMinute)
    $runId = '20261023-140530-' + $Action
    if ($null -ne $SameMinute) { $runId = '20261023-140545-' + $Action }
    $dir = Join-Path $script:root "Tool\$runId"
    if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    [void][IO.Directory]::CreateDirectory($dir)
    if ($null -eq $SameMinute -and [IO.Directory]::Exists($script:sessionDir)) { [IO.Directory]::Delete($script:sessionDir, $true) }
    $run = New-ToolRun -ToolArgs (New-TestArgs -Action $Action -RunId $runId) -Config $script:cfg -Root $script:root
    $run.StartedAt = $(if ($null -ne $SameMinute) { $SameMinute.StartedAt.AddSeconds(15) } else { [datetime]::new(2026, 10, 23, 14, 5, 30) })
    $null = New-ToolSessionDir -Run $run
    $run
  }

  # A Full report run whose sections are the sample's (Data.Report), with the sample's complaint and visit.
  function New-SampleRun {
    param([hashtable]$SameMinute)
    $run = New-ActionRun fullReport -SameMinute $SameMinute
    $copy = Read-ReportFixture 'report-sections-sample.json'
    $sections = [ordered]@{}
    foreach ($id in @($copy['Sections'].Keys)) {
      $s = $copy['Sections'][$id]
      $items = [ordered]@{}
      # The sample keeps its items in one place; a collector's section holds its own.
      if ($id -eq '01') { foreach ($k in @($copy['Items'].Keys)) { $items[$k] = $copy['Items'][$k] } }
      $s['Items'] = $items
      $sections[$id] = $s
    }
    $run.Data['Report'] = $sections
    $run.Args['Complaint'] = [string]$copy['Complaint']
    $run.Args['Done'] = @($copy['Done'])
    $run
  }

  # What every grandchild answers on this healthy Dell (the Data of Invoke-ToolJsonChild, by grandchild name).
  function Get-DefaultAnswers {
    $none = @{ Error = ''; Total = 0; Rows = @(); Groups = @() }
    @{
      activation   = @{ Statuses = @(1) }
      diskInfo     = @{ SystemDisks = @(0); Items = @(
          @{ DeviceId = '0'; Model = 'Samsung SSD 980 PRO 512GB'; Serial = 'S4EWNX0R123456'; Media = 'SSD'; Bus = 'NVMe'; Health = 'Healthy'; Size = 512110190592; Firmware = '5B2QGXA7' }
          @{ DeviceId = '1'; Model = 'SanDisk Cruzer Glide'; Serial = '4C530001'; Media = 'Unspecified'; Bus = 'USB'; Health = 'Healthy'; Size = 30752000000; Firmware = '1.00' }) }
      diskCounters = @{ Items = @(
          @{ DeviceId = '0'; Wear = 7; Temperature = 38; TemperatureMax = 70; ReadErrors = 0; WriteErrors = 0; PowerOnHours = 2210 }
          @{ DeviceId = '1'; Wear = $null; Temperature = $null; TemperatureMax = $null; ReadErrors = $null; WriteErrors = $null; PowerOnHours = $null }) }
      volumeState  = @{ HealthStatus = 0; OperationalStatus = @(2); Dirty = $false }
      partitions   = @{ Items = @(
          @{ Disk = 0; Number = 1; GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; MbrType = $null; Size = 104857600; Letter = ''; IsSystem = $true; IsBoot = $false }
          @{ Disk = 0; Number = 2; GptType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'; MbrType = $null; Size = 16777216; Letter = ''; IsSystem = $false; IsBoot = $false }
          @{ Disk = 0; Number = 3; GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; MbrType = $null; Size = 511000000000; Letter = 'C'; IsSystem = $false; IsBoot = $true }
          @{ Disk = 0; Number = 4; GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'; MbrType = $null; Size = 750000000; Letter = ''; IsSystem = $false; IsBoot = $false }) }
      bootEvents   = @{
        boot  = @{ Error = ''; Total = 1; Groups = @(); Rows = @(@{ Provider = 'Microsoft-Windows-Diagnostics-Performance'; Id = 100; Level = 2; Time = '2026-10-22T08:01:40'
                                                                 Data = @{ BootTime = '18200'; MainPathBootTime = '9100'; BootPostBootTime = '9100' }; Props = @() }) }
        power = @{ Error = ''; Total = 13; Rows = @(); Groups = @(
            @{ Provider = 'EventLog'; Id = 6005; Level = 4; Count = 12; First = '2026-10-01T08:00:00'; Last = '2026-10-22T08:01:00'; Message = 'The Event log service was started.' }
            @{ Provider = 'EventLog'; Id = 6008; Level = 2; Count = 1; First = '2026-10-21T11:43:00'; Last = '2026-10-21T11:43:00'; Message = 'The previous system shutdown was unexpected.' }) } }
      wuResults    = @{ LastSearch = '2026-10-23T09:12:00'; LastInstall = '2026-10-21T03:10:00' }
      wuEvents     = @{ wu = @{ Error = ''; Total = 4; Rows = @(); Groups = @(@{ Provider = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; Level = 4; Count = 4
                                                                              First = '2026-10-02T03:10:00'; Last = '2026-10-21T03:10:00'; Message = 'Installation Successful' }) }
                        wuFailed = $none }
      devices      = @{ Items = @(@{ InstanceId = 'PCI\VEN_8086&DEV_51F1\3&11583659&0&A3'; Class = 'Net'; Name = 'Intel(R) Wi-Fi 6E AX211 160MHz'; Status = 'Error'; ConfigManagerErrorCode = 28 }) }
      ghostCount   = @{ Items = @(@{ Class = 'USB'; Count = 12 }, @{ Class = 'HIDClass'; Count = 9 }, @{ Class = 'SoftwareDevice'; Count = 19 }) }
      pnpEvents    = @{ pnp = $none }
      drivers      = @{ Items = @(
          @{ Driver = 'oem12.inf'; Original = 'iigd_dch.inf'; Provider = 'Intel Corporation'; Class = 'Display'; Version = '31.0.101.5186'; Date = '2024-01-10' }
          @{ Driver = 'oem3.inf'; Original = 'rt640x64.inf'; Provider = 'Realtek'; Class = 'Net'; Version = '10.1.505.2015'; Date = '2015-05-05' }) }
      eventGroups  = @{
        system      = @{ Error = ''; Total = 3; Rows = @(); Groups = @(@{ Provider = 'Service Control Manager'; Id = 7031; Level = 2; Count = 3; First = '2026-10-20T09:15:00'
                                                                          Last = '2026-10-22T18:30:00'; Message = ($script:hebStopped + ' x') }) }
        application = @{ Error = ''; Total = 2; Rows = @(); Groups = @(@{ Provider = 'Application Error'; Id = 1000; Level = 2; Count = 2; First = '2026-10-18T10:02:00'
                                                                          Last = '2026-10-19T16:40:00'; Message = 'Faulting application name: chrome.exe' }) } }
      crashEvents  = @{
        kp41     = @{ Error = ''; Total = 1; Groups = @(); Rows = @(@{ Provider = 'Microsoft-Windows-Kernel-Power'; Id = 41; Level = 1; Time = '2026-10-21T11:42:10'; Data = @{ BugcheckCode = '0' }; Props = @() }) }
        bugcheck = $none
        whea     = $none
        shutdown = @{ Error = ''; Total = 1; Groups = @(); Rows = @(@{ Provider = 'EventLog'; Id = 6008; Level = 2; Time = '2026-10-21T11:43:00'; Data = @{}; Props = @() }) }
        appError = @{ Error = ''; Total = 2; Groups = @(); Rows = @(
            @{ Provider = 'Application Error'; Id = 1000; Level = 2; Time = '2026-10-19T16:40:00'; Data = @{}; Props = @('chrome.exe', 'chrome_elf.dll', '0xc0000005') }
            @{ Provider = 'Application Error'; Id = 1000; Level = 2; Time = '2026-10-18T10:02:00'; Data = @{}; Props = @('chrome.exe', 'ntdll.dll', '0xc0000374') }) }
        appHang  = $none }
      reliability  = @{ Items = @(@{ Source = 'Application Error'; EventId = 1000; Product = 'chrome.exe'; Time = '2026-10-19T16:40:00'; Message = 'Faulting application chrome.exe' }) }
      netSettings  = @{ Items = @(@{ Alias = 'Wi-Fi'; Guid = '{5D36E972-E325-11CE-BFC1-08002BE10318}'; Mac = 'A4-BB-6D-12-34-57'; Index = 7; Ipv4Dhcp = $true; Ipv6Dhcp = $true
                                     Addresses = @(); Gateways = @(); Dns = @() }) }
      netState     = @{ Errors = @()
                        Profiles = @(@{ Name = 'Cohen_Home_5G'; Alias = 'Wi-Fi'; Category = 'Private'; Ipv4 = 'Internet'; Ipv6 = 'NoTraffic' })
                        Firewall = @(@{ Name = 'Domain'; Enabled = 'True' }, @{ Name = 'Private'; Enabled = 'True' }, @{ Name = 'Public'; Enabled = 'True' })
                        Addresses = @(@{ Alias = 'Wi-Fi'; Ip = '192.168.1.23'; Prefix = 24; Origin = 'Dhcp' })
                        Gateways = @(@{ Alias = 'Wi-Fi'; NextHop = '192.168.1.1'; Metric = 0 })
                        Dns = @(@{ Alias = 'Wi-Fi'; Servers = @('192.168.1.1') }) }
      tcp          = @{ Items = @(@{ Process = 'chrome'; State = 'Established'; Count = 34 }, @{ Process = 'svchost'; State = 'Listen'; Count = 12 }) }
      # As the brief has it: the grandchild's row with the task's arguments, which the report must never show.
      tasks        = @{ Items = @(@{ Name = 'Agent'; Path = '\'; State = 'Ready'; Execute = 'C:\Agent\agent.exe'; Arguments = '--token abc /password x' }) }
      appx         = @{ Items = @(@{ Name = 'Microsoft.WindowsCalculator'; Version = '11.2409.0.0'; NonRemovable = $false }) }
      features     = @{ Items = @('NetFx4-AdvSrvs', 'Printing-PrintToPDFServices-Features') }
      printers     = @{ Items = @(@{ Name = 'HP LaserJet'; Driver = 'HP Universal Printing PCL 6'; Port = 'IP_192.168.1.50'; Shared = $false; Type = 'Local' }) }
      defender     = @{ RealTime = $true; AntivirusEnabled = $true; AMServiceEnabled = $true; SignatureAge = 1; Mode = 'Normal'; Tamper = $true; SignatureVersion = '1.419.12.0' }
      wuLog        = @{ Done = $true }
    }
  }

  # The CIM classes the collectors read (by class name).
  function Get-DefaultCim {
    $boot = (Get-Date).AddDays(-1.3)
    @{
      Win32_ComputerSystem  = @([pscustomobject]@{ Name = 'DELL-7HX2K93'; Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; PartOfDomain = $false; Domain = 'WORKGROUP'
                                                  Workgroup = 'WORKGROUP'; TotalPhysicalMemory = 17012899840; SystemType = 'x64-based PC'; UserName = 'DELL-7HX2K93\Dana' })
      Win32_OperatingSystem = @([pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; OSArchitecture = '64-bit'; LastBootUpTime = $boot; MUILanguages = @('he-IL')
                                                  FreePhysicalMemory = 9338880; TotalVisibleMemorySize = 16614160 })
      Win32_BIOS            = @([pscustomobject]@{ Manufacturer = 'Dell Inc.'; SMBIOSBIOSVersion = '1.21.0'; ReleaseDate = [datetime]::new(2026, 8, 12); SerialNumber = '7HX2K93' })
      Win32_BaseBoard       = @([pscustomobject]@{ Manufacturer = 'Dell Inc.'; Product = '0K4W0G'; SerialNumber = '/7HX2K93/CNCMK0034R00AB/' })
      Win32_Processor       = @([pscustomobject]@{ Name = '13th Gen Intel(R) Core(TM) i5-1345U'; NumberOfCores = 10; NumberOfLogicalProcessors = 12; MaxClockSpeed = 1600 })
      Win32_PhysicalMemory  = @([pscustomobject]@{ Capacity = 8589934592; Speed = 5200; SerialNumber = '80AD0123'; Manufacturer = 'SK Hynix' }
                                [pscustomobject]@{ Capacity = 8589934592; Speed = 5200; SerialNumber = '80AD0124'; Manufacturer = 'SK Hynix' })
      Win32_VideoController = @([pscustomobject]@{ Name = 'Intel(R) Iris(R) Xe Graphics'; DriverVersion = '31.0.101.5186'; InfFilename = 'oem12.inf' })
      WmiMonitorID          = @([pscustomobject]@{ ManufacturerName = [uint16[]]@(68, 69, 76, 0); UserFriendlyName = [uint16[]]@(68, 69, 76, 76, 32, 80, 50, 52, 50, 50, 72, 0)
                                                  SerialNumberID = [uint16[]]@(70, 88, 51, 52, 0); YearOfManufacture = 2023 })
      Win32_Battery         = @([pscustomobject]@{ Name = 'DELL VKYJX2B'; EstimatedChargeRemaining = 87 })
      BatteryStaticData     = @([pscustomobject]@{ InstanceName = 'ACPI\PNP0C0A\1_0'; DesignedCapacity = 54000; SerialNumber = '1234'; DeviceName = 'DELL VKYJX2B' })
      BatteryFullChargedCapacity = @([pscustomobject]@{ InstanceName = 'ACPI\PNP0C0A\1_0'; FullChargedCapacity = 47520 })
      Win32_Tpm             = @([pscustomobject]@{ IsEnabled_InitialValue = $true; IsActivated_InitialValue = $true; SpecVersion = '2.0, 0, 1.59' })
      Win32_DeviceGuard     = @([pscustomobject]@{ VirtualizationBasedSecurityStatus = 2; SecurityServicesRunning = @(2) })
      Win32_Volume          = @([pscustomobject]@{ DriveLetter = 'C:'; Label = ''; FileSystem = 'NTFS'; Capacity = 510872850432; FreeSpace = 225914855424; DirtyBitSet = $false; DriveType = 3 }
                                [pscustomobject]@{ DriveLetter = 'E:'; Label = 'BENTECH'; FileSystem = 'FAT32'; Capacity = 30752000000; FreeSpace = 21582000000; DirtyBitSet = $false; DriveType = 2 })
      Win32_PageFileSetting = @()
      Win32_PageFileUsage   = @([pscustomobject]@{ Name = 'C:\pagefile.sys'; AllocatedBaseSize = 8192; CurrentUsage = 500; PeakUsage = 1200 })
      SystemRestore         = @([pscustomobject]@{ CreationTime = '20261020090000.000000-000'; Description = 'Windows Update'; SequenceNumber = 7 })
      Win32_QuickFixEngineering = @([pscustomobject]@{ HotFixID = 'KB5044284'; InstalledOn = '10/15/2026'; Description = 'Security Update' }
                                    [pscustomobject]@{ HotFixID = 'KB5043080'; InstalledOn = '9/10/2026'; Description = 'Update' })
      Win32_PerfFormattedData_PerfOS_Processor = @([pscustomobject]@{ Name = '_Total'; PercentProcessorTime = 7 })
      Win32_PerfFormattedData_PerfOS_Memory = @([pscustomobject]@{ AvailableMBytes = 9120; PercentCommittedBytesInUse = 41 })
      Win32_PerfFormattedData_PerfDisk_PhysicalDisk = @([pscustomobject]@{ Name = '_Total'; PercentDiskTime = 3; AvgDiskQueueLength = 0 })
      Win32_PerfFormattedData_PerfProc_Process = @(
        [pscustomobject]@{ Name = '_Total'; IDProcess = 0; PercentProcessorTime = 100; WorkingSetPrivate = 5000000000 }
        [pscustomobject]@{ Name = 'Idle'; IDProcess = 0; PercentProcessorTime = 93; WorkingSetPrivate = 8192 }
        [pscustomobject]@{ Name = 'chrome'; IDProcess = 100; PercentProcessorTime = 4; WorkingSetPrivate = 1268776960 }
        [pscustomobject]@{ Name = 'MsMpEng'; IDProcess = 200; PercentProcessorTime = 2; WorkingSetPrivate = 210000000 })
      Win32_Service         = @(
        [pscustomobject]@{ Name = 'AgentSvc'; DisplayName = 'Agent Service'; StartMode = 'Auto'; State = 'Running'; PathName = '"C:\Program Files\Agent\agentsvc.exe" --token abc /password x' }
        [pscustomobject]@{ Name = 'wuauserv'; DisplayName = 'Windows Update'; StartMode = 'Manual'; State = 'Running'; PathName = 'C:\WINDOWS\system32\svchost.exe -k netsvcs -p' }
        [pscustomobject]@{ Name = 'sppsvc'; DisplayName = 'Software Protection'; StartMode = 'Auto'; State = 'Stopped'; PathName = 'C:\WINDOWS\system32\sppsvc.exe' })
      AntiVirusProduct      = @([pscustomobject]@{ displayName = 'Microsoft Defender Antivirus'; productState = 397568; pathToSignedProductExe = 'windowsdefender://' })
      Win32_UserAccount     = @(
        [pscustomobject]@{ Name = 'Dana'; SID = 'S-1-5-21-1-2-3-1001'; Disabled = $false; LocalAccount = $true }
        [pscustomobject]@{ Name = 'Administrator'; SID = 'S-1-5-21-1-2-3-500'; Disabled = $true; LocalAccount = $true }
        [pscustomobject]@{ Name = 'Guest'; SID = 'S-1-5-21-1-2-3-501'; Disabled = $true; LocalAccount = $true })
    }
  }

  # Single registry values ('<path>|<name>' -> value), whole keys and their subkeys.
  function Get-DefaultRegistry {
    $nt = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $user = 'Registry::HKEY_USERS\' + $script:sid
    @{
      "$nt|ProductName" = 'Windows 10 Pro'; "$nt|DisplayVersion" = '24H2'; "$nt|CurrentBuild" = '26100'; "$nt|UBR" = 2033; "$nt|EditionID" = 'Professional'
      "$nt|InstallDate" = 1740989520
      'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full|Release' = 533325
      'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem|DisableDeleteNotification' = 0
      'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes|ActivePowerScheme' = '381b4222-f694-41f0-9685-ff5bb260df2e'
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System|EnableLUA' = 1
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System|ConsentPromptBehaviorAdmin' = 5
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System|PromptOnSecureDesktop' = 1
      'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon|AutoAdminLogon' = '0'
      'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server|fDenyTSConnections' = 1
      'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp|UserAuthentication' = 1
      'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10|Start' = 4
      "$user\Software\Microsoft\Windows\CurrentVersion\Internet Settings|ProxyEnable" = 0
      "$nt\ProfileList\$($script:sid)|ProfileImagePath" = (Join-Path $TestDrive 'Users\Dana')
      'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration|VersionToReport' = '16.0.18025.20160'
      'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration|CDNBaseUrl' = 'http://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60'
      "$user\Software\Microsoft\OneDrive|Version" = '24.201.1006.0005'
    }
  }
  function Get-DefaultRegistryKeys {
    @{
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ SecurityHealth = '%windir%\system32\SecurityHealthSystray.exe'; Agent = '"C:\Agent\agent.exe" --token abc' }
      ('Registry::HKEY_USERS\' + $script:sid + '\Software\Microsoft\Windows\CurrentVersion\Run') = @{ OneDrive = '"C:\Users\Dana\AppData\Local\Microsoft\OneDrive\OneDrive.exe" /background' }
    }
  }
  function Get-DefaultRegistrySubkeys {
    @{
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = @(
        @{ Name = 'Google Chrome'; Values = @{ DisplayName = 'Google Chrome'; DisplayVersion = '130.0.6723.70'; Publisher = 'Google LLC'; InstallDate = (Get-Date).AddDays(-3).ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture) } }
        @{ Name = '{HEB}'; Values = @{ DisplayName = ($script:hebProgram + ' 2026'); DisplayVersion = '1.2.3'; Publisher = $script:hebProgram; InstallDate = '20250101' } }
        @{ Name = 'Hidden'; Values = @{ DisplayName = 'A system component'; SystemComponent = 1 } }
        @{ Name = 'KB1'; Values = @{ DisplayName = 'An update of Chrome'; ParentKeyName = 'Google Chrome' } }
        @{ Name = 'SupportAssist'; Values = @{ DisplayName = 'HP Support Assistant'; DisplayVersion = '9.1'; Publisher = 'HP Inc.' } })
      'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' = @(
        @{ Name = '{A}'; Values = @{ ProfileName = 'Cohen_Home_5G'; NameType = 71; Category = 1 } }
        @{ Name = '{B}'; Values = @{ ProfileName = 'Network 2'; NameType = 6; Category = 0 } })
      ('Registry::HKEY_USERS\' + $script:sid + '\Software\Microsoft\OneDrive\Accounts') = @(
        @{ Name = 'Personal'; Values = @{ UserEmail = 'dana.cohen@example.co.il' } })
      'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' = @(
        @{ Name = 'S-1-5-18'; Values = @{ ProfileImagePath = 'C:\WINDOWS\system32\config\systemprofile' } }
        @{ Name = $script:sid; Values = @{ ProfileImagePath = 'C:\Users\Dana' } })
    }
  }

  # The mocked Invoke-ToolJsonChild's answer: the data goes through JSON and back, as the real grandchild's file does.
  # A $script:gc entry that has an Ok key is a whole answer (a timeout, a failure).
  function Get-TestChildAnswer {
    param([string]$Name)
    if ($script:gcFail.ContainsKey($Name)) {
      $e = [string]$script:gcFail[$Name]
      return @{ Ok = $false; TimedOut = ($e -eq 'timed out'); Data = $null; Error = $e }
    }
    if (-not $script:gc.ContainsKey($Name)) { return @{ Ok = $false; TimedOut = $false; Data = $null; Error = "no answer for $Name" } }
    $value = $script:gc[$Name]
    if ($value -is [System.Collections.IDictionary] -and $value.Contains('Ok')) { return $value }
    $json = ConvertTo-Json -InputObject $value -Depth 10 -Compress
    @{ Ok = $true; TimedOut = $false; Data = (ConvertTo-HashtableDeep -InputObject (ConvertFrom-Json -InputObject $json)); Error = $null }
  }

  function Get-StepStatus { param($Run, [string]$Id) foreach ($s in $Run.Steps) { if ($s.Id -eq $Id) { return $s.Status } } }
  function Get-Codes { param($Findings) @(foreach ($f in $Findings) { [string]$f.Code }) }
  function Get-Flag { param($Findings, [string]$Code) foreach ($f in $Findings) { if ([string]$f.Code -ceq $Code) { return $f } } }
  # Every text value inside -Value, flattened (to look for a word anywhere in a section).
  function Get-AllText {
    param($Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { [string]$k; Get-AllText -Value $Value[$k] }; return }
    if ($Value -is [System.Collections.IEnumerable]) { foreach ($v in $Value) { Get-AllText -Value $v }; return }
    [string]$Value
  }
}

Describe 'ToolReport (repair Task 8)' {
  BeforeEach {
    $script:blocked = New-Object System.Collections.ArrayList
    $script:native = New-Object System.Collections.ArrayList
    $script:gcNames = New-Object System.Collections.ArrayList
    $script:gc = Get-DefaultAnswers; $script:gcFail = @{}; $script:gcCommands = @{}
    $script:cim = Get-DefaultCim; $script:cimFail = $false
    $script:reg = Get-DefaultRegistry; $script:regKeys = Get-DefaultRegistryKeys; $script:regSubkeys = Get-DefaultRegistrySubkeys
    $script:services = @{}
    foreach ($n in 'wuauserv', 'bits', 'cryptsvc', 'usosvc', 'dosvc') { $script:services[$n] = @{ Status = 'Running'; StartType = 'Manual' } }
    foreach ($n in 'msiserver', 'TrustedInstaller') { $script:services[$n] = @{ Status = 'Stopped'; StartType = 'Manual' } }
    $script:internet = @{ Tcp = $true; Https = $true; Probe = 'ok'; ClockOffsetSeconds = 6.0; Clock = $false; Chip = @{ Level = 'ok'; Args = @(); Detail = @{} } }
    $script:hosts = @{}

    # The files the collectors list, in $TestDrive.
    $win = Join-Path $TestDrive 'Windows'
    foreach ($d in 'Minidump', 'Logs\CBS', 'Logs\DISM', 'INF', 'Startup') { [void][IO.Directory]::CreateDirectory((Join-Path $win $d)) }
    foreach ($old in [IO.Directory]::GetFiles((Join-Path $win 'Minidump'))) { [IO.File]::Delete($old) }
    [void][IO.Directory]::CreateDirectory((Join-Path $TestDrive 'Users\Dana\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'))
    [IO.File]::WriteAllText((Join-Path $win 'hosts'), "# Copyright (c) Microsoft Corp.`r`n#`r`n# 127.0.0.1 localhost`r`n", [Text.Encoding]::ASCII)
    $script:ToolReportPaths = @{
      Minidump = (Join-Path $win 'Minidump'); MemoryDump = (Join-Path $win 'MEMORY.DMP'); Hosts = (Join-Path $win 'hosts')
      CbsLog = (Join-Path $win 'Logs\CBS\CBS.log'); DismLog = (Join-Path $win 'Logs\DISM\dism.log'); SetupApiLog = (Join-Path $win 'INF\setupapi.dev.log')
      CommonStartup = (Join-Path $win 'Startup'); WindowsFolder = 'C:\WINDOWS' }

    Mock Invoke-ToolJsonChild { [void]$script:gcNames.Add($Name); $script:gcCommands[$Name] = $Command; Get-TestChildAnswer -Name $Name }
    Mock Invoke-ToolNative {
      [void]$script:native.Add(('{0} {1}' -f [IO.Path]::GetFileName($FilePath), $ArgumentList).Trim())
      $out = $null
      if ($OutputName) {
        $folder = $(if ($OutputFolder) { $OutputFolder } else { $Run.LogDir })
        $out = Join-Path $folder ($OutputName + '-140600.txt'); [IO.File]::WriteAllText($out, 'raw')
      }
      @{ ExitCode = 0; TimedOut = $false; OutputPath = $out }
    }
    Mock Get-CimInstance {
      if ($script:cimFail) { Write-Error -Message 'The WMI provider did not answer' -Category OperationTimeout; return }
      if (-not $script:cim.ContainsKey([string]$ClassName)) { [void]$script:blocked.Add("Get-CimInstance $ClassName"); throw "not mocked: Get-CimInstance $ClassName" }
      $rows = @($script:cim[[string]$ClassName])
      if ($Filter -match "Name='_Total'") { $rows = @($rows | Where-Object { $_.Name -eq '_Total' }) }
      $rows
    }
    Mock Get-RebootRegistryValue { $script:reg[('{0}|{1}' -f $Path, $Name)] }
    Mock Read-ToolRegistryKey { $script:regKeys[$Path] }
    Mock Read-ToolRegistrySubkeys { , @($script:regSubkeys[$Path] | Where-Object { $null -ne $_ }) }
    Mock Get-Service {
      $s = $script:services[[string]$Name]
      if ($null -eq $s) { Write-Error -Message "Cannot find any service with service name '$Name'." -Category ObjectNotFound; return }
      [pscustomobject]@{ Name = [string]$Name; Status = $s.Status; StartType = $s.StartType }
    }
    Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $true; ComputerRenamePending = $false } }
    Mock Test-ToolInternet { $script:internet }
    Mock Test-ToolTcpHosts { $answer = @{}; foreach ($h in $Hosts) { $answer[$h] = (-not $script:hosts.ContainsKey($h)) -or $script:hosts[$h] }; $answer }
    Mock Get-ToolBcdState { @{ Recovery = 'On'; SafeBoot = $null } }
    Mock Get-ToolReAgentState { 'On' }
    Mock Get-ToolDiskEventCount { @{ Ok = $true; Count = 0; Other = 0; Ids = [string[]]@() } }
    Mock Get-ToolBitLockerChip { @{ Level = 'warn'; Args = @(); Detail = @{ ProtectionStatus = 1; ConversionStatus = 1; Protectors = @('Tpm', 'RecoveryPassword') } } }
    Mock Confirm-SecureBootUEFI { $true }
    Mock Get-LocalGroupMember { [pscustomobject]@{ Name = 'DELL-7HX2K93\Dana'; SID = [Security.Principal.SecurityIdentifier]$script:sid; PrincipalSource = 'Local'; ObjectClass = 'User' } }
    Mock Get-SignedInUserName { 'DELL-7HX2K93\Dana' }
    Mock Get-ToolUserSid { $script:sid }
    Mock Get-SmartAppControlState { 'Off' }
    Mock Read-ToolCbsLog { '' }
    Mock Wait-SetupDelay { }
    # Never reached: the runners above them are mocked.
    Mock Invoke-External { [void]$script:blocked.Add('Invoke-External'); throw 'blocked by the test: Invoke-External' }
    Mock Invoke-PowerShellChild { [void]$script:blocked.Add('Invoke-PowerShellChild'); throw 'blocked by the test: Invoke-PowerShellChild' }
    # Never called in the child's own process: events and hang-prone cmdlets run only in grandchildren.
    # (Get-PhysicalDisk cannot be mocked by Pester: its CDXML proxy does not parse. The static test of RepairStatic and the
    # grandchild command text keep it out of this process.)
    foreach ($name in 'Get-WinEvent', 'Get-PnpDevice', 'Get-NetAdapter', 'Get-NetTCPConnection', 'Get-Printer', 'Get-WindowsDriver', 'Get-MpComputerStatus') {
      Mock $name -MockWith ([scriptblock]::Create("[void]`$script:blocked.Add('$name'); throw 'blocked by the test: $name'"))
    }
    # Safety nets.
    foreach ($name in 'Start-BackgroundExternal', 'Stop-ProcessTree', 'Start-Process', 'Restart-Computer', 'Stop-Service', 'Start-Service', 'Rename-Item',
                      'Remove-BitsTransfer', 'Set-NetIPInterface', 'New-NetIPAddress', 'Set-DnsClientServerAddress', 'Optimize-Volume', 'Repair-Volume',
                      'Repair-WindowsImage', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty') {
      Mock $name -MockWith ([scriptblock]::Create("[void]`$script:blocked.Add('$name'); throw 'blocked by the test: $name'"))
    }
  }

  AfterEach {
    @($script:blocked) | Should -BeNullOrEmpty
    $script:SetupLogPath = $null
    Unregister-SetupTick
  }

  Describe 'the catalog rows (repair plan, Actions and steps)' {
    It 'quickReport and fullReport are read-only, need the stick, log to the session, and list their sections in order' {
      foreach ($id in 'quickReport', 'fullReport') {
        $a = $script:ToolActionCatalog[$id]
        $a | Should -Not -BeNullOrEmpty -Because $id
        $a.Kind | Should -Be 'readonly'; $a.Confirm | Should -Be 'none'; $a.NeedsStick | Should -BeTrue; $a.LogLocal | Should -BeFalse
      }
      @($script:ToolActionCatalog['quickReport'].Steps) | Should -Be @('report01', 'report02', 'report03', 'report04', 'report05', 'report06', 'report07', 'report08',
                                                                       'report09', 'report10', 'report11', 'reportWrite')
      @($script:ToolActionCatalog['fullReport'].Steps) | Should -Be @('report01', 'report02', 'report03', 'report04', 'report05', 'report06', 'report07', 'report08',
                                                                      'report09', 'report10', 'report11', 'report12', 'reportWrite', 'reportZip')
    }
    It 'every report step has its function, none is a servicing step, and only reportWrite always runs (a stopped report still writes what it has)' {
      foreach ($id in @($script:ToolActionCatalog['fullReport'].Steps)) {
        $s = $script:ToolSteps[$id]
        $s | Should -Not -BeNullOrEmpty -Because $id
        $s.Function | Should -BeExactly ('Invoke-ToolStep' + $id.Substring(0, 1).ToUpperInvariant() + $id.Substring(1)) -Because $id
        (Get-Command -Name $s.Function -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because $id
        $s.Servicing | Should -BeFalse -Because $id
        ($s['AlwaysRun'] -eq $true) | Should -Be ($id -ceq 'reportWrite') -Because $id
      }
    }
    It 'every step timeout the report files name is in config.json''s toolStep' {
      $names = foreach ($file in $script:collectFile, $script:reportFile) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).Path, [ref]$null, [ref]$null)
        # The literal names (a helper that forwards its own -StepTimeout passes a variable).
        $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'StepTimeout' }, $true) | ForEach-Object {
          $i = $_.Parent.CommandElements.IndexOf($_); $v = $_.Parent.CommandElements[$i + 1]
          if ($v -is [Management.Automation.Language.StringConstantExpressionAst]) { [string]$v.Value } }
      }
      @($names).Count | Should -BeGreaterThan 5
      foreach ($n in $names) { $script:cfg.timeoutsMinutes.toolStep.PSObject.Properties.Name | Should -Contain $n }
    }
    It 'the report''s finding texts are the plan''s, in English and Hebrew' {
      $expected = [ordered]@{
        'finding.diskUnhealthy'        = 'Disk {0}: health {1}'
        'finding.diskErrors'           = 'Disk {0}: {1} uncorrected read/write errors'
        'finding.diskWear'             = 'Disk {0}: {1}% worn'
        'finding.diskTemp'             = 'Disk {0}: {1} C'
        'finding.diskEvents'           = 'Disk events in {0} days: {1}'
        'finding.lowSpace'             = '{0} {1} GB free ({2}%)'
        'finding.wheaFatal'            = '{0} fatal hardware errors (WHEA) in {1} days'
        'finding.wheaCorrected'        = '{0} corrected hardware errors (WHEA) in {1} days'
        'finding.bugchecks'            = '{0} blue screens in {1} days (codes {2})'
        'finding.kernelPower'          = '{0} unexpected power losses or hard resets in {1} days'
        'finding.minidumps'            = '{0} crash dumps in {1} days'
        'finding.appCrashes'           = '{0} application crashes in {1} days (most: {2})'
        'finding.wuDisabled'           = 'The Windows Update service is disabled'
        'finding.defenderOff'          = 'Defender real-time protection is off and no other antivirus is active'
        'finding.defenderSignatureOld' = 'Defender signatures are {0} days old'
        'finding.uacOff'               = 'UAC is off (EnableLUA = 0)'
        'finding.guestEnabled'         = 'The Guest account is enabled'
        'finding.autoLogon'            = 'Automatic sign-in is configured'
        'finding.rdpNoNla'             = 'Remote Desktop is on without Network Level Authentication'
        'finding.smb1On'               = 'SMBv1 is on'
        'finding.userProxy'            = 'A user proxy is set: {0}'
        'finding.hostsEntries'         = 'The hosts file has {0} active entries'
        'finding.lowRam'               = '{0} GB of RAM'
        'finding.windows10'            = 'Windows 10 (build {0}): out of support since 14/10/2025'
        'finding.uptimeLong'           = 'Up for {0} days: restart before judging stability'
        'finding.batteryWear'          = 'Battery {0}% worn'
        'finding.basicDisplay'         = 'No display driver (Microsoft Basic Display Adapter)'
        'finding.secureBootOff'        = 'Secure Boot is off'
        'finding.tpmMissing'           = 'No ready TPM'
        'finding.bitlockerOn'          = 'BitLocker is on: have the recovery key before BIOS or board work'
        'finding.safeBootSet'          = 'Safe boot is set in the boot configuration'
        'finding.ghostDevicesMany'     = '{0} disconnected devices are registered'
        'finding.autoServicesStopped'  = '{0} automatic services are not running: {1}'
        'finding.noInternet'           = 'No internet (TCP 443 and HTTPS failed)'
        'finding.firewallOff'          = 'The firewall is off for: {0}'
        'finding.notCollected'         = '{0}: not collected ({1})'
        'finding.reportWriteFailed'    = 'The report could not be written ({0})'
        'finding.reportZipFailed'      = 'The raw files could not be zipped ({0}): they are in {1}'
      }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        $script:ToolboxStrings.he[$k] | Should -Not -Match "'" -Because $k
        ([regex]::Matches($script:ToolboxStrings.he[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',' |
          Should -Be (([regex]::Matches($expected[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',') -Because $k
      }
    }
    It 'every finding code the report files add has its text in English and Hebrew' {
      $codes = foreach ($file in $script:collectFile, $script:reportFile) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).Path, [ref]$null, [ref]$null)
        foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Add-ToolFinding', 'Add-ReportFlag' }, $true)) {
          $i = 0
          foreach ($e in $c.CommandElements) { if ($e -is [Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Code') { break }; $i++ }
          if ($i + 1 -lt $c.CommandElements.Count -and $c.CommandElements[$i + 1] -is [Management.Automation.Language.StringConstantExpressionAst]) { $c.CommandElements[$i + 1].Value }
        }
      }
      @($codes).Count | Should -BeGreaterThan 40
      foreach ($code in $codes) {
        $script:ToolboxStrings.en.Keys | Should -Contain "finding.$code"
        $script:ToolboxStrings.he.Keys | Should -Contain "finding.$code"
      }
    }
  }

  Describe 'flags (spec 6.8, review I-10)' {
    It '<Code> fires at <At> and not at <Below>' -ForEach @(
      @{ Code = 'kernelPower'; Item = 'KernelPower41'; At = 3; Below = 2 }, @{ Code = 'appCrashes'; Item = 'AppCrashes'; At = 10; Below = 9 }, @{ Code = 'lowRam'; Item = 'RamGB'; At = 7.9; Below = 8 }
      @{ Code = 'batteryWear'; Item = 'BatteryWear'; At = 40; Below = 39 }, @{ Code = 'defenderSignatureOld'; Item = 'SignatureAgeDays'; At = 8; Below = 7 }, @{ Code = 'clockOff'; Item = 'ClockOffsetMinutes'; At = 2.1; Below = 2.0 }
      @{ Code = 'diskWear'; Item = 'Wear'; At = 80; Below = 79 }, @{ Code = 'diskTemp'; Item = 'Temperature'; At = 60; Below = 59 }, @{ Code = 'uptimeLong'; Item = 'UptimeDays'; At = 8; Below = 7 }
      @{ Code = 'ghostDevicesMany'; Item = 'GhostCount'; At = 151; Below = 150 }) {
      (Get-ReportFlags -Report (Set-ReportItem $sample $Item $At) -Config $cfg).Code | Should -Contain $Code
      (Get-ReportFlags -Report (Set-ReportItem $sample $Item $Below) -Config $cfg).Code | Should -Not -Contain $Code
    }
    It 'WHEA: corrected IDs are a WARN with a count, fatal ones a CRIT' {
      $f = Get-ReportFlags -Report (Set-ReportItem $sample 'Whea' @(@{ Id = 17; Level = 3 }, @{ Id = 19; Level = 3 }, @{ Id = 18; Level = 1 })) -Config $cfg
      ($f | Where-Object Code -eq 'wheaCorrected').Args[0] | Should -Be '2'; ($f | Where-Object Code -eq 'wheaFatal').Level | Should -Be 'CRIT'
      ($f | Where-Object Code -eq 'wheaCorrected').Level | Should -Be 'WARN'; ($f | Where-Object Code -eq 'wheaFatal').Args[0] | Should -Be '1'
    }
    It 'Kernel-Power 41 with BugcheckCode 0 is a power loss, not a blue screen' {
      $f = Get-ReportFlags -Report (Set-ReportItem $sample 'KernelPower41Events' @(@{ BugcheckCode = 0 }, @{ BugcheckCode = 0 }, @{ BugcheckCode = 0 })) -Config $cfg
      $f.Code | Should -Contain 'kernelPower'; $f.Code | Should -Not -Contain 'bugchecks'
      # A 41 that carries a bugcheck code was a blue screen: it is not counted as a power loss.
      $g = Get-ReportFlags -Report (Set-ReportItem $sample 'KernelPower41Events' @(@{ BugcheckCode = 0 }, @{ BugcheckCode = 0 }, @{ BugcheckCode = 159 })) -Config $cfg
      $g.Code | Should -Not -Contain 'kernelPower'; $g.Code | Should -Contain 'bugchecks'; ($g | Where-Object Code -eq 'bugchecks').Args[2] | Should -Be '0x0000009F'
    }
    It 'BugCheck 1001 rows are blue screens, grouped by code' {
      $f = Get-ReportFlags -Report (Set-ReportItem $sample 'BugChecks' @(@{ Time = '2026-10-20T10:00:00'; Code = '0x0000009f' }, @{ Time = '2026-10-21T10:00:00'; Code = '0x0000009f' }, @{ Time = '2026-10-22T10:00:00'; Code = '0x00000124' })) -Config $cfg
      $b = $f | Where-Object Code -eq 'bugchecks'
      $b.Level | Should -Be 'CRIT'; $b.Args[0] | Should -Be '3'; $b.Args[2] | Should -Be '0x0000009F x2, 0x00000124'; $b.Section | Should -Be '07'
    }
    It 'a disabled device (CM 22) and Ntfs 140 are never flagged; disk 7, 51, 153 and Ntfs 55 are' {
      $f = Get-ReportFlags -Report (Set-ReportItem $sample 'DiskEvents' @('Ntfs/140')) -Config $cfg; $f.Code | Should -Not -Contain 'diskEvents'
      foreach ($e in 'disk/7', 'disk/51', 'disk/153', 'Ntfs/55') { (Get-ReportFlags -Report (Set-ReportItem $sample 'DiskEvents' @($e)) -Config $cfg).Code | Should -Contain 'diskEvents' }
      # The collector counts only problem codes: a disabled device is no problem.
      $script:gc['devices'] = @{ Items = @(@{ InstanceId = 'USB\X'; Class = 'USB'; Name = 'Off'; Status = 'Error'; ConfigManagerErrorCode = 22 }) }
      $d = Get-ReportData06 -Run (New-ActionRun quickReport) -Quick $true
      $d.Items.DevicesProblem | Should -Be 0; $d.Items.DevicesDisabled | Should -Be 1
      (Get-ReportFlags -Report (Set-ReportItem (Set-ReportItem $sample 'DevicesProblem' 0) 'ProblemDevices' @()) -Config $cfg).Code | Should -Not -Contain 'devicesProblem'
    }
    It 'Guest and Administrators are found by SID on a Hebrew PC' {
      Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_UserAccount' } { [pscustomobject]@{ Name = 'אורח'; SID = 'S-1-5-21-1-2-3-501'; Disabled = $false; LocalAccount = $true } }
      $d = Get-ReportData11 -Run (New-ActionRun fullReport) -Quick $true; $d.Items.GuestEnabled | Should -BeTrue
      Should -Invoke Get-LocalGroupMember -ParameterFilter { $SID -eq 'S-1-5-32-544' }
      (Get-ReportFlags -Report (Set-ReportItem $sample 'GuestEnabled' $true) -Config $cfg).Code | Should -Contain 'guestEnabled'
      @($d.Items.Users) | Should -Contain 'אורח'
    }
    It 'the Administrators fall back to ADSI on the translated name when Get-LocalGroupMember fails' {
      Mock Get-LocalGroupMember { Write-Error -Message 'An unspecified error occurred: error code = 1789' -Category NotSpecified }
      Mock Get-ToolAdminMembersAdsi { @(@{ Name = 'DELL-7HX2K93\Dana'; Sid = $script:sid }) }
      $d = Get-ReportData11 -Run (New-ActionRun quickReport) -Quick $true
      Should -Invoke Get-ToolAdminMembersAdsi -Times 1 -Exactly
      @($d.Items.Admins).Count | Should -Be 1; @($d.Missing).Count | Should -Be 0
    }
    It 'the Internet chip''s "Clock wrong" is a wrong clock, not "no internet" (RD-R20); a portal is captivePortal (RD-R13)' {
      $clock = Set-ReportItem (Set-ReportItem $sample 'Internet' @{ Tcp = $true; Https = $false; Probe = 'ok'; Clock = $true }) 'ClockOffsetMinutes' 1051200
      $f = Get-ReportFlags -Report $clock -Config $cfg
      $f.Code | Should -Contain 'clockOff'; $f.Code | Should -Not -Contain 'noInternet'; (Get-Flag $f 'clockOff').Args[0] | Should -Be '1051200.0'
      (Get-ReportFlags -Report (Set-ReportItem $sample 'Internet' @{ Tcp = $false; Https = $false; Probe = 'skipped'; Clock = $false }) -Config $cfg).Code | Should -Contain 'noInternet'
      (Get-ReportFlags -Report (Set-ReportItem $sample 'Internet' @{ Tcp = $true; Https = $false; Probe = 'failed'; Clock = $false }) -Config $cfg).Code | Should -Contain 'noInternet'
      $portal = Get-ReportFlags -Report (Set-ReportItem $sample 'Internet' @{ Tcp = $true; Https = $true; Probe = 'different'; Clock = $false }) -Config $cfg
      $portal.Code | Should -Contain 'captivePortal'; $portal.Code | Should -Not -Contain 'noInternet'; (Get-Flag $portal 'captivePortal').Section | Should -Be '09'
    }
    It 'reproduces the Health check''s codes from the sections (volume*, winre*, notActivated, devicesProblem, oemLeftover)' {
      $cases = @(
        @{ Item = 'VolumeState'; Value = 'SpotFixNeeded'; Code = 'volumeStateSpotFix'; Level = 'CRIT'; Section = '03' }
        @{ Item = 'VolumeState'; Value = 'FullRepairNeeded'; Code = 'volumeStateFullRepair'; Level = 'CRIT'; Section = '03' }
        @{ Item = 'VolumeState'; Value = 'ScanNeeded'; Code = 'volumeStateScan'; Level = 'WARN'; Section = '03' }
        @{ Item = 'Dirty'; Value = $true; Code = 'volumeDirty'; Level = 'WARN'; Section = '03' }
        @{ Item = 'WinRe'; Value = @{ Bcd = 'Off'; ReAgent = 'Off'; Verdict = 'Off'; Error = '' }; Code = 'winreOff'; Level = 'WARN'; Section = '04' }
        @{ Item = 'WinRe'; Value = @{ Bcd = 'On'; ReAgent = 'Off'; Verdict = 'Unknown'; Error = '' }; Code = 'winreUnknown'; Level = 'WARN'; Section = '04' }
        @{ Item = 'WinRe'; Value = @{ Bcd = 'Unknown'; ReAgent = 'On'; Verdict = 'Unknown'; Error = 'timed out' }; Code = 'winreUnreadable'; Level = 'WARN'; Section = '04' }
        @{ Item = 'Activation'; Value = 'Not activated'; Code = 'notActivated'; Level = 'WARN'; Section = '01' }
        @{ Item = 'OemLeftovers'; Value = @('HP Support Assistant'); Code = 'oemLeftover'; Level = 'WARN'; Section = '10' }
        @{ Item = 'TrimDisabled'; Value = '1'; Code = 'trimOff'; Level = 'WARN'; Section = '03' }
        @{ Item = 'PageFile'; Value = @{ Files = @('D:\pagefile.sys'); MissingDrives = @('D:'); Error = '' }; Code = 'pageFileMissingDrive'; Level = 'WARN'; Section = '03' }
        @{ Item = 'PageFile'; Value = @{ Files = @(); MissingDrives = @(); Error = 'timed out' }; Code = 'pageFileUnknown'; Level = 'WARN'; Section = '03' })
      foreach ($c in $cases) {
        $f = Get-Flag (Get-ReportFlags -Report (Set-ReportItem $sample $c.Item $c.Value) -Config $cfg) $c.Code
        $f | Should -Not -BeNullOrEmpty -Because $c.Code
        $f.Level | Should -Be $c.Level -Because $c.Code; $f.Section | Should -Be $c.Section -Because $c.Code
      }
      (Get-Codes (Get-ReportFlags -Report $sample -Config $cfg)) | Should -Contain 'devicesProblem'
      (Get-Flag (Get-ReportFlags -Report $sample -Config $cfg) 'winreUnreadable') | Should -BeNullOrEmpty
    }
    It 'every finding names its section; CRIT comes before WARN before INFO; a source that was not collected is INFO notCollected' {
      $f = @(Get-ReportFlags -Report (Set-ReportItem (Set-ReportItem $sample 'DiskEvents' @('disk/7')) 'UptimeDays' 30) -Config $cfg)
      foreach ($x in $f) { $x.Section | Should -Match '^(0[1-9]|1[0-2])$' -Because $x.Code; $x.Text | Should -Not -BeNullOrEmpty -Because $x.Code }
      $rank = @{ CRIT = 0; WARN = 1; INFO = 2 }
      for ($i = 1; $i -lt $f.Count; $i++) { $rank[$f[$i].Level] | Should -BeGreaterOrEqual $rank[$f[$i - 1].Level] }
      $n = Get-Flag $f 'notCollected'; $n.Level | Should -Be 'INFO'; $n.Section | Should -Be '05'; $n.Args | Should -Be @('Windows Update log', 'timed out')
      foreach ($x in $f) { foreach ($a in @($x.Args)) { $a | Should -Not -Match '[^\x20-\x7E]' } }
    }
  }

  Describe 'collectors' {
    It 'Quick skips every slow source and runs one connectivity test' {
      $r = New-ActionRun quickReport
      foreach ($n in '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11') { $null = & "Get-ReportData$n" -Run $r -Quick $true }
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -in 'drivers', 'printers', 'reliability', 'appx', 'features', 'wuLog' }
      Should -Invoke Test-ToolInternet -Times 1 -Exactly; Should -Invoke Test-ToolTcpHosts -Times 0 -Exactly; Should -Invoke Invoke-ToolNative -Times 0
      # Nor the monitors' serials, the volume state, or a copy of anything.
      Should -Invoke Get-CimInstance -Times 0 -ParameterFilter { $ClassName -eq 'WmiMonitorID' }
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'volumeState' }
      [IO.Directory]::Exists((Join-Path $r.SessionDir 'raw_2026-10-23_1405')) | Should -BeFalse
    }
    It 'a source that times out is "not collected", the section and the report still complete' {
      $script:gc['printers'] = @{ Ok = $false; TimedOut = $true; Error = 'timed out' }
      $d = Get-ReportData10 -Run (New-ActionRun fullReport) -Quick $false; $d.Missing.What | Should -Contain 'Printers'; $d.Facts.Count | Should -BeGreaterThan 0
      ($d.Missing | Where-Object What -eq 'Printers').Why | Should -Be 'timed out'
    }
    It 'every section completes when every source fails: each failure is a Missing entry, never an exception' {
      $script:cimFail = $true
      foreach ($k in @($script:gc.Keys)) { $script:gcFail[$k] = 'timed out' }
      Mock Get-RebootRegistryValue { $null }
      Mock Read-ToolRegistryKey { throw 'registry unreadable' }
      Mock Read-ToolRegistrySubkeys { throw 'registry unreadable' }
      Mock Get-Service { Write-Error -Message 'Service control manager unavailable' -Category ResourceUnavailable }
      Mock Test-ToolInternet { throw 'no network stack' }
      Mock Test-ToolTcpHosts { throw 'no network stack' }
      Mock Confirm-SecureBootUEFI { throw (New-Object UnauthorizedAccessException('denied')) }
      Mock Get-LocalGroupMember { Write-Error -Message 'failed' -Category NotSpecified }
      Mock Get-ToolAdminMembersAdsi { throw 'ADSI failed' }
      Mock Get-SignedInUserName { throw 'CIM did not answer' }
      Mock Get-ToolDiskEventCount { @{ Ok = $false; Count = $null; Other = $null; Ids = [string[]]@(); Error = 'log unreadable' } }
      Mock Get-ToolBitLockerChip { @{ Level = 'unknown'; Args = @(); Detail = @{ Error = 'timed out' } } }
      Mock Get-ServicingRebootSignals { throw 'registry unreadable' }
      Mock Invoke-ToolNative { @{ ExitCode = $null; TimedOut = $true; OutputPath = $null } }
      $r = New-ActionRun fullReport
      foreach ($n in '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12') {
        $d = & "Get-ReportData$n" -Run $r -Quick $false
        $d.Id | Should -Be $n
        @($d.Missing).Count | Should -BeGreaterThan 0 -Because "section $n"
        foreach ($m in @($d.Missing)) { $m.What | Should -Not -BeNullOrEmpty; $m.Why | Should -Not -Match '[^\x20-\x7E]' }
      }
    }
    It 'scheduled tasks and services are listed without their arguments' {
      ($core -join "`n") | Should -Not -Match '--token|/password'; ($core -join "`n") | Should -Match 'agent\.exe'
      # The collector itself: the grandchild's task row and the service's command line carry tokens; nothing keeps them.
      $d = Get-ReportData10 -Run (New-ActionRun quickReport) -Quick $true
      $all = (Get-AllText -Value @($d.Facts, $d.Groups, $d.Items)) -join "`n"
      $all | Should -Not -Match '--token|/password|Arguments'
      $all | Should -Match 'C:\\Agent\\agent\.exe'; $all | Should -Match 'agentsvc\.exe'
    }
    It 'the Full disk scan is skipped when the Disk chip is red' {
      $r = New-ActionRun fullReport; $r.Args.Strip.Disk = 'crit'; $null = Get-ReportData03 -Run $r -Quick $false
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'volumeScan' }
    }
    It 'Full reads the volume state read-only (Get-Volume, RD-R12) and never scans, red disk or not' {
      $script:gc['volumeState'] = @{ HealthStatus = 0; OperationalStatus = @(53262); Dirty = $true }
      $d = Get-ReportData03 -Run (New-ActionRun fullReport) -Quick $false
      $d.Items.VolumeState | Should -Be 'SpotFixNeeded'; $d.Items.Dirty | Should -BeTrue
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'volumeState' }
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'volumeScan' }
      (Get-Content -Raw $script:collectFile) | Should -Not -Match 'Repair-Volume'
    }
    It 'storage: the system disk is judged, every disk is listed with its serial, disk events are read for the system disk' {
      Mock Get-ToolDiskEventCount { @{ Ok = $true; Count = 2; Other = 5; Ids = [string[]]@('disk/7', 'Ntfs/55') } }
      $d = Get-ReportData03 -Run (New-ActionRun quickReport) -Quick $true
      $d.Items.SystemDisk | Should -Be 'Samsung SSD 980 PRO 512GB'; $d.Items.Wear | Should -Be 7; $d.Items.Temperature | Should -Be 38; $d.Items.DiskErrors | Should -Be 0
      @($d.Items.Disks.Serial) | Should -Be @('S4EWNX0R123456', '4C530001')
      @($d.Items.DiskEvents) | Should -Be @('disk/7', 'Ntfs/55')
      Should -Invoke Get-ToolDiskEventCount -ParameterFilter { @($SystemDisks) -contains 0 -and $SystemDrive -eq 'C:' }
      $d.Items.FreeGB | Should -Be 210.4; $d.Items.FreePercent | Should -Be 44
    }
    It 'Full runs the five-host test, the raw tools into raw_<stamp>\ and copies the newest crash dumps' {
      $r = New-ActionRun fullReport
      $dumps = $script:ToolReportPaths.Minidump
      for ($i = 1; $i -le 12; $i++) { $p = Join-Path $dumps ('1023{0:D2}-1-01.dmp' -f $i); [IO.File]::WriteAllText($p, 'dump'); [IO.File]::SetLastWriteTime($p, (Get-Date).AddDays(-$i)) }
      $d09 = Get-ReportData09 -Run $r -Quick $false
      Should -Invoke Test-ToolTcpHosts -Times 1 -Exactly -ParameterFilter { @($Hosts).Count -eq 5 -and $Seconds -eq 3 -and @($Hosts) -contains 'login.microsoftonline.com' }
      $d09.Items.Hosts['www.google.com'] | Should -BeTrue
      $d07 = Get-ReportData07 -Run $r -Quick $false
      $raw = Join-Path $r.SessionDir 'raw_2026-10-23_1405'
      @([IO.Directory]::GetFiles((Join-Path $raw 'Minidump'))).Count | Should -Be 10
      $d07.Items.Minidumps | Should -Be 12
      foreach ($n in '01', '03', '05', '06', '08', '11', '12') { $null = & "Get-ReportData$n" -Run $r -Quick $false }
      $lines = @($script:native)
      foreach ($tool in 'systeminfo.exe', 'vssadmin.exe list shadows', 'vssadmin.exe list shadowstorage', 'wevtutil.exe epl System', 'wevtutil.exe epl Application',
                        'powercfg.exe /batteryreport', 'powercfg.exe /sleepstudy', 'powercfg.exe /energy /duration 30', 'gpresult.exe /h', 'dsregcmd.exe /status',
                        'msinfo32.exe /nfo', 'msinfo32.exe /report') {
        @($lines | Where-Object { $_.StartsWith($tool) }).Count | Should -BeGreaterThan 0 -Because $tool
      }
      foreach ($l in $lines) { if ($l -match '"([A-Za-z]:\\[^"]+)"') { $Matches[1] | Should -BeLike "$raw\*" -Because $l } }
      Should -Invoke Invoke-ToolNative -ParameterFilter { $FilePath -like '*msinfo32.exe' -and $StepTimeout -eq 'msinfo32' }
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'wuLog' -and $Command -like "*$raw*" -and $StepTimeout -eq 'wuLog' }
    }
    It 'section 12 is Full only: Quick runs nothing for it' {
      $d = Get-ReportData12 -Run (New-ActionRun quickReport) -Quick $true
      Should -Invoke Invoke-ToolNative -Times 0; @($d.Missing).Count | Should -Be 0; $d.Facts.Count | Should -Be 0
    }
    It 'display names keep their real text (Hebrew programs and event messages, RD-R21)' {
      $r = New-ActionRun quickReport
      $d10 = Get-ReportData10 -Run $r -Quick $true
      @($d10.Items.Programs.Name) | Should -Contain ($script:hebProgram + ' 2026')
      ($d10.Groups -join "`n") | Should -Match ([regex]::Escape($script:hebProgram))
      @($d10.Items.Programs.Name) | Should -Not -Contain 'A system component'; @($d10.Items.Programs.Name) | Should -Not -Contain 'An update of Chrome'
      $d07 = Get-ReportData07 -Run $r -Quick $true
      ($d07.Groups -join "`n") | Should -Match ([regex]::Escape($script:hebStopped))
    }
    It 'software: installs of the last 30 days, the other maker''s utility, Office''s channel and OneDrive''s account' {
      $d = Get-ReportData10 -Run (New-ActionRun quickReport) -Quick $true
      @($d.Items.RecentInstalls) | Should -Be @('Google Chrome')
      @($d.Items.OemLeftovers) | Should -Be @('HP Support Assistant')
      $d.Facts['Office'] | Should -Match 'Current'
      @($d.Items.OneDriveEmails) | Should -Be @('dana.cohen@example.co.il')
      $d.Items.SignedInUser | Should -Be 'DELL-7HX2K93\Dana'
      @($d.Items.AutoStopped).Count | Should -Be 0
    }
    It 'the events of section 07 come from two bounded grandchildren: counts, power losses, blue screens, WHEA, crashes' {
      $script:gc['crashEvents']['whea'] = @{ Error = ''; Total = 2; Groups = @(); Rows = @(
          @{ Provider = 'Microsoft-Windows-WHEA-Logger'; Id = 19; Level = 3; Time = '2026-10-20T10:00:00'; Data = @{}; Props = @() }
          @{ Provider = 'Microsoft-Windows-WHEA-Logger'; Id = 18; Level = 1; Time = '2026-10-21T10:00:00'; Data = @{}; Props = @() }) }
      $script:gc['crashEvents']['bugcheck'] = @{ Error = ''; Total = 1; Groups = @(); Rows = @(
          @{ Provider = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; Level = 2; Time = '2026-10-21T11:44:00'; Data = @{}; Props = @('0x0000009f (0x0000000000000003, 0x)') }) }
      $d = Get-ReportData07 -Run (New-ActionRun quickReport) -Quick $true
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'eventGroups' -and $StepTimeout -eq 'events' }
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'crashEvents' -and $StepTimeout -eq 'events' }
      $d.Items.KernelPower41 | Should -Be 1; @($d.Items.KernelPower41Events)[0].BugcheckCode | Should -Be 0
      @($d.Items.BugChecks)[0].Code | Should -Be '0x0000009F'
      @($d.Items.Whea).Count | Should -Be 2; $d.Items.AppCrashes | Should -Be 2; $d.Items.AppCrashTop | Should -Be 'chrome.exe'
      $f = Get-ReportFlags -Report @{ Sections = @{ '07' = $d }; Items = $d.Items } -Config $cfg
      (Get-Codes $f) | Should -Contain 'bugchecks'; (Get-Codes $f) | Should -Contain 'wheaFatal'; (Get-Codes $f) | Should -Contain 'wheaCorrected'
      # Quick looks back quickEventDays (7) for the error groups, Full eventDays (14); the crash rows always crashDays (60).
      $script:gcCommands['eventGroups'] | Should -Match '"Days":7'; $script:gcCommands['crashEvents'] | Should -Match '"Days":60'
    }
    It 'network: the hosts file''s active entries, a user proxy, SMBv1 and a firewall profile that is off are read' {
      [IO.File]::WriteAllText($script:ToolReportPaths.Hosts, "# hosts`r`n127.0.0.1 localhost # kept`r`n`r`n10.0.0.9 login.microsoftonline.com`r`n", [Text.Encoding]::ASCII)
      $script:reg[('Registry::HKEY_USERS\' + $script:sid + '\Software\Microsoft\Windows\CurrentVersion\Internet Settings|ProxyEnable')] = 1
      $script:reg[('Registry::HKEY_USERS\' + $script:sid + '\Software\Microsoft\Windows\CurrentVersion\Internet Settings|ProxyServer')] = 'proxy.local:8080'
      $script:reg['HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10|Start'] = 2
      $script:gc['netState']['Firewall'] = @(@{ Name = 'Domain'; Enabled = 'True' }, @{ Name = 'Private'; Enabled = 'False' }, @{ Name = 'Public'; Enabled = 'False' })
      $d = Get-ReportData09 -Run (New-ActionRun quickReport) -Quick $true
      $d.Items.HostsEntries | Should -Be 2; $d.Items.UserProxy | Should -Be 'proxy.local:8080'; $d.Items.Smb1 | Should -BeTrue
      @($d.Items.FirewallOff) | Should -Be @('Private', 'Public'); @($d.Items.Ssids) | Should -Be @('Cohen_Home_5G')
      $f = Get-Codes (Get-ReportFlags -Report @{ Sections = @{ '09' = $d }; Items = $d.Items } -Config $cfg)
      foreach ($c in 'hostsEntries', 'userProxy', 'smb1On', 'firewallOff') { $f | Should -Contain $c }
    }
  }

  Describe 'ConvertTo-EventGroups (pure)' {
    It 'groups by provider, ID and level: count, first and last dd/MM/yyyy HH:mm, the newest message, newest group first' {
      $events = @(
        @{ Provider = 'disk'; Id = 7; Level = 2; Time = '2026-10-20T08:00:00'; Message = 'old' }
        @{ Provider = 'disk'; Id = 7; Level = 2; Time = '2026-10-22T09:30:00'; Message = "newest  `r`n  text" }
        @{ Provider = 'disk'; Id = 7; Level = 3; Time = '2026-10-21T10:00:00'; Message = 'a warning' }
        @{ Provider = 'Service Control Manager'; Id = 7031; Level = 2; Count = 3; First = '2026-10-19T07:00:00'; Last = '2026-10-23T12:00:00'; Message = $script:hebStopped })
      $g = @(ConvertTo-EventGroups -Events $events)
      $g.Count | Should -Be 3
      $g[0] | Should -BeExactly ('3x Service Control Manager/7031 [2] 19/10/2026 07:00 - 23/10/2026 12:00  ' + $script:hebStopped)
      $g[1] | Should -BeExactly '2x disk/7 [2] 20/10/2026 08:00 - 22/10/2026 09:30  newest text'
      $g[2] | Should -BeExactly '1x disk/7 [3] 21/10/2026 10:00 - 21/10/2026 10:00  a warning'
    }
    It 'cuts the message to 200 characters, reads event records too, and ignores a Hebrew calendar on the thread' {
      $culture = [Threading.Thread]::CurrentThread.CurrentCulture
      try {
        $he = New-Object Globalization.CultureInfo 'he-IL'; $he.DateTimeFormat.Calendar = New-Object Globalization.HebrewCalendar
        [Threading.Thread]::CurrentThread.CurrentCulture = $he
        $g = @(ConvertTo-EventGroups -Events @([pscustomobject]@{ ProviderName = 'x'; Id = 1; Level = 2; TimeCreated = [datetime]::new(2026, 10, 22, 9, 5, 0); Message = ('m' * 500) }))
      } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
      $g[0] | Should -BeExactly ('1x x/1 [2] 22/10/2026 09:05 - 22/10/2026 09:05  ' + ('m' * 200))
      @(ConvertTo-EventGroups -Events @()).Count | Should -Be 0
    }
  }

  Describe 'Test-ToolTcpHosts' {
    It 'starts every connection together and answers host -> bool, a hung one false within the bound' {
      $script:started = New-Object System.Collections.ArrayList
      $connect = {
        param($HostName)
        [void]$script:started.Add($HostName)
        switch ($HostName) {
          'ok.example' { @{ Client = $null; Task = [Threading.Tasks.Task]::FromResult($true) } }
          'hung.example' { @{ Client = $null; Task = (New-Object 'Threading.Tasks.TaskCompletionSource[bool]').Task } }
          default { throw 'no such host' }
        }
      }
      $clock = [Diagnostics.Stopwatch]::StartNew()
      # The real function (BeforeEach makes Test-ToolTcpHosts a recorder for the collectors).
      $answer = & $script:realTcpHosts -Hosts @('ok.example', 'hung.example', 'bad.example') -Seconds 1 -Connect $connect
      $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
      $answer['ok.example'] | Should -BeTrue; $answer['hung.example'] | Should -BeFalse; $answer['bad.example'] | Should -BeFalse
      @($script:started) | Should -Be @('ok.example', 'hung.example', 'bad.example')
    }
  }

  Describe 'Read-ToolLogErrors' {
    It 'keeps only the English error lines, grouped and counted without their time stamps, newest last, at most -MaxLines' {
      $p = Join-Path $TestDrive 'cbs-errors.log'
      $lines = @(
        '2026-10-20 08:00:00, Info                  CBS    Starting TrustedInstaller initialization.'
        '2026-10-20 08:00:01, Error                 CBS    Failed to resolve package [HRESULT = 0x80070490 - ERROR_NOT_FOUND]'
        '2026-10-21 08:00:01, Error                 CBS    Failed to resolve package [HRESULT = 0x80070490 - ERROR_NOT_FOUND]'
        '2026-10-21 09:00:00, Info                  CSI    00000012 [SR] Cannot repair member file [l:10]"amd64_x.dll"'
        '2026-10-21 09:10:00, Info                  DISM   PID=1 TID=2 Exit code [HRESULT = 0x800f081f]')
      [IO.File]::WriteAllText($p, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding $false))
      $e = @(Read-ToolLogErrors -Path $p -MaxLines 10)
      $e.Count | Should -Be 3
      $e[0] | Should -Match '^2x .*Failed to resolve package'
      ($e -join "`n") | Should -Match '\[SR\] Cannot repair member file'; ($e -join "`n") | Should -Match '0x800f081f'
      ($e -join "`n") | Should -Not -Match 'Starting TrustedInstaller'
      @(Read-ToolLogErrors -Path $p -MaxLines 1).Count | Should -Be 1
      @(Read-ToolLogErrors -Path (Join-Path $TestDrive 'none.log') -MaxLines 10).Count | Should -Be 0
      @(Read-ToolLogErrors -Path $p -MaxLines 10 -Patterns @('!!!')).Count | Should -Be 0
    }
  }

  Describe 'the AI-ready core (spec 6.8)' {
    It 'holds the complaint, this visit, section 00 and the sections in order; dates are dd/MM/yyyy HH:mm under a Hebrew calendar' {
      $culture = [Threading.Thread]::CurrentThread.CurrentCulture
      try {
        $he = New-Object Globalization.CultureInfo 'he-IL'; $he.DateTimeFormat.Calendar = New-Object Globalization.HebrewCalendar
        [Threading.Thread]::CurrentThread.CurrentCulture = $he
        $l = Format-ReportCore -Report $sample -Kind full; $t = $l -join "`n"
      } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
      $t.IndexOf('CUSTOMER COMPLAINT') | Should -BeLessThan $t.IndexOf('THIS VISIT'); $t.IndexOf('THIS VISIT') | Should -BeLessThan $t.IndexOf('== 00 SUMMARY ==')
      $t.IndexOf('== 01 SYSTEM ==') | Should -BeLessThan $t.IndexOf('== 12 MSINFO32 =='); $l[0] | Should -Match '\d\d/\d\d/20\d\d \d\d:\d\d'
      $l[0] | Should -Match '23/10/2026 14:05'; $l[0] | Should -Match 'FULL REPORT'; $l[0] | Should -Match '7HX2K93'
      $t | Should -Match '23/10/2026 13:58  Health check: Done, YELLOW'
      $t.IndexOf('HOW TO USE') | Should -BeGreaterThan $t.IndexOf('== 12 MSINFO32 ==')
      foreach ($f in $sample.Findings) { $t | Should -Match ([regex]::Escape(('[{0}] {1} (section {2})' -f $f.Level, $f.Text, $f.Section))) }
    }
    It 'says (none) when there is no complaint and nothing else ran this visit; Quick has no section 12' {
      $quiet = Set-ReportItem $sample 'RamGB' 16
      $quiet['Complaint'] = ''; $quiet['Done'] = @(); $quiet['Sections'].Remove('12'); $quiet['Findings'] = @()
      $t = (Format-ReportCore -Report $quiet -Kind quick) -join "`n"
      $t | Should -Match 'CUSTOMER COMPLAINT\n  \(none\)'; $t | Should -Match 'THIS VISIT\n  \(nothing else yet\)'
      $t | Should -Match 'QUICK REPORT'; $t | Should -Not -Match '== 12 '; $t | Should -Match '\(no findings\)'
    }
    It 'stays under 150 KB with 10 000 event groups, keeping the summary and every finding' {
      $l = Limit-ReportCore -Lines (Format-ReportCore -Report $huge -Kind full) -Sections $huge.Sections -MaxBytes 153600
      [Text.Encoding]::UTF8.GetByteCount(($l -join "`r`n")) | Should -BeLessThan 153600; ($l -join "`n") | Should -Match '== 00 SUMMARY =='
      $t = $l -join "`n"
      foreach ($f in $huge.Findings) { $t | Should -Match ([regex]::Escape(('[{0}] {1}' -f $f.Level, $f.Text))) }
      foreach ($k in @($huge.Sections['01'].Facts.Keys)) { $t | Should -Match ([regex]::Escape(('  {0} = ' -f $k))) }
      # The largest section is cut first, from its oldest end, and says where the full text is.
      $t | Should -Match '    \([0-9]+ lines cut to fit; full text in raw\\report-full\.txt\)'
      $t | Should -Match ([regex]::Escape($huge.Sections['07'].Groups[0]))
      $t | Should -Not -Match ([regex]::Escape($huge.Sections['07'].Groups[9999]))
      # A core that already fits is not touched.
      $small = Format-ReportCore -Report $sample -Kind full
      @(Limit-ReportCore -Lines $small -Sections $sample.Sections -MaxBytes 153600) | Should -Be $small
    }
    It 'keeps Hebrew event messages as UTF-8 with a BOM; headings and flags stay ASCII' {
      $r = New-SampleRun
      $null = Invoke-ToolStepReportWrite -Run $r; $b = [IO.File]::ReadAllBytes($r.Files.Report); $b[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
      $t = [IO.File]::ReadAllText($r.Files.Report); $t | Should -Match 'השירות'; @($t -split "`r`n" | Where-Object { $_ -match '^(==|\s*\[(CRIT|WARN|INFO)\])' -and $_ -match '[^\x00-\x7F]' }).Count | Should -Be 0
      $t | Should -Match 'המחשב איטי'
      (Split-Path $r.Files.Report -Leaf) | Should -BeExactly 'REPORT_DELL-7HX2K93_2026-10-23_1405.txt'
    }
    It 'writes the data JSON, raw\ and (Full) the zip; a second report in the same minute gets _2' {
      $r = New-SampleRun
      $null = Invoke-ToolStepReportWrite -Run $r; $null = Invoke-ToolStepReportZip -Run $r
      Test-Path $r.Files.Data | Should -BeTrue; (Get-ChildItem $r.SessionDir -Filter '*_raw.zip').Count | Should -Be 1
      (Split-Path $r.Files.Data -Leaf) | Should -BeExactly 'REPORT_DELL-7HX2K93_2026-10-23_1405_data.json'
      Test-Path (Join-Path $r.SessionDir 'raw_2026-10-23_1405\report-full.txt') | Should -BeTrue
      $r2 = New-SampleRun -SameMinute $r; $null = Invoke-ToolStepReportWrite -Run $r2; $r2.Files.Report | Should -Match '_2\.txt$'
      $r2.Files.Data | Should -Match '_2_data\.json$'
    }
    It 'the data JSON has the shape Compare reads: identity, facts, findings, disks by serial, free space, devices, programs, crashes' {
      $r = New-SampleRun
      $null = Invoke-ToolStepReportWrite -Run $r
      $d = Read-ToolJsonFile -Path $r.Files.Data -MaxBytes $script:ToolReportDataMaxBytes
      $d.Version | Should -Be 1; $d.Kind | Should -Be 'full'; $d.CreatedAt | Should -Be '2026-10-23T14:05:30'
      $d.Identity.Key | Should -Be 'SN-7HX2K93'
      $d.Disks['S4EWNX0R123456'].Wear | Should -Be 7; $d.Disks['S4EWNX0R123456'].ReadErrors | Should -Be 0
      $d.FreeGB | Should -Be 210.4
      @($d.ProblemDevices)[0].Id | Should -Be 'PCI\VEN_8086&DEV_51F1\3&11583659&0&A3'
      @($d.Programs) | Should -Contain ('חשבשבת 2026|1.2.3')
      @($d.Crashes.KernelPower) | Should -Be @('2026-10-21T11:42:10')
      @($d.Findings.Code) | Should -Contain 'devicesProblem'; (@($d.Findings) | Where-Object Code -eq 'devicesProblem').Section | Should -Be '06'
      $d.Facts['Windows'] | Should -Be 'Windows 11 Pro 24H2'
    }
    It 'the report''s findings go into the run (the window shows them); result.json holds no report data and stays small (RD-R21)' {
      $r = New-SampleRun
      $r.Data['Report']['07']['Groups'] = $huge.Sections['07'].Groups
      $null = Invoke-ToolStepReportWrite -Run $r
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'devicesProblem'
      Write-ToolResult -Run $r -Outcome Done | Should -BeTrue
      (Get-Item $r.ResultPath).Length | Should -BeLessThan 64KB
      $res = Read-ToolJsonFile -Path $r.ResultPath
      $res.Data.ContainsKey('Report') | Should -BeFalse
      $res.Files.Report | Should -Be $r.Files.Report; $res.Files.Data | Should -Be $r.Files.Data
      [IO.File]::ReadAllText($r.ResultPath) | Should -Not -Match '[^\x00-\x7F]'
    }
    It 'a report file that cannot be written is the CRIT reportWriteFailed, never a silent success' {
      $r = New-SampleRun
      Mock Test-StickReparsePoint { $Path -like '*REPORT_*' }
      Invoke-ToolStepReportWrite -Run $r | Should -Be 'failed'
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'reportWriteFailed'
    }
  }

  Describe 'RD-R23: the files Ben reads on the stick are plain UTF-8' {
    It 'Write-ToolJsonFile -Utf8 keeps Hebrew as UTF-8 (2 bytes a letter, no \u escapes); Read-ToolJsonFile reads it back with a larger cap' {
      $name = $script:hebProgram
      $rows = @(for ($i = 0; $i -lt 20000; $i++) { '{0} {1}|1.0.{1}' -f $name, $i })
      $p = Join-Path $TestDrive 'hebrew-data.json'
      Write-ToolJsonFile -Path $p -InputObject @{ Programs = $rows; Name = $name } -Depth 4 -Utf8 | Should -BeTrue
      $bytes = [IO.File]::ReadAllBytes($p)
      $text = (New-Object Text.UTF8Encoding $false, $true).GetString($bytes)
      $text | Should -Not -Match '\\u05'; $text | Should -Match ([regex]::Escape($name))
      $bytes.Length | Should -BeGreaterThan 1MB; $bytes.Length | Should -BeLessThan 2MB
      Read-ToolJsonFile -Path $p | Should -BeNullOrEmpty
      $back = Read-ToolJsonFile -Path $p -MaxBytes $script:ToolReportDataMaxBytes
      $back.Name | Should -BeExactly $name; @($back.Programs).Count | Should -Be 20000; @($back.Programs)[19999] | Should -BeExactly $rows[19999]
      $script:ToolReportDataMaxBytes | Should -Be 16MB
      # The exchange files stay ASCII bytes with \u escapes (RD-R21).
      $q = Join-Path $TestDrive 'exchange.json'
      Write-ToolJsonFile -Path $q -InputObject @{ Name = $name } | Should -BeTrue
      [IO.File]::ReadAllText($q) | Should -Match '\\u05d7'; (Read-ToolJsonFile -Path $q).Name | Should -BeExactly $name
    }
    It 'the report''s data JSON on the stick is plain UTF-8' {
      $r = New-SampleRun
      $null = Invoke-ToolStepReportWrite -Run $r
      $t = [IO.File]::ReadAllText($r.Files.Data, [Text.Encoding]::UTF8)
      $t | Should -Match 'חשבשבת 2026'; $t | Should -Not -Match '\\u0'
      $t | Should -Match ([regex]::Escape('VEN_8086&DEV_51F1'))
    }
    It 'the UTF-8 mode also shows the ampersand, apostrophe and angle brackets as they are (5.1 escapes them); an escape kept as text in a value survives' {
      $p = Join-Path $TestDrive 'marks.json'
      $value = 'a&b ''q'' <x> \u0026 \\u0027 end'
      Write-ToolJsonFile -Path $p -InputObject @{ V = $value } -Utf8 | Should -BeTrue
      $text = [IO.File]::ReadAllText($p)
      $text | Should -Match ([regex]::Escape("a&b 'q' <x>"))
      (Read-ToolJsonFile -Path $p -MaxBytes $script:ToolReportDataMaxBytes).V | Should -BeExactly $value
      ConvertFrom-ToolJsonHtmlEscapes -Json '{"a":"\\u0026","b":"\u0026","c":"\\\u003c"}' | Should -BeExactly '{"a":"\\u0026","b":"&","c":"\\<"}'
    }
  }

  Describe 'a Quick report end to end on the fake PC' {
    It 'runs every section, writes the core and the data, and the result names them' {
      $r = New-ActionRun quickReport
      $outcome = Invoke-ToolSteps -Run $r
      $outcome | Should -Be 'Done'
      @(foreach ($s in $r.Steps) { $s.Status }) | Should -Not -Contain 'failed'
      Test-Path $r.Files.Report | Should -BeTrue; Test-Path $r.Files.Data | Should -BeTrue
      $t = [IO.File]::ReadAllText($r.Files.Report)
      foreach ($n in '01 SYSTEM', '02 HARDWARE', '03 STORAGE', '04 BOOT AND RECOVERY', '05 WINDOWS UPDATE', '06 DRIVERS AND DEVICES', '07 EVENTS AND CRASHES',
                     '08 PERFORMANCE AND POWER', '09 NETWORK', '10 SOFTWARE', '11 SECURITY') { $t | Should -Match ([regex]::Escape("== $n ==")) }
      $t | Should -Not -Match '== 12 '
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'devicesProblem'
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'oemLeftover'
      Should -Invoke Invoke-ToolNative -Times 0
    }
    It 'a stopped report still writes what it collected; the sections it did not reach are listed as not collected' {
      $r = New-ActionRun fullReport
      Mock Invoke-ToolStepReport03 { [IO.File]::WriteAllText($r.StopPath, 'stop'); 'done' }
      $outcome = Invoke-ToolSteps -Run $r
      $outcome | Should -Be 'Stopped'
      Test-Path $r.Files.Report | Should -BeTrue
      $t = [IO.File]::ReadAllText($r.Files.Report)
      $t | Should -Match '== 01 SYSTEM =='; $t | Should -Match '== 07 EVENTS AND CRASHES =='
      $t | Should -Match 'Not collected: This section \(not run: the report was stopped or ran out of time\)'
      # One summary line and one finding in the window for the sections not reached, not ten.
      $t | Should -Match '\[INFO\] This section: not collected \(not run: the report was stopped or ran out of time\) \(sections 03, 04, 05, 06, 07, 08, 09, 10, 11, 12\)'
      @(foreach ($f in $r.Findings) { if ($f.Code -eq 'notCollected' -and $f.Args[0] -eq 'This section') { $f } }).Count | Should -Be 1
      (Get-StepStatus -Run $r -Id 'reportZip') | Should -Be 'skipped'
    }
  }
}
