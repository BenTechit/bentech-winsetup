# src/Detect/Detection.ps1
# Machine facts: laptop or desktop, VM, vendor brand, OS, AC power, the fresh-install check, and whether
# Windows Administrator protection runs this setup as another account (Test-AdminProtection).
# Pure decision functions come first (unit-tested); the system readers at the bottom are not.
# Everything reads CIM, the registry or the process token. Nothing here parses localized command output,
# because the target machines may run Hebrew Windows: account names are compared, never interpreted.

function Test-IsVirtualMachine {
  <#
  .SYNOPSIS
    True for Hyper-V, VMware, VirtualBox, QEMU and KVM guests, judged from Manufacturer and Model.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Manufacturer,
    [AllowNull()][AllowEmptyString()][string]$Model
  )

  $m = "$Manufacturer".Trim()
  $mo = "$Model".Trim()
  if ($m -eq 'Microsoft Corporation' -and $mo -eq 'Virtual Machine') { return $true }
  foreach ($text in $m, $mo) {
    foreach ($token in 'VMware', 'VirtualBox', 'innotek', 'QEMU', 'KVM') {
      if ($text -like "*$token*") { return $true }
    }
  }
  return $false
}

function Resolve-Brand {
  <#
  .SYNOPSIS
    Maps Win32_ComputerSystem Manufacturer/Model to a brand (spec 9.2): DELL, LENOVO, HP, ASUS, ACER,
    MSI, SURFACE, SAMSUNG, VM or OTHER.
  .DESCRIPTION
    A virtual machine is decided first, then the table is applied in order with case-insensitive
    matching. HP is the exact name "HP" or anything containing "Hewlett", so "SHP Systems" is OTHER.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Manufacturer,
    [AllowNull()][AllowEmptyString()][string]$Model
  )

  if (Test-IsVirtualMachine -Manufacturer $Manufacturer -Model $Model) { return 'VM' }

  $m = "$Manufacturer".Trim()
  $mo = "$Model".Trim()
  if ($m -like '*Dell*') { return 'DELL' }
  if ($m -like '*Lenovo*') { return 'LENOVO' }
  if ($m -eq 'HP' -or $m -like '*Hewlett*') { return 'HP' }
  if ($m -like '*ASUS*') { return 'ASUS' }
  if ($m -like '*Acer*') { return 'ACER' }
  if ($m -like '*Micro-Star*') { return 'MSI' }
  if ($m -eq 'Microsoft Corporation' -and $mo -like 'Surface*') { return 'SURFACE' }
  if ($m -like '*Samsung*') { return 'SAMSUNG' }
  return 'OTHER'
}

function Test-IsLaptop {
  <#
  .SYNOPSIS
    Laptop test from chassis type, then PCSystemTypeEx, then (tie-breaker) a non-UPS battery.
  .DESCRIPTION
    Spec 8.0. Chassis 8, 9, 10, 11, 14, 30, 31, 32 are portable. PCSystemTypeEx 2 (Mobile) and
    8 (Slate) are portable. A battery only decides when nothing else did, and a battery whose Name
    or DeviceID contains "UPS" is ignored because desktops with a USB UPS report one.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()][AllowEmptyCollection()][int[]]$ChassisTypes,
    [int]$PCSystemTypeEx = 0,
    [AllowNull()][AllowEmptyCollection()][object[]]$Batteries
  )

  foreach ($type in @($ChassisTypes)) {
    if ($type -in 8, 9, 10, 11, 14, 30, 31, 32) { return $true }
  }
  if ($PCSystemTypeEx -in 2, 8) { return $true }
  foreach ($battery in @($Batteries)) {
    if ($null -eq $battery) { continue }
    if (("$($battery.Name)" -notlike '*UPS*') -and ("$($battery.DeviceID)" -notlike '*UPS*')) { return $true }
  }
  return $false
}

function Test-FreshInstall {
  <#
  .SYNOPSIS
    True when Windows was installed no more than MaxAgeDays ago and the user's data is no larger
    than MaxUserDataGB.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][datetime]$InstallDate,
    [Parameter(Mandatory)][long]$UserDataBytes,
    [Parameter(Mandatory)][int]$MaxAgeDays,
    [Parameter(Mandatory)][double]$MaxUserDataGB,
    [datetime]$Now = (Get-Date)
  )

  $ageDays = ($Now - $InstallDate).TotalDays
  return ($ageDays -le $MaxAgeDays) -and ($UserDataBytes -le ($MaxUserDataGB * 1GB))
}

