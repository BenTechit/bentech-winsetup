# bentech-winsetup v2: see what it is doing, faster Office

**Status:** APPROVED by Ben, 20/10/2026 (with the five builder-check calls marked "my call", and build order A). §9 and §10 added the same day from the first real-machine test and Ben's answers Q6 A and Q7 A.
**Date:** 20/10/2026
**Amends:** [2026-10-18-bentech-winsetup-design.md](2026-10-18-bentech-winsetup-design.md). That spec stays binding wherever this document does not change it.
Amended by [2026-10-22-windows-update-option-design.md](2026-10-22-windows-update-option-design.md): Windows Update "drivers only" and the final screen's U key.

## 1. Why

Ben tested v1 (release `v2026.10.19.1`) on a real machine and reported four problems:

1. **The start screen is unclear and too fast.** It was gone before he understood which keys did what.
2. **The run looks frozen.** The progress screen only redraws when a step starts or ends, so during a 30-minute step the timer sits at `00:00`. He could not tell "still working" from "stuck" or "error".
3. **Microsoft 365 takes a very long time.**
4. **He wants much more information throughout the run.** In particular, during the driver phase he wants to see which drivers are being installed and how far along it is.

He also wants desktop shortcuts for Word, Excel, PowerPoint and Outlook.

The v1 goal is unchanged. Ben double-clicks one file on 5–7 machines in parallel and walks away. What changes is that, when he walks past a machine, one glance tells him:

- what it is doing right now
- that it is alive
- how long it may still take
- what it has done so far

## 2. Decisions Ben made (20/10/2026)

| # | Question | Answer |
|---|---|---|
| Q1 | Start screen countdown | **30 s, any key restarts it at 30 s.** It still starts by itself if nobody touches it. |
| Q2 | Office speed | **Skip unneeded apps AND install Office in the background** while the other steps run. |
| Q3 | Office apps | **Word, Excel, PowerPoint, Outlook, OneNote.** Everything else is excluded. |
| Q4 | Driver tools | **List the updates first, then install.** This adds about 2–4 minutes per driver pass, which is accepted. |
| — | Progress screen | The mockup in §4.2 was approved: checklist + NOW + JUST HAPPENED. |
| — | Office shortcuts | Word, Excel, PowerPoint and Outlook on the desktop. |

## 3. Goals, non-goals, anti-goals

**Goals**
- A start screen a technician understands in one read, with time to read it.
- A progress screen that visibly moves at least once a second for the whole run, including inside long child processes and long waits.
- At any moment the screen says what is happening now, and keeps a short running history of what already happened. Both survive reboots.
- Driver passes and Windows Update show the individual updates and where each one is.
- Office no longer adds its full install time to the run.
- Office desktop shortcuts.
- The report (`Setup-Report.txt`) also lists the Windows updates installed and the driver updates found, per pass.

**Non-goals**
- No GUI (WinForms/WPF). The console stays the only UI.
  Amended by [the toolbox spec, section 8](2026-10-21-toolbox-design.md): one WPF window before the run.
- No Hebrew on the console: it stays ASCII, as in spec §5.
- No percent-complete bar for the whole run. Its length can't be known, so a bar would lie.
- No Office copy on the USB stick. It would go stale, against Ben's "always up to date" (spec Q6).

**Anti-goals** (failures even if everything else works)
- **The display makes a run fail, hang or slow down noticeably.** Every display error is logged and ignored. Drawing never blocks a step. The run without a screen behaves exactly as before.
- **The screen flickers or scrolls** so that it can't be read from a metre away.
- **A setup decision depends on parsing a vendor log or other localized text.** Parsing tool output is for display only. Results keep coming from exit codes, result files and registry values, as in v1.
- **Office's background install gets killed by a restart, or leaves the run waiting forever.**

## 4. Design

### 4.1 Start screen (Q1)

Layout, with the current choice values highlighted in colour (green for on, grey for off):

