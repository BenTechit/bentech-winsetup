# src/Steps/Prepare.ps1
# Step 0, "Prepare machine" (spec 8.3 and 8.5): locks down the working folder, registers the logon task
# that resumes the run after a reboot, keeps the machine awake for the whole run (lid closing does
# nothing), turns Fast Startup off, silences first-logon nag screens and stops Windows from rebooting
# on its own. Restore-FinalPowerSettings and Unregister-ResumeTask are used later by Finalize and the
# entry point. Needs StepResult.ps1, Logging.ps1 and Process.ps1.
#
# Nothing here reads localized text. The one exception is Get-PowerIndexFromQueryOutput, which takes
# only the hex values out of a `powercfg /query` listing and ignores every label around them.

$script:ResumeTaskName = 'BenTechSetup-Resume'

# powercfg is quick; two minutes is far beyond any real run and still bounds a wedged power service.
$script:PowerCfgTimeoutMinutes = 2

# LIDACTION is this tool's own addition: closing a laptop lid mid-run must not sleep it. It is set to
# 0 (do nothing) during setup and put back at the end.
$script:PowerSettingMap = @(
  @{ Name = 'STANDBYIDLE';   Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' },
  @{ Name = 'HIBERNATEIDLE'; Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364' },
  @{ Name = 'VIDEOIDLE';     Sub = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' },
  @{ Name = 'LIDACTION';     Sub = '4f971e89-eebd-4455-a8de-9e59040e7347'; Setting = '5ca83367-6e45-459f-a27b-476b1d01c936' }
)

# A desktop has no lid: its query or set may fail. That is logged and skipped, never reported.
$script:OptionalPowerSettings = @('LIDACTION')

function Invoke-PrepareTool {
  <#
  .SYNOPSIS
    Private. Runs one system tool (powercfg, icacls) through Invoke-External. Returns @{ Ok; Output }.
  .DESCRIPTION
    Ok is $true only for exit code 0 without a timeout. A timeout, a non-zero exit code or a program
    that cannot be started is a WARN in the log and Ok = $false; it never throws, because none of
    these tools may stop the step. Output is always captured, which keeps a tool's own console text
    off the progress screen; it is returned for parsing by the caller (hex values only) and logged,
    trimmed, only when the call failed.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string]$ArgumentList,
    [Parameter(Mandatory)][double]$TimeoutMinutes
  )

  try {
    $run = Invoke-External -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutMinutes $TimeoutMinutes -CaptureOutput
  } catch {
    Write-SetupLog -Message 'Tool could not be started' -Level WARN -Data @{ file = $FilePath; args = $ArgumentList; error = $_.Exception.Message }
    return @{ Ok = $false; Output = '' }
  }

  $ok = (-not $run.TimedOut) -and ($null -ne $run.ExitCode) -and ($run.ExitCode -eq 0)
  if (-not $ok) {
    $tail = ([string]$run.Output).Trim()
    if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) }
    Write-SetupLog -Message 'Tool did not succeed' -Level WARN -Data @{ file = $FilePath; args = $ArgumentList; exitCode = $run.ExitCode; timedOut = [bool]$run.TimedOut; output = $tail }
  }
  return @{ Ok = $ok; Output = [string]$run.Output }
}

function Invoke-PowerCfg {
  # Private. powercfg.exe by full path (a Hebrew PATH or a hijacked PATH cannot change what runs).
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][string]$ArgumentList)

  Invoke-PrepareTool -FilePath (Join-Path $env:windir 'System32\powercfg.exe') -ArgumentList $ArgumentList -TimeoutMinutes $script:PowerCfgTimeoutMinutes
}

