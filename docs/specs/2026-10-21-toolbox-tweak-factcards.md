# Registry tweak fact cards for bentech-winsetup

Research date: 21/10/2026. Scope: Windows 11 Home/Pro 24H2, 25H2, 26H2 (main), Windows 10 22H2 (best effort).
The rules every tweak must pass: (1) works on 11 Home AND Pro 24H2+; (2) no downloads, deletions, app removal, networking, weakened security, services or power settings; (3) reversible; (4) no path containing `\Policies\`; (5) a clear benefit.

Verdicts: **SHIP-ON** (default on), **SHIP-OFF** (available, default off), **REJECT** (with the failed rule).

---

## 0. Summary table

| # | Tweak | Verdict | Exact value(s) | Confidence |
|---|---|---|---|---|
| A1 | Sticky Keys shortcut (Shift x5) off | SHIP-ON | HKCU\Control Panel\Accessibility\StickyKeys `Flags` REG_SZ: clear bit 0x4 (default "510" -> "506") | High |
| A2 | Filter Keys shortcut (hold right Shift 8 s) off | SHIP-ON | HKCU\Control Panel\Accessibility\Keyboard Response `Flags` REG_SZ: clear bit 0x4 (default "126" -> "122") | High (bit) / Medium (default string) |
| A3 | Toggle Keys shortcut (hold NumLock 5 s) off | SHIP-OFF | HKCU\Control Panel\Accessibility\ToggleKeys `Flags` REG_SZ: clear bit 0x4 (default "62" -> "58") | High (bit) / Medium (default string) |
| B | NumLock on at sign-in, desktop chassis only | SHIP-ON (desktops only) | HKU\.DEFAULT\Control Panel\Keyboard `InitialKeyboardIndicators` REG_SZ "2147483650"; HKCU\Control Panel\Keyboard same name REG_SZ "2" | Medium-High |
| C1 | Start: tips, shortcuts, new apps off | SHIP-ON | HKCU\...\Explorer\Advanced `Start_IrisRecommendations` DWORD 0 | High |
| C2 | Notifications: "Get tips and suggestions when using Windows" off | SHIP-ON | HKCU\...\ContentDeliveryManager `SubscribedContent-338389Enabled` DWORD 0 | High |
| C3 | Settings app suggested content / "Recommendations and offers in Settings" off | SHIP-ON | ContentDeliveryManager `SubscribedContent-338393Enabled`, `-353694Enabled`, `-353696Enabled` DWORD 0 (all three) | High |
| C4 | Lock screen fun facts/tips off | SHIP-ON | ContentDeliveryManager `RotatingLockScreenOverlayEnabled` DWORD 0 and `SubscribedContent-338387Enabled` DWORD 0 | High (mapping) / note: only visible with Picture/Slideshow lock screen |
| C5 | SilentInstalledAppsEnabled, SystemPaneSuggestionsEnabled, SoftLandingEnabled, PreInstalledAppsEnabled, OemPreInstalledAppsEnabled, SubscribedContent-338388Enabled | REJECT (rule 1) | n/a | Medium |
| D | Detailed bug-check screen | REJECT (rules 1 and 5) | (HKLM\SYSTEM\CurrentControlSet\Control\CrashControl `DisplayParameters` DWORD 1, `DisableEmoticon` DWORD 1) | Low-Medium |
| E | No Bing/web results in Start search, non-policy | SHIP-OFF, only after a VM test (otherwise REJECT rule 1) | HKCU\Software\Microsoft\Windows\CurrentVersion\Search `BingSearchEnabled` DWORD 0; plus HKCU\...\CurrentVersion\SearchSettings `IsWebSuggestionsEnabled` DWORD 0 where the new toggle exists | Medium-Low |
| F | Hide Widgets button | REJECT (rule 1: UCPD denies powershell.exe; workarounds fail rules 2 and 4) | (HKCU\...\Explorer\Advanced `TaskbarDa` DWORD 0) | High |
| G | Show file extensions | SHIP-ON | HKCU\...\Explorer\Advanced `HideFileExt` DWORD 0 | High |
| H | Left-aligned taskbar icons | SHIP-OFF | HKCU\...\Explorer\Advanced `TaskbarAl` DWORD 0 | High |
| I | Classic right-click menu | SHIP-OFF | HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32, default value REG_SZ "" (empty string) | Medium |
| J | "End task" on taskbar right-click | SHIP-OFF | HKCU\...\Explorer\Advanced\TaskbarDeveloperSettings `TaskbarEndTask` DWORD 1 | High |
| K | Game DVR / background recording off | REJECT (rule 5) | (HKCU\System\GameConfigStore `GameDVR_Enabled` DWORD 0; HKCU\...\GameDVR `AppCaptureEnabled` DWORD 0) | High |
| L1 | Hide "Try the new Outlook" toggle (keeps classic Outlook) | SHIP-ON, only when Office = BUSINESS or HOME | HKCU\Software\Microsoft\Office\16.0\Outlook\Options\General `HideNewOutlookToggle` DWORD 1 | High (documented) / Medium (blocks Microsoft-driven migration) |
| L2 | NewOutlookMigrationUserSetting (stop automatic migration) | REJECT (rule 4) | only documented under HKCU\Software\Policies\... | High |
| L3 | DoNewOutlookAutoMigration=0 / UseNewOutlook=0 | REJECT (rule 5 / rule 1) | n/a | Medium |
| M1 | Start: "Show account-related notifications" off | SHIP-ON | HKCU\...\Explorer\Advanced `Start_AccountNotifications` DWORD 0 | High |
| M2 | File Explorer: "Show sync provider notifications" off | SHIP-ON | HKCU\...\Explorer\Advanced `ShowSyncProviderNotifications` DWORD 0 | High |
| M3 | Settings: "Show notifications in Settings" off | SHIP-OFF | HKCU\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications `EnableAccountNotifications` DWORD 0 | Medium |

`HKCU\...\Explorer\Advanced` = `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`.
`ContentDeliveryManager` = `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager`.

---

## 1. Cross-cutting findings (read these first)

### 1.1 UCPD (UserChoice Protection Driver) protects more than file associations
A read-only string scan of `C:\Windows\System32\drivers\UCPD.sys` on the dev PC (build 26300, driver dated 14/10/2026; the file was only read, nothing was executed or changed) shows:

- **Processes it denies** on protected paths: `powershell.exe`, `pwsh.exe`, `reg.exe`, `regedit.exe`, `regini.exe`, `cmd.exe`, `cscript.exe`, `wscript.exe`, `mshta.exe`, `rundll32.exe`, `dllhost.exe`, `wmiprvse.exe`, `InfDefaultInstall.exe`, `bssafe.exe`. **setup.ps1 runs in powershell.exe, so any protected value fails with "Access is denied".** The same list is published by binary.ninja (04/08/2026).
- **Protected registry paths/values** relevant here:
  - `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`, value **`TaskbarDa`** (also strings `TaskbarDelKey`, `TaskbarRenKey`: deleting/renaming the Advanced key is very likely blocked too). No other Explorer\Advanced value name appears; ElevenForum's REG files for TaskbarAl, Start_IrisRecommendations, Start_AccountNotifications, TaskbarEndTask work through regedit.exe (which is on the deny list), so those values are not protected.
  - `Software\Microsoft\Windows\CurrentVersion\Feeds` (`ShellFeedsTaskbarViewMode`, `EnableFeeds`, `IsFeedsAvailable`), `SOFTWARE\Policies\Microsoft\Dsh` (the Widgets policy) and `SOFTWARE\Policies\Microsoft\Windows\Windows Feeds`.
  - `Software\Microsoft\Windows\CurrentVersion\Search` and `...\SearchSettings` (no value names visible; see card E).
  - `Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband` (taskbar pins), `...\GamingConfiguration`, `...\CrossDeviceResume\*`, `Software\Microsoft\Windows\Shell\BrandedKey`, `...\Control Panel\DeviceRegion`, and the UserChoice keys for http/https/.pdf/.htm/.html/.doc(x)/.xls(x)/.ppt(x).
- Implication: **the tweak step must treat "Access is denied" as an expected outcome** (yellow note, not a crash), and the undo must never delete or rename `Explorer\Advanced` itself: only remove values it created.

### 1.2 Administrator protection moves HKCU when elevated
Administrator protection is GA with KB5120998 (August 2026) on Windows 11 Home/Pro 24H2/25H2. It is **off by default** on consumer devices (on by default only for orgs that apply the Windows security baseline, from the October 2026 update). When it is on, an elevated process runs under a hidden, profile-separated admin account, so **every HKCU write made by the elevated setup lands in the wrong profile** (ElevenForum notes "will not work when Administrator protection is turned on" on most of the REG files below). This already affects the existing `nags` step. Suggest: detect it and skip HKCU tweaks with a yellow note (the detection value needs a VM check; the documented switch is the policy "User Account Control: Configure type of Admin Approval Mode").

### 1.3 HKCU scope
Every HKCU tweak applies only to the account running setup. Other or later accounts get Windows defaults unless the Default user hive is edited (not recommended: more complexity, harder rollback).

### 1.4 When changes apply
Do not restart Explorer (no taskkill: anti-pattern registry). The tool reboots several times, so apply the tweaks in an early step and they are in effect after the next sign-in. Cards say what would apply sooner.

### 1.5 Recording the original
- REG_SZ accessibility Flags: record the string; write back by clearing only bit 0x4 of the current number (do not hard-code 506), so a customer's own Sticky Keys settings survive.
- Values that are usually absent on a fresh install (most Explorer\Advanced and CDM ones): record "absent"; undo = remove the value (absent means Windows default = on).

---

## A. Accessibility keyboard shortcuts

### A1. Sticky Keys shortcut (press Shift 5 times) off
- **Hive/key:** HKCU\Control Panel\Accessibility\StickyKeys
- **Value:** `Flags`, **REG_SZ** (a decimal number stored as a string).
- **Set:** current value with bit 0x4 (SKF_HOTKEYACTIVE) cleared. From the default "510" (0x1FE) that gives **"506"**.
- **Default:** "510", present on a fresh install.
- **Applies:** next sign-in (the registry is read at logon; immediate only via SystemParametersInfo(SPI_SETSTICKYKEYS), not needed).
- **Windows 11 24H2+ Home/Pro:** yes. Same switch as Settings > Accessibility > Keyboard > Sticky keys > "Keyboard shortcut for Sticky keys". Not protected by UCPD.
- **Windows 10 22H2:** yes (Settings > Ease of Access > Keyboard > "Allow the shortcut key to start Sticky Keys").
- **Benefit:** no more surprise Sticky Keys dialog/beep for gamers, kids and anyone resting on Shift.
- **Side effects:** a user who relies on the Shift x5 shortcut must turn Sticky Keys on in Settings or Quick Settings instead; Sticky Keys itself still works.
- **Sources:** Microsoft STICKYKEYS structure (SKF_HOTKEYACTIVE = 0x00000004: "the user can turn the StickyKeys feature on and off by pressing the SHIFT key five times") https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-stickykeys ; ElevenForum "Turn On or Off Sticky Keys" (REG_SZ Flags, "sign out and sign in or restart to apply", edited 30/08/2026) https://www.elevenforum.com/t/turn-on-or-off-sticky-keys-in-windows-11.8889/ ; kapilarya (506) https://www.kapilarya.com/how-to-disable-sticky-keys-in-windows-11
- **Confidence:** High.
- **Verdict:** **SHIP-ON.**

### A2. Filter Keys shortcut (hold right Shift 8 s) off
- **Key/value:** HKCU\Control Panel\Accessibility\Keyboard Response, `Flags`, **REG_SZ**.
- **Set:** clear bit 0x4 (FKF_HOTKEYACTIVE). Default **"126"** -> **"122"**.
- **Default:** "126", present (community sources; matches the documented bits 2+4+8+16+32+64).
- **Applies:** next sign-in.
- **24H2+ / Win10:** yes / yes.
- **Benefit:** stops the classic "my keyboard stopped typing" call after someone held right Shift and accepted the Filter Keys prompt.
- **Side effects:** Filter Keys must be enabled in Settings instead of by the shortcut.
- **Sources:** Microsoft FILTERKEYS (FKF_HOTKEYACTIVE 0x4 "holding down the RIGHT SHIFT key for eight seconds") https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-filterkeys ; pcrisk / edugeek ("Flags"="122") https://www.pcrisk.com/blog/windows/12938-cant-turn-off-sticky-keys
- **Confidence:** High for the bit, Medium for the default string (clear-the-bit approach makes it irrelevant).
- **Verdict:** **SHIP-ON** (as safe as A1).

### A3. Toggle Keys shortcut (hold NumLock 5 s) off
- **Key/value:** HKCU\Control Panel\Accessibility\ToggleKeys, `Flags`, **REG_SZ**. Clear bit 0x4 (TKF_HOTKEYACTIVE). Default **"62"** -> **"58"**.
- **Applies:** next sign-in. **24H2+ / Win10:** yes / yes.
- **Benefit:** small (it only turns on lock-key beeps).
- **Side effects:** none of note.
- **Sources:** Microsoft TOGGLEKEYS https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-togglekeys ; pcrisk (58).
- **Confidence:** High (bit) / Medium (default).
- **Verdict:** **SHIP-OFF** (safe, but weak benefit under rule 5).

---

## B. NumLock on at sign-in (desktops only)
- **Keys/values (both REG_SZ):**
  - HKU\.DEFAULT\Control Panel\Keyboard `InitialKeyboardIndicators` = **"2147483650"** (0x80000002). This is the sign-in screen state.
  - HKCU\Control Panel\Keyboard `InitialKeyboardIndicators` = **"2"** (or "2147483650"; both mean NumLock on).
- **Defaults:** .DEFAULT = "2147483648" on Windows 10/11 (present). HKCU: present, varies ("0", "2" or "2147483648"), because **Windows itself rewrites the HKCU value at sign-out and shutdown with the current NumLock state** (Microsoft: "The system stores the state of the NUMLOCK key in this entry during logoff and shutdown"). So the HKCU write is only a seed; the user's last state wins afterwards. Undo: write back the recorded strings.
- **Applies:** next boot (sign-in screen) and next sign-in.
- **Fast Startup:** the known failure (the hibernated session ignores the new value) does not apply, because this tool turns Fast Startup off. Firmware "Boot NumLock" settings only affect the time before Windows.
- **Laptops:** **do not apply.** On laptops with an embedded keypad (numbers printed on U/I/O/J/K/L/M), NumLock on makes letters type digits, including in the password box. Gate it on `Win32_SystemEnclosure.ChassisTypes` (CIM, no localized text) containing only desktop types (3, 4, 5, 6, 7, 13 all-in-one, 15, 16, 35) and no `Win32_Battery`; anything else (8, 9, 10, 14, 30, 31, 32, unknown) = skip.
- **24H2+ Home/Pro:** yes (same value since Windows 8; winaero lists 2147483650 for "Windows 11, 10, 8.1"). Not UCPD-protected.
- **Windows 10 22H2:** yes.
- **Benefit:** desktop users can type a numeric PIN on the numpad at the sign-in screen straight away.
- **Side effects:** none on desktops; harmful on embedded-keypad laptops (hence the gate).
- **Sources:** Microsoft (archived) InitialKeyboardIndicators, REG_SZ, 0 off / 2 on, saved at logoff https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-2000-server/cc978657(v=technet.10) ; winaero (2147483650 / undo 2147483648, REG_SZ, Fast Startup note) https://winaero.com/enable-numlock-logon-screen-windows-10 ; Microsoft Q&A (Fast Startup failures) https://learn.microsoft.com/en-us/answers/a/7567804
- **Confidence:** Medium-High (no current Microsoft page; behaviour long-stable).
- **Verdict:** **SHIP-ON for desktop chassis only** (skip on all others).

---

## C. Sponsored content, suggestions and tips

Current map (ElevenForum "Disable Ads in Windows 11", edited 19/09/2026; PCWorld 28/09/2026; Microsoft support "Privacy settings for Recommendations & offers"). All values: **REG_DWORD**, HKCU, non-policy, not UCPD-protected (ElevenForum applies them with regedit.exe). The tool already sets `SubscribedContent-310093Enabled`=0 and `ScoobeSystemSettingEnabled`=0; C2 completes that Notifications > Additional settings group.

### C1. Start: "Show recommendations for tips, shortcuts, new apps, and more"
- **Value:** HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced `Start_IrisRecommendations` = **0**.
- **Default:** usually absent (= on).
- **Applies:** next sign-in (or Start/Explorer restart).
- **24H2+:** yes (Settings > Personalization > Start). **Win10:** no effect (harmless).
- **Benefit:** no Store app promotions and tips in Start's Recommended section.
- **Side effects:** none; recent files still show unless the separate "recommended files" toggle is off.
- **Sources:** https://www.elevenforum.com/t/disable-ads-in-windows-11.8004/ ; https://www.elevenforum.com/t/enable-or-disable-tips-shortcuts-new-apps-and-more-on-start-in-windows-11.14346/ ; https://www.pcworld.com/article/2545435/windows-11s-ads-are-way-too-pushy-these-9-settings-fix-the-worst-of-it.html
- **Confidence:** High. **Verdict:** **SHIP-ON.**

### C2. "Get tips and suggestions when using Windows" (notifications)
- **Value:** ContentDeliveryManager `SubscribedContent-338389Enabled` = **0**.
- **Default:** 1 or absent (= on).
- **Applies:** immediately for new suggestions; Settings shows it at once.
- **24H2+:** yes (Settings > System > Notifications > Additional settings). **Win10:** yes ("Get tips, tricks, and suggestions as you use Windows").
- **Benefit:** stops upsell toasts (OneDrive, Microsoft 365, Edge, Game Pass).
- **Side effects:** no Windows "tips" toasts at all.
- **Sources:** ElevenForum ads list (above); geekrewind https://geekrewind.com/how-to-enable-or-disable-tips-and-suggestions-notifications-in-windows-11/ ; PCWorld (above).
- **Confidence:** High. **Verdict:** **SHIP-ON.**

### C3. Suggested content in the Settings app
- **Values:** ContentDeliveryManager `SubscribedContent-338393Enabled`, `SubscribedContent-353694Enabled`, `SubscribedContent-353696Enabled`, all = **0** (set all three together).
- **Default:** 1 or absent (= on).
- **Applies:** next time Settings opens.
- **24H2+:** yes. On builds from late 2026 the toggle lives at Settings > Privacy & security > **Recommendations & offers** ("Recommendations and offers in Settings"; older builds: Privacy & security > General > "Show me suggested content in the Settings app"). It also removes the Microsoft 365 "upgrade your plan" offer added in 26100.8116. NTLite users confirmed the three values on 24H2. **Win10:** yes (2004+).
- **Benefit:** no Microsoft 365/Game Pass/OneDrive promotions on the Settings home page.
- **Side effects:** fewer "discover this feature" cards in Settings.
- **Sources:** https://www.elevenforum.com/t/enable-or-disable-suggested-content-in-settings-in-windows-11.3791/ (edited 06/10/2026) ; https://support.microsoft.com/windows/807608ee-3de2-4498-8e7c-eb10d655567f ; https://ntlite.com/community/threads/windows-11-24h2-disable-show-me-suggested-content-in-the-settings-app.4531/
- **Confidence:** High. **Verdict:** **SHIP-ON.**

### C4. Lock screen "Get fun facts, tips, tricks, and more"
- **Values:** ContentDeliveryManager `RotatingLockScreenOverlayEnabled` = **0** and `SubscribedContent-338387Enabled` = **0**.
- **Default:** 1 or absent.
- **Applies:** next lock.
- **24H2+ / Win10:** yes / yes. The toggle is only shown (and only matters) when the lock screen is set to Picture or Slideshow; with the default Windows Spotlight it has no visible effect.
- **Benefit:** no tips/ads text on the lock screen if the customer picks their own photo.
- **Side effects:** none.
- **Sources:** ElevenForum ads list (above).
- **Confidence:** High. **Verdict:** **SHIP-ON** (cheap, harmless).

### C5. The rest of the classic ContentDeliveryManager list
`SilentInstalledAppsEnabled`, `SystemPaneSuggestionsEnabled`, `SoftLandingEnabled`, `PreInstalledAppsEnabled`, `OemPreInstalledAppsEnabled`, `SubscribedContent-338388Enabled`:
- No Windows 11 Settings toggle maps to them; they are absent from every current (2026) Windows 11 list (ElevenForum, PCWorld, Microsoft's Recommendations & offers page). `SystemPaneSuggestionsEnabled`/`338388` are the Windows 10 "Show suggestions occasionally in Start" switch. Windows 11's promoted Start pins are not driven by them, and Microsoft documents only the Enterprise/Education-only "Turn off Microsoft consumer experiences" policy for that. No 24H2 evidence they still change anything; the bloatware step already removes the known promoted apps.
- **Verdict:** **REJECT (rule 1: no evidence of effect on 11 24H2+; Windows 10-only effect).**
- **Confidence:** Medium.

---

## D. Detailed bug-check ("blue/black screen") text
- **Values:** HKLM\SYSTEM\CurrentControlSet\Control\CrashControl `DisplayParameters` REG_DWORD 1; `DisableEmoticon` REG_DWORD 1. Both absent by default.
- **Applies:** after reboot.
- **24H2+:** **not verified.** Since mid-2025 24H2+ shows the new black "Your device ran into a problem and needs to restart" screen (no emoticon, no QR code, stop code plus the failing module). No source confirms DisplayParameters still adds the four parameters to it; an ElevenForum thread (04/11/2025) asked exactly this and nobody could confirm. `DisableEmoticon` is moot (no emoticon any more).
- **Win10 22H2:** works (widely reported).
- **Benefit:** marginal. The four parameters are already in Event Viewer (BugCheck event) and the minidump, which is where a technician reads them anyway.
- **Side effects:** none.
- **Sources:** https://support.microsoft.com/en-us/help/14238 ; https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/blue-screen-data ; https://www.elevenforum.com/t/the-black-screen-of-death-is-causing-problems-in-terms-of-user-recognition.41688/
- **Confidence:** Low-Medium.
- **Verdict:** **REJECT (rule 1 unverified on the 24H2+ screen; rule 5 marginal).** Could be revisited after a NotMyFault crash on a 24H2 VM.

---

## E. No Bing/web results in Start search (non-policy)
- **Values:**
  - HKCU\Software\Microsoft\Windows\CurrentVersion\Search `BingSearchEnabled` REG_DWORD **0** (usually absent = web on).
  - HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings `IsWebSuggestionsEnabled` REG_DWORD **0**: the value behind the new official toggle Settings > Privacy & security > Search > "Show suggested search results" > **Web searches**, shipped with KB5120998 (August 2026) for 24H2 (26100.9278) and 25H2 (26200.9278) as a gradual (controlled feature) rollout. Kapilarya says it applies immediately.
- **Policy route:** `DisableSearchBoxSuggestions` lives under HKCU\Software\Policies\Microsoft\Windows\Explorer: **REJECT (rule 4).**
- **Does BingSearchEnabled still work?** ElevenForum's Brink (MVP, June 2026): BingSearchEnabled "is the current setting to use" where the new toggle isn't available; a user confirmed Start search was local-only with it (02/2025).
- **Blocking risk:** both `...\CurrentVersion\Search` and `...\SearchSettings` are on UCPD's protected-path list (section 1.1), and a 24H2 user got "access denied" writing BingSearchEnabled with reg/regedit that went away in Safe Mode (AnandTech forum). Yet ElevenForum's REG files for SearchboxTaskbarMode in the same key work (edited 12/10/2026), so the protection seems value- or region-specific. **Unknown whether powershell.exe can write BingSearchEnabled on a 24H2 PC in Israel.**
- **Win10 22H2:** unclear; BingSearchEnabled alone was reported insufficient after 2004.
- **Benefit:** Start search finds apps and files without opening Edge/Bing by surprise.
- **Side effects:** customers who use Start as a web search box lose that.
- **Sources:** https://www.elevenforum.com/t/enable-or-disable-bing-web-suggested-search-results-in-windows-search-on-windows-11.5309/ (edited 22/09/2026 plus replies) ; https://www.kapilarya.com/enable-or-disable-web-search-results-in-windows-11-26h2 ; https://www.digitaltrends.com/computing/windows-11-is-finally-rolling-out-the-option-to-kick-bing-out-of-search/ ; https://forums.anandtech.com/threads/can-someone-here-test-something-on-win11-24h2-for-me-please.2630400
- **Confidence:** Medium-Low.
- **Verdict:** **SHIP-OFF, only after a 24H2 VM test proves a powershell.exe write succeeds and Start shows no web results; until then REJECT (rule 1).** If shipped: Access denied = yellow note "turn off Web searches in Settings".

---

## F. Hide the Widgets taskbar button
- **Value:** HKCU\...\Explorer\Advanced `TaskbarDa` REG_DWORD 0 (default absent/1).
- **24H2+:** **write blocked by UCPD** for powershell.exe/reg.exe/regedit.exe. Confirmed by the driver strings (`TaskbarDa`), ElevenForum ("It is required to temporarily disable the UCPD service ... to be able to change the TaskbarDa DWORD", edited 08/09/2026), oofhours (24H2, LocalSystem still denied) and NTLite.
- **Alternatives:** disabling UCPD = service change plus weaker protection (rule 2); `AllowNewsAndInterests` under HKLM\SOFTWARE\Policies\Microsoft\Dsh = policy path (rule 4) and also UCPD-protected; uninstalling the Widgets package = app removal (rule 2). No non-policy, writable alternative. Manual: Settings > Personalization > Taskbar > Widgets off (technician checklist).
- **Win10 22H2:** the News and interests equivalent (`Feeds\ShellFeedsTaskbarViewMode`) is UCPD-protected too.
- **Sources:** https://www.elevenforum.com/t/add-or-remove-widgets-button-on-taskbar-in-windows-11.32/ ; https://oofhours.com/2025/05/02/what-is-windows-11s-new-ucpd-feature/ ; https://ntlite.com/community/threads/error-5-access-is-denied-when-disabling-set-news-and-interests-taskbar-widget.4852/ ; https://binary.ninja/2026/08/04/ucpd-dynamic-rules.html
- **Confidence:** High.
- **Verdict:** **REJECT (rule 1: cannot be written by the tool; every workaround fails rule 2 or 4).**

---

## G. Show file extensions
- **Value:** HKCU\...\Explorer\Advanced `HideFileExt` REG_DWORD **0**.
- **Default:** 1, normally present after first sign-in.
- **Applies:** new File Explorer windows / next sign-in.
- **24H2+ / Win10:** yes / yes. Same as File Explorer > View > Show > File name extensions (Microsoft support) and the "Show file extensions" switch in Settings (System > For developers / Advanced). Not UCPD-protected.
- **Benefit:** customers can see that "invoice.pdf.exe" is a program (MITRE ATT&CK T1036.007 mitigation: don't hide extensions).
- **Side effects:** renaming can touch the extension (Windows warns before changing it).
- **Sources:** https://support.microsoft.com/help/4479981 ; https://attack.mitre.org/techniques/T1036/007/ ; https://www.ninjaone.com/blog/display-file-name-extensions/
- **Confidence:** High. **Verdict:** **SHIP-ON.**

---

## H. Left-aligned taskbar icons
- **Value:** HKCU\...\Explorer\Advanced `TaskbarAl` REG_DWORD **0** (0 = left, or top on a vertical taskbar; 1 = center). Default absent (= center).
- **Applies:** usually at once; certainly at next sign-in.
- **24H2+:** yes, not UCPD-protected (only TaskbarDa is). The 2026 taskbar can sit on any edge; with a left/right taskbar, 0 means top-aligned. **Win10:** n/a.
- **Benefit:** familiar Windows 10 layout for customers coming from Windows 10.
- **Side effects:** a matter of taste.
- **Sources:** https://www.elevenforum.com/t/change-taskbar-icon-alignment-in-windows-11.12/ (edited 26/06/2026)
- **Confidence:** High. **Verdict:** **SHIP-OFF** (preference, not a clear benefit for everyone).

---

## I. Classic right-click menu
- **Key:** HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32, **default value REG_SZ "" (empty string)**. It must be a real empty string, not "(value not set)", or it does nothing (administrator.de). Not UCPD-protected.
- **Default:** key absent. **Undo:** delete `HKCU\Software\Classes\CLSID\{86ca1aa0-...}` only if setup created it.
- **Applies:** after Explorer restart or next sign-in.
- **24H2/25H2:** works per Microsoft Q&A (answer and "Worked great", 02-03/12/2025) and Pureinfotech (revised 21/05/2026, with "some users report problems"). Undocumented COM override: a future update could ignore it (it would fall back to the new menu, harmlessly).
- **Win10:** n/a (skip there).
- **Benefit:** full menu in one click for customers coming from Windows 10.
- **Side effects:** loses the Windows 11 compact menu.
- **Sources:** https://learn.microsoft.com/en-us/answers/questions/5644320/how-to-bypass-the-new-context-menu-and-go-directly ; https://pureinfotech.com/bring-back-classic-context-menu-windows-11/ ; https://administrator.de/knowledge/windows-11-activate-classic-context-menu-1377812885.html
- **Confidence:** Medium. **Verdict:** **SHIP-OFF.**

---

## J. "End task" in the taskbar right-click menu
- **Value:** HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings `TaskbarEndTask` REG_DWORD **1**.
- **Default:** key and value absent (= off). Undo: remove the value; leave the subkey (deleting keys under Explorer\Advanced may hit UCPD's key-delete rule).
- **Applies:** immediately (no restart, per prajwaldesai).
- **24H2+:** yes; available since 22631.2715 (23H2). Settings location in 2026: System > Advanced > Taskbar settings > End task (formerly System > For developers). Not UCPD-protected. **Win10:** n/a.
- **Benefit:** easy phone instruction for frozen apps: right-click the icon, End task.
- **Side effects:** End task kills without a save prompt; a misclick next to "Close window" loses unsaved work.
- **Sources:** https://www.elevenforum.com/t/enable-or-disable-end-task-in-taskbar-by-right-click-in-windows-11.14325/ (edited 12/04/2026) ; https://www.prajwaldesai.com/?p=327059
- **Confidence:** High. **Verdict:** **SHIP-OFF** (data-loss risk for non-technical users).

---

## K. Game DVR / background recording
- **Values:** HKCU\System\GameConfigStore `GameDVR_Enabled` REG_DWORD 0; HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR `AppCaptureEnabled` REG_DWORD 0.
- **Facts:** background recording ("Record what happened", `HistoricalCaptureEnabled`) is **off by default** on Windows 11 (ElevenForum, edited 29/08/2026), so there is no idle cost to remove. Turning off AppCaptureEnabled/GameDVR_Enabled removes Game Bar video/screenshot capture (Win+Alt+R, Win+Alt+PrtScn). The only current "disable" documented by ElevenForum is the policy AllowgameDVR (rule 4).
- **Win10:** same values.
- **Sources:** https://www.elevenforum.com/t/enable-or-disable-record-what-happened-for-gaming-captures-in-windows-11.17900/ ; https://www.elevenforum.com/t/enable-or-disable-game-recording-for-captures-in-windows-11.17611/
- **Confidence:** High.
- **Verdict:** **REJECT (rule 5: no benefit when the expensive part is already off; it only breaks Game Bar capture).**

---

## L. Keep classic Outlook

### L1. Hide the "Try the new Outlook" toggle
- **Value:** HKCU\Software\Microsoft\Office\16.0\Outlook\Options\General `HideNewOutlookToggle` REG_DWORD **1** (Microsoft documents this non-policy path). Create `General` if missing.
- **Default:** absent (toggle shown). Undo: remove the value.
- **Applies:** next start of classic Outlook. Microsoft FAQ: a user already on new Outlook "is switched out of Outlook for Windows back to classic Outlook the next time they open classic Outlook".
- **Migration:** Microsoft's admin-controlled migration flow is not shown when the toggle is hidden ("If the toggle is hidden, users don't see the migration experience"). The Enterprise auto-migration notice MC949965 (opt-out phase moved to March 2027) excludes users whose toggle is "hidden by policy"; whether the non-policy value counts is not documented (Medium confidence).
- **Note:** Microsoft's "Control installing and using new Outlook" page shows the 0/1 values the other way round; the Exchange page and the FAQ agree that **1 = hide**.
- **Scope:** only useful when classic Outlook is installed: **Office = BUSINESS or HOME**; skip for CRAFT and OFF. Windows-version independent (Win10 too).
- **Benefit:** customers who pay for classic Outlook don't flip to new Outlook by accident (no COM add-ins, different PST/POP behaviour).
- **Side effects:** the user can still open the new Outlook app from Start; they just lose the one-click switch.
- **Sources:** https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/outlook-on-the-web/enable-disable-employee-access-new-outlook (updated 06/10/2026) ; https://learn.microsoft.com/en-us/microsoft-365-apps/outlook/manage/admin-controlled-migration-policy ; https://mc.merill.net/message/MC949965
- **Confidence:** High (documented value) / Medium (stops Microsoft-driven migration).
- **Verdict:** **SHIP-ON when Office = BUSINESS or HOME.**

### L2. NewOutlookMigrationUserSetting = 0
- Microsoft documents it **only** at HKCU\Software\Policies\Microsoft\office\16.0\outlook\preferences.
- **Verdict:** **REJECT (rule 4).**

### L3. DoNewOutlookAutoMigration = 0 and UseNewOutlook = 0
- `DoNewOutlookAutoMigration` (HKCU\...\Office\16.0\Outlook\Options\General, documented) only switches off the *admin-controlled* migration policy, which is never set on an unmanaged PC, and a tenant Cloud Policy (Policies path) would override it: **REJECT (rule 5).**
- `UseNewOutlook` (HKCU\...\Office\16.0\Outlook\Preferences) is only mentioned in a community Q&A answer, not in Microsoft docs, and L1 already returns users to classic: **REJECT (rule 1).**

---

## M. Extra suggestions (three, strong evidence)

### M1. Start: "Show account-related notifications" off
- **Value:** HKCU\...\Explorer\Advanced `Start_AccountNotifications` REG_DWORD **0**. Default absent (= on).
- **Applies:** next sign-in.
- **24H2+:** yes (Settings > Personalization > Start > "Show account-related notifications"; since 22621.1928; Microsoft says required notifications still show). **Win10:** ElevenForum says it applies to Windows 10 as well.
- **Benefit:** no badge/nag on the Start account picture ("back up your PC", OneDrive storage, subscription upsell).
- **Side effects:** some useful prompts (for example, account recovery info) are hidden from Start; Microsoft still shows required ones.
- **Sources:** https://www.elevenforum.com/t/enable-or-disable-notification-badging-for-microsoft-accounts-on-start-menu-in-windows-11.14645/ (edited 08/09/2026) ; ElevenForum ads list.
- **Confidence:** High. **Verdict:** **SHIP-ON.**

### M2. File Explorer: "Show sync provider notifications" off
- **Value:** HKCU\...\Explorer\Advanced `ShowSyncProviderNotifications` REG_DWORD **0**. Default: on (often absent).
- **Applies:** new Explorer windows / next sign-in.
- **24H2+ / Win10:** yes / yes (Folder Options > View checkbox; Windows 10 build 14901+).
- **Benefit:** removes OneDrive/Microsoft 365 upsell banners inside File Explorer.
- **Side effects:** OneDrive info banners in Explorer are hidden too (OneDrive's own tray notifications still work).
- **Sources:** ElevenForum ads list ; PCWorld (28/09/2026) ; https://www.ninjaone.com/blog/show-sync-provider-notification-in-file-explorer/
- **Confidence:** High. **Verdict:** **SHIP-ON.**

### M3. Settings: "Show notifications in Settings" off
- **Value:** HKCU\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications `EnableAccountNotifications` REG_DWORD **0**. Default absent (= on).
- **Applies:** next time Settings opens.
- **24H2+:** yes (Settings > Privacy & security > Recommendations & offers on current builds; > General on older ones; NTLite user confirmed it "did the trick" on 24H2). **Win10:** probably n/a.
- **Benefit:** fewer Microsoft-account nags on the Settings home page.
- **Side effects:** hides account-security prompts (recovery info) that can actually help a non-technical customer.
- **Sources:** https://www.elevenforum.com/t/enable-or-disable-show-notifications-in-settings-app-in-windows-11.25835/ (edited 06/10/2026) ; https://ntlite.com/community/threads/windows-11-24h2-disable-show-me-suggested-content-in-the-settings-app.4531/
- **Confidence:** Medium. **Verdict:** **SHIP-OFF.**

Considered but not carded: `LaunchTo`=1 (Explorer opens to This PC; taste), `AdvertisingInfo\Enabled`=0 and `Privacy\TailoredExperiencesWithDiagnosticDataEnabled`=0 (privacy, no visible benefit; good SHIP-OFF candidates), "Show search highlights" (`SearchSettings\IsDynamicSearchBoxEnabled`: SearchSettings is UCPD-listed, same caveat as E).

---

## Things a VM must prove before shipping (add to docs/testing.md)
1. E: a powershell.exe write of `BingSearchEnabled` (and `IsWebSuggestionsEnabled`) succeeds on 24H2/25H2 with UCPD running, and Start shows no web results.
2. Every HKCU tweak lands in the customer's hive (and the tool detects Administrator protection).
3. B: NumLock is on at the sign-in screen on a desktop VM after a cold boot with Fast Startup off.
4. I: the default value is an empty REG_SZ (not "value not set") when written from PowerShell 5.1, and the classic menu appears after sign-in.
5. A: `Flags` stays REG_SZ after the write (writing a DWORD would break it).
