# src/Repair/ToolChecks.ps1
# Repair & diagnostics: the language-independent checks and the read-only Health check (repair spec 6.1).
#
# Customer PCs run Hebrew Windows, so no verdict here comes from a tool's text (Review Focus 4). The sources are:
#   - enums and CIM codes of Windows' own cmdlets: Get-Volume's HealthStatus and OperationalStatus codes (the Health
#     check's disk state), Repair-Volume -Scan's Volume.RepairStatus (Standard repair and Post-clone only: it can fix
#     errors online, ruling RD-R12), Repair-WindowsImage's ImageHealthState;
#   - CIM and WMI: Win32_Volume.DirtyBitSet, the BCD store ({current}'s recoveryenabled, recoverysequence and
#     safeboot), Win32_PnPEntity's ConfigManagerErrorCode, SoftwareLicensingProduct.LicenseStatus;
#   - ReAgent.xml, read by its InstallState attribute (supporting evidence only: the BCD decides, builder check 7);
#   - CBS.log's [SR] lines, which are always English, for sfc /verifyonly. sfc's own console text is redirected to
#     the log folder for the progress tick and never read for a decision.
# Every cmdlet that can hang runs in a bounded grandchild (Invoke-ToolJsonChild); its command is a here-string below
# ($script:Tool<Name>Command) that returns one hashtable. A grandchild that fails or times out gives 'Unknown', and
# its reason is kept in $Run.Data.CheckErrors.<name> for the finding's argument.
#
# The Health steps only read: no Repair-Volume, no repair switch, no device rescan (no pnputil /scan-devices, spec
# 6.1), no reagentc. An unknown result is yellow, never a generic red: a step that timed out adds its own WARN before
# it says so.
#
# Needs ToolEngine (Invoke-ToolJsonChild, Invoke-ToolNative, Add-ToolFinding, Add-ToolLog, Format-ToolExitCode),
# Activity (Read-FileTail, Wait-SetupDelay), Logging (Write-SetupLog), StartScreen (ConvertTo-ScreenText) and Report
# ($script:WindowsLicensingApplicationId). The bundle holds every file.

# Repair-Volume -Scan of the system drive (<L> is its letter): a Volume.RepairStatus name. It is NOT read-only: the
# online scan may fix what it finds (ScanErrorsFoundAndFixedOnline), so only Standard repair and Post-clone run it,
# never the Health check (ruling RD-R12).
$script:ToolVolumeScanCommand = @'
@{ Result = [string](Repair-Volume -DriveLetter '<L>' -Scan) }
'@

# The system volume's state for the read-only Health check (ruling RD-R12): Get-Volume's raw CIM codes (HealthStatus,
# OperationalStatus; the English names Get-Volume shows come from the Storage types file, the codes from MSFT_Volume)
# and Win32_Volume.DirtyBitSet ($null when it cannot be read). Nothing is scanned or changed.
$script:ToolVolumeStateCommand = @'
$volume = Get-Volume -DriveLetter '<L>'
$raw = $volume.psBase.CimInstanceProperties
$dirty = $null
try {
  $cim = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='<L>:'"
  if ($null -ne $cim -and $cim.DirtyBitSet -is [bool]) { $dirty = $cim.DirtyBitSet }
} catch { $dirty = $null }
@{ HealthStatus = $raw['HealthStatus'].Value; OperationalStatus = @(foreach ($code in @($raw['OperationalStatus'].Value)) { [int]$code }); Dirty = $dirty }
'@

# Volume.RepairStatus (Storage\Volume.cdxml) -> the Standard repair verdict (ruling RD-R12). A name that is not
# here is Unknown (yellow). tests\ToolChecks.Tests.ps1 checks every name against the installed Volume.cdxml.
$script:ToolRepairStatusMap = @{
  NoErrorsFound                 = 'Clean'
  ScanNoErrorsFound             = 'Clean'
  ScanErrorsFoundAndFixedOnline = 'FixedOnline'
  ScanErrorsFoundNeedSpotFix    = 'SpotFixNeeded'
  NeedOfflineScanAndFix         = 'FullRepairNeeded'
}

# Volume.HealthStatus and the three repair codes of Volume.OperationalStatus (Storage\Volume.cdxml; the test checks
# them against the installed file). Plain hashtables: an [int] index into an ordered dictionary is a position.
# ToolVolumeRepairOrder is the most serious first.
$script:ToolVolumeHealthCodes = @{ 0 = 'Healthy'; 1 = 'Warning'; 2 = 'Unhealthy' }
$script:ToolVolumeRepairCodes = @{ 53263 = 'FullRepairNeeded'; 53262 = 'SpotFixNeeded'; 53261 = 'ScanNeeded' }
$script:ToolVolumeRepairOrder = @(53263, 53262, 53261)

# Repair-WindowsImage -Online -CheckHealth or -ScanHealth (<Mode>): the ImageHealthState enum (Healthy, Repairable,
# NonRepairable). Neither switch changes the image.
$script:ToolImageHealthCommand = @'
@{ State = [string](Repair-WindowsImage -Online -<Mode>).ImageHealthState }
'@

# The boot configuration through the WMI BcdStore (language-independent, unlike bcdedit's text): the system store
# (OpenStore with an empty file name), the {current} loader by its well-known id, and three elements read with
# GetElement: 0x16000009 recoveryenabled (BcdBooleanElement), 0x14000008 recoverysequence (BcdObjectListElement)
# and 0x25000080 safeboot (BcdIntegerElement). A missing element (GetElement answers false) is $null; a GetElement
# that throws is named in Errors, so an unreadable element is never taken for a missing one. Nothing is written.
$script:ToolBcdCommand = @'
$store = ([wmiclass]'\\.\root\wmi:BcdStore').OpenStore('').Store
if ($null -eq $store) { throw 'The BCD store could not be opened' }
$current = $store.OpenObject('{fa926493-6f1c-4193-a414-58f0b2456d1e}').Object
if ($null -eq $current) { throw 'The current boot entry could not be opened' }
$errors = New-Object System.Collections.Generic.List[string]
$read = { param($type, $name) try { $answer = $current.GetElement($type); if ($answer.ReturnValue) { $answer.Element } } catch { $errors.Add($name + ': ' + $_.Exception.Message) } }
$enabled = & $read 0x16000009 'recoveryenabled'
$sequence = & $read 0x14000008 'recoverysequence'
$safeBoot = & $read 0x25000080 'safeboot'
@{
  RecoveryEnabled  = $(if ($null -ne $enabled) { [bool]$enabled.Boolean } else { $null })
  RecoverySequence = @(if ($null -ne $sequence) { foreach ($id in @($sequence.Ids)) { [string]$id } })
  SafeBoot         = $(if ($null -ne $safeBoot) { [long]$safeBoot.Integer } else { $null })
  Errors           = $errors.ToArray()
}
'@