function Get-PowerIndexFromQueryOutput {
  <#
  .SYNOPSIS
    Returns @{ AC = <int>; DC = <int> } from `powercfg /query SCHEME_CURRENT <sub> <setting>` output.
  .DESCRIPTION
    AC and DC are the LAST TWO 0x<8 hex digits> values in the text: the listing ends with the AC and
    then the DC index, after the Minimum/Maximum/Increment lines. Nothing else is read, so the
    labels may be in any language (Hebrew Windows). Throws 'powercfg output had no AC/DC values' for
    fewer than two values, and a distinct message for a value that does not fit an int (a wrong
    number must never be stored as the original).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Text)

  # Not \b: .NET counts Hebrew letters as word characters, so a letter next to the value would hide the boundary.
  $found = @([regex]::Matches([string]$Text, '0x[0-9a-fA-F]{8}(?![0-9a-fA-F])'))
  if ($found.Count -lt 2) { throw 'powercfg output had no AC/DC values' }

  $values = foreach ($m in $found[($found.Count - 2)..($found.Count - 1)]) {
    $n = [Convert]::ToInt64($m.Value.Substring(2), 16)
    if ($n -gt [int]::MaxValue) { throw "powercfg value out of range: $($m.Value)" }
    [int]$n
  }
  return @{ AC = [int]$values[0]; DC = [int]$values[1] }
}

function Save-OriginalPowerSettings {
  <#
  .SYNOPSIS
    Records the machine's own power settings in State.Power.Original.<Name> = @{ AC; DC } (ints).
  .DESCRIPTION
    Runs ONLY while Original is empty. After a reboot the run resumes with the setup values (0) in
    place, and capturing then would save those instead of the user's. A re-run therefore never
    captures again. A setting whose query fails is logged and left out (Restore skips what it has
    no original for). Returns $false if a required setting could not be captured; a missing
    LIDACTION (a desktop) does not count.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$State)

  if ($null -eq $State.Power) { $State.Power = @{} }
  if ($null -eq $State.Power.Original) { $State.Power.Original = @{} }
  if ($State.Power.Original.Count -gt 0) {
    Write-SetupLog -Message 'Original power settings already captured; keeping them'
    return $true
  }

  $allOk = $true
  foreach ($entry in $script:PowerSettingMap) {
    $captured = $false
    $run = Invoke-PowerCfg -ArgumentList "/query SCHEME_CURRENT $($entry.Sub) $($entry.Setting)"
    if ($run.Ok) {
      try {
        $index = Get-PowerIndexFromQueryOutput -Text $run.Output
        $State.Power.Original[$entry.Name] = @{ AC = $index.AC; DC = $index.DC }
        $captured = $true
      } catch {
        Write-SetupLog -Message 'Could not read the power setting' -Level WARN -Data @{ setting = $entry.Name; error = $_.Exception.Message }
      }
    }
    if (-not $captured -and $entry.Name -notin $script:OptionalPowerSettings) { $allOk = $false }
  }
  return $allOk
}

function Set-PowerIndexValue {
  # Private. One `powercfg /setacvalueindex|/setdcvalueindex SCHEME_CURRENT <sub> <setting> <value>`.
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][ValidateSet('AC', 'DC')][string]$Kind,
    [Parameter(Mandatory)][hashtable]$Entry,
    [Parameter(Mandatory)][int]$Value
  )

  $switch = if ($Kind -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
  $run = Invoke-PowerCfg -ArgumentList "$switch SCHEME_CURRENT $($Entry.Sub) $($Entry.Setting) $Value"
  return [bool]$run.Ok
}

function Set-SetupPowerSettings {
  <#
  .SYNOPSIS
    Keeps the machine awake for the run: every mapped setting gets AC = 0 and DC = 0, then the scheme
    is re-activated so the change applies at once.
  .DESCRIPTION
    A failed call is logged and the rest still run. Returns $false if any required call failed; a
    failing LIDACTION (a desktop) does not count.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $allOk = $true
  foreach ($entry in $script:PowerSettingMap) {
    foreach ($kind in 'AC', 'DC') {
      $ok = Set-PowerIndexValue -Kind $kind -Entry $entry -Value 0
      if (-not $ok -and $entry.Name -notin $script:OptionalPowerSettings) { $allOk = $false }
    }
  }
  if (-not (Invoke-PowerCfg -ArgumentList '/setactive SCHEME_CURRENT').Ok) { $allOk = $false }
  return $allOk
}

