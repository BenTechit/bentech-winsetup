@echo off
setlocal
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1 || ( "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b )
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText('%~f0'); & ([ScriptBlock]::Create($t.Substring($t.LastIndexOf('#__PS__')))) %*"
exit /b %errorlevel%
#__PS__
# BenTech Windows Setup launcher - the PowerShell part of BenTechSetup.cmd.
# Built by tools\Build-Launcher.ps1 from launcher\BenTechSetup.template.cmd. Do not edit a built copy.
#
# THE TRUST GATE. It downloads setup.ps1 and config.json with their detached signatures, verifies BOTH
# against the public key embedded below, and only then writes them to $TargetDir and runs setup.ps1.
# Nothing unsigned ever runs. This section is self-contained on purpose (it cannot dot-source anything),
# so the small helpers below are commented copies ("mirrors") of src code and must be kept in step.
# Keep this file ASCII-only and never write the marker string from line 6 anywhere below it.
# The cmd part starts every program by its full path: cmd looks for a bare name in the .cmd's own folder
# first, so a powershell.bat or fltmc.bat planted next to the launcher (Downloads) would run instead.
#
# Exit codes: setup.ps1's own exit code once it ran; 1 unexpected launcher error; 2 a setup run already
# holds the lock; 3 a signature check failed (nothing written, nothing run); 4 the release could not be
# downloaded after all retries (a missing asset counts as a failed download; nothing written or run);
# 5 the folder could not be made admin-only (nothing written, nothing run).
param(
  [string]$BaseUrl = '{{BASE_URL}}',
  [string]$TargetDir = 'C:\BenTech\Setup',
  [switch]$SkipAcl,
  [switch]$NoPause,
  [int]$Retries = 20,
  [int]$RetrySeconds = 30
)

$ErrorActionPreference = 'Stop'
$PublicKeyXml = '{{PUBLIC_KEY_XML}}'
$ReleaseFiles = @('setup.ps1', 'config.json')   # each has a detached <name>.sig next to it in the release

function Exit-Launcher([int]$Code) {
  # A non-zero result stays on screen long enough to read before the window closes.
  if ($Code -ne 0 -and -not $NoPause) { Start-Sleep -Seconds 15 }
  exit $Code
}

function Write-Failure([string]$Text) { Write-Host $Text -ForegroundColor Red }

function Test-SetupLockHeld([string]$Root) {
  # Mirror of src/State/State.ps1 / Test-RunLockHeld - keep in step. Held only when run.lock holds an
  # int pid of a live powershell/pwsh process that started no more than 5 s after the lock was written
  # (a later start means Windows reused the pid of a crashed run).
  $lock = Join-Path $Root 'run.lock'
  if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return $false }
  try { $text = [IO.File]::ReadAllText($lock) } catch { return $false }
  $ownerPid = 0
  $parsed = [int]::TryParse($text.Trim(), [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$ownerPid)
  if (-not $parsed -or $ownerPid -le 0) { return $false }
  $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
  if ($null -eq $process) { return $false }
  if ($process.ProcessName -notin 'powershell', 'pwsh') { return $false }
  try {
    if ($process.StartTime.ToUniversalTime() -gt [IO.File]::GetLastWriteTimeUtc($lock).AddSeconds(5)) { return $false }
  } catch {
    # Start time unreadable (access denied): the name matched, so treat the lock as held, like the source.
  }
  return $true
}

function Test-ReleaseSignature($Data, $Signature, $KeyXml) {
  # Mirror of src/Common/Signature.ps1 / Test-DetachedSignature - keep in step. RSA PKCS#1 v1.5 SHA-256
  # over the raw bytes. Fails closed: untyped parameters so binding cannot throw, every conversion inside
  # the try, and empty data or signature, any exception or any wrong type is $false.
  try {
    $ErrorActionPreference = 'Stop'
    $dataBytes = [byte[]]$Data
    $signatureBytes = [byte[]]$Signature
    if ($null -eq $dataBytes -or $dataBytes.Length -eq 0 -or $null -eq $signatureBytes -or $signatureBytes.Length -eq 0) { return $false }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
      $rsa.FromXmlString([string]$KeyXml)
      return [bool]$rsa.VerifyData($dataBytes, $signatureBytes,
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
      $rsa.Dispose()
    }
  } catch {
    return $false
  }
}

function Get-LauncherAclCommands([string]$Parent) {
  # Mirror of src/Steps/Prepare.ps1 / Get-SetupFolderAclCommands - keep in step. In order: Administrators
  # take ownership of the parent and everything below; every ACL below is reset to inherited-only (drops
  # planted ACEs); the parent stops inheriting from C:\ and grants only Administrators and SYSTEM. SIDs,
  # never localized group names. No /C, which makes icacls exit 0 even when it failed. No trailing
  # backslash, since \" escapes the quote. Throws unless Parent is below a drive root ("C:\x").
  $path = $Parent.Trim().TrimEnd('\')
  if ($path -notmatch '^[A-Za-z]:\\[^\\]') { throw "Refusing to lock down '$Parent': expected an absolute folder below a drive root." }
  @(
    "`"$path`" /setowner *S-1-5-32-544 /T"
    "`"$path`" /reset /T"
    "`"$path`" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F"
  )
}

function Test-LauncherReparsePoint([string]$Path) {
  # Mirror of src/Steps/Prepare.ps1 / Test-SetupReparsePoint. A junction or symlink is $true; missing is $false.
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return ($null -ne $item -and (([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))
}

function Protect-LauncherFolder([string]$TargetDir) {
  # Same sequence as src/Steps/Prepare.ps1 / Protect-SetupFolder - keep in step. $true only when the parent
  # (C:\BenTech) and everything below are owned by Administrators and only Administrators and SYSTEM have
  # access, and neither folder is a junction or symlink. Never throws: any problem is $false.
  try {
    $parent = Split-Path -Parent $TargetDir
    $commands = Get-LauncherAclCommands -Parent $parent
    foreach ($path in $parent, $TargetDir) { if (Test-LauncherReparsePoint -Path $path) { return $false } }
    if ($null -eq (Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    foreach ($arguments in $commands) {
      $icacls = Start-Process -FilePath "$env:windir\System32\icacls.exe" -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
      if ($null -eq $icacls -or $icacls.ExitCode -ne 0) { return $false }
    }
    # Created only now, so it inherits the lockdown.
    if ($null -eq (Get-Item -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
    # Again: a junction swapped in before the lockdown is refused too. From here on only administrators
    # can change anything under the parent.
    foreach ($path in $parent, $TargetDir) { if (Test-LauncherReparsePoint -Path $path) { return $false } }
    return $true
  } catch {
    return $false
  }
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  # 1. One run at a time: never overwrite the files of a run (or its resume) in progress.
  if (Test-SetupLockHeld -Root $TargetDir) {
    Write-Failure 'Setup is already running on this machine'
    Exit-Launcher 2
  }

  # 2. Download all four files as raw bytes. A retry fetches the whole set again.
  Write-Host 'BenTech Setup: downloading the latest version...'
  $base = $BaseUrl.TrimEnd('/')
  $names = foreach ($name in $ReleaseFiles) { $name; "$name.sig" }
  $downloaded = $null
  for ($attempt = 1; $attempt -le $Retries -and $null -eq $downloaded; $attempt++) {
    $client = New-Object System.Net.WebClient
    $current = $null
    try {
      $got = @{}
      foreach ($name in $names) {
        $current = $name
        $client.Headers['User-Agent'] = 'BenTechSetup/1.0'
        $got[$name] = $client.DownloadData("$base/$name")
      }
      $downloaded = $got
    } catch {
      $reason = $_.Exception
      if ($reason.InnerException) { $reason = $reason.InnerException }
      Write-Host "  ($current, attempt $attempt of $Retries) $($reason.Message)" -ForegroundColor DarkGray
      if ($attempt -lt $Retries) {
        Write-Failure "Cannot reach GitHub - retrying in $($RetrySeconds)s (close this window to stop)"
        Start-Sleep -Seconds $RetrySeconds
      }
    } finally {
      $client.Dispose()
    }
  }
  if ($null -eq $downloaded) {
    Write-Failure 'Cannot reach GitHub - giving up. Nothing was run.'
    Exit-Launcher 4
  }

  # 3. Verify BOTH files before anything is written. Only a real [bool] $true counts as a pass, and
  # every file must pass (counted, so nothing can pass by default).
  $passed = 0
  try {
    foreach ($name in $ReleaseFiles) {
      $ok = Test-ReleaseSignature -Data $downloaded[$name] -Signature $downloaded["$name.sig"] -KeyXml $PublicKeyXml
      if (($ok -is [bool]) -and ($ok -eq $true)) { $passed++ }
    }
  } catch {
    $passed = 0
  }
  if ($ReleaseFiles.Count -lt 2 -or $passed -ne $ReleaseFiles.Count) {
    Write-Failure 'SECURITY CHECK FAILED - files are not signed by BenTech. Nothing was run.'
    Exit-Launcher 3
  }

  # 4. Check the lock again: retries can take minutes, and a resume may have started meanwhile.
  if (Test-SetupLockHeld -Root $TargetDir) {
    Write-Failure 'Setup is already running on this machine'
    Exit-Launcher 2
  }

  # 5. Admin-only folder (fatal when it fails), then the verified bytes exactly as downloaded.
  #    -SkipAcl is for the tests only: they run without elevation and cannot lock a folder down.
  if ($SkipAcl) {
    if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
  } elseif (-not (Protect-LauncherFolder -TargetDir $TargetDir)) {
    Write-Failure "Cannot secure $(Split-Path -Parent $TargetDir) - nothing was run."
    Exit-Launcher 5
  }
  foreach ($name in $ReleaseFiles) {
    [IO.File]::WriteAllBytes((Join-Path $TargetDir $name), [byte[]]$downloaded[$name])
  }
  $setupPath = Join-Path $TargetDir 'setup.ps1'
} catch {
  Write-Failure "Setup could not start: $($_.Exception.Message)"
  Exit-Launcher 1
}

# 6. Run that same file. Outside the try and not inside a function, so setup.ps1 gets the real console
# (its screens need it) instead of a captured pipe. Verification is done, so the native call runs with
# the default error preference.
$ErrorActionPreference = 'Continue'
Write-Host 'Signature OK. Starting setup...'
& "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $setupPath
$setupExit = $LASTEXITCODE
if ($null -eq $setupExit) { $setupExit = 1 }
Exit-Launcher $setupExit