# The present devices whose status is not OK, with Win32_PnPEntity's ConfigManagerErrorCode (Get-PnpDevice returns
# Win32_PnPEntity objects). Status and the code are CIM values, never localized; the name is for display only.
$script:ToolProblemDevicesCommand = @'
@{ Items = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' } | ForEach-Object {
  @{ InstanceId = [string]$_.InstanceId; Class = [string]$_.Class; Name = [string]$_.FriendlyName; Status = [string]$_.Status
     ConfigManagerErrorCode = [int]$_.ConfigManagerErrorCode } }) }
'@

# Get-ActivationStatus's query (Report.ps1): the LicenseStatus of Windows' own SoftwareLicensingProduct rows that
# hold a product key (<AppId> is the Windows licensing application id). It can take tens of seconds, hence the
# grandchild.
$script:ToolActivationCommand = @'
@{ Statuses = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='<AppId>' AND PartialProductKey IS NOT NULL" | ForEach-Object { [int]$_.LicenseStatus }) }
'@

# --- Why a check gave no result -------------------------------------------------------------------------------

function Set-ToolCheckError {
  # Private. Keeps why check -Name gave no result in $Run.Data.CheckErrors (ASCII; 'no result' when empty): the
  # argument of its finding, and in result.json for the technician.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$Name,
    [AllowNull()][AllowEmptyString()][string]$Reason
  )

  if ($Run.Data['CheckErrors'] -isnot [System.Collections.IDictionary]) { $Run.Data['CheckErrors'] = @{} }
  $text = ConvertTo-ScreenText -Text $Reason
  if ($text -eq '') { $text = 'no result' }
  $Run.Data['CheckErrors'][$Name] = $text
}

function Get-ToolCheckError {
  # Private. Why check -Name gave no result ('timed out', the grandchild's message, ...), or 'no result'.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$Name
  )

  $errors = $Run.Data['CheckErrors']
  if ($errors -is [System.Collections.IDictionary] -and $errors.Contains($Name)) { return [string]$errors[$Name] }
  return 'no result'
}

function Test-ToolCheckTimedOut {
  # Private. $true when check -Name gave no result because its grandchild timed out.
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$Name
  )

  return ((Get-ToolCheckError -Run $Run -Name $Name) -ceq 'timed out')
}

# --- The checks ---------------------------------------------------------------------------------------------------

function Get-ToolSystemLetter {
  # Private. The system drive's letter (upper case), or '' when $env:SystemDrive is not '<letter>:'.
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $letter = ([string]$env:SystemDrive).TrimEnd(':')
  if ($letter -notmatch '^[A-Za-z]\z') { return '' }
  return $letter.ToUpperInvariant()
}

function ConvertFrom-ToolRepairStatus {
  <#
  .SYNOPSIS
    Repair-Volume -Scan's Volume.RepairStatus name -> 'Clean', 'FixedOnline', 'SpotFixNeeded', 'FullRepairNeeded', or
    'Unknown' for any other name (ruling RD-R12, $script:ToolRepairStatusMap). Pure.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Status)

  foreach ($name in $script:ToolRepairStatusMap.Keys) {
    if ($Status -ceq $name) { return [string]$script:ToolRepairStatusMap[$name] }
  }
  return 'Unknown'
}

function Get-ToolVolumeScan {
  <#
  .SYNOPSIS
    Repair-Volume -Scan of the system drive, in the grandchild 'volumeScan' bounded by toolStep.volumeScan: the
    Volume.RepairStatus name it returned, or 'Unknown' (the reason in $Run.Data.CheckErrors.volumeScan). Never throws.
  .DESCRIPTION
    Standard repair and Post-clone only: the online scan may fix errors (ruling RD-R12). ConvertFrom-ToolRepairStatus
    turns the name into the verdict.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $letter = Get-ToolSystemLetter
  if ($letter -eq '') {
    Set-ToolCheckError -Run $Run -Name 'volumeScan' -Reason 'no system drive letter'
    return 'Unknown'
  }
  $child = Invoke-ToolJsonChild -Run $Run -Name 'volumeScan' -Command ($script:ToolVolumeScanCommand.Replace('<L>', $letter)) -StepTimeout 'volumeScan'
  if (-not $child.Ok) {
    Set-ToolCheckError -Run $Run -Name 'volumeScan' -Reason $child.Error
    return 'Unknown'
  }
  $value = ConvertTo-ScreenText -Text $child.Data['Result']
  if ($value -eq '') {
    Set-ToolCheckError -Run $Run -Name 'volumeScan' -Reason 'no result'
    return 'Unknown'
  }
  return $value
}

