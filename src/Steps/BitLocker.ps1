# src/Steps/BitLocker.ps1
# Step 1, "Turn off BitLocker" (spec 8.3, Q13), plus the helpers the vendor step (Wait-BitLockerDecrypted,
# Suspend-BitLockerOnce) and Finalize (Get-BitLockerAction, Get-BitLockerConversionStatus) use.
#
# Everything goes through CIM (root\cimv2\Security\MicrosoftVolumeEncryption, Win32_EncryptableVolume):
# no manage-bde, no BitLocker module, nothing whose output is localized text. Needs StepResult.ps1 and
# Logging.ps1, and Set-RegistryDword from Prepare.ps1 (the bundle holds every file).
#
# "No BitLocker" and "could not read BitLocker" are different answers and must never be mixed up:
# the first is safe to act on (nothing to wait for, nothing to suspend), the second is not (a BIOS
# flash on a drive that is in fact encrypted can leave the PC asking for a recovery key). The
# volume is therefore reported as 'Present', 'Absent' or 'Unknown' (Get-BitLockerVolumeInfo), and
# only Absent is treated as "no BitLocker".
#
# A new Windows 11 PC auto-encrypts the system drive ("device encryption") as soon as the user signs
# in with a Microsoft account. PreventDeviceEncryption = 1 stops that from happening again after
# the drive has been decrypted here.

$script:BitLockerNamespace = 'root\cimv2\Security\MicrosoftVolumeEncryption'
$script:BitLockerPolicyKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'

# CimException.NativeErrorCode values that mean "this class of object does not exist here" (the
# namespace is missing on an edition without BitLocker, or the class is). The enum NAME is used, not
# the message text, which is localized. Anything else (AccessDenied, Failed, a timeout, a service
# that is down...) says nothing about whether BitLocker exists, so it is 'Unknown'.
$script:BitLockerAbsentErrorCodes = @('InvalidNamespace', 'InvalidClass')

function Get-BitLockerAction {
  <#
  .SYNOPSIS
    Maps a Win32_EncryptableVolume ConversionStatus to what the step does: 'None', 'Decrypt' or 'Wait'.
  .DESCRIPTION
    ConversionStatus: 0 fully decrypted, 1 fully encrypted, 2 encryption in progress, 3 decryption in
    progress, 4 encryption paused, 5 decryption paused.
      0 -> None (nothing to do)           3 -> Wait (already decrypting; Decrypt must not be repeated)
      1, 2, 4, 5 -> Decrypt (5 resumes a paused decryption)
    A value outside 0..5 also maps to Decrypt, so the CIM return value decides rather than the volume
    being silently left as it is.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][int]$ConversionStatus)

  switch ($ConversionStatus) {
    0 { return 'None' }
    3 { return 'Wait' }
    default { return 'Decrypt' }
  }
}

function Get-BitLockerVolumeInfo {
  <#
  .SYNOPSIS
    Private. Looks C: up in CIM and returns @{ State = 'Present'|'Absent'|'Unknown'; Volume = <CimInstance|$null> }.
  .DESCRIPTION
    Present: the volume was found (Volume holds it, for the caller to reuse).
    Absent:  the namespace or class does not exist (CimException.NativeErrorCode InvalidNamespace or
             InvalidClass), or the query worked and no volume matched. Logged at INFO.
    Unknown: the query failed for any other reason (access denied, WMI down, a timeout, an error
             that is not a CimException). Logged at WARN. Never to be read as "no BitLocker".
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  try {
    $found = Get-CimInstance -Namespace $script:BitLockerNamespace -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction Stop
  } catch {
    $code = [string]$_.Exception.NativeErrorCode
    if ($code -in $script:BitLockerAbsentErrorCodes) {
      Write-SetupLog -Message 'BitLocker is not available on this PC' -Data @{ nativeErrorCode = $code }
      return @{ State = 'Absent'; Volume = $null }
    }
    Write-SetupLog -Message 'BitLocker volume could not be queried' -Level WARN -Data @{ nativeErrorCode = $code; error = $_.Exception.Message }
    return @{ State = 'Unknown'; Volume = $null }
  }

  $volume = @($found | Select-Object -First 1)[0]
  if ($null -eq $volume) {
    Write-SetupLog -Message 'BitLocker has no volume for C:'
    return @{ State = 'Absent'; Volume = $null }
  }
  return @{ State = 'Present'; Volume = $volume }
}

