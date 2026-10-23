# src/Repair/ToolRepairs.ps1
# Repair & diagnostics: Standard repair (repair spec 6.2), Post-clone (spec 6.3) and the DISM retry with a local source
# (spec 6.2, builder check 6).
#
# Standard repair keeps the old kit's order and its reasons: the clock first (downloads and signatures fail on a wrong
# clock), the disk scan (volumeScan, ToolChecks.ps1: Repair-Volume -Scan, which may fix errors online; ruling RD-R12),
# DISM RestoreHealth (dism.exe for its live percent and its exit code), sfc /scannow, then WinRE turned on only when the
# boot configuration and ReAgent.xml both say it is off. Post-clone adds a device rescan, the device and activation
# checks of the Health check, software left by another manufacturer, a page file on a missing drive, the TRIM state
# with ReTrim (SSD) or Analyze (HDD), a component cleanup and a Windows Update search.
#
# The rules (repair plan, Global Constraints):
#   - no verdict comes from a tool's text: exit codes (DISM's HRESULT is its exit code, compared by its 32 bits),
#     enum names (ServiceControllerStatus, ServiceStartMode, MediaType, the update search's ResultCode), CIM, the
#     registry and CBS.log (Read-ToolSfcResult). DISM's and SFC's own output is redirected to the log folder for the
#     progress tick only;
#   - every native tool runs through Invoke-ToolNative (Invoke-External with a step timeout); every cmdlet that can hang
#     (Get-WindowsImage, Get-PhysicalDisk, Optimize-Volume, Repair-WindowsImage, the Windows Update search) runs in a
#     bounded grandchild (Invoke-ToolJsonChild) whose command returns one hashtable;
#   - nothing waits without a deadline: the time service is polled with Wait-SetupDelay, counting the slices (never the
#     wall clock, which this very step moves: ruling RD-R8);
#   - nothing here changes a setting it only reports: the time service's start type, the TRIM registry value and the
#     page file are read, never written; the component store is cleaned up, never reset; the DISM retry with a local
#     source runs only when the technician picked it in the window (the file is unsigned, builder check 6), so a
#     source failure here only OFFERS it ($Run.Offers.DismSource, which the window's Offer dismSource reads);
#   - every log line and finding argument is ASCII (Add-ToolFinding and Add-ToolLog run ConvertTo-ScreenText).
#
# Needs ToolEngine (Invoke-ToolNative, Invoke-ToolJsonChild, Add-ToolFinding, Add-ToolLog, Format-ToolExitCode,
# Get-ToolStepTimeout, Get-ToolStepName), ToolChecks (Read-ToolSfcResult, Get-ToolWinReState, Get-ToolCheckError,
# Get-ToolSystemLetter), ToolSafety (Test-ToolInternet, Get-ToolRepairSetting, Get-ToolRepairNumber), Reboot
# (Get-RebootRegistryValue), Detection (Resolve-Brand, Get-SignedInUserName), Winget (ConvertTo-PowerShellLiteral),
# Activity (Wait-SetupDelay), Logging and StartScreen (ConvertTo-ScreenText). The bundle holds every file.

# DISM's exit codes (HRESULTs, compared by their 32 bits): the source files could not be found (CBS_E_SOURCE_MISSING,
# CBS_E_DOWNLOAD_FAILURE, CBS_E_SOURCE_MISSING_FROM_PSF), and a servicing operation waits for a restart
# (CBS_E_PENDING). PowerShell reads these hex literals as negative Int32s; ConvertTo-ToolExitBits makes both sides
# unsigned before they are compared.
$script:DismSourceFailureCodes = @(0x800F081F, 0x800F0906, 0x800F0950)
$script:DismPendingCode = 0x800F082F

$script:ToolDismArguments = '/Online /Cleanup-Image /RestoreHealth'

# The machine's Uninstall views (64- and 32-bit). The signed-in user's own view is added by its SID (review I-12):
# the elevated process's HKCU may be another account's.
$script:ToolMachineUninstallKeys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

# Brands whose leftover check is skipped: a whitebox or an unknown maker, a virtual machine, and Samsung.
$script:ToolOemSkippedBrands = @('OTHER', 'VM', 'SAMSUNG')

# The images inside an install.wim or install.esd (<P> is the file, as a literal): one row per index with its edition,
# architecture (the DISM module's number or enum name: 0 x86, 9 x64, 12 ARM64), languages and version. Read only.
$script:ToolInstallImageCommand = @'
@{ Items = @(foreach ($image in @(Get-WindowsImage -ImagePath <P>)) {
  $detail = Get-WindowsImage -ImagePath <P> -Index $image.ImageIndex
  @{ Index = [int]$detail.ImageIndex; Name = [string]$detail.ImageName; EditionId = [string]$detail.EditionId
     Architecture = [string]$detail.Architecture; Languages = @(foreach ($l in @($detail.Languages)) { [string]$l }); Version = [string]$detail.Version } }) }
'@

# The media type(s) of the physical disk(s) holding the system volume (<L> is its letter): enum names (SSD, HDD,
# Unspecified, SCM), never localized.
$script:ToolMediaCommand = @'
$numbers = @(Get-Partition -DriveLetter '<L>' | ForEach-Object { [string]$_.DiskNumber })
@{ Media = @(Get-PhysicalDisk | Where-Object { $numbers -contains [string]$_.DeviceId } | ForEach-Object { [string]$_.MediaType }) }
'@

# ReTrim (an SSD) or Analyze (an HDD) of the system volume (<L>, <Mode>).
$script:ToolRetrimCommand = @'
$null = Optimize-Volume -DriveLetter '<L>' -<Mode>
@{ Done = $true }
'@

# The component store's cleanup (spec 6.3): superseded components only; the base is never reset, so installed
# updates can still be uninstalled.
$script:ToolComponentCleanupCommand = @'
$image = Repair-WindowsImage -Online -StartComponentCleanup -NoRestart
@{ Done = $true; RestartNeeded = [bool]$image.RestartNeeded }
'@

# A Windows Update search for what is not installed and not hidden (Plan call: a WUA search, so the result is known).
# Nothing is downloaded or installed. ResultCode is OperationResultCode (2 succeeded, 3 succeeded with errors).
$script:ToolWuScanCommand = @'
$session = New-Object -ComObject 'Microsoft.Update.Session'
$found = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
@{ ResultCode = [int]$found.ResultCode; Count = [int]$found.Updates.Count }
'@

# --- Helpers ------------------------------------------------------------------------------------------------------

