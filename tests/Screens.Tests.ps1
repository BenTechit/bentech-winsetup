# tests/Screens.Tests.ps1
# Task 15: start, progress and final screens.
#
# SAFETY: these are console screens. Nothing here may touch the real console, read a real key, change
# the console colour or start a process. Every Show-* call passes all of its seams (-ReadKey, -Now,
# -Sleep, -OnAC, -Write, -SetColor, -Launch, -FlushInput), and BeforeEach also replaces Clear-Host,
# Write-Host and Start-Process with commands that throw, so a forgotten seam fails loudly.
BeforeAll {
  foreach ($f in 'StartScreen','ProgressScreen','FinalScreen') { . "$PSScriptRoot\..\src\UI\$f.ps1" }
  # The real commands the screens call in production, so Pester can mock them.
  . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Config.ps1"
  . "$PSScriptRoot\..\src\Engine\Catalog.ps1"; . "$PSScriptRoot\..\src\Engine\Verdict.ps1"
  . "$PSScriptRoot\..\src\Detect\Detection.ps1"
  . "$PSScriptRoot\..\src\Steps\Apps.ps1"; . "$PSScriptRoot\..\src\Steps\DefaultBrowser.ps1"
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:m = @{ Manufacturer='Dell Inc.'; FriendlyModel='Latitude 5440'; Serial='7HX2K93'; IsLaptop=$true; IsVM=$false; OsCaption='Windows 11 Pro'; OsDisplayVersion='25H2'; OsBuild=26200; Arch='x64'; NewName='DELL-7HX2K93' }

  # A fake clock: Sleep moves it forward, Now reads it. Show-StartScreen never waits for real time.
  function Reset-FakeClock { $script:clock = [datetime]'2026-10-18T09:00:00'; $script:t0 = $script:clock }
  function Get-ElapsedSeconds { ($script:clock - $script:t0).TotalSeconds }

  # Runs Show-StartScreen against the fake clock. -KeyAt is a scriptblock that gets the elapsed
  # seconds and returns a key name (or nothing). Records every drawn screen in $script:screens.
  function Invoke-StartScreen {
    param([hashtable]$Machine = $script:m, [bool]$IsFresh = $true, [scriptblock]$KeyAt = { param($s) }, [scriptblock]$OnAC = { $true }, $Previous = $null)
    Reset-FakeClock
    $script:screens = New-Object System.Collections.ArrayList
    $script:keyAt = $KeyAt
    $script:readCalls = 0
    Show-StartScreen -Machine $Machine -Config $script:cfg -Version '2026.10.18.1' -Previous $Previous -IsFresh $IsFresh `
      -ReadKey { $script:readCalls++; if ($script:readCalls -gt 5000) { throw 'runaway loop: the fake clock stopped advancing' }; & $script:keyAt (Get-ElapsedSeconds) } `
      -Now { $script:clock } `
      -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds($ms) } `
      -OnAC $OnAC `
      -Write { param($lines) $null = $script:screens.Add(($lines -join "`n")) }
  }

  # Runs Show-FinalScreen with a scripted key sequence. Records colours, drawn screens, launches
  # and the order of flush/read events.
  function Invoke-FinalScreen {
    param([string[]]$Keys = @('Q'), [string]$Color = 'YELLOW', [string[]]$Failures = @(), [string[]]$Notes = @('x'), [scriptblock]$Launch = $null)
    $script:keyQueue = New-Object System.Collections.Queue
    foreach ($k in $Keys) { $script:keyQueue.Enqueue($k) }
    $script:colors = New-Object System.Collections.ArrayList
    $script:drawn = New-Object System.Collections.ArrayList
    $script:launched = New-Object System.Collections.ArrayList
    $script:events = New-Object System.Collections.ArrayList
    $script:launchBody = $Launch
    $st = @{ Machine = $script:m; AnyDeskId = '123456789'; RebootCount = 2; StartedAt = '2026-10-18T09:00:00'; EndedAt = '2026-10-18T10:12:00' }
    $verdict = @{ Color = $Color; Banner = 'COMPLETE - CHECK NOTES'; Failures = $Failures; Notes = $Notes }
    Show-FinalScreen -State $st -Verdict $verdict -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' `
      -ReadKey { $null = $script:events.Add('read'); if ($script:keyQueue.Count -gt 0) { $script:keyQueue.Dequeue() } } `
      -SetColor { param($c) $null = $script:events.Add('color'); $null = $script:colors.Add($c) } `
      -Write { param($lines) $null = $script:events.Add('write'); $null = $script:drawn.Add(($lines -join "`n")) } `
      -ResetColor { $null = $script:events.Add('reset') } `
      -FlushInput { $null = $script:events.Add('flush') } `
      -Launch { param($target, $arguments) $null = $script:launched.Add(@{ Target = $target; Arguments = $arguments }); if ($script:launchBody) { & $script:launchBody $target $arguments } }
  }
}

Describe 'Update-StartChoices' {
  BeforeEach { $script:c = @{ Mode='LAPTOP'; SevenZip=$true; Office='OFF' } }
  It 'O cycles OFF -> BUSINESS -> HOME -> OFF' { $r = Update-StartChoices -Choices $c -Key 'O'; $r.Choices.Office | Should -Be 'BUSINESS'; $r = Update-StartChoices -Choices $r.Choices -Key 'o'; $r.Choices.Office | Should -Be 'HOME'; (Update-StartChoices -Choices $r.Choices -Key 'O').Choices.Office | Should -Be 'OFF' }
  It 'Z toggles and resets the countdown' { $r = Update-StartChoices -Choices $c -Key 'Z'; $r.Choices.SevenZip | Should -BeFalse; $r.ResetCountdown | Should -BeTrue }
  It 'D switches to desktop' { (Update-StartChoices -Choices $c -Key 'D').Choices.Mode | Should -Be 'DESKTOP' }
  It 'Enter starts, Esc cancels, X does nothing' { (Update-StartChoices -Choices $c -Key 'Enter').Action | Should -Be 'Start'; (Update-StartChoices -Choices $c -Key 'Escape').Action | Should -Be 'Cancel'; $r = Update-StartChoices -Choices $c -Key 'X'; $r.Action | Should -Be 'None'; $r.ResetCountdown | Should -BeFalse }
  It 'L switches to laptop, case-insensitively, and resets the countdown' {
    $desktop = @{ Mode='DESKTOP'; SevenZip=$true; Office='OFF' }
    $r = Update-StartChoices -Choices $desktop -Key 'l'
    $r.Choices.Mode | Should -Be 'LAPTOP'; $r.ResetCountdown | Should -BeTrue; $r.Action | Should -Be 'None'
  }
  It 'every toggle key resets the countdown, Enter and Escape do not' {
    foreach ($k in 'L','D','Z','O') { (Update-StartChoices -Choices $c -Key $k).ResetCountdown | Should -BeTrue }
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
  }
}

Describe 'New-DefaultChoices' {
  It 'picks LAPTOP for a laptop and takes 7-Zip and Office from the config defaults' {
    $r = New-DefaultChoices -Machine $m -Config $cfg
    $r.Mode | Should -Be 'LAPTOP'; $r.SevenZip | Should -BeTrue; $r.Office | Should -Be 'BUSINESS'
  }
  It 'picks DESKTOP for a desktop' {
    (New-DefaultChoices -Machine @{ IsLaptop = $false; IsVM = $false } -Config $cfg).Mode | Should -Be 'DESKTOP'
  }
  It 'picks DESKTOP for a laptop-looking virtual machine' {
    (New-DefaultChoices -Machine @{ IsLaptop = $true; IsVM = $true } -Config $cfg).Mode | Should -Be 'DESKTOP'
  }
  It 'follows the config defaults and falls back to OFF for an unknown Office value' {
    $off = [pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $false; office = 'home' } }
    $r = New-DefaultChoices -Machine $m -Config $off
    $r.SevenZip | Should -BeFalse; $r.Office | Should -Be 'HOME'
    $bad = [pscustomobject]@{ defaults = [pscustomobject]@{ sevenZip = $true; office = 'PLATINUM' } }
    (New-DefaultChoices -Machine $m -Config $bad).Office | Should -Be 'OFF'
  }
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
  It 'marks DESKTOP mode, 7-Zip OFF and the full countdown line' {
    $l = Format-StartScreen -Machine $m -Choices @{Mode='DESKTOP';SevenZip=$false;Office='HOME'} -SecondsLeft 10 -Version '2026.10.18.1' -OnAC $true -IsFresh $true -Previous $null
    $l | Should -Contain '   MODE   [L] Laptop           [D] Desktop  <=='
    $l | Should -Contain '          [Z] 7-Zip                OFF'
    $l | Should -Contain '          [O] Office 365 (HE+EN)   HOME   (OFF/BUSINESS/HOME)'
    $l | Should -Contain '   Starting in 10s ...  [Enter] start now   [Esc] cancel'
    $l | Should -Contain '   (any toggle resets the countdown to 10s)'
  }
  It 'prints the not-fresh line exactly and drops the countdown hint' {
    $l = Format-StartScreen -Machine $m -Choices @{Mode='LAPTOP';SevenZip=$true;Office='OFF'} -SecondsLeft 10 -Version 'v1' -OnAC $true -IsFresh $false -Previous $null
    $l | Should -Contain "   This doesn't look like a fresh install: press Enter to run anyway"
    ($l -join "`n") | Should -Not -Match 'toggle resets'
  }
  It 'prints the machine header lines' {
    $l = Format-StartScreen -Machine $m -Choices @{Mode='LAPTOP';SevenZip=$true;Office='OFF'} -SecondsLeft 10 -Version '2026.10.18.1' -OnAC $true -IsFresh $true -Previous $null
    $l | Should -Contain '   BENTECH WINDOWS SETUP                    v2026.10.18.1'
    $l | Should -Contain '   Machine  : Dell Inc.  Latitude 5440        SN: 7HX2K93'
    $l | Should -Contain '   Detected : LAPTOP'
    $l | Should -Contain '   Windows  : Windows 11 Pro 25H2 (26200)   x64'
    $l | Should -Contain '   Power    : ON CHARGER'
    $l | Should -Contain '   New name : DELL-7HX2K93'
    $l | Should -Contain '   APPS   Chrome, AnyDesk          always'
  }
  It 'does not double the v when the version already starts with one' {
    $l = Format-StartScreen -Machine $m -Choices @{Mode='LAPTOP';SevenZip=$true;Office='OFF'} -SecondsLeft 10 -Version 'v1' -OnAC $true -IsFresh $true -Previous $null
    $l | Should -Contain '   BENTECH WINDOWS SETUP                    v1'
  }
  It 'says ON BATTERY on the Power line and DESKTOP / VM in Detected' {
    $desk = $m.Clone(); $desk.IsLaptop = $false
    $l = Format-StartScreen -Machine $desk -Choices @{Mode='DESKTOP';SevenZip=$true;Office='OFF'} -SecondsLeft 10 -Version 'v1' -OnAC $false -IsFresh $true -Previous $null
    $l | Should -Contain '   Power    : ON BATTERY'; $l | Should -Contain '   Detected : DESKTOP'
    $vm = $m.Clone(); $vm.IsVM = $true
    (Format-StartScreen -Machine $vm -Choices @{Mode='DESKTOP';SevenZip=$true;Office='OFF'} -SecondsLeft 10 -Version 'v1' -OnAC $true -IsFresh $true -Previous $null) | Should -Contain '   Detected : VM'
  }
  It 'shows the previous run as dd/MM/yyyy HH:mm - Color, from a string or a datetime' {
    $c = @{Mode='LAPTOP';SevenZip=$true;Office='OFF'}
    $l = Format-StartScreen -Machine $m -Choices $c -SecondsLeft 10 -Version 'v1' -OnAC $true -IsFresh $true -Previous @{ StartedAt = '2026-10-17T14:05:09'; Color = 'RED' }
    $l | Should -Contain '   Previous run: 17/10/2026 14:05 - RED'
    $l = Format-StartScreen -Machine $m -Choices $c -SecondsLeft 10 -Version 'v1' -OnAC $true -IsFresh $true -Previous @{ StartedAt = [datetime]'2026-01-02T03:04:05'; Color = 'GREEN' }
    $l | Should -Contain '   Previous run: 02/01/2026 03:04 - GREEN'
    @($l | Where-Object { $_ -like '*Previous run*' }).Count | Should -Be 1
  }
  It 'has no previous-run line without a previous run' {
    $l = Format-StartScreen -Machine $m -Choices @{Mode='LAPTOP';SevenZip=$true;Office='OFF'} -SecondsLeft 10 -Version 'v1' -OnAC $true -IsFresh $true -Previous $null
    ($l -join "`n") | Should -Not -Match 'Previous run'
  }
  It 'is ASCII only, even when the machine fields are not' {
    $odd = $m.Clone(); $odd.FriendlyModel = 'Latitude 5440 ' + [char]0x05D1 + [char]0x2122; $odd.Manufacturer = "Dell`r`nInc."
    $l = Format-StartScreen -Machine $odd -Choices @{Mode='LAPTOP';SevenZip=$true;Office='OFF'} -SecondsLeft 10 -Version 'v1' -OnAC $false -IsFresh $false -Previous @{ StartedAt = '2026-10-17T14:05:09'; Color = 'RED' }
    ($l -join "`n") -match '[^\x20-\x7E\r\n]' | Should -BeFalse
    $l | Should -Contain '   Machine  : Dell Inc.  Latitude 5440 ??        SN: 7HX2K93'
    $l.Count | Should -BeGreaterThan 10
    @($l | Where-Object { $_ -match "[`r`n]" }).Count | Should -Be 0
  }
}

