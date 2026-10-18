# tools/spikes/Spike-DefaultBrowser.ps1
# THROWAWAY research tool for spec section 17, spike #1 (default-browser policy).
#
# Question: on a workgroup Windows 11 Pro / Home / Windows 10 Pro machine, does the
# DefaultAssociationsConfiguration policy with Suggested="true" make Chrome the default
# browser at the next sign-in?
#
# Run it elevated, in two phases, on a TEST VM (it installs Chrome and changes a policy):
#   1. powershell -ExecutionPolicy Bypass -File Spike-DefaultBrowser.ps1 -Phase Apply
#   2. reboot, sign in with the same account
#   3. powershell -ExecutionPolicy Bypass -File Spike-DefaultBrowser.ps1 -Phase Check
# Send back: C:\BenTechSpike\default-browser-result.json
#
# Never prompts: no Read-Host, no confirmations. ASCII only. Windows PowerShell 5.1.

[CmdletBinding()]
param(
  [ValidateSet('Apply', 'Check')]
  [string]$Phase
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SpikeDir = 'C:\BenTechSpike'
$AssocXmlPath = Join-Path $SpikeDir 'assoc.xml'
$ApplyJsonPath = Join-Path $SpikeDir 'default-browser-apply.json'
$ResultJsonPath = Join-Path $SpikeDir 'default-browser-result.json'
$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$PolicyValueName = 'DefaultAssociationsConfiguration'
$ChromeMsiUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'

# --- Elevation check -------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'ERROR: this spike must run elevated. Open PowerShell with "Run as administrator" and run it again.' -ForegroundColor Red
  exit 1
}
if (-not $Phase) {
  Write-Host 'ERROR: missing -Phase. Use -Phase Apply first, then reboot, sign in, then -Phase Check.' -ForegroundColor Red
  exit 1
}

# --- Helpers ---------------------------------------------------------------------------------
function Save-Json {
  param($Object, [string]$Path)
  $json = $Object | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function Invoke-Proc {
  param([string]$FilePath, [string]$ArgumentList = '', [int]$TimeoutMinutes = 15)
  $startArgs = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
  if ($ArgumentList) { $startArgs.ArgumentList = $ArgumentList }
  $p = Start-Process @startArgs
  $null = $p.Handle   # cache the handle so ExitCode is readable after exit
  $timedOut = $false
  if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
    $timedOut = $true
    try { $p.Kill() } catch { }
  } else {
    $p.WaitForExit()
  }
  $code = $null
  if (-not $timedOut) { $code = $p.ExitCode }
  [pscustomobject]@{ ExitCode = $code; TimedOut = $timedOut }
}

function Get-ChromePath {
  $candidates = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe")
  $x86 = [Environment]::GetFolderPath('ProgramFilesX86')
  if ($x86) { $candidates += (Join-Path $x86 'Google\Chrome\Application\chrome.exe') }
  foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) { return $c }
  }
  return $null
}

function Read-RegValue {
  param([string]$Path, [string]$Name)
  try {
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    $value = $item.$Name
    if ($null -eq $value) { return $null }
    return [string]$value
  } catch {
    return $null
  }
}

function Get-FirstNonEmpty {
  param([string[]]$Values)
  foreach ($v in $Values) {
    if (-not [string]::IsNullOrEmpty($v)) { return $v }
  }
  return $null
}

# Reads the three places a default-browser ProgId can live, for https and http, plus .htm/.html.
function Read-Associations {
  $out = [ordered]@{}
  foreach ($proto in @('https', 'http')) {
    $base = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\' + $proto
    $latestSubkey = Read-RegValue -Path ($base + '\UserChoiceLatest\ProgId') -Name 'ProgId'
    $latestKey = Read-RegValue -Path ($base + '\UserChoiceLatest') -Name 'ProgId'
    $legacy = Read-RegValue -Path ($base + '\UserChoice') -Name 'ProgId'
    $out[$proto] = [ordered]@{
      UserChoiceLatestProgIdSubkey = $latestSubkey   # ...\UserChoiceLatest\ProgId, value ProgId
      UserChoiceLatest             = $latestKey      # ...\UserChoiceLatest, value ProgId
      UserChoice                   = $legacy         # ...\UserChoice, value ProgId
      Resolved                     = (Get-FirstNonEmpty @($latestSubkey, $latestKey, $legacy))
    }
  }
  foreach ($ext in @('.htm', '.html')) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $ext + '\UserChoice'
    $out[$ext] = [ordered]@{ UserChoice = (Read-RegValue -Path $key -Name 'ProgId') }
  }
  return $out
}

