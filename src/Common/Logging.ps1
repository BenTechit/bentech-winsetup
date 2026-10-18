$script:SetupLogPath = $null

function Initialize-SetupLog {
  <#
  .SYNOPSIS
    Points the logger at <LogDirectory>\setup.log and creates the directory.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$LogDirectory)

  if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
  }
  $script:SetupLogPath = Join-Path $LogDirectory 'setup.log'
}

function Write-SetupLog {
  <#
  .SYNOPSIS
    Appends "yyyy-MM-dd HH:mm:ss [LEVEL] message {json}" to the setup log as UTF-8.
  .DESCRIPTION
    A no-op until Initialize-SetupLog has been called, so shared code can log unconditionally.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
    [hashtable]$Data
  )

  if (-not $script:SetupLogPath) { return }

  # Invariant culture: ':' and digits must not depend on the machine's regional settings.
  $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
  $line = '{0} [{1}] {2}' -f $stamp, $Level, $Message
  if ($Data -and $Data.Count -gt 0) {
    $line += ' ' + (ConvertTo-Json -InputObject $Data -Compress -Depth 6)
  }
  [IO.File]::AppendAllText($script:SetupLogPath, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
}
