# tools/spikes/Spike-WuaSearch.ps1
# THROWAWAY research tool for spec section 17, spike #2 (Windows Update Agent search).
#
# Question: on a fresh machine, do the 25H2/26H2 enablement packages show up in a consumer
# device search, and with which BrowseOnly / category values?
#
# It registers Microsoft Update (AddService2) and then SEARCHES FOUR TIMES, ServerSelection=3:
#   BrowseOnly=0 and BrowseOnly=1, each for Type='Software' and Type='Driver'.
# IT INSTALLS NOTHING: no download, no install, no hide. Each search can take several minutes.
#
# Run elevated on a fresh TEST VM:
#   powershell -ExecutionPolicy Bypass -File Spike-WuaSearch.ps1
# Send back: C:\BenTechSpike\wua-result.json
#
# Never prompts. ASCII only. Windows PowerShell 5.1.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SpikeDir = 'C:\BenTechSpike'
$ResultJsonPath = Join-Path $SpikeDir 'wua-result.json'
$MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
$UpgradesCategoryId = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'

# --- Elevation check -------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'ERROR: this spike must run elevated. Open PowerShell with "Run as administrator" and run it again.' -ForegroundColor Red
  exit 1
}

# --- Helpers ---------------------------------------------------------------------------------
function Save-Json {
  param($Object, [string]$Path)
  $json = $Object | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-NowText {
  return (Get-Date).ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

# Runs a script block and returns $null if it throws (some COM properties are missing on some updates).
function Get-Safe {
  param([scriptblock]$Block)
  try { return (& $Block) } catch { return $null }
}

function Get-MachineFacts {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem
  $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  return [ordered]@{
    ComputerName   = $env:COMPUTERNAME
    Manufacturer   = $cs.Manufacturer
    Model          = $cs.Model
    PartOfDomain   = [bool]$cs.PartOfDomain
    Caption        = $os.Caption
    EditionId      = $cv.EditionID
    Version        = $os.Version
    BuildNumber    = $os.BuildNumber
    Ubr            = $cv.UBR
    DisplayVersion = $cv.DisplayVersion
  }
}

# Values of the Windows Update policy key, if any (a WSUS or target-release policy changes the answer).
function Get-WuPolicyValues {
  $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $out = [ordered]@{ KeyPresent = (Test-Path -LiteralPath $key); Values = [ordered]@{} }
  if ($out.KeyPresent) {
    $props = Get-ItemProperty -LiteralPath $key
    foreach ($p in $props.PSObject.Properties) {
      if ($p.Name -notlike 'PS*') { $out.Values[$p.Name] = [string]$p.Value }
    }
  }
  return $out
}

function Convert-UpdateToRecord {
  param($Update)
  $cats = New-Object System.Collections.ArrayList
  foreach ($c in $Update.Categories) {
    [void]$cats.Add([ordered]@{
        CategoryID = [string]$c.CategoryID
        Name       = [string]$c.Name
        Type       = [string](Get-Safe { $c.Type })
      })
  }
  $kbs = @()
  foreach ($k in $Update.KBArticleIDs) { $kbs += [string]$k }

  return [ordered]@{
    Title                = [string]$Update.Title
    KBArticleIDs         = $kbs
    UpdateID             = [string]$Update.Identity.UpdateID
    RevisionNumber       = (Get-Safe { $Update.Identity.RevisionNumber })
    Categories           = $cats
    BrowseOnly           = (Get-Safe { $Update.BrowseOnly })
    IsMandatory          = (Get-Safe { $Update.IsMandatory })
    CanRequestUserInput  = (Get-Safe { $Update.InstallationBehavior.CanRequestUserInput })
    RebootBehavior       = (Get-Safe { $Update.InstallationBehavior.RebootBehavior })
    DeploymentAction     = (Get-Safe { $Update.DeploymentAction })
    UpdateType           = (Get-Safe { $Update.Type })
    IsDownloaded         = (Get-Safe { $Update.IsDownloaded })
    EulaAccepted         = (Get-Safe { $Update.EulaAccepted })
    MaxDownloadSizeBytes = (Get-Safe { $Update.MaxDownloadSize })
  }
}

function Invoke-WuaSearch {
  param($Session, [int]$BrowseOnly, [string]$UpdateType)
  $criteria = "IsInstalled=0 and IsHidden=0 and BrowseOnly=$BrowseOnly and Type='$UpdateType'"
  $updates = New-Object System.Collections.ArrayList
  $entry = [ordered]@{
    Criteria                = $criteria
    BrowseOnlyRequested     = $BrowseOnly
    TypeRequested           = $UpdateType
    Succeeded               = $false
    ResultCode              = $null
    ElapsedSeconds          = $null
    UpdateCount             = 0
    UpgradesCategoryCount   = 0
    Error                   = $null
    Updates                 = $updates
  }
  Write-Host ('Searching: ' + $criteria + ' ...')
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $searcher = $Session.CreateUpdateSearcher()
    $searcher.ServerSelection = 3              # ssOthers: use the ServiceID below
    $searcher.ServiceID = $MicrosoftUpdateServiceId
    $found = $searcher.Search($criteria)
    $entry.ResultCode = [int]$found.ResultCode
    foreach ($u in $found.Updates) {
      $rec = Convert-UpdateToRecord -Update $u
      [void]$updates.Add($rec)
      foreach ($c in $rec.Categories) {
        if ($c.CategoryID -eq $UpgradesCategoryId) {
          $entry.UpgradesCategoryCount = $entry.UpgradesCategoryCount + 1
          break
        }
      }
    }
    $entry.UpdateCount = $updates.Count
    $entry.Succeeded = $true
  } catch {
    $entry.Error = $_.Exception.Message
    Write-Host ('  search failed: ' + $_.Exception.Message) -ForegroundColor Yellow
  } finally {
    $sw.Stop()
    $entry.ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  }
  Write-Host ('  -> ' + $entry.UpdateCount + ' update(s), ' + $entry.UpgradesCategoryCount + ' in the Upgrades category, ' + $entry.ElapsedSeconds + ' s')
  return $entry
}

# --- Main ------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $SpikeDir)) {
  [void](New-Item -ItemType Directory -Path $SpikeDir -Force)
}

