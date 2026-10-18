# tools/Signing.ps1 - signing helpers (developer machine only; never shipped to target PCs).
# Scheme: RSA-3072, PKCS#1 v1.5, SHA-256, detached signature over the raw bytes.
# The private key lives DPAPI-protected (CurrentUser) outside the repo.

function Resolve-SigningPath {
  # .NET file APIs use the process working directory, not the PowerShell location, so a relative
  # path must be resolved through the PowerShell session first.
  param([Parameter(Mandatory)][string]$Path)
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function New-DetachedSignature {
  <#
  .SYNOPSIS
    Signs raw bytes with a private key (<RSAKeyValue> XML incl. private parameters).
  .OUTPUTS
    byte[] - a 384-byte signature for a 3072-bit key.
  #>
  [CmdletBinding()]
  [OutputType([byte[]])]
  param(
    [Parameter(Mandatory)][byte[]]$Data,
    [Parameter(Mandatory)][string]$PrivateKeyXml
  )

  $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
  try {
    $rsa.FromXmlString($PrivateKeyXml)
    if ($rsa.PublicOnly) { throw 'The supplied key XML has no private parameters; cannot sign.' }
    $signature = $rsa.SignData(
      $Data,
      [Security.Cryptography.HashAlgorithmName]::SHA256,
      [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    , $signature   # leading comma: keep the byte[] intact instead of unrolling it into the pipeline
  } finally {
    $rsa.Dispose()
  }
}

function Save-PrivateKeyXml {
  <#
  .SYNOPSIS
    Writes the private key XML to disk protected with DPAPI (CurrentUser scope).
  .DESCRIPTION
    The file holds the DPAPI-protected bytes of the UTF-8 key XML. Only the same Windows user
    on the same machine can read it back. Creates the destination folder when missing.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$PrivateKeyXml
  )

  Add-Type -AssemblyName System.Security
  $full = Resolve-SigningPath -Path $Path
  $dir = Split-Path -Parent $full
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $plain = [Text.Encoding]::UTF8.GetBytes($PrivateKeyXml)
  $protected = [Security.Cryptography.ProtectedData]::Protect(
    $plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  [IO.File]::WriteAllBytes($full, $protected)
}

function Read-PrivateKeyXml {
  <#
  .SYNOPSIS
    Reads a DPAPI-protected private key file (see Save-PrivateKeyXml) back into key XML.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Path)

  Add-Type -AssemblyName System.Security
  $full = Resolve-SigningPath -Path $Path
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    throw "Signing key not found: $full (create it with tools\New-SigningKey.ps1)"
  }
  $protected = [IO.File]::ReadAllBytes($full)
  try {
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
      $protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  } catch {
    throw "Cannot unprotect signing key '$full'. It can only be read by the Windows user that created it, on the same PC. ($($_.Exception.Message))"
  }
  [Text.Encoding]::UTF8.GetString($plain)
}
