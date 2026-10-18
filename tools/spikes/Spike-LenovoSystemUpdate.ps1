# tools/spikes/Spike-LenovoSystemUpdate.ps1
# THROWAWAY research tool for spec section 17, spike #4 (Lenovo System Update on consumer models).
#
# Question: does Lenovo System Update (tvsu.exe /CM) cover consumer lines (IdeaPad, Yoga) as well
# as ThinkPads, and what does root\Lenovo Lenovo_Updates look like afterwards? If consumer
# models are not covered, the Lenovo path switches to LSUClient.
#
# What it does: installs Lenovo.SystemUpdate with winget (if missing), sets AdminCommandLine to
# a SEARCH-ONLY command line (-action LIST, so no update is installed), runs tvsu.exe /CM,
# waits until no Tvsukernel/tvsu process is left, then dumps every property of every
# Lenovo_Updates instance. System Update stays installed. The AdminCommandLine value is put
# back (or removed) at the end.
#
# Run elevated on a real LENOVO laptop (an IdeaPad/Yoga, then a ThinkPad), on AC power:
#   powershell -ExecutionPolicy Bypass -File Spike-LenovoSystemUpdate.ps1
# Send back: C:\BenTechSpike\lenovo-result.json
#
# Never prompts. ASCII only. Windows PowerShell 5.1.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SpikeDir = 'C:\BenTechSpike'
$ResultJsonPath = Join-Path $SpikeDir 'lenovo-result.json'
$TvsuPath = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Lenovo\System Update\tvsu.exe'
$RegKey = 'HKLM:\SOFTWARE\Policies\Lenovo\System Update\UserSettings\General'
$RegSubKeyPath = 'SOFTWARE\Policies\Lenovo\System Update\UserSettings\General'
$RegValueName = 'AdminCommandLine'
$AdminCommandLine = '/CM -search A -action LIST -noicon -nolicense -exporttowmi'
$InstallTimeoutMinutes = 20
$RunTimeoutMinutes = 45

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

# Turns a CIM property value into something ConvertTo-Json writes faithfully.
function Convert-ToPlain {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value.ToString('o') }
  if (($Value -is [string]) -or ($Value -is [bool]) -or ($Value -is [decimal]) -or $Value.GetType().IsPrimitive) { return $Value }
  if ($Value -is [array]) {
    $items = New-Object System.Collections.ArrayList
    foreach ($v in $Value) { [void]$items.Add((Convert-ToPlain $v)) }
    return , $items
  }
  return [string]$Value
}

# Reads one registry value in an explicit registry view (Registry64 = native, Registry32 = what a 32-bit
# process such as tvsu.exe sees). Returns $null if the key or value is missing.
function Read-RegistryView {
  param([string]$SubKeyPath, [string]$ValueName, [string]$View)
  $base = $null
  $key = $null
  try {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]$View)
    $key = $base.OpenSubKey($SubKeyPath)
    if ($null -eq $key) { return $null }
    $value = $key.GetValue($ValueName)
    if ($null -eq $value) { return $null }
    return [string]$value
  } catch {
    return ('(error: ' + $_.Exception.Message + ')')
  } finally {
    if ($null -ne $key) { $key.Close() }
    if ($null -ne $base) { $base.Close() }
  }
}

# Every property of every Lenovo_Updates instance.
function Read-LenovoUpdates {
  $rec = [ordered]@{ Error = $null; Count = 0; Instances = $null }
  $list = New-Object System.Collections.ArrayList
  try {
    foreach ($inst in @(Get-CimInstance -Namespace 'root\Lenovo' -ClassName 'Lenovo_Updates' -ErrorAction Stop)) {
      $props = [ordered]@{}
      foreach ($p in $inst.CimInstanceProperties) { $props[$p.Name] = (Convert-ToPlain $p.Value) }
      [void]$list.Add($props)
    }
  } catch {
    $rec.Error = $_.Exception.Message
  }
  $rec.Count = $list.Count
  $rec.Instances = $list
  return $rec
}

