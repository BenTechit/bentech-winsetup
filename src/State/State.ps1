# src/State/State.ps1
# Persistent run state (state.json) and the single-instance lock (run.lock).
#
# State is held in memory as nested hashtables and saved as JSON. Windows PowerShell 5.1 has no
# ConvertFrom-Json -AsHashtable, so ConvertTo-HashtableDeep does that conversion by hand.
# Timestamps are ISO 8601 local time (yyyy-MM-ddTHH:mm:ss), always formatted with the invariant
# culture because target machines may run a Hebrew locale.

function Get-StateTimestamp {
  [CmdletBinding()]
  [OutputType([string])]
  param()
  (Get-Date).ToString('s', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-HashtableDeep {
  <#
  .SYNOPSIS
    Recursively turns PSCustomObjects (ConvertFrom-Json output) into hashtables. Arrays stay arrays.
  .DESCRIPTION
    A one-element array and an empty array must survive the return: PowerShell unrolls whatever a
    function emits, so every array is returned wrapped with the comma operator, and the caller's
    assignment unwraps exactly one level.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()]$InputObject)

  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [string]) { return $InputObject }
  if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
    $table = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
      $table[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
    }
    return $table
  }
  if ($InputObject -is [System.Collections.IDictionary]) {
    $table = @{}
    foreach ($key in @($InputObject.Keys)) {
      $table[$key] = ConvertTo-HashtableDeep -InputObject $InputObject[$key]
    }
    return $table
  }
  if ($InputObject -is [System.Collections.IEnumerable]) {
    $items = @(foreach ($item in $InputObject) { ConvertTo-HashtableDeep -InputObject $item })
    return , $items
  }
  return $InputObject
}

function New-RunState {
  <#
  .SYNOPSIS
    Builds a fresh State hashtable (see "Shared shapes" in the plan). Every plan step is pending.
  .DESCRIPTION
    PreviousRun stays $null: the entry point (Task 17) fills it from the previous run's verdict.
    PreviousHiddenUpdateIds is copied from -Previous so Windows Update can re-offer what was hidden.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)][hashtable]$Choices,
    [Parameter(Mandatory)][string[]]$Plan,
    [Parameter(Mandatory)][string]$Version,
    [hashtable]$Previous
  )

  $steps = @{}
  foreach ($id in $Plan) {
    $steps[$id] = @{ Status = 'pending'; Attempts = 0; Message = ''; StartedAt = $null; EndedAt = $null; Data = @{} }
  }

  $previousHidden = @()
  if ($null -ne $Previous -and $null -ne $Previous['HiddenUpdateIds']) {
    $previousHidden = @($Previous['HiddenUpdateIds'])
  }

  @{
    SchemaVersion           = 1
    Version                 = $Version
    RunId                   = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    StartedAt               = Get-StateTimestamp
    EndedAt                 = $null
    Machine                 = $Machine
    Choices                 = $Choices
    Plan                    = @($Plan)
    Steps                   = $steps
    RebootCount             = 0
    RebootCapHit            = $false
    FinalRebootDone         = $false
    WuFailureCounts         = @{}
    HiddenUpdateIds         = @()
    PreviousHiddenUpdateIds = $previousHidden
    Notes                   = @()
    Errors                  = @()
    AnyDeskId               = $null
    Power                   = @{ Original = @{} }
    PreviousRun             = $null
  }
}

function Get-FreeArchivePath {
  # Returns $Path, or "<name>-2<ext>", "<name>-3<ext>"... when it is already taken: an archive is
  # evidence and must never be overwritten.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return $Path }
  $dir = Split-Path -Parent $Path
  $name = [IO.Path]::GetFileNameWithoutExtension($Path)
  $ext = [IO.Path]::GetExtension($Path)
  for ($i = 2; ; $i++) {
    $candidate = Join-Path $dir ('{0}-{1}{2}' -f $name, $i, $ext)
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
}

function Save-RunState {
  <#
  .SYNOPSIS
    Atomically writes <Root>\state.json: state.json.tmp (UTF-8, no BOM, flushed to disk), then replace.
  .DESCRIPTION
    A power cut leaves either the old complete file or the new complete file, never a half-written
    one. The JSON is built before anything is written. Note that Windows PowerShell 5.1 truncates
    anything nested deeper than -Depth 12 without a warning; State is about 6 levels deep, so keep
    step Data shallow.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][string]$Root
  )

  if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
  $target = Join-Path $Root 'state.json'
  $tmp = $target + '.tmp'

  $json = ConvertTo-Json -InputObject $State -Depth 12
  $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($json)

  $stream = [IO.File]::Open($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)   # data on disk before the rename, or a power cut can leave an empty file
  } finally { $stream.Dispose() }

  # A virus scanner can hold the file for a moment, so retry the swap a couple of times.
  for ($attempt = 1; ; $attempt++) {
    try {
      # [NullString]::Value, not $null: PowerShell converts a plain $null to "" for a string
      # parameter, and Replace rejects "" as an illegal path.
      if (Test-Path -LiteralPath $target) { [IO.File]::Replace($tmp, $target, [NullString]::Value) }
      else { [IO.File]::Move($tmp, $target) }
      break
    } catch [IO.IOException], [UnauthorizedAccessException] {
      if ($attempt -ge 3) { throw }
      Start-Sleep -Milliseconds 150
    }
  }
}

