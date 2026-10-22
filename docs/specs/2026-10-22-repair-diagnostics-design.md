# BenTech Toolbox step 2: Repair & diagnostics

**Status:** Approved by Ben on 22/10/2026 ("Spec approved"), including the calls in section 13.
**Amends:** [2026-10-21-toolbox-design.md](2026-10-21-toolbox-design.md) and, through it, the earlier specs. They stay binding wherever this document does not change them.
**Source material:** Ben's BenTech Windows Toolkit v1.0 (`Downloads\BenTech-Toolkit\`, with its `BenTech-Toolkit-SUMMARY.md`), and a full read-only review of it on 22/10/2026. The review is referred to below as "the review".

## 1. Why

Ben built a USB repair and diagnostics kit. Its repairs are a health check, a standard repair, a post-clone repair, and Windows Update and network resets. Its diagnostics produce one big report for an AI chat. He wants it inside the BenTech Toolbox, so that **one window holds all his tools**.

The review found the kit well designed, but not ready for his customers' PCs:
- **Hebrew Windows:** on Hebrew Windows the core verdicts are wrong on every PC. WinRE always reads as disabled, the DISM health check always warns, and the driver count is always 0.
- **No disk-health check:** nothing checks the disk before hours of heavy repair I/O.
- **Hangs:** several commands can hang forever on a broken PC.
- **Weak confirmations:** the destructive actions are protected less than the README says.
- **Unsigned code:** it runs unsigned code as admin from a writable stick.

So the kit is **rebuilt into the toolbox** (Q31), keeping its repair order and its knowledge, and fixing those problems.

## 2. Decisions (Ben, 22/10/2026)

| # | Question | Answer |
|---|---|---|
| Q31 | How it joins the toolbox | **Rebuilt into the toolbox.** A second page in the same window, "Repair & diagnostics", with the Hebrew-Windows, timeout and safety fixes built in. Same spec, plan and reviewed-build process. |
| Q32 | Working without internet | **Online only.** The toolbox comes from the signed release, as today. A PC whose network is broken needs Ethernet or a phone hotspot first (see 9). |
| Q33 | The report and customer data | **A full report plus a privacy-safe copy.** The full report stays on Ben's stick. A shorter copy, with names, e-mails, serials, IPs and network names masked, is the one to paste into an AI chat. |
| Q34 | Where progress shows during long repairs | **In the toolbox window.** Each action runs in the background with a timeout. The window shows the current step, its progress and a live log, and stays responsive. |

## 3. What changes for Ben

1. **Launch, as today.** Ben runs `BenTechSetup.cmd` from the stick (UAC, signature check, download). The toolbox opens on "New PC setup".
2. **Pick the tool.** He clicks **Repair & diagnostics** in the left nav.
3. **Read the safety strip.** It sums the PC up at a glance: pending restart, disk health, BitLocker, internet and free space.
4. **Run an action.** He picks one, for example "Standard repair", and confirms. The window shows each step and its progress live.
5. **Read the result.** The window shows the result with its findings, and where the log and the report are on the stick.
6. **Finish.** He can run more actions, switch to "New PC setup" and start a setup, restart the PC from the toolbox, or close the window.

Closing the window after repairs is a Cancel, as today. The setup folder is removed when no earlier setup run exists. **The reports and logs are already on the stick.**

## 4. The page

### 4.1 Layout
It uses the same window, look (Q29), languages (Q21) and machine card as "New PC setup". The left nav gains a second entry, **Repair & diagnostics**, with its own glyph.