function ConvertFrom-ToolVolumeState {
  <#
  .SYNOPSIS
    The system volume's state from Get-Volume's raw codes (ruling RD-R12): 'FullRepairNeeded', 'SpotFixNeeded',
    'ScanNeeded', 'Healthy' or 'Unknown'. Pure.
  .DESCRIPTION
    An OperationalStatus repair code decides first, the most serious one: 53263 Full Repair Needed, 53262 Spot Fix
    Needed, 53261 Scan Needed. Without one, HealthStatus decides: 0 Healthy; 1 Warning is read as ScanNeeded and
    2 Unhealthy as FullRepairNeeded; anything else (missing, unreadable) is Unknown.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()]$HealthStatus,
    [AllowNull()][object[]]$OperationalStatus
  )

  $codes = @(foreach ($value in @($OperationalStatus)) {
      $number = 0
      if ($null -ne $value -and [int]::TryParse([string]$value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { $number }
    })
  foreach ($code in $script:ToolVolumeRepairOrder) {
    if ($codes -contains $code) { return [string]$script:ToolVolumeRepairCodes[$code] }
  }
  $health = -1
  if ($null -eq $HealthStatus -or -not [int]::TryParse([string]$HealthStatus, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$health)) {
    return 'Unknown'
  }
  switch ($health) {
    0 { return 'Healthy' }
    1 { return 'ScanNeeded' }
    2 { return 'FullRepairNeeded' }
  }
  return 'Unknown'
}

function Get-ToolVolumeState {
  <#
  .SYNOPSIS
    The system volume's state for the read-only Health check, in the grandchild 'volumeState' (Get-Volume and
    Win32_Volume.DirtyBitSet): @{ Verdict (ConvertFrom-ToolVolumeState); Health; Operational = [string[]] (the code
    names); Dirty = <bool|$null> }. A failed read is Verdict 'Unknown' (the reason in $Run.Data.CheckErrors.volumeState).
    Never throws.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $unknown = @{ Verdict = 'Unknown'; Health = ''; Operational = [string[]]@(); Dirty = $null }
  $letter = Get-ToolSystemLetter
  if ($letter -eq '') {
    Set-ToolCheckError -Run $Run -Name 'volumeState' -Reason 'no system drive letter'
    return $unknown
  }
  $child = Invoke-ToolJsonChild -Run $Run -Name 'volumeState' -Command ($script:ToolVolumeStateCommand.Replace('<L>', $letter))
  if (-not $child.Ok) {
    Set-ToolCheckError -Run $Run -Name 'volumeState' -Reason $child.Error
    return $unknown
  }
  $data = $child.Data
  $operational = @(foreach ($code in @($data['OperationalStatus'])) { if ($null -ne $code) { $code } })
  $verdict = ConvertFrom-ToolVolumeState -HealthStatus $data['HealthStatus'] -OperationalStatus $operational
  if ($verdict -eq 'Unknown') { Set-ToolCheckError -Run $Run -Name 'volumeState' -Reason 'no volume health' }
  $health = ''
  $healthCode = -1
  if ([int]::TryParse([string]$data['HealthStatus'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$healthCode) -and
      $script:ToolVolumeHealthCodes.ContainsKey($healthCode)) {
    $health = [string]$script:ToolVolumeHealthCodes[$healthCode]
  }
  $names = [string[]]@(foreach ($code in $operational) {
      $number = 0
      if ([int]::TryParse([string]$code, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
          $script:ToolVolumeRepairCodes.ContainsKey($number)) {
        [string]$script:ToolVolumeRepairCodes[$number]
      } else {
        ConvertTo-ScreenText -Text $code
      }
    })
  $dirty = $null
  if ($data['Dirty'] -is [bool]) { $dirty = [bool]$data['Dirty'] }
  return @{ Verdict = $verdict; Health = $health; Operational = $names; Dirty = $dirty }
}

function Get-ToolImageHealth {
  <#
  .SYNOPSIS
    Repair-WindowsImage -Online -CheckHealth or -ScanHealth (-Mode), in the grandchild 'imageCheck' or 'imageScan'
    bounded by toolStep.imageCheck / toolStep.imageScan: 'Healthy', 'Repairable', 'NonRepairable', or 'Unknown'
    (the reason in $Run.Data.CheckErrors.<that name>). Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][ValidateSet('CheckHealth', 'ScanHealth')][string]$Mode
  )

  $name = if ($Mode -ceq 'CheckHealth') { 'imageCheck' } else { 'imageScan' }
  $child = Invoke-ToolJsonChild -Run $Run -Name $name -Command ($script:ToolImageHealthCommand.Replace('<Mode>', $Mode)) -StepTimeout $name
  if (-not $child.Ok) {
    Set-ToolCheckError -Run $Run -Name $name -Reason $child.Error
    return 'Unknown'
  }
  $value = [string]$child.Data['State']
  foreach ($known in 'Healthy', 'Repairable', 'NonRepairable') {
    if ($value -eq $known) { return $known }
  }
  Set-ToolCheckError -Run $Run -Name $name -Reason ('unexpected state ' + $value)
  return 'Unknown'
}

