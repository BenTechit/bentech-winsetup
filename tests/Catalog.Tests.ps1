# tests/Catalog.Tests.ps1
BeforeAll {
  . "$PSScriptRoot\..\src\Common\Config.ps1"; . "$PSScriptRoot\..\src\State\State.ps1"
  . "$PSScriptRoot\..\src\Engine\Catalog.ps1"; . "$PSScriptRoot\..\src\Engine\Verdict.ps1"
  . "$PSScriptRoot\..\src\UI\StartScreen.ps1"   # New-DefaultChoices, for the default-plan test
  . "$PSScriptRoot\..\src\Toolbox\SetupPlanner.ps1"   # New-DefaultChoices reads the default profile
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  # The fifth and sixth parameters add Choices.Remote and Choices.Tweaks only when given: the plans built without them prove "exactly as today".
  function P($brand, $mode, $z = $true, $o = 'BUSINESS', $r = $null, $t = $null) {
    $c = @{Mode=$mode;SevenZip=$z;Office=$o}; if ($null -ne $r) { $c.Remote = $r }; if ($null -ne $t) { $c.Tweaks = $t }
    Get-StepPlan -Machine @{Brand=$brand} -Choices $c -Config $cfg }
}
Describe 'StepCatalog' {
  It 'lists the 22 steps in spec order with their titles and functions' {
    $rows = @($script:StepCatalog | ForEach-Object { '{0}|{1}|{2}' -f $_.Id, $_.Title, $_.Function })
    $rows | Should -Be @(
      'prepare|Prepare machine|Invoke-StepPrepare'
      'bitlocker|Turn off BitLocker|Invoke-StepBitLocker'
      'region|Time zone + Hebrew keyboard|Invoke-StepRegion'
      'desktop-icons|Desktop icons|Invoke-StepDesktopIcons'
      'tweaks|System tweaks|Invoke-StepTweaks'
      'bloatware|Remove bloatware|Invoke-StepBloatware'
      'rename|Rename PC|Invoke-StepRename'
      'winget|Prepare winget|Invoke-StepWinget'
      'chrome|Google Chrome|Invoke-StepChrome'
      'anydesk|AnyDesk|Invoke-StepAnyDesk'
      'screenconnect|ScreenConnect|Invoke-StepScreenConnect'
      '7zip|7-Zip|Invoke-StepSevenZip'
      'craft-apps|Craft apps|Invoke-StepCraftApps'
      'default-browser|Chrome as default browser|Invoke-StepDefaultBrowser'
      'vendor-pass1|Vendor drivers + BIOS (pass 1)|Invoke-StepVendorPass1'
      'office|Microsoft 365|Invoke-StepOffice'
      'windows-update|Windows Update|Invoke-StepWindowsUpdate'
      'office-finish|Microsoft 365 (finish)|Invoke-StepOfficeFinish'
      'vendor-pass2|Vendor drivers + BIOS (pass 2)|Invoke-StepVendorPass2'
      'consumer-app|Vendor app|Invoke-StepConsumerApp'
      'vendor-cleanup|Remove business updater|Invoke-StepVendorCleanup'
      'finalize|Finalize|Invoke-StepFinalize'
    )
  }
  It 'has unique ids' { @($script:StepCatalog.Id | Select-Object -Unique).Count | Should -Be $script:StepCatalog.Count }
  It 'every step has a Short title of at most 20 characters' { foreach ($s in $script:StepCatalog) { $s.Short | Should -Not -BeNullOrEmpty; $s.Short.Length | Should -BeLessOrEqual 20 } }
  It 'has the progress screen''s Short titles (v2 spec 4.2)' {
    @($script:StepCatalog | ForEach-Object { '{0}|{1}' -f $_.Id, $_.Short }) | Should -Be @(
      'prepare|Prepare', 'bitlocker|BitLocker off', 'region|Time zone + keyboard', 'desktop-icons|Desktop icons', 'tweaks|Tweaks'
      'bloatware|Remove bloatware', 'rename|Rename PC', 'winget|winget', 'chrome|Chrome', 'anydesk|AnyDesk', 'screenconnect|ScreenConnect', '7zip|7-Zip', 'craft-apps|Craft apps'
      'default-browser|Default browser', 'vendor-pass1|Drivers (pass 1)', 'office|Microsoft 365', 'windows-update|Windows Update'
      'office-finish|Microsoft 365', 'vendor-pass2|Drivers (pass 2)', 'consumer-app|Laptop app', 'vendor-cleanup|Remove updater', 'finalize|Finish'
    )
  }
}
Describe 'Test-HasDriverTool' {
  It 'Test-HasDriverTool: Dell yes, ASUS no, a Dell VM no' {
    Test-HasDriverTool -Machine @{ Brand = 'DELL' } | Should -BeTrue
    Test-HasDriverTool -Machine @{ Brand = 'ASUS' } | Should -BeFalse
    Test-HasDriverTool -Machine @{ Brand = 'DELL'; IsVM = $true } | Should -BeFalse
  }
  It 'Lenovo and HP yes; the VM brand, an unknown brand and a missing brand no' {
    foreach ($b in 'LENOVO', 'HP') { Test-HasDriverTool -Machine @{ Brand = $b } | Should -BeTrue -Because $b }
    foreach ($mach in @{ Brand = 'VM' }, @{ Brand = 'OTHER' }, @{ Brand = '' }, @{ }) { Test-HasDriverTool -Machine $mach | Should -BeFalse }
  }
}
Describe 'Get-RemoteChoice (screenconnect spec 4.1)' {
  It '<Why> is <Expected>' -ForEach @(
    @{ Why = 'ANYDESK';                Choices = @{ Remote = 'ANYDESK' };       Expected = 'ANYDESK' }
    @{ Why = 'SCREENCONNECT';          Choices = @{ Remote = 'SCREENCONNECT' }; Expected = 'SCREENCONNECT' }
    @{ Why = 'BOTH';                   Choices = @{ Remote = 'BOTH' };          Expected = 'BOTH' }
    @{ Why = 'a lower-case both';      Choices = @{ Remote = 'both' };          Expected = 'BOTH' }
    @{ Why = 'choices without Remote'; Choices = @{ Mode = 'LAPTOP' };          Expected = 'ANYDESK' }
    @{ Why = 'an empty Remote';        Choices = @{ Remote = '' };              Expected = 'ANYDESK' }
    @{ Why = 'an unknown Remote';      Choices = @{ Remote = 'TEAMVIEWER' };    Expected = 'ANYDESK' }
    @{ Why = 'no choices at all';      Choices = $null;                         Expected = 'ANYDESK' }
  ) { Get-RemoteChoice -Choices $Choices | Should -BeExactly $Expected }
  It 'a state.json from an older version (no Remote) reads as ANYDESK (Review Focus 1)' {
    $old = ConvertTo-HashtableDeep -InputObject ('{"Choices":{"Mode":"LAPTOP","SevenZip":true,"Office":"CRAFT"}}' | ConvertFrom-Json)
    Get-RemoteChoice -Choices $old.Choices | Should -BeExactly 'ANYDESK'
  }
}
Describe 'Get-StepPlan' {
  It 'Dell laptop gets everything in order' { (P DELL LAPTOP) -join ',' | Should -Be 'prepare,bitlocker,region,desktop-icons,bloatware,rename,winget,chrome,anydesk,7zip,default-browser,vendor-pass1,office,windows-update,office-finish,vendor-pass2,consumer-app,vendor-cleanup,finalize' }
  It 'Dell desktop: vendor passes, no consumer app, no cleanup' { $p = P DELL DESKTOP; $p | Should -Contain 'vendor-pass1'; $p | Should -Not -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-cleanup' }
  It 'ASUS laptop: consumer app only' { $p = P ASUS LAPTOP; $p | Should -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-pass1'; $p | Should -Not -Contain 'vendor-cleanup' }
  It 'custom desktop: no vendor steps' { (P OTHER DESKTOP) -match 'vendor|consumer' | Should -BeNullOrEmpty }
  It 'VM in laptop mode: still no vendor steps' { (P VM LAPTOP) -match 'vendor|consumer' | Should -BeNullOrEmpty }
  It 'toggles off' { $p = P DELL LAPTOP $false 'OFF'; $p | Should -Not -Contain '7zip'; $p | Should -Not -Contain 'office'; $p | Should -Not -Contain 'office-finish' }
  It 'office-finish comes with office, right after windows-update' { $p = @(P ASUS LAPTOP); $p.IndexOf('office-finish') | Should -Be ($p.IndexOf('windows-update') + 1); $p.IndexOf('office') | Should -Be ($p.IndexOf('windows-update') - 1) }
  It 'a brand with no vendors entry does not throw (SAMSUNG laptop)' {
    { P SAMSUNG LAPTOP } | Should -Not -Throw
    $p = P SAMSUNG LAPTOP; $p | Should -Not -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-pass1'
  }
  It 'a VM never gets vendor steps, even when the brand string says otherwise' {
    $p = Get-StepPlan -Machine @{Brand='DELL';IsVM=$true} -Choices @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'} -Config $cfg
    $p -match 'vendor|consumer' | Should -BeNullOrEmpty
  }
  It 'takes the mode from Choices, never from Machine.IsLaptop' {
    $p = Get-StepPlan -Machine @{Brand='DELL';IsLaptop=$true} -Choices @{Mode='DESKTOP';SevenZip=$true;Office='BUSINESS'} -Config $cfg
    $p | Should -Not -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-cleanup'
    $p = Get-StepPlan -Machine @{Brand='DELL';IsLaptop=$false} -Choices @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'} -Config $cfg
    $p | Should -Contain 'consumer-app'; $p | Should -Contain 'vendor-cleanup'
  }
  It 'HP and Lenovo laptops get passes, vendor app and cleanup' {
    foreach ($b in 'HP', 'LENOVO') { $p = P $b LAPTOP; $p | Should -Contain 'vendor-pass1'; $p | Should -Contain 'vendor-pass2'; $p | Should -Contain 'consumer-app'; $p | Should -Contain 'vendor-cleanup' }
  }
  It 'emits the ids as plain strings (not one wrapped array)' {
    $p = P DELL LAPTOP
    $p.Count | Should -Be 19
    $p[0] | Should -BeOfType [string]; $p[0] | Should -Be 'prepare'; $p[18] | Should -Be 'finalize'
  }
  It 'the id list survives the caller patterns: @(), foreach, pipeline, New-RunState -Plan' {
    $m = @{Brand='DELL'}; $c = @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'}
    @(Get-StepPlan -Machine $m -Choices $c -Config $cfg).Count | Should -Be 19
    @(Get-StepPlan -Machine $m -Choices $c -Config $cfg)[0] | Should -Be 'prepare'
    $seen = 0; foreach ($id in Get-StepPlan -Machine $m -Choices $c -Config $cfg) { $seen++ }
    $seen | Should -Be 19
    @(Get-StepPlan -Machine $m -Choices $c -Config $cfg | ForEach-Object { $_ }).Count | Should -Be 19
    $state = New-RunState -Machine @{} -Choices $c -Plan (Get-StepPlan -Machine $m -Choices $c -Config $cfg) -Version 'v'
    @($state.Plan).Count | Should -Be 19
    $state.Plan[0] | Should -Be 'prepare'
    $state.Steps.Count | Should -Be 19
  }
  It 'Office HOME keeps the office step' { (P DELL LAPTOP $true 'HOME') | Should -Contain 'office'; (P DELL LAPTOP $true 'HOME') | Should -Contain 'office-finish' }
  It 'CRAFT: craft-apps right after 7zip, and no Microsoft 365 steps' {
    (P DELL LAPTOP $true 'CRAFT') -join ',' | Should -Be 'prepare,bitlocker,region,desktop-icons,bloatware,rename,winget,chrome,anydesk,7zip,craft-apps,default-browser,vendor-pass1,windows-update,vendor-pass2,consumer-app,vendor-cleanup,finalize' }
  It 'CRAFT without 7-Zip: craft-apps right after anydesk' { $p = @(P ASUS DESKTOP $false 'CRAFT'); $p.IndexOf('craft-apps') | Should -Be ($p.IndexOf('anydesk') + 1) }
  It 'BUSINESS, HOME and OFF never get craft-apps' { foreach ($o in 'BUSINESS', 'HOME', 'OFF') { (P DELL LAPTOP $true $o) | Should -Not -Contain 'craft-apps' } }
  It 'the default choices plan craft-apps, not Microsoft 365' {
    $o = (New-DefaultChoices -Machine @{ IsLaptop = $true } -Config $cfg).Office
    $p = P DELL LAPTOP $true $o
    $p | Should -Contain 'craft-apps'; $p | Should -Not -Contain 'office'; $p | Should -Not -Contain 'office-finish' }
  It 'BOTH: screenconnect right after anydesk' {
    (P DELL LAPTOP $true 'BUSINESS' 'BOTH') -join ',' | Should -Be 'prepare,bitlocker,region,desktop-icons,bloatware,rename,winget,chrome,anydesk,screenconnect,7zip,default-browser,vendor-pass1,office,windows-update,office-finish,vendor-pass2,consumer-app,vendor-cleanup,finalize' }
  It 'SCREENCONNECT: no anydesk, screenconnect right after chrome' {
    $p = @(P ASUS DESKTOP $false 'CRAFT' 'SCREENCONNECT'); $p | Should -Not -Contain 'anydesk'; $p.IndexOf('screenconnect') | Should -Be ($p.IndexOf('chrome') + 1) }
  It 'ANYDESK, an empty or unknown Remote and a lower-case value plan as their Get-RemoteChoice says (Review Focus 1)' {
    $today = (P DELL LAPTOP) -join ','
    foreach ($r in 'ANYDESK', '', 'TEAMVIEWER') { (P DELL LAPTOP $true 'BUSINESS' $r) -join ',' | Should -Be $today -Because $r }
    (P DELL LAPTOP $true 'BUSINESS' 'both') | Should -Contain 'screenconnect' }
  It 'the default choices plan AnyDesk only' {
    $d = New-DefaultChoices -Machine @{ IsLaptop = $true } -Config $cfg; $p = Get-StepPlan -Machine @{ Brand = 'DELL' } -Choices $d -Config $cfg
    $p | Should -Contain 'anydesk'; $p | Should -Not -Contain 'screenconnect' }
  It 'tweaks right after desktop-icons when the effective list is not empty' {
    $p = @(P DELL LAPTOP $true 'BUSINESS' $null @('noAds')); $p.IndexOf('tweaks') | Should -Be ($p.IndexOf('desktop-icons') + 1) }
  It 'no tweaks step when every chosen tweak is ruled out (NumLock on a laptop)' { P DELL LAPTOP $true 'CRAFT' $null @('numLock') | Should -Not -Contain 'tweaks' }
  It 'the default choices (home profile) plan the tweaks step' {
    $d = New-DefaultChoices -Machine @{ IsLaptop = $true } -Config $cfg; Get-StepPlan -Machine @{ Brand = 'DELL' } -Choices $d -Config $cfg | Should -Contain 'tweaks' }
}
Describe 'Get-EffectiveTweaks (toolbox spec 5.3)' {
  BeforeAll { $script:home5 = @('accessKeys', 'numLock', 'startClean', 'noAds', 'classicOutlook') }
  It '<Why>' -ForEach @(
    @{ Why = 'laptop with Craft: no NumLock, no classic Outlook'; C = @{ Mode = 'LAPTOP'; Office = 'CRAFT' }; B = 26200; E = 'accessKeys,startClean,noAds' }
    @{ Why = 'desktop with Craft: NumLock'; C = @{ Mode = 'DESKTOP'; Office = 'CRAFT' }; B = 26200; E = 'accessKeys,numLock,startClean,noAds' }
    @{ Why = 'desktop with 365 Business: both'; C = @{ Mode = 'DESKTOP'; Office = 'BUSINESS' }; B = 26200; E = 'accessKeys,numLock,startClean,noAds,classicOutlook' }
    @{ Why = 'laptop with a lower-case home'; C = @{ Mode = 'LAPTOP'; Office = 'home' }; B = 26200; E = 'accessKeys,startClean,noAds,classicOutlook' }
  ) { $C.Tweaks = $home5; (@(Get-EffectiveTweaks -Choices $C -Config $cfg -Machine @{ OsBuild = $B }) -join ',') | Should -BeExactly $E }
  It 'Windows 10 leaves out the minBuild 22000 tweaks; an unknown build keeps them' {
    $c = @{ Mode = 'DESKTOP'; Office = 'OFF'; Tweaks = @('endTask', 'fileExtensions', 'classicMenu', 'taskbarLeft') }
    @(Get-EffectiveTweaks -Choices $c -Config $cfg -Machine @{ OsBuild = 19045 }) | Should -Be @('fileExtensions')
    @(Get-EffectiveTweaks -Choices $c -Config $cfg -Machine @{}) | Should -Be @('fileExtensions', 'taskbarLeft', 'classicMenu', 'endTask') }
  It 'drops unknown, empty and repeated ids, and keeps catalog order' {
    @(Get-EffectiveTweaks -Choices @{ Mode = 'LAPTOP'; Office = 'OFF'; Tweaks = @('noAds', 'widgets', '', $null, 'accessKeys', 'noAds') } -Config $cfg) | Should -Be @('accessKeys', 'noAds') }
  It 'no Tweaks key, no choices or no config means none (an older state.json)' {
    @(Get-EffectiveTweaks -Choices @{ Mode = 'DESKTOP' } -Config $cfg).Count | Should -Be 0
    @(Get-EffectiveTweaks -Choices $null -Config $cfg).Count | Should -Be 0; @(Get-EffectiveTweaks -Choices @{ Tweaks = @('noAds') } -Config $null).Count | Should -Be 0 }
}
Describe 'Get-TweakCatalog guard: every rule keeps or drops (toolbox spec 5.3, review I1)' {
  BeforeAll {
    # How many tweaks Get-TweakCatalog keeps from a config whose only entry is the given JSON. GOOD in the text
    # stands for a valid value; the value tables use an entry "t1" around one value.
    $script:good = '{"path":"HKCU:\\Software\\BenTech","name":"n","type":"DWord","op":"set","value":0}'
    function Get-KeptCount([string]$EntryJson) {
      @(Get-TweakCatalog -Config (('{"tweaks":[' + $EntryJson.Replace('GOOD', $script:good) + ']}') | ConvertFrom-Json)).Count }
    function Get-ValueEntry([string]$ValueJson) { '{"id":"t1","title":{"en":"T"},"values":[' + $ValueJson + ']}' }
  }
  It 'keeps a value whose path is <Why>' -ForEach @(
    @{ Why = 'under HKCU:\';                         P = '"HKCU:\\Software\\BenTech"' }
    @{ Why = 'under HKLM:\';                         P = '"HKLM:\\SOFTWARE\\BenTech"' }
    @{ Why = 'under the sign-in profile';            P = '"Registry::HKEY_USERS\\.DEFAULT\\Control Panel\\Keyboard"' }
    @{ Why = 'a lower-case hive';                    P = '"hkcu:\\software\\BenTech"' }
    @{ Why = 'a CLSID key with braces';              P = '"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32"' }
    @{ Why = 'Policies only inside a longer segment'; P = '"HKCU:\\Software\\MyPolicies\\Policies2"' }
  ) { Get-KeptCount (Get-ValueEntry ('{"path":' + $P + ',"name":"n","type":"DWord","op":"set","value":0}')) | Should -Be 1 }
  It 'drops a value whose path <Why>' -ForEach @(
    @{ Why = 'is in HKCR:';                          P = '"HKCR:\\Software\\BenTech"' }
    @{ Why = 'names HKCU through the provider';      P = '"Registry::HKEY_CURRENT_USER\\Software\\BenTech"' }
    @{ Why = 'names HKLM through the provider';      P = '"Registry::HKEY_LOCAL_MACHINE\\SOFTWARE\\BenTech"' }
    @{ Why = 'is another user''s hive';               P = '"Registry::HKEY_USERS\\S-1-5-21-1-2-3-1001\\Software\\BenTech"' }
    @{ Why = 'is relative';                          P = '"Software\\BenTech"' }
    @{ Why = 'is empty';                             P = '""' }
    @{ Why = 'is not a string';                      P = '5' }
    @{ Why = 'is missing';                           P = 'null' }
    @{ Why = 'has \Policies\ in the middle';         P = '"HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows"' }
    @{ Why = 'ends in \Policies';                    P = '"HKLM:\\SOFTWARE\\Policies"' }
    @{ Why = 'has Policies in mixed case';           P = '"HKCU:\\Software\\pOlIcIeS\\BenTech"' }
    @{ Why = 'has Policies under WOW6432Node';       P = '"HKLM:\\SOFTWARE\\WOW6432Node\\Policies\\Microsoft"' }
    @{ Why = 'has /Policies/';                       P = '"HKLM:\\SOFTWARE/Policies/Microsoft"' }
    @{ Why = 'has any /';                            P = '"HKCU:\\Software/BenTech"' }
    @{ Why = 'has a *';                              P = '"HKCU:\\Software\\*"' }
    @{ Why = 'has a ?';                              P = '"HKCU:\\Software\\Ben?ech"' }
    @{ Why = 'has a [';                              P = '"HKCU:\\Software\\[ab]"' }
    @{ Why = 'has a ]';                              P = '"HKCU:\\Software\\ab]"' }
    @{ Why = 'has a .. segment';                     P = '"HKCU:\\Software\\Microsoft\\..\\Classes"' }
    @{ Why = 'ends in ..';                           P = '"HKCU:\\Software\\Microsoft\\.."' }
    @{ Why = 'has a . segment';                      P = '"HKCU:\\Software\\.\\BenTech"' }
    @{ Why = 'has a NUL (Windows cuts the name there: Policies)'; P = '"HKLM:\\SOFTWARE\\Policies\u0000x"' }   # task 1 re-review N1
    @{ Why = 'has a control character (0x1F)';      P = '"HKCU:\\Software\\Ben\u001fTech"' }
  ) { Get-KeptCount (Get-ValueEntry ('{"path":' + $P + ',"name":"n","type":"DWord","op":"set","value":0}')) | Should -Be 0 }
  It 'keeps <Why>' -ForEach @(
    @{ Why = 'a DWord set of 0';                      F = '"name":"n","type":"DWord","op":"set","value":0' }
    @{ Why = 'a DWord set of 0x7FFFFFFF';             F = '"name":"n","type":"DWord","op":"set","value":2147483647' }
    @{ Why = 'a String set';                          F = '"name":"n","type":"String","op":"set","value":"2"' }
    @{ Why = 'a String set of the default value to an empty string'; F = '"name":"","type":"String","op":"set","value":""' }
    @{ Why = 'a clearBit of bit 1';                   F = '"name":"Flags","type":"String","op":"clearBit","bit":1,"value":"506"' }
    @{ Why = 'a clearBit of bit 0x80000000';          F = '"name":"Flags","type":"String","op":"clearBit","bit":2147483648,"value":"506"' }
  ) { Get-KeptCount (Get-ValueEntry ('{"path":"HKCU:\\Software\\BenTech",' + $F + '}')) | Should -Be 1 }
  It 'drops a value with <Why>' -ForEach @(
    @{ Why = 'type ExpandString';                     F = '"name":"n","type":"ExpandString","op":"set","value":"x"' }
    @{ Why = 'type QWord';                            F = '"name":"n","type":"QWord","op":"set","value":0' }
    @{ Why = 'type dword in lower case';              F = '"name":"n","type":"dword","op":"set","value":0' }
    @{ Why = 'no type';                               F = '"name":"n","op":"set","value":0' }
    @{ Why = 'op delete';                             F = '"name":"n","type":"DWord","op":"delete","value":0' }
    @{ Why = 'op Set in another case';                F = '"name":"n","type":"DWord","op":"Set","value":0' }
    @{ Why = 'no op';                                 F = '"name":"n","type":"DWord","value":0' }
    @{ Why = 'clearBit on a DWord';                   F = '"name":"Flags","type":"DWord","op":"clearBit","bit":4,"value":"506"' }
    @{ Why = 'clearBit of bit 3 (not a power of two)'; F = '"name":"Flags","type":"String","op":"clearBit","bit":3,"value":"506"' }
    @{ Why = 'clearBit of bit 0';                     F = '"name":"Flags","type":"String","op":"clearBit","bit":0,"value":"506"' }
    @{ Why = 'clearBit of bit 0x100000000';           F = '"name":"Flags","type":"String","op":"clearBit","bit":4294967296,"value":"506"' }
    @{ Why = 'clearBit without a bit';                F = '"name":"Flags","type":"String","op":"clearBit","value":"506"' }
    @{ Why = 'clearBit with the bit as text';         F = '"name":"Flags","type":"String","op":"clearBit","bit":"4","value":"506"' }
    @{ Why = 'clearBit with a negative value';        F = '"name":"Flags","type":"String","op":"clearBit","bit":4,"value":"-1"' }
    @{ Why = 'clearBit with a value that is not digits'; F = '"name":"Flags","type":"String","op":"clearBit","bit":4,"value":"50a"' }
    @{ Why = 'clearBit with an empty value';          F = '"name":"Flags","type":"String","op":"clearBit","bit":4,"value":""' }
    @{ Why = 'clearBit with a value above 32 bits';   F = '"name":"Flags","type":"String","op":"clearBit","bit":4,"value":"4294967296"' }
    @{ Why = 'clearBit with a number, not text';      F = '"name":"Flags","type":"String","op":"clearBit","bit":4,"value":506' }
    @{ Why = 'clearBit with an empty name';           F = '"name":"","type":"String","op":"clearBit","bit":4,"value":"506"' }
    @{ Why = 'a DWord of -1';                         F = '"name":"n","type":"DWord","op":"set","value":-1' }
    @{ Why = 'a DWord of 0x80000000';                 F = '"name":"n","type":"DWord","op":"set","value":2147483648' }
    @{ Why = 'a DWord given as text';                 F = '"name":"n","type":"DWord","op":"set","value":"0"' }
    @{ Why = 'a DWord of 1.5';                        F = '"name":"n","type":"DWord","op":"set","value":1.5' }
    @{ Why = 'a DWord without a value';               F = '"name":"n","type":"DWord","op":"set"' }
    @{ Why = 'a DWord with an empty name';            F = '"name":"","type":"DWord","op":"set","value":0' }
    @{ Why = 'a String without a value';              F = '"name":"n","type":"String","op":"set","value":null' }
    @{ Why = 'a String given a number';               F = '"name":"n","type":"String","op":"set","value":5' }
    @{ Why = 'no name';                               F = '"type":"DWord","op":"set","value":0' }
    @{ Why = 'a name that is not text';               F = '"name":5,"type":"DWord","op":"set","value":0' }
  ) { Get-KeptCount (Get-ValueEntry ('{"path":"HKCU:\\Software\\BenTech",' + $F + '}')) | Should -Be 0 }
  It 'keeps an entry with <Why>' -ForEach @(
    @{ Why = 'every rule field set';                  E = '{"id":"t1","title":{"en":"T"},"desktopOnly":true,"office365Only":false,"minBuild":22000,"values":[GOOD]}' }
    @{ Why = 'a 32-character id';                     E = '{"id":"tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":{"en":"T"},"values":[GOOD]}' }
  ) { Get-KeptCount $E | Should -Be 1 }
  It 'drops an entry with <Why>' -ForEach @(
    @{ Why = 'a space in its id';                     E = '{"id":"bad id","title":{"en":"T"},"values":[GOOD]}' }
    @{ Why = 'an id that starts with a digit';        E = '{"id":"1abc","title":{"en":"T"},"values":[GOOD]}' }
    @{ Why = 'a dash in its id';                      E = '{"id":"a-b","title":{"en":"T"},"values":[GOOD]}' }
    @{ Why = 'a 33-character id';                     E = '{"id":"tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":{"en":"T"},"values":[GOOD]}' }
    @{ Why = 'no id';                                 E = '{"title":{"en":"T"},"values":[GOOD]}' }
    @{ Why = 'an empty title';                        E = '{"id":"t1","title":{"en":""},"values":[GOOD]}' }
    @{ Why = 'no title';                              E = '{"id":"t1","values":[GOOD]}' }
    @{ Why = 'no values';                             E = '{"id":"t1","title":{"en":"T"},"values":[]}' }
    @{ Why = 'no values property';                    E = '{"id":"t1","title":{"en":"T"}}' }
    @{ Why = 'one good and one bad value';            E = '{"id":"t1","title":{"en":"T"},"values":[GOOD,{"path":"HKLM:\\SOFTWARE\\Policies\\x","name":"n","type":"DWord","op":"set","value":0}]}' }
    @{ Why = 'desktopOnly given as text';             E = '{"id":"t1","title":{"en":"T"},"desktopOnly":"yes","values":[GOOD]}' }
    @{ Why = 'office365Only given as a number';       E = '{"id":"t1","title":{"en":"T"},"office365Only":1,"values":[GOOD]}' }
    @{ Why = 'a minBuild of 1.5';                     E = '{"id":"t1","title":{"en":"T"},"minBuild":1.5,"values":[GOOD]}' }
    @{ Why = 'a minBuild given as text';              E = '{"id":"t1","title":{"en":"T"},"minBuild":"22000","values":[GOOD]}' }
    @{ Why = 'a negative minBuild';                   E = '{"id":"t1","title":{"en":"T"},"minBuild":-1,"values":[GOOD]}' }
  ) { Get-KeptCount $E | Should -Be 0 }
  It 'keeps the first of two ids that differ only in case' {
    $x = '{"tweaks":[{"id":"t1","title":{"en":"First"},"values":[GOOD]},{"id":"T1","title":{"en":"Second"},"values":[GOOD]}]}'.Replace('GOOD', $script:good) | ConvertFrom-Json
    @(Get-TweakCatalog -Config $x | ForEach-Object { $_.Title.en }) | Should -Be @('First') }
}
Describe 'Get-RunVerdict' {
  BeforeEach { $script:s = New-RunState -Machine @{} -Choices @{} -Plan @('chrome','office') -Version 'v'
               $s.Steps.chrome.Status = 'Done'; $s.Steps.office.Status = 'Done' }
  It 'green' { (Get-RunVerdict -State $s).Color | Should -Be 'GREEN' }
  It 'green banner' { (Get-RunVerdict -State $s).Banner | Should -Be 'SETUP COMPLETE' }
  It 'yellow on skipped' { $s.Steps.office.Status = 'Skipped'; $s.Steps.office.Message = 'x'; $v = Get-RunVerdict -State $s; $v.Color | Should -Be 'YELLOW'; $v.Banner | Should -Be 'COMPLETE - CHECK NOTES' }
  It 'yellow on a note' { $s.Notes = @('Windows 10: no security updates'); (Get-RunVerdict -State $s).Color | Should -Be 'YELLOW' }
  It 'red on failed' { $s.Steps.chrome.Status = 'Failed'; (Get-RunVerdict -State $s).Banner | Should -Be 'COMPLETED WITH ERRORS' }
  It 'red on hidden update' { $s.HiddenUpdateIds = @('abc'); (Get-RunVerdict -State $s).Color | Should -Be 'RED' }
  It 'red on reboot cap' { $s.RebootCapHit = $true; (Get-RunVerdict -State $s).Failures | Should -Contain 'Reboot limit reached' }
  It 'red on a state error' { $s.Errors = @('Drive still encrypted'); (Get-RunVerdict -State $s).Color | Should -Be 'RED' }
  It 'formats a failed step as Title colon Message' {
    $s.Steps.chrome.Status = 'Failed'; $s.Steps.chrome.Message = 'download timed out'
    (Get-RunVerdict -State $s).Failures | Should -Contain 'Google Chrome: download timed out'
  }
  It 'formats a skipped step as a note, Title colon Message' {
    $s.Steps.office.Status = 'Skipped'; $s.Steps.office.Message = 'already installed'
    (Get-RunVerdict -State $s).Notes | Should -Contain 'Microsoft 365: already installed'
  }
  It 'names the hidden update id' {
    $s.HiddenUpdateIds = @('abc', 'def'); $f = (Get-RunVerdict -State $s).Failures
    $f | Should -Contain 'Windows update failed repeatedly (left to Windows Update): abc'
    $f | Should -Contain 'Windows update failed repeatedly (left to Windows Update): def'
  }
  It 'passes state notes and errors through' {
    $s.Notes = @('n1'); $s.Errors = @('e1'); $v = Get-RunVerdict -State $s
    $v.Notes | Should -Contain 'n1'; $v.Failures | Should -Contain 'e1'
  }
  It 'failures outrank notes: red even with notes present' {
    $s.Steps.office.Status = 'Skipped'; $s.Steps.office.Message = 'x'; $s.Steps.chrome.Status = 'Failed'
    $v = Get-RunVerdict -State $s; $v.Color | Should -Be 'RED'; @($v.Notes).Count | Should -Be 1
  }
  It 'a step still pending counts as a failure (never green when steps never ran)' {
    $s.Steps.office.Status = 'pending'
    $v = Get-RunVerdict -State $s
    $v.Color | Should -Be 'RED'; $v.Banner | Should -Be 'COMPLETED WITH ERRORS'
    $v.Failures | Should -Contain 'Microsoft 365: did not finish'
  }
  It 'a step still running counts as a failure' {
    $s.Steps.chrome.Status = 'running'
    $v = Get-RunVerdict -State $s
    $v.Color | Should -Be 'RED'; $v.Failures | Should -Contain 'Google Chrome: did not finish'
  }
  It 'a plan step with no state entry counts as a failure' {
    $s.Steps.Remove('office')
    (Get-RunVerdict -State $s).Failures | Should -Contain 'Microsoft 365: did not finish'
  }
  It 'ignores steps that are not in the plan' {
    $s.Plan = @('chrome'); $s.Steps.office.Status = 'Failed'
    (Get-RunVerdict -State $s).Color | Should -Be 'GREEN'
  }
  It 'returns Failures and Notes as arrays, empty when green' {
    $v = Get-RunVerdict -State $s
    $v.Failures -is [string[]] | Should -BeTrue; $v.Notes -is [string[]] | Should -BeTrue
    @($v.Failures).Count | Should -Be 0; @($v.Notes).Count | Should -Be 0
  }
  It 'names a hidden update by the title the Windows Update step recorded, else by its id (M7)' {
    $s.Plan = @('chrome', 'windows-update'); $s.Steps['windows-update'] = @{ Status = 'Done'; Message = ''; Data = @{ FailedTitles = @{ 'abc' = 'Cumulative Update KB5050001'; 'xyz' = 'not hidden' } } }
    $s.HiddenUpdateIds = @('abc', 'def')
    $f = (Get-RunVerdict -State $s).Failures
    $f | Should -Contain 'Windows update failed repeatedly (left to Windows Update): Cumulative Update KB5050001'
    $f | Should -Contain 'Windows update failed repeatedly (left to Windows Update): def'
    ($f -join "`n") | Should -Not -Match 'xyz|not hidden'
  }
  It 'falls back to the id when the title is empty or the step Data is missing' {
    $s.Plan = @('chrome', 'windows-update'); $s.Steps['windows-update'] = @{ Status = 'Done'; Message = ''; Data = @{ FailedTitles = @{ 'abc' = '  ' } } }
    $s.HiddenUpdateIds = @('abc')
    (Get-RunVerdict -State $s).Failures | Should -Contain 'Windows update failed repeatedly (left to Windows Update): abc'
    $s.Steps['windows-update'] = @{ Status = 'Done'; Message = '' }
    (Get-RunVerdict -State $s).Failures | Should -Contain 'Windows update failed repeatedly (left to Windows Update): abc'
  }
  It 'lists an exact duplicate failure or note once, keeping the first (M1)' {
    $s.Steps.chrome.Status = 'Failed'; $s.Steps.chrome.Message = 'x'
    $s.Errors = @('Restart skipped: no resume task', 'Google Chrome: x', 'Restart skipped: no resume task', 'restart skipped: no resume task')
    $s.Notes = @('On battery: BIOS skipped', 'n2', 'On battery: BIOS skipped')
    $v = Get-RunVerdict -State $s
    @($v.Failures) | Should -Be @('Google Chrome: x', 'Restart skipped: no resume task', 'restart skipped: no resume task')   # exact match only
    @($v.Notes) | Should -Be @('On battery: BIOS skipped', 'n2')
    $v.Failures -is [string[]] | Should -BeTrue
  }
}
