# bentech-winsetup: ScreenConnect as a remote-access choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new start-screen choice, **R**, picks AnyDesk (the default), ScreenConnect or both. ScreenConnect is installed from Ben's own `ScreenConnect.ClientSetup.exe`, shipped as a fifth file of the run's own GitHub release, pinned by SHA-256 in the signed `config.json` and checked against the ConnectWise signature.

**Architecture:**
- `Choices.Remote` is read through one helper, `Get-RemoteChoice` (in `src/Engine/Catalog.ps1`), by the start screen, the plan, the final screen and the report. Missing or invalid means `ANYDESK`.
- A new step file, `src/Steps/ScreenConnect.ps1`, holds the step `Invoke-StepScreenConnect` and its small helpers: the version-pinned URL, the service state, the service wait, the installer check. It works only through existing helpers: `Get-RemoteFile`, `Test-FileSignature`, `Invoke-External`, `Wait-SetupDelay`, `Set-SetupNow` and `Add-SetupActivity`.
- The final screen and the report read the step's `Status` and its `Data.Service`.
- `tools/Publish.ps1` checks Ben's installer before building and uploads it as the fifth release file. The launcher is not touched.

**Tech Stack:** Windows PowerShell 5.1, `Get-Service`, `Get-FileHash`, `Get-AuthenticodeSignature` (inside `Test-FileSignature`, and directly for the certificate end date), `gh` (Publish only, never in tests). Pester 5.5+ on the dev PC only.

**Spec:** `docs/specs/2026-10-20-screenconnect-design.md` (binding). It amends the v1 spec, `docs/specs/2026-10-20-progress-visibility-design.md` and `docs/specs/2026-10-20-craft-apps-design.md`. These travel with this plan and still apply:
- the Global Constraints of `docs/superpowers/plans/2026-10-20-progress-visibility.md` and `docs/superpowers/plans/2026-10-20-craft-apps.md`;
- the ledger rulings in `.superpowers/sdd/2026-10-20-progress-visibility/progress.md` and `.superpowers/sdd/2026-10-20-craft-apps/progress.md` (do not undo any, especially V2-R13 deletion safety and the colour rule).

## Global Constraints

**Platform and safety**
- Windows PowerShell **5.1 only**. No modules. Console, activity and report text are English, ASCII only.
- **Never run setup steps, `setup.ps1`, the launcher, msiexec or any installer on this PC.** In particular never run `ScreenConnect.ClientSetup.exe` (any copy, including `C:\Users\BenTech\Downloads\ScreenConnect.ClientSetup.exe`): it would enrol the dev PC in Ben's ScreenConnect list. Tests mock `Get-Service`, `Get-RemoteFile`, `Test-FileSignature`, `Get-AuthenticodeSignature`, `Invoke-External`, `Wait-SetupDelay`, `Set-SetupNow` and `Add-SetupActivity`. The only real file I/O is inside `$TestDrive`. **No test reads Ben's real installer** in `%USERPROFILE%\.bentech-winsetup\`.
- **Outward-facing actions need Ben's explicit OK at that moment.** Never run `git push`, any `gh` command, or `tools\Publish.ps1` without `-DryRun`.
- **The launcher must not change.** `launcher\BenTechSetup.template.cmd` and `keys\public-key.xml` are not edited. `keys\launcher.sha256` stays `702c323aff5e813d7264375d15387d3bcdc12baded3d192f4bc47890663b69ff` (pinned by `tests\Launcher.Tests.ps1`). The launcher still downloads only the four signed files.

**Runtime rules (unchanged)**
- **Child processes:** through `Invoke-External` only. The ScreenConnect installer gets its **own** `timeoutsMinutes.screenconnect` (10), never `default` (30).
- **Downloads:** `Get-RemoteFile` only. Never `Invoke-WebRequest`.
- **Waits:** step code never calls `Start-Sleep`; it calls `Wait-SetupDelay` (`tests\Waits.Tests.ps1`). No prompts.
- **`try` blocks:** `$ErrorActionPreference` stays `Continue`; inside a `try`, `Get-FileHash` and `Get-AuthenticodeSignature` carry `-ErrorAction Stop`. A failing cmdlet is mocked with `Write-Error`, never `throw`.
- **Colours:** no `DarkYellow` or `DarkMagenta`; every start-screen write passes both colours (the frame's Black background). The step writes nothing to the console.
- **Deleting files (V2-R13):** the only file the step deletes is the downloaded installer after a failed check: `Remove-Item -LiteralPath <exe> -Force -ErrorAction SilentlyContinue`, inside `DownloadDir`, as Chrome and AnyDesk do.
- **Never parse localized output:** the service is read by its exact name with `Get-Service -Name` (service names are not localized); the signature by `Status` and `Subject`.

**Values the spec pins** (full shapes in Shared shapes; copy them exactly)
- `config.json`: `defaults.remote` `"ANYDESK"`; `signers.connectwise` `["\"ConnectWise, LLC\""]`, **with the quotes**; `apps.screenconnect` (`signer`, `url`, `sha256`, `serviceName`); `timeoutsMinutes.screenconnect` 10 and `screenconnectService` 3.
- **Signer match:** `Test-FileSignature` **without** `-ExactCN`. The real subject is `CN="ConnectWise, LLC", O="ConnectWise, LLC", L=Tampa, S=Florida, C=US`.
- **Catalog:** step `screenconnect`, Title `ScreenConnect`, Short `ScreenConnect`, right after `anydesk`. `anydesk` runs with ANYDESK or BOTH, `screenconnect` with SCREENCONNECT or BOTH.
- **Download:** `<DownloadDir>\ScreenConnect.ClientSetup.exe`, from `url` with `{version}` replaced by `$script:SetupVersion`, never `latest`.
- **Poll:** every 5 s through `Wait-SetupDelay`, for up to `timeoutsMinutes.screenconnectService` minutes.
- **R key help:** `R = anydesk / sc / both`. The reminder is drawn Yellow on Black.
- **Publish:**
  - the installer is read from `%USERPROFILE%\.bentech-winsetup\ScreenConnect.ClientSetup.exe`;
  - it is uploaded as the fifth release file `ScreenConnect.ClientSetup.exe`, with no `.sig`;
  - the certificate's end date is printed, with a warning when it is less than 60 days away.

**Files, tests, commits**
- Every `.ps1` is UTF-8 **with BOM**. After writing, re-save with: `powershell -NoProfile -Command "Get-ChildItem -Recurse -Include *.ps1 src,tests,tools | % { $t=[IO.File]::ReadAllText($_.FullName); [IO.File]::WriteAllText($_.FullName,$t,(New-Object Text.UTF8Encoding $true)) }"`
- **Test command:** `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` (or one file). **Pass = the last line reads `Failed: 0`.** Today 2218 tests pass. Every task ends with the full suite green.
- A new `src` file needs a `$BundleOrder` entry in `tools\Build-Bundle.ps1`.
- **Commits:** a review gate before every commit (Ben's rule). Conventional commits, each with a second `-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Work on branch `feat/screenconnect`.

## Review Focus

The five failure modes the spec implies that are most likely to bite, most likely first. Each names the test that pins it.

1. **A run state without `Remote`.** The resume task runs `C:\BenTech\Setup\setup.ps1`, which the launcher may have replaced with a newer bundle after a crash, against the older run's `state.json`.
   - Expected: ANYDESK everywhere. The plan keeps `anydesk` only, the final screen shows the AnyDesk ID with no ScreenConnect status, and the report says `ScreenConnect: not chosen`.
   - Tests: Task 1 `Get-RemoteChoice` on a `state.json` round trip; Task 2 plan with no Remote; Task 3 final screen and report from choices without Remote.
2. **The quoted signer subject.** Windows renders `CN="ConnectWise, LLC", ...`.
   - Expected: the quoted config entry accepts it, and an unquoted entry would refuse every real installer. `-ExactCN` refuses it (which is why it is not used). Any status other than `Valid`, which is what an expired installer reports after 19/02/2027, refuses it.
   - Test: Task 1, the new `Test-FileSignature` context in `tests\Download.Tests.ps1`.
3. **A ScreenConnect service that exists but does not run, or one of another company.**
   - Expected: only the exact service name counts. Another company's client (another suffix) is not "already installed". A stopped service is Done with the yellow Note after the full 3-minute wait, never Failed.
   - Tests: Task 2, `Get-ScreenConnectServiceState` and the step.
4. **An installer that never exits** (a hidden window waiting for a click).
   - Expected: it is killed at 10 minutes, then the service decides. `ScreenConnect install timed out` only when the service is missing; Done when the service runs anyway.
   - Test: Task 2, the step.
5. **Publish without the installer, with another file, or with one near its end date.**
   - Expected: a real publish stops before building. `-DryRun` only warns, and leaves a missing installer out of the `gh` command. The end date is printed, with a warning inside 60 days. The tests never read Ben's real file.
   - Tests: Task 4.

---

## File Structure

