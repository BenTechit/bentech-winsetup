# tools/Publish.ps1 - test, bundle, sign, verify, build the launcher, then publish a GitHub Release.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.18.1 [-Notes "..."] [-DryRun]
#
# Steps, stopping at the first failure (non-zero exit):
#   0. the source: the working tree is clean (dist\ is ignored) and HEAD is pushed (equals its upstream),
#      so the release tag points at exactly the code that was built; and Ben's ScreenConnect installer
#      (%USERPROFILE%\.bentech-winsetup\ScreenConnect.ClientSetup.exe, or -ScreenConnectInstaller) exists, has
#      the SHA-256 pinned in config\config.json apps.screenconnect and a Valid ConnectWise signature. Its
#      certificate end date is printed, with a warning inside 60 days. -DryRun only warns.
#   1. tools\Invoke-Tests.ps1 on tests\ (in a child Windows PowerShell 5.1)
#   2. tools\Build-Bundle.ps1 -> dist\setup.ps1, dist\config.json; the installer is copied to dist\ and, on a
#      real publish, checked again there (same pin and signers as step 0), so the uploaded bytes are the checked ones.
#      Then Microsoft Defender scans dist\setup.ps1 (MpCmdRun -Scan -ScanType 3; -DefenderScanner): anything but a
#      clean result (exit 0), a missing scanner included, refuses a real publish before signing and is a warning
#      under -DryRun (CLAUDE.md, "Plain code only": v2026.10.23.1 was blocked on customer PCs). Update Defender's
#      definitions first. A file scan is not the AMSI scan setup.ps1 gets when it runs: docs\testing.md has that check.
#   3. tools\Sign-File.ps1 on both (the DPAPI-protected private key; never leaves this PC)
#   4. both signatures verified against keys\public-key.xml with Test-DetachedSignature
#   5. tools\Build-Launcher.ps1 -> dist\BenTechSetup.cmd, pointing at <repo>'s latest release. Its SHA-256
#      is printed and recorded in keys\launcher.sha256, with a warning when it changed (copies already
#      handed out are then the old launcher). Commit that file: a real publish needs a clean tree.
#   6. unless -DryRun: gh release create v<Version> --target <HEAD> with FIVE files: the four signed ones
#      (setup.ps1, config.json and their .sig) plus ScreenConnect.ClientSetup.exe. The installer has no .sig:
#      the signed config.json pins its SHA-256. Under -DryRun a missing installer is left out (it was warned
#      about in step 0).
#      The launcher is the trust anchor (it holds the public key), so it never ships on the channel it
#      protects (R29): Ben hands out dist\BenTechSetup.cmd himself.
# -DryRun does steps 0-5 for real (including signing dist\ locally) and only prints the gh command.
# The repo comes from tools\publish.settings.json: { "repo": "<owner>/<name>" }.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Version,
  [string]$Notes,
  [switch]$DryRun,
  # Ben's installer; empty means %USERPROFILE%\.bentech-winsetup\ScreenConnect.ClientSetup.exe (resolved in the body).
  # A parameter so the tests point it into $TestDrive and never read the real file.
  [string]$ScreenConnectInstaller,
  # Microsoft Defender's command-line scanner; empty means the newest MpCmdRun.exe (resolved in the body). A parameter
  # so the tests point it at a stub and never start a real scan.
  [string]$DefenderScanner
)

$ErrorActionPreference = 'Stop'

# Script-relative paths are resolved here, not in the param block: $PSScriptRoot is empty in the param
# defaults of a [CmdletBinding()] script on Windows PowerShell 5.1.
$toolsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $toolsDir
$dist = Join-Path $repoRoot 'dist'
$publicKeyPath = Join-Path $repoRoot 'keys\public-key.xml'
$launcherHashPath = Join-Path $repoRoot 'keys\launcher.sha256'
$windowsPowerShell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$signedNames = @('setup.ps1', 'config.json')
$releaseNames = @('setup.ps1', 'setup.ps1.sig', 'config.json', 'config.json.sig', 'ScreenConnect.ClientSetup.exe')
$installerName = 'ScreenConnect.ClientSetup.exe'
$launcherName = 'BenTechSetup.cmd'
if ([string]::IsNullOrWhiteSpace($ScreenConnectInstaller)) {
  $ScreenConnectInstaller = Join-Path $env:USERPROFILE ('.bentech-winsetup\' + $installerName)
}

if ([string]::IsNullOrWhiteSpace($DefenderScanner)) {
  # The platform folder holds the current scanner; the Program Files one is the copy Windows shipped with.
  $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
  $newest = @(Get-ChildItem -LiteralPath $platform -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'MpCmdRun.exe') -PathType Leaf } |
    Sort-Object { try { [version]($_.Name -replace '-.*$', '') } catch { [version]'0.0' } } -Descending)   # 4.18.24090.11-0
  $DefenderScanner = if ($newest.Count -gt 0) { Join-Path $newest[0].FullName 'MpCmdRun.exe' } else { Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe' }
}

