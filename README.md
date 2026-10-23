# bentech-winsetup

Zero-touch Windows post-install setup by BENTECH IT. Ben double-clicks one launcher file on a freshly installed PC, accepts the UAC prompt, plans the PC in the BenTech Toolbox window (a profile, a few switches) and presses Start, then walks away. The tool survives any number of reboots, installs the standard apps, runs the vendor driver tool and Windows Update until nothing is left, and finishes on a full-screen green, yellow or red result with the AnyDesk ID in big digits when AnyDesk was chosen. While it works, one glance at the screen says what it is doing right now, that it is alive and what it has already done. When Ben presses Enter on the final screen it saves its logs to the USB stick and deletes its own folder, so nothing of setup's own is left in `C:\BenTech` on the customer's PC (the known leftovers are listed in [docs/testing.md](docs/testing.md) section 5: `C:\Program Files\OfficeDeploymentTool`, only after Microsoft 365, and a few empty policy keys).

The launcher (`BenTechSetup.cmd`) is tiny and rarely changes. It downloads the newest signed `setup.ps1` and `config.json` from this repo's latest GitHub Release, verifies the signatures against the public key built into the launcher, and only then runs them. Updating the tool means publishing a release, never re-copying a file to the USB stick (usually; see [Publishing](#publishing-a-new-version)).

Design: [docs/specs/2026-10-18-bentech-winsetup-design.md](docs/specs/2026-10-18-bentech-winsetup-design.md) (the spec is binding) and, for the progress screens, Microsoft 365 in the background and the "no leftover folder" cleanup, [docs/specs/2026-10-20-progress-visibility-design.md](docs/specs/2026-10-20-progress-visibility-design.md) (it amends the first) and, for the free Craft office suite that is now the default, [docs/specs/2026-10-20-craft-apps-design.md](docs/specs/2026-10-20-craft-apps-design.md) (it amends both) and, for ScreenConnect as a remote-access choice next to AnyDesk, [docs/specs/2026-10-20-screenconnect-design.md](docs/specs/2026-10-20-screenconnect-design.md) (it amends all three) and, for the BenTech Toolbox, the window that opens first (profiles, options, curated system tweaks, a closing restore point, English or Hebrew), [docs/specs/2026-10-21-toolbox-design.md](docs/specs/2026-10-21-toolbox-design.md) (it amends all four) with its [tweak fact cards](docs/specs/2026-10-21-toolbox-tweak-factcards.md). Plans: [docs/superpowers/plans/2026-10-18-bentech-winsetup.md](docs/superpowers/plans/2026-10-18-bentech-winsetup.md), [docs/superpowers/plans/2026-10-20-progress-visibility.md](docs/superpowers/plans/2026-10-20-progress-visibility.md), [docs/superpowers/plans/2026-10-20-craft-apps.md](docs/superpowers/plans/2026-10-20-craft-apps.md), [docs/superpowers/plans/2026-10-20-screenconnect.md](docs/superpowers/plans/2026-10-20-screenconnect.md) and [docs/superpowers/plans/2026-10-21-toolbox.md](docs/superpowers/plans/2026-10-21-toolbox.md). Test checklist: [docs/testing.md](docs/testing.md). Open research questions: [docs/spikes.md](docs/spikes.md).

## What it does

