# src/Engine/Verdict.ps1
# Turns a finished run's State into the GREEN / YELLOW / RED result shown on the final screen and in
# the report. Needs $script:StepCatalog from Catalog.ps1 (loaded before this file) for step titles.

function Get-StepTitle {
  # The catalog title for a step id; the id itself if the catalog does not know it.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Id)

  foreach ($step in $script:StepCatalog) {
    if ($step.Id -eq $Id) { return [string]$step.Title }
  }
  return $Id
}

function Get-RunVerdict {
  <#
  .SYNOPSIS
    Computes the run's colour, banner, failure list and note list from State.
  .DESCRIPTION
    Walks State.Plan in order. Failed steps are failures, Skipped steps are notes, both formatted as
    "<Title>: <Message>". A step that is still pending or running (or has no state entry at all)
    when the verdict is taken never finished, so it is a failure ("<Title>: did not finish"): the
    final screen must never be green when steps never ran. Done steps are fine.
    RED if any failure, otherwise YELLOW if any note, otherwise GREEN.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$State)

  $failures = New-Object System.Collections.Generic.List[string]
  $notes = New-Object System.Collections.Generic.List[string]

  foreach ($id in @($State['Plan'])) {
    if ([string]::IsNullOrEmpty($id)) { continue }
    $title = Get-StepTitle -Id $id
    $step = $null
    if ($null -ne $State['Steps']) { $step = $State['Steps'][$id] }
    $status = if ($null -ne $step) { [string]$step['Status'] } else { '' }
    $message = if ($null -ne $step) { [string]$step['Message'] } else { '' }

    switch ($status) {
      'Done'    { }
      'Skipped' { $notes.Add(('{0}: {1}' -f $title, $message)) }
      'Failed'  { $failures.Add(('{0}: {1}' -f $title, $message)) }
      default   { $failures.Add(('{0}: did not finish' -f $title)) }   # pending, running, missing, unknown
    }
  }

  if ($State['RebootCapHit'] -eq $true) { $failures.Add('Reboot limit reached') }
  foreach ($updateId in @($State['HiddenUpdateIds'])) {
    if (-not [string]::IsNullOrEmpty($updateId)) {
      $failures.Add(('Windows update hidden after repeated failures: {0}' -f $updateId))
    }
  }
  foreach ($e in @($State['Errors'])) { if (-not [string]::IsNullOrEmpty($e)) { $failures.Add([string]$e) } }
  foreach ($n in @($State['Notes']))  { if (-not [string]::IsNullOrEmpty($n)) { $notes.Add([string]$n) } }

  if ($failures.Count -gt 0) { $color = 'RED';    $banner = 'COMPLETED WITH ERRORS' }
  elseif ($notes.Count -gt 0) { $color = 'YELLOW'; $banner = 'COMPLETE - CHECK NOTES' }
  else { $color = 'GREEN'; $banner = 'SETUP COMPLETE' }

  @{
    Color    = $color
    Banner   = $banner
    Failures = [string[]]$failures.ToArray()
    Notes    = [string[]]$notes.ToArray()
  }
}
