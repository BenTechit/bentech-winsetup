# tests/fixtures/ReportFakePc.ps1
# The fake PC of the report tests (repair Task 8; Task 9's SAFE copy and Compare reuse it): a healthy Dell Latitude on
# Hebrew Windows 11, its answers for every source the report collectors read, the mocks that serve them, and the sample
# report built from the REAL collectors (New-ReportSample), so the sample's lines are always in the formats the report
# writes (review M8). Dot-source it after the src files:
#   BeforeAll (file)     : . the src files; . "$PSScriptRoot\fixtures\ReportFakePc.ps1"; Initialize-ReportFakePc
#   BeforeAll (Describe) : Register-ReportFakePcMocks; Reset-ReportFakePc; $script:sample = New-ReportSample; ...
#   BeforeEach           : Reset-ReportFakePc
#   AfterEach            : @($script:blocked) | Should -BeNullOrEmpty
#
# SAFETY: nothing here reads this PC or starts anything. Invoke-ToolJsonChild answers from $script:gc (by grandchild
# name; $script:gcFail makes one fail or time out; the zip grandchild's command alone is run in this process, on
# $TestDrive files only); Invoke-ToolNative records its calls and writes the file a raw tool would write under
# $TestDrive; CIM, the registry, services, the internet check and the five-host test answer fixed values; the
# hang-prone and event cmdlets, Get-LocalGroupMember and Get-ToolDiskEventCount (which reads the event log in its own
# process) and every changing cmdlet record their name in $script:blocked and throw. Files go under $TestDrive only.

function Initialize-ReportFakePc {
  # The constants of the fake PC and its stick (under $TestDrive), and the Hebrew texts it holds (built from code
  # points where a test names them).
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\..\config\config.json"
  $script:root = Join-Path $TestDrive 'Root'
  $script:stickRoot = (Join-Path $TestDrive 'Stick') + '\'
  $script:reports = Join-Path $TestDrive 'Stick\BenTech-Reports'
  $script:sessionDir = Join-Path $script:reports 'DELL-7HX2K93_7HX2K93_2026-10-23_1400'
  $script:sid = 'S-1-5-21-1-2-3-1001'
  $script:hebStopped = -join ([char[]](0x05D4, 0x05E9, 0x05D9, 0x05E8, 0x05D5, 0x05EA))   # "the service"
  $script:hebProgram = -join ([char[]](0x05D7, 0x05E9, 0x05D1, 0x05E9, 0x05D1, 0x05EA))   # a Hebrew accounting program
  $script:hebLabel = -join ([char[]](0x05D1, 0x05E0, 0x05D8, 0x05E7))                     # a volume label
  $script:hebComplaint = 'המחשב איטי מאוד ונכבה לבד באמצע העבודה.' + "`n" + 'The customer says it started after a Windows update.'
}

