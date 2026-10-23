# tests/Winget.Tests.ps1
# Nothing here runs the real winget or the real Add-AppxPackage: every test that reaches them
# mocks Invoke-External, Add-AppxPackage, Get-RemoteFile and Get-WingetPath.
BeforeAll {
  foreach ($f in 'Common\StepResult', 'Common\Logging', 'Common\Activity', 'Common\Process', 'Common\Download', 'Steps\Winget') { . "$PSScriptRoot\..\src\$f.ps1" }

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
  # The command line a child powershell.exe was given: the text inside -EncodedCommand (Base64 of UTF-16LE).
  function ConvertFrom-ChildArgument {
    param([string]$ArgumentList)
    if ($ArgumentList -notmatch '-EncodedCommand ([A-Za-z0-9+/=]+)$') { return $null }
    [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
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

  # Zoom spec 3.2: the signed config's custom tokens travel as one quoted --custom value.
  It 'appends one quoted --custom value for a custom token' {
    Get-WingetInstallArgs -Id 'Zoom.Zoom' -Custom 'ZConfig=AU2_EnableAutoUpdate=true' |
      Should -BeExactly 'install --id Zoom.Zoom -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --custom "ZConfig=AU2_EnableAutoUpdate=true"'
  }
  It 'joins two custom tokens with one space' {
    Get-WingetInstallArgs -Id 'Zoom.Zoom' -Custom 'ZConfig=AU2_EnableAutoUpdate=true', 'ZSSOHOST=x' |
      Should -BeExactly 'install --id Zoom.Zoom -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --custom "ZConfig=AU2_EnableAutoUpdate=true ZSSOHOST=x"'
  }
  It 'throws for a custom token that could change the command line, and never echoes it: <t>' -ForEach @(
    @{ t = 'ZConfig="x" & calc' }, @{ t = 'A B=c' }, @{ t = '=x' }, @{ t = '' }
  ) {
    $err = $null
    try { Get-WingetInstallArgs -Id 'Zoom.Zoom' -Custom 'A=b', $t } catch { $err = $_.Exception.Message }
    $err | Should -Not -BeNullOrEmpty
    if ($t -ne '') { $err | Should -Not -Match ([regex]::Escape($t)) }
  }
  It 'without -Custom, or with an empty list, the args are byte-identical to today''s' {
    $today = 'install --id 7zip.7zip -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    Get-WingetInstallArgs -Id '7zip.7zip' | Should -BeExactly $today
    Get-WingetInstallArgs -Id '7zip.7zip' -Custom @() | Should -BeExactly $today
    Get-WingetInstallArgs -Id '9WZDNCRFJ4MV' -Source msstore | Should -BeExactly ($today -replace '7zip\.7zip', '9WZDNCRFJ4MV' -replace '--source winget', '--source msstore')
  }
}

Describe 'Test-WingetCustomToken' {
  It 'accepts <t>' -ForEach @(@{ t = 'ZConfig=AU2_EnableAutoUpdate=true' }, @{ t = 'A=b;c=d' }, @{ t = 'NAME_1=x_2' }) {
    Test-WingetCustomToken -Token $t | Should -BeTrue
  }
  It 'refuses <Why>' -ForEach @(
    @{ Why = 'a quote and an ampersand'; t = 'ZConfig="x" & calc' }, @{ Why = 'a space'; t = 'A B=c' }, @{ Why = 'no name'; t = '=x' }
    @{ Why = 'no value'; t = 'A=' }, @{ Why = 'no equals sign'; t = 'ABC' }, @{ Why = 'a leading dash'; t = '-A=b' }
    @{ Why = 'a slash'; t = 'A=/b' }, @{ Why = 'a trailing newline'; t = "A=b`n" }, @{ Why = 'empty'; t = '' }, @{ Why = '$null'; t = $null }
    @{ Why = 'a Kelvin sign (a letter only a case-insensitive match takes for k)'; t = ('A=' + [char]0x212A) }
    @{ Why = 'a Hebrew letter'; t = ('A=' + [char]0x05D0) }
  ) {
    Test-WingetCustomToken -Token $t | Should -BeFalse
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
    $extCalls[1].TimeoutMinutes | Should -Be 7     # timeoutsMinutes.default, not a hard-coded 5
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

  # Zoom spec 3.2: custom args and a per-call limit; the already-installed and timed-out answers carry Data.
  It 'passes the custom tokens on the command line and -TimeoutMinutes to Invoke-External' {
    Set-ExternalQueue @(New-ExternalResult 0)
    $r = Invoke-WingetInstall -Id 'Zoom.Zoom' -Custom 'ZConfig=AU2_EnableAutoUpdate=true' -TimeoutMinutes 10 -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Zoom.Zoom: installed'
    $extCalls.Count | Should -Be 1
    $extCalls[0].ArgumentList | Should -BeExactly (Get-WingetInstallArgs -Id 'Zoom.Zoom' -Custom 'ZConfig=AU2_EnableAutoUpdate=true')
    $extCalls[0].TimeoutMinutes | Should -Be 10
  }
  It 'without -TimeoutMinutes it waits timeoutsMinutes.default, and without -Custom it runs today''s command line' {
    Set-ExternalQueue @(New-ExternalResult 0)
    Invoke-WingetInstall -Id '7zip.7zip' -Context $ctx | Out-Null
    $extCalls[0].TimeoutMinutes | Should -Be 7
    $extCalls[0].ArgumentList | Should -BeExactly 'install --id 7zip.7zip -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
  }
  It 'the source reset and the retry keep the given limit and the custom tokens' {
    Set-ExternalQueue @((New-ExternalResult 0x8A15000F), (New-ExternalResult 0), (New-ExternalResult 0))
    (Invoke-WingetInstall -Id 'Zoom.Zoom' -Custom 'A=b' -TimeoutMinutes 10 -Context $ctx).Status | Should -Be 'Done'
    @($extCalls.TimeoutMinutes) | Should -Be @(10, 10, 10)
    $extCalls[2].ArgumentList | Should -BeExactly (Get-WingetInstallArgs -Id 'Zoom.Zoom' -Custom 'A=b')
  }
  It 'a Done from 0x8A150061 (already installed) carries Data.AlreadyInstalled; a plain 0 does not' {
    Set-ExternalQueue @(New-ExternalResult -1978335135)
    $r = Invoke-WingetInstall -Id 'Zoom.Zoom' -Context $ctx
    $r.Status | Should -Be 'Done'
    $r.Data.AlreadyInstalled | Should -BeTrue
    Set-ExternalQueue @(New-ExternalResult 0)
    (Invoke-WingetInstall -Id 'Zoom.Zoom' -Context $ctx).Data.Contains('AlreadyInstalled') | Should -BeFalse
  }
  It 'a timed-out run carries Data.TimedOut, on the first run and on the retry' {
    Set-ExternalQueue @(New-ExternalResult $null $true)
    $r = Invoke-WingetInstall -Id 'Zoom.Zoom' -TimeoutMinutes 10 -Context $ctx
    $r.Status | Should -Be 'Failed'; $r.Message | Should -Be 'Zoom.Zoom: winget timed out'; $r.Data.TimedOut | Should -BeTrue
    Set-ExternalQueue @((New-ExternalResult 0x8A15000F), (New-ExternalResult 0), (New-ExternalResult $null $true))
    (Invoke-WingetInstall -Id 'Zoom.Zoom' -Context $ctx).Data.TimedOut | Should -BeTrue
    Set-ExternalQueue @(New-ExternalResult 0x8A15001E)
    (Invoke-WingetInstall -Id 'Zoom.Zoom' -Context $ctx).Data.Contains('TimedOut') | Should -BeFalse
  }
  It 'returns Failed (it does not throw) for a custom token that fails the pattern, runs nothing and never echoes it' {
    Set-ExternalQueue @()
    $r = Invoke-WingetInstall -Id 'Zoom.Zoom' -Custom 'A=b', 'ZConfig="x" & calc' -Context $ctx
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -BeExactly 'Zoom.Zoom: invalid winget custom argument'
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
Describe 'ConvertTo-PowerShellLiteral' {
  It 'wraps plain text in single quotes' {
    ConvertTo-PowerShellLiteral -Text 'C:\BenTech\Setup\x.msixbundle' | Should -Be "'C:\BenTech\Setup\x.msixbundle'"
  }
  It 'doubles an apostrophe' {
    ConvertTo-PowerShellLiteral -Text "C:\O'Brien\x" | Should -Be "'C:\O''Brien\x'"
  }
  It 'doubles the typographic single quotes PowerShell also reads as quotes (U+2018 U+2019 U+201A U+201B)' {
    foreach ($c in 0x2018, 0x2019, 0x201A, 0x201B) {
      $q = [string][char]$c
      ConvertTo-PowerShellLiteral -Text "a${q}b" | Should -Be "'a${q}${q}b'"
    }
  }
  It 'leaves Hebrew letters, spaces, double quotes and dollar signs alone' {
    ConvertTo-PowerShellLiteral -Text 'C:\Users\בן גולדנברג\a "b" $x' | Should -Be ('''C:\Users\בן גולדנברג\a "b" $x''')
  }
  It 'quotes an empty string' {
    ConvertTo-PowerShellLiteral -Text '' | Should -Be "''"
  }
}

Describe 'Invoke-PowerShellChild' {
  BeforeEach {
    Mock Write-SetupLog {}
    Mock Invoke-External {
      [void]$script:extCalls.Add(@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes; Capture = [bool]$CaptureOutput })
      $script:extQueue.Dequeue()
    }
  }

  It 'starts Windows PowerShell 5.1 with the fixed switches and the command as -EncodedCommand, with the given timeout' {
    Set-ExternalQueue @(New-ExternalResult 0)
    Invoke-PowerShellChild -Command 'Get-Date' -TimeoutMinutes 3.5 | Out-Null
    $extCalls.Count | Should -Be 1
    $extCalls[0].FilePath | Should -Be (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $extCalls[0].ArgumentList | Should -Match '^-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand [A-Za-z0-9+/=]+$'
    $extCalls[0].TimeoutMinutes | Should -Be 3.5
    $extCalls[0].Capture | Should -BeTrue
    (ConvertFrom-ChildArgument $extCalls[0].ArgumentList) | Should -Match 'Get-Date$'
  }
  It 'carries any text unharmed, including quotes, Hebrew and spaces' {
    $cmd = 'Add-AppxPackage -Path ''C:\Users\בן גולדנברג\O''''Brien\a b.msixbundle'' -ErrorAction Stop; "x" | Out-Null'
    Set-ExternalQueue @(New-ExternalResult 0)
    Invoke-PowerShellChild -Command $cmd -TimeoutMinutes 1 | Out-Null
    (ConvertFrom-ChildArgument $extCalls[0].ArgumentList).EndsWith($cmd) | Should -BeTrue
  }
  It 'passes the exit code, the timeout flag and the output back' {
    Set-ExternalQueue @((New-ExternalResult 1 $false 'boom'), (New-ExternalResult $null $true 'partial'))
    $a = Invoke-PowerShellChild -Command 'x' -TimeoutMinutes 1
    $a.ExitCode | Should -Be 1
    $a.TimedOut | Should -BeFalse
    $a.Output | Should -Be 'boom'
    $b = Invoke-PowerShellChild -Command 'x' -TimeoutMinutes 1
    $b.ExitCode | Should -BeNullOrEmpty
    $b.TimedOut | Should -BeTrue
  }
}
Describe 'Invoke-StepWinget' {
  BeforeEach {
    Mock Write-SetupLog {}
    $script:pathCalls = 0
    $script:bundleInstalled = $false
    $script:registerResult = @{ ExitCode = 0; TimedOut = $false }
    $script:bundleResult = @{ ExitCode = 0; TimedOut = $false }
    $script:childThrows = $false
    $script:downloadThrows = $false
    $script:appx = New-Object System.Collections.ArrayList
    $script:downloads = New-Object System.Collections.ArrayList
    # Get-WingetPath: $null until the bundle has been installed, unless a test overrides this.
    Mock Get-WingetPath { if ($script:bundleInstalled) { 'C:\found\winget.exe' } }
    # The `winget --version` probe: working by default; the stale-alias tests override it.
    Mock Test-WingetUsable { $true }
    # Add-AppxPackage must never run in this process: it has no timeout. Each call is a child
    # powershell.exe started through Invoke-External, recorded here (decoded) instead of started.
    Mock Add-AppxPackage { throw 'Add-AppxPackage must not be called in-process' }
    Mock Invoke-External {
      $cmd = ConvertFrom-ChildArgument $ArgumentList
      $isRegister = [bool]($cmd -match '-RegisterByFamilyName')
      $main = $null
      if ($cmd -match '-MainPackage (\S+)') { $main = $Matches[1] }
      $path = $null
      if ($cmd -match "-Path '((?:[^']|'')*)'") { $path = $Matches[1].Replace("''", "'") }
      [void]$script:appx.Add(@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes; Capture = [bool]$CaptureOutput
                                Command = $cmd; Register = $isRegister; Main = $main; Path = $path })
      if ($script:childThrows) { throw 'Cannot start' }
      $res = if ($isRegister) { $script:registerResult } else { $script:bundleResult }
      if ($path -and -not $res.TimedOut -and $res.ExitCode -eq 0) { $script:bundleInstalled = $true }
      @{ ExitCode = $res.ExitCode; TimedOut = $res.TimedOut; Output = '' }
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
  It 'logs a WARN and goes on to the bundle when registering <what>' -ForEach @(
    @{ what = 'exits non-zero'; result = @{ ExitCode = 1; TimedOut = $false }; warn = 'Registering App Installer failed' },
    @{ what = 'times out'; result = @{ ExitCode = $null; TimedOut = $true }; warn = 'Registering App Installer timed out' }
  ) {
    $script:registerResult = $result
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Done'
    $downloads.Count | Should -Be 1
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Message -eq $warn } -Times 1 -Exactly
  }
  It 'logs a WARN and goes on to the bundle when the registration child cannot be started' {
    $script:childThrows = $true
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Failed'               # the bundle child cannot start either
    $downloads.Count | Should -Be 1
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'Registering App Installer failed' } -Times 1
  }
  It 'logs the exit code of a failed registration' {
    $script:registerResult = @{ ExitCode = 7; TimedOut = $false }
    Invoke-StepWinget -Context $ctx -PollSeconds 0.01 | Out-Null
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Data.exitCode -eq 7 } -Times 1
  }

  It 'runs the registration as a child Windows PowerShell with -EncodedCommand, limited to timeoutsMinutes.default' {
    Mock Get-WingetPath { $script:pathCalls++; if ($script:pathCalls -ge 3) { 'C:\registered\winget.exe' } }
    Invoke-StepWinget -Context (New-WingetContext -ReadyMinutes 1) -PollSeconds 0.01 | Out-Null
    $appx.Count | Should -Be 1
    $appx[0].FilePath | Should -Be (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $appx[0].ArgumentList | Should -Match '^-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand [A-Za-z0-9+/=]+$'
    $appx[0].Command | Should -Match '-RegisterByFamilyName'
    $appx[0].Command | Should -Match '-MainPackage Microsoft\.DesktopAppInstaller_8wekyb3d8bbwe'
    $appx[0].Command | Should -Match '-ErrorAction Stop$'
    $appx[0].TimeoutMinutes | Should -Be 7           # timeoutsMinutes.default; wingetReady is 1 here
  }
  It 'installs the bundle in a child too, with the same limit, and never runs Add-AppxPackage in-process' {
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Done'
    $appx.Count | Should -Be 2
    $appx[1].FilePath | Should -Be (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $appx[1].Command | Should -Match 'Add-AppxPackage -Path '
    $appx[1].Command | Should -Match '-ErrorAction Stop$'
    $appx[1].TimeoutMinutes | Should -Be 7
    Should -Invoke Add-AppxPackage -Times 0 -Exactly
  }
  It 'escapes quotes in the bundle path so the decoded command parses back to exactly that path' {
    $q = [string][char]0x2019
    $ctx.DownloadDir = Join-Path $TestDrive "O'Brien ${q}s בן"
    $expected = Join-Path $ctx.DownloadDir 'AppInstaller.msixbundle'
    Invoke-StepWinget -Context $ctx -PollSeconds 0.01 | Out-Null
    $cmd = $appx[1].Command
    $cmd.Contains("O''Brien ${q}${q}s") | Should -BeTrue
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$errors)
    $errors.Count | Should -Be 0
    $command = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-AppxPackage' }, $true) | Select-Object -First 1
    $elements = @($command.CommandElements)
    $pathIndex = (0..($elements.Count - 1) | Where-Object { $elements[$_] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$_].ParameterName -eq 'Path' })[0]
    $elements[$pathIndex + 1].Value | Should -Be $expected
  }
  It 'never calls Add-AppxPackage in-process in any stage' {
    Mock Get-WingetPath { $null }
    Invoke-StepWinget -Context $ctx -PollSeconds 0.01 | Out-Null
    $appx.Count | Should -Be 2
    Should -Invoke Add-AppxPackage -Times 0 -Exactly
  }
  It 'is Failed "winget unavailable" when the download fails, without installing anything from it' {
    $script:downloadThrows = $true
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
    @($appx | Where-Object { $_.Path }).Count | Should -Be 0
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' } -Times 1
  }
  It 'is Failed "winget unavailable", after a WARN, when the bundle install <what>' -ForEach @(
    @{ what = 'exits non-zero'; result = @{ ExitCode = 1; TimedOut = $false }; warn = 'Installing the App Installer bundle failed' },
    @{ what = 'times out'; result = @{ ExitCode = $null; TimedOut = $true }; warn = 'Installing the App Installer bundle timed out' }
  ) {
    $script:bundleResult = $result
    $r = Invoke-StepWinget -Context $ctx -PollSeconds 0.01
    $r.Status | Should -Be 'Failed'
    $r.Message | Should -Be 'winget unavailable'
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Message -eq $warn } -Times 1 -Exactly
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
  It 'Wait-WingetPath shows its limit while it polls and removes it after' {
    Clear-SetupNow
    $script:limits = New-Object System.Collections.ArrayList
    Mock Get-WingetPath { [void]$script:limits.Add((Get-SetupNow).Wait.LimitMinutes); 'C:\present\winget.exe' }
    Wait-WingetPath -TimeoutMinutes 4 -PollSeconds 0.01 | Should -Be 'C:\present\winget.exe'
    @($script:limits) | Should -Be @(4); (Get-SetupNow).Wait | Should -BeNullOrEmpty
  }
}
