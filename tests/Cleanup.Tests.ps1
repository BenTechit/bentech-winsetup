# tests/Cleanup.Tests.ps1
# v2 Task 15 (spec 10): no leftover folder. The logs go to the USB stick, the Desktop launcher and
# C:\BenTech are deleted when the technician finishes the final screen.
#
# SAFETY: nothing outside $TestDrive is ever deleted. Invoke-SetupCleanup runs only with Remove-SetupFolder,
# Remove-Item and Set-Location mocked. The only real deletion is the one `rd` test (plus `mklink /J`), on a
# folder named BenTech inside $TestDrive whose junction target is also inside $TestDrive. Every refusal test
# mocks Invoke-External to throw.
BeforeAll {
  foreach ($f in 'Common\Logging', 'Common\Activity', 'Common\Process', 'Entry\Cleanup') { . "$PSScriptRoot\..\src\$f.ps1" }
  function New-Disk($id, $serial, $type = 2) { [pscustomobject]@{ DeviceID = $id; VolumeSerialNumber = $serial; DriveType = $type } }
}
Describe 'Get-LauncherInfo' {
  It 'records the path, its drive and that drive''s volume serial' {
    Mock Get-CimInstance { New-Disk 'E:' '1A2B3C4D' } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
    $i = Get-LauncherInfo -Path 'E:\BenTechSetup.cmd'; $i.Drive | Should -Be 'E:'; $i.VolumeSerial | Should -Be '1A2B3C4D'
    $i.Path | Should -Be 'E:\BenTechSetup.cmd'
    Should -Invoke Get-CimInstance -ParameterFilter { $Filter -eq "DeviceID='E:'" -and $OperationTimeoutSec -eq 10 }
  }
  It 'is $null without BT_SELF; no serial for a UNC path or a failed query' {
    Get-LauncherInfo -Path '' | Should -BeNullOrEmpty
    Get-LauncherInfo -Path $null | Should -BeNullOrEmpty
    $unc = Get-LauncherInfo -Path '\\server\share\BenTechSetup.cmd'; $unc.VolumeSerial | Should -BeNullOrEmpty; $unc.Drive | Should -BeNullOrEmpty
    Mock Get-CimInstance { throw 'WMI down' }; (Get-LauncherInfo -Path 'E:\BenTechSetup.cmd').VolumeSerial | Should -BeNullOrEmpty
  }
}
Describe 'Find-SetupStick (Review Focus 1)' {
  BeforeEach { Mock Get-CimInstance { New-Disk 'C:' 'AAAA0001' 3; New-Disk 'F:' '1A2B3C4D'; New-Disk 'G:' 'BBBB0002' } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }; Mock Test-Path { $false } }
  It 'finds the stick by its serial, also under another letter' { (Find-SetupStick -Launcher @{ Drive = 'E:'; VolumeSerial = '1a2b3c4d' } -SystemDrive 'C:').Drive | Should -Be 'F:' }
  It 'falls back to a drive holding BenTechSetup.cmd, never the system drive' {
    Mock Test-Path { $LiteralPath -in 'C:\BenTechSetup.cmd', 'G:\BenTechSetup.cmd' }
    $s = Find-SetupStick -Launcher @{ VolumeSerial = 'FFFF0000' } -SystemDrive 'C:'; $s.Drive | Should -Be 'G:'; $s.Root | Should -Be 'G:\'
  }
  It 'none when nothing matches, the record is missing or the query fails' {
    (Find-SetupStick -Launcher $null -SystemDrive 'C:').Root | Should -BeNullOrEmpty
    # Filtered like the BeforeEach mock: Pester 5 prefers a filtered mock over a later unfiltered one.
    Mock Get-CimInstance { throw 'WMI down' } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
    (Find-SetupStick -Launcher @{ VolumeSerial = '1A2B3C4D' } -SystemDrive 'C:').Root | Should -BeNullOrEmpty
  }
  It 'logs a failed query once, not at every call (the final screen asks every second)' {
    $script:SetupStickQueryWarned = $false; Mock Write-SetupLog { }
    Mock Get-CimInstance { throw 'WMI down' } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
    1..3 | ForEach-Object { (Find-SetupStick -Launcher $null -SystemDrive 'C:').Root | Should -BeNullOrEmpty }
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Data.error -eq 'WMI down' }
  }
  It 'never picks the system drive by its serial (a launcher run from the Desktop recorded C:)' {
    $s = Find-SetupStick -Launcher @{ Path = 'C:\Users\ben\Desktop\BenTechSetup.cmd'; Drive = 'C:'; VolumeSerial = 'AAAA0001' } -SystemDrive 'c:'
    $s.Root | Should -BeNullOrEmpty
  }
  It 'never looks at a network drive (an unreachable share would freeze the screen)' {
    Mock Get-CimInstance { New-Disk 'C:' 'AAAA0001' 3; New-Disk 'N:' '1A2B3C4D' 4 } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
    Mock Test-Path { $true }
    (Find-SetupStick -Launcher @{ VolumeSerial = '1A2B3C4D' } -SystemDrive 'C:').Root | Should -BeNullOrEmpty
    Should -Invoke Test-Path -Times 0 -Exactly
  }
  It 'the live line says where the logs go' {
    Format-StickLine -Stick @{ Root = 'E:\'; Drive = 'E:' } | Should -Be '  USB stick found (E:) - logs will be saved there'
    Format-StickLine -Stick @{ Root = $null } | Should -Be '  No BenTech USB stick - plug it in now to keep the logs'
  }
}
Describe 'Copy-SetupLogsToStick' {
  It 'replaces BenTech-Logs\(PC name) on the stick with the Logs folder' {   # no angle brackets: Pester reads <x> in a name as a template
    $logs = "$TestDrive\Logs"; [void][IO.Directory]::CreateDirectory($logs); 'r' | Set-Content "$logs\Setup-Report.txt"
    $old = "$TestDrive\stick\BenTech-Logs\DELL-J0C7QK4"; [void][IO.Directory]::CreateDirectory($old); 'old' | Set-Content "$old\stale.txt"
    (Copy-SetupLogsToStick -LogDir $logs -StickRoot "$TestDrive\stick\" -PcName 'DELL-J0C7QK4').Ok | Should -BeTrue
    "$old\Setup-Report.txt" | Should -Exist; "$old\stale.txt" | Should -Not -Exist
  }
  It 'creates BenTech-Logs on a stick that has none' {
    $logs = "$TestDrive\Logs2"; [void][IO.Directory]::CreateDirectory($logs); 'r' | Set-Content "$logs\setup.log"
    $r = Copy-SetupLogsToStick -LogDir $logs -StickRoot "$TestDrive\fresh\" -PcName 'PC1'
    $r.Ok | Should -BeTrue; $r.Target | Should -Be "$TestDrive\fresh\BenTech-Logs\PC1"; "$TestDrive\fresh\BenTech-Logs\PC1\setup.log" | Should -Exist
  }
  It 'a failed copy is reported, never thrown' {
    Mock Copy-Item { Write-Error 'The device is not ready' }
    $r = Copy-SetupLogsToStick -LogDir "$TestDrive\Logs" -StickRoot "$TestDrive\s2\" -PcName 'PC'; $r.Ok | Should -BeFalse; $r.Error | Should -Match 'not ready'
  }
  It 'turns invalid characters into _ and an empty or dots-only name into UNKNOWN-PC (never the BenTech-Logs folder itself)' {
    Mock Copy-Item { }; Mock Remove-Item { }
    $s = "$TestDrive\s3\"
    (Copy-SetupLogsToStick -LogDir "$TestDrive\Logs" -StickRoot $s -PcName 'A:B*C').Target | Should -Be "$($s)BenTech-Logs\A_B_C"
    foreach ($name in '', '..', ' . ') { (Copy-SetupLogsToStick -LogDir "$TestDrive\Logs" -StickRoot $s -PcName $name).Target | Should -Be "$($s)BenTech-Logs\UNKNOWN-PC" }
    Should -Invoke Remove-Item -Times 0 -Exactly
    Get-StickLogTarget -StickRoot 'E:\' -PcName 'DELL-J0C7QK4' | Should -Be 'E:\BenTech-Logs\DELL-J0C7QK4'   # pure, no file access
  }
}
Describe 'Remove-SetupFolder (Review Focus 2)' {
  It 'refuses anything that is not a folder named BenTech' {
    Mock Invoke-External { throw 'must not run' }; Mock Write-SetupLog { }
    foreach ($p in 'C:\', 'C:\Windows', $TestDrive, "$TestDrive\BenTechX") { Remove-SetupFolder -Path $p | Should -BeFalse }
    Should -Invoke Invoke-External -Times 0 -Exactly
    Should -Invoke Write-SetupLog -Times 4 -Exactly -ParameterFilter { $Level -eq 'ERROR' }
  }
  It 'refuses a BenTech that is a junction (reparse point), and its target stays' {
    Mock Invoke-External { throw 'must not run' }; Mock Write-SetupLog { }
    $b = "$TestDrive\j1"; [void][IO.Directory]::CreateDirectory("$b\elsewhere"); 'keep' | Set-Content "$b\elsewhere\keep.txt"
    & "$env:SystemRoot\System32\cmd.exe" /d /c mklink /J "$b\BenTech" "$b\elsewhere" | Out-Null
    try {
      Remove-SetupFolder -Path "$b\BenTech" | Should -BeFalse
      Remove-SetupFolder -Path "$b\BenTech\" | Should -BeFalse
      Should -Invoke Invoke-External -Times 0 -Exactly
      Should -Invoke Write-SetupLog -Times 2 -Exactly -ParameterFilter { $Level -eq 'ERROR' }
      "$b\elsewhere\keep.txt" | Should -Exist
    } finally {
      [IO.Directory]::Delete("$b\BenTech")   # removes the junction only (no recursion), so TestDrive cleanup never walks it
    }
  }
  It 'refuses a path that cannot be resolved, and a file named BenTech' {
    Mock Invoke-External { throw 'must not run' }; Mock Write-SetupLog { }
    'x' | Set-Content "$TestDrive\BenTech"
    Remove-SetupFolder -Path "$TestDrive\BenTech" | Should -BeFalse
    Remove-SetupFolder -Path "C:\bad|name\BenTech" | Should -BeFalse
    Should -Invoke Invoke-External -Times 0 -Exactly
    "$TestDrive\BenTech" | Should -Exist
  }
  It 'a BenTech folder that is already gone is $true, with nothing run' {
    Mock Invoke-External { throw 'must not run' }
    Remove-SetupFolder -Path "$TestDrive\gone\BenTech" | Should -BeTrue
  }
  It 'runs rd /s /q through Invoke-External and retries 3 times, 2 s apart' {
    $t = "$TestDrive\r1\BenTech"; [void][IO.Directory]::CreateDirectory($t)
    Mock Invoke-External { @{ ExitCode = 0; TimedOut = $false; Output = '' } }; Mock Wait-SetupDelay { }
    Remove-SetupFolder -Path $t | Should -BeFalse
    Should -Invoke Invoke-External -Times 4 -Exactly -ParameterFilter { $FilePath -like '*\System32\cmd.exe' -and $ArgumentList -eq ('/d /c rd /s /q "{0}"' -f $t) -and $TimeoutMinutes -eq 5 }
    Should -Invoke Wait-SetupDelay -Times 3 -Exactly -ParameterFilter { $Seconds -eq 2 }
  }
  It 'stops retrying once the folder is gone, and a try that throws counts as failed' {
    $script:t3 = "$TestDrive\r3\BenTech"; [void][IO.Directory]::CreateDirectory($t3); $script:tries = 0
    Mock Invoke-External { $script:tries++; if ($script:tries -eq 1) { throw 'cannot start cmd' }; [IO.Directory]::Delete($script:t3); @{ ExitCode = 2; TimedOut = $false; Output = '' } }
    Mock Wait-SetupDelay { }
    Remove-SetupFolder -Path $t3 | Should -BeTrue
    Should -Invoke Invoke-External -Times 2 -Exactly; Should -Invoke Wait-SetupDelay -Times 1 -Exactly
  }
  It 'rd removes a junction inside without touching its target (real rd, inside $TestDrive only)' {
    $b = "$TestDrive\r2"; [void][IO.Directory]::CreateDirectory("$b\target"); 'keep' | Set-Content "$b\target\keep.txt"; [void][IO.Directory]::CreateDirectory("$b\BenTech\Setup")
    & "$env:SystemRoot\System32\cmd.exe" /d /c mklink /J "$b\BenTech\Setup\link" "$b\target" | Out-Null
    Remove-SetupFolder -Path "$b\BenTech" | Should -BeTrue
    "$b\BenTech" | Should -Not -Exist; "$b\target\keep.txt" | Should -Exist
  }
}
Describe 'Test-DesktopLauncher' {
  It 'is true only for the user''s or the public Desktop itself' {
    $d = @{ UserDesktop = 'C:\Users\ben\Desktop'; PublicDesktop = 'C:\Users\Public\Desktop' }
    Test-DesktopLauncher -Path 'C:\Users\ben\Desktop\BenTechSetup.cmd' @d | Should -BeTrue
    Test-DesktopLauncher -Path 'c:\users\public\desktop\BenTechSetup.cmd' @d | Should -BeTrue
    Test-DesktopLauncher -Path 'E:\BenTechSetup.cmd' @d | Should -BeFalse
    Test-DesktopLauncher -Path 'C:\Users\ben\Desktop\tools\BenTechSetup.cmd' @d | Should -BeFalse
  }
  It 'ignores a trailing backslash on the Desktop, and is false for no path' {
    Test-DesktopLauncher -Path 'C:\Users\ben\Desktop\BenTechSetup.cmd' -UserDesktop 'C:\Users\ben\Desktop\' -PublicDesktop 'C:\Users\Public\Desktop' | Should -BeTrue
    Test-DesktopLauncher -Path '' -UserDesktop 'C:\Users\ben\Desktop' -PublicDesktop 'C:\Users\Public\Desktop' | Should -BeFalse
    Test-DesktopLauncher -Path 'C:\Users\ben\Desktop\BenTechSetup.cmd' -UserDesktop '' -PublicDesktop '' | Should -BeFalse
  }
}
Describe 'Invoke-SetupCleanup' {
  # Step 4 moves the process's .NET current directory out of the folder; put it back for the tests after these.
  BeforeAll { $script:savedCwd = [Environment]::CurrentDirectory }
  AfterAll { [Environment]::CurrentDirectory = $script:savedCwd }
  BeforeEach {
    $script:order = New-Object System.Collections.ArrayList; $script:lines = New-Object System.Collections.ArrayList; $script:SetupLogPath = "$TestDrive\x.log"
    $script:SetupActivityPath = "$TestDrive\activity.txt"
    Mock Write-SetupLog { }; Mock Find-SetupStick { @{ Root = 'E:\'; Drive = 'E:' } }
    Mock Copy-SetupLogsToStick { [void]$script:order.Add("copy $PcName logging=$([bool]$script:SetupLogPath)"); @{ Ok = $true; Target = 'E:\BenTech-Logs\DELL-J0C7QK4' } }
    Mock Test-DesktopLauncher { $true }; Mock Remove-Item { [void]$script:order.Add("del $LiteralPath") }; Mock Set-Location { }
    Mock Remove-SetupFolder { [void]$script:order.Add("rd $Path"); $true }
    $script:st = @{ Machine = @{ NewName = 'DELL-J0C7QK4' }; Launcher = @{ Path = 'C:\Users\ben\Desktop\BenTechSetup.cmd'; VolumeSerial = '1A2B3C4D' } }
    $script:run = @{ Root = 'C:\BenTech\Setup'; State = $st; Write = { param($t) [void]$script:lines.Add($t) }; ProgramDataFolder = "$TestDrive\pd" }
  }
  It 'Finish: stops logging, copies the logs, deletes the Desktop launcher, then removes C:\BenTech' {
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { throw 'no key expected' }
    @($order) | Should -Be @('copy DELL-J0C7QK4 logging=False', 'del C:\Users\ben\Desktop\BenTechSetup.cmd', 'rd C:\BenTech')
    Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Cleanup: saving the logs and removing C:\BenTech' -and $Data.mode -eq 'Finish' }
    $script:SetupActivityPath | Should -BeNullOrEmpty
    Should -Invoke Find-SetupStick -Times 1 -Exactly -ParameterFilter { $Launcher.VolumeSerial -eq '1A2B3C4D' }
    Should -Invoke Copy-SetupLogsToStick -Times 1 -Exactly -ParameterFilter { $LogDir -eq 'C:\BenTech\Setup\Logs' -and $StickRoot -eq 'E:\' }
    Should -Invoke Set-Location -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $env:SystemRoot }
    $lines | Should -Contain 'Saving the logs to E:\BenTech-Logs\DELL-J0C7QK4 ...'
  }
  It 'a failed copy is shown, and only Enter goes on to the deletion' {
    Mock Copy-SetupLogsToStick { @{ Ok = $false; Error = 'disk full' } }; $script:keys = New-Object Collections.Queue; 'X', 'Enter' | ForEach-Object { $script:keys.Enqueue($_) }
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { $script:keys.Dequeue() }
    $lines | Should -Contain 'Logs could not be saved to the USB stick: disk full'; $script:keys.Count | Should -Be 0; $order | Should -Contain 'rd C:\BenTech'
    $lines | Should -Contain 'Press ENTER to delete C:\BenTech anyway'
  }
  It 'no stick: says so and deletes without waiting' {
    Mock Find-SetupStick { @{ Root = $null } }; Invoke-SetupCleanup @run -Mode Finish -ReadKey { throw 'no key expected' }
    $lines | Should -Contain 'No USB stick found: the logs are not saved'; Should -Invoke Copy-SetupLogsToStick -Times 0 -Exactly
    $order | Should -Contain 'rd C:\BenTech'
  }
  It 'falls back to the computer name when the state has no new name' {
    $st.Machine = @{ NewName = ''; ComputerName = 'DESKTOP-OLD' }
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { throw 'no key expected' }
    $order[0] | Should -Be 'copy DESKTOP-OLD logging=False'
  }
  It 'a launcher anywhere but the Desktop is never touched' {
    Mock Test-DesktopLauncher { $false }; $st.Launcher.Path = 'E:\BenTechSetup.cmd'
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { throw 'no key expected' }
    @($order) | Should -Be @('copy DELL-J0C7QK4 logging=False', 'rd C:\BenTech')
    Should -Invoke Test-DesktopLauncher -Times 1 -Exactly -ParameterFilter { $Path -eq 'E:\BenTechSetup.cmd' }
  }
  It 'a Desktop launcher that cannot be deleted is a line, and the folder still goes' {
    Mock Remove-Item { Write-Error 'Access is denied' }
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { throw 'no key expected' }
    @($lines | Where-Object { $_ -like 'Could not delete the launcher on the Desktop:*Access is denied*' }).Count | Should -Be 1
    $order | Should -Contain 'rd C:\BenTech'
  }
  It 'a deletion that fails says so and waits for a key' {
    Mock Remove-SetupFolder { $false }; $script:keys = New-Object Collections.Queue; $script:keys.Enqueue('Q')
    Invoke-SetupCleanup @run -Mode Finish -ReadKey { $script:keys.Dequeue() }
    $lines | Should -Contain 'Could not delete C:\BenTech - delete it by hand'; $script:keys.Count | Should -Be 0
  }
  It 'Cancel only removes C:\BenTech: no copy, the launcher stays' {
    Invoke-SetupCleanup @run -Mode Cancel -ReadKey { throw 'no key' }; @($order) | Should -Be @('rd C:\BenTech')
    Should -Invoke Find-SetupStick -Times 0 -Exactly; Should -Invoke Test-DesktopLauncher -Times 0 -Exactly
    $script:SetupLogPath | Should -BeNullOrEmpty
  }
  It 'Cancel without a state' {
    Invoke-SetupCleanup -Root 'C:\BenTech\Setup' -Mode Cancel -Write $run.Write -ProgramDataFolder $run.ProgramDataFolder -ReadKey { throw 'no key' }
    @($order) | Should -Be @('rd C:\BenTech')
  }
  It 'removes an empty ProgramData\BenTech and keeps one that has files' {
    [void][IO.Directory]::CreateDirectory("$TestDrive\pd"); Invoke-SetupCleanup @run -Mode Cancel -ReadKey { }; "$TestDrive\pd" | Should -Not -Exist
    [void][IO.Directory]::CreateDirectory("$TestDrive\pd"); 'x' | Set-Content "$TestDrive\pd\f.txt"; Invoke-SetupCleanup @run -Mode Cancel -ReadKey { }; "$TestDrive\pd\f.txt" | Should -Exist
  }
  It 'never throws, even when the key read fails' {
    Mock Remove-SetupFolder { $false }
    { Invoke-SetupCleanup @run -Mode Finish -ReadKey { throw 'no console' } } | Should -Not -Throw
  }
}