function ConvertTo-ToolExitBits {
  # Private. An exit code's 32 bits as a [uint32] (-2146498529 and 0x800F081F are the same code), or $null for
  # $null, text or a number outside 32 bits.
  [CmdletBinding()]
  param([AllowNull()]$ExitCode)

  if ($null -eq $ExitCode) { return $null }
  $n = [long]0
  if (-not [long]::TryParse([string]$ExitCode, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $null }
  if ($n -lt 0 -and $n -ge [int]::MinValue) { $n += 4294967296 }
  if ($n -lt 0 -or $n -gt 4294967295) { return $null }
  return [uint32]$n
}

function Test-ToolExitCodeIn {
  # Private. $true when -ExitCode has the same 32 bits as one of -Codes.
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()]$ExitCode, [Parameter(Mandatory)][object[]]$Codes)

  $bits = ConvertTo-ToolExitBits -ExitCode $ExitCode
  if ($null -eq $bits) { return $false }
  foreach ($code in $Codes) {
    $other = ConvertTo-ToolExitBits -ExitCode $code
    if ($null -ne $other -and $other -eq $bits) { return $true }
  }
  return $false
}

function Get-ToolSystemTool {
  # Private. The full path of a tool in %windir%\System32 (-Name 'dism.exe').
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Name)

  return [IO.Path]::Combine([string]$env:windir, 'System32', $Name)
}

function Get-ToolArgsEntry {
  # Private. $Run.Args.<Section>.<Name> when both exist (hashtables from the args), else $null.
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Name)

  $part = $Run.Args[$Section]
  if ($part -is [System.Collections.IDictionary] -and $part.Contains($Name)) { return $part[$Name] }
  return $null
}

function Get-ToolServiceState {
  # Private. A service's Status and StartType names (ServiceControllerStatus, ServiceStartMode: enum names, never
  # localized) as @{ Status; StartType }, or $null when it cannot be read (logged as a WARN).
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Name)

  try {
    $service = @(Get-Service -Name $Name -ErrorAction Stop) | Select-Object -First 1
    if ($null -eq $service) { return $null }
    return @{ Status = [string]$service.Status; StartType = [string]$service.StartType }
  } catch {
    Write-SetupLog -Level WARN -Message 'A service could not be read' -Data @{ service = $Name; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    return $null
  }
}

# --- Time sync (spec 6.2.1) ---------------------------------------------------------------------------------------

function Start-ToolTimeService {
  # Private. Starts w32time (sc.exe start w32time: exit 0, or 1056 when it already runs) and waits up to
  # toolStep.service minutes for Running, in 2 s Wait-SetupDelay slices (counted, never the wall clock). '' when it
  # runs, else the reason (ASCII).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $start = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'sc.exe') -ArgumentList 'start w32time' -StepTimeout 'service'
  if ($start.TimedOut) { return 'sc start timed out' }
  if ($start.ExitCode -ne 0 -and $start.ExitCode -ne 1056) { return ('sc start returned {0}' -f (Format-ToolExitCode -ExitCode $start.ExitCode)) }
  $slices = [int][math]::Ceiling((Get-ToolStepTimeout -Run $Run -Name 'service') * 60 / 2)
  for ($i = 0; $i -le $slices; $i++) {
    if ($i -gt 0) { Wait-SetupDelay -Seconds 2 }
    $state = Get-ToolServiceState -Name 'w32time'
    if ($null -ne $state -and $state.Status -ceq 'Running') { return '' }
  }
  return 'the Windows Time service did not start'
}

function Invoke-ToolStepTimeSync {
  <#
  .SYNOPSIS
    Step timeSync (spec 6.2.1): the Windows Time service started, w32tm.exe /resync, then the clock offset measured.
    $Run.Data.TimeSync = @{ Synced; ClockOffsetSeconds; StartType }.
  .DESCRIPTION
    - w32time's start type (Get-Service): Disabled is WARN timeServiceDisabled and no sync: the start type is never
      changed. A service that cannot be read is WARN timeSyncFailed.
    - Otherwise sc.exe start w32time (exit 0, or 1056 when it already runs) and up to toolStep.service minutes for
      Running; then w32tm.exe /resync (toolStep.timeSync). Any failure on the way is WARN timeSyncFailed with the
      reason (the exit code as 0x...).
    - Then, synced or not, the clock offset from Test-ToolInternet (the HTTPS Date header of the internet check):
      more than repair.thresholds.clockOffsetMinutes (2) either way is WARN clockOff with the minutes (one decimal,
      "downloads may fail"); no measurement is INFO clockUnknown.
    'warn' when a WARN was added, else 'done'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $status = 'done'
  $synced = $false
  $service = Get-ToolServiceState -Name 'w32time'
  $startType = if ($null -eq $service) { '' } else { $service.StartType }
  if ($null -eq $service) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'timeSyncFailed' -Arguments @('the Windows Time service could not be read')
    $status = 'warn'
  } elseif ($service.StartType -ceq 'Disabled') {
    Add-ToolFinding -Run $Run -Level WARN -Code 'timeServiceDisabled'
    $status = 'warn'
  } else {
    $problem = Start-ToolTimeService -Run $Run
    if ($problem -eq '') {
      $sync = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'w32tm.exe') -ArgumentList '/resync' -StepTimeout 'timeSync'
      if ($sync.TimedOut) {
        $problem = 'w32tm /resync timed out'
      } elseif ($sync.ExitCode -ne 0) {
        $problem = 'w32tm /resync returned {0}' -f (Format-ToolExitCode -ExitCode $sync.ExitCode)
      } else {
        $synced = $true
      }
    }
    if ($problem -ne '') {
      Add-ToolFinding -Run $Run -Level WARN -Code 'timeSyncFailed' -Arguments @($problem)
      $status = 'warn'
    }
  }

  $offset = $null
  try {
    $check = Test-ToolInternet -Config $Run.Config
    if ($check -is [System.Collections.IDictionary] -and $null -ne $check['ClockOffsetSeconds']) { $offset = [double]$check['ClockOffsetSeconds'] }
  } catch {
    Write-SetupLog -Level WARN -Message 'The clock offset could not be measured' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  $Run.Data['TimeSync'] = @{ Synced = $synced; ClockOffsetSeconds = $offset; StartType = (ConvertTo-ScreenText -Text $startType) }
  if ($null -eq $offset) {
    Add-ToolLog -Run $Run -Text ('Time sync: synced {0}, clock offset unknown' -f $synced)
    Add-ToolFinding -Run $Run -Level INFO -Code 'clockUnknown'
    return $status
  }
  $minutes = [math]::Abs($offset) / 60
  Add-ToolLog -Run $Run -Text ('Time sync: synced {0}, clock offset {1} s' -f $synced, $offset.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))
  $limit = Get-ToolRepairNumber -Config $Run.Config -Path 'thresholds', 'clockOffsetMinutes' -Default 2
  if ($minutes -gt $limit) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'clockOff' -Arguments @($minutes.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))
    $status = 'warn'
  }
  return $status
}

# --- DISM (spec 6.2.3) --------------------------------------------------------------------------------------------

