# bentech-winsetup: Windows Update "drivers only" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new choice, `WindowsUpdate` = `FULL` (the default) or `DRIVERS`, picked on a new UPDATES row of the toolbox. In DRIVERS mode the windows-update step searches driver updates only, the report says so, and the final screen offers **U** to hand the remaining updates to Windows.

**Architecture:**
- **One reader.** `Get-WindowsUpdateChoice` (`Catalog.ps1`, beside `Get-RemoteChoice`) turns any Choices into `FULL` or `DRIVERS`; missing, empty, unknown or `$null` is `FULL`. Every reader goes through it: the step, the child round, the report, the final screen, the toolbox view and plan preview.
- **The child learns the mode from `state.json`**, like `IsWindows10`. `Invoke-SetupWuRoundProcess` reads `Choices` and passes `Invoke-WuRound -Scope`. There is no new command-line switch, so `Param.ps1` and the launcher do not change.
- **A profile may set `windowsUpdate`.** `Get-ProfileChoices` returns that key only when the profile sets it. So every overlay (`New-DefaultChoices`, the Profile click) leaves a DRIVERS pick alone, and `Test-ProfileChanged` compares it only then (spec 3.1, builder check).
- **Order.** Task 1 is the engine (reachable through `defaults.windowsUpdate`), Task 2 the toolbox row, Task 3 the final screen's U key. Each task ends green and carries its own docs.

**Tech Stack:** Windows PowerShell 5.1, the WUA COM API (mocked in tests), WPF from .NET Framework 4.8 (parsed offscreen, never shown), Pester on the dev PC only.

**Spec:** `docs/specs/2026-10-22-windows-update-option-design.md` (approved by Ben, Q36 to Q40). It amends the v1, v2 and toolbox specs, which stay binding elsewhere. These also still apply:
- the Global Constraints of `docs/superpowers/plans/2026-10-21-toolbox.md`;
- the ledger rulings in `.superpowers/sdd/*/progress.md` (TB-R3: an invalid Remote is ANYDESK, not the profile's value; TB-R5: the window's step names; TB-R8: the console fallback waits for Enter).

## Global Constraints

**Platform and safety**
- Windows PowerShell **5.1 only**. No modules, nothing downloaded or installed at run time.
- **Never run any of these on this PC:** `setup.ps1`, a setup step, the launcher, `Publish.ps1`, Windows Update, `msiexec` or any installer.
- **Mocks:**
  - The WUA COM touchpoints are mocked (`Search-WuUpdates`, `Set-WuHidden`, `Invoke-WuDownload`, `Invoke-WuInstall`, `Get-WuRebootRequired`, `New-WuSession`, `Register-MicrosoftUpdateService`), and so is `Invoke-External`.
  - **No test opens `ms-settings:`**: `Show-FinalScreen` always gets a `-Launch` seam, and `Start-Process` is mocked to throw (`tests\Screens.Tests.ps1` BeforeEach).
  - **No test opens a window or stops WPF** (`-ShowDialog` / `-ShutdownDispatcher` seams, as today).
- **The launcher must not change.** `launcher\BenTechSetup.template.cmd`, `keys\public-key.xml` and `src\Entry\Param.ps1` stay as they are, and `keys\launcher.sha256` stays `702c323a...` (pinned by `tests\Launcher.Tests.ps1` and `tests\Bundle.Tests.ps1`).
- **No new `src` file**, so `$BundleOrder` in `tools\Build-Bundle.ps1` does not change.
- **Outward-facing actions need Ben's OK at that moment:** no `git push`, no `gh`.

**Runtime rules (unchanged)**
- **Never parse localized output.** Updates are told apart by the WUA `Type` and `BrowseOnly` criteria, never by a title.
- `$ErrorActionPreference` stays `Continue`, so a cmdlet inside a `try` needs `-ErrorAction Stop`.
- No `Start-Sleep` in step code, and nothing waits without a deadline.
- `Choices` holds ASCII ids only.

**Text, language, colour**
- Console, `setup.log`, `activity.txt` and the report are English ASCII: free text goes through `ConvertTo-ScreenText`.
- **`src\Toolbox\Strings.ps1` stays the only non-ASCII `src` file.** The new Hebrew lives there only.
- No `DarkYellow` / `DarkMagenta`. XAML colours stay in the one resource dictionary (the new row uses `TileStyle` and `TileGlyphStyle`, nothing new).

**Values the spec pins (copy exactly)**
- **The choice:**
  - Choices key `WindowsUpdate`: `FULL` | `DRIVERS`;
  - `config.json` `defaults.windowsUpdate`: `"FULL"`;
  - the three shipped profiles do not set `windowsUpdate` (Q37).
- **The toolbox:**
  - row `UPDATES`, between REMOTE and APPS;
  - tiles `Full updates` and `Drivers only`;
  - plan line `Windows Update (drivers only)` in DRIVERS mode.
- **The DRIVERS search:**
  - only `Type='Driver'`;
  - optional updates (`BrowseOnly=1`) stay skipped, and each DRIVERS round logs how many it skipped;
  - every other rule is unchanged (one at a time, firmware only on AC, round and restart caps, hide and un-hide).
- **The step's activity line:** `Windows Update: drivers only (other updates left to Windows)`.
- **The final screen, DRIVERS only:**
  - key line `  [R] report   [U] Windows Update   [ENTER] finish`;
  - U opens `ms-settings:windowsupdate-action`;
  - feedback `Windows Update started: Windows will finish on its own` or `Could not open Windows Update: open Settings > Windows Update`, the failure in `setup.log`;
  - at most 29 lines; the new lines are at most 79 columns. FULL's key line is unchanged.
- **The report:** after `Restore point:` comes `Updates      : full` or `Updates      : drivers only (other updates left to Windows)`.
- **The verdict does not change** in DRIVERS mode.

