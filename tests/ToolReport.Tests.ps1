# tests/ToolReport.Tests.ps1
# Repair & diagnostics Task 8 (repair spec 6.8; rulings RD-R12, RD-R13, RD-R20, RD-R21, RD-R23, RD-R24): the Quick and
# Full reports: the section collectors (src\Repair\ToolCollect.ps1), the flags, the event grouping, the AI-ready core, its
# size limit, the data JSON, raw\ and the zip (src\Repair\ToolReport.ps1), and their catalog rows.
#
# SAFETY: this runs on Ben's real PC. For real, the collectors read this PC's event logs, programs, drivers, devices,
# disks, network, services, users and CIM, start PowerShell grandchildren (Get-PhysicalDisk, Get-WinEvent,
# Get-WindowsDriver, Get-Printer, Get-MpComputerStatus, Get-NetTCPConnection, Get-LocalGroupMember, ...) and run
# systeminfo, vssadmin, gpresult, dsregcmd, powercfg, wevtutil and msinfo32. Here nothing is started, nothing is changed
# and no answer comes from this PC: every source answers from the fake PC of tests\fixtures\ReportFakePc.ps1 (its header lists
# the mocks and the safety nets); the sample report is built from the real collectors on that fake PC, and the huge
# one from the sample, at test time (review M8, M9). Every file a test writes is under $TestDrive.
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Common\Config', 'State\State', 'Steps\Winget', 'Engine\Reboot',
                 'UI\StartScreen', 'Toolbox\Strings', 'Entry\Cleanup', 'Detect\Detection', 'Detect\PcName', 'Report\Report', 'Repair\ToolEngine',
                 'Repair\ToolChecks', 'Repair\ToolSafety', 'Repair\ToolRepairs', 'Repair\ToolAdvanced', 'Repair\ToolCollect', 'Repair\ToolReport',
                 'Repair\ToolPrivacy', 'Repair\ToolCompare') {
    . "$PSScriptRoot\..\src\$f.ps1"
  }
  . "$PSScriptRoot\fixtures\ReportFakePc.ps1"
  Initialize-ReportFakePc
  $script:collectFile = "$PSScriptRoot\..\src\Repair\ToolCollect.ps1"
  $script:reportFile = "$PSScriptRoot\..\src\Repair\ToolReport.ps1"
  # The real code of a function the collectors' tests mock (Pester 6 never falls through to the original).
  $script:realTcpHosts = ${function:Test-ToolTcpHosts}
  # The fixed reasons a "not collected" line may give (review M11: never a tool's or Windows' own, localized, text).
  $script:reasonPattern = '^(timed out|failed|no result|no answer|output too large|access denied|not found|not supported|is a link|no system drive letter|no signed-in user|no SID for the user|not enough time left|not run: the report was stopped or ran out of time|exit 0x[0-9A-F]{8}|no file \(exit 0x[0-9A-F]{8}\))$'

  function Get-StepStatus { param($Run, [string]$Id) foreach ($s in $Run.Steps) { if ($s.Id -eq $Id) { return $s.Status } } }
  function Get-Codes { param($Findings) @(foreach ($f in $Findings) { [string]$f.Code }) }
  function Get-Flag { param($Findings, [string]$Code) foreach ($f in $Findings) { if ([string]$f.Code -ceq $Code) { return $f } } }
  # Every text value inside -Value, flattened (to look for a word anywhere in a section).
  function Get-AllText {
    param($Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { [string]$k; Get-AllText -Value $Value[$k] }; return }
    if ($Value -is [System.Collections.IEnumerable]) { foreach ($v in $Value) { Get-AllText -Value $v }; return }
    [string]$Value
  }
  # -Count event groups (400 a log at most, as the grandchild keeps), the oldest last, with ~150-character messages.
  function New-ManyGroups {
    param([string]$Log, [int]$Count)
    @(for ($i = 0; $i -lt $Count; $i++) {
        $day = 22 - [int][math]::Floor($i / 40)
        @{ Provider = "$Log-Provider-$i"; Id = 1000 + $i; Level = 3; Count = 2; First = ('2026-10-{0:D2}T08:00:00' -f [math]::Max(1, $day - 1)); Last = ('2026-10-{0:D2}T09:00:00' -f [math]::Max(1, $day))
           Message = ("$Log warning number $i " + ('x' * 130)) } })
  }
}

