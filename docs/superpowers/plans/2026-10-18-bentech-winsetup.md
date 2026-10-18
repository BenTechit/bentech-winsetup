# BenTech Windows Setup Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a zero-touch Windows post-install tool. Ben double-clicks `BenTechSetup.cmd`, accepts UAC once, and the machine sets itself up across reboots, ending on a green, yellow or red result screen.

**Architecture:**
- **Launcher.** A tiny ASCII `.cmd`/PowerShell polyglot. It elevates, downloads the newest **signed** `setup.ps1` + `config.json` from the latest GitHub Release, verifies their RSA signatures against an embedded public key, and runs them from an admin-only `C:\BenTech\Setup`.
- **`setup.ps1`.** One bundled Windows PowerShell 5.1 script, built from small `src/` files. It runs a fixed catalog of idempotent steps through a runner that persists `state.json`, so it can reboot and resume through a logon scheduled task.
- **Data lives in `config.json`:** URLs, IDs, signers, lists, caps and timeouts.

**Tech Stack:**
- Target machines: Windows PowerShell 5.1 (inbox), .NET Framework 4.8 crypto, CIM/WMI, the Windows Update Agent COM API, winget, Task Scheduler.
- Dev machine: Pester 5.5+ and the `gh` CLI.

**Spec:** `docs/specs/2026-10-18-bentech-winsetup-design.md`. Executors read the spec and this plan together.

## Global Constraints

**Runtime and platform**
- **Runtime:** Windows PowerShell **5.1** only, with **no modules or dependencies at runtime** on target machines.
- **Targets:** Windows 11 25H2/26H2 Home/Pro are the main target. Windows 10 22H2 is best effort. x64 is required; ARM64 is best effort.
- **Never parse localized command output.** Machines may run Hebrew Windows. Use exit codes, CIM, registry values, GUIDs and SIDs only. The one exception: in `powercfg /query` output, read **only** the hex values (Task 10).

**Paths and names**
- **Working folder:** `C:\BenTech\Setup`, containing `Logs\`, `Downloads\`, `state.json`, `run.lock`, `setup.ps1`, `config.json`.
- **Scheduled task:** `BenTechSetup-Resume`.
- **Launcher file:** `BenTechSetup.cmd`. It must be ASCII-only with CRLF line endings.

**Files and encoding**
- Every `.ps1` is saved **UTF-8 with BOM**.
- `.gitattributes` marks `*.ps1`, `*.json` and `*.cmd` as `-text`, so Git never rewrites line endings.

**Downloads and signatures**
- Downloads use `System.Net.WebClient`.
- **Never** call `Invoke-WebRequest`. Without `-UseBasicParsing` it prompts since KB5074596.
- TLS 1.2 is forced: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`.
- Signature scheme: **RSA-3072, PKCS#1 v1.5, SHA-256**, as a detached `<file>.sig` over the **raw bytes**.
- The private key lives at `%USERPROFILE%\.bentech-winsetup\signing-key.dpapi`. It is **never** stored in the repo.

**Step contract**
- Every step is `Invoke-Step<Name> -Context <hashtable>` and returns `New-StepResult`.
- Steps never prompt: no `Read-Host`, no `-Confirm`, no `pause`.
- Any child process runs through `Invoke-External` with a timeout from `config.timeoutsMinutes`.

**Text, data and safety**
- **Console text is English.** Report dates use the format `dd/MM/yyyy HH:mm`.
- **No secrets** anywhere. No customer PII beyond machine identity (model, serial, PC name).
- **Ben's rules apply:**
  - A review gate before every commit: the reviewer subagent in subagent-driven mode.
  - **Outward-facing actions need Ben's explicit OK at that moment:** creating the public GitHub repo, pushing, publishing a Release.

**Tests and commits**
- Run tests with `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path <tests file or folder>`. **Pass** = the last line reads `Failed: 0`.
- Commit messages are conventional (`feat:`, `test:`, `chore:`, `docs:`) and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Repo root:** a new folder `bentech-winsetup`. Proposed location: `C:\Users\BenTech\Documents\AI\bentech-winsetup`, next to Ben's other projects. Move this spec and plan into its `docs/`.

## Review Focus

The five likeliest real-world inputs that no task's tests would otherwise cover, most likely first. Each line names the task that owns its pinning test.

1. **Hebrew-display Windows.** Localized `powercfg` labels, localized group names, localized WU category names. Expected behaviour: everything still works.
   - Task 10: power parsing uses a Hebrew-label fixture, and the ACL uses SIDs.
   - Task 14: WU filtering uses category **GUIDs**.
2. **A user name or path with Hebrew letters or spaces** (`C:\Users\בן גולדנברג`). Expected behaviour: the resume task and child processes still launch.
   - Task 10: task-definition quoting test.
   - Task 8: `Invoke-External` with a path that contains spaces.
3. **A laptop on battery, or the charger pulled mid-run.** Expected behaviour: no BIOS or firmware flashing, and the run continues.
   - Task 13: argument builders exclude BIOS/firmware when `-OnAC:$false`.
4. **A power cut or forced reboot while `state.json` is being written.** Expected behaviour: the next start archives the broken file and starts clean, without crashing.
   - Task 4: truncated-JSON test and atomic-save test.
5. **A second double-click while a run (or its resume) is active.** Expected behaviour: *"Setup is already running on this machine"*, and nothing is overwritten.
   - Task 4: lock tests.
   - Task 18: launcher lock test.

---

## File Structure

```
bentech-winsetup/
  .gitattributes  .gitignore  README.md  CLAUDE.md
  config/config.json                  # all data (URLs, IDs, signers, lists, caps, timeouts)
  keys/public-key.xml                 # RSA public key (<RSAKeyValue>), committed
  launcher/BenTechSetup.template.cmd  # polyglot launcher with {{BASE_URL}} / {{PUBLIC_KEY_XML}}
  src/Common/StepResult.ps1           # New-StepResult
  src/Common/Logging.ps1              # Initialize-SetupLog, Write-SetupLog
  src/Common/Config.ps1               # Read-SetupConfig, Get-Signers
  src/Common/Signature.ps1            # Test-DetachedSignature
  src/Common/Process.ps1              # Invoke-External, Convert-MsiExitCode
  src/Common/Download.ps1             # Get-RemoteFile, Get-RemoteText, Find-LatestLink, Test-FileSignature
  src/State/State.ps1                 # run state (json), archive, lock
  src/Detect/Detection.ps1            # machine facts, brand, laptop/VM, AC power, fresh-install
  src/Detect/PcName.ps1               # New-PcName
  src/Engine/Catalog.ps1              # step catalog + Get-StepPlan
  src/Engine/Verdict.ps1              # Get-RunVerdict
  src/Engine/Reboot.ps1               # pending-reboot signals, controlled reboot
  src/Engine/Runner.ps1               # Invoke-SetupRun
  src/Steps/Winget.ps1  Prepare.ps1  BitLocker.ps1  Region.ps1  Desktop.ps1  Bloatware.ps1
  src/Steps/Rename.ps1  Apps.ps1  Office.ps1  DefaultBrowser.ps1  Vendor.ps1  WindowsUpdate.ps1  Finalize.ps1
  src/Report/Report.ps1               # Format-SetupReport and its data collectors
  src/UI/StartScreen.ps1  ProgressScreen.ps1  FinalScreen.ps1
  src/Entry/Param.ps1                 # the bundle's param() block only
  src/Entry/Main.ps1                  # Start-BenTechSetup (+ the call at bundle end)
  tools/Invoke-Tests.ps1  Signing.ps1  New-SigningKey.ps1  Sign-File.ps1
  tools/Build-Bundle.ps1  Build-Launcher.ps1  Publish.ps1  publish.settings.json
  tools/spikes/*.ps1                  # throwaway spike scripts for Ben's test machines
  tests/*.Tests.ps1  tests/fixtures/*
  docs/specs/…  docs/superpowers/plans/…  docs/spikes.md  docs/testing.md
```

## Shared shapes (defined once, used everywhere)

**StepResult** (Task 1):
```
[pscustomobject]@{
  Status  = 'Done'|'Skipped'|'Failed'|'Continue'
  Message = <string>
  Reboot  = 'None'|'Now'
  Notes   = <string[]>
  Errors  = <string[]>
  Data    = <hashtable>
}
```
- `Continue` means "call me again". It's used by the Windows Update rounds and by the two Finalize phases.
- `Notes` are yellow-level messages and `Errors` are red-level messages. The runner appends both to the state.

**Machine** (Task 5), returned by `Get-MachineInfo`:
```
@{ Manufacturer; Model; FriendlyModel; Brand; Serial; BiosUuid; ChassisTypes; IsLaptop; IsVM;
   Arch='x64'|'ARM64'; OsCaption; OsBuild(int); OsDisplayVersion; IsWindows10; InstallDate(ISO string);
   ComputerName; NewName }
```

**Choices** (Task 15):
```
@{ Mode='LAPTOP'|'DESKTOP'; SevenZip=<bool>; Office='OFF'|'BUSINESS'|'HOME' }
```

**State** (Task 4). Saved as `state.json`, and held in memory as nested hashtables:
```
@{ SchemaVersion=1; Version; RunId; StartedAt; EndedAt=$null; Machine; Choices; Plan=<string[]>;
   Steps=@{ <id>=@{ Status='pending'|'running'|'Done'|'Skipped'|'Failed'; Attempts=0; Message='';
                    StartedAt=$null; EndedAt=$null; Data=@{} } };
   RebootCount=0; RebootCapHit=$false; FinalRebootDone=$false;
   WuFailureCounts=@{}; HiddenUpdateIds=@(); PreviousHiddenUpdateIds=@();
   Notes=@(); Errors=@(); AnyDeskId=$null; Power=@{ Original=@{} };
   PreviousRun=$null | @{ StartedAt; Color } }
```

**Context** (Task 7), passed to every step:
```
@{ Config; State; Root='C:\BenTech\Setup'; LogDir; DownloadDir; ScriptPath; StatePath }
```

---

### Task 1: Repo scaffold, test runner, StepResult, logging, config

**Files:**
- Create: `.gitattributes`, `.gitignore`, `README.md` (one paragraph for now), `tools/Invoke-Tests.ps1`, `src/Common/StepResult.ps1`, `src/Common/Logging.ps1`, `src/Common/Config.ps1`, `config/config.json`
- Test: `tests/Common.Tests.ps1`, `tests/Config.Tests.ps1`

**Interfaces:**
- Produces:
  - `New-StepResult -Status <string> [-Message <string>] [-Reboot <string>='None'] [-Notes <string[]>] [-Errors <string[]>] [-Data <hashtable>] -> pscustomobject` (shape above). An invalid `Status` or `Reboot` throws.
  - `Initialize-SetupLog -LogDirectory <string>`: sets `$script:SetupLogPath = <dir>\setup.log` and creates the dir.
  - `Write-SetupLog -Message <string> [-Level 'INFO'|'WARN'|'ERROR'='INFO'] [-Data <hashtable>]`: appends `yyyy-MM-dd HH:mm:ss [LEVEL] message {compressed json of Data}` as UTF-8. It is a no-op when the log isn't initialized.
  - `Read-SetupConfig -Path <string> -> pscustomobject`: throws `"config missing key: <name>"` if any top-level key from the list below is missing.
  - `Get-Signers -Config <obj> -Key <string> -> string[]`, i.e. `$Config.signers.<Key>`.

- [ ] **Step 1: Scaffold the repo.**
  - Create the folder and run `git init`.
  - `.gitattributes`:
    ```
    *.ps1 -text
    *.json -text
    *.cmd -text
    *.xml -text
    ```
  - `.gitignore`: `dist/`, `*.dpapi`, `TestResults/`.
  - Install Pester on the dev machine if it's missing: `powershell -NoProfile -Command "Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck"`.
- [ ] **Step 2: Write `tools/Invoke-Tests.ps1`.**
  - Signature: `param([string]$Path = "$PSScriptRoot\..\tests")`.
  - Runs `Import-Module Pester -MinimumVersion 5.5.0`.
  - Then `$r = Invoke-Pester -Path $Path -Output Detailed -PassThru`.
  - Prints `"Failed: $($r.FailedCount)"` as the last line and exits with `$r.FailedCount`.
- [ ] **Step 3: Write `config/config.json` exactly as below.** These are the spec's values. Spike results may change some IDs or rules later (Task 19, Step 4).

```json
{
  "schemaVersion": 1,
  "defaults": { "sevenZip": true, "office": "BUSINESS" },
  "caps": { "maxReboots": 12, "maxWuRounds": 6, "maxStepAttempts": 3, "wuFailuresBeforeHide": 2 },
  "timeoutsMinutes": { "default": 30, "msi": 20, "office": 60, "vendor": 60, "wuRound": 90,
                       "wingetReady": 5, "bitlockerDecrypt": 120, "anydeskId": 2 },
  "power": { "finalAcMonitorMinutes": 15 },
  "freshInstall": { "maxInstallAgeDays": 14, "maxUserDataGB": 1 },
  "signers": {
    "google": ["Google LLC"], "anydesk": ["AnyDesk Software GmbH"], "microsoft": ["Microsoft Corporation"],
    "dell": ["Dell Inc", "Dell Technologies"], "lenovo": ["Lenovo"], "hp": ["HP Inc"]
  },
  "winget": { "bundleUrl": "https://aka.ms/getwinget" },
  "apps": {
    "chrome": { "signer": "google", "msi": {
      "x64": "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi",
      "ARM64": "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise_arm64.msi" } },
    "anydesk": { "signer": "anydesk", "url": "https://download.anydesk.com/AnyDesk.exe",
                 "installDir": "C:\\Program Files (x86)\\AnyDesk" },
    "sevenZip": { "wingetId": "7zip.7zip" },
    "office": {
      "signer": "microsoft", "odtWingetId": "Microsoft.OfficeDeploymentTool",
      "odtSetupPath": "C:\\Program Files\\OfficeDeploymentTool\\setup.exe",
      "odtFallbackPage": "https://www.microsoft.com/en-us/download/details.aspx?id=49117",
      "odtLinkPattern": "https://download\\.microsoft\\.com/download/[^\"' ]+/officedeploymenttool_[0-9-]+\\.exe",
      "products": { "BUSINESS": "O365BusinessRetail", "HOME": "O365HomePremRetail" },
      "languages": ["he-il", "en-us"], "excludeApps": ["Groove", "Lync"], "channel": "Current", "edition": "64"
    }
  },
  "vendors": {
    "DELL": { "tool": { "kind": "dcu", "wingetId": "Dell.CommandUpdate.Universal", "signer": "dell",
              "exeCandidates": ["C:\\Program Files\\Dell\\CommandUpdate\\dcu-cli.exe",
                                "C:\\Program Files (x86)\\Dell\\CommandUpdate\\dcu-cli.exe"] },
              "consumerApp": { "source": "msstore", "id": "XPDCCXDN26VNBT", "name": "Dell SupportAssist" } },
    "LENOVO": { "tool": { "kind": "lsu", "wingetId": "Lenovo.SystemUpdate", "signer": "lenovo",
                "exeCandidates": ["C:\\Program Files (x86)\\Lenovo\\System Update\\tvsu.exe"] },
                "consumerApp": { "source": "msstore", "id": "9WZDNCRFJ4MV", "name": "Lenovo Vantage" } },
    "HP": { "tool": { "kind": "hpia", "signer": "hp",
            "page": "https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html",
            "linkPattern": "https://hpia\\.hpcloud\\.hp\\.com/downloads/hpia/hp-hpia-[0-9.]+\\.exe" },
            "consumerApp": { "source": "winget", "id": "HP.SupportAssistant", "name": "HP Support Assistant" } },
    "ASUS": { "consumerApp": { "source": "msstore", "id": "9N7R5S6B0ZZH", "name": "MyASUS" } },
    "ACER": { "consumerApp": { "source": "msstore", "id": "9P8BB54NQNQ4", "name": "Acer Care Center S" } },
    "MSI": { "consumerApp": { "source": "msstore", "id": "9NVMNJCR03XV", "name": "MSI Center" } },
    "SURFACE": { "consumerApp": { "source": "msstore", "id": "9WZDNCRFJB8P", "name": "Surface" } }
  },
  "bloatware": {
    "remove": ["Microsoft.MicrosoftSolitaireCollection", "king.com.*", "*CandyCrush*", "*TikTok*",
               "SpotifyAB.SpotifyMusic", "*Disney*", "Clipchamp.Clipchamp", "Microsoft.BingNews",
               "Microsoft.GetHelp", "Microsoft.Getstarted", "Microsoft.WindowsFeedbackHub",
               "MicrosoftCorporationII.MicrosoftFamily", "Microsoft.PowerAutomateDesktop",
               "Microsoft.Windows.DevHome", "MicrosoftTeams"],
    "protect": ["Microsoft.WindowsStore", "Microsoft.DesktopAppInstaller", "Microsoft.Windows.Photos",
                "Microsoft.WindowsCalculator", "Microsoft.WindowsNotepad", "Microsoft.Paint",
                "Microsoft.ScreenSketch", "Microsoft.WindowsCamera", "Microsoft.ZuneMusic",
                "Microsoft.WindowsTerminal", "Microsoft.OutlookForWindows", "Microsoft.MicrosoftEdge*",
                "Microsoft.Copilot", "Microsoft.Xbox*", "Microsoft.GamingApp", "Microsoft.VCLibs*",
                "Microsoft.UI.Xaml*", "Microsoft.NET.*", "Microsoft.WindowsAppRuntime*", "MSTeams"]
  },
  "nags": [
    { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\UserProfileEngagement",
      "name": "ScoobeSystemSettingEnabled", "value": 0 },
    { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
      "name": "SubscribedContent-310093Enabled", "value": 0 }
  ]
}
```

