# tests/Winget.Tests.ps1
# Nothing here runs the real winget or the real Add-AppxPackage: every test that reaches them
# mocks Invoke-External, Add-AppxPackage, Get-RemoteFile and Get-WingetPath.
BeforeAll {
  foreach ($f in 'Common\StepResult', 'Common\Logging', 'Common\Process', 'Common\Download', 'Steps\Winget') { . "$PSScriptRoot\..\src\$f.ps1" }

  function New-WingetContext {
    param([double]$ReadyMinutes = 5)
    @{
      Config      = [pscustomobject]@{
        timeoutsMinutes = [pscustomobject]@{ default = 7; wingetReady = $ReadyMinutes }
        winget          = [pscustomobject]@{ bundleUrl = 'https://example.invalid/getwinget' }
      }
      DownloadDir = Join-Path $TestDrive 'Downloads'
    }
  }
  function New-ExternalResult {
    param($Code, [bool]$TimedOut = $false, [string]$Output = '')
    @{ ExitCode = $Code; TimedOut = $TimedOut; Output = $Output }
  }
  # Queues the results the mocked Invoke-External hands back, one per call, and records the calls.
  function Set-ExternalQueue {
    param([hashtable[]]$Result)
    $script:extQueue = New-Object System.Collections.Queue
    foreach ($r in $Result) { $script:extQueue.Enqueue($r) }
    $script:extCalls = New-Object System.Collections.ArrayList
  }
}

Describe 'ConvertTo-UInt32ExitCode' {
  It '<c> -> <u>' -ForEach @(
    @{ c = 0; u = 0 },
    @{ c = -1978335135; u = 2316632161 },     # the negative int32 Process.ExitCode delivers
    @{ c = 0x8A150061; u = 2316632161 },      # a PS 5.1 hex literal is already that negative int32
    @{ c = 2316632161; u = 2316632161 },      # the unsigned form
    @{ c = -1; u = 4294967295 },
    @{ c = 3010; u = 3010 }
  ) {
    $r = ConvertTo-UInt32ExitCode -ExitCode $c
    $r | Should -BeOfType [uint32]
    $r | Should -Be $u
  }
  It 'throws for a value that is not a 32-bit exit code' {
    { ConvertTo-UInt32ExitCode -ExitCode 4294967296 } | Should -Throw
    { ConvertTo-UInt32ExitCode -ExitCode -2147483649 } | Should -Throw
  }
}

Describe 'Convert-WingetExitCode' {
  It '<c> -> <r>' -ForEach @(@{c=0;r='Done'},@{c=-1978335135;r='Done'},@{c=0x8A150061;r='Done'},@{c=0x8A150109;r='DoneReboot'},
    @{c=0x8A15010B;r='DoneReboot'},@{c=0x8A150014;r='Skipped'},@{c=0x8A150010;r='Skipped'},@{c=0x8A15000F;r='SourceReset'},@{c=0x8A15001E;r='Failed'}) {
    Convert-WingetExitCode -ExitCode $c | Should -Be $r }

  It 'maps the unsigned form of a code the same way' {
    Convert-WingetExitCode -ExitCode 2316632161 | Should -Be 'Done'
    Convert-WingetExitCode -ExitCode 2316632079 | Should -Be 'SourceReset'
  }
  It 'accepts a hex literal typed as a command argument, not only as an expression' {
    Convert-WingetExitCode -ExitCode 0x8A15000F | Should -Be 'SourceReset'
    Convert-WingetExitCode -ExitCode 0x8A150109 | Should -Be 'DoneReboot'
  }
  It 'treats a missing or non-numeric exit code as Failed, not as 0' {
    Convert-WingetExitCode -ExitCode $null | Should -Be 'Failed'
    Convert-WingetExitCode -ExitCode 'abc' | Should -Be 'Failed'
    Convert-WingetExitCode -ExitCode 99999999999 | Should -Be 'Failed'
  }
  It 'treats other small codes as Failed' {
    Convert-WingetExitCode -ExitCode 1 | Should -Be 'Failed'
    Convert-WingetExitCode -ExitCode -1 | Should -Be 'Failed'
  }
}

