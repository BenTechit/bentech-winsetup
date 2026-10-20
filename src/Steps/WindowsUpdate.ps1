# src/Steps/WindowsUpdate.ps1
# Step 13 (spec 8.3, 13): the bounded Windows Update loop over the native Windows Update Agent (WUA)
# COM API. Needs StepResult.ps1, Logging.ps1, Process.ps1 (Invoke-External) and State.ps1
# (Read-RunState, Save-RunState); the bundle holds every file.
#
# Two halves:
# - The parent step, Invoke-StepWindowsUpdate, runs in the runner. Each call is ONE round: it bumps
#   Data.Rounds (capped by caps.maxWuRounds), saves the state, starts the bundle again as a child with
#   -WuRound (timeout timeoutsMinutes.wuRound, the whole process tree is killed on timeout), reads the
#   child's result JSON, and books it into the state. It returns Continue (with Reboot 'Now' when
#   needed) until a round finds nothing to do, then Done.
# - The child round, Invoke-WuRound, does the COM work in that separate process: search, hide, accept
#   EULAs, download, install. It ALWAYS writes its result JSON; any exception becomes its Error.
#
# Why it cannot loop forever: the round cap; a per-update failure counter in state.json
# (WuFailureCounts) that hides an update after caps.wuFailuresBeforeHide failures; Defender
# definition updates do not count as "something left to do"; and the runner's own reboot cap.
#
# Update categories are matched by GUID only, never by name: names are localized (Hebrew Windows,
# Review Focus #1). No WUA text is parsed; only result codes, GUIDs and booleans are read.
#
# Every COM touchpoint is its own small function (New-WuSession, New-WuServiceManager,
# Register-MicrosoftUpdateService, Search-WuUpdates, Set-WuHidden, Invoke-WuDownload,
# Invoke-WuInstall, Get-WuRebootRequired), so the tests replace them and nothing real is touched.

$script:MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
$script:DefinitionUpdatesCategoryId = 'e0789628-ce08-4437-be74-2495b842f43b'
$script:UpgradesCategoryId = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'

$script:WuStepId = 'windows-update'

# Spec 9.2: the Note of a round that left firmware for later because the machine is on battery. The exact
# text of Vendor.ps1's $script:BatteryNote, so the verdict's exact-match de-duplication (M1) shows it once.
$script:WuBatteryNote = 'On battery: BIOS/firmware updates skipped'

# Ruling R23: WUA error codes the parent step retries instead of failing. Matched on the numeric code,
# never on the (localized) message text.
#   0x80240016 WU_E_INSTALL_NOT_ALLOWED (another installation is in progress)
#   0x8024A000 WU_E_AU_NOSERVICE (the Automatic Updates service is not available)
#   0x80242014 WU_E_UH_POSTREBOOTSTILLPENDING (earlier updates need a restart to finish)
$script:WuBusyErrorCodes = @('0x80240016', '0x8024A000')
$script:WuRebootPendingErrorCode = '0x80242014'

# --- pure helpers -----------------------------------------------------------------------------

function ConvertTo-WuList {
  # Private. Emits the non-null items of a list (an array, a single object or $null) one by one.
  # Callers wrap the call in @(), so $null and an empty list both become an empty array; @($null)
  # alone would be a one-element array.
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyCollection()]$Value)

  if ($null -eq $Value) { return }
  foreach ($item in @($Value)) {
    if ($null -ne $item) { $item }
  }
}

function Get-WuCollectionItems {
  # Private. The items of a COM collection (IUpdateCollection, ICategoryCollection,
  # IStringCollection, IUpdateServiceCollection), read with Count and Item(i). Works for plain arrays
  # too. $null gives nothing.
  [CmdletBinding()]
  param([AllowNull()]$Collection)

  if ($null -eq $Collection) { return }
  $count = [int]$Collection.Count
  for ($i = 0; $i -lt $count; $i++) { $Collection.Item($i) }
}

function Format-WuHResult {
  # Private. An HRESULT as '0x' + 8 upper-case hex digits. Accepts the negative Int32 that .NET reports
  # (0x80240016 is -2145124330) as well as a positive 64-bit value.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)]$HResult)

  return ('0x{0:X8}' -f ([int64]$HResult -band [int64]4294967295))
}

function Get-WuExceptionErrorCode {
  # Private. The HRESULT behind an exception, formatted by Format-WuHResult. A failing COM call can
  # reach PowerShell as a COMException or wrapped (MethodInvocationException, SetValueInvocationException,
  # TargetInvocationException), and a wrapper's own HResult is a generic 0x80131501. So the chain is
  # searched for the first COM (ExternalException) error; without one, the outer exception's HResult
  # is used.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][Exception]$Exception)

  for ($e = $Exception; $null -ne $e; $e = $e.InnerException) {
    if ($e -is [System.Runtime.InteropServices.ExternalException]) { return (Format-WuHResult -HResult $e.HResult) }
  }
  return (Format-WuHResult -HResult $Exception.HResult)
}

function Get-WuResultErrorCode {
  # Private. A round result's ErrorCode as a trimmed string, '' when there is none.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)]$Result)

  $code = [string]$Result.ErrorCode
  if ([string]::IsNullOrWhiteSpace($code)) { return '' }
  return $code.Trim()
}

function Test-WuResultError {
  # Private. $true when a round result carries an Error (a non-blank string).
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)]$Result)

  return (-not [string]::IsNullOrWhiteSpace([string]$Result.Error))
}

function Get-WuSearchCriteria {
  <#
  .SYNOPSIS
    The WUA search criteria for one update type: not installed, not hidden, not optional (BrowseOnly=0).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][ValidateSet('Software', 'Driver')][string]$Type)

  # ValidateSet ignores case; the criteria always get the canonical spelling.
  $canonical = if ($Type -eq 'Driver') { 'Driver' } else { 'Software' }
  return "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='$canonical'"
}