These deviate slightly from the spec and need Ben's OK:
- The Office XML is **generated** from `apps.office` data (Task 12) instead of storing two literal XMLs. Same content, testable.
- **Dell has no direct-download fallback in v1.** Dell's driver-ID URLs aren't stable permalinks.

- [ ] **Step 4: Write the failing tests.**

```powershell
# tests/Common.Tests.ps1
BeforeAll { . "$PSScriptRoot\..\src\Common\StepResult.ps1"; . "$PSScriptRoot\..\src\Common\Logging.ps1" }
Describe 'New-StepResult' {
  It 'defaults Reboot to None and arrays to empty' {
    $r = New-StepResult -Status Done -Message 'ok'
    $r.Reboot | Should -Be 'None'; @($r.Notes).Count | Should -Be 0; @($r.Errors).Count | Should -Be 0
  }
  It 'rejects an unknown status' { { New-StepResult -Status Maybe } | Should -Throw }
  It 'rejects an unknown reboot value' { { New-StepResult -Status Done -Reboot Later } | Should -Throw }
}
Describe 'Write-SetupLog' {
  It 'appends a timestamped line with level and data' {
    $d = Join-Path $TestDrive 'logs'; Initialize-SetupLog -LogDirectory $d
    Write-SetupLog -Message 'hello' -Level WARN -Data @{ step = 'x' }
    (Get-Content "$d\setup.log" -Raw) | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[WARN\] hello \{"step":"x"\}'
  }
}
# tests/Config.Tests.ps1
BeforeAll { . "$PSScriptRoot\..\src\Common\Config.ps1"; $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json" }
Describe 'config.json' {
  It 'has every top-level key' {
    foreach ($k in 'defaults','caps','timeoutsMinutes','power','freshInstall','signers','winget','apps','vendors','bloatware','nags') {
      $cfg.PSObject.Properties.Name | Should -Contain $k }
  }
  It 'pins spec values' {
    $cfg.caps.maxReboots | Should -Be 12; $cfg.caps.maxWuRounds | Should -Be 6
    $cfg.apps.office.products.BUSINESS | Should -Be 'O365BusinessRetail'
    $cfg.apps.office.products.HOME | Should -Be 'O365HomePremRetail'
    $cfg.apps.office.languages[0] | Should -Be 'he-il'
  }
  It 'never removes a protected package' {
    foreach ($r in $cfg.bloatware.remove) { foreach ($p in $cfg.bloatware.protect) { $r | Should -Not -BeLike $p } }
  }
  It 'every signer key referenced exists' {
    $refs = @($cfg.apps.chrome.signer, $cfg.apps.anydesk.signer, $cfg.apps.office.signer) +
            @($cfg.vendors.PSObject.Properties.Value | ForEach-Object { $_.tool.signer } | Where-Object { $_ })
    foreach ($s in $refs) { @(Get-Signers -Config $cfg -Key $s).Count | Should -BeGreaterThan 0 }
  }
  It 'throws on a missing key' {
    '{"defaults":{}}' | Set-Content "$TestDrive\c.json"; { Read-SetupConfig -Path "$TestDrive\c.json" } | Should -Throw '*config missing key*'
  }
}
```

- [ ] **Step 5: Run `tools\Invoke-Tests.ps1 -Path tests`.** Expected: FAIL, because the functions aren't defined yet.
- [ ] **Step 6: Implement** `New-StepResult`, `Initialize-SetupLog`, `Write-SetupLog`, `Read-SetupConfig` and `Get-Signers` with the signatures above.
- [ ] **Step 7: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 8: Commit:** `chore: scaffold repo, test runner, config and step result`.

---

### Task 2: Spike scripts for Ben's test machines

These spikes feed spec §17. They are throwaway: no Pester tests, only a parse check. Ben runs them on test VMs or laptops and relays the JSON files (his delegation protocol). **Build Tasks 3–17 in parallel.** Each spike-dependent spot below is marked `SPIKE#n`.

**Files:**
- Create:
  - `tools/spikes/Spike-DefaultBrowser.ps1`
  - `tools/spikes/Spike-WuaSearch.ps1`
  - `tools/spikes/Spike-StoreInstall.ps1`
  - `tools/spikes/Spike-LenovoSystemUpdate.ps1`
  - `docs/spikes.md`

- [ ] **Step 1: Write `Spike-DefaultBrowser.ps1`.**
  - Parameter: `-Phase Apply|Check`.
  - **Apply:**
    - Installs the Chrome MSI if it's missing.
    - Writes the XML from Task 12's `New-DefaultAssociationsXml` (paste a literal copy) to `C:\BenTechSpike\assoc.xml`.
    - Sets `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System\DefaultAssociationsConfiguration`.
    - Prints `Reboot, sign in, then run -Phase Check`.
  - **Check:**
    - Writes `C:\BenTechSpike\default-browser-result.json`, containing the OS edition and build plus the https/http ProgIds read from `UserChoiceLatest\ProgId` (value `ProgId`), `UserChoiceLatest` and `UserChoice`.
    - Removes the policy value.
- [ ] **Step 2: Write `Spike-WuaSearch.ps1`.**
  - Registers Microsoft Update with `AddService2('7971f918-a847-4430-9279-4a52d1efe18d',7,'')`.
  - Searches `ServerSelection=3` four times: `BrowseOnly=0/1` × `Type='Software'/'Driver'` (plus `IsInstalled=0 and IsHidden=0`). **It installs nothing.**
  - Writes `wua-result.json`. Per update: Title, KBArticleIDs, `Identity.UpdateID`, every category's `CategoryID` + `Name`, `BrowseOnly`, `IsMandatory`, `InstallationBehavior.CanRequestUserInput`.
- [ ] **Step 3: Write `Spike-StoreInstall.ps1`.**
  - For each id in `XPDCCXDN26VNBT`, `9WZDNCRFJ4MV`, `9N7R5S6B0ZZH`: run `winget install --id <id> -e --source msstore --silent --accept-package-agreements --accept-source-agreements --disable-interactivity`.
  - Records the exit code as hex in `store-result.json`, together with whether a Microsoft account is signed in (`HKCU:\Software\Microsoft\IdentityCRL\StoredIdentities` has subkeys).
- [ ] **Step 4: Write `Spike-LenovoSystemUpdate.ps1`.**
  - Installs `Lenovo.SystemUpdate` via winget.
  - Sets `AdminCommandLine` to `/CM -search A -action LIST -noicon -nolicense -exporttowmi`.
  - Runs `tvsu.exe /CM` and waits until no `Tvsukernel`/`tvsu` process remains.
  - Writes `lenovo-result.json`. Contents: the model (`Win32_ComputerSystemProduct.Version`), the tvsu exit code, and **every property** of every instance from `Get-CimInstance -Namespace root\Lenovo -ClassName Lenovo_Updates`.
- [ ] **Step 5: Write `docs/spikes.md`.**
  - For each spike: which machine to use (spec §17), how to run it (elevated `powershell -ExecutionPolicy Bypass -File …`), and which JSON to send back.
  - A "What the result changes" line, pointing to the affected Task and config key.
- [ ] **Step 6: Verify.**
  - Run: `powershell -NoProfile -Command "Get-ChildItem tools\spikes\*.ps1 | % { $e=$null; [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e); if($e){$_.Name; $e} }"`
  - Expected: no output.
- [ ] **Step 7: Commit:** `chore: add spike scripts for default browser, WUA, Store and Lenovo`. Then **tell Ben the spikes are ready to run.**

---

### Task 3: Script signing (verify + key and sign tools)

**Files:**
- Create: `src/Common/Signature.ps1`, `tools/Signing.ps1`, `tools/New-SigningKey.ps1`, `tools/Sign-File.ps1`, `keys/public-key.xml` (generated)
- Test: `tests/Signature.Tests.ps1`

