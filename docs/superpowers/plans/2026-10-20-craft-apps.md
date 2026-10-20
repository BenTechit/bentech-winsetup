# bentech-winsetup: Craft apps as the default office suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new default Office choice, `CRAFT`, installs WordCraft, GridCraft, DeckCraft and PdfCraft silently from their signed GitHub-release MSIs, then the ArtCraft Launcher. It also puts `Word`, `Excel`, `PowerPoint` and `PDF Reader` shortcuts on the public desktop and an `ArtCraft Launcher` shortcut on the user's desktop. Microsoft 365 stays one `O` press away.

**Architecture:**
- One new step file, `src/Steps/CraftApps.ps1`, holds two kinds of function:
  - pure helpers (pick the asset, read `SHA256SUMS.txt`, compare versions, map the processor);
  - `Get-CraftRelease`, the one GitHub API call, with its rate-limit retry;
  - `Install-CraftItem`, which handles one item: lookup, skip when current, download, checksum, signature, msiexec;
  - `Add-CraftShortcut`, which renames or copies the MSI's own shortcut;
  - the step itself, `Invoke-StepCraftApps`.
- Everything goes through the existing helpers: `Get-RemoteText`, `Get-RemoteFile`, `Test-FileSignature`, `Invoke-External`, `Convert-MsiExitCode`, `Wait-SetupDelay`, `Add-SetupActivity` and `Set-SetupNow`.
- `Get-InstalledAppVersions` learns the five names from `config.json` and the per-user Uninstall view. The report and the step's "already up to date" check share it.
- `Get-StepPlan` swaps `office` and `office-finish` for `craft-apps` when the choice is CRAFT.

**Tech Stack:** Windows PowerShell 5.1, .NET Framework 4.8 (`WebClient` through the existing download helpers), `ConvertFrom-Json`, `Get-FileHash`, `Get-AuthenticodeSignature` (inside `Test-FileSignature`), msiexec. Pester 5.5+ on the dev PC only.

**Spec:** `docs/specs/2026-10-20-craft-apps-design.md` (binding). It amends `docs/specs/2026-10-20-progress-visibility-design.md` and the v1 spec. These travel with this plan and still apply:
- the v2 plan `docs/superpowers/plans/2026-10-20-progress-visibility.md`: its Global Constraints and Shared shapes;
- the ledger rulings in `.superpowers/sdd/2026-10-20-progress-visibility/progress.md` (do not undo any, especially V2-R13 deletion safety, V2-R11 and the colour rule).

## Global Constraints

**Platform and safety**
- Windows PowerShell **5.1 only**. No modules. Console and activity text are English, ASCII only.
- **Never run setup steps, `setup.ps1`, the launcher, msiexec or any downloaded MSI on this PC.** Tests mock every system call: `Invoke-External`, `Get-RemoteText`, `Get-RemoteFile`, `Test-FileSignature`, the registry and the desktop folders. The only real file I/O is inside `$TestDrive`.
- **Outward-facing actions need Ben's explicit OK at that moment.** Never run `git push`, any `gh` command, or `tools\Publish.ps1` without `-DryRun`.
- **The launcher must not change.** `launcher\` and `keys\public-key.xml` are not edited. `keys\launcher.sha256` stays `702c323aff5e813d7264375d15387d3bcdc12baded3d192f4bc47890663b69ff` (pinned by `tests\Launcher.Tests.ps1`).

**Runtime rules (unchanged)**
- **Child processes:** every one goes through `Invoke-External` with a timeout from `config.timeoutsMinutes`. For msiexec that is `timeoutsMinutes.msi` (20).
- **Downloads:** only `Get-RemoteText` and `Get-RemoteFile` (`WebClient` + TLS 1.2, User-Agent `BenTechSetup/1.0`). Never `Invoke-WebRequest`. GitHub's JSON is parsed with `ConvertFrom-Json`, which is allowed because it is not localized.
- **No prompts:** no `Read-Host`, `-Confirm` or `pause`.
- **Waits:** step code never calls `Start-Sleep`; it calls `Wait-SetupDelay` (`tests\Waits.Tests.ps1`).
- **`try` blocks:** `$ErrorActionPreference` stays `Continue`. Inside a `try`, every state-changing cmdlet (`Copy-Item`, `Move-Item`, `Get-FileHash`) carries `-ErrorAction Stop`. Tests mock a failing cmdlet with `Write-Error`, never `throw`.
- **Colours:** no `DarkYellow` or `DarkMagenta`, and every `Write-Host` passes both colours. The new step writes nothing to the console.
- **Deleting files (V2-R13):** nothing is ever deleted except a downloaded MSI that failed its checksum or signature: `Remove-Item -LiteralPath <file> -Force -ErrorAction SilentlyContinue`, inside `DownloadDir`, as Chrome does. Desktop shortcuts are copied or moved, never deleted.

**Values the spec pins (copy them exactly)**
- **API:** `https://api.github.com/repos/<repo>/releases/latest`.
- **Asset pattern:** `^<prefix>-[0-9][0-9A-Za-z.+-]*-windows-<arch>\.msi$`, where `<prefix>` is regex-escaped and `<arch>` is `x64`, `arm64` or `x86`.
- **Checksum file:** `SHA256SUMS.txt`, lines `<sha256>  <filename>`, matched by exact file name.
- **Signer:** `signers.craft = ["Learning Machines Inc"]`, matched by company name, never a thumbprint (the certificates live 3 days and are timestamped).
- **Install:** `msiexec /i "<msi>" /qn /norestart` through `Invoke-External`, mapped by `Convert-MsiExitCode`. 1618 waits 60 s and tries again, three tries in all, as Chrome does. 3010 and 1641 count as installed, with no restart of their own.
- **Rate limit:** HTTP 403 or 429 gets one retry after `Wait-SetupDelay -Seconds 60`. A second one fails the item with `GitHub busy - try again later`.
- **Catalog:** step `craft-apps`, Title `Craft apps`, Short `Craft apps`, right after `7zip`, before `default-browser`.
- **Results:**
  - Note `ArtCraft Launcher could not be installed`;
  - shortcut Note `<shortcut> desktop shortcut could not be created`;
  - Failed message `Not installed: <Name> (<reason>), ...`.
- **Start screen:**
  - Office line `   Office   CRAFT (free Word/Excel/PowerPoint/PDF)`;
  - **O** cycles CRAFT -> BUSINESS -> HOME -> OFF -> CRAFT;
  - `defaults.office` is `"CRAFT"`.