function Read-RunState {
  <#
  .SYNOPSIS
    Reads <Root>\state.json as nested hashtables. Returns $null when the file is absent.
  .DESCRIPTION
    A file that is not valid JSON (or not a JSON object) is moved to
    <LogDir>\state.corrupt-yyyyMMdd-HHmmss.json, a WARN is logged, and $null is returned so the
    caller starts clean. LogDir defaults to <Root>\Logs. A file that cannot be *read* (locked) is
    not treated as corrupt: that exception propagates and the file is left alone.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Root,
    [string]$LogDir
  )

  $path = Join-Path $Root 'state.json'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $text = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding $false))

  $state = $null
  $problem = $null
  try {
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'state.json is empty' }
    $state = ConvertTo-HashtableDeep -InputObject (ConvertFrom-Json -InputObject $text -ErrorAction Stop)
    if ($state -isnot [hashtable]) { throw 'state.json does not contain a JSON object' }
  } catch {
    $problem = $_.Exception.Message
    $state = $null
  }
  if ($null -ne $state) { return $state }

  if (-not $LogDir) { $LogDir = Join-Path $Root 'Logs' }
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
  $destination = Get-FreeArchivePath -Path (Join-Path $LogDir "state.corrupt-$stamp.json")
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null }
    [IO.File]::Move($path, $destination)
    Write-SetupLog -Level WARN -Message "state.json is unreadable; moved it to $destination and starting clean" -Data @{ reason = $problem }
  } catch {
    # Still return $null: the damaged file is unusable, and the next Save-RunState replaces it.
    Write-SetupLog -Level ERROR -Message 'state.json is unreadable and could not be archived' -Data @{ path = $path; reason = $problem; error = $_.Exception.Message }
  }
  return $null
}

function Backup-RunState {
  <#
  .SYNOPSIS
    Moves <Root>\state.json to <LogDir>\state-<RunId>.json (before a re-run starts a new state).
  .DESCRIPTION
    Does nothing when there is no state.json. A corrupt file is archived as state.corrupt-* by
    Read-RunState instead. An existing archive with the same name is never overwritten.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$LogDir
  )

  $path = Join-Path $Root 'state.json'
  if (-not (Test-Path -LiteralPath $path)) { return }
  $state = Read-RunState -Root $Root -LogDir $LogDir
  if ($null -eq $state) { return }

  $runId = $null
  if ($state.ContainsKey('RunId') -and $state['RunId']) { $runId = ([string]$state['RunId']) -replace '[^0-9A-Za-z._-]', '_' }
  if (-not $runId) { $runId = 'unknown-' + (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) }

  if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  [IO.File]::Move($path, (Get-FreeArchivePath -Path (Join-Path $LogDir "state-$runId.json")))
}

function Set-StepState {
  <#
  .SYNOPSIS
    Updates one step in the in-memory state (the caller saves).
  .DESCRIPTION
    StartedAt is set on 'running' (and a stale EndedAt cleared); EndedAt is set on Done, Skipped and
    Failed. -Message is only changed when given. -ResetAttempts is applied before -IncrementAttempt.
    -Data is merged key by key into Steps[id].Data. An id that is not in the plan throws: a typo
    must not silently create a phantom step the runner never executes.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][string]$StepId,
    [Parameter(Mandatory)][ValidateSet('pending', 'running', 'Done', 'Skipped', 'Failed')][string]$Status,
    [string]$Message,
    [switch]$IncrementAttempt,
    [switch]$ResetAttempts,
    [hashtable]$Data
  )

  if (-not $State.Steps.ContainsKey($StepId)) { throw "Unknown step id '$StepId'" }
  $step = $State.Steps[$StepId]

  # ValidateSet is case-insensitive; store the canonical spelling the State shape documents.
  $canonical = 'pending', 'running', 'Done', 'Skipped', 'Failed' | Where-Object { $_ -eq $Status } | Select-Object -First 1
  $step.Status = $canonical
  $now = Get-StateTimestamp
  if ($canonical -eq 'running') {
    $step.StartedAt = $now
    $step.EndedAt = $null
  } elseif ($canonical -in 'Done', 'Skipped', 'Failed') {
    $step.EndedAt = $now
  }

  if ($PSBoundParameters.ContainsKey('Message')) { $step.Message = $Message }
  if ($ResetAttempts) { $step.Attempts = 0 }
  if ($IncrementAttempt) { $step.Attempts = [int]$step.Attempts + 1 }
  if ($Data) {
    if ($null -eq $step.Data) { $step.Data = @{} }
    foreach ($key in $Data.Keys) { $step.Data[$key] = $Data[$key] }
  }
}

