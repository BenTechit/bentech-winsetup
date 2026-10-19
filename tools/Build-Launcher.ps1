# tools/Build-Launcher.ps1 - builds the signed-release launcher BenTechSetup.cmd from launcher\BenTechSetup.template.cmd.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Launcher.ps1 -BaseUrl https://github.com/<repo>/releases/latest/download
#              [-PublicKeyPath keys\public-key.xml] [-OutPath dist\BenTechSetup.cmd] [-TemplatePath launcher\BenTechSetup.template.cmd]
#
# The template is an ASCII cmd/PowerShell polyglot. This fills in its two placeholders: the base URL and the
# public key XML (collapsed to one line), both inside single-quoted PowerShell strings. The result is written
# ASCII-only with CRLF line endings.
#
# Throws (non-zero exit) and writes nothing when:
# - the template is not pure ASCII (a BOM counts), or lacks a placeholder, or a placeholder is left over
# - the key XML has a single quote or a newline, is not an RSA key, is a PRIVATE key, or is under 3072 bits
# - the base URL is not an absolute https:// (or file:// for tests) URL, or has a quote or a newline
# - the marker line is missing, is not right after the cmd part's `exit /b`, or the PowerShell section
#   repeats the marker (the cmd part finds that section with LastIndexOf)
# - the PowerShell section does not parse
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BaseUrl,
  [string]$PublicKeyPath,
  [string]$OutPath,
  [string]$TemplatePath
)

$ErrorActionPreference = 'Stop'

# Script-relative defaults are resolved here, not in the param block: $PSScriptRoot is empty in the
# param defaults of a [CmdletBinding()] script on Windows PowerShell 5.1.
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($PublicKeyPath)) { $PublicKeyPath = Join-Path $repoRoot 'keys\public-key.xml' }
if ([string]::IsNullOrEmpty($OutPath)) { $OutPath = Join-Path $repoRoot 'dist\BenTechSetup.cmd' }
if ([string]::IsNullOrEmpty($TemplatePath)) { $TemplatePath = Join-Path $repoRoot 'launcher\BenTechSetup.template.cmd' }
# .NET file APIs use the process working directory, not the PowerShell location.
$PublicKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PublicKeyPath)
$OutPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)
$TemplatePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TemplatePath)

$marker = '#__PS__'
$placeholders = @('{{BASE_URL}}', '{{PUBLIC_KEY_XML}}')

function Get-FirstNonAsciiIndex([string]$Text) {
  for ($i = 0; $i -lt $Text.Length; $i++) { if ([int]$Text[$i] -gt 0x7F) { return $i } }
  return -1
}

# --- Template: ASCII bytes only -------------------------------------------------------------------------
$templateBytes = [IO.File]::ReadAllBytes($TemplatePath)
for ($i = 0; $i -lt $templateBytes.Length; $i++) {
  if ($templateBytes[$i] -gt 0x7F) {
    throw ("The launcher template is not ASCII: byte 0x{0:X2} at offset {1} in {2} (a UTF-8 BOM counts)." -f $templateBytes[$i], $i, $TemplatePath)
  }
}
$text = [Text.Encoding]::ASCII.GetString($templateBytes)
foreach ($placeholder in $placeholders) {
  $count = ([regex]::Matches($text, [regex]::Escape($placeholder))).Count
  if ($count -ne 1) { throw "The launcher template must contain $placeholder exactly once (found $count)." }
}

# --- Public key: one line, no single quote, a PUBLIC RSA key ---------------------------------------------
$keyXml = (([IO.File]::ReadAllText($PublicKeyPath) -split "\r\n|\r|\n") | ForEach-Object { $_.Trim() }) -join ''
if ($keyXml.Contains("'")) { throw "The public key XML contains a single quote; it would end the launcher's PowerShell string: $PublicKeyPath" }
if ($keyXml -match "[\r\n]") { throw "The public key XML still contains a newline after collapsing it: $PublicKeyPath" }
if ((Get-FirstNonAsciiIndex $keyXml) -ge 0) { throw "The public key XML is not ASCII: $PublicKeyPath" }
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
try {
  try { $rsa.FromXmlString($keyXml) } catch { throw "Not an RSA key (<RSAKeyValue> XML): $PublicKeyPath ($($_.Exception.Message))" }
  # Embedding a private key would hand it to every customer machine.
  if (-not $rsa.PublicOnly) { throw "Refusing to embed a private key in the launcher: $PublicKeyPath holds private parameters. Use keys\public-key.xml." }
  $keyBits = $rsa.KeySize
} finally {
  $rsa.Dispose()
}
if ($keyBits -lt 3072) { throw "The public key is $keyBits-bit; the signing scheme is RSA-3072: $PublicKeyPath" }

# --- Base URL -------------------------------------------------------------------------------------------
if ($BaseUrl -match "['\r\n]") { throw "-BaseUrl must not contain a single quote or a newline: $BaseUrl" }
$uri = $null
if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'https', 'file') {
  throw "-BaseUrl must be an absolute https:// URL (file:// only for tests): $BaseUrl"
}
if ((Get-FirstNonAsciiIndex $BaseUrl) -ge 0) { throw "-BaseUrl must be ASCII: $BaseUrl" }

# --- Fill in, normalize, check ----------------------------------------------------------------------------
# String.Replace, not -replace: the values are literal text, never regex replacement patterns.
$text = $text.Replace('{{BASE_URL}}', $BaseUrl).Replace('{{PUBLIC_KEY_XML}}', $keyXml)
if ($text.Contains('{{')) {
  $left = ([regex]::Matches($text, '\{\{[^\r\n]*?\}\}') | ForEach-Object { $_.Value }) -join ', '
  throw "The launcher still contains a placeholder after filling it in: $left"
}
$text = $text -replace "\r\n|\r|\n", "`r`n"

$markerLine = "`r`n$marker`r`n"
$markerAt = $text.IndexOf($markerLine)
if ($markerAt -lt 0) { throw "The launcher template has no '$marker' line." }
$psStart = $markerAt + 2
if ($text.LastIndexOf($marker) -ne $psStart) {
  throw "The PowerShell section must not contain '$marker': the cmd part finds that section with LastIndexOf."
}
$cmdLines = @($text.Substring(0, $markerAt) -split "`r`n")
if ($cmdLines[-1] -notmatch '^exit /b\b') { throw "The line before '$marker' must be the cmd part's 'exit /b', so cmd never runs the PowerShell section." }

$psSection = $text.Substring($psStart)
$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($psSection, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
  throw ("The launcher's PowerShell section does not parse:`r`n  " + (($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`r`n  "))
}

$bad = Get-FirstNonAsciiIndex $text
if ($bad -ge 0) { throw ("The launcher is not ASCII: char U+{0:X4} at offset {1}." -f [int]$text[$bad], $bad) }

# --- Write ------------------------------------------------------------------------------------------------
$outDir = Split-Path -Parent $OutPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[IO.File]::WriteAllText($OutPath, $text, (New-Object Text.ASCIIEncoding))
Write-Host "Built $OutPath ($keyBits-bit public key, base URL $BaseUrl)"