function Resolve-ToolDismResult {
  <#
  .SYNOPSIS
    Private. Judges a dism.exe /RestoreHealth run by its exit code alone and returns the step result. Sets
    $Run.Data.DismOk for SFC, $Run.Data.DismPending for the runner and $Run.Data.Dism = @{ ExitCode; LocalSource }.
  .DESCRIPTION
      timed out                         : CRIT stepTimedOut (the step's name, -TimeoutMinutes), 'timedout';
      0                                 : 'done';
      3010                              : INFO dismRestart, RestartRequired, 'done';
      0x800F082F ($DismPendingCode)     : WARN restartFirst and $Run.Data.DismPending, 'warn'. The runner treats
                                          DismPending as a pending servicing restart: the action stops before the next
                                          servicing step (SFC) with NeedsRestart and no second restartFirst (spec 5,
                                          review M1);
      a source failure ($DismSourceFailureCodes), from Windows Update (no -LocalSource): WARN dismSourceMissing and
                                          the offer of a local source (Find-ToolInstallSource -> $Run.Offers.DismSource);
                                          without one, INFO dismSourceUnreadable (install files were found and none
                                          could be read: final wave item 14), INFO dismNoMatchingImage (install files
                                          were found, none for this PC: its edition and architecture) or INFO
                                          dismNoSource (no install file at all); 'warn'. The retry is never run here
                                          (builder check 6);
      anything else, and a source failure of the retry itself (-LocalSource: the file the technician picked could not
      repair this PC; nothing is offered again): CRIT dismFailed with the code, 'failed'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][hashtable]$Native,
    [Parameter(Mandatory)][string]$StepId,
    [double]$TimeoutMinutes,
    [switch]$LocalSource
  )

  $code = $Native.ExitCode
  $text = Format-ToolExitCode -ExitCode $code
  $Run.Data['DismOk'] = $false
  $Run.Data['Dism'] = @{ ExitCode = $text; LocalSource = [bool]$LocalSource }
  Add-ToolLog -Run $Run -Text ('DISM RestoreHealth: {0}' -f $text)
  if ($Native.TimedOut -or $null -eq $code) {
    Add-ToolFinding -Run $Run -Level CRIT -Code 'stepTimedOut' -Arguments @((Get-ToolStepName -Id $StepId), [math]::Round($TimeoutMinutes, 1))
    return 'timedout'
  }
  if ($code -eq 0) {
    $Run.Data['DismOk'] = $true
    return 'done'
  }
  if ($code -eq 3010) {
    $Run.Data['DismOk'] = $true
    $Run.RestartRequired = $true
    Add-ToolFinding -Run $Run -Level INFO -Code 'dismRestart'
    return 'done'
  }
  if (Test-ToolExitCodeIn -ExitCode $code -Codes @($script:DismPendingCode)) {
    $Run.Data['DismPending'] = $true
    Add-ToolFinding -Run $Run -Level WARN -Code 'restartFirst'
    return 'warn'
  }
  if (-not $LocalSource -and (Test-ToolExitCodeIn -ExitCode $code -Codes $script:DismSourceFailureCodes)) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'dismSourceMissing' -Arguments @($text)
    $source = Find-ToolInstallSource -Run $Run
    if ($source -is [System.Collections.IDictionary]) {
      $Run.Offers['DismSource'] = $source
      Add-ToolLog -Run $Run -Text ('A local source can be offered: {0} index {1}' -f $source['Path'], $source['Index'])
    } else {
      $search = $Run.Data['DismSourceSearch']
      $found = 0
      $unreadable = 0
      if ($search -is [System.Collections.IDictionary]) { $found = @($search['Files']).Count; $unreadable = [int]$search['Unreadable'] }
      if ($found -gt 0 -and $unreadable -ge $found) {
        Add-ToolFinding -Run $Run -Level INFO -Code 'dismSourceUnreadable'
      } elseif ($found -gt 0) {
        Add-ToolFinding -Run $Run -Level INFO -Code 'dismNoMatchingImage' -Arguments @($search['Edition'], $search['Arch'])
      } else {
        Add-ToolFinding -Run $Run -Level INFO -Code 'dismNoSource'
      }
    }
    return 'warn'
  }
  Add-ToolFinding -Run $Run -Level CRIT -Code 'dismFailed' -Arguments @($text)
  return 'failed'
}

function Invoke-ToolStepDism {
  <#
  .SYNOPSIS
    Step dism (servicing): dism.exe /Online /Cleanup-Image /RestoreHealth through Invoke-ToolNative (toolStep.dism; the
    output goes to the log folder for the live percent), judged by Resolve-ToolDismResult.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $timeout = Get-ToolStepTimeout -Run $Run -Name 'dism'
  $native = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'dism.exe') -ArgumentList $script:ToolDismArguments -StepTimeout 'dism' -OutputName 'dism'
  return (Resolve-ToolDismResult -Run $Run -Native $native -StepId 'dism' -TimeoutMinutes $timeout)
}

function Get-ToolInstallSourceRoots {
  <#
  .SYNOPSIS
    The drive roots where an install.wim or install.esd may be (spec 6.2.3): the stick (-StickRoot, 'E:\'), then every
    ready CD-ROM or removable drive (a mounted ISO is a CD-ROM), each once, upper case ('E:\'). -Drives is a seam (tests
    pass objects with Name, DriveType and IsReady); by default [IO.DriveInfo]::GetDrives(). Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [AllowNull()][AllowEmptyString()][string]$StickRoot,
    [AllowNull()][object[]]$Drives
  )

  $roots = New-Object System.Collections.Generic.List[string]
  if ($StickRoot -match '^[A-Za-z]:\\\z') { $roots.Add($StickRoot.ToUpperInvariant()) }
  try {
    if (-not $PSBoundParameters.ContainsKey('Drives')) { $Drives = @([IO.DriveInfo]::GetDrives()) }
    foreach ($drive in @($Drives)) {
      if ($null -eq $drive) { continue }
      $root = ([string]$drive.Name).ToUpperInvariant()
      if ($root -notmatch '^[A-Z]:\\\z' -or [string]$drive.DriveType -cnotin 'CDRom', 'Removable') { continue }
      if ($drive.IsReady -ne $true -or $roots.Contains($root)) { continue }
      $roots.Add($root)
    }
  } catch {
    Write-SetupLog -Level WARN -Message 'The drives could not be listed for an install source' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  return [string[]]$roots.ToArray()
}

function ConvertTo-ToolImageArch {
  # Private. An image's architecture (the DISM module's number or enum name) as the window's names: 'x86', 'x64',
  # 'ARM64', or '' for anything else (never offered).
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Value)

  switch ($Value.Trim()) {
    { $_ -in '0', 'x86' } { return 'x86' }
    { $_ -in '9', 'x64', 'amd64' } { return 'x64' }
    { $_ -in '12', 'arm64' } { return 'ARM64' }
  }
  return ''
}

