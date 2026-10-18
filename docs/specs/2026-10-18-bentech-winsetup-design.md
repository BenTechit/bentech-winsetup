# BenTech Windows Setup Tool — Design

**Date:** 2026-10-18 · **Owner:** Ben Goldenberg (BENTECH IT) · **Status:** APPROVED by Ben, 18/10/2026. Implementation plan: `docs/superpowers/plans/2026-10-18-bentech-winsetup.md`
**Working name:** `bentech-winsetup`

---

## 1. Intent: why this exists

Ben's repair and IT shop sets up freshly installed Windows machines (laptops and desktops) for Israeli business and home customers. He often has **5–7 machines running at the same time**. Today each one needs him to sit with it: clicking installers, running Windows Update over and over, finding the vendor's driver tool, rebooting and checking back.

A friend's tool (`winAutomationFull.exe`, from 1007.co.il/1) proved the idea: a PowerShell script packed into an .exe. It falls short of Ben's goal because it:
- waits on a menu for typed input
- **does not continue after a reboot**: when Windows Update finds updates, the machine reboots and the app installs never run
- runs Windows Update only once
- has no laptop or vendor awareness

**Goal in one sentence:** Ben double-clicks one file, clicks "Yes" on UAC, walks away, and later finds the machine fully set up with a clear green or red result on screen.

## 2. Goals

1. **Zero touch after the UAC click.** No prompts, menus, or "Next" buttons anywhere in the flow, including after reboots.
2. **Survives any number of reboots** and resumes on its own.
3. **Detects laptop vs desktop and the brand automatically.** A 10-second start screen lets Ben override the mode and toggle optional apps; if nobody touches it, it proceeds.
4. **Always up to date.** Every run downloads the newest version of the setup logic and of every installer. Ben updates the tool by publishing to GitHub, never by re-copying an .exe.
5. **Windows Update runs until nothing is left** (bounded).
6. **Laptops:** drivers and BIOS are installed silently through the vendor's business command-line tool where one exists, and the vendor's consumer app is installed for the customer.
7. **The result is obvious from across the room:** a full-screen green or red final screen plus a report file.

## 3. Non-goals

- Driver installation on desktops beyond what Windows Update provides. Ben handles desktop drivers by hand.
- Notifications to phone, email, WhatsApp or Telegram. Ben chose screen-only for v1; see §18 for later phases.
- An offline installer cache. Ben's internet is strong, and freshness matters more than bandwidth.
- Building the tool into the Windows install media (autounattend.xml). This could come later; see §18.
- Any GUI framework. A console UI is enough.
- Activating Windows or Office. Licensing is the customer's business; the report only shows activation status.

## 4. Anti-goals: failure even if it "works"

- **The tool stops and waits** for a click, a Store sign-in, a "Let's finish setting up your device" screen, or a BitLocker recovery prompt on a machine Ben walked away from.
- **It bricks a laptop** by flashing a BIOS on battery.
- **It can be hijacked:** someone who gets into the GitHub account, or into the network path, can run code as admin on customer machines.
- **It silently claims success.** Every failure must reach the final screen.
- **It loops forever** (Windows Update or a vendor tool that reboots endlessly).
- **It leaves junk behind:** a resume task, an admin auto-login, an unattended-access remote tool, or installers in TEMP.

## 5. Constraints

- **Target OS:** **Windows 11 25H2 / 26H2, Home or Pro**, is the main target.
  - 24H2 Home/Pro **stopped receiving updates on 13/10/2026** and is being moved to 25H2 automatically.
  - **Windows 10 22H2 is best effort:** consumer ESU ended on 13/10/2026, so the final screen and report add a yellow note, *"Windows 10: no security updates"* (§8.6).
  - **x64 is required; ARM64 (Snapdragon) is best effort.** Chrome, Office, Dell Command Update and HP Image Assistant have native ARM64 builds. 7-Zip has a native ARM64 build. AnyDesk runs x86 under emulation. Lenovo System Update on ARM64 is unknown.
  - **Recommendation to Ben, outside the tool:** keep the install USB on the newest ISO (25H2/26H2).