```
 ================================================================
   BENTECH WINDOWS SETUP                          v2026.10.20.1
 ================================================================
   Dell Latitude 5440    SN: ABC1234    ON CHARGER
   New PC name: DELL-ABC1234

   WHAT WILL HAPPEN                  TO CHANGE IT, PRESS
   Type     LAPTOP (driver tool)     L = laptop    D = desktop
   Chrome + AnyDesk   always
   7-Zip    YES                      Z = yes / no
   Office   BUSINESS (Heb + Eng)     O = off / business / home

   Starts by itself in 25 s   ##########..........
   ENTER = start now           ESC = cancel, change nothing
 ================================================================
```

- **Countdown:** it starts at 30 s, and any key (a toggle, or an unknown key) restarts it at 30 s.
- **Machines that don't look fresh:** behaviour as in v1. There is no countdown, and the line reads `This PC already has user files or is older than 14 days - press ENTER to run anyway`.
- **Other lines:** the battery warning and the `Previous run:` line stay. The `Type` line says what the mode means: `LAPTOP (driver tool + laptop app)` or `DESKTOP (no laptop app)`. On a brand that has no driver tool, the parentheses become `(no driver tool for this brand)`.
- **Unchanged:** the keys, the defaults, the stale-key flush and Esc.

### 4.2 Progress screen

Three areas, in the layout below.

The mockup groups some lines ("Chrome + AnyDesk", no winget line), but that is for illustration only. **The checklist keeps one line per plan step, as in v1** (my call), so the screen, the verdict and the report always name the same steps. The one exception is `office-finish`, which is folded into the Microsoft 365 line (§4.6).

```
  BENTECH WINDOWS SETUP - working, do not turn off   /   Total 01:12:40   Restarts 2
  ---------------------------------------------------------------------------------
  [OK] Prepare               [OK] Chrome + AnyDesk     [..] Windows Update
  [OK] BitLocker off         [OK] 7-Zip                [..] Drivers (pass 2)
  [OK] Time zone + keyboard  [>>] Microsoft 365 (bg)   [..] Laptop app
  [OK] Desktop icons         [OK] Default browser      [..] Finish
  [OK] Remove bloatware      [>>] Drivers (pass 1)
  [OK] Rename PC
  ---------------------------------------------------------------------------------
  NOW  Drivers - Dell Command Update   /   12:40 (max 60 min)
       Found 7 updates (BIOS skipped: on battery)
       [OK] Intel Chipset Device Software              10.1.19.9
       [OK] Realtek Audio Driver                       6.0.9600.1
       [>>] Intel Iris Xe Graphics Driver              31.0.101.5590
       [..] Intel Wi-Fi 6E AX211 Driver
       [..] Dell Power Manager Service       ... and 2 more
  ---------------------------------------------------------------------------------
  JUST HAPPENED
  12:31  Microsoft 365 started installing in the background (Hebrew + English)
  12:29  Chrome set as default browser (checked again at the end)
  12:28  AnyDesk installed - ID 123 456 789
  12:27  Google Chrome 141.0 installed
```

