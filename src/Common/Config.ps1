function Read-SetupConfig {
  <#
  .SYNOPSIS
    Loads config.json and verifies every required top-level section is present.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  $required = 'defaults', 'caps', 'timeoutsMinutes', 'power', 'freshInstall', 'signers',
              'winget', 'apps', 'vendors', 'bloatware', 'nags'

  $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $present = @($config.PSObject.Properties.Name)
  foreach ($key in $required) {
    if ($present -notcontains $key) { throw "config missing key: $key" }
  }
  $config
}

function Get-Signers {
  <#
  .SYNOPSIS
    Returns the allowed certificate-subject names for a signer key (config.signers.<Key>).
  .DESCRIPTION
    Throws on an unknown key instead of returning nothing, so a typo cannot silently
    turn into an empty trust list.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Key
  )

  $entry = $Config.signers.PSObject.Properties[$Key]
  if (-not $entry) { throw "config missing signer: $Key" }
  [string[]]@($entry.Value)
}
