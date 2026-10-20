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
Describe 'Select-WuUpdates: drivers and firmware (spec 9.2)' {
  BeforeAll { function D($id, [string]$class = 'System', [bool]$ui = $true) { [pscustomobject]@{ Id = $id; Title = $id; KBs = @(); CategoryIds = @(); CanRequestUserInput = $ui; IsDriver = $true; DriverClass = $class } } }
  It 'installs a driver that can ask for input' { (Select-WuUpdates -Updates @((D drv)) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false).Install.Id | Should -Be @('drv') }
  It 'still skips a software update that can ask for input' { (Select-WuUpdates -Updates @((U sw @() $true)) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false).Skip.Id | Should -Be @('sw') }
  It 'installs firmware on AC' { (Select-WuUpdates -Updates @((D fw 'Firmware')) -FailureCounts @{} -FailuresBeforeHide 2 -IsWindows10 $false -OnAC $true).Install.Id | Should -Be @('fw') }
  It 'defers firmware on battery: not installed, not hidden even after failures' {
    $r = Select-WuUpdates -Updates @((D fw 'firmware'), (D net 'Net')) -FailureCounts @{ fw = 5 } -FailuresBeforeHide 2 -IsWindows10 $false -OnAC $false
    $r.Deferred.Id | Should -Be @('fw'); @($r.Hide).Count | Should -Be 0; $r.Install.Id | Should -Be @('net')
  }
  It 'a driver that failed too often is still hidden (R24)' { (Select-WuUpdates -Updates @((D bad)) -FailureCounts @{ bad = 2 } -FailuresBeforeHide 2 -IsWindows10 $false).Hide.Id | Should -Be @('bad') }
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
    foreach ($f in 'StepResult', 'Logging', 'Activity', 'Process') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
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
      param([string]$StatePath, [int]$FailuresBeforeHide = 2, [bool]$IsWindows10 = $false, [switch]$SearchOnly, [bool]$OnAC = $true, [string]$InstallMode = 'Batch')
      $script:roundResultPath = Join-Path (Split-Path -Parent $StatePath) 'Logs\wu-round.json'
      Invoke-WuRound -StatePath $StatePath -ResultPath $script:roundResultPath -FailuresBeforeHide $FailuresBeforeHide -IsWindows10 $IsWindows10 -SearchOnly:$SearchOnly -OnAC $OnAC -InstallMode $InstallMode
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
      param([object[]]$Installed = @(), [object[]]$Failed = @(), [string[]]$Hidden = @(), [string[]]$HideFailed = @(), [bool]$OnlyDefinitions = $false, [bool]$RebootRequired = $false, $ErrorText = $null, $ErrorCode = $null)
      [ordered]@{ Installed = @($Installed); Failed = @($Failed); Hidden = [string[]]@($Hidden); HideFailed = [string[]]@($HideFailed); OnlyDefinitions = $OnlyDefinitions; RebootRequired = $RebootRequired; Error = $ErrorText; ErrorCode = $ErrorCode }
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
    It 'Approve-WuEula calls AcceptEula on the update' {
      $u = New-FakeUpdate -Id 'e' -Eula $false
      Approve-WuEula -Update $u
      $u.EulaCalls | Should -Be 1
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
      $script:installThrow = $null
      $script:installHResult = 0
      $script:downloadHResult = 0
      $script:systemReboot = $false
      $script:systemRebootThrow = $null
      $script:hideThrowFor = @{}
      $script:eulaApproved = New-Object System.Collections.ArrayList
      $script:registerCalls = 0
      $script:registered = $true
      $script:registeredChecks = 0
      $script:logs = New-Object System.Collections.ArrayList

      Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
      Mock Approve-WuEula { [void]$script:eulaApproved.Add([string]$Update.Identity.UpdateID) }
      Mock New-WuSession { [pscustomobject]@{ Name = 'fake session' } }
      Mock Register-MicrosoftUpdateService { $script:registerCalls++ }
      Mock New-WuServiceManager { [pscustomobject]@{ Name = 'fake manager' } }
      Mock Test-WuServiceRegistered { $script:registeredChecks++; return $script:registered }
      Mock Search-WuUpdates {
        [void]$script:searches.Add($Criteria)
        if ($script:searchError) { throw $script:searchError }
        if ($script:searchResults.Contains($Criteria)) { $script:searchResults[$Criteria] }
      }
      Mock Set-WuHidden {
        $id = [string]$Update.Identity.UpdateID
        [void]$script:hideCalls.Add(@{ Id = $id; Hidden = $Hidden })
        if ($script:hideThrowFor.Contains($id)) { throw $script:hideThrowFor[$id] }
      }
      Mock Invoke-WuDownload {
        $ids = @(foreach ($u in $Updates) { [string]$u.Identity.UpdateID })
        [void]$script:downloadCalls.Add($ids)
        $codes = @(foreach ($id in $ids) { if ($script:downloadCodes.Contains($id)) { $script:downloadCodes[$id] } else { 2 } })
        return @{ ResultCodes = $codes; HResult = $script:downloadHResult }
      }
      Mock Invoke-WuInstall {
        $ids = @(foreach ($u in $Updates) { [string]$u.Identity.UpdateID })
        [void]$script:installCalls.Add($ids)
        if ($null -ne $script:installThrow) { throw $script:installThrow }
        $codes = @(foreach ($id in $ids) { if ($script:installCodes.Contains($id)) { $script:installCodes[$id] } else { 2 } })
        return @{ ResultCodes = $codes; RebootRequired = $script:installReboot; HResult = $script:installHResult }
      }
      Mock Get-WuRebootRequired {
        if ($null -ne $script:systemRebootThrow) { throw $script:systemRebootThrow }
        return $script:systemReboot
      }
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
    It 'accepts the EULA (Approve-WuEula) only of updates that need it' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'e1' -Eula $false), (New-FakeUpdate -Id 'e2' -Eula $true))
      $null = Invoke-TestRound -StatePath (New-WuStateFile)
      @($script:eulaApproved) | Should -Be @('e1')
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

    # Ruling R23: the numeric code next to the text.
    It 'writes the ErrorCode of a COM exception next to its text' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $script:installThrow = New-Object Runtime.InteropServices.COMException('x', 0x80240016)
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $r.Error | Should -Be 'x'
      $r.ErrorCode | Should -Be '0x80240016'
    }
    It 'finds the COM code inside a PowerShell wrapper exception' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $com = New-Object Runtime.InteropServices.COMException('inner', 0x8024A000)
      $script:installThrow = New-Object System.Management.Automation.MethodInvocationException('Exception calling "Install" with "0" argument(s): "inner"', $com)
      (Invoke-TestRound -StatePath (New-WuStateFile)).ErrorCode | Should -Be '0x8024A000'
    }
    It 'writes the outer code for a non-COM exception' {
      $script:searchError = 'plain failure'
      (Invoke-TestRound -StatePath (New-WuStateFile)).ErrorCode | Should -Match '^0x[0-9A-F]{8}$'
    }
    It 'records the installation result''s own HResult without turning it into an Error' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b'))
      $script:installCodes = @{ b = 4 }
      $script:installHResult = 0x80242014
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $r.ErrorCode | Should -Be '0x80242014'
      $r.Error | Should -BeNullOrEmpty
      @($r.Installed.Id) | Should -Be @('a')
      @($r.Failed.Id) | Should -Be @('b')
    }
    It 'records the download result''s own HResult when no install ran' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $script:downloadCodes = @{ a = 4 }
      $script:downloadHResult = 0x80240016
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:installCalls.Count | Should -Be 0
      $r.ErrorCode | Should -Be '0x80240016'
    }
    It 'ignores a leftover download code once the installs ran cleanly' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b'))
      $script:downloadCodes = @{ b = 4 }
      $script:downloadHResult = 0x80240016
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:installCalls[0] | Should -Be @('a')
      $r.ErrorCode | Should -BeNullOrEmpty
      @($r.Installed.Id) | Should -Be @('a')
    }
    It 'prefers the installation''s code over the download''s' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $script:downloadHResult = 0x80240016
      $script:installHResult = 0x80242014
      (Invoke-TestRound -StatePath (New-WuStateFile)).ErrorCode | Should -Be '0x80242014'
    }

    # Ruling R24a: SystemInfo is read on every path.
    It 'reads the restart flag even when the round threw' {
      $script:searchError = 'busy (0x80240016)'
      $script:systemReboot = $true
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $r.Error | Should -Be 'busy (0x80240016)'
      $r.RebootRequired | Should -BeTrue
    }
    It 'does not turn an unreadable restart flag into an error' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $script:installReboot = $true
      $script:systemRebootThrow = New-Object Runtime.InteropServices.COMException('no sysinfo', 0x80004005)
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $r.Error | Should -BeNullOrEmpty
      $r.RebootRequired | Should -BeTrue
      @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Data.errorCode -eq '0x80004005' }).Count | Should -Be 1
    }

    # Ruling R24b: an update that cannot be hidden does not abort the round.
    It 'goes on when an update cannot be hidden, and lists it in HideFailed' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'h'), (New-FakeUpdate -Id 'i'))
      $script:hideThrowFor['h'] = New-Object Runtime.InteropServices.COMException('not hideable', 0x80248016)
      $r = Invoke-TestRound -StatePath (New-WuStateFile -FailureCounts @{ h = 2 })
      $r.Error | Should -BeNullOrEmpty
      @($r.HideFailed) | Should -Be @('h')
      ($r.HideFailed -is [array]) | Should -BeTrue
      @($r.Hidden).Count | Should -Be 0
      $script:downloadCalls[0] | Should -Be @('i')
      $script:installCalls[0] | Should -Be @('i')
      @($r.Installed.Id) | Should -Be @('i')
      @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Data.errorCode -eq '0x80248016' -and $_.Data.id -eq 'h' }).Count | Should -Be 1
    }

    # Ruling R24c support: definition updates are flagged so they are never counted as re-offers.
    It 'flags definition updates in the Installed list' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'def' -Cats @($script:defs)), (New-FakeUpdate -Id 'cu'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      @($r.Installed | Where-Object { $_.Id -eq 'def' })[0].IsDefinition | Should -BeTrue
      @($r.Installed | Where-Object { $_.Id -eq 'cu' })[0].IsDefinition | Should -BeFalse
    }
    It 'has no ErrorCode when the round went well' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $r.PSObject.Properties['ErrorCode'] | Should -Not -BeNullOrEmpty
      $r.ErrorCode | Should -BeNullOrEmpty
    }

    # Spec 9.2: drivers are installed even when they can ask for input; firmware only on AC.
    It 'installs driver updates that can ask for input; software ones stay skipped' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'sw' -Ui $true)); $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'drv' -Ui $true))
      $r = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:installCalls[0] | Should -Be @('drv'); @($r.Installed.Id) | Should -Be @('drv')
    }
    It 'leaves firmware alone on battery and counts it' {
      $fw = New-FakeUpdate -Id 'fw' -Ui $true; $fw | Add-Member NoteProperty DriverClass 'Firmware'
      $script:searchResults[$script:DriverCriteria] = @($fw, (New-FakeUpdate -Id 'net'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile -FailureCounts @{ fw = 3 }) -OnAC $false
      $script:installCalls[0] | Should -Be @('net'); $script:hideCalls.Count | Should -Be 0; $r.FirmwareDeferred | Should -Be 1
    }
    # Spec 9.2 "to prove on a real machine": every driver's class is in setup.log, on AC too.
    It 'logs each driver update found at INFO with its driverClass, and no such line for software' {
      $drv = New-FakeUpdate -Id 'drv' -Title 'Dell Firmware'; $drv | Add-Member NoteProperty DriverClass 'Firmware'
      $sw = New-FakeUpdate -Id 'sw'; $sw | Add-Member NoteProperty DriverClass 'Firmware'
      $script:searchResults[$script:SoftwareCriteria] = @($sw); $script:searchResults[$script:DriverCriteria] = @($drv)
      $null = Invoke-TestRound -StatePath (New-WuStateFile)
      $found = @($script:logs | Where-Object { $_.Message -eq 'Windows Update driver found' })
      $found.Count | Should -Be 1
      $found[0].Level | Should -Not -BeIn @('WARN', 'ERROR')    # INFO is the default level, which a mock does not bind
      $found[0].Data.id | Should -Be 'drv'; $found[0].Data.title | Should -Be 'Dell Firmware'; $found[0].Data.driverClass | Should -Be 'Firmware'
    }
    It 'reads DriverClass only from driver search results' {
      $sw = New-FakeUpdate -Id 'sw'; $sw | Add-Member NoteProperty DriverClass 'Firmware'
      $script:searchResults[$script:SoftwareCriteria] = @($sw)
      $r = Invoke-TestRound -StatePath (New-WuStateFile) -OnAC $false
      @($r.Installed.Id) | Should -Be @('sw'); $r.FirmwareDeferred | Should -Be 0
    }

    # Spec 4.5: one update at a time, so the parent can show "Installing 3 of 7". Inherits every COM mock
    # above; the download and install mocks are replaced by per-id ones.
    Context 'one at a time' {
      BeforeEach {
        $script:installHResultFor = @{}
        $script:downloadHResultFor = @{}
        $script:installRebootFor = @{}
        $script:installThrowFor = @{}
        Mock Invoke-WuDownload {
          $ids = @(foreach ($u in $Updates) { [string]$u.Identity.UpdateID })
          [void]$script:downloadCalls.Add($ids)
          $codes = @(foreach ($id in $ids) { if ($script:downloadCodes.Contains($id)) { $script:downloadCodes[$id] } else { 2 } })
          $hr = 0
          foreach ($id in $ids) { if ($script:downloadHResultFor.Contains($id)) { $hr = $script:downloadHResultFor[$id] } }
          return @{ ResultCodes = $codes; HResult = $hr }
        }
        Mock Invoke-WuInstall {
          $ids = @(foreach ($u in $Updates) { [string]$u.Identity.UpdateID })
          [void]$script:installCalls.Add($ids)
          foreach ($id in $ids) { if ($script:installThrowFor.Contains($id)) { throw $script:installThrowFor[$id] } }
          $codes = @(foreach ($id in $ids) { if ($script:installCodes.Contains($id)) { $script:installCodes[$id] } else { 2 } })
          $hr = 0
          $reboot = $false
          foreach ($id in $ids) {
            if ($script:installHResultFor.Contains($id)) { $hr = $script:installHResultFor[$id] }
            if ($script:installRebootFor.Contains($id)) { $reboot = [bool]$script:installRebootFor[$id] }
          }
          return @{ ResultCodes = $codes; RebootRequired = $reboot; HResult = $hr }
        }
      }

      It 'downloads and installs each update on its own, in search order' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 's1')); $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $script:downloadCalls.Count | Should -Be 2; $script:downloadCalls[0] | Should -Be @('s1'); $script:downloadCalls[1] | Should -Be @('d1')
        $script:installCalls.Count | Should -Be 2; $script:installCalls[0] | Should -Be @('s1'); $script:installCalls[1] | Should -Be @('d1')
        @($r.Installed.Id) | Should -Be @('s1', 'd1'); $r.Found | Should -Be 2; $r.Installed[0].Kb | Should -Be 'KB5000001'
      }
      It 'maps per-update codes the v1 way: 2 and 3 installed, 4 and 5 failed' {
        $script:searchResults[$script:SoftwareCriteria] = @('a','b','c','d' | ForEach-Object { New-FakeUpdate -Id $_ }); $script:installCodes = @{ a = 2; b = 3; c = 4; d = 5 }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        @($r.Installed.Id) | Should -Be @('a', 'b'); @($r.Failed.Id) | Should -Be @('c', 'd'); @($r.Failed.ResultCode) | Should -Be @(4, 5)
      }
      It 'a failed download is Failed with its code, is not installed, and the next update still runs' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'x'), (New-FakeUpdate -Id 'y')); $script:downloadCodes = @{ x = 4 }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $script:installCalls.Count | Should -Be 1; $script:installCalls[0] | Should -Be @('y'); @($r.Failed.ResultCode) | Should -Be @(4)
      }
      It 'skips the download of an update that is already downloaded' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'dl' -Downloaded $true))
        $null = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime; $script:downloadCalls.Count | Should -Be 0; $script:installCalls.Count | Should -Be 1
      }
      It 'ORs RebootRequired over the updates' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installRebootFor = @{ a = $true }
        (Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime).RebootRequired | Should -BeTrue
      }
      It 'ErrorCode is the first non-zero install HResult; a code that does not end the round lets the loop go on' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installHResultFor = @{ a = 0x80070643; b = 0x80070005 }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $script:installCalls.Count | Should -Be 2; $r.ErrorCode | Should -Be '0x80070643'; $r.Error | Should -BeNullOrEmpty
      }
      It 'stops at a round-ending install code (<_>): the rest are not attempted' -ForEach @(0x80240016, 0x8024A000, 0x80242014) {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installHResultFor = @{ a = $_ }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $script:installCalls.Count | Should -Be 1; $r.ErrorCode | Should -Be (Format-WuHResult -HResult $_)
        @($r.Installed.Id) + @($r.Failed.Id) | Should -Not -Contain 'b'
        $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
        $p.Updates[1].Status | Should -Be 'skipped'
      }
      It 'a round-ending download code stops the loop and is ErrorCode when no install ran after it' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:downloadHResultFor = @{ b = 0x80240016 }; $script:downloadCodes = @{ b = 4 }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $script:installCalls.Count | Should -Be 1; $r.ErrorCode | Should -Be '0x80240016'
      }
      It 'keeps what was done when the second install throws; Error and ErrorCode are set' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installThrowFor = @{ b = (New-Object Runtime.InteropServices.COMException('busy', 0x80240016)) }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        @($r.Installed.Id) | Should -Be @('a'); $r.Error | Should -Be 'busy'; $r.ErrorCode | Should -Be '0x80240016'
      }
      It 'writes the progress file: total, statuses, KB, size and phase done' {
        $u = New-FakeUpdate -Id 'a'; $u | Add-Member NoteProperty MaxDownloadSize ([decimal]52428800)
        $script:searchResults[$script:SoftwareCriteria] = @($u, (New-FakeUpdate -Id 'b')); $script:installCodes = @{ b = 4 }
        $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 2) -InstallMode OneAtATime
        $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
        $p.Round | Should -Be 2; $p.Mode | Should -Be 'OneAtATime'; $p.Phase | Should -Be 'done'; $p.Total | Should -Be 2
        @($p.Updates.Status) | Should -Be @('installed', 'failed'); $p.Updates[0].Kb | Should -Be 'KB5000001'; $p.Updates[0].SizeMB | Should -Be 50
      }
      It 'a progress file that cannot be written never breaks the round' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
        Mock Get-WuProgressPath { Join-Path $TestDrive 'no\such\folder\p.json' }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $r.Error | Should -BeNullOrEmpty; @($r.Installed.Id) | Should -Be @('a')
      }

      # Beyond the brief's list: the details the parent's NOW and the result rules depend on.
      It 'logs at most one WARN per round when the progress file cannot be written' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b'))
        Mock Get-WuProgressPath { Join-Path $TestDrive 'no\such\folder\p.json' }
        $null = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -match 'progress' }).Count | Should -Be 1
        Test-Path (Join-Path $TestDrive 'no') | Should -BeFalse
      }
      It 'shows the update being installed: phase installing, its 1-based number, status installing' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b'))
        $script:seenAtInstall = New-Object System.Collections.ArrayList
        Mock Invoke-WuInstall {
          $p = [IO.File]::ReadAllText((Get-WuProgressPath -ResultPath $script:roundResultPath)) | ConvertFrom-Json
          [void]$script:seenAtInstall.Add(('{0} {1} of {2}: {3}' -f $p.Phase, $p.Current, $p.Total, (@($p.Updates.Status) -join ',')))
          return @{ ResultCodes = @(2); RebootRequired = $false; HResult = 0 }
        }
        $null = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        @($script:seenAtInstall) | Should -Be @('installing 1 of 2: installing,pending', 'installing 2 of 2: installed,installing')
      }
      It 'writes phase done after an exception, and leaves no temporary file' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
        $script:installThrowFor = @{ a = (New-Object Runtime.InteropServices.COMException('busy', 0x80240016)) }
        $null = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $path = Get-WuProgressPath -ResultPath $script:roundResultPath
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).Phase | Should -Be 'done'
        Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
      }
      It 'never attempts or lists firmware left for later on battery' {
        $fw = New-FakeUpdate -Id 'fw'; $fw | Add-Member NoteProperty DriverClass 'Firmware'
        $script:searchResults[$script:DriverCriteria] = @($fw, (New-FakeUpdate -Id 'net'))
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime -OnAC $false
        @($script:installCalls | ForEach-Object { $_ }) | Should -Be @('net'); $r.FirmwareDeferred | Should -Be 1; $r.Found | Should -Be 2
        $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
        $p.Total | Should -Be 1; @($p.Updates.Title) | Should -Be @('Update net')
      }
      It 'an earlier non-zero install HResult stays ErrorCode when a later download ends the round' {
        $script:searchResults[$script:SoftwareCriteria] = @('a', 'b', 'c' | ForEach-Object { New-FakeUpdate -Id $_ })
        $script:installHResultFor = @{ a = 0x80070643 }; $script:downloadHResultFor = @{ b = 0x80240016 }; $script:downloadCodes = @{ b = 4 }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $r.ErrorCode | Should -Be '0x80070643'; @($script:downloadCalls | ForEach-Object { $_ }) | Should -Be @('a', 'b')
        @($r.Failed.Id) | Should -Be @('b'); @($r.Installed.Id) | Should -Be @('a')
        $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
        @($p.Updates.Status) | Should -Be @('installed', 'failed', 'skipped')
      }
      It 'when no install ran at all, ErrorCode is the first non-zero download HResult (v1 rule)' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b'))
        $script:downloadCodes = @{ a = 4; b = 4 }; $script:downloadHResultFor = @{ a = 0x80240022; b = 0x80070005 }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $script:downloadCalls.Count | Should -Be 2; $script:installCalls.Count | Should -Be 0; $r.ErrorCode | Should -Be '0x80240022'
      }
      It 'has no ErrorCode when every update went well' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b'))
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $r.ErrorCode | Should -BeNullOrEmpty; @($r.Installed.Id) | Should -Be @('a', 'b')
      }
    }
    It 'batch mode writes the phases and final statuses too' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b')); $script:installCodes = @{ b = 4 }
      $null = Invoke-TestRound -StatePath (New-WuStateFile)
      $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
      $p.Mode | Should -Be 'Batch'; $p.Phase | Should -Be 'done'; @($p.Updates.Status) | Should -Be @('installed', 'failed')
    }
    It 'batch mode marks a failed download failed and shows the install phase during the install' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'x'), (New-FakeUpdate -Id 'y')); $script:downloadCodes = @{ x = 4 }
      $script:seenAtInstall = $null
      Mock Invoke-WuInstall {
        $script:seenAtInstall = [IO.File]::ReadAllText((Get-WuProgressPath -ResultPath $script:roundResultPath)) | ConvertFrom-Json
        return @{ ResultCodes = @(2); RebootRequired = $false; HResult = 0 }
      }
      $null = Invoke-TestRound -StatePath (New-WuStateFile)
      $script:seenAtInstall.Phase | Should -Be 'installing'; @($script:seenAtInstall.Updates.Status) | Should -Be @('failed', 'pending')
      $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
      @($p.Updates.Status) | Should -Be @('failed', 'installed')
    }
  }

  Context 'Invoke-StepWindowsUpdate (parent step, child process mocked)' {
    BeforeEach {
      $script:ext = New-Object System.Collections.ArrayList
      $script:childResult = New-ChildResult
      $script:childJson = $null
      $script:childTimedOut = $false
      $script:roundsSeenByChild = $null
      $script:logs = New-Object System.Collections.ArrayList
      $script:sleeps = New-Object System.Collections.ArrayList
      Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
      Mock Start-Sleep { [void]$script:sleeps.Add($Seconds) }
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

    # Ruling R23: busy agent / restart pending are retried, by numeric code.
    It 'waits 120 seconds by default and continues without a restart when another install is running (<_>)' -ForEach @('0x80240016', '0x8024A000') {
      $code = $_
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -ErrorText 'x' -ErrorCode $code
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'
      $r.Reboot | Should -Be 'None'
      @($script:sleeps) | Should -Be @(120)
      $warns = @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -match 'busy' })
      $warns.Count | Should -Be 1
      $warns[0].Data.errorCode | Should -Be $code
    }
    It 'uses the injected busy wait' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -ErrorText 'x' -ErrorCode '0x80240016'
      $r = Invoke-StepWindowsUpdate -Context $script:ctx -BusyWaitSeconds 0
      $r.Status | Should -Be 'Continue'
      @($script:sleeps) | Should -Be @(0)
    }
    It 'matches the busy code whatever its letter case' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -ErrorText 'x' -ErrorCode '0x8024a000'
      (Invoke-StepWindowsUpdate -Context $script:ctx -BusyWaitSeconds 0).Status | Should -Be 'Continue'
    }
    It 'counts a busy round toward the cap, which still ends the loop' {
      $script:ctx = New-WuContext -Data @{ Rounds = 5 }
      $script:childResult = New-ChildResult -ErrorText 'x' -ErrorCode '0x80240016'
      $first = Invoke-StepWindowsUpdate -Context $script:ctx -BusyWaitSeconds 0
      $first.Status | Should -Be 'Continue'
      $first.Data.Rounds | Should -Be 6
      $second = Invoke-StepWindowsUpdate -Context $script:ctx -BusyWaitSeconds 0
      $second.Status | Should -Be 'Failed'
      $second.Message | Should -Be 'Windows Update round cap reached (6)'
      $script:ext.Count | Should -Be 1
    }
    # Ruling R23b: a busy / restart-pending round says nothing about whether an update is bad.
    It 'does not count failures on a <_> round, but still records titles and hidden ids' -ForEach @('0x80240016', '0x8024A000', '0x80242014') {
      $script:ctx = New-WuContext -FailureCounts @{ f1 = 1 }
      $script:childResult = New-ChildResult -Hidden @('h1') -Failed @([ordered]@{ Id = 'f1'; Title = 'F1'; ResultCode = 4 }, [ordered]@{ Id = 'f2'; Title = 'F2'; ResultCode = 4 }) -ErrorText 'x' -ErrorCode $_
      $r = Invoke-StepWindowsUpdate -Context $script:ctx -BusyWaitSeconds 0
      $script:ctx.State.WuFailureCounts['f1'] | Should -Be 1
      $script:ctx.State.WuFailureCounts.ContainsKey('f2') | Should -BeFalse
      $r.Data.FailedTitles['f1'] | Should -Be 'F1'
      $r.Data.FailedTitles['f2'] | Should -Be 'F2'
      @($script:ctx.State.HiddenUpdateIds) | Should -Be @('h1')
    }
    It 'still counts failures on a normal failure round' {
      $script:ctx = New-WuContext -FailureCounts @{ f1 = 1 }
      $script:childResult = New-ChildResult -Failed @([ordered]@{ Id = 'f1'; Title = 'F1'; ResultCode = 4 }, [ordered]@{ Id = 'f2'; Title = 'F2'; ResultCode = 5 })
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'
      $script:ctx.State.WuFailureCounts['f1'] | Should -Be 2
      $script:ctx.State.WuFailureCounts['f2'] | Should -Be 1
    }
    # Ruling R24a: busy because a mandatory restart is pending -> restart now, no wait.
    It 'restarts at once instead of waiting when busy and a restart is pending (<_>)' -ForEach @('0x80240016', '0x8024A000') {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -ErrorText 'x' -ErrorCode $_ -RebootRequired $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'
      $r.Reboot | Should -Be 'Now'
      $script:sleeps.Count | Should -Be 0
      @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -match 'restart' }).Count | Should -Be 1
    }

    # Ruling R24b: an update that cannot be hidden is red, once.
    It 'reports an update that could not be hidden in State.Errors, once across rounds' {
      $script:ctx = New-WuContext -Data @{ FailedTitles = @{ h = 'Stubborn update' } }
      $script:ctx.State.Errors = @('earlier error')
      $script:childResult = New-ChildResult -HideFailed @('h') -Installed @([ordered]@{ Id = 'a'; Title = 'A'; IsDefinition = $false })
      $first = Invoke-StepWindowsUpdate -Context $script:ctx
      $first.Status | Should -Be 'Continue'
      $script:childResult = New-ChildResult -HideFailed @('h')
      $second = Invoke-StepWindowsUpdate -Context $script:ctx
      $second.Status | Should -Be 'Done'
      @($script:ctx.State.Errors) | Should -Be @('earlier error', 'Windows update could not be hidden: Stubborn update')
      @($script:ctx.State.HiddenUpdateIds).Count | Should -Be 0
    }
    It 'names an update that could not be hidden by its id when there is no title' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -HideFailed @('id-9')
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      @($script:ctx.State.Errors) | Should -Be @('Windows update could not be hidden: id-9')
    }

    # Ruling R24c: an update offered again after a "successful" install is counted as a failure.
    It 'counts re-offers of an installed update and lets it be hidden' {
      $script:ctx = New-WuContext
      $again = New-ChildResult -Installed @([ordered]@{ Id = 'drv'; Title = 'Driver X'; IsDefinition = $false })
      $script:childResult = $again
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx.State.WuFailureCounts.ContainsKey('drv') | Should -BeFalse
      $script:ctx.State.Steps['windows-update'].Data.Installed | Should -Be 1
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx.State.WuFailureCounts['drv'] | Should -Be 1
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx.State.WuFailureCounts['drv'] | Should -Be 2
      $r.Data.Installed | Should -Be 1
      @($r.Data.InstalledIds) | Should -Be @('drv')
      $r.Data.FailedTitles['drv'] | Should -Be 'Driver X'
      # The next round's child hides it: two counts reach FailuresBeforeHide.
      (Select-WuUpdates -Updates @((U drv)) -FailureCounts $script:ctx.State.WuFailureCounts -FailuresBeforeHide 2 -IsWindows10 $false).Hide.Id | Should -Be @('drv')
    }
    It 'never counts a definition update installed again as a re-offer' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'def'; Title = 'Defender'; IsDefinition = $true }, [ordered]@{ Id = 'cu'; Title = 'CU'; IsDefinition = $false })
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'def'; Title = 'Defender'; IsDefinition = $true }) -OnlyDefinitions $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Done'
      $script:ctx.State.WuFailureCounts.ContainsKey('def') | Should -BeFalse
      $r.Data.Installed | Should -Be 3
    }

    # Ruling R24d: Done with failed updates carries a yellow Note.
    It 'is Done with a Note when a definitions-only round had a failed update' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -OnlyDefinitions $true -Installed @([ordered]@{ Id = 'd1'; Title = 'Defender A'; IsDefinition = $true }) -Failed @([ordered]@{ Id = 'd2'; Title = 'Defender B'; ResultCode = 4 })
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Done'
      @($r.Notes) | Should -Be @('Some Windows updates failed: Defender B')
    }
    It 'lists at most three failed titles in that Note, then an ellipsis' {
      $script:ctx = New-WuContext
      $failedList = @(foreach ($n in 'A', 'B', 'C', 'D') { [ordered]@{ Id = "id$n"; Title = "T$n"; ResultCode = 4 } })
      $script:childResult = New-ChildResult -OnlyDefinitions $true -Installed @([ordered]@{ Id = 'd1'; Title = 'Defender'; IsDefinition = $true }) -Failed $failedList
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      @($r.Notes) | Should -Be @('Some Windows updates failed: TA, TB, TC, ' + [char]0x2026)
    }
    It 'has no Note when a Done round had no failures' {
      $script:ctx = New-WuContext
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Done'
      @($r.Notes).Count | Should -Be 0
    }

    It 'still counts failures when the round fails with an unmapped code' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -Failed @([ordered]@{ Id = 'f1'; Title = 'F1'; ResultCode = 4 }) -ErrorText 'access denied' -ErrorCode '0x80070005'
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx.State.WuFailureCounts['f1'] | Should -Be 1
    }
    It 'restarts when earlier updates still need a restart (0x80242014)' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -ErrorText 'x' -ErrorCode '0x80242014'
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'
      $r.Reboot | Should -Be 'Now'
      $script:sleeps.Count | Should -Be 0
      @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -match 'restart' }).Count | Should -Be 1
    }
    It 'fails on any other code and carries it in the message' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -ErrorText 'access denied' -ErrorCode '0x80070005'
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Windows Update error: access denied (0x80070005)'
      $script:sleeps.Count | Should -Be 0
    }
    It 'lets the per-update results decide when a code comes without an Error' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -Failed @([ordered]@{ Id = 'f1'; Title = 'F1'; ResultCode = 4 }) -ErrorCode '0x80070643'
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'
      $script:ctx.State.WuFailureCounts['f1'] | Should -Be 1
    }

    # Spec 9.2: firmware left for later on battery carries the vendor pass's battery Note.
    It 'adds the battery Note when the round left firmware for later' {
      $script:ctx = New-WuContext; $res = New-ChildResult; $res['FirmwareDeferred'] = 2; $script:childResult = $res
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Done'; $r.Notes | Should -Contain 'On battery: BIOS/firmware updates skipped'
    }
    It 'adds the battery Note on a Continue round too, and none when nothing was deferred' {
      $script:ctx = New-WuContext; $res = New-ChildResult -Installed @([ordered]@{ Id = 'a'; Title = 'A'; IsDefinition = $false }); $res['FirmwareDeferred'] = 1; $script:childResult = $res
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'; @($r.Notes) | Should -Be @('On battery: BIOS/firmware updates skipped')
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'b'; Title = 'B'; IsDefinition = $false })
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'; @($r.Notes).Count | Should -Be 0
    }
    It 'uses the vendor pass''s exact battery text' { . "$PSScriptRoot\..\src\Steps\Vendor.ps1"; $script:WuBatteryNote | Should -BeExactly $script:BatteryNote }
  }
}

