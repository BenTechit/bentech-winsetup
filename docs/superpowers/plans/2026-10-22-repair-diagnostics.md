# bentech-winsetup: Repair & diagnostics (BenTech Toolbox step 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second page in the BenTech Toolbox window, "Repair & diagnostics": a safety strip, ten action tiles (health check, repairs, resets, reports), confirmations in the window, and a live run panel. Each action runs in a hidden, deadline-bound child of the same signed `setup.ps1`, judges only exit codes, enums, CIM, the registry and English CBS.log, and writes its logs and reports straight to the BenTech stick, with a privacy-safe copy for an AI chat.

**Architecture:**
- **One child per action (spec 7).** The window starts `powershell.exe -File <setup.ps1> -ToolAction <id> -ToolArgs <args.json>` through `Start-BackgroundExternal` (no wait) and polls `progress.json` every 500 ms with a DispatcherTimer. The child runs a list of steps (`Invoke-ToolSteps`): every native tool through `Invoke-External` with a per-step timeout, every hang-prone cmdlet in a bounded grandchild (`Invoke-ToolJsonChild`, built on `Invoke-PowerShellChild`), Stop and the deadline checked only between steps. It writes `result.json` at the end; the window kills the tree at the deadline.
- **Engine first, window second (spec 12).** Tasks 1-2 build the child side and the read-only Health check without any window. Task 3 is the page's look (pure model + XAML + strings + PNGs) and ends in a **HARD STOP** for Ben. Tasks 4-5 wire the runs, the close guard, the safety strip, the gates and the confirmations. Tasks 6-7 add the repairs, Tasks 8-9 the reports, the SAFE copy, Compare and the docs.
- **The window stays as it is built.** The page is more XAML in `Xaml.ps1`, a pure model in `RepairPlanner.ps1` and a view plus run handling in `RepairPage.ps1`; every handler still goes through `Invoke-ToolboxAction`. `Get-SetupChoices` keeps its contract; Restart PC is a fourth outcome that returns `$null` and leaves a request `Main.ps1` performs after its Cancel path.

**Tech Stack:** Windows PowerShell 5.1; WPF from .NET Framework 4.8; Windows' own modules, only inside child processes: Storage (`Repair-Volume`, `Get-PhysicalDisk`, `Get-StorageReliabilityCounter`, `Optimize-Volume`), DISM (`Repair-WindowsImage`, `Get-WindowsImage`, `Get-WindowsDriver`), PnpDevice, NetTCPIP, NetAdapter, DnsClient, BitsTransfer, Defender, PrintManagement; CIM (`root\wmi` BcdStore, `Win32_EncryptableVolume`, `Win32_Volume`); native `dism.exe`, `sfc.exe`, `w32tm.exe`, `reagentc.exe`, `fsutil.exe`, `chkntfs.exe`, `netsh.exe`, `ipconfig.exe`, `pnputil.exe`, `sc.exe`, `msinfo32.exe`, `wevtutil.exe`, `powercfg.exe`, `gpresult.exe`. Pester 5.5+ on the dev PC only.