function Get-ToolPcLanguage {
  # Private. Windows' install language (Nls\Language InstallLanguage, a hex LCID such as 040D) as a culture name
  # ('he-IL'), or '' when it cannot be read.
  [CmdletBinding()]
  [OutputType([string])]
  param()

  try {
    $hex = [string](Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name 'InstallLanguage')
    if ($hex -notmatch '^[0-9A-Fa-f]{1,8}\z') { return '' }
    return [string][Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($hex, 16)).Name
  } catch {
    return ''
  }
}

function Find-ToolInstallSource {
  <#
  .SYNOPSIS
    An install.wim or install.esd that could repair this PC (spec 6.2.3): the offer @{ Path; Type ('wim'|'esd'); Index;
    Edition; Arch; Languages = [string[]]; Build; BuildDiffers; LanguageDiffers; PcLanguage } for the window
    (Offer dismSource), or $null. Never throws. Nothing is run against the file but Get-WindowsImage.
  .DESCRIPTION
    Candidates: <root>\sources\install.wim, then install.esd, of each root of Get-ToolInstallSourceRoots (the stick
    first, then every ready CD-ROM or removable drive). Split images (.swm) are not supported (Plan call). One
    grandchild per file (installImage: Get-WindowsImage -ImagePath, then -Index for each image). The first image whose
    EditionId equals this PC's EditionID (registry, any case) AND whose architecture is this PC's (Args.Machine.Arch;
    a mismatch is never offered, Plan call) is the offer, and the search stops. BuildDiffers: the image's build (the
    third part of its version) is not this PC's (Args.Machine.OsBuild); LanguageDiffers: its languages lack this PC's
    install language (PcLanguage). Without this PC's edition or architecture nothing is offered.
    What was looked at is kept in $Run.Data.DismSourceSearch = @{ Files = [string[]] (the candidate files found);
    Edition; Arch ('unknown' when not known); Unreadable (how many of the files the installImage grandchild could not
    read) }, so the dism step can tell "no install file" (dismNoSource) from "install files, none for this PC"
    (dismNoMatchingImage; review M2) and "install files, none readable" (dismSourceUnreadable; final wave item 14).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Run)

  $files = New-Object System.Collections.Generic.List[string]
  $search = @{ Files = [string[]]@(); Edition = 'unknown'; Arch = 'unknown'; Unreadable = 0 }
  $Run.Data['DismSourceSearch'] = $search
  try {
    $edition = ([string](Get-RebootRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID')).Trim()
    $arch = ConvertTo-ToolImageArch -Value ([string](Get-ToolArgsEntry -Run $Run -Section 'Machine' -Name 'Arch'))
    if ($edition -ne '') { $search['Edition'] = ConvertTo-ScreenText -Text $edition }
    if ($arch -ne '') { $search['Arch'] = $arch }
    foreach ($root in @(Get-ToolInstallSourceRoots -StickRoot ([string]$Run.Args['StickRoot']))) {
      foreach ($type in 'wim', 'esd') {
        $path = $root + 'sources\install.' + $type
        if (Test-Path -LiteralPath $path -PathType Leaf) { $files.Add($path) }
      }
    }
    $search['Files'] = [string[]]$files.ToArray()
    if ($files.Count -eq 0) { return $null }
    if ($edition -eq '' -or $arch -eq '') {
      Add-ToolLog -Run $Run -Text 'No install image looked at: this PC''s edition or architecture is unknown'
      return $null
    }
    $osBuild = [string](Get-ToolArgsEntry -Run $Run -Section 'Machine' -Name 'OsBuild')
    if ($osBuild -notmatch '^[0-9]+\z') { $osBuild = [string][Environment]::OSVersion.Version.Build }
    $pcLanguage = Get-ToolPcLanguage

    foreach ($path in $files) {
      $type = $path.Substring($path.Length - 3)
      Add-ToolLog -Run $Run -Text ('Reading the images in {0}' -f $path)
      $child = Invoke-ToolJsonChild -Run $Run -Name 'installImage' -Command ($script:ToolInstallImageCommand.Replace('<P>', (ConvertTo-PowerShellLiteral -Text $path))) -StepTimeout 'grandchild'
      if (-not $child.Ok) {
        Add-ToolLog -Run $Run -Text ('{0} could not be read: {1}' -f $path, $child.Error)
        $search['Unreadable'] = [int]$search['Unreadable'] + 1
        continue
      }
      foreach ($image in @($child.Data['Items'])) {
        if ($image -isnot [System.Collections.IDictionary]) { continue }
        $index = 0
        if (-not [int]::TryParse([string]$image['Index'], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$index) -or $index -lt 1 -or $index -gt 99) { continue }
        if (-not [string]::Equals(([string]$image['EditionId']).Trim(), $edition, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ((ConvertTo-ToolImageArch -Value ([string]$image['Architecture'])) -cne $arch) { continue }
        $languages = [string[]]@(foreach ($l in @($image['Languages'])) {
            $name = (([string]$l).Trim() -split '\s+')[0]
            if ($name -ne '') { ConvertTo-ScreenText -Text $name }
          })
        $parts = ([string]$image['Version']).Split('.')
        $build = if ($parts.Count -ge 3) { ConvertTo-ScreenText -Text $parts[2] } else { '' }
        $languageDiffers = ($pcLanguage -ne '') -and -not (@($languages) -contains $pcLanguage)
        return @{
          Path            = $path
          Type            = $type
          Index           = $index
          Edition         = (ConvertTo-ScreenText -Text ([string]$image['EditionId']).Trim())
          Arch            = $arch
          Languages       = $languages
          Build           = $build
          BuildDiffers    = ($build -ne $osBuild)
          LanguageDiffers = $languageDiffers
          PcLanguage      = (ConvertTo-ScreenText -Text $pcLanguage)
        }
      }
      Add-ToolLog -Run $Run -Text ('{0} holds no {1} {2} image' -f $path, $edition, $arch)
    }
  } catch {
    Write-SetupLog -Level WARN -Message 'Looking for an install source failed' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  return $null
}

function Get-ToolDismSourceOptions {
  # Private. The DISM retry's Options checked again in the child (the window built them from the offer, but the args
  # file is the only thing the child trusts): @{ Path; Type; Index }. Throws with an ASCII reason when the Path is not
  # <X>:\sources\install.wim|esd on an existing file, its drive is not the stick or a mounted ISO (a root of
  # Get-ToolInstallSourceRoots: the stick, a ready CD-ROM or removable drive; spec 6.2, review M9), the Type is not
  # wim|esd or not the file's, or the Index is not a whole number 1..99.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $options = $Run.Args['Options']
  if ($options -isnot [System.Collections.IDictionary]) { throw 'The DISM source options are missing' }
  $path = $options['Path']
  if ($path -isnot [string] -or $path -notmatch '^[A-Za-z]:\\sources\\install\.(wim|esd)\z') { throw 'The DISM source is not <drive>:\sources\install.wim or install.esd' }
  $extension = $Matches[1].ToLowerInvariant()
  $root = $path.Substring(0, 3).ToUpperInvariant()
  if (@(Get-ToolInstallSourceRoots -StickRoot ([string]$Run.Args['StickRoot'])) -notcontains $root) {
    throw 'The DISM source is not on the stick or a mounted ISO'
  }
  $type = $options['Type']
  if ($type -isnot [string] -or $type -cnotin 'wim', 'esd' -or $type -cne $extension) { throw 'The DISM source type is not wim or esd, or not the file''s' }
  $value = $options['Index']
  $index = 0
  if (-not ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) -or
      [math]::Floor([double]$value) -ne [double]$value -or [double]$value -lt 1 -or [double]$value -gt 99) {
    throw 'The DISM source index is not a whole number from 1 to 99'
  }
  $index = [int]$value
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The DISM source file is not there any more' }
  return @{ Path = $path; Type = $type; Index = $index }
}

function Invoke-ToolStepDismSource {
  <#
  .SYNOPSIS
    Step dismSource (servicing; the action the technician picked from the offer, builder check 6): the Options checked
    again (Get-ToolDismSourceOptions; refused options throw, so the step is failed with stepFailed and dism never
    runs), then dism.exe /Online /Cleanup-Image /RestoreHealth /Source:<Type>:<Path>:<Index> /LimitAccess, judged like
    the dism step (Resolve-ToolDismResult -LocalSource: a source failure is dismFailed, nothing is offered again).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $source = Get-ToolDismSourceOptions -Run $Run
  $arguments = '{0} /Source:{1}:{2}:{3} /LimitAccess' -f $script:ToolDismArguments, $source.Type, $source.Path, $source.Index
  Add-ToolLog -Run $Run -Text ('DISM with the local source {0} index {1}' -f $source.Path, $source.Index)
  $timeout = Get-ToolStepTimeout -Run $Run -Name 'dism'
  $native = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'dism.exe') -ArgumentList $arguments -StepTimeout 'dism' -OutputName 'dism'
  return (Resolve-ToolDismResult -Run $Run -Native $native -StepId 'dismSource' -TimeoutMinutes $timeout -LocalSource)
}

# --- SFC (spec 6.2.4) ---------------------------------------------------------------------------------------------

function Invoke-ToolSfcPass {
  # Private. One sfc.exe /scannow (toolStep.sfc; its own output goes to the log folder for the tick and is never read
  # here), judged from CBS.log since it started (Read-ToolSfcResult): @{ TimedOut; ExitCode; Result }.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $since = Get-Date
  $native = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'sfc.exe') -ArgumentList '/scannow' -StepTimeout 'sfc' -OutputName 'sfc'
  if ($native.TimedOut) { return @{ TimedOut = $true; ExitCode = 'timed out'; Result = $null } }
  $cbs = Read-ToolSfcResult -Run $Run -Since $since
  foreach ($line in @($cbs.Lines)) { Write-SetupLog -Message ('CBS: ' + (ConvertTo-ScreenText -Text $line)) }
  Add-ToolLog -Run $Run -Text ('System files: {0} repaired, {1} could not be repaired' -f [int]$cbs.Repaired, [int]$cbs.CannotRepair)
  return @{ TimedOut = $false; ExitCode = (Format-ToolExitCode -ExitCode $native.ExitCode); Result = $cbs }
}

function Invoke-ToolStepSfc {
  <#
  .SYNOPSIS
    Step sfc (servicing): sfc.exe /scannow, judged from CBS.log's [SR] lines (review I-3). $Run.Data.Sfc =
    @{ Passes; Repaired; CannotRepair; SecondPass; ExitCode }.
  .DESCRIPTION
    - Timed out: WARN sfcTimedOut, 'timedout' (TrustedInstaller may go on; nothing else is killed).
    - Files it could not repair: CRIT sfcCannotRepair, plus CRIT dismAndSfcFailed when DISM failed in this run
      ($Run.Data.DismOk is $false), 'warn'.
    - It repaired something (Repaired > 0) and nothing was beyond repair: ONE second pass, and INFO sfcRepaired with
      the first pass's count and what the second did. The second pass starts after a wait longer than the CBS.log
      look-back ($script:ToolCbsLookbackSeconds + 1 s), so it never counts the first pass's last lines (review I1):
      'ran clean', 'still repaired files', 'could not repair everything' (with sfcCannotRepair as above), 'gave no
      result', or 'timed out' (with sfcTimedOut).
    - No completed verify in CBS.log: WARN sfcNotRun.
    - Else 'done'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $first = Invoke-ToolSfcPass -Run $Run
  if ($first.TimedOut) {
    $Run.Data['Sfc'] = @{ Passes = 1; TimedOut = $true }
    Add-ToolFinding -Run $Run -Level WARN -Code 'sfcTimedOut'
    return 'timedout'
  }
  $cbs = $first.Result
  $repaired = [int]$cbs.Repaired
  $cannot = [int]$cbs.CannotRepair
  $data = @{ Passes = 1; Repaired = $repaired; CannotRepair = $cannot; SecondPass = ''; ExitCode = $first.ExitCode }
  $Run.Data['Sfc'] = $data
  if ($cannot -gt 0) {
    Add-ToolSfcCannotRepair -Run $Run -Count $cannot
    return 'warn'
  }
  if ($repaired -gt 0) {
    # The second pass takes its start (Invoke-ToolSfcPass) after this wait: its look-back cannot reach the first pass.
    Wait-SetupDelay -Seconds ($script:ToolCbsLookbackSeconds + 1)
    $second = Invoke-ToolSfcPass -Run $Run
    $data['Passes'] = 2
    $status = 'done'
    if ($second.TimedOut) {
      $outcome = 'timed out'
      $status = 'timedout'
    } else {
      $again = $second.Result
      $data['CannotRepair'] = [int]$again.CannotRepair
      if ([int]$again.CannotRepair -gt 0) { $outcome = 'could not repair everything'; $status = 'warn' }
      elseif ([int]$again.Repaired -gt 0) { $outcome = 'still repaired files' }
      elseif (-not $again.VerifyComplete) { $outcome = 'gave no result' }
      else { $outcome = 'ran clean' }
    }
    $data['SecondPass'] = $outcome
    Add-ToolFinding -Run $Run -Level INFO -Code 'sfcRepaired' -Arguments @($repaired, $outcome)
    if ($second.TimedOut) { Add-ToolFinding -Run $Run -Level WARN -Code 'sfcTimedOut' }
    elseif ([int]$second.Result.CannotRepair -gt 0) { Add-ToolSfcCannotRepair -Run $Run -Count ([int]$second.Result.CannotRepair) }
    return $status
  }
  if (-not $cbs.VerifyComplete) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'sfcNotRun'
    return 'warn'
  }
  return 'done'
}

