# src/Engine/Reboot.ps1
# Pending-reboot detection and the one controlled way this tool restarts the machine during a run
# (Invoke-ControlledReboot), plus the stateless restart of the toolbox's Restart PC (Invoke-StatelessRestart, repair
# spec 6.9: no run, so no state, no cap and no countdown).
#
# Detection reads only registry keys and values, never command output: target machines may run a
# Hebrew display language. Every read is guarded, so a missing key or value is simply "no signal".

function Test-RebootRegistryKey {
  # Private. $true when the registry key exists; $false when it is missing or cannot be read.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Path)

  try { return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop) }
  catch { return $false }
}

function Get-RebootRegistryValue {
  # Private. The value's data, or $null when the key or value is missing or cannot be read.
  # A REG_MULTI_SZ comes back as its strings (unrolled), so callers wrap the call in @().
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name
  )

  try {
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    if ($null -eq $item) { return $null }
    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
  } catch {
    return $null
  }
}

function Get-PendingRebootSignals {
  <#
  .SYNOPSIS
    Reads the four registry signals that say Windows wants a restart. Never throws.
  .DESCRIPTION
    CbsRebootPending      : the Component Based Servicing\RebootPending key exists.
    WuRebootRequired      : the WindowsUpdate\Auto Update\RebootRequired key exists.
    PendingFileRename     : Session Manager\PendingFileRenameOperations has at least one non-empty entry.
    ComputerRenamePending : ComputerName\ComputerName differs from ComputerName\ActiveComputerName
                            (compared case-insensitively; a missing value means no rename is pending).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
  $wuKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
  $nameRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'

  $renames = @(Get-RebootRegistryValue -Path $sessionManager -Name 'PendingFileRenameOperations' |
      Where-Object { -not [string]::IsNullOrEmpty([string]$_) })

  $pendingName = [string](Get-RebootRegistryValue -Path "$nameRoot\ComputerName" -Name 'ComputerName')
  $activeName = [string](Get-RebootRegistryValue -Path "$nameRoot\ActiveComputerName" -Name 'ComputerName')
  $renamePending = (-not [string]::IsNullOrEmpty($pendingName)) -and
    (-not [string]::IsNullOrEmpty($activeName)) -and
    ($pendingName -ne $activeName)   # -ne is case-insensitive, like Windows computer names

  @{
    CbsRebootPending      = Test-RebootRegistryKey -Path $cbsKey
    WuRebootRequired      = Test-RebootRegistryKey -Path $wuKey
    PendingFileRename     = ($renames.Count -gt 0)
    ComputerRenamePending = [bool]$renamePending
  }
}

function Test-PendingReboot {
  <#
  .SYNOPSIS
    $true when any signal from Get-PendingRebootSignals is $true.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$Signals)

  foreach ($value in $Signals.Values) {
    if ($value -eq $true) { return $true }
  }
  return $false
}

function Get-ServicingRebootSignals {
  <#
  .SYNOPSIS
    The pending-restart signals the repair page and the action child read (repair spec 5). Never throws.
  .DESCRIPTION
    @{ CbsRebootPending; CbsPackagesPending; PendingXml; WuRebootRequired; PendingFileRename; ComputerRenamePending },
    every value a bool:
      CbsPackagesPending : the Component Based Servicing\PackagesPending key exists.
      PendingXml         : %windir%\WinSxS\pending.xml exists.
      the other four     : as Get-PendingRebootSignals reads them.
    Only the first four break servicing (Test-ServicingRebootPending); a pending file or computer rename is set on
    most PCs and is a grey note only. A read that fails is "no signal", like Get-PendingRebootSignals.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $signals = @{
    CbsRebootPending      = $false
    CbsPackagesPending    = $false
    PendingXml            = $false
    WuRebootRequired      = $false
    PendingFileRename     = $false
    ComputerRenamePending = $false
  }
  try {
    $reboot = Get-PendingRebootSignals
    foreach ($name in 'CbsRebootPending', 'WuRebootRequired', 'PendingFileRename', 'ComputerRenamePending') {
      $signals[$name] = ($reboot[$name] -eq $true)
    }
  } catch {
    # ConvertTo-ScreenText (UI\StartScreen.ps1; the bundle holds every file): a Hebrew Windows can localize the message.
    Write-SetupLog -Level WARN -Message 'Could not read the pending-restart signals; treating them as none' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  $signals['CbsPackagesPending'] = Test-RebootRegistryKey -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
  try {
    $signals['PendingXml'] = [bool](Test-Path -LiteralPath (Join-Path $env:windir 'WinSxS\pending.xml') -PathType Leaf -ErrorAction Stop)
  } catch {
    $signals['PendingXml'] = $false
  }
  return $signals
}

function Test-ServicingRebootPending {
  <#
  .SYNOPSIS
    $true when a signal that breaks servicing is set: CbsRebootPending, CbsPackagesPending, PendingXml or
    WuRebootRequired (repair spec 5). A pending file or computer rename alone is $false.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$Signals)

  foreach ($name in 'CbsRebootPending', 'CbsPackagesPending', 'PendingXml', 'WuRebootRequired') {
    if ($Signals[$name] -eq $true) { return $true }
  }
  return $false
}

