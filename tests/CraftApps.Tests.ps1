# tests/CraftApps.Tests.ps1
# Craft apps (ArtCraft's free office suite): the pure helpers and the GitHub release lookup of
# src\Steps\CraftApps.ps1 (craft spec 3.3). Task 2 adds the step itself to this file.
#
# SAFETY: this runs on a real PC. Nothing here downloads, installs or writes anything outside $TestDrive.
# The lookup tests replace Get-RemoteText, Wait-SetupDelay, Write-SetupLog and Get-WebStatusCode with
# recorders, so no request leaves the machine and nothing waits; every other function tested here is pure.
BeforeAll {
  foreach ($f in 'StepResult', 'Logging', 'Activity', 'Process', 'Download', 'Config') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
  . "$PSScriptRoot\..\src\Report\Report.ps1"
  . "$PSScriptRoot\..\src\Steps\DefaultBrowser.ps1"   # Read-RegistryStringValue
  . "$PSScriptRoot\..\src\Steps\CraftApps.ps1"
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"

  # A release as ConvertFrom-Json gives it. -Prefix/-Version/-Arch builds the installers of every given
  # processor plus a SHA256SUMS.txt (unless -NoSums); -Names builds exactly the assets named. Every asset
  # links to https://github.com/storytold/<repo>/releases/download/v<version>/<name>.
  function New-CraftRelease {
    [CmdletBinding(DefaultParameterSetName = 'Build')]
    param(
      [Parameter(ParameterSetName = 'Build')][string]$Prefix = 'wordcraft',
      [Parameter(ParameterSetName = 'Build')][string]$Version = '0.8.0',
      [Parameter(ParameterSetName = 'Build')][string[]]$Arch = @('x64'),
      [Parameter(ParameterSetName = 'Build')][switch]$NoSums,
      [Parameter(Mandatory, ParameterSetName = 'Names')][string[]]$Names
    )
    $repo = if ($PSCmdlet.ParameterSetName -eq 'Build') { $Prefix } else { 'wordcraft' }
    $tag = 'v' + $(if ($PSCmdlet.ParameterSetName -eq 'Build') { $Version } else { '0.8.0' })
    if ($PSCmdlet.ParameterSetName -eq 'Build') {
      $Names = @(foreach ($a in $Arch) { '{0}-{1}-windows-{2}.msi' -f $Prefix, $Version, $a })
      if (-not $NoSums) { $Names += 'SHA256SUMS.txt' }
    }
    $assets = @(foreach ($n in $Names) {
      [ordered]@{ name = $n; browser_download_url = "https://github.com/storytold/$repo/releases/download/$tag/$n" }
    })
    ConvertTo-Json -InputObject ([ordered]@{ tag_name = $tag; assets = $assets }) -Depth 5 | ConvertFrom-Json
  }
}

Describe 'ConvertTo-CraftArch' {
  It 'maps ARM64 to arm64, x86 to x86, anything else to x64' {
    ConvertTo-CraftArch -Arch 'ARM64' | Should -BeExactly 'arm64'; ConvertTo-CraftArch -Arch 'x86' | Should -BeExactly 'x86'
    ConvertTo-CraftArch -Arch 'x64' | Should -BeExactly 'x64'; ConvertTo-CraftArch -Arch '' | Should -BeExactly 'x64'
  }
  It 'ignores case, and takes AMD64 or nothing for x64' {
    ConvertTo-CraftArch -Arch 'arm64' | Should -BeExactly 'arm64'; ConvertTo-CraftArch -Arch 'X86' | Should -BeExactly 'x86'
    ConvertTo-CraftArch -Arch 'AMD64' | Should -BeExactly 'x64'; ConvertTo-CraftArch -Arch $null | Should -BeExactly 'x64'
  }
}

