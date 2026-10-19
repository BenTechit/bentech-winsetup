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
    Turns a WUA IUpdate into [pscustomobject]@{ Id; Title; KBs; CategoryIds; CanRequestUserInput }.
  .DESCRIPTION
    Id is Identity.UpdateID. KBs and CategoryIds are string arrays (possibly empty), read from the COM
    collections with Count/Item(i). Only the category GUIDs (CategoryID) are kept: names are localized.
    A CanRequestUserInput that cannot be read counts as $false.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)]$Update)

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

  [pscustomobject]@{
    Id                  = [string]$Update.Identity.UpdateID
    Title               = [string]$Update.Title
    KBs                 = $kbs
    CategoryIds         = $categoryIds
    CanRequestUserInput = $userInput
  }
}

function Select-WuUpdates {
  <#
  .SYNOPSIS
    Sorts the found updates into @{ Install; Hide; Skip; OnlyDefinitions }.
  .DESCRIPTION
    In this order:
      Skip    CanRequestUserInput, or IsWindows10 and the Upgrades category (the Windows 11 upgrade
              offer is never taken on Windows 10; on Windows 11 the 25H2/26H2 enablement package is
              installed like any other update).
      Hide    FailureCounts[Id] -ge FailuresBeforeHide.
      Install everything else, in the order found.
    OnlyDefinitions is $true only when Install is not empty and every Install item has the Defender
    definition-updates category. Categories are matched by GUID only. Install, Hide and Skip are always
    arrays (never $null), and hold the same objects that came in.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Updates,
    [AllowNull()][System.Collections.IDictionary]$FailureCounts,
    [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$FailuresBeforeHide,
    [Parameter(Mandatory)][bool]$IsWindows10
  )

  $install = New-Object 'System.Collections.Generic.List[object]'
  $hide = New-Object 'System.Collections.Generic.List[object]'
  $skip = New-Object 'System.Collections.Generic.List[object]'

  foreach ($update in @(ConvertTo-WuList -Value $Updates)) {
    $categories = @(ConvertTo-WuList -Value $update.CategoryIds)
    $id = [string]$update.Id
    $failures = 0
    if ($null -ne $FailureCounts -and $id -and $FailureCounts.Contains($id)) { $failures = [int]$FailureCounts[$id] }

    if ([bool]$update.CanRequestUserInput -or ($IsWindows10 -and $categories -contains $script:UpgradesCategoryId)) {
      $skip.Add($update)
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
  # Private. Sets IUpdate.IsHidden (needs elevation).
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Update,
    [Parameter(Mandatory)][bool]$Hidden
  )

  $Update.IsHidden = $Hidden
}

function Invoke-WuDownload {
  # Private. Downloads the updates in one batch and emits each update's download ResultCode (int), in
  # the order given. (The UpdateColl is built in place, not returned from a helper: PowerShell would
  # enumerate a COM collection that a function returns.)
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][object[]]$Updates
  )

  $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
  foreach ($update in $Updates) { [void]$collection.Add($update) }
  $downloader = $Session.CreateUpdateDownloader()
  $downloader.Updates = $collection
  $result = $downloader.Download()
  for ($i = 0; $i -lt $Updates.Count; $i++) { [int]$result.GetUpdateResult($i).ResultCode }
}