```
+-------------+------------------------------------------+-----------------------+
| New PC      | DELL Latitude 5440  SN 7HX2K93           | RESULT / RUNNING      |
| setup       | SAFETY: [restart ok] [disk OK] [BitLocker| Standard repair       |
| ----------- |  off] [internet OK] [C: 41% free]        |  v Time sync          |
| Repair &    |                                          |  v Disk scan          |
| diagnostics | CHECK      [Health check] [Quick report] |  > Windows image (DISM)|
|             | REPAIR     [Standard repair] [Post-clone]|     [=====    ] 45%   |
|             | ADVANCED   [Windows Update reset]        |    System files (SFC) |
|             |            [Network reset] [Disk check   |    Recovery (WinRE)   |
|             |             at restart] [Ghost devices]  |  live log (last lines)|
|             | REPORT     [Full report] [Compare with   |                       |
|             |             last visit]                  | [Open folder] [Stop]  |
|             | Customer complaint: [________________]   |  [Restart PC]         |
+-------------+------------------------------------------+-----------------------+
```

- **Safety strip:** five chips, green, yellow or red, each with a tooltip (section 5).
- **Action tiles,** each with a glyph, a title and one line of explanation. A tile is disabled, with the reason in its tooltip, while another action is running or while a safety rule blocks it.
- **Customer complaint:** a free-text box, in Hebrew or English, typed before a report. It goes at the top of the report as the AI's starting point. It stays on the stick; the privacy-safe copy keeps it but masks e-mails and phone numbers in it.
- **Right column:**
  - before any action: "What it does" for the hovered or selected tile;
  - while running: the step list with ✓ / ▶ / ✗, a progress bar for the current step when one is known, elapsed time and the live log tail;
  - after: the findings (CRIT red, WARN yellow, INFO grey), plus the "Open folder" and "Restart PC" buttons.

### 4.2 Confirmations (in the window, never a console prompt)
- **Read-only actions** start at once: Health check, Quick report, Full report, Compare.
- **Repairs** (Standard, Post-clone) show a confirmation panel listing what will change.
- **Destructive actions** need the technician to type `YES` in the panel. It is accepted in any case, and also as `טקד`, the same three keys on a Hebrew keyboard layout. The actions:
  - Windows Update reset;
  - Network reset;
  - Disk check at restart;
  - Ghost devices.
- **Restart PC** always asks first.

### 4.3 Stop
- **Stop** ends the action at the next **safe point**: between steps, never in the middle of a step.
- **A step can only be killed mid-run by its own timeout.** DISM, SFC and chkdsk are never killed by the Stop button.
- The window says "Stopping after <step>…".

### 4.4 While an action runs (builder check 1)
- **Locked in place:**
  - **The window cannot be closed.** X and Alt+F4 show "An action is running: press Stop, then close".
  - **The nav is locked:** switching to "New PC setup" and pressing Start are disabled.
  - **The safety strip does not refresh.**
- **If the window fails** (a Failed outcome) while a child runs, `Get-SetupChoices`' `finally` kills that child's process tree **before** anything else happens. Only then does the console fallback or a cleanup run, so `C:\BenTech` is never deleted under a running child.
- **The child also guards itself.** It enforces its own per-step timeouts, and it exits when its whole-action deadline passes, even if the window is gone.

## 5. Safety strip and gates

| Chip | Source (language-independent) | Effect |
|---|---|---|
| **Restart pending** | **Only the signals that break servicing:** CBS `RebootPending`, `PackagesPending` and `pending.xml`, and Windows Update `RebootRequired`. A pending file rename or computer rename is a grey note only (it is set on most PCs). | **Red blocks** Standard repair, Post-clone, Windows Update reset and Disk check at restart; DISM and SFC on a pending servicing restart give wrong results. The chip offers "Restart PC". Read-only actions, Network reset and Ghost devices still run. **Checked again between steps:** if DISM itself leaves a servicing restart pending, the action stops before the next servicing step with "Restart, then run it again" (yellow). |
| **Power** (laptops) | The window's existing AC check | **On battery blocks** Standard repair and Post-clone (an hour of DISM/SFC must not die with the battery). |
| **Disk health** | `Get-PhysicalDisk` HealthStatus; `Get-StorageReliabilityCounter` (wear, uncorrected read/write errors, temperature); System events 7, 51, 153 and NTFS 55 in the last 30 days (by provider and ID) | **Red (failing or errors found) blocks Standard and Post-clone repair and Disk check at restart.** They unlock only after the technician ticks "The customer's data is backed up / imaged" (shop rule: image first). Yellow warns. |
| **BitLocker** | `Get-BitLockerVolume` or CIM `Win32_EncryptableVolume` (protection status and protector types, never keys) | When on, a reminder: "Have the recovery key before BIOS or board work". Informative only. |
| **Internet** | A bounded check, run in the safety child: TCP 443 to `www.msftconnecttest.com`, then an HTTPS request to `https://www.msftconnecttest.com/connecttest.txt` (5 s each) | Red disables Windows Update reset's rescan. |