Describe 'Select-CraftAsset' {
  It 'picks the MSI of the processor, its version and the SHA256SUMS.txt link' {
    $a = Select-CraftAsset -Release (New-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64, arm64, x86) -Prefix wordcraft -Arch arm64
    $a.Name | Should -BeExactly 'wordcraft-0.8.0-windows-arm64.msi'; $a.Version | Should -BeExactly '0.8.0'
    $a.Url | Should -Be 'https://github.com/storytold/wordcraft/releases/download/v0.8.0/wordcraft-0.8.0-windows-arm64.msi'
    $a.SumsUrl | Should -Be 'https://github.com/storytold/wordcraft/releases/download/v0.8.0/SHA256SUMS.txt'
  }
  It 'reads a longer prefix (the launcher)' { (Select-CraftAsset -Release (New-CraftRelease -Prefix artcraft-launcher -Version 0.5.1 -Arch x64) -Prefix artcraft-launcher -Arch x64).Version | Should -Be '0.5.1' }
  It 'ignores lookalikes (Review Focus 2)' {
    $rel = New-CraftRelease -Names 'wordcraft-0.8.0-windows-x64.msi.sig', 'wordcraft-portable-0.8.0-windows-x64.msi', 'gridcraft-0.8.0-windows-x64.msi', '..\wordcraft-0.8.0-windows-x64.msi', 'wordcraft-0.8.0-windows-arm64.msi'
    Select-CraftAsset -Release $rel -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty
  }
  It 'two matching installers is no choice' {
    $rel = New-CraftRelease -Names 'wordcraft-0.8.0-windows-x64.msi', 'wordcraft-0.8.0-debug-windows-x64.msi', 'SHA256SUMS.txt'
    Select-CraftAsset -Release $rel -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty
  }
  It 'SumsUrl is $null unless an asset is named exactly SHA256SUMS.txt' {
    (Select-CraftAsset -Release (New-CraftRelease -Names 'wordcraft-0.8.0-windows-x64.msi', 'sha256sums.txt', 'SHA256SUMS.txt.asc') -Prefix wordcraft -Arch x64).SumsUrl | Should -BeNullOrEmpty
  }
  It 'a release without assets is $null' { Select-CraftAsset -Release ([pscustomobject]@{ tag_name = 'v1' }) -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty }

  It 'matches the name without regard to case' {
    $a = Select-CraftAsset -Release (New-CraftRelease -Names 'WordCraft-0.8.0-Windows-X64.MSI') -Prefix wordcraft -Arch x64
    $a.Name | Should -BeExactly 'WordCraft-0.8.0-Windows-X64.MSI'; $a.Version | Should -BeExactly '0.8.0'
  }
  It 'keeps a pre-release version part' {
    (Select-CraftAsset -Release (New-CraftRelease -Names 'wordcraft-0.9.0-beta.2-windows-x64.msi') -Prefix wordcraft -Arch x64).Version | Should -BeExactly '0.9.0-beta.2'
  }
  It 'takes the prefix literally, as text and not as a pattern' {
    Select-CraftAsset -Release (New-CraftRelease -Names 'wordcraft-0.8.0-windows-x64.msi') -Prefix 'w.rdcraft' -Arch x64 | Should -BeNullOrEmpty
  }
  It 'an installer of another processor only is $null' {
    Select-CraftAsset -Release (New-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch arm64) -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty
  }
  It 'an installer without a download link is no installer' {
    $rel = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'wordcraft-0.8.0-windows-x64.msi'; browser_download_url = '' }) }
    Select-CraftAsset -Release $rel -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty
  }
  It 'no release at all is $null' { Select-CraftAsset -Release $null -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty }
  It 'logs a WARN when more than one installer matched, and stays quiet when none did' {
    Mock Write-SetupLog { }
    Select-CraftAsset -Release (New-CraftRelease -Names 'wordcraft-0.8.0-windows-x64.msi', 'wordcraft-0.8.0-debug-windows-x64.msi') -Prefix wordcraft -Arch x64 | Out-Null
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    Select-CraftAsset -Release (New-CraftRelease -Names 'gridcraft-0.8.0-windows-x64.msi') -Prefix wordcraft -Arch x64 | Out-Null
    Should -Invoke Write-SetupLog -Times 1 -Exactly
  }
}