function ConvertTo-WuUpdateInfo {
  <#
  .SYNOPSIS
    Turns a WUA IUpdate into [pscustomobject]@{ Id; Title; KBs; CategoryIds; CanRequestUserInput;
    IsDriver; DriverClass }.
  .DESCRIPTION
    Id is Identity.UpdateID. KBs and CategoryIds are string arrays (possibly empty), read from the COM
    collections with Count/Item(i). Only the category GUIDs (CategoryID) are kept: names are localized.
    A CanRequestUserInput that cannot be read counts as $false.
    -Type is the search that found the update (spec 9.2): IsDriver is $true for 'Driver'. DriverClass
    (IWindowsDriverUpdate.DriverClass, the INF setup class such as 'Firmware'; not localized) is read
    only for drivers, in a try; it is '' for software or when it cannot be read.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]$Update,
    [ValidateSet('Software', 'Driver')][string]$Type = 'Software'
  )

  $categoryIds = [string[]]@(foreach ($category in @(Get-WuCollectionItems -Collection $Update.Categories)) {
      if ($null -eq $category) { continue }
      $id = [string]$category.CategoryID
      if ($id) { $id }
    })
  $kbs = [string[]]@(foreach ($kb in @(Get-WuCollectionItems -Collection $Update.KBArticleIDs)) {
      if ($null -ne $kb -and [string]$kb) { [string]$kb }
    })
  $userInput = $false
  try {
    $behavior = $Update.InstallationBehavior
    if ($null -ne $behavior) { $userInput = [bool]$behavior.CanRequestUserInput }
  } catch {
    $userInput = $false
  }
  $isDriver = ($Type -eq 'Driver')
  $driverClass = ''
  if ($isDriver) {
    try {
      $driverClass = [string]$Update.DriverClass
    } catch {
      $driverClass = ''
    }
  }

  [pscustomobject]@{
    Id                  = [string]$Update.Identity.UpdateID
    Title               = [string]$Update.Title
    KBs                 = $kbs
    CategoryIds         = $categoryIds
    CanRequestUserInput = $userInput
    IsDriver            = $isDriver
    DriverClass         = $driverClass
  }
}

function Select-WuUpdates {
  <#
  .SYNOPSIS
    Sorts the found updates into @{ Install; Hide; Skip; Deferred; OnlyDefinitions }.
  .DESCRIPTION
    In this order:
      Skip     A software update (not IsDriver) with CanRequestUserInput, or IsWindows10 and the
               Upgrades category (the Windows 11 upgrade offer is never taken on Windows 10; on
               Windows 11 the 25H2/26H2 enablement package is installed like any other update).
               Drivers are installed even when they can ask for input (spec 9.2): the installer runs
               with ForceQuiet and no source prompts, and the round timeout is the backstop.
      Deferred A driver whose DriverClass is 'Firmware' (any letter case) while not OnAC: firmware is
               flashed only on mains power. It is not installed, never hidden, and its failure count is
               left alone.
      Hide     FailureCounts[Id] -ge FailuresBeforeHide.
      Install  everything else, in the order found.
    OnlyDefinitions is $true only when Install is not empty and every Install item has the Defender
    definition-updates category. Categories are matched by GUID only. Install, Hide, Skip and Deferred
    are always arrays (never $null), and hold the same objects that came in.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Updates,
    [AllowNull()][System.Collections.IDictionary]$FailureCounts,
    [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$FailuresBeforeHide,
    [Parameter(Mandatory)][bool]$IsWindows10,
    [bool]$OnAC = $true
  )

  $install = New-Object 'System.Collections.Generic.List[object]'
  $hide = New-Object 'System.Collections.Generic.List[object]'
  $skip = New-Object 'System.Collections.Generic.List[object]'
  $deferred = New-Object 'System.Collections.Generic.List[object]'

  foreach ($update in @(ConvertTo-WuList -Value $Updates)) {
    $categories = @(ConvertTo-WuList -Value $update.CategoryIds)
    $id = [string]$update.Id
    $isDriver = ($update.IsDriver -eq $true)
    $failures = 0
    if ($null -ne $FailureCounts -and $id -and $FailureCounts.Contains($id)) { $failures = [int]$FailureCounts[$id] }

    if ((-not $isDriver -and [bool]$update.CanRequestUserInput) -or ($IsWindows10 -and $categories -contains $script:UpgradesCategoryId)) {
      $skip.Add($update)
    } elseif ($isDriver -and ([string]$update.DriverClass).Trim() -eq 'Firmware' -and -not $OnAC) {
      # -eq on strings ignores case in PowerShell: 'firmware' and 'FIRMWARE' match too.
      $deferred.Add($update)
    } elseif ($failures -ge $FailuresBeforeHide) {
      $hide.Add($update)
    } else {
      $install.Add($update)
    }
  }

  $onlyDefinitions = $install.Count -gt 0
  foreach ($update in $install) {
    if (-not (@(ConvertTo-WuList -Value $update.CategoryIds) -contains $script:DefinitionUpdatesCategoryId)) {
      $onlyDefinitions = $false
      break
    }
  }

  return @{
    Install         = $install.ToArray()
    Hide            = $hide.ToArray()
    Skip            = $skip.ToArray()
    Deferred        = $deferred.ToArray()
    OnlyDefinitions = $onlyDefinitions
  }
}

function Get-WuRoundOutcome {
  <#
  .SYNOPSIS
    'Done' or 'Continue' for one round's result.
  .DESCRIPTION
    Done when there is no Error and either nothing was installed or failed, or the round only installed
    Defender definition updates (OnlyDefinitions; those are offered again and again and must not keep
    the loop going). Everything else is Continue.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)]$Result)

  if (Test-WuResultError -Result $Result) { return 'Continue' }
  if ($Result.OnlyDefinitions -eq $true) { return 'Done' }
  $installed = @(ConvertTo-WuList -Value $Result.Installed).Count
  $failed = @(ConvertTo-WuList -Value $Result.Failed).Count
  if ($installed -eq 0 -and $failed -eq 0) { return 'Done' }
  return 'Continue'
}

# --- COM touchpoints (each replaced by the tests) ---------------------------------------------

