# tests/CraftApps.Tests.ps1
# Craft apps (ArtCraft's free office suite): the pure helpers, the GitHub release lookup, one item's
# install (Install-CraftItem), its desktop shortcut (Add-CraftShortcut) and the craft-apps step
# (Invoke-StepCraftApps) of src\Steps\CraftApps.ps1 (craft spec 3.3).
#
# SAFETY: this runs on a real PC. Nothing here downloads, installs, runs msiexec or writes anything outside
# $TestDrive. The lookup tests replace Get-RemoteText, Wait-SetupDelay, Write-SetupLog and Get-WebStatusCode
# with recorders, so no request leaves the machine and nothing waits. The Install-CraftItem tests run after
# Initialize-CraftMocks, which replaces Get-RemoteText, Get-RemoteFile (it writes a placeholder MSI into
# $TestDrive), Test-FileSignature, Invoke-External, Wait-SetupDelay, Set-SetupNow and Write-SetupLog. The
# Add-CraftShortcut tests use $TestDrive folders for the desktops and Start menus; the one test that lets it
# find this PC's real folders mocks Test-Path, Get-ChildItem, Copy-Item and Move-Item first. The step tests
# mock Install-CraftItem, Add-CraftShortcut, Get-InstalledAppVersions and Add-SetupActivity.
BeforeAll {
  foreach ($f in 'StepResult', 'Logging', 'Activity', 'Process', 'Download', 'Config') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
  . "$PSScriptRoot\..\src\Report\Report.ps1"
  . "$PSScriptRoot\..\src\Steps\DefaultBrowser.ps1"   # Read-RegistryStringValue
  . "$PSScriptRoot\..\src\Steps\CraftApps.ps1"
  $script:ConfigFile = "$PSScriptRoot\..\config\config.json"
  $script:cfg = Read-SetupConfig -Path $script:ConfigFile
  $script:ConfigJson = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)

  # The SHA-256 of the bytes the Get-RemoteFile mock writes ('placeholder', UTF-8 without BOM).
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $script:placeholderHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('placeholder'))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }

  # A context like the runner's: a fresh copy of the real config per call (a test may change it), Machine.Arch
  # x64, Office CRAFT, and every folder in its own $TestDrive folder.
  function New-CraftContext {
    $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    @{
      Config      = ($script:ConfigJson | ConvertFrom-Json)
      State       = @{ Machine = @{ Arch = 'x64' }; Choices = @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT' } }
      Root        = $dir
      LogDir      = (Join-Path $dir 'Logs')
      DownloadDir = (Join-Path $dir 'Downloads')
      ScriptPath  = (Join-Path $dir 'setup.ps1')
      StatePath   = (Join-Path $dir 'state.json')
    }
  }

  # Turns every command Install-CraftItem can reach into a recorder. Call from BeforeEach.
  #   $script:now        each Set-SetupNow SubTitle
  #   $script:waits      each Wait-SetupDelay Seconds
  #   $script:downloads  each Get-RemoteFile call (Url, Destination); the mock writes 'placeholder' to Destination
  #   $script:sigCalls   each Test-FileSignature call (Path, Signers); $script:sigBad lists the leaf names that fail
  #   $script:ext        each Invoke-External call; $script:extHandler answers it (default: exit 0)
  #   $script:texts      URL -> text for Get-RemoteText (Set-CraftRelease fills it); an unknown URL throws
  function Initialize-CraftMocks {
    $script:now = New-Object System.Collections.ArrayList
    $script:waits = New-Object System.Collections.ArrayList
    $script:downloads = New-Object System.Collections.ArrayList
    $script:sigCalls = New-Object System.Collections.ArrayList
    $script:sigBad = @()
    $script:ext = New-Object System.Collections.ArrayList
    $script:extHandler = { param($c) @{ ExitCode = 0; TimedOut = $false } }
    $script:texts = @{}
    $script:sumsHash = $script:placeholderHash

    Mock Write-SetupLog { }
    Mock Set-SetupNow { [void]$script:now.Add($SubTitle) }
    Mock Wait-SetupDelay { [void]$script:waits.Add($Seconds) }
    Mock Get-RemoteText {
      if (-not $script:texts.ContainsKey($Url)) { throw "download failed after 3 attempts: $Url" }
      return $script:texts[$Url]
    }
    Mock Get-RemoteFile {
      [void]$script:downloads.Add(@{ Url = $Url; Destination = $Destination })
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
      [IO.File]::WriteAllText($Destination, 'placeholder')
      return $Destination
    }
    Mock Test-FileSignature {
      [void]$script:sigCalls.Add(@{ Path = $Path; Signers = @($AllowedSigners) })
      return (-not ($script:sigBad -contains (Split-Path -Leaf $Path)))
    }
    Mock Invoke-External {
      $call = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes }
      [void]$script:ext.Add($call)
      & $script:extHandler $call
    }
  }

  # What GitHub answers for the item with asset prefix Prefix: releases/latest of its repo (from config)
  # lists the MSIs of every Arch plus SHA256SUMS.txt (unless -NoSums), and SHA256SUMS.txt holds one line
  # "<$script:sumsHash>  <prefix>-<version>-windows-<arch>.msi" per SumsArch (default: Arch). Replaces
  # $script:texts.
  function Set-CraftRelease {
    param(
      [Parameter(Mandatory)][string]$Prefix,
      [Parameter(Mandatory)][string]$Version,
      [Parameter(Mandatory)][string[]]$Arch,
      [string[]]$SumsArch,
      [switch]$NoSums
    )
    if (-not $SumsArch) { $SumsArch = $Arch }
    $repo = [string]@($script:cfg.apps.craft.items | Where-Object { $_.assetPrefix -eq $Prefix })[0].repo
    $release = New-CraftRelease -Prefix $Prefix -Version $Version -Arch $Arch -NoSums:$NoSums
    $script:texts = @{}
    $script:texts["https://api.github.com/repos/$repo/releases/latest"] = ConvertTo-Json -InputObject $release -Depth 5
    if (-not $NoSums) {
      $sumsUrl = "https://github.com/storytold/$Prefix/releases/download/v$Version/SHA256SUMS.txt"
      $script:texts[$sumsUrl] = (@(foreach ($a in $SumsArch) { '{0}  {1}-{2}-windows-{3}.msi' -f $script:sumsHash, $Prefix, $Version, $a }) -join "`n") + "`n"
    }
  }

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