- **Machine state when run:** a fresh install with a local account and **no password**, so Windows logs in by itself after a reboot. The machine is not domain-joined and no Microsoft account is signed in.
- **Network must already work** (Ethernet or Wi-Fi set up during OOBE). If there is no internet, the tool shows a clear message and retries; it can't do anything else.
- **Runs as the logged-in local admin, elevated** (one UAC click), not as SYSTEM. Per-user settings such as desktop icons, keyboards and the default browser must apply to *that* user.
- **No secrets in the tool or the repo.** No passwords, no tokens, no AnyDesk unattended password.
- **Customer privacy (Amendment 13):** the tool collects nothing off-machine. The report stays on the machine.
- **The console UI is in English**, because Hebrew renders poorly in conhost. *(builder's call, already agreed in conversation)*

## 6. Decisions Ben made

| # | Topic | Decision |
|---|---|---|
| Q1 | Laptop/desktop selection | **One file, auto-detect, with a 10-second override screen** (L = laptop, D = desktop) |
| Q2 | Laptop drivers | **Silent vendor CLI updater + the consumer app** (details in §9) |
| Q3 | Login after reboot | **Local user, no password**, so no auto-login handling is needed |
| Q4 + Q17 | Optional apps | **7-Zip** and **Office 365** are optional. **Chrome + AnyDesk are always installed.** WinRAR was dropped (Q17: 40-day trial, business customers would need a licence, no Hebrew build). VLC isn't included. |
| Q5 + Q16 | How optional apps are chosen | **Toggled on the 10-second start screen**, with defaults from config. **Z** = 7-Zip on/off. **O cycles Office: OFF → BUSINESS → HOME** (Q16). |
| Q6 | Source of installers | **Always download the latest at run time.** No offline cache. |
| Q7 | Completion signal | **Screen only:** a big green or red final screen plus a report file |
| Q8 | AnyDesk | **Full install, starts with Windows, the customer must accept every connection.** No unattended password. |
| Q9 | Script hosting | **A public GitHub repo** of Ben's |
| Q10 | Extra tweaks | **Remove bloatware, Israel time zone + Hebrew keyboard, rename the PC.** (Showing file extensions was *not* chosen.) |
| Q11 | Final power settings | **On charger: never sleep, screen off after 15 min. On battery: Windows defaults.** Fast Startup off. |
| Q12 | Office edition | **Microsoft 365 Apps for business (O365BusinessRetail), Hebrew + English**, Current Channel, x64. The customer signs in later. |
| Q13 | BitLocker / device encryption | **Turn it off:** decrypt C: and stop Windows from turning device encryption back on automatically |
| Q14 | Brand-name desktops | **Desktop mode on Dell/Lenovo/HP also runs the silent vendor driver+BIOS tool** (no consumer app). Custom-built PCs get Windows Update drivers only. |
| Q15 | Account after handover | **The customer keeps the account the tool ran on.** Per-user settings only need to go to that account. No default-profile work. |
| Q16 | Office for home customers | **Office toggle cycles OFF / BUSINESS (`O365BusinessRetail`) / HOME (`O365HomePremRetail`)**, both Hebrew + English. Personal/Family can't activate the Business product. |
| Q17 | WinRAR | **Replaced by 7-Zip entirely** |
| Q18 | What vendor tools install | **Everything the vendor tool recommends for the model:** drivers, BIOS, firmware **and** the brand's utilities (hotkeys, audio control, power management) |

## 7. Architecture

### 7.1 Components

```
┌──────────────────────────┐  HTTPS   ┌──────────────────────────────┐
│ BenTechSetup.cmd         │ ───────► │ GitHub Releases (latest)     │
│ (launcher, tiny, stable) │          │  setup.ps1 + setup.ps1.sig   │
│ - self-elevate (1 UAC)   │ ◄─────── │  config.json + .sig          │
│ - download + VERIFY sig  │          └──────────────────────────────┘
│ - run setup.ps1          │
└────────────┬─────────────┘
             ▼
┌─────────────────────────────────────────────────────────────────┐
│ C:\BenTech\Setup\  (working dir on the target machine)          │
│   setup.ps1, config.json   ← verified copies, PINNED for the run │
│   state.json               ← step progress, survives reboots     │
│   Logs\                    ← our log + vendor tool logs          │
│   Downloads\               ← installers (deleted at the end)     │
│ Scheduled Task "BenTechSetup-Resume" (at logon, highest, visible)│
└─────────────────────────────────────────────────────────────────┘
```

1. **Launcher (`BenTechSetup.cmd`).** Small and rarely changed. It:
   - re-launches itself elevated if it isn't already (one UAC prompt)
   - forces TLS 1.2+
   - downloads `setup.ps1`, `config.json` and their detached signatures from the **latest GitHub Release**
   - **verifies the signatures against a public key embedded in the launcher**, and refuses to run anything unsigned or tampered with
   - stores the files in `C:\BenTech\Setup\` and runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\BenTech\Setup\setup.ps1`

   **Decision (builder's call, based on research): the launcher is a single `BenTechSetup.cmd` file, not an .exe.**
   - PS2EXE output is regularly flagged by antivirus (SentinelOne quarantine, CrowdStrike 70/100, Defender `Wacatac`; PS2EXE issues #153 and #103).
   - With a `.cmd` that re-launches itself elevated through PowerShell, the UAC prompt shows **Microsoft Windows as the verified publisher** instead of "Unknown publisher".
   - Nothing is compiled, so there's nothing for antivirus to mistake for malware.
   - It is still a double-click.
   - The `.cmd` holds the RSA public key and the verification code, and stays **ASCII-only**.
   - A signed `.exe` can come later (§18).
2. **Setup script (`setup.ps1`).** All the logic, written for Windows PowerShell 5.1 (inbox, no dependencies). The source may be split into modules in the repo, but it ships as **one bundled file** so there is one signature to check. *(builder's call)*
3. **Config (`config.json`).** The data Ben may want to change without touching code: default toggles (7-Zip on/off, Office OFF/BUSINESS/HOME), both Office XMLs, the bloatware list, the vendor tool matrix (download sources, expected signer names), the PC-name format, timeouts, and the Windows Update round cap. It is signed exactly like the script.
4. **Publish tooling (in the repo, runs on Ben's PC).** `tools/New-SigningKey.ps1` (one time) and `tools/Publish.ps1` (bundle → sign → create GitHub Release with `gh`). **The private key never leaves Ben's PC and is never committed.** Pushing to `main` does **not** reach customers; only a published Release does. Rollback = publish a Release of the previous version.

### 7.2 Why Releases and signing *(builder's calls, explained)*
- **Releases, not raw `main`:** work-in-progress commits must never reach a customer machine.
- **A detached signature checked by the launcher:** a compromised GitHub account alone is not enough to run code on customer machines. The attacker would also need Ben's private key.
  - **Scheme:** RSA-3072, PKCS#1 v1.5, SHA-256, detached `.sig` files.
  - **Signing** happens offline on Ben's PC: `openssl` (ships with Git for Windows) or .NET.
  - **Verification** runs in Windows PowerShell 5.1 with nothing extra: `RSA.VerifyData(bytes, sig, SHA256, Pkcs1)`, with the public key embedded as `<RSAKeyValue>` XML. (PEM import doesn't exist in .NET Framework.)
- **Byte-exact rules:**
  - Verify the **raw downloaded bytes** (`WebClient.DownloadData`), never decoded text.
  - Write them to the admin-only folder, then run **that same file**.
  - `.ps1` files are saved as **UTF-8 with BOM** (PS 5.1 reads BOM-less files as ANSI).
  - They are marked `binary` in `.gitattributes` so Git never rewrites line endings.
- **Working-folder ACL:** `C:\BenTech\Setup` is set to Administrators + SYSTEM only. A folder in the root of C: is otherwise writable by normal users, and the elevated resume task runs code from it.
- **Pinning per machine:** once a run has started, resumes after reboots use the already verified local copy. A new release published mid-run must not mix versions on one machine.

### 7.3 Version identity
Every release carries a version (e.g. `2026.10.18.1`) in the script header. It is shown on the start screen, in the final report and in the log.

## 8. Runtime flow

### 8.0 Detection rules *(from research)*
- **Laptop** if `Win32_SystemEnclosure.ChassisTypes` contains any of **8, 9, 10, 11, 14, 30, 31, 32**. Otherwise **laptop** if `Win32_ComputerSystem.PCSystemTypeEx` is **2 (Mobile)** or **8 (Slate)**.
- `Win32_Battery` is only a **tie-breaker**, and batteries that look like a UPS are ignored, because desktops with a USB UPS report a battery.
- Chassis 12 and 21 (docking/peripheral) are weak hints only.
- **Virtual machine** (Hyper-V "Virtual Machine", VMware, VirtualBox, QEMU): Desktop mode, vendor steps skipped, logged as VM. The 10-second override screen exists because detection is never 100%.
- **Architecture:** `(Get-CimInstance Win32_Processor).Architecture -eq 12` means ARM64. `$env:PROCESSOR_ARCHITECTURE` can report AMD64 inside an emulated process. On ARM64, steps without a usable installer are Skipped with a reason.

### 8.1 First run: start screen (10-second countdown)

Detection runs first, and its results are shown:

```
 ================================================================
   BENTECH WINDOWS SETUP                    v2026.10.18.1
 ================================================================
   Machine  : Dell Inc.  Latitude 5440        SN: 7HX2K93
   Detected : LAPTOP   (chassis Notebook, battery present)
   Windows  : Windows 11 Pro 24H2 (26100.xxxx)   x64
   Power    : ON CHARGER                  Internet: OK
   New name : DELL-7HX2K93

   MODE   [L] Laptop  <==        [D] Desktop
   APPS   Chrome, AnyDesk          always
          [Z] 7-Zip                ON
          [O] Office 365 (HE+EN)   BUSINESS   (OFF/BUSINESS/HOME)

   Starting in 10s ...  [Enter] start now   [Esc] cancel
   (any toggle resets the countdown to 10s)
 ================================================================
```

- **On battery:** the screen shows a yellow line, *"ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery."* It does not block.
- **Esc** = cancel, leaving no changes and no resume task.
- Choices are written to `state.json` **before** any change is made.

### 8.2 Progress screen (every run and every resume)
A live checklist of all planned steps with a status for each (`✓ done`, `► running`, `• pending`, `✗ failed`, `– skipped`), the current step's elapsed time, the reboot count so far and the total elapsed time. On a resume after a reboot the same screen redraws immediately with the steps already done marked.

### 8.3 Step order

Each step is **idempotent**: it checks first, then acts, then verifies. Each records `pending/running/done/failed/skipped`, an attempt count, a timestamp and a message in `state.json`. If a step was `running` when the machine rebooted unexpectedly, it is re-run (with an attempt cap).

| # | Step | Runs on | Reboot? |
|---|---|---|---|
| 0 | **Prepare:** create the working dirs (admin-only ACL); register the resume task (§8.5); set **no sleep and no screen-off on AC and DC** for the duration; turn off Fast Startup; **suppress "Let's finish setting up your device"** (`HKCU\...\UserProfileEngagement\ScoobeSystemSettingEnabled=0`) and other first-logon nags that would block the desktop after reboots; make sure Windows doesn't reboot on its own mid-step | all | |
| 1 | **BitLocker off (Q13):** if C: is encrypted or "waiting for activation", start decryption. Set the value that prevents automatic device encryption (`HKLM\SYSTEM\CurrentControlSet\Control\BitLocker\PreventDeviceEncryption=1`, _builder to verify on 25H2/26H2_). Decryption runs in the background; step 12 waits for it before any BIOS update. | all | |
| 2 | **Region:** time zone *Israel Standard Time* + time sync now; add the **Hebrew keyboard** next to English (merge with the existing language list, never replace it). The region/format setting is left as installed. *(builder's call)* | all | |
| 3 | **Desktop icons:** This PC + the user's folder (same as the friend's tool) | all | |
| 4 | **Remove bloatware:** conservative list from config (§10), for the current user **and** the provisioned copy | all | |
| 5 | **Rename the PC** (§11). Takes effect at the next reboot. | all | (pending) |
| 6 | **winget readiness** (§9.1): check for winget; if missing, register App Installer and retry with a delay; then install the App Installer bundle from `aka.ms/getwinget` (signature checked); on error `0x8a15000f`, run `winget source reset --force`. Always run as the logged-on user, elevated (Microsoft doesn't support winget as SYSTEM). If winget never becomes usable, the steps that need it are marked Failed("winget unavailable"); direct-download steps still run. | all | |
| 7 | **Google Chrome:** the enterprise MSI permalink, which is always the newest (x64 or ARM64): `msiexec /i … /qn /norestart`. 0/3010/1641 = OK; 1618 = retry. | all | |
| 8 | **AnyDesk (Q8):** `download.anydesk.com/AnyDesk.exe` (always the newest) → `--install "C:\Program Files (x86)\AnyDesk" --start-with-win --create-shortcuts --create-desktop-icon --silent --update-auto`. **No password and no unattended access.** Read the ID by polling `AnyDesk.exe --get-id` until it returns 9–10 digits (fallback: parse `%ProgramData%\AnyDesk\service.conf`). | all | |
| 9 | **7-Zip** (if toggled on; Q17): winget `7zip.7zip`, which picks x64 or ARM64 itself. 7-Zip's own installers aren't Authenticode-signed, so winget's hash check against the manifest is the integrity check. No direct-download fallback. | all | |
| 10 | **Office 365** (if toggled on; Q12, Q16): Office Deployment Tool via winget `Microsoft.OfficeDeploymentTool` (fallback: scrape the Microsoft download page, id=49117) → `/quiet /extract:` → `setup.exe /configure office.xml`. Two XMLs in config, picked by the toggle: **BUSINESS** = `O365BusinessRetail`, **HOME** = `O365HomePremRetail`. Both: 64-bit, Current Channel, **he-il first** (Hebrew interface) **+ en-us**, exclude Groove and Lync, `RemoveMSI`, `FORCEAPPSHUTDOWN`, `Display Level="None" AcceptEULA="TRUE"`. Timeout 60 min. | all | |
| 11 | **Chrome as the default browser:** policy XML (§12); applies at the next sign-in, verified in Finalize | all | |
| 12 | **Vendor silent updater, pass 1** (§9.2): install the business tool → apply **everything it recommends for the model** (Q18: drivers, BIOS/firmware and the brand's utilities). Waits for step 1's decryption. BIOS only when on AC. | laptops + Dell/Lenovo/HP desktops | usually |
| 13 | **Windows Update loop** (§13) | all | yes |
| 14 | **Vendor silent updater, pass 2:** catches what only became applicable after Windows updates. One pass. | as step 12 | maybe |
| 15 | **Vendor consumer app** (§9.2). Runs **after** Windows Update because some need a driver that arrives through it first (MyASUS needs the "ASUS System Control Interface" driver). | laptops | |
| 16 | **Clean up the vendor business tool** *(builder's call)*: on laptops, **if the consumer app installed OK**, uninstall the business tool (DCU / System Update / HPIA). Dell documents a conflict when DCU and SupportAssist are both installed (KB 000207301). If the consumer app was Skipped or Failed, the business tool stays, so the machine keeps an updater. Branded desktops always keep it. | laptops | |
| 17 | **Finalize:** apply the final power settings (Q11); remove the resume task, the no-auto-reboot settings and the default-browser policy value; delete `Downloads\` and the setup script; keep `Logs\`; write the report; show the final screen (incl. the default-browser check, §12) | all | |

**Order rationale (builder's call):**
- Configuration and apps run first, so a long Windows Update loop doesn't delay what Ben can see working.
- Vendor drivers run before Windows Update, so vendor drivers win over generic ones.
- Consumer apps run last, because some depend on drivers that arrive through Windows Update.
- Everything runs **sequentially** for reliability. No parallel jobs like the friend's Ninite/Office pair.

### 8.4 Reboots
- **Only reboot when needed.** Check the real pending-reboot indicators (CBS RebootPending, WU RebootRequired, PendingFileRenameOperations, pending computer rename, and the vendor tool's exit code).
- **Before rebooting:** save state, write to the log, show a 15-second on-screen countdown, then `Restart-Computer -Force`.
- **Guard:** a maximum total reboot count (config, default 12). Once it is hit, stop rebooting, finish whatever doesn't need a reboot, and report red.

### 8.5 Resume mechanism
- A **Scheduled Task with a logon trigger for the setup user**, configured as:
  - `LogonType Interactive` ("run only when user is logged on"). This is what makes the console **visible**; S4U would run hidden.
  - `RunLevel Highest`.
  - Settings: `AllowStartIfOnBatteries`, `DontStopIfGoingOnBatteries` (**the default would silently stall a laptop on battery**), `ExecutionTimeLimit 0` (the default is 3 days), `MultipleInstances IgnoreNew`, and **`Priority 5`** (the default 7 is background priority and slows installers).
- It runs the **pinned local** `setup.ps1`. A lock file prevents two copies running at once.
- **Not RunOnce:** it's deleted before it runs, its order is indeterminate, and its commands are limited to 260 characters.
- The task is deleted in Finalize, and also when the user cancels.

### 8.6 Final screen
The whole console turns one of three colours *(builder's call)*:

| Colour | Banner | When |
|---|---|---|
| **GREEN** | `SETUP COMPLETE` | every step Done, no notes |
| **YELLOW** | `COMPLETE - CHECK NOTES` | no failures, but at least one **note**: a step Skipped (unsupported model, Store sign-in needed, ARM64); Chrome not the default (press **B**); Windows not activated; BitLocker decryption still running; Windows 10 (no security updates) |
| **RED** | `COMPLETED WITH ERRORS` | any step **Failed**; any Windows update hidden after repeated failures; any cap hit (reboots or update rounds); drive still encrypted and not decrypting |

The screen also shows:
- the machine, new name and serial
- **the AnyDesk ID in large text**
- the total time and the reboot count
- each failed or skipped step with a one-line reason
- the report path (**R** opens it)

It stays on screen until a key is pressed. There is no auto-close.

### 8.8 Running it again on the same machine *(builder's call)*
- **A run is already in progress** (the lock file is held by a live process): the launcher shows *"Setup is already running on this machine"* and exits.
- **A previous run exists** (unfinished, or finished green/yellow/red): the start screen shows *"Previous run: <date> - <result>"* and the countdown proceeds as normal. The new run:
  - downloads the **newest release**, which is how a fixed release reaches a machine that went red
  - archives the old `state.json` into `Logs\`
  - **resets all counters** (reboot cap, attempt caps, per-update failure counts). Updates the previous run hid are **un-hidden** and get one more try.
  - runs every step again. Every step checks before it acts, so steps that were already done finish in seconds.
- **Unreadable `state.json`:** archived as `state.corrupt-<time>.json` and a new run starts. This is safe for the same reason.
- **Fresh-install guard:** v1 is for fresh installs only. If the machine looks used, the start screen shows a yellow line, *"This doesn't look like a fresh install: press Enter to run anyway"*, and **does not auto-start**. "Used" means Windows was installed more than 14 days ago, or the user's Desktop/Documents/Downloads hold more than 1 GB. (A maintenance mode for existing machines is in §18.)

### 8.7 Report: `C:\BenTech\Setup\Logs\Setup-Report.txt` *(builder's call: the customer keeps this account (Q15), so the desktop stays clean; **R** on the final screen opens the report)*
- tool version
- start/end time and duration (DD/MM/YYYY HH:mm)
- manufacturer, model, serial, old and new PC name, chassis/mode, Windows edition, version and build, architecture
- **Windows activation status**
- **BitLocker / device encryption status** (should read "Off" after Q13; "decrypting" is a yellow note, still encrypted and not decrypting is red, as in §8.6)
- AnyDesk ID
- installed apps with versions
- vendor tool results: drivers/BIOS applied (from the vendor's report)
- Windows Update: rounds, count installed, any failures (KB numbers)
- each step's result and timing

No customer personal data.

## 9. Install sources and the vendor matrix

### 9.1 Where installers come from *(builder's call, based on research)*

**What "always up to date" means here:** the **apps, drivers and updates** a customer ends up with are always the newest.
- **Apps** come from vendor permalinks that always serve the latest version: the Chrome MSI and AnyDesk.
- **Updater tools** (Dell Command Update, HP Image Assistant, Lenovo System Update, the Office Deployment Tool) come through **winget**. winget can trail the vendor by days or weeks (today DCU is 5.7.0 vs 5.7.2, HPIA 5.3.6 vs 5.3.7). That's acceptable, because these tools download the vendor's **live** driver catalog every time they run.
- **Every source has a fallback**, and the **expected Authenticode signer** for each is kept in `config.json`.
- **Signature policy** *(builder's call)*:
  - **Direct downloads** (Chrome, AnyDesk, the App Installer bundle and all fallbacks) have their Authenticode signature checked **before** they run: status must be Valid **and** the signer must match.
  - **winget installs** rely on winget's own SHA-256 check against the reviewed `winget-pkgs` manifest. After install, the tool's main executable (`dcu-cli.exe`, `tvsu.exe`, `HPImageAssistant.exe`, the ODT `setup.exe`) is signature-checked against the expected signer **before we run it**.
  - **Store apps** are signed and delivered by the Microsoft Store; no extra check.

**winget usage:**
- Always called as `winget install --id <ID> -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity`.
- Store apps use `--source msstore`.
- Exit codes:
  - `0` and `0x8A150061` (already installed) = Done
  - `0x8A150109` / `0x8A15010B` = Done + reboot needed
  - `0x8A150014` / `0x8A150010` (no package / no installer for this system) = Skipped
  - anything else = Failed, with the hex code in the report

### 9.2 Vendor matrix

**Manufacturer matching:** case-insensitive substring match on `Win32_ComputerSystem.Manufacturer`:

| Pattern | Brand |
|---|---|
| `*Dell*` | DELL |
| `*Lenovo*` | LENOVO |
| exact `HP`, or `*Hewlett*` | HP |
| `*ASUS*` | ASUS |
| `*Acer*` | ACER |
| `*Micro-Star*` | MSI |
| `Microsoft Corporation` + a Model starting with `Surface` | SURFACE |
| `Microsoft Corporation` + Model `Virtual Machine` | VM |
| `*Samsung*` | SAMSUNG |
| junk (`To be filled by O.E.M.`, `System manufacturer`, `Default string`) | OTHER |

The Lenovo friendly model comes from `Win32_ComputerSystemProduct.Version`.

| Brand | Silent driver + BIOS tool (steps 12 & 14) | Result mapping | Consumer app (step 15, laptops only) |
|---|---|---|---|
| **DELL** | **Dell Command Update Universal.** Installed with winget `Dell.CommandUpdate.Universal` (it pulls its .NET dependency); fallback is Dell's direct package (driver ID in config). Run: `dcu-cli /configure -autoSuspendBitLocker=enable`, then `dcu-cli /applyUpdates -silent -reboot=disable -outputLog=<Logs>`. | `0` Done · `1`/`5` Done + reboot · `500` Done (nothing to do) · **`3`/`7` Skipped (model not supported, e.g. some consumer models)** · `3000–3005` start the Dell service, retry once · anything else Failed | **SupportAssist:** winget msstore `XPDCCXDN26VNBT` _(⏳ spike #3; DCU removed afterwards, step 16)_ |
| **LENOVO** | **Lenovo System Update.** winget `Lenovo.SystemUpdate` (`/VERYSILENT /NORESTART`). Parameters go in `HKLM\Software\Policies\Lenovo\System Update\UserSettings\General\AdminCommandLine` = `/CM -search A -action INSTALL -includerebootpackages 1,3,5 -noreboot -noicon -nolicense -exporttowmi` (all package types, Q18), then run `tvsu.exe /CM`. **Type 5 (BIOS/firmware) forces its own reboot after a countdown, and Lenovo can't suppress it.** That's acceptable: state is saved before the tool runs, and the tool resumes after the reboot. **Type 4 (forces a *shutdown*) is excluded**, because a powered-off machine would stall the run. tvsu has no documented exit codes, so results are read from the WMI export and the log. **If System Update doesn't support IdeaPad/Yoga/Legion (spike #4), fall back to the open-source LSUClient module**, which supports consumer lines. | Done / Done + reboot / Skipped (unsupported) / Failed | **Lenovo Vantage:** winget msstore `9WZDNCRFJ4MV` _(⏳ spike #3)_ |
| **HP** | **HP Image Assistant (HPIA).** winget `HP.ImageAssistant` (fallback: scrape `ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html`) → extract with `/s /e /f <dir>`. Run: `HPImageAssistant.exe /Operation:Analyze /Category:All /Selection:All /Action:Install /Silent /ReportFolder:<Logs> /SoftpaqDownloadFolder:<Downloads> /AutoCleanup`. **Business models only (Elite/Pro/ZBook).** | `0`/`256`/`257` Done · `3010` Done + reboot · `3011` Done with a warning (needs manual install) · `3020` Failed (partial) · **`4096` Skipped (consumer model: Pavilion/ENVY/Victus/OMEN/Spectre)**, so Windows Update covers the drivers · `4098` retry · anything else Failed | **HP Support Assistant:** winget `HP.SupportAssistant` (MSIX, pulls VCLibs) |
| **ASUS** | none exists, so Windows Update drivers | — | **MyASUS:** winget msstore `9N7R5S6B0ZZH` _(⏳ spike #3)_ |
| **ACER** | none, so Windows Update | — | Acer Care Center S, msstore `9P8BB54NQNQ4` *(builder's call, in config)* |
| **MSI** | none, so Windows Update | — | MSI Center, msstore `9NVMNJCR03XV` *(builder's call, in config)* |
| **SURFACE** | none needed: drivers and firmware come through Windows Update | — | Surface app, msstore `9WZDNCRFJB8P` *(builder's call, in config)* |
| **SAMSUNG / OTHER** | none, so Windows Update | — | none |
| **VM** | skip all vendor steps | — | none |

**Desktop mode (Q14):** Dell/Lenovo/HP desktops get steps 12 and 14 but **no consumer app**. All other desktops get Windows Update drivers only.

**Rules for every vendor step:**
- An unsupported model = **Skipped (yellow)**, never Failed. Windows Update still covers its drivers.
- **BIOS/firmware only when on AC power.** The step re-checks power right before it runs. If the drive is still encrypted (decryption hasn't finished), BitLocker is suspended for one reboot as a backstop.
- The vendor tool's own logs and reports are copied into `Logs\`.
- Every vendor step has a timeout (config, default 60 min).
- The step is marked `running` **before** the tool starts, so a forced reboot mid-step (Lenovo type 5) resumes cleanly. Attempt cap: 3.

## 10. Bloatware list (conservative) *(builder's call; lives in config)*

- **Remove:** consumer junk only, such as games (Solitaire, Candy Crush and other king.com titles), promo stubs (TikTok, Spotify, Disney+, etc.), Clipchamp, Microsoft News, Get Help, Tips, Feedback Hub, Family, Power Automate, Dev Home, and the consumer Teams/Chat.
- **Never remove:** Store, App Installer (winget), Photos, Calculator, Notepad, Paint, Snipping Tool, Camera, Media Player, Terminal, Outlook (new), Edge, Copilot, Xbox components (needed by Game Bar and some drivers).
- **OEM trials** (McAfee/Norton): **not in v1.** Ben installs from Microsoft media, so there are none. Uninstalling antivirus trials silently is also unreliable. *(builder's call)*

## 11. PC name *(builder's call)*

- **Format:** `<BRAND>-<SERIAL>`, uppercase, only `A–Z 0–9 -`, **max 15 characters** (NetBIOS). Truncate the serial from the left if needed so the unique tail is kept.
- **Brand codes:** DELL, LEN, HP, ASUS, ACER, MSI, SURF, PC (unknown).
- **Junk serials** (`To be filled by O.E.M.`, `Default string`, `System Serial Number`, `0`, empty, VMs): use `PC-<6 chars of the BIOS UUID>`.
- If the target name is already the current name, skip.

## 12. Default browser (Chrome)

**Research result: Windows 11 Home/Pro has no reliable zero-click method in 2026.**
- **The UserChoice Protection driver (UCPD)** blocks scripts (`powershell`, `cmd`, `reg`, …) from writing the http/https choice.
- **On Home/Pro**, Windows is moving to a new `UserChoiceLatest` hash that includes a machine ID.
- **Chrome can't do it itself:** it always opens Settings.
- **DISM associations** only affect new user profiles.
- **SetUserFTA** is paid and doesn't target Home/Pro.

**Design: try the cleanest method, verify, then fall back to one click at the end.**
1. **Step 11 (unattended):**
   - Write a default-associations XML: `http`, `https`, `.htm`, `.html` → `ChromeHTML`, with `Version="1"` and `Suggested="true"` so it applies once and the customer can change it later.
   - Point the `DefaultAssociationsConfiguration` policy at it. It applies at the next sign-in, and there are reboots anyway.
   - Microsoft documents this policy as "domain-joined only", and Home isn't listed. **Whether it works on Ben's workgroup Pro/Home machines must be tested in a VM before building on it (spike #1, §17).**
   - After it has applied, the policy value is removed so the customer can change browsers later.
2. **Verify** in Finalize. Read `HKCU\...\UrlAssociations\https\UserChoiceLatest\ProgId`, then fall back to the legacy `UserChoice\ProgId`.
3. **Fallback:** if Chrome isn't the default, the final screen shows a yellow line, *"Chrome is not the default browser: press B to open Default Apps, then click 'Set default'"*. **B** opens `ms-settings:defaultapps?registeredAppMachine=Google Chrome` (exact name read from `RegisteredApplications`). This is the only possible human action in the whole flow, and it happens on the final screen, when Ben is at the machine anyway.
4. **Rejected for v1:** turning off UCPD (a registry change + task + reboot, then a PS-SFTA hash write). It removes an anti-hijack protection on a customer machine, Microsoft has changed the driver about 4 times in 13 months, and the PS-SFTA fork is a week old. It could come back as an opt-in experiment.

## 13. Windows Update loop

- **Implementation: the native Windows Update Agent COM API.** Not PSWindowsUpdate:
  - Its last release was 2024-07.
  - Open issues include crashes in `Get-WindowsUpdate` on some driver updates (#71, #76).
  - It needs NuGet/PSGallery set up on a fresh machine, which can prompt.
  - Reference implementation: `rgl/packer-plugin-windows-update`.
- **Opt in to Microsoft Update once:** `ServiceManager.AddService2('7971f918-a847-4430-9279-4a52d1efe18d', 7, '')`. Searches use `ServerSelection=3` plus that `ServiceID`.
- **Search criteria:** `IsInstalled=0 and IsHidden=0 and BrowseOnly=0`, run separately for `Type='Software'` and `Type='Driver'`.
  - **Optional updates (`BrowseOnly=1`) are skipped.**
  - Updates with `CanRequestUserInput` are skipped and logged.
  - EULAs are accepted with `AcceptEula()`.
- **Feature updates** *(builder's call)*: **included** when Windows Update offers them (25H2/26H2 enablement packages: small, one reboot). 24H2 Home/Pro is out of support, and Windows would push them within days anyway. Spike #2 confirms they show up in the search. **On Windows 10, the Windows 11 upgrade offer is always excluded.**
- **Round:** search → download → install → reboot if `Microsoft.Update.SystemInfo.RebootRequired` or CBS `PackagesPending` says so.
- **Stop when:** the search returns nothing, **or** the round cap is hit (config, default 6).
- **Per-update failure counter** (UpdateID → attempts) is saved in `state.json`. After **2 failures** the update is **hidden** (`IsHidden=$true`), reported in red, and the loop moves on. This prevents the classic infinite loops (e.g. KB5034441 on Windows 10, drivers offered again and again).
- **Defender definition updates** don't count as "updates remaining".
- **Per-round timeout:** config, default 90 min.

## 14. Error handling, logging, timeouts

- Every step returns `Done | Skipped(reason) | Failed(reason)`. **A failed step does not stop the run**, except for:
  - **launcher signature verification failure:** red screen, nothing runs
  - **unreadable `state.json`:** handled as in §8.8 (archived, new run). Not a stop.
- **Downloads** (signature policy in §9.1): **never use `Invoke-WebRequest` without `-UseBasicParsing`.** Since the December 2025 security update (CVE-2025-54100, KB5074596), Windows PowerShell 5.1 shows an interactive prompt otherwise, and an unattended run would hang. Prefer `System.Net.WebClient`/`HttpClient` for downloads. 3 retries with backoff. Expected signers live in config (e.g. *Google LLC*, *AnyDesk Software GmbH*, *Dell Inc*, *Lenovo*, *HP Inc.*, *Microsoft Corporation*).
- **Timeouts:** each step has one (config). When it's hit, kill the child process and mark the step Failed("timeout").
- **Logs:** a timestamped log (`Logs\setup.log`) plus a PowerShell transcript for each run segment. Logs never contain passwords or keys (there are none).
- **Errors on screen** are short English sentences; full details go to the log.

## 15. Open questions for Ben (after research and the builder check)

**None left.** Every question from the research and the builder check has been answered (Q13–Q18) or settled as a builder's call (marked in place).

## 16. Risks (and how the design handles them)

| Risk | Mitigation |
|---|---|
| Antivirus or SmartScreen flags the launcher | `.cmd` launcher, so no unsigned exe. A file copied from a USB formatted exFAT/FAT32 carries no "downloaded from the internet" mark. Code-sign later (§18). |
| Smart App Control blocks unsigned code | Clean installs start in Evaluation mode, which doesn't block. The report records its state. |
| Default browser can't be set on newer Windows | Best effort + verify + yellow "set manually" |
| Vendor changes a download URL or CLI | URLs and flags live in signed config; a failure is reported, not silent; quick fix = publish a new release |
| A BIOS flash bricks a laptop | AC-only, vendor tools' own safety checks |
| BitLocker recovery lockout | Device encryption turned off and prevented (Q13); BitLocker suspended as a backstop before any BIOS update |
| Windows Update loops forever | Round cap, per-update failure cap, total reboot cap |
| GitHub is unreachable | The launcher shows a clear red error and retries; nothing runs unverified |
| Store-based consumer apps need a Microsoft account | Spike #3; if so, Skipped("needs Store sign-in") |
| winget not ready on a brand-new install / intermittent `0x8a15000f` | Step 6 readiness routine + `source reset`; direct-download apps don't depend on winget |
| HP consumer laptops aren't supported by HPIA | Exit 4096 → Skipped; Windows Update drivers + HP Support Assistant |
| Lenovo BIOS forces a reboot mid-step | State is saved before the tool runs; resume continues; attempt cap 3 |
| **AnyDesk licensing:** the free version is for personal use, and AnyDesk flags users it considers commercial | Installing AnyDesk on the customer's PC is fine. The licence question is on **Ben's** side (the connecting PC). Outside the tool's scope; noted for Ben. |
| Office edition doesn't match the customer's licence | The toggle picks BUSINESS or HOME (Q16); the wrong one installs but can't activate, so Ben re-runs with the other choice |
| A first-logon nag screen blocks the desktop after a reboot | Suppressed in step 0; the resume task still runs behind any nag |

## 17. Testing *(builder's call on the details)*

**Spikes to run before the matching steps are built (results feed back into this spec):**
1. **Default-browser policy** on a workgroup **Win11 25H2 Pro**, **Win11 25H2 Home** and Win10 22H2 Pro VM. Does `DefaultAssociationsConfiguration` with `Suggested="true"` set Chrome at the next sign-in?
2. **WUA API on a fresh VM:** do the 25H2/26H2 enablement packages show up in a consumer-device search, and with which `BrowseOnly`/category values? Log every update's categories on the first runs.
3. **Store apps without a Microsoft account:** on a fresh local-account VM, can `winget install --source msstore` install Lenovo Vantage (`9WZDNCRFJ4MV`), MyASUS (`9N7R5S6B0ZZH`) and SupportAssist (`XPDCCXDN26VNBT`) with no sign-in? Sources conflict. If it can't, consumer Store apps become Skipped("needs Store sign-in"), and Ben gets told before v1.
4. **Lenovo System Update on consumer models:** test on an IdeaPad/Yoga and on a ThinkPad. If System Update doesn't cover consumer lines, the Lenovo path switches to LSUClient.

- **Pure logic** (manufacturer normalization, laptop detection, the name generator, the step state machine, the pending-reboot decision): Pester tests on Ben's PC.
- **End-to-end:** Hyper-V VMs with a checkpoint for each case (Win11 Pro 24H2/25H2, Win11 Home, Win10 22H2). VM = desktop path. Verify the full reboot loop and the final screen.
- **Real laptops:** at least one Dell, Lenovo, HP and ASUS from the shop before calling v1 done.
- **Security:** a tampered `setup.ps1` (one byte changed) must be refused by the launcher.

## 18. Later phases (not v1)
1. Build the tool into the Windows install USB (autounattend.xml), giving zero clicks with no UAC.
2. Telegram/WhatsApp "machine done" notification.
3. Report posted to BenTech PSA (creates or updates a device record with the AnyDesk ID and serial).
4. Code-signing the launcher (Azure Trusted Signing or an OV cert) to remove the SmartScreen and AV friction.
5. **Maintenance mode** for existing customer machines: updates + drivers only, with no rename, no decryption and no app removal.