function Restore-FinalPowerSettings {
  <#
  .SYNOPSIS
    Puts the power settings in their final state (spec Q11), then re-activates the scheme.
  .DESCRIPTION
    On AC: sleep and hibernate stay at never (0), the display turns off after
    Config.power.finalAcMonitorMinutes, and the lid action goes back to what it was.
    On battery (DC): every setting goes back to its original value.
    A value with no captured original is skipped with a WARN rather than guessed. Every write is
    tried even if one fails. Returns $false if any write failed, or if a required setting could not
    be restored because its original was never captured (it would stay at 0, i.e. never sleep, on
    battery). A missing LIDACTION original does not count: a desktop has no lid.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)]$Config
  )

  $original = if ($null -ne $State.Power) { $State.Power.Original } else { $null }
  $monitorSeconds = [int]$Config.power.finalAcMonitorMinutes * 60

  $allOk = $true
  foreach ($entry in $script:PowerSettingMap) {
    $was = if ($null -ne $original) { $original[$entry.Name] } else { $null }

    $acValue = $null
    switch ($entry.Name) {
      'STANDBYIDLE'   { $acValue = 0 }
      'HIBERNATEIDLE' { $acValue = 0 }
      'VIDEOIDLE'     { $acValue = $monitorSeconds }
      default         { if ($null -ne $was) { $acValue = [int]$was.AC } }
    }
    # A required setting that cannot be put back is a failure, not a skip: it would stay at 0
    # (never sleep) for good, so the caller must hear about it. Only LIDACTION is exempt.
    $required = $entry.Name -notin $script:OptionalPowerSettings

    if ($null -ne $acValue) {
      if (-not (Set-PowerIndexValue -Kind AC -Entry $entry -Value $acValue)) { $allOk = $false }
    } else {
      Write-SetupLog -Message 'No original AC value to restore; skipped' -Level WARN -Data @{ setting = $entry.Name }
      if ($required) { $allOk = $false }
    }

    if ($null -ne $was) {
      if (-not (Set-PowerIndexValue -Kind DC -Entry $entry -Value ([int]$was.DC))) { $allOk = $false }
    } else {
      Write-SetupLog -Message 'No original DC value to restore; skipped' -Level WARN -Data @{ setting = $entry.Name }
      if ($required) { $allOk = $false }
    }
  }
  if (-not (Invoke-PowerCfg -ArgumentList '/setactive SCHEME_CURRENT').Ok) { $allOk = $false }
  return $allOk
}

function Get-ResumeTaskDefinition {
  <#
  .SYNOPSIS
    The parts of the resume task as @{ Execute; Argument; UserId; Settings}. Registers nothing.
  .DESCRIPTION
    Execute is powershell.exe by its full System32 path, never a bare name looked up through PATH (the
    same rule as the launcher's R30). The script path is wrapped in double quotes so a path with spaces
    stays one argument; the user id is passed through untouched (it may hold Hebrew letters). Settings:
    runs on battery and keeps running when the charger is pulled, no execution time limit, one instance
    at a time, priority 5.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$UserId
  )

  @{
    Execute  = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    Argument = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Resume"
    UserId   = $UserId
    Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 5
  }
}

function Register-ResumeTask {
  <#
  .SYNOPSIS
    Registers (or replaces) the BenTechSetup-Resume task: at every logon of the current user, elevated.
  .DESCRIPTION
    Interactive logon type with the highest run level: the run needs the user's desktop (it shows a
    window) and administrator rights. -Force replaces an older registration, so re-running the step
    is safe. Throws if Task Scheduler refuses; Invoke-StepPrepare handles that.
    Register-ScheduledTask is a CDXML cmdlet: it reports a refusal as a NON-terminating error, so it
    runs with -ErrorAction Stop (otherwise a refused registration would look like success and R15 would
    never fire). The registration is then read back with Get-ScheduledTask (-ErrorAction Stop): a task
    that is not there afterwards is a failure too.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ScriptPath)

  $userId = "$env:USERDOMAIN\$env:USERNAME"
  $def = Get-ResumeTaskDefinition -ScriptPath $ScriptPath -UserId $userId
  $action = New-ScheduledTaskAction -Execute $def.Execute -Argument $def.Argument
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $def.UserId
  $principal = New-ScheduledTaskPrincipal -UserId $def.UserId -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $script:ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $def.Settings -Force -ErrorAction Stop | Out-Null
  $null = Get-ScheduledTask -TaskName $script:ResumeTaskName -ErrorAction Stop
  Write-SetupLog -Message 'Resume task registered' -Data @{ task = $script:ResumeTaskName; user = $userId }
}

