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
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][byte[]]$Data,
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][byte[]]$Signature,
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$PublicKeyXml
  )

  try {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
      $rsa.FromXmlString($PublicKeyXml)
      return [bool]$rsa.VerifyData(
        $Data, $Signature,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
      $rsa.Dispose()
    }
  } catch {
    return $false
  }
}
