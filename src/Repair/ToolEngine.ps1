# src/Repair/ToolEngine.ps1
# Repair & diagnostics (toolbox step 2): the engine of the action child (repair spec 7, the run model).
#
# The toolbox window runs each action in its own hidden child process: setup.ps1 -ToolAction <id> -ToolArgs
# <args.json>, started through Start-BackgroundExternal, its deadline (timeoutsMinutes.tool.<id>) enforced by the
# window's timer, which kills the process tree. Start-BenTechSetup hands that child to Invoke-SetupToolProcess, like
# -WuRound: no lock, no transcript, no QuickEdit change, no screen, no activity feed. The child never draws and never
# prompts: every question was answered in the window before it started.
#
# The files of one run live in <Root>\Tool\<RunId>\ (C:\BenTech\Setup\Tool, admin-only), never on the writable stick:
# args.json (written by the window), progress.json and result.json (by this child) and stop.flag (the window's Stop).
# The child takes those paths from the run folder, never from the args. Every JSON file is UTF-8 without a BOM,
# written to <file>.tmp and then swapped in ([IO.File]::Replace, or a move), so a reader never sees half a file.
# The action's logs and outputs go to the session folder (spec 8: <stick>\BenTech-Reports\<PC>_<serial>_<stamp>\logs,
# ruling RD-R6) or, for the info actions marked LogLocal, to the run folder.
#
# The rules (repair plan, Global Constraints):
#   - every native tool runs through Invoke-External with a timeout (Invoke-ToolNative); every cmdlet that can hang
#     runs in a bounded PowerShell grandchild that returns JSON (Invoke-ToolJsonChild);
#   - no decision comes from a tool's text: exit codes, enums, CIM, the registry, event IDs, CBS.log. The only text
#     read from a tool is DISM's percent from its redirected output, for display (Update-ToolTick), so no tool output
#     is ever captured in memory (tests\RepairStatic.Tests.ps1 pins both);
#   - Stop works only between steps (spec 4.3): a running tool ends by its own timeout or the action's deadline;
#   - every deadline is measured on a monotonic clock (ruling RD-R8): the child gets its budget in seconds
#     (BudgetSeconds in the args) and measures its elapsed time with one Stopwatch started when it begins. The wall
#     clock is never compared with anything: Standard repair's first step syncs it, and a clock hours off would end
#     the run early. DeadlineUtc is kept for the log only;
#   - a step timeout is capped by the time the action has left, so the child stops before the window kills it;
#   - progress.json, result.json and the child's log are English and ASCII (ConvertTo-ScreenText on every free value):
#     the customer complaint in the args is never logged. The one exception is a display-only name (a ghost device's,
#     a network adapter's; ruling RD-R21): it keeps its real text (ConvertTo-ToolDisplayText) and every JSON file is
#     written in ASCII bytes with \uXXXX escapes (ConvertTo-ToolAsciiJson), so the window shows Hebrew; no decision
#     reads such a name, and a log line takes ConvertTo-ScreenText of it;
#   - nothing waits without a deadline; no sleep, no prompt, no console text in this file.
#
# Needs Logging (Write-SetupLog, Initialize-SetupLog), Activity (Read-FileTail, Register-SetupTick), Process
# (Invoke-External), Winget (Invoke-PowerShellChild, ConvertTo-PowerShellLiteral), Config (Read-SetupConfig), State
# (ConvertTo-HashtableDeep), Reboot (Get-ServicingRebootSignals), StartScreen (ConvertTo-ScreenText,
# $script:DirectionMarksPattern), Strings
# ($script:ToolboxStrings) and Cleanup (Test-StickReparsePoint). The bundle holds every file.