function Unregister-ResumeTask {
  <#
  .SYNOPSIS
    Removes the BenTechSetup-Resume task. Returns $true when the task is gone afterwards (removed now, or
    already absent: the normal case, Finalize may run twice), $false when it could not be removed. Never
    throws.
  .DESCRIPTION
    "Already absent" is recognized by the error's category (ObjectNotFound), never by its text, which is
    localized. Any other failure (access denied, Task Scheduler unavailable) is a WARN and $false, so the
    caller can report the leftover task (triage 250).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  try {
    Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false -ErrorAction Stop
    Write-SetupLog -Message 'Resume task removed' -Data @{ task = $script:ResumeTaskName }
    return $true
  } catch {
    if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) {
      Write-SetupLog -Message 'Resume task was not registered; nothing to remove' -Data @{ task = $script:ResumeTaskName }
      return $true
    }
    Write-SetupLog -Message 'Resume task could not be removed' -Level WARN -Data @{ task = $script:ResumeTaskName; error = $_.Exception.Message }
    return $false
  }
}

function Get-SetupFolderAclCommands {
  <#
  .SYNOPSIS
    The two icacls argument strings, in order, that lock down a C:\BenTech this run has just created
    (R28b). The launcher holds a mirror of this function; keep the two in step.
  .DESCRIPTION
      1. /setowner *S-1-5-32-544            Administrators own the folder (an owner can always change the
                                             ACL, so it must not stay the creating user's).
      2. /inheritance:r /grant:r ...        It does not inherit from C:\ (which gives Authenticated Users
                                             Modify) and grants only Administrators and SYSTEM, to itself and
                                             to everything created below it later.
    Both act on that one folder only. Nothing here may recurse or reset: a recursive owner or ACL change
    follows junctions below the folder and would change files wherever they point. An existing folder is
    therefore never repaired, only verified (Test-SetupFolderAdminOnly).
    `*S-1-5-32-544` and `*S-1-5-18` are the well-known SIDs of Administrators and SYSTEM. Group NAMES are
    localized (Hebrew Windows has other names), so a name must never be used here.
    No /C: with /C icacls exits 0 even when it failed, so a failure would go unnoticed.
    The path is quoted, and a trailing backslash is dropped because \" would escape the closing quote.
    Throws unless <Parent> is an absolute, already normalized folder below a drive root ("C:\x"): no
    drive root, no relative path (resolved against the working directory) and no "." or ".." parts.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param([Parameter(Mandatory)][string]$Parent)

  $path = $Parent.Trim().TrimEnd('\')
  if ($path -notmatch '^[A-Za-z]:\\[^\\]' -or [IO.Path]::GetFullPath($path) -ne $path) {
    throw "Refusing to lock down '$Parent': expected an absolute, normalized folder below a drive root, such as C:\BenTech."
  }
  @(
    "`"$path`" /setowner *S-1-5-32-544"
    "`"$path`" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F"
  )
}

function Test-SetupReparsePoint {
  # Private. $true when Path exists and is a junction, symlink or other reparse point. Missing is $false.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Path)

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return ($null -ne $item -and (([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))
}

function Test-SetupFolderAdminOnly {
  <#
  .SYNOPSIS
    Private. $true only when Path is admin-only in our locked state (R28b). Never throws: any doubt is $false.
  .DESCRIPTION
    All of: not a reparse point; owned by Administrators (S-1-5-32-544) or SYSTEM (S-1-5-18); does not
    inherit (AreAccessRulesProtected); and every access rule, allow or deny, explicit or inherited, is for
    Administrators or SYSTEM. Read through Get-Acl and SIDs only, so it is the same on Hebrew Windows.
    -OwnerMayBeCurrentUser (R28c) also accepts this process's own user as owner: the check right after
    New-SetupLockedDirectory, before /setowner, where the default owner can still be the creating admin.
    The launcher holds a mirror (Test-LauncherFolderAdminOnly); keep the two in step.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$OwnerMayBeCurrentUser
  )

  try {
    if (Test-SetupReparsePoint -Path $Path) { return $false }
    $allowed = @('S-1-5-32-544', 'S-1-5-18')
    $owners = @($allowed)
    if ($OwnerMayBeCurrentUser) { $owners += [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($null -eq $acl) { return $false }
    if ([string]$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $owners) { return $false }
    if ($acl.AreAccessRulesProtected -ne $true) { return $false }
    foreach ($rule in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
      if ([string]$rule.IdentityReference.Value -notin $allowed) { return $false }
    }
    return $true
  } catch {
    return $false
  }
}

function New-SetupLockedDirectory {
  <#
  .SYNOPSIS
    Private. Creates Path with its final protected DACL in the same call: full control for Administrators
    and SYSTEM, inherited by everything below, nothing inherited from above.
  .DESCRIPTION
    A folder made with New-Item under C:\ inherits Authenticated Users: Modify from C:\ until icacls runs.
    In that window a waiting non-admin process could create C:\BenTech\Setup (or keep a handle open) with
    its own permissions, which a later run's verify-only path would accept. Created this way, the folder
    is never accessible to non-admins, not even for a moment. The owner is left to the default (icacls sets
    it next), because naming an owner here needs privileges the token may not have enabled.
    The launcher holds a mirror (New-LauncherLockedDirectory); keep the two in step.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  $security = New-Object Security.AccessControl.DirectorySecurity
  $security.SetAccessRuleProtection($true, $false)
  foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
    $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList (New-Object Security.Principal.SecurityIdentifier $sid),
        ([Security.AccessControl.FileSystemRights]::FullControl), ([Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'),
        ([Security.AccessControl.PropagationFlags]::None), ([Security.AccessControl.AccessControlType]::Allow)))
  }
  $null = [IO.Directory]::CreateDirectory($Path, $security)
}

function Protect-SetupFolder {
  <#
  .SYNOPSIS
    Private. Makes sure the working folder's parent (C:\BenTech) is admin-only, fail closed (R28b). Returns
    @{ Ok = <bool>; Message = <string> }; Message is the Error text when Ok is $false. Never throws.
  .DESCRIPTION
    Verify or create; never repair, never recurse. The same sequence as the launcher's
    Protect-LauncherFolder, which normally did this already; this re-asserts it.
      1. Normalize Root, then take its parent. Get-SetupFolderAclCommands refuses a parent that is a drive
         root or not normalized (so "C:\x\..\Setup" is refused, not turned into a lockdown of C:\).
      2. Parent exists: Test-SetupFolderAdminOnly must pass, else refuse. No icacls on it, ever: it is
         either our own locked folder from an earlier run, or someone else's and refused.
      3. Parent missing: New-SetupLockedDirectory; then (R28c) it must be ours - Test-SetupFolderAdminOnly
         -OwnerMayBeCurrentUser, and the working folder must not exist in it yet - else refuse with no
         icacls; then the two Get-SetupFolderAclCommands calls to icacls (stopping at the first failure);
         then Test-SetupFolderAdminOnly as a post-condition, and the working folder still must not exist.
      4. Working folder: refuse a reparse point; create it when missing (it inherits). No icacls on it.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][double]$TimeoutMinutes
  )

  $parent = $Root   # replaced by the real parent below; only used in a message if that fails
  $failed = { param([string]$Text) @{ Ok = $false; Message = $Text } }
  try {
    $target = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $parent = Split-Path -Parent $target
    $commands = Get-SetupFolderAclCommands -Parent $parent
    $notAdminOnly = "$parent already exists and is not admin-only, so non-admin users may be able to change the setup files. Delete it (as administrator) and run setup again."
    $couldNot = "Could not make $parent admin-only, so non-admin users may be able to change the setup files"

    if ($null -ne (Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
      if (-not (Test-SetupFolderAdminOnly -Path $parent)) {
        Write-SetupLog -Level ERROR -Message 'Working folder parent exists and is not admin-only; refusing it (never repaired)' -Data @{ path = $parent }
        return (& $failed $notAdminOnly)
      }
    } else {
      New-SetupLockedDirectory -Path $parent
      # R28c: someone may have created it between "missing" and our create; CreateDirectory then neither
      # fails nor applies our security. Prove it is ours (our security descriptor, empty of the working
      # folder) before any icacls, which would otherwise tidy up their folder for them.
      if (-not (Test-SetupFolderAdminOnly -Path $parent -OwnerMayBeCurrentUser)) {
        Write-SetupLog -Level ERROR -Message 'Working folder parent was not created by this run (someone else made it first); refusing it' -Data @{ path = $parent }
        return (& $failed $notAdminOnly)
      }
      if ($null -ne (Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue)) {
        Write-SetupLog -Level ERROR -Message 'A parent created by this run already holds the working folder; refusing it' -Data @{ path = $target }
        return (& $failed $notAdminOnly)
      }
      foreach ($arguments in $commands) {
        $run = Invoke-PrepareTool -FilePath (Join-Path $env:windir 'System32\icacls.exe') -ArgumentList $arguments -TimeoutMinutes $TimeoutMinutes
        if (-not $run.Ok) {
          Write-SetupLog -Level ERROR -Message 'Working folder parent could not be locked down (icacls failed)' -Data @{ args = $arguments }
          return (& $failed $couldNot)
        }
      }
      if (-not (Test-SetupFolderAdminOnly -Path $parent)) {
        Write-SetupLog -Level ERROR -Message 'Working folder parent is still not admin-only after the lockdown' -Data @{ path = $parent }
        return (& $failed $couldNot)
      }
      if ($null -ne (Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue)) {
        Write-SetupLog -Level ERROR -Message 'A parent created by this run already holds the working folder; refusing it' -Data @{ path = $target }
        return (& $failed $notAdminOnly)
      }
    }

    if (Test-SetupReparsePoint -Path $target) {
      Write-SetupLog -Level ERROR -Message 'Working folder is a junction or symlink; refusing to use it' -Data @{ path = $target }
      return (& $failed $couldNot)
    }
    # -ErrorAction Stop without -Force: a folder that appears after the check is an error, never reused.
    if ($null -eq (Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue)) { New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null }
    return @{ Ok = $true; Message = '' }
  } catch {
    Write-SetupLog -Level ERROR -Message 'Working folder could not be secured' -Data @{ root = $Root; error = $_.Exception.Message }
    return (& $failed "Could not make $parent admin-only, so non-admin users may be able to change the setup files")
  }
}

function Set-RegistryDword {
  # Private. Creates the key if it is missing, then writes the DWord. Never throws: returns $false
  # (and logs a WARN) when the write is refused.
  # New-Item -Force on an EXISTING key can clear what the key holds, so it runs only when the key is missing.
  # Both writes use -ErrorAction Stop: the registry provider reports a refusal as a non-terminating error,
  # which the catch below would otherwise never see (final review I1).
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)]$Value
  )

  try {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value ([int]$Value) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    return $true
  } catch {
    Write-SetupLog -Message 'Registry value could not be written' -Level WARN -Data @{ path = $Path; name = $Name; error = $_.Exception.Message }
    return $false
  }
}