function Test-RunLockHeld {
  <#
  .SYNOPSIS
    $true only if run.lock holds an integer pid, that process exists, and it is powershell or pwsh.
  .DESCRIPTION
    One extra guard against pid reuse: a process that started more than 5 seconds after the lock
    was written cannot be the owner (the owner wrote the lock after it started), so a stale lock
    left by a crash or power cut cannot be mistaken for a live run just because Windows handed its
    pid to a new powershell after the reboot.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Root)

  $lock = Join-Path $Root 'run.lock'
  if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return $false }
  try { $text = [IO.File]::ReadAllText($lock) } catch { return $false }

  $ownerPid = 0
  $parsed = [int]::TryParse($text.Trim(), [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$ownerPid)
  if (-not $parsed -or $ownerPid -le 0) { return $false }

  $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
  if ($null -eq $process) { return $false }
  if ($process.ProcessName -notin 'powershell', 'pwsh') { return $false }

  try {
    $lockWritten = [IO.File]::GetLastWriteTimeUtc($lock)   # UTC both sides: immune to DST changes
    if ($process.StartTime.ToUniversalTime() -gt $lockWritten.AddSeconds(5)) { return $false }
  } catch {
    # Start time unreadable (access denied): the name matched, so assume the owner is alive.
    Write-SetupLog -Level WARN -Message 'run.lock owner start time unavailable; treating the lock as held' -Data @{ error = $_.Exception.Message }
  }
  return $true
}

function Move-RunLockIntoPlace {
  # Private. The check-takeover-move sequence behind Enter-RunLock; Enter-RunLock serializes callers
  # around it with a named mutex. Returns $false (never throws) when the lock is held, cannot be
  # taken over, or the file system refuses.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Root)

  $lock = Join-Path $Root 'run.lock'
  $tmp = "$lock.$PID.tmp"
  try {
    [IO.File]::WriteAllText($tmp, "$PID", (New-Object Text.UTF8Encoding $false))
    for ($attempt = 1; $attempt -le 2; $attempt++) {
      try {
        [IO.File]::Move($tmp, $lock)   # fails if run.lock exists, so it never overwrites a lock
        return $true
      } catch [IO.IOException] {
        # A lock is already there: keep it if its owner is alive, otherwise it is stale.
        if (Test-RunLockHeld -Root $Root) { return $false }
        if ($attempt -ge 2) {
          Write-SetupLog -Level WARN -Message 'could not create run.lock even after removing a stale one' -Data @{ error = $_.Exception.Message }
          return $false
        }
        [IO.File]::Delete($lock)
      }
    }
    return $false
  } catch [IO.IOException], [UnauthorizedAccessException] {
    Write-SetupLog -Level WARN -Message 'could not take run.lock' -Data @{ error = $_.Exception.Message }
    return $false
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Enter-RunLock {
  <#
  .SYNOPSIS
    Takes <Root>\run.lock for this process. Returns $false when another live setup run holds it.
  .DESCRIPTION
    Everything runs inside the machine-wide named mutex Global\BenTechSetup-RunLock, so two
    starters (for example the resume task and a double-click right after a reboot) can never both
    inspect the same stale lock and both take it over. Inside the mutex the pid goes to a private
    temp file that is moved onto run.lock; a move onto an existing file fails, so a live owner's
    lock is never overwritten. A stale lock (dead or reused pid, garbage) is re-checked, deleted
    and replaced. Returns $false, never throws, when the mutex is not obtained within 10 seconds
    or the lock cannot be taken (the reason is logged as WARN). If the mutex itself cannot be
    created (access denied), it continues without it, which protects against everything except
    the stale-lock takeover race.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Root)

  if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }

  $mutex = $null
  $owned = $false
  try {
    try {
      $mutex = New-Object Threading.Mutex -ArgumentList $false, 'Global\BenTechSetup-RunLock'
    } catch {
      Write-SetupLog -Level WARN -Message 'run lock mutex unavailable; continuing without it' -Data @{ error = $_.Exception.Message }
    }
    if ($null -ne $mutex) {
      try { $owned = $mutex.WaitOne(10000) }
      catch [Threading.AbandonedMutexException] { $owned = $true }   # the previous owner died; we own it now
      if (-not $owned) {
        Write-SetupLog -Level WARN -Message 'run lock mutex not obtained within 10 seconds'
        return $false
      }
    }
    return (Move-RunLockIntoPlace -Root $Root)
  } finally {
    if ($owned) {
      try { $mutex.ReleaseMutex() }
      catch { Write-SetupLog -Level WARN -Message 'could not release run lock mutex' -Data @{ error = $_.Exception.Message } }
    }
    if ($null -ne $mutex) { $mutex.Dispose() }
  }
}

function Exit-RunLock {
  <#
  .SYNOPSIS
    Releases <Root>\run.lock, but only if it holds this process's pid. Never throws.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Root)

  try {
    $lock = Join-Path $Root 'run.lock'
    if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return }
    if ([IO.File]::ReadAllText($lock).Trim() -eq "$PID") { [IO.File]::Delete($lock) }
  } catch {
    Write-SetupLog -Level WARN -Message 'could not release run.lock' -Data @{ error = $_.Exception.Message }
  }
}
