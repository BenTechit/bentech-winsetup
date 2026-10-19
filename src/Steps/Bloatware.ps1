# src/Steps/Bloatware.ps1
# Step 4, "Remove bloatware" (spec 8.3 and section 10): a conservative removal of pre-installed junk.
# Needs StepResult.ps1, Logging.ps1, Process.ps1 and Winget.ps1 (Invoke-PowerShellChild,
# ConvertTo-PowerShellLiteral, Get-OutputTail). The patterns are data: Config.bloatware.remove and
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

# One line per provisioned app, "<DisplayName>|<PackageName>": ASCII package identifiers, nothing localized.
$script:ProvisionedListCommand = 'Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName + ''|'' + $_.PackageName }'

# Used when Config.timeoutsMinutes.default is missing or not a positive number.
$script:BloatwareFallbackTimeoutMinutes = 30

function Invoke-BloatwareChild {
  # Private. Runs one Appx/DISM command line in a child Windows PowerShell with a time limit
  # (Invoke-PowerShellChild: -EncodedCommand, the whole process tree is killed on timeout). The Appx
  # and DISM cmdlets have no timeout of their own and the runner has none per step, so a wedged
  # AppX or DISM queue would otherwise freeze the unattended run for good.
  # Returns @{ Ok; TimedOut; Output }. Ok is $true only for exit code 0 without a timeout. A failure,
  # a timeout or a child that cannot be started is a WARN in the log and never throws.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$What,
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][double]$TimeoutMinutes
  )

  try {
    $run = Invoke-PowerShellChild -Command $Command -TimeoutMinutes $TimeoutMinutes
  } catch {
    Write-SetupLog -Message "$What failed: the child process could not be started" -Level WARN -Data @{ error = $_.Exception.Message }
    return @{ Ok = $false; TimedOut = $false; Output = '' }
  }
  if ($run.TimedOut) {
    Write-SetupLog -Message "$What timed out" -Level WARN -Data @{ timeoutMinutes = $TimeoutMinutes }
    return @{ Ok = $false; TimedOut = $true; Output = [string]$run.Output }
  }
  if ($null -eq $run.ExitCode -or $run.ExitCode -ne 0) {
    Write-SetupLog -Message "$What failed" -Level WARN -Data @{ exitCode = $run.ExitCode; tail = (Get-OutputTail -Output $run.Output) }
    return @{ Ok = $false; TimedOut = $false; Output = [string]$run.Output }
  }
  return @{ Ok = $true; TimedOut = $false; Output = [string]$run.Output }
}

function ConvertFrom-ProvisionedListOutput {
  # Private. Parses the "<DisplayName>|<PackageName>" lines of $script:ProvisionedListCommand into
  # objects with DisplayName and PackageName. Only plain package identifiers (letters, digits, '.', '_',
  # '-', and '~' in the package name) are accepted, so noise in the output (progress, error text) can
  # never become a removal target. Wrap the call in @().
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyString()][string]$Output)

  foreach ($line in @([string]$Output -split "`r`n|`r|`n")) {
    $m = [regex]::Match($line.Trim(), '^(?<display>[\w.\-]+)\|(?<package>[\w.\-~]+)$')
    if ($m.Success) {
      [pscustomobject]@{ DisplayName = $m.Groups['display'].Value; PackageName = $m.Groups['package'].Value }
    }
  }
}

function Remove-BloatwarePackage {
  # Private. Removes one app for the current user (a no-op when the user does not have it) and each of
  # its provisioned copies (the ones new accounts would get), each in its own time-limited child
  # process; the package names reach the child as quoted literals. Every failure is a WARN in the log.
  # Returns @{ Ok; TimedOut }: Ok is $true only when nothing failed. After a timeout the remaining
  # removals of this app are skipped (the queue is wedged) and TimedOut tells the caller to stop.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$ProvisionedPackageNames = @(),
    [Parameter(Mandatory)][double]$TimeoutMinutes
  )

  $ok = $true
  $timedOut = $false
  $userCommand = 'Get-AppxPackage -Name {0} -ErrorAction Stop | Remove-AppxPackage -ErrorAction Stop' -f (ConvertTo-PowerShellLiteral -Text $Name)
  $run = Invoke-BloatwareChild -What "Removing '$Name' for the current user" -Command $userCommand -TimeoutMinutes $TimeoutMinutes
  if ($run.Ok) {
    Write-SetupLog -Message 'App removed for the current user (if installed)' -Data @{ name = $Name }
  } else {
    $ok = $false
    $timedOut = $run.TimedOut
  }

  foreach ($packageName in @($ProvisionedPackageNames | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
    if (-not $timedOut) {
      $command = 'Remove-AppxProvisionedPackage -Online -PackageName {0} -ErrorAction Stop | Out-Null' -f (ConvertTo-PowerShellLiteral -Text $packageName)
      $run = Invoke-BloatwareChild -What "Removing provisioned '$packageName'" -Command $command -TimeoutMinutes $TimeoutMinutes
      if ($run.Ok) {
        Write-SetupLog -Message 'Provisioned app removed' -Data @{ name = $Name; package = $packageName }
      } else {
        $ok = $false
        $timedOut = $run.TimedOut
      }
    }
  }
  return @{ Ok = $ok; TimedOut = $timedOut }
}