function Add-ToolSfcCannotRepair {
  # Private. CRIT sfcCannotRepair with -Count, and CRIT dismAndSfcFailed when DISM failed in this run.
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][int]$Count)

  Add-ToolFinding -Run $Run -Level CRIT -Code 'sfcCannotRepair' -Arguments @($Count)
  if ($Run.Data.ContainsKey('DismOk') -and $Run.Data['DismOk'] -eq $false) { Add-ToolFinding -Run $Run -Level CRIT -Code 'dismAndSfcFailed' }
}

# --- WinRE (spec 6.1, 6.2.5) --------------------------------------------------------------------------------------

function Invoke-ToolStepWinreFix {
  <#
  .SYNOPSIS
    Step winreFix: WinRE turned on only when the boot configuration and ReAgent.xml both say it is off (builder check
    7). $Run.Data.WinRe (before) and $Run.Data.WinReAfter (after reagentc).
  .DESCRIPTION
    Get-ToolWinReState, then:
      BCD unreadable                 : WARN winreUnreadable (ruling RD-R10), nothing run;
      CanEnable (BCD Off + ReAgent Off): reagentc.exe /enable; exit 0 and the BCD read again says On: INFO winreEnabled;
                                       any other exit, a timeout, or a BCD still not On: WARN winreEnableFailed;
      Off without ReAgent.xml's agreement (Missing, Unknown): WARN winreNoAgreement, nothing run (WinRE is off: the
                                       Health check's winreOff is WARN too; ruling RD-R20, review M8);
      the two disagree               : WARN winreUnknown, nothing run;
      On                             : 'done'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $state = Get-ToolWinReState -Run $Run
  $Run.Data['WinRe'] = $state
  Add-ToolLog -Run $Run -Text ('WinRE: boot configuration {0}, ReAgent.xml {1}: {2}' -f $state.Bcd, $state.ReAgent, $state.Verdict)
  if ($state.Bcd -ceq 'Unknown') {
    Add-ToolFinding -Run $Run -Level WARN -Code 'winreUnreadable' -Arguments @(Get-ToolCheckError -Run $Run -Name 'bcd')
    return 'warn'
  }
  if ($state.CanEnable) {
    $native = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'reagentc.exe') -ArgumentList '/enable' -StepTimeout 'native'
    if ($native.TimedOut) {
      Add-ToolFinding -Run $Run -Level WARN -Code 'winreEnableFailed' -Arguments @('timed out')
      return 'timedout'
    }
    if ($native.ExitCode -ne 0) {
      Add-ToolFinding -Run $Run -Level WARN -Code 'winreEnableFailed' -Arguments @(Format-ToolExitCode -ExitCode $native.ExitCode)
      return 'warn'
    }
    $after = Get-ToolWinReState -Run $Run
    $Run.Data['WinReAfter'] = $after
    if ($after.Bcd -ceq 'On') {
      Add-ToolFinding -Run $Run -Level INFO -Code 'winreEnabled'
      return 'done'
    }
    Add-ToolFinding -Run $Run -Level WARN -Code 'winreEnableFailed' -Arguments @('the boot configuration says {0} afterwards' -f $after.Bcd)
    return 'warn'
  }
  switch -CaseSensitive ($state.Verdict) {
    'On' { return 'done' }
    'Off' {
      Add-ToolFinding -Run $Run -Level WARN -Code 'winreNoAgreement'
      return 'warn'
    }
  }
  Add-ToolFinding -Run $Run -Level WARN -Code 'winreUnknown'
  return 'warn'
}

