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
    foreach ($k in 'defaults','caps','timeoutsMinutes','power','freshInstall','signers','winget','apps','vendors','bloatware','nags') {
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
  It 'throws on a missing key' {
    '{"defaults":{}}' | Set-Content "$TestDrive\c.json"; { Read-SetupConfig -Path "$TestDrive\c.json" } | Should -Throw '*config missing key*'
  }
}
