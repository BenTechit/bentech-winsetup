# bentech-winsetup

Zero-touch Windows post-install setup by BENTECH IT. Ben double-clicks one launcher file on a freshly installed PC, accepts the UAC prompt and walks away. The tool survives any number of reboots, installs the standard apps, runs the vendor driver tool and Windows Update until nothing is left, and finishes on a full-screen green, yellow or red result with the AnyDesk ID in big digits. While it works, one glance at the screen says what it is doing right now, that it is alive and what it has already done. When Ben presses Enter on the final screen it saves its logs to the USB stick and deletes its own folder, so nothing is left on the customer's PC.

The launcher (`BenTechSetup.cmd`) is tiny and rarely changes. It downloads the newest signed `setup.ps1` and `config.json` from this repo's latest GitHub Release, verifies the signatures against the public key built into the launcher, and only then runs them. Updating the tool means publishing a release, never re-copying a file to the USB stick (usually; see [Publishing](#publishing-a-new-version)).

Design: [docs/specs/2026-10-18-bentech-winsetup-design.md](docs/specs/2026-10-18-bentech-winsetup-design.md) (the spec is binding) and, for the progress screens, Microsoft 365 in the background and the "no leftover folder" cleanup, [docs/specs/2026-10-20-progress-visibility-design.md](docs/specs/2026-10-20-progress-visibility-design.md) (it amends the first). Plans: [docs/superpowers/plans/2026-10-18-bentech-winsetup.md](docs/superpowers/plans/2026-10-18-bentech-winsetup.md) and [docs/superpowers/plans/2026-10-20-progress-visibility.md](docs/superpowers/plans/2026-10-20-progress-visibility.md). Test checklist: [docs/testing.md](docs/testing.md). Open research questions: [docs/spikes.md](docs/spikes.md).

## What it does