function ConvertFrom-CbsSrText {
  <#
  .SYNOPSIS
    What SFC wrote to CBS.log since -Since: @{ Ran; VerifyStarted; VerifyCompleted; VerifyComplete; SrLines; Repaired;
    CannotRepair; Corrupt; Lines }. Pure.
  .DESCRIPTION
    Only lines that hold [SR] and whose first 19 characters parse as 'yyyy-MM-dd HH:mm:ss' (invariant culture, so a
    Hebrew calendar on the thread changes nothing) at or after -Since minus 5 seconds count; Windows' own verify
    blocks of earlier days are left out. CBS.log is always English.
      Ran             : at least one such line.
      VerifyStarted   : the '[SR] Verifying N components' lines (SFC verifies in batches).
      VerifyCompleted : the '[SR] Verify complete' lines.
      VerifyComplete  : at least one batch completed, and every batch that started has completed (review M1: SFC
                        writes one 'Verify complete' per batch, so one alone does not mean the scan is over).
      SrLines         : the [SR] lines counted, for Read-ToolSfcResult's "unchanged between two reads".
      Repaired       : the sum of N >= 1 in '[SR] Repairing N components' (a clean '0 components' is never a repair,
                       review I-3).
      CannotRepair   : the '[SR] Cannot repair member file' lines.
      Corrupt        : the [SR] lines that match 'Hashes for file member', 'is corrupt', 'Could not reproject' or
                       'Cannot repair member file'.
      Lines          : up to 40 of the counted lines, trimmed (English; ConvertTo-ScreenText before any log).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory)][datetime]$Since
  )

  $result = @{ Ran = $false; VerifyStarted = 0; VerifyCompleted = 0; VerifyComplete = $false; SrLines = 0; Repaired = 0; CannotRepair = 0; Corrupt = 0; Lines = [string[]]@() }
  if ([string]::IsNullOrEmpty($Text)) { return $result }
  $from = $Since.AddSeconds(-5)
  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $kept = New-Object System.Collections.Generic.List[string]
  foreach ($line in [regex]::Split($Text, '\r?\n')) {
    if ($line.Length -lt 19 -or $line.IndexOf('[SR]', [StringComparison]::Ordinal) -lt 0) { continue }
    $stamp = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($line.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $invariant, [Globalization.DateTimeStyles]::None, [ref]$stamp)) { continue }
    if ($stamp -lt $from) { continue }
    $result.Ran = $true
    $result.SrLines++
    $counted = $false
    if ($line.IndexOf('[SR] Verify complete', [StringComparison]::Ordinal) -ge 0) { $result.VerifyCompleted++ }
    if ([regex]::IsMatch($line, '\[SR\] Verifying [0-9]+ components')) { $result.VerifyStarted++ }
    $repairing = [regex]::Match($line, '\[SR\] Repairing ([0-9]{1,9}) components')
    if ($repairing.Success) {
      $n = [int]::Parse($repairing.Groups[1].Value, $invariant)
      if ($n -ge 1) {
        $result.Repaired += $n
        $counted = $true
      }
    }
    if ($line.IndexOf('[SR] Cannot repair member file', [StringComparison]::Ordinal) -ge 0) { $result.CannotRepair++ }
    if ([regex]::IsMatch($line, 'Hashes for file member|is corrupt|Could not reproject|Cannot repair member file')) {
      $result.Corrupt++
      $counted = $true
    }
    if ($counted -and $kept.Count -lt 40) { $kept.Add($line.Trim()) }
  }
  $result.Lines = $kept.ToArray()
  $result.VerifyComplete = ($result.VerifyCompleted -gt 0 -and $result.VerifyCompleted -ge $result.VerifyStarted)
  return $result
}

function Read-ToolCbsLog {
  <#
  .SYNOPSIS
    The CBS log text SFC may have written to since -Since: every CbsPersist_*.log in -Folder written at or after
    -Since (oldest first), then the end of CBS.log, at most the last 16 MB of each. '' when nothing can be read.
    Never throws.
  .DESCRIPTION
    Plan call: CBS.log can rotate into a CbsPersist_<stamp>.log during a long scan, so the start of SFC's lines may
    be in the rotated file. Read-FileTail opens each file shared, so TrustedInstaller can go on writing.
    Windows later compresses a rotated log into CbsPersist_<stamp>.cab, which is not read (review M2: a rotation
    compressed during the scan loses SFC's first lines); one written since -Since is logged as a WARN.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][datetime]$Since,
    [string]$Folder = (Join-Path $env:windir 'Logs\CBS')
  )

  try {
    if (-not [IO.Directory]::Exists($Folder)) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    $rotated = @(foreach ($path in [IO.Directory]::GetFiles($Folder, 'CbsPersist_*.log')) {
        $written = [IO.File]::GetLastWriteTime($path)
        if ($written -ge $Since) { [pscustomobject]@{ Path = $path; Written = $written } }
      })
    foreach ($file in @($rotated | Sort-Object -Property Written)) {
      $text = Read-FileTail -Path $file.Path -MaxBytes 16MB
      if (-not [string]::IsNullOrEmpty($text)) { $parts.Add($text) }
    }
    foreach ($cab in [IO.Directory]::GetFiles($Folder, 'CbsPersist_*.cab')) {
      if ([IO.File]::GetLastWriteTime($cab) -ge $Since) {
        Write-SetupLog -Level WARN -Message 'A CBS log rotated during the scan is compressed and not read: the first SFC lines may be missing' -Data @{
          file = (ConvertTo-ScreenText -Text ([IO.Path]::GetFileName($cab))) }
      }
    }
    $current = Read-FileTail -Path ([IO.Path]::Combine($Folder, 'CBS.log')) -MaxBytes 16MB
    if (-not [string]::IsNullOrEmpty($current)) { $parts.Add($current) }
    return ($parts.ToArray() -join "`r`n")
  } catch {
    Write-SetupLog -Level WARN -Message 'CBS.log could not be read' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    return ''
  }
}

function Read-ToolSfcResult {
  <#
  .SYNOPSIS
    SFC's result from CBS.log (ConvertFrom-CbsSrText of Read-ToolCbsLog -Since). Never throws.
  .DESCRIPTION
    Review I-3 and M1: CBS.log is written late, so the log is read again every 2 seconds (Wait-SetupDelay, which
    keeps the progress tick alive) until every verify batch that started has completed (VerifyComplete) AND the [SR]
    lines are unchanged since the previous read, for at most 30 seconds (15 waits). A clean, already flushed log
    therefore takes two reads. The last reading is returned either way, with Settled = $true when both held. The
    wait counts its slices, never the wall clock.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][datetime]$Since
  )

  $result = $null
  $previous = $null
  $settled = $false
  for ($attempt = 0; $attempt -le 15; $attempt++) {
    if ($attempt -eq 1) { Add-ToolLog -Run $Run -Text 'Waiting for CBS.log' }
    if ($attempt -gt 0) { Wait-SetupDelay -Seconds 2 }
    $result = ConvertFrom-CbsSrText -Text (Read-ToolCbsLog -Since $Since) -Since $Since
    if ($result.VerifyComplete -and $null -ne $previous -and $previous.SrLines -eq $result.SrLines) {
      $settled = $true
      break
    }
    $previous = $result
  }
  $result['Settled'] = $settled
  if (-not $settled) {
    Write-SetupLog -Level WARN -Message 'CBS.log shows no completed and settled SFC verify' -Data @{
      ran = $result.Ran; started = $result.VerifyStarted; completed = $result.VerifyCompleted; corrupt = $result.Corrupt }
  }
  return $result
}