Describe 'Get-WingetInstallArgs' {
  It 'winget source' { Get-WingetInstallArgs -Id '7zip.7zip' | Should -Be 'install --id 7zip.7zip -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' }
  It 'msstore source' { Get-WingetInstallArgs -Id '9WZDNCRFJ4MV' -Source msstore | Should -Match '--source msstore' }

  It 'accepts the package ids the config uses' {
    foreach ($id in 'Microsoft.OfficeDeploymentTool', 'Dell.CommandUpdate.Universal', 'Lenovo.SystemUpdate', 'HP.SupportAssistant', 'XPDCCXDN26VNBT', 'Some-Vendor.Tool_2') {
      { Get-WingetInstallArgs -Id $id } | Should -Not -Throw
    }
  }
  It 'throws for an id that could change the command line: <id>' -ForEach @(
    @{ id = 'a b' }, @{ id = 'x;y' }, @{ id = 'a&b' }, @{ id = '"quoted"' }, @{ id = '-x' }, @{ id = '--source evil' }, @{ id = '' }, @{ id = ' ' }, @{ id = "a`nb" }, @{ id = "7zip.7zip`n" }
  ) {
    { Get-WingetInstallArgs -Id $id } | Should -Throw
  }
  It 'rejects an unknown source' {
    { Get-WingetInstallArgs -Id '7zip.7zip' -Source 'evil' } | Should -Throw
  }
}

Describe 'Get-WingetUninstallArgs' {
  It 'builds the uninstall command line' {
    Get-WingetUninstallArgs -Id 'Lenovo.SystemUpdate' | Should -Be 'uninstall --id Lenovo.SystemUpdate -e --silent --disable-interactivity --accept-source-agreements'
  }
  It 'throws for an id that could change the command line' {
    { Get-WingetUninstallArgs -Id 'a b' } | Should -Throw
    { Get-WingetUninstallArgs -Id 'x;y' } | Should -Throw
  }
}

