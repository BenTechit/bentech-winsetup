function Convert-MsiExitCode {
  <#
  .SYNOPSIS
    Maps an msiexec exit code to Done, DoneReboot, Retry or Failed.
  .DESCRIPTION
    0 is success; 3010 and 1641 are success that needs a reboot; 1618 means another installation is
    already running (try again later); everything else fails.

    The parameter is untyped on purpose. Invoke-External returns ExitCode = $null for a timed-out
    run, and a [int] parameter would silently turn that $null into 0, i.e. 'Done'. A null or
    non-numeric value is 'Failed'.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param($ExitCode)

  $n = 0
  if ($null -eq $ExitCode -or -not [int]::TryParse([string]$ExitCode, [ref]$n)) { return 'Failed' }
  switch ($n) {
    0 { return 'Done' }
    3010 { return 'DoneReboot' }
    1641 { return 'DoneReboot' }
    1618 { return 'Retry' }
    default { return 'Failed' }
  }
}

function Get-ProcessTreeId {
  <#
  .SYNOPSIS
    Returns the process ID of RootId followed by every descendant, found through Win32_Process.ParentProcessId.
  #>
  [CmdletBinding()]
  [OutputType([int[]])]
  param([Parameter(Mandatory)][int]$RootId)

  $seen = New-Object 'System.Collections.Generic.HashSet[int]'
  $order = New-Object 'System.Collections.Generic.List[int]'
  [void]$seen.Add($RootId)
  $order.Add($RootId)
  $i = 0
  while ($i -lt $order.Count) {
    $parent = $order[$i]
    $i++
    $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$parent" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
      if ($seen.Add([int]$child.ProcessId)) { $order.Add([int]$child.ProcessId) }
    }
  }
  return $order.ToArray()
}

function Stop-ProcessTree {
  <#
  .SYNOPSIS
    Force-kills a process and everything it started. Never throws.
  .DESCRIPTION
    The whole tree is collected BEFORE anything is killed, because killing a parent orphans its
    children and the walk would lose them. A hung installer usually hangs inside a child
    (msiexec, setup.exe) that Process.Kill() on the parent alone would leave running.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][int]$ProcessId)

  try {
    $ids = @(Get-ProcessTreeId -RootId $ProcessId)
  } catch {
    Write-SetupLog -Message 'Could not enumerate child processes; killing the root only' -Level WARN -Data @{ processId = $ProcessId; error = $_.Exception.Message }
    $ids = @($ProcessId)
  }
  # Root first, so it cannot start replacements while the children are being killed.
  foreach ($id in $ids) {
    try {
      Stop-Process -Id $id -Force -ErrorAction Stop
    } catch {
      # Already gone is fine; still running means access denied or similar.
      if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
        Write-SetupLog -Message 'Could not kill process' -Level WARN -Data @{ processId = $id; error = $_.Exception.Message }
      }
    }
  }
}

# --- Output capture -------------------------------------------------------------------------
# Not BeginOutputReadLine/OutputDataReceived: a script-block handler runs on a thread-pool thread
# that has no PowerShell runspace, and the parameterless WaitForExit() that flushes it waits for
# end-of-file on the pipe forever when a detached grandchild (an installer's helper service, say)
# inherited the pipe handles and outlives its parent. These helpers read with ReadAsync from the
# calling thread and every wait on them is bounded.

function New-PipeReader {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][IO.StreamReader]$Stream)

  return @{
    Stream = $Stream
    Buffer = New-Object 'char[]' 8192
    Sb     = New-Object Text.StringBuilder
    Task   = $null
    Done   = $false
  }
}

function Update-PipeReader {
  # Collects what the pending read has delivered and starts the next read. Never blocks.
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Reader)

  while (-not $Reader.Done) {
    if ($null -eq $Reader.Task) {
      $Reader.Task = $Reader.Stream.ReadAsync($Reader.Buffer, 0, $Reader.Buffer.Length)
    }
    if (-not $Reader.Task.IsCompleted) { return }
    $task = $Reader.Task
    $Reader.Task = $null
    if ($task.IsFaulted -or $task.IsCanceled) {
      $null = $task.Exception     # observe it
      $Reader.Done = $true
      return
    }
    $count = $task.Result
    if ($count -le 0) { $Reader.Done = $true; return }    # end of file
    [void]$Reader.Sb.Append($Reader.Buffer, 0, $count)
  }
}

function Wait-PipeReader {
  # Waits up to $Milliseconds for any unfinished reader to receive data, then collects it.
  # Returns $false (without waiting) once every reader has reached end-of-file.
  [CmdletBinding()]
  [OutputType([bool])]
  param([object[]]$Reader, [Parameter(Mandatory)][int]$Milliseconds)

  foreach ($r in $Reader) { Update-PipeReader -Reader $r }
  $tasks = @($Reader | Where-Object { -not $_.Done } | ForEach-Object { $_.Task })
  if ($tasks.Count -eq 0) { return $false }
  [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]$tasks, $Milliseconds)
  foreach ($r in $Reader) { Update-PipeReader -Reader $r }
  return $true
}

function Complete-PipeReader {
  # Waits (at most $GraceMilliseconds) for the readers to reach end-of-file.
  # Returns $false when the time ran out with a pipe still open.
  [CmdletBinding()]
  [OutputType([bool])]
  param([object[]]$Reader, [Parameter(Mandatory)][int]$GraceMilliseconds)

  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($clock.ElapsedMilliseconds -lt $GraceMilliseconds) {
    $slice = [int][Math]::Min(100, $GraceMilliseconds - $clock.ElapsedMilliseconds)
    if (-not (Wait-PipeReader -Reader $Reader -Milliseconds ([Math]::Max(1, $slice)))) { return $true }
  }
  return $false
}

