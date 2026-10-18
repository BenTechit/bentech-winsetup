# tests/Config.Tests.ps1
BeforeAll { . "$PSScriptRoot\..\src\Common\Config.ps1"; $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json" }
Describe 'config.json' {
  It 'has every top-level key' {
    foreach ($k in 'defaults','caps','timeoutsMinutes','power','freshInstall','signers','winget','apps','vendors','bloatware','nags') {
      $cfg.PSObject.Properties.Name | Should -Contain $k }
  }
  It 'pins spec values' {
    $cfg.caps.maxReboots | Should -Be 12; $cfg.caps.maxWuRounds | Should -Be 6
    $cfg.apps.office.products.BUSINESS | Should -Be 'O365BusinessRetail'
    $cfg.apps.office.products.HOME | Should -Be 'O365HomePremRetail'
    $cfg.apps.office.languages[0] | Should -Be 'he-il'
  }
  It 'never removes a protected package' {
    foreach ($r in $cfg.bloatware.remove) { foreach ($p in $cfg.bloatware.protect) { $r | Should -Not -BeLike $p } }
  }
  It 'every signer key referenced exists' {
    $refs = @($cfg.apps.chrome.signer, $cfg.apps.anydesk.signer, $cfg.apps.office.signer) +
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
  It 'throws on a missing key' {
    '{"defaults":{}}' | Set-Content "$TestDrive\c.json"; { Read-SetupConfig -Path "$TestDrive\c.json" } | Should -Throw '*config missing key*'
  }
}
