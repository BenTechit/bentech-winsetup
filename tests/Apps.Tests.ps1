# tests/Apps.Tests.ps1
# Task 12: Chrome, AnyDesk, 7-Zip, Office and default-browser steps.
#
# SAFETY: this runs on a real PC, and the steps install and uninstall software, download files and
# change file associations and policies. Nothing here may do any of that. Every test that reaches
# the system runs after Initialize-AppMocks (each Describe calls it from BeforeEach), which replaces
# EVERY command the steps can reach with a recorder: Invoke-External, Get-RemoteFile, Get-RemoteText,
# Test-FileSignature, Invoke-WingetInstall, Test-Path, Get-ItemProperty, New-Item, New-ItemProperty,
# Get-Content, Start-Sleep, Write-SetupLog and Get-ShellDefaultBrowserProgId (the AssocQueryString
# P/Invoke wrapper). The only real file I/O is inside $TestDrive: the XML files the steps write, and
# the placeholder "downloads" the Get-RemoteFile mock creates there.
BeforeAll {
  foreach ($f in 'StepResult', 'Logging', 'Activity', 'Process', 'Download') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
  . "$PSScriptRoot\..\src\Steps\Winget.ps1"
  foreach ($f in 'Apps', 'Office', 'DefaultBrowser') { . "$PSScriptRoot\..\src\Steps\$f.ps1" }
  # Report.ps1 holds Get-InstalledAppVersions, which the steps read for the activity feed (mocked below).
  . "$PSScriptRoot\..\src\Report\Report.ps1"
  . "$PSScriptRoot\..\src\Common\Config.ps1"
  $script:ConfigFile = "$PSScriptRoot\..\config\config.json"
  $script:cfg = Read-SetupConfig -Path $script:ConfigFile
  # The config text is read once here: Get-Content is mocked inside the tests, so Read-SetupConfig
  # cannot be used there.
  $script:ConfigJson = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)

  # A fresh config object per call, so a test can change a timeout without touching the others.
  function New-AppContext {
    param([Parameter(Mandatory)][string]$Dir, [string]$Arch = 'x64', [string]$Office = 'BUSINESS')
    @{
      Config      = ($script:ConfigJson | ConvertFrom-Json)
      State       = @{
        Machine = @{ Arch = $Arch }
        Choices = @{ Mode = 'DESKTOP'; SevenZip = $true; Office = $Office }
        RebootCount = 3
        AnyDeskId   = $null
      }
      Root        = $Dir
      LogDir      = (Join-Path $Dir 'Logs')
      DownloadDir = (Join-Path $Dir 'Downloads')
      ScriptPath  = (Join-Path $Dir 'setup.ps1')
      StatePath   = (Join-Path $Dir 'state.json')
    }
  }

  function New-TestDir {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($d)
    return $d
  }

  # Turns every command the steps can reach into a recorder. Call from BeforeEach.
  #   $script:logs        one hashtable per Write-SetupLog call
  #   $script:sleeps      one hashtable per Start-Sleep call (Seconds, Milliseconds)
  #   $script:ext         one hashtable per Invoke-External call; $script:extHandler answers it
  #   $script:existing    the paths Test-Path answers $true for (files, folders and registry keys)
  #   $script:downloads   one hashtable per Get-RemoteFile call; a placeholder file is created at Destination
  #   $script:sigCalls    one hashtable per Test-FileSignature call; $script:sigBad lists the file names that fail
  #   $script:wingetCalls one hashtable per Invoke-WingetInstall call; $script:wingetResult is its answer
  #   $script:regRead     registry path -> hashtable of values for Get-ItemProperty ($null result when absent)
  #   $script:regKeys     the New-Item paths; $script:regValues one hashtable per New-ItemProperty call
  #   $script:fileText    path -> text for Get-Content
  #   $script:activity    one hashtable (Text, LogText) per Add-SetupActivity call
  function Initialize-AppMocks {
    $script:activity = New-Object System.Collections.ArrayList
    $script:logs = New-Object System.Collections.ArrayList
    $script:sleeps = New-Object System.Collections.ArrayList
    $script:ext = New-Object System.Collections.ArrayList
    $script:extHandler = { param($c) @{ ExitCode = 0; TimedOut = $false; Output = '' } }
    $script:existing = @()
    $script:downloads = New-Object System.Collections.ArrayList
    $script:downloadError = $null
    $script:sigCalls = New-Object System.Collections.ArrayList
    $script:sigBad = @()
    $script:wingetCalls = New-Object System.Collections.ArrayList
    $script:wingetResult = New-StepResult -Status Done -Message 'Microsoft.OfficeDeploymentTool: installed'
    $script:pageHtml = ''
    $script:pageError = $null
    $script:pageCalls = New-Object System.Collections.ArrayList
    $script:regRead = @{}
    $script:regReadThrows = $false
    $script:regKeys = New-Object System.Collections.ArrayList
    $script:regValues = New-Object System.Collections.ArrayList
    $script:regWriteThrows = $false
    $script:regWriteMessage = $null
    $script:fileText = @{}
    $script:fileReadThrows = $false
    $script:shellProgId = $null
    $script:shellThrows = $false
    $script:shellCalls = 0

    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    Mock Add-SetupActivity { [void]$script:activity.Add(@{ Text = $Text; LogText = $LogText }) }
    Mock Get-InstalledAppVersions { @{} }
    Mock Start-Sleep { [void]$script:sleeps.Add(@{ Seconds = $Seconds; Milliseconds = $Milliseconds }) }
    Mock Test-Path { return ($script:existing -contains $LiteralPath) }
    Mock Invoke-External {
      $call = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes; CaptureOutput = [bool]$CaptureOutput }
      [void]$script:ext.Add($call)
      & $script:extHandler $call
    }
    Mock Get-RemoteFile {
      [void]$script:downloads.Add(@{ Url = $Url; Destination = $Destination })
      if ($script:downloadError) { throw $script:downloadError }
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
      [IO.File]::WriteAllText($Destination, 'placeholder')
      return $Destination
    }
    Mock Get-RemoteText {
      [void]$script:pageCalls.Add($Url)
      if ($script:pageError) { throw $script:pageError }
      return $script:pageHtml
    }
    Mock Test-FileSignature {
      [void]$script:sigCalls.Add(@{ Path = $Path; Signers = @($AllowedSigners) })
      return (-not ($script:sigBad -contains (Split-Path -Leaf $Path)))
    }
    Mock Invoke-WingetInstall {
      [void]$script:wingetCalls.Add(@{ Id = $Id; Source = $Source })
      return $script:wingetResult
    }
    Mock Get-ItemProperty {
      if ($script:regReadThrows) { throw 'Requested registry access is not allowed' }
      $values = $script:regRead[[string]$LiteralPath]
      if ($null -eq $values) { return $null }
      return [pscustomobject]$values
    }
    Mock New-Item { [void]$script:regKeys.Add([string]$Path); $script:existing += [string]$Path }
    Mock New-ItemProperty {
      # Write-Error, not throw: the registry provider reports a refusal as a non-terminating error (I1).
      if ($script:regWriteThrows) { Write-Error -Message $(if ($script:regWriteMessage) { $script:regWriteMessage } else { 'Requested registry access is not allowed' }) -Category PermissionDenied; return }
      [void]$script:regValues.Add(@{ Path = [string]$LiteralPath; Name = $Name; Value = $Value; Type = [string]$PropertyType })
    }
    Mock Get-Content {
      if ($script:fileReadThrows) { throw 'The process cannot access the file' }
      return $script:fileText[[string]$LiteralPath]
    }
    Mock Get-ShellDefaultBrowserProgId {
      $script:shellCalls++
      if ($script:shellThrows) { throw 'AssocQueryString failed' }
      return $script:shellProgId
    }
  }

  function Set-ChromeInstalled { $script:existing += "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" }
}

