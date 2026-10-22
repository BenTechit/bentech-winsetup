# tests/Screens.Tests.ps1
# Task 15: start, progress and final screens.
#
# SAFETY: these are console screens. Nothing here may touch the real console, read a real key, change
# the console colour or start a process. Every Show-* call passes all of its seams (-ReadKey, -Now,
# -Sleep, -OnAC, -Stick, -Write, -Writer, -SetColor, -Launch, -FlushInput), and BeforeEach also replaces
# Clear-Host, Write-Host and Start-Process with commands that throw, so a forgotten seam fails loudly.
BeforeAll {
  foreach ($f in 'ConsoleFrame','StartScreen','ProgressScreen','FinalScreen') { . "$PSScriptRoot\..\src\UI\$f.ps1" }
  . "$PSScriptRoot\..\src\Entry\Cleanup.ps1"   # Format-StickLine and Find-SetupStick, for the final screen's stick line
  # The real commands the screens call in production, so Pester can mock them.
  . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Activity.ps1"; . "$PSScriptRoot\..\src\Common\Config.ps1"
  . "$PSScriptRoot\..\src\Engine\Catalog.ps1"; . "$PSScriptRoot\..\src\Engine\Verdict.ps1"
  . "$PSScriptRoot\..\src\Toolbox\SetupPlanner.ps1"   # New-DefaultChoices reads the default profile
  . "$PSScriptRoot\..\src\Detect\Detection.ps1"
  . "$PSScriptRoot\..\src\Steps\Apps.ps1"; . "$PSScriptRoot\..\src\Steps\DefaultBrowser.ps1"
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:m = @{ Manufacturer='Dell Inc.'; FriendlyModel='Latitude 5440'; Serial='7HX2K93'; IsLaptop=$true; IsVM=$false; OsCaption='Windows 11 Pro'; OsDisplayVersion='25H2'; OsBuild=26200; Arch='x64'; NewName='DELL-7HX2K93' }
  $script:Hebrew = -join [char[]](0x05E2, 0x05D3, 0x05DB, 0x05D5, 0x05DF)

  # The v2 progress screen fixture (Task 7): a local catalog with Short titles, a run with every marker,
  # Office in the background, and a NOW view with a 60-minute wait.
  $script:cat = @(
    @{ Id = 'prepare';        Title = 'Prepare machine';                Short = 'Prepare';          Function = 'Invoke-StepPrepare' }
    @{ Id = 'bitlocker';      Title = 'Turn off BitLocker';             Short = 'BitLocker off';    Function = 'Invoke-StepBitLocker' }
    @{ Id = 'chrome';         Title = 'Google Chrome';                  Short = 'Chrome';           Function = 'Invoke-StepChrome' }
    @{ Id = 'anydesk';        Title = 'AnyDesk';                        Short = 'AnyDesk';          Function = 'Invoke-StepAnyDesk' }
    @{ Id = '7zip';           Title = '7-Zip';                          Short = '7-Zip';            Function = 'Invoke-StepSevenZip' }
    @{ Id = 'vendor-pass1';   Title = 'Vendor drivers + BIOS (pass 1)'; Short = 'Drivers (pass 1)'; Function = 'Invoke-StepVendorPass1' }
    @{ Id = 'office';         Title = 'Microsoft 365';                  Short = 'Microsoft 365';    Function = 'Invoke-StepOffice' }
    @{ Id = 'windows-update'; Title = 'Windows Update';                 Short = 'Windows Update';   Function = 'Invoke-StepWindowsUpdate' }
    @{ Id = 'office-finish';  Title = 'Microsoft 365 (finish)';         Short = 'Microsoft 365';    Function = 'Invoke-StepOfficeFinish' }
    @{ Id = 'finalize';       Title = 'Finalize';                       Short = 'Finish';           Function = 'Invoke-StepFinalize' }
  )
  function New-V2State {
    @{
      StartedAt = '2026-10-20T11:00:00'; RebootCount = 2
      Plan = @('prepare', 'bitlocker', 'chrome', 'anydesk', '7zip', 'vendor-pass1', 'office', 'windows-update', 'office-finish', 'finalize')
      Steps = @{
        'prepare'        = @{ Status = 'Done' }
        'bitlocker'      = @{ Status = 'Skipped'; Message = 'Not encrypted' }
        'chrome'         = @{ Status = 'Failed'; Message = 'MSI exit 1603' }
        'anydesk'        = @{ Status = 'Done' }
        '7zip'           = @{ Status = 'Done' }
        'vendor-pass1'   = @{ Status = 'running'; StartedAt = '2026-10-20T12:00:00' }
        'office'         = @{ Status = 'Done'; Data = @{ Background = $true; StartedAt = '2026-10-20T11:59:00' } }
        'windows-update' = @{ Status = 'pending' }
        'office-finish'  = @{ Status = 'pending' }
        'finalize'       = @{ Status = 'pending' }
      }
    }
  }
  $script:now = [datetime]'2026-10-20T12:12:40'
  $script:view = @{ SubTitle = 'Dell Command Update'; Lines = @('Log: Installing Intel Chipset'); Wait = @{ StartedAt = [datetime]'2026-10-20T12:00:00'; LimitMinutes = 60 } }
  $script:act = @([pscustomobject]@{ Time = [datetime]'2026-10-20T12:31:00'; Text = 'Microsoft 365 started installing in the background' })

  # A fake clock: Sleep moves it forward, Now reads it. Show-StartScreen never waits for real time.
  function Reset-FakeClock { $script:clock = [datetime]'2026-10-18T09:00:00'; $script:t0 = $script:clock }
  function Get-ElapsedSeconds { ($script:clock - $script:t0).TotalSeconds }

  # Runs Show-StartScreen against the fake clock. -KeyAt is a scriptblock that gets the elapsed
  # seconds and returns a key name (or nothing). Records every drawn screen in $script:screens.
  function Invoke-StartScreen {
    param([hashtable]$Machine = $script:m, [bool]$IsFresh = $true, [scriptblock]$KeyAt = { param($s) }, [scriptblock]$OnAC = { $true }, $Previous = $null, [scriptblock]$FlushInput = { })
    Reset-FakeClock
    $script:screens = New-Object System.Collections.ArrayList
    $script:startEvents = New-Object System.Collections.ArrayList
    $script:flushBody = $FlushInput
    $script:keyAt = $KeyAt
    $script:readCalls = 0
    Show-StartScreen -Machine $Machine -Config $script:cfg -Version '2026.10.18.1' -Previous $Previous -IsFresh $IsFresh `
      -ReadKey { $script:readCalls++; if ($script:readCalls -gt 5000) { throw 'runaway loop: the fake clock stopped advancing' }; & $script:keyAt (Get-ElapsedSeconds) } `
      -Now { $script:clock } `
      -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds($ms) } `
      -OnAC $OnAC `
      -FlushInput { $null = $script:startEvents.Add('flush'); & $script:flushBody } `
      -Write { param($lines) $null = $script:startEvents.Add('write'); $null = $script:screens.Add(($lines -join "`n")) }
  }

  # Runs Show-FinalScreen against the fake clock with a scripted key sequence: one key per poll, then
  # empty polls; 2000 empty polls (200 s of fake time) mean no Enter ever came. -KeyAt (elapsed seconds
  # -> key name or nothing) replaces -Keys when given. -Stick is the stick reader (default: the stick in
  # $script:stick). -Choices, when given, becomes the state's Choices. Records colours, drawn screens,
  # launches and the order of flush/read events.
  function Invoke-FinalScreen {
    param([string[]]$Keys = @('Enter'), [scriptblock]$KeyAt = $null, [string]$Color = 'YELLOW', [string[]]$Failures = @(), [string[]]$Notes = @('x'),
          [scriptblock]$Launch = $null, [scriptblock]$Stick = { $script:stick }, [hashtable]$Choices = $null)
    Reset-FakeClock
    $script:keyQueue = New-Object System.Collections.Queue
    foreach ($k in $Keys) { $script:keyQueue.Enqueue($k) }
    $script:finalKeyAt = $KeyAt
    $script:emptyPolls = 0
    $script:colors = New-Object System.Collections.ArrayList
    $script:fores = New-Object System.Collections.ArrayList
    $script:drawn = New-Object System.Collections.ArrayList
    $script:launched = New-Object System.Collections.ArrayList
    $script:events = New-Object System.Collections.ArrayList
    $script:launchBody = $Launch
    $st = @{ Machine = $script:m; AnyDeskId = '123456789'; RebootCount = 2; StartedAt = '2026-10-18T09:00:00'; EndedAt = '2026-10-18T10:12:00' }
    if ($null -ne $Choices) { $st.Choices = $Choices }
    $verdict = @{ Color = $Color; Banner = 'COMPLETE - CHECK NOTES'; Failures = $Failures; Notes = $Notes }
    Show-FinalScreen -State $st -Verdict $verdict -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' `
      -ReadKey {
        $null = $script:events.Add('read')
        $k = if ($script:finalKeyAt) { & $script:finalKeyAt (Get-ElapsedSeconds) } elseif ($script:keyQueue.Count -gt 0) { $script:keyQueue.Dequeue() }
        if ($k) { return $k }
        $script:emptyPolls++
        if ($script:emptyPolls -gt 2000) { throw 'runaway: no Enter' }
      } `
      -Stick $Stick -Now { $script:clock } -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds($ms) } `
      -SetColor { param($b, $f) $null = $script:events.Add('color'); $null = $script:colors.Add($b); $null = $script:fores.Add($f) } `
      -Write { param($lines) $null = $script:events.Add('write'); $null = $script:drawn.Add(($lines -join "`n")) } `
      -ResetColor { $null = $script:events.Add('reset') } `
      -FlushInput { $null = $script:events.Add('flush') } `
      -Launch { param($target, $arguments) $null = $script:launched.Add(@{ Target = $target; Arguments = $arguments }); if ($script:launchBody) { & $script:launchBody $target $arguments } }
  }
}

Describe 'ConvertTo-ScreenText' {
  It 'strips direction and format marks before the ASCII filter (spec 9.5)' {
    $marks = 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069
    ConvertTo-ScreenText ((-join ($marks | ForEach-Object { [char]$_ })) + 'Microsoft Windows 11 Home') | Should -BeExactly 'Microsoft Windows 11 Home'
    ConvertTo-ScreenText ('Home ' + [char]0x05D1) | Should -BeExactly 'Home ?'
  }
  It 'still turns line breaks and tabs into a space and other non-ASCII into ?' {
    ConvertTo-ScreenText "a`r`nb`tc" | Should -BeExactly 'a b c'
    ConvertTo-ScreenText ([string][char]0x00E9) | Should -BeExactly '?'
    ConvertTo-ScreenText $null | Should -BeExactly ''
  }
}

Describe 'Update-StartChoices' {
  BeforeEach { $script:c = @{ Mode='LAPTOP'; SevenZip=$true; Office='OFF' } }
  It 'O cycles CRAFT -> BUSINESS -> HOME -> OFF -> CRAFT' {
    $r = Update-StartChoices -Choices @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT' } -Key 'O'
    $seen = @($r.Choices.Office); foreach ($i in 1..3) { $r = Update-StartChoices -Choices $r.Choices -Key 'o'; $seen += $r.Choices.Office }
    $seen | Should -Be @('BUSINESS', 'HOME', 'OFF', 'CRAFT'); $r.ResetCountdown | Should -BeTrue }
  It 'R cycles ANYDESK -> SCREENCONNECT -> BOTH -> ANYDESK and resets the countdown' {
    $r = Update-StartChoices -Choices @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT'; Remote = 'ANYDESK' } -Key 'R'
    $seen = @($r.Choices.Remote); foreach ($i in 1..2) { $r = Update-StartChoices -Choices $r.Choices -Key 'r'; $seen += $r.Choices.Remote }
    $seen | Should -Be @('SCREENCONNECT', 'BOTH', 'ANYDESK'); $r.ResetCountdown | Should -BeTrue }
  It 'R from choices without Remote, or an invalid one, goes to SCREENCONNECT' {
    (Update-StartChoices -Choices $c -Key 'R').Choices.Remote | Should -Be 'SCREENCONNECT'
    (Update-StartChoices -Choices @{ Remote = 'TEAMVIEWER' } -Key 'R').Choices.Remote | Should -Be 'SCREENCONNECT' }
  It 'Z toggles and resets the countdown' { $r = Update-StartChoices -Choices $c -Key 'Z'; $r.Choices.SevenZip | Should -BeFalse; $r.ResetCountdown | Should -BeTrue }
  It 'D switches to desktop' { (Update-StartChoices -Choices $c -Key 'D').Choices.Mode | Should -Be 'DESKTOP' }
  It 'Enter starts, Esc cancels, and any other key resets the countdown (Q1)' {
    (Update-StartChoices -Choices $c -Key 'Enter').Action | Should -Be 'Start'; (Update-StartChoices -Choices $c -Key 'Escape').Action | Should -Be 'Cancel'
    $r = Update-StartChoices -Choices $c -Key 'X'; $r.Action | Should -Be 'None'; $r.ResetCountdown | Should -BeTrue; $r.Choices.Mode | Should -Be 'LAPTOP'
    foreach ($k in 'Spacebar', 'F5', 'D7', 'Tab') { (Update-StartChoices -Choices $c -Key $k).ResetCountdown | Should -BeTrue -Because $k }
  }
  It 'L switches to laptop, case-insensitively, and resets the countdown' {
    $desktop = @{ Mode='DESKTOP'; SevenZip=$true; Office='OFF' }
    $r = Update-StartChoices -Choices $desktop -Key 'l'
    $r.Choices.Mode | Should -Be 'LAPTOP'; $r.ResetCountdown | Should -BeTrue; $r.Action | Should -Be 'None'
  }
  It 'every toggle key resets the countdown, Enter and Escape do not' {
    foreach ($k in 'L','D','Z','O','R') { (Update-StartChoices -Choices $c -Key $k).ResetCountdown | Should -BeTrue }
    foreach ($k in 'Enter','Escape') { (Update-StartChoices -Choices $c -Key $k).ResetCountdown | Should -BeFalse }
  }
  It 'returns a new table and leaves the input alone' {
    $r = Update-StartChoices -Choices $c -Key 'Z'
    $c.SevenZip | Should -BeTrue
    $r.Choices.SevenZip | Should -BeFalse
  }
  It 'treats an empty or null key as no key' {
    (Update-StartChoices -Choices $c -Key '').Action | Should -Be 'None'
    (Update-StartChoices -Choices $c -Key $null).Action | Should -Be 'None'
    (Update-StartChoices -Choices $c -Key '').ResetCountdown | Should -BeFalse
    (Update-StartChoices -Choices $c -Key $null).ResetCountdown | Should -BeFalse
  }
}