function New-WuSession {
  # Private. A new Microsoft.Update.Session.
  [CmdletBinding()]
  param()

  $session = New-Object -ComObject 'Microsoft.Update.Session'
  $session.ClientApplicationID = 'BenTech Setup'
  return $session
}

function New-WuServiceManager {
  # Private. A new Microsoft.Update.ServiceManager.
  [CmdletBinding()]
  param()

  return (New-Object -ComObject 'Microsoft.Update.ServiceManager')
}

function Test-WuServiceRegistered {
  # Private. $true when ServiceManager.Services already holds the Microsoft Update service. Read-only.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)]$ServiceManager)

  foreach ($service in @(Get-WuCollectionItems -Collection $ServiceManager.Services)) {
    if ($null -ne $service -and [string]$service.ServiceID -eq $script:MicrosoftUpdateServiceId) { return $true }
  }
  return $false
}

function Register-MicrosoftUpdateService {
  <#
  .SYNOPSIS
    Private. Opts in to Microsoft Update once (spec 13), so searches also find drivers and other
    Microsoft products. Does nothing when the service is already registered.
  .DESCRIPTION
    AddService2(<Microsoft Update id>, 7, ''): 7 = allow pending registration + allow online
    registration + register with Automatic Updates. Throws when the registration fails.
  #>
  [CmdletBinding()]
  param()

  $manager = New-WuServiceManager
  if (Test-WuServiceRegistered -ServiceManager $manager) {
    Write-SetupLog -Message 'Microsoft Update is already registered'
    return
  }
  [void]$manager.AddService2($script:MicrosoftUpdateServiceId, 7, '')
  Write-SetupLog -Message 'Microsoft Update registered' -Data @{ serviceId = $script:MicrosoftUpdateServiceId }
}

function Search-WuUpdates {
  <#
  .SYNOPSIS
    Private. Runs one WUA search against Microsoft Update (ServerSelection 3 + its ServiceID) and emits
    the IUpdate objects found.
  .DESCRIPTION
    A search whose ResultCode is not 2 (succeeded) or 3 (succeeded with errors) throws.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][string]$Criteria
  )

  $searcher = $Session.CreateUpdateSearcher()
  $searcher.ServerSelection = 3      # ssOthers: the service named by ServiceID
  $searcher.ServiceID = $script:MicrosoftUpdateServiceId
  $found = $searcher.Search($Criteria)
  $code = [int]$found.ResultCode
  if ($code -ne 2 -and $code -ne 3) { throw "Windows Update search failed (result code $code): $Criteria" }
  Get-WuCollectionItems -Collection $found.Updates
}

function Set-WuHidden {
  # Private. Sets IUpdate.IsHidden (needs elevation). A mandatory update refuses to be hidden
  # (WU_E_UPDATE_NOT_HIDEABLE-style errors such as 0x80248016); that throws.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Update,
    [Parameter(Mandatory)][bool]$Hidden
  )

  $Update.IsHidden = $Hidden
}

function Approve-WuEula {
  # Private. IUpdate.AcceptEula(). The caller decides whether it is needed (EulaAccepted).
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Update)

  [void]$Update.AcceptEula()
}

function Invoke-WuDownload {
  # Private. Downloads the updates in one batch. Returns @{ ResultCodes = <int[]> (each update's
  # download ResultCode, in the order given); HResult = <int> (the download result's own HResult,
  # 0 = success) }. (The UpdateColl is built in place, not returned from a helper: PowerShell would
  # enumerate a COM collection that a function returns.)
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][object[]]$Updates
  )

  $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
  foreach ($update in $Updates) { [void]$collection.Add($update) }
  $downloader = $Session.CreateUpdateDownloader()
  $downloader.Updates = $collection
  $result = $downloader.Download()
  $codes = @(for ($i = 0; $i -lt $Updates.Count; $i++) { [int]$result.GetUpdateResult($i).ResultCode })
  return @{ ResultCodes = $codes; HResult = [int]$result.HResult }
}

function Invoke-WuInstall {
  # Private. Installs the updates in one batch. Returns @{ ResultCodes = <int[]> (in the order given);
  # RebootRequired = <bool>; HResult = <int> (the installation result's own HResult, 0 = success) }.
  # Triage 233: IUpdateInstaller.ForceQuiet = $true and AllowSourcePrompts = $false, so WUA never waits on a
  # dialog or a "insert the source media" prompt nobody can see for the whole round. Each is best effort: a
  # refused setting is a WARN and the install still runs (the round timeout still bounds it).
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][object[]]$Updates
  )

  $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
  foreach ($update in $Updates) { [void]$collection.Add($update) }
  $installer = $Session.CreateUpdateInstaller()
  try { $installer.ForceQuiet = $true }
  catch { Write-SetupLog -Message 'Windows Update installer refused ForceQuiet' -Level WARN -Data @{ error = $_.Exception.Message } }
  try { $installer.AllowSourcePrompts = $false }
  catch { Write-SetupLog -Message 'Windows Update installer refused AllowSourcePrompts' -Level WARN -Data @{ error = $_.Exception.Message } }
  $installer.Updates = $collection
  $result = $installer.Install()
  $codes = @(for ($i = 0; $i -lt $Updates.Count; $i++) { [int]$result.GetUpdateResult($i).ResultCode })
  return @{ ResultCodes = $codes; RebootRequired = [bool]$result.RebootRequired; HResult = [int]$result.HResult }
}

function Get-WuRebootRequired {
  # Private. Microsoft.Update.SystemInfo.RebootRequired. Read-only.
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  return [bool](New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired
}

# --- the child round --------------------------------------------------------------------------

function Write-WuRoundResult {
  # Private. Writes a round result as JSON (UTF-8 without a BOM, depth 5), creating the folder.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Result
  )

  $folder = Split-Path -Parent $Path
  if ($folder) { [void][IO.Directory]::CreateDirectory($folder) }
  $json = ConvertTo-Json -InputObject $Result -Depth 5
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function New-WuInstalledEntry {
  # Private. One Installed entry of the round result: @{ Id; Title; IsDefinition }. IsDefinition (the
  # Defender definition-updates category GUID) lets the parent leave those out of re-offer counting:
  # definition updates keep their UpdateID and only get a new revision, so they come back legitimately.
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Info)

  return [ordered]@{
    Id           = [string]$Info.Id
    Title        = [string]$Info.Title
    IsDefinition = (@(ConvertTo-WuList -Value $Info.CategoryIds) -contains $script:DefinitionUpdatesCategoryId)
  }
}

