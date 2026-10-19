# src/Steps/Rename.ps1
# Step 5, "Rename PC" (spec 8.3 and section 11). The target name is State.Machine.NewName (built once by
# New-PcName at the start of the run and kept in the state, so it does not change between resumes).
# Needs StepResult.ps1 and Logging.ps1.

function Get-PendingComputerName {
  <#
  .SYNOPSIS
    Returns the name the PC will have after the next restart.
  .DESCRIPTION
    Reads ComputerName\ComputerName, which Rename-Computer updates at once, unlike ActiveComputerName
    (the running name, changed only by a restart). Reading the pending name is what makes the step
    safe to repeat after the restart it asked for, or after a crash between rename and restart. If
    the value cannot be read, the running name ($env:COMPUTERNAME) is returned and a WARN is logged.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  try {
    return [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
  } catch {
    Write-SetupLog -Message 'Pending computer name could not be read; using the running name' -Level WARN -Data @{ error = $_.Exception.Message }
    return [string]$env:COMPUTERNAME
  }
}

function Invoke-StepRename {
  <#
  .SYNOPSIS
    Step 5: renames the PC to State.Machine.NewName. The new name applies after a restart.
  .DESCRIPTION
    No target name -> Skipped('No target name'). The pending name already equals the target (compared
    without regard to case) -> Done('Name already set'). Otherwise Rename-Computer -NewName <target> -Force ->
    Done('Renamed to <target> (applies after restart)'); an exception gives Failed('Rename failed: <message>').
    The step never restarts the PC itself: the pending rename is one of the signals the reboot logic
    looks for.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $target = [string]$Context.State.Machine.NewName
  if ([string]::IsNullOrWhiteSpace($target)) {
    return New-StepResult -Status Skipped -Message 'No target name'
  }

  if ((Get-PendingComputerName) -ieq $target) {
    return New-StepResult -Status Done -Message 'Name already set'
  }

  try {
    Rename-Computer -NewName $target -Force -ErrorAction Stop
  } catch {
    $reason = $_.Exception.Message
    Write-SetupLog -Message 'Rename failed' -Level ERROR -Data @{ target = $target; error = $reason }
    return New-StepResult -Status Failed -Message "Rename failed: $reason"
  }
  Write-SetupLog -Message 'Computer renamed' -Data @{ target = $target }
  return New-StepResult -Status Done -Message "Renamed to $target (applies after restart)"
}