# The actions and their steps (repair plan, "Actions and steps"). Each task adds its own rows:
#   $script:ToolActionCatalog['<id>'] = @{ Kind = 'info'|'readonly'|'repair'|'destructive'; Confirm = 'none'|'confirm'|'yes';
#                                          NeedsStick = <bool>; LogLocal = <bool>; Steps = [string[]] }
#   $script:ToolSteps['<stepId>'] = @{ Function = 'Invoke-ToolStep<StepId with its first letter upper-cased>';
#                                      Servicing = <bool: re-checked for a pending servicing restart first>;
#                                      AlwaysRun = <bool, optional: runs even after a Stop, an Abort or the deadline> }
# A step function takes -Run <hashtable> and returns exactly one of 'done', 'warn', 'failed', 'skipped' (or
# 'timedout'); findings go through Add-ToolFinding, shared data into $Run.Data. A step that sets $Run.Data.Abort to
# $true ends its action after it, like a Stop (Task 7: no verified backup, no reset).
#
# Task 2: safety (the strip, computed in this child: spec 5; ToolSafety.ps1) and health (the read-only Health check:
# spec 6.1; ToolChecks.ps1). Neither has a servicing step: read-only actions run with a restart pending (spec 5).
# The Health check reads the disk state (volumeState, Get-Volume); volumeScan (Repair-Volume -Scan, which can fix
# online) is Standard repair's and Post-clone's (ruling RD-R12; Task 6 adds those actions).
#
# Task 6: standard (spec 6.2: the kit's order), postClone (spec 6.3: standard's five, then the post-clone steps; devices
# and activation are the Health check's own steps) and dismSource (the DISM retry with the local source the technician
# picked from the offer, then SFC; builder check 6), in ToolRepairs.ps1. Their servicing steps (dism, sfc,
# componentCleanup, dismSource) are re-checked for a pending servicing restart first (spec 5).
#
# Task 7: the advanced tools in ToolAdvanced.ps1 (spec 6.4 to 6.7): wuReset (its wuServicesStart always runs, so the
# update services never stay stopped: review I-2; then Task 6's wuScan), diskCheck (the dirty bit; ruling RD-R1: no
# cancel), netInfo and ghostList (the info children the Network reset and Ghost devices confirmations wait for: they
# log locally), netReset (netBackup first: no verified backup on the stick, no reset), netRestore and ghostRemove
# (ghostCsv first: no saved list, nothing removed). The safety child also names this PC's newest saved network
# backup on the stick (safetyNetBackup), for the Restore network settings button.
#
# Task 8: quickReport and fullReport (spec 6.8): one step per report section (report01 ... report12, ToolCollect.ps1:
# each stores its section in $Run.Data.Report), then reportWrite (ToolReport.ps1: the AI-ready core, the data JSON and
# raw_<stamp>\ on the stick) and, Full only, reportZip. reportWrite always runs: a report stopped or out of time still
# writes what it collected, and names the sections it did not reach.
$script:ToolActionCatalog = [ordered]@{
  safety     = @{ Kind = 'info'; Confirm = 'none'; NeedsStick = $false; LogLocal = $true
                  Steps = [string[]]@('safetyRestart', 'safetyFree', 'safetyBitLocker', 'safetyInternet', 'safetyDisk', 'safetyDiskCheck', 'safetyNetBackup') }
  health     = @{ Kind = 'readonly'; Confirm = 'none'; NeedsStick = $false; LogLocal = $false
                  Steps = [string[]]@('volumeState', 'imageCheck', 'imageScan', 'sfcVerify', 'winre', 'devices', 'activation') }
  standard   = @{ Kind = 'repair'; Confirm = 'confirm'; NeedsStick = $false; LogLocal = $false
                  Steps = [string[]]@('timeSync', 'volumeScan', 'dism', 'sfc', 'winreFix') }
  postClone  = @{ Kind = 'repair'; Confirm = 'confirm'; NeedsStick = $false; LogLocal = $false
                  Steps = [string[]]@('timeSync', 'volumeScan', 'dism', 'sfc', 'winreFix', 'pnpScan', 'devices', 'oemLeftovers', 'pageFile', 'trim',
                                      'activation', 'componentCleanup', 'wuScan') }
  dismSource = @{ Kind = 'repair'; Confirm = 'confirm'; NeedsStick = $false; LogLocal = $false
                  Steps = [string[]]@('dismSource', 'sfc') }
  wuReset     = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $false; LogLocal = $false
                   Steps = [string[]]@('wuServicesStop', 'wuRename', 'wuBits', 'wuServicesStart', 'wuScan') }
  diskCheck   = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $false; LogLocal = $false
                   Steps = [string[]]@('diskCheckSchedule') }
  netInfo     = @{ Kind = 'info'; Confirm = 'none'; NeedsStick = $false; LogLocal = $true
                   Steps = [string[]]@('netInfo') }
  netReset    = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $true; LogLocal = $false
                   Steps = [string[]]@('netBackup', 'winsockReset', 'ipReset', 'ipv6Reset', 'dnsFlush') }
  netRestore  = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $true; LogLocal = $false
                   Steps = [string[]]@('netRestore') }
  ghostList   = @{ Kind = 'info'; Confirm = 'none'; NeedsStick = $true; LogLocal = $true
                   Steps = [string[]]@('ghostList') }
  ghostRemove = @{ Kind = 'destructive'; Confirm = 'yes'; NeedsStick = $true; LogLocal = $false
                   Steps = [string[]]@('ghostCsv', 'ghostRemove') }
  quickReport = @{ Kind = 'readonly'; Confirm = 'none'; NeedsStick = $true; LogLocal = $false
                   Steps = [string[]]@('report01', 'report02', 'report03', 'report04', 'report05', 'report06', 'report07', 'report08', 'report09', 'report10',
                                       'report11', 'reportWrite') }
  fullReport  = @{ Kind = 'readonly'; Confirm = 'none'; NeedsStick = $true; LogLocal = $false
                   Steps = [string[]]@('report01', 'report02', 'report03', 'report04', 'report05', 'report06', 'report07', 'report08', 'report09', 'report10',
                                       'report11', 'report12', 'reportWrite', 'reportZip') }
}
$script:ToolSteps = @{
  safetyRestart    = @{ Function = 'Invoke-ToolStepSafetyRestart'; Servicing = $false }
  safetyFree       = @{ Function = 'Invoke-ToolStepSafetyFree'; Servicing = $false }
  safetyBitLocker  = @{ Function = 'Invoke-ToolStepSafetyBitLocker'; Servicing = $false }
  safetyInternet   = @{ Function = 'Invoke-ToolStepSafetyInternet'; Servicing = $false }
  safetyDisk       = @{ Function = 'Invoke-ToolStepSafetyDisk'; Servicing = $false }
  safetyDiskCheck  = @{ Function = 'Invoke-ToolStepSafetyDiskCheck'; Servicing = $false }
  volumeState      = @{ Function = 'Invoke-ToolStepVolumeState'; Servicing = $false }
  volumeScan       = @{ Function = 'Invoke-ToolStepVolumeScan'; Servicing = $false }
  imageCheck       = @{ Function = 'Invoke-ToolStepImageCheck'; Servicing = $false }
  imageScan        = @{ Function = 'Invoke-ToolStepImageScan'; Servicing = $false }
  sfcVerify        = @{ Function = 'Invoke-ToolStepSfcVerify'; Servicing = $false }
  winre            = @{ Function = 'Invoke-ToolStepWinre'; Servicing = $false }
  devices          = @{ Function = 'Invoke-ToolStepDevices'; Servicing = $false }
  activation       = @{ Function = 'Invoke-ToolStepActivation'; Servicing = $false }
  timeSync         = @{ Function = 'Invoke-ToolStepTimeSync'; Servicing = $false }
  dism             = @{ Function = 'Invoke-ToolStepDism'; Servicing = $true }
  sfc              = @{ Function = 'Invoke-ToolStepSfc'; Servicing = $true }
  winreFix         = @{ Function = 'Invoke-ToolStepWinreFix'; Servicing = $false }
  pnpScan          = @{ Function = 'Invoke-ToolStepPnpScan'; Servicing = $false }
  oemLeftovers     = @{ Function = 'Invoke-ToolStepOemLeftovers'; Servicing = $false }
  pageFile         = @{ Function = 'Invoke-ToolStepPageFile'; Servicing = $false }
  trim             = @{ Function = 'Invoke-ToolStepTrim'; Servicing = $false }
  componentCleanup = @{ Function = 'Invoke-ToolStepComponentCleanup'; Servicing = $true }
  wuScan           = @{ Function = 'Invoke-ToolStepWuScan'; Servicing = $false }
  dismSource       = @{ Function = 'Invoke-ToolStepDismSource'; Servicing = $true }
  safetyNetBackup   = @{ Function = 'Invoke-ToolStepSafetyNetBackup'; Servicing = $false }
  wuServicesStop    = @{ Function = 'Invoke-ToolStepWuServicesStop'; Servicing = $false }
  wuRename          = @{ Function = 'Invoke-ToolStepWuRename'; Servicing = $false }
  wuBits            = @{ Function = 'Invoke-ToolStepWuBits'; Servicing = $false }
  wuServicesStart   = @{ Function = 'Invoke-ToolStepWuServicesStart'; Servicing = $false; AlwaysRun = $true }
  diskCheckSchedule = @{ Function = 'Invoke-ToolStepDiskCheckSchedule'; Servicing = $false }
  netInfo           = @{ Function = 'Invoke-ToolStepNetInfo'; Servicing = $false }
  netBackup         = @{ Function = 'Invoke-ToolStepNetBackup'; Servicing = $false }
  winsockReset      = @{ Function = 'Invoke-ToolStepWinsockReset'; Servicing = $false }
  ipReset           = @{ Function = 'Invoke-ToolStepIpReset'; Servicing = $false }
  ipv6Reset         = @{ Function = 'Invoke-ToolStepIpv6Reset'; Servicing = $false }
  dnsFlush          = @{ Function = 'Invoke-ToolStepDnsFlush'; Servicing = $false }
  netRestore        = @{ Function = 'Invoke-ToolStepNetRestore'; Servicing = $false }
  ghostList         = @{ Function = 'Invoke-ToolStepGhostList'; Servicing = $false }
  ghostCsv          = @{ Function = 'Invoke-ToolStepGhostCsv'; Servicing = $false }
  ghostRemove       = @{ Function = 'Invoke-ToolStepGhostRemove'; Servicing = $false }
  report01          = @{ Function = 'Invoke-ToolStepReport01'; Servicing = $false }
  report02          = @{ Function = 'Invoke-ToolStepReport02'; Servicing = $false }
  report03          = @{ Function = 'Invoke-ToolStepReport03'; Servicing = $false }
  report04          = @{ Function = 'Invoke-ToolStepReport04'; Servicing = $false }
  report05          = @{ Function = 'Invoke-ToolStepReport05'; Servicing = $false }
  report06          = @{ Function = 'Invoke-ToolStepReport06'; Servicing = $false }
  report07          = @{ Function = 'Invoke-ToolStepReport07'; Servicing = $false }
  report08          = @{ Function = 'Invoke-ToolStepReport08'; Servicing = $false }
  report09          = @{ Function = 'Invoke-ToolStepReport09'; Servicing = $false }
  report10          = @{ Function = 'Invoke-ToolStepReport10'; Servicing = $false }
  report11          = @{ Function = 'Invoke-ToolStepReport11'; Servicing = $false }
  report12          = @{ Function = 'Invoke-ToolStepReport12'; Servicing = $false }
  reportWrite       = @{ Function = 'Invoke-ToolStepReportWrite'; Servicing = $false; AlwaysRun = $true }
  reportZip         = @{ Function = 'Invoke-ToolStepReportZip'; Servicing = $false }
}

# A failed progress write, or a failed tick, is logged once per run (New-ToolRun resets both).
$script:ToolProgressWarned = $false
$script:ToolTickWarned = $false

# The Data keys that stay in the child: the report sections (Task 8) are written to the report files on the stick, and
# result.json holds only the summary and the paths (ruling RD-R21: the window reads a result.json over 1 MB as no
# result); the signed-in user the report read (a name and a SID) is in the report files only.
$script:ToolResultHiddenData = @('Report', 'ReportUser')

# The read cap of a report's _data.json (ruling RD-R23): Compare (Task 9) reads it with this, not with the 1 MB of the
# exchange files.
$script:ToolReportDataMaxBytes = 16MB

# --- Texts ------------------------------------------------------------------------------------------------------

function Get-ToolText {
  <#
  .SYNOPSIS
    The English text of a string-table key ($script:ToolboxStrings.en), formatted with -Arguments in the invariant
    culture and made ASCII (ConvertTo-ScreenText). The key itself when it is missing or cannot be formatted (too few
    arguments). Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Key,
    [AllowNull()][object[]]$Arguments
  )

  try {
    $table = $script:ToolboxStrings['en']
    if ($null -eq $table -or -not $table.ContainsKey($Key)) { return (ConvertTo-ScreenText -Text $Key) }
    # A real object[]: a string[] passed on as it is would bind to Format's single-object overload.
    $count = 0
    if ($null -ne $Arguments) { $count = $Arguments.Count }
    $values = New-Object 'object[]' $count
    for ($i = 0; $i -lt $count; $i++) { $values[$i] = $Arguments[$i] }
    return (ConvertTo-ScreenText -Text ([string]::Format([Globalization.CultureInfo]::InvariantCulture, [string]$table[$Key], $values)))
  } catch {
    return (ConvertTo-ScreenText -Text $Key)
  }
}

function Get-ToolStepName {
  # Private. A step's English name (tool.step.<id> in the string table, Task 3), else the id itself. ASCII.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Id)

  $key = 'tool.step.' + $Id
  $table = $null
  if ($script:ToolboxStrings -is [System.Collections.IDictionary]) { $table = $script:ToolboxStrings['en'] }
  if ($table -is [System.Collections.IDictionary] -and $table.Contains($key)) { return (Get-ToolText -Key $key) }
  return (ConvertTo-ScreenText -Text $Id)
}