**Files, tests, commits**
- Every `.ps1` is UTF-8 **with BOM**. After writing, re-save: `powershell -NoProfile -Command "Get-ChildItem -Recurse -Include *.ps1 src,tests,tools | % { $t=[IO.File]::ReadAllText($_.FullName); [IO.File]::WriteAllText($_.FullName,$t,(New-Object Text.UTF8Encoding $true)) }"`.
- **Test command:** `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` (or one file). **Pass = the last line reads `Failed: 0`.** Baseline on `8e33794`: 2646 tests pass (about 8 minutes). Every task ends with the full suite green.
- **Commits:**
  - Ben's review gate runs before every commit.
  - Conventional commits, each with a second `-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
  - Branch `feat/wu-drivers`, worktree `C:\Users\BenTech\Documents\AI\bentech-winsetup-wu` only.

## Review Focus

The five failure modes most likely to bite, most likely first. Each names the test that pins it.

1. **An older `state.json` resumed by the new version, or an invalid value.**
   - Expected: the run is FULL everywhere: the child searches software and drivers, the report says `full`, and the final screen keeps today's key line.
   - Tests: Task 1 `'-WuRound passes the state''s Windows Update choice; none, an invalid one or no state is FULL (Review Focus 1, 3)'` and `'Updates follows the restore point ... (Review Focus 1)'`; Task 3 `'DRIVERS: the key line offers U ... (Review Focus 1)'`.
2. **A profile click silently resetting a DRIVERS pick, or `(changed)` appearing for it** (spec 3.1, builder check).
   - Expected: Home, Business and Clean leave the tile alone, and DRIVERS is no change for a profile that does not set the key.
   - Tests: Task 1 `'DRIVERS is no change for a profile that does not set windowsUpdate (Review Focus 2)'`; Task 2 `'... a profile without windowsUpdate keeps it ... (Review Focus 2)'`.
3. **The choice lost at the child-process boundary.** The child runs in its own process and has `-Scope 'FULL'` as its default, so a value that is not passed through silently runs FULL.
   - Expected: DRIVERS in `state.json` reaches `Invoke-WuRound -Scope DRIVERS`, and that round never searches software.
   - Tests: Task 1, the Entry test of Review Focus 1, and `'DRIVERS searches drivers only, then counts the optional ones ... (Review Focus 3)'`.
4. **The extra optional-driver search failing** (a WUA error on `BrowseOnly=1`) and taking the DRIVERS round down with it.
   - Expected: one WARN; the round installs its drivers and has no Error.
   - Test: Task 1 `'a failed optional-driver count is one WARN; the DRIVERS round goes on (Review Focus 4)'`.
5. **U breaking the final screen.** A Settings launch that throws, or a new line that pushes the screen past 29 lines or 79 columns, would end or garble the one screen that holds the AnyDesk ID before cleanup.
   - Expected: the could-not line and a WARN; Enter still finishes; the worst case stays at 29 lines or fewer.
   - Tests: Task 3 `'a U that cannot open Settings ... (Review Focus 5)'` and `'DRIVERS worst case ... (Review Focus 5)'`.

## Plan calls (where the spec is silent)

1. **The child reads the choice from `state.json`**, the way it already reads `IsWindows10`; `Invoke-WuRound` gets `-Scope 'FULL'|'DRIVERS'` (the default is `FULL`). There is no new command-line switch, so `Param.ps1` and the launcher do not change.
2. **Counting the optional drivers** (spec 3.2 "logs how many"):
   - **DRIVERS round 1 only** runs one more WUA search, `BrowseOnly=1 and Type='Driver'`, after the driver search. The count is logged once per run, and this search is answered from the catalog the driver search has just downloaded, so it costs seconds. Later rounds run no extra search (controller ruling WU-R1); the tests check round 1 does and round 2 does not;
   - INFO `Optional driver updates skipped` with `@{ round; count; titles }` (at most 20 titles, ASCII);
   - a failure is WARN `Optional driver updates could not be counted`, and the round goes on;
   - the count is never in `Found` or in the result JSON. FULL runs no extra search.
3. **The step's message** (spec "says `Drivers only`"): the DRIVERS Done message is `Drivers only: installed <n> updates in <r> rounds`. The Continue and Failed messages do not change.
4. **The activity line** `Windows Update: drivers only (other updates left to Windows)` is written once, in round 1, before the child starts and before that round's own line.
5. **A profile's `windowsUpdate`:**
   - present and not `$null` means set; an invalid value is set to `FULL`;
   - `Get-ProfileChoices` returns the key only when it is set, and both overlays copy every key it returns.
6. **`ConvertTo-ValidChoices`** turns an invalid value into `FULL` through `Get-WindowsUpdateChoice`, not into the default profile's value. This follows the spec's "missing or invalid means FULL" and matches TB-R3's Remote rule.
7. **The toolbox:**
   - glyphs E895 (Full) and E950 (Drivers only);
   - the Hebrew copy (Task 2 table);
   - the plan line's key `step.windows-update.drivers`, with `$script:WindowsUpdateDriversTitle` as the fallback;
   - two new preview PNGs (`toolbox-en-drivers.png`, `toolbox-he-drivers.png`).
   All of these are settled on the screenshots.
8. **The final screen:**
   - "The blank spacer line above the key line" is the existing spacer before the Chrome hint and the stick line. The stick line is always shown, so no blank line sits directly above the key line.
   - The status lines get two leading spaces.
   - U redraws at once. Every press opens Settings again, and the line shows the last outcome.
   - In FULL mode U is an ignored key, and `-WindowsUpdateStatus` is ignored.
9. **The `-Launch` default gets `-ErrorAction Stop`** on both `Start-Process` calls, so a refused start is always caught. This touches B and R too: they now always reach their existing WARN.
10. **Docs:** one cross-reference line in each amended spec (v1, v2, toolbox), as the toolbox plan did.

---

## File Structure

```
config/config.json              MOD  T1: defaults.windowsUpdate
src/Engine/Catalog.ps1          MOD  T1: $script:WindowsUpdateChoices, Get-WindowsUpdateChoice
src/Steps/WindowsUpdate.ps1     MOD  T1: Get-WuSearchCriteria -Optional, Invoke-WuRound -Scope, the optional count,
                                         Invoke-StepWindowsUpdate's DRIVERS message and activity line
src/Entry/Main.ps1              MOD  T1: Invoke-SetupWuRoundProcess passes -Scope from state.json
src/UI/StartScreen.ps1          MOD  T1: New-DefaultChoices adds WindowsUpdate
src/Toolbox/SetupPlanner.ps1    MOD  T1: profiles, ConvertTo-ValidChoices, Test-ProfileChanged;
                                     T2: Update-ToolboxModel, Get-ToolboxPlanLines, $script:WindowsUpdateDriversTitle