**The whole strip is computed in a bounded child process,** never on the window's thread, because `Get-PhysicalDisk` and similar calls can hang on exactly the failing disks this targets. The child returns JSON. A timeout makes the affected chip "unknown" (yellow), and that blocks nothing.
| **Free space C:** | Volume size and free bytes | Under 10% or under 15 GB is red. DISM needs room, so Standard and Post-clone warn. |

**Also checked before a Network reset** (shown in the confirmation panel):
- a static IP on any adapter (its settings are shown and saved as data that can be restored, section 6.6);
- an active remote session (RDP, AnyDesk or ScreenConnect connected). That **blocks** the reset unless the technician confirms he is at the PC.

## 6. Actions

Every action runs in a **hidden child process** of the same signed `setup.ps1` (section 7). Every native tool goes through `Invoke-External` with its own timeout. **No result is read from localized text.**

**How each kind of tool is bounded** (builder check 4):
- **Native tools** (`dism.exe`, `sfc`, `chkdsk`, `netsh`, `pnputil`, `w32tm`, `reagentc`) run through `Invoke-External` with a timeout.
  - Their output is redirected to a file that the child tails from `Invoke-External`'s poll loop (the v2 tick).
  - That is how DISM's `[===  45.0%]` reaches the progress file.
  - Success and failure come from **exit codes** (DISM's 0x800f081f-class codes are its exit code).
- **Cmdlets that can hang or have no timeout** (`Repair-WindowsImage -CheckHealth/-ScanHealth`, `Repair-Volume -Scan`, `Get-PhysicalDisk`, `Get-StorageReliabilityCounter`, `Get-Printer`, `Get-WindowsDriver`) each run in a bounded grandchild through the engine's `Invoke-PowerShellChild`, which returns JSON (for example `ImageHealthState`).
- **RestoreHealth** runs as `dism.exe /Online /Cleanup-Image /RestoreHealth [/Source:... /LimitAccess]`, for the live percent and the exit code.

### 6.1 Health check (read-only)
1. **Disk scan:** `Repair-Volume -DriveLetter <system> -Scan` gives NoErrorsFound, ScanNeeded, SpotFixNeeded or FullRepairNeeded.
2. **Windows image health:** `Repair-WindowsImage -Online -CheckHealth`, then `-ScanHealth`. The `ImageHealthState` enum is Healthy, Repairable or NonRepairable.
3. **System files:** `sfc /verifyonly`, judged from the CBS.log `[SR]` lines (CBS.log is always English).
4. **WinRE** (builder check 7):
   - **The BCD decides:** the `{current}` loader's `recoveryenabled` and `recoverysequence`, read through the WMI `BcdStore`, which is language-independent.
   - **`ReAgent.xml` is supporting evidence only**, because it is often stale after a clone. When the two disagree, the result is "unknown" (yellow), and Repair does **not** run `reagentc /enable`.
   - `reagentc /enable` runs only when the BCD says recovery is off **and** `ReAgent.xml` agrees.
5. **Devices with problems:** `Get-PnpDevice` status and problem codes. Unlike the kit, no `pnputil /scan-devices`, so the check is truly read-only.
6. **Activation:** `SoftwareLicensingProduct.LicenseStatus`.

### 6.2 Standard repair
The kit's order is kept, with its reasons:
1. **Time sync,** verified: `w32tm /resync`, then the clock offset measured. A clock still more than 2 minutes off is a WARN, with "downloads may fail".
2. **Disk scan** as in 6.1. SpotFixNeeded or FullRepairNeeded is CRIT, with the "Disk check at restart" offer (6.5).
3. **DISM RestoreHealth** (`dism.exe`, with live percent).
   - On a source failure (a 0x800f081f-class exit code), the window **offers** a retry with `/Source:` and `/LimitAccess`.
   - The source is an `install.wim` / `install.esd` found in `<stick>\sources\` or a mounted ISO.
   - The offer shows the file, its edition, architecture, language and build, and warns when the build differs from the PC's.
   - The retry runs only when the technician picks it (builder check 6: the file is unsigned, so it is never used silently).
4. **`sfc /scannow`.** A second pass runs only when the first repaired something. "Repaired" means CBS.log `[SR]` lines with a repair count above 0, fixing the kit's always-second-pass bug.
5. **WinRE:** `reagentc /enable` runs **only** when 6.1 found it disabled.

### 6.3 Post-clone / new hardware
Standard repair, then:
- the device problem list (`pnputil /scan-devices` here, deliberately);
- leftover software from another manufacturer (the kit's OEM check);
- a page file on a missing drive;
- the TRIM state, plus `Optimize-Volume -ReTrim` on SSDs (with `-Analyze` only on HDDs);
- activation;
- `Repair-WindowsImage -Online -StartComponentCleanup` (never `/ResetBase`);
- a Windows Update scan.

A pending servicing restart blocks the action before it starts (section 5), and is checked again between steps. The kit carried on anyway.

### 6.4 Windows Update reset (YES)
1. Stop the six update services, with a bounded wait for each.
2. Rename `SoftwareDistribution` and `catroot2` (nothing is deleted).
3. Clear **only the Windows Update BITS jobs**. The kit removed every user's BITS jobs.
4. Start the services again, checking each one's start type and state, and report any that failed.
5. Trigger a scan.

### 6.5 Disk check at restart (YES)
- **How it is scheduled** (builder check 5): `fsutil dirty set <system drive>`. It is judged by its exit code, then confirmed by `fsutil dirty query` (exit code). At the next start Windows runs autochk, the boot-time chkdsk.
  - `Repair-Volume -OfflineScanAndFix` is not used: Microsoft does not document it scheduling a boot-time check on the volume in use.
  - The real-VM test (14) confirms the dirty-bit route.
- **Cancel:** a **Cancel scheduled disk check** button runs `chkntfs /x <system drive>`. It is shown while the volume is marked dirty.

### 6.6 Network reset (YES)
1. **Save the settings first, as data.** Every adapter's IP, gateway and DNS settings go to the stick as JSON. The write is verified before anything changes.
2. **Then reset:** `netsh winsock reset`, `int ip reset`, `int ipv6 reset`, flush DNS.
3. **No `/release` / `/renew`;** the restart does that.
4. "Restart required".

**Restore:** a **Restore network settings** button appears when a saved file for this PC exists on the stick. It **shows every value it will apply** (adapter, IP, mask, gateway, DNS) and needs YES, because the stick is writable. Then it puts static IPs and DNS back from that file.

**Network reset is disabled without a stick:** its backup must survive the restart.

### 6.7 Ghost devices (YES)
1. **List** the non-present devices in a read-only child.
2. **Leave these out entirely** (builder check 8):
   - Bluetooth by enumerator (`BTHENUM\`, `BTHLE\`, `BTHLEDEVICE\`, `BTHHFENUM\`, and children of any Bluetooth parent);
   - printers and print queues, and WSD and IPP devices;
   - audio endpoints (`SWD\MMDEVAPI\`), because customers would lose per-device audio settings.
3. **Show** the rest in the window, every one ticked, so the technician can untick any.
4. **Export** the list to the stick as a UTF-8 CSV.
5. **Remove** the ticked devices with `pnputil /remove-device`.
6. **Without a stick,** this action is disabled.

### 6.8 Reports
- **Quick report** (about 1-2 min): the key facts and the auto-flagged findings, skipping every slow item. Unlike the kit's, it is really quick: no driver enumeration, no Appx, no reliability records, and one bounded connectivity test.
- **Full report** (about 5-12 min): sections 00-12 as in the kit (summary, system, hardware, storage, boot and recovery, Windows Update, drivers, events and crashes, performance and power, network, software, security, msinfo32), with these changes:
  - **Every source is language-independent:**
    - `Get-WindowsDriver` instead of `pnputil /enum-drivers`;
    - `Get-NetTCPConnection` instead of `netstat`;
    - the Guest account and the Administrators group by SID (`-501`, `S-1-5-32-544`);
    - dates in the invariant culture.
  - **Every slow or fragile source has a timeout:** `Get-Printer`, gpresult, vssadmin, systeminfo, msinfo32, the network tests and CIM.
  - **The always-empty items are fixed:** safe-boot flags, last Windows Update results.
- **The AI-ready core** (`REPORT_<PC>_<date>.txt`, target under 150 KB):
  - the customer complaint and section 00;
  - each section's facts and findings, and raw lines grouped and counted instead of pasted verbatim.

  The large raw material goes in `raw\` and a zip: evtx, logs, minidumps, msinfo32, CSVs.
- **The privacy-safe copy** (`REPORT_<PC>_<date>_SAFE.txt`, Q33) is the core with these masked consistently: user names, e-mails, the computer name, serial numbers, MAC addresses, IPs, SSIDs and BSSIDs, profile paths and phone numbers. Masking turns `user1`, `PC-1` and so on into stable tokens, so the AI can still follow them.
- **Compare with last visit:** when the stick holds an earlier report for the same PC, a short "since last visit" section lists the changes. "The same PC" means the same serial, or the BIOS UUID when the serial is a placeholder such as "To Be Filled By O.E.M." or "Default string" (as `New-PcName` does), so different whitebox PCs are never merged. The changes listed:
  - new crashes or WHEA errors;
  - disk wear and errors;
  - free space;
  - devices with problems;
  - installed and removed programs;
  - new findings.
- **Better flags** (the review, section 4): WHEA by severity, chkdsk results from the 6.1 enum, disk event IDs, the clock offset, activation, Windows Update disabled and an expired Defender signature. Each threshold is in `config.json`.
- **Encoding:** report files are **UTF-8**. They may contain Hebrew, such as event messages and program names. This is the one place outside the toolbox window where Hebrew is allowed (amendment 10). The summary lines and flags are English.

### 6.9 Restart PC (builder check 3)
1. **Confirm.**
2. **Close the window with a fourth outcome, Restart.**
   - `Get-SetupChoices` still returns `$null` (no setup run).
   - It records the restart request, which `Main.ps1` reads after its normal Cancel path: transcript stopped, lock released, logs copied to the stick, `C:\BenTech` removed when no earlier run exists.
3. **Then a stateless restart:** `Restart-Computer -Force`, with a fallback to `shutdown.exe /r /t 5 /f`.
   - Not the engine's controlled restart, which needs a run state.
   - There is no setup state, so nothing resumes, and no `C:\BenTech` is left behind.

## 7. Run model (Q34)
- **One child process per action.** The window starts `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <the same setup.ps1> -ToolAction <id> -ToolArgs <json path>`. It is hidden, with a deadline per action (`timeoutsMinutes.tool.<id>`), like the Windows Update round child.
  - The child writes its progress (step, percent, log lines) to a JSON progress file, and its result to a result file.
  - **The child never draws anything and never prompts.** Every question was answered in the window before it started.
- **The window polls** the progress file every 500 ms with a DispatcherTimer and renders it. No runspaces, and the UI thread never blocks.
- **Progress percent** comes from the tools' own numbers where they give them: DISM's `[===   45.0%]` and the `Repair-WindowsImage` progress. Otherwise the step list alone is shown.
- **Deadlines:** a child past its deadline is killed (process tree), and the action ends as "timed out" (red) with whatever it had finished. Per-step timeouts inside the child also go through `Invoke-External`.
- **Engine change:** `src\Entry\Param.ps1` gains `-ToolAction` and `-ToolArgs`, like `-WuRound`. That amends the pinned parameter list. The launcher does not change.
- **The window starts the child without waiting** (builder check 1), through the engine's existing non-blocking `Start-BackgroundExternal`. The window enforces the action's deadline on its timer, killing the process tree at the deadline. This becomes the second named exception to "every child goes through `Invoke-External`" (after Office).
- **Logs and outputs** are written by the child **directly to the stick**, in `BenTech-Reports\<PC>_<yyyy-MM-dd_HHmm>\` (section 8). The window also keeps one ASCII line per action in setup.log.

## 8. Where things are kept
- **On the stick,** found as the setup finds it (`Find-SetupStick`): `BenTech-Reports\<PC>_<serial>_<yyyy-MM-dd_HHmm>\` holds:
  - the action logs;
  - the reports (core, SAFE, full raw, zip);
  - the network-settings backup;
  - the ghost-device CSV.

  Previous visits are found there by serial (6.8).
- **No stick** (the launcher ran from the Desktop): the page shows a red chip, "Plug in the BenTech stick to keep reports and logs". Actions that only change the PC still run, and their log goes to `C:\BenTech\Setup\Logs`, which Cancel would delete. The window says so before the action starts. **Reports are disabled until a stick is found.** The page re-checks for the stick every few seconds.
- **The run lock** stays held while the window is open, as today, so a second launcher instance still exits.

## 9. Online only (Q32), and its known limit
- The toolbox, and with it this page, needs the internet to download its signed release, as today.
- **On a PC whose network is broken,** the technician first connects Ethernet or a phone hotspot, then runs the launcher.
- **Network reset** stays useful for a PC whose network works on one connection but not another, or after the toolbox has opened.
- An offline copy (a signed bundle cached on the stick) can come later. It would need a new launcher on every stick.

## 10. Rules this changes
| Rule | From now on |
|---|---|
| Toolbox spec 5.1: the window is used before the run only | The window may also run Repair & diagnostics actions, each in a hidden child process; it never runs setup steps. |
| `Param.ps1` is pinned | Gains `-ToolAction` and `-ToolArgs` (the child entry), as `-WuRound` did. |
| Report and logs are English and ASCII | Unchanged for the setup. **Diagnostic reports** on the stick are UTF-8 and may hold Hebrew data (event messages, program names); their summary and flags are English. |
| "Nothing may stop and wait" | Unchanged for setup steps. The toolbox waits for the technician by design (Q18), and every action's child has a deadline. |
| "Every child goes through `Invoke-External`; the one exception is Office" | **A second exception: the action child** started by the window through `Start-BackgroundExternal`, its deadline enforced by the window's timer (7). |
| `Get-SetupChoices` returns Choices or `$null` | Unchanged. A "Restart" outcome also returns `$null`, and records a restart request that `Main.ps1` performs after its Cancel path (6.9). |

## 11. Not in scope
- **Offline use** (Q32).
- **Running the old kit,** or its RUN-*.cmd, from the stick. The kit is retired once this ships.
- **Automatic upload of reports** anywhere. Ben pastes the SAFE copy himself.
- **Repairs not in the kit:** in-place upgrade, driver installation, malware removal.

## 12. Build order (my call; one spec, four reviewed task groups)
1. **The engine side:** the child entry (`-ToolAction`), the progress and result files, `Invoke-External` timeouts per tool, the language-independent checks, the safety gates and the read-only Health check.
2. **The page:** nav entry, safety strip, tiles, confirmations, the live run panel, Stop and Restart PC. Ben approves screenshots (EN/HE) before the run panel is wired, as Q25.
3. **The repairs:** Standard, Post-clone, Windows Update reset, Disk check at restart, Network reset (with Restore), Ghost devices.
4. **The reports:** Quick, Full, the AI-ready core, SAFE masking, Compare with last visit.

## 13. Calls made without Ben (check while reading)
1. **One hidden child per action, progress by file polling** (7). The setup's proven WU-child pattern; no runspaces.
2. **Language-independent sources:** `Repair-Volume`, `Repair-WindowsImage`, `Get-WindowsDriver` and `Get-NetTCPConnection` from Windows' own modules; ReAgent.xml for WinRE. Each needs a Hebrew-VM check (14).
3. **A failing disk blocks repairs until "backed up / imaged" is ticked** (5).
4. **A pending restart blocks repairs; read-only actions still run** (5).
5. **Network reset:**
   - no `/release` / `/renew`;
   - settings saved as restorable JSON, with a Restore button;
   - blocked during a remote session unless the technician is at the PC.
6. **Ghost devices exclude Bluetooth by enumerator,** not only by class.
7. **Stop works only between steps.** Only a timeout kills a running DISM, SFC or chkdsk.
8. **Reports and logs go to the stick only.** Without a stick, reports are disabled and repairs warn that their log will not be kept.
9. **The customer complaint box** feeds the report.
10. **Compare with last visit** is keyed by serial.
11. **The old kit is retired** after this ships.
12. **While an action runs:** the window cannot close and Start is disabled. A window failure kills the child first (4.4).
13. **Pending restart:** only servicing signals count (CBS, `pending.xml`, Windows Update), not file or computer renames. It is re-checked between steps (5).
14. **A laptop on battery** blocks Standard repair and Post-clone (5).
15. **Restart PC** is a fourth window outcome, performed by `Main.ps1` after cleanup with a stateless restart (6.9).
16. **DISM RestoreHealth runs as `dism.exe`,** for live percent and exit codes. Cmdlets that can hang run in bounded grandchildren. The safety strip is computed in a child (6, 5).
17. **Disk check at restart uses the dirty bit,** with a Cancel button (`chkntfs /x`) (6.5).
18. **WinRE:** the BCD decides, and `reagentc /enable` runs only when the BCD and `ReAgent.xml` both say disabled (6.1).
19. **The unsigned `install.wim` source** is used only when the technician picks it, after seeing its details (6.2).
20. **Network reset and Ghost devices need the stick.** Restore shows every value and needs YES (6.6, 6.7).
21. **Ghost devices also leave out** audio endpoints and WSD/IPP printers, and the list is shown ticked so each can be unticked (6.7).
22. **The same PC means** its serial, or its BIOS UUID for placeholder serials (6.8).
23. **YES is accepted in any case,** and as `טקד` on a Hebrew keyboard layout (4.2).

## 14. To prove on a real machine (`docs/testing.md`)
- **On a Hebrew Windows 11 VM:** every language-independent check gives the same verdict as on English Windows (WinRE, image health, disk scan, drivers, admins and Guest, TCP list).
- **Each repair end to end on a VM checkpoint:** before and after, logs and timing.
- **The live progress:** DISM percent, Stop between steps, a timeout killing a stuck step.
- **Network reset:** with a static IP, then Restore.
- **Ghost devices:** with a paired Bluetooth headset that is turned off.
- **Disk check at restart:** schedule it (dirty bit), see autochk run at the next start, and also test Cancel (`chkntfs /x`).
- **WinRE:** after a clone (stale `ReAgent.xml`), the BCD verdict is right.
- **Pending restart:** on a PC with only a pending file rename, the strip is not red. After a Windows Update needing a restart, it is.
- **Window lifecycle:** X during an action is refused. A forced window failure during an action kills the child before cleanup.
- **The SAFE copy:** read it end to end; nothing identifying is left.
- **Compare with last visit:** on the same PC, twice.
