# tests/fixtures/RepairSamples.ps1
# Repair Task 3: the sample states the repair page tests share (RepairPlanner.Tests, RepairPage.Tests). Dot-sourced in
# a BeforeAll after src\Toolbox\RepairPlanner.ps1 and SetupPlanner.ps1; reads $script:cfg and $script:m (the Dell
# sample machine of tools\Preview-Toolbox.ps1). Plain data and a model builder: nothing here runs or reads anything.

# Standard repair at DISM 45%: time sync and disk scan done, SFC and WinRE pending, 12:34 elapsed, six log lines.
$script:runSample = @{
  Action = 'standard'; Current = 2; Percent = 45; ElapsedSeconds = 754; Stopping = $false
  Steps  = @(
    @{ Id = 'timeSync'; Status = 'done'; Percent = $null }
    @{ Id = 'volumeScan'; Status = 'done'; Percent = $null }
    @{ Id = 'dism'; Status = 'running'; Percent = 45 }
    @{ Id = 'sfc'; Status = 'pending'; Percent = $null }
    @{ Id = 'winreFix'; Status = 'pending'; Percent = $null }
  )
  Log    = @('Time sync: w32tm exit 0', 'Clock offset after the sync: 0.4 s', 'Disk scan: ScanNoErrorsFound', 'No servicing restart pending',
             'DISM /RestoreHealth started (limit 150 min)', 'DISM output: logs\dism-1027.txt')
}

# A finished result with one finding of each level, in the child's order: CRIT volumeSpotFix, WARN sfcCorrupt (3),
# INFO activationUnknown.
$script:resultSample = @{
  Action = 'standard'; RunId = '20261022-101500-standard'; Outcome = 'Done'; Color = 'YELLOW'
  Steps = @(foreach ($id in 'timeSync', 'volumeScan', 'dism', 'sfc', 'winreFix') { @{ Id = $id; Status = 'done'; Percent = $null } })
  Findings = @(
    @{ Level = 'CRIT'; Code = 'volumeSpotFix'; Text = 'Disk scan found errors that need a disk check at restart'; Args = @() }
    @{ Level = 'WARN'; Code = 'sfcCorrupt'; Text = 'System files: 3 integrity problems found (nothing repaired yet)'; Args = @('3') }
    @{ Level = 'INFO'; Code = 'activationUnknown'; Text = 'Activation could not be read'; Args = @() }
  )
  RestartRequired = $true
  Offers = @{ DiskCheck = $true; DismSource = $null }
  Files = @{ Folder = 'E:\BenTech-Reports\DESKTOP-4F7K2LQ_7HX2K93_2026-10-22_1015' }
}

# Network reset's confirmation: its change list and one static adapter (confirm.static: a left-to-right value line).
# Confirm.Lines entries are @{ Key; Args } or @{ Ltr } (RepairPage.ps1, review M2).
$script:confirmSample = @{
  Action = 'netReset'; Kind = 'yes'; Typed = ''; AtPc = $false; Loading = $false
  Lines = @(@{ Key = 'tile.netReset.changes' }, @{ Key = 'confirm.static'; Args = @('Ethernet', '192.168.1.10/24, gateway 192.168.1.1, DNS 8.8.8.8') })
  Remote = @{ Rdp = $false }; Items = @(); Options = @{}
}

# The toolbox model for the Dell sample on the repair page: a ready all-ok strip, stick E:, every tile available, the
# setup files present (CanRun), on AC, English; then each $Set key applied:
#   Restart, Free, BitLocker, Internet, Disk = a level ('ok'|'warn'|'crit'|'unknown'), or $null for a chip not read
#   yet; State = the strip's state;
#   OnAC, Language = the toolbox model's own; Stick = $null for no stick; Running = $true for an action running
#   ($script:runSample); any other key (IsLaptop, BackedUp, Available, Selected, Run, Result, Confirm, NetBackup,
#   HasEarlierReport, CanRun) = Model.Repair.<key>.
function New-TestModel([hashtable]$Set = @{}) {
  $model = New-ToolboxModel -Machine $script:m -Config $script:cfg -Previous $null -IsFresh $false -OnAC $true -AdminProtection 'Off'
  $model.Page = 'repair'
  $r = $model.Repair
  $r.CanRun = $true
  $r.Available = [string[]](@($script:RepairTileRows.Values | ForEach-Object { $_ }) + @('netRestore', 'dismSource'))
  $r.Stick = @{ Root = 'E:\'; Drive = 'E:' }
  $r.Strip = ConvertTo-RepairStrip -Final $true -Chips @{
    Restart = @{ Level = 'ok' }; Free = @{ Level = 'ok'; Args = @('C:', '41') }; BitLocker = @{ Level = 'ok' }; Internet = @{ Level = 'ok' }; Disk = @{ Level = 'ok' } }
  foreach ($key in $Set.Keys) {
    $value = $Set[$key]
    if ($key -in 'Restart', 'Free', 'BitLocker', 'Internet', 'Disk') {
      $chipArgs = if ($key -eq 'Free') { @('C:', $(if ($value -eq 'crit') { '4' } else { '41' })) } else { @() }
      $r.Strip[$key] = $(if ($null -eq $value) { $null } else { @{ Level = $value; Args = $chipArgs; Detail = @{} } })
    } elseif ($key -eq 'State') { $r.Strip.State = $value }
    elseif ($key -in 'OnAC', 'Language') { $model[$key] = $value }
    elseif ($key -eq 'Stick') { $r.Stick = $(if ($null -eq $value) { @{ Root = $null; Drive = $null } } else { $value }) }
    elseif ($key -eq 'Running') { if ($value) { $r.Run = $script:runSample } }
    else { $r[$key] = $value }
  }
  return $model
}
