# tests/Signature.Tests.ps1
BeforeAll {
  . "$PSScriptRoot\..\src\Common\Signature.ps1"; . "$PSScriptRoot\..\tools\Signing.ps1"
  $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
  $script:priv = $rsa.ToXmlString($true); $script:pub = $rsa.ToXmlString($false)
  $script:data = [byte[]](0xEF,0xBB,0xBF) + [Text.Encoding]::UTF8.GetBytes("Write-Host 'שלום'`r`n")
}
Describe 'detached signatures' {
  It 'verifies a correct signature' { $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv; Test-DetachedSignature -Data $data -Signature $s -PublicKeyXml $pub | Should -BeTrue }
  It 'rejects one changed byte' { $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv; $d2 = $data.Clone(); $d2[5] = $d2[5] -bxor 1; Test-DetachedSignature -Data $d2 -Signature $s -PublicKeyXml $pub | Should -BeFalse }
  It 'rejects another key' { $o = (New-Object Security.Cryptography.RSACryptoServiceProvider 3072).ToXmlString($false); $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv; Test-DetachedSignature -Data $data -Signature $s -PublicKeyXml $o | Should -BeFalse }
  It 'returns false for garbage' { Test-DetachedSignature -Data $data -Signature ([byte[]](1,2,3)) -PublicKeyXml 'nope' | Should -BeFalse }
  It 'signs a 3072-bit key (384-byte signature)' { (New-DetachedSignature -Data $data -PrivateKeyXml $priv).Length | Should -Be 384 }
}

Describe 'detached signature edge cases' {
  It 'rejects a corrupted signature under the right key' {
    $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv
    $s2 = $s.Clone(); $s2[10] = $s2[10] -bxor 0x80
    Test-DetachedSignature -Data $data -Signature $s2 -PublicKeyXml $pub | Should -BeFalse
  }
  It 'rejects a truncated signature under the right key' {
    $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv
    Test-DetachedSignature -Data $data -Signature $s[0..99] -PublicKeyXml $pub | Should -BeFalse
  }
  It 'never throws on null or empty input, it returns false' {
    { Test-DetachedSignature -Data $null -Signature $null -PublicKeyXml $null } | Should -Not -Throw
    Test-DetachedSignature -Data $null -Signature $null -PublicKeyXml $null | Should -BeFalse
    Test-DetachedSignature -Data ([byte[]]@()) -Signature ([byte[]]@()) -PublicKeyXml '' | Should -BeFalse
    Test-DetachedSignature -Data $data -Signature ([byte[]]@()) -PublicKeyXml $pub | Should -BeFalse
  }
  # Fail closed at PARAMETER BINDING too. With typed params, a mistyped argument throws before the
  # function body (so before its try/catch); under the default $ErrorActionPreference = 'Continue'
  # that error is non-fatal and the caller's `if (-not (Test-DetachedSignature ...))` is never
  # decided, so a check-then-run caller would carry on. The result must be a real [bool] $false.
  It 'returns a real $false (no binding error, no $null) for a wrongly typed <Arg> under EAP <Eap>' -ForEach @(
    foreach ($eap in 'Continue', 'Stop') {
      @{ Arg = 'Data (string)';       Eap = $eap; Splat = @{ Data = 'abc' } }
      @{ Arg = 'Data (hashtable)';    Eap = $eap; Splat = @{ Data = @{ a = 1 } } }
      @{ Arg = 'Data (int)';          Eap = $eap; Splat = @{ Data = 5 } }
      @{ Arg = 'Signature (string)';  Eap = $eap; Splat = @{ Signature = 'abc' } }
      @{ Arg = 'Signature (hashtable)'; Eap = $eap; Splat = @{ Signature = @{ a = 1 } } }
      @{ Arg = 'Signature (object[] of strings)'; Eap = $eap; Splat = @{ Signature = @('x', 'y') } }
      @{ Arg = 'PublicKeyXml (hashtable)'; Eap = $eap; Splat = @{ PublicKeyXml = @{ a = 1 } } }
    }
  ) {
    $args2 = @{ Data = $data; Signature = (New-DetachedSignature -Data $data -PrivateKeyXml $priv); PublicKeyXml = $pub }
    foreach ($k in $Splat.Keys) { $args2[$k] = $Splat[$k] }
    $prev = $ErrorActionPreference
    try {
      $ErrorActionPreference = $Eap
      # 2>&1 captures anything the call leaks to the error stream; a binding error would show up
      # here as an ErrorRecord (Continue) or be thrown (Stop), instead of the single [bool].
      $out = @(Test-DetachedSignature @args2 2>&1)
    } finally { $ErrorActionPreference = $prev }
    $out.Count | Should -Be 1 -Because 'exactly one output: the verdict, no leaked error record'
    ($out[0] -is [bool]) | Should -BeTrue -Because 'a binding error would leave no verdict and the caller would not reject'
    $out[0] | Should -Be $false
  }
  It 'returns false when an argument is omitted entirely, under EAP Stop' {
    $prev = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Stop'
      $r1 = Test-DetachedSignature
      $r2 = Test-DetachedSignature -Data $data
      $r3 = Test-DetachedSignature -Data $data -Signature (New-DetachedSignature -Data $data -PrivateKeyXml $priv)
    } finally { $ErrorActionPreference = $prev }
    foreach ($r in $r1, $r2, $r3) { ($r -is [bool]) | Should -BeTrue; $r | Should -Be $false }
  }
  It 'still accepts a signature that arrives as an object[] of bytes (pipeline-unrolled)' {
    $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv
    $unrolled = [object[]]@($s)
    Test-DetachedSignature -Data $data -Signature $unrolled -PublicKeyXml $pub | Should -BeTrue
  }
  It 'returns a real byte[] (not an object[])' {
    (New-DetachedSignature -Data $data -PrivateKeyXml $priv) -is [byte[]] | Should -BeTrue
  }
  It 'refuses to sign with a public-only key' {
    { New-DetachedSignature -Data $data -PrivateKeyXml $pub } | Should -Throw '*no private parameters*'
  }
}