# --- the brief's own tests (verbatim) ---------------------------------------------------------
Describe 'Chrome/AnyDesk' {
  It 'picks the ARM64 MSI' { Get-ChromeMsiUrl -Config $cfg -Arch ARM64 | Should -Match '_arm64\.msi$' }
  It 'reads an id from --get-id output' { Get-AnyDeskIdFromText -Text "`r`n 123456789 `r`n" | Should -Be '123456789' }
  It 'ignores non-id output' { Get-AnyDeskIdFromText -Text 'Service not running' | Should -BeNullOrEmpty }
  It 'reads an id from service.conf' { Get-AnyDeskIdFromConf -Text "ad.anynet.alias=x`nad.anynet.id=1234567890`n" | Should -Be '1234567890' }
  It 'never sets a password or unattended access' { $a = Get-AnyDeskInstallArgs -InstallDir 'C:\Program Files (x86)\AnyDesk'; $a | Should -Be '--install "C:\Program Files (x86)\AnyDesk" --start-with-win --create-shortcuts --create-desktop-icon --silent --update-auto'; $a | Should -Not -Match 'password' }
}
Describe 'Office' {
  It 'builds the business XML with Hebrew first' {
    $x = [xml](New-OfficeConfigXml -ProductId 'O365BusinessRetail' -Languages @('he-il','en-us') -ExcludeApps @('Groove','Lync') -Channel 'Current' -Edition '64')
    $x.Configuration.Add.Channel | Should -Be 'Current'; $x.Configuration.Add.Product.ID | Should -Be 'O365BusinessRetail'
    $x.Configuration.Add.Product.Language[0].ID | Should -Be 'he-il'; $x.Configuration.Display.AcceptEULA | Should -Be 'TRUE'
    $x.Configuration.Property.Name | Should -Be 'FORCEAPPSHUTDOWN'; $x.Configuration.SelectSingleNode('RemoveMSI') | Should -Not -BeNullOrEmpty
  }
  It 'detects an installed product' { Test-OfficeInstalled -ProductReleaseIds 'O365HomePremRetail,ProofingTools' -ProductId 'O365HomePremRetail' | Should -BeTrue }
}
Describe 'default browser' {
  It 'suggests Chrome for 4 identifiers' { $x = [xml](New-DefaultAssociationsXml -ProgId ChromeHTML -ApplicationName 'Google Chrome'); @($x.DefaultAssociations.Association).Count | Should -Be 4; ($x.DefaultAssociations.Association | ? Identifier -eq 'https').Suggested | Should -Be 'true' }
  It 'prefers UserChoiceLatest' { Resolve-DefaultBrowserProgId -LatestProgId 'ChromeHTML' -LegacyProgId 'MSEdgeHTM' | Should -Be 'ChromeHTML' }
  It 'falls back to legacy' { Resolve-DefaultBrowserProgId -LatestProgId $null -LegacyProgId 'MSEdgeHTM' | Should -Be 'MSEdgeHTM' }
}

# --- pure helpers -----------------------------------------------------------------------------
Describe 'Get-ChromeMsiUrl' {
  It 'picks the x64 MSI' { Get-ChromeMsiUrl -Config $script:cfg -Arch x64 | Should -Be $script:cfg.apps.chrome.msi.x64 }
  It 'throws for an architecture the config does not list' { { Get-ChromeMsiUrl -Config $script:cfg -Arch 'x86' } | Should -Throw }
}

Describe 'AnyDesk parsing' {
  It 'takes the first line that is exactly an id' { Get-AnyDeskIdFromText -Text "banner 111111111`r`n222222222`r`n333333333" | Should -Be '222222222' }
  It 'accepts a 10-digit id' { Get-AnyDeskIdFromText -Text '1234567890' | Should -Be '1234567890' }
  It 'rejects 8 and 11 digits' {
    Get-AnyDeskIdFromText -Text '12345678' | Should -BeNullOrEmpty
    Get-AnyDeskIdFromText -Text '12345678901' | Should -BeNullOrEmpty
  }
  It 'handles $null and empty text' {
    Get-AnyDeskIdFromText -Text $null | Should -BeNullOrEmpty
    Get-AnyDeskIdFromText -Text '' | Should -BeNullOrEmpty
    Get-AnyDeskIdFromConf -Text $null | Should -BeNullOrEmpty
  }
  It 'does not take part of a longer service.conf value' { Get-AnyDeskIdFromConf -Text 'ad.anynet.id=12345678901234' | Should -BeNullOrEmpty }
  It 'reads service.conf with CRLF line endings' { Get-AnyDeskIdFromConf -Text "ad.anynet.alias=x`r`nad.anynet.id=987654321`r`nother=1`r`n" | Should -Be '987654321' }
}

Describe 'Test-OfficeInstalled' {
  It 'matches a whole product id only' {
    Test-OfficeInstalled -ProductReleaseIds 'O365HomePremRetail2,ProofingTools' -ProductId 'O365HomePremRetail' | Should -BeFalse
  }
  It 'ignores case and spaces around the commas' {
    Test-OfficeInstalled -ProductReleaseIds 'ProofingTools, o365businessretail ' -ProductId 'O365BusinessRetail' | Should -BeTrue
  }
  It 'is false for an empty or missing value' {
    Test-OfficeInstalled -ProductReleaseIds '' -ProductId 'O365BusinessRetail' | Should -BeFalse
    Test-OfficeInstalled -ProductReleaseIds $null -ProductId 'O365BusinessRetail' | Should -BeFalse
  }
}