Describe 'Show-StartScreen' {
  # Safety net: this must only reach the console through its seams.
  BeforeEach {
    Mock Clear-Host { throw 'Clear-Host must not run in tests' }
    Mock Write-Host { throw 'Write-Host must not run in tests' }
    Mock Start-Process { throw 'Start-Process must not run in tests' }
  }
  It 'counts down from 10 and starts at 0 with the default choices' {
    $r = Invoke-StartScreen
    $r.Mode | Should -Be 'LAPTOP'; $r.SevenZip | Should -BeTrue; $r.Office | Should -Be 'BUSINESS'
    Get-ElapsedSeconds | Should -Be 10
    # One redraw per second: the first screen and then 9 ticks (10s down to 1s), nothing at 0.
    $screens.Count | Should -Be 10
    $screens[0] | Should -Match 'Starting in 10s'
    $screens[9] | Should -Match 'Starting in 1s'
    $screens[5] | Should -Match 'Starting in 5s'
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
  It 'a toggle resets the countdown to 10 and is part of the result' {
    $script:zSent = $false
    $r = Invoke-StartScreen -KeyAt { param($s) if (-not $script:zSent -and $s -ge 4) { $script:zSent = $true; 'Z' } }
    $r.SevenZip | Should -BeFalse
    # Seven ticks happened before the toggle, so a reset run lasts 4s + 10s.
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 14
    Get-ElapsedSeconds | Should -BeLessThan 14.5
    $toggleScreen = @($screens | Where-Object { $_ -match '\[Z\] 7-Zip\s+OFF' })[0]
    $toggleScreen | Should -Match 'Starting in 10s'
    # The screen just before the toggle was at 6s.
    $screens[$screens.IndexOf($toggleScreen) - 1] | Should -Match 'Starting in 6s'
  }
  It 'the L, D and O toggles change the returned choices' {
    $script:sent = New-Object System.Collections.Queue
    foreach ($k in 'D','O','O','L') { $script:sent.Enqueue($k) }
    $r = Invoke-StartScreen -KeyAt { param($s) if ($script:sent.Count -gt 0) { $script:sent.Dequeue() } }
    $r.Mode | Should -Be 'LAPTOP'; $r.Office | Should -Be 'OFF'   # BUSINESS -> HOME -> OFF
  }
  It 'never starts by itself when the machine is not fresh' {
    $r = Invoke-StartScreen -IsFresh $false -KeyAt { param($s) if ($s -ge 30) { 'Escape' } }
    $r | Should -BeNullOrEmpty
    Get-ElapsedSeconds | Should -BeGreaterOrEqual 30
    $screens.Count | Should -BeGreaterOrEqual 30
    @($screens | Where-Object { $_ -match 'Starting in' }).Count | Should -Be 0
    @($screens | Where-Object { $_ -match "press Enter to run anyway" }).Count | Should -Be $screens.Count
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
    $screens[4] | Should -Match 'Power    : ON BATTERY'
    $screens[9] | Should -Match 'ON BATTERY'
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
      -Now { $script:t0 } -Sleep { param($ms) } -OnAC { $true } -Write { param($lines) $null = $script:screens.Add(($lines -join "`n")) }
    $r | Should -Not -BeNullOrEmpty
    $screens.Count | Should -Be 10
  }
  It 'still counts down when the clock jumps backwards' {
    Reset-FakeClock
    $script:readCalls = 0
    $script:screens = New-Object System.Collections.ArrayList
    $r = Show-StartScreen -Machine $m -Config $cfg -Version 'v1' -Previous $null -IsFresh $true `
      -ReadKey { $script:readCalls++; if ($script:readCalls -gt 5000) { throw 'runaway loop' } } `
      -Now { $script:clock } -Sleep { param($ms) $script:clock = $script:clock.AddMilliseconds(-$ms) } -OnAC { $true } `
      -Write { param($lines) $null = $script:screens.Add(($lines -join "`n")) }
    $r | Should -Not -BeNullOrEmpty
    $screens.Count | Should -Be 10
  }
  It 'the production writer clears the screen, writes every line (blank ones too) and paints the warnings yellow' {
    $script:cleared = 0
    $script:hostCalls = New-Object System.Collections.ArrayList
    Mock Clear-Host { $script:cleared++ }
    Mock Write-Host { $null = $script:hostCalls.Add(@{ Text = [string]$Object; Color = $ForegroundColor }) }
    Write-StartScreenLines -Lines @('   MODE', '', '   ON BATTERY: plug in the charger. BIOS updates will be skipped if still on battery.', "   This doesn't look like a fresh install: press Enter to run anyway")
    $cleared | Should -Be 1
    $hostCalls.Count | Should -Be 4
    $hostCalls[1].Text | Should -Be ''
    $hostCalls[0].Color | Should -BeNullOrEmpty
    $hostCalls[2].Color | Should -Be 'Yellow'
    $hostCalls[3].Color | Should -Be 'Yellow'
  }
  It 'draws through the production writer when no -Write seam is given' {
    $script:cleared = 0
    $script:hostCalls = New-Object System.Collections.ArrayList
    Mock Clear-Host { $script:cleared++ }
    Mock Write-Host { $null = $script:hostCalls.Add(@{ Text = [string]$Object; Color = $ForegroundColor }) }
    Reset-FakeClock
    $r = Show-StartScreen -Machine $m -Config $cfg -Version '2026.10.18.1' -Previous $null -IsFresh $true `
      -ReadKey { 'Enter' } -Now { $script:clock } -Sleep { param($ms) } -OnAC { $true }
    $r | Should -Not -BeNullOrEmpty
    $cleared | Should -Be 1
    ($hostCalls | ForEach-Object { $_.Text }) | Should -Contain '   Starting in 10s ...  [Enter] start now   [Esc] cancel'
  }
  It 'keeps going when the power reader throws' {
    $r = Invoke-StartScreen -OnAC { throw 'WMI is unhappy' }
    $r | Should -Not -BeNullOrEmpty
    $screens[9] | Should -Not -Match 'ON BATTERY'
  }
}

Describe 'Format-ProgressScreen' {
  BeforeAll {
    $script:cat = @(
      @{ Id = 'prepare';  Title = 'Prepare machine';   Function = 'Invoke-StepPrepare' }
      @{ Id = 'bitlocker'; Title = 'Turn off BitLocker'; Function = 'Invoke-StepBitLocker' }
      @{ Id = 'chrome';   Title = 'Google Chrome';     Function = 'Invoke-StepChrome' }
      @{ Id = 'anydesk';  Title = 'AnyDesk';           Function = 'Invoke-StepAnyDesk' }
      @{ Id = '7zip';     Title = '7-Zip';             Function = 'Invoke-StepSevenZip' }
      @{ Id = 'office';   Title = 'Microsoft 365';     Function = 'Invoke-StepOffice' }
    )
    function New-ProgressState {
      @{
        StartedAt = '2026-10-18T09:00:00'; RebootCount = 2
        Plan = @('prepare', 'bitlocker', 'chrome', 'anydesk', '7zip', 'office')
        Steps = @{
          'prepare'   = @{ Status = 'Done';    Message = 'ok';                  StartedAt = '2026-10-18T09:00:01' }
          'bitlocker' = @{ Status = 'Skipped'; Message = 'Drive not encrypted'; StartedAt = '2026-10-18T09:01:00' }
          'chrome'    = @{ Status = 'Failed';  Message = 'MSI exit 1603';       StartedAt = '2026-10-18T09:02:00' }
          'anydesk'   = @{ Status = 'running'; Message = '';                    StartedAt = '2026-10-18T09:14:55' }
          '7zip'      = @{ Status = 'pending'; Message = '';                    StartedAt = $null }
          # 'office' has no state entry at all
        }
      }
    }
  }
  It 'prints one marker line per planned step, in plan order, with catalog titles' {
    $l = Format-ProgressScreen -State (New-ProgressState) -Catalog $cat -Now ([datetime]'2026-10-18T09:17:30')
    $l | Should -Contain '  [OK] Prepare machine'
    $l | Should -Contain '  [--] Turn off BitLocker - Drive not encrypted'
    $l | Should -Contain '  [X ] Google Chrome - MSI exit 1603'
    $l | Should -Contain '  [>>] AnyDesk  (02:35)'
    $l | Should -Contain '  [..] 7-Zip'
    $l | Should -Contain '  [..] Microsoft 365'
    $order = @($l | Where-Object { $_ -match '^  \[' })
    $order.Count | Should -Be 6
    $order[0] | Should -Match 'Prepare machine'; $order[5] | Should -Match 'Microsoft 365'
  }
  It 'has the heading first and the reboot and total line last' {
    $l = Format-ProgressScreen -State (New-ProgressState) -Catalog $cat -Now ([datetime]'2026-10-18T10:17:30')
    $l[0] | Should -Be '  BENTECH WINDOWS SETUP - working, do not turn off'
    $l[$l.Count - 1] | Should -Be '  Reboots: 2    Total: 1:17'
  }
  It 'shows elapsed time past 59 minutes as minutes, and clamps a start time in the future to 00:00' {
    $st = New-ProgressState
    $st.Steps['anydesk'].StartedAt = '2026-10-18T09:00:00'
    (Format-ProgressScreen -State $st -Catalog $cat -Now ([datetime]'2026-10-18T10:41:07')) | Should -Contain '  [>>] AnyDesk  (101:07)'
    (Format-ProgressScreen -State $st -Catalog $cat -Now ([datetime]'2026-10-18T08:00:00')) | Should -Contain '  [>>] AnyDesk  (00:00)'
  }
  It 'accepts a step start time that was already turned into a datetime' {
    $st = New-ProgressState
    $st.Steps['anydesk'].StartedAt = [datetime]'2026-10-18T09:14:55'
    $st.StartedAt = [datetime]'2026-10-18T09:00:00'
    $l = Format-ProgressScreen -State $st -Catalog $cat -Now ([datetime]'2026-10-18T09:17:30')
    $l | Should -Contain '  [>>] AnyDesk  (02:35)'
    $l | Should -Contain '  Reboots: 2    Total: 0:17'
  }
  It 'falls back to the step id when the catalog does not know it, and drops an empty reason' {
    $st = @{ StartedAt = '2026-10-18T09:00:00'; RebootCount = 0; Plan = @('mystery'); Steps = @{ mystery = @{ Status = 'Failed'; Message = '' } } }
    (Format-ProgressScreen -State $st -Catalog $cat -Now ([datetime]'2026-10-18T09:00:10')) | Should -Contain '  [X ] mystery'
  }
  It 'keeps a long failure reason on one ASCII line' {
    $st = New-ProgressState
    $st.Steps['chrome'].Message = ('Windows said ' + [char]0x05D1 + "`r`n" + ('x' * 200))
    $l = Format-ProgressScreen -State $st -Catalog $cat -Now ([datetime]'2026-10-18T09:17:30')
    $line = @($l | Where-Object { $_ -match '^  \[X \] Google Chrome' })
    $line.Count | Should -Be 1
    $line[0].Length | Should -BeLessOrEqual 79
    $line[0] | Should -Match '^  \[X \] Google Chrome - Windows said \? x+\.\.\.$'
  }
  It 'works with the real step catalog' {
    $st = @{ StartedAt = '2026-10-18T09:00:00'; RebootCount = 0; Plan = @('prepare', 'finalize'); Steps = @{ prepare = @{ Status = 'Done' }; finalize = @{ Status = 'pending' } } }
    $l = Format-ProgressScreen -State $st -Catalog $script:StepCatalog -Now ([datetime]'2026-10-18T09:00:10')
    $l | Should -Contain '  [OK] Prepare machine'; $l | Should -Contain '  [..] Finalize'
  }
}

Describe 'Show-ProgressScreen' {
  # Safety net: this must only reach the console through its seams.
  BeforeEach {
    Mock Clear-Host { throw 'Clear-Host must not run in tests' }
    Mock Write-Host { throw 'Write-Host must not run in tests' }
    Mock Start-Process { throw 'Start-Process must not run in tests' }
  }
  It 'draws the formatted lines through the write seam at the injected time' {
    $script:progressDrawn = $null
    $st = @{ StartedAt = '2026-10-18T09:00:00'; RebootCount = 1; Plan = @('prepare'); Steps = @{ prepare = @{ Status = 'running'; StartedAt = '2026-10-18T09:00:00' } } }
    Show-ProgressScreen -State $st -Catalog @(@{ Id = 'prepare'; Title = 'Prepare machine'; Function = 'x' }) `
      -Now { [datetime]'2026-10-18T09:01:05' } -Write { param($lines) $script:progressDrawn = @($lines) }
    $script:progressDrawn | Should -Contain '  [>>] Prepare machine  (01:05)'
    $script:progressDrawn[$script:progressDrawn.Count - 1] | Should -Be '  Reboots: 1    Total: 0:01'
  }
  It 'clears the screen and writes the lines when no -Write seam is given' {
    $script:cleared = 0
    $script:hostCalls = New-Object System.Collections.ArrayList
    Mock Clear-Host { $script:cleared++ }
    Mock Write-Host { $null = $script:hostCalls.Add([string]$Object) }
    $st = @{ StartedAt = '2026-10-18T09:00:00'; RebootCount = 0; Plan = @('finalize'); Steps = @{ finalize = @{ Status = 'Done' } } }
    Show-ProgressScreen -State $st -Now { [datetime]'2026-10-18T09:00:05' }
    $cleared | Should -Be 1
    $hostCalls | Should -Contain '  [OK] Finalize'
    $hostCalls | Should -Contain ''
  }
  It 'uses the step catalog when none is passed' {
    $script:progressDrawn = $null
    $st = @{ StartedAt = '2026-10-18T09:00:00'; RebootCount = 0; Plan = @('finalize'); Steps = @{ finalize = @{ Status = 'Done' } } }
    Show-ProgressScreen -State $st -Now { [datetime]'2026-10-18T09:00:05' } -Write { param($lines) $script:progressDrawn = @($lines) }
    $script:progressDrawn | Should -Contain '  [OK] Finalize'
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
      $l.IndexOf('  Report: C:\r.txt   [R] open report   [any other key] close')
    )
    @($idx | Where-Object { $_ -lt 0 }).Count | Should -Be 0
    $sorted = @($idx | Sort-Object)
    $idx | Should -Be $sorted
    $idx[6] | Should -Be ($l.Count - 1)   # the report line is last
  }
  It 'ends with the report line' {
    $l = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict) -ReportPath 'C:\BenTech\Setup\Logs\Setup-Report.txt' -DefaultBrowserIsChrome $true)
    $l[$l.Count - 1] | Should -Be '  Report: C:\BenTech\Setup\Logs\Setup-Report.txt   [R] open report   [any other key] close'
  }
  It 'caps long lists so the banner and the ID stay on screen, and cuts long lines' {
    $many = 1..9 | ForEach-Object { "Failure number $_" }
    $long = 'Windows Update: ' + ('y' * 200)
    $l = @(Format-FinalScreen -State (New-FinalState) -Verdict (New-Verdict -Color 'RED' -Banner 'COMPLETED WITH ERRORS' -Failures (@($long) + $many) -Notes @(1..6 | ForEach-Object { "Note $_" })) -ReportPath 'C:\r.txt' -DefaultBrowserIsChrome $true)
    @($l | Where-Object { $_ -like '  X  *' -and $_ -notlike '*more*' }).Count | Should -Be 5
    @($l | Where-Object { $_ -like '  !  *' -and $_ -notlike '*more*' }).Count | Should -Be 4
    $l | Should -Contain '  X  ... and 5 more: see the report'
    $l | Should -Contain '  !  ... and 2 more: see the report'
    $l.Count | Should -BeLessThan 36
    @($l | Where-Object { $_ -like '  X  *' -and $_.Length -gt 79 }).Count | Should -Be 0
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
}