Describe 'DPAPI private key file' {
  BeforeAll { $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('bw-sig-' + [guid]::NewGuid().ToString('N')) }
  AfterAll { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
  It 'round-trips the key XML and creates the missing folder' {
    $p = Join-Path $tmp 'nested\deeper\key.dpapi'
    Save-PrivateKeyXml -Path $p -PrivateKeyXml $priv
    Test-Path -LiteralPath $p | Should -BeTrue
    Read-PrivateKeyXml -Path $p | Should -BeExactly $priv
  }
  It 'stores the key protected, not as readable XML' {
    $p = Join-Path $tmp 'nested\deeper\key.dpapi'
    [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($p)) | Should -Not -BeLike '*RSAKeyValue*'
  }
  It 'throws a clear error when the key file is missing' {
    { Read-PrivateKeyXml -Path (Join-Path $tmp 'nope.dpapi') } | Should -Throw '*Signing key not found*'
  }
  It 'throws a clear error when the file is not a DPAPI blob' {
    $p = Join-Path $tmp 'junk.dpapi'; [IO.File]::WriteAllBytes($p, [byte[]](1,2,3,4,5))
    { Read-PrivateKeyXml -Path $p } | Should -Throw '*Cannot unprotect*'
  }
}

Describe 'tools/New-SigningKey.ps1' {
  BeforeAll {
    $script:tool = Join-Path $PSScriptRoot '..\tools\New-SigningKey.ps1'
    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('bw-newkey-' + [guid]::NewGuid().ToString('N'))
    $script:privPath = Join-Path $tmp 'store\signing-key.dpapi'
    $script:pubPath = Join-Path $tmp 'keys\public-key.xml'
    $script:bakPath = Join-Path $tmp 'backup\key-BACKUP.xml'
    function script:Invoke-NewKey([string[]]$ToolArgs) {
      $ErrorActionPreference = 'Continue'
      $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool @ToolArgs 2>&1 | Out-String
      @{ Code = $LASTEXITCODE; Out = $out }
    }
    $script:first = Invoke-NewKey @('-PrivateKeyPath', $privPath, '-PublicKeyOut', $pubPath, '-BackupPath', $bakPath)
  }
  AfterAll { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }

  It 'succeeds and creates the DPAPI key, the public key and the backup' {
    $first.Code | Should -Be 0
    Test-Path -LiteralPath $privPath | Should -BeTrue
    Test-Path -LiteralPath $pubPath | Should -BeTrue
    Test-Path -LiteralPath $bakPath | Should -BeTrue
  }
  It 'writes a 3072-bit public key as ASCII XML without a BOM and without private parts' {
    $bytes = [IO.File]::ReadAllBytes($pubPath)
    $bytes[0] | Should -Be ([byte][char]'<')
    @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    $xml = [Text.Encoding]::ASCII.GetString($bytes)
    $xml | Should -BeLike '<RSAKeyValue>*'
    $xml | Should -Not -BeLike '*<D>*'
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.FromXmlString($xml); $rsa.KeySize | Should -Be 3072 } finally { $rsa.Dispose() }
  }
  It 'stores a private key that signs and verifies against the written public key' {
    $k = Read-PrivateKeyXml -Path $privPath
    $s = New-DetachedSignature -Data $data -PrivateKeyXml $k
    $s.Length | Should -Be 384
    Test-DetachedSignature -Data $data -Signature $s -PublicKeyXml ([IO.File]::ReadAllText($pubPath)) | Should -BeTrue
  }
  It 'writes a backup that is the same private key' {
    [IO.File]::ReadAllText($bakPath) | Should -BeExactly (Read-PrivateKeyXml -Path $privPath)
  }
  It 'never prints private key material' {
    $k = Read-PrivateKeyXml -Path $privPath
    foreach ($tag in 'D', 'P', 'Q', 'DP', 'DQ', 'InverseQ') {
      $m = [regex]::Match($k, "<$tag>([^<]+)</$tag>")
      $m.Success | Should -BeTrue
      $first.Out | Should -Not -BeLike "*$($m.Groups[1].Value)*"
    }
    $first.Out | Should -Not -BeLike '*<RSAKeyValue>*'
  }
  It 'prints the next steps: back up the private key and commit the public key' {
    $first.Out | Should -BeLike '*back up*'
    $first.Out | Should -BeLike '*commit*public-key.xml*'
  }
  It 'refuses to overwrite an existing private key: exit 1, nothing changed' {
    $privBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($privPath))
    $pubBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pubPath))
    $r = Invoke-NewKey @('-PrivateKeyPath', $privPath, '-PublicKeyOut', (Join-Path $tmp 'keys\other.xml'))
    $r.Code | Should -Be 1
    $r.Out | Should -BeLike '*already exists*'
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($privPath)) | Should -BeExactly $privBefore
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($pubPath)) | Should -BeExactly $pubBefore
    Test-Path -LiteralPath (Join-Path $tmp 'keys\other.xml') | Should -BeFalse
  }
  It 'refuses to replace an existing public key (would break every launcher) and creates no private key' {
    $newPriv = Join-Path $tmp 'store2\signing-key.dpapi'
    $r = Invoke-NewKey @('-PrivateKeyPath', $newPriv, '-PublicKeyOut', $pubPath)
    $r.Code | Should -Be 1
    $r.Out | Should -BeLike '*already exists*'
    Test-Path -LiteralPath $newPriv | Should -BeFalse
  }
  It 'defaults the public key to keys\public-key.xml next to the tools folder (resolved from the script location)' {
    # $PSScriptRoot is empty inside param() defaults of a [CmdletBinding()] script on 5.1, so this
    # must run with NO -PublicKeyOut. Use a copy of the tool tree so the real repo is not touched.
    $tree = Join-Path $tmp 'tree'
    New-Item -ItemType Directory -Path "$tree\tools", "$tree\src\Common" -Force | Out-Null
    Copy-Item -LiteralPath $tool, (Join-Path $PSScriptRoot '..\tools\Signing.ps1') -Destination "$tree\tools"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\src\Common\Signature.ps1') -Destination "$tree\src\Common"
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$tree\tools\New-SigningKey.ps1" -PrivateKeyPath "$tmp\store4\signing-key.dpapi" 2>&1 | Out-String
    $LASTEXITCODE | Should -Be 0 -Because $out
    Test-Path -LiteralPath "$tree\keys\public-key.xml" | Should -BeTrue
  }
  It 'refuses to replace an existing backup file and creates no private key' {
    $newPriv = Join-Path $tmp 'store3\signing-key.dpapi'
    $r = Invoke-NewKey @('-PrivateKeyPath', $newPriv, '-PublicKeyOut', (Join-Path $tmp 'keys3\public-key.xml'), '-BackupPath', $bakPath)
    $r.Code | Should -Be 1
    Test-Path -LiteralPath $newPriv | Should -BeFalse
  }
}

