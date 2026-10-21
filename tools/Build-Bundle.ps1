# tools/Build-Bundle.ps1 - builds the single-file dist\setup.ps1 and copies config\config.json next to it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Bundle.ps1 -Version 2026.10.18.1 [-OutDir dist]
#
# setup.ps1 is UTF-8 with BOM and CRLF line endings, laid out as:
#   1. '# BenTech Windows Setup <Version>' (plus one more comment line)
#   2. src\Entry\Param.ps1 (the script's param block)
#   3. $script:SetupVersion = '<Version>'
#   4. every file in $BundleOrder, each after a '# ---- <path under src> ----' marker. The list is explicit
#      and ends with src\Entry\Main.ps1 (Start-BenTechSetup) and src\Entry\Run.ps1, whose only statement,
#      `exit (Start-BenTechSetup ...)`, is therefore the bundle's last one.
# Each source file's BOM is stripped and its line endings become CRLF. config.json is copied byte for
# byte. Throws (non-zero exit) on any problem: a bad -Version, a src file missing from $BundleOrder, a
# $BundleOrder entry with no file, or a bundle that does not parse. Nothing is written in those cases.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Version,
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'

# [0-9], not \d (which also matches non-ASCII digits), and \z, not $ (which also matches before a final
# newline): the version is pasted into the bundle as a string literal.
if ($Version -cnotmatch '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+\z') {
  throw "Invalid -Version '$Version': expected yyyy.MM.dd.N, for example 2026.10.18.1"
}

# Script-relative defaults are resolved here, not in the param block: $PSScriptRoot is empty in the
# param defaults of a [CmdletBinding()] script on Windows PowerShell 5.1.
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $repoRoot 'dist' }
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$srcRoot = Join-Path $repoRoot 'src'
$paramFile = 'Entry\Param.ps1'
$configSource = Join-Path $repoRoot 'config\config.json'

# Every src file except Entry\Param.ps1 (emitted first, on its own), in bundle order. Load order only
# matters for the file-scope $script: values, which are all plain constants; functions resolve at call
# time. Entry\Main.ps1 and Entry\Run.ps1 must stay last.
$BundleOrder = @(
  'Common\StepResult.ps1'
  'Common\Logging.ps1'
  'Common\Activity.ps1'
  'Common\Config.ps1'
  'Common\Signature.ps1'
  'Common\Process.ps1'
  'Common\Download.ps1'
  'State\State.ps1'
  'Detect\PcName.ps1'
  'Detect\Detection.ps1'
  'Engine\Catalog.ps1'
  'Engine\Verdict.ps1'
  'Engine\Reboot.ps1'
  'Engine\Runner.ps1'
  'Steps\Prepare.ps1'
  'Steps\BitLocker.ps1'
  'Steps\Region.ps1'
  'Steps\Desktop.ps1'
  'Steps\Tweaks.ps1'
  'Steps\Bloatware.ps1'
  'Steps\Rename.ps1'
  'Steps\Winget.ps1'
  'Steps\Apps.ps1'
  'Steps\ScreenConnect.ps1'
  'Steps\Office.ps1'
  'Steps\CraftApps.ps1'
  'Steps\DefaultBrowser.ps1'
  'Steps\Vendor.ps1'
  'Steps\WindowsUpdate.ps1'
  'Steps\Finalize.ps1'
  'Report\Report.ps1'
  'UI\ConsoleFrame.ps1'
  'UI\StartScreen.ps1'
  'UI\ProgressScreen.ps1'
  'UI\FinalScreen.ps1'
  'Toolbox\Strings.ps1'
  'Toolbox\SetupPlanner.ps1'
  'Toolbox\Toolbox.ps1'
  'Entry\Cleanup.ps1'
  'Entry\Main.ps1'
  'Entry\Run.ps1'
)

# --- The list must match the src folder exactly ---------------------------------------------------------
$onDisk = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter *.ps1 |
  ForEach-Object { $_.FullName.Substring($srcRoot.Length + 1) })
$listed = @($BundleOrder) + $paramFile
$problems = New-Object System.Collections.Generic.List[string]
foreach ($file in $onDisk) {
  if (-not ($listed | Where-Object { $_ -eq $file })) { $problems.Add("src file not in `$BundleOrder: $file") }
}
foreach ($file in $listed) {
  if (-not (Test-Path -LiteralPath (Join-Path $srcRoot $file) -PathType Leaf)) { $problems.Add("`$BundleOrder lists a missing file: $file") }
}
foreach ($group in @($BundleOrder | Group-Object | Where-Object { $_.Count -gt 1 })) { $problems.Add("`$BundleOrder lists a file twice: $($group.Name)") }
if ($BundleOrder -contains $paramFile) { $problems.Add("`$BundleOrder must not list $paramFile (it is emitted first)") }
if ($BundleOrder[-2] -ne 'Entry\Main.ps1' -or $BundleOrder[-1] -ne 'Entry\Run.ps1') { $problems.Add('$BundleOrder must end with Entry\Main.ps1, Entry\Run.ps1') }
if (-not (Test-Path -LiteralPath $configSource -PathType Leaf)) { $problems.Add("config not found: $configSource") }
if ($problems.Count -gt 0) { throw ("Cannot build the bundle:`r`n  " + ($problems -join "`r`n  ")) }

# --- Build the text -----------------------------------------------------------------------------------------
function Read-BundleSource {
  # A source file as text without its BOM, with CRLF line endings and no trailing blank lines.
  param([Parameter(Mandatory)][string]$RelativePath)

  $bytes = [IO.File]::ReadAllBytes((Join-Path $srcRoot $RelativePath))
  $start = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
  $text = (New-Object Text.UTF8Encoding $false, $true).GetString($bytes, $start, $bytes.Length - $start)   # throws on invalid UTF-8
  return (($text -replace "`r`n|`r|`n", "`r`n").TrimEnd())
}

$builder = New-Object System.Text.StringBuilder
$null = $builder.Append("# BenTech Windows Setup $Version`r`n")
$null = $builder.Append("# Built by tools\Build-Bundle.ps1 from src\. Do not edit: change src\ and rebuild.`r`n")
$null = $builder.Append((Read-BundleSource -RelativePath $paramFile) + "`r`n")
$null = $builder.Append("`$script:SetupVersion = '$Version'`r`n")
foreach ($file in $BundleOrder) {
  $null = $builder.Append("`r`n# ---- $file ----`r`n")
  $null = $builder.Append((Read-BundleSource -RelativePath $file) + "`r`n")
}
$bundle = $builder.ToString()

$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($bundle, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
  throw ("The bundle does not parse:`r`n  " + (($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`r`n  "))
}

# --- Write ------------------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$bundlePath = Join-Path $OutDir 'setup.ps1'
[IO.File]::WriteAllText($bundlePath, $bundle, (New-Object Text.UTF8Encoding $true))
[IO.File]::Copy($configSource, (Join-Path $OutDir 'config.json'), $true)
Write-Host "Built $bundlePath (version $Version, $($BundleOrder.Count + 1) source files) and copied config.json"