function Get-WuRoundNumber {
  # Private. Steps['windows-update'].Data.Rounds from a state hashtable, or 0.
  [CmdletBinding()]
  [OutputType([int])]
  param([Parameter(Mandatory)][hashtable]$State)

  $steps = $State['Steps']
  if ($steps -isnot [System.Collections.IDictionary] -or -not $steps.Contains($script:WuStepId)) { return 0 }
  $step = $steps[$script:WuStepId]
  if ($step -isnot [System.Collections.IDictionary]) { return 0 }
  $data = $step['Data']
  if ($data -isnot [System.Collections.IDictionary] -or -not $data.Contains('Rounds')) { return 0 }
  return [int]$data['Rounds']
}

function Invoke-WuRound {
  <#
  .SYNOPSIS
    One Windows Update round, run in the child process the parent step starts with -WuRound. Always
    writes ResultPath:
      { Installed: [{Id,Title,IsDefinition}], Failed: [{Id,Title,ResultCode}], Hidden: [Id],
        HideFailed: [Id], OnlyDefinitions, RebootRequired, Error, ErrorCode, FirmwareDeferred }
  .DESCRIPTION
    1. Reads state.json (Read-RunState on StatePath's folder; read-only use): WuFailureCounts,
       PreviousHiddenUpdateIds and Steps['windows-update'].Data.Rounds (the parent saved the new
       round number before it started this process). No state is an error.
    2. Registers Microsoft Update unless it already is.
    3. Round 1 only: un-hides the updates the previous run hid (PreviousHiddenUpdateIds), found with
       the search 'IsHidden=1', so they get another chance.
    4. Searches Software, then Driver (Get-WuSearchCriteria), and sorts the result with
       Select-WuUpdates (each update converted with -Type of the search that found it, and -OnAC as
       given: spec 9.2). Each driver update found is logged at INFO with its driverClass. Skipped
       updates are logged (WARN); deferred ones (firmware on battery) are logged at INFO and counted
       in FirmwareDeferred: they are neither installed nor failed.
    5. Hides the Hide set (they failed FailuresBeforeHide times; the parent reports them in red). Each
       hide is tried on its own (ruling R24b): one that throws (a mandatory update cannot be hidden)
       is logged with its code and listed in HideFailed, and the round goes on.
    6. Accepts the EULA (Approve-WuEula) of every update to install whose EulaAccepted is $false.
    7. Downloads what is not downloaded yet. A download ResultCode other than 2/3 makes the update
       Failed with that code; it is not installed.
    8. Installs the rest. ResultCode 2 (succeeded) and 3 (succeeded with errors) are Installed; 4
       (failed), 5 (aborted) and anything else are Failed with their code.
    9. RebootRequired = the install result's RebootRequired or Microsoft.Update.SystemInfo's. SystemInfo
       is read after the round in its own try/catch, on the exception path too (ruling R24a).
    Any exception ends the round: its message is Error, and whatever was already done stays listed.
    ErrorCode (ruling R23) is the numeric HRESULT as '0x' + 8 hex digits, so the parent never depends
    on localized text: an exception's code (Get-WuExceptionErrorCode); otherwise, when the install
    ran, the installation result's own non-zero HResult (or $null); only when no install ran, the
    download result's own non-zero HResult. A result HResult alone does not set Error: the per-update
    results still count.

    -SearchOnly (smoke test only, WhatIf-style): changes nothing on the machine. It does not register
    Microsoft Update (it is an Error when it is not registered), does not un-hide, hide, download or
    install; it searches, writes the Install selection as Installed, and reads SystemInfo.

    -OnAC (spec 9.2): whether the machine is on mains power; the -WuRound entry reads it at the start
    of the round. On battery, firmware driver updates are deferred.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$FailuresBeforeHide,
    [Parameter(Mandatory)][bool]$IsWindows10,
    [switch]$SearchOnly,
    [bool]$OnAC = $true
  )

  $installed = New-Object 'System.Collections.Generic.List[object]'
  $failed = New-Object 'System.Collections.Generic.List[object]'
  $hidden = New-Object 'System.Collections.Generic.List[string]'
  $hideFailed = New-Object 'System.Collections.Generic.List[string]'
  $onlyDefinitions = $false
  $rebootRequired = $false
  $errorText = $null
  $errorCode = $null
  # Set once the selection exists; a round that fails before it deferred nothing.
  $firmwareDeferred = 0

  try {
    $state = Read-RunState -Root (Split-Path -Parent $StatePath)
    if ($null -eq $state) { throw "Run state not found or unreadable: $StatePath" }
    $failureCounts = $state['WuFailureCounts']
    if ($failureCounts -isnot [System.Collections.IDictionary]) { $failureCounts = @{} }
    $previousHidden = @(ConvertTo-WuList -Value $state['PreviousHiddenUpdateIds'] | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $round = Get-WuRoundNumber -State $state
    Write-SetupLog -Message 'Windows Update round starting' -Data @{ round = $round; searchOnly = [bool]$SearchOnly; failuresBeforeHide = $FailuresBeforeHide; isWindows10 = $IsWindows10; onAC = $OnAC }

    $session = New-WuSession
    if ($SearchOnly) {
      if (-not (Test-WuServiceRegistered -ServiceManager (New-WuServiceManager))) {
        throw 'Microsoft Update is not registered; -SearchOnly does not register it'
      }
    } else {
      Register-MicrosoftUpdateService
      if ($round -eq 1 -and $previousHidden.Count -gt 0) {
        foreach ($update in @(Search-WuUpdates -Session $session -Criteria 'IsHidden=1')) {
          if ($null -eq $update) { continue }
          $id = [string]$update.Identity.UpdateID
          if ($previousHidden -notcontains $id) { continue }
          Set-WuHidden -Update $update -Hidden $false
          Write-SetupLog -Message 'Un-hid an update hidden by the previous run' -Data @{ id = $id; title = [string]$update.Title }
        }
      }
    }

    # Id -> IUpdate, so the selection (info objects) can be mapped back to the COM objects.
    $byId = @{}
    $infos = New-Object 'System.Collections.Generic.List[object]'
    foreach ($type in 'Software', 'Driver') {
      foreach ($update in @(Search-WuUpdates -Session $session -Criteria (Get-WuSearchCriteria -Type $type))) {
        if ($null -eq $update) { continue }
        $info = ConvertTo-WuUpdateInfo -Update $update -Type $type
        if ($byId.ContainsKey($info.Id)) { continue }
        $byId[$info.Id] = $update
        $infos.Add($info)
        # Spec 9.2: every driver's class goes to setup.log, so a normal run on the charger proves what
        # DriverClass the firmware updates really report (the firmware rule matches 'Firmware').
        if ($info.IsDriver) {
          Write-SetupLog -Message 'Windows Update driver found' -Data @{ id = $info.Id; title = $info.Title; driverClass = $info.DriverClass }
        }
      }
    }

    $selection = Select-WuUpdates -Updates $infos.ToArray() -FailureCounts $failureCounts -FailuresBeforeHide $FailuresBeforeHide -IsWindows10 $IsWindows10 -OnAC $OnAC
    $onlyDefinitions = [bool]$selection.OnlyDefinitions
    $firmwareDeferred = @($selection.Deferred).Count
    foreach ($info in $selection.Skip) {
      Write-SetupLog -Message 'Windows update skipped (needs user input, or the Windows 11 upgrade on Windows 10)' -Level WARN -Data @{ id = $info.Id; title = $info.Title; userInput = [bool]$info.CanRequestUserInput }
    }
    foreach ($info in $selection.Deferred) {
      Write-SetupLog -Message 'Firmware update left for later: on battery' -Data @{ id = $info.Id; title = $info.Title; driverClass = $info.DriverClass }
    }
    Write-SetupLog -Message 'Windows Update search finished' -Data @{ found = $infos.Count; install = @($selection.Install).Count; hide = @($selection.Hide).Count; skip = @($selection.Skip).Count; deferred = $firmwareDeferred; onlyDefinitions = $onlyDefinitions }

    if ($SearchOnly) {
      foreach ($info in $selection.Install) { $installed.Add((New-WuInstalledEntry -Info $info)) }
    } else {
      # Each hide on its own (ruling R24b): a mandatory update cannot be hidden, and that must not
      # abort the round. It stays out of Install either way; the parent reports it in red.
      foreach ($info in $selection.Hide) {
        try {
          Set-WuHidden -Update $byId[$info.Id] -Hidden $true
          $hidden.Add($info.Id)
          Write-SetupLog -Message 'Windows update hidden after repeated failures' -Level WARN -Data @{ id = $info.Id; title = $info.Title }
        } catch {
          $hideFailed.Add($info.Id)
          Write-SetupLog -Message 'Windows update could not be hidden' -Level WARN -Data @{ id = $info.Id; title = $info.Title; errorCode = (Get-WuExceptionErrorCode -Exception $_.Exception); error = $_.Exception.Message }
        }
      }

      foreach ($info in $selection.Install) {
        $update = $byId[$info.Id]
        if (-not [bool]$update.EulaAccepted) { Approve-WuEula -Update $update }
      }

      # Download what is not there yet; an update whose download did not succeed is not installed.
      # The download's own HResult only becomes ErrorCode when no install runs afterwards: a leftover
      # download code must not trigger the busy / restart handling of a round whose installs worked.
      $downloadErrorCode = $null
      $downloadCodes = @{}
      $toDownload = @(foreach ($info in $selection.Install) { if (-not [bool]$byId[$info.Id].IsDownloaded) { $info } })
      if ($toDownload.Count -gt 0) {
        $download = Invoke-WuDownload -Session $session -Updates @(foreach ($info in $toDownload) { $byId[$info.Id] })
        $codes = @(ConvertTo-WuList -Value $download.ResultCodes)
        if ($null -ne $download.HResult -and [int64]$download.HResult -ne 0) {
          $downloadErrorCode = Format-WuHResult -HResult $download.HResult
          Write-SetupLog -Message 'Windows Update download reported an error code' -Level WARN -Data @{ errorCode = $downloadErrorCode }
        }
        for ($i = 0; $i -lt $toDownload.Count; $i++) {
          $downloadCodes[$toDownload[$i].Id] = if ($i -lt $codes.Count) { [int]$codes[$i] } else { 0 }
        }
      }
      $ready = New-Object 'System.Collections.Generic.List[object]'
      foreach ($info in $selection.Install) {
        $code = if ($downloadCodes.ContainsKey($info.Id)) { $downloadCodes[$info.Id] } else { 2 }
        if ($code -eq 2 -or $code -eq 3) {
          $ready.Add($info)
        } else {
          $failed.Add([ordered]@{ Id = $info.Id; Title = $info.Title; ResultCode = $code })
          Write-SetupLog -Message 'Windows update download failed' -Level WARN -Data @{ id = $info.Id; title = $info.Title; resultCode = $code }
        }
      }

      if ($ready.Count -gt 0) {
        $install = Invoke-WuInstall -Session $session -Updates @(foreach ($info in $ready) { $byId[$info.Id] })
        $codes = @(ConvertTo-WuList -Value $install.ResultCodes)
        $rebootRequired = [bool]$install.RebootRequired
        if ($null -ne $install.HResult -and [int64]$install.HResult -ne 0) {
          $errorCode = Format-WuHResult -HResult $install.HResult
          Write-SetupLog -Message 'Windows Update installation reported an error code' -Level WARN -Data @{ errorCode = $errorCode }
        }
        for ($i = 0; $i -lt $ready.Count; $i++) {
          $info = $ready[$i]
          $code = if ($i -lt $codes.Count) { [int]$codes[$i] } else { 0 }
          if ($code -eq 2 -or $code -eq 3) {
            $installed.Add((New-WuInstalledEntry -Info $info))
          } else {
            $failed.Add([ordered]@{ Id = $info.Id; Title = $info.Title; ResultCode = $code })
            Write-SetupLog -Message 'Windows update install failed' -Level WARN -Data @{ id = $info.Id; title = $info.Title; resultCode = $code }
          }
        }
      } else {
        $errorCode = $downloadErrorCode
      }
    }
  } catch {
    $errorText = [string]$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = [string]$_ }
    $errorCode = Get-WuExceptionErrorCode -Exception $_.Exception
    Write-SetupLog -Message 'Windows Update round failed' -Level ERROR -Data @{ error = $errorText; errorCode = $errorCode }
  }

  # Always read SystemInfo, on the exception path too (ruling R24a): 0x80240016 also means "a
  # mandatory restart is pending", and the parent must then restart instead of waiting. A failed read
  # is only a WARN; it never turns the round into an error.
  try {
    if ([bool](Get-WuRebootRequired)) { $rebootRequired = $true }
  } catch {
    Write-SetupLog -Message 'Windows Update restart flag could not be read' -Level WARN -Data @{ errorCode = (Get-WuExceptionErrorCode -Exception $_.Exception); error = $_.Exception.Message }
  }

  $result = [ordered]@{
    Installed        = $installed.ToArray()
    Failed           = $failed.ToArray()
    Hidden           = $hidden.ToArray()
    HideFailed       = $hideFailed.ToArray()
    OnlyDefinitions  = $onlyDefinitions
    RebootRequired   = $rebootRequired
    Error            = $errorText
    ErrorCode        = $errorCode
    FirmwareDeferred = $firmwareDeferred
  }
  Write-WuRoundResult -Path $ResultPath -Result $result
  Write-SetupLog -Message 'Windows Update round result written' -Data @{ path = $ResultPath; installed = $installed.Count; failed = $failed.Count; hidden = $hidden.Count; hideFailed = $hideFailed.Count; firmwareDeferred = $firmwareDeferred; rebootRequired = $rebootRequired; error = $errorText; errorCode = $errorCode }
}

