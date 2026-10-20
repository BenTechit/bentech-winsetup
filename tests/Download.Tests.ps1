# tests/Download.Tests.ps1
BeforeAll { . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Activity.ps1"; . "$PSScriptRoot\..\src\Common\Process.ps1"; . "$PSScriptRoot\..\src\Common\Download.ps1" }

Describe 'downloads and signatures' {
  It 'copies a file:// url' { 'x' | Set-Content "$TestDrive\src.txt"; Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination "$TestDrive\dst.txt" -BackoffSeconds 0 | Should -Exist }
  It 'throws after retries' { { Get-RemoteFile -Url ([uri]"$TestDrive\missing.txt").AbsoluteUri -Destination "$TestDrive\d2.txt" -Retries 2 -BackoffSeconds 0 } | Should -Throw '*after 2 attempts*' }
  It 'finds the newest HPIA link in the fixture' { Find-LatestLink -Html (Get-Content "$PSScriptRoot\fixtures\hpia.html" -Raw) -Pattern 'https://hpia\.hpcloud\.hp\.com/downloads/hpia/hp-hpia-[0-9.]+\.exe' | Should -Be 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.7.exe' }
  It 'accepts a Microsoft-signed binary' { Test-FileSignature -Path "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -AllowedSigners @('Microsoft') | Should -BeTrue }
  It 'rejects the wrong signer' { Test-FileSignature -Path "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -AllowedSigners @('Google LLC') | Should -BeFalse }
  It 'rejects an unsigned file' { 'x' | Set-Content "$TestDrive\u.exe"; Test-FileSignature -Path "$TestDrive\u.exe" -AllowedSigners @('Microsoft') | Should -BeFalse }
}

Describe 'Get-RemoteFile' {
  BeforeAll {
    $script:stallDefaults = @($script:DownloadStallFirstByteSeconds, $script:DownloadStallSeconds)
    # A fake WebClient for the stall tests. DownloadFileTaskAsync writes $script:fakeBytes bytes to the
    # .part file (none when 0) and returns a task that never completes; CancelAsync is counted.
    function New-StallingClient {
      $c = [pscustomobject]@{}
      $c | Add-Member ScriptMethod DownloadFileTaskAsync {
        param($u, $p)
        if ($script:fakeBytes -gt 0) { [IO.File]::WriteAllBytes($p, (New-Object byte[] $script:fakeBytes)) }
        (New-Object 'Threading.Tasks.TaskCompletionSource[object]').Task
      }
      $c | Add-Member ScriptMethod CancelAsync { $script:cancels++ }
      $c | Add-Member ScriptMethod Dispose { }
      $c
    }
  }
  BeforeEach { 'payload' | Set-Content "$TestDrive\src.txt" }
  AfterEach { $script:DownloadStallFirstByteSeconds, $script:DownloadStallSeconds = $script:stallDefaults }
  It 'returns the destination path and copies the content' {
    $dest = "$TestDrive\out1.txt"
    Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination $dest -BackoffSeconds 0 | Should -Be $dest
    (Get-Content $dest -Raw).Trim() | Should -Be 'payload'
  }
  It 'creates the destination directory when it is missing' {
    $dest = "$TestDrive\new\deeper\out2.txt"
    Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination $dest -BackoffSeconds 0 | Out-Null
    $dest | Should -Exist
  }
  It 'leaves no .part file after a successful download' {
    $dest = "$TestDrive\out3.txt"
    Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination $dest -BackoffSeconds 0 | Out-Null
    "$dest.part" | Should -Not -Exist
  }
  It 'replaces an existing destination file and a stale .part' {
    $dest = "$TestDrive\out4.txt"
    'old' | Set-Content $dest; 'stale' | Set-Content "$dest.part"
    Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination $dest -BackoffSeconds 0 | Out-Null
    (Get-Content $dest -Raw).Trim() | Should -Be 'payload'
    "$dest.part" | Should -Not -Exist
  }
  It 'removes the .part file and creates no destination when every attempt fails' {
    $dest = "$TestDrive\out5.txt"
    'half-a-download' | Set-Content "$dest.part"
    { Get-RemoteFile -Url ([uri]"$TestDrive\missing.txt").AbsoluteUri -Destination $dest -Retries 2 -BackoffSeconds 0 } | Should -Throw
    "$dest.part" | Should -Not -Exist
    $dest | Should -Not -Exist
  }
  It 'does not touch an existing destination when the download fails' {
    $dest = "$TestDrive\out6.txt"; 'keep me' | Set-Content $dest
    { Get-RemoteFile -Url ([uri]"$TestDrive\missing.txt").AbsoluteUri -Destination $dest -Retries 1 -BackoffSeconds 0 } | Should -Throw
    (Get-Content $dest -Raw).Trim() | Should -Be 'keep me'
  }
  It 'throws the exact message, naming the attempts and the url' {
    $url = ([uri]"$TestDrive\missing.txt").AbsoluteUri
    $err = $null
    try { Get-RemoteFile -Url $url -Destination "$TestDrive\out7.txt" -Retries 3 -BackoffSeconds 0 } catch { $err = $_ }
    $err.Exception.Message | Should -BeExactly "download failed after 3 attempts: $url"
  }
  It 'waits BackoffSeconds * attempt between tries, and not after the last one' {
    Mock Start-Sleep { }
    { Get-RemoteFile -Url ([uri]"$TestDrive\missing.txt").AbsoluteUri -Destination "$TestDrive\out8.txt" -Retries 3 -BackoffSeconds 5 } | Should -Throw
    Should -Invoke Start-Sleep -Times 2 -Exactly
    Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 5000 }
    Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 10000 }
  }
  It 'forces TLS 1.2' {
    $saved = [Net.ServicePointManager]::SecurityProtocol
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3 -bor [Net.SecurityProtocolType]::Tls
      Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination "$TestDrive\out9.txt" -BackoffSeconds 0 | Out-Null
      [Net.ServicePointManager]::SecurityProtocol | Should -Be ([Net.SecurityProtocolType]::Tls12)
    } finally { [Net.ServicePointManager]::SecurityProtocol = $saved }
  }
  It 'gives up on a download that never finishes, cancels it, and reports the attempts' {
    $script:cancels = 0
    Mock New-SetupWebClient {
      $c = [pscustomobject]@{}
      $c | Add-Member ScriptMethod DownloadFileTaskAsync { param($u, $p) (New-Object 'Threading.Tasks.TaskCompletionSource[object]').Task }
      $c | Add-Member ScriptMethod CancelAsync { $script:cancels++ }
      $c | Add-Member ScriptMethod Dispose { }
      $c }
    $err = $null
    try { Get-RemoteFile -Url 'https://example.invalid/x.exe' -Destination "$TestDrive\x.exe" -Retries 1 -BackoffSeconds 0 -TimeoutMinutes 0.001 } catch { $err = $_ }
    $err.Exception.Message | Should -BeExactly 'download failed after 1 attempts: https://example.invalid/x.exe'
    $err.Exception.InnerException.Message | Should -Match 'timed out'
    $script:cancels | Should -Be 1
  }
  It 'ticks while downloading and still copies the file' {
    # The fake download writes the file and finishes on its own after 300 ms, so the loop must wait.
    Mock New-SetupWebClient {
      $c = [pscustomobject]@{}
      $c | Add-Member ScriptMethod DownloadFileTaskAsync { param($u, $p) [IO.File]::WriteAllText($p, 'done'); [Threading.Tasks.Task]::Delay(300) }
      $c | Add-Member ScriptMethod CancelAsync { }
      $c | Add-Member ScriptMethod Dispose { }
      $c }
    $script:ticks = 0; Register-SetupTick -Context @{} -Handler { $script:ticks++ }
    try { Get-RemoteFile -Url 'https://example.invalid/t.exe' -Destination "$TestDrive\t.txt" -BackoffSeconds 0 | Should -Exist } finally { Unregister-SetupTick }
    $script:ticks | Should -BeGreaterThan 0
  }
  It 'gives up on a download that receives nothing within the first-byte limit, and cancels it' {
    $script:DownloadStallFirstByteSeconds = 0.3; $script:DownloadStallSeconds = 60
    $script:cancels = 0; $script:fakeBytes = 0
    Mock New-SetupWebClient { New-StallingClient }
    $err = $null; $clock = [Diagnostics.Stopwatch]::StartNew()
    try { Get-RemoteFile -Url 'https://example.invalid/s.exe' -Destination "$TestDrive\s.exe" -Retries 1 -BackoffSeconds 0 -TimeoutMinutes 0.5 } catch { $err = $_ }
    $clock.Stop()
    $err.Exception.Message | Should -BeExactly 'download failed after 1 attempts: https://example.invalid/s.exe'
    $err.Exception.InnerException.Message | Should -BeExactly 'download stalled for 0.3 s: https://example.invalid/s.exe'
    $script:cancels | Should -Be 1
    $clock.Elapsed.TotalSeconds | Should -BeLessThan 15     # the 30 s deadline was not what ended it
    "$TestDrive\s.exe" | Should -Not -Exist
  }
  It 'uses the between-bytes stall limit once bytes have arrived, on every attempt' {
    $script:DownloadStallFirstByteSeconds = 60; $script:DownloadStallSeconds = 0.4
    $script:cancels = 0; $script:fakeBytes = 5
    Mock New-SetupWebClient { New-StallingClient }
    $err = $null
    try { Get-RemoteFile -Url 'https://example.invalid/s2.exe' -Destination "$TestDrive\s2.exe" -Retries 2 -BackoffSeconds 0 -TimeoutMinutes 0.5 } catch { $err = $_ }
    $err.Exception.Message | Should -BeExactly 'download failed after 2 attempts: https://example.invalid/s2.exe'
    $err.Exception.InnerException.Message | Should -BeExactly 'download stalled for 0.4 s: https://example.invalid/s2.exe'
    $script:cancels | Should -Be 2       # every attempt was cancelled: the retries apply
    "$TestDrive\s2.exe.part" | Should -Not -Exist
  }
  It 'does not give up on a slow download whose .part file keeps growing' {
    if (-not ('BenTechTests.TrickleDownload' -as [type])) {
      Add-Type -TypeDefinition @'
namespace BenTechTests {
  public static class TrickleDownload {
    // A slow download that keeps moving: appends one byte to path every gapMs, count times, then completes.
    public static System.Threading.Tasks.Task Start(string path, int count, int gapMs) {
      return System.Threading.Tasks.Task.Run(() => {
        for (int i = 0; i < count; i++) {
          System.Threading.Thread.Sleep(gapMs);
          using (var fs = new System.IO.FileStream(path, System.IO.FileMode.Append, System.IO.FileAccess.Write, System.IO.FileShare.ReadWrite)) { fs.WriteByte(65); }
        }
      });
    }
  }
}
'@
    }
    # 20 bytes, 100 ms apart: 2 s in all, twice the 1 s stall limit, but the file never stands still for 1 s.
    $script:DownloadStallFirstByteSeconds = 1; $script:DownloadStallSeconds = 1
    $script:cancels = 0
    Mock New-SetupWebClient {
      $c = [pscustomobject]@{}
      $c | Add-Member ScriptMethod DownloadFileTaskAsync { param($u, $p) [BenTechTests.TrickleDownload]::Start($p, 20, 100) }
      $c | Add-Member ScriptMethod CancelAsync { $script:cancels++ }
      $c | Add-Member ScriptMethod Dispose { }
      $c }
    $out = Get-RemoteFile -Url 'https://example.invalid/slow.bin' -Destination "$TestDrive\slow.bin" -Retries 1 -BackoffSeconds 0 -TimeoutMinutes 0.5
    $out | Should -Exist
    (Get-Item -LiteralPath $out).Length | Should -Be 20
    $script:cancels | Should -Be 0
  }
  It 'gives a stalled download 100 s for its first byte and 300 s between bytes' {
    $script:stallDefaults | Should -Be @(100, 300)
  }
  It 'shows its timeout as the wait limit while it downloads, and removes it after' {
    Clear-SetupNow
    $script:limits = New-Object System.Collections.ArrayList
    Mock New-SetupWebClient {
      $c = [pscustomobject]@{}
      $c | Add-Member ScriptMethod DownloadFileTaskAsync {
        param($u, $p)
        [void]$script:limits.Add((Get-SetupNow).Wait.LimitMinutes)
        [IO.File]::WriteAllText($p, 'done')
        $tcs = New-Object 'Threading.Tasks.TaskCompletionSource[object]'; $tcs.SetResult($null); $tcs.Task
      }
      $c | Add-Member ScriptMethod CancelAsync { }
      $c | Add-Member ScriptMethod Dispose { }
      $c }
    Get-RemoteFile -Url 'https://example.invalid/y.exe' -Destination "$TestDrive\y.exe" -BackoffSeconds 0 -TimeoutMinutes 12 | Should -Exist
    @($script:limits) | Should -Be @(12)
    (Get-SetupNow).Wait | Should -BeNullOrEmpty
  }
}

Describe 'Get-RemoteText' {
  It 'returns UTF-8 text without the BOM' {
    $text = "שלום world`r`nline2"
    [IO.File]::WriteAllText("$TestDrive\t.txt", $text, (New-Object Text.UTF8Encoding $true))
    Get-RemoteText -Url ([uri]"$TestDrive\t.txt").AbsoluteUri | Should -BeExactly $text
  }
  It 'returns UTF-8 text that has no BOM' {
    $text = 'תודה'
    [IO.File]::WriteAllText("$TestDrive\t2.txt", $text, (New-Object Text.UTF8Encoding $false))
    Get-RemoteText -Url ([uri]"$TestDrive\t2.txt").AbsoluteUri | Should -BeExactly $text
  }
  It 'throws the exact message after the retries' {
    $url = ([uri]"$TestDrive\nothing.txt").AbsoluteUri
    $err = $null
    try { Get-RemoteText -Url $url -Retries 2 -BackoffSeconds 0 } catch { $err = $_ }
    $err.Exception.Message | Should -BeExactly "download failed after 2 attempts: $url"
  }
}

Describe 'Find-LatestLink' {
  BeforeAll { $script:html = Get-Content "$PSScriptRoot\fixtures\hpia.html" -Raw }
  It 'returns the first match in document order, not the highest version' {
    $html2 = '<a href="x/app-1.0.exe"></a><a href="x/app-9.0.exe"></a>'
    Find-LatestLink -Html $html2 -Pattern 'x/app-[0-9.]+\.exe' | Should -Be 'x/app-1.0.exe'
  }
  It 'skips matches that the exclude pattern matches' {
    Find-LatestLink -Html $html -Pattern 'https://hpia\.hpcloud\.hp\.com/downloads/hpia/hp-hpia-[0-9.]+\.exe' -ExcludePattern '5\.3\.7' |
      Should -Be 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.6.exe'
  }
  It 'returns $null when the pattern does not match' {
    Find-LatestLink -Html $html -Pattern 'https://example\.invalid/[a-z]+\.exe' | Should -BeNullOrEmpty
  }
  It 'returns $null when the exclude pattern rules out every match' {
    Find-LatestLink -Html $html -Pattern 'hp-hpia-[0-9.]+\.exe' -ExcludePattern 'hpia' | Should -BeNullOrEmpty
  }
  It 'returns $null for empty html' {
    Find-LatestLink -Html '' -Pattern 'anything' | Should -BeNullOrEmpty
  }
  It 'matches case-insensitively' {
    Find-LatestLink -Html '<a href="HTTPS://X.COM/A.EXE">' -Pattern 'https://x\.com/a\.exe' | Should -Be 'HTTPS://X.COM/A.EXE'
  }
}

Describe 'Test-FileSignature' {
  BeforeAll { $script:ps = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }
  It 'returns $false for a missing file without throwing' {
    { Test-FileSignature -Path "$TestDrive\does-not-exist.exe" -AllowedSigners @('Microsoft') } | Should -Not -Throw
    Test-FileSignature -Path "$TestDrive\does-not-exist.exe" -AllowedSigners @('Microsoft') | Should -BeFalse
  }
  It 'accepts the file when any one of several allowed signers matches' {
    Test-FileSignature -Path $ps -AllowedSigners @('Google LLC', 'Microsoft') | Should -BeTrue
  }
  It 'returns $false when no signer is allowed' {
    Test-FileSignature -Path $ps -AllowedSigners @() | Should -BeFalse
  }
  It 'does not let an empty signer string match everything' {
    Test-FileSignature -Path $ps -AllowedSigners @('') | Should -BeFalse
  }
  It 'treats the signer as literal text, not a wildcard' {
    Test-FileSignature -Path $ps -AllowedSigners @('*') | Should -BeFalse
  }
  It 'returns a bool' {
    (Test-FileSignature -Path $ps -AllowedSigners @('Microsoft')) -is [bool] | Should -BeTrue
  }
  Context 'the signature status must be Valid' {
    # A tampered binary keeps its original certificate, so the signer subject still says Microsoft.
    # Only the Status check can reject it. These mock Get-AuthenticodeSignature because a real
    # tampered binary cannot be built portably.
    BeforeAll {
      function New-FakeSignature([string]$Status) {
        [pscustomobject]@{
          Status            = [Management.Automation.SignatureStatus]$Status
          SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
        }
      }
    }
    It 'accepts the same mocked signer subject when the status is Valid (control: the mock path works)' {
      $script:fakeStatus = 'Valid'
      Mock Get-AuthenticodeSignature { New-FakeSignature $script:fakeStatus }
      Test-FileSignature -Path $ps -AllowedSigners @('Microsoft Corporation') | Should -BeTrue
    }
    It 'rejects Status <status> even though the signer subject is an allowed one' -ForEach @(
      @{ status = 'HashMismatch' }, @{ status = 'NotTrusted' }, @{ status = 'UnknownError' },
      @{ status = 'NotSigned' }, @{ status = 'Incompatible' }, @{ status = 'NotSupportedFileFormat' }
    ) {
      $script:fakeStatus = $status
      Mock Get-AuthenticodeSignature { New-FakeSignature $script:fakeStatus }
      Test-FileSignature -Path $ps -AllowedSigners @('Microsoft Corporation') | Should -BeFalse
    }
    It 'logs the rejected status at WARN' {
      $script:fakeStatus = 'HashMismatch'
      Mock Get-AuthenticodeSignature { New-FakeSignature $script:fakeStatus }
      $d = Join-Path $TestDrive 'siglog3'
      Initialize-SetupLog -LogDirectory $d
      try { Test-FileSignature -Path $ps -AllowedSigners @('Microsoft Corporation') | Out-Null } finally { $script:SetupLogPath = $null }
      $log = Get-Content "$d\setup.log" -Raw
      $log | Should -Match '\[WARN\]'
      $log | Should -Match 'HashMismatch'
    }
  }
  It 'logs the actual status and subject at WARN when it rejects a signed file' {
    $d = Join-Path $TestDrive 'siglog'
    Initialize-SetupLog -LogDirectory $d
    try { Test-FileSignature -Path $ps -AllowedSigners @('Google LLC') | Out-Null } finally { $script:SetupLogPath = $null }
    $log = Get-Content "$d\setup.log" -Raw
    $log | Should -Match '\[WARN\]'
    $log | Should -Match 'Valid'
    $log | Should -Match 'Microsoft'
  }
  It 'logs the status when it rejects an unsigned file' {
    $d = Join-Path $TestDrive 'siglog2'
    'Write-Host x' | Set-Content "$TestDrive\u2.ps1"
    Initialize-SetupLog -LogDirectory $d
    try { Test-FileSignature -Path "$TestDrive\u2.ps1" -AllowedSigners @('Microsoft') | Out-Null } finally { $script:SetupLogPath = $null }
    (Get-Content "$d\setup.log" -Raw) | Should -Match 'NotSigned'
  }

  Context '-ExactCN: the signer is the certificate''s one CN, exactly (Craft, final review I1)' {
    # Real certificates with the subject under test, made in memory: an ephemeral CNG key signs them and is
    # not attached, so nothing reaches a key or certificate store. Get-AuthenticodeSignature is mocked to
    # hand one back with the Status under test, because no real file is signed by these subjects.
    # Subject is a string for CertificateRequest, or an X500DistinguishedName built from DER by
    # New-DerSubject for subjects that text cannot express (a line break inside a value).
    BeforeAll {
      # DER of a subject Name from a spec: RDNs split by '|', the attributes of one multi-valued RDN by '&',
      # each '<type>=<value>' split at the first '='. Every value is a UTF8String.
      function New-DerSubject([string]$Spec) {
        $oids = @{ CN = 0x03; C = 0x06; L = 0x07; S = 0x08; O = 0x0A; OU = 0x0B }
        function Der([byte]$Tag, [byte[]]$Content) {
          $out = New-Object 'System.Collections.Generic.List[byte]'
          $out.Add($Tag)
          if ($Content.Length -lt 0x80) { $out.Add([byte]$Content.Length) } else { $out.Add(0x81); $out.Add([byte]$Content.Length) }
          $out.AddRange($Content)
          return ,($out.ToArray())
        }
        $name = New-Object 'System.Collections.Generic.List[byte]'
        foreach ($rdn in ($Spec -split '\|')) {
          $set = New-Object 'System.Collections.Generic.List[byte]'
          foreach ($atv in ($rdn -split '&')) {
            $at = $atv.IndexOf('=')
            $oid = Der 0x06 ([byte[]](0x55, 0x04, $oids[$atv.Substring(0, $at)]))
            $value = Der 0x0C ([Text.Encoding]::UTF8.GetBytes($atv.Substring($at + 1)))
            $set.AddRange([byte[]](Der 0x30 ([byte[]]($oid + $value))))
          }
          $name.AddRange([byte[]](Der 0x31 $set.ToArray()))
        }
        New-Object Security.Cryptography.X509Certificates.X500DistinguishedName (, [byte[]](Der 0x30 $name.ToArray()))
      }
      function New-TestCertificate($Subject) {
        $rsa = New-Object Security.Cryptography.RSACng 2048
        try {
          $pkcs1 = [Security.Cryptography.RSASignaturePadding]::Pkcs1
          $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest ($Subject, $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, $pkcs1)
          $generator = [Security.Cryptography.X509Certificates.X509SignatureGenerator]::CreateForRSA($rsa, $pkcs1)
          $now = [DateTimeOffset]::UtcNow
          $request.Create($request.SubjectName, $generator, $now.AddDays(-1), $now.AddDays(2), [byte[]](1, 2, 3, 4))
        } finally { $rsa.Dispose() }
      }
      $script:craftSubject = 'CN=Learning Machines Inc, O=Learning Machines Inc, L=Atlanta, S=Georgia, C=US'
      function Use-FakeSignature([string]$Status, $Subject) {
        $script:fake = [pscustomobject]@{ Status = [Management.Automation.SignatureStatus]$Status; SignerCertificate = (New-TestCertificate $Subject) }
        Mock Get-AuthenticodeSignature { $script:fake }
      }
    }
    It 'accepts the real Craft subject' {
      Use-FakeSignature 'Valid' $script:craftSubject
      Test-FileSignature -Path $ps -AllowedSigners @('Learning Machines Inc') -ExactCN | Should -BeTrue
    }
    It 'rejects <Why>' -ForEach @(
      @{ Why = 'a trailing dot';                   Subject = 'CN=Learning Machines Inc., O=Learning Machines Inc., L=Atlanta, S=Georgia, C=US' }
      @{ Why = 'a longer company name';            Subject = 'CN=Learning Machines Incorporated, O=Learning Machines Incorporated, C=US' }
      @{ Why = 'more words after the name';        Subject = 'CN=Learning Machines Inc Holdings, C=US' }
      @{ Why = 'the name only in O=';              Subject = 'CN=Other Company Ltd, O=Learning Machines Inc, C=US' }
      @{ Why = 'the name in O= and no CN at all';  Subject = 'O=Learning Machines Inc, L=Atlanta, C=US' }
      @{ Why = 'the name in OU= and no CN at all'; Subject = 'OU=Learning Machines Inc, O=Other Company Ltd, C=US' }
      @{ Why = 'another letter case';              Subject = 'CN=LEARNING MACHINES INC, C=US' }
      @{ Why = 'a second CN';                      Subject = 'CN=Other Company Ltd, CN=Learning Machines Inc, C=US' }
    ) {
      Use-FakeSignature 'Valid' $Subject
      Test-FileSignature -Path $ps -AllowedSigners @('Learning Machines Inc') -ExactCN | Should -BeFalse
    }
    It 'rejects Status <_> even with the exact CN' -ForEach 'HashMismatch', 'NotTrusted', 'NotSigned', 'UnknownError' {
      Use-FakeSignature $_ $script:craftSubject
      Test-FileSignature -Path $ps -AllowedSigners @('Learning Machines Inc') -ExactCN | Should -BeFalse
    }
    It 'rejects a signature without a signer certificate' {
      $script:fake = [pscustomobject]@{ Status = [Management.Automation.SignatureStatus]'Valid'; SignerCertificate = $null }
      Mock Get-AuthenticodeSignature { $script:fake }
      Test-FileSignature -Path $ps -AllowedSigners @('Learning Machines Inc') -ExactCN | Should -BeFalse
    }
    It 'still ignores an empty allowed signer' {
      Use-FakeSignature 'Valid' $script:craftSubject
      Test-FileSignature -Path $ps -AllowedSigners @('', ' ') -ExactCN | Should -BeFalse
    }
    It 'accepts when any one of several allowed signers is the CN' {
      Use-FakeSignature 'Valid' $script:craftSubject
      Test-FileSignature -Path $ps -AllowedSigners @('Other Company Ltd', 'Learning Machines Inc') -ExactCN | Should -BeTrue
    }
    It 'without -ExactCN the match stays a substring, as for the vendors (R32)' {
      Use-FakeSignature 'Valid' 'CN=Learning Machines Inc., O=Learning Machines Inc., C=US'
      Test-FileSignature -Path $ps -AllowedSigners @('Learning Machines Inc') | Should -BeTrue
    }
    # Fix round C-R6 (N1): subjects built from DER that a text subject cannot express. The check fails closed
    # on a quote or a control character anywhere in the subject, and counts every CN, also one inside a
    # multi-valued RDN (O=... + CN=...).
    It 'accepts the real Craft subject built from DER' {
      Use-FakeSignature 'Valid' (New-DerSubject 'C=US|S=Georgia|L=Atlanta|O=Learning Machines Inc|CN=Learning Machines Inc')
      Test-FileSignature -Path $ps -AllowedSigners @('Learning Machines Inc') -ExactCN | Should -BeTrue
    }
    It 'rejects (DER) <Why>' -ForEach @(
      @{ Why = 'no real CN, and CN=<signer> inside a quoted O value with line breaks'; Spec = "C=US|O=x`nCN=Learning Machines Inc`ny" }
      @{ Why = 'the CN=<signer> inside a multi-valued RDN next to another CN';        Spec = 'CN=Evil Corp|O=Evil&CN=Learning Machines Inc' }
      @{ Why = 'a second CN hidden in a multi-valued RDN after CN=<signer>';           Spec = 'CN=Learning Machines Inc|O=Evil&CN=Evil Corp' }
      @{ Why = 'two CNs in one multi-valued RDN';                                      Spec = 'C=US|CN=Learning Machines Inc&CN=Evil Corp' }
      @{ Why = 'a tab in another value (Windows does not quote it)';                   Spec = "O=a`tb|CN=Learning Machines Inc" }
      @{ Why = 'a control character in another value';                                 Spec = "O=a$([char]1)b|CN=Learning Machines Inc" }
      @{ Why = 'a DEL in another value';                                               Spec = "O=a$([char]0x7f)b|CN=Learning Machines Inc" }
      @{ Why = 'a quote in another value';                                             Spec = 'O=a"b|CN=Learning Machines Inc' }
      @{ Why = 'a comma in another value (quoted by Windows)';                         Spec = 'O=Learning Machines, Inc|CN=Learning Machines Inc' }
      @{ Why = 'a carriage return after the CN';                                       Spec = "C=US|CN=Learning Machines Inc`r" }
    ) {
      Use-FakeSignature 'Valid' (New-DerSubject $Spec)
      Test-FileSignature -Path $ps -AllowedSigners @('Learning Machines Inc') -ExactCN | Should -BeFalse
    }
    It 'logs the subject and the CN it read when it rejects' {
      Use-FakeSignature 'Valid' 'CN=Learning Machines Incorporated, C=US'
      $d = Join-Path $TestDrive 'siglog4'
      Initialize-SetupLog -LogDirectory $d
      try { Test-FileSignature -Path $ps -AllowedSigners @('Learning Machines Inc') -ExactCN | Out-Null } finally { $script:SetupLogPath = $null }
      $log = Get-Content "$d\setup.log" -Raw
      $log | Should -Match '\[WARN\]'; $log | Should -Match '"commonName":\s*"Learning Machines Incorporated"'
    }
  }
}