**Header:** the run title, a spinner, the total time since the run started, and the restart count. The spinner is an ASCII frame (`| / - \`) that advances on every redraw.

**Checklist:**
- The plan's steps go in columns, as many as the width allows. Titles are short.
- The markers are the v1 ones: `[OK]`, `[>>]`, `[..]`, `[X ]`, `[--]`. Coloured: OK green, running cyan, failed red, skipped dark grey, pending default.
- **Failed and skipped steps:** their reason moves out of the checklist and into JUST HAPPENED, so checklist lines stay short.

**NOW:**
- **Its first line:** the running step's title, plus an optional sub-title (which tool, which round). Then the step's elapsed time, plus the limit of whatever it is currently waiting on: `(12:40 of max 60 min)`. The limit is the timeout already passed to `Invoke-External`, or the deadline of the wait.
- **Below it:** detail lines from the running step (§4.4, §4.5); with no detail, the latest activity line instead. Lists cut off with `... and N more`.
- **More than one step at work:** when a background job runs (Office, §4.6), NOW shows the foreground step. The checklist shows the background job as `[>>] Microsoft 365 (bg)` with its own timer.

**JUST HAPPENED:** the newest activity lines first, as many as fit. Each is `HH:mm  text`, in local time, ASCII.

**Size and redraw:**
- **Window size:** at start, try to enlarge the console window to about 100×45 characters, capped at the largest the screen allows. Ignore any failure. Windows Terminal, the default on many Windows 11 machines, doesn't allow a script to resize it.
- **Every redraw** reads the actual window width and height and fits the layout. When space runs out, shrink JUST HAPPENED first, then the NOW list. The header, checklist and NOW first line always show.
- **No flicker:** redraw by moving the cursor to the top-left, overwriting each line padded to the full width, and blanking the leftover lines. No `Clear-Host` every second; only when the window size changed.
- The reboot countdown and the final screen stay as they are.

### 4.3 The tick: something moves at least once a second

A single **tick** redraws the progress screen. It runs:
- **Inside `Invoke-External`'s existing wait loop**, which already polls every 200 ms. A redraw is allowed at most once per second.
- **In every other long wait**, through one new helper (`Wait-SetupDelay -Seconds n`, name left to the builder) that replaces `Start-Sleep` in step code. The waits involved:
  - the Windows Update busy wait
  - the Lenovo process wait
  - the BitLocker decryption wait
  - the Office wait (§4.6)
  - any other sleep longer than 2 s
  - large downloads (`Get-RemoteFile`: the ODT, HPIA, AnyDesk), which can block for minutes on a slow line

Rules:
- **Only on the main run path.** The tick never draws in the `-WuRound` child (that child has no screen) or before the progress screen exists. With no tick registered, it is a no-op.
- **Never throws, and stays cheap:** about 50 ms at most per tick. Detail sources that read files read only the last 64 KB.
- **Logging:** any error in the tick is logged once per minute at most, then ignored.
- **The step's own work is never delayed** by drawing beyond that cost.

### 4.4 Activity feed: JUST HAPPENED

- **Function:** a new `Add-SetupActivity -Text '...'` (name left to the builder). It appends one line to `Logs\activity.txt` (`yyyy-MM-dd HH:mm:ss<TAB>text`), writes the same text to `setup.log`, and is shown by the next tick. It never throws.
- **Lasts through reboots:** the screen reads the last lines of the file, so the history is still there after a restart.
- **A new run starts empty.** A new run (not a resume) archives the old file as `Logs\activity-<RunId>.txt` and starts a fresh one.
- **AnyDesk ID** (my call): v1 keeps the ID out of `setup.log`. The activity line with the ID goes to the screen and to `activity.txt`, which is consistent with the report already showing the ID. Its copy in `setup.log` leaves the ID out.
- **The screen never draws through `Write-Host`** (my call). `Start-Transcript` records every `Write-Host`, so a redraw every second would flood the transcript. The progress screen draws with `[Console]` calls, which the transcript doesn't record. Each activity line is logged once, through the log.
- **The runner adds:**
  - `<Title> started`
  - `<Title> done - <message>`
  - `<Title> skipped - <reason>`
  - `<Title> FAILED - <reason>`
  - `Restarting (restart N)`, and `Back after restart N` on resume
- **Steps add the facts a technician cares about:**
  - each app's installed version
  - the AnyDesk ID
  - the new PC name
  - each bloatware app removed
  - BitLocker state changes
  - the time zone and keyboard set
  - each Windows Update round's summary (found, installed and failed counts)
  - each driver pass's summary
  - Office started, finished and failed
  - Office shortcuts created

  The builder picks the exact wording. Lines say what happened in plain words. They never hold secrets or customer files.

### 4.5 NOW detail: drivers and Windows Update (Q4)

**Driver passes: list first, then install.** For each vendor pass:

1. **List:** run the tool's scan or list mode with the same filters as the install (on battery: no BIOS/firmware). Read the list it produces:
   - **Dell:** `dcu-cli /scan` with `-report=<folder>`. It writes `DCUApplicableUpdates.xml`, with each update's name, version and category.
   - **HP:** HP Image Assistant with `/Operation:Analyze /Action:List`, same category and selection. It writes a report of the recommended SoftPaqs.
   - **Lenovo: no list in this version** (my call). A LIST run would export through the same `-exporttowmi` records that decide v1's install result, and stale records are already a known problem (`docs/testing.md`). Lenovo shows the live log line and the timer. It gets a list only after SPIKE#4 proves that LIST leaves those records alone.
2. **Show the list** in NOW: `Found N updates`, then one line per update (name, version, status). Items that the battery filter holds back show as `skipped: on battery`, when the tool reports them.
3. **Install:** the v1 install run, unchanged in arguments and in how its result is decided.
4. **During the install:**
   - **Latest log line:** NOW shows the tool's latest log line, read from the log file the run already writes, ASCII-cleaned and cut to the width.
   - **Per-update status:** where a log line names an update from the list, that update's status moves to `[>>]` (in progress) or `[OK]` (done). This is display only; the step's result still comes from exit codes and result files.
5. **When the pass ends:** an activity line gives the summary. The report gets the list with the final status where known.

A list that can't be produced or read never fails the step. NOW then says `List not available from <tool> - installing everything it recommends`, the install runs as in v1, and the cause is logged.

**Windows Update: "Installing 3 of 7".**
- **Progress file:** the `-WuRound` child writes `Logs\wu-round<N>.progress.json`, replaced atomically on every change. It holds:
  - the phase: searching, downloading or installing
  - the list: KB number, title, size and status per update
  - the index of the current update

  The parent's NOW reads it on each tick: `Windows Update - round 2 (max 6)`, the phase, then the list.
- **Config switch** (my call): `config.json` gets a Windows Update setting that chooses between one-at-a-time and v1's batch install. The default is one-at-a-time. If the real-machine test shows it is too slow or behaves differently, flipping the switch brings back v1's batch install. The screen then shows only the list and the phase, with no "3 of 7". The round timeout (`wuRound`, 90 min) and the round cap stay as they are unless that test says otherwise.
- **One update at a time:** the child downloads and then installs **one update at a time**, in search order. It folds the per-update results back into the shape v1 already uses (`ResultCodes` in the original order, `RebootRequired` OR-ed, `HResult` = the first non-zero one).
  - At the first HRESULT that v1 treats as round-ending (busy, reboot pending), the loop stops. The remaining updates count as not attempted, and v1's existing handling applies unchanged.
  - The v1 meaning of every result (R23, R24a–d, hide rules, failure counts) must stay the same. The tests that pin it must still pass.
- **Update titles:** shown in English where Windows allows it. Set the WUA session's locale to en-US (`UserLocale` = 1033) when the session accepts it. Otherwise titles go through the ASCII filter, and the KB number goes first so the line is still useful.

### 4.6 Office: smaller and in the background (Q2, Q3)

**Smaller download:**
- `config.json` `apps.office.excludeApps` becomes everything except Word, Excel, PowerPoint, Outlook (classic) and OneNote:
  - `Access`, `Publisher`, `Teams`, `OneDrive`, `Groove`, `Lync`, `Bing`
  - `OutlookForWindows`, the new Outlook. Ben wants classic Outlook.
- The IDs must be valid ODT `ExcludeApp` values. Confirm each on a real install. Any ID that ODT rejects is dropped from config.

**Background install:** the Office step is split in two catalog steps.

1. **`office`** (**moved** to right after `vendor-pass1`, just before `windows-update`; my call, see "What runs alongside Office" below):
   - Same checks as v1: already installed, ODT found and signed, XML written.
   - Then it **starts** `setup.exe /configure` and does not wait. It keeps the process in memory and records in the step's `Data` the process id, its start time, and the deadline (start + `timeoutsMinutes.office`).
   - It returns Done with `Microsoft 365 installing in the background`.
2. **`office-finish`** (new, placed right after `windows-update`):
   - Waits (ticking) until the background process ends or its deadline passes. At the deadline it kills the process tree: Failed `Office setup timed out`.
   - Exit 0 → Done. 3010 or 1641 → Done with Reboot Now.
   - When the exit code is unknown, Office counts as installed if the product shows in `ProductReleaseIds`. The exit code is unknown when this step runs in a new process after a crash: it then waits for a live Office setup process to finish, if one is running.
   - Office not installed and no process left (killed by an unexpected restart): **one** install in the foreground, the v1 way. A second failure is Failed.
   - Then it creates the desktop shortcuts (§4.7).

**Restarts wait for Office.**
- `Invoke-ControlledReboot` first waits for a background Office process that is still running, ticking, with NOW showing `Waiting for Microsoft 365 to finish before restarting`.
- The wait lasts until the Office deadline. At the deadline it kills the process tree, then restarts; `office-finish` later reports the failure.
- The restart is never refused because of Office.
- A restart that a vendor tool or Windows forces anyway is covered by `office-finish`'s foreground retry.

**What runs alongside Office:** only Windows Update round 1, up to its restart (my call).
- **Why `office` moves after `vendor-pass1`:** next to the driver tools, Office could be killed or blocked. A Lenovo BIOS package restarts the PC by itself, which would kill Office. Two installers can also collide on the Windows Installer lock (error 1618).
- **So these all happen before Office starts:** every Windows Installer–based install (Chrome, 7-Zip, the vendor tools and their packages) and every restart a vendor tool forces.
- **Office still finishes mostly out of sight.** Windows Update round 1 on a fresh machine is long because of the big cumulative update, so it hides most of Office's install time.

**Office's result across the restart** (my call):
- When the restart wait sees the Office process end, it stores the exit code in the `office` step's `Data` before restarting.
- When it has to kill Office at the deadline, it stores a `killed at deadline` marker instead.
- `office-finish` reports from these after the restart. The marker means Failed (`Office setup timed out`), not a foreground retry.

**Display:**
- **Checklist:** one line, `Microsoft 365`. While the background job runs it shows `[>>] Microsoft 365 (bg)` with its own timer. Once `office-finish` has a result, it shows that result.
- **`office-finish`:** it has no line of its own.
- **Office not chosen:** both steps are left out of the plan.

### 4.7 Office desktop shortcuts

- **When:** once Office is installed, including the "already installed" case. Done by `office-finish`.
- **What:** `Word`, `Excel`, `PowerPoint` and `Outlook` shortcuts on the **public desktop** (all users), pointing at the Click-to-Run executables:
  - `WINWORD.EXE`, `EXCEL.EXE`, `POWERPNT.EXE` and `OUTLOOK.EXE`
  - under the Office install path read from the Click-to-Run registry, e.g. `...\root\Office16\`
- **Idempotent:** an existing shortcut is left alone, and a missing executable is skipped.
- **On failure:** a yellow Note, `Office desktop shortcuts could not be created`.

### 4.8 Report additions

`Setup-Report.txt` gains two sections:

- **`Windows updates installed`:** KB and title, per round.
- **`Driver updates`:** per vendor pass, the list found and the final status where known.

The full activity history stays in `Logs\activity.txt`.

## 5. Constraints (from v1, still binding)

- Windows PowerShell 5.1, no modules, ASCII console text, `dd/MM/yyyy HH:mm` in the report.
- Never parse localized output for a decision. Display-only parsing of vendor logs is allowed, with a silent fallback.
- Every child process runs through `Invoke-External` with a timeout.
  - **The one exception is the Office background process.** Its timeout is enforced by `office-finish` and the restart wait.
  - Nothing may wait without a deadline.
- No prompts, ever.
- Tests mock every system call. Every new behaviour gets tests.
- `ErrorAction.Tests.ps1`, `Encoding.Tests.ps1` and the full suite must stay green.
- The launcher must not change, so the USB sticks stay valid. If a change truly needs the launcher, say so before building it.

## 6. Left to the builder

- Function and file names, following the existing patterns.
- Exact colours, spinner frames and activity wording.
- The column layout algorithm.
- How detail sources are registered: for example, a step sets a provider scriptblock that the tick calls, cleared by the runner when the step ends.
- Catalog title wording.
- The exact JSON shape of the WU progress file.

## 7. To prove on real machines

Add these to `docs/testing.md` and `docs/spikes.md`:

- **Dell:** the `dcu-cli /scan -report` XML fields, and what the apply log lines look like.
- **HP:** HP Image Assistant `/Action:List`: where the report is and what it holds, and whether HPIA writes a live log.
- **Lenovo:** whether `-action LIST` works through AdminCommandLine and where its results go (SPIKE#4).
- **Windows Update:**
  - English titles via `UserLocale` on Hebrew Windows.
  - Installing one update at a time on a fresh Windows 11 machine with 10 or more updates: same end state as the batch install, and the time difference.
- **Office:**
  - The ODT `ExcludeApp` IDs.
  - The background install while Windows Update round 1 and a vendor pass run.
  - The restart waiting for Office.
  - A forced restart mid-install, then the foreground retry.
- **Screen:**
  - Rendering, colours and resizing in conhost and in Windows Terminal.
  - Readable from a metre away.
  - No flicker over a 30-minute step.

## 8. Build order (Ben chose A, 20/10/2026)

The driver-list readers (Dell scan XML, HP list report, vendor log lines) need real output from the tools. Ben's anti-pattern registry says to test on the target system rather than predict from documentation. Two orders are possible:

- **A. Build the rest now.** The start screen, the tick and screen, the activity feed, Office, the shortcuts and the Windows Update list are built and published after a VM test. Ben runs a 5-minute capture script (`tools\spikes\`) on one Dell and one HP laptop when they come through the shop. Each brand's driver list is built from what that script captured. Until then, driver passes show the tool's live log line and the timer, not a list.
- **B. Capture first.** Ben runs the capture script on a Dell and an HP before any building starts. Everything ships in one go.

## 9. Fixes from the first real-machine test (20/10/2026)

**Machine:** Dell Pro 15 Essential, Windows 11 Home 25H2 in Hebrew, release `v2026.10.19.1`. The evidence is the copied `C:\BenTech\Setup` folder (setup.log, transcripts, wu-round*.json, Setup-Report.txt). These fixes are built **first** and may ship as their own release before the rest of v2. Ben approves each publish.

### 9.1 Final screen colours (the "white screen")

**Cause:**
- Windows ships a console profile for `powershell.exe` (`HKCU\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe`) that remaps two palette entries:
  - 5 (DarkMagenta) to `#012456`, the PowerShell blue
  - 6 (DarkYellow) to `#EEEDF0`, near white
- The YELLOW verdict painted DarkYellow, which was near white, and wrote White text on it. The screen looked empty except for the cursor.
- The transcript shows the full final screen was drawn.

**Rule from now on:**
- No screen uses `DarkYellow` or `DarkMagenta`, as foreground or background.
- Every screen line sets its foreground **and** background explicitly.
- Verdict colours:

  | Verdict | Background | Text |
  |---|---|---|
  | YELLOW | `Yellow` | `Black` |
  | GREEN | `DarkGreen` | `White` |
  | RED | `DarkRed` | `White` |

- The v2 start and progress screens draw on `Black`.
- A test scans `src\UI` (and any other drawing code) for `DarkYellow` and `DarkMagenta`.

### 9.2 Driver updates skipped by Windows Update

**Cause:** v1 skipped every update whose `InstallationBehavior.CanRequestUserInput` is true. On the Dell, all 9 driver and firmware updates had that flag, so both rounds skipped them. Windows then installed them by itself after the run, which left "restart pending".

**New rule:**
- Updates of type **Driver** are installed even when `CanRequestUserInput` is true. The installer already runs with `ForceQuiet` and without source prompts, and the round timeout stays the backstop.
- Software updates keep the v1 rule.

**Firmware:**
- A driver update whose `DriverClass` (from `IWindowsDriverUpdate`; not localized) is `Firmware` is installed only on mains power. Power is read at the start of each round.
- On battery, firmware updates are left alone: not hidden, and not counted as failures. The step adds the existing battery Note.

**To prove on a real machine:** the `DriverClass` value of the Dell firmware updates.

### 9.3 Vendor app: check it is really there

- winget reported success for Dell SupportAssist after 7.5 minutes, but Ben did not see the app.
- **New check:** after a successful install, the step checks that the app is present, using a `verify` entry per vendor in `config.json` (file paths and/or service names). Found → Done. Not found → Failed `<app> was not found after install`.
- **Unknown values:** while a vendor's values are not known yet, `verify` is left out and v1 behaviour stays. Ben's check of the Dell's Start menu, plus the capture script (Task 1), supply the values.
- An activity line says which check passed.

### 9.4 Chrome as default browser: the check ran too early

**Cause:** after the final restart, the check ran **one second** after sign-in. Finalize then removed the policy value and the XML at once, probably before Windows had applied them.

**New behaviour:**
- After the final restart, Finalize polls for `ChromeHTML` for up to **120 s**, ticking.
- It removes the policy value and the XML only after Chrome is confirmed as default, or after the wait ends.
- Still not default after the wait → the existing yellow Note and the **B** hint.

**To prove on a real machine:** whether the policy is honoured on Windows 11 **Home**.

### 9.5 Small items

- **Report text:** `ConvertTo-ScreenText` strips Unicode direction and format marks (U+200E, U+200F, U+202A–U+202E, U+2066–U+2069) before the ASCII filter. Hebrew Windows put `??` before `Microsoft Windows 11 Home`.
- **Windows activation (Ben's Q7, A):**
  - In Finalize, before the final restart: when Windows is not activated and a product key is installed, ask Windows to activate, by calling the `Activate` method of the Windows `SoftwareLicensingProduct` entry. This runs in a child PowerShell through `Invoke-External` with a 3-minute timeout.
  - The report reads the status afterwards, as before.
  - A failed attempt is logged, and the Note stays `Windows not activated`.

## 10. No leftover folder (Ben's Q6, A)

The tool keeps `C:\BenTech` **while it runs**. It restarts several times, and the elevated resume task has to run its own verified copy. A USB stick can't hold that safely: FAT/exFAT has no permissions, and the stick moves between 5–7 laptops. Cleanup happens when the technician **finishes** the final screen.

1. **Finishing the final screen:** `Enter` finishes (my call: a stray key must not throw the logs away). `B` and `R` work as before, and other keys are ignored. The screen gains one live line, re-checked every second:
   - `USB stick found (E:) - logs will be saved there`
   - or `No BenTech USB stick - plug it in now to keep the logs`
2. **Finding the stick:**
   - On a new run (not a resume), `setup.ps1` records the launcher's path from `$env:BT_SELF`, plus that drive's volume serial number, in `state.json`. The launcher does not change.
   - At the end, the stick is the drive with that serial. If it isn't plugged in, the stick is any other drive (not the system drive) holding `BenTechSetup.cmd` in its root.
3. **Saving the logs:** copy `C:\BenTech\Setup\Logs` to `<stick>\BenTech-Logs\<PC name>\`.
   - Before copying, the folder for that PC name is deleted, so a re-run replaces it.
   - The PC name is the new name, for example `DELL-J0C7QK4`.
   - A failed copy shows on screen. Deletion still goes ahead after the technician presses Enter once more.
4. **Deleting the Desktop launcher:** if the run started from the user's or the public Desktop, that launcher copy is deleted. A launcher on a removable drive, or anywhere else, is never deleted.
5. **Deleting `C:\BenTech`:**
   - First stop the transcript and logging, release the run lock and mutex, and move out of the folder.
   - Then delete it with `cmd.exe /c rd /s /q` through `Invoke-External`. `rd` removes junctions without following them. PowerShell 5.1's `Remove-Item -Recurse` would follow them.
   - Also remove `C:\ProgramData\BenTech` if it is empty.
   - **If deletion fails:** retry 3 times, 2 s apart, then show `Could not delete C:\BenTech - delete it by hand` and wait for a key.
6. **Esc on the start screen** (cancel) also deletes `C:\BenTech`, because nothing ran. A **crash** leaves everything in place for diagnosis, as in v1.
7. **What's lost:**
   - **"Previous run":** the start screen's `Previous run:` line now only appears after an unfinished run, because a finished run leaves nothing behind. Earlier results live in the stick's `BenTech-Logs` folder.
   - **Re-runs:** there is no state to archive on a re-run after a finished run.

**To prove on a real machine:**
- the stick detection
- the copy to exFAT
- the deletion while the final process still runs from `C:\BenTech\Setup\setup.ps1`
- the Desktop-launcher deletion
