# tools/Publish.ps1 - test, bundle, sign, verify, build the launcher, then publish a GitHub Release.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.18.1 [-Notes "..."] [-DryRun]
#
# Steps, stopping at the first failure (non-zero exit):
#   0. the source: the working tree is clean (dist\ is ignored) and HEAD is pushed (equals its upstream),
#      so the release tag points at exactly the code that was built. -DryRun only warns.
#   1. tools\Invoke-Tests.ps1 on tests\ (in a child Windows PowerShell 5.1)
#   2. tools\Build-Bundle.ps1 -> dist\setup.ps1, dist\config.json
#   3. tools\Sign-File.ps1 on both (the DPAPI-protected private key; never leaves this PC)
#   4. both signatures verified against keys\public-key.xml with Test-DetachedSignature
#   5. tools\Build-Launcher.ps1 -> dist\BenTechSetup.cmd, pointing at <repo>'s latest release. Its SHA-256
#      is printed and recorded in keys\launcher.sha256, with a warning when it changed (copies already
#      handed out are then the old launcher). Commit that file: a real publish needs a clean tree.
#   6. unless -DryRun: gh release create v<Version> --target <HEAD> with the FOUR signed files only.
#      The launcher is the trust anchor (it holds the public key), so it never ships on the channel it
#      protects (R29): Ben hands out dist\BenTechSetup.cmd himself.
# -DryRun does steps 1-5 for real (including signing dist\ locally) and only prints the gh command.
# The repo comes from tools\publish.settings.json: { "repo": "<owner>/<name>" }.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Version,
  [string]$Notes,
  [switch]$DryRun
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
$releaseNames = @('setup.ps1', 'setup.ps1.sig', 'config.json', 'config.json.sig')
$launcherName = 'BenTechSetup.cmd'

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
  Write-PublishStep '0/6 Checking the source (clean tree, HEAD pushed)'
  $source = Get-PublishSource -RepoRoot $repoRoot
  foreach ($problem in $source.Problems) { Write-Host "WARNING: $problem" -ForegroundColor Yellow }
  if ($source.Problems.Count -gt 0 -and -not $DryRun) { throw "refusing to publish: $($source.Problems -join '; ')" }
  if ($source.Problems.Count -eq 0) { Write-Host "Clean and pushed at $($source.Head)" }

  $step = '1/6 tests'
  Write-PublishStep "1/6 Running the test suite"
  & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'Invoke-Tests.ps1') -Path (Join-Path $repoRoot 'tests')
  if ($LASTEXITCODE -ne 0) { throw "the test suite failed (exit $LASTEXITCODE)" }

  $step = '2/6 bundle'
  Write-PublishStep "2/6 Building the bundle $Version"
  # Old outputs go first, so a failure further on can never leave a new file next to a stale signature
  # or launcher. Only these five files are removed, never the folder.
  foreach ($name in @($releaseNames) + $launcherName) {
    $path = Join-Path $dist $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  & (Join-Path $toolsDir 'Build-Bundle.ps1') -Version $Version -OutDir $dist

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
  $releaseAssets = @(foreach ($name in $releaseNames) { Join-Path $dist $name })
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
foreach ($asset in $releaseAssets) { Write-Host ("    {0,-17} {1,9:N0} bytes" -f (Split-Path -Leaf $asset), (Get-Item -LiteralPath $asset).Length) }
Write-Host '  Launcher (NOT uploaded; hand it out yourself):'
Write-Host ("    {0,-17} {1,9:N0} bytes  SHA-256 {2}" -f $launcherName, (Get-Item -LiteralPath $launcherPath).Length, $launcherHash)
if ($DryRun) { Write-Host '  DRY RUN: nothing was published.' -ForegroundColor Yellow } else { Write-Host "  Published: https://github.com/$repo/releases/tag/$tag" -ForegroundColor Green }
exit 0
