# src/Engine/Catalog.ps1
# The ordered list of setup steps and the rules that pick which of them apply to one machine.
#
# Only the step *names* live here as strings. The Invoke-Step* functions are defined by the files in
# src/Steps/ and are resolved by the runner at call time (the bundle test in Task 17 asserts that
# every Function below exists).

# Defined at file scope on purpose: dot-sourcing this file, or bundling it into one script, makes
# $script:StepCatalog visible to Get-StepPlan, Get-RunVerdict and the runner.
$script:StepCatalog = @(
  @{ Id = 'prepare';         Title = 'Prepare machine';                 Function = 'Invoke-StepPrepare' }
  @{ Id = 'bitlocker';       Title = 'Turn off BitLocker';              Function = 'Invoke-StepBitLocker' }
  @{ Id = 'region';          Title = 'Time zone + Hebrew keyboard';     Function = 'Invoke-StepRegion' }
  @{ Id = 'desktop-icons';   Title = 'Desktop icons';                   Function = 'Invoke-StepDesktopIcons' }
  @{ Id = 'bloatware';       Title = 'Remove bloatware';                Function = 'Invoke-StepBloatware' }
  @{ Id = 'rename';          Title = 'Rename PC';                       Function = 'Invoke-StepRename' }
  @{ Id = 'winget';          Title = 'Prepare winget';                  Function = 'Invoke-StepWinget' }
  @{ Id = 'chrome';          Title = 'Google Chrome';                   Function = 'Invoke-StepChrome' }
  @{ Id = 'anydesk';         Title = 'AnyDesk';                         Function = 'Invoke-StepAnyDesk' }
  @{ Id = '7zip';            Title = '7-Zip';                           Function = 'Invoke-StepSevenZip' }
  @{ Id = 'office';          Title = 'Microsoft 365';                   Function = 'Invoke-StepOffice' }
  @{ Id = 'default-browser'; Title = 'Chrome as default browser';       Function = 'Invoke-StepDefaultBrowser' }
  @{ Id = 'vendor-pass1';    Title = 'Vendor drivers + BIOS (pass 1)';  Function = 'Invoke-StepVendorPass1' }
  @{ Id = 'windows-update';  Title = 'Windows Update';                  Function = 'Invoke-StepWindowsUpdate' }
  @{ Id = 'vendor-pass2';    Title = 'Vendor drivers + BIOS (pass 2)';  Function = 'Invoke-StepVendorPass2' }
  @{ Id = 'consumer-app';    Title = 'Vendor app';                      Function = 'Invoke-StepConsumerApp' }
  @{ Id = 'vendor-cleanup';  Title = 'Remove business updater';         Function = 'Invoke-StepVendorCleanup' }
  @{ Id = 'finalize';        Title = 'Finalize';                        Function = 'Invoke-StepFinalize' }
)

# Brands whose vendor tool (Dell Command | Update, Lenovo System Update, HP Image Assistant) the
# tool runs for drivers + BIOS, and whose pre-installed business updater is removed on laptops.
$script:BusinessUpdaterBrands = @('DELL', 'LENOVO', 'HP')

function Test-HasConsumerApp {
  # True when config.vendors has an entry for this brand and that entry has a consumerApp.
  # Uses PSObject.Properties so a missing brand or a missing consumerApp is $false, not an error
  # (VM, OTHER and SAMSUNG have no vendors entry; ASUS/ACER/MSI/SURFACE have no tool section).
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()]$Config,
    [AllowNull()][AllowEmptyString()][string]$Brand
  )

  if ($null -eq $Config -or [string]::IsNullOrEmpty($Brand)) { return $false }
  $vendors = $Config.PSObject.Properties['vendors']
  if ($null -eq $vendors -or $null -eq $vendors.Value) { return $false }
  $entry = $vendors.Value.PSObject.Properties[$Brand]
  if ($null -eq $entry -or $null -eq $entry.Value) { return $false }
  $consumerApp = $entry.Value.PSObject.Properties['consumerApp']
  return ($null -ne $consumerApp -and $null -ne $consumerApp.Value)
}

function Get-StepPlan {
  <#
  .SYNOPSIS
    Returns the ids of the steps that apply to this machine, in catalog order.
  .DESCRIPTION
    Vendor passes: DELL/LENOVO/HP only. Vendor app: laptop mode and a configured consumerApp.
    Business-updater cleanup: laptop mode and DELL/LENOVO/HP. A VM never gets a vendor step.
    The mode comes from Choices (what the technician picked), never from Machine.IsLaptop.
    The result is emitted as ONE string[] object (so it stays an array whatever its length). Assign it
    first (`$plan = Get-StepPlan ...`); `foreach ($id in Get-StepPlan ...)` or piping the call directly
    would see a single item, the whole array.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)][hashtable]$Choices,
    [Parameter(Mandatory)]$Config
  )

  $brand = [string]$Machine['Brand']
  # Resolve-Brand already reports a VM as 'VM'; checking IsVM too keeps "a VM never gets a vendor
  # step" true even if the two fields ever disagree.
  $isVm = ($brand -eq 'VM') -or ($Machine['IsVM'] -eq $true)
  $isLaptopMode = ($Choices['Mode'] -eq 'LAPTOP')
  $hasBusinessTool = (-not $isVm) -and ($script:BusinessUpdaterBrands -contains $brand)
  $hasConsumerApp = (-not $isVm) -and (Test-HasConsumerApp -Config $Config -Brand $brand)

  $plan = New-Object System.Collections.Generic.List[string]
  foreach ($step in $script:StepCatalog) {
    $include = switch ($step.Id) {
      'vendor-pass1'   { $hasBusinessTool }
      'vendor-pass2'   { $hasBusinessTool }
      'consumer-app'   { $isLaptopMode -and $hasConsumerApp }
      'vendor-cleanup' { $isLaptopMode -and $hasBusinessTool }
      '7zip'           { [bool]$Choices['SevenZip'] }
      'office'         { $Choices['Office'] -ne 'OFF' }
      default          { $true }
    }
    if ($include) { $plan.Add($step.Id) }
  }

  # The comma keeps a one-element plan an array instead of letting PowerShell unroll it.
  return , $plan.ToArray()
}
