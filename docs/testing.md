# Testing: VMs and real laptops

The Pester suite (`tools\Invoke-Tests.ps1`) mocks everything that touches the machine. It cannot prove Task Scheduler, `icacls`, the Windows Update COM API, vendor tools, the Store, winget, reboots, power settings or console colours. This checklist is for exactly those things: every item here was only unit-tested. Spec reference: [section 17](specs/2026-10-18-bentech-winsetup-design.md) for v1, and [sections 7, 9 and 10](specs/2026-10-20-progress-visibility-design.md) for v2 (the progress screens, Office in the background, no leftover folder). Open research questions (SPIKE#1 to #5) are in [spikes.md](spikes.md).

How to use it: tick the boxes on a printed or copied file. Make one filled copy of section 1 per VM type, and one copy of section 3 per laptop. Keep each filled copy next to the machine's `Logs\` folder, copied out after the run (v2: from the stick's `BenTech-Logs\<PC name>` folder, see section 0).

The v2 items are sections 1.10 to 1.16 (every VM) and 3.7 to 3.9 (laptops). The older items in sections 1.3 to 1.9 were brought up to date with v2 where it behaves differently (the start screen, the final screen, the cleanup and the re-run).

## 0. Before you start

- [ ] A release is published and `dist\BenTechSetup.cmd` is current. Its SHA-256 equals the hash in `keys\launcher.sha256`.
- [ ] Each VM has a **checkpoint** taken right after OOBE: a local administrator account with **no password**, no Microsoft account, no domain, internet works. Roll back to it before every run.
- [ ] Copy `BenTechSetup.cmd` into the VM from a USB stick, mounted VHD or ISO, or the VM's file-copy integration. Don't download it in a browser (that adds the Mark-of-the-Web, which the real USB flow doesn't have).
- [ ] **Where the evidence is (v2).** `C:\BenTech` is deleted when the final screen is finished with Enter, so after a normal run the evidence is the USB stick's `BenTech-Logs\<PC name>\` folder. Keep a USB stick formatted exFAT with `BenTechSetup.cmd` in its root plugged in for the whole run, or plug it in while the final screen shows `No BenTech USB stick`. After a **crash**, or after anything that does not end in Enter on the final screen, nothing is deleted: copy `C:\BenTech\Setup\Logs\` (and `state.json`) out of the machine from an elevated prompt before you touch the machine again. To keep a VM's logs without a stick, copy them out by hand **before** pressing Enter (with no stick, Enter deletes the logs without asking).
- [ ] Note the release version and the date on each filled copy.

---

## 1. Core checks: run on every VM

### 1.1 Launcher and elevation

- [ ] **The UAC elevation line.** Double-click the launcher as the (non-elevated) administrator. Exactly one UAC prompt appears. Click Yes: the first window closes and one elevated console runs the launcher. No second UAC prompt appears at any later point, including after reboots.
- [ ] Click **No** on the UAC prompt: nothing runs, and `C:\BenTech` does not exist.
- [ ] The elevated window prints `downloading the latest version...` then `Signature OK. Starting setup...`.
- [ ] No SmartScreen warning and no Defender detection for the `.cmd` copied from the stick.
- [ ] The launcher works from a folder with a space in its path (for example `D:\My Tools\`).
- [ ] **Apostrophe in the path (triage 269).** Run it once from a folder with an apostrophe, for example `D:\O'Brien\`, and once from the Downloads folder of an account named with a geresh (`ג'ני`): one UAC prompt, then a normal run. (The launcher passes its own path through `BT_SELF`; the unit test covers only the non-elevated part.)
- [ ] **Full paths (R30).** Put a `powershell.bat` and a `fltmc.bat` that each write a marker file next to the launcher, then run it: neither marker appears.
- [ ] Unplug the network before the double-click: the launcher says `Cannot reach GitHub - retrying in 30s` and carries on by itself when the network returns. (Optional: leave it unplugged for about 10 minutes and confirm it gives up with exit code 4.)

### 1.2 Admin-only `C:\BenTech` (R28, R28b, R28c)

Use SIDs when you read ACLs: Administrators `S-1-5-32-544`, SYSTEM `S-1-5-18`.

- [ ] On a clean checkpoint the launcher creates `C:\BenTech`. `icacls C:\BenTech` shows **only** Administrators and SYSTEM with `(OI)(CI)(F)`, and no inherited entries (nothing for Users, Authenticated Users, CREATOR OWNER). `(Get-Acl C:\BenTech).Owner` is **BUILTIN\Administrators**, not the signed-in user. Same check on `C:\BenTech\Setup` and the files in it.
- [ ] A second, standard (non-admin) account cannot open, create or read anything in `C:\BenTech\Setup`.
- [ ] **Pre-created by a non-admin.** Roll back, sign in as a standard user, run `mkdir C:\BenTech`, then run the launcher as the administrator: it prints `C:\BenTech already exists and is not admin-only. Delete it (as administrator) and run again. Nothing was run.`, the exit code is **5**, nothing is written into the folder, and there is no resume task. Delete the folder as administrator, run again: it works.
- [ ] **Pre-created by an elevated `mkdir C:\BenTech`** (it inherits Authenticated Users: Modify from `C:\`): exit code 5 as well.
- [ ] **Pre-created junction.** `mkdir C:\bt-target`, then `mklink /J C:\BenTech C:\bt-target`: exit code 5, and the target folder's permissions are unchanged (compare `icacls` before and after).
- [ ] A `C:\BenTech` left by an earlier good run (admin-only) is accepted on the next run, with no `icacls` change.

### 1.3 Start screen

- [ ] Shows the machine, serial, power (`ON CHARGER` / `ON BATTERY`) and `New PC name` (at most 15 characters), then WHAT WILL HAPPEN with the keys that change each line (see 1.11 for the v2 screen checks).
- [ ] **(a)** On a VM: the `Type` line is `DESKTOP (no driver tool for this brand)` (a VM defaults to Desktop). No vendor steps appear later.
- [ ] A VM shows no `ON BATTERY` line.
- [ ] The countdown goes 30 to 0 and starts by itself. `L`, `D`, `Z` and `O` change the mode, 7-Zip and Office (OFF, BUSINESS, HOME) and reset the countdown to 30. `Enter` starts at once.
- [ ] `Esc` cancels. Afterwards `Get-ScheduledTask BenTechSetup-Resume` finds nothing and, on a fresh machine (no earlier run), `C:\BenTech` is gone too (v2 spec 10.6, see 1.16). After an *unfinished* earlier run, Esc deletes nothing.
- [ ] Press Enter repeatedly while the launcher is still downloading: the start screen still counts down (stray keys are thrown away).
- [ ] Put more than 1 GB in Documents and run again: the yellow text `This PC already has user files or is older than 14 days - press ENTER to run anyway` appears and nothing starts by itself.
- [ ] Steps turned off on the start screen (7-Zip OFF, Office OFF) are absent from the progress screen and the report.

### 1.4 Resume, reboots and power

- [ ] **(b)** The run resumes by itself after **each** reboot (automatic sign-in because there is no password), with no click.
- [ ] **The reboot after the PC rename resumes too.** The resume task is registered for `<old name>\<user>`; check it survives the rename. Before the rename: `Get-ScheduledTask BenTechSetup-Resume | Select -Expand Principal`, and `... | Select -Expand Actions` shows `Execute` as the full `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` path (triage 180). After the restart: the setup window appears at logon, and `Get-ScheduledTaskInfo BenTechSetup-Resume` shows a fresh `LastRunTime`. If this fails, the machine sits at an empty desktop after the rename. Unit tests cannot show this, so it is the first thing to check.
- [ ] **(c)** After every logon the progress screen is in front: `[OK]` done steps, `[>>]` for the running step, `[..]` pending, the NOW timer running, and `Restarts N` in the header (see 1.12). After a real restart `Back after restart N` is the newest JUST HAPPENED line.
- [ ] Before every restart a `Restarting in N s ...` countdown (15 s) is on screen, and the reboot count never goes above 12.
- [ ] Nothing ever waits for input: no "Let's finish setting up your device", no Store sign-in, no second UAC, no BitLocker recovery screen.
- [ ] Double-click the launcher while a run (or its resume) is active: `Setup is already running on this machine`, exit code 2, and `setup.ps1` and `state.json` are untouched.
- [ ] **Power off the VM abruptly** (not shut down) during a step: at the next logon the run resumes, the step runs again, and `state.json` is valid. If a `Logs\state.corrupt-*.json` appears, note it.
- [ ] During the run: Fast Startup is off (`HiberbootEnabled` is 0 under `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power`), the machine never sleeps or turns the screen off, and `NoAutoRebootWithLoggedOnUsers` is 1 under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`.
- [ ] **A failed resume-task registration is red, with no reboots (final review I1).** Unit tests prove the logic with mocks only; this proves the real `Register-ScheduledTask` failure is caught. On a fresh checkpoint, before the run, block the task name with a Task Scheduler *folder* of the same name (elevated PowerShell): `$s = New-Object -ComObject Schedule.Service; $s.Connect(); $null = $s.GetFolder('\').CreateFolder('BenTechSetup-Resume')`. (Not verified to make the registration fail; if the run still registers the task, note it and try another way, for example a deny ACE on `C:\Windows\System32\Tasks`.) Expected: Prepare is red `Could not register the resume task` (`setup.log` shows the retry after 10 s), the run continues **without any restart** (`Restart skipped: no resume task` instead of a countdown), and the final screen is RED with those lines. Afterwards remove the folder: `$s.GetFolder('\').DeleteFolder('BenTechSetup-Resume', 0)`, and roll the checkpoint back.
- [ ] **Clicking into the window never pauses the run (final review I3).** On the Windows 10 VM (classic console host), and once on Windows 11 with the default terminal set to *Windows Console Host*: click once into the progress screen mid-run and wait a minute. The title bar must not say `Select`, the timer keeps counting and `setup.log` keeps advancing. (QuickEdit is turned off at start; Windows Terminal never blocks anyway.)
- Other steps (check the report, then the machine):
  - [ ] Time zone is Israel Standard Time; Hebrew keyboard added next to English.
  - [ ] This PC and the user folder are on the desktop.
  - [ ] The bloatware list is gone; Store, Photos, Calculator, Notepad, Paint, Terminal are still there.
  - [ ] The PC is renamed to the name the start screen showed.
  - [ ] `winget --version` works.
  - [ ] C: is not encrypted (`Get-BitLockerVolume`, no localized text), and device encryption does not come back after a reboot.

### 1.5 App installs

- [ ] **Chrome.** Installed; the report shows its version. The step logged a valid `Google LLC` signature before running the MSI.
- [ ] **AnyDesk `--get-id`.** The ID (9 or 10 digits) is read within the 2-minute budget. Note whether it came from `AnyDesk.exe --get-id` or from the `service.conf` fallback (`ad.anynet.id=`). The same ID is on the final screen, in the report, and in the AnyDesk window.
- [ ] AnyDesk starts with Windows and has a desktop icon. A connection attempt makes the customer **accept** it. Settings, Security: unattended access is **off** and no password is set.
- [ ] **Office (ODT).** The ODT comes from winget (`C:\Program Files\OfficeDeploymentTool\setup.exe`, Microsoft signature checked), `/quiet /extract:` extracts to `Downloads\ODT`, and `setup.exe /configure` runs without any dialog. Exit codes 0, 3010 and 1641 are all Done (3010 and 1641 show `Office installed (restart pending)`). Word opens with Hebrew UI first, English also installed. In v2 only Word, Excel, PowerPoint, Outlook (classic) and OneNote are installed, and the install runs in the background (checks in 1.14). The report lists `Microsoft 365` with a version.
- [ ] **Chrome as default browser (SPIKE#1).** After the final sign-in, `https` resolves to `ChromeHTML`. Check `HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoiceLatest` (ProgId) or Settings, Default apps. If it did not work, the final screen must be YELLOW with the Chrome hint, and **B** must open the Chrome page in Default apps. v2 waits up to 120 s for it after the final restart (checks in 1.10).
- [ ] 7-Zip installed via winget when it was ON.

### 1.6 Windows Update (real COM)

- [ ] Microsoft Update is registered on the first run, and the search finds updates on a fresh machine.
- [ ] Rounds run as search, download, install. `setup.log` shows one entry per round, each in a `-WuRound` child process, and a reboot between rounds when a restart is required.
- [ ] The loop ends when a search returns nothing. Note the number of rounds and the total time. The cap is 6 rounds (`caps.maxWuRounds`); a fresh machine that needs close to 6 is a sign to raise it.
- [ ] Optional updates (`BrowseOnly=1`) are skipped; software updates that need user input are skipped and logged (driver updates are not, see 3.8); Defender definitions don't keep the loop going.
- [ ] **Busy and reboot-pending codes.** A fresh install often has the Windows Update orchestrator busy. Look in `setup.log` for `0x80240016` or `0x8024A000` (the step waits 120 s and continues) and `0x80242014` (continues with a reboot). They must not hide good updates: those rounds don't raise the per-update failure counts.
- [ ] **Hiding a mandatory update.** Some updates cannot be hidden (`0x80248016`). If a failing update shows up, the round continues, and the verdict lists `Windows update failed repeatedly (left to Windows Update): ...` in red. To provoke it on purpose: disable the Windows Modules Installer service in the checkpoint before the run (not verified to give this exact error).
- [ ] **Enablement package (SPIKE#2).** From a Windows 11 **24H2** checkpoint, the 25H2 enablement package is offered, installed, and the build moves to 25H2 after one reboot. If it is offered only with `BrowseOnly=1`, Task 14 needs a third search (see [spikes.md](spikes.md)).
- [ ] No leftover update loop: the same KB is not installed round after round.

### 1.7 Final screen on a real console

- [ ] **(d)** The whole console turns the verdict colour: GREEN is White on DarkGreen, YELLOW is **Black on Yellow**, RED is White on DarkRed. The banner matches (`SETUP COMPLETE`, `COMPLETE - CHECK NOTES`, `COMPLETED WITH ERRORS`). **All three are readable in a `powershell.exe` window started by the resume task with the default console profile** (the v1 YELLOW was white on near-white there, spec 9.1).
- [ ] Check all three colours at least once across the VMs. For RED, make a step fail on purpose (for example a hosts-file entry blocking `dl.google.com` before the run): the Chrome step fails and the screen is red.
- [ ] The AnyDesk ID is in big digits, readable from 3 to 5 metres. Machine, new name, total time and reboot count are shown.
- [ ] Failures (`X`) and notes (`!`) are listed with one-line reasons, at most **3 failures and 2 notes**, each list then `... and N more: see the report`.
- [ ] **Worst-case final screen in a 30-row window (triage 240).** Set the console to 30 rows (Properties > Layout > Window size, height 30; in Windows Terminal, a profile with `"rows": 30`), and provoke more than 3 failures and 2 notes with Chrome not the default (for example block `dl.google.com` and `download.anydesk.com` in `hosts` and turn 7-Zip and Office on with winget broken). The layout is 29 lines, so with the row the frame writer keeps free it fills the window exactly: the top `=====` frame, the banner and the AnyDesk ID must all be visible without scrolling, the USB stick line sits above the report line, and the report line is the last row of text.
- [ ] **Enter finishes** the screen (and starts the cleanup, see 1.16). **B** opens Settings, Default apps for Google Chrome; **R** opens `Setup-Report.txt` in Notepad. Both keep the final screen up. Every other key (Esc, Space, Q, ...) does nothing.
- [ ] A key pressed during the last step doesn't finish the screen early, and a buffered Enter does not skip the cleanup's `Press ENTER to delete ... anyway` stop (1.16).
- [ ] The stick line follows plugging the stick in and out within a second (1.16).
- [ ] Colours are back to normal when the final screen closes (in a console that stays open). Try the Windows 11 default terminal (Windows Terminal) and, once, the classic console host.

### 1.8 Report and cleanup

- [ ] **(e)** `C:\BenTech\Setup\Logs\Setup-Report.txt` (while the final screen is up; afterwards on the stick) exists and is complete: tool version, result, started/finished (`dd/MM/yyyy HH:mm`), duration, machine and serial, PC name old to new, mode and detected type, Windows build and architecture (the `Windows` line has **no `??`** before the product name on Hebrew Windows, spec 9.5), activation, BitLocker, Smart App Control (`Off`, `On`, `Evaluation` or `Unknown`; compare with Windows Security > App & browser control), AnyDesk ID, apps with versions, the Windows Update line, the `Windows updates installed` list (one line per update, per round), one line per step with its time, and the Failures and Notes sections. Its result matches the final screen. The file is plain ASCII.
- [ ] **(f)** While the final screen is up (before Enter), none of these exist:
  - [ ] the resume task (`Get-ScheduledTask BenTechSetup-Resume` finds nothing)
  - [ ] `NoAutoRebootWithLoggedOnUsers` under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`
  - [ ] `C:\BenTech\Setup\Downloads\`
  - [ ] `DefaultAssociationsConfiguration` under `HKLM\SOFTWARE\Policies\Microsoft\Windows\System`, and `%ProgramData%\BenTech\DefaultAssociations.xml`
  - [ ] the Lenovo `AdminCommandLine` value (both registry views; Lenovo laptops only)
  - [ ] `C:\BenTech\Setup\setup.ps1` and `config.json`
  - [ ] installers left in `%TEMP%`
- [ ] While the final screen is up, `Logs\` and `state.json` are still there. Vendor tool logs are in `Logs\`. After Enter, `C:\BenTech` is gone and the same files are in the stick's `BenTech-Logs\<PC name>\` (1.16).
- [ ] **Read the logs the safe way (M9).** While `C:\BenTech` exists (the final screen is up, or after a crash), open them with **R** on the final screen or from an elevated prompt (`notepad C:\BenTech\Setup\Logs\setup.log` in an administrator Terminal), never by browsing `C:\BenTech` in Explorer: Explorer's "Continue" button adds your account to the folder's permissions, and the next re-run then refuses the folder with exit code 5. (To see it happen once on a VM: browse there in Explorer, click Continue, run the launcher again: exit 5.)
- [ ] Final power settings: on AC never sleep and screen off after 15 minutes; on battery the Windows defaults (the originals are in `state.json` under `Power`). Fast Startup stays off. The lid action is back to what it was.

### 1.9 Release and re-run checks

- [ ] **(g) A tampered release is refused.** On the host, build and sign a throwaway release with the real key, change one byte of `setup.ps1` afterwards, and copy the folder into the VM:

  ```
  tools\Build-Bundle.ps1 -Version 2099.01.01.1 -OutDir C:\tamper
  tools\Sign-File.ps1 -Path C:\tamper\setup.ps1
  tools\Sign-File.ps1 -Path C:\tamper\config.json
  $b = [IO.File]::ReadAllBytes('C:\tamper\setup.ps1'); $b[100] = $b[100] -bxor 1; [IO.File]::WriteAllBytes('C:\tamper\setup.ps1', $b)
  ```

  In an **elevated** command prompt in the VM run `BenTechSetup.cmd -BaseUrl file:///C:/tamper -NoPause`. Expected: red `SECURITY CHECK FAILED - files are not signed by BenTech. Nothing was run.`, exit code **3**, no `C:\BenTech`, no resume task. Repeat with only `config.json` changed (still exit 3), with a `.sig` deleted (exit 4), and with a release signed by a different throwaway key (create it outside the repo with `tools\New-SigningKey.ps1 -PrivateKeyPath <p> -PublicKeyOut <p>`, sign with `tools\Sign-File.ps1 -PrivateKeyPath <p>`; exit 3). The `-BaseUrl` parameter is the one the launcher tests use. If it doesn't reach the launcher, the real release is downloaded and a normal run starts: roll the checkpoint back. `tests\Launcher.Tests.ps1` covers this against `file://` folders; this repeats it with the real launcher on a clean machine.
- [ ] **(spec 8.8, v2 spec 10.7) Re-run on the same machine after GREEN.** A run finished with Enter deletes `C:\BenTech`, so the start screen normally shows **no** `Previous run:` line (it would show `Previous run: ... - GREEN` if the folder survived: the window closed instead of Enter, `rd` failed, or Windows is not on C:), there is no state to archive and the counters start at zero, and every step runs again but finishes quickly. Nothing is duplicated: one AnyDesk, one Chrome, the same PC name, the Hebrew keyboard added once. The stick's `BenTech-Logs\<PC name>` folder is replaced by the new run's logs, not added to.
- [ ] **A finished run leaves no hidden update (final review C1, verified by mocks only).** After a run that hid an update (RED `Windows update failed repeatedly (left to Windows Update): ...`), and before Enter, `setup.log` shows `Un-hiding the Windows updates the run hid` and `Windows Update un-hide finished` with `failed` 0, and no `Windows update still hidden` line is on the final screen. Then, in an elevated PowerShell, Windows Update lists **no** hidden update of that run: `$s = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher(); $s.ServerSelection = 3; $s.ServiceID = '7971f918-a847-4430-9279-4a52d1efe18d'; $s.Search('IsHidden=1').Updates | Select-Object Title` (it changes nothing). An update that refuses to be un-hidden must show red `Windows update still hidden: <title> - un-hide it in Windows Update`, never green.
- [ ] **Re-run after a RED run that was finished with Enter is not falsely green.** The run's hidden update was un-hidden at its end, so the re-run's search sees it again: it is tried once more (installed, or failed and reported), never silently missing. Note what the second run shows. After a RED run that was **not** finished with Enter (a crash, or Esc on the start screen), the state is still there too, and the first Windows Update round of the next run un-hides the previous run's updates once (`Updates hidden by the previous run un-hidden` in `setup.log`), as in v1.
- [ ] **Re-run after an *unfinished* run keeps the real power settings (final review I2).** Before the first run note the originals: `powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE`, `... SUB_SLEEP HIBERNATEIDLE`, `... SUB_VIDEO VIDEOIDLE` and `... SUB_BUTTONS LIDACTION` (read only the hex AC/DC values). Start a run and stop it before Finalize (while Windows Update runs, remove the resume task in an elevated PowerShell with `Unregister-ScheduledTask BenTechSetup-Resume -Confirm:$false`, then power the VM off at once; in this order, because after power-on the automatic sign-in would fire the task before you could remove it). Double-click the launcher again and let the new run finish. Expected: the start screen says `Previous run: ... - UNFINISHED`; afterwards, on battery (DC) the four values are the ones you noted (not 0), and on a laptop the lid action is back to what it was. If they are 0, the run must show the yellow note `Some power settings could not be restored`, never green.
- [ ] Re-run with a corrupt `state.json` (cut the file in half): it is archived as `Logs\state.corrupt-<time>.json` and a new run starts without a crash.
- [ ] Re-run on a machine that no longer looks fresh: no auto-start, Enter needed.
- [ ] Once a second release exists: a new release published **during** a run does not change that run (resumes use the pinned local copy; the report keeps the old version), and the next launcher run uses the newest one.
- [ ] Variants worth one run each: a Windows account with **Hebrew letters and a space** in its name (the resume task and child processes still start), and **Hebrew display language** (power settings, ACLs and Windows Update filtering still work).

### 1.10 The fixes from the first real-machine test (v2 spec 9)

The Dell test of release `v2026.10.19.1` found these. They are the first things to check on the section 9 release. The final-screen colours are checked in 1.7 (d) and the report's `Windows` line in 1.8 (e); the Windows Update, vendor-app and firmware items are laptop checks in 3.8.

- [ ] **Chrome as default after the final restart (spec 9.4).** After the final sign-in `setup.log` shows either `Chrome is the default browser` with `reads` and `waitedSeconds` (how long `ChromeHTML` took to appear after the sign-in; the wait is up to 120 s, polled every 5 s), or `Chrome is still not the default browser after the wait` after 120 s (then the verdict is YELLOW with the Chrome note and the **B** hint). The policy value and `DefaultAssociations.xml` are removed only after that. The screen keeps moving during the wait (NOW shows the wait timer).
- [ ] **No wait without a sign-in.** When the final restart was refused or failed (no resume task, reboot cap), nobody signed in after the policy was set: `setup.log` says `No wait for Chrome as default` and the default browser is read once. The run must not sit 120 s for nothing.
- [ ] **Is the policy honoured on Windows 11 Home at all?** Record the result for the Home VM (2.2, SPIKE#1): `reads`/`waitedSeconds` in `setup.log`, or the Note and the **B** hint.
- [ ] **Activation attempt (spec 9.5), on a machine with a product key** (Hebrew Windows 11 Home: the Dell). Before the final restart `setup.log` shows `Trying to activate Windows`, then `Windows activated` or `Windows activation attempt failed` with its exit code. After the run the `Windows not activated` Note is gone, or it stays and the failed attempt is in `setup.log`. A machine with no key logs `No Windows activation attempt: no product key is installed`; an already activated one logs `No Windows activation attempt needed`.
- [ ] **Sleep during the attempt (ruling V2-R8).** The attempt runs after the power settings are put back (on battery the Windows defaults), up to 3 minutes. A laptop on battery and idle may sleep in the middle: note whether it did and whether the run carried on after waking.

### 1.11 Start screen, v2 (spec 4.1)

- [ ] The countdown is **30 s** (`Starts by itself in N s` with a 20-character bar that empties) and the run starts by itself at 0.
- [ ] **Any key restarts it at 30 s**: `L`, `D`, `Z`, `O`, and an unknown key such as Space, F5 or Q. Only Enter starts at once and Esc cancels. Holding a key down stays smooth (no flicker, no lag).
- [ ] Colours, all on a **black** window with no blue strips, in the classic console host (conhost) with the default `powershell.exe` profile and in Windows Terminal: frame grey, the chosen values green, `NO` and `OFF` dark grey, the ON BATTERY and not-fresh lines yellow.
- [ ] The `Type` line: `LAPTOP (driver tool + laptop app)`, `DESKTOP (no laptop app)`, and for a brand without a driver tool (ASUS, a VM) `(no driver tool for this brand)`.
- [ ] In an **80x25** window the ON BATTERY line (85 characters) and a very long model name are cut at the window edge and nothing else wraps.
- [ ] The not-fresh text (`This PC already has user files or is older than 14 days - press ENTER to run anyway`) appears with no countdown; `Previous run: dd/MM/yyyy HH:mm - UNFINISHED` appears after an unfinished run (a crash, or Esc on the start screen after one). After a run finished with Enter it normally does not appear; it does when that run's folder survived (window closed instead of Enter, `rd` failed, Windows not on C:), and then it shows that run's colour.

### 1.12 Progress screen, tick and activity feed (v2 spec 4.2 to 4.4)

- [ ] **Rendering.** In conhost the window is enlarged to about 100x45 at start (as far as the screen allows); in Windows Terminal it is not (a script cannot resize it) and the layout fits whatever size it has. Resize the window during a step in both: JUST HAPPENED shrinks first, then the NOW list; the header, the checklist and the first NOW line always stay.
- [ ] **Colours**, all on black, no blue strips: `[OK]` green, `[>>]` cyan, `[X ]` red, `[--]` dark grey, `[..]` default. Readable from a metre away.
- [ ] **A sign of life.** The spinner in the header turns and the timers (Total, NOW, `(bg)`) move every second during Windows Update round 1, a vendor pass, the Office restart wait, a download and the Chrome wait. No flicker and no scrolling over a 30-minute step. The first frame after a clear lands at the top even on a scrolled buffer, and text a child process prints between two frames does not leave debris.
- [ ] **Tick cost.** A redraw stays around 50 ms or less in conhost and in Windows Terminal: a step that takes N minutes without the screen does not take noticeably longer with it.
- [ ] **The reboot countdown** (`Restarting in N s ...`, 15 s) is still readable over the frame, and after the restart `Back after restart N` is the newest JUST HAPPENED line. A restart that was not ours (power-off, a vendor tool's forced restart) can show a lagging N: note it.
- [ ] **The transcript holds no redraws.** `Logs\transcript-*.txt` does not contain the progress screen repeated every second, and not the final screen's one-second redraw either.
- [ ] **Failed and skipped steps** show `[X ]` / `[--]` in the checklist and their reason in JUST HAPPENED (`<Title> FAILED - <reason>`, `<Title> skipped - <reason>`).
- [ ] **JUST HAPPENED survives a restart** (the history is still there after the machine comes back). A new run (not a resume) archives the old feed as `Logs\activity-<RunId>.txt` and starts empty.
- [ ] **The AnyDesk ID** appears in `Logs\activity.txt` (`AnyDesk <version> - ID <id>`) and **never** in `Logs\setup.log` (search `setup.log` for the ID: no match).
- [ ] The feed holds the facts a technician cares about: app versions, the new PC name, each bloatware app removed, BitLocker changes, time zone and keyboard, each Windows Update round's summary, each driver pass's summary, Office started and finished, the shortcuts.

### 1.13 Windows Update, one update at a time (v2 spec 4.5)

- [ ] **English titles on Hebrew Windows.** `UserLocale` 1033 is accepted by the WUA session: NOW and the report's `Windows updates installed` list show English titles (the Dell's round 1 had a Hebrew Defender title). If the session refuses it, the titles are ASCII-filtered with the KB number first.
- [ ] **One at a time vs batch.** On a fresh Windows 11 with 10 or more updates, run once with the default `OneAtATime` and once with `windowsUpdate.installMode` set to `Batch` in `config.json` (a throwaway build). Expected: the same end state (same updates installed, same restarts, same hidden list). Note the round times against the 90-minute cap (`timeoutsMinutes.wuRound`).
- [ ] **Live progress.** NOW shows `Installing 3 of 7` with the list and a marker per update; `Logs\wu-round<N>.progress.json` changes while the round runs (read it from an elevated prompt). With `Batch` the screen shows only the phase and the list.
- [ ] **A busy agent** (a fresh machine): whether it shows up as an exception from Install() or as a result HResult. Either way the loop stops there and the v1 handling of `0x80240016` / `0x8024A000` / `0x80242014` applies (1.6).

### 1.14 Microsoft 365 in the background (v2 spec 4.6 and 4.7)

- [ ] **The ODT accepts every `ExcludeApp` id** in `config.json` (`Access`, `Publisher`, `Teams`, `OneDrive`, `Groove`, `Lync`, `Bing`, `OutlookForWindows`). Drop any id the ODT rejects from `config.json`. Only Word, Excel, PowerPoint, Outlook (classic) and OneNote are installed.
- [ ] **It runs in the background.** After the drivers pass the `office` step ends Done at once (`Microsoft 365 installing in the background`), the checklist shows `[>>] Microsoft 365 (bg) mm:ss` with its own timer, and Windows Update round 1 runs next to it. The hidden `setup.exe` console window never shows, and its exit code is readable (activity line `Microsoft 365 setup ended (exit 0)`).
- [ ] **A restart waits for Office.** NOW shows `Waiting for Microsoft 365 to finish before restarting` with the timer against the 60-minute limit, and the restart comes after Office ends. At the deadline (test with `timeoutsMinutes.office` set to 2 in a throwaway build) the `setup.exe` tree is killed, the activity line says `Microsoft 365 setup stopped at its 2 min limit` and `office-finish` is Failed `Office setup timed out`. Check whether the Click-to-Run service keeps installing after that kill.
- [ ] **A forced restart in the middle of the install** (reset the VM while Office installs): after the restart `office-finish` makes **one** foreground install attempt (the ODT runs in the foreground); if that fails too the step is Failed and nothing is retried, also not after another crash. When it cannot tell what happened it is Failed `Office setup did not complete` and does not start an install beside one that may still be running.
- [ ] **`office-finish` after Windows Update** waits for a still-running Office (NOW `Waiting for Microsoft 365 to finish`); exit 0 is Done, 3010 and 1641 are Done with a restart (none extra when a restart already followed).
- [ ] **The four shortcuts** (Word, Excel, PowerPoint, Outlook) are on the **public desktop** with their icons, also for an already-installed Office (the step says `Office already installed`). `InstallationPath` in `HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` really holds the folder that contains `root\Office16`. A re-run leaves existing shortcuts alone, and a program that is not installed is skipped without a Note. The activity line reads `Desktop shortcuts: ...`.
- [ ] **Office OFF**: no Microsoft 365 line on the checklist, and neither `office` nor `office-finish` in the report.

### 1.15 Downloads and waits (v2 spec 4.3)

- [ ] A real HTTPS download through `DownloadFileTaskAsync` (the Chrome MSI, AnyDesk): the screen keeps moving. On a slow line (throttle the VM's network) the spinner stays alive for the whole download.
- [ ] **A stalled download.** Cut the network in the middle of one: the attempt is cancelled after **100 s** with no first byte or **300 s** with no growth after that (`download stalled`) and retried. The 30-minute cap per attempt holds on a very slow line. The cancelled `.part` file is released, so the next attempt can write it.
- [ ] **Waits that still do not tick:** starting the Dell service (up to 60 s) and the kill path of `Invoke-External`'s timeout (about 10 s). Note how long the screen stands still; anything longer is a bug.

### 1.16 No leftover folder (v2 spec 10)

Pressing Enter on the final screen copies the logs to the stick, deletes the Desktop launcher and deletes `C:\BenTech`. Use a VM checkpoint for each variant.

- [ ] **The stick is found by its serial**, also after it comes back under another drive letter (change the letter in Disk Management and press Enter), and by `BenTechSetup.cmd` in its root when the launcher ran from a Desktop. The system drive is never taken as the stick and network drives are not looked at.
- [ ] **The live line** `USB stick found (E:) - logs will be saved there` / `No BenTech USB stick - plug it in now to keep the logs` follows plugging the stick in and out within a second.
- [ ] **The copy to exFAT.** `E:\BenTech-Logs\<PC name>\` holds the whole `Logs` folder (`setup.log`, `Setup-Report.txt`, `activity.txt`, the vendor logs) and `state-final.json` (the run's `state.json`, final review M3). A re-run replaces that folder instead of adding to it. After the copy the screen shows `Logs saved to E:\BenTech-Logs\<PC name>` for about 3 seconds before the window closes (final review M4).
- [ ] **A link is never followed.** On an NTFS stick make `E:\BenTech-Logs` a junction (`mklink /J E:\BenTech-Logs C:\somewhere`; check that the command worked): the screen says `BenTech-Logs on the USB stick is a link; logs not saved`, and nothing in the junction target is copied or deleted.
- [ ] **A failed copy** (write-protected or full stick) shows why and `Press ENTER to delete C:\BenTech anyway`. Only Enter goes on, and an Enter pressed earlier does not skip that stop. With **no stick** it shows `No USB stick found: the logs are not saved` and goes on without waiting.
- [ ] **`C:\BenTech` is deleted while the final process still runs from `C:\BenTech\Setup\setup.ps1`**, and `C:\ProgramData\BenTech` is gone when it is empty (and stays when something else is in it). With a folder in use (open another **administrator** console and run `cd C:\BenTech\Setup\Logs` there before pressing Enter; Notepad would not do, it releases the file after loading it) `rd` cannot remove it, so it retries 3 times, 2 s apart, then shows `Could not delete C:\BenTech - delete it by hand` and waits for a key.
- [ ] **The Desktop launcher** is deleted when the run started from the user's Desktop, and from the public Desktop (also on a OneDrive-redirected Desktop); only a `.cmd` file is ever deleted. Does `cmd.exe` print `The batch file cannot be found` when the launcher it was running is gone (a run with no restart)? A launcher on the stick is never deleted. A launcher run from another local disk (for example `D:\Downloads`) sends the logs to that disk instead of the stick (a known limitation): note what happens.
- [ ] **A PC whose system drive is not C:** `C:\BenTech` is kept and the screen says `Not deleting ...`.
- [ ] **A resume task that cannot be removed keeps `C:\BenTech` (final review I1, verified by mocks only).** The task runs `C:\BenTech\Setup\setup.ps1` elevated at every logon, so the admin-only folder must stay while the task does. While the final screen is up, make the removal fail: in an elevated PowerShell re-register a task named `BenTechSetup-Resume` and put a deny-delete entry for Administrators on its file `C:\Windows\System32\Tasks\BenTechSetup-Resume` (not verified to make `Unregister-ScheduledTask` fail; try another way if the task still goes). Press Enter. Expected: the logs are saved, then `Resume task BenTechSetup-Resume is still registered: C:\BenTech kept - delete the task, then the folder, as administrator`, and the window waits for a key (an Enter typed earlier does not skip it); `C:\BenTech` is still there afterwards. Clean up: remove the deny entry, then the task, then the folder, as administrator. With the task gone (the normal case) the folder is deleted as before.
- [ ] **Esc on the start screen of a fresh machine leaves nothing** (no `C:\BenTech`, no resume task). Esc when an unfinished run left a state deletes nothing.
- [ ] **A crash leaves everything** for diagnosis: `C:\BenTech`, its logs and the resume task stay and the `Setup crashed` text shows. (Provoke one in a VM, for example by cutting `config.json` in half before a resume; not verified to crash.)
- [ ] `Previous run:` on the next start screen appears after an unfinished run, and after a finished run only when its `C:\BenTech` survived (it then shows that run's colour, for example `GREEN`); after a run finished with Enter whose folder was deleted it does not appear.

---

## 2. Per VM type

Each list adds to section 1; run section 1 on all three VMs.

### 2.1 Windows 11 25H2 Pro

- [ ] Start from the 25H2 checkpoint (local account, no password). Office toggled to **BUSINESS** (the default) and installed.
- [ ] **SPIKE#1:** the default-browser policy sets Chrome at the next sign-in on Pro. Result: set / not set.
- [ ] Device encryption is off and stays off (use a VM with a virtual TPM to make it relevant).
- [ ] A clean run ends **GREEN** if everything worked. Record the actual colour and every note.
- [ ] The 24H2 variant: from a 24H2 checkpoint the run ends on 25H2 (see SPIKE#2 above).

### 2.2 Windows 11 25H2 Home

- [ ] Office toggled to **HOME** (`O365HomePremRetail`) and installed.
- [ ] **SPIKE#1 on Home**, the likeliest to fail: Microsoft documents the policy for domain-joined machines. If Chrome is not the default after sign-in, the expected result is **YELLOW** (not red) with the hint, and **B** works.
- [ ] Windows Home has no Group Policy editor: the registry policy value is still written during the run and removed afterwards.
- [ ] The Hebrew keyboard and the time zone apply on Home.

### 2.3 Windows 10 22H2

- [ ] **winget** may be missing on a fresh Windows 10: the App Installer bundle is installed from `aka.ms/getwinget`, or the step ends `winget unavailable` while Chrome and AnyDesk (direct downloads) still install. Record which happened and what the final colour was.
- [ ] The final screen is at best **YELLOW**, with `Windows 10: no security updates`.
- [ ] The Windows 11 upgrade is **never** offered or installed: the machine stays Windows 10 22H2.
- [ ] No endless update loop (for example KB5034441): a stuck update is hidden and reported in red, the run still finishes, and the update is un-hidden again at the end (1.9).
- [ ] **SPIKE#1 on Windows 10 Pro:** the default-browser policy result.
- [ ] 7-Zip OFF and Office OFF on this VM, to check the optional-step skipping end to end.
- [ ] **QuickEdit (final review I3), the classic console host:** click into the progress screen mid-run (section 1.4); the run must keep going.

---

## 3. Real laptops

One each of Dell, Lenovo, HP and ASUS before calling v1 done. A VM cannot test any of this.

### 3.0 Safety preconditions (read before every laptop run)

A real run changes the machine for good and there is no checkpoint to roll back to. Tick every box before you start.

- [ ] **Shop stock or lab hardware only. Never a customer's machine.**
- [ ] **Fresh OOBE:** a new local account with no password, no Microsoft account, and nothing on the drive you want to keep.
- [ ] **Start on AC power**, with the charger connected for the whole run. The only exceptions are the two battery tests in 3.1, and each says exactly when the charger may come out.
- [ ] You know what the run does: it decrypts BitLocker, renames the PC, removes apps, installs and uninstalls software, changes power settings and policies, restarts many times, and **may flash the BIOS or firmware**. There is no rollback. A BIOS or firmware flash that loses power or is interrupted can leave the laptop unbootable.
- [ ] **Never remove the charger, close the lid, press the power button or pull the battery** while a vendor tool is running, while a `Restarting in N s ...` countdown is showing, during a restart, or on any "do not turn off" firmware update screen. A BIOS or firmware package can be staged to apply at the next restart, so a restart is also a flash window.
- [ ] A Windows install USB and the vendor's recovery option are within reach.

### 3.1 Every laptop

- [ ] The start screen shows the right manufacturer, model and serial, and the `Type` line reads `LAPTOP (...)` (see 1.3 and 1.11). Mode is LAPTOP; the name is `<BRAND>-<SERIAL>` (at most 15 characters).
- [ ] **(h) Close the lid** mid-run for a few minutes, **only while the Windows Update loop is running** (the progress screen shows Windows Update as the running step, no vendor tool is running, no restart countdown): the laptop does not sleep, `setup.log` keeps advancing, and after Finalize the original lid action is back. Open the lid again before the run reaches a restart.
- [ ] **Charger connected from the start:** BIOS and firmware updates are allowed in pass 1.
- [ ] **Battery run (a separate run, battery at 80% or more):** unplug the charger at the **start screen**, before anything has started, so the whole vendor pass runs on battery and no flash can be in progress. The yellow `ON BATTERY` line shows. In pass 1 the vendor log shows **no BIOS or firmware package** applied and the step message says so. The BitLocker wait is skipped. As soon as pass 1 is finished (the progress screen shows pass 1 as `[OK]` or skipped and Windows Update running, and no vendor tool process is left: `Get-Process dcu-cli, HPImageAssistant, tvsu, Tvsukernel -ErrorAction SilentlyContinue` prints nothing), **plug the charger back in** for the rest of the run.
- [ ] **Charger pulled mid-run** (a separate check, and the charger goes back in): pull it **only while the Windows Update loop is running**, and only after confirming in the vendor log (`Logs\`) that pass 1 applied **no** BIOS or firmware package, that no flash is running, and that no restart is pending (the progress screen shows no countdown; no vendor tool process is running, as in the check above). If pass 1 did install a BIOS or firmware package, skip this check on that laptop. Plug the charger back in within two minutes, and before the run reaches a restart. Expected: the run keeps going without a stall, and `setup.log` continues. Don't leave the laptop unplugged into vendor pass 2.
- [ ] If the drive was encrypted at the start: decryption finishes before any BIOS update, or BitLocker is suspended for one reboot as a backstop. Afterwards the drive is not encrypted.
- [ ] A forced reboot by a vendor tool in the middle of a step resumes the run, and the step is not repeated more than 3 times.
- [ ] The vendor tool's logs and reports are in `Logs\`.
- [ ] **Child processes get an empty stdin and piped output (triage 153).** Every program setup starts now has its stdin closed at once and its stdout/stderr read through pipes (the output stays off the screen). In `setup.log`, note any `Output pipes still open after the process ended` WARN for a vendor tool, an installer or a Windows Update round: it costs 5 s each time (a helper process it started kept the pipe), and a tool that misbehaves with piped output would show up here.
- [ ] On a laptop where the consumer app installed, the business updater is gone afterwards; where the consumer app was skipped or failed, the updater is still installed.
- [ ] The final screen is readable on the laptop's own display from across the room, and the colour matches the verdict.

Result sheet to fill per laptop:

| Brand / model | Vendor tool result and exit codes | Consumer app | Yellow items | Red items | Final colour |
|---|---|---|---|---|---|
| | | | | | |

### 3.2 Dell

- [ ] **Business model (Latitude, Precision):** Dell Command Update Universal installs through winget (with its .NET dependency). `dcu-cli /configure -autoSuspendBitLocker=enable` runs, then `/applyUpdates -silent -reboot=disable`. Record the exit code (0 done; 1 or 5 done with reboot; 500 nothing to do) and what was applied. Retry codes 3000 to 3005 start the Dell service and retry once after 30 s.
- [ ] **DCU on a consumer model (for example Inspiron or XPS):** exit code 3 or 7 ends as **Skipped (yellow)**, never Failed, and Windows Update still supplies the drivers.
- [ ] SupportAssist (Store ID `XPDCCXDN26VNBT`) installs without a Microsoft account (SPIKE#3). Then DCU is removed (Dell documents a conflict between the two).
- [ ] Brand name desktop (if one is available): the vendor passes run, no consumer app.

### 3.3 Lenovo

- [ ] Run on a **ThinkPad** and an **IdeaPad or Yoga** (SPIKE#4).
- [ ] System Update installs through winget; its `tvsu.exe` signature is checked.
- [ ] **WMI result fields.** After pass 1 run `Get-CimInstance -Namespace root\Lenovo -ClassName Lenovo_Updates | Format-List *` and keep the output. The result parsing in `Convert-LenovoUpdateRecords` is provisional (it matches `fail`, `reboot` and `restart` in a `Status` text, and a whole `Status` of `Installed`, `Success`, `Successful`, `Succeeded`, `Complete` or `Completed` as a success): record the real property names and values, whether stale records from pass 1 show up in pass 2, and whether the `Status` text is English on a Hebrew-display Windows. Until SPIKE#4 is folded in, records it does not recognize end the pass yellow with `Lenovo System Update result could not be verified; see Logs\lenovo-pass<N>` (final review I4): note whether that appeared.
- [ ] **`-packagetypes` acceptance.** On battery the tool runs with `-packagetypes 1,2` (apps and drivers only; this is seen in the battery run of 3.1). Does `tvsu /CM` accept it? If it rejects it, the Lenovo battery run fails visibly (red) instead of flashing. Also check which reboot types BIOS and firmware packages use on this model.
- [ ] **32-bit registry view.** `AdminCommandLine` is written to both `HKLM\SOFTWARE\Policies\Lenovo\System Update\UserSettings\General` and the `WOW6432Node` copy. With Process Monitor (filter `tvsu.exe`, operation `RegQueryValue`, path contains `AdminCommandLine`) record which one `tvsu` reads.
- [ ] A type 5 (BIOS) package forces a restart after Lenovo's own countdown. The run resumes afterwards and the step finishes. No type 4 (forced shutdown) package is installed.
- [ ] `AdminCommandLine` is gone from both views after every pass and again after Finalize.
- [ ] Lenovo Vantage (Store ID `9WZDNCRFJ4MV`) installs without a Microsoft account (SPIKE#3); System Update is removed afterwards.

### 3.4 HP

- [ ] **Business model (EliteBook, ProBook, ZBook):** HP Image Assistant installs through winget (or the scrape fallback), extracts with `/s /e /f`, and runs `Analyze /Action:Install`. Record the exit code (0, 256, 257 done; 3010 done with reboot; 3011 done with a warning; 3020 partial failure) and the report in `Logs\`.
- [ ] **Consumer model (Pavilion, ENVY, Victus, OMEN):** exit code 4096 ends as **Skipped (yellow)**, and Windows Update supplies the drivers.
- [ ] HP Support Assistant (winget) installs; HPIA is then removed.

### 3.5 ASUS

- [ ] No vendor tool: drivers come from Windows Update. The step plan has no vendor passes.
- [ ] MyASUS (Store ID `9N7R5S6B0ZZH`) installs **after** Windows Update, without a Microsoft account (SPIKE#3). It needs the "ASUS System Control Interface" driver that arrives through Windows Update, so check that MyASUS actually opens and sees the laptop.
- [ ] The PC name is `ASUS-<serial>`.

### 3.6 Consumer apps without a Microsoft account (SPIKE#3)

For each Store app above (SupportAssist, Vantage, MyASUS):

- [ ] Record the `winget install --source msstore` exit code with only a local account signed in. If it needs a Store sign-in, the step must end **Skipped (yellow)** with a clear reason, not Failed (red). If it ends red, the Store-app Skipped rule from [spikes.md](spikes.md) is still missing.

### 3.7 Driver passes on the screen (v2 spec 4.5)

Until the Spike 5 capture is folded in (build order A), a driver pass shows the tool's name, the elapsed time against the 60-minute limit and the tool's latest log line; there is no update list yet.

- [ ] **Dell.** NOW shows `Log: <last line of dcu-pass<N>.log>`. The format of `D:\Setup\Logs\dcu-pass1.log` (from the first test) is `[yyyy-MM-dd HH:mm:ss] : <text>`; the timestamp is cut for display. During installs the line reads `Log: Installing updates (n of N). Update Name: ...` and the `synchronized view ... in SSM` housekeeping lines are skipped. Long update names are cut at the window width.
- [ ] **HP.** Does HP Image Assistant write its live `*.log` directly into `Logs\HPIA-pass<N>`, or into a sub-folder (NOW would then show no line)? Does the newest `*.log` give a useful line? (On NTFS a folder's newest write time can be stale.)
- [ ] **Lenovo.** The names, encoding and format of the logs in `%ProgramData%\Lenovo\SystemUpdate\logs`, and whether the newest `*.log` is the live one. The folder keeps old sessions, so NOW can show the previous session's last line until `tvsu` writes a new one. Is the line useful?

### 3.8 The first-test fixes, on a laptop (v2 spec 9.2 and 9.3)

- [ ] **Driver updates that ask for input.** Windows Update installs the driver updates whose `InstallationBehavior.CanRequestUserInput` is true (all 9 on the Dell) under `ForceQuiet`, without a prompt, and afterwards Windows has nothing left to install by itself (no "restart pending" after the run).
- [ ] **A driver re-offered after it installed** is hidden after 2 rounds (R24c) and turns the verdict red. Watch for it on a Dell; it would be a false red.
- [ ] **The `DriverClass` of the Dell firmware updates.** `setup.log` has one `Windows Update driver found` line per driver update with its `driverClass`. Record the real value for the firmware updates: the code compares it with `Firmware`.
- [ ] **Firmware only on mains power.** Battery run (see 3.1): the firmware updates are left alone (not hidden, not counted as failures) and the Note `On battery: BIOS/firmware updates skipped` is shown. On AC they install.
- [ ] **Vendor-app `verify`.** The Dell, Lenovo and HP `consumerApp` entries have no `verify` yet, so the step is Done after winget (v1). Take the values from Ben's Start-menu check of the Dell and from the `-InventoryOnly` capture after setup (Spike 5), put them into `config.json` and then check both ways: with the app there, the message reads `<name> installed (found file ...)` or `(found service ...)` and an activity line says which check passed; with the app missing the step is Failed `<name> was not found after install` and the business updater stays.

### 3.9 Spike 5 capture script (v2 spec 7)

`tools\spikes\Spike-DriverListCapture.ps1` is list-only and meant for customer Dell and HP laptops (see [spikes.md](spikes.md)). Things only a real laptop shows:

- [ ] **Dell:** the exit codes of `dcu-cli /scan`, the quoting of `-outputLog`, and the fields of the report XML (`DCUApplicableUpdates.xml`: name, version, category).
- [ ] **HP:** HP Image Assistant's `/Action:List` (where the report is and what it holds). The self-extractor with `/s /e /f` blocks until it is done (otherwise the script says `HPImageAssistant.exe was not found`). Where HPIA writes its logs. The myHP package name in the inventory.
- [ ] **Left behind:** `%TEMP%\BenTechCapture` (one `HPIA-<stamp>` folder per run) stays on the laptop: delete it by hand.
- [ ] **Signatures (final review, Task 1 SECURITY).** The extracted `HPImageAssistant.exe` runs only when its signature is Valid and from HP Inc: `capture.json` shows `Tool.SignatureStatus` `Valid` and an `HP Inc` signer. Note the real signer subject. (A refused tool is a red `ERROR: HPImageAssistant.exe was not run: ...` and an entry in `Errors`.)
- [ ] **Dell with `-InstallTool` (final review M6).** winget is taken from the App Installer package folder (`C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_...\winget.exe`, shown in `capture.json` under `Tool.Install.CommandLine`), never through PATH. If the script says winget was not found although App Installer works, note it: the elevated window could neither list `WindowsApps` nor read the package with `Get-AppxPackage -AllUsers`.
- [ ] **After the setup run** on the same laptop: `-InventoryOnly` (services, Start-menu shortcuts, Store packages: the `verify` values), and `dcu-pass1.log` / `HPIA-pass1` from the stick's `BenTech-Logs\<PC name>\`.

---

## 4. When something fails

Fix it in the owning task's files with a regression test, run the full suite (`Failed: 0`), publish `yyyy.MM.dd.N+1`, and re-run the failed item on a rolled-back checkpoint. Anything that is only verified by mocks should be added to this file.

## 5. Known open items (deferred until VM data exists, ruling R32)

Not fixed on purpose; each needs what the VM runs above show. The items marked (v2) were found while building the progress-visibility release.

- **Signer matching is a substring** (`HP Inc` also matches `CN=HP Incubator Ltd`). Record the real signer subjects of every installer in `setup.log`, then anchor the match to the exact CN.
- **The resume task names the user, not the SID** (`<old name>\<user>`). Section 1.4's rename check decides whether it must move to the SID.
- **State times are local, not UTC.** If OOBE left a non-Israel time zone, "Total time" and the step times can be off by the zone difference (the Region step changes the zone mid-run). Note any odd duration.
- **The default-browser check may run before Explorer applied the policy** right after the final sign-in (a false "Chrome is not the default" note). v2 waits up to 120 s for it (section 1.10); note the `waitedSeconds` in `setup.log`, and whether the note still appears after the wait.
- **A refused policy-value removal only logs a WARN** (`Remove-RegistryValueIfPresent`, Finalize; v1 R35, unchanged in v2). If `DefaultAssociationsConfiguration` stays, Windows keeps resetting the default browser to Chrome at every sign-in, with no note on screen. Note any `Registry value could not be removed` line in `setup.log`.
- **Leftovers:** the empty `...\WindowsUpdate\AU` and Lenovo `UserSettings\General` policy keys, and `C:\Program Files\OfficeDeploymentTool`, stay after the run.
- **(v2) Esc after a corrupt `state.json`, or after a crash before the first save, deletes those logs.** The cleanup decides "an earlier run left something" from a readable `state.json` (`HadPrevious`), so Esc on the start screen of such a machine counts as a fresh machine and deletes `C:\BenTech` with the logs. Ben's call whether that matters.
- **(v2) `Back after restart N` can show a lagging number** after an unexpected restart (a power-off, a vendor tool's forced restart): the count is only raised by the controlled restart.
- **(v2) The Office background job's `StartedAt` and `DeadlineAt` are local time without an offset.** The end of daylight saving time (the last Sunday of October, 02:00 back to 01:00) lengthens a wait by up to an hour on a run that spans it. The start of daylight saving time (late March, 02:00 forward to 03:00) **shortens** the Office deadline by up to an hour, so a Microsoft 365 setup that is still running can be stopped early as timed out (Failed, no retry). The fix is to store `DeadlineAt` in UTC; until then, note any Office timeout on a run that spans the March change.
- **(v2) Hidden updates are un-hidden at the end of the run** (final review C1): Finalize starts a `-WuUnhide` child for the updates this run (or the previous one) hid, and one that stays hidden is red (`Windows update still hidden: ...`). Only mocks prove it so far: section 1.9 has the real-machine checks. A run that never reaches Finalize (a crash, a power cut) leaves its hidden updates to the next run, which un-hides them in its first Windows Update round as in v1 (while its `state.json` survived).
