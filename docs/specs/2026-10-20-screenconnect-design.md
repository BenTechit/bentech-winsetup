# bentech-winsetup: ScreenConnect as a remote-access choice

**Status:** Agreed in chat on 20/10/2026 (Q14, Q15, Q16). Ben reviews this text together with the plan.
**Amends:** the v1 spec, [2026-10-20-progress-visibility-design.md](2026-10-20-progress-visibility-design.md) and [2026-10-20-craft-apps-design.md](2026-10-20-craft-apps-design.md). They stay binding wherever this document does not change them.

## 1. Why

Ben has a ScreenConnect (ConnectWise) cloud account. His installer `ScreenConnect.ClientSetup.exe`, built from his ScreenConnect page, installs the unattended client and enrolls the PC in his account. Running it is enough: the PC appears in his ScreenConnect list.

He wants ScreenConnect next to AnyDesk, with a choice of AnyDesk, ScreenConnect or both.

## 2. Decisions (Ben, 20/10/2026)

| # | Question | Answer |
|---|---|---|
| Q14 | Where the installer lives | **In each GitHub release**, next to `setup.ps1` and `config.json`. The release is public, so Ben accepts that anyone can download it (see 7). |
| Q15 | What the start screen picks by itself | **AnyDesk only**, as today. **R** adds ScreenConnect or switches to it. |
| Q16 | Unattended access | **Unattended on purpose.** ScreenConnect connects without the customer clicking Accept. Ben gets the customer's OK at the counter, for example on the repair form. The start screen shows a reminder whenever ScreenConnect is chosen (4.1). Section 4.6 lists the v1 rules this changes. |

## 3. The installer (read on 20/10/2026, never run)

| Property | Value |
|---|---|
| File | `ScreenConnect.ClientSetup.exe` |
| Version | ScreenConnect 26.6.6.9747 |
| Size | 24,395,832 bytes |
| SHA-256 | `74E058E0F597CF197132775552FBB6F4BDD21F8A0870E1A638D41A63F7C3FD99` |
| Authenticode | `Valid` |
| Signer subject | `CN="ConnectWise, LLC", O="ConnectWise, LLC", L=Tampa, S=Florida, C=US` (Windows quotes the name because it holds a comma) |
| Issuer | DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1 |
| Certificate | valid 20/02/2026 to 19/02/2027, **no timestamp** |
| Built for | `instance-iao68e-relay.screenconnect.com`, port 443, session type Access. These settings sit inside the signed part of the file. |
| Installs as | product and service `ScreenConnect Client (b58e7c32699a96bf)`. The suffix is fixed for Ben's instance. |
| Silent switch | None documented. Ben runs it by double-click and it asks for nothing. |

**What follows from these facts:**

- **The signature cannot prove the file is Ben's.** Every ScreenConnect installer has a valid ConnectWise signature, including one a scammer builds for their own instance. The SHA-256 pin in the signed `config.json` is what proves it is Ben's file.
- **The installer has an end date.** It has no timestamp, so from 20/02/2027 Windows stops reporting the signature as `Valid`. Ben must build a new installer before then. Until he does, the tool refuses the old one with a red line. Clients already installed are not affected, because they update themselves from Ben's server.

## 4. Behaviour

### 4.1 Start screen

- New choice `Choices.Remote`, with the values `ANYDESK` (the default, from `config.json` `defaults.remote`), `SCREENCONNECT` and `BOTH`.
- **R** cycles ANYDESK, then SCREENCONNECT, then BOTH, then back to ANYDESK. Like every other toggle, it restarts the countdown.
- The line `Chrome + AnyDesk   always` becomes two lines:
  ```
     Chrome   always
     Remote   ANYDESK                                 R = anydesk / sc / both
  ```
  The value reads `ANYDESK`, `SCREENCONNECT` or `ANYDESK + SCREENCONNECT`.
- The whole value is highlighted. Today's highlight colours only the first word (`\S+`, StartScreen.ps1:257), which would leave `+ SCREENCONNECT` plain.
- **Reminder (Q16).** When the value includes SCREENCONNECT, one more line follows the Remote line:
  ```
     ScreenConnect = unattended access: get the customer's OK first
  ```
  - It is drawn Yellow on Black, never DarkYellow.
  - It disappears when R goes back to ANYDESK.
  - It is a reminder only: nothing waits for it, and the countdown runs as usual.
- There is no "none" choice. Ben asked for these three.
- **Missing or invalid values mean ANYDESK.** This covers:
  - a run state without `Remote` (a run started by an older version), which is what that version did;
  - an invalid `defaults.remote`.

  Every reader applies this rule: the plan, the final screen and the report all decide from `Choices.Remote` this way, never from the plan list. Final-screen tests that build a State without Choices therefore still show the AnyDesk ID.

### 4.2 Plan

- `anydesk` runs with ANYDESK or BOTH.
- New step **`screenconnect`** (Title `ScreenConnect`, Short `ScreenConnect`) runs right after `anydesk`, with SCREENCONNECT or BOTH.