Describe 'Get-WingetPath' {
  BeforeEach {
    $script:oldLocalAppData = $env:LOCALAPPDATA
    $script:oldProgramFiles = $env:ProgramFiles
    $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))   # TestDrive is shared by the tests of a Describe
    $env:LOCALAPPDATA = Join-Path $base 'local'
    $env:ProgramFiles = Join-Path $base 'pf'
    Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget.exe' }
    function New-FakeWinget([string]$Path) {
      New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
      Set-Content -LiteralPath $Path -Value 'x'
    }
  }
  AfterEach {
    $env:LOCALAPPDATA = $script:oldLocalAppData
    $env:ProgramFiles = $script:oldProgramFiles
  }

  It 'returns what Get-Command finds' {
    Mock Get-Command { [pscustomobject]@{ Source = 'C:\on\path\winget.exe' } } -ParameterFilter { $Name -eq 'winget.exe' }
    Get-WingetPath | Should -Be 'C:\on\path\winget.exe'
  }
  It 'falls back to the WindowsApps alias of the current user' {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    New-FakeWinget $alias
    Get-WingetPath | Should -Be $alias
  }
  It 'falls back to the newest installed package folder, by version and not by text' {
    $root = Join-Path $env:ProgramFiles 'WindowsApps'
    New-FakeWinget (Join-Path $root 'Microsoft.DesktopAppInstaller_1.9.25180.0_x64__8wekyb3d8bbwe\winget.exe')
    New-FakeWinget (Join-Path $root 'Microsoft.DesktopAppInstaller_1.27.350.0_x64__8wekyb3d8bbwe\winget.exe')
    New-FakeWinget (Join-Path $root 'Microsoft.DesktopAppInstaller_1.12.0.0_x64__8wekyb3d8bbwe\winget.exe')
    Get-WingetPath | Should -Be (Join-Path $root 'Microsoft.DesktopAppInstaller_1.27.350.0_x64__8wekyb3d8bbwe\winget.exe')
  }
  It 'also considers an arm64 package folder' {
    $root = Join-Path $env:ProgramFiles 'WindowsApps'
    New-FakeWinget (Join-Path $root 'Microsoft.DesktopAppInstaller_1.22.0.0_x64__8wekyb3d8bbwe\winget.exe')
    New-FakeWinget (Join-Path $root 'Microsoft.DesktopAppInstaller_1.28.0.0_arm64__8wekyb3d8bbwe\winget.exe')
    Get-WingetPath | Should -Be (Join-Path $root 'Microsoft.DesktopAppInstaller_1.28.0.0_arm64__8wekyb3d8bbwe\winget.exe')
  }
  It 'prefers the alias over a package folder' {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    New-FakeWinget $alias
    New-FakeWinget (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_1.27.0.0_x64__8wekyb3d8bbwe\winget.exe')
    Get-WingetPath | Should -Be $alias
  }
  It 'returns $null when winget is nowhere' {
    Get-WingetPath | Should -BeNullOrEmpty
  }
  It 'ignores a package folder that has no winget.exe in it' {
    New-Item -ItemType Directory -Path (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_1.27.0.0_x64__8wekyb3d8bbwe') -Force | Out-Null
    Get-WingetPath | Should -BeNullOrEmpty
  }
}

Describe 'Invoke-WingetInstall' {
  BeforeEach {
    Mock Get-WingetPath { 'C:\fake\winget.exe' }
    Mock Write-SetupLog {}
    Mock Invoke-External {
      [void]$script:extCalls.Add(@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes; Capture = [bool]$CaptureOutput })
      $script:extQueue.Dequeue()
    }
    $ctx = New-WingetContext
  }

  It 'is Done for exit code 0, and runs winget with the exact arguments, the default timeout and captured output' {
    Set-ExternalQueue @(New-ExternalResult 0)
    $r = Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    $r.Message | Should -Be '7zip.7zip: installed'
    $extCalls.Count | Should -Be 1
    $extCalls[0].FilePath | Should -Be 'C:\fake\winget.exe'
    $extCalls[0].ArgumentList | Should -Be (Get-WingetInstallArgs -Id '7zip.7zip')
    $extCalls[0].TimeoutMinutes | Should -Be 7
    $extCalls[0].Capture | Should -BeTrue
  }
  It 'uses the msstore source when asked' {
    Set-ExternalQueue @(New-ExternalResult 0)
    Invoke-WingetInstall -Id '9WZDNCRFJ4MV' -Source msstore -Context $ctx | Out-Null
    $extCalls[0].ArgumentList | Should -Match '--source msstore'
  }
  It 'is Done when the package is already installed (0x8A150061, as the negative int32 Process.ExitCode gives)' {
    Set-ExternalQueue @(New-ExternalResult -1978335135)
    (Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx).Status | Should -Be 'Done'
  }
  It 'turns "done, reboot needed" into Done with Reboot None (the Windows Update loop reboots)' -ForEach @(
    @{ code = 0x8A150109 }, @{ code = 0x8A15010B }
  ) {
    Set-ExternalQueue @(New-ExternalResult $code)
    $r = Invoke-WingetInstall -Id 'Dell.CommandUpdate.Universal' -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
  }
  It 'is Skipped when there is no package or installer for this system' -ForEach @(
    @{ code = 0x8A150014 }, @{ code = 0x8A150010 }
  ) {
    Set-ExternalQueue @(New-ExternalResult $code)
    $r = Invoke-WingetInstall -Id 'Some.Package' -Context $ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Be 'Some.Package: no package or installer for this system'
  }
  It 'is Failed with the hex code for any other exit code' {
    Set-ExternalQueue @(New-ExternalResult 0x8A15001E)
    $r = Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be '7zip.7zip: winget 0x8A15001E'
  }
  It 'zero-pads the hex code to eight digits' {
    Set-ExternalQueue @(New-ExternalResult 1)
    (Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx).Message | Should -Be '7zip.7zip: winget 0x00000001'
  }
  It 'logs only the last five lines of the output, at WARN, when it fails' {
    $out = (1..7 | ForEach-Object { "line-$_" }) -join "`r`n"
    Set-ExternalQueue @(New-ExternalResult 0x8A15001E $false $out)
    Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx | Out-Null
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Data.tail -match 'line-7' -and $Data.tail -match 'line-3' -and $Data.tail -notmatch 'line-2' } -Times 1 -Exactly
  }
  It 'does not log the output when it succeeds' {
    Set-ExternalQueue @(New-ExternalResult 0 $false 'secret-looking output')
    Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx | Out-Null
    Should -Invoke Write-SetupLog -ParameterFilter { $Data -and $Data.tail } -Times 0 -Exactly
  }
  It 'is Failed "timed out" when winget times out' {
    Set-ExternalQueue @(New-ExternalResult $null $true)
    $r = Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be '7zip.7zip: winget timed out'
  }
  It 'is Failed, with the number as text, for an exit code that is not a 32-bit value' {
    Set-ExternalQueue @(New-ExternalResult 99999999999)
    $r = Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be '7zip.7zip: winget 99999999999'
  }
  It 'is Failed (it does not throw) when winget cannot be started' {
    Mock Invoke-External { throw 'Cannot start' }
    $r = Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be '7zip.7zip: winget could not be started'
  }
  It 'is Failed, not Done, when winget gives no exit code and did not time out' {
    Set-ExternalQueue @(New-ExternalResult $null $false)
    (Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx).Status | Should -Be 'Failed'
  }

  It 'resets the sources once and retries the install once on 0x8A15000F' {
    Set-ExternalQueue @((New-ExternalResult 0x8A15000F), (New-ExternalResult 0), (New-ExternalResult 0))
    $r = Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx
    $r.Status | Should -Be 'Done'
    $extCalls.Count | Should -Be 3
    $extCalls[0].ArgumentList | Should -Be (Get-WingetInstallArgs -Id '7zip.7zip')
    $extCalls[1].ArgumentList | Should -Be 'source reset --force'
    $extCalls[1].FilePath | Should -Be 'C:\fake\winget.exe'
    $extCalls[1].TimeoutMinutes | Should -Be 5
    $extCalls[2].ArgumentList | Should -Be (Get-WingetInstallArgs -Id '7zip.7zip')
  }
  It 'does not reset or retry a second time when the retry also returns 0x8A15000F' {
    Set-ExternalQueue @((New-ExternalResult 0x8A15000F), (New-ExternalResult 0), (New-ExternalResult 0x8A15000F))
    $r = Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be '7zip.7zip: winget 0x8A15000F'
    $extCalls.Count | Should -Be 3
    @($extCalls | Where-Object { $_.ArgumentList -eq 'source reset --force' }).Count | Should -Be 1
  }
  It 'still retries the install when the source reset itself fails' {
    Set-ExternalQueue @((New-ExternalResult 0x8A15000F), (New-ExternalResult 5), (New-ExternalResult 0))
    (Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx).Status | Should -Be 'Done'
    $extCalls.Count | Should -Be 3
  }
  It 'reports a timeout of the retry' {
    Set-ExternalQueue @((New-ExternalResult 0x8A15000F), (New-ExternalResult 0), (New-ExternalResult $null $true))
    (Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx).Message | Should -Be '7zip.7zip: winget timed out'
  }

  It 'is Failed "winget unavailable" without running anything when winget is missing' {
    Mock Get-WingetPath { $null }
    Set-ExternalQueue @()
    $r = Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
    $extCalls.Count | Should -Be 0
  }
  It 'returns Failed (it does not throw) for an invalid package id, and runs nothing' -ForEach @(
    @{ id = 'a b' }, @{ id = 'x;y' }
  ) {
    Set-ExternalQueue @()
    $r = Invoke-WingetInstall -Id $id -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Match 'invalid winget package id'
    $extCalls.Count | Should -Be 0
  }
}