# --- the parent step --------------------------------------------------------------------------

function Get-WuStepData {
  # Private. Steps['windows-update'].Data of the state (created when missing, with FailedTitles), as the
  # live hashtable the runner saves. A state without the windows-update step throws.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$State)

  $steps = $State['Steps']
  if ($steps -isnot [System.Collections.IDictionary] -or $steps[$script:WuStepId] -isnot [System.Collections.IDictionary]) {
    throw "The run state has no '$($script:WuStepId)' step"
  }
  $step = $steps[$script:WuStepId]
  if ($step['Data'] -isnot [System.Collections.IDictionary]) { $step['Data'] = @{} }
  $data = $step['Data']
  if ($data['FailedTitles'] -isnot [System.Collections.IDictionary]) { $data['FailedTitles'] = @{} }
  return $data
}

function Get-WuResultData {
  # Private. The step result's Data: Rounds, Installed (running total of distinct installs),
  # InstalledIds (string array, for re-offer detection) and FailedTitles (id -> title). Never
  # Interruptions: that key belongs to the runner.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)

  return @{
    Rounds       = [int]$Data['Rounds']
    Installed    = [int]$Data['Installed']
    InstalledIds = [string[]]@(ConvertTo-WuList -Value $Data['InstalledIds'])
    FailedTitles = $Data['FailedTitles']
  }
}

