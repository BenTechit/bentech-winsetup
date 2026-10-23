# tests/ToolPrivacy.Tests.ps1
# Repair & diagnostics Task 9 (repair spec 6.8, Q33; rulings RD-R4, RD-R23): the privacy-safe (SAFE) copy of a report
# (src\Repair\ToolPrivacy.ps1), Compare with last visit and the "since last visit" section (src\Repair\ToolCompare.ps1),
# the compare action, the safety child's safetyEarlier step, and what reportWrite adds (src\Repair\ToolReport.ps1).
#
# SAFETY: this runs on Ben's real PC. For real, the report collectors read this PC's event logs, programs, devices, disks,
# network, users and CIM and start PowerShell grandchildren; Compare reads report files on the BenTech stick. Here nothing
# is started, nothing is changed and no answer comes from this PC: every source answers from the fake PC of
# tests\fixtures\ReportFakePc.ps1 (its header lists the mocks and the safety nets; its sample report is built from the
# real collectors on that fake PC), and every "stick" is a folder under $TestDrive. No test reads this PC's personal
# data: the identifiers below are the fake PC's and made-up ones. Every file a test writes is under $TestDrive.
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Common\Config', 'State\State', 'Steps\Winget', 'Engine\Reboot',
                 'UI\StartScreen', 'Toolbox\Strings', 'Entry\Cleanup', 'Detect\Detection', 'Detect\PcName', 'Report\Report', 'Repair\ToolEngine',
                 'Repair\ToolChecks', 'Repair\ToolSafety', 'Repair\ToolRepairs', 'Repair\ToolAdvanced', 'Repair\ToolCollect', 'Repair\ToolReport',
                 'Repair\ToolPrivacy', 'Repair\ToolCompare') {
    . "$PSScriptRoot\..\src\$f.ps1"
  }
  . "$PSScriptRoot\fixtures\ReportFakePc.ps1"
  Initialize-ReportFakePc
  $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
  $script:privacyFile = "$PSScriptRoot\..\src\Repair\ToolPrivacy.ps1"
  $script:compareFile = "$PSScriptRoot\..\src\Repair\ToolCompare.ps1"
  $script:reportFile = "$PSScriptRoot\..\src\Repair\ToolReport.ps1"
  $script:safetyFile = "$PSScriptRoot\..\src\Repair\ToolSafety.ps1"

  function Get-Codes { param($Findings) @(foreach ($f in $Findings) { [string]$f.Code }) }
  function Get-Flag { param($Findings, [string]$Code) foreach ($f in $Findings) { if ([string]$f.Code -ceq $Code) { return $f } } }
  function Read-Fixture { param([string]$Name) Read-ToolJsonFile -Path (Join-Path $script:fixtures $Name) -MaxBytes $script:ToolReportDataMaxBytes }
  function Write-DataFile {
    # A report's data JSON at <folder>\<name> (the folder is made), as reportWrite writes it (plain UTF-8, RD-R23).
    param([string]$Folder, [string]$Name, $Data)
    [void][IO.Directory]::CreateDirectory($Folder)
    $path = Join-Path $Folder $Name
    Write-ToolJsonFile -Path $path -InputObject $Data -Depth 10 -Utf8 | Should -BeTrue
    $path
  }
  # A stick under $TestDrive (-Name) with BenTech-Reports\ holding: the Dell's visits of 01/09 and 01/10 (the earlier
  # fixture, the newest earlier one), white box A's visit (another PC whose folder part is white box B's), and the
  # current visit's own report of today. Returns @{ Root (with its trailing \); Reports; Current }.
  function New-CompareStick {
    param([string]$Name = 'CmpStick')
    $stick = Join-Path $TestDrive $Name
    if ([IO.Directory]::Exists($stick)) { [IO.Directory]::Delete($stick, $true) }
    $reports = Join-Path $stick 'BenTech-Reports'
    $earlier = Read-Fixture 'report-earlier-data.json'
    $older = Copy-ReportValue -Value $earlier; $older['CreatedAt'] = '2026-09-01T09:00:00'
    $today = Copy-ReportValue -Value $earlier; $today['CreatedAt'] = '2026-10-23T14:05:30'
    $null = Write-DataFile -Folder (Join-Path $reports 'DELL-7HX2K93_7HX2K93_2026-09-01_0900') -Name 'REPORT_DELL-7HX2K93_2026-09-01_0900_data.json' -Data $older
    $null = Write-DataFile -Folder (Join-Path $reports 'DELL-7HX2K93_7HX2K93_2026-10-01_0900') -Name 'REPORT_DELL-7HX2K93_2026-10-01_0900_data.json' -Data $earlier
    $null = Write-DataFile -Folder (Join-Path $reports 'PC-9ABCDE_UUID-3456789ABCDE_2026-10-10_1000') -Name 'REPORT_PC-9ABCDE_2026-10-10_1000_data.json' -Data (Read-Fixture 'report-whitebox-a.json')
    $current = Join-Path $reports 'DELL-7HX2K93_7HX2K93_2026-10-23_1400'
    $null = Write-DataFile -Folder $current -Name 'REPORT_DELL-7HX2K93_2026-10-23_1405_data.json' -Data $today
    @{ Root = $stick + '\'; Reports = $reports; Current = $current }
  }
}