# --- Post-clone (spec 6.3) ----------------------------------------------------------------------------------------

function Invoke-ToolStepPnpScan {
  <#
  .SYNOPSIS
    Step pnpScan (Post-clone only; the Health check never rescans, spec 6.1): pnputil.exe /scan-devices
    (toolStep.pnpScan). Exit 0, or 3010 (RestartRequired): 'done'. Any other exit or a timeout: WARN pnpScanFailed.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $native = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'pnputil.exe') -ArgumentList '/scan-devices' -StepTimeout 'pnpScan'
  if ($native.TimedOut) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'pnpScanFailed' -Arguments @('timed out')
    return 'timedout'
  }
  Add-ToolLog -Run $Run -Text ('Device rescan: {0}' -f (Format-ToolExitCode -ExitCode $native.ExitCode))
  if ($native.ExitCode -eq 0) { return 'done' }
  if ($native.ExitCode -eq 3010) {
    $Run.RestartRequired = $true
    return 'done'
  }
  Add-ToolFinding -Run $Run -Level WARN -Code 'pnpScanFailed' -Arguments @(Format-ToolExitCode -ExitCode $native.ExitCode)
  return 'warn'
}

function Get-ToolUserSid {
  # Private seam. The SID of the account -UserName (DOMAIN\user) as text, or '' when it does not translate.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$UserName)

  try {
    return [string](New-Object Security.Principal.NTAccount $UserName).Translate([Security.Principal.SecurityIdentifier]).Value
  } catch {
    return ''
  }
}

