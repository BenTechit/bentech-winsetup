# bentech-winsetup: the BenTech Toolbox (step 1), a visual setup planner with curated tweaks

**Status:** Approved by Ben on 21/10/2026 (Q28), with his answers to Q26 and Q27 (section 10).
**Amends:** the v1 spec, [2026-10-20-progress-visibility-design.md](2026-10-20-progress-visibility-design.md), [2026-10-20-craft-apps-design.md](2026-10-20-craft-apps-design.md) and [2026-10-20-screenconnect-design.md](2026-10-20-screenconnect-design.md). They stay binding wherever this document does not change them.

## 1. Why

Ben plans each PC on a console start screen today: letter keys and ASCII text. He wants a graphical toolbox, like Chris Titus Tech's WinUtil (taken apart on 21/10/2026; see section 9) but built for his own needs:
- clear options with icons;
- saved profiles;
- English or Hebrew;
- a curated set of system tweaks that are safe and actually useful.

Start hands the plan to the existing, proven engine.

This is **step 1** of a larger goal: one window that holds all of Ben's tools. Later tools get their own entry and page in the same window. They are not part of this spec.

## 2. Decisions (Ben, 21/10/2026)

| # | Question | Answer |
|---|---|---|
| Q17 | Where it runs | **On customer PCs**, opened by the same signed `BenTechSetup.cmd` from the USB stick. The launcher does not change. |
| Q18 | If nobody clicks | **It waits for Start.** There is no countdown: Ben plans every PC. |
| Q19 | Technology | **PowerShell + WPF**, inside the signed `setup.ps1`. Nothing is installed. |
| Q20 | Progress during the run | The **console progress and final screens stay.** The toolbox plans and starts the run. |
| Q21 | Language | **English and Hebrew, switchable** in the window. setup.log and the report stay English. |
| Q22, Q24 | Profiles | **Built-in profiles only**, in the signed `config.json`. Changing a profile means a new release. |
| Q23 | Tweaks | **Curated and safe.** The clearly beneficial ones are on by default, and each can be turned off. |
| Q25 | Look | **Dark, like WinUtil.** Ben approves rendered screenshots, in English and Hebrew, before the rest is built. |

## 3. What changes for Ben

1. Ben runs `BenTechSetup.cmd` from the stick exactly as today (UAC, signature check, download).
2. The **BenTech Toolbox** window opens instead of the console start screen.
3. Ben picks a profile and adjusts any option. The right-hand column always shows what will happen.
4. He presses **Start**. The window closes and the run continues exactly as today: console progress, restarts, final screen, cleanup.

