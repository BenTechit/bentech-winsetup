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
  .DESCRIPTION
    Breadth-first, so a parent always comes before its children. If the query for one process fails,
    a WARN is logged and the walk does not descend from that process; everything already found (and
    every other branch) is kept. Never throws because of a failed query.
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
    # -ErrorAction Stop makes a WMI failure visible (SilentlyContinue would look like "no children"
    # and the children would survive unnoticed). -OperationTimeoutSec bounds each query, so a wedged
    # WMI service delays the kill by at most 10 s per process in the tree, not indefinitely.
    try {
      $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$parent" -OperationTimeoutSec 10 -ErrorAction Stop)
    } catch {
      Write-SetupLog -Message "Could not enumerate children of ${parent}: $(ConvertTo-ScreenText -Text $_.Exception.Message)" -Level WARN -Data @{ processId = $parent }
      continue
    }
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
    A logged exception text goes through ConvertTo-ScreenText (StartScreen.ps1; a Hebrew Windows
    localizes it: repair Task 4 review M8); the bundle defines every function before it runs.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][int]$ProcessId)

  try {
    $ids = @(Get-ProcessTreeId -RootId $ProcessId)
  } catch {
    # Last resort: Get-ProcessTreeId handles failed queries itself, so this means something
    # unexpected. The root must still be killed.
    Write-SetupLog -Message "Could not walk the process tree; killing the root only: $(ConvertTo-ScreenText -Text $_.Exception.Message)" -Level WARN -Data @{ processId = $ProcessId }
    $ids = @($ProcessId)
  }
  # Root first, so it cannot start replacements while the children are being killed.
  foreach ($id in $ids) {
    try {
      Stop-Process -Id $id -Force -ErrorAction Stop
    } catch {
      # Already gone is fine; still running means access denied or similar.
      if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
        Write-SetupLog -Message 'Could not kill process' -Level WARN -Data @{ processId = $id; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
      }
    }
  }
}

