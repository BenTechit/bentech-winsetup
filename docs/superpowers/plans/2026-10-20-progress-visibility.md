# bentech-winsetup v2: Progress Visibility and Background Office Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One glance at a machine tells Ben what it is doing, that it is alive, how long it may take and what it has done: a clear 30-second start screen, a progress screen that moves every second (checklist, NOW, JUST HAPPENED), Windows Update shown update by update, and Microsoft 365 installed in the background with desktop shortcuts. Before that, the fixes from the first real-machine test (spec §9); at the end, no leftover folder (spec §10). Build order **A**: everything except the Dell and HP driver *lists*.

**Architecture:**
- **Tasks 2-4 are the spec §9 fixes**, built first on top of v1 alone (no v2 plumbing), so they can ship as their own release: the suite is green and the bundle builds after Task 4 (its last step is the release checkpoint).
- **Task 15 is spec §10**: the run records where the launcher came from, the final screen finishes on Enter, the logs go to the USB stick, and `C:\BenTech` is deleted with `rd /s /q` after the transcript, logging and lock are released.
- A small live-status layer (`src/Common/Activity.ps1`) holds the activity feed (`Logs\activity.txt`), the NOW state and a throttled **tick**. Every long wait (`Invoke-External`'s loop, `Wait-SetupDelay`, downloads, the Office wait) calls the tick; the tick redraws the progress screen through an injectable `[Console]` writer (`src/UI/ConsoleFrame.ps1`), never `Write-Host`.
- Office is split: `office` starts the ODT in the background right after `vendor-pass1`; `office-finish` (right after `windows-update`) collects the result and creates the shortcuts. Every controlled restart waits for the background Office first.
- The `-WuRound` child installs one update at a time (config switch, batch still available) and writes `Logs\wu-round<N>.progress.json`, which the parent's NOW reads on every tick.

**Tech Stack:** Windows PowerShell 5.1, .NET Framework 4.8 (`System.Console`, `Diagnostics.Process`, `WebClient.DownloadFileTaskAsync`), WUA COM, `WScript.Shell` COM (shortcuts). Pester 5.5+ on the dev PC only.

**Spec:** `docs/specs/2026-10-20-progress-visibility-design.md` (binding), which amends `docs/specs/2026-10-18-bentech-winsetup-design.md`. The v1 plan `docs/superpowers/plans/2026-10-18-bentech-winsetup.md` (its Global Constraints and Shared shapes still apply) and the v1 rulings in `.superpowers/sdd/2026-10-18-bentech-winsetup/progress.md` ("Ruling" lines) travel with this plan.

## Global Constraints

**Platform and safety**
- Windows PowerShell **5.1 only**; no modules or dependencies at runtime. Pester 5.5+ on the dev PC only.
- **Never run setup steps, `setup.ps1`, the launcher, Windows Update COM installs, vendor tools or the new capture spike on this PC.** Tests mock every system call (registry, CIM, Task Scheduler, WUA COM, `Invoke-External`, `Start-BackgroundExternal`, `WScript.Shell`, `[Console]` through the writer seam). The only real children in tests are harmless ones: `Process.Tests` (ping, `cmd /c exit`), and Task 15's one `rd` (plus `mklink /J`) inside `$TestDrive`.
- **Outward-facing actions need Ben's explicit OK at that moment.** Never run `git push`, any `gh` command, or `tools\Publish.ps1` without `-DryRun`.
- **The launcher must not change.** `launcher\BenTechSetup.template.cmd` and `keys\public-key.xml` are not edited; `keys\launcher.sha256` stays `702c323aff5e813d7264375d15387d3bcdc12baded3d192f4bc47890663b69ff` (pinned by a test in Task 1).

**Runtime rules (v1, unchanged)**
- **Never parse localized output for a decision.** Display-only parsing of vendor logs and WU titles is allowed, with a silent fallback (spec §5).
- **Every child process goes through `Invoke-External` with a timeout from `config.timeoutsMinutes`.** The one exception is the Office background process, started by `Start-BackgroundExternal`; its deadline (`timeoutsMinutes.office` after its start) is enforced by `Wait-OfficeBackground`. Nothing may wait without a deadline.
- No prompts: no `Read-Host`, no `-Confirm`, no `pause`.
- `$ErrorActionPreference` stays `Continue`. Inside a `try`, state-changing cmdlets carry `-ErrorAction Stop`; tests mock a failing cmdlet with `Write-Error`, never `throw` (`tests\ErrorAction.Tests.ps1`).
- Downloads: `System.Net.WebClient` + TLS 1.2, never `Invoke-WebRequest`.
- Console text English, ASCII only (`ConvertTo-ScreenText` on every free-text value). Report dates `dd/MM/yyyy HH:mm`. `activity.txt` lines start `yyyy-MM-dd HH:mm:ss` + TAB (invariant culture).
- No secrets, no customer PII beyond machine identity. **The AnyDesk ID never goes into `setup.log`** (it may go to the screen, `activity.txt` and the report).
- Step contract, `Context` and `State` shapes as in the v1 plan. Keep step `Data` shallow (`ConvertTo-Json -Depth 12` truncates silently). The key `Interruptions` belongs to the runner.

**Screen colours (spec §9.1, from Task 2 on)**
- **No screen uses `DarkYellow` or `DarkMagenta`**, as foreground or background (the `powershell.exe` console profile remaps them to near white and PowerShell blue).
- **Every screen line sets its foreground and background explicitly**: every `Write-Host` under `src` passes both `-ForegroundColor` and `-BackgroundColor`; every `[Console]` frame write passes both (Task 7).
- Verdict colours: YELLOW = `Black` on `Yellow`, GREEN = `White` on `DarkGreen`, RED (and anything unknown) = `White` on `DarkRed`. The v2 start and progress screens draw on `Black`.
- `tests\Colors.Tests.ps1` (Task 2) scans `src` and the launcher template for the two colour names (comments excluded) and every `Write-Host` for both colour parameters.

**v2 display rules (spec §3, §4.3, §4.4)**
- The progress screen and the start screen draw through the `[Console]` writer seam (`New-ConsoleWriter`), **never `Write-Host` or `Clear-Host`**: the transcript records every `Write-Host`. The reboot countdown stays as it is. From Task 15 the final screen draws through the same writer.
- **The tick never throws**, redraws at most once per second, costs about 50 ms at most, reads at most the last 64 KB of any file, and logs its own error at most once per minute.
- **The tick runs only on the main path**: never in the `-WuRound` child, never before `Register-SetupTick`. With no tick registered, `Wait-SetupDelay` is exactly one `Start-Sleep` with the same argument, so the run without a screen behaves exactly as v1.
- Step code never calls `Start-Sleep`; it calls `Wait-SetupDelay` (guarded by `tests\Waits.Tests.ps1`, Task 6).

**Deleting `C:\BenTech` (spec §10, Task 15)**
- Only `Remove-SetupFolder` deletes it: `cmd.exe /d /c rd /s /q` through `Invoke-External` (`rd` never follows a junction; `Remove-Item -Recurse` on 5.1 would). It refuses any path whose leaf is not `BenTech`, a drive root, or a reparse point.
- It runs only after a finished final screen (Enter) or an Esc cancel with no earlier run; never after a crash, a restart, or a lock held by another run.
- **Tests never delete anything outside `$TestDrive`.** `tests\Entry.Tests.ps1` mocks `Invoke-SetupCleanup` in its `BeforeEach` (its `-Root` is `$TestDrive`, whose parent is the temp folder). The one real `rd` test works inside `$TestDrive` on a folder named `BenTech`.

**v1 rulings this plan keeps** (do not undo): R11 (interruptions), R15 (no resume task, no restart), R17a (amended only as Task 13 states), R20/R21/R22 (vendor power and Lenovo policy), R23, R23b, R24a-d (Windows Update result meaning), R26 (Phase B always runs), R27, R28b/R28c, R29, R30.

**Files, tests, commits**
- Every `.ps1` is UTF-8 **with BOM** (the file-writing tool emits none). After writing, re-save with: `powershell -NoProfile -Command "Get-ChildItem -Recurse -Include *.ps1 src,tests,tools | % { $t=[IO.File]::ReadAllText($_.FullName); [IO.File]::WriteAllText($_.FullName,$t,(New-Object Text.UTF8Encoding $true)) }"` (ruling R4; `tests\Encoding.Tests.ps1` enforces it).
- Test command: `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` (or one file). **Pass = the last line reads `Failed: 0`.** Today: 1548 tests, all passing; every task ends with the full suite green.
- A review gate before every commit (the reviewer subagent; Ben's rule). Conventional commits, each ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (pass it as a second `-m`).
- A new `src` file needs a `$BundleOrder` entry in `tools\Build-Bundle.ps1` (`tests\Bundle.Tests.ps1` fails otherwise).
- Whatever only a real machine can prove goes into `docs\testing.md` (Task 16 collects it).

## Review Focus

The five inputs the spec implies that no task's tests would otherwise exercise, most likely first. Each names the task that owns its pinning test.

1. **The USB stick is not where it was** (it came back with another drive letter, a second USB drive is plugged in, or there is no stick): the logs go to the stick the run started from, found by its volume serial, else to a drive holding `BenTechSetup.cmd`, never to the system drive; no stick means no copy and a clear line. Task 15: `Find-SetupStick` serial, fallback, system-drive and none tests.
2. **A deletion target that is not `C:\BenTech`** (a test root, a junction inside the folder, a drive root): nothing outside `C:\BenTech` may ever be removed. Task 15: `Remove-SetupFolder refuses ...` and `rd removes a junction without touching its target`.
3. **A small console or Windows Terminal** (the Windows 11 default refuses resizing), also for the final screen: header, checklist and NOW line stay, nothing wraps or scrolls. Task 7: `fits a tiny 40x12 window`; Task 15: `the worst-case final screen fits 29 lines`.
4. **Hebrew Windows text** (direction marks in WMI captions, Hebrew update titles, vendor log lines, step messages): the screen and the report stay readable ASCII, marks removed. Task 2: `strips direction and format marks`; Task 7: `is ASCII only with Hebrew everywhere`; Task 10: `Hebrew in a log line becomes ?`.
5. **The Office PID reused after a forced restart** (another process got the same id): `office-finish` must not wait on, or kill, a stranger. Task 13: `a process with the same id but another start time is not Office`.

---

## File Structure

```
-- spec §9 (Tasks 2-4) --
src/UI/FinalScreen.ps1       MOD  verdict colours (fg + bg), later: Enter finishes, live USB-stick line (Task 15)
src/UI/StartScreen.ps1       MOD  ConvertTo-ScreenText strips direction marks; explicit colours
src/Engine/Reboot.ps1, src/Entry/Main.ps1, src/UI/ProgressScreen.ps1  MOD  explicit fg + bg on every Write-Host
src/Steps/WindowsUpdate.ps1  MOD  drivers that can ask for input are installed; firmware only on AC
src/Steps/Vendor.ps1         MOD  consumer-app verify (config vendors.<BRAND>.consumerApp.verify)
src/Steps/Finalize.ps1       MOD  waits up to 120 s for Chrome as default; Windows activation attempt
tests/Colors.Tests.ps1       NEW  colour-name scan + explicit-colour check
-- spec §10 (Task 15) --
src/Entry/Cleanup.ps1        NEW  launcher info, stick search, log copy, Desktop launcher, rd of C:\BenTech
tests/Cleanup.Tests.ps1      NEW
-- v2 (Tasks 5-14) --
src/Common/Activity.ps1      NEW  activity feed (Logs\activity.txt), file tail reader, tick registry,
                                  Wait-SetupDelay, NOW state (title/subtitle/provider) and the wait stack
src/Common/Process.ps1       MOD  Invoke-External ticks + publishes its timeout; Start-BackgroundExternal
src/Common/Download.ps1      MOD  Get-RemoteFile async with tick and a deadline; backoff via Wait-SetupDelay
src/UI/ConsoleFrame.ps1      NEW  [Console] writer seam, flicker-free frame writer, console resize
src/UI/ProgressScreen.ps1    MOD  v2 layout: header + spinner, checklist columns, NOW, JUST HAPPENED
src/UI/StartScreen.ps1       MOD  v2 layout, 30 s countdown, any key resets, colours, draws via ConsoleFrame
src/Engine/Catalog.ps1       MOD  Short titles, Test-HasDriverTool, office moved, office-finish added
src/Engine/Runner.ps1        MOD  activity lines per step, NOW cleared around every step
src/Engine/Reboot.ps1        MOD  "Restarting (restart N)", waits for background Office before restarting
src/Entry/Main.ps1           MOD  activity init/archive, console resize, tick registration, WU install mode
src/Steps/Office.ps1         MOD  background start, Wait-OfficeBackground, office-finish, desktop shortcuts
src/Steps/WindowsUpdate.ps1  MOD  en-US titles, one-at-a-time install, progress file, NOW list, round lines
src/Steps/Vendor.ps1         MOD  NOW: tool name + latest log line; BitLocker suspension line
src/Steps/Apps.ps1, Bloatware.ps1, Region.ps1   MOD  activity facts (versions, AnyDesk ID, apps removed, region)
src/Steps/BitLocker.ps1, Prepare.ps1, Winget.ps1 MOD  Wait-SetupDelay instead of Start-Sleep
src/Steps/Finalize.ps1       MOD  waits for a live background Office before Phase A / Phase B (R26)
src/Report/Report.ps1        MOD  "Windows updates installed" section
config/config.json           MOD  windowsUpdate.installMode, apps.office.excludeApps
tools/Build-Bundle.ps1       MOD  $BundleOrder: Common\Activity.ps1, UI\ConsoleFrame.ps1, Entry\Cleanup.ps1
tools/spikes/Spike-DriverListCapture.ps1  NEW  list-only Dell/HP capture for Ben's laptops
tests/Activity.Tests.ps1, tests/Waits.Tests.ps1, tests/Spikes.Tests.ps1   NEW
docs/spikes.md, docs/testing.md, README.md, CLAUDE.md   MOD
```

## Shared shapes (v2 additions; v1 shapes unchanged)

**WU update info** (Task 3): `ConvertTo-WuUpdateInfo` adds `IsDriver = <bool>` (it came from the `Type='Driver'` search) and `DriverClass = <string>` (`IWindowsDriverUpdate.DriverClass`, not localized; `''` for software or when unreadable). `Select-WuUpdates` returns `Deferred` (firmware held back on battery) next to `Install`, `Hide`, `Skip`. The round result JSON gains `FirmwareDeferred = <int>`.

**`consumerApp.verify`** (Task 4, optional per vendor in `config.json`): `{ "paths": ["<path, env vars and wildcards allowed>", ...], "services": ["<service name>", ...] }`, either list may be left out. Absent = v1 behaviour.

**`State.Launcher`** (Task 15, new runs only): `@{ Path = <BT_SELF>; Drive = 'E:'|$null; VolumeSerial = '<hex>'|$null }`, or `$null` when `BT_SELF` was not set.

**Catalog entry:** `@{ Id; Title; Short; Function }`. `Title` stays what the verdict and report print; `Short` (at most 20 characters) is what the checklist and NOW print.

**Plan order (Task 13):** `prepare, bitlocker, region, desktop-icons, bloatware, rename, winget, chrome, anydesk, 7zip, default-browser, vendor-pass1, office, windows-update, office-finish, vendor-pass2, consumer-app, vendor-cleanup, finalize`. `office-finish` is in the plan exactly when `office` is.

**Activity line** (`Logs\activity.txt`, UTF-8 without BOM): `yyyy-MM-dd HH:mm:ss<TAB><text>`. In memory: `[pscustomobject]@{ Time = [datetime]; Text = [string] }`, newest first, at most 50.

**NOW state** (`Get-SetupNow`): `@{ Title = <string|$null>; SubTitle = <string|$null>; Provider = <scriptblock|$null>; ProviderArgument = <object>; Wait = $null | @{ StartedAt = [datetime]; LimitMinutes = [double] } }`. `Title` overrides the running step's name (used by the Office restart wait). `Wait` is the top of the wait stack.

**`office` step Data** (Task 13): `@{ Background = $true; ProcessId = <int>; ProcessStartUtc = <ISO 'o'>; StartedAt = <ISO 's', local>; DeadlineAt = <ISO 's', local> }`, plus, once the background process is known to have ended: `Finished = $true` and either `ExitCode = <int>` or `KilledAtDeadline = $true` (or neither: ended, code unknown). `office-finish` Data: `@{ ForegroundTried = $true }` once its one foreground retry has started.

**`windows-update` step Data** gains `InstalledLines = <string[]>`, e.g. `'Round 1: KB5070001 2026-10 Cumulative Update for Windows 11'`.

**WU round result JSON** gains `Found = <int>` and, per `Installed` entry, `Kb = 'KB<id>' | ''`.

**WU progress file** `Logs\wu-round<N>.progress.json` (written by the child, replaced atomically):
```
{ Round: <int>, Mode: 'OneAtATime'|'Batch', Phase: 'searching'|'downloading'|'installing'|'done',
  Current: <int, 1-based, 0 = none>, Total: <int>,
  Updates: [ { Kb: 'KB5070001'|'', Title: <string>, SizeMB: <double>,
               Status: 'pending'|'downloading'|'installing'|'installed'|'failed'|'skipped' } ],
  UpdatedAt: <ISO 's'> }
```
`skipped` = not attempted (the loop stopped at a round-ending code).

---

### Task 1: Driver-list capture spike and launcher guard

The first deliverable Ben can use: a list-only capture he runs on one Dell and one HP laptop that come through the shop. Its output decides the later driver-list work (not in this plan). The launcher guard pins the trust anchor for every later task.

**Files:**
- Create: `tools/spikes/Spike-DriverListCapture.ps1`, `tests/Spikes.Tests.ps1`
- Modify: `docs/spikes.md` (new "Spike 5" section, a line in "Before you start", a row in "Quick reference"), `README.md` ("Open spikes": one paragraph), `tests/Launcher.Tests.ps1` (one new `Describe` at the end)

**Interfaces:**
- Produces: `tools\spikes\Spike-DriverListCapture.ps1 [-OutRoot <string>] [-InstallTool] [-InventoryOnly] [-TimeoutMinutes <int> = 20]` (`[CmdletBinding()]`; resolve `-OutRoot` default = the script's own folder in the body, not in `param()`). Reuse the patterns of `Spike-LenovoSystemUpdate.ps1`: elevation check, `Invoke-Proc` (hidden `Start-Process`, stdout/stderr to files, `.Handle` cached, kill on timeout), `Get-FileTail`, `Save-Json`, `$ErrorActionPreference = 'Stop'`, ASCII only, never prompts.
  1. Not elevated: red message, exit 1.
  2. Brand from `Win32_ComputerSystem.Manufacturer`: `Dell` -> DELL; `HP` or `Hewlett` -> HP; anything else: "This is not a Dell or HP laptop", exit 1.
  3. Output folder `<OutRoot>\capture-<BRAND>-<Serial>-<yyyyMMdd-HHmm>\` with `report\`, `logs\` and `capture.json` (machine: manufacturer, model, product, serial, OS caption + build, on AC; tool: path, file version, signature status + signer subject; run: command line, exit code + hex, timed out, elapsed seconds; copied files; errors). `capture.json` is written in a `finally`, also after a failure.
  4. **DELL:** `dcu-cli.exe` from the same candidates as `config.json` (`C:\Program Files\Dell\CommandUpdate\dcu-cli.exe`, then the `(x86)` path). Missing: with `-InstallTool` only, `winget install --id Dell.CommandUpdate.Universal -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity` (the package the setup tool installs anyway); without it, print how to re-run with `-InstallTool` and exit 1. Authenticode `Valid` with a subject containing `Dell` or nothing runs. Run `"<dcu-cli>" /scan -report="<out>\report" -outputLog="<out>\logs\dcu-scan.log"`. Then copy the newest 10 `*.log` files (at most 5 MB each) from `%ProgramData%\Dell\UpdateService\Log` and `%ProgramData%\Dell\CommandUpdate` when they exist.
  5. **HP:** HP Image Assistant is portable: read `https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html`, first match of `https://hpia\.hpcloud\.hp\.com/downloads/hpia/hp-hpia-[0-9.]+\.exe` (copied from `config.json`), download with `WebClient` + TLS 1.2 to `%TEMP%\BenTechCapture\hp-hpia.exe`, require a `Valid` signature whose subject contains `HP Inc`, extract with `/s /e /f "%TEMP%\BenTechCapture\HPIA"`, run `HPImageAssistant.exe /Operation:Analyze /Category:All /Selection:All /Action:List /Silent /ReportFolder:"<out>\report"`. Then copy every `*.log` under the extraction folder into `logs\`.
  6. Never: `/applyUpdates`, `/configure`, `/Action:Install` or `/Action:Download`, a restart, a registry write, a BIOS or firmware command. Every run is bounded by `-TimeoutMinutes` and killed on timeout. On battery it still runs (list only).
  7. **Inventory, always (read-only; supplies the spec §9.3 `verify` values):** `capture.json` also lists the services whose name or display name contains the brand (`Dell`, `HP`, `SupportAssist`), the `*.lnk` files under `%ProgramData%\Microsoft\Windows\Start Menu\Programs` whose name contains them (name + target), and `Get-AppxPackage -AllUsers` entries whose name contains them (name, version, install location). `-InventoryOnly` skips steps 4-5 (for the second run, after the setup run, when Dell Command Update may already be removed).
  8. Prints the output folder and exits 0.

- [ ] **Step 1: Write the failing tests** in `tests/Spikes.Tests.ps1` and the launcher guard in `tests/Launcher.Tests.ps1`.

```powershell
# tests/Spikes.Tests.ps1 - static checks only; the spike scripts are never run here.
BeforeAll {
  $script:spikeDir = (Resolve-Path "$PSScriptRoot\..\tools\spikes").Path
  $script:capture = Join-Path $script:spikeDir 'Spike-DriverListCapture.ps1'
  $script:text = [IO.File]::ReadAllText($script:capture)
  $script:ast = [Management.Automation.Language.Parser]::ParseFile($script:capture, [ref]$null, [ref]$null)
}
Describe 'spike scripts' {
  It 'every spike script parses' {
    foreach ($f in Get-ChildItem $script:spikeDir -Filter *.ps1) {
      $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
      $e | Should -BeNullOrEmpty -Because $f.Name
    }
  }
}
Describe 'Spike-DriverListCapture.ps1 is list-only' {
  It 'uses the list modes of both tools' { $text | Should -Match '/scan'; $text | Should -Match '/Action:List' }
  It 'never applies, downloads or installs updates' { $text | Should -Not -Match '(?i)/applyUpdates|/configure|/Action:(Install|Download)|autoSuspendBitLocker' }
  It 'never restarts and never writes the registry' { $text | Should -Not -Match '(?i)Restart-Computer|shutdown|bcdedit|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty' }
  It 'has the -InstallTool switch and installs a tool only inside if ($InstallTool)' {
    $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'InstallTool'
    $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'InventoryOnly'
    $hits = @($ast.FindAll({ param($n) ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Extent.Text -match 'install --id' }, $true))
    $hits.Count | Should -BeGreaterThan 0
    foreach ($h in $hits) {
      $p = $h.Parent
      while ($null -ne $p -and -not ($p -is [Management.Automation.Language.IfStatementAst] -and $p.Clauses[0].Item1.Extent.Text -eq '$InstallTool')) { $p = $p.Parent }
      $p | Should -Not -BeNullOrEmpty
    }
  }
}
```

```powershell
# tests/Launcher.Tests.ps1, new Describe at the end. Builds into $TestDrive only.
Describe 'the launcher does not change in v2' {
  It 'a launcher built from this repo matches keys\launcher.sha256' {
    $repo = (Get-Content "$PSScriptRoot\..\tools\publish.settings.json" -Raw | ConvertFrom-Json).repo
    $out = Join-Path $TestDrive 'BenTechSetup.cmd'
    & "$PSScriptRoot\..\tools\Build-Launcher.ps1" -BaseUrl "https://github.com/$repo/releases/latest/download" -OutPath $out | Out-Null
    $recorded = @(([IO.File]::ReadAllText("$PSScriptRoot\..\keys\launcher.sha256").Trim()) -split '\s+')[0]
    $recorded | Should -Be '702c323aff5e813d7264375d15387d3bcdc12baded3d192f4bc47890663b69ff'
    (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $recorded
  }
}
```

- [ ] **Step 2: Run** `tools\Invoke-Tests.ps1 -Path tests\Spikes.Tests.ps1`. Expected: FAIL (the script does not exist). The launcher guard already passes (it pins today's state).
- [ ] **Step 3: Write `Spike-DriverListCapture.ps1`** per the Interfaces. Re-save with BOM.
- [ ] **Step 4: Write the docs.**
  - `docs/spikes.md`: in "Before you start", change "Nothing here goes on a customer machine" to say Spike 5 is the exception (list-only, made for customer Dell/HP laptops that came in for setup). New section **"Spike 5: What do the Dell and HP tools list, and what do their logs look like?"**: which machine (one Dell, one HP laptop, **before** the setup tool runs, on AC, online), how to run it from the USB stick (`powershell -ExecutionPolicy Bypass -File E:\spikes\Spike-DriverListCapture.ps1`; on a Dell without Dell Command Update add `-InstallTool`), what it never does, the 5-minute time, and **send back** the whole `capture-...` folder. Also: after the setup run on the same laptop, run it once more with `-InventoryOnly` (the vendor app's services, Start-menu entries and packages: the spec §9.3 `verify` values), and take `dcu-pass1.log` (Dell) or the `HPIA-pass1` folder (HP) from the stick's `BenTech-Logs\<PC name>` folder (Task 15) or, before Task 15 ships, from `C:\BenTech\Setup\Logs` (the apply log lines, spec §7). "What the result changes": the Dell/HP list readers, NOW per-update status and the report's "Driver updates" section (build order A, later plan). Quick-reference row.
  - `README.md` "Open spikes": one paragraph pointing at Spike 5.
- [ ] **Step 5: Run the full suite.** Expected: `Failed: 0`.
- [ ] **Step 6: Commit:** `chore: add list-only driver capture spike and pin the launcher hash`. **Tell Ben the capture script is ready** (it does not block the rest of this plan).

---

### Task 2: Screen colours and screen text (spec §9.1, §9.5 report text)

Built on v1 alone (Tasks 2-4 may ship before the rest of v2). The Dell's evidence (`D:\Setup`, read-only): the YELLOW final screen was near-white on near-white, and the report read `Windows      : ??Microsoft Windows 11 Home`.

**Files:**
- Modify: `src/UI/FinalScreen.ps1`, `src/UI/StartScreen.ps1` (`ConvertTo-ScreenText`, `Write-StartScreenLines`), `src/UI/ProgressScreen.ps1` (v1 default writer), `src/Engine/Reboot.ps1` (countdown line), `src/Entry/Main.ps1` (crash screen, "already running" line)
- Create: `tests/Colors.Tests.ps1`
- Test: `tests/Screens.Tests.ps1`, `tests/Finalize.Tests.ps1` (report line)

**Interfaces:**
- Produces:
  - `Get-VerdictColors -Color <string> -> @{ Background; Foreground }` (FinalScreen.ps1): `YELLOW` -> `Yellow` / `Black`; `GREEN` -> `DarkGreen` / `White`; anything else -> `DarkRed` / `White`.
  - `Show-FinalScreen`: the `-SetColor` seam becomes `param($background, $foreground)` (default sets `$Host.UI.RawUI.BackgroundColor` and `.ForegroundColor`), the `-Write` seam becomes `param($lines, $foreground, $background)` (default: `Clear-Host`, then each line `Write-Host -ForegroundColor $foreground -BackgroundColor $background`, the last without a newline). Keys, flush and launch unchanged.
  - Explicit colours on every other `Write-Host`: `Write-StartScreenLines` `Gray`/`Black` (warnings `Yellow`/`Black`); the v1 `Show-ProgressScreen` default writer `Gray`/`Black` (replaced in Task 7); the reboot countdown `White`/`Black`; Main's crash screen `White`/`DarkRed` (and `RawUI.ForegroundColor = 'White'` next to the existing background); "Setup is already running" `Yellow`/`Black`.
  - `ConvertTo-ScreenText`: first removes U+200E, U+200F, U+202A-U+202E and U+2066-U+2069 (written as code points, the file stays ASCII), then the v1 rules.

- [ ] **Step 1: Write the failing tests.**

```powershell
# tests/Colors.Tests.ps1 - static, parses files only.
BeforeAll { $script:files = @(Get-ChildItem (Resolve-Path "$PSScriptRoot\..\src").Path -Recurse -Filter *.ps1) }
Describe 'screen colours (spec 9.1)' {
  It 'no DarkYellow or DarkMagenta in src (comments aside) or in the launcher' {
    foreach ($f in $files) {
      $tokens = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$null)
      @($tokens | Where-Object { $_.Kind -ne 'Comment' -and $_.Text -match '(?i)Dark(Yellow|Magenta)' }).Count | Should -Be 0 -Because $f.Name
    }
    [IO.File]::ReadAllText("$PSScriptRoot\..\launcher\BenTechSetup.template.cmd") | Should -Not -Match '(?i)Dark(Yellow|Magenta)'
  }
  It 'every Write-Host in src sets its foreground and its background' {
    foreach ($f in $files) {
      $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
      foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host' }, $true)) {
        $names = @($c.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        ($names -contains 'ForegroundColor' -and $names -contains 'BackgroundColor') | Should -BeTrue -Because ('{0} line {1}' -f $f.Name, $c.Extent.StartLineNumber)
      }
    }
  }
}
```

Screens.Tests: `Invoke-FinalScreen`'s `-SetColor` becomes `{ param($b, $f) ...; $null = $script:colors.Add($b); $null = $script:fores.Add($f) }` with `$script:fores` initialised next to `$colors` (other tests keep reading `$colors[0]` as the background). Replace `'paints the console DarkGreen, DarkYellow or DarkRed by verdict colour'` with:
```powershell
It 'paints Black on Yellow, White on DarkGreen and White on DarkRed (spec 9.1)' {
  Invoke-FinalScreen -Color 'YELLOW'; $colors[0] | Should -Be 'Yellow'; $fores[0] | Should -Be 'Black'
  Invoke-FinalScreen -Color 'GREEN'; $colors[0] | Should -Be 'DarkGreen'; $fores[0] | Should -Be 'White'
  Invoke-FinalScreen -Color 'RED'; $colors[0] | Should -Be 'DarkRed'; $fores[0] | Should -Be 'White'
}
It 'the production writer sets both colours on every line' {
  $script:hostCalls = New-Object System.Collections.ArrayList; Mock Clear-Host { }
  Mock Write-Host { $null = $script:hostCalls.Add(@{ F = $ForegroundColor; B = $BackgroundColor }) }
  Show-FinalScreen -State (@{ Machine = $m; AnyDeskId = '123456789'; RebootCount = 0; StartedAt = '2026-10-18T09:00:00'; EndedAt = '2026-10-18T09:10:00' }) `
    -Verdict @{ Color = 'YELLOW'; Banner = 'COMPLETE - CHECK NOTES'; Failures = @(); Notes = @('n') } -ReportPath 'C:\r.txt' `
    -ReadKey { 'Q' } -SetColor { param($b, $f) } -ResetColor { } -FlushInput { } -Launch { param($t, $a) }
  @($hostCalls | Where-Object { $_.F -ne 'Black' -or $_.B -ne 'Yellow' }).Count | Should -Be 0
}
It 'strips direction and format marks before the ASCII filter (spec 9.5)' {
  $marks = 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069
  ConvertTo-ScreenText ((-join ($marks | ForEach-Object { [char]$_ })) + 'Microsoft Windows 11 Home') | Should -BeExactly 'Microsoft Windows 11 Home'
  ConvertTo-ScreenText ('Home ' + [char]0x05D1) | Should -BeExactly 'Home ?'
}
```
The existing `'clears the screen and writes the lines in white ...'` asserts `White` on `DarkGreen` (record `BackgroundColor` too); the start-screen writer test expects `Gray` instead of no colour for plain lines. Finalize.Tests: `It 'shows the Windows caption without the direction marks Hebrew Windows adds' { <state with OsCaption = [char]0x200F + [char]0x200E + 'Microsoft Windows 11 Home'> ; $l | Should -Contain 'Windows      : Microsoft Windows 11 Home 25H2 (26200) x64' }`.

- [ ] **Step 2: Run** `tests\Colors.Tests.ps1`, `tests\Screens.Tests.ps1`, `tests\Finalize.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM.
- [ ] **Step 4: Run** the three files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `fix: readable final-screen colours on any console palette; strip direction marks`.

---

### Task 3: Windows Update installs drivers; firmware only on AC (spec §9.2)

Evidence: `D:\Setup\Logs\setup.log` lines 151-178: both rounds skipped all 9 Dell driver and firmware updates with `userInput: true`. The v1 rule is in `Select-WuUpdates`: Skip when `CanRequestUserInput`, or when `IsWindows10` and the Upgrades category.

**Files:**
- Modify: `src/Steps/WindowsUpdate.ps1`, `src/Entry/Main.ps1` (`Invoke-SetupWuRoundProcess`)
- Test: `tests/WindowsUpdate.Tests.ps1`, `tests/Entry.Tests.ps1`

**Interfaces:**
- Consumes: `Test-OnACPower` (Detection.ps1).
- Produces:
  - `$script:WuBatteryNote = 'On battery: BIOS/firmware updates skipped'`: the exact text of Vendor.ps1's `$script:BatteryNote`, so the verdict's exact-match de-duplication (M1) shows it once.
  - `ConvertTo-WuUpdateInfo -Update <object> [-Type <'Software'|'Driver'> = 'Software']` adds `IsDriver` and `DriverClass` (`[string]$Update.DriverClass` read in a `try` only for drivers; `''` otherwise).
  - `Select-WuUpdates ... [bool]$OnAC = $true -> @{ Install; Hide; Skip; Deferred; OnlyDefinitions }`, in this order: **Skip** = (not `IsDriver` and `CanRequestUserInput`) or (`IsWindows10` and the Upgrades category); **Deferred** = `IsDriver`, `DriverClass -eq 'Firmware'` (case-insensitive) and not `$OnAC`: not installed, never hidden, its failure count untouched; **Hide** = failures >= `FailuresBeforeHide` (R24 unchanged); **Install** = the rest. `OnlyDefinitions` unchanged (Install only).
  - `Invoke-WuRound ... [bool]$OnAC = $true`: passes `-Type` of the search that found each update; logs each deferred update at INFO; the result JSON gains `FirmwareDeferred = @($selection.Deferred).Count`.
  - `Invoke-SetupWuRoundProcess`: power is read at the start of every round, `$onAC = [bool](Test-OnACPower)` in a `try` (a failed read = `$false`: firmware is never flashed on a guess, WARN), passed as `-OnAC`. The bundle's `param()` block and the launcher do not change.
  - `Invoke-StepWindowsUpdate`: a round whose `FirmwareDeferred` is above 0 carries the Note `$script:WuBatteryNote` on its result (Continue or Done). `Get-WuRoundOutcome` is unchanged: deferred updates are neither installed nor failed, so they never keep the loop going. R23, R23b and R24a-d keep their meaning.

- [ ] **Step 1: Write the failing tests.** Only change to existing test code: the helper `Invoke-TestRound` gains `[bool]$OnAC = $true`, passed through.

```powershell
Describe 'Select-WuUpdates: drivers and firmware (spec 9.2)' {
  BeforeAll { function D($id, [string]$class = 'System', [bool]$ui = $true) { [pscustomobject]@{ Id = $id; Title = $id; KBs = @(); CategoryIds = @(); CanRequestUserInput = $ui; IsDriver = $true; DriverClass = $class } } }
  It 'installs a driver that can ask for input' { (Select-WuUpdates -Updates @((D drv)) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false).Install.Id | Should -Be @('drv') }
  It 'still skips a software update that can ask for input' { (Select-WuUpdates -Updates @((U sw @() $true)) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false).Skip.Id | Should -Be @('sw') }
  It 'installs firmware on AC' { (Select-WuUpdates -Updates @((D fw 'Firmware')) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false -OnAC $true).Install.Id | Should -Be @('fw') }
  It 'defers firmware on battery: not installed, not hidden even after failures' {
    $r = Select-WuUpdates -Updates @((D fw 'firmware'), (D net 'Net')) -FailureCounts @{ fw = 5 } -FailuresBeforeHide 2 -IsWindows10 $false -OnAC $false
    $r.Deferred.Id | Should -Be @('fw'); @($r.Hide).Count | Should -Be 0; $r.Install.Id | Should -Be @('net')
  }
  It 'a driver that failed too often is still hidden (R24)' { (Select-WuUpdates -Updates @((D bad)) -FailureCounts @{ bad = 2 } -FailuresBeforeHide 2 -IsWindows10 $false).Hide.Id | Should -Be @('bad') }
}
# inside Context 'Invoke-WuRound (child round, COM mocked)':
It 'installs driver updates that can ask for input; software ones stay skipped' {
  $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'sw' -Ui $true)); $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'drv' -Ui $true))
  $r = Invoke-TestRound -StatePath (New-WuStateFile)
  $script:installCalls[0] | Should -Be @('drv'); @($r.Installed.Id) | Should -Be @('drv')
}
It 'leaves firmware alone on battery and counts it' {
  $fw = New-FakeUpdate -Id 'fw' -Ui $true; $fw | Add-Member NoteProperty DriverClass 'Firmware'
  $script:searchResults[$script:DriverCriteria] = @($fw, (New-FakeUpdate -Id 'net'))
  $r = Invoke-TestRound -StatePath (New-WuStateFile -FailureCounts @{ fw = 3 }) -OnAC $false
  $script:installCalls[0] | Should -Be @('net'); $script:hideCalls.Count | Should -Be 0; $r.FirmwareDeferred | Should -Be 1
}
It 'reads DriverClass only from driver search results' {
  $sw = New-FakeUpdate -Id 'sw'; $sw | Add-Member NoteProperty DriverClass 'Firmware'
  $script:searchResults[$script:SoftwareCriteria] = @($sw)
  $r = Invoke-TestRound -StatePath (New-WuStateFile) -OnAC $false
  @($r.Installed.Id) | Should -Be @('sw'); $r.FirmwareDeferred | Should -Be 0
}
# inside Context 'Invoke-StepWindowsUpdate (parent step, child process mocked)':
It 'adds the battery Note when the round left firmware for later' {
  $script:ctx = New-WuContext; $res = New-ChildResult; $res['FirmwareDeferred'] = 2; $script:childResult = $res
  $r = Invoke-StepWindowsUpdate -Context $script:ctx
  $r.Status | Should -Be 'Done'; $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
}
It 'uses the vendor pass''s exact battery text' { . "$PSScriptRoot\..\src\Steps\Vendor.ps1"; $script:WuBatteryNote | Should -BeExactly $script:BatteryNote }
```
Entry.Tests:
```powershell
It '-WuRound reads the power and passes -OnAC; a failed read counts as battery' {
  Mock Test-OnACPower { $true }; Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null
  Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $OnAC -eq $true }
  Mock Test-OnACPower { throw 'no power status' }; Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null
  Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $OnAC -eq $false }
}
```

- [ ] **Step 2: Run** `tests\WindowsUpdate.Tests.ps1`, `tests\Entry.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM. Never call the real WUA COM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0`, every existing R23/R24 test unchanged and green.
- [ ] **Step 5: Commit:** `fix: install Windows Update drivers that may ask for input; firmware only on AC`.

---

### Task 4: Vendor-app check, default-browser wait, activation attempt (spec §9.3, §9.4, §9.5)

**Files:**
- Modify: `src/Steps/Vendor.ps1` (`Invoke-StepConsumerApp`), `src/Steps/Finalize.ps1`
- Test: `tests/Vendor.Tests.ps1`, `tests/Finalize.Tests.ps1` (also dot-source `Steps\Winget` for `Invoke-PowerShellChild`), `tests/Config.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-PowerShellChild` (Winget.ps1), `Get-ActivationStatus` and `$script:WindowsLicensingApplicationId` (Report.ps1), `Get-DefaultBrowserProgId`, `Test-ChromeInstalled`.
- Produces:
  - `Test-ConsumerAppPresent -Verify <object> -> @{ Found = <bool>; Check = <string> }` (Vendor.ps1, never throws): each `paths` entry through `[Environment]::ExpandEnvironmentVariables`, then `Test-Path -Path` (wildcards allowed); each `services` entry `Get-Service -Name <n> -ErrorAction SilentlyContinue`. First hit wins: `Check = "file <path>"` or `"service <name>"`. A probe that throws is a miss.
  - `Invoke-StepConsumerApp`, after winget's Done only: no `verify` -> v1 `Done('<name> installed')`; found -> `Done('<name> installed (found <Check>)')` and an INFO log (from Task 9 the runner's activity line shows it); not found -> `Failed('<name> was not found after install')`. Store failures and everything else unchanged. `config.json` gets **no** `verify` values now (unknown until Ben's Start-menu check and Spike 5's inventory).
  - `Wait-ChromeDefault [-Attempts <int> = 25] [-PollSeconds <int> = 5] -> bool` (Finalize.ps1): reads `Get-DefaultBrowserProgId` at once and after each of up to 24 waits of 5 s (120 s), `$true` at the first `ChromeHTML`. It counts reads, not clock time, so it always ends. It waits with `Start-Sleep -Seconds` (Task 6 turns that into `Wait-SetupDelay`, which ticks).
  - `Complete-SetupFinalization` step 1: Chrome installed and the `default-browser` step Done -> `Wait-ChromeDefault`; Chrome installed otherwise -> one read (v1); not Chrome -> Note `'Chrome is not the default browser'` (and the final screen's B hint, unchanged). Step 2 (policy value and XML removed) stays after it.
  - `Invoke-WindowsActivation -> 'NotNeeded'|'Activated'|'Failed'` (Finalize.ps1, never throws): `Get-ActivationStatus` other than `'Not activated'` -> NotNeeded; no Windows `SoftwareLicensingProduct` row with a product key (read-only CIM query with the same filter as `Get-ActivationStatus`) -> NotNeeded; otherwise `Invoke-PowerShellChild -TimeoutMinutes 3 -Command` with exactly:
    ```
    $ErrorActionPreference = 'Stop'; $f = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL AND LicenseStatus <> 1"
    foreach ($p in @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $f)) { $r = Invoke-CimMethod -InputObject $p -MethodName Activate; if ($r.ReturnValue -ne 0) { exit 2 } }
    ```
    Exit 0 -> Activated (INFO). Timeout, another exit code or a child that cannot start -> WARN `'Windows activation attempt failed'` -> Failed. Phase B reads the status afterwards as before; its Note stays `'Windows not activated'` when it still is.
  - Called in `Invoke-FinalizePhaseA` right after `Restore-PostSetupSettings` and its save, before `Test-FinalRebootNeeded` (before the final restart); and in `Complete-SetupFinalization` before its own `Restore-PostSetupSettings` when `FinalRebootDone` is not `$true` (the R26 path that never ran Phase A). Phase B after the final restart does not call it again.

- [ ] **Step 1: Write the failing tests.**

```powershell
# Vendor.Tests (the step tests use the file's existing mocks and a Dell consumerApp; give it a verify object where a test says so)
It 'without verify keeps v1' { (Invoke-StepConsumerApp -Context $ctx).Message | Should -Be 'Dell SupportAssist installed' }
It 'a service that exists makes it Done and names the check' {
  <consumerApp.verify = [pscustomobject]@{ services = @('SupportAssistAgent') }>; Mock Get-Service { [pscustomobject]@{ Name = 'SupportAssistAgent' } } -ParameterFilter { $Name -eq 'SupportAssistAgent' }
  (Invoke-StepConsumerApp -Context $ctx).Message | Should -Be 'Dell SupportAssist installed (found service SupportAssistAgent)'
}
It 'nothing found after a successful install is Failed' {
  <verify paths that do not exist and a service Get-Service does not return>
  $r = Invoke-StepConsumerApp -Context $ctx; $r.Status | Should -Be 'Failed'; $r.Message | Should -Be 'Dell SupportAssist was not found after install'
}
It 'never checks when winget did not install it' { <msstore Failed>; (Invoke-StepConsumerApp -Context $ctx).Status | Should -Be 'Skipped'; Should -Invoke Get-Service -Times 0 }
# in a Describe without the file's Test-Path mock:
It 'Test-ConsumerAppPresent expands environment variables and wildcards' {
  $d = "$TestDrive\SA\App-1.2"; [void][IO.Directory]::CreateDirectory($d); 'x' | Set-Content "$d\SupportAssist.exe"; $env:BT_TEST_SA = "$TestDrive\SA"
  try { $r = Test-ConsumerAppPresent -Verify ([pscustomobject]@{ paths = @('%BT_TEST_SA%\App-*\SupportAssist.exe') }); $r.Found | Should -BeTrue; $r.Check | Should -Match '^file ' } finally { Remove-Item Env:\BT_TEST_SA }
}
# Config.Tests
It 'every consumerApp verify entry, when present, lists paths and/or services as strings' {
  foreach ($v in $cfg.vendors.PSObject.Properties.Value) { $ver = $v.consumerApp.verify; if ($null -eq $ver) { continue }
    (@($ver.paths) + @($ver.services) | Where-Object { $_ }).Count | Should -BeGreaterThan 0
    foreach ($s in @($ver.paths) + @($ver.services)) { if ($null -ne $s) { $s | Should -BeOfType [string] } } }
}
```

```powershell
# Finalize.Tests (Start-Sleep and Get-DefaultBrowserProgId mocked; reuse the Phase B fixtures)
Describe 'Chrome as default: wait before the policy goes (spec 9.4)' {
  It 'waits until Chrome is the default, then removes the policy' {
    $script:reads = 0; Mock Get-DefaultBrowserProgId { $script:reads++; if ($script:reads -ge 4) { 'ChromeHTML' } else { 'MSEdgeHTM' } }
    <default-browser Done; record the order of the last read and the policy removal>
    $null = Complete-SetupFinalization -Context $ctx
    $reads | Should -Be 4; Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 5 }
    $ctx.State.Notes | Should -Not -Contain 'Chrome is not the default browser'; <policy removed after the 4th read>
  }
  It 'gives up after 120 s with the yellow Note' {
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }; $null = Complete-SetupFinalization -Context $ctx
    Should -Invoke Get-DefaultBrowserProgId -Times 25 -Exactly; Should -Invoke Start-Sleep -Times 24 -Exactly
    $ctx.State.Notes | Should -Contain 'Chrome is not the default browser'
  }
  It 'reads once when the default-browser step did not set the policy' { <default-browser Skipped>; $null = Complete-SetupFinalization -Context $ctx; Should -Invoke Get-DefaultBrowserProgId -Times 1 -Exactly }
}
Describe 'Windows activation attempt (spec 9.5)' {
  BeforeEach { Mock Get-ActivationStatus { 'Not activated' }; Mock Get-CimInstance { [pscustomobject]@{ LicenseStatus = 5 } } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
    Mock Invoke-PowerShellChild { @{ ExitCode = 0; TimedOut = $false; Output = '' } } }
  It 'activates in a 3-minute child when a key is installed but not activated' {
    Invoke-WindowsActivation | Should -Be 'Activated'
    Should -Invoke Invoke-PowerShellChild -Times 1 -Exactly -ParameterFilter { $TimeoutMinutes -eq 3 -and $Command -match "MethodName Activate" -and $Command -match '55c92734-d682-4d71-983e-d6ec3f16059f' }
  }
  It 'does nothing when activated, unknown, or without a product key' {
    Mock Get-ActivationStatus { 'Activated' }; Invoke-WindowsActivation | Should -Be 'NotNeeded'
    Mock Get-ActivationStatus { 'Unknown' }; Invoke-WindowsActivation | Should -Be 'NotNeeded'
    Mock Get-ActivationStatus { 'Not activated' }; Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }; Invoke-WindowsActivation | Should -Be 'NotNeeded'
    Should -Invoke Invoke-PowerShellChild -Times 0 -Exactly
  }
  It 'a timeout or a failure is a WARN and never throws' {
    Mock Invoke-PowerShellChild { @{ ExitCode = $null; TimedOut = $true; Output = '' } }; Invoke-WindowsActivation | Should -Be 'Failed'
    Mock Invoke-PowerShellChild { throw 'cannot start' }; Invoke-WindowsActivation | Should -Be 'Failed'
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Message -eq 'Windows activation attempt failed' }
  }
  It 'Phase A tries it before deciding the final restart; Phase B after the restart does not' {
    $script:order = New-Object System.Collections.ArrayList
    Mock Invoke-WindowsActivation { [void]$script:order.Add('activate'); 'Activated' }; Mock Test-FinalRebootNeeded { [void]$script:order.Add('restart?'); $true }
    $null = Invoke-StepFinalize -Context $ctx; @($order) | Should -Be @('activate', 'restart?')
    $null = Invoke-StepFinalize -Context $ctx; Should -Invoke Invoke-WindowsActivation -Times 1 -Exactly   # second call = Phase B
  }
  It 'the R26 path without Phase A tries it once' { Mock Invoke-WindowsActivation { 'Failed' }; <FinalRebootDone $false>; $null = Complete-SetupFinalization -Context $ctx; Should -Invoke Invoke-WindowsActivation -Times 1 -Exactly }
}
```

- [ ] **Step 2: Run** `tests\Vendor.Tests.ps1`, `tests\Finalize.Tests.ps1`, `tests\Config.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM. Never run activation, Get-Service probes or Finalize for real.
- [ ] **Step 4: Run** the three files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `fix: verify the vendor app, wait for Chrome as default, try Windows activation`.
- [ ] **Step 6: Release checkpoint (spec §9 can ship on its own).**
  - Full suite: last line `Failed: 0`.
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Bundle.ps1 -Version 2026.10.20.1 -OutDir <scratchpad>\dist9` builds without error.
  - Tell Ben Tasks 2-4 are ready to publish as their own release. If he wants it now, first add the §9 items of Task 16 Step 1 to `docs\testing.md`, then run `tools\Publish.ps1 -Version <his version> -DryRun`. **The real publish is Ben's call: never run it, `gh` or `git push`.**

---

### Task 5: Live-status plumbing: activity feed, tick, NOW state

**Files:**
- Create: `src/Common/Activity.ps1`, `tests/Activity.Tests.ps1`
- Modify: `tools/Build-Bundle.ps1` (`'Common\Activity.ps1'` right after `'Common\Logging.ps1'`)
- Modify (one line each): every test `BeforeAll` that dot-sources `src\Common\Logging.ps1` also dot-sources `src\Common\Activity.ps1` right after it: `Apps`, `Common`, `Download`, `Entry`, `Finalize`, `Launcher` (the block near line 529), `Prepare`, `Process` (also the `$prefix` in `Invoke-InHostWithOpenStdin`), `Runner`, `Screens`, `State`, `SystemSteps`, `Vendor`, `WindowsUpdate` (both blocks), `Winget`.

**Interfaces:**
- Consumes: `Write-SetupLog` (Logging.ps1).
- Produces (all in `src/Common/Activity.ps1`; none of them throws):
  - Feed: `$script:SetupActivityPath = $null`, `$script:SetupActivityRecent` (newest-first list, max 50).
    - `Initialize-SetupActivity -LogDirectory <string>`: path = `<LogDirectory>\activity.txt`; seeds the in-memory list from the file's last 64 KB (so the history survives a restart).
    - `Reset-SetupActivityLog -LogDirectory <string> [-PreviousRunId <string>]`: a new run (not a resume) renames an existing `activity.txt` to `activity-<PreviousRunId>.txt` (no id: `activity-<file LastWriteTime yyyyMMdd-HHmmss>.txt`; a taken name gets `-2`, `-3`, ...), empties the list, sets the path. `Move-Item -ErrorAction Stop` inside the `try`.
    - `Add-SetupActivity -Text <string> [-LogText <string>]`: CR, LF and TAB become one space; appends the activity line when the path is set (`[IO.File]::AppendAllText`, UTF-8 without BOM); adds it to the list; logs `'Activity: ' + (LogText, else Text)` at INFO.
    - `Get-SetupActivityLines -Count <int> -> object[]` (`Time`, `Text`), newest first.
    - `Read-FileTail -Path <string> [-MaxBytes <int> = 65536] -> string|$null`: opens with `FileShare.ReadWrite -bor FileShare.Delete`; decodes UTF-16LE when the file starts with `FF FE`, else UTF-8 (BOM dropped); when it started mid-file, drops the partial first line; `$null` when missing or unreadable.
  - Tick: `Register-SetupTick -Handler <scriptblock> -Context <hashtable> [-Clock <scriptblock>]` (Clock returns elapsed milliseconds as `[long]`; default a process Stopwatch), `Unregister-SetupTick`.
    - `Invoke-SetupTick [-Force]`: no handler -> return. Not `-Force` and less than 1000 ms since the last run -> return. Re-entrant call -> return. Otherwise `& $handler $context | Out-Null` inside a one-shot `foreach` + `try/catch` (so `break`/`continue` cannot escape, like `Save-SetupProgress`). An error is logged `WARN 'Progress display failed; continuing'` with the message, at most once per 60 000 ms of the Clock.
    - `Wait-SetupDelay -Seconds <double>` | `-Milliseconds <int>` (two parameter sets). No handler: exactly one `Start-Sleep` with the same parameter and value. With a handler: `Start-Sleep -Milliseconds` slices of at most 250, `Invoke-SetupTick` after each; it ends when either the Clock or the sum of the slices reaches the total (a clock that stands still or jumps back cannot stretch it).
  - NOW: `Set-SetupNow [-Title <string>] [-SubTitle <string>] [-Provider <scriptblock>] [-ProviderArgument <object>]` (sets only what is given), `Clear-SetupNow` (resets all, the wait stack too), `Get-SetupNow -> hashtable` (shape in Shared shapes), `Enter-SetupWait -LimitMinutes <double> [-StartedAt <datetime>]` (push; StartedAt defaults to now), `Exit-SetupWait` (pop; empty is a no-op). A provider is called as `& $Provider $ProviderArgument` (never `.GetNewClosure()`: a closure's module scope cannot see the bundle's functions).

- [ ] **Step 1: Write the failing tests** (`tests/Activity.Tests.ps1`). Every test uses `$TestDrive`; `BeforeEach` calls `Unregister-SetupTick` and `Clear-SetupNow`.

```powershell
BeforeAll {
  . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Activity.ps1"
  $script:Hebrew = -join [char[]](0x05E2, 0x05D3, 0x05DB, 0x05D5, 0x05DF)
  function New-LogDir { $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($d); $d }
}
Describe 'activity feed' {
  BeforeEach {
    $script:dir = New-LogDir; $script:logged = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logged.Add($Message) }
    Initialize-SetupActivity -LogDirectory $dir
  }
  It 'appends "yyyy-MM-dd HH:mm:ss<TAB>text" as UTF-8 without a BOM and logs it once' {
    Add-SetupActivity -Text 'Google Chrome 141.0 installed'
    ([IO.File]::ReadAllBytes("$dir\activity.txt"))[0] | Should -Not -Be 0xEF
    [IO.File]::ReadAllText("$dir\activity.txt") | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\tGoogle Chrome 141\.0 installed\r\n$'
    @($logged | Where-Object { $_ -eq 'Activity: Google Chrome 141.0 installed' }).Count | Should -Be 1
  }
  It 'keeps the AnyDesk ID out of setup.log' {
    Add-SetupActivity -Text 'AnyDesk 9.0 - ID 123456789' -LogText 'AnyDesk 9.0 - ID recorded'
    [IO.File]::ReadAllText("$dir\activity.txt") | Should -Match '123456789'
    (Get-SetupActivityLines -Count 1)[0].Text | Should -Be 'AnyDesk 9.0 - ID 123456789'
    @($logged | Where-Object { $_ -match '123456789' }).Count | Should -Be 0
    $logged | Should -Contain 'Activity: AnyDesk 9.0 - ID recorded'
  }
  It 'flattens line breaks and tabs' { Add-SetupActivity -Text "a`r`nb`tc"; (Get-SetupActivityLines -Count 1)[0].Text | Should -Be 'a b c' }
  It 'never throws when the file cannot be written, and still shows the line' {
    Initialize-SetupActivity -LogDirectory (Join-Path $dir 'gone\deeper')
    { Add-SetupActivity -Text 'x' } | Should -Not -Throw
    (Get-SetupActivityLines -Count 1)[0].Text | Should -Be 'x'
  }
  It 'returns the newest lines first, at most Count' {
    'one','two','three' | ForEach-Object { Add-SetupActivity -Text $_ }
    @(Get-SetupActivityLines -Count 2).Text | Should -Be @('three', 'two')
  }
  It 'brings the history back after a restart' {
    [IO.File]::WriteAllText("$dir\activity.txt", "2026-10-20 12:27:00`tAnyDesk installed`r`n2026-10-20 12:28:00`tRename PC done`r`n")
    Initialize-SetupActivity -LogDirectory $dir
    $l = @(Get-SetupActivityLines -Count 5)
    $l.Count | Should -Be 2; $l[0].Text | Should -Be 'Rename PC done'; $l[0].Time | Should -Be ([datetime]'2026-10-20T12:28:00')
  }
  It 'reads at most the last 64 KB of a big file and keeps at most 50 lines' {
    $sb = New-Object Text.StringBuilder; for ($i = 0; $i -lt 6000; $i++) { [void]$sb.Append("2026-10-20 12:00:00`tline $i`r`n") }
    [IO.File]::WriteAllText("$dir\activity.txt", $sb.ToString())
    Initialize-SetupActivity -LogDirectory $dir
    $l = @(Get-SetupActivityLines -Count 100); $l.Count | Should -Be 50; $l[0].Text | Should -Be 'line 5999'
  }
  It 'a new run archives the old file as activity-<RunId>.txt and starts empty; a second archive gets -2' {
    Add-SetupActivity -Text 'old run'
    Reset-SetupActivityLog -LogDirectory $dir -PreviousRunId '20261019-090000'
    "$dir\activity-20261019-090000.txt" | Should -Exist; "$dir\activity.txt" | Should -Not -Exist
    @(Get-SetupActivityLines -Count 5).Count | Should -Be 0
    Add-SetupActivity -Text 'again'; Reset-SetupActivityLog -LogDirectory $dir -PreviousRunId '20261019-090000'
    "$dir\activity-20261019-090000-2.txt" | Should -Exist
  }
}
Describe 'Read-FileTail' {
  It 'decodes UTF-16LE with Hebrew' { $p = "$TestDrive\u16.log"; [IO.File]::WriteAllText($p, "a`r`n$Hebrew", [Text.Encoding]::Unicode); Read-FileTail -Path $p | Should -Match $Hebrew }
  It 'reads a file another process holds open for writing' {
    $p = "$TestDrive\held.log"; $w = [IO.File]::Open($p, 'Create', 'Write', 'ReadWrite')
    try { $b = [Text.Encoding]::UTF8.GetBytes("first`r`nlast line`r`n"); $w.Write($b, 0, $b.Length); $w.Flush(); Read-FileTail -Path $p | Should -Match 'last line' } finally { $w.Dispose() }
  }
  It 'reads at most MaxBytes and drops the cut first line' {
    $p = "$TestDrive\big.log"; [IO.File]::WriteAllText($p, ('x' * 70000) + "`r`ntail")
    $t = Read-FileTail -Path $p; $t.Length | Should -BeLessOrEqual 65536; $t | Should -Not -Match 'x'; $t | Should -Match 'tail'
  }
  It 'returns $null for a missing file' { Read-FileTail -Path "$TestDrive\none.log" | Should -BeNullOrEmpty }
}
Describe 'tick' {
  BeforeEach { Unregister-SetupTick; $script:ms = [long]0; $script:ctx = @{ Calls = 0 }; $script:warns = 0
    Mock Write-SetupLog { if ($Level -eq 'WARN') { $script:warns++ } } }
  It 'is a no-op with no handler' { { Invoke-SetupTick -Force } | Should -Not -Throw }
  It 'calls the handler with the context, at most once a second unless forced' {
    Register-SetupTick -Context $ctx -Handler { param($c) $c.Calls++ } -Clock { $script:ms }
    Invoke-SetupTick; $script:ms = 500; Invoke-SetupTick; $ctx.Calls | Should -Be 1
    $script:ms = 1000; Invoke-SetupTick; $ctx.Calls | Should -Be 2
    Invoke-SetupTick -Force; $ctx.Calls | Should -Be 3
  }
  It 'a throwing tick is logged once per minute and never escapes' {
    Register-SetupTick -Context $ctx -Handler { throw 'no console' } -Clock { $script:ms }
    foreach ($t in 0, 1000, 2000) { $script:ms = $t; { Invoke-SetupTick } | Should -Not -Throw }
    $warns | Should -Be 1
    $script:ms = 61000; Invoke-SetupTick; $warns | Should -Be 2
  }
  It 'does not re-enter itself' {
    Register-SetupTick -Context $ctx -Handler { param($c) $c.Calls++; Invoke-SetupTick -Force } -Clock { $script:ms }
    Invoke-SetupTick -Force; $ctx.Calls | Should -Be 1
  }
  It 'a handler using break cannot stop the caller''s loop' {
    Register-SetupTick -Context $ctx -Handler { break } -Clock { $script:ms }
    $after = 0; foreach ($i in 1..3) { Invoke-SetupTick -Force; $after++ }; $after | Should -Be 3
  }
}
Describe 'Wait-SetupDelay' {
  BeforeEach { Unregister-SetupTick; $script:sleeps = New-Object System.Collections.ArrayList; $script:ms = [long]0
    Mock Start-Sleep { [void]$script:sleeps.Add(@{ S = $Seconds; M = $Milliseconds }); $script:ms += $Milliseconds } }
  It 'without a tick is exactly one Start-Sleep with the same argument' {
    Wait-SetupDelay -Seconds 120; Wait-SetupDelay -Milliseconds 5000
    $sleeps.Count | Should -Be 2; $sleeps[0].S | Should -Be 120; $sleeps[1].M | Should -Be 5000
  }
  It 'with a tick sleeps in slices of at most 250 ms and ticks between them' {
    $script:ticks = 0; Register-SetupTick -Context @{} -Handler { $script:ticks++ } -Clock { $script:ms }
    Wait-SetupDelay -Seconds 2
    @($sleeps | Where-Object { $_.M -gt 250 }).Count | Should -Be 0
    ($sleeps | Measure-Object -Property M -Sum).Sum | Should -Be 2000
    $ticks | Should -BeGreaterOrEqual 2
  }
  It 'still ends when the clock stands still' {
    Register-SetupTick -Context @{} -Handler { } -Clock { [long]0 }
    Wait-SetupDelay -Milliseconds 1000; ($sleeps | Measure-Object -Property M -Sum).Sum | Should -Be 1000
  }
}
Describe 'NOW state' {
  BeforeEach { Clear-SetupNow }
  It 'sets only what is given and clears everything' {
    Set-SetupNow -SubTitle 'Dell Command Update'; Set-SetupNow -Provider { 'x' } -ProviderArgument 'p'
    (Get-SetupNow).SubTitle | Should -Be 'Dell Command Update'; (Get-SetupNow).ProviderArgument | Should -Be 'p'
    Clear-SetupNow; (Get-SetupNow).SubTitle | Should -BeNullOrEmpty; (Get-SetupNow).Provider | Should -BeNullOrEmpty
  }
  It 'keeps a stack of waits; the top one is shown' {
    Enter-SetupWait -LimitMinutes 60; Enter-SetupWait -LimitMinutes 5
    (Get-SetupNow).Wait.LimitMinutes | Should -Be 5; Exit-SetupWait; (Get-SetupNow).Wait.LimitMinutes | Should -Be 60
    Exit-SetupWait; Exit-SetupWait; (Get-SetupNow).Wait | Should -BeNullOrEmpty
  }
}
```

- [ ] **Step 2: Run** `tools\Invoke-Tests.ps1 -Path tests\Activity.Tests.ps1`. Expected: FAIL (file missing).
- [ ] **Step 3: Implement `src/Common/Activity.ps1`** per the Interfaces; add it to `$BundleOrder`; add the dot-source line to the test files listed above. Re-save with BOM.
- [ ] **Step 4: Run** the file, then the full suite. Expected: `Failed: 0` both (nothing calls the new functions yet).
- [ ] **Step 5: Commit:** `feat: add activity feed, tick and NOW state`.

---

### Task 6: Every long wait ticks

**Files:**
- Modify: `src/Common/Process.ps1`, `src/Common/Download.ps1`, `src/Steps/Apps.ps1` (lines ~127, ~237), `src/Steps/BitLocker.ps1` (~231), `src/Steps/Prepare.ps1` (~612), `src/Steps/Winget.ps1` (~430), `src/Steps/Vendor.ps1` (~501, ~581, ~869), `src/Steps/WindowsUpdate.ps1` (~890), `src/Steps/Finalize.ps1` (`Wait-ChromeDefault`, Task 4)
- Create: `tests/Waits.Tests.ps1`
- Test: `tests/Process.Tests.ps1`, `tests/Download.Tests.ps1`, `tests/Vendor.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-SetupTick`, `Wait-SetupDelay`, `Enter-SetupWait`, `Exit-SetupWait`, `Get-SetupNow` (Task 5).
- Produces:
  - `Invoke-External`: signature and return unchanged. `Enter-SetupWait -LimitMinutes $TimeoutMinutes` before its wait loop, `Exit-SetupWait` in its `finally`, `Invoke-SetupTick` after every slice of the loop.
  - `Start-BackgroundExternal -FilePath <string> [-ArgumentList <string>] -> System.Diagnostics.Process` (Process.ps1): `ProcessStartInfo` with `UseShellExecute = $true` and `WindowStyle = Hidden` (its own hidden console: no handles inherited, nothing lands on the setup screen, the operator's keys never reach it); touches `.Handle` right after the start so `ExitCode` stays readable; logs file, arguments and process id at INFO; a program that cannot start throws `InvalidOperationException("Cannot start '<file>': <reason>")` like `Invoke-External`. Its only caller is the `office` step (Task 13); it is the Global Constraints exception.
  - `Get-RemoteFile` gains `[ValidateRange(0.001, 1440)][double]$TimeoutMinutes = 30`. Each attempt: `$client.DownloadFileTaskAsync([uri]$Url, $part)`, waiting with `[Threading.Tasks.Task]::WaitAny(@($task), 250)` and `Invoke-SetupTick` between slices (no `Start-Sleep`), `Enter-SetupWait`/`Exit-SetupWait` around it; at the deadline `$client.CancelAsync()`, wait at most 2 s, then throw `TimeoutException("download timed out after <n> min: <url>")` (the attempt fails; the retries apply). A finished task is completed with `$task.GetAwaiter().GetResult()` (rethrows the WebException). `Invoke-DownloadAttempt`'s backoff becomes `Wait-SetupDelay -Milliseconds <same value>`.
  - Every `Start-Sleep` in the listed step lines becomes `Wait-SetupDelay` with the same parameter name and value. The bounded waits also publish their limit (`Enter-SetupWait` before the loop, `Exit-SetupWait` in a `finally`): `Wait-BitLockerDecrypted` (`-LimitMinutes $TimeoutMinutes`), `Wait-LenovoProcessExit` (`$TimeoutSeconds / 60`), `Find-AnyDeskId` (`$TimeoutMinutes`), `Wait-WingetPath` (`$TimeoutMinutes`), `Wait-ChromeDefault` (`($Attempts - 1) * $PollSeconds / 60`, i.e. 2 min).
  - Unchanged on purpose: `Write-SetupLog`'s 200 ms retry, `Save-RunState`'s 150 ms retry, the reboot countdown in `Invoke-ControlledReboot`, the start screen's `-Sleep` seam.

- [ ] **Step 1: Write the failing tests.**

```powershell
# tests/Waits.Tests.ps1 - static guard, parses files only.
BeforeAll {
  $script:srcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
  $script:sleepers = @(foreach ($f in Get-ChildItem $srcRoot -Recurse -Filter *.ps1) {
    $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Sleep' }, $true)) {
      $fn = $c.Parent; while ($null -ne $fn -and $fn -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
      '{0}|{1}' -f $f.FullName.Substring($srcRoot.Length + 1), $(if ($fn) { $fn.Name } else { '<top>' })
    } })
}
Describe 'every long wait ticks' {
  It 'Start-Sleep is left only where no tick may run' {
    ($sleepers | Sort-Object -Unique) | Should -Be @(
      'Common\Activity.ps1|Wait-SetupDelay', 'Common\Logging.ps1|Write-SetupLog', 'Engine\Reboot.ps1|Invoke-ControlledReboot',
      'State\State.ps1|Save-RunState', 'UI\StartScreen.ps1|Show-StartScreen')
  }
}
```

Process.Tests (real, harmless processes, as the file already does):
```powershell
Describe 'Invoke-External and the tick' {
  BeforeEach { Unregister-SetupTick; Clear-SetupNow; $script:seen = New-Object System.Collections.ArrayList }
  AfterEach { Unregister-SetupTick }
  It 'ticks while it waits, shows its timeout as the wait limit, and clears it after' {
    Register-SetupTick -Context @{} -Handler { [void]$script:seen.Add((Get-SetupNow).Wait) }
    (Invoke-External -FilePath "$env:windir\System32\PING.EXE" -ArgumentList '-n 3 127.0.0.1' -TimeoutMinutes 0.5).ExitCode | Should -Be 0
    $seen.Count | Should -BeGreaterThan 0; $seen[0].LimitMinutes | Should -Be 0.5
    (Get-SetupNow).Wait | Should -BeNullOrEmpty
  }
  It 'a throwing tick never breaks Invoke-External' {
    Register-SetupTick -Context @{} -Handler { throw 'screen gone' }
    (Invoke-External -FilePath "$env:windir\System32\cmd.exe" -ArgumentList '/c ping -n 2 127.0.0.1 >nul & exit 3' -TimeoutMinutes 1).ExitCode | Should -Be 3
  }
}
Describe 'Start-BackgroundExternal' {
  It 'returns at once and keeps the exit code readable' {
    $p = Start-BackgroundExternal -FilePath "$env:windir\System32\cmd.exe" -ArgumentList '/c exit 7'
    $p.Id | Should -BeGreaterThan 0; $p.WaitForExit(10000) | Should -BeTrue; $p.ExitCode | Should -Be 7
  }
  It 'throws for a program that does not exist' { { Start-BackgroundExternal -FilePath "$TestDrive\nope.exe" } | Should -Throw '*Cannot start*' }
}
```

Download.Tests (every existing test stays as it is):
```powershell
It 'gives up on a download that never finishes, cancels it, and reports the attempts' {
  $script:cancels = 0
  Mock New-SetupWebClient {
    $c = [pscustomobject]@{}
    $c | Add-Member ScriptMethod DownloadFileTaskAsync { param($u, $p) (New-Object 'Threading.Tasks.TaskCompletionSource[object]').Task }
    $c | Add-Member ScriptMethod CancelAsync { $script:cancels++ }
    $c | Add-Member ScriptMethod Dispose { }
    $c }
  $err = $null
  try { Get-RemoteFile -Url 'https://example.invalid/x.exe' -Destination "$TestDrive\x.exe" -Retries 1 -BackoffSeconds 0 -TimeoutMinutes 0.001 } catch { $err = $_ }
  $err.Exception.Message | Should -BeExactly 'download failed after 1 attempts: https://example.invalid/x.exe'
  $err.Exception.InnerException.Message | Should -Match 'timed out'
  $script:cancels | Should -Be 1
}
It 'ticks while downloading and still copies the file' {
  $script:ticks = 0; Register-SetupTick -Context @{} -Handler { $script:ticks++ }
  try { Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination "$TestDrive\t.txt" -BackoffSeconds 0 | Should -Exist } finally { Unregister-SetupTick }
}
```

Vendor.Tests (one representative bounded wait):
```powershell
It 'Wait-LenovoProcessExit shows its limit while it waits and removes it after' {
  $script:limits = New-Object System.Collections.ArrayList
  Mock Get-Process { [void]$script:limits.Add((Get-SetupNow).Wait.LimitMinutes); @() }
  Wait-LenovoProcessExit -TimeoutSeconds 120 -PollSeconds 0.001 | Should -BeTrue
  $limits[0] | Should -Be 2; (Get-SetupNow).Wait | Should -BeNullOrEmpty
}
```

- [ ] **Step 2: Run** the four test files. Expected: FAIL (`Waits.Tests` lists the step sleepers; the new process/download/vendor tests fail).
- [ ] **Step 3: Implement** per the Interfaces. Re-save with BOM. **Do not run any step, vendor tool or setup.exe for real.**
- [ ] **Step 4: Run** the four files, then the full suite. Expected: `Failed: 0` (every existing `Mock Start-Sleep` test still sees exactly its one call: no tick is registered in those tests).
- [ ] **Step 5: Commit:** `feat: tick during child processes, downloads and step waits`.

---

### Task 7: Console frame and the v2 progress screen

**Files:**
- Create: `src/UI/ConsoleFrame.ps1`
- Modify: `src/UI/ProgressScreen.ps1` (rewrite), `src/Engine/Catalog.ps1` (add `Short` to every entry), `tools/Build-Bundle.ps1` (`'UI\ConsoleFrame.ps1'` right before `'UI\StartScreen.ps1'`)
- Test: `tests/Screens.Tests.ps1` (replace the `Format-ProgressScreen` and `Show-ProgressScreen` Describes; dot-source `UI\ConsoleFrame` and `Common\Activity`), `tests/Catalog.Tests.ps1`

**Interfaces:**
- Consumes: `Get-SetupNow`, `Get-SetupActivityLines` (Task 5); `ConvertTo-ScreenText`, `Limit-ScreenLine`, `ConvertFrom-StateTime` (StartScreen.ps1).
- Produces, `src/UI/ConsoleFrame.ps1`:
  - `New-ConsoleWriter -> hashtable` with four script blocks: `GetSize` (returns `@{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight; Top = [Console]::WindowTop }`), `Clear` (`param($background)`: sets `[Console]::BackgroundColor`, then `[Console]::Clear()`, so the whole window takes that colour), `MoveTo` (`param($row) [Console]::SetCursorPosition(0, $row)`), `Write` (`param($text, $foreground, $background)`: sets **both** `[Console]::ForegroundColor` and `[Console]::BackgroundColor`, `[Console]::Write($text)`, `[Console]::ResetColor()`; spec §9.1). Tests always pass a fake writer with the same four keys.
  - `ConvertTo-ConsoleFrame -Lines <string[]> -Width <int> -Height <int> -> string[]` (pure): exactly `Height` entries, each exactly `Width` characters (padded or cut); extra lines dropped.
  - `Write-ConsoleFrame -Lines <string[]> -Writer <hashtable> [-Colorize <scriptblock>] [-Foreground <string> = 'Gray'] [-Background <string> = 'Black']`: `GetSize`; `Clear $Background` only when the size differs from the last frame (`$script:ConsoleFrameLastSize`) or after `Reset-ConsoleFrame`; frame = `ConvertTo-ConsoleFrame -Width (Width - 1) -Height (Height - 1)` (never the last column or row, so nothing wraps or scrolls); per row `MoveTo (Top + r)`, then `Write` each segment from `& $Colorize $line` (default: one uncoloured segment) with its `Color` (else `-Foreground`) and its `Background` (else `-Background`), so every write carries both colours; finally `MoveTo (Top + Height - 1)` parks the cursor. A writer that throws propagates (the tick catches it).
  - `Reset-ConsoleFrame`: forgets the last size, so the next frame clears.
  - `Get-ConsoleTargetSize -Current <hashtable Width,Height,BufferWidth,BufferHeight> -Largest <hashtable Width,Height> [-WantedWidth 100] [-WantedHeight 45] -> @{ WindowWidth; WindowHeight; BufferWidth; BufferHeight }` (pure): window = max(current, min(wanted, largest)) per axis; buffer = max(current buffer, window) per axis.
  - `Resize-SetupConsole -> bool`: applies it with `[Console]::SetBufferSize` then `SetWindowSize`; any failure (Windows Terminal refuses) is logged at INFO and returns `$false`. Never throws.
- Produces, `src/UI/ProgressScreen.ps1` (all pure except the last two):
  - `$script:ProgressSpinnerFrames = @('|', '/', '-', '\')`, `$script:ProgressSpinnerIndex = 0`, `$script:NowDetailMaxLines = 10`.
  - `Format-Elapsed -Span <timespan> -> 'HH:mm:ss'` (hours not wrapped; negative = 00:00:00); `Format-MinutesSeconds -Span <timespan> -> 'mm:ss'` (minutes not wrapped, e.g. `101:07`).
  - `Get-ChecklistEntry -State <hashtable> -Id <string> -Short <string> -Now <datetime> -> string`: `[OK]` Done, `[>>]` running, `[X ]` Failed, `[--]` Skipped, `[..]` anything else, then a space and `Short`. The `office` line folds `office-finish` (spec §4.6): office Failed/Skipped -> office's own marker; office-finish Done/Failed/Skipped -> its marker; office-finish running -> `[>>] Microsoft 365`; office Done with `Data.Background` and office-finish not started: `Data.Finished` -> `[..] Microsoft 365 (bg ended)`, else `[>>] Microsoft 365 (bg) <mm:ss since Data.StartedAt>`.
  - `Format-Checklist -Entries <string[]> -Width <int> -> string[]`: column width = longest entry + 3; columns = max(1, floor((Width - 2) / column width)); rows = ceil(n / columns); filled column by column; each line starts with two spaces; trailing spaces trimmed.
  - `Format-ProgressScreen -State <hashtable> -Catalog <object[]> -Now <datetime> -Width <int> -Height <int> [-Spinner <string> = '|'] [-NowView <hashtable>] [-Activity <object[]>] -> string[]`, in order:
    1. `'  BENTECH WINDOWS SETUP - working, do not turn off   {spinner}   Total {Format-Elapsed since State.StartedAt}   Restarts {RebootCount}'`
    2. `'  ' + ('-' * max(10, Width - 4))`
    3. the checklist: plan order, `office-finish` never listed, `Short` (else `Title`, else the id)
    4. the separator
    5. `'  NOW  {title}'` + `' - {SubTitle}'` when given + `'   /   {mm:ss}'` + `' (of max {N} min)'` when a wait is active. Title: `NowView.Title`, else the running step's `Short`, else `-`. Time: when `NowView.Wait` is set, the time since `Wait.StartedAt` and `N = ceiling(Wait.LimitMinutes)`; otherwise the running step's time since its `StartedAt` and no limit; nothing running and no title: no time part.
    6. detail lines `'       ' + text` (7 spaces): `NowView.Lines`, else the newest activity text; at most `NowDetailMaxLines` and the room left; a cut list ends in `'       ... and {N} more'`.
    7. the separator, `'  JUST HAPPENED'`, then `'  {HH:mm}  {text}'` newest first, as many as fit; the whole block is left out when fewer than 3 rows remain.
    Free text goes through `ConvertTo-ScreenText`; every line is cut to `Width - 1` (`Limit-ScreenLine`); at most `Height - 1` lines. Space runs out: JUST HAPPENED shrinks first, then the NOW list; the header, checklist and NOW line stay. Only when the header, the checklist and the NOW line alone exceed `Height - 1` (a tiny window): the two separators go first, then checklist rows are dropped from the bottom, so the header and the NOW line always show.
  - `Split-ProgressLine -Line <string> -> object[]` of `@{ Text; Color; Background }` (Background optional: none = the frame's `-Background`): text before the first marker is uncoloured; each marker starts a segment that runs to the next marker: `[OK]` Green, `[>>]` Cyan, `[X ]` Red, `[--]` DarkGray, `[..]` uncoloured.
  - `Get-ProgressNowView -> hashtable @{ Title; SubTitle; Lines; Wait }`: from `Get-SetupNow`; calls the provider (`& $Provider $ProviderArgument`) in a `try`; a provider error gives `Lines = @()` and one WARN until the next `Clear-SetupNow`. Never throws.
  - `Show-ProgressScreen -State <hashtable> [-Catalog <object[]> = $script:StepCatalog] [-Now <scriptblock> = { Get-Date }] [-Writer <hashtable> = (New-ConsoleWriter)]`: size from `Writer.GetSize`; advances the spinner one frame per call; `Get-ProgressNowView`; `Get-SetupActivityLines -Count 50`; `Format-ProgressScreen`; `Write-ConsoleFrame -Colorize { param($l) Split-ProgressLine -Line $l }`. Never `Write-Host` or `Clear-Host`.
- `src/Engine/Catalog.ps1`: `Short` values: prepare `Prepare`, bitlocker `BitLocker off`, region `Time zone + keyboard`, desktop-icons `Desktop icons`, bloatware `Remove bloatware`, rename `Rename PC`, winget `winget`, chrome `Chrome`, anydesk `AnyDesk`, 7zip `7-Zip`, office `Microsoft 365`, default-browser `Default browser`, vendor-pass1 `Drivers (pass 1)`, windows-update `Windows Update`, vendor-pass2 `Drivers (pass 2)`, consumer-app `Laptop app`, vendor-cleanup `Remove updater`, finalize `Finish`.

- [ ] **Step 1: Write the failing tests** (Screens.Tests). The fixture: a local catalog with `Short` titles for `prepare, bitlocker, chrome, anydesk, 7zip, vendor-pass1, office, windows-update, office-finish, finalize` (Shorts as above; office-finish `Microsoft 365`), and `New-V2State` = StartedAt `2026-10-20T11:00:00`, RebootCount 2, that plan, statuses prepare Done, bitlocker Skipped ('Not encrypted'), chrome Failed ('MSI exit 1603'), anydesk Done, 7zip Done, vendor-pass1 running since `12:00:00`, office Done with `Data = @{ Background = $true; StartedAt = '2026-10-20T11:59:00' }`, the rest pending. `$now = [datetime]'2026-10-20T12:12:40'`. `$view = @{ SubTitle = 'Dell Command Update'; Lines = @('Log: Installing Intel Chipset'); Wait = @{ StartedAt = [datetime]'2026-10-20T12:00:00'; LimitMinutes = 60 } }`. `$act = @([pscustomobject]@{ Time = [datetime]'2026-10-20T12:31:00'; Text = 'Microsoft 365 started installing in the background' })`.

```powershell
Describe 'Format-ProgressScreen (v2)' {
  It 'draws header, checklist columns, NOW and JUST HAPPENED' {
    $l = Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -Spinner '/' -NowView $view -Activity $act
    $l[0] | Should -Be '  BENTECH WINDOWS SETUP - working, do not turn off   /   Total 01:12:40   Restarts 2'
    $l[1] | Should -Be ('  ' + ('-' * 96))
    $l[2] | Should -Be ('  ' + '[OK] Prepare'.PadRight(32) + '[OK] AnyDesk'.PadRight(32) + '[>>] Microsoft 365 (bg) 13:40')
    $l[3] | Should -Be ('  ' + '[--] BitLocker off'.PadRight(32) + '[OK] 7-Zip'.PadRight(32) + '[..] Windows Update')
    $l[4] | Should -Be ('  ' + '[X ] Chrome'.PadRight(32) + '[>>] Drivers (pass 1)'.PadRight(32) + '[..] Finish')
    $l[6] | Should -Be '  NOW  Drivers (pass 1) - Dell Command Update   /   12:40 (of max 60 min)'
    $l[7] | Should -Be '       Log: Installing Intel Chipset'
    $l[9] | Should -Be '  JUST HAPPENED'
    $l[10] | Should -Be '  12:31  Microsoft 365 started installing in the background'
    ($l -join "`n") | Should -Not -Match 'Microsoft 365 \(finish\)'
  }
  It 'NOW without a wait shows the step time and no limit' {
    (Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView @{ Lines = @() } -Activity @())[6] | Should -Be '  NOW  Drivers (pass 1)   /   12:40'
  }
  It 'NOW shows an override title (the Office restart wait)' {
    $v = @{ Title = 'Waiting for Microsoft 365 to finish before restarting'; Wait = @{ StartedAt = [datetime]'2026-10-20T11:59:00'; LimitMinutes = 60 } }
    (Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView $v)[6] | Should -Be '  NOW  Waiting for Microsoft 365 to finish before restarting   /   13:40 (of max 60 min)'
  }
  It 'falls back to the newest activity line when the step has no detail' {
    (Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView @{ Lines = @() } -Activity $act)[7] | Should -Be '       Microsoft 365 started installing in the background'
  }
  It 'cuts a long NOW list with "... and N more"' {
    $v = @{ Lines = @(1..15 | ForEach-Object { "update $_" }) }
    $l = Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 40 -NowView $v
    $l[7] | Should -Be '       update 1'; $l[15] | Should -Be '       update 9'; $l[16] | Should -Be '       ... and 6 more'
  }
  It 'shrinks JUST HAPPENED first, then the NOW list, and keeps header, checklist and NOW line' {
    $v = @{ Lines = @(1..10 | ForEach-Object { "u$_" }) }
    $l = @(Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 12 -NowView $v -Activity $act)
    $l.Count | Should -Be 11; $l[6] | Should -Match '^  NOW  '; $l[10] | Should -Be '       ... and 7 more'
    $l | Should -Not -Contain '  JUST HAPPENED'
  }
  It 'fits a tiny 40x12 window (Review Focus 3)' {
    $l = @(Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 40 -Height 12 -NowView $view -Activity $act)
    $l.Count | Should -BeLessOrEqual 11; @($l | Where-Object { $_.Length -gt 39 }).Count | Should -Be 0
  }
  It 'is ASCII only with Hebrew everywhere (Review Focus 4)' {
    $v = @{ SubTitle = "tool $Hebrew"; Lines = @("log $Hebrew") }; $a = @([pscustomobject]@{ Time = $now; Text = "done $Hebrew" })
    ((Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView $v -Activity $a) -join "`n") -match '[^\x20-\x7E\n]' | Should -BeFalse
  }
}
Describe 'Get-ChecklistEntry: the Microsoft 365 line' {
  It 'shows the result of office-finish once it has one' { $s = New-V2State; $s.Steps['office-finish'] = @{ Status = 'Failed'; Message = 'Office setup timed out' }; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[X ] Microsoft 365' }
  It 'keeps office''s own failure' { $s = New-V2State; $s.Steps.office = @{ Status = 'Failed' }; $s.Steps['office-finish'] = @{ Status = 'Done' }; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[X ] Microsoft 365' }
  It 'says (bg ended) when the background process has ended' { $s = New-V2State; $s.Steps.office.Data.Finished = $true; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[..] Microsoft 365 (bg ended)' }
  It 'is running while office-finish waits' { $s = New-V2State; $s.Steps['office-finish'] = @{ Status = 'running' }; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[>>] Microsoft 365' }
}
Describe 'Format-Checklist' {
  It 'fills columns top to bottom, two-space indent, no trailing spaces' { Format-Checklist -Entries @('a','b','c','d','e') -Width 20 | Should -Be @('  a   c   e', '  b   d') }
}
Describe 'ConsoleFrame' {
  BeforeEach {
    $script:fw = @{ Calls = New-Object System.Collections.ArrayList; Size = @{ Width = 30; Height = 5; Top = 10 } }
    $script:writer = @{ GetSize = { [pscustomobject]$script:fw.Size }; Clear = { param($b) [void]$script:fw.Calls.Add('clear'); $script:fw.ClearBack = $b }
      MoveTo = { param($row) [void]$script:fw.Calls.Add("row $row") }; Write = { param($t, $c, $b) [void]$script:fw.Calls.Add(@{ T = $t; C = $c; B = $b }) } }
    Reset-ConsoleFrame
    Mock Write-Host { throw 'Write-Host must not be used' }; Mock Clear-Host { throw 'Clear-Host must not be used' }
  }
  It 'ConvertTo-ConsoleFrame pads and cuts to exactly Width x Height' {
    $f = ConvertTo-ConsoleFrame -Lines @('abc', ('x' * 50)) -Width 10 -Height 3
    $f.Count | Should -Be 3; @($f | Where-Object { $_.Length -ne 10 }).Count | Should -Be 0; $f[0] | Should -Be 'abc       '
  }
  It 'clears only when the size changes, writes Height-1 rows of Width-1 characters and parks the cursor' {
    Write-ConsoleFrame -Lines @('a', 'b') -Writer $writer; Write-ConsoleFrame -Lines @('a', 'b') -Writer $writer
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 1
    @($fw.Calls | Where-Object { $_ -is [hashtable] -and $_.T.Length -ne 29 }).Count | Should -Be 0
    @($fw.Calls | Where-Object { $_ -is [hashtable] -and (-not $_.C -or $_.B -ne 'Black') }).Count | Should -Be 0   # spec 9.1: both colours, on Black
    $fw.ClearBack | Should -Be 'Black'
    @($fw.Calls | Where-Object { $_ -eq 'row 14' }).Count | Should -Be 2     # Top + Height - 1, once per frame
    $fw.Calls[$fw.Calls.Count - 1] | Should -Be 'row 14'
    $fw.Size.Width = 40; Write-ConsoleFrame -Lines @('a') -Writer $writer
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 2
  }
  It 'Split-ProgressLine colours each marker up to the next one' {
    $s = @(Split-ProgressLine -Line '  [OK] Prepare   [X ] Chrome')
    $s[0].Text | Should -Be '  '; $s[0].Color | Should -BeNullOrEmpty
    $s[1].Text | Should -Be '[OK] Prepare   '; $s[1].Color | Should -Be 'Green'
    $s[2].Text | Should -Be '[X ] Chrome'; $s[2].Color | Should -Be 'Red'
  }
  It 'Get-ConsoleTargetSize grows to 100x45 within the screen and never shrinks' {
    $r = Get-ConsoleTargetSize -Current @{ Width = 80; Height = 25; BufferWidth = 80; BufferHeight = 9001 } -Largest @{ Width = 160; Height = 50 }
    $r.WindowWidth | Should -Be 100; $r.WindowHeight | Should -Be 45; $r.BufferWidth | Should -Be 100; $r.BufferHeight | Should -Be 9001
    (Get-ConsoleTargetSize -Current @{ Width = 80; Height = 25; BufferWidth = 80; BufferHeight = 25 } -Largest @{ Width = 90; Height = 30 }).WindowHeight | Should -Be 30
    (Get-ConsoleTargetSize -Current @{ Width = 120; Height = 50; BufferWidth = 120; BufferHeight = 9001 } -Largest @{ Width = 160; Height = 60 }).WindowWidth | Should -Be 120
  }
  It 'Show-ProgressScreen draws through the writer and the spinner moves on every call' {
    $script:ProgressSpinnerIndex = 0; $fw.Size = @{ Width = 100; Height = 30; Top = 0 }
    Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer
    Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer
    $heads = @($fw.Calls | Where-Object { $_ -is [hashtable] -and $_.T -like '  BENTECH WINDOWS SETUP*' })
    $heads[0].T | Should -Match '   \|   Total'; $heads[1].T | Should -Match '   /   Total'
  }
  It 'a provider that throws still gives a screen, with one WARN' {
    $script:warns = 0; Mock Write-SetupLog { if ($Level -eq 'WARN') { $script:warns++ } }
    Clear-SetupNow; Set-SetupNow -Provider { throw 'bad json' }; $fw.Size = @{ Width = 100; Height = 30; Top = 0 }
    { Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer } | Should -Not -Throw
    { Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer } | Should -Not -Throw
    $warns | Should -Be 1; Clear-SetupNow
  }
}
```

Catalog.Tests: `It 'every step has a Short title of at most 20 characters' { foreach ($s in $script:StepCatalog) { $s.Short | Should -Not -BeNullOrEmpty; $s.Short.Length | Should -BeLessOrEqual 20 } }`.

- [ ] **Step 2: Run** `tests\Screens.Tests.ps1` and `tests\Catalog.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** per the Interfaces; add `UI\ConsoleFrame.ps1` to `$BundleOrder`. Re-save with BOM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0` (Main still calls `Show-ProgressScreen -State -Catalog`, which still binds).
- [ ] **Step 5: Commit:** `feat: v2 progress screen drawn through a console writer`.

---

### Task 8: Start screen v2 (Q1)

**Files:**
- Modify: `src/UI/StartScreen.ps1`, `src/Engine/Catalog.ps1` (`Test-HasDriverTool`, used by `Get-StepPlan`)
- Test: `tests/Screens.Tests.ps1` (`Update-StartChoices`, `Format-StartScreen`, `Show-StartScreen` Describes), `tests/Catalog.Tests.ps1`

**Interfaces:**
- Consumes: `New-ConsoleWriter`, `Write-ConsoleFrame` (Task 7).
- Produces:
  - `$script:StartCountdownSeconds = 30`; `$script:StartHelpColumn = 53`; frame `' ' + ('=' * 77)`; countdown bar 20 wide: `'#' * ceil(20 * SecondsLeft / 30)` then `.`.
  - `Test-HasDriverTool -Machine <hashtable> -> bool` (Catalog.ps1): Brand in `$script:BusinessUpdaterBrands` and not a VM (Brand `VM` or `IsVM`). `Get-StepPlan` uses it for `$hasBusinessTool` (behaviour unchanged).
  - `Update-StartChoices`: any non-empty key other than `Enter`/`Escape` sets `ResetCountdown = $true` (unknown keys too; Choices unchanged for them). Empty or `$null`: nothing.
  - `Format-StartScreen -Machine -Choices -SecondsLeft -Version -OnAC -IsFresh -Previous [-HasDriverTool <bool> = $true] [-MaxAgeDays <int> = 14] -> string[]`, lines in order:
    - frame; `'   BENTECH WINDOWS SETUP' + <v-version>.PadLeft(54)`; frame
    - `'   {Manufacturer} {FriendlyModel}    SN: {Serial}    {ON CHARGER|ON BATTERY}'`
    - `'   New PC name: {NewName}'`; `''`
    - `'   WHAT WILL HAPPEN'.PadRight(53) + 'TO CHANGE IT, PRESS'`
    - `('   Type     ' + type).PadRight(53) + 'L = laptop   D = desktop'`; type: `LAPTOP (driver tool + laptop app)`, `DESKTOP (no laptop app)`, or without a driver tool `LAPTOP (no driver tool for this brand)` / `DESKTOP (no driver tool for this brand)`
    - `'   Chrome + AnyDesk   always'`
    - `('   7-Zip    ' + YES|NO).PadRight(53) + 'Z = yes / no'`
    - `('   Office   ' + office).PadRight(53) + 'O = off / business / home'`; office: `OFF`, `BUSINESS (Hebrew + English)`, `HOME (Hebrew + English)`
    - `''`; the v1 battery line and `Previous run:` line when they apply
    - fresh: `'   Starts by itself in {SecondsLeft} s   {bar}'` and `'   ENTER = start now           ESC = cancel, change nothing'`
    - not fresh: `'   This PC already has user files or is older than {MaxAgeDays} days -'`, `'   press ENTER to run anyway'`, `'   ESC = cancel, change nothing'` (two lines so nothing is cut in an 80-column console)
    - frame
  - `Get-StartScreenSegments -Line <string> -> object[]` (`@{ Text; Color }`): on the `Type`, `7-Zip` and `Office` lines the value word (from column 12 to the next space) is Green, or DarkGray when it is `NO` or `OFF`; the battery line and the two not-fresh text lines are one Yellow segment; everything else one uncoloured segment.
  - `Write-StartScreenLines -Lines <string[]> [-Writer <hashtable> = (New-ConsoleWriter)]`: `Write-ConsoleFrame -Colorize { param($l) Get-StartScreenSegments -Line $l }`. No `Clear-Host`, no `Write-Host`.
  - `Show-StartScreen`: same parameters and seams; passes `-HasDriverTool (Test-HasDriverTool -Machine $Machine)` and `-MaxAgeDays [int]$Config.freshInstall.maxInstallAgeDays`; counts down from 30; any key resets it to 30.

- [ ] **Step 1: Update and add the tests.** In the existing `Show-StartScreen` tests change every countdown count from 10 to 30 (`Get-ElapsedSeconds | Should -Be 30`, `$screens.Count | Should -Be 30`, `'Starts by itself in 30 s'` first and `'in 1 s'` last; the toggle test: 4 s + 30 s), the text `'Starting in Ns'` to `'Starts by itself in N s'`, and the two production-writer tests to a fake writer (`Mock New-ConsoleWriter { $script:writer }`, as in Task 7). Replace the v1 `Format-StartScreen` string tests with:

```powershell
Describe 'Format-StartScreen (v2)' {
  BeforeAll { function F([hashtable]$c, [int]$s = 25, [bool]$ac = $true, [bool]$fresh = $true, [bool]$tool = $true, $prev = $null) {
    Format-StartScreen -Machine $m -Choices $c -SecondsLeft $s -Version '2026.10.20.1' -OnAC $ac -IsFresh $fresh -Previous $prev -HasDriverTool $tool -MaxAgeDays 14 } }
  It 'shows the v2 layout for a fresh laptop on AC' {
    $l = F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'BUSINESS' }
    $l[0] | Should -Be (' ' + ('=' * 77)); $l[1] | Should -Be ('   BENTECH WINDOWS SETUP' + 'v2026.10.20.1'.PadLeft(54))
    $l | Should -Contain '   Dell Inc. Latitude 5440    SN: 7HX2K93    ON CHARGER'
    $l | Should -Contain '   New PC name: DELL-7HX2K93'
    $l | Should -Contain ('   WHAT WILL HAPPEN'.PadRight(53) + 'TO CHANGE IT, PRESS')
    $l | Should -Contain ('   Type     LAPTOP (driver tool + laptop app)'.PadRight(53) + 'L = laptop   D = desktop')
    $l | Should -Contain '   Chrome + AnyDesk   always'
    $l | Should -Contain ('   7-Zip    YES'.PadRight(53) + 'Z = yes / no')
    $l | Should -Contain ('   Office   BUSINESS (Hebrew + English)'.PadRight(53) + 'O = off / business / home')
    $l | Should -Contain ('   Starts by itself in 25 s   ' + ('#' * 17) + ('.' * 3))
    $l | Should -Contain '   ENTER = start now           ESC = cancel, change nothing'
    @($l | Where-Object { $_.Length -gt 79 }).Count | Should -Be 0
  }
  It 'says what the mode means, also for a brand without a driver tool' {
    (F @{ Mode = 'DESKTOP'; SevenZip = $false; Office = 'OFF' }) | Should -Contain ('   Type     DESKTOP (no laptop app)'.PadRight(53) + 'L = laptop   D = desktop')
    (F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'HOME' } -tool $false) | Should -Contain ('   Type     LAPTOP (no driver tool for this brand)'.PadRight(53) + 'L = laptop   D = desktop')
    (F @{ Mode = 'DESKTOP'; SevenZip = $false; Office = 'OFF' }) | Should -Contain ('   Office   OFF'.PadRight(53) + 'O = off / business / home')
  }
  It 'a full and an empty countdown bar' {
    (F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -s 30) | Should -Contain ('   Starts by itself in 30 s   ' + ('#' * 20))
    (F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -s 1) | Should -Contain ('   Starts by itself in 1 s   #' + ('.' * 19))
  }
  It 'not fresh: no countdown, the two-line message and ESC' {
    $l = F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -fresh $false
    $l | Should -Contain '   This PC already has user files or is older than 14 days -'
    $l | Should -Contain '   press ENTER to run anyway'; $l | Should -Contain '   ESC = cancel, change nothing'
    ($l -join "`n") | Should -Not -Match 'Starts by itself'
  }
  It 'keeps the battery and previous-run lines and stays ASCII' {
    $odd = $m.Clone(); $odd.FriendlyModel = 'Latitude ' + [char]0x05D1
    $l = Format-StartScreen -Machine $odd -Choices @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -SecondsLeft 9 -Version 'v1' -OnAC $false -IsFresh $true -Previous @{ StartedAt = '2026-10-17T14:05:09'; Color = 'RED' }
    $l | Should -Contain '   ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery.'
    $l | Should -Contain '   Previous run: 17/10/2026 14:05 - RED'
    ($l -join "`n") -match '[^\x20-\x7E\n]' | Should -BeFalse
  }
}
Describe 'start screen colours' {
  It 'the chosen value is green when on, dark grey when off; warnings are yellow' {
    $on = @(Get-StartScreenSegments -Line ('   7-Zip    YES'.PadRight(53) + 'Z = yes / no')); $on[1].Text | Should -Be 'YES'; $on[1].Color | Should -Be 'Green'
    $off = @(Get-StartScreenSegments -Line ('   Office   OFF'.PadRight(53) + 'O = off / business / home')); $off[1].Text | Should -Be 'OFF'; $off[1].Color | Should -Be 'DarkGray'
    (Get-StartScreenSegments -Line '   press ENTER to run anyway')[0].Color | Should -Be 'Yellow'
  }
}
```

Update-StartChoices: replace `'Enter starts, Esc cancels, X does nothing'` by `It 'Enter starts, Esc cancels, and any other key resets the countdown (Q1)' { ...; $r = Update-StartChoices -Choices $c -Key 'X'; $r.Action | Should -Be 'None'; $r.ResetCountdown | Should -BeTrue; $r.Choices.Mode | Should -Be 'LAPTOP' }`. Show-StartScreen: add `It 'an unknown key restarts the countdown at 30' { $script:sent = $false; $r = Invoke-StartScreen -KeyAt { param($s) if (-not $script:sent -and $s -ge 4) { $script:sent = $true; 'X' } }; Get-ElapsedSeconds | Should -BeGreaterOrEqual 34; Get-ElapsedSeconds | Should -BeLessThan 34.5 }`. Catalog.Tests: `It 'Test-HasDriverTool: Dell yes, ASUS no, a Dell VM no' { Test-HasDriverTool -Machine @{ Brand = 'DELL' } | Should -BeTrue; Test-HasDriverTool -Machine @{ Brand = 'ASUS' } | Should -BeFalse; Test-HasDriverTool -Machine @{ Brand = 'DELL'; IsVM = $true } | Should -BeFalse }`.

- [ ] **Step 2: Run** `tests\Screens.Tests.ps1`, `tests\Catalog.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: clearer 30-second start screen`.

---

### Task 9: Runner, restart and entry wiring

**Files:**
- Modify: `src/Engine/Runner.ps1`, `src/Engine/Reboot.ps1`, `src/Entry/Main.ps1`
- Test: `tests/Runner.Tests.ps1`, `tests/Entry.Tests.ps1` (dot-source `UI\ConsoleFrame`; BeforeEach adds `Mock Resize-SetupConsole { $true }`, `Mock Initialize-SetupActivity { }`, `Mock Reset-SetupActivityLog { }`, `Mock Add-SetupActivity { }`)

**Interfaces:**
- Consumes: Task 5 (`Add-SetupActivity`, `Clear-SetupNow`, `Register-SetupTick`, `Unregister-SetupTick`, `Invoke-SetupTick`, `Initialize-SetupActivity`, `Reset-SetupActivityLog`), Task 7 (`Show-ProgressScreen`, `Reset-ConsoleFrame`, `Resize-SetupConsole`).
- Produces:
  - `Invoke-SetupRun`: builds `$titles` (id -> catalog `Title`, else the id) and passes it to `Save-StepOutcome -Titles`. Before each call: `Clear-SetupNow`; when the step's `StartedAt` is still `$null` (first call ever), `Add-SetupActivity "<Title> started"`. After each call: `Clear-SetupNow`.
  - `Save-StepOutcome ... [hashtable]$Titles`: after recording Done -> `"<Title> done - <Message>"` (`"<Title> done"` without a message), Skipped -> `"<Title> skipped - <Message>"`, Failed -> `"<Title> FAILED - <Message>"` (also the attempt-cap, interruption, not-in-catalog and refused-reboot failures). `pending` (Continue) writes nothing: a step writes its own round summaries.
  - `Invoke-ControlledReboot`: right after the incremented `RebootCount` is saved: `Add-SetupActivity "Restarting (restart <RebootCount>)"`.
  - `Start-BenTechSetup` (not on `-WuRound`): `Initialize-SetupActivity -LogDirectory $logDir` right after `Initialize-SetupLog`; `$null = Resize-SetupConsole` right after `Disable-ConsoleQuickEdit`; `Unregister-SetupTick` first in the `catch` (before the crash screen) and in the `finally`.
  - `Invoke-SetupMainFlow`: new run, after the start screen returned choices: `Reset-SetupActivityLog -LogDirectory $logDir -PreviousRunId <previous RunId or $null>` (Escape archives nothing). Resume: `Add-SetupActivity ('Back after restart {0}' -f [int]$runState['RebootCount'])`. Before `Invoke-SetupRun`: `Reset-ConsoleFrame`; `Register-SetupTick -Context $ctx -Handler { param($tickContext) Show-ProgressScreen -State $tickContext.State -Catalog $script:StepCatalog }`; `-OnProgress { param($progressContext) Invoke-SetupTick -Force }`.
  - `Complete-SetupRun`: `Unregister-SetupTick` right before `Show-FinalScreen`.

- [ ] **Step 1: Write the failing tests.**

Runner.Tests (BeforeEach of a new Describe: `$script:act = New-Object System.Collections.ArrayList; Mock Add-SetupActivity { [void]$script:act.Add($Text) }`):
```powershell
It 'writes "<Title> started" once and the final result once, nothing for Continue' {
  $script:n = 0; function Step-A { param($Context) $script:n++; if ($script:n -lt 3) { New-StepResult -Status Continue -Message 'round' } else { New-StepResult -Status Done -Message 'all good' } }
  function Step-B { param($Context) New-StepResult -Status Skipped -Message 'n/a' }
  $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction { } -CountdownSeconds 0 | Out-Null
  @($act) | Should -Be @('A started', 'A done - all good', 'B started', 'B skipped - n/a')
}
It 'writes FAILED with the reason, also for the attempt cap' {
  function Step-A { param($Context) throw 'boom' }; function Step-B { param($Context) New-StepResult -Status Done }
  $c = New-Ctx @('a','b'); $c.State.Steps.b.Status = 'running'; $c.State.Steps.b.Attempts = 3; $c.State.Steps.b.StartedAt = '2026-10-20T10:00:00'
  Invoke-SetupRun -Context $c -Catalog $cat -RestartAction { } -CountdownSeconds 0 | Out-Null
  $act | Should -Contain 'A FAILED - boom'; $act | Should -Contain 'B FAILED - attempt cap reached'
}
It 'no started line when the step already ran before (resume)' {
  function Step-A { param($Context) New-StepResult -Status Done }; function Step-B { param($Context) New-StepResult -Status Done }
  $c = New-Ctx @('a','b'); $c.State.Steps.a.StartedAt = '2026-10-20T10:00:00'
  Invoke-SetupRun -Context $c -Catalog $cat -RestartAction { } -CountdownSeconds 0 | Out-Null
  $act | Should -Not -Contain 'A started'; $act | Should -Contain 'A done'
}
It 'clears the NOW state before and after every step' {
  function Step-A { param($Context) $script:seenA = (Get-SetupNow).SubTitle; Set-SetupNow -SubTitle 'tool A'; New-StepResult -Status Done }
  function Step-B { param($Context) $script:seenB = (Get-SetupNow).SubTitle; New-StepResult -Status Done }
  Set-SetupNow -SubTitle 'left over'; $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction { } -CountdownSeconds 0 | Out-Null
  $seenA | Should -BeNullOrEmpty; $seenB | Should -BeNullOrEmpty; (Get-SetupNow).SubTitle | Should -BeNullOrEmpty
}
It 'Invoke-ControlledReboot writes "Restarting (restart N)" after the count is saved' {
  $c = New-Ctx @('a'); $c.State.RebootCount = 1
  Mock Add-SetupActivity { [void]$script:act.Add(@($Text, (Read-RunState -Root $c.Root).RebootCount)) }
  Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { } | Should -BeTrue
  $act[0][0] | Should -Be 'Restarting (restart 2)'; $act[0][1] | Should -Be 2
}
```

Entry.Tests:
```powershell
It 'initializes the activity feed in Root\Logs and resizes the console once' {
  Invoke-Entry | Out-Null
  Should -Invoke Initialize-SetupActivity -Times 1 -Exactly -ParameterFilter { $LogDirectory -eq (Join-Path $TestDrive 'Logs') }
  Should -Invoke Resize-SetupConsole -Times 1 -Exactly
}
It 'a new run archives the previous activity under its RunId, after the start screen' {
  $script:order = New-Object System.Collections.ArrayList
  Mock Read-RunState { New-FakeState -RunId '20261019-090000' -EndedAt '2026-10-19T11:00:00' }
  Mock Show-StartScreen { [void]$script:order.Add('start'); $script:choices }
  Mock Reset-SetupActivityLog { [void]$script:order.Add('archive') }
  Invoke-Entry | Out-Null
  @($order) | Should -Be @('start', 'archive')
  Should -Invoke Reset-SetupActivityLog -Times 1 -Exactly -ParameterFilter { $PreviousRunId -eq '20261019-090000' }
}
It 'Escape archives nothing' { Mock Show-StartScreen { $null }; Invoke-Entry | Out-Null; Should -Invoke Reset-SetupActivityLog -Times 0 -Exactly }
It 'a resume writes "Back after restart N"' {
  Mock Read-RunState { $s = New-FakeState; $s.RebootCount = 3; $s }
  Invoke-Entry -Resume $true | Out-Null
  Should -Invoke Add-SetupActivity -Times 1 -Exactly -ParameterFilter { $Text -eq 'Back after restart 3' }
}
It 'registers the tick with the context before the run and unregisters it before the final screen' {
  $script:order = New-Object System.Collections.ArrayList
  Mock Register-SetupTick { [void]$script:order.Add('register'); $script:tickCtx = $Context }
  Mock Invoke-SetupRun { [void]$script:order.Add('run'); 'Completed' }
  Mock Unregister-SetupTick { [void]$script:order.Add('unregister') }
  Mock Show-FinalScreen { [void]$script:order.Add('final') }
  Invoke-Entry | Out-Null
  $order.IndexOf('register') | Should -BeLessThan $order.IndexOf('run')
  $order.IndexOf('unregister') | Should -BeLessThan $order.IndexOf('final')
  $tickCtx.State.RunId | Should -Be 'new-run'
}
It 'a crash unregisters the tick before the crash screen' {
  $script:order = New-Object System.Collections.ArrayList
  Mock Invoke-SetupRun { throw 'boom' }; Mock Unregister-SetupTick { [void]$script:order.Add('unregister') }
  Invoke-Entry -CrashScreen { param($t) [void]$script:order.Add('crash') } | Out-Null
  $order[0] | Should -Be 'unregister'; $order | Should -Contain 'crash'
}
It '-WuRound: no tick, no resize, no activity feed' {
  Mock Register-SetupTick { }
  Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null
  Should -Invoke Register-SetupTick -Times 0 -Exactly; Should -Invoke Resize-SetupConsole -Times 0 -Exactly; Should -Invoke Initialize-SetupActivity -Times 0 -Exactly
}
```
The existing `'draws the progress screen with the run state from the progress callback'` must stay green unchanged (the real `Register-SetupTick` + `Invoke-SetupTick -Force` reach the mocked `Show-ProgressScreen`).

- [ ] **Step 2: Run** `tests\Runner.Tests.ps1`, `tests\Entry.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** per the Interfaces. Re-save with BOM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: wire the activity feed and the tick into the runner and entry point`.

---

### Task 10: Step facts and the driver-pass NOW line

**Files:**
- Modify: `src/Steps/Apps.ps1`, `src/Steps/Bloatware.ps1`, `src/Steps/Region.ps1`, `src/Steps/Vendor.ps1`
- Test: `tests/Apps.Tests.ps1` (dot-source `Report\Report`; `Initialize-AppMocks` adds `Mock Get-InstalledAppVersions { @{} }` and `Mock Add-SetupActivity { [void]$script:activity.Add(@{ Text = $Text; LogText = $LogText }) }`), `tests/SystemSteps.Tests.ps1`, `tests/Vendor.Tests.ps1`

**Interfaces:**
- Consumes: `Add-SetupActivity`, `Set-SetupNow`, `Read-FileTail` (Task 5); `Get-InstalledAppVersions` (Report.ps1).
- Produces:
  - `Get-AppVersionText -Name <string> -> string` (Apps.ps1, private): `(Get-InstalledAppVersions)[$Name]`, `''` when missing or on any error.
  - Chrome, after a fresh install is Done: `"Google Chrome <version> installed"` (no version: `'Google Chrome installed'`). Already installed: no line.
  - AnyDesk, when an ID was read: `Add-SetupActivity -Text "AnyDesk <version> - ID <id>" -LogText "AnyDesk <version> - ID recorded"`.
  - 7-Zip, when winget's result is Done: `"7-Zip <version> installed"`.
  - Bloatware: one `"Removed <name>"` per package whose removal succeeded.
  - Region: no notes -> `'Time zone set to Israel; Hebrew and English keyboards ready'`.
  - Vendor: `Get-VendorLogSource -Context <hashtable> -Kind <string> -Pass <int> -> @{ Path = <string|$null>; Folder = <string|$null> }` (pure): dcu -> `Path = <Logs>\dcu-pass<N>.log`; lsu -> `Folder = %ProgramData%\Lenovo\SystemUpdate\logs`; hpia -> `Folder = <Logs>\HPIA-pass<N>`. `Get-LastLogLine -Text <string> -> string` (pure): the last non-blank line through `ConvertTo-ScreenText`. `Get-VendorNowLines -Source <hashtable> -> string[]` (display only, never throws): the file, or the newest `*.log` in the folder, read with `Read-FileTail`; `@('Log: <last line>')`, else `@()`. `Invoke-VendorPass`, right before the tool runs: `Set-SetupNow -SubTitle <tool name> -Provider { param($source) Get-VendorNowLines -Source $source } -ProviderArgument (Get-VendorLogSource ...)`. BitLocker suspended by the gate: `'BitLocker suspended for one restart (BIOS update)'`; on battery: `'On battery: BIOS and firmware left out of this driver pass'`.

- [ ] **Step 1: Write the failing tests.**

```powershell
# Apps.Tests
It 'Chrome writes its installed version to the activity feed' {
  Mock Get-InstalledAppVersions { @{ 'Google Chrome' = '141.0.7390.55' } }
  (Invoke-StepChrome -Context $script:ctx -RetrySeconds 0).Status | Should -Be 'Done'
  @($script:activity.Text) | Should -Contain 'Google Chrome 141.0.7390.55 installed'
}
It 'an already installed Chrome writes no version line' { <add chrome.exe's path to $script:existing, as the Test-ChromeInstalled tests do>; $null = Invoke-StepChrome -Context $script:ctx; $script:activity.Count | Should -Be 0 }
It 'AnyDesk: the ID goes to the feed, never to setup.log' {
  Mock Get-InstalledAppVersions { @{ 'AnyDesk' = '9.0.4' } }
  $null = Invoke-StepAnyDesk -Context $script:ctx -PollSeconds 0
  $script:activity[0].Text | Should -Be 'AnyDesk 9.0.4 - ID 123456789'; $script:activity[0].LogText | Should -Be 'AnyDesk 9.0.4 - ID recorded'
}
It 'a version lookup that throws still leaves the step Done' { Mock Get-InstalledAppVersions { throw 'registry gone' }; (Invoke-StepChrome -Context $script:ctx -RetrySeconds 0).Status | Should -Be 'Done' }
It '7-Zip writes its version when winget installed it' { Mock Get-InstalledAppVersions { @{ '7-Zip' = '24.08' } }; $null = Invoke-StepSevenZip -Context $script:ctx; @($script:activity.Text) | Should -Contain '7-Zip 24.08 installed' }
```
(Use the existing Apps fixtures: `Initialize-AppMocks` (add `$script:activity = New-Object System.Collections.ArrayList` there), the "Chrome not installed, MSI exit 0" setup and the AnyDesk `$script:getIdOutput` that yields `123456789`.)

```powershell
# SystemSteps.Tests
It 'bloatware lists each removed app, not the failed ones' { <two selected, one removal fails>; @($script:activity) | Should -Be @('Removed king.com.CandyCrushSaga') }
It 'region writes one line when both settings worked' { $null = Invoke-StepRegion -Context $ctx; @($script:activity) | Should -Be @('Time zone set to Israel; Hebrew and English keyboards ready') }
# Vendor.Tests
It 'Get-VendorLogSource: Dell file, Lenovo and HP folders' {
  (Get-VendorLogSource -Context $ctx -Kind dcu -Pass 2).Path | Should -Be (Join-Path $ctx.LogDir 'dcu-pass2.log')
  (Get-VendorLogSource -Context $ctx -Kind lsu -Pass 1).Folder | Should -Be (Join-Path $env:ProgramData 'Lenovo\SystemUpdate\logs')
  (Get-VendorLogSource -Context $ctx -Kind hpia -Pass 1).Folder | Should -Be (Join-Path $ctx.LogDir 'HPIA-pass1')
}
It 'shows the last non-blank log line; Hebrew in a log line becomes ? (Review Focus 4)' {
  $p = "$TestDrive\dcu.log"; [IO.File]::WriteAllText($p, "start`r`nInstalling $Hebrew driver`r`n`r`n")
  Get-VendorNowLines -Source @{ Path = $p } | Should -Be @('Log: Installing ????? driver')
}
It 'reads a log the tool holds open and the newest *.log of a folder' {
  $d = "$TestDrive\lsu"; [void][IO.Directory]::CreateDirectory($d)
  [IO.File]::WriteAllText("$d\old.log", 'old'); (Get-Item "$d\old.log").LastWriteTime = (Get-Date).AddHours(-1)
  $w = [IO.File]::Open("$d\new.log", 'Create', 'Write', 'ReadWrite')
  try { $b = [Text.Encoding]::UTF8.GetBytes("Downloading package 3`r`n"); $w.Write($b, 0, $b.Length); $w.Flush(); Get-VendorNowLines -Source @{ Folder = $d } | Should -Be @('Log: Downloading package 3') } finally { $w.Dispose() }
}
It 'no log yet is no line' { Get-VendorNowLines -Source @{ Path = "$TestDrive\none.log" } | Should -BeNullOrEmpty }
It 'Invoke-VendorPass shows the tool name and the log provider in NOW' {
  Mock Invoke-DellUpdate { $script:now = Get-SetupNow; New-VendorOutcome -Outcome Done }
  $null = Invoke-VendorPass -Context $ctx -Pass 1
  $now.SubTitle | Should -Be 'Dell Command Update'; $now.ProviderArgument.Path | Should -Match 'dcu-pass1\.log$'
}
It 'a BitLocker suspension writes an activity line' { <gate: Wait-BitLockerDecrypted $false, Suspend-BitLockerOnce $true>; @($script:activity) | Should -Contain 'BitLocker suspended for one restart (BIOS update)' }
```

- [ ] **Step 2: Run** the three files. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM. Never run a vendor tool.
- [ ] **Step 4: Run** the three files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: step facts in the activity feed and the driver tool's log line in NOW`.

---

### Task 11: Windows Update child: one update at a time, English titles, progress file

**Files:**
- Modify: `src/Steps/WindowsUpdate.ps1` (child side), `src/Entry/Main.ps1` (`Invoke-SetupWuRoundProcess`), `config/config.json`
- Test: `tests/WindowsUpdate.Tests.ps1`, `tests/Entry.Tests.ps1`, `tests/Config.Tests.ps1`

**Interfaces:**
- Consumes: v1 `Invoke-WuDownload`, `Invoke-WuInstall`, `Format-WuHResult`, `New-WuInstalledEntry`, `$script:WuBusyErrorCodes`, `$script:WuRebootPendingErrorCode`; Task 3's `-OnAC`, `Deferred` and `FirmwareDeferred` (deferred firmware is never attempted and never listed in the progress file: the loop and the progress list cover `Install` only).
- Produces:
  - `config.json`: top-level `"windowsUpdate": { "installMode": "OneAtATime" }` (values `OneAtATime` | `Batch`). Not a required key of `Read-SetupConfig`.
  - `Get-WuInstallMode -Config <object> -> 'OneAtATime'|'Batch'`: missing section or value -> `OneAtATime`; an unknown value -> `OneAtATime` and a WARN.
  - `New-WuSession`: after `ClientApplicationID`, `try { $session.UserLocale = 1033 } catch { WARN 'Windows Update session refused the en-US locale; titles stay localized' }`.
  - `ConvertTo-WuUpdateInfo` adds `SizeBytes` (`[double]$Update.MaxDownloadSize`; unreadable or missing -> 0). `New-WuInstalledEntry` adds `Kb` (`'KB' + first KB` or `''`).
  - `Get-WuProgressPath -ResultPath <string> -> string`: `...\wu-round2.json` -> `...\wu-round2.progress.json`.
  - `Update-WuProgress -Path <string> -Progress <IDictionary> [-Phase <string>] [-Current <int>] [-Index <int> -Status <string>]`: updates the ordered progress (shape in Shared shapes; `SizeMB = [math]::Round(SizeBytes / 1MB, 1)`, `Kb` = `'KB' + first KB` or `''`), sets `UpdatedAt`, writes `<Path>.tmp` (UTF-8 without BOM, `ConvertTo-Json -Depth 4`) then `[IO.File]::Replace` (or `Move` when new). Never throws; at most one WARN per round.
  - `Invoke-WuInstallEach -Session <object> -ById <hashtable> -Infos <object[]> -Installed <List[object]> -Failed <List[object]> -Progress <IDictionary> -ProgressPath <string> -> @{ RebootRequired = <bool>; ErrorCode = <string|$null> }`. For each info in search order (`Current` = its 1-based index):
    1. Status `downloading`; not `IsDownloaded` -> `Invoke-WuDownload -Updates @(<one>)`; its code not 2/3 -> `Failed` entry `@{ Id; Title; ResultCode = <download code> }`, status `failed`, next update.
    2. Status `installing`; `Invoke-WuInstall -Updates @(<one>)`; code 2/3 -> `Installed` (`New-WuInstalledEntry`), status `installed`; else `Failed` with the code, status `failed`. `RebootRequired` is OR-ed.
    3. **Stop rule:** when this update's download or install HResult (`Format-WuHResult`) is in `$script:WuBusyErrorCodes` or equals `$script:WuRebootPendingErrorCode`, the loop stops; the rest get status `skipped` and appear in neither list (not attempted).
    4. **ErrorCode:** the first non-zero install HResult; when there is none, the round-ending download HResult that stopped the loop; when no install ran at all, the first non-zero download HResult (v1's rule); otherwise `$null`. Any other non-zero HResult does not stop the loop.
    5. Exceptions propagate: `Invoke-WuRound`'s `catch` keeps what is already listed (v1 behaviour).
  - `Invoke-WuRound` gains `[ValidateSet('OneAtATime', 'Batch')][string]$InstallMode = 'OneAtATime'`. Progress: Phase `searching` at the start; after the selection `Total` and `Updates` (the Install set, all `pending`); `Batch`: v1 download/install code unchanged, with Phase `downloading` / `installing` and the final statuses from the codes; `OneAtATime`: `Invoke-WuInstallEach` replaces v1's download + install block (hide, EULA and SearchOnly paths unchanged); Phase `done` in a `finally`, also after an exception. The result JSON gains `Found = $infos.Count`.
  - `Invoke-SetupWuRoundProcess` passes `-InstallMode (Get-WuInstallMode -Config $config)`.

- [ ] **Step 1: Write the failing tests.** Existing tests: change only the helper `Invoke-TestRound` (add `[string]$InstallMode = 'Batch'` next to Task 3's `-OnAC`, passed through), so every v1 child test keeps pinning v1 batch behaviour. New tests go in a `Context 'one at a time'` **nested inside** `Context 'Invoke-WuRound (child round, COM mocked)'` (it inherits every COM mock); its `BeforeEach` re-mocks `Invoke-WuDownload` / `Invoke-WuInstall` with per-id maps `$script:installHResultFor`, `$script:downloadHResultFor`, `$script:installRebootFor`, `$script:installThrowFor` (defaults: 0 / 0 / `$false` / none).

```powershell
Context 'one at a time' {
  It 'downloads and installs each update on its own, in search order' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 's1')); $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
    $script:downloadCalls.Count | Should -Be 2; $script:downloadCalls[0] | Should -Be @('s1'); $script:downloadCalls[1] | Should -Be @('d1')
    $script:installCalls.Count | Should -Be 2; $script:installCalls[0] | Should -Be @('s1'); $script:installCalls[1] | Should -Be @('d1')
    @($r.Installed.Id) | Should -Be @('s1', 'd1'); $r.Found | Should -Be 2; $r.Installed[0].Kb | Should -Be 'KB5000001'
  }
  It 'maps per-update codes the v1 way: 2 and 3 installed, 4 and 5 failed' {
    $script:searchResults[$script:SoftwareCriteria] = @('a','b','c','d' | ForEach-Object { New-FakeUpdate -Id $_ }); $script:installCodes = @{ a = 2; b = 3; c = 4; d = 5 }
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
    @($r.Installed.Id) | Should -Be @('a', 'b'); @($r.Failed.Id) | Should -Be @('c', 'd'); @($r.Failed.ResultCode) | Should -Be @(4, 5)
  }
  It 'a failed download is Failed with its code, is not installed, and the next update still runs' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'x'), (New-FakeUpdate -Id 'y')); $script:downloadCodes = @{ x = 4 }
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
    $script:installCalls.Count | Should -Be 1; $script:installCalls[0] | Should -Be @('y'); @($r.Failed.ResultCode) | Should -Be @(4)
  }
  It 'skips the download of an update that is already downloaded' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'dl' -Downloaded $true))
    $null = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime; $script:downloadCalls.Count | Should -Be 0; $script:installCalls.Count | Should -Be 1
  }
  It 'ORs RebootRequired over the updates' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installRebootFor = @{ a = $true }
    (Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime).RebootRequired | Should -BeTrue
  }
  It 'ErrorCode is the first non-zero install HResult; a code that does not end the round lets the loop go on' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installHResultFor = @{ a = 0x80070643; b = 0x80070005 }
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
    $script:installCalls.Count | Should -Be 2; $r.ErrorCode | Should -Be '0x80070643'; $r.Error | Should -BeNullOrEmpty
  }
  It 'stops at a round-ending install code (<_>): the rest are not attempted' -ForEach @(0x80240016, 0x8024A000, 0x80242014) {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installHResultFor = @{ a = $_ }
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
    $script:installCalls.Count | Should -Be 1; $r.ErrorCode | Should -Be (Format-WuHResult -HResult $_)
    @($r.Installed.Id) + @($r.Failed.Id) | Should -Not -Contain 'b'
    $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
    $p.Updates[1].Status | Should -Be 'skipped'
  }
  It 'a round-ending download code stops the loop and is ErrorCode when no install ran after it' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:downloadHResultFor = @{ b = 0x80240016 }; $script:downloadCodes = @{ b = 4 }
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
    $script:installCalls.Count | Should -Be 1; $r.ErrorCode | Should -Be '0x80240016'
  }
  It 'keeps what was done when the second install throws; Error and ErrorCode are set' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installThrowFor = @{ b = (New-Object Runtime.InteropServices.COMException('busy', 0x80240016)) }
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
    @($r.Installed.Id) | Should -Be @('a'); $r.Error | Should -Be 'busy'; $r.ErrorCode | Should -Be '0x80240016'
  }
  It 'writes the progress file: total, statuses, KB, size and phase done' {
    $u = New-FakeUpdate -Id 'a'; $u | Add-Member NoteProperty MaxDownloadSize ([decimal]52428800)
    $script:searchResults[$script:SoftwareCriteria] = @($u, (New-FakeUpdate -Id 'b')); $script:installCodes = @{ b = 4 }
    $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 2) -InstallMode OneAtATime
    $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
    $p.Round | Should -Be 2; $p.Mode | Should -Be 'OneAtATime'; $p.Phase | Should -Be 'done'; $p.Total | Should -Be 2
    @($p.Updates.Status) | Should -Be @('installed', 'failed'); $p.Updates[0].Kb | Should -Be 'KB5000001'; $p.Updates[0].SizeMB | Should -Be 50
  }
  It 'a progress file that cannot be written never breaks the round' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
    Mock Get-WuProgressPath { Join-Path $TestDrive 'no\such\folder\p.json' }
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
    $r.Error | Should -BeNullOrEmpty; @($r.Installed.Id) | Should -Be @('a')
  }
}
It 'batch mode writes the phases and final statuses too' {
  $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installCodes = @{ b = 4 }
  $null = Invoke-TestRound -StatePath (New-WuStateFile)
  $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
  $p.Mode | Should -Be 'Batch'; $p.Phase | Should -Be 'done'; @($p.Updates.Status) | Should -Be @('installed', 'failed')
}
Describe 'New-WuSession' {
  It 'asks for English titles (UserLocale 1033)' {
    Mock New-Object { [pscustomobject]@{ ClientApplicationID = $null; UserLocale = 0 } } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
    $s = New-WuSession; $s.UserLocale | Should -Be 1033; $s.ClientApplicationID | Should -Be 'BenTech Setup'
  }
  It 'still returns the session when the locale is refused, with a WARN' {
    Mock Write-SetupLog { }
    Mock New-Object { $o = [pscustomobject]@{ ClientApplicationID = $null }; $o | Add-Member ScriptProperty UserLocale { 0 } { throw 'E_INVALIDARG' }; $o } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
    New-WuSession | Should -Not -BeNullOrEmpty; Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'en-US' }
  }
}
Describe 'Get-WuInstallMode and Get-WuProgressPath' {
  It 'defaults to OneAtATime, honours Batch, ignores nonsense' {
    Get-WuInstallMode -Config ([pscustomobject]@{}) | Should -Be 'OneAtATime'
    Get-WuInstallMode -Config ([pscustomobject]@{ windowsUpdate = [pscustomobject]@{ installMode = 'Batch' } }) | Should -Be 'Batch'
    Get-WuInstallMode -Config ([pscustomobject]@{ windowsUpdate = [pscustomobject]@{ installMode = 'Fast' } }) | Should -Be 'OneAtATime'
  }
  It 'derives the progress path from the result path' { Get-WuProgressPath -ResultPath 'C:\BenTech\Setup\Logs\wu-round2.json' | Should -Be 'C:\BenTech\Setup\Logs\wu-round2.progress.json' }
}
```
Entry.Tests: `It '-WuRound passes the configured install mode' { Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Out-Null; Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $InstallMode -eq 'OneAtATime' } }` and the same with `Mock Read-SetupConfig` returning a copy of the config whose `windowsUpdate.installMode` is `Batch`. Config.Tests: `It 'installs Windows updates one at a time by default' { $cfg.windowsUpdate.installMode | Should -Be 'OneAtATime' }`.

- [ ] **Step 2: Run** the three files. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM. **Never call the real WUA COM on this PC** (no `-SearchOnly` smoke test either).
- [ ] **Step 4: Run** the three files, then the full suite. Expected: `Failed: 0`, with every v1 R23 and R24a-d test unchanged and green.
- [ ] **Step 5: Commit:** `feat: install Windows updates one at a time and write round progress`.

---

### Task 12: Windows Update parent: NOW list, round lines, report section

**Files:**
- Modify: `src/Steps/WindowsUpdate.ps1` (parent side), `src/Report/Report.ps1`
- Test: `tests/WindowsUpdate.Tests.ps1`, `tests/Finalize.Tests.ps1` (report)

**Interfaces:**
- Consumes: Task 11 (`Get-WuProgressPath`, progress shape, `Found`, `Kb`), Task 5 (`Read-FileTail`, `Set-SetupNow`, `Add-SetupActivity`).
- Produces:
  - `Format-WuUpdateLine -Update <object> -> string` (pure): `'<marker> <Kb> <Title>'` + `(' ({0:0} MB)' -f SizeMB)` when SizeMB > 0; markers installed `[OK]`, failed `[X ]`, downloading/installing `[>>]`, pending `[..]`, skipped `[--]`; KB first, then the title through `ConvertTo-ScreenText`; no KB: just the title.
  - `Get-WuProgressLines -Path <string> -> string[]` (display only, never throws): the progress JSON via `Read-FileTail`; missing, half-written, not JSON or over 64 KB -> `@()`. First line: OneAtATime `'Downloading <Current> of <Total>'` / `'Installing <Current> of <Total>'`; Batch `'Downloading <Total> updates'` / `'Installing <Total> updates'`; `'Searching for updates'`; `'Round finished'`. Then one `Format-WuUpdateLine` per update.
  - `Invoke-StepWindowsUpdate`: removes a stale `wu-round<N>.progress.json` with the stale result file; before `Invoke-External`: `Set-SetupNow -SubTitle "round <N> (max <cap>)" -Provider { param($path) Get-WuProgressLines -Path $path } -ProviderArgument <progress path>`; after booking the result: `Add-SetupActivity "Windows Update round <N>: found <Found>, installed <count>, failed <count>"` (this round's lists).
  - `Update-WuRunState` appends to `Data.InstalledLines` one `"Round <Rounds>: <Kb> <Title>"` (`"Round <Rounds>: <Title>"` without a KB) per Installed entry that is booked as installed (not a re-offer, R24c); definition updates each time they install. `Get-WuResultData` returns `InstalledLines` (`[string[]]`).
  - `Format-SetupReport`: right after the `Windows Update: ...` line: `''`, `'Windows updates installed:'`, then `'  ' + (ConvertTo-ScreenText line)` per InstalledLines, or `'  none'`. The "Driver updates" section waits for the driver lists (build order A).

- [ ] **Step 1: Write the failing tests.**

```powershell
Describe 'Windows Update NOW' {
  It 'Format-WuUpdateLine puts the KB first and stays ASCII' {
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = 'KB5070001'; Title = '2026-10 Cumulative Update'; SizeMB = 412.4; Status = 'installing' }) | Should -Be '[>>] KB5070001 2026-10 Cumulative Update (412 MB)'
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = 'KB5070002'; Title = $Hebrew; SizeMB = 0; Status = 'installed' }) | Should -Be '[OK] KB5070002 ?????'
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = ''; Title = 'Intel driver'; SizeMB = 0; Status = 'skipped' }) | Should -Be '[--] Intel driver'
  }
  It 'Get-WuProgressLines: "Installing 3 of 7" one at a time, "Installing 7 updates" in batch' {
    $p = "$TestDrive\p.json"
    $u = @(1..7 | ForEach-Object { @{ Kb = "KB$_"; Title = "T$_"; SizeMB = 0; Status = 'pending' } })
    [IO.File]::WriteAllText($p, (ConvertTo-Json -Depth 4 -InputObject @{ Round = 1; Mode = 'OneAtATime'; Phase = 'installing'; Current = 3; Total = 7; Updates = $u }))
    $l = @(Get-WuProgressLines -Path $p); $l[0] | Should -Be 'Installing 3 of 7'; $l.Count | Should -Be 8
    [IO.File]::WriteAllText($p, (ConvertTo-Json -Depth 4 -InputObject @{ Round = 1; Mode = 'Batch'; Phase = 'installing'; Current = 0; Total = 7; Updates = $u }))
    (Get-WuProgressLines -Path $p)[0] | Should -Be 'Installing 7 updates'
  }
  It 'a half-written or missing progress file gives no lines' {
    [IO.File]::WriteAllText("$TestDrive\half.json", '{ "Round": 1, "Upda'); @(Get-WuProgressLines -Path "$TestDrive\half.json").Count | Should -Be 0
    @(Get-WuProgressLines -Path "$TestDrive\none.json").Count | Should -Be 0
  }
}
# inside Context 'Invoke-StepWindowsUpdate (parent step, child process mocked)':
It 'shows round N (max cap) and reads that round''s progress file' {
  $script:ctx = New-WuContext -Data @{ Rounds = 1 }
  Mock Invoke-External { $script:nowSeen = Get-SetupNow; @{ ExitCode = 0; TimedOut = $false; Output = '' } }
  $null = Invoke-StepWindowsUpdate -Context $script:ctx
  $nowSeen.SubTitle | Should -Be 'round 2 (max 6)'; $nowSeen.ProviderArgument | Should -Be (Join-Path $script:ctx.LogDir 'wu-round2.progress.json')
}
It 'removes a stale progress file before the round' {
  $script:ctx = New-WuContext; $stale = Join-Path $script:ctx.LogDir 'wu-round1.progress.json'
  [void][IO.Directory]::CreateDirectory($script:ctx.LogDir); 'old' | Set-Content $stale
  Mock Invoke-External { $script:staleSeen = Test-Path $stale; @{ ExitCode = 0; TimedOut = $false; Output = '' } }
  $null = Invoke-StepWindowsUpdate -Context $script:ctx; $staleSeen | Should -BeFalse
}
It 'writes one activity line per round with found, installed and failed' {
  $script:act = New-Object System.Collections.ArrayList; Mock Add-SetupActivity { [void]$script:act.Add($Text) }
  $script:ctx = New-WuContext
  $res = New-ChildResult -Installed @([ordered]@{ Id = 'a'; Title = 'A'; Kb = 'KB1' }) -Failed @([ordered]@{ Id = 'b'; Title = 'B'; ResultCode = 4 }); $res['Found'] = 5; $script:childResult = $res
  $null = Invoke-StepWindowsUpdate -Context $script:ctx
  @($act) | Should -Be @('Windows Update round 1: found 5, installed 1, failed 1')
}
It 'records installed updates per round for the report, but not a re-offer' {
  $script:ctx = New-WuContext -Data @{ Rounds = 1; Installed = 1; InstalledIds = @('a') }
  $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'a'; Title = 'A'; Kb = 'KB1' }, [ordered]@{ Id = 'c'; Title = 'Cumulative'; Kb = 'KB5070001' })
  $r = Invoke-StepWindowsUpdate -Context $script:ctx
  @($r.Data.InstalledLines) | Should -Be @('Round 2: KB5070001 Cumulative')
}
# Finalize.Tests (report)
It 'lists Windows updates installed per round, and none when there are none' {
  $red | Should -Contain 'Windows updates installed:'; $green[[array]::IndexOf($green, 'Windows updates installed:') + 1] | Should -Be '  none'
}
```
(For the report test give `$rs.Steps['windows-update'].Data` an `InstalledLines = @('Round 1: KB5070001 Cumulative', "Round 2: KB5070002 $Hebrew")` and also assert `$red | Should -Contain '  Round 2: KB5070002 ????'`.)

- [ ] **Step 2: Run** `tests\WindowsUpdate.Tests.ps1`, `tests\Finalize.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0` (every existing parent test unchanged).
- [ ] **Step 5: Commit:** `feat: show Windows Update rounds update by update and report them`.

---

### Task 13: Microsoft 365 in the background (Q2, Q3)

**Files:**
- Modify: `src/Steps/Office.ps1`, `src/Engine/Catalog.ps1`, `src/Engine/Reboot.ps1`, `src/Steps/Finalize.ps1`, `config/config.json`
- Test: `tests/Apps.Tests.ps1` (Office Describes; dot-source `State\State`; `Initialize-AppMocks` adds `Mock Start-BackgroundExternal` returning `[pscustomobject]@{ Id = 4242; StartTime = [datetime]'2026-10-20T10:00:00'; HasExited = $false }` and recording `@{ FilePath; ArgumentList }` in `$script:bg`), `tests/Catalog.Tests.ps1`, `tests/Runner.Tests.ps1` (dot-source `Common\Process`, `Steps\Office`), `tests/Finalize.Tests.ps1`, `tests/Config.Tests.ps1`

**Interfaces:**
- Consumes: `Start-BackgroundExternal`, `Stop-ProcessTree` (Process.ps1), `Wait-SetupDelay`, `Set-SetupNow`, `Clear-SetupNow`, `Enter-SetupWait`, `Exit-SetupWait`, `Add-SetupActivity` (Task 5), `Save-RunState`, v1 `Get-OdtSetupPath`, `New-OfficeConfigXml`, `Test-OfficeInstalled`.
- Produces:
  - **Catalog:** the plan order in Shared shapes; new entry `@{ Id = 'office-finish'; Title = 'Microsoft 365 (finish)'; Short = 'Microsoft 365'; Function = 'Invoke-StepOfficeFinish' }`; `Get-StepPlan` includes `office-finish` exactly when it includes `office`.
  - **config:** `apps.office.excludeApps = ["Access", "Publisher", "Teams", "OneDrive", "Groove", "Lync", "Bing", "OutlookForWindows"]` (any ID ODT rejects on the real-machine test is dropped later).
  - `$script:OfficeBackgroundProcess = $null` (Office.ps1).
  - `Initialize-OfficeInstall -Context <hashtable> -> @{ Result = <StepResult|$null>; SetupPath; XmlPath; ProductId }`: v1's checks in v1 order (choice OFF -> `Skipped('Office not selected')`; no product -> Failed; already in `ProductReleaseIds` -> `Done('Office already installed')`; ODT; setup.exe signature; XML written). A non-null `Result` is returned by the caller as is.
  - `Invoke-OfficeForegroundInstall -Context <hashtable> -Prepared <hashtable> -> StepResult`: v1's `/configure` through `Invoke-External` with `timeoutsMinutes.office` and v1's mapping, except **3010/1641 -> `Done('Office installed (restart pending)')` with `Reboot 'Now'`**: it now only runs inside `office-finish`, after `windows-update`, whose restarts ruling R17a relied on.
  - `Invoke-StepOffice -Context -> StepResult` (v2): `Initialize-OfficeInstall`; then `Start-BackgroundExternal -FilePath <SetupPath> -ArgumentList "/configure `"<XmlPath>`""` (cannot start -> `Failed('Office setup could not be started')`); keeps the process in `$script:OfficeBackgroundProcess`; `Add-SetupActivity "Microsoft 365 started installing in the background (<languages joined by ', '>)"`; returns `Done('Microsoft 365 installing in the background')` with `Data = @{ Background = $true; ProcessId; ProcessStartUtc = StartTime.ToUniversalTime().ToString('o'); StartedAt = <now, 's'>; DeadlineAt = <now + timeoutsMinutes.office, 's'> }`.
  - `Get-OfficeBackgroundProcess -Data <IDictionary> -> object|$null`: `$script:OfficeBackgroundProcess` when its `Id` equals `Data.ProcessId`; else `Get-Process -Id <ProcessId> -ErrorAction SilentlyContinue` whose `StartTime.ToUniversalTime()` is within 2 s of `ProcessStartUtc` (touch `.Handle` so `ExitCode` stays readable); a different start time (a reused PID) or no process -> `$null`.
  - `Wait-OfficeBackground -Context <hashtable> -Purpose <'Restart'|'Finish'> [-PollMilliseconds <int> = 1000] [-Clock <scriptblock> = { Get-Date }] -> @{ Outcome = 'None'|'Exited'|'Killed'|'Gone'; ExitCode = <int|$null> }`. Never throws.
    - `office` not in the plan, its Data without `Background`, or with `Finished` -> `None`, nothing written.
    - Process found: `Set-SetupNow -Title` (`'Waiting for Microsoft 365 to finish before restarting'` for Restart, `'Waiting for Microsoft 365 to finish'` for Finish); `Enter-SetupWait -LimitMinutes timeoutsMinutes.office -StartedAt <Data.StartedAt>`; loop `Wait-SetupDelay -Milliseconds $PollMilliseconds` until `HasExited` or `Clock >= DeadlineAt`; then `Exit-SetupWait` and `Set-SetupNow -Title $null` (the step's subtitle and provider stay).
    - Ended: `Data.ExitCode` (when readable), `Data.Finished = $true`, activity `"Microsoft 365 setup ended (exit <code>)"` (`(exit unknown)`), Outcome `Exited`.
    - Deadline: `Stop-ProcessTree -ProcessId`, `Data.KilledAtDeadline = $true`, `Data.Finished = $true`, activity `"Microsoft 365 setup stopped at its <N> min limit"`, Outcome `Killed`.
    - No process: `Data.Finished = $true`, Outcome `Gone`.
    - Every write is to `State.Steps['office'].Data`, followed by `Save-RunState` (a failed save is a WARN).
  - `Invoke-StepOfficeFinish -Context -> StepResult`:
    1. `office` not Done -> `Done('Nothing to finish: Microsoft 365 was not started')` (its own Failed already carries the red; the checklist shows office's status).
    2. `office` Done without `Data.Background` (already installed) -> `Done('Office already installed')`.
    3. `$wait = Wait-OfficeBackground -Purpose Finish`, then from `office` Data: `KilledAtDeadline` -> `Failed('Office setup timed out')`; `ExitCode` 0 -> `Done('Office installed')`; 3010/1641 -> `Done('Office installed (restart pending)')` with `Reboot 'Now'` **only when `$wait.Outcome -eq 'Exited'`** (this step saw it end, so no restart has happened since; a code stored by the restart wait was followed by that restart: no extra one, R17a); any other code -> `Failed('Office setup exit <code>')`, no retry.
    4. No code and no marker: `Test-OfficeInstalled` against `ProductReleaseIds` -> `Done('Office installed')`; otherwise, when `office-finish` Data has no `ForegroundTried`: write `ForegroundTried = $true` into `State.Steps['office-finish'].Data`, `Save-RunState`, then `Initialize-OfficeInstall` + `Invoke-OfficeForegroundInstall` (a second failure is its Failed); with `ForegroundTried` already set -> `Failed('Office setup did not complete')`.
  - `Invoke-ControlledReboot`: after the resume-task and cap checks (a refused restart never waits), before `RebootCount + 1`: `$null = Wait-OfficeBackground -Context $Context -Purpose Restart`. The restart is never refused because of Office.
  - **R26 interplay:** `Invoke-StepFinalize` and `Complete-SetupFinalization` both start with `$null = Wait-OfficeBackground -Context $Context -Purpose Finish` (no-op without a live background process), before Task 4's activation attempt and Chrome wait. Phase A restores power settings and Phase B deletes `Downloads\` (the ODT and `office.xml`); neither may race a live install. `Test-FinalRebootNeeded` stays unchanged: Office's own restart need is covered by `office-finish`'s `Reboot 'Now'`.

- [ ] **Step 1: Update and write the tests.** Existing `Describe 'Invoke-StepOffice'`: the preparation tests (Skipped, already installed, ODT via winget and fallback, signatures, XML content, extractor failures, unknown choice) stay; where they assert the `/configure` run on `$script:ext`, assert it on `$script:bg` instead (FilePath, ArgumentList `"/configure `"$xmlPath`""`), and the Done message becomes `'Microsoft 365 installing in the background'`. Move the exit-code tests (`exit 1603`, `3010 and 1641`, `codes next to the success codes`, `plain exit 0`, `times out`, `cannot be started` through `Invoke-External`) into a new `Describe 'Invoke-OfficeForegroundInstall'` that calls `Invoke-OfficeForegroundInstall -Context $ctx -Prepared (Initialize-OfficeInstall -Context $ctx)`, with one change: `3010 and 1641` now expect `Reboot | Should -Be 'Now'`. New tests (fake clock: `$script:t = [datetime]'2026-10-20T10:30:00'`; `Mock Wait-SetupDelay { $script:t = $script:t.AddSeconds(1); $script:polls++; if ($script:exitAfter -and $script:polls -ge $script:exitAfter) { $script:OfficeBackgroundProcess.HasExited = $true } }`; `Mock Save-RunState { $script:saves++ }`; `Mock Stop-ProcessTree { $script:killed = $ProcessId }`):

```powershell
Describe 'office: background start' {
  It 'starts /configure in the background and records the process' {
    $script:existing = @($script:odt)
    $r = Invoke-StepOffice -Context $script:ctx
    $r.Status | Should -Be 'Done'; $r.Message | Should -Be 'Microsoft 365 installing in the background'
    $script:bg[0].ArgumentList | Should -Be "/configure `"$($script:xmlPath)`""
    @($script:ext | Where-Object { $_.ArgumentList -like '/configure*' }).Count | Should -Be 0
    $r.Data.Background | Should -BeTrue; $r.Data.ProcessId | Should -Be 4242
    ([datetime]$r.Data.DeadlineAt - [datetime]$r.Data.StartedAt).TotalMinutes | Should -Be 60
  }
  It 'a setup.exe that cannot start is Failed' { $script:existing = @($script:odt); Mock Start-BackgroundExternal { throw 'Cannot start' }; (Invoke-StepOffice -Context $script:ctx).Message | Should -Be 'Office setup could not be started' }
}
Describe 'Get-OfficeBackgroundProcess' {
  BeforeEach { $script:OfficeBackgroundProcess = $null; $script:started = [datetime]'2026-10-20T09:59:00'
    $script:data = @{ ProcessId = 4242; ProcessStartUtc = $script:started.ToUniversalTime().ToString('o') } }
  It 'finds the process by id and start time' { Mock Get-Process { [pscustomobject]@{ Id = 4242; StartTime = $script:started; HasExited = $false; Handle = 1 } }; (Get-OfficeBackgroundProcess -Data $data).Id | Should -Be 4242 }
  It 'a process with the same id but another start time is not Office (Review Focus 5)' { Mock Get-Process { [pscustomobject]@{ Id = 4242; StartTime = $script:started.AddMinutes(30); HasExited = $false; Handle = 1 } }; Get-OfficeBackgroundProcess -Data $data | Should -BeNullOrEmpty }
  It 'no process is $null' { Mock Get-Process { }; Get-OfficeBackgroundProcess -Data $data | Should -BeNullOrEmpty }
}
Describe 'Wait-OfficeBackground' {
  BeforeEach { <ctx with plan containing office; office Data = @{ Background = $true; ProcessId = 4242; ProcessStartUtc = ...; StartedAt = '2026-10-20T10:00:00'; DeadlineAt = '2026-10-20T11:00:00' }>
    $script:OfficeBackgroundProcess = [pscustomobject]@{ Id = 4242; HasExited = $false; ExitCode = 0 }; $script:polls = 0; $script:saves = 0 }
  It 'without background data does nothing' { $script:ctx.State.Steps.office.Data = @{}; (Wait-OfficeBackground -Context $ctx -Purpose Restart -Clock { $script:t }).Outcome | Should -Be 'None'; $saves | Should -Be 0 }
  It 'waits, showing the restart title, then stores the exit code and saves' {
    $script:exitAfter = 3; $script:titles = New-Object System.Collections.ArrayList; Mock Set-SetupNow { [void]$script:titles.Add($Title) }
    $r = Wait-OfficeBackground -Context $ctx -Purpose Restart -Clock { $script:t }
    $r.Outcome | Should -Be 'Exited'; $r.ExitCode | Should -Be 0
    $titles[0] | Should -Be 'Waiting for Microsoft 365 to finish before restarting'
    $ctx.State.Steps.office.Data.ExitCode | Should -Be 0; $ctx.State.Steps.office.Data.Finished | Should -BeTrue; $saves | Should -BeGreaterThan 0
  }
  It 'kills the process tree at the deadline and stores the marker' {
    $script:exitAfter = 0; $script:t = [datetime]'2026-10-20T10:59:58'
    $r = Wait-OfficeBackground -Context $ctx -Purpose Restart -Clock { $script:t }
    $r.Outcome | Should -Be 'Killed'; $script:killed | Should -Be 4242; $ctx.State.Steps.office.Data.KilledAtDeadline | Should -BeTrue
  }
  It 'a process that is gone ends the wait with no code' { $script:OfficeBackgroundProcess = $null; Mock Get-Process { }; (Wait-OfficeBackground -Context $ctx -Purpose Finish -Clock { $script:t }).Outcome | Should -Be 'Gone'; $ctx.State.Steps.office.Data.Contains('ExitCode') | Should -BeFalse }
  It 'never throws when the state cannot be saved' { $script:exitAfter = 1; Mock Save-RunState { throw 'disk full' }; { Wait-OfficeBackground -Context $ctx -Purpose Finish -Clock { $script:t } } | Should -Not -Throw }
}
Describe 'office-finish' {
  # BeforeEach: Initialize-AppMocks; ctx plan includes office and office-finish; Mock Save-RunState { }; Mock Get-Process { }; Mock Add-OfficeDesktopShortcuts { @{ Created = @(); Failed = $false } } (Task 14 tests it)
  It 'a killed-at-deadline marker is Failed, with no foreground retry' { <office Data Finished + KilledAtDeadline>; $r = Invoke-StepOfficeFinish -Context $ctx; $r.Message | Should -Be 'Office setup timed out'; $script:ext.Count | Should -Be 0 }
  It 'a stored 3010 (a restart already followed) is Done without another restart' { <Finished, ExitCode 3010>; $r = Invoke-StepOfficeFinish -Context $ctx; $r.Status | Should -Be 'Done'; $r.Reboot | Should -Be 'None' }
  It '3010 seen by its own wait asks for a restart' { <process alive, ExitCode 3010, exitAfter 1>; $r = Invoke-StepOfficeFinish -Context $ctx; $r.Message | Should -Be 'Office installed (restart pending)'; $r.Reboot | Should -Be 'Now' }
  It 'another stored code is Failed with the code, no retry' { <Finished, ExitCode 17002>; (Invoke-StepOfficeFinish -Context $ctx).Message | Should -Be 'Office setup exit 17002'; $script:ext.Count | Should -Be 0 }
  It 'no code but the product is installed is Done' { <Finished, no code; regRead ProductReleaseIds O365BusinessRetail>; (Invoke-StepOfficeFinish -Context $ctx).Message | Should -Be 'Office installed' }
  It 'no code, not installed, no process: one foreground install, recorded before it starts' {
    <Finished, no code; existing = odt>; Mock Invoke-External { $script:triedSeen = $ctx.State.Steps['office-finish'].Data.ForegroundTried; @{ ExitCode = 0; TimedOut = $false; Output = '' } }
    (Invoke-StepOfficeFinish -Context $ctx).Message | Should -Be 'Office installed'; $triedSeen | Should -BeTrue
  }
  It 'a second time without a code is Failed and never retries again' { <Finished, no code, office-finish Data ForegroundTried>; (Invoke-StepOfficeFinish -Context $ctx).Message | Should -Be 'Office setup did not complete'; $script:ext.Count | Should -Be 0 }
  It 'nothing to finish when office did not start' { <office Failed>; (Invoke-StepOfficeFinish -Context $ctx).Message | Should -Be 'Nothing to finish: Microsoft 365 was not started' }
  It 'already installed Office is Done without waiting' { <office Done, no Background>; (Invoke-StepOfficeFinish -Context $ctx).Message | Should -Be 'Office already installed'; Should -Invoke Get-Process -Times 0 }
}
```

Runner.Tests (`Describe 'Invoke-ControlledReboot and Office'`; ctx plan `@('office')`):
```powershell
It 'waits for Office before counting and restarting' {
  $script:order = New-Object System.Collections.ArrayList
  Mock Wait-OfficeBackground { [void]$script:order.Add("wait $($Context.State.RebootCount) $Purpose"); @{ Outcome = 'Exited'; ExitCode = 0 } }
  $c = New-Ctx @('a'); Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { [void]$script:order.Add('restart') } | Should -BeTrue
  @($order) | Should -Be @('wait 0 Restart', 'restart')
}
It 'never waits when the restart is refused (cap, no resume task)' {
  Mock Wait-OfficeBackground { @{ Outcome = 'None' } }
  $c = New-Ctx @('a'); $c.State.RebootCount = 2; Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { } | Should -BeFalse
  $c2 = New-Ctx @('a'); $c2.State.ResumeTaskMissing = $true; Invoke-ControlledReboot -Context $c2 -CountdownSeconds 0 -RestartAction { } | Should -BeFalse
  Should -Invoke Wait-OfficeBackground -Times 0 -Exactly
}
It 'still restarts after Office was killed at its deadline' { Mock Wait-OfficeBackground { @{ Outcome = 'Killed' } }; $script:restarts = 0; $c = New-Ctx @('a'); Invoke-ControlledReboot -Context $c -CountdownSeconds 0 -RestartAction { $script:restarts++ } | Should -BeTrue; $restarts | Should -Be 1 }
```
Finalize.Tests: `It 'waits for a live background Office first, in the step and in Complete-SetupFinalization (R26)' { Mock Wait-OfficeBackground { [void]$script:order.Add('office'); @{ Outcome = 'None' } }; ...; $order[0] | Should -Be 'office'; Should -Invoke Wait-OfficeBackground -ParameterFilter { $Purpose -eq 'Finish' } }` (reuse the file's existing Phase A/Phase B fixtures and record the first Phase action after it).
Catalog.Tests: the rows list becomes 19 rows in the new order with `'office-finish|Microsoft 365 (finish)|Invoke-StepOfficeFinish'`; the Dell laptop order string becomes `'prepare,bitlocker,region,desktop-icons,bloatware,rename,winget,chrome,anydesk,7zip,default-browser,vendor-pass1,office,windows-update,office-finish,vendor-pass2,consumer-app,vendor-cleanup,finalize'`; every `18` becomes `19` and `$p[17]` becomes `$p[18]`; `'toggles off'` also asserts `$p | Should -Not -Contain 'office-finish'`; new `It 'office-finish comes with office, right after windows-update' { $p = @(P ASUS LAPTOP); $p.IndexOf('office-finish') | Should -Be ($p.IndexOf('windows-update') + 1); $p.IndexOf('office') | Should -Be ($p.IndexOf('windows-update') - 1) }`. Config.Tests: `It 'excludes every Office app except Word, Excel, PowerPoint, classic Outlook and OneNote' { @($cfg.apps.office.excludeApps) | Should -Be @('Access','Publisher','Teams','OneDrive','Groove','Lync','Bing','OutlookForWindows') }`.

- [ ] **Step 2: Run** the five test files. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM. **Never start setup.exe, ODT or a restart on this PC.**
- [ ] **Step 4: Run** the five files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: install Microsoft 365 in the background and let restarts wait for it`.

---

### Task 14: Office desktop shortcuts

**Files:**
- Modify: `src/Steps/Office.ps1`
- Test: `tests/Apps.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-StepOfficeFinish` (Task 13), `Add-SetupActivity`.
- Produces:
  - `$script:OfficeShortcutApps = [ordered]@{ Word = 'WINWORD.EXE'; Excel = 'EXCEL.EXE'; PowerPoint = 'POWERPNT.EXE'; Outlook = 'OUTLOOK.EXE' }`.
  - `Get-OfficeExeFolder -> string|$null`: `InstallationPath` from `HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` (`Get-ItemProperty -ErrorAction SilentlyContinue`, as v1 reads it) joined with `root\Office16`; `$null` when missing.
  - `New-DesktopShortcut -Path <string> -TargetPath <string>` (private): `WScript.Shell` `CreateShortcut`, `TargetPath`, `WorkingDirectory` = the target's folder, `Save()`; throws on failure.
  - `Add-OfficeDesktopShortcuts [-DesktopFolder <string>] [-ExeFolder <string>] -> @{ Created = <string[]>; Failed = <bool> }`: defaults resolved in the body: `[Environment]::GetFolderPath('CommonDesktopDirectory')` (the public desktop, all users) and `Get-OfficeExeFolder`. Per app: `<Desktop>\<Name>.lnk` exists -> left alone; `<ExeFolder>\<exe>` missing -> skipped; else `New-DesktopShortcut`. A throw is a WARN and `Failed = $true`; the others are still tried. No exe folder -> `Failed = $true`.
  - `Invoke-StepOfficeFinish`: on every Done (including 'Office already installed'): `Add-OfficeDesktopShortcuts`; `Created` not empty -> activity `"Desktop shortcuts: <names joined by ', '>"`; `Failed` -> Note `'Office desktop shortcuts could not be created'`. Not on Failed.

- [ ] **Step 1: Write the failing tests.** The `Add-OfficeDesktopShortcuts` Describe does **not** call `Initialize-AppMocks` (whose `Test-Path` mock would hide the files): `$desk` and `$exe` are real `$TestDrive` folders, fake exe files are created with `Set-Content`, and it mocks only `Write-SetupLog`, `Get-OfficeExeFolder` (where a test says so) and `New-DesktopShortcut { [void]$script:made.Add(@{ Path = $Path; Target = $TargetPath }) }`. The office-finish Describe uses `Initialize-AppMocks` and the Task 13 fixtures.

```powershell
Describe 'Add-OfficeDesktopShortcuts' {
  It 'creates Word, Excel, PowerPoint and Outlook on the public desktop, pointing at root\Office16' {
    foreach ($e in 'WINWORD.EXE','EXCEL.EXE','POWERPNT.EXE','OUTLOOK.EXE') { 'x' | Set-Content (Join-Path $exe $e) }
    $r = Add-OfficeDesktopShortcuts -DesktopFolder $desk -ExeFolder $exe
    @($r.Created) | Should -Be @('Word','Excel','PowerPoint','Outlook'); $r.Failed | Should -BeFalse
    $made[0].Path | Should -Be (Join-Path $desk 'Word.lnk'); $made[0].Target | Should -Be (Join-Path $exe 'WINWORD.EXE')
  }
  It 'leaves an existing shortcut alone and skips a missing executable' {
    'x' | Set-Content (Join-Path $exe 'WINWORD.EXE'); 'x' | Set-Content (Join-Path $exe 'EXCEL.EXE'); 'old' | Set-Content (Join-Path $desk 'Word.lnk')
    @((Add-OfficeDesktopShortcuts -DesktopFolder $desk -ExeFolder $exe).Created) | Should -Be @('Excel')
  }
  It 'a failing shortcut is reported and the others are still made' {
    foreach ($e in 'WINWORD.EXE','EXCEL.EXE') { 'x' | Set-Content (Join-Path $exe $e) }
    Mock New-DesktopShortcut { if ($Path -like '*Word.lnk') { throw 'access denied' }; [void]$script:made.Add(@{ Path = $Path }) }
    $r = Add-OfficeDesktopShortcuts -DesktopFolder $desk -ExeFolder $exe; $r.Failed | Should -BeTrue; @($r.Created) | Should -Be @('Excel')
  }
  It 'no Office folder is a failure' { Mock Get-OfficeExeFolder { $null }; (Add-OfficeDesktopShortcuts -DesktopFolder $desk).Failed | Should -BeTrue }
}
Describe 'office-finish shortcuts' {
  It 'creates them after a Done and says so' { Mock Add-OfficeDesktopShortcuts { @{ Created = @('Word','Excel'); Failed = $false } }; <stored ExitCode 0>; $r = Invoke-StepOfficeFinish -Context $ctx; @($script:activity.Text) | Should -Contain 'Desktop shortcuts: Word, Excel'; @($r.Notes).Count | Should -Be 0 }
  It 'a failure is a yellow Note, the step stays Done' { Mock Add-OfficeDesktopShortcuts { @{ Created = @(); Failed = $true } }; <stored ExitCode 0>; $r = Invoke-StepOfficeFinish -Context $ctx; $r.Status | Should -Be 'Done'; $r.Notes | Should -Contain 'Office desktop shortcuts could not be created' }
  It 'also for Office that was already installed' { Mock Add-OfficeDesktopShortcuts { @{ Created = @('Word'); Failed = $false } }; <office Done, no Background>; $null = Invoke-StepOfficeFinish -Context $ctx; Should -Invoke Add-OfficeDesktopShortcuts -Times 1 -Exactly }
  It 'never after a failure' { Mock Add-OfficeDesktopShortcuts { }; <KilledAtDeadline>; $null = Invoke-StepOfficeFinish -Context $ctx; Should -Invoke Add-OfficeDesktopShortcuts -Times 0 -Exactly }
}
```

- [ ] **Step 2: Run** `tests\Apps.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement.** Re-save with BOM. `New-DesktopShortcut` is the only `WScript.Shell` touchpoint and is always mocked.
- [ ] **Step 4: Run** the file, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: Office desktop shortcuts on the public desktop`.

---

### Task 15: No leftover folder (spec §10)

When the technician finishes the final screen with Enter, the logs go to the USB stick and `C:\BenTech` is deleted. A crash leaves everything (v1). The launcher does not change: it already sets `BT_SELF`, which `setup.ps1` inherits.

**Files:**
- Create: `src/Entry/Cleanup.ps1`, `tests/Cleanup.Tests.ps1`
- Modify: `src/Entry/Main.ps1`, `src/UI/FinalScreen.ps1`, `tools/Build-Bundle.ps1` (`'Entry\Cleanup.ps1'` right before `'Entry\Main.ps1'`)
- Test: `tests/Screens.Tests.ps1` (`Format-FinalScreen`, `Show-FinalScreen`), `tests/Entry.Tests.ps1` (dot-source `Entry\Cleanup`; **`BeforeEach` adds `Mock Invoke-SetupCleanup { }`** and `Mock Get-LauncherInfo { @{ Path = 'E:\BenTechSetup.cmd'; Drive = 'E:'; VolumeSerial = '1A2B3C4D' } }`), `tests/Waits.Tests.ps1` (the allow-list gains `'UI\FinalScreen.ps1|Show-FinalScreen'`, the final screen's `-Sleep` seam, which runs after the tick is gone)

**Interfaces:**
- Consumes: `Invoke-External`, `Wait-SetupDelay`, `New-ConsoleWriter`, `Write-ConsoleFrame`, `Get-VerdictColors` (Task 2), `Exit-RunLock`.
- Produces, `src/Entry/Cleanup.ps1` (none of them throws):
  - `Get-LauncherInfo -Path <string> -> @{ Path; Drive; VolumeSerial }|$null`: `$null` for an empty path; `Drive` = the path's drive letter (`'E:'`, `$null` for a UNC path); `VolumeSerial` = `Win32_LogicalDisk` (`-Filter "DeviceID='E:'"`, `-OperationTimeoutSec 10`) `.VolumeSerialNumber`, `$null` when unknown.
  - `Find-SetupStick -Launcher <hashtable|$null> [-SystemDrive <string> = $env:SystemDrive] -> @{ Root = 'E:\'|$null; Drive = 'E:'|$null }`: one `Get-CimInstance Win32_LogicalDisk` read. The disk whose `VolumeSerialNumber` equals `Launcher.VolumeSerial` (case-insensitive) wins; otherwise the first disk other than `-SystemDrive` with `<DeviceID>\BenTechSetup.cmd` (`Test-Path -LiteralPath`); otherwise none.
  - `Format-StickLine -Stick <hashtable> -> string`: `'  USB stick found (E:) - logs will be saved there'` or `'  No BenTech USB stick - plug it in now to keep the logs'`.
  - `Copy-SetupLogsToStick -LogDir <string> -StickRoot <string> -PcName <string> -> @{ Ok = <bool>; Target = <string>; Error = <string|$null> }`: target `<StickRoot>BenTech-Logs\<PcName>` (invalid file-name characters become `_`; empty name `UNKNOWN-PC`); an existing target is removed first (`Remove-Item -LiteralPath -Recurse -Force -ErrorAction Stop`; FAT/exFAT holds no junctions), then `Copy-Item -LiteralPath $LogDir -Destination $target -Recurse -Force -ErrorAction Stop`.
  - `Test-DesktopLauncher -Path <string> [-UserDesktop <string>] [-PublicDesktop <string>] -> bool`: the launcher's folder equals (full path, case-insensitive, trailing `\` ignored) `[Environment]::GetFolderPath('Desktop')` or `GetFolderPath('CommonDesktopDirectory')` (defaults resolved in the body).
  - `Remove-SetupFolder -Path <string> [-Retries <int> = 3] [-RetrySeconds <int> = 2] -> bool`: refuses (ERROR log, `$false`, nothing run) unless `[IO.Path]::GetFullPath($Path)` has the leaf `BenTech`, is not a drive root and is not a reparse point; then `Invoke-External -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/d /c rd /s /q "{0}"' -f $full) -TimeoutMinutes 5`, up to 1 + `Retries` tries with `Wait-SetupDelay -Seconds $RetrySeconds` between them. Success = the folder no longer exists (`rd`'s exit code is not trusted).
  - `Invoke-SetupCleanup -Root <string> -Mode <'Finish'|'Cancel'> [-State <hashtable>] [-ReadKey <scriptblock> = { [Console]::ReadKey($true).Key.ToString() }] [-Write <scriptblock> = { param($t) Write-Host $t -ForegroundColor White -BackgroundColor Black }] [-ProgramDataFolder <string> = (Join-Path $env:ProgramData 'BenTech')]`:
    1. Logs `'Cleanup: saving the logs and removing C:\BenTech'` (`Mode` in the data), then stops logging: `$script:SetupLogPath = $null`, `$script:SetupActivityPath = $null` (the caller already stopped the transcript).
    2. Finish: `Find-SetupStick -Launcher $State.Launcher`. Found: write `"Saving the logs to <target> ..."`, `Copy-SetupLogsToStick` with `State.Machine.NewName` (else `ComputerName`); a failed copy writes `"Logs could not be saved to the USB stick: <error>"` and `'Press ENTER to delete C:\BenTech anyway'`, then waits for Enter (other keys ignored). Not found: write `'No USB stick found: the logs are not saved'` and go on (the final screen's live line already warned).
    3. Finish: `Test-DesktopLauncher -Path $State.Launcher.Path` -> delete that one file (`Remove-Item -LiteralPath -Force -ErrorAction Stop` in a `try`; a failure is a written line). A launcher anywhere else is never touched.
    4. `Set-Location -LiteralPath $env:SystemRoot`; `[Environment]::CurrentDirectory = $env:SystemRoot`.
    5. `Remove-SetupFolder -Path (Split-Path -Parent $Root)`; `$false` -> write `'Could not delete C:\BenTech - delete it by hand'` and wait for any key.
    6. `-ProgramDataFolder` removed with `[IO.Directory]::Delete($path, $false)` when it exists and is empty.
    Cancel runs 1 and 4-6 only.
- Produces, `src/UI/FinalScreen.ps1`:
  - `Format-FinalScreen ... [string]$StickLine = ''`: the stick line right above the report line; the report line becomes `'  Report: <path>   [R] open report   [ENTER] finish'`; `$script:FinalMaxFailures = 3`, `$script:FinalMaxNotes = 2`, so the worst case is 29 lines (the frame writer keeps the last row of a 30-row window free).
  - `Show-FinalScreen`: same parameters, plus `-Stick <scriptblock> = { Find-SetupStick -Launcher $State['Launcher'] }`, `-Now <scriptblock> = { Get-Date }`, `-Sleep <scriptblock> = { param($ms) Start-Sleep -Milliseconds $ms }`. `-ReadKey` becomes non-blocking (`{ if ([Console]::KeyAvailable) { [Console]::ReadKey($true).Key.ToString() } }`). `-Write` (`param($lines, $foreground, $background)`) defaults to `Write-ConsoleFrame -Lines $lines -Writer (New-ConsoleWriter) -Foreground $foreground -Background $background`: a redraw every second without flicker and without filling the transcript. Flow: paint (Task 2 colours), read the stick, draw, flush the key buffer, then poll every 100 ms: **`Enter` returns**; `B` and `R` as before; every other key is ignored; every second (by the clock or by the summed sleeps, the start-screen rule) the stick is read again and the screen redrawn. A `-Stick` that throws counts as no stick (one WARN). A `-ReadKey` that throws still propagates after the colours are restored (a crash keeps the folder).
- Produces, `src/Entry/Main.ps1`:
  - New run, right after `New-RunState`: `$runState.Launcher = Get-LauncherInfo -Path $env:BT_SELF`. A resume records nothing (the resume task has no `BT_SELF`).
  - `Invoke-SetupMainFlow` (private; `Start-BenTechSetup` is its only caller) returns `@{ Outcome = 'Cancelled'|'NoState'|'Rebooting'|'Completed'; State = <hashtable|$null>; HadPrevious = <bool> }`.
  - `Start-BenTechSetup`: `Completed` -> cleanup `@{ Mode = 'Finish'; State = $flow.State }`; `Cancelled` with `HadPrevious = $false` -> `@{ Mode = 'Cancel' }`; then, **after** its `finally` (tick unregistered, run lock and mutex released, transcript stopped): `Invoke-SetupCleanup -Root $Root @cleanup`. A crash, `Rebooting`, `NoState` or a lock held by another run: no cleanup. Exit codes unchanged.
- **Interplay, checked:**
  - Finalize Phase A and Phase B are unchanged: Phase B still writes the report, removes the resume task and deletes `Downloads\`, `setup.ps1` and `config.json` before the final screen; the report is in `Logs\` and is copied with it.
  - R26: `Complete-SetupRun`'s own `Complete-SetupFinalization` runs before the final screen, so the copy holds its report; a finalization that throws is still a red final screen, then Enter and the cleanup.
  - `Rebooting` keeps the lock and the folder (the run resumes from `C:\BenTech`).
  - Esc: R27's `Unregister-ResumeTask` stays. The folder is deleted only when no earlier run state was found ("because nothing ran", §10.6); an earlier unfinished run's folder and logs stay for diagnosis.
  - The start screen's `Previous run:` line needs no change: it simply only appears after an unfinished run (§10.7).

- [ ] **Step 1: Write the failing tests** (`tests/Cleanup.Tests.ps1`; nothing outside `$TestDrive` is ever deleted).

```powershell
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Entry\Cleanup') { . "$PSScriptRoot\..\src\$f.ps1" }
  function New-Disk($id, $serial) { [pscustomobject]@{ DeviceID = $id; VolumeSerialNumber = $serial } }
}
Describe 'Get-LauncherInfo' {
  It 'records the path, its drive and that drive''s volume serial' {
    Mock Get-CimInstance { New-Disk 'E:' '1A2B3C4D' } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
    $i = Get-LauncherInfo -Path 'E:\BenTechSetup.cmd'; $i.Drive | Should -Be 'E:'; $i.VolumeSerial | Should -Be '1A2B3C4D'
    Should -Invoke Get-CimInstance -ParameterFilter { $Filter -eq "DeviceID='E:'" }
  }
  It 'is $null without BT_SELF; no serial for a UNC path or a failed query' {
    Get-LauncherInfo -Path '' | Should -BeNullOrEmpty
    (Get-LauncherInfo -Path '\\server\share\BenTechSetup.cmd').VolumeSerial | Should -BeNullOrEmpty
    Mock Get-CimInstance { throw 'WMI down' }; (Get-LauncherInfo -Path 'E:\BenTechSetup.cmd').VolumeSerial | Should -BeNullOrEmpty
  }
}
Describe 'Find-SetupStick (Review Focus 1)' {
  BeforeEach { Mock Get-CimInstance { New-Disk 'C:' 'AAAA0001'; New-Disk 'F:' '1A2B3C4D'; New-Disk 'G:' 'BBBB0002' } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }; Mock Test-Path { $false } }
  It 'finds the stick by its serial, also under another letter' { (Find-SetupStick -Launcher @{ Drive = 'E:'; VolumeSerial = '1a2b3c4d' } -SystemDrive 'C:').Drive | Should -Be 'F:' }
  It 'falls back to a drive holding BenTechSetup.cmd, never the system drive' {
    Mock Test-Path { $LiteralPath -in 'C:\BenTechSetup.cmd', 'G:\BenTechSetup.cmd' }
    $s = Find-SetupStick -Launcher @{ VolumeSerial = 'FFFF0000' } -SystemDrive 'C:'; $s.Drive | Should -Be 'G:'; $s.Root | Should -Be 'G:\'
  }
  It 'none when nothing matches, the record is missing or the query fails' {
    (Find-SetupStick -Launcher $null -SystemDrive 'C:').Root | Should -BeNullOrEmpty
    Mock Get-CimInstance { throw 'WMI down' }; (Find-SetupStick -Launcher @{ VolumeSerial = '1A2B3C4D' } -SystemDrive 'C:').Root | Should -BeNullOrEmpty
  }
  It 'the live line says where the logs go' {
    Format-StickLine -Stick @{ Root = 'E:\'; Drive = 'E:' } | Should -Be '  USB stick found (E:) - logs will be saved there'
    Format-StickLine -Stick @{ Root = $null } | Should -Be '  No BenTech USB stick - plug it in now to keep the logs'
  }
}
Describe 'Copy-SetupLogsToStick' {
  It 'replaces <stick>\BenTech-Logs\<PC name> with the Logs folder' {
    $logs = "$TestDrive\Logs"; [void][IO.Directory]::CreateDirectory($logs); 'r' | Set-Content "$logs\Setup-Report.txt"
    $old = "$TestDrive\stick\BenTech-Logs\DELL-J0C7QK4"; [void][IO.Directory]::CreateDirectory($old); 'old' | Set-Content "$old\stale.txt"
    (Copy-SetupLogsToStick -LogDir $logs -StickRoot "$TestDrive\stick\" -PcName 'DELL-J0C7QK4').Ok | Should -BeTrue
    "$old\Setup-Report.txt" | Should -Exist; "$old\stale.txt" | Should -Not -Exist
  }
  It 'a failed copy is reported, never thrown' {
    Mock Copy-Item { Write-Error 'The device is not ready' }
    $r = Copy-SetupLogsToStick -LogDir "$TestDrive\Logs" -StickRoot "$TestDrive\s2\" -PcName 'PC'; $r.Ok | Should -BeFalse; $r.Error | Should -Match 'not ready'
  }
}
Describe 'Remove-SetupFolder (Review Focus 2)' {
  It 'refuses anything that is not a folder named BenTech' {
    Mock Invoke-External { throw 'must not run' }
    foreach ($p in 'C:\', 'C:\Windows', $TestDrive, "$TestDrive\BenTechX") { Remove-SetupFolder -Path $p | Should -BeFalse }
    Should -Invoke Invoke-External -Times 0 -Exactly
  }
  It 'runs rd /s /q through Invoke-External and retries 3 times, 2 s apart' {
    $t = "$TestDrive\r1\BenTech"; [void][IO.Directory]::CreateDirectory($t)
    Mock Invoke-External { @{ ExitCode = 0; TimedOut = $false; Output = '' } }; Mock Wait-SetupDelay { }
    Remove-SetupFolder -Path $t | Should -BeFalse
    Should -Invoke Invoke-External -Times 4 -Exactly -ParameterFilter { $FilePath -like '*\System32\cmd.exe' -and $ArgumentList -eq ('/d /c rd /s /q "{0}"' -f $t) }
    Should -Invoke Wait-SetupDelay -Times 3 -Exactly -ParameterFilter { $Seconds -eq 2 }
  }
  It 'rd removes a junction inside without touching its target (real rd, inside $TestDrive only)' {
    $b = "$TestDrive\r2"; [void][IO.Directory]::CreateDirectory("$b\target"); 'keep' | Set-Content "$b\target\keep.txt"; [void][IO.Directory]::CreateDirectory("$b\BenTech\Setup")
    & "$env:SystemRoot\System32\cmd.exe" /d /c mklink /J "$b\BenTech\Setup\link" "$b\target" | Out-Null
    Remove-SetupFolder -Path "$b\BenTech" | Should -BeTrue
    "$b\BenTech" | Should -Not -Exist; "$b\target\keep.txt" | Should -Exist
  }
}
Describe 'Test-DesktopLauncher' {
  It 'is true only for the user''s or the public Desktop itself' {
    $d = @{ UserDesktop = 'C:\Users\ben\Desktop'; PublicDesktop = 'C:\Users\Public\Desktop' }
    Test-DesktopLauncher -Path 'C:\Users\ben\Desktop\BenTechSetup.cmd' @d | Should -BeTrue
    Test-DesktopLauncher -Path 'c:\users\public\desktop\BenTechSetup.cmd' @d | Should -BeTrue
    Test-DesktopLauncher -Path 'E:\BenTechSetup.cmd' @d | Should -BeFalse
    Test-DesktopLauncher -Path 'C:\Users\ben\Desktop\tools\BenTechSetup.cmd' @d | Should -BeFalse
  }
}
Describe 'Invoke-SetupCleanup' {
  BeforeEach {
    $script:order = New-Object System.Collections.ArrayList; $script:lines = New-Object System.Collections.ArrayList; $script:SetupLogPath = "$TestDrive\x.log"
    Mock Write-SetupLog { }; Mock Find-SetupStick { @{ Root = 'E:\'; Drive = 'E:' } }
    Mock Copy-SetupLogsToStick { [void]$script:order.Add("copy $PcName logging=$([bool]$script:SetupLogPath)"); @{ Ok = $true; Target = 'E:\BenTech-Logs\DELL-J0C7QK4' } }
    Mock Test-DesktopLauncher { $true }; Mock Remove-Item { [void]$script:order.Add("del $LiteralPath") }; Mock Set-Location { }
    Mock Remove-SetupFolder { [void]$script:order.Add("rd $Path"); $true }
    $script:st = @{ Machine = @{ NewName = 'DELL-J0C7QK4' }; Launcher = @{ Path = 'C:\Users\ben\Desktop\BenTechSetup.cmd'; VolumeSerial = '1A2B3C4D' } }
    $script:run = @{ Root = 'C:\BenTech\Setup'; State = $st; Write = { param($t) [void]$script:lines.Add($t) }; ProgramDataFolder = "$TestDrive\pd" }
  }
  It 'Finish: stops logging, copies the logs, deletes the Desktop launcher, then removes C:\BenTech' {
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { throw 'no key expected' }
    @($order) | Should -Be @('copy DELL-J0C7QK4 logging=False', 'del C:\Users\ben\Desktop\BenTechSetup.cmd', 'rd C:\BenTech')
  }
  It 'a failed copy is shown, and only Enter goes on to the deletion' {
    Mock Copy-SetupLogsToStick { @{ Ok = $false; Error = 'disk full' } }; $script:keys = New-Object Collections.Queue; 'X', 'Enter' | ForEach-Object { $script:keys.Enqueue($_) }
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { $script:keys.Dequeue() }
    $lines | Should -Contain 'Logs could not be saved to the USB stick: disk full'; $script:keys.Count | Should -Be 0; $order | Should -Contain 'rd C:\BenTech'
  }
  It 'no stick: says so and deletes without waiting' {
    Mock Find-SetupStick { @{ Root = $null } }; Invoke-SetupCleanup @run -Mode Finish -ReadKey { throw 'no key expected' }
    $lines | Should -Contain 'No USB stick found: the logs are not saved'; Should -Invoke Copy-SetupLogsToStick -Times 0 -Exactly
  }
  It 'a deletion that fails says so and waits for a key' {
    Mock Remove-SetupFolder { $false }; $script:keys = New-Object Collections.Queue; $script:keys.Enqueue('Q')
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { $script:keys.Dequeue() }
    $lines | Should -Contain 'Could not delete C:\BenTech - delete it by hand'; $script:keys.Count | Should -Be 0
  }
  It 'Cancel only removes C:\BenTech: no copy, the launcher stays' { Invoke-SetupCleanup @run -Mode Cancel -ReadKey { throw 'no key' }; @($order) | Should -Be @('rd C:\BenTech') }
  It 'removes an empty ProgramData\BenTech and keeps one that has files' {
    [void][IO.Directory]::CreateDirectory("$TestDrive\pd"); Invoke-SetupCleanup @run -Mode Cancel -ReadKey { }; "$TestDrive\pd" | Should -Not -Exist
    [void][IO.Directory]::CreateDirectory("$TestDrive\pd"); 'x' | Set-Content "$TestDrive\pd\f.txt"; Invoke-SetupCleanup @run -Mode Cancel -ReadKey { }; "$TestDrive\pd\f.txt" | Should -Exist
  }
}
```

Screens.Tests (final screen): `Invoke-FinalScreen` passes `-Stick { $script:stick }` (default `@{ Root = 'E:\'; Drive = 'E:' }`), a fake clock (`-Now`, `-Sleep` advancing it) and a `-ReadKey` that pops the queue and throws `'runaway: no Enter'` after 2000 empty polls; its default `-Keys` is `@('Enter')`, and every existing key sequence that ended in `Q` or `Escape` ends in `Enter`. Changes:
- `'any other key returns without launching anything'` -> `It 'only Enter finishes; every other key is ignored' { Invoke-FinalScreen -Keys 'Escape', 'Spacebar', 'X', 'Q', 'Enter'; $launched.Count | Should -Be 0; @($events | Where-Object { $_ -eq 'read' }).Count | Should -BeGreaterOrEqual 5 }`.
- `'returns instead of looping forever when no key can be read'` is removed (no key now means "keep waiting"); the runaway guard covers it.
- Task 2's production-writer test becomes `It 'the production writer draws through the console writer in the verdict colours' { Mock New-ConsoleWriter { $script:writer }; <YELLOW>; every recorded Write has C = 'Black' and B = 'Yellow'; Write-Host and Clear-Host are never called }`; `'writes the last line without a newline ...'` is removed (the frame writer never scrolls).
- Format tests: the report line is `'  Report: C:\BenTech\Setup\Logs\Setup-Report.txt   [R] open report   [ENTER] finish'`; the caps test expects 3 failures and 2 notes (`'  X  ... and 7 more: see the report'`, `'  !  ... and 4 more: see the report'`).
New:
```powershell
It 'the worst-case final screen fits 29 lines (Review Focus 3)' {
  $st = New-FinalState; $st.AnyDeskId = '1234567890'
  $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict -Color 'RED' -Banner 'COMPLETED WITH ERRORS' -Failures @(1..20 | % { "Failure $_" }) -Notes @(1..20 | % { "Note $_" })) -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' -DefaultBrowserIsChrome $false -StickLine '  No BenTech USB stick - plug it in now to keep the logs')
  $l.Count | Should -BeLessOrEqual 29; $l[$l.Count - 2] | Should -Be '  No BenTech USB stick - plug it in now to keep the logs'
}
It 'shows the stick line live: a stick plugged in while waiting appears within a second' {
  $script:stick = @{ Root = $null }; $script:plugAt = 3
  <-Stick { if ((Get-ElapsedSeconds) -ge $script:plugAt) { @{ Root = 'F:\'; Drive = 'F:' } } else { @{ Root = $null } } }; Enter at 5 s>
  $drawn[0] | Should -Match 'No BenTech USB stick'; $drawn[$drawn.Count - 1] | Should -Match 'USB stick found \(F:\)'
}
It 'a stick check that throws shows "no stick" and keeps going' { <-Stick { throw 'WMI down' }>; $drawn[0] | Should -Match 'No BenTech USB stick' }
```
Entry.Tests:
```powershell
It 'a new run records the launcher; a resume does not' {
  $env:BT_SELF = 'E:\BenTechSetup.cmd'
  try { Invoke-Entry | Out-Null; Should -Invoke Get-LauncherInfo -Times 1 -Exactly -ParameterFilter { $Path -eq 'E:\BenTechSetup.cmd' }; $script:newState.Launcher.VolumeSerial | Should -Be '1A2B3C4D' } finally { Remove-Item Env:\BT_SELF }
  Mock Read-RunState { New-FakeState }; Invoke-Entry -Resume $true | Out-Null; Should -Invoke Get-LauncherInfo -Times 1 -Exactly
}
It 'a finished run cleans up after the lock is released and the transcript stopped' {
  $script:order = New-Object System.Collections.ArrayList
  Mock Exit-RunLock { [void]$script:order.Add('unlock') }; Mock Stop-Transcript { [void]$script:order.Add('transcript') }
  Mock Invoke-SetupCleanup { [void]$script:order.Add("cleanup $Mode"); $script:cleanState = $State }
  Invoke-Entry | Out-Null
  $order.IndexOf('cleanup Finish') | Should -BeGreaterThan $order.IndexOf('unlock'); $order.IndexOf('cleanup Finish') | Should -BeGreaterThan $order.IndexOf('transcript')
  $cleanState.RunId | Should -Be 'new-run'
}
It 'Escape with no earlier run cleans up (Cancel); after an unfinished earlier run it keeps the folder' {
  Mock Show-StartScreen { $null }; Invoke-Entry | Out-Null; Should -Invoke Invoke-SetupCleanup -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Cancel' }
  Mock Read-RunState { New-FakeState }; Invoke-Entry | Out-Null; Should -Invoke Invoke-SetupCleanup -Times 1 -Exactly
}
It 'a crash, a restart or a held lock cleans nothing' {
  Mock Invoke-SetupRun { throw 'boom' }; Invoke-Entry | Out-Null
  Mock Invoke-SetupRun { 'Rebooting' }; Invoke-Entry | Out-Null
  Mock Enter-RunLock { $false }; Invoke-Entry | Out-Null
  Should -Invoke Invoke-SetupCleanup -Times 0 -Exactly
}
```

- [ ] **Step 2: Run** `tests\Cleanup.Tests.ps1`, `tests\Screens.Tests.ps1`, `tests\Entry.Tests.ps1`, `tests\Waits.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** per the Interfaces; add `Entry\Cleanup.ps1` to `$BundleOrder`. Re-save with BOM. **Never call `Invoke-SetupCleanup` or `Remove-SetupFolder` on a real path; never run `setup.ps1`.**
- [ ] **Step 4: Run** the four files, then the full suite. Expected: `Failed: 0`. Then confirm the launcher guard from Task 1 is still green (the launcher is untouched).
- [ ] **Step 5: Commit:** `feat: save the logs to the USB stick and leave no folder behind`.

---

### Task 16: Docs and the publish dry run

**Files:**
- Modify: `docs/testing.md`, `docs/spikes.md`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: `docs/testing.md`** (spec §7, §9 and §10, plus what only mocks proved in Tasks 2-15):
  - **§9 fixes (ship with Tasks 2-4):** the YELLOW final screen readable (Black on Yellow) in a `powershell.exe` window with the default console profile, and GREEN/RED too; the report's `Windows` line has no `??`; Windows Update installs the Dell driver updates that ask for input; the `DriverClass` value of the Dell firmware updates, and firmware left alone on battery with the battery Note; the vendor-app `verify` values (Ben's Start-menu check, Spike 5 `-InventoryOnly`) and the Failed message when the app is missing; Chrome as default after the final restart within 120 s, and whether the policy is honoured on Windows 11 **Home**; the activation attempt on a machine with a key (`Windows not activated` gone, or the attempt in `setup.log`).
  - **§10 no leftover folder:** the stick found by serial (also under another letter) and by `BenTechSetup.cmd`; the live line follows plugging in and out; the copy to exFAT (`BenTech-Logs\<PC name>`, replaced on a re-run); deleting `C:\BenTech` while the final process still runs from `C:\BenTech\Setup\setup.ps1`; `C:\ProgramData\BenTech` gone when empty; the Desktop launcher deleted (and whether cmd.exe prints "The batch file cannot be found" when the launcher it is running is gone); a launcher on the stick never deleted; Esc on a fresh machine leaves nothing; a crash leaves everything.
  - **Screen:** rendering, colours (all on Black) and resizing in conhost and in Windows Terminal; readable from a metre away; no flicker and no scrolling over a 30-minute step; the spinner and timers move every second during WU round 1, a vendor pass and the Office restart wait; the reboot countdown still readable over the frame; the transcript holds no redraws (the final screen's one-second redraw included).
  - **Start screen:** 30 s countdown, any key (also an unknown one) restarts it, colours, the not-fresh text.
  - **Activity feed:** JUST HAPPENED survives a restart; a new run archives `activity-<RunId>.txt`; the AnyDesk ID is in `activity.txt` and never in `setup.log`.
  - **Windows Update:** English titles via `UserLocale` on Hebrew Windows (the Dell's round 1 had a Hebrew Defender title); one at a time vs batch on a fresh Windows 11 with 10 or more updates: same end state, time difference noted (flip `windowsUpdate.installMode` to `Batch` for the comparison run).
  - **Office:** the ODT `ExcludeApp` IDs accepted (drop any that ODT rejects); the background install while WU round 1 and a vendor pass run; a restart waiting for Office; a forced restart mid-install, then the foreground retry; the four shortcuts on the public desktop, also for an already-installed Office; a hidden ODT console never shows.
  - **Downloads:** a slow line keeps the screen alive; the 30-minute download deadline.
  - **Driver passes:** the Dell `dcu-pass<N>.log` last line in NOW (the format in `D:\Setup\Logs\dcu-pass1.log` is `[yyyy-MM-dd HH:mm:ss] : <text>`); whether Lenovo's and HP's newest `*.log` give a useful line.
- [ ] **Step 2: `docs/spikes.md`:** under Spike 4 add the v2 question "does `-action LIST` through `AdminCommandLine` leave the `-exporttowmi` install records alone?" (the spike already records `LenovoUpdatesBefore` and `LenovoUpdates`; compare them). Spike 5 exists from Task 1; add that its `-InventoryOnly` run after setup supplies the §9.3 `verify` values.
- [ ] **Step 3: `README.md`** "Daily use": the new start screen (what each line means, 30 s, any key restarts the countdown, colours) and the progress screen (checklist markers and colours, `(bg)` for Microsoft 365, NOW with the time against its limit, JUST HAPPENED, the spinner as the sign of life); the final screen: **Enter finishes** (other keys do nothing; B and R as before), the USB-stick line, and what happens on Enter: the logs go to `<stick>\BenTech-Logs\<PC name>\`, a Desktop launcher is deleted, and **no `C:\BenTech` folder is left**; Esc on a fresh machine leaves nothing; a crash leaves everything for diagnosis; `Previous run:` only appears after an unfinished run. "What the colours mean": YELLOW is black text on yellow. "Where things are": during a run as before plus `Logs\activity.txt` and `Logs\wu-round<N>.progress.json`; after a run, the stick's `BenTech-Logs` folder. "What it does": the Office shortcuts, the five Office apps, the vendor-app check. "Changing apps and lists": the optional `consumerApp.verify` entry.
- [ ] **Step 4: `CLAUDE.md`:** the step order with `office` after `vendor-pass1` and `office-finish` after `windows-update`; the Office background process as the one `Invoke-External` exception; the colour rule (no `DarkYellow`/`DarkMagenta`, explicit foreground and background on every screen line, `tests\Colors.Tests.ps1`); the tick rules (step code never calls `Start-Sleep`, uses `Wait-SetupDelay`; the tick never throws and never runs in `-WuRound`; screens draw through the console writer, never `Write-Host`); `Add-SetupActivity` for facts, never the AnyDesk ID in `setup.log`; `config.windowsUpdate.installMode` and `consumerApp.verify`; `C:\BenTech` is deleted only by `Remove-SetupFolder` (`rd` through `Invoke-External`, after Enter or a clean Esc, never after a crash), and tests never delete outside `$TestDrive` (`Invoke-SetupCleanup` is mocked in `Entry.Tests`).
- [ ] **Step 5: Verify.**
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` -> last line `Failed: 0`.
  - `git diff --quiet main -- launcher keys; $LASTEXITCODE` -> `0` (launcher template, public key and launcher hash untouched).
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.20.1 -DryRun` -> it prints `Launcher SHA-256: 702c323aff5e813d7264375d15387d3bcdc12baded3d192f4bc47890663b69ff`, no `WARNING: the launcher changed`, and ends with `DRY RUN: nothing was published.` Afterwards `git status --short keys` prints nothing. (Uncommitted or unpushed work only produces warnings under `-DryRun`.)
  - **Never** run `Publish.ps1` without `-DryRun`, `gh`, or `git push`: that is Ben's call.
- [ ] **Step 6: Commit:** `docs: v2 screens, Office in the background, no leftover folder, real-machine checks`. Then tell Ben what is ready for a VM test (docs/testing.md) and that Spike 5 is waiting for a Dell and an HP.

---

## Spec coverage (self-review)

| Spec | Task |
|---|---|
| §4.1 start screen | 8 |
| §4.2 progress screen, sizing, no flicker | 7 (screen), 9 (wiring, resize) |
| §4.3 tick in Invoke-External, waits, downloads | 5, 6 |
| §4.4 activity feed, AnyDesk rule, runner + step lines | 5, 9, 10, 12, 13, 14 |
| §4.5 drivers under order A: log line + timer + summaries | 10 (lists deferred: Task 1 capture) |
| §4.5 Windows Update: progress file, one at a time, switch, en-US | 11, 12 |
| §4.6 Office: excludeApps, split, restart wait, result across restarts | 13 |
| §4.7 shortcuts | 14 |
| §4.8 report: Windows updates installed | 12 (Driver updates: with the lists, later) |
| §5 launcher unchanged | 1 (test), 15 (BT_SELF only read), 16 (verification) |
| §7 real-machine items | 1 (Dell/HP capture), 16 (testing.md, spikes.md) |
| §9.1 final-screen colours, explicit fg + bg | 2 (rule, scan), 7 (frame writer), 15 (final screen via the frame writer) |
| §9.2 WU drivers with user input; firmware on AC only | 3 (and 11 keeps it in the per-update loop) |
| §9.3 vendor-app verify | 4 (values: Task 1 inventory + Ben's check) |
| §9.4 Chrome default: 120 s wait before removing the policy | 4 (ticking from Task 6) |
| §9.5 direction marks; activation attempt | 2; 4 |
| §9 ships alone | 4 Step 6 release checkpoint |
| §10 launcher record, stick, Enter, copy, Desktop launcher, rd, Esc, crash | 15 |