Describe 'Get-Sha256FromSums' {
  It 'reads the line of the exact file name' {
    $text = ('a' * 64) + "  wordcraft-0.8.0-windows-x64.msi`n" + ('c' * 64) + "  wordcraft-0.8.0-windows-arm64.msi`n"
    Get-Sha256FromSums -Text $text -FileName 'wordcraft-0.8.0-windows-x64.msi' | Should -BeExactly ('a' * 64)
  }
  It 'accepts CRLF, a * before the name and upper-case hex, and answers in lower case' {
    Get-Sha256FromSums -Text (('B' * 64) + " *wordcraft-0.8.0-windows-x64.msi`r`n") -FileName 'wordcraft-0.8.0-windows-x64.msi' | Should -BeExactly ('b' * 64)
  }
  It 'is $null for <Why> (Review Focus 3)' -ForEach @(
    @{ Why = 'no line for the name'; Text = ('a' * 64) + '  wordcraft-0.8.0-windows-arm64.msi' }
    @{ Why = 'only a longer name';   Text = ('a' * 64) + '  wordcraft-0.8.0-windows-x64.msi.zip' }
    @{ Why = 'another case';         Text = ('a' * 64) + '  WordCraft-0.8.0-windows-x64.msi' }
    @{ Why = 'two different hashes'; Text = ('a' * 64) + "  wordcraft-0.8.0-windows-x64.msi`n" + ('c' * 64) + '  wordcraft-0.8.0-windows-x64.msi' }
    @{ Why = 'a short hash';         Text = 'abc123  wordcraft-0.8.0-windows-x64.msi' }
    @{ Why = 'empty text';           Text = '' }
  ) { Get-Sha256FromSums -Text $Text -FileName 'wordcraft-0.8.0-windows-x64.msi' | Should -BeNullOrEmpty }

  It 'a line listed twice with the same hash is still one answer' {
    $text = ('a' * 64) + "  wordcraft-0.8.0-windows-x64.msi`n" + ('A' * 64) + " *wordcraft-0.8.0-windows-x64.msi`n"
    Get-Sha256FromSums -Text $text -FileName 'wordcraft-0.8.0-windows-x64.msi' | Should -BeExactly ('a' * 64)
  }
  It 'is $null for text that is $null' { Get-Sha256FromSums -Text $null -FileName 'wordcraft-0.8.0-windows-x64.msi' | Should -BeNullOrEmpty }
}

Describe 'ConvertTo-CraftVersion' {
  It '<Text> is <Expected>' -ForEach @(
    @{ Text = '0.8.0';         Expected = '0.8.0.0' }
    @{ Text = 'v0.5.1';        Expected = '0.5.1.0' }
    @{ Text = '2';             Expected = '2.0.0.0' }
    @{ Text = '1.2.3.4';       Expected = '1.2.3.4' }
    @{ Text = '1.2.3.4.5';     Expected = '1.2.3.4' }
    @{ Text = '0.9.0-beta.2';  Expected = '0.9.0.0' }
    @{ Text = ' 0.8.0 ';       Expected = '0.8.0.0' }
  ) { (ConvertTo-CraftVersion -Text $Text).ToString() | Should -Be $Expected }
  It 'is a [version]' { ConvertTo-CraftVersion -Text '0.8.0' | Should -BeOfType ([version]) }
  It '<Why> is $null' -ForEach @(
    @{ Why = 'empty text';       Text = '' }
    @{ Why = 'a word';           Text = 'abc' }
    @{ Why = 'a leading word';   Text = 'release 0.8.0' }
    @{ Why = 'a part too big';   Text = '99999999999.1' }
  ) { ConvertTo-CraftVersion -Text $Text | Should -BeNullOrEmpty }
  It 'is $null for text that is $null' { ConvertTo-CraftVersion -Text $null | Should -BeNullOrEmpty }
}

Describe 'Test-CraftVersionCurrent (Review Focus 4)' {
  It 'installed <Installed> vs release <Available> is <Expected>' -ForEach @(
    @{ Installed = '0.8.0';   Available = '0.8.0';        Expected = $true }
    @{ Installed = '0.8.0.0'; Available = '0.8.0';        Expected = $true }
    @{ Installed = '0.8.0';   Available = '0.8.0.0';      Expected = $true }
    @{ Installed = 'v0.8.0';  Available = '0.8.0';        Expected = $true }
    @{ Installed = '0.9.1';   Available = '0.9.0';        Expected = $true }    # never downgrade
    @{ Installed = '0.8.0';   Available = '0.8.0-beta.2'; Expected = $true }    # numeric part only
    @{ Installed = '0.7.9';   Available = '0.8.0';        Expected = $false }
    @{ Installed = '';        Available = '0.8.0';        Expected = $false }
    @{ Installed = 'abc';     Available = '0.8.0';        Expected = $false }   # doubt: install
    @{ Installed = '0.8.0';   Available = 'x';            Expected = $false }
  ) { Test-CraftVersionCurrent -Installed $Installed -Available $Available | Should -Be $Expected }
}

