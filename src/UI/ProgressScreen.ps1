# src/UI/ProgressScreen.ps1
# The progress screen (spec 8.2): a live checklist of the planned steps, redrawn after every step
# transition and immediately on a resume after a reboot.
#
# Format-ProgressScreen is pure. Show-ProgressScreen takes the clock and the writer as injectable
# script blocks. The markers are plain ASCII because conhost cannot reliably show check marks and
# arrows. Uses ConvertTo-ScreenText, Limit-ScreenLine, ConvertFrom-StateTime and Format-HoursMinutes
# from StartScreen.ps1.

function Format-ProgressScreen {
  <#
  .SYNOPSIS
    The progress screen as lines of text. Pure: no console access.
  .DESCRIPTION
    One line per step in State.Plan, in plan order, titled from -Catalog (the id when the catalog does
    not know it):
      [OK] Title                 Done
      [>>] Title  (mm:ss)        running; time since the step's StartedAt
      [..] Title                 pending, or no state entry yet
      [X ] Title - Message       Failed
      [--] Title - Message       Skipped
    followed by the reboot count and the total time since State.StartedAt.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][object[]]$Catalog,
    [Parameter(Mandatory)][datetime]$Now
  )

  $titles = @{}
  foreach ($entry in $Catalog) { $titles[[string]$entry.Id] = [string]$entry.Title }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('  BENTECH WINDOWS SETUP - working, do not turn off')
  $lines.Add('')

  foreach ($id in @($State['Plan'])) {
    if ([string]::IsNullOrEmpty($id)) { continue }
    $title = ConvertTo-ScreenText $(if ($titles.ContainsKey([string]$id)) { $titles[[string]$id] } else { $id })
    $step = $null
    if ($null -ne $State['Steps']) { $step = $State['Steps'][$id] }
    $status = if ($null -ne $step) { [string]$step['Status'] } else { '' }
    $reason = if ($null -ne $step) { ConvertTo-ScreenText $step['Message'] } else { '' }

    switch ($status) {
      'Done' { $lines.Add("  [OK] $title") }
      'running' {
        $started = ConvertFrom-StateTime $step['StartedAt']
        $elapsed = if ($null -ne $started -and $Now -gt $started) { $Now - $started } else { [timespan]::Zero }
        $lines.Add(('  [>>] {0}  ({1:00}:{2:00})' -f $title, [int][math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds))
      }
      'Failed'  { $lines.Add((Limit-ScreenLine $(if ($reason) { "  [X ] $title - $reason" } else { "  [X ] $title" }))) }
      'Skipped' { $lines.Add((Limit-ScreenLine $(if ($reason) { "  [--] $title - $reason" } else { "  [--] $title" }))) }
      default   { $lines.Add("  [..] $title") }
    }
  }

  $total = [timespan]::Zero
  $runStarted = ConvertFrom-StateTime $State['StartedAt']
  if ($null -ne $runStarted) { $total = $Now - $runStarted }
  $lines.Add('')
  $lines.Add(('  Reboots: {0}    Total: {1}' -f [int]$State['RebootCount'], (Format-HoursMinutes $total)))

  return $lines.ToArray()
}

function Show-ProgressScreen {
  <#
  .SYNOPSIS
    Clears the console and draws the progress screen.
  .DESCRIPTION
    -Catalog defaults to the step catalog. The seams (production defaults shown): -Now is the clock,
    -Write draws the lines.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [object[]]$Catalog = $script:StepCatalog,
    [scriptblock]$Now = { Get-Date },
    [scriptblock]$Write = { param($lines) Clear-Host; $lines | ForEach-Object { Write-Host $_ -ForegroundColor Gray -BackgroundColor Black } }
  )

  $lines = @(Format-ProgressScreen -State $State -Catalog $Catalog -Now ([datetime](& $Now)))
  $null = & $Write $lines
}
