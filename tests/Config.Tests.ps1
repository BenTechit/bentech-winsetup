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
  It 'throws on a missing key' {
    '{"defaults":{}}' | Set-Content "$TestDrive\c.json"; { Read-SetupConfig -Path "$TestDrive\c.json" } | Should -Throw '*config missing key*'
  }
}