$searches = New-Object System.Collections.ArrayList
$result = [ordered]@{
  Spike                       = 'WuaSearch'
  RunAt                       = (Get-NowText)
  UpgradesCategoryIdChecked   = $UpgradesCategoryId
  Machine                     = $null
  WindowsUpdatePolicy         = $null
  MicrosoftUpdateRegistration = $null
  RebootRequired              = $null
  Searches                    = $searches
  Error                       = $null
}
$failed = $false

try {
  $result.Machine = Get-MachineFacts
  $result.WindowsUpdatePolicy = Get-WuPolicyValues

  $session = New-Object -ComObject 'Microsoft.Update.Session'
  $serviceManager = New-Object -ComObject 'Microsoft.Update.ServiceManager'

  # Opt in to Microsoft Update (flags 7 = allow pending + allow online + register with AU).
  $registration = [ordered]@{ Succeeded = $false; ServiceName = $null; Error = $null }
  try {
    $reg = $serviceManager.AddService2($MicrosoftUpdateServiceId, 7, '')
    $registration.Succeeded = $true
    $registration.ServiceName = [string](Get-Safe { $reg.Service.Name })
    Write-Host ('Microsoft Update registered: ' + $registration.ServiceName)
  } catch {
    $registration.Error = $_.Exception.Message
    Write-Host ('AddService2 failed: ' + $_.Exception.Message) -ForegroundColor Yellow
  }
  $result.MicrosoftUpdateRegistration = $registration

  foreach ($browseOnly in @(0, 1)) {
    foreach ($updateType in @('Software', 'Driver')) {
      [void]$searches.Add((Invoke-WuaSearch -Session $session -BrowseOnly $browseOnly -UpdateType $updateType))
    }
  }

  $result.RebootRequired = Get-Safe { [bool](New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired }
} catch {
  $result.Error = $_.Exception.Message
  $failed = $true
  Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
}

Save-Json -Object $result -Path $ResultJsonPath

Write-Host ''
Write-Host 'Nothing was installed or hidden.'
Write-Host ('Result written to: ' + $ResultJsonPath)
if ($failed) { exit 1 }
exit 0