# --- JSON files ---------------------------------------------------------------------------------------------------

function ConvertTo-ToolAsciiJson {
  <#
  .SYNOPSIS
    -Json with every character outside printable ASCII written as a \uXXXX escape (UTF-16 code units, so a surrogate
    pair becomes two escapes), the rest unchanged. Pure. Ruling RD-R21.
  .DESCRIPTION
    JSON is ASCII outside its strings, so this is the same JSON in ASCII bytes: a display-only name keeps its real
    (Hebrew) text through progress.json and result.json, and ConvertFrom-Json gives it back. Layout characters (new
    lines, indentation) are printable or below 0x20 and stay; ConvertTo-Json has already escaped the control
    characters inside strings.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Json)

  if ([string]::IsNullOrEmpty($Json)) { return [string]$Json }
  return [regex]::Replace($Json, '[^\x00-\x7E]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

function ConvertFrom-ToolJsonHtmlEscapes {
  <#
  .SYNOPSIS
    -Json with the four escapes Windows PowerShell 5.1's ConvertTo-Json always writes (backslash-u and the hex code
    of the ampersand 0026, the apostrophe 0027 and the angle brackets 003c and 003e) turned back into their characters,
    so a file Ben reads shows them (ruling RD-R23). Pure.
  .DESCRIPTION
    Only an escape whose backslash is not itself escaped is turned back (an even run of backslashes before it), so a
    value that holds such an escape as text (its backslash doubled in the JSON) stays as it is. The four characters
    need no escape in a JSON string; the JSON means the same.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Json)

  if ([string]::IsNullOrEmpty($Json)) { return [string]$Json }
  return [regex]::Replace($Json, '(?<!\\)((?:\\\\)*)\\u00(26|27|3[cCeE])', {
      param($m)
      $m.Groups[1].Value + [string][char][Convert]::ToInt32($m.Groups[2].Value, 16)
    })
}

function ConvertTo-ToolDisplayText {
  <#
  .SYNOPSIS
    A display-only name (a device's, an adapter's, a report value's) with its real text kept for the window and the
    report (RD-R21): the direction marks Hebrew Windows adds are dropped ($script:DirectionMarksPattern, StartScreen),
    every control character becomes a space, the ends are trimmed, and it is cut to -MaxLength UTF-16 code units,
    never between the two halves of a surrogate pair. $null is ''. No decision may read it; a log line still takes
    ConvertTo-ScreenText of it.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()]$Text,
    [Parameter(Mandatory)][ValidateRange(1, 4096)][int]$MaxLength
  )

  if ($null -eq $Text) { return '' }
  $value = [regex]::Replace([string]$Text, $script:DirectionMarksPattern, '')
  $value = ([regex]::Replace($value, '[\x00-\x1F\x7F]', ' ')).Trim()
  if ($value.Length -le $MaxLength) { return $value }
  $cut = $MaxLength
  if ([char]::IsHighSurrogate($value[$cut - 1])) { $cut-- }
  return $value.Substring(0, $cut)
}

function Save-ToolJsonFile {
  # Private. Writes -InputObject as JSON (UTF-8 without a BOM) to <Path>.tmp, then swaps it in: [IO.File]::Replace over
  # an existing file ([NullString]::Value, because PowerShell would pass '' for $null), else a move. Folders are not
  # created. Throws on failure; Write-ToolJsonFile, Write-ToolProgress and Write-ToolResult catch.
  # The window/child exchange files (args, progress, result) are ASCII bytes (ConvertTo-ToolAsciiJson, RD-R21). -Utf8
  # (ruling RD-R23) is for the files Ben reads on the stick (a report's _data.json): their text stays as it is, so a
  # Hebrew letter is two bytes and Notepad shows it, never a \uXXXX escape.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowNull()]$InputObject,
    [int]$Depth = 8,
    [switch]$Utf8
  )

  $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
  if ($Utf8) { $json = ConvertFrom-ToolJsonHtmlEscapes -Json $json } else { $json = ConvertTo-ToolAsciiJson -Json $json }
  $temporary = $Path + '.tmp'
  [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding $false))
  if ([IO.File]::Exists($Path)) {
    [IO.File]::Replace($temporary, $Path, [NullString]::Value)
  } else {
    [IO.File]::Move($temporary, $Path)
  }
}

function Write-ToolJsonFile {
  <#
  .SYNOPSIS
    Writes -InputObject as JSON (depth 8 by default, UTF-8 without a BOM, in ASCII bytes: a character outside ASCII is
    a \uXXXX escape, RD-R21) through <Path>.tmp, so a reader never sees half a file. $true when written; a failure is
    a WARN in the log and $false. Never throws.
  .DESCRIPTION
    -Utf8 (ruling RD-R23): plain UTF-8 text, no escapes, for the files Ben reads on the stick (a report's _data.json).
    The exchange files between the window and the child (args, progress, result) never take it.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowNull()]$InputObject,
    [ValidateRange(1, 100)][int]$Depth = 8,
    [switch]$Utf8
  )

  try {
    Save-ToolJsonFile -Path $Path -InputObject $InputObject -Depth $Depth -Utf8:$Utf8
    return $true
  } catch {
    Write-SetupLog -Level WARN -Message 'Could not write a tool JSON file' -Data @{
      path = (ConvertTo-ScreenText -Text $Path); error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    return $false
  }
}