Describe 'Show-FinalScreen' {
  BeforeEach {
    Mock Clear-Host { throw 'Clear-Host must not run in tests' }
    Mock Write-Host { throw 'Write-Host must not run in tests' }
    Mock Start-Process { throw 'Start-Process must not run in tests' }
    Mock Test-ChromeInstalled { $true }
    Mock Get-DefaultBrowserProgId { 'MSEdgeHTM' }
    Mock Get-ChromeRegisteredAppName { 'Google Chrome' }
  }
  It 'paints the console DarkGreen, DarkYellow or DarkRed by verdict colour' {
    Invoke-FinalScreen -Color 'GREEN'; $colors[0] | Should -Be 'DarkGreen'
    Invoke-FinalScreen -Color 'YELLOW'; $colors[0] | Should -Be 'DarkYellow'
    Invoke-FinalScreen -Color 'RED'; $colors[0] | Should -Be 'DarkRed'
    $colors.Count | Should -Be 1
  }
  It 'paints an unexpected colour name red, never green' {
    Invoke-FinalScreen -Color 'PURPLE'; $colors[0] | Should -Be 'DarkRed'
  }
  It 'puts the console colours back last, when the screen closes' {
    Invoke-FinalScreen -Keys 'R', 'Q'
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
  It 'clears the screen and writes the lines in white when no -Write seam is given' {
    $script:cleared = 0
    $script:hostCalls = New-Object System.Collections.ArrayList
    Mock Clear-Host { $script:cleared++ }
    Mock Write-Host { $null = $script:hostCalls.Add(@{ Text = [string]$Object; Color = $ForegroundColor }) }
    Show-FinalScreen -State (@{ Machine = $m; AnyDeskId = '123456789'; RebootCount = 0; StartedAt = '2026-10-18T09:00:00'; EndedAt = '2026-10-18T09:10:00' }) `
      -Verdict @{ Color = 'GREEN'; Banner = 'SETUP COMPLETE'; Failures = @(); Notes = @() } -ReportPath 'C:\r.txt' `
      -ReadKey { 'Q' } -SetColor { param($c) } -ResetColor { } -FlushInput { } -Launch { param($t, $a) }
    $cleared | Should -Be 1
    @($hostCalls | Where-Object { $_.Text -match 'SETUP COMPLETE' }).Count | Should -Be 1
    @($hostCalls | Where-Object { $_.Color -ne 'White' }).Count | Should -Be 0
  }
  It 'treats an unknown default browser as not Chrome' {
    Mock Get-DefaultBrowserProgId { $null }
    Invoke-FinalScreen
    $drawn[0] | Should -Match 'press B'
  }
  It 'B opens Default Apps for Chrome with the registered name URL-encoded, then keeps waiting' {
    Invoke-FinalScreen -Keys 'B', 'Q'
    $launched.Count | Should -Be 1
    $launched[0].Target | Should -Be 'ms-settings:defaultapps?registeredAppMachine=Google%20Chrome'
    @($events | Where-Object { $_ -eq 'read' }).Count | Should -Be 2
    $drawn.Count | Should -Be 1
  }
  It 'R opens the report in notepad with the path quoted, then keeps waiting' {
    Invoke-FinalScreen -Keys 'R', 'Escape'
    $launched.Count | Should -Be 1
    $launched[0].Target | Should -Be 'notepad.exe'
    $launched[0].Arguments | Should -Be '"C:\BenTech\Setup\Logs\Setup-Report.txt"'
  }
  It 'B and R can be used in any order and any number of times' {
    Invoke-FinalScreen -Keys 'R', 'B', 'R', 'Enter'
    @($launched | ForEach-Object { $_.Target }) | Should -Be @('notepad.exe', 'ms-settings:defaultapps?registeredAppMachine=Google%20Chrome', 'notepad.exe')
  }
  It 'any other key returns without launching anything' {
    foreach ($k in 'Enter', 'Escape', 'Spacebar', 'X') {
      Invoke-FinalScreen -Keys $k, 'B'
      $launched.Count | Should -Be 0
      @($events | Where-Object { $_ -eq 'read' }).Count | Should -Be 1
    }
  }
  It 'returns instead of looping forever when no key can be read' {
    Invoke-FinalScreen -Keys @()
    $launched.Count | Should -Be 0
  }
  It 'empties the key buffer after drawing and before it waits, so a stray key cannot close the screen' {
    Invoke-FinalScreen
    $events.IndexOf('write') | Should -BeLessThan $events.IndexOf('flush')
    $events.IndexOf('flush') | Should -BeLessThan $events.IndexOf('read')
  }
  It 'restores the console colour even when the key read throws' {
    $script:colors = New-Object System.Collections.ArrayList
    $script:resets = 0
    {
      Show-FinalScreen -State (@{ Machine = $m; AnyDeskId = '123456789'; RebootCount = 0; StartedAt = '2026-10-18T09:00:00'; EndedAt = '2026-10-18T09:10:00' }) `
        -Verdict @{ Color = 'RED'; Banner = 'COMPLETED WITH ERRORS'; Failures = @('F'); Notes = @() } -ReportPath 'C:\r.txt' `
        -ReadKey { throw 'console went away' } -SetColor { param($c) $null = $script:colors.Add($c) } -ResetColor { $script:resets++ } `
        -Write { param($lines) } -FlushInput { } -Launch { param($t, $a) }
    } | Should -Throw '*console went away*'
    $colors.Count | Should -Be 1
    $colors[0] | Should -Be 'DarkRed'
    $resets | Should -Be 1
  }
  It 'survives a launch failure and keeps waiting' {
    Invoke-FinalScreen -Keys 'R', 'B', 'Q' -Launch { param($t, $a) throw 'no notepad here' }
    $launched.Count | Should -Be 2
    @($events | Where-Object { $_ -eq 'read' }).Count | Should -Be 3
  }
  It 'survives a colour change that fails and still draws the screen' {
    $script:drawn = New-Object System.Collections.ArrayList
    Show-FinalScreen -State (@{ Machine = $m; AnyDeskId = '123456789'; RebootCount = 0; StartedAt = '2026-10-18T09:00:00'; EndedAt = '2026-10-18T09:10:00' }) `
      -Verdict @{ Color = 'GREEN'; Banner = 'SETUP COMPLETE'; Failures = @(); Notes = @() } -ReportPath 'C:\r.txt' `
      -ReadKey { 'Q' } -SetColor { param($c) throw 'cannot set colour' } -ResetColor { throw 'cannot reset colour' } `
      -Write { param($lines) $null = $script:drawn.Add(($lines -join "`n")) } -FlushInput { throw 'cannot flush' } -Launch { param($t, $a) }
    $drawn.Count | Should -Be 1
    $drawn[0] | Should -Match 'SETUP COMPLETE'
  }
}