function Invoke-ShutdownRestart {
  <#
  .SYNOPSIS
    Private. The fallback restart of Invoke-ControlledReboot and Invoke-StatelessRestart: shutdown.exe /r /t 5 /f through
    Invoke-External, bounded at 1 minute (nothing waits without a deadline; final wave item 13: never Start-Process
    -Wait). Returns nothing; throws 'shutdown.exe exited with code <n>' unless the exit code is 0 (restart scheduled),
    1115 (ERROR_SHUTDOWN_IN_PROGRESS) or 1190 (ERROR_SHUTDOWN_IS_SCHEDULED): the machine restarts either way. A timeout
    (no exit code) throws too.
  #>
  [CmdletBinding()]
  param()

  $shutdown = Invoke-External -FilePath "$env:windir\System32\shutdown.exe" -ArgumentList '/r /t 5 /f' -TimeoutMinutes 1
  if ($null -eq $shutdown -or $shutdown['TimedOut'] -eq $true -or $null -eq $shutdown['ExitCode'] -or [int]$shutdown['ExitCode'] -notin 0, 1115, 1190) {
    $code = if ($null -ne $shutdown -and $null -ne $shutdown['ExitCode']) { [string]$shutdown['ExitCode'] } else { 'none (timed out)' }
    throw ('shutdown.exe exited with code {0}' -f $code)
  }
}

function Invoke-ControlledReboot {
  <#
  .SYNOPSIS
    Restarts the machine through the reboot cap. Returns $true when a restart was started.
  .DESCRIPTION
    No resume task (State.ResumeTaskMissing is $true, set by the Prepare step when it could not
    register the logon task): a restart would end the run for good, so nothing is restarted and
    RebootCount is left alone. 'Restart skipped: no resume task' is added to State.Errors (once),
    the state is saved, an ERROR is logged and $false is returned. RebootCapHit stays as it was,
    so the runner reports 'restart failed' and carries on.
    At or above Config.caps.maxReboots: sets State.RebootCapHit, saves, logs a WARN and returns
    $false without restarting. A refused restart never waits for Office.
    Otherwise it first waits for a background Microsoft 365 setup that is still running
    (Wait-OfficeBackground -Purpose Restart, up to Office's deadline; at the deadline Office is killed
    and its result recorded for office-finish). The restart is never refused because of Office.
    Then it increments State.RebootCount and saves before anything else, so a restart that happens
    sooner than expected still counts against the cap; then adds
    "Restarting (restart <RebootCount>)" to the activity feed, logs, shows "Restarting in N s ..."
    once per second (only when CountdownSeconds is above 0) and calls RestartAction.
    A restart must never fail silently (the machine would sit idle), so RestartAction must throw on
    failure (hence -ErrorAction Stop). When it throws, a WARN is logged and FallbackRestartAction
    (Invoke-ShutdownRestart: shutdown.exe /r /t 5 /f through Invoke-External, bounded at 1 minute; exit
    code 0, 1190 "shutdown already scheduled" or 1115 "shutdown in progress" is success, anything else
    or a timeout a failure) is tried. Either one succeeding
    returns $true; the caller must then return straight away, because Windows is shutting down.
    When both fail: "Restart failed: ..." is appended to State.Errors, the state is saved, an ERROR
    is logged and $false is returned. RebootCount stays incremented and RebootCapHit stays $false,
    so the caller can tell a failed restart from the cap.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [int]$CountdownSeconds = 15,
    [scriptblock]$RestartAction = { Restart-Computer -Force -ErrorAction Stop },
    [scriptblock]$FallbackRestartAction = { Invoke-ShutdownRestart }
  )

  $runState = $Context.State
  $maxReboots = [int]$Context.Config.caps.maxReboots   # a missing cap reads as 0: fail closed, never reboot
  $rebootCount = [int]$runState.RebootCount

  if ($runState.ResumeTaskMissing -eq $true) {
    $skipMessage = 'Restart skipped: no resume task'
    $knownErrors = @(@($runState.Errors) | Where-Object { $null -ne $_ })
    if ($knownErrors -notcontains $skipMessage) { $runState.Errors = @($knownErrors + $skipMessage) }
    Save-RunState -State $runState -Root $Context.Root
    Write-SetupLog -Level ERROR -Message 'Restart skipped: the resume task was never registered' -Data @{ rebootCount = $rebootCount }
    return $false
  }

  if ($rebootCount -ge $maxReboots) {
    $runState.RebootCapHit = $true
    Save-RunState -State $runState -Root $Context.Root
    Write-SetupLog -Level WARN -Message 'Reboot cap reached; not restarting' -Data @{ rebootCount = $rebootCount; maxReboots = $maxReboots }
    return $false
  }

  # Never throws by contract; the catch only makes sure Office can never stop the restart.
  try {
    $null = Wait-OfficeBackground -Context $Context -Purpose Restart
  } catch {
    Write-SetupLog -Level WARN -Message 'Waiting for Microsoft 365 before the restart failed; restarting anyway' -Data @{ error = $_.Exception.Message }
  }

  $runState.RebootCount = $rebootCount + 1
  Save-RunState -State $runState -Root $Context.Root
  Add-SetupActivity -Text ('Restarting (restart {0})' -f $runState.RebootCount)
  Write-SetupLog -Message 'Restarting the computer' -Data @{ rebootCount = $runState.RebootCount; maxReboots = $maxReboots }

  for ($remaining = $CountdownSeconds; $remaining -gt 0; $remaining--) {
    Write-Host "Restarting in $remaining s ..." -ForegroundColor White -BackgroundColor Black
    Start-Sleep -Seconds 1
  }

  try {
    & $RestartAction | Out-Null
    return $true
  } catch {
    $primaryError = $_.Exception.Message
    Write-SetupLog -Level WARN -Message 'Restart failed; trying shutdown.exe' -Data @{ error = $primaryError }
  }

  try {
    & $FallbackRestartAction | Out-Null
    Write-SetupLog -Message 'Restart started by the fallback (shutdown.exe)'
    return $true
  } catch {
    $fallbackError = $_.Exception.Message
  }

  $runState.Errors = @(@(@($runState.Errors) | Where-Object { $null -ne $_ }) + ('Restart failed: {0} (fallback: {1})' -f $primaryError, $fallbackError))
  Save-RunState -State $runState -Root $Context.Root
  Write-SetupLog -Level ERROR -Message 'Restart failed; the fallback failed too' -Data @{ error = $primaryError; fallbackError = $fallbackError; rebootCount = $runState.RebootCount }
  return $false
}

