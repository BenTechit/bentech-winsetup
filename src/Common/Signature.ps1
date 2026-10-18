function Test-DetachedSignature {
  <#
  .SYNOPSIS
    Verifies a detached RSA signature (PKCS#1 v1.5, SHA-256) over raw bytes.
  .DESCRIPTION
    Returns $true only when the signature is valid for Data under the given public key
    (<RSAKeyValue> XML). Returns $false on ANY failure - bad key XML, wrong-length signature,
    null input, changed data - and never throws. Fail closed: a caller that cannot tell
    "invalid" from "broken" must treat both as "do not run".

    Self-contained on purpose: the launcher inlines this function, so it must not depend on
    any other file or module.

    The parameters are deliberately UNTYPED and not Mandatory. Declared as [byte[]] / [string]
    (or Mandatory), a mistyped, null or missing argument is rejected during parameter binding,
    which happens BEFORE this function's try/catch: the call throws, and under the default
    $ErrorActionPreference = 'Continue' that error is non-fatal, so a caller's
    `if (-not (Test-DetachedSignature ...)) { reject }` is never decided and execution carries
    on. Parameter binding must therefore not be able to fail, so every conversion happens
    inside the try instead.
    Expected types: -Data [byte[]], -Signature [byte[]], -PublicKeyXml [string].
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param($Data, $Signature, $PublicKeyXml)

  try {
    $dataBytes = [byte[]]$Data
    $signatureBytes = [byte[]]$Signature
    $keyXml = [string]$PublicKeyXml
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
      $rsa.FromXmlString($keyXml)
      return [bool]$rsa.VerifyData(
        $dataBytes, $signatureBytes,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
      $rsa.Dispose()
    }
  } catch {
    return $false
  }
}