Describe 'New-DefaultChoices' {
  It 'picks LAPTOP for a laptop and takes 7-Zip and Office from the config defaults' {
    $r = New-DefaultChoices -Machine $m -Config $cfg
    $r.Mode | Should -Be 'LAPTOP'; $r.SevenZip | Should -BeTrue; $r.Office | Should -Be 'CRAFT'
  }
  It 'opens on CRAFT, and a lower-case craft default is CRAFT' {
    (New-DefaultChoices -Machine $m -Config $cfg).Office | Should -Be 'CRAFT'
    (New-DefaultChoices -Machine $m -Config ([pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $true; office = 'craft' } })).Office | Should -Be 'CRAFT' }
  It 'picks DESKTOP for a desktop' {
    (New-DefaultChoices -Machine @{ IsLaptop = $false; IsVM = $false } -Config $cfg).Mode | Should -Be 'DESKTOP'
  }
  It 'picks DESKTOP for a laptop-looking virtual machine' {
    (New-DefaultChoices -Machine @{ IsLaptop = $true; IsVM = $true } -Config $cfg).Mode | Should -Be 'DESKTOP'
  }
  It 'opens on ANYDESK; a lower-case default counts, an invalid or missing one is ANYDESK' {
    (New-DefaultChoices -Machine $m -Config $cfg).Remote | Should -BeExactly 'ANYDESK'
    foreach ($case in @(@{ V = 'both'; E = 'BOTH' }, @{ V = 'screenconnect'; E = 'SCREENCONNECT' }, @{ V = 'TEAMVIEWER'; E = 'ANYDESK' }, @{ V = $null; E = 'ANYDESK' })) {
      $x = [pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $true; office = 'CRAFT'; remote = $case.V } }
      (New-DefaultChoices -Machine $m -Config $x).Remote | Should -BeExactly $case.E } }
  It 'follows the config defaults and falls back to OFF for an unknown Office value' {
    $off = [pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $false; office = 'home' } }
    $r = New-DefaultChoices -Machine $m -Config $off
    $r.SevenZip | Should -BeFalse; $r.Office | Should -Be 'HOME'
    $bad = [pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $true; office = 'PLATINUM' } }
    (New-DefaultChoices -Machine $m -Config $bad).Office | Should -Be 'OFF'
  }
  It 'opens on the default profile: home, its tweak selection and the restore point (toolbox spec 5.2)' {
    $r = New-DefaultChoices -Machine $m -Config $cfg
    $r.Profile | Should -BeExactly 'home'; $r.Office | Should -Be 'CRAFT'; $r.Remote | Should -Be 'ANYDESK'; $r.RestorePoint | Should -BeTrue
    @($r.Tweaks) | Should -Be @('accessKeys', 'numLock', 'startClean', 'noAds', 'classicOutlook') }
  It 'without profiles: no profile, the catalog defaults, a restore point' {
    $x = [pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $true; office = 'CRAFT' } }
    $r = New-DefaultChoices -Machine $m -Config $x; $r.Profile | Should -BeExactly ''; @($r.Tweaks).Count | Should -Be 0; $r.RestorePoint | Should -BeTrue }
  It 'the console fallback keeps the profile''s tweaks and follows L, D and O (Review Focus 3)' {
    $c = New-DefaultChoices -Machine $m -Config $cfg   # a laptop
    $eff = { param($x) (@(Get-EffectiveTweaks -Choices $x -Config $cfg -Machine $m) -join ',') }
    & $eff $c | Should -BeExactly 'accessKeys,startClean,noAds'
    $d = (Update-StartChoices -Choices $c -Key 'D').Choices; & $eff $d | Should -BeExactly 'accessKeys,numLock,startClean,noAds'
    & $eff ((Update-StartChoices -Choices $d -Key 'L').Choices) | Should -BeExactly 'accessKeys,startClean,noAds'
    & $eff ((Update-StartChoices -Choices $c -Key 'O').Choices) | Should -BeExactly 'accessKeys,startClean,noAds,classicOutlook'   # CRAFT -> BUSINESS
    @((Update-StartChoices -Choices $c -Key 'Z').Choices.Tweaks) | Should -Be @($c.Tweaks) }
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
}

Describe 'Format-StartScreen (v2)' {
  BeforeAll { function F([hashtable]$c, [int]$s = 25, [bool]$ac = $true, [bool]$fresh = $true, [bool]$tool = $true, $prev = $null) {
    Format-StartScreen -Machine $m -Choices $c -SecondsLeft $s -Version '2026.10.20.1' -OnAC $ac -IsFresh $fresh -Previous $prev -HasDriverTool $tool -MaxAgeDays 14 } }
  It 'shows the v2 layout for a fresh laptop on AC' {
    $l = F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'BUSINESS' }
    $l[0] | Should -Be (' ' + ('=' * 77)); $l[1] | Should -Be ('   BENTECH WINDOWS SETUP' + 'v2026.10.20.1'.PadLeft(54))
    $l | Should -Contain '   Dell Inc. Latitude 5440    SN: 7HX2K93    ON CHARGER'
    $l | Should -Contain '   New PC name: DELL-7HX2K93'
    $l | Should -Contain ('   WHAT WILL HAPPEN'.PadRight(53) + 'TO CHANGE IT, PRESS')
    $l | Should -Contain ('   Type     LAPTOP (driver tool + laptop app)'.PadRight(53) + 'L = laptop   D = desktop')
    $l | Should -Contain '   Chrome   always'
    $l | Should -Contain ('   Remote   ANYDESK'.PadRight(53) + 'R = anydesk / sc / both')
    ($l -join "`n") | Should -Not -Match 'unattended'
    $l | Should -Contain ('   7-Zip    YES'.PadRight(53) + 'Z = yes / no')
    $l | Should -Contain ('   Office   BUSINESS (Hebrew + English)'.PadRight(53) + 'O = craft / 365 / off')
    $l | Should -Contain ('   Starts by itself in 25 s   ' + ('#' * 17) + ('.' * 3))
    $l | Should -Contain '   ENTER = start now           ESC = cancel, change nothing'
    @($l | Where-Object { $_.Length -gt 79 }).Count | Should -Be 0
  }
  It 'shows <Text>, then the reminder, between Chrome and 7-Zip' -ForEach @(@{ Remote = 'SCREENCONNECT'; Text = 'SCREENCONNECT' }, @{ Remote = 'BOTH'; Text = 'ANYDESK + SCREENCONNECT' }) {
    $l = @(F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT'; Remote = $Remote })
    $at = [array]::IndexOf($l, (('   Remote   ' + $Text).PadRight(53) + 'R = anydesk / sc / both'))
    $at | Should -BeGreaterThan 0; $l[$at - 1] | Should -BeExactly '   Chrome   always'
    $l[$at + 1] | Should -BeExactly "   ScreenConnect = unattended access: get the customer's OK first"
    $l[$at + 2] | Should -BeLike '   7-Zip    *'
    @($l | Where-Object { $_.Length -gt 79 }).Count | Should -Be 0 }
  It 'shows the CRAFT line and still fits 79 columns' {
    $l = F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT' }
    $l | Should -Contain ('   Office   CRAFT (free Word/Excel/PowerPoint/PDF)'.PadRight(53) + 'O = craft / 365 / off')
    @($l | Where-Object { $_.Length -gt 79 }).Count | Should -Be 0 }
  It 'says what the mode means, also for a brand without a driver tool' {
    (F @{ Mode = 'DESKTOP'; SevenZip = $false; Office = 'OFF' }) | Should -Contain ('   Type     DESKTOP (no laptop app)'.PadRight(53) + 'L = laptop   D = desktop')
    (F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'HOME' } -tool $false) | Should -Contain ('   Type     LAPTOP (no driver tool for this brand)'.PadRight(53) + 'L = laptop   D = desktop')
    (F @{ Mode = 'DESKTOP'; SevenZip = $false; Office = 'OFF' }) | Should -Contain ('   Office   OFF'.PadRight(53) + 'O = craft / 365 / off')
  }
  It 'a full and an empty countdown bar' {
    (F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -s 30) | Should -Contain ('   Starts by itself in 30 s   ' + ('#' * 20))
    (F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -s 1) | Should -Contain ('   Starts by itself in 1 s   #' + ('.' * 19))
  }
  It 'not fresh: no countdown, the two-line message and ESC' {
    $l = F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -fresh $false
    $l | Should -Contain '   This PC already has user files or is older than 14 days -'
    $l | Should -Contain '   press ENTER to run anyway'; $l | Should -Contain '   ESC = cancel, change nothing'
    ($l -join "`n") | Should -Not -Match 'Starts by itself'
    @($l | Where-Object { $_.Length -gt 79 }).Count | Should -Be 0
  }
  It 'keeps the battery and previous-run lines and stays ASCII' {
    $odd = $m.Clone(); $odd.FriendlyModel = 'Latitude ' + [char]0x05D1
    $l = Format-StartScreen -Machine $odd -Choices @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -SecondsLeft 9 -Version 'v1' -OnAC $false -IsFresh $true -Previous @{ StartedAt = '2026-10-17T14:05:09'; Color = 'RED' }
    $l | Should -Contain '   ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery.'
    $l | Should -Contain '   Previous run: 17/10/2026 14:05 - RED'
    ($l -join "`n") -match '[^\x20-\x7E\n]' | Should -BeFalse
  }
  It 'says ON BATTERY on the machine line, and shows no battery warning on AC' {
    (F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -ac $false) | Should -Contain '   Dell Inc. Latitude 5440    SN: 7HX2K93    ON BATTERY'
    (F @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' }) -join "`n" | Should -Not -Match 'plug in the charger'
  }
  It 'does not double the v of the version, and the previous run may be a datetime or absent' {
    $c = @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' }
    $l = Format-StartScreen -Machine $m -Choices $c -SecondsLeft 9 -Version 'v1' -OnAC $true -IsFresh $true -Previous @{ StartedAt = [datetime]'2026-01-02T03:04:05'; Color = 'GREEN' }
    $l[1] | Should -Be ('   BENTECH WINDOWS SETUP' + 'v1'.PadLeft(54))
    $l | Should -Contain '   Previous run: 02/01/2026 03:04 - GREEN'
    (F $c) -join "`n" | Should -Not -Match 'Previous run'
  }
  It 'formats the previous run through the helper the toolbox shares, with its fallbacks (toolbox review M4)' {
    $l = Format-StartScreen -Machine $m -Choices @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'OFF' } -SecondsLeft 9 -Version 'v1' -OnAC $true -IsFresh $true -Previous @{ StartedAt = 'garbage'; Color = '' }
    $l | Should -Contain '   Previous run: unknown date - unfinished'
    $p = Format-PreviousRun -Previous @{ StartedAt = '2026-10-20T09:05:00'; Color = "YEL$Hebrew" }
    $p.When | Should -BeExactly '20/10/2026 09:05'; $p.Color | Should -BeExactly 'YEL?????'
    $f = Format-PreviousRun -Previous @{ StartedAt = $null; Color = $null } -UnknownDate 'no date' -Unfinished 'not done'
    $f.When | Should -BeExactly 'no date'; $f.Color | Should -BeExactly 'not done'
  }
  It 'a DESKTOP choice or a VM keeps the same layout (ASCII, no line over 79)' {
    $vm = $m.Clone(); $vm.IsVM = $true; $vm.Manufacturer = "Dell`r`nInc."
    $l = Format-StartScreen -Machine $vm -Choices @{ Mode = 'DESKTOP'; SevenZip = $true; Office = 'HOME' } -SecondsLeft 3 -Version 'v1' -OnAC $true -IsFresh $true -Previous $null -HasDriverTool $false
    $l | Should -Contain '   Dell Inc. Latitude 5440    SN: 7HX2K93    ON CHARGER'
    @($l | Where-Object { $_ -match "[`r`n]" }).Count | Should -Be 0
    @($l | Where-Object { $_.Length -gt 79 }).Count | Should -Be 0
  }
}
Describe 'start screen colours' {
  It 'the chosen value is green when on, dark grey when off; warnings are yellow' {
    $on = @(Get-StartScreenSegments -Line ('   7-Zip    YES'.PadRight(53) + 'Z = yes / no')); $on[1].Text | Should -Be 'YES'; $on[1].Color | Should -Be 'Green'
    $off = @(Get-StartScreenSegments -Line ('   Office   OFF'.PadRight(53) + 'O = craft / 365 / off')); $off[1].Text | Should -Be 'OFF'; $off[1].Color | Should -Be 'DarkGray'
    @(Get-StartScreenSegments -Line '   press ENTER to run anyway')[0].Color | Should -Be 'Yellow'
  }
  It 'CRAFT is shown green' {
    $s = @(Get-StartScreenSegments -Line ('   Office   CRAFT (free Word/Excel/PowerPoint/PDF)'.PadRight(53) + 'O = craft / 365 / off'))
    $s[1].Text | Should -Be 'CRAFT'; $s[1].Color | Should -Be 'Green' }
  It 'the segments of a line add up to the line, and the labels stay uncoloured' {
    foreach ($line in @(('   Type     LAPTOP (driver tool + laptop app)'.PadRight(53) + 'L = laptop   D = desktop'), ('   7-Zip    NO'.PadRight(53) + 'Z = yes / no'), '   Chrome   always', '')) {
      (@(Get-StartScreenSegments -Line $line) | ForEach-Object { $_.Text }) -join '' | Should -Be $line
    }
    $type = @(Get-StartScreenSegments -Line ('   Type     DESKTOP (no laptop app)'.PadRight(53) + 'L = laptop   D = desktop'))
    $type[0].Text | Should -Be '   Type     '; $type[0].Color | Should -BeNullOrEmpty
    $type[1].Text | Should -Be 'DESKTOP'; $type[1].Color | Should -Be 'Green'
    $type[2].Color | Should -BeNullOrEmpty
    $no = @(Get-StartScreenSegments -Line ('   7-Zip    NO'.PadRight(53) + 'Z = yes / no')); $no[1].Text | Should -Be 'NO'; $no[1].Color | Should -Be 'DarkGray'
  }
  It 'the battery line and both not-fresh text lines are one yellow segment; other lines are one plain segment' {
    foreach ($line in '   ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery.', '   This PC already has user files or is older than 14 days -', '   press ENTER to run anyway') {
      $s = @(Get-StartScreenSegments -Line $line); $s.Count | Should -Be 1; $s[0].Color | Should -Be 'Yellow'; $s[0].Text | Should -Be $line
    }
    foreach ($line in '   Chrome   always', '   WHAT WILL HAPPEN', '   ESC = cancel, change nothing', '   Starts by itself in 30 s   ####', '') {
      $s = @(Get-StartScreenSegments -Line $line); $s.Count | Should -Be 1; $s[0].Color | Should -BeNullOrEmpty; $s[0].Text | Should -Be $line
    }
  }
  It 'the whole Remote value is green; the reminder is one yellow segment' {
    $line = '   Remote   ANYDESK + SCREENCONNECT'.PadRight(53) + 'R = anydesk / sc / both'
    $s = @(Get-StartScreenSegments -Line $line)
    $s[0].Text | Should -Be '   Remote   '; $s[1].Text | Should -Be 'ANYDESK + SCREENCONNECT'; $s[1].Color | Should -Be 'Green'; $s[2].Color | Should -BeNullOrEmpty
    (@($s | ForEach-Object { $_.Text }) -join '') | Should -Be $line
    $y = @(Get-StartScreenSegments -Line "   ScreenConnect = unattended access: get the customer's OK first"); $y.Count | Should -Be 1; $y[0].Color | Should -Be 'Yellow' }
}

