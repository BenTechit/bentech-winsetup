# tests/Tweaks.Tests.ps1
# BenTech Toolbox, Task 1: the tweaks step (toolbox spec 5.3, 6.3) and its registry helpers.
#
# SAFETY: this runs on Ben's real PC, and the tweaks step writes HKCU, HKLM and HKU\.DEFAULT. Nothing here
# writes the registry, not even HKCU:
#   - the step's Describe mocks Set-RegistryDword, Set-RegistryString, Get-RegistryValue, Test-AdminProtection,
#     Add-SetupActivity and Write-SetupLog (Initialize-TweakMocks): the "registry" is the $script:reg table;
#   - the helper tests (Set-RegistryString, Get-RegistryValue) mock Test-Path, New-Item, New-ItemProperty and
#     Get-Item in every test;
#   - as a safety net, every Describe's BeforeEach calls Set-TweakSafetyNet: New-Item, New-ItemProperty,
#     Set-ItemProperty and Remove-ItemProperty throw unless a test mocks them itself.
BeforeAll {
  foreach ($f in 'Common\StepResult', 'Common\Logging', 'Common\Activity', 'Common\Config', 'Detect\Detection', 'Engine\Catalog',
                 'UI\StartScreen', 'Steps\Prepare', 'Steps\Tweaks') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"

  # One write through a mocked writer: recorded in $script:writes; a name in $script:throwOn throws, a name in
  # $script:refuse is refused ($false); otherwise the value lands in $script:reg (with another value when the
  # name is in $script:readBackWrong, so the read-back differs) and the answer is $true.
  function Add-FakeWrite([string]$Fn, [string]$Kind, [string]$Path, [string]$Name, $Value) {
    [void]$script:writes.Add(@{ Fn = $Fn; Path = $Path; Name = $Name; Value = $Value })
    if ($script:throwOn -contains $Name) { throw "fake registry failure: $Name" }
    if ($script:refuse -contains $Name) { return $false }
    $stored = if ($Kind -eq 'DWord') { [int]$Value } else { [string]$Value }
    if ($script:readBackWrong -contains $Name) { $stored = if ($Kind -eq 'DWord') { [int]$Value + 1 } else { [string]$Value + 'x' } }
    $script:reg["$Path|$Name"] = @{ Value = $stored; Kind = $Kind }
    return $true
  }

  # The safety net (see the header) and a quiet log. Call from every Describe's BeforeEach.
  function Set-TweakSafetyNet {
    Mock New-Item { throw 'blocked by the test: New-Item' }
    Mock New-ItemProperty { throw 'blocked by the test: New-ItemProperty' }
    Mock Set-ItemProperty { throw 'blocked by the test: Set-ItemProperty' }
    Mock Remove-ItemProperty { throw 'blocked by the test: Remove-ItemProperty' }
    Mock Write-SetupLog { }
  }

  # The step's fake world. Call from BeforeEach.
  #   $script:reg            '<path>|<name>' -> @{ Value; Kind }, seeded with the fresh-install accessibility Flags
  #   $script:writes         one @{ Fn; Path; Name; Value } per Set-RegistryDword / Set-RegistryString call
  #   $script:refuse / $script:throwOn / $script:readBackWrong   value names the writers refuse, throw on, or store wrong
  #   $script:protection     what Test-AdminProtection answers (default Off)
  #   $script:activity / $script:logs   Add-SetupActivity texts / Write-SetupLog calls (@{ Message; Level; Data })
  function Initialize-TweakMocks {
    Set-TweakSafetyNet
    $script:reg = @{
      'HKCU:\Control Panel\Accessibility\StickyKeys|Flags'        = @{ Value = '510'; Kind = 'String' }
      'HKCU:\Control Panel\Accessibility\Keyboard Response|Flags' = @{ Value = '126'; Kind = 'String' }
    }
    $script:writes = New-Object System.Collections.ArrayList
    $script:refuse = @(); $script:throwOn = @(); $script:readBackWrong = @()
    $script:protection = 'Off'
    $script:activity = New-Object System.Collections.ArrayList
    $script:logs = New-Object System.Collections.ArrayList

    Mock Get-RegistryValue {
      $e = $script:reg["$Path|$Name"]
      if ($null -eq $e) { @{ Exists = $false; Value = $null; Kind = '' } } else { @{ Exists = $true; Value = $e.Value; Kind = $e.Kind } } }
    Mock Set-RegistryDword { Add-FakeWrite 'Set-RegistryDword' 'DWord' $Path $Name $Value }
    Mock Set-RegistryString { Add-FakeWrite 'Set-RegistryString' 'String' $Path $Name $Value }
    Mock Test-AdminProtection { $script:protection }
    Mock Add-SetupActivity { [void]$script:activity.Add($Text) }
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
  }

  function New-TweakContext([string[]]$Tweaks, [string]$Mode = 'DESKTOP', [string]$Office = 'BUSINESS') {
    @{ Config = $script:cfg; State = @{ Machine = @{ OsBuild = 26200 }; Choices = @{ Mode = $Mode; Office = $Office; Tweaks = $Tweaks } } }
  }
}
Describe 'Get-ClearBitValue' {
  BeforeEach { Set-TweakSafetyNet }
  It '<C> clears 0x4 to <E>' -ForEach @(@{ C = '510'; E = '506' }, @{ C = '126'; E = '122' }, @{ C = '506'; E = '506' }, @{ C = '0'; E = '0' }, @{ C = '4294967295'; E = '4294967291' }) {
    Get-ClearBitValue -Current $C -Bit 4 -Fresh '506' | Should -BeExactly $E }
  It '<Why> takes the fresh-install value' -ForEach @(@{ Why = 'missing'; C = $null }, @{ Why = 'empty'; C = '' }, @{ Why = 'not a number'; C = 'abc' }, @{ Why = 'negative'; C = '-1' }, @{ Why = 'too big'; C = '4294967296' }) {
    Get-ClearBitValue -Current $C -Bit 4 -Fresh '506' | Should -BeExactly '506' }
}
Describe 'Set-RegistryString and Get-RegistryValue' {
  BeforeEach { Set-TweakSafetyNet }
  It 'writes a named REG_SZ, creating only a missing key' {
    Mock Test-Path { $false }; Mock New-Item { }; Mock New-ItemProperty { }
    Set-RegistryString -Path 'HKCU:\Control Panel\Keyboard' -Name 'InitialKeyboardIndicators' -Value '2' | Should -BeTrue
    Should -Invoke New-Item -Times 1 -Exactly
    Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'InitialKeyboardIndicators' -and $Value -eq '2' -and $PropertyType -eq 'String' } }
  It 'writes the key''s default value as a real empty string (classic menu)' {
    Mock Test-Path { $true }; Mock New-Item { }; Mock New-ItemProperty { }
    Set-RegistryString -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Name '' -Value '' | Should -BeTrue
    Should -Invoke New-Item -Times 0 -Exactly
    Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq '(default)' -and $Value -is [string] -and $Value -eq '' -and $PropertyType -eq 'String' } }
  It 'a refused write is $false, never a throw' {
    Mock Test-Path { $true }; Mock New-ItemProperty { Write-Error -Message 'Access is denied' -Category PermissionDenied }
    Set-RegistryString -Path 'HKCU:\x' -Name 'n' -Value 'v' | Should -BeFalse }
  It 'reads a value, the default value, a missing value and a missing key without throwing' {
    $fake = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod GetValueNames { @('Flags', '') } |
      Add-Member -PassThru ScriptMethod GetValue { param($n, $d, $o) @{ 'Flags' = '510'; '' = '' }[$n] } |
      Add-Member -PassThru ScriptMethod GetValueKind { param($n) [Microsoft.Win32.RegistryValueKind]::String } | Add-Member -PassThru ScriptMethod Dispose { }
    Mock Get-Item { $fake }
    $r = Get-RegistryValue -Path 'HKCU:\x' -Name 'Flags'; $r.Exists | Should -BeTrue; $r.Value | Should -BeExactly '510'; $r.Kind | Should -Be 'String'
    (Get-RegistryValue -Path 'HKCU:\x' -Name '').Exists | Should -BeTrue
    (Get-RegistryValue -Path 'HKCU:\x' -Name 'Nope').Exists | Should -BeFalse
    Mock Get-Item { Write-Error -Message 'Cannot find path' -Category ObjectNotFound }
    (Get-RegistryValue -Path 'HKCU:\gone' -Name 'Flags').Exists | Should -BeFalse }
  It 'tells "absent" from "could not be read": only a read that fails is Failed, and only it is a WARN (review M3, M7b)' {
    $script:logs = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    $fake = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod GetValueNames { @('Flags') } |
      Add-Member -PassThru ScriptMethod GetValue { param($n, $d, $o) '510' } |
      Add-Member -PassThru ScriptMethod GetValueKind { param($n) [Microsoft.Win32.RegistryValueKind]::String } | Add-Member -PassThru ScriptMethod Dispose { }
    Mock Get-Item { $fake }
    (Get-RegistryValue -Path 'HKCU:\x' -Name 'Flags').Failed | Should -BeFalse
    (Get-RegistryValue -Path 'HKCU:\x' -Name 'Nope').Failed | Should -BeFalse
    Mock Get-Item { Write-Error -Message 'Cannot find path' -Category ObjectNotFound }
    $r = Get-RegistryValue -Path 'HKCU:\gone' -Name 'Flags'; $r.Exists | Should -BeFalse; $r.Failed | Should -BeFalse
    @($script:logs).Count | Should -Be 0
    Mock Get-Item { Write-Error -Message 'Requested registry access is not allowed' -Category PermissionDenied }
    $r = Get-RegistryValue -Path 'HKLM:\SECURITY\x' -Name 'Flags'; $r.Exists | Should -BeFalse; $r.Failed | Should -BeTrue
    @($script:logs | ForEach-Object { '{0}|{1}' -f $_.Level, $_.Message }) | Should -Be @('WARN|Registry value could not be read') }
  It 'Set-RegistryDword logs a Hebrew refusal as ASCII (review M4)' {
    $script:logs = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    $he = [string]::new([char[]]@(0x05D2, 0x05D9, 0x05E9, 0x05D4))   # four Hebrew letters
    Mock Test-Path { $true }; Mock New-ItemProperty { Write-Error -Message "$he denied" -Category PermissionDenied }
    Set-RegistryDword -Path 'HKCU:\x' -Name 'n' -Value 1 | Should -BeFalse
    @($script:logs).Count | Should -Be 1; $script:logs[0].Level | Should -Be 'WARN'; $script:logs[0].Data.error | Should -BeExactly '???? denied' }
  It 'Set-RegistryString logs a Hebrew refusal as ASCII (review M7d)' {
    $script:logs = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    $he = [string]::new([char[]]@(0x05D2, 0x05D9, 0x05E9, 0x05D4))
    Mock Test-Path { $true }; Mock New-ItemProperty { Write-Error -Message "$he denied" -Category PermissionDenied }
    Set-RegistryString -Path 'HKCU:\x' -Name 'n' -Value 'v' | Should -BeFalse
    @($script:logs).Count | Should -Be 1; $script:logs[0].Level | Should -Be 'WARN'; $script:logs[0].Data.error | Should -BeExactly '???? denied' }
}
Describe 'Invoke-StepTweaks (toolbox spec 5.3)' {
  BeforeEach { Initialize-TweakMocks }
  It 'applies the business defaults on a desktop: Done, five applied, no Note' {
    $r = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('accessKeys', 'numLock', 'startClean', 'noAds', 'classicOutlook'))
    $r.Status | Should -Be 'Done'; $r.Message | Should -BeExactly '5 tweaks applied'; @($r.Notes).Count | Should -Be 0
    @($r.Data.Applied) | Should -Be @('accessKeys', 'numLock', 'startClean', 'noAds', 'classicOutlook'); @($r.Data.Keys | Sort-Object) | Should -Be @('Applied', 'Refused', 'Skipped')
    @($script:activity) | Should -Be @('Tweaks: 5 applied') }
  It 'clearBit keeps the Flags REG_SZ and keeps the customer''s other bits' {
    $script:reg['HKCU:\Control Panel\Accessibility\StickyKeys|Flags'] = @{ Value = '511'; Kind = 'String' }
    $null = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('accessKeys'))
    @($script:writes | Where-Object { $_.Name -eq 'Flags' } | ForEach-Object { '{0}|{1}' -f $_.Fn, $_.Value }) | Should -Be @('Set-RegistryString|507', 'Set-RegistryString|122') }
  It 'writes the classic-menu default value as an empty REG_SZ' {
    $null = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('classicMenu'))
    $w = @($script:writes)[0]; $w.Fn | Should -Be 'Set-RegistryString'; $w.Name | Should -BeExactly ''; $w.Value | Should -BeExactly '' }
  It 'a write Windows refuses is a yellow Note, never red (Review Focus 4)' {
    $script:refuse = @('TaskbarAl')
    $r = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('fileExtensions', 'taskbarLeft'))
    $r.Status | Should -Be 'Done'; $r.Message | Should -BeExactly '1 tweaks applied'
    @($r.Notes) | Should -Be @('Taskbar icons on the left could not be applied'); @($r.Data.Refused) | Should -Be @('taskbarLeft')
    @($script:activity) | Should -Be @('Tweaks: 1 applied, 1 refused by Windows') }
  It 'a writer that throws, or a read-back that differs, is refused too' {
    $script:throwOn = @('HideFileExt'); $script:readBackWrong = @('TaskbarEndTask')
    $r = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('fileExtensions', 'endTask'))
    $r.Status | Should -Be 'Done'; @($r.Data.Refused) | Should -Be @('fileExtensions', 'endTask') }
  It 'Administrator protection On: no HKCU write, the sign-in NumLock still applies, one Note (Review Focus 4)' {
    $script:protection = 'On'
    $r = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('accessKeys', 'numLock', 'noAds'))
    @($script:writes | Where-Object { $_.Path -like 'HKCU:\*' }).Count | Should -Be 0
    @($script:writes).Path | Should -Be @('Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard')
    @($r.Data.Applied) | Should -Be @('numLock'); @($r.Data.Skipped) | Should -Be @('accessKeys', 'noAds')
    @($r.Notes) | Should -Be @('Per-user tweaks skipped: Windows Administrator protection is on')
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Administrator protection is on: per-user tweak values are skipped' }).Count | Should -Be 1   # review M7e
    @($script:logs | Where-Object { $_.Message -eq 'Tweak value' -and $_.Data.result -eq 'skipped' }).Count | Should -Be 10 }   # 2 accessKeys + 1 NumLock + 7 noAds
  It 'rewrites a value whose text matches but whose kind differs (HideFileExt stored as REG_SZ "0", review M7c)' {
    $script:reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'] = @{ Value = '0'; Kind = 'String' }
    $r = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('fileExtensions'))
    @($script:writes | ForEach-Object { '{0}|{1}|{2}' -f $_.Fn, $_.Name, $_.Value }) | Should -Be @('Set-RegistryDword|HideFileExt|0')
    @($r.Data.Applied) | Should -Be @('fileExtensions')
    $script:reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'].Kind | Should -Be 'DWord' }
  It 'Unknown protection is the same user, logged at WARN' {
    $script:protection = 'Unknown'; (Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('noAds'))).Data.Applied | Should -Be 'noAds'
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -like '*Administrator protection state unknown*' }).Count | Should -Be 1 }
  It 'enforces desktopOnly and office365Only itself (a laptop with Craft gets neither)' {
    $r = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('numLock', 'classicOutlook', 'noAds') -Mode LAPTOP -Office CRAFT)
    @($r.Data.Applied) | Should -Be @('noAds'); @($script:writes | Where-Object { $_.Name -in 'InitialKeyboardIndicators', 'HideNewOutlookToggle' }).Count | Should -Be 0 }
  It 'logs each value with its original, writes nothing that is already set, and logs only ASCII' {
    $script:reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'] = @{ Value = 0; Kind = 'DWord' }
    $null = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('fileExtensions', 'numLock'))
    @($script:writes | Where-Object { $_.Name -eq 'HideFileExt' }).Count | Should -Be 0
    $lines = @($script:logs | Where-Object { $_.Message -eq 'Tweak value' })   # catalog order: numLock (two values) before fileExtensions
    $lines.Count | Should -Be 3; @($lines.Data.result) | Should -Be @('applied', 'applied', 'unchanged'); $lines[0].Data.original | Should -Be 'absent'
    (@($script:logs) | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match '[^\x00-\x7F]' }
  It 'nothing effective is Skipped with a message' {
    $r = Invoke-StepTweaks -Context (New-TweakContext -Tweaks @('numLock') -Mode LAPTOP); $r.Status | Should -Be 'Skipped'; $r.Message | Should -BeExactly 'No tweaks chosen' }
}
