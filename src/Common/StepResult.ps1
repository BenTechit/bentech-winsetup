function New-StepResult {
  <#
  .SYNOPSIS
    Builds the result object every setup step returns.
  .DESCRIPTION
    Status 'Continue' means "call this step again" (Windows Update rounds, Finalize phases).
    Notes are yellow-level messages, Errors are red-level messages; the runner appends both to the state.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('Done', 'Skipped', 'Failed', 'Continue')][string]$Status,
    [string]$Message = '',
    [ValidateSet('None', 'Now')][string]$Reboot = 'None',
    [string[]]$Notes = @(),
    [string[]]$Errors = @(),
    [hashtable]$Data = @{}
  )

  [pscustomobject]@{
    Status  = $Status
    Message = $Message
    Reboot  = $Reboot
    Notes   = [string[]]@($Notes | Where-Object { $null -ne $_ })
    Errors  = [string[]]@($Errors | Where-Object { $null -ne $_ })
    Data    = $Data
  }
}