function Format-WuFailedNote {
  # Private. 'Some Windows updates failed: <titles>' for a round that is Done although updates failed
  # (ruling R24d): at most 3 titles (the id when there is no title), then an ellipsis.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Failed)

  $names = @(foreach ($item in $Failed) {
      if ([string]::IsNullOrWhiteSpace([string]$item.Title)) { [string]$item.Id } else { [string]$item.Title }
    })
  $text = ($names | Select-Object -First 3) -join ', '
  if ($names.Count -gt 3) { $text += ', ' + [char]0x2026 }
  return "Some Windows updates failed: $text"
}

function Read-WuRoundResult {
  # Private. The child's result JSON as an object, or $null when the file is missing, empty, not valid
  # JSON, not a JSON object, or lacks Installed/Failed/Hidden (logged as WARN).
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding $false))
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'the file is empty' }
    $result = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    if ($result -isnot [System.Management.Automation.PSCustomObject]) { throw 'not a JSON object' }
    foreach ($name in 'Installed', 'Failed', 'Hidden') {
      if ($null -eq $result.PSObject.Properties[$name]) { throw "no $name list" }
    }
    return $result
  } catch {
    Write-SetupLog -Message 'Windows Update round result is unreadable' -Level WARN -Data @{ path = $Path; error = $_.Exception.Message }
    return $null
  }
}

