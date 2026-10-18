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
}