function Invoke-External {
  <#
  .SYNOPSIS
    Runs a program, waits for it with a timeout, and kills its whole process tree on timeout.
  .DESCRIPTION
    Returns @{ ExitCode = <int|$null>; TimedOut = <bool>; Output = <string> }.
    - Uses System.Diagnostics.Process with UseShellExecute = $false and no console window.
    - -CaptureOutput redirects stdout and stderr and reads both concurrently (no pipe deadlock).
      Output is stdout followed by stderr; it is '' when output is not captured.
    - On timeout the process and every descendant are force-killed; ExitCode is $null, TimedOut is
      $true, and Output holds whatever was captured before the kill.
    - A .cmd or .bat file is started through cmd.exe, because a batch file cannot be started
      directly when UseShellExecute is $false (and a path with spaces needs the extra quoting).
    - A program that cannot be started throws (the runner catches it).
    - Start and end are logged at INFO with file, arguments, exit code and elapsed time. The
      captured Output is NEVER logged: it can hold an AnyDesk ID and logs must stay small.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string]$ArgumentList = '',
    [ValidateRange(0.001, 10080)][double]$TimeoutMinutes = 30,
    [string]$WorkingDirectory,
    [switch]$CaptureOutput
  )

  # How long to keep reading after the process is gone; see the note above New-PipeReader.
  $drainAfterExitMs = 5000
  $drainAfterKillMs = 2000

  $isBatch = [IO.Path]::GetExtension($FilePath) -in '.cmd', '.bat'
  $psi = New-Object Diagnostics.ProcessStartInfo
  if ($isBatch) {
    if ([IO.Path]::IsPathRooted($FilePath) -and -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
      Write-SetupLog -Message 'External file not found' -Level ERROR -Data @{ file = $FilePath }
      throw (New-Object IO.FileNotFoundException ("Cannot start '$FilePath': the file does not exist.", $FilePath))
    }
    # cmd /s /c ""<file>" <args>": /s makes cmd strip exactly the outer quote pair, so the inner
    # quotes around a path with spaces survive.
    $inner = '"' + $FilePath + '"'
    if ($ArgumentList) { $inner += ' ' + $ArgumentList }
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/s /c "' + $inner + '"'
  } else {
    $psi.FileName = $FilePath
    $psi.Arguments = $ArgumentList
  }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
  if ($CaptureOutput) {
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
  }

  $timeoutMs = [int][Math]::Min([Math]::Ceiling($TimeoutMinutes * 60000), [double][int]::MaxValue)
  $clock = [Diagnostics.Stopwatch]::StartNew()
  Write-SetupLog -Message 'External process starting' -Data @{ file = $FilePath; args = $ArgumentList; timeoutMinutes = $TimeoutMinutes }

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  try {
    try {
      [void]$proc.Start()
    } catch {
      Write-SetupLog -Message 'External process failed to start' -Level ERROR -Data @{ file = $FilePath; error = $_.Exception.Message }
      throw (New-Object InvalidOperationException ("Cannot start '$FilePath': $($_.Exception.Message)", $_.Exception))
    }

    $readers = @()
    if ($CaptureOutput) {
      $stdout = New-PipeReader -Stream $proc.StandardOutput
      $stderr = New-PipeReader -Stream $proc.StandardError
      $readers = @($stdout, $stderr)
    }

    $timedOut = $false
    while (-not $proc.HasExited) {
      $remaining = $timeoutMs - $clock.ElapsedMilliseconds
      if ($remaining -le 0) { $timedOut = $true; break }
      $slice = [int][Math]::Min($remaining, 200)
      if (-not (Wait-PipeReader -Reader $readers -Milliseconds $slice)) { [void]$proc.WaitForExit($slice) }
    }

    if ($timedOut) {
      Write-SetupLog -Message 'External process timed out; killing its process tree' -Level WARN -Data @{ file = $FilePath; processId = $proc.Id; timeoutMinutes = $TimeoutMinutes }
      Stop-ProcessTree -ProcessId $proc.Id
      [void]$proc.WaitForExit(5000)
      $exitCode = $null
      $drainMs = $drainAfterKillMs
    } else {
      $exitCode = [int]$proc.ExitCode
      $drainMs = $drainAfterExitMs
    }

    if ($CaptureOutput -and -not (Complete-PipeReader -Reader $readers -GraceMilliseconds $drainMs)) {
      Write-SetupLog -Message 'Output pipes still open after the process ended (a detached child holds them); continuing' -Level WARN -Data @{ file = $FilePath; waitedMs = $drainMs }
    }

    $output = ''
    if ($CaptureOutput) {
      $text = $stdout.Sb.ToString()
      $errText = $stderr.Sb.ToString()
      if ($text.Length -gt 0 -and $errText.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
      $output = $text + $errText
    }
  } finally {
    $proc.Dispose()
  }

  $clock.Stop()
  Write-SetupLog -Message 'External process finished' -Data @{ file = $FilePath; exitCode = $exitCode; timedOut = $timedOut; elapsedMs = $clock.ElapsedMilliseconds }
  return @{ ExitCode = $exitCode; TimedOut = $timedOut; Output = $output }
}