function Invoke-WuInstall {
  # Private. Installs the updates in one batch. Returns @{ ResultCodes = <int[]> (in the order given);
  # RebootRequired = <bool> }.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][object[]]$Updates
  )

  $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
  foreach ($update in $Updates) { [void]$collection.Add($update) }
  $installer = $Session.CreateUpdateInstaller()
  $installer.Updates = $collection
  $result = $installer.Install()
  $codes = @(for ($i = 0; $i -lt $Updates.Count; $i++) { [int]$result.GetUpdateResult($i).ResultCode })
  return @{ ResultCodes = $codes; RebootRequired = [bool]$result.RebootRequired }
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
      { Installed: [{Id,Title}], Failed: [{Id,Title,ResultCode}], Hidden: [Id],
        OnlyDefinitions, RebootRequired, Error }
  .DESCRIPTION
    1. Reads state.json (Read-RunState on StatePath's folder; read-only use): WuFailureCounts,
       PreviousHiddenUpdateIds and Steps['windows-update'].Data.Rounds (the parent saved the new
       round number before it started this process). No state is an error.
    2. Registers Microsoft Update unless it already is.
    3. Round 1 only: un-hides the updates the previous run hid (PreviousHiddenUpdateIds), found with
       the search 'IsHidden=1', so they get another chance.
    4. Searches Software, then Driver (Get-WuSearchCriteria), and sorts the result with
       Select-WuUpdates. Skipped updates are logged.
    5. Hides the Hide set (they failed FailuresBeforeHide times; the parent reports them in red).
    6. Accepts the EULA of every update to install whose EulaAccepted is $false.
    7. Downloads what is not downloaded yet. A download ResultCode other than 2/3 makes the update
       Failed with that code; it is not installed.
    8. Installs the rest. ResultCode 2 (succeeded) and 3 (succeeded with errors) are Installed; 4
       (failed), 5 (aborted) and anything else are Failed with their code.
    9. RebootRequired = the install result's RebootRequired or Microsoft.Update.SystemInfo's.
    Any exception ends the round: its message is Error, and whatever was already done stays listed.

    -SearchOnly (smoke test only, WhatIf-style): changes nothing on the machine. It does not register
    Microsoft Update (it is an Error when it is not registered), does not un-hide, hide, download or
    install; it searches, writes the Install selection as Installed, and reads SystemInfo.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$FailuresBeforeHide,
    [Parameter(Mandatory)][bool]$IsWindows10,
    [switch]$SearchOnly
  )

  $installed = New-Object 'System.Collections.Generic.List[object]'
  $failed = New-Object 'System.Collections.Generic.List[object]'
  $hidden = New-Object 'System.Collections.Generic.List[string]'
  $onlyDefinitions = $false
  $rebootRequired = $false
  $errorText = $null

  try {
    $state = Read-RunState -Root (Split-Path -Parent $StatePath)
    if ($null -eq $state) { throw "Run state not found or unreadable: $StatePath" }
    $failureCounts = $state['WuFailureCounts']
    if ($failureCounts -isnot [System.Collections.IDictionary]) { $failureCounts = @{} }
    $previousHidden = @(ConvertTo-WuList -Value $state['PreviousHiddenUpdateIds'] | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $round = Get-WuRoundNumber -State $state
    Write-SetupLog -Message 'Windows Update round starting' -Data @{ round = $round; searchOnly = [bool]$SearchOnly; failuresBeforeHide = $FailuresBeforeHide; isWindows10 = $IsWindows10 }

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
        $info = ConvertTo-WuUpdateInfo -Update $update
        if ($byId.ContainsKey($info.Id)) { continue }
        $byId[$info.Id] = $update
        $infos.Add($info)
      }
    }

    $selection = Select-WuUpdates -Updates $infos.ToArray() -FailureCounts $failureCounts -FailuresBeforeHide $FailuresBeforeHide -IsWindows10 $IsWindows10
    $onlyDefinitions = [bool]$selection.OnlyDefinitions
    foreach ($info in $selection.Skip) {
      Write-SetupLog -Message 'Windows update skipped (needs user input, or the Windows 11 upgrade on Windows 10)' -Level WARN -Data @{ id = $info.Id; title = $info.Title; userInput = [bool]$info.CanRequestUserInput }
    }
    Write-SetupLog -Message 'Windows Update search finished' -Data @{ found = $infos.Count; install = @($selection.Install).Count; hide = @($selection.Hide).Count; skip = @($selection.Skip).Count; onlyDefinitions = $onlyDefinitions }

    if ($SearchOnly) {
      foreach ($info in $selection.Install) { $installed.Add([ordered]@{ Id = $info.Id; Title = $info.Title }) }
      $rebootRequired = [bool](Get-WuRebootRequired)
    } else {
      foreach ($info in $selection.Hide) {
        Set-WuHidden -Update $byId[$info.Id] -Hidden $true
        $hidden.Add($info.Id)
        Write-SetupLog -Message 'Windows update hidden after repeated failures' -Level WARN -Data @{ id = $info.Id; title = $info.Title }
      }

      foreach ($info in $selection.Install) {
        $update = $byId[$info.Id]
        if (-not [bool]$update.EulaAccepted) { [void]$update.AcceptEula() }
      }

      # Download what is not there yet; an update whose download did not succeed is not installed.
      $downloadCodes = @{}
      $toDownload = @(foreach ($info in $selection.Install) { if (-not [bool]$byId[$info.Id].IsDownloaded) { $info } })
      if ($toDownload.Count -gt 0) {
        $codes = @(Invoke-WuDownload -Session $session -Updates @(foreach ($info in $toDownload) { $byId[$info.Id] }))
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

      $installReboot = $false
      if ($ready.Count -gt 0) {
        $install = Invoke-WuInstall -Session $session -Updates @(foreach ($info in $ready) { $byId[$info.Id] })
        $codes = @(ConvertTo-WuList -Value $install.ResultCodes)
        $installReboot = [bool]$install.RebootRequired
        for ($i = 0; $i -lt $ready.Count; $i++) {
          $info = $ready[$i]
          $code = if ($i -lt $codes.Count) { [int]$codes[$i] } else { 0 }
          if ($code -eq 2 -or $code -eq 3) {
            $installed.Add([ordered]@{ Id = $info.Id; Title = $info.Title })
          } else {
            $failed.Add([ordered]@{ Id = $info.Id; Title = $info.Title; ResultCode = $code })
            Write-SetupLog -Message 'Windows update install failed' -Level WARN -Data @{ id = $info.Id; title = $info.Title; resultCode = $code }
          }
        }
      }
      $rebootRequired = $installReboot -or [bool](Get-WuRebootRequired)
    }
  } catch {
    $errorText = [string]$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = [string]$_ }
    Write-SetupLog -Message 'Windows Update round failed' -Level ERROR -Data @{ error = $errorText }
  }

  $result = [ordered]@{
    Installed       = $installed.ToArray()
    Failed          = $failed.ToArray()
    Hidden          = $hidden.ToArray()
    OnlyDefinitions = $onlyDefinitions
    RebootRequired  = $rebootRequired
    Error           = $errorText
  }
  Write-WuRoundResult -Path $ResultPath -Result $result
  Write-SetupLog -Message 'Windows Update round result written' -Data @{ path = $ResultPath; installed = $installed.Count; failed = $failed.Count; hidden = $hidden.Count; rebootRequired = $rebootRequired; error = $errorText }
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
  # Private. The step result's Data: Rounds, Installed (running total) and FailedTitles (id -> title).
  # Never Interruptions: that key belongs to the runner.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)

  return @{ Rounds = [int]$Data['Rounds']; Installed = [int]$Data['Installed']; FailedTitles = $Data['FailedTitles'] }
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
  # Private. Books one round result into the state: WuFailureCounts[Id]++ and FailedTitles[Id] = Title
  # for every failed update, Hidden appended to HiddenUpdateIds (no duplicates, ignoring case), and
  # the Installed count added to Data.Installed.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Data,
    [Parameter(Mandatory)]$Result
  )

  if ($State['WuFailureCounts'] -isnot [System.Collections.IDictionary]) { $State['WuFailureCounts'] = @{} }
  $counts = $State['WuFailureCounts']
  $titles = $Data['FailedTitles']
  foreach ($item in @(ConvertTo-WuList -Value $Result.Failed)) {
    $id = [string]$item.Id
    if (-not $id) { continue }
    $counts[$id] = [int]$counts[$id] + 1
    $titles[$id] = [string]$item.Title
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $all = New-Object 'System.Collections.Generic.List[string]'
  foreach ($id in (@(ConvertTo-WuList -Value $State['HiddenUpdateIds']) + @(ConvertTo-WuList -Value $Result.Hidden))) {
    $text = [string]$id
    if ($text -and $seen.Add($text)) { $all.Add($text) }
  }
  $State['HiddenUpdateIds'] = $all.ToArray()

  $Data['Installed'] = [int]$Data['Installed'] + @(ConvertTo-WuList -Value $Result.Installed).Count
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
       the round hid before failing is still reported.
    6. Error -> Failed('Windows Update error: <Error>').
    7. Get-WuRoundOutcome: Done -> Done('Installed <total> updates in <rounds> rounds');
       Continue -> Continue, Reboot 'Now' when RebootRequired.
    Data = @{ Rounds; Installed; FailedTitles } (shallow: the report prints hidden updates by title).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

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

  Update-WuRunState -State $state -Data $data -Result $result
  $installedNow = @(ConvertTo-WuList -Value $result.Installed).Count
  $failedNow = @(ConvertTo-WuList -Value $result.Failed).Count
  $rebootNow = ($result.RebootRequired -eq $true)
  Write-SetupLog -Message 'Windows Update round finished' -Data @{ round = $round; exitCode = $run.ExitCode; installed = $installedNow; failed = $failedNow; hidden = @(ConvertTo-WuList -Value $result.Hidden).Count; rebootRequired = $rebootNow; error = [string]$result.Error }

  if (Test-WuResultError -Result $result) {
    return New-StepResult -Status Failed -Message "Windows Update error: $($result.Error)" -Data (Get-WuResultData -Data $data)
  }

  if ((Get-WuRoundOutcome -Result $result) -eq 'Done') {
    return New-StepResult -Status Done -Message "Installed $([int]$data['Installed']) updates in $round rounds" -Data (Get-WuResultData -Data $data)
  }
  $reboot = if ($rebootNow) { 'Now' } else { 'None' }
  $message = "Windows Update round ${round}: $installedNow installed, $failedNow failed"
  return New-StepResult -Status Continue -Message $message -Reboot $reboot -Data (Get-WuResultData -Data $data)
}