Describe 'Get-WebStatusCode' {
  It 'is 0 when no HTTP answer is attached, also deep inside' {
    Get-WebStatusCode -Exception (New-Object Exception 'x') | Should -Be 0
    $inner = New-Object Management.Automation.MethodInvocationException ('m', (New-Object Net.WebException 'The remote name could not be resolved'))
    Get-WebStatusCode -Exception (New-Object Exception ('download failed after 3 attempts: u', $inner)) | Should -Be 0
  }
  It 'is 0 for no exception at all' { Get-WebStatusCode -Exception $null | Should -Be 0 }
  It 'finds status <_> of the HTTP answer deep in the chain, as the download helpers wrap it' -ForEach 403, 429 {
    # An HttpWebResponse cannot be made without a connection: build an empty one and set its status field.
    $field = [Net.HttpWebResponse].GetField('m_StatusCode', [Reflection.BindingFlags]'NonPublic,Instance')
    if ($null -eq $field) { Set-ItResult -Skipped -Because 'this .NET has no m_StatusCode field'; return }
    $code = $_
    $response = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([Net.HttpWebResponse])
    $field.SetValue($response, [Enum]::ToObject([Net.HttpStatusCode], $code))   # .NET Framework has no name for 429
    $web = New-Object Net.WebException ('The remote server returned an error.', $null, [Net.WebExceptionStatus]::ProtocolError, $response)
    $invocation = New-Object Management.Automation.MethodInvocationException ('Exception calling "DownloadData"', $web)
    Get-WebStatusCode -Exception (New-Object Exception ('download failed after 3 attempts: u', $invocation)) | Should -Be $code
    Get-WebStatusCode -Exception $web | Should -Be $code
  }
}

Describe 'Get-CraftRelease' {
  BeforeEach {
    Mock Write-SetupLog { }; Mock Wait-SetupDelay { }
    $script:calls = 0; $script:fail = 0; $script:status = 0
    Mock Get-RemoteText { $script:calls++; if ($script:calls -le $script:fail) { throw 'download failed after 3 attempts' }; '{"tag_name":"v0.8.0","assets":[{"name":"SHA256SUMS.txt","browser_download_url":"u"}]}' }
    Mock Get-WebStatusCode { $script:status }
  }
  It 'reads releases/latest of the repo and returns the parsed answer' {
    (Get-CraftRelease -Repo 'storytold/wordcraft').assets[0].name | Should -Be 'SHA256SUMS.txt'
    Should -Invoke Get-RemoteText -Times 1 -Exactly -ParameterFilter { $Url -eq 'https://api.github.com/repos/storytold/wordcraft/releases/latest' }
  }
  It 'a rate limit (<_>) gets one retry after 60 s (Review Focus 1)' -ForEach 403, 429 {
    $script:fail = 1; $script:status = $_
    (Get-CraftRelease -Repo 'storytold/wordcraft').tag_name | Should -Be 'v0.8.0'
    $script:calls | Should -Be 2
    Should -Invoke Wait-SetupDelay -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
  }
  It 'a second rate limit is GitHub busy' {
    $script:fail = 2; $script:status = 403
    { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw 'GitHub busy - try again later'
    $script:calls | Should -Be 2
  }
  It 'any other failure is a lookup failure at once, with no wait' {
    $script:fail = 1; $script:status = 404
    { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw 'release lookup failed'
    $script:calls | Should -Be 1; Should -Invoke Wait-SetupDelay -Times 0 -Exactly
  }
  It 'an answer that is not JSON is a lookup failure' { Mock Get-RemoteText { '<html>busy</html>' }; { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw 'release lookup failed' }

  It 'an answer of <_> is JSON but no release object, so a lookup failure' -ForEach 'null', '[]', '"busy"' {
    $script:answer = $_
    Mock Get-RemoteText { $script:answer }
    { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw 'release lookup failed'
  }
  It 'a rate limit then another failure is a lookup failure, after the one wait' {
    $script:fail = 2
    Mock Get-WebStatusCode { if ($script:calls -le 1) { 403 } else { 500 } }
    { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw 'release lookup failed'
    $script:calls | Should -Be 2; Should -Invoke Wait-SetupDelay -Times 1 -Exactly
  }
  It 'logs the retry, and each failure, at WARN' {
    $script:fail = 2; $script:status = 429
    { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw
    Should -Invoke Write-SetupLog -Times 2 -Exactly -ParameterFilter { $Level -eq 'WARN' }
  }
}