src/Report/Report.ps1           MOD  T1: the Updates line
src/Toolbox/Strings.ps1         MOD  T2: four keys (en, he)
src/Toolbox/Xaml.ps1            MOD  T2: the UPDATES row (8 grid rows)
src/Toolbox/Toolbox.ps1         MOD  T2: Update-ToolboxView (tiles, step name)
tools/Preview-Toolbox.ps1       MOD  T2: two DRIVERS views (six PNGs)
src/UI/FinalScreen.ps1          MOD  T3: Format-FinalScreen -WindowsUpdateStatus, Show-FinalScreen's U key
tests/Config, Catalog, Screens, SetupPlanner, WindowsUpdate, Entry, Finalize, Toolbox .Tests.ps1      MOD
README.md, docs/testing.md (new 1.20), CLAUDE.md, the v1 / v2 / toolbox specs (one line each)            MOD
```

---

### Task 1: The choice, the drivers-only search and the report (no window yet)

**Files:**
- Modify:
  - `config/config.json`;
  - `src/Engine/Catalog.ps1` (header comment, after `Get-RemoteChoice`);
  - `src/Steps/WindowsUpdate.ps1` (header "Needs", `Get-WuSearchCriteria`, `Invoke-WuRound` and its doc, `Invoke-StepWindowsUpdate` and its doc);
  - `src/Entry/Main.ps1` (`Invoke-SetupWuRoundProcess`);
  - `src/UI/StartScreen.ps1` (`New-DefaultChoices` and its doc);
  - `src/Toolbox/SetupPlanner.ps1` (`Get-SetupProfiles`, `Get-ProfileChoices`, `ConvertTo-ValidChoices`, `Test-ProfileChanged` and their docs);
  - `src/Report/Report.ps1` (doc and header lines);
  - `README.md`, `docs/testing.md`, `CLAUDE.md`.
- Test: `tests/Config.Tests.ps1`, `tests/Catalog.Tests.ps1`, `tests/Screens.Tests.ps1`, `tests/SetupPlanner.Tests.ps1`, `tests/WindowsUpdate.Tests.ps1`, `tests/Entry.Tests.ps1`, `tests/Finalize.Tests.ps1`.

**Interfaces:**
- Consumes: `Get-RemoteChoice` (the pattern to copy), `Search-WuUpdates -Session -Criteria`, `Get-WuExceptionErrorCode`, `ConvertTo-ScreenText`, `Add-SetupActivity -Text`, `Read-RunState`.
- Produces:
  - **`Catalog.ps1`:**
    - `$script:WindowsUpdateChoices = @('FULL', 'DRIVERS')`;
    - `Get-WindowsUpdateChoice [-Choices <AllowNull object>] -> 'FULL'|'DRIVERS'`. It matches case-insensitively, returns upper case and never throws: a copy of `Get-RemoteChoice` on the key `WindowsUpdate`.
  - **`WindowsUpdate.ps1`:**
    - `Get-WuSearchCriteria -Type <Software|Driver> [-Optional] -> string`. `-Optional` gives `BrowseOnly=1` instead of `BrowseOnly=0`, so `-Type Driver -Optional` is `"IsInstalled=0 and IsHidden=0 and BrowseOnly=1 and Type='Driver'"`.
    - `Invoke-WuRound` gains `[ValidateSet('FULL', 'DRIVERS')][string]$Scope = 'FULL'`; see Step 4.
  - **`SetupPlanner.ps1`:**
    - Each `Get-SetupProfiles` entry gains `WindowsUpdate = ''|'FULL'|'DRIVERS'` (`''` = the profile does not set it).
    - `Get-ProfileChoices` returns a `WindowsUpdate` key **only when the profile sets it**.
    - `ConvertTo-ValidChoices` returns exactly 8 keys, the new one `WindowsUpdate = Get-WindowsUpdateChoice -Choices $given`.
  - **`New-DefaultChoices`** returns `WindowsUpdate` too. The Task 2 window model and the console path both read it.

- [ ] **Step 1: Config.** Add `"windowsUpdate": "FULL"` as the last key of `defaults`. The profiles do not change.

- [ ] **Step 2: Write the failing tests.**

  `tests/Config.Tests.ps1`:
```powershell
  It 'pins defaults.windowsUpdate FULL; no shipped profile sets windowsUpdate (wu spec 3.1, Q37)' {
    $cfg.defaults.windowsUpdate | Should -BeExactly 'FULL'
    @($cfg.profiles | Where-Object { $null -ne $_.PSObject.Properties['windowsUpdate'] }).Count | Should -Be 0 }
```
  `tests/Catalog.Tests.ps1` (with the file's own machine and config fixtures):
```powershell
  It 'Get-WindowsUpdateChoice: <Why>' -ForEach @(
    @{ Why = 'DRIVERS'; C = @{ WindowsUpdate = 'DRIVERS' }; E = 'DRIVERS' }, @{ Why = 'any case'; C = @{ WindowsUpdate = 'drivers' }; E = 'DRIVERS' }
    @{ Why = 'full'; C = @{ WindowsUpdate = 'full' }; E = 'FULL' }, @{ Why = 'unknown'; C = @{ WindowsUpdate = 'NONE' }; E = 'FULL' }
    @{ Why = 'empty'; C = @{ WindowsUpdate = '' }; E = 'FULL' }, @{ Why = 'missing (an older state)'; C = @{ Mode = 'LAPTOP' }; E = 'FULL' }
    @{ Why = 'no choices'; C = $null; E = 'FULL' }) { Get-WindowsUpdateChoice -Choices $C | Should -BeExactly $E }
  It 'DRIVERS plans exactly the steps FULL plans (spec 3.2: the same step)' {
    $c = @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'BUSINESS' }
    $full = @(Get-StepPlan -Machine @{ Brand = 'DELL' } -Choices ($c + @{ WindowsUpdate = 'FULL' }) -Config $cfg)
    @(Get-StepPlan -Machine @{ Brand = 'DELL' } -Choices ($c + @{ WindowsUpdate = 'DRIVERS' }) -Config $cfg) -join ',' | Should -BeExactly ($full -join ',')
    $full | Should -Contain 'windows-update' }
```
  `tests/Screens.Tests.ps1`, Describe `New-DefaultChoices`:
```powershell
  It 'opens on FULL; defaults.windowsUpdate counts when the default profile does not set it; an invalid one is FULL (wu spec 3.1)' {
    (New-DefaultChoices -Machine $m -Config $cfg).WindowsUpdate | Should -BeExactly 'FULL'
    foreach ($case in @(@{ V = 'drivers'; E = 'DRIVERS' }, @{ V = 'SOMETIMES'; E = 'FULL' }, @{ V = $null; E = 'FULL' })) {
      $x = [pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $true; office = 'CRAFT'; windowsUpdate = $case.V } }
      (New-DefaultChoices -Machine $m -Config $x).WindowsUpdate | Should -BeExactly $case.E } }
  It 'a default profile that sets windowsUpdate wins over defaults.windowsUpdate' {
    $x = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $x.profiles[0] | Add-Member NoteProperty windowsUpdate 'DRIVERS'
    (New-DefaultChoices -Machine $m -Config $x).WindowsUpdate | Should -BeExactly 'DRIVERS' }
  It 'the console fallback runs FULL: U is no key there (wu spec 3.1)' {
    $r = Update-StartChoices -Choices (New-DefaultChoices -Machine $m -Config $cfg) -Key 'U'
    $r.Choices.WindowsUpdate | Should -BeExactly 'FULL'; $r.Action | Should -Be 'None' }
```
  `tests/SetupPlanner.Tests.ps1`:
  - In `'repairs every key from the defaults ...'`, add `WindowsUpdate = 'everything'` to the input and `$r.Choices.WindowsUpdate | Should -BeExactly 'FULL'`.
  - Add these tests:
```powershell
  # Describe 'profiles'
  It 'a profile may set windowsUpdate (an invalid value is FULL); without it the key is not among its choices (wu spec 3.1)' {
    $x = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $x.profiles[1] | Add-Member NoteProperty windowsUpdate 'drivers'; $x.profiles[2] | Add-Member NoteProperty windowsUpdate 'never'
    (Get-ProfileChoices -Config $x -ProfileId 'home').Contains('WindowsUpdate') | Should -BeFalse
    (Get-ProfileChoices -Config $x -ProfileId 'business').WindowsUpdate | Should -BeExactly 'DRIVERS'
    (Get-ProfileChoices -Config $x -ProfileId 'clean').WindowsUpdate | Should -BeExactly 'FULL' }
  # Describe 'ConvertTo-ValidChoices'
  It 'keeps DRIVERS in any case and returns exactly eight keys' {
    $c = New-DefaultChoices -Machine $m -Config $cfg; $c.WindowsUpdate = 'drivers'
    $r = ConvertTo-ValidChoices -Choices $c -Config $cfg -Machine $m; $r.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS'
    @($r.Choices.Keys | Sort-Object) | Should -Be @('Mode', 'Office', 'Profile', 'Remote', 'RestorePoint', 'SevenZip', 'Tweaks', 'WindowsUpdate') }
  # Describe 'Test-ProfileChanged' ($c = New-DefaultChoices from its BeforeEach)
  It 'DRIVERS is no change for a profile that does not set windowsUpdate (Review Focus 2)' { $c.WindowsUpdate = 'DRIVERS'; Test-ProfileChanged -Choices $c -Config $cfg -Machine $m | Should -BeFalse }
  It 'a profile that sets windowsUpdate: another value is a change, its own is not' {
    $x = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $x.profiles[0] | Add-Member NoteProperty windowsUpdate 'FULL'
    $c.WindowsUpdate = 'DRIVERS'; Test-ProfileChanged -Choices $c -Config $x -Machine $m | Should -BeTrue
    $c.WindowsUpdate = 'FULL'; Test-ProfileChanged -Choices $c -Config $x -Machine $m | Should -BeFalse }