Describe 'Install-CraftItem' {
  BeforeAll { function I([string]$Arch = 'x64', [string]$Installed = '') { Install-CraftItem -Context $script:ctx -Item $script:word -Arch $Arch -Signers @('Learning Machines Inc') -InstalledVersion $Installed } }
  BeforeEach { Initialize-CraftMocks; $script:ctx = New-CraftContext; $script:word = $script:ctx.Config.apps.craft.items[0]
    $script:msi = Join-Path $script:ctx.DownloadDir 'wordcraft-0.8.0-windows-x64.msi'; Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64, arm64 }
  It 'downloads, checks the checksum and the signer, then installs silently' {
    $r = I; $r.Status | Should -Be 'Installed'; $r.Version | Should -Be '0.8.0'; $r.Reason | Should -BeExactly ''
    $script:downloads[0].Destination | Should -Be $msi
    $script:sigCalls[0].Path | Should -Be $msi; @($script:sigCalls[0].Signers) | Should -Be @('Learning Machines Inc')
    $script:ext.Count | Should -Be 1; $script:ext[0].FilePath | Should -Be (Join-Path $env:windir 'System32\msiexec.exe')
    $script:ext[0].ArgumentList | Should -BeExactly "/i `"$msi`" /qn /norestart"; $script:ext[0].TimeoutMinutes | Should -Be 20
  }
  It 'shows each phase in NOW' { $null = I; @($script:now) | Should -Be @('WordCraft: looking up the latest release', 'WordCraft 0.8.0: downloading', 'WordCraft 0.8.0: checking', 'WordCraft 0.8.0: installing') }
  It 'installed <_> is Current: nothing downloaded or run' -ForEach '0.8.0', '0.8.0.0', '0.9.1' {
    $r = I -Installed $_; $r.Status | Should -Be 'Current'; $r.Version | Should -Be '0.8.0'; $script:downloads.Count | Should -Be 0; $script:ext.Count | Should -Be 0 }
  It 'an older installed version is upgraded' { (I -Installed '0.7.2').Status | Should -Be 'Installed' }
  It 'a checksum mismatch deletes the MSI and never runs it' { $script:sumsHash = 'f' * 64; Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64
    $r = I; $r.Status | Should -Be 'Failed'; $r.Reason | Should -Be 'checksum mismatch'; Test-Path -LiteralPath $msi | Should -BeFalse; $script:ext.Count | Should -Be 0 }
  It 'a bad signature deletes the MSI and never runs it' { $script:sigBad = @('wordcraft-0.8.0-windows-x64.msi')
    $r = I; $r.Reason | Should -Be 'signature check failed'; Test-Path -LiteralPath $msi | Should -BeFalse; $script:ext.Count | Should -Be 0 }
  It 'no checksum line for the file' { Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64, arm64 -SumsArch x64
    $r = I -Arch arm64; $r.Reason | Should -Be 'no checksum for wordcraft-0.8.0-windows-arm64.msi'; $script:ext.Count | Should -Be 0 }
  It 'no SHA256SUMS.txt in the release' { Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64 -NoSums; (I).Reason | Should -Be 'no SHA256SUMS.txt in the release'; $script:downloads.Count | Should -Be 0 }
  It 'no installer for the processor' { (I -Arch x86).Reason | Should -Be 'no x86 installer in the latest release' }
  It 'GitHub busy is the reason' { Mock Get-CraftRelease { throw 'GitHub busy - try again later' }; (I).Reason | Should -Be 'GitHub busy - try again later' }
  It 'a failed MSI download is the reason' { Mock Get-RemoteFile { throw 'download failed after 3 attempts' }; (I).Reason | Should -Be 'download failed'; $script:ext.Count | Should -Be 0 }
  It 'a checksum list that cannot be read is the reason' {
    $script:texts.Remove(@($script:texts.Keys | Where-Object { $_ -like '*SHA256SUMS.txt' })[0]); (I).Reason | Should -Be 'checksum list could not be read'; $script:ext.Count | Should -Be 0 }
  It 'msiexec <Code> is <Status>' -ForEach @(@{ Code = 3010; Status = 'Installed' }, @{ Code = 1641; Status = 'Installed' }, @{ Code = 1603; Status = 'Failed' }) {
    $script:code = $Code; $script:extHandler = { param($c) @{ ExitCode = $script:code; TimedOut = $false } }; $r = I; $r.Status | Should -Be $Status
    if ($Status -eq 'Failed') { $r.Reason | Should -Be 'msiexec 1603' } }
  It 'msiexec 1618 waits 60 s and tries again, three tries in all' {
    $script:extHandler = { param($c) @{ ExitCode = 1618; TimedOut = $false } }; $r = I
    $r.Reason | Should -Be 'msiexec 1618'; $script:ext.Count | Should -Be 3; @($script:waits) | Should -Be @(60, 60) }
  It 'msiexec that times out or cannot start is a failure' {
    $script:extHandler = { param($c) @{ ExitCode = $null; TimedOut = $true } }; (I).Reason | Should -Be 'msiexec timed out'
    Mock Invoke-External { throw 'cannot start' }; (I).Reason | Should -Be 'msiexec could not be started' }
  It 'an unexpected error is a failure, never a throw' { Mock Select-CraftAsset { throw 'boom' }; (I).Reason | Should -Be 'unexpected error' }

  # Beyond the brief's table: the edges of "never runs an unverified MSI" and "deletes only that MSI".
  It 'an MSI with no checksum line is deleted too, and nothing else in the download folder is' {
    $other = Join-Path $script:ctx.DownloadDir 'chrome.msi'; [void][IO.Directory]::CreateDirectory($script:ctx.DownloadDir); [IO.File]::WriteAllText($other, 'x')
    Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64 -SumsArch arm64
    (I).Reason | Should -Be 'no checksum for wordcraft-0.8.0-windows-x64.msi'
    Test-Path -LiteralPath $msi | Should -BeFalse; Test-Path -LiteralPath $other | Should -BeTrue; $script:sigCalls.Count | Should -Be 0 }
  It 'a checksum in upper case still matches' {
    $script:sumsHash = $script:placeholderHash.ToUpperInvariant(); Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64
    (I).Status | Should -Be 'Installed' }
  It 'the signature is checked only after the checksum matched' {
    $script:sumsHash = 'f' * 64; Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64; $null = I; $script:sigCalls.Count | Should -Be 0 }
  It 'a lookup or asset failure has no version; a later failure has the release version' {
    (I -Arch x86).Version | Should -BeExactly ''
    $script:extHandler = { param($c) @{ ExitCode = 1603; TimedOut = $false } }; (I).Version | Should -Be '0.8.0' }
  It 'never waits for anything but a 1618' { $script:extHandler = { param($c) @{ ExitCode = 1603; TimedOut = $false } }; $null = I; $script:waits.Count | Should -Be 0 }
  It 'a checksum that cannot be computed is an unexpected error, and msiexec never runs (C-R3)' {
    Mock Get-FileHash { Write-Error 'locked' }; (I).Reason | Should -Be 'unexpected error'; $script:ext.Count | Should -Be 0 }
}

Describe 'Add-CraftShortcut' {
  BeforeAll {
    $script:items = $script:cfg.apps.craft.items
    # A fake shortcut: <Folder>\<Name>.lnk holding Text, so a test can tell a copy from a rename.
    function Add-Lnk([string]$Folder, [string]$Name, [string]$Text = 'lnk') {
      [void][IO.Directory]::CreateDirectory($Folder); [IO.File]::WriteAllText((Join-Path $Folder "$Name.lnk"), $Text) }
    function S($item) { Add-CraftShortcut -Item $item -PublicDesktop $script:pub -UserDesktop $script:usr -StartMenuFolders @($script:menu, $script:userMenu) }
  }
  BeforeEach {
    Mock Write-SetupLog { }
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $script:pub = Join-Path $root 'Public\Desktop'; $script:usr = Join-Path $root 'Tech\Desktop'
    $script:menu = Join-Path $root 'ProgramData\Start Menu\Programs'; $script:userMenu = Join-Path $root 'Tech\Start Menu\Programs'
    foreach ($d in $script:pub, $script:usr, $script:menu, $script:userMenu) { [void][IO.Directory]::CreateDirectory($d) }
  }
  It 'copies the Start-menu shortcut to the public desktop as Word.lnk' {
    Add-Lnk (Join-Path $menu 'WordCraft') 'WordCraft' 'start'; $r = S $items[0]
    $r.Status | Should -Be 'Created'; $r.Path | Should -Be (Join-Path $pub 'Word.lnk')
    Get-Content -LiteralPath (Join-Path $pub 'Word.lnk') | Should -Be 'start'; Test-Path -LiteralPath (Join-Path $menu 'WordCraft\WordCraft.lnk') | Should -BeTrue }
  It 'renames the MSI''s own desktop shortcut instead of copying, so there is no duplicate' {
    Add-Lnk $pub 'WordCraft' 'msi'; Add-Lnk $menu 'WordCraft' 'start'
    (S $items[0]).Status | Should -Be 'Renamed'; @((Get-ChildItem -LiteralPath $pub -Filter *.lnk).Name) | Should -Be @('Word.lnk')
    Get-Content -LiteralPath (Join-Path $pub 'Word.lnk') | Should -Be 'msi' }
  It 'never overwrites or deletes: an existing Word.lnk stays, and so does the MSI''s own (Review Focus 5)' {
    Add-Lnk $pub 'Word' 'microsoft word'; Add-Lnk $pub 'WordCraft' 'msi'; Add-Lnk $menu 'WordCraft' 'start'
    (S $items[0]).Status | Should -Be 'Exists'; Get-Content -LiteralPath (Join-Path $pub 'Word.lnk') | Should -Be 'microsoft word'
    Test-Path -LiteralPath (Join-Path $pub 'WordCraft.lnk') | Should -BeTrue }
  It 'puts the launcher on the user''s desktop, from the per-user Start menu' {
    Add-Lnk $userMenu 'ArtCraft Launcher'; (S $items[4]).Path | Should -Be (Join-Path $usr 'ArtCraft Launcher.lnk')
    Test-Path -LiteralPath (Join-Path $usr 'ArtCraft Launcher.lnk') | Should -BeTrue; Test-Path -LiteralPath (Join-Path $pub 'ArtCraft Launcher.lnk') | Should -BeFalse }
  It 'takes only a shortcut whose name starts as startMenuName says' {
    Add-Lnk $menu 'Uninstall WordCraft'; Add-Lnk $menu 'GridCraft'; (S $items[0]).Status | Should -Be 'Failed'
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' } }
  # The copy goes through Copy-CraftShortcutFile ([IO.File]::Copy, which throws on failure) since C-R3, so
  # the next two mock that seam where the brief mocked Copy-Item.
  It 'a copy that fails is Failed and never throws' {
    Add-Lnk $menu 'WordCraft'; Mock Copy-CraftShortcutFile { throw 'access denied' }
    { $script:r = S $items[0] } | Should -Not -Throw; $script:r.Status | Should -Be 'Failed' }
  It 'with no folders given it looks at both desktops and both Start menus of this PC, and copies nothing' {
    Mock Test-Path { $false }; Mock Get-ChildItem { }; Mock Copy-CraftShortcutFile { }; Mock Move-Item { }
    (Add-CraftShortcut -Item $items[0]).Status | Should -Be 'Failed'
    foreach ($f in 'CommonDesktopDirectory', 'DesktopDirectory', 'CommonPrograms', 'Programs') {
      $script:want = [Environment]::GetFolderPath($f); Should -Invoke Get-ChildItem -ParameterFilter { $LiteralPath -eq $script:want } }
    Should -Invoke Copy-CraftShortcutFile -Times 0 -Exactly; Should -Invoke Move-Item -Times 0 -Exactly }

  # Beyond the brief's table.
  It 'a rename that fails is Failed, never a throw, and the MSI''s own shortcut stays' {
    Add-Lnk $pub 'WordCraft' 'msi'; Mock Move-Item { Write-Error 'access denied' }
    { $script:r = S $items[0] } | Should -Not -Throw; $script:r.Status | Should -Be 'Failed'
    Test-Path -LiteralPath (Join-Path $pub 'WordCraft.lnk') | Should -BeTrue; Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' } }
  It 'moves the MSI''s shortcut from the user''s desktop to the public desktop' {
    Add-Lnk $usr 'PdfCraft' 'msi'; $r = S $items[3]
    $r.Status | Should -Be 'Renamed'; $r.Path | Should -Be (Join-Path $pub 'PDF Reader.lnk')
    Test-Path -LiteralPath (Join-Path $usr 'PdfCraft.lnk') | Should -BeFalse }
  It 'never copies a folder that happens to match' {
    [void][IO.Directory]::CreateDirectory((Join-Path $menu 'WordCraft.lnk')); (S $items[0]).Status | Should -Be 'Failed' }

  # Fix round 1 (C-R3): never guess, never overwrite, never duplicate.
  It 'takes the shortcut named exactly like the app over Help and Uninstall, which NTFS lists first' {
    Add-Lnk $menu 'WordCraft Help' 'help'; Add-Lnk $menu 'WordCraft Uninstall' 'uninstall'; Add-Lnk $menu 'WordCraft' 'start'
    (S $items[0]).Status | Should -Be 'Created'; [IO.File]::ReadAllText((Join-Path $pub 'Word.lnk')) | Should -Be 'start' }
  It 'two matches and none named like the app is Failed: nothing copied, the candidates in a WARN' {
    Add-Lnk $menu 'WordCraft Help'; Add-Lnk $menu 'WordCraft Uninstall'
    (S $items[0]).Status | Should -Be 'Failed'; Test-Path -LiteralPath (Join-Path $pub 'Word.lnk') | Should -BeFalse
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and @($Data.candidates).Count -eq 2 } }
  It 'one match not named exactly like the app is taken' {
    Add-Lnk $menu 'WordCraft 0.8' 'start'; (S $items[0]).Status | Should -Be 'Created'; [IO.File]::ReadAllText((Join-Path $pub 'Word.lnk')) | Should -Be 'start' }
  It 'the same rule on the desktops: two loose matches are Failed, nothing moved or copied' {
    Add-Lnk $pub 'WordCraft Help'; Add-Lnk $usr 'WordCraft Beta'; Add-Lnk $menu 'WordCraft' 'start'
    (S $items[0]).Status | Should -Be 'Failed'; Test-Path -LiteralPath (Join-Path $pub 'Word.lnk') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $pub 'WordCraft Help.lnk') | Should -BeTrue; Test-Path -LiteralPath (Join-Path $usr 'WordCraft Beta.lnk') | Should -BeTrue }
  It 'the MSI''s own desktop shortcut named like the app wins over a loose match there' {
    Add-Lnk $pub 'WordCraft Help' 'help'; Add-Lnk $pub 'WordCraft' 'msi'
    (S $items[0]).Status | Should -Be 'Renamed'; [IO.File]::ReadAllText((Join-Path $pub 'Word.lnk')) | Should -Be 'msi'
    Test-Path -LiteralPath (Join-Path $pub 'WordCraft Help.lnk') | Should -BeTrue }
  It 'a Word.lnk that appears between the check and the copy is never overwritten' {
    Add-Lnk $pub 'Word' 'microsoft word'; Add-Lnk $menu 'WordCraft' 'start'; Mock Test-Path { $false }   # the check misses it
    (S $items[0]).Status | Should -Be 'Failed'; [IO.File]::ReadAllText((Join-Path $pub 'Word.lnk')) | Should -Be 'microsoft word' }
  It 'a Word.lnk that appears between the check and the rename is never overwritten' {
    Add-Lnk $pub 'Word' 'microsoft word'; Add-Lnk $pub 'WordCraft' 'msi'; Mock Test-Path { $false }
    (S $items[0]).Status | Should -Be 'Failed'; [IO.File]::ReadAllText((Join-Path $pub 'Word.lnk')) | Should -Be 'microsoft word'
    [IO.File]::ReadAllText((Join-Path $pub 'WordCraft.lnk')) | Should -Be 'msi' }
  It 'Copy-CraftShortcutFile refuses an existing destination and leaves it as it was' {
    Add-Lnk $pub 'Word' 'microsoft word'; Add-Lnk $menu 'WordCraft' 'start'
    { Copy-CraftShortcutFile -Path (Join-Path $menu 'WordCraft.lnk') -Destination (Join-Path $pub 'Word.lnk') } | Should -Throw
    [IO.File]::ReadAllText((Join-Path $pub 'Word.lnk')) | Should -Be 'microsoft word' }
  It 'a Word.lnk on the user''s own desktop is enough: no second Word icon on the public desktop' {
    Add-Lnk $usr 'Word' 'mine'; Add-Lnk $menu 'WordCraft' 'start'
    $r = S $items[0]; $r.Status | Should -Be 'Exists'; $r.Path | Should -Be (Join-Path $usr 'Word.lnk')
    Test-Path -LiteralPath (Join-Path $pub 'Word.lnk') | Should -BeFalse }
  It 'the launcher''s shortcut already on the public desktop is Exists: never moved to the user''s desktop' {
    Add-Lnk $pub 'ArtCraft Launcher' 'msi'; $r = S $items[4]
    $r.Status | Should -Be 'Exists'; $r.Path | Should -Be (Join-Path $pub 'ArtCraft Launcher.lnk')
    Test-Path -LiteralPath (Join-Path $usr 'ArtCraft Launcher.lnk') | Should -BeFalse }
}

Describe 'Invoke-StepCraftApps' {
  BeforeEach {
    $script:ctx = New-CraftContext
    $script:order = New-Object System.Collections.ArrayList
    $script:outcome = @{}
    $script:shortcutFails = @()
    $script:shortcutStatus = 'Created'
    $script:activity = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { }
    Mock Install-CraftItem {
      [void]$script:order.Add([string]$Item.name)
      if ($script:outcome.ContainsKey([string]$Item.name)) { return $script:outcome[[string]$Item.name] }
      $v = switch ([string]$Item.name) { 'PdfCraft' { '0.9.0' } 'ArtCraft Launcher' { '0.5.1' } default { '0.8.0' } }
      return @{ Status = 'Installed'; Version = $v; Reason = '' }
    }
    Mock Add-CraftShortcut {
      $s = if ($script:shortcutFails -contains [string]$Item.shortcut) { 'Failed' } else { $script:shortcutStatus }
      return @{ Status = $s; Path = "X:\Desktop\$($Item.shortcut).lnk" }
    }
    Mock Get-InstalledAppVersions { @{ 'PdfCraft' = '0.9.0' } }
    Mock Add-SetupActivity { [void]$script:activity.Add(@{ Text = $Text }) }
  }
  It 'works through the five items in config order with the processor, the craft signer and the installed version' {
    $ctx.State.Machine.Arch = 'ARM64'; $null = Invoke-StepCraftApps -Context $ctx
    @($script:order) | Should -Be @('WordCraft', 'GridCraft', 'DeckCraft', 'PdfCraft', 'ArtCraft Launcher')
    Should -Invoke Install-CraftItem -Times 5 -Exactly -ParameterFilter { $Arch -eq 'arm64' -and (@($Signers) -join '|') -eq 'Learning Machines Inc' }
    Should -Invoke Install-CraftItem -Times 1 -Exactly -ParameterFilter { $Item.name -eq 'PdfCraft' -and $InstalledVersion -eq '0.9.0' }
    Should -Invoke Get-InstalledAppVersions -Times 1 -Exactly -ParameterFilter { $null -ne $Config } }
  It 'all installed: Done, one activity line per item (spec 3.4)' {
    $r = Invoke-StepCraftApps -Context $ctx; $r.Status | Should -Be 'Done'; $r.Message | Should -Be 'Craft apps installed'; @($r.Notes).Count | Should -Be 0
    @($script:activity.Text) | Should -Be @('WordCraft 0.8.0 installed - desktop shortcut: Word', 'GridCraft 0.8.0 installed - desktop shortcut: Excel',
      'DeckCraft 0.8.0 installed - desktop shortcut: PowerPoint', 'PdfCraft 0.9.0 installed - desktop shortcut: PDF Reader',
      'ArtCraft Launcher 0.5.1 installed - open it to check the apps and their updates') }
  It 'an app already up to date says so; a shortcut that was there already is not mentioned' {
    $script:outcome['PdfCraft'] = @{ Status = 'Current'; Version = '0.9.0'; Reason = '' }; $script:shortcutStatus = 'Exists'
    $null = Invoke-StepCraftApps -Context $ctx
    @($script:activity.Text) | Should -Contain 'PdfCraft 0.9.0 already up to date'; @($script:activity.Text) | Should -Contain 'WordCraft 0.8.0 installed' }
  It 'every item current is Done(Craft apps already up to date), and the shortcuts are still checked' {
    foreach ($n in 'WordCraft', 'GridCraft', 'DeckCraft', 'PdfCraft', 'ArtCraft Launcher') { $script:outcome[$n] = @{ Status = 'Current'; Version = '1.0'; Reason = '' } }
    (Invoke-StepCraftApps -Context $ctx).Message | Should -Be 'Craft apps already up to date'; Should -Invoke Add-CraftShortcut -Times 5 -Exactly }
  It 'one app failing does not stop the others: Failed with the names and reasons' {
    $script:outcome['GridCraft'] = @{ Status = 'Failed'; Version = '0.8.0'; Reason = 'checksum mismatch' }
    $script:outcome['PdfCraft'] = @{ Status = 'Failed'; Version = ''; Reason = 'GitHub busy - try again later' }
    $r = Invoke-StepCraftApps -Context $ctx; $r.Status | Should -Be 'Failed'
    $r.Message | Should -BeExactly 'Not installed: GridCraft (checksum mismatch), PdfCraft (GitHub busy - try again later)'
    Should -Invoke Install-CraftItem -Times 5 -Exactly; Should -Invoke Add-CraftShortcut -Times 0 -Exactly -ParameterFilter { $Item.name -in 'GridCraft', 'PdfCraft' }
    @($script:activity.Text) | Should -Contain 'GridCraft not installed - checksum mismatch' }
  It 'only the launcher failing is Done with a yellow Note' {
    $script:outcome['ArtCraft Launcher'] = @{ Status = 'Failed'; Version = ''; Reason = 'no arm64 installer in the latest release' }
    $r = Invoke-StepCraftApps -Context $ctx; $r.Status | Should -Be 'Done'; @($r.Notes) | Should -Be @('ArtCraft Launcher could not be installed') }
  It 'a shortcut that cannot be made is a yellow Note; the step stays Done' {
    $script:shortcutFails = @('PDF Reader'); $r = Invoke-StepCraftApps -Context $ctx
    $r.Status | Should -Be 'Done'; @($r.Notes) | Should -Be @('PDF Reader desktop shortcut could not be created')
    @($script:activity.Text) | Should -Contain 'PdfCraft 0.9.0 installed' }
  It 'no Craft config is Failed and installs nothing' {
    $ctx.Config.apps.PSObject.Properties.Remove('craft')
    (Invoke-StepCraftApps -Context $ctx).Message | Should -Be 'Craft apps are not configured'; Should -Invoke Install-CraftItem -Times 0 -Exactly }

  # Beyond the brief's table.
  It 'an unknown signer key is Failed(Craft apps are not configured) and installs nothing' {
    $ctx.Config.apps.craft.signer = 'nobody'; $r = Invoke-StepCraftApps -Context $ctx
    $r.Status | Should -Be 'Failed'; $r.Message | Should -Be 'Craft apps are not configured'; Should -Invoke Install-CraftItem -Times 0 -Exactly }
  It 'an empty item list is Failed(Craft apps are not configured)' {
    $ctx.Config.apps.craft.items = @(); (Invoke-StepCraftApps -Context $ctx).Message | Should -Be 'Craft apps are not configured' }
  It 'an app failing and the launcher failing: Failed, the launcher only as a Note, every activity line said' {
    $script:outcome['WordCraft'] = @{ Status = 'Failed'; Version = '0.8.0'; Reason = 'msiexec 1603' }
    $script:outcome['ArtCraft Launcher'] = @{ Status = 'Failed'; Version = ''; Reason = 'release lookup failed' }
    $r = Invoke-StepCraftApps -Context $ctx
    $r.Status | Should -Be 'Failed'; $r.Message | Should -BeExactly 'Not installed: WordCraft (msiexec 1603)'
    @($r.Notes) | Should -Be @('ArtCraft Launcher could not be installed'); @($script:activity).Count | Should -Be 5
    @($script:activity.Text) | Should -Contain 'ArtCraft Launcher not installed - release lookup failed' }
  It 'a launcher already up to date has no shortcut text; an app with a renamed shortcut has' {
    $script:outcome['ArtCraft Launcher'] = @{ Status = 'Current'; Version = '0.5.1'; Reason = '' }; $script:shortcutStatus = 'Renamed'
    $null = Invoke-StepCraftApps -Context $ctx
    @($script:activity.Text) | Should -Contain 'ArtCraft Launcher 0.5.1 already up to date'; @($script:activity.Text) | Should -Contain 'WordCraft 0.8.0 installed - desktop shortcut: Word' }
  It 'an app not yet installed gets an empty installed version' {
    $null = Invoke-StepCraftApps -Context $ctx
    Should -Invoke Install-CraftItem -Times 4 -Exactly -ParameterFilter { $InstalledVersion -eq '' } }
  It 'no Reboot and no Data' { $r = Invoke-StepCraftApps -Context $ctx; $r.Reboot | Should -Be 'None'; $r.Data.Count | Should -Be 0 }
  It 'nothing installed (apps current, launcher failed) is Done(Craft apps already up to date) with the launcher Note (C-R3)' {
    foreach ($n in 'WordCraft', 'GridCraft', 'DeckCraft', 'PdfCraft') { $script:outcome[$n] = @{ Status = 'Current'; Version = '1.0'; Reason = '' } }
    $script:outcome['ArtCraft Launcher'] = @{ Status = 'Failed'; Version = ''; Reason = 'release lookup failed' }
    $r = Invoke-StepCraftApps -Context $ctx; $r.Status | Should -Be 'Done'; $r.Message | Should -Be 'Craft apps already up to date'
    @($r.Notes) | Should -Be @('ArtCraft Launcher could not be installed') }
  It 'one item installed and the rest current is Craft apps installed' {
    foreach ($n in 'WordCraft', 'GridCraft', 'PdfCraft', 'ArtCraft Launcher') { $script:outcome[$n] = @{ Status = 'Current'; Version = '1.0'; Reason = '' } }
    (Invoke-StepCraftApps -Context $ctx).Message | Should -Be 'Craft apps installed' }
}
