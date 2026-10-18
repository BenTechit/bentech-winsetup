# tests/TestRunner.Tests.ps1
# Every task gates on the runner's last line being "Failed: 0". These tests run tools\Invoke-Tests.ps1 in a
# child process (it calls Invoke-Pester itself) and pin that a test run which cannot load is never green.
BeforeDiscovery {
  $script:brokenCases = @(
    @{ Name = 'a parse error'; Body = "Describe 'x' {`r`n  It 'y' {`r`n" }
    @{ Name = 'a throwing BeforeDiscovery'; Body = "BeforeDiscovery { throw 'boom' }`r`nDescribe 'x' { It 'y' { 1 | Should -Be 1 } }`r`n" }
  )
}
BeforeAll {
  $script:runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Invoke-Tests.ps1'
  function New-TestFile {
    param([string]$Body)
    $file = Join-Path $TestDrive 'sample.Tests.ps1'
    Set-Content -LiteralPath $file -Value $Body -Encoding UTF8
    $file
  }
  function Invoke-Runner {
    param([string]$Path)
    $ErrorActionPreference = 'Continue'   # native stderr must not become a terminating error
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script:runner -Path $Path 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Last = "$($out[-1])".Trim() }
  }
}
Describe 'Invoke-Tests.ps1 exit contract' {
  It 'is not green when the test file has <Name>' -ForEach $script:brokenCases {
    $run = Invoke-Runner -Path (New-TestFile -Body $Body)
    $run.ExitCode | Should -Not -Be 0
    $run.Last | Should -Match '^Failed: [1-9]\d*$'
  }
  It 'is not green when Pester finds no tests at the path' {
    $run = Invoke-Runner -Path (Join-Path $TestDrive 'does-not-exist.Tests.ps1')
    $run.ExitCode | Should -Not -Be 0
    $run.Last | Should -Match '^Failed: [1-9]\d*$'
  }
  It 'is green (Failed: 0, exit 0) for a passing test file' {
    $run = Invoke-Runner -Path (New-TestFile -Body "Describe 'x' { It 'y' { 1 | Should -Be 1 } }`r`n")
    $run.ExitCode | Should -Be 0
    $run.Last | Should -Be 'Failed: 0'
  }
}