function Get-BitLockerState {
  <#
  .SYNOPSIS
    Private. @{ Presence = 'Present'|'Absent'|'Unknown'; Volume; Status = <int|$null> } in one CIM round.
  .DESCRIPTION
    Status is the ConversionStatus and is $null unless Presence is 'Present' AND GetConversionStatus
    answered (an exception or a non-zero ReturnValue is a WARN and leaves it $null). So Present with a
    $null Status means "there is a volume but its state could not be read".
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $info = Get-BitLockerVolumeInfo
  $state = @{ Presence = $info.State; Volume = $info.Volume; Status = $null }
  if ($info.State -ne 'Present') { return $state }

  try {
    $r = Invoke-CimMethod -InputObject $info.Volume -MethodName GetConversionStatus -ErrorAction Stop
  } catch {
    Write-SetupLog -Message 'BitLocker status could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
    return $state
  }
  if ($null -eq $r -or [uint32]$r.ReturnValue -ne 0) {
    $code = if ($null -ne $r) { '0x{0:X8}' -f [uint32]$r.ReturnValue } else { 'no result' }
    Write-SetupLog -Message 'BitLocker status call failed' -Level WARN -Data @{ returnValue = $code }
    return $state
  }
  $state.Status = [int]$r.ConversionStatus
  return $state
}

function Get-BitLockerConversionStatus {
  <#
  .SYNOPSIS
    Returns C:'s ConversionStatus (0..5) as an int, or $null when it is not available.
  .DESCRIPTION
    $null covers both "no BitLocker" and "could not be read" (a failure is a WARN in the log). Callers
    that must tell the two apart (the steps in this file do) use Get-BitLockerState.
  #>
  [CmdletBinding()]
  param()

  return (Get-BitLockerState).Status
}

function Invoke-StepBitLocker {
  <#
  .SYNOPSIS
    Step 1: stops automatic device encryption and starts decrypting C: if it is encrypted.
  .DESCRIPTION
    1. HKLM\SYSTEM\CurrentControlSet\Control\BitLocker\PreventDeviceEncryption = 1, ALWAYS and first,
       so a failure further down still leaves the machine from re-encrypting. A refused write is a
       Note, not a failure.
    2. The volume and its conversion status are read once; that volume is then reused for Decrypt.
         Absent                       -> Done('BitLocker not present')
         Unknown, or unreadable status -> Done('BitLocker status unknown') with the Note
                                          'BitLocker status could not be read' (never "not present")
         not encrypted                -> Done('Not encrypted')
         already decrypting           -> Done('Decryption in progress')
         anything else                -> the Decrypt method -> Done('Decryption started')
    Decryption runs in the background and needs no restart, so the step does not wait for it; the
    vendor step waits (Wait-BitLockerDecrypted) before it flashes a BIOS, and Finalize reports it.
    A Decrypt that fails (non-zero ReturnValue, or an exception) is Failed.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $notes = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Set-RegistryDword -Path $script:BitLockerPolicyKey -Name 'PreventDeviceEncryption' -Value 1)) {
    $notes.Add('Automatic device encryption could not be turned off')
  }

  $state = Get-BitLockerState
  if ($state.Presence -eq 'Absent') {
    return New-StepResult -Status Done -Message 'BitLocker not present' -Notes $notes.ToArray()
  }
  if ($state.Presence -ne 'Present' -or $null -eq $state.Status) {
    Write-SetupLog -Message 'BitLocker state is unknown; nothing was changed' -Level WARN -Data @{ presence = $state.Presence }
    $notes.Add('BitLocker status could not be read')
    return New-StepResult -Status Done -Message 'BitLocker status unknown' -Notes $notes.ToArray()
  }
  $status = [int]$state.Status

  switch (Get-BitLockerAction -ConversionStatus $status) {
    'None' { return New-StepResult -Status Done -Message 'Not encrypted' -Notes $notes.ToArray() }
    'Wait' { return New-StepResult -Status Done -Message 'Decryption in progress' -Notes $notes.ToArray() }
  }

  # Decrypt
  try {
    $r = Invoke-CimMethod -InputObject $state.Volume -MethodName Decrypt -ErrorAction Stop
  } catch {
    $reason = $_.Exception.Message
    Write-SetupLog -Message 'BitLocker decrypt threw' -Level ERROR -Data @{ status = $status; error = $reason }
    return New-StepResult -Status Failed -Message "BitLocker decrypt failed: $reason" -Notes $notes.ToArray()
  }
  $returnValue = if ($null -ne $r) { [uint32]$r.ReturnValue } else { [uint32]::MaxValue }
  if ($returnValue -ne 0) {
    $text = 'BitLocker decrypt failed (0x{0:X8})' -f $returnValue
    Write-SetupLog -Message $text -Level ERROR -Data @{ status = $status }
    return New-StepResult -Status Failed -Message $text -Notes $notes.ToArray()
  }
  Write-SetupLog -Message 'BitLocker decryption started' -Data @{ previousStatus = $status }
  return New-StepResult -Status Done -Message 'Decryption started' -Notes $notes.ToArray()
}