function Get-ToolReAgentState {
  <#
  .SYNOPSIS
    WinRE as ReAgent.xml records it: 'On' (<WindowsRE><InstallState state="1"/>), 'Off' (state "0"), 'Missing' (no
    file), or 'Unknown' (unreadable, not XML, no such element, any other state). Never throws.
  .DESCRIPTION
    Read as XML, by the attribute: never as text. A DTD is refused and no external entity is resolved. Supporting
    evidence only: it is often stale after a clone, and the BCD decides (Resolve-WinReVerdict).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([string]$Path = (Join-Path $env:windir 'System32\Recovery\ReAgent.xml'))

  $reader = $null
  try {
    if (-not [IO.File]::Exists($Path)) { return 'Missing' }
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver = $null
    $document.Load($reader)
    $node = $document.SelectSingleNode('/WindowsRE/InstallState')
    if ($node -isnot [Xml.XmlElement]) { return 'Unknown' }
    $state = $node.GetAttribute('state')
    if ($state -ceq '1') { return 'On' }
    if ($state -ceq '0') { return 'Off' }
    return 'Unknown'
  } catch {
    Write-SetupLog -Level WARN -Message 'ReAgent.xml could not be read' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    return 'Unknown'
  } finally {
    if ($null -ne $reader) { $reader.Dispose() }
  }
}

function Get-ToolBcdState {
  <#
  .SYNOPSIS
    Recovery in the boot configuration of the {current} loader, read in the grandchild 'bcd' through the WMI
    BcdStore: @{ Recovery = 'On'|'Off'|'Unknown'; SafeBoot = <long|$null> }. Never throws.
  .DESCRIPTION
    On: a recoverysequence id, and recoveryenabled true or absent (Plan call: absent counts as on, as on a fresh
    install; docs/testing.md checks it). Off: no recoverysequence, or recoveryenabled false. Unknown (the BCD could
    not be read; the reason in $Run.Data.CheckErrors.bcd): the grandchild failed, answered without the recovery
    sequence, or could not read recoveryenabled or recoverysequence (GetElement threw: review M4, an unreadable
    element is never taken for a missing one). SafeBoot is the safeboot element (0 minimal, 1 network, 2 DsRepair),
    $null when it is not set or could not be read.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $child = Invoke-ToolJsonChild -Run $Run -Name 'bcd' -Command $script:ToolBcdCommand
  if (-not $child.Ok) {
    Set-ToolCheckError -Run $Run -Name 'bcd' -Reason $child.Error
    return @{ Recovery = 'Unknown'; SafeBoot = $null }
  }
  $data = $child.Data
  $safeBoot = $null
  $number = [long]0
  if ($null -ne $data['SafeBoot'] -and [long]::TryParse([string]$data['SafeBoot'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
    $safeBoot = $number
  }
  if (-not $data.ContainsKey('RecoverySequence')) {
    Set-ToolCheckError -Run $Run -Name 'bcd' -Reason 'no recovery sequence in the answer'
    return @{ Recovery = 'Unknown'; SafeBoot = $safeBoot }
  }
  $unreadable = @(foreach ($e in @($data['Errors'])) {
      $text = [string]$e
      if ($text.StartsWith('recoveryenabled:', [StringComparison]::Ordinal) -or $text.StartsWith('recoverysequence:', [StringComparison]::Ordinal)) { $text }
    })
  if ($unreadable.Count -gt 0) {
    Set-ToolCheckError -Run $Run -Name 'bcd' -Reason ($unreadable -join '; ')
    return @{ Recovery = 'Unknown'; SafeBoot = $safeBoot }
  }
  $ids = @(foreach ($id in @($data['RecoverySequence'])) { if (-not [string]::IsNullOrWhiteSpace([string]$id)) { [string]$id } })
  $enabled = $data['RecoveryEnabled']
  $recovery = 'On'
  if ($ids.Count -eq 0 -or ($enabled -is [bool] -and -not $enabled)) { $recovery = 'Off' }
  return @{ Recovery = $recovery; SafeBoot = $safeBoot }
}

function Resolve-WinReVerdict {
  <#
  .SYNOPSIS
    WinRE's verdict from the BCD and ReAgent.xml (spec 6.1, builder check 7): @{ Verdict = 'On'|'Off'|'Unknown';
    CanEnable = <bool> }. Pure.
  .DESCRIPTION
    The BCD decides; ReAgent.xml only supports it (it is often stale after a clone):
      BCD On  + ReAgent On, Missing or Unknown -> On
      BCD On  + ReAgent Off                    -> Unknown (they disagree)
      BCD Off + ReAgent Off                    -> Off, and CanEnable: the one case Standard repair may run
                                                  reagentc /enable
      BCD Off + ReAgent On                     -> Unknown (they disagree)
      BCD Off + ReAgent Missing or Unknown     -> Off, not CanEnable (Plan call: winreNoAgreement in Task 6)
      BCD Unknown (or anything else)           -> Unknown
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Bcd,
    [AllowNull()][AllowEmptyString()][string]$ReAgent
  )

  if ($Bcd -ceq 'On') {
    if ($ReAgent -ceq 'Off') { return @{ Verdict = 'Unknown'; CanEnable = $false } }
    return @{ Verdict = 'On'; CanEnable = $false }
  }
  if ($Bcd -ceq 'Off') {
    if ($ReAgent -ceq 'Off') { return @{ Verdict = 'Off'; CanEnable = $true } }
    if ($ReAgent -ceq 'On') { return @{ Verdict = 'Unknown'; CanEnable = $false } }
    return @{ Verdict = 'Off'; CanEnable = $false }
  }
  return @{ Verdict = 'Unknown'; CanEnable = $false }
}

