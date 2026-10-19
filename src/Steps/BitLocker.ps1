# src/Steps/BitLocker.ps1
# Step 1, "Turn off BitLocker" (spec 8.3, Q13), plus the helpers the vendor step (Wait-BitLockerDecrypted,
# Suspend-BitLockerOnce) and Finalize (Get-BitLockerAction, Get-BitLockerConversionStatus) use.
#
# Everything goes through CIM (root\cimv2\Security\MicrosoftVolumeEncryption, Win32_EncryptableVolume):
# no manage-bde, no BitLocker module, nothing whose output is localized text. Needs StepResult.ps1 and
# Logging.ps1, and Set-RegistryDword from Prepare.ps1 (the bundle holds every file).
#
# A new Windows 11 PC auto-encrypts the system drive ("device encryption") as soon as the user signs
# in with a Microsoft account. PreventDeviceEncryption = 1 stops that from happening again after
# the drive has been decrypted here.

$script:BitLockerNamespace = 'root\cimv2\Security\MicrosoftVolumeEncryption'
$script:BitLockerPolicyKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'

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

function Get-BitLockerCimVolume {
  # Private. The CIM instance for C:, or $null when the namespace, the class or the volume is missing
  # (no BitLocker on this edition, or a VM without it). The exception text is localized and is only logged.
  [CmdletBinding()]
  param()

  try {
    $volume = Get-CimInstance -Namespace $script:BitLockerNamespace -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction Stop
  } catch {
    Write-SetupLog -Message 'BitLocker volume not available' -Data @{ error = $_.Exception.Message }
    return $null
  }
  return @($volume | Select-Object -First 1)[0]
}

function Get-BitLockerConversionStatus {
  <#
  .SYNOPSIS
    Returns C:'s ConversionStatus (0..5) as an int, or $null when BitLocker is not there.
  .DESCRIPTION
    $null means "no volume": a missing namespace, class or volume. A GetConversionStatus call that
    fails (an exception, or a non-zero ReturnValue) is a WARN in the log and also gives $null.
  #>
  [CmdletBinding()]
  param()

  $volume = Get-BitLockerCimVolume
  if ($null -eq $volume) { return $null }
  try {
    $r = Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus -ErrorAction Stop
  } catch {
    Write-SetupLog -Message 'BitLocker status could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
    return $null
  }
  if ($null -eq $r -or [uint32]$r.ReturnValue -ne 0) {
    $code = if ($null -ne $r) { '0x{0:X8}' -f [uint32]$r.ReturnValue } else { 'no result' }
    Write-SetupLog -Message 'BitLocker status call failed' -Level WARN -Data @{ returnValue = $code }
    return $null
  }
  return [int]$r.ConversionStatus
}

function Invoke-StepBitLocker {
  <#
  .SYNOPSIS
    Step 1: stops automatic device encryption and starts decrypting C: if it is encrypted.
  .DESCRIPTION
    1. HKLM\SYSTEM\CurrentControlSet\Control\BitLocker\PreventDeviceEncryption = 1, ALWAYS and first,
       so a failure further down still leaves the machine from re-encrypting. A refused write is a
       Note, not a failure.
    2. The conversion status decides: no BitLocker -> Done('BitLocker not present'), Not encrypted ->
       Done('Not encrypted'), already decrypting -> Done('Decryption in progress'), anything else ->
       the Decrypt method -> Done('Decryption started').
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

  $status = Get-BitLockerConversionStatus
  if ($null -eq $status) {
    return New-StepResult -Status Done -Message 'BitLocker not present' -Notes $notes.ToArray()
  }

  switch (Get-BitLockerAction -ConversionStatus $status) {
    'None' { return New-StepResult -Status Done -Message 'Not encrypted' -Notes $notes.ToArray() }
    'Wait' { return New-StepResult -Status Done -Message 'Decryption in progress' -Notes $notes.ToArray() }
  }

  # Decrypt
  $volume = Get-BitLockerCimVolume
  if ($null -eq $volume) {
    return New-StepResult -Status Done -Message 'BitLocker not present' -Notes $notes.ToArray()
  }
  try {
    $r = Invoke-CimMethod -InputObject $volume -MethodName Decrypt -ErrorAction Stop
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
    Waits for C: to finish decrypting. $true = decrypted (or no BitLocker); $false = timed out, or
    the volume is not decrypting.
  .DESCRIPTION
    Status 0 or $null (no BitLocker) -> $true. Status 3 (decrypting) -> poll again every PollSeconds
    until the TimeoutMinutes are used up, then $false. Status 1, 2, 4 or 5 means no decryption is
    running, so waiting would be pointless: $false at once. PollSeconds and TimeoutMinutes take
    fractions so a test can run in milliseconds.
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
    $status = Get-BitLockerConversionStatus
    if ($null -eq $status -or $status -eq 0) {
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
    A machine without BitLocker, or with a decrypted C:, has nothing to protect, so that is $true and
    nothing is called. Anything that goes wrong (an exception, a non-zero ReturnValue) is a WARN and $false.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  try {
    $status = Get-BitLockerConversionStatus
    if ($null -eq $status -or $status -eq 0) {
      Write-SetupLog -Message 'BitLocker not active; nothing to suspend'
      return $true
    }
    $volume = Get-BitLockerCimVolume
    if ($null -eq $volume) { return $true }
    $r = Invoke-CimMethod -InputObject $volume -MethodName DisableKeyProtectors -Arguments @{ DisableCount = [uint32]1 } -ErrorAction Stop
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