```
config/config.json            MOD  Task 1: defaults.remote, signers.connectwise, apps.screenconnect, two timeouts
src/Engine/Catalog.ps1        MOD  Task 1: $script:RemoteChoices, Get-RemoteChoice
                                   Task 2: screenconnect entry; anydesk/screenconnect plan rules
src/UI/StartScreen.ps1        MOD  Task 1: Remote default, R cycle, Chrome/Remote/reminder lines, whole-value highlight
src/Steps/ScreenConnect.ps1   NEW  Task 2: URL, service state, service wait, installer check, Invoke-StepScreenConnect
tools/Build-Bundle.ps1        MOD  Task 2: $BundleOrder 'Steps\ScreenConnect.ps1' right after 'Steps\Apps.ps1'
src/UI/FinalScreen.ps1        MOD  Task 3: AnyDesk block only when chosen; status on the New name line
src/Report/Report.ps1         MOD  Task 3: AnyDesk 'not chosen', ScreenConnect line; Get-InstalledAppVersions 'ScreenConnect'
tools/Publish.ps1             MOD  Task 4: installer check, copy, fifth file, end-date warning
tests/ScreenConnect.Tests.ps1 NEW  Task 2
tests/Config.Tests.ps1, tests/Download.Tests.ps1, tests/Catalog.Tests.ps1, tests/Screens.Tests.ps1   MOD  Tasks 1-3
tests/Finalize.Tests.ps1                                                                              MOD  Task 3
tests/Launcher.Tests.ps1                                                                              MOD  Task 4
README.md, docs/testing.md, CLAUDE.md                                                                 MOD  Task 4
```

**Plan call:** the step gets its own file, not a section of `Apps.ps1`:
- it has four helpers and its own test file, and `Apps.ps1` and `tests\Apps.Tests.ps1` (1605 lines) are already the largest of their kind;
- it shares nothing with AnyDesk but the pattern.

## Shared shapes

**`config.json`** (Task 1), merged into the existing sections:
```
"defaults": { "sevenZip": true, "office": "CRAFT", "remote": "ANYDESK" },
"timeoutsMinutes": { ..., "anydeskId": 2, "screenconnect": 10, "screenconnectService": 3 },
"signers": { ..., "connectwise": ["\"ConnectWise, LLC\""] },
"apps": { ..., "screenconnect": {
  "signer": "connectwise",
  "url": "https://github.com/BenTechit/bentech-winsetup/releases/download/v{version}/ScreenConnect.ClientSetup.exe",
  "sha256": "74E058E0F597CF197132775552FBB6F4BDD21F8A0870E1A638D41A63F7C3FD99",
  "serviceName": "ScreenConnect Client (b58e7c32699a96bf)" } }
```

**`Choices.Remote`**: `ANYDESK` | `SCREENCONNECT` | `BOTH`. `$script:RemoteChoices = @('ANYDESK', 'SCREENCONNECT', 'BOTH')` is also the **R** cycle. `Get-RemoteChoice` returns one of the three, always. AnyDesk is chosen when it is `-ne 'SCREENCONNECT'`; ScreenConnect when it is `-ne 'ANYDESK'`.

**Plan with BOTH** (Dell laptop, 7-Zip on, BUSINESS): `prepare, bitlocker, region, desktop-icons, bloatware, rename, winget, chrome, anydesk, screenconnect, 7zip, default-browser, vendor-pass1, office, windows-update, office-finish, vendor-pass2, consumer-app, vendor-cleanup, finalize`. With SCREENCONNECT, `anydesk` is left out. With ANYDESK, or no valid Remote, the plan is exactly today's.

**Step outcomes** (`Invoke-StepScreenConnect`; the runner merges `Data` into `Steps.screenconnect.Data`):

