# bentech-winsetup: Craft apps as the default office suite

**Status:** DRAFT. Ben agreed the behaviour in chat on 20/10/2026; the plan approval is pending.
**Amends:** [2026-10-20-progress-visibility-design.md](2026-10-20-progress-visibility-design.md) and the v1 spec. Both stay binding wherever this document does not change them.

## 1. Why

Ben wants a free office suite installed by default instead of Microsoft 365. The suite is ArtCraft's open-source WordCraft (Word), GridCraft (Excel), DeckCraft (PowerPoint) and PdfCraft (PDF). He tested WordCraft with Hebrew on his own PC: it works like Word. He also wants ArtCraft's launcher installed, so the apps get updates afterwards.

**This is a test release.** On the first laptop, Ben checks that the launcher recognises the apps the tool installed and updates them.

The apps are alpha: their own README says "WordCraft is in alpha". Microsoft 365 therefore stays one key press away.

## 2. Decisions (Ben, 20/10/2026)

| # | Question | Answer |
|---|---|---|
| Q10 | Default office choice | **CRAFT** (Craft apps). Microsoft 365 stays selectable. |
| Q11 | Desktop shortcuts | **Yes**, with familiar names: **Word**, **Excel**, **PowerPoint**. PdfCraft's shortcut is **PDF Reader** (my call). |
| Q12 (revised) | How to install | The tool installs the four apps **itself, silently**, from their signed installers. **Then** it installs the **ArtCraft Launcher**. Ben opens the launcher on the test laptop to check that it finds the apps and updates them. |

## 3. Behaviour

### 3.1 Start screen

- `Choices.Office` gains the value `CRAFT`.
- `config.json` `defaults.office` becomes `"CRAFT"`.
- **O** cycles CRAFT → BUSINESS → HOME → OFF → CRAFT.
- The Office line reads `Office   CRAFT (free Word/Excel/PowerPoint/PDF)`.

### 3.2 Plan

- With CRAFT, a new step **`craft-apps`** (Title `Craft apps`, Short `Craft apps`) runs right after `7zip`, before `default-browser` and the driver tools. Running there keeps every MSI install ahead of the vendor tools.
- With CRAFT, `office` and `office-finish` are left out of the plan.
- With BUSINESS or HOME, the plan is exactly as today.

### 3.3 The step

The step works through the list in `config.json`: WordCraft, GridCraft, DeckCraft, PdfCraft, then the launcher.

For each item:

1. **Find the newest release.** Read `https://api.github.com/repos/<repo>/releases/latest` (JSON, with a User-Agent header, through the existing download helpers).
   - Pick the asset matching `^<prefix>-[0-9][0-9A-Za-z.+-]*-windows-<arch>\.msi$`.
   - `<arch>` is the laptop's processor: x64, arm64 or x86.
2. **Download and check.** Download the MSI and that release's `SHA256SUMS.txt`.
   - The MSI's SHA-256 must equal its line in `SHA256SUMS.txt`, matched by exact file name.
   - Its Authenticode signature must be `Valid`, and the signer must match `signers.craft`: `Learning Machines Inc`. This is the subject seen on 20/10/2026 on `wordcraft-0.8.0` and `artcraft-launcher-0.5.1`.
   - The certificates are short-lived (3 days) and timestamped, so the check uses the company name, never a thumbprint.
3. **Skip when current.** If the app is already installed at that version or newer, skip it ("already up to date"). Installed version = Uninstall registry `DisplayVersion`, found by a configurable `displayName` match.
4. **Install.** Run `msiexec /i "<msi>" /qn /norestart` through `Invoke-External`, with `timeoutsMinutes.msi`, mapped by `Convert-MsiExitCode`.
5. **Shortcut** (apps only). On the public desktop, create `<FamiliarName>.lnk`, but only if a shortcut with that name doesn't already exist.
   - Preferred: copy the Start-menu shortcut the MSI created, found by a configurable `startMenuName` match. If the MSI put its own desktop shortcut (`<App>.lnk`) on a desktop, rename it rather than copy, so there are no duplicates.
   - The launcher gets an `ArtCraft Launcher` shortcut on the user's desktop the same way.

**Results:**
- **One item failing** (lookup, download, checksum, signature, install) doesn't stop the others.
- **All installed or current:** Done.
- **Any app failed:** Failed with the failed names in the message (red).
- **Only the launcher failed:** Done with a yellow Note, `ArtCraft Launcher could not be installed`. The apps work without it.
- **A shortcut failing:** a yellow Note.

**GitHub limits:** GitHub allows 60 lookups per hour per shop IP, and a laptop needs 5. A rate-limit answer (HTTP 403 or 429) gets one retry after 60 s through `Wait-SetupDelay`. If that also fails, the item fails with `GitHub busy - try again later`.

### 3.4 Visibility

- **NOW** shows the item being worked on, for example `Craft apps - WordCraft 0.8.0: downloading`.
- **Activity lines:**
  - `WordCraft 0.8.0 installed - desktop shortcut: Word`
  - `PdfCraft 0.9.0 already up to date`
  - `ArtCraft Launcher 0.5.1 installed - open it to check the apps and their updates`
- **The report** lists the installed versions. `Get-InstalledAppVersions` learns the five names.

### 3.5 Unchanged

- The Office path (BUSINESS/HOME) and its shortcuts are unchanged. The two choices never both run.
- The launcher must not change (the USB sticks stay valid).
- The colour, tick, ASCII and no-prompt rules all hold.

## 4. Not in scope

- The tool does not update the apps later. That is the launcher's job, and Ben checks it.
- No Outlook or OneNote equivalents.
- No per-app choice. All four are installed.

## 5. To prove on a real machine (`docs/testing.md`)

- `msiexec /qn` installs each app MSI and the launcher MSI silently, under the elevated setup account.
  - The apps should install for all users and the launcher for the current user. Confirm which.
- The real Uninstall `DisplayName` and Start-menu shortcut names, to fill or correct `displayName`/`startMenuName` in `config.json`.
- Whether the MSIs create desktop shortcuts themselves.
- The four desktop shortcuts are named Word, Excel, PowerPoint and PDF Reader, with the right icons and no duplicates.
- **Ben's test:** the launcher shows the four apps as installed, and offers and applies an update when one comes out.
- A second run skips the apps as up to date.
- The same signer on all five MSIs (DeckCraft, GridCraft and PdfCraft were not checked on 20/10/2026).