function Wait-ProcessExit {
  <#
  .SYNOPSIS
    $true once -Process has ended, waiting at most -Milliseconds (0 to 10000) for it. Never throws.
  .DESCRIPTION
    A kill is asynchronous (TerminateProcess returns before the process has ended), so a caller that would call a
    child "still running" right after its kill first waits here, briefly and bounded (repair final wave item 11). A
    real [Diagnostics.Process] is waited on with WaitForExit(-Milliseconds); any other object (a test's stand-in) has
    its HasExited read once. $null has ended; a wait or a read that fails has not. The toolbox calls it only after its
    window is gone (Get-SetupChoices' finally): the window never waits while it is shown.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()]$Process,
    [ValidateRange(0, 10000)][int]$Milliseconds = 0
  )

  if ($null -eq $Process) { return $true }
  try {
    if ($Process -is [Diagnostics.Process]) { return [bool]$Process.WaitForExit($Milliseconds) }
    return [bool]$Process.HasExited
  } catch {
    return $false
  }
}

# --- Output capture -------------------------------------------------------------------------
# Not BeginOutputReadLine/OutputDataReceived: a script-block handler runs on a thread-pool thread
# that has no PowerShell runspace, and the parameterless WaitForExit() that flushes it waits for
# end-of-file on the pipe forever when a detached grandchild (an installer's helper service, say)
# inherited the pipe handles and outlives its parent. These helpers read with ReadAsync from the
# calling thread and every wait on them is bounded. A -Discard reader reads the same way but keeps
# nothing: it only keeps the pipe from filling up (output that is not captured).

function New-PipeReader {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][IO.StreamReader]$Stream,
    [switch]$Discard
  )

  return @{
    Stream  = $Stream
    Buffer  = New-Object 'char[]' 8192
    Sb      = New-Object Text.StringBuilder
    Task    = $null
    Done    = $false
    Discard = [bool]$Discard
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
    if (-not $Reader.Discard) { [void]$Reader.Sb.Append($Reader.Buffer, 0, $count) }
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
    - Standard input is a pipe that is closed right after the start, so a child that reads stdin
      (a prompt, a "press any key") gets end-of-file at once instead of waiting until its timeout,
      and never reads the operator's keys (triage 153).
    - stdout and stderr are always redirected and read concurrently (no pipe deadlock). They must be:
      with only stdin redirected, .NET would hand the child this process's own stdout, and its text
      would land on the setup screen. -CaptureOutput keeps what was read: Output is stdout followed
      by stderr. Without it the text is read and thrown away, and Output is ''.
    - On timeout the process and every descendant are force-killed; ExitCode is $null, TimedOut is
      $true, and Output holds whatever was captured before the kill.
    - A .cmd or .bat file is started through cmd.exe, because a batch file cannot be started
      directly when UseShellExecute is $false (and a path with spaces needs the extra quoting).
    - A program that cannot be started throws (the runner catches it).
    - While it waits, TimeoutMinutes is the published wait limit (Enter-SetupWait, removed again in
      the finally) and the tick runs after every slice of the wait loop, so the progress screen
      stays alive. A tick never throws (Activity.ps1).
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
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $timeoutMs = [int][Math]::Min([Math]::Ceiling($TimeoutMinutes * 60000), [double][int]::MaxValue)
  $clock = [Diagnostics.Stopwatch]::StartNew()
  Write-SetupLog -Message 'External process starting' -Data @{ file = $FilePath; args = $ArgumentList; timeoutMinutes = $TimeoutMinutes }

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  # Paired with Exit-SetupWait in the finally below, so a program that cannot start removes only
  # its own entry and never a caller's wait.
  Enter-SetupWait -LimitMinutes $TimeoutMinutes
  try {
    try {
      [void]$proc.Start()
    } catch {
      Write-SetupLog -Message 'External process failed to start' -Level ERROR -Data @{ file = $FilePath; error = $_.Exception.Message }
      throw (New-Object InvalidOperationException ("Cannot start '$FilePath': $($_.Exception.Message)", $_.Exception))
    }

    # End-of-file on stdin at once (triage 153). A failure here only costs that protection.
    try {
      $proc.StandardInput.Close()
    } catch {
      Write-SetupLog -Message 'Could not close the child''s standard input' -Level WARN -Data @{ file = $FilePath; error = $_.Exception.Message }
    }

    $stdout = New-PipeReader -Stream $proc.StandardOutput -Discard:(-not $CaptureOutput)
    $stderr = New-PipeReader -Stream $proc.StandardError -Discard:(-not $CaptureOutput)
    $readers = @($stdout, $stderr)

    $timedOut = $false
    while (-not $proc.HasExited) {
      $remaining = $timeoutMs - $clock.ElapsedMilliseconds
      if ($remaining -le 0) { $timedOut = $true; break }
      $slice = [int][Math]::Min($remaining, 200)
      if (-not (Wait-PipeReader -Reader $readers -Milliseconds $slice)) { [void]$proc.WaitForExit($slice) }
      Invoke-SetupTick
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

    if (-not (Complete-PipeReader -Reader $readers -GraceMilliseconds $drainMs)) {
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
    Exit-SetupWait
  }

  $clock.Stop()
  Write-SetupLog -Message 'External process finished' -Data @{ file = $FilePath; exitCode = $exitCode; timedOut = $timedOut; elapsedMs = $clock.ElapsedMilliseconds }
  return @{ ExitCode = $exitCode; TimedOut = $timedOut; Output = $output }
}

function Start-BackgroundExternal {
  <#
  .SYNOPSIS
    Starts a program in the background and returns its System.Diagnostics.Process at once. The
    caller owns the wait and its deadline.
  .DESCRIPTION
    The named exception to "every child goes through Invoke-External" (Global Constraints). Its callers:
    - the office step, whose Wait-OfficeBackground enforces timeoutsMinutes.office;
    - the toolbox window (repair spec 7, 10), through its StartChild seam: the Repair & diagnostics action
      child (setup.ps1 -ToolAction), whose deadline (timeoutsMinutes.tool.<id> + 3 minutes, on the run's own
      Stopwatch) the window's run timer enforces with Stop-ProcessTree, and "Open folder" (explorer.exe),
      which nobody waits for.
    - UseShellExecute = $true with a hidden window: the child gets its own (hidden) console and
      inherits no handles, so nothing it writes lands on the setup screen and the operator's keys
      never reach it.
    - .Handle is read right after the start, so ExitCode stays readable once the process has ended.
    - A program that cannot be started throws InvalidOperationException("Cannot start '<file>':
      <reason>"), like Invoke-External.
    - File, arguments and process id are logged at INFO.
  #>
  [CmdletBinding()]
  [OutputType([System.Diagnostics.Process])]
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string]$ArgumentList = ''
  )

  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = $ArgumentList
  $psi.UseShellExecute = $true
  $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  try {
    # Start() is $false when the shell reused a process instead of starting one: nothing to wait on.
    if (-not $proc.Start()) { throw (New-Object InvalidOperationException 'no new process was started') }
    $null = $proc.Handle
  } catch {
    $proc.Dispose()
    Write-SetupLog -Message 'Background process failed to start' -Level ERROR -Data @{ file = $FilePath; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    throw (New-Object InvalidOperationException ("Cannot start '$FilePath': $($_.Exception.Message)", $_.Exception))
  }

  Write-SetupLog -Message 'Background process started' -Data @{ file = $FilePath; args = $ArgumentList; processId = $proc.Id }
  return $proc
}