The **BenTech Toolbox** window opens first: you pick a profile, adjust the options and the tweaks (English or Hebrew) and press Start; the console screens then run as before. The window is described in [Daily use](#daily-use), the tweaks in [System tweaks](#system-tweaks) and the restore point in [The restore point](#the-restore-point).

In this order (steps that don't apply to the machine are left out):

1. **Prepare**: locks down `C:\BenTech` (admin only), registers the `BenTechSetup-Resume` logon task, stops sleep and lid-close sleep for the run, turns Fast Startup off, silences first-logon nag screens, stops Windows rebooting by itself.
2. **Turn off BitLocker / device encryption** and prevent it coming back.
3. **Time zone + Hebrew keyboard**: Israel Standard Time, Hebrew added next to English.
4. **Desktop icons**: This PC and the user folder.
5. **System tweaks** (the `tweaks` step): the curated registry tweaks the toolbox has switched on, from nine to choose from (see [System tweaks](#system-tweaks)). It lands before the first restart, so Explorer picks the values up at the next sign-in. A tweak Windows refuses is a yellow note, never red. Left out when no tweak is chosen.
6. **Remove bloatware**: a conservative list from `config.json`.
7. **Rename the PC** to `<BRAND>-<SERIAL>` (max 15 characters).
8. **winget** ready (installs App Installer if missing).
9. **Google Chrome** (always), then the **remote tool** chosen in the toolbox (**R** on the console start screen): **AnyDesk** (the default; no unattended password, the customer accepts every connection), **ScreenConnect**, or both.
    - ScreenConnect is **unattended on purpose**: it connects without the customer clicking Accept, so get the customer's OK at the counter (for example on the repair form). It enrols the PC in Ben's ScreenConnect list (name, IP, user name). That is the one exception to "the tool collects nothing off-machine" (v1 spec, section 5).
    - The installer is Ben's own `ScreenConnect.ClientSetup.exe`, taken from the run's own release. It runs only after its SHA-256 matches the one in the signed `config.json` and it carries a `ConnectWise, LLC` signature. The step then waits for the `ScreenConnect Client (b58e7c32699a96bf)` service. How Ben builds a new installer: [A new ScreenConnect installer](#a-new-screenconnect-installer).
10. **7-Zip**, optional, then **Zoom**, optional and off unless switched on in the toolbox's APPS row ([zoom spec](docs/specs/2026-10-22-zoom-app-design.md)).
    - Zoom installs per machine through winget (`Zoom.Zoom`, the MSI from zoom.us, hash-checked by winget), as 7-Zip does, with **auto-update on**: the token in `apps.zoom.custom` of the signed `config.json` (`ZConfig=AU2_EnableAutoUpdate=true`) reaches the MSI through winget's `--custom` argument ([Changing apps and lists](#changing-apps-and-lists)). Updates then install quietly when Zoom restarts, never during a meeting.
    - **It may take at most 10 minutes** (`timeoutsMinutes.zoom`), so a wrong token that leaves msiexec waiting on its help box (a Windows Installer window listing msiexec's options) costs 10 minutes, not the 30 of `timeoutsMinutes.default`; the step is then red, `Zoom install timed out`. Clicking that window away ends the step at once, red with a winget code (`Zoom.Zoom: winget 0x8A15....`); it means the same. `setup.log` keeps the last lines winget printed (`winget install timed out` / `winget install failed`).
    - JUST HAPPENED gets `Zoom <version> installed` (just `Zoom installed` when the version cannot be read). A Zoom already on the PC (ruling Z-R3): an older per-machine one is upgraded, with the token, so auto-update is set, and the step reads like a fresh install; an up-to-date one, or one the customer installed per user, is left as it is (winget answers `0x8A15002B`, no applicable update, or `0x8A150061`): the step is done with the yellow note `Zoom was already installed: auto-update not changed`, and JUST HAPPENED says `Zoom already installed`. A token missing from `config.json` or refused by the check means Zoom installs without auto-update, with the yellow note `Zoom auto-update not set`. A failed install is red, as for 7-Zip.
    - The step does not open Zoom, sign in or change its settings, and it keeps the installer's desktop icon (expected on the public desktop). The report's Apps list shows Zoom's version. The install, the auto-update setting, the icon and the report's name for Zoom are checked on the first laptop with Zoom on ([docs/testing.md](docs/testing.md) 1.22).
11. **Craft apps** (Office CRAFT, the default): the free **WordCraft, GridCraft, DeckCraft and PdfCraft** (Word, Excel, PowerPoint and a PDF reader), then the **ArtCraft Launcher**, meant to keep them up to date (checked on the first laptop, [docs/testing.md](docs/testing.md) 1.17).
    - Each is the MSI for the PC's processor (x64 or arm64) from the latest GitHub release of its project. It runs only after its `SHA256SUMS.txt` line and its `Learning Machines Inc` signature check out, and an app already at that version is skipped.
    - Desktop shortcuts `Word`, `Excel`, `PowerPoint` and `PDF Reader`, normally on the public desktop (**all users**). When an MSI put its own shortcut on the signed-in user's desktop, it is renamed there and stays that user's only. `ArtCraft Launcher` goes on the **signed-in user's** desktop, unless the MSI already put it on a desktop. A shortcut of that name already on a desktop stays; nothing is overwritten or deleted.
    - A failed app is red; the launcher or a shortcut alone is a yellow note. GitHub limits and the fields: [Changing apps and lists](#changing-apps-and-lists).
12. **Chrome as default browser** (best effort). After the final restart Windows may take a while to apply it, so the end of the run waits up to 2 minutes for it before checking.
13. **Vendor drivers + BIOS, pass 1** for Dell, Lenovo and HP (laptops and brand-name desktops).
14. **Microsoft 365** (Hebrew + English), with Office BUSINESS or HOME. It **starts here and installs in the background** while Windows Update round 1 runs. Only **Word, Excel, PowerPoint, Outlook (classic) and OneNote** are installed. A restart waits for it, for at most 60 minutes.
15. **Windows Update** in rounds, **one update at a time**, with reboots, until the search comes back empty (capped). Driver updates are installed even when they ask for input; firmware updates only on mains power. With **Drivers only** (the toolbox's UPDATES row) it searches driver updates only; cumulative and feature updates are left to Windows (the final screen's **U** hands them to Windows).
16. **Microsoft 365, finish**, with Office BUSINESS or HOME: collects the result of the background install (this step has no line of its own on the screen) and puts **Word, Excel, PowerPoint and Outlook shortcuts on the desktop of all users**, also when Office was already installed.
17. **Vendor drivers + BIOS, pass 2**, for what only became applicable after Windows Update.
18. **Vendor consumer app** on laptops (SupportAssist, Vantage, HP Support Assistant, MyASUS, ...). When `config.json` says how to recognise the app (`verify`, see [Changing apps and lists](#changing-apps-and-lists)), the step checks that the app is really there after winget reports success, and fails if it is not. Then the business updater is removed if the consumer app installed.
19. **Finalize**: final power settings, an attempt to activate Windows when it has a product key but is not activated, the final restart, cleanup, the **restore point** when it was chosen (see [The restore point](#the-restore-point)), `Setup-Report.txt`, the final screen.

## Daily use

1. **Put the launcher on a USB stick formatted exFAT or FAT32**: copy `dist\BenTechSetup.cmd` to the stick (see [Publishing](#publishing-a-new-version) for when to re-copy it). exFAT/FAT32 files carry no Mark-of-the-Web, so there is no SmartScreen warning. Spaces, Hebrew letters and apostrophes in the launcher's path are fine. **Leave the stick in the PC:** at the end the logs are saved to it (see step 5). Neither the v2 nor the toolbox release changes the launcher, so a stick that holds the current one stays valid.
2. **On the fresh PC**: finish OOBE with a local account (no password), connect to the internet, double-click `BenTechSetup.cmd`, click **Yes** on the UAC prompt. The BenTech Toolbox window opens on top of the console.
3. **The BenTech Toolbox window opens** (on top, after the UAC prompt) and waits for you. There is no countdown: nothing starts until you press **Start**. It is a dark window of about 1000 x 680 with English or Hebrew text.

   - **Machine card:** make and model, serial number (`SN`), the name the PC will get (`New name`) and the power state (`On charger` / `On battery`). The power state is read again every 5 seconds, so plugging the charger in or out shows within seconds. The machine values always read left to right, also in Hebrew.
   - **Profiles:** three tiles, **Home PC** (the one the window opens on), **Business PC** and **Clean Windows**. **A profile only fills in the options**: every option stays switchable for this PC, and changing one never changes the profile tile (the report then names the profile with `(changed)`). The Type (laptop or desktop) is never part of a profile: it is detected.

     | Profile | Office | Remote | 7-Zip | Tweaks | Restore point |
     |---|---|---|---|---|---|
     | Home PC | Craft (free) | AnyDesk | yes | the defaults | yes |
     | Business PC | 365 Business | Both (AnyDesk and ScreenConnect) | yes | the defaults | yes |
     | Clean Windows | none | AnyDesk | no | none | yes |

   - **The tiles and switches:** **Type** (Laptop / Desktop), **Office** (Craft (free) / 365 Business / 365 Home / None), **Remote** (AnyDesk / ScreenConnect / Both), **Updates** (Full updates / Drivers only) and **Apps** (Chrome is always installed; 7-Zip and Zoom are switches). Type, Office, Remote and 7-Zip are the choices the console screen makes with `L` / `D`, `O`, `R` and `Z`. **Zoom** is off when the window opens, and a profile click keeps whatever it is on (no shipped profile sets it); with it on, the "What will happen" list shows `Zoom` right after `7-Zip`. The console fallback has no line or key for it and runs the start choice: the default profile's `zoom` when it sets one, else `defaults.zoom` (off as shipped). **Updates** is Full updates in every shipped profile, and a profile click keeps whatever it is on (no shipped profile sets it); with **Drivers only**, Windows Update installs driver updates only and the "What will happen" list names the step `Windows Update (drivers only)`. The console fallback has no key for it and runs the start choice: the default profile's `windowsUpdate` when it sets one, else `defaults.windowsUpdate` (Full updates as shipped). While ScreenConnect is chosen (ScreenConnect or Both) a yellow reminder reads `ScreenConnect = unattended access: get the customer's OK first`; it is only a reminder, nothing waits for it. **Tweaks** have one row each, with a switch, an icon, the title and a one-line explanation, and the full text in a tooltip ([System tweaks](#system-tweaks)). The last switch is **Restore point at the end** ([The restore point](#the-restore-point)). A row the rules rule out is hidden (NumLock on a laptop, classic Outlook without Microsoft 365, the three Windows 11 tweaks on Windows 10).
   - **What will happen** (right-hand column): the numbered list of the steps this PC will run. It comes from the same plan the run uses, so it always matches; it changes with every click, shows the step names in the window's language and scrolls by itself when it is longer than the window. **Start** (the large blue button) and **Cancel** are under it.
   - **Yellow banner:** the warnings the console screen has always shown: `This PC already has user files or is older than 14 days` (it does not look like a fresh install), `Previous run: <date> - <result>` (details below) and `On battery: BIOS updates will be skipped`. It is not there when there is nothing to warn about.
   - **Red banner and a disabled Start: Administrator protection.** When setup runs as another user than the one signed in, the banner says `Setup is running as a different user than the one signed in (Windows Administrator protection, or an admin password typed for another account). It would not resume after a restart: sign in as this PC's administrator, or turn Administrator protection off in Windows Security.` Start stays disabled while that lasts (the resume task would register the wrong, hidden account): **turn Administrator protection off in Windows Security, then start the launcher again**. Cancel and the X still work. A signed-in user name that is empty (an RDP session, an early logon) or cannot be read counts as the same user and does not block.
   - **EN | HE:** the switch in the title bar changes the window's language **for this run only** (the window opens in `toolbox.language`, `en` as shipped). Hebrew turns the whole window right-to-left. `setup.log`, the report and the console stay English. The title bar also drags the window, and the X is Cancel.
   - **Start** works with the mouse only. It is not the default button and cannot take the keyboard focus, so Enter and Space never start a run, and **Esc does nothing**. Start closes the window and the run goes on exactly as before: the console progress screen, the restarts, the final screen.
   - **Cancel, the X and Alt+F4** do what Esc does on the console start screen: no setup step runs, any leftover resume task is removed, and on a PC that no earlier run touched, the `C:\BenTech` folder the launcher made is deleted too. If an earlier run left its state, nothing is deleted.
   - **Small screens:** the window is 1000 x 680, clamped to the screen's work area when that is smaller. On the basic display driver at 1024 x 768 and 100% it keeps 1000 x 680; at 150% scaling (a 683 x 512 screen in device-independent pixels, the work area shorter by the taskbar) it takes the whole work area and its content scrolls, sideways too when the window is narrower than the content. Start stays at the bottom of the "What will happen" column, whose list scrolls on its own.
   - **Ctrl+C** pressed in the console behind the window takes effect only after the window closes.

   **The emergency path: the console start screen.** It appears only when the window cannot open (the line `Toolbox not available; using the console start screen` in `setup.log`: the thread is not STA, the session is not interactive or is session 0, or WPF cannot be loaded) or when the window fails once it is open (`Toolbox failed; using the console start screen`). A failure is never read as Cancel. **The console fallback waits for Enter (TB-R8):** it has no countdown and never starts by itself, also on a fresh PC, because the window promised to wait and you may have walked away from it; a window that failed later must not start a run nobody pressed Start for, on choices nobody made. Otherwise the console screen is the one below, unchanged. It has no lines or keys for profiles, tweaks or the restore point: the run takes the default profile's tweaks and restore point (`L` / `D` and `O` still drop or bring back NumLock and classic Outlook). It has no Administrator-protection block either; the tweaks step then skips the per-user values with a note.

   ```
    =============================================================================
      BENTECH WINDOWS SETUP                                         v2026.10.20.1
    =============================================================================
      Dell Latitude 5440    SN: ABC1234    ON CHARGER
      New PC name: DELL-ABC1234

      WHAT WILL HAPPEN                                  TO CHANGE IT, PRESS
      Type     LAPTOP (driver tool + laptop app)        L = laptop   D = desktop
      Chrome   always
      Remote   ANYDESK                                  R = anydesk / sc / both
      7-Zip    YES                                      Z = yes / no
      Office   CRAFT (free Word/Excel/PowerPoint/PDF)   O = craft / 365 / off

      ENTER = start now           ESC = cancel, change nothing
    =============================================================================
   ```

   - **Top block:** the PC (make, model, serial number `SN`), whether it is on its charger or on battery, and the name it will get.
   - **WHAT WILL HAPPEN:** one line per choice, with the key that changes it on the right. The `Type` line says what the mode means: a laptop gets the vendor driver tool and the laptop app; a brand-name desktop gets the driver tool but no laptop app; a brand with no driver tool (ASUS, a VM) gets no driver tool and the line says `no driver tool for this brand` (an ASUS laptop still gets its laptop app, MyASUS; a VM gets neither). Chrome always gets installed.
   - **Remote:** the default is **ANYDESK**, as before. **R** goes to SCREENCONNECT, then BOTH (the line reads `ANYDESK + SCREENCONNECT`), then back to ANYDESK. While ScreenConnect is chosen a yellow line follows: `ScreenConnect = unattended access: get the customer's OK first`. It is only a reminder: nothing waits for it.
   - **Office:** the default is **CRAFT**, the free Craft apps (WordCraft, GridCraft, DeckCraft, PdfCraft and the ArtCraft Launcher; see "What it does", item 11). They are alpha, so Microsoft 365 is one key press away: **O** goes to BUSINESS, then HOME (both install Microsoft 365), then OFF, then back to CRAFT. The tool installs one suite or the other, never both.
   - **Colours:** on a black screen, the value of each choice is green (yes / on) or dark grey (`NO` / `OFF`); a yellow line is a warning.
   - **No countdown (TB-R8):** only Enter starts the run. (`Show-StartScreen` keeps its v2 30-second countdown, `Starts by itself in N s`, for a caller that does not pass `-NoAutoStart`; the setup never is one: `Get-SetupChoices` always passes it.)

   | Key | Does |
   |---|---|
   | `L` / `D` | Laptop / Desktop mode (auto-detected; a VM defaults to Desktop) |
   | `Z` | 7-Zip on/off |
   | `O` | Office cycles CRAFT (the default), BUSINESS, HOME, OFF. CRAFT is the free Craft apps; BUSINESS and HOME are Microsoft 365 (Hebrew + English) |
   | `R` | Remote tool cycles ANYDESK (the default), SCREENCONNECT, BOTH. ScreenConnect is unattended access: get the customer's OK first |
   | `Enter` | Start now |
   | `Esc` | Cancel (the same as Cancel in the toolbox): no setup step runs, and any leftover resume task is removed. On a PC that no earlier run touched, the `C:\BenTech` folder the launcher made is deleted too, so nothing of setup's own is left. If an earlier run left its state, Esc deletes nothing: its logs stay for diagnosis |
   | any other key | Nothing changes |

   The three warnings below are the ones the toolbox's yellow banner shows too (the window has no `press ENTER`). On battery a yellow line warns that BIOS updates are skipped unless you plug in. If the PC does not look like a fresh install (Windows older than 14 days, or more than 1 GB in Desktop/Documents/Downloads) the screen says `This PC already has user files or is older than 14 days - press ENTER to run anyway`. A `Previous run: <date> - <result>` line appears when an earlier run left its `state.json` behind: normally after an unfinished run (`UNFINISHED`: a crash, or a run stopped half way). A run that was finished with Enter deletes `C:\BenTech` and so shows nothing; if its folder survived (the window was closed instead of pressing Enter, `rd` could not delete it, or Windows is not on drive C:) the line shows that run's colour, for example `GREEN`.
4. **Walk away.** The progress screen (below) shows what is happening. The machine reboots by itself (a 15 s `Restarting in N s ...` countdown on screen), logs in by itself and carries on. If Microsoft 365 is still installing in the background, the restart waits for it (the screen says so). Nothing asks for input.
5. **Come back to the final screen.** The whole console is green, yellow or red. Press **Enter** to finish. Keys:

   | Key | Does |
   |---|---|
   | `Enter` | Finish: save the logs, clean up, close (see below) |
   | `B` | Open Default Apps for Chrome (the screen suggests it when Chrome is not the default) |
   | `R` | Open the report in Notepad |
   | `U` | Only after a Drivers only run: opens Settings > Windows Update and starts its check; Windows downloads and installs on its own, also after Enter and after the console is closed, and decides when to restart ([docs/testing.md](docs/testing.md) 1.20 checks that). Press U, then Enter before you leave |
   | any other key | Nothing: a stray key does not throw the logs away |

   **After a Drivers only run** the last line reads `[R] report   [U] Windows Update   [ENTER] finish`, without the report path to make room for U (R still opens the report, and after Enter it is in the logs folder on the stick, when the stick is found). The blank line above the Chrome hint and the stick line shows the outcome of the last U: `Windows Update started: Windows will finish on its own`, or `Could not open Windows Update: open Settings > Windows Update` (then open it by hand; the reason is in `setup.log`). U can be pressed again; each press opens Settings once more. After a Full updates run the last line is `Report: <path>   [R] open report   [ENTER] finish` and U does nothing. Drivers only never changes the colour of the screen.

   **The remote tools on this screen:** the AnyDesk ID in big digits shows only when AnyDesk was chosen (ANYDESK or BOTH). With ScreenConnect chosen the `New name` line ends in `ScreenConnect: installed` or `ScreenConnect: NOT installed`, so the name to look for sits beside the status; with SCREENCONNECT alone there is no AnyDesk ID at all. The PC should appear in Ben's ScreenConnect list under that name after the final restart (unproven until [docs/testing.md](docs/testing.md) 1.18).

   **The USB-stick line** right above the last line (the report line, or the key line after a Drivers only run) says whether the stick is there, and is checked again every second: `USB stick found (E:) - logs will be saved there`, or `No BenTech USB stick - plug it in now to keep the logs`. Plug the stick in while the screen is up. **With no stick, Enter deletes the logs without asking again.** To keep them anyway, copy `C:\BenTech\Setup\Logs` from an elevated prompt before you press Enter.

   **What Enter does**, in this order:
   1. **Saves the logs:** the whole `Logs` folder goes to `<stick>\BenTech-Logs\<PC name>\` (the new PC name), with the run's `state.json` beside it as `state-final.json`. A folder of the same name from an earlier run is replaced. When it worked, the screen shows `Logs saved to <folder>` for about 3 seconds. The stick is the drive the launcher was started from; if it is plugged in under another letter it is found by its serial number; otherwise it is any other removable or hard drive with `BenTechSetup.cmd` in its root (the only rule that works when you started the launcher from the Desktop). A stick whose `BenTech-Logs` folder is a link is refused and nothing is saved. If saving fails, the screen says why and waits for Enter before going on, so you can still save the logs by hand.
   2. **Deletes the Desktop launcher:** if you started `BenTechSetup.cmd` from the user's or the public Desktop, that copy is deleted. Only a `.cmd` file on a Desktop is ever deleted: a launcher on the stick, or anywhere else, is never touched.
   3. **Deletes `C:\BenTech`** (and `C:\ProgramData\BenTech` when it is empty), so **no setup folder is left**. If it cannot be deleted the screen says `delete it by hand` and waits for a key. On a PC whose Windows is not on drive C: the folder is kept (`Not deleting ...`). The folder is also kept while the resume task could not be removed (`Resume task BenTechSetup-Resume is still registered: C:\BenTech kept - delete the task, then the folder, as administrator`, then a key): that task starts `C:\BenTech\Setup\setup.ps1` as administrator at every sign-in, and only the admin-only folder stops anyone else from putting a file of that name there. Delete the task first (`Unregister-ScheduledTask BenTechSetup-Resume -Confirm:$false` in an administrator PowerShell), then the folder.

   A **crash** is different: it leaves everything in place (the folder, the logs and the resume task) so you can see what went wrong. See [Setup crashed](#setup-crashed).

### System tweaks

The toolbox offers nine small, safe Windows settings, one switch each. A tweak ships only if it passes the five rules of [toolbox spec 6.1](docs/specs/2026-10-21-toolbox-design.md) (it works on Windows 11 Home and Pro, nothing harmful, reversible, no `\Policies\` path, a clear benefit); the exact values and the research are in the [fact cards](docs/specs/2026-10-21-toolbox-tweak-factcards.md).

| Tweak | Default | What it does |
|---|---|---|
| `accessKeys` Accessibility shortcuts off | **on** | Sticky Keys (Shift x5) and Filter Keys (hold right Shift) stop popping up; both stay available in Settings. Clears bit 4 of the two accessibility `Flags` values (REG_SZ). |
| `numLock` NumLock on at sign-in | **on, desktops only** | The number pad works at the sign-in screen. Writes the sign-in screen's own profile (`HKEY_USERS\.DEFAULT`) and the account's. Offered and applied only when Type is Desktop: a laptop with a number pad inside the letter keys would type digits into the password box. |
| `startClean` Start menu: no recommended tips and apps, no account nags | **on** | Turns off the recommendations in Start and the account notifications on Start. |
| `noAds` No tips, suggestions and ads in Windows | **on** | No tips notifications, no suggested content in Settings, no lock-screen fun facts, no OneDrive or Microsoft 365 banners in File Explorer. |
| `classicOutlook` Keep classic Outlook | **on, only with Office 365 Business or Home** | Hides the "Try the new Outlook" switch. |
| `fileExtensions` Show file extensions | off | Shows `invoice.pdf.exe` as what it is. Off everywhere (Q27): no profile turns it on, you switch it on per PC. |
| `taskbarLeft` Taskbar icons on the left | off | The Windows 10 layout. Windows 11 only. |
| `classicMenu` Classic right-click menu | off | The full right-click menu in one click. Windows 11 only. |
| `endTask` End task in the taskbar right-click menu | off | Closes a frozen app from the taskbar, without asking to save. Windows 11 only. |

- **They take effect at the next sign-in**, which the run's restarts provide. They reach only the account that runs setup, which is the customer's account (as the other steps assume): accounts created later get the Windows defaults.
- **A refused tweak is a yellow note**, `<title> could not be applied`, and the other tweaks still run. A tweak is never red: Windows works without it. (Windows' UCPD driver refuses some writes from PowerShell; none of the nine values is known to be on its list. With Windows Administrator protection on, which the toolbox blocks but the console fallback does not, the per-user values are skipped with one note, `Per-user tweaks skipped: Windows Administrator protection is on`, and NumLock's sign-in screen value is still written.)
- **There is no undo**: the toolbox is gone after the run. **Every original is in `setup.log`**: in `C:\BenTech\Setup\Logs\setup.log` until Enter on the final screen, then in `<stick>\BenTech-Logs\<PC name>\setup.log` (Enter deletes `C:\BenTech`). There is one `Tweak value` line per value with the path, name, type, the original (`absent` when there was none), the new value, the value read back and the result. To reverse a tweak by hand, write the original back, or delete the value when it was `absent`. A value that cannot be read is never written over, and a value already at its target is left alone on a re-run.
- The report has a `Tweaks       :` line (`5 applied: accessKeys, numLock, ...`, with `(refused: ...)` and `(skipped, Administrator protection: ...)` when there are any), and JUST HAPPENED gets `Tweaks: 5 applied`.

### The restore point

**Restore point at the end** (on in all three profiles) creates a Windows restore point named `BenTech setup` at the very end of the run, in Finalize: after the resume task, the downloads and the setup files are gone, and before the report is written. The snapshot is then the finished PC, not the setup's temporary policies, power values or resume task.

- **System Protection is turned on** for the system drive (a restore point needs it) and reserves a few percent of the disk. The report says so: `Restore point: created (System Protection is now on and reserves a few percent of the disk)`.
- **One bounded child process** does the work, limited by `timeoutsMinutes.restorePoint` (10 minutes); NOW reads `Creating a restore point`. It counts as created only when the newest restore point's number rose. Once per run.
- **The frequency value:** Windows silently skips a second restore point within 24 hours, so before the child starts the main setup process records `SystemRestorePointCreationFrequency` (under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore`) in `setup.log` (`Restore point: creation frequency recorded`) and in `state.json`, and sets it to 0. **It puts the original back afterwards, whatever happened** (and removes the value again when it was absent), even after a timeout.
- **A restore point that is not confirmed** (timeout, error, no new point) is a yellow note, `Restore point could not be confirmed`; a frequency value that could not be put back is a second note, `Restore point frequency value could not be put back`. Once the child was started the report reads `Restore point: could not be confirmed (System Protection may now be on)`, since the child turns System Protection on first. An original frequency value that cannot be read, or is not a DWORD, means no attempt at all (nothing written, no child, the same note).
- **Known gap:** a power cut, or a console closed, during these last minutes can leave the frequency value at 0 for good, because the resume task is already removed and nothing resumes to put it back. A value left at 0 only lifts Windows' 24-hour limit between restore points (a later one is no longer skipped): it is benign, but the run still always tries to put it back. The original is in `setup.log` and in `state.json` (`RestorePointOriginalFrequency`); after Enter on the final screen both are on the stick (`BenTech-Logs\<PC name>\setup.log` and `state-final.json`). [docs/testing.md](docs/testing.md) 1.19 checks the value after a normal run.

### Reading the progress screen

Everything the run is doing is on one screen, redrawn about once a second while the run works or waits (the timer does not redraw more often than that), and at once when a step starts or ends. It enlarges the console window to about 100 x 45 when it can; Windows Terminal does not let a script resize it, and the screen then fits whatever size it has (when space runs out, JUST HAPPENED gets shorter first, then the list under NOW).

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
       ... and 3 more
  ------------------------------------------------------------------------------------------------
  JUST HAPPENED
  13:05  Windows Update round 1: found 7, installed 6, failed 0
  12:58  Microsoft 365 started installing in the background (he-il, en-us)
  12:57  Drivers (pass 1) done - Dell Command Update finished
  12:30  Rename PC skipped - already named DELL-ABC1234
```

(The names, times and counts in this example are made up, and it is a run with Office BUSINESS. With CRAFT the checklist has one `Craft apps` line right after `7-Zip` and no Microsoft 365 line, NOW reads for example `Craft apps - WordCraft 0.8.0: downloading`, and JUST HAPPENED gets one line per app, for example `WordCraft 0.8.0 installed - desktop shortcut: Word` or `PdfCraft 0.9.0 already up to date`.)

- **Header:** the total time since the run started, how many times the PC restarted, and a **spinner** (`| / - \`) that turns on every redraw (in the example above it is the `/` in the first line, between `do not turn off` and `Total`; the `/` in the NOW line is only a separator). The spinner and the timers moving is the sign of life: if they stand still for more than a couple of minutes, something is probably stuck, and `Logs\setup.log` shows the last thing it did. (A few short waits, such as starting the Dell service, can stand still for up to a minute.)
- **Checklist:** one line per step of this run, in order, in as many columns as fit. The whole screen is on a black background. Markers: `[OK]` done (green), `[>>]` running (cyan), `[X ]` failed (red), `[--]` skipped (dark grey), `[..]` still to do (plain). The reason of a failed or skipped step is not here; it is in JUST HAPPENED.
- **`(bg)` after Microsoft 365** means it is installing in the background, next to the step NOW shows, with its own timer. When the background installer has ended but the finishing step has not run yet it reads `(bg ended)`; after that the line shows the result.
- **NOW:** the step that is running, with what it is using (the tool, the Windows Update round), and its time. While the step waits for something that has a time limit, the time is shown against the limit: `14:10 (of max 90 min)` means 14 minutes 10 seconds so far and the wait ends at 90 minutes. Under it, what the step reports: for a **driver pass** the tool's own latest log line (`Log: ...`), for **Windows Update** the phase (`Installing 3 of 7`) and the list of updates with a marker each, while **Microsoft 365 holds up a restart** `Waiting for Microsoft 365 to finish before restarting`. With nothing to report it shows the newest JUST HAPPENED line.
- **JUST HAPPENED:** the newest facts first, each with its time: versions installed, the AnyDesk ID, the new PC name, each bloatware app removed, each Windows Update round and driver pass summarised, why a step failed or was skipped, and `Restarting (restart N)` / `Back after restart N`. It survives restarts; a new run starts it empty.

### What the colours mean

The final screen is white text on dark green (GREEN), **black text on yellow** (YELLOW) or white text on dark red (RED).

| Colour | Banner | Meaning |
|---|---|---|
| GREEN | `SETUP COMPLETE` | Every step done, no notes. |
| YELLOW | `COMPLETE - CHECK NOTES` | No failures, but something needs a look: a step skipped (unsupported model, Store sign-in needed, ARM64), Chrome is not the default, Windows not activated (or its status could not be read), BitLocker still decrypting, Windows 10 (no security updates), a Lenovo result that could not be verified, BIOS or firmware updates left alone because the PC was on battery, the Office or Craft desktop shortcuts, the ArtCraft Launcher (the apps work without it), a Zoom that was already installed or installed without auto-update, the power settings or the resume task that could not be put back, a system tweak Windows refused (or per-user tweaks skipped under Administrator protection), the restore point that could not be confirmed (or its frequency value that could not be put back). |
| RED | `COMPLETED WITH ERRORS` | A step failed or never finished, a Windows update failed repeatedly (`left to Windows Update`: setup hid it during the run and un-hid it at the end; one it could not un-hide says `Windows update still hidden: ... - un-hide it in Windows Update`), a cap was hit (reboots or update rounds), the drive is still encrypted, or a restart was refused. |

The final screen lists at most 3 failures and 2 notes, each with a one-line reason, then `... and N more: see the report`. The report lists them all.

### Where things are

**During a run, and after a crash** (`C:\BenTech\Setup`):

| What | Where |
|---|---|
| Report | `C:\BenTech\Setup\Logs\Setup-Report.txt` (also lists the Windows updates installed, per round, and after the `ScreenConnect:` line the `Profile`, `Tweaks`, `Restore point` and `Updates` lines) |
| Our log | `C:\BenTech\Setup\Logs\setup.log` |
| The JUST HAPPENED feed | `C:\BenTech\Setup\Logs\activity.txt` (an earlier run's: `activity-<RunId>.txt`). The AnyDesk ID is here and in the report, never in `setup.log` |
| Windows Update rounds | `C:\BenTech\Setup\Logs\wu-round<N>.json` (the round's result) and `wu-round<N>.progress.json` (the live list the screen reads) |
| Console transcripts | `C:\BenTech\Setup\Logs\transcript-<time>.txt` |
| Vendor tool logs and reports | `C:\BenTech\Setup\Logs\` (for example `dcu-pass1.log`, `HPIA-pass1\`) |
| Craft app installs | `C:\BenTech\Setup\Logs\craft-<assetPrefix>.log`: msiexec's verbose log of each Craft item (for example `craft-wordcraft.log`) |
| Run state | `C:\BenTech\Setup\state.json` (older runs: `Logs\state-<RunId>.json`) |

`Downloads\`, the pinned `setup.ps1` and `config.json` are deleted when Finalize ends. `Logs\` and `state.json` stay until you press Enter on the final screen.

**After a finished run** nothing of setup's own is left in `C:\BenTech`: Enter on the final screen copied the whole `Logs\` folder (and `state.json`, as `state-final.json`) to the USB stick, to `<stick>\BenTech-Logs\<PC name>\`, and deleted `C:\BenTech`. Read the report and the logs there. What setup does not remove (`C:\Program Files\OfficeDeploymentTool` after Microsoft 365, a few empty policy keys) is listed in [docs/testing.md](docs/testing.md) section 5. (With CRAFT, the default, no `OfficeDeploymentTool` folder is left at all. With no stick, the logs are gone: see step 5 of [Daily use](#daily-use).)

**While `C:\BenTech` exists, open the logs with R on the final screen or from an elevated prompt** (for example `notepad C:\BenTech\Setup\Logs\setup.log` in an administrator Terminal). Never browse to `C:\BenTech` in Explorer: its "You don't currently have permission... Continue" button adds your own account to the folder's permissions, and the next run then refuses the folder with exit code 5 (it is no longer admin-only), so you would have to delete it, logs included.

## Troubleshooting

### Launcher exit codes

The launcher window stays open for 15 seconds after a failure. The exit code is also visible if you start it from a command prompt.

| Code | Message | What to do |
|---|---|---|
| 0 | (none) | Setup ran and ended normally. This includes Cancel in the toolbox (Esc on the console start screen) and a restart in progress. The colour of the final screen is the result, not the exit code. |
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
4. To stop the retries without running again: double-click the launcher and press **Cancel** in the toolbox (Esc does nothing there; Esc is for the console start screen). That removes the leftover resume task and runs no step. When the crashed run saved its state, Cancel deletes nothing: the launcher's fresh `setup.ps1`, `config.json` and the `Logs\` folder stay in `C:\BenTech\Setup`. Copy the logs out (from an elevated prompt) before you delete the folder by hand. **Exception:** a crash before the run's first state save (or a corrupt `state.json`) leaves no readable state, and then Cancel deletes `C:\BenTech` with its logs, so copy the logs out before you press Cancel.

An unreadable `state.json` (power cut mid-write) is archived as `Logs\state.corrupt-<time>.json` and a new run starts by itself. (Known gap, in two cases: after a corrupt `state.json`, and after a crash before the first save, there is no readable state, so Cancel on the start screen (Esc on the console one) counts as a fresh PC and deletes `C:\BenTech` with those logs. Copy out what you need first.)

## Publishing a new version

Pushing to `main` does not reach any customer. Only a published GitHub Release does.

1. Commit and **push** first. `Publish.ps1` refuses a dirty working tree or a HEAD that is not pushed, because the release tag must point at the code that was built. (`-DryRun` only warns.)
2. Run:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.19.1 -Notes "What changed"
   ```

   The version is `yyyy.MM.dd.N`; `N` counts releases on that day. Add `-DryRun` to do everything except the upload (it still builds and signs `dist\` locally and prints the `gh` command).
3. It stops at the first failure and runs: clean/pushed check and the ScreenConnect installer check, the full test suite, bundle (and a copy of the installer into `dist\`, checked again there on a real publish), sign `setup.ps1` and `config.json` with your private key, verify both signatures against `keys\public-key.xml`, build the launcher, then `gh release create v<Version> --target <HEAD>` with five files: `setup.ps1`, `setup.ps1.sig`, `config.json`, `config.json.sig` and `ScreenConnect.ClientSetup.exe`.
   - **The fifth file is Ben's own installer**, read from `%USERPROFILE%\.bentech-winsetup\ScreenConnect.ClientSetup.exe` (beside the signing key; `-ScreenConnectInstaller <path>` names another file). It has no `.sig`: the signed `config.json` pins its SHA-256. The release is public, so anyone can download the installer (spec section 7).
   - **It is checked first**, before the slow test run: the file exists, its SHA-256 equals `apps.screenconnect.sha256` in `config.json`, and its Authenticode status is `Valid` with a `ConnectWise, LLC` signer. Any failure stops a real publish. With `-DryRun` it is only a `WARNING: ScreenConnect installer ...` line, and a missing installer is left out of the printed `gh` command.
   - **The end date:** Publish prints `ScreenConnect installer certificate ends dd/MM/yyyy`, and a yellow warning when that is less than 60 days away (a warning only, also on a real publish). See [A new ScreenConnect installer](#a-new-screenconnect-installer).
4. **Check the launcher hash it prints.** The launcher is the trust anchor (it holds the public key), so it is never uploaded to GitHub. Publish prints `Launcher SHA-256: ...` and records it in `keys\launcher.sha256`.
   - **Hash unchanged:** the USB sticks are still current.
   - **Hash changed** (a `WARNING: the launcher changed` line): copy the new `dist\BenTechSetup.cmd` to every USB stick. The launcher only changes when the public key, the repo URL or `launcher\BenTechSetup.template.cmd` changes. A normal release (code or config) does not change it.
   - Commit and push the updated `keys\launcher.sha256`; the next real publish needs a clean tree.
5. Don't publish while a PC is downloading: the launcher fetches the four files one by one from `/releases/latest/`, so a publish in between could hand it files from two versions.

**The very first publish** needs the GitHub repo `BenTechit/bentech-winsetup` to exist (public: the repo holds only the public key and no secrets, but every release also carries Ben's ScreenConnect installer, screenconnect spec section 7), the branch pushed with an upstream, `gh auth status` logged in, and Ben's installer saved as `%USERPROFILE%\.bentech-winsetup\ScreenConnect.ClientSetup.exe` (a real publish refuses without it; see [A new ScreenConnect installer](#a-new-screenconnect-installer)). Creating the repo, pushing and publishing are outward-facing: **run these only after Ben's go-ahead**, from the repo root, with the work merged into `main` and the key backup done (see [Signing key](#signing-key)):

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

The next launcher run downloads that release. Machines already running keep their pinned copy. Then fix forward with a new release (`N+1`). A rollback brings back that release's own ScreenConnect installer too: each run downloads the installer from its own release (`releases/download/v<its version>/`), never from `latest`.

### A new ScreenConnect installer

Needed when Ben builds a new installer (a new ScreenConnect version, or another instance), and in any case **before 19/02/2027**. The installer is signed with no timestamp, so from 20/02/2027 Windows stops reporting its signature as `Valid`. Publish warns 60 days ahead; until a new release is out, the ScreenConnect step refuses the old installer with a red `ScreenConnect installer check failed`. (PCs that already have the client are not affected: they update themselves from Ben's server.)

1. **Save the new file** as `%USERPROFILE%\.bentech-winsetup\ScreenConnect.ClientSetup.exe`, beside the signing key. It never goes into the repo or a synced folder (OneDrive, a cloud-backed Desktop or Downloads). **Never run it on the dev PC:** it would enrol that PC in the list. Read what it is:

   ```
   $exe = "$env:USERPROFILE\.bentech-winsetup\ScreenConnect.ClientSetup.exe"
   Get-FileHash $exe -Algorithm SHA256
   $sig = Get-AuthenticodeSignature $exe
   $sig.Status                       # must be Valid
   $sig.SignerCertificate.Subject    # must hold CN="ConnectWise, LLC" (Windows puts the quotes there)
   $sig.SignerCertificate.NotAfter   # the end date: build the next installer before it
   ```
2. **Update `config\config.json`:** `apps.screenconnect.sha256` becomes the new hash. `serviceName` changes only if a test install shows another suffix. Run the tests, commit, push.
3. **Publish a new release** ([Publishing](#publishing-a-new-version)). A real publish refuses an installer whose hash is not the one in `config.json`, so a stale `config.json` or the wrong file cannot go out.

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

Everything Ben may want to change without touching code is in `config\config.json`: the 7-Zip, Zoom and Office defaults, Zoom's auto-update token, the Chrome and AnyDesk download URLs, the ScreenConnect installer's pin, winget IDs, the Office products and languages, the vendor tool matrix and consumer app IDs, expected Authenticode signers, the bloatware remove/protect lists, the toolbox profiles and tweaks, caps and timeouts.

Edit it, run the tests (they check that the remove and protect lists don't overlap, that every signer reference exists and that every `verify` entry is well formed), commit, push, publish. No launcher update is needed. Keep it UTF-8 and valid JSON.

Settings worth knowing:

- **`windowsUpdate.installMode`**: `"OneAtATime"` (the default) downloads and installs each Windows update on its own, so the screen shows `Installing 3 of 7`; `"Batch"` is the v1 way, all updates in one go, and the screen then shows only the phase and the list. Switch to `"Batch"` if one at a time turns out too slow on a machine. The round limit (`timeoutsMinutes.wuRound`, 90 minutes) and the round cap (`caps.maxWuRounds`) apply to both.
- **`defaults.windowsUpdate`**: `"FULL"` as shipped, or `"DRIVERS"` (Windows Update searches driver updates only); a missing or invalid value is FULL. It is the start choice unless the default profile sets `windowsUpdate`.
- **`apps.craft`** (with **`signers.craft`**): the Craft apps, installed in the order of `items` (the four apps, then the launcher). Each item has these fields:
  - `name`: shown on screen and in the report;
  - `repo`: the GitHub `owner/name` whose latest release holds the MSI;
  - `assetPrefix`: the release's installer is `<assetPrefix>-<version>-windows-<x64|arm64|x86>.msi`, and exactly one asset may match (two matches install nothing);
  - `displayName`: a regex for the program's `DisplayName` under Uninstall. It finds the installed version, so the report lists the app and a second run skips it as `already up to date`;
  - `startMenuName`: a regex for the program's **Start-menu** shortcut names, used when the step copies a Start-menu shortcut to the desktop. The shortcut named exactly like the app wins, else a single match is used, and two or more loose matches give no shortcut and a yellow note (on the desktops no regex is used: only the MSI's own `<name>.lnk`, named exactly like the app, is renamed in place);
  - `shortcut`: the name of the desktop shortcut (`Word`, `Excel`, `PowerPoint`, `PDF Reader`);
  - `launcher` (only on the ArtCraft Launcher): `true` puts the shortcut the step makes on the signed-in user's desktop instead of the public one, and its failure is a yellow note instead of a red failure.

  **`displayName` and `startMenuName` are best guesses** (`^WordCraft` and so on) until [docs/testing.md](docs/testing.md) section 1.17 confirms the real names on a laptop: if the report lacks a Craft app's version, or a desktop shortcut is missing, correct the regex there. `signers.craft` is the company name the MSIs' Authenticode signature must carry (`Learning Machines Inc`): the signer certificate's one CN must be exactly that, letter for letter. It is matched by name and never by thumbprint, because their certificates live 3 days.

  **GitHub limits:** GitHub allows 60 lookups an hour per IP, and a laptop needs 5. A rate-limit answer (HTTP 403 or 429) gets one retry after 60 s; a second one fails that item with `GitHub busy - try again later`, and the items after it fail the same way at once, without asking GitHub again. A network blip is asked again after 5 s and 10 s. The MSI and `SHA256SUMS.txt` links must point into the project's own `https://github.com/<repo>/releases/download/`; any other link fails the item with `release lookup failed`. msiexec logs each install to `Logs\craft-<assetPrefix>.log`.
- **`apps.screenconnect`** (with **`signers.connectwise`**, **`defaults.remote`** and two timeouts): Ben's ScreenConnect installer. Its fields:
  - `signer`: `connectwise`, the key in `signers`;
  - `url`: the installer in this repo's release. `{version}` becomes the run's own bundle version, **never `latest`**: a run then never mixes a newer installer with its own `config.json`, and a rollback brings back its own installer. A development run that was not bundled has no version, and the step fails with `ScreenConnect: release version unknown`;
  - `sha256`: the SHA-256 of Ben's installer. This pin, in the signed `config.json`, is what proves the file is Ben's: every ScreenConnect installer carries a valid ConnectWise signature, including one built for somebody else's instance. The downloaded file must match it (case does not matter) **and** carry the signature, else it is deleted and the step fails with `ScreenConnect installer check failed`;
  - `serviceName`: the exact Windows service name (`ScreenConnect Client (b58e7c32699a96bf)`; the suffix is fixed for Ben's instance). A PC that has the service counts as already installed, the service's state decides the result, and the same text is the `DisplayName` the report looks for.

  `signers.connectwise` is `"ConnectWise, LLC"` **with the quotes**: Windows quotes a name that holds a comma, and the check looks for the text `CN=<signer>` in the signer subject (`CN="ConnectWise, LLC", O=...`), so without the quotes the real file would be refused. The step does **not** use the exact-CN rule of the Craft apps (`-ExactCN`): it refuses quoted subjects by design, and the hash already pins the exact file. `defaults.remote` (`ANYDESK`, `SCREENCONNECT` or `BOTH`; a missing or invalid value counts as `ANYDESK`) is the start choice only when `defaults.profile` names no valid profile. With the shipped `defaults.profile` (`home`) the profile's `remote` decides, and a profile without `remote` gets `ANYDESK` (`Get-RemoteChoice`), never `defaults.remote`. `timeoutsMinutes.screenconnect` (10) is how long the installer may run (it has no documented silent switch), and `timeoutsMinutes.screenconnectService` (3) how long the step then waits for the service to run.
- **`apps.zoom`** (with **`defaults.zoom`** and **`timeoutsMinutes.zoom`**): Zoom, the optional app of the toolbox's APPS row. Its fields:
  - `wingetId`: `Zoom.Zoom`, Zoom's per-machine MSI;
  - `custom`: a list of `NAME=VALUE` tokens for the MSI command line. They are joined with one space and passed as winget's `--custom "<tokens>"`. Shipped: `["ZConfig=AU2_EnableAutoUpdate=true"]`, Zoom's documented auto-update setting (Q50). Each token must match `^[A-Za-z0-9_]+=[A-Za-z0-9_=;]+$`: a name of letters, digits and `_`, then `=`, then letters, digits, `_`, `=` and `;`. **No quotes and no spaces**: a quote is how Zoom's own users ended up with msiexec's help box. A token that fails the check is dropped (`setup.log` names its position, never its text) and Zoom installs without it, with the yellow note `Zoom auto-update not set`.

  **Changing the token.** It is built on Zoom's documented value and is proven only on the first customer laptop with Zoom on ([docs/testing.md](docs/testing.md) 1.22; Q55). If auto-update is off after the run, or the step timed out on a msiexec help box (or was red with a winget code after that box was clicked away), correct `apps.zoom.custom`, change the pinned list in `tests\Config.Tests.ps1` with it, run the tests and publish: no code changes. Several Zoom settings share one `ZConfig` token, separated by `;`; another MSI property is another token (for example the one that stops Zoom from starting by itself, if the first laptop shows it does). `defaults.zoom` (`false` as shipped, Q49; anything but `true` means off) is the start choice unless the default profile sets `zoom`. `timeoutsMinutes.zoom` (10) is how long the install may take, instead of `timeoutsMinutes.default` (30).
- **`apps.office.excludeApps`**: the Office apps left out of the install. The default leaves exactly Word, Excel, PowerPoint, Outlook (classic) and OneNote. An id the Office Deployment Tool rejects must be removed from the list. `timeoutsMinutes.office` (60) is how long a background install and a restart waiting for it may take.
- **`vendors.<BRAND>.consumerApp.verify`** (optional): how the vendor-app step recognises the app after winget reports success.

  ```
  "consumerApp": { "source": "msstore", "id": "...", "name": "...",
                   "verify": { "paths": ["%ProgramFiles%\\Vendor\\App\\app.exe"], "services": ["VendorAppService"] } }
  ```

  (The values above are only an example of the shape.) `paths` and `services` are both optional, but at least one must list something. `%VARIABLES%` and wildcards in a path are fine. The paths are tried first, then the services; the first hit counts. Found: the step is Done and an activity line says which check passed. Not found: the step is Failed with `<app> was not found after install`, and the business updater stays. **Leave `verify` out and the step is Done as soon as winget reports success** (the v1 behaviour; no brand has a `verify` entry yet). The real values come from Ben's check of the Start menu and from the `-InventoryOnly` run of Spike 5 after a setup run.
- **`profiles`** (with **`defaults.profile`**): the toolbox's built-in profiles, in the order of the tiles. Each has:
  - `id`: lower-case letters, digits and `-`, starting with a letter, at most 32 characters; a repeated id is ignored;
  - `name`: `{ "en": ..., "he": ... }` (`en` is required, else the profile is ignored; a missing `he` shows the English name);
  - `office` (`CRAFT`, `BUSINESS`, `HOME` or `OFF`), `remote` (`ANYDESK`, `SCREENCONNECT` or `BOTH`), `sevenZip` and `restorePoint` (true or false): a value that is not valid is repaired, never a reason to lose the profile (an invalid `office` takes `defaults.office`, or `OFF`; an invalid `remote` is `ANYDESK`; `sevenZip` takes `defaults.sevenZip`; `restorePoint` is true);
  - `tweaks` (a list of tweak ids): the profile's tweaks **instead of** the ones marked `default` (an empty list means no tweaks, as in Clean Windows); without this field the profile takes every tweak with `"default": true`. `tweaksAdd` adds ids on top. An id that is not in the catalog is dropped;
  - `windowsUpdate` (optional; `FULL` or `DRIVERS`, an invalid value is FULL). Without it a profile leaves the UPDATES tile as it is, and none of the shipped profiles sets it;
  - `zoom` (optional; `true` or `false`, anything else is ignored). Without it a profile leaves the Zoom switch as it is, and none of the shipped profiles sets it (Q49).

  The Type is never a profile field: it is detected. **Adding or changing a profile means a new release** (Q22: built-in profiles only, in the signed `config.json`). `defaults.profile` is the profile the window opens on, and the one the console fallback runs; it wins over `defaults.office`, `defaults.remote` and `defaults.sevenZip`. With it set, those three do not decide the start choices: `defaults.office` and `defaults.sevenZip` only fill in a profile's own missing or invalid `office` and `sevenZip` (see above), and `defaults.remote` is not used at all (a profile without `remote` is `ANYDESK`). A `defaults.profile` that names no valid profile means no profile (the `defaults.*` values and the tweaks marked `default`).
- **`tweaks`**: the catalog the toolbox draws its switches from. An entry has `id` (a letter, then letters and digits, at most 32 characters), `default` (on by default?), `title` and `description` (`en` and `he`), `icon` (the hex code of a glyph in the Segoe Fluent / MDL2 icon fonts, for example `E765`) and `values`, plus the optional rules `desktopOnly` (offered and applied only when Type is Desktop), `office365Only` (only with Office BUSINESS or HOME) and `minBuild` (hidden and not applied below that Windows build; `22000` is Windows 11). Each value is `{ path, name, type, op, value }`, and `bit` for `clearBit`:
  - `path` starts with `HKCU:\`, `HKLM:\` or `Registry::HKEY_USERS\.DEFAULT\` (PowerShell has no `HKU:` drive); the rules of [toolbox spec 6.1](docs/specs/2026-10-21-toolbox-design.md) apply, among them **no `\Policies\` path** (a policy makes Settings say "managed by your organization") and nothing the run's other steps already manage (power, `HiberbootEnabled`, `WindowsUpdate\AU`, the `nags` values, the desktop icons, the default browser). At run time `Get-TweakCatalog` leaves out, without a message, an entry with a value whose path has another hive, a `Policies` segment, a `/`, a wildcard (`*`, `?`, `[`, `]`), a `.` or `..` segment or a control character, or whose type, operation, `bit` or `value` is not allowed or out of range (and an entry whose id, title or rule fields are not valid). "Nothing the run already manages" is **not** checked at run time: `tests\Config.Tests.ps1` checks it for the shipped entries only, and proves that all nine survive `Get-TweakCatalog`. A new entry that writes a managed value fails that test; it is not dropped;
  - `type` is `String` (REG_SZ) or `DWord` (REG_DWORD), nothing else; `op` is `set`, or `clearBit` for the accessibility `Flags`. An empty `name` is the key's default value and is allowed only for a String `set` (the classic right-click menu writes a real empty REG_SZ there);
  - `bit` is the **mask** to clear, not a bit index: `4` means 0x4, so `510` becomes `506`. `clearBit` reads the current REG_SZ number, clears the mask and writes it back as REG_SZ; when the value is missing or is not a number it writes `value`, the fresh-install number.
- **`toolbox.language`**: `"en"` or `"he"`, the language the window opens in (anything else means `en`); the EN | HE switch changes it for one run only.
- **`timeoutsMinutes.restorePoint`**: how long the restore point's child process may take (10).
- **Hebrew text:** all Hebrew lives in the `he` values of `config.json` and in `src\Toolbox\Strings.ps1` (the toolbox's own texts, including the Hebrew step names); nothing else in `src` may contain a non-ASCII character.

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
- Never run setup steps, the launcher or `ScreenConnect.ClientSetup.exe` on the dev PC (the installer would enrol it in the ScreenConnect list). Tests mock everything, and none reads the real installer.
- The console is English and ASCII; **the toolbox window is the one exception**. `src\Toolbox\Strings.ps1` is the only non-ASCII `src` file (`tests\Encoding.Tests.ps1` enforces it), and the window uses hex colours. No test opens a window or stops WPF.

**Preview the toolbox:** `tools\Preview-Toolbox.ps1` draws the window offscreen into eight PNG files (nothing is shown, no window is opened), in `dist\toolbox-preview` unless `-OutDir` names another folder:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Preview-Toolbox.ps1
```

It prints each file's path: `toolbox-en.png` and `toolbox-he.png` (the default profile on a sample Dell laptop, with the yellow banner), `toolbox-en-business-desktop.png` (the Business profile as a desktop: the ScreenConnect reminder, NumLock and classic Outlook), `toolbox-en-blocked.png` (Administrator protection: the red banner and the disabled Start), `toolbox-en-drivers.png` and `toolbox-he-drivers.png` (the default profile with Updates on Drivers only: the tile and the step `Windows Update (drivers only)` in English and in Hebrew), and `toolbox-en-zoom.png` and `toolbox-he-zoom.png` (the default profile with the Zoom switch on: the switch and the step `Zoom` after `7-Zip`, in English and in Hebrew). Run it after any change to `src\Toolbox\`, to a profile or a tweak title in `config.json`, and look at the pictures before a VM run; the look was approved on these pictures (Q29).

**Build the bundle by hand:**

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Bundle.ps1 -Version 2026.10.19.1
```

This writes `dist\setup.ps1` and `dist\config.json`. Sign with `tools\Sign-File.ps1 -Path dist\setup.ps1`, build the launcher with `tools\Build-Launcher.ps1 -BaseUrl <releases/latest/download URL>`. A new file under `src\` must also be added to `$BundleOrder` in `tools\Build-Bundle.ps1`; the build fails when the two disagree.

**Layout:**

| Path | Holds |
|---|---|
| `src\` | The code: Common, State, Detect, Engine, Steps, Report, UI, Toolbox, Entry |
| `tests\` | Pester tests and fixtures |
| `config\config.json` | All data: URLs, IDs, signers, lists, caps, timeouts |
| `launcher\` | The launcher template (polyglot cmd + PowerShell) |
| `tools\` | Bundle, launcher, signing and publish tooling; `Preview-Toolbox.ps1` renders the toolbox; `spikes\` has the research scripts |
| `keys\` | `public-key.xml` and `launcher.sha256` |
| `docs\` | Spec, plan, spikes, testing checklist |
| `dist\` | Build output (ignored by Git) |