function Read-ToolJsonFile {
  <#
  .SYNOPSIS
    Reads a JSON object file as a hashtable (ConvertTo-HashtableDeep). $null when the file is missing, empty, over
    -MaxBytes (1 MB), not JSON, or not a JSON object. Never throws.
  .DESCRIPTION
    Opened with FileShare ReadWrite + Delete, so the writer can swap a new version in while this reads (the window
    polls progress.json every 500 ms). Decoded as UTF-8, with or without a BOM: the ASCII exchange files (RD-R21) and
    the plain UTF-8 files on the stick (RD-R23) alike. 1 MB is the cap of the exchange files; a reader of a report's
    _data.json (Compare, Task 9) passes -MaxBytes $script:ToolReportDataMaxBytes (16 MB).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
    [ValidateRange(1, 104857600)][long]$MaxBytes = 1MB
  )

  $stream = $null
  try {
    if ([string]::IsNullOrEmpty($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    if ($stream.Length -le 0 -or $stream.Length -gt $MaxBytes) { return $null }
    $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding $false), $true)
    $text = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    if ($parsed -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    return (ConvertTo-HashtableDeep -InputObject $parsed)
  } catch {
    return $null
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

# --- The args -----------------------------------------------------------------------------------------------------

function ConvertFrom-ToolDeadline {
  # Private. DeadlineUtc (a round-trip 'o' date) as a UTC [datetime]. A date without a zone is taken as UTC (the
  # name says so); one with an offset is converted. Throws when it is not a round-trip date.
  [CmdletBinding()]
  [OutputType([datetime])]
  param([AllowNull()]$Value)

  $parsed = [datetime]::MinValue
  if ($Value -is [datetime]) {
    $parsed = $Value
  } elseif ($Value -isnot [string] -or -not [datetime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
    throw 'The deadline is not a round-trip date'
  }
  if ($parsed.Kind -eq [DateTimeKind]::Local) { return $parsed.ToUniversalTime() }
  return [datetime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
}

function Read-ToolArgs {
  <#
  .SYNOPSIS
    Reads and checks the window's args.json for -ActionId. Returns the args as a hashtable; throws with an ASCII
    message on anything invalid.
  .DESCRIPTION
    - The path is fully qualified, and its full path is <Root>\Tool\<one folder>\args.json (case-insensitive), so
      the child reads nothing outside the admin-only Tool folder; neither that folder nor Tool is a reparse point.
    - The JSON is an object under 1 MB.
    - Action is text, -ceq -ActionId, and an action of $script:ToolActionCatalog (case-sensitive).
    - RunId matches ^[0-9]{8}-[0-9]{6}-[A-Za-z]{2,20}$ and names the run folder (the window creates
      <Root>\Tool\<RunId>\, and the child derives its files from it).
    - BudgetSeconds (the action's whole time, which the child measures on its own Stopwatch, ruling RD-R8) is a
      number above 0 and at most 7 days; DeadlineUtc (for the log only) is a round-trip date.
    - SessionDir is fully qualified or empty (missing = ''); Complaint is text of at most 2000 characters
      (missing = ''); Options is an object (missing = @{}).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Path,
    [Parameter(Mandatory)][string]$Root,
    [AllowNull()][AllowEmptyString()][string]$ActionId
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'No args file was given' }
  if ($Path -notmatch '^[A-Za-z]:\\') { throw 'The args path is not fully qualified' }
  try {
    $full = [IO.Path]::GetFullPath($Path)
    $toolDir = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, 'Tool')).TrimEnd('\')
  } catch {
    throw 'The args path is not a valid path'
  }
  $runDir = [IO.Path]::GetDirectoryName($full)
  $inTool = (-not [string]::IsNullOrEmpty($runDir)) -and
    [string]::Equals([IO.Path]::GetFileName($full), 'args.json', [StringComparison]::OrdinalIgnoreCase) -and
    [string]::Equals([IO.Path]::GetDirectoryName($runDir), $toolDir, [StringComparison]::OrdinalIgnoreCase)
  if (-not $inTool) { throw 'The args file is not <Root>\Tool\<run>\args.json' }
  try {
    $isLink = (Test-StickReparsePoint -Path $toolDir) -or (Test-StickReparsePoint -Path $runDir)
  } catch {
    throw 'The run folder could not be checked'
  }
  if ($isLink) { throw 'The run folder or the Tool folder is a link' }

  $data = Read-ToolJsonFile -Path $full -MaxBytes 1MB
  if ($null -eq $data) { throw 'args.json is missing, over 1 MB or not a JSON object' }

  $action = $data['Action']
  if ($action -isnot [string] -or -not [string]::Equals($action, [string]$ActionId, [StringComparison]::Ordinal)) {
    throw ('The args are for another action ({0})' -f (ConvertTo-ScreenText -Text ([string]$action)))
  }
  if (@($script:ToolActionCatalog.Keys) -cnotcontains $action) {
    throw ("'{0}' is not a tool action" -f (ConvertTo-ScreenText -Text $action))
  }
  $runId = $data['RunId']
  if ($runId -isnot [string] -or $runId -notmatch '^[0-9]{8}-[0-9]{6}-[A-Za-z]{2,20}\z') { throw 'The RunId is not valid' }
  if (-not [string]::Equals([IO.Path]::GetFileName($runDir), $runId, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The run folder is not named after the RunId'
  }
  $null = ConvertFrom-ToolDeadline -Value $data['DeadlineUtc']
  $budget = $data['BudgetSeconds']
  # A JSON number comes back as Int32, Int64 or Decimal (Windows PowerShell 5.1); text is refused.
  if (-not ($budget -is [int] -or $budget -is [long] -or $budget -is [double] -or $budget -is [decimal]) -or
      [double]$budget -le 0 -or [double]$budget -gt 604800) {
    throw 'BudgetSeconds is not a number of seconds above 0 and at most 7 days'
  }
  $data['BudgetSeconds'] = [double]$budget

  $session = $data['SessionDir']
  if ($null -eq $session) { $session = '' }
  if ($session -isnot [string] -or ($session -ne '' -and $session -notmatch '^[A-Za-z]:\\')) { throw 'SessionDir is not a fully qualified path' }
  $data['SessionDir'] = $session

  $complaint = $data['Complaint']
  if ($null -eq $complaint) { $complaint = '' }
  if ($complaint -isnot [string]) { throw 'Complaint is not text' }
  if ($complaint.Length -gt 2000) { throw 'Complaint is over 2000 characters' }
  $data['Complaint'] = $complaint

  $options = $data['Options']
  if ($null -eq $options) { $options = @{} }
  if ($options -isnot [System.Collections.IDictionary]) { throw 'Options is not an object' }
  $data['Options'] = $options
  return $data
}

# --- The run ------------------------------------------------------------------------------------------------------

function New-ToolRun {
  <#
  .SYNOPSIS
    The in-memory run of one action, from its checked args (Read-ToolArgs).
  .DESCRIPTION
    @{ Args; Config; Root; Dir = <Root>\Tool\<RunId>; ProgressPath; ResultPath; StopPath (in Dir); LogDir = Dir
       (New-ToolSessionDir moves it); SessionDir = $null; Deadline (UTC [datetime], from DeadlineUtc: for the log
       only); BudgetSeconds (from the args); Clock (the run's Stopwatch: -Clock, which Invoke-SetupToolProcess starts
       when the child begins, else one started now; every deadline is measured on it, ruling RD-R8);
       Steps = List of @{ Id; Status = 'pending'; Percent = $null } (the catalog's steps of the action);
       Current = -1; Findings = List; Log = List (the last 12 lines); Data = @{}; Partial = @{};
       RestartRequired = $false; Offers = @{ DiskCheck = $false; DismSource = $null }; Files = @{};
       OutputPath = $null (the tool output the tick reads); StartedAt (local [datetime]) }
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$ToolArgs,
    [Parameter(Mandatory)][AllowNull()]$Config,
    [Parameter(Mandatory)][string]$Root,
    [Diagnostics.Stopwatch]$Clock
  )

  if ($null -eq $Clock) { $Clock = [Diagnostics.Stopwatch]::StartNew() }
  $budget = 0.0
  if ($null -ne $ToolArgs['BudgetSeconds']) { $budget = [double]$ToolArgs['BudgetSeconds'] }
  $dir = [IO.Path]::Combine($Root, 'Tool', [string]$ToolArgs['RunId'])
  $steps = New-Object System.Collections.Generic.List[object]
  $entry = $script:ToolActionCatalog[[string]$ToolArgs['Action']]
  if ($null -ne $entry) {
    foreach ($id in $entry['Steps']) { $steps.Add(@{ Id = [string]$id; Status = 'pending'; Percent = $null }) }
  }
  $script:ToolProgressWarned = $false
  $script:ToolTickWarned = $false
  return @{
    Args            = $ToolArgs
    Config          = $Config
    Root            = $Root
    Dir             = $dir
    ProgressPath    = [IO.Path]::Combine($dir, 'progress.json')
    ResultPath      = [IO.Path]::Combine($dir, 'result.json')
    StopPath        = [IO.Path]::Combine($dir, 'stop.flag')
    LogDir          = $dir
    SessionDir      = $null
    Deadline        = (ConvertFrom-ToolDeadline -Value $ToolArgs['DeadlineUtc'])
    BudgetSeconds   = $budget
    Clock           = $Clock
    Steps           = $steps
    Current         = -1
    Findings        = (New-Object System.Collections.Generic.List[object])
    Log             = (New-Object System.Collections.Generic.List[string])
    Data            = @{}
    Partial         = @{}
    RestartRequired = $false
    Offers          = @{ DiskCheck = $false; DismSource = $null }
    Files           = @{}
    OutputPath      = $null
    StartedAt       = (Get-Date)
  }
}

function New-ToolSessionDir {
  <#
  .SYNOPSIS
    Creates the session folder Args.SessionDir and its logs\ (spec 8), points $Run.LogDir at that logs\ and returns
    the folder used (also $Run.SessionDir and $Run.Files.Folder). Never writes through a link.
  .DESCRIPTION
    When <stick>\BenTech-Reports (the parent of SessionDir), the session folder or its logs\ is a reparse point
    (Test-StickReparsePoint, before and again after the creation), or the creation fails, nothing more is done on the
    stick: the folder used is <Root>\Logs\Repair\<leaf> (the leaf reduced to [A-Za-z0-9_-]), named by a WARN
    finding: sessionLink for a link (V2-R13), sessionCreateFailed (with the reason) when the folder could not be
    created (a pulled or write-protected stick). An empty SessionDir uses that local folder without a finding. If
    even the local folder cannot be made, the run folder is used. $Run.Data.SessionIsLocal is $true unless the folder
    used is the one the window asked for on the stick (Args.StickRoot): the network backup and the ghost CSV refuse a
    local one.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $wanted = [string]$Run.Args['SessionDir']
  $leaf = ''
  if ($wanted -ne '') {
    try { $leaf = [IO.Path]::GetFileName($wanted.TrimEnd('\')) } catch { $leaf = '' }
  }
  $leaf = $leaf -replace '[^A-Za-z0-9_-]', '_'
  if ($leaf.Trim('_') -eq '') { $leaf = [string]$Run.Args['RunId'] }
  $local = [IO.Path]::Combine($Run.Root, 'Logs', 'Repair', $leaf)

  $used = $null
  $problem = $null
  $isLink = $false
  if ($wanted -ne '') {
    try {
      $reports = [IO.Path]::GetDirectoryName($wanted.TrimEnd('\'))
      $logs = [IO.Path]::Combine($wanted, 'logs')
      if ((Test-StickReparsePoint -Path $reports) -or (Test-StickReparsePoint -Path $wanted)) {
        $isLink = $true
        $problem = 'BenTech-Reports or the session folder is a link'
      } else {
        [void][IO.Directory]::CreateDirectory($logs)
        # Checked again once the folders exist: a link put in place meanwhile is never written through.
        if ((Test-StickReparsePoint -Path $reports) -or (Test-StickReparsePoint -Path $wanted) -or (Test-StickReparsePoint -Path $logs)) {
          $isLink = $true
          $problem = 'BenTech-Reports or the session folder is a link'
        } else {
          $used = $wanted
        }
      }
    } catch {
      $problem = $_.Exception.Message
    }
  }

  $fellBack = $false
  if ($null -eq $used) {
    $fellBack = ($wanted -ne '')
    try {
      [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($local, 'logs'))
      $used = $local
    } catch {
      Write-SetupLog -Level WARN -Message 'Could not create the local session folder; using the run folder' -Data @{
        folder = $local; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
      $used = $Run.Dir
    }
    if ($fellBack) {
      Write-SetupLog -Level WARN -Message 'The session folder on the stick was not used; the files stay on this PC' -Data @{
        wanted = (ConvertTo-ScreenText -Text $wanted); used = (ConvertTo-ScreenText -Text $used); reason = (ConvertTo-ScreenText -Text $problem) }
      if ($isLink) {
        Add-ToolFinding -Run $Run -Level WARN -Code 'sessionLink' -Arguments @($used)
      } else {
        Add-ToolFinding -Run $Run -Level WARN -Code 'sessionCreateFailed' -Arguments @($problem, $used)
      }
    }
  }

  $Run.SessionDir = $used
  $Run.LogDir = if ($used -eq $Run.Dir) { $Run.Dir } else { [IO.Path]::Combine($used, 'logs') }
  $Run.Files['Folder'] = $used
  $stickRoot = [string]$Run.Args['StickRoot']
  $onStick = (-not $fellBack) -and $used -eq $wanted -and $stickRoot -ne '' -and $used.StartsWith($stickRoot, [StringComparison]::OrdinalIgnoreCase)
  $Run.Data['SessionIsLocal'] = (-not $onStick)
  return $used
}

function Add-ToolFinding {
  <#
  .SYNOPSIS
    Adds a finding to the run: @{ Level; Code; Text = the English finding.<Code> text; Args = [string[]] (ASCII) }.
    The window shows finding.<Code> from the string table in its own language, with the same Args.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][ValidateSet('CRIT', 'WARN', 'INFO')][string]$Level,
    [Parameter(Mandatory)][string]$Code,
    [AllowNull()][object[]]$Arguments
  )

  $values = [string[]]@()
  if ($null -ne $Arguments) { $values = [string[]]@(foreach ($a in $Arguments) { ConvertTo-ScreenText -Text $a }) }
  $text = Get-ToolText -Key ('finding.' + $Code) -Arguments $values
  $Run.Findings.Add([ordered]@{ Level = $Level; Code = $Code; Text = $text; Args = $values })
  Write-SetupLog -Message ('Finding {0} {1}: {2}' -f $Level, $Code, $text)
}

function Test-ToolFindingCode {
  # Private. $true when the run already has a finding with -Code.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$Code)

  foreach ($finding in $Run.Findings) { if ([string]$finding['Code'] -ceq $Code) { return $true } }
  return $false
}

function Add-ToolLog {
  <#
  .SYNOPSIS
    One line for the window's run log (ASCII): an INFO line in the child's log, and kept in $Run.Log (the last 12).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Text
  )

  $line = ConvertTo-ScreenText -Text $Text
  if ($line -eq '') { return }
  Write-SetupLog -Level INFO -Message $line
  $Run.Log.Add($line)
  while ($Run.Log.Count -gt 12) { $Run.Log.RemoveAt(0) }
}

function ConvertTo-ToolStepRows {
  # Private. The run's steps as plain rows for progress.json and result.json: @( @{ Id; Status; Percent } ).
  [CmdletBinding()]
  param([AllowNull()]$Steps)

  $rows = @(foreach ($s in $Steps) { [ordered]@{ Id = [string]$s['Id']; Status = [string]$s['Status']; Percent = $s['Percent'] } })
  return , $rows
}

function Format-ToolTime {
  # Private. A [datetime] as ISO 'yyyy-MM-ddTHH:mm:ss' (invariant), like the run state; anything else as text.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$Value)

  if ($Value -is [datetime]) { return $Value.ToString('s', [Globalization.CultureInfo]::InvariantCulture) }
  return [string]$Value
}

function Write-ToolProgress {
  <#
  .SYNOPSIS
    Writes progress.json: @{ Action; RunId; State = 'running'|'done'; Current; Steps = @( @{ Id; Status; Percent } );
    Log = @( the last 12 lines ); Partial; UpdatedAt }. Never throws: the file is display only, and a failed write is
    a WARN once per run.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [ValidateSet('running', 'done')][string]$State = 'running'
  )

  try {
    $progress = [ordered]@{
      Action    = [string]$Run.Args['Action']
      RunId     = [string]$Run.Args['RunId']
      State     = $State
      Current   = [int]$Run.Current
      Steps     = (ConvertTo-ToolStepRows -Steps $Run.Steps)
      Log       = $Run.Log.ToArray()
      Partial   = $Run.Partial
      UpdatedAt = (Format-ToolTime -Value (Get-Date))
    }
    Save-ToolJsonFile -Path $Run.ProgressPath -InputObject $progress -Depth 8
  } catch {
    if (-not $script:ToolProgressWarned) {
      $script:ToolProgressWarned = $true
      Write-SetupLog -Level WARN -Message 'Could not write the progress file; the action goes on' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
  }
}

function Get-ToolResultColor {
  <#
  .SYNOPSIS
    The result's colour: RED for TimedOut, Failed (or any other outcome) or any CRIT finding; else YELLOW for
    Stopped, NeedsRestart or any WARN finding; else GREEN.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Outcome,
    [AllowNull()]$Findings
  )

  # Not @($Findings): on Windows PowerShell 5.1, @() of a List parameter throws "Argument types do not match".
  $levels = @(foreach ($f in $Findings) { if ($null -ne $f) { [string]$f.Level } })
  if ($Outcome -cnotin 'Done', 'Stopped', 'NeedsRestart' -or $levels -contains 'CRIT') { return 'RED' }
  if ($Outcome -cin 'Stopped', 'NeedsRestart' -or $levels -contains 'WARN') { return 'YELLOW' }
  return 'GREEN'
}

function Write-ToolResult {
  <#
  .SYNOPSIS
    Writes the final progress (State 'done') and result.json: @{ Action; RunId; Outcome; Color; Steps; Findings;
    RestartRequired; Offers; Files; Data; StartedAt; EndedAt }. $true when result.json was written; a failure is an
    ERROR in the log and $false. Never throws.
  .DESCRIPTION
    Files.Folder defaults to the session folder (else the run folder) and Files.Log to <LogDir>\setup.log. Data leaves
    out the keys of $script:ToolResultHiddenData (the report sections: they are in the report files, RD-R21).
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][ValidateSet('Done', 'Stopped', 'TimedOut', 'NeedsRestart', 'Failed')][string]$Outcome
  )

  try {
    $Run.Current = -1
    Write-ToolProgress -Run $Run -State 'done'
    if (-not $Run.Files.ContainsKey('Folder')) { $Run.Files['Folder'] = $(if ($Run.SessionDir) { $Run.SessionDir } else { $Run.Dir }) }
    if (-not $Run.Files.ContainsKey('Log')) { $Run.Files['Log'] = [IO.Path]::Combine($Run.LogDir, 'setup.log') }
    $data = @{}
    foreach ($key in @($Run.Data.Keys)) { if ($script:ToolResultHiddenData -notcontains [string]$key) { $data[$key] = $Run.Data[$key] } }
    $result = [ordered]@{
      Action          = [string]$Run.Args['Action']
      RunId           = [string]$Run.Args['RunId']
      Outcome         = $Outcome
      Color           = (Get-ToolResultColor -Outcome $Outcome -Findings $Run.Findings)
      Steps           = (ConvertTo-ToolStepRows -Steps $Run.Steps)
      Findings        = $Run.Findings.ToArray()
      RestartRequired = [bool]$Run.RestartRequired
      Offers          = $Run.Offers
      Files           = $Run.Files
      Data            = $data
      StartedAt       = (Format-ToolTime -Value $Run.StartedAt)
      EndedAt         = (Format-ToolTime -Value (Get-Date))
    }
    Save-ToolJsonFile -Path $Run.ResultPath -InputObject $result -Depth 8
    return $true
  } catch {
    Write-SetupLog -Level ERROR -Message 'Could not write the result file' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    return $false
  }
}

function Test-ToolStopRequested {
  # $true when the window asked for a stop (stop.flag in the run folder). Never throws.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][hashtable]$Run)

  return [IO.File]::Exists([string]$Run.StopPath)
}

function Get-ToolConfigMinutes {
  # Private. The positive number <Section>.<Name> (a JSON object or a hashtable), or $null.
  [CmdletBinding()]
  param([AllowNull()]$Section, [Parameter(Mandatory)][string]$Name)

  if ($null -eq $Section) { return $null }
  $value = $null
  if ($Section -is [System.Collections.IDictionary]) {
    $value = $Section[$Name]
  } else {
    $property = $Section.PSObject.Properties[$Name]
    if ($null -ne $property) { $value = $property.Value }
  }
  $minutes = 0.0
  if ($null -ne $value -and [double]::TryParse([string]$value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$minutes) -and $minutes -gt 0) {
    return $minutes
  }
  return $null
}

function Get-ToolElapsedSeconds {
  <#
  .SYNOPSIS
    The seconds since the child began, on the run's monotonic clock ($Run.Clock, a Stopwatch). Ruling RD-R8: no
    deadline ever reads the wall clock, which Standard repair's first step syncs. Tests mock this seam. 0 without a
    clock.
  #>
  [CmdletBinding()]
  [OutputType([double])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $clock = $Run.Clock
  if ($clock -is [Diagnostics.Stopwatch]) { return [double]$clock.Elapsed.TotalSeconds }
  return 0.0
}

function Get-ToolRemainingSeconds {
  # The action's time left: BudgetSeconds minus Get-ToolElapsedSeconds (negative once the budget is spent).
  [CmdletBinding()]
  [OutputType([double])]
  param([Parameter(Mandatory)][hashtable]$Run)

  return ([double]$Run.BudgetSeconds - (Get-ToolElapsedSeconds -Run $Run))
}

function Get-ToolStepTimeout {
  <#
  .SYNOPSIS
    A step's timeout in minutes: config timeoutsMinutes.toolStep.<Name>, else toolStep.native, else 3, capped at the
    action's remaining time (Get-ToolRemainingSeconds, the monotonic clock) minus 0.5 minute (and at least 0.25), so
    the child stops before the window's kill.
  #>
  [CmdletBinding()]
  [OutputType([double])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$Name
  )

  $section = $null
  try { $section = $Run.Config.timeoutsMinutes.toolStep } catch { $section = $null }
  $minutes = Get-ToolConfigMinutes -Section $section -Name $Name
  if ($null -eq $minutes) { $minutes = Get-ToolConfigMinutes -Section $section -Name 'native' }
  if ($null -eq $minutes) { $minutes = 3.0 }
  $left = (Get-ToolRemainingSeconds -Run $Run) / 60 - 0.5
  return [double][math]::Min($minutes, [math]::Max(0.25, $left))
}

function Get-ToolActionMinutes {
  # Private. The action's whole time for the actionTimedOut finding: its budget (BudgetSeconds), in whole minutes.
  [CmdletBinding()]
  [OutputType([int])]
  param([Parameter(Mandatory)][hashtable]$Run)

  return [int][math]::Max(0, [math]::Round([double]$Run.BudgetSeconds / 60))
}

# --- The step runner ----------------------------------------------------------------------------------------------

function Invoke-ToolStep {
  # Private. Runs step -Index of the run: 'running' and progress, the step function, its status and progress. An
  # exception, a step without a function, or a result that is not exactly one of the step results is 'failed' with
  # the CRIT finding stepFailed. A step that ends 'failed' or 'timedout' without adding a CRIT or WARN finding of its
  # own (INFO findings do not count) gets a generic CRIT one (stepFailed '<name> failed: see the log', or stepTimedOut
  # with the step's minutes on the run's clock), so a failure is never GREEN (fix round 1; Task 1 re-review: a step
  # that adds only an INFO finding and then fails is still red). A step's own WARN keeps an intentional timeout yellow
  # (sfcTimedOut). The step runs inside a one-shot loop: a stray break or continue in step code ends only that step
  # (as Invoke-SetupTick), never the runner's loop.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][int]$Index
  )

  $step = $Run.Steps[$Index]
  $id = [string]$step['Id']
  $name = Get-ToolStepName -Id $id
  $step['Status'] = 'running'
  $step['Percent'] = $null
  $Run.Current = $Index
  Add-ToolLog -Run $Run -Text ('{0}: started' -f $name)
  Write-ToolProgress -Run $Run
  $findingsBefore = $Run.Findings.Count
  $startedSeconds = Get-ToolElapsedSeconds -Run $Run

  $status = 'failed'
  $failure = $null
  $finished = $false
  foreach ($once in 1) {
    try {
      $definition = $script:ToolSteps[$id]
      $function = if ($null -ne $definition) { [string]$definition['Function'] } else { '' }
      if ($function -eq '') { throw ('no step function for {0}' -f $id) }
      $output = @(& $function -Run $Run)
      if ($output.Count -eq 1 -and $output[0] -is [string] -and $output[0] -cin 'done', 'warn', 'failed', 'skipped', 'timedout') {
        $status = $output[0]
      } else {
        $failure = 'unknown result'
        Write-SetupLog -Level ERROR -Message 'Tool step returned an unknown result' -Data @{ step = $id; values = $output.Count }
      }
      $finished = $true
    } catch {
      $failure = ConvertTo-ScreenText -Text $_.Exception.Message
      Write-SetupLog -Level ERROR -Message 'Tool step failed' -Data @{ step = $id; error = $failure; stack = (ConvertTo-ScreenText -Text $_.ScriptStackTrace) }
      $finished = $true
    }
  }
  if (-not $finished) {
    $failure = 'break or continue outside a loop'
    Write-SetupLog -Level ERROR -Message 'Tool step used break or continue outside a loop' -Data @{ step = $id }
  }
  # The CRIT and WARN findings the step added (an INFO alone would leave a failed step GREEN).
  $serious = 0
  for ($i = $findingsBefore; $i -lt $Run.Findings.Count; $i++) {
    if ([string]$Run.Findings[$i]['Level'] -cin 'CRIT', 'WARN') { $serious++ }
  }
  if ($null -ne $failure) {
    $status = 'failed'
    Add-ToolFinding -Run $Run -Level CRIT -Code 'stepFailed' -Arguments @($name, $failure)
  } elseif ($serious -eq 0 -and $status -eq 'failed') {
    Write-SetupLog -Level WARN -Message 'Tool step failed without a finding; adding a generic one' -Data @{ step = $id }
    Add-ToolFinding -Run $Run -Level CRIT -Code 'stepFailed' -Arguments @($name, 'see the log')
  } elseif ($serious -eq 0 -and $status -eq 'timedout') {
    Write-SetupLog -Level WARN -Message 'Tool step timed out without a finding; adding a generic one' -Data @{ step = $id }
    $minutes = [math]::Round([math]::Max(0, (Get-ToolElapsedSeconds -Run $Run) - $startedSeconds) / 60, 1)
    Add-ToolFinding -Run $Run -Level CRIT -Code 'stepTimedOut' -Arguments @($name, $minutes)
  }
  $step['Status'] = $status
  Add-ToolLog -Run $Run -Text ('{0}: {1}' -f $name, $status)
  Write-ToolProgress -Run $Run
}

function Invoke-ToolSteps {
  <#
  .SYNOPSIS
    Runs the run's steps in order. Returns 'Done', 'Stopped', 'TimedOut' or 'NeedsRestart'.
  .DESCRIPTION
    Safe points (spec 4.3), in this order:
      - stop.flag, before every step: the INFO finding stopped (the previous step's English name), or before the first
        step stoppedBeforeStart (a Stop pressed while the child was starting), 'Stopped';
      - the budget spent (Get-ToolRemainingSeconds, the monotonic clock, ruling RD-R8), before every step after the
        first: the CRIT finding actionTimedOut (the budget's minutes), 'TimedOut'.
    Before every servicing step, the first too (spec 5): a pending servicing restart (Get-ServicingRebootSignals,
    Test-ServicingRebootPending, or $Run.Data.DismPending: DISM itself answered 0x800F082F, which the registry may not
    show; review M1) is the WARN finding restartFirst (once: not again when a step already added it) and
    'NeedsRestart'. A file or computer rename alone never blocks. A step that fails does not stop the next one (DISM
    failing must not stop SFC).
    After every step, $Run.Data.Abort -eq $true (the step's own CRIT says why; Task 7: no verified backup, no reset)
    ends the action like a Stop, but the outcome stays 'Done' (red through that CRIT).
    Once any of these ended the action, the steps not run are 'skipped', except a step whose $script:ToolSteps row has
    AlwaysRun = $true (Task 7: the update services start again): it still runs, in its place, its waits shrunk to the
    0.25-minute floor of Get-ToolStepTimeout once the budget is spent, and the outcome stays the one that ended the
    others. Current is -1 at the end, and the progress is written.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $outcome = 'Done'
  $ended = $false
  for ($index = 0; $index -lt $Run.Steps.Count; $index++) {
    $id = [string]$Run.Steps[$index]['Id']
    $definition = $script:ToolSteps[$id]
    $always = ($null -ne $definition -and $definition['AlwaysRun'] -eq $true)
    if (-not $ended -and (Test-ToolStopRequested -Run $Run)) {
      if ($index -eq 0) {
        Add-ToolFinding -Run $Run -Level INFO -Code 'stoppedBeforeStart'
      } else {
        Add-ToolFinding -Run $Run -Level INFO -Code 'stopped' -Arguments @(Get-ToolStepName -Id ([string]$Run.Steps[$index - 1]['Id']))
      }
      Add-ToolLog -Run $Run -Text 'Stopped by the technician'
      $outcome = 'Stopped'
      $ended = $true
    }
    if (-not $ended -and $index -gt 0 -and (Get-ToolRemainingSeconds -Run $Run) -le 0) {
      Add-ToolFinding -Run $Run -Level CRIT -Code 'actionTimedOut' -Arguments @(Get-ToolActionMinutes -Run $Run)
      Add-ToolLog -Run $Run -Text 'The action reached its deadline'
      $outcome = 'TimedOut'
      $ended = $true
    }
    if (-not $ended -and $null -ne $definition -and $definition['Servicing'] -eq $true) {
      $signals = Get-ServicingRebootSignals
      $byDism = ($Run.Data['DismPending'] -eq $true)
      if ($byDism -or (Test-ServicingRebootPending -Signals $signals)) {
        Write-SetupLog -Level WARN -Message 'A servicing restart is pending; stopping before a servicing step' -Data @{ step = $id; signals = $signals; dism = $byDism }
        if (-not (Test-ToolFindingCode -Run $Run -Code 'restartFirst')) { Add-ToolFinding -Run $Run -Level WARN -Code 'restartFirst' }
        Add-ToolLog -Run $Run -Text 'A Windows servicing restart is pending'
        $outcome = 'NeedsRestart'
        $ended = $true
      }
    }
    if ($ended) {
      if ($always) {
        Add-ToolLog -Run $Run -Text ('{0}: runs although the action ended' -f (Get-ToolStepName -Id $id))
        Invoke-ToolStep -Run $Run -Index $index
      }
      continue
    }
    Invoke-ToolStep -Run $Run -Index $index
    if ($Run.Data['Abort'] -eq $true) {
      Write-SetupLog -Level WARN -Message 'A step ended the action' -Data @{ step = $id }
      Add-ToolLog -Run $Run -Text ('The action ended after {0}' -f (Get-ToolStepName -Id $id))
      $ended = $true
    }
  }
  foreach ($step in $Run.Steps) {
    if ($step['Status'] -eq 'pending') { $step['Status'] = 'skipped' }
  }
  $Run.Current = -1
  Write-ToolProgress -Run $Run
  return $outcome
}

# --- Bounded tools ------------------------------------------------------------------------------------------------

function Invoke-ToolNative {
  <#
  .SYNOPSIS
    Runs a native tool through Invoke-External with the step timeout (Get-ToolStepTimeout -Name -StepTimeout,
    'native' by default). Returns @{ ExitCode (<int>, $null on a timeout); TimedOut; OutputPath }.
  .DESCRIPTION
    Without -OutputName the tool runs itself and its output is discarded (never captured). With it, the output goes
    to <LogDir>\<OutputName>-<HHmmss>.txt (-2, -3, ... when taken; -OutputFolder names another folder, such as a
    report's raw_<stamp>\: Task 8) through
      cmd.exe /d /s /c ""<FilePath>" <ArgumentList> > "<file>" 2>&1"
    so the tick can read DISM's percent from the file while the tool runs: $Run.OutputPath holds the file during the
    call and is cleared in a finally. cmd passes the tool's exit code through. Plan call: every part is built from
    sanitized values, so this guard only catches a bug: a FilePath, ArgumentList or output path holding
    " % & ^ | < > or ! (cmd would read it), or an OutputName that is not a plain name, throws before anything runs.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$FilePath,
    [AllowEmptyString()][string]$ArgumentList = '',
    [string]$StepTimeout = 'native',
    [string]$OutputName,
    [string]$OutputFolder
  )

  if ([string]::IsNullOrEmpty($OutputName)) {
    $plain = Invoke-External -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutMinutes (Get-ToolStepTimeout -Run $Run -Name $StepTimeout)
    return @{ ExitCode = $plain.ExitCode; TimedOut = [bool]$plain.TimedOut; OutputPath = $null }
  }

  if ($OutputName -notmatch '^[A-Za-z0-9_-]{1,40}\z') { throw ('Invoke-ToolNative: the output name is not a plain name ({0})' -f (ConvertTo-ScreenText -Text $OutputName)) }
  $folder = [string]$Run.LogDir
  if (-not [string]::IsNullOrEmpty($OutputFolder)) { $folder = $OutputFolder }
  $stamp = (Get-Date).ToString('HHmmss', [Globalization.CultureInfo]::InvariantCulture)
  $outputPath = [IO.Path]::Combine($folder, ('{0}-{1}.txt' -f $OutputName, $stamp))
  $n = 2
  while ([IO.File]::Exists($outputPath)) {
    $outputPath = [IO.Path]::Combine($folder, ('{0}-{1}-{2}.txt' -f $OutputName, $stamp, $n))
    $n++
  }
  foreach ($part in $FilePath, $ArgumentList, $outputPath) {
    if ($part -match '["%&^|<>!]') { throw ('Invoke-ToolNative refuses a cmd metacharacter in: {0}' -f (ConvertTo-ScreenText -Text $part)) }
  }

  $inner = '"' + $FilePath + '"'
  if ($ArgumentList -ne '') { $inner += ' ' + $ArgumentList }
  $arguments = '/d /s /c "{0} > "{1}" 2>&1"' -f $inner, $outputPath
  $cmd = [IO.Path]::Combine($env:SystemRoot, 'System32\cmd.exe')
  $timeout = Get-ToolStepTimeout -Run $Run -Name $StepTimeout
  $Run.OutputPath = $outputPath
  try {
    $native = Invoke-External -FilePath $cmd -ArgumentList $arguments -TimeoutMinutes $timeout
  } finally {
    $Run.OutputPath = $null
  }
  return @{ ExitCode = $native.ExitCode; TimedOut = [bool]$native.TimedOut; OutputPath = $outputPath }
}

function Format-ToolExitCode {
  <#
  .SYNOPSIS
    An exit code as text: 'timed out' for $null, else '0x' and the 8 hex digits of its 32 bits (DISM's HRESULT
    -2146498529 is 0x800F081F). A value that is not a number comes back as ASCII text. Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()]$ExitCode)

  if ($null -eq $ExitCode) { return 'timed out' }
  $n = [long]0
  if (-not [long]::TryParse([string]$ExitCode, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
    return (ConvertTo-ScreenText -Text $ExitCode)
  }
  if ($n -lt 0 -and $n -ge [int]::MinValue) { $n += 4294967296 }
  if ($n -lt 0 -or $n -gt 4294967295) { return [string]$n }
  return ('0x{0:X8}' -f [uint32]$n)
}

function Get-ToolPercent {
  <#
  .SYNOPSIS
    The last percent in a tool's text ("[====  45.0%  ]"), as a [double] (a decimal comma is read as a point), or
    $null when there is none or it is above 100. Display only: no decision depends on it. Never throws.
  .DESCRIPTION
    The pattern is (?<!\d)(\d{1,3}(?:[.,]\d{1,2})?)\s?% with ASCII digits ([0-9]), so a digit run inside a longer
    number never counts and a non-ASCII digit can never fail the parse.
  #>
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  try {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $found = [regex]::Matches($Text, '(?<![0-9])([0-9]{1,3}(?:[.,][0-9]{1,2})?)\s?%')
    if ($found.Count -eq 0) { return $null }
    $value = [double]::Parse($found[$found.Count - 1].Groups[1].Value.Replace(',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
    if ($value -gt 100) { return $null }
    return $value
  } catch {
    return $null
  }
}

function Update-ToolTick {
  <#
  .SYNOPSIS
    The child's tick handler (Register-SetupTick in Invoke-SetupToolProcess; Invoke-External's poll loop calls it at
    most once a second). While a tool writes to $Run.OutputPath: the last 64 KB of that file, its last percent
    (Get-ToolPercent) as the running step's Percent. Then the progress file. Never throws.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Run)

  try {
    if (-not [string]::IsNullOrEmpty([string]$Run.OutputPath) -and [int]$Run.Current -ge 0) {
      $tail = Read-FileTail -Path ([string]$Run.OutputPath) -MaxBytes 65536
      $percent = Get-ToolPercent -Text $tail
      if ($null -ne $percent) { $Run.Steps[[int]$Run.Current]['Percent'] = $percent }
    }
    Write-ToolProgress -Run $Run
  } catch {
    if (-not $script:ToolTickWarned) {
      $script:ToolTickWarned = $true
      Write-SetupLog -Level WARN -Message 'The progress tick failed; the action goes on' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    }
  }
}

function Invoke-ToolJsonChild {
  <#
  .SYNOPSIS
    Runs a cmdlet that can hang (Repair-WindowsImage, Repair-Volume, Get-PhysicalDisk, ...) in a bounded PowerShell
    grandchild (Invoke-PowerShellChild, the step timeout -StepTimeout, 'grandchild' by default) that returns JSON.
    Returns @{ Ok; TimedOut; Data; Error }. Never throws.
  .DESCRIPTION
    The grandchild sets $ErrorActionPreference = 'Stop' and $out to <Dir>\gc-<Name>-<n>.json (the first free n, as a
    single-quoted literal), evaluates & { <Command> }, writes its value as compressed JSON (depth 6, UTF-8 without a
    BOM) and exits 0; a throw writes @{ Error = <message> } and exits 1. Commands return a hashtable (lists go inside
    Items), never a bare array, and stay short (the command line carries them encoded).
    Then Read-ToolJsonFile: exit 0 and an object is Ok with Data. Anything else is Ok = $false with Error: 'timed
    out', 'output too large' (the result file is over Read-ToolJsonFile's 1 MB), the grandchild's own message
    (ASCII), 'exit 0x...', or 'no result'. The grandchild's console output is
    never read.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Command,
    [string]$StepTimeout = 'grandchild'
  )

  try {
    if ($Name -notmatch '^[A-Za-z0-9_-]{1,40}\z') { return @{ Ok = $false; TimedOut = $false; Data = $null; Error = 'invalid grandchild name' } }
    $n = 1
    $out = [IO.Path]::Combine([string]$Run.Dir, ('gc-{0}-{1}.json' -f $Name, $n))
    while ([IO.File]::Exists($out)) {
      $n++
      $out = [IO.Path]::Combine([string]$Run.Dir, ('gc-{0}-{1}.json' -f $Name, $n))
    }
    $script = @(
      "`$ErrorActionPreference = 'Stop'"
      ('$out = ' + (ConvertTo-PowerShellLiteral -Text $out))
      'try {'
      '$value = & {'
      $Command
      '}'
      '[IO.File]::WriteAllText($out, (ConvertTo-Json -InputObject $value -Depth 6 -Compress), (New-Object Text.UTF8Encoding $false))'
      'exit 0'
      '} catch {'
      'try { [IO.File]::WriteAllText($out, (ConvertTo-Json -InputObject @{ Error = [string]$_.Exception.Message } -Compress), (New-Object Text.UTF8Encoding $false)) } catch { }'
      'exit 1'
      '}'
    ) -join "`r`n"
    $child = Invoke-PowerShellChild -Command $script -TimeoutMinutes (Get-ToolStepTimeout -Run $Run -Name $StepTimeout)
    if ($child.TimedOut) {
      Write-SetupLog -Level WARN -Message 'Tool grandchild timed out' -Data @{ name = $Name }
      return @{ Ok = $false; TimedOut = $true; Data = $null; Error = 'timed out' }
    }
    $data = Read-ToolJsonFile -Path $out
    if ($child.ExitCode -eq 0 -and $null -ne $data) { return @{ Ok = $true; TimedOut = $false; Data = $data; Error = $null } }
    $outFile = New-Object IO.FileInfo $out
    if ($null -eq $data -and $outFile.Exists -and $outFile.Length -gt 1MB) {
      # Read-ToolJsonFile's default cap: a command that returns more must return less (or write its own file).
      $message = 'output too large'
    } elseif ($null -ne $data -and $data.ContainsKey('Error') -and -not [string]::IsNullOrWhiteSpace([string]$data['Error'])) {
      $message = ConvertTo-ScreenText -Text ([string]$data['Error'])
    } elseif ($null -ne $child.ExitCode -and $child.ExitCode -ne 0) {
      $message = 'exit ' + (Format-ToolExitCode -ExitCode $child.ExitCode)
    } else {
      $message = 'no result'
    }
    Write-SetupLog -Level WARN -Message 'Tool grandchild gave no result' -Data @{ name = $Name; error = $message }
    return @{ Ok = $false; TimedOut = $false; Data = $null; Error = $message }
  } catch {
    $message = ConvertTo-ScreenText -Text $_.Exception.Message
    Write-SetupLog -Level WARN -Message 'Tool grandchild could not run' -Data @{ name = $Name; error = $message }
    return @{ Ok = $false; TimedOut = $false; Data = $null; Error = $message }
  }
}

# --- The child entry ----------------------------------------------------------------------------------------------

function Invoke-SetupToolProcess {
  <#
  .SYNOPSIS
    The -ToolAction child process: one action of the repair page. Returns 0 when result.json was written, else 1.
    Never prompts, never draws.
  .DESCRIPTION
    1. The run's Stopwatch starts (every deadline is measured on it, ruling RD-R8). <Root> must exist (the launcher
       made it admin-only): without it nothing is created and the answer is 1.
    2. The log goes to <Root>\Tool\setup.log, so a refused call logs inside the admin-only folder and creates
       nothing elsewhere. Read-ToolArgs: invalid args are an ERROR 'Tool action refused' with the ASCII reason, 1,
       and nothing else runs (no step, no progress, no result).
    3. The log moves to the run folder; Read-SetupConfig <Root>\config.json; New-ToolRun. An action that is not
       LogLocal gets its session folder (New-ToolSessionDir) and the log moves to <session>\logs.
    4. 'Tool action started' @{ action; runId; budgetSeconds; deadlineUtc }; the tick (Update-ToolTick) is
       registered; Invoke-ToolSteps;
       Write-ToolResult. The tick is unregistered in a finally.
    A failure after the run exists marks the running step failed and the rest skipped, adds stepFailed and writes
    the result as 'Failed'. Before that (config.json unreadable) it is an ERROR and 1, without a result.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)][string]$Root,
    [AllowNull()][AllowEmptyString()][string]$ActionId,
    [AllowNull()][AllowEmptyString()][string]$ArgsPath
  )

  $clock = [Diagnostics.Stopwatch]::StartNew()
  if (-not [IO.Directory]::Exists($Root)) { return 1 }
  $action = ConvertTo-ScreenText -Text $ActionId
  $run = $null
  $exitCode = 1
  try {
    $null = Initialize-SetupLog -LogDirectory ([IO.Path]::Combine($Root, 'Tool'))
    try {
      $toolArgs = Read-ToolArgs -Path $ArgsPath -Root $Root -ActionId $ActionId
    } catch {
      Write-SetupLog -Level ERROR -Message 'Tool action refused' -Data @{ action = $action; reason = (ConvertTo-ScreenText -Text $_.Exception.Message) }
      return 1
    }
    $runId = [string]$toolArgs['RunId']
    $null = Initialize-SetupLog -LogDirectory ([IO.Path]::Combine($Root, 'Tool', $runId))
    $config = Read-SetupConfig -Path ([IO.Path]::Combine($Root, 'config.json'))
    $run = New-ToolRun -ToolArgs $toolArgs -Config $config -Root $Root -Clock $clock
    if ($script:ToolActionCatalog[$toolArgs['Action']]['LogLocal'] -ne $true) {
      $null = New-ToolSessionDir -Run $run
      $null = Initialize-SetupLog -LogDirectory $run.LogDir
    }
    Write-SetupLog -Message 'Tool action started' -Data @{
      action = $action; runId = $runId; budgetSeconds = $run.BudgetSeconds; deadlineUtc = (ConvertTo-ScreenText -Text $toolArgs['DeadlineUtc']) }
    Register-SetupTick -Context $run -Handler { param($tickRun) Update-ToolTick -Run $tickRun }
    $outcome = Invoke-ToolSteps -Run $run
    $written = Write-ToolResult -Run $run -Outcome $outcome
    Write-SetupLog -Message 'Tool action finished' -Data @{ action = $action; runId = $runId; outcome = $outcome; resultWritten = $written }
    if ($written) { $exitCode = 0 }
  } catch {
    $message = ConvertTo-ScreenText -Text $_.Exception.Message
    Write-SetupLog -Level ERROR -Message 'Tool action failed' -Data @{ action = $action; error = $message; stack = (ConvertTo-ScreenText -Text $_.ScriptStackTrace) }
    if ($null -ne $run) {
      foreach ($s in $run.Steps) {
        if ($s['Status'] -eq 'running') { $s['Status'] = 'failed' } elseif ($s['Status'] -eq 'pending') { $s['Status'] = 'skipped' }
      }
      Add-ToolFinding -Run $run -Level CRIT -Code 'stepFailed' -Arguments @('The action', $message)
      if (Write-ToolResult -Run $run -Outcome 'Failed') { $exitCode = 0 }
    }
  } finally {
    Unregister-SetupTick
  }
  return $exitCode
}