$step = 'checks'
$started = Get-Date
function Write-PublishStep([string]$Name) { Write-Host ''; Write-Host "== $Name" -ForegroundColor Cyan }

function Get-PublishSource {
  # Returns @{ Head = <HEAD sha or $null>; Problems = <string[]> } for the git repo at RepoRoot. A problem
  # is anything that would let the release tag point at other code than the code that was built: a dirty
  # or untracked working tree, no upstream, or a HEAD that differs from its upstream (not pushed). "Pushed"
  # is as far as this clone knows (the upstream ref as of the last fetch or push).
  param([Parameter(Mandatory)][string]$RepoRoot)

  $ErrorActionPreference = 'Continue'   # git reports e.g. "no upstream" on stderr; its exit codes decide
  $problems = New-Object System.Collections.Generic.List[string]
  $global:LASTEXITCODE = -1   # a git that cannot even start must not leave a stale 0 behind
  $status = @(& git -C $RepoRoot status --porcelain 2>$null)
  if ($LASTEXITCODE -ne 0) {
    $problems.Add("git status failed in $RepoRoot (not a git repository, or git is missing), so the source cannot be verified")
    return @{ Head = $null; Problems = $problems.ToArray() }
  }
  if (@($status | Where-Object { "$_".Trim() }).Count -gt 0) {
    $problems.Add('the working tree has uncommitted or untracked changes (git status --porcelain is not empty); commit them first')
  }
  $global:LASTEXITCODE = -1
  $headOut = @(& git -C $RepoRoot rev-parse HEAD 2>$null)
  $head = $null
  if ($LASTEXITCODE -eq 0 -and $headOut.Count -gt 0) { $head = "$($headOut[0])".Trim() }
  if (-not $head) { $problems.Add('git rev-parse HEAD failed (no commit yet?)') }
  $global:LASTEXITCODE = -1
  $upOut = @(& git -C $RepoRoot rev-parse '@{u}' 2>$null)
  $upstream = $null
  if ($LASTEXITCODE -eq 0 -and $upOut.Count -gt 0) { $upstream = "$($upOut[0])".Trim() }
  if (-not $upstream) {
    $problems.Add('the branch has no upstream yet; push it first (git push -u origin <branch>)')
  } elseif ($head -and $upstream -ne $head) {
    $problems.Add("HEAD $head is not pushed (its upstream is at $upstream); push first")
  }
  return @{ Head = $head; Problems = $problems.ToArray() }
}

function Get-ScreenConnectInstallerCheck {
  # Returns @{ Problems = <string[]>; NotAfter = <datetime or $null> } for Ben's ScreenConnect installer. It
  # never throws, whatever Signers holds (a config without signers.connectwise gives @($null), which must
  # reach the function and be reported, not stop the run at the call). A problem is anything that would make
  # the run's step refuse the file, or that would mean the wrong file is about to be published: the file is
  # missing, its SHA-256 is not the one pinned in config.json (that pin is what proves it is Ben's file;
  # every ScreenConnect installer carries a valid ConnectWise signature), there is no usable signer to check
  # against, its Authenticode status is not Valid (an expired certificate shows as another status: the
  # installer has no timestamp), or its signer is not on the list. The signer rule is the one
  # Test-FileSignature applies without -ExactCN: the subject holds CN=<signer> as literal text.
  # NotAfter is the signer certificate's end date whenever it could be read.
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Sha256,
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Signers
  )

  $problems = New-Object System.Collections.Generic.List[string]
  $notAfter = $null
  $allowed = @($Signers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      # Nothing else can be checked without the file.
      $problems.Add("not found: $Path")
      return @{ Problems = $problems.ToArray(); NotAfter = $null }
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actual, $Sha256, [StringComparison]::OrdinalIgnoreCase)) {
      $problems.Add("SHA-256 is $actual, config.json apps.screenconnect.sha256 is $Sha256")
    }
    if ($allowed.Count -eq 0) { $problems.Add('no ConnectWise signer in config.json signers.connectwise') }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $subject = ''
    if ($signature.SignerCertificate) {
      $subject = [string]$signature.SignerCertificate.Subject
      $notAfter = $signature.SignerCertificate.NotAfter
    }
    if ([string]$signature.Status -ne 'Valid') {
      $problems.Add("Authenticode status is $($signature.Status), not Valid")
    } elseif ($allowed.Count -gt 0) {
      $match = $false
      foreach ($signer in $allowed) {
        if ($subject -like ('*CN=' + [Management.Automation.WildcardPattern]::Escape($signer) + '*')) { $match = $true; break }
      }
      if (-not $match) { $problems.Add("not signed by $($allowed -join ' or ') (subject: $subject)") }
    }
  } catch {
    $problems.Add("could not be read: $($_.Exception.Message)")
  }
  return @{ Problems = $problems.ToArray(); NotAfter = $notAfter }
}

