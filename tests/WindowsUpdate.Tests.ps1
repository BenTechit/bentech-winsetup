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

# --- Task 14 additions: the child round, the parent step, COM-shaped input ---------------------
# SAFETY: this runs on Ben's real PC. NOTHING here may search, download, install, hide or un-hide a
# Windows update, or register the Microsoft Update service.
#   - The parent step's child process is Invoke-External, mocked: it writes the round's result JSON
#     inside $TestDrive and starts nothing.
#   - In the child round (Invoke-WuRound) every COM touchpoint is mocked: New-WuSession,
#     Register-MicrosoftUpdateService, New-WuServiceManager, Test-WuServiceRegistered,
#     Search-WuUpdates, Set-WuHidden, Invoke-WuDownload, Invoke-WuInstall, Get-WuRebootRequired.
#   - Register-MicrosoftUpdateService itself is tested with New-WuServiceManager mocked to return a
#     plain object whose AddService2 only records its arguments.
# The fake updates and collections are plain objects shaped like the COM ones (Count + Item(i)). The
# only real file I/O is state.json and the result JSON, both inside $TestDrive.
Describe 'Windows Update round and step (mocked COM)' {
  BeforeAll {
    foreach ($f in 'StepResult', 'Logging', 'Process') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
    . "$PSScriptRoot\..\src\State\State.ps1"

    $script:WuConfigJson = [IO.File]::ReadAllText("$PSScriptRoot\..\config\config.json", [Text.Encoding]::UTF8)
    $script:MuId = '7971f918-a847-4430-9279-4a52d1efe18d'
    $script:SoftwareCriteria = "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Software'"
    $script:DriverCriteria = "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Driver'"
    $script:PowerShellExe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    # Hebrew letters (and a space) built from code points, so the tests do not depend on how this file
    # is decoded: a folder name for the command-line quoting test (Review Focus #2) and a localized
    # update title / category name (Review Focus #1).
    $script:HebrewFolder = -join [char[]](0x05D1, 0x05DF, 0x0020, 0x05D2, 0x05D5, 0x05DC, 0x05D3)
    $script:HebrewText = -join [char[]](0x05E2, 0x05D3, 0x05DB, 0x05D5, 0x05DF)

    # A COM-style collection: Count and Item(i), nothing else (no enumeration).
    function New-FakeCollection {
      param([object[]]$Items = @())
      $c = [pscustomobject]@{ Items = @($Items) }
      $c | Add-Member -MemberType ScriptProperty -Name Count -Value { @($this.Items).Count }
      $c | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) @($this.Items)[$i] }
      return $c
    }

    # A COM-style IUpdate. AcceptEula only counts its calls on the object itself.
    function New-FakeUpdate {
      param(
        [string]$Id,
        [string[]]$Cats = @(),
        [string]$CatName = 'Category',
        [bool]$Ui = $false,
        [bool]$Eula = $true,
        [bool]$Downloaded = $false,
        [string]$Title
      )
      if (-not $Title) { $Title = "Update $Id" }
      $categories = @(foreach ($c in $Cats) { [pscustomobject]@{ CategoryID = $c; Name = $CatName } })
      $u = [pscustomobject]@{
        Identity             = [pscustomobject]@{ UpdateID = $Id; RevisionNumber = 1 }
        Title                = $Title
        KBArticleIDs         = (New-FakeCollection -Items @('5000001'))
        Categories           = (New-FakeCollection -Items $categories)
        InstallationBehavior = [pscustomobject]@{ CanRequestUserInput = $Ui }
        EulaAccepted         = $Eula
        IsDownloaded         = $Downloaded
        EulaCalls            = 0
      }
      $u | Add-Member -MemberType ScriptMethod -Name AcceptEula -Value { $this.EulaCalls++; $this.EulaAccepted = $true }
      return $u
    }

    # A state.json inside $TestDrive for the child to read. Returns its path.
    function New-WuStateFile {
      param([int]$Rounds = 2, [hashtable]$FailureCounts = @{}, [string[]]$PreviousHidden = @())
      $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      $state = New-RunState -Machine @{ IsWindows10 = $false } -Choices @{} -Plan @('windows-update') -Version 'test'
      $state.Steps['windows-update'].Data = @{ Rounds = $Rounds }
      $state.WuFailureCounts = $FailureCounts
      $state.PreviousHiddenUpdateIds = [string[]]@($PreviousHidden)
      Save-RunState -State $state -Root $root
      return (Join-Path $root 'state.json')
    }

    # Runs the child round against a state file and returns its parsed result JSON.
    function Invoke-TestRound {
      param([string]$StatePath, [int]$FailuresBeforeHide = 2, [bool]$IsWindows10 = $false, [switch]$SearchOnly)
      $script:roundResultPath = Join-Path (Split-Path -Parent $StatePath) 'Logs\wu-round.json'
      Invoke-WuRound -StatePath $StatePath -ResultPath $script:roundResultPath -FailuresBeforeHide $FailuresBeforeHide -IsWindows10 $IsWindows10 -SearchOnly:$SearchOnly
      return ([IO.File]::ReadAllText($script:roundResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }

    # A step Context whose state has the windows-update step; the folder name is configurable.
    function New-WuContext {
      param([hashtable]$Data = @{}, [hashtable]$FailureCounts = @{}, [string[]]$Hidden = @(), [string]$Folder = 'Setup')
      $root = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) $Folder
      $state = New-RunState -Machine @{ IsWindows10 = $false } -Choices @{} -Plan @('windows-update') -Version 'test'
      $state.Steps['windows-update'].Data = $Data
      $state.WuFailureCounts = $FailureCounts
      $state.HiddenUpdateIds = [string[]]@($Hidden)
      @{
        Config      = ($script:WuConfigJson | ConvertFrom-Json)
        State       = $state
        Root        = $root
        LogDir      = (Join-Path $root 'Logs')
        DownloadDir = (Join-Path $root 'Downloads')
        ScriptPath  = (Join-Path $root 'setup.ps1')
        StatePath   = (Join-Path $root 'state.json')
      }
    }

    # What a child round writes, as Invoke-WuRound builds it.
    function New-ChildResult {
      param([object[]]$Installed = @(), [object[]]$Failed = @(), [string[]]$Hidden = @(), [bool]$OnlyDefinitions = $false, [bool]$RebootRequired = $false, $ErrorText = $null)
      [ordered]@{ Installed = @($Installed); Failed = @($Failed); Hidden = [string[]]@($Hidden); OnlyDefinitions = $OnlyDefinitions; RebootRequired = $RebootRequired; Error = $ErrorText }
    }
  }

  Context 'COM-shaped input and pure helpers' {
    It 'reads id, title, KBs, category GUIDs and the user-input flag from a COM-style update' {
      $info = ConvertTo-WuUpdateInfo -Update (New-FakeUpdate -Id 'id-1' -Cats @('cat-a', $script:upg) -Ui $true -Title 'Title 1')
      $info.Id | Should -Be 'id-1'
      $info.Title | Should -Be 'Title 1'
      $info.KBs | Should -Be @('5000001')
      $info.CategoryIds | Should -Be @('cat-a', $script:upg)
      $info.CanRequestUserInput | Should -BeTrue
    }
    It 'reads an update with no categories as an empty list' {
      $info = ConvertTo-WuUpdateInfo -Update (New-FakeUpdate -Id 'id-2')
      @($info.CategoryIds).Count | Should -Be 0
      $info.CanRequestUserInput | Should -BeFalse
    }
    It 'matches the upgrade category by GUID only, never by its (localized) name' {
      $byGuid = ConvertTo-WuUpdateInfo -Update (New-FakeUpdate -Id 'g' -Cats @($script:upg) -CatName $script:HebrewText)
      $byName = ConvertTo-WuUpdateInfo -Update (New-FakeUpdate -Id 'n' -Cats @('11111111-2222-3333-4444-555555555555') -CatName 'Upgrades')
      $sel = Select-WuUpdates -Updates @($byGuid, $byName) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $true
      $sel.Skip.Id | Should -Be @('g')
      $sel.Install.Id | Should -Be @('n')
    }
    It 'returns empty arrays, never $null, when there is nothing' {
      $sel = Select-WuUpdates -Updates @() -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false
      foreach ($k in 'Install', 'Hide', 'Skip') { ($sel[$k] -is [array]) | Should -BeTrue; $sel[$k].Count | Should -Be 0 }
      $sel.OnlyDefinitions | Should -BeFalse
    }
    It 'is not definitions-only when something else is installed too' {
      (Select-WuUpdates -Updates @((U d @($script:defs)), (U x)) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false).OnlyDefinitions | Should -BeFalse
    }
    It 'continues when the result carries an error' {
      Get-WuRoundOutcome -Result ([pscustomobject]@{ Installed = @(); Failed = @(); OnlyDefinitions = $false; Error = 'x' }) | Should -Be 'Continue'
    }
    It 'builds the software criteria' {
      Get-WuSearchCriteria -Type Software | Should -Be $script:SoftwareCriteria
    }
  }

  Context 'Register-MicrosoftUpdateService' {
    BeforeEach {
      Mock Write-SetupLog { }
      $script:manager = [pscustomobject]@{ Services = $null; AddCalls = (New-Object System.Collections.ArrayList) }
      $script:manager | Add-Member -MemberType ScriptMethod -Name AddService2 -Value {
        param($ServiceId, $Flags, $AuthorizationCab)
        [void]$this.AddCalls.Add(@($ServiceId, $Flags, $AuthorizationCab))
        return [pscustomobject]@{ Service = $null }
      }
      Mock New-WuServiceManager { $script:manager }
    }
    It 'registers Microsoft Update (flags 7, no cab) when it is absent' {
      $script:manager.Services = New-FakeCollection -Items @([pscustomobject]@{ ServiceID = '9482f4b4-e343-43b6-b170-9a65bc822c77' })
      Register-MicrosoftUpdateService
      $script:manager.AddCalls.Count | Should -Be 1
      $script:manager.AddCalls[0][0] | Should -Be $script:MuId
      $script:manager.AddCalls[0][1] | Should -Be 7
      $script:manager.AddCalls[0][2] | Should -Be ''
    }
    It 'does nothing when Microsoft Update is already registered' {
      $script:manager.Services = New-FakeCollection -Items @([pscustomobject]@{ ServiceID = 'other' }, [pscustomobject]@{ ServiceID = $script:MuId })
      Register-MicrosoftUpdateService
      $script:manager.AddCalls.Count | Should -Be 0
    }
  }

  Context 'Invoke-WuRound (child round, COM mocked)' {
    BeforeEach {
      $script:searches = New-Object System.Collections.ArrayList
      $script:searchResults = @{}
      $script:searchError = $null
      $script:hideCalls = New-Object System.Collections.ArrayList
      $script:downloadCalls = New-Object System.Collections.ArrayList
      $script:downloadCodes = @{}
      $script:installCalls = New-Object System.Collections.ArrayList
      $script:installCodes = @{}
      $script:installReboot = $false
      $script:systemReboot = $false
      $script:registerCalls = 0
      $script:registered = $true
      $script:registeredChecks = 0

      Mock Write-SetupLog { }
      Mock New-WuSession { [pscustomobject]@{ Name = 'fake session' } }
      Mock Register-MicrosoftUpdateService { $script:registerCalls++ }
      Mock New-WuServiceManager { [pscustomobject]@{ Name = 'fake manager' } }
      Mock Test-WuServiceRegistered { $script:registeredChecks++; return $script:registered }
      Mock Search-WuUpdates {
        [void]$script:searches.Add($Criteria)
        if ($script:searchError) { throw $script:searchError }
        if ($script:searchResults.Contains($Criteria)) { $script:searchResults[$Criteria] }
      }
      Mock Set-WuHidden { [void]$script:hideCalls.Add(@{ Id = [string]$Update.Identity.UpdateID; Hidden = $Hidden }) }
      Mock Invoke-WuDownload {
        $ids = @(foreach ($u in $Updates) { [string]$u.Identity.UpdateID })
        [void]$script:downloadCalls.Add($ids)
        foreach ($id in $ids) { if ($script:downloadCodes.Contains($id)) { $script:downloadCodes[$id] } else { 2 } }
      }
      Mock Invoke-WuInstall {
        $ids = @(foreach ($u in $Updates) { [string]$u.Identity.UpdateID })
        [void]$script:installCalls.Add($ids)
        $codes = @(foreach ($id in $ids) { if ($script:installCodes.Contains($id)) { $script:installCodes[$id] } else { 2 } })
        return @{ ResultCodes = $codes; RebootRequired = $script:installReboot }
      }
      Mock Get-WuRebootRequired { return $script:systemReboot }
    }

    It 'registers Microsoft Update, then searches software and drivers' {
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:registerCalls | Should -Be 1
      @($script:searches) | Should -Be @($script:SoftwareCriteria, $script:DriverCriteria)
      $r.Error | Should -BeNullOrEmpty
    }
    It 'installs software and driver updates and lists them' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 's1'))
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:installCalls[0] | Should -Be @('s1', 'd1')
      @($r.Installed.Id) | Should -Be @('s1', 'd1')
      @($r.Installed.Title) | Should -Be @('Update s1', 'Update d1')
      @($r.Failed).Count | Should -Be 0
    }
    It 'un-hides the previous run''s hidden updates in round 1' {
      $script:searchResults['IsHidden=1'] = @((New-FakeUpdate -Id 'p1'), (New-FakeUpdate -Id 'p9'))
      $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1 -PreviousHidden @('p1'))
      $script:searches[0] | Should -Be 'IsHidden=1'
      $script:hideCalls.Count | Should -Be 1
      $script:hideCalls[0].Id | Should -Be 'p1'
      $script:hideCalls[0].Hidden | Should -BeFalse
    }
    It 'does not un-hide anything after round 1' {
      $script:searchResults['IsHidden=1'] = @((New-FakeUpdate -Id 'p1'))
      $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 2 -PreviousHidden @('p1'))
      $script:searches -contains 'IsHidden=1' | Should -BeFalse
      $script:hideCalls.Count | Should -Be 0
    }
    It 'hides updates that failed too often and installs the rest' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'h'), (New-FakeUpdate -Id 'i'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile -FailureCounts @{ h = 2; i = 1 })
      $script:hideCalls.Count | Should -Be 1
      $script:hideCalls[0].Id | Should -Be 'h'
      $script:hideCalls[0].Hidden | Should -BeTrue
      @($r.Hidden) | Should -Be @('h')
      $script:installCalls[0] | Should -Be @('i')
    }
    It 'skips updates that can ask for user input' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'ui' -Ui $true), (New-FakeUpdate -Id 'ok'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:installCalls[0] | Should -Be @('ok')
      @($r.Installed.Id) | Should -Be @('ok')
    }
    It 'accepts the EULA of updates that need it, before downloading' {
      $needs = New-FakeUpdate -Id 'e1' -Eula $false
      $has = New-FakeUpdate -Id 'e2' -Eula $true
      $script:searchResults[$script:SoftwareCriteria] = @($needs, $has)
      $null = Invoke-TestRound -StatePath (New-WuStateFile)
      $needs.EulaCalls | Should -Be 1
      $has.EulaCalls | Should -Be 0
    }
    It 'maps install result codes: 2 and 3 installed, 4 and 5 failed' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b'), (New-FakeUpdate -Id 'c'), (New-FakeUpdate -Id 'd'))
      $script:installCodes = @{ a = 2; b = 3; c = 4; d = 5 }
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      @($r.Installed.Id) | Should -Be @('a', 'b')
      @($r.Failed.Id) | Should -Be @('c', 'd')
      @($r.Failed.ResultCode) | Should -Be @(4, 5)
      @($r.Failed.Title) | Should -Be @('Update c', 'Update d')
    }
    It 'counts a failed download as failed and does not install it' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'x'), (New-FakeUpdate -Id 'y'))
      $script:downloadCodes = @{ x = 4 }
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:installCalls[0] | Should -Be @('y')
      @($r.Failed.Id) | Should -Be @('x')
      @($r.Failed.ResultCode) | Should -Be @(4)
      @($r.Installed.Id) | Should -Be @('y')
    }
    It 'does not download what is already downloaded' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'dl' -Downloaded $true), (New-FakeUpdate -Id 'nd'))
      $null = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:downloadCalls.Count | Should -Be 1
      $script:downloadCalls[0] | Should -Be @('nd')
      $script:installCalls[0] | Should -Be @('dl', 'nd')
    }
    It 'downloads and installs nothing when nothing is selected' {
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:downloadCalls.Count | Should -Be 0
      $script:installCalls.Count | Should -Be 0
      @($r.Installed).Count | Should -Be 0
    }
    It 'needs a restart when the install result says so' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $script:installReboot = $true
      (Invoke-TestRound -StatePath (New-WuStateFile)).RebootRequired | Should -BeTrue
    }
    It 'needs a restart when SystemInfo says so' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $script:systemReboot = $true
      (Invoke-TestRound -StatePath (New-WuStateFile)).RebootRequired | Should -BeTrue
    }
    It 'needs no restart when neither says so' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      (Invoke-TestRound -StatePath (New-WuStateFile)).RebootRequired | Should -BeFalse
    }
    It 'reports definitions-only rounds' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'def' -Cats @($script:defs)))
      (Invoke-TestRound -StatePath (New-WuStateFile)).OnlyDefinitions | Should -BeTrue
    }
    It 'skips the Windows 11 upgrade on Windows 10' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'up' -Cats @($script:upg)), (New-FakeUpdate -Id 'cu'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile) -IsWindows10 $true
      $script:installCalls[0] | Should -Be @('cu')
    }
    It 'keeps one-item lists as JSON arrays, with a Hebrew title intact' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'one' -Title $script:HebrewText), (New-FakeUpdate -Id 'two'), (New-FakeUpdate -Id 'hid'))
      $script:installCodes = @{ two = 4 }
      $r = Invoke-TestRound -StatePath (New-WuStateFile -FailureCounts @{ hid = 2 })
      ($r.Installed -is [array]) | Should -BeTrue
      ($r.Failed -is [array]) | Should -BeTrue
      ($r.Hidden -is [array]) | Should -BeTrue
      $r.Installed[0].Title | Should -Be $script:HebrewText
      # UTF-8 without a BOM.
      $bytes = [IO.File]::ReadAllBytes($script:roundResultPath)
      ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    }
    It '-SearchOnly lists the selection and changes nothing' {
      $script:searchResults['IsHidden=1'] = @((New-FakeUpdate -Id 'p1'))
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a' -Eula $false), (New-FakeUpdate -Id 'h'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1 -PreviousHidden @('p1') -FailureCounts @{ h = 2 }) -SearchOnly
      $script:registerCalls | Should -Be 0
      $script:registeredChecks | Should -Be 1
      $script:hideCalls.Count | Should -Be 0
      $script:downloadCalls.Count | Should -Be 0
      $script:installCalls.Count | Should -Be 0
      $script:searches -contains 'IsHidden=1' | Should -BeFalse
      @($r.Installed.Id) | Should -Be @('a')
      @($r.Hidden).Count | Should -Be 0
      @($r.Failed).Count | Should -Be 0
      $r.Error | Should -BeNullOrEmpty
    }
    It '-SearchOnly never registers Microsoft Update; it reports the missing registration' {
      $script:registered = $false
      $r = Invoke-TestRound -StatePath (New-WuStateFile) -SearchOnly
      $script:registerCalls | Should -Be 0
      $script:searches.Count | Should -Be 0
      $r.Error | Should -Match 'not registered'
    }
    It 'turns an exception into Error and still writes the JSON' {
      $script:searchError = 'search exploded (0x8024402C)'
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $r.Error | Should -Be 'search exploded (0x8024402C)'
      @($r.Installed).Count | Should -Be 0
      ($r.Installed -is [array]) | Should -BeTrue
    }
    It 'reports a missing state file as an Error in the JSON' {
      $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      $r = Invoke-TestRound -StatePath (Join-Path $dir 'state.json')
      $r.Error | Should -Match 'state'
      $script:searches.Count | Should -Be 0
    }
  }

  Context 'Invoke-StepWindowsUpdate (parent step, child process mocked)' {
    BeforeEach {
      $script:ext = New-Object System.Collections.ArrayList
      $script:childResult = New-ChildResult
      $script:childJson = $null
      $script:childTimedOut = $false
      $script:roundsSeenByChild = $null
      Mock Write-SetupLog { }
      Mock Invoke-External {
        [void]$script:ext.Add(@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes })
        $saved = Read-RunState -Root $script:ctx.Root
        if ($null -ne $saved) { $script:roundsSeenByChild = $saved.Steps['windows-update'].Data.Rounds }
        if ($script:childTimedOut) { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
        $path = [regex]::Match($ArgumentList, '-ResultPath "([^"]+)"').Groups[1].Value
        if ($null -ne $script:childJson) {
          [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
          [IO.File]::WriteAllText($path, $script:childJson, (New-Object Text.UTF8Encoding $false))
        } elseif ($null -ne $script:childResult) {
          Write-WuRoundResult -Path $path -Result $script:childResult
        }
        return @{ ExitCode = 0; TimedOut = $false; Output = '' }
      }
    }

    It 'continues with a restart when the round installed updates that need one' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'a'; Title = 'A' }) -RebootRequired $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'
      $r.Reboot | Should -Be 'Now'
      $r.Data.Rounds | Should -Be 1
      $r.Data.Installed | Should -Be 1
    }
    It 'continues without a restart when none is needed' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'a'; Title = 'A' })
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'
      $r.Reboot | Should -Be 'None'
    }
    It 'is Done with the running total when the round found nothing' {
      $script:ctx = New-WuContext -Data @{ Rounds = 2; Installed = 5 }
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Done'
      $r.Message | Should -Be 'Installed 5 updates in 3 rounds'
      $r.Reboot | Should -Be 'None'
    }
    It 'is Done when only definition updates were installed' {
      $script:ctx = New-WuContext -Data @{ Rounds = 1; Installed = 4 }
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'def'; Title = 'Defender' }) -OnlyDefinitions $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Done'
      $r.Message | Should -Be 'Installed 5 updates in 2 rounds'
    }
    It 'fails at the round cap without starting a round' {
      $script:ctx = New-WuContext -Data @{ Rounds = 6 }
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Windows Update round cap reached (6)'
      $script:ext.Count | Should -Be 0
    }
    It 'fails when the round times out' {
      $script:ctx = New-WuContext
      $script:childTimedOut = $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Windows Update round timed out'
    }
    It 'fails when the round wrote no result' {
      $script:ctx = New-WuContext
      $script:childResult = $null
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Windows Update round produced no result'
    }
    It 'fails when the result is not valid JSON' {
      $script:ctx = New-WuContext
      $script:childJson = '{"Installed": ['
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Windows Update round produced no result'
    }
    It 'never reads a stale result file left by an earlier run' {
      $script:ctx = New-WuContext
      [void][IO.Directory]::CreateDirectory($script:ctx.LogDir)
      Write-WuRoundResult -Path (Join-Path $script:ctx.LogDir 'wu-round1.json') -Result (New-ChildResult)
      $script:childResult = $null
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Windows Update round produced no result'
    }
    It 'fails with the round''s error' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -ErrorText 'boom (0x8024402C)'
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Windows Update error: boom (0x8024402C)'
    }
    It 'still records what the round hid when it reports an error' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -Hidden @('h1') -ErrorText 'download failed'
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      @($script:ctx.State.HiddenUpdateIds) | Should -Be @('h1')
    }
    It 'counts failures per update id' {
      $script:ctx = New-WuContext -FailureCounts @{ a = 1 }
      $script:childResult = New-ChildResult -Failed @([ordered]@{ Id = 'a'; Title = 'A'; ResultCode = 4 }, [ordered]@{ Id = 'b'; Title = 'B'; ResultCode = 5 })
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx.State.WuFailureCounts['a'] | Should -Be 2
      $script:ctx.State.WuFailureCounts['b'] | Should -Be 1
    }
    It 'appends hidden ids without duplicates' {
      $script:ctx = New-WuContext -Hidden @('x')
      $script:childResult = New-ChildResult -Hidden @('x', 'y', 'y') -Installed @([ordered]@{ Id = 'z'; Title = 'Z' })
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      @($script:ctx.State.HiddenUpdateIds) | Should -Be @('x', 'y')
    }
    It 'records failed titles by id, Hebrew included' {
      $script:ctx = New-WuContext -Data @{ FailedTitles = @{ old = 'Old' } }
      $script:childResult = New-ChildResult -Failed @([ordered]@{ Id = 'a'; Title = $script:HebrewText; ResultCode = 4 })
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Data.FailedTitles['a'] | Should -Be $script:HebrewText
      $r.Data.FailedTitles['old'] | Should -Be 'Old'
      $script:ctx.State.Steps['windows-update'].Data.FailedTitles['a'] | Should -Be $script:HebrewText
    }
    It 'starts the round with the exact command line, quoted for a Hebrew path with spaces' {
      $script:ctx = New-WuContext -Folder $script:HebrewFolder
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ext.Count | Should -Be 1
      $script:ext[0].FilePath | Should -Be $script:PowerShellExe
      $expected = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -WuRound -ResultPath "{1}"' -f $script:ctx.ScriptPath, (Join-Path $script:ctx.LogDir 'wu-round1.json')
      $script:ext[0].ArgumentList | Should -Be $expected
      $script:ext[0].TimeoutMinutes | Should -Be 90
    }
    It 'saves the incremented round to state.json before the child starts' {
      $script:ctx = New-WuContext -Data @{ Rounds = 3 }
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:roundsSeenByChild | Should -Be 4
    }
    It 'leaves the runner''s Interruptions counter alone' {
      $script:ctx = New-WuContext -Data @{ Interruptions = 1 }
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Data.ContainsKey('Interruptions') | Should -BeFalse
      $script:ctx.State.Steps['windows-update'].Data['Interruptions'] | Should -Be 1
    }
  }
}