function Get-LenovoNamespaceClasses {
  try {
    $names = @(Get-CimClass -Namespace 'root\Lenovo' -ErrorAction Stop | ForEach-Object { $_.CimClassName } | Where-Object { $_ -notlike '__*' })
    return , $names
  } catch {
    return ('(error: ' + $_.Exception.Message + ')')
  }
}

# Tail of the newest System Update log files, so an empty result can be explained.
function Get-LenovoLogTails {
  $out = New-Object System.Collections.ArrayList
  try {
    $dir = Join-Path $env:ProgramData 'Lenovo\SystemUpdate\logs'
    if (Test-Path -LiteralPath $dir) {
      $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
      foreach ($f in $files) {
        $lines = @(Get-Content -LiteralPath $f.FullName -Tail 120 -ErrorAction SilentlyContinue)
        [void]$out.Add([ordered]@{
            Name      = $f.Name
            LastWrite = $f.LastWriteTime.ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            Tail      = ($lines -join "`n")
          })
      }
    }
  } catch {
    [void]$out.Add([ordered]@{ Name = '(error)'; LastWrite = $null; Tail = $_.Exception.Message })
  }
  return , $out
}

# --- Main ------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $SpikeDir)) {
  [void](New-Item -ItemType Directory -Path $SpikeDir -Force)
}

$result = [ordered]@{
  Spike                = 'LenovoSystemUpdate'
  RunAt                = (Get-NowText)
  Model                = $null    # Win32_ComputerSystemProduct.Version, e.g. the marketing name
  Machine              = $null
  Install              = $null
  AdminCommandLine     = [ordered]@{ Value = $AdminCommandLine; Key = $RegKey; Restored = $null; ReadBack = $null }
  Tvsu                 = $null
  LenovoUpdatesBefore  = $null
  LenovoUpdates        = $null
  NamespaceClasses     = $null
  LogTails             = $null
  Error                = $null
}
$failed = $false
$regTouched = $false
$priorValue = $null