function Get-CertificateEndWarning {
  # A warning text when the certificate ends in less than 60 days, else $null. The installer carries no
  # timestamp, so from the end date on Windows stops reporting its signature as Valid and the run refuses it.
  param(
    [Parameter(Mandatory)][datetime]$NotAfter,
    [Parameter(Mandatory)][datetime]$Now
  )

  $days = ($NotAfter - $Now).TotalDays
  if ($days -ge 60) { return $null }
  $end = $NotAfter.ToString('dd/MM/yyyy', [Globalization.CultureInfo]::InvariantCulture)
  if ($days -lt 0) {
    # Already ended (a dry run only: a real publish refuses a file whose status is no longer Valid). Whole calendar
    # days, so the count agrees with the date shown.
    $ago = [int]($Now.Date - $NotAfter.Date).TotalDays
    return "WARNING: the ScreenConnect installer's certificate ended $end ($ago days ago): build a new installer now (README `"A new ScreenConnect installer`")"
  }
  return "WARNING: the ScreenConnect installer's certificate ends $end ($([int][Math]::Floor($days)) days from now): build a new installer before then (README `"A new ScreenConnect installer`")"
}

function Get-DefenderScanCheck {
  # Returns @{ Problems = <string[]> }: empty only when Microsoft Defender's scanner scanned Path and found nothing
  # (exit code 0). Exit code 2 is a detection or a scan error and both refuse (fail closed), as does a scanner that
  # is missing or cannot start: an unscanned bundle is not a clean one. -DisableRemediation: the scan reports, it
  # never quarantines dist\. The scanner's text is shown, never parsed.
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Scanner
  )

  $ErrorActionPreference = 'Continue'   # the scanner may write to stderr; its exit code decides
  $problems = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $Scanner -PathType Leaf)) {
    $problems.Add("Microsoft Defender's scanner was not found ($Scanner), so $Path was not scanned")
    return @{ Problems = $problems.ToArray() }
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $problems.Add("$Path is missing (Defender's real-time protection may have quarantined it)")
    return @{ Problems = $problems.ToArray() }
  }
  $global:LASTEXITCODE = -1   # a scanner that cannot even start must not leave a stale 0 behind
  try {
    $output = @(& $Scanner -Scan -ScanType 3 -File $Path -DisableRemediation 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  } catch {
    $problems.Add("Microsoft Defender's scanner could not start ($Scanner): $($_.Exception.Message)")
    return @{ Problems = $problems.ToArray() }
  }
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    $problems.Add("Microsoft Defender did not pass $Path (MpCmdRun exit $code`: a detection or a scan error): $($output -join ' / ')")
  }
  return @{ Problems = $problems.ToArray() }
}

