# tools/spikes/Spike-DriverListCapture.ps1
# THROWAWAY research tool for v2 (progress visibility), Task 1: Spike 5.
#
# Question: what do the Dell and HP update tools LIST on a real laptop, and what do their logs look
# like? The answer decides how the setup tool will read per-update status for Dell and HP (a later
# plan). This is the one spike made for customer laptops that came in for setup: it is LIST-ONLY.
#
# What it does, on a Dell:   runs dcu-cli.exe /scan (Dell Command Update), which writes a report of
#                            the applicable updates, then copies the newest Dell update logs.
# What it does, on an HP:    downloads HP Image Assistant (a portable tool, extracted under %TEMP%),
#                            runs it with /Action:List, then copies its logs. Nothing is deleted, so
#                            %TEMP%\BenTechCapture stays behind: delete it by hand afterwards.
# On any other brand:        says so and stops.
# Always (read-only):        an inventory of the brand's services, Start-menu shortcuts and Store
#                            packages. With -InventoryOnly that is ALL it does (use that for the
#                            second run, after the setup tool has run, when the vendor tool may be gone).
#
# What it never does: apply or download an update, change a setting, write the registry, touch BIOS or
# firmware, or restart the PC. Every tool run is bounded by -TimeoutMinutes and killed on timeout. On
# battery it still runs (the list is the same). The only thing it can install is the Dell tool itself,
# and only when you pass -InstallTool.
#
# Run elevated, on AC power and online, BEFORE the setup tool has run on that laptop:
#   powershell -ExecutionPolicy Bypass -File E:\spikes\Spike-DriverListCapture.ps1
#   (on a Dell without Dell Command Update add -InstallTool; it does nothing on an HP)
# Send back: the whole capture-<BRAND>-<serial>-<date> folder next to this script (or under -OutRoot).
#
# Never prompts. ASCII only. Windows PowerShell 5.1.

[CmdletBinding()]
param(
  [string]$OutRoot,
  [switch]$InstallTool,
  [switch]$InventoryOnly,
  [ValidateRange(1, 240)][int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Elevation check -------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'ERROR: this capture must run elevated. Open PowerShell with "Run as administrator" and run it again.' -ForegroundColor Red
  exit 1
}

# --- Settings (the vendor values are copied from config\config.json) -------------------------
$DcuCandidates = @(
  'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
  'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
)
$HpiaPage = 'https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html'
$HpiaLinkPattern = 'https://hpia\.hpcloud\.hp\.com/downloads/hpia/hp-hpia-[0-9.]+\.exe'
$HpWorkDir = Join-Path $env:TEMP 'BenTechCapture'
$MaxLogBytes = 5MB
$NewestLogCount = 10

# $PSScriptRoot is not used in param(): it is empty there in a [CmdletBinding()] script on 5.1.
$scriptPath = $PSCommandPath
if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrEmpty($OutRoot)) {
  if ([string]::IsNullOrEmpty($scriptPath)) { $OutRoot = (Get-Location).Path } else { $OutRoot = Split-Path -Parent $scriptPath }
}
# .NET file APIs use the process working directory, not the PowerShell location.
$OutRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutRoot)

# Filled while the script runs; the lists are written to capture.json even after a failure.
$errors = New-Object System.Collections.ArrayList     # a step could not finish: the script exits 1
$notes = New-Object System.Collections.ArrayList      # worth knowing, not fatal
$copied = New-Object System.Collections.ArrayList     # log files copied into logs\

