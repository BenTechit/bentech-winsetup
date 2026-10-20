# tests/ScreenConnect.Tests.ps1
# The screenconnect step (screenconnect spec 4.3) of src\Steps\ScreenConnect.ps1: the installer link of this
# release, the service state read by its exact name, the installer checks and Invoke-StepScreenConnect.
#
# SAFETY: this runs on Ben's real PC, and running a ScreenConnect installer would enrol it in his ScreenConnect
# list. Nothing here is downloaded, installed or written outside $TestDrive, and no test reads Ben's real
# installer. Get-Service and the installer are always mocked: Initialize-ScMocks replaces Get-RemoteFile (it
# writes the text 'placeholder' into $TestDrive), Test-FileSignature, Get-AuthenticodeSignature, Invoke-External,
# Get-Service, Wait-SetupDelay, Set-SetupNow, Add-SetupActivity and Write-SetupLog with recorders. Test-Path,
# Get-FileHash and Remove-Item are real: the installer is a real $TestDrive file.
BeforeAll {
  foreach ($f in 'StepResult', 'Logging', 'Activity', 'Process', 'Download', 'Config') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
  . "$PSScriptRoot\..\src\Steps\ScreenConnect.ps1"
  $script:ConfigFile = "$PSScriptRoot\..\config\config.json"
  $script:cfg = Read-SetupConfig -Path $script:ConfigFile
  $script:ConfigJson = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8)
  $script:scName = 'ScreenConnect Client (b58e7c32699a96bf)'

  # The SHA-256 (upper case) of the bytes the Get-RemoteFile mock writes ('placeholder', UTF-8 without BOM).
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $script:placeholderHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('placeholder'))) -replace '-', '').ToUpperInvariant() }
  finally { $sha.Dispose() }

  # A context like the runner's: a fresh copy of the real config per call (a test may change it) whose pinned
  # SHA-256 is the placeholder's, Remote SCREENCONNECT, and every folder in its own $TestDrive folder.
  function New-ScContext {
    $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    $config = $script:ConfigJson | ConvertFrom-Json
    $config.apps.screenconnect.sha256 = $script:placeholderHash
    @{
      Config      = $config
      State       = @{ Machine = @{ Arch = 'x64' }; Choices = @{ Remote = 'SCREENCONNECT' } }
      Root        = $dir
      LogDir      = (Join-Path $dir 'Logs')
      DownloadDir = (Join-Path $dir 'Downloads')
      ScriptPath  = (Join-Path $dir 'setup.ps1')
      StatePath   = (Join-Path $dir 'state.json')
    }
  }

  # Turns every command the step can reach into a recorder. Call from BeforeEach.
  #   $script:now        each Set-SetupNow Title
  #   $script:waits      each Wait-SetupDelay Seconds
  #   $script:downloads  each Get-RemoteFile call (Url, Destination); throws $script:downloadError when set,
  #                      else writes 'placeholder' to Destination
  #   $script:sigCalls   each Test-FileSignature call (Path, Signers, ExactCN), answered by $script:sigOk
  #   $script:ext        each Invoke-External call (FilePath, ArgumentList, TimeoutMinutes), answered by
  #                      $script:extHandler; the default one sets $script:svc = $script:svcAfterInstall, exit 0
  #   Get-Service        counts $script:svcReads; Running once $script:svcReads -ge $script:svcRunningFrom (when
  #                      set), else $script:svc; Missing is a Write-Error and nothing, anything else a service
  #                      named $script:svcName with that Status
  #   Get-AuthenticodeSignature   records whether the file still existed ($script:exeExistedAtRead) and answers
  #                      UnknownError with a certificate ending 19/02/2027 13:59:59
  #   $script:activity   each Add-SetupActivity Text; $script:logs each Write-SetupLog (Message, Level, Data)
  function Initialize-ScMocks {
    $script:SetupVersion = '2026.10.20.1'
    $script:now = New-Object System.Collections.ArrayList
    $script:waits = New-Object System.Collections.ArrayList
    $script:downloads = New-Object System.Collections.ArrayList
    $script:downloadError = $null
    $script:sigCalls = New-Object System.Collections.ArrayList
    $script:sigOk = $true
    $script:ext = New-Object System.Collections.ArrayList
    $script:svc = 'Missing'
    $script:svcAfterInstall = 'Running'
    $script:svcName = $script:scName
    $script:svcReads = 0
    $script:svcRunningFrom = $null
    $script:exeExistedAtRead = $null
    $script:activity = New-Object System.Collections.ArrayList
    $script:logs = New-Object System.Collections.ArrayList
    $script:extHandler = { param($c) $script:svc = $script:svcAfterInstall; @{ ExitCode = 0; TimedOut = $false; Output = '' } }

    Mock Write-SetupLog { [void]$script:logs.Add([pscustomobject]@{ Message = $Message; Level = $Level; Data = $Data }) }
    Mock Add-SetupActivity { [void]$script:activity.Add([pscustomobject]@{ Text = $Text }) }
    Mock Set-SetupNow { [void]$script:now.Add($Title) }
    Mock Wait-SetupDelay { [void]$script:waits.Add($Seconds) }
    Mock Get-RemoteFile {
      [void]$script:downloads.Add(@{ Url = $Url; Destination = $Destination })
      if ($script:downloadError) { throw $script:downloadError }
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
      [IO.File]::WriteAllText($Destination, 'placeholder')
      return $Destination
    }
    Mock Test-FileSignature {
      [void]$script:sigCalls.Add(@{ Path = $Path; Signers = @($AllowedSigners); ExactCN = [bool]$ExactCN })
      return $script:sigOk
    }
    Mock Invoke-External {
      $call = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes }
      [void]$script:ext.Add($call)
      & $script:extHandler $call
    }
    Mock Get-Service {
      $script:svcReads++
      $state = if ($null -ne $script:svcRunningFrom -and $script:svcReads -ge $script:svcRunningFrom) { 'Running' } else { $script:svc }
      if ($state -eq 'Missing') { Write-Error "Cannot find any service with service name '$Name'."; return }
      [pscustomobject]@{ Name = $script:svcName; Status = $state }
    }
    Mock Get-AuthenticodeSignature {
      $script:exeExistedAtRead = Test-Path -LiteralPath $LiteralPath
      [pscustomobject]@{ Status = 'UnknownError'; SignerCertificate = [pscustomobject]@{ NotAfter = [datetime]'2027-02-19T13:59:59' } }
    }
  }
}