In this order (steps that don't apply to the machine are left out):

1. **Prepare**: locks down `C:\BenTech` (admin only), registers the `BenTechSetup-Resume` logon task, stops sleep and lid-close sleep for the run, turns Fast Startup off, silences first-logon nag screens, stops Windows rebooting by itself.
2. **Turn off BitLocker / device encryption** and prevent it coming back.
3. **Time zone + Hebrew keyboard**: Israel Standard Time, Hebrew added next to English.
4. **Desktop icons**: This PC and the user folder.
5. **Remove bloatware**: a conservative list from `config.json`.
6. **Rename the PC** to `<BRAND>-<SERIAL>` (max 15 characters).
7. **winget** ready (installs App Installer if missing).
8. **Google Chrome** and **AnyDesk** (always; no unattended password, the customer accepts every connection).
9. **7-Zip**, optional.
10. **Chrome as default browser** (best effort). After the final restart Windows may take a while to apply it, so the end of the run waits up to 2 minutes for it before checking.
11. **Vendor drivers + BIOS, pass 1** for Dell, Lenovo and HP (laptops and brand-name desktops).
12. **Microsoft 365** (Hebrew + English), optional. It **starts here and installs in the background** while Windows Update round 1 runs. Only **Word, Excel, PowerPoint, Outlook (classic) and OneNote** are installed. A restart waits for it, for at most 60 minutes.
13. **Windows Update** in rounds, **one update at a time**, with reboots, until the search comes back empty (capped). Driver updates are installed even when they ask for input; firmware updates only on mains power.
14. **Microsoft 365, finish**: collects the result of the background install (this step has no line of its own on the screen) and puts **Word, Excel, PowerPoint and Outlook shortcuts on the desktop of all users**, also when Office was already installed.
15. **Vendor drivers + BIOS, pass 2**, for what only became applicable after Windows Update.
16. **Vendor consumer app** on laptops (SupportAssist, Vantage, HP Support Assistant, MyASUS, ...). When `config.json` says how to recognise the app (`verify`, see [Changing apps and lists](#changing-apps-and-lists)), the step checks that the app is really there after winget reports success, and fails if it is not. Then the business updater is removed if the consumer app installed.
17. **Finalize**: final power settings, an attempt to activate Windows when it has a product key but is not activated, the final restart, cleanup, `Setup-Report.txt`, the final screen.

## Daily use

1. **Put the launcher on a USB stick formatted exFAT or FAT32**: copy `dist\BenTechSetup.cmd` to the stick (see [Publishing](#publishing-a-new-version) for when to re-copy it). exFAT/FAT32 files carry no Mark-of-the-Web, so there is no SmartScreen warning. Spaces, Hebrew letters and apostrophes in the launcher's path are fine. **Leave the stick in the PC:** at the end the logs are saved to it (see step 5). The v2 release does not change the launcher, so a stick that holds the current one stays valid.
2. **On the fresh PC**: finish OOBE with a local account (no password), connect to the internet, double-click `BenTechSetup.cmd`, click **Yes** on the UAC prompt.
3. **The start screen** gives you 30 seconds to read it, then starts by itself:

   ```
    =============================================================================
      BENTECH WINDOWS SETUP                                         v2026.10.20.1
    =============================================================================
      Dell Latitude 5440    SN: ABC1234    ON CHARGER
      New PC name: DELL-ABC1234

      WHAT WILL HAPPEN                                  TO CHANGE IT, PRESS
      Type     LAPTOP (driver tool + laptop app)        L = laptop   D = desktop
      Chrome + AnyDesk   always
      7-Zip    YES                                      Z = yes / no
      Office   BUSINESS (Hebrew + English)              O = off / business / home

      Starts by itself in 30 s   ####################
      ENTER = start now           ESC = cancel, change nothing
    =============================================================================
   ```

   - **Top block:** the PC (make, model, serial number `SN`), whether it is on its charger or on battery, and the name it will get.
   - **WHAT WILL HAPPEN:** one line per choice, with the key that changes it on the right. The `Type` line says what the mode means: a laptop gets the vendor driver tool and the laptop app, a desktop does not; for a brand without a driver tool (ASUS, a VM) it says `no driver tool for this brand`. Chrome and AnyDesk always get installed.
   - **Colours:** on a black screen, the value of each choice is green (yes / on) or dark grey (`NO` / `OFF`); a yellow line is a warning.
   - **The countdown:** `Starts by itself in N s` and a bar that empties. **Every key you press restarts it at 30 s**, also a key that does nothing (Space, F5, ...), so the run starts by itself only when nobody touches the keyboard.

   | Key | Does |
   |---|---|
   | `L` / `D` | Laptop / Desktop mode (auto-detected; a VM defaults to Desktop) |
   | `Z` | 7-Zip on/off |
   | `O` | Office cycles OFF, BUSINESS, HOME |
   | `Enter` | Start now |
   | `Esc` | Cancel: no setup step runs, and any leftover resume task is removed. On a PC that no earlier run touched, the `C:\BenTech` folder the launcher made is deleted too, so nothing is left. If an earlier run was left unfinished, Esc deletes nothing: its logs stay for diagnosis |
   | any other key | Nothing changes, but the countdown goes back to 30 s |

   On battery a yellow line warns that BIOS updates are skipped unless you plug in. If the PC does not look like a fresh install (Windows older than 14 days, or more than 1 GB in Desktop/Documents/Downloads) there is no countdown and the screen says `This PC already has user files or is older than 14 days - press ENTER to run anyway`. A `Previous run: <date> - UNFINISHED` line appears only when an earlier run was left unfinished (a crash, or a run stopped half way). A run that was finished with Enter leaves nothing behind, so there is nothing to show.
4. **Walk away.** The progress screen (below) shows what is happening. The machine reboots by itself (a 15 s `Restarting in N s ...` countdown on screen), logs in by itself and carries on. If Microsoft 365 is still installing in the background, the restart waits for it (the screen says so). Nothing asks for input.
5. **Come back to the final screen.** The whole console is green, yellow or red. Press **Enter** to finish. Keys:

   | Key | Does |
   |---|---|
   | `Enter` | Finish: save the logs, clean up, close (see below) |
   | `B` | Open Default Apps for Chrome (the screen suggests it when Chrome is not the default) |
   | `R` | Open the report in Notepad |
   | any other key | Nothing: a stray key does not throw the logs away |

   **The USB-stick line** above the report line says whether the stick is there, and is checked again every second: `USB stick found (E:) - logs will be saved there`, or `No BenTech USB stick - plug it in now to keep the logs`. Plug the stick in while the screen is up. **With no stick, Enter deletes the logs without asking again.** To keep them anyway, copy `C:\BenTech\Setup\Logs` from an elevated prompt before you press Enter.

   **What Enter does**, in this order:
   1. **Saves the logs:** the whole `Logs` folder goes to `<stick>\BenTech-Logs\<PC name>\` (the new PC name). A folder of the same name from an earlier run is replaced. The stick is the drive the launcher was started from; if it is plugged in under another letter it is found by its serial number; otherwise it is any other removable or hard drive with `BenTechSetup.cmd` in its root (the only rule that works when you started the launcher from the Desktop). A stick whose `BenTech-Logs` folder is a link is refused and nothing is saved. If saving fails, the screen says why and waits for Enter before going on, so you can still save the logs by hand.
   2. **Deletes the Desktop launcher:** if you started `BenTechSetup.cmd` from the user's or the public Desktop, that copy is deleted. Only a `.cmd` file on a Desktop is ever deleted: a launcher on the stick, or anywhere else, is never touched.
   3. **Deletes `C:\BenTech`** (and `C:\ProgramData\BenTech` when it is empty), so **no folder is left**. If it cannot be deleted the screen says `delete it by hand` and waits for a key. On a PC whose Windows is not on drive C: the folder is kept (`Not deleting ...`).

   A **crash** is different: it leaves everything in place (the folder, the logs and the resume task) so you can see what went wrong. See [Setup crashed](#setup-crashed).

### Reading the progress screen

Everything the run is doing is on one screen, redrawn at least once a second. It enlarges the console window to about 100 x 45 when it can; Windows Terminal does not let a script resize it, and the screen then fits whatever size it has (when space runs out, JUST HAPPENED gets shorter first, then the list under NOW).

```
  BENTECH WINDOWS SETUP - working, do not turn off   /   Total 01:12:40   Restarts 2
  ------------------------------------------------------------------------------------------------
  [OK] Prepare                    [OK] winget                     [>>] Microsoft 365 (bg) 14:40
  [OK] BitLocker off              [OK] Chrome                     [>>] Windows Update
  [OK] Time zone + keyboard       [OK] AnyDesk                    [..] Drivers (pass 2)
  [OK] Desktop icons              [OK] 7-Zip                      [..] Laptop app
  [OK] Remove bloatware           [OK] Default browser            [..] Remove updater
  [--] Rename PC                  [OK] Drivers (pass 1)           [..] Finish
  ------------------------------------------------------------------------------------------------
  NOW  Windows Update - round 2 (max 6)   /   14:10 (of max 90 min)
       Installing 3 of 7
       [OK] KB5044284 2024-10 Cumulative Update
       [OK] KB5043080 .NET Framework 3.5
       [>>] KB2267602 Defender Antivirus definitions
       [..] KB5046613 Servicing Stack
       ... 3 more
  ------------------------------------------------------------------------------------------------
  JUST HAPPENED
  13:05  Windows Update round 1: found 7, installed 6, failed 0
  12:58  Microsoft 365 started installing in the background (he-il, en-us)
  12:57  Drivers (pass 1) done - Dell Command Update finished
  12:30  Rename PC skipped - already named DELL-ABC1234
```

(The names, times and counts in this example are made up.)

- **Header:** the total time since the run started, how many times the PC restarted, and a **spinner** (`| / - \`) that turns on every redraw. The spinner and the timers moving is the sign of life: if they stand still for more than a couple of minutes, something is probably stuck, and `Logs\setup.log` shows the last thing it did. (A few short waits, such as starting the Dell service, can stand still for up to a minute.)
- **Checklist:** one line per step of this run, in order, in as many columns as fit. The whole screen is on a black background. Markers: `[OK]` done (green), `[>>]` running (cyan), `[X ]` failed (red), `[--]` skipped (dark grey), `[..]` still to do (plain). The reason of a failed or skipped step is not here; it is in JUST HAPPENED.
- **`(bg)` after Microsoft 365** means it is installing in the background, next to the step NOW shows, with its own timer. When the background installer has ended but the finishing step has not run yet it reads `(bg ended)`; after that the line shows the result.
- **NOW:** the step that is running, with what it is using (the tool, the Windows Update round), and its time. While the step waits for something that has a time limit, the time is shown against the limit: `14:10 (of max 90 min)` means 14 minutes 10 seconds so far and the wait ends at 90 minutes. Under it, what the step reports: for a **driver pass** the tool's own latest log line (`Log: ...`), for **Windows Update** the phase (`Installing 3 of 7`) and the list of updates with a marker each, while **Microsoft 365 holds up a restart** `Waiting for Microsoft 365 to finish before restarting`. With nothing to report it shows the newest JUST HAPPENED line.
- **JUST HAPPENED:** the newest facts first, each with its time: versions installed, the AnyDesk ID, the new PC name, each bloatware app removed, each Windows Update round and driver pass summarised, why a step failed or was skipped, and `Restarting (restart N)` / `Back after restart N`. It survives restarts; a new run starts it empty.

### What the colours mean

The final screen is white text on dark green (GREEN), **black text on yellow** (YELLOW) or white text on dark red (RED).

| Colour | Banner | Meaning |
|---|---|---|
| GREEN | `SETUP COMPLETE` | Every step done, no notes. |
| YELLOW | `COMPLETE - CHECK NOTES` | No failures, but something needs a look: a step skipped (unsupported model, Store sign-in needed, ARM64), Chrome is not the default, Windows not activated (or its status could not be read), BitLocker still decrypting, Windows 10 (no security updates), a Lenovo result that could not be verified, BIOS or firmware updates left alone because the PC was on battery, the Office desktop shortcuts or the power settings or the resume task that could not be put back. |
| RED | `COMPLETED WITH ERRORS` | A step failed or never finished, a Windows update was hidden after repeated failures, a cap was hit (reboots or update rounds), the drive is still encrypted, or a restart was refused. |

The final screen lists at most 3 failures and 2 notes, each with a one-line reason, then `... and N more: see the report`. The report lists them all.

### Where things are

**During a run, and after a crash** (`C:\BenTech\Setup`):

| What | Where |
|---|---|
| Report | `C:\BenTech\Setup\Logs\Setup-Report.txt` (also lists the Windows updates installed, per round) |
| Our log | `C:\BenTech\Setup\Logs\setup.log` |
| The JUST HAPPENED feed | `C:\BenTech\Setup\Logs\activity.txt` (an earlier run's: `activity-<RunId>.txt`). The AnyDesk ID is here and in the report, never in `setup.log` |
| Windows Update rounds | `C:\BenTech\Setup\Logs\wu-round<N>.json` (the round's result) and `wu-round<N>.progress.json` (the live list the screen reads) |
| Console transcripts | `C:\BenTech\Setup\Logs\transcript-<time>.txt` |
| Vendor tool logs and reports | `C:\BenTech\Setup\Logs\` (for example `dcu-pass1.log`, `HPIA-pass1\`) |
| Run state | `C:\BenTech\Setup\state.json` (older runs: `Logs\state-<RunId>.json`) |

`Downloads\`, the pinned `setup.ps1` and `config.json` are deleted when Finalize ends. `Logs\` and `state.json` stay until you press Enter on the final screen.

**After a finished run** nothing is left on the PC: Enter on the final screen copied the whole `Logs\` folder to the USB stick, to `<stick>\BenTech-Logs\<PC name>\`, and deleted `C:\BenTech`. Read the report and the logs there. (With no stick, they are gone: see step 5 of [Daily use](#daily-use).)

**While `C:\BenTech` exists, open the logs with R on the final screen or from an elevated prompt** (for example `notepad C:\BenTech\Setup\Logs\setup.log` in an administrator Terminal). Never browse to `C:\BenTech` in Explorer: its "You don't currently have permission... Continue" button adds your own account to the folder's permissions, and the next run then refuses the folder with exit code 5 (it is no longer admin-only), so you would have to delete it, logs included.

## Troubleshooting

### Launcher exit codes

The launcher window stays open for 15 seconds after a failure. The exit code is also visible if you start it from a command prompt.

| Code | Message | What to do |
|---|---|---|
| 0 | (none) | Setup ran and ended normally. This includes Esc on the start screen and a restart in progress. The colour of the final screen is the result, not the exit code. |
| 1 | `Setup could not start: ...` | Unexpected launcher error. Read the message. If the console shows `Setup crashed`, see below. |
| 2 | `Setup is already running on this machine` | A run (or its resume after a reboot) holds the lock. Look for the setup window on the taskbar and don't double-click twice. If no window exists, restart Windows and try again: a lock left by a dead run is detected and ignored. |
| 3 | `SECURITY CHECK FAILED - files are not signed by BenTech` | A downloaded file does not match its signature. Nothing was written or run. Try once more (a captive portal or proxy can corrupt a download). Check the stick holds the current launcher: `Get-FileHash <stick>\BenTechSetup.cmd -Algorithm SHA256` must equal the hash in `keys\launcher.sha256` (ignore upper/lower case). A launcher built for an old signing key fails against releases signed with a new one. If it still fails, treat it as a possible tampering incident: check the GitHub account and the release files before doing anything else. Never bypass it. |
| 4 | `Cannot reach GitHub - giving up` | The launcher retried 20 times, 30 s apart (about 10 minutes). Check the PC's internet and DNS, that `https://github.com/BenTechit/bentech-winsetup/releases` opens in a browser, and that the latest release has all four files (a missing file counts as unreachable). |
| 5 | `C:\BenTech already exists and is not admin-only. Delete it (as administrator) and run again.` or `Cannot secure C:\BenTech` | Someone or something created `C:\BenTech` before the launcher did, or its permissions are wrong, or it is a junction. The launcher never repairs an existing folder, because the resumed task runs code from it. Look inside first (copy out any logs you want), then delete it from an elevated prompt (`rd /s /q C:\BenTech`; if it is a junction or symlink, `rmdir C:\BenTech` removes only the link) and run again. |

### Setup crashed

A red screen reads `Setup crashed: <message> - see C:\BenTech\Setup\Logs`. Press a key to close it. A crash leaves everything in place for diagnosis: `C:\BenTech`, its logs and the resume task. Nothing is saved to the stick and nothing is deleted. The resume task stays registered, so after a crash outside a step the next logon shows the same crash again until it is fixed.

1. Read the tail of `Logs\setup.log` and the newest `Logs\transcript-*.txt`. The log has the stack trace.
2. Fix it in the repo and publish a new release, or re-run if it looks transient.
3. **Re-run:** double-click the launcher again. It downloads the newest release, archives the old state to `Logs\state-<RunId>.json` and the old activity feed to `Logs\activity-<RunId>.txt`, resets the counters, and runs every step again. Steps that were already done finish in seconds. The start screen shows `Previous run: <date> - UNFINISHED`.
4. To stop the retries without running again: double-click the launcher and press **Esc**. That removes the leftover resume task and runs no step. Because the crashed run left its state, Esc deletes nothing: the launcher's fresh `setup.ps1`, `config.json` and the `Logs\` folder stay in `C:\BenTech\Setup`. Copy the logs out (from an elevated prompt) before you delete the folder by hand.

An unreadable `state.json` (power cut mid-write) is archived as `Logs\state.corrupt-<time>.json` and a new run starts by itself. (Known gap: Esc on the start screen then counts as a fresh PC and deletes `C:\BenTech` with those logs, so copy out what you need first.)

## Publishing a new version

Pushing to `main` does not reach any customer. Only a published GitHub Release does.

1. Commit and **push** first. `Publish.ps1` refuses a dirty working tree or a HEAD that is not pushed, because the release tag must point at the code that was built. (`-DryRun` only warns.)
2. Run:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.19.1 -Notes "What changed"
   ```

   The version is `yyyy.MM.dd.N`; `N` counts releases on that day. Add `-DryRun` to do everything except the upload (it still builds and signs `dist\` locally and prints the `gh` command).
3. It stops at the first failure and runs: clean/pushed check, the full test suite, bundle, sign `setup.ps1` and `config.json` with your private key, verify both signatures against `keys\public-key.xml`, build the launcher, then `gh release create v<Version> --target <HEAD>` with exactly four files: `setup.ps1`, `setup.ps1.sig`, `config.json`, `config.json.sig`.
4. **Check the launcher hash it prints.** The launcher is the trust anchor (it holds the public key), so it is never uploaded to GitHub. Publish prints `Launcher SHA-256: ...` and records it in `keys\launcher.sha256`.
   - **Hash unchanged:** the USB sticks are still current.
   - **Hash changed** (a `WARNING: the launcher changed` line): copy the new `dist\BenTechSetup.cmd` to every USB stick. The launcher only changes when the public key, the repo URL or `launcher\BenTechSetup.template.cmd` changes. A normal release (code or config) does not change it.
   - Commit and push the updated `keys\launcher.sha256`; the next real publish needs a clean tree.
5. Don't publish while a PC is downloading: the launcher fetches the four files one by one from `/releases/latest/`, so a publish in between could hand it files from two versions.

**The very first publish** needs the GitHub repo `BenTechit/bentech-winsetup` to exist (public: it holds only the public key and no secrets), the branch pushed with an upstream, and `gh auth status` logged in. Creating the repo, pushing and publishing are outward-facing: **run these only after Ben's go-ahead**, from the repo root, with the work merged into `main` and the key backup done (see [Signing key](#signing-key)):

```
gh auth status
git status                     # clean, on main
gh repo create BenTechit/bentech-winsetup --public --source . --push
git branch -vv                 # main now tracks origin/main
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.19.1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.19.1 -Notes "First release"
```

Then commit and push the updated `keys\launcher.sha256` if Publish changed it, and copy `dist\BenTechSetup.cmd` to the USB sticks.

**Rebuilding the launcher on a fresh clone** (a new PC, or to check a stick): restore the signing key first ("Restore" below), then run `tools\Publish.ps1 -Version <any> -DryRun`. It builds `dist\BenTechSetup.cmd` from the template, the public key and the repo in `tools\publish.settings.json`, and prints `Launcher SHA-256: ...`. That hash must equal the one in the committed `keys\launcher.sha256`, and Publish says `WARNING: the launcher changed` when it does not. Because the dry run also records the new hash, run `git diff keys\launcher.sha256` afterwards: no change means the rebuilt launcher is byte-for-byte the one on the sticks; a change you did not expect means the template, the key or the repo setting differs, so find out why (and `git checkout keys\launcher.sha256`) before copying anything. To check a stick, compare `Get-FileHash <stick>\BenTechSetup.cmd -Algorithm SHA256` with the same file.

A run in progress keeps using the verified copy already on its disk; a new release never changes a machine mid-run.

### Rollback

Make the previous release the "latest" one (from the repo folder):

```
gh release edit v<old> --latest
```

The next launcher run downloads that release. Machines already running keep their pinned copy. Then fix forward with a new release (`N+1`).

## Signing key

- **Private key:** `%USERPROFILE%\.bentech-winsetup\signing-key.dpapi`. It is protected with DPAPI for the current Windows user, so only this user on this PC can read it. It is never in the repo (`*.dpapi` is ignored).
- **Public key:** `keys\public-key.xml`, committed, and built into every launcher.
- **The backup must be in the password manager before the first publish.** The DPAPI file is the only working copy and it dies with the PC or the Windows profile. A plain-text copy on disk is a leaked key, so the password manager is the only place the key may rest.

### Back up the existing key (do this once, before the first publish)

Run from the repo root. Nothing below needs the key to be printed on screen.

**Precondition: turn the cloud clipboard off first.** The key passes through the clipboard (Notepad copy, `Set-Clipboard`, the password manager). With Windows cloud clipboard on, that copy is sent to Microsoft's cloud, and `Set-Clipboard -Value $null` does not remove clipboard-history entries. Before you touch the key, open **Settings > System > Clipboard** and switch **Clipboard history** OFF and **Sync across your devices** OFF. You can switch them back on at the end if you want them. The same applies to restoring the key below.

1. **Get the XML into the password manager** (a secure note, named for example `bentech-winsetup signing key`):
   - If `%USERPROFILE%\Desktop\bentech-signing-key-BACKUP.xml` exists (`New-SigningKey` wrote it when the key was created), open it in Notepad, select all, copy, paste it into the password manager entry, and close Notepad.
   - If it does not exist, export the key from the DPAPI file straight to the clipboard. This uses `Read-PrivateKeyXml -Path` from `tools\Signing.ps1` and writes nothing to disk:

     ```
     . tools\Signing.ps1
     Read-PrivateKeyXml -Path "$env:USERPROFILE\.bentech-winsetup\signing-key.dpapi" | Set-Clipboard
     ```

     Paste into the password manager entry.
2. **Verify the stored copy.** Copy the entry's text back out of the password manager (to the clipboard), then check it is exactly the working key. It must print `True`:

   ```
   . tools\Signing.ps1
   (Read-PrivateKeyXml -Path "$env:USERPROFILE\.bentech-winsetup\signing-key.dpapi").Trim() -ceq (Get-Clipboard -Raw).Trim()
   ```
3. **Delete the plain-text file permanently:** select `bentech-signing-key-BACKUP.xml` and press **Shift+Delete** (not the Recycle Bin; if it already went there, empty the Recycle Bin). Clear the clipboard with `Set-Clipboard -Value $null`. Then open **Win+V**, click **Clear all**, and confirm the history is empty. (If clipboard history is off, Win+V only offers to turn it on: use **Settings > System > Clipboard > Clear clipboard data > Clear** instead.) Only now switch **Clipboard history** and **Sync across your devices** back on, if you want them.
4. **For any future `-BackupPath`**, use a folder that is not synced and not the Desktop, for example `$env:LOCALAPPDATA\bentech-key-backup\signing-key-BACKUP.xml` (never the Desktop, Documents or anything OneDrive covers). Move the XML into the password manager, verify it as in step 2, then delete the file permanently as in step 3.

If the plain-text file was ever in a synced folder (OneDrive, a cloud-backed Desktop), backed up (for example by File History), shared, committed or pasted into a chat, or if the key was on the clipboard while **Sync across your devices** or **Clipboard history** was on, treat the key as exposed and rotate it ("If the key is lost" below). Before the first release that costs only a new `keys\public-key.xml`.

### Restore and other key tasks

- **Restore on a new PC or profile** (same key, so no launcher change). **Only when no `signing-key.dpapi` exists there: `Save-PrivateKeyXml` overwrites whatever is at the path.** Turn **Clipboard history** and **Sync across your devices** OFF first (the precondition above), copy the entry's text out of the password manager to the clipboard, then:

  ```
  . tools\Signing.ps1
  $keyPath = "$env:USERPROFILE\.bentech-winsetup\signing-key.dpapi"
  if (Test-Path -LiteralPath $keyPath) { throw "A signing key already exists at $keyPath; not overwriting it." }
  $xml = Get-Clipboard -Raw
  if ($xml -notmatch '<RSAKeyValue>') { throw 'The clipboard does not hold a key (no <RSAKeyValue>); nothing was saved.' }
  Save-PrivateKeyXml -Path $keyPath -PrivateKeyXml $xml
  Set-Clipboard -Value $null
  ```

  Then clear the clipboard history as in step 3 of the backup procedure. A `Publish.ps1 -DryRun` then proves the restored key matches `keys\public-key.xml` (it verifies both signatures).
- **If the key is lost or exposed:** a lost key cannot sign new releases for the existing launchers, and an exposed one must stop being trusted. Run `tools\New-SigningKey.ps1 -BackupPath <non-synced folder, see step 4 above>` again (it refuses to overwrite, so move any old `signing-key.dpapi` away and delete `keys\public-key.xml` yourself first), commit the new public key, publish a release, and copy the **new launcher to every USB stick**. Old launchers will refuse every new release with exit 3; that is the design. After an exposure, also delete the old launcher from every stick: it still trusts the old key.

## Changing apps and lists

Everything Ben may want to change without touching code is in `config\config.json`: the 7-Zip and Office defaults, the Chrome and AnyDesk download URLs, winget IDs, the Office products and languages, the vendor tool matrix and consumer app IDs, expected Authenticode signers, the bloatware remove/protect lists, caps and timeouts.

Edit it, run the tests (they check that the remove and protect lists don't overlap, that every signer reference exists and that every `verify` entry is well formed), commit, push, publish. No launcher update is needed. Keep it UTF-8 and valid JSON.

Settings worth knowing:

- **`windowsUpdate.installMode`**: `"OneAtATime"` (the default) downloads and installs each Windows update on its own, so the screen shows `Installing 3 of 7`; `"Batch"` is the v1 way, all updates in one go, and the screen then shows only the phase and the list. Switch to `"Batch"` if one at a time turns out too slow on a machine. The round limit (`timeoutsMinutes.wuRound`, 90 minutes) and the round cap (`caps.maxWuRounds`) apply to both.
- **`apps.office.excludeApps`**: the Office apps left out of the install. The default leaves exactly Word, Excel, PowerPoint, Outlook (classic) and OneNote. An id the Office Deployment Tool rejects must be removed from the list. `timeoutsMinutes.office` (60) is how long a background install and a restart waiting for it may take.
- **`vendors.<BRAND>.consumerApp.verify`** (optional): how the vendor-app step recognises the app after winget reports success.

  ```
  "consumerApp": { "source": "msstore", "id": "...", "name": "...",
                   "verify": { "paths": ["%ProgramFiles%\\Vendor\\App\\app.exe"], "services": ["VendorAppService"] } }
  ```

  (The values above are only an example of the shape.) `paths` and `services` are both optional, but at least one must list something. `%VARIABLES%` and wildcards in a path are fine. The paths are tried first, then the services; the first hit counts. Found: the step is Done and an activity line says which check passed. Not found: the step is Failed with `<app> was not found after install`, and the business updater stays. **Leave `verify` out and the step is Done as soon as winget reports success** (the v1 behaviour; no brand has a `verify` entry yet). The real values come from Ben's check of the Start menu and from the `-InventoryOnly` run of Spike 5 after a setup run.

## Open spikes

Five small research scripts in `tools\spikes\` answer open questions that need real machines. Until they are run, the code uses the plan's defaults. Details, commands and what to send back: [docs/spikes.md](docs/spikes.md).

| # | Question |
|---|---|
| 1 | Does the `DefaultAssociationsConfiguration` policy make Chrome the default on a workgroup Win 11 Pro, Home and Win 10 Pro? (Otherwise the yellow B fallback is the only way.) |
| 2 | Does Windows Update offer the 25H2/26H2 enablement package, and with which `BrowseOnly` value? |
| 3 | Can `winget install --source msstore` install SupportAssist, Vantage and MyASUS with no Microsoft account? |
| 4 | Does Lenovo System Update cover IdeaPad/Yoga, what does it report back, how does `tvsu` take its parameters, and (v2) does a LIST run through `AdminCommandLine` leave the install records alone? |

Spike 5 is different: `tools\spikes\Spike-DriverListCapture.ps1` is **list-only and made for customer Dell and HP laptops** that come in for setup. Run it from the USB stick on one Dell and one HP laptop before the setup tool, and again with `-InventoryOnly` after it, and send back the whole `capture-...` folder (plus `dcu-pass1.log` or `HPIA-pass1\` from the stick's `BenTech-Logs\<PC name>` folder). It decides how the Dell and HP driver lists will be read (v2), and its `-InventoryOnly` run after setup supplies the `verify` values for the vendor-app check. It never applies an update, writes the registry or restarts the PC. **Spike 5 is waiting for a Dell and an HP laptop.** Details: [Spike 5 in docs/spikes.md](docs/spikes.md).

## Development

**Tests** (Pester 5.5+ is needed on the dev PC only):

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests
```

Pass means the last line reads `Failed: 0`. Pass a single file to `-Path` to run one suite. `Publish.ps1` runs the whole suite itself.

**Rules** (the full list is in [CLAUDE.md](CLAUDE.md)):

- Windows PowerShell **5.1 only**, no modules or dependencies on target machines.
- Every `.ps1` is **UTF-8 with BOM** (PowerShell 5.1 reads BOM-less files as ANSI). `tests\Encoding.Tests.ps1` enforces it. `.gitattributes` marks `*.ps1`, `*.json`, `*.cmd` and `*.xml` as `-text` so Git never rewrites line endings. The launcher is ASCII-only with CRLF.
- **Never parse localized output.** Machines may run Hebrew Windows: use exit codes, CIM, registry values, GUIDs and SIDs.
- Downloads use `System.Net.WebClient` with TLS 1.2, never `Invoke-WebRequest`.
- Never run setup steps or the launcher on the dev PC. Tests mock everything.

**Build the bundle by hand:**

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Bundle.ps1 -Version 2026.10.19.1
```

This writes `dist\setup.ps1` and `dist\config.json`. Sign with `tools\Sign-File.ps1 -Path dist\setup.ps1`, build the launcher with `tools\Build-Launcher.ps1 -BaseUrl <releases/latest/download URL>`. A new file under `src\` must also be added to `$BundleOrder` in `tools\Build-Bundle.ps1`; the build fails when the two disagree.

**Layout:**

| Path | Holds |
|---|---|
| `src\` | The code: Common, State, Detect, Engine, Steps, Report, UI, Entry |
| `tests\` | Pester tests and fixtures |
| `config\config.json` | All data: URLs, IDs, signers, lists, caps, timeouts |
| `launcher\` | The launcher template (polyglot cmd + PowerShell) |
| `tools\` | Bundle, launcher, signing and publish tooling; `spikes\` has the research scripts |
| `keys\` | `public-key.xml` and `launcher.sha256` |
| `docs\` | Spec, plan, spikes, testing checklist |
| `dist\` | Build output (ignored by Git) |