function Get-ToolInstalledPrograms {
  <#
  .SYNOPSIS
    The DisplayNames of the installed programs (unique, in the order found): the machine's Uninstall keys (64- and
    32-bit) and the signed-in user's own view, HKEY_USERS\<SID>, the SID translated from Get-SignedInUserName. Never
    the elevated process's HKCU, which may be another account's (review I-12; Plan call). Never throws.
  .DESCRIPTION
    Without a signed-in user (an RDP session, an early logon) or a name that does not translate, only the machine
    views are read (logged). A view that cannot be read is skipped.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param()

  $keys = New-Object System.Collections.Generic.List[string]
  foreach ($key in $script:ToolMachineUninstallKeys) { $keys.Add($key) }
  $user = ''
  try { $user = ([string](Get-SignedInUserName)).Trim() } catch { $user = '' }
  if ($user -eq '') {
    Write-SetupLog -Level WARN -Message 'No signed-in user: the per-user programs were not read'
  } else {
    $sid = Get-ToolUserSid -UserName $user
    if ($sid -match '^S-1-[0-9]+(-[0-9]+)+\z') {
      $keys.Add('Registry::HKEY_USERS\' + $sid + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    } else {
      Write-SetupLog -Level WARN -Message 'The signed-in user has no SID here: the per-user programs were not read'
    }
  }
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($key in $keys) {
    try {
      foreach ($entry in @(Get-ItemProperty -Path ($key + '\*') -ErrorAction SilentlyContinue)) {
        if ($null -eq $entry) { continue }
        $property = $entry.PSObject.Properties['DisplayName']
        if ($null -eq $property) { continue }
        $name = ([string]$property.Value).Trim()
        if ($name -ne '' -and -not $names.Contains($name)) { $names.Add($name) }
      }
    } catch {
      Write-SetupLog -Level WARN -Message 'Installed programs could not be read' -Data @{ key = (ConvertTo-ScreenText -Text $key); error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
  }
  return [string[]]$names.ToArray()
}

function Get-ToolOemLeftovers {
  <#
  .SYNOPSIS
    The installed programs that are another manufacturer's system utility (the old kit's OEM check): every program
    (-Programs, display names) that matches (-like, any case) a pattern of repair.oemUtilities under a brand that is not
    -Brand, each once, in the order given. Pure.
  .DESCRIPTION
    oemUtilities names system utilities only, never printer or peripheral software (review I-9), so "HP Smart" on a
    Dell is not a leftover. Brand OTHER (a whitebox or an unknown maker), VM or SAMSUNG: nothing (the step reports
    oemSkipped).
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [AllowNull()][AllowEmptyCollection()][string[]]$Programs,
    [AllowNull()][AllowEmptyString()][string]$Brand,
    [AllowNull()]$Config
  )

  if ([string]::IsNullOrWhiteSpace($Brand) -or $script:ToolOemSkippedBrands -contains $Brand) { return [string[]]@() }
  $table = Get-ToolRepairSetting -Config $Config -Path 'oemUtilities' -Default $null
  $patterns = New-Object System.Collections.Generic.List[string]
  if ($table -is [System.Collections.IDictionary]) {
    foreach ($name in @($table.Keys)) { if ([string]$name -ne $Brand) { foreach ($p in @($table[$name])) { $patterns.Add([string]$p) } } }
  } elseif ($null -ne $table) {
    foreach ($property in $table.PSObject.Properties) { if ($property.Name -ne $Brand) { foreach ($p in @($property.Value)) { $patterns.Add([string]$p) } } }
  }
  $found = New-Object System.Collections.Generic.List[string]
  foreach ($program in @($Programs)) {
    $name = ([string]$program).Trim()
    if ($name -eq '') { continue }
    $seen = $false
    foreach ($f in $found) { if ([string]::Equals($f, $name, [StringComparison]::OrdinalIgnoreCase)) { $seen = $true } }
    if ($seen) { continue }
    foreach ($pattern in $patterns) {
      if ($pattern -ne '' -and $name -like $pattern) {
        $found.Add($name)
        break
      }
    }
  }
  return [string[]]$found.ToArray()
}

