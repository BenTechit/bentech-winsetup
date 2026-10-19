# CLAUDE.md: bentech-winsetup

Zero-touch Windows post-install setup tool for Ben's repair shop (BENTECH IT). A signed `.cmd` launcher downloads and verifies `setup.ps1` + `config.json` from this repo's latest GitHub Release and runs them as admin on customer PCs. **It runs as admin on other people's machines: every change is judged by that.**

This is a PowerShell project. Ben's global rules for Node/TypeScript, the API envelope, Hebrew-first UI and RTL do **not** apply here: the console UI is English and ASCII only (spec section 5). His review, planning and outward-facing rules do apply (below).

## Stack
- Windows PowerShell **5.1 only**. No modules, no dependencies on target machines. Pester 5.5+ on the dev PC only.
- Targets: Windows 11 25H2/26H2 Home/Pro (main), Windows 10 22H2 (best effort), x64 (ARM64 best effort).
- Launcher: ASCII-only polyglot `.cmd` (CRLF). Data lives in `config/config.json`.

## Hard rules (Global Constraints, condensed)
- **Never parse localized output** (Hebrew Windows). Use exit codes, CIM, registry values, GUIDs, SIDs. The one exception: hex values in `powercfg /query`.
- Every `.ps1` is **UTF-8 with BOM** (the file-writing tool emits none: re-save; `tests/Encoding.Tests.ps1` enforces it). `.gitattributes` marks `*.ps1`, `*.json`, `*.cmd`, `*.xml` as `-text`: Git must never rewrite line endings.
- Downloads: `System.Net.WebClient` + TLS 1.2. **Never `Invoke-WebRequest`** (it prompts without `-UseBasicParsing`).
- Every child process goes through `Invoke-External` with a timeout from `config.timeoutsMinutes`.
- Steps never prompt: no `Read-Host`, no `-Confirm`, no `pause`. Nothing may stop and wait.
- Console text is English; report dates are `dd/MM/yyyy HH:mm`. No secrets anywhere, no customer PII beyond machine identity.
- Signature scheme: RSA-3072, PKCS#1 v1.5, SHA-256, detached `<file>.sig` over the **raw bytes**. Verify fails closed.
- Working folder `C:\BenTech\Setup`; resume task `BenTechSetup-Resume`. `C:\BenTech` is admin-only, created by the launcher, **never repaired and never ACL'd recursively** (R28b/R28c): an existing one is verified or the launcher refuses (exit 5).

## Step contract and shapes
- Every step is `Invoke-Step<Name> -Context <hashtable>` and returns `New-StepResult` (`Status` Done/Skipped/Failed/Continue, `Message`, `Reboot` None/Now, `Notes` = yellow, `Errors` = red, `Data`). Always set a `Message` on Skipped/Failed. `Continue` means "call me again".
- Steps are listed in `src/Engine/Catalog.ps1`; a new step needs a catalog entry, its `Invoke-Step*` function, a `$BundleOrder` entry in `tools/Build-Bundle.ps1` (when it is a new file) and tests.
- **State** (`state.json`) shape: `New-RunState` in `src/State/State.ps1` and "Shared shapes" in the plan. Keep step `Data` shallow (`ConvertTo-Json -Depth 12` truncates silently); the key `Interruptions` is reserved by the runner.
- Context: `@{ Config; State; Root; LogDir; DownloadDir; ScriptPath; StatePath }`.
- `Get-StepPlan` returns plain ids (no comma-wrapping). `$PSScriptRoot` is empty in `param()` defaults of a `[CmdletBinding()]` script on 5.1: resolve it in the body.

## Sign and publish flow (R29)
- Private key: `%USERPROFILE%\.bentech-winsetup\signing-key.dpapi` (DPAPI, never in the repo). Public key: `keys/public-key.xml`, built into every launcher. **The private-key backup MUST be in Ben's password manager before the first publish; verify it** (README "Signing key" has the procedure). The private key must never be written to a file outside the DPAPI store (except a short-lived `-BackupPath` file such as `bentech-signing-key-BACKUP.xml`, in a non-synced folder, deleted permanently as soon as the password manager holds the key), and never put in a synced folder, a repo, or a chat. Moving it into the password manager through the clipboard is the intended route (README procedure, with Windows clipboard history and sync OFF).
- `tools/Publish.ps1 -Version yyyy.MM.dd.N [-Notes ..] [-DryRun]`: needs a clean tree and a pushed HEAD (warnings only under `-DryRun`), runs the tests, builds the bundle, signs, verifies, builds the launcher, then `gh release create v<Version> --target <HEAD>` with exactly **four** files (`setup.ps1`, `config.json` and their `.sig`).
- **R29: the launcher is never uploaded.** It is the trust anchor (it holds the public key). Publish prints its SHA-256 and records it in `keys/launcher.sha256`; Ben keeps `dist\BenTechSetup.cmd` on his USB stick and re-copies it only when that hash changes (new key or changed template). Commit the updated hash file.
- R30: the launcher calls `powershell.exe` and `fltmc.exe` by full path.
- Launcher exit codes: 0 ok, 1 unexpected error, 2 already running, 3 signature check failed, 4 cannot download, 5 cannot secure `C:\BenTech`.
- Rollback: `gh release edit v<old> --latest`. A lost key means a new key and a new launcher on every stick.

## Never on the dev PC
- **Never run setup steps, `setup.ps1` or the launcher on this machine.** They reboot, uninstall apps, change power plans, ACLs, BitLocker and policies. Tests mock everything (registry, CIM, Task Scheduler, icacls, WUA COM, `Invoke-External`).
- **Outward-facing actions need Ben's explicit OK at that moment:** creating the public repo, `git push`, publishing a Release. Never run `gh repo`, `gh release`, `git push` or `Publish.ps1` without `-DryRun` on your own.

## Tests and commits
- `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` (or one file). **Pass = the last line reads `Failed: 0`.**
- Conventional commits (`feat:`, `fix:`, `test:`, `docs:`, `chore:`). Review gate before every commit; run the `code-review` command before a PR (Ben's rules).
- Things only a real machine can prove are listed in `docs/testing.md`. Add to it whenever something is verified by mocks only.

## Where things live
- Spec (binding): `docs/specs/2026-10-18-bentech-winsetup-design.md`
- Plan: `docs/superpowers/plans/2026-10-18-bentech-winsetup.md` (Global Constraints, File Structure, Shared shapes)
- Spikes (open research, SPIKE#1-4): `docs/spikes.md`; scripts in `tools/spikes/`
- Test checklist for VMs and real laptops: `docs/testing.md`
- Decision ledger (local only, not in the repo; read its "Ruling" lines, they changed behaviour relative to the plan): `.superpowers/sdd/2026-10-18-bentech-winsetup/progress.md`, with the Global Constraints beside it in `global-constraints.md`