function Get-ToolProblemDevices {
  <#
  .SYNOPSIS
    The present devices whose status is not OK, read in the grandchild 'devices': an array of
    @{ InstanceId; Class; Name; Status; ConfigManagerErrorCode } (empty when none), or $null when the list could not
    be read (the reason in $Run.Data.CheckErrors.devices). Never throws.
  .DESCRIPTION
    Read-only: no pnputil /scan-devices here (spec 6.1; unlike the old kit, the Health check rescans nothing).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Run)

  $child = Invoke-ToolJsonChild -Run $Run -Name 'devices' -Command $script:ToolProblemDevicesCommand
  if (-not $child.Ok) {
    Set-ToolCheckError -Run $Run -Name 'devices' -Reason $child.Error
    return $null
  }
  if (-not $child.Data.ContainsKey('Items')) {
    Set-ToolCheckError -Run $Run -Name 'devices' -Reason 'no device list in the answer'
    return $null
  }
  $items = @(foreach ($item in @($child.Data['Items'])) { if ($item -is [System.Collections.IDictionary]) { $item } })
  return , $items
}

function Get-ToolActivation {
  <#
  .SYNOPSIS
    Windows activation, read in the grandchild 'activation' with Get-ActivationStatus's query: 'Activated' (a
    LicenseStatus of 1 on a Windows row with a product key), 'Not activated' (none, or no such row), or 'Unknown'
    (the query failed; the reason in $Run.Data.CheckErrors.activation). Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $applicationId = [string]$script:WindowsLicensingApplicationId
  if ($applicationId -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z') {
    Set-ToolCheckError -Run $Run -Name 'activation' -Reason 'no Windows licensing application id'
    return 'Unknown'
  }
  $child = Invoke-ToolJsonChild -Run $Run -Name 'activation' -Command ($script:ToolActivationCommand.Replace('<AppId>', $applicationId))
  if (-not $child.Ok) {
    Set-ToolCheckError -Run $Run -Name 'activation' -Reason $child.Error
    return 'Unknown'
  }
  if (-not $child.Data.ContainsKey('Statuses')) {
    Set-ToolCheckError -Run $Run -Name 'activation' -Reason 'no license status in the answer'
    return 'Unknown'
  }
  foreach ($status in @($child.Data['Statuses'])) {
    $value = 0
    if ([int]::TryParse([string]$status, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and $value -eq 1) {
      return 'Activated'
    }
  }
  return 'Not activated'
}

# --- The Health check's steps (spec 6.1) ------------------------------------------------------------------------

function Invoke-ToolStepVolumeState {
  <#
  .SYNOPSIS
    Step volumeState (Health check, read-only; ruling RD-R12): the system volume's state from Get-Volume and its dirty
    bit (Get-ToolVolumeState). $Run.Data.VolumeState = @{ Verdict; Health; Operational; Dirty }. Nothing is scanned.
  .DESCRIPTION
    Healthy: done. SpotFixNeeded: CRIT volumeSpotFix. FullRepairNeeded: CRIT volumeFullRepair. Both offer "Disk check
    at restart" ($Run.Offers.DiskCheck; spec 6.2, ruling RD-R10). ScanNeeded: WARN volumeScanNeeded. Unknown: WARN
    volumeUnknown with the reason ('timedout' when the read timed out). A volume marked dirty adds WARN volumeDirty
    (Windows checks it at the next start).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $state = Get-ToolVolumeState -Run $Run
  $Run.Data['VolumeState'] = $state
  $dirtyText = if ($null -eq $state.Dirty) { 'unknown' } else { [string]$state.Dirty }
  Add-ToolLog -Run $Run -Text ('Disk state: {0} (health {1}, dirty {2})' -f $state.Verdict, $state.Health, $dirtyText)
  $status = 'done'
  switch -CaseSensitive ($state.Verdict) {
    'Healthy' { }
    'SpotFixNeeded' {
      Add-ToolFinding -Run $Run -Level CRIT -Code 'volumeSpotFix'
      $Run.Offers['DiskCheck'] = $true
      $status = 'warn'
    }
    'FullRepairNeeded' {
      Add-ToolFinding -Run $Run -Level CRIT -Code 'volumeFullRepair'
      $Run.Offers['DiskCheck'] = $true
      $status = 'warn'
    }
    'ScanNeeded' {
      Add-ToolFinding -Run $Run -Level WARN -Code 'volumeScanNeeded'
      $status = 'warn'
    }
    default {
      Add-ToolFinding -Run $Run -Level WARN -Code 'volumeUnknown' -Arguments @(Get-ToolCheckError -Run $Run -Name 'volumeState')
      $status = 'warn'
      if (Test-ToolCheckTimedOut -Run $Run -Name 'volumeState') { $status = 'timedout' }
    }
  }
  if ($state.Dirty -eq $true) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'volumeDirty'
    if ($status -eq 'done') { $status = 'warn' }
  }
  return $status
}

