# bentech-winsetup: Windows Update "drivers only", with Windows Update handed to Windows at the end

**Status:** Approved by Ben on 22/10/2026 (Q39), shipping on its own first (Q40).
**Amends:** the v1 spec, the v2 spec ([2026-10-20-progress-visibility-design.md](2026-10-20-progress-visibility-design.md)) and the toolbox spec ([2026-10-21-toolbox-design.md](2026-10-21-toolbox-design.md)). They stay binding wherever this document does not change them.

## 1. Why

A full setup takes a long time, and most of it is Windows Update: the big cumulative and feature updates, and the restarts they need. Sometimes Ben has the time, and sometimes he wants the PC ready fast with only the drivers sorted. When there is time left at the end, he wants to start Windows Update and let it finish on its own.

## 2. Decisions (Ben, 22/10/2026)

| # | Question | Answer |
|---|---|---|
| Q36 | What "leave out Windows Update" does | **Drivers only.** Windows Update installs driver updates only, with no cumulative or feature updates. The Dell, HP and Lenovo tools run as today. |
| Q37 | What the toolbox picks by itself | **Full updates, as today.** Ben switches a PC to drivers only when he is short on time. |
| Q38 | Starting Windows Update at the end | **Hand it to Windows.** A key on the final screen starts Windows' own update check. Windows downloads and installs in the background and restarts when it decides. Ben can leave. |

## 3. Behaviour

### 3.1 The choice
- **New Choices key** `WindowsUpdate`: `FULL` (the default) or `DRIVERS`.
  - `config.json` gains `defaults.windowsUpdate`, set to `"FULL"`.
  - A profile may also set `"windowsUpdate"`. The three approved profiles do not, so they stay FULL (Q37).
  - **A profile that does not set `windowsUpdate` leaves the tile alone** (builder check). Clicking Home, Business or Clean never resets a DRIVERS pick. `Test-ProfileChanged` ignores the key unless the profile sets it, so choosing DRIVERS does not add "(changed)" to the report's Profile line.
  - **Missing or invalid means FULL,** so an older run state behaves as today.
- **The toolbox window** gets an **UPDATES** row between REMOTE and APPS, with two tiles:
  - `Full updates` (glyph: the update icon);
  - `Drivers only` (glyph: a chip or driver icon, settled on the screenshots).

  Both tiles are in English and Hebrew. The "What will happen" column shows the step as `Windows Update (drivers only)` in DRIVERS mode.
- **The console fallback** (`Show-StartScreen`) is unchanged: no new line, no new key. It runs with the default profile's value (FULL). *(My call: the fallback is an emergency path, and FULL is the safe default.)*

### 3.2 The windows-update step
- **FULL:** exactly as today. It searches `Software` then `Driver` updates, installs them one at a time and restarts as needed.
- **DRIVERS:** the same step, rounds and restarts, but the search covers **`Driver` only**.
  - Every existing rule still applies: one at a time, firmware only on AC power, the round and restart caps, hide and un-hide.
  - **Optional updates (`BrowseOnly=1`) stay skipped, as in FULL** *(my call)*. On Windows 11 many OEM drivers are offered as optional, so DRIVERS may install few drivers through Windows Update; the vendor tools cover the rest. The first DRIVERS round logs how many optional drivers it skipped (ruling WU-R1: once per run, answered from the catalog the driver search has just downloaded). The count runs last in that round, after its installs (ruling WU-R3), and is skipped when the round threw (the agent just failed, and the count is only a diagnostic), so that run logs none. **The round's result is written before the count** (ruling WU-R5), so the count only logs. A count that hangs runs into the round's deadline (`timeoutsMinutes.wuRound`); the parent whose round timed out then uses the result the round already wrote (a WARN `Windows Update round timed out after its result was written`, then the round is booked like any other), and fails as `Windows Update round timed out` only when there is no readable result. A hanging count can still cost time, up to the round's deadline, but never the round's drivers or its result. `docs/testing.md` 1.20 measures how long the count takes. Ben decides after the first real runs whether DRIVERS should also take them.
  - The step's message says `Drivers only`. Its activity line reads `Windows Update: drivers only (other updates left to Windows)`.
- **Nothing else changes:** the vendor passes, Office, the Microsoft Update opt-in and the policies the run sets and removes.

### 3.3 The final screen and the report
- **Final screen,** in DRIVERS mode only: the key line gains `[U] Windows Update`.
  - Pressing **U** opens `ms-settings:windowsupdate-action`. That opens Settings → Windows Update and starts **Check for updates** at once, which is Windows' documented URI.
  - **Feedback** (builder check): once Settings has opened, the blank spacer line above the key line shows `Windows Update started: Windows will finish on its own`. If opening it fails, the same line reads `Could not open Windows Update: open Settings > Windows Update` and the failure goes to setup.log. Enter still finishes as today.
  - **Layout:** the 29-line worst case holds, because no line is added. The width budget is 79 columns, since the console frame cuts every row at width minus one. In DRIVERS mode the key line becomes `  [R] report   [U] Windows Update   [ENTER] finish`, without the report path; the path is in the report folder on the stick. FULL mode's key line is unchanged.
- **The verdict is not changed by DRIVERS mode** *(my call)*. Ben chose to leave the updates to Windows, so a fast run can still be GREEN.
- **The report** gains a header line after `Restore point:`: `Updates      : full`, or `Updates      : drivers only (other updates left to Windows)`. It is named "Updates" so it is not mistaken for the existing `Windows Update: N rounds, ...` line.

### 3.4 Time saved (to measure, not promised)
DRIVERS mode skips the cumulative-update download (often 1–4 GB), its install and usually one or two restarts. The real saving is measured on the first laptops (5).

## 4. Rules this changes
| Rule | From now on |
|---|---|
| v1 / v2: Windows Update installs everything the search finds | In DRIVERS mode, only `Type='Driver'` updates. FULL is unchanged. |
| The final screen's keys: Enter, B, R | **U** is added, in DRIVERS mode only. |

## 5. To prove on a real machine (`docs/testing.md`)
- **The DRIVERS run:** Windows Update history shows only driver updates installed by the run, and no cumulative update. Firmware is still held on battery. Record the total time against a FULL run on a similar PC.
- **Optional drivers:** record the logged count of optional drivers skipped; Ben decides from it.
- **The U key:** Settings opens on Windows Update and starts checking. After Enter (cleanup) and closing the console, Windows keeps downloading and installing on its own.
- **An old run state** without `WindowsUpdate`, resumed by the new version, runs FULL.
- **The toolbox:** the UPDATES row in English and Hebrew, and the plan column's step title.

## 6. Not in scope
- **A "skip Windows Update completely" mode** (Q36 chose drivers only).
- **Choosing individual updates.**
- **Running full updates later from the toolbox, with its own restarts** (Q38 chose to hand them to Windows).
