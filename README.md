# bentech-winsetup

Zero-touch Windows post-install setup by BENTECH IT. Ben double-clicks one launcher file on a freshly installed PC, accepts the UAC prompt and walks away. The tool survives any number of reboots, installs the standard apps, runs the vendor driver tool and Windows Update until nothing is left, and finishes on a full-screen green, yellow or red result with the AnyDesk ID in big digits.

The launcher (`BenTechSetup.cmd`) is tiny and rarely changes. It downloads the newest signed `setup.ps1` and `config.json` from this repo's latest GitHub Release, verifies the signatures against the public key built into the launcher, and only then runs them. Updating the tool means publishing a release, never re-copying a file to the USB stick (usually; see [Publishing](#publishing-a-new-version)).

Design: [docs/specs/2026-10-18-bentech-winsetup-design.md](docs/specs/2026-10-18-bentech-winsetup-design.md) (the spec is binding). Plan: [docs/superpowers/plans/2026-10-18-bentech-winsetup.md](docs/superpowers/plans/2026-10-18-bentech-winsetup.md). Test checklist: [docs/testing.md](docs/testing.md). Open research questions: [docs/spikes.md](docs/spikes.md).

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
9. **7-Zip** and **Microsoft 365** (Hebrew + English), optional.
10. **Chrome as default browser** (best effort, checked at the end).
11. **Vendor drivers + BIOS, pass 1** for Dell, Lenovo and HP (laptops and brand-name desktops).
12. **Windows Update** in rounds, with reboots, until the search comes back empty (capped).
13. **Vendor drivers + BIOS, pass 2**, for what only became applicable after Windows Update.
14. **Vendor consumer app** on laptops (SupportAssist, Vantage, HP Support Assistant, MyASUS, ...), then the business updater is removed if the consumer app installed.
15. **Finalize**: final power settings, cleanup, `Setup-Report.txt`, the final screen.

## Daily use

1. **Put the launcher on a USB stick formatted exFAT or FAT32**: copy `dist\BenTechSetup.cmd` to the stick (see [Publishing](#publishing-a-new-version) for when to re-copy it). exFAT/FAT32 files carry no Mark-of-the-Web, so there is no SmartScreen warning. Spaces, Hebrew letters and apostrophes in the launcher's path are fine.
2. **On the fresh PC**: finish OOBE with a local account (no password), connect to the internet, double-click `BenTechSetup.cmd`, click **Yes** on the UAC prompt.
3. **The start screen** counts down 10 seconds, then starts by itself. Keys:

   | Key | Does |
   |---|---|
   | `L` / `D` | Laptop / Desktop mode (auto-detected; a VM defaults to Desktop) |
   | `Z` | 7-Zip on/off |
   | `O` | Office cycles OFF, BUSINESS, HOME |
   | `Enter` | Start now |
   | `Esc` | Cancel: no setup step runs, and any leftover resume task is removed. What the launcher already put in `C:\BenTech\Setup` stays: `setup.ps1`, `config.json` and `Logs\` |

   Any toggle resets the countdown to 10 s. On battery a yellow line warns that BIOS updates are skipped unless you plug in. If the PC does not look like a fresh install (Windows older than 14 days, or more than 1 GB in Desktop/Documents/Downloads) there is no countdown: press Enter to run anyway.
4. **Walk away.** The machine reboots by itself (15 s countdown on screen), logs in by itself and carries on. Nothing asks for input.
5. **Come back to the final screen.** The whole console is green, yellow or red. Press **B** to open Default Apps for Chrome (the screen suggests it when Chrome is not the default), **R** to open the report in Notepad, any other key closes it.

### What the colours mean

| Colour | Banner | Meaning |
|---|---|---|
| GREEN | `SETUP COMPLETE` | Every step done, no notes. |
| YELLOW | `COMPLETE - CHECK NOTES` | No failures, but something needs a look: a step skipped (unsupported model, Store sign-in needed, ARM64), Chrome is not the default, Windows not activated (or its status could not be read), BitLocker still decrypting, Windows 10 (no security updates), a Lenovo result that could not be verified, power settings or the resume task that could not be put back. |
| RED | `COMPLETED WITH ERRORS` | A step failed or never finished, a Windows update was hidden after repeated failures, a cap was hit (reboots or update rounds), the drive is still encrypted, or a restart was refused. |

Each failed or skipped step is listed with a one-line reason.

### Where things are

| What | Where |
|---|---|
| Report | `C:\BenTech\Setup\Logs\Setup-Report.txt` |
| Our log | `C:\BenTech\Setup\Logs\setup.log` |
| Console transcripts | `C:\BenTech\Setup\Logs\transcript-<time>.txt` |
| Vendor tool logs and reports | `C:\BenTech\Setup\Logs\` |
| Run state | `C:\BenTech\Setup\state.json` (older runs: `Logs\state-<RunId>.json`) |

`Downloads\`, the pinned `setup.ps1` and `config.json` are deleted at the end. `Logs\` stays.

**Open the logs with R on the final screen or from an elevated prompt** (for example `notepad C:\BenTech\Setup\Logs\setup.log` in an administrator Terminal). Never browse to `C:\BenTech` in Explorer: its "You don't currently have permission... Continue" button adds your own account to the folder's permissions, and the next run then refuses the folder with exit code 5 (it is no longer admin-only), so you would have to delete it, logs included.

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

A red screen reads `Setup crashed: <message> - see C:\BenTech\Setup\Logs`. Press a key to close it. The resume task stays registered, so after a crash outside a step the next logon shows the same crash again until it is fixed.

1. Read the tail of `Logs\setup.log` and the newest `Logs\transcript-*.txt`. The log has the stack trace.
2. Fix it in the repo and publish a new release, or re-run if it looks transient.
3. **Re-run:** double-click the launcher again. It downloads the newest release, archives the old state to `Logs\state-<RunId>.json`, resets the counters, and runs every step again. Steps that were already done finish in seconds. The start screen shows `Previous run: <date> - <result>`.
4. To stop the retries without running again: double-click the launcher and press **Esc**. That removes the leftover resume task and runs no step (the launcher's fresh `setup.ps1`, `config.json` and the `Logs\` folder stay in `C:\BenTech\Setup`).

An unreadable `state.json` (power cut mid-write) is archived as `Logs\state.corrupt-<time>.json` and a new run starts by itself.

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

Edit it, run the tests (they check that the remove and protect lists don't overlap and that every signer reference exists), commit, push, publish. No launcher update is needed. Keep it UTF-8 and valid JSON.

## Open spikes

Four small research scripts in `tools\spikes\` answer open questions that need real machines. Until they are run, the code uses the plan's defaults. Details, commands and what to send back: [docs/spikes.md](docs/spikes.md).

| # | Question |
|---|---|
| 1 | Does the `DefaultAssociationsConfiguration` policy make Chrome the default on a workgroup Win 11 Pro, Home and Win 10 Pro? (Otherwise the yellow B fallback is the only way.) |
| 2 | Does Windows Update offer the 25H2/26H2 enablement package, and with which `BrowseOnly` value? |
| 3 | Can `winget install --source msstore` install SupportAssist, Vantage and MyASUS with no Microsoft account? |
| 4 | Does Lenovo System Update cover IdeaPad/Yoga, what does it report back, and how does `tvsu` take its parameters? |

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
