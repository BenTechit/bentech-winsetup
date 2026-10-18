# tools/spikes/Spike-StoreInstall.ps1
# THROWAWAY research tool for spec section 17, spike #3 (Store apps without a Microsoft account).
#
# Question: on a fresh LOCAL-account machine, can "winget install --source msstore" install
# Dell SupportAssist, Lenovo Vantage and MyASUS with no Microsoft account sign-in?
#
# It installs the three apps (they stay installed) and records each winget exit code as hex,
# plus whether a Microsoft account is signed in. Only the COUNT of stored identities is
# recorded, never their names (those are e-mail addresses).
#
# Run elevated on a fresh local-account TEST VM:
#   powershell -ExecutionPolicy Bypass -File Spike-StoreInstall.ps1
# Send back: C:\BenTechSpike\store-result.json
#
# Never prompts (winget runs with --disable-interactivity). ASCII only. Windows PowerShell 5.1.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SpikeDir = 'C:\BenTechSpike'
$ResultJsonPath = Join-Path $SpikeDir 'store-result.json'
$PerAppTimeoutMinutes = 20
$Apps = @(
  [pscustomobject]@{ Id = 'XPDCCXDN26VNBT'; Name = 'Dell SupportAssist' },
  [pscustomobject]@{ Id = '9WZDNCRFJ4MV'; Name = 'Lenovo Vantage' },
  [pscustomobject]@{ Id = '9N7R5S6B0ZZH'; Name = 'MyASUS' }
)

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

function Get-MachineFacts {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem
  $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  return [ordered]@{
    ComputerName   = $env:COMPUTERNAME
    Manufacturer   = $cs.Manufacturer
    Model          = $cs.Model
    Caption        = $os.Caption
    EditionId      = $cv.EditionID
    Version        = $os.Version
    BuildNumber    = $os.BuildNumber
    Ubr            = $cv.UBR
    DisplayVersion = $cv.DisplayVersion
  }
}

function Invoke-Proc {
  param(
    [string]$FilePath,
    [string]$ArgumentList = '',
    [int]$TimeoutMinutes = 15,
    [string]$StdOutFile = '',
    [string]$StdErrFile = ''
  )
  $startArgs = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
  if ($ArgumentList) { $startArgs.ArgumentList = $ArgumentList }
  if ($StdOutFile) { $startArgs.RedirectStandardOutput = $StdOutFile }
  if ($StdErrFile) { $startArgs.RedirectStandardError = $StdErrFile }
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

# Last part of a text file, for a human to read. It is never parsed.
function Get-FileTail {
  param([string]$Path, [int]$MaxChars = 2500)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path) -replace "`r", "`n"
    $text = ($text -replace "`n{2,}", "`n").Trim()
    if ($text.Length -gt $MaxChars) { $text = $text.Substring($text.Length - $MaxChars) }
    return $text
  } catch {
    return ('(could not read ' + $Path + ': ' + $_.Exception.Message + ')')
  }
}

function Format-ExitHex {
  param($Code)
  if ($null -eq $Code) { return $null }
  return ('0x{0:X8}' -f [int]$Code)
}

# --- Main ------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $SpikeDir)) {
  [void](New-Item -ItemType Directory -Path $SpikeDir -Force)
}

$results = New-Object System.Collections.ArrayList
$result = [ordered]@{
  Spike            = 'StoreInstall'
  RunAt            = (Get-NowText)
  Machine          = $null
  Winget           = $null
  MicrosoftAccount = $null
  Results          = $results
  Error            = $null
}
$failed = $false

try {
  $result.Machine = Get-MachineFacts

  # Is a Microsoft account signed in? Count the stored identities, never record their names.
  $identityKey = 'HKCU:\Software\Microsoft\IdentityCRL\StoredIdentities'
  $identityCount = 0
  if (Test-Path -LiteralPath $identityKey) {
    $identityCount = @(Get-ChildItem -LiteralPath $identityKey -ErrorAction SilentlyContinue).Count
  }
  $result.MicrosoftAccount = [ordered]@{
    StoredIdentityCount = $identityCount
    SignedIn            = ($identityCount -gt 0)
  }
  Write-Host ('Microsoft account signed in: ' + ($identityCount -gt 0))

  $wingetCmd = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $wingetCmd) {
    $result.Winget = [ordered]@{ Found = $false; Path = $null; Version = $null }
    throw 'winget.exe was not found on this machine. Install or repair App Installer, then run the spike again.'
  }
  $wingetPath = $wingetCmd.Source
  $wingetVersion = $null
  try { $wingetVersion = (& $wingetPath --version 2>&1 | Out-String).Trim() } catch { }
  $result.Winget = [ordered]@{ Found = $true; Path = $wingetPath; Version = $wingetVersion }

  foreach ($app in $Apps) {
    $argText = 'install --id ' + $app.Id + ' -e --source msstore --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    $outFile = Join-Path $SpikeDir ('store-' + $app.Id + '.out.txt')
    $errFile = Join-Path $SpikeDir ('store-' + $app.Id + '.err.txt')
    Write-Host ('Installing ' + $app.Name + ' (' + $app.Id + ') from the Store, this can take several minutes...')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Proc -FilePath $wingetPath -ArgumentList $argText -TimeoutMinutes $PerAppTimeoutMinutes -StdOutFile $outFile -StdErrFile $errFile
    $sw.Stop()
    $hex = Format-ExitHex $r.ExitCode
    [void]$results.Add([ordered]@{
        Id             = $app.Id
        Name           = $app.Name
        Command        = ('winget ' + $argText)
        ExitCode       = $r.ExitCode
        ExitCodeHex    = $hex
        TimedOut       = $r.TimedOut
        ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        OutputTail     = (Get-FileTail -Path $outFile)
        ErrorTail      = (Get-FileTail -Path $errFile)
      })
    if ($r.TimedOut) {
      Write-Host ('  -> timed out after ' + $PerAppTimeoutMinutes + ' minutes') -ForegroundColor Yellow
    } else {
      Write-Host ('  -> exit code ' + $hex)
    }
  }
} catch {
  $result.Error = $_.Exception.Message
  $failed = $true
  Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
}

Save-Json -Object $result -Path $ResultJsonPath

Write-Host ''
Write-Host ('Result written to: ' + $ResultJsonPath)
if ($failed) { exit 1 }
exit 0