function Invoke-StepPrepare {
  <#
  .SYNOPSIS
    Step 0: prepares the machine for an unattended run. Returns Done('Machine prepared').
  .DESCRIPTION
    In order:
      1. Protect-SetupFolder (R28b): the working folder's parent (C:\BenTech) must be owned by
         Administrators and open only to Administrators and SYSTEM. An existing one is only verified;
         a missing one is created locked. Fail closed: a junction or symlink, a folder that is not
         admin-only, or any failing icacls is Failed('Working folder could not be secured') with an
         Error. That message wins over the resume task's, and every other stage still runs.
      2. The logon task that resumes the run after a reboot.
      3. Power: remember the original settings (first run only), then never sleep, hibernate or turn
         the display off, and ignore the lid, on AC and on battery.
      4. HiberbootEnabled = 0 (Fast Startup off, so a restart is a real restart).
      5. The first-logon nag switches from Config.nags (current user).
      6. NoAutoRebootWithLoggedOnUsers = 1 (Windows Update may not restart the machine by itself).

    Nothing in 3, 4, 5 or 6 stops the step: each failure is logged and becomes a Note. A resume
    task that cannot be registered is different, because the run could not survive a reboot. The
    registration is tried twice (ResumeTaskRetrySeconds apart, 10 by default; a test passes 0). If
    both fail, every other stage still runs, State.ResumeTaskMissing is set to $true, and the result
    is Failed('Could not register the resume task'). Invoke-ControlledReboot then refuses to restart.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [ValidateRange(0, 600)][int]$ResumeTaskRetrySeconds = 10
  )

  $notes = New-Object 'System.Collections.Generic.List[string]'
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $addNote = {
    param([string]$Text)
    if (-not $notes.Contains($Text)) { $notes.Add($Text) }
  }

  # 1. Working folder (R28): its parent admin-only, fail closed
  $folder = Protect-SetupFolder -Root $Context.Root -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.default)
  $folderSecured = ($folder -is [hashtable]) -and ($folder.Ok -eq $true)
  if (-not $folderSecured) {
    $errors.Add($(if (($folder -is [hashtable]) -and $folder.Message) { [string]$folder.Message } else { 'Could not make the working folder admin-only' }))
  }

  # 2. Resume task
  # A first failure is often transient (Task Scheduler still starting after a fresh logon), so it is
  # retried once. No break/continue here: this runs inside the runner's loops.
  $taskRegistered = $false
  for ($attempt = 1; $attempt -le 2 -and -not $taskRegistered; $attempt++) {
    try {
      Register-ResumeTask -ScriptPath $Context.ScriptPath
      $taskRegistered = $true
    } catch {
      $retrying = ($attempt -eq 1)
      Write-SetupLog -Message $(if ($retrying) { 'Resume task could not be registered; retrying once' } else { 'Resume task could not be registered' }) `
        -Level $(if ($retrying) { 'WARN' } else { 'ERROR' }) -Data @{ attempt = $attempt; error = $_.Exception.Message }
      if ($retrying -and $ResumeTaskRetrySeconds -gt 0) { Start-Sleep -Seconds $ResumeTaskRetrySeconds }
    }
  }
  if (-not $taskRegistered) {
    # Read by Invoke-ControlledReboot: a restart now would end the run for good.
    $Context.State.ResumeTaskMissing = $true
    $errors.Add('Could not register the resume task, so setup cannot continue on its own after a restart')
  }

  # 3. Power
  try {
    $captured = Save-OriginalPowerSettings -State $Context.State
    $applied = Set-SetupPowerSettings
    if (-not ($captured -and $applied)) { & $addNote 'Some power settings could not be applied' }
  } catch {
    Write-SetupLog -Message 'Power settings could not be prepared' -Level WARN -Data @{ error = $_.Exception.Message }
    & $addNote 'Some power settings could not be applied'
  }

  # 4-6. Registry
  $registryOk = $true
  if (-not (Set-RegistryDword -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0)) { $registryOk = $false }
  foreach ($nag in @($Context.Config.nags | Where-Object { $null -ne $_ })) {
    if ([string]::IsNullOrWhiteSpace([string]$nag.path) -or [string]::IsNullOrWhiteSpace([string]$nag.name)) {
      Write-SetupLog -Message 'Nag entry has no path or name; skipped' -Level WARN
      $registryOk = $false
      continue
    }
    if (-not (Set-RegistryDword -Path ([string]$nag.path) -Name ([string]$nag.name) -Value $nag.value)) { $registryOk = $false }
  }
  if (-not (Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1)) { $registryOk = $false }
  if (-not $registryOk) { & $addNote 'Some Windows settings could not be applied' }

  if (-not $folderSecured) {
    return New-StepResult -Status Failed -Message 'Working folder could not be secured' -Notes $notes.ToArray() -Errors $errors.ToArray()
  }
  if (-not $taskRegistered) {
    return New-StepResult -Status Failed -Message 'Could not register the resume task' -Notes $notes.ToArray() -Errors $errors.ToArray()
  }
  return New-StepResult -Status Done -Message 'Machine prepared' -Notes $notes.ToArray()
}
