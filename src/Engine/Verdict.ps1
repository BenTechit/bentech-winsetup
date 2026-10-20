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
    Then 'Reboot limit reached', each update the run hid after repeated failures ("Windows update failed
    repeatedly (left to Windows Update): <title>", the title the Windows Update step recorded in
    Data.FailedTitles, else the id; M7; Finalize un-hides it again at the end, final review C1, and one
    that stays hidden is in State.Errors too), and State.Errors are failures; State.Notes are notes. A string already in its list is not added again
    (exact match; M1), so one root cause reported by two steps takes one line on the final screen.
    RED if any failure, otherwise YELLOW if any note, otherwise GREEN.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$State)

  $failures = New-Object System.Collections.Generic.List[string]
  $notes = New-Object System.Collections.Generic.List[string]
  # Exact (ordinal) duplicates are dropped as they arrive; the first occurrence keeps its place.
  $failureSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $noteSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $addFailure = { param([string]$Text) if ($failureSeen.Add($Text)) { $failures.Add($Text) } }
  $addNote = { param([string]$Text) if ($noteSeen.Add($Text)) { $notes.Add($Text) } }

  foreach ($id in @($State['Plan'])) {
    if ([string]::IsNullOrEmpty($id)) { continue }
    $title = Get-StepTitle -Id $id
    $step = $null
    if ($null -ne $State['Steps']) { $step = $State['Steps'][$id] }
    $status = if ($null -ne $step) { [string]$step['Status'] } else { '' }
    $message = if ($null -ne $step) { [string]$step['Message'] } else { '' }

    switch ($status) {
      'Done'    { }
      'Skipped' { & $addNote ('{0}: {1}' -f $title, $message) }
      'Failed'  { & $addFailure ('{0}: {1}' -f $title, $message) }
      default   { & $addFailure ('{0}: did not finish' -f $title) }   # pending, running, missing, unknown
    }
  }

  if ($State['RebootCapHit'] -eq $true) { & $addFailure 'Reboot limit reached' }

  # Updates the run hid, by title (as the report lists them), else by id. They are un-hidden at the end of
  # the run (final review C1), so the line says what is true afterwards.
  $titles = @{}
  $wuStep = if ($State['Steps'] -is [System.Collections.IDictionary]) { $State['Steps']['windows-update'] } else { $null }
  if ($wuStep -is [System.Collections.IDictionary] -and $wuStep['Data'] -is [System.Collections.IDictionary] -and
      $wuStep['Data']['FailedTitles'] -is [System.Collections.IDictionary]) {
    $titles = $wuStep['Data']['FailedTitles']
  }
  foreach ($updateId in @($State['HiddenUpdateIds'])) {
    $key = [string]$updateId
    if ([string]::IsNullOrEmpty($key)) { continue }
    $title = if ($titles.Contains($key)) { [string]$titles[$key] } else { '' }
    $name = if ([string]::IsNullOrWhiteSpace($title)) { $key } else { $title }
    & $addFailure ('Windows update failed repeatedly (left to Windows Update): {0}' -f $name)
  }
  foreach ($e in @($State['Errors'])) { if (-not [string]::IsNullOrEmpty($e)) { & $addFailure ([string]$e) } }
  foreach ($n in @($State['Notes']))  { if (-not [string]::IsNullOrEmpty($n)) { & $addNote ([string]$n) } }

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