Describe 'Get-ScreenConnectUrl' {
  It 'puts this release''s version in the link' {
    Get-ScreenConnectUrl -Template $cfg.apps.screenconnect.url -Version '2026.10.20.1' |
      Should -BeExactly 'https://github.com/BenTechit/bentech-winsetup/releases/download/v2026.10.20.1/ScreenConnect.ClientSetup.exe' }
  It 'an unknown version (<_>) gives no link' -ForEach 'dev', '', 'v2026.10.20.1', '2026.10.20', '2026.10.20.1 ', '2026.10.20.1/../latest' {
    Get-ScreenConnectUrl -Template $cfg.apps.screenconnect.url -Version $_ | Should -BeNullOrEmpty }
}

Describe 'Get-ScreenConnectServiceState' {
  It '<Status> is <Expected>, read by the exact name' -ForEach @(@{ Status = 'Running'; Expected = 'Running' }, @{ Status = 'Stopped'; Expected = 'NotRunning' }, @{ Status = 'StartPending'; Expected = 'NotRunning' }) {
    $script:st = $Status; Mock Get-Service { [pscustomobject]@{ Name = 'ScreenConnect Client (b58e7c32699a96bf)'; Status = $script:st } }
    Get-ScreenConnectServiceState -Name $scName | Should -Be $Expected
    Should -Invoke Get-Service -ParameterFilter { $Name -eq 'ScreenConnect Client (b58e7c32699a96bf)' } }
  It 'no such service is Missing, and never throws' { Mock Get-Service { Write-Error "Cannot find any service with service name 'x'." }; Get-ScreenConnectServiceState -Name $scName | Should -Be 'Missing' }
  It 'another company''s ScreenConnect client is Missing (Review Focus 3)' {
    Mock Get-Service { [pscustomobject]@{ Name = 'ScreenConnect Client (0123456789abcdef)'; Status = 'Running' } }; Get-ScreenConnectServiceState -Name $scName | Should -Be 'Missing' }
  It 'a Get-Service that throws is Missing, logged at WARN' {
    Mock Write-SetupLog { }
    Mock Get-Service { throw 'service control manager unavailable' }
    Get-ScreenConnectServiceState -Name $scName | Should -Be 'Missing'
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' } }
}

Describe 'Invoke-StepScreenConnect' {
  BeforeEach { Initialize-ScMocks; $script:ctx = New-ScContext; $script:exe = Join-Path $script:ctx.DownloadDir 'ScreenConnect.ClientSetup.exe' }
  It 'downloads this release''s installer, checks it, runs it with no arguments and waits for the service' {
    $r = Invoke-StepScreenConnect -Context $ctx
    $r.Status | Should -Be 'Done'; $r.Message | Should -BeExactly 'ScreenConnect installed'; @($r.Notes).Count | Should -Be 0; $r.Data.Service | Should -Be 'Running'
    $script:downloads[0].Url | Should -BeExactly 'https://github.com/BenTechit/bentech-winsetup/releases/download/v2026.10.20.1/ScreenConnect.ClientSetup.exe'
    $script:downloads[0].Destination | Should -Be $exe
    $script:sigCalls[0].Path | Should -Be $exe; @($script:sigCalls[0].Signers) | Should -Be @('"ConnectWise, LLC"'); $script:sigCalls[0].ExactCN | Should -BeFalse
    $script:ext.Count | Should -Be 1; $script:ext[0].FilePath | Should -Be $exe; $script:ext[0].ArgumentList | Should -BeNullOrEmpty; $script:ext[0].TimeoutMinutes | Should -Be 10
    @($script:activity.Text) | Should -Be @('ScreenConnect installed - this PC will appear in your ScreenConnect list') }
  It 'shows each phase in NOW' { $null = Invoke-StepScreenConnect -Context $ctx
    @($script:now) | Should -Be @('ScreenConnect: downloading', 'ScreenConnect: checking', 'ScreenConnect: installing', 'ScreenConnect: waiting for the service') }
  It 'a service already there skips the install' {
    $script:svc = 'Running'; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Message | Should -BeExactly 'ScreenConnect already installed'; $script:downloads.Count | Should -Be 0; $script:ext.Count | Should -Be 0
    @($script:now) | Should -Be @('ScreenConnect: waiting for the service'); $script:activity.Count | Should -Be 1 }
  It 'another company''s ScreenConnect does not count: Ben''s is installed (Review Focus 3)' {
    $script:svcName = 'ScreenConnect Client (0123456789abcdef)'; $script:svc = 'Running'
    $null = Invoke-StepScreenConnect -Context $ctx; $script:downloads.Count | Should -Be 1; $script:ext.Count | Should -Be 1 }
  It 'version <_> is unknown: Failed, nothing downloaded' -ForEach 'dev', '' {
    $script:SetupVersion = $_; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Status | Should -Be 'Failed'; $r.Message | Should -BeExactly 'ScreenConnect: release version unknown'; $script:downloads.Count | Should -Be 0 }
  It 'a SHA-256 mismatch deletes the installer and never runs it; the log names the check' {
    $ctx.Config.apps.screenconnect.sha256 = 'F' * 64; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Message | Should -BeExactly 'ScreenConnect installer check failed'; Test-Path -LiteralPath $exe | Should -BeFalse; $script:ext.Count | Should -Be 0
    @($script:logs | Where-Object { $_.Message -eq 'ScreenConnect installer check failed: SHA-256' }).Count | Should -Be 1
    $script:sigCalls.Count | Should -Be 0 }
  It 'the SHA-256 is compared without regard to case' {
    $ctx.Config.apps.screenconnect.sha256 = $script:placeholderHash.ToLowerInvariant(); (Invoke-StepScreenConnect -Context $ctx).Status | Should -Be 'Done' }
  It 'a refused signature deletes the installer; the log gives the PC date and the certificate end date' {
    $script:sigOk = $false; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Message | Should -BeExactly 'ScreenConnect installer check failed'; Test-Path -LiteralPath $exe | Should -BeFalse; $script:ext.Count | Should -Be 0
    $line = @($script:logs | Where-Object { $_.Message -eq 'ScreenConnect installer check failed: signature' })[0]
    $line.Data.certificateEnds | Should -Be '19/02/2027 13:59'; $line.Data.pcDate | Should -Match '^[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}$'
    $script:exeExistedAtRead | Should -BeTrue }
  It 'a failed download is Failed with the reason' {
    $script:downloadError = 'download failed after 3 attempts: x'
    (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect download failed: download failed after 3 attempts: x'; $script:ext.Count | Should -Be 0 }
  It 'the exit code decides nothing: 1603 with a running service is Done, and the code is logged' {
    $script:extHandler = { param($c) $script:svc = 'Running'; @{ ExitCode = 1603; TimedOut = $false; Output = '' } }
    (Invoke-StepScreenConnect -Context $ctx).Status | Should -Be 'Done'
    @($script:logs | Where-Object { $_.Message -eq 'ScreenConnect installer ended' -and $_.Data.exitCode -eq 1603 }).Count | Should -Be 1 }
  It 'a service that exists but does not run: Done with the yellow Note after the full wait (Review Focus 3)' {
    $script:svcAfterInstall = 'Stopped'; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Status | Should -Be 'Done'; $r.Message | Should -BeExactly 'ScreenConnect installed'; @($r.Notes) | Should -Be @('ScreenConnect service not running yet'); $r.Data.Service | Should -Be 'NotRunning'
    $script:waits.Count | Should -Be 36; @($script:waits | Select-Object -Unique) | Should -Be @(5) }
  It 'no service after the wait: Failed (service not found)' {
    $script:svcAfterInstall = 'Missing'; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Status | Should -Be 'Failed'; $r.Message | Should -BeExactly 'ScreenConnect install failed (service not found)'; $r.Data.Service | Should -Be 'Missing'; $script:waits.Count | Should -Be 36
    $script:activity.Count | Should -Be 0 }
  It 'an installer that never exits: stopped at 10 minutes, then the service decides (Review Focus 4)' {
    $script:extHandler = { param($c) @{ ExitCode = $null; TimedOut = $true; Output = '' } }
    (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect install timed out'; $script:ext[0].TimeoutMinutes | Should -Be 10
    @($script:logs | Where-Object { $_.Message -eq 'ScreenConnect installer ended' -and $_.Level -eq 'WARN' -and $_.Data.timedOut -eq $true }).Count | Should -Be 1
    $script:svc = 'Missing'; $script:extHandler = { param($c) $script:svc = 'Running'; @{ ExitCode = $null; TimedOut = $true; Output = '' } }
    (Invoke-StepScreenConnect -Context $ctx).Status | Should -Be 'Done' }
  It 'an installer that cannot be started is Failed at once, with no wait' {
    Mock Invoke-External { throw 'The system cannot execute the specified program' }
    (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect install failed (installer could not be started)'; $script:waits.Count | Should -Be 0 }
  It 'polls every 5 s until the service runs, and shows the 3-minute limit only while it waits' {
    Clear-SetupNow; $script:svcAfterInstall = 'Missing'; $script:svcRunningFrom = 4; $script:limits = New-Object System.Collections.ArrayList
    Mock Wait-SetupDelay { [void]$script:waits.Add($Seconds); [void]$script:limits.Add((Get-SetupNow).Wait.LimitMinutes) }
    (Invoke-StepScreenConnect -Context $ctx).Status | Should -Be 'Done'
    @($script:waits) | Should -Be @(5, 5); @($script:limits | Select-Object -Unique) | Should -Be @(3); (Get-SetupNow).Wait | Should -BeNullOrEmpty }
  It 'without apps.screenconnect, or with an unknown signer key, it is not configured and does nothing' {
    $ctx.Config.apps.PSObject.Properties.Remove('screenconnect'); (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect is not configured'
    $other = New-ScContext; $other.Config.apps.screenconnect.signer = 'nope'; (Invoke-StepScreenConnect -Context $other).Message | Should -BeExactly 'ScreenConnect is not configured'
    $script:downloads.Count | Should -Be 0; Should -Invoke Get-Service -Times 0 -Exactly }
  It 'a blank <_> is not configured either, and nothing is read' -ForEach 'url', 'sha256', 'serviceName' {
    $ctx.Config.apps.screenconnect.$_ = ' '; (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect is not configured'
    $script:downloads.Count | Should -Be 0; Should -Invoke Get-Service -Times 0 -Exactly }
}

Describe 'the step file' {
  It 'uses no Write-Host, Start-Sleep or Invoke-WebRequest, and never passes -ExactCN' {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path "$PSScriptRoot\..\src\Steps\ScreenConnect.ps1").Path, [ref]$null, [ref]$null)
    $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    foreach ($banned in 'Write-Host', 'Start-Sleep', 'Invoke-WebRequest') { $commands | Should -Not -Contain $banned }
    @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'ExactCN' }, $true)).Count | Should -Be 0 }
}