function Invoke-StatelessRestart {
  <#
  .SYNOPSIS
    Restart PC from the toolbox (repair spec 6.9): restarts the machine without any run state. $true when a restart
    was started. Never throws.
  .DESCRIPTION
    Start-BenTechSetup calls it after the Cancel path (the transcript stopped, the lock released, C:\BenTech removed
    when no earlier run exists). Not Invoke-ControlledReboot: there is no run state, so no reboot cap, no
    RebootCount, no resume task and no countdown (the technician confirmed in the window).
    RestartAction first (Restart-Computer -Force; it must throw on failure, hence -ErrorAction Stop); when it throws,
    a WARN and FallbackRestartAction (Invoke-ShutdownRestart: shutdown.exe /r /t 5 /f through Invoke-External, bounded
    at 1 minute; exit code 0, 1115 "shutdown in progress" or 1190 "shutdown already scheduled" is success, anything
    else or a timeout throws). When both fail: an ERROR, one line 'Could not restart the PC: <reasons in ASCII>' White
    on DarkRed (the window is gone, and after a cleanup the log is too, so the console is the one place it shows), and
    $false.
    Logging is a no-op after the cleanup stopped it.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [scriptblock]$RestartAction = { Restart-Computer -Force -ErrorAction Stop },
    [scriptblock]$FallbackRestartAction = { Invoke-ShutdownRestart }
  )

  $primaryError = ''
  $fallbackError = ''
  try {
    Write-SetupLog -Message 'Restarting the computer (Restart PC in the toolbox)'
    try {
      $null = & $RestartAction
      return $true
    } catch {
      $primaryError = ConvertTo-ScreenText -Text $_.Exception.Message
      Write-SetupLog -Level WARN -Message 'Restart failed; trying shutdown.exe' -Data @{ error = $primaryError }
    }
    try {
      $null = & $FallbackRestartAction
      Write-SetupLog -Message 'Restart started by the fallback (shutdown.exe)'
      return $true
    } catch {
      $fallbackError = ConvertTo-ScreenText -Text $_.Exception.Message
    }
    Write-SetupLog -Level ERROR -Message 'Restart failed; the fallback failed too' -Data @{ error = $primaryError; fallbackError = $fallbackError }
    Write-Host ('Could not restart the PC: {0} (fallback: {1})' -f $primaryError, $fallbackError) -ForegroundColor White -BackgroundColor DarkRed
  } catch {
    # Not expected (each step above catches its own failure); still never thrown.
    try {
      Write-Host ('Could not restart the PC: {0}' -f (ConvertTo-ScreenText -Text $_.Exception.Message)) -ForegroundColor White -BackgroundColor DarkRed
    } catch {
      Write-SetupLog -Level ERROR -Message 'Could not show the restart failure' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
  }
  return $false
}