Describe 'Show-StartScreen' {
  # Safety net: this must only reach the console through its seams. The screen draws through a fake
  # console writer (never the real [Console]); Clear-Host and Write-Host throw, since the v2 start screen
  # uses neither.
  BeforeEach {
    Mock Clear-Host { throw 'Clear-Host must not run in tests' }
    Mock Write-Host { throw 'Write-Host must not run in tests' }
    Mock Start-Process { throw 'Start-Process must not run in tests' }
    Mock Write-SetupLog { }
    $script:fw = @{ Calls = New-Object System.Collections.ArrayList; Size = @{ Width = 100; Height = 30; Top = 0 } }
    $script:writer = @{ GetSize = { [pscustomobject]$script:fw.Size }; Clear = { param($b) [void]$script:fw.Calls.Add('clear'); $script:fw.ClearBack = $b }
      MoveTo = { param($row) [void]$script:fw.Calls.Add("row $row") }; Write = { param($t, $c, $b) [void]$script:fw.Calls.Add(@{ T = $t; C = $c; B = $b }) } }
    Reset-ConsoleFrame
  }
  It 'counts down from 30 and starts at 0 with the default choices (Q1)' {
    $r = Invoke-StartScreen
    $r.Mode | Should -Be 'LAPTOP'; $r.SevenZip | Should -BeTrue; $r.Office | Should -Be 'CRAFT'
    Get-ElapsedSeconds | Should -Be 30
    # One redraw per second: the first screen and then 29 ticks (30 s down to 1 s), nothing at 0.
    $screens.Count | Should -Be 30
    $screens[0] | Should -Match 'Starts by itself in 30 s'
    $screens[29] | Should -Match 'Starts by itself in 1 s'
    $screens[5] | Should -Match 'Starts by itself in 25 s'
  }
  It 'the countdown bar shrinks as the seconds run out' {
    Invoke-StartScreen | Out-Null
    $screens[0] | Should -Match ('Starts by itself in 30 s   ' + ('#' * 20) + '\r?\n')
    $screens[15] | Should -Match ('Starts by itself in 15 s   ' + ('#' * 10) + ('\.' * 10))
    $screens[29] | Should -Match ('Starts by itself in 1 s   #' + ('\.' * 19))
  }
  It 'starts at once on Enter without waiting for the countdown' {
    $r = Invoke-StartScreen -KeyAt { param($s) if ($s -ge 2) { 'Enter' } }
    $r | Should -Not -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeLessThan 2.5
  }
  It 'returns $null on Escape' {
    Invoke-StartScreen -KeyAt { param($s) if ($s -ge 3) { 'Escape' } } | Should -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeLessThan 3.5
  }
  It 'a toggle resets the countdown to 30 and is part of the result' {
    $script:zSent = $false
    $r = Invoke-StartScreen -KeyAt { param($s) if (-not $script:zSent -and $s -ge 4) { $script:zSent = $true; 'Z' } }
    $r.SevenZip | Should -BeFalse
    # Four ticks happened before the toggle, so a reset run lasts 4 s + 30 s.
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 34
    Get-ElapsedSeconds | Should -BeLessThan 34.5
    $toggleScreen = @($screens | Where-Object { $_ -match '7-Zip    NO\b' })[0]
    $toggleScreen | Should -Match 'Starts by itself in 30 s'
    # The screen just before the toggle was at 26 s.
    $screens[$screens.IndexOf($toggleScreen) - 1] | Should -Match 'Starts by itself in 26 s'
  }
  It 'an unknown key restarts the countdown at 30 (Q1)' {
    $script:sent = $false
    $r = Invoke-StartScreen -KeyAt { param($s) if (-not $script:sent -and $s -ge 4) { $script:sent = $true; 'X' } }
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 34
    Get-ElapsedSeconds | Should -BeLessThan 34.5
    # An unknown key changes nothing but the clock.
    $r.Mode | Should -Be 'LAPTOP'; $r.SevenZip | Should -BeTrue; $r.Office | Should -Be 'CRAFT'
    $screens[4] | Should -Match 'Starts by itself in 26 s'
    $screens[5] | Should -Match 'Starts by itself in 30 s'   # redrawn at once, not a second later
  }
  It 'any key restarts the countdown, however often it is pressed' {
    $script:presses = 0
    $r = Invoke-StartScreen -KeyAt { param($s) if ($script:presses -lt 3 -and $s -ge (10 * ($script:presses + 1))) { $script:presses++; 'Spacebar' } }
    $r | Should -Not -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 60
    Get-ElapsedSeconds | Should -BeLessThan 60.5
  }
  It 'a stray key on a machine that does not look fresh never starts it' {
    $script:sent = $false
    $r = Invoke-StartScreen -IsFresh $false -KeyAt { param($s) if (-not $script:sent -and $s -ge 5) { $script:sent = $true; 'X' } elseif ($s -ge 40) { 'Escape' } }
    $r | Should -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 40
  }
  It 'R picks ScreenConnect, shows the reminder and restarts the countdown' {
    $script:rSent = $false
    $r = Invoke-StartScreen -KeyAt { param($s) if (-not $script:rSent -and $s -ge 4) { $script:rSent = $true; 'R' } }
    $r.Remote | Should -Be 'SCREENCONNECT'; Get-ElapsedSeconds | Should -BeGreaterOrEqual 34
    $screens[0] | Should -Not -Match 'unattended access'; @($screens | Where-Object { $_ -match 'unattended access' }).Count | Should -BeGreaterThan 0 }
  It 'the L, D and O toggles change the returned choices' {
    $script:sent = New-Object System.Collections.Queue
    foreach ($k in 'D','O','O','L') { $script:sent.Enqueue($k) }
    $r = Invoke-StartScreen -KeyAt { param($s) if ($script:sent.Count -gt 0) { $script:sent.Dequeue() } }
    $r.Mode | Should -Be 'LAPTOP'; $r.Office | Should -Be 'HOME'   # CRAFT -> BUSINESS -> HOME
  }
  It 'never starts by itself when the machine is not fresh' {
    $r = Invoke-StartScreen -IsFresh $false -KeyAt { param($s) if ($s -ge 30) { 'Escape' } }
    $r | Should -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 30
    $screens.Count | Should -BeGreaterOrEqual 30
    @($screens | Where-Object { $_ -match 'Starts by itself' }).Count | Should -Be 0
    @($screens | Where-Object { $_ -match 'press ENTER to run anyway' }).Count | Should -Be $screens.Count
  }
  It 'starts on Enter when the machine is not fresh' {
    $r = Invoke-StartScreen -IsFresh $false -KeyAt { param($s) if ($s -ge 12) { 'Enter' } }
    $r | Should -Not -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 12
  }
  It 're-reads the power state every second: the battery line follows the injected reader' {
    $r = Invoke-StartScreen -OnAC { (Get-ElapsedSeconds) -lt 3.5 }
    $r | Should -Not -BeNullOrEmpty
    $screens[0] | Should -Not -Match 'ON BATTERY'
    $screens[0] | Should -Match 'ON CHARGER'
    $screens[3] | Should -Not -Match 'ON BATTERY'   # drawn at t=3s, still on AC
    $screens[4] | Should -Match 'ON BATTERY: plug in the charger'   # drawn at t=4s
    $screens[4] | Should -Match 'SN: 7HX2K93    ON BATTERY'
    $screens[9] | Should -Match 'ON BATTERY'
  }
  It 'tells a brand without a driver tool apart, and shows the configured age limit when not fresh' {
    $dell = $m.Clone(); $dell.Brand = 'DELL'
    $asus = $m.Clone(); $asus.Brand = 'ASUS'
    $dellVm = $dell.Clone(); $dellVm.IsVM = $true
    $esc = { param($s) if ($s -ge 1) { 'Escape' } }
    Invoke-StartScreen -Machine $dell -KeyAt $esc | Out-Null; $screens[0] | Should -Match 'Type     LAPTOP \(driver tool \+ laptop app\)'
    Invoke-StartScreen -Machine $asus -KeyAt $esc | Out-Null; $screens[0] | Should -Match 'Type     LAPTOP \(no driver tool for this brand\)'
    Invoke-StartScreen -Machine $dellVm -KeyAt $esc | Out-Null; $screens[0] | Should -Match 'Type     DESKTOP \(no driver tool for this brand\)'
    Invoke-StartScreen -Machine $dell -IsFresh $false -KeyAt $esc | Out-Null; $screens[0] | Should -Match 'older than 14 days'
  }
  It 'shows the previous run on every redraw' {
    Invoke-StartScreen -Previous @{ StartedAt = '2026-10-17T14:05:09'; Color = 'YELLOW' } -KeyAt { param($s) if ($s -ge 2) { 'Escape' } } | Out-Null
    @($screens | Where-Object { $_ -match 'Previous run: 17/10/2026 14:05 - YELLOW' }).Count | Should -Be $screens.Count
  }
  It 'still counts down when the clock stands still' {
    Reset-FakeClock
    $script:readCalls = 0
    $script:screens = New-Object System.Collections.ArrayList
    $r = Show-StartScreen -Machine $m -Config $cfg -Version 'v1' -Previous $null -IsFresh $true `
      -ReadKey { $script:readCalls++; if ($script:readCalls -gt 5000) { throw 'runaway loop' } } `
      -Now { $script:t0 } -Sleep { param($ms) } -OnAC { $true } -FlushInput { } -Write { param($lines) $null = $script:screens.Add(($lines -join "`n")) }
    $r | Should -Not -BeNullOrEmpty
    $screens.Count | Should -Be 30
  }
  It 'still counts down when the clock jumps backwards' {
    Reset-FakeClock
    $script:readCalls = 0
    $script:screens = New-Object System.Collections.ArrayList
    $r = Show-StartScreen -Machine $m -Config $cfg -Version 'v1' -Previous $null -IsFresh $true `
      -ReadKey { $script:readCalls++; if ($script:readCalls -gt 5000) { throw 'runaway loop' } } `
      -Now { $script:clock } -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds(-$ms) } -OnAC { $true } -FlushInput { } `
      -Write { param($lines) $null = $script:screens.Add(($lines -join "`n")) }
    $r | Should -Not -BeNullOrEmpty
    $screens.Count | Should -Be 30
  }
  It 'Write-StartScreenLines draws through the writer: one clear on Black, the value green, the warnings yellow, nothing else coloured' {
    Write-StartScreenLines -Writer $writer -Lines @(('   7-Zip    YES'.PadRight(53) + 'Z = yes / no'), '', '   ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery.', '   press ENTER to run anyway', '   Chrome   always', "   ScreenConnect = unattended access: get the customer's OK first")
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 1
    $fw.ClearBack | Should -Be 'Black'
    $w = @($fw.Calls | Where-Object { $_ -is [hashtable] })
    @($w | Where-Object { -not $_.C -or $_.B -ne 'Black' }).Count | Should -Be 0   # spec 9.1: both colours on every write
    @($w | Where-Object { $_.T -eq 'YES' })[0].C | Should -Be 'Green'
    @($w | Where-Object { $_.T -like '   ON BATTERY*' })[0].C | Should -Be 'Yellow'
    @($w | Where-Object { $_.T -like '   press ENTER*' })[0].C | Should -Be 'Yellow'
    @($w | Where-Object { $_.T -like '   Chrome   always*' })[0].C | Should -Be 'Gray'   # the row is padded to the window width, hence the *
    @($w | Where-Object { $_.T -like '   ScreenConnect =*' })[0].C | Should -Be 'Yellow'
    @($w | Where-Object { $_.T -like '   7-Zip    ' })[0].C | Should -Be 'Gray'
  }
  It 'Write-StartScreenLines never uses Write-Host or Clear-Host, and does not clear again for the same window size' {
    Write-StartScreenLines -Writer $writer -Lines @('   a')
    Write-StartScreenLines -Writer $writer -Lines @('   b')
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 1
    Should -Invoke Write-Host -Times 0 -Exactly
    Should -Invoke Clear-Host -Times 0 -Exactly
  }
  It 'draws through the production writer when no -Write seam is given' {
    Mock New-ConsoleWriter { $script:writer }
    Reset-FakeClock
    $r = Show-StartScreen -Machine $m -Config $cfg -Version '2026.10.18.1' -Previous $null -IsFresh $true `
      -ReadKey { 'Enter' } -Now { $script:clock } -Sleep { param($ms) } -OnAC { $true } -FlushInput { }
    $r | Should -Not -BeNullOrEmpty
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 1
    @($fw.Calls | Where-Object { $_ -is [hashtable] } | ForEach-Object { $_.T }) | Should -Contain (('   Starts by itself in 30 s   ' + ('#' * 20)).PadRight(99))
    Should -Invoke New-ConsoleWriter -Times 1 -Exactly
  }
  It 'empties the key buffer once, before the first draw' {
    Invoke-StartScreen -KeyAt { param($s) if ($s -ge 2) { 'Escape' } } | Out-Null
    @($startEvents | Where-Object { $_ -eq 'flush' }).Count | Should -Be 1
    $startEvents[0] | Should -Be 'flush'
    $startEvents.IndexOf('flush') | Should -BeLessThan $startEvents.IndexOf('write')
  }
  It 'a key waiting before the screen appears cannot start a machine that does not look fresh' {
    $script:stale = New-Object System.Collections.Queue
    $script:stale.Enqueue('Enter')
    $r = Invoke-StartScreen -IsFresh $false -FlushInput { $script:stale.Clear() } `
      -KeyAt { param($s) if ($script:stale.Count -gt 0) { $script:stale.Dequeue() } elseif ($s -ge 12) { 'Enter' } }
    $r | Should -Not -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 12   # only the Enter pressed after the screen appeared
    $startEvents[0] | Should -Be 'flush'
  }
  It 'the same waiting Enter starts the run at once when nothing empties the buffer' {
    $script:stale = New-Object System.Collections.Queue
    $script:stale.Enqueue('Enter')
    $r = Invoke-StartScreen -IsFresh $false `
      -KeyAt { param($s) if ($script:stale.Count -gt 0) { $script:stale.Dequeue() } elseif ($s -ge 12) { 'Enter' } }
    $r | Should -Not -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeLessThan 1
  }
  It 'still shows the screen when emptying the key buffer fails' {
    $r = Invoke-StartScreen -FlushInput { throw 'no console input here' }
    $r | Should -Not -BeNullOrEmpty
    $screens.Count | Should -Be 30
  }
  It 'a writer that fails (the window resized mid-frame) is one WARN per failure; the next frame clears and the run goes on' {
    $script:warns = 0; Mock Write-SetupLog { if ($Level -eq 'WARN') { $script:warns++ } }
    $script:failNext = $true
    $fw.Size = @{ Width = 100; Height = 30; Top = 0 }
    $writer.MoveTo = { param($row) if ($script:failNext) { $script:failNext = $false; throw 'The cursor position cannot be smaller than zero or larger than the buffer' }; [void]$script:fw.Calls.Add("row $row") }
    Mock New-ConsoleWriter { $script:writer }
    Reset-FakeClock; $script:readCalls = 0
    $r = Show-StartScreen -Machine $m -Config $cfg -Version 'v1' -Previous $null -IsFresh $true `
      -ReadKey { $script:readCalls++; if ($script:readCalls -gt 5000) { throw 'runaway loop' } } `
      -Now { $script:clock } -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds($ms) } -OnAC { $true } -FlushInput { }
    $r | Should -Not -BeNullOrEmpty
    $warns | Should -Be 1
    # The first frame died after its clear; the second frame (one second later) clears again and draws.
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 2
    @($fw.Calls | Where-Object { $_ -is [hashtable] -and $_.T -like '   Starts by itself in 29 s*' }).Count | Should -Be 1
  }
  It 'keeps going when the power reader throws' {
    $r = Invoke-StartScreen -OnAC { throw 'WMI is unhappy' }
    $r | Should -Not -BeNullOrEmpty
    $screens[9] | Should -Not -Match 'ON BATTERY'
  }
}

Describe 'Show-StartScreen -NoAutoStart (TB-R8: the console fallback waits for Enter)' {
  # The same safety net as 'Show-StartScreen': the screen reaches the console only through its seams.
  BeforeAll {
    # Show-StartScreen -NoAutoStart against the fake clock, with Invoke-StartScreen's seams.
    function Invoke-NoAutoStart([bool]$IsFresh = $true, [scriptblock]$KeyAt = { param($s) }) {
      Reset-FakeClock
      $script:screens = New-Object System.Collections.ArrayList
      $script:keyAt = $KeyAt
      $script:readCalls = 0
      Show-StartScreen -Machine $script:m -Config $script:cfg -Version '2026.10.18.1' -Previous $null -IsFresh $IsFresh -NoAutoStart `
        -ReadKey { $script:readCalls++; if ($script:readCalls -gt 5000) { throw 'runaway loop: the fake clock stopped advancing' }; & $script:keyAt (Get-ElapsedSeconds) } `
        -Now { $script:clock } -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds($ms) } -OnAC { $true } -FlushInput { } `
        -Write { param($lines) $null = $script:screens.Add(($lines -join "`n")) }
    }
    $script:enterLine = '   ENTER = start now           ESC = cancel, change nothing'
  }
  BeforeEach {
    Mock Clear-Host { throw 'Clear-Host must not run in tests' }
    Mock Write-Host { throw 'Write-Host must not run in tests' }
    Mock Start-Process { throw 'Start-Process must not run in tests' }
    Mock Write-SetupLog { }
    Reset-ConsoleFrame
  }
  It 'a fresh PC never starts by itself: no countdown at all, still waiting at 120 s, then Escape is $null' {
    $r = Invoke-NoAutoStart -KeyAt { param($s) if ($s -ge 120) { 'Escape' } }
    $r | Should -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 120
    $screens.Count | Should -BeGreaterOrEqual 120   # it kept redrawing (the power line) the whole time
    @($screens | Where-Object { $_ -match 'Starts by itself' }).Count | Should -Be 0
    @($screens | Where-Object { ($_ -split "`n") -ccontains $script:enterLine }).Count | Should -Be $screens.Count
  }
  It 'only Enter starts it, long after 30 s, with the choices as toggled; toggles and stray keys start nothing' {
    $script:sent = New-Object System.Collections.Queue
    $r = Invoke-NoAutoStart -KeyAt { param($s)
      if ($s -ge 5 -and -not $script:sent.Contains('Z')) { $script:sent.Enqueue('Z'); 'Z' }
      elseif ($s -ge 20 -and -not $script:sent.Contains('X')) { $script:sent.Enqueue('X'); 'X' }
      elseif ($s -ge 75) { 'Enter' } }
    $r | Should -Not -BeNullOrEmpty; $r.SevenZip | Should -BeFalse; $r.Office | Should -Be 'CRAFT'
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 75
    @($screens | Where-Object { $_ -match 'Starts by itself' }).Count | Should -Be 0
  }
  It 'the fresh screen is the countdown screen without its countdown line; every other line stays (Format-StartScreen)' {
    $c = @{ Mode = 'LAPTOP'; SevenZip = $true; Office = 'CRAFT'; Remote = 'BOTH' }
    $counting = @(Format-StartScreen -Machine $m -Choices $c -SecondsLeft 25 -Version 'v1' -OnAC $false -IsFresh $true -Previous @{ StartedAt = '2026-10-17T14:05:09'; Color = 'RED' })
    $waiting = @(Format-StartScreen -Machine $m -Choices $c -SecondsLeft 25 -Version 'v1' -OnAC $false -IsFresh $true -Previous @{ StartedAt = '2026-10-17T14:05:09'; Color = 'RED' } -NoAutoStart)
    $waiting | Should -Be @($counting | Where-Object { $_ -notlike '   Starts by itself*' })
    $waiting.Count | Should -Be ($counting.Count - 1)
    $waiting[-2] | Should -BeExactly $script:enterLine
    $waiting[-1] | Should -BeExactly (' ' + ('=' * 77))
  }
  It 'a PC that does not look fresh shows exactly what it shows today' {
    $c = @{ Mode = 'DESKTOP'; SevenZip = $false; Office = 'OFF' }
    @(Format-StartScreen -Machine $m -Choices $c -SecondsLeft 30 -Version 'v1' -OnAC $true -IsFresh $false -Previous $null -NoAutoStart) |
      Should -Be @(Format-StartScreen -Machine $m -Choices $c -SecondsLeft 30 -Version 'v1' -OnAC $true -IsFresh $false -Previous $null)
    $r = Invoke-NoAutoStart -IsFresh $false -KeyAt { param($s) if ($s -ge 40) { 'Escape' } }
    $r | Should -BeNullOrEmpty
    @($screens | Where-Object { $_ -match 'press ENTER to run anyway' }).Count | Should -Be $screens.Count
  }
}