function Get-MachineInfo {
  <#
  .SYNOPSIS
    Reads the machine facts and returns the Machine hashtable (see the plan's "Shared shapes").
  .DESCRIPTION
    CIM and registry only. Win32_Battery returning nothing (desktops) is normal and not an error.
    InstallDate is stored as an ISO 8601 string (invariant culture) so it survives state.json.
    A virtual machine is never a laptop, whatever its emulated chassis says: VMs run in Desktop mode.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
  $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
  $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
  $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
  $enclosures = @(Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue)
  $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
  $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue) | Select-Object -First 1

  $manufacturer = "$($cs.Manufacturer)".Trim()
  $model = "$($cs.Model)".Trim()
  $serial = "$($bios.SerialNumber)".Trim()
  $biosUuid = "$($product.UUID)".Trim()
  $productVersion = "$($product.Version)".Trim()

  # ChassisTypes is a uint16[] on each enclosure instance; keep it as int[].
  [int[]]$chassisTypes = @($enclosures | ForEach-Object { $_.ChassisTypes } | Where-Object { $null -ne $_ })

  $brand = Resolve-Brand -Manufacturer $manufacturer -Model $model
  $isVM = Test-IsVirtualMachine -Manufacturer $manufacturer -Model $model
  $isLaptop = (-not $isVM) -and (Test-IsLaptop -ChassisTypes $chassisTypes -PCSystemTypeEx ([int]$cs.PCSystemTypeEx) -Batteries $batteries)

  $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $displayVersion = Get-ItemPropertyValue -LiteralPath $key -Name DisplayVersion -ErrorAction SilentlyContinue
  if (-not $displayVersion) {
    # Windows 10 before 20H2 has no DisplayVersion, only ReleaseId (1909, 2004).
    $displayVersion = Get-ItemPropertyValue -LiteralPath $key -Name ReleaseId -ErrorAction SilentlyContinue
  }

  $osBuild = [int]$os.BuildNumber
  $installDate = ''
  if ($os.InstallDate -is [datetime]) {
    $installDate = $os.InstallDate.ToString('s', [Globalization.CultureInfo]::InvariantCulture)
  }

  $friendlyModel = $model
  if ($brand -eq 'LENOVO' -and $productVersion) { $friendlyModel = $productVersion }

  return @{
    Manufacturer     = $manufacturer
    Model            = $model
    FriendlyModel    = $friendlyModel
    Brand            = $brand
    Serial           = $serial
    BiosUuid         = $biosUuid
    ChassisTypes     = $chassisTypes
    IsLaptop         = $isLaptop
    IsVM             = $isVM
    Arch             = $(if ($cpu -and $cpu.Architecture -eq 12) { 'ARM64' } else { 'x64' })
    OsCaption        = "$($os.Caption)".Trim()
    OsBuild          = $osBuild
    OsDisplayVersion = "$displayVersion"
    IsWindows10      = ($osBuild -lt 22000)
    InstallDate      = $installDate
    ComputerName     = $env:COMPUTERNAME
    NewName          = (New-PcName -Brand $brand -Serial $serial -BiosUuid $biosUuid)
  }
}

function Test-OnACPower {
  <#
  .SYNOPSIS
    True when the machine runs on mains power (used before BIOS/firmware flashing).
  .DESCRIPTION
    A desktop has no battery and reports Online. PowerLineStatus can also be Unknown on some
    hardware and virtual machines; there is no battery to run out there, so Unknown counts as
    AC. Only a definite Offline (running on battery) returns false.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  Add-Type -AssemblyName System.Windows.Forms
  $status = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
  return ($status -eq 'Online') -or ($status -eq 'Unknown')
}

function Get-ProcessUserName {
  # The account this process runs as, DOMAIN\user (the elevated token's user). Read-only.
  [CmdletBinding()]
  [OutputType([string])]
  param()

  return [string][Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-SignedInUserName {
  # The account signed in at the console, DOMAIN\user (Win32_ComputerSystem.UserName): empty in an RDP
  # session or early in a logon. Read-only; throws when CIM cannot be read.
  [CmdletBinding()]
  [OutputType([string])]
  param()

  return [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
}

function Test-AdminProtection {
  <#
  .SYNOPSIS
    Whether setup runs as another account than the one signed in: 'On', 'Off' or 'Unknown' (toolbox spec 5.3).
  .DESCRIPTION
    Windows Administrator protection (KB5120998) runs elevated programs as a hidden admin account, so HKCU
    and the resume task would belong to that account; an admin password typed for another account does the
    same. The process user (Get-ProcessUserName) is compared with the signed-in user (Get-SignedInUserName),
    ignoring case: equal is 'Off', different is 'On'. An empty signed-in name (RDP, an early logon) or a read
    that fails is 'Unknown'. Never throws and logs nothing: the callers decide and log.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  try {
    $processUser = [string](Get-ProcessUserName)
    $signedInUser = [string](Get-SignedInUserName)
  } catch {
    return 'Unknown'
  }
  if ([string]::IsNullOrWhiteSpace($signedInUser)) { return 'Unknown' }
  if ([string]::Equals($processUser, $signedInUser, [StringComparison]::OrdinalIgnoreCase)) { return 'Off' }
  return 'On'
}

function Get-UserDataBytes {
  <#
  .SYNOPSIS
    Total size in bytes of the files in the current user's Desktop, Documents and Downloads.
  .DESCRIPTION
    Never throws. Unreadable files and folders are skipped. If something unexpected fails, the
    result is [long]::MaxValue so the fresh-install guard errs on the side of "this machine is used".
  #>
  [CmdletBinding()]
  [OutputType([long])]
  param()

  try {
    $downloads = $null
    try {
      $downloads = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
    } catch {
      $downloads = $null # no shell namespace in this session: use the default location below
    }
    if (-not $downloads) { $downloads = Join-Path $env:USERPROFILE 'Downloads' }

    # Redirected folders can point at the same place, so count each path once.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), $downloads)) {
      if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
      if (-not $seen.Add($folder)) { continue }
      $sum = Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
      if ($sum.Sum) { $total += [long]$sum.Sum }
    }
    return $total
  } catch {
    return [long]::MaxValue
  }
}
