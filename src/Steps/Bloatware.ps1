# src/Steps/Bloatware.ps1
# Step 4, "Remove bloatware" (spec 8.3 and section 10): a conservative removal of pre-installed junk.
# Needs StepResult.ps1 and Logging.ps1. The patterns are data: Config.bloatware.remove and
# Config.bloatware.protect (-like patterns). Protect always wins, so a pattern added to "remove"
# by mistake can never take a protected app (Store, Calculator, Photos, Xbox, Teams (work or school)...).

function Select-BloatwareToRemove {
  <#
  .SYNOPSIS
    Returns the package names that match any remove pattern and no protect pattern, in input order.
  .DESCRIPTION
    Patterns are PowerShell -like wildcards, matched case-insensitively. Emits the names one by one
    (a plain string[] for the caller; wrap the call in @() to get an array for zero or one name).
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [AllowNull()][string[]]$PackageNames,
    [AllowNull()][string[]]$RemovePatterns,
    [AllowNull()][string[]]$ProtectPatterns
  )

  $remove = @($RemovePatterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $protect = @($ProtectPatterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

  foreach ($name in @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $isJunk = $false
    foreach ($pattern in $remove) { if ($name -like $pattern) { $isJunk = $true } }
    $isProtected = $false
    foreach ($pattern in $protect) { if ($name -like $pattern) { $isProtected = $true } }
    if ($isJunk -and -not $isProtected) { $name }
  }
}

function Remove-BloatwarePackage {
  # Private. Removes one app for the current user (a no-op when the user does not have it) and each of
  # its provisioned copies (the ones new accounts would get). Every failure is a WARN in the log.
  # Returns $true only when nothing failed.
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$ProvisionedPackageNames = @()
  )

  $ok = $true
  try {
    Get-AppxPackage -Name $Name | Remove-AppxPackage -ErrorAction Stop | Out-Null
    Write-SetupLog -Message 'App removed for the current user (if installed)' -Data @{ name = $Name }
  } catch {
    $ok = $false
    Write-SetupLog -Message 'App could not be removed for the current user' -Level WARN -Data @{ name = $Name; error = $_.Exception.Message }
  }
  foreach ($packageName in @($ProvisionedPackageNames | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
    try {
      Remove-AppxProvisionedPackage -Online -PackageName $packageName -ErrorAction Stop | Out-Null
      Write-SetupLog -Message 'Provisioned app removed' -Data @{ name = $Name; package = $packageName }
    } catch {
      $ok = $false
      Write-SetupLog -Message 'Provisioned app could not be removed' -Level WARN -Data @{ name = $Name; package = $packageName; error = $_.Exception.Message }
    }
  }
  return $ok
}

function Invoke-StepBloatware {
  <#
  .SYNOPSIS
    Step 4: removes the apps in Config.bloatware.remove (minus Config.bloatware.protect). Always Done.
  .DESCRIPTION
    Names come from Get-AppxPackage (current user, .Name) and Get-AppxProvisionedPackage -Online
    (.DisplayName), de-duplicated. For each selected name the current user's copy is removed with
    Remove-AppxPackage and every provisioned copy with Remove-AppxProvisionedPackage -Online.
    A package counts as failed if either removal failed (a WARN is logged for each failure). The result is
    Done('Removed <N> packages'), with the Note 'Bloatware: <M> packages could not be removed' when
    M > 0. An app list that cannot be read is a Note too: it only means less is removed.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $notes = New-Object 'System.Collections.Generic.List[string]'
  $bloatware = $Context.Config.bloatware

  $installed = @()
  try {
    $installed = @(Get-AppxPackage -ErrorAction Stop | ForEach-Object { [string]$_.Name })
  } catch {
    Write-SetupLog -Message 'Installed apps could not be listed' -Level WARN -Data @{ error = $_.Exception.Message }
    $notes.Add('Bloatware: installed apps could not be listed')
  }
  $provisioned = @()
  try {
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
  } catch {
    Write-SetupLog -Message 'Provisioned apps could not be listed' -Level WARN -Data @{ error = $_.Exception.Message }
    $notes.Add('Bloatware: provisioned apps could not be listed')
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $names = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in @($installed) + @($provisioned | ForEach-Object { [string]$_.DisplayName })) {
    if (-not [string]::IsNullOrWhiteSpace($name) -and $seen.Add($name)) { $names.Add($name) }
  }

  $selected = @(Select-BloatwareToRemove -PackageNames $names.ToArray() -RemovePatterns @($bloatware.remove) -ProtectPatterns @($bloatware.protect))
  $failed = 0
  foreach ($name in $selected) {
    $packageNames = @($provisioned | Where-Object { [string]$_.DisplayName -eq $name } | ForEach-Object { [string]$_.PackageName })
    if (-not (Remove-BloatwarePackage -Name $name -ProvisionedPackageNames $packageNames)) { $failed++ }
  }

  $removed = $selected.Count - $failed
  if ($failed -gt 0) { $notes.Add("Bloatware: $failed packages could not be removed") }
  Write-SetupLog -Message 'Bloatware removal finished' -Data @{ selected = $selected.Count; removed = $removed; failed = $failed }
  return New-StepResult -Status Done -Message "Removed $removed packages" -Notes $notes.ToArray()
}