function Update-WuRunState {
  <#
  .SYNOPSIS
    Private. Books one round result into the state.
  .DESCRIPTION
    - Failed: FailedTitles[Id] = Title, and WuFailureCounts[Id]++ unless -SkipFailureCounts (ruling
      R23b: a busy / restart-pending round says nothing about whether an update is bad).
    - Installed (ruling R24c): an id already in Data.InstalledIds was "successfully" installed before
      and is offered again; that is a re-offer: WuFailureCounts[Id]++ and FailedTitles[Id] = Title, and
      it is not counted again in Data.Installed, so after FailuresBeforeHide re-offers the child hides
      it. A new id goes into InstalledIds and Data.Installed + 1. Defender definition updates
      (IsDefinition) keep their UpdateID across new revisions, so they are never re-offers: they only
      add to Data.Installed.
    - Hidden: appended to HiddenUpdateIds (no duplicates, ignoring case).
    - HideFailed (ruling R24b): 'Windows update could not be hidden: <title or id>' appended to
      State.Errors once (red in the verdict).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Data,
    [Parameter(Mandatory)]$Result,
    [switch]$SkipFailureCounts
  )

  if ($State['WuFailureCounts'] -isnot [System.Collections.IDictionary]) { $State['WuFailureCounts'] = @{} }
  $counts = $State['WuFailureCounts']
  $titles = $Data['FailedTitles']
  foreach ($item in @(ConvertTo-WuList -Value $Result.Failed)) {
    $id = [string]$item.Id
    if (-not $id) { continue }
    if (-not $SkipFailureCounts) { $counts[$id] = [int]$counts[$id] + 1 }
    $titles[$id] = [string]$item.Title
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $all = New-Object 'System.Collections.Generic.List[string]'
  foreach ($id in (@(ConvertTo-WuList -Value $State['HiddenUpdateIds']) + @(ConvertTo-WuList -Value $Result.Hidden))) {
    $text = [string]$id
    if ($text -and $seen.Add($text)) { $all.Add($text) }
  }
  $State['HiddenUpdateIds'] = $all.ToArray()

  $installedIds = New-Object 'System.Collections.Generic.List[string]'
  $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($id in @(ConvertTo-WuList -Value $Data['InstalledIds'])) {
    $text = [string]$id
    if ($text -and $known.Add($text)) { $installedIds.Add($text) }
  }
  $total = [int]$Data['Installed']
  foreach ($item in @(ConvertTo-WuList -Value $Result.Installed)) {
    $id = [string]$item.Id
    if (-not $id) { continue }
    if ($item.IsDefinition -eq $true) { $total++; continue }
    if ($known.Contains($id)) {
      $counts[$id] = [int]$counts[$id] + 1
      $titles[$id] = [string]$item.Title
      Write-SetupLog -Message 'Windows update offered again after a successful install; counted as a failure' -Level WARN -Data @{ id = $id; title = [string]$item.Title; count = $counts[$id] }
      continue
    }
    [void]$known.Add($id)
    $installedIds.Add($id)
    $total++
  }
  $Data['InstalledIds'] = $installedIds.ToArray()
  $Data['Installed'] = $total

  foreach ($id in @(ConvertTo-WuList -Value $Result.HideFailed)) {
    $text = [string]$id
    if (-not $text) { continue }
    $name = if ($titles.Contains($text) -and -not [string]::IsNullOrWhiteSpace([string]$titles[$text])) { [string]$titles[$text] } else { $text }
    $entry = "Windows update could not be hidden: $name"
    $errors = @(ConvertTo-WuList -Value $State['Errors'])
    if ($errors -notcontains $entry) { $State['Errors'] = @($errors + $entry) }
  }
}

