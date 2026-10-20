# tests/Common.Tests.ps1
BeforeAll { . "$PSScriptRoot\..\src\Common\StepResult.ps1"; . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Activity.ps1" }
Describe 'New-StepResult' {
  It 'defaults Reboot to None and arrays to empty' {
    $r = New-StepResult -Status Done -Message 'ok'
    $r.Reboot | Should -Be 'None'; @($r.Notes).Count | Should -Be 0; @($r.Errors).Count | Should -Be 0
  }
  It 'carries Reboot, Notes, Errors and Data through' {
    $r = New-StepResult -Status Continue -Reboot Now -Notes 'n1', 'n2' -Errors 'e1' -Data @{ round = 2 }
    $r.Status | Should -Be 'Continue'; $r.Reboot | Should -Be 'Now'
    @($r.Notes).Count | Should -Be 2; @($r.Errors) | Should -Be @('e1'); $r.Data.round | Should -Be 2
  }
  It 'tolerates null Notes and Errors' {
    $r = New-StepResult -Status Done -Notes $null -Errors $null
    @($r.Notes).Count | Should -Be 0; @($r.Errors).Count | Should -Be 0
  }
  It 'rejects an unknown status' { { New-StepResult -Status Maybe } | Should -Throw }
  It 'rejects an unknown reboot value' { { New-StepResult -Status Done -Reboot Later } | Should -Throw }
}
Describe 'Write-SetupLog' {
  It 'appends a timestamped line with level and data' {
    $d = Join-Path $TestDrive 'logs'; Initialize-SetupLog -LogDirectory $d
    Write-SetupLog -Message 'hello' -Level WARN -Data @{ step = 'x' }
    (Get-Content "$d\setup.log" -Raw) | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[WARN\] hello \{"step":"x"\}'
  }
  It 'never throws when the log file is locked; it warns instead' {
    $d = Join-Path $TestDrive 'locked'; Initialize-SetupLog -LogDirectory $d
    $path = "$d\setup.log"
    $lock = [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
      { Write-SetupLog -Message 'x' 3>$null } | Should -Not -Throw
      Write-SetupLog -Message 'y' -WarningVariable w -WarningAction SilentlyContinue
      [string]$w[0].Message | Should -BeLike 'log write failed: *'
    } finally { $lock.Dispose() }
    (Get-Item -LiteralPath $path).Length | Should -Be 0
  }
}