try {
  # Same rule as Build-Bundle.ps1, checked up front so a typo fails before the slow test run.
  if ($Version -cnotmatch '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+\z') {
    throw "Invalid -Version '$Version': expected yyyy.MM.dd.N, for example 2026.10.18.1"
  }
  if ([string]::IsNullOrWhiteSpace($Notes)) { $Notes = "BenTech Windows Setup v$Version" }
  # Windows PowerShell 5.1 passes embedded double quotes to native programs unescaped, so gh would get a
  # mangled argument list.
  if ($Notes.Contains('"')) { throw '-Notes must not contain double quotes.' }
  $settingsPath = Join-Path $toolsDir 'publish.settings.json'
  $repo = [string](Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).repo
  if ($repo -cnotmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+\z') { throw "publish.settings.json: 'repo' must be '<owner>/<name>', got '$repo'" }
  $baseUrl = "https://github.com/$repo/releases/latest/download"
  $tag = "v$Version"
  if (-not $DryRun -and -not (Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'gh (GitHub CLI) was not found on PATH; install it and run gh auth login first.'
  }

  $step = '0/6 source'
  Write-PublishStep '0/6 Checking the source and the ScreenConnect installer'
  $source = Get-PublishSource -RepoRoot $repoRoot
  foreach ($problem in $source.Problems) { Write-Host "WARNING: $problem" -ForegroundColor Yellow }
  if ($source.Problems.Count -gt 0 -and -not $DryRun) { throw "refusing to publish: $($source.Problems -join '; ')" }
  if ($source.Problems.Count -eq 0) { Write-Host "Clean and pushed at $($source.Head)" }

  # Ben's installer, checked here, before the slow test run: it must be the file config.json pins.
  $appConfig = Get-Content -LiteralPath (Join-Path $repoRoot 'config\config.json') -Raw | ConvertFrom-Json
  $installerCheck = Get-ScreenConnectInstallerCheck -Path $ScreenConnectInstaller -Sha256 ([string]$appConfig.apps.screenconnect.sha256) -Signers @($appConfig.signers.connectwise)
  foreach ($problem in $installerCheck.Problems) { Write-Host "WARNING: ScreenConnect installer $problem" -ForegroundColor Yellow }
  if ($installerCheck.Problems.Count -gt 0 -and -not $DryRun) {
    throw "refusing to publish: the ScreenConnect installer $($installerCheck.Problems -join '; ')"
  }
  if ($installerCheck.Problems.Count -eq 0) { Write-Host "ScreenConnect installer checked: $ScreenConnectInstaller" }
  if ($installerCheck.NotAfter) {
    Write-Host "ScreenConnect installer certificate ends $(([datetime]$installerCheck.NotAfter).ToString('dd/MM/yyyy', [Globalization.CultureInfo]::InvariantCulture))"
    $endWarning = Get-CertificateEndWarning -NotAfter ([datetime]$installerCheck.NotAfter) -Now (Get-Date)
    if ($endWarning) { Write-Host $endWarning -ForegroundColor Yellow }
  }

  $step = '1/6 tests'
  Write-PublishStep "1/6 Running the test suite"
  & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'Invoke-Tests.ps1') -Path (Join-Path $repoRoot 'tests')
  if ($LASTEXITCODE -ne 0) { throw "the test suite failed (exit $LASTEXITCODE)" }

  $step = '2/6 bundle'
  Write-PublishStep "2/6 Building the bundle $Version"
  # Old outputs go first, so a failure further on can never leave a new file next to a stale signature
  # or launcher. Only these six files are removed, never the folder.
  foreach ($name in @($releaseNames) + $launcherName) {
    $path = Join-Path $dist $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  & (Join-Path $toolsDir 'Build-Bundle.ps1') -Version $Version -OutDir $dist
  # Ben's installer goes to dist\ as it is. A real publish only gets here after step 0 passed its checks;
  # under -DryRun a file that failed them is still copied, so the dry run shows the full upload.
  if (Test-Path -LiteralPath $ScreenConnectInstaller -PathType Leaf) {
    Copy-Item -LiteralPath $ScreenConnectInstaller -Destination (Join-Path $dist $installerName) -Force
  }
  # The file was checked at step 0, and the test run took a while since. Check the bytes that will be uploaded,
  # with the same pin and signers, so a file that changed in between never reaches the release.
  if (-not $DryRun) {
    $distCheck = Get-ScreenConnectInstallerCheck -Path (Join-Path $dist $installerName) -Sha256 ([string]$appConfig.apps.screenconnect.sha256) -Signers @($appConfig.signers.connectwise)
    if ($distCheck.Problems.Count -gt 0) { throw "ScreenConnect installer in dist failed its check: $($distCheck.Problems -join '; ')" }
  }
  # Defender scans the bundle before it is signed, so a flagged setup.ps1 never gets a signature (CLAUDE.md, "Plain
  # code only").
  $defenderCheck = Get-DefenderScanCheck -Path (Join-Path $dist 'setup.ps1') -Scanner $DefenderScanner
  if ($defenderCheck.Problems.Count -gt 0 -and -not $DryRun) { throw "refusing to publish: $($defenderCheck.Problems -join '; ')" }
  if ($defenderCheck.Problems.Count -gt 0) { foreach ($problem in $defenderCheck.Problems) { Write-Host "WARNING: $problem" -ForegroundColor Yellow } }
  else { Write-Host 'Microsoft Defender: dist\setup.ps1 scanned clean' }

  $step = '3/6 sign'
  Write-PublishStep '3/6 Signing'
  foreach ($name in $signedNames) { & (Join-Path $toolsDir 'Sign-File.ps1') -Path (Join-Path $dist $name) }

  $step = '4/6 verify'
  Write-PublishStep '4/6 Verifying the signatures against keys\public-key.xml'
  . (Join-Path $repoRoot 'src\Common\Signature.ps1')
  $publicXml = [IO.File]::ReadAllText($publicKeyPath)
  foreach ($name in $signedNames) {
    $path = Join-Path $dist $name
    $ok = Test-DetachedSignature -Data ([IO.File]::ReadAllBytes($path)) -Signature ([IO.File]::ReadAllBytes("$path.sig")) -PublicKeyXml $publicXml
    if (-not (($ok -is [bool]) -and ($ok -eq $true))) {
      throw "$name.sig does not verify against $publicKeyPath. The signing key and the committed public key do not match; every launcher would refuse this release."
    }
    Write-Host "Verified $name"
  }

  $step = '5/6 launcher'
  Write-PublishStep '5/6 Building the launcher (not uploaded: hand it out yourself)'
  $launcherPath = Join-Path $dist $launcherName
  & (Join-Path $toolsDir 'Build-Launcher.ps1') -BaseUrl $baseUrl -PublicKeyPath $publicKeyPath -OutPath $launcherPath
  $launcherHash = (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host "Launcher SHA-256: $launcherHash"
  if (Test-Path -LiteralPath $launcherHashPath -PathType Leaf) {
    $recorded = @(([IO.File]::ReadAllText($launcherHashPath).Trim()) -split '\s+')[0]
    if ($recorded -ne $launcherHash) {
      Write-Host "WARNING: the launcher changed (keys\launcher.sha256 had $recorded). Copies already handed out are the old launcher: replace them with dist\$launcherName." -ForegroundColor Yellow
    }
  }
  [IO.File]::WriteAllText($launcherHashPath, "$launcherHash  $launcherName`r`n", (New-Object Text.ASCIIEncoding))

  $step = '6/6 release'
  # Under -DryRun a missing installer (already warned about in step 0) is left out; every other file must exist.
  $releaseAssets = @(foreach ($name in $releaseNames) {
    $asset = Join-Path $dist $name
    if ($DryRun -and $name -eq $installerName -and -not (Test-Path -LiteralPath $asset -PathType Leaf)) { continue }
    $asset
  })
  foreach ($asset in $releaseAssets) { if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) { throw "missing release file: $asset" } }
  $ghArgs = @('release', 'create', $tag) + $releaseAssets + @('--repo', $repo, '--target', $source.Head, '--title', $tag, '--notes', $Notes)
  if ($DryRun) {
    Write-PublishStep '6/6 GitHub Release (skipped: DRY RUN)'
    $shown = @($ghArgs | ForEach-Object { if ([string]::IsNullOrEmpty([string]$_)) { '(unknown-HEAD)' } else { $_ } })
    Write-Host "DRY RUN - not run: gh $($shown -join ' ')" -ForegroundColor Yellow
  }
  if (-not $DryRun) {
    Write-PublishStep "6/6 Publishing GitHub Release $tag to $repo at $($source.Head)"
    $ErrorActionPreference = 'Continue'   # gh reports progress on stderr; its exit code decides
    $global:LASTEXITCODE = -1             # never read a stale 0 left by an earlier native call
    & gh @ghArgs
    $ghExit = $global:LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($ghExit -ne 0) { throw "gh release create failed (exit $ghExit)" }
  }
} catch {
  Write-Host ''
  Write-Host "PUBLISH FAILED at step $step : $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'Nothing was published.' -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host ('Done in {0:mm\:ss}.' -f ((Get-Date) - $started)) -ForegroundColor Green
Write-Host "  Version:  $Version ($tag)"
Write-Host "  Repo:     $repo"
Write-Host "  Commit:   $(if ($source.Head) { $source.Head } else { '(unknown)' })"
Write-Host "  Base URL: $baseUrl"
Write-Host '  Release files (uploaded):'
foreach ($asset in $releaseAssets) { Write-Host ("    {0,-29} {1,10:N0} bytes" -f (Split-Path -Leaf $asset), (Get-Item -LiteralPath $asset).Length) }
Write-Host '  Launcher (NOT uploaded; hand it out yourself):'
Write-Host ("    {0,-29} {1,10:N0} bytes  SHA-256 {2}" -f $launcherName, (Get-Item -LiteralPath $launcherPath).Length, $launcherHash)
if ($DryRun) { Write-Host '  DRY RUN: nothing was published.' -ForegroundColor Yellow } else { Write-Host "  Published: https://github.com/$repo/releases/tag/$tag" -ForegroundColor Green }
exit 0