function Invoke-StepBloatware {
  <#
  .SYNOPSIS
    Step 4: removes the apps in Config.bloatware.remove (minus Config.bloatware.protect). Always Done.
  .DESCRIPTION
    Names come from Get-AppxPackage (current user, .Name; a fast read, done in-process) and from the
    provisioned list (DisplayName), de-duplicated. The provisioned list and every removal run in a
    child Windows PowerShell limited to Config.timeoutsMinutes.default (see Invoke-BloatwareChild):
    the current user's copy with Remove-AppxPackage, each provisioned copy with
    Remove-AppxProvisionedPackage -Online. Only names that Select-BloatwareToRemove passed ever reach a
    removal command.

    A package counts as failed if either removal failed, timed out or could not be started (a WARN is
    logged for each). After the first TIMEOUT the remaining packages are not tried (a wedged AppX or
    DISM queue would cost the full timeout for each one) and count as failed. The result is
    Done('Removed <N> packages'), with the Note 'Bloatware: <M> packages could not be removed' when
    M > 0. A list that cannot be read is a Note too: it only means less is removed.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $notes = New-Object 'System.Collections.Generic.List[string]'
  $bloatware = $Context.Config.bloatware
  $timeout = [double]$script:BloatwareFallbackTimeoutMinutes
  if ($null -ne $Context.Config.timeoutsMinutes -and [double]$Context.Config.timeoutsMinutes.default -gt 0) {
    $timeout = [double]$Context.Config.timeoutsMinutes.default
  }

  $installed = @()
  try {
    $installed = @(Get-AppxPackage -ErrorAction Stop | ForEach-Object { [string]$_.Name })
  } catch {
    Write-SetupLog -Message 'Installed apps could not be listed' -Level WARN -Data @{ error = $_.Exception.Message }
    $notes.Add('Bloatware: installed apps could not be listed')
  }

  $provisioned = @()
  $listing = Invoke-BloatwareChild -What 'Listing provisioned apps' -Command $script:ProvisionedListCommand -TimeoutMinutes $timeout
  if ($listing.Ok) {
    $provisioned = @(ConvertFrom-ProvisionedListOutput -Output $listing.Output)
  } else {
    $notes.Add('Bloatware: provisioned apps could not be listed')
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $names = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in @($installed) + @($provisioned | ForEach-Object { [string]$_.DisplayName })) {
    if (-not [string]::IsNullOrWhiteSpace($name) -and $seen.Add($name)) { $names.Add($name) }
  }

  $selected = @(Select-BloatwareToRemove -PackageNames $names.ToArray() -RemovePatterns @($bloatware.remove) -ProtectPatterns @($bloatware.protect))
  $failed = 0
  $skipped = 0
  $stopped = $false
  foreach ($name in $selected) {
    if ($stopped) {
      $failed++
      $skipped++
    } else {
      $packageNames = @($provisioned | Where-Object { [string]$_.DisplayName -eq $name } | ForEach-Object { [string]$_.PackageName })
      $result = Remove-BloatwarePackage -Name $name -ProvisionedPackageNames $packageNames -TimeoutMinutes $timeout
      if (-not $result.Ok) { $failed++ }
      if ($result.TimedOut) {
        $stopped = $true
        Write-SetupLog -Message 'An app removal timed out; the remaining packages are not tried' -Level WARN -Data @{ name = $name }
        $notes.Add('Bloatware: removal stopped after a timeout')
      }
    }
  }

  $removed = $selected.Count - $failed
  if ($failed -gt 0) { $notes.Add("Bloatware: $failed packages could not be removed") }
  Write-SetupLog -Message 'Bloatware removal finished' -Data @{ selected = $selected.Count; removed = $removed; failed = $failed; skipped = $skipped }
  return New-StepResult -Status Done -Message "Removed $removed packages" -Notes $notes.ToArray()
}