# Triage 233: the installer must never sit on a hidden prompt for the whole round. Invoke-WuInstall gets a
# fake session (plain objects, no COM); New-Object -ComObject is mocked, so no WUA object is ever created.
Describe 'Invoke-WuInstall (COM wrapper, fake session)' {
  BeforeAll {
    . "$PSScriptRoot\..\src\Common\Logging.ps1"
    . "$PSScriptRoot\..\src\Common\Activity.ps1"
    function New-FakeInstallerSession {
      param([switch]$RefuseQuiet)
      $script:installer = [pscustomobject]@{ Updates = $null; AllowSourcePrompts = $true; SeenAtInstall = $null }
      if ($RefuseQuiet) {
        $script:installer | Add-Member -MemberType ScriptProperty -Name ForceQuiet -Value { $false } -SecondValue { throw 'Access is denied.' }
      } else {
        $script:installer | Add-Member -MemberType NoteProperty -Name ForceQuiet -Value $false
      }
      $script:installer | Add-Member -MemberType ScriptMethod -Name Install -Value {
        $this.SeenAtInstall = @{ ForceQuiet = $this.ForceQuiet; AllowSourcePrompts = $this.AllowSourcePrompts; Updates = @($this.Updates.Items) }
        $result = [pscustomobject]@{ RebootRequired = $true; HResult = 0 }
        $result | Add-Member -MemberType ScriptMethod -Name GetUpdateResult -Value { param($i) [pscustomobject]@{ ResultCode = 2 + $i } } -PassThru
      }
      $session = [pscustomobject]@{}
      $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value { $script:installer } -PassThru
    }
  }
  BeforeEach {
    $script:logs = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level }) }
    # The most recently defined matching mock wins: the catch-all block first, the UpdateColl fake after it.
    Mock New-Object { throw "blocked by the test: New-Object $ComObject $TypeName" } -ParameterFilter { $ComObject }
    Mock New-Object {
      $coll = [pscustomobject]@{ Items = [System.Collections.ArrayList]::new() }
      $coll | Add-Member -MemberType ScriptMethod -Name Add -Value { param($u) $this.Items.Add($u) } -PassThru
    } -ParameterFilter { $ComObject -eq 'Microsoft.Update.UpdateColl' }
  }
  It 'sets ForceQuiet and turns AllowSourcePrompts off before Install()' {
    $r = Invoke-WuInstall -Session (New-FakeInstallerSession) -Updates @('u1', 'u2')
    $script:installer.SeenAtInstall.ForceQuiet | Should -BeTrue
    $script:installer.SeenAtInstall.AllowSourcePrompts | Should -BeFalse
    $script:installer.SeenAtInstall.Updates | Should -Be @('u1', 'u2')
    $r.ResultCodes | Should -Be @(2, 3)
    $r.RebootRequired | Should -BeTrue
    $r.HResult | Should -Be 0
  }
  It 'still installs (WARN) when the installer refuses one of the settings' {
    $r = Invoke-WuInstall -Session (New-FakeInstallerSession -RefuseQuiet) -Updates @('u1')
    $script:installer.SeenAtInstall | Should -Not -BeNullOrEmpty
    $script:installer.SeenAtInstall.AllowSourcePrompts | Should -BeFalse
    $r.ResultCodes | Should -Be @(2)
    @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -match 'ForceQuiet' }).Count | Should -Be 1
  }
}