```
  `tests/WindowsUpdate.Tests.ps1`:
  - The `'Windows Update round and step (mocked COM)'` BeforeAll also dot-sources `src\Engine\Catalog.ps1` and sets `$script:OptionalDriverCriteria = "IsInstalled=0 and IsHidden=0 and BrowseOnly=1 and Type='Driver'"`.
  - `Invoke-TestRound` gains `[string]$Scope = 'FULL'` (passed as `-Scope`), and `New-WuContext` gains `[hashtable]$Choices = @{}` (passed to `New-RunState`).
  - The existing FULL tests stay as they are: `'registers Microsoft Update, then searches software and drivers'`, `'is Done with the running total ...'` (`Installed 5 updates in 3 rounds`) and `'writes one activity line per round ...'` pin that FULL is unchanged.
  - Add these tests:
```powershell
  # Describe 'criteria' (the one-line Describe near the top)
  It 'optional drivers' { Get-WuSearchCriteria -Type Driver -Optional | Should -Be "IsInstalled=0 and IsHidden=0 and BrowseOnly=1 and Type='Driver'" }
  # Context 'Invoke-WuRound (child round, COM mocked)'
  It 'DRIVERS searches drivers only, then counts the optional ones: logged, never installed (spec 3.2, Review Focus 3)' {
    $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 's1'))
    $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
    $script:searchResults[$script:OptionalDriverCriteria] = @((New-FakeUpdate -Id 'o1'), (New-FakeUpdate -Id 'o2'))
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -Scope 'DRIVERS'
    @($script:searches) | Should -Be @($script:DriverCriteria, $script:OptionalDriverCriteria)
    @($r.Installed.Id) | Should -Be @('d1'); $r.Found | Should -Be 1; @($script:installCalls | ForEach-Object { $_ }) | Should -Not -Contain 'o1'
    $l = @($script:logs | Where-Object { $_.Message -eq 'Optional driver updates skipped' }); $l.Count | Should -Be 1; $l[0].Data.count | Should -Be 2 }
  It 'a failed optional-driver count is one WARN; the DRIVERS round goes on (Review Focus 4)' {
    $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
    Mock Search-WuUpdates { [void]$script:searches.Add($Criteria); if ($Criteria -like '*BrowseOnly=1*') { throw 'search failed' }; if ($script:searchResults.Contains($Criteria)) { $script:searchResults[$Criteria] } }
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -Scope 'DRIVERS'
    $r.Error | Should -BeNullOrEmpty; @($r.Installed.Id) | Should -Be @('d1')
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Optional driver updates could not be counted' }).Count | Should -Be 1 }
  It 'DRIVERS keeps the firmware rule: on battery a Firmware driver is deferred' {
    $fw = New-FakeUpdate -Id 'fw'; $fw | Add-Member NoteProperty DriverClass 'Firmware'
    $script:searchResults[$script:DriverCriteria] = @($fw, (New-FakeUpdate -Id 'net'))
    $r = Invoke-TestRound -StatePath (New-WuStateFile) -Scope 'DRIVERS' -OnAC $false
    @($script:installCalls | ForEach-Object { $_ }) | Should -Be @('net'); $r.FirmwareDeferred | Should -Be 1 }
  # Context 'Invoke-StepWindowsUpdate (parent step, child process mocked)'
  It 'DRIVERS: round 1 says so once in the activity feed, and Done says Drivers only, with no note (spec 3.2, 3.3)' {
    $script:act = New-Object System.Collections.ArrayList; Mock Add-SetupActivity { [void]$script:act.Add($Text) }
    $script:ctx = New-WuContext -Choices @{ WindowsUpdate = 'DRIVERS' }; $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'd'; Title = 'D' })
    $null = Invoke-StepWindowsUpdate -Context $script:ctx
    @($act) | Should -Be @('Windows Update: drivers only (other updates left to Windows)', 'Windows Update round 1: found 0, installed 1, failed 0')
    $script:act.Clear(); $script:ctx = New-WuContext -Data @{ Rounds = 2; Installed = 5 } -Choices @{ WindowsUpdate = 'DRIVERS' }; $script:childResult = New-ChildResult
    $r = Invoke-StepWindowsUpdate -Context $script:ctx
    $r.Status | Should -Be 'Done'; $r.Message | Should -BeExactly 'Drivers only: installed 5 updates in 3 rounds'; @($r.Notes).Count | Should -Be 0
    @($act) | Should -Be @('Windows Update round 3: found 0, installed 0, failed 0') }
```
  `tests/Entry.Tests.ps1`, Context `-WuRound`:
```powershell
  It '-WuRound passes the state''s Windows Update choice; none, an invalid one or no state is FULL (Review Focus 1, 3)' -ForEach @(
    @{ S = { $s = New-FakeState; $s.Choices = @{ WindowsUpdate = 'drivers' }; $s }; E = 'DRIVERS' }, @{ S = { New-FakeState }; E = 'FULL' }
    @{ S = { $s = New-FakeState; $s.Choices = @{ WindowsUpdate = 'NONE' }; $s }; E = 'FULL' }, @{ S = { $null }; E = 'FULL' }) {
    $script:wantScope = $E; Mock Read-RunState -MockWith $S; Invoke-Entry -WuRound $true -ResultPath "$TestDrive\r.json" | Should -Be 0
    Should -Invoke Invoke-WuRound -Times 1 -Exactly -ParameterFilter { $Scope -ceq $script:wantScope } }
```
  `tests/Finalize.Tests.ps1`:
  - In `'starts with the title and lists the header lines in order'`, append `'Updates      : '` to `$expected` and add `$green | Should -Contain 'Updates      : full'` (that state's Choices have no `WindowsUpdate`).
  - Add this test to `Describe 'Format-SetupReport: profile, tweaks, restore point'`:
```powershell
  It 'Updates follows the restore point: full, or drivers only; an older state or an invalid value is full (wu spec 3.3, Review Focus 1)' {
    foreach ($case in @{ V = 'DRIVERS'; L = 'Updates      : drivers only (other updates left to Windows)' }, @{ V = 'FULL'; L = 'Updates      : full' },
                      @{ V = 'later'; L = 'Updates      : full' }, @{ V = $null; L = 'Updates      : full' }) {
      $c = New-DefaultChoices -Machine $script:fm -Config $rcfg; if ($null -eq $case.V) { $c.Remove('WindowsUpdate') } else { $c.WindowsUpdate = $case.V }
      $l = Get-ToolboxReport $c $null $false; $at = @(0..($l.Count - 1) | Where-Object { $l[$_] -like 'Restore point:*' })[0]
      $l[$at + 1] | Should -BeExactly $case.L } }