function Wait-BitLockerDecrypted {
  <#
  .SYNOPSIS
    Waits for C: to finish decrypting. $true = decrypted, or there is no BitLocker; $false = timed out,
    not decrypting, or the state could not be read.
  .DESCRIPTION
    Volume absent, or status 0 -> $true. Status 3 (decrypting) -> poll again every PollSeconds until
    the TimeoutMinutes are used up, then $false. Status 1, 2, 4 or 5 means no decryption is
    running, so waiting would be pointless: $false at once. A volume that cannot be queried at all
    (Unknown), or a volume whose status cannot be read, is $false with a WARN: "I could not look" must
    never be reported as "decrypted", because the caller goes on to flash a BIOS. PollSeconds and
    TimeoutMinutes take fractions so a test can run in milliseconds.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][ValidateRange(0, 10080)][double]$TimeoutMinutes,
    [ValidateRange(0.001, 3600)][double]$PollSeconds = 30
  )

  $clock = [Diagnostics.Stopwatch]::StartNew()
  $timeoutMs = $TimeoutMinutes * 60000
  $lastStatus = -1
  while ($true) {
    $state = Get-BitLockerState
    if ($state.Presence -eq 'Absent') {
      Write-SetupLog -Message 'No BitLocker; nothing to wait for'
      return $true
    }
    if ($state.Presence -ne 'Present' -or $null -eq $state.Status) {
      Write-SetupLog -Message 'BitLocker state could not be read; not treating it as decrypted' -Level WARN -Data @{ presence = $state.Presence; waitedSeconds = [int]$clock.Elapsed.TotalSeconds }
      return $false
    }
    $status = [int]$state.Status
    if ($status -eq 0) {
      Write-SetupLog -Message 'BitLocker is decrypted' -Data @{ waitedSeconds = [int]$clock.Elapsed.TotalSeconds }
      return $true
    }
    if ($status -ne 3) {
      Write-SetupLog -Message 'BitLocker is not decrypting; not waiting' -Level WARN -Data @{ status = $status }
      return $false
    }
    if ($status -ne $lastStatus) {
      Write-SetupLog -Message 'Waiting for BitLocker decryption' -Data @{ timeoutMinutes = $TimeoutMinutes }
      $lastStatus = $status
    }
    $remainingMs = $timeoutMs - $clock.ElapsedMilliseconds
    if ($remainingMs -le 0) {
      Write-SetupLog -Message 'Timed out waiting for BitLocker decryption' -Level WARN -Data @{ timeoutMinutes = $TimeoutMinutes }
      return $false
    }
    Start-Sleep -Milliseconds ([int][Math]::Max(1, [Math]::Min($PollSeconds * 1000, $remainingMs)))
  }
}

function Suspend-BitLockerOnce {
  <#
  .SYNOPSIS
    Suspends BitLocker protection for one restart (DisableKeyProtectors, DisableCount = 1), e.g. before
    a BIOS flash. Returns $true when C: is suspended or there is nothing to suspend; never throws.
  .DESCRIPTION
    No BitLocker (the volume is Absent) or a decrypted C: (status 0) has nothing to protect: $true,
    nothing is called. A volume that cannot be queried at all (Unknown) cannot be suspended: $false.
    A volume that exists but whose status could not be read is treated as possibly encrypted: the
    suspension is still attempted, because suspending an unprotected drive is harmless and a wrongly
    skipped suspension is not. Anything that goes wrong (an exception, a non-zero ReturnValue) is a
    WARN and $false.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  try {
    $state = Get-BitLockerState
    if ($state.Presence -eq 'Absent') {
      Write-SetupLog -Message 'No BitLocker; nothing to suspend'
      return $true
    }
    if ($state.Presence -ne 'Present') {
      Write-SetupLog -Message 'BitLocker could not be queried, so it cannot be suspended' -Level WARN
      return $false
    }
    if ($null -ne $state.Status -and $state.Status -eq 0) {
      Write-SetupLog -Message 'BitLocker not active; nothing to suspend'
      return $true
    }
    if ($null -eq $state.Status) {
      Write-SetupLog -Message 'BitLocker status unreadable; suspending anyway' -Level WARN
    }
    $r = Invoke-CimMethod -InputObject $state.Volume -MethodName DisableKeyProtectors -Arguments @{ DisableCount = [uint32]1 } -ErrorAction Stop
    if ($null -ne $r -and [uint32]$r.ReturnValue -eq 0) {
      Write-SetupLog -Message 'BitLocker suspended for one restart'
      return $true
    }
    $code = if ($null -ne $r) { '0x{0:X8}' -f [uint32]$r.ReturnValue } else { 'no result' }
    Write-SetupLog -Message 'BitLocker could not be suspended' -Level WARN -Data @{ returnValue = $code }
    return $false
  } catch {
    Write-SetupLog -Message 'BitLocker could not be suspended' -Level WARN -Data @{ error = $_.Exception.Message }
    return $false
  }
}