Describe 'ToolPrivacy and ToolCompare (repair Task 9)' {
  BeforeAll {
    Register-ReportFakePcMocks
    Reset-ReportFakePc
    $script:sample = New-ReportSample
    if (@($script:blocked).Count -gt 0) { throw ('The sample touched a blocked command: ' + (@($script:blocked) -join ', ')) }
    $script:earlier = Read-Fixture 'report-earlier-data.json'
    # The current data: the sample's (the same Dell), its system disk now at 84% wear and one new blue screen. The earlier
    # visit had Chrome 129 and Old Toolbar, a lower free space and a Logitech receiver with a problem.
    $script:now = Copy-ReportValue -Value (ConvertTo-ReportData -Report $script:sample)
    $script:now['Disks']['S4EWNX0R123456']['Wear'] = 84
    $script:now['Crashes']['BugCheck'] = @('2026-10-20T11:00:00')
    $script:whiteboxB = Read-Fixture 'report-whitebox-b.json'
  }
  BeforeEach { Reset-ReportFakePc }
  AfterEach {
    @($script:blocked) | Should -BeNullOrEmpty
    $script:SetupLogPath = $null
    Unregister-SetupTick
  }

  Describe 'the SAFE copy (Q33)' {
    It 'the SAFE copy holds none of the identifiers, in any case or spelling, and tokens are stable (Review Focus 5)' {
      $known = @{ User = @('Dana', 'דנה כהן', 'admin_dana'); Computer = @('DELL-7HX2K93'); Serial = @('7HX2K93', 'S4EWNX0R123456'); Mac = @('A4-BB-6D-12-34-56'); Ip = @('192.168.1.10')
                  Ssid = @('Cohen_Home_5G'); Email = @('dana.cohen@example.co.il') }
      $text = @('PC DELL-7HX2K93 sn 7hx2k93', 'C:\Users\דנה כהן\AppData', 'mac a4:bb:6d:12:34:56 and A4-BB-6D-12-34-56', 'ip 192.168.1.10 gw 192.168.1.1 dns 2a00:1450:4001::8a',
                'Wi-Fi Cohen_Home_5G', 'mail DANA.COHEN@EXAMPLE.CO.IL', 'call 050-1234567 or +972 3 6123456', 'disk S4EWNX0R123456', 'user Dana logged on') -join "`n"
      $safe = ConvertTo-SafeText -Masker (New-SafeMasker -Known $known) -Text $text
      foreach ($v in @($known.Values | ForEach-Object { $_ }) + '7hx2k93', 'a4:bb:6d:12:34:56', '192.168.1.1', '2a00:1450:4001::8a', '050-1234567', '6123456') { $safe | Should -Not -Match ([regex]::Escape($v)) }
      $safe | Should -Match 'PC PC-1 sn SERIAL-1'; $safe | Should -Match 'mac MAC-1 and MAC-1'; $safe | Should -Match 'C:\\Users\\user\d\\AppData'
      # The exact text: known values by their list order, pattern finds by appearance, one token per value.
      $safe | Should -BeExactly (@('PC PC-1 sn SERIAL-1', 'C:\Users\user2\AppData', 'mac MAC-1 and MAC-1', 'ip IP-1 gw IP-2 dns IP6-1', 'Wi-Fi SSID-1', 'mail EMAIL-1',
                                    'call PHONE-1 or PHONE-2', 'disk SERIAL-2', 'user user1 logged on') -join "`n")
    }
    It 'keeps 127.0.0.1, 0.0.0.0, masks, ::1, times and versions so the AI can still read them' { $t = 'lo 127.0.0.1 any 0.0.0.0 mask 255.255.255.0 v6 ::1 at 10:15:45 build 10.0.26100.1'
      ConvertTo-SafeText -Masker (New-SafeMasker -Known @{}) -Text $t | Should -BeExactly $t }
    It 'masks e-mails and phone numbers inside the complaint' { $s = ConvertTo-SafeText -Masker (New-SafeMasker -Known @{}) -Text 'המחשב איטי, לחזור ל-054-7654321 או dana@gmail.com'
      $s | Should -BeExactly 'המחשב איטי, לחזור ל-PHONE-1 או EMAIL-1' }
    It 'reportWrite writes the SAFE copy beside the core, with no PC name in its file name (RD-R4)' { $r = New-ReportSampleRun -Sample $script:sample; $null = Invoke-ToolStepReportWrite -Run $r
      $safe = @(Get-ChildItem (Split-Path $r.Files.Report) -Filter 'REPORT_SAFE_*.txt')[0].FullName
      Test-Path $safe | Should -BeTrue; (Split-Path $safe -Leaf) | Should -Not -Match '7HX2K93'; (Split-Path $safe -Leaf) | Should -Match '^REPORT_SAFE_\d{4}-\d{2}-\d{2}_\d{4}\.txt$'
      [IO.File]::ReadAllText($safe) | Should -Not -Match '7HX2K93'; [IO.File]::ReadAllText($r.Files.Report) | Should -Match '7HX2K93'
      $r.Files.Safe | Should -BeExactly $safe
      $b = [IO.File]::ReadAllBytes($safe); $b[0..2] | Should -Be @(0xEF, 0xBB, 0xBF) }

    It 'the masker gaps of the Task 8 review: SIDs, the domain and compact-hex MACs; well-known SIDs, GUIDs and plain numbers stay' {
      $known = @{ Sid = @('S-1-5-21-1-2-3-1001'); Domain = @('contoso.local', 'CONTOSO'); Mac = @('A4-BB-6D-12-34-56') }
      $text = @('task OneDrive Standalone Update Task-S-1-5-21-1-2-3-1001', 'other S-1-5-21-9-8-7-500 and s-1-12-1-11-22-33-44', 'system S-1-5-18 admins S-1-5-32-544',
                'user CONTOSO\x at dc1.contoso.local', 'bt BTHENUM\{0000110b-0000-1000-8000-00805f9b34fb}_LOCALMFG&0002\7&2A5B5C4E&0&A4BB6D123456_C00000000',
                'adapter {5D36E972-E325-11CE-BFC1-08002BE10318} other 001a2b3c4d5e size 512110190592 code 0x00000000001F') -join "`n"
      $safe = ConvertTo-SafeText -Masker (New-SafeMasker -Known $known) -Text $text
      $safe | Should -BeExactly (@('task OneDrive Standalone Update Task-SID-1', 'other SID-2 and SID-3', 'system S-1-5-18 admins S-1-5-32-544',
                                    'user DOMAIN-2\x at dc1.DOMAIN-1', 'bt BTHENUM\{0000110b-0000-1000-8000-00805f9b34fb}_LOCALMFG&0002\7&2A5B5C4E&0&MAC-1_C00000000',
                                    'adapter {5D36E972-E325-11CE-BFC1-08002BE10318} other MAC-2 size 512110190592 code 0x00000000001F') -join "`n")
    }
    It 'profile paths in any case give a user token, the same name the same one; built-in folders stay' {
      $safe = ConvertTo-SafeText -Masker (New-SafeMasker -Known @{ User = @('Dana') }) -Text 'c:\users\Yossi\Desktop, C:\Users\Public\Documents, C:\Users\Default, D:\Users\YOSSI\x, C:\Users\Dana and C:\Users\Moshe Levi\AppData'
      $safe | Should -BeExactly 'c:\users\user2\Desktop, C:\Users\Public\Documents, C:\Users\Default, D:\Users\user2\x, C:\Users\user1 and C:\Users\user3\AppData'
    }
    It 'one masker gives the same token to a value in every call and every spelling (one report, one masker)' {
      $m = New-SafeMasker -Known @{ Ip = @('10.1.2.3') }
      ConvertTo-SafeText -Masker $m -Text 'gw 192.168.7.1, mac 00-1A-2B-3C-4D-5E' | Should -BeExactly 'gw IP-2, mac MAC-1'
      ConvertTo-SafeText -Masker $m -Text 'mac 001A2B3C4D5E 00:1a:2b:3c:4d:5e, gw 192.168.7.1, known 10.1.2.3, v6 FE80::1%7 fe80:0:0::1' | Should -BeExactly 'mac MAC-1 MAC-1, gw IP-2, known IP-1, v6 IP6-1 IP6-1'
      ConvertTo-SafeText -Masker $m -Text '050-1234567 and +972-50-1234567 and 0501234567' | Should -BeExactly 'PHONE-1 and PHONE-1 and PHONE-1'
    }
    It 'a known value under 3 characters is never masked, a short one only as a whole word, a long one everywhere' {
      # RD-R25: a numeric serial under 6 digits is no known value (I2); a token a letter or digit follows gets '_' (M4).
      $m = New-SafeMasker -Known @{ User = @('Al', 'Ben'); Serial = @('1234', 'CNCMK0034R00AB'); Computer = @('OFFICE-PC') }
      ConvertTo-SafeText -Masker $m -Text 'Al Ben Bench KB51234 serial 1234 board /X/CNCMK0034R00AB/ usb USB\VID_1\CNCMK0034R00AB99 at office-pc2' |
        Should -BeExactly 'Al user1 Bench KB51234 serial 1234 board /X/SERIAL-1/ usb USB\VID_1\SERIAL-1_99 at PC-1_2'
    }
    It 'Get-ReportIdentifiers names every personal value the collectors saw, and never a built-in account or a placeholder' {
      $id = Get-ReportIdentifiers -Report $script:sample
      foreach ($k in 'User', 'Computer', 'Serial', 'Mac', 'Ip', 'Ssid', 'Email', 'Sid', 'Domain') { $id.ContainsKey($k) | Should -BeTrue -Because $k }
      @($id.User) | Should -Contain 'Dana'; @($id.User) | Should -Not -Contain 'Administrator'; @($id.User) | Should -Not -Contain 'Guest'
      @($id.Computer) | Should -Contain 'DELL-7HX2K93'
      foreach ($s in '7HX2K93', 'S4EWNX0R123456', '4C530001', '/7HX2K93/CNCMK0034R00AB/', '80AD0123', '4C4C4544-0048-5810-8032-B7C04F4B3933') { @($id.Serial) | Should -Contain $s }
      @($id.Mac) | Should -Contain 'A4-BB-6D-12-34-57'; @($id.Ip) | Should -Contain '192.168.1.23'; @($id.Ip) | Should -Contain '192.168.1.1'
      @($id.Ssid) | Should -Contain 'Cohen_Home_5G'; @($id.Email) | Should -Contain 'dana.cohen@example.co.il'; @($id.Sid) | Should -Contain 'S-1-5-21-1-2-3-1001'
      @($id.Domain).Count | Should -Be 0   # a workgroup PC named WORKGROUP
      # A domain PC: the domain, the NetBIOS domain of its accounts, a custom workgroup and a proxy host; the placeholder serial is no serial.
      $domain = Copy-ReportValue -Value $script:sample
      $domain['Items']['Domain'] = 'contoso.local'; $domain['Items']['SignedInUser'] = 'CONTOSO\yossi'; $domain['Items']['UserProxy'] = 'proxy.contoso.local:8080'
      $domain['Items']['Admins'] = @(@{ Name = 'CONTOSO\Domain Admins'; Sid = 'S-1-5-21-5-6-7-512' }, @{ Name = 'MicrosoftAccount\dana.cohen@outlook.com'; Sid = 'S-1-5-21-1-2-3-1002' })
      $domain['Items']['BoardSerial'] = 'To Be Filled By O.E.M.'
      $d = Get-ReportIdentifiers -Report $domain
      foreach ($v in 'contoso.local', 'CONTOSO', 'proxy.contoso.local') { @($d.Domain) | Should -Contain $v }
      @($d.User) | Should -Contain 'yossi'; @($d.Email) | Should -Contain 'dana.cohen@outlook.com'; @($d.Sid) | Should -Contain 'S-1-5-21-5-6-7-512'
      @($d.Serial) | Should -Not -Contain 'To Be Filled By O.E.M.'
      $wg = Copy-ReportValue -Value $script:sample; $wg['Items']['Workgroup'] = 'COHEN-FAMILY'
      @((Get-ReportIdentifiers -Report $wg).Domain) | Should -Contain 'COHEN-FAMILY'
      # Hebrew Windows: the built-in Guest is localized; found by SID (BuiltinUsers), it stays. A renamed Administrator is masked.
      $guest = -join ([char[]](0x05D0, 0x05D5, 0x05E8, 0x05D7))
      $he = Copy-ReportValue -Value $script:sample; $he['Items']['Users'] = @('Dana', $guest, 'DanaAdmin'); $he['Items']['BuiltinUsers'] = @($guest)
      $hid = Get-ReportIdentifiers -Report $he
      @($hid.User) | Should -Not -Contain $guest; @($hid.User) | Should -Contain 'DanaAdmin'
      @($script:sample.Items.BuiltinUsers) | Should -Be @('Guest')   # the collector reads it by SID (-501)
      # The earlier report's disk serials (a disk that is gone shows in "since last visit").
      @((Get-ReportIdentifiers -Report $script:sample -Earlier $script:earlier).Serial) | Should -Contain 'WD-OLD123456'
    }
    It 'the SAFE copy of the sample report holds none of the sample''s identifiers and keeps what the AI needs' {
      $r = New-ReportSampleRun -Sample $script:sample
      Invoke-ToolStepReportWrite -Run $r | Should -Be 'done'
      $t = [IO.File]::ReadAllText($r.Files.Safe)
      $id = Get-ReportIdentifiers -Report $script:sample
      foreach ($k in @($id.Keys)) { foreach ($v in @($id[$k])) { if ([string]$v -ne '' -and ([string]$v).Length -ge 3) { $t | Should -Not -Match ([regex]::Escape([string]$v)) -Because "$k $v" } } }
      foreach ($v in 'Dana', '192.168.1', 'A4-BB-6D', 'Cohen', 'S-1-5-21-1-2-3') { $t | Should -Not -Match ([regex]::Escape($v)) -Because $v }
      foreach ($keep in 'Samsung SSD 980 PRO 512GB', 'Microsoft Defender Antivirus', 'Windows 11 Pro 24H2', '26100.2033', 'המחשב איטי', 'Intel(R) Wi-Fi 6E AX211', 'HOW TO USE',
                        'C:\Users\user1\AppData\Local\Microsoft\OneDrive\OneDrive.exe', 'PC-1\user1', 'PRIVACY-SAFE COPY') {
        $t | Should -Match ([regex]::Escape($keep)) -Because $keep }
      ($t -split "`r`n")[0] | Should -Match '\| PC PC-1 \|.*\| serial SERIAL-1$'
      $t | Should -Match 'Local users = user1, Administrator \(disabled\), Guest \(disabled\)'
    }
    It 'a masker that fails writes no SAFE copy (fail closed); the full report stays and the window says so' {
      $r = New-ReportSampleRun -Sample $script:sample
      Mock ConvertTo-SafeText { throw 'masker broke' }
      Invoke-ToolStepReportWrite -Run $r | Should -Be 'done'
      Test-Path $r.Files.Report | Should -BeTrue
      @(Get-ChildItem $r.SessionDir -Filter 'REPORT_SAFE_*').Count | Should -Be 0; $r.Files.ContainsKey('Safe') | Should -BeFalse
      (Get-Flag $r.Findings 'reportWriteFailed').Args[0] | Should -BeExactly 'the privacy-safe copy could not be written'
      (Get-Flag $r.Findings 'reportWriteFailed').Level | Should -Be 'WARN'
    }
    It 'the SAFE copy is never written through a link (V2-R13)' {
      $r = New-ReportSampleRun -Sample $script:sample
      Mock Test-StickReparsePoint { $Path -like '*REPORT_SAFE_*' }
      Invoke-ToolStepReportWrite -Run $r | Should -Be 'done'
      @(Get-ChildItem $r.SessionDir -Filter 'REPORT_SAFE_*').Count | Should -Be 0
      (Get-Flag $r.Findings 'reportWriteFailed').Args[0] | Should -BeExactly 'the privacy-safe copy is a link'
    }
  }

  Describe 'compare with last visit (spec 6.8)' {
    BeforeAll {
      $script:cmp = New-CompareStick
      $script:stick = $script:cmp.Root; $script:current = $script:cmp.Current
    }
    It 'finds the earlier report of the same serial, never the current session''s' { # the stick holds <session A>\REPORT_..._data.json (SN-7HX2K93, 01/10) and the current session's own (today)
      (Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current).CreatedAt | Should -Be '2026-10-01T09:00:00'
      Find-ToolEarlierReport -StickRoot $stick -IdentityKey '' -CurrentSessionDir $current | Should -BeNullOrEmpty
      # Another visit (not the one of today's report) finds today's: the newest.
      (Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir 'x').CreatedAt | Should -Be '2026-10-23T14:05:30'
      (Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current).File | Should -Match 'REPORT_DELL-7HX2K93_2026-10-01_0900_data\.json$'
      Find-ToolEarlierReport -StickRoot '' -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current | Should -BeNullOrEmpty
      Find-ToolEarlierReport -StickRoot (Join-Path $TestDrive 'NoSuchStick') -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current | Should -BeNullOrEmpty }
    It 'two whiteboxes with the same placeholder serial are never merged' { Find-ToolEarlierReport -StickRoot $stick -IdentityKey (Get-MachineIdentity -Machine $whiteboxB).Key -CurrentSessionDir 'x' | Should -BeNullOrEmpty
      # B's folder part is A's (the same last 12 hex of the UUID): A's file is read, refused by its key, and is no "unreadable" file.
      (Get-MachineIdentity -Machine $whiteboxB).FolderPart | Should -BeExactly 'UUID-3456789ABCDE'
      $skipped = New-Object System.Collections.Generic.List[string]
      Find-ToolEarlierReport -StickRoot $stick -IdentityKey (Get-MachineIdentity -Machine $whiteboxB).Key -CurrentSessionDir 'x' -Skipped $skipped | Should -BeNullOrEmpty
      $skipped.Count | Should -Be 0
      (Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'UUID-8A3F2C105B6D4E7F90123456789ABCDE' -CurrentSessionDir 'x').CreatedAt | Should -Be '2026-10-10T10:00:00' }
    It 'lists new crashes, disk wear, free space, devices, programs and findings' { (Format-ToolSinceLastVisit -Diff (Compare-ToolReportData -Earlier $earlier -Current $now)) | Should -Contain '  Disk S4EWNX0R123456: wear 61% -> 84%' }
    It 'ignores a data file that is too big, not JSON, or a link' { # three newer files of the same key: over 16 MB (RD-R23), '{not json', and one in a folder Test-StickReparsePoint calls a link
      $s = New-CompareStick -Name 'CmpStickBad'
      $big = Join-Path $s.Reports 'DELL-7HX2K93_7HX2K93_2026-10-05_0900'; [void][IO.Directory]::CreateDirectory($big)
      $fs = [IO.File]::Create((Join-Path $big 'REPORT_DELL-7HX2K93_2026-10-05_0900_data.json')); try { $fs.SetLength(17MB) } finally { $fs.Dispose() }
      $bad = Join-Path $s.Reports 'DELL-7HX2K93_7HX2K93_2026-10-06_0900'; [void][IO.Directory]::CreateDirectory($bad)
      [IO.File]::WriteAllText((Join-Path $bad 'REPORT_DELL-7HX2K93_2026-10-06_0900_data.json'), '{not json')
      $linked = Copy-ReportValue -Value $earlier; $linked['CreatedAt'] = '2026-10-07T09:00:00'
      $null = Write-DataFile -Folder (Join-Path $s.Reports 'DELL-7HX2K93_7HX2K93_2026-10-07_0900') -Name 'REPORT_DELL-7HX2K93_2026-10-07_0900_data.json' -Data $linked
      Mock Test-StickReparsePoint { $Path -like '*2026-10-07_0900*' }
      $stick = $s.Root; $current = $s.Current
      (Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current).CreatedAt | Should -Be '2026-10-01T09:00:00'
      # RD-R23: never silently: every file of this PC that could not be read is named, newest first (a folder that is a
      # link is never even listed: V2-R13).
      $skipped = New-Object System.Collections.Generic.List[string]
      $null = Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current -Skipped $skipped
      @($skipped) | Should -Be @('DELL-7HX2K93_7HX2K93_2026-10-07_0900 (a link)', 'REPORT_DELL-7HX2K93_2026-10-06_0900_data.json (not a report data file)',
                                 'REPORT_DELL-7HX2K93_2026-10-05_0900_data.json (too big)')
      # A data file that is itself a link.
      Mock Test-StickReparsePoint { $Path -like '*REPORT_DELL-7HX2K93_2026-10-07_0900_data.json' }
      $skipped.Clear()
      (Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current -Skipped $skipped).CreatedAt | Should -Be '2026-10-01T09:00:00'
      @($skipped)[0] | Should -Be 'REPORT_DELL-7HX2K93_2026-10-07_0900_data.json (a link)'; $skipped.Count | Should -Be 3

      # BenTech-Reports itself a link: nothing on the stick is read.
      Mock Test-StickReparsePoint { $Path -like '*BenTech-Reports' }
      Find-ToolEarlierReport -StickRoot $stick -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $current | Should -BeNullOrEmpty }

    It 'the since-last-visit section, line by line (dd/MM/yyyy HH:mm; names keep their real text)' {
      $lines = @(Format-ToolSinceLastVisit -Diff (Compare-ToolReportData -Earlier $earlier -Current $now))
      $lines | Should -Be @(
        'SINCE LAST VISIT (01/10/2026 09:00)'
        '  New blue screens: 1 (the newest 20/10/2026 11:00)'
        '  New Kernel-Power 41 events: 1 (the newest 21/10/2026 11:42)'
        '  Disk S4EWNX0R123456: wear 61% -> 84%'
        '  Disk 4C530001 (SanDisk Cruzer Glide): new'
        '  Disk WD-OLD123456 (WD Elements): not found this time'
        '  Free space: 9.5 GB (2%) -> 210.4 GB (44%)'
        '  New device problem: Intel(R) Wi-Fi 6E AX211 160MHz (code 28)'
        '  Device problem gone: Logitech USB Receiver (code 43)'
        '  Updated: Google Chrome 129.0.6668.90 -> 130.0.6723.70'
        '  Removed: Old Toolbar 1.0'
        '  New finding: [WARN] 1 devices have a problem (codes 28) (section 06)'
        '  Resolved: [WARN] C: 9.5 GB free (2%) (section 03)'
        # RD-R25: the earlier visit had a Quick report, this one a Full one.
        '  Not compared: the checks only a Full report makes (one visit had a Quick report, the other a Full one)')
      # wuDisabled (05) is not claimed resolved: section 05 was not fully collected this time; a source missing is no evidence.
      ($lines -join "`n") | Should -Not -Match 'Windows Update service'
      (Compare-ToolReportData -Earlier $earlier -Current $now).Count | Should -Be 12
    }
    It '(no changes) when nothing changed; a list one report lacks is not read as everything removed' {
      @(Format-ToolSinceLastVisit -Diff (Compare-ToolReportData -Earlier $earlier -Current $earlier)) | Should -Be @('SINCE LAST VISIT (01/10/2026 09:00)', '  (no changes)')
      $empty = Copy-ReportValue -Value $earlier; $empty['Programs'] = @(); $empty['Disks'] = [ordered]@{}
      $l = @(Format-ToolSinceLastVisit -Diff (Compare-ToolReportData -Earlier $earlier -Current $empty))
      $l | Should -Not -Contain '  Removed: Old Toolbar 1.0'; ($l -join "`n") | Should -Not -Match 'not found this time'
      $l | Should -Contain '  Programs: not compared (one of the two reports has no program list)'
      $l | Should -Contain '  Disks: not compared (one of the two reports has no disk list)'
      $l | Should -Contain '  (no changes)'
      (Compare-ToolReportData -Earlier $earlier -Current $empty).Count | Should -Be 0
    }
    It 'a long program list is cut with a count, and the count of changes stays whole' {
      $many = Copy-ReportValue -Value $earlier; $many['Programs'] = @($earlier['Programs']) + @(for ($i = 0; $i -lt 60; $i++) { 'Tool {0}|1.{0}' -f $i })
      $d = Compare-ToolReportData -Earlier $earlier -Current $many
      $l = @(Format-ToolSinceLastVisit -Diff $d)
      @($l | Where-Object { $_ -like '  Installed: *' }).Count | Should -Be 40; $l | Should -Contain '  ... and 20 more installed'
      $d.Count | Should -Be 60
    }
    It 'the folder part of a key is Get-MachineIdentity''s (Compare reads only this PC''s visit folders)' {
      foreach ($m in @(@{ Serial = '7HX2K93' }, @{ Serial = 'ABCDEFGHIJ0123456789XYZ' }, $whiteboxB)) {
        $i = Get-MachineIdentity -Machine $m
        Get-ToolIdentityFolderPart -IdentityKey $i.Key | Should -BeExactly $i.FolderPart }
      Get-ToolIdentityFolderPart -IdentityKey '' | Should -BeExactly ''; Get-ToolIdentityFolderPart -IdentityKey 'odd' | Should -BeExactly ''
    }

    It 'Quick and Full reports put SINCE LAST VISIT right after section 00, and its SAFE copy masks the disks of both visits' {
      $folder = Join-Path $script:reports 'DELL-7HX2K93_7HX2K93_2026-10-01_0900'
      try {
        $null = Write-DataFile -Folder $folder -Name 'REPORT_DELL-7HX2K93_2026-10-01_0900_data.json' -Data $earlier
        $r = New-ReportSampleRun -Sample $script:sample
        Invoke-ToolStepReportWrite -Run $r | Should -Be 'done'
        $t = [IO.File]::ReadAllText($r.Files.Report)
        $t.IndexOf('== 00 SUMMARY ==') | Should -BeLessThan $t.IndexOf('SINCE LAST VISIT (01/10/2026 09:00)')
        $t.IndexOf('SINCE LAST VISIT (01/10/2026 09:00)') | Should -BeLessThan $t.IndexOf('== 01 SYSTEM ==')
        $t | Should -Match ([regex]::Escape('  Disk S4EWNX0R123456: wear 61% -> 7%')); $t | Should -Match ([regex]::Escape('  Removed: Old Toolbar 1.0'))
        $s = [IO.File]::ReadAllText($r.Files.Safe)
        $s | Should -Match 'SINCE LAST VISIT \(01/10/2026 09:00\)'; $s | Should -Match '  Disk SERIAL-\d+: wear 61% -> 7%'
        $s | Should -Not -Match 'S4EWNX0R123456'; $s | Should -Not -Match 'WD-OLD123456'
        # Without an earlier report there is no such section (the sample's other tests).
        [IO.Directory]::Delete($folder, $true)
        $r2 = New-ReportSampleRun -Sample $script:sample; $null = Invoke-ToolStepReportWrite -Run $r2
        [IO.File]::ReadAllText($r2.Files.Report) | Should -Not -Match 'SINCE LAST VISIT'
      } finally { if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder, $true) } }
    }
    It 'a report whose earlier report of this PC cannot be read says so, in the report and in the window (RD-R23)' {
      $folder = Join-Path $script:reports 'DELL-7HX2K93_7HX2K93_2026-10-01_0900'
      try {
        [void][IO.Directory]::CreateDirectory($folder); [IO.File]::WriteAllText((Join-Path $folder 'REPORT_DELL-7HX2K93_2026-10-01_0900_data.json'), '{not json')
        $r = New-ReportSampleRun -Sample $script:sample
        Invoke-ToolStepReportWrite -Run $r | Should -Be 'done'
        $t = [IO.File]::ReadAllText($r.Files.Report)
        $t | Should -Match 'SINCE LAST VISIT\r\n  \(not compared: 1 earlier report files of this PC could not be read: REPORT_DELL-7HX2K93_2026-10-01_0900_data\.json \(not a report data file\)\)'
        $f = Get-Flag $r.Findings 'earlierUnreadable'; $f.Level | Should -Be 'WARN'; $f.Args[0] | Should -Be '1'
        $f.Text | Should -BeExactly '1 earlier report files of this PC could not be read and were not compared: REPORT_DELL-7HX2K93_2026-10-01_0900_data.json (not a report data file)'
      } finally { if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder, $true) } }
    }
    It 'an earlier file the comparison cannot use never costs the report or the comparison file: it is named instead' {
      $folder = Join-Path $script:reports 'DELL-7HX2K93_7HX2K93_2026-10-01_0900'
      try {
        $null = Write-DataFile -Folder $folder -Name 'REPORT_DELL-7HX2K93_2026-10-01_0900_data.json' -Data $earlier
        Mock Compare-ToolReportData { throw 'an odd shape' }
        $r = New-ReportSampleRun -Sample $script:sample
        Invoke-ToolStepReportWrite -Run $r | Should -Be 'done'
        [IO.File]::ReadAllText($r.Files.Report) | Should -Match ([regex]::Escape('(not compared: 1 earlier report files of this PC could not be read: REPORT_DELL-7HX2K93_2026-10-01_0900_data.json (not a report data file))'))
        (Get-Codes $r.Findings) | Should -Contain 'earlierUnreadable'; Test-Path $r.Files.Safe | Should -BeTrue
        $c = New-ReportActionRun compare
        Invoke-ToolSteps -Run $c | Should -Be 'Done'
        Test-Path $c.Files.Compare | Should -BeTrue; (Get-Codes $c.Findings) | Should -Contain 'earlierUnreadable'; (Get-Codes $c.Findings) | Should -Not -Contain 'compareDone'
      } finally { if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder, $true) } }
    }

    It 'the compare action end to end: the COMPARE file, COMPARE_SAFE (no PC name) and its data, which the next Compare finds (a visit too)' {
      $folder = Join-Path $script:reports 'DELL-7HX2K93_7HX2K93_2026-10-01_0900'
      try {
        $null = Write-DataFile -Folder $folder -Name 'REPORT_DELL-7HX2K93_2026-10-01_0900_data.json' -Data $earlier
        $r = New-ReportActionRun compare
        $r.Args['Complaint'] = 'slow since last week, call dana@gmail.com'
        Invoke-ToolSteps -Run $r | Should -Be 'Done'
        @(foreach ($s in $r.Steps) { $s.Status }) | Should -Not -Contain 'failed'
        (Split-Path $r.Files.Compare -Leaf) | Should -BeExactly 'COMPARE_DELL-7HX2K93_2026-10-23_1405.txt'
        (Split-Path $r.Files.CompareSafe -Leaf) | Should -BeExactly 'COMPARE_SAFE_2026-10-23_1405.txt'
        (Split-Path $r.Files.Data -Leaf) | Should -BeExactly 'COMPARE_DELL-7HX2K93_2026-10-23_1405_data.json'
        $t = [IO.File]::ReadAllText($r.Files.Compare)
        ($t -split "`r`n")[0] | Should -Match '^BENTECH TOOLBOX COMPARE \| 23/10/2026 14:05 \| version dev \| PC DELL-7HX2K93 \| Dell Inc\. Latitude 5440 \| serial 7HX2K93$'
        $t | Should -Match 'CUSTOMER COMPLAINT\r\n  slow since last week, call dana@gmail\.com'
        $t | Should -Match 'SINCE LAST VISIT \(01/10/2026 09:00\)'; $t | Should -Match ([regex]::Escape('  Disk S4EWNX0R123456: wear 61% -> 7%'))
        $b = [IO.File]::ReadAllBytes($r.Files.Compare); $b[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $s = [IO.File]::ReadAllText($r.Files.CompareSafe)
        $s | Should -Not -Match '7HX2K93'; $s | Should -Not -Match 'S4EWNX0R123456'; $s | Should -Not -Match 'dana@gmail'; $s | Should -Match 'call EMAIL-\d'   # EMAIL-1 is the OneDrive address the report knows
        $s | Should -Match 'PC PC-1'
        # The window: what was compared, and the findings that are new since that visit.
        $count = (Compare-ToolReportData -Earlier $earlier -Current (Read-ToolJsonFile -Path $r.Files.Data -MaxBytes $script:ToolReportDataMaxBytes)).Count
        $count | Should -Be 12   # Kernel-Power 1, disks 3, free space 1, devices 2, programs 2, findings 3 (Quick collects section 05 in full)
        $done = Get-Flag $r.Findings 'compareDone'; $done.Level | Should -Be 'INFO'; @($done.Args) | Should -Be @('01/10/2026 09:00', [string]$count)
        (Get-Codes $r.Findings) | Should -Contain 'devicesProblem'; (Get-Codes $r.Findings) | Should -Not -Contain 'oemLeftover'   # not new
        Get-ToolResultColor -Outcome 'Done' -Findings $r.Findings | Should -Be 'YELLOW'
        # It is a visit too: from another visit, the newest report of this PC is the comparison's data.
        $next = Find-ToolEarlierReport -StickRoot $script:stickRoot -IdentityKey 'SN-7HX2K93' -CurrentSessionDir 'x'
        $next.CreatedAt | Should -Be '2026-10-23T14:05:30'; $next.Kind | Should -Be 'quick'; $next.File | Should -BeExactly $r.Files.Data
        Write-ToolResult -Run $r -Outcome Done | Should -BeTrue
        (Read-ToolJsonFile -Path $r.ResultPath).Data.ContainsKey('Report') | Should -BeFalse
      } finally { if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder, $true) } }
    }
    It 'compare without an earlier report: WARN compareNoEarlier, and still a visit' {
      $r = New-ReportActionRun compare
      Invoke-ToolSteps -Run $r | Should -Be 'Done'
      (Get-Flag $r.Findings 'compareNoEarlier').Level | Should -Be 'WARN'
      Test-Path $r.Files.Data | Should -BeTrue
      [IO.File]::ReadAllText($r.Files.Compare) | Should -Match 'SINCE LAST VISIT\r\n  \(no earlier report of this PC on the stick\)'
    }
    It 'compare whose earlier report cannot be read: WARN earlierUnreadable, never a comparison with nothing' {
      $folder = Join-Path $script:reports 'DELL-7HX2K93_7HX2K93_2026-10-01_0900'
      try {
        [void][IO.Directory]::CreateDirectory($folder); [IO.File]::WriteAllText((Join-Path $folder 'REPORT_DELL-7HX2K93_2026-10-01_0900_data.json'), '{not json')
        $r = New-ReportActionRun compare
        Invoke-ToolSteps -Run $r | Should -Be 'Done'
        (Get-Codes $r.Findings) | Should -Contain 'earlierUnreadable'; (Get-Codes $r.Findings) | Should -Not -Contain 'compareDone'
        (Get-Codes $r.Findings) | Should -Not -Contain 'compareNoEarlier'
        [IO.File]::ReadAllText($r.Files.Compare) | Should -Match 'not compared: 1 earlier report files of this PC could not be read'
      } finally { if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder, $true) } }
    }
    It 'a stopped compare writes nothing: a part of a report is never compared (no AlwaysRun)' {
      $r = New-ReportActionRun compare
      Mock Invoke-ToolStepReport03 { [IO.File]::WriteAllText($r.StopPath, 'stop'); 'done' }
      Invoke-ToolSteps -Run $r | Should -Be 'Stopped'
      @(Get-ChildItem $r.SessionDir -Filter 'COMPARE_*').Count | Should -Be 0
    }

    It 'safetyEarlier sets Data.HasEarlierReport for the Compare tile: never the current visit; none without a stick or a key' {
      $s = New-CompareStick -Name 'SafetyStick'
      $run = @{ Args = @{ StickRoot = $s.Root; SessionDir = $s.Current; Identity = @{ Key = 'SN-7HX2K93' } }; Data = @{}; Partial = @{}; Log = (New-Object System.Collections.Generic.List[string]) }
      Mock Write-ToolProgress { }
      Invoke-ToolStepSafetyEarlier -Run $run | Should -Be 'done'; $run.Data.HasEarlierReport | Should -BeTrue
      # Only today's own visit on the stick: none.
      foreach ($old in 'DELL-7HX2K93_7HX2K93_2026-09-01_0900', 'DELL-7HX2K93_7HX2K93_2026-10-01_0900') { [IO.Directory]::Delete((Join-Path $s.Reports $old), $true) }
      $run.Data = @{}; Invoke-ToolStepSafetyEarlier -Run $run | Should -Be 'done'; $run.Data.HasEarlierReport | Should -BeFalse
      # An earlier report of this PC that cannot be read still enables the tile: Compare then says why (never silently "none").
      $bad = Join-Path $s.Reports 'DELL-7HX2K93_7HX2K93_2026-10-01_0900'; [void][IO.Directory]::CreateDirectory($bad)
      [IO.File]::WriteAllText((Join-Path $bad 'REPORT_DELL-7HX2K93_2026-10-01_0900_data.json'), '{not json')
      $run.Data = @{}; Invoke-ToolStepSafetyEarlier -Run $run | Should -Be 'done'; $run.Data.HasEarlierReport | Should -BeTrue
      foreach ($case in @(@{ StickRoot = ''; Key = 'SN-7HX2K93' }, @{ StickRoot = $s.Root; Key = '' })) {
        $run.Args.StickRoot = $case.StickRoot; $run.Args.Identity.Key = $case.Key; $run.Data = @{}
        Invoke-ToolStepSafetyEarlier -Run $run | Should -Be 'done'; $run.Data.HasEarlierReport | Should -BeFalse }
      # A search that throws is none, never a red safety result.
      $run.Args.StickRoot = $s.Root; $run.Args.Identity.Key = 'SN-7HX2K93'; Mock Find-ToolEarlierReport { throw 'stick gone' }
      $run.Data = @{}; Invoke-ToolStepSafetyEarlier -Run $run | Should -Be 'done'; $run.Data.HasEarlierReport | Should -BeFalse
    }

    It 'the catalog rows: compare is read-only, needs the stick, logs to the session; the safety child ends with safetyEarlier' {
      $a = $script:ToolActionCatalog['compare']
      $a.Kind | Should -Be 'readonly'; $a.Confirm | Should -Be 'none'; $a.NeedsStick | Should -BeTrue; $a.LogLocal | Should -BeFalse
      @($a.Steps) | Should -Be @('report01', 'report02', 'report03', 'report04', 'report05', 'report06', 'report07', 'report08', 'report09', 'report10', 'report11', 'compare')
      @($script:ToolActionCatalog['safety'].Steps)[-1] | Should -Be 'safetyEarlier'
      foreach ($id in 'compare', 'safetyEarlier') {
        $s = $script:ToolSteps[$id]
        $s.Function | Should -BeExactly ('Invoke-ToolStep' + $id.Substring(0, 1).ToUpperInvariant() + $id.Substring(1))
        (Get-Command -Name $s.Function -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because $id
        $s.Servicing | Should -BeFalse; ($s['AlwaysRun'] -eq $true) | Should -BeFalse -Because $id
      }
    }
    It 'the new findings'' texts, in English and Hebrew, and every code these files add has both' {
      $expected = [ordered]@{
        'finding.earlierUnreadable'  = '{0} earlier report files of this PC could not be read and were not compared: {1}'
        'finding.compareNoEarlier'   = 'No earlier report of this PC on the stick: nothing to compare'
        'finding.compareDone'        = 'Compared with the visit of {0}: {1} changes'
        'finding.compareWriteFailed' = 'The comparison could not be written ({0})'
      }
      foreach ($k in $expected.Keys) {
        $script:ToolboxStrings.en[$k] | Should -BeExactly $expected[$k] -Because $k
        $script:ToolboxStrings.he[$k] | Should -Match '[א-ת]' -Because $k
        $script:ToolboxStrings.he[$k] | Should -Not -Match "'" -Because $k
        ([regex]::Matches($script:ToolboxStrings.he[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',' |
          Should -Be (([regex]::Matches($expected[$k], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ',') -Because $k
      }
      foreach ($file in $script:compareFile, $script:reportFile, $script:safetyFile, $script:privacyFile) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).Path, [ref]$null, [ref]$null)
        foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-ToolFinding' }, $true)) {
          $i = 0
          foreach ($e in $c.CommandElements) { if ($e -is [Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Code') { break }; $i++ }
          $v = $c.CommandElements[$i + 1]
          if ($v -isnot [Management.Automation.Language.StringConstantExpressionAst]) { continue }   # a report flag passed on ($f.Code)
          $script:ToolboxStrings.en.Keys | Should -Contain ('finding.' + $v.Value) -Because $file
          $script:ToolboxStrings.he.Keys | Should -Contain ('finding.' + $v.Value) -Because $file
        }
      }
    }
  }

  Describe 'the Task 9 review fixes (ruling RD-R25)' {
    BeforeAll {
      $script:fullOnlyNote = '  Not compared: the checks only a Full report makes (one visit had a Quick report, the other a Full one)'
      function Get-Mask { param($Masker, [string]$Text) ConvertTo-SafeText -Masker $Masker -Text $Text }
    }
    It 'I1: a check only a Full report makes is never "new" or "resolved" between a Quick and a Full visit; a note says so' {
      $full = Copy-ReportValue -Value $earlier; $full['Kind'] = 'full'
      $full['Findings'] = @(@{ Code = 'volumeStateSpotFix'; Level = 'CRIT'; Args = @(); Section = '03' }, @{ Code = 'volumeDirty'; Level = 'WARN'; Args = @(); Section = '03' },
                            @{ Code = 'lowSpace'; Level = 'WARN'; Args = @('C:', '9.5', '2'); Section = '03' })
      $quick = Copy-ReportValue -Value $earlier; $quick['Kind'] = 'quick'; $quick['CreatedAt'] = '2026-10-20T09:00:00'; $quick['Findings'] = @()
      # A Full report on visit 1, Compare (Quick sections) on visit 2: no false "Resolved" for the spot fix.
      $d = Compare-ToolReportData -Earlier $full -Current $quick
      @(foreach ($f in $d.FindingsResolved) { $f.Code }) | Should -Be @('volumeDirty', 'lowSpace')
      $l = @(Format-ToolSinceLastVisit -Diff $d)
      $l | Should -Contain $script:fullOnlyNote; ($l -join "`n") | Should -Not -Match 'spot fix'
      # A Quick visit 1 and a Full visit 2: no false "New finding" either.
      @(foreach ($f in (Compare-ToolReportData -Earlier $quick -Current $full).FindingsNew) { $f.Code }) | Should -Be @('volumeDirty', 'lowSpace')
      # Two Full reports compare every code, and say nothing about it.
      $full2 = Copy-ReportValue -Value $full; $full2['CreatedAt'] = '2026-10-20T09:00:00'; $full2['Findings'] = @()
      $same = Compare-ToolReportData -Earlier $full -Current $full2
      @(foreach ($f in $same.FindingsResolved) { $f.Code }) | Should -Contain 'volumeStateSpotFix'
      @(Format-ToolSinceLastVisit -Diff $same) | Should -Not -Contain $script:fullOnlyNote
    }
    It 'I1: the Full-only codes are pinned: a Quick and a Full run of an unhealthy fake PC differ only by $script:ReportFullOnlyCodes' {
      $script:gc['volumeState'] = @{ HealthStatus = 1; OperationalStatus = @(53262); Dirty = $true }
      foreach ($v in @($script:cim['Win32_Volume'])) { if ($v.DriveLetter -eq 'C:') { $v.DirtyBitSet = $true } }
      $codes = @{}
      foreach ($action in 'quickReport', 'fullReport') {
        $run = New-ReportActionRun -Action $action
        $ids = @(foreach ($s in $script:ToolActionCatalog[$action].Steps) { if ([string]$s -match '^report([0-9]{2})\z') { $Matches[1] } })
        foreach ($id in $ids) { $null = Invoke-ToolReportSection -Run $run -Id $id }
        $codes[$action] = @(foreach ($f in (New-ToolReport -Run $run)['Findings']) { if ([string]$f.Code -cne 'notCollected') { [string]$f.Code } }) | Sort-Object -Unique
      }
      $fullOnly = @($codes['fullReport'] | Where-Object { @($codes['quickReport']) -cnotcontains $_ })
      $fullOnly | Should -Contain 'volumeStateSpotFix'   # the unhealthy volume made the Full-only check speak
      @($codes['quickReport']) | Should -Contain 'volumeDirty'   # the dirty bit is read by both
      foreach ($c in $fullOnly) { @($script:ReportFullOnlyCodes) | Should -Contain $c -Because 'every code only a Full report gives is on the list' }
      foreach ($c in @($script:ReportFullOnlyCodes)) { @($codes['quickReport']) | Should -Not -Contain $c -Because "$c is Full-only" }
      @($codes['quickReport'] | Where-Object { @($codes['fullReport']) -cnotcontains $_ }) | Should -BeNullOrEmpty   # nothing is Quick-only
    }
    It 'I2: generic names are never masked (a stop-list, Windows'' own network names, letter-only names as whole words, short numeric serials not at all)' {
      $hebNet2 = (-join ([char[]](0x05E8, 0x05E9, 0x05EA))) + ' 2'
      $m = New-SafeMasker -Known @{ User = @('User', 'Admin', 'Owner', 'TEMP', 'Guest'); Ssid = @('Network', 'Network 2', 'Home', $hebNet2, 'Unidentified network')
                                    Computer = @('OFFICE', 'COHENPC'); Domain = @('HOME', 'contoso', 'WORKGROUP'); Serial = @('1234', '98765', '123456') }
      foreach ($line in '== 09 NETWORK ==', 'Network reset', 'Windows 11 Home', 'Microsoft Office Professional Plus', 'OfficeClickToRun.exe', 'no signed-in user',
                        'User Profile Service', 'Run as Admin', 'Domain Admins', 'Free 1234 MB', 'Free 98765 MB', 'KB1234', 'Known network Network 2 (wired, Private)',
                        'TEMP=%TEMP%', 'C:\Users\User\AppData', 'Connection Network on Ethernet: Private', "net $hebNet2", 'Guest (disabled)', 'Domain = WORKGROUP (workgroup)') {
        Get-Mask $m $line | Should -BeExactly $line -Because $line
      }
      # A letter-only computer or domain name only as a whole word; one with a digit or a separator everywhere; a numeric
      # serial of 6 digits or more only as a whole number.
      Get-Mask $m 'host COHENPC.local, cohenpcx, contoso\dana, contosoltd, serial 123456, 91234567' |
        Should -BeExactly 'host PC-1.local, cohenpcx, DOMAIN-1\dana, contosoltd, serial SERIAL-1, 91234567'
      # Get-ReportIdentifiers leaves them out too: Windows' generic wired names, stop words, a WORKGROUP-like workgroup.
      $rep = @{ Identity = @{ ComputerName = 'DESKTOP-4F7K2LQ'; Serial = '7HX2K93'; Brand = 'DELL' }
                Items = @{ NetworkProfiles = @(@{ Name = 'Network'; Type = 'wired' }, @{ Name = 'Network 2'; Type = 'wired' }, @{ Name = $hebNet2; Type = 'wired' },
                                               @{ Name = 'lan'; Type = 'wired' }, @{ Name = 'Cohen_Home'; Type = 'wireless' }, @{ Name = 'Unidentified network'; Type = 'other' })
                           Ssids = @('Cohen_Home'); Users = @('Owner', 'Dana', 'User'); Workgroup = 'HOME'; BatterySerials = @('1234'); RamSerials = @('80AD0123') } }
      $ids = Get-ReportIdentifiers -Report $rep
      @($ids.Ssid) | Should -Be @('Cohen_Home'); @($ids.User) | Should -Be @('Dana'); @($ids.Domain).Count | Should -Be 0
      @($ids.Serial) | Should -Not -Contain '1234'; @($ids.Serial) | Should -Contain '80AD0123'
    }
    It 'I3: Hebrew names after up to three prefix letters (b h v k l m sh) are masked, user names and network names alike' {
      $m = New-SafeMasker -Known @{ User = @('דנה כהן', 'Dana'); Ssid = @('הבית כהן') }
      Get-Mask $m 'לחזור לדנה כהן מחר' | Should -BeExactly 'לחזור לuser1 מחר'
      Get-Mask $m 'ודנה כהן ביקשה' | Should -BeExactly 'וuser1 ביקשה'
      Get-Mask $m 'וכשדנה כהן התקשרה' | Should -BeExactly 'וכשuser1 התקשרה'
      Get-Mask $m 'של דנה כהן' | Should -BeExactly 'של user1'
      Get-Mask $m 'ברשת בהבית כהן' | Should -BeExactly 'ברשת בSSID-1'
      Get-Mask $m 'אדנה כהן' | Should -BeExactly 'אדנה כהן'   # א is no prefix letter
    }
    It 'I3: SIDs are found by pattern wherever they are, after a letter or a dash, known or not; well-known SIDs stay' {
      $m = New-SafeMasker -Known @{}
      Get-Mask $m 'OneDrive Standalone Update Task-S-1-5-21-444-555-666-1002' | Should -BeExactly 'OneDrive Standalone Update Task-SID-1'
      Get-Mask $m 'GoogleUpdateTaskUserS-1-5-21-444-555-666-1003Core' | Should -BeExactly 'GoogleUpdateTaskUserSID-2_Core'
      Get-Mask $m 'Task-S-1-12-1-11-22-33-44 and HKU\S-1-5-21-444-555-666-1002_Classes' | Should -BeExactly 'Task-SID-3 and HKU\SID-1_Classes'
      Get-Mask $m 'system S-1-5-18 admins S-1-5-32-544' | Should -BeExactly 'system S-1-5-18 admins S-1-5-32-544'
    }
    It 'M1: phone numbers in every common Israeli spelling, the spec''s pinned ones included; dates, versions and codes stay' {
      $m = New-SafeMasker -Known @{}
      foreach ($p in '050-1234567', '0501234567', '050 123 4567', '+972-50-123-4567', '+972501234567', '972-50-1234567', '00972501234567', '050.123.4567',
                     '972501234567', '050-123-45-67', '(050)1234567', '+972 (0)50-1234567', '+972-50-1234567') {
        Get-Mask $m "call $p." | Should -BeExactly 'call PHONE-1.' -Because $p
      }
      Get-Mask $m 'call 054 - 7654321' | Should -BeExactly 'call PHONE-2'
      Get-Mask $m '03-6123456 or +972 3 612 3456 or +972 3 6123456' | Should -BeExactly 'PHONE-3 or PHONE-3 or PHONE-3'
      foreach ($keep in 'on 02.10.2026 1:15', 'build 10.0.26100.1', 'KB5044284', 'code 0x0000009F', 'size 512110190592', 'id 1972501234567', 'at 04/10/2026 09:00') {
        Get-Mask $m $keep | Should -BeExactly $keep -Because $keep
      }
    }
    It 'M2: an unknown profile name in a UNC, forward-slash, JSON-escaped or %SystemDrive% path, or at the end of a line, is a user token' {
      $m = New-SafeMasker -Known @{}
      Get-Mask $m '\\PC7\c$\Users\Yossi\Desktop' | Should -BeExactly '\\PC7\c$\Users\user1\Desktop'
      Get-Mask $m 'C:/Users/Yossi/Desktop and C:\\Users\\Yossi\\Desktop' | Should -BeExactly 'C:/Users/user1/Desktop and C:\\Users\\user1\\Desktop'
      Get-Mask $m '%SystemDrive%\Users\Rina2\x' | Should -BeExactly '%SystemDrive%\Users\user2\x'
      Get-Mask $m "path C:\Users\Moshe Levi`nnext line" | Should -BeExactly "path C:\Users\user3`nnext line"
      Get-Mask $m 'C:/Users/Public/x and C:\Users\Default' | Should -BeExactly 'C:/Users/Public/x and C:\Users\Default'
    }
    It 'M3: an IPv6 address right after a colon, a Cisco-style MAC and a URL-encoded e-mail address are masked; times stay' {
      $m = New-SafeMasker -Known @{ Mac = @('A4-BB-6D-12-34-57') }
      Get-Mask $m 'Address:2a00:1450:4001::8a IPv6:2a00:1450:4001::8d' | Should -BeExactly 'Address:IP6-1 IPv6:IP6-2'
      Get-Mask $m 'at 10:15:45 and 12:34:56:78' | Should -BeExactly 'at 10:15:45 and 12:34:56:78'
      Get-Mask $m 'mac a4bb.6d12.3457, user yossi%40gmail.com' | Should -BeExactly 'mac MAC-1, user EMAIL-1'
    }
    It 'M4: a token a letter or digit follows gets an underscore, so it never reads as another token' {
      $m = New-SafeMasker -Known @{ Serial = @('S4EWNX0R123456'); Computer = @('DESKTOP-4F7K2LQ') }
      Get-Mask $m 'S4EWNX0R1234567 OLD-DESKTOP-4F7K2LQX DESKTOP-4F7K2LQ.local S4EWNX0R123456' | Should -BeExactly 'SERIAL-1_7 OLD-PC-1_X PC-1.local SERIAL-1'
    }
    It 'M5: Compare names a BenTech-Reports that is a link or cannot be listed, and a visit folder it cannot list' {
      $s = New-CompareStick -Name 'CmpStickList'
      $skipped = New-Object System.Collections.Generic.List[string]
      Mock Test-StickReparsePoint { $Path -like '*BenTech-Reports' }
      Find-ToolEarlierReport -StickRoot $s.Root -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $s.Current -Skipped $skipped | Should -BeNullOrEmpty
      @($skipped) | Should -Be @('BenTech-Reports (a link)')
      Mock Test-StickReparsePoint { if ($Path -like '*BenTech-Reports') { throw (New-Object UnauthorizedAccessException 'denied') }; $false }
      $skipped.Clear(); $null = Find-ToolEarlierReport -StickRoot $s.Root -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $s.Current -Skipped $skipped
      @($skipped) | Should -Be @('BenTech-Reports (could not be listed)')
      Mock Test-StickReparsePoint { if ($Path -like '*_2026-10-01_0900') { throw (New-Object UnauthorizedAccessException 'denied') }; $false }
      $skipped.Clear()
      (Find-ToolEarlierReport -StickRoot $s.Root -IdentityKey 'SN-7HX2K93' -CurrentSessionDir $s.Current -Skipped $skipped).CreatedAt | Should -Be '2026-09-01T09:00:00'
      @($skipped) | Should -Be @('DELL-7HX2K93_7HX2K93_2026-10-01_0900 (could not be listed)')
    }
    It 'M6: the crash counts say they cover only the last crashDays when the last visit was longer ago' {
      $note = '  Crashes are counted for the last 60 days only (the last visit was longer ago)'
      $old = Copy-ReportValue -Value $earlier; $old['CreatedAt'] = '2026-07-01T09:00:00'
      @(Format-ToolSinceLastVisit -Diff (Compare-ToolReportData -Earlier $old -Current $now -CrashDays 60)) | Should -Contain $note
      @(Format-ToolSinceLastVisit -Diff (Compare-ToolReportData -Earlier $earlier -Current $now -CrashDays 60)) | Should -Not -Contain $note
    }
    It 'M7: reportWrite writes the core before it reads the stick; with no time left it only writes, and says so' {
      $script:coresAtSearch = -1
      Mock Find-ToolEarlierReport { $script:coresAtSearch = @(Get-ChildItem $script:sessionDir -Filter 'REPORT_DELL-7HX2K93_*.txt').Count; $null }
      $r = New-ReportSampleRun -Sample $script:sample
      Invoke-ToolStepReportWrite -Run $r | Should -Be 'done'
      $script:coresAtSearch | Should -Be 1
      $r2 = New-ReportSampleRun -Sample $script:sample
      Mock Get-ToolRemainingSeconds { 0 }
      Invoke-ToolStepReportWrite -Run $r2 | Should -Be 'done'
      Should -Invoke Find-ToolEarlierReport -Times 1 -Exactly
      [IO.File]::ReadAllText($r2.Files.Report) | Should -Match 'SINCE LAST VISIT\r\n  \(not looked for: the report ran out of time\)'
      Test-Path $r2.Files.Safe | Should -BeTrue; Test-Path $r2.Files.Data | Should -BeTrue
    }
  }
}