Describe 'New-OfficeConfigXml' {
  It 'produces exactly the specified XML with 2-space indentation' {
    $text = New-OfficeConfigXml -ProductId 'O365BusinessRetail' -Languages @('he-il', 'en-us') -ExcludeApps @('Groove', 'Lync') -Channel 'Current' -Edition '64'
    $expected = @(
      '<Configuration>'
      '  <Add OfficeClientEdition="64" Channel="Current">'
      '    <Product ID="O365BusinessRetail">'
      '      <Language ID="he-il" />'
      '      <Language ID="en-us" />'
      '      <ExcludeApp ID="Groove" />'
      '      <ExcludeApp ID="Lync" />'
      '    </Product>'
      '  </Add>'
      '  <RemoveMSI />'
      '  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />'
      '  <Updates Enabled="TRUE" />'
      '  <Display Level="None" AcceptEULA="TRUE" />'
      '</Configuration>'
    )
    @($text -split "`r?`n") | Should -Be $expected
  }
  It 'keeps the languages in the order given and writes one ExcludeApp per app' {
    $x = [xml](New-OfficeConfigXml -ProductId 'O365HomePremRetail' -Languages @('en-us', 'he-il', 'fr-fr') -ExcludeApps @('Groove') -Channel 'Current' -Edition '64')
    @($x.Configuration.Add.Product.Language.ID) | Should -Be @('en-us', 'he-il', 'fr-fr')
    @($x.Configuration.Add.Product.ExcludeApp).Count | Should -Be 1
  }
  It 'escapes characters that are special in XML' {
    $x = [xml](New-OfficeConfigXml -ProductId 'A&B' -Languages @('he-il') -ExcludeApps @() -Channel 'Cur"rent' -Edition '64')
    $x.Configuration.Add.Product.ID | Should -Be 'A&B'
    $x.Configuration.Add.Channel | Should -Be 'Cur"rent'
  }
}

Describe 'New-DefaultAssociationsXml' {
  It 'writes an XML declaration and the four identifiers in order' {
    $text = New-DefaultAssociationsXml -ProgId 'ChromeHTML' -ApplicationName 'Google Chrome'
    $text | Should -Match '^<\?xml version="1\.0" encoding="UTF-8"\?>'
    $x = [xml]$text
    @($x.DefaultAssociations.Association.Identifier) | Should -Be @('.htm', '.html', 'http', 'https')
  }
  It 'gives every association the same ProgId, name, Version and Suggested' {
    $x = [xml](New-DefaultAssociationsXml -ProgId 'ChromeHTML' -ApplicationName 'Google Chrome')
    foreach ($a in $x.DefaultAssociations.Association) {
      $a.ProgId | Should -Be 'ChromeHTML'
      $a.ApplicationName | Should -Be 'Google Chrome'
      $a.Version | Should -Be '1'
      $a.Suggested | Should -Be 'true'
    }
  }
}