Describe 'Format-ProgressScreen (v2)' {
  It 'draws header, checklist columns, NOW and JUST HAPPENED' {
    $l = Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -Spinner '/' -NowView $view -Activity $act
    $l[0] | Should -Be '  BENTECH WINDOWS SETUP - working, do not turn off   /   Total 01:12:40   Restarts 2'
    $l[1] | Should -Be ('  ' + ('-' * 96))
    $l[2] | Should -Be ('  ' + '[OK] Prepare'.PadRight(32) + '[OK] AnyDesk'.PadRight(32) + '[>>] Microsoft 365 (bg) 13:40')
    $l[3] | Should -Be ('  ' + '[--] BitLocker off'.PadRight(32) + '[OK] 7-Zip'.PadRight(32) + '[..] Windows Update')
    $l[4] | Should -Be ('  ' + '[X ] Chrome'.PadRight(32) + '[>>] Drivers (pass 1)'.PadRight(32) + '[..] Finish')
    $l[6] | Should -Be '  NOW  Drivers (pass 1) - Dell Command Update   /   12:40 (of max 60 min)'
    $l[7] | Should -Be '       Log: Installing Intel Chipset'
    $l[9] | Should -Be '  JUST HAPPENED'
    $l[10] | Should -Be '  12:31  Microsoft 365 started installing in the background'
    ($l -join "`n") | Should -Not -Match 'Microsoft 365 \(finish\)'
  }
  It 'NOW without a wait shows the step time and no limit' {
    (Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView @{ Lines = @() } -Activity @())[6] | Should -Be '  NOW  Drivers (pass 1)   /   12:40'
  }
  It 'NOW shows an override title (the Office restart wait)' {
    $v = @{ Title = 'Waiting for Microsoft 365 to finish before restarting'; Wait = @{ StartedAt = [datetime]'2026-10-20T11:59:00'; LimitMinutes = 60 } }
    (Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView $v)[6] | Should -Be '  NOW  Waiting for Microsoft 365 to finish before restarting   /   13:40 (of max 60 min)'
  }
  It 'falls back to the newest activity line when the step has no detail' {
    (Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView @{ Lines = @() } -Activity $act)[7] | Should -Be '       Microsoft 365 started installing in the background'
  }
  It 'cuts a long NOW list with "... and N more"' {
    $v = @{ Lines = @(1..15 | ForEach-Object { "update $_" }) }
    $l = Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 40 -NowView $v
    $l[7] | Should -Be '       update 1'; $l[15] | Should -Be '       update 9'; $l[16] | Should -Be '       ... and 6 more'
  }
  It 'shrinks JUST HAPPENED first, then the NOW list, and keeps header, checklist and NOW line' {
    $v = @{ Lines = @(1..10 | ForEach-Object { "u$_" }) }
    $l = @(Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 12 -NowView $v -Activity $act)
    $l.Count | Should -Be 11; $l[6] | Should -Match '^  NOW  '; $l[10] | Should -Be '       ... and 7 more'
    $l | Should -Not -Contain '  JUST HAPPENED'
  }
  It 'fits a tiny 40x12 window (Review Focus 3)' {
    $l = @(Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 40 -Height 12 -NowView $view -Activity $act)
    $l.Count | Should -BeLessOrEqual 11; @($l | Where-Object { $_.Length -gt 39 }).Count | Should -Be 0
  }
  It 'is ASCII only with Hebrew everywhere (Review Focus 4)' {
    $v = @{ SubTitle = "tool $Hebrew"; Lines = @("log $Hebrew") }; $a = @([pscustomobject]@{ Time = $now; Text = "done $Hebrew" })
    ((Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView $v -Activity $a) -join "`n") -match '[^\x20-\x7E\n]' | Should -BeFalse
  }
  It 'in a tiny window drops the separators first, then checklist rows from the bottom; header and NOW stay' {
    $l = @(Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 40 -Height 12 -NowView $view -Activity $act)
    $l.Count | Should -Be 11
    $l[0] | Should -Match '^  BENTECH WINDOWS SETUP'; $l[1] | Should -Be '  [OK] Prepare'; $l[9] | Should -Be '  [..] Finish'; $l[10] | Should -Match '^  NOW  Drivers \(pass 1\)'
    $l = @(Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 40 -Height 8 -NowView $view -Activity $act)
    $l.Count | Should -Be 7
    $l[0] | Should -Match '^  BENTECH'; $l[1] | Should -Be '  [OK] Prepare'; $l[5] | Should -Be '  [OK] 7-Zip'; $l[6] | Should -Match '^  NOW  '
  }
  It 'shows NOW "-" with no time when nothing runs and no title is set, and leaves out an empty JUST HAPPENED' {
    $st = New-V2State; $st.Steps['vendor-pass1'] = @{ Status = 'Done' }
    $l = @(Format-ProgressScreen -State $st -Catalog $cat -Now $now -Width 100 -Height 30)
    $l[6] | Should -Be '  NOW  -'
    $l.Count | Should -Be 7
  }
  It 'never shows a negative wait limit or time' {
    $v = @{ Wait = @{ StartedAt = [datetime]'2026-10-20T13:00:00'; LimitMinutes = -0.5 } }
    (Format-ProgressScreen -State (New-V2State) -Catalog $cat -Now $now -Width 100 -Height 30 -NowView $v)[6] | Should -Be '  NOW  Drivers (pass 1)   /   00:00 (of max 0 min)'
  }
  It 'titles a step from Short, else Title, else the id' {
    $c = @(@{ Id = 'prepare'; Title = 'Prepare machine' }, @{ Id = 'bitlocker'; Short = 'BitLocker off'; Title = 'x' })
    $st = @{ StartedAt = '2026-10-20T11:00:00'; RebootCount = 0; Plan = @('prepare', 'bitlocker', 'mystery'); Steps = @{} }
    $l = @(Format-ProgressScreen -State $st -Catalog $c -Now $now -Width 100 -Height 30)
    $l[2] | Should -Be ('  ' + '[..] Prepare machine'.PadRight(23) + '[..] BitLocker off'.PadRight(23) + '[..] mystery')
  }
}
Describe 'Get-ChecklistEntry: the Microsoft 365 line' {
  It 'shows the result of office-finish once it has one' { $s = New-V2State; $s.Steps['office-finish'] = @{ Status = 'Failed'; Message = 'Office setup timed out' }; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[X ] Microsoft 365' }
  It 'keeps office''s own failure' { $s = New-V2State; $s.Steps.office = @{ Status = 'Failed' }; $s.Steps['office-finish'] = @{ Status = 'Done' }; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[X ] Microsoft 365' }
  It 'says (bg ended) when the background process has ended' { $s = New-V2State; $s.Steps.office.Data.Finished = $true; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[..] Microsoft 365 (bg ended)' }
  It 'is running while office-finish waits' { $s = New-V2State; $s.Steps['office-finish'] = @{ Status = 'running' }; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[>>] Microsoft 365' }
  It 'is [OK] for a foreground Office install with office-finish not started' { $s = New-V2State; $s.Steps.office = @{ Status = 'Done' }; Get-ChecklistEntry -State $s -Id 'office' -Short 'Microsoft 365' -Now $now | Should -Be '[OK] Microsoft 365' }
  It 'marks every other step by its own status, with no timer' {
    $s = New-V2State
    Get-ChecklistEntry -State $s -Id 'vendor-pass1' -Short 'Drivers (pass 1)' -Now $now | Should -Be '[>>] Drivers (pass 1)'
    Get-ChecklistEntry -State $s -Id 'bitlocker' -Short 'BitLocker off' -Now $now | Should -Be '[--] BitLocker off'
    Get-ChecklistEntry -State $s -Id 'not-in-state' -Short 'X' -Now $now | Should -Be '[..] X'
  }
}
Describe 'Format-Checklist' {
  It 'fills columns top to bottom, two-space indent, no trailing spaces' { Format-Checklist -Entries @('a','b','c','d','e') -Width 20 | Should -Be @('  a   c   e', '  b   d') }
  It 'uses one column when the window is narrower than one entry' { Format-Checklist -Entries @('[OK] Prepare', '[..] Finish') -Width 10 | Should -Be @('  [OK] Prepare', '  [..] Finish') }
}
Describe 'Format-Elapsed and Format-MinutesSeconds' {
  It 'do not wrap hours or minutes, and show a negative span as zero' {
    Format-Elapsed -Span ([timespan]::FromSeconds(26 * 3600 + 65)) | Should -Be '26:01:05'
    Format-Elapsed -Span ([timespan]::FromSeconds(-5)) | Should -Be '00:00:00'
    Format-MinutesSeconds -Span ([timespan]::FromSeconds(101 * 60 + 7)) | Should -Be '101:07'
    Format-MinutesSeconds -Span ([timespan]::FromSeconds(-5)) | Should -Be '00:00'
  }
}
Describe 'ConsoleFrame' {
  BeforeEach {
    $script:fw = @{ Calls = New-Object System.Collections.ArrayList; Size = @{ Width = 30; Height = 5; Top = 10 } }
    $script:writer = @{ GetSize = { [pscustomobject]$script:fw.Size }; Clear = { param($b) [void]$script:fw.Calls.Add('clear'); $script:fw.ClearBack = $b }
      MoveTo = { param($row) [void]$script:fw.Calls.Add("row $row") }; Write = { param($t, $c, $b) [void]$script:fw.Calls.Add(@{ T = $t; C = $c; B = $b }) } }
    Reset-ConsoleFrame
    Mock Write-Host { throw 'Write-Host must not be used' }; Mock Clear-Host { throw 'Clear-Host must not be used' }
  }
  It 'ConvertTo-ConsoleFrame pads and cuts to exactly Width x Height' {
    $f = ConvertTo-ConsoleFrame -Lines @('abc', ('x' * 50)) -Width 10 -Height 3
    $f.Count | Should -Be 3; @($f | Where-Object { $_.Length -ne 10 }).Count | Should -Be 0; $f[0] | Should -Be 'abc       '
  }
  It 'clears only when the size changes, writes Height-1 rows of Width-1 characters and parks the cursor' {
    Write-ConsoleFrame -Lines @('a', 'b') -Writer $writer; Write-ConsoleFrame -Lines @('a', 'b') -Writer $writer
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 1
    @($fw.Calls | Where-Object { $_ -is [hashtable] -and $_.T.Length -ne 29 }).Count | Should -Be 0
    @($fw.Calls | Where-Object { $_ -is [hashtable] -and (-not $_.C -or $_.B -ne 'Black') }).Count | Should -Be 0   # spec 9.1: both colours, on Black
    $fw.ClearBack | Should -Be 'Black'
    @($fw.Calls | Where-Object { $_ -eq 'row 14' }).Count | Should -Be 2     # Top + Height - 1, once per frame
    $fw.Calls[$fw.Calls.Count - 1] | Should -Be 'row 14'
    $fw.Size.Width = 40; Write-ConsoleFrame -Lines @('a') -Writer $writer
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 2
  }
  It 'clears again after Reset-ConsoleFrame, and blanks the rows it has no line for' {
    Write-ConsoleFrame -Lines @('a', 'b') -Writer $writer; Reset-ConsoleFrame; $fw.Calls.Clear()
    Write-ConsoleFrame -Lines @('a') -Writer $writer
    $fw.Calls[0] | Should -Be 'clear'
    @($fw.Calls | Where-Object { $_ -is [hashtable] } | ForEach-Object { $_.T }) | Should -Be @(('a'.PadRight(29)), (' ' * 29), (' ' * 29), (' ' * 29))
    @($fw.Calls | Where-Object { $_ -is [string] -and $_ -like 'row *' }) | Should -Be @('row 10', 'row 11', 'row 12', 'row 13', 'row 14')
  }
  It 'writes each Colorize segment in its colour, else the frame colours, always with a background' {
    Write-ConsoleFrame -Lines @('  [OK] a') -Writer $writer -Foreground 'White' -Background 'Black' -Colorize { param($l) @{ Text = $l.Substring(0, 2) }; @{ Text = $l.Substring(2); Color = 'Green'; Background = 'Blue' } }
    $w = @($fw.Calls | Where-Object { $_ -is [hashtable] })
    $w[0].T | Should -Be '  '; $w[0].C | Should -Be 'White'; $w[0].B | Should -Be 'Black'
    $w[1].T | Should -Be '[OK] a'.PadRight(27); $w[1].C | Should -Be 'Green'; $w[1].B | Should -Be 'Blue'
  }
  It 'lets a writer failure propagate (the tick catches it)' {
    $writer.MoveTo = { param($row) throw 'window closed' }
    { Write-ConsoleFrame -Lines @('a') -Writer $writer } | Should -Throw '*window closed*'
  }
  It 'Split-ProgressLine colours each marker up to the next one' {
    $s = @(Split-ProgressLine -Line '  [OK] Prepare   [X ] Chrome')
    $s[0].Text | Should -Be '  '; $s[0].Color | Should -BeNullOrEmpty
    $s[1].Text | Should -Be '[OK] Prepare   '; $s[1].Color | Should -Be 'Green'
    $s[2].Text | Should -Be '[X ] Chrome'; $s[2].Color | Should -Be 'Red'
  }
  It 'Split-ProgressLine knows every marker and leaves plain text whole' {
    $s = @(Split-ProgressLine -Line '[>>] a [--] b [..] c')
    $s.Count | Should -Be 3
    $s[0].Text | Should -Be '[>>] a '; $s[0].Color | Should -Be 'Cyan'
    $s[1].Text | Should -Be '[--] b '; $s[1].Color | Should -Be 'DarkGray'
    $s[2].Text | Should -Be '[..] c'; $s[2].Color | Should -BeNullOrEmpty
    $p = @(Split-ProgressLine -Line '  NOW  Windows Update')
    $p.Count | Should -Be 1; $p[0].Text | Should -Be '  NOW  Windows Update'; $p[0].Color | Should -BeNullOrEmpty
  }
  It 'Get-ConsoleTargetSize grows to 100x45 within the screen and never shrinks' {
    $r = Get-ConsoleTargetSize -Current @{ Width = 80; Height = 25; BufferWidth = 80; BufferHeight = 9001 } -Largest @{ Width = 160; Height = 50 }
    $r.WindowWidth | Should -Be 100; $r.WindowHeight | Should -Be 45; $r.BufferWidth | Should -Be 100; $r.BufferHeight | Should -Be 9001
    (Get-ConsoleTargetSize -Current @{ Width = 80; Height = 25; BufferWidth = 80; BufferHeight = 25 } -Largest @{ Width = 90; Height = 30 }).WindowHeight | Should -Be 30
    (Get-ConsoleTargetSize -Current @{ Width = 120; Height = 50; BufferWidth = 120; BufferHeight = 9001 } -Largest @{ Width = 160; Height = 60 }).WindowWidth | Should -Be 120
  }
  It 'Resize-SetupConsole never throws: a refusal is logged at INFO and gives $false' {
    # Get-ConsoleTargetSize throws before anything is set, so the console running the tests is never resized.
    Mock Get-ConsoleTargetSize { throw 'The handle is invalid.' }; Mock Write-SetupLog { }
    Resize-SetupConsole | Should -BeFalse
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'INFO' }
    Should -Invoke Write-SetupLog -Times 0 -Exactly -ParameterFilter { $Level -ne 'INFO' }
  }
  It 'Show-ProgressScreen draws through the writer and the spinner moves on every call' {
    $script:ProgressSpinnerIndex = 0; $fw.Size = @{ Width = 100; Height = 30; Top = 0 }
    Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer
    Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer
    $heads = @($fw.Calls | Where-Object { $_ -is [hashtable] -and $_.T -like '  BENTECH WINDOWS SETUP*' })
    $heads[0].T | Should -Match '   \|   Total'; $heads[1].T | Should -Match '   /   Total'
  }
  It 'Show-ProgressScreen colours the checklist markers and shows the NOW provider''s lines' {
    Clear-SetupNow; Set-SetupNow -SubTitle 'Dell Command Update' -Provider { param($a) "Log: $a" } -ProviderArgument 'Installing Intel Chipset'
    $fw.Size = @{ Width = 100; Height = 30; Top = 0 }
    Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer
    Clear-SetupNow
    $w = @($fw.Calls | Where-Object { $_ -is [hashtable] })
    @($w | Where-Object { $_.T -like '`[X `] Chrome*' })[0].C | Should -Be 'Red'
    @($w | Where-Object { $_.T -like '`[OK`] Prepare*' })[0].C | Should -Be 'Green'
    @($w | Where-Object { $_.T -like '  NOW  Drivers (pass 1) - Dell Command Update   /   12:40*' }).Count | Should -Be 1
    @($w | Where-Object { $_.T -like '       Log: Installing Intel Chipset*' }).Count | Should -Be 1
  }
  It 'a provider that throws still gives a screen, with one WARN' {
    $script:warns = 0; Mock Write-SetupLog { if ($Level -eq 'WARN') { $script:warns++ } }
    Clear-SetupNow; Set-SetupNow -Provider { throw 'bad json' }; $fw.Size = @{ Width = 100; Height = 30; Top = 0 }
    { Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer } | Should -Not -Throw
    { Show-ProgressScreen -State (New-V2State) -Catalog $cat -Now { $now } -Writer $writer } | Should -Not -Throw
    $warns | Should -Be 1; Clear-SetupNow
  }
  It 'a provider that fails again after Clear-SetupNow warns again' {
    $script:warns = 0; Mock Write-SetupLog { if ($Level -eq 'WARN') { $script:warns++ } }
    Clear-SetupNow; Set-SetupNow -Provider { throw 'bad json' }
    (Get-ProgressNowView).Lines.Count | Should -Be 0; $null = Get-ProgressNowView
    Clear-SetupNow; Set-SetupNow -Provider { throw 'still bad' }
    $null = Get-ProgressNowView
    $warns | Should -Be 2; Clear-SetupNow
  }
}

Describe 'Format-BigDigits' {
  It 'big digits are 5 rows' { @(Format-BigDigits -Text '123').Count | Should -Be 5 }
  It 'draws a 7 exactly' {
    $r = @(Format-BigDigits -Text '7')
    $r.Count | Should -Be 5
    $r[0] | Should -Be '#####'
    $r[1] | Should -Be '    #'
    $r[2] | Should -Be '   # '
    $r[3] | Should -Be '  #  '
    $r[4] | Should -Be '  #  '
  }
  It 'draws a 0 exactly' {
    $r = @(Format-BigDigits -Text '0')
    $r | Should -Be @('#####', '#   #', '#   #', '#   #', '#####')
  }
  It 'puts one blank column between glyphs and none after the last' {
    $r = @(Format-BigDigits -Text '07')
    $r[0] | Should -Be '##### #####'
    $r[1] | Should -Be '#   #     #'
    @($r | Where-Object { $_.Length -ne 11 }).Count | Should -Be 0
  }
  It 'renders a space as a blank 5-column glyph and unknown characters as spaces' {
    (Format-BigDigits -Text '1 1') | ForEach-Object { $_.Length } | Should -Be @(17, 17, 17, 17, 17)
    $a = @(Format-BigDigits -Text '1 1'); $b = @(Format-BigDigits -Text '1x1')
    $b | Should -Be $a
  }
  It 'gives all ten digits a distinct 5x5 glyph made of # and spaces' {
    $seen = @{}
    foreach ($d in 0..9) {
      $rows = @(Format-BigDigits -Text ([string]$d))
      $rows.Count | Should -Be 5
      foreach ($row in $rows) { $row.Length | Should -Be 5; $row -match '^[# ]{5}$' | Should -BeTrue }
      $seen[($rows -join '|')] = $true
    }
    $seen.Count | Should -Be 10
  }
  It 'returns five empty rows for empty text' {
    $r = @(Format-BigDigits -Text '')
    $r.Count | Should -Be 5
    @($r | Where-Object { $_ -ne '' }).Count | Should -Be 0
  }
}

Describe 'Format-FinalScreen' {
  BeforeAll {
    function New-FinalState { @{ Machine = $script:m; AnyDeskId = '123456789'; RebootCount = 3; StartedAt = '2026-10-18T09:00:00'; EndedAt = '2026-10-18T10:12:00' } }
    function New-Verdict { param($Color = 'YELLOW', $Banner = 'COMPLETE - CHECK NOTES', $Failures = @(), $Notes = @('x')) @{ Color = $Color; Banner = $Banner; Failures = $Failures; Notes = $Notes } }
  }
  It 'shows the default-browser hint' {
    $st = @{ Machine=$m; AnyDeskId='123456789'; RebootCount=3; StartedAt='2026-10-18T09:00:00'; EndedAt='2026-10-18T10:12:00' }
    $l = Format-FinalScreen -State $st -Verdict @{Color='YELLOW';Banner='COMPLETE - CHECK NOTES';Failures=@();Notes=@('x')} -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $false
    ($l -join "`n") | Should -Match "press B to open Default Apps, then click 'Set default'"; ($l -join "`n") | Should -Match 'COMPLETE - CHECK NOTES'
  }
  It 'prints the hint line exactly, and no hint when Chrome is the default' {
    $v = New-Verdict
    (Format-FinalScreen -State (New-FinalState) -Verdict $v -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $false) |
      Should -Contain "  Chrome is not the default browser: press B to open Default Apps, then click 'Set default'"
    (Format-FinalScreen -State (New-FinalState) -Verdict $v -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true) -join "`n" | Should -Not -Match 'press B'
  }
  It 'centres the banner in an 80 column frame of =' {
    $l = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict -Banner 'SETUP COMPLETE' -Color 'GREEN' -Notes @()) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $l[0] | Should -Be ('=' * 80)
    $bannerLine = @($l | Where-Object { $_ -match 'SETUP COMPLETE' })[0]
    $bannerLine | Should -Be ((' ' * 33) + 'SETUP COMPLETE')   # (80 - 14) / 2 = 33
    $l.IndexOf($bannerLine) | Should -BeLessThan 4
    $l[$l.IndexOf($bannerLine) + 2] | Should -Be ('=' * 80)
  }
  It 'prints the machine, the new name and the serial' {
    $l = Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true
    $l | Should -Contain '  Machine  : Dell Inc.  Latitude 5440        SN: 7HX2K93'
    $l | Should -Contain '  New name : DELL-7HX2K93'
  }
  It 'shows the AnyDesk ID as big digits grouped 3-3-3' {
    $l = Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true
    $l | Should -Contain '  AnyDesk ID:'
    $rows = @(Format-BigDigits -Text '123 456 789')
    $at = $l.IndexOf('  AnyDesk ID:')
    foreach ($i in 0..4) { $l[$at + 1 + $i] | Should -Be ('    ' + $rows[$i]) }
  }
  It 'groups a 10 digit ID 3-3-4' {
    $st = New-FinalState; $st.AnyDeskId = '1234567890'
    $l = Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true
    $rows = @(Format-BigDigits -Text '123 456 7890')
    $at = $l.IndexOf('  AnyDesk ID:')
    foreach ($i in 0..4) { $l[$at + 1 + $i] | Should -Be ('    ' + $rows[$i]) }
    $rows[0].Length + 4 | Should -BeLessThan 80
  }
  It 'says not available when there is no AnyDesk ID' {
    foreach ($id in $null, '', 'abc') {
      $st = New-FinalState; $st.AnyDeskId = $id
      $l = Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true
      $l | Should -Contain '  AnyDesk ID: not available'
      @($l | Where-Object { $_ -match '#' }).Count | Should -Be 0
    }
  }
  It 'shows total time and reboots' {
    (Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true) | Should -Contain '  Total time: 1:12   Reboots: 3'
  }
  It 'uses the given time as the end when the run has not ended' {
    $st = New-FinalState; $st.EndedAt = $null
    $l = Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true -Now ([datetime]'2026-10-18T09:45:59')
    $l | Should -Contain '  Total time: 0:45   Reboots: 3'
  }
  It 'lists failures with X and notes with !' {
    $l = Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict -Color 'RED' -Banner 'COMPLETED WITH ERRORS' -Failures @('Google Chrome: MSI exit 1603', 'Reboot limit reached') -Notes @('7-Zip: winget unavailable')) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true
    $l | Should -Contain '  X  Google Chrome: MSI exit 1603'
    $l | Should -Contain '  X  Reboot limit reached'
    $l | Should -Contain '  !  7-Zip: winget unavailable'
  }
  It 'orders the sections: banner, machine, AnyDesk, time, failures, notes, hint, report' {
    $l = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict -Failures @('F1') -Notes @('N1')) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $false)
    $idx = @(
      $l.IndexOf('  Machine  : Dell Inc.  Latitude 5440        SN: 7HX2K93'), $l.IndexOf('  AnyDesk ID:'), $l.IndexOf('  Total time: 1:12   Reboots: 3'),
      $l.IndexOf('  X  F1'), $l.IndexOf('  !  N1'),
      $l.IndexOf("  Chrome is not the default browser: press B to open Default Apps, then click 'Set default'"),
      $l.IndexOf('  Report: C:\r.txt   [R] open report   [ENTER] finish')
    )
    @($idx | Where-Object { $_ -lt 0 }).Count | Should -Be 0
    $sorted = @($idx | Sort-Object)
    $idx | Should -Be $sorted
    $idx[6] | Should -Be ($l.Count - 1)   # the report line is last
  }
  It 'ends with the report line' {
    $l = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' -DefaultBrowserIsChrome $true)
    $l[$l.Count - 1] | Should -Be '  Report: C:\BenTech\Setup\Logs\Setup-Report.txt   [R] open report   [ENTER] finish'
  }
  It 'puts the stick line right above the report line, below the Chrome hint; no line without one' {
    $stickLine = '  USB stick found (E:) - logs will be saved there'
    $l = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $false -StickLine $stickLine)
    $l[$l.Count - 2] | Should -Be $stickLine
    $l[$l.Count - 3] | Should -Be "  Chrome is not the default browser: press B to open Default Apps, then click 'Set default'"
    $without = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $false)
    $without.Count | Should -Be ($l.Count - 1)
  }
  It 'caps long lists (3 failures, 2 notes) so the banner and the ID stay on screen, and cuts long lines' {
    $many = 1..9 | ForEach-Object { "Failure number $_" }
    $long = 'Windows Update: ' + ('y' * 200)
    $l = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict -Color 'RED' -Banner 'COMPLETED WITH ERRORS' -Failures (@($long) + $many) -Notes @(1..6 | ForEach-Object { "Note $_" })) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    @($l | Where-Object { $_ -like '  X  *' -and $_ -notlike '*more*' }).Count | Should -Be 3
    @($l | Where-Object { $_ -like '  !  *' -and $_ -notlike '*more*' }).Count | Should -Be 2
    $l | Should -Contain '  X  ... and 7 more: see the report'
    $l | Should -Contain '  !  ... and 4 more: see the report'
    @($l | Where-Object { $_ -like '  X  *' -and $_.Length -gt 79 }).Count | Should -Be 0
  }
  It 'the worst-case final screen fits 29 lines (Review Focus 3)' {
    $st = New-FinalState; $st.AnyDeskId = '1234567890'
    $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict -Color 'RED' -Banner 'COMPLETED WITH ERRORS' -Failures @(1..20 | % { "Failure $_" }) -Notes @(1..20 | % { "Note $_" })) -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' -DefaultBrowserIsChrome $false -StickLine '  No BenTech USB stick - plug it in now to keep the logs')
    $l.Count | Should -BeLessOrEqual 29; $l[$l.Count - 2] | Should -Be '  No BenTech USB stick - plug it in now to keep the logs'
    $l[0] | Should -Be ('=' * 80)                                       # the frame and the banner are the first lines
    $l | Should -Contain "  Chrome is not the default browser: press B to open Default Apps, then click 'Set default'"
    $l[$l.Count - 1] | Should -Be '  Report: C:\BenTech\Setup\Logs\Setup-Report.txt   [R] open report   [ENTER] finish'
  }
  It 'cuts one very long failure to fit 79 columns' {
    $long = 'Windows Update: ' + ('y' * 200)
    $l = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict -Color 'RED' -Failures @($long) -Notes @()) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $line = @($l | Where-Object { $_ -like '  X  Windows Update:*' })
    $line.Count | Should -Be 1
    $line[0].Length | Should -Be 79
    $line[0] | Should -Match '\.\.\.$'
  }
  It 'is ASCII only, even when a failure message is not' {
    $l = Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict -Failures @('BitLocker: ' + [char]0x05D1 + [char]0x05E1)) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $false
    ($l -join "`n") -match '[^\x20-\x7E\r\n]' | Should -BeFalse
    $l | Should -Contain '  X  BitLocker: ??'
  }

  # ScreenConnect spec 4.1 and 4.4: the state's Choices.Remote decides (Get-RemoteChoice), never the plan list.
  It 'SCREENCONNECT alone: no AnyDesk line at all, the status on the New name line' {
    $st = New-FinalState; $st.Choices = @{ Remote = 'SCREENCONNECT' }; $st.Steps = @{ screenconnect = @{ Status = 'Done' } }
    $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $l | Should -Contain '  New name : DELL-7HX2K93     ScreenConnect: installed'
    @($l | Where-Object { $_ -match 'AnyDesk|#' }).Count | Should -Be 0
    $with = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $l.Count | Should -Be ($with.Count - 7)   # 'AnyDesk ID:', 5 digit rows and the blank after them
  }
  It 'NOT installed when the step failed or never ran' -ForEach @(@{ Steps = @{ screenconnect = @{ Status = 'Failed' } } }, @{ Steps = @{} }, @{ Steps = $null }) {
    $st = New-FinalState; $st.Choices = @{ Remote = 'SCREENCONNECT' }; $st.Steps = $Steps
    Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true | Should -Contain '  New name : DELL-7HX2K93     ScreenConnect: NOT installed'
  }
  It 'BOTH: the AnyDesk ID and the status; the worst case still fits 29 lines' {
    $st = New-FinalState; $st.AnyDeskId = '1234567890'; $st.Choices = @{ Remote = 'BOTH' }; $st.Steps = @{ screenconnect = @{ Status = 'Done' } }
    $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict -Color 'RED' -Banner 'COMPLETED WITH ERRORS' -Failures @(1..20 | % { "Failure $_" }) -Notes @(1..20 | % { "Note $_" })) -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' -DefaultBrowserIsChrome $false -StickLine '  No BenTech USB stick - plug it in now to keep the logs')
    $l.Count | Should -BeLessOrEqual 29; $l | Should -Contain '  AnyDesk ID:'; $l | Should -Contain '  New name : DELL-7HX2K93     ScreenConnect: installed'
  }
  It 'a 15 character new name (the longest) and ScreenConnect chosen: the New name line stays within 79 columns (<Remote>, <Status>)' -ForEach @(
    @{ Remote = 'SCREENCONNECT'; Status = 'Failed'; Tail = 'NOT installed' }, @{ Remote = 'BOTH'; Status = 'Failed'; Tail = 'NOT installed' }
    @{ Remote = 'SCREENCONNECT'; Status = 'Done'; Tail = 'installed' }
  ) {
    $st = New-FinalState; $st.Machine = @{} + $script:m; $st.Machine.NewName = 'ABCDEFGHIJKLMNO'
    $st.Choices = @{ Remote = $Remote }; $st.Steps = @{ screenconnect = @{ Status = $Status } }
    $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $line = @($l | Where-Object { $_ -like '  New name : *' })
    $line.Count | Should -Be 1
    $line[0] | Should -BeExactly ('  New name : ABCDEFGHIJKLMNO     ScreenConnect: ' + $Tail)
    $line[0].Length | Should -BeLessOrEqual 79
  }
  It 'ANYDESK, choices without Remote and an invalid Remote: the ID and no status (Review Focus 1)' -ForEach @(@{ Choices = @{ Remote = 'ANYDESK' } }, @{ Choices = @{ Mode = 'LAPTOP' } }, @{ Choices = @{ Remote = 'TEAMVIEWER' } }) {
    $st = New-FinalState; $st.Choices = $Choices; $l = @(Format-FinalScreen -State $st -Verdict (New-Verdict) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    $l | Should -Contain '  New name : DELL-7HX2K93'; $l | Should -Contain '  AnyDesk ID:'; ($l -join "`n") | Should -Not -Match 'ScreenConnect'
  }

  # Wu spec 3.3: in DRIVERS mode (Get-WindowsUpdateChoice of the state's Choices) the key line offers U, and
  # the U outcome sits on the blank spacer line, so no line is added.
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
}

