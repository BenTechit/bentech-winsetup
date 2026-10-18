# tools/New-SigningKey.ps1 - one-time generation of the RSA-3072 signing key (developer machine only).
#
#   powershell -File tools\New-SigningKey.ps1 -BackupPath "$env:USERPROFILE\Desktop\bentech-signing-key-BACKUP.xml"
#
# - Private key -> DPAPI-protected (CurrentUser) file outside the repo. NEVER printed.
# - Public key  -> keys\public-key.xml (ASCII, no BOM), to be committed.
# - Refuses to overwrite an existing private key, public key or backup: replacing the key means
#   every launcher already handed out stops working, so it must be a deliberate manual act.
[CmdletBinding()]
param(
  [string]$PrivateKeyPath = "$env:USERPROFILE\.bentech-winsetup\signing-key.dpapi",
  [string]$PublicKeyOut,   # default: <repo>\keys\public-key.xml, resolved below
  [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Signing.ps1"
. "$PSScriptRoot\..\src\Common\Signature.ps1"

# Not a param() default: on Windows PowerShell 5.1, $PSScriptRoot is empty inside the param()
# block of a [CmdletBinding()] script, but valid here in the body.
if (-not $PublicKeyOut) { $PublicKeyOut = Join-Path (Split-Path -Parent $PSScriptRoot) 'keys\public-key.xml' }

function Stop-WithError([string]$Message) {
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

$privFull = Resolve-SigningPath -Path $PrivateKeyPath
$pubFull = Resolve-SigningPath -Path $PublicKeyOut
$bakFull = if ($BackupPath) { Resolve-SigningPath -Path $BackupPath } else { $null }

# Refuse BEFORE generating anything, so a refusal leaves the disk exactly as it was.
if (Test-Path -LiteralPath $privFull) {
  Stop-WithError "A private key already exists at $privFull. Refusing to overwrite it. If you really want a new key (this invalidates every launcher already handed out), move that file away yourself first."
}
if (Test-Path -LiteralPath $pubFull) {
  Stop-WithError "A public key already exists at $pubFull. Refusing to overwrite it, because every launcher embeds it. Delete it yourself if you really are rotating the key."
}
if ($bakFull -and (Test-Path -LiteralPath $bakFull)) {
  Stop-WithError "A backup file already exists at $bakFull. Refusing to overwrite it. Move or delete it first."
}

$created = New-Object System.Collections.Generic.List[string]
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
try {
  $privateXml = $rsa.ToXmlString($true)
  $publicXml = $rsa.ToXmlString($false)

  try {
    if ($bakFull) {
      $bakDir = Split-Path -Parent $bakFull
      if ($bakDir -and -not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
      [IO.File]::WriteAllText($bakFull, $privateXml, (New-Object Text.ASCIIEncoding))
      $created.Add($bakFull)
    }

    Save-PrivateKeyXml -Path $privFull -PrivateKeyXml $privateXml
    $created.Add($privFull)

    # Prove the stored key is readable and matches the public key before declaring success.
    $probe = [Text.Encoding]::UTF8.GetBytes('bentech-winsetup key self-test')
    $sig = New-DetachedSignature -Data $probe -PrivateKeyXml (Read-PrivateKeyXml -Path $privFull)
    if (-not (Test-DetachedSignature -Data $probe -Signature $sig -PublicKeyXml $publicXml)) {
      throw 'Self-test failed: the stored private key does not verify against the new public key.'
    }

    $pubDir = Split-Path -Parent $pubFull
    if ($pubDir -and -not (Test-Path -LiteralPath $pubDir)) { New-Item -ItemType Directory -Path $pubDir -Force | Out-Null }
    [IO.File]::WriteAllText($pubFull, $publicXml, (New-Object Text.ASCIIEncoding))
    $created.Add($pubFull)
  } catch {
    # Leave nothing half-made behind: a stray private key would make every re-run refuse.
    foreach ($f in $created) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Write-Host "ERROR: key generation failed and was rolled back: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
  }
} finally {
  $rsa.Dispose()
}

$check = New-Object Security.Cryptography.RSACryptoServiceProvider
try { $check.FromXmlString($publicXml); $bits = $check.KeySize } finally { $check.Dispose() }

Write-Host ''
Write-Host "Signing key created ($bits-bit RSA)." -ForegroundColor Green
Write-Host "  Private key (DPAPI, this Windows user on this PC only): $privFull"
Write-Host "  Public key: $pubFull"
if ($bakFull) { Write-Host "  Backup (PLAIN TEXT private key): $bakFull" }
Write-Host ''
Write-Host 'NEXT STEPS' -ForegroundColor Yellow
if ($bakFull) {
  Write-Host "  1. Back up the private key NOW: move $bakFull into your password manager, then DELETE the file."
} else {
  Write-Host '  1. Back up the private key NOW. No -BackupPath was given, so the key exists only in the DPAPI file,'
  Write-Host '     which cannot be read on another PC or by another Windows user. Re-run is refused, so export it'
  Write-Host '     deliberately (Read-PrivateKeyXml in tools\Signing.ps1) and store it in your password manager.'
}
Write-Host '     If the key is lost, every launcher on every USB stick has to be rebuilt.'
Write-Host "  2. Commit the public key: git add keys/public-key.xml (it is the only part that goes in the repo)."
Write-Host '  3. Never commit the private key or the backup file.'
