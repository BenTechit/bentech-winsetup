# tests/Catalog.Tests.ps1
BeforeAll {
  . "$PSScriptRoot\..\src\Common\Config.ps1"; . "$PSScriptRoot\..\src\State\State.ps1"
  . "$PSScriptRoot\..\src\Engine\Catalog.ps1"; . "$PSScriptRoot\..\src\Engine\Verdict.ps1"
  $script:cfg = Read-SetupConfig -Path "$PSScriptRoot\..\config\config.json"
  function P($brand, $mode, $z = $true, $o = 'BUSINESS') { Get-StepPlan -Machine @{Brand=$brand} -Choices @{Mode=$mode;SevenZip=$z;Office=$o} -Config $cfg }
}
Describe 'StepCatalog' {
  It 'lists the 18 steps in spec order with their titles and functions' {
    $rows = @($script:StepCatalog | ForEach-Object { '{0}|{1}|{2}' -f $_.Id, $_.Title, $_.Function })
    $rows | Should -Be @(
      'prepare|Prepare machine|Invoke-StepPrepare'
      'bitlocker|Turn off BitLocker|Invoke-StepBitLocker'
      'region|Time zone + Hebrew keyboard|Invoke-StepRegion'
      'desktop-icons|Desktop icons|Invoke-StepDesktopIcons'
      'bloatware|Remove bloatware|Invoke-StepBloatware'
      'rename|Rename PC|Invoke-StepRename'
      'winget|Prepare winget|Invoke-StepWinget'
      'chrome|Google Chrome|Invoke-StepChrome'
      'anydesk|AnyDesk|Invoke-StepAnyDesk'
      '7zip|7-Zip|Invoke-StepSevenZip'
      'office|Microsoft 365|Invoke-StepOffice'
      'default-browser|Chrome as default browser|Invoke-StepDefaultBrowser'
      'vendor-pass1|Vendor drivers + BIOS (pass 1)|Invoke-StepVendorPass1'
      'windows-update|Windows Update|Invoke-StepWindowsUpdate'
      'vendor-pass2|Vendor drivers + BIOS (pass 2)|Invoke-StepVendorPass2'
      'consumer-app|Vendor app|Invoke-StepConsumerApp'
      'vendor-cleanup|Remove business updater|Invoke-StepVendorCleanup'
      'finalize|Finalize|Invoke-StepFinalize'
    )
  }
  It 'has unique ids' { @($script:StepCatalog.Id | Select-Object -Unique).Count | Should -Be $script:StepCatalog.Count }
  It 'every step has a Short title of at most 20 characters' { foreach ($s in $script:StepCatalog) { $s.Short | Should -Not -BeNullOrEmpty; $s.Short.Length | Should -BeLessOrEqual 20 } }
  It 'has the progress screen''s Short titles (v2 spec 4.2)' {
    @($script:StepCatalog | ForEach-Object { '{0}|{1}' -f $_.Id, $_.Short }) | Should -Be @(
      'prepare|Prepare', 'bitlocker|BitLocker off', 'region|Time zone + keyboard', 'desktop-icons|Desktop icons'
      'bloatware|Remove bloatware', 'rename|Rename PC', 'winget|winget', 'chrome|Chrome', 'anydesk|AnyDesk', '7zip|7-Zip'
      'office|Microsoft 365', 'default-browser|Default browser', 'vendor-pass1|Drivers (pass 1)', 'windows-update|Windows Update'
      'vendor-pass2|Drivers (pass 2)', 'consumer-app|Laptop app', 'vendor-cleanup|Remove updater', 'finalize|Finish'
    )
  }
}
Describe 'Test-HasDriverTool' {
  It 'Test-HasDriverTool: Dell yes, ASUS no, a Dell VM no' {
    Test-HasDriverTool -Machine @{ Brand = 'DELL' } | Should -BeTrue
    Test-HasDriverTool -Machine @{ Brand = 'ASUS' } | Should -BeFalse
    Test-HasDriverTool -Machine @{ Brand = 'DELL'; IsVM = $true } | Should -BeFalse
  }
  It 'Lenovo and HP yes; the VM brand, an unknown brand and a missing brand no' {
    foreach ($b in 'LENOVO', 'HP') { Test-HasDriverTool -Machine @{ Brand = $b } | Should -BeTrue -Because $b }
    foreach ($mach in @{ Brand = 'VM' }, @{ Brand = 'OTHER' }, @{ Brand = '' }, @{ }) { Test-HasDriverTool -Machine $mach | Should -BeFalse }
  }
}
Describe 'Get-StepPlan' {
  It 'Dell laptop gets everything in order' { (P DELL LAPTOP) -join ',' | Should -Be 'prepare,bitlocker,region,desktop-icons,bloatware,rename,winget,chrome,anydesk,7zip,office,default-browser,vendor-pass1,windows-update,vendor-pass2,consumer-app,vendor-cleanup,finalize' }
  It 'Dell desktop: vendor passes, no consumer app, no cleanup' { $p = P DELL DESKTOP; $p | Should -Contain 'vendor-pass1'; $p | Should -Not -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-cleanup' }
  It 'ASUS laptop: consumer app only' { $p = P ASUS LAPTOP; $p | Should -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-pass1'; $p | Should -Not -Contain 'vendor-cleanup' }
  It 'custom desktop: no vendor steps' { (P OTHER DESKTOP) -match 'vendor|consumer' | Should -BeNullOrEmpty }
  It 'VM in laptop mode: still no vendor steps' { (P VM LAPTOP) -match 'vendor|consumer' | Should -BeNullOrEmpty }
  It 'toggles off' { $p = P DELL LAPTOP $false 'OFF'; $p | Should -Not -Contain '7zip'; $p | Should -Not -Contain 'office' }
  It 'a brand with no vendors entry does not throw (SAMSUNG laptop)' {
    { P SAMSUNG LAPTOP } | Should -Not -Throw
    $p = P SAMSUNG LAPTOP; $p | Should -Not -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-pass1'
  }
  It 'a VM never gets vendor steps, even when the brand string says otherwise' {
    $p = Get-StepPlan -Machine @{Brand='DELL';IsVM=$true} -Choices @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'} -Config $cfg
    $p -match 'vendor|consumer' | Should -BeNullOrEmpty
  }
  It 'takes the mode from Choices, never from Machine.IsLaptop' {
    $p = Get-StepPlan -Machine @{Brand='DELL';IsLaptop=$true} -Choices @{Mode='DESKTOP';SevenZip=$true;Office='BUSINESS'} -Config $cfg
    $p | Should -Not -Contain 'consumer-app'; $p | Should -Not -Contain 'vendor-cleanup'
    $p = Get-StepPlan -Machine @{Brand='DELL';IsLaptop=$false} -Choices @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'} -Config $cfg
    $p | Should -Contain 'consumer-app'; $p | Should -Contain 'vendor-cleanup'
  }
  It 'HP and Lenovo laptops get passes, vendor app and cleanup' {
    foreach ($b in 'HP', 'LENOVO') { $p = P $b LAPTOP; $p | Should -Contain 'vendor-pass1'; $p | Should -Contain 'vendor-pass2'; $p | Should -Contain 'consumer-app'; $p | Should -Contain 'vendor-cleanup' }
  }
  It 'emits the ids as plain strings (not one wrapped array)' {
    $p = P DELL LAPTOP
    $p.Count | Should -Be 18
    $p[0] | Should -BeOfType [string]; $p[0] | Should -Be 'prepare'; $p[17] | Should -Be 'finalize'
  }
  It 'the id list survives the caller patterns: @(), foreach, pipeline, New-RunState -Plan' {
    $m = @{Brand='DELL'}; $c = @{Mode='LAPTOP';SevenZip=$true;Office='BUSINESS'}
    @(Get-StepPlan -Machine $m -Choices $c -Config $cfg).Count | Should -Be 18
    @(Get-StepPlan -Machine $m -Choices $c -Config $cfg)[0] | Should -Be 'prepare'
    $seen = 0; foreach ($id in Get-StepPlan -Machine $m -Choices $c -Config $cfg) { $seen++ }
    $seen | Should -Be 18
    @(Get-StepPlan -Machine $m -Choices $c -Config $cfg | ForEach-Object { $_ }).Count | Should -Be 18
    $state = New-RunState -Machine @{} -Choices $c -Plan (Get-StepPlan -Machine $m -Choices $c -Config $cfg) -Version 'v'
    @($state.Plan).Count | Should -Be 18
    $state.Plan[0] | Should -Be 'prepare'
    $state.Steps.Count | Should -Be 18
  }
  It 'Office HOME keeps the office step' { (P DELL LAPTOP $true 'HOME') | Should -Contain 'office' }
}
Describe 'Get-RunVerdict' {
  BeforeEach { $script:s = New-RunState -Machine @{} -Choices @{} -Plan @('chrome','office') -Version 'v'
               $s.Steps.chrome.Status = 'Done'; $s.Steps.office.Status = 'Done' }
  It 'green' { (Get-RunVerdict -State $s).Color | Should -Be 'GREEN' }
  It 'green banner' { (Get-RunVerdict -State $s).Banner | Should -Be 'SETUP COMPLETE' }
  It 'yellow on skipped' { $s.Steps.office.Status = 'Skipped'; $s.Steps.office.Message = 'x'; $v = Get-RunVerdict -State $s; $v.Color | Should -Be 'YELLOW'; $v.Banner | Should -Be 'COMPLETE - CHECK NOTES' }
  It 'yellow on a note' { $s.Notes = @('Windows 10: no security updates'); (Get-RunVerdict -State $s).Color | Should -Be 'YELLOW' }
  It 'red on failed' { $s.Steps.chrome.Status = 'Failed'; (Get-RunVerdict -State $s).Banner | Should -Be 'COMPLETED WITH ERRORS' }
  It 'red on hidden update' { $s.HiddenUpdateIds = @('abc'); (Get-RunVerdict -State $s).Color | Should -Be 'RED' }
  It 'red on reboot cap' { $s.RebootCapHit = $true; (Get-RunVerdict -State $s).Failures | Should -Contain 'Reboot limit reached' }
  It 'red on a state error' { $s.Errors = @('Drive still encrypted'); (Get-RunVerdict -State $s).Color | Should -Be 'RED' }
  It 'formats a failed step as Title colon Message' {
    $s.Steps.chrome.Status = 'Failed'; $s.Steps.chrome.Message = 'download timed out'
    (Get-RunVerdict -State $s).Failures | Should -Contain 'Google Chrome: download timed out'
  }
  It 'formats a skipped step as a note, Title colon Message' {
    $s.Steps.office.Status = 'Skipped'; $s.Steps.office.Message = 'already installed'
    (Get-RunVerdict -State $s).Notes | Should -Contain 'Microsoft 365: already installed'
  }
  It 'names the hidden update id' {
    $s.HiddenUpdateIds = @('abc', 'def'); $f = (Get-RunVerdict -State $s).Failures
    $f | Should -Contain 'Windows update hidden after repeated failures: abc'
    $f | Should -Contain 'Windows update hidden after repeated failures: def'
  }
  It 'passes state notes and errors through' {
    $s.Notes = @('n1'); $s.Errors = @('e1'); $v = Get-RunVerdict -State $s
    $v.Notes | Should -Contain 'n1'; $v.Failures | Should -Contain 'e1'
  }
  It 'failures outrank notes: red even with notes present' {
    $s.Steps.office.Status = 'Skipped'; $s.Steps.office.Message = 'x'; $s.Steps.chrome.Status = 'Failed'
    $v = Get-RunVerdict -State $s; $v.Color | Should -Be 'RED'; @($v.Notes).Count | Should -Be 1
  }
  It 'a step still pending counts as a failure (never green when steps never ran)' {
    $s.Steps.office.Status = 'pending'
    $v = Get-RunVerdict -State $s
    $v.Color | Should -Be 'RED'; $v.Banner | Should -Be 'COMPLETED WITH ERRORS'
    $v.Failures | Should -Contain 'Microsoft 365: did not finish'
  }
  It 'a step still running counts as a failure' {
    $s.Steps.chrome.Status = 'running'
    $v = Get-RunVerdict -State $s
    $v.Color | Should -Be 'RED'; $v.Failures | Should -Contain 'Google Chrome: did not finish'
  }
  It 'a plan step with no state entry counts as a failure' {
    $s.Steps.Remove('office')
    (Get-RunVerdict -State $s).Failures | Should -Contain 'Microsoft 365: did not finish'
  }
  It 'ignores steps that are not in the plan' {
    $s.Plan = @('chrome'); $s.Steps.office.Status = 'Failed'
    (Get-RunVerdict -State $s).Color | Should -Be 'GREEN'
  }
  It 'returns Failures and Notes as arrays, empty when green' {
    $v = Get-RunVerdict -State $s
    $v.Failures -is [string[]] | Should -BeTrue; $v.Notes -is [string[]] | Should -BeTrue
    @($v.Failures).Count | Should -Be 0; @($v.Notes).Count | Should -Be 0
  }
  It 'names a hidden update by the title the Windows Update step recorded, else by its id (M7)' {
    $s.Plan = @('chrome', 'windows-update'); $s.Steps['windows-update'] = @{ Status = 'Done'; Message = ''; Data = @{ FailedTitles = @{ 'abc' = 'Cumulative Update KB5050001'; 'xyz' = 'not hidden' } } }
    $s.HiddenUpdateIds = @('abc', 'def')
    $f = (Get-RunVerdict -State $s).Failures
    $f | Should -Contain 'Windows update hidden after repeated failures: Cumulative Update KB5050001'
    $f | Should -Contain 'Windows update hidden after repeated failures: def'
    ($f -join "`n") | Should -Not -Match 'xyz|not hidden'
  }
  It 'falls back to the id when the title is empty or the step Data is missing' {
    $s.Plan = @('chrome', 'windows-update'); $s.Steps['windows-update'] = @{ Status = 'Done'; Message = ''; Data = @{ FailedTitles = @{ 'abc' = '  ' } } }
    $s.HiddenUpdateIds = @('abc')
    (Get-RunVerdict -State $s).Failures | Should -Contain 'Windows update hidden after repeated failures: abc'
    $s.Steps['windows-update'] = @{ Status = 'Done'; Message = '' }
    (Get-RunVerdict -State $s).Failures | Should -Contain 'Windows update hidden after repeated failures: abc'
  }
  It 'lists an exact duplicate failure or note once, keeping the first (M1)' {
    $s.Steps.chrome.Status = 'Failed'; $s.Steps.chrome.Message = 'x'
    $s.Errors = @('Restart skipped: no resume task', 'Google Chrome: x', 'Restart skipped: no resume task', 'restart skipped: no resume task')
    $s.Notes = @('On battery: BIOS skipped', 'n2', 'On battery: BIOS skipped')
    $v = Get-RunVerdict -State $s
    @($v.Failures) | Should -Be @('Google Chrome: x', 'Restart skipped: no resume task', 'restart skipped: no resume task')   # exact match only
    @($v.Notes) | Should -Be @('On battery: BIOS skipped', 'n2')
    $v.Failures -is [string[]] | Should -BeTrue
  }
}
