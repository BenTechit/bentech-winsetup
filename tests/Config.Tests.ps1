# tests/Config.Tests.ps1
BeforeAll {
  . "$PSScriptRoot\..\src\Common\Config.ps1"; $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"

  # Spec 9.3: the vendors whose consumerApp.verify entry is malformed. A verify entry must list at
  # least one non-empty path or service, and every listed value must be a string. Vendors without a
  # consumerApp or without verify (values not known yet: v1 behaviour) are fine.
  function Get-BadVerifyVendors {
    param([Parameter(Mandatory)]$Config)
    foreach ($p in $Config.vendors.PSObject.Properties) {
      $ver = $p.Value.consumerApp.verify
      if ($null -eq $ver) { continue }
      $values = @(@($ver.paths) + @($ver.services) | Where-Object { $null -ne $_ })
      $usable = @($values | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
      $notStrings = @($values | Where-Object { $_ -isnot [string] })
      if ($usable.Count -eq 0 -or $notStrings.Count -gt 0) { $p.Name }
    }
  }
}
Describe 'config.json' {
  It 'has every top-level key' {
    foreach ($k in 'defaults','caps','timeoutsMinutes','power','freshInstall','signers','winget','apps','vendors','bloatware','nags','profiles','tweaks','toolbox') {
      $cfg.PSObject.Properties.Name | Should -Contain $k }
  }
  It 'pins spec values' {
    $cfg.caps.maxReboots | Should -Be 12; $cfg.caps.maxWuRounds | Should -Be 6
    $cfg.defaults.office | Should -Be 'CRAFT'; $cfg.defaults.sevenZip | Should -BeTrue
    $cfg.apps.office.products.BUSINESS | Should -Be 'O365BusinessRetail'
    $cfg.apps.office.products.HOME | Should -Be 'O365HomePremRetail'
    $cfg.apps.office.languages[0] | Should -Be 'he-il'
  }
  It 'excludes every Office app except Word, Excel, PowerPoint, classic Outlook and OneNote' { @($cfg.apps.office.excludeApps) | Should -Be @('Access','Publisher','Teams','OneDrive','Groove','Lync','Bing','OutlookForWindows') }
  It 'never removes a protected package' {
    foreach ($r in $cfg.bloatware.remove) { foreach ($p in $cfg.bloatware.protect) { $r | Should -Not -BeLike $p } }
  }
  It 'every signer key referenced exists' {
    $refs = @($cfg.apps.chrome.signer, $cfg.apps.anydesk.signer, $cfg.apps.office.signer, $cfg.apps.craft.signer, $cfg.apps.screenconnect.signer) +
            @($cfg.vendors.PSObject.Properties.Value | ForEach-Object { $_.tool.signer } | Where-Object { $_ })
    foreach ($s in $refs) { @(Get-Signers -Config $cfg -Key $s).Count | Should -BeGreaterThan 0 }
  }
  It 'Get-Signers returns the configured names as an array' {
    $dell = @(Get-Signers -Config $cfg -Key 'dell')
    $dell.Count | Should -Be 2; $dell | Should -Contain 'Dell Technologies'
    @(Get-Signers -Config $cfg -Key 'google') | Should -Be @('Google LLC')
  }
  It 'Get-Signers throws on an unknown signer key instead of returning an empty list' {
    { Get-Signers -Config $cfg -Key 'nope' } | Should -Throw '*config missing signer: nope*'
  }
  It 'every consumerApp verify entry, when present, lists paths and/or services as strings' {
    @(Get-BadVerifyVendors -Config $cfg).Count | Should -Be 0
  }
  It 'the verify check accepts a well-formed entry and rejects an empty or non-string one' {
    # The same check on a synthetic config, so it is proven before config.json has any verify entry.
    $synthetic = @'
{ "vendors": {
  "BOTH":      { "consumerApp": { "id": "a", "verify": { "paths": ["%ProgramFiles%\\Dell\\SupportAssist.exe"], "services": ["SupportAssistAgent"] } } },
  "SERVICES":  { "consumerApp": { "id": "b", "verify": { "services": ["SupportAssistAgent"] } } },
  "NOVERIFY":  { "consumerApp": { "id": "c" } },
  "TOOLONLY":  { "tool": { "kind": "dcu" } },
  "EMPTY":     { "consumerApp": { "id": "d", "verify": {} } },
  "EMPTYLIST": { "consumerApp": { "id": "e", "verify": { "paths": [], "services": [""] } } },
  "NUMBER":    { "consumerApp": { "id": "f", "verify": { "paths": ["C:\\x.exe", 5] } } }
} }
'@ | ConvertFrom-Json
    @(Get-BadVerifyVendors -Config $synthetic) | Should -Be @('EMPTY', 'EMPTYLIST', 'NUMBER')
  }
  It 'lists the five Craft items in install order, the launcher last' {
    $items = @($cfg.apps.craft.items)
    @($items.name) | Should -Be @('WordCraft', 'GridCraft', 'DeckCraft', 'PdfCraft', 'ArtCraft Launcher')
    @($items.repo) | Should -Be @('storytold/wordcraft', 'storytold/gridcraft', 'storytold/deckcraft', 'storytold/pdfcraft', 'storytold/craft-launcher')
    @($items.assetPrefix) | Should -Be @('wordcraft', 'gridcraft', 'deckcraft', 'pdfcraft', 'artcraft-launcher')
    @($items.shortcut) | Should -Be @('Word', 'Excel', 'PowerPoint', 'PDF Reader', 'ArtCraft Launcher')
    @($items | Where-Object { $_.launcher -eq $true }).name | Should -Be 'ArtCraft Launcher'
  }
  It 'trusts the Craft MSIs by company name only' { @(Get-Signers -Config $cfg -Key $cfg.apps.craft.signer) | Should -Be @('Learning Machines Inc') }
  It 'every Craft displayName and startMenuName is a valid regular expression' {
    foreach ($i in $cfg.apps.craft.items) { foreach ($p in $i.displayName, $i.startMenuName) { $p | Should -Not -BeNullOrEmpty; { [void][regex]::new($p) } | Should -Not -Throw } }
  }
  It 'installs Windows updates one at a time by default' { $cfg.windowsUpdate.installMode | Should -Be 'OneAtATime' }
  It 'pins the ScreenConnect values (screenconnect spec 4.3)' {
    $cfg.defaults.remote | Should -BeExactly 'ANYDESK'
    $sc = $cfg.apps.screenconnect
    $sc.signer | Should -BeExactly 'connectwise'
    $sc.url | Should -BeExactly 'https://github.com/BenTechit/bentech-winsetup/releases/download/v{version}/ScreenConnect.ClientSetup.exe'
    $sc.sha256 | Should -BeExactly '74E058E0F597CF197132775552FBB6F4BDD21F8A0870E1A638D41A63F7C3FD99'
    $sc.serviceName | Should -BeExactly 'ScreenConnect Client (b58e7c32699a96bf)'
    $cfg.timeoutsMinutes.screenconnect | Should -Be 10; $cfg.timeoutsMinutes.screenconnectService | Should -Be 3
  }
  It 'trusts the ScreenConnect installer by the quoted name Windows shows' { @(Get-Signers -Config $cfg -Key 'connectwise') | Should -Be @('"ConnectWise, LLC"') }
  It 'the ScreenConnect link names a release of the repo Publish uploads to, never latest' {
    $repo = (Get-Content "$PSScriptRoot\..\tools\publish.settings.json" -Raw | ConvertFrom-Json).repo
    $cfg.apps.screenconnect.url | Should -BeLike "https://github.com/$repo/releases/download/v{version}/*"
    $cfg.apps.screenconnect.url | Should -Not -Match 'latest'
  }
  It 'pins the toolbox values (toolbox spec 5.2, 5.4)' {
    $cfg.defaults.profile | Should -BeExactly 'home'; $cfg.toolbox.language | Should -BeExactly 'en'; $cfg.timeoutsMinutes.restorePoint | Should -Be 10
    @($cfg.profiles | ForEach-Object { '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $_.id, $_.name.en, $_.office, $_.remote, $_.sevenZip, $_.restorePoint,
        $(if ($_.PSObject.Properties['tweaks']) { 'tweaks=' + (@($_.tweaks) -join ',') } else { 'catalog' }) }) | Should -Be @(
      'home|Home PC|CRAFT|ANYDESK|True|True|catalog', 'business|Business PC|BUSINESS|BOTH|True|True|catalog', 'clean|Clean Windows|OFF|ANYDESK|False|True|tweaks=')
    @($cfg.profiles.name.he) | Should -Be @('מחשב ביתי', 'מחשב עסקי', 'Windows נקי')   # also proves Read-SetupConfig reads UTF-8
  }
  It 'lists the nine shipped tweaks with their defaults and rules (spec 6.3, Q27: file extensions off everywhere)' {
    @($cfg.tweaks | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.id, $_.default, [bool]$_.desktopOnly, [bool]$_.office365Only, [int]$_.minBuild }) | Should -Be @(
      'accessKeys|True|False|False|0', 'numLock|True|True|False|0', 'startClean|True|False|False|0', 'noAds|True|False|False|0',
      'classicOutlook|True|False|True|0', 'fileExtensions|False|False|False|0', 'taskbarLeft|False|False|False|22000',
      'classicMenu|False|False|False|22000', 'endTask|False|False|False|22000') }
  It 'pins every tweak value (fact cards)' {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    @($cfg.tweaks | ForEach-Object { $t = $_; $t.values | ForEach-Object { '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $t.id, $_.path, $_.name, $_.type, $_.op, $_.bit, $_.value } }) | Should -Be @(
      'accessKeys|HKCU:\Control Panel\Accessibility\StickyKeys|Flags|String|clearBit|4|506'
      'accessKeys|HKCU:\Control Panel\Accessibility\Keyboard Response|Flags|String|clearBit|4|122'
      'numLock|Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard|InitialKeyboardIndicators|String|set||2147483650'
      'numLock|HKCU:\Control Panel\Keyboard|InitialKeyboardIndicators|String|set||2'
      "startClean|$adv|Start_IrisRecommendations|DWord|set||0", "startClean|$adv|Start_AccountNotifications|DWord|set||0"
      "noAds|$cdm|SubscribedContent-338389Enabled|DWord|set||0", "noAds|$cdm|SubscribedContent-338393Enabled|DWord|set||0"
      "noAds|$cdm|SubscribedContent-353694Enabled|DWord|set||0", "noAds|$cdm|SubscribedContent-353696Enabled|DWord|set||0"
      "noAds|$cdm|SubscribedContent-338387Enabled|DWord|set||0", "noAds|$cdm|RotatingLockScreenOverlayEnabled|DWord|set||0"
      "noAds|$adv|ShowSyncProviderNotifications|DWord|set||0"
      'classicOutlook|HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General|HideNewOutlookToggle|DWord|set||1'
      "fileExtensions|$adv|HideFileExt|DWord|set||0", "taskbarLeft|$adv|TaskbarAl|DWord|set||0"
      'classicMenu|HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32||String|set||'
      "endTask|$adv\TaskbarDeveloperSettings|TaskbarEndTask|DWord|set||1")
    $cfg.tweaks[7].values[0].value | Should -BeExactly ''   # a real empty string, not $null
  }
  It 'every tweak value obeys spec 5.3: allowed hive, no \Policies\, no value the run already manages' {
    . "$PSScriptRoot\..\src\Steps\Desktop.ps1"
    $managed = @($cfg.nags | ForEach-Object { '{0}|{1}' -f $_.path, $_.name }) + @(foreach ($k in $script:DesktopIconKeys) { foreach ($g in $script:DesktopIconGuids) { "$k|$g" } })
    $owned = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
      'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    foreach ($v in @($cfg.tweaks.values)) {
      $v.path | Should -Match '^(HKCU:\\|HKLM:\\|Registry::HKEY_USERS\\\.DEFAULT\\)'; $v.path | Should -Not -Match '(?i)\\Policies(\\|$)'
      # The registry provider turns '/' into '\' and resolves '.' and '..'; New-Item -Path takes * ? [ ] as wildcards (review I1).
      $v.path | Should -Not -Match '[/*?\[\]]'; $v.path | Should -Not -Match '(^|\\)\.{1,2}(\\|$)'
      $owned | Should -Not -Contain $v.path; $managed | Should -Not -Contain ('{0}|{1}' -f $v.path, $v.name) } }
  It 'all nine tweaks pass Get-TweakCatalog''s checks' { . "$PSScriptRoot\..\src\Engine\Catalog.ps1"; @(Get-TweakCatalog -Config $cfg).Id | Should -Be @($cfg.tweaks.id) }
  It 'holds non-ASCII text only inside "he" values (toolbox spec 4.3)' {
    function Find-NonAscii($o, $path) {
      if ($o -is [string]) { if ($o -match '[^\x00-\x7F]' -and $path -notmatch '\.he$') { $path } }
      elseif ($o -is [Management.Automation.PSCustomObject]) { foreach ($p in $o.PSObject.Properties) { Find-NonAscii $p.Value "$path.$($p.Name)" } }
      elseif ($o -is [Collections.IEnumerable]) { $i = 0; foreach ($x in $o) { Find-NonAscii $x "$path[$i]"; $i++ } } }
    @(Find-NonAscii $cfg '') | Should -BeNullOrEmpty }
  It 'throws on a missing key' {
    '{"defaults":{}}' | Set-Content "$TestDrive\c.json"; { Read-SetupConfig -Path "$TestDrive\c.json" } | Should -Throw '*config missing key*'
  }
}