### 4.3 The step

**`config.json` additions:**
```json
"defaults": { "remote": "ANYDESK" },
"signers": { "connectwise": ["\"ConnectWise, LLC\""] },
"apps": { "screenconnect": {
  "signer": "connectwise",
  "url": "https://github.com/BenTechit/bentech-winsetup/releases/download/v{version}/ScreenConnect.ClientSetup.exe",
  "sha256": "74E058E0F597CF197132775552FBB6F4BDD21F8A0870E1A638D41A63F7C3FD99",
  "serviceName": "ScreenConnect Client (b58e7c32699a96bf)" } },
"timeoutsMinutes": { "screenconnect": 10, "screenconnectService": 3 }
```

**Why the signer entry has quotes:** `Test-FileSignature` matches `CN=<signer>` as text, and the real subject reads `CN="ConnectWise, LLC"`. Without the quotes in the entry, the real file would be refused. A test pins the real subject string. `-ExactCN` is not used: it refuses quoted subjects by design, and the hash already pins the exact file.

**The steps:**

1. **Already installed?** If the service `serviceName` exists, skip the install and go to step 5. A ScreenConnect client from another company has a different service name, so it does not count.
2. **Download** `url` to `<Downloads>\ScreenConnect.ClientSetup.exe`, with `{version}` replaced by this bundle's version (`$script:SetupVersion`).
   - The link names this run's own release, never `latest`. A run therefore never mixes a newer installer with its own config, and a rollback brings back its own installer.
   - If the version is unknown (`dev`), the step is Failed: `ScreenConnect: release version unknown`.
3. **Check.** Both checks must pass:
   - the SHA-256 equals `sha256`, compared case-insensitively;
   - `Test-FileSignature` with `signers.connectwise` returns `$true`.

   If either fails, the file is deleted (V2-R13) and the step is Failed: `ScreenConnect installer check failed`.
   - The log says which check failed.
   - For a signature failure, the log line also gives the PC's date and the certificate's end date. A wrong PC clock and an expired installer then look different.
   - Expiry is caught early at publish time (4.5). The step adds no start-screen warning for it.
4. **Install.** Run the file with no arguments through `Invoke-External`, with its own `timeoutsMinutes.screenconnect` (10).
   - The EXE has no documented silent switch. If it ever shows a window that waits, the run loses 10 minutes, not `default`'s 30.
   - The exit code and any timeout are logged but decide nothing.
   - The MSI fallback (section 6) is a later amendment, written only if the real laptop shows a waiting window. The config holds no MSI fields until then.
5. **Wait for the service.** Poll every 5 s, through `Wait-SetupDelay`, for up to `timeoutsMinutes.screenconnectService` minutes, until the service is Running:
   - **Running:** Done, `ScreenConnect installed` (or `ScreenConnect already installed`).
   - **Exists but not Running:** Done with the yellow Note `ScreenConnect service not running yet`. It starts automatically after the next restart.
   - **Missing:** Failed (red), `ScreenConnect install failed (service not found)`. If the installer timed out, the message is `ScreenConnect install timed out`.

   The service is read with `Get-Service -Name <exact name>`, because service names are not localized.

### 4.4 Visibility

- **NOW** shows `ScreenConnect: downloading`, then `checking`, `installing` and `waiting for the service`.
- **Activity line:** `ScreenConnect installed - this PC will appear in your ScreenConnect list`.
- **Final screen:**
  - The AnyDesk ID block shows only when AnyDesk was chosen: `Choices.Remote` is ANYDESK or BOTH, read under 4.1's rule. With SCREENCONNECT alone there is no AnyDesk line at all.
  - When `screenconnect` was in the plan, the `New name` line gains its status, for example `  New name : BT-12345     ScreenConnect: installed` (or `NOT installed`). The name Ben looks for in his list sits right beside the status.
  - The status goes on an existing line because the screen is already at its 29-line limit with every list full.
  - **Why the new name is the right one to show** (my call):
    - The step runs before the rename takes effect.
    - Finalize restarts whenever a computer rename is pending (`Test-FinalRebootNeeded`), so the final screen always comes after the PC has started with its new name.
    - ScreenConnect's session name follows the machine name after a restart. This is unproven, so it is listed in section 6.
    - The report already keeps the old name.
- A failed step reads `ScreenConnect: ScreenConnect installer check failed` on the final screen, because the verdict prefixes the step title. This is the same double wording AnyDesk's messages already have. It is kept for consistency.
- **Report:**
  - A line `ScreenConnect: installed (service running)`, `installed (service not running)`, `not installed` or `not chosen`.
  - `AnyDesk ID` reads `not chosen` when AnyDesk was not chosen.
  - `Get-InstalledAppVersions` learns `ScreenConnect` = DisplayName `ScreenConnect Client (b58e7c32699a96bf)`.