function Invoke-StepWindowsUpdate {
  <#
  .SYNOPSIS
    Step 13: one bounded Windows Update round per call. Continue (Reboot 'Now' when a restart is
    needed) until a round has nothing left to do, then Done.
  .DESCRIPTION
    1. Data.Rounds + 1. Above caps.maxWuRounds -> Failed('Windows Update round cap reached (<cap>)'),
       without starting a round.
    2. Saves the state: the child reads the new round number and the failure counts from state.json.
    3. Removes a stale <Logs>\wu-round<N>.json (Logs survive earlier runs), then runs
       "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass
       -File "<ScriptPath>" -WuRound -ResultPath "<Logs>\wu-round<N>.json" with timeoutsMinutes.wuRound
       (the whole process tree is killed on timeout). Timeout -> Failed('Windows Update round timed
       out'); a child that cannot start -> Failed('Windows Update round could not be started: ...').
    4. No readable result JSON -> Failed('Windows Update round produced no result').
    5. Books the result into the state (Update-WuRunState), even when it carries an Error, so an update
       the round hid before failing is still reported. On a round with one of the three mapped codes
       below, failed updates get their FailedTitles entry but NOT a WuFailureCounts increment (ruling
       R23b: a busy agent says nothing about whether an update is bad).
    6. ErrorCode (ruling R23; the numeric code, never the localized text), before the Error check:
         0x80240016 / 0x8024A000 (another install in progress, or a mandatory restart pending / no AU
           service): with RebootRequired, WARN and Continue with Reboot 'Now' at once (ruling R24a);
           otherwise WARN, wait BusyWaitSeconds (default 120), then Continue with no restart. The
           round still counts toward the cap, so a machine that stays busy ends at the cap.
         0x80242014 (earlier updates need a restart to finish): WARN, Continue with Reboot 'Now'.
    7. Error -> Failed('Windows Update error: <Error> (<ErrorCode>)'), or without the brackets when there
       is no code. An ErrorCode without an Error (a download or installation result's own HResult)
       does not fail the step: it is logged and the per-update results decide, so ordinary update
       failures still go through the failure counter.
    8. Get-WuRoundOutcome: Done -> Done('Installed <total> updates in <rounds> rounds'), with the Note
       'Some Windows updates failed: <up to 3 titles>' when the round still listed failed updates
       (ruling R24d); Continue -> Continue, Reboot 'Now' when RebootRequired.
    Spec 9.2: a round whose FirmwareDeferred is above 0 (firmware left alone on battery) carries the
    Note $script:WuBatteryNote on its Continue or Done result. Deferred updates are neither installed
    nor failed, so they never keep the loop going; the verdict shows the Note once (exact match, M1).
    Data = @{ Rounds; Installed; InstalledIds; FailedTitles } (shallow: the report prints hidden
    updates by title). Installed counts distinct updates; a re-offer is counted as a failure instead
    (ruling R24c, see Update-WuRunState).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [ValidateRange(0, 3600)][int]$BusyWaitSeconds = 120
  )

  $state = $Context.State
  $data = Get-WuStepData -State $state
  $cap = [int]$Context.Config.caps.maxWuRounds
  $round = [int]$data['Rounds'] + 1
  $data['Rounds'] = $round
  if ($round -gt $cap) {
    Write-SetupLog -Message 'Windows Update round cap reached' -Level WARN -Data @{ round = $round; cap = $cap }
    return New-StepResult -Status Failed -Message "Windows Update round cap reached ($cap)" -Data (Get-WuResultData -Data $data)
  }

  Save-RunState -State $state -Root $Context.Root

  $resultPath = Join-Path $Context.LogDir "wu-round$round.json"
  $exe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -WuRound -ResultPath "{1}"' -f $Context.ScriptPath, $resultPath
  $timeout = [double]$Context.Config.timeoutsMinutes.wuRound
  Write-SetupLog -Message 'Windows Update round starting' -Data @{ round = $round; cap = $cap; resultPath = $resultPath }
  try {
    if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force -ErrorAction Stop }
    $run = Invoke-External -FilePath $exe -ArgumentList $arguments -TimeoutMinutes $timeout
  } catch {
    Write-SetupLog -Message 'Windows Update round could not be started' -Level ERROR -Data @{ round = $round; error = $_.Exception.Message }
    return New-StepResult -Status Failed -Message "Windows Update round could not be started: $($_.Exception.Message)" -Data (Get-WuResultData -Data $data)
  }
  if ($run.TimedOut) {
    return New-StepResult -Status Failed -Message 'Windows Update round timed out' -Data (Get-WuResultData -Data $data)
  }

  $result = Read-WuRoundResult -Path $resultPath
  if ($null -eq $result) {
    Write-SetupLog -Message 'Windows Update round produced no result' -Level ERROR -Data @{ round = $round; exitCode = $run.ExitCode; path = $resultPath }
    return New-StepResult -Status Failed -Message 'Windows Update round produced no result' -Data (Get-WuResultData -Data $data)
  }

  $errorCode = Get-WuResultErrorCode -Result $result
  $isBusy = $script:WuBusyErrorCodes -contains $errorCode
  $isRebootPending = $errorCode -eq $script:WuRebootPendingErrorCode
  Update-WuRunState -State $state -Data $data -Result $result -SkipFailureCounts:($isBusy -or $isRebootPending)
  $installedNow = @(ConvertTo-WuList -Value $result.Installed).Count
  $failedNow = @(ConvertTo-WuList -Value $result.Failed).Count
  $rebootNow = ($result.RebootRequired -eq $true)
  # Spec 9.2. -as never throws: a result without the field (or an odd value) deferred nothing.
  $deferredNow = [int]($result.FirmwareDeferred -as [int])
  $batteryNotes = @()
  if ($deferredNow -gt 0) { $batteryNotes = @($script:WuBatteryNote) }
  Write-SetupLog -Message 'Windows Update round finished' -Data @{ round = $round; exitCode = $run.ExitCode; installed = $installedNow; failed = $failedNow; hidden = @(ConvertTo-WuList -Value $result.Hidden).Count; firmwareDeferred = $deferredNow; rebootRequired = $rebootNow; error = [string]$result.Error; errorCode = $errorCode }

  # Ruling R23: codes that mean "not now" are retried; the round still counts toward the cap.
  # Ruling R24a: 0x80240016 also means "a mandatory restart is pending"; when the machine says a
  # restart is required, restart now instead of waiting for something only a restart can clear.
  if ($isBusy -and $rebootNow) {
    Write-SetupLog -Message 'Windows Update agent is busy and a restart is pending; restarting' -Level WARN -Data @{ round = $round; errorCode = $errorCode; cap = $cap }
    return New-StepResult -Status Continue -Message "Windows Update round ${round}: agent busy ($errorCode), restart pending" -Reboot Now -Notes $batteryNotes -Data (Get-WuResultData -Data $data)
  }
  if ($isBusy) {
    Write-SetupLog -Message 'Windows Update agent is busy; waiting, then retrying' -Level WARN -Data @{ round = $round; errorCode = $errorCode; waitSeconds = $BusyWaitSeconds; cap = $cap }
    Wait-SetupDelay -Seconds $BusyWaitSeconds
    return New-StepResult -Status Continue -Message "Windows Update round ${round}: agent busy ($errorCode), retrying" -Notes $batteryNotes -Data (Get-WuResultData -Data $data)
  }
  if ($isRebootPending) {
    Write-SetupLog -Message 'Windows Update needs a restart to finish earlier updates; restarting' -Level WARN -Data @{ round = $round; errorCode = $errorCode; cap = $cap }
    return New-StepResult -Status Continue -Message "Windows Update round ${round}: restart needed to finish earlier updates ($errorCode)" -Reboot Now -Notes $batteryNotes -Data (Get-WuResultData -Data $data)
  }

  if (Test-WuResultError -Result $result) {
    $text = "Windows Update error: $($result.Error)"
    if ($errorCode) { $text += " ($errorCode)" }
    return New-StepResult -Status Failed -Message $text -Data (Get-WuResultData -Data $data)
  }
  if ($errorCode) {
    Write-SetupLog -Message 'Windows Update reported an error code without an error; the per-update results decide' -Level WARN -Data @{ round = $round; errorCode = $errorCode }
  }

  if ((Get-WuRoundOutcome -Result $result) -eq 'Done') {
    # Ruling R24d: Done (e.g. a definitions-only round) can still carry failed updates; say so in yellow.
    $failedItems = @(ConvertTo-WuList -Value $result.Failed)
    $notes = @()
    if ($failedItems.Count -gt 0) { $notes = @(Format-WuFailedNote -Failed $failedItems) }
    $notes = @($notes) + $batteryNotes
    return New-StepResult -Status Done -Message "Installed $([int]$data['Installed']) updates in $round rounds" -Notes $notes -Data (Get-WuResultData -Data $data)
  }
  $reboot = if ($rebootNow) { 'Now' } else { 'None' }
  $message = "Windows Update round ${round}: $installedNow installed, $failedNow failed"
  return New-StepResult -Status Continue -Message $message -Reboot $reboot -Notes $batteryNotes -Data (Get-WuResultData -Data $data)
}
