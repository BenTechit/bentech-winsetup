# tools/Sign-File.ps1 - writes a detached signature <Path>.sig over the raw bytes of a file.
#
#   powershell -File tools\Sign-File.ps1 -Path dist\setup.ps1
#
# Throws (non-zero exit) on any problem; a .sig is only written when signing fully succeeded.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Path,
  [string]$PrivateKeyPath = "$env:USERPROFILE\.bentech-winsetup\signing-key.dpapi"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Signing.ps1"

$full = Resolve-SigningPath -Path $Path
if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "File to sign not found: $full" }

$bytes = [IO.File]::ReadAllBytes($full)
$privateXml = Read-PrivateKeyXml -Path $PrivateKeyPath
$signature = New-DetachedSignature -Data $bytes -PrivateKeyXml $privateXml
[IO.File]::WriteAllBytes("$full.sig", $signature)
Write-Host "Signed $full -> $full.sig ($($signature.Length) bytes)"