**Interfaces:**
- Produces:
  - `Test-DetachedSignature -Data <byte[]> -Signature <byte[]> -PublicKeyXml <string> -> bool`
    - Uses `RSACryptoServiceProvider.FromXmlString` + `VerifyData($Data, $Signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)`.
    - **Returns `$false` on any exception.**
  - `New-DetachedSignature -Data <byte[]> -PrivateKeyXml <string> -> byte[]` in `tools/Signing.ps1`.
  - `Read-PrivateKeyXml -Path <string> -> string`: DPAPI `CurrentUser` unprotect via `[Security.Cryptography.ProtectedData]`, after `Add-Type -AssemblyName System.Security`.
  - `tools/New-SigningKey.ps1 [-PrivateKeyPath "$env:USERPROFILE\.bentech-winsetup\signing-key.dpapi"] [-PublicKeyOut keys\public-key.xml] [-BackupPath <string>]`
    - Creates a 3072-bit key.
    - Writes the DPAPI-protected private XML to the path above, and the public XML to the output path.
    - **Refuses to overwrite an existing private key.**
  - `tools/Sign-File.ps1 -Path <string> [-PrivateKeyPath "$env:USERPROFILE\.bentech-winsetup\signing-key.dpapi"]`: writes `<Path>.sig`.

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll {
  . "$PSScriptRoot\..\src\Common\Signature.ps1"; . "$PSScriptRoot\..\tools\Signing.ps1"
  $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
  $script:priv = $rsa.ToXmlString($true); $script:pub = $rsa.ToXmlString($false)
  $script:data = [byte[]](0xEF,0xBB,0xBF) + [Text.Encoding]::UTF8.GetBytes("Write-Host 'שלום'`r`n")
}
Describe 'detached signatures' {
  It 'verifies a correct signature' { $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv; Test-DetachedSignature -Data $data -Signature $s -PublicKeyXml $pub | Should -BeTrue }
  It 'rejects one changed byte' { $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv; $d2 = $data.Clone(); $d2[5] = $d2[5] -bxor 1; Test-DetachedSignature -Data $d2 -Signature $s -PublicKeyXml $pub | Should -BeFalse }
  It 'rejects another key' { $o = (New-Object Security.Cryptography.RSACryptoServiceProvider 3072).ToXmlString($false); $s = New-DetachedSignature -Data $data -PrivateKeyXml $priv; Test-DetachedSignature -Data $data -Signature $s -PublicKeyXml $o | Should -BeFalse }
  It 'returns false for garbage' { Test-DetachedSignature -Data $data -Signature ([byte[]](1,2,3)) -PublicKeyXml 'nope' | Should -BeFalse }
  It 'signs a 3072-bit key (384-byte signature)' { (New-DetachedSignature -Data $data -PrivateKeyXml $priv).Length | Should -Be 384 }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL (not defined).
- [ ] **Step 3: Implement** the functions and the two tool scripts per the Interfaces above. `New-SigningKey` prints the next steps: *back up the private key*, and *commit `keys/public-key.xml`*.
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Generate the real key on Ben's PC.**
  - Run: `powershell -File tools\New-SigningKey.ps1 -BackupPath "$env:USERPROFILE\Desktop\bentech-signing-key-BACKUP.xml"`.
  - **Tell Ben to move that backup into his password manager and delete the file.** If the key is lost, every launcher on every USB stick has to be rebuilt.
- [ ] **Step 6: Commit:** `feat: add detached RSA signing and verification`. This includes `keys/public-key.xml` and never the private key.

---

### Task 4: Run state and lock

**Files:**
- Create: `src/State/State.ps1`
- Test: `tests/State.Tests.ps1`

**Interfaces:**
- Consumes: `Write-SetupLog` (Task 1).
- Produces:
  - `ConvertTo-HashtableDeep -InputObject <object> -> object`: PSCustomObjects become hashtables, recursively; arrays stay arrays.
  - `New-RunState -Machine <hashtable> -Choices <hashtable> -Plan <string[]> -Version <string> [-Previous <hashtable>] -> hashtable`
    - Uses the State shape above. Every plan id starts as `pending`.
    - `PreviousHiddenUpdateIds = $Previous.HiddenUpdateIds`.
    - `PreviousRun` stays `$null`. Task 17 fills it in, so this file doesn't depend on the verdict code.
  - `Save-RunState -State <hashtable> -Root <string>`: writes `state.json.tmp` (UTF-8 without BOM, `ConvertTo-Json -Depth 12`), then replaces `state.json` with `[IO.File]::Replace` (or a move when the target is absent).
  - `Read-RunState -Root <string> [-LogDir <string>] -> hashtable|$null`
    - Returns `$null` if the file is absent.
    - On invalid JSON, moves the file to `<LogDir>\state.corrupt-yyyyMMdd-HHmmss.json` and returns `$null`.
  - `Backup-RunState -Root <string> -LogDir <string>`: moves `state.json` to `<LogDir>\state-<RunId>.json`.
  - `Set-StepState -State <hashtable> -StepId <string> -Status <string> [-Message <string>] [-IncrementAttempt] [-ResetAttempts] [-Data <hashtable>]`
    - Sets `StartedAt` (ISO) on `running`, and `EndedAt` on `Done`/`Skipped`/`Failed`.
    - Merges `-Data` into `Steps[id].Data`.
  - `Enter-RunLock -Root <string> -> bool`: returns `$false` if the lock is held; otherwise writes `$PID`.
  - `Exit-RunLock -Root <string>`.
  - `Test-RunLockHeld -Root <string> -> bool`: true only if `run.lock` parses as an int, that process exists, and its name is `powershell` or `pwsh`.

- [ ] **Step 1: Write the failing tests.** These include Review Focus #4 and #5.

```powershell
BeforeAll { . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\State\State.ps1" }
Describe 'run state' {
  BeforeEach { $script:root = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory "$root\Logs" -Force | Out-Null }
  It 'round-trips through json as nested hashtables' {
    $s = New-RunState -Machine @{Brand='DELL'} -Choices @{Mode='LAPTOP';SevenZip=$true;Office='OFF'} -Plan @('prepare','finalize') -Version '2026.10.18.1'
    Save-RunState -State $s -Root $root; $r = Read-RunState -Root $root -LogDir "$root\Logs"
    $r.Steps['prepare'].Status | Should -Be 'pending'; $r.Machine.Brand | Should -Be 'DELL'; $r | Should -BeOfType [hashtable]
  }
  It 'archives truncated json and returns null (power cut mid-write)' {
    '{"SchemaVersion":1,"Steps":{"prep' | Set-Content "$root\state.json"
    Read-RunState -Root $root -LogDir "$root\Logs" | Should -BeNullOrEmpty
    Test-Path "$root\state.json" | Should -BeFalse; @(Get-ChildItem "$root\Logs\state.corrupt-*.json").Count | Should -Be 1
  }
  It 'leaves no tmp file after a save' { Save-RunState -State (New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v') -Root $root; Test-Path "$root\state.json.tmp" | Should -BeFalse }
  It 'counts attempts and stamps times' {
    $s = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'
    Set-StepState -State $s -StepId a -Status running -IncrementAttempt; Set-StepState -State $s -StepId a -Status Done -Message ok
    $s.Steps.a.Attempts | Should -Be 1; $s.Steps.a.EndedAt | Should -Not -BeNullOrEmpty
  }
  It 'carries hidden updates from the previous run' {
    $p = New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v'; $p.HiddenUpdateIds = @('u1')
    (New-RunState -Machine @{} -Choices @{} -Plan @('a') -Version 'v' -Previous $p).PreviousHiddenUpdateIds | Should -Be @('u1')
  }
}
Describe 'run lock' {
  BeforeEach { $script:root = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory $root | Out-Null }
  It 'is held when the pid is this live powershell' { "$PID" | Set-Content "$root\run.lock"; Test-RunLockHeld -Root $root | Should -BeTrue; Enter-RunLock -Root $root | Should -BeFalse }
  It 'is not held for a dead pid' { '999999' | Set-Content "$root\run.lock"; Test-RunLockHeld -Root $root | Should -BeFalse; Enter-RunLock -Root $root | Should -BeTrue }
  It 'is not held for garbage' { 'abc' | Set-Content "$root\run.lock"; Test-RunLockHeld -Root $root | Should -BeFalse }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement** per the Interfaces above.
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add persistent run state and run lock`.

---

### Task 5: Detection and PC name

**Files:**
- Create: `src/Detect/Detection.ps1`, `src/Detect/PcName.ps1`
- Test: `tests/Detection.Tests.ps1`

**Interfaces:**
- Produces (pure functions first):
  - `Resolve-Brand -Manufacturer <string> -Model <string> -> string`
    - Uses the spec §9.2 table, applied in that order with case-insensitive `-like`.
    - Returns `'VM'` if `Test-IsVirtualMachine` is true; otherwise `'OTHER'` when nothing matches.
  - `Test-IsVirtualMachine -Manufacturer <string> -Model <string> -> bool`. True when:
    - Manufacturer is `Microsoft Corporation` and Model is `Virtual Machine`, or
    - either string contains `VMware`, `VirtualBox`, `innotek`, `QEMU` or `KVM`.
  - `Test-IsLaptop -ChassisTypes <int[]> -PCSystemTypeEx <int> -Batteries <object[]> -> bool`
    - True if any chassis type is in `8,9,10,11,14,30,31,32`.
    - Otherwise true if `PCSystemTypeEx` is `2` or `8`.
    - Otherwise true if any battery has a `Name`/`DeviceID` not matching `*UPS*`.
    - Otherwise false.
  - `Test-FreshInstall -InstallDate <datetime> -UserDataBytes <long> -MaxAgeDays <int> -MaxUserDataGB <double> [-Now <datetime>=(Get-Date)] -> bool`
  - `New-PcName -Brand <string> -Serial <string> -BiosUuid <string> -> string`
    - Brand codes: DELL→`DELL`, LENOVO→`LEN`, HP→`HP`, ASUS→`ASUS`, ACER→`ACER`, MSI→`MSI`, SURFACE→`SURF`, anything else →`PC`.
    - Strip the serial to `[A-Z0-9]`, uppercase.
    - **Junk serial** (empty after strip, all zeros, or matching `TOBEFILLED*|DEFAULTSTRING|SYSTEMSERIALNUMBER|NONE|NA`), or brand VM → `PC-` + the **last 6** hex chars of the BIOS UUID (uppercase).
    - Otherwise `<code>-<serial>`, keeping the **right-most** `15 - code.Length - 1` serial characters.
- Produces (system readers, not unit-tested):
  - `Get-MachineInfo -> hashtable` (Machine shape):
    - CIM: `Win32_ComputerSystem` (Manufacturer, Model, PCSystemTypeEx), `Win32_ComputerSystemProduct` (Version, UUID), `Win32_BIOS` (SerialNumber), `Win32_SystemEnclosure` (ChassisTypes), `Win32_Battery`, `Win32_OperatingSystem` (Caption, BuildNumber, InstallDate).
    - Architecture: `Win32_Processor.Architecture` 12 → `ARM64`, else `x64`.
    - `OsDisplayVersion` from `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DisplayVersion`.
    - `IsWindows10 = OsBuild -lt 22000`.
    - `FriendlyModel` = the `Win32_ComputerSystemProduct.Version` for Lenovo, else Model.
    - `NewName` comes from `New-PcName`.
  - `Test-OnACPower -> bool`: `[System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online'`, after `Add-Type -AssemblyName System.Windows.Forms`.
  - `Get-UserDataBytes -> long`: total size of the Desktop, Documents and Downloads folders.

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll { . "$PSScriptRoot\..\src\Detect\Detection.ps1"; . "$PSScriptRoot\..\src\Detect\PcName.ps1" }
Describe 'Resolve-Brand' {
  It '<m> / <mo> -> <b>' -ForEach @(
    @{m='Dell Inc.';mo='Latitude 5440';b='DELL'}, @{m='LENOVO';mo='21AH';b='LENOVO'}, @{m='HP';mo='EliteBook';b='HP'},
    @{m='Hewlett-Packard';mo='x';b='HP'}, @{m='ASUSTeK COMPUTER INC.';mo='x';b='ASUS'}, @{m='Acer';mo='x';b='ACER'},
    @{m='Micro-Star International Co., Ltd.';mo='x';b='MSI'}, @{m='Microsoft Corporation';mo='Surface Laptop 7';b='SURFACE'},
    @{m='Microsoft Corporation';mo='Virtual Machine';b='VM'}, @{m='VMware, Inc.';mo='VMware7,1';b='VM'},
    @{m='SAMSUNG ELECTRONICS CO., LTD.';mo='x';b='SAMSUNG'}, @{m='To be filled by O.E.M.';mo='x';b='OTHER'},
    @{m='SHP Systems';mo='x';b='OTHER'}) { Resolve-Brand -Manufacturer $m -Model $mo | Should -Be $b }
}
Describe 'Test-IsLaptop' {
  It 'notebook chassis' { Test-IsLaptop -ChassisTypes @(10) -PCSystemTypeEx 1 -Batteries @() | Should -BeTrue }
  It 'desktop chassis' { Test-IsLaptop -ChassisTypes @(3) -PCSystemTypeEx 1 -Batteries @() | Should -BeFalse }
  It 'mobile system type' { Test-IsLaptop -ChassisTypes @(35) -PCSystemTypeEx 2 -Batteries @() | Should -BeTrue }
  It 'desktop with a UPS is not a laptop' { Test-IsLaptop -ChassisTypes @(3) -PCSystemTypeEx 1 -Batteries @([pscustomobject]@{Name='APC UPS';DeviceID='UPS1'}) | Should -BeFalse }
  It 'unknown chassis with a real battery' { Test-IsLaptop -ChassisTypes @(2) -PCSystemTypeEx 1 -Batteries @([pscustomobject]@{Name='Internal';DeviceID='BAT0'}) | Should -BeTrue }
}
Describe 'Test-FreshInstall' {
  $now = Get-Date '2026-10-18'
  It 'fresh' { Test-FreshInstall -InstallDate $now.AddDays(-1) -UserDataBytes 10MB -MaxAgeDays 14 -MaxUserDataGB 1 -Now $now | Should -BeTrue }
  It 'old install' { Test-FreshInstall -InstallDate $now.AddDays(-20) -UserDataBytes 0 -MaxAgeDays 14 -MaxUserDataGB 1 -Now $now | Should -BeFalse }
  It 'lots of user data' { Test-FreshInstall -InstallDate $now -UserDataBytes 2GB -MaxAgeDays 14 -MaxUserDataGB 1 -Now $now | Should -BeFalse }
}
Describe 'New-PcName' {
  It 'brand + serial' { New-PcName -Brand DELL -Serial '7HX2K93' -BiosUuid 'x' | Should -Be 'DELL-7HX2K93' }
  It 'keeps the right-most serial chars within 15' { New-PcName -Brand ASUS -Serial 'N8NRCX03X123456' -BiosUuid 'x' | Should -Be 'ASUS-X03X123456' }
  It 'strips invalid chars' { New-PcName -Brand LENOVO -Serial 'pf-3a b7c' -BiosUuid 'x' | Should -Be 'LEN-PF3AB7C' }
  It 'junk serial uses the uuid tail' { New-PcName -Brand OTHER -Serial 'To be filled by O.E.M.' -BiosUuid '4C4C4544-0037-4810-8058-B7C04F4B3933' | Should -Be 'PC-4B3933' }
  It 'VM uses the uuid tail' { New-PcName -Brand VM -Serial '1234-5678' -BiosUuid 'abcdef12-0000-0000-0000-00000a1b2c3d' | Should -Be 'PC-1B2C3D' }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement** the pure functions, then the system readers.
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
  - Also run `powershell -NoProfile -Command ". .\src\Detect\Detection.ps1; . .\src\Detect\PcName.ps1; Get-MachineInfo | ConvertTo-Json"`. Expected: a sane JSON for Ben's PC.
- [ ] **Step 5: Commit:** `feat: add machine detection and PC name generator`.

---

### Task 6: Step catalog, plan and verdict

**Files:**
- Create: `src/Engine/Catalog.ps1`, `src/Engine/Verdict.ps1`
- Test: `tests/Catalog.Tests.ps1`

**Interfaces:**
- Produces:
  - `$script:StepCatalog`: an ordered array of `@{ Id; Title; Function }`, **in this exact order** (spec §8.3):

    | Id | Title | Function |
    |---|---|---|
    | `prepare` | Prepare machine | `Invoke-StepPrepare` |
    | `bitlocker` | Turn off BitLocker | `Invoke-StepBitLocker` |
    | `region` | Time zone + Hebrew keyboard | `Invoke-StepRegion` |
    | `desktop-icons` | Desktop icons | `Invoke-StepDesktopIcons` |
    | `bloatware` | Remove bloatware | `Invoke-StepBloatware` |
    | `rename` | Rename PC | `Invoke-StepRename` |
    | `winget` | Prepare winget | `Invoke-StepWinget` |
    | `chrome` | Google Chrome | `Invoke-StepChrome` |
    | `anydesk` | AnyDesk | `Invoke-StepAnyDesk` |
    | `7zip` | 7-Zip | `Invoke-StepSevenZip` |
    | `office` | Microsoft 365 | `Invoke-StepOffice` |
    | `default-browser` | Chrome as default browser | `Invoke-StepDefaultBrowser` |
    | `vendor-pass1` | Vendor drivers + BIOS (pass 1) | `Invoke-StepVendorPass1` |
    | `windows-update` | Windows Update | `Invoke-StepWindowsUpdate` |
    | `vendor-pass2` | Vendor drivers + BIOS (pass 2) | `Invoke-StepVendorPass2` |
    | `consumer-app` | Vendor app | `Invoke-StepConsumerApp` |
    | `vendor-cleanup` | Remove business updater | `Invoke-StepVendorCleanup` |
    | `finalize` | Finalize | `Invoke-StepFinalize` |

  - `Get-StepPlan -Machine <hashtable> -Choices <hashtable> -Config <object> -> string[]`. Catalog order, filtered as follows:
    - **`vendor-pass1`/`vendor-pass2`:** only if `Machine.Brand` is `DELL`, `LENOVO` or `HP`.
    - **`consumer-app`:** only if `Choices.Mode -eq 'LAPTOP'` and `Config.vendors.<Brand>.consumerApp` exists.
    - **`vendor-cleanup`:** only if `Choices.Mode -eq 'LAPTOP'` and Brand is `DELL`, `LENOVO` or `HP`.
    - **VM:** never any vendor step.
    - **`7zip`:** only if `Choices.SevenZip`.
    - **`office`:** only if `Choices.Office -ne 'OFF'`.
    - **Mode comes from Choices, never from `Machine.IsLaptop`.**
  - `Get-RunVerdict -State <hashtable> -> @{ Color; Banner; Failures=<string[]>; Notes=<string[]> }`:
    - **`Failures`** collects:
      - every plan step with `Status Failed` (as `"<Title>: <Message>"`)
      - `'Reboot limit reached'` if `RebootCapHit`
      - `"Windows update hidden after repeated failures: <id>"` for each id in `HiddenUpdateIds`
      - every entry of `State.Errors`
    - **`Notes`** collects every plan step with `Status Skipped` (as `"<Title>: <Message>"`) and every entry of `State.Notes`.
    - **Color:**
      - **RED** if any Failures; banner `COMPLETED WITH ERRORS`
      - otherwise **YELLOW** if any Notes; banner `COMPLETE - CHECK NOTES`
      - otherwise **GREEN**; banner `SETUP COMPLETE`

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll {
  . "$PSScriptRoot\..\src\Common\Config.ps1"; . "$PSScriptRoot\..\src\State\State.ps1"
  . "$PSScriptRoot\..\src\Engine\Catalog.ps1"; . "$PSScriptRoot\..\src\Engine\Verdict.ps1"
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  function P($brand, $mode, $z = $true, $o = 'BUSINESS') { Get-StepPlan -Machine @{Brand=$brand} -Choices @{Mode=$mode;SevenZip=$z;Office=$o} -Config $cfg }
}
Describe 'Get-StepPlan' {
  It 'Dell laptop gets everything in order' { (P DELL LAPTOP) -join ',' | Should -Be 'prepare,bitlocker,region,desktop-icons,bloatware,rename,winget,chrome,anydesk,7zip,office,default-browser,vendor-pass1,windows-update,vendor-pass2,consumer-app,vendor-cleanup,finalize' }
  It 'Dell desktop: vendor passes, no consumer app, no cleanup' { $p = P DELL DESKTOP; $p | Should -Contain 'vendor-pass1'; $p | Should -Not -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-cleanup' }
  It 'ASUS laptop: consumer app only' { $p = P ASUS LAPTOP; $p | Should -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-pass1'; $p | Should -Not -Contain 'vendor-cleanup' }
  It 'custom desktop: no vendor steps' { (P OTHER DESKTOP) -match 'vendor|consumer' | Should -BeNullOrEmpty }
  It 'VM in laptop mode: still no vendor steps' { (P VM LAPTOP) -match 'vendor|consumer' | Should -BeNullOrEmpty }
  It 'toggles off' { $p = P DELL LAPTOP $false 'OFF'; $p | Should -Not -Contain '7zip'; $p | Should -Not -Contain 'office' }
}
Describe 'Get-RunVerdict' {
  BeforeEach { $script:s = New-RunState -Machine @{} -Choices @{} -Plan @('chrome','office') -Version 'v'
               $s.Steps.chrome.Status = 'Done'; $s.Steps.office.Status = 'Done' }
  It 'green' { (Get-RunVerdict -State $s).Color | Should -Be 'GREEN' }
  It 'yellow on skipped' { $s.Steps.office.Status = 'Skipped'; $s.Steps.office.Message = 'x'; $v = Get-RunVerdict -State $s; $v.Color | Should -Be 'YELLOW'; $v.Banner | Should -Be 'COMPLETE - CHECK NOTES' }
  It 'yellow on a note' { $s.Notes = @('Windows 10: no security updates'); (Get-RunVerdict -State $s).Color | Should -Be 'YELLOW' }
  It 'red on failed' { $s.Steps.chrome.Status = 'Failed'; (Get-RunVerdict -State $s).Banner | Should -Be 'COMPLETED WITH ERRORS' }
  It 'red on hidden update' { $s.HiddenUpdateIds = @('abc'); (Get-RunVerdict -State $s).Color | Should -Be 'RED' }
  It 'red on reboot cap' { $s.RebootCapHit = $true; (Get-RunVerdict -State $s).Failures | Should -Contain 'Reboot limit reached' }
  It 'red on a state error' { $s.Errors = @('Drive still encrypted'); (Get-RunVerdict -State $s).Color | Should -Be 'RED' }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add step catalog, plan rules and run verdict`.

---

### Task 7: Runner and controlled reboots

**Files:**
- Create: `src/Engine/Reboot.ps1`, `src/Engine/Runner.ps1`
- Test: `tests/Runner.Tests.ps1`

**Interfaces:**
- Consumes: State functions (Task 4), `$script:StepCatalog` (Task 6), `New-StepResult` and `Write-SetupLog` (Task 1).
- Produces:
  - `Get-PendingRebootSignals -> @{ CbsRebootPending; WuRebootRequired; PendingFileRename; ComputerRenamePending }` (all bools):
    - CbsRebootPending: `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending` exists.
    - WuRebootRequired: `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired` exists.
    - PendingFileRename: `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` `PendingFileRenameOperations` is non-empty.
    - ComputerRenamePending: `ComputerName\ComputerName` ≠ `ComputerName\ActiveComputerName`.
  - `Test-PendingReboot -Signals <hashtable> -> bool`: true if any signal is true.
  - `Invoke-ControlledReboot -Context <hashtable> [-CountdownSeconds 15] [-RestartAction <scriptblock>={ Restart-Computer -Force }] -> bool`
    - If `State.RebootCount -ge Config.caps.maxReboots`: sets `RebootCapHit`, saves, returns `$false`.
    - Otherwise: `RebootCount++`, save, write log, show `Restarting in N s ...` once per second, invoke the RestartAction, return `$true`.
  - `New-SetupContext -Config <object> -State <hashtable> -Root <string> -ScriptPath <string> -> hashtable` (Context shape).
  - `Invoke-SetupRun -Context <hashtable> [-Catalog <object[]>=$script:StepCatalog] [-OnProgress <scriptblock>] [-RestartAction <scriptblock>] [-CountdownSeconds 15] -> 'Completed'|'Rebooting'`. For each id in `State.Plan`:
    - **Skip** if the step's status is `Done`, `Skipped` or `Failed`.
    - **Crash cap:** if status is `running` (a crash or forced reboot mid-step) and `Attempts -ge caps.maxStepAttempts`, mark `Failed('attempt cap reached')` and move on.
    - **Before invoking:** set `running`, `-IncrementAttempt`, save, call `OnProgress`.
    - **Invoke** `& $catalogEntry.Function -Context $Context` inside try/catch. An exception becomes `Failed(<exception message>)` and is logged at ERROR with `@{ step = id }`.
    - **Record** the step result: append `Notes`/`Errors` to the State; merge `Data` into the step.
    - **Status `Continue`:**
      - set `pending` with `-ResetAttempts`, then save
      - if `Reboot -eq 'Now'`: when `Invoke-ControlledReboot` returns `$true`, return `'Rebooting'`; when it returns `$false`, mark the step `Failed('reboot cap reached')` and go to the next step
      - otherwise invoke the same step again (loop)
    - **Status `Done`/`Skipped`/`Failed`:** set the status and message, then save. If `Reboot -eq 'Now'` and `Invoke-ControlledReboot` returns `$true`, return `'Rebooting'`.
    - **After the last step:** return `'Completed'`.

- [ ] **Step 1: Write the failing tests.** These use fake steps and a fake catalog.

```powershell
BeforeAll {
  foreach ($f in 'Common\StepResult','Common\Logging','State\State','Engine\Reboot','Engine\Runner') { . "$PSScriptRoot\..\src\$f.ps1" }
  function New-Ctx([string[]]$plan) {
    $root = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory "$root\Logs" -Force | Out-Null
    $st = New-RunState -Machine @{} -Choices @{} -Plan $plan -Version 'v'
    $cfg = [pscustomobject]@{ caps = [pscustomobject]@{ maxReboots = 2; maxStepAttempts = 3 } }
    New-SetupContext -Config $cfg -State $st -Root $root -ScriptPath "$root\setup.ps1"
  }
  $script:cat = @(@{Id='a';Title='A';Function='Step-A'}, @{Id='b';Title='B';Function='Step-B'})
}
Describe 'Invoke-SetupRun' {
  BeforeEach { $script:calls = @(); $script:restarts = 0; $script:rs = { $script:restarts++ } }
  It 'runs in order and completes' {
    function Step-A { param($Context) $script:calls += 'a'; New-StepResult -Status Done }
    function Step-B { param($Context) $script:calls += 'b'; New-StepResult -Status Skipped -Message 'n/a' }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $calls -join '' | Should -Be 'ab'; $c.State.Steps.b.Status | Should -Be 'Skipped'
  }
  It 'saves running + attempt before invoking' {
    function Step-A { param($Context) $d = Get-Content "$($Context.Root)\state.json" -Raw | ConvertFrom-Json; $script:seen = $d.Steps.a; New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $seen.Status | Should -Be 'running'; $seen.Attempts | Should -Be 1
  }
  It 'turns an exception into Failed and continues' {
    function Step-A { param($Context) throw 'boom' }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $c.State.Steps.a.Status | Should -Be 'Failed'; $c.State.Steps.a.Message | Should -Match 'boom'; $c.State.Steps.b.Status | Should -Be 'Done'
  }
  It 'fails a step stuck running at the attempt cap without invoking it' {
    function Step-A { param($Context) $script:calls += 'a'; New-StepResult -Status Done }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.Steps.a.Status = 'running'; $c.State.Steps.a.Attempts = 3
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $calls | Should -BeNullOrEmpty; $c.State.Steps.a.Message | Should -Be 'attempt cap reached'
  }
  It 'loops on Continue without reboot' {
    $script:n = 0; function Step-A { param($Context) $script:n++; if ($script:n -lt 3) { New-StepResult -Status Continue } else { New-StepResult -Status Done } }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Out-Null
    $n | Should -Be 3; $c.State.Steps.a.Status | Should -Be 'Done'
  }
  It 'reboots on Continue+Now and leaves the step pending' {
    function Step-A { param($Context) New-StepResult -Status Continue -Reboot Now }
    $c = New-Ctx @('a','b'); Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Rebooting'
    $restarts | Should -Be 1; $c.State.Steps.a.Status | Should -Be 'pending'; $c.State.RebootCount | Should -Be 1
  }
  It 'fails the step when the reboot cap is reached' {
    function Step-A { param($Context) New-StepResult -Status Continue -Reboot Now }
    function Step-B { param($Context) New-StepResult -Status Done }
    $c = New-Ctx @('a','b'); $c.State.RebootCount = 2
    Invoke-SetupRun -Context $c -Catalog $cat -RestartAction $rs -CountdownSeconds 0 | Should -Be 'Completed'
    $restarts | Should -Be 0; $c.State.RebootCapHit | Should -BeTrue; $c.State.Steps.a.Message | Should -Be 'reboot cap reached'
  }
}
Describe 'Test-PendingReboot' {
  It 'any signal' { Test-PendingReboot -Signals @{CbsRebootPending=$false;WuRebootRequired=$false;PendingFileRename=$false;ComputerRenamePending=$true} | Should -BeTrue }
  It 'none' { Test-PendingReboot -Signals @{CbsRebootPending=$false;WuRebootRequired=$false;PendingFileRename=$false;ComputerRenamePending=$false} | Should -BeFalse }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add step runner with resume, attempt and reboot caps`.

---

### Task 8: Process and download helpers

**Files:**
- Create: `src/Common/Process.ps1`, `src/Common/Download.ps1`
- Test: `tests/Process.Tests.ps1`, `tests/Download.Tests.ps1`, `tests/fixtures/hpia.html`

**Interfaces:**
- Produces:
  - `Invoke-External -FilePath <string> [-ArgumentList <string>] [-TimeoutMinutes <double>=30] [-WorkingDirectory <string>] [-CaptureOutput] -> @{ ExitCode=<int|$null>; TimedOut=<bool>; Output=<string> }`
    - Uses `System.Diagnostics.Process` with `UseShellExecute=$false`.
    - With `-CaptureOutput`, stdout is read asynchronously.
    - **On timeout**, kills the process tree: recursive child PIDs from `Win32_Process.ParentProcessId`, then `Stop-Process -Force`. Returns `ExitCode=$null; TimedOut=$true`.
  - `Convert-MsiExitCode -ExitCode <int> -> 'Done'|'DoneReboot'|'Retry'|'Failed'`: 0 → Done; 3010 and 1641 → DoneReboot; 1618 → Retry; anything else → Failed.
  - `Get-RemoteFile -Url <string> -Destination <string> [-Retries 3] [-BackoffSeconds 5] -> string`
    - `WebClient.DownloadFile` with TLS 1.2.
    - Waits `BackoffSeconds * attempt` between tries.
    - Throws `"download failed after <n> attempts: <url>"`.
  - `Get-RemoteText -Url <string> [-Retries 3] -> string`: UTF-8.
  - `Find-LatestLink -Html <string> -Pattern <string> [-ExcludePattern <string>] -> string|$null`: the first regex match that doesn't match the exclude pattern.
  - `Test-FileSignature -Path <string> -AllowedSigners <string[]> -> bool`: `Get-AuthenticodeSignature` status is `Valid` and `SignerCertificate.Subject -like "*CN=$signer*"` for some allowed signer. Logs the actual subject when it returns false.

- [ ] **Step 1: Write the failing tests.** This includes Review Focus #2: a path with spaces.

```powershell
BeforeAll { . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Process.ps1"; . "$PSScriptRoot\..\src\Common\Download.ps1" }
Describe 'Invoke-External' {
  It 'returns the exit code' { (Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c exit 3').ExitCode | Should -Be 3 }
  It 'runs a file in a path with spaces' {
    $d = Join-Path $TestDrive 'a b'; New-Item -ItemType Directory $d | Out-Null; '@echo hi& exit /b 7' | Set-Content "$d\t t.cmd" -Encoding ASCII
    $r = Invoke-External -FilePath "$d\t t.cmd" -CaptureOutput; $r.ExitCode | Should -Be 7; $r.Output | Should -Match 'hi'
  }
  It 'kills on timeout' { $r = Invoke-External -FilePath 'ping.exe' -ArgumentList '-n 30 127.0.0.1' -TimeoutMinutes 0.03; $r.TimedOut | Should -BeTrue; $r.ExitCode | Should -BeNullOrEmpty }
}
Describe 'Convert-MsiExitCode' {
  It '<c> -> <r>' -ForEach @(@{c=0;r='Done'},@{c=3010;r='DoneReboot'},@{c=1641;r='DoneReboot'},@{c=1618;r='Retry'},@{c=1603;r='Failed'}) { Convert-MsiExitCode -ExitCode $c | Should -Be $r }
}
Describe 'downloads and signatures' {
  It 'copies a file:// url' { 'x' | Set-Content "$TestDrive\src.txt"; Get-RemoteFile -Url ([uri]"$TestDrive\src.txt").AbsoluteUri -Destination "$TestDrive\dst.txt" -BackoffSeconds 0 | Should -Exist }
  It 'throws after retries' { { Get-RemoteFile -Url ([uri]"$TestDrive\missing.txt").AbsoluteUri -Destination "$TestDrive\d2.txt" -Retries 2 -BackoffSeconds 0 } | Should -Throw '*after 2 attempts*' }
  It 'finds the newest HPIA link in the fixture' { Find-LatestLink -Html (Get-Content "$PSScriptRoot\fixtures\hpia.html" -Raw) -Pattern 'https://hpia\.hpcloud\.hp\.com/downloads/hpia/hp-hpia-[0-9.]+\.exe' | Should -Be 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.7.exe' }
  It 'accepts a Microsoft-signed binary' { Test-FileSignature -Path "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -AllowedSigners @('Microsoft') | Should -BeTrue }
  It 'rejects the wrong signer' { Test-FileSignature -Path "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -AllowedSigners @('Google LLC') | Should -BeFalse }
  It 'rejects an unsigned file' { 'x' | Set-Content "$TestDrive\u.exe"; Test-FileSignature -Path "$TestDrive\u.exe" -AllowedSigners @('Microsoft') | Should -BeFalse }
}
```
`tests/fixtures/hpia.html` is a small HTML file whose first link is `https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.7.exe`, followed by an older `…5.3.6.exe` link.

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add process runner with timeouts and signed-download helpers`.

---

### Task 9: winget wrapper and readiness step

**Files:**
- Create: `src/Steps/Winget.ps1`
- Test: `tests/Winget.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-External`, `Get-RemoteFile` (Task 8), `New-StepResult`.
- Produces:
  - `ConvertTo-UInt32ExitCode -ExitCode <long> -> uint32`. Handles both negative int32 and unsigned forms.
  - `Convert-WingetExitCode -ExitCode <long> -> 'Done'|'DoneReboot'|'Skipped'|'SourceReset'|'Failed'`:
    - `0` and `0x8A150061` → Done
    - `0x8A150109` and `0x8A15010B` → DoneReboot
    - `0x8A150014` and `0x8A150010` → Skipped
    - `0x8A15000F` → SourceReset
    - anything else → Failed
  - `Get-WingetInstallArgs -Id <string> [-Source 'winget'|'msstore'='winget'] -> string`. Exactly: `install --id <Id> -e --source <Source> --silent --accept-package-agreements --accept-source-agreements --disable-interactivity`.
  - `Get-WingetPath -> string|$null`: `(Get-Command winget.exe -ErrorAction SilentlyContinue).Source`, else `$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe` if it exists.
  - `Invoke-WingetInstall -Id <string> [-Source <string>] -Context <hashtable> -> StepResult`
    - No winget → `Failed('winget unavailable')`.
    - On `SourceReset`: run `winget source reset --force` once, then retry once.
    - `DoneReboot` → `Done` with `Reboot 'None'` (the WU loop reboots).
    - `Failed` messages include the hex code, e.g. `winget 0x8A15001E`.
  - `Invoke-WingetUninstall -Id <string> -Context <hashtable> -> StepResult`: `uninstall --id <Id> -e --silent --disable-interactivity --accept-source-agreements`.
  - `Invoke-StepWinget -Context -> StepResult`:
    - If `Get-WingetPath` → Done.
    - Else `Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe`, then poll every 15 s up to `timeoutsMinutes.wingetReady`.
    - Else download `winget.bundleUrl` to `Downloads\AppInstaller.msixbundle`, then `Add-AppxPackage -Path` (Windows enforces the package signature), then poll again.
    - Else `Failed('winget unavailable')`.

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll { . "$PSScriptRoot\..\src\Steps\Winget.ps1" }
Describe 'Convert-WingetExitCode' {
  It '<c> -> <r>' -ForEach @(@{c=0;r='Done'},@{c=-1978335135;r='Done'},@{c=0x8A150061;r='Done'},@{c=0x8A150109;r='DoneReboot'},
    @{c=0x8A15010B;r='DoneReboot'},@{c=0x8A150014;r='Skipped'},@{c=0x8A150010;r='Skipped'},@{c=0x8A15000F;r='SourceReset'},@{c=0x8A15001E;r='Failed'}) {
    Convert-WingetExitCode -ExitCode $c | Should -Be $r }
}
Describe 'Get-WingetInstallArgs' {
  It 'winget source' { Get-WingetInstallArgs -Id '7zip.7zip' | Should -Be 'install --id 7zip.7zip -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' }
  It 'msstore source' { Get-WingetInstallArgs -Id '9WZDNCRFJ4MV' -Source msstore | Should -Match '--source msstore' }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add winget wrapper and readiness step`.

---

### Task 10: Prepare step: power, nags, resume task, folder ACL

**Files:**
- Create: `src/Steps/Prepare.ps1`
- Test: `tests/Prepare.Tests.ps1`, `tests/fixtures/powercfg-en.txt`, `tests/fixtures/powercfg-he.txt`

**Interfaces:**
- Produces:
  - `$script:ResumeTaskName = 'BenTechSetup-Resume'`.
  - `$script:PowerSettingMap`: ordered `@{ Name; Sub; Setting }` entries:

    | Name | Sub | Setting |
    |---|---|---|
    | `STANDBYIDLE` | `238c9fa8-0aad-41ed-83f4-97be242c8f20` | `29f6c1db-86da-48c5-9fdb-f2b67b1f44da` |
    | `HIBERNATEIDLE` | `238c9fa8-0aad-41ed-83f4-97be242c8f20` | `9d7815a6-7ee4-497e-8888-515a05f02364` |
    | `VIDEOIDLE` | `7516b95f-f776-4464-8c53-06167f40cc99` | `3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e` |
    | `LIDACTION` | `4f971e89-eebd-4455-a8de-9e59040e7347` | `5ca83367-6e45-459f-a27b-476b1d01c936` |

    `LIDACTION` is **this plan's addition**: closing a laptop lid mid-run must not sleep it. It's set to 0 (do nothing) during setup and restored at the end.
  - `Get-PowerIndexFromQueryOutput -Text <string> -> @{ AC=<int>; DC=<int> }`. AC and DC are the **last two** `0x[0-9a-fA-F]{8}` values in the text, so the localized labels are ignored.
  - `Save-OriginalPowerSettings -State <hashtable>` → `State.Power.Original.<Name> = @{AC;DC}`, read with `powercfg /query SCHEME_CURRENT <sub> <setting>` and captured with `Invoke-External -CaptureOutput`. **Runs only if `Original` is empty**, so a re-run never captures the setup values.
  - `Set-SetupPowerSettings`: every map entry gets AC=0 and DC=0 via `powercfg /setacvalueindex|/setdcvalueindex SCHEME_CURRENT <sub> <setting> 0`, then `powercfg /setactive SCHEME_CURRENT`.
  - `Restore-FinalPowerSettings -State <hashtable> -Config <object>` (spec Q11):
    - **AC:** STANDBYIDLE 0, HIBERNATEIDLE 0, VIDEOIDLE `Config.power.finalAcMonitorMinutes*60`, LIDACTION = original AC.
    - **DC:** every entry restored to its original DC value.
  - `Get-ResumeTaskDefinition -ScriptPath <string> -UserId <string> -> @{ Execute; Argument; UserId; Settings }`:
    - `Execute='powershell.exe'`
    - `Argument="-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Resume"`
    - `Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 5`
  - `Register-ResumeTask -ScriptPath <string>`: `UserId = "$env:USERDOMAIN\$env:USERNAME"`, an `-AtLogOn -User` trigger, a principal with `-LogonType Interactive -RunLevel Highest`, then `Register-ScheduledTask -Force`.
  - `Unregister-ResumeTask` never throws if the task is absent.
  - `Get-SetupFolderAclArgs -Path <string> -> string`: `"<Path>" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F`. These are **SIDs, never localized group names.**
  - `Invoke-StepPrepare -Context -> StepResult`. In order:
    1. icacls the root with the args above.
    2. `Register-ResumeTask -ScriptPath $Context.ScriptPath`.
    3. `Save-OriginalPowerSettings`, then `Set-SetupPowerSettings`.
    4. `HiberbootEnabled=0` at `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power`.
    5. Each `Config.nags` entry: create the key and set the DWORD.
    6. `NoAutoRebootWithLoggedOnUsers=1` at `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`.
    7. Return Done.

- [ ] **Step 1: Capture the fixtures on Ben's PC.**
  - `powercfg /query SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da > tests\fixtures\powercfg-en.txt`
  - For `powercfg-he.txt`, use the same text with Hebrew labels (translate the label words by hand) and keep the hex values as `0x00000708` (AC) and `0x00000384` (DC).
- [ ] **Step 2: Write the failing tests.** These include Review Focus #1 and #2.

```powershell
BeforeAll { . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Process.ps1"; . "$PSScriptRoot\..\src\Steps\Prepare.ps1" }
Describe 'power parsing' {
  It 'reads AC/DC from Hebrew-labelled output' { $r = Get-PowerIndexFromQueryOutput -Text (Get-Content "$PSScriptRoot\fixtures\powercfg-he.txt" -Raw); $r.AC | Should -Be 1800; $r.DC | Should -Be 900 }
  It 'reads English output' { $r = Get-PowerIndexFromQueryOutput -Text (Get-Content "$PSScriptRoot\fixtures\powercfg-en.txt" -Raw); $r.AC | Should -BeOfType [int] }
}
Describe 'resume task definition' {
  It 'quotes a script path with spaces and keeps a Hebrew user id' {
    $d = Get-ResumeTaskDefinition -ScriptPath 'C:\Ben Tech\Setup\setup.ps1' -UserId 'PC-1\בן גולדנברג'
    $d.Argument | Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\Ben Tech\Setup\setup.ps1" -Resume'; $d.UserId | Should -Be 'PC-1\בן גולדנברג'
  }
  It 'runs on battery, never times out, priority 5' {
    $s = (Get-ResumeTaskDefinition -ScriptPath 'C:\x.ps1' -UserId 'a\b').Settings
    $s.DisallowStartIfOnBatteries | Should -BeFalse; $s.StopIfGoingOnBatteries | Should -BeFalse
    $s.ExecutionTimeLimit | Should -Be 'PT0S'; $s.Priority | Should -Be 5; $s.MultipleInstances | Should -Be 'IgnoreNew'
  }
}
Describe 'folder ACL' {
  It 'uses SIDs only' { $a = Get-SetupFolderAclArgs -Path 'C:\BenTech\Setup'; $a | Should -Match '\*S-1-5-32-544:\(OI\)\(CI\)F'; $a | Should -Match '\*S-1-5-18'; $a | Should -Match '/inheritance:r'; $a | Should -Not -Match 'Administrators' }
}
```

- [ ] **Step 3: Run the tests.** Expected: FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 6: Commit:** `feat: add prepare step (power, nags, resume task, folder ACL)`.

---

### Task 11: System steps: BitLocker, region, desktop icons, bloatware, rename

**Files:**
- Create: `src/Steps/BitLocker.ps1`, `src/Steps/Region.ps1`, `src/Steps/Desktop.ps1`, `src/Steps/Bloatware.ps1`, `src/Steps/Rename.ps1`
- Test: `tests/SystemSteps.Tests.ps1`

**Interfaces:**
- Consumes: `New-PcName` (Task 5), `Invoke-External` (Task 8).
- Produces:
  - **BitLocker** (all CIM, namespace `root\cimv2\Security\MicrosoftVolumeEncryption`, class `Win32_EncryptableVolume`, `DriveLetter='C:'`):
    - `Get-BitLockerAction -ConversionStatus <int> -> 'None'|'Decrypt'|'Wait'`: 0 → None; 1, 2, 4, 5 → Decrypt; 3 → Wait.
    - `Get-BitLockerConversionStatus -> int|$null`: `$null` when the class or volume is missing.
    - `Invoke-StepBitLocker -Context`:
      - set `PreventDeviceEncryption=1` at `HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker`
      - `$null` status → `Done('BitLocker not present')`
      - `Decrypt` → `Invoke-CimMethod Decrypt` → `Done('Decryption started')`
      - `Wait` → `Done('Decryption in progress')`
      - `None` → `Done('Not encrypted')`
    - `Wait-BitLockerDecrypted -TimeoutMinutes <int> -> bool`: polls every 30 s.
    - `Suspend-BitLockerOnce`: `Invoke-CimMethod DisableKeyProtectors @{DisableCount=1}`.
  - **Region:**
    - `Merge-LanguageTags -Existing <string[]> -> string[]`: keeps the existing order; appends `en-US` if no tag starts with `en`; appends `he-IL` if no tag starts with `he`.
    - `Invoke-StepRegion -Context`:
      - `Set-TimeZone -Id 'Israel Standard Time'`
      - start the `w32time` service, then run `w32tm.exe /resync /force` (exit code logged only)
      - `Get-WinUserLanguageList`, add the missing tags, `Set-WinUserLanguageList -Force`
      - Done
  - **Desktop:** `Invoke-StepDesktopIcons -Context`. Under both `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel` and `…\ClassicStartMenu`, set `{20D04FE0-3AEA-1069-A2D8-08002B30309D}=0` (This PC) and `{59031a47-3f72-44a7-89c5-5595fe6b30ee}=0` (User's Files). **No Explorer restart.**
  - **Bloatware:**
    - `Select-BloatwareToRemove -PackageNames <string[]> -RemovePatterns <string[]> -ProtectPatterns <string[]> -> string[]`: names matching any remove pattern and **no** protect pattern.
    - `Invoke-StepBloatware -Context`:
      - for each selected name, `Get-AppxPackage -Name` → `Remove-AppxPackage`, and `Get-AppxProvisionedPackage -Online` (DisplayName) → `Remove-AppxProvisionedPackage -Online`
      - per-package failures are logged and counted
      - returns `Done("Removed N")`, plus Note `"Bloatware: M packages could not be removed"` when M > 0
  - **Rename:**
    - `Get-PendingComputerName -> string`, from `HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName`.
    - `Invoke-StepRename -Context`:
      - target = `State.Machine.NewName`
      - if it equals the pending name → `Done('Name already set')`
      - else `Rename-Computer -NewName <target> -Force -ErrorAction Stop` → `Done("Renamed to <target> (applies after restart)")`

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll { foreach ($f in 'BitLocker','Region','Bloatware') { . "$PSScriptRoot\..\src\Steps\$f.ps1" } }
Describe 'Get-BitLockerAction' { It '<s> -> <a>' -ForEach @(@{s=0;a='None'},@{s=1;a='Decrypt'},@{s=2;a='Decrypt'},@{s=3;a='Wait'},@{s=4;a='Decrypt'},@{s=5;a='Decrypt'}) { Get-BitLockerAction -ConversionStatus $s | Should -Be $a } }
Describe 'Merge-LanguageTags' {
  It 'Hebrew-only Windows gets English appended' { Merge-LanguageTags -Existing @('he-IL') | Should -Be @('he-IL','en-US') }
  It 'English-only gets Hebrew appended' { Merge-LanguageTags -Existing @('en-US') | Should -Be @('en-US','he-IL') }
  It 'en-GB counts as English' { Merge-LanguageTags -Existing @('en-GB') | Should -Be @('en-GB','he-IL') }
  It 'no change when both exist' { Merge-LanguageTags -Existing @('he-IL','en-US') | Should -Be @('he-IL','en-US') }
}
Describe 'Select-BloatwareToRemove' {
  It 'removes junk, never protected' {
    $r = Select-BloatwareToRemove -PackageNames @('king.com.CandyCrushSaga','Microsoft.WindowsCalculator','Microsoft.XboxGamingOverlay','MicrosoftTeams','MSTeams') -RemovePatterns @('king.com.*','*CandyCrush*','MicrosoftTeams','Microsoft.Xbox*') -ProtectPatterns @('Microsoft.WindowsCalculator','Microsoft.Xbox*','MSTeams')
    $r | Should -Be @('king.com.CandyCrushSaga','MicrosoftTeams')
  }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add BitLocker, region, desktop icon, bloatware and rename steps`.

---

### Task 12: App steps: Chrome, AnyDesk, 7-Zip, Office, default browser

**Files:**
- Create: `src/Steps/Apps.ps1`, `src/Steps/Office.ps1`, `src/Steps/DefaultBrowser.ps1`
- Test: `tests/Apps.Tests.ps1`

**Interfaces:**
- Consumes: Tasks 8 and 9 helpers, and `Get-Signers`.
- Produces:
  - **Chrome:**
    - `Get-ChromeMsiUrl -Config <object> -Arch <string> -> string`, from `Config.apps.chrome.msi.<Arch>`.
    - `Invoke-StepChrome`:
      - if `"$env:ProgramFiles\Google\Chrome\Application\chrome.exe"` exists → `Done('Already installed')`
      - else download to `Downloads\chrome.msi` → `Test-FileSignature` (google signers), and on failure `Failed('Chrome installer signature check failed')`
      - run `msiexec.exe /i "<msi>" /qn /norestart` (timeout `msi`) → `Convert-MsiExitCode`
      - `Retry` → wait 60 s, at most 3 tries
      - `DoneReboot` → Done
  - **AnyDesk:**
    - `Get-AnyDeskIdFromText -Text <string> -> string|$null`: the first line that is exactly `\s*\d{9,10}\s*`.
    - `Get-AnyDeskIdFromConf -Text <string> -> string|$null`: `ad.anynet.id=(\d{9,10})`.
    - `Get-AnyDeskInstallArgs -InstallDir <string> -> string`: exactly `--install "<InstallDir>" --start-with-win --create-shortcuts --create-desktop-icon --silent --update-auto`.
    - `Invoke-StepAnyDesk`:
      - install if `<installDir>\AnyDesk.exe` is missing (download → signer check → run with the args)
      - poll `AnyDesk.exe --get-id` (`-CaptureOutput`) every 5 s for `timeoutsMinutes.anydeskId`
      - fall back to `%ProgramData%\AnyDesk\service.conf`
      - set `State.AnyDeskId`; no ID → `Done` with Note `'AnyDesk ID not available yet'`
  - **7-Zip:** `Invoke-StepSevenZip` → `Invoke-WingetInstall -Id $Config.apps.sevenZip.wingetId`.
  - **Office:**
    - `New-OfficeConfigXml -ProductId <string> -Languages <string[]> -ExcludeApps <string[]> -Channel <string> -Edition <string> -> string`. Exact output (languages in the given order, one `<ExcludeApp>` per app):
      ```xml
      <Configuration>
        <Add OfficeClientEdition="64" Channel="Current">
          <Product ID="O365BusinessRetail">
            <Language ID="he-il" />
            <Language ID="en-us" />
            <ExcludeApp ID="Groove" />
            <ExcludeApp ID="Lync" />
          </Product>
        </Add>
        <RemoveMSI />
        <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
        <Updates Enabled="TRUE" />
        <Display Level="None" AcceptEULA="TRUE" />
      </Configuration>
      ```
    - `Test-OfficeInstalled -ProductReleaseIds <string> -ProductId <string> -> bool`: comma-separated contains.
    - `Invoke-StepOffice`:
      - product = `Config.apps.office.products.<Choices.Office>`
      - **already installed** if `HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` `ProductReleaseIds` contains it → Done
      - otherwise `Invoke-WingetInstall odtWingetId`, then use `odtSetupPath` if it exists
      - **fallback:** `Get-RemoteText odtFallbackPage` → `Find-LatestLink odtLinkPattern` → download → signer check → `/quiet /extract:"<Downloads>\ODT"`
      - `Test-FileSignature setup.exe` (microsoft signers), write the XML to `Downloads\office.xml`, run `setup.exe /configure "<xml>"` (timeout `office`)
      - exit 0 → Done, else `Failed("Office setup exit <code>")`
  - **Default browser:**
    - `New-DefaultAssociationsXml -ProgId 'ChromeHTML' -ApplicationName 'Google Chrome' -> string`: four `<Association Identifier=… ProgId=… ApplicationName=… Version="1" Suggested="true" />` entries for `.htm`, `.html`, `http`, `https`.
    - `Invoke-StepDefaultBrowser`:
      - Chrome missing → `Skipped('Chrome not installed')`
      - else write `<Root>\DefaultAssociations.xml`, set `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System` `DefaultAssociationsConfiguration` → `Done('Applies at next sign-in')`, with `Data @{ RebootCountAtSet = State.RebootCount }`. Task 16 uses it to decide whether a final reboot is needed.
      - **SPIKE#1:** if Ben's spike shows the policy doesn't work on workgroup/Home, keep this step (harmless) and rely on the Finalize fallback.
    - `Resolve-DefaultBrowserProgId -LatestProgId <string> -LegacyProgId <string> -> string|$null`: the first non-empty.
    - `Get-DefaultBrowserProgId -> string|$null`. Reads, under `HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\`, first `UserChoiceLatest\ProgId` value `ProgId`, then `UserChoiceLatest` value `ProgId`, then `UserChoice` value `ProgId`.
    - `Get-ChromeRegisteredAppName -> string`: the value name under `HKLM:\SOFTWARE\RegisteredApplications` that is like `Google Chrome*`, else `'Google Chrome'`.

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll { foreach ($f in 'Apps','Office','DefaultBrowser') { . "$PSScriptRoot\..\src\Steps\$f.ps1" } . "$PSScriptRoot\..\src\Common\Config.ps1"; $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json" }
Describe 'Chrome/AnyDesk' {
  It 'picks the ARM64 MSI' { Get-ChromeMsiUrl -Config $cfg -Arch ARM64 | Should -Match '_arm64\.msi$' }
  It 'reads an id from --get-id output' { Get-AnyDeskIdFromText -Text "`r`n 123456789 `r`n" | Should -Be '123456789' }
  It 'ignores non-id output' { Get-AnyDeskIdFromText -Text 'Service not running' | Should -BeNullOrEmpty }
  It 'reads an id from service.conf' { Get-AnyDeskIdFromConf -Text "ad.anynet.alias=x`nad.anynet.id=1234567890`n" | Should -Be '1234567890' }
  It 'never sets a password or unattended access' { $a = Get-AnyDeskInstallArgs -InstallDir 'C:\Program Files (x86)\AnyDesk'; $a | Should -Be '--install "C:\Program Files (x86)\AnyDesk" --start-with-win --create-shortcuts --create-desktop-icon --silent --update-auto'; $a | Should -Not -Match 'password' }
}
Describe 'Office' {
  It 'builds the business XML with Hebrew first' {
    $x = [xml](New-OfficeConfigXml -ProductId 'O365BusinessRetail' -Languages @('he-il','en-us') -ExcludeApps @('Groove','Lync') -Channel 'Current' -Edition '64')
    $x.Configuration.Add.Channel | Should -Be 'Current'; $x.Configuration.Add.Product.ID | Should -Be 'O365BusinessRetail'
    $x.Configuration.Add.Product.Language[0].ID | Should -Be 'he-il'; $x.Configuration.Display.AcceptEULA | Should -Be 'TRUE'
    $x.Configuration.Property.Name | Should -Be 'FORCEAPPSHUTDOWN'; $x.Configuration.SelectSingleNode('RemoveMSI') | Should -Not -BeNullOrEmpty
  }
  It 'detects an installed product' { Test-OfficeInstalled -ProductReleaseIds 'O365HomePremRetail,ProofingTools' -ProductId 'O365HomePremRetail' | Should -BeTrue }
}
Describe 'default browser' {
  It 'suggests Chrome for 4 identifiers' { $x = [xml](New-DefaultAssociationsXml -ProgId ChromeHTML -ApplicationName 'Google Chrome'); @($x.DefaultAssociations.Association).Count | Should -Be 4; ($x.DefaultAssociations.Association | ? Identifier -eq 'https').Suggested | Should -Be 'true' }
  It 'prefers UserChoiceLatest' { Resolve-DefaultBrowserProgId -LatestProgId 'ChromeHTML' -LegacyProgId 'MSEdgeHTM' | Should -Be 'ChromeHTML' }
  It 'falls back to legacy' { Resolve-DefaultBrowserProgId -LatestProgId $null -LegacyProgId 'MSEdgeHTM' | Should -Be 'MSEdgeHTM' }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add Chrome, AnyDesk, 7-Zip, Office and default-browser steps`.

---

### Task 13: Vendor steps: silent tools, consumer app, cleanup

**Files:**
- Create: `src/Steps/Vendor.ps1`
- Test: `tests/Vendor.Tests.ps1`

**Interfaces:**
- Consumes: Tasks 8, 9 and 11 (`Wait-BitLockerDecrypted`, `Suspend-BitLockerOnce`), Task 5 (`Test-OnACPower`).

**Produces: exit-code mappers**
- `Convert-DcuExitCode -ExitCode <int> -> 'Done'|'DoneReboot'|'Skipped'|'RetryService'|'Failed'`:
  - 0 and 500 → Done
  - 1 and 5 → DoneReboot
  - 3 and 7 → Skipped
  - 3000–3005 → RetryService
  - anything else → Failed
- `Convert-HpiaExitCode -ExitCode <int> -> 'Done'|'DoneReboot'|'DoneWarning'|'Skipped'|'Retry'|'Failed'`:
  - 0, 256 and 257 → Done
  - 3010 → DoneReboot
  - 3011 → DoneWarning
  - 4096 → Skipped
  - 4098 → Retry
  - anything else, including 3020 → Failed

**Produces: argument builders.** On battery these exclude BIOS/firmware (Review Focus #3).
- `Get-DcuApplyArgs -LogPath <string> -OnAC <bool> -> string`
  - On AC: `/applyUpdates -silent -reboot=disable -outputLog="<LogPath>"`
  - On battery: the same, plus ` -updateType=driver,application,others`
- `Get-HpiaArgs -ReportFolder <string> -DownloadFolder <string> -OnAC <bool> -> string`
  - On AC: `/Operation:Analyze /Category:All /Selection:All /Action:Install /Silent /ReportFolder:"<r>" /SoftpaqDownloadFolder:"<d>" /AutoCleanup`
  - On battery: `/Category:Drivers,Software` instead of `All`
- `Get-LenovoAdminCommandLine -OnAC <bool> -> string`
  - On AC: `/CM -search A -action INSTALL -includerebootpackages 1,3,5 -noreboot -noicon -nolicense -exporttowmi`
  - On battery: `1,3` instead of `1,3,5`

**Produces: steps and helpers**
- `Test-ShouldRemoveBusinessTool -Mode <string> -Brand <string> -ConsumerAppStatus <string> -> bool`: true only for LAPTOP + (DELL|LENOVO|HP) + `Done`.
- `Invoke-VendorPass -Context -Pass <int> -> StepResult`. In order:
  1. If `Wait-BitLockerDecrypted -TimeoutMinutes timeoutsMinutes.bitlockerDecrypt` is false: `Suspend-BitLockerOnce`, then Note `'BitLocker still decrypting: suspended for BIOS update'`.
  2. `$onAC = Test-OnACPower`. If it's false, Note `'On battery: BIOS/firmware updates skipped'`.
  3. Dispatch on `Config.vendors.<Brand>.tool.kind` to `Invoke-DellUpdate`, `Invoke-LenovoUpdate` or `Invoke-HpUpdate`.
  4. Map the result: `DoneReboot` → `Done` + `Reboot 'Now'`; `Skipped` → `Skipped("<tool> does not support this model")`; `DoneWarning` → Done + Note.
- `Invoke-StepVendorPass1` = `Invoke-VendorPass -Pass 1`; `Invoke-StepVendorPass2` = `Invoke-VendorPass -Pass 2`.
- **Rule for `Invoke-DellUpdate` and `Invoke-LenovoUpdate`:** when the winget install returns `Skipped` (no installer for this system, e.g. ARM64), return `Skipped('<tool>: no installer for this system')`.
- `Invoke-DellUpdate -Context -OnAC`:
  - exe = the first existing `exeCandidates`; else winget install `wingetId` and look again; else `Failed('Dell Command Update not found')`.
  - Signer check (dell).
  - Run `/configure -silent -autoSuspendBitLocker=enable` (5 min).
  - Then apply with `LogPath = Logs\dcu-pass<N>.log` (timeout `vendor`).
  - `RetryService` → `Start-Service DellClientManagementService`, retry once.
- `Invoke-LenovoUpdate -Context -OnAC`:
  - tvsu exe via candidates or winget, plus a signer check (lenovo).
  - Set `HKLM:\SOFTWARE\Policies\Lenovo\System Update\UserSettings\General\AdminCommandLine` (REG_SZ) to `Get-LenovoAdminCommandLine`.
  - Run `tvsu.exe /CM`, then wait until no `tvsu`/`Tvsukernel` process remains (within the `vendor` timeout; on timeout kill them → Failed).
  - Copy `C:\ProgramData\Lenovo\SystemUpdate\logs\*` to `Logs\lenovo-pass<N>\`.
  - Read the result from `Get-CimInstance -Namespace root\Lenovo -ClassName Lenovo_Updates`. **SPIKE#4 decides the property names and the "unsupported model" signal.** Until it arrives: no instances → `Done('No Lenovo updates reported')`; any instance whose status text contains `fail` → Failed; otherwise Done, and `DoneReboot` if any instance indicates a reboot.
  - If SPIKE#4 shows that consumer models aren't covered, swap in LSUClient here (spec §9.2) and keep this function's signature.
- `Invoke-HpUpdate -Context -OnAC`:
  - Use `Downloads\HPIA\HPImageAssistant.exe` if it already exists (pass 2).
  - Else `Get-RemoteText page` → `Find-LatestLink linkPattern` → download `Downloads\hp-hpia.exe` → signer (hp) → `/s /e /f "<Downloads>\HPIA"` → signer check on the extracted exe.
  - Run `Get-HpiaArgs` with `ReportFolder = Logs\HPIA-pass<N>` (timeout `vendor`).
  - `Retry` → wait 30 s, then retry once.
  - **Deviation from spec §9.1:** HPIA comes from its download page instead of winget. It's a portable tool, so we get a known path, and removal is just deleting `Downloads`. Ben has been told.
- `Invoke-StepConsumerApp -Context`:
  - `$app = Config.vendors.<Brand>.consumerApp`, then `Invoke-WingetInstall -Id $app.id -Source $app.source`.
  - **SPIKE#3:** when `source -eq 'msstore'` and the result is Failed, return `Skipped("<name>: Store install failed (<hex>), install it from the Store")` instead.
- `Invoke-StepVendorCleanup -Context`:
  - If `-not (Test-ShouldRemoveBusinessTool -Mode $State.Choices.Mode -Brand $State.Machine.Brand -ConsumerAppStatus $State.Steps['consumer-app'].Status)` → `Skipped('Kept: consumer app not installed')`.
  - DELL → `Invoke-WingetUninstall Dell.CommandUpdate.Universal`.
  - LENOVO → uninstall `Lenovo.SystemUpdate`, then remove the `AdminCommandLine` value.
  - HP → `Done('HPIA is portable; removed with Downloads')`.

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll { . "$PSScriptRoot\..\src\Steps\Vendor.ps1" }
Describe 'exit codes' {
  It 'DCU <c> -> <r>' -ForEach @(@{c=0;r='Done'},@{c=500;r='Done'},@{c=1;r='DoneReboot'},@{c=5;r='DoneReboot'},@{c=3;r='Skipped'},@{c=7;r='Skipped'},@{c=3001;r='RetryService'},@{c=2;r='Failed'}) { Convert-DcuExitCode -ExitCode $c | Should -Be $r }
  It 'HPIA <c> -> <r>' -ForEach @(@{c=0;r='Done'},@{c=256;r='Done'},@{c=257;r='Done'},@{c=3010;r='DoneReboot'},@{c=3011;r='DoneWarning'},@{c=3020;r='Failed'},@{c=4096;r='Skipped'},@{c=4098;r='Retry'},@{c=8192;r='Failed'}) { Convert-HpiaExitCode -ExitCode $c | Should -Be $r }
}
Describe 'battery never flashes BIOS/firmware' {
  It 'DCU on AC has no filter' { Get-DcuApplyArgs -LogPath 'C:\L\d.log' -OnAC $true | Should -Be '/applyUpdates -silent -reboot=disable -outputLog="C:\L\d.log"' }
  It 'DCU on battery excludes bios/firmware' { $a = Get-DcuApplyArgs -LogPath 'C:\L\d.log' -OnAC $false; $a | Should -Match '-updateType=driver,application,others'; $a | Should -Not -Match 'bios|firmware' }
  It 'HPIA on battery' { $a = Get-HpiaArgs -ReportFolder 'C:\r' -DownloadFolder 'C:\d' -OnAC $false; $a | Should -Match '/Category:Drivers,Software'; $a | Should -Not -Match 'Category:All' }
  It 'Lenovo on battery drops type 5' { Get-LenovoAdminCommandLine -OnAC $false | Should -Match '-includerebootpackages 1,3 ' }
  It 'Lenovo on AC never includes type 4 (shutdown)' { Get-LenovoAdminCommandLine -OnAC $true | Should -Match '-includerebootpackages 1,3,5 ' }
}
Describe 'cleanup rule' {
  It 'laptop + Dell + app installed' { Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand DELL -ConsumerAppStatus Done | Should -BeTrue }
  It 'keeps the tool when the app was skipped' { Test-ShouldRemoveBusinessTool -Mode LAPTOP -Brand DELL -ConsumerAppStatus Skipped | Should -BeFalse }
  It 'keeps it on desktops' { Test-ShouldRemoveBusinessTool -Mode DESKTOP -Brand HP -ConsumerAppStatus Done | Should -BeFalse }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add vendor driver/BIOS passes, consumer app and cleanup`.

---

### Task 14: Windows Update loop

**Files:**
- Create: `src/Steps/WindowsUpdate.ps1`
- Test: `tests/WindowsUpdate.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-External`, `Read-RunState`, `New-StepResult`.

**Produces: constants**
- `$script:MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'`
- `$script:DefinitionUpdatesCategoryId = 'e0789628-ce08-4437-be74-2495b842f43b'`
- `$script:UpgradesCategoryId = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'`
- Matching is by **GUID, never by category name** (Review Focus #1).

**Produces: pure functions**
- `Get-WuSearchCriteria -Type 'Software'|'Driver' -> string`, i.e. `"IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='<Type>'"`.
- `ConvertTo-WuUpdateInfo -Update <object> -> pscustomobject{ Id; Title; KBs; CategoryIds; CanRequestUserInput }`.
- `Select-WuUpdates -Updates <object[]> -FailureCounts <hashtable> -FailuresBeforeHide <int> -IsWindows10 <bool> -> @{ Install; Hide; Skip; OnlyDefinitions }`:
  - **Skip:** `CanRequestUserInput`, or (`IsWindows10` and the Upgrades category).
  - **Hide:** `FailureCounts[Id] -ge FailuresBeforeHide`.
  - **Install:** everything else.
  - **OnlyDefinitions:** `Install` is non-empty and every item has the definitions category.
- `Get-WuRoundOutcome -Result <object> -> 'Done'|'Continue'`. Done if `Error` is null **and** either:
  - `Installed` and `Failed` are both empty, or
  - `OnlyDefinitions` is true.

  Otherwise Continue.

**Produces: child process (COM, verified on a VM)**
- `Invoke-WuRound -StatePath <string> -ResultPath <string> -FailuresBeforeHide <int> -IsWindows10 <bool> [-SearchOnly]` (`-SearchOnly` stops after step 4 and writes the selection as `Installed` with nothing installed; it's used only by Step 5's smoke test):
  1. Register the Microsoft Update service.
  2. **If this is round 1, un-hide `PreviousHiddenUpdateIds`:** search `IsHidden=1`, then `IsHidden=$false` for matching ids.
  3. Search Software, then Driver.
  4. `Select-WuUpdates`.
  5. Hide the `Hide` updates.
  6. `AcceptEula()` where needed.
  7. Download, then install.
  8. Per-update `GetUpdateResult(i).ResultCode` (2 and 3 = ok; 4 and 5 = failed).
  9. Write JSON to `ResultPath`:
     ```
     { Installed: [{Id,Title}], Failed: [{Id,Title,ResultCode}], Hidden: [Id],
       OnlyDefinitions, RebootRequired, Error }
     ```
     `RebootRequired` = the install result's `RebootRequired` **or** `Microsoft.Update.SystemInfo.RebootRequired`. Any exception goes into `Error`.

**Produces: the parent step**
- `Invoke-StepWindowsUpdate -Context -> StepResult`:
  1. `Data.Rounds++`. If `Rounds -gt caps.maxWuRounds` → `Failed("Windows Update round cap reached ($cap)")`.
  2. Save state.
  3. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<ScriptPath>" -WuRound -ResultPath "<Logs>\wu-round<N>.json"` with timeout `wuRound`. On timeout → `Failed('Windows Update round timed out')`.
  4. Read the JSON. `Error` → `Failed("Windows Update error: <Error>")`.
  5. Update state: `WuFailureCounts[Id]++` for each failed update; append `Hidden` to `HiddenUpdateIds`; `Data.Installed += count`; `Data.FailedTitles[Id] = Title` for each failed update (the report prints hidden updates by title).
  6. Outcome `Done` → `Done("Installed <total> updates in <rounds> rounds")`.
  7. Outcome `Continue` → `Continue`, with `Reboot = RebootRequired ? 'Now' : 'None'`.
- **SPIKE#2:** if the 25H2/26H2 enablement package doesn't appear with `BrowseOnly=0`, add a third search for the Upgrades category with `BrowseOnly=1`. That is still a Select-WuUpdates input, so the pure tests are unchanged.

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll {
  . "$PSScriptRoot\..\src\Steps\WindowsUpdate.ps1"
  function U($id, [string[]]$cats = @(), [bool]$ui = $false) { [pscustomobject]@{ Id=$id; Title=$id; KBs=@(); CategoryIds=$cats; CanRequestUserInput=$ui } }
  $script:defs = 'e0789628-ce08-4437-be74-2495b842f43b'; $script:upg = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'
}
Describe 'Select-WuUpdates' {
  It 'hides an update that failed twice' { $r = Select-WuUpdates -Updates @((U a),(U b)) -FailureCounts @{a=2} -FailuresBeforeHide 2 -IsWindows10 $false; $r.Hide.Id | Should -Be @('a'); $r.Install.Id | Should -Be @('b') }
  It 'skips user-input updates' { (Select-WuUpdates -Updates @((U a @() $true)) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false).Skip.Id | Should -Be @('a') }
  It 'skips the Win11 upgrade on Windows 10 by category GUID' { (Select-WuUpdates -Updates @((U up @($upg))) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $true).Skip.Id | Should -Be @('up') }
  It 'installs the enablement package on Windows 11' { (Select-WuUpdates -Updates @((U up @($upg))) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false).Install.Id | Should -Be @('up') }
  It 'flags definitions-only rounds' { (Select-WuUpdates -Updates @((U d @($defs))) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false).OnlyDefinitions | Should -BeTrue }
}
Describe 'Get-WuRoundOutcome' {
  It 'done when nothing happened' { Get-WuRoundOutcome -Result ([pscustomobject]@{Installed=@();Failed=@();OnlyDefinitions=$false;Error=$null}) | Should -Be 'Done' }
  It 'done when only definitions were installed' { Get-WuRoundOutcome -Result ([pscustomobject]@{Installed=@(@{Id='d'});Failed=@();OnlyDefinitions=$true;Error=$null}) | Should -Be 'Done' }
  It 'continue when something installed' { Get-WuRoundOutcome -Result ([pscustomobject]@{Installed=@(@{Id='a'});Failed=@();OnlyDefinitions=$false;Error=$null}) | Should -Be 'Continue' }
  It 'continue when something failed' { Get-WuRoundOutcome -Result ([pscustomobject]@{Installed=@();Failed=@(@{Id='a'});OnlyDefinitions=$false;Error=$null}) | Should -Be 'Continue' }
}
Describe 'criteria' { It 'drivers' { Get-WuSearchCriteria -Type Driver | Should -Be "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Driver'" } }
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Smoke test on Ben's PC, search only.**
  - Run `Invoke-WuRound` with a temp state and a `-WhatIf`-style switch `-SearchOnly`, which skips hide/download/install. This is the only extra parameter allowed.
  - Expected: a JSON file with `Error = null`.
- [ ] **Step 6: Commit:** `feat: add bounded Windows Update loop over the WUA API`.

---

### Task 15: Screens: start, progress, final

**Files:**
- Create: `src/UI/StartScreen.ps1`, `src/UI/ProgressScreen.ps1`, `src/UI/FinalScreen.ps1`
- Test: `tests/Screens.Tests.ps1`

**Interfaces:**
- Consumes: the Machine/Choices/State shapes, `Get-RunVerdict`, `$script:StepCatalog`.

**Start screen**
- `New-DefaultChoices -Machine <hashtable> -Config <object> -> Choices`:
  - `Mode` = LAPTOP if `IsLaptop` and not `IsVM`, else DESKTOP
  - `SevenZip` = `Config.defaults.sevenZip`
  - `Office` = `Config.defaults.office`
- `Update-StartChoices -Choices <hashtable> -Key <string> -> @{ Choices; Action='None'|'Start'|'Cancel'; ResetCountdown=<bool> }`. Keys are case-insensitive:

  | Key | Effect | Resets the countdown |
  |---|---|---|
  | `L` | Mode = LAPTOP | yes |
  | `D` | Mode = DESKTOP | yes |
  | `Z` | toggles 7-Zip | yes |
  | `O` | cycles Office OFF → BUSINESS → HOME → OFF | yes |
  | `Enter` | Action = Start | no |
  | `Escape` | Action = Cancel | no |
  | anything else | nothing | no |

- `Format-StartScreen -Machine -Choices -SecondsLeft <int> -Version <string> -OnAC <bool> -IsFresh <bool> -Previous <hashtable> -> string[]`. Uses the spec §8.1 layout with these exact strings:
  - Mode line when LAPTOP: `'   MODE   [L] Laptop  <==        [D] Desktop'`
  - Mode line when DESKTOP: `'   MODE   [L] Laptop           [D] Desktop  <=='`
  - 7-Zip line: `'          [Z] 7-Zip                ON'` (or `OFF`)
  - Office line: `'          [O] Office 365 (HE+EN)   BUSINESS   (OFF/BUSINESS/HOME)'`
  - Countdown: `'   Starting in 10s ...  [Enter] start now   [Esc] cancel'`
  - On battery: `'   ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery.'`
  - When not fresh, the countdown line is replaced by `"   This doesn't look like a fresh install: press Enter to run anyway"`
  - With a Previous run: `'   Previous run: <dd/MM/yyyy HH:mm> - <Color>'`
- `Show-StartScreen -Machine <hashtable> -Config <object> -Version <string> -Previous <hashtable|$null> -IsFresh <bool> -> Choices|$null`:
  - starts from `New-DefaultChoices`
  - redraws every second, re-reading `Test-OnACPower`, and polls `[Console]::KeyAvailable` every 100 ms
  - counts down from 10 **only when `IsFresh`**
  - `$null` on Cancel
  - `-Previous` is the summary `@{StartedAt; Color}` built in Task 17

**Progress screen**
- `Format-ProgressScreen -State <hashtable> -Catalog <object[]> -Now <datetime> -> string[]`. One line per plan step: `"  [OK] <Title>"`, `"  [>>] <Title>  (mm:ss)"`, `"  [..] <Title>"`, `"  [X ] <Title> - <Message>"`, `"  [--] <Title> - <Message>"`. **Markers are ASCII** because conhost can't reliably show ✓ and ►. Then `"  Reboots: <n>    Total: <h:mm>"`.
- `Show-ProgressScreen -State -Catalog`: `Clear-Host`, then the lines.

**Final screen**
- `Format-BigDigits -Text <string> -> string[5]`: a 5-row `#` font for `0-9` and space, so the AnyDesk ID is readable from across the room. Each glyph is 5 wide plus a 1-column gap. The glyph table is a builder's choice.
- `Format-FinalScreen -State -Verdict -ReportPath -DefaultBrowserIsChrome <bool> -> string[]`:
  - the banner, centred
  - the machine, new name and serial
  - `AnyDesk ID:` followed by the big digits, grouped 3-3-3 (or `not available`)
  - `"Total time: <h:mm>   Reboots: <n>"`
  - each Failure and each Note
  - the line `"Chrome is not the default browser: press B to open Default Apps, then click 'Set default'"` when `-not DefaultBrowserIsChrome`
  - `"Report: <path>   [R] open report   [any other key] close"`
- `Show-FinalScreen -State <hashtable> -Verdict <hashtable> -ReportPath <string>`:
  - `DefaultBrowserIsChrome` = `(Get-DefaultBrowserProgId) -eq 'ChromeHTML'`, or `$true` when Chrome isn't installed (no hint then)
  - background `DarkGreen`/`DarkYellow`/`DarkRed` by Color, then `Clear-Host` and the lines
  - **B** → `Start-Process "ms-settings:defaultapps?registeredAppMachine=$(Get-ChromeRegisteredAppName)"` (URL-encode the name)
  - **R** → `notepad.exe <report>`
  - any other key → return

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll { foreach ($f in 'StartScreen','ProgressScreen','FinalScreen') { . "$PSScriptRoot\..\src\UI\$f.ps1" }
  $script:m = @{ Manufacturer='Dell Inc.'; FriendlyModel='Latitude 5440'; Serial='7HX2K93'; IsLaptop=$true; IsVM=$false; OsCaption='Windows 11 Pro'; OsDisplayVersion='25H2'; OsBuild=26200; Arch='x64'; NewName='DELL-7HX2K93' } }
Describe 'Update-StartChoices' {
  BeforeEach { $script:c = @{ Mode='LAPTOP'; SevenZip=$true; Office='OFF' } }
  It 'O cycles OFF -> BUSINESS -> HOME -> OFF' { $r = Update-StartChoices -Choices $c -Key 'O'; $r.Choices.Office | Should -Be 'BUSINESS'; $r = Update-StartChoices -Choices $r.Choices -Key 'o'; $r.Choices.Office | Should -Be 'HOME'; (Update-StartChoices -Choices $r.Choices -Key 'O').Choices.Office | Should -Be 'OFF' }
  It 'Z toggles and resets the countdown' { $r = Update-StartChoices -Choices $c -Key 'Z'; $r.Choices.SevenZip | Should -BeFalse; $r.ResetCountdown | Should -BeTrue }
  It 'D switches to desktop' { (Update-StartChoices -Choices $c -Key 'D').Choices.Mode | Should -Be 'DESKTOP' }
  It 'Enter starts, Esc cancels, X does nothing' { (Update-StartChoices -Choices $c -Key 'Enter').Action | Should -Be 'Start'; (Update-StartChoices -Choices $c -Key 'Escape').Action | Should -Be 'Cancel'; $r = Update-StartChoices -Choices $c -Key 'X'; $r.Action | Should -Be 'None'; $r.ResetCountdown | Should -BeFalse }
}
Describe 'Format-StartScreen' {
  It 'shows mode, toggles, countdown' {
    $l = Format-StartScreen -Machine $m -Choices @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'} -SecondsLeft 7 -Version 'v1' -OnAC $true -IsFresh $true -Previous $null
    $l | Should -Contain '   MODE   [L] Laptop  <==        [D] Desktop'; $l | Should -Contain '          [Z] 7-Zip                ON'
    $l | Should -Contain '          [O] Office 365 (HE+EN)   BUSINESS   (OFF/BUSINESS/HOME)'; ($l -join "`n") | Should -Match 'Starting in 7s'
  }
  It 'warns on battery and does not count down when not fresh' {
    $l = Format-StartScreen -Machine $m -Choices @{Mode='DESKTOP';SevenZip=$false;Office='OFF'} -SecondsLeft 10 -Version 'v1' -OnAC $false -IsFresh $false -Previous $null
    $l | Should -Contain '   ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery.'
    ($l -join "`n") | Should -Match "This doesn't look like a fresh install: press Enter to run anyway"; ($l -join "`n") | Should -Not -Match 'Starting in'
  }
}
Describe 'final screen' {
  It 'big digits are 5 rows' { @(Format-BigDigits -Text '123').Count | Should -Be 5 }
  It 'shows the default-browser hint' {
    $st = @{ Machine=$m; AnyDeskId='123456789'; RebootCount=3; StartedAt='2026-10-18T09:00:00'; EndedAt='2026-10-18T10:12:00' }
    $l = Format-FinalScreen -State $st -Verdict @{Color='YELLOW';Banner='COMPLETE - CHECK NOTES';Failures=@();Notes=@('x')} -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $false
    ($l -join "`n") | Should -Match "press B to open Default Apps, then click 'Set default'"; ($l -join "`n") | Should -Match 'COMPLETE - CHECK NOTES'
  }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add start, progress and final screens`.

---

### Task 16: Finalize step and report

**Files:**
- Create: `src/Steps/Finalize.ps1`, `src/Report/Report.ps1`
- Test: `tests/Finalize.Tests.ps1`

**Interfaces:**
- Consumes: Tasks 7, 10, 11, 12 and 6.

**Report**
- `Format-SetupReport -State <hashtable> -Verdict <hashtable> -Activation <string> -BitLockerText <string> -AppVersions <hashtable> -> string[]`. **All dates are `dd/MM/yyyy HH:mm`.** Lines, in order:
  ```
  BenTech Windows Setup - Report
  Tool version : <Version>
  Result       : <Banner>
  Started      : <dd/MM/yyyy HH:mm>
  Finished     : <dd/MM/yyyy HH:mm>
  Duration     : <h:mm>
  Machine      : <Manufacturer> <FriendlyModel>   SN: <Serial>
  PC name      : <ComputerName> -> <NewName>
  Mode         : <Mode> (detected: LAPTOP|DESKTOP|VM)
  Windows      : <OsCaption> <OsDisplayVersion> (<OsBuild>) <Arch>
  Activation   : <Activation>
  BitLocker    : <BitLockerText>
  AnyDesk ID   : <id or 'not available'>
  ```
  Then:
  - `Apps:` followed by `  <name> <version>` lines
  - `Windows Update: <rounds> rounds, <installed> installed, hidden: <titles from Data.FailedTitles (id when no title), or none>`
  - `Steps:` followed by `  <Status padded to 8> <Title> - <Message>` lines
  - `Failures:` and `Notes:` sections when non-empty
- `Get-ActivationStatus -> 'Activated'|'Not activated'|'Unknown'`: CIM `SoftwareLicensingProduct` with `ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' and PartialProductKey is not null`; `LicenseStatus 1` = Activated.
- `Get-InstalledAppVersions -> hashtable`:
  - Chrome, AnyDesk and 7-Zip: `DisplayVersion` from the 64- and 32-bit Uninstall keys, matched by `DisplayName` like `Google Chrome*`, `AnyDesk*`, `7-Zip*`.
  - Office: `VersionToReport` under ClickToRun\Configuration.

**Finalize step**
- `Test-FinalRebootNeeded -Signals <hashtable> -State <hashtable> -> bool`. Spec §8.4: only reboot when needed. True if:
  - `Test-PendingReboot -Signals` is true (this covers the pending rename), **or**
  - the default-browser step is Done and its `Data.RebootCountAtSet -eq State.RebootCount`, meaning nobody has signed in since the policy was set.
- `Invoke-StepFinalize -Context -> StepResult`:
  - **Phase A** (when `FinalRebootDone` is false):
    1. `Restore-FinalPowerSettings`.
    2. Remove `NoAutoRebootWithLoggedOnUsers`.
    3. Set `FinalRebootDone = $true` and save.
    4. If `Test-FinalRebootNeeded (Get-PendingRebootSignals)` is true **and** `RebootCount -lt caps.maxReboots`, return `Continue` + `Reboot 'Now'`.
    5. Otherwise fall through to Phase B in the same call.
  - **Phase B:**
    1. Default browser: if `Get-DefaultBrowserProgId -ne 'ChromeHTML'` and Chrome is installed → Note `'Chrome is not the default browser'`.
    2. Remove the `DefaultAssociationsConfiguration` value and `<Root>\DefaultAssociations.xml`.
    3. Activation: not `Activated` → Note `'Windows not activated'`.
    4. BitLocker:
       - action `Wait` → Note `'BitLocker decryption still running'`
       - action `Decrypt` (still encrypted, not decrypting) → Error `'Drive still encrypted and not decrypting'`
    5. `IsWindows10` → Note `'Windows 10: no security updates'`.
    6. `Unregister-ResumeTask`.
    7. Delete `Downloads\`, `setup.ps1` and `config.json`. **Keep `state.json` and `Logs\`.**
    8. `EndedAt = now`.
    9. Write `Logs\Setup-Report.txt` (UTF-8 BOM), using a verdict computed **after** this step is marked Done.
    10. Return `Done`.
  - Implementation note: Phase B records its notes and errors in the State before computing the report verdict.

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll { foreach ($f in 'Common\StepResult','State\State','Engine\Catalog','Engine\Verdict','Engine\Reboot','Report\Report','Steps\Finalize') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:st = New-RunState -Machine @{ Manufacturer='Dell Inc.'; FriendlyModel='Latitude 5440'; Serial='7HX2K93'; ComputerName='DESKTOP-AB12'; NewName='DELL-7HX2K93'; OsCaption='Windows 11 Pro'; OsDisplayVersion='25H2'; OsBuild=26200; Arch='x64'; IsLaptop=$true; IsVM=$false } -Choices @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'} -Plan @('chrome') -Version '2026.10.18.1'
  $st.StartedAt = '2026-10-18T09:05:00'; $st.EndedAt = '2026-10-18T10:17:00'; $st.AnyDeskId = '123456789'; $st.Steps.chrome.Status = 'Done' }
Describe 'Format-SetupReport' {
  BeforeAll { $script:l = Format-SetupReport -State $st -Verdict (Get-RunVerdict -State $st) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{ 'Google Chrome' = '155.0.8059.85' } }
  It 'uses Israeli dates' { $l | Should -Contain 'Started      : 18/10/2026 09:05'; $l | Should -Contain 'Duration     : 1:12' }
  It 'has identity and AnyDesk' { $l | Should -Contain 'PC name      : DESKTOP-AB12 -> DELL-7HX2K93'; $l | Should -Contain 'AnyDesk ID   : 123456789' }
  It 'has the version and result' { $l | Should -Contain 'Tool version : 2026.10.18.1'; $l | Should -Contain 'Result       : SETUP COMPLETE' }
}
Describe 'Test-FinalRebootNeeded' {
  BeforeAll { $script:none = @{CbsRebootPending=$false;WuRebootRequired=$false;PendingFileRename=$false;ComputerRenamePending=$false} }
  It 'reboots for a pending rename' { $s = @{ Steps=@{}; RebootCount=4 }; Test-FinalRebootNeeded -Signals $none -State $s | Should -BeFalse
    $sig = $none.Clone(); $sig.ComputerRenamePending = $true; Test-FinalRebootNeeded -Signals $sig -State $s | Should -BeTrue }
  It 'reboots when nobody signed in since the browser policy was set' { $s = @{ Steps=@{ 'default-browser' = @{ Status='Done'; Data=@{ RebootCountAtSet=4 } } }; RebootCount=4 }; Test-FinalRebootNeeded -Signals $none -State $s | Should -BeTrue }
  It 'skips the reboot when a reboot already happened after the policy' { $s = @{ Steps=@{ 'default-browser' = @{ Status='Done'; Data=@{ RebootCountAtSet=2 } } }; RebootCount=4 }; Test-FinalRebootNeeded -Signals $none -State $s | Should -BeFalse }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add finalize step and setup report`.

---

### Task 17: Entry point and bundle

**Files:**
- Create: `src/Entry/Param.ps1`, `src/Entry/Main.ps1`, `tools/Build-Bundle.ps1`
- Test: `tests/Bundle.Tests.ps1`

**Interfaces:**
- Produces:
  - `src/Entry/Param.ps1` is exactly `param([switch]$Resume, [switch]$WuRound, [switch]$SearchOnly, [string]$ResultPath)`.
  - `Start-BenTechSetup -Resume <bool> -WuRound <bool> -SearchOnly <bool> -ResultPath <string> -> int` (exit code). Flow:
    1. **`$WuRound`:** `$root='C:\BenTech\Setup'`. Run `Invoke-WuRound -StatePath "$root\state.json" -ResultPath $ResultPath -FailuresBeforeHide (Read-SetupConfig "$root\config.json").caps.wuFailuresBeforeHide -IsWindows10 (Read-RunState $root).Machine.IsWindows10 -SearchOnly:$SearchOnly`; return 0. **This path takes no lock**, because the parent holds it.
    2. `$root='C:\BenTech\Setup'`. `Initialize-SetupLog "$root\Logs"`. `Start-Transcript "$root\Logs\transcript-<yyyyMMdd-HHmmss>.txt"`. `Write-SetupLog "BenTech Windows Setup $script:SetupVersion starting" -Data @{ resume = $Resume }`.
    3. **Lock:** if `-not (Enter-RunLock $root)`, write `Setup is already running on this machine` and return 2.
    4. `$config = Read-SetupConfig "$root\config.json"`.
    5. **Not resuming:**
       - `$prev = Read-RunState`
       - `$prevSummary = if ($prev) { @{ StartedAt = $prev.StartedAt; Color = if ($prev.EndedAt) { (Get-RunVerdict -State $prev).Color } else { 'UNFINISHED' } } }`
       - `$machine = Get-MachineInfo`
       - `$fresh = Test-FreshInstall -InstallDate ([datetime]$machine.InstallDate) -UserDataBytes (Get-UserDataBytes) -MaxAgeDays $config.freshInstall.maxInstallAgeDays -MaxUserDataGB $config.freshInstall.maxUserDataGB`
       - `$choices = Show-StartScreen -Machine $machine -Config $config -Version $script:SetupVersion -Previous $prevSummary -IsFresh $fresh`; `$null` → `Exit-RunLock`, return 0, with **no changes made**
       - if `$prev`, run `Backup-RunState`
       - `$plan = Get-StepPlan -Machine $machine -Choices $choices -Config $config`
       - `$state = New-RunState -Machine $machine -Choices $choices -Plan $plan -Version $script:SetupVersion -Previous $prev`; set `$state.PreviousRun = $prevSummary`; save
    6. **Resuming:** `$state = Read-RunState`. If it's `$null`, `Unregister-ResumeTask`, then return 0.
    7. `$ctx = New-SetupContext -Config $config -State $state -Root $root -ScriptPath "$root\setup.ps1"`. `$r = Invoke-SetupRun -Context $ctx -OnProgress { Show-ProgressScreen -State $ctx.State -Catalog $script:StepCatalog }`.
    8. If `$r -eq 'Rebooting'`, return 0. The lock is not released; the process ends during the restart.
    9. `$verdict = Get-RunVerdict`. `Show-FinalScreen`. `Exit-RunLock`. Return 0.
    10. Wrap the whole flow in try/catch. An unexpected error → `Write-SetupLog ERROR`, then a red screen showing `"Setup crashed: <message> - see C:\BenTech\Setup\Logs"`, and return 1.
  - The last line of `Main.ps1` is `exit (Start-BenTechSetup -Resume:$Resume -WuRound:$WuRound -SearchOnly:$SearchOnly -ResultPath $ResultPath)`.
  - `tools/Build-Bundle.ps1 -Version <yyyy.MM.dd.N> [-OutDir dist]`. It writes `dist/setup.ps1` (UTF-8 **with BOM**, CRLF) as:
    1. `# BenTech Windows Setup <Version>`
    2. the content of `Param.ps1`
    3. `$script:SetupVersion = '<Version>'`
    4. every file in `$BundleOrder`

    `$BundleOrder` is an explicit array listing every `src/**/*.ps1` except the `Entry` files, followed by `src/Entry/Main.ps1` last. The script also copies `config/config.json` to `dist/config.json` byte-for-byte.

- [ ] **Step 1: Write the failing tests.**

```powershell
BeforeAll { $script:out = Join-Path $TestDrive 'dist'; & "$PSScriptRoot\..\tools\Build-Bundle.ps1" -Version '2026.10.18.9' -OutDir $out
  $script:b = [IO.File]::ReadAllBytes("$out\setup.ps1"); $script:tok = $null; $script:err = $null
  $script:ast = [Management.Automation.Language.Parser]::ParseFile("$out\setup.ps1", [ref]$tok, [ref]$err) }
Describe 'bundle' {
  It 'is UTF-8 with BOM' { $b[0..2] | Should -Be @(0xEF,0xBB,0xBF) }
  It 'parses without errors' { $err | Should -BeNullOrEmpty }
  It 'has the param block first' { $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Be @('Resume','WuRound','SearchOnly','ResultPath') }
  It 'stamps the version' { [Text.Encoding]::UTF8.GetString($b) | Should -Match "\`$script:SetupVersion = '2026\.10\.18\.9'" }
  It 'includes every src file' { $order = (Get-Content "$PSScriptRoot\..\tools\Build-Bundle.ps1" -Raw)
    Get-ChildItem "$PSScriptRoot\..\src" -Recurse -Filter *.ps1 | ForEach-Object { $order | Should -Match ([regex]::Escape($_.Name)) } }
  It 'defines every catalog function' { . "$PSScriptRoot\..\src\Engine\Catalog.ps1"; $names = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
    foreach ($s in $script:StepCatalog) { $names | Should -Contain $s.Function } }
  It 'copies config byte-for-byte' { (Get-FileHash "$out\config.json").Hash | Should -Be (Get-FileHash "$PSScriptRoot\..\config\config.json").Hash }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement** `Param.ps1`, `Main.ps1` and `Build-Bundle.ps1`.
- [ ] **Step 4: Run the full suite:** `tools\Invoke-Tests.ps1 -Path tests`. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: add entry point and single-file bundle builder`.

---

### Task 18: Launcher and publish tooling

**Files:**
- Create: `launcher/BenTechSetup.template.cmd`, `tools/Build-Launcher.ps1`, `tools/Publish.ps1`, `tools/publish.settings.json`
- Test: `tests/Launcher.Tests.ps1`

**Interfaces:**
- Consumes: `keys/public-key.xml`, `tools/Signing.ps1`, `Build-Bundle.ps1`, `Test-DetachedSignature` (logic duplicated inline in the launcher).

**`launcher/BenTechSetup.template.cmd`** (ASCII only). The polyglot header is fixed:
```bat
@echo off
setlocal
fltmc >nul 2>&1 || ( powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b )
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText('%~f0'); & ([ScriptBlock]::Create($t.Substring($t.LastIndexOf('#__PS__')))) %*"
exit /b %errorlevel%
#__PS__
```
- After the marker comes a PowerShell section. Its parameters: `param([string]$BaseUrl='{{BASE_URL}}', [string]$TargetDir='C:\BenTech\Setup', [switch]$SkipAcl, [switch]$NoPause)`. It also holds `$PublicKeyXml='{{PUBLIC_KEY_XML}}'`.
- The section must **not** contain the literal `#__PS__`.
- Flow, with exit codes:
  1. TLS 1.2.
  2. **Lock check:** if `$TargetDir\run.lock` holds a live powershell PID → `Setup is already running on this machine` → exit **2**.
  3. Create `$TargetDir`. Unless `-SkipAcl`, run icacls with the SID args (copy of Task 10).
  4. **Download** the bytes of `setup.ps1`, `setup.ps1.sig`, `config.json` and `config.json.sig` from `$BaseUrl/<name>` with `WebClient.DownloadData`.
     - On failure, show red `Cannot reach GitHub - retrying in 30s (close this window to stop)`, retrying up to 20 times.
     - Then exit **4**.
  5. **Verify** both files with the RSA logic. On failure: red `SECURITY CHECK FAILED - files are not signed by BenTech. Nothing was run.` → exit **3**, and **write nothing to `$TargetDir`**.
  6. `WriteAllBytes` for both files.
  7. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TargetDir\setup.ps1"` and exit with its exit code.
  - Before any non-zero exit, `Start-Sleep 15` unless `-NoPause`.

**Tools**
- `tools/Build-Launcher.ps1 -BaseUrl <string> [-PublicKeyPath keys\public-key.xml] [-OutPath dist\BenTechSetup.cmd]`:
  - replaces both placeholders (the XML on one line)
  - **throws if any byte is > 0x7F**
  - writes CRLF line endings
- `tools/publish.settings.json`: `{ "repo": "<owner>/bentech-winsetup" }`.
- `tools/Publish.ps1 -Version <string> [-Notes <string>] [-DryRun]`. Stops at the first failure:
  1. `Invoke-Tests.ps1`
  2. `Build-Bundle`
  3. `Sign-File` on `dist/setup.ps1` and `dist/config.json`
  4. check both signatures with `keys/public-key.xml`
  5. `Build-Launcher -BaseUrl "https://github.com/<repo>/releases/latest/download"`
  6. unless `-DryRun`: `gh release create "v<Version>" dist/setup.ps1 dist/setup.ps1.sig dist/config.json dist/config.json.sig dist/BenTechSetup.cmd --repo <repo> --title "v<Version>" --notes <Notes>`

- [ ] **Step 1: Write the failing tests.** These include Review Focus #5.

```powershell
BeforeAll {
  . "$PSScriptRoot\..\tools\Signing.ps1"
  $script:rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
  $script:rel = Join-Path $TestDrive 'release'; New-Item -ItemType Directory $rel | Out-Null
  $rsa.ToXmlString($false) | Set-Content "$TestDrive\pub.xml" -Encoding ASCII
  "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'ran.txt') -Value ok" | Set-Content "$rel\setup.ps1" -Encoding UTF8
  '{"x":1}' | Set-Content "$rel\config.json" -Encoding ASCII
  function SignAll { foreach ($f in 'setup.ps1','config.json') { [IO.File]::WriteAllBytes("$rel\$f.sig", (New-DetachedSignature -Data ([IO.File]::ReadAllBytes("$rel\$f")) -PrivateKeyXml $rsa.ToXmlString($true))) } }
  & "$PSScriptRoot\..\tools\Build-Launcher.ps1" -BaseUrl ([uri]$rel).AbsoluteUri -PublicKeyPath "$TestDrive\pub.xml" -OutPath "$TestDrive\BenTechSetup.cmd"
  $t = [IO.File]::ReadAllText("$TestDrive\BenTechSetup.cmd"); $t.Substring($t.LastIndexOf('#__PS__')) | Set-Content "$TestDrive\launcher.ps1" -Encoding UTF8
  function RunL($target) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\launcher.ps1" -TargetDir $target -SkipAcl -NoPause | Out-Null; $LASTEXITCODE }
}
Describe 'launcher' {
  It 'is ASCII with CRLF' { $b = [IO.File]::ReadAllBytes("$TestDrive\BenTechSetup.cmd"); ($b | ? { $_ -gt 0x7F }) | Should -BeNullOrEmpty; [Text.Encoding]::ASCII.GetString($b) | Should -Match "\r\n" }
  It 'verifies and runs a correctly signed release' { SignAll; $d = Join-Path $TestDrive 't1'; RunL $d | Should -Be 0; "$d\ran.txt" | Should -Exist }
  It 'refuses a tampered script and writes nothing' {
    SignAll; Add-Content "$rel\setup.ps1" ' '; $d = Join-Path $TestDrive 't2'
    RunL $d | Should -Be 3; "$d\setup.ps1" | Should -Not -Exist; "$d\ran.txt" | Should -Not -Exist
  }
  It 'refuses while a run holds the lock' { $d = Join-Path $TestDrive 't3'; New-Item -ItemType Directory $d | Out-Null; "$PID" | Set-Content "$d\run.lock"; RunL $d | Should -Be 2 }
}
```

- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement** the template, `Build-Launcher.ps1` and `Publish.ps1`.
- [ ] **Step 4: Run the tests.** Expected: `Failed: 0`. Then run `tools\Publish.ps1 -Version 2026.10.18.1 -DryRun`. Expected: `dist\` holds 5 files, with no `gh` call.
- [ ] **Step 5: Commit:** `feat: add signed launcher and publish tooling`.

---

### Task 19: Docs, first publish, VM and real-machine verification

**Files:**
- Create: `README.md` (full), `CLAUDE.md`, `docs/testing.md`
- Modify: `config/config.json` (spike results only)

**Docs**
- [ ] **Step 1: Write `README.md`.** It covers:
  - what the tool does
  - **Using it:** copy `BenTechSetup.cmd` to a USB stick formatted exFAT/FAT32, then double-click and accept UAC
  - **Publishing:** `tools\Publish.ps1 -Version yyyy.MM.dd.N`
  - **Rollback:** `gh release edit v<old> --latest`
  - **Key backup and recovery:** a lost key means a new key plus a new launcher on every USB stick
  - the spike list
- [ ] **Step 2: Write `CLAUDE.md`** with the rules from Global Constraints: PS 5.1 only, no localized parsing, `-text` attributes, sign/publish flow, no `Invoke-WebRequest`.
- [ ] **Step 3: Write `docs/testing.md`,** the end-to-end checklist from spec §17:
  - **VM matrix:** Win11 25H2 Pro, Win11 25H2 Home, Win10 22H2. Each starts from a checkpoint with a local account and no password.
  - Explicit checks:
    - (a) the start screen shows "VM → Desktop"
    - (b) the run resumes after **each** reboot, **including the one after the PC rename** (the task principal survives the rename)
    - (c) the progress screen is visible after logon
    - (d) the final screen colour matches the verdict, and B and R work
    - (e) `Logs\Setup-Report.txt` is complete
    - (f) no resume task, no `NoAutoRebootWithLoggedOnUsers`, no `Downloads\` left behind
    - (g) a tampered release is refused
    - (h) a lid closed mid-run doesn't sleep the laptop
  - **Real laptops:** one each of Dell, Lenovo, HP and ASUS. Note vendor tool results and any yellow/red items.
- [ ] **Step 4: Fold in spike results.** For each spike JSON Ben has relayed, apply the change named in `docs/spikes.md`: config IDs, the Lenovo result parsing in Task 13, the WU search in Task 14, and the Store-app Skipped rule. Re-run the tests. Expected: `Failed: 0`.

**First publish (outward-facing)**
- [ ] **Step 5: Get Ben's OK for the outward-facing steps.** **STOP and ask Ben** before creating the **public** repo and publishing. Show him:
  - the repo name
  - that it's public
  - that it holds no secrets (only the public key)
- [ ] **Step 6: Create the repo and publish, after Ben says yes.**
  - `gh api user --jq .login` → write `tools/publish.settings.json`
  - `gh repo create <owner>/bentech-winsetup --public --source . --push`
  - `tools\Publish.ps1 -Version 2026.10.18.1 -Notes "First release"`
  - Give Ben `dist\BenTechSetup.cmd` for his USB stick.

**Verification**
- [ ] **Step 7: Ben runs `docs/testing.md` on the VM matrix,** then on real laptops. Each failure is fixed in its owning task's files with a regression test, then re-published (`yyyy.MM.dd.N+1`).
- [ ] **Step 8: Commit:** `docs: add README, CLAUDE.md, testing checklist; apply spike results`. Then run the `code-review` command on the branch before calling v1 done (Ben's pre-PR rule).