```

- [ ] **Step 3: Run them and see them fail.** Run each file above, for example `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests\WindowsUpdate.Tests.ps1`. Expected: the new tests fail (`Get-WindowsUpdateChoice` is not recognized, or `-Scope` / `-Optional` is not a parameter).

- [ ] **Step 4: Implement.**
  - **`Catalog.ps1`:** `$script:WindowsUpdateChoices` and `Get-WindowsUpdateChoice` (see Interfaces). The header comment gains one paragraph, worded like the Remote one.
  - **`Get-WuSearchCriteria`:** add the `-Optional` switch.
  - **`Invoke-WuRound -Scope`:**
    - The search loop runs over `@('Driver')` for DRIVERS and `@('Software', 'Driver')` for FULL (unchanged).
    - The `Windows Update round starting` log gains `scope = $Scope`.
    - **DRIVERS only,** right after the search loop, run one `Search-WuUpdates -Session $session -Criteria (Get-WuSearchCriteria -Type Driver -Optional)` in its own `try`:
      - success: INFO `Optional driver updates skipped` with `@{ round; count; titles }`, where `titles` is at most the first 20, each through `ConvertTo-ScreenText`;
      - a throw: WARN `Optional driver updates could not be counted` with `@{ round; errorCode = (Get-WuExceptionErrorCode ...); error }`, and the round goes on.
    - The optional updates are never converted, added to `Found`, selected, hidden or installed. `-SearchOnly` counts them too (read-only).
    - The doc's step 4 says all of this.
  - **`Invoke-StepWindowsUpdate`:**
    - Set `$driversOnly = (Get-WindowsUpdateChoice -Choices $state['Choices']) -eq 'DRIVERS'`.
    - **When `$round -eq 1` and DRIVERS:** after the cap check and `Save-RunState`, before NOW and the child, call `Add-SetupActivity -Text 'Windows Update: drivers only (other updates left to Windows)'`.
    - The parent's `Windows Update round starting` log gains `scope`.
    - The Done message in DRIVERS is `"Drivers only: installed $n updates in $round rounds"`. FULL keeps `"Installed $n updates in $round rounds"`. Continue and Failed messages do not change.
    - The header's "Needs" names `Catalog.ps1 (Get-WindowsUpdateChoice)`.
  - **`Invoke-SetupWuRoundProcess`:** `$scope = 'FULL'`; when `$runState` is a hashtable, `$scope = Get-WindowsUpdateChoice -Choices $runState['Choices']`; pass `-Scope $scope`. Indexing a `$null` state would throw, hence the guard. Add one line to its comment.
  - **`New-DefaultChoices`:**
    - Add `WindowsUpdate = (Get-WindowsUpdateChoice -Choices @{ WindowsUpdate = [string]$Config.defaults.windowsUpdate })`.
    - The profile overlay becomes `foreach ($key in @($profileChoices.Keys))`, so `WindowsUpdate` is copied only when the profile sets it.
    - Doc: the console start screen shows no line and has no key for it; the run takes this value (spec 3.1).
  - **`Get-SetupProfiles`:** `WindowsUpdate` is `''` when the entry has no `windowsUpdate` property or it is `$null`. Otherwise it is `Get-WindowsUpdateChoice -Choices @{ WindowsUpdate = [string]$entry.windowsUpdate }`.
  - **`Get-ProfileChoices`:** add `WindowsUpdate` to the returned table only when the profile's `WindowsUpdate` is not `''`.
  - **`ConvertTo-ValidChoices`:** add `WindowsUpdate = (Get-WindowsUpdateChoice -Choices $given)`. The doc says "exactly eight keys".
  - **`Test-ProfileChanged`:** before the tweak comparison, add `if ($profileChoices.Contains('WindowsUpdate') -and (Get-WindowsUpdateChoice -Choices $c) -cne $profileChoices.WindowsUpdate) { return $true }`. The doc says the key counts only when the profile sets it.
  - **`Format-SetupReport`:** add `$lines.Add('Updates      : ' + $(if ((Get-WindowsUpdateChoice -Choices $choices) -eq 'DRIVERS') { 'drivers only (other updates left to Windows)' } else { 'full' }))` right after the Restore point line, and update the doc's header list.

- [ ] **Step 5: Re-save as UTF-8 with BOM, then run the full suite.** Expected: the last line reads `Failed: 0`.

- [ ] **Step 6: Docs.**
  - **README:**
    - "What it does" item 15 gains: `With **Drivers only** (the toolbox's UPDATES row) it searches driver updates only; cumulative and feature updates are left to Windows (the final screen's U starts them).`
    - "Changing apps and lists" gains a bullet **`defaults.windowsUpdate`**: `"FULL"` as shipped or `"DRIVERS"`; missing or invalid is FULL. It is the start choice unless the default profile sets `windowsUpdate`.
    - The `profiles` field list gains `windowsUpdate` (optional; `FULL` or `DRIVERS`, an invalid value is FULL). Without it a profile leaves the UPDATES tile as it is, and none of the shipped profiles sets it.
  - **`docs/testing.md`:** a new section **1.20 Windows Update drivers only (wu spec 5)** after 1.19, with these items:
    - the DRIVERS run: Windows Update history shows only driver updates, no cumulative update; firmware held on battery; record the total time against a FULL run on a similar PC;
    - optional drivers: record the `Optional driver updates skipped` counts from `setup.log`;
    - an old run state without `WindowsUpdate`, resumed by the new version, runs FULL (`Windows Update round starting` with `scope` `FULL`, the report `Updates      : full`);
    - "Proven by mocks only": the failed optional count.
  - **`CLAUDE.md`:**
    - After the `Choices.Remote` bullet: `Choices.WindowsUpdate` is `FULL` (the default) | `DRIVERS`. Every reader goes through `Get-WindowsUpdateChoice` (missing or invalid means FULL). A profile may set `windowsUpdate`; one that does not leaves the choice alone, and `Test-ProfileChanged` ignores it then. The console fallback has no key for it.
    - Beside the step order: `windows-update` with DRIVERS searches `Type='Driver'` only (the child reads the choice from `state.json` and gets `Invoke-WuRound -Scope`; no new switch). Optional drivers stay skipped and are counted in `setup.log`.
    - "Where things live" lists this spec and plan.

- [ ] **Step 7: Review gate, then commit.**
```bash
git add config/config.json src/Engine/Catalog.ps1 src/Steps/WindowsUpdate.ps1 src/Entry/Main.ps1 src/UI/StartScreen.ps1 src/Toolbox/SetupPlanner.ps1 src/Report/Report.ps1 tests README.md docs/testing.md CLAUDE.md
git commit -m "feat: Windows Update drivers-only choice and search" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The toolbox's UPDATES row

