# tests/SetupPlanner.Tests.ps1
# BenTech Toolbox, Task 1: the profiles and the Choices check (toolbox spec 5.2, 10b.6). SetupPlanner.ps1 is
# pure (no logging, no I/O), so nothing here needs a mock: it only reads config.json and synthetic configs.
BeforeAll {
  foreach ($f in 'Common\Config', 'Engine\Catalog', 'UI\StartScreen', 'Toolbox\SetupPlanner') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:m = @{ IsLaptop = $true; IsVM = $false; OsBuild = 26200 }
  # A model as JSON with every table's keys sorted: Hashtable.Clone() re-inserts the keys, so a copy can list
  # them in another order although it holds exactly the same values.
  function ConvertTo-SortedJson($Value) {
    function Get-SortedValue($v) {
      if ($v -is [Collections.IDictionary]) { $o = [ordered]@{}; foreach ($k in @($v.Keys | Sort-Object)) { $o[$k] = Get-SortedValue $v[$k] }; return $o }
      Write-Output -NoEnumerate $v
    }
    ConvertTo-Json -InputObject (Get-SortedValue $Value) -Depth 5
  }
}
Describe 'profiles (toolbox spec 5.2)' {
  It 'reads the three approved profiles; business takes the catalog defaults, without file extensions (Q27)' {
    @(Get-SetupProfiles -Config $cfg).Id | Should -Be @('home', 'business', 'clean')
    $b = Get-ProfileChoices -Config $cfg -ProfileId 'business'
    $b.Office | Should -Be 'BUSINESS'; $b.Remote | Should -Be 'BOTH'; $b.SevenZip | Should -BeTrue; $b.RestorePoint | Should -BeTrue
    @($b.Tweaks) | Should -Be @('accessKeys', 'numLock', 'startClean', 'noAds', 'classicOutlook')
    $c = Get-ProfileChoices -Config $cfg -ProfileId 'clean'; @($c.Tweaks).Count | Should -Be 0; $c.Office | Should -Be 'OFF'; $c.SevenZip | Should -BeFalse }
  It 'skips a profile with a bad, duplicate or nameless id, and repairs bad values from defaults' {
    $x = '{"defaults":{"sevenZip":true,"office":"CRAFT","remote":"ANYDESK","profile":"nope"},"tweaks":[],"profiles":[
      {"id":"Bad Id","name":{"en":"x"}},{"id":"a","name":{"en":"A"},"office":"platinum","remote":"teamviewer","sevenZip":"yes"},
      {"id":"a","name":{"en":"dup"}},{"id":"b","name":{"en":""}},{"id":"c","name":{"en":"C"},"tweaksAdd":["noAds","widgets"]}]}' | ConvertFrom-Json
    @(Get-SetupProfiles -Config $x).Id | Should -Be @('a', 'c')
    $a = Get-ProfileChoices -Config $x -ProfileId 'a'; $a.Office | Should -Be 'CRAFT'; $a.Remote | Should -Be 'ANYDESK'; $a.SevenZip | Should -BeTrue
    Get-DefaultProfileId -Config $x | Should -BeExactly ''        # an unknown default profile is skipped
    Get-ProfileChoices -Config $x -ProfileId 'nope' | Should -BeNullOrEmpty }
  It 'tweaksAdd adds catalog ids only' {
    $x = $cfg.PSObject.Copy(); $x.profiles = @([pscustomobject]@{ id = 'c'; name = [pscustomobject]@{ en = 'C' }; tweaks = @(); tweaksAdd = @('fileExtensions', 'widgets') })
    @((Get-ProfileChoices -Config $x -ProfileId 'c').Tweaks) | Should -Be @('fileExtensions') }
  It 'a profile may set windowsUpdate (an invalid value is FULL); without it the key is not among its choices (wu spec 3.1)' {
    $x = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $x.profiles[1] | Add-Member NoteProperty windowsUpdate 'drivers'; $x.profiles[2] | Add-Member NoteProperty windowsUpdate 'never'
    (Get-ProfileChoices -Config $x -ProfileId 'home').Contains('WindowsUpdate') | Should -BeFalse
    (Get-ProfileChoices -Config $x -ProfileId 'business').WindowsUpdate | Should -BeExactly 'DRIVERS'
    (Get-ProfileChoices -Config $x -ProfileId 'clean').WindowsUpdate | Should -BeExactly 'FULL' }
}
Describe 'ConvertTo-ValidChoices (toolbox spec 5.2)' {
  It 'repairs every key from the defaults and reports unknown tweak ids' {
    $r = ConvertTo-ValidChoices -Choices @{ Mode = 'tablet'; Office = 'business'; Remote = 'TEAMVIEWER'; SevenZip = 'yes'; Profile = 'nope'; RestorePoint = 1
                                            Tweaks = @('noAds', 'widgets', '', 'classicOutlook'); WindowsUpdate = 'everything' } -Config $cfg -Machine $m
    $r.Choices.Mode | Should -Be 'LAPTOP'; $r.Choices.Office | Should -Be 'BUSINESS'; $r.Choices.Remote | Should -Be 'ANYDESK'
    $r.Choices.SevenZip | Should -BeTrue; $r.Choices.Profile | Should -BeExactly ''; $r.Choices.RestorePoint | Should -BeTrue
    $r.Choices.WindowsUpdate | Should -BeExactly 'FULL'
    @($r.Choices.Tweaks) | Should -Be @('noAds', 'classicOutlook'); @($r.Dropped) | Should -Be @('widgets') }
  It 'keeps DRIVERS in any case and returns exactly eight keys' {
    $c = New-DefaultChoices -Machine $m -Config $cfg; $c.WindowsUpdate = 'drivers'
    $r = ConvertTo-ValidChoices -Choices $c -Config $cfg -Machine $m; $r.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS'
    @($r.Choices.Keys | Sort-Object) | Should -Be @('Mode', 'Office', 'Profile', 'Remote', 'RestorePoint', 'SevenZip', 'Tweaks', 'WindowsUpdate') }
  It 'keeps only ASCII ids in the Choices (nothing Hebrew reaches state.json or setup.log)' {
    $r = ConvertTo-ValidChoices -Choices (New-DefaultChoices -Machine $m -Config $cfg) -Config $cfg -Machine $m
    ($r.Choices | ConvertTo-Json -Compress) | Should -Not -Match '[^\x00-\x7F]' }
}
Describe 'Test-ProfileChanged (spec 10b.6)' {
  BeforeEach { $script:c = New-DefaultChoices -Machine $m -Config $cfg }
  It 'the untouched default profile is not changed' { Test-ProfileChanged -Choices $c -Config $cfg -Machine $m | Should -BeFalse }
  It 'Type is never part of a profile: Desktop is not a change, NumLock follows it' { $c.Mode = 'DESKTOP'; Test-ProfileChanged -Choices $c -Config $cfg -Machine $m | Should -BeFalse }
  It '<Why> is a change' -ForEach @(@{ Why = 'another Office'; K = 'Office'; V = 'OFF' }, @{ Why = 'a tweak turned off'; K = 'Tweaks'; V = @('accessKeys') },
      @{ Why = 'no restore point'; K = 'RestorePoint'; V = $false }, @{ Why = 'another Remote'; K = 'Remote'; V = 'BOTH' }) {
    $c[$K] = $V; Test-ProfileChanged -Choices $c -Config $cfg -Machine $m | Should -BeTrue }
  It 'an unknown or empty profile is never "changed"' { $c.Profile = 'gone'; Test-ProfileChanged -Choices $c -Config $cfg -Machine $m | Should -BeFalse }
  It 'DRIVERS is no change for a profile that does not set windowsUpdate (Review Focus 2)' { $c.WindowsUpdate = 'DRIVERS'; Test-ProfileChanged -Choices $c -Config $cfg -Machine $m | Should -BeFalse }
  It 'a profile that sets windowsUpdate: another value is a change, its own is not' {
    $x = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $x.profiles[0] | Add-Member NoteProperty windowsUpdate 'FULL'
    $c.WindowsUpdate = 'DRIVERS'; Test-ProfileChanged -Choices $c -Config $x -Machine $m | Should -BeTrue
    $c.WindowsUpdate = 'FULL'; Test-ProfileChanged -Choices $c -Config $x -Machine $m | Should -BeFalse }
}
Describe 'New-ToolboxModel and Get-ToolboxPlanLines' {
  It 'opens on the default profile in the configured language' {
    $mo = New-ToolboxModel -Machine $m -Config $cfg -IsFresh $true -OnAC $true -AdminProtection 'Off'
    $mo.Language | Should -Be 'en'; $mo.Choices.Profile | Should -Be 'home'; $mo.MaxAgeDays | Should -Be 14
    $x = $cfg.PSObject.Copy(); $x.toolbox = [pscustomobject]@{ language = 'fr' }; (New-ToolboxModel -Machine $m -Config $x -IsFresh $true -OnAC $true -AdminProtection 'Off').Language | Should -Be 'en' }
  It 'numbers the plan with catalog titles, the tweaks step right after the desktop icons' {
    $l = @(Get-ToolboxPlanLines -Model (New-ToolboxModel -Machine $m -Config $cfg -IsFresh $true -OnAC $true -AdminProtection 'Off') -Machine @{ Brand = 'DELL'; OsBuild = 26200 } -Config $cfg)
    $l[0] | Should -BeExactly ' 1  Prepare machine'; $l[4] | Should -BeExactly ' 5  System tweaks'; $l[-1] | Should -Match '^\d\d  Finalize$' }
  It 'takes the titles of the window''s language, the catalog''s English where one is missing (TB-R5)' {
    $l = @(Get-ToolboxPlanLines -Model (New-ToolboxModel -Machine $m -Config $cfg -IsFresh $true -OnAC $true -AdminProtection 'Off') -Machine @{ Brand = 'DELL'; OsBuild = 26200 } -Config $cfg `
      -Titles @{ prepare = 'Step one'; bitlocker = '' })
    $l[0] | Should -BeExactly ' 1  Step one'; $l[1] | Should -BeExactly ' 2  Turn off BitLocker' }
  It 'DRIVERS titles the Windows Update line "(drivers only)", or with the window''s title for it (wu spec 3.1)' {
    $mo = New-ToolboxModel -Machine $m -Config $cfg -IsFresh $true -OnAC $true -AdminProtection 'Off'; $mo.Choices.WindowsUpdate = 'DRIVERS'; $dell = @{ Brand = 'DELL'; OsBuild = 26200 }
    $l = @(Get-ToolboxPlanLines -Model $mo -Machine $dell -Config $cfg)
    @($l | Where-Object { $_ -match '^[ \d]\d  Windows Update \(drivers only\)$' }).Count | Should -Be 1; @($l | Where-Object { $_ -match '  Windows Update$' }).Count | Should -Be 0
    @(@(Get-ToolboxPlanLines -Model $mo -Machine $dell -Config $cfg -Titles @{ 'windows-update' = 'WU'; 'windows-update.drivers' = 'WU drivers' }) -match '  WU drivers$').Count | Should -Be 1 }
  # Final wave 7 (Task 2 M4): a window language that has the Windows Update title but not the drivers one still
  # shows "drivers only" (the English drivers title), never the plain FULL title.
  It 'DRIVERS falls back to "Windows Update (drivers only)" when -Titles has no drivers title, or an empty one' -ForEach @(
    @{ T = @{ 'windows-update' = 'WU' } }, @{ T = @{ 'windows-update' = 'WU'; 'windows-update.drivers' = '' } }) {
    $mo = New-ToolboxModel -Machine $m -Config $cfg -IsFresh $true -OnAC $true -AdminProtection 'Off'; $mo.Choices.WindowsUpdate = 'DRIVERS'
    $l = @(Get-ToolboxPlanLines -Model $mo -Machine @{ Brand = 'DELL'; OsBuild = 26200 } -Config $cfg -Titles $T)
    @($l | Where-Object { $_ -match '^[ \d]\d  Windows Update \(drivers only\)$' }).Count | Should -Be 1; @($l | Where-Object { $_ -match '  WU$' }).Count | Should -Be 0 }
  # Final wave 3 (Task 2 M2): the plan line decides through Get-WindowsUpdateChoice on the validated Choices, like
  # every other reader. The mock flips the answer for each table it is asked about, so the line is DRIVERS only if
  # the second question (about the validated table, where validation made it FULL) is asked.
  It 'the DRIVERS title is decided by Get-WindowsUpdateChoice on the validated Choices (every reader goes through it)' {
    Mock Get-WindowsUpdateChoice { if ($Choices['WindowsUpdate'] -ceq 'DRIVERS') { 'FULL' } else { 'DRIVERS' } }
    $mo = New-ToolboxModel -Machine $m -Config $cfg -IsFresh $true -OnAC $true -AdminProtection 'Off'; $mo.Choices.WindowsUpdate = 'DRIVERS'
    $l = @(Get-ToolboxPlanLines -Model $mo -Machine @{ Brand = 'DELL'; OsBuild = 26200 } -Config $cfg)
    @($l | Where-Object { $_ -match '^[ \d]\d  Windows Update \(drivers only\)$' }).Count | Should -Be 1 }
}
Describe 'Update-ToolboxModel (pure, like Update-StartChoices)' {
  BeforeEach { $script:mo = New-ToolboxModel -Machine $m -Config $cfg -IsFresh $true -OnAC $true -AdminProtection 'Off' }
  It 'a profile fills the options and keeps the Type' {
    $mo.Choices.Mode = 'DESKTOP'; $r = Update-ToolboxModel -Model $mo -Action 'Profile' -Value 'business' -Config $cfg
    $r.Choices.Profile | Should -Be 'business'; $r.Choices.Office | Should -Be 'BUSINESS'; $r.Choices.Remote | Should -Be 'BOTH'; $r.Choices.Mode | Should -Be 'DESKTOP' }
  It 'a changed option keeps the profile; the input model is untouched' {
    $r = Update-ToolboxModel -Model $mo -Action 'Office' -Value 'HOME' -Config $cfg
    $r.Choices.Office | Should -Be 'HOME'; $r.Choices.Profile | Should -Be 'home'; $mo.Choices.Office | Should -Be 'CRAFT' }
  It 'toggles a tweak in catalog order, and ignores unknown values' {
    $r = Update-ToolboxModel -Model $mo -Action 'Tweak' -Value 'fileExtensions' -Config $cfg
    @($r.Choices.Tweaks) | Should -Be @('accessKeys', 'numLock', 'startClean', 'noAds', 'classicOutlook', 'fileExtensions')
    @((Update-ToolboxModel -Model $r -Action 'Tweak' -Value 'accessKeys' -Config $cfg).Choices.Tweaks)[0] | Should -Be 'numLock'
    foreach ($a in @(@('Tweak', 'widgets'), @('Office', 'PLATINUM'), @('Mode', 'TABLET'), @('Profile', 'nope'), @('Language', 'fr'), @('Explode', ''),
                     @('WindowsUpdate', 'drivers'), @('WindowsUpdate', 'NONE'))) {
      ConvertTo-SortedJson (Update-ToolboxModel -Model $mo -Action $a[0] -Value $a[1] -Config $cfg) | Should -Be (ConvertTo-SortedJson $mo) -Because ($a -join ' ') } }
  It 'toggles 7-Zip and the restore point, sets the language and the power' {
    (Update-ToolboxModel -Model $mo -Action 'SevenZip' -Config $cfg).Choices.SevenZip | Should -BeFalse
    (Update-ToolboxModel -Model $mo -Action 'RestorePoint' -Config $cfg).Choices.RestorePoint | Should -BeFalse
    (Update-ToolboxModel -Model $mo -Action 'Language' -Value 'he' -Config $cfg).Language | Should -Be 'he'
    (Update-ToolboxModel -Model $mo -Action 'Power' -Value 'false' -Config $cfg).OnAC | Should -BeFalse }
  It 'never changes the input: the Choices and the Tweaks array are copies' {
    $before = $mo | ConvertTo-Json -Depth 5
    $r = Update-ToolboxModel -Model $mo -Action 'Tweak' -Value 'accessKeys' -Config $cfg
    foreach ($a in @(@('Profile', 'clean'), @('Mode', 'DESKTOP'), @('SevenZip', ''), @('Language', 'he'), @('Power', 'false'))) { $null = Update-ToolboxModel -Model $mo -Action $a[0] -Value $a[1] -Config $cfg }
    ($mo | ConvertTo-Json -Depth 5) | Should -Be $before   # the input itself: same table, same order
    [object]::ReferenceEquals($r.Choices, $mo.Choices) | Should -BeFalse; [object]::ReferenceEquals($r.Choices.Tweaks, $mo.Choices.Tweaks) | Should -BeFalse
    @($r.Choices.Tweaks) | Should -Not -Contain 'accessKeys'; @($mo.Choices.Tweaks) | Should -Contain 'accessKeys' }
  It 'sets the Windows Update choice from the tile; a profile without windowsUpdate keeps it, one with it fills it (wu spec 3.1, Review Focus 2)' {
    $d = Update-ToolboxModel -Model $mo -Action 'WindowsUpdate' -Value 'DRIVERS' -Config $cfg
    $d.Choices.WindowsUpdate | Should -BeExactly 'DRIVERS'; $d.Choices.Profile | Should -Be 'home'; $mo.Choices.WindowsUpdate | Should -BeExactly 'FULL'
    foreach ($p in 'home', 'business', 'clean') { (Update-ToolboxModel -Model $d -Action 'Profile' -Value $p -Config $cfg).Choices.WindowsUpdate | Should -BeExactly 'DRIVERS' -Because $p }
    $x = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $x.profiles[2] | Add-Member NoteProperty windowsUpdate 'FULL'
    (Update-ToolboxModel -Model $d -Action 'Profile' -Value 'clean' -Config $x).Choices.WindowsUpdate | Should -BeExactly 'FULL' }
}