try {
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem
  $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $result.Model = [string]$csp.Version
  $result.Machine = [ordered]@{
    ComputerName        = $env:COMPUTERNAME
    Manufacturer        = $cs.Manufacturer
    SystemFamily        = $cs.SystemFamily
    ComputerSystemModel = $cs.Model
    ProductName         = $csp.Name
    ProductVersion      = $csp.Version
    OsCaption           = $os.Caption
    OsVersion           = $os.Version
    OsBuildNumber       = $os.BuildNumber
    OsArchitecture      = $os.OSArchitecture
  }
  Write-Host ('Model: ' + $csp.Version)
  if ([string]$cs.Manufacturer -notmatch 'LENOVO') {
    throw ('This is not a Lenovo machine (manufacturer: ' + $cs.Manufacturer + '). Run this spike on a Lenovo laptop.')
  }

  # 1. Install Lenovo System Update with winget, unless tvsu.exe is already there.
  $install = [ordered]@{ AlreadyPresent = $false; Attempted = $false; ExitCode = $null; ExitCodeHex = $null; TimedOut = $false; OutputTail = $null; ErrorTail = $null }
  $result.Install = $install
  if (Test-Path -LiteralPath $TvsuPath) {
    $install.AlreadyPresent = $true
    Write-Host 'Lenovo System Update is already installed.'
  } else {
    $wingetCmd = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $wingetCmd) { throw 'winget.exe was not found on this machine. Install or repair App Installer, then run the spike again.' }
    $outFile = Join-Path $SpikeDir 'lenovo-install.out.txt'
    $errFile = Join-Path $SpikeDir 'lenovo-install.err.txt'
    Write-Host 'Installing Lenovo.SystemUpdate with winget...'
    $install.Attempted = $true
    $r = Invoke-Proc -FilePath $wingetCmd.Source -ArgumentList 'install --id Lenovo.SystemUpdate -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' -TimeoutMinutes $InstallTimeoutMinutes -StdOutFile $outFile -StdErrFile $errFile
    $install.ExitCode = $r.ExitCode
    $install.ExitCodeHex = Format-ExitHex $r.ExitCode
    $install.TimedOut = $r.TimedOut
    $install.OutputTail = Get-FileTail -Path $outFile
    $install.ErrorTail = Get-FileTail -Path $errFile
    Write-Host ('  -> winget exit code ' + $install.ExitCodeHex)
    if (-not (Test-Path -LiteralPath $TvsuPath)) { throw ('tvsu.exe was not found at ' + $TvsuPath + ' after the install.') }
  }

  $result.LenovoUpdatesBefore = Read-LenovoUpdates

  # 2. Set AdminCommandLine (search only), remembering what was there.
  $priorValue = Read-RegistryView -SubKeyPath $RegSubKeyPath -ValueName $RegValueName -View 'Registry64'
  $regTouched = $true
  if (-not (Test-Path -LiteralPath $RegKey)) { [void](New-Item -Path $RegKey -Force) }
  [void](New-ItemProperty -LiteralPath $RegKey -Name $RegValueName -Value $AdminCommandLine -PropertyType String -Force)
  $result.AdminCommandLine.ReadBack = [ordered]@{
    Native64View = (Read-RegistryView -SubKeyPath $RegSubKeyPath -ValueName $RegValueName -View 'Registry64')
    Wow64View32  = (Read-RegistryView -SubKeyPath $RegSubKeyPath -ValueName $RegValueName -View 'Registry32')
  }

  # 3. Run tvsu.exe /CM and wait until no Tvsukernel/tvsu process remains.
  Write-Host 'Running tvsu.exe /CM (search only). This can take several minutes...'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $run = Invoke-Proc -FilePath $TvsuPath -ArgumentList '/CM' -TimeoutMinutes $RunTimeoutMinutes
  $timedOut = [bool]$run.TimedOut
  Start-Sleep -Seconds 10   # grace period: the kernel process may start just after tvsu.exe returns
  $emptyPolls = 0
  while ($emptyPolls -lt 3) {
    $running = @(Get-Process -Name 'Tvsukernel', 'tvsu' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { $emptyPolls = $emptyPolls + 1 } else { $emptyPolls = 0 }
    if ($sw.Elapsed.TotalMinutes -ge $RunTimeoutMinutes) {
      $timedOut = $true
      $running | Stop-Process -Force -ErrorAction SilentlyContinue
      break
    }
    if ($emptyPolls -lt 3) { Start-Sleep -Seconds 5 }
  }
  $sw.Stop()
  $result.Tvsu = [ordered]@{
    Path           = $TvsuPath
    CommandLine    = '/CM'
    ExitCode       = $run.ExitCode
    ExitCodeHex    = (Format-ExitHex $run.ExitCode)
    TimedOut       = $timedOut
    ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  }
  Write-Host ('  -> tvsu exit code ' + $result.Tvsu.ExitCodeHex + ', finished after ' + $result.Tvsu.ElapsedSeconds + ' s')

  # 4. Dump the WMI result.
  $result.LenovoUpdates = Read-LenovoUpdates
  $result.NamespaceClasses = Get-LenovoNamespaceClasses
  $result.LogTails = Get-LenovoLogTails
  Write-Host ('Lenovo_Updates instances: ' + $result.LenovoUpdates.Count)
} catch {
  $result.Error = $_.Exception.Message
  $failed = $true
  Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
} finally {
  # Put AdminCommandLine back the way it was (or remove it if it was not there).
  if ($regTouched) {
    try {
      if ($null -ne $priorValue) {
        [void](New-ItemProperty -LiteralPath $RegKey -Name $RegValueName -Value $priorValue -PropertyType String -Force)
      } else {
        Remove-ItemProperty -LiteralPath $RegKey -Name $RegValueName -ErrorAction SilentlyContinue
      }
      $result.AdminCommandLine.Restored = $true
    } catch {
      $result.AdminCommandLine.Restored = $false
      Write-Host ('WARNING: could not restore AdminCommandLine: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
  }
}

Save-Json -Object $result -Path $ResultJsonPath

Write-Host ''
Write-Host ('Result written to: ' + $ResultJsonPath)
if ($failed) { exit 1 }
exit 0
