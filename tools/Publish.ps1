# tools/Publish.ps1 - test, bundle, sign, verify, build the launcher, then publish a GitHub Release.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.18.1 [-Notes "..."] [-DryRun]
#
# Steps, stopping at the first failure (non-zero exit):
#   1. tools\Invoke-Tests.ps1 on tests\ (in a child Windows PowerShell 5.1)
#   2. tools\Build-Bundle.ps1 -> dist\setup.ps1, dist\config.json
#   3. tools\Sign-File.ps1 on both (the DPAPI-protected private key; never leaves this PC)
#   4. both signatures verified against keys\public-key.xml with Test-DetachedSignature
#   5. tools\Build-Launcher.ps1 -> dist\BenTechSetup.cmd, pointing at <repo>'s latest release
#   6. unless -DryRun: gh release create v<Version> with the five files
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
$windowsPowerShell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$signedNames = @('setup.ps1', 'config.json')
$assetNames = @('setup.ps1', 'setup.ps1.sig', 'config.json', 'config.json.sig', 'BenTechSetup.cmd')

$step = 'checks'
$started = Get-Date
function Write-PublishStep([string]$Name) { Write-Host ''; Write-Host "== $Name" -ForegroundColor Cyan }

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

  $step = '1/6 tests'
  Write-PublishStep "1/6 Running the test suite"
  & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'Invoke-Tests.ps1') -Path (Join-Path $repoRoot 'tests')
  if ($LASTEXITCODE -ne 0) { throw "the test suite failed (exit $LASTEXITCODE)" }

  $step = '2/6 bundle'
  Write-PublishStep "2/6 Building the bundle $Version"
  # Old outputs go first, so a failure further on can never leave a new file next to a stale signature
  # or launcher. Only the five release files are removed, never the folder.
  foreach ($name in $assetNames) {
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
  Write-PublishStep '5/6 Building the launcher'
  & (Join-Path $toolsDir 'Build-Launcher.ps1') -BaseUrl $baseUrl -PublicKeyPath $publicKeyPath -OutPath (Join-Path $dist 'BenTechSetup.cmd')

  $step = '6/6 release'
  $assets = @(foreach ($name in $assetNames) { Join-Path $dist $name })
  foreach ($asset in $assets) { if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) { throw "missing release file: $asset" } }
  $ghArgs = @('release', 'create', $tag) + $assets + @('--repo', $repo, '--title', $tag, '--notes', $Notes)
  if ($DryRun) {
    Write-PublishStep '6/6 GitHub Release (skipped: DRY RUN)'
    Write-Host "DRY RUN - not run: gh $($ghArgs -join ' ')" -ForegroundColor Yellow
  }
  if (-not $DryRun) {
    Write-PublishStep "6/6 Publishing GitHub Release $tag to $repo"
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
Write-Host "  Base URL: $baseUrl"
foreach ($asset in $assets) { Write-Host ("  {0,-17} {1,9:N0} bytes" -f (Split-Path -Leaf $asset), (Get-Item -LiteralPath $asset).Length) }
if ($DryRun) { Write-Host '  DRY RUN: nothing was published.' -ForegroundColor Yellow } else { Write-Host "  Published: https://github.com/$repo/releases/tag/$tag" -ForegroundColor Green }
exit 0
