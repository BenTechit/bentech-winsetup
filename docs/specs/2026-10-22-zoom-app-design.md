# bentech-winsetup: Zoom as an optional app

**Status:** Approved by Ben on 23/10/2026 (Q56; decisions Q49-Q52 and Q55).
**Amends:** the v1 spec, the toolbox spec ([2026-10-21-toolbox-design.md](2026-10-21-toolbox-design.md)) and the drivers-only spec ([2026-10-22-windows-update-option-design.md](2026-10-22-windows-update-option-design.md)). They stay binding wherever this document does not change them.
**Builds on:** main as released in v2026.10.22.2 (drivers-only), which touches the same toolbox files. The repair page (`feat/repair-tool`) touches them too; whichever of the two merges second takes the other in first.

## 1. Why
Some customers need Zoom for work or family calls. Today Ben installs it by hand after the run. He wants it as a switch in the toolbox's APPS row, next to 7-Zip, so it installs with everything else when he turns it on.

## 2. Decisions (Ben, 22/10/2026)

| # | Question | Answer |
|---|---|---|
| Q49 | Default | **Off everywhere.** Ben switches it on for the PCs that need it. No profile turns it on. |
| Q50 | Auto-update | **On at install.** Zoom's per-machine MSI leaves auto-update off by default, so a customer's Zoom would go stale and, after a while, refuse to join meetings. Turning it on makes updates install quietly when Zoom restarts, never during a meeting. |
| Q51 | Install route | **winget `Zoom.Zoom`,** like 7-Zip. It is the per-machine MSI from zoom.us (x64 and ARM64), hash-checked by winget. |
| Q52 | Desktop icon | **Keep it.** The installer's Public desktop icon stays. |
| Q55 | Proving the auto-update setting | **Build now on Zoom's documented value; the first customer laptop with Zoom on is the test.** No VM check first. |

## 3. Behaviour