Describe 'ToolReport (repair Task 8)' {
  BeforeAll {
    Register-ReportFakePcMocks
    Reset-ReportFakePc
    $script:sample = New-ReportSample
    $script:huge = New-ReportHuge -Sample $script:sample
    $script:core = Format-ReportCore -Report $script:sample -Kind full
    if (@($script:blocked).Count -gt 0) { throw ('The sample touched a blocked command: ' + (@($script:blocked) -join ', ')) }
  }
  BeforeEach { Reset-ReportFakePc }
  AfterEach {
    @($script:blocked) | Should -BeNullOrEmpty
    $script:SetupLogPath = $null
    Unregister-SetupTick
  }

  Describe 'the catalog rows (repair plan, Actions and steps)' {
    It 'quickReport and fullReport are read-only, need the stick, log to the session, and list their sections in order' {
      foreach ($id in 'quickReport', 'fullReport') {
        $a = $script:ToolActionCatalog[$id]
        $a | Should -Not -BeNullOrEmpty -Because $id
        $a.Kind | Should -Be 'readonly'; $a.Confirm | Should -Be 'none'; $a.NeedsStick | Should -BeTrue; $a.LogLocal | Should -BeFalse
      }
      @($script:ToolActionCatalog['quickReport'].Steps) | Should -Be @('report01', 'report02', 'report03', 'report04', 'report05', 'report06', 'report07', 'report08',
                                                                       'report09', 'report10', 'report11', 'reportWrite')
      @($script:ToolActionCatalog['fullReport'].Steps) | Should -Be @('report01', 'report02', 'report03', 'report04', 'report05', 'report06', 'report07', 'report08',
                                                                      'report09', 'report10', 'report11', 'report12', 'reportWrite', 'reportZip')
    }
    It 'every report step has its function, none is a servicing step, and only reportWrite always runs (a stopped report still writes what it has)' {
      foreach ($id in @($script:ToolActionCatalog['fullReport'].Steps)) {
        $s = $script:ToolSteps[$id]
        $s | Should -Not -BeNullOrEmpty -Because $id
        $s.Function | Should -BeExactly ('Invoke-ToolStep' + $id.Substring(0, 1).ToUpperInvariant() + $id.Substring(1)) -Because $id
        (Get-Command -Name $s.Function -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because $id
        $s.Servicing | Should -BeFalse -Because $id
        ($s['AlwaysRun'] -eq $true) | Should -Be ($id -ceq 'reportWrite') -Because $id
      }
    }
    It 'every step timeout the report files name is in config.json''s toolStep' {
      $names = foreach ($file in $script:collectFile, $script:reportFile) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).Path, [ref]$null, [ref]$null)
        # The literal names (a helper that forwards its own -StepTimeout passes a variable).
        $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'StepTimeout' }, $true) | ForEach-Object {
          $i = $_.Parent.CommandElements.IndexOf($_); $v = $_.Parent.CommandElements[$i + 1]
          if ($v -is [Management.Automation.Language.StringConstantExpressionAst]) { [string]$v.Value } }
      }
      @($names).Count | Should -BeGreaterThan 5
      @($names) | Should -Contain 'zip'
      foreach ($n in $names) { $script:cfg.timeoutsMinutes.toolStep.PSObject.Properties.Name | Should -Contain $n }
    }
    It 'the report''s finding texts are the plan''s, in English and Hebrew' {
      $expected = [ordered]@{
        'finding.diskUnhealthy'        = 'Disk {0}: health {1}'
        'finding.diskErrors'           = 'Disk {0}: {1} uncorrected read/write errors'
        'finding.diskWear'             = 'Disk {0}: {1}% worn'
        'finding.diskTemp'             = 'Disk {0}: {1} C'
        'finding.diskEvents'           = 'Disk events in {0} days: {1}'
        'finding.lowSpace'             = '{0} {1} GB free ({2}%)'
        'finding.wheaFatal'            = '{0} fatal hardware errors (WHEA) in {1} days'
        'finding.wheaCorrected'        = '{0} corrected hardware errors (WHEA) in {1} days'
        'finding.bugchecks'            = '{0} blue screens in {1} days (codes {2})'
        'finding.kernelPower'          = '{0} unexpected power losses or hard resets in {1} days'
        'finding.minidumps'            = '{0} crash dumps in {1} days'
        'finding.appCrashes'           = '{0} application crashes in {1} days (most: {2})'
        'finding.wuDisabled'           = 'The Windows Update service is disabled'
        'finding.defenderOff'          = 'Defender real-time protection is off and no other antivirus is active'
        'finding.defenderSignatureOld' = 'Defender signatures are {0} days old'
        'finding.uacOff'               = 'UAC is off (EnableLUA = 0)'
        'finding.guestEnabled'         = 'The Guest account is enabled'
        'finding.autoLogon'            = 'Automatic sign-in is configured'
        'finding.rdpNoNla'             = 'Remote Desktop is on without Network Level Authentication'
        'finding.smb1On'               = 'SMBv1 is on'
        'finding.userProxy'            = 'A user proxy is set: {0}'
        'finding.hostsEntries'         = 'The hosts file has {0} active entries'
        'finding.lowRam'               = '{0} GB of RAM'
        'finding.windows10'            = 'Windows 10 (build {0}): out of support since 14/10/2025'
        'finding.uptimeLong'           = 'Up for {0} days: restart before judging stability'
        'finding.batteryWear'          = 'Battery {0}% worn'
        'finding.basicDisplay'         = 'No display driver (Microsoft Basic Display Adapter)'
        'finding.secureBootOff'        = 'Secure Boot is off'
        'finding.tpmMissing'           = 'No ready TPM'
        'finding.bitlockerOn'          = 'BitLocker is on: have the recovery key before BIOS or board work'
        'finding.safeBootSet'          = 'Safe boot is set in the boot configuration'
        'finding.ghostDevicesMany'     = '{0} disconnected devices are registered'
        'finding.autoServicesStopped'  = '{0} automatic services are not running: {1}'
        'finding.noInternet'           = 'No internet (TCP 443 and HTTPS failed)'
        'finding.firewallOff'          = 'The firewall is off for: {0}'
        'finding.notCollected'         = '{0}: not collected ({1})'
        'finding.reportWriteFailed'    = 'The report could not be written ({0})'
        'finding.reportZipFailed'      = 'The raw files could not be zipped ({0}): they are in {1}'
        # RD-R24 (review M2): the report's own clock finding; clockOff keeps its meaning for the time sync.
        'finding.clockWrong'           = 'The clock is {0} min off Microsoft''s time: HTTPS, Windows Update and activation may fail until it is fixed (Standard repair syncs it)'
      }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        $script:ToolboxStrings.he[$k] | Should -Not -Match "'" -Because $k
        ([regex]::Matches($script:ToolboxStrings.he[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',' |
          Should -Be (([regex]::Matches($expected[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',') -Because $k
      }
      # Review M2 and M11: the Hebrew texts the review settled.
      $script:ToolboxStrings.he['finding.clockWrong'] | Should -BeExactly 'השעון סוטה ב-{0} דקות מהשעה של Microsoft: חיבורי HTTPS, עדכוני Windows והפעלת Windows עלולים להיכשל עד שהשעון יתוקן (התיקון הרגיל מסנכרן אותו)'
      $script:ToolboxStrings.he['finding.windows10'] | Should -BeExactly 'מערכת Windows 10 בגרסת בנייה {0}: ללא תמיכה מאז 14/10/2025'
      # Task 6's clockOff keeps its own text: the report no longer uses it.
      $script:ToolboxStrings.en['finding.clockOff'] | Should -BeExactly 'The clock is still {0} min off after the time sync: downloads may fail'
    }
    It 'every finding code the report files add has its text in English and Hebrew' {
      $codes = foreach ($file in $script:collectFile, $script:reportFile) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).Path, [ref]$null, [ref]$null)
        foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Add-ToolFinding', 'Add-ReportFlag' }, $true)) {
          $i = 0
          foreach ($e in $c.CommandElements) { if ($e -is [Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Code') { break }; $i++ }
          if ($i + 1 -lt $c.CommandElements.Count -and $c.CommandElements[$i + 1] -is [Management.Automation.Language.StringConstantExpressionAst]) { $c.CommandElements[$i + 1].Value }
        }
      }
      @($codes).Count | Should -BeGreaterThan 40
      @($codes) | Should -Contain 'clockWrong'; @($codes) | Should -Not -Contain 'clockOff'
      foreach ($code in $codes) {
        $script:ToolboxStrings.en.Keys | Should -Contain "finding.$code"
        $script:ToolboxStrings.he.Keys | Should -Contain "finding.$code"
      }
    }
  }

  Describe 'flags (spec 6.8, review I-10)' {
    It '<Code> fires at <At> and not at <Below>' -ForEach @(
      @{ Code = 'kernelPower'; Item = 'KernelPower41'; At = 3; Below = 2 }, @{ Code = 'appCrashes'; Item = 'AppCrashes'; At = 10; Below = 9 }, @{ Code = 'lowRam'; Item = 'RamGB'; At = 7.9; Below = 8 }
      @{ Code = 'batteryWear'; Item = 'BatteryWear'; At = 40; Below = 39 }, @{ Code = 'defenderSignatureOld'; Item = 'SignatureAgeDays'; At = 8; Below = 7 }, @{ Code = 'clockWrong'; Item = 'ClockOffsetMinutes'; At = 2.1; Below = 2.0 }
      @{ Code = 'diskWear'; Item = 'Wear'; At = 80; Below = 79 }, @{ Code = 'diskTemp'; Item = 'Temperature'; At = 60; Below = 59 }, @{ Code = 'uptimeLong'; Item = 'UptimeDays'; At = 8; Below = 7 }
      @{ Code = 'ghostDevicesMany'; Item = 'GhostCount'; At = 151; Below = 150 }) {
      (Get-ReportFlags -Report (Set-ReportItem $sample $Item $At) -Config $cfg).Code | Should -Contain $Code
      (Get-ReportFlags -Report (Set-ReportItem $sample $Item $Below) -Config $cfg).Code | Should -Not -Contain $Code
    }
    It 'WHEA: corrected IDs are a WARN with a count, fatal ones a CRIT' {
      $f = Get-ReportFlags -Report (Set-ReportItem $sample 'Whea' @(@{ Id = 17; Level = 3 }, @{ Id = 19; Level = 3 }, @{ Id = 18; Level = 1 })) -Config $cfg
      ($f | Where-Object Code -eq 'wheaCorrected').Args[0] | Should -Be '2'; ($f | Where-Object Code -eq 'wheaFatal').Level | Should -Be 'CRIT'
      ($f | Where-Object Code -eq 'wheaCorrected').Level | Should -Be 'WARN'; ($f | Where-Object Code -eq 'wheaFatal').Args[0] | Should -Be '1'
    }
    It 'Kernel-Power 41 with BugcheckCode 0 is a power loss, not a blue screen' {
      $f = Get-ReportFlags -Report (Set-ReportItem $sample 'KernelPower41Events' @(@{ BugcheckCode = 0 }, @{ BugcheckCode = 0 }, @{ BugcheckCode = 0 })) -Config $cfg
      $f.Code | Should -Contain 'kernelPower'; $f.Code | Should -Not -Contain 'bugchecks'
      # A 41 that carries a bugcheck code was a blue screen: it is not counted as a power loss.
      $g = Get-ReportFlags -Report (Set-ReportItem $sample 'KernelPower41Events' @(@{ BugcheckCode = 0 }, @{ BugcheckCode = 0 }, @{ BugcheckCode = 159 })) -Config $cfg
      $g.Code | Should -Not -Contain 'kernelPower'; $g.Code | Should -Contain 'bugchecks'; ($g | Where-Object Code -eq 'bugchecks').Args[2] | Should -Be '0x0000009F'
    }
    It 'BugCheck 1001 rows are blue screens, grouped by code' {
      $f = Get-ReportFlags -Report (Set-ReportItem $sample 'BugChecks' @(@{ Time = '2026-10-20T10:00:00'; Code = '0x0000009f' }, @{ Time = '2026-10-21T10:00:00'; Code = '0x0000009f' }, @{ Time = '2026-10-22T10:00:00'; Code = '0x00000124' })) -Config $cfg
      $b = $f | Where-Object Code -eq 'bugchecks'
      $b.Level | Should -Be 'CRIT'; $b.Args[0] | Should -Be '3'; $b.Args[2] | Should -Be '0x0000009F x2, 0x00000124'; $b.Section | Should -Be '07'
    }
    It 'a disabled device (CM 22) and Ntfs 140 are never flagged; disk 7, 51, 153 and Ntfs 55 are' {
      $f = Get-ReportFlags -Report (Set-ReportItem $sample 'DiskEvents' @('Ntfs/140')) -Config $cfg; $f.Code | Should -Not -Contain 'diskEvents'
      foreach ($e in 'disk/7', 'disk/51', 'disk/153', 'Ntfs/55') { (Get-ReportFlags -Report (Set-ReportItem $sample 'DiskEvents' @($e)) -Config $cfg).Code | Should -Contain 'diskEvents' }
      # The collector counts only problem codes: a disabled device is no problem.
      $script:gc['devices'] = @{ Items = @(@{ InstanceId = 'USB\X'; Class = 'USB'; Name = 'Off'; Status = 'Error'; ConfigManagerErrorCode = 22 }) }
      $d = Get-ReportData06 -Run (New-ReportActionRun quickReport) -Quick $true
      $d.Items.DevicesProblem | Should -Be 0; $d.Items.DevicesDisabled | Should -Be 1
      (Get-ReportFlags -Report (Set-ReportItem (Set-ReportItem $sample 'DevicesProblem' 0) 'ProblemDevices' @()) -Config $cfg).Code | Should -Not -Contain 'devicesProblem'
    }
    It 'Guest and Administrators are found by SID on a Hebrew PC' {
      Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_UserAccount' } { [pscustomobject]@{ Name = 'אורח'; SID = 'S-1-5-21-1-2-3-501'; Disabled = $false; LocalAccount = $true } }
      $d = Get-ReportData11 -Run (New-ReportActionRun fullReport) -Quick $true; $d.Items.GuestEnabled | Should -BeTrue
      # The Administrators group by its SID, in a bounded grandchild (review M4).
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'admins' -and $Command -match [regex]::Escape("Get-LocalGroupMember -SID 'S-1-5-32-544'") }
      (Get-ReportFlags -Report (Set-ReportItem $sample 'GuestEnabled' $true) -Config $cfg).Code | Should -Contain 'guestEnabled'
      @($d.Items.Users) | Should -Contain 'אורח'
      @($d.Items.Admins)[0].Sid | Should -Be $script:sid
    }
    It 'the Administrators fall back to ADSI on the group''s translated name, in the same grandchild' {
      $script:gcCommands = @{}
      $script:gc['admins'] = @{ Source = 'ADSI'; Items = @(@{ Name = 'Dana'; Sid = $script:sid; Source = 'ADSI' }) }
      $d = Get-ReportData11 -Run (New-ReportActionRun quickReport) -Quick $true
      $script:gcCommands['admins'] | Should -Match ([regex]::Escape("Translate([Security.Principal.NTAccount])"))
      $script:gcCommands['admins'] | Should -Match ([regex]::Escape('WinNT://'))
      @($d.Items.Admins).Count | Should -Be 1; @($d.Missing).Count | Should -Be 0
      $d.Facts['Administrators'] | Should -Match 'ADSI'
    }
    It 'the Internet chip''s "Clock wrong" is a wrong clock, not "no internet" (RD-R20); a portal is captivePortal (RD-R13); the report says clockWrong (RD-R24)' {
      $clock = Set-ReportItem (Set-ReportItem $sample 'Internet' @{ Tcp = $true; Https = $false; Probe = 'ok'; Clock = $true }) 'ClockOffsetMinutes' 1051200
      $f = Get-ReportFlags -Report $clock -Config $cfg
      $f.Code | Should -Contain 'clockWrong'; $f.Code | Should -Not -Contain 'clockOff'; $f.Code | Should -Not -Contain 'noInternet'
      (Get-Flag $f 'clockWrong').Args[0] | Should -Be '1051200.0'; (Get-Flag $f 'clockWrong').Level | Should -Be 'WARN'; (Get-Flag $f 'clockWrong').Section | Should -Be '01'
      (Get-Flag $f 'clockWrong').Text | Should -Not -Match 'after the time sync'
      (Get-ReportFlags -Report (Set-ReportItem $sample 'Internet' @{ Tcp = $false; Https = $false; Probe = 'skipped'; Clock = $false }) -Config $cfg).Code | Should -Contain 'noInternet'
      (Get-ReportFlags -Report (Set-ReportItem $sample 'Internet' @{ Tcp = $true; Https = $false; Probe = 'failed'; Clock = $false }) -Config $cfg).Code | Should -Contain 'noInternet'
      $portal = Get-ReportFlags -Report (Set-ReportItem $sample 'Internet' @{ Tcp = $true; Https = $true; Probe = 'different'; Clock = $false }) -Config $cfg
      $portal.Code | Should -Contain 'captivePortal'; $portal.Code | Should -Not -Contain 'noInternet'; (Get-Flag $portal 'captivePortal').Section | Should -Be '09'
    }
    It 'reproduces the Health check''s codes from the sections (volume*, winre*, notActivated, devicesProblem, oemLeftover)' {
      $cases = @(
        @{ Item = 'VolumeState'; Value = 'SpotFixNeeded'; Code = 'volumeStateSpotFix'; Level = 'CRIT'; Section = '03' }
        @{ Item = 'VolumeState'; Value = 'FullRepairNeeded'; Code = 'volumeStateFullRepair'; Level = 'CRIT'; Section = '03' }
        @{ Item = 'VolumeState'; Value = 'ScanNeeded'; Code = 'volumeStateScan'; Level = 'WARN'; Section = '03' }
        @{ Item = 'Dirty'; Value = $true; Code = 'volumeDirty'; Level = 'WARN'; Section = '03' }
        @{ Item = 'WinRe'; Value = @{ Bcd = 'Off'; ReAgent = 'Off'; Verdict = 'Off'; Error = '' }; Code = 'winreOff'; Level = 'WARN'; Section = '04' }
        @{ Item = 'WinRe'; Value = @{ Bcd = 'On'; ReAgent = 'Off'; Verdict = 'Unknown'; Error = '' }; Code = 'winreUnknown'; Level = 'WARN'; Section = '04' }
        @{ Item = 'WinRe'; Value = @{ Bcd = 'Unknown'; ReAgent = 'On'; Verdict = 'Unknown'; Error = 'timed out' }; Code = 'winreUnreadable'; Level = 'WARN'; Section = '04' }
        @{ Item = 'Activation'; Value = 'Not activated'; Code = 'notActivated'; Level = 'WARN'; Section = '01' }
        @{ Item = 'OemLeftovers'; Value = @('HP Support Assistant'); Code = 'oemLeftover'; Level = 'WARN'; Section = '10' }
        @{ Item = 'TrimDisabled'; Value = '1'; Code = 'trimOff'; Level = 'WARN'; Section = '03' }
        @{ Item = 'PageFile'; Value = @{ Files = @('D:\pagefile.sys'); MissingDrives = @('D:'); Error = '' }; Code = 'pageFileMissingDrive'; Level = 'WARN'; Section = '03' }
        @{ Item = 'PageFile'; Value = @{ Files = @(); MissingDrives = @(); Error = 'timed out' }; Code = 'pageFileUnknown'; Level = 'WARN'; Section = '03' })
      foreach ($c in $cases) {
        $f = Get-Flag (Get-ReportFlags -Report (Set-ReportItem $sample $c.Item $c.Value) -Config $cfg) $c.Code
        $f | Should -Not -BeNullOrEmpty -Because $c.Code
        $f.Level | Should -Be $c.Level -Because $c.Code; $f.Section | Should -Be $c.Section -Because $c.Code
      }
      (Get-Codes (Get-ReportFlags -Report $sample -Config $cfg)) | Should -Contain 'devicesProblem'
      (Get-Flag (Get-ReportFlags -Report $sample -Config $cfg) 'winreUnreadable') | Should -BeNullOrEmpty
    }
    It 'every finding names its section; CRIT comes before WARN before INFO; a source that was not collected is INFO notCollected' {
      $f = @(Get-ReportFlags -Report (Set-ReportItem (Set-ReportItem $sample 'DiskEvents' @('disk/7')) 'UptimeDays' 30) -Config $cfg)
      foreach ($x in $f) { $x.Section | Should -Match '^(0[1-9]|1[0-2])$' -Because $x.Code; $x.Text | Should -Not -BeNullOrEmpty -Because $x.Code }
      $rank = @{ CRIT = 0; WARN = 1; INFO = 2 }
      for ($i = 1; $i -lt $f.Count; $i++) { $rank[$f[$i].Level] | Should -BeGreaterOrEqual $rank[$f[$i - 1].Level] }
      $n = Get-Flag $f 'notCollected'; $n.Level | Should -Be 'INFO'; $n.Section | Should -Be '05'; $n.Args | Should -Be @('Windows Update log', 'timed out')
      foreach ($x in $f) { foreach ($a in @($x.Args)) { $a | Should -Not -Match '[^\x20-\x7E]' } }
    }
  }

  Describe 'collectors' {
    It 'Quick skips every slow source and runs one connectivity test' {
      $r = New-ReportActionRun quickReport
      foreach ($n in '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11') { $null = & "Get-ReportData$n" -Run $r -Quick $true }
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -in 'drivers', 'printers', 'reliability', 'appx', 'features', 'wuLog' }
      Should -Invoke Test-ToolInternet -Times 1 -Exactly; Should -Invoke Test-ToolTcpHosts -Times 0 -Exactly; Should -Invoke Invoke-ToolNative -Times 0
      # Nor the monitors' serials, the volume state, or a copy of anything.
      Should -Invoke Get-CimInstance -Times 0 -ParameterFilter { $ClassName -eq 'WmiMonitorID' }
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'volumeState' }
      [IO.Directory]::Exists((Join-Path $r.SessionDir 'raw_2026-10-23_1405')) | Should -BeFalse
    }
    It 'a source that times out is "not collected", the section and the report still complete' {
      $script:gc['printers'] = @{ Ok = $false; TimedOut = $true; Error = 'timed out' }
      $d = Get-ReportData10 -Run (New-ReportActionRun fullReport) -Quick $false; $d.Missing.What | Should -Contain 'Printers'; $d.Facts.Count | Should -BeGreaterThan 0
      ($d.Missing | Where-Object What -eq 'Printers').Why | Should -Be 'timed out'
    }
    It 'every section completes when every source fails: each failure is a Missing entry with a fixed reason, never an exception' {
      $script:cimFail = $true
      foreach ($k in @($script:gc.Keys)) { $script:gcFail[$k] = 'timed out' }
      Mock Get-RebootRegistryValue { $null }
      Mock Read-ToolRegistryKey { throw 'registry unreadable' }
      Mock Read-ToolRegistrySubkeys { throw 'registry unreadable' }
      Mock Get-Service { Write-Error -Message 'Service control manager unavailable' -Category ResourceUnavailable }
      Mock Test-ToolInternet { throw 'no network stack' }
      Mock Test-ToolTcpHosts { throw 'no network stack' }
      Mock Confirm-SecureBootUEFI { throw (New-Object UnauthorizedAccessException('denied')) }
      Mock Get-SignedInUserName { throw 'CIM did not answer' }
      Mock Get-ToolBitLockerChip { @{ Level = 'unknown'; Args = @(); Detail = @{ Error = 'timed out' } } }
      Mock Get-ServicingRebootSignals { throw 'registry unreadable' }
      Mock Invoke-ToolNative { @{ ExitCode = $null; TimedOut = $true; OutputPath = $null } }
      $r = New-ReportActionRun fullReport
      foreach ($n in '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12') {
        $d = & "Get-ReportData$n" -Run $r -Quick $false
        $d.Id | Should -Be $n
        @($d.Missing).Count | Should -BeGreaterThan 0 -Because "section $n"
        foreach ($m in @($d.Missing)) { $m.What | Should -Not -BeNullOrEmpty; $m.Why | Should -Match $script:reasonPattern -Because ('{0}: {1}' -f $m.What, $m.Why) }
      }
    }
    It 'scheduled tasks and services are listed without their arguments' {
      ($core -join "`n") | Should -Not -Match '--token|/password'; ($core -join "`n") | Should -Match 'agent\.exe'
      # The collector itself: the grandchild's task row and the service's command line carry tokens; nothing keeps them.
      $d = Get-ReportData10 -Run (New-ReportActionRun quickReport) -Quick $true
      $all = (Get-AllText -Value @($d.Facts, $d.Groups, $d.Items)) -join "`n"
      $all | Should -Not -Match '--token|/password|Arguments'
      $all | Should -Match 'C:\\Agent\\agent\.exe'; $all | Should -Match 'agentsvc\.exe'
    }
    It 'the Full disk scan is skipped when the Disk chip is red' {
      $r = New-ReportActionRun fullReport; $r.Args.Strip.Disk = 'crit'; $null = Get-ReportData03 -Run $r -Quick $false
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'volumeScan' }
    }
    It 'Full reads the volume state read-only (Get-Volume, RD-R12) and never scans, red disk or not' {
      $script:gc['volumeState'] = @{ HealthStatus = 0; OperationalStatus = @(53262); Dirty = $true }
      $d = Get-ReportData03 -Run (New-ReportActionRun fullReport) -Quick $false
      $d.Items.VolumeState | Should -Be 'SpotFixNeeded'; $d.Items.Dirty | Should -BeTrue
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'volumeState' }
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'volumeScan' }
      (Get-Content -Raw $script:collectFile) | Should -Not -Match 'Repair-Volume'
    }
    It 'storage: the system disk is judged, every disk is listed with its serial, the system disk''s events are read in a grandchild' {
      $script:gc['diskEvents'] = @{ disk = @{ Error = ''; Total = 4; Groups = @(); Rows = @(
            @{ Provider = 'disk'; Id = 7; Level = 2; Time = '2026-10-20T10:00:00'; Data = @{}; Props = @('\Device\Harddisk0\DR0') }
            @{ Provider = 'Ntfs'; Id = 55; Level = 2; Time = '2026-10-20T10:01:00'; Data = @{}; Props = @('C:') }
            @{ Provider = 'disk'; Id = 51; Level = 3; Time = '2026-10-20T10:02:00'; Data = @{}; Props = @('\Device\Harddisk1\DR1') }
            @{ Provider = 'Ntfs'; Id = 55; Level = 2; Time = '2026-10-20T10:03:00'; Data = @{}; Props = @('E:') }) } }
      $d = Get-ReportData03 -Run (New-ReportActionRun quickReport) -Quick $true
      $d.Items.SystemDisk | Should -Be 'Samsung SSD 980 PRO 512GB'; $d.Items.Wear | Should -Be 7; $d.Items.Temperature | Should -Be 38; $d.Items.DiskErrors | Should -Be 0
      @($d.Items.Disks.Serial) | Should -Be @('S4EWNX0R123456', '4C530001')
      @($d.Items.DiskEvents) | Should -Be @('disk/7', 'Ntfs/55')
      $d.Facts['Disk events'] | Should -Match '^2 on the system disk, 2 elsewhere'
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'diskEvents' -and $StepTimeout -eq 'events' -and $Command -match '"Ids":\[7,51,153,55\]' }
      $d.Items.FreeGB | Should -Be 210.4; $d.Items.FreePercent | Should -Be 44
    }
    It 'Full runs the five-host test, the raw tools into raw_<stamp>\ and copies the newest crash dumps' {
      $r = New-ReportActionRun fullReport
      $dumps = $script:ToolReportPaths.Minidump
      for ($i = 1; $i -le 12; $i++) { $p = Join-Path $dumps ('1023{0:D2}-1-01.dmp' -f $i); [IO.File]::WriteAllText($p, 'dump'); [IO.File]::SetLastWriteTime($p, (Get-Date).AddDays(-$i)) }
      $d09 = Get-ReportData09 -Run $r -Quick $false
      Should -Invoke Test-ToolTcpHosts -Times 1 -Exactly -ParameterFilter { @($Hosts).Count -eq 5 -and $Seconds -eq 3 -and @($Hosts) -contains 'login.microsoftonline.com' }
      $d09.Items.Hosts['www.google.com'] | Should -BeTrue
      $d07 = Get-ReportData07 -Run $r -Quick $false
      $raw = Join-Path $r.SessionDir 'raw_2026-10-23_1405'
      @([IO.Directory]::GetFiles((Join-Path $raw 'Minidump'))).Count | Should -Be 10
      $d07.Items.Minidumps | Should -Be 12
      foreach ($n in '01', '03', '05', '06', '08', '11', '12') { $null = & "Get-ReportData$n" -Run $r -Quick $false }
      $lines = @($script:native)
      foreach ($tool in 'systeminfo.exe', 'vssadmin.exe list shadows', 'vssadmin.exe list shadowstorage', 'wevtutil.exe epl System', 'wevtutil.exe epl Application',
                        'powercfg.exe /batteryreport', 'powercfg.exe /sleepstudy', 'powercfg.exe /energy /duration 30', 'gpresult.exe /h', 'dsregcmd.exe /status',
                        'msinfo32.exe /nfo', 'msinfo32.exe /report') {
        @($lines | Where-Object { $_.StartsWith($tool) }).Count | Should -BeGreaterThan 0 -Because $tool
      }
      foreach ($l in $lines) { if ($l -match '"([A-Za-z]:\\[^"]+)"') { $Matches[1] | Should -BeLike "$raw\*" -Because $l } }
      Should -Invoke Invoke-ToolNative -ParameterFilter { $FilePath -like '*msinfo32.exe' -and $StepTimeout -eq 'msinfo32' }
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'wuLog' -and $Command -like "*$raw*" -and $StepTimeout -eq 'wuLog' }
    }
    It 'section 12 is Full only: Quick runs nothing for it' {
      $d = Get-ReportData12 -Run (New-ReportActionRun quickReport) -Quick $true
      Should -Invoke Invoke-ToolNative -Times 0; @($d.Missing).Count | Should -Be 0; $d.Facts.Count | Should -Be 0
    }
    It 'display names keep their real text (Hebrew programs and event messages, RD-R21)' {
      $r = New-ReportActionRun quickReport
      $d10 = Get-ReportData10 -Run $r -Quick $true
      @($d10.Items.Programs.Name) | Should -Contain ($script:hebProgram + ' 2026')
      ($d10.Groups -join "`n") | Should -Match ([regex]::Escape($script:hebProgram))
      @($d10.Items.Programs.Name) | Should -Not -Contain 'A system component'; @($d10.Items.Programs.Name) | Should -Not -Contain 'An update of Chrome'
      $d07 = Get-ReportData07 -Run $r -Quick $true
      ($d07.Groups -join "`n") | Should -Match ([regex]::Escape($script:hebStopped))
    }
    It 'software: installs of the last 30 days, the other maker''s utility, Office''s channel and OneDrive''s account' {
      $d = Get-ReportData10 -Run (New-ReportActionRun quickReport) -Quick $true
      @($d.Items.RecentInstalls) | Should -Be @('Google Chrome')
      @($d.Items.OemLeftovers) | Should -Be @('HP Support Assistant')
      $d.Facts['Office'] | Should -Match 'Current'
      @($d.Items.OneDriveEmails) | Should -Be @('dana.cohen@example.co.il')
      $d.Items.SignedInUser | Should -Be 'DELL-7HX2K93\Dana'
      @($d.Items.AutoStopped).Count | Should -Be 0
    }
    It 'the events of section 07 come from two bounded grandchildren: counts, power losses, blue screens, WHEA, crashes' {
      $script:gc['crashEvents']['whea'] = @{ Error = ''; Total = 2; Groups = @(); Rows = @(
          @{ Provider = 'Microsoft-Windows-WHEA-Logger'; Id = 19; Level = 3; Time = '2026-10-20T10:00:00'; Data = @{}; Props = @() }
          @{ Provider = 'Microsoft-Windows-WHEA-Logger'; Id = 18; Level = 1; Time = '2026-10-21T10:00:00'; Data = @{}; Props = @() }) }
      $script:gc['crashEvents']['bugcheck'] = @{ Error = ''; Total = 1; Groups = @(); Rows = @(
          @{ Provider = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; Level = 2; Time = '2026-10-21T11:44:00'; Data = @{}; Props = @('0x0000009f (0x0000000000000003, 0x)') }) }
      $d = Get-ReportData07 -Run (New-ReportActionRun quickReport) -Quick $true
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'eventGroups' -and $StepTimeout -eq 'events' }
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'crashEvents' -and $StepTimeout -eq 'events' }
      $d.Items.KernelPower41 | Should -Be 1; @($d.Items.KernelPower41Events)[0].BugcheckCode | Should -Be 0
      @($d.Items.BugChecks)[0].Code | Should -Be '0x0000009F'
      @($d.Items.Whea).Count | Should -Be 2; $d.Items.AppCrashes | Should -Be 2; $d.Items.AppCrashTop | Should -Be 'chrome.exe'
      $f = Get-ReportFlags -Report @{ Sections = @{ '07' = $d }; Items = $d.Items } -Config $cfg
      (Get-Codes $f) | Should -Contain 'bugchecks'; (Get-Codes $f) | Should -Contain 'wheaFatal'; (Get-Codes $f) | Should -Contain 'wheaCorrected'
      # Quick looks back quickEventDays (7) for the error groups, Full eventDays (14); the crash rows always crashDays (60).
      $script:gcCommands['eventGroups'] | Should -Match '"Days":7'; $script:gcCommands['crashEvents'] | Should -Match '"Days":60'
    }
    It 'network: the hosts file''s active entries, a user proxy, SMBv1 and a firewall profile that is off are read' {
      [IO.File]::WriteAllText($script:ToolReportPaths.Hosts, "# hosts`r`n127.0.0.1 localhost # kept`r`n`r`n10.0.0.9 login.microsoftonline.com`r`n", [Text.Encoding]::ASCII)
      $script:reg[('Registry::HKEY_USERS\' + $script:sid + '\Software\Microsoft\Windows\CurrentVersion\Internet Settings|ProxyEnable')] = 1
      $script:reg[('Registry::HKEY_USERS\' + $script:sid + '\Software\Microsoft\Windows\CurrentVersion\Internet Settings|ProxyServer')] = 'proxy.local:8080'
      $script:reg['HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10|Start'] = 2
      $script:gc['netState']['Firewall'] = @(@{ Name = 'Domain'; Enabled = 'True' }, @{ Name = 'Private'; Enabled = 'False' }, @{ Name = 'Public'; Enabled = 'False' })
      $d = Get-ReportData09 -Run (New-ReportActionRun quickReport) -Quick $true
      $d.Items.HostsEntries | Should -Be 2; $d.Items.UserProxy | Should -Be 'proxy.local:8080'; $d.Items.Smb1 | Should -BeTrue
      @($d.Items.FirewallOff) | Should -Be @('Private', 'Public'); @($d.Items.Ssids) | Should -Be @('Cohen_Home_5G')
      $f = Get-Codes (Get-ReportFlags -Report @{ Sections = @{ '09' = $d }; Items = $d.Items } -Config $cfg)
      foreach ($c in 'hostsEntries', 'userProxy', 'smb1On', 'firewallOff') { $f | Should -Contain $c }
    }
  }

  Describe 'review fixes (RD-R24)' {
    It 'I1: Get-ToolCommandExecutable never returns a command''s arguments' -ForEach @(
      @{ Line = '"C:\Agent\agent.exe" --token abc'; Program = 'C:\Agent\agent.exe' }
      @{ Line = 'C:\Program Files\Agent\agent.exe --token abc'; Program = 'C:\Program Files\Agent\agent.exe' }
      @{ Line = 'C:\WINDOWS\system32\svchost.exe -k netsvcs -p'; Program = 'C:\WINDOWS\system32\svchost.exe' }
      @{ Line = '%windir%\system32\SecurityHealthSystray.exe'; Program = '%windir%\system32\SecurityHealthSystray.exe' }
      @{ Line = '\\server\share\tool.exe /silent C:\x.exe'; Program = '\\server\share\tool.exe' }
      @{ Line = 'C:\Tools\app.exe C:\Users\Dana\secret.js'; Program = 'C:\Tools\app.exe' }
      @{ Line = 'rundll32.exe C:\x.dll,Run secret'; Program = 'rundll32.exe' }
      @{ Line = 'powershell.exe -Command "Invoke-Thing -Token abc"'; Program = 'powershell.exe' }
      @{ Line = 'node --token=abc C:\app\server.js'; Program = 'node' }
      @{ Line = 'cmd /c set TOKEN=abc && C:\tools\run.bat'; Program = 'cmd' }
      @{ Line = 'C:\Tools\x /flag C:\tools\run.bat'; Program = 'C:\Tools\x' }
      @{ Line = ''; Program = '' }) {
      Get-ToolCommandExecutable -Command $Line | Should -BeExactly $Program
    }
    It 'M1: section 07 lists its crash, WHEA, hang, dump and reliability lines before the event groups, so the size limit cuts event groups first (800 groups)' {
      $script:gc['eventGroups'] = @{ system = @{ Error = ''; Total = 4000; Rows = @(); Groups = (New-ManyGroups -Log 'System' -Count 400) }
                                     application = @{ Error = ''; Total = 4000; Rows = @(); Groups = (New-ManyGroups -Log 'Application' -Count 400) } }
      $script:gc['crashEvents']['bugcheck'] = @{ Error = ''; Total = 1; Groups = @(); Rows = @(
          @{ Provider = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; Level = 2; Time = '2026-10-21T11:44:00'; Data = @{}; Props = @('0x0000009f (0x3)') }) }
      $d = Get-ReportData07 -Run (New-ReportActionRun quickReport) -Quick $true
      $lines = @($d.Groups)
      $blue = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($x) $x.StartsWith('Blue screen') })
      $crash = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($x) $x.StartsWith('Application crash') })
      $firstGroup = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($x) $x -match '^\d+x ' })
      $blue | Should -BeGreaterOrEqual 0; $crash | Should -BeGreaterOrEqual 0
      $blue | Should -BeLessThan $firstGroup; $crash | Should -BeLessThan $firstGroup
      $report = Copy-ReportValue -Value $sample
      $report['Sections']['07'] = Copy-ReportValue -Value $d
      $limited = (Limit-ReportCore -Lines (Format-ReportCore -Report $report -Kind full) -Sections $report.Sections -MaxBytes 60000) -join "`n"
      $limited | Should -Match 'Blue screen 21/10/2026 11:44: 0x0000009F'
      $limited | Should -Match 'Application crash: chrome\.exe / chrome_elf\.dll x1'
      $limited | Should -Match 'lines cut to fit'
      $limited | Should -Not -Match ([regex]::Escape($lines[$lines.Count - 1]))
    }
    It 'M1: section 05 lists the CBS.log and dism.log error lines before the Windows Update event groups' {
      [IO.File]::WriteAllText($script:ToolReportPaths.CbsLog, "2026-10-21 08:00:01, Error                 CBS    Failed to resolve package [HRESULT = 0x80070490 - ERROR_NOT_FOUND]`r`n", [Text.Encoding]::ASCII)
      $d = Get-ReportData05 -Run (New-ReportActionRun fullReport) -Quick $false
      $lines = @($d.Groups)
      $cbs = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($x) $x.StartsWith('CBS.log: ') })
      $group = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($x) $x -match '^\d+x Microsoft-Windows-WindowsUpdateClient/' })
      $cbs | Should -BeGreaterOrEqual 0; $group | Should -BeGreaterThan $cbs
    }
    It 'M3: the domain and the signed-in user''s SID are Items, and the personal-values list names every identifiable Item' {
      $script:cim['Win32_ComputerSystem'] = @([pscustomobject]@{ Name = 'DELL-7HX2K93'; Manufacturer = 'Dell Inc.'; Model = 'Latitude 5440'; PartOfDomain = $true; Domain = 'cohenlaw.local'
                                                               Workgroup = $null; UserName = 'COHENLAW\dana' })
      $r = New-ReportActionRun quickReport
      (Get-ReportData01 -Run $r -Quick $true).Items.Domain | Should -Be 'cohenlaw.local'
      (Get-ReportData10 -Run $r -Quick $true).Items.SignedInSid | Should -Be $script:sid
      (Get-ReportData11 -Run $r -Quick $true).Items.SignedInSid | Should -Be $script:sid
      @($sample.Items.Keys) | Should -Not -Contain 'Domain'   # a workgroup PC has no domain Item
      $header = (Get-Content -Raw $script:reportFile).Substring(0, 4000)
      foreach ($name in 'ComputerName', 'Serial', 'BiosUuid', 'Domain', 'BoardSerial', 'RamSerials', 'MonitorSerials', 'BatterySerials', 'Disks[].Serial', 'Adapters[]',
                        'CurrentAddresses', 'Gateways', 'DnsServers', 'Ssids', 'NetworkProfiles[].Name', 'UserProxy', 'SignedInUser', 'SignedInSid', 'OneDriveEmails',
                        'Programs', 'Tasks[]', 'Startup[].Program', 'Services[].Program', 'ProblemDevices[]', 'Users', 'Admins[].Name', 'Admins[].Sid', 'Profiles') {
        $header | Should -Match ([regex]::Escape($name)) -Because $name
      }
    }
    It 'M4: the Administrators and the disk events are read in bounded grandchildren; a stall there loses that source, never the report' {
      $script:gcFail['admins'] = 'timed out'; $script:gcFail['diskEvents'] = 'timed out'
      $r = New-ReportActionRun quickReport
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      Test-Path $r.Files.Report | Should -BeTrue
      ($r.Data.Report['11'].Missing | Where-Object What -eq 'Administrators').Why | Should -Be 'timed out'
      ($r.Data.Report['03'].Missing | Where-Object What -eq 'Disk events').Why | Should -Be 'timed out'
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'admins' -and $StepTimeout -eq 'grandchild' }
      # Get-LocalGroupMember, Get-WinEvent and Get-ToolDiskEventCount are safety nets here: AfterEach proves none ran in this process.
    }
    It 'M5: the zip is written under a temporary name and renamed when it is complete' {
      $r = New-ReportSampleRun -Sample $sample
      $null = Invoke-ToolStepReportWrite -Run $r
      Invoke-ToolStepReportZip -Run $r | Should -Be 'done'
      $zip = Join-Path $r.SessionDir 'REPORT_DELL-7HX2K93_2026-10-23_1405_raw.zip'
      $r.Files.Zip | Should -Be $zip
      @(Get-ChildItem $r.SessionDir -Filter '*.partial').Count | Should -Be 0
      Should -Invoke Invoke-ToolJsonChild -Times 1 -Exactly -ParameterFilter { $Name -eq 'zip' -and $StepTimeout -eq 'zip' -and $Command -match '\.zip\.partial' }
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $archive = [IO.Compression.ZipFile]::OpenRead($zip)
      try { @($archive.Entries.FullName) | Should -Contain 'report-full.txt' } finally { $archive.Dispose() }
    }
    It 'M5: a zip that times out leaves no file that looks complete' {
      $r = New-ReportSampleRun -Sample $sample
      $null = Invoke-ToolStepReportWrite -Run $r
      $partial = Join-Path $r.SessionDir 'REPORT_DELL-7HX2K93_2026-10-23_1405_raw.zip.partial'
      [IO.File]::WriteAllText($partial, 'half a zip')
      $script:gcFail['zip'] = 'timed out'
      Invoke-ToolStepReportZip -Run $r | Should -Be 'timedout'
      @(Get-ChildItem $r.SessionDir -Filter '*_raw.zip').Count | Should -Be 0
      Test-Path $partial | Should -BeFalse
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'reportZipFailed'
    }
    It 'M5: with too little time left the zip is not started' {
      $r = New-ReportSampleRun -Sample $sample
      $null = Invoke-ToolStepReportWrite -Run $r
      Mock Get-ToolRemainingSeconds { 120 }
      Invoke-ToolStepReportZip -Run $r | Should -Be 'skipped'
      Should -Invoke Invoke-ToolJsonChild -Times 0 -ParameterFilter { $Name -eq 'zip' }
      ($r.Findings | Where-Object Code -eq 'reportZipFailed').Args[0] | Should -Be 'not enough time left'
    }
    It 'M6: a count that reached the query''s limit reads as a lower bound (5000+), in the facts and in the findings' {
      $script:gc['eventGroups']['system']['Total'] = 5000
      $script:gc['crashEvents']['appError'] = @{ Error = ''; Total = 1000; Groups = @(); Rows = @(
          @{ Provider = 'Application Error'; Id = 1000; Level = 2; Time = '2026-10-19T16:40:00'; Data = @{}; Props = @('chrome.exe', 'chrome_elf.dll', '0xc0000005') }) }
      $d = Get-ReportData07 -Run (New-ReportActionRun fullReport) -Quick $false
      $d.Facts['System errors and warnings'] | Should -BeExactly '5000+ in 14 days (the newest 5000 read)'
      $d.Facts['Application errors and warnings'] | Should -BeExactly '2 in 14 days'
      $d.Facts['Application crashes'] | Should -Match '^1000\+ in 60 days'
      @($d.Items.CappedCounts) | Should -Contain 'AppCrashes'
      $f = Get-ReportFlags -Report @{ Sections = @{ '07' = $d }; Items = $d.Items } -Config $cfg
      (Get-Flag $f 'appCrashes').Args[0] | Should -Be '1000+'
    }
    It 'M11: a "not collected" reason is a fixed English code, never Windows'' own (Hebrew) text' {
      $script:gc['printers'] = @{ Ok = $false; TimedOut = $false; Data = $null; Error = 'הגישה נדחתה' }
      $script:gc['tasks'] = @{ Ok = $false; TimedOut = $false; Data = $null; Error = 'output too large' }
      $d = Get-ReportData10 -Run (New-ReportActionRun fullReport) -Quick $false
      ($d.Missing | Where-Object What -eq 'Printers').Why | Should -Be 'failed'
      ($d.Missing | Where-Object What -eq 'Scheduled tasks').Why | Should -Be 'output too large'
      foreach ($m in @($d.Missing)) { $m.Why | Should -Match $script:reasonPattern }
    }
    It 'M11: ConvertTo-ReportText is gone; ConvertTo-ToolDisplayText also drops the direction marks Hebrew Windows adds' {
      Get-Command -Name ConvertTo-ReportText -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
      (Get-Content -Raw $script:reportFile) + (Get-Content -Raw $script:collectFile) | Should -Not -Match 'ConvertTo-ReportText'
      $marked = ([string][char]0x200E) + 'Microsoft Windows 11' + ([string][char]0x200F) + ' ' + $script:hebProgram
      ConvertTo-ToolDisplayText -Text $marked -MaxLength 100 | Should -BeExactly ('Microsoft Windows 11 ' + $script:hebProgram)
    }
  }

  Describe 'ConvertTo-EventGroups (pure)' {
    It 'groups by provider, ID and level: count, first and last dd/MM/yyyy HH:mm, the newest message, newest group first' {
      $events = @(
        @{ Provider = 'disk'; Id = 7; Level = 2; Time = '2026-10-20T08:00:00'; Message = 'old' }
        @{ Provider = 'disk'; Id = 7; Level = 2; Time = '2026-10-22T09:30:00'; Message = "newest  `r`n  text" }
        @{ Provider = 'disk'; Id = 7; Level = 3; Time = '2026-10-21T10:00:00'; Message = 'a warning' }
        @{ Provider = 'Service Control Manager'; Id = 7031; Level = 2; Count = 3; First = '2026-10-19T07:00:00'; Last = '2026-10-23T12:00:00'; Message = $script:hebStopped })
      $g = @(ConvertTo-EventGroups -Events $events)
      $g.Count | Should -Be 3
      $g[0] | Should -BeExactly ('3x Service Control Manager/7031 [2] 19/10/2026 07:00 - 23/10/2026 12:00  ' + $script:hebStopped)
      $g[1] | Should -BeExactly '2x disk/7 [2] 20/10/2026 08:00 - 22/10/2026 09:30  newest text'
      $g[2] | Should -BeExactly '1x disk/7 [3] 21/10/2026 10:00 - 21/10/2026 10:00  a warning'
    }
    It 'cuts the message to 200 characters (cut between words with " ...": RD-R26; a word longer than the room is dropped: RD-R27), reads event records too, and ignores a Hebrew calendar on the thread' {
      $culture = [Threading.Thread]::CurrentThread.CurrentCulture
      try {
        $he = New-Object Globalization.CultureInfo 'he-IL'; $he.DateTimeFormat.Calendar = New-Object Globalization.HebrewCalendar
        [Threading.Thread]::CurrentThread.CurrentCulture = $he
        $g = @(ConvertTo-EventGroups -Events @([pscustomobject]@{ ProviderName = 'x'; Id = 1; Level = 2; TimeCreated = [datetime]::new(2026, 10, 22, 9, 5, 0); Message = ('m' * 500) }))
      } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
      $g[0] | Should -BeExactly '1x x/1 [2] 22/10/2026 09:05 - 22/10/2026 09:05  ...'
      @(ConvertTo-EventGroups -Events @()).Count | Should -Be 0
    }
  }

  Describe 'Test-ToolTcpHosts' {
    It 'starts every connection together and answers host -> bool, a hung one false within the bound' {
      $script:started = New-Object System.Collections.ArrayList
      $connect = {
        param($HostName)
        [void]$script:started.Add($HostName)
        switch ($HostName) {
          'ok.example' { @{ Client = $null; Task = [Threading.Tasks.Task]::FromResult($true) } }
          'hung.example' { @{ Client = $null; Task = (New-Object 'Threading.Tasks.TaskCompletionSource[bool]').Task } }
          default { throw 'no such host' }
        }
      }
      $clock = [Diagnostics.Stopwatch]::StartNew()
      # The real function (the fake PC makes Test-ToolTcpHosts a recorder for the collectors).
      $answer = & $script:realTcpHosts -Hosts @('ok.example', 'hung.example', 'bad.example') -Seconds 1 -Connect $connect
      $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
      $answer['ok.example'] | Should -BeTrue; $answer['hung.example'] | Should -BeFalse; $answer['bad.example'] | Should -BeFalse
      @($script:started) | Should -Be @('ok.example', 'hung.example', 'bad.example')
    }
  }

  Describe 'Read-ToolLogErrors' {
    It 'keeps only the English error lines, grouped and counted without their time stamps, newest last, at most -MaxLines' {
      $p = Join-Path $TestDrive 'cbs-errors.log'
      $lines = @(
        '2026-10-20 08:00:00, Info                  CBS    Starting TrustedInstaller initialization.'
        '2026-10-20 08:00:01, Error                 CBS    Failed to resolve package [HRESULT = 0x80070490 - ERROR_NOT_FOUND]'
        '2026-10-21 08:00:01, Error                 CBS    Failed to resolve package [HRESULT = 0x80070490 - ERROR_NOT_FOUND]'
        '2026-10-21 09:00:00, Info                  CSI    00000012 [SR] Cannot repair member file [l:10]"amd64_x.dll"'
        '2026-10-21 09:10:00, Info                  DISM   PID=1 TID=2 Exit code [HRESULT = 0x800f081f]')
      [IO.File]::WriteAllText($p, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding $false))
      $e = @(Read-ToolLogErrors -Path $p -MaxLines 10)
      $e.Count | Should -Be 3
      $e[0] | Should -Match '^2x .*Failed to resolve package'
      ($e -join "`n") | Should -Match '\[SR\] Cannot repair member file'; ($e -join "`n") | Should -Match '0x800f081f'
      ($e -join "`n") | Should -Not -Match 'Starting TrustedInstaller'
      @(Read-ToolLogErrors -Path $p -MaxLines 1).Count | Should -Be 1
      @(Read-ToolLogErrors -Path (Join-Path $TestDrive 'none.log') -MaxLines 10).Count | Should -Be 0
      @(Read-ToolLogErrors -Path $p -MaxLines 10 -Patterns @('!!!')).Count | Should -Be 0
    }
  }

  Describe 'the AI-ready core (spec 6.8)' {
    It 'holds the complaint, this visit, section 00 and the sections in order; dates are dd/MM/yyyy HH:mm under a Hebrew calendar' {
      $culture = [Threading.Thread]::CurrentThread.CurrentCulture
      try {
        $he = New-Object Globalization.CultureInfo 'he-IL'; $he.DateTimeFormat.Calendar = New-Object Globalization.HebrewCalendar
        [Threading.Thread]::CurrentThread.CurrentCulture = $he
        $l = Format-ReportCore -Report $sample -Kind full; $t = $l -join "`n"
      } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
      $t.IndexOf('CUSTOMER COMPLAINT') | Should -BeLessThan $t.IndexOf('THIS VISIT'); $t.IndexOf('THIS VISIT') | Should -BeLessThan $t.IndexOf('== 00 SUMMARY ==')
      $t.IndexOf('== 01 SYSTEM ==') | Should -BeLessThan $t.IndexOf('== 12 MSINFO32 =='); $l[0] | Should -Match '\d\d/\d\d/20\d\d \d\d:\d\d'
      $l[0] | Should -Match '23/10/2026 14:05'; $l[0] | Should -Match 'FULL REPORT'; $l[0] | Should -Match '7HX2K93'
      $t | Should -Match '23/10/2026 13:58  Health check: Done, YELLOW'
      $t.IndexOf('HOW TO USE') | Should -BeGreaterThan $t.IndexOf('== 12 MSINFO32 ==')
      foreach ($f in $sample.Findings) { $t | Should -Match ([regex]::Escape(('[{0}] {1} (section {2})' -f $f.Level, $f.Text, $f.Section))) }
    }
    It 'says (none) when there is no complaint and nothing else ran this visit; Quick has no section 12' {
      $quiet = Set-ReportItem $sample 'RamGB' 16
      $quiet['Complaint'] = ''; $quiet['Done'] = @(); $quiet['Sections'].Remove('12'); $quiet['Findings'] = @()
      $t = (Format-ReportCore -Report $quiet -Kind quick) -join "`n"
      $t | Should -Match 'CUSTOMER COMPLAINT\n  \(none\)'; $t | Should -Match 'THIS VISIT\n  \(nothing else yet\)'
      $t | Should -Match 'QUICK REPORT'; $t | Should -Not -Match '== 12 '; $t | Should -Match '\(no findings\)'
    }
    It 'stays under 150 KB with 10 000 event groups, keeping the summary and every finding' {
      $l = Limit-ReportCore -Lines (Format-ReportCore -Report $huge -Kind full) -Sections $huge.Sections -MaxBytes 153600
      [Text.Encoding]::UTF8.GetByteCount(($l -join "`r`n")) | Should -BeLessThan 153600; ($l -join "`n") | Should -Match '== 00 SUMMARY =='
      $t = $l -join "`n"
      foreach ($f in $huge.Findings) { $t | Should -Match ([regex]::Escape(('[{0}] {1}' -f $f.Level, $f.Text))) }
      foreach ($k in @($huge.Sections['01'].Facts.Keys)) { $t | Should -Match ([regex]::Escape(('  {0} = ' -f $k))) }
      # The largest section is cut first, from its oldest end, and says where the full text is.
      $t | Should -Match '    \([0-9]+ lines cut to fit; full text in raw\\report-full\.txt\)'
      $t | Should -Match ([regex]::Escape($huge.Sections['07'].Groups[0]))
      $t | Should -Not -Match ([regex]::Escape($huge.Sections['07'].Groups[9999]))
      # A core that already fits is not touched.
      $small = Format-ReportCore -Report $sample -Kind full
      @(Limit-ReportCore -Lines $small -Sections $sample.Sections -MaxBytes 153600) | Should -Be $small
    }
    It 'keeps Hebrew event messages as UTF-8 with a BOM; headings and flags stay ASCII' {
      $r = New-ReportSampleRun -Sample $sample
      $null = Invoke-ToolStepReportWrite -Run $r; $b = [IO.File]::ReadAllBytes($r.Files.Report); $b[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
      $t = [IO.File]::ReadAllText($r.Files.Report); $t | Should -Match 'השירות'; @($t -split "`r`n" | Where-Object { $_ -match '^(==|\s*\[(CRIT|WARN|INFO)\])' -and $_ -match '[^\x00-\x7F]' }).Count | Should -Be 0
      $t | Should -Match 'המחשב איטי'
      (Split-Path $r.Files.Report -Leaf) | Should -BeExactly 'REPORT_DELL-7HX2K93_2026-10-23_1405.txt'
    }
    It 'writes the data JSON, raw\ and (Full) the zip; a second report in the same minute gets _2' {
      $r = New-ReportSampleRun -Sample $sample
      $null = Invoke-ToolStepReportWrite -Run $r; $null = Invoke-ToolStepReportZip -Run $r
      Test-Path $r.Files.Data | Should -BeTrue; (Get-ChildItem $r.SessionDir -Filter '*_raw.zip').Count | Should -Be 1
      (Split-Path $r.Files.Data -Leaf) | Should -BeExactly 'REPORT_DELL-7HX2K93_2026-10-23_1405_data.json'
      Test-Path (Join-Path $r.SessionDir 'raw_2026-10-23_1405\report-full.txt') | Should -BeTrue
      $r2 = New-ReportSampleRun -Sample $sample -SameMinute $r; $null = Invoke-ToolStepReportWrite -Run $r2; $r2.Files.Report | Should -Match '_2\.txt$'
      $r2.Files.Data | Should -Match '_2_data\.json$'
    }
    It 'the data JSON has the shape Compare reads: identity, facts, findings, disks by serial, free space, devices, programs, crashes' {
      $r = New-ReportSampleRun -Sample $sample
      $null = Invoke-ToolStepReportWrite -Run $r
      $d = Read-ToolJsonFile -Path $r.Files.Data -MaxBytes $script:ToolReportDataMaxBytes
      $d.Version | Should -Be 1; $d.Kind | Should -Be 'full'; $d.CreatedAt | Should -Be '2026-10-23T14:05:30'
      $d.Identity.Key | Should -Be 'SN-7HX2K93'
      $d.Disks['S4EWNX0R123456'].Wear | Should -Be 7; $d.Disks['S4EWNX0R123456'].ReadErrors | Should -Be 0
      $d.FreeGB | Should -Be 210.4
      @($d.ProblemDevices)[0].Id | Should -Be 'PCI\VEN_8086&DEV_51F1\3&11583659&0&A3'
      @($d.Programs) | Should -Contain ('חשבשבת 2026|1.2.3')
      @($d.Crashes.KernelPower) | Should -Be @('2026-10-21T11:42:10')
      @($d.Findings.Code) | Should -Contain 'devicesProblem'; (@($d.Findings) | Where-Object Code -eq 'devicesProblem').Section | Should -Be '06'
      $d.Facts['Windows'] | Should -Be 'Windows 11 Pro 24H2'
    }
    It 'the report''s findings go into the run (the window shows them); result.json holds no report data and stays small (RD-R21)' {
      $r = New-ReportSampleRun -Sample $sample
      $r.Data['Report']['07']['Groups'] = $huge.Sections['07'].Groups
      $null = Invoke-ToolStepReportWrite -Run $r
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'devicesProblem'
      Write-ToolResult -Run $r -Outcome Done | Should -BeTrue
      (Get-Item $r.ResultPath).Length | Should -BeLessThan 64KB
      $res = Read-ToolJsonFile -Path $r.ResultPath
      $res.Data.ContainsKey('Report') | Should -BeFalse
      $res.Files.Report | Should -Be $r.Files.Report; $res.Files.Data | Should -Be $r.Files.Data
      [IO.File]::ReadAllText($r.ResultPath) | Should -Not -Match '[^\x00-\x7F]'
    }
    It 'a report file that cannot be written is the CRIT reportWriteFailed, never a silent success' {
      $r = New-ReportSampleRun -Sample $sample
      Mock Test-StickReparsePoint { $Path -like '*REPORT_*' }
      Invoke-ToolStepReportWrite -Run $r | Should -Be 'failed'
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'reportWriteFailed'
    }
  }

  Describe 'RD-R23: the files Ben reads on the stick are plain UTF-8' {
    It 'Write-ToolJsonFile -Utf8 keeps Hebrew as UTF-8 (2 bytes a letter, no \u escapes); Read-ToolJsonFile reads it back with a larger cap' {
      $name = $script:hebProgram
      $rows = @(for ($i = 0; $i -lt 20000; $i++) { '{0} {1}|1.0.{1}' -f $name, $i })
      $p = Join-Path $TestDrive 'hebrew-data.json'
      Write-ToolJsonFile -Path $p -InputObject @{ Programs = $rows; Name = $name } -Depth 4 -Utf8 | Should -BeTrue
      $bytes = [IO.File]::ReadAllBytes($p)
      $text = (New-Object Text.UTF8Encoding $false, $true).GetString($bytes)
      $text | Should -Not -Match '\\u05'; $text | Should -Match ([regex]::Escape($name))
      $bytes.Length | Should -BeGreaterThan 1MB; $bytes.Length | Should -BeLessThan 2MB
      Read-ToolJsonFile -Path $p | Should -BeNullOrEmpty
      $back = Read-ToolJsonFile -Path $p -MaxBytes $script:ToolReportDataMaxBytes
      $back.Name | Should -BeExactly $name; @($back.Programs).Count | Should -Be 20000; @($back.Programs)[19999] | Should -BeExactly $rows[19999]
      $script:ToolReportDataMaxBytes | Should -Be 16MB
      # The exchange files stay ASCII bytes with \u escapes (RD-R21).
      $q = Join-Path $TestDrive 'exchange.json'
      Write-ToolJsonFile -Path $q -InputObject @{ Name = $name } | Should -BeTrue
      [IO.File]::ReadAllText($q) | Should -Match '\\u05d7'; (Read-ToolJsonFile -Path $q).Name | Should -BeExactly $name
    }
    It 'the report''s data JSON on the stick is plain UTF-8' {
      $r = New-ReportSampleRun -Sample $sample
      $null = Invoke-ToolStepReportWrite -Run $r
      $t = [IO.File]::ReadAllText($r.Files.Data, [Text.Encoding]::UTF8)
      $t | Should -Match 'חשבשבת 2026'; $t | Should -Not -Match '\\u0'
      $t | Should -Match ([regex]::Escape('VEN_8086&DEV_51F1'))
    }
    It 'the UTF-8 mode also shows the ampersand, apostrophe and angle brackets as they are (5.1 escapes them); an escape kept as text in a value survives' {
      $p = Join-Path $TestDrive 'marks.json'
      $value = 'a&b ''q'' <x> \u0026 \\u0027 end'
      Write-ToolJsonFile -Path $p -InputObject @{ V = $value } -Utf8 | Should -BeTrue
      $text = [IO.File]::ReadAllText($p)
      $text | Should -Match ([regex]::Escape("a&b 'q' <x>"))
      (Read-ToolJsonFile -Path $p -MaxBytes $script:ToolReportDataMaxBytes).V | Should -BeExactly $value
      ConvertFrom-ToolJsonHtmlEscapes -Json '{"a":"\\u0026","b":"\u0026","c":"\\\u003c"}' | Should -BeExactly '{"a":"\\u0026","b":"&","c":"\\<"}'
    }
  }

  Describe 'a Quick report end to end on the fake PC' {
    It 'runs every section, writes the core and the data, and the result names them' {
      $r = New-ReportActionRun quickReport
      $outcome = Invoke-ToolSteps -Run $r
      $outcome | Should -Be 'Done'
      @(foreach ($s in $r.Steps) { $s.Status }) | Should -Not -Contain 'failed'
      Test-Path $r.Files.Report | Should -BeTrue; Test-Path $r.Files.Data | Should -BeTrue
      $t = [IO.File]::ReadAllText($r.Files.Report)
      foreach ($n in '01 SYSTEM', '02 HARDWARE', '03 STORAGE', '04 BOOT AND RECOVERY', '05 WINDOWS UPDATE', '06 DRIVERS AND DEVICES', '07 EVENTS AND CRASHES',
                     '08 PERFORMANCE AND POWER', '09 NETWORK', '10 SOFTWARE', '11 SECURITY') { $t | Should -Match ([regex]::Escape("== $n ==")) }
      $t | Should -Not -Match '== 12 '
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'devicesProblem'
      @(foreach ($f in $r.Findings) { $f.Code }) | Should -Contain 'oemLeftover'
      Should -Invoke Invoke-ToolNative -Times 0
    }
    It 'a stopped report still writes what it collected; the sections it did not reach are listed as not collected' {
      $r = New-ReportActionRun fullReport
      Mock Invoke-ToolStepReport03 { [IO.File]::WriteAllText($r.StopPath, 'stop'); 'done' }
      $outcome = Invoke-ToolSteps -Run $r
      $outcome | Should -Be 'Stopped'
      Test-Path $r.Files.Report | Should -BeTrue
      $t = [IO.File]::ReadAllText($r.Files.Report)
      $t | Should -Match '== 01 SYSTEM =='; $t | Should -Match '== 07 EVENTS AND CRASHES =='
      $t | Should -Match 'Not collected: This section \(not run: the report was stopped or ran out of time\)'
      # One summary line and one finding in the window for the sections not reached, not ten.
      $t | Should -Match '\[INFO\] This section: not collected \(not run: the report was stopped or ran out of time\) \(sections 03, 04, 05, 06, 07, 08, 09, 10, 11, 12\)'
      @(foreach ($f in $r.Findings) { if ($f.Code -eq 'notCollected' -and $f.Args[0] -eq 'This section') { $f } }).Count | Should -Be 1
      (Get-StepStatus -Run $r -Id 'reportZip') | Should -Be 'skipped'
    }
  }
}
