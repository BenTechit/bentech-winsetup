# src/Entry/Cleanup.ps1
# v2 spec 10: no leftover folder. When the technician finishes the final screen with Enter (or presses Esc on
# the start screen of a fresh machine), the logs are copied to the USB stick, the launcher copy on the Desktop
# is deleted, and C:\BenTech is removed. A crash leaves everything in place for diagnosis.
#
# Finding the stick: a new run records the launcher's path ($env:BT_SELF, set by the launcher) and that
# drive's volume serial number in the state (Get-LauncherInfo). At the end the stick is the drive with that
# serial, else any other drive holding BenTechSetup.cmd in its root (Find-SetupStick). The system drive is
# never the stick: a launcher run from the Desktop recorded the system drive's serial.
#
# Deleting C:\BenTech: only Remove-SetupFolder does it, with `cmd.exe /d /c rd /s /q` through Invoke-External.
# rd removes a junction without following it; Remove-Item -Recurse on Windows PowerShell 5.1 would follow it
# and delete whatever it points to. It refuses any path whose leaf is not BenTech, a drive root, and a
# reparse point. Needs Logging.ps1, Activity.ps1 (Wait-SetupDelay) and Process.ps1 (Invoke-External).
#
# None of these functions throws.

$script:SetupStickQueryWarned = $false

function Get-LauncherInfo {
  <#
  .SYNOPSIS
    @{ Path; Drive; VolumeSerial } of the launcher at -Path, or $null for an empty path. Never throws.
  .DESCRIPTION
    Drive is the path's drive letter ('E:'), $null for a UNC path. VolumeSerial is that drive's
    Win32_LogicalDisk VolumeSerialNumber (a 10-second CIM query), $null when it is unknown.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()][AllowEmptyString()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $info = @{ Path = $Path; Drive = $null; VolumeSerial = $null }
  if ($Path -notmatch '^([A-Za-z]):') { return $info }
  $info.Drive = $Matches[1].ToUpperInvariant() + ':'
  try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $info.Drive) -OperationTimeoutSec 10 -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $disk -and -not [string]::IsNullOrWhiteSpace([string]$disk.VolumeSerialNumber)) { $info.VolumeSerial = [string]$disk.VolumeSerialNumber }
  } catch {
    Write-SetupLog -Level WARN -Message 'Could not read the volume serial of the launcher drive' -Data @{ drive = $info.Drive; error = $_.Exception.Message }
  }
  return $info
}

function Find-SetupStick {
  <#
  .SYNOPSIS
    The BenTech USB stick: @{ Root = 'E:\'; Drive = 'E:' }, or @{ Root = $null; Drive = $null }. Never throws.
  .DESCRIPTION
    One Win32_LogicalDisk read. The disk whose VolumeSerialNumber equals Launcher.VolumeSerial
    (case-insensitive) wins, so the stick is found under another letter too. Otherwise the first disk with
    <DeviceID>\BenTechSetup.cmd. The system drive (-SystemDrive) is never the stick, by serial or by file:
    a launcher started from the Desktop recorded the system drive. Network drives are never looked at (a
    share that does not answer would hold up the final screen, which calls this every second). A failed
    query is no stick, logged once per process (not once a second).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()][hashtable]$Launcher,
    [string]$SystemDrive = $env:SystemDrive
  )

  $none = @{ Root = $null; Drive = $null }
  $system = ([string]$SystemDrive).TrimEnd('\')
  try {
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -OperationTimeoutSec 10 -ErrorAction Stop | Where-Object {
      $id = [string]$_.DeviceID
      $id -ne '' -and $id -ne $system -and [int]$_.DriveType -ne 4
    })
    $serial = if ($null -ne $Launcher) { [string]$Launcher['VolumeSerial'] } else { '' }
    if ($serial -ne '') {
      foreach ($disk in $disks) {
        if ([string]::Equals([string]$disk.VolumeSerialNumber, $serial, [StringComparison]::OrdinalIgnoreCase)) {
          $id = ([string]$disk.DeviceID).ToUpperInvariant()
          return @{ Root = $id + '\'; Drive = $id }
        }
      }
    }
    foreach ($disk in $disks) {
      $id = ([string]$disk.DeviceID).ToUpperInvariant()
      if (Test-Path -LiteralPath ($id + '\BenTechSetup.cmd') -PathType Leaf) { return @{ Root = $id + '\'; Drive = $id } }
    }
  } catch {
    if (-not $script:SetupStickQueryWarned) {
      $script:SetupStickQueryWarned = $true
      Write-SetupLog -Level WARN -Message 'Could not look for the USB stick' -Data @{ error = $_.Exception.Message }
    }
  }
  return $none
}

function Format-StickLine {
  # Pure. The final screen's live stick line.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][hashtable]$Stick)

  if ($null -ne $Stick -and -not [string]::IsNullOrEmpty([string]$Stick['Root'])) {
    return ('  USB stick found ({0}) - logs will be saved there' -f [string]$Stick['Drive'])
  }
  return '  No BenTech USB stick - plug it in now to keep the logs'
}

function Get-StickLogTarget {
  # Pure. <StickRoot>BenTech-Logs\<PC name>: invalid file-name characters become '_', and leading or
  # trailing dots and spaces are dropped, so the name is always a real child folder (never '..', which
  # would make the target the stick's root). An empty name is UNKNOWN-PC.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$StickRoot,
    [AllowNull()][AllowEmptyString()][string]$PcName
  )

  $name = [string]$PcName
  foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$c, '_') }
  $name = $name.Trim(' ', '.')
  if ($name -eq '') { $name = 'UNKNOWN-PC' }
  return [IO.Path]::Combine($StickRoot, 'BenTech-Logs', $name)
}