function Get-OsFacts {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem
  $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  return [ordered]@{
    ComputerName       = $env:COMPUTERNAME
    Manufacturer       = $cs.Manufacturer
    Model              = $cs.Model
    PartOfDomain       = [bool]$cs.PartOfDomain
    Caption            = $os.Caption
    EditionId          = $cv.EditionID
    OperatingSystemSku = $os.OperatingSystemSKU
    Version            = $os.Version
    BuildNumber        = $os.BuildNumber
    Ubr                = $cv.UBR
    DisplayVersion     = $cv.DisplayVersion
    LastBootUpTime     = $os.LastBootUpTime.ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
  }
}

function Get-NowText {
  return (Get-Date).ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

# Literal copy of the XML that Task 12's New-DefaultAssociationsXml produces.
$AssocXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier=".htm" ProgId="ChromeHTML" ApplicationName="Google Chrome" Version="1" Suggested="true" />
  <Association Identifier=".html" ProgId="ChromeHTML" ApplicationName="Google Chrome" Version="1" Suggested="true" />
  <Association Identifier="http" ProgId="ChromeHTML" ApplicationName="Google Chrome" Version="1" Suggested="true" />
  <Association Identifier="https" ProgId="ChromeHTML" ApplicationName="Google Chrome" Version="1" Suggested="true" />
</DefaultAssociations>
'@

if (-not (Test-Path -LiteralPath $SpikeDir)) {
  [void](New-Item -ItemType Directory -Path $SpikeDir -Force)
}

# --- Phase: Apply ----------------------------------------------------------------------------
if ($Phase -eq 'Apply') {
  try {
    $baseline = Read-Associations
    $chromePath = Get-ChromePath
    $chromeInstalledBySpike = $false
    $msiExit = $null

    if (-not $chromePath) {
      Write-Host 'Chrome is not installed. Downloading the enterprise MSI...'
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $msi = Join-Path $SpikeDir 'chrome.msi'
      $wc = New-Object System.Net.WebClient
      try { $wc.DownloadFile($ChromeMsiUrl, $msi) } finally { $wc.Dispose() }
      Write-Host 'Installing Chrome silently...'
      $r = Invoke-Proc -FilePath 'msiexec.exe' -ArgumentList ('/i "' + $msi + '" /qn /norestart') -TimeoutMinutes 15
      $msiExit = $r.ExitCode
      if ($r.TimedOut) { throw 'Chrome MSI install timed out after 15 minutes.' }
      if (($msiExit -ne 0) -and ($msiExit -ne 3010) -and ($msiExit -ne 1641)) {
        throw ('Chrome MSI install failed with exit code ' + $msiExit + '.')
      }
      $chromePath = Get-ChromePath
      if (-not $chromePath) { throw 'The Chrome MSI finished but chrome.exe was not found.' }
      $chromeInstalledBySpike = $true
    }

    [IO.File]::WriteAllText($AssocXmlPath, $AssocXml, (New-Object Text.UTF8Encoding $false))

    if (-not (Test-Path -LiteralPath $PolicyKey)) { [void](New-Item -Path $PolicyKey -Force) }
    [void](New-ItemProperty -LiteralPath $PolicyKey -Name $PolicyValueName -Value $AssocXmlPath -PropertyType String -Force)
    $policyReadBack = Read-RegValue -Path $PolicyKey -Name $PolicyValueName

    $applyRecord = [ordered]@{
      Spike                  = 'DefaultBrowser'
      Phase                  = 'Apply'
      RunAt                  = (Get-NowText)
      AppliedAtUtc           = (Get-Date).ToUniversalTime().ToString('o')
      Machine                = (Get-OsFacts)
      ChromePath             = $chromePath
      ChromeVersion          = (Get-Item -LiteralPath $chromePath).VersionInfo.ProductVersion
      ChromeInstalledBySpike = $chromeInstalledBySpike
      ChromeMsiExitCode      = $msiExit
      AssocXmlPath           = $AssocXmlPath
      PolicyKey              = $PolicyKey
      PolicyValueName        = $PolicyValueName
      PolicyValueReadBack    = $policyReadBack
      BaselineAssociations   = $baseline
    }
    Save-Json -Object $applyRecord -Path $ApplyJsonPath

    Write-Host ''
    Write-Host ('Policy value set: ' + $PolicyKey + '\' + $PolicyValueName + ' = ' + $policyReadBack)
    Write-Host ('Apply record written to: ' + $ApplyJsonPath)
    Write-Host 'Reboot, sign in, then run -Phase Check' -ForegroundColor Green
    Write-Host ('Example: powershell -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '" -Phase Check')
    exit 0
  } catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
  }
}

# --- Phase: Check ----------------------------------------------------------------------------
$result = [ordered]@{
  Spike                = 'DefaultBrowser'
  Phase                = 'Check'
  RunAt                = (Get-NowText)
  Machine              = $null
  RebootedSinceApply   = $null
  Chrome               = $null
  Associations         = $null
  ChromeIsDefaultHttps = $null
  ChromeIsDefaultHttp  = $null
  PolicyValueFoundAtCheck = $null
  PolicyValueRemoved   = $null
  Apply                = $null
  Error                = $null
}
$failed = $false
try {
  $result.Machine = Get-OsFacts

  if (Test-Path -LiteralPath $ApplyJsonPath) {
    $apply = Get-Content -LiteralPath $ApplyJsonPath -Raw | ConvertFrom-Json
    $result.Apply = $apply
    $appliedAt = [datetime]::Parse([string]$apply.AppliedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    $bootAt = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $result.RebootedSinceApply = ($bootAt -gt $appliedAt)
  } else {
    Write-Host 'WARNING: no apply record found. Was -Phase Apply run on this machine?' -ForegroundColor Yellow
  }

  $chromePath = Get-ChromePath
  $result.Chrome = [ordered]@{
    Installed = [bool]$chromePath
    Path      = $chromePath
    Version   = $(if ($chromePath) { (Get-Item -LiteralPath $chromePath).VersionInfo.ProductVersion } else { $null })
  }

  $assoc = Read-Associations
  $result.Associations = $assoc
  $result.ChromeIsDefaultHttps = ($assoc['https'].Resolved -eq 'ChromeHTML')
  $result.ChromeIsDefaultHttp = ($assoc['http'].Resolved -eq 'ChromeHTML')

  # Remove the policy so the customer could change browsers later (this is what the real step does).
  $policyBefore = Read-RegValue -Path $PolicyKey -Name $PolicyValueName
  $result.PolicyValueFoundAtCheck = $policyBefore
  if ($null -ne $policyBefore) {
    Remove-ItemProperty -LiteralPath $PolicyKey -Name $PolicyValueName -ErrorAction Stop
  }
  $result.PolicyValueRemoved = ($null -eq (Read-RegValue -Path $PolicyKey -Name $PolicyValueName))
} catch {
  $result.Error = $_.Exception.Message
  $failed = $true
  Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
}

Save-Json -Object $result -Path $ResultJsonPath

Write-Host ''
if ($result.Associations) {
  Write-Host ('https default ProgId: ' + $result.Associations['https'].Resolved)
  Write-Host ('http  default ProgId: ' + $result.Associations['http'].Resolved)
  if ($result.ChromeIsDefaultHttps) {
    Write-Host 'Chrome IS the default browser.' -ForegroundColor Green
  } else {
    Write-Host 'Chrome is NOT the default browser.' -ForegroundColor Yellow
  }
}
Write-Host ('Result written to: ' + $ResultJsonPath)
if ($failed) { exit 1 }
exit 0