# --- Test-ChromeInstalled ---------------------------------------------------------------------
Describe 'Test-ChromeInstalled' {
  BeforeEach { Initialize-AppMocks }
  It 'is false when chrome.exe is in neither Program Files folder' { Test-ChromeInstalled | Should -BeFalse }
  It 'finds the Program Files copy' {
    $script:existing = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe")
    Test-ChromeInstalled | Should -BeTrue
  }
  It 'finds the Program Files (x86) copy' {
    $script:existing = @("${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
    Test-ChromeInstalled | Should -BeTrue
  }
}

# --- Invoke-StepChrome ------------------------------------------------------------------------
Describe 'Invoke-StepChrome' {
  BeforeEach {
    Initialize-AppMocks
    $script:ctx = New-AppContext -Dir (New-TestDir)
    $script:msi = Join-Path $script:ctx.DownloadDir 'chrome.msi'
    $script:msiExe = Join-Path $env:windir 'System32\msiexec.exe'
    $script:codes = @(0)
    $script:runs = 0
    $script:extHandler = {
      param($c)
      $i = [Math]::Min($script:runs, $script:codes.Count - 1)
      $script:runs++
      if ($script:codes[$i] -eq 'timeout') { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
      return @{ ExitCode = $script:codes[$i]; TimedOut = $false; Output = '' }
    }
  }
  It 'is Done without downloading when chrome.exe is already there' {
    Set-ChromeInstalled
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Already installed'
    Should -Invoke -CommandName Get-RemoteFile -Times 0 -Exactly
    Should -Invoke -CommandName Invoke-External -Times 0 -Exactly
  }
  It 'downloads the x64 MSI, checks the Google signature and installs it silently' {
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:downloads.Count | Should -Be 1
    $script:downloads[0].Url | Should -Be $script:cfg.apps.chrome.msi.x64
    $script:downloads[0].Destination | Should -Be $script:msi
    $script:sigCalls[0].Path | Should -Be $script:msi
    $script:sigCalls[0].Signers | Should -Contain 'Google LLC'
    $script:ext.Count | Should -Be 1
    $script:ext[0].FilePath | Should -Be $script:msiExe
    $script:ext[0].ArgumentList | Should -Be "/i `"$($script:msi)`" /qn /norestart"
    $script:ext[0].TimeoutMinutes | Should -Be 20
  }
  It 'uses the ARM64 MSI on an ARM64 machine' {
    $script:ctx.State.Machine.Arch = 'ARM64'
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:downloads[0].Url | Should -Match '_arm64\.msi$'
  }
  It 'treats 3010 and 1641 (reboot needed) as Done' {
    foreach ($code in 3010, 1641) {
      $script:codes = @($code); $script:runs = 0
      (Invoke-StepChrome -Context $script:ctx).Status | Should -Be 'Done'
    }
  }
  It 'waits 60 seconds on 1618 and tries again' {
    $script:codes = @(1618, 0)
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:ext.Count | Should -Be 2
    $script:sleeps.Count | Should -Be 1
    $script:sleeps[0].Seconds | Should -Be 60
  }
  It 'makes the wait injectable' {
    $script:codes = @(1618, 0)
    $null = Invoke-StepChrome -Context $script:ctx -RetrySeconds 7
    $script:sleeps[0].Seconds | Should -Be 7
  }
  It 'gives up after 3 tries and reports the exit code' {
    $script:codes = @(1618)
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Chrome install failed (msiexec 1618)'
    $script:ext.Count | Should -Be 3
    $script:sleeps.Count | Should -Be 2
  }
  It 'fails at once on any other exit code, with the code in the message' {
    $script:codes = @(1603)
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Chrome install failed (msiexec 1603)'
    $script:ext.Count | Should -Be 1
    $script:sleeps.Count | Should -Be 0
  }
  It 'fails when msiexec times out' {
    $script:codes = @('timeout')
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^Chrome install failed \(msiexec timed out\)$'
    $script:ext.Count | Should -Be 1
  }
  It 'fails when msiexec cannot be started' {
    $script:extHandler = { param($c) throw 'Cannot start msiexec' }
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^Chrome install failed'
  }
  It 'rejects an installer with a bad signature, deletes it and never runs it' {
    $script:sigBad = @('chrome.msi')
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Chrome installer signature check failed'
    [IO.File]::Exists($script:msi) | Should -BeFalse
    $script:ext.Count | Should -Be 0
  }
  It 'reports a download failure with the reason' {
    $script:downloadError = 'download failed after 3 attempts: https://example.test/chrome.msi'
    $r = Invoke-StepChrome -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Chrome download failed: download failed after 3 attempts: https://example.test/chrome.msi'
    $script:ext.Count | Should -Be 0
  }

  # --- the activity feed (Task 10) ---
  It 'writes its installed version to the activity feed' {
    Mock Get-InstalledAppVersions { @{ 'Google Chrome' = '141.0.7390.55' } }
    (Invoke-StepChrome -Context $script:ctx -RetrySeconds 0).Status | Should -Be 'Done'
    @($script:activity.Text) | Should -Contain 'Google Chrome 141.0.7390.55 installed'
  }
  It 'an already installed Chrome writes no version line' {
    Set-ChromeInstalled
    Mock Get-InstalledAppVersions { @{ 'Google Chrome' = '141.0.7390.55' } }
    $null = Invoke-StepChrome -Context $script:ctx
    $script:activity.Count | Should -Be 0
  }
  It 'a version that cannot be found still writes the line, without a version' {
    (Invoke-StepChrome -Context $script:ctx -RetrySeconds 0).Status | Should -Be 'Done'
    @($script:activity.Text) | Should -Be @('Google Chrome installed')
  }
  It 'a version lookup that throws still leaves the step Done, with a WARN' {
    Mock Get-InstalledAppVersions { throw 'registry gone' }
    (Invoke-StepChrome -Context $script:ctx -RetrySeconds 0).Status | Should -Be 'Done'
    @($script:activity.Text) | Should -Be @('Google Chrome installed')
    @($script:logs | Where-Object { $_.Level -eq 'WARN' }).Count | Should -BeGreaterOrEqual 1
  }
  It 'a failed install writes no version line' {
    $script:codes = @(1603)
    (Invoke-StepChrome -Context $script:ctx -RetrySeconds 0).Status | Should -Be 'Failed'
    $script:activity.Count | Should -Be 0
  }
}

# --- Invoke-StepAnyDesk -----------------------------------------------------------------------
Describe 'Invoke-StepAnyDesk' {
  BeforeEach {
    Initialize-AppMocks
    $script:ctx = New-AppContext -Dir (New-TestDir)
    $script:ctx.Config.timeoutsMinutes.anydeskId = 0          # a single --get-id attempt
    $script:installDir = $script:ctx.Config.apps.anydesk.installDir
    $script:anyExe = Join-Path $script:installDir 'AnyDesk.exe'
    $script:downloaded = Join-Path $script:ctx.DownloadDir 'AnyDesk.exe'
    $script:confPath = Join-Path $env:ProgramData 'AnyDesk\service.conf'
    $script:getIdOutput = "`r`n 123456789 `r`n"
    $script:installCode = 0
    $script:extHandler = {
      param($c)
      if ($c.FilePath -eq $script:downloaded) {
        if ($script:installCode -eq 0) { $script:existing += $script:anyExe }     # the installer put AnyDesk.exe in place
        if ($script:installCode -eq 'timeout') { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
        return @{ ExitCode = $script:installCode; TimedOut = $false; Output = '' }
      }
      return @{ ExitCode = 0; TimedOut = $false; Output = $script:getIdOutput }
    }
  }
  It 'reads the ID from an AnyDesk that is already installed, without installing' {
    $script:existing = @($script:anyExe)
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:ctx.State.AnyDeskId | Should -Be '123456789'
    $script:ext.Count | Should -Be 1
    $script:ext[0].FilePath | Should -Be $script:anyExe
    $script:ext[0].ArgumentList | Should -Be '--get-id'
    $script:ext[0].CaptureOutput | Should -BeTrue
    $script:ext[0].TimeoutMinutes | Should -Be 1
    Should -Invoke -CommandName Get-RemoteFile -Times 0 -Exactly
  }
  It 'downloads, checks the signature, installs without a password and reads the ID' {
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:ctx.State.AnyDeskId | Should -Be '123456789'
    $script:downloads[0].Url | Should -Be $script:ctx.Config.apps.anydesk.url
    $script:downloads[0].Destination | Should -Be $script:downloaded
    $script:sigCalls[0].Path | Should -Be $script:downloaded
    $script:sigCalls[0].Signers | Should -Contain 'AnyDesk Software GmbH'
    $script:ext[0].FilePath | Should -Be $script:downloaded
    $script:ext[0].ArgumentList | Should -Be (Get-AnyDeskInstallArgs -InstallDir $script:installDir)
    $script:ext[0].ArgumentList | Should -Not -Match 'password'
    $script:ext[0].TimeoutMinutes | Should -Be 30
    $script:ext[1].ArgumentList | Should -Be '--get-id'
  }
  It 'polls --get-id every 5 seconds until the ID appears' {
    $script:ctx.Config.timeoutsMinutes.anydeskId = 2
    $script:existing = @($script:anyExe)
    $script:idRuns = 0
    $script:extHandler = {
      param($c)
      $script:idRuns++
      $out = if ($script:idRuns -lt 3) { 'Service not running' } else { '987654321' }
      @{ ExitCode = 0; TimedOut = $false; Output = $out }
    }
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:ctx.State.AnyDeskId | Should -Be '987654321'
    $script:ext.Count | Should -Be 3
    $script:sleeps.Count | Should -Be 2
    $script:sleeps[0].Milliseconds | Should -Be 5000
  }
  It 'makes the poll interval injectable' {
    $script:ctx.Config.timeoutsMinutes.anydeskId = 2
    $script:existing = @($script:anyExe)
    $script:getIdOutput = 'Service not running'
    $script:idRuns = 0
    $script:extHandler = {
      param($c)
      $script:idRuns++
      $out = if ($script:idRuns -lt 2) { 'Service not running' } else { '987654321' }
      @{ ExitCode = 0; TimedOut = $false; Output = $out }
    }
    $null = Invoke-StepAnyDesk -Context $script:ctx -PollSeconds 1
    $script:sleeps[0].Milliseconds | Should -Be 1000
  }
  It 'falls back to service.conf when --get-id gives nothing' {
    $script:existing = @($script:anyExe, $script:confPath)
    $script:getIdOutput = 'Service not running'
    $script:fileText[$script:confPath] = "ad.anynet.alias=x`nad.anynet.id=1234567890`n"
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:ctx.State.AnyDeskId | Should -Be '1234567890'
  }
  It 'reads service.conf with Get-Content -Raw' {
    $script:existing = @($script:anyExe, $script:confPath)
    $script:getIdOutput = ''
    $script:fileText[$script:confPath] = 'ad.anynet.id=1234567890'
    $null = Invoke-StepAnyDesk -Context $script:ctx
    Should -Invoke -CommandName Get-Content -Times 1 -Exactly -ParameterFilter { $Raw -and $LiteralPath -eq $script:confPath }
  }
  It 'is Done with a Note when no ID can be found' {
    $script:existing = @($script:anyExe)
    $script:getIdOutput = 'Service not running'
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $r.Notes | Should -Contain 'AnyDesk ID not available yet'
    $script:ctx.State.AnyDeskId | Should -BeNullOrEmpty
  }
  It 'survives an unreadable service.conf' {
    $script:existing = @($script:anyExe, $script:confPath)
    $script:getIdOutput = ''
    $script:fileReadThrows = $true
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $r.Notes | Should -Contain 'AnyDesk ID not available yet'
  }
  It 'survives a --get-id run that cannot be started' {
    $script:existing = @($script:anyExe, $script:confPath)
    $script:fileText[$script:confPath] = 'ad.anynet.id=1234567890'
    $script:extHandler = { param($c) throw 'Cannot start AnyDesk.exe' }
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:ctx.State.AnyDeskId | Should -Be '1234567890'
  }
  It 'rejects an installer with a bad signature, deletes it and never runs it' {
    $script:sigBad = @('AnyDesk.exe')
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'AnyDesk installer signature check failed'
    [IO.File]::Exists($script:downloaded) | Should -BeFalse
    $script:ext.Count | Should -Be 0
  }
  It 'reports a download failure with the reason' {
    $script:downloadError = 'download failed after 3 attempts: https://download.anydesk.com/AnyDesk.exe'
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'AnyDesk download failed: download failed after 3 attempts: https://download.anydesk.com/AnyDesk.exe'
  }
  It 'fails with the exit code when the installer fails' {
    $script:installCode = 5
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'AnyDesk install failed (5)'
    $script:ext.Count | Should -Be 1
  }
  It 'fails when the installer times out' {
    $script:installCode = 'timeout'
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'AnyDesk install timed out'
  }
  It 'fails when the installer reports success but AnyDesk.exe never appears' {
    $script:extHandler = { param($c) @{ ExitCode = 0; TimedOut = $false; Output = '' } }
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^AnyDesk install failed'
  }
  It 'never writes the ID to the log or into a result message' {
    $id = '123456789'
    $r = Invoke-StepAnyDesk -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:ctx.State.AnyDeskId | Should -Be $id
    ($script:logs | ConvertTo-Json -Depth 6 -Compress) | Should -Not -Match $id
    ($r | ConvertTo-Json -Depth 6 -Compress) | Should -Not -Match $id
  }
  It 'does not put an ID into a Failed message either' {
    $script:installCode = 5
    $script:getIdOutput = '123456789'
    $r = Invoke-StepAnyDesk -Context $script:ctx
    ($r | ConvertTo-Json -Depth 6 -Compress) | Should -Not -Match '123456789'
  }
  It 'the ID goes to the activity feed with a log text that has no ID, so setup.log never sees it' {
    Mock Get-InstalledAppVersions { @{ 'AnyDesk' = '9.0.4' } }
    $null = Invoke-StepAnyDesk -Context $script:ctx -PollSeconds 0
    $script:activity.Count | Should -Be 1
    $script:activity[0].Text | Should -Be 'AnyDesk 9.0.4 - ID 123456789'
    $script:activity[0].LogText | Should -Be 'AnyDesk 9.0.4 - ID recorded'
    $script:activity[0].LogText | Should -Not -Match '123456789'
  }
  It 'the activity line has no stray space when the version is not known' {
    $null = Invoke-StepAnyDesk -Context $script:ctx -PollSeconds 0
    $script:activity[0].Text | Should -Be 'AnyDesk - ID 123456789'
    $script:activity[0].LogText | Should -Be 'AnyDesk - ID recorded'
  }
  It 'no ID, no activity line' {
    $script:existing = @($script:anyExe)
    $script:getIdOutput = 'Service not running'
    $null = Invoke-StepAnyDesk -Context $script:ctx
    $script:activity.Count | Should -Be 0
  }
  It 'an AnyDesk that was already installed still shows its ID' {
    $script:existing = @($script:anyExe)
    $null = Invoke-StepAnyDesk -Context $script:ctx
    $script:activity[0].Text | Should -Be 'AnyDesk - ID 123456789'
  }
  It 'Find-AnyDeskId shows its limit while it polls and removes it after' {
    Clear-SetupNow
    $script:limits = New-Object System.Collections.ArrayList
    Mock Read-AnyDeskIdFromServiceConf { [void]$script:limits.Add((Get-SetupNow).Wait.LimitMinutes); '123456789' }
    Find-AnyDeskId -Exe $script:anyExe -TimeoutMinutes 3 -PollSeconds 0.01 | Should -Be '123456789'
    @($script:limits) | Should -Be @(3); (Get-SetupNow).Wait | Should -BeNullOrEmpty
  }
}

# --- Invoke-StepSevenZip ----------------------------------------------------------------------
Describe 'Invoke-StepSevenZip' {
  BeforeEach { Initialize-AppMocks; $script:ctx = New-AppContext -Dir (New-TestDir) }
  It 'hands the configured winget id to Invoke-WingetInstall and returns its result' {
    $script:wingetResult = New-StepResult -Status Done -Message '7zip.7zip: installed'
    $r = Invoke-StepSevenZip -Context $script:ctx
    $r | Should -Be $script:wingetResult
    $script:wingetCalls.Count | Should -Be 1
    $script:wingetCalls[0].Id | Should -Be '7zip.7zip'
    $script:wingetCalls[0].Source | Should -Be 'winget'
  }
  It 'passes a winget failure through unchanged' {
    $script:wingetResult = New-StepResult -Status Failed -Message 'winget unavailable'
    $r = Invoke-StepSevenZip -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
    $script:activity.Count | Should -Be 0
  }
  It 'writes its version when winget installed it' {
    Mock Get-InstalledAppVersions { @{ '7-Zip' = '24.08' } }
    $null = Invoke-StepSevenZip -Context $script:ctx
    @($script:activity.Text) | Should -Be @('7-Zip 24.08 installed')
  }
  It 'a version that cannot be found still writes the line' {
    $null = Invoke-StepSevenZip -Context $script:ctx
    @($script:activity.Text) | Should -Be @('7-Zip installed')
  }
  It 'a skipped winget install writes no line' {
    $script:wingetResult = New-StepResult -Status Skipped -Message '7zip.7zip: no package or installer for this system'
    $null = Invoke-StepSevenZip -Context $script:ctx
    $script:activity.Count | Should -Be 0
  }
}

Describe 'Get-AppVersionText' {
  BeforeEach { Initialize-AppMocks }
  It 'is the version of the named app' {
    Mock Get-InstalledAppVersions { @{ 'Google Chrome' = ' 141.0.1 '; '7-Zip' = '24.08' } }
    Get-AppVersionText -Name 'Google Chrome' | Should -Be '141.0.1'
  }
  It 'is an empty string for an app that is not listed' { Get-AppVersionText -Name 'AnyDesk' | Should -BeExactly '' }
  It 'is an empty string when the lookup throws' {
    Mock Get-InstalledAppVersions { throw 'registry gone' }
    Get-AppVersionText -Name 'AnyDesk' | Should -BeExactly ''
  }
}

# --- Invoke-StepOffice ------------------------------------------------------------------------
Describe 'Invoke-StepOffice' {
  BeforeEach {
    Initialize-AppMocks
    $script:ctx = New-AppContext -Dir (New-TestDir)
    $script:odt = $script:ctx.Config.apps.office.odtSetupPath
    $script:xmlPath = Join-Path $script:ctx.DownloadDir 'office.xml'
    $script:odtDir = Join-Path $script:ctx.DownloadDir 'ODT'
    $script:odtExe = Join-Path $script:ctx.DownloadDir 'officedeploymenttool.exe'
    $script:extractedSetup = Join-Path $script:odtDir 'setup.exe'
    $script:releaseKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $script:configureCode = 0
    $script:extractCode = 0
    $script:extHandler = {
      param($c)
      if ($c.ArgumentList -like '/configure*') {
        if ($script:configureCode -eq 'timeout') { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
        return @{ ExitCode = $script:configureCode; TimedOut = $false; Output = '' }
      }
      # the self-extractor
      if ($script:extractCode -eq 0) { $script:existing += $script:extractedSetup }
      return @{ ExitCode = $script:extractCode; TimedOut = $false; Output = '' }
    }
    $script:pageHtml = '<a href="https://download.microsoft.com/download/2/7/A/27AF1BE6-DD20-4CB4-B154-EBAB8A7D4A7E/officedeploymenttool_17531-20046.exe">Download</a>'
  }
  It 'is Skipped when Office was not selected' {
    $script:ctx.State.Choices.Office = 'OFF'
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Office not selected'
    $script:wingetCalls.Count | Should -Be 0
    $script:ext.Count | Should -Be 0
  }
  It 'is Done without installing when the product is already installed' {
    $script:regRead[$script:releaseKey] = @{ ProductReleaseIds = 'O365BusinessRetail,ProofingTools' }
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Office already installed'
    $script:wingetCalls.Count | Should -Be 0
    $script:ext.Count | Should -Be 0
  }
  It 'still installs when only the other product is installed' {
    $script:regRead[$script:releaseKey] = @{ ProductReleaseIds = 'O365HomePremRetail' }
    $script:existing = @($script:odt)
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:ext.Count | Should -Be 1
  }
  It 'installs when Office is not installed at all' {
    $script:existing = @($script:odt)
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Office installed'
  }
  It 'installs the ODT with winget, checks setup.exe and runs /configure' {
    $script:existing = @($script:odt)
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:wingetCalls[0].Id | Should -Be 'Microsoft.OfficeDeploymentTool'
    $script:wingetCalls[0].Source | Should -Be 'winget'
    $script:sigCalls.Count | Should -Be 1
    $script:sigCalls[0].Path | Should -Be $script:odt
    $script:sigCalls[0].Signers | Should -Contain 'Microsoft Corporation'
    $script:ext.Count | Should -Be 1
    $script:ext[0].FilePath | Should -Be $script:odt
    $script:ext[0].ArgumentList | Should -Be "/configure `"$($script:xmlPath)`""
    $script:ext[0].TimeoutMinutes | Should -Be 60
    $script:pageCalls.Count | Should -Be 0
  }
  It 'builds the XML for the BUSINESS product' {
    $script:existing = @($script:odt)
    $null = Invoke-StepOffice -Context $script:ctx
    $x = [xml]([IO.File]::ReadAllText($script:xmlPath, [Text.Encoding]::UTF8))
    $x.Configuration.Add.Product.ID | Should -Be 'O365BusinessRetail'
  }
  It 'builds the XML for the HOME product' {
    $script:ctx.State.Choices.Office = 'HOME'
    $script:existing = @($script:odt)
    $null = Invoke-StepOffice -Context $script:ctx
    $x = [xml]([IO.File]::ReadAllText($script:xmlPath, [Text.Encoding]::UTF8))
    $x.Configuration.Add.Product.ID | Should -Be 'O365HomePremRetail'
  }
  It 'checks the installed product ids for the chosen product, not the other one' {
    $script:ctx.State.Choices.Office = 'HOME'
    $script:regRead[$script:releaseKey] = @{ ProductReleaseIds = 'O365HomePremRetail' }
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Message | Should -Be 'Office already installed'
  }
  It 'takes languages, excluded apps, channel and edition from the config' {
    $script:existing = @($script:odt)
    $null = Invoke-StepOffice -Context $script:ctx
    $o = $script:ctx.Config.apps.office
    $expected = New-OfficeConfigXml -ProductId $o.products.BUSINESS -Languages @($o.languages) -ExcludeApps @($o.excludeApps) -Channel $o.channel -Edition $o.edition
    [IO.File]::ReadAllText($script:xmlPath, [Text.Encoding]::UTF8) | Should -Be $expected
    $x = [xml]$expected
    $x.Configuration.Add.Product.Language[0].ID | Should -Be 'he-il'
  }
  It 'writes the XML as UTF-8 without a BOM' {
    $script:existing = @($script:odt)
    $null = Invoke-StepOffice -Context $script:ctx
    $bytes = [IO.File]::ReadAllBytes($script:xmlPath)
    $bytes.Length | Should -BeGreaterThan 3
    $bytes[0] | Should -Be ([byte][char]'<')
  }
  It 'falls back to the download page when winget fails' {
    $script:wingetResult = New-StepResult -Status Failed -Message 'winget unavailable'
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:pageCalls[0] | Should -Be $script:ctx.Config.apps.office.odtFallbackPage
    $script:downloads[0].Url | Should -Be 'https://download.microsoft.com/download/2/7/A/27AF1BE6-DD20-4CB4-B154-EBAB8A7D4A7E/officedeploymenttool_17531-20046.exe'
    $script:downloads[0].Destination | Should -Be $script:odtExe
    $script:sigCalls[0].Path | Should -Be $script:odtExe
    $script:sigCalls[0].Signers | Should -Contain 'Microsoft Corporation'
    $script:ext[0].FilePath | Should -Be $script:odtExe
    $script:ext[0].ArgumentList | Should -Be "/quiet /extract:`"$($script:odtDir)`""
    $script:ext[0].TimeoutMinutes | Should -Be 30
    $script:sigCalls[1].Path | Should -Be $script:extractedSetup
    $script:ext[1].FilePath | Should -Be $script:extractedSetup
    $script:ext[1].ArgumentList | Should -Be "/configure `"$($script:xmlPath)`""
  }
  It 'falls back to the download page when winget succeeds but setup.exe is missing' {
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $script:wingetCalls.Count | Should -Be 1
    $script:pageCalls.Count | Should -Be 1
    $script:ext[1].FilePath | Should -Be $script:extractedSetup
  }
  It 'fails when the download page has no matching link' {
    $script:pageHtml = '<html>nothing here</html>'
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Office Deployment Tool download link not found'
    $script:ext.Count | Should -Be 0
  }
  It 'fails when the download page cannot be read' {
    $script:pageError = 'download failed after 3 attempts: https://www.microsoft.com'
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^Office Deployment Tool page could not be read'
    $script:ext.Count | Should -Be 0
  }
  It 'fails when the ODT download fails' {
    $script:downloadError = 'download failed after 3 attempts: x'
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^Office Deployment Tool download failed'
    $script:ext.Count | Should -Be 0
  }
  It 'rejects a fallback ODT with a bad signature, deletes it and never runs it' {
    $script:sigBad = @('officedeploymenttool.exe')
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Office Deployment Tool signature check failed'
    [IO.File]::Exists($script:odtExe) | Should -BeFalse
    $script:ext.Count | Should -Be 0
  }
  It 'fails when the self-extractor fails' {
    $script:extractCode = 5
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Office Deployment Tool extract failed (5)'
  }
  It 'fails when the extractor leaves no setup.exe' {
    $script:extHandler = { param($c) @{ ExitCode = 0; TimedOut = $false; Output = '' } }
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Office Deployment Tool setup.exe not found after extract'
  }
  It 'does not run a setup.exe whose signer is wrong' {
    $script:existing = @($script:odt)
    $script:sigBad = @('setup.exe')
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Office setup.exe signature check failed'
    $script:ext.Count | Should -Be 0
  }
  It 'fails with the exit code when setup.exe returns non-zero' {
    $script:existing = @($script:odt)
    $script:configureCode = 1603
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Office setup exit 1603'
  }
  It 'treats 3010 and 1641 (restart pending) as Done, ruling R17a' {
    $script:existing = @($script:odt)
    foreach ($code in 3010, 1641) {
      $script:configureCode = $code
      $r = Invoke-StepOffice -Context $script:ctx
      $r.Status | Should -Be 'Done'
      $r.Message | Should -Be 'Office installed (restart pending)'
      $r.Reboot | Should -Be 'None'
    }
  }
  It 'still fails on exit codes next to the success codes' {
    $script:existing = @($script:odt)
    foreach ($code in 1, 3011, 1642, -1) {
      $script:configureCode = $code
      $r = Invoke-StepOffice -Context $script:ctx
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be "Office setup exit $code"
    }
  }
  It 'reports a plain exit 0 as Office installed' {
    $script:existing = @($script:odt)
    (Invoke-StepOffice -Context $script:ctx).Message | Should -Be 'Office installed'
  }
  It 'fails when setup.exe times out' {
    $script:existing = @($script:odt)
    $script:configureCode = 'timeout'
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Office setup timed out'
  }
  It 'fails when setup.exe cannot be started' {
    $script:existing = @($script:odt)
    $script:extHandler = { param($c) throw 'Cannot start setup.exe' }
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match '^Office setup could not be started'
  }
  It 'fails for a choice that is neither OFF nor a configured product' {
    $script:ctx.State.Choices.Office = 'ENTERPRISE'
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Failed'
    $script:ext.Count | Should -Be 0
  }
}

# --- Invoke-StepDefaultBrowser ----------------------------------------------------------------
Describe 'Invoke-StepDefaultBrowser' {
  BeforeEach {
    Initialize-AppMocks
    $script:ctx = New-AppContext -Dir (New-TestDir)
    # The XML lives under %ProgramData%\BenTech (ruling R18), so ProgramData is pointed at a test folder
    # for the length of each test and put back in AfterEach.
    $script:origProgramData = $env:ProgramData
    $script:programData = New-TestDir
    $env:ProgramData = $script:programData
    $script:xmlFolder = Join-Path $script:programData 'BenTech'
    $script:xmlFile = Join-Path $script:xmlFolder 'DefaultAssociations.xml'
    $script:rootXml = Join-Path $script:ctx.Root 'DefaultAssociations.xml'
    $script:policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
  }
  AfterEach { $env:ProgramData = $script:origProgramData }
  It 'puts the associations file under ProgramData\BenTech, where the signed-in user can read it (ruling R18)' {
    Get-DefaultAssociationsPath | Should -Be $script:xmlFile
    Get-DefaultAssociationsPath | Should -Be (Join-Path $env:ProgramData 'BenTech\DefaultAssociations.xml')
  }
  It 'is Skipped when Chrome is not installed, and changes nothing' {
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Chrome not installed'
    [IO.File]::Exists($script:xmlFile) | Should -BeFalse
    [IO.Directory]::Exists($script:xmlFolder) | Should -BeFalse
    Should -Invoke -CommandName New-ItemProperty -Times 0 -Exactly
    Should -Invoke -CommandName New-Item -Times 0 -Exactly
  }
  It 'creates the BenTech folder when it is missing, without touching any ACL' {
    Set-ChromeInstalled
    Mock Set-Acl {}
    [IO.Directory]::Exists($script:xmlFolder) | Should -BeFalse
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Done'
    [IO.Directory]::Exists($script:xmlFolder) | Should -BeTrue
    Should -Invoke -CommandName Set-Acl -Times 0 -Exactly
    Should -Invoke -CommandName Invoke-External -Times 0 -Exactly
  }
  It 'leaves an existing BenTech folder and what is in it alone' {
    Set-ChromeInstalled
    [void][IO.Directory]::CreateDirectory($script:xmlFolder)
    $other = Join-Path $script:xmlFolder 'other.txt'
    [IO.File]::WriteAllText($other, 'keep me')
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Done'
    [IO.File]::ReadAllText($other) | Should -Be 'keep me'
    [IO.File]::Exists($script:xmlFile) | Should -BeTrue
  }
  It 'does not write anything under Root any more' {
    Set-ChromeInstalled
    $null = Invoke-StepDefaultBrowser -Context $script:ctx
    [IO.File]::Exists($script:rootXml) | Should -BeFalse
    @(Get-ChildItem -LiteralPath $script:ctx.Root -Force).Count | Should -Be 0
  }
  It 'writes DefaultAssociations.xml as UTF-8 without a BOM' {
    Set-ChromeInstalled
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $bytes = [IO.File]::ReadAllBytes($script:xmlFile)
    $bytes[0] | Should -Be ([byte][char]'<')
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $text | Should -Be (New-DefaultAssociationsXml -ProgId 'ChromeHTML' -ApplicationName 'Google Chrome')
    @(([xml]$text).DefaultAssociations.Association.Identifier) | Should -Be @('.htm', '.html', 'http', 'https')
  }
  It 'sets DefaultAssociationsConfiguration to that file as a string, creating the key when missing' {
    Set-ChromeInstalled
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Applies at next sign-in'
    $script:regKeys | Should -Contain $script:policyKey
    $script:regValues.Count | Should -Be 1
    $script:regValues[0].Path | Should -Be $script:policyKey
    $script:regValues[0].Name | Should -Be 'DefaultAssociationsConfiguration'
    $script:regValues[0].Value | Should -Be $script:xmlFile
    $script:regValues[0].Value | Should -Be (Get-DefaultAssociationsPath)
    $script:regValues[0].Type | Should -Be 'String'
  }
  It 'does not recreate a policy key that exists' {
    Set-ChromeInstalled
    $script:existing += $script:policyKey
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Done'
    Should -Invoke -CommandName New-Item -Times 0 -Exactly
    $script:regValues.Count | Should -Be 1
  }
  It 'records RebootCountAtSet and a parsable UTC SetAtUtc (ruling R16)' {
    Set-ChromeInstalled
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Data.RebootCountAtSet | Should -Be 3
    $r.Data.SetAtUtc | Should -BeOfType [string]
    $parsed = [datetime]::Parse($r.Data.SetAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $parsed.Kind | Should -Be 'Utc'
    ([datetime]::UtcNow - $parsed).TotalMinutes | Should -BeLessThan 1
    $r.Data.SetAtUtc | Should -Match 'Z$'
  }
  It 'treats a missing RebootCount as 0' {
    Set-ChromeInstalled
    $script:ctx.State.Remove('RebootCount')
    (Invoke-StepDefaultBrowser -Context $script:ctx).Data.RebootCountAtSet | Should -Be 0
  }
  It 'is Skipped (best effort, ruling R17b) with the reason when the policy value cannot be written' {
    Set-ChromeInstalled
    $script:regWriteThrows = $true
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Default browser policy could not be set: Requested registry access is not allowed'
    $r.Reboot | Should -Be 'None'
    $r.Data.Count | Should -Be 0
  }
  It 'is Skipped, with the reason, when the policy key cannot be created' {
    Set-ChromeInstalled
    Mock New-Item { Write-Error -Message 'Attempted to perform an unauthorized operation.' -Category PermissionDenied }
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Default browser policy could not be set: Attempted to perform an unauthorized operation.'
    Should -Invoke -CommandName New-ItemProperty -Times 0 -Exactly
  }
  It 'is Skipped, and sets no policy, when the XML file cannot be written' {
    Set-ChromeInstalled
    # A file named BenTech where the folder should be.
    [IO.File]::WriteAllText($script:xmlFolder, 'a file where the folder should be')
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Match '^Default browser policy could not be set: .+'
    Should -Invoke -CommandName New-ItemProperty -Times 0 -Exactly
  }
  It 'keeps the reason short: first line only, at most 120 characters' {
    Set-ChromeInstalled
    $script:regWriteThrows = $true
    $script:regWriteMessage = ('x' * 300) + "`r`nsecond line"
    $r = Invoke-StepDefaultBrowser -Context $script:ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Not -Match 'second line'
    $r.Message.Substring('Default browser policy could not be set: '.Length).Length | Should -BeLessOrEqual 120
  }
  It 'logs the failure at WARN, not ERROR' {
    Set-ChromeInstalled
    $script:regWriteThrows = $true
    $null = Invoke-StepDefaultBrowser -Context $script:ctx
    $failure = @($script:logs | Where-Object { $_.Message -eq 'Default browser policy could not be set' })
    $failure.Count | Should -Be 1
    $failure[0].Level | Should -Be 'WARN'
  }
}

# --- Get-DefaultBrowserProgId / Get-ChromeRegisteredAppName ----------------------------------
Describe 'Get-DefaultBrowserProgId' {
  BeforeEach {
    Initialize-AppMocks
    $script:base = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https'
  }
  It 'uses the answer of the shell when it has one' {
    $script:shellProgId = 'ChromeHTML'
    $script:regRead["$($script:base)\UserChoice"] = @{ ProgId = 'MSEdgeHTM' }
    Get-DefaultBrowserProgId | Should -Be 'ChromeHTML'
    Should -Invoke -CommandName Get-ItemProperty -Times 0 -Exactly
  }
  It 'reads UserChoiceLatest\ProgId (value ProgId) first when the shell has no answer' {
    $script:regRead["$($script:base)\UserChoiceLatest\ProgId"] = @{ ProgId = 'ChromeHTML' }
    $script:regRead["$($script:base)\UserChoiceLatest"] = @{ ProgId = 'FirefoxURL' }
    $script:regRead["$($script:base)\UserChoice"] = @{ ProgId = 'MSEdgeHTM' }
    Get-DefaultBrowserProgId | Should -Be 'ChromeHTML'
  }
  It 'then reads the UserChoiceLatest key itself' {
    $script:regRead["$($script:base)\UserChoiceLatest"] = @{ ProgId = 'FirefoxURL' }
    $script:regRead["$($script:base)\UserChoice"] = @{ ProgId = 'MSEdgeHTM' }
    Get-DefaultBrowserProgId | Should -Be 'FirefoxURL'
  }
  It 'then falls back to the legacy UserChoice' {
    $script:regRead["$($script:base)\UserChoice"] = @{ ProgId = 'MSEdgeHTM' }
    Get-DefaultBrowserProgId | Should -Be 'MSEdgeHTM'
  }
  It 'falls back to the registry when the shell answer is empty' {
    $script:shellProgId = ''
    $script:regRead["$($script:base)\UserChoice"] = @{ ProgId = 'MSEdgeHTM' }
    Get-DefaultBrowserProgId | Should -Be 'MSEdgeHTM'
  }
  It 'falls back to the registry when the shell call throws' {
    $script:shellThrows = $true
    $script:regRead["$($script:base)\UserChoice"] = @{ ProgId = 'MSEdgeHTM' }
    Get-DefaultBrowserProgId | Should -Be 'MSEdgeHTM'
  }
  It 'returns $null when nothing answers' { Get-DefaultBrowserProgId | Should -BeNullOrEmpty }
  It 'returns $null and does not throw when both the shell and the registry fail' {
    $script:shellThrows = $true
    $script:regReadThrows = $true
    { Get-DefaultBrowserProgId } | Should -Not -Throw
    Get-DefaultBrowserProgId | Should -BeNullOrEmpty
  }
}

Describe 'Resolve-DefaultBrowserProgId' {
  It 'returns $null when both are empty' { Resolve-DefaultBrowserProgId -LatestProgId '' -LegacyProgId $null | Should -BeNullOrEmpty }
  It 'skips an empty latest value' { Resolve-DefaultBrowserProgId -LatestProgId '' -LegacyProgId 'MSEdgeHTM' | Should -Be 'MSEdgeHTM' }
}

Describe 'Get-ChromeRegisteredAppName' {
  BeforeEach { Initialize-AppMocks; $script:regKey = 'HKLM:\SOFTWARE\RegisteredApplications' }
  It 'returns the registered name that starts with Google Chrome' {
    $script:regRead[$script:regKey] = @{ 'Mozilla Firefox 1.0' = 'Software\Mozilla'; 'Google Chrome' = 'Software\Clients\StartMenuInternet\Google Chrome\Capabilities'; PSPath = 'x' }
    Get-ChromeRegisteredAppName | Should -Be 'Google Chrome'
  }
  It 'returns an unusual registered Chrome name as registered' {
    $script:regRead[$script:regKey] = @{ 'Google Chrome 123' = 'Software\x' }
    Get-ChromeRegisteredAppName | Should -Be 'Google Chrome 123'
  }
  It 'falls back to Google Chrome when there is no such value' {
    $script:regRead[$script:regKey] = @{ 'Mozilla Firefox 1.0' = 'Software\Mozilla' }
    Get-ChromeRegisteredAppName | Should -Be 'Google Chrome'
  }
  It 'falls back to Google Chrome when the key cannot be read' {
    $script:regReadThrows = $true
    Get-ChromeRegisteredAppName | Should -Be 'Google Chrome'
  }
}