### 4.5 Publishing

- **Where the installer lives on Ben's PC:** `%USERPROFILE%\.bentech-winsetup\ScreenConnect.ClientSetup.exe`, beside the signing key. It is not in the repo and not in a synced folder.
- **What `Publish.ps1` checks before building:**
  - the file exists;
  - its SHA-256 equals `apps.screenconnect.sha256`;
  - its Authenticode status is `Valid`, signed by ConnectWise.

  Any failure stops the publish. Under `-DryRun` it is only a warning. Publish prints the certificate's end date and warns when it is less than 60 days away.
- **What it uploads:** a copy of the file in `dist`, uploaded as a **fifth** release file, `ScreenConnect.ClientSetup.exe`. There is no `.sig`: the signed `config.json` pins its SHA-256.
  - Every place that assumes four files changes with it: Publish.ps1's header, its file list, its checks and its summary, plus CLAUDE.md's "exactly four" and the README.
  - The four signed files stay exactly as they are.
- **The launcher is unchanged.** It still downloads only `setup.ps1` and `config.json`, so the USB sticks stay valid.
- **A new installer** (a new version, or before 19/02/2027):
  1. Ben saves the new file to the path above.
  2. The SHA-256 in `config.json` is updated (and the `serviceName` if the suffix changed).
  3. A new release is published.

  The README describes this procedure.

### 4.6 v1 rules this changes (Q16)

| v1 rule | From now on |
|---|---|
| **Anti-goal:** "It leaves junk behind: ... an unattended-access remote tool" | Still a failure for everything **except** ScreenConnect when Ben chose it. ScreenConnect is the one unattended tool, and only on purpose. |
| **Q8:** AnyDesk is a full install, and "the customer must accept every connection" | **Unchanged for AnyDesk.** ScreenConnect is the unattended choice. |
| **Section 5:** "the tool collects nothing off-machine" (Amendment 13) | **Still true for the tool itself.** The one exception is that the ScreenConnect client, when chosen, enrols the PC in Ben's ScreenConnect cloud (name, IP, user name). Ben covers this with the customer's consent at the counter. |

The v1 spec stays as written: this section overrides it. The plain-language docs are updated to match:
- README.md, where it says "no unattended password, the customer accepts every connection";
- `docs/testing.md`;
- CLAUDE.md.

### 4.7 Unchanged

- The AnyDesk step itself, its ID and the launcher.
- The colour, tick, ASCII and no-prompt rules.
- The Office and Craft paths.

## 5. Not in scope

- Removing AnyDesk or ScreenConnect from a PC that already has them.
- Setting the session name or custom properties in ScreenConnect. The installer's settings are signed, and the tool never touches them.
- A "no remote tool" choice.

## 6. To prove on a real machine (`docs/testing.md`)

- **Silent install.** Run as the elevated setup account, the EXE installs with no window waiting for a click. If a window does wait, the fix is the MSI from the same Build page, installed with `msiexec /i /qn`.
- **Service and list.** The service `ScreenConnect Client (b58e7c32699a96bf)` appears and runs, and the PC appears in Ben's list.
- **The name in the list.** The new PC name applies only after a restart, so the old name (`DESKTOP-...`) may show first. ConnectWise's forum says the session name follows the machine name, so it should switch to the new name after the restart.
- **Exit code.** The EXE's exit code, from the log.
- **Second run.** A second run skips the install as already installed.
- **BOTH.** The AnyDesk ID still shows and the final screen fits on one screen.

## 7. Risks Ben accepted (Q14)

- **Anyone can download the installer** from the public release. Running it puts *their* PC in Ben's list: it gives Ben access to it, not them access to anything of his.
- **It reveals Ben's instance address.** Every customer he connects to sees it anyway.
- **A security scanner may flag the release.** Scanners sometimes flag remote-access installers in public GitHub releases.
- **Strangers can add junk machines to Ben's list.** If his plan limits the number of unattended agents, they would use up slots. Ben can delete them in ScreenConnect.

## 8. Calls made without Ben (check while reading)

1. **The download names this run's release, not `latest`** (4.3).
2. **The hash is pinned in `config.json`, with no `.sig` for the EXE** (4.5).
3. **Both the hash and the signature must pass.** The signer entry keeps the quotes Windows puts around `ConnectWise, LLC` (4.3).
4. **The service decides, not the exit code.** A service that exists but is not running gives a yellow Note (4.3).
5. **The installer gets its own 10-minute timeout.** The MSI fallback waits for the real-laptop test (4.3).
6. **The status sits on the final screen's `New name` line.** With ScreenConnect only, there is no AnyDesk line (4.4).
7. **Missing or invalid `Remote` means ANYDESK, everywhere** (4.1).
8. **The installer lives in `%USERPROFILE%\.bentech-winsetup\`.** Publish warns 60 days before the certificate ends (4.5).
9. **R's help reads `R = anydesk / sc / both`,** to fit 80 columns (4.1).