**Spec:** `docs/specs/2026-10-22-repair-diagnostics-design.md` (binding, approved 22/10/2026 with its 23 calls). It amends `docs/specs/2026-10-21-toolbox-design.md`, which with the v1, v2, Craft and ScreenConnect specs stays binding elsewhere. These travel with this plan and still apply:
- the Global Constraints of `docs/superpowers/plans/2026-10-21-toolbox.md` (and through it the earlier plans');
- the ledger rulings in `.superpowers/sdd/*/progress.md` (do not undo any; especially V2-R13 deletion safety, TB-R6 Xaml.ps1, TB-R7 the wheel, TB-R8 the console fallback waits for Enter);
- the source material: Ben's old kit `Downloads\BenTech-Toolkit\BenTech-Toolkit\BenTech-Toolkit.ps1` (its repair order, OEM list, report sections; not its code) and the review `toolkit-review.md` (its bug list is what the tests below pin).

## Global Constraints

**Platform and safety**
- Windows PowerShell **5.1 only**; nothing installed, no module imported by name outside a child process.
- **Never run on this PC:** `setup.ps1`, the launcher, `Publish.ps1` (not even `-DryRun`), the old kit, or any repair or diagnostic tool (`dism`, `sfc`, `chkdsk`, `reagentc`, `netsh`, `pnputil`, `fsutil`, `chkntfs`, `w32tm`, `sc`, `msinfo32`). **No test runs a repair tool, changes the network, removes a device, schedules a disk check, restarts, touches a service, or starts a real child process.** Every test file under this plan mocks `Invoke-External`, `Invoke-PowerShellChild`, `Invoke-ToolJsonChild`, `Start-BackgroundExternal`, `Stop-ProcessTree`, CIM, the registry, `Get-WinEvent` and the Storage/DISM/Net cmdlets it reaches, and adds **safety-net mocks that throw** for `Start-Process`, `Restart-Computer`, `Stop-Service`, `Start-Service`, `Rename-Item`, `Remove-BitsTransfer`, `Set-NetIPInterface`, `New-NetIPAddress`, `Set-DnsClientServerAddress`, `Optimize-Volume`, `Repair-Volume`, `Repair-WindowsImage`, `Set-ItemProperty`, `New-ItemProperty`, `Remove-ItemProperty` (each records its name in `$script:blocked`, then throws) unless a test replaces one with a recorder. Files the tests write go under `$TestDrive` only.
- **No test opens a window or stops WPF** (toolbox rule, unchanged): `ShowDialog()` and `Dispatcher.InvokeShutdown()` appear only as seam defaults.
- **Outward-facing actions need Ben's explicit OK at that moment.** Never `git push`, never any `gh` command.
- **The launcher must not change:** `launcher\BenTechSetup.template.cmd` and `keys\public-key.xml` are not edited; `keys\launcher.sha256` stays `702c323aff5e813d7264375d15387d3bcdc12baded3d192f4bc47890663b69ff`. **`src\Entry\Param.ps1` changes exactly once** (Task 1, spec 10): it gains `[string]$ToolAction, [string]$ToolArgs`.

**Runtime rules (spec 6, 7, 10)**
- **Child processes:** every native tool runs through `Invoke-External` with a timeout from `config.timeoutsMinutes.toolStep`. **Two named exceptions** to "every child goes through `Invoke-External`": the Office background process (unchanged) and **the action child**, started by the window through `Start-BackgroundExternal`, its deadline (`timeoutsMinutes.tool.<id>`) enforced by the window's timer (spec 10). "Open folder" also starts `explorer.exe` through `Start-BackgroundExternal` and never waits for it (**Plan call**).
- **Hang-prone cmdlets** (`Repair-WindowsImage -CheckHealth/-ScanHealth/-StartComponentCleanup`, `Repair-Volume -Scan`, `Get-PhysicalDisk`, `Get-StorageReliabilityCounter`, `Get-Printer`, `Get-WindowsDriver`, and every PnpDevice/NetTCPIP/BitsTransfer/Defender cmdlet a step uses) run only in a bounded grandchild through `Invoke-ToolJsonChild`. **The window's thread never calls any of them** (Review Focus 1).
- **Never parse localized output.** Decisions come from exit codes (DISM's HRESULT is its exit code), enums (`ImageHealthState`, `Repair-Volume`'s result, `ServiceControllerStatus`, `StartType`), CIM, the registry, event provider + ID + `Properties`, SIDs, and CBS.log (always English). **The one display-only read** of tool text is DISM's percent from its redirected output; no decision depends on it. The repair code never uses `-CaptureOutput` (Task 1 static test).
- **Nothing waits without a deadline; nothing prompts.** Child code calls `Wait-SetupDelay`, never `Start-Sleep` (`tests\Waits.Tests.ps1` list unchanged); the window never sleeps or waits. No `Read-Host`, no `Write-Host` in `src\Repair` and `src\Toolbox` (the only new `Write-Host` is the restart-failed line in `Invoke-StatelessRestart`, White on DarkRed).
- **Stop works only between steps** (spec 4.3): DISM, SFC and the disk scan are killed only by their own timeout or the action deadline.
- **`try` blocks:** `$ErrorActionPreference` stays `Continue`; guarded cmdlets inside a `try` carry `-ErrorAction Stop` (`tests\ErrorAction.Tests.ps1`); a failing cmdlet is mocked with `Write-Error`, never `throw`.
- **Nothing on the stick is followed through a link** (V2-R13): `BenTech-Reports`, a session folder or a file named there that is a reparse point is never written through; the child falls back to the local folder with the `sessionLink` finding. Nothing is deleted with `Remove-Item -Recurse`. The repairs delete nothing: the Windows Update reset **renames**.

**Text, language and colour**
- `setup.log`, the child's log, `progress.json`, `result.json`, the console: **English and ASCII** (`ConvertTo-ScreenText` on every free value). Finding texts are English; the window shows `finding.<Code>` from the string table in its language.
- **`src\Toolbox\Strings.ps1` stays the only non-ASCII `src` file.** The Hebrew YES (`טקד`) is written as code points `0x05D8, 0x05E7, 0x05D3` in `RepairPlanner.ps1` (**Plan call**).
- **Diagnostic reports on the stick are UTF-8** and may hold Hebrew data (event messages, program names, the customer complaint); their headings, facts names and flags are English (spec 6.8, 10). Report dates `dd/MM/yyyy HH:mm` through `Format-ReportDate` (invariant culture, Gregorian).
- Colours are hex values inside the one `<Window.Resources>` dictionary; `DarkYellow` / `DarkMagenta` never appear in `src`.

**WPF rules (toolbox spec 5.1, unchanged)**
- Every handler is one line through `Invoke-ToolboxAction`, which never throws; window state lives in `$window.Tag`; every .NET call's output goes to `$null`.
- **Script-scope exceptions** to "no outer variables" (none is read by a handler): `$script:ToolboxOpenWindow` (exists), `$script:ToolboxChildren` (the processes the window started, so `Get-SetupChoices`' `finally` can kill them after the window is gone) and `$script:ToolboxRestartRequested` (**Plan call**, both).
- A disabled button still runs its Click handler when the event is raised in code, so every action re-checks its gate.

**Values the spec pins** (copy them exactly)
- YES: `YES` in any case, or `טקד` (spec 4.2).
- Internet: TCP 443 to `www.msftconnecttest.com`, then HTTPS `https://www.msftconnecttest.com/connecttest.txt`, 5 s each (spec 5).
- Free space: under 10% or under 15 GB is red (spec 5). Clock: more than 2 minutes off after the sync is a WARN with "downloads may fail" (spec 6.2).
- Disk events: System, provider `disk` IDs 7, 51, 153, and NTFS ID 55, last 30 days (spec 5).
- Pending servicing restart: CBS `RebootPending`, CBS `PackagesPending`, `%windir%\WinSxS\pending.xml`, WU `RebootRequired`; a pending file rename or computer rename is a grey note only (spec 5).
- DISM: `dism.exe /Online /Cleanup-Image /RestoreHealth`, retry `... /Source:<wim|esd>:<path>:<index> /LimitAccess` only when picked (spec 6.2). `Repair-WindowsImage -Online -StartComponentCleanup`, never `/ResetBase` (spec 6.3).
- Disk check: `fsutil dirty set <system drive>`, confirmed by `Win32_Volume.DirtyBitSet`. **No Cancel and no `chkntfs` at all** (ruling RD-R1, below).
- Network: `netsh winsock reset`, `netsh int ip reset`, `netsh int ipv6 reset`, flush DNS; **no `/release`, no `/renew`** (spec 6.6).
- Ghosts: leave out `BTHENUM\`, `BTHLE\`, `BTHLEDEVICE\`, `BTHHFENUM\`, children of any Bluetooth parent, printers and print queues, WSD and IPP devices, `SWD\MMDEVAPI\`; remove with `pnputil /remove-device` (spec 6.7).
- Restart: `Restart-Computer -Force`, fallback `shutdown.exe /r /t 5 /f` (spec 6.9).
- Reports: `BenTech-Reports\<PC>_<serial>_<yyyy-MM-dd_HHmm>\`, `REPORT_<PC>_<date>.txt` under 150 KB, **`REPORT_SAFE_<yyyy-MM-dd_HHmm>.txt`** and **`COMPARE_SAFE_<yyyy-MM-dd_HHmm>.txt`** (no PC name in a SAFE file name: ruling RD-R4), tokens like `user1`, `PC-1` (spec 6.8, 8).
- The window polls every 500 ms (spec 7).

**Controller rulings (22/10/2026). They override any plan text below that says otherwise.**
- **RD-R1: no "Cancel scheduled disk check".** `chkntfs /x` excludes the drive from **every later** start-up check until `chkntfs /d`, which would silently switch off a Windows safety check on the customer's PC.
  - The Disk check confirmation says "It runs at the next start and cannot be cancelled from the toolbox".
  - There is no `diskCheckCancel` action, button or finding, and no `diskCheckExclusionCleared` (`chkntfs /d`) step.
  - No `chkntfs` call anywhere; a static test pins that.
  - Spec 6.5 and section 13 call 17 are amended to match.
- **RD-R2: Network reset always asks for the at-PC tick** ("I am at this PC, not connected remotely"), whatever is detected.
  - Only RDP is detected (`TerminalServerSession`), and only to make the warning red.
  - AnyDesk and ScreenConnect are **not** read as "connected": their clients run on every PC Ben sets up, and "running" is not "connected".
- **RD-R3: the periodic stick re-check uses `[IO.DriveInfo]::GetDrives()`.** It looks at Removable and Fixed drives other than the system drive with `BenTechSetup.cmd` in the root, and skips Network and CD-ROM drives. There is no CIM call on the window's thread. The full `Find-SetupStick` (volume serial) runs once when the page opens, and when the presence check sees a change.
- **RD-R4: SAFE file names hold no PC name:** `REPORT_SAFE_<stamp>.txt` and `COMPARE_SAFE_<stamp>.txt`. The folder name still holds the PC and serial, on the stick only.
- **RD-R5: Restart PC copies nothing extra.** The action logs and reports are already on the stick (spec 7). Restart = Cancel's path plus a stateless restart. Spec 6.9 step 2 is amended.
- **RD-R6: the session folder is spec 8's** `<PC>_<serial>_<stamp>`; spec 7 is amended to match.

**Files, tests, commits**
- Every `.ps1` is UTF-8 **with BOM**; after writing, re-save: `powershell -NoProfile -Command "Get-ChildItem -Recurse -Include *.ps1 src,tests,tools | % { $t=[IO.File]::ReadAllText($_.FullName); [IO.File]::WriteAllText($_.FullName,$t,(New-Object Text.UTF8Encoding $true)) }"`.
- **Test command:** `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` (or one file). **Pass = the last line reads `Failed: 0`.** Today 2646 tests pass (about 7 minutes). Every task ends with the full suite green.
- A new `src` file gets its `$BundleOrder` entry **in the task that creates it**.
- **Commits:** a review gate before every commit (Ben's rule). Conventional commits, each with a second `-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Branch `feat/repair-tool`.

## Review Focus

The five real-world failure modes the spec implies that the tests could most easily miss, most likely first. Each names the test that pins it and its task.

1. **A hung cmdlet freezing the window** (a failing disk under `Get-PhysicalDisk`, a stuck spooler under `Get-Printer`, a wedged WMI).
   - Expected: the window never calls a hang-prone cmdlet or waits on a process; a safety child that never answers is killed at its deadline, the chips it did not finish read "unknown" (yellow) and block nothing.
   - Tests: Task 4 `'the window''s files call no hang-prone cmdlet and never wait on a process (Review Focus 1)'`; Task 5 `'a safety child that never finishes is killed at its deadline; its missing chips are unknown and block nothing (Review Focus 1)'`.
2. **`C:\BenTech` deleted under a running child** (the window fails mid-repair and the Cancel cleanup runs `rd` while DISM writes into `C:\BenTech\Setup\Tool`).
   - Expected: X, Alt+F4 and Cancel are refused while an action runs; a Failed outcome kills every child's process tree **before** the dispatcher shutdown, the console fallback and any cleanup.
   - Tests: Task 4 `'a window that fails while a child runs kills it before the shutdown, the console and the cleanup (Review Focus 2)'` and `'X, Alt+F4 and Cancel are refused while an action runs'`.
3. **A destructive action without its backup on the stick** (stick pulled, read-only, or a link).
   - Expected: no stick disables Network reset and Ghost devices; a network backup that cannot be written **and read back equal** runs no `netsh` at all; a device list that cannot be saved removes nothing.
   - Tests: Task 5 `'Network reset and Ghost devices are disabled without a stick (Review Focus 3)'`; Task 7 `'no verified backup, no reset: nothing after the backup step runs (Review Focus 3)'` and `'a device list that cannot be saved removes nothing (Review Focus 3)'`.
4. **Hebrew output parsed somewhere** (a verdict that reads English words from a tool, as the old kit's WinRE and DISM checks did).
   - Expected: no repair file captures tool output; every text file the repair code reads is on an allow-list (DISM output for the percent, CBS.log, ReAgent.xml, its own JSON files, the English servicing logs condensed for the report); a Hebrew DISM output only moves the percent.
   - Tests: Task 1 `'the repair code captures no tool output and reads only the files on its allow-list (Review Focus 4)'`; Task 2 `'Health check verdicts come from enums, exit codes and English CBS.log; Hebrew tool text changes nothing (Review Focus 4)'`.
5. **The SAFE copy leaking an identifier** (a serial inside the PC name, a MAC with dashes, a Hebrew user name in a profile path, a phone number in the complaint).
   - Expected: every identifier the report was built from, and every e-mail, MAC, IP, phone number and profile path the patterns find, is replaced by a stable token; the same value gets the same token everywhere.
   - Test: Task 9 `'the SAFE copy holds none of the identifiers, in any case or spelling, and tokens are stable (Review Focus 5)'`.

---

## File Structure

```
src/Entry/Param.ps1              MOD  T1: + [string]$ToolAction, [string]$ToolArgs
src/Entry/Run.ps1                MOD  T1: passes -ToolAction / -ToolArgs
src/Entry/Main.ps1               MOD  T1: -ToolAction dispatch; T4: Root/ScriptPath to Get-SetupChoices, restart after cleanup
src/Engine/Reboot.ps1            MOD  T1: Get-ServicingRebootSignals, Test-ServicingRebootPending; T4: Invoke-StatelessRestart
src/Detect/PcName.ps1            MOD  T2: Test-PlaceholderSerial, Test-UsableBiosUuid, Get-MachineIdentity (New-PcName uses them)
src/Common/Process.ps1           MOD  T4: Start-BackgroundExternal's doc names its second caller
src/Repair/ToolEngine.ps1        NEW  T1: catalogs, the child entry, args/progress/result files, the step runner, native and grandchild runners
src/Repair/ToolChecks.ps1        NEW  T2: volume scan, image health, SFC from CBS.log, WinRE (BCD + ReAgent.xml), devices, activation; Health steps
src/Repair/ToolSafety.ps1        NEW  T2: the safety strip steps (restart, free space, BitLocker, internet, disk, disk-check state)
src/Repair/ToolRepairs.ps1       NEW  T6: time sync, DISM (+ source), SFC, WinRE fix, post-clone steps
src/Repair/ToolAdvanced.ps1      NEW  T7: WU reset, disk check (+ cancel), network info/backup/reset/restore, ghost devices
src/Repair/ToolCollect.ps1       NEW  T8: report sections 01-12 (collectors)
src/Repair/ToolReport.ps1        NEW  T8: flags, event grouping, the AI-ready core, raw\ and zip, the data JSON
src/Repair/ToolPrivacy.ps1       NEW  T9: SAFE masking
src/Repair/ToolCompare.ps1       NEW  T9: compare with last visit
src/Toolbox/RepairPlanner.ps1    NEW  T3: pure page model, strip, gates; T4: run/result merges; T5: Update-RepairModel, Test-RepairYes
src/Toolbox/RepairPage.ps1       NEW  T3: Update-RepairView; T4: runs, timer, Stop, children; T5: stick, Open folder
src/Toolbox/Xaml.ps1             MOD  T3: nav entry, page split, the repair page, new resources
src/Toolbox/Strings.ps1          MOD  T1-T9: page strings, step names, finding texts (en + he)
src/Toolbox/SetupPlanner.ps1     MOD  T3: model Page + Repair, Update-ToolboxModel 'Page'
src/Toolbox/Toolbox.ps1          MOD  T3: handlers on ButtonBase only, view calls; T4: close guard, Restart outcome, runs in the seam; T5: text/hover handlers, page actions
config/config.json               MOD  T1: timeoutsMinutes.tool / toolStep, repair section
tools/Build-Bundle.ps1           MOD  T1, T2, T3, T6, T7, T8, T9: $BundleOrder entries
tools/Preview-Toolbox.ps1        MOD  T3: seven repair views
tests/ToolEngine.Tests.ps1, RepairStatic.Tests.ps1                              NEW T1
tests/ToolChecks.Tests.ps1                                                      NEW T2
tests/RepairPlanner.Tests.ps1, RepairPage.Tests.ps1                             NEW T3 (extended T4, T5)
tests/ToolRepairs.Tests.ps1                                                     NEW T6
tests/ToolAdvanced.Tests.ps1                                                    NEW T7
tests/ToolReport.Tests.ps1                                                      NEW T8
tests/ToolPrivacy.Tests.ps1                                                     NEW T9
tests/fixtures/cbs-*.log, reagent-*.xml, dism-*.txt, netbackup-*.json, report-*.json   NEW T2, T6, T7, T8, T9
tests/Bundle, Entry, Config, Detection, Toolbox, SetupPlanner .Tests.ps1        MOD
README.md, docs/testing.md, CLAUDE.md, docs/specs/2026-10-21-toolbox-design.md  MOD T9
```

**Bundle order** (`$BundleOrder`): the nine `Repair\*.ps1` right after `'Report\Report.ps1'`, in the order above; `'Toolbox\RepairPlanner.ps1'` right after `'Toolbox\SetupPlanner.ps1'`; `'Toolbox\RepairPage.ps1'` right after `'Toolbox\Toolbox.ps1'`.

**Plan calls on placement:**
- `Get-ServicingRebootSignals` lives in `Reboot.ps1` beside `Get-PendingRebootSignals` (it reuses `Test-RebootRegistryKey`); the engine's own signals are unchanged.
- The identity helpers live in `PcName.ps1`: "the same PC" must use exactly `New-PcName`'s placeholder rule (spec 6.8), so the rule moves into `Test-PlaceholderSerial` and both call it.
- The repair page's XAML goes into `Xaml.ps1`'s one here-string: a separately parsed fragment could not use the window's `StaticResource`s, and the one-dictionary rule stays.
- Each catalog (`$script:ToolActionCatalog`, `$script:ToolSteps`) is **one literal in `ToolEngine.ps1`**; every task adds its rows there.

## Shared shapes

### config.json additions (Task 1)

Merged into the existing sections. **Plan call:** `repair` is not a required key of `Read-SetupConfig` (every reader falls back to the values below when a key is missing), so synthetic test configs stay valid.

```json
"timeoutsMinutes": { ...,
  "tool": { "safety": 3, "health": 150, "standard": 300, "postClone": 420, "dismSource": 240, "wuReset": 30,
            "diskCheck": 5, "netInfo": 3, "netReset": 15, "netRestore": 10,
            "ghostList": 10, "ghostRemove": 30, "quickReport": 10, "fullReport": 45, "compare": 10 },
  "toolStep": { "native": 3, "grandchild": 3, "volumeScan": 60, "imageCheck": 15, "imageScan": 60, "dism": 150,
                "sfc": 90, "timeSync": 3, "pnpScan": 5, "componentCleanup": 90, "retrim": 30, "wuScan": 15,
                "service": 2, "pnputil": 2, "ghostList": 8, "drivers": 10, "printers": 1, "events": 5,
                "msinfo32": 4, "wuLog": 5 } },
"repair": {
  "internet": { "host": "www.msftconnecttest.com", "url": "https://www.msftconnecttest.com/connecttest.txt", "seconds": 5 },
  "freeSpace": { "minPercent": 10, "minGB": 15 },
  "reportMaxKB": 150,
  "thresholds": { "clockOffsetMinutes": 2, "diskWearPercent": 80, "diskTemperatureC": 60, "diskEventDays": 30,
                  "crashDays": 60, "kernelPowerWarn": 3, "appCrashesWarn": 10, "defenderSignatureDays": 7,
                  "batteryWearPercent": 40, "ramMinGB": 8, "ghostDevicesInfo": 150, "eventDays": 14,
                  "quickEventDays": 7, "uptimeDays": 7 },
  "oemUtilities": {
    "DELL": ["Dell SupportAssist*", "Dell Command*", "Dell Update*", "Dell Digital Delivery*", "Dell Optimizer*"],
    "HP": ["HP Support Assistant*", "HP Sure*", "HP Wolf*", "HP Notifications*", "HP Connection Optimizer*", "HP System Event Utility*"],
    "LENOVO": ["Lenovo Vantage*", "Lenovo System Update*", "Lenovo Commercial Vantage*", "Lenovo Now*"],
    "ASUS": ["MyASUS*", "ASUS System Control Interface*", "Armoury Crate*"],
    "ACER": ["Acer Care Center*", "Acer Jumpstart*", "Acer Quick Access*"],
    "MSI": ["MSI Center*", "Dragon Center*"] } }
```
- **Plan calls:** the deadlines and step timeouts are mine (generous: a hung tool ends, a slow healthy one finishes); `clockOffsetMinutes` 2 is spec 6.2's and also drives the report's clock flag; the other thresholds are the kit's (review section 4 corrected: wear is a WARN, RAM is the module sum); `oemUtilities` names **system utilities only**, never printer or peripheral software (review I-9).
- A step's timeout is `toolStep.<name>`, else `toolStep.native`, else 3, **capped at the action's remaining time minus 0.5 min** (at least 0.25), so the child stops before the window's kill (**Plan call**).

### Actions and steps (`ToolEngine.ps1`, rows added by the task named)

| Action | Kind | Confirm | Stick | Logs | Steps, in order (`*` = servicing: re-checked for a pending servicing restart first) | Task |
|---|---|---|---|---|---|---|
| `safety` | info | none | no | local | `safetyRestart`, `safetyFree`, `safetyBitLocker`, `safetyInternet`, `safetyDisk`, `safetyDiskCheck`; + `safetyNetBackup` (T7), `safetyEarlier` (T9) | 2 |
| `health` | readonly | none | no | session | `volumeScan`, `imageCheck`, `imageScan`, `sfcVerify`, `winre`, `devices`, `activation` | 2 |
| `standard` | repair | confirm | no | session | `timeSync`, `volumeScan`, `dism`*, `sfc`*, `winreFix` | 6 |
| `postClone` | repair | confirm | no | session | standard's five, then `pnpScan`, `devices`, `oemLeftovers`, `pageFile`, `trim`, `activation`, `componentCleanup`*, `wuScan` | 6 |
| `dismSource` | repair | confirm | no | session | `dismSource`*, `sfc`* | 6 |
| `wuReset` | destructive | yes | no | session | `wuServicesStop`, `wuRename`, `wuBits`, `wuServicesStart`, `wuScan` | 7 |
| `diskCheck` | destructive | yes | no | session | `diskCheckSchedule` | 7 |
| `netInfo` | info | none | no | local | `netInfo` | 7 |
| `netReset` | destructive | yes | yes | session | `netBackup`, `winsockReset`, `ipReset`, `ipv6Reset`, `dnsFlush` | 7 |
| `netRestore` | destructive | yes | yes | session | `netRestore` | 7 |
| `ghostList` | info | none | yes | local | `ghostList` | 7 |
| `ghostRemove` | destructive | yes | yes | session | `ghostCsv`, `ghostRemove` | 7 |
| `quickReport` | readonly | none | yes | session | `report01` ... `report11`, `reportWrite` | 8 |
| `fullReport` | readonly | none | yes | session | `report01` ... `report12`, `reportWrite`, `reportZip` | 8 |
| `compare` | readonly | none | yes | session | `report01` ... `report11`, `compare` | 9 |

- `$script:ToolActionCatalog` = ordered `@{ <id> = @{ Kind; Confirm; NeedsStick = <bool>; LogLocal = <bool>; Steps = [string[]] } }`; `$script:ToolSteps` = `@{ <stepId> = @{ Function = 'Invoke-ToolStep<Name>'; Servicing = <bool>; AlwaysRun = <bool, optional, Task 7> } }`. Step function names are the step id with its first letter upper-cased (`dism` -> `Invoke-ToolStepDism`, `winreFix` -> `Invoke-ToolStepWinreFix`, `report01` -> `Invoke-ToolStepReport01`).
- **"Logs local"** (info children): the log goes to the run folder under `C:\BenTech\Setup\Tool`, so opening the page leaves no folder on the stick (**Plan call**). Every other action logs to `<session>\logs\setup.log` (spec 7, 8).
- A step function takes `-Run <hashtable>` and returns `'done'`, `'warn'`, `'failed'` or `'skipped'`; findings go through `Add-ToolFinding`; shared data goes into `$Run.Data`. A step that throws is `'failed'` with `stepFailed`, and the runner goes on (**Plan call**: DISM failing must not stop SFC, as in the kit).

### The files of one run (Task 1)

The window creates `<Root>\Tool\<RunId>\` (`C:\BenTech\Setup\Tool\...`, admin-only) and writes `args.json` there; the child derives `progress.json`, `result.json` and `stop.flag` from that folder, never from the args (**Plan call**: progress and results never live on the writable stick). All JSON is UTF-8 without BOM, written to `<file>.tmp` then `[IO.File]::Replace` (or `Move`), like `Update-WuProgress`.

```
args.json   @{ Version = 1; Action; RunId ('yyyyMMdd-HHmmss-<action>', invariant); DeadlineUtc (ISO 'o');
               SessionDir (<stick>\BenTech-Reports\<name> | <Root>\Logs\Repair\<name>); StickRoot ('' | 'E:\');
               Complaint (<= 2000 chars, may be Hebrew); Done = @( @{ Action; Outcome; Color; EndedAt } );
               Identity = @{ Key; FolderPart; Serial; BiosUuid; ComputerName; Manufacturer; Model; Brand };
               Machine = @{ IsLaptop; OsBuild; Arch }; Strip = @{ Restart; Disk; Internet; Free; BitLocker } (levels);
               Options = @{ ... per action } }
progress    @{ Action; RunId; State = 'running'|'done'; Current = <index, -1 none>;
               Steps = @( @{ Id; Status = 'pending'|'running'|'done'|'warn'|'failed'|'skipped'|'timedout'; Percent = <double|$null> } );
               Log = @( <last 12 ASCII lines> ); Partial = @{ ... }; UpdatedAt }
result      @{ Action; RunId; Outcome = 'Done'|'Stopped'|'TimedOut'|'NeedsRestart'|'Failed'; Color = 'GREEN'|'YELLOW'|'RED';
               Steps; Findings = @( @{ Level = 'CRIT'|'WARN'|'INFO'; Code; Text (English ASCII); Args = [string[]] } );
               RestartRequired = <bool>; Offers = @{ DiskCheck = <bool>; DismSource = $null | @{ Path; Type; Index; Edition; Arch; Languages; Build; BuildDiffers; LanguageDiffers } };
               Files = @{ Folder; Log; ... }; Data = @{ ... per action }; StartedAt; EndedAt }
```
- **Colour:** RED for `TimedOut`, `Failed` or any CRIT; else YELLOW for `Stopped`, `NeedsRestart` or any WARN; else GREEN (**Plan call**: a Stop is yellow).
- **Session folder name:** `'{0}_{1}_{2}' -f <ComputerName>, <Identity.FolderPart>, <window open time 'yyyy-MM-dd_HHmm'>`, every part reduced to `[A-Za-z0-9-]` (spec 8's form, which holds the serial; spec 7's shorter form is superseded, see the spec points at the end). The window builds it; the child creates it with `New-ToolSessionDir`.
- **Identity** (`Get-MachineIdentity`, Task 2): a real serial gives `Key = 'SN-<serial upper, [A-Z0-9]>'` and `FolderPart` = that serial (right-most 20); a placeholder serial (`Test-PlaceholderSerial`, `New-PcName`'s rule) with a usable BIOS UUID gives `Key = 'UUID-<32 hex>'`, `FolderPart = 'UUID-<last 12 hex>'`; neither gives `Key = ''` (never compared) and `FolderPart = 'NOSERIAL'`.

### Findings (code, level, English text; `{n}` are `Args`)

Strings.ps1 holds `finding.<Code>` in `en` (exactly the text below) and `he`; the child formats the English one (`Get-ToolText`), the window the language's one. Each task adds its own rows, both languages.

| Code | Lvl | English | T |
|---|---|---|---|
| `stepFailed` | CRIT | `{0} failed: {1}` | 1 |
| `stepTimedOut` | CRIT | `{0} timed out after {1} min` | 1 |
| `stopped` | INFO | `Stopped after {0}` | 1 |
| `actionTimedOut` | CRIT | `The action reached its deadline ({0} min) and was stopped` | 1 |
| `restartFirst` | WARN | `A Windows servicing restart is pending: restart, then run it again` | 1 |
| `sessionLink` | WARN | `BenTech-Reports on the stick is a link: the files were kept in {0}` | 1 |
| `volumeSpotFix` | CRIT | `Disk scan found errors that need a disk check at restart` | 2 |
| `volumeFullRepair` | CRIT | `Disk scan found errors that need a full offline repair: back up first` | 2 |
| `volumeScanNeeded` | WARN | `Disk scan could not finish online: a full scan is needed` | 2 |
| `volumeUnknown` | WARN | `Disk scan gave no result ({0})` | 2 |
| `imageRepairable` | WARN | `The Windows image is corrupt but repairable: run Standard repair` | 2 |
| `imageNonRepairable` | CRIT | `The Windows image is corrupt and cannot be repaired online` | 2 |
| `imageUnknown` | WARN | `The Windows image check gave no result ({0})` | 2 |
| `sfcCorrupt` | WARN | `System files: {0} integrity problems found (nothing repaired yet)` | 2 |
| `sfcCannotRepair` | CRIT | `System files: {0} files could not be repaired` | 2 |
| `sfcNotRun` | WARN | `SFC left no result in CBS.log: restart, then run it again` | 2 |
| `sfcTimedOut` | WARN | `SFC timed out and may still run in the background: restart before running it again` | 2 |
| `winreOff` | WARN | `Windows Recovery (WinRE) is off` | 2 |
| `winreUnknown` | WARN | `WinRE: the boot configuration and ReAgent.xml disagree (often after a clone); nothing was changed` | 2 |
| `devicesProblem` | WARN | `{0} devices have a problem (codes {1})` | 2 |
| `devicesDisabled` | INFO | `{0} devices are disabled` | 2 |
| `devicesUnknown` | WARN | `The device list could not be read ({0})` | 2 |
| `notActivated` | WARN | `Windows is not activated` | 2 |
| `activationUnknown` | INFO | `Activation could not be read` | 2 |
| `childNoResult` | CRIT | `The action ended without a result (exit {0})` | 4 |
| `childStartFailed` | CRIT | `The action could not start: {0}` | 4 |
| `clockOff` | WARN | `The clock is still {0} min off after the time sync: downloads may fail` | 6 |
| `clockUnknown` | INFO | `The clock offset could not be measured (no internet)` | 6 |
| `timeServiceDisabled` | WARN | `The Windows Time service is disabled: the clock was not synced` | 6 |
| `timeSyncFailed` | WARN | `Time sync failed ({0})` | 6 |
| `dismRestart` | INFO | `DISM finished; a restart is needed` | 6 |
| `dismSourceMissing` | WARN | `DISM could not get repair files from Windows Update ({0})` | 6 |
| `dismNoSource` | INFO | `No install.wim or install.esd on the stick or a mounted ISO` | 6 |
| `dismFailed` | CRIT | `DISM RestoreHealth failed ({0})` | 6 |
| `sfcRepaired` | INFO | `SFC repaired files ({0} components); a second pass {1}` | 6 |
| `dismAndSfcFailed` | CRIT | `DISM failed and SFC could not repair: supply a matching install.wim, or plan an in-place upgrade` | 6 |
| `winreEnabled` | INFO | `WinRE was turned on` | 6 |
| `winreEnableFailed` | WARN | `reagentc /enable failed ({0}): Winre.wim may be missing` | 6 |
| `winreNoAgreement` | INFO | `WinRE is off but ReAgent.xml does not confirm it: not turned on` | 6 |
| `pnpScanFailed` | WARN | `The device rescan failed ({0})` | 6 |
| `oemLeftover` | WARN | `Software from another manufacturer: {0}` | 6 |
| `oemSkipped` | INFO | `Manufacturer unknown or a whitebox: the leftover check was skipped` | 6 |
| `pageFileMissingDrive` | WARN | `The page file is set on a missing drive ({0})` | 6 |
| `trimOff` | WARN | `TRIM is off (DisableDeleteNotification = {0})` | 6 |
| `retrimFailed` | WARN | `ReTrim failed ({0})` | 6 |
| `componentCleanupFailed` | WARN | `Component cleanup failed ({0})` | 6 |
| `updatesAvailable` | INFO | `{0} updates are available` | 6 |
| `wuScanFailed` | WARN | `The Windows Update scan failed ({0})` | 6 |
| `wuScanSkipped` | INFO | `No internet: the Windows Update scan was skipped` | 6 |
| `wuServiceDisabled` | WARN | `{0} is disabled (start type): Windows Update cannot work` | 7 |
| `wuServiceStopFailed` | WARN | `{0} did not stop` | 7 |
| `wuServiceStartFailed` | CRIT | `{0} did not start again` | 7 |
| `wuRenamed` | INFO | `{0} renamed to {1}` | 7 |
| `wuRenameFailed` | WARN | `{0} could not be renamed (locked): restart, then run it again` | 7 |
| `wuBitsCleared` | INFO | `{0} Windows Update download jobs cleared` | 7 |
| `wuBitsFailed` | WARN | `The Windows Update download jobs could not be cleared ({0})` | 7 |
| `diskCheckScheduled` | INFO | `Disk check scheduled for the next start (it can take hours on a large HDD)` | 7 |
| `diskCheckNotScheduled` | CRIT | `The disk check could not be scheduled ({0})` | 7 |
| `netBackupSaved` | INFO | `Network settings saved to {0}` | 7 |
| `netBackupFailed` | CRIT | `The network settings could not be saved and checked: nothing was reset` | 7 |
| `netResetStepFailed` | WARN | `{0} returned {1}` | 7 |
| `netRestored` | INFO | `Network settings restored on {0} adapters` | 7 |
| `netRestoreFailed` | WARN | `{0}: {1}` | 7 |
| `netRestoreRefused` | CRIT | `The backup file changed after it was shown: nothing was applied` | 7 |
| `netRestoreInvalid` | CRIT | `The backup file is not valid: nothing was applied` | 7 |
| `ghostCsvFailed` | CRIT | `The device list could not be saved: nothing was removed` | 7 |
| `ghostsRemoved` | INFO | `{0} devices removed` | 7 |
| `ghostRemoveFailed` | WARN | `{0} could not be removed ({1})` | 7 |
| `restartRequired` | INFO | `Restart the PC to finish` | 7 |
| `diskUnhealthy` | CRIT | `Disk {0}: health {1}` | 8 |
| `diskErrors` | CRIT | `Disk {0}: {1} uncorrected read/write errors` | 8 |
| `diskWear` | WARN | `Disk {0}: {1}% worn` | 8 |
| `diskTemp` | WARN | `Disk {0}: {1} C` | 8 |
| `diskEvents` | CRIT | `Disk events in {0} days: {1}` | 8 |
| `lowSpace` | WARN | `{0} {1} GB free ({2}%)` | 8 |
| `wheaFatal` | CRIT | `{0} fatal hardware errors (WHEA) in {1} days` | 8 |
| `wheaCorrected` | WARN | `{0} corrected hardware errors (WHEA) in {1} days` | 8 |
| `bugchecks` | CRIT | `{0} blue screens in {1} days (codes {2})` | 8 |
| `kernelPower` | WARN | `{0} unexpected power losses or hard resets in {1} days` | 8 |
| `minidumps` | WARN | `{0} crash dumps in {1} days` | 8 |
| `appCrashes` | WARN | `{0} application crashes in {1} days (most: {2})` | 8 |
| `wuDisabled` | WARN | `The Windows Update service is disabled` | 8 |
| `defenderOff` | CRIT | `Defender real-time protection is off and no other antivirus is active` | 8 |
| `defenderSignatureOld` | WARN | `Defender signatures are {0} days old` | 8 |
| `uacOff` | CRIT | `UAC is off (EnableLUA = 0)` | 8 |
| `guestEnabled` | WARN | `The Guest account is enabled` | 8 |
| `autoLogon` | WARN | `Automatic sign-in is configured` | 8 |
| `rdpNoNla` | WARN | `Remote Desktop is on without Network Level Authentication` | 8 |
| `smb1On` | WARN | `SMBv1 is on` | 8 |
| `userProxy` | WARN | `A user proxy is set: {0}` | 8 |
| `hostsEntries` | WARN | `The hosts file has {0} active entries` | 8 |
| `lowRam` | WARN | `{0} GB of RAM` | 8 |
| `windows10` | WARN | `Windows 10 (build {0}): out of support since 14/10/2025` | 8 |
| `uptimeLong` | INFO | `Up for {0} days: restart before judging stability` | 8 |
| `batteryWear` | WARN | `Battery {0}% worn` | 8 |
| `basicDisplay` | WARN | `No display driver (Microsoft Basic Display Adapter)` | 8 |
| `secureBootOff` | INFO | `Secure Boot is off` | 8 |
| `tpmMissing` | INFO | `No ready TPM` | 8 |
| `bitlockerOn` | INFO | `BitLocker is on: have the recovery key before BIOS or board work` | 8 |
| `safeBootSet` | WARN | `Safe boot is set in the boot configuration` | 8 |
| `ghostDevicesMany` | INFO | `{0} disconnected devices are registered` | 8 |
| `autoServicesStopped` | INFO | `{0} automatic services are not running: {1}` | 8 |
| `noInternet` | CRIT | `No internet (TCP 443 and HTTPS failed)` | 8 |
| `firewallOff` | WARN | `The firewall is off for: {0}` | 8 |
| `notCollected` | INFO | `{0}: not collected ({1})` | 8 |

Plan call: the codes, levels and texts are mine (spec 6.8 and the review's I-10 decide the levels: corrected WHEA is a WARN, CM 22 is not a problem, only listed disk event IDs count).

### Safety strip, chips and gates (Tasks 2, 3, 5)

The safety child's `Data.Chips` (also in `progress.Partial.Chips` as each chip finishes): `@{ Restart; Free; BitLocker; Internet; Disk }`, each `@{ Level = 'ok'|'warn'|'crit'|'unknown'; Args = [string[]]; Detail = @{...} }`, plus `Data.DiskCheck = @{ Dirty = <bool|$null>; Excluded = <bool> }`. Power and Stick are the window's.

| Chip | ok | warn | crit | unknown |
|---|---|---|---|---|
| Restart | no servicing signal (a file or computer rename adds a grey note) | | any servicing signal | read failed |
| Free (system drive) | | | under `minPercent` % or under `minGB` GB | read failed |
| BitLocker | protection off | protection on (the key reminder) | | read failed or timed out |
| Internet | TCP and HTTPS answered | | either failed | the step timed out |
| Disk | | wear >= `diskWearPercent` or temperature >= `diskTemperatureC` | a disk not Healthy, uncorrected errors > 0, or any listed disk event in `diskEventDays` | a grandchild failed or timed out |
| Power (laptops only) | on charger | | on battery | |
| Stick | found (`Stick E:`) | | none (red chip, spec 8) | |

**Gates** (`Get-RepairGate`, pure; first rule that fires wins; "warn" adds a line to the confirmation):

| Action | Disabled (reason key) | Warns |
|---|---|---|
| every action | `reason.running` (an action runs); `reason.noScript` (no Root/ScriptPath); `reason.unavailable` (not in `Model.Repair.Available`) | |
| `standard`, `postClone`, `dismSource` | `reason.checking` (strip loading); `reason.restart` (Restart crit); `reason.battery` (laptop on battery); `reason.diskFailing` (Disk crit, not ticked backed up) | `warn.lowSpace` (Free crit); `warn.diskFailing` (Disk crit, ticked); `confirm.noStickLog` (no stick) |
| `wuReset` | `reason.checking`; `reason.restart` | `warn.noRescan` (Internet crit); `confirm.noStickLog` |
| `diskCheck` | `reason.checking`; `reason.restart`; `reason.diskFailing` | `confirm.noStickLog` |
| `netReset`, `ghosts` | `reason.noStickBackup` | |
| `netRestore` | hidden unless `NetBackup` is set; `reason.noStickBackup` | |
| `quickReport`, `fullReport` | `reason.noStickReport` | |
| `compare` | `reason.noStickReport`; `reason.noEarlier` (no `HasEarlierReport`) | |
| `health` | | `confirm.noStickLog` |
| Restart PC | `reason.running` | |

- Unknown chips block nothing (spec 5). Read-only actions start at once (spec 4.2) **except without a stick**: spec 8's "the window says so before the action starts" becomes a one-click confirmation with `confirm.noStickLog` (**Plan call**).
- The strip is "loading" from the page's first visit until the safety child ends, and again after every action (the strip refreshes after each action; **Plan call**). It never refreshes while an action runs (spec 4.4).

### The repair model (Task 3; the toolbox model gains `Page = 'setup'|'repair'` and `Repair`)

```
Repair = @{ Available = [string[]] (catalog ids); CanRun = <bool>; IsLaptop = <bool>; SessionStamp = 'yyyy-MM-dd_HHmm'
            Strip = @{ State = 'loading'|'ready'; Restart; Free; BitLocker; Internet; Disk = <chip|$null> }
            Stick = @{ Root = $null|'E:\'; Drive = $null|'E:' }; DiskCheck = @{ Dirty; Excluded }
            NetBackup = $null | @{ Path; Sha256; CreatedAt; Adapters }; HasEarlierReport = <bool>
            BackedUp = $false; Complaint = ''; Selected = ''; CloseRefused = $false; Done = @(); Pending = $null (an action id the window must start now)
            Confirm = $null | @{ Action; Kind = 'confirm'|'yes'|'restart'; Typed = ''; AtPc = $false; Loading = <bool>;
                                 Lines = [string[]]; Remote = $null|@{ Rdp; AnyDesk; ScreenConnect }; Items = @( @{ InstanceId; Class; Name; Ticked } ); Options = @{} }
            Run = $null | @{ Action; Steps; Current; Percent; Log; ElapsedSeconds; Stopping = $false }
            Result = $null | <result.json as a hashtable> }
```

### XAML contract additions (Task 3)

- **Nav:** `NavSetup` becomes a `RadioButton` (`NavStyle`, `a:Page:setup`); new `NavRepair` (`a:Page:repair`, glyph `E90F`, `t:nav.repair`).
- **Page split:** the centre column is `CenterPanel` = `AdminBanner`, the machine card (shared), `WarnPanel`, `SetupOptions` (today's option grid), `RepairCenter`; the right column holds `SetupRight` (today's plan card) and `RepairRight`. `AdminBanner`, `WarnPanel`, `SetupOptions`, `SetupRight` show on the setup page only (**Plan call**).
- **`RepairCenter`:**
  - `StripPanel` (WrapPanel) with chips `ChipRestart`, `ChipFree`, `ChipBitLocker`, `ChipInternet`, `ChipDisk`, `ChipPower`, `ChipStick`; each a `Border` (`ChipStyle`) holding `<Name>Glyph` and `<Name>Text`, its tooltip a wrapping TextBlock; `ChipRestartButton` (`a:Restart:`, `t:repair.restartChip`), visible when Restart is crit.
  - `BackedUpSwitch` (`SwitchStyle`, `a:BackedUp:`, `t:repair.backedUp`), visible when Disk is crit; `NoStickBanner` (`t:repair.noStick`).
  - Row labels `t:repair.row.check|repair|advanced|report`; tiles are `Button`s (`RepairTileStyle`) `TileHealth`, `TileQuickReport`, `TileStandard`, `TilePostClone`, `TileWuReset`, `TileNetReset`, `TileDiskCheck`, `TileGhosts`, `TileFullReport`, `TileCompare` with `Tag="a:Tile:<id>"`, each a glyph, `t:tile.<id>.title` and `t:tile.<id>.line`; small button `NetRestoreButton` (`a:Tile:netRestore`).
  - `ComplaintBox`: `TextBox`, `Tag="a:Complaint:"`, `MaxLength="2000"`, `AcceptsReturn="True"`, `TextWrapping="Wrap"`, label `t:repair.complaint`, hint `t:repair.complaintHint`.
- **`RepairRight`** (a card; one panel visible at a time, in this priority: Confirm, Run, Result, What):
  - `WhatPanel`: `t:what.title`, `WhatText`.
  - `ConfirmPanel`: `ConfirmTitle`, `ConfirmLines` (StackPanel), `ConfirmScroll` with `ConfirmItems` (generated ghost CheckBoxes `a:GhostTick:<index>` or adapter lines), `AtPcSwitch` (`a:AtPc:`), `YesPanel` with `t:confirm.yesPrompt` and `YesBox` (`TextBox`, `a:YesText:`, `MaxLength="8"`), `ConfirmButton` (`a:Confirm:`), `ConfirmCancelButton` (`a:ConfirmCancel:`).
  - `RunPanel`: `RunTitle`, `RunSteps` (generated rows: glyph + `tool.step.<id>` name), `RunBar` (`ProgressBar`, Maximum 100, visible when a percent is known), `RunElapsed`, `RunLog` (`MonoFont`, LeftToRight, last 8 lines), `StopButton` (`a:Stop:`), `StoppingText`.
  - `ResultPanel`: `ResultBanner` (`ResultOutcome`), `ResultFindings` (generated rows, CRIT `CritBrush`, WARN `WarnBrush`, INFO `DimTextBrush`), `ResultRestartNeeded`, `OfferDiskCheckButton` (`a:Tile:diskCheck`), `OfferDismButton` (`a:Offer:dismSource`, `OfferDismText`), `ResultFiles` (LeftToRight), `OpenFolderButton` (`a:OpenFolder:`), `RestartButton` (`a:Restart:`).
  - `CloseRefusedText` (`t:run.closeRefused`, `WarnBrush`).
- **New resources** (starting values, settled on the screenshots): `OkBrush #4CAF50`, `OkBackBrush #1E3A24`, `CritBrush #E04343`, `MonoFont` (`Consolas`), styles `NavStyle`, `RepairTileStyle` (disabled = 45% opacity), `InputBoxStyle` (TextBox), `ProgressStyle`.
- **Glyphs** (starting values): tiles health `E9D9`, quickReport `E9F9`, standard `E90F`, postClone `E8C8`, wuReset `E895`, netReset `E968`, diskCheck `EDA2`, ghosts `E772`, fullReport `E8A5`, compare `E8F1`; chips restart `E777`, disk `EDA2`, BitLocker `E72E`, internet `E774`, free `E8B7`, power `E83E`/`E83F`, stick `E88E`; step rows done `E73E`, running `E768`, failed/timed out `E711`, warn `E7BA`, skipped `E738`, pending `E91F`.

### The string table additions (Task 3; `he` is the implementer's, Ben settles it on the PNGs)

| Key | en |
|---|---|
| `nav.repair` | Repair & diagnostics |
| `repair.row.check`, `.repair`, `.advanced`, `.report` | CHECK, REPAIR, ADVANCED, REPORT |
| `tile.health.title` / `.line` | Health check / Read-only: disk, Windows image, system files, recovery, devices |
| `tile.quickReport.title` / `.line` | Quick report / Key facts and findings in 1-2 minutes |
| `tile.standard.title` / `.line` | Standard repair / Clock, disk scan, DISM, SFC, recovery |
| `tile.postClone.title` / `.line` | Post-clone / Standard repair plus drivers, leftovers, TRIM, updates |
| `tile.wuReset.title` / `.line` | Windows Update reset / Services, update cache and download jobs |
| `tile.netReset.title` / `.line` | Network reset / Winsock and TCP/IP, settings saved first |
| `tile.diskCheck.title` / `.line` | Disk check at restart / Full check of C: at the next start |
| `tile.ghosts.title` / `.line` | Ghost devices / Remove old, disconnected devices |
| `tile.fullReport.title` / `.line` | Full report / Everything, for an AI chat (5-12 minutes) |
| `tile.compare.title` / `.line` | Compare with last visit / What changed since the last report |
| `tile.netRestore.title`, `tile.dismSource.title` | Restore network settings, Retry DISM with a local source |
| `tile.<id>.what` (10) | one paragraph per tile: what it does, how long, what it changes (mine) |
| `tile.<id>.changes` (standard, postClone, dismSource, wuReset, diskCheck, netReset, netRestore, ghosts) | the confirmation's list, one change per line (`\n`), from spec 6.2-6.7; diskCheck's list ends with "It runs at the next start and cannot be cancelled from the toolbox" (RD-R1) |
| `chip.loading` (every chip while the strip loads) | Checking... |
| `chip.restart.ok`, `.crit`, `.unknown` | No restart pending, Restart pending, Restart: unknown |
| `chip.free.level`, `chip.free.unknown` | {0} {1}% free, Free space unknown |
| `chip.bitlocker.ok`, `.warn`, `.unknown` | BitLocker off, BitLocker on, BitLocker: unknown |
| `chip.internet.ok`, `.crit`, `.unknown` | Internet OK, No internet, Internet: unknown |
| `chip.disk.ok`, `.warn`, `.crit`, `.unknown` | Disk OK, Disk: check, Disk failing, Disk: unknown |
| `chip.power.ac`, `chip.power.battery`, `chip.stick.ok`, `chip.stick.none` | On charger, On battery, Stick {0}, No stick |
| `tip.restart.crit`, `tip.restart.note` | A Windows servicing restart is pending: DISM and SFC would give wrong results. Restart first. / A file or computer rename is pending: that does not block repairs. |
| `tip.disk.crit`, `tip.disk.warn` | The disk is failing or has errors: back up or image the customer's data before any repair. / The disk is worn or hot. |
| `tip.bitlocker.warn`, `tip.internet.crit`, `tip.free.crit`, `tip.power.battery`, `tip.stick.none`, `tip.unknown` | Have the recovery key before BIOS or board work / No internet: connect Ethernet or a phone hotspot. / DISM needs room: free some space first. / On battery: Standard repair and Post-clone are blocked. / Plug in the BenTech stick to keep reports and logs / Could not be checked in time; it blocks nothing. |
| `repair.backedUp`, `repair.noStick`, `repair.restartChip`, `repair.complaint`, `repair.complaintHint` | The customer's data is backed up / imaged, Plug in the BenTech stick to keep reports and logs, Restart PC, CUSTOMER COMPLAINT, Type it before a report: it goes at the top. |
| `what.title`, `what.empty` | WHAT IT DOES, Point at a tile to see what it does. |
| `confirm.title`, `confirm.changes`, `confirm.yesPrompt`, `confirm.atPc`, `confirm.go`, `confirm.cancel`, `confirm.loading` | CONFIRM, This will change:, Type YES to continue, I am at this PC (not connected remotely), Confirm, Cancel, Checking... |
| `confirm.remote`, `confirm.static`, `confirm.noStatic`, `confirm.noStickLog` | A remote session may be active ({0}): the reset would cut it., {0}: {1}, No static IP or DNS settings found., No stick: the log goes to C:\BenTech\Setup\Logs, which Cancel deletes. |
| `confirm.ghostCount`, `confirm.restart`, `confirm.restartGo` | {0} of {1} devices will be removed ({2} left out: Bluetooth, audio, printers), Restart this PC now?, Restart |
| `warn.lowSpace`, `warn.diskFailing`, `warn.noRescan` | Low free space: DISM needs room, The disk is failing: the customer's data is backed up, No internet: the update rescan is skipped |
| `run.title`, `run.elapsed`, `run.stop`, `run.stopping`, `run.closeRefused` | RUNNING, Elapsed {0}, Stop, Stopping after {0}..., An action is running: press Stop, then close |
| `result.title`, `result.none`, `result.files`, `result.openFolder`, `result.restart`, `result.restartNeeded` | RESULT, No problems found, Logs and reports: {0}, Open folder, Restart PC, A restart is needed to finish |
| `result.outcome.Done`, `.Stopped`, `.TimedOut`, `.NeedsRestart`, `.Failed` | Finished, Stopped, Timed out, Restart first, Failed |
| `result.offerDism`, `result.buildDiffers`, `result.languageDiffers` | Retry DISM with {0} ({1}, {2}, {3}, build {4}), Its build differs from this PC (build {0}): DISM may refuse it., Its languages ({0}) do not include this PC's ({1}). |
| `reason.running`, `reason.checking`, `reason.restart`, `reason.battery`, `reason.diskFailing` | Another action is running, Checking the PC first..., Restart pending: restart first, On battery: plug in the charger, The disk is failing: tick "backed up / imaged" first |
| `reason.noStickReport`, `reason.noStickBackup`, `reason.noEarlier`, `reason.unavailable`, `reason.noScript` | Plug in the BenTech stick: reports are kept only there, Plug in the BenTech stick: the backup must survive the restart, No earlier report for this PC on the stick, Not available in this version, Not available: the setup files are missing |
| `tool.step.<id>` | one name per step id of the catalog (Task 3 adds all of them; English e.g. `dism` = `Windows image (DISM)`, `sfc` = `System files (SFC)`, `winreFix` = `Recovery (WinRE)`, `report01` = `01 System`) |

---

### Task 1: The child entry and the action engine

**Files:**
- Modify: `src/Entry/Param.ps1`, `src/Entry/Run.ps1`, `src/Entry/Main.ps1` (`Start-BenTechSetup` params, doc and dispatch), `src/Engine/Reboot.ps1`, `src/Toolbox/Strings.ps1` (the six Task 1 findings), `config/config.json`, `tools/Build-Bundle.ps1`.
- Create: `src/Repair/ToolEngine.ps1`, `tests/ToolEngine.Tests.ps1`, `tests/RepairStatic.Tests.ps1`, `tests/fixtures/dism-progress-en.txt`, `tests/fixtures/dism-progress-he.txt`.
- Test: also `tests/Bundle.Tests.ps1`, `tests/Entry.Tests.ps1`, `tests/Config.Tests.ps1`.

**Interfaces:**
- Consumes: `Invoke-External`, `Invoke-PowerShellChild -Command -TimeoutMinutes -> @{ ExitCode; TimedOut; Output }`, `ConvertTo-PowerShellLiteral`, `Read-FileTail`, `Register-SetupTick` / `Unregister-SetupTick`, `Wait-SetupDelay`, `Write-SetupLog`, `Initialize-SetupLog`, `Read-SetupConfig`, `ConvertTo-ScreenText`, `Test-RebootRegistryKey`, `$script:ToolboxStrings`.
- Produces:
  - **`Param.ps1`:** `param([switch]$Resume, [switch]$WuRound, [switch]$SearchOnly, [string]$ResultPath, [switch]$WuUnhide, [string]$UpdateIds, [string]$ToolAction, [string]$ToolArgs)`.
  - **`Run.ps1`:** `exit (Start-BenTechSetup -Resume:$Resume -WuRound:$WuRound -SearchOnly:$SearchOnly -ResultPath $ResultPath -WuUnhide:$WuUnhide -UpdateIds $UpdateIds -ToolAction $ToolAction -ToolArgs $ToolArgs)`.
  - **`Main.ps1`:** `Start-BenTechSetup` gains `[AllowNull()][AllowEmptyString()][string]$ToolAction`, `$ToolArgs`; right after the `-WuUnhide` line: `if (-not [string]::IsNullOrEmpty($ToolAction)) { return (Invoke-SetupToolProcess -Root $Root -ActionId $ToolAction -ArgsPath $ToolArgs) }`: no lock, no transcript, no QuickEdit, no screen, no activity feed (as `-WuRound`).
  - **`Reboot.ps1`:**
    - `Get-ServicingRebootSignals -> @{ CbsRebootPending; CbsPackagesPending; PendingXml; WuRebootRequired; PendingFileRename; ComputerRenamePending }` (bools; `...\Component Based Servicing\PackagesPending` key; `Test-Path "$env:windir\WinSxS\pending.xml"`; the other four as `Get-PendingRebootSignals` reads them). Never throws.
    - `Test-ServicingRebootPending -Signals <hashtable> -> bool`: any of the first four.
  - **`ToolEngine.ps1`** (header: spec 7, the run model, the rules of Global Constraints; needs Logging, Activity, Process, Winget (`Invoke-PowerShellChild`, `ConvertTo-PowerShellLiteral`), Config, Reboot, StartScreen, Strings):
    - `$script:ToolActionCatalog`, `$script:ToolSteps` (empty literals; rows per the table, added by their tasks).
    - `Get-ToolText -Key <string> [-Arguments <object[]>] -> string`: `$script:ToolboxStrings.en[$Key]` formatted, through `ConvertTo-ScreenText`; the key itself when missing or unformattable. Never throws.
    - `Write-ToolJsonFile -Path -InputObject [-Depth 8] -> bool` (tmp, then Replace/Move; never throws) and `Read-ToolJsonFile -Path [-MaxBytes 1MB] -> object|$null` (missing, too big, empty, not JSON, not an object: `$null`; never throws).
    - `Read-ToolArgs -Path <string> -Root <string> -ActionId <string> -> hashtable` (throws with an ASCII message on anything invalid): the path is fully qualified, its full path is `<Root>\Tool\<one folder>\args.json` (case-insensitive) and neither that folder nor `Tool` is a reparse point; the JSON is an object under 1 MB; `Action -ceq $ActionId` and is in the catalog; `RunId` matches `^[0-9]{8}-[0-9]{6}-[A-Za-z]{2,20}$`; `DeadlineUtc` parses as a round-trip date; `SessionDir` is fully qualified or empty; `Complaint` is a string of at most 2000 characters; `Options` is an object or missing.
    - `New-ToolRun -ToolArgs <hashtable> -Config <object> -Root <string> -> hashtable` = `@{ Args; Config; Root; Dir; ProgressPath; ResultPath; StopPath; LogDir; SessionDir = $null (set by New-ToolSessionDir); Deadline (UTC [datetime]); Steps = List of @{ Id; Status = 'pending'; Percent = $null }; Current = -1; Findings = List; Log = List; Data = @{}; Partial = @{}; RestartRequired = $false; Offers = @{ DiskCheck = $false; DismSource = $null }; Files = @{}; OutputPath = $null; StartedAt }`.
    - `New-ToolSessionDir -Run -> string`: creates `Args.SessionDir` and its `logs\`; when `<stick>\BenTech-Reports` or the session folder is a reparse point (`Test-StickReparsePoint`), or creation fails, it uses `<Root>\Logs\Repair\<leaf>` instead and adds `sessionLink` (WARN). Returns the folder used and stores it in `$Run.SessionDir` (`$Run.Data.SessionIsLocal = $true` for the fallback, which the network backup and the ghost CSV refuse in Task 7).
    - `Add-ToolFinding -Run -Level <'CRIT'|'WARN'|'INFO'> -Code <string> [-Arguments <object[]>]` (Text = `Get-ToolText "finding.$Code"`; Args as ASCII strings); `Add-ToolLog -Run -Text` (ASCII; INFO in the child's log; keeps the last 12).
    - `Write-ToolProgress -Run` (never throws; a failed write is logged once per run) and `Write-ToolResult -Run -Outcome <string> -> bool`; `Get-ToolResultColor -Outcome -Findings -> string`.
    - `Test-ToolStopRequested -Run -> bool` (`stop.flag` exists); `Get-ToolStepTimeout -Run -Name <string> -> double` (config table rule).
    - `Invoke-ToolSteps -Run -> 'Done'|'Stopped'|'TimedOut'|'NeedsRestart'`: for each id of `$Run.Steps`, in order. **Safe points before every step after the first**, in this order: stop flag -> `stopped` (INFO, the previous step's English name), the rest `skipped`, `Stopped`; past `Deadline` -> `actionTimedOut`, the rest `skipped`, `TimedOut`. Before **every** servicing step (the first too): `Test-ServicingRebootPending (Get-ServicingRebootSignals)` -> `restartFirst`, the rest `skipped`, `NeedsRestart`. Then the step: `running`, progress, `& <Function> -Run $Run` (an exception or an unknown result is `failed` + `stepFailed`), its status, progress.
    - `Invoke-ToolNative -Run -FilePath <string> [-ArgumentList <string>] [-StepTimeout <string>] [-OutputName <string>] -> @{ ExitCode; TimedOut; OutputPath }`:
      - without `-OutputName`: `Invoke-External` with `Get-ToolStepTimeout` (output discarded, never captured);
      - with it: the output goes to `<LogDir>\<OutputName>-<HHmmss>.txt` through `Invoke-External -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/d /s /c ""{0}" {1} > "{2}" 2>&1"' -f ...)`; `$Run.OutputPath` is set for the tick during the call and cleared in `finally`;
      - refuses (throws) an output path or argument holding `"`, `%`, `&`, `^`, `|`, `<`, `>` or `!` (**Plan call**: every path is built from sanitized parts, so this only guards against a bug).
    - `Format-ToolExitCode -ExitCode -> string`: `$null` -> `timed out`; else `0x{0:X8}` of the `[uint32]` bits.
    - `Get-ToolPercent -Text <string> -> object`: the **last** match of `(?<!\d)(\d{1,3}(?:[.,]\d{1,2})?)\s?%` as `[double]` (comma read as a point, invariant), `$null` when none or above 100. Display only.
    - `Update-ToolTick -Run`: the child's tick handler (`Register-SetupTick` in `Invoke-SetupToolProcess`): with `OutputPath` set, `Read-FileTail -MaxBytes 65536`, `Get-ToolPercent`, the running step's `Percent`; then `Write-ToolProgress`. Never throws.
    - `Invoke-ToolJsonChild -Run -Name <string> -Command <string> [-StepTimeout <string>] -> @{ Ok; TimedOut; Data; Error }`: the grandchild runs `$ErrorActionPreference = 'Stop'`, sets `$out` to the literal `<Dir>\gc-<Name>-<n>.json` (`ConvertTo-PowerShellLiteral`), evaluates `& { <Command> }`, writes it as compressed JSON (depth 6, UTF-8 without BOM) and exits 0; a throw writes `@{ Error = <message> }` and exits 1. Then `Read-ToolJsonFile`: exit 0 and an object -> `Ok`; anything else -> `Ok = $false` with `Error` (`timed out`, `exit 0x...`, the grandchild's message, or `no result`). Commands return a hashtable (lists inside `Items`), never a bare array. Never throws.
    - `Invoke-SetupToolProcess -Root -ActionId -ArgsPath -> int`: points the log at `<Root>\Tool` first (so a refused call logs inside the admin-only folder and creates nothing elsewhere), then at the run folder once the args are valid; `Read-ToolArgs` (invalid: ERROR `Tool action refused` with the ASCII reason, return 1, nothing else runs); `Read-SetupConfig <Root>\config.json`; `New-ToolRun`; for a non-`LogLocal` action `New-ToolSessionDir` and the log moves to `<session>\logs`; logs `Tool action started` @{ action; runId }; `Register-SetupTick`; `Invoke-ToolSteps`; `Write-ToolResult`; `Unregister-SetupTick` in `finally`. 0 when the result was written, else 1. Never prompts, never draws.

- [ ] **Step 1: Config.** Add the Shared shapes block to `config/config.json` exactly; nothing else changes.

- [ ] **Step 2: Write the failing tests.**

  `tests/Bundle.Tests.ps1`: the param names become `@('Resume','WuRound','SearchOnly','ResultPath','WuUnhide','UpdateIds','ToolAction','ToolArgs')`, `$codeLines[0]` the new `param(...)` line, `$call` the new `exit (...)` line (both exactly as in Produces). Add:
  ```powershell
  It 'defines every tool action''s step functions' { . "$PSScriptRoot\..\src\Repair\ToolEngine.ps1"; $names = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
    foreach ($a in $script:ToolActionCatalog.Values) { foreach ($s in $a.Steps) { $script:ToolSteps.Keys | Should -Contain $s; $names | Should -Contain $script:ToolSteps[$s].Function } } }
  ```
  `tests/Config.Tests.ps1`: `'pins the repair values (repair spec 5, 6.2, 6.8)'`: `$cfg.repair.internet.url` is `https://www.msftconnecttest.com/connecttest.txt`, host `www.msftconnecttest.com`, seconds 5; `freeSpace` 10 / 15; `reportMaxKB` 150; `thresholds.clockOffsetMinutes` 2; `@($cfg.timeoutsMinutes.tool.PSObject.Properties.Name)` equals the sixteen action ids of the table; every `tool` and `toolStep` value is a number above 0; `oemUtilities` keys are `DELL, HP, LENOVO, ASUS, ACER, MSI`.

  `tests/Entry.Tests.ps1`: `Invoke-Entry` gains `[string]$ToolAction = '', [string]$ToolArgs = ''`. Add `Context '-ToolAction'`:
  ```powershell
  It 'dispatches to Invoke-SetupToolProcess and takes no lock, transcript, console change or start screen' {
    Mock Invoke-SetupToolProcess { 0 }; Invoke-Entry -ToolAction 'health' -ToolArgs "$TestDrive\Tool\r\args.json" | Should -Be 0
    Should -Invoke Invoke-SetupToolProcess -Times 1 -Exactly -ParameterFilter { $Root -eq $TestDrive -and $ActionId -eq 'health' -and $ArgsPath -like '*\Tool\r\args.json' }
    foreach ($c in 'Enter-RunLock','Start-Transcript','Disable-ConsoleQuickEdit','Resize-SetupConsole','Get-SetupChoices','Initialize-SetupActivity') { Should -Invoke $c -Times 0 -Exactly } }
  It 'returns the child''s exit code' { Mock Invoke-SetupToolProcess { 1 }; Invoke-Entry -ToolAction 'health' -ToolArgs 'x' | Should -Be 1 }
  ```

  `tests/ToolEngine.Tests.ps1` (new).
  - **SAFETY header** as Global Constraints; `Invoke-External`, `Invoke-PowerShellChild`, `Get-ServicingRebootSignals` are mocked in every `BeforeEach`; the safety nets throw.
  - **BeforeAll** dot-sources `Common\Logging`, `Common\Activity`, `Common\Process`, `Common\Config`, `Steps\Winget`, `Engine\Reboot`, `UI\StartScreen`, `Toolbox\Strings`, `Entry\Cleanup` (`Test-StickReparsePoint`), `Repair\ToolEngine`; `$cfg`.
  - **Fixture `New-TestRun -Steps <string[]> [-DeadlineMinutes 600]`:** creates `$TestDrive\Root\Tool\20261022-101500-test\`, registers fake steps in `$script:ToolSteps` (`fakeA`, `fakeB` with `Servicing = $false`, `fakeS` with `$true`, functions defined in the test that run `$script:onCall`, record calls in `$script:calls`, throw when named in `$script:stepThrows` and return `'done'`) and a fake action `test` in `$script:ToolActionCatalog` (readonly, `LogLocal = $false`, its steps the given ones), returns `New-ToolRun`. **Fixture `Write-TestArgs [-Mutate <scriptblock>] [-Outside]`:** writes a valid `args.json` for `test` (a `SessionDir` under `$TestDrive\Stick\BenTech-Reports`), changed by `-Mutate`, under `$TestDrive\Root\Tool\<RunId>\` or, with `-Outside`, under `$TestDrive\elsewhere\`; returns its path.
  ```powershell
  Describe 'Invoke-ToolSteps (spec 4.3, 5, 7)' {
    It 'runs the steps in order and writes progress at every transition' { $r = New-TestRun 'fakeA','fakeB'; Invoke-ToolSteps -Run $r | Should -Be 'Done'
      $script:calls | Should -Be @('fakeA','fakeB'); (Read-ToolJsonFile $r.ProgressPath).Steps.Status | Should -Be @('done','done') }
    It 'Stop is honoured only between steps: a stop raised during a step lets it finish' {
      $r = New-TestRun 'fakeA','fakeB'; $script:onCall = { if ($args[0] -eq 'fakeA') { 'x' | Set-Content $r.StopPath } }
      Invoke-ToolSteps -Run $r | Should -Be 'Stopped'; $script:calls | Should -Be @('fakeA'); $r.Steps.Status | Should -Be @('done','skipped')
      $r.Findings.Code | Should -Contain 'stopped' }
    It 'a passed deadline ends the action at the next safe point' { $r = New-TestRun 'fakeA','fakeB'; $script:onCall = { $r.Deadline = [datetime]::UtcNow.AddMinutes(-1) }
      Invoke-ToolSteps -Run $r | Should -Be 'TimedOut'; $r.Findings.Code | Should -Contain 'actionTimedOut' }
    It 'a servicing restart pending before a servicing step stops the action (yellow), checked before the first step too' {
      Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $false; CbsPackagesPending = $true; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $true; ComputerRenamePending = $false } }
      $r = New-TestRun 'fakeA','fakeS','fakeB'; Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'; $script:calls | Should -Be @('fakeA')
      Get-ToolResultColor -Outcome 'NeedsRestart' -Findings $r.Findings | Should -Be 'YELLOW' }
    It 'a file rename alone never blocks' { Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $true; ComputerRenamePending = $true } }
      Invoke-ToolSteps -Run (New-TestRun 'fakeS') | Should -Be 'Done' }
    It 'a step that throws is failed with stepFailed and the next step still runs' { $script:stepThrows = 'fakeA'; $r = New-TestRun 'fakeA','fakeB'
      Invoke-ToolSteps -Run $r | Should -Be 'Done'; $r.Steps.Status | Should -Be @('failed','done'); Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'RED' }
  }
  Describe 'Invoke-ToolNative' {
    It 'redirects to a file through cmd /d /s /c, with the step timeout capped by the deadline' { $r = New-TestRun 'fakeA' -DeadlineMinutes 10
      $null = Invoke-ToolNative -Run $r -FilePath 'C:\Windows\System32\dism.exe' -ArgumentList '/Online /Cleanup-Image /RestoreHealth' -StepTimeout 'dism' -OutputName 'dism'
      Should -Invoke Invoke-External -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\System32\cmd.exe' -and $ArgumentList -like '/d /s /c ""C:\Windows\System32\dism.exe" /Online /Cleanup-Image /RestoreHealth > "*\dism-*.txt" 2>&1"' -and $TimeoutMinutes -le 9.5 -and -not $CaptureOutput } }
    It 'refuses a path with cmd metacharacters' { { Invoke-ToolNative -Run (New-TestRun 'fakeA') -FilePath 'C:\x&y.exe' -OutputName 'x' } | Should -Throw }
    It 'formats DISM''s HRESULT exit code' { Format-ToolExitCode -ExitCode -2146498529 | Should -Be '0x800F081F'; Format-ToolExitCode -ExitCode $null | Should -Be 'timed out' }
  }
  Describe 'Get-ToolPercent (display only)' {
    It '<Why>' -ForEach @(@{ Why = 'the DISM bar'; F = 'dism-progress-en.txt'; E = 45.0 }, @{ Why = 'Hebrew text around the bar'; F = 'dism-progress-he.txt'; E = 62.3 }) {
      Get-ToolPercent -Text ([IO.File]::ReadAllText("$PSScriptRoot\fixtures\$F")) | Should -Be $E }
    It 'none, or above 100, is $null' { Get-ToolPercent -Text 'no number' | Should -BeNullOrEmpty; Get-ToolPercent -Text '250%' | Should -BeNullOrEmpty; Get-ToolPercent -Text '[==100.0%==]' | Should -Be 100 }
  }
  Describe 'Invoke-ToolJsonChild' {
    It 'wraps the command, bounds it, and returns its JSON' { Mock Invoke-PowerShellChild { [IO.File]::WriteAllText(($Command -replace "(?s).*\`$out = '([^']+)'.*", '$1'), '{"Result":"NoErrorsFound"}'); @{ ExitCode = 0; TimedOut = $false; Output = '' } }
      $g = Invoke-ToolJsonChild -Run (New-TestRun 'fakeA') -Name 'volumeScan' -Command "@{ Result = [string](Repair-Volume -DriveLetter 'C' -Scan) }" -StepTimeout 'volumeScan'
      $g.Ok | Should -BeTrue; $g.Data.Result | Should -Be 'NoErrorsFound'; Should -Invoke Invoke-PowerShellChild -ParameterFilter { $Command -match "ErrorActionPreference = 'Stop'" -and $TimeoutMinutes -eq 60 } }
    It 'a timeout, a non-zero exit or no file is not Ok, never a throw' { Mock Invoke-PowerShellChild { @{ ExitCode = $null; TimedOut = $true; Output = '' } }
      $g = Invoke-ToolJsonChild -Run (New-TestRun 'fakeA') -Name 'x' -Command '@{}'; $g.Ok | Should -BeFalse; $g.TimedOut | Should -BeTrue; $g.Error | Should -Be 'timed out' }
  }
  Describe 'Read-ToolArgs and Invoke-SetupToolProcess' {
    It 'refuses <Why>' -ForEach @(@{ Why = 'an args file outside Root\Tool'; Outside = $true; Mutate = { } }, @{ Why = 'another action than -ToolAction'; Outside = $false; Mutate = { param($a) $a.Action = 'health' } }
      @{ Why = 'an action not in the catalog'; Outside = $false; Mutate = { param($a) $a.Action = 'format' } }, @{ Why = 'a bad RunId'; Outside = $false; Mutate = { param($a) $a.RunId = '..\x' } }
      @{ Why = 'a complaint over 2000 characters'; Outside = $false; Mutate = { param($a) $a.Complaint = 'x' * 2001 } }) {
      $p = Write-TestArgs -Mutate $Mutate -Outside:$Outside; { Read-ToolArgs -Path $p -Root "$TestDrive\Root" -ActionId 'test' } | Should -Throw }
    It 'runs the steps, writes the result and returns 0; Hebrew in the complaint never reaches the log' { <# a valid args.json with Complaint = 'המחשב איטי', fake steps #>
      Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath $argsPath | Should -Be 0
      (Read-ToolJsonFile "$runDir\result.json").Outcome | Should -Be 'Done'
      Get-ChildItem "$TestDrive\Root" -Recurse -Filter setup.log | ForEach-Object { [IO.File]::ReadAllText($_.FullName) | Should -Not -Match '[^\x00-\x7F]' } }
    It 'invalid args: 1, an ERROR line, no step and no result' { Invoke-SetupToolProcess -Root "$TestDrive\Root" -ActionId 'test' -ArgsPath "$TestDrive\elsewhere\args.json" | Should -Be 1; $script:calls | Should -BeNullOrEmpty }
    It 'a session folder that is a link on the stick is not written through: local folder and sessionLink' { Mock Test-StickReparsePoint { $Path -like '*BenTech-Reports*' } <# ... #>; (Read-ToolJsonFile "$runDir\result.json").Findings.Code | Should -Contain 'sessionLink' }
  }
  ```
  `tests/RepairStatic.Tests.ps1` (new; parses files only), grown by later tasks:
  ```powershell
  # $repairFiles = src\Repair\*.ps1; $allowedReads = 'Update-ToolTick','Read-ToolJsonFile','Read-ToolArgs' (+ the functions later tasks add: Read-ToolCbsLog, Get-ToolReAgentState, Read-ToolLogErrors)
  It 'the repair code captures no tool output and reads only the files on its allow-list (Review Focus 4)' {
    foreach ($f in $repairFiles) { $ast = ...ParseFile...
      $ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandParameterAst] -and $args[0].ParameterName -eq 'CaptureOutput' }, $true).Count | Should -Be 0 -Because $f.Name
      foreach ($c in $ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -in 'Read-FileTail','Get-Content' }, $true)) { (Get-EnclosingFunction $c) | Should -BeIn $allowedReads }
      ([regex]::Matches((Get-Content $f.FullName -Raw), 'ReadAllText|ReadAllLines|StreamReader')) | ForEach-Object { <# same allow-list check by enclosing function #> } } }
  It 'no Invoke-WebRequest, Start-Sleep, Read-Host or Write-Host in src\Repair' { <# token scan #> }
  It 'no repair file runs /release, /renew, /ResetBase or reads a key protector''s password' { <# text scan: (?i)/release|/renew|ResetBase|GetKeyProtectorNumericalPassword|RecoveryPassword #> }
  ```
- [ ] **Step 3: Run** `ToolEngine`, `RepairStatic`, `Bundle`, `Entry`, `Config` tests. Expected: FAIL (no file, no parameters).
- [ ] **Step 4: Implement** the Produces list (Reboot, ToolEngine, Strings, Param, Run, Main, `$BundleOrder` `'Repair\ToolEngine.ps1'` after `'Report\Report.ps1'`). Re-save with BOM.
- [ ] **Step 5: Run** those files, then the full suite. Expected: `Failed: 0`. `Bundle.Tests` now pins the new parameter list; `Launcher.Tests` passes unchanged (the launcher does not pass the new parameters).
- [ ] **Step 6: Review gate, then commit:** `feat: tool action child entry and engine (repair step 2)`.

---

### Task 2: Language-independent checks, the safety strip child and the Health check

**Files:**
- Create: `src/Repair/ToolChecks.ps1`, `src/Repair/ToolSafety.ps1`, `tests/ToolChecks.Tests.ps1`, fixtures `cbs-clean.log`, `cbs-repaired.log`, `cbs-cannot-repair.log`, `cbs-verify-corrupt.log`, `reagent-on.xml`, `reagent-off.xml`.
- Modify: `src/Detect/PcName.ps1`, `src/Repair/ToolEngine.ps1` (catalog rows `safety`, `health`; their steps), `src/Toolbox/Strings.ps1` (Task 2 findings), `tools/Build-Bundle.ps1`.
- Test: also `tests/Detection.Tests.ps1`, `tests/RepairStatic.Tests.ps1`.

**Interfaces:**
- Consumes (Task 1): `Invoke-ToolJsonChild`, `Invoke-ToolNative`, `Add-ToolFinding`, `Add-ToolLog`, `Write-ToolProgress`, `Get-ToolStepTimeout`, `Get-ServicingRebootSignals`, `Test-ServicingRebootPending`; `Read-FileTail`, `Wait-SetupDelay`.
- Produces:
  - **`PcName.ps1`:** `Test-PlaceholderSerial -Serial <string> -> bool` (New-PcName's junk rule, moved; `New-PcName` calls it, behaviour unchanged); `Test-UsableBiosUuid -BiosUuid <string> -> bool` (32 hex, not one repeated character, not `03000200040005000006000700080009`); `Get-MachineIdentity -Machine <hashtable> -> @{ Key; FolderPart; Serial; BiosUuid }` (Shared shapes rule).
  - **`ToolChecks.ps1`** (grandchild commands as `$script:Tool<Name>Command` here-strings, each returning one hashtable):
    - `Get-ToolVolumeScan -Run -> 'NoErrorsFound'|'ScanNeeded'|'SpotFixNeeded'|'FullRepairNeeded'|'Unknown'`: grandchild `@{ Result = [string](Repair-Volume -DriveLetter '<L>' -Scan) }` (`<L>` from `$env:SystemDrive`), step timeout `volumeScan`.
    - `Get-ToolImageHealth -Run -Mode <'CheckHealth'|'ScanHealth'> -> 'Healthy'|'Repairable'|'NonRepairable'|'Unknown'`: grandchild `@{ State = [string](Repair-WindowsImage -Online -<Mode>).ImageHealthState }`, timeouts `imageCheck` / `imageScan`.
    - `ConvertFrom-CbsSrText -Text <string> -Since <datetime> -> @{ Ran; VerifyComplete; Repaired; CannotRepair; Corrupt; Lines }` (pure): only lines whose first 19 characters parse as `yyyy-MM-dd HH:mm:ss` (invariant) at or after `Since - 5 s` and that hold `[SR]`; `Repaired` = the **sum of N >= 1** in `[SR] Repairing (\d+) components` (so a clean `Repairing 0 components` is never a repair, review I-3); `CannotRepair` = count of `[SR] Cannot repair member file`; `Corrupt` = count of `[SR]` lines matching `Hashes for file member|is corrupt|Could not reproject|Cannot repair member file`; `VerifyComplete` = `[SR] Verify complete`; `Lines` = up to 40 of the counted lines.
    - `Read-ToolCbsLog -Since <datetime> [-Folder "$env:windir\Logs\CBS"] -> string`: the last 16 MB of `CBS.log` plus every `CbsPersist_*.log` written after `Since` (CBS.log can rotate during a scan; **Plan call**).
    - `Read-ToolSfcResult -Run -Since <datetime> -> hashtable`: waits up to 30 s (`Wait-SetupDelay -Seconds 2` slices) until `VerifyComplete` appears, then `ConvertFrom-CbsSrText` (review I-3: CBS.log is written late).
    - `Get-ToolReAgentState [-Path "$env:windir\System32\Recovery\ReAgent.xml"] -> 'On'|'Off'|'Missing'|'Unknown'`: `<WindowsRE><InstallState state="1"/>` is On, `"0"` Off; no file Missing; unreadable Unknown.
    - `Get-ToolBcdState -Run -> @{ Recovery = 'On'|'Off'|'Unknown'; SafeBoot = <long|$null> }`: grandchild through the WMI `BcdStore` (`root\wmi`, `OpenStore` with `File = ''`, `OpenObject` `{fa926493-6f1c-4193-a414-58f0b2456d1e}` = `{current}`, `GetElement` `0x16000009` recoveryenabled, `0x14000008` recoverysequence, `0x25000080` safeboot). On = a recoverysequence id and recoveryenabled true or absent; Off = no recoverysequence or recoveryenabled false (**Plan call**: an absent recoveryenabled counts as on; docs/testing.md checks it).
    - `Resolve-WinReVerdict -Bcd <string> -ReAgent <string> -> @{ Verdict = 'On'|'Off'|'Unknown'; CanEnable = <bool> }` (pure; spec 6.1 builder check 7):

      | BCD | ReAgent.xml | Verdict | CanEnable |
      |---|---|---|---|
      | On | On, Missing, Unknown | On | no |
      | On | Off | Unknown | no |
      | Off | Off | Off | **yes** |
      | Off | On | Unknown | no |
      | Off | Missing, Unknown | Off | no (`winreNoAgreement` in Task 6; **Plan call**) |
      | Unknown | any | Unknown | no |
    - `Get-ToolProblemDevices -Run -> object`: grandchild `@{ Items = @(Get-PnpDevice -PresentOnly | Where-Object Status -ne 'OK' | ...) }` with `InstanceId`, `Class`, `Name`, `Status` and the `ConfigManagerErrorCode` of `Win32_PnPEntity`; `$null` when it failed. **No `pnputil /scan-devices` here** (spec 6.1).
    - `Get-ToolActivation -Run -> 'Activated'|'Not activated'|'Unknown'`: grandchild running `Get-ActivationStatus`'s query.
    - Steps (Health): `Invoke-ToolStepVolumeScan` (sets `$Run.Data.VolumeScan`; SpotFix -> `volumeSpotFix` + `Offers.DiskCheck`; FullRepair -> `volumeFullRepair`; ScanNeeded -> `volumeScanNeeded`; Unknown -> `volumeUnknown`), `Invoke-ToolStepImageCheck` / `Invoke-ToolStepImageScan` (Repairable WARN, NonRepairable CRIT, Unknown WARN; the scan step reports, the check step only logs), `Invoke-ToolStepSfcVerify` (`sfc.exe /verifyonly` through `Invoke-ToolNative -OutputName 'sfc'`, then `Read-ToolSfcResult`; not run -> `sfcNotRun`; corrupt -> `sfcCorrupt`; timed out -> `sfcTimedOut`), `Invoke-ToolStepWinre` (read-only: `winreOff` / `winreUnknown`; `$Run.Data.WinRe`), `Invoke-ToolStepDevices` (CM 22 counts as `devicesDisabled` INFO, never a problem; review I-10), `Invoke-ToolStepActivation`.
  - **`ToolSafety.ps1`:** chip readers `Get-ToolRestartChip`, `Get-ToolFreeSpaceChip -Config` (reads `[IO.DriveInfo]` of `$env:SystemDrive`, then the pure `ConvertTo-ToolFreeChip -FreeBytes <long> -TotalBytes <long> -Config [-Drive 'C:'] -> chip`, `Args` = the drive and the whole percent, e.g. `@('C:', '41')`), `Get-ToolBitLockerChip` (CIM `Win32_EncryptableVolume` for the system drive with `-OperationTimeoutSec 15`: `ProtectionStatus` and `GetKeyProtectors`' protector **types** only), `Test-ToolInternet -Config [-Connect <scriptblock>] [-Fetch <scriptblock>] -> @{ Tcp; Https; ClockOffsetSeconds; Chip }` (the two seams default to: `TcpClient.ConnectAsync(host, 443).Wait(5000)` -> bool, and `[Net.HttpWebRequest]` GET -> `@{ Ok; Date }`; TCP first, no HTTPS attempt when it fails; the `[Net.HttpWebRequest]` GET of the URL with `Timeout`/`ReadWriteTimeout` 5000 and TLS 1.2, its `Date` header giving the clock offset; **Plan call**: HttpWebRequest because WebClient has no timeout, and never `Invoke-WebRequest`), `Get-ToolDiskChip -Run` (grandchildren `disks` (`Get-PhysicalDisk`) and `reliability` (`Get-StorageReliabilityCounter`), plus `Get-WinEvent -FilterHashtable` for `disk` 7/51/153 and `Ntfs`/`Microsoft-Windows-Ntfs` 55 since `diskEventDays`, a `NoMatchingEventsFound` error id counting as 0), `Get-ToolDiskCheckState` (`Win32_Volume.DirtyBitSet` of the system drive; `Excluded` when `Session Manager\BootExecute` holds `/k:<letter>`); the steps `Invoke-ToolStepSafety*` store each chip in `$Run.Data.Chips` and `$Run.Partial.Chips` and write progress.

- [ ] **Step 1: Write the failing tests.**

  `tests/Detection.Tests.ps1`: `'Get-MachineIdentity: <Why>'` -ForEach `'7HX2K93'` -> `SN-7HX2K93`; `'To Be Filled By O.E.M.'` with UUID `4C4C4544-0037-4810-8058-B7C04F4B3933` -> `UUID-4C4C454400374810...` and `FolderPart` `UUID-B7C04F4B3933`; `'Default string'` with the AMI default UUID -> `Key ''`, `NOSERIAL`; **two whiteboxes with the same placeholder serial and different UUIDs get different keys**. The existing `New-PcName` tests stay unchanged and pass.

  `tests/ToolChecks.Tests.ps1` (new; SAFETY header; BeforeAll as Task 1 plus `Detect\PcName`, `Report\Report`, `Repair\ToolChecks`, `Repair\ToolSafety`; each test file defines its own `New-TestRun`, as the suite does today; `New-HealthRun` = a run of the `health` action with every grandchild answering a healthy PC from `$script:gc`, `Invoke-ToolNative` returning exit 0 and `Read-ToolSfcResult` a clean pass; `$old` = CBS text dated 2026-10-21):
  ```powershell
  Describe 'SFC from CBS.log (review I-3)' {
    It '<F>: Repaired <R>, CannotRepair <C>, Corrupt <K>' -ForEach @(
      @{ F = 'cbs-clean.log'; R = 0; C = 0; K = 0 }, @{ F = 'cbs-repaired.log'; R = 3; C = 0; K = 0 }
      @{ F = 'cbs-cannot-repair.log'; R = 0; C = 2; K = 2 }, @{ F = 'cbs-verify-corrupt.log'; R = 0; C = 0; K = 4 }) {
      $x = ConvertFrom-CbsSrText -Text ([IO.File]::ReadAllText("$PSScriptRoot\fixtures\$F")) -Since ([datetime]'2026-10-22 10:00:00')
      $x.Ran | Should -BeTrue; $x.Repaired | Should -Be $R; $x.CannotRepair | Should -Be $C; $x.Corrupt | Should -Be $K }
    It 'lines before -Since (Windows'' own verify blocks) are ignored' { (ConvertFrom-CbsSrText -Text $old -Since ([datetime]'2026-10-22 10:00')).Ran | Should -BeFalse }
    It 'a Hebrew-calendar culture on the thread changes nothing' { <# set [Threading.Thread]::CurrentThread.CurrentCulture to he-IL with HebrewCalendar #> (ConvertFrom-CbsSrText ...).Repaired | Should -Be 3 }
  }
  Describe 'WinRE (spec 6.1, builder check 7)' {
    It 'BCD <B> + ReAgent <A> -> <V>, CanEnable <E>' -ForEach @( <# every row of the table #> ) { $r = Resolve-WinReVerdict -Bcd $B -ReAgent $A; $r.Verdict | Should -Be $V; $r.CanEnable | Should -Be $E }
    It 'reads ReAgent.xml by attribute, not text' { Get-ToolReAgentState -Path "$PSScriptRoot\fixtures\reagent-on.xml" | Should -Be 'On'; Get-ToolReAgentState -Path "$TestDrive\none.xml" | Should -Be 'Missing' }
  }
  Describe 'the safety strip (spec 5)' {
    It 'a pending file or computer rename is a grey note, never red' { Mock Get-ServicingRebootSignals { @{ CbsRebootPending = $false; CbsPackagesPending = $false; PendingXml = $false; WuRebootRequired = $false; PendingFileRename = $true; ComputerRenamePending = $true } }
      $c = Get-ToolRestartChip; $c.Level | Should -Be 'ok'; $c.Detail.Notes | Should -Be @('PendingFileRename','ComputerRenamePending') }
    It '<Signal> alone is red' -ForEach @(@{ Signal = 'CbsRebootPending' }, @{ Signal = 'CbsPackagesPending' }, @{ Signal = 'PendingXml' }, @{ Signal = 'WuRebootRequired' }) { <# mock with only $Signal true #> (Get-ToolRestartChip).Level | Should -Be 'crit' }
    It 'free space: <Free> GB of <Size> GB is <L>' -ForEach @(@{ Free = 20; Size = 250; L = 'crit' }, @{ Free = 14; Size = 100; L = 'crit' }, @{ Free = 41; Size = 100; L = 'ok' }) {
      (ConvertTo-ToolFreeChip -FreeBytes ($Free * 1GB) -TotalBytes ($Size * 1GB) -Config $cfg).Level | Should -Be $L }
    It 'disk: <Why> is <L>' -ForEach @( @{ Why = 'a disk in Warning health'; Set = @{ Health = 'Warning' }; L = 'crit' }, @{ Why = 'uncorrected read errors'; Set = @{ ReadErrorsUncorrected = 3 }; L = 'crit' }
      @{ Why = 'one disk event 153'; Set = @{ Event = 'disk/153' }; L = 'crit' }, @{ Why = 'NTFS 55'; Set = @{ Event = 'Ntfs/55' }; L = 'crit' }, @{ Why = '84% wear'; Set = @{ Wear = 84 }; L = 'warn' }
      @{ Why = '61 C'; Set = @{ Temperature = 61 }; L = 'warn' }, @{ Why = 'a grandchild that timed out'; Set = @{ TimedOut = 'disks' }; L = 'unknown' }, @{ Why = 'all fine'; Set = @{}; L = 'ok' }) {
      Set-DiskMocks $Set   # Invoke-ToolJsonChild answers 'disks' / 'reliability' from one healthy SSD changed by $Set; Get-WinEvent returns the one event or NoMatchingEventsFound
      (Get-ToolDiskChip -Run (New-TestRun 'safetyDisk')).Level | Should -Be $L }
    It 'BitLocker reports protector types and never asks for a key' { <# CIM mocked #> (Get-ToolBitLockerChip).Detail.Protectors | Should -Be @('Tpm','RecoveryPassword') ; Should -Invoke Invoke-CimMethod -Times 0 -ParameterFilter { $MethodName -like '*NumericalPassword*' } }
    It 'internet: TCP fails -> crit and no HTTPS attempt; both fine -> ok with the clock offset' { $script:fetched = 0
      $t = Test-ToolInternet -Config $cfg -Connect { param($h, $ms) $false } -Fetch { param($u, $ms) $script:fetched++; @{ Ok = $true; Date = [datetime]::UtcNow } }
      $t.Chip.Level | Should -Be 'crit'; $script:fetched | Should -Be 0
      $t = Test-ToolInternet -Config $cfg -Connect { param($h, $ms) $h -eq 'www.msftconnecttest.com' -and $ms -eq 5000 } -Fetch { param($u, $ms) @{ Ok = ($u -eq 'https://www.msftconnecttest.com/connecttest.txt'); Date = [datetime]::UtcNow.AddMinutes(-3) } }
      $t.Chip.Level | Should -Be 'ok'; [math]::Round($t.ClockOffsetSeconds / 60) | Should -Be 3 }
    It 'each chip lands in progress.Partial as soon as it is known' { <# run the safety action with the disk grandchild hanging (mock returns TimedOut) #> (Read-ToolJsonFile $r.ProgressPath).Partial.Chips.Restart.Level | Should -Be 'ok' }
  }
  Describe 'Health check (spec 6.1)' {
    It 'runs its seven steps in order and only reads' { <# mocks #> Invoke-ToolSteps -Run (New-HealthRun) | Should -Be 'Done'
      Should -Invoke Invoke-ToolNative -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\sfc.exe' -and $ArgumentList -eq '/verifyonly' }
      Should -Invoke Invoke-ToolNative -Times 0 -ParameterFilter { $FilePath -match 'reagentc|pnputil|dism|fsutil' } }
    It 'Health check verdicts come from enums, exit codes and English CBS.log; Hebrew tool text changes nothing (Review Focus 4)' {
      <# the sfc output file the mock leaves is Hebrew UTF-16 text; the grandchildren answer Repairable / SpotFixNeeded #>
      $r = New-HealthRun; $null = Invoke-ToolSteps -Run $r
      @($r.Findings | ForEach-Object { '{0}|{1}' -f $_.Level, $_.Code }) | Should -Be @('CRIT|volumeSpotFix','WARN|imageRepairable','WARN|sfcCorrupt','WARN|winreUnknown','WARN|devicesProblem','WARN|notActivated')
      $r.Offers.DiskCheck | Should -BeTrue }
    It 'a disabled device (CM 22) is INFO, never a problem' { <# devices grandchild returns one CM 22 device #> $r.Findings.Code | Should -Be @('devicesDisabled') }
  }
  ```
  `tests/RepairStatic.Tests.ps1`: the read allow-list gains `Read-ToolCbsLog` and `Get-ToolReAgentState`.
- [ ] **Step 2: Run** `ToolChecks`, `Detection`, `RepairStatic`. Expected: FAIL.
- [ ] **Step 3: Implement** the Produces list; catalog rows `safety` (Kind info, LogLocal) and `health`; their `$script:ToolSteps` rows; Strings (findings, en + he); `$BundleOrder` `'Repair\ToolChecks.ps1'`, `'Repair\ToolSafety.ps1'` after `ToolEngine`. Re-save with BOM.
- [ ] **Step 4: Run** the three files, then the full suite. Expected: `Failed: 0`; `Bundle.Tests` (`defines every tool action's step functions`) passes.
- [ ] **Step 5: Review gate, then commit:** `feat: language-independent checks, the safety strip child and Health check`.

---

### Task 3: The repair page's look: model, XAML, strings and the preview

**Files:**
- Create: `src/Toolbox/RepairPlanner.ps1`, `src/Toolbox/RepairPage.ps1`, `tests/RepairPlanner.Tests.ps1`, `tests/RepairPage.Tests.ps1`.
- Modify: `src/Toolbox/Xaml.ps1`, `src/Toolbox/Strings.ps1`, `src/Toolbox/SetupPlanner.ps1`, `src/Toolbox/Toolbox.ps1` (`Register-ToolboxHandlers`, `Update-ToolboxView`), `tools/Preview-Toolbox.ps1`, `tools/Build-Bundle.ps1`.
- Test: also `tests/Toolbox.Tests.ps1` (dot-source list, the preview test), `tests/SetupPlanner.Tests.ps1`.

**Interfaces:**
- Consumes: `$script:ToolActionCatalog` (Task 1-2), `Get-MachineIdentity` (Task 2), `Get-ToolboxString`, `Set-ToolboxLanguage`, the toolbox model.
- Produces:
  - **`RepairPlanner.ps1`** (pure; no logging, no I/O):
    - `$script:RepairTileRows = [ordered]@{ check = @('health','quickReport'); repair = @('standard','postClone'); advanced = @('wuReset','netReset','diskCheck','ghosts'); report = @('fullReport','compare') }`.
    - `New-RepairModel -Machine <hashtable> -SessionStamp <string> [-CanRun <bool>] -> hashtable` (Shared shapes; `Available` = the catalog's ids; `Strip.State = 'loading'`).
    - `ConvertTo-RepairStrip -Chips <AllowNull object> [-Final <bool>] -> hashtable`: the five chips from a (partial) safety result; with `-Final $true` every missing chip becomes `@{ Level = 'unknown' }` and `State = 'ready'`.
    - `Get-RepairGate -Model <hashtable> -ActionId <string> -> @{ Enabled; Visible; Reason; Warns }` (the gate table; `Reason` and `Warns` are string keys).
  - **`SetupPlanner.ps1`:** `New-ToolboxModel` adds `Page = 'setup'` and `Repair = New-RepairModel ...`; `Update-ToolboxModel` gains `Page` (`setup`|`repair`; anything else changes nothing).
  - **`RepairPage.ps1`:** `Update-RepairView -Window -> void`: page visibility (both pages' parts and `NavSetup`/`NavRepair` IsChecked), chips (text, glyph, brush by level, tooltips; `ChipPower` laptops only), `BackedUpSwitch`/`NoStickBanner`/`ChipRestartButton` visibility, every tile's `IsEnabled`, `Visibility` and `ToolTip` (a wrapping `TextBlock` with the reason's text, `$null` when enabled; `ToolTipService.ShowOnDisabled` true) from `Get-RepairGate`, then the right panel by priority (Confirm, Run, Result, What) with its generated rows. Text through `Get-ToolboxString` in the model's language; machine values, the log tail and file paths `LeftToRight`. It **never writes `ComplaintBox.Text` or `YesBox.Text`** except to clear `YesBox` when a new confirmation opens (**Plan call**: a re-render must not move the caret).
  - **`Toolbox.ps1`:** `Register-ToolboxHandlers` wires `Add_Click` only on `a:` elements that are `[Windows.Controls.Primitives.ButtonBase]` (TextBoxes get theirs in Task 5); `Update-ToolboxView` calls `Update-RepairView` at its end.
  - **`tools/Preview-Toolbox.ps1`** also loads `Detect\PcName`, `Repair\ToolEngine`, `Toolbox\RepairPlanner`, `Toolbox\RepairPage` and renders seven more PNGs (same sample Dell, `Available` = every tile, `CanRun` true, stick `E:`):
    - `repair-en.png` / `repair-he.png`: idle; strip restart ok, free 41%, BitLocker on, internet ok, disk warn (wear 84%), power on charger; `Selected = 'standard'` (What it does); a complaint typed.
    - `repair-en-blocked.png`: restart crit, disk crit (backed-up switch shown, unticked), on battery, no stick: repairs, reports, Network reset and Ghosts disabled with their reasons.
    - `repair-en-confirm.png`: Network reset's confirmation: one adapter with a static IP, `AnyDesk` running, the at-PC switch, `YES` typed.
    - `repair-en-running.png` / `repair-he-running.png`: Standard repair, time sync and disk scan done, DISM running at 45%, SFC and WinRE pending, elapsed 12:34, six log lines, Stop.
    - `repair-en-result.png`: a YELLOW result with one CRIT, two WARN and one INFO finding, a restart needed, the DISM source offer with the build-differs line, the files line, Open folder and Restart PC.
  - **`$BundleOrder`:** `'Toolbox\RepairPlanner.ps1'` after `'Toolbox\SetupPlanner.ps1'`, `'Toolbox\RepairPage.ps1'` after `'Toolbox\Toolbox.ps1'`.

- [ ] **Step 1: Write the failing tests.**

  `tests/RepairPlanner.Tests.ps1` (new):
  ```powershell
  Describe 'Get-RepairGate (spec 5, 6.6, 6.7, 8)' {
    It '<A> is <E> (<Why>)' -ForEach @(
      @{ Why = 'restart pending blocks DISM and SFC';        Set = @{ Restart = 'crit' };                 A = 'standard';  E = 'reason.restart' }
      @{ Why = 'restart pending blocks the WU reset';         Set = @{ Restart = 'crit' };                 A = 'wuReset';   E = 'reason.restart' }
      @{ Why = 'read-only actions still run';                 Set = @{ Restart = 'crit' };                 A = 'health';    E = '' }
      @{ Why = 'Network reset still runs';                     Set = @{ Restart = 'crit' };                 A = 'netReset';  E = '' }
      @{ Why = 'a laptop on battery';                          Set = @{ OnAC = $false };                    A = 'postClone'; E = 'reason.battery' }
      @{ Why = 'a desktop on "battery" is no laptop';          Set = @{ OnAC = $false; IsLaptop = $false }; A = 'standard';  E = '' }
      @{ Why = 'a failing disk until backed up';               Set = @{ Disk = 'crit' };                    A = 'diskCheck'; E = 'reason.diskFailing' }
      @{ Why = 'backed up unlocks it';                         Set = @{ Disk = 'crit'; BackedUp = $true };  A = 'standard';  E = '' }
      @{ Why = 'unknown chips block nothing';                  Set = @{ Restart = 'unknown'; Disk = 'unknown' }; A = 'standard'; E = '' }
      @{ Why = 'strip still loading holds the repairs';        Set = @{ State = 'loading' };                A = 'standard';  E = 'reason.checking' }
      @{ Why = 'no stick: reports';                             Set = @{ Stick = $null };                    A = 'fullReport'; E = 'reason.noStickReport' }
      @{ Why = 'an action running';                             Set = @{ Running = $true };                  A = 'health';    E = 'reason.running' }
      @{ Why = 'not in this version';                           Set = @{ Available = @('health') };          A = 'ghosts';    E = 'reason.unavailable' }
      @{ Why = 'compare without an earlier report';             Set = @{};                                   A = 'compare';   E = 'reason.noEarlier' }
    ) { $g = Get-RepairGate -Model (New-TestModel $Set) -ActionId $A; $g.Reason | Should -BeExactly $E; $g.Enabled | Should -Be ($E -eq '') }
    It 'low space and an internet outage only warn' { (Get-RepairGate -Model (New-TestModel @{ Free = 'crit'; Internet = 'crit' }) -ActionId 'standard').Warns | Should -Contain 'warn.lowSpace'
      (Get-RepairGate -Model (New-TestModel @{ Internet = 'crit' }) -ActionId 'wuReset').Warns | Should -Contain 'warn.noRescan' }
    It 'there is no Cancel scheduled disk check action (RD-R1)' { $script:ToolActionCatalog.Keys | Should -Not -Contain 'diskCheckCancel' }
  }
  Describe 'ConvertTo-RepairStrip' {
    It 'keeps the chips it has and, at the end, makes the missing ones unknown' { $s = ConvertTo-RepairStrip -Chips @{ Restart = @{ Level = 'ok' } } -Final $true
      $s.State | Should -Be 'ready'; $s.Disk.Level | Should -Be 'unknown'; $s.Restart.Level | Should -Be 'ok' }
  }
  ```
  (`New-TestModel` builds `New-ToolboxModel` for the Dell sample, `Page = 'repair'`, a ready all-ok strip, stick `E:`, `Available` = all ids, `CanRun` true, then applies `$Set`.)

  `tests/RepairPage.Tests.ps1` (new; SAFETY header as `Toolbox.Tests`: windows are parsed, never shown; BeforeAll as `Toolbox.Tests` plus `Detect\PcName`, `Repair\ToolEngine`, `Toolbox\RepairPlanner`, `Toolbox\RepairPage`; the same `New-TestModel` as `RepairPlanner.Tests`, and `New-RepairWindow $Set` = `New-ToolboxWindow` on `New-TestModel $Set`; `$w` = `New-RepairWindow @{}` unless a test makes its own; `Click`, `ClickTag` and `Find-Tagged` copied from `Toolbox.Tests`; `$contractNames` = every name of the XAML contract additions; `$runSample` (Standard at DISM 45%), `$resultSample` (YELLOW: CRIT `volumeSpotFix`, WARN `sfcCorrupt` with Args `3`, INFO `activationUnknown`) and `$confirmSample` (Network reset, one static adapter) are the preview's sample states):
  ```powershell
  Describe 'the repair page look (spec 4.1)' {
    It 'has every named element of the contract, ten tiles tagged a:Tile:<id>, and no default or cancel button' {
      foreach ($n in $contractNames) { $w.FindName($n) | Should -Not -BeNullOrEmpty -Because $n }   # every name of the XAML contract additions
      foreach ($id in $script:RepairTileRows.Values | ForEach-Object { $_ }) { (Find-Tagged $w "a:Tile:$id") | Should -BeOfType [Windows.Controls.Button] }
      $script:ToolboxXaml | Should -Not -Match 'IsDefault="True"|IsCancel="True"|InputBindings' }
    It 'the complaint and YES boxes are TextBoxes with their limits' { $w.FindName('ComplaintBox').MaxLength | Should -Be 2000; $w.FindName('ComplaintBox').AcceptsReturn | Should -BeTrue; $w.FindName('YesBox').MaxLength | Should -Be 8 }
    It 'the nav switches the page; the machine card stays' { $w = New-RepairWindow @{}; $w.FindName('RepairCenter').Visibility | Should -Be 'Visible'; $w.FindName('SetupOptions').Visibility | Should -Be 'Collapsed'; $w.FindName('MachineModel').Text | Should -Match 'Latitude' }
    It 'chips take their level''s brush and the tooltip text; power shows on laptops only' { $w = New-RepairWindow @{ Restart = 'crit'; Disk = 'warn' }
      $w.FindName('ChipRestart').Background | Should -Be $w.FindResource('DangerBackBrush'); $w.FindName('ChipRestartButton').Visibility | Should -Be 'Visible'
      $w.FindName('ChipDisk').Background | Should -Be $w.FindResource('WarnBackBrush'); $w.FindName('ChipRestart').ToolTip.Text | Should -Match 'servicing restart'
      (New-RepairWindow @{ IsLaptop = $false }).FindName('ChipPower').Visibility | Should -Be 'Collapsed' }
    It 'a disabled tile carries its reason as its tooltip' { $w = New-RepairWindow @{ Restart = 'crit' }; $t = $w.FindName('TileStandard'); $t.IsEnabled | Should -BeFalse; $t.ToolTip.Text | Should -Be 'Restart pending: restart first' }
    It 'the right panel shows, in priority, the confirmation, the run, the result or what the tile does' {
      foreach ($c in @(@{ Set = @{ Selected = 'standard' }; P = 'WhatPanel' }, @{ Set = @{ Result = $resultSample }; P = 'ResultPanel' }, @{ Set = @{ Result = $resultSample; Run = $runSample }; P = 'RunPanel' }
                        @{ Set = @{ Run = $runSample; Confirm = $confirmSample }; P = 'ConfirmPanel' })) {
        $x = New-RepairWindow $c.Set; @('WhatPanel','ConfirmPanel','RunPanel','ResultPanel' | Where-Object { $x.FindName($_).Visibility -eq 'Visible' }) | Should -Be @($c.P) } }
    It 'a running action lists its steps with their glyphs, the percent bar and the log tail left-to-right' { <# Run with DISM at 45 #> $w.FindName('RunBar').Value | Should -Be 45; $w.FindName('RunLog').FlowDirection | Should -Be 'LeftToRight' }
    It 'findings are coloured by level and use the language''s text' { $x = New-RepairWindow @{ Language = 'he'; Result = $resultSample }   # CRIT volumeSpotFix, WARN sfcCorrupt (Args '3'), INFO activationUnknown
      $rows = @($x.FindName('ResultFindings').Children); $rows[0].Foreground | Should -Be $x.FindResource('CritBrush'); $rows[2].Foreground | Should -Be $x.FindResource('DimTextBrush')
      $rows[1].Text | Should -BeExactly ($script:ToolboxStrings.he['finding.sfcCorrupt'] -f '3') }
    It 'Hebrew mirrors the page; every t: key of the page exists in both languages' { $x = New-RepairWindow @{ Language = 'he' }; $x.FlowDirection | Should -Be 'RightToLeft'
      foreach ($k in [regex]::Matches($script:ToolboxXaml, 'Tag="t:([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) { $script:ToolboxStrings.he.Keys | Should -Contain $k }
      foreach ($id in $script:ToolSteps.Keys) { $script:ToolboxStrings.en.Keys | Should -Contain "tool.step.$id"; $script:ToolboxStrings.he.Keys | Should -Contain "tool.step.$id" } }
    It 'the new colours live in the one resource dictionary' { ([regex]::Matches($script:ToolboxXaml, '<Window\.Resources>')).Count | Should -Be 1; foreach ($c in '#4CAF50','#1E3A24','#E04343') { $script:ToolboxXaml | Should -Match $c } }
    It 'Register-ToolboxHandlers leaves the TextBoxes alone' { { Register-ToolboxHandlers -Window (New-RepairWindow @{}) } | Should -Not -Throw }
  }
  ```
  `tests/Toolbox.Tests.ps1`: the preview test expects the eleven PNGs (`toolbox-*` four, `repair-*` seven), each 1000 x 680. `tests/SetupPlanner.Tests.ps1`: `New-ToolboxModel` has `Page = 'setup'`; `Update-ToolboxModel -Action Page -Value repair` sets it and `-Value nope` changes nothing.
- [ ] **Step 2: Run** `RepairPlanner`, `RepairPage`, `Toolbox`, `SetupPlanner`. Expected: FAIL.
- [ ] **Step 3: Implement** the Produces list: the XAML (contract, resources), the strings (every key of the table, en + he, and `tool.step.<id>` for every step id of the catalog table), the model, the gate, the view, the preview. Re-save with BOM; check `Strings.ps1` still shows Hebrew.
- [ ] **Step 4: Run** the four files, then the full suite. Expected: `Failed: 0`; `Encoding`, `Colors` and the existing toolbox tests pass (the setup page renders as before).
- [ ] **Step 5: Render:** `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Preview-Toolbox.ps1`. Expected: eleven paths under `dist\toolbox-preview\`. Open each and check: nothing cut; Hebrew right-to-left with the machine values, log and paths left-to-right; glyphs are not boxes; the four setup PNGs look as approved (Q29).
- [ ] **Step 6: Review gate, then commit:** `feat: Repair & diagnostics page look, strings and previews`.
- [ ] **Step 7: HARD STOP (Q25, spec 12.2).** The controller sends the seven `repair-*.png` (and the four `toolbox-*.png`, to show the setup page did not move) to Ben and **waits for his approval of the look before Task 4 starts**. Every change he asks for (colours, sizes, glyphs, the copy in `Strings.ps1`, the Hebrew) is made here, re-rendered and re-sent, and committed as `fix: repair page look after Ben's review`. Task 4 does not start without Ben's explicit OK in chat.

---

### Task 4: Running actions from the window: the background child, deadline, Stop, the close guard and Restart PC

**Files:**
- Modify: `src/Toolbox/RepairPage.ps1`, `src/Toolbox/RepairPlanner.ps1`, `src/Toolbox/Toolbox.ps1`, `src/Engine/Reboot.ps1`, `src/Entry/Main.ps1`, `src/Common/Process.ps1` (doc only), `src/Toolbox/Strings.ps1` (`childNoResult`, `childStartFailed`).
- Test: `tests/RepairPage.Tests.ps1`, `tests/RepairPlanner.Tests.ps1`, `tests/Toolbox.Tests.ps1`, `tests/Entry.Tests.ps1`, `tests/RepairStatic.Tests.ps1`.

**Interfaces:**
- Consumes: `Start-BackgroundExternal`, `Stop-ProcessTree`, `Read-ToolJsonFile`, `Write-ToolJsonFile`, `Get-MachineIdentity`, `Get-LauncherInfo`, `Find-SetupStick`, `$script:ToolActionCatalog`, the Task 3 model and view.
- Produces:
  - **`RepairPlanner.ps1`:** `Update-RepairRunModel -Repair <hashtable> -Progress <object> -ElapsedSeconds <int> -> hashtable` (steps, current, percent, log); `Complete-RepairRunModel -Repair -Result <object> -> hashtable` (`Run = $null`, `Result` set, an entry appended to `Done`, `Strip.State = 'loading'`); `New-RepairWindowResult -Repair -Outcome <'TimedOut'|'Failed'> -Code <string> -Arguments <object[]> -> hashtable` (the steps from the last progress, the running one `timedout`, the pending ones `skipped`; RED).
  - **`RepairPage.ps1`:**
    - `$script:ToolboxChildren` (a `List[object]` of the processes the window started).
    - `Get-ToolboxSessionDir -State <hashtable> -> string` (Shared shapes; the stick's `BenTech-Reports` or `<Root>\Logs\Repair`).
    - `Start-ToolboxRun -Window -ActionId <string> [-Options <hashtable>] [-Slot <'Action'|'Safety'>] -> bool`: refuses (`$false`, WARN) a busy slot or a window without Root/ScriptPath; creates `<Root>\Tool\<RunId>\`, writes `args.json` (Shared shapes; `Complaint` and `Done` from the model, `Strip` levels, `Identity`, the deadline `UtcNow + timeoutsMinutes.tool.<id>`, 30 when missing), calls `& $Tag.StartChild "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ToolAction {1} -ToolArgs "{2}"' -f ...)`, adds the process to `$script:ToolboxChildren`, stores `@{ ActionId; RunId; Process; Dir; StartedUtc; DeadlineUtc }` in `Tag.Runs.<Slot>` and, for the Action slot, `Model.Repair.Run` with every step of the catalog `pending`. A `StartChild` that throws: Result `Failed` with `childStartFailed` (ASCII message), WARN.
    - `Update-ToolboxRuns -Window -> void` (the run timer's tick; every 500 ms): for each busy slot, reads `progress.json` (Action slot: `Update-RepairRunModel`; Safety slot: `ConvertTo-RepairStrip` of `Partial.Chips`); when the process **has exited**: `result.json` -> `Complete-RepairRunModel` (or, without one, `New-RepairWindowResult -Outcome Failed -Code childNoResult -Arguments <exit code>`); when `UtcNow > DeadlineUtc + 1 min` and it still runs: `Stop-ProcessTree -ProcessId`, WARN `Toolbox action killed at its deadline`, `New-RepairWindowResult -Outcome TimedOut -Code actionTimedOut` (Safety slot: `ConvertTo-RepairStrip -Final $true` of the last partial chips). A finished slot is cleared and its process removed from `$script:ToolboxChildren`; a finished **action** logs one INFO line `Toolbox action finished` @{ action; runId; outcome; color; minutes; findings } (ASCII) and starts the safety child again. Re-renders with `Update-RepairView` only (**Plan call**: not the whole window every 500 ms).
    - `Request-ToolboxStop -Window -> void`: writes `<Dir>\stop.flag`, `Run.Stopping = $true` (the Stop button is disabled, `StoppingText` names the running step).
    - `Stop-ToolboxChildren -> void`: `Stop-ProcessTree` on every process in `$script:ToolboxChildren` that has not exited, then clears the list. Never throws.
    - `New-ToolboxRunTimer -Window -> DispatcherTimer`: `Interval` 500 ms, `Tag` the window, tick `Invoke-ToolboxAction -Sender $this -Action 'RunTick'`; started by `Show-ToolboxWindow` with the power timer.
  - **`Toolbox.ps1`:**
    - `Register-ToolboxHandlers`: `Add_Closing({ Invoke-ToolboxAction -Sender $this -Action 'Closing' -EventArgs $_ })`.
    - `Invoke-ToolboxAction`:
      - `Closing`: while `Tag.Runs.Action` is set and the Outcome is not `Failed`: `$EventArgs.Cancel = $true`, Outcome back to `$null`, `Model.Repair.CloseRefused = $true`, re-render; otherwise as today.
      - `RunTick` -> `Update-ToolboxRuns`; `Stop` -> `Request-ToolboxStop`.
      - `Start` (setup) and `Page` refused while an action runs (WARN `Start refused: an action is running`).
      - `Restart`: refused while an action runs; otherwise opens the `restart` confirmation; its `Confirm` calls `Close-ToolboxWindow -Outcome Restart` (Task 5 adds the confirmation panel's other kinds).
    - `Close-ToolboxWindow -Outcome` accepts `'Restart'`.
    - `New-ToolboxWindow` gains `-Root ''`, `-ScriptPath ''`, `-Launcher $null`, `-StartChild`, `-FindStick` (defaults as in `Show-ToolboxWindow`) and its `Tag` gains `Root; ScriptPath; Launcher; StartChild; FindStick; Runs = @{ Action = $null; Safety = $null }; RunTimer = $null`; `New-ToolboxModel` gains `[bool]$CanRun = $false` and `[string]$SessionStamp` (default: now, `yyyy-MM-dd_HHmm`, invariant), passed to `New-RepairModel`. `Show-ToolboxWindow` passes `CanRun = (Root and ScriptPath are not empty)`. Test windows set `Tag.RunTimer = New-ToolboxRunTimer` (never started).
    - `Show-ToolboxWindow` gains `[AllowEmptyString()][string]$Root = ''`, `[AllowEmptyString()][string]$ScriptPath = ''` and the seams `-Launcher { Get-LauncherInfo -Path $env:BT_SELF }`, `-FindStick { param($l) Find-SetupStick -Launcher $l }`, `-StartChild { param($file, $arguments) Start-BackgroundExternal -FilePath $file -ArgumentList $arguments }`, all kept in `Tag`; it starts the run timer, and its `finally` calls `Stop-ToolboxChildren` **before** `Close()`. The result gains `Outcome = 'Restart'`.
    - `Get-SetupChoices` gains `[AllowEmptyString()][string]$Root = ''`, `$ScriptPath = ''`, passed to `-ShowToolbox` only (the console keeps exactly Show-StartScreen's parameters); `$script:ToolboxRestartRequested = $false` at its start; its `finally` calls `Stop-ToolboxChildren` **before** `-ShutdownDispatcher`; `Restart`: INFO `Toolbox closed` @{ outcome = 'Restart' }, `$script:ToolboxRestartRequested = $true`, returns `$null`.
    - `Get-ToolboxRestartRequest -> bool`.
  - **`Reboot.ps1`:** `Invoke-StatelessRestart [-RestartAction { Restart-Computer -Force -ErrorAction Stop }] [-FallbackRestartAction <runs shutdown.exe /r /t 5 /f through Invoke-External, 1 minute; exit 0, 1115 or 1190 is success, else throws>] -> bool`: no state, no cap, no countdown (spec 6.9); both failing: `Write-Host 'Could not restart the PC: <ASCII>' -ForegroundColor White -BackgroundColor DarkRed`, `$false`. Never throws.
  - **`Main.ps1`:** `Get-SetupChoices ... -Root $Root -ScriptPath $ScriptPath`; on `$null`, `Restart = (Get-ToolboxRestartRequest)` joins the flow result (logged `Restart requested in the toolbox`); `Start-BenTechSetup` calls `Invoke-StatelessRestart` **after** its cleanup block when the outcome is `Cancelled` and `Restart` is set (with or without a cleanup: an earlier run's folder stays, the restart still happens). Never after a crash.
  - **`Process.ps1`:** `Start-BackgroundExternal`'s doc names its second caller (the toolbox's action child and "Open folder").

- [ ] **Step 1: Write the failing tests.**

  `tests/RepairPage.Tests.ps1`, new Describe (BeforeEach: `Write-SetupLog` into `$script:logs`; `Test-OnACPower { $true }`; `Stop-ProcessTree` records the id into `$script:killed` and `'kill:<id>'` into `$script:order`, and sets `$script:closingAtKill` from `$script:shown.Tag.Closing` when a window is shown; `$showArgs` = the Dell machine, `$cfg`, version, no previous run, not fresh, `-Root "$TestDrive\Root" -ScriptPath "$TestDrive\Root\setup.ps1"` and the seams `-OnAC { $true } -AdminProtection { 'Off' } -WorkArea { New-Object Windows.Rect 0, 0, 1920, 1040 } -Launcher { $null } -FindStick { param($l) @{ Root = 'E:\'; Drive = 'E:' } } -StartChild <the recorder below>`; `$script:ToolboxChildren` cleared; `$script:started` records each StartChild call as `@{ File; Args; Process }` and returns a new `[pscustomobject]@{ Id = <4242, 4243, ...>; HasExited = $false; ExitCode = 0 }`, also kept in `$script:fake` (so the first child of a test is 4242); `New-RunWindow` = `New-ToolboxWindow` with `-Root "$TestDrive\Root" -ScriptPath "$TestDrive\Root\setup.ps1"` and the seams, handlers registered, `-Page` (default `'repair'`), a ready strip; `$choiceArgs` = `Get-SetupChoices`' five parameters plus `-Root "$TestDrive\Root" -ScriptPath 'x' -TestHost { @{ Ok = $true } } -ShutdownDispatcher { } -ShowConsole { param($p) $null }`):
  ```powershell
  Describe 'action runs (spec 7, 4.3, 4.4)' {
    It 'starts the child hidden and without waiting, with the args the child reads' { $w = New-RunWindow; Start-ToolboxRun -Window $w -ActionId 'health' | Should -BeTrue
      $script:started[0].File | Should -BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
      $script:started[0].Args | Should -BeLike '-NoProfile -ExecutionPolicy Bypass -File "*\Root\setup.ps1" -ToolAction health -ToolArgs "*\Root\Tool\*-health\args.json"'
      $a = Read-ToolJsonFile (Get-ChildItem "$TestDrive\Root\Tool" -Recurse -Filter args.json).FullName; $a.Action | Should -Be 'health'; $a.Identity.Key | Should -Be 'SN-7HX2K93'
      $script:ToolboxChildren | Should -Contain $script:fake; @($w.Tag.Model.Repair.Run.Steps.Status | Select-Object -Unique) | Should -Be @('pending') }
    It 'polls progress into the run panel and ends on the result, with one ASCII log line' { <# write progress.json, RunTick; write result.json, fake.HasExited = $true, RunTick #>
      $w.Tag.Model.Repair.Result.Outcome | Should -Be 'Done'; @($script:logs | Where-Object Message -eq 'Toolbox action finished').Count | Should -Be 1
      $script:started[-1].Args | Should -Match '-ToolAction safety'; ($script:logs | ConvertTo-Json -Depth 5) | Should -Not -Match '[^\x00-\x7F]' }
    It 'kills the tree past the deadline and reports Timed out (red) with what was done' { <# DeadlineUtc 2 minutes ago, still running #> Invoke-ToolboxAction -Sender $w.Tag.RunTimer -Action 'RunTick'
      $script:killed | Should -Be @(4242); $w.Tag.Model.Repair.Result.Color | Should -Be 'RED'; $w.Tag.Model.Repair.Result.Steps.Status | Should -Be @('done','timedout','skipped') }
    It 'a child that exits without a result is Failed with childNoResult' { $w = New-RunWindow; $null = Start-ToolboxRun -Window $w -ActionId 'health'; $script:fake.HasExited = $true; $script:fake.ExitCode = 1
      Invoke-ToolboxAction -Sender $w.Tag.RunTimer -Action 'RunTick'; $res = $w.Tag.Model.Repair.Result
      $res.Outcome | Should -Be 'Failed'; $res.Color | Should -Be 'RED'; $res.Findings[0].Code | Should -Be 'childNoResult'; $res.Findings[0].Args | Should -Be @('1') }
    It 'Stop writes the flag and never kills (only between steps)' { Click $w 'StopButton'; Test-Path "$($w.Tag.Runs.Action.Dir)\stop.flag" | Should -BeTrue; $script:killed | Should -BeNullOrEmpty; $w.FindName('StopButton').IsEnabled | Should -BeFalse }
    It 'X, Alt+F4 and Cancel are refused while an action runs' { $w.Close(); $w.Tag.Outcome | Should -BeNullOrEmpty; $w.Tag.Closing | Should -BeFalse; $w.FindName('CloseRefusedText').Visibility | Should -Be 'Visible'
      Click $w 'CloseButton'; $w.Tag.Outcome | Should -BeNullOrEmpty }
    It 'a running safety child does not block closing, and is killed with the window' { <# Safety slot only #> $w.Close(); $w.Tag.Outcome | Should -Be 'Cancel' }
    It 'Start, the nav and Restart PC are refused while an action runs' { Click $w 'StartButton'; $w.Tag.Outcome | Should -BeNullOrEmpty; Click $w 'NavSetup'; $w.Tag.Model.Page | Should -Be 'repair'; Click $w 'RestartButton'; $w.Tag.Model.Repair.Confirm | Should -BeNullOrEmpty }
    It 'a Failed window closes even while a child runs' { Close-ToolboxWindow -Window $w -Outcome Failed -ErrorText 'x'; $w.Tag.Closing | Should -BeTrue }
  }
  Describe 'Show-ToolboxWindow and Get-SetupChoices with children' {
    It 'Show-ToolboxWindow kills its children before it closes the window' { # the ShowDialog seam starts a run and returns; Stop-ProcessTree records whether the window was already closing
      $r = Show-ToolboxWindow @showArgs -ShowDialog { param($w) $script:shown = $w; $null = Start-ToolboxRun -Window $w -ActionId 'health' }
      $r.Outcome | Should -Be 'Failed'; $script:killed | Should -Be @(4242); $script:closingAtKill | Should -BeFalse; $script:shown.Tag.Closing | Should -BeTrue }
    It 'a window that fails while a child runs kills it before the shutdown, the console and the cleanup (Review Focus 2)' {
      $r = Get-SetupChoices -Machine $m -Config $cfg -Version 'v' -Previous $null -IsFresh $false -Root "$TestDrive\Root" -ScriptPath 'x' -TestHost { @{ Ok = $true } } `
        -ShowToolbox { param($p) $script:ToolboxChildren.Add($script:fake); @{ Outcome = 'Failed'; Error = 'boom' } } -ShowConsole { param($p) $script:order.Add('console'); $null } -ShutdownDispatcher { $script:order.Add('shutdown') }
      $script:order | Should -Be @('kill:4242','shutdown','console') }
    It 'Restart returns $null and records the request; Cancel does not' {
      Get-SetupChoices @choiceArgs -ShowToolbox { param($p) @{ Outcome = 'Restart' } } | Should -BeNullOrEmpty; Get-ToolboxRestartRequest | Should -BeTrue
      Get-SetupChoices @choiceArgs -ShowToolbox { param($p) @{ Outcome = 'Cancel' } } | Should -BeNullOrEmpty; Get-ToolboxRestartRequest | Should -BeFalse }
    It 'the console still gets exactly Show-StartScreen''s parameters; the window gets Root and ScriptPath' {
      $null = Get-SetupChoices @choiceArgs -ShowToolbox { param($p) $script:toolboxArgs = $p; @{ Outcome = 'Failed'; Error = 'x' } } -ShowConsole { param($p) $script:consoleArgs = $p; $null }
      @($script:consoleArgs.Keys | Sort-Object) | Should -Be @('Config','IsFresh','Machine','NoAutoStart','Previous','Version'); $script:toolboxArgs.Root | Should -Be "$TestDrive\Root" }
  }
  ```
  `tests/Toolbox.Tests.ps1`: the static test `'calls ShowDialog only through the seam ...'` also reads `RepairPage.ps1`. `tests/RepairStatic.Tests.ps1`:
  ```powershell
  It 'the window''s files call no hang-prone cmdlet and never wait on a process (Review Focus 1)' {
    $banned = 'Get-PhysicalDisk','Get-StorageReliabilityCounter','Repair-Volume','Repair-WindowsImage','Get-Printer','Get-WindowsDriver','Get-PnpDevice','Get-NetAdapter','Get-NetIPAddress',
              'Get-NetIPConfiguration','Get-BitLockerVolume','Get-WinEvent','Invoke-External','Invoke-PowerShellChild','Invoke-ToolJsonChild','Wait-Process','Start-Sleep','Wait-SetupDelay'
    foreach ($f in Get-ChildItem "$PSScriptRoot\..\src\Toolbox" -Filter *.ps1) { <# CommandAst names not in $banned; text has no '.WaitForExit(' or '.WaitOne(' #> } }
  ```
  `tests/Entry.Tests.ps1` (`Invoke-StatelessRestart` and `Get-ToolboxRestartRequest` mocked in BeforeEach; `Invoke-StatelessRestart` records into `$script:order`, as does `Invoke-SetupCleanup`):
  ```powershell
  It 'Restart PC: the Cancel path, the cleanup, then a stateless restart' { Mock Get-SetupChoices { $null }; Mock Get-ToolboxRestartRequest { $true }
    Invoke-Entry | Should -Be 0; $script:order | Should -Be @('cleanup:Cancel','restart'); Should -Invoke Unregister-ResumeTask -Times 1 }
  It 'after an unfinished earlier run: no cleanup, still the restart' { <# Read-RunState returns a state #> $script:order | Should -Be @('restart') }
  It 'no restart after a crash, a plain Cancel or a run' { <# three cases #> Should -Invoke Invoke-StatelessRestart -Times 0 }
  It 'passes Root and ScriptPath to Get-SetupChoices' { Should -Invoke Get-SetupChoices -ParameterFilter { $Root -eq $TestDrive -and $ScriptPath -like '*\setup.ps1' } }
  ```
  `tests/ToolEngine.Tests.ps1` (Reboot): `'Invoke-StatelessRestart falls back to shutdown.exe /r /t 5 /f and accepts 1190'`, `'both failing is $false and one White on DarkRed line'`.
- [ ] **Step 2: Run** `RepairPage`, `RepairPlanner`, `Toolbox`, `Entry`, `ToolEngine`, `RepairStatic`. Expected: FAIL on the new tests only.
- [ ] **Step 3: Implement** the Produces list. Re-save with BOM.
- [ ] **Step 4: Run** those files, then the full suite. Expected: `Failed: 0`; the existing `Toolbox`/`Entry` tests pass unchanged except the documented filters.
- [ ] **Step 5: Review gate, then commit:** `feat: toolbox action runs: background child, deadline, Stop, close guard, Restart PC`.

---

### Task 5: The page at work: strip, stick, tiles, confirmations, complaint, and Health check end to end

**Files:**
- Modify: `src/Toolbox/RepairPlanner.ps1`, `src/Toolbox/RepairPage.ps1`, `src/Toolbox/Toolbox.ps1`.
- Test: `tests/RepairPlanner.Tests.ps1`, `tests/RepairPage.Tests.ps1`.

**Interfaces:**
- Consumes: Task 4's runs; `Get-RepairGate`; `Find-SetupStick` through `Tag.FindStick`; `Test-OnACPower` through `Tag.ReadOnAC`.
- Produces:
  - **`RepairPlanner.ps1`:**
    - `Test-RepairYes -Text <string> -> bool`: the trimmed text equals `YES` ignoring case, or equals the three code points `0x05D8 0x05E7 0x05D3` exactly.
    - `Update-RepairModel -Model <hashtable> -Action <string> [-Value <AllowNull object>] -> hashtable` (pure, returns a copy; `Value` is a string for the clicks and the info child's `Data` for `NetInfo` / `GhostItems`): `Tile <id>` (enabled by the gate: `Confirm = 'none'` and a stick -> `Pending = <id>` for the window to start; otherwise a confirmation of the catalog's kind, `Lines` = `tile.<id>.changes` + the gate's warns, `Typed = ''`; Network reset and Ghosts add `Loading = $true` until their info child answers); `YesText <text>`; `AtPc`; `BackedUp`; `GhostTick <index>`; `Complaint <text>` (cut to 2000); `Hover <id>` (`Selected`); `ConfirmCancel`; `Offer dismSource` (a confirmation with `Options` from `Result.Offers.DismSource` and its details, plus `result.buildDiffers` / `result.languageDiffers` when set); `NetInfo <data>` (`Loading = $false`, `Remote`, and one `confirm.static` line per static adapter: alias, then IP/prefix, gateway, DNS; or `confirm.noStatic`) / `GhostItems <data>` (every device that is not excluded becomes an item, `Ticked`; the excluded count goes into `confirm.ghostCount`); **`Tile netRestore`** lists **every value it will apply** from `Repair.NetBackup`, one `confirm.static` line per adapter, with `Options = @{ File; Sha256 }` (spec 6.6); `Confirm` -> `Pending` only when the gate still allows it, YES is right for a `yes` kind, `AtPc` is ticked when `Remote` shows any session, and at least one ghost is ticked.
  - **`RepairPage.ps1`:** `Update-ToolboxRuns` (Task 4) hands a finished **info** action (`netInfo`, `ghostList`) to the open confirmation instead of the result panel: `Update-RepairModel -Action NetInfo|GhostItems -Value <result.Data.NetInfo|Ghosts>`; no `Toolbox action finished` line and no safety refresh for them; one that failed or timed out closes the confirmation and shows its result (RED) instead. `Update-ToolboxStick -Window -> void` (on the power timer's tick, only on the repair page with no action running: `& $Tag.FindStick $Tag.Launcher`; a change is logged once, ASCII); `Open-ToolboxFolder -Window` (`& $Tag.StartChild "$env:windir\explorer.exe" ('"{0}"' -f <Result.Files.Folder>)`, not registered as a child).
  - **`Toolbox.ps1`:**
    - `Register-ToolboxHandlers` also wires `Add_TextChanged({ Invoke-ToolboxAction -Sender $this -Action 'Text' })` on `a:` TextBoxes and `Add_MouseEnter({ Invoke-ToolboxAction -Sender $this -Action 'Hover' })` on the ten tiles.
    - `Invoke-ToolboxAction`: `Text` reads `$Sender.Text` and the box's Tag action (`Complaint` or `YesText`); `Hover` reads the tile id from the sender's Tag; `Page repair` starts the safety child the first time; `Tile`, `AtPc`, `BackedUp`, `GhostTick`, `ConfirmCancel`, `Offer` go through `Update-RepairModel`, then: `Pending` -> `Start-ToolboxRun` with the confirmation's `Options` (`ghostRemove`: the ticked `InstanceId`s; `netRestore`: `@{ File; Sha256 }`; `dismSource`: `@{ Path; Type; Index }`), and an opened Network reset or Ghosts confirmation starts `netInfo` / `ghostList` in the Action slot; `OpenFolder` -> `Open-ToolboxFolder`. The Power tick also calls `Update-ToolboxStick`.

- [ ] **Step 1: Write the failing tests.**

  `tests/RepairPlanner.Tests.ps1`:
  ```powershell
  Describe 'Test-RepairYes (spec 4.2)' {
    It '<T> is <E>' -ForEach @(@{ T = 'YES'; E = $true }, @{ T = 'yes'; E = $true }, @{ T = ' yEs '; E = $true }, @{ T = ([string][char]0x05D8 + [char]0x05E7 + [char]0x05D3); E = $true }
      @{ T = 'YE'; E = $false }, @{ T = 'YESS'; E = $false }, @{ T = 'Y E S'; E = $false }, @{ T = ''; E = $false }) { Test-RepairYes -Text $T | Should -Be $E }
  }
  Describe 'Update-RepairModel' {
    It 'a read-only tile with a stick starts at once; without a stick it asks first' { (Update-RepairModel -Model $m -Action Tile -Value health).Repair.Pending | Should -Be 'health'
      $n = Update-RepairModel -Model (Set-NoStick $m) -Action Tile -Value health; $n.Repair.Pending | Should -BeNullOrEmpty; $n.Repair.Confirm.Lines | Should -Contain 'confirm.noStickLog' }
    It 'a destructive tile needs YES, and a raised Confirm without it starts nothing' { $n = Update-RepairModel -Model $m -Action Tile -Value wuReset; (Update-RepairModel -Model $n -Action Confirm).Repair.Pending | Should -BeNullOrEmpty
      $y = Update-RepairModel -Model $n -Action YesText -Value 'yes'; (Update-RepairModel -Model $y -Action Confirm).Repair.Pending | Should -Be 'wuReset' }
    It 'Network reset always demands the at-PC tick, with or without RDP (RD-R2)' { $n = Update-RepairModel -Model (Update-RepairModel -Model $m -Action Tile -Value netReset) -Action NetInfo -Value @{ Adapters = @(); Remote = @{ Rdp = $false } }
      $n = Update-RepairModel -Model $n -Action YesText -Value 'YES'; (Update-RepairModel -Model $n -Action Confirm).Repair.Pending | Should -BeNullOrEmpty
      (Update-RepairModel -Model (Update-RepairModel -Model $n -Action AtPc) -Action Confirm).Repair.Pending | Should -Be 'netReset' }
    It 'ghosts: every item ticked, untick one, the options carry the ticked ids only; none ticked cannot confirm' {
      $n = Update-RepairModel -Model (Update-RepairModel -Model $m -Action Tile -Value ghosts) -Action GhostItems -Value $threeGhosts   # 3 devices, one excluded (BTHENUM)
      @($n.Repair.Confirm.Items).Count | Should -Be 2; @($n.Repair.Confirm.Items.Ticked) | Should -Be @($true, $true)
      $n = Update-RepairModel -Model (Update-RepairModel -Model $n -Action GhostTick -Value 0) -Action YesText -Value 'yes'
      (Update-RepairModel -Model $n -Action Confirm).Repair.Confirm.Options.Ids | Should -Be @('USB\VID_0781&PID_5567\4C53')
      (Update-RepairModel -Model (Update-RepairModel -Model $n -Action GhostTick -Value 1) -Action Confirm).Repair.Pending | Should -BeNullOrEmpty }
    It 'Restore network settings lists every value it will apply and needs YES' { $n = Update-RepairModel -Model (Set-NetBackup $m) -Action Tile -Value netRestore
      ($n.Repair.Confirm.Lines -join "`n") | Should -Match '192\.168\.1\.10/24.*192\.168\.1\.1.*8\.8\.8\.8'; $n.Repair.Confirm.Kind | Should -Be 'yes' }
    It 'a gate that closed after the panel opened refuses the Confirm' { $n = Update-RepairModel -Model $m -Action Tile -Value standard; $n.Repair.Strip.Restart = @{ Level = 'crit' }
      (Update-RepairModel -Model $n -Action Confirm).Repair.Pending | Should -BeNullOrEmpty }
    It 'the complaint is kept to 2000 characters, Hebrew and all' { $t = ('ק' * 2100); $c = (Update-RepairModel -Model $m -Action Complaint -Value $t).Repair.Complaint
      $c.Length | Should -Be 2000; $c[0] | Should -Be 'ק' }
  }
  ```
  `tests/RepairPage.Tests.ps1`:
  ```powershell
  Describe 'the page at work' {
    It 'the first visit to the page starts the safety child; the strip loads chip by chip' { $w = New-RunWindow -Page 'setup'; Click $w 'NavRepair'; $script:started[0].Args | Should -Match '-ToolAction safety'
      <# progress.Partial.Chips with Restart only, RunTick #> $w.FindName('ChipRestartText').Text | Should -Be 'No restart pending'; $w.FindName('ChipDiskText').Text | Should -Be 'Checking...' }
    It 'a safety child that never finishes is killed at its deadline; its missing chips are unknown and block nothing (Review Focus 1)' {
      <# Safety slot past DeadlineUtc + 1 min, Partial has Restart ok #> $script:killed | Should -Be @(4242); $w.Tag.Model.Repair.Strip.Disk.Level | Should -Be 'unknown'
      $w.FindName('TileStandard').IsEnabled | Should -BeTrue }
    It 'Network reset and Ghost devices are disabled without a stick (Review Focus 3)' { <# FindStick returns no root, Power tick #> $w.FindName('TileNetReset').IsEnabled | Should -BeFalse; $w.FindName('TileGhosts').IsEnabled | Should -BeFalse
      $before = $script:started.Count; ClickTag $w 'a:Tile:netReset'; $script:started.Count | Should -Be $before }   # nothing starts, not even netInfo
    # RD-R3: the 5-second check is a cheap presence seam (Tag.StickPresent, default an [IO.DriveInfo] scan of Removable/Fixed non-system drives with BenTechSetup.cmd in the root, Network and CD-ROM skipped); FindStick (CIM) runs only when the presence answer changes. Adapt this test so $script:sticks counts FindStick calls after a presence change, and add a test that an unchanged presence never calls FindStick.
    It 'the stick is re-checked every 5 s on the page while nothing runs, and not during an action' { $script:sticks = 0; $w.Tag.FindStick = { param($l) $script:sticks++; @{ Root = 'F:\'; Drive = 'F:' } }
      Invoke-ToolboxAction -Sender (New-ToolboxPowerTimer -Window $w) -Action 'Power'; $script:sticks | Should -Be 1; $w.FindName('ChipStickText').Text | Should -Be 'Stick F:'
      $null = Start-ToolboxRun -Window $w -ActionId 'health'; Invoke-ToolboxAction -Sender (New-ToolboxPowerTimer -Window $w) -Action 'Power'; $script:sticks | Should -Be 1 }
    It 'typing YES (or the Hebrew-layout YES) enables Confirm; Confirm starts the action' { ClickTag $w 'a:Tile:diskCheck'; $w.FindName('ConfirmButton').IsEnabled | Should -BeFalse
      $w.FindName('YesBox').Text = 'yes'; $w.FindName('ConfirmButton').IsEnabled | Should -BeTrue; Click $w 'ConfirmButton'; $script:started[-1].Args | Should -Match '-ToolAction diskCheck' }
    It 'Health check end to end: tile, live steps, findings in colour, files, Open folder, Restart PC' {
      ClickTag $w 'a:Tile:health'; <# progress: volumeScan done, imageCheck running; RunTick #> $w.FindName('RunSteps').Children.Count | Should -Be 7
      <# result YELLOW with sfcCorrupt; exited; RunTick #> $w.FindName('ResultFindings').Children[0].Foreground | Should -Be $w.FindResource('WarnBrush')
      Click $w 'OpenFolderButton'; $script:started[-1].File | Should -BeLike '*\explorer.exe'; $script:ToolboxChildren | Should -Not -Contain $script:started[-1].Process
      Click $w 'RestartButton'; Click $w 'ConfirmButton'; $w.Tag.Outcome | Should -Be 'Restart' }
    It 'the complaint reaches the child''s args (UTF-8) and never setup.log' { $w.FindName('ComplaintBox').Text = 'המחשב נכבה'; ClickTag $w 'a:Tile:health'
      $argsPath = ($script:started[-1].Args -replace '.*-ToolArgs "([^"]+)".*', '$1'); (Read-ToolJsonFile $argsPath).Complaint | Should -Be 'המחשב נכבה'; ($script:logs | ConvertTo-Json -Depth 5) | Should -Not -Match '[^\x00-\x7F]' }
    It 'hovering a tile shows what it does' { Invoke-ToolboxAction -Sender $w.FindName('TileWuReset') -Action 'Hover'; $w.FindName('WhatText').Text | Should -Match 'SoftwareDistribution' }
  }
  ```
- [ ] **Step 2: Run** `RepairPlanner`, `RepairPage`. Expected: FAIL on the new tests.
- [ ] **Step 3: Implement** the Produces list. Re-save with BOM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0`. With Tasks 1-5 the Health check works end to end on the page; the other tiles say "Not available in this version".
- [ ] **Step 5: Review gate, then commit:** `feat: repair page: safety strip, gates, confirmations and Health check`.

---

### Task 6: Standard repair, Post-clone and the DISM source retry

**Files:**
- Create: `src/Repair/ToolRepairs.ps1`, `tests/ToolRepairs.Tests.ps1`.
- Modify: `src/Repair/ToolEngine.ps1` (rows `standard`, `postClone`, `dismSource` and their steps), `src/Toolbox/Strings.ps1` (Task 6 findings), `tools/Build-Bundle.ps1`.

**Interfaces:**
- Consumes: Tasks 1-2 (`Invoke-ToolNative`, `Invoke-ToolJsonChild`, `Read-ToolSfcResult`, `Get-ToolWinReState`, `Resolve-WinReVerdict`, `Get-ToolProblemDevices`, `Get-ToolActivation`, `Test-ToolInternet`, the Health steps `volumeScan`, `devices`, `activation`), `Resolve-Brand`.
- Produces (`ToolRepairs.ps1`):
  - `$script:DismSourceFailureCodes = @(0x800F081F, 0x800F0906, 0x800F0950)` and `$script:DismPendingCode = 0x800F082F` (compared as `[uint32]` bits of the exit code).
  - `Invoke-ToolStepTimeSync`: `w32time`'s start type from `Get-Service` (Disabled -> `timeServiceDisabled`, no sync); `sc.exe start w32time` (exit 0 or 1056) and up to `toolStep.service` minutes for Running (`Wait-SetupDelay` polls); `w32tm.exe /resync` (`timeSync`); exit non-zero -> `timeSyncFailed`; then `Test-ToolInternet`'s clock offset: above `clockOffsetMinutes` -> `clockOff` (minutes, one decimal); no offset -> `clockUnknown` (spec 6.2).
  - `Invoke-ToolStepDism`: `dism.exe /Online /Cleanup-Image /RestoreHealth` through `Invoke-ToolNative -StepTimeout dism -OutputName dism`:
    - 0 -> `done`; 3010 -> `dismRestart`, `RestartRequired`;
    - a source code -> `dismSourceMissing` + `Find-ToolInstallSource` -> `Offers.DismSource`, or `dismNoSource` (**the retry is never run here**: spec 6.2, builder check 6);
    - `$script:DismPendingCode` -> `restartFirst`;
    - timeout -> `stepTimedOut`; anything else -> `dismFailed`. `$Run.Data.DismOk`.
  - `Find-ToolInstallSource -Run -> hashtable|$null`: candidates `<StickRoot>\sources\install.wim|esd` and `<root>\sources\install.wim|esd` of every `[IO.DriveInfo]` of DriveType CDRom or Removable that `IsReady`; one grandchild per file (`Get-WindowsImage -ImagePath` then `-Index` for each, giving `EditionId`, `Architecture`, `Languages`, `Version`); the first index whose `EditionId` equals the PC's `EditionID` (registry) **and** whose architecture matches `Machine.Arch` (0 x86, 9 x64, 12 ARM64; a mismatch is never offered; **Plan call**). `BuildDiffers` = the image's build differs from the OS build; `LanguageDiffers` = its `Languages` lack the PC's install language (`Nls\Language\InstallLanguage` as a culture name). `.swm` files are not supported (**Plan call**).
  - `Invoke-ToolStepDismSource`: `Options` re-validated (`Path` is `<X>:\sources\install.wim|esd` and exists, `Type` is `wim`|`esd`, `Index` 1..99), then `dism.exe /Online /Cleanup-Image /RestoreHealth /Source:<Type>:<Path>:<Index> /LimitAccess`, judged like `dism`.
  - `Invoke-ToolStepSfc`: `sfc.exe /scannow` (`sfc`), `Read-ToolSfcResult` since its start; `Repaired > 0` and `CannotRepair = 0` -> **one** second pass, `sfcRepaired` (`'ran clean'` or `'still repaired files'`); `CannotRepair > 0` -> `sfcCannotRepair`, plus `dismAndSfcFailed` when `Data.DismOk` is `$false`; not run -> `sfcNotRun`; timeout -> `sfcTimedOut` (TrustedInstaller keeps going; nothing else is killed).
  - `Invoke-ToolStepWinreFix`: `Get-ToolWinReState`; `CanEnable` -> `reagentc.exe /enable` (exit 0 -> read the BCD again -> `winreEnabled`, else `winreEnableFailed`); Off without agreement -> `winreNoAgreement`; Unknown -> `winreUnknown`; On -> done (spec 6.1, 6.2.5).
  - Post-clone: `Invoke-ToolStepPnpScan` (`pnputil.exe /scan-devices`, exit 0 or 3010; else `pnpScanFailed`); `Invoke-ToolStepOemLeftovers` (`Get-ToolInstalledPrograms` = the machine Uninstall keys (64- and 32-bit) and the signed-in user's `HKEY_USERS\<SID>` view, the SID from `Get-SignedInUserName` translated, never the elevated HKCU (review I-12; **Plan call**); `Get-ToolOemLeftovers -Programs -Brand -Config -> string[]` (pure): brand `OTHER`, `VM` or `SAMSUNG` -> `oemSkipped`; else every program matching another brand's `oemUtilities` pattern -> `oemLeftover` with up to five names); `Invoke-ToolStepPageFile` (`Win32_PageFileSetting` names on a drive that `Test-Path` cannot find -> `pageFileMissingDrive`); `Invoke-ToolStepTrim` (registry `HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem` `DisableDeleteNotification` not 0 -> `trimOff`, **never changed** (**Plan call**: spec 6.3 lists the state only); a grandchild reads the system disk's `MediaType` and runs `Optimize-Volume -ReTrim` on SSD or `-Analyze` on HDD, timeout `retrim`; failure -> `retrimFailed`); `Invoke-ToolStepComponentCleanup` (grandchild `Repair-WindowsImage -Online -StartComponentCleanup -NoRestart`, timeout `componentCleanup`, never `-ResetBase`; failure -> `componentCleanupFailed`); `Invoke-ToolStepWuScan` (Internet crit in `Args.Strip` -> `wuScanSkipped`; else a grandchild `Microsoft.Update.Session` search `IsInstalled=0 and IsHidden=0` -> `updatesAvailable` with the count, failure -> `wuScanFailed`; **Plan call**: a WUA search, not `UsoClient`, so the result is known).

- [ ] **Step 1: Write the failing tests** (`tests/ToolRepairs.Tests.ps1`; SAFETY header; fixtures set in `BeforeEach`:
  - `Invoke-ToolNative` answers `@{ ExitCode = $script:exit[<file name>] (0 by default); TimedOut = ($null -eq that) }` and records the file name in `$script:native`, `'<file name> <args>'` in `$script:nativeLines` and the arguments in `$script:nativeArgs`;
  - `Invoke-ToolJsonChild` answers `$script:gc[<Name>]` (Ok) and records each command in `$script:gcCommands[<Name>]`;
  - `Read-ToolSfcResult` dequeues `$script:sfc` (one result per pass); `Get-ServicingRebootSignals` reads `$script:pending`, which `$script:pendingAfter = '<step>'` turns on once that step has run;
  - `Get-Service` answers `$script:services[<name>]`; `Test-ToolInternet` answers `ClockOffsetSeconds = $script:offsetSeconds`; `Get-ItemProperty` reads `$script:reg`; `Set-ItemProperty`, `New-ItemProperty` and `New-Item` are recorders (never called by these steps);
  - `New-ActionRun <action>` = `New-ToolRun` on a valid args hashtable for that action in `$TestDrive` (stick `E:\`, all chips ok)):
  ```powershell
  Describe 'Standard repair (spec 6.2)' {
    It 'keeps the kit''s order: time, disk scan, DISM, SFC, WinRE' { $null = Invoke-ToolSteps -Run (New-ActionRun standard); $script:native | Should -Be @('sc.exe','w32tm.exe','dism.exe','sfc.exe') }
    It 'DISM exit <C> -> <F>' -ForEach @(@{ C = 0; F = ''; R = $false }, @{ C = 3010; F = 'dismRestart'; R = $true }, @{ C = -2146498529; F = 'dismSourceMissing'; R = $false }, @{ C = 5; F = 'dismFailed'; R = $false }, @{ C = $null; F = 'stepTimedOut'; R = $false }) {
      $script:exit['dism.exe'] = $C; $r = New-ActionRun standard; $null = Invoke-ToolStepDism -Run $r
      @($r.Findings | Where-Object { $_.Code -like 'dism*' -or $_.Code -eq 'stepTimedOut' } | ForEach-Object Code) | Should -Be @($F | Where-Object { $_ }); $r.RestartRequired | Should -Be $R }
    It 'DISM 0x800F082F (a servicing restart pending) is "restart first"' { $script:exit['dism.exe'] = -2146498513; $r = New-ActionRun standard; $null = Invoke-ToolStepDism -Run $r; $r.Findings.Code | Should -Be @('restartFirst') }
    It 'a source failure offers the found install.wim with its details and never retries by itself' { <# Find-ToolInstallSource mocked #> $r.Offers.DismSource.Path | Should -Be 'E:\sources\install.wim'; @($script:native | Where-Object { $_ -eq 'dism.exe' }).Count | Should -Be 1 }
    It 'DISM leaving a servicing restart pending stops before SFC with "restart first" (yellow)' { $script:pendingAfter = 'dism'; Invoke-ToolSteps -Run $r | Should -Be 'NeedsRestart'; $script:native | Should -Not -Contain 'sfc.exe' }
    It 'SFC runs a second pass only when the first one repaired something (review I-3)' { $script:sfc = @(@{ Ran = $true; Repaired = 0; CannotRepair = 0 }); @($script:native -eq 'sfc.exe').Count | Should -Be 1
      $script:sfc = @(@{ Ran = $true; Repaired = 2 }, @{ Ran = $true; Repaired = 0 }); @($script:native -eq 'sfc.exe').Count | Should -Be 2 }
    It 'reagentc /enable runs only when the BCD and ReAgent.xml both say off' { <# Off+Off -> enable; Off+Missing -> winreNoAgreement and no reagentc; On+Off -> winreUnknown and no reagentc #> }
    It 'a disabled time service is reported, never changed; a clock still 3 min off warns' { $script:services['w32time'] = @{ Status = 'Stopped'; StartType = 'Disabled' }
      $r = New-ActionRun standard; $null = Invoke-ToolStepTimeSync -Run $r; $r.Findings.Code | Should -Contain 'timeServiceDisabled'; $script:native | Should -BeNullOrEmpty
      $script:services['w32time'] = @{ Status = 'Running'; StartType = 'Manual' }; $script:offsetSeconds = 180; $r = New-ActionRun standard; $null = Invoke-ToolStepTimeSync -Run $r
      $r.Findings | Where-Object Code -eq 'clockOff' | ForEach-Object { $_.Args } | Should -Be @('3.0') }
  }
  Describe 'Post-clone (spec 6.3)' {
    It 'runs Standard''s steps, then the post-clone steps, with pnputil /scan-devices here' { $r = New-ActionRun postClone; $null = Invoke-ToolSteps -Run $r
      @($r.Steps.Id) | Should -Be @('timeSync','volumeScan','dism','sfc','winreFix','pnpScan','devices','oemLeftovers','pageFile','trim','activation','componentCleanup','wuScan')
      $script:nativeLines | Should -Contain 'pnputil.exe /scan-devices' }
    It 'flags another brand''s system utility, never printer software, and skips a whitebox' { Get-ToolOemLeftovers -Programs @('HP Smart','HP Support Assistant','Dell Display Manager') -Brand 'DELL' -Config $cfg | Should -Be @('HP Support Assistant')
      Get-ToolOemLeftovers -Programs @('Dell SupportAssist') -Brand 'OTHER' -Config $cfg | Should -BeNullOrEmpty }
    It 'TRIM off is reported, the registry is never written; ReTrim on SSD, Analyze on HDD' { $script:reg['DisableDeleteNotification'] = 1; $script:gc['media'] = @{ Media = 'SSD' }
      $r = New-ActionRun postClone; $null = Invoke-ToolStepTrim -Run $r; $r.Findings.Code | Should -Contain 'trimOff'; Should -Invoke Set-ItemProperty -Times 0; Should -Invoke New-ItemProperty -Times 0
      $script:gcCommands['retrim'] | Should -Match '-ReTrim'; $script:gc['media'] = @{ Media = 'HDD' }; $null = Invoke-ToolStepTrim -Run (New-ActionRun postClone); $script:gcCommands['retrim'] | Should -Match '-Analyze' }
    It 'component cleanup never resets the base' { $script:gcCommands['componentCleanup'] | Should -Match 'StartComponentCleanup'; $script:gcCommands['componentCleanup'] | Should -Not -Match 'ResetBase' }
    It 'no internet skips the update scan' { $r = New-ActionRun postClone; $r.Args.Strip.Internet = 'crit'; $null = Invoke-ToolStepWuScan -Run $r
      $r.Findings.Code | Should -Be @('wuScanSkipped'); Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'wuScan' } }
  }
  Describe 'DISM with a local source' {
    It 'runs /Source:wim:E:\sources\install.wim:6 /LimitAccess, then SFC' { $script:nativeArgs[0] | Should -Be '/Online /Cleanup-Image /RestoreHealth /Source:wim:E:\sources\install.wim:6 /LimitAccess' }
    It 'refuses options that are not a sources\install file on a drive root' { <# 'E:\x\install.wim', index 0, type 'swm' -> stepFailed, no dism #> }
    It 'Find-ToolInstallSource matches EditionID and architecture, and flags a build or language that differs' {
      # one install.wim on E: with index 1 Core x64, index 6 Professional x64 en-US build 26100, index 7 Professional ARM64; the PC: Professional x64 he-IL build 26200
      $s = Find-ToolInstallSource -Run (New-ActionRun standard); $s.Index | Should -Be 6; $s.Arch | Should -Be 'x64'; $s.BuildDiffers | Should -BeTrue; $s.LanguageDiffers | Should -BeTrue
      <# with only index 7 (ARM64): $null #> }
  }
  ```
- [ ] **Step 2: Run** `ToolRepairs`. Expected: FAIL.
- [ ] **Step 3: Implement** the Produces list, the catalog rows, the strings (en + he), `$BundleOrder` `'Repair\ToolRepairs.ps1'`. Re-save with BOM.
- [ ] **Step 4: Run** `ToolRepairs`, `Bundle`, `RepairStatic`, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Review gate, then commit:** `feat: Standard repair, Post-clone and the DISM source retry`.

---

### Task 7: Windows Update reset, Disk check at restart, Network reset and Ghost devices

**Files:**
- Create: `src/Repair/ToolAdvanced.ps1`, `tests/ToolAdvanced.Tests.ps1`, fixtures `netbackup-valid.json`, `netbackup-bad.json`.
- Modify: `src/Repair/ToolEngine.ps1` (rows of the eight actions and `safetyNetBackup`; the runner's `Abort` / `AlwaysRun` rule), `src/Repair/ToolSafety.ps1` (the step), `src/Toolbox/Strings.ps1`, `tools/Build-Bundle.ps1`.
- Test: also `tests/ToolEngine.Tests.ps1`, `tests/RepairStatic.Tests.ps1`.

**Interfaces:**
- Consumes: Tasks 1-2 helpers; `Test-StickReparsePoint`; `Get-MachineIdentity`.
- Produces (`ToolAdvanced.ps1`):
  - **Windows Update reset (spec 6.4):** `$script:WuResetServices = @('wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc', 'dosvc')`.
    - `wuServicesStop` records each service's `Status` and `StartType` (`Get-Service`) in `Data.Services`, reports Disabled `wuauserv`/`bits`/`cryptsvc`/`usosvc` as `wuServiceDisabled` (never changed; review I-13), then, in the list's order, `sc.exe stop <name>` for each one that is Running (exit 0 or 1062) and up to `toolStep.service` minutes for Stopped (`wuServiceStopFailed`).
    - `wuRename`: `%windir%\SoftwareDistribution` and `%windir%\System32\catroot2` -> `<name>.bak-<yyyyMMdd-HHmmss>` with `Rename-Item -LiteralPath -NewName -ErrorAction Stop`, up to 3 tries 3 s apart (services stopped again between); a reparse point is never renamed; `wuRenamed` / `wuRenameFailed`. **Nothing is deleted.**
    - `wuBits`: a grandchild that removes only the `Get-BitsTransfer -AllUsers` jobs with a file whose `LocalName` is under `%windir%\SoftwareDistribution\` (the path, never the job's localized name; **Plan call**) -> `wuBitsCleared` count / `wuBitsFailed`.
    - `wuServicesStart` (its `$script:ToolSteps` row has `AlwaysRun = $true`, so it runs even after a Stop, an `Abort` or the deadline; **Plan call**: review I-2, the kit could leave the update services stopped): starts, in reverse order, each service that was Running before and is not Disabled (`sc.exe start`, exit 0 or 1056; up to `toolStep.service` minutes) -> `wuServiceStartFailed`.
    - `wuScan` is Task 6's step (skipped without internet, spec 5).
  - **Disk check at restart (spec 6.5, ruling RD-R1):** `diskCheckSchedule`: `fsutil.exe dirty set <SystemDrive>`; success = exit 0 **and** `Win32_Volume.DirtyBitSet` true afterwards (`fsutil dirty query`'s exit code is logged only) -> `diskCheckScheduled`, `RestartRequired`; else `diskCheckNotScheduled`. **There is no cancel action and no `chkntfs` call.**
  - **Network (spec 6.6):**
    - `Get-ToolNetSettings -Run -> hashtable[]` (grandchild): per `Get-NetAdapter` `@{ Alias; Guid; Mac; Ipv4Dhcp; Ipv6Dhcp; Addresses = @( @{ Ip; Prefix } ) (PrefixOrigin Manual); Gateways (PersistentStore routes 0.0.0.0/0 and ::/0); Dns (the `NameServer` registry value of `Tcpip\Parameters\Interfaces\<Guid>` and `Tcpip6\...`) }`.
    - `Test-ToolRemoteSession [-TerminalServerSession <scriptblock>] -> @{ Rdp }`: RDP = the seam, by default `[System.Windows.Forms.SystemInformation]::TerminalServerSession`. **Ruling RD-R2:** AnyDesk and ScreenConnect are not detected, and the Network reset confirmation **always** requires the at-PC tick; a detected RDP session only turns its warning red.
    - `netInfo` step: `Data.NetInfo = @{ Adapters = <the static ones>; Remote }`.
    - `netBackup`: writes `<session>\network-backup-<yyyyMMdd-HHmmss>.json` (`@{ Version = 1; CreatedAt; Identity = @{ Key; ComputerName }; Adapters }`) with `Write-ToolJsonFile`, then reads it back and compares (`ConvertTo-Json -Compress` of both equal); a session folder that is the local fallback (no stick, or a link) or any failure -> `netBackupFailed` and **the step returns `failed` with `$Run.Data.Abort = $true`**, which the runner honours like a Stop: the remaining steps are `skipped` (**Plan call**: a step can end its action). Else `netBackupSaved`.
    - `winsockReset` (`netsh.exe winsock reset`), `ipReset` (`netsh.exe int ip reset`), `ipv6Reset` (`netsh.exe int ipv6 reset`), `dnsFlush` (`ipconfig.exe /flushdns`): exit codes only, `netResetStepFailed` on non-zero; then `restartRequired`, `RestartRequired`. **No `/release`, no `/renew`.**
    - `Test-ToolNetBackup -Value <object> -IdentityKey <string> -> hashtable|$null` (pure): `Version` 1, the identity key equal, at most 16 adapters, each `Guid` a GUID, `Mac` `([0-9A-F]{2}-){5}[0-9A-F]{2}`, every `Ip`/gateway/DNS parsing as `[ipaddress]` (re-rendered with `.ToString()`), `Prefix` 0..32 (IPv4) or 0..128 (IPv6). `Find-ToolNetBackup -StickRoot -IdentityKey -> @{ Path; Sha256; CreatedAt; Adapters }|$null`: the newest valid `BenTech-Reports\*\network-backup-*.json` (under 1 MB, no link) for this PC; `safetyNetBackup` puts it in `Data.NetBackup`.
    - `netRestore`: the file's SHA-256 must equal `Options.Sha256` (else `netRestoreRefused`), `Test-ToolNetBackup` must pass (else `netRestoreInvalid`); per adapter (matched by `Guid`, else `Mac`) one grandchild with the validated values as literals: `Set-NetIPInterface -Dhcp Disabled` per family with static addresses, `New-NetIPAddress` (the first with `-DefaultGateway`), `Set-DnsClientServerAddress`; per-adapter failures `netRestoreFailed`; `netRestored`. DHCP adapters are left alone.
  - **Ghost devices (spec 6.7):** `$script:GhostExcludedPrefixes = @('BTHENUM\', 'BTHLE\', 'BTHLEDEVICE\', 'BTHHFENUM\', 'SWD\MMDEVAPI\', 'SWD\PRINTENUM\', 'WSDPRINT\')`, `$script:GhostExcludedClasses = @('Bluetooth', 'Printer', 'PrintQueue', 'AudioEndpoint')`.
    - `Test-GhostExcluded -Device <hashtable> -Ancestors <hashtable[]> -> string` (pure; `''` = keep, else the reason `bluetooth`|`audio`|`printer`|`wsd-ipp`): a listed prefix or class; an `InstanceId` whose first or second segment contains `WSD` or `IPP` (**Plan call**: wider than the exact enumerators, which are unknown until the VM; over-excluding only removes less); an ancestor that is Bluetooth by prefix or class.
    - `ghostList` (grandchild, timeout `ghostList`): every non-present `Get-PnpDevice` with its `DEVPKEY_Device_Parent` chain (up to 10 levels, through the full device list) -> `Data.Ghosts = @( @{ InstanceId; Class; Name; Excluded = <reason> } )`.
    - `ghostCsv`: every device of the list with a `Status` column (`remove`, `kept` or `excluded (<reason>)`) through `ConvertTo-Csv -NoTypeInformation`, written UTF-8 **with BOM** (Excel shows Hebrew names; review: the kit's ASCII CSV turned them into `?`) to `<session>\ghost-devices-<yyyyMMdd-HHmmss>.csv`, then read back (line count = devices + 1); a local-fallback folder or any failure -> `ghostCsvFailed`, `Data.Abort` (nothing removed).
    - `ghostRemove`: lists again and removes only the `Options.Ids` that are still non-present and not excluded: `pnputil.exe /remove-device "<id>"` (timeout `pnputil`); 0 or 3010 is success (3010 also `RestartRequired`); an id holding `"` is skipped; `ghostsRemoved` / `ghostRemoveFailed`.
  - **Engine change (`Invoke-ToolSteps`):** `$Run.Data.Abort -eq $true` after a step ends the action like a Stop (the rest `skipped`, outcome `Done`, RED through the step's own CRIT). A step whose `$script:ToolSteps` row has `AlwaysRun = $true` still runs after a Stop, an Abort or the deadline (its waits shrink to the 0.25-minute floor of `Get-ToolStepTimeout`), and the outcome stays the one that ended the others.

- [ ] **Step 1: Write the failing tests** (`tests/ToolAdvanced.Tests.ps1`; SAFETY header; the Task 6 recorders (`$script:native`, `$script:nativeLines`, `$script:gc`, `$script:gcCommands`, `$script:services`, `$script:reg`) plus: `Rename-Item` records into `$script:renamed` and succeeds only when `$script:renameOk` (default `$true`); `Get-CimInstance Win32_Volume` answers `DirtyBitSet = $script:dirty`; `$script:onStep` runs before each step (a seam in the fake step wrapper); `New-ActionRun <action> [-Options <hashtable>] [-Break <'the write fails'|'the read-back differs'|'no stick: the local fallback folder'>]` (the last one gives `Data.SessionIsLocal = $true`; the other two make `Write-ToolJsonFile` return `$false` or `Read-ToolJsonFile` answer a different object); the `ghostList` grandchild answers a fixed list holding a Hebrew-named Bluetooth headset (`אוזניות של דנה`); `$valid` / `$bad` are copies of `netbackup-valid.json` / `netbackup-bad.json` in the session folder and `$validObject` the parsed valid one; `Set-JsonValue <object> <path> <value>` returns a changed copy):
  ```powershell
  Describe 'Windows Update reset (spec 6.4)' {
    It 'stops the running services, renames both folders, clears the update jobs, starts what was running, then scans' {
      # every service Running/Automatic except msiserver Stopped/Manual
      $null = Invoke-ToolSteps -Run (New-ActionRun wuReset)
      @($script:nativeLines | Where-Object { $_ -like 'sc.exe *' }) | Should -Be @('sc.exe stop wuauserv','sc.exe stop bits','sc.exe stop cryptsvc','sc.exe stop usosvc','sc.exe stop dosvc',
        'sc.exe start dosvc','sc.exe start usosvc','sc.exe start cryptsvc','sc.exe start bits','sc.exe start wuauserv')
      @($script:renamed.NewName) | Should -Match '^(SoftwareDistribution|catroot2)\.bak-\d{8}-\d{6}$'; @($script:renamed).Count | Should -Be 2; $script:gcCommands.Keys | Should -Contain 'wuScan' }
    It 'a Disabled wuauserv is reported and left Disabled' { $script:services['wuauserv'] = @{ Status = 'Stopped'; StartType = 'Disabled' }; $r = New-ActionRun wuReset; $null = Invoke-ToolSteps -Run $r
      $r.Findings.Code | Should -Contain 'wuServiceDisabled'; $script:nativeLines | Should -Not -Contain 'sc.exe start wuauserv'; @($script:nativeLines | Where-Object { $_ -like 'sc.exe config*' }).Count | Should -Be 0 }
    It 'the services start again even when the rename fails, and after a Stop' { $script:renameOk = $false; $null = Invoke-ToolSteps -Run (New-ActionRun wuReset); $script:nativeLines | Should -Contain 'sc.exe start wuauserv'
      $r = New-ActionRun wuReset; $script:onStep = { if ($args[0] -eq 'wuServicesStop') { 'x' | Set-Content $r.StopPath } }
      Invoke-ToolSteps -Run $r | Should -Be 'Stopped'; $r.Steps | Where-Object Id -eq 'wuServicesStart' | ForEach-Object Status | Should -Be 'done' }
    It 'clears only jobs whose files are under SoftwareDistribution' { $script:gcCommands['wuBits'] | Should -Match 'SoftwareDistribution'; $script:gcCommands['wuBits'] | Should -Not -Match 'DisplayName' }
  }
  Describe 'Disk check at restart (spec 6.5)' {
    It 'fsutil dirty set, confirmed by DirtyBitSet: scheduled and a restart needed' { $script:dirty = $true; $r = New-ActionRun diskCheck; $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -Be @('fsutil.exe dirty set C:'); $r.Findings.Code | Should -Be @('diskCheckScheduled'); $r.RestartRequired | Should -BeTrue }
    It 'exit 0 but no dirty bit is not scheduled (CRIT)' { $script:dirty = $false; $r = New-ActionRun diskCheck; $null = Invoke-ToolSteps -Run $r; $r.Findings.Code | Should -Be @('diskCheckNotScheduled'); $r.RestartRequired | Should -BeFalse }
    It 'chkntfs appears nowhere in src (RD-R1)' { @(Get-ChildItem "$PSScriptRoot\..\src" -Recurse -Filter *.ps1 | Select-String -Pattern 'chkntfs' -SimpleMatch).Count | Should -Be 0 }
  }
  Describe 'Network reset and restore (spec 6.6)' {
    It 'saves the settings as JSON, checks them, then runs the four resets; never /release or /renew' { $r = New-ActionRun netReset; $null = Invoke-ToolSteps -Run $r
      $script:nativeLines | Should -Be @('netsh.exe winsock reset','netsh.exe int ip reset','netsh.exe int ipv6 reset','ipconfig.exe /flushdns')
      (Read-ToolJsonFile (Get-ChildItem "$($r.SessionDir)\network-backup-*.json").FullName).Adapters[0].Addresses[0].Ip | Should -Be '192.168.1.10'; $r.RestartRequired | Should -BeTrue }
    It 'no verified backup, no reset: nothing after the backup step runs (Review Focus 3)' -ForEach @(@{ Why = 'the write fails' }, @{ Why = 'the read-back differs' }, @{ Why = 'no stick: the local fallback folder' }) {
      $r = New-ActionRun netReset -Break $Why; $null = Invoke-ToolSteps -Run $r; $script:nativeLines | Should -BeNullOrEmpty; $r.Findings.Code | Should -Contain 'netBackupFailed'; $r.Steps.Status[1..4] | Should -Be @('skipped','skipped','skipped','skipped') }
    It 'restore refuses a file that changed after it was shown, or that is not valid' { $r = New-ActionRun netRestore -Options @{ File = $valid; Sha256 = ('0' * 64) }; $null = Invoke-ToolSteps -Run $r
      $r.Findings.Code | Should -Be @('netRestoreRefused'); Should -Invoke Invoke-ToolJsonChild -Times 0
      $r = New-ActionRun netRestore -Options @{ File = $bad; Sha256 = (Get-FileHash $bad).Hash }; $null = Invoke-ToolSteps -Run $r; $r.Findings.Code | Should -Be @('netRestoreInvalid') }
    It 'Test-ToolNetBackup rejects <Why>' -ForEach @(@{ Why = 'a bad IP'; Path = 'Adapters[0].Addresses[0].Ip'; V = '192.168.1.300' }, @{ Why = 'prefix 33'; Path = 'Adapters[0].Addresses[0].Prefix'; V = 33 }
      @{ Why = 'another PC''s key'; Path = 'Identity.Key'; V = 'SN-OTHER' }, @{ Why = 'a MAC with colons'; Path = 'Adapters[0].Mac'; V = 'A4:BB:6D:12:34:56' }, @{ Why = 'a GUID that is not one'; Path = 'Adapters[0].Guid'; V = 'x' }) {
      Test-ToolNetBackup -Value (Set-JsonValue $validObject $Path $V) -IdentityKey 'SN-7HX2K93' | Should -BeNullOrEmpty }
    It 'Test-ToolNetBackup accepts the valid fixture and 16 adapters, not 17' { Test-ToolNetBackup -Value $validObject -IdentityKey 'SN-7HX2K93' | Should -Not -BeNullOrEmpty }
    It 'restore applies the static values per adapter by GUID, then MAC, as validated literals' { $script:gcCommands['netApply-1'] | Should -Match "New-NetIPAddress -InterfaceIndex \d+ -IPAddress '192\.168\.1\.10' -PrefixLength 24 -DefaultGateway '192\.168\.1\.1'" }
    It 'the remote-session check names RDP, AnyDesk or ScreenConnect' { Mock Get-Process { if ($Name -eq 'AnyDesk') { [pscustomobject]@{ Id = 1 } } }
      $s = Test-ToolRemoteSession -TerminalServerSession { $false }; $s.AnyDesk | Should -BeTrue; $s.Rdp | Should -BeFalse; $s.ScreenConnect | Should -BeFalse }
  }
  Describe 'Ghost devices (spec 6.7)' {
    It 'leaves out <Why>' -ForEach @(@{ Why = 'BTHENUM'; Id = 'BTHENUM\{0000110b...}_LOCALMFG&0002\7&1' }, @{ Why = 'BTHLE'; Id = 'BTHLE\DEV_A1B2C3' }, @{ Why = 'BTHLEDEVICE'; Id = 'BTHLEDEVICE\{0000180f...}' }
      @{ Why = 'BTHHFENUM'; Id = 'BTHHFENUM\BthHFPAudio\8&1' }, @{ Why = 'an audio endpoint'; Id = 'SWD\MMDEVAPI\{0.0.0.00000000}.{guid}' }, @{ Why = 'a print queue'; Id = 'SWD\PRINTENUM\{guid}' }
      @{ Why = 'a WSD printer'; Id = 'WSDPRINT\HPOFFICEJET\1&2' }, @{ Why = 'an IPP device'; Id = 'SWD\IPPENUM\{guid}' }, @{ Why = 'a HID child of a Bluetooth keyboard'; Id = 'HID\{00001124...}_VID&0002046D\8&1'; Parent = 'BTHENUM\{00001124...}' }) {
      Test-GhostExcluded -Device @{ InstanceId = $Id; Class = 'HIDClass' } -Ancestors @($(if ($Parent) { @{ InstanceId = $Parent; Class = 'Bluetooth' } })) | Should -Not -BeNullOrEmpty }
    It 'keeps an old USB disk and an old network adapter' { Test-GhostExcluded -Device @{ InstanceId = 'USBSTOR\DISK&VEN_SANDISK\4C53&0'; Class = 'DiskDrive' } -Ancestors @(@{ InstanceId = 'USB\VID_0781&PID_5567\4C53'; Class = 'USB' }) | Should -BeExactly ''
      Test-GhostExcluded -Device @{ InstanceId = 'PCI\VEN_8086&DEV_15BC\3&11583659&0&FE'; Class = 'Net' } -Ancestors @() | Should -BeExactly '' }
    It 'writes the CSV as UTF-8 with BOM, Hebrew names intact, before anything is removed' { $r = New-ActionRun ghostRemove -Options @{ Ids = @('USB\VID_0781&PID_5567\4C53') }; $null = Invoke-ToolStepGhostCsv -Run $r
      $csv = (Get-ChildItem $r.SessionDir -Filter 'ghost-devices-*.csv').FullName; $b = [IO.File]::ReadAllBytes($csv); $b[0..2] | Should -Be @(0xEF,0xBB,0xBF)
      [IO.File]::ReadAllText($csv) | Should -Match 'אוזניות של דנה'; $script:nativeLines | Should -BeNullOrEmpty }
    It 'a device list that cannot be saved removes nothing (Review Focus 3)' { $r = New-ActionRun ghostRemove -Options @{ Ids = @('USB\VID_0781&PID_5567\4C53') } -Break 'no stick: the local fallback folder'
      $null = Invoke-ToolSteps -Run $r; $script:nativeLines | Should -BeNullOrEmpty; $r.Findings.Code | Should -Contain 'ghostCsvFailed' }
    It 'removes only ticked ids that are still non-present and not excluded; 3010 is success' { # the list: the USB stick (ghost), a Bluetooth headset (excluded), a device that is present again
      $script:exit['pnputil.exe'] = 3010; $r = New-ActionRun ghostRemove -Options @{ Ids = @('USB\VID_0781&PID_5567\4C53', 'BTHENUM\{0000110b}_X\7&1', 'PCI\VEN_10EC&DEV_8168\4&1') }
      $null = Invoke-ToolSteps -Run $r; $script:nativeLines | Should -Be @('pnputil.exe /remove-device "USB\VID_0781&PID_5567\4C53"'); $r.Findings.Code | Should -Contain 'ghostsRemoved'; $r.RestartRequired | Should -BeTrue }
  }
  ```
  `tests/RepairStatic.Tests.ps1`: the read allow-list gains `Invoke-ToolStepGhostCsv` (it reads back its own CSV); `/release` and `/renew` are already refused by Task 1's text scan; add `'the ghost exclusion lists hold every enumerator of spec 6.7'` (the seven prefixes and four classes exactly).
- [ ] **Step 2: Run** `ToolAdvanced`. Expected: FAIL.
- [ ] **Step 3: Implement** the Produces list, the engine change, the catalog rows (`AlwaysRun` on `wuServicesStart`), the strings, `$BundleOrder` `'Repair\ToolAdvanced.ps1'`. Re-save with BOM.
- [ ] **Step 4: Run** `ToolAdvanced`, `ToolEngine`, `Bundle`, `RepairStatic`, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Review gate, then commit:** `feat: Windows Update reset, disk check at restart, network reset and ghost devices`.

---

### Task 8: The Quick and Full reports

**Files:**
- Create: `src/Repair/ToolCollect.ps1`, `src/Repair/ToolReport.ps1`, `tests/ToolReport.Tests.ps1`, fixtures `report-sections-sample.json` (collector output for one PC, with Hebrew event messages and program names), `report-sections-huge.json` (10 000 event groups).
- Modify: `src/Repair/ToolEngine.ps1` (rows `quickReport`, `fullReport`), `src/Toolbox/Strings.ps1`, `tools/Build-Bundle.ps1`.
- Test: also `tests/RepairStatic.Tests.ps1`.

**Interfaces:**
- Consumes: Tasks 1-7 readers (the chips, `Get-ToolBcdState`, `Get-ToolReAgentState`, `ConvertFrom-CbsSrText`, `Get-ToolProblemDevices`, `Get-ToolInstalledPrograms`, `Get-ToolOemLeftovers`, `Test-ToolInternet`, `Get-ToolNetSettings`), `Get-ActivationStatus`, `Get-SmartAppControlState`, `Format-ReportDate`, `Get-MachineIdentity`.
- Produces:
  - **`ToolCollect.ps1`:** `Get-ReportData<NN> -Run -Quick <bool> -> @{ Id = '<NN>'; Title; Facts = [ordered]; Groups = @( <string lines> ); Items = @{ ... structured, for flags and the data JSON }; Raw = @( <file names under raw\> ); Missing = @( @{ What; Why } ) }`, one per section, and the steps `Invoke-ToolStepReport<NN>` that store it in `$Run.Data.Report['<NN>']`. **Every source is language-independent and bounded** (timeouts in `toolStep`); a source that times out or fails is a `Missing` entry (`notCollected`), never a failed section (review Minor: one failing fact no longer loses section 01). Sources:

    | NN | Section | Sources | Quick skips |
    |---|---|---|---|
    | 01 | System | registry `CurrentVersion` (name corrected by build, DisplayVersion, build.UBR, EditionID, InstallDate), CIM computer/OS/BIOS (`-OperationTimeoutSec 30`), uptime, clock offset (`Test-ToolInternet`, run once per report and kept in `Data.Internet` for section 09), servicing restart signals, .NET release; raw `systeminfo` (native) | systeminfo |
    | 02 | Hardware | BIOS, board, CPU, `Win32_PhysicalMemory` sum, GPU (`Win32_VideoController`, `InfFilename display.inf` = basic display), monitors (`WmiMonitorID` serials), batteries (`root\wmi` full/design, summed per battery), `Confirm-SecureBootUEFI`, `Win32_Tpm`, `Win32_DeviceGuard` | monitors |
    | 03 | Storage | the disk grandchildren (Task 2), `Win32_Volume` (free, dirty bit), TRIM value, BitLocker types, page file, restore points (`root\default SystemRestore`), the disk events; Full: the volume scan (only when the Disk chip is not red; **Plan call**: no heavy scan on a failing disk), raw `vssadmin list shadows` / `shadowstorage` | scan, vssadmin |
    | 04 | Boot and recovery | `Get-ToolBcdState` (WinRE, safeboot), ReAgent.xml, EFI/recovery partitions (`MSFT_Partition` by GptType), boot times (Diagnostics-Performance 100 `Properties`), 6005/6006/6008/41/1074 counts | |
    | 05 | Windows Update | `Win32_QuickFixEngineering` newest 40, last search/install success (`Microsoft.Update.AutoUpdate` `.Results`, grandchild), WU policy values, services' start types, last SFC (`ConvertFrom-CbsSrText`), WindowsUpdateClient events; Full: CBS.log and dism.log error lines condensed (`Read-ToolLogErrors`: `, Error`, `HRESULT = 0x8`, `[SR] Cannot repair`), raw copies, `Get-WindowsUpdateLog` in a grandchild (`wuLog`) to raw | logs |
    | 06 | Drivers and devices | problem devices (Task 2), ghost count by class; Full: `Get-WindowsDriver -Online` (grandchild, `drivers`) third-party list + core drivers older than 6 years, setupapi.dev.log `!!!` lines condensed + raw, Kernel-PnP events | drivers, setupapi |
    | 07 | Events and crashes | `ConvertTo-EventGroups` of System and Application errors/warnings (`eventDays`, Quick `quickEventDays`, `-MaxEvents 5000`); Kernel-Power 41 with `BugcheckCode` (0 = power loss or hang); BugCheck 1001 grouped by code from `Properties`; WHEA by ID and level (fatal 1, 18, 20, 46 or level 1-2; corrected 17, 19, 47); 6008; minidumps (list; Full copies the newest 10 to raw); Application Error 1000 by app/module (`Properties`); hangs 1002; Full: `Win32_ReliabilityRecords` with a WQL `TimeGenerated >` filter (grandchild), evtx export (`wevtutil epl`, 14 days) to raw | reliability, evtx, dumps copy |
    | 08 | Performance and power | perf counters (two samples 1 s apart, the second kept; review I-10), top 15 processes by CPU and by memory, active power scheme GUID (registry); Full: `powercfg /batteryreport`, `/sleepstudy`, `/energy /duration 30` to raw | raw reports |
    | 09 | Network | `Get-ToolNetSettings`, connection profiles, firewall profiles (grandchild), Wi-Fi network names (registry `NetworkList\Profiles\*\ProfileName`), user proxy (signed-in SID's hive), hosts file (count + first 20 active lines), `Get-NetTCPConnection` grouped by owning process and state (counts, no remote addresses in the core), SMBv1 (`mrxsmb10` start value); connectivity: Quick **one** bounded test (the `Data.Internet` of section 01), Full TCP 443 to `login.microsoftonline.com`, `outlook.office365.com`, `update.microsoft.com`, `download.windowsupdate.com`, `www.google.com` in parallel, 3 s each (`TcpClient.ConnectAsync`) | the five-host test |
    | 10 | Software | installed programs (`Get-ToolInstalledPrograms`), installs of the last 30 days, OEM leftovers, Office Click-to-Run (version, channel by GUID), OneDrive (signed-in hive: version and account e-mail), startup items (Run keys, startup folders), non-Microsoft scheduled tasks and non-Windows services **by executable only, never their arguments** (review section 3: arguments hold tokens), automatic services not running (the kit's ignore list); Full: Appx (all users), optional features, printers (`Get-Printer`, grandchild, `printers`) | Appx, features, printers |
    | 11 | Security | Defender (`Get-MpComputerStatus`, grandchild), `root\SecurityCenter2` products, UAC values, Smart App Control (`Get-SmartAppControlState`), local users (`Win32_UserAccount LocalAccount=True`), **Guest by SID `-501`**, **Administrators by SID `S-1-5-32-544`** (`Get-LocalGroupMember -SID`, falling back to ADSI on the translated name), AutoAdminLogon (presence only), RDP and NLA values, join state (`CloudDomainJoin\JoinInfo`, `PartOfDomain`); Full: `gpresult /h` to raw, `dsregcmd /status` to raw | gpresult, dsregcmd |
    | 12 | msinfo32 | Full only: `msinfo32 /nfo` and `/report` to raw (`msinfo32` each) | all |
  - **`ToolReport.ps1`:**
    - `ConvertTo-EventGroups -Events <object[]> -> string[]` (pure): grouped by provider + ID + level, newest group first, `'{0}x {1}/{2} [{3}] {4} - {5}  {6}'` (count, provider, ID, level number, first and last `dd/MM/yyyy HH:mm`, the newest message with whitespace collapsed, cut to 200 characters).
    - `Get-ReportFlags -Report <hashtable> -Config -> hashtable[]` (pure): every Task 8 finding of the table, from `Items` and the thresholds (`kernelPower` at `kernelPowerWarn` or more, `appCrashes` at `appCrashesWarn`, `lowRam` under `ramMinGB`, `ghostDevicesMany` above `ghostDevicesInfo`, `uptimeLong` above `uptimeDays`, `batteryWear` at `batteryWearPercent`, `defenderSignatureOld` above `defenderSignatureDays`, `clockOff` above `clockOffsetMinutes`), plus the Health codes the sections reproduce (`volume*`, `winre*`, `notActivated`, `devicesProblem`, `oemLeftover`). Each finding also names its section.
    - `Format-ReportCore -Report <hashtable> -Kind <'quick'|'full'> -> string[]` (pure): the header (kind, `dd/MM/yyyy HH:mm`, version, PC, model, serial), `CUSTOMER COMPLAINT` (the complaint as typed, or `(none)`), `THIS VISIT` (`Args.Done`: action, outcome, colour, time; **Plan call** from review 4.2), `== 00 SUMMARY ==` (key facts, then the findings CRIT > WARN > INFO with their section), then each section: `== NN TITLE ==`, its facts as `name = value`, its findings, its grouped lines, `Missing` lines; and at the end a fixed English `HOW TO USE` paragraph for the AI (**Plan call**, review 4.7).
    - `Limit-ReportCore -Lines <string[]> -Sections <hashtable> -MaxBytes <int> -> string[]` (pure): while the UTF-8 size is above `MaxBytes - 2048`, cut grouped lines from the largest section first, leaving `(<n> lines cut to fit; full text in raw\<file>)`; the header, summary, facts and findings are never cut.
    - `Invoke-ToolStepReportWrite`: the stamp `yyyy-MM-dd_HHmm` of the report's start (a second one in the same minute gets `_2`); writes `REPORT_<PC>_<stamp>.txt` (UTF-8 **with BOM**, **Plan call**: Notepad shows Hebrew right), `REPORT_<PC>_<stamp>_data.json` (`@{ Version = 1; Kind; CreatedAt; Identity; Facts; Findings (Code, Level, Args); Disks (serial -> wear, errors); FreeGB; ProblemDevices (id, name); Programs (name|version); Crashes (times of 41, 1001, WHEA) }`) and the raw files under `raw_<stamp>\`; the findings also go into the run's findings (so the window shows them); `Files.Report`, `Files.Data`.
    - `Invoke-ToolStepReportZip` (Full): `raw_<stamp>\` into `REPORT_<PC>_<stamp>_raw.zip` (`System.IO.Compression.ZipFile.CreateFromDirectory`).
    - `Read-ToolLogErrors -Path -MaxLines -> string[]` (on the read allow-list).
  - **`ToolCollect.ps1`** also: `Test-ToolTcpHosts -Hosts <string[]> -Seconds <int> [-Connect <scriptblock>] -> hashtable` (host -> bool, all started together, each `ConnectAsync(...).Wait(Seconds * 1000)`).

- [ ] **Step 1: Write the failing tests** (`tests/ToolReport.Tests.ps1`; SAFETY header; the Task 6 recorders; `Test-ToolInternet` and `Test-ToolTcpHosts` mocked as recorders; `$sample` = `report-sections-sample.json` as a report hashtable (`Sections`, `Items`, `Complaint`, `Done`; one scheduled task `@{ Name = 'Agent'; Execute = 'C:Agentgent.exe'; Arguments = '--token abc /password x' }` as the grandchild returns it, Hebrew event messages such as `השירות נעצר`), `$huge` = `report-sections-huge.json`; `Set-ReportItem <report> <item> <value>` returns a changed copy; `$core` = `Format-ReportCore -Report $sample -Kind full`; `New-ActionRun fullReport [-SameMinute <run>]` (the same report stamp as `<run>`) and `$r` = one such run with `$sample` in `Data.Report`):
  ```powershell
  Describe 'flags (spec 6.8, review I-10)' {
    It '<Code> fires at <At> and not at <Below>' -ForEach @(
      @{ Code = 'kernelPower'; Item = 'KernelPower41'; At = 3; Below = 2 }, @{ Code = 'appCrashes'; Item = 'AppCrashes'; At = 10; Below = 9 }, @{ Code = 'lowRam'; Item = 'RamGB'; At = 7.9; Below = 8 }
      @{ Code = 'batteryWear'; Item = 'BatteryWear'; At = 40; Below = 39 }, @{ Code = 'defenderSignatureOld'; Item = 'SignatureAgeDays'; At = 8; Below = 7 }, @{ Code = 'clockOff'; Item = 'ClockOffsetMinutes'; At = 2.1; Below = 2.0 }
      @{ Code = 'diskWear'; Item = 'Wear'; At = 80; Below = 79 }, @{ Code = 'diskTemp'; Item = 'Temperature'; At = 60; Below = 59 }, @{ Code = 'uptimeLong'; Item = 'UptimeDays'; At = 8; Below = 7 }
      @{ Code = 'ghostDevicesMany'; Item = 'GhostCount'; At = 151; Below = 150 }) {
      (Get-ReportFlags -Report (Set-ReportItem $sample $Item $At) -Config $cfg).Code | Should -Contain $Code
      (Get-ReportFlags -Report (Set-ReportItem $sample $Item $Below) -Config $cfg).Code | Should -Not -Contain $Code }
    It 'WHEA: corrected IDs are a WARN with a count, fatal ones a CRIT' { $f = Get-ReportFlags -Report (Set-ReportItem $sample 'Whea' @(@{ Id = 17; Level = 3 }, @{ Id = 19; Level = 3 }, @{ Id = 18; Level = 1 })) -Config $cfg
      ($f | Where-Object Code -eq 'wheaCorrected').Args[0] | Should -Be '2'; ($f | Where-Object Code -eq 'wheaFatal').Level | Should -Be 'CRIT' }
    It 'Kernel-Power 41 with BugcheckCode 0 is a power loss, not a blue screen' { $f = Get-ReportFlags -Report (Set-ReportItem $sample 'KernelPower41Events' @(@{ BugcheckCode = 0 }, @{ BugcheckCode = 0 }, @{ BugcheckCode = 0 })) -Config $cfg
      $f.Code | Should -Contain 'kernelPower'; $f.Code | Should -Not -Contain 'bugchecks' }
    It 'a disabled device (CM 22) and Ntfs 140 are never flagged; disk 7, 51, 153 and Ntfs 55 are' { $f = Get-ReportFlags -Report (Set-ReportItem $sample 'DiskEvents' @('Ntfs/140')) -Config $cfg; $f.Code | Should -Not -Contain 'diskEvents'
      foreach ($e in 'disk/7','disk/51','disk/153','Ntfs/55') { (Get-ReportFlags -Report (Set-ReportItem $sample 'DiskEvents' @($e)) -Config $cfg).Code | Should -Contain 'diskEvents' } }
    It 'Guest and Administrators are found by SID on a Hebrew PC' { Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_UserAccount' } { [pscustomobject]@{ Name = 'אורח'; SID = 'S-1-5-21-1-2-3-501'; Disabled = $false; LocalAccount = $true } }
      $d = Get-ReportData11 -Run (New-ActionRun fullReport) -Quick $true; $d.Items.GuestEnabled | Should -BeTrue
      Should -Invoke Get-LocalGroupMember -ParameterFilter { $SID -eq 'S-1-5-32-544' }; (Get-ReportFlags -Report (Set-ReportItem $sample 'GuestEnabled' $true) -Config $cfg).Code | Should -Contain 'guestEnabled' }
  }
  Describe 'collectors' {
    It 'Quick skips every slow source and runs one connectivity test' { $r = New-ActionRun quickReport; foreach ($n in '01','02','03','04','05','06','07','08','09','10','11') { $null = & "Get-ReportData$n" -Run $r -Quick $true }
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -in 'drivers','printers','reliability','appx','features','wuLog' }
      Should -Invoke Test-ToolInternet -Times 1 -Exactly; Should -Invoke Test-ToolTcpHosts -Times 0 -Exactly; Should -Invoke Invoke-ToolNative -Times 0 }
    It 'a source that times out is "not collected", the section and the report still complete' { $script:gc['printers'] = @{ Ok = $false; TimedOut = $true; Error = 'timed out' }
      $d = Get-ReportData10 -Run (New-ActionRun fullReport) -Quick $false; $d.Missing.What | Should -Contain 'Printers'; $d.Facts.Count | Should -BeGreaterThan 0 }
    It 'scheduled tasks and services are listed without their arguments' { ($core -join "`n") | Should -Not -Match '--token|/password'; ($core -join "`n") | Should -Match 'agent\.exe' }
    It 'the Full disk scan is skipped when the Disk chip is red' { $r = New-ActionRun fullReport; $r.Args.Strip.Disk = 'crit'; $null = Get-ReportData03 -Run $r -Quick $false
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'volumeScan' } }
  }
  Describe 'the AI-ready core (spec 6.8)' {
    It 'holds the complaint, this visit, section 00 and the sections in order; dates are dd/MM/yyyy HH:mm under a Hebrew calendar' { <# thread culture he-IL with HebrewCalendar #>
      $l = Format-ReportCore -Report $sample -Kind full; $t = $l -join "`n"
      $t.IndexOf('CUSTOMER COMPLAINT') | Should -BeLessThan $t.IndexOf('THIS VISIT'); $t.IndexOf('THIS VISIT') | Should -BeLessThan $t.IndexOf('== 00 SUMMARY ==')
      $t.IndexOf('== 01 SYSTEM ==') | Should -BeLessThan $t.IndexOf('== 12 MSINFO32 =='); $l[0] | Should -Match '\d\d/\d\d/20\d\d \d\d:\d\d' }
    It 'stays under 150 KB with 10 000 event groups, keeping the summary and every finding' { $l = Limit-ReportCore -Lines (Format-ReportCore -Report $huge -Kind full) -Sections $huge.Sections -MaxBytes 153600
      [Text.Encoding]::UTF8.GetByteCount(($l -join "`r`n")) | Should -BeLessThan 153600; ($l -join "`n") | Should -Match '== 00 SUMMARY ==' }
    It 'keeps Hebrew event messages as UTF-8 with a BOM; headings and flags stay ASCII' { $null = Invoke-ToolStepReportWrite -Run $r; $b = [IO.File]::ReadAllBytes($r.Files.Report); $b[0..2] | Should -Be @(0xEF,0xBB,0xBF)
      $t = [IO.File]::ReadAllText($r.Files.Report); $t | Should -Match 'השירות'; @($t -split "`r`n" | Where-Object { $_ -match '^(==|\s*\[(CRIT|WARN|INFO)\])' -and $_ -match '[^\x00-\x7F]' }).Count | Should -Be 0 }
    It 'writes the data JSON, raw\ and (Full) the zip; a second report in the same minute gets _2' { $null = Invoke-ToolStepReportWrite -Run $r; $null = Invoke-ToolStepReportZip -Run $r
      Test-Path $r.Files.Data | Should -BeTrue; (Get-ChildItem $r.SessionDir -Filter '*_raw.zip').Count | Should -Be 1
      $r2 = New-ActionRun fullReport -SameMinute $r; $null = Invoke-ToolStepReportWrite -Run $r2; $r2.Files.Report | Should -Match '_2\.txt$' }
  }
  ```
  `tests/RepairStatic.Tests.ps1`: the allow-list gains `Read-ToolLogErrors` (English servicing logs) and `Get-ReportData09` (the hosts file); `'the report collectors call no localized-output tool'` (no `netstat`, `ipconfig /all`, `pnputil /enum`, `driverquery`, `net localgroup`, `net user`, `netsh wlan show`, `manage-bde`, `slmgr`, `bcdedit`, `reagentc /info` in `src\Repair`).
- [ ] **Step 2: Run** `ToolReport`, `RepairStatic`. Expected: FAIL.
- [ ] **Step 3: Implement** the Produces list, catalog rows, strings, `$BundleOrder` (`'Repair\ToolCollect.ps1'`, `'Repair\ToolReport.ps1'`). Re-save with BOM.
- [ ] **Step 4: Run** those files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Review gate, then commit:** `feat: Quick and Full diagnostic reports`.

---

### Task 9: The privacy-safe copy, Compare with last visit, and the docs

**Files:**
- Create: `src/Repair/ToolPrivacy.ps1`, `src/Repair/ToolCompare.ps1`, `tests/ToolPrivacy.Tests.ps1`, fixtures `report-earlier-data.json`, `report-whitebox-a.json`, `report-whitebox-b.json`.
- Modify: `src/Repair/ToolReport.ps1` (`reportWrite` writes the SAFE copy and the "since last visit" section), `src/Repair/ToolEngine.ps1` (row `compare`, step `safetyEarlier`), `src/Repair/ToolSafety.ps1`, `src/Toolbox/Strings.ps1`, `tools/Build-Bundle.ps1`, `README.md`, `docs/testing.md`, `CLAUDE.md`, `docs/specs/2026-10-21-toolbox-design.md` (one cross-reference line).

**Interfaces:**
- Consumes: Task 8's report data, `Get-MachineIdentity`, `Read-ToolJsonFile`, `Test-StickReparsePoint`.
- Produces:
  - **`ToolPrivacy.ps1`** (spec 6.8, Q33):
    - `Get-ReportIdentifiers -Report <hashtable> -> @{ User; Computer; Serial; Mac; Ip; Ssid; Email }` (the values the collectors saw: local user names, profile folder names, the signed-in user, the OneDrive e-mail; the computer name and new name; BIOS, board, disk, RAM, monitor and battery serials; adapter MACs; addresses, gateways, DNS; Wi-Fi network names).
    - `New-SafeMasker -Known <hashtable> -> hashtable`: tokens per category (numbered as `ConvertTo-SafeText` says): `user1`, `PC-1`, `SERIAL-1`, `MAC-1`, `IP-1`, `IP6-1`, `SSID-1`, `EMAIL-1`, `PHONE-1`. Known values shorter than 3 characters are ignored (**Plan call**).
    - `ConvertTo-SafeText -Masker <hashtable> -Text <string> -> string`: first the known values, longest first, case-insensitive (a serial inside the PC name is masked as the PC name, then everywhere else as the serial); then patterns: e-mail; MAC `([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}`; IPv4 `(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])` (every address except `0.0.0.0`, `127.0.0.1`, `255.255.255.255` and masks starting `255.`; a four-part version number such as `10.0.0.1` is masked too, the safe side); IPv6 (every address except `::` and `::1`); profile paths `[A-Za-z]:\\Users\\<name>` (the name as a user token); phone numbers `(?<!\d)(?:\+972[- ]?|0)(?:[23489]|5\d|7\d)[- ]?\d{3}[- ]?\d{4}(?!\d)`. Every IPv4 and IPv6 candidate is confirmed with `[ipaddress]::TryParse` before it is masked, so times such as `10:15:45` and version numbers stay. The same value always gets the same token in one report: known values are numbered in the order of the `-Known` lists, pattern finds in order of appearance; a MAC is keyed by its 12 hex digits in upper case and an IP by its parsed form, so every spelling of one value gets one token.
    - `reportWrite` writes `REPORT_SAFE_<stamp>.txt` (UTF-8 with BOM; **no PC name in the file name**, RD-R4): the core, the complaint included, through one masker.
  - **`ToolCompare.ps1`** (spec 6.8):
    - `Find-ToolEarlierReport -StickRoot <string> -IdentityKey <string> -CurrentSessionDir <string> -> object|$null`: the newest `BenTech-Reports\*\REPORT_*_data.json` (under 5 MB, not a link, not in the current session folder) whose `Identity.Key` **equals** the key; an empty key never matches (**different whiteboxes are never merged**).
    - `Compare-ToolReportData -Earlier <object> -Current <hashtable> -> hashtable` (pure): new crashes and WHEA errors (times after the earlier `CreatedAt`), disk wear and error changes (by disk serial), the free-space change, devices with problems added and gone, programs installed and removed (name|version), findings new and resolved (codes).
    - `Format-ToolSinceLastVisit -Diff -> string[]`: `SINCE LAST VISIT (dd/MM/yyyy HH:mm)` and one line per change, `(no changes)` when none. Quick and Full reports put it right after section 00 when an earlier report exists.
    - The `compare` step writes `COMPARE_<PC>_<stamp>.txt` and `COMPARE_SAFE_<stamp>.txt` (header, complaint, the section) and its data JSON, so it is a visit too (**Plan call**); `safetyEarlier` sets `Data.HasEarlierReport` for the Compare tile.
  - **Docs:** listed in Steps 5-7.

- [ ] **Step 1: Write the failing tests** (`tests/ToolPrivacy.Tests.ps1`; SAFETY header; `$stick` = a `$TestDrive` folder with `BenTech-Reports\<two earlier session folders>` holding the fixtures; `$current` = the current session folder; `$r` as in Task 8 (a Full report run of the Dell sample); `$earlier` = `report-earlier-data.json` (key `SN-7HX2K93`, `CreatedAt` `2026-10-01T09:00:00`, disk `S4EWNX0R123456` at 61% wear) and `$now` the current data (the same disk at 84%, one new BugCheck, one program removed); `report-whitebox-a.json` holds key `UUID-<A>` and `$whiteboxB` is a machine with serial `To Be Filled By O.E.M.` and UUID `<B>`):
  ```powershell
  Describe 'the SAFE copy (Q33)' {
    It 'the SAFE copy holds none of the identifiers, in any case or spelling, and tokens are stable (Review Focus 5)' {
      $known = @{ User = @('Dana', 'דנה כהן', 'admin_dana'); Computer = @('DELL-7HX2K93'); Serial = @('7HX2K93', 'S4EWNX0R123456'); Mac = @('A4-BB-6D-12-34-56'); Ip = @('192.168.1.10')
                  Ssid = @('Cohen_Home_5G'); Email = @('dana.cohen@example.co.il') }
      $text = @('PC DELL-7HX2K93 sn 7hx2k93', 'C:\Users\דנה כהן\AppData', 'mac a4:bb:6d:12:34:56 and A4-BB-6D-12-34-56', 'ip 192.168.1.10 gw 192.168.1.1 dns 2a00:1450:4001::8a',
                'Wi-Fi Cohen_Home_5G', 'mail DANA.COHEN@EXAMPLE.CO.IL', 'call 050-1234567 or +972 3 6123456', 'disk S4EWNX0R123456', 'user Dana logged on') -join "`n"
      $safe = ConvertTo-SafeText -Masker (New-SafeMasker -Known $known) -Text $text
      foreach ($v in @($known.Values | ForEach-Object { $_ }) + '7hx2k93', 'a4:bb:6d:12:34:56', '192.168.1.1', '2a00:1450:4001::8a', '050-1234567', '6123456') { $safe | Should -Not -Match ([regex]::Escape($v)) }
      $safe | Should -Match 'PC PC-1 sn SERIAL-1'; $safe | Should -Match 'mac MAC-1 and MAC-1'; $safe | Should -Match 'C:\\Users\\user\d\\AppData' }
    It 'keeps 127.0.0.1, 0.0.0.0, masks, ::1, times and versions so the AI can still read them' { $t = 'lo 127.0.0.1 any 0.0.0.0 mask 255.255.255.0 v6 ::1 at 10:15:45 build 10.0.26100.1'
      ConvertTo-SafeText -Masker (New-SafeMasker -Known @{}) -Text $t | Should -BeExactly $t }
    It 'masks e-mails and phone numbers inside the complaint' { $s = ConvertTo-SafeText -Masker (New-SafeMasker -Known @{}) -Text 'המחשב איטי, לחזור ל-054-7654321 או dana@gmail.com'
      $s | Should -BeExactly 'המחשב איטי, לחזור ל-PHONE-1 או EMAIL-1' }
    It 'reportWrite writes the SAFE copy beside the core, with no PC name in its file name (RD-R4)' { $null = Invoke-ToolStepReportWrite -Run $r
      $safe = @(Get-ChildItem (Split-Path $r.Files.Report) -Filter 'REPORT_SAFE_*.txt')[0].FullName
      Test-Path $safe | Should -BeTrue; (Split-Path $safe -Leaf) | Should -Not -Match '7HX2K93'; (Split-Path $safe -Leaf) | Should -Match '^REPORT_SAFE_\d{4}-\d{2}-\d{2}_\d{4}\.txt$'
      [IO.File]::ReadAllText($safe) | Should -Not -Match '7HX2K93'; [IO.File]::ReadAllText($r.Files.Report) | Should -Match '7HX2K93' }
  }
  Describe 'compare with last visit (spec 6.8)' {
    It 'finds the earlier report of the same serial, never the current session''s' { # the stick holds <session A>\REPORT_..._data.json (SN-7HX2K93, 01/10) and the current session's own (today)
      (Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current).CreatedAt | Should -Be '2026-10-01T09:00:00'
      Find-ToolEarlierReport -StickRoot $stick -IdentityKey '' -CurrentSessionDir $current | Should -BeNullOrEmpty }
    It 'two whiteboxes with the same placeholder serial are never merged' { Find-ToolEarlierReport -StickRoot $stick -IdentityKey (Get-MachineIdentity -Machine $whiteboxB).Key -CurrentSessionDir 'x' | Should -BeNullOrEmpty }
    It 'lists new crashes, disk wear, free space, devices, programs and findings' { (Format-ToolSinceLastVisit -Diff (Compare-ToolReportData -Earlier $earlier -Current $now)) | Should -Contain '  Disk S4EWNX0R123456: wear 61% -> 84%' }
    It 'ignores a data file that is too big, not JSON, or a link' { # three newer files of the same key: 6 MB, '{not json', and one in a folder Test-StickReparsePoint calls a link
      (Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current).CreatedAt | Should -Be '2026-10-01T09:00:00' }
  }
  ```
- [ ] **Step 2: Run** `ToolPrivacy`. Expected: FAIL.
- [ ] **Step 3: Implement** the Produces list, catalog rows, strings, `$BundleOrder` (`'Repair\ToolPrivacy.ps1'`, `'Repair\ToolCompare.ps1'`). Re-save with BOM.
- [ ] **Step 4: Run** `ToolPrivacy`, `ToolReport`, `Bundle`, then the full suite. Expected: `Failed: 0`. Review gate, then commit: `feat: privacy-safe report copy and compare with last visit`.
- [ ] **Step 5: `README.md`.** New section "Repair & diagnostics" after "The restore point": opening the page; the safety strip (each chip, what blocks what, unknown blocks nothing); the ten tiles and the two small buttons; confirmations (YES in any case, or `טקד` on the Hebrew layout; the at-PC tick; the backed-up tick); Stop (between steps only); the window cannot close while an action runs; Restart PC; where things are kept (`BenTech-Reports\<PC>_<serial>_<stamp>\`, the SAFE copy is the one to paste, never the full report; without a stick reports are disabled and logs are deleted by Cancel); online only (Ethernet or a hotspot first). "Changing apps and lists": `repair` (internet, freeSpace, thresholds, oemUtilities, reportMaxKB), `timeoutsMinutes.tool` / `toolStep`. "Development": `tools\Preview-Toolbox.ps1` renders eleven PNGs. Link the spec and this plan in the intro.
- [ ] **Step 6: `docs/testing.md`.** New `### 1.20 Repair & diagnostics (repair spec 14)` after 1.19, one checkbox per spec 14 item (a Hebrew Windows 11 VM for every language-independent verdict compared with English Windows; each repair end to end on a checkpoint with before/after and timing; DISM percent, Stop between steps, a timeout killing a stuck step; Network reset with a static IP, then Restore; Ghost devices with a paired, switched-off Bluetooth headset; Disk check scheduled, autochk at the next start, and Cancel; WinRE after a clone with a stale ReAgent.xml; pending restart with only a file rename (not red) and after a WU restart-needed update (red); the window lifecycle: X refused during an action, a forced failure kills the child before cleanup; the SAFE copy read end to end; Compare twice on one PC), plus "Proven by mocks only" (the deadline kill, the close guard, the backup-before-reset order, the CSV-before-removal order, the masking). Section 5 gains `(repair)` items: `fsutil dirty query`'s exit code; `chkntfs /x` lasting until `/d`; DISM's percent in redirected output; an absent `recoveryenabled`; the WSD/IPP enumerators of real ghosts; AnyDesk "running" read as connected; the stick check on the window's thread (a CIM query, 10 s limit, every 5 s on the page); CBS.log rotation during SFC; the SAFE file name holds the PC name.
- [ ] **Step 7: `CLAUDE.md`** and the spec cross-reference:
  - Hard rules: **two** exceptions to "every child goes through `Invoke-External`" (Office, and the toolbox's action child with its deadline on the window's timer; "Open folder" starts Explorer the same way); hang-prone cmdlets only in grandchildren; diagnostic reports on the stick are UTF-8 and may hold Hebrew, while setup.log, the child's log and the result files stay ASCII; the Hebrew YES lives as code points.
  - The toolbox window section: the second page, the files `RepairPlanner.ps1` / `RepairPage.ps1`, the run timer, `$script:ToolboxChildren` and `$script:ToolboxRestartRequested` as the new script-scope exceptions, the close guard, the fourth outcome Restart, eleven preview PNGs.
  - A short "Repair & diagnostics" section: the child entry (`-ToolAction`/`-ToolArgs`, Param list changed, the launcher unchanged), the catalogs in `ToolEngine.ps1`, the step contract, Stop between steps, `Abort`/`AlwaysRun`, never parsing tool text (the DISM percent is display only), the files of a run, the session folder.
  - Where things live: the repair spec, this plan, the ledger `.superpowers/sdd/2026-10-22-repair-diagnostics/progress.md`.
  - `docs/specs/2026-10-21-toolbox-design.md` header: `**Amended by:** [2026-10-22-repair-diagnostics-design.md](2026-10-22-repair-diagnostics-design.md) (the second page, the action child, Restart PC).`
- [ ] **Step 8: Verify:** the full suite, last line `Failed: 0`; `git diff --quiet main -- launcher keys; $LASTEXITCODE` is `0`; `git diff main -- src/Entry/Param.ps1` shows only the two new parameters. Build once into the scratchpad (`tools\Build-Bundle.ps1 -Version 2026.10.22.1 -OutDir <scratchpad>\bundle`): it builds and its markers list the nine `Repair\*.ps1` after `Report\Report.ps1`; **never run the bundle**.
- [ ] **Step 9: Review gate, then commit:** `docs: Repair & diagnostics (README, testing, CLAUDE.md, spec cross-reference)`. Then tell Ben: the branch is ready for docs/testing.md 1.20 on a Hebrew VM; publishing is his call.

---

## Spec coverage (self-review)

| Spec | Task |
|---|---|
| §1-3 why, decisions Q31-Q34, the flow for Ben | all; 9 (README) |
| §4.1 layout, strip, tiles, complaint, right column | 3 (look), 5 (behaviour) |
| §4.2 confirmations, YES / `טקד`, Restart asks | 5, 4 (Restart) |
| §4.3 Stop between steps, only timeouts kill | 1 (runner), 4 (window) |
| §4.4 locked while running, Failed kills first, the child guards itself | 4, 1 |
| §5 strip sources, gates, the strip in a child, unknown blocks nothing, the network pre-checks | 2, 3, 5, 7 |
| §6 bounded tools, grandchildren, RestoreHealth as dism.exe | 1, 2, 6 |
| §6.1 Health check; §6.2 Standard; §6.3 Post-clone | 2; 6; 6 |
| §6.4 WU reset; §6.5 disk check + Cancel; §6.6 network + Restore; §6.7 ghosts | 7 |
| §6.8 Quick, Full, sources, timeouts, core, SAFE, Compare, flags, encoding | 8, 9 |
| §6.9 Restart PC | 4 |
| §7 run model, files, polling, deadlines, Param, Start-BackgroundExternal, logs on the stick | 1, 4 |
| §8 where things are kept, no stick, the lock | 1 (session folder), 4, 5 |
| §9 online only | 9 (README) |
| §10 rules changed | 1 (Param), 4, 9 (CLAUDE.md) |
| §13 calls 1-23 | 1 (1, 7, 16), 2 (2, 13, 18, 22), 3-5 (3, 4, 8, 9, 12, 14, 20, 23), 4 (15), 6 (19), 7 (5, 6, 17, 21), 9 (10, 11) |
| §14 real-machine items | 9 (docs/testing.md 1.20) |

## Spec points settled by this plan (flagged for Ben)

**Contradictions or gaps in the spec:**
- **The session folder name:** §7 says `BenTech-Reports\<PC>_<yyyy-MM-dd_HHmm>\`, §8 `<PC>_<serial>_<yyyy-MM-dd_HHmm>\`. The plan uses §8's (it carries the identity Compare needs); `<serial>` is `UUID-<last 12 hex>` for placeholder serials.
- **"Logs copied to the stick" on the Restart path (§6.9):** today's Cancel path copies no logs (only Finish does). The plan leaves Cancel as it is: the action logs and reports are already on the stick (§3, §7); the window's own setup.log lines go with `C:\BenTech` on a fresh PC.
- **"Confirmed by `fsutil dirty query` (exit code)" (§6.5):** that exit code is not documented to reflect the dirty bit. The plan confirms with `Win32_Volume.DirtyBitSet` (CIM, language-independent) and only logs fsutil's code; the VM records it.
- **`chkntfs /x` lasts** (§6.5): it excludes C: from every later start-up check until `chkntfs /d`. **Settled by RD-R1: no Cancel action at all, no `chkntfs` anywhere** (spec amended).
- **"The Repair-WindowsImage progress" (§7):** the cmdlet runs in a grandchild whose progress stream is silenced (`Invoke-PowerShellChild`), so the image check and scan show the step list and elapsed time only; DISM RestoreHealth shows its percent.
- **§13.2 "ReAgent.xml for WinRE" vs §6.1 "the BCD decides":** the plan follows §6.1. **§13.10 "keyed by serial" vs §6.8/§13.22:** serial, or BIOS UUID for placeholders.
- **"An active remote session (AnyDesk or ScreenConnect connected)":** no language-independent "connected" signal is known. **Settled by RD-R2:** the at-PC tick is always required for Network reset; only RDP is detected, to make the warning red.
- **The stick re-check "every few seconds" (§8).** **Settled by RD-R3:** `[IO.DriveInfo]` presence check (no CIM on the window's thread); `Find-SetupStick` only at page open and on a change.
- **The SAFE file name.** **Settled by RD-R4:** `REPORT_SAFE_<stamp>.txt` / `COMPARE_SAFE_<stamp>.txt`, with no PC name.

**Plan calls** (each also marked where it is decided): the progress and result files live in `C:\BenTech\Setup\Tool\<RunId>\`, never on the stick; info children log locally; the step timeout is capped by the action's remaining time; a failed step does not stop the action, but `Data.Abort` does (backup and CSV), and `AlwaysRun` restarts the WU services; Stop is yellow; grandchild commands return hashtables; HttpWebRequest for the 5-second HTTPS probe and the clock offset; the Hebrew YES as code points; one 500 ms run timer re-rendering the repair page only; the strip refreshes after each action and holds the repairs while it loads; read-only actions ask once without a stick; Open folder through `Start-BackgroundExternal`; the deadline kill at deadline + 1 minute; `$script:ToolboxChildren` and `$script:ToolboxRestartRequested`; the machine card shared and the setup banners on the setup page only; the view never rewrites the two text boxes; an absent `recoveryenabled` counts as on; WinRE off without ReAgent.xml agreement is never enabled; TRIM reported, never changed; the OEM check limited to system utilities and skipped for whiteboxes; the signed-in user's hive, not the elevated HKCU; an architecture mismatch never offered as a DISM source, `.swm` unsupported; WU scan by a WUA search; BITS jobs chosen by file path; services restored to their earlier state, Disabled never changed; ghost exclusions widened to any `WSD`/`IPP` segment; the CSV and reports UTF-8 with BOM; the full disk scan skipped on a red disk; tasks and services listed without arguments; a "THIS VISIT" block and a "HOW TO USE" paragraph in the core; known values under 3 characters not masked; Compare writes its own file and counts as a visit; every deadline, timeout, threshold, finding text and Hebrew string not quoted from the spec.