Describe 'tools/Sign-File.ps1' {
  BeforeAll {
    $script:tool = Join-Path $PSScriptRoot '..\tools\Sign-File.ps1'
    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('bw-signfile-' + [guid]::NewGuid().ToString('N'))
    $script:keyPath = Join-Path $tmp 'k\signing-key.dpapi'
    Save-PrivateKeyXml -Path $keyPath -PrivateKeyXml $priv
    $script:file = Join-Path $tmp 'setup.ps1'
    [IO.File]::WriteAllBytes($file, $data)
  }
  AfterAll { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }

  It 'writes a .sig next to the file that verifies over the raw file bytes' {
    & $tool -Path $file -PrivateKeyPath $keyPath *> $null
    Test-Path -LiteralPath "$file.sig" | Should -BeTrue
    $sig = [IO.File]::ReadAllBytes("$file.sig")
    $sig.Length | Should -Be 384
    Test-DetachedSignature -Data ([IO.File]::ReadAllBytes($file)) -Signature $sig -PublicKeyXml $pub | Should -BeTrue
  }
  It 'produces a signature that no longer verifies once the file changes' {
    $other = Join-Path $tmp 'other.ps1'; [IO.File]::WriteAllBytes($other, $data)
    & $tool -Path $other -PrivateKeyPath $keyPath *> $null
    [IO.File]::AppendAllText($other, ' ')
    Test-DetachedSignature -Data ([IO.File]::ReadAllBytes($other)) -Signature ([IO.File]::ReadAllBytes("$other.sig")) -PublicKeyXml $pub | Should -BeFalse
  }
  It 'throws when the file to sign does not exist' {
    { & $tool -Path (Join-Path $tmp 'missing.ps1') -PrivateKeyPath $keyPath } | Should -Throw '*File to sign not found*'
  }
  It 'throws when the private key file does not exist, and writes no .sig' {
    $f2 = Join-Path $tmp 'nokey.ps1'; [IO.File]::WriteAllBytes($f2, $data)
    { & $tool -Path $f2 -PrivateKeyPath (Join-Path $tmp 'none.dpapi') } | Should -Throw '*Signing key not found*'
    Test-Path -LiteralPath "$f2.sig" | Should -BeFalse
  }
}