### 3.1 The choice
- **New Choices key `Zoom`** (bool, default `$false`).
  - `config.json` gains `defaults.zoom: false`.
  - A profile may set `"zoom"` (bool). **The three approved profiles do not set it** (Q49).
  - **A profile that does not set `zoom` leaves the switch alone** *(my call, the same rule as drivers-only's `windowsUpdate`)*. Clicking Home, Business or Clean never turns off a Zoom that Ben switched on. `Test-ProfileChanged` ignores the key unless the profile sets it.
  - **Missing or not a bool means `$false`,** so an older run state behaves as today.
  - `ConvertTo-ValidChoices` keeps the key, as it does for the others.
- **The toolbox window:** the APPS row gains a **Zoom** switch after 7-Zip, in the same switch style. Its label is "Zoom" in both languages. The "What will happen" column shows the new step when the switch is on.
- **The console fallback** (`Show-StartScreen`) is unchanged: no new line, no new key. It runs with the default profile's value, which is off *(my call, as for drivers-only: the fallback is an emergency path)*.

### 3.2 The zoom step
- **New step `zoom`** (title `Zoom`), right after `7zip` in `Catalog.ps1`. It is planned only when `Choices.Zoom` is `$true`.
  - It comes before `office`, so its Windows Installer run never overlaps the Office background install.
- **It installs with winget,** the same way as 7-Zip: `Invoke-WingetInstall -Id <apps.zoom.wingetId>`. It returns winget's own result (Done or Failed; a failure is red, like 7-Zip).
- **Auto-update (Q50):** the MSI gets Zoom's documented auto-update key `AU2_EnableAutoUpdate` set to true, through Zoom's `ZConfig` MSI property.
  - It travels on winget's `--custom` argument, which adds to the MSI command line.
  - The value lives in the signed `config.json` as `apps.zoom.custom`, a list of `NAME=VALUE` tokens, so it is never built from user input.
  - Each token must match a strict pattern: a name of letters, digits and `_`, then `=`, then letters, digits, `_`, `=` and `;`. No quotes and no spaces.
  - The tokens are joined with spaces, and our code passes them as one quoted `--custom` value. Quoting is where Zoom's own users went wrong (msiexec showed its help box), so no token ever holds a quote.
  - **Built on Zoom's documented value, proven on the first laptop (Ben, Q55 B).** The shipped token is `ZConfig=AU2_EnableAutoUpdate=true`. The first customer laptop with Zoom on is the test (5). If the token turns out wrong, it is fixed in the signed `config.json` of the next release, with no code change. `tools\spikes\Spike-ZoomInstall.ps1` stays for a VM check whenever one is at hand.
  - **A wrong token must not stall the run** *(my call)*: the zoom step has its own short bound, `timeoutsMinutes.zoom` = 10. A msiexec help box waiting for a click then costs at most 10 minutes, not the 30 of `timeoutsMinutes.default`, and the step is red (`Zoom install timed out`).
  - **A token that is missing or fails the pattern at run time** (Config.Tests pins the shipped value, so this means a broken config): Zoom installs without it, and the step adds a yellow Note `Zoom auto-update not set` *(my call: Zoom itself is still useful)*.
- **Already installed** *(my call; reworded by ruling Z-R3)*: `winget install` of a Zoom it finds installed tries an upgrade.
  - **An older per-machine Zoom is upgraded**, and the `--custom` token goes with the upgrade, so auto-update is set. The step reads like a fresh install. That is better than leaving it old.
  - **An up-to-date Zoom, or a per-user one, is left as it is.** winget answers `0x8A15002B` (no applicable update; a per-user Zoom next to our per-machine installer is a scope mismatch and answers the same), or `0x8A150061` (already installed). Neither installs anything or applies `--custom`. The step is Done with a yellow Note: `Zoom was already installed: auto-update not changed`. The activity line then says `Zoom already installed`. A customer's own per-user Zoom is left alone (6).
- **After a fresh install,** an activity line reads `Zoom installed`, as for 7-Zip.
- **Nothing else:**
  - The step does not open Zoom or sign in.
  - It does not set meeting or audio settings.
  - It does not create or remove shortcuts (Q52).
  - If the first laptop shows that Zoom starts on its own after a silent install, Zoom's documented property that stops it joins `apps.zoom.custom` in the next release (config only), so no Zoom window pops up in the middle of the run.

### 3.3 The report and the final screen
- **Report:** the Apps list gains Zoom, read like 7-Zip from its Uninstall entry. The 64-bit HKLM entry is read first, so a per-machine install wins over a leftover per-user one. The patterns are Zoom's per-machine names, `Zoom Workplace*` and then `Zoom(64bit)*` / `Zoom (64-bit)*` *(my call; older builds used the latter)*, not a bare `Zoom*` that could match another product (an Outlook plug-in, say). The first laptop records the real name (5).
- **The toolbox look** *(my call, as for the UPDATES row)*: re-render the preview PNGs, add one with Zoom switched on in English and Hebrew, and show them to Ben before the merge.
- **Final screen and verdict:** nothing new. A failed Zoom is a red step, like 7-Zip.

## 4. Rules this changes
| Rule | From now on |
|---|---|
| The APPS row: Chrome (always) and 7-Zip | **Zoom** is added as a third item, off by default. |
| `Get-WingetInstallArgs` takes only an id and a source | It also takes an optional custom string from the signed config, checked against a strict pattern. |
| winget `0x8A15002B` (no applicable update) is Failed | **For `install` only** it is Done, already installed, like `0x8A150061` (ruling Z-R3): `winget install` of a package it finds installed tries an upgrade and answers this code when none applies. It also keeps 7-Zip green on a PC that already has it. `uninstall` keeps Failed. |

## 5. To prove on a real machine (`docs/testing.md`; the first laptop with Zoom on, Q55)
- **Install:** Zoom installs per-machine from winget on x64 (and on ARM64 when one is at hand), with no window and no prompt during the run, well inside the 10-minute bound.
- **Auto-update:** in Zoom, Settings > General shows automatic updates on. If not, or if the step timed out on a msiexec help box, the token is fixed in the next release's `config.json`.
- **Zoom does not open by itself** during the run, and does not start at sign-in unless Zoom's default does. Record what Zoom does.
- **The desktop icon** is on the Public desktop after the run.
- **The report** shows Zoom's version. Record the real DisplayName.
- **The toolbox:** the Zoom switch in English and Hebrew; a profile click leaves it alone; the plan column shows `Zoom`.

## 6. Not in scope
- **Zoom settings beyond auto-update** (audio, video, sign-in, SSO).
- **Removing an existing Zoom,** or a per-user Zoom the customer already has. A per-user Zoom next to the per-machine one is possible; testing.md records what happens.
- **Other video apps** (Teams, Webex).