# Spec 4.5: English titles where Windows allows it. New-Object -ComObject is mocked; no WUA object is created.
Describe 'New-WuSession' {
  BeforeAll {
    . "$PSScriptRoot\..\src\Common\Logging.ps1"
    . "$PSScriptRoot\..\src\Common\Activity.ps1"
  }
  It 'asks for English titles (UserLocale 1033)' {
    Mock New-Object { [pscustomobject]@{ ClientApplicationID = $null; UserLocale = 0 } } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
    $s = New-WuSession; $s.UserLocale | Should -Be 1033; $s.ClientApplicationID | Should -Be 'BenTech Setup'
  }
  It 'still returns the session when the locale is refused, with a WARN' {
    Mock Write-SetupLog { }
    Mock New-Object { $o = [pscustomobject]@{ ClientApplicationID = $null }; $o | Add-Member ScriptProperty UserLocale { 0 } { throw 'E_INVALIDARG' }; $o } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
    New-WuSession | Should -Not -BeNullOrEmpty; Should -Invoke Write-SetupLog -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'en-US' }
  }
}
Describe 'Get-WuInstallMode and Get-WuProgressPath' {
  BeforeAll {
    . "$PSScriptRoot\..\src\Common\Logging.ps1"
    . "$PSScriptRoot\..\src\Common\Activity.ps1"
  }
  BeforeEach { Mock Write-SetupLog { } }
  It 'defaults to OneAtATime, honours Batch, ignores nonsense' {
    Get-WuInstallMode -Config ([pscustomobject]@{}) | Should -Be 'OneAtATime'
    Get-WuInstallMode -Config ([pscustomobject]@{ windowsUpdate = [pscustomobject]@{ installMode = 'Batch' } }) | Should -Be 'Batch'
    Get-WuInstallMode -Config ([pscustomobject]@{ windowsUpdate = [pscustomobject]@{ installMode = 'Fast' } }) | Should -Be 'OneAtATime'
  }
  It 'derives the progress path from the result path' { Get-WuProgressPath -ResultPath 'C:\BenTech\Setup\Logs\wu-round2.json' | Should -Be 'C:\BenTech\Setup\Logs\wu-round2.progress.json' }
  It 'warns about an unknown mode only, and uses the canonical spelling' {
    Get-WuInstallMode -Config ([pscustomobject]@{ windowsUpdate = [pscustomobject]@{ installMode = 'batch' } }) | Should -BeExactly 'Batch'
    Get-WuInstallMode -Config ([pscustomobject]@{ windowsUpdate = [pscustomobject]@{} }) | Should -Be 'OneAtATime'
    Should -Invoke Write-SetupLog -Times 0 -Exactly
    Get-WuInstallMode -Config ([pscustomobject]@{ windowsUpdate = [pscustomobject]@{ installMode = 'Fast' } }) | Should -Be 'OneAtATime'
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Data.installMode -eq 'Fast' }
  }
}
# The progress file the parent's NOW reads (spec 4.5). Real file I/O inside $TestDrive only.
Describe 'Update-WuProgress' {
  BeforeAll {
    . "$PSScriptRoot\..\src\Common\Logging.ps1"
    . "$PSScriptRoot\..\src\Common\Activity.ps1"
    function New-TestProgress {
      [ordered]@{ Round = 1; Mode = 'OneAtATime'; Phase = 'searching'; Current = 0; Total = 2
                  Updates = @([ordered]@{ Kb = 'KB1'; Title = 'One'; SizeMB = 1.5; Status = 'pending' }, [ordered]@{ Kb = ''; Title = 'Two'; SizeMB = 0; Status = 'pending' })
                  UpdatedAt = $null }
    }
  }
  BeforeEach {
    $script:logs = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    $script:WuProgressWarned = $false
  }
  It 'sets the phase, the current number and one status, and writes UTF-8 JSON without a BOM' {
    $path = Join-Path $TestDrive 'p1.progress.json'; $progress = New-TestProgress
    Update-WuProgress -Path $path -Progress $progress -Phase 'installing' -Current 2 -Index 1 -Status 'installing'
    $bytes = [IO.File]::ReadAllBytes($path); ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    $p = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $p.Phase | Should -Be 'installing'; $p.Current | Should -Be 2; @($p.Updates.Status) | Should -Be @('pending', 'installing')
    $p.UpdatedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
  }
  It 'replaces an existing file and leaves no temporary file' {
    $path = Join-Path $TestDrive 'p2.progress.json'; $progress = New-TestProgress
    Update-WuProgress -Path $path -Progress $progress -Phase 'downloading'
    Update-WuProgress -Path $path -Progress $progress -Phase 'done'
    ([IO.File]::ReadAllText($path) | ConvertFrom-Json).Phase | Should -Be 'done'
    Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
  }
  It 'keeps a one-update list a JSON array' {
    $path = Join-Path $TestDrive 'p3.progress.json'; $progress = New-TestProgress; $progress.Updates = @($progress.Updates[0]); $progress.Total = 1
    Update-WuProgress -Path $path -Progress $progress
    ([IO.File]::ReadAllText($path) | ConvertFrom-Json).Updates -is [array] | Should -BeTrue
  }
  It 'never throws: an unwritable path is one WARN, however often it is tried' {
    $path = Join-Path $TestDrive 'missing\folder\p.progress.json'; $progress = New-TestProgress
    { Update-WuProgress -Path $path -Progress $progress -Phase 'downloading' } | Should -Not -Throw
    { Update-WuProgress -Path $path -Progress $progress -Phase 'installing' -Index 0 -Status 'installing' } | Should -Not -Throw
    @($script:logs | Where-Object { $_.Level -eq 'WARN' }).Count | Should -Be 1
    $progress.Phase | Should -Be 'installing'
  }
  It 'ignores an index outside the list' {
    $path = Join-Path $TestDrive 'p4.progress.json'; $progress = New-TestProgress
    { Update-WuProgress -Path $path -Progress $progress -Index 5 -Status 'failed' } | Should -Not -Throw
    @(([IO.File]::ReadAllText($path) | ConvertFrom-Json).Updates.Status) | Should -Be @('pending', 'pending')
  }
}
# Spec 4.5: the size and KB the progress file shows, and the KB on each Installed entry.
Describe 'ConvertTo-WuUpdateInfo SizeBytes and New-WuInstalledEntry Kb' {
  It 'reads MaxDownloadSize as SizeBytes; missing or unreadable is 0' {
    $u =[pscustomobject]@{ Identity = [pscustomobject]@{ UpdateID = 'a' }; Title = 'A'; KBArticleIDs = $null; Categories = $null; MaxDownloadSize = [decimal]1048576 }
    (ConvertTo-WuUpdateInfo -Update $u).SizeBytes | Should -Be 1048576
    $u2 = [pscustomobject]@{ Identity = [pscustomobject]@{ UpdateID = 'b' }; Title = 'B'; KBArticleIDs = $null; Categories = $null }
    (ConvertTo-WuUpdateInfo -Update $u2).SizeBytes | Should -Be 0
    $u3 = [pscustomobject]@{ Identity = [pscustomobject]@{ UpdateID = 'c' }; Title = 'C'; KBArticleIDs = $null; Categories = $null }
    $u3 | Add-Member ScriptProperty MaxDownloadSize { throw 'E_FAIL' }
    (ConvertTo-WuUpdateInfo -Update $u3).SizeBytes | Should -Be 0
  }
  It 'Kb is KB plus the first KB article, or empty' {
    (New-WuInstalledEntry -Info ([pscustomobject]@{ Id = 'a'; Title = 'A'; KBs = @('5070001', '5070002'); CategoryIds = @() })).Kb | Should -Be 'KB5070001'
    (New-WuInstalledEntry -Info ([pscustomobject]@{ Id = 'b'; Title = 'B'; KBs = @(); CategoryIds = @() })).Kb | Should -Be ''
  }
}
