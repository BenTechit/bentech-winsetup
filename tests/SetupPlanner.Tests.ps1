# tests/SetupPlanner.Tests.ps1
# BenTech Toolbox, Task 1: the profiles and the Choices check (toolbox spec 5.2, 10b.6). SetupPlanner.ps1 is
# pure (no logging, no I/O), so nothing here needs a mock: it only reads config.json and synthetic configs.
BeforeAll {
  foreach ($f in 'Common\Config', 'Engine\Catalog', 'UI\StartScreen', 'Toolbox\SetupPlanner') { . "$PSScriptRoot\..\src\$f.ps1" }
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  $script:m = @{ IsLaptop = $true; IsVM = $false; OsBuild = 26200 }
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
}
Describe 'ConvertTo-ValidChoices (toolbox spec 5.2)' {
  It 'repairs every key from the defaults and reports unknown tweak ids' {
    $r = ConvertTo-ValidChoices -Choices @{ Mode = 'tablet'; Office = 'business'; Remote = 'TEAMVIEWER'; SevenZip = 'yes'; Profile = 'nope'; RestorePoint = 1
                                            Tweaks = @('noAds', 'widgets', '', 'classicOutlook') } -Config $cfg -Machine $m
    $r.Choices.Mode | Should -Be 'LAPTOP'; $r.Choices.Office | Should -Be 'BUSINESS'; $r.Choices.Remote | Should -Be 'ANYDESK'
    $r.Choices.SevenZip | Should -BeTrue; $r.Choices.Profile | Should -BeExactly ''; $r.Choices.RestorePoint | Should -BeTrue
    @($r.Choices.Tweaks) | Should -Be @('noAds', 'classicOutlook'); @($r.Dropped) | Should -Be @('widgets') }
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
}