Cancel (the Cancel button, the window's X, or Alt+F4) does what Esc does on the console today: nothing is changed, and the leftover folder is removed when there was no earlier run.

## 4. The window

### 4.1 Layout

The window is about 1000x680 device-independent pixels, so it fits a 1024x768 screen on the basic display driver. It is borderless, dark and draggable, with rounded corners.

```
+--------------------------------------------------------------------------------+
| [B] BENTECH TOOLBOX                                        [EN | HE]    [ X ]  |
+-------------+------------------------------------------+-----------------------+
| [icon]      | DELL Latitude 5440   SN 7HX2K93          | WHAT WILL HAPPEN      |
| New PC      | New name: DELL-7HX2K93   On charger      |  1 Prepare            |
| setup       | (yellow banner: used PC / previous run)  |  2 BitLocker          |
|             |                                          |  ...                  |
|             | PROFILE  [Home PC] [Business PC] [Clean] |  18 Finalize          |
|             | TYPE     [Laptop] [Desktop]              |                       |
|             | OFFICE   [Craft] [365 Business] [365 Home] [None]               |
|             | REMOTE   [AnyDesk] [ScreenConnect] [Both]|                       |
|             |   (yellow: unattended access reminder)   |                       |
|             | APPS     Chrome (always)  [x] 7-Zip      |                       |
|             | TWEAKS   [on ] Sticky Keys shortcut off  |                       |
|             |          [off] Show file extensions ...  |                       |
|             | RESTORE  [on ] Restore point at the end  |   [Cancel] [ START ]  |
+-------------+------------------------------------------+-----------------------+
```

**The parts:**
- **Left nav:** one entry, "New PC setup", with an icon. A later tool adds one entry and one page. A nav with one entry is kept on purpose, because it is the toolbox's shape.
- **Machine card:** manufacturer, model, serial, new PC name and power (on charger / on battery). The power state refreshes every few seconds from a DispatcherTimer. A yellow banner shows the console's existing warnings: "This PC already has user files or is older than N days", "Previous run: <date> - <result>", and "On battery: BIOS updates will be skipped".
- **Option rows:** each choice is a tile (a styled RadioButton) with a glyph icon. The options are exactly today's (Type, Office, Remote, 7-Zip) plus the new Tweaks and Restore point (section 6). Choosing ScreenConnect shows the existing Q16 reminder, in yellow.
- **Tweaks:** one row per tweak: a switch, an icon, a title and a one-line explanation, with the full description in a tooltip.
- **What will happen:** the live step list from `Get-StepPlan` with the step titles from the catalog. It updates on every change.
- **Start / Cancel:** Start is a large accent button. It is **not** the default button: Enter or a stray key never starts a run. **Esc does nothing.**

The content scrolls when the window is clamped to a small screen's work area.

### 4.2 Look (Q25)
- **Colours:** dark background `#1E1E1E`, panels `#252526`, text `#F0F0F0`, accent BenTech blue `#2D7DD2`, yellow warnings `#FFC83D` on dark.
  - Colours are always hex values. The colour names DarkYellow and DarkMagenta never appear: `tests\Colors.Tests.ps1` scans every `src` file.
  - All colours and sizes are resources in one resource dictionary inside the XAML.
- **Fonts:** Segoe UI for text.
- **Icons:** glyphs from `Segoe Fluent Icons, Segoe MDL2 Assets`, so they also show on Windows 10.
- **No image files** and no downloaded assets. The "B" logo is drawn in XAML.
- **Approval:** before the window logic is built, `tools\Preview-Toolbox.ps1` renders the window to PNG files, in English and Hebrew, for Ben's approval. Exact colours and spacing are settled on those screenshots.

### 4.3 Language (Q21)
- **Strings:** every visible text comes from one string table with an English and a Hebrew entry for each key (`src\Toolbox\Strings.ps1`). Profile, tweak and option names come from `config.json` in both languages.
- **Switching:** the EN | HE switch walks the elements tagged `Tag="t:<key>"` and sets their text. Hebrew sets `FlowDirection=RightToLeft` on the window. Machine values (model, serial, PC name) and step titles stay left-to-right.
- **Default:** the language the window opens in is `config.json` `toolbox.language` (`"en"`). The switch lasts for that run only.
- **What stays English:** nothing Hebrew reaches setup.log, the console or the report. Choices hold ASCII ids only.
- **Encoding:** `Strings.ps1` is the only `src` file allowed to contain non-ASCII (UTF-8 with BOM, as every `.ps1`).

## 5. Engine changes

### 5.1 The seam
`src\Entry\Main.ps1:295` today calls `Show-StartScreen -Machine -Config -Version -Previous -IsFresh`. It becomes `Get-SetupChoices` with the **same parameters and the same return contract**: a Choices hashtable, or `$null` for Cancel.

- **Inside:** the window's outcome is **Start**, **Cancel** or **Failed**.
  - Start returns the Choices.
  - Cancel returns `$null`.
  - **Only Failed** falls back to the unchanged console `Show-StartScreen`, which keeps its own 30-second auto-start (the emergency path).
  - A failure is never read as a Cancel.
- **Checks before WPF loads.** Any one failing means Failed, which falls back to the console:
  - the thread is STA;
  - the session is interactive and not session 0;
  - `Add-Type -AssemblyName PresentationFramework` succeeds.
- **Never throws:**
  - every click handler is one line calling `Invoke-ToolboxAction`, which catches everything and closes the window as Failed;
  - a dispatcher `UnhandledException` handler marks any exception handled and closes the window as Failed;
  - `ShowDialog()` runs inside try/finally, with `Close()` in the finally;
  - the window's state lives in `$window.Tag`; handlers never rely on outer variables or `GetNewClosure()`.
- **Shutdown:** after the window closes, `Dispatcher.InvokeShutdown()` runs. It sits behind a parameter seam so tests never call it, because it would stop WPF for the rest of the test run. Without it, the main thread keeps a hidden WPF window that other programs' settings broadcasts can hang on, for the hours the run takes.
- **Exactly one return value:** every .NET call's output is assigned to `$null`, so the function returns exactly one value (pinned by a test).
- **Rendering:** `RenderOptions.ProcessRenderMode = SoftwareOnly`. The PC has no GPU driver yet, and one may arrive during the run.
- **Focus:** the window opens Topmost and is activated on ContentRendered, then Topmost is turned off, so it never opens behind the console after UAC.
- **Logging and sleeping:** no `Write-Host` and no `Start-Sleep` in the toolbox. The outcome and the chosen profile are logged to setup.log, in ASCII.
- **Ctrl+C:** pressed in the console behind the window, it takes effect only after the window closes. That is documented, not handled.
- **The resume path never reaches line 295,** so restarts, the progress screen, the final screen and cleanup are unchanged.

### 5.2 Choices and profiles
- **New Choices keys:**
  - `Profile`: an ASCII profile id;
  - `Tweaks`: an array of tweak ids from the signed catalog, with empty values filtered;
  - `RestorePoint`: a bool.

  State stores them in state.json as today, so they survive restarts. A missing key in an older state means no tweaks, no restore point and no profile.
- **New `config.json` sections:**
  ```json
  "defaults": { ..., "profile": "home" },
  "toolbox": { "language": "en" },
  "profiles": [
    { "id": "home", "name": { "en": "Home PC", "he": "מחשב ביתי" },
      "office": "CRAFT", "remote": "ANYDESK", "sevenZip": true, "restorePoint": true },
    { "id": "business", "name": { "en": "Business PC", "he": "מחשב עסקי" },
      "office": "BUSINESS", "remote": "BOTH", "sevenZip": true, "restorePoint": true },
    { "id": "clean", "name": { "en": "Clean Windows", "he": "Windows נקי" },
      "office": "OFF", "remote": "ANYDESK", "sevenZip": false, "restorePoint": true, "tweaks": [] }
  ]
  ```
  - A profile without `tweaks` takes the catalog defaults. A profile may also list `tweaksAdd`, which the three approved profiles do not use.
  - The **Type** (laptop or desktop) is never part of a profile: it is detected, as today.
  - Ben approved these three profiles (Q26). **A profile only fills in the options.** Every option (Type, Office, Remote, 7-Zip, each tweak and the restore point) can still be switched per PC before Start. A changed option never alters the profile itself.
- **Validation (`SetupPlanner.ps1`, pure):**
  - every value is checked against the existing whitelists: `$script:OfficeChoices`, `$script:RemoteChoices` and the tweak catalog;
  - an unknown value falls back to the default;
  - an unknown tweak id is dropped and logged;
  - a profile that names an unknown profile id is skipped.
- **Console fallback:** `New-DefaultChoices` returns the default profile's choices, tweaks included, so the console fallback keeps the tweaks that are on by default.

### 5.3 The `tweaks` step
- **Place in the plan:** a new catalog step, `tweaks` (Title `System tweaks`, Short `Tweaks`), right after `desktop-icons`. It is planned only when `Choices.Tweaks` is not empty.
  - HKCU here is the setup account, which is the customer's account, and the resume task runs as the same user.
  - The step lands before the first restart, so Explorer picks the values up at the next sign-in.
- **What it may write:** registry values only, in the shape of the existing `nags` entries.
  - The types are **REG_DWORD and REG_SZ only**. The operations are `set` and `clearBit` (6.3).
  - The hives are **HKCU, HKLM and `HKU\.DEFAULT`**; the last one is for the sign-in screen, used by NumLock.
  - **No path contains `\Policies\`:** policies make Settings show "managed by your organization", and Finalize removes the policy values the run sets.
  - **No path the run already manages:** power, `HiberbootEnabled`, `WindowsUpdate\AU`, the `nags` values, the desktop-icon values or the default-browser policy.
- **For each value:**
  1. read the original (or "missing");
  2. write through `Set-RegistryDword` (Prepare.ps1:531), or its REG_SZ twin `Set-RegistryString`;
  3. read it back.
- **Logging:** the original, the new value and the read-back go to setup.log, never into step Data.
- **Results:**
  - **A write Windows refuses**, or a read-back that differs, makes that tweak a yellow Note: `<Tweak title> could not be applied`. The other tweaks still run.
  - **All applied:** Done, `<n> tweaks applied`.
  - **Some refused:** Done with the Notes. A tweak is never red: Windows works without it.
- **Activity line:** `Tweaks: <n> applied` (and `<m> refused by Windows`).
- **Rules tied to other choices**, enforced by both the planner and the step:
  - `desktopOnly` tweaks (NumLock) are offered and applied **only when Type is DESKTOP**. On a laptop with a number pad built into the letter keys, NumLock would make the password box type digits. Switching Type to Laptop drops them, also in the console fallback.
  - `office365Only` tweaks (Classic Outlook) are offered and applied only when Office is BUSINESS or HOME.
- **Administrator protection** (6.3, finding 2) is checked by one shared function, `Test-AdminProtection`. It returns On when the process user differs from `Win32_ComputerSystem.UserName`, and Unknown when that name is empty (an RDP session or an early logon).
  - **Toolbox:** when it is On, the window shows a red banner and **Start is disabled**: `Windows Administrator protection is on: setup would not resume after a restart. Turn it off in Windows Security first.` This is because the resume task registers `$env:USERNAME` at logon (Prepare.ps1:302-305), which would be the hidden admin account. That cause is to be proven on a VM.
  - **Tweaks step:** when it is On, the step skips the HKCU values with the yellow Note. Unknown is treated as the same user (as the setup assumes today) and logged at WARN.
- **Undo:** there is no undo button in step 1, because the toolbox is not available after the run. The log holds every original, so a tweak can be reversed by hand. An undo tool can come later.

### 5.4 The restore point
- **When it is created:** `Choices.RestorePoint` (on by default) creates a restore point **at the very end of the run**. It runs inside `Complete-SetupFinalization`, after the setup files are removed (Finalize.ps1:557-561) and before `EndedAt`. The snapshot is then the finished PC, not the setup's temporary policies, power values or resume task.
- **Only once:** `State.RestorePointTried` is set and saved before the attempt, so a repeated finalize phase never tries twice.
- **The frequency value:** before the child starts, **the main setup process** records `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\SystemRestorePointCreationFrequency` (its value, or that it is absent) and sets it to 0; otherwise Windows silently skips a second point within 24 hours. **It restores it after the child ends**, whatever happened, deleting the value when it was absent. The value must never stay at 0 on the customer's PC, and a child killed on timeout could not restore it itself.
- **Bounded:** one child process through `Invoke-PowerShellChild` (Winget.ps1:323), with a new `timeoutsMinutes.restorePoint` (10). The child:
  1. turns on System Protection for the system drive (`Enable-ComputerRestore`);
  2. reads the newest restore point's sequence number;
  3. runs `Checkpoint-Computer -Description 'BenTech setup' -RestorePointType MODIFY_SETTINGS`;
  4. reads the sequence number again. Exit 0 means a new point was confirmed.
- **Results:** any failure, timeout or unconfirmed point is a yellow Note, `Restore point could not be confirmed`. The report says System Protection is now on, because it reserves disk space (a few percent of the drive).

### 5.5 Report and final screen
- **Report lines** (after `ScreenConnect:`):
  ```
  Profile      : Home PC (home)
  Tweaks       : 5 applied: sticky-keys, numlock, ...  (refused: widgets)
  Restore point: created | could not be confirmed | not chosen
  ```
- **Final screen:** unchanged. Notes reach it through the existing verdict.

## 6. Tweaks

### 6.1 Rules: a tweak ships only if it passes all five
1. **Home and Pro.** It works on Windows 11 Home **and** Pro 24H2/25H2/26H2, checked against Microsoft documentation, or reported working on 24H2+ by reliable sources and proven on Ben's first real laptop (docs/testing.md).
2. **Nothing harmful.** No downloads, no deletions, no app removal, no networking (IPv6, DNS, hosts), nothing that weakens security (Defender, Smart App Control, UAC, firewall, updates), no services, and no power, sleep or hibernate settings.
3. **Reversible.** The original value is logged.
4. **No `\Policies\` path,** and no overlap with an existing step.
5. **A clear benefit** to the customer, or to Ben when supporting them.

### 6.2 The catalog
`config.json` `tweaks` holds one entry per tweak:
```json
{ "id": "accessKeys", "default": true,
  "title":       { "en": "...", "he": "..." },
  "description": { "en": "...", "he": "..." },
  "icon": "E765",
  "values": [ { "path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys", "name": "Flags",
                "type": "String", "op": "clearBit", "bit": 4, "value": "506" },
              { "path": "HKCU:\\Control Panel\\Accessibility\\Keyboard Response", "name": "Flags",
                "type": "String", "op": "clearBit", "bit": 4, "value": "122" } ] }
```
Optional fields: `"desktopOnly": true`, `"office365Only": true` (Classic Outlook) and `"minBuild"`.

### 6.3 The tweaks that ship (research of 21/10/2026)
The full fact cards are in [2026-10-21-toolbox-tweak-factcards.md](2026-10-21-toolbox-tweak-factcards.md). Each card gives exact values, the Windows default, when the value takes effect, behaviour on Home and Pro 24H2+ and on Windows 10, the benefit, side effects, sources and confidence.

All values are HKCU unless marked. None uses a `\Policies\` path. All take effect at the next sign-in, which the run's restarts provide.

| Id | Shown as | Default | Values |
|---|---|---|---|
| `accessKeys` | Accessibility shortcuts off: Sticky Keys (Shift x5) and Filter Keys (hold right Shift) | **On** | `Control Panel\Accessibility\StickyKeys` `Flags` and `...\Keyboard Response` `Flags` (REG_SZ): **clear bit 0x4** of the current number (fresh install: "510" becomes "506", "126" becomes "122"). The features stay available in Settings. |
| `numLock` | NumLock on at sign-in | **On for desktops** (`desktopOnly`) | `HKU\.DEFAULT\Control Panel\Keyboard` `InitialKeyboardIndicators` REG_SZ "2147483650" and HKCU `Control Panel\Keyboard` the same value REG_SZ "2". It is off by default on laptops, because those with a built-in number pad would type digits. |
| `startClean` | Start menu: no "recommended" tips and apps, no account nags | **On** | `Explorer\Advanced` `Start_IrisRecommendations` DWORD 0 and `Start_AccountNotifications` DWORD 0 |
| `noAds` | No tips, suggestions and ads in Windows | **On** | `ContentDeliveryManager`: `SubscribedContent-338389Enabled` (tips notifications), `-338393Enabled`, `-353694Enabled`, `-353696Enabled` (suggested content in Settings), `-338387Enabled` and `RotatingLockScreenOverlayEnabled` (lock-screen fun facts), all DWORD 0; plus `Explorer\Advanced` `ShowSyncProviderNotifications` DWORD 0 (OneDrive and Microsoft 365 banners in File Explorer) |
| `classicOutlook` | Keep classic Outlook (hide "Try the new Outlook") | **On**, only with Office BUSINESS or HOME (`office365Only`) | `Software\Microsoft\Office\16.0\Outlook\Options\General` `HideNewOutlookToggle` DWORD 1. This is Microsoft's documented non-policy value. |
| `fileExtensions` | Show file extensions | **Off everywhere** (Q27); a switch Ben can turn on per PC | `Explorer\Advanced` `HideFileExt` DWORD 0. It makes "invoice.pdf.exe" visible, a security benefit. |
| `taskbarLeft` | Taskbar icons on the left | Off | `Explorer\Advanced` `TaskbarAl` DWORD 0 (not blocked by UCPD) |
| `classicMenu` | Classic right-click menu | Off | `Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32`, default value REG_SZ "" (a real empty string). The step creates this key. |
| `endTask` | "End task" in the taskbar's right-click menu | Off | `Explorer\Advanced\TaskbarDeveloperSettings` `TaskbarEndTask` DWORD 1. It closes an app without asking to save. |

**Three findings shape the step:**
1. **UCPD blocks writes from PowerShell.** The Windows driver that protects default apps also refuses writes from `powershell.exe` and `reg.exe` to some taskbar, search and widget values. None of the values above is on its list. A refusal ("Access is denied") becomes the tweak's yellow Note, never a crash. This is also why Widgets and Bing were rejected.
2. **Administrator protection** (KB5120998, off by default on Home and Pro) runs elevated programs as a hidden admin account, so HKCU would be the wrong profile.
   - **Detection:** `Test-AdminProtection` compares the process user (`WindowsIdentity.GetCurrent().Name`) with the signed-in user (`Win32_ComputerSystem.UserName`). If they differ, the step skips the HKCU values with the yellow Note `Per-user tweaks skipped: Windows Administrator protection is on`. The `HKU\.DEFAULT` NumLock value still applies.
   - **The toolbox blocks Start** in that case (5.3), because the resume task would also go to the hidden account.
   - **Existing steps:** the same issue affects the existing `nags`, desktop-icon and default-browser steps. The block covers them too.
3. **HKCU reaches only the account that runs setup,** which is the customer's account (as the existing steps assume). Accounts created later get Windows defaults.

**Value operations:** `"op": "set"` (DWORD or REG_SZ), and `"op": "clearBit"` for the accessibility `Flags`. clearBit reads the REG_SZ number, clears the bit and writes it back as REG_SZ; when the value is missing or not a number, it writes the card's fresh-install value. The original is logged as the string, or as `absent`.

### 6.4 Rejected, and why
Every WinUtil tweak not listed in 6.3 was rejected by rule:
- **Telemetry:** it runs `bcdedit`, adds an icacls deny rule for SYSTEM, deletes Edge policies and changes Defender sample submission (rule 2).
- **Recall:** it also turns off Smart App Control, without saying so (rule 2).
- **Debloat, OneDrive and Copilot removal:** they remove apps; Store apps stay in `config.bloatware` (rule 2).
- **Services to Manual, IPv6/Teredo/IPv4-first, DNS, hosts block, OOSU (downloads), Intel LMS (deletes driver files), WPBT, Razer block** (rule 2).
- **Hibernation, laptop hibernation, Ultimate Performance:** power is owned by the setup (rule 2).
- **Storage Sense off, Location off:** these take away a customer benefit (rule 5).
- **Delete temp files, Disk Cleanup with `DISM /ResetBase`** (it removes the ability to uninstall updates), **Explorer auto-discovery** (it deletes saved folder views) (rule 2).
- **Activity history, Wi-Fi Sense, Homegroup:** obsolete on Windows 11 (rule 5).
- **Researched on 21/10/2026, then rejected:**
  - **Hide Widgets (`TaskbarDa`):** UCPD blocks the write from PowerShell, and every workaround fails rule 2 or 4 (rule 1).
  - **No Bing results in Start search (`BingSearchEnabled`, `IsWebSuggestionsEnabled`):** both are on UCPD's protected list, and one 24H2 report says "access denied"; the policy route fails rule 4. It may come back if a real machine proves it works.
  - **Detailed crash screen (`DisplayParameters`):** not confirmed on the new 24H2 black crash screen, and the same parameters are already in Event Viewer and the dump (rules 1 and 5).
  - **Game DVR off:** background recording is already off by default, so this would only break Game Bar capture (rule 5).
  - **The older ContentDeliveryManager values** (`SilentInstalledAppsEnabled`, `SystemPaneSuggestionsEnabled`, `SoftLandingEnabled`, `PreInstalledAppsEnabled`, `OemPreInstalledAppsEnabled`, `-338388Enabled`): no Windows 11 setting maps to them and there is no evidence they do anything on 24H2 (rule 1).
  - **Toggle Keys shortcut off and "Show notifications in Settings" off:** safe, but little benefit; the second also hides useful account-recovery prompts (rule 5).
  - **The other "keep classic Outlook" values** (`NewOutlookMigrationUserSetting`, `DoNewOutlookAutoMigration`, `UseNewOutlook`): policy-only or undocumented (rules 4 and 1).
- **Required diagnostic data only, consumer features:** policy paths, and Enterprise/Education-only (rules 1 and 4).
- **Edge and Brave debloat:** policy paths (rule 4).
- **Preference toggles** (dark mode, snap, mouse acceleration, verbose logon, multiplane overlay, S3 sleep, cross-device resume, Settings home, hidden files, Task View, search button): no clear benefit for most customers (rule 5). Ben can ask for any of them later.

## 7. Files
- **New:**
  - `src\Toolbox\Strings.ps1`: the string tables;
  - `src\Toolbox\Toolbox.ps1`: XAML here-strings, `Show-ToolboxWindow`, `Invoke-ToolboxAction`, the language switch;
  - `src\Toolbox\SetupPlanner.ps1`: pure functions for profiles, validation and the plan preview;
  - `src\Steps\Tweaks.ps1`;
  - `tools\Preview-Toolbox.ps1`.
- **Changed:** `src\Entry\Main.ps1` (line 295), `src\UI\StartScreen.ps1` (`New-DefaultChoices`), `src\Engine\Catalog.ps1`, `src\Steps\Finalize.ps1`, `src\Report\Report.ps1`, `config\config.json`, `tools\Build-Bundle.ps1` (`$BundleOrder`).
- **Untouched:** the launcher, the keys, the console progress and final screens, and the resume path.

## 8. Rules this changes
| Rule | From now on |
|---|---|
| v1 spec 36: "Any GUI framework. A console UI is enough." | One WPF window, before the run only. |
| v2 spec 48: "No GUI (WinForms/WPF)." | The same. The console screens stay for the run. |
| v2 Q1: zero-touch start (30-second countdown) | The toolbox waits for Start (Q18). The console fallback keeps its countdown. |
| v1 anti-goal "the tool stops and waits" | Still true for the run. Waiting before anything starts is intended. |
| ASCII-only and colour rules | Unchanged for the console. The window may show Hebrew (`Strings.ps1` only) and uses hex colours. |

## 9. Borrowed from WinUtil, and what not to copy
- **Borrowed ideas** (no code is copied):
  - a dark, borderless window;
  - theme values as resources;
  - Segoe glyph icons;
  - controls generated from JSON fields;
  - tooltips holding the full description.
- **Not copied:**
  - tweaks that run on the UI thread the moment a toggle is clicked;
  - reading a toggle's state by creating registry keys;
  - a runspace pool that can be disposed while in use;
  - `Start-Sleep` on the UI thread;
  - presets that run a toggle's undo;
  - downloading and running code at run time (`irm | iex`).

## 10. Ben's answers (21/10/2026)
| # | Question | Answer |
|---|---|---|
| Q26 | The three profiles in 5.2 | **Approved as proposed**, on condition that every option stays switchable per PC (5.2). |
| Q27 | Show file extensions | **Off everywhere.** It stays available as a switch, and no profile turns it on. |
| Q28 | The spec | **Approved**; the implementation plan comes next. |

## 10b. Calls made without Ben (check while reading)
1. **Administrator protection blocks Start** (5.3). The resume task would probably register the hidden admin account, so the run would stop after its first restart. An empty signed-in user name (RDP, early logon) counts as the same user, as today.
2. **NumLock (`desktopOnly`) is enforced, not just a default.** It is applied only when Type is DESKTOP, including in the console fallback.
3. **The restore-point frequency value is set and restored by the main process,** never left at 0, even when the child times out.
4. **There is no undo in step 1.** Every original value is in setup.log.
5. **The default profile wins over `defaults.office/remote/sevenZip`.** Those values stay for the console fallback, and for a profile that does not set them.
6. **The Profile line in the report keeps the profile's name** even after Ben changes an option, followed by `(changed)`.
7. **Business picks AnyDesk and ScreenConnect.** ScreenConnect means unattended access, so the Q16 rule applies: get the customer's OK at the counter.

## 11. To prove on a real machine (`docs/testing.md`)
- **Opening:** the window opens on top after UAC, and Start / Cancel / X behave as in section 3.
- **Hebrew:** RTL renders correctly, with machine values left-to-right.
- **Small screens:** the basic display driver at 1024x768 and at 150% scaling: everything is reachable, and the content scrolls.
- **Windows 10:** icons show (MDL2), and nothing hangs after the window closes (the `InvokeShutdown` check).
- **Fallback:** a failure (simulated on a VM by blocking PresentationFramework) falls back to the console screen.
- **Tweaks:**
  - each shipped tweak takes effect after the run, and a refused one is a yellow Note;
  - every HKCU value lands in the customer's hive;
  - the accessibility `Flags` stay REG_SZ;
  - the classic-menu default value is a real empty string;
  - NumLock is on at the sign-in screen of a desktop after a cold boot;
  - with Administrator protection turned on (on a VM), the toolbox shows the red banner with Start disabled. On the same VM, check whether `$env:USERNAME` and the resume task really point at the hidden account; that is the reason for the block. The tweaks step's skip and Note are proven by tests.
- **Restore point frequency:** after a run, `SystemRestorePointCreationFrequency` is back to its original value, or absent.
- **Restore point:** "BenTech setup" appears in `rstrui.exe`, and System Protection is on for C:.
- **The run is unchanged:** restarts, progress screen, final screen and cleanup.