function Invoke-ToolStepVolumeScan {
  <#
  .SYNOPSIS
    Step volumeScan (Standard repair and Post-clone, wired by Task 6; never the Health check): Repair-Volume -Scan of
    the system drive, which may fix errors online (ruling RD-R12). $Run.Data.VolumeScan = @{ Status (the
    Volume.RepairStatus name, or 'Unknown'); Verdict (ConvertFrom-ToolRepairStatus) }.
  .DESCRIPTION
    Clean (NoErrorsFound, ScanNoErrorsFound): done. FixedOnline (ScanErrorsFoundAndFixedOnline): INFO
    volumeFixedOnline. SpotFixNeeded (ScanErrorsFoundNeedSpotFix): CRIT volumeSpotFix. FullRepairNeeded
    (NeedOfflineScanAndFix): CRIT volumeFullRepair. Both CRITs offer "Disk check at restart" ($Run.Offers.DiskCheck).
    Any other status, or no result: WARN volumeUnknown with the status or the reason ('timedout' when the scan timed
    out).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $status = Get-ToolVolumeScan -Run $Run
  $verdict = ConvertFrom-ToolRepairStatus -Status $status
  $Run.Data['VolumeScan'] = @{ Status = $status; Verdict = $verdict }
  Add-ToolLog -Run $Run -Text ('Disk scan: {0}' -f $status)
  switch -CaseSensitive ($verdict) {
    'Clean' { return 'done' }
    'FixedOnline' {
      Add-ToolFinding -Run $Run -Level INFO -Code 'volumeFixedOnline'
      return 'done'
    }
    'SpotFixNeeded' {
      Add-ToolFinding -Run $Run -Level CRIT -Code 'volumeSpotFix'
      $Run.Offers['DiskCheck'] = $true
      return 'warn'
    }
    'FullRepairNeeded' {
      Add-ToolFinding -Run $Run -Level CRIT -Code 'volumeFullRepair'
      $Run.Offers['DiskCheck'] = $true
      return 'warn'
    }
  }
  $reason = $status
  if ($status -ceq 'Unknown') { $reason = Get-ToolCheckError -Run $Run -Name 'volumeScan' }
  Add-ToolFinding -Run $Run -Level WARN -Code 'volumeUnknown' -Arguments @($reason)
  if ($status -ceq 'Unknown' -and (Test-ToolCheckTimedOut -Run $Run -Name 'volumeScan')) { return 'timedout' }
  return 'warn'
}

function Invoke-ToolStepImageCheck {
  <#
  .SYNOPSIS
    Step imageCheck: Repair-WindowsImage -Online -CheckHealth (the quick look at the image's flags). It only logs and
    keeps the state in $Run.Data.ImageCheck for the scan that follows, which reports (and falls back on it when it
    gives no result). Always done: a yellow step without a finding would tell the technician nothing (review M5).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $state = Get-ToolImageHealth -Run $Run -Mode 'CheckHealth'
  $Run.Data['ImageCheck'] = $state
  if ($state -ceq 'Unknown') {
    Add-ToolLog -Run $Run -Text ('Windows image quick check: Unknown ({0})' -f (Get-ToolCheckError -Run $Run -Name 'imageCheck'))
  } else {
    Add-ToolLog -Run $Run -Text ('Windows image quick check: {0}' -f $state)
  }
  return 'done'
}

function Invoke-ToolStepImageScan {
  <#
  .SYNOPSIS
    Step imageScan: Repair-WindowsImage -Online -ScanHealth. $Run.Data.ImageHealth holds the state and
    $Run.Data.ImageHealthSource where it came from ('ScanHealth', or 'CheckHealth' for the fallback).
  .DESCRIPTION
    Healthy: done. Repairable: WARN imageRepairable (run Standard repair). NonRepairable: CRIT imageNonRepairable.
    When the scan gives no result but the quick check found the image Repairable or NonRepairable, that state is
    reported instead (review M5). Otherwise Unknown: WARN imageUnknown with the reason. 'timedout' when the scan
    timed out (the finding added keeps it from a generic red).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $state = Get-ToolImageHealth -Run $Run -Mode 'ScanHealth'
  $source = 'ScanHealth'
  $timedOut = ($state -ceq 'Unknown') -and (Test-ToolCheckTimedOut -Run $Run -Name 'imageScan')
  $checked = [string]$Run.Data['ImageCheck']
  if ($state -ceq 'Unknown' -and $checked -cin 'Repairable', 'NonRepairable') {
    $state = $checked
    $source = 'CheckHealth'
  }
  $Run.Data['ImageHealth'] = $state
  $Run.Data['ImageHealthSource'] = $source
  Add-ToolLog -Run $Run -Text ('Windows image scan: {0} (from {1})' -f $state, $source)
  $done = 'warn'
  if ($timedOut) { $done = 'timedout' }
  switch -CaseSensitive ($state) {
    'Healthy' { return 'done' }
    'Repairable' {
      Add-ToolFinding -Run $Run -Level WARN -Code 'imageRepairable'
      return $done
    }
    'NonRepairable' {
      Add-ToolFinding -Run $Run -Level CRIT -Code 'imageNonRepairable'
      return $done
    }
  }
  Add-ToolFinding -Run $Run -Level WARN -Code 'imageUnknown' -Arguments @(Get-ToolCheckError -Run $Run -Name 'imageScan')
  return $done
}

function Invoke-ToolStepSfcVerify {
  <#
  .SYNOPSIS
    Step sfcVerify: sfc.exe /verifyonly (it repairs nothing), judged from CBS.log's [SR] lines written after it
    started (Read-ToolSfcResult). $Run.Data.Sfc holds the counts.
  .DESCRIPTION
    sfc runs through Invoke-ToolNative with toolStep.sfc; its own (localized, UTF-16) output goes to
    <log folder>\sfc-<time>.txt for the tick and is never read here. Its exit code is kept for the log only.
      timed out                     : WARN sfcTimedOut (it may still run in the background), 'timedout'.
      integrity problems (Corrupt)  : WARN sfcCorrupt with the count.
      no completed verify since then: WARN sfcNotRun (restart, then run it again).
      else                          : done.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $since = Get-Date
  $sfc = [IO.Path]::Combine([string]$env:windir, 'System32\sfc.exe')
  $native = Invoke-ToolNative -Run $Run -FilePath $sfc -ArgumentList '/verifyonly' -StepTimeout 'sfc' -OutputName 'sfc'
  if ($native.TimedOut) {
    $Run.Data['Sfc'] = @{ TimedOut = $true }
    Add-ToolFinding -Run $Run -Level WARN -Code 'sfcTimedOut'
    return 'timedout'
  }
  $cbs = Read-ToolSfcResult -Run $Run -Since $since
  $Run.Data['Sfc'] = @{
    TimedOut       = $false
    ExitCode       = (Format-ToolExitCode -ExitCode $native.ExitCode)
    Ran            = [bool]$cbs.Ran
    VerifyComplete = [bool]$cbs.VerifyComplete
    Settled        = [bool]$cbs.Settled
    Corrupt        = [int]$cbs.Corrupt
    CannotRepair   = [int]$cbs.CannotRepair
    Repaired       = [int]$cbs.Repaired
  }
  foreach ($line in @($cbs.Lines)) { Write-SetupLog -Message ('CBS: ' + (ConvertTo-ScreenText -Text $line)) }
  Add-ToolLog -Run $Run -Text ('System files: {0} integrity problems in CBS.log' -f [int]$cbs.Corrupt)
  if ([int]$cbs.Corrupt -gt 0) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'sfcCorrupt' -Arguments @([int]$cbs.Corrupt)
    return 'warn'
  }
  if (-not $cbs.VerifyComplete) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'sfcNotRun'
    return 'warn'
  }
  return 'done'
}

