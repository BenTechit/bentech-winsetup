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
Describe 'criteria' { It 'drivers' { Get-WuSearchCriteria -Type Driver | Should -Be "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Driver'" }
  It 'optional drivers' { Get-WuSearchCriteria -Type Driver -Optional | Should -Be "IsInstalled=0 and IsHidden=0 and BrowseOnly=1 and Type='Driver'" } }

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
    . "$PSScriptRoot\..\src\UI\StartScreen.ps1"   # ConvertTo-ScreenText, for the NOW provider
    . "$PSScriptRoot\..\src\Engine\Catalog.ps1"   # Get-WindowsUpdateChoice, for the parent step (wu spec 3.2)

    $script:WuConfigJson = [IO.File]::ReadAllText("$PSScriptRoot\..\config\config.json", [Text.Encoding]::UTF8)
    $script:MuId = '7971f918-a847-4430-9279-4a52d1efe18d'
    $script:SoftwareCriteria = "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Software'"
    $script:DriverCriteria = "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Driver'"
    $script:OptionalDriverCriteria = "IsInstalled=0 and IsHidden=0 and BrowseOnly=1 and Type='Driver'"
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
      param([int]$Rounds = 2, [hashtable]$FailureCounts = @{}, [string[]]$PreviousHidden = @(), [switch]$PreviousRestored)
      $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      $state = New-RunState -Machine @{ IsWindows10 = $false } -Choices @{} -Plan @('windows-update') -Version 'test'
      $state.Steps['windows-update'].Data = @{ Rounds = $Rounds }
      $state.WuFailureCounts = $FailureCounts
      $state.PreviousHiddenUpdateIds = [string[]]@($PreviousHidden)
      $state.PreviousHiddenRestored = [bool]$PreviousRestored
      Save-RunState -State $state -Root $root
      return (Join-Path $root 'state.json')
    }

    # Runs the child round against a state file and returns its parsed result JSON.
    function Invoke-TestRound {
      param([string]$StatePath, [int]$FailuresBeforeHide = 2, [bool]$IsWindows10 = $false, [switch]$SearchOnly, [bool]$OnAC = $true, [string]$InstallMode = 'Batch', [string]$Scope = 'FULL')
      $script:roundResultPath = Join-Path (Split-Path -Parent $StatePath) 'Logs\wu-round.json'
      Invoke-WuRound -StatePath $StatePath -ResultPath $script:roundResultPath -FailuresBeforeHide $FailuresBeforeHide -IsWindows10 $IsWindows10 -SearchOnly:$SearchOnly -OnAC $OnAC -InstallMode $InstallMode -Scope $Scope
      return ([IO.File]::ReadAllText($script:roundResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }

    # A step Context whose state has the windows-update step; the folder name is configurable.
    function New-WuContext {
      param([hashtable]$Data = @{}, [hashtable]$FailureCounts = @{}, [string[]]$Hidden = @(), [string]$Folder = 'Setup', [hashtable]$Choices = @{})
      $root = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) $Folder
      $state = New-RunState -Machine @{ IsWindows10 = $false } -Choices $Choices -Plan @('windows-update') -Version 'test'
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
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1 -PreviousHidden @('p1'))
      $script:searches[0] | Should -Be 'IsHidden=1'
      $script:hideCalls.Count | Should -Be 1
      $script:hideCalls[0].Id | Should -Be 'p1'
      $script:hideCalls[0].Hidden | Should -BeFalse
      $r.PreviousUnhideDone | Should -BeTrue
    }
    # Final review C1: once per run by a state flag, not "round 1 only", so a round 1 that failed before
    # the un-hide does not lose it for the whole run.
    It 'does not un-hide again once the state says it was done' {
      $script:searchResults['IsHidden=1'] = @((New-FakeUpdate -Id 'p1'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 2 -PreviousHidden @('p1') -PreviousRestored)
      $script:searches -contains 'IsHidden=1' | Should -BeFalse
      $script:hideCalls.Count | Should -Be 0
      $r.PreviousUnhideDone | Should -BeFalse
    }
    It 'un-hides in a later round when round 1 never got to it (no flag in the state)' {
      $script:searchResults['IsHidden=1'] = @((New-FakeUpdate -Id 'p1'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 2 -PreviousHidden @('p1'))
      $script:searches[0] | Should -Be 'IsHidden=1'
      @($script:hideCalls | ForEach-Object { '{0}={1}' -f $_.Id, $_.Hidden }) | Should -Be @('p1=False')
      $r.PreviousUnhideDone | Should -BeTrue
    }
    It 'a round that fails before the un-hide does not report it done' {
      Mock Register-MicrosoftUpdateService { throw 'Microsoft Update registration failed' }
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1 -PreviousHidden @('p1'))
      $r.Error | Should -Be 'Microsoft Update registration failed'
      $r.PreviousUnhideDone | Should -BeFalse
      $script:hideCalls.Count | Should -Be 0
    }
    It 'an update that cannot be un-hidden is a WARN; the round goes on and the un-hide counts as done' {
      $script:searchResults['IsHidden=1'] = @((New-FakeUpdate -Id 'p1'), (New-FakeUpdate -Id 'p2'))
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'))
      $script:hideThrowFor = @{ p1 = 'cannot un-hide' }
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1 -PreviousHidden @('p1', 'p2'))
      $r.Error | Should -BeNullOrEmpty; @($r.Installed.Id) | Should -Be @('a'); $r.PreviousUnhideDone | Should -BeTrue
      @($script:hideCalls | ForEach-Object { $_.Id }) | Should -Be @('p1', 'p2')
      @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Windows update could not be un-hidden' -and $_.Data.id -eq 'p1' }).Count | Should -Be 1
    }
    It 'Invoke-WuUnhide un-hides only the given ids that are hidden (any letter case), each once, and lists them' {
      $script:searchResults['IsHidden=1'] = @((New-FakeUpdate -Id 'A1'), (New-FakeUpdate -Id 'b2'), (New-FakeUpdate -Id 'c3'), (New-FakeUpdate -Id 'A1'))
      $r = Invoke-WuUnhide -Session ([pscustomobject]@{ Name = 'fake session' }) -Ids @('a1', 'c3', 'd4', 'c3')
      @($script:searches) | Should -Be @('IsHidden=1')
      @($script:hideCalls | ForEach-Object { '{0}={1}' -f $_.Id, $_.Hidden }) | Should -Be @('A1=False', 'c3=False')
      @($r.Unhidden) | Should -Be @('A1', 'c3'); @($r.UnhideFailed).Count | Should -Be 0
    }
    It 'Invoke-WuUnhide lists an update that refuses in UnhideFailed and goes on with the rest' {
      $script:searchResults['IsHidden=1'] = @((New-FakeUpdate -Id 'x1'), (New-FakeUpdate -Id 'x2'))
      $script:hideThrowFor = @{ x1 = (New-Object Runtime.InteropServices.COMException('refused', 0x80248016)) }
      $r = Invoke-WuUnhide -Session ([pscustomobject]@{ Name = 'fake session' }) -Ids @('x1', 'x2')
      @($r.Unhidden) | Should -Be @('x2'); @($r.UnhideFailed) | Should -Be @('x1')
      ($script:logs | Where-Object { $_.Message -eq 'Windows update could not be un-hidden' }).Data.errorCode | Should -Be '0x80248016'
    }
    It 'Invoke-WuUnhide with no ids searches nothing' {
      $r = Invoke-WuUnhide -Session ([pscustomobject]@{ Name = 'fake session' }) -Ids @()
      $script:searches.Count | Should -Be 0; @($r.Unhidden).Count | Should -Be 0; @($r.UnhideFailed).Count | Should -Be 0
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

    # Wu spec 3.2: DRIVERS searches Type='Driver' only. Ruling WU-R1 (plan call 2): the optional drivers
    # (BrowseOnly=1) are counted once per run, in DRIVERS round 1 only; they are never installed. Ruling WU-R3:
    # the count runs last, after the round's installs, so a count search that hangs never costs the drivers.
    It 'DRIVERS searches drivers only, then counts the optional ones: logged, never installed (spec 3.2, Review Focus 3)' {
      $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 's1'))
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
      $script:searchResults[$script:OptionalDriverCriteria] = @((New-FakeUpdate -Id 'o1'), (New-FakeUpdate -Id 'o2'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1) -Scope 'DRIVERS'
      @($script:searches) | Should -Be @($script:DriverCriteria, $script:OptionalDriverCriteria)
      @($r.Installed.Id) | Should -Be @('d1'); $r.Found | Should -Be 1; @($script:installCalls | ForEach-Object { $_ }) | Should -Not -Contain 'o1'
      $l = @($script:logs | Where-Object { $_.Message -eq 'Optional driver updates skipped' }); $l.Count | Should -Be 1; $l[0].Data.count | Should -Be 2
    }
    It 'a failed optional-driver count is one WARN; the DRIVERS round goes on (Review Focus 4)' {
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
      $script:installsBeforeCount = $null
      Mock Search-WuUpdates { [void]$script:searches.Add($Criteria)
        if ($Criteria -like '*BrowseOnly=1*') { $script:installsBeforeCount = @($script:installCalls | ForEach-Object { $_ }); throw 'search failed' }
        if ($script:searchResults.Contains($Criteria)) { $script:searchResults[$Criteria] } }
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1) -Scope 'DRIVERS'
      $r.Error | Should -BeNullOrEmpty; @($r.Installed.Id) | Should -Be @('d1')
      @($script:installsBeforeCount) | Should -Be @('d1')   # WU-R3: the drivers were installed before the count search ran
      $w = @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Optional driver updates could not be counted' }); $w.Count | Should -Be 1
      $w[0].Data.round | Should -Be 1; $w[0].Data.errorCode | Should -Match '^0x[0-9A-F]{8}$'; $w[0].Data.error | Should -Be 'search failed'
      $w[0].Data.seconds | Should -BeOfType [double]
    }
    # Final wave 1: CLAUDE.md says Hebrew never reaches setup.log, and a COM/.NET exception text can be localized.
    It 'the could-not-count WARN logs the exception text as ASCII (final review M1)' {
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
      Mock Search-WuUpdates { [void]$script:searches.Add($Criteria)
        if ($Criteria -like '*BrowseOnly=1*') { throw ('search failed ' + $script:HebrewText) }
        if ($script:searchResults.Contains($Criteria)) { $script:searchResults[$Criteria] } }
      $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1) -Scope 'DRIVERS'
      $w = @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -eq 'Optional driver updates could not be counted' }); $w.Count | Should -Be 1
      $w[0].Data.error | Should -BeExactly 'search failed ?????'
    }
    # Final wave 2 (Task 1 re-review M1): while the count runs the progress file says so (the parent's NOW area
    # shows "Counting optional drivers"), and 'done' comes back when it ends. Only DRIVERS round 1 ever writes it.
    It 'DRIVERS round 1 shows the count as a phase: done, then counting, then done again; a failing count too' -ForEach @(
      @{ Fails = $false }, @{ Fails = $true }) {
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
      $script:searchResults[$script:OptionalDriverCriteria] = @((New-FakeUpdate -Id 'o1'))
      $script:phases = New-Object System.Collections.ArrayList; $script:countFails = $Fails
      Mock Update-WuProgress { if (-not [string]::IsNullOrEmpty($Phase)) { [void]$script:phases.Add($Phase) } }
      Mock Search-WuUpdates { [void]$script:searches.Add($Criteria)
        if ($Criteria -like '*BrowseOnly=1*' -and $script:countFails) { throw 'search failed' }
        if ($script:searchResults.Contains($Criteria)) { $script:searchResults[$Criteria] } }
      $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1) -Scope 'DRIVERS'
      @($script:phases)[0] | Should -Be 'searching'
      @($script:phases)[-3..-1] | Should -Be @('done', 'counting', 'done')
      @($script:phases | Where-Object { $_ -eq 'counting' }).Count | Should -Be 1
    }
    It 'no other round writes the counting phase: DRIVERS round 2, FULL, and a DRIVERS round 1 that threw' -ForEach @(
      @{ Scope = 'FULL'; Rounds = 1; Throw = $null }, @{ Scope = 'DRIVERS'; Rounds = 2; Throw = $null }, @{ Scope = 'DRIVERS'; Rounds = 1; Throw = 'install exploded' }) {
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
      $script:searchResults[$script:OptionalDriverCriteria] = @((New-FakeUpdate -Id 'o1'))
      $script:phases = New-Object System.Collections.ArrayList; $script:installThrow = $Throw
      Mock Update-WuProgress { if (-not [string]::IsNullOrEmpty($Phase)) { [void]$script:phases.Add($Phase) } }
      $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds $Rounds) -Scope $Scope
      @($script:phases) | Should -Not -Contain 'counting'
      @($script:phases)[-1] | Should -Be 'done'
    }
    It 'counts the optional drivers last: after the installs, the progress file''s done and SystemInfo (<Mode>; WU-R3)' -ForEach @(
      @{ Mode = 'Batch'; Installs = @('install d1,d2') }, @{ Mode = 'OneAtATime'; Installs = @('install d1', 'install d2') }) {
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'), (New-FakeUpdate -Id 'd2'))
      $script:searchResults[$script:OptionalDriverCriteria] = @((New-FakeUpdate -Id 'o1'))
      $script:events = New-Object System.Collections.ArrayList; $script:phaseAtCount = $null
      Mock Search-WuUpdates { [void]$script:searches.Add($Criteria); [void]$script:events.Add("search $Criteria")
        if ($Criteria -like '*BrowseOnly=1*') { $script:phaseAtCount = ([IO.File]::ReadAllText((Get-WuProgressPath -ResultPath $script:roundResultPath)) | ConvertFrom-Json).Phase }
        if ($script:searchResults.Contains($Criteria)) { $script:searchResults[$Criteria] } }
      Mock Invoke-WuInstall { $ids = @(foreach ($u in $Updates) { [string]$u.Identity.UpdateID }); [void]$script:installCalls.Add($ids); [void]$script:events.Add('install ' + ($ids -join ','))
        @{ ResultCodes = @(foreach ($id in $ids) { 2 }); RebootRequired = $false; HResult = 0 } }
      Mock Get-WuRebootRequired { [void]$script:events.Add('systeminfo'); $false }
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1) -Scope 'DRIVERS' -InstallMode $Mode
      @($script:events) | Should -Be (@("search $script:DriverCriteria") + $Installs + @('systeminfo', "search $script:OptionalDriverCriteria"))
      $script:phaseAtCount | Should -Be 'counting'   # final wave 2: the NOW area says the count runs, not "Round finished"
      ([IO.File]::ReadAllText((Get-WuProgressPath -ResultPath $script:roundResultPath)) | ConvertFrom-Json).Phase | Should -Be 'done'   # replaced when the count ends
      @($r.Installed.Id) | Should -Be @('d1', 'd2'); $r.Found | Should -Be 2
      # Never in the result: the child's JSON keeps exactly its v2 fields.
      @($r.PSObject.Properties.Name) | Should -Be @('Installed', 'Failed', 'Hidden', 'HideFailed', 'OnlyDefinitions', 'RebootRequired', 'Error', 'ErrorCode', 'FirmwareDeferred', 'Found', 'PreviousUnhideDone')
    }
    # Ruling WU-R5: the round's result is written before the count, so a count that hangs into the round's deadline
    # leaves a result the parent can still book. The count only logs: working or throwing, the result stays the same.
    It 'writes the round''s result before it counts the optional drivers, and the count leaves it as it was (<Why>; WU-R5)' -ForEach @(
      @{ Why = 'a count that works'; Fails = $false; Log = 'Optional driver updates skipped' }
      @{ Why = 'a count that throws'; Fails = $true; Log = 'Optional driver updates could not be counted' }) {
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'), (New-FakeUpdate -Id 'd2'))
      $script:searchResults[$script:OptionalDriverCriteria] = @((New-FakeUpdate -Id 'o1'))
      $script:installReboot = $true
      $script:countFails = $Fails; $script:resultAtCount = $null; $script:logsAtCount = $null
      Mock Search-WuUpdates { [void]$script:searches.Add($Criteria)
        if ($Criteria -like '*BrowseOnly=1*') {
          if (Test-Path -LiteralPath $script:roundResultPath) { $script:resultAtCount = [IO.File]::ReadAllText($script:roundResultPath) }
          $script:logsAtCount = @($script:logs | ForEach-Object { $_.Message })
          if ($script:countFails) { throw 'search failed' } }
        if ($script:searchResults.Contains($Criteria)) { $script:searchResults[$Criteria] } }
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1) -Scope 'DRIVERS'
      @($script:searches) | Should -Be @($script:DriverCriteria, $script:OptionalDriverCriteria)
      $script:resultAtCount | Should -Not -BeNullOrEmpty                                        # the file was there when the count started
      @($script:logsAtCount) | Should -Contain 'Windows Update round result written'
      [IO.File]::ReadAllText($script:roundResultPath) | Should -BeExactly $script:resultAtCount  # the count never rewrites it
      @($r.Installed.Id) | Should -Be @('d1', 'd2'); $r.RebootRequired | Should -BeTrue; $r.Error | Should -BeNullOrEmpty; $r.ErrorCode | Should -BeNullOrEmpty; $r.Found | Should -Be 2
      @($script:logs | Where-Object { $_.Message -eq 'Windows Update round result written' }).Count | Should -Be 1
      @($script:logs | Where-Object { $_.Message -eq $Log }).Count | Should -Be 1
      ([IO.File]::ReadAllText((Get-WuProgressPath -ResultPath $script:roundResultPath)) | ConvertFrom-Json).Phase | Should -Be 'done'
    }
    It 'a DRIVERS round 1 that ended in an exception does not count (the agent just failed; WU-R3)' {
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
      $script:searchResults[$script:OptionalDriverCriteria] = @((New-FakeUpdate -Id 'o1'))
      $script:installThrow = 'install exploded'
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1) -Scope 'DRIVERS'
      $r.Error | Should -Match 'install exploded'
      @($script:searches) | Should -Be @($script:DriverCriteria)
      @($script:logs | Where-Object { $_.Message -like 'Optional driver updates*' }).Count | Should -Be 0
    }
    It 'only DRIVERS round 1 counts the optional drivers: not round 2, never FULL (WU-R1, plan call 2)' {
      $script:searchResults[$script:DriverCriteria] = @((New-FakeUpdate -Id 'd1'))
      $script:searchResults[$script:OptionalDriverCriteria] = @((New-FakeUpdate -Id 'o1'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 2) -Scope 'DRIVERS'
      @($script:searches) | Should -Be @($script:DriverCriteria); @($r.Installed.Id) | Should -Be @('d1')
      $script:searches.Clear()
      $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1)
      @($script:searches) | Should -Be @($script:SoftwareCriteria, $script:DriverCriteria)
      @($script:logs | Where-Object { $_.Message -like 'Optional driver updates*' }).Count | Should -Be 0
      @($script:logs | Where-Object { $_.Message -eq 'Windows Update round starting' } | ForEach-Object { $_.Data.scope }) | Should -Be @('DRIVERS', 'FULL')
    }
    It 'logs at most 20 optional titles, as ASCII, and how long the search took; -SearchOnly counts them too, after its selection' {
      $script:searchResults[$script:OptionalDriverCriteria] = @(foreach ($i in 1..22) { New-FakeUpdate -Id "o$i" -Title $(if ($i -eq 1) { "Driver $script:HebrewText" } else { "Driver $i" }) })
      $null = Invoke-TestRound -StatePath (New-WuStateFile -Rounds 1) -Scope 'DRIVERS' -SearchOnly
      $l = @($script:logs | Where-Object { $_.Message -eq 'Optional driver updates skipped' }); $l.Count | Should -Be 1
      $l[0].Data.count | Should -Be 22; $l[0].Data.round | Should -Be 1; @($l[0].Data.titles).Count | Should -Be 20
      @($l[0].Data.titles)[0] | Should -BeExactly 'Driver ?????'; @($l[0].Data.titles)[19] | Should -BeExactly 'Driver 20'
      $l[0].Data.seconds | Should -BeOfType [double]; $l[0].Data.seconds | Should -BeGreaterOrEqual 0
      $script:installCalls.Count | Should -Be 0; $script:hideCalls.Count | Should -Be 0
      $messages = @($script:logs | ForEach-Object { $_.Message })
      [array]::IndexOf($messages, 'Windows Update search finished') | Should -BeLessThan ([array]::IndexOf($messages, 'Optional driver updates skipped'))
    }
    It 'DRIVERS keeps the firmware rule: on battery a Firmware driver is deferred' {
      $fw = New-FakeUpdate -Id 'fw'; $fw | Add-Member NoteProperty DriverClass 'Firmware'
      $script:searchResults[$script:DriverCriteria] = @($fw, (New-FakeUpdate -Id 'net'))
      $r = Invoke-TestRound -StatePath (New-WuStateFile) -Scope 'DRIVERS' -OnAC $false
      @($script:installCalls | ForEach-Object { $_ }) | Should -Be @('net'); $r.FirmwareDeferred | Should -Be 1
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
      # Final review M1 (spec 4.5): the loop stops at the first round-ending code, also before the install of
      # the update whose download reported it. Not attempted is 'skipped', in neither list (no failure count).
      It 'a round-ending download code (<_>) stops before that update''s install, even when its download succeeded' -ForEach @(0x80240016, 0x80242014) {
        $script:searchResults[$script:SoftwareCriteria] = @('a', 'b', 'c' | ForEach-Object { New-FakeUpdate -Id $_ }); $script:downloadHResultFor = @{ b = $_ }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        @($script:installCalls | ForEach-Object { $_ }) | Should -Be @('a'); @($script:downloadCalls | ForEach-Object { $_ }) | Should -Be @('a', 'b')
        $r.ErrorCode | Should -Be (Format-WuHResult -HResult $_); $r.Error | Should -BeNullOrEmpty
        @($r.Installed.Id) | Should -Be @('a'); @($r.Failed).Count | Should -Be 0
        $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
        @($p.Updates.Status) | Should -Be @('installed', 'skipped', 'skipped')
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
      # Ruling V2-R11: the code that stopped the loop is ErrorCode, so the parent keeps v1's meaning (R23, R23b).
      It 'the download code that stopped the loop is ErrorCode, even after an earlier non-zero install HResult' {
        $script:searchResults[$script:SoftwareCriteria] = @('a', 'b', 'c' | ForEach-Object { New-FakeUpdate -Id $_ })
        $script:installHResultFor = @{ a = 0x80070643 }; $script:downloadHResultFor = @{ b = 0x80240016 }; $script:downloadCodes = @{ b = 4 }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $r.ErrorCode | Should -Be '0x80240016'; @($script:downloadCalls | ForEach-Object { $_ }) | Should -Be @('a', 'b')
        @($r.Failed.Id) | Should -Be @('b'); @($r.Installed.Id) | Should -Be @('a')
        $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
        @($p.Updates.Status) | Should -Be @('installed', 'failed', 'skipped')
      }
      It 'the install code that stopped the loop is ErrorCode, even after an earlier non-zero install HResult' {
        $script:searchResults[$script:SoftwareCriteria] = @('a', 'b', 'c' | ForEach-Object { New-FakeUpdate -Id $_ })
        $script:installHResultFor = @{ a = 0x80070643; b = 0x80242014 }; $script:installCodes = @{ a = 4; b = 4 }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $r.ErrorCode | Should -Be '0x80242014'; $r.Error | Should -BeNullOrEmpty
        @($script:installCalls | ForEach-Object { $_ }) | Should -Be @('a', 'b'); @($r.Failed.Id) | Should -Be @('a', 'b')
        $p = Get-Content (Get-WuProgressPath -ResultPath $script:roundResultPath) -Raw | ConvertFrom-Json
        @($p.Updates.Status) | Should -Be @('failed', 'failed', 'skipped')
      }
      It 'keeps the restart flag of an install that finished before a later install threw' {
        $script:searchResults[$script:SoftwareCriteria] = @((New-FakeUpdate -Id 'a'), (New-FakeUpdate -Id 'b'))
        $script:installRebootFor = @{ a = $true }; $script:installThrowFor = @{ b = (New-Object Runtime.InteropServices.COMException('busy', 0x80240016)) }
        $r = Invoke-TestRound -StatePath (New-WuStateFile) -InstallMode OneAtATime
        $r.RebootRequired | Should -BeTrue; $r.Error | Should -Be 'busy'; $r.ErrorCode | Should -Be '0x80240016'; @($r.Installed.Id) | Should -Be @('a')
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
      # Ruling WU-R5: a child that wrote its result (or $script:childJson), then ran into the round's deadline.
      $script:childTimedOutAfterWrite = $false
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
        if ($script:childTimedOutAfterWrite) { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
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
    # Ruling WU-R5: the child writes its result only at the end of its round (in DRIVERS round 1 before the optional-
    # driver count), and the parent deletes an old result file before it starts the child, so a readable result after
    # a timeout is this round's: it is booked as for a round that ended normally, plus one WARN. Both scopes.
    It 'a round that timed out after writing its result goes on like a finished round, with a WARN (<Scope>; WU-R5)' -ForEach @(
      @{ Scope = 'DRIVERS' }, @{ Scope = 'FULL' }) {
      $script:ctx = New-WuContext -Choices @{ WindowsUpdate = $Scope }
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'a'; Title = 'A'; Kb = 'KB5000001' }) -RebootRequired $true
      $script:childTimedOutAfterWrite = $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'; $r.Reboot | Should -Be 'Now'; $r.Message | Should -Be 'Windows Update round 1: 1 installed, 0 failed'
      $r.Data.Rounds | Should -Be 1; $r.Data.Installed | Should -Be 1; @($r.Data.InstalledIds) | Should -Be @('a')
      $w = @($script:logs | Where-Object { $_.Message -eq 'Windows Update round timed out after its result was written' })
      $w.Count | Should -Be 1; $w[0].Level | Should -Be 'WARN'
      $w[0].Data.round | Should -Be 1; $w[0].Data.path | Should -BeExactly (Join-Path $script:ctx.LogDir 'wu-round1.json')
      @($script:logs | Where-Object { $_.Message -eq 'Windows Update round finished' }).Count | Should -Be 1
    }
    It 'a round that timed out after writing a result with nothing left is Done, with the same notes (WU-R5)' {
      $script:ctx = New-WuContext -Data @{ Rounds = 1; Installed = 3 } -Choices @{ WindowsUpdate = 'DRIVERS' }
      $script:childResult = New-ChildResult; $script:childResult['FirmwareDeferred'] = 1
      $script:childTimedOutAfterWrite = $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Done'; $r.Message | Should -Be 'Drivers only: installed 3 updates in 2 rounds'; $r.Reboot | Should -Be 'None'
      @($r.Notes) | Should -Be @('On battery: BIOS/firmware updates skipped')
    }
    It 'a round that timed out with <Why> still fails as timed out, and books nothing (WU-R5)' -ForEach @(
      @{ Why = 'no result'; Json = $null }
      @{ Why = 'a result that is not JSON'; Json = '{"Installed": [' }
      @{ Why = 'a result without its lists'; Json = '{"Error": null}' }) {
      $script:ctx = New-WuContext
      $script:childResult = $null; $script:childJson = $Json; $script:childTimedOutAfterWrite = $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Failed'; $r.Message | Should -Be 'Windows Update round timed out'
      $r.Data.Rounds | Should -Be 1; [int]$r.Data.Installed | Should -Be 0
      @($script:logs | Where-Object { $_.Message -eq 'Windows Update round timed out after its result was written' }).Count | Should -Be 0
      @($script:logs | Where-Object { $_.Message -eq 'Windows Update round finished' }).Count | Should -Be 0
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
    # Ruling V2-R11: a one-at-a-time round that stopped at a busy code writes that code with no Error
    # (here: a failed with 0x80070643, then b failed with 0x80240016, c not attempted). The parent gives it
    # v1's meaning: no failure counts for the round (R23b) and the busy wait (R23).
    It 'gives a one-at-a-time round stopped by a busy code the v1 busy meaning: no failure counts, wait, Continue' {
      $script:ctx = New-WuContext -FailureCounts @{ a = 1 }
      $res = New-ChildResult -Failed @([ordered]@{ Id = 'a'; Title = 'A'; ResultCode = 4 }, [ordered]@{ Id = 'b'; Title = 'B'; ResultCode = 4 }) -ErrorCode '0x80240016'
      $res['FirmwareDeferred'] = 0; $res['Found'] = 3; $script:childResult = $res
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Continue'; $r.Reboot | Should -Be 'None'; @($script:sleeps) | Should -Be @(120)
      $script:ctx.State.WuFailureCounts['a'] | Should -Be 1; $script:ctx.State.WuFailureCounts.ContainsKey('b') | Should -BeFalse
      $r.Data.FailedTitles['a'] | Should -Be 'A'; $r.Data.FailedTitles['b'] | Should -Be 'B'
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

    # Task 12 (spec 4.5): NOW shows the round and the child's progress file, each round has an activity
    # line, and the installed updates are kept for the report.
    It 'shows round N (max cap) and reads that round''s progress file' {
      Clear-SetupNow
      $script:ctx = New-WuContext -Data @{ Rounds = 1 }
      Mock Invoke-External { $script:nowSeen = Get-SetupNow; @{ ExitCode = 0; TimedOut = $false; Output = '' } }
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $nowSeen.SubTitle | Should -Be 'round 2 (max 6)'
      $nowSeen.ProviderArgument | Should -Be (Join-Path $script:ctx.LogDir 'wu-round2.progress.json')
    }
    It 'gives NOW a provider that turns the progress file into lines' {
      Clear-SetupNow
      $script:ctx = New-WuContext
      Mock Invoke-External {
        $now = Get-SetupNow
        $script:linesBefore = @(& $now.Provider $now.ProviderArgument)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $now.ProviderArgument))
        [IO.File]::WriteAllText($now.ProviderArgument, (ConvertTo-Json -Depth 4 -InputObject @{ Round = 1; Mode = 'OneAtATime'; Phase = 'installing'; Current = 1; Total = 1; Updates = @(@{ Kb = 'KB5070001'; Title = 'Cumulative'; SizeMB = 0; Status = 'installing' }) }))
        $script:linesDuring = @(& $now.Provider $now.ProviderArgument)
        @{ ExitCode = 0; TimedOut = $false; Output = '' }
      }
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $linesBefore.Count | Should -Be 0
      $linesDuring | Should -Be @('Installing 1 of 1', '[>>] KB5070001 Cumulative')
    }
    It 'removes a stale progress file before the round' {
      $script:ctx = New-WuContext; $stale = Join-Path $script:ctx.LogDir 'wu-round1.progress.json'
      [void][IO.Directory]::CreateDirectory($script:ctx.LogDir); 'old' | Set-Content $stale
      Mock Invoke-External { $script:staleSeen = Test-Path $stale; @{ ExitCode = 0; TimedOut = $false; Output = '' } }
      $null = Invoke-StepWindowsUpdate -Context $script:ctx; $staleSeen | Should -BeFalse
    }
    It 'a stale progress file that cannot be removed is a WARN; the round still runs (display only)' {
      $script:ctx = New-WuContext; $stale = Join-Path $script:ctx.LogDir 'wu-round1.progress.json'
      [void][IO.Directory]::CreateDirectory($script:ctx.LogDir); 'old' | Set-Content $stale
      Mock Remove-Item { if ("$LiteralPath" -like '*.progress.json') { Write-Error 'locked' } }
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ext.Count | Should -Be 1
      $r.Message | Should -Not -BeLike 'Windows Update round could not be started*'
      @($script:logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -like '*progress file*' }).Count | Should -Be 1
    }
    It 'writes one activity line per round with found, installed and failed' {
      $script:act = New-Object System.Collections.ArrayList; Mock Add-SetupActivity { [void]$script:act.Add($Text) }
      $script:ctx = New-WuContext
      $res = New-ChildResult -Installed @([ordered]@{ Id = 'a'; Title = 'A'; Kb = 'KB1' }) -Failed @([ordered]@{ Id = 'b'; Title = 'B'; ResultCode = 4 }); $res['Found'] = 5; $script:childResult = $res
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      @($act) | Should -Be @('Windows Update round 1: found 5, installed 1, failed 1')
    }
    It 'counts a round from a child that wrote no Found as found 0, and logs every booked round' {
      $script:act = New-Object System.Collections.ArrayList; Mock Add-SetupActivity { [void]$script:act.Add($Text) }
      $script:ctx = New-WuContext -Data @{ Rounds = 2 }
      $script:childResult = New-ChildResult -ErrorText 'x' -ErrorCode '0x80070005'
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      @($act) | Should -Be @('Windows Update round 3: found 0, installed 0, failed 0')
    }
    It 'DRIVERS: round 1 says so once in the activity feed, and Done says Drivers only, with no note (spec 3.2, 3.3)' {
      $script:act = New-Object System.Collections.ArrayList; Mock Add-SetupActivity { [void]$script:act.Add($Text) }
      $script:ctx = New-WuContext -Choices @{ WindowsUpdate = 'DRIVERS' }; $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'd'; Title = 'D' })
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      @($act) | Should -Be @('Windows Update: drivers only (other updates left to Windows)', 'Windows Update round 1: found 0, installed 1, failed 0')
      $script:act.Clear(); $script:ctx = New-WuContext -Data @{ Rounds = 2; Installed = 5 } -Choices @{ WindowsUpdate = 'DRIVERS' }; $script:childResult = New-ChildResult
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      $r.Status | Should -Be 'Done'; $r.Message | Should -BeExactly 'Drivers only: installed 5 updates in 3 rounds'; @($r.Notes).Count | Should -Be 0
      @($act) | Should -Be @('Windows Update round 3: found 0, installed 0, failed 0')
    }
    It 'logs the scope as a round starts: DRIVERS, and FULL for a state without the choice (Review Focus 1)' {
      $script:ctx = New-WuContext -Choices @{ WindowsUpdate = 'drivers' }; $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx = New-WuContext; $null = Invoke-StepWindowsUpdate -Context $script:ctx
      @($script:logs | Where-Object { $_.Message -eq 'Windows Update round starting' } | ForEach-Object { $_.Data.scope }) | Should -Be @('DRIVERS', 'FULL')
    }
    It 'writes no activity line when the round produced no result' {
      $script:act = New-Object System.Collections.ArrayList; Mock Add-SetupActivity { [void]$script:act.Add($Text) }
      $script:ctx = New-WuContext; $script:childResult = $null
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $act.Count | Should -Be 0
    }
    It 'records installed updates per round for the report, but not a re-offer' {
      $script:ctx = New-WuContext -Data @{ Rounds = 1; Installed = 1; InstalledIds = @('a') }
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'a'; Title = 'A'; Kb = 'KB1' }, [ordered]@{ Id = 'c'; Title = 'Cumulative'; Kb = 'KB5070001' })
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      @($r.Data.InstalledLines) | Should -Be @('Round 2: KB5070001 Cumulative')
    }
    It 'keeps the installed lines of earlier rounds, adds a definition update every time, and leaves out the KB when there is none' {
      $script:ctx = New-WuContext
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'cu'; Title = 'Cumulative'; Kb = 'KB5070001'; IsDefinition = $false }, [ordered]@{ Id = 'def'; Title = 'Defender'; Kb = 'KB2267602'; IsDefinition = $true }, [ordered]@{ Id = 'drv'; Title = 'Intel driver'; Kb = ''; IsDefinition = $false })
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:childResult = New-ChildResult -Installed @([ordered]@{ Id = 'def'; Title = 'Defender'; Kb = 'KB2267602'; IsDefinition = $true }) -OnlyDefinitions $true
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      @($r.Data.InstalledLines) | Should -Be @('Round 1: KB5070001 Cumulative', 'Round 1: KB2267602 Defender', 'Round 1: Intel driver', 'Round 2: KB2267602 Defender')
      @($script:ctx.State.Steps['windows-update'].Data.InstalledLines) | Should -Be @($r.Data.InstalledLines)
      $r.Data.InstalledLines -is [string[]] | Should -BeTrue
    }
    It 'has an empty InstalledLines list when nothing was installed' {
      $script:ctx = New-WuContext
      $r = Invoke-StepWindowsUpdate -Context $script:ctx
      @($r.Data.InstalledLines).Count | Should -Be 0
      $r.Data.InstalledLines -is [string[]] | Should -BeTrue
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

    # Final review C1: the child says when it un-hid the previous run's updates; the state remembers it for the run.
    It 'books PreviousUnhideDone into State.PreviousHiddenRestored, also from a round with an error' {
      $script:ctx = New-WuContext
      $res = New-ChildResult -ErrorText 'search failed'; $res['PreviousUnhideDone'] = $true; $script:childResult = $res
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx.State.PreviousHiddenRestored | Should -BeTrue
    }
    It 'leaves State.PreviousHiddenRestored alone when the child did not un-hide' {
      $script:ctx = New-WuContext
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx.State.PreviousHiddenRestored | Should -Not -BeTrue
      $script:ctx.State.PreviousHiddenRestored = $true
      $null = Invoke-StepWindowsUpdate -Context $script:ctx
      $script:ctx.State.PreviousHiddenRestored | Should -BeTrue
    }
  }

  # Final review C1 (v1 spec 8.8): at the end of every run the updates this run (or the previous one) hid are
  # un-hidden again, in a -WuUnhide child (mocked here: it only writes its result JSON inside $TestDrive).
  Context 'Restore-WuHiddenUpdates (end of the run, child mocked)' {
    BeforeAll {
      $script:g1 = '11111111-aaaa-4bbb-8ccc-000000000001'; $script:g2 = '22222222-aaaa-4bbb-8ccc-000000000002'; $script:g3 = '33333333-aaaa-4bbb-8ccc-000000000003'
    }
    BeforeEach {
      $script:ext = New-Object System.Collections.ArrayList
      $script:unhideResult = [ordered]@{ Unhidden = @(); UnhideFailed = @() }
      $script:unhideJson = $null
      $script:unhideTimedOut = $false
      $script:unhideThrows = $false
      $script:logs = New-Object System.Collections.ArrayList
      Mock Write-SetupLog { [void]$script:logs.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
      Mock Invoke-External {
        [void]$script:ext.Add(@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes })
        if ($script:unhideThrows) { throw 'The system cannot find the file specified' }
        if ($script:unhideTimedOut) { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
        $path = [regex]::Match($ArgumentList, '-ResultPath "([^"]+)"').Groups[1].Value
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        if ($null -ne $script:unhideJson) { [IO.File]::WriteAllText($path, $script:unhideJson, (New-Object Text.UTF8Encoding $false)) }
        elseif ($null -ne $script:unhideResult) { Write-WuRoundResult -Path $path -Result $script:unhideResult }
        return @{ ExitCode = 0; TimedOut = $false; Output = '' }
      }
      # A run that hid g1 (title known) and inherited g2 from the previous run (no title).
      $script:ctx = New-WuContext -Hidden @($script:g1) -Data @{ FailedTitles = @{ $script:g1 = 'Cumulative Update KB5050001' } }
      $script:ctx.State.PreviousHiddenUpdateIds = @($script:g2, $script:g1.ToUpperInvariant())
    }

    It 'starts no child when nothing was hidden' {
      $c = New-WuContext
      @(Restore-WuHiddenUpdates -Context $c).Count | Should -Be 0
      $script:ext.Count | Should -Be 0
      $c.State.HiddenUpdatesRestored | Should -Not -BeTrue
    }
    It 'passes this run''s and the previous run''s ids exactly, once each, to a -WuUnhide child with a 15-minute timeout' {
      $null = Restore-WuHiddenUpdates -Context $script:ctx
      $script:ext.Count | Should -Be 1
      $script:ext[0].FilePath | Should -Be $script:PowerShellExe
      $expected = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -WuUnhide -ResultPath "{1}" -UpdateIds "{2},{3}"' -f $script:ctx.ScriptPath, (Join-Path $script:ctx.LogDir 'wu-unhide.json'), $script:g1, $script:g2
      $script:ext[0].ArgumentList | Should -Be $expected
      $script:ext[0].TimeoutMinutes | Should -Be 15
    }
    It 'success sets HiddenUpdatesRestored, saves it, and a second call starts nothing' {
      $script:unhideResult = [ordered]@{ Unhidden = @($script:g1); UnhideFailed = @() }
      @(Restore-WuHiddenUpdates -Context $script:ctx).Count | Should -Be 0
      $script:ctx.State.HiddenUpdatesRestored | Should -BeTrue
      (Read-RunState -Root $script:ctx.Root).HiddenUpdatesRestored | Should -BeTrue
      @(Restore-WuHiddenUpdates -Context $script:ctx).Count | Should -Be 0
      $script:ext.Count | Should -Be 1
    }
    It 'an id left in UnhideFailed is red, by its title where known, else by its id; the flag stays unset' {
      $script:unhideResult = [ordered]@{ Unhidden = @(); UnhideFailed = @($script:g1, $script:g2) }
      $errors = @(Restore-WuHiddenUpdates -Context $script:ctx)
      $errors | Should -Be @(
        'Windows update still hidden: Cumulative Update KB5050001 - un-hide it in Windows Update',
        "Windows update still hidden: $($script:g2) - un-hide it in Windows Update")
      $script:ctx.State.HiddenUpdatesRestored | Should -Not -BeTrue
    }
    It 'a timeout is red for every id' {
      $script:unhideTimedOut = $true
      @(Restore-WuHiddenUpdates -Context $script:ctx).Count | Should -Be 2
      $script:ctx.State.HiddenUpdatesRestored | Should -Not -BeTrue
    }
    It 'a child that cannot start, writes nothing, or writes an unreadable result is red for every id' {
      $script:unhideThrows = $true
      @(Restore-WuHiddenUpdates -Context $script:ctx) | Should -Contain 'Windows update still hidden: Cumulative Update KB5050001 - un-hide it in Windows Update'
      $script:unhideThrows = $false; $script:unhideResult = $null
      @(Restore-WuHiddenUpdates -Context $script:ctx).Count | Should -Be 2
      $script:unhideJson = '{"Unhidden": ['
      @(Restore-WuHiddenUpdates -Context $script:ctx).Count | Should -Be 2
      $script:unhideJson = '{"Unhidden": []}'
      @(Restore-WuHiddenUpdates -Context $script:ctx).Count | Should -Be 2
      $script:ctx.State.HiddenUpdatesRestored | Should -Not -BeTrue
    }
    It 'never reads a stale result file left by an earlier call' {
      [void][IO.Directory]::CreateDirectory($script:ctx.LogDir)
      Write-WuRoundResult -Path (Join-Path $script:ctx.LogDir 'wu-unhide.json') -Result ([ordered]@{ Unhidden = @($script:g1, $script:g2); UnhideFailed = @() })
      $script:unhideResult = $null
      @(Restore-WuHiddenUpdates -Context $script:ctx).Count | Should -Be 2
    }
    It 'never puts an id that is not a GUID on the command line; it counts as still hidden' {
      $script:ctx.State.HiddenUpdateIds = @($script:g3, 'x" -Resume "')
      $script:ctx.State.PreviousHiddenUpdateIds = @()
      $script:unhideResult = [ordered]@{ Unhidden = @($script:g3); UnhideFailed = @() }
      $errors = @(Restore-WuHiddenUpdates -Context $script:ctx)
      $script:ext[0].ArgumentList | Should -Match ('-UpdateIds "{0}"$' -f $script:g3)
      $errors | Should -Be @('Windows update still hidden: x" -Resume " - un-hide it in Windows Update')
    }
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
# Task 12 (spec 4.5): the lines NOW shows for a Windows Update round. Pure helpers plus a file read; the
# only I/O is inside $TestDrive.
Describe 'Windows Update NOW' {
  BeforeAll {
    foreach ($f in 'Logging', 'Activity') { . "$PSScriptRoot\..\src\Common\$f.ps1" }
    . "$PSScriptRoot\..\src\UI\StartScreen.ps1"
    $script:Hebrew = -join [char[]](0x05E2, 0x05D3, 0x05DB, 0x05D5, 0x05DF)   # five Hebrew letters
    function Write-TestProgress {
      param([string]$Path, [string]$Mode = 'OneAtATime', [string]$Phase = 'installing', [int]$Current = 0, [int]$Total = 0, [object[]]$Updates = @())
      [IO.File]::WriteAllText($Path, (ConvertTo-Json -Depth 4 -InputObject @{ Round = 1; Mode = $Mode; Phase = $Phase; Current = $Current; Total = $Total; Updates = $Updates }))
    }
    function New-TestUpdates { param([int]$Count, [string]$Status = 'pending') @(1..$Count | ForEach-Object { @{ Kb = "KB$_"; Title = "T$_"; SizeMB = 0; Status = $Status } }) }
  }
  It 'Format-WuUpdateLine puts the KB first and stays ASCII' {
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = 'KB5070001'; Title = '2026-10 Cumulative Update'; SizeMB = 412.4; Status = 'installing' }) | Should -Be '[>>] KB5070001 2026-10 Cumulative Update (412 MB)'
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = 'KB5070002'; Title = $script:Hebrew; SizeMB = 0; Status = 'installed' }) | Should -Be '[OK] KB5070002 ?????'
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = ''; Title = 'Intel driver'; SizeMB = 0; Status = 'skipped' }) | Should -Be '[--] Intel driver'
  }
  It 'Format-WuUpdateLine has a marker for every status' {
    $expected = @{ installed = '[OK]'; failed = '[X ]'; downloading = '[>>]'; installing = '[>>]'; pending = '[..]'; skipped = '[--]' }
    foreach ($status in $expected.Keys) {
      Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = 'KB1'; Title = 'T'; SizeMB = 0; Status = $status }) | Should -Be ($expected[$status] + ' KB1 T')
    }
  }
  It 'Format-WuUpdateLine treats an unknown status as pending and copes with missing fields' {
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = 'KB1'; Title = 'T'; SizeMB = 0; Status = 'weird' }) | Should -Be '[..] KB1 T'
    Format-WuUpdateLine -Update ([pscustomobject]@{ Status = 'pending' }) | Should -Be '[..]'
  }
  It 'Format-WuUpdateLine shows no size for 0 and whole MB otherwise' {
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = 'KB1'; Title = 'T'; SizeMB = 0.0; Status = 'pending' }) | Should -Be '[..] KB1 T'
    Format-WuUpdateLine -Update ([pscustomobject]@{ Kb = 'KB1'; Title = 'T'; SizeMB = 1536.6; Status = 'pending' }) | Should -Be '[..] KB1 T (1537 MB)'
  }
  It 'Get-WuProgressLines: "Installing 3 of 7" one at a time, "Installing 7 updates" in batch' {
    $p = "$TestDrive\p.json"
    $u = @(1..7 | ForEach-Object { @{ Kb = "KB$_"; Title = "T$_"; SizeMB = 0; Status = 'pending' } })
    [IO.File]::WriteAllText($p, (ConvertTo-Json -Depth 4 -InputObject @{ Round = 1; Mode = 'OneAtATime'; Phase = 'installing'; Current = 3; Total = 7; Updates = $u }))
    $l = @(Get-WuProgressLines -Path $p); $l[0] | Should -Be 'Installing 3 of 7'; $l.Count | Should -Be 8
    [IO.File]::WriteAllText($p, (ConvertTo-Json -Depth 4 -InputObject @{ Round = 1; Mode = 'Batch'; Phase = 'installing'; Current = 0; Total = 7; Updates = $u }))
    (Get-WuProgressLines -Path $p)[0] | Should -Be 'Installing 7 updates'
  }
  It 'Get-WuProgressLines: the first line for each phase and mode' {
    $p = "$TestDrive\phases.json"
    $cases = @(
      @('OneAtATime', 'searching', 0, 0, 'Searching for updates'),
      @('Batch', 'searching', 0, 0, 'Searching for updates'),
      @('OneAtATime', 'downloading', 2, 5, 'Downloading 2 of 5'),
      @('Batch', 'downloading', 0, 5, 'Downloading 5 updates'),
      @('OneAtATime', 'installing', 5, 5, 'Installing 5 of 5'),
      @('Batch', 'installing', 0, 5, 'Installing 5 updates'),
      @('OneAtATime', 'counting', 0, 0, 'Counting optional drivers'),
      @('Batch', 'counting', 0, 0, 'Counting optional drivers'),
      @('OneAtATime', 'done', 5, 5, 'Round finished'),
      @('Batch', 'done', 0, 5, 'Round finished')
    )
    foreach ($c in $cases) {
      Write-TestProgress -Path $p -Mode $c[0] -Phase $c[1] -Current $c[2] -Total $c[3]
      @(Get-WuProgressLines -Path $p) | Should -Be @($c[4])
    }
  }
  It 'Get-WuProgressLines lists the updates with their markers after the first line, ASCII only' {
    $p = "$TestDrive\list.json"
    Write-TestProgress -Path $p -Phase 'installing' -Current 2 -Total 3 -Updates @(
      @{ Kb = 'KB1'; Title = 'First'; SizeMB = 12.3; Status = 'installed' },
      @{ Kb = 'KB2'; Title = $script:Hebrew; SizeMB = 0; Status = 'installing' },
      @{ Kb = ''; Title = 'Third'; SizeMB = 0; Status = 'pending' })
    @(Get-WuProgressLines -Path $p) | Should -Be @('Installing 2 of 3', '[OK] KB1 First (12 MB)', '[>>] KB2 ?????', '[..] Third')
  }
  It 'Get-WuProgressLines lists a single update (a one-element array in the file)' {
    $p = "$TestDrive\one.json"
    Write-TestProgress -Path $p -Phase 'downloading' -Current 1 -Total 1 -Updates @(@{ Kb = 'KB9'; Title = 'Only'; SizeMB = 0; Status = 'downloading' })
    @(Get-WuProgressLines -Path $p) | Should -Be @('Downloading 1 of 1', '[>>] KB9 Only')
  }
  It 'a half-written or missing progress file gives no lines' {
    [IO.File]::WriteAllText("$TestDrive\half.json", '{ "Round": 1, "Upda'); @(Get-WuProgressLines -Path "$TestDrive\half.json").Count | Should -Be 0
    @(Get-WuProgressLines -Path "$TestDrive\none.json").Count | Should -Be 0
  }
  It 'an empty file, JSON that is not an object, a null or blank path, and a folder give no lines' {
    [IO.File]::WriteAllText("$TestDrive\empty.json", '')
    [IO.File]::WriteAllText("$TestDrive\array.json", '[1, 2, 3]')
    [IO.File]::WriteAllText("$TestDrive\text.json", 'not json at all')
    foreach ($path in "$TestDrive\empty.json", "$TestDrive\array.json", "$TestDrive\text.json", $TestDrive, '', $null) {
      { Get-WuProgressLines -Path $path } | Should -Not -Throw
      @(Get-WuProgressLines -Path $path).Count | Should -Be 0
    }
  }
  It 'a progress file over 64 KB gives no lines' {
    $p = "$TestDrive\big.json"
    Write-TestProgress -Path $p -Phase 'installing' -Current 1 -Total 300 -Updates @(1..300 | ForEach-Object { @{ Kb = "KB$_"; Title = ('Long update title ' * 12) + $_; SizeMB = 1; Status = 'pending' } })
    (Get-Item $p).Length | Should -BeGreaterThan 65536
    @(Get-WuProgressLines -Path $p).Count | Should -Be 0
  }
  It 'a progress file with an unknown phase still lists the updates' {
    $p = "$TestDrive\odd.json"
    Write-TestProgress -Path $p -Phase 'weird' -Updates (New-TestUpdates -Count 2)
    @(Get-WuProgressLines -Path $p) | Should -Be @('[..] KB1 T1', '[..] KB2 T2')
  }
}