| Case | Status | Message | Notes | Data.Service |
|---|---|---|---|---|
| Installed now, service Running | Done | `ScreenConnect installed` | | `Running` |
| Service was there, Running | Done | `ScreenConnect already installed` | | `Running` |
| Either, service exists but not Running after the wait | Done | as above | `ScreenConnect service not running yet` | `NotRunning` |
| Service missing after the wait | Failed | `ScreenConnect install failed (service not found)` | | `Missing` |
| ... and the installer had timed out | Failed | `ScreenConnect install timed out` | | `Missing` |
| Version unknown (`dev`) | Failed | `ScreenConnect: release version unknown` | | |
| SHA-256 or signature check failed | Failed | `ScreenConnect installer check failed` | | |
| Download failed (**plan call**, AnyDesk's pattern) | Failed | `ScreenConnect download failed: <exception message>` | | |
| Installer could not be started (**plan call**, no service wait) | Failed | `ScreenConnect install failed (installer could not be started)` | | |
| No `apps.screenconnect`, or an unknown signer key (**plan call**, Craft's pattern) | Failed | `ScreenConnect is not configured` | | |

**NOW** (`Set-SetupNow -Title`, so the line reads exactly as spec 4.4; the runner clears it after the step): `ScreenConnect: downloading`, `ScreenConnect: checking`, `ScreenConnect: installing`, `ScreenConnect: waiting for the service`. **Plan call:** `-Title`, not `-SubTitle`, which would print `ScreenConnect - ScreenConnect: downloading`.

**Activity line** (on every Done, also "already installed", where it is still true; none on Failed, the runner writes those lines): `ScreenConnect installed - this PC will appear in your ScreenConnect list`.

**Start screen** (`$helpAt` = 53):
```
   Chrome   always
   Remote   <VALUE>                     (padded to column 53) R = anydesk / sc / both
   ScreenConnect = unattended access: get the customer's OK first      <- only when VALUE includes SCREENCONNECT
```
`<VALUE>` is `ANYDESK`, `SCREENCONNECT` or `ANYDESK + SCREENCONNECT`. The lines sit between `Type` and `7-Zip`.

**Final screen:** `  New name : <name>     ScreenConnect: installed` (or `NOT installed`). There are five spaces before `ScreenConnect`.

**Report**, right after `AnyDesk ID   : ...`:
- `ScreenConnect: installed (service running)`, `installed (service not running)`, `not installed` or `not chosen`;
- `AnyDesk ID   : not chosen` when AnyDesk was not chosen.

---

### Task 1: Config, the Remote choice and the start screen

**Files:**
- Modify: `config/config.json`, `src/Engine/Catalog.ps1`, `src/UI/StartScreen.ps1` (header comment, `New-DefaultChoices`, `Update-StartChoices`, `Format-StartScreen:206`, `Get-StartScreenSegments:254-257`)
- Test: `tests/Config.Tests.ps1`, `tests/Download.Tests.ps1`, `tests/Catalog.Tests.ps1`, `tests/Screens.Tests.ps1`

**Interfaces:**
- Consumes: `Get-Signers -Config -Key -> string[]`, `Test-FileSignature -Path -AllowedSigners [-ExactCN] -> bool`, `ConvertTo-HashtableDeep`.
- Produces:
  - `Catalog.ps1`: `$script:RemoteChoices` (Shared shapes) and `Get-RemoteChoice [-Choices <AllowNull object>] -> string`.
    - When `$Choices` is an `IDictionary`: `([string]$Choices['Remote']).ToUpperInvariant()` if it is in `$script:RemoteChoices`;
    - anything else is `'ANYDESK'`;
    - it never throws.
    - **Plan call:** it lives in `Catalog.ps1` because the plan, the final screen, the report and the start screen all load it already. It is case-insensitive, like Office's default.
  - `New-DefaultChoices` adds `Remote = Get-RemoteChoice -Choices @{ Remote = [string]$Config.defaults.remote }`.
  - `Update-StartChoices` key `R`:
    - the next value after `Get-RemoteChoice -Choices $next` in `$script:RemoteChoices` (wrapping);
    - `ResetCountdown = $true`.
  - `Format-StartScreen`:
    - the `Chrome + AnyDesk` line becomes the two lines of Shared shapes;
    - the reminder line follows when `Get-RemoteChoice -Choices $Choices` is not `ANYDESK`.
  - `Get-StartScreenSegments`:
    - the labelled-line regex becomes `'^(   (?:Type {5}|7-Zip {4}|Office {3}|Remote {3}))(\S+(?: \+ \S+)*)(.*)$'`, so the whole `ANYDESK + SCREENCONNECT` is Green and every other line's value is still its first word;
    - the Yellow-line regex gains the alternative `ScreenConnect = unattended access`;
    - the Chrome line stays one plain segment.
    - **Plan call:** "the whole value" applies to the Remote line only. Type and Office keep their first-word highlight, and their tests stay unchanged.
  - Update the doc comments (keys `L / D / Z / O / R`).

- [ ] **Step 1: Config.** Add the four `config.json` additions exactly as in Shared shapes. `defaults` keeps `sevenZip` and `office`.

- [ ] **Step 2: Write the failing tests.**

  `tests/Config.Tests.ps1`: add `$cfg.apps.screenconnect.signer` to the refs of `'every signer key referenced exists'`, and:
```powershell
  It 'pins the ScreenConnect values (screenconnect spec 4.3)' {
    $cfg.defaults.remote | Should -BeExactly 'ANYDESK'
    $sc = $cfg.apps.screenconnect
    $sc.signer | Should -BeExactly 'connectwise'
    $sc.url | Should -BeExactly 'https://github.com/BenTechit/bentech-winsetup/releases/download/v{version}/ScreenConnect.ClientSetup.exe'
    $sc.sha256 | Should -BeExactly '74E058E0F597CF197132775552FBB6F4BDD21F8A0870E1A638D41A63F7C3FD99'
    $sc.serviceName | Should -BeExactly 'ScreenConnect Client (b58e7c32699a96bf)'
    $cfg.timeoutsMinutes.screenconnect | Should -Be 10; $cfg.timeoutsMinutes.screenconnectService | Should -Be 3
  }
  It 'trusts the ScreenConnect installer by the quoted name Windows shows' { @(Get-Signers -Config $cfg -Key 'connectwise') | Should -Be @('"ConnectWise, LLC"') }
  It 'the ScreenConnect link names a release of the repo Publish uploads to, never latest' {
    $repo = (Get-Content "$PSScriptRoot\..\tools\publish.settings.json" -Raw | ConvertFrom-Json).repo
    $cfg.apps.screenconnect.url | Should -BeLike "https://github.com/$repo/releases/download/v{version}/*"
    $cfg.apps.screenconnect.url | Should -Not -Match 'latest'
  }
```

  `tests/Download.Tests.ps1`, a new Context inside `Describe 'Test-FileSignature'` (it uses the Describe's `$ps`):
```powershell
  Context 'the real ScreenConnect subject (screenconnect spec 4.3, Review Focus 2)' {
    BeforeAll {
      . "$PSScriptRoot\..\src\Common\Config.ps1"
      $script:scSigners = @(Get-Signers -Config (Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json") -Key 'connectwise')
      $script:scSubject = 'CN="ConnectWise, LLC", O="ConnectWise, LLC", L=Tampa, S=Florida, C=US'
      function Use-ScSignature([string]$Status) {
        $script:fake = [pscustomobject]@{ Status = [Management.Automation.SignatureStatus]$Status; SignerCertificate = [pscustomobject]@{ Subject = $script:scSubject } }
        Mock Get-AuthenticodeSignature { $script:fake } }
    }
    It 'the quoted config entry accepts the real subject' { Use-ScSignature 'Valid'; Test-FileSignature -Path $ps -AllowedSigners $scSigners | Should -BeTrue }
    It 'an entry without the quotes would refuse it' { Use-ScSignature 'Valid'; Test-FileSignature -Path $ps -AllowedSigners @('ConnectWise, LLC') | Should -BeFalse }
    It '-ExactCN refuses the quoted subject, so the step does not use it' { Use-ScSignature 'Valid'; Test-FileSignature -Path $ps -AllowedSigners $scSigners -ExactCN | Should -BeFalse }
    It 'refuses status <_> (an expired installer is not Valid)' -ForEach 'UnknownError', 'NotTrusted', 'HashMismatch', 'NotSigned' {
      Use-ScSignature $_; Test-FileSignature -Path $ps -AllowedSigners $scSigners | Should -BeFalse }
  }
```

  `tests/Catalog.Tests.ps1`:
```powershell
Describe 'Get-RemoteChoice (screenconnect spec 4.1)' {
  It '<Why> is <Expected>' -ForEach @(
    @{ Why = 'ANYDESK';                Choices = @{ Remote = 'ANYDESK' };       Expected = 'ANYDESK' }
    @{ Why = 'SCREENCONNECT';          Choices = @{ Remote = 'SCREENCONNECT' }; Expected = 'SCREENCONNECT' }
    @{ Why = 'BOTH';                   Choices = @{ Remote = 'BOTH' };          Expected = 'BOTH' }
    @{ Why = 'a lower-case both';      Choices = @{ Remote = 'both' };          Expected = 'BOTH' }
    @{ Why = 'choices without Remote'; Choices = @{ Mode = 'LAPTOP' };          Expected = 'ANYDESK' }
    @{ Why = 'an empty Remote';        Choices = @{ Remote = '' };              Expected = 'ANYDESK' }
    @{ Why = 'an unknown Remote';      Choices = @{ Remote = 'TEAMVIEWER' };    Expected = 'ANYDESK' }
    @{ Why = 'no choices at all';      Choices = $null;                         Expected = 'ANYDESK' }
  ) { Get-RemoteChoice -Choices $Choices | Should -BeExactly $Expected }
  It 'a state.json from an older version (no Remote) reads as ANYDESK (Review Focus 1)' {
    $old = ConvertTo-HashtableDeep -InputObject ('{"Choices":{"Mode":"LAPTOP","SevenZip":true,"Office":"CRAFT"}}' | ConvertFrom-Json)
    Get-RemoteChoice -Choices $old.Choices | Should -BeExactly 'ANYDESK'
  }
}
```

  `tests/Screens.Tests.ps1`. First, update existing tests:
  - Every `'   Chrome + AnyDesk   always'` becomes `'   Chrome   always'` (lines 197, 260, 273, 418 and 426; at 426 the `-like` pattern becomes `'   Chrome   always'`).
  - Line 148's toggle list becomes `'L','D','Z','O','R'`.
  - Line 197's v2-layout test (choices without Remote) also expects `('   Remote   ANYDESK'.PadRight(53) + 'R = anydesk / sc / both')`, and `($l -join "`n") | Should -Not -Match 'unattended'`.
  - Line 418's `Write-StartScreenLines` test gains the reminder line in `-Lines` and asserts `@($w | Where-Object { $_.T -like '   ScreenConnect =*' })[0].C | Should -Be 'Yellow'`. Its existing assertion already requires `B = 'Black'` on every write.

  Then add:
```powershell
  It 'R cycles ANYDESK -> SCREENCONNECT -> BOTH -> ANYDESK and resets the countdown' {
    $r = Update-StartChoices -Choices @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT'; Remote = 'ANYDESK' } -Key 'R'
    $seen = @($r.Choices.Remote); foreach ($i in 1..2) { $r = Update-StartChoices -Choices $r.Choices -Key 'r'; $seen += $r.Choices.Remote }
    $seen | Should -Be @('SCREENCONNECT', 'BOTH', 'ANYDESK'); $r.ResetCountdown | Should -BeTrue }
  It 'R from choices without Remote, or an invalid one, goes to SCREENCONNECT' {
    (Update-StartChoices -Choices $c -Key 'R').Choices.Remote | Should -Be 'SCREENCONNECT'
    (Update-StartChoices -Choices @{ Remote = 'TEAMVIEWER' } -Key 'R').Choices.Remote | Should -Be 'SCREENCONNECT' }
  # in Describe 'New-DefaultChoices'
  It 'opens on ANYDESK; a lower-case default counts, an invalid or missing one is ANYDESK' {
    (New-DefaultChoices -Machine $m -Config $cfg).Remote | Should -BeExactly 'ANYDESK'
    foreach ($case in @(@{ V = 'both'; E = 'BOTH' }, @{ V = 'screenconnect'; E = 'SCREENCONNECT' }, @{ V = 'TEAMVIEWER'; E = 'ANYDESK' }, @{ V = $null; E = 'ANYDESK' })) {
      $x = [pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $true; office = 'CRAFT'; remote = $case.V } }
      (New-DefaultChoices -Machine $m -Config $x).Remote | Should -BeExactly $case.E } }
  # in Describe 'Format-StartScreen (v2)'
  It 'shows <Text>, then the reminder, between Chrome and 7-Zip' -ForEach @(@{ Remote = 'SCREENCONNECT'; Text = 'SCREENCONNECT' }, @{ Remote = 'BOTH'; Text = 'ANYDESK + SCREENCONNECT' }) {
    $l = @(F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT'; Remote = $Remote })
    $at = [array]::IndexOf($l, (('   Remote   ' + $Text).PadRight(53) + 'R = anydesk / sc / both'))
    $at | Should -BeGreaterThan 0; $l[$at - 1] | Should -BeExactly '   Chrome   always'
    $l[$at + 1] | Should -BeExactly "   ScreenConnect = unattended access: get the customer's OK first"
    $l[$at + 2] | Should -BeLike '   7-Zip    *'
    @($l | Where-Object { $_.Length -gt 79 }).Count | Should -Be 0 }
  # in Describe 'start screen colours'
  It 'the whole Remote value is green; the reminder is one yellow segment' {
    $line = '   Remote   ANYDESK + SCREENCONNECT'.PadRight(53) + 'R = anydesk / sc / both'
    $s = @(Get-StartScreenSegments -Line $line)
    $s[0].Text | Should -Be '   Remote   '; $s[1].Text | Should -Be 'ANYDESK + SCREENCONNECT'; $s[1].Color | Should -Be 'Green'; $s[2].Color | Should -BeNullOrEmpty
    (@($s | ForEach-Object { $_.Text }) -join '') | Should -Be $line
    $y = @(Get-StartScreenSegments -Line "   ScreenConnect = unattended access: get the customer's OK first"); $y.Count | Should -Be 1; $y[0].Color | Should -Be 'Yellow' }
  # in Describe 'Show-StartScreen'
  It 'R picks ScreenConnect, shows the reminder and restarts the countdown' {
    $script:rSent = $false
    $r = Invoke-StartScreen -KeyAt { param($s) if (-not $script:rSent -and $s -ge 4) { $script:rSent = $true; 'R' } }
    $r.Remote | Should -Be 'SCREENCONNECT'; Get-ElapsedSeconds | Should -BeGreaterOrEqual 34
    $screens[0] | Should -Not -Match 'unattended access'; @($screens | Where-Object { $_ -match 'unattended access' }).Count | Should -BeGreaterThan 0 }
```
- [ ] **Step 3: Run** the four files. Expected: FAIL (no `remote` default, no `Get-RemoteChoice`, the old Chrome line).
- [ ] **Step 4: Implement** the Produces list. Re-save with BOM.
- [ ] **Step 5: Run** the four files, then the full suite. Expected: `Failed: 0`. The plan does not read `Remote` yet; Task 2 adds the rules.
- [ ] **Step 6: Review gate, then commit:** `feat: Remote choice (AnyDesk, ScreenConnect or both) on the start screen; ScreenConnect config`.

---

### Task 2: The screenconnect step and its place in the plan

**Files:**
- Create: `src/Steps/ScreenConnect.ps1`, `tests/ScreenConnect.Tests.ps1`
- Modify: `src/Engine/Catalog.ps1` (catalog entry, `Get-StepPlan` rules and doc comment), `tools/Build-Bundle.ps1` (`$BundleOrder`)
- Test: `tests/ScreenConnect.Tests.ps1`, `tests/Catalog.Tests.ps1`

**Interfaces:**
- Consumes:
  - from Task 1: `Get-RemoteChoice`; `apps.screenconnect`; `timeoutsMinutes.screenconnect` and `.screenconnectService`;
  - existing helpers: `Get-RemoteFile -Url -Destination -> string`, `Test-FileSignature -Path -AllowedSigners -> bool`, `Invoke-External -FilePath -TimeoutMinutes -> @{ ExitCode; TimedOut }`, `Wait-SetupDelay -Seconds`, `Enter-SetupWait -LimitMinutes` / `Exit-SetupWait`, `Set-SetupNow -Title`, `Add-SetupActivity -Text`, `Get-Signers`, `New-StepResult`, `Write-SetupLog`.
- Produces (all in `src/Steps/ScreenConnect.ps1`; none throws):
  - `Get-ScreenConnectUrl -Template <string> -Version <AllowEmpty string> -> string|$null`: `$Template.Replace('{version}', $Version)` when `$Version -cmatch '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+\z'`, else `$null`. **Plan call:** "known" means Build-Bundle's own version rule, so `dev`, empty or anything odd can never become part of a link.
  - `Get-ScreenConnectServiceState -Name <string> -> 'Running'|'NotRunning'|'Missing'`:
    - reads `@(Get-Service -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Name })`;
    - none -> `Missing`; `[string]$_.Status -eq 'Running'` -> `Running`; any other status -> `NotRunning`;
    - an exception -> `Missing`, logged at WARN.
    - The exact-name filter keeps another company's client out (Review Focus 3).
  - `Wait-ScreenConnectService -Name <string> -TimeoutMinutes <double> [-PollSeconds <double> = 5] -> 'Running'|'NotRunning'|'Missing'`:
    - reads the state at once; while it is not `Running`, up to `[math]::Ceiling($TimeoutMinutes * 60 / $PollSeconds)` times: `Wait-SetupDelay -Seconds $PollSeconds`, then read again;
    - returns the last state read;
    - `Enter-SetupWait -LimitMinutes $TimeoutMinutes` around the loop, `Exit-SetupWait` in `finally`.
    - **Plan call:** the limit is counted in polls (36 for 3 min), not by the clock. Tests stay deterministic, and a clock jump after the install cannot stretch it.
  - `Get-SignerEndDateText -Path <string> -> string`: `(Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).SignerCertificate.NotAfter` as `dd/MM/yyyy HH:mm` (invariant culture), or `'unknown'`.
  - `Test-ScreenConnectInstaller -Path <string> -Sha256 <string> -Signers <string[]> -> string`:
    - `''` when both checks pass, else the name of the failed check, `'SHA-256'` or `'signature'`;
    - SHA-256 first: `(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash`, compared with `[string]::Equals(..., 'OrdinalIgnoreCase')`;
    - a mismatch or an unreadable file logs ERROR `ScreenConnect installer check failed: SHA-256`, with `expected` and `actual`;
    - then `Test-FileSignature -Path $Path -AllowedSigners $Signers` (no `-ExactCN`);
    - a refusal logs ERROR `ScreenConnect installer check failed: signature`, with `pcDate` (now, `dd/MM/yyyy HH:mm`) and `certificateEnds` (`Get-SignerEndDateText`, read while the file still exists).
    - **Plan call:** a SHA-256 mismatch skips the signature check; the file is not Ben's either way.
  - `Invoke-StepScreenConnect -Context <hashtable> [-PollSeconds <double> = 5] -> StepResult`, the outcomes in Shared shapes, in this order:
    1. the config (settings, `Get-Signers` inside a `try`);
    2. `Get-ScreenConnectServiceState`: anything but `Missing` is "already installed", so go to step 7;
    3. `Get-ScreenConnectUrl -Version ([string]$script:SetupVersion)`;
    4. NOW `downloading`, then `Get-RemoteFile` to `Join-Path $Context.DownloadDir 'ScreenConnect.ClientSetup.exe'`;
    5. NOW `checking`, then `Test-ScreenConnectInstaller`; a failure deletes the file;
    6. NOW `installing`, then `Invoke-External -FilePath <exe> -TimeoutMinutes ([double]timeoutsMinutes.screenconnect)`, with no `-ArgumentList`; it logs `ScreenConnect installer ended` with `exitCode` and `timedOut` (WARN when timed out);
    7. NOW `waiting for the service`, then `Wait-ScreenConnectService -TimeoutMinutes ([double]timeoutsMinutes.screenconnectService) -PollSeconds $PollSeconds`;
    8. the result and the activity line.
    - It uses no `Write-Host`, `Start-Sleep` or `-ExactCN`.
  - `Catalog.ps1`:
    - the entry `@{ Id = 'screenconnect'; Title = 'ScreenConnect'; Short = 'ScreenConnect'; Function = 'Invoke-StepScreenConnect' }` goes right after `anydesk`;
    - `Get-StepPlan` gets `'anydesk' { (Get-RemoteChoice -Choices $Choices) -ne 'SCREENCONNECT' }` and `'screenconnect' { (Get-RemoteChoice -Choices $Choices) -ne 'ANYDESK' }`;
    - update the doc comment.
  - `$BundleOrder`: `'Steps\ScreenConnect.ps1'` right after `'Steps\Apps.ps1'`.

- [ ] **Step 1: Write the failing tests** in `tests/ScreenConnect.Tests.ps1`.
  - **Header:** a SAFETY comment: nothing is downloaded, installed or written outside `$TestDrive`; `Get-Service` and the installer are always mocked.
  - **BeforeAll:**
    - dot-sources Common `StepResult`, `Logging`, `Activity`, `Process`, `Download`, `Config`, then `Steps\ScreenConnect.ps1`;
    - `$script:cfg` from `Read-SetupConfig`, and `$script:ConfigJson`, the raw text;
    - `$script:scName = 'ScreenConnect Client (b58e7c32699a96bf)'`;
    - `$script:placeholderHash`, the upper-case SHA-256 of the UTF-8 bytes of `placeholder`.
  - **Fixture `New-ScContext`:** the config from `$script:ConfigJson` with `apps.screenconnect.sha256 = $script:placeholderHash`, `DownloadDir` under `$TestDrive`, and `State = @{ Machine = @{ Arch = 'x64' }; Choices = @{ Remote = 'SCREENCONNECT' } }`.
  - **Fixture `Initialize-ScMocks`** (BeforeEach) sets `$script:SetupVersion = '2026.10.20.1'`, then records and answers:
    - `$script:now`: each `Set-SetupNow` `$Title`;
    - `$script:waits`: each `Wait-SetupDelay` `$Seconds`;
    - `$script:downloads`: each `Get-RemoteFile` Url and Destination. It throws `$script:downloadError` when set, else writes `placeholder` to Destination;
    - `$script:sigCalls`: Path and Signers, answered by `$script:sigOk` (default `$true`);
    - `$script:ext`: FilePath, ArgumentList and TimeoutMinutes, answered by `$script:extHandler`. The default sets `$script:svc = $script:svcAfterInstall` (default `'Running'`) and returns exit 0, not timed out;
    - `Get-Service`: counts `$script:svcReads`. The state is `Running` when `$script:svcRunningFrom` is set and `$script:svcReads -ge` it, else `$script:svc` (default `'Missing'`). `Missing` -> `Write-Error` and nothing; otherwise `[pscustomobject]@{ Name = $script:svcName (default the real name); Status = <state> }`;
    - `Get-AuthenticodeSignature`: sets `$script:exeExistedAtRead = Test-Path -LiteralPath $LiteralPath` and returns Status `UnknownError` with `SignerCertificate.NotAfter = [datetime]'2027-02-19T13:59:59'`;
    - `$script:activity` (each Text) and `$script:logs` (Message, Level, Data).
  - **Do not mock `Test-Path` or `Remove-Item`:** the installer is a real `$TestDrive` file.
```powershell
Describe 'Get-ScreenConnectUrl' {
  It 'puts this release''s version in the link' {
    Get-ScreenConnectUrl -Template $cfg.apps.screenconnect.url -Version '2026.10.20.1' |
      Should -BeExactly 'https://github.com/BenTechit/bentech-winsetup/releases/download/v2026.10.20.1/ScreenConnect.ClientSetup.exe' }
  It 'an unknown version (<_>) gives no link' -ForEach 'dev', '', 'v2026.10.20.1', '2026.10.20', '2026.10.20.1 ', '2026.10.20.1/../latest' {
    Get-ScreenConnectUrl -Template $cfg.apps.screenconnect.url -Version $_ | Should -BeNullOrEmpty }
}
Describe 'Get-ScreenConnectServiceState' {
  It '<Status> is <Expected>, read by the exact name' -ForEach @(@{ Status = 'Running'; Expected = 'Running' }, @{ Status = 'Stopped'; Expected = 'NotRunning' }, @{ Status = 'StartPending'; Expected = 'NotRunning' }) {
    $script:st = $Status; Mock Get-Service { [pscustomobject]@{ Name = 'ScreenConnect Client (b58e7c32699a96bf)'; Status = $script:st } }
    Get-ScreenConnectServiceState -Name $scName | Should -Be $Expected
    Should -Invoke Get-Service -ParameterFilter { $Name -eq 'ScreenConnect Client (b58e7c32699a96bf)' } }
  It 'no such service is Missing, and never throws' { Mock Get-Service { Write-Error "Cannot find any service with service name 'x'." }; Get-ScreenConnectServiceState -Name $scName | Should -Be 'Missing' }
  It 'another company''s ScreenConnect client is Missing (Review Focus 3)' {
    Mock Get-Service { [pscustomobject]@{ Name = 'ScreenConnect Client (0123456789abcdef)'; Status = 'Running' } }; Get-ScreenConnectServiceState -Name $scName | Should -Be 'Missing' }
}
Describe 'Invoke-StepScreenConnect' {
  BeforeEach { Initialize-ScMocks; $script:ctx = New-ScContext; $script:exe = Join-Path $script:ctx.DownloadDir 'ScreenConnect.ClientSetup.exe' }
  It 'downloads this release''s installer, checks it, runs it with no arguments and waits for the service' {
    $r = Invoke-StepScreenConnect -Context $ctx
    $r.Status | Should -Be 'Done'; $r.Message | Should -BeExactly 'ScreenConnect installed'; @($r.Notes).Count | Should -Be 0; $r.Data.Service | Should -Be 'Running'
    $script:downloads[0].Url | Should -BeExactly 'https://github.com/BenTechit/bentech-winsetup/releases/download/v2026.10.20.1/ScreenConnect.ClientSetup.exe'
    $script:downloads[0].Destination | Should -Be $exe
    $script:sigCalls[0].Path | Should -Be $exe; @($script:sigCalls[0].Signers) | Should -Be @('"ConnectWise, LLC"')
    $script:ext.Count | Should -Be 1; $script:ext[0].FilePath | Should -Be $exe; $script:ext[0].ArgumentList | Should -BeNullOrEmpty; $script:ext[0].TimeoutMinutes | Should -Be 10
    @($script:activity.Text) | Should -Be @('ScreenConnect installed - this PC will appear in your ScreenConnect list') }
  It 'shows each phase in NOW' { $null = Invoke-StepScreenConnect -Context $ctx
    @($script:now) | Should -Be @('ScreenConnect: downloading', 'ScreenConnect: checking', 'ScreenConnect: installing', 'ScreenConnect: waiting for the service') }
  It 'a service already there skips the install' {
    $script:svc = 'Running'; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Message | Should -BeExactly 'ScreenConnect already installed'; $script:downloads.Count | Should -Be 0; $script:ext.Count | Should -Be 0
    @($script:now) | Should -Be @('ScreenConnect: waiting for the service'); $script:activity.Count | Should -Be 1 }
  It 'another company''s ScreenConnect does not count: Ben''s is installed (Review Focus 3)' {
    $script:svcName = 'ScreenConnect Client (0123456789abcdef)'; $script:svc = 'Running'
    $null = Invoke-StepScreenConnect -Context $ctx; $script:downloads.Count | Should -Be 1; $script:ext.Count | Should -Be 1 }
  It 'version <_> is unknown: Failed, nothing downloaded' -ForEach 'dev', '' {
    $script:SetupVersion = $_; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Status | Should -Be 'Failed'; $r.Message | Should -BeExactly 'ScreenConnect: release version unknown'; $script:downloads.Count | Should -Be 0 }
  It 'a SHA-256 mismatch deletes the installer and never runs it; the log names the check' {
    $ctx.Config.apps.screenconnect.sha256 = 'F' * 64; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Message | Should -BeExactly 'ScreenConnect installer check failed'; Test-Path -LiteralPath $exe | Should -BeFalse; $script:ext.Count | Should -Be 0
    @($script:logs | Where-Object { $_.Message -eq 'ScreenConnect installer check failed: SHA-256' }).Count | Should -Be 1 }
  It 'the SHA-256 is compared without regard to case' {
    $ctx.Config.apps.screenconnect.sha256 = $script:placeholderHash.ToLowerInvariant(); (Invoke-StepScreenConnect -Context $ctx).Status | Should -Be 'Done' }
  It 'a refused signature deletes the installer; the log gives the PC date and the certificate end date' {
    $script:sigOk = $false; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Message | Should -BeExactly 'ScreenConnect installer check failed'; Test-Path -LiteralPath $exe | Should -BeFalse; $script:ext.Count | Should -Be 0
    $line = @($script:logs | Where-Object { $_.Message -eq 'ScreenConnect installer check failed: signature' })[0]
    $line.Data.certificateEnds | Should -Be '19/02/2027 13:59'; $line.Data.pcDate | Should -Match '^[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}$'
    $script:exeExistedAtRead | Should -BeTrue }
  It 'a failed download is Failed with the reason' {
    $script:downloadError = 'download failed after 3 attempts: x'
    (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect download failed: download failed after 3 attempts: x'; $script:ext.Count | Should -Be 0 }
  It 'the exit code decides nothing: 1603 with a running service is Done, and the code is logged' {
    $script:extHandler = { param($c) $script:svc = 'Running'; @{ ExitCode = 1603; TimedOut = $false; Output = '' } }
    (Invoke-StepScreenConnect -Context $ctx).Status | Should -Be 'Done'
    @($script:logs | Where-Object { $_.Message -eq 'ScreenConnect installer ended' -and $_.Data.exitCode -eq 1603 }).Count | Should -Be 1 }
  It 'a service that exists but does not run: Done with the yellow Note after the full wait (Review Focus 3)' {
    $script:svcAfterInstall = 'Stopped'; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Status | Should -Be 'Done'; $r.Message | Should -BeExactly 'ScreenConnect installed'; @($r.Notes) | Should -Be @('ScreenConnect service not running yet'); $r.Data.Service | Should -Be 'NotRunning'
    $script:waits.Count | Should -Be 36; @($script:waits | Select-Object -Unique) | Should -Be @(5) }
  It 'no service after the wait: Failed (service not found)' {
    $script:svcAfterInstall = 'Missing'; $r = Invoke-StepScreenConnect -Context $ctx
    $r.Status | Should -Be 'Failed'; $r.Message | Should -BeExactly 'ScreenConnect install failed (service not found)'; $r.Data.Service | Should -Be 'Missing'; $script:waits.Count | Should -Be 36
    $script:activity.Count | Should -Be 0 }
  It 'an installer that never exits: stopped at 10 minutes, then the service decides (Review Focus 4)' {
    $script:extHandler = { param($c) @{ ExitCode = $null; TimedOut = $true; Output = '' } }
    (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect install timed out'; $script:ext[0].TimeoutMinutes | Should -Be 10
    $script:svc = 'Missing'; $script:extHandler = { param($c) $script:svc = 'Running'; @{ ExitCode = $null; TimedOut = $true; Output = '' } }
    (Invoke-StepScreenConnect -Context $ctx).Status | Should -Be 'Done' }
  It 'an installer that cannot be started is Failed at once, with no wait' {
    Mock Invoke-External { throw 'The system cannot execute the specified program' }
    (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect install failed (installer could not be started)'; $script:waits.Count | Should -Be 0 }
  It 'polls every 5 s until the service runs, and shows the 3-minute limit only while it waits' {
    Clear-SetupNow; $script:svcAfterInstall = 'Missing'; $script:svcRunningFrom = 4; $script:limits = New-Object System.Collections.ArrayList
    Mock Wait-SetupDelay { [void]$script:waits.Add($Seconds); [void]$script:limits.Add((Get-SetupNow).Wait.LimitMinutes) }
    (Invoke-StepScreenConnect -Context $ctx).Status | Should -Be 'Done'
    @($script:waits) | Should -Be @(5, 5); @($script:limits | Select-Object -Unique) | Should -Be @(3); (Get-SetupNow).Wait | Should -BeNullOrEmpty }
  It 'without apps.screenconnect, or with an unknown signer key, it is not configured and does nothing' {
    $ctx.Config.apps.PSObject.Properties.Remove('screenconnect'); (Invoke-StepScreenConnect -Context $ctx).Message | Should -BeExactly 'ScreenConnect is not configured'
    $other = New-ScContext; $other.Config.apps.screenconnect.signer = 'nope'; (Invoke-StepScreenConnect -Context $other).Message | Should -BeExactly 'ScreenConnect is not configured'
    $script:downloads.Count | Should -Be 0; Should -Invoke Get-Service -Times 0 -Exactly }
}
```
  `tests/Catalog.Tests.ps1`:
  - The catalog test becomes `'lists the 21 steps ...'`, with `'screenconnect|ScreenConnect|Invoke-StepScreenConnect'` after `anydesk`.
  - The Short list gains `'screenconnect|ScreenConnect'` after `'anydesk|AnyDesk'`.
  - `P` gains a fifth parameter: `function P($brand, $mode, $z = $true, $o = 'BUSINESS', $r = $null)`, which adds `Remote = $r` to the Choices only when `$r` is not `$null`.
  - Every existing plan test stays **unchanged**: their Choices have no Remote, which proves "exactly as today".
  - Add:
```powershell
  It 'BOTH: screenconnect right after anydesk' {
    (P DELL LAPTOP $true 'BUSINESS' 'BOTH') -join ',' | Should -Be 'prepare,bitlocker,region,desktop-icons,bloatware,rename,winget,chrome,anydesk,screenconnect,7zip,default-browser,vendor-pass1,office,windows-update,office-finish,vendor-pass2,consumer-app,vendor-cleanup,finalize' }
  It 'SCREENCONNECT: no anydesk, screenconnect right after chrome' {
    $p = @(P ASUS DESKTOP $false 'CRAFT' 'SCREENCONNECT'); $p | Should -Not -Contain 'anydesk'; $p.IndexOf('screenconnect') | Should -Be ($p.IndexOf('chrome') + 1) }
  It 'ANYDESK, an empty or unknown Remote and a lower-case value plan as their Get-RemoteChoice says (Review Focus 1)' {
    $today = (P DELL LAPTOP) -join ','
    foreach ($r in 'ANYDESK', '', 'TEAMVIEWER') { (P DELL LAPTOP $true 'BUSINESS' $r) -join ',' | Should -Be $today -Because $r }
    (P DELL LAPTOP $true 'BUSINESS' 'both') | Should -Contain 'screenconnect' }
  It 'the default choices plan AnyDesk only' {
    $d = New-DefaultChoices -Machine @{ IsLaptop = $true } -Config $cfg; $p = Get-StepPlan -Machine @{ Brand = 'DELL' } -Choices $d -Config $cfg
    $p | Should -Contain 'anydesk'; $p | Should -Not -Contain 'screenconnect' }
```
- [ ] **Step 2: Run** `ScreenConnect.Tests.ps1` and `Catalog.Tests.ps1`. Expected: FAIL (`ScreenConnect.ps1` and the catalog entry are missing).
- [ ] **Step 3: Implement** the Produces list.
  - `src/Steps/ScreenConnect.ps1` opens with a header comment: its purpose (screenconnect spec 4.3); the files it needs (`StepResult`, `Logging`, `Activity`, `Process`, `Download`, `Config`); and "the bundle holds every file".
  - Re-save with BOM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0`. `Bundle.Tests` (`defines every catalog function`), `Waits`, `ErrorAction`, `Colors` and `Encoding` pass.
- [ ] **Step 5: Review gate, then commit:** `feat: screenconnect step: Ben's pinned ScreenConnect installer from this release`.

---

### Task 3: Final screen and report

**Files:**
- Modify: `src/UI/FinalScreen.ps1` (header comment, `Format-FinalScreen:129-152`), `src/Report/Report.ps1` (header comment, `Get-InstalledAppVersions`, `Format-SetupReport:211-238`)
- Test: `tests/Screens.Tests.ps1`, `tests/Finalize.Tests.ps1`

**Interfaces:**
- Consumes: `Get-RemoteChoice` (Task 1); `State.Steps['screenconnect'].Status` and `.Data.Service` (Task 2's outcomes).
- Produces:
  - `Format-FinalScreen`. `$remote = Get-RemoteChoice -Choices $State['Choices']`, never the plan list (spec 4.1):
    - When `$remote -ne 'ANYDESK'`, the New name line is `'  New name : ' + <name> + '     ScreenConnect: ' + $status`. `$status` is `installed` when `Steps.screenconnect.Status -eq 'Done'`, else `NOT installed` (also when `Steps` or the entry is missing).
    - When `$remote -eq 'SCREENCONNECT'`, the AnyDesk lines (`AnyDesk ID...` and the digit rows) and the blank line after them are left out.
    - The 29-line worst case is unchanged, because the status sits on an existing line.
    - Update the doc comment and the header.
  - `Format-SetupReport`:
    - `AnyDesk ID   : not chosen` when `$remote -eq 'SCREENCONNECT'`;
    - right after it, `'ScreenConnect: ' + <text>`:
      - `not chosen` when `$remote -eq 'ANYDESK'`;
      - else, with step `Done` and `Data.Service -eq 'Running'`, `installed (service running)`;
      - with any other `Done`, `installed (service not running)`;
      - otherwise `not installed`.
    - Update the doc comment.
  - `Get-InstalledAppVersions -Config`:
    - with `apps.screenconnect.serviceName` in the config, it reports `ScreenConnect` from the first Uninstall entry with a version whose `DisplayName -eq` that name (case-insensitive);
    - without Config, no ScreenConnect.
    - **Plan call:** the DisplayName comes from `serviceName` (spec 3: product and service share the name) instead of a constant, so a new suffix is the one config edit spec 4.5 describes. `Finalize.ps1` already passes `-Config`.
  - **Plan call:** no change to the progress screen or the verdict.
    - The checklist picks `ScreenConnect` up from the catalog.
    - The NOW line shows the Title.
    - `Get-RunVerdict` already prefixes the step title (`ScreenConnect: ScreenConnect installer check failed`, spec 4.4).

- [ ] **Step 1: Write the failing tests.**

  `tests/Screens.Tests.ps1`, in `Describe 'Format-FinalScreen'`. The existing tests stay unchanged: their state has no Choices, so they still show the ID (spec 4.1).
```powershell
  It 'SCREENCONNECT alone: no AnyDesk line at all, the status on the New name line' {
    $st = New-FinalState; $st.Choices = @{ Remote = 'SCREENCONNECT' }; $st.Steps = @{ screenconnect = @{ Status = 'Done' } }
    $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $l | Should -Contain '  New name : DELL-7HX2K93     ScreenConnect: installed'
    @($l | Where-Object { $_ -match 'AnyDesk|#' }).Count | Should -Be 0
    $with = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $l.Count | Should -Be ($with.Count - 7) }   # 'AnyDesk ID:', 5 digit rows and the blank after them
  It 'NOT installed when the step failed or never ran' -ForEach @(@{ Steps = @{ screenconnect = @{ Status = 'Failed' } } }, @{ Steps = @{} }, @{ Steps = $null }) {
    $st = New-FinalState; $st.Choices = @{ Remote = 'SCREENCONNECT' }; $st.Steps = $Steps
    Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true | Should -Contain '  New name : DELL-7HX2K93     ScreenConnect: NOT installed' }
  It 'BOTH: the AnyDesk ID and the status; the worst case still fits 29 lines' {
    $st = New-FinalState; $st.AnyDeskId = '1234567890'; $st.Choices = @{ Remote = 'BOTH' }; $st.Steps = @{ screenconnect = @{ Status = 'Done' } }
    $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict -Color 'RED' -Banner 'COMPLETED WITH ERRORS' -Failures @(1..20 | % { "Failure $_" }) -Notes @(1..20 | % { "Note $_" })) -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' -DefaultBrowserIsChrome $false -StickLine '  No BenTech USB stick - plug it in now to keep the logs')
    $l.Count | Should -BeLessOrEqual 29; $l | Should -Contain '  AnyDesk ID:'; $l | Should -Contain '  New name : DELL-7HX2K93     ScreenConnect: installed' }
  It 'ANYDESK, choices without Remote and an invalid Remote: the ID and no status (Review Focus 1)' -ForEach @(@{ Choices = @{ Remote = 'ANYDESK' } }, @{ Choices = @{ Mode = 'LAPTOP' } }, @{ Choices = @{ Remote = 'TEAMVIEWER' } }) {
    $st = New-FinalState; $st.Choices = $Choices; $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $l | Should -Contain '  New name : DELL-7HX2K93'; $l | Should -Contain '  AnyDesk ID:'; ($l -join "`n") | Should -Not -Match 'ScreenConnect' }
```
  `tests/Finalize.Tests.ps1`:
  - the header-order test (line 219) gains `'ScreenConnect: '` after `'AnyDesk ID   : '`;
  - its `$green` (Choices without Remote) also gives `$green | Should -Contain 'ScreenConnect: not chosen'`;
  - add:
```powershell
Describe 'Format-SetupReport: remote tools (screenconnect spec 4.4)' {
  # Not "R": PowerShell's built-in alias r (Invoke-History) wins over a function of that name.
  BeforeAll { function Get-RemoteReport([hashtable]$Choices, $Step) {
      $s = New-RunState -Machine $script:fm -Choices $Choices -Plan @('chrome') -Version '2026.10.20.1'; $s.AnyDeskId = '123456789'
      if ($Step) { $s.Steps['screenconnect'] = $Step }
      @(Format-SetupReport -State $s -Verdict (Get-RunVerdict -State $s) -Activation 'Activated' -BitLockerText 'Off' -AppVersions @{}) } }
  It '<Why>' -ForEach @(
    @{ Why = 'no Remote: AnyDesk only (Review Focus 1)'; Choices = @{ Mode = 'LAPTOP' }; Step = $null; AnyDesk = 'AnyDesk ID   : 123456789'; Sc = 'ScreenConnect: not chosen' }
    @{ Why = 'SCREENCONNECT, service running'; Choices = @{ Remote = 'SCREENCONNECT' }; Step = @{ Status = 'Done'; Message = 'ScreenConnect installed'; Data = @{ Service = 'Running' } }; AnyDesk = 'AnyDesk ID   : not chosen'; Sc = 'ScreenConnect: installed (service running)' }
    @{ Why = 'BOTH, service not running'; Choices = @{ Remote = 'BOTH' }; Step = @{ Status = 'Done'; Message = 'ScreenConnect installed'; Data = @{ Service = 'NotRunning' } }; AnyDesk = 'AnyDesk ID   : 123456789'; Sc = 'ScreenConnect: installed (service not running)' }
    @{ Why = 'SCREENCONNECT, step failed'; Choices = @{ Remote = 'SCREENCONNECT' }; Step = @{ Status = 'Failed'; Message = 'ScreenConnect installer check failed'; Data = @{} }; AnyDesk = 'AnyDesk ID   : not chosen'; Sc = 'ScreenConnect: not installed' }
    @{ Why = 'SCREENCONNECT, step never recorded'; Choices = @{ Remote = 'SCREENCONNECT' }; Step = $null; AnyDesk = 'AnyDesk ID   : not chosen'; Sc = 'ScreenConnect: not installed' }
  ) { $l = Get-RemoteReport $Choices $Step; $l | Should -Contain $AnyDesk; [array]::IndexOf($l, $Sc) | Should -Be ([array]::IndexOf($l, $AnyDesk) + 1) }
}
```
  In `Describe 'Get-InstalledAppVersions'`:
```powershell
  It 'with the config it reports ScreenConnect by the exact name of Ben''s client' {
    $scCfg = '{"apps":{"screenconnect":{"serviceName":"ScreenConnect Client (b58e7c32699a96bf)"}}}' | ConvertFrom-Json
    Mock Get-ItemProperty {
      [pscustomobject]@{ DisplayName = 'ScreenConnect Client (0123456789abcdef)'; DisplayVersion = '25.1.0.1' }
      [pscustomobject]@{ DisplayName = 'ScreenConnect Client (b58e7c32699a96bf)'; DisplayVersion = '26.6.6.9747' }
    } -ParameterFilter { @($Path) -contains $script:Uninstall32 }
    (Get-InstalledAppVersions -Config $scCfg)['ScreenConnect'] | Should -Be '26.6.6.9747'
    (Get-InstalledAppVersions).ContainsKey('ScreenConnect') | Should -BeFalse }
```
- [ ] **Step 2: Run** `Screens.Tests.ps1` and `Finalize.Tests.ps1`. Expected: FAIL on the new tests only.
- [ ] **Step 3: Implement** the Produces list. Re-save with BOM.
- [ ] **Step 4: Run** both files, then the full suite. Expected: `Failed: 0`.
- [ ] **Step 5: Review gate, then commit:** `feat: ScreenConnect status on the final screen and in the report`.

---

### Task 4: Publish the installer as the fifth release file; docs

**Files:**
- Modify: `tools/Publish.ps1`, `README.md`, `docs/testing.md`, `CLAUDE.md`
- Test: `tests/Launcher.Tests.ps1` (`Describe 'Publish.ps1'`)

**Interfaces:**
- Consumes: `config/config.json` `apps.screenconnect` and `signers` (Task 1).
- Produces, in `tools/Publish.ps1`:
  - **Param** `[string]$ScreenConnectInstaller`. When empty it is resolved **in the body** to `Join-Path $env:USERPROFILE '.bentech-winsetup\ScreenConnect.ClientSetup.exe'`.
    - **Plan call:** a parameter, so the stubbed dry runs point it into `$TestDrive` and never read Ben's real file.
  - `$installerName = 'ScreenConnect.ClientSetup.exe'`; `$releaseNames` gains it as the fifth name; `$signedNames` is unchanged.
  - `function Get-ScreenConnectInstallerCheck -Path <string> -Sha256 <AllowEmpty string> -Signers <AllowEmptyCollection string[]> -> @{ Problems = [string[]]; NotAfter = [datetime]|$null }`. It never throws. Its problems, in order (it stops at the first one that makes the rest meaningless):
    - `not found: <Path>`;
    - `SHA-256 is <actual>, config.json apps.screenconnect.sha256 is <expected>` (compared OrdinalIgnoreCase);
    - `Authenticode status is <Status>, not Valid`;
    - `not signed by <signers joined with ' or '> (subject: <subject>)`. The subject match is `-like ('*CN=' + [WildcardPattern]::Escape($signer) + '*')` for any non-blank signer, the same rule as `Test-FileSignature`;
    - `could not be read: <message>`.
    - `NotAfter` is `SignerCertificate.NotAfter` whenever it could be read.
  - `function Get-CertificateEndWarning -NotAfter <datetime> -Now <datetime> -> string|$null`: when `($NotAfter - $Now).TotalDays -lt 60`, it returns `WARNING: the ScreenConnect installer's certificate ends <dd/MM/yyyy> (<floor of the days> days from now): build a new installer before then (README "A new ScreenConnect installer")`, else `$null`.
  - **Step 0** becomes `0/6 Checking the source and the ScreenConnect installer`:
    - after the source check, it reads `config\config.json` from the repo root and calls the check;
    - it prints `WARNING: ScreenConnect installer <problem>` for each problem (Yellow);
    - `if ($installerCheck.Problems.Count -gt 0 -and -not $DryRun) { throw ... }`;
    - when `NotAfter` is known, it prints `ScreenConnect installer certificate ends <dd/MM/yyyy>`, then the warning, if any (a warning only, also on a real publish).
    - **Plan call:** the check runs here, before the slow test run, as the version check does.
  - **Step 2:** after `Build-Bundle`, it copies the installer to `dist\ScreenConnect.ClientSetup.exe` whenever the file exists. A real publish only gets this far after the check passed; under `-DryRun` a file that failed its checks is still copied, so the dry run shows the full upload. The existing old-output removal already covers the fifth name.
  - **Step 6:** a missing `dist` file still throws `missing release file`, except the installer under `-DryRun`, which is left out of `$releaseAssets` (it was already warned about).
  - **Header comment and summary:** five files; the name column widens to `{0,-29}`.

- [ ] **Step 1: Write the failing tests** in `tests/Launcher.Tests.ps1`, `Describe 'Publish.ps1'`.
  - `'uploads exactly the four signed files ...'` becomes `'uploads the four signed files and the ScreenConnect installer, never the launcher (R29), and targets HEAD'`, with `$names | Should -Be @('setup.ps1', 'setup.ps1.sig', 'config.json', 'config.json.sig', 'ScreenConnect.ClientSetup.exe')`.
  - Add `It 'a real publish refuses a failed installer check'`: the Publish text `Should -Match 'if \(\$installerCheck\.Problems\.Count -gt 0 -and -not \$DryRun\) \{\s*throw'`.
  - Add a Context that extracts both functions from the AST, as `'Get-PublishSource (git mocked)'` does:
```powershell
  Context 'the ScreenConnect installer check (Review Focus 5)' {
    BeforeAll {
      # Dot-source Get-ScreenConnectInstallerCheck and Get-CertificateEndWarning from the AST of tools\Publish.ps1.
      $script:fakeExe = Join-Path $TestDrive 'sc\ScreenConnect.ClientSetup.exe'; New-Item -ItemType Directory (Split-Path $fakeExe) -Force | Out-Null
      [IO.File]::WriteAllText($fakeExe, 'installer'); $script:fakeHash = (Get-FileHash -LiteralPath $fakeExe -Algorithm SHA256).Hash
      $script:scSubject = 'CN="ConnectWise, LLC", O="ConnectWise, LLC", L=Tampa, S=Florida, C=US'
      function Use-Sig([string]$Status, [string]$Subject) {
        $script:sig = [pscustomobject]@{ Status = [Management.Automation.SignatureStatus]$Status; SignerCertificate = [pscustomobject]@{ Subject = $Subject; NotAfter = [datetime]'2027-02-19T13:59:59' } }
        Mock Get-AuthenticodeSignature { $script:sig } }
      function C([string]$Sha = $script:fakeHash, [string]$Path = $script:fakeExe) { Get-ScreenConnectInstallerCheck -Path $Path -Sha256 $Sha -Signers @('"ConnectWise, LLC"') }
    }
    It 'passes Ben''s file and returns the certificate end date' { Use-Sig 'Valid' $scSubject; $r = C; @($r.Problems).Count | Should -Be 0; $r.NotAfter | Should -Be ([datetime]'2027-02-19T13:59:59') }
    It 'compares the SHA-256 without regard to case' { Use-Sig 'Valid' $scSubject; @((C $fakeHash.ToLowerInvariant()).Problems).Count | Should -Be 0 }
    It 'names each failed check' {
      Use-Sig 'Valid' $scSubject; (@((C ('0' * 64)).Problems) -join "`n") | Should -Match 'SHA-256 is'
      Use-Sig 'UnknownError' $scSubject; (@((C).Problems) -join "`n") | Should -Match 'Authenticode status is UnknownError, not Valid'
      Use-Sig 'Valid' 'CN="Other Remote Ltd", O="Other Remote Ltd", C=US'; (@((C).Problems) -join "`n") | Should -Match 'not signed by'
      (@((C -Path "$TestDrive\nope.exe").Problems) -join "`n") | Should -Match 'not found' }
    It 'warns inside 60 days of the end date, not before' {
      Get-CertificateEndWarning -NotAfter ([datetime]'2027-02-19T13:59:59') -Now ([datetime]'2026-10-20T10:00:00') | Should -BeNullOrEmpty
      Get-CertificateEndWarning -NotAfter ([datetime]'2027-02-19T13:59:59') -Now ([datetime]'2026-12-22T10:00:00') | Should -Match '^WARNING: .*19/02/2027' }
  }
```
  In `Context 'run as -DryRun in a stubbed copy of the repo'`:
  - BeforeAll also copies `config\config.json` to `$pr\config\`;
  - `RunPublish` gains `param([string]$Installer = (Join-Path $TestDrive 'no-installer\ScreenConnect.ClientSetup.exe'))` and passes `-ScreenConnectInstaller $Installer`;
  - the first test also asserts `$r.Out | Should -Match 'WARNING: ScreenConnect installer not found'`. Its dist and `gh` token assertions stay as they are: without the file, four files and the launcher, and `--repo` right after the four;
  - add:
```powershell
    It 'copies an installer to dist and lists it as the fifth file; a failed check is only a warning under -DryRun' {
      $fake = Join-Path $TestDrive 'fake-sc\ScreenConnect.ClientSetup.exe'; New-Item -ItemType Directory (Split-Path $fake) -Force | Out-Null
      [IO.File]::WriteAllText($fake, 'not the real installer')
      $r = RunPublish -Installer $fake
      $r.Code | Should -Be 0; $r.Out | Should -Match 'WARNING: ScreenConnect installer SHA-256 is'
      "$pr\dist\ScreenConnect.ClientSetup.exe" | Should -Exist
      $line = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^DRY RUN - not run: gh ' })[0]
      $tokens = @(($line -replace '^DRY RUN - not run: gh ', '') -split ' ')
      $tokens[7] | Should -Be "$pr\dist\ScreenConnect.ClientSetup.exe"; $tokens[8] | Should -Be '--repo' }
```
- [ ] **Step 2: Run** `tests\Launcher.Tests.ps1`. Expected: FAIL (four names, no functions, no warning).
- [ ] **Step 3: Implement** the Produces list in `tools/Publish.ps1`. Re-save with BOM.
- [ ] **Step 4: Run** `Launcher.Tests.ps1`, then the full suite. Expected: `Failed: 0`. `'the launcher does not change in v2'` still passes.
- [ ] **Step 5: `README.md`**
  - **Intro:** link the screenconnect spec and this plan beside the Craft ones. "with the AnyDesk ID in big digits" becomes "... when AnyDesk was chosen".
  - **"What it does", item 8.** Replace "no unattended password, the customer accepts every connection" (spec 4.6) with:
    - **Google Chrome** (always), then the **remote tool** that **R** picked: **AnyDesk** (the default; no unattended password, the customer accepts every connection), **ScreenConnect**, or both;
    - ScreenConnect is **unattended on purpose**: it connects without the customer clicking Accept, so get the customer's OK at the counter (for example on the repair form). It enrols the PC in Ben's ScreenConnect list (name, IP, user name). That is the one exception to "the tool collects nothing off-machine";
    - the installer is Ben's own, from the run's own release, checked against the SHA-256 in the signed `config.json` and the `ConnectWise, LLC` signature.
  - **Start-screen sample** and text: the `Chrome   always` and `Remote   ANYDESK ... R = anydesk / sc / both` lines; a sentence on the yellow reminder; the key table gains `R`; "Chrome and AnyDesk always get installed" becomes "Chrome always gets installed".
  - **Final screen (Daily use 5):** the AnyDesk ID shows only when AnyDesk was chosen. With ScreenConnect the `New name` line ends in `ScreenConnect: installed` or `NOT installed`. The PC should appear in the list under that name after the final restart (unproven until docs/testing.md 1.18).
  - **Publishing:** step 3 becomes five files, the fifth being `ScreenConnect.ClientSetup.exe` from `%USERPROFILE%\.bentech-winsetup\`, with no `.sig`, and checked first (exists, SHA-256, `Valid` ConnectWise signature; `-DryRun` only warns). The end-date line and the 60-day warning are mentioned. "The launcher fetches the four files" stays true and stays as it is.
  - **New subsection `### A new ScreenConnect installer`** (spec 4.5): the three steps;
    - the file lives beside the signing key, never in the repo or a synced folder;
    - `Get-FileHash <file> -Algorithm SHA256`, and `(Get-AuthenticodeSignature <file>).Status`, `.SignerCertificate.Subject` and `.NotAfter` to check it;
    - `serviceName` changes only if a test install shows another suffix;
    - build it **before 19/02/2027** (no timestamp); Publish warns 60 days ahead, and until then the step refuses the old installer with a red line;
    - a rollback brings back that release's own installer.
  - **"Changing apps and lists":** an `apps.screenconnect` bullet covering:
    - the fields, and why `{version}` is never `latest`;
    - `signers.connectwise` keeps the quotes Windows puts around `ConnectWise, LLC`, and why `-ExactCN` is not used;
    - `defaults.remote`;
    - `timeoutsMinutes.screenconnect` and `screenconnectService`.
- [ ] **Step 6: `docs/testing.md`**
  - **Line 78:** append "This is AnyDesk's rule; ScreenConnect, when chosen, is the one unattended tool (1.18)."
  - **Line 100 (worst-case final screen):** add "also with Remote BOTH".
  - **A new section `### 1.18 ScreenConnect (screenconnect spec 6)`** after 1.17, with these checkboxes:
    - **Silent install:** as the elevated setup account, the EXE installs with no window waiting for a click. If one waits, the fix is the MSI from the same Build page with `msiexec /i /qn` (a later amendment).
    - **Service and list:** `ScreenConnect Client (b58e7c32699a96bf)` appears and runs, and the PC appears in Ben's list.
    - **The name in the list:** the old `DESKTOP-...` name may show first; after the final restart it should switch to the new name (unproven; ConnectWise's forum says so). Record what happened.
    - **Exit code:** record the EXE's exit code from `setup.log` (`ScreenConnect installer ended`).
    - **Second run:** the step says `ScreenConnect already installed` and downloads nothing.
    - **BOTH:** the AnyDesk ID still shows and the final screen fits on one screen.
    - **Start screen:** `R` cycles ANYDESK, SCREENCONNECT, BOTH; the whole value is green; the reminder is yellow on black and leaves when R comes back to ANYDESK.
    - **Report lines:** `ScreenConnect: ...` and `AnyDesk ID   : not chosen`.
    - **Proven by mocks only:**
      - the expired-installer refusal: on a VM checkpoint, with the clock set after 19/02/2027, record the `Status` `Get-AuthenticodeSignature` reports for the installer;
      - the publish checks.
  - **Section 5:** add the `(screenconnect)` items: the MSI fallback is unwritten until 1.18 shows a waiting window; the session name after the rename is unproven.
- [ ] **Step 7: `CLAUDE.md`**
  - **Step order:** add `**screenconnect**` after `anydesk`.
  - **A new bullet:** `Choices.Remote` is `ANYDESK` (the default) | `SCREENCONNECT` | `BOTH`, and **R** cycles them. Every reader goes through `Get-RemoteChoice` (missing or invalid means ANYDESK), never through the plan list. `anydesk` runs with ANYDESK or BOTH, `screenconnect` with SCREENCONNECT or BOTH.
  - **Hard rules:** "no customer PII beyond machine identity" gains: except that ScreenConnect, when chosen, is the one unattended remote tool and enrols the PC in Ben's ScreenConnect cloud (spec 4.6).
  - **Sign and publish:**
    - "exactly **four** files" becomes five: the four signed ones plus `ScreenConnect.ClientSetup.exe` (no `.sig`; `config.json` pins its SHA-256), read from `%USERPROFILE%\.bentech-winsetup\` and checked before building;
    - "The v2 and Craft work" becomes "The v2, Craft and ScreenConnect work".
  - **Where things live:** add the spec, this plan and `.superpowers/sdd/2026-10-20-screenconnect/progress.md`.
- [ ] **Step 8: Verify.**
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests`: last line `Failed: 0`.
  - `git diff --quiet main -- launcher keys; $LASTEXITCODE`: `0`.
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Publish.ps1 -Version 2026.10.20.4 -DryRun` prints:
    - `Launcher SHA-256: 702c323aff5e813d7264375d15387d3bcdc12baded3d192f4bc47890663b69ff`, and no `WARNING: the launcher changed`;
    - either `ScreenConnect installer certificate ends 19/02/2027` (Ben's file is in place: the gh line lists five files) or `WARNING: ScreenConnect installer not found: ...` (not yet: four files);
    - and it ends with `DRY RUN: nothing was published.`

    Clean-tree warnings are expected under `-DryRun`. Then `git checkout keys\launcher.sha256` if the dry run touched it.
  - **Never** run `Publish.ps1` without `-DryRun`, `gh`, or `git push`: that is Ben's call.
- [ ] **Step 9: Review gate, then commit:** `feat: publish the ScreenConnect installer as the fifth release file; docs`. Then tell Ben:
  - the branch is ready for the first-laptop test (docs/testing.md 1.18);
  - his installer must be at `%USERPROFILE%\.bentech-winsetup\ScreenConnect.ClientSetup.exe` before a real publish;
  - publishing is his call.

---

## Spec coverage (self-review)

| Spec | Task |
|---|---|
| §2 Q14 installer in each release | 4 (fifth file), 2 (link to this release) |
| §2 Q15 AnyDesk only by default, R adds or switches | 1 |
| §2 Q16 unattended on purpose, reminder | 1 (reminder), 4 (docs) |
| §3 facts: SHA-256, quoted subject, service name, no timestamp | 1 (config, signer test), 2, 4 (end date) |
| §4.1 Remote values, R cycle, two lines, whole-value highlight, reminder Yellow on Black, missing/invalid = ANYDESK for every reader | 1 (`Get-RemoteChoice`, screen), 2 (plan), 3 (final screen, report) |
| §4.2 anydesk with ANYDESK/BOTH; screenconnect after anydesk with SCREENCONNECT/BOTH | 2 |
| §4.3 config additions; signer quotes, no `-ExactCN` | 1 |
| §4.3 steps 1-5: already installed, version-pinned download, `dev` fails, both checks, delete, log which check and the dates, own timeout, exit code logged only, 5 s poll, three outcomes, timed-out message, `Get-Service -Name` | 2 |
| §4.4 NOW, activity line | 2 |
| §4.4 final screen: AnyDesk block only when chosen; status on New name; 29 lines | 3 |
| §4.4 report lines, `AnyDesk ID not chosen`, `Get-InstalledAppVersions` 'ScreenConnect' | 3 |
| §4.5 installer path, Publish checks (DryRun warns), end date and 60-day warning, fifth file without `.sig`, four-file places updated, launcher unchanged, new-installer procedure | 4 |
| §4.6 v1 rules changed: README, testing.md, CLAUDE.md | 4 |
| §4.7 unchanged: AnyDesk step, launcher, colour/tick/ASCII/no-prompt, Office/Craft | 2 (plan without Remote is today's), 4 (launcher hash), static guards every task |
| §6 real-machine items | 4 (testing.md 1.18) |

**Spec points settled by this plan** (flagged for Ben):
- **"In the plan" vs "never from the plan list".** §4.4 says the AnyDesk block shows "when `anydesk` was in the plan". §4.1 says every reader decides from `Choices.Remote`, never from the plan list. This plan follows §4.1. Both give the same answer for every state this version writes.
- **`ScreenConnect: release version unknown`** is taken verbatim as the step message. The final screen then reads `ScreenConnect: ScreenConnect: release version unknown`. It only happens on an unbundled dev run.
- **The expired-installer status.** PowerShell 5.1's `SignatureStatus` has no `NotTimeValid`; an expired certificate shows as another non-`Valid` status. The tests use `UnknownError` and `NotTrusted`, and testing.md 1.18 records the real one.