function New-ReportTestArgs {
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

function New-ReportActionRun {
  # A run of -Action (quickReport or fullReport) in a fresh run folder, with a fresh session folder on the fake stick,
  # started at 23/10/2026 14:05:30. -SameMinute <run>: the same session folder and start minute as that run (kept).
  param([Parameter(Mandatory)][string]$Action, [hashtable]$SameMinute)
  $runId = '20261023-140530-' + $Action
  if ($null -ne $SameMinute) { $runId = '20261023-140545-' + $Action }
  $dir = Join-Path $script:root "Tool\$runId"
  if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
  [void][IO.Directory]::CreateDirectory($dir)
  if ($null -eq $SameMinute -and [IO.Directory]::Exists($script:sessionDir)) { [IO.Directory]::Delete($script:sessionDir, $true) }
  $run = New-ToolRun -ToolArgs (New-ReportTestArgs -Action $Action -RunId $runId) -Config $script:cfg -Root $script:root
  $run.StartedAt = $(if ($null -ne $SameMinute) { $SameMinute.StartedAt.AddSeconds(15) } else { [datetime]::new(2026, 10, 23, 14, 5, 30) })
  $null = New-ToolSessionDir -Run $run
  $run
}

function ConvertTo-OrderedDeep {
  # Parsed JSON as nested ordered dictionaries and arrays (an empty or one-item array stays an array).
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

function Copy-ReportValue {
  # A deep copy (through JSON) of a report or a part of it.
  param($Value)
  ConvertTo-OrderedDeep -InputObject (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30 -Compress))
}

function Set-ReportItem {
  # A deep copy of -Report with Items.<Item> set to -Value.
  param($Report, [string]$Item, $Value)
  $copy = Copy-ReportValue -Value $Report
  $copy['Items'][$Item] = $Value
  $copy
}

# --- What the fake PC answers ----------------------------------------------------------------------------------

function Get-ReportFakeAnswers {
  # What every grandchild answers (the Data of Invoke-ToolJsonChild, by grandchild name).
  $none = @{ Error = ''; Total = 0; Rows = @(); Groups = @() }
  @{
    activation   = @{ Statuses = @(1) }
    diskInfo     = @{ SystemDisks = @(0); Items = @(
        @{ DeviceId = '0'; Model = 'Samsung SSD 980 PRO 512GB'; Serial = 'S4EWNX0R123456'; Media = 'SSD'; Bus = 'NVMe'; Health = 'Healthy'; Size = 512110190592; Firmware = '5B2QGXA7' }
        @{ DeviceId = '1'; Model = 'SanDisk Cruzer Glide'; Serial = '4C530001'; Media = 'Unspecified'; Bus = 'USB'; Health = 'Healthy'; Size = 30752000000; Firmware = '1.00' }) }
    diskCounters = @{ Items = @(
        @{ DeviceId = '0'; Wear = 7; Temperature = 38; TemperatureMax = 70; ReadErrors = 0; WriteErrors = 0; PowerOnHours = 2210 }
        @{ DeviceId = '1'; Wear = $null; Temperature = $null; TemperatureMax = $null; ReadErrors = $null; WriteErrors = $null; PowerOnHours = $null }) }
    diskEvents   = @{ disk = $none }
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
                                                                        Last = '2026-10-22T18:30:00'; Message = ($script:hebStopped + ' נעצר באופן בלתי צפוי. זה קרה 1 פעמים.') }) }
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
    admins       = @{ Source = 'Get-LocalGroupMember'; Items = @(@{ Name = 'DELL-7HX2K93\Dana'; Sid = $script:sid; Source = 'Local' }) }
    wuLog        = @{ Done = $true }
  }
}

function Get-ReportFakeCim {
  # The CIM classes the collectors read (by class name).
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
                              [pscustomobject]@{ DriveLetter = 'E:'; Label = $script:hebLabel; FileSystem = 'FAT32'; Capacity = 30752000000; FreeSpace = 21582000000; DirtyBitSet = $false; DriveType = 2 })
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

