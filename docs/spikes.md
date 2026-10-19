# Spikes: what to run, where, and what to send back

These are five small throwaway scripts. Spikes 1 to 4 each answer one open question from the v1 design spec (section 17); Spike 5 belongs to the v2 design (progress visibility). Run them on the machines named under each spike, then relay what each one writes (spikes 1 to 4: one JSON file, which you paste into the Claude Code session or attach; spike 5: a whole folder). The plan is then adjusted where an answer needs it, so there is nothing to read or judge yourself.

## Before you start (spikes 1 to 4; Spike 5 has its own rules below)

- **Copy the folder `tools\spikes` to the test machine** (a USB stick is fine), for example to `C:\spikes`.
- **Open PowerShell as administrator.** Right-click PowerShell, choose "Run as administrator". If you don't, the script says so and stops.
- **Every command below is run from that elevated window.** Nothing asks you a question, so you can walk away while it runs.
- **Every script writes its result to `C:\BenTechSpike\`** (the folder is created for you). Send back the file named under "Send back".
- **Use a VM checkpoint** for spikes 1 to 3. The scripts install Chrome or Store apps and change settings. Roll the checkpoint back when you're done.
- **Spikes 1 to 4 never go on a customer machine.** They are for testing only and are never part of the final tool. **Spike 5 is the exception:** it is list-only and made for customer Dell and HP laptops that came in for setup (it installs nothing except, with `-InstallTool`, Dell Command Update itself). It writes into its own `capture-...` folder, not into `C:\BenTechSpike\`.

---

## Spike 1: Does Chrome become the default browser from the policy?

**Question:** on a PC that isn't joined to a domain, does the `DefaultAssociationsConfiguration` policy make Chrome the default browser at the next sign-in?

**Which machine:** three VMs, each a fresh install with a local account and no domain. Run the whole spike on each one.
- Windows 11 25H2 **Pro**
- Windows 11 25H2 **Home**
- Windows 10 22H2 **Pro**

**How to run it** (two parts, with a reboot in between):

1. Part 1, as administrator:
   ```
   powershell -ExecutionPolicy Bypass -File C:\spikes\Spike-DefaultBrowser.ps1 -Phase Apply
   ```
   It installs Chrome if it's missing, writes the settings file and sets the policy. It ends by printing: `Reboot, sign in, then run -Phase Check`.
2. Reboot the VM and sign in. Use the **same Windows account** as in part 1.
3. Part 2, as administrator (open it from that same account):
   ```
   powershell -ExecutionPolicy Bypass -File C:\spikes\Spike-DefaultBrowser.ps1 -Phase Check
   ```
   It records which browser Windows now treats as the default, then removes the policy again.

Don't open Settings or change the default browser yourself between the two parts. That would spoil the answer.

**Send back (one per VM, note which VM it came from):** `C:\BenTechSpike\default-browser-result.json`

**What the result changes:**
- Task 12 (default-browser step) and Task 16 (Finalize fallback).
- If Chrome is the default after sign-in on a VM, the policy works on that Windows edition and the step stays as it is.
- If it isn't, the step stays too (it's harmless), but that Windows edition relies on the yellow "press B to open Default Apps" fallback on the final screen.

---

## Spike 2: Does Windows Update offer the 25H2/26H2 upgrade, and how is it labelled?

**Question:** when the tool searches Windows Update on a fresh machine, do the 25H2/26H2 "enablement package" updates show up, and with which `BrowseOnly` and category values?

**Which machine:** a fresh VM that has never been through Windows Update (take the first run right after install, before any updates). Best:
- Windows 11 24H2 (Pro or Home), which should be offered 25H2.
- Windows 11 25H2, if you have one, to see whether 26H2 is offered.
- Optional: Windows 10 22H2, to see how the Windows 11 upgrade offer is labelled.

The VM needs internet. **The script installs nothing.** It only registers Microsoft Update and searches four times, so it can take 5 to 15 minutes.

**How to run it:**
```
powershell -ExecutionPolicy Bypass -File C:\spikes\Spike-WuaSearch.ps1
```

**Send back (one per VM, note which VM it came from):** `C:\BenTechSpike\wua-result.json`

**What the result changes:**
- Task 14 (Windows Update search), the `BrowseOnly` and Upgrades handling.
- If the enablement package appears with `BrowseOnly=0`, the search stays as written.
- If it appears only with `BrowseOnly=1`, a third search for the Upgrades category is added. In plan terms: **if the 25H2/26H2 enablement package only appears with `BrowseOnly=1`, Task 14 needs a third search (Upgrades category, `BrowseOnly=1`).** The script already counts the updates in the Upgrades category for each of its four searches.
- If it doesn't appear at all, the spec is updated to say that feature updates are left to Windows itself.

---

## Spike 3: Can Store apps install without a Microsoft account?

**Question:** on a fresh machine with only a local account, can `winget install --source msstore` install Dell SupportAssist, Lenovo Vantage and MyASUS without signing in?

**Which machine:** a fresh Windows 11 VM, **signed in with a local account only** (no Microsoft account). It needs internet. The three apps stay installed afterwards, so roll the checkpoint back when you're done.

**How to run it:**
```
powershell -ExecutionPolicy Bypass -File C:\spikes\Spike-StoreInstall.ps1
```
It tries the three apps one after another (each can take several minutes) and records every exit code. It also records whether a Microsoft account is signed in. It never records the account name.

If the installs fail, an extra run helps: sign in to the VM's Microsoft Store with a Microsoft account, run the script again, and send both result files. That shows whether the sign-in is the cause.

**Send back:** `C:\BenTechSpike\store-result.json` (if you run it twice, rename the second one first, for example `store-result-signed-in.json`).

**What the result changes:**
- Task 13 (consumer-app install) and the `vendors.*.consumerApp` entries in `config/config.json`.
- If the apps install without an account, nothing changes.
- If they don't, Store-based consumer apps become "Skipped: install it from the Store", and you're told before v1.

---

## Spike 4: Does Lenovo System Update work on consumer Lenovo laptops?

**Question:** does Lenovo System Update cover consumer lines (IdeaPad, Yoga) as well as business ThinkPads, and what does it report back?

**Three more questions** (added after the Lenovo step was built; the code makes an assumption for each until they are answered):
- **Does `tvsu /CM` accept `-packagetypes 1,2`?** The on-battery variant relies on it to keep firmware and BIOS packages out (ruling R21). If tvsu rejects the parameter, the Lenovo battery run fails visibly (red) instead of flashing, and the argument needs another form.
- **Which reboot types do BIOS/firmware packages use on this model?** The AC variant installs reboot types 1, 3 and 5 and never type 4 (forced shutdown); the battery variant leaves out type 5. A BIOS or firmware package that carries type 1 or 3 would slip past the reboot-type filter, which is why `-packagetypes` exists.
- **Which registry view does tvsu read `AdminCommandLine` from?** tvsu is a 32-bit program. The tool currently writes the value to both the 64-bit and the `WOW6432Node` policy keys (ruling R19) and removes both afterwards. Once the answer is known, the unused view can be dropped.

The spike script as it stands lists the available packages (search only) and dumps every property of every `Lenovo_Updates` record, which may show each package's type and reboot type. It does not test `-packagetypes` or watch the registry yet; those two need a small extension of `Spike-LenovoSystemUpdate.ps1` (a second search-only run with `-packagetypes 1,2` added, and a registry-access trace of `tvsu.exe`).

**Which machine:** a **real Lenovo laptop** (not a VM). Run it on two of them if you can:
- an IdeaPad or Yoga (consumer),
- a ThinkPad (business).

Keep the laptop on AC power and connected to the internet. The script stops with a message if the machine isn't a Lenovo.

**How to run it:**
```
powershell -ExecutionPolicy Bypass -File C:\spikes\Spike-LenovoSystemUpdate.ps1
```
It installs Lenovo System Update if it isn't there, then runs it in **search-only mode**. It doesn't install any driver or BIOS update. It waits until the Lenovo processes have finished (up to 45 minutes). Lenovo System Update stays installed afterwards. To remove it, run `winget uninstall --id Lenovo.SystemUpdate` from an administrator window.

**Send back (one per laptop, note which model it was):** `C:\BenTechSpike\lenovo-result.json`

**What the result changes:**
- Task 13 (Lenovo update step): the way the result is read and the "this model isn't supported" signal.
- If System Update reports updates on the consumer laptop, the result parsing is built from the real property names in the JSON.
- If it reports nothing on consumer models, the Lenovo path switches to the LSUClient fallback, with the same function signature.
- The three extra questions: if `-packagetypes` is rejected, the battery variant in Task 13 gets another way to keep firmware out; the reboot types decide the `-includerebootpackages` lists; the registry view decides which `AdminCommandLine` key is kept.

---

## Spike 5: What do the Dell and HP tools list, and what do their logs look like?

**Question:** on a real Dell and a real HP laptop, what does the vendor's update tool list (Dell Command Update's scan, HP Image Assistant's list), and what do the report files and logs look like? The answer decides how the setup tool will read the Dell and HP driver lists and show per-update status (v2 design, [sections 4.5, 7 and 9.3](specs/2026-10-20-progress-visibility-design.md)).

**Which machine:** **one Dell and one HP laptop** that come through the shop, **before** the setup tool runs on them. Keep each on AC power and online. This one is meant for customer laptops, so it only **lists**.

**How to run it** from the USB stick, in an administrator window:
```
powershell -ExecutionPolicy Bypass -File E:\spikes\Spike-DriverListCapture.ps1
```
- On a **Dell without Dell Command Update**, add `-InstallTool`. The script then installs `Dell.CommandUpdate.Universal` with winget (the package the setup tool installs anyway). Without the switch it stops and prints how to run it again.
- On an **HP**, nothing needs installing: HP Image Assistant is portable. The script downloads it, checks the HP signature, extracts it under `%TEMP%\BenTechCapture` and runs it from there. The script deletes nothing (each run extracts into a fresh `HPIA-<date and time>` folder), so delete `%TEMP%\BenTechCapture` by hand when you are done.
- It works out the brand itself and stops with a message on any other laptop.
- It takes about **5 minutes** (Dell Command Update's scan and HP Image Assistant's analysis each take a few minutes). Every run is cut off after `-TimeoutMinutes` (20 by default). Nothing asks a question, so you can walk away.

**What it never does:** apply, download or install a driver or update, change a setting, write the registry, touch BIOS or firmware, or restart the PC. On battery it still runs (the list is the same; it only notes that the PC was on battery).

**What it writes:** a folder `capture-<DELL or HP>-<serial>-<date and time>` next to the script (so on the stick, if you run it from there; `-OutRoot <folder>` picks another place). Inside: `report\` (the tool's own report files), `logs\` (the tool's output and the vendor logs it copied) and `capture.json` (machine, tool, the command line and exit code, the copied files, any errors, and the inventory below). `capture.json` is written even when something failed.

**Send back:** the **whole `capture-...` folder** (zip it if that is easier), one per laptop, saying which model it was.

**After the setup run on the same laptop** (two more things to send back):
1. Run the script **once more with `-InventoryOnly`**:
   ```
   powershell -ExecutionPolicy Bypass -File E:\spikes\Spike-DriverListCapture.ps1 -InventoryOnly
   ```
   It skips the Dell/HP tool (Dell Command Update may already be removed by then) and only records the brand's **services, Start-menu shortcuts and Store packages**. Those are the `verify` values for the vendor-app check (v2 design, section 9.3). The inventory is part of every run, so the first capture also shows what was on the laptop before setup; the second one shows what the setup run left behind.
2. Take **`dcu-pass1.log`** (Dell) or the **`HPIA-pass1` folder** (HP) from the stick's `BenTech-Logs\<PC name>` folder (Task 15 of the v2 plan). Until that task ships, they are in `C:\BenTech\Setup\Logs` on the laptop. They hold what the apply run logged (v2 design, section 7).

**What the result changes:**
- The Dell and HP list readers: which report fields and log lines exist and how to read them.
- The NOW line's per-update status during a vendor pass, and the report's "Driver updates" section (build order A, a later plan).
- The `verify` entries for the Dell and HP consumer apps in `config/config.json` (service names and Start-menu entries from the inventory).

---

## Quick reference

| Spike | Machine | Command (as administrator) | Send back |
|---|---|---|---|
| 1 Default browser | 3 VMs: Win 11 Pro, Win 11 Home, Win 10 Pro | `...\Spike-DefaultBrowser.ps1 -Phase Apply`, reboot, sign in, then `-Phase Check` | `default-browser-result.json` |
| 2 Windows Update search | Fresh VM, before any updates | `...\Spike-WuaSearch.ps1` | `wua-result.json` |
| 3 Store apps | Fresh Win 11 VM, local account only | `...\Spike-StoreInstall.ps1` | `store-result.json` |
| 4 Lenovo System Update | Real Lenovo laptops (IdeaPad/Yoga and ThinkPad) | `...\Spike-LenovoSystemUpdate.ps1` | `lenovo-result.json` |
| 5 Dell and HP driver lists | One real Dell and one real HP laptop, **before** setup (list only) | `...\Spike-DriverListCapture.ps1` (Dell without Dell Command Update: add `-InstallTool`); after the setup run, again with `-InventoryOnly` | the whole `capture-...` folder (+ `dcu-pass1.log` / `HPIA-pass1` after setup) |

Spikes 1 to 4: all commands start with `powershell -ExecutionPolicy Bypass -File C:\spikes\` and all result files are in `C:\BenTechSpike\`. Spike 5 runs from the USB stick (`E:\spikes\`) and writes a `capture-...` folder next to the script.