**Files, tests, commits**
- Every `.ps1` is UTF-8 **with BOM**. After writing, re-save with: `powershell -NoProfile -Command "Get-ChildItem -Recurse -Include *.ps1 src,tests,tools | % { $t=[IO.File]::ReadAllText($_.FullName); [IO.File]::WriteAllText($_.FullName,$t,(New-Object Text.UTF8Encoding $true)) }"`
- **Test command:** `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` (or one file). **Pass = the last line reads `Failed: 0`.** Today 2008 tests pass. Every task ends with the full suite green.
- A new `src` file needs a `$BundleOrder` entry in `tools\Build-Bundle.ps1`.
- **Commits:** a review gate before every commit (Ben's rule). Conventional commits, each with a second `-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Work on branch `feat/craft-apps`.

## Review Focus

The five inputs the spec implies that are most likely to bite, most likely first. Each names the test that pins it.

1. **GitHub rate-limits the shop's IP** (60 lookups an hour, shared by every PC on the bench). The item gets exactly one retry after 60 s, then fails with `GitHub busy - try again later`. Any other failure (404, no network) gets no 60 s wait.
   - Task 1: `Get-CraftRelease` rate-limit tests.
2. **A release whose assets do not fit.** Examples: only other processors, a `.msi.sig`, a `portable` or `debug` build, a name with a path, two matching installers.
   - Expected: exactly one exact match, or the item fails with `no <arch> installer in the latest release`. A file name from GitHub never reaches the disk unless the anchored pattern matched it.
   - Task 1: `Select-CraftAsset` tests.
3. **`SHA256SUMS.txt` in another shape.** Examples: CRLF, `*name`, upper-case hex, a longer name such as `.msi.zip`, the name twice with two hashes.
   - Expected: only one unambiguous exact-name line counts. Anything else is `no checksum for <file>`.
   - Task 1: `Get-Sha256FromSums` tests.
4. **Version strings that are not plain x.y.z.** Examples: `0.9.0.0` in the registry against `0.9.0`, a leading `v`, `0.9.0-beta.2`, an installed version newer than the release, garbage.
   - Expected: never skip on doubt, and never downgrade.
   - Task 1: `Test-CraftVersionCurrent` table.
5. **The desktop already has a shortcut with the familiar name**, for example a real Microsoft Word one from a pre-installed Office, or the MSI made its own.
   - Expected: never overwrite and never delete. The MSI's own shortcut is moved, not copied.
   - Task 2: `Add-CraftShortcut` tests.

---

## File Structure

```
src/Steps/CraftApps.ps1    NEW  Task 1: arch, asset pick, checksum line, versions, HTTP status, GitHub lookup
                                Task 2: Install-CraftItem, Add-CraftShortcut, Invoke-StepCraftApps
src/Report/Report.ps1      MOD  Task 1: HKCU Uninstall view; Get-InstalledAppVersions -Config (Craft names)
src/Steps/Finalize.ps1     MOD  Task 1: the report passes -Config
src/Engine/Catalog.ps1     MOD  Task 2: craft-apps entry; plan rule CRAFT vs office/office-finish
src/UI/StartScreen.ps1     MOD  Task 3: CRAFT choice, O cycle, Office line, help text
config/config.json         MOD  Task 1: signers.craft, apps.craft; Task 3: defaults.office = CRAFT
tools/Build-Bundle.ps1     MOD  Task 1: $BundleOrder 'Steps\CraftApps.ps1' after 'Steps\Office.ps1'
tests/CraftApps.Tests.ps1  NEW  Tasks 1-2
tests/Config.Tests.ps1, tests/Finalize.Tests.ps1   MOD  Task 1
tests/Catalog.Tests.ps1                            MOD  Task 2
tests/Screens.Tests.ps1                            MOD  Task 3
README.md, docs/testing.md, CLAUDE.md              MOD  Task 4
```

## Shared shapes

**`config.json`** (Task 1; `defaults.office` in Task 3):
```
"signers": { ..., "craft": ["Learning Machines Inc"] },
"apps": { ..., "craft": { "signer": "craft", "items": [
  { "name": "WordCraft", "repo": "storytold/wordcraft", "assetPrefix": "wordcraft",
    "displayName": "^WordCraft", "startMenuName": "^WordCraft", "shortcut": "Word" },
  { "name": "GridCraft", "repo": "storytold/gridcraft", "assetPrefix": "gridcraft",
    "displayName": "^GridCraft", "startMenuName": "^GridCraft", "shortcut": "Excel" },
  { "name": "DeckCraft", "repo": "storytold/deckcraft", "assetPrefix": "deckcraft",
    "displayName": "^DeckCraft", "startMenuName": "^DeckCraft", "shortcut": "PowerPoint" },
  { "name": "PdfCraft", "repo": "storytold/pdfcraft", "assetPrefix": "pdfcraft",
    "displayName": "^PdfCraft", "startMenuName": "^PdfCraft", "shortcut": "PDF Reader" },
  { "name": "ArtCraft Launcher", "repo": "storytold/craft-launcher", "assetPrefix": "artcraft-launcher",
    "displayName": "^ArtCraft Launcher", "startMenuName": "^ArtCraft Launcher", "shortcut": "ArtCraft Launcher",
    "launcher": true } ] } }
```
- The items are worked through in this order.
- `displayName` and `startMenuName` are case-insensitive regexes (`-match`). They are best guesses until a real machine confirms them (docs/testing.md).
- `launcher: true` means four things:
  - the shortcut goes on the user's desktop;
  - a failure is a Note, not a Failed;
  - the installed activity line is the launcher text;
  - an absent `launcher` means false.

**`Choices.Office`**: `CRAFT` | `BUSINESS` | `HOME` | `OFF`.

**Plan with CRAFT (Dell laptop, 7-Zip on):** `prepare, bitlocker, region, desktop-icons, bloatware, rename, winget, chrome, anydesk, 7zip, craft-apps, default-browser, vendor-pass1, windows-update, vendor-pass2, consumer-app, vendor-cleanup, finalize`. BUSINESS and HOME keep today's 19-step plan, and no plan holds both.

**Release object:** the `ConvertFrom-Json` of the API answer. Only `assets[].name` and `assets[].browser_download_url` are read.

**`Select-CraftAsset` result:** `@{ Name = <asset file name>; Url = <browser_download_url>; Version = <the version part of the name>; SumsUrl = <url of the asset named exactly SHA256SUMS.txt, or $null> }`, or `$null`.

**`Install-CraftItem` result:** `@{ Status = 'Installed'|'Current'|'Failed'; Version = <release version, '' when unknown>; Reason = <'' unless Failed> }`. The possible reasons are:
- `GitHub busy - try again later`
- `release lookup failed`
- `no <arch> installer in the latest release`
- `no SHA256SUMS.txt in the release`
- `checksum list could not be read`
- `download failed`
- `no checksum for <file>`
- `checksum mismatch`
- `signature check failed`
- `msiexec <code>`
- `msiexec timed out`
- `msiexec could not be started`
- `unexpected error`

**`Add-CraftShortcut` result:** `@{ Status = 'Created'|'Renamed'|'Exists'|'Failed'; Path = <the .lnk it is about> }`.

**NOW sub-titles** (the screen prints `Craft apps - <sub-title>`):
- `<Name>: looking up the latest release`
- `<Name> <ver>: downloading`
- `<Name> <ver>: checking`
- `<Name> <ver>: installing`

**Activity lines** (`<ver>` is the release version):

| Case | Line |
|---|---|
| App installed | `<Name> <ver> installed`, plus ` - desktop shortcut: <shortcut>` when the shortcut was Created or Renamed now |
| App already current | `<Name> <ver> already up to date`, with the same suffix rule |
| Launcher installed | `<Name> <ver> installed - open it to check the apps and their updates` |
| Launcher already current | `<Name> <ver> already up to date` |
| Any failed item | `<Name> not installed - <reason>` |

---

### Task 1: Craft config, release lookup and checks, report versions

**Files:**
- Create: `src/Steps/CraftApps.ps1`, `tests/CraftApps.Tests.ps1`
- Modify: `config/config.json`, `tools/Build-Bundle.ps1` (`$BundleOrder`), `src/Report/Report.ps1` (`$script:UninstallRegistryKeys`, `Get-InstalledAppVersions`), `src/Steps/Finalize.ps1:569`, `tests/Config.Tests.ps1`, `tests/Finalize.Tests.ps1`

**Interfaces:**
- Consumes:
  - `Get-RemoteText -Url <string> -> string`: throws `download failed after <n> attempts: <url>`, and the original error is in the `InnerException` chain;
  - `Wait-SetupDelay -Seconds <double>`;
  - `Write-SetupLog`;
  - `Get-Signers -Config -Key -> string[]`.
- Produces (all in `src/Steps/CraftApps.ps1`; none throws unless it says so):
  - `ConvertTo-CraftArch -Arch <string> -> string`: `ARM64` -> `arm64`, `x86` -> `x86`, anything else -> `x64` (case-insensitive). `Machine.Arch` is `x64` or `ARM64` today.
  - `Select-CraftAsset -Release <object> -Prefix <string> -Arch <string> -> hashtable|$null`: the shape is in Shared shapes.
    - The pattern is case-insensitive.
    - Exactly one asset must match; zero or two or more give `$null`, logged at WARN when more than one matched.
    - `Version` is the capture of `[0-9][0-9A-Za-z.+-]*`.
    - `SumsUrl` comes from the asset whose name is `-ceq 'SHA256SUMS.txt'`.
  - `Get-Sha256FromSums -Text <string> -FileName <string> -> string|$null`:
    - lines split on `\r?\n`, each matched against `^([0-9A-Fa-f]{64}) [ *](.+?)\s*$`;
    - the name is compared with `-ceq`;
    - returns the hash in lower case when exactly one distinct hash names the file, else `$null`.
  - `ConvertTo-CraftVersion -Text <string> -> [version]|$null`:
    - the leading `v?([0-9]+(\.[0-9]+){0,3})`, padded to four parts with `.0`;
    - `$null` when there is no match or the number does not fit.
  - `Test-CraftVersionCurrent -Installed <string> -Available <string> -> bool`: `$true` only when both convert and installed >= available.
  - `Get-WebStatusCode -Exception <Exception> -> int`:
    - walks `.InnerException` from the given exception;
    - the first `[Net.WebException]` whose `.Response -is [Net.HttpWebResponse]` gives `[int]$Response.StatusCode`;
    - otherwise 0.
  - `Get-CraftRelease -Repo <string> -> pscustomobject`:
    - reads `Get-RemoteText -Url "https://api.github.com/repos/$Repo/releases/latest"` and returns its `ConvertFrom-Json`;
    - on a failure whose `Get-WebStatusCode` is 403 or 429, it logs a WARN, calls `Wait-SetupDelay -Seconds 60` and tries once more;
    - a second 403 or 429 **throws** `GitHub busy - try again later`;
    - any other failure, including JSON that does not parse, **throws** `release lookup failed`, with the detail logged at WARN.
  - `Get-InstalledAppVersions [-Config <object>]` (`Report.ps1`):
    - `$script:UninstallRegistryKeys` gains a third entry, `'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'` (per-user installs: the ArtCraft Launcher);
    - with a Config that has `apps.craft.items`, each item's `name` is reported from the first Uninstall entry that has a version and whose `DisplayName -match` the item's `displayName`;
    - without Config it behaves as today;
    - a missing `apps.craft` is no error.
  - `Complete-SetupFinalization` calls `Get-InstalledAppVersions -Config $Context.Config`.

- [ ] **Step 1: Config.** Add `signers.craft` and `apps.craft` exactly as in Shared shapes (`defaults.office` stays `BUSINESS` until Task 3). Add `'Steps\CraftApps.ps1'` to `$BundleOrder` right after `'Steps\Office.ps1'`.

- [ ] **Step 2: Write the failing tests.**

  `tests/Config.Tests.ps1`:
  - add `$cfg.apps.craft.signer` to the refs of `'every signer key referenced exists'`;
  - add:
```powershell
  It 'lists the five Craft items in install order, the launcher last' {
    $items = @($cfg.apps.craft.items)
    @($items.name) | Should -Be @('WordCraft', 'GridCraft', 'DeckCraft', 'PdfCraft', 'ArtCraft Launcher')
    @($items.repo) | Should -Be @('storytold/wordcraft', 'storytold/gridcraft', 'storytold/deckcraft', 'storytold/pdfcraft', 'storytold/craft-launcher')
    @($items.assetPrefix) | Should -Be @('wordcraft', 'gridcraft', 'deckcraft', 'pdfcraft', 'artcraft-launcher')
    @($items.shortcut) | Should -Be @('Word', 'Excel', 'PowerPoint', 'PDF Reader', 'ArtCraft Launcher')
    @($items | Where-Object { $_.launcher -eq $true }).name | Should -Be 'ArtCraft Launcher'
  }
  It 'trusts the Craft MSIs by company name only' { @(Get-Signers -Config $cfg -Key $cfg.apps.craft.signer) | Should -Be @('Learning Machines Inc') }
  It 'every Craft displayName and startMenuName is a valid regular expression' {
    foreach ($i in $cfg.apps.craft.items) { foreach ($p in $i.displayName, $i.startMenuName) { $p | Should -Not -BeNullOrEmpty; { [void][regex]::new($p) } | Should -Not -Throw } }
  }
```

  `tests/CraftApps.Tests.ps1`:
  - **Header:** a SAFETY comment saying nothing is downloaded, installed or written outside `$TestDrive`.
  - **BeforeAll dot-sources:** Common `StepResult`, `Logging`, `Activity`, `Process`, `Download`, `Config`; `Report\Report.ps1`; `Steps\DefaultBrowser.ps1` (`Read-RegistryStringValue`); `Steps\CraftApps.ps1`.
  - **`$script:cfg`:** from `Read-SetupConfig`.
  - **Helper `New-CraftRelease`:** two forms, `-Prefix <p> -Version <v> -Arch <a[]> [-NoSums]` and `-Names <string[]>`. It returns `ConvertFrom-Json` of a release JSON whose assets carry the URL `https://github.com/storytold/<p or wordcraft>/releases/download/v<v or 0.8.0>/<name>`, plus a `SHA256SUMS.txt` asset unless `-NoSums` (with `-Names`, only the names given).
```powershell
Describe 'ConvertTo-CraftArch' {
  It 'maps ARM64 to arm64, x86 to x86, anything else to x64' {
    ConvertTo-CraftArch -Arch 'ARM64' | Should -BeExactly 'arm64'; ConvertTo-CraftArch -Arch 'x86' | Should -BeExactly 'x86'
    ConvertTo-CraftArch -Arch 'x64' | Should -BeExactly 'x64'; ConvertTo-CraftArch -Arch '' | Should -BeExactly 'x64'
  }
}
Describe 'Select-CraftAsset' {
  It 'picks the MSI of the processor, its version and the SHA256SUMS.txt link' {
    $a = Select-CraftAsset -Release (New-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64, arm64, x86) -Prefix wordcraft -Arch arm64
    $a.Name | Should -BeExactly 'wordcraft-0.8.0-windows-arm64.msi'; $a.Version | Should -BeExactly '0.8.0'
    $a.Url | Should -Be 'https://github.com/storytold/wordcraft/releases/download/v0.8.0/wordcraft-0.8.0-windows-arm64.msi'
    $a.SumsUrl | Should -Be 'https://github.com/storytold/wordcraft/releases/download/v0.8.0/SHA256SUMS.txt'
  }
  It 'reads a longer prefix (the launcher)' { (Select-CraftAsset -Release (New-CraftRelease -Prefix artcraft-launcher -Version 0.5.1 -Arch x64) -Prefix artcraft-launcher -Arch x64).Version | Should -Be '0.5.1' }
  It 'ignores lookalikes (Review Focus 2)' {
    $rel = New-CraftRelease -Names 'wordcraft-0.8.0-windows-x64.msi.sig', 'wordcraft-portable-0.8.0-windows-x64.msi', 'gridcraft-0.8.0-windows-x64.msi', '..\wordcraft-0.8.0-windows-x64.msi', 'wordcraft-0.8.0-windows-arm64.msi'
    Select-CraftAsset -Release $rel -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty
  }
  It 'two matching installers is no choice' {
    $rel = New-CraftRelease -Names 'wordcraft-0.8.0-windows-x64.msi', 'wordcraft-0.8.0-debug-windows-x64.msi', 'SHA256SUMS.txt'
    Select-CraftAsset -Release $rel -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty
  }
  It 'SumsUrl is $null unless an asset is named exactly SHA256SUMS.txt' {
    (Select-CraftAsset -Release (New-CraftRelease -Names 'wordcraft-0.8.0-windows-x64.msi', 'sha256sums.txt', 'SHA256SUMS.txt.asc') -Prefix wordcraft -Arch x64).SumsUrl | Should -BeNullOrEmpty
  }
  It 'a release without assets is $null' { Select-CraftAsset -Release ([pscustomobject]@{ tag_name = 'v1' }) -Prefix wordcraft -Arch x64 | Should -BeNullOrEmpty }
}
Describe 'Get-Sha256FromSums' {
  It 'reads the line of the exact file name' {
    $text = ('a' * 64) + "  wordcraft-0.8.0-windows-x64.msi`n" + ('c' * 64) + "  wordcraft-0.8.0-windows-arm64.msi`n"
    Get-Sha256FromSums -Text $text -FileName 'wordcraft-0.8.0-windows-x64.msi' | Should -BeExactly ('a' * 64)
  }
  It 'accepts CRLF, a * before the name and upper-case hex, and answers in lower case' {
    Get-Sha256FromSums -Text (('B' * 64) + " *wordcraft-0.8.0-windows-x64.msi`r`n") -FileName 'wordcraft-0.8.0-windows-x64.msi' | Should -BeExactly ('b' * 64)
  }
  It 'is $null for <Why> (Review Focus 3)' -ForEach @(
    @{ Why = 'no line for the name'; Text = ('a' * 64) + '  wordcraft-0.8.0-windows-arm64.msi' }
    @{ Why = 'only a longer name';   Text = ('a' * 64) + '  wordcraft-0.8.0-windows-x64.msi.zip' }
    @{ Why = 'another case';         Text = ('a' * 64) + '  WordCraft-0.8.0-windows-x64.msi' }
    @{ Why = 'two different hashes'; Text = ('a' * 64) + "  wordcraft-0.8.0-windows-x64.msi`n" + ('c' * 64) + '  wordcraft-0.8.0-windows-x64.msi' }
    @{ Why = 'a short hash';         Text = 'abc123  wordcraft-0.8.0-windows-x64.msi' }
    @{ Why = 'empty text';           Text = '' }
  ) { Get-Sha256FromSums -Text $Text -FileName 'wordcraft-0.8.0-windows-x64.msi' | Should -BeNullOrEmpty }
}
Describe 'Test-CraftVersionCurrent (Review Focus 4)' {
  It 'installed <Installed> vs release <Available> is <Expected>' -ForEach @(
    @{ Installed = '0.8.0';   Available = '0.8.0';        Expected = $true }
    @{ Installed = '0.8.0.0'; Available = '0.8.0';        Expected = $true }
    @{ Installed = '0.8.0';   Available = '0.8.0.0';      Expected = $true }
    @{ Installed = 'v0.8.0';  Available = '0.8.0';        Expected = $true }
    @{ Installed = '0.9.1';   Available = '0.9.0';        Expected = $true }    # never downgrade
    @{ Installed = '0.8.0';   Available = '0.8.0-beta.2'; Expected = $true }    # numeric part only
    @{ Installed = '0.7.9';   Available = '0.8.0';        Expected = $false }
    @{ Installed = '';        Available = '0.8.0';        Expected = $false }
    @{ Installed = 'abc';     Available = '0.8.0';        Expected = $false }   # doubt: install
    @{ Installed = '0.8.0';   Available = 'x';            Expected = $false }
  ) { Test-CraftVersionCurrent -Installed $Installed -Available $Available | Should -Be $Expected }
}
Describe 'Get-WebStatusCode' {
  It 'is 0 when no HTTP answer is attached, also deep inside' {
    Get-WebStatusCode -Exception (New-Object Exception 'x') | Should -Be 0
    $inner = New-Object Management.Automation.MethodInvocationException ('m', (New-Object Net.WebException 'The remote name could not be resolved'))
    Get-WebStatusCode -Exception (New-Object Exception ('download failed after 3 attempts: u', $inner)) | Should -Be 0
  }
}
Describe 'Get-CraftRelease' {
  BeforeEach {
    Mock Write-SetupLog { }; Mock Wait-SetupDelay { }
    $script:calls = 0; $script:fail = 0; $script:status = 0
    Mock Get-RemoteText { $script:calls++; if ($script:calls -le $script:fail) { throw 'download failed after 3 attempts' }; '{"tag_name":"v0.8.0","assets":[{"name":"SHA256SUMS.txt","browser_download_url":"u"}]}' }
    Mock Get-WebStatusCode { $script:status }
  }
  It 'reads releases/latest of the repo and returns the parsed answer' {
    (Get-CraftRelease -Repo 'storytold/wordcraft').assets[0].name | Should -Be 'SHA256SUMS.txt'
    Should -Invoke Get-RemoteText -Times 1 -Exactly -ParameterFilter { $Url -eq 'https://api.github.com/repos/storytold/wordcraft/releases/latest' }
  }
  It 'a rate limit (<_>) gets one retry after 60 s (Review Focus 1)' -ForEach 403, 429 {
    $script:fail = 1; $script:status = $_
    (Get-CraftRelease -Repo 'storytold/wordcraft').tag_name | Should -Be 'v0.8.0'
    $script:calls | Should -Be 2
    Should -Invoke Wait-SetupDelay -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
  }
  It 'a second rate limit is GitHub busy' {
    $script:fail = 2; $script:status = 403
    { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw 'GitHub busy - try again later'
    $script:calls | Should -Be 2
  }
  It 'any other failure is a lookup failure at once, with no wait' {
    $script:fail = 1; $script:status = 404
    { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw 'release lookup failed'
    $script:calls | Should -Be 1; Should -Invoke Wait-SetupDelay -Times 0 -Exactly
  }
  It 'an answer that is not JSON is a lookup failure' { Mock Get-RemoteText { '<html>busy</html>' }; { Get-CraftRelease -Repo 'storytold/wordcraft' } | Should -Throw 'release lookup failed' }
}
```

  `tests/Finalize.Tests.ps1`, in `Describe 'Get-InstalledAppVersions'`. `$craftCfg` is `'{"apps":{"craft":{"items":[{"name":"WordCraft","displayName":"^WordCraft"},{"name":"PdfCraft","displayName":"^PdfCraft"},{"name":"ArtCraft Launcher","displayName":"^ArtCraft Launcher"}]}}}' | ConvertFrom-Json`.
```powershell
  It 'with the config it also reports the Craft apps, the launcher from the per-user view' {
    Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'WordCraft'; DisplayVersion = '0.8.0' } } -ParameterFilter { @($Path) -contains $script:Uninstall64 }
    Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'ArtCraft Launcher'; DisplayVersion = '0.5.1' } } -ParameterFilter { @($Path) -contains 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' }
    $v = Get-InstalledAppVersions -Config $craftCfg
    $v['WordCraft'] | Should -Be '0.8.0'; $v['ArtCraft Launcher'] | Should -Be '0.5.1'; $v.ContainsKey('PdfCraft') | Should -BeFalse
  }
  It 'without the config it reports no Craft app' {
    Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'WordCraft'; DisplayVersion = '0.8.0' } } -ParameterFilter { @($Path) -contains $script:Uninstall64 }
    (Get-InstalledAppVersions).ContainsKey('WordCraft') | Should -BeFalse
  }
