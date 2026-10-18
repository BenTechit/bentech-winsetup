# tests/Download.Tests.ps1
BeforeAll { . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Process.ps1"; . "$PSScriptRoot\..\src\Common\Download.ps1" }

Describe 'downloads and signatures' {
  It 'copies a file:// url' { 'x' | Set-Content "$TestDrive\src.txt"; Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination "$TestDrive\dst.txt" -BackoffSeconds 0 | Should -Exist }
  It 'throws after retries' { { Get-RemoteFile -Url ([uri]"$TestDrive\missing.txt").AbsoluteUri -Destination "$TestDrive\d2.txt" -Retries 2 -BackoffSeconds 0 } | Should -Throw '*after 2 attempts*' }
  It 'finds the newest HPIA link in the fixture' { Find-LatestLink -Html (Get-Content "$PSScriptRoot\fixtures\hpia.html" -Raw) -Pattern 'https://hpia\.hpcloud\.hp\.com/downloads/hpia/hp-hpia-[0-9.]+\.exe' | Should -Be 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.7.exe' }
  It 'accepts a Microsoft-signed binary' { Test-FileSignature -Path "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -AllowedSigners @('Microsoft') | Should -BeTrue }
  It 'rejects the wrong signer' { Test-FileSignature -Path "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -AllowedSigners @('Google LLC') | Should -BeFalse }
  It 'rejects an unsigned file' { 'x' | Set-Content "$TestDrive\u.exe"; Test-FileSignature -Path "$TestDrive\u.exe" -AllowedSigners @('Microsoft') | Should -BeFalse }
}

Describe 'Get-RemoteFile' {
  BeforeEach { 'payload' | Set-Content "$TestDrive\src.txt" }
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
}
