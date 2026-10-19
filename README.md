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

1. **Put the launcher on a USB stick formatted exFAT or FAT32**: copy `dist\BenTechSetup.cmd` to the stick (see [Publishing](#publishing-a-new-version) for when to re-copy it). exFAT/FAT32 files carry no Mark-of-the-Web, so there is no SmartScreen warning. Keep it in the stick's root or a folder whose path has no apostrophe (an apostrophe breaks the elevation line).
2. **On the fresh PC**: finish OOBE with a local account (no password), connect to the internet, double-click `BenTechSetup.cmd`, click **Yes** on the UAC prompt.
3. **The start screen** counts down 10 seconds, then starts by itself. Keys:

   | Key | Does |
   |---|---|
   | `L` / `D` | Laptop / Desktop mode (auto-detected; a VM defaults to Desktop) |
   | `Z` | 7-Zip on/off |
   | `O` | Office cycles OFF, BUSINESS, HOME |
   | `Enter` | Start now |
   | `Esc` | Cancel: nothing changes and any leftover resume task is removed |

   Any toggle resets the countdown to 10 s. On battery a yellow line warns that BIOS updates are skipped unless you plug in. If the PC does not look like a fresh install (Windows older than 14 days, or more than 1 GB in Desktop/Documents/Downloads) there is no countdown: press Enter to run anyway.
4. **Walk away.** The machine reboots by itself (15 s countdown on screen), logs in by itself and carries on. Nothing asks for input.
5. **Come back to the final screen.** The whole console is green, yellow or red. Press **B** to open Default Apps for Chrome (the screen suggests it when Chrome is not the default), **R** to open the report in Notepad, any other key closes it.

### What the colours mean

| Colour | Banner | Meaning |
|---|---|---|
| GREEN | `SETUP COMPLETE` | Every step done, no notes. |
| YELLOW | `COMPLETE - CHECK NOTES` | No failures, but something needs a look: a step skipped (unsupported model, Store sign-in needed, ARM64), Chrome is not the default, Windows not activated, BitLocker still decrypting, Windows 10 (no security updates). |
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
4. To stop the retries without running again: double-click the launcher and press **Esc**. That removes the leftover resume task and changes nothing else.

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

**The very first publish** needs the GitHub repo `BenTechit/bentech-winsetup` to exist (public: it holds only the public key and no secrets), the branch pushed with an upstream, and `gh auth status` logged in. Creating the repo and publishing are outward-facing, so do them deliberately.

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
- **Backup:** the key can be lost with the PC or the Windows profile. Generate it with a backup, move that plain-text XML into the **password manager**, then delete the file:

  ```
  powershell -File tools\New-SigningKey.ps1 -BackupPath "$env:USERPROFILE\Desktop\bentech-signing-key-BACKUP.xml"
  ```
- **Restore on a new PC or profile** (same key, so no launcher change): put the XML from the password manager in a file, then store it DPAPI-protected for the new user:

  ```
  . tools\Signing.ps1
  Save-PrivateKeyXml -Path "$env:USERPROFILE\.bentech-winsetup\signing-key.dpapi" -PrivateKeyXml (Get-Content <backup.xml> -Raw)
  ```

  Delete the plain-text file afterwards. A `Publish.ps1 -DryRun` proves the restored key matches `keys\public-key.xml` (it verifies both signatures).
- **If the key is lost:** no new release can be signed for the existing launchers. Run `tools\New-SigningKey.ps1 -BackupPath ...` again (it refuses to overwrite, so move any old `signing-key.dpapi` away and delete `keys\public-key.xml` yourself first), commit the new public key, publish a release, and copy the **new launcher to every USB stick**. Old launchers will refuse every new release with exit 3; that is the design.

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