```

  `tests/Finalize.Tests.ps1`, in `Describe 'Complete-SetupFinalization on its own (ruling R26)'`: `It 'asks for the app versions with the config, so the report lists the Craft apps'`, which calls `Complete-SetupFinalization -Context (New-FinalizeContext)` and then `Should -Invoke Get-InstalledAppVersions -ParameterFilter { $null -ne $Config }`.

- [ ] **Step 3: Run** `tools\Invoke-Tests.ps1 -Path tests\CraftApps.Tests.ps1`, then `Config.Tests.ps1` and `Finalize.Tests.ps1`. Expected: FAIL (`CraftApps.ps1` missing, no `apps.craft`, no `-Config`).
- [ ] **Step 4: Implement** the Produces list:
  - `src/Steps/CraftApps.ps1` opens with a header comment: purpose (craft spec §3.3), the files it needs (`StepResult`, `Logging`, `Activity`, `Process`, `Download`, `Config`, `Report`), and "the bundle holds every file".
  - Edit `Report.ps1`: header comment, the HKCU key, `-Config` and the craft matching inside the existing registry loop.
  - Edit the `Finalize.ps1:569` call.
  - Re-save every `.ps1` with BOM.
- [ ] **Step 5: Run** the three files, then the full suite. Expected: last line `Failed: 0`. `tests\Bundle.Tests.ps1` passes with the new `$BundleOrder` entry.
- [ ] **Step 6: Commit:** `feat: Craft apps config, GitHub release lookup and checks, report versions`.

---

### Task 2: The craft-apps step

**Files:**
- Modify: `src/Steps/CraftApps.ps1`, `src/Engine/Catalog.ps1`
- Test: `tests/CraftApps.Tests.ps1`, `tests/Catalog.Tests.ps1`

**Interfaces:**
- Consumes:
  - from Task 1: `ConvertTo-CraftArch`, `Get-CraftRelease`, `Select-CraftAsset`, `Get-Sha256FromSums`, `Test-CraftVersionCurrent`, `Get-InstalledAppVersions -Config`;
  - existing helpers: `Get-RemoteFile -Url -Destination -> string`, `Get-RemoteText`, `Test-FileSignature -Path -AllowedSigners -> bool`, `Invoke-External -FilePath -ArgumentList -TimeoutMinutes -> @{ ExitCode; TimedOut }`, `Convert-MsiExitCode -> 'Done'|'DoneReboot'|'Retry'|'Failed'`, `Wait-SetupDelay`, `Set-SetupNow -SubTitle`, `Add-SetupActivity -Text`, `Get-Signers`, `New-StepResult`.
- Produces:
  - `Install-CraftItem -Context <hashtable> -Item <object> -Arch <string> -Signers <string[]> [-InstalledVersion <string>] -> hashtable`:
    - the shape and reasons are in Shared shapes, and it never throws;
    - order of work:
      1. NOW `looking up`, then `Get-CraftRelease -Repo $Item.repo` (a throw's message is the reason);
      2. `Select-CraftAsset`;
      3. `Test-CraftVersionCurrent` -> `Current`, with nothing downloaded;
      4. `SumsUrl` present;
      5. NOW `downloading`, then `Get-RemoteText` of the sums file and `Get-RemoteFile` of the MSI to `Join-Path $Context.DownloadDir <asset name>`;
      6. NOW `checking`, then the sums line, `Get-FileHash -Algorithm SHA256 -ErrorAction Stop` compared case-insensitively, then `Test-FileSignature`; a mismatch or a bad signature deletes the MSI;
      7. NOW `installing`, then `Join-Path $env:windir 'System32\msiexec.exe'` with `/i "<msi>" /qn /norestart` and `timeoutsMinutes.msi`, with the 1618 retry.
  - `Add-CraftShortcut -Item <object> [-PublicDesktop <string>] [-UserDesktop <string>] [-StartMenuFolders <string[]>] -> hashtable`:
    - the shape is in Shared shapes, and it never throws;
    - empty parameters are resolved in the body to `[Environment]::GetFolderPath('CommonDesktopDirectory')`, `'DesktopDirectory'` and `@('CommonPrograms', 'Programs')`;
    - the target is `<UserDesktop if launcher, else PublicDesktop>\<Item.shortcut>.lnk`, then:
      1. the target exists -> `Exists`;
      2. else the first `*.lnk` directly in PublicDesktop, then UserDesktop, whose BaseName `-match` `startMenuName` -> `Move-Item -LiteralPath <it> -Destination <target> -ErrorAction Stop` -> `Renamed`;
      3. else the first `*.lnk` under the Start-menu folders (recursive) that matches the same way -> `Copy-Item -LiteralPath ... -ErrorAction Stop` -> `Created`;
      4. else `Failed` (WARN);
      5. any error -> `Failed` (WARN).
  - `Invoke-StepCraftApps -Context <hashtable> -> StepResult`:
    - no `apps.craft.items`, or an unknown signer key -> Failed(`Craft apps are not configured`);
    - otherwise: `ConvertTo-CraftArch $Context.State.Machine.Arch`, then **one** `Get-InstalledAppVersions -Config $Context.Config`;
    - per item: `Install-CraftItem`; on Installed or Current, `Add-CraftShortcut`, with its Failed giving the Note `<shortcut> desktop shortcut could not be created`; then the activity line (Shared shapes);
    - result: any non-launcher Failed -> Failed(`Not installed: <Name> (<reason>), ...`) in config order;
    - otherwise Done(`Craft apps installed`), or Done(`Craft apps already up to date`) when every item was Current;
    - a failed launcher adds the Note `ArtCraft Launcher could not be installed` (`<Name> could not be installed`);
    - Notes travel with both Done and Failed;
    - no Data and no Reboot.
  - `Catalog.ps1`:
    - the entry `@{ Id = 'craft-apps'; Title = 'Craft apps'; Short = 'Craft apps'; Function = 'Invoke-StepCraftApps' }` goes right after `7zip`;
    - `Get-StepPlan`: `'craft-apps' { $Choices['Office'] -eq 'CRAFT' }`, and `office` and `office-finish` become `{ $Choices['Office'] -notin 'OFF', 'CRAFT' }`, so every other value behaves exactly as today;
    - update the doc comment.

- [ ] **Step 1: Write the failing tests** in `tests/CraftApps.Tests.ps1`.
  - **Fixture `Initialize-CraftMocks`**, called from BeforeEach. It records:
    - `$script:now` (each `Set-SetupNow` SubTitle);
    - `$script:waits` (each `Wait-SetupDelay` Seconds);
    - `$script:downloads` (each `Get-RemoteFile` Url and Destination); the mock writes `placeholder` to Destination;
    - `$script:sigCalls`, with `$script:sigBad` listing the leaf names that fail;
    - `$script:ext` (each `Invoke-External` call), answered by `$script:extHandler`, default exit 0;
    - `Write-SetupLog`.
  - **Fixture `Set-CraftRelease -Prefix -Version -Arch [-SumsArch] [-NoSums]`** sets `$script:texts`:
    - the API URL maps to the release JSON;
    - the sums URL maps to `"<hash>  <prefix>-<ver>-windows-<arch>.msi"`, one line per arch in `-SumsArch` (default: `-Arch`);
    - `<hash>` is `$script:sumsHash`, by default the real SHA-256 of the bytes of `placeholder`;
    - `Get-RemoteText` answers from `$script:texts[$Url]` and throws for an unknown URL.
  - **Fixture `New-CraftContext`:** real `config.json`, `Machine.Arch = 'x64'`, and `DownloadDir` under `$TestDrive`.
  - **Do not mock `Test-Path` or `Remove-Item`** in this Describe: the MSI is a real `$TestDrive` file.
  - **Handlers:** an `$script:extHandler` reads its values from `$script:` variables, never from an `It`'s local or `-ForEach` variables, because it runs inside the mock.
```powershell
Describe 'Install-CraftItem' {
  BeforeAll { function I([string]$Arch = 'x64', [string]$Installed = '') { Install-CraftItem -Context $script:ctx -Item $script:word -Arch $Arch -Signers @('Learning Machines Inc') -InstalledVersion $Installed } }
  BeforeEach { Initialize-CraftMocks; $script:ctx = New-CraftContext; $script:word = $script:ctx.Config.apps.craft.items[0]
    $script:msi = Join-Path $script:ctx.DownloadDir 'wordcraft-0.8.0-windows-x64.msi'; Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64, arm64 }
  It 'downloads, checks the checksum and the signer, then installs silently' {
    $r = I; $r.Status | Should -Be 'Installed'; $r.Version | Should -Be '0.8.0'; $r.Reason | Should -BeExactly ''
    $script:downloads[0].Destination | Should -Be $msi
    $script:sigCalls[0].Path | Should -Be $msi; @($script:sigCalls[0].Signers) | Should -Be @('Learning Machines Inc')
    $script:ext.Count | Should -Be 1; $script:ext[0].FilePath | Should -Be (Join-Path $env:windir 'System32\msiexec.exe')
    $script:ext[0].ArgumentList | Should -BeExactly "/i `"$msi`" /qn /norestart"; $script:ext[0].TimeoutMinutes | Should -Be 20
  }
  It 'shows each phase in NOW' { $null = I; @($script:now) | Should -Be @('WordCraft: looking up the latest release', 'WordCraft 0.8.0: downloading', 'WordCraft 0.8.0: checking', 'WordCraft 0.8.0: installing') }
  It 'installed <_> is Current: nothing downloaded or run' -ForEach '0.8.0', '0.8.0.0', '0.9.1' {
    $r = I -Installed $_; $r.Status | Should -Be 'Current'; $r.Version | Should -Be '0.8.0'; $script:downloads.Count | Should -Be 0; $script:ext.Count | Should -Be 0 }
  It 'an older installed version is upgraded' { (I -Installed '0.7.2').Status | Should -Be 'Installed' }
  It 'a checksum mismatch deletes the MSI and never runs it' { $script:sumsHash = 'f' * 64; Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64
    $r = I; $r.Status | Should -Be 'Failed'; $r.Reason | Should -Be 'checksum mismatch'; Test-Path -LiteralPath $msi | Should -BeFalse; $script:ext.Count | Should -Be 0 }
  It 'a bad signature deletes the MSI and never runs it' { $script:sigBad = @('wordcraft-0.8.0-windows-x64.msi')
    $r = I; $r.Reason | Should -Be 'signature check failed'; Test-Path -LiteralPath $msi | Should -BeFalse; $script:ext.Count | Should -Be 0 }
  It 'no checksum line for the file' { Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64, arm64 -SumsArch x64
    $r = I -Arch arm64; $r.Reason | Should -Be 'no checksum for wordcraft-0.8.0-windows-arm64.msi'; $script:ext.Count | Should -Be 0 }
  It 'no SHA256SUMS.txt in the release' { Set-CraftRelease -Prefix wordcraft -Version 0.8.0 -Arch x64 -NoSums; (I).Reason | Should -Be 'no SHA256SUMS.txt in the release'; $script:downloads.Count | Should -Be 0 }
  It 'no installer for the processor' { (I -Arch x86).Reason | Should -Be 'no x86 installer in the latest release' }
  It 'GitHub busy is the reason' { Mock Get-CraftRelease { throw 'GitHub busy - try again later' }; (I).Reason | Should -Be 'GitHub busy - try again later' }
  It 'a failed MSI download is the reason' { Mock Get-RemoteFile { throw 'download failed after 3 attempts' }; (I).Reason | Should -Be 'download failed'; $script:ext.Count | Should -Be 0 }
  It 'a checksum list that cannot be read is the reason' {
    $script:texts.Remove(@($script:texts.Keys | Where-Object { $_ -like '*SHA256SUMS.txt' })[0]); (I).Reason | Should -Be 'checksum list could not be read'; $script:ext.Count | Should -Be 0 }
  It 'msiexec <Code> is <Status>' -ForEach @(@{ Code = 3010; Status = 'Installed' }, @{ Code = 1641; Status = 'Installed' }, @{ Code = 1603; Status = 'Failed' }) {
    $script:code = $Code; $script:extHandler = { param($c) @{ ExitCode = $script:code; TimedOut = $false } }; $r = I; $r.Status | Should -Be $Status
    if ($Status -eq 'Failed') { $r.Reason | Should -Be 'msiexec 1603' } }
  It 'msiexec 1618 waits 60 s and tries again, three tries in all' {
    $script:extHandler = { param($c) @{ ExitCode = 1618; TimedOut = $false } }; $r = I
    $r.Reason | Should -Be 'msiexec 1618'; $script:ext.Count | Should -Be 3; @($script:waits) | Should -Be @(60, 60) }
  It 'msiexec that times out or cannot start is a failure' {
    $script:extHandler = { param($c) @{ ExitCode = $null; TimedOut = $true } }; (I).Reason | Should -Be 'msiexec timed out'
    Mock Invoke-External { throw 'cannot start' }; (I).Reason | Should -Be 'msiexec could not be started' }
  It 'an unexpected error is a failure, never a throw' { Mock Select-CraftAsset { throw 'boom' }; (I).Reason | Should -Be 'unexpected error' }
}
```
  `Add-CraftShortcut` tests:
  - Use real `$TestDrive` folders `$pub`, `$usr`, `$menu`, `$userMenu`.
  - Helper `Add-Lnk <folder> <name> [<text>]` writes a fake `.lnk` file.
  - Helper `S($item)` calls `Add-CraftShortcut -Item $item -PublicDesktop $pub -UserDesktop $usr -StartMenuFolders @($menu, $userMenu)`.
  - `$items` is `$cfg.apps.craft.items`.
  - Mock only `Write-SetupLog`, plus whatever a test names.
```powershell
Describe 'Add-CraftShortcut' {
  It 'copies the Start-menu shortcut to the public desktop as Word.lnk' {
    Add-Lnk (Join-Path $menu 'WordCraft') 'WordCraft' 'start'; $r = S $items[0]
    $r.Status | Should -Be 'Created'; $r.Path | Should -Be (Join-Path $pub 'Word.lnk')
    Get-Content -LiteralPath (Join-Path $pub 'Word.lnk') | Should -Be 'start'; Test-Path -LiteralPath (Join-Path $menu 'WordCraft\WordCraft.lnk') | Should -BeTrue }
  It 'renames the MSI''s own desktop shortcut instead of copying, so there is no duplicate' {
    Add-Lnk $pub 'WordCraft' 'msi'; Add-Lnk $menu 'WordCraft' 'start'
    (S $items[0]).Status | Should -Be 'Renamed'; @((Get-ChildItem -LiteralPath $pub -Filter *.lnk).Name) | Should -Be @('Word.lnk')
    Get-Content -LiteralPath (Join-Path $pub 'Word.lnk') | Should -Be 'msi' }
  It 'never overwrites or deletes: an existing Word.lnk stays, and so does the MSI''s own (Review Focus 5)' {
    Add-Lnk $pub 'Word' 'microsoft word'; Add-Lnk $pub 'WordCraft' 'msi'; Add-Lnk $menu 'WordCraft' 'start'
    (S $items[0]).Status | Should -Be 'Exists'; Get-Content -LiteralPath (Join-Path $pub 'Word.lnk') | Should -Be 'microsoft word'
    Test-Path -LiteralPath (Join-Path $pub 'WordCraft.lnk') | Should -BeTrue }
  It 'puts the launcher on the user''s desktop, from the per-user Start menu' {
    Add-Lnk $userMenu 'ArtCraft Launcher'; (S $items[4]).Path | Should -Be (Join-Path $usr 'ArtCraft Launcher.lnk')
    Test-Path -LiteralPath (Join-Path $usr 'ArtCraft Launcher.lnk') | Should -BeTrue; Test-Path -LiteralPath (Join-Path $pub 'ArtCraft Launcher.lnk') | Should -BeFalse }
  It 'takes only a shortcut whose name starts as startMenuName says' {
    Add-Lnk $menu 'Uninstall WordCraft'; Add-Lnk $menu 'GridCraft'; (S $items[0]).Status | Should -Be 'Failed'
    Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' } }
  It 'a copy that fails is Failed and never throws' {
    Add-Lnk $menu 'WordCraft'; Mock Copy-Item { Write-Error 'access denied' }
    { $script:r = S $items[0] } | Should -Not -Throw; $script:r.Status | Should -Be 'Failed' }
  It 'with no folders given it looks at both desktops and both Start menus of this PC, and copies nothing' {
    Mock Test-Path { $false }; Mock Get-ChildItem { }; Mock Copy-Item { }; Mock Move-Item { }
    (Add-CraftShortcut -Item $items[0]).Status | Should -Be 'Failed'
    foreach ($f in 'CommonDesktopDirectory', 'DesktopDirectory', 'CommonPrograms', 'Programs') {
      $script:want = [Environment]::GetFolderPath($f); Should -Invoke Get-ChildItem -ParameterFilter { $LiteralPath -eq $script:want } }
    Should -Invoke Copy-Item -Times 0 -Exactly; Should -Invoke Move-Item -Times 0 -Exactly }
}
```

  `Invoke-StepCraftApps` tests:
  - Mocks: `Install-CraftItem`, recording `$Item.name` into `$script:order` and answering `$script:outcome[$Item.name]`, or by default `@{ Status = 'Installed'; Version = <0.8.0, or 0.9.0 for PdfCraft, or 0.5.1 for the launcher>; Reason = '' }`;
  - `Add-CraftShortcut`, answering `Failed` when `$script:shortcutFails -contains $Item.shortcut`, else `$script:shortcutStatus` (default `Created`);
  - `Get-InstalledAppVersions { @{ 'PdfCraft' = '0.9.0' } }`;
  - `Add-SetupActivity`, recording into `$script:activity`;
  - `Write-SetupLog`.
```powershell
Describe 'Invoke-StepCraftApps' {
  It 'works through the five items in config order with the processor, the craft signer and the installed version' {
    $ctx.State.Machine.Arch = 'ARM64'; $null = Invoke-StepCraftApps -Context $ctx
    @($script:order) | Should -Be @('WordCraft', 'GridCraft', 'DeckCraft', 'PdfCraft', 'ArtCraft Launcher')
    Should -Invoke Install-CraftItem -Times 5 -Exactly -ParameterFilter { $Arch -eq 'arm64' -and (@($Signers) -join '|') -eq 'Learning Machines Inc' }
    Should -Invoke Install-CraftItem -Times 1 -Exactly -ParameterFilter { $Item.name -eq 'PdfCraft' -and $InstalledVersion -eq '0.9.0' }
    Should -Invoke Get-InstalledAppVersions -Times 1 -Exactly -ParameterFilter { $null -ne $Config } }
  It 'all installed: Done, one activity line per item (spec 3.4)' {
    $r = Invoke-StepCraftApps -Context $ctx; $r.Status | Should -Be 'Done'; $r.Message | Should -Be 'Craft apps installed'; @($r.Notes).Count | Should -Be 0
    @($script:activity.Text) | Should -Be @('WordCraft 0.8.0 installed - desktop shortcut: Word', 'GridCraft 0.8.0 installed - desktop shortcut: Excel',
      'DeckCraft 0.8.0 installed - desktop shortcut: PowerPoint', 'PdfCraft 0.9.0 installed - desktop shortcut: PDF Reader',
      'ArtCraft Launcher 0.5.1 installed - open it to check the apps and their updates') }
  It 'an app already up to date says so; a shortcut that was there already is not mentioned' {
    $script:outcome['PdfCraft'] = @{ Status = 'Current'; Version = '0.9.0'; Reason = '' }; $script:shortcutStatus = 'Exists'
    $null = Invoke-StepCraftApps -Context $ctx
    @($script:activity.Text) | Should -Contain 'PdfCraft 0.9.0 already up to date'; @($script:activity.Text) | Should -Contain 'WordCraft 0.8.0 installed' }
  It 'every item current is Done(Craft apps already up to date), and the shortcuts are still checked' {
    foreach ($n in 'WordCraft', 'GridCraft', 'DeckCraft', 'PdfCraft', 'ArtCraft Launcher') { $script:outcome[$n] = @{ Status = 'Current'; Version = '1.0'; Reason = '' } }
    (Invoke-StepCraftApps -Context $ctx).Message | Should -Be 'Craft apps already up to date'; Should -Invoke Add-CraftShortcut -Times 5 -Exactly }
  It 'one app failing does not stop the others: Failed with the names and reasons' {
    $script:outcome['GridCraft'] = @{ Status = 'Failed'; Version = '0.8.0'; Reason = 'checksum mismatch' }
    $script:outcome['PdfCraft'] = @{ Status = 'Failed'; Version = ''; Reason = 'GitHub busy - try again later' }
    $r = Invoke-StepCraftApps -Context $ctx; $r.Status | Should -Be 'Failed'
    $r.Message | Should -BeExactly 'Not installed: GridCraft (checksum mismatch), PdfCraft (GitHub busy - try again later)'
    Should -Invoke Install-CraftItem -Times 5 -Exactly; Should -Invoke Add-CraftShortcut -Times 0 -Exactly -ParameterFilter { $Item.name -in 'GridCraft', 'PdfCraft' }
    @($script:activity.Text) | Should -Contain 'GridCraft not installed - checksum mismatch' }
  It 'only the launcher failing is Done with a yellow Note' {
    $script:outcome['ArtCraft Launcher'] = @{ Status = 'Failed'; Version = ''; Reason = 'no arm64 installer in the latest release' }
    $r = Invoke-StepCraftApps -Context $ctx; $r.Status | Should -Be 'Done'; @($r.Notes) | Should -Be @('ArtCraft Launcher could not be installed') }
  It 'a shortcut that cannot be made is a yellow Note; the step stays Done' {
    $script:shortcutFails = @('PDF Reader'); $r = Invoke-StepCraftApps -Context $ctx
    $r.Status | Should -Be 'Done'; @($r.Notes) | Should -Be @('PDF Reader desktop shortcut could not be created')
    @($script:activity.Text) | Should -Contain 'PdfCraft 0.9.0 installed' }
  It 'no Craft config is Failed and installs nothing' {
    $ctx.Config.apps.PSObject.Properties.Remove('craft')
    (Invoke-StepCraftApps -Context $ctx).Message | Should -Be 'Craft apps are not configured'; Should -Invoke Install-CraftItem -Times 0 -Exactly }
}
```

  `tests/Catalog.Tests.ps1`:
  - the catalog test becomes `'lists the 20 steps ...'`, with `'craft-apps|Craft apps|Invoke-StepCraftApps'` after `7zip`;
  - the Short list gains `'craft-apps|Craft apps'` after `'7zip|7-Zip'`;
  - `'Dell laptop gets everything in order'` (BUSINESS) stays **unchanged**, which proves "exactly as today";
  - add:
```powershell
  It 'CRAFT: craft-apps right after 7zip, and no Microsoft 365 steps' {
    (P DELL LAPTOP $true 'CRAFT') -join ',' | Should -Be 'prepare,bitlocker,region,desktop-icons,bloatware,rename,winget,chrome,anydesk,7zip,craft-apps,default-browser,vendor-pass1,windows-update,vendor-pass2,consumer-app,vendor-cleanup,finalize' }
  It 'CRAFT without 7-Zip: craft-apps right after anydesk' { $p = @(P ASUS DESKTOP $false 'CRAFT'); $p.IndexOf('craft-apps') | Should -Be ($p.IndexOf('anydesk') + 1) }
  It 'BUSINESS, HOME and OFF never get craft-apps' { foreach ($o in 'BUSINESS', 'HOME', 'OFF') { (P DELL LAPTOP $true $o) | Should -Not -Contain 'craft-apps' } }
```
- [ ] **Step 2: Run** `CraftApps.Tests.ps1` and `Catalog.Tests.ps1`. Expected: FAIL (functions and catalog entry missing).
- [ ] **Step 3: Implement** the Produces list:
  - `Install-CraftItem` mirrors `Invoke-StepChrome`: download, signature, delete on reject, msiexec loop.
  - The step uses no `Write-Host`, `Start-Sleep` or `WScript.Shell`.
  - Re-save with BOM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0`. `Bundle.Tests` 'defines every catalog function' passes, and so do `Waits`, `ErrorAction` and `Colors`.
- [ ] **Step 5: Commit:** `feat: craft-apps step: Craft apps from signed GitHub MSIs, desktop shortcuts`.

---

### Task 3: CRAFT on the start screen, the new default

**Files:**
- Modify: `src/UI/StartScreen.ps1`, `config/config.json` (`defaults.office`)
- Test: `tests/Screens.Tests.ps1`, `tests/Config.Tests.ps1`, `tests/Catalog.Tests.ps1`

**Interfaces:**
- Consumes: `Get-StepPlan` with `CRAFT` (Task 2).
- Produces:
  - `$script:OfficeChoices = @('CRAFT', 'BUSINESS', 'HOME', 'OFF')`. Its order is the **O** cycle. `New-DefaultChoices` still maps an unknown default to `OFF`.
  - `Format-StartScreen`: `'CRAFT'` shows as `CRAFT (free Word/Excel/PowerPoint/PDF)`. The help text on the Office line becomes `O = craft / 365 / off` (53 + 21 = 74 columns; the four values do not fit in 79).
  - `Get-StartScreenSegments` is unchanged: `CRAFT` is the chosen word and is shown Green.
  - Update the doc comments of `Update-StartChoices` and `New-DefaultChoices`.
  - `config.json`: `"defaults": { "sevenZip": true, "office": "CRAFT" }`.

- [ ] **Step 1: Update and add tests.**
  - `Screens.Tests.ps1`:
    - `'O cycles OFF -> BUSINESS -> HOME -> OFF'` becomes the test below.
    - Every expected `'O = off / business / home'` becomes `'O = craft / 365 / off'` (lines 193, 201 and 243).
    - `New-DefaultChoices` with the real config, and both `Show-StartScreen` default tests (282, 323), expect `'CRAFT'`.
    - The `D O O L` test expects `'HOME'` (`# CRAFT -> BUSINESS -> HOME`).
    - Add the tests below.
  - `Config.Tests.ps1`: `$cfg.defaults.office | Should -Be 'CRAFT'`.
  - `Catalog.Tests.ps1`: `It 'the default choices plan craft-apps, not Microsoft 365'`: `$o = (New-DefaultChoices -Machine @{ IsLaptop = $true } -Config $cfg).Office; (P DELL LAPTOP $true $o) | Should -Contain 'craft-apps'`. Dot-source `src\UI\StartScreen.ps1` in its BeforeAll.
```powershell
  It 'O cycles CRAFT -> BUSINESS -> HOME -> OFF -> CRAFT' {
    $r = Update-StartChoices -Choices @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT' } -Key 'O'
    $seen = @($r.Choices.Office); foreach ($i in 1..3) { $r = Update-StartChoices -Choices $r.Choices -Key 'o'; $seen += $r.Choices.Office }
    $seen | Should -Be @('BUSINESS', 'HOME', 'OFF', 'CRAFT'); $r.ResetCountdown | Should -BeTrue }
  It 'opens on CRAFT, and a lower-case craft default is CRAFT' {
    (New-DefaultChoices -Machine $m -Config $cfg).Office | Should -Be 'CRAFT'
    (New-DefaultChoices -Machine $m -Config ([pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $true; office = 'craft' } })).Office | Should -Be 'CRAFT' }
  It 'shows the CRAFT line and still fits 79 columns' {
    $l = F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT' }
    $l | Should -Contain ('   Office   CRAFT (free Word/Excel/PowerPoint/PDF)'.PadRight(53) + 'O = craft / 365 / off')
    @($l | Where-Object { $_.Length -gt 79 }).Count | Should -Be 0 }
  It 'CRAFT is shown green' {
    $s = @(Get-StartScreenSegments -Line ('   Office   CRAFT (free Word/Excel/PowerPoint/PDF)'.PadRight(53) + 'O = craft / 365 / off'))
    $s[1].Text | Should -Be 'CRAFT'; $s[1].Color | Should -Be 'Green' }
```
- [ ] **Step 2: Run** `Screens.Tests.ps1`, `Config.Tests.ps1` and `Catalog.Tests.ps1`. Expected: FAIL on the new and updated tests.
- [ ] **Step 3: Implement** the Produces list. Re-save with BOM.
- [ ] **Step 4: Run** the three files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Commit:** `feat: CRAFT office choice on the start screen, now the default`.

---

### Task 4: Docs and the publish dry run

**Files:**
- Modify: `README.md`, `docs/testing.md`, `CLAUDE.md`

- [ ] **Step 1: `README.md`**
  - **Intro:** link the craft spec and this plan beside the v2 ones.
  - **"What it does":**
    - a new item after 7-Zip: **Craft apps** (Office CRAFT, the default) installs WordCraft, GridCraft, DeckCraft and PdfCraft, then the ArtCraft Launcher;
    - say where they come from: each project's latest GitHub release MSI for the processor, checked against `SHA256SUMS.txt` and the `Learning Machines Inc` signature, skipped when already up to date;
    - add desktop shortcuts `Word`, `Excel`, `PowerPoint` and `PDF Reader` for all users and `ArtCraft Launcher` for the signed-in user;
    - mark the two Microsoft 365 items "with Office BUSINESS or HOME";
    - renumber.
  - **Start-screen sample:** the Office line now reads `CRAFT (free Word/Excel/PowerPoint/PDF)` and its help `O = craft / 365 / off`.
  - **Key table:** `O` cycles CRAFT, BUSINESS, HOME, OFF.
  - Add one sentence: the Craft apps are alpha, so Microsoft 365 is one key press away.
  - **Leftovers sentence:** with CRAFT no `OfficeDeploymentTool` folder is left.
  - **"Changing apps and lists":** an `apps.craft` bullet covering the item fields, `displayName` and `startMenuName` as regexes that are best guesses until docs/testing.md 1.17 confirms them, and `signers.craft`.
- [ ] **Step 2: `docs/testing.md`.** Add a new section `### 1.17 Craft apps (craft spec 5)` after 1.16. It holds these checkboxes:
  - **Silent install:** `msiexec /qn` installs each app MSI and the launcher MSI, under the elevated setup account. Record per-machine vs per-user: the Uninstall entry is in HKLM or HKCU, and the files are in `C:\Program Files\<App>` or elsewhere.
  - **Names:** the real Uninstall `DisplayName` and Start-menu shortcut names. Correct `displayName` and `startMenuName` in `config.json`.
  - **MSI desktop shortcuts:** whether the MSIs make desktop shortcuts themselves, and on which desktop.
  - **Desktop result:** the shortcuts `Word`, `Excel`, `PowerPoint` and `PDF Reader` on the public desktop and `ArtCraft Launcher` on the user's desktop. They have the right icons, there are no duplicates, and each opens its app (a copied Start-menu shortcut may be an advertised one).
  - **Ben's test:** the launcher shows the four apps as installed, and offers and applies an update when one comes out.
  - **Second run:** a second run says `already up to date` for each item and downloads nothing.
  - **Signers:** the same signer on all five MSIs. DeckCraft, GridCraft and PdfCraft were not checked on 20/10/2026.
  - **Proven by mocks only:**
    - the report lists the five versions;
    - the rate-limit path. On any PC, `Get-WebStatusCode` on the error `Get-RemoteText` throws for `https://api.github.com/repos/storytold/no-such-repo/releases/latest` must return 404 (read-only).
  - **ARM64:** the launcher's v0.5.1 release has x64, arm64 and x86 MSIs (verified via the GitHub API on 20/10/2026). On an ARM64 laptop, check that the arm64 MSIs of the apps and the launcher install and run.
  - **Start screen:** the CRAFT line, green, and the O cycle.

  In section 5, add the `displayName` and `startMenuName` guesses as an open item.
- [ ] **Step 3: `CLAUDE.md`**
  - Under "Step contract and shapes", one bullet:
    - `Choices.Office` is `CRAFT` (default) | `BUSINESS` | `HOME` | `OFF`;
    - CRAFT plans `craft-apps` (after `7zip`, `src/Steps/CraftApps.ps1`) and leaves `office` and `office-finish` out;
    - its MSIs come from GitHub `releases/latest`, checked against `SHA256SUMS.txt` and Authenticode `signers.craft` by company name (3-day certificates: never a thumbprint).
  - Under "Where things live", add the craft spec and this plan.
- [ ] **Step 4: Verify.**
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` gives the last line `Failed: 0`.
  - `git diff --quiet main -- launcher keys; $LASTEXITCODE` gives `0`.
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.20.3 -DryRun` prints:
    - `Launcher SHA-256: 702c323aff5e813d7264375d15387d3bcdc12baded3d192f4bc47890663b69ff`;
    - no `WARNING: the launcher changed`;
    - and it ends with `DRY RUN: nothing was published.`

    Clean-tree and pushed-HEAD warnings are expected under `-DryRun`.
  - **Never** run `Publish.ps1` without `-DryRun`, `gh`, or `git push`: that is Ben's call.
- [ ] **Step 5: Commit:** `docs: Craft apps default, shortcuts and real-machine checks`. Then tell Ben the branch is ready for his first-laptop test (docs/testing.md 1.17), and that publishing is his call.

---

## Spec coverage (self-review)

| Spec | Task |
|---|---|
| §2 Q10 default CRAFT, M365 selectable | 3 |
| §2 Q11 shortcut names | 2 (`Add-CraftShortcut`), 1 (config) |
| §2 Q12 four apps silently, then the launcher | 1 (config order), 2 |
| §3.1 start screen, O cycle, Office line | 3 |
| §3.2 plan: craft-apps after 7zip; no office/office-finish; BUSINESS/HOME unchanged | 2 |
| §3.3 step 1 lookup + asset pattern + arch | 1 (`Get-CraftRelease`, `Select-CraftAsset`, `ConvertTo-CraftArch`), 2 (wiring) |
| §3.3 step 2 checksum + signer by company name | 1 (`Get-Sha256FromSums`, `signers.craft`), 2 |
| §3.3 step 3 skip when current (Uninstall DisplayVersion via `displayName`) | 1 (`Test-CraftVersionCurrent`, `Get-InstalledAppVersions -Config`), 2 |
| §3.3 step 4 msiexec via `Invoke-External`, `timeoutsMinutes.msi`, `Convert-MsiExitCode` | 2 |
| §3.3 step 5 shortcuts: rename MSI desktop link, else copy Start-menu link; launcher on user desktop | 2 |
| §3.3 results (one failing, all done, app failed red, launcher-only yellow, shortcut yellow) | 2 |
| §3.3 GitHub limits (403/429, one retry after 60 s via `Wait-SetupDelay`) | 1 |
| §3.4 NOW and activity lines | 2 |
| §3.4 report versions | 1 |
| §3.5 Office path unchanged, launcher unchanged, colour/tick/ASCII/no-prompt rules | 2 (BUSINESS plan test), 4 (launcher hash), static guards every task |
| §5 real-machine items | 4 |