Describe 'Invoke-WingetUninstall' {
  BeforeEach {
    Mock Get-WingetPath { 'C:\fake\winget.exe' }
    Mock Write-SetupLog {}
    Mock Invoke-External {
      [void]$script:extCalls.Add(@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes; Capture = [bool]$CaptureOutput })
      $script:extQueue.Dequeue()
    }
    $ctx = New-WingetContext
  }

  It 'is Done for exit code 0 and uses the uninstall arguments' {
    Set-ExternalQueue @(New-ExternalResult 0)
    $r = Invoke-WingetUninstall -Id 'Dell.CommandUpdate.Universal' -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
    $extCalls[0].ArgumentList | Should -Be 'uninstall --id Dell.CommandUpdate.Universal -e --silent --disable-interactivity --accept-source-agreements'
    $extCalls[0].TimeoutMinutes | Should -Be 7
    $extCalls[0].Capture | Should -BeTrue
  }
  It 'turns "done, reboot needed" into Done with Reboot None' {
    Set-ExternalQueue @(New-ExternalResult 0x8A150109)
    $r = Invoke-WingetUninstall -Id 'Lenovo.SystemUpdate' -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Reboot | Should -Be 'None'
  }
  It 'is Skipped when winget has nothing to uninstall' {
    Set-ExternalQueue @(New-ExternalResult 0x8A150014)
    $r = Invoke-WingetUninstall -Id 'Lenovo.SystemUpdate' -Context $ctx
    $r.Status | Should -Be 'Skipped'
    $r.Message | Should -Match '^Lenovo\.SystemUpdate: '
  }
  It 'is Failed with the hex code for any other exit code' {
    Set-ExternalQueue @(New-ExternalResult 0x8A15001E)
    $r = Invoke-WingetUninstall -Id 'Lenovo.SystemUpdate' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'Lenovo.SystemUpdate: winget 0x8A15001E'
  }
  It 'is Failed "timed out" when winget times out' {
    Set-ExternalQueue @(New-ExternalResult $null $true)
    (Invoke-WingetUninstall -Id 'Lenovo.SystemUpdate' -Context $ctx).Message | Should -Be 'Lenovo.SystemUpdate: winget timed out'
  }
  It 'resets the sources once and retries once on 0x8A15000F' {
    Set-ExternalQueue @((New-ExternalResult 0x8A15000F), (New-ExternalResult 0), (New-ExternalResult 0))
    (Invoke-WingetUninstall -Id 'Lenovo.SystemUpdate' -Context $ctx).Status | Should -Be 'Done'
    $extCalls.Count | Should -Be 3
    $extCalls[1].ArgumentList | Should -Be 'source reset --force'
    $extCalls[2].ArgumentList | Should -Match '^uninstall --id Lenovo\.SystemUpdate '
  }
  It 'is Failed "winget unavailable" when winget is missing' {
    Mock Get-WingetPath { $null }
    Set-ExternalQueue @()
    $r = Invoke-WingetUninstall -Id 'Lenovo.SystemUpdate' -Context $ctx
    $r.Message | Should -Be 'winget unavailable'
    $extCalls.Count | Should -Be 0
  }
  It 'returns Failed (it does not throw) for an invalid package id' {
    Set-ExternalQueue @()
    $r = Invoke-WingetUninstall -Id 'x;y' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $extCalls.Count | Should -Be 0
  }
}