**Files:**
- Modify: `src/Toolbox/Strings.ps1`, `src/Toolbox/Xaml.ps1`, `src/Toolbox/Toolbox.ps1` (`Update-ToolboxView`, the `Invoke-ToolboxAction` doc's action list), `src/Toolbox/SetupPlanner.ps1` (`Update-ToolboxModel`, `Get-ToolboxPlanLines`), `tools/Preview-Toolbox.ps1`, `README.md`, `docs/testing.md`.
- Test: `tests/SetupPlanner.Tests.ps1`, `tests/Toolbox.Tests.ps1`.

**Interfaces:**
- Consumes: `Get-WindowsUpdateChoice`, `$script:WindowsUpdateChoices` and `Get-ProfileChoices` returning `WindowsUpdate` only when set (Task 1).
- Produces:
  - `$script:WindowsUpdateDriversTitle = 'Windows Update (drivers only)'` (SetupPlanner.ps1).
  - The window action `a:WindowsUpdate:FULL` / `a:WindowsUpdate:DRIVERS`.
  - The string keys `row.updates`, `updates.full`, `updates.drivers`, `step.windows-update.drivers`.
  - The named elements `UpdatesFull`, `UpdatesDrivers`.

**The string table** (both tables; the Hebrew is the implementer's and Ben settles it on the screenshots):

| Key | en | he |
|---|---|---|
| `row.updates` | UPDATES | עדכונים |
| `updates.full` | Full updates | עדכונים מלאים |
| `updates.drivers` | Drivers only | דרייברים בלבד |
| `step.windows-update.drivers` | Windows Update (drivers only) | עדכוני Windows (דרייברים בלבד) |

**The XAML:**
- The options grid gets 8 `RowDefinition`s.
- The new row is at `Grid.Row="4"`; APPS moves to 5, TWEAKS to 6 and RESTORE to 7.
- The new row's label is `<TextBlock Grid.Row="4" Style="{StaticResource RowLabelStyle}" Tag="t:row.updates"/>`, and beside it a `WrapPanel` (`Grid.Column="1"`) with two `TileStyle` RadioButtons shaped exactly like the Type tiles:
  - `x:Name="UpdatesFull"`, `Tag="a:WindowsUpdate:FULL"`, glyph `&#xE895;`, text `t:updates.full`;
  - `x:Name="UpdatesDrivers"`, `Tag="a:WindowsUpdate:DRIVERS"`, glyph `&#xE950;`, text `t:updates.drivers`.
- **Plan call:** the glyphs are E895 (Sync, the Settings icon for Windows Update) and E950 (a chip). Both exist in Segoe MDL2 Assets and Segoe Fluent Icons, and they are settled on the screenshots.

- [ ] **Step 1: Write the failing tests.**

  `tests/SetupPlanner.Tests.ps1`:
  - The unchanged-model loop in `'toggles a tweak in catalog order, and ignores unknown values'` gains `@('WindowsUpdate', 'drivers')` and `@('WindowsUpdate', 'NONE')`.
  - Add these tests:
```powershell
  # Describe 'Update-ToolboxModel' ($mo from its BeforeEach)
  It 'sets the Windows Update choice from the tile; a profile without windowsUpdate keeps it, one with it fills it (wu spec 3.1, Review Focus 2)' {
    $d = Update-ToolboxModel -Model $mo -Action 'WindowsUpdate' -Value 'DRIVERS' -Config $cfg
    $d.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS'; $d.Choices.Profile | Should -Be 'home'; $mo.Choices.WindowsUpdate | Should -BeExactly 'FULL'
    foreach ($p in 'home', 'business', 'clean') { (Update-ToolboxModel -Model $d -Action 'Profile' -Value $p -Config $cfg).Choices.WindowsUpdate | Should -BeExactly 'DRIVERS' -Because $p }
    $x = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $x.profiles[2] | Add-Member NoteProperty windowsUpdate 'FULL'
    (Update-ToolboxModel -Model $d -Action 'Profile' -Value 'clean' -Config $x).Choices.WindowsUpdate | Should -BeExactly 'FULL' }
  # Describe 'New-ToolboxModel and Get-ToolboxPlanLines'
  It 'DRIVERS titles the Windows Update line "(drivers only)", or with the window''s title for it (wu spec 3.1)' {
    $mo = New-ToolboxModel -Machine $m -Config $cfg -IsFresh $true -OnAC $true -AdminProtection 'Off'; $mo.Choices.WindowsUpdate = 'DRIVERS'; $dell = @{ Brand = 'DELL'; OsBuild = 26200 }
    $l = @(Get-ToolboxPlanLines -Model $mo -Machine $dell -Config $cfg)
    @($l | Where-Object { $_ -match '^[ \d]\d  Windows Update \(drivers only\)$' }).Count | Should -Be 1; @($l | Where-Object { $_ -match '  Windows Update$' }).Count | Should -Be 0
    @(@(Get-ToolboxPlanLines -Model $mo -Machine $dell -Config $cfg -Titles @{ 'windows-update' = 'WU'; 'windows-update.drivers' = 'WU drivers' }) -match '  WU drivers$').Count | Should -Be 1 }
```
  `tests/Toolbox.Tests.ps1`:
  - The named-element list in `'has every named element ...'` gains `'UpdatesFull','UpdatesDrivers'`.
  - In `'Start returns the validated Choices and closes ...'` the key list becomes `@('Mode', 'Office', 'Profile', 'Remote', 'RestorePoint', 'SevenZip', 'Tweaks', 'WindowsUpdate')`, and it also checks `$w.Tag.Choices.WindowsUpdate | Should -BeExactly 'FULL'`.
  - The Preview test becomes `'renders the six PNGs at 1000x680 without showing a window'`, with `'toolbox-en-drivers.png', 'toolbox-he-drivers.png'` added to its list.
  - Add these tests:
```powershell
  It 'the UPDATES row sits between REMOTE and APPS; Full is checked by default (wu spec 3.1)' {
    $x = $script:ToolboxXaml; $x.IndexOf('t:row.remote') | Should -BeLessThan $x.IndexOf('t:row.updates'); $x.IndexOf('t:row.updates') | Should -BeLessThan $x.IndexOf('t:row.apps')
    $w = New-TestWindow; $w.FindName('UpdatesFull').IsChecked | Should -BeTrue; $w.FindName('UpdatesDrivers').IsChecked | Should -BeFalse }
  It 'Drivers only: the tile, the plan line in both languages, a profile click keeps it, Start hands it over (wu spec 3.1)' {
    $w = New-LiveWindow; ClickTag $w 'a:WindowsUpdate:DRIVERS'
    $w.Tag.Model.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS'; $w.FindName('UpdatesDrivers').IsChecked | Should -BeTrue; $w.FindName('UpdatesFull').IsChecked | Should -BeFalse
    (@($w.FindName('PlanList').Children).Text -join "`n") | Should -Match '(?m)  Windows Update \(drivers only\)$'
    Click $w 'LangHe'; (@($w.FindName('PlanList').Children).Text -join "`n") | Should -Match ('(?m)  ' + [regex]::Escape($script:ToolboxStrings.he['step.windows-update.drivers']) + '$')
    ClickTag $w 'a:Profile:business'; $w.Tag.Model.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS'; $w.FindName('UpdatesDrivers').IsChecked | Should -BeTrue
    Click $w 'StartButton'; $w.Tag.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS' }
```

- [ ] **Step 2: Run them and see them fail.** Run `tools\Invoke-Tests.ps1 -Path tests\Toolbox.Tests.ps1` and `-Path tests\SetupPlanner.Tests.ps1`. Expected: FAIL (no element `UpdatesFull`, no element tagged `a:WindowsUpdate:DRIVERS`, plan line not found).

- [ ] **Step 3: Implement.**
  - **`Update-ToolboxModel`:**
    - add `'WindowsUpdate' { if ($script:WindowsUpdateChoices -ccontains $Value) { $choices['WindowsUpdate'] = $Value } }`;
    - the `'Profile'` branch copies `foreach ($key in @($fill.Keys))`, so a profile without `windowsUpdate` leaves it alone;
    - the doc gets both rules.
  - **`Get-ToolboxPlanLines`:** when the validated Choices' `WindowsUpdate` is `DRIVERS`, the `windows-update` line takes `-Titles['windows-update.drivers']` when that is not empty, else `$script:WindowsUpdateDriversTitle`. The doc says so.
  - **`Update-ToolboxView`:**
    - `$updates = Get-WindowsUpdateChoice -Choices $choices`;
    - `$checks` gains `UpdatesFull = ($updates -eq 'FULL'); UpdatesDrivers = ($updates -eq 'DRIVERS')`;
    - after the `$stepNames` loop, add `$stepNames['windows-update.drivers'] = Get-ToolboxString -Table $state.Strings -Language $language -Key 'step.windows-update.drivers'`;
    - the doc lists the UPDATES tiles.
  - **`Invoke-ToolboxAction`:** its default branch already routes the new action; only the doc's action list changes.
  - **`Strings.ps1`:** the four keys, in both tables (an empty Hebrew value fails `'every t: key exists in both languages'`).
  - **`Xaml.ps1`:** the row, as specified above.
  - **`Preview-Toolbox.ps1`:**
    - every view gains `Updates = ''`, plus two new views, `@{ File = 'toolbox-en-drivers.png'; Language = 'en'; ...; Updates = 'DRIVERS' }` and `@{ File = 'toolbox-he-drivers.png'; Language = 'he'; ...; Updates = 'DRIVERS' }`;
    - `if ($view.Updates -ne '') { $model.Choices.WindowsUpdate = $view.Updates }`;
    - the header comment lists six PNGs.

- [ ] **Step 4: Re-save as UTF-8 with BOM (Hebrew in `Strings.ps1`), then run the full suite.** Expected: the last line reads `Failed: 0`.

- [ ] **Step 5: Look check.**
  - Run `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Preview-Toolbox.ps1`. It writes to `dist\toolbox-preview`, which is git-ignored.
  - Open `toolbox-en.png`, `toolbox-he.png`, `toolbox-en-drivers.png` and `toolbox-he-drivers.png`, and check:
    - UPDATES / עדכונים sits between REMOTE (with its ScreenConnect reminder) and APPS, in the existing tile style;
    - both glyphs draw (no empty box);
    - the Hebrew row mirrors;
    - the plan column reads `Windows Update (drivers only)` and its Hebrew twin.
  - The body already scrolls at 680 high (the tweak rows run past the bottom today), so one more row is expected.
  - Report the four paths. The controller shows Ben the PNGs before merge; this is no hard stop (Ben approved the toolbox look, and the row reuses its tiles).

- [ ] **Step 6: Docs.**
  - **README:** the toolbox's "tiles and switches" bullet gains **Updates** (Full updates / Drivers only, Full in every shipped profile; a profile click keeps the pick). In DRIVERS mode the plan list names the step `Windows Update (drivers only)`. The console fallback has no key for it and runs Full.
  - **`docs/testing.md` 1.20:** the UPDATES row in English and Hebrew (both glyphs drawn, also on Windows 10), and the plan column's step title in both languages.

- [ ] **Step 7: Review gate, then commit.**
```bash
git add src/Toolbox tools/Preview-Toolbox.ps1 tests/SetupPlanner.Tests.ps1 tests/Toolbox.Tests.ps1 README.md docs/testing.md
git commit -m "feat: toolbox UPDATES row (Full updates / Drivers only)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The final screen's U key

**Files:**
- Modify: `src/UI/FinalScreen.ps1` (header comment, `Format-FinalScreen`, `Show-FinalScreen` and their docs), `README.md`, `docs/testing.md`, `CLAUDE.md`, and one cross-reference line each in `docs/specs/2026-10-18-bentech-winsetup-design.md`, `docs/specs/2026-10-20-progress-visibility-design.md` and `docs/specs/2026-10-21-toolbox-design.md`.
- Test: `tests/Screens.Tests.ps1`.

**Interfaces:**
- Consumes: `Get-WindowsUpdateChoice` (Task 1).
- Produces:
  - `$script:WindowsUpdateSettingsUri = 'ms-settings:windowsupdate-action'`;
  - `Format-FinalScreen` gains `[ValidateSet('', 'Started', 'Failed')][string]$WindowsUpdateStatus = ''`.

**The rules:**
- **DRIVERS** is `Get-WindowsUpdateChoice -Choices $State['Choices']`. In FULL nothing changes: the key line is the same, `-WindowsUpdateStatus` is ignored, and U is an ignored key.
- **The key line in DRIVERS** is exactly `'  [R] report   [U] Windows Update   [ENTER] finish'`.
- **The status line:**
  - **Plan call:** "the blank spacer line above the key line" is the existing `$lines.Add('')` before the Chrome hint and the stick line. In production the stick line is always there, so no blank line sits directly above the key line.
  - In DRIVERS that spacer reads `'  Windows Update started: Windows will finish on its own'` for `Started` and `'  Could not open Windows Update: open Settings > Windows Update'` for `Failed`. Both get two leading spaces like every screen line (**Plan call**).
- **`Show-FinalScreen`, key `U` in DRIVERS:**
  - `try { $null = & $Launch $script:WindowsUpdateSettingsUri $null; $wuStatus = 'Started'; Write-SetupLog -Message 'Windows Update handed to Windows' -Data @{ uri = $script:WindowsUpdateSettingsUri } }`;
  - `catch { $wuStatus = 'Failed'; Write-SetupLog -Level WARN -Message 'Could not open Windows Update from the final screen' -Data @{ error = (ConvertTo-ScreenText $_.Exception.Message) } }`;
  - then `. $draw` at once (`$draw` passes `-WindowsUpdateStatus $wuStatus`), then `continue`.
  - Every press opens Settings again, and the line shows the last outcome (**Plan call**).
- **Plan call:** the `-Launch` default passes `-ErrorAction Stop` to both `Start-Process` calls. Then a refused start is always caught: it reaches the could-not line, and for B and R the WARN their code already intends. Checked on this PC on 22/10/2026: a missing file already throws a terminating error, and an unknown URI scheme does not fail at all, so this is belt and braces.

- [ ] **Step 1: Write the failing tests** (`tests/Screens.Tests.ps1`).
  - The helper `Invoke-FinalScreen` gains `[hashtable]$Choices = $null`, put into `$st.Choices` when it is not `$null`.
  - Add these tests:
```powershell
  # Describe 'Format-FinalScreen'
  It 'DRIVERS: the key line offers U without the report path; FULL, no choice and an invalid one keep today''s line (wu spec 3.3, Review Focus 1)' {
    $st = New-FinalState; $st.Choices = @{ WindowsUpdate = 'DRIVERS' }
    $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $l[$l.Count - 1] | Should -BeExactly '  [R] report   [U] Windows Update   [ENTER] finish'; ($l -join "`n") | Should -Not -Match 'Report:'
    foreach ($c in @{ WindowsUpdate = 'FULL' }, @{ WindowsUpdate = 'SOON' }, @{ Mode = 'LAPTOP' }) {
      $s = New-FinalState; $s.Choices = $c; $f = @(Format-FinalScreen -State $s -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
      $f[$f.Count - 1] | Should -BeExactly '  Report: C:\r.txt   [R] open report   [ENTER] finish' } }
  It 'the U outcome takes the blank spacer line: same length, same place; FULL never shows it' {
    $st = New-FinalState; $st.Choices = @{ WindowsUpdate = 'DRIVERS' }
    $f = { param($s) @(Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $false -StickLine '  USB stick found (E:) - logs will be saved there' -WindowsUpdateStatus $s) }
    $none = & $f ''; $ok = & $f 'Started'; $bad = & $f 'Failed'; $at = $none.Count - 4   # the spacer, above the Chrome hint, the stick line and the key line
    $ok.Count | Should -Be $none.Count; $bad.Count | Should -Be $none.Count; $none[$at] | Should -BeExactly ''
    $ok[$at] | Should -BeExactly '  Windows Update started: Windows will finish on its own'
    $bad[$at] | Should -BeExactly '  Could not open Windows Update: open Settings > Windows Update'
    (@(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true -WindowsUpdateStatus 'Started') -join "`n") | Should -Not -Match 'Windows Update started' }
  It 'DRIVERS worst case: still 29 lines, the key and status lines within 79 columns (Review Focus 5)' {
    $st = New-FinalState; $st.AnyDeskId = '1234567890'; $st.Choices = @{ Remote = 'BOTH'; WindowsUpdate = 'DRIVERS' }; $st.Steps = @{ screenconnect = @{ Status = 'Done' } }
    $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict -Color 'RED' -Banner 'COMPLETED WITH ERRORS' -Failures @(1..20 | % { "Failure $_" }) -Notes @(1..20 | % { "Note $_" })) `
      -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' -DefaultBrowserIsChrome $false -StickLine '  No BenTech USB stick - plug it in now to keep the logs' -WindowsUpdateStatus 'Failed')
    $l.Count | Should -BeLessOrEqual 29
    foreach ($t in @($l | Where-Object { $_ -like '*Windows Update*' })) { $t.Length | Should -BeLessOrEqual 79 }
    @($l | Where-Object { $_ -like '*Windows Update*' }).Count | Should -Be 2 }
  # Describe 'Show-FinalScreen'
  It 'U in DRIVERS mode opens Settings on Windows Update, logs it and redraws at once; the screen keeps waiting (wu spec 3.3)' {
    Invoke-FinalScreen -Keys 'U', 'Enter' -Choices @{ WindowsUpdate = 'DRIVERS' }
    $launched.Count | Should -Be 1; $launched[0].Target | Should -BeExactly 'ms-settings:windowsupdate-action'; [string]$launched[0].Arguments | Should -BeExactly ''
    $drawn.Count | Should -Be 2; $drawn[0] | Should -Not -Match 'Windows Update started'; $drawn[1] | Should -Match 'Windows Update started: Windows will finish on its own'
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Windows Update handed to Windows' } }
  It 'a U that cannot open Settings shows the could-not line and logs a WARN; Enter still finishes (Review Focus 5)' {
    Invoke-FinalScreen -Keys 'U', 'Enter' -Choices @{ WindowsUpdate = 'DRIVERS' } -Launch { param($t, $a) throw 'no settings app' }
    $drawn[$drawn.Count - 1] | Should -Match 'Could not open Windows Update: open Settings > Windows Update'
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq 'Could not open Windows Update from the final screen' -and $Data.error -eq 'no settings app' } }
  It 'U does nothing in FULL mode or without the choice' -ForEach @(@{ C = @{ WindowsUpdate = 'FULL' } }, @{ C = $null }) {
    Invoke-FinalScreen -Keys 'U', 'Enter' -Choices $C; $launched.Count | Should -Be 0; $drawn.Count | Should -Be 1 }
  It 'the production launcher stops on a failed start, so a refused U reaches the could-not line' {
    $p = (Get-Command Show-FinalScreen).ScriptBlock.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Launch' }
    ([regex]::Matches($p.DefaultValue.Extent.Text, '-ErrorAction Stop')).Count | Should -Be 2 }
```

- [ ] **Step 2: Run them and see them fail.** Run `tools\Invoke-Tests.ps1 -Path tests\Screens.Tests.ps1`. Expected: FAIL (`-WindowsUpdateStatus` is not a parameter; no launch on U).

- [ ] **Step 3: Implement** the rules above.
  - The header comment of `FinalScreen.ps1` names `Get-WindowsUpdateChoice` among its Catalog.ps1 needs.
  - The doc of `Format-FinalScreen` covers the key line and the status line, and says the line count is unchanged.
  - The doc of `Show-FinalScreen` adds U (DRIVERS only) to its keys.

- [ ] **Step 4: Run the full suite.** Expected: the last line reads `Failed: 0`.

- [ ] **Step 5: Docs.**
  - **README, step 5's key table:** add `| U | Only after a Drivers only run: opens Settings > Windows Update and starts its check; Windows downloads, installs and restarts on its own, also after Enter and after the console is closed |`.
  - **README, under the table:** in Drivers only mode the last line reads `[R] report   [U] Windows Update   [ENTER] finish` (the report path is in the report folder on the stick), and the line above the stick line shows the U outcome.
  - **`docs/testing.md` 1.20:** the U key (Settings opens on Windows Update and starts checking; after Enter and closing the console Windows keeps downloading and installing), and record the could-not line if it ever shows.
  - **`CLAUDE.md`:** one line: the final screen's **U** (DRIVERS only) opens `ms-settings:windowsupdate-action` through `-Launch`; its outcome replaces the blank spacer, so the screen stays at 29 lines.
  - **The specs:** each of the v1, v2 and toolbox specs gets one line under its header: `Amended by [2026-10-22-windows-update-option-design.md](2026-10-22-windows-update-option-design.md): Windows Update "drivers only" and the final screen's U key.` (**Plan call**, as the toolbox's Task 5 did).

- [ ] **Step 6: Review gate, then commit.**
```bash
git add src/UI/FinalScreen.ps1 tests/Screens.Tests.ps1 README.md docs/testing.md CLAUDE.md docs/specs
git commit -m "feat: final screen U key hands Windows Update to Windows" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Spec coverage (self-review)

| Spec | Task |
|---|---|
| 3.1 Choices key, `defaults.windowsUpdate`, profiles may set it, the three do not | 1 (config, `Get-WindowsUpdateChoice`, profiles) |
| 3.1 a profile without it leaves the tile alone; `Test-ProfileChanged` | 1 (`Test-ProfileChanged`), 2 (Profile click) |
| 3.1 missing or invalid means FULL | 1 (reader, Entry, report), 3 (final screen) |
| 3.1 UPDATES row, two tiles, en and he, plan line | 2 |
| 3.1 console fallback unchanged, runs the default profile's value | 1 (`New-DefaultChoices`, U is no console key) |
| 3.2 DRIVERS searches `Driver` only; every rule still applies | 1 (round tests, firmware test) |
| 3.2 optional stay skipped, the count is logged | 1 |
| 3.2 the message says `Drivers only`; the activity line | 1 |
| 3.3 U, the URI, the feedback, the log, the 29 lines, the 79 columns, the key line | 3 |
| 3.3 the verdict is unchanged; the report's Updates line | 1 (no note; report) |
| 5 real-machine items | 1, 2, 3 (`docs/testing.md` 1.20) |
| 6 not in scope | nothing added |