Describe 'Show-FinalScreen' {
  BeforeEach {
    Mock Clear-Host { throw 'Clear-Host must not run in tests' }
    Mock Write-Host { throw 'Write-Host must not run in tests' }
    Mock Start-Process { throw 'Start-Process must not run in tests' }
    Mock Write-SetupLog { }
    Mock Test-ChromeInstalled { $true }
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    Mock Get-ChromeRegisteredAppName { 'Google Chrome' }
    $script:stick = @{ Root = 'E:\'; Drive = 'E:' }
    # A fake console writer for the tests of the production -Write (never the real [Console]).
    $script:fw = @{ Calls = New-Object System.Collections.ArrayList; Size = @{ Width = 100; Height = 30; Top = 0 } }
    $script:writer = @{ GetSize = { [pscustomobject]$script:fw.Size }; Clear = { param($b) [void]$script:fw.Calls.Add('clear'); $script:fw.ClearBack = $b }
      MoveTo = { param($row) [void]$script:fw.Calls.Add("row $row") }; Write = { param($t, $c, $b) [void]$script:fw.Calls.Add(@{ T = $t; C = $c; B = $b }) } }
    Reset-ConsoleFrame
    $script:finalState = @{ Machine = $m; AnyDeskId = '123456789'; RebootCount = 0; StartedAt = '2026-10-18T09:00:00'; EndedAt = '2026-10-18T09:10:00' }
  }
  It 'paints Black on Yellow, White on DarkGreen and White on DarkRed (spec 9.1)' {
    Invoke-FinalScreen -Color 'YELLOW'; $colors[0] | Should -Be 'Yellow'; $fores[0] | Should -Be 'Black'
    Invoke-FinalScreen -Color 'GREEN'; $colors[0] | Should -Be 'DarkGreen'; $fores[0] | Should -Be 'White'
    Invoke-FinalScreen -Color 'RED'; $colors[0] | Should -Be 'DarkRed'; $fores[0] | Should -Be 'White'
    $colors.Count | Should -Be 1
  }
  It 'paints an unexpected colour name white on red, never green' {
    Invoke-FinalScreen -Color 'PURPLE'; $colors[0] | Should -Be 'DarkRed'; $fores[0] | Should -Be 'White'
  }
  It 'Get-VerdictColors maps YELLOW, GREEN and everything else' {
    $y = Get-VerdictColors -Color 'YELLOW'; $y.Background | Should -Be 'Yellow'; $y.Foreground | Should -Be 'Black'
    $g = Get-VerdictColors -Color 'GREEN'; $g.Background | Should -Be 'DarkGreen'; $g.Foreground | Should -Be 'White'
    foreach ($other in 'RED', 'PURPLE', '', $null) {
      $r = Get-VerdictColors -Color $other; $r.Background | Should -Be 'DarkRed'; $r.Foreground | Should -Be 'White'
    }
  }
  It 'the production writer draws through the console writer in the verdict colours' {
    Mock New-ConsoleWriter { $script:writer }
    Reset-FakeClock
    Show-FinalScreen -State $finalState -Verdict @{ Color = 'YELLOW'; Banner = 'COMPLETE - CHECK NOTES'; Failures = @(); Notes = @('n') } -ReportPath 'C:\r.txt' `
      -ReadKey { 'Enter' } -Stick { $script:stick } -Now { $script:clock } -Sleep { param($ms) } -SetColor { param($b, $f) } -ResetColor { } -FlushInput { } -Launch { param($t, $a) }
    $w = @($fw.Calls | Where-Object { $_ -is [hashtable] })
    $w.Count | Should -BeGreaterThan 10
    @($w | Where-Object { $_.C -ne 'Black' -or $_.B -ne 'Yellow' }).Count | Should -Be 0
    @($w | Where-Object { $_.T -like '  USB stick found (E:)*' }).Count | Should -Be 1
    Should -Invoke Write-Host -Times 0 -Exactly
    Should -Invoke Clear-Host -Times 0 -Exactly
  }
  It 'the production writer clears the whole window once in the verdict colour, also after a progress frame of the same size' {
    Write-ConsoleFrame -Lines @('  progress') -Writer $writer   # the last progress frame, on Black
    Mock New-ConsoleWriter { $script:writer }
    Reset-FakeClock
    Show-FinalScreen -State $finalState -Verdict @{ Color = 'GREEN'; Banner = 'SETUP COMPLETE'; Failures = @(); Notes = @() } -ReportPath 'C:\r.txt' `
      -ReadKey { if ((Get-ElapsedSeconds) -ge 2) { 'Enter' } } -Stick { $script:stick } -Now { $script:clock } -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds($ms) } `
      -SetColor { param($b, $f) } -ResetColor { } -FlushInput { } -Launch { param($t, $a) }
    @($fw.Calls | Where-Object { $_ -eq 'clear' }).Count | Should -Be 2   # the progress frame's, then the final screen's first frame only
    $fw.ClearBack | Should -Be 'DarkGreen'
    @($fw.Calls | Where-Object { $_ -is [hashtable] -and $_.T -match 'SETUP COMPLETE' }).Count | Should -Be 3   # drawn at 0, 1 and 2 s
  }
  It 'the production colour setter sets both the background and the foreground of the console' {
    # $Host cannot be replaced, so read the -SetColor default out of the param block.
    $param = (Get-Command Show-FinalScreen).ScriptBlock.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SetColor' }
    $text = $param.DefaultValue.Extent.Text
    $text | Should -Match 'param\(\$background, \$foreground\)'
    $text | Should -Match 'RawUI\.BackgroundColor = \$background'
    $text | Should -Match 'RawUI\.ForegroundColor = \$foreground'
  }
  It 'the production key reader never blocks: it reads only a waiting key' {
    $param = (Get-Command Show-FinalScreen).ScriptBlock.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ReadKey' }
    $param.DefaultValue.Extent.Text | Should -Match 'if \(\[Console\]::KeyAvailable\) \{ \[Console\]::ReadKey\(\$true\)\.Key\.ToString\(\) \}'
  }
  It 'puts the console colours back last, when the screen closes' {
    Invoke-FinalScreen -Keys 'R', 'Enter'
    @($events | Where-Object { $_ -eq 'reset' }).Count | Should -Be 1
    $events[$events.Count - 1] | Should -Be 'reset'
  }
  It 'paints the colour before the first draw' {
    Invoke-FinalScreen
    $drawn.Count | Should -Be 1
    $drawn[0] | Should -Match 'COMPLETE - CHECK NOTES'
    $events.IndexOf('color') | Should -BeLessThan $events.IndexOf('write')
  }
  It 'shows the default-browser hint when Chrome is installed but not the default' {
    Invoke-FinalScreen
    $drawn[0] | Should -Match "press B to open Default Apps, then click 'Set default'"
  }
  It 'shows no hint when Chrome is the default browser' {
    Mock Get-DefaultBrowserProgId { 'ChromeHTML' }
    Invoke-FinalScreen
    $drawn[0] | Should -Not -Match 'press B'
  }
  It 'shows no hint, and never asks for the default browser, when Chrome is not installed' {
    Mock Test-ChromeInstalled { $false }
    Invoke-FinalScreen
    $drawn[0] | Should -Not -Match 'press B'
    Should -Invoke Get-DefaultBrowserProgId -Times 0 -Exactly
  }
  It 'treats an unknown default browser as not Chrome' {
    Mock Get-DefaultBrowserProgId { $null }
    Invoke-FinalScreen
    $drawn[0] | Should -Match 'press B'
  }
  It 'B opens Default Apps for Chrome with the registered name URL-encoded, then keeps waiting' {
    Invoke-FinalScreen -Keys 'B', 'Enter'
    $launched.Count | Should -Be 1
    $launched[0].Target | Should -Be 'ms-settings:defaultapps?registeredAppMachine=Google%20Chrome'
    @($events | Where-Object { $_ -eq 'read' }).Count | Should -Be 2
    $drawn.Count | Should -Be 1
  }
  It 'R opens the report in notepad with the path quoted, then keeps waiting' {
    Invoke-FinalScreen -Keys 'R', 'Enter'
    $launched.Count | Should -Be 1
    $launched[0].Target | Should -Be 'notepad.exe'
    $launched[0].Arguments | Should -Be '"C:\BenTech\Setup\Logs\Setup-Report.txt"'
  }
  It 'B and R can be used in any order and any number of times' {
    Invoke-FinalScreen -Keys 'R', 'B', 'R', 'Enter'
    @($launched | ForEach-Object { $_.Target }) | Should -Be @('notepad.exe', 'ms-settings:defaultapps?registeredAppMachine=Google%20Chrome', 'notepad.exe')
  }
  It 'only Enter finishes; every other key is ignored' { Invoke-FinalScreen -Keys 'Escape', 'Spacebar', 'X', 'Q', 'Enter'; $launched.Count | Should -Be 0; @($events | Where-Object { $_ -eq 'read' }).Count | Should -BeGreaterOrEqual 5 }
  It 'keeps waiting while no key comes, and never returns by itself' {
    { Invoke-FinalScreen -Keys @() } | Should -Throw '*runaway: no Enter*'
    @($events | Where-Object { $_ -eq 'reset' }).Count | Should -Be 1
  }
  It 'empties the key buffer after drawing and before it waits, so a stray key cannot close the screen' {
    Invoke-FinalScreen
    $events.IndexOf('write') | Should -BeLessThan $events.IndexOf('flush')
    $events.IndexOf('flush') | Should -BeLessThan $events.IndexOf('read')
  }
  It 'shows the stick line live: a stick plugged in while waiting appears within a second' {
    $script:stick = @{ Root = $null }; $script:plugAt = 3
    Invoke-FinalScreen -Stick { if ((Get-ElapsedSeconds) -ge $script:plugAt) { @{ Root = 'F:\'; Drive = 'F:' } } else { @{ Root = $null } } } -KeyAt { param($s) if ($s -ge 5) { 'Enter' } }
    $drawn[0] | Should -Match 'No BenTech USB stick'; $drawn[$drawn.Count - 1] | Should -Match 'USB stick found \(F:\)'
    $drawn.Count | Should -Be 6                      # one redraw a second: 0, 1, 2, 3, 4 and 5 s
    $drawn[2] | Should -Match 'No BenTech USB stick'; $drawn[3] | Should -Match 'USB stick found \(F:\)'
  }
  It 'a stick check that throws shows "no stick" and keeps going' {
    Invoke-FinalScreen -Stick { throw 'WMI down' } -KeyAt { param($s) if ($s -ge 3) { 'Enter' } }
    $drawn[0] | Should -Match 'No BenTech USB stick'
    $drawn.Count | Should -Be 4
    @($drawn | Where-Object { $_ -match 'No BenTech USB stick' }).Count | Should -Be 4
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Data.error -eq 'WMI down' }
  }
  It 'the default stick reader looks for the launcher recorded in the state' {
    Mock Find-SetupStick { @{ Root = 'G:\'; Drive = 'G:' } }
    $script:drawn = New-Object System.Collections.ArrayList
    $st = $finalState.Clone(); $st.Launcher = @{ Path = 'E:\BenTechSetup.cmd'; Drive = 'E:'; VolumeSerial = '1A2B3C4D' }
    Show-FinalScreen -State $st -Verdict @{ Color = 'GREEN'; Banner = 'SETUP COMPLETE'; Failures = @(); Notes = @() } -ReportPath 'C:\r.txt' `
      -ReadKey { 'Enter' } -Now { [datetime]'2026-10-18T09:00:00' } -Sleep { param($ms) } -SetColor { param($b, $f) } -ResetColor { } `
      -Write { param($lines) $null = $script:drawn.Add(($lines -join "`n")) } -FlushInput { } -Launch { param($t, $a) }
    $drawn[0] | Should -Match 'USB stick found \(G:\)'
    Should -Invoke Find-SetupStick -Times 1 -Exactly -ParameterFilter { $Launcher.VolumeSerial -eq '1A2B3C4D' }
  }
  It 'a draw that fails (the window resized mid-frame) is logged once, and the next second draws again' {
    $script:failDraws = 2
    $script:drawn = New-Object System.Collections.ArrayList
    Reset-FakeClock
    Show-FinalScreen -State $finalState -Verdict @{ Color = 'GREEN'; Banner = 'SETUP COMPLETE'; Failures = @(); Notes = @() } -ReportPath 'C:\r.txt' `
      -ReadKey { if ((Get-ElapsedSeconds) -ge 3) { 'Enter' } } -Stick { $script:stick } -Now { $script:clock } -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds($ms) } `
      -SetColor { param($b, $f) } -ResetColor { } -FlushInput { } -Launch { param($t, $a) } `
      -Write { param($lines) if ($script:failDraws -gt 0) { $script:failDraws--; throw 'The cursor position cannot be smaller than zero' }; $null = $script:drawn.Add(($lines -join "`n")) }
    $drawn.Count | Should -Be 2                      # 0 and 1 s failed, 2 and 3 s drew
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'draw' }
  }
  It 'restores the console colour even when the key read throws' {
    $script:colors = New-Object System.Collections.ArrayList
    $script:fores = New-Object System.Collections.ArrayList
    $script:resets = 0
    {
      Show-FinalScreen -State $finalState `
        -Verdict @{ Color = 'RED'; Banner = 'COMPLETED WITH ERRORS'; Failures = @('F'); Notes = @() } -ReportPath 'C:\r.txt' `
        -ReadKey { throw 'console went away' } -SetColor { param($b, $f) $null = $script:colors.Add($b); $null = $script:fores.Add($f) } -ResetColor { $script:resets++ } `
        -Stick { $script:stick } -Now { [datetime]'2026-10-18T09:00:00' } -Sleep { param($ms) } `
        -Write { param($lines) } -FlushInput { } -Launch { param($t, $a) }
    } | Should -Throw '*console went away*'
    $colors.Count | Should -Be 1
    $colors[0] | Should -Be 'DarkRed'
    $fores[0] | Should -Be 'White'
    $resets | Should -Be 1
  }
  It 'survives a launch failure and keeps waiting' {
    Invoke-FinalScreen -Keys 'R', 'B', 'Enter' -Launch { param($t, $a) throw 'no notepad here' }
    $launched.Count | Should -Be 2
    @($events | Where-Object { $_ -eq 'read' }).Count | Should -Be 3
  }
  It 'survives a colour change that fails and still draws the screen' {
    $script:drawn = New-Object System.Collections.ArrayList
    Show-FinalScreen -State $finalState `
      -Verdict @{ Color = 'GREEN'; Banner = 'SETUP COMPLETE'; Failures = @(); Notes = @() } -ReportPath 'C:\r.txt' `
      -ReadKey { 'Enter' } -SetColor { param($b, $f) throw 'cannot set colour' } -ResetColor { throw 'cannot reset colour' } `
      -Stick { $script:stick } -Now { [datetime]'2026-10-18T09:00:00' } -Sleep { param($ms) } `
      -Write { param($lines) $null = $script:drawn.Add(($lines -join "`n")) } -FlushInput { throw 'cannot flush' } -Launch { param($t, $a) }
    $drawn.Count | Should -Be 1
    $drawn[0] | Should -Match 'SETUP COMPLETE'
  }

  # Wu spec 3.3: U, in DRIVERS mode only, hands Windows Update to Windows through the -Launch seam.
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
  # Final wave 8 (Task 3 M2): the same, by behaviour, through the production -Launch default. Start-Process is
  # mocked to fail the way a refused start does (a non-terminating error, CLAUDE.md), so nothing is ever opened.
  It 'a refused start through the production launcher reaches the could-not line for U and the WARN for R (mocked Start-Process; Task 3 M2)' {
    Mock Start-Process { Write-Error 'refused by the test' }
    $script:drawn = New-Object System.Collections.ArrayList; $script:keyQueue = New-Object System.Collections.Queue; foreach ($k in 'R', 'U', 'Enter') { $script:keyQueue.Enqueue($k) }
    Show-FinalScreen -State ($finalState + @{ Choices = @{ WindowsUpdate = 'DRIVERS' } }) -Verdict @{ Color = 'GREEN'; Banner = 'SETUP COMPLETE'; Failures = @(); Notes = @() } -ReportPath 'C:\r.txt' `
      -ReadKey { if ($script:keyQueue.Count -gt 0) { $script:keyQueue.Dequeue() } } -Stick { $script:stick } -Now { [datetime]'2026-10-18T09:00:00' } -Sleep { param($ms) } `
      -SetColor { param($b, $f) } -ResetColor { } -FlushInput { } -Write { param($lines) $null = $script:drawn.Add(($lines -join "`n")) }
    Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'ms-settings:windowsupdate-action' }
    Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'notepad.exe' }
    $drawn[$drawn.Count - 1] | Should -Match 'Could not open Windows Update: open Settings > Windows Update'
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq 'Could not open Windows Update from the final screen' -and $Data.error -match 'refused by the test' }
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq 'Could not open the report from the final screen' -and $Data.error -match 'refused by the test' }
    Should -Invoke Write-SetupLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Windows Update handed to Windows' } }
  # Final wave 8 (Task 3 M3): every U opens Settings again and the line shows the last outcome; Enter ends the
  # screen at once (Main.ps1 then runs the cleanup once, Entry.Tests), so a key after Enter is never read.
  It 'U twice opens Settings twice and the line shows the last outcome; the first Enter ends the screen (<Last>; Task 3 M3)' -ForEach @(
    @{ FailOn = 2; Last = 'Could not open Windows Update: open Settings > Windows Update' }
    @{ FailOn = 1; Last = 'Windows Update started: Windows will finish on its own' }) {
    $script:failOn = $FailOn
    Invoke-FinalScreen -Keys 'U', 'U', 'Enter', 'U' -Choices @{ WindowsUpdate = 'DRIVERS' } -Launch { param($t, $a) if ($script:launched.Count -eq $script:failOn) { throw 'refused once' } }
    $launched.Count | Should -Be 2; $script:keyQueue.Count | Should -Be 1     # the U after Enter was never read
    $drawn.Count | Should -Be 3; $drawn[2] | Should -Match ([regex]::Escape($Last))
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Windows Update handed to Windows' }
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq 'Could not open Windows Update from the final screen' } }
  # Final wave 1 (final review M1, Task 3 M1): the B/R WARN goes through ConvertTo-ScreenText like U's.
  It 'a B or R that cannot start logs the error text as ASCII' {
    Invoke-FinalScreen -Keys 'R', 'Enter' -Launch { param($t, $a) throw ('no notepad ' + $script:Hebrew) }
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq 'Could not open the report from the final screen' -and $Data.error -ceq 'no notepad ?????' } }
  # Pre-PR code review: the launch and its WARN exist once ($open); U reads $open's answer instead of its own try/catch.
  It 'B, R and U all launch through one place, with one could-not WARN (code review)' {
    $statements = (Get-Command Show-FinalScreen).ScriptBlock.Ast.Body.EndBlock.Statements
    $code = ($statements | ForEach-Object { $_.Extent.Text }) -join "`n"
    ([regex]::Matches($code, '&\s*\$Launch\b')).Count | Should -Be 1
    ([regex]::Matches($code, 'Could not open')).Count | Should -Be 1 }
  It 'B, R and U return nothing to the caller, whether the launch works or not (code review)' -ForEach @(
    @{ Why = 'works'; L = $null }, @{ Why = 'fails'; L = { param($t, $a) throw 'refused' } }) {
    @(Invoke-FinalScreen -Keys 'B', 'R', 'U', 'Enter' -Choices @{ WindowsUpdate = 'DRIVERS' } -Launch $L).Count | Should -Be 0
    $launched.Count | Should -Be 3 }
}