function Get-ReportFakeRegistry {
  # Single registry values ('<path>|<name>' -> value).
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

function Get-ReportFakeRegistryKeys {
  # Whole keys (path -> name -> value).
  @{
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ SecurityHealth = '%windir%\system32\SecurityHealthSystray.exe'; Agent = '"C:\Agent\agent.exe" --token abc' }
    ('Registry::HKEY_USERS\' + $script:sid + '\Software\Microsoft\Windows\CurrentVersion\Run') = @{ OneDrive = '"C:\Users\Dana\AppData\Local\Microsoft\OneDrive\OneDrive.exe" /background' }
  }
}

function Get-ReportFakeRegistrySubkeys {
  # Subkeys (path -> @( @{ Name; Values } )).
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

function Get-ReportFakeChildAnswer {
  # The mocked Invoke-ToolJsonChild's answer. The data goes through JSON and back, as the real grandchild's file does;
  # a $script:gc entry that has an Ok key is a whole answer (a timeout, a failure). The zip grandchild's own command is
  # run here, in this process: it only zips a $TestDrive folder into a $TestDrive file.
  param([string]$Name, [string]$Command)
  if ($script:gcFail.ContainsKey($Name)) {
    $e = [string]$script:gcFail[$Name]
    return @{ Ok = $false; TimedOut = ($e -eq 'timed out'); Data = $null; Error = $e }
  }
  if ($Name -eq 'zip') {
    if ($Command -notmatch [regex]::Escape($TestDrive)) { [void]$script:blocked.Add('zip outside TestDrive'); throw 'the zip command names a path outside TestDrive' }
    return @{ Ok = $true; TimedOut = $false; Data = (& ([scriptblock]::Create($Command))); Error = $null }
  }
  if (-not $script:gc.ContainsKey($Name)) { return @{ Ok = $false; TimedOut = $false; Data = $null; Error = "no answer for $Name" } }
  $value = $script:gc[$Name]
  if ($value -is [System.Collections.IDictionary] -and $value.Contains('Ok')) { return $value }
  $json = ConvertTo-Json -InputObject $value -Depth 10 -Compress
  @{ Ok = $true; TimedOut = $false; Data = (ConvertTo-HashtableDeep -InputObject (ConvertFrom-Json -InputObject $json)); Error = $null }
}

function Reset-ReportFakePc {
  # Every answer back to the healthy Dell, the recorders empty, and the files the collectors list in $TestDrive.
  $script:blocked = New-Object System.Collections.ArrayList
  $script:native = New-Object System.Collections.ArrayList
  $script:gcNames = New-Object System.Collections.ArrayList
  $script:gc = Get-ReportFakeAnswers; $script:gcFail = @{}; $script:gcCommands = @{}
  $script:cim = Get-ReportFakeCim; $script:cimFail = $false
  $script:reg = Get-ReportFakeRegistry; $script:regKeys = Get-ReportFakeRegistryKeys; $script:regSubkeys = Get-ReportFakeRegistrySubkeys
  $script:services = @{}
  foreach ($n in 'wuauserv', 'bits', 'cryptsvc', 'usosvc', 'dosvc') { $script:services[$n] = @{ Status = 'Running'; StartType = 'Manual' } }
  foreach ($n in 'msiserver', 'TrustedInstaller') { $script:services[$n] = @{ Status = 'Stopped'; StartType = 'Manual' } }
  $script:internet = @{ Tcp = $true; Https = $true; Probe = 'ok'; ClockOffsetSeconds = 6.0; Clock = $false; Chip = @{ Level = 'ok'; Args = @(); Detail = @{} } }
  $script:hosts = @{}
  $win = Join-Path $TestDrive 'Windows'
  foreach ($d in 'Minidump', 'Logs\CBS', 'Logs\DISM', 'INF', 'Startup') { [void][IO.Directory]::CreateDirectory((Join-Path $win $d)) }
  foreach ($old in [IO.Directory]::GetFiles((Join-Path $win 'Minidump'))) { [IO.File]::Delete($old) }
  [void][IO.Directory]::CreateDirectory((Join-Path $TestDrive 'Users\Dana\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'))
  [IO.File]::WriteAllText((Join-Path $win 'hosts'), "# Copyright (c) Microsoft Corp.`r`n#`r`n# 127.0.0.1 localhost`r`n", [Text.Encoding]::ASCII)
  $script:ToolReportPaths = @{
    Minidump = (Join-Path $win 'Minidump'); MemoryDump = (Join-Path $win 'MEMORY.DMP'); Hosts = (Join-Path $win 'hosts')
    CbsLog = (Join-Path $win 'Logs\CBS\CBS.log'); DismLog = (Join-Path $win 'Logs\DISM\dism.log'); SetupApiLog = (Join-Path $win 'INF\setupapi.dev.log')
    CommonStartup = (Join-Path $win 'Startup'); WindowsFolder = 'C:\WINDOWS' }
}

function Register-ReportFakePcMocks {
  # Every mock of the fake PC (call it once, in a Describe's BeforeAll; Reset-ReportFakePc before each test).
  Mock Invoke-ToolJsonChild { [void]$script:gcNames.Add($Name); $script:gcCommands[$Name] = $Command; Get-ReportFakeChildAnswer -Name $Name -Command $Command }
  Mock Invoke-ToolNative {
    [void]$script:native.Add(('{0} {1}' -f [IO.Path]::GetFileName($FilePath), $ArgumentList).Trim())
    $out = $null
    if ($OutputName) {
      $folder = $(if ($OutputFolder) { $OutputFolder } else { $Run.LogDir })
      $out = Join-Path $folder ($OutputName + '-140600.txt'); [IO.File]::WriteAllText($out, 'raw')
    } elseif ($ArgumentList -match '"([A-Za-z]:\\[^"]+)"' -and $Matches[1].StartsWith([string]$TestDrive, [StringComparison]::OrdinalIgnoreCase)) {
      # The file a raw tool writes itself (wevtutil, powercfg, gpresult, msinfo32).
      [IO.File]::WriteAllText($Matches[1], 'raw')
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
  Mock Get-ToolBitLockerChip { @{ Level = 'warn'; Args = @(); Detail = @{ ProtectionStatus = 1; ConversionStatus = 1; Protectors = @('Tpm', 'RecoveryPassword') } } }
  Mock Confirm-SecureBootUEFI { $true }
  Mock Get-SignedInUserName { 'DELL-7HX2K93\Dana' }
  Mock Get-ToolUserSid { $script:sid }
  Mock Get-SmartAppControlState { 'Off' }
  Mock Read-ToolCbsLog { '' }
  Mock Wait-SetupDelay { }
  # Never reached: the runners above them are mocked.
  Mock Invoke-External { [void]$script:blocked.Add('Invoke-External'); throw 'blocked by the test: Invoke-External' }
  Mock Invoke-PowerShellChild { [void]$script:blocked.Add('Invoke-PowerShellChild'); throw 'blocked by the test: Invoke-PowerShellChild' }
  # Never called in the child's own process: events, the Administrators group and the hang-prone cmdlets run only in
  # grandchildren (review M4). (Get-PhysicalDisk cannot be mocked by Pester: its CDXML proxy does not parse; the
  # grandchild command text keeps it out of this process.)
  foreach ($name in 'Get-WinEvent', 'Get-ToolDiskEventCount', 'Get-LocalGroupMember', 'Get-PnpDevice', 'Get-NetAdapter', 'Get-NetTCPConnection', 'Get-Printer',
                    'Get-WindowsDriver', 'Get-MpComputerStatus') {
    Mock $name -MockWith ([scriptblock]::Create("[void]`$script:blocked.Add('$name'); throw 'blocked by the test: $name'"))
  }
  # Safety nets.
  foreach ($name in 'Start-BackgroundExternal', 'Stop-ProcessTree', 'Start-Process', 'Restart-Computer', 'Stop-Service', 'Start-Service', 'Rename-Item',
                    'Remove-BitsTransfer', 'Set-NetIPInterface', 'New-NetIPAddress', 'Set-DnsClientServerAddress', 'Optimize-Volume', 'Repair-Volume',
                    'Repair-WindowsImage', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty') {
    Mock $name -MockWith ([scriptblock]::Create("[void]`$script:blocked.Add('$name'); throw 'blocked by the test: $name'"))
  }
}

# --- The sample report -----------------------------------------------------------------------------------------

function New-ReportSample {
  # A Full report of the fake PC from the real collectors (review M8): every section collected on a fullReport run,
  # then New-ToolReport, with a Hebrew complaint, one earlier action this visit, and the Windows Update log timed out
  # (one "not collected"). Returned as a deep copy (plain ordered data, detached from the run). Needs the mocks.
  $script:gcFail['wuLog'] = 'timed out'
  $run = New-ReportActionRun -Action fullReport
  $run.Args['Complaint'] = $script:hebComplaint
  $run.Args['Done'] = @(@{ Action = 'health'; Outcome = 'Done'; Color = 'YELLOW'; EndedAt = '2026-10-23T13:58:10' })
  foreach ($id in '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12') { $null = Invoke-ToolReportSection -Run $run -Id $id }
  $script:gcFail.Remove('wuLog')
  Copy-ReportValue -Value (New-ToolReport -Run $run)
}

function New-ReportHuge {
  # -Sample with 10 000 event groups (Hebrew messages) in section 07 and 3 000 program lines in section 10, and its
  # findings again (review M9: made at test time, nothing committed).
  param([Parameter(Mandatory)]$Sample)
  $huge = Copy-ReportValue -Value $Sample
  $message = $script:hebStopped + ' ' + (-join ([char[]](0x05E0, 0x05E2, 0x05E6, 0x05E8)))
  $events = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt 10000; $i++) {
    $events.Add(('{0}x Provider-{1:D5}/{2} [{3}] 01/10/2026 08:00 - 22/10/2026 18:30  {4} ({5})' -f (($i % 7) + 1), $i, (1000 + ($i % 50)), (($i % 3) + 1), $message, $i))
  }
  $huge['Sections']['07']['Groups'] = $events.ToArray()
  $programs = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt 3000; $i++) { $programs.Add(('Program {0} {1} 1.0.{1} (Publisher {1})' -f $script:hebProgram, $i)) }
  $huge['Sections']['10']['Groups'] = $programs.ToArray()
  $huge['Findings'] = @(Get-ReportFlags -Report $huge -Config $script:cfg)
  $huge
}

function New-ReportSampleRun {
  # A Full report run whose collected sections are -Sample's (Data.Report), with its complaint and visit.
  param([Parameter(Mandatory)]$Sample, [hashtable]$SameMinute)
  $run = New-ReportActionRun -Action fullReport -SameMinute $SameMinute
  $copy = Copy-ReportValue -Value $Sample
  $run.Data['Report'] = $copy['Sections']
  $run.Args['Complaint'] = [string]$copy['Complaint']
  $run.Args['Done'] = @($copy['Done'])
  $run
}
