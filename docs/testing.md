# Testing: VMs and real laptops

The Pester suite (`tools\Invoke-Tests.ps1`) mocks everything that touches the machine. It cannot prove Task Scheduler, `icacls`, the Windows Update COM API, vendor tools, the Store, winget, reboots, power settings or console colours. This checklist is for exactly those things: every item here was only unit-tested. Spec reference: [section 17](specs/2026-10-18-bentech-winsetup-design.md). Open research questions (SPIKE#1 to #4) are in [spikes.md](spikes.md).

How to use it: tick the boxes on a printed or copied file. Make one filled copy of section 1 per VM type, and one copy of section 3 per laptop. Keep each filled copy next to the machine's `Logs\` folder, copied out after the run.

## 0. Before you start

- [ ] A release is published and `dist\BenTechSetup.cmd` is current. Its SHA-256 equals the hash in `keys\launcher.sha256`.
- [ ] Each VM has a **checkpoint** taken right after OOBE: a local administrator account with **no password**, no Microsoft account, no domain, internet works. Roll back to it before every run.
- [ ] Copy `BenTechSetup.cmd` into the VM from a USB stick, mounted VHD or ISO, or the VM's file-copy integration. Don't download it in a browser (that adds the Mark-of-the-Web, which the real USB flow doesn't have).
- [ ] After each run, copy `C:\BenTech\Setup\Logs\` (and `state.json` if it exists) out of the machine. This is the evidence.
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

- [ ] Shows the machine, serial, `Windows 11 ... x64` (or Windows 10), `Power`, and `New name` (at most 15 characters).
- [ ] **(a)** On a VM: `Detected : VM` and the arrow is on **Desktop** (VM to Desktop). No vendor steps appear later.
- [ ] A VM shows no `ON BATTERY` line.
- [ ] The countdown goes 10 to 0 and starts by itself. `L`, `D`, `Z` and `O` change the mode, 7-Zip and Office (OFF, BUSINESS, HOME) and reset the countdown to 10. `Enter` starts at once.
- [ ] `Esc` cancels. Afterwards `Get-ScheduledTask BenTechSetup-Resume` finds nothing, there is no `state.json`, and `run.lock` is gone.
- [ ] Press Enter repeatedly while the launcher is still downloading: the start screen still counts down (stray keys are thrown away).
- [ ] Put more than 1 GB in Documents and run again: the yellow line `This doesn't look like a fresh install: press Enter to run anyway` appears and nothing starts by itself.
- [ ] Steps turned off on the start screen (7-Zip OFF, Office OFF) are absent from the progress screen and the report.

### 1.4 Resume, reboots and power

- [ ] **(b)** The run resumes by itself after **each** reboot (automatic sign-in because there is no password), with no click.
- [ ] **The reboot after the PC rename resumes too.** The resume task is registered for `<old name>\<user>`; check it survives the rename. Before the rename: `Get-ScheduledTask BenTechSetup-Resume | Select -Expand Principal`, and `... | Select -Expand Actions` shows `Execute` as the full `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` path (triage 180). After the restart: the setup window appears at logon, and `Get-ScheduledTaskInfo BenTechSetup-Resume` shows a fresh `LastRunTime`. If this fails, the machine sits at an empty desktop after the rename. Unit tests cannot show this, so it is the first thing to check.
- [ ] **(c)** After every logon the progress screen is in front: `[OK]` done steps, `[>>]` with a running timer, `[..]` pending, and the reboot count.
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
- [ ] **Office (ODT).** The ODT comes from winget (`C:\Program Files\OfficeDeploymentTool\setup.exe`, Microsoft signature checked), `/quiet /extract:` extracts to `Downloads\ODT`, and `setup.exe /configure` runs without any dialog. Exit codes 0, 3010 and 1641 are all Done (3010 and 1641 show `Office installed (restart pending)`). Word opens with Hebrew UI first, English also installed; Groove and Lync are absent. The report lists `Microsoft 365` with a version.
- [ ] **Chrome as default browser (SPIKE#1).** After the final sign-in, `https` resolves to `ChromeHTML`. Check `HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoiceLatest` (ProgId) or Settings, Default apps. If it did not work, the final screen must be YELLOW with the Chrome hint, and **B** must open the Chrome page in Default apps.
- [ ] 7-Zip installed via winget when it was ON.

### 1.6 Windows Update (real COM)

- [ ] Microsoft Update is registered on the first run, and the search finds updates on a fresh machine.
- [ ] Rounds run as search, download, install. `setup.log` shows one entry per round, each in a `-WuRound` child process, and a reboot between rounds when a restart is required.
- [ ] The loop ends when a search returns nothing. Note the number of rounds and the total time. The cap is 6 rounds (`caps.maxWuRounds`); a fresh machine that needs close to 6 is a sign to raise it.
- [ ] Optional updates (`BrowseOnly=1`) are skipped; updates that need user input are skipped and logged; Defender definitions don't keep the loop going.
- [ ] **Busy and reboot-pending codes.** A fresh install often has the Windows Update orchestrator busy. Look in `setup.log` for `0x80240016` or `0x8024A000` (the step waits 120 s and continues) and `0x80242014` (continues with a reboot). They must not hide good updates: those rounds don't raise the per-update failure counts.
- [ ] **Hiding a mandatory update.** Some updates cannot be hidden (`0x80248016`). If a failing update shows up, the round continues, and the verdict lists `Windows update hidden after repeated failures: ...` in red. To provoke it on purpose: disable the Windows Modules Installer service in the checkpoint before the run (not verified to give this exact error).
- [ ] **Enablement package (SPIKE#2).** From a Windows 11 **24H2** checkpoint, the 25H2 enablement package is offered, installed, and the build moves to 25H2 after one reboot. If it is offered only with `BrowseOnly=1`, Task 14 needs a third search (see [spikes.md](spikes.md)).
- [ ] No leftover update loop: the same KB is not installed round after round.

### 1.7 Final screen on a real console

- [ ] **(d)** The whole console turns the verdict colour: dark green, dark yellow or dark red. The banner matches (`SETUP COMPLETE`, `COMPLETE - CHECK NOTES`, `COMPLETED WITH ERRORS`).
- [ ] Check all three colours at least once across the VMs. For RED, make a step fail on purpose (for example a hosts-file entry blocking `dl.google.com` before the run): the Chrome step fails and the screen is red.
- [ ] The AnyDesk ID is in big digits, readable from 3 to 5 metres. Machine, new name, total time and reboot count are shown.
- [ ] Failures (`X`) and notes (`!`) are listed with one-line reasons, at most 4 failures and 3 notes, each list then `... and N more: see the report`.
- [ ] **Worst-case final screen in a 30-row window (triage 240).** Set the console to 30 rows (Properties > Layout > Window size, height 30; in Windows Terminal, a profile with `"rows": 30`), and provoke more than 4 failures and 3 notes with Chrome not the default (for example block `dl.google.com` and `download.anydesk.com` in `hosts` and turn 7-Zip and Office on with winget broken). The layout is exactly 30 lines: the top `=====` frame, the banner and the AnyDesk ID must all be visible without scrolling, and the report line is the last row.
- [ ] **B** opens Settings, Default apps for Google Chrome; **R** opens `Setup-Report.txt` in Notepad. Both keep the final screen up. Any other key closes it.
- [ ] A key pressed during the last step doesn't close the screen early.
- [ ] Colours are back to normal when the final screen closes (in a console that stays open). Try the Windows 11 default terminal (Windows Terminal) and, once, the classic console host.

### 1.8 Report and cleanup

- [ ] **(e)** `C:\BenTech\Setup\Logs\Setup-Report.txt` exists and is complete: tool version, result, started/finished (`dd/MM/yyyy HH:mm`), duration, machine and serial, PC name old to new, mode and detected type, Windows build and architecture, activation, BitLocker, Smart App Control (`Off`, `On`, `Evaluation` or `Unknown`; compare with Windows Security > App & browser control), AnyDesk ID, apps with versions, the Windows Update line, one line per step with its time, and the Failures and Notes sections. Its result matches the final screen. The file is plain ASCII.
- [ ] **(f)** After the run, none of these exist:
  - [ ] the resume task (`Get-ScheduledTask BenTechSetup-Resume` finds nothing)
  - [ ] `NoAutoRebootWithLoggedOnUsers` under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`
  - [ ] `C:\BenTech\Setup\Downloads\`
  - [ ] `DefaultAssociationsConfiguration` under `HKLM\SOFTWARE\Policies\Microsoft\Windows\System`, and `%ProgramData%\BenTech\DefaultAssociations.xml`
  - [ ] the Lenovo `AdminCommandLine` value (both registry views; Lenovo laptops only)
  - [ ] `C:\BenTech\Setup\setup.ps1`, `config.json` and `run.lock`
  - [ ] installers left in `%TEMP%`
- [ ] `Logs\` and `state.json` are still there. Vendor tool logs are in `Logs\`.
- [ ] **Read the logs the safe way (M9).** Open them with **R** on the final screen or from an elevated prompt (`notepad C:\BenTech\Setup\Logs\setup.log` in an administrator Terminal), never by browsing `C:\BenTech` in Explorer: Explorer's "Continue" button adds your account to the folder's permissions, and the next re-run then refuses the folder with exit code 5. (To see it happen once on a VM: browse there in Explorer, click Continue, run the launcher again: exit 5.)
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
- [ ] **(spec 8.8) Re-run on the same machine after GREEN.** The start screen shows `Previous run: dd/MM/yyyy HH:mm - GREEN`. The old state is archived as `Logs\state-<RunId>.json`, counters start at zero, and every step runs again but finishes quickly. Nothing is duplicated: one AnyDesk, one Chrome, the same PC name, the Hebrew keyboard added once.
- [ ] Re-run after a RED run: updates that were hidden are un-hidden and get one more try.
- [ ] **Re-run after an *unfinished* run keeps the real power settings (final review I2).** Before the first run note the originals: `powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE`, `... SUB_SLEEP HIBERNATEIDLE`, `... SUB_VIDEO VIDEOIDLE` and `... SUB_BUTTONS LIDACTION` (read only the hex AC/DC values). Start a run and stop it before Finalize (power the VM off during Windows Update, then remove the resume task with `Unregister-ScheduledTask BenTechSetup-Resume` so it cannot continue). Double-click the launcher again and let the new run finish. Expected: the start screen says `Previous run: ... - UNFINISHED`; afterwards, on battery (DC) the four values are the ones you noted (not 0), and on a laptop the lid action is back to what it was. If they are 0, the run must show the yellow note `Some power settings could not be restored`, never green.
- [ ] Re-run with a corrupt `state.json` (cut the file in half): it is archived as `Logs\state.corrupt-<time>.json` and a new run starts without a crash.
- [ ] Re-run on a machine that no longer looks fresh: no auto-start, Enter needed.
- [ ] Once a second release exists: a new release published **during** a run does not change that run (resumes use the pinned local copy; the report keeps the old version), and the next launcher run uses the newest one.
- [ ] Variants worth one run each: a Windows account with **Hebrew letters and a space** in its name (the resume task and child processes still start), and **Hebrew display language** (power settings, ACLs and Windows Update filtering still work).

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
- [ ] No endless update loop (for example KB5034441): a stuck update is hidden and reported in red, and the run still finishes.
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

- [ ] The start screen says `Detected : LAPTOP` and shows the right manufacturer, model and serial. Mode is LAPTOP; the name is `<BRAND>-<SERIAL>` (at most 15 characters).
- [ ] **(h) Close the lid** mid-run for a few minutes, **only while the Windows Update loop is running** (the progress screen shows Windows Update as the running step, no vendor tool is running, no restart countdown): the laptop does not sleep, `setup.log` keeps advancing, and after Finalize the original lid action is back. Open the lid again before the run reaches a restart.
- [ ] **Charger connected from the start:** BIOS and firmware updates are allowed in pass 1.
- [ ] **Battery run (a separate run, battery at 80% or more):** unplug the charger at the **start screen**, before anything has started, so the whole vendor pass runs on battery and no flash can be in progress. The yellow `ON BATTERY` line shows. In pass 1 the vendor log shows **no BIOS or firmware package** applied and the step message says so. The BitLocker wait is skipped. As soon as pass 1 is finished (the progress screen shows pass 1 as `[OK]` or skipped and Windows Update running, and no vendor tool process is left: `Get-Process dcu-cli, HPImageAssistant, tvsu, Tvsukernel -ErrorAction SilentlyContinue` prints nothing), **plug the charger back in** for the rest of the run.
- [ ] **Charger pulled mid-run** (a separate check, and the charger goes back in): pull it **only while the Windows Update loop is running**, and only after confirming in the vendor log (`Logs\`) that pass 1 applied **no** BIOS or firmware package, that no flash is running, and that no restart is pending (the progress screen shows no countdown; no vendor tool process is running, as in the check above). If pass 1 did install a BIOS or firmware package, skip this check on that laptop. Plug the charger back in within two minutes, and before the run reaches a restart. Expected: the run keeps going without a stall, and `setup.log` continues. Don't leave the laptop unplugged into vendor pass 2.
- [ ] If the drive was encrypted at the start: decryption finishes before any BIOS update, or BitLocker is suspended for one reboot as a backstop. Afterwards the drive is not encrypted.
- [ ] A forced reboot by a vendor tool in the middle of a step resumes the run, and the step is not repeated more than 3 times.
- [ ] The vendor tool's logs and reports are in `Logs\`.
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

---

## 4. When something fails

Fix it in the owning task's files with a regression test, run the full suite (`Failed: 0`), publish `yyyy.MM.dd.N+1`, and re-run the failed item on a rolled-back checkpoint. Anything that is only verified by mocks should be added to this file.

## 5. Known open items (deferred until VM data exists, ruling R32)

Not fixed in v1 on purpose; each needs what the VM runs above show:

- **Signer matching is a substring** (`HP Inc` also matches `CN=HP Incubator Ltd`). Record the real signer subjects of every installer in `setup.log`, then anchor the match to the exact CN.
- **The resume task names the user, not the SID** (`<old name>\<user>`). Section 1.4's rename check decides whether it must move to the SID.
- **State times are local, not UTC.** If OOBE left a non-Israel time zone, "Total time" and the step times can be off by the zone difference (the Region step changes the zone mid-run). Note any odd duration.
- **The default-browser check may run before Explorer applied the policy** right after the final sign-in (a false "Chrome is not the default" note). Note whether it happens.
- **Leftovers:** the empty `...\WindowsUpdate\AU` and Lenovo `UserSettings\General` policy keys, and `C:\Program Files\OfficeDeploymentTool`, stay after the run.