function Invoke-ToolStepOemLeftovers {
  <#
  .SYNOPSIS
    Step oemLeftovers: software another manufacturer left (a disk cloned from another brand's PC). The brand comes from
    the args' manufacturer and model (Resolve-Brand). OTHER, VM or SAMSUNG: INFO oemSkipped. Else
    Get-ToolOemLeftovers of Get-ToolInstalledPrograms: WARN oemLeftover with up to five names (and how many more).
    Nothing is uninstalled. $Run.Data.OemLeftovers = @{ Brand; Programs }.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $brand = Resolve-Brand -Manufacturer ([string](Get-ToolArgsEntry -Run $Run -Section 'Identity' -Name 'Manufacturer')) `
    -Model ([string](Get-ToolArgsEntry -Run $Run -Section 'Identity' -Name 'Model'))
  if ($script:ToolOemSkippedBrands -contains $brand) {
    $Run.Data['OemLeftovers'] = @{ Brand = $brand; Programs = [string[]]@() }
    Add-ToolFinding -Run $Run -Level INFO -Code 'oemSkipped'
    return 'done'
  }
  $found = @(Get-ToolOemLeftovers -Programs @(Get-ToolInstalledPrograms) -Brand $brand -Config $Run.Config)
  $names = [string[]]@(foreach ($n in $found) { ConvertTo-ScreenText -Text $n })
  $Run.Data['OemLeftovers'] = @{ Brand = $brand; Programs = $names }
  Add-ToolLog -Run $Run -Text ('Other makers'' software on this {0}: {1}' -f $brand, $names.Count)
  if ($names.Count -eq 0) { return 'done' }
  $shown = ($names | Select-Object -First 5) -join ', '
  if ($names.Count -gt 5) { $shown += ' and {0} more' -f ($names.Count - 5) }
  Add-ToolFinding -Run $Run -Level WARN -Code 'oemLeftover' -Arguments @($shown)
  return 'warn'
}

function Invoke-ToolStepPageFile {
  <#
  .SYNOPSIS
    Step pageFile: a page file set on a drive that is not there any more (a clone onto a PC without that disk). The
    Win32_PageFileSetting names (CIM, 15 s) whose drive Test-Path cannot find: WARN pageFileMissingDrive with the
    drives. A system-managed page file ('?:\pagefile.sys') is on any drive. Settings that cannot be read: WARN
    pageFileUnknown with the reason (review M6). Read only. $Run.Data.PageFile.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try {
    $settings = @(Get-CimInstance -ClassName Win32_PageFileSetting -OperationTimeoutSec 15 -ErrorAction Stop)
  } catch {
    $reason = ConvertTo-ScreenText -Text $_.Exception.Message
    $Run.Data['PageFile'] = @{ Error = $reason }
    Add-ToolFinding -Run $Run -Level WARN -Code 'pageFileUnknown' -Arguments @($reason)
    return 'warn'
  }
  $files = New-Object System.Collections.Generic.List[string]
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($setting in $settings) {
    if ($null -eq $setting) { continue }
    $name = [string]$setting.Name
    $files.Add((ConvertTo-ScreenText -Text $name))
    if ($name -notmatch '^([A-Za-z]:)\\') { continue }
    $drive = $Matches[1].ToUpperInvariant()
    if (-not $missing.Contains($drive) -and -not (Test-Path -LiteralPath ($drive + '\'))) { $missing.Add($drive) }
  }
  $Run.Data['PageFile'] = @{ Files = $files.ToArray(); MissingDrives = $missing.ToArray() }
  Add-ToolLog -Run $Run -Text ('Page files: {0}' -f $files.Count)
  if ($missing.Count -eq 0) { return 'done' }
  Add-ToolFinding -Run $Run -Level WARN -Code 'pageFileMissingDrive' -Arguments @($missing.ToArray() -join ', ')
  return 'warn'
}

function Invoke-ToolStepTrim {
  <#
  .SYNOPSIS
    Step trim: the TRIM state, then ReTrim on an SSD or Analyze on an HDD (spec 6.3). $Run.Data.Trim.
  .DESCRIPTION
    - HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem DisableDeleteNotification not 0: WARN trimOff with the value.
      It is never changed (Plan call: spec 6.3 lists the state only); a missing value is Windows' default, on.
    - The grandchild media (toolStep.disks) reads the system disk's MediaType. All SSD: Optimize-Volume -ReTrim; all
      HDD: Optimize-Volume -Analyze (grandchild retrim, toolStep.retrim); anything else (Unspecified, a mix, no
      answer): nothing is optimized, and INFO trimMediaUnknown says why (review M5). A failed or timed-out ReTrim is
      WARN retrimFailed, a failed or timed-out Analyze WARN analyzeFailed.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $status = 'done'
  $value = Get-RebootRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'DisableDeleteNotification'
  $setting = if ($null -eq $value) { '' } else { ConvertTo-ScreenText -Text ([string]$value) }
  $number = 0
  if ($setting -ne '' -and (-not [int]::TryParse($setting, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -ne 0)) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'trimOff' -Arguments @($setting)
    $status = 'warn'
  }
  $trim = @{ DisableDeleteNotification = $setting; Media = [string[]]@(); Mode = '' }
  $Run.Data['Trim'] = $trim
  $letter = Get-ToolSystemLetter
  if ($letter -eq '') {
    Add-ToolLog -Run $Run -Text 'TRIM: no system drive letter, nothing was optimized'
    return $status
  }
  $media = Invoke-ToolJsonChild -Run $Run -Name 'media' -Command ($script:ToolMediaCommand.Replace('<L>', $letter)) -StepTimeout 'disks'
  $kinds = [string[]]@()
  if ($media.Ok) { $kinds = [string[]]@(foreach ($m in @($media.Data['Media'])) { if ($null -ne $m) { ConvertTo-ScreenText -Text ([string]$m) } }) }
  $trim['Media'] = $kinds
  $mode = ''
  if ($kinds.Count -gt 0 -and @($kinds | Where-Object { $_ -cne 'SSD' }).Count -eq 0) { $mode = 'ReTrim' }
  elseif ($kinds.Count -gt 0 -and @($kinds | Where-Object { $_ -cne 'HDD' }).Count -eq 0) { $mode = 'Analyze' }
  $trim['Mode'] = $mode
  if ($mode -eq '') {
    $what = if (-not $media.Ok) { $media.Error } elseif ($kinds.Count -gt 0) { ($kinds -join ', ') } else { 'no disk found' }
    Add-ToolFinding -Run $Run -Level INFO -Code 'trimMediaUnknown' -Arguments @($what)
    return $status
  }
  $optimize = Invoke-ToolJsonChild -Run $Run -Name 'retrim' -Command ($script:ToolRetrimCommand.Replace('<L>', $letter).Replace('<Mode>', $mode)) -StepTimeout 'retrim'
  if (-not $optimize.Ok) {
    if ($mode -ceq 'ReTrim') {
      Add-ToolFinding -Run $Run -Level WARN -Code 'retrimFailed' -Arguments @($optimize.Error)
    } else {
      Add-ToolFinding -Run $Run -Level WARN -Code 'analyzeFailed' -Arguments @($optimize.Error)
    }
    if ($optimize.TimedOut) { return 'timedout' }
    return 'warn'
  }
  Add-ToolLog -Run $Run -Text ('Optimize-Volume -{0} of {1}: done' -f $mode, $letter)
  return $status
}

function Invoke-ToolStepComponentCleanup {
  <#
  .SYNOPSIS
    Step componentCleanup (servicing): Repair-WindowsImage -Online -StartComponentCleanup -NoRestart in the grandchild
    componentCleanup (toolStep.componentCleanup). The base is never reset (spec 6.3). A failure or timeout is WARN
    componentCleanupFailed; a cleanup that needs a restart sets RestartRequired.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $cleanup = Invoke-ToolJsonChild -Run $Run -Name 'componentCleanup' -Command $script:ToolComponentCleanupCommand -StepTimeout 'componentCleanup'
  if (-not $cleanup.Ok) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'componentCleanupFailed' -Arguments @($cleanup.Error)
    if ($cleanup.TimedOut) { return 'timedout' }
    return 'warn'
  }
  if ($cleanup.Data['RestartNeeded'] -eq $true) { $Run.RestartRequired = $true }
  Add-ToolLog -Run $Run -Text 'Component cleanup: done'
  return 'done'
}

function Invoke-ToolStepWuScan {
  <#
  .SYNOPSIS
    Step wuScan (Post-clone; Windows Update reset reuses it): a Windows Update search in the grandchild wuScan
    (toolStep.wuScan; Plan call: a WUA search rather than UsoClient, so the result is known). Nothing is downloaded or
    installed. $Run.Data.WuScan = @{ ResultCode; Count }.
  .DESCRIPTION
    No internet on the strip (Args.Strip.Internet 'crit'): INFO wuScanSkipped, 'skipped', no search. A clock the
    action's time sync could not fix and that is too far off for HTTPS ($Run.Data.TimeSync: Synced $false, a
    ClockOffsetSeconds above repair.thresholds.clockWrongMinutes, 60; Post-clone: final wave item 14): INFO
    wuScanClockSkipped, 'skipped', no search (it would fail; clockOff already names the cause). Updates found:
    INFO updatesAvailable with the count. A search that fails, times out or ends with a ResultCode other than 2
    (succeeded) or 3 (succeeded with errors): WARN wuScanFailed.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  if ([string](Get-ToolArgsEntry -Run $Run -Section 'Strip' -Name 'Internet') -ceq 'crit') {
    Add-ToolFinding -Run $Run -Level INFO -Code 'wuScanSkipped'
    return 'skipped'
  }
  $sync = $Run.Data['TimeSync']
  if ($sync -is [System.Collections.IDictionary] -and $sync['Synced'] -ne $true -and $null -ne $sync['ClockOffsetSeconds']) {
    $wrongMinutes = Get-ToolRepairNumber -Config $Run.Config -Path 'thresholds', 'clockWrongMinutes' -Default 60
    if (([math]::Abs([double]$sync['ClockOffsetSeconds']) / 60) -gt $wrongMinutes) {
      Add-ToolFinding -Run $Run -Level INFO -Code 'wuScanClockSkipped'
      return 'skipped'
    }
  }
  $search = Invoke-ToolJsonChild -Run $Run -Name 'wuScan' -Command $script:ToolWuScanCommand -StepTimeout 'wuScan'
  if (-not $search.Ok) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'wuScanFailed' -Arguments @($search.Error)
    if ($search.TimedOut) { return 'timedout' }
    return 'warn'
  }
  $code = 0
  $count = 0
  $null = [int]::TryParse([string]$search.Data['ResultCode'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$code)
  $null = [int]::TryParse([string]$search.Data['Count'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$count)
  $Run.Data['WuScan'] = @{ ResultCode = $code; Count = $count }
  if ($code -ne 2 -and $code -ne 3) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'wuScanFailed' -Arguments @('result code {0}' -f $code)
    return 'warn'
  }
  Add-ToolLog -Run $Run -Text ('Windows Update: {0} updates available' -f $count)
  if ($count -gt 0) { Add-ToolFinding -Run $Run -Level INFO -Code 'updatesAvailable' -Arguments @($count) }
  return 'done'
}