# --- Helpers ---------------------------------------------------------------------------------
function Save-Json {
  param($Object, [string]$Path)
  $json = $Object | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-NowText {
  return (Get-Date).ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function Add-CaptureError {
  param([string]$Message)
  [void]$errors.Add($Message)
  Write-Host ('ERROR: ' + $Message) -ForegroundColor Red
}

function Add-CaptureNote {
  param([string]$Message)
  [void]$notes.Add($Message)
  Write-Host ('Note: ' + $Message) -ForegroundColor Yellow
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
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process @startArgs
  $null = $p.Handle   # cache the handle so ExitCode is readable after exit
  $timedOut = $false
  if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
    $timedOut = $true
    try { $p.Kill() } catch { }
  } else {
    $p.WaitForExit()
  }
  $sw.Stop()
  $code = $null
  if (-not $timedOut) { $code = $p.ExitCode }
  [pscustomobject]@{ ExitCode = $code; TimedOut = $timedOut; ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
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

# The capture.json record of one child process run.
function New-RunRecord {
  param([string]$CommandLine, $Result)
  return [ordered]@{
    CommandLine    = $CommandLine
    ExitCode       = $Result.ExitCode
    ExitCodeHex    = (Format-ExitHex $Result.ExitCode)
    TimedOut       = [bool]$Result.TimedOut
    ElapsedSeconds = $Result.ElapsedSeconds
  }
}

function Get-SignatureInfo {
  param([string]$Path)
  $info = [ordered]@{ Status = $null; Subject = $null }
  try {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $info.Status = [string]$sig.Status
    if ($sig.SignerCertificate) { $info.Subject = [string]$sig.SignerCertificate.Subject }
  } catch {
    $info.Status = 'Error: ' + $_.Exception.Message
  }
  return $info
}

function Get-FileVersionText {
  param([string]$Path)
  try { return [string](Get-Item -LiteralPath $Path).VersionInfo.FileVersion } catch { return $null }
}

function Find-FirstExisting {
  param([string[]]$Candidates)
  foreach ($c in $Candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
  return $null
}

# winget.exe from the App Installer package folder, never through PATH: in an elevated session PATH also
# reaches the per-user WindowsApps alias folder, which the user can write to (final review M6). The folder
# pattern is the setup tool's (Get-WingetPath, its package-folder step): the newest
# Microsoft.DesktopAppInstaller_<version>_(x64|arm64)__8wekyb3d8bbwe directly under %ProgramFiles%\WindowsApps
# that holds a winget.exe. When WindowsApps cannot be listed, the same folders come from Get-AppxPackage
# -AllUsers (read-only). $null when there is none.
function Get-WingetPackagePath {
  $pattern = '^Microsoft\.DesktopAppInstaller_(?<v>\d+(?:\.\d+){1,3})_(?:x64|arm64)__8wekyb3d8bbwe$'
  $apps = (Join-Path $env:ProgramFiles 'WindowsApps').TrimEnd('\')
  $folders = @()
  try {
    $folders = @(Get-ChildItem -LiteralPath $apps -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction Stop | ForEach-Object { $_.FullName })
  } catch {
    $folders = @()
  }
  if ($folders.Count -eq 0) {
    try {
      $folders = @(Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop | ForEach-Object { [string]$_.InstallLocation } | Where-Object { $_ })
    } catch {
      $folders = @()
    }
  }
  $best = $null
  $bestVersion = $null
  foreach ($folder in $folders) {
    $parent = [string](Split-Path -Parent $folder)
    if (-not [string]::Equals($parent.TrimEnd('\'), $apps, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $m = [regex]::Match((Split-Path -Leaf $folder), $pattern)
    $version = $null
    if (-not $m.Success -or -not [version]::TryParse($m.Groups['v'].Value, [ref]$version)) { continue }
    $exe = Join-Path $folder 'winget.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
    if ($null -eq $bestVersion -or $version -gt $bestVersion) {
      $best = $exe
      $bestVersion = $version
    }
  }
  return $best
}

# $true on AC power or when there is no battery at all, $false on battery, $null when it cannot be read.
function Get-OnAcPower {
  try {
    $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
    if ($batteries.Count -eq 0) { return $true }
    foreach ($b in $batteries) {
      $status = [int]$b.BatteryStatus   # 1 discharging, 4 low, 5 critical: running on the battery
      if ($status -eq 1 -or $status -eq 4 -or $status -eq 5) { return $false }
    }
    return $true
  } catch {
    return $null
  }
}

function Get-MachineRecord {
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
  $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
  $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
  $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
  $board = $null
  try { $board = [string](Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1).Product } catch { }
  return [ordered]@{
    Manufacturer  = ([string]$cs.Manufacturer).Trim()
    Model         = ([string]$cs.Model).Trim()
    Product       = ([string]$csp.Name).Trim()
    SystemSku     = ([string]$cs.SystemSKUNumber).Trim()
    BaseBoard     = $board
    Serial        = ([string]$bios.SerialNumber).Trim()
    OsCaption     = $os.Caption
    OsVersion     = $os.Version
    OsBuildNumber = $os.BuildNumber
    OnAc          = (Get-OnAcPower)
  }
}

# --- Downloads (WebClient + TLS 1.2, never Invoke-WebRequest; bounded by a deadline) ---------
function New-CaptureWebClient {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $client = New-Object Net.WebClient
  $client.Headers.Add('User-Agent', 'BenTechSetup/1.0')
  return $client
}

function Wait-WebTask {
  param($Task, $Client, [int]$Minutes, [string]$What)
  $done = $false
  try {
    $done = $Task.Wait($Minutes * 60 * 1000)
  } catch {
    $inner = $_.Exception
    while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
    throw ($What + ' failed: ' + $inner.Message)
  }
  if (-not $done) {
    try { $Client.CancelAsync() } catch { }
    throw ($What + ' did not finish within ' + $Minutes + ' minutes.')
  }
}

function Get-WebText {
  param([string]$Url, [int]$Minutes)
  $client = New-CaptureWebClient
  try {
    $task = $client.DownloadStringTaskAsync($Url)
    Wait-WebTask -Task $task -Client $client -Minutes $Minutes -What ('Reading ' + $Url)
    return [string]$task.Result
  } finally {
    $client.Dispose()
  }
}

function Save-WebFile {
  param([string]$Url, [string]$Path, [int]$Minutes)
  $client = New-CaptureWebClient
  try {
    $task = $client.DownloadFileTaskAsync($Url, $Path)
    Wait-WebTask -Task $task -Client $client -Minutes $Minutes -What ('Downloading ' + $Url)
  } catch {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    throw
  } finally {
    $client.Dispose()
  }
}

# --- Copying logs ----------------------------------------------------------------------------
# Opens the source with read sharing so a log that a service still writes can be copied. Returns
# nothing; a file that cannot be copied becomes a note.
function Copy-LogFile {
  param([string]$Source, [string]$DestDir, [string]$DestName)
  $dest = Join-Path $DestDir $DestName
  $n = 2
  while (Test-Path -LiteralPath $dest) {
    $dest = Join-Path $DestDir ([IO.Path]::GetFileNameWithoutExtension($DestName) + '-' + $n + [IO.Path]::GetExtension($DestName))
    $n = $n + 1
  }
  $in = $null
  $out = $null
  try {
    $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $out = [IO.File]::Open($dest, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $in.CopyTo($out)
  } catch {
    Add-CaptureNote ('Could not copy ' + $Source + ': ' + $_.Exception.Message)
    return
  } finally {
    if ($null -ne $out) { $out.Dispose() }
    if ($null -ne $in) { $in.Dispose() }
  }
  # PowerShell variable names are case-insensitive: $Source (the path) must not be reused below.
  $srcItem = Get-Item -LiteralPath $Source
  $dstItem = Get-Item -LiteralPath $dest
  try { $dstItem.LastWriteTime = $srcItem.LastWriteTime } catch { }
  [void]$copied.Add([ordered]@{
      Source        = $Source
      Destination   = ('logs\' + $dstItem.Name)
      Bytes         = $dstItem.Length
      LastWriteTime = $srcItem.LastWriteTime.ToString('o')
    })
}

# The newest $Count *.log files of one folder, each at most $MaxBytes. A folder that is not there is
# normal (the tool may never have run) and is skipped quietly.
function Copy-NewestLogs {
  param([string]$SourceDir, [string]$Prefix, [string]$DestDir)
  if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { return }
  try {
    $files = @(Get-ChildItem -LiteralPath $SourceDir -Filter '*.log' -File | Sort-Object LastWriteTime -Descending)
    foreach ($f in $files) {
      if ($f.Length -gt $MaxLogBytes) { Add-CaptureNote ('Skipped ' + $f.FullName + ' (over 5 MB).') }
    }
    $small = @($files | Where-Object { $_.Length -le $MaxLogBytes } | Select-Object -First $NewestLogCount)
    foreach ($f in $small) { Copy-LogFile -Source $f.FullName -DestDir $DestDir -DestName ($Prefix + '-' + $f.Name) }
  } catch {
    Add-CaptureNote ('Could not read the logs in ' + $SourceDir + ': ' + $_.Exception.Message)
  }
}

# --- Dell ------------------------------------------------------------------------------------
# Reads the script's own -InstallTool switch on purpose: the tool is installed only inside if ($InstallTool).
function Invoke-DellCapture {
  param($Capture, [string]$ReportDir, [string]$LogDir)
  $tool = [ordered]@{ Kind = 'dcu'; Path = $null; FileVersion = $null; SignatureStatus = $null; SignerSubject = $null; Install = $null }
  $Capture.Tool = $tool

  $dcu = Find-FirstExisting -Candidates $DcuCandidates
  if (-not $dcu) {
    if ($InstallTool) {
      $winget = Get-WingetPackagePath
      if (-not $winget) { throw 'winget.exe was not found in the App Installer package on this PC, so Dell Command Update cannot be installed. Install or repair App Installer, then run this again.' }
      $outFile = Join-Path $LogDir 'winget-install.out.txt'
      $errFile = Join-Path $LogDir 'winget-install.err.txt'
      Write-Host 'Installing Dell Command Update with winget (this can take several minutes)...'
      $wingetArgs = 'install --id Dell.CommandUpdate.Universal -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
      $r = Invoke-Proc -FilePath $winget -ArgumentList $wingetArgs -TimeoutMinutes $TimeoutMinutes -StdOutFile $outFile -StdErrFile $errFile
      $record = New-RunRecord -CommandLine ('"' + $winget + '" ' + $wingetArgs) -Result $r
      $record.OutputTail = Get-FileTail -Path $outFile
      $record.ErrorTail = Get-FileTail -Path $errFile
      $tool.Install = $record
      Write-Host ('  -> winget exit code ' + $record.ExitCodeHex)
      if ($r.TimedOut) { throw ('The winget install did not finish within ' + $TimeoutMinutes + ' minutes and was stopped.') }
      $dcu = Find-FirstExisting -Candidates $DcuCandidates
      if (-not $dcu) { throw 'dcu-cli.exe was not found after the winget install.' }
    } else {
      $rerun = 'powershell -ExecutionPolicy Bypass -File "' + $scriptPath + '" -InstallTool'
      throw ('Dell Command Update (dcu-cli.exe) is not installed on this Dell. To let this script install it with winget, run it again with -InstallTool: ' + $rerun)
    }
  }

  $sig = Get-SignatureInfo -Path $dcu
  $tool.Path = $dcu
  $tool.FileVersion = Get-FileVersionText -Path $dcu
  $tool.SignatureStatus = $sig.Status
  $tool.SignerSubject = $sig.Subject
  if ($sig.Status -ne 'Valid' -or [string]$sig.Subject -notmatch 'Dell') {
    throw ('dcu-cli.exe was not run: its Authenticode signature is "' + $sig.Status + '" with signer "' + $sig.Subject + '" (it must be Valid and signed by Dell).')
  }

  $scanLog = Join-Path $LogDir 'dcu-scan.log'
  $scanArgs = '/scan -report="' + $ReportDir + '" -outputLog="' + $scanLog + '"'
  Write-Host ('Running dcu-cli /scan (list only, up to ' + $TimeoutMinutes + ' minutes)...')
  $r = Invoke-Proc -FilePath $dcu -ArgumentList $scanArgs -TimeoutMinutes $TimeoutMinutes -StdOutFile (Join-Path $LogDir 'dcu-scan.out.txt') -StdErrFile (Join-Path $LogDir 'dcu-scan.err.txt')
  $Capture.Run = New-RunRecord -CommandLine ('"' + $dcu + '" ' + $scanArgs) -Result $r
  Write-Host ('  -> dcu-cli exit code ' + $Capture.Run.ExitCodeHex + ', ' + $Capture.Run.ElapsedSeconds + ' s')

  Copy-NewestLogs -SourceDir (Join-Path $env:ProgramData 'Dell\UpdateService\Log') -Prefix 'UpdateService' -DestDir $LogDir
  Copy-NewestLogs -SourceDir (Join-Path $env:ProgramData 'Dell\CommandUpdate') -Prefix 'CommandUpdate' -DestDir $LogDir

  if ($r.TimedOut) { throw ('dcu-cli did not finish within ' + $TimeoutMinutes + ' minutes and was stopped.') }
}

# --- HP --------------------------------------------------------------------------------------
function Invoke-HpCapture {
  param($Capture, [string]$ReportDir, [string]$LogDir)
  $tool = [ordered]@{ Kind = 'hpia'; Path = $null; FileVersion = $null; SignatureStatus = $null; SignerSubject = $null; Source = $null; Installer = $null; Extract = $null }
  $Capture.Tool = $tool

  # The newest download link, read from HP's page (the first match of the pattern).
  Write-Host 'Reading the HP Image Assistant download page...'
  $page = Get-WebText -Url $HpiaPage -Minutes $TimeoutMinutes
  $match = [regex]::Match($page, $HpiaLinkPattern)
  if (-not $match.Success) { throw ('No HP Image Assistant download link was found on ' + $HpiaPage + '.') }
  $url = $match.Value
  $tool.Source = $url

  if (-not (Test-Path -LiteralPath $HpWorkDir)) { [void](New-Item -ItemType Directory -Path $HpWorkDir -Force) }
  $installer = Join-Path $HpWorkDir 'hp-hpia.exe'

  # Every run extracts into its own fresh folder, so nothing is ever deleted (this runs elevated, and a
  # recursive delete in a user-writable folder could follow a planted junction) and every log copied
  # later belongs to this run. The folders are left behind in %TEMP%\BenTechCapture.
  $extractStamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
  $extractDir = Join-Path $HpWorkDir ('HPIA-' + $extractStamp)
  $n = 2
  while (Test-Path -LiteralPath $extractDir) {
    $extractDir = Join-Path $HpWorkDir ('HPIA-' + $extractStamp + '-' + $n)
    $n = $n + 1
  }
  $extractArgs = '/s /e /f "' + $extractDir + '"'

  Write-Host ('Downloading ' + $url + ' ...')
  Save-WebFile -Url $url -Path $installer -Minutes $TimeoutMinutes
  $installerBytes = (Get-Item -LiteralPath $installer).Length

  # The signature check and the launch are back to back on purpose: nothing happens in between, which
  # keeps the window for swapping the file as short as it can be.
  Write-Host 'Checking the signature and extracting HP Image Assistant...'
  $sig = Get-SignatureInfo -Path $installer
  if ($sig.Status -ne 'Valid' -or [string]$sig.Subject -notmatch 'HP Inc') {
    $tool.Installer = [ordered]@{ Path = $installer; Bytes = $installerBytes; SignatureStatus = $sig.Status; SignerSubject = $sig.Subject }
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    throw ('The downloaded HP Image Assistant was deleted unused: its Authenticode signature is "' + $sig.Status + '" with signer "' + $sig.Subject + '" (it must be Valid and signed by HP Inc).')
  }
  $r = Invoke-Proc -FilePath $installer -ArgumentList $extractArgs -TimeoutMinutes $TimeoutMinutes
  $tool.Installer = [ordered]@{ Path = $installer; Bytes = $installerBytes; SignatureStatus = $sig.Status; SignerSubject = $sig.Subject }
  $tool.Extract = New-RunRecord -CommandLine ('"' + $installer + '" ' + $extractArgs) -Result $r
  if ($r.TimedOut) { throw ('The HP Image Assistant extraction did not finish within ' + $TimeoutMinutes + ' minutes and was stopped.') }

  $hpia = $null
  if (Test-Path -LiteralPath $extractDir) {
    $hpia = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'HPImageAssistant.exe' -File | Select-Object -First 1
  }
  if (-not $hpia) { throw ('HPImageAssistant.exe was not found under ' + $extractDir + ' after the extraction (exit code ' + $tool.Extract.ExitCodeHex + ').') }
  # The extracted tool runs elevated from the user-writable %TEMP%, so its own signature is checked too,
  # right before the launch (final review, Task 1 SECURITY). capture.json keeps what was found.
  $hpiaSig = Get-SignatureInfo -Path $hpia.FullName
  $tool.Path = $hpia.FullName
  $tool.FileVersion = Get-FileVersionText -Path $hpia.FullName
  $tool.SignatureStatus = $hpiaSig.Status
  $tool.SignerSubject = $hpiaSig.Subject
  if ($hpiaSig.Status -ne 'Valid' -or [string]$hpiaSig.Subject -notmatch 'HP Inc') {
    throw ('HPImageAssistant.exe was not run: its Authenticode signature is "' + $hpiaSig.Status + '" with signer "' + $hpiaSig.Subject + '" (it must be Valid and signed by HP Inc).')
  }

  $analyzeArgs = '/Operation:Analyze /Category:All /Selection:All /Action:List /Silent /ReportFolder:"' + $ReportDir + '"'
  Write-Host ('Running HP Image Assistant (list only, up to ' + $TimeoutMinutes + ' minutes)...')
  $r = Invoke-Proc -FilePath $hpia.FullName -ArgumentList $analyzeArgs -TimeoutMinutes $TimeoutMinutes -StdOutFile (Join-Path $LogDir 'hpia-analyze.out.txt') -StdErrFile (Join-Path $LogDir 'hpia-analyze.err.txt')
  $Capture.Run = New-RunRecord -CommandLine ('"' + $hpia.FullName + '" ' + $analyzeArgs) -Result $r
  Write-Host ('  -> HP Image Assistant exit code ' + $Capture.Run.ExitCodeHex + ', ' + $Capture.Run.ElapsedSeconds + ' s')

  # Every log under the extraction folder, flattened into logs\ with the sub-folder in the name.
  try {
    $logs = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Filter '*.log' -File)
    foreach ($f in $logs) {
      $relative = $f.FullName.Substring($extractDir.Length).TrimStart('\')
      Copy-LogFile -Source $f.FullName -DestDir $LogDir -DestName ('hpia-' + ($relative -replace '[\\/]', '__'))
    }
  } catch {
    Add-CaptureNote ('Could not read the logs under ' + $extractDir + ': ' + $_.Exception.Message)
  }

  Write-Host ('HP Image Assistant was left in ' + $HpWorkDir + '. Delete that folder when you are done.')
  if ($r.TimedOut) { throw ('HP Image Assistant did not finish within ' + $TimeoutMinutes + ' minutes and was stopped.') }
}

# --- Inventory (read-only) -------------------------------------------------------------------
# Plain, case-insensitive "contains" matching on the brand's terms. A few unrelated names may match
# (that is only noise); a missed vendor name would cost more, because these names become the verify values.
function Get-InventoryPattern {
  param([string]$Brand)
  if ($Brand -eq 'DELL') { return '(?i)Dell|SupportAssist' }
  return '(?i)HP|Hewlett'
}

function Get-Inventory {
  param([string]$Brand)
  $pattern = Get-InventoryPattern -Brand $Brand
  $inv = [ordered]@{ Pattern = $pattern; Services = $null; StartMenuShortcuts = $null; AppxPackages = $null }

  try {
    $list = New-Object System.Collections.ArrayList
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Sort-Object Name)) {
      if ([regex]::IsMatch([string]$s.Name, $pattern) -or [regex]::IsMatch([string]$s.DisplayName, $pattern)) {
        [void]$list.Add([ordered]@{ Name = $s.Name; DisplayName = $s.DisplayName; State = $s.State; StartMode = $s.StartMode; PathName = $s.PathName })
      }
    }
    $inv.Services = $list
  } catch {
    Add-CaptureError ('Inventory: the services could not be read: ' + $_.Exception.Message)
  }

  try {
    $list = New-Object System.Collections.ArrayList
    $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    if (Test-Path -LiteralPath $programs) {
      $lnkErrors = @()
      $files = @(Get-ChildItem -LiteralPath $programs -Recurse -Filter '*.lnk' -File -ErrorAction SilentlyContinue -ErrorVariable lnkErrors | Sort-Object FullName)
      if ($lnkErrors.Count -gt 0) { Add-CaptureNote ('Inventory: ' + $lnkErrors.Count + ' Start-menu folder(s) could not be read; first: ' + $lnkErrors[0].Exception.Message) }
      $shell = New-Object -ComObject WScript.Shell
      try {
        foreach ($f in $files) {
          if (-not [regex]::IsMatch($f.BaseName, $pattern)) { continue }
          $target = $null
          $arguments = $null
          try {
            $lnk = $shell.CreateShortcut($f.FullName)
            $target = $lnk.TargetPath
            $arguments = $lnk.Arguments
          } catch {
            Add-CaptureNote ('Inventory: could not read the shortcut ' + $f.FullName + ': ' + $_.Exception.Message)
          }
          [void]$list.Add([ordered]@{ Name = $f.BaseName; Path = $f.FullName.Substring($programs.Length).TrimStart('\'); Target = $target; Arguments = $arguments })
        }
      } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
      }
    }
    $inv.StartMenuShortcuts = $list
  } catch {
    Add-CaptureError ('Inventory: the Start-menu shortcuts could not be read: ' + $_.Exception.Message)
  }

  try {
    $list = New-Object System.Collections.ArrayList
    $appxErrors = @()
    $packages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue -ErrorVariable appxErrors | Where-Object { [regex]::IsMatch([string]$_.Name, $pattern) } | Sort-Object Name)
    if ($appxErrors.Count -gt 0) { Add-CaptureNote ('Inventory: Get-AppxPackage reported ' + $appxErrors.Count + ' error(s); first: ' + $appxErrors[0].Exception.Message) }
    foreach ($pkg in $packages) {
      [void]$list.Add([ordered]@{ Name = $pkg.Name; Version = [string]$pkg.Version; InstallLocation = $pkg.InstallLocation })
    }
    $inv.AppxPackages = $list
  } catch {
    Add-CaptureError ('Inventory: the Store packages could not be read: ' + $_.Exception.Message)
  }

  return $inv
}

# --- Main ------------------------------------------------------------------------------------
$machine = $null
try {
  $machine = Get-MachineRecord
} catch {
  Write-Host ('ERROR: the machine details could not be read: ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}

$brand = $null
if ($machine.Manufacturer -match 'Dell') {
  $brand = 'DELL'
} elseif ($machine.Manufacturer -match '\bHP\b|Hewlett') {
  $brand = 'HP'
} else {
  Write-Host 'This is not a Dell or HP laptop.' -ForegroundColor Red
  Write-Host ('(manufacturer: ' + $machine.Manufacturer + ', model: ' + $machine.Model + ')')
  exit 1
}

$serialText = ($machine.Serial -replace '[^A-Za-z0-9]', '')
if ($serialText.Length -eq 0) { $serialText = 'unknown' }
if ($serialText.Length -gt 20) { $serialText = $serialText.Substring(0, 20) }
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm', [Globalization.CultureInfo]::InvariantCulture)
$folderName = 'capture-' + $brand + '-' + $serialText + '-' + $stamp

$outDir = $null
$reportDir = $null
$logDir = $null
try {
  $outDir = Join-Path $OutRoot $folderName
  $n = 2
  while (Test-Path -LiteralPath $outDir) {
    $outDir = Join-Path $OutRoot ($folderName + '-' + $n)
    $n = $n + 1
  }
  $reportDir = Join-Path $outDir 'report'
  $logDir = Join-Path $outDir 'logs'
  [void](New-Item -ItemType Directory -Path $reportDir -Force)
  [void](New-Item -ItemType Directory -Path $logDir -Force)
} catch {
  Write-Host ('ERROR: the output folder could not be created under ' + $OutRoot + ': ' + $_.Exception.Message + ' (use -OutRoot to pick another place).') -ForegroundColor Red
  exit 1
}

$mode = 'Full'
if ($InventoryOnly) { $mode = 'InventoryOnly' }
$capture = [ordered]@{
  Spike          = 'DriverListCapture'
  RunAt          = (Get-NowText)
  Brand          = $brand
  Mode           = $mode
  InstallTool    = [bool]$InstallTool
  TimeoutMinutes = $TimeoutMinutes
  OutputFolder   = $outDir
  Machine        = $machine
  Tool           = $null
  Run            = $null
  CopiedFiles    = $copied
  Inventory      = $null
  Notes          = $notes
  Errors         = $errors
}

Write-Host ('Brand: ' + $brand + '   Model: ' + $machine.Model + '   Serial: ' + $machine.Serial)
Write-Host ('Output folder: ' + $outDir)
if ($machine.OnAc -eq $false) { Add-CaptureNote 'This PC is running on battery. The list is the same, but plug it in next time.' }
if ($InventoryOnly) {
  Write-Host 'Inventory only: the Dell/HP tool is not run.'
  if ($InstallTool) { Add-CaptureNote '-InstallTool is ignored with -InventoryOnly.' }
} else {
  Write-Host 'List-only capture: nothing is applied, changed or restarted on this PC.'
}

try {
  if (-not $InventoryOnly) {
    try {
      if ($brand -eq 'DELL') {
        Invoke-DellCapture -Capture $capture -ReportDir $reportDir -LogDir $logDir
      } else {
        Invoke-HpCapture -Capture $capture -ReportDir $reportDir -LogDir $logDir
      }
    } catch {
      Add-CaptureError $_.Exception.Message
    }
  }
  # The inventory runs in every case, also after a tool failure.
  Write-Host 'Reading the inventory (services, Start-menu shortcuts, Store packages)...'
  $capture.Inventory = Get-Inventory -Brand $brand
} catch {
  Add-CaptureError $_.Exception.Message
} finally {
  try {
    Save-Json -Object $capture -Path (Join-Path $outDir 'capture.json')
  } catch {
    [void]$errors.Add('capture.json could not be written: ' + $_.Exception.Message)
    Write-Host ('ERROR: capture.json could not be written: ' + $_.Exception.Message) -ForegroundColor Red
  }
}

Write-Host ''
Write-Host ('Files copied into logs: ' + $copied.Count)
Write-Host ('Output folder: ' + $outDir)
if ($errors.Count -gt 0) {
  Write-Host ('Finished with ' + $errors.Count + ' error(s). Send the whole folder back anyway: capture.json says what happened.') -ForegroundColor Yellow
  exit 1
}
Write-Host 'Done. Send back the whole folder.'
exit 0
