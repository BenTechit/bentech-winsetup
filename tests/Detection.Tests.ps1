# tests/Detection.Tests.ps1
BeforeAll { . "$PSScriptRoot\..\src\Detect\Detection.ps1"; . "$PSScriptRoot\..\src\Detect\PcName.ps1" }
Describe 'Resolve-Brand' {
  It '<m> / <mo> -> <b>' -ForEach @(
    @{m='Dell Inc.';mo='Latitude 5440';b='DELL'}, @{m='LENOVO';mo='21AH';b='LENOVO'}, @{m='HP';mo='EliteBook';b='HP'},
    @{m='Hewlett-Packard';mo='x';b='HP'}, @{m='ASUSTeK COMPUTER INC.';mo='x';b='ASUS'}, @{m='Acer';mo='x';b='ACER'},
    @{m='Micro-Star International Co., Ltd.';mo='x';b='MSI'}, @{m='Microsoft Corporation';mo='Surface Laptop 7';b='SURFACE'},
    @{m='Microsoft Corporation';mo='Virtual Machine';b='VM'}, @{m='VMware, Inc.';mo='VMware7,1';b='VM'},
    @{m='SAMSUNG ELECTRONICS CO., LTD.';mo='x';b='SAMSUNG'}, @{m='To be filled by O.E.M.';mo='x';b='OTHER'},
    @{m='SHP Systems';mo='x';b='OTHER'}) { Resolve-Brand -Manufacturer $m -Model $mo | Should -Be $b }
}
Describe 'Test-IsLaptop' {
  It 'notebook chassis' { Test-IsLaptop -ChassisTypes @(10) -PCSystemTypeEx 1 -Batteries @() | Should -BeTrue }
  It 'desktop chassis' { Test-IsLaptop -ChassisTypes @(3) -PCSystemTypeEx 1 -Batteries @() | Should -BeFalse }
  It 'mobile system type' { Test-IsLaptop -ChassisTypes @(35) -PCSystemTypeEx 2 -Batteries @() | Should -BeTrue }
  It 'desktop with a UPS is not a laptop' { Test-IsLaptop -ChassisTypes @(3) -PCSystemTypeEx 1 -Batteries @([pscustomobject]@{Name='APC UPS';DeviceID='UPS1'}) | Should -BeFalse }
  It 'unknown chassis with a real battery' { Test-IsLaptop -ChassisTypes @(2) -PCSystemTypeEx 1 -Batteries @([pscustomobject]@{Name='Internal';DeviceID='BAT0'}) | Should -BeTrue }
}
Describe 'Test-FreshInstall' {
  BeforeAll { $script:now = Get-Date '2026-10-18' }
  It 'fresh' { Test-FreshInstall -InstallDate $now.AddDays(-1) -UserDataBytes 10MB -MaxAgeDays 14 -MaxUserDataGB 1 -Now $now | Should -BeTrue }
  It 'old install' { Test-FreshInstall -InstallDate $now.AddDays(-20) -UserDataBytes 0 -MaxAgeDays 14 -MaxUserDataGB 1 -Now $now | Should -BeFalse }
  It 'lots of user data' { Test-FreshInstall -InstallDate $now -UserDataBytes 2GB -MaxAgeDays 14 -MaxUserDataGB 1 -Now $now | Should -BeFalse }
}
Describe 'New-PcName' {
  It 'brand + serial' { New-PcName -Brand DELL -Serial '7HX2K93' -BiosUuid 'x' | Should -Be 'DELL-7HX2K93' }
  It 'keeps the right-most serial chars within 15' { New-PcName -Brand ASUS -Serial 'N8NRCX03X123456' -BiosUuid 'x' | Should -Be 'ASUS-X03X123456' }
  It 'strips invalid chars' { New-PcName -Brand LENOVO -Serial 'pf-3a b7c' -BiosUuid 'x' | Should -Be 'LEN-PF3AB7C' }
  It 'junk serial uses the uuid tail' { New-PcName -Brand OTHER -Serial 'To be filled by O.E.M.' -BiosUuid '4C4C4544-0037-4810-8058-B7C04F4B3933' | Should -Be 'PC-4B3933' }
  It 'VM uses the uuid tail' { New-PcName -Brand VM -Serial '1234-5678' -BiosUuid 'abcdef12-0000-0000-0000-00000a1b2c3d' | Should -Be 'PC-1B2C3D' }
  # Triage 119: placeholder serials that white-box boards ship with must not become a shared PC name.
  It 'treats the placeholder serial <Serial> as junk' -ForEach @(
    @{ Serial = 'Not Applicable' }, @{ Serial = 'Not Specified' }, @{ Serial = 'Unknown' }, @{ Serial = 'Serial Number' }
    @{ Serial = 'Chassis Serial Number' }, @{ Serial = '0123456789' }, @{ Serial = '123456789' }, @{ Serial = 'not-applicable' }
    @{ Serial = ' UNKNOWN ' }, @{ Serial = 'System Serial Number' }, @{ Serial = 'Default string' }, @{ Serial = 'N/A' }
    @{ Serial = '0123-4567-89' }, @{ Serial = 'serial number' }
  ) {
    New-PcName -Brand ASUS -Serial $Serial -BiosUuid '4C4C4544-0037-4810-8058-B7C04F4B3933' | Should -Be 'PC-4B3933'
  }
  It 'treats an all-same-character serial as junk: <Serial>' -ForEach @(
    @{ Serial = '1111111111' }, @{ Serial = 'XXXXXXXX' }, @{ Serial = 'FFFF-FFFF' }, @{ Serial = '9' }
  ) {
    New-PcName -Brand DELL -Serial $Serial -BiosUuid '4C4C4544-0037-4810-8058-B7C04F4B3933' | Should -Be 'PC-4B3933'
  }
  It 'keeps a real serial that merely contains a placeholder-like part' {
    New-PcName -Brand LENOVO -Serial 'PF123456789' -BiosUuid 'x' | Should -Be 'LEN-PF123456789'
    New-PcName -Brand HP -Serial '5CD0123456789A' -BiosUuid 'x' | Should -Be 'HP-D0123456789A'
    New-PcName -Brand DELL -Serial '11111112' -BiosUuid 'x' | Should -Be 'DELL-11111112'
  }
  It 'uses random hex, not the shared tail, for the AMI default UUID and all-same-character UUIDs: <Uuid>' -ForEach @(
    @{ Uuid = '03000200-0400-0500-0006-000700080009' }
    @{ Uuid = '03000200-0400-0500-0006-000700080009'.ToLowerInvariant() }
    @{ Uuid = '11111111-1111-1111-1111-111111111111' }
    @{ Uuid = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' }
    @{ Uuid = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF' }
    @{ Uuid = '00000000-0000-0000-0000-000000000000' }
  ) {
    $names = @(1..5 | ForEach-Object { New-PcName -Brand OTHER -Serial 'To be filled by O.E.M.' -BiosUuid $Uuid })
    foreach ($n in $names) { $n | Should -Match '^PC-[0-9A-F]{6}$'; $n | Should -Not -Be 'PC-080009' }
    @($names | Sort-Object -Unique).Count | Should -BeGreaterThan 1     # random each time, so two such PCs differ
  }
}
# Repair spec 6.8, section 13 call 22: "the same PC" is its serial, or its BIOS UUID when the serial is a placeholder,
# by exactly New-PcName's placeholder rule (Test-PlaceholderSerial).
Describe 'Get-MachineIdentity (repair spec 6.8)' {
  It 'Get-MachineIdentity: <Why>' -ForEach @(
    @{ Why = 'a real serial'; Serial = '7HX2K93'; Uuid = '4C4C4544-0037-4810-8058-B7C04F4B3933'; Key = 'SN-7HX2K93'; Folder = '7HX2K93' }
    @{ Why = 'a real serial with spaces, dashes and lower case'; Serial = ' pf-3a b7c '; Uuid = ''; Key = 'SN-PF3AB7C'; Folder = 'PF3AB7C' }
    @{ Why = 'a placeholder serial with a usable UUID'; Serial = 'To Be Filled By O.E.M.'; Uuid = '4C4C4544-0037-4810-8058-B7C04F4B3933'
       Key = 'UUID-4C4C4544003748108058B7C04F4B3933'; Folder = 'UUID-B7C04F4B3933' }
    @{ Why = 'a placeholder serial with a UUID in braces and lower case'; Serial = 'System Serial Number'; Uuid = '{4c4c4544-0037-4810-8058-b7c04f4b3933}'
       Key = 'UUID-4C4C4544003748108058B7C04F4B3933'; Folder = 'UUID-B7C04F4B3933' }
    @{ Why = 'a placeholder serial and the AMI default UUID'; Serial = 'Default string'; Uuid = '03000200-0400-0500-0006-000700080009'; Key = ''; Folder = 'NOSERIAL' }
    @{ Why = 'a placeholder serial and an all-F UUID'; Serial = '0123456789'; Uuid = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'; Key = ''; Folder = 'NOSERIAL' }
    @{ Why = 'no serial and no UUID'; Serial = $null; Uuid = $null; Key = ''; Folder = 'NOSERIAL' }
  ) {
    $id = Get-MachineIdentity -Machine @{ Serial = $Serial; BiosUuid = $Uuid; Brand = 'OTHER' }
    $id.Key | Should -BeExactly $Key
    $id.FolderPart | Should -BeExactly $Folder
    $id.Serial | Should -BeExactly ("$Serial".Trim())
    $id.BiosUuid | Should -BeExactly ("$Uuid".Trim())
  }
  It 'two whiteboxes with the same placeholder serial and different UUIDs get different keys' {
    $a = Get-MachineIdentity -Machine @{ Serial = 'To Be Filled By O.E.M.'; BiosUuid = '4C4C4544-0037-4810-8058-B7C04F4B3933' }
    $b = Get-MachineIdentity -Machine @{ Serial = 'To Be Filled By O.E.M.'; BiosUuid = '4C4C4544-0037-4810-8058-B7C04F4B3934' }
    $a.Key | Should -Not -BeNullOrEmpty; $b.Key | Should -Not -BeNullOrEmpty
    $a.Key | Should -Not -Be $b.Key
  }
  It 'keeps the right-most 20 characters of a long serial for the folder, the whole serial for the key' {
    $id = Get-MachineIdentity -Machine @{ Serial = 'ABCDEFGHIJ1234567890XYZ'; BiosUuid = '' }
    $id.Key | Should -BeExactly 'SN-ABCDEFGHIJ1234567890XYZ'; $id.FolderPart | Should -BeExactly 'DEFGHIJ1234567890XYZ'
  }
  It 'Test-PlaceholderSerial is New-PcName''s junk rule: <Serial> is <E>' -ForEach @(
    @{ Serial = 'To be filled by O.E.M.'; E = $true }, @{ Serial = 'Default string'; E = $true }, @{ Serial = 'N/A'; E = $true }
    @{ Serial = 'XXXXXXXX'; E = $true }, @{ Serial = ''; E = $true }, @{ Serial = $null; E = $true }, @{ Serial = '0123-4567-89'; E = $true }
    @{ Serial = '7HX2K93'; E = $false }, @{ Serial = 'PF123456789'; E = $false }, @{ Serial = '11111112'; E = $false }) {
    Test-PlaceholderSerial -Serial $Serial | Should -Be $E
    # The PC name agrees: a placeholder gets PC-<uuid tail>, a real serial keeps its brand code.
    (New-PcName -Brand DELL -Serial $Serial -BiosUuid '4C4C4544-0037-4810-8058-B7C04F4B3933') -eq 'PC-4B3933' | Should -Be $E
  }
  It 'Test-UsableBiosUuid: <Uuid> is <E>' -ForEach @(
    @{ Uuid = '4C4C4544-0037-4810-8058-B7C04F4B3933'; E = $true }, @{ Uuid = '{4c4c4544-0037-4810-8058-b7c04f4b3933}'; E = $true }
    @{ Uuid = '03000200-0400-0500-0006-000700080009'; E = $false }, @{ Uuid = '00000000-0000-0000-0000-000000000000'; E = $false }
    @{ Uuid = '4C4C4544-0037-4810-8058'; E = $false }, @{ Uuid = '4C4C4544-0037-4810-8058-B7C04F4B393G'; E = $false }
    @{ Uuid = ''; E = $false }, @{ Uuid = $null; E = $false }) {
    Test-UsableBiosUuid -BiosUuid $Uuid | Should -Be $E
  }
}
Describe 'Test-AdminProtection (toolbox spec 5.3)' {
  It '<Why> is <E>' -ForEach @(
    @{ Why = 'the same account';                 P = 'PC1\Dana'; S = 'pc1\dana';  E = 'Off' }
    @{ Why = 'a hidden admin account';           P = 'PC1\ADMIN_Dana'; S = 'PC1\Dana'; E = 'On' }
    @{ Why = 'no signed-in user (RDP, early logon)'; P = 'PC1\Dana'; S = '';      E = 'Unknown' }
  ) { $script:pu = $P; $script:su = $S; Mock Get-ProcessUserName { $script:pu }; Mock Get-SignedInUserName { $script:su }; Test-AdminProtection | Should -BeExactly $E }
  It 'a CIM failure is Unknown, never a throw' { Mock Get-ProcessUserName { 'PC1\Dana' }; Mock Get-SignedInUserName { throw 'RPC unavailable' }; Test-AdminProtection | Should -BeExactly 'Unknown' }
  It 'reads the signed-in user with a 10-second CIM limit, so a wedged WMI cannot hang the window (review M5)' {
    Mock Get-CimInstance { [pscustomobject]@{ UserName = 'PC1\Dana' } }
    Get-SignedInUserName | Should -BeExactly 'PC1\Dana'
    Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' -and $OperationTimeoutSec -eq 10 } }
  It 'a CIM read that times out is Unknown (review M5)' {
    Mock Get-ProcessUserName { 'PC1\Dana' }
    Mock Get-CimInstance { Write-Error -Message 'The operation did not complete within the time allotted' -Category OperationTimeout }
    Test-AdminProtection | Should -BeExactly 'Unknown' }
}