Describe 'Test-WingetUsable' {
  BeforeEach {
    Mock Write-SetupLog {}
    Mock Invoke-External {
      [void]$script:extCalls.Add(@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes; Capture = [bool]$CaptureOutput })
      $script:extQueue.Dequeue()
    }
  }

  It 'is $true when "winget --version" exits with 0, and runs exactly that with a one-minute limit' {
    Set-ExternalQueue @(New-ExternalResult 0)
    Test-WingetUsable -Path 'C:\fake\winget.exe' | Should -BeTrue
    $extCalls.Count | Should -Be 1
    $extCalls[0].FilePath | Should -Be 'C:\fake\winget.exe'
    $extCalls[0].ArgumentList | Should -Be '--version'
    $extCalls[0].TimeoutMinutes | Should -Be 1
    $extCalls[0].Capture | Should -BeTrue
  }
  It 'returns a [bool]' {
    Set-ExternalQueue @(New-ExternalResult 0)
    Test-WingetUsable -Path 'C:\fake\winget.exe' | Should -BeOfType [bool]
  }
  It 'is $false when the probe times out' {
    Set-ExternalQueue @(New-ExternalResult $null $true)
    Test-WingetUsable -Path 'C:\fake\winget.exe' | Should -BeFalse
  }
  It 'is $false when the probe times out even if an exit code is reported' {
    Set-ExternalQueue @(New-ExternalResult 0 $true)
    Test-WingetUsable -Path 'C:\fake\winget.exe' | Should -BeFalse
  }
  It 'is $false for a non-zero exit code (<code>)' -ForEach @(@{ code = 1 }, @{ code = -1 }, @{ code = 0x8A15000F }) {
    Set-ExternalQueue @(New-ExternalResult $code)
    Test-WingetUsable -Path 'C:\fake\winget.exe' | Should -BeFalse
  }
  It 'is $false when there is no exit code and no timeout' {
    Set-ExternalQueue @(New-ExternalResult $null $false)
    Test-WingetUsable -Path 'C:\fake\winget.exe' | Should -BeFalse
  }
  It 'is $false, and does not throw, when the program cannot be started' {
    Mock Invoke-External { throw 'Cannot start' }
    { Test-WingetUsable -Path 'C:\stale\alias\winget.exe' } | Should -Not -Throw
    Test-WingetUsable -Path 'C:\stale\alias\winget.exe' | Should -BeFalse
  }
}
Describe 'Invoke-StepWinget' {
  BeforeEach {
    Mock Write-SetupLog {}
    $script:pathCalls = 0
    $script:bundleInstalled = $false
    $script:registerThrows = $false
    $script:bundleInstallThrows = $false
    $script:downloadThrows = $false
    $script:appx = New-Object System.Collections.ArrayList
    $script:downloads = New-Object System.Collections.ArrayList
    # Get-WingetPath: $null until the bundle has been installed, unless a test overrides this.
    Mock Get-WingetPath { if ($script:bundleInstalled) { 'C:\found\winget.exe' } }
    # The `winget --version` probe: working by default; the stale-alias tests override it.
    Mock Test-WingetUsable { $true }
    # Never the real Add-AppxPackage.
    Mock Add-AppxPackage {
      [void]$script:appx.Add(@{ Register = [bool]$RegisterByFamilyName; Main = $MainPackage; Path = $Path })
      if ($RegisterByFamilyName -and $script:registerThrows) { throw 'register boom' }
      if ($Path -and $script:bundleInstallThrows) { throw 'bundle boom' }
      if ($Path) { $script:bundleInstalled = $true }
    }
    Mock Get-RemoteFile {
      [void]$script:downloads.Add(@{ Url = $Url; Destination = $Destination })
      if ($script:downloadThrows) { throw "download failed after 3 attempts: $Url" }
      $Destination
    }
    # Short waits: 0.002 minutes is 0.12 s.
    $ctx = New-WingetContext -ReadyMinutes 0.002
  }

  It 'is Done at once when winget is already present, and registers and downloads nothing' {
    Mock Get-WingetPath { 'C:\present\winget.exe' }
    $r = Invoke-StepWinget -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'winget ready: C:\present\winget.exe'
    $r.Reboot | Should -Be 'None'
    $appx.Count | Should -Be 0
    $downloads.Count | Should -Be 0
  }

  It 'registers App Installer and is Done when winget appears while polling' {
    # 1st call: the initial check; 2nd: first poll; 3rd: second poll.
    Mock Get-WingetPath { $script:pathCalls++; if ($script:pathCalls -ge 3) { 'C:\registered\winget.exe' } }
    $r = Invoke-StepWinget -Context (New-WingetContext -ReadyMinutes 1) -PollSeconds 0.01
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'winget ready: C:\registered\winget.exe'
    $script:pathCalls | Should -Be 3
    $appx.Count | Should -Be 1
    $appx[0].Register | Should -BeTrue
    $appx[0].Main | Should -Be 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
    $downloads.Count | Should -Be 0
  }

  It 'downloads and installs the bundle when registering does not make winget appear' {
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'winget ready: C:\found\winget.exe'
    $downloads.Count | Should -Be 1
    $downloads[0].Url | Should -Be 'https://example.invalid/getwinget'
    $downloads[0].Destination | Should -Be (Join-Path $ctx.DownloadDir 'AppInstaller.msixbundle')
    $appx.Count | Should -Be 2
    $appx[0].Register | Should -BeTrue
    $appx[1].Register | Should -BeFalse
    $appx[1].Path | Should -Be (Join-Path $ctx.DownloadDir 'AppInstaller.msixbundle')
  }

  It 'is Failed "winget unavailable" when winget never appears' {
    Mock Get-WingetPath { $null }
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
    $appx.Count | Should -Be 2
    $downloads.Count | Should -Be 1
  }

  It 'takes its wait from timeoutsMinutes.wingetReady unless told otherwise' {
    # The config says 0.12 s, so no sleep may be anywhere near the default 15 s poll.
    Mock Get-WingetPath { $null }
    Mock Start-Sleep {
      if ($Milliseconds -gt 1000) { throw "slept $Milliseconds ms: the configured wait was ignored" }
      [Threading.Thread]::Sleep([int]$Milliseconds)
    }
    $r = Invoke-StepWinget -Context $ctx
    $r.Message | Should -Be 'winget unavailable'
  }
  It 'honours an explicit ReadyTimeoutMinutes over the configured one' {
    Mock Get-WingetPath { $null }
    Mock Start-Sleep {
      if ($Milliseconds -gt 1000) { throw "slept $Milliseconds ms: ReadyTimeoutMinutes was ignored" }
      [Threading.Thread]::Sleep([int]$Milliseconds)
    }
    $r = Invoke-StepWinget -Context (New-WingetContext -ReadyMinutes 60) -ReadyTimeoutMinutes 0.002 -PollSeconds 0.01
    $r.Message | Should -Be 'winget unavailable'
  }
  It 'logs a WARN and goes on to the bundle when registering throws' {
    $script:registerThrows = $true
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Done'
    $downloads.Count | Should -Be 1
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' } -Times 1
  }
  It 'is Failed "winget unavailable" when the download fails, without installing anything from it' {
    $script:downloadThrows = $true
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
    @($appx | Where-Object { $_.Path }).Count | Should -Be 0
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' } -Times 1
  }
  It 'is Failed "winget unavailable" when the bundle will not install' {
    $script:bundleInstallThrows = $true
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
  }
  It 'skips the bundle (and still ends Failed) when the config has no bundleUrl' {
    $noUrl = New-WingetContext -ReadyMinutes 0.002
    $noUrl.Config.winget.bundleUrl = ''
    $r = Invoke-StepWinget -Context $noUrl -PollSeconds 0.01
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
    $downloads.Count | Should -Be 0
  }

  It 'does not trust a winget that exists but fails "--version": it keeps polling and ends Failed "winget unavailable"' {
    Mock Get-WingetPath { 'C:\stale\alias\winget.exe' }
    Mock Test-WingetUsable { $false }
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
    $appx.Count | Should -Be 2                      # registered, then the bundle: a stale alias is not "present"
    $downloads.Count | Should -Be 1
    Should -Invoke Test-WingetUsable -ParameterFilter { $Path -eq 'C:\stale\alias\winget.exe' } -Times 3   # the initial check, then at least one probe per poll
  }
  It 'keeps polling while the probe fails and is Done as soon as it passes' {
    # Probe results: initial check fails, first poll fails, second poll passes.
    Mock Get-WingetPath { 'C:\flaky\winget.exe' }
    Mock Test-WingetUsable { $script:probeCalls++; $script:probeCalls -ge 3 }
    $script:probeCalls = 0
    $r = Invoke-StepWinget -Context (New-WingetContext -ReadyMinutes 1) -PollSeconds 0.01
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'winget ready: C:\flaky\winget.exe'
    $script:probeCalls | Should -Be 3
    $appx.Count | Should -Be 1                      # registration only; no bundle
    $downloads.Count | Should -Be 0
  }
  It 'is Done after registration when the stale winget starts working' {
    $script:registered = $false
    Mock Get-WingetPath { 'C:\stale\alias\winget.exe' }
    Mock Test-WingetUsable { $script:appx.Count -ge 1 }     # works only once App Installer has been registered
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'winget ready: C:\stale\alias\winget.exe'
    $appx.Count | Should -Be 1
    $appx[0].Register | Should -BeTrue
    $downloads.Count | Should -Be 0
  }
  It 'is Done after the bundle install when only then does the probe pass' {
    Mock Get-WingetPath { 'C:\stale\alias\winget.exe' }
    Mock Test-WingetUsable { [bool]$script:bundleInstalled }
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Done'
    $downloads.Count | Should -Be 1
    @($appx | Where-Object { $_.Path }).Count | Should -Be 1
  }
  It 'does not run the probe at all when Get-WingetPath finds nothing' {
    Mock Get-WingetPath { $null }
    Invoke-StepWinget -Context $ctx -PollSeconds 0.01 | Out-Null
    Should -Invoke Test-WingetUsable -Times 0 -Exactly
  }
  It 'probes the path it is about to report' {
    Mock Get-WingetPath { 'C:\present\winget.exe' }
    Invoke-StepWinget -Context $ctx | Out-Null
    Should -Invoke Test-WingetUsable -ParameterFilter { $Path -eq 'C:\present\winget.exe' } -Times 1 -Exactly
  }
}