function Invoke-ToolStepWinre {
  <#
  .SYNOPSIS
    Step winre (read-only): WinRE from the BCD (Get-ToolBcdState) with ReAgent.xml as support (Get-ToolReAgentState),
    Resolve-WinReVerdict. $Run.Data.WinRe = @{ Bcd; ReAgent; Verdict; CanEnable; SafeBoot }.
  .DESCRIPTION
    On: done. Off: WARN winreOff. The BCD could not be read: WARN winreUnreadable with the reason (ruling RD-R10).
    The BCD and ReAgent.xml disagree: WARN winreUnknown. Nothing is changed; reagentc never runs here.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $bcd = Get-ToolBcdState -Run $Run
  $agent = Get-ToolReAgentState
  $verdict = Resolve-WinReVerdict -Bcd $bcd.Recovery -ReAgent $agent
  $Run.Data['WinRe'] = @{ Bcd = $bcd.Recovery; ReAgent = $agent; Verdict = $verdict.Verdict; CanEnable = [bool]$verdict.CanEnable; SafeBoot = $bcd.SafeBoot }
  Add-ToolLog -Run $Run -Text ('WinRE: boot configuration {0}, ReAgent.xml {1}: {2}' -f $bcd.Recovery, $agent, $verdict.Verdict)
  if ($bcd.Recovery -ceq 'Unknown') {
    Add-ToolFinding -Run $Run -Level WARN -Code 'winreUnreadable' -Arguments @(Get-ToolCheckError -Run $Run -Name 'bcd')
    return 'warn'
  }
  switch -CaseSensitive ($verdict.Verdict) {
    'On' { return 'done' }
    'Off' {
      Add-ToolFinding -Run $Run -Level WARN -Code 'winreOff'
      return 'warn'
    }
  }
  Add-ToolFinding -Run $Run -Level WARN -Code 'winreUnknown'
  return 'warn'
}

function Invoke-ToolStepDevices {
  <#
  .SYNOPSIS
    Step devices (Health check; Post-clone reuses it): the present devices with a problem (Get-ToolProblemDevices).
    $Run.Data.Devices = @{ Problem; Disabled; Items (up to 50, ASCII) }.
  .DESCRIPTION
    A device that is disabled (ConfigManagerErrorCode 22) is INFO devicesDisabled, never a problem (review I-10).
    Any other code above 0 is a problem: WARN devicesProblem with the count and the codes. A device whose status is
    not OK with code 0 is listed, not counted. A list that could not be read is WARN devicesUnknown with the reason.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $items = Get-ToolProblemDevices -Run $Run
  if ($null -eq $items) {
    Add-ToolFinding -Run $Run -Level WARN -Code 'devicesUnknown' -Arguments @(Get-ToolCheckError -Run $Run -Name 'devices')
    if (Test-ToolCheckTimedOut -Run $Run -Name 'devices') { return 'timedout' }
    return 'warn'
  }
  $problemCodes = New-Object System.Collections.Generic.List[int]
  $disabled = 0
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($item in $items) {
    $code = 0
    $null = [int]::TryParse([string]$item['ConfigManagerErrorCode'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$code)
    if ($code -eq 22) { $disabled++ } elseif ($code -gt 0) { $problemCodes.Add($code) }
    if ($rows.Count -lt 50) {
      $rows.Add(@{
          InstanceId = (ConvertTo-ScreenText -Text $item['InstanceId']); Class = (ConvertTo-ScreenText -Text $item['Class'])
          Name = (ConvertTo-ScreenText -Text $item['Name']); Status = (ConvertTo-ScreenText -Text $item['Status']); Code = $code })
    }
  }
  $Run.Data['Devices'] = @{ Problem = $problemCodes.Count; Disabled = $disabled; Items = $rows.ToArray() }
  Add-ToolLog -Run $Run -Text ('Devices: {0} with a problem, {1} disabled' -f $problemCodes.Count, $disabled)
  if ($problemCodes.Count -gt 0) {
    $codes = (@($problemCodes.ToArray() | Sort-Object -Unique) -join ', ')
    Add-ToolFinding -Run $Run -Level WARN -Code 'devicesProblem' -Arguments @($problemCodes.Count, $codes)
  }
  if ($disabled -gt 0) { Add-ToolFinding -Run $Run -Level INFO -Code 'devicesDisabled' -Arguments @($disabled) }
  if ($problemCodes.Count -gt 0) { return 'warn' }
  return 'done'
}

function Invoke-ToolStepActivation {
  <#
  .SYNOPSIS
    Step activation (Health check; Post-clone reuses it): Get-ToolActivation. $Run.Data.Activation holds the state.
    Activated: done. Not activated: WARN notActivated. Unknown: INFO activationUnknown and 'warn' (an activation that
    cannot be read is no reason for red).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $state = Get-ToolActivation -Run $Run
  $Run.Data['Activation'] = $state
  Add-ToolLog -Run $Run -Text ('Activation: {0}' -f $state)
  if ($state -ceq 'Activated') { return 'done' }
  if ($state -ceq 'Not activated') {
    Add-ToolFinding -Run $Run -Level WARN -Code 'notActivated'
    return 'warn'
  }
  Add-ToolFinding -Run $Run -Level INFO -Code 'activationUnknown'
  return 'warn'
}
