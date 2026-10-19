# tests/Prepare.Tests.ps1
# SAFETY: nothing here may touch the real machine. Every test that reaches Invoke-External,
# Register-ScheduledTask, Unregister-ScheduledTask, New-Item, New-ItemProperty or Test-Path runs with
# those mocked (Initialize-PrepareMocks, called from each BeforeEach). The only commands that run for
# real are the in-memory New-ScheduledTask* constructors and New-ScheduledTaskSettingsSet, which build
# objects and register nothing. The powercfg fixtures were captured with a read-only `powercfg /query`.
BeforeAll {
  . "$PSScriptRoot\..\src\Common\StepResult.ps1"; . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Process.ps1"; . "$PSScriptRoot\..\src\Steps\Prepare.ps1"

  # The four settings and their GUIDs, spelled out here so a typo in Prepare.ps1 cannot hide.
  $script:PwrSleepSub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
  $script:PwrGuid = @{
    STANDBYIDLE   = @{ Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' }
    HIBERNATEIDLE = @{ Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364' }
    VIDEOIDLE     = @{ Sub = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' }
    LIDACTION     = @{ Sub = '4f971e89-eebd-4455-a8de-9e59040e7347'; Setting = '5ca83367-6e45-459f-a27b-476b1d01c936' }
  }

  # powercfg /query output for one setting; only the last two hex values matter.
  function New-PowerQueryText {
    param([int]$AC, [int]$DC)
    "Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)`r`n      Minimum Possible Setting: 0x00000000`r`n      Maximum Possible Setting: 0xffffffff`r`n" +
    ("    Current AC Power Setting Index: 0x{0:x8}`r`n    Current DC Power Setting Index: 0x{1:x8}`r`n" -f $AC, $DC)
  }

  function New-PrepareConfig {
    [pscustomobject]@{
      timeoutsMinutes = [pscustomobject]@{ default = 7 }
      power           = [pscustomobject]@{ finalAcMonitorMinutes = 15 }
      nags            = @(
        [pscustomobject]@{ path = 'HKCU:\Software\Test\One'; name = 'NagOne'; value = 0 },
        [pscustomobject]@{ path = 'HKCU:\Software\Test\Two'; name = 'NagTwo'; value = 0 }
      )
    }
  }

  function New-PrepareContext {
    @{
      Config      = New-PrepareConfig
      State       = @{ Power = @{ Original = @{} } }
      Root        = 'C:\BenTech\Setup'
      LogDir      = 'C:\BenTech\Setup\Logs'
      DownloadDir = 'C:\BenTech\Setup\Downloads'
      ScriptPath  = 'C:\BenTech\Setup\setup.ps1'
      StatePath   = 'C:\BenTech\Setup\state.json'
    }
  }

  # Turns every command that could change the real machine into a recorder. Call from BeforeEach.
  #   $script:calls        ordered, human-readable log of every mocked call
  #   $script:ext          one hashtable per Invoke-External call (File, Args, Timeout, Capture)
  #   $script:regTask      the arguments Register-ScheduledTask received
  #   $script:failExternal regexes; an Invoke-External call whose "file args" matches one exits with 1
  #   $script:throwExternal  same, but the call throws (a program that cannot be started)
  #   $script:queryValues  setting GUID -> @{AC;DC} that a powercfg /query answers with
  function Initialize-PrepareMocks {
    $script:calls = New-Object System.Collections.ArrayList
    $script:ext = New-Object System.Collections.ArrayList
    $script:regTask = $null
    $script:regKeys = New-Object System.Collections.ArrayList
    $script:regValues = New-Object System.Collections.ArrayList
    $script:failExternal = @()
    $script:throwExternal = @()
    $script:registerFailuresLeft = 0     # Register-ScheduledTask throws this many times, then succeeds
    $script:throwNewItemProperty = $false
    $script:existingKeys = @()
    # Folders Get-Item finds (R28), and those it reports as a junction/symlink (ReparsePoint). No test
    # creates a real junction or reads the real C:\BenTech.
    $script:existingFolders = @('C:\BenTech', 'C:\BenTech\Setup')
    $script:reparseFolders = @()
    $script:reparseAfterIcacls = @()   # these turn into a reparse point once all three icacls calls ran
    $script:queryValues = @{}
    foreach ($n in $script:PwrGuid.Keys) { $script:queryValues[$script:PwrGuid[$n].Setting] = @{ AC = 111; DC = 222 } }

    Mock Invoke-External {
      $line = "$FilePath $ArgumentList"
      [void]$script:ext.Add(@{ File = $FilePath; Args = $ArgumentList; Timeout = $TimeoutMinutes; Capture = [bool]$CaptureOutput })
      $tag = if ($FilePath -match 'icacls\.exe$') { 'icacls' } elseif ($FilePath -match 'powercfg\.exe$') { "powercfg $ArgumentList" } else { "other $line" }
      [void]$script:calls.Add($tag)
      foreach ($rx in $script:throwExternal) { if ($line -match $rx) { throw "cannot start $FilePath" } }
      foreach ($rx in $script:failExternal) { if ($line -match $rx) { return @{ ExitCode = 1; TimedOut = $false; Output = '' } } }
      $out = ''
      if ($ArgumentList -match '^/query SCHEME_CURRENT \S+ (?<s>\S+)$') {
        $v = $script:queryValues[$Matches['s']]
        if ($v) { $out = New-PowerQueryText -AC $v.AC -DC $v.DC }
      }
      return @{ ExitCode = 0; TimedOut = $false; Output = $out }
    }
    Mock Register-ScheduledTask {
      [void]$script:calls.Add('task')
      if ($script:registerFailuresLeft -gt 0) { $script:registerFailuresLeft--; throw 'Task Scheduler is not available' }
      $script:regTask = @{ TaskName = $TaskName; Action = $Action; Trigger = $Trigger; Principal = $Principal; Settings = $Settings; Force = [bool]$Force }
    }
    Mock Unregister-ScheduledTask { [void]$script:calls.Add("unregister $TaskName") }
    Mock Start-Sleep { [void]$script:calls.Add("sleep $Seconds") }      # no test ever really waits
    Mock Test-Path { return ($script:existingKeys -contains $LiteralPath) }
    Mock New-Item {
      if ($ItemType -eq 'Directory') { [void]$script:calls.Add("mkdir $Path"); return }
      [void]$script:calls.Add("regkey $Path"); [void]$script:regKeys.Add([string]$Path)
    }
    Mock Get-Item {
      if ($script:existingFolders -notcontains $LiteralPath) { return $null }
      $attributes = [IO.FileAttributes]::Directory
      if ($script:reparseFolders -contains $LiteralPath) { $attributes = $attributes -bor [IO.FileAttributes]::ReparsePoint }
      if ($script:reparseAfterIcacls -contains $LiteralPath -and @($script:ext | Where-Object { $_.File -match 'icacls\.exe$' }).Count -ge 3) {
        $attributes = $attributes -bor [IO.FileAttributes]::ReparsePoint
      }
      [pscustomobject]@{ FullName = $LiteralPath; Attributes = $attributes }
    }
    Mock New-ItemProperty {
      [void]$script:calls.Add("regvalue $LiteralPath $Name")
      if ($script:throwNewItemProperty) { throw 'Requested registry access is not allowed' }
      [void]$script:regValues.Add(@{ Path = [string]$LiteralPath; Name = $Name; Value = $Value; Type = [string]$PropertyType; Force = [bool]$Force })
    }
  }

  function Get-CallIndex {
    param([string]$Pattern)
    for ($i = 0; $i -lt $script:calls.Count; $i++) { if ($script:calls[$i] -match $Pattern) { return $i } }
    return -1
  }
  function Get-PowercfgSet {
    # The "/setacvalueindex" / "/setdcvalueindex" calls as @{ Kind; Sub; Setting; Value }.
    param([string]$Kind)
    @($script:ext | Where-Object { $_.Args -match "^/set${Kind}valueindex SCHEME_CURRENT (?<sub>\S+) (?<s>\S+) (?<v>\d+)$" } | ForEach-Object {
        $null = $_.Args -match "^/set${Kind}valueindex SCHEME_CURRENT (?<sub>\S+) (?<s>\S+) (?<v>\d+)$"
        @{ Sub = $Matches['sub']; Setting = $Matches['s']; Value = [int]$Matches['v'] }
      })
  }
}

Describe 'power parsing' {
  It 'reads AC/DC from Hebrew-labelled output' { $r = Get-PowerIndexFromQueryOutput -Text (Get-Content "$PSScriptRoot\fixtures\powercfg-he.txt" -Raw -Encoding UTF8); $r.AC | Should -Be 1800; $r.DC | Should -Be 900 }
  It 'reads English output' { $r = Get-PowerIndexFromQueryOutput -Text (Get-Content "$PSScriptRoot\fixtures\powercfg-en.txt" -Raw -Encoding UTF8); $r.AC | Should -BeOfType [int] }
  It 'returns AC and DC as ints taken from the last two values, not the Min/Max/Increment lines' {
    $r = Get-PowerIndexFromQueryOutput -Text (Get-Content "$PSScriptRoot\fixtures\powercfg-en.txt" -Raw -Encoding UTF8)
    $r.AC | Should -BeOfType [int]; $r.DC | Should -BeOfType [int]
    $r.Keys.Count | Should -Be 2
    $r.AC | Should -Be 0; $r.DC | Should -Be 240          # 0x00000000 and 0x000000f0 in the captured fixture
  }
  It 'accepts upper-case hex digits' {
    $r = Get-PowerIndexFromQueryOutput -Text "AC: 0x0000000A`nDC: 0x000000FF"
    $r.AC | Should -Be 10; $r.DC | Should -Be 255
  }
  It 'throws a clear message when fewer than two values are present' {
    { Get-PowerIndexFromQueryOutput -Text 'Current AC Power Setting Index: 0x00000708' } | Should -Throw 'powercfg output had no AC/DC values'
    { Get-PowerIndexFromQueryOutput -Text 'The power scheme, subgroup or setting specified does not exist.' } | Should -Throw 'powercfg output had no AC/DC values'
    { Get-PowerIndexFromQueryOutput -Text '' } | Should -Throw 'powercfg output had no AC/DC values'
    { Get-PowerIndexFromQueryOutput -Text $null } | Should -Throw 'powercfg output had no AC/DC values'
  }
  It 'refuses a value that does not fit an int rather than storing a wrong one' {
    { Get-PowerIndexFromQueryOutput -Text "AC: 0xffffffff`nDC: 0x00000001" } | Should -Throw '*out of range*'
  }
}

Describe 'power setting map' {
  It 'holds the four settings in order with the exact GUIDs' {
    $names = @($script:PowerSettingMap | ForEach-Object { $_.Name })
    $names | Should -Be @('STANDBYIDLE', 'HIBERNATEIDLE', 'VIDEOIDLE', 'LIDACTION')
    foreach ($e in $script:PowerSettingMap) {
      $e.Sub | Should -Be $script:PwrGuid[$e.Name].Sub
      $e.Setting | Should -Be $script:PwrGuid[$e.Name].Setting
    }
  }
}

Describe 'resume task definition' {
  It 'quotes a script path with spaces and keeps a Hebrew user id' {
    $d = Get-ResumeTaskDefinition -ScriptPath 'C:\Ben Tech\Setup\setup.ps1' -UserId 'PC-1\בן גולדנברג'
    $d.Argument | Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\Ben Tech\Setup\setup.ps1" -Resume'; $d.UserId | Should -Be 'PC-1\בן גולדנברג'
  }
  It 'runs on battery, never times out, priority 5' {
    $s = (Get-ResumeTaskDefinition -ScriptPath 'C:\x.ps1' -UserId 'a\b').Settings
    $s.DisallowStartIfOnBatteries | Should -BeFalse; $s.StopIfGoingOnBatteries | Should -BeFalse
    $s.ExecutionTimeLimit | Should -Be 'PT0S'; $s.Priority | Should -Be 5; $s.MultipleInstances | Should -Be 'IgnoreNew'
  }
  It 'starts powershell.exe' {
    (Get-ResumeTaskDefinition -ScriptPath 'C:\x.ps1' -UserId 'a\b').Execute | Should -Be 'powershell.exe'
  }
}

Describe 'folder ACL (R28)' {
  It 'is exactly: take ownership, reset every ACL below, then admin-only on the parent - in that order' {
    $c = @(Get-SetupFolderAclCommands -Parent 'C:\BenTech')
    $c | Should -Be @(
      '"C:\BenTech" /setowner *S-1-5-32-544 /T'
      '"C:\BenTech" /reset /T'
      '"C:\BenTech" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F'
    )
  }
  It 'uses SIDs only, never localized group names' {
    $all = (Get-SetupFolderAclCommands -Parent 'C:\BenTech') -join ' '
    $all | Should -Match '\*S-1-5-32-544'; $all | Should -Match '\*S-1-5-18'
    $all | Should -Not -Match 'Administrators|SYSTEM|Everyone'
  }
  It 'never uses /C (it makes icacls exit 0 even when every file failed)' {
    (Get-SetupFolderAclCommands -Parent 'C:\BenTech') -join ' ' | Should -Not -Match '/C\b'
  }
  It 'keeps a path with spaces together and never ends the quote with a backslash' {
    @(Get-SetupFolderAclCommands -Parent 'C:\Ben Tech\') | ForEach-Object { $_ | Should -Match '^"C:\\Ben Tech" /' }
  }
  It 'refuses a drive root, a relative or an empty path (a recursive owner change there would wreck the system)' {
    foreach ($bad in 'C:\', 'C:', 'BenTech', '.\BenTech', '\BenTech', ' ') {
      { Get-SetupFolderAclCommands -Parent $bad } | Should -Throw
    }
  }
}

Describe 'Register-ResumeTask' {
  BeforeEach { Initialize-PrepareMocks }

  It 'registers BenTechSetup-Resume at logon of the current user, interactive, highest, with -Force' {
    Register-ResumeTask -ScriptPath 'C:\Ben Tech\Setup\setup.ps1'
    $uid = "$env:USERDOMAIN\$env:USERNAME"
    Should -Invoke Register-ScheduledTask -Times 1 -Exactly
    $script:regTask.TaskName | Should -Be 'BenTechSetup-Resume'
    $script:regTask.Force | Should -BeTrue
    $script:regTask.Action.Execute | Should -Be 'powershell.exe'
    $script:regTask.Action.Arguments | Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\Ben Tech\Setup\setup.ps1" -Resume'
    $script:regTask.Trigger.CimClass.CimClassName | Should -Be 'MSFT_TaskLogonTrigger'
    $script:regTask.Trigger.UserId | Should -Be $uid
    $script:regTask.Principal.UserId | Should -Be $uid
    [string]$script:regTask.Principal.LogonType | Should -Be 'Interactive'
    [string]$script:regTask.Principal.RunLevel | Should -Be 'Highest'
    $script:regTask.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
  }
}

Describe 'Unregister-ResumeTask' {
  BeforeEach { Initialize-PrepareMocks }

  It 'removes the task by name without a confirmation prompt' {
    Unregister-ResumeTask
    Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'BenTechSetup-Resume' -and $Confirm -eq $false }
  }
  It 'never throws when the task is absent or cannot be removed' {
    Mock Unregister-ScheduledTask { throw 'No MSFT_ScheduledTask objects found with property TaskName equal to BenTechSetup-Resume.' }
    { Unregister-ResumeTask } | Should -Not -Throw
  }
}

Describe 'Save-OriginalPowerSettings' {
  BeforeEach { Initialize-PrepareMocks }

  It 'reads each setting with powercfg /query SCHEME_CURRENT, captured, with a 2 minute timeout' {
    $state = @{ Power = @{ Original = @{} } }
    $script:queryValues[$script:PwrGuid.STANDBYIDLE.Setting] = @{ AC = 1800; DC = 900 }
    Save-OriginalPowerSettings -State $state | Out-Null
    $queries = @($script:ext | Where-Object { $_.Args -like '/query *' })
    $queries.Count | Should -Be 4
    foreach ($q in $queries) {
      $q.File | Should -Be (Join-Path $env:windir 'System32\powercfg.exe')
      $q.Capture | Should -BeTrue
      $q.Timeout | Should -Be 2
    }
    foreach ($n in $script:PwrGuid.Keys) { $queries.Args | Should -Contain "/query SCHEME_CURRENT $($script:PwrGuid[$n].Sub) $($script:PwrGuid[$n].Setting)" }
    $state.Power.Original.Keys.Count | Should -Be 4
    $state.Power.Original.STANDBYIDLE.AC | Should -Be 1800
    $state.Power.Original.STANDBYIDLE.DC | Should -Be 900
    $state.Power.Original.STANDBYIDLE.AC | Should -BeOfType [int]
    $state.Power.Original.LIDACTION.AC | Should -Be 111
    $state.Power.Original.LIDACTION.DC | Should -Be 222
  }
  It 'does not capture again when Original already holds values (a re-run must not save the setup values)' {
    $state = @{ Power = @{ Original = @{ STANDBYIDLE = @{ AC = 1800; DC = 900 } } } }
    Save-OriginalPowerSettings -State $state | Out-Null
    Should -Invoke Invoke-External -Times 0 -Exactly
    $state.Power.Original.Keys.Count | Should -Be 1
    $state.Power.Original.STANDBYIDLE.AC | Should -Be 1800
  }
  It 'skips a failed LIDACTION query silently (desktops) and still reports success' {
    $script:failExternal = @([regex]::Escape($script:PwrGuid.LIDACTION.Setting))
    $state = @{ Power = @{ Original = @{} } }
    $ok = Save-OriginalPowerSettings -State $state
    $ok | Should -BeTrue
    $state.Power.Original.ContainsKey('LIDACTION') | Should -BeFalse
    $state.Power.Original.Keys.Count | Should -Be 3
  }
  It 'reports failure, and keeps the others, when a required query fails' {
    $script:failExternal = @([regex]::Escape($script:PwrGuid.VIDEOIDLE.Setting))
    $state = @{ Power = @{ Original = @{} } }
    $ok = Save-OriginalPowerSettings -State $state
    $ok | Should -BeFalse
    $state.Power.Original.ContainsKey('VIDEOIDLE') | Should -BeFalse
    $state.Power.Original.ContainsKey('STANDBYIDLE') | Should -BeTrue
  }
  It 'treats unparseable output as a failed query, not a crash' {
    $script:queryValues.Remove($script:PwrGuid.HIBERNATEIDLE.Setting)       # exit 0 but no values in the output
    $state = @{ Power = @{ Original = @{} } }
    { $script:ok = Save-OriginalPowerSettings -State $state } | Should -Not -Throw
    $script:ok | Should -BeFalse
    $state.Power.Original.ContainsKey('HIBERNATEIDLE') | Should -BeFalse
  }
  It 'treats a powercfg that cannot be started as a failed query' {
    $script:throwExternal = @('powercfg')
    $state = @{ Power = @{ Original = @{} } }
    { $script:ok = Save-OriginalPowerSettings -State $state } | Should -Not -Throw
    $script:ok | Should -BeFalse
    $state.Power.Original.Keys.Count | Should -Be 0
  }
}

Describe 'Set-SetupPowerSettings' {
  BeforeEach { Initialize-PrepareMocks }

  It 'sets AC and DC to 0 for every setting, then activates the scheme' {
    $ok = Set-SetupPowerSettings
    $ok | Should -BeTrue
    foreach ($kind in 'ac', 'dc') {
      $sets = @(Get-PowercfgSet -Kind $kind)
      $sets.Count | Should -Be 4
      foreach ($n in $script:PwrGuid.Keys) {
        $hit = @($sets | Where-Object { $_.Sub -eq $script:PwrGuid[$n].Sub -and $_.Setting -eq $script:PwrGuid[$n].Setting })
        $hit.Count | Should -Be 1
        $hit[0].Value | Should -Be 0
      }
    }
    $script:ext[-1].Args | Should -Be '/setactive SCHEME_CURRENT'
    @($script:ext | Where-Object { $_.Args -eq '/setactive SCHEME_CURRENT' }).Count | Should -Be 1
    foreach ($e in $script:ext) { $e.File | Should -Be (Join-Path $env:windir 'System32\powercfg.exe'); $e.Timeout | Should -Be 2 }
  }
  It 'keeps going and reports failure when a required set fails' {
    $script:failExternal = @('^\S+ /setacvalueindex SCHEME_CURRENT \S+ ' + [regex]::Escape($script:PwrGuid.STANDBYIDLE.Setting))
    $ok = Set-SetupPowerSettings
    $ok | Should -BeFalse
    @(Get-PowercfgSet -Kind 'dc').Count | Should -Be 4
    $script:ext[-1].Args | Should -Be '/setactive SCHEME_CURRENT'
  }
  It 'does not report failure when only the LIDACTION settings fail' {
    $script:failExternal = @([regex]::Escape($script:PwrGuid.LIDACTION.Setting))
    Set-SetupPowerSettings | Should -BeTrue
    @(Get-PowercfgSet -Kind 'ac').Count | Should -Be 4        # it still tried
  }
}

Describe 'Restore-FinalPowerSettings' {
  BeforeEach {
    Initialize-PrepareMocks
    $script:origState = @{ Power = @{ Original = @{
          STANDBYIDLE   = @{ AC = 1800; DC = 900 }
          HIBERNATEIDLE = @{ AC = 10800; DC = 5400 }
          VIDEOIDLE     = @{ AC = 600; DC = 300 }
          LIDACTION     = @{ AC = 1; DC = 2 }
        } } }
  }

  It 'AC: sleep and hibernate never, display off after the configured minutes, lid action as it was' {
    Restore-FinalPowerSettings -State $script:origState -Config (New-PrepareConfig) | Should -BeTrue
    $ac = @(Get-PowercfgSet -Kind 'ac')
    $ac.Count | Should -Be 4
    ($ac | Where-Object { $_.Setting -eq $script:PwrGuid.STANDBYIDLE.Setting }).Value | Should -Be 0
    ($ac | Where-Object { $_.Setting -eq $script:PwrGuid.HIBERNATEIDLE.Setting }).Value | Should -Be 0
    ($ac | Where-Object { $_.Setting -eq $script:PwrGuid.VIDEOIDLE.Setting }).Value | Should -Be 900
    ($ac | Where-Object { $_.Setting -eq $script:PwrGuid.LIDACTION.Setting }).Value | Should -Be 1
  }
  It 'DC: all four go back to their original values' {
    Restore-FinalPowerSettings -State $script:origState -Config (New-PrepareConfig) | Out-Null
    $dc = @(Get-PowercfgSet -Kind 'dc')
    $dc.Count | Should -Be 4
    ($dc | Where-Object { $_.Setting -eq $script:PwrGuid.STANDBYIDLE.Setting }).Value | Should -Be 900
    ($dc | Where-Object { $_.Setting -eq $script:PwrGuid.HIBERNATEIDLE.Setting }).Value | Should -Be 5400
    ($dc | Where-Object { $_.Setting -eq $script:PwrGuid.VIDEOIDLE.Setting }).Value | Should -Be 300
    ($dc | Where-Object { $_.Setting -eq $script:PwrGuid.LIDACTION.Setting }).Value | Should -Be 2
  }
  It 'sends each value to the right subgroup' {
    Restore-FinalPowerSettings -State $script:origState -Config (New-PrepareConfig) | Out-Null
    foreach ($s in @(Get-PowercfgSet -Kind 'ac') + @(Get-PowercfgSet -Kind 'dc')) {
      $name = ($script:PwrGuid.Keys | Where-Object { $script:PwrGuid[$_].Setting -eq $s.Setting })
      $s.Sub | Should -Be $script:PwrGuid[$name].Sub
    }
  }
  It 'scales the monitor timeout from the config (minutes -> seconds)' {
    $cfg = New-PrepareConfig; $cfg.power.finalAcMonitorMinutes = 20
    Restore-FinalPowerSettings -State $script:origState -Config $cfg | Out-Null
    (Get-PowercfgSet -Kind 'ac' | Where-Object { $_.Setting -eq $script:PwrGuid.VIDEOIDLE.Setting }).Value | Should -Be 1200
  }
  It 'activates the scheme last, once' {
    Restore-FinalPowerSettings -State $script:origState -Config (New-PrepareConfig) | Out-Null
    $script:ext[-1].Args | Should -Be '/setactive SCHEME_CURRENT'
    @($script:ext | Where-Object { $_.Args -eq '/setactive SCHEME_CURRENT' }).Count | Should -Be 1
  }
  It 'skips what was never captured instead of inventing a value' {
    $state = @{ Power = @{ Original = @{ STANDBYIDLE = @{ AC = 1800; DC = 900 } } } }
    Restore-FinalPowerSettings -State $state -Config (New-PrepareConfig) | Should -BeFalse     # three required originals are missing
    $dc = @(Get-PowercfgSet -Kind 'dc')
    $dc.Count | Should -Be 1
    $dc[0].Setting | Should -Be $script:PwrGuid.STANDBYIDLE.Setting
    $ac = @(Get-PowercfgSet -Kind 'ac')
    $ac.Count | Should -Be 3                                    # LIDACTION AC has no original to go back to
    $ac.Setting | Should -Not -Contain $script:PwrGuid.LIDACTION.Setting
  }
  It 'returns $false when a required original is missing (it would stay at 0 on battery), but writes everything else' {
    $script:origState.Power.Original.Remove('STANDBYIDLE')
    Restore-FinalPowerSettings -State $script:origState -Config (New-PrepareConfig) | Should -BeFalse
    $ac = @(Get-PowercfgSet -Kind 'ac')
    $dc = @(Get-PowercfgSet -Kind 'dc')
    $ac.Count | Should -Be 4                                   # AC values do not depend on an original (except LIDACTION, present here)
    $dc.Count | Should -Be 3
    $dc.Setting | Should -Not -Contain $script:PwrGuid.STANDBYIDLE.Setting
    foreach ($n in 'HIBERNATEIDLE', 'VIDEOIDLE', 'LIDACTION') { $dc.Setting | Should -Contain $script:PwrGuid[$n].Setting }
    $script:ext[-1].Args | Should -Be '/setactive SCHEME_CURRENT'
  }
  It 'returns $false when any one required original is missing: <Name>' -ForEach @(
    @{ Name = 'STANDBYIDLE' }, @{ Name = 'HIBERNATEIDLE' }, @{ Name = 'VIDEOIDLE' }
  ) {
    $script:origState.Power.Original.Remove($Name)
    Restore-FinalPowerSettings -State $script:origState -Config (New-PrepareConfig) | Should -BeFalse
  }
  It 'returns $true when only the LIDACTION original is missing (a desktop has no lid)' {
    $script:origState.Power.Original.Remove('LIDACTION')
    Restore-FinalPowerSettings -State $script:origState -Config (New-PrepareConfig) | Should -BeTrue
    @(Get-PowercfgSet -Kind 'dc').Count | Should -Be 3
    @(Get-PowercfgSet -Kind 'ac').Count | Should -Be 3
  }
  It 'returns $false when nothing was ever captured' {
    Restore-FinalPowerSettings -State @{ Power = @{ Original = @{} } } -Config (New-PrepareConfig) | Should -BeFalse
    Restore-FinalPowerSettings -State @{} -Config (New-PrepareConfig) | Should -BeFalse
  }
  It 'reports failure but still does every other write when one fails' {
    $script:failExternal = @('^\S+ /setdcvalueindex SCHEME_CURRENT \S+ ' + [regex]::Escape($script:PwrGuid.VIDEOIDLE.Setting))
    Restore-FinalPowerSettings -State $script:origState -Config (New-PrepareConfig) | Should -BeFalse
    @(Get-PowercfgSet -Kind 'dc').Count | Should -Be 4
    $script:ext[-1].Args | Should -Be '/setactive SCHEME_CURRENT'
  }
}

Describe 'Invoke-StepPrepare' {
  BeforeEach { Initialize-PrepareMocks }

  It 'returns Done with the prepared message and no notes when everything works' {
    $r = Invoke-StepPrepare -Context (New-PrepareContext)
    $r.Status | Should -Be 'Done'
    $r.Message | Should -Be 'Machine prepared'
    $r.Reboot | Should -Be 'None'
    @($r.Notes).Count | Should -Be 0
    @($r.Errors).Count | Should -Be 0
  }

  It 'runs in the documented order: icacls, resume task, power capture, power set, Fast Startup, nags, no-auto-reboot' {
    Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
    $order = @(
      (Get-CallIndex '^icacls$'),
      (Get-CallIndex '^task$'),
      (Get-CallIndex '^powercfg /query '),
      (Get-CallIndex '^powercfg /setacvalueindex '),
      (Get-CallIndex '^powercfg /setactive '),
      (Get-CallIndex 'regvalue .*HiberbootEnabled'),
      (Get-CallIndex 'regvalue HKCU:\\Software\\Test\\One NagOne'),
      (Get-CallIndex 'regvalue HKCU:\\Software\\Test\\Two NagTwo'),
      (Get-CallIndex 'regvalue .*NoAutoRebootWithLoggedOnUsers')
    )
    ($order -contains -1) | Should -BeFalse
    for ($i = 1; $i -lt $order.Count; $i++) { $order[$i] | Should -BeGreaterThan $order[$i - 1] }
    # all captures happen before the first set
    $lastQuery = ($script:calls | ForEach-Object -Begin { $k = 0; $last = -1 } -Process { if ($_ -match '^powercfg /query ') { $last = $k }; $k++ } -End { $last })
    $lastQuery | Should -BeLessThan (Get-CallIndex '^powercfg /setacvalueindex ')
  }

  It 'locks down the PARENT folder with the three icacls commands in order, through Invoke-External (R28)' {
    Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
    $icacls = @($script:ext | Where-Object { $_.File -match 'icacls\.exe$' })
    $icacls.Count | Should -Be 3
    foreach ($call in $icacls) {
      $call.File | Should -Be (Join-Path $env:windir 'System32\icacls.exe')
      $call.Timeout | Should -Be 7           # config timeoutsMinutes.default
    }
    @($icacls | ForEach-Object { $_.Args }) | Should -Be @(Get-SetupFolderAclCommands -Parent 'C:\BenTech')
    @($script:calls | Where-Object { $_ -like 'mkdir *' }) | Should -BeNullOrEmpty     # both folders already exist
  }

  It 'creates a missing parent folder before icacls, and the working folder after it (R28)' {
    $script:existingFolders = @()
    Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
    (Get-CallIndex '^mkdir C:\\BenTech$') | Should -BeLessThan (Get-CallIndex '^icacls$')
    $lastIcacls = ($script:calls | ForEach-Object -Begin { $k = 0; $last = -1 } -Process { if ($_ -eq 'icacls') { $last = $k }; $k++ } -End { $last })
    (Get-CallIndex '^mkdir C:\\BenTech\\Setup$') | Should -BeGreaterThan $lastIcacls
  }

  It 'registers the resume task for the context script path' {
    Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
    Should -Invoke Register-ScheduledTask -Times 1 -Exactly
    $script:regTask.TaskName | Should -Be 'BenTechSetup-Resume'
    $script:regTask.Action.Arguments | Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\BenTech\Setup\setup.ps1" -Resume'
  }

  It 'captures the original power settings into State, then sets AC and DC to 0 (one call per setting and kind)' {
    $ctx = New-PrepareContext
    Invoke-StepPrepare -Context $ctx | Out-Null
    $ctx.State.Power.Original.Keys.Count | Should -Be 4
    $ctx.State.Power.Original.VIDEOIDLE.AC | Should -Be 111
    $ctx.State.Power.Original.VIDEOIDLE.DC | Should -Be 222
    foreach ($kind in 'ac', 'dc') {
      $sets = @(Get-PowercfgSet -Kind $kind)
      $sets.Count | Should -Be 4
      ($sets | Where-Object { $_.Value -ne 0 }).Count | Should -Be 0
    }
    @($script:ext | Where-Object { $_.Args -eq '/setactive SCHEME_CURRENT' }).Count | Should -Be 1
  }

  It 'turns off Fast Startup (HiberbootEnabled = 0, DWord) in HKLM' {
    Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
    $v = @($script:regValues | Where-Object { $_.Name -eq 'HiberbootEnabled' })
    $v.Count | Should -Be 1
    $v[0].Path | Should -Be 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $v[0].Value | Should -Be 0
    $v[0].Type | Should -Be 'DWord'
    $v[0].Force | Should -BeTrue
  }

  It 'writes every configured nag as a DWord and creates the key first when it is missing' {
    Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
    $one = @($script:regValues | Where-Object { $_.Name -eq 'NagOne' })
    $two = @($script:regValues | Where-Object { $_.Name -eq 'NagTwo' })
    $one.Count | Should -Be 1; $two.Count | Should -Be 1
    $one[0].Path | Should -Be 'HKCU:\Software\Test\One'; $one[0].Value | Should -Be 0; $one[0].Type | Should -Be 'DWord'
    $two[0].Path | Should -Be 'HKCU:\Software\Test\Two'; $two[0].Value | Should -Be 0; $two[0].Type | Should -Be 'DWord'
    $script:regKeys | Should -Contain 'HKCU:\Software\Test\One'
    (Get-CallIndex '^regkey HKCU:\\Software\\Test\\One$') | Should -BeLessThan (Get-CallIndex 'regvalue HKCU:\\Software\\Test\\One NagOne')
  }

  It 'does not re-create a key that already exists (New-Item -Force would clear its values)' {
    $script:existingKeys = @('HKCU:\Software\Test\One', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power')
    Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
    $script:regKeys | Should -Not -Contain 'HKCU:\Software\Test\One'
    $script:regKeys | Should -Not -Contain 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $script:regKeys | Should -Contain 'HKCU:\Software\Test\Two'
    @($script:regValues | Where-Object { $_.Name -eq 'NagOne' }).Count | Should -Be 1
  }

  It 'stops Windows rebooting by itself while someone is logged on (NoAutoRebootWithLoggedOnUsers = 1)' {
    Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
    $v = @($script:regValues | Where-Object { $_.Name -eq 'NoAutoRebootWithLoggedOnUsers' })
    $v.Count | Should -Be 1
    $v[0].Path | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $v[0].Value | Should -Be 1
    $v[0].Type | Should -Be 'DWord'
    $script:regKeys | Should -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  }

  It 'does not capture the setup values again on a re-run' {
    $ctx = New-PrepareContext
    $ctx.State.Power.Original = @{ STANDBYIDLE = @{ AC = 1800; DC = 900 } }
    Invoke-StepPrepare -Context $ctx | Out-Null
    @($script:ext | Where-Object { $_.Args -like '/query *' }).Count | Should -Be 0
    $ctx.State.Power.Original.STANDBYIDLE.AC | Should -Be 1800
    @(Get-PowercfgSet -Kind 'ac').Count | Should -Be 4          # but the settings are applied again
  }

  Context 'when something fails' {
    # R28: the working folder is fail-closed. Any failure is Failed('Working folder could not be secured')
    # with an Error; the rest of the step still runs, like a failed resume task.
    It 'a non-zero icacls exit fails the step, stops the icacls sequence, and the rest still runs' {
      $script:failExternal = @('/setowner')
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Working folder could not be secured'
      @($r.Errors | Where-Object { $_ -match 'C:\\BenTech' -and $_ -match 'admin' }).Count | Should -Be 1
      @($script:ext | Where-Object { $_.File -match 'icacls\.exe$' }).Count | Should -Be 1     # /reset and the grant never ran
      Should -Invoke Register-ScheduledTask -Times 1 -Exactly
      (Get-CallIndex '^powercfg /setactive') | Should -BeGreaterThan -1
      @($script:regValues | Where-Object { $_.Name -eq 'NoAutoRebootWithLoggedOnUsers' }).Count | Should -Be 1
    }
    It 'a failure on the last icacls command (the grant) also fails the step' {
      $script:failExternal = @('/inheritance:r')
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Working folder could not be secured'
    }
    It 'an icacls that cannot be started fails the step' {
      $script:throwExternal = @('icacls')
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Working folder could not be secured'
    }
    It 'a timed-out icacls fails the step' {
      Mock Invoke-External { return @{ ExitCode = $null; TimedOut = $true; Output = '' } } -ParameterFilter { $FilePath -match 'icacls' }
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Working folder could not be secured'
    }
    It 'refuses a parent folder that is a junction or symlink, without running icacls' {
      $script:reparseFolders = @('C:\BenTech')
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Working folder could not be secured'
      @($script:ext | Where-Object { $_.File -match 'icacls\.exe$' }) | Should -BeNullOrEmpty
    }
    It 'refuses a working folder that is a junction or symlink, without running icacls' {
      $script:reparseFolders = @('C:\BenTech\Setup')
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Failed'
      @($script:ext | Where-Object { $_.File -match 'icacls\.exe$' }) | Should -BeNullOrEmpty
    }
    It 'checks for a junction again after icacls (one swapped in before the lockdown is still refused)' {
      $script:reparseAfterIcacls = @('C:\BenTech\Setup')
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Working folder could not be secured'
      @($script:ext | Where-Object { $_.File -match 'icacls\.exe$' }).Count | Should -Be 3
    }
    It 'reports the folder first when the resume task fails too, and keeps both errors' {
      $script:failExternal = @('/reset')
      $script:registerFailuresLeft = 99
      $r = Invoke-StepPrepare -Context (New-PrepareContext) -ResumeTaskRetrySeconds 0
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Working folder could not be secured'
      @($r.Errors).Count | Should -Be 2
    }
    It 'a failed powercfg set is one Note for the whole step, never a failure' {
      $script:failExternal = @('/setacvalueindex', '/setdcvalueindex')
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Done'
      @($r.Notes | Where-Object { $_ -eq 'Some power settings could not be applied' }).Count | Should -Be 1
      @($script:regValues | Where-Object { $_.Name -eq 'HiberbootEnabled' }).Count | Should -Be 1
    }
    It 'a failed powercfg query is a Note and the sets still run' {
      $script:failExternal = @('^\S+ /query ')
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Done'
      $r.Notes | Should -Contain 'Some power settings could not be applied'
      @(Get-PowercfgSet -Kind 'ac').Count | Should -Be 4
    }
    It 'a missing lid setting (desktop) leaves no Note' {
      $script:failExternal = @([regex]::Escape($script:PwrGuid.LIDACTION.Setting))
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Done'
      @($r.Notes).Count | Should -Be 0
    }
    It 'a registry write that is refused is a Note, and the remaining writes are still tried' {
      $script:throwNewItemProperty = $true
      $r = Invoke-StepPrepare -Context (New-PrepareContext)
      $r.Status | Should -Be 'Done'
      $r.Notes | Should -Contain 'Some Windows settings could not be applied'
      @($script:calls | Where-Object { $_ -like 'regvalue *' }).Count | Should -Be 4   # Hiberboot + 2 nags + NoAutoReboot
    }
    It 'a resume task that cannot be registered fails the step, but the machine is still prepared' {
      $script:registerFailuresLeft = 99
      $r = Invoke-StepPrepare -Context (New-PrepareContext) -ResumeTaskRetrySeconds 0
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Could not register the resume task'
      @($r.Errors).Count | Should -BeGreaterThan 0
      (Get-CallIndex '^powercfg /setactive') | Should -BeGreaterThan -1
      @($script:regValues | Where-Object { $_.Name -eq 'NoAutoRebootWithLoggedOnUsers' }).Count | Should -Be 1
    }
  }

  # Ruling R15: a failed registration is retried once, and a final failure is flagged for the reboot code.
  Context 'resume task retry (R15)' {
    It 'registers once, without waiting, when the first attempt works' {
      $ctx = New-PrepareContext
      $r = Invoke-StepPrepare -Context $ctx
      $r.Status | Should -Be 'Done'
      Should -Invoke Register-ScheduledTask -Times 1 -Exactly
      Should -Invoke Start-Sleep -Times 0 -Exactly
      $ctx.State.ContainsKey('ResumeTaskMissing') | Should -BeFalse
    }
    It 'first attempt throws, second works: Done, no ResumeTaskMissing' {
      $script:registerFailuresLeft = 1
      $ctx = New-PrepareContext
      $r = Invoke-StepPrepare -Context $ctx -ResumeTaskRetrySeconds 0
      $r.Status | Should -Be 'Done'
      $r.Message | Should -Be 'Machine prepared'
      @($r.Errors).Count | Should -Be 0
      Should -Invoke Register-ScheduledTask -Times 2 -Exactly
      $ctx.State.ContainsKey('ResumeTaskMissing') | Should -BeFalse
      $script:regTask.TaskName | Should -Be 'BenTechSetup-Resume'          # the second call is the one that registered
    }
    It 'both attempts throw: Failed, ResumeTaskMissing is set, and the delay can be injected as 0' {
      $script:registerFailuresLeft = 5
      $ctx = New-PrepareContext
      $r = Invoke-StepPrepare -Context $ctx -ResumeTaskRetrySeconds 0
      $r.Status | Should -Be 'Failed'
      $r.Message | Should -Be 'Could not register the resume task'
      @($r.Errors).Count | Should -BeGreaterThan 0
      Should -Invoke Register-ScheduledTask -Times 2 -Exactly               # one retry, no more
      Should -Invoke Start-Sleep -Times 0 -Exactly
      $ctx.State.ResumeTaskMissing | Should -BeTrue
      (Get-CallIndex '^powercfg /setactive') | Should -BeGreaterThan -1       # the rest of the step still ran
    }
    It 'waits 10 seconds between the two attempts by default' {
      $script:registerFailuresLeft = 1
      Invoke-StepPrepare -Context (New-PrepareContext) | Out-Null
      Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
      $first = Get-CallIndex '^task$'
      $sleep = Get-CallIndex '^sleep 10$'
      $first | Should -BeGreaterThan -1
      $sleep | Should -BeGreaterThan $first
      @($script:calls | Where-Object { $_ -eq 'task' }).Count | Should -Be 2
      $script:calls.LastIndexOf('task') | Should -BeGreaterThan $sleep
    }
  }
}