function Copy-SetupLogsToStick {
  <#
  .SYNOPSIS
    Copies -LogDir to <StickRoot>BenTech-Logs\<PcName>, replacing what is there. Returns
    @{ Ok; Target; Error }. Never throws.
  .DESCRIPTION
    An existing target is removed first (Remove-Item -Recurse: FAT/exFAT holds no junctions), so a re-run of
    the same PC replaces its logs; then the folder is copied. A failure is Ok = $false with the message.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$LogDir,
    [Parameter(Mandatory)][string]$StickRoot,
    [AllowNull()][AllowEmptyString()][string]$PcName
  )

  $target = Get-StickLogTarget -StickRoot $StickRoot -PcName $PcName
  try {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    Copy-Item -LiteralPath $LogDir -Destination $target -Recurse -Force -ErrorAction Stop
    return @{ Ok = $true; Target = $target; Error = $null }
  } catch {
    return @{ Ok = $false; Target = $target; Error = $_.Exception.Message }
  }
}

function Test-DesktopLauncher {
  <#
  .SYNOPSIS
    $true when the launcher at -Path sits directly on the user's or the public Desktop. Never throws.
  .DESCRIPTION
    Compares the launcher's folder (full path, case-insensitive, a trailing '\' ignored) with
    -UserDesktop and -PublicDesktop, which default to [Environment]::GetFolderPath('Desktop') and
    ('CommonDesktopDirectory'). A launcher in a subfolder, on a stick or anywhere else is $false.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Path,
    [AllowNull()][AllowEmptyString()][string]$UserDesktop,
    [AllowNull()][AllowEmptyString()][string]$PublicDesktop
  )

  if (-not $PSBoundParameters.ContainsKey('UserDesktop')) { $UserDesktop = [Environment]::GetFolderPath('Desktop') }
  if (-not $PSBoundParameters.ContainsKey('PublicDesktop')) { $PublicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory') }
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  try {
    $folder = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if ([string]::IsNullOrEmpty($folder)) { return $false }
    $folder = $folder.TrimEnd('\')
    foreach ($desktop in @($UserDesktop, $PublicDesktop)) {
      if ([string]::IsNullOrWhiteSpace($desktop)) { continue }
      $full = [IO.Path]::GetFullPath($desktop).TrimEnd('\')
      if ([string]::Equals($folder, $full, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
  } catch {
    Write-SetupLog -Level WARN -Message 'Could not tell whether the launcher is on the Desktop' -Data @{ path = $Path; error = $_.Exception.Message }
  }
  return $false
}

function Remove-SetupFolder {
  <#
  .SYNOPSIS
    Deletes the BenTech folder at -Path with `rd /s /q`. $true when it no longer exists. Never throws.
  .DESCRIPTION
    Refuses (ERROR log, $false, nothing run) unless [IO.Path]::GetFullPath(-Path) is a folder whose leaf is
    BenTech, is not a drive root and is not a reparse point (a junction named BenTech would point the
    deletion somewhere else). A path that does not exist (already gone) is $true.
    Then `cmd.exe /d /c rd /s /q "<full>"` through Invoke-External (5-minute timeout), up to 1 + -Retries
    tries, Wait-SetupDelay -RetrySeconds between them. rd's exit code is not trusted: success is the folder
    being gone afterwards.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Path,
    [int]$Retries = 3,
    [int]$RetrySeconds = 2
  )

  $refuse = {
    param($reason, $detail)
    Write-SetupLog -Level ERROR -Message 'Refusing to delete the setup folder' -Data @{ path = $Path; reason = $reason; error = $detail }
  }

  try {
    $full = [IO.Path]::GetFullPath($Path)
  } catch {
    & $refuse 'the path cannot be resolved' $_.Exception.Message
    return $false
  }
  $root = [IO.Path]::GetPathRoot($full)
  $trimmed = $full.TrimEnd('\', '/')
  if ([string]::IsNullOrEmpty($root) -or $trimmed.Length -le $root.TrimEnd('\', '/').Length) {
    & $refuse 'it is a drive root' $null
    return $false
  }
  $full = $trimmed
  if (-not [string]::Equals([IO.Path]::GetFileName($full), 'BenTech', [StringComparison]::OrdinalIgnoreCase)) {
    & $refuse 'its name is not BenTech' $null
    return $false
  }

  try {
    if (-not [IO.Directory]::Exists($full)) {
      if ([IO.File]::Exists($full)) {
        & $refuse 'it is a file' $null
        return $false
      }
      Write-SetupLog -Message 'The setup folder is already gone' -Data @{ path = $full }
      return $true
    }
    if (([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      & $refuse 'it is a reparse point (junction or link)' $null
      return $false
    }
  } catch {
    & $refuse 'its attributes cannot be read' $_.Exception.Message
    return $false
  }

  $tries = 1 + [math]::Max(0, $Retries)
  for ($try = 1; $try -le $tries; $try++) {
    try {
      $null = Invoke-External -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/d /c rd /s /q "{0}"' -f $full) -TimeoutMinutes 5 -WorkingDirectory $env:SystemRoot
    } catch {
      Write-SetupLog -Level WARN -Message 'rd could not run' -Data @{ path = $full; try = $try; error = $_.Exception.Message }
    }
    if (-not [IO.Directory]::Exists($full)) {
      Write-SetupLog -Message 'Setup folder deleted' -Data @{ path = $full; tries = $try }
      return $true
    }
    if ($try -lt $tries) { Wait-SetupDelay -Seconds $RetrySeconds }
  }
  Write-SetupLog -Level ERROR -Message 'Could not delete the setup folder' -Data @{ path = $full; tries = $tries }
  return $false
}

function Invoke-SetupCleanup {
  <#
  .SYNOPSIS
    Leaves no folder behind (spec 10). Runs after Start-BenTechSetup has stopped the transcript and released
    the run lock and mutex. Never throws.
  .DESCRIPTION
    1. Logs 'Cleanup: ...', then stops logging (setup.log and activity.txt are about to be copied and
       deleted).
    2. Finish only: the logs go to the stick (Find-SetupStick, Copy-SetupLogsToStick with the new PC name,
       else the computer name). A failed copy is shown and waits for Enter (other keys are ignored), so the
       technician can still save the logs by hand. No stick: one line, no wait.
    3. Finish only: a launcher that ran from the Desktop (Test-DesktopLauncher) is deleted. A launcher
       anywhere else is never touched.
    4. The process (PowerShell and .NET) moves out of the folder, to %SystemRoot%.
    5. Remove-SetupFolder on the parent of -Root (C:\BenTech). A failure is shown and waits for any key.
    6. -ProgramDataFolder is removed when it exists and is empty.
    Cancel (Esc on the start screen, no earlier run) runs 1 and 4-6 only.

    The seams (production defaults shown): -ReadKey waits for a key and returns its [ConsoleKey] name;
    -Write writes one line of text.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][ValidateSet('Finish', 'Cancel')][string]$Mode,
    [AllowNull()][hashtable]$State,
    [scriptblock]$ReadKey = { [Console]::ReadKey($true).Key.ToString() },
    [scriptblock]$Write = { param($t) Write-Host $t -ForegroundColor White -BackgroundColor Black },
    [string]$ProgramDataFolder = (Join-Path $env:ProgramData 'BenTech')
  )

  $say = {
    param($text)
    try { $null = & $Write $text } catch { }
  }
  # Waits for Enter (-EnterOnly) or any key. A key read that fails (no console) ends the wait: nothing may
  # hold the machine forever, and the folder is still deleted.
  $waitKey = {
    param([bool]$EnterOnly)
    while ($true) {
      try { $key = [string](& $ReadKey) } catch { return }
      if (-not $EnterOnly -or $key -eq 'Enter') { return }
    }
  }

  $folder = Split-Path -Parent $Root
  Write-SetupLog -Message 'Cleanup: saving the logs and removing C:\BenTech' -Data @{ mode = $Mode; folder = $folder }
  $script:SetupLogPath = $null
  $script:SetupActivityPath = $null

  $launcher = $null
  if ($null -ne $State -and $State['Launcher'] -is [hashtable]) { $launcher = $State['Launcher'] }

  if ($Mode -eq 'Finish') {
    try {
      $stick = Find-SetupStick -Launcher $launcher
      if (-not [string]::IsNullOrEmpty([string]$stick['Root'])) {
        $machine = if ($null -ne $State -and $State['Machine'] -is [hashtable]) { $State['Machine'] } else { @{} }
        $pcName = [string]$machine['NewName']
        if ([string]::IsNullOrWhiteSpace($pcName)) { $pcName = [string]$machine['ComputerName'] }
        if ([string]::IsNullOrWhiteSpace($pcName)) { $pcName = [string]$env:COMPUTERNAME }
        & $say ('Saving the logs to {0} ...' -f (Get-StickLogTarget -StickRoot ([string]$stick['Root']) -PcName $pcName))
        $copy = Copy-SetupLogsToStick -LogDir (Join-Path $Root 'Logs') -StickRoot ([string]$stick['Root']) -PcName $pcName
        if (-not $copy['Ok']) {
          & $say ('Logs could not be saved to the USB stick: {0}' -f $copy['Error'])
          & $say ('Press ENTER to delete {0} anyway' -f $folder)
          & $waitKey $true
        }
      } else {
        & $say 'No USB stick found: the logs are not saved'
      }
    } catch {
      & $say ('Logs could not be saved to the USB stick: {0}' -f $_.Exception.Message)
    }

    $launcherPath = if ($null -ne $launcher) { [string]$launcher['Path'] } else { '' }
    if ($launcherPath -ne '' -and (Test-DesktopLauncher -Path $launcherPath)) {
      try {
        Remove-Item -LiteralPath $launcherPath -Force -ErrorAction Stop
      } catch {
        & $say ('Could not delete the launcher on the Desktop: {0}' -f $_.Exception.Message)
      }
    }
  }

  # rd cannot remove a folder that is some process's current directory, this one's included.
  try { Set-Location -LiteralPath $env:SystemRoot -ErrorAction Stop } catch { }
  try { [Environment]::CurrentDirectory = $env:SystemRoot } catch { }

  if (-not (Remove-SetupFolder -Path $folder)) {
    & $say ('Could not delete {0} - delete it by hand' -f $folder)
    & $waitKey $false
  }

  try {
    if ([IO.Directory]::Exists($ProgramDataFolder) -and @([IO.Directory]::GetFileSystemEntries($ProgramDataFolder)).Count -eq 0) {
      [IO.Directory]::Delete($ProgramDataFolder, $false)
    }
  } catch {
    & $say ('Could not delete {0}: {1}' -f $ProgramDataFolder, $_.Exception.Message)
  }
}
