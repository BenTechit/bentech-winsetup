# tests/Process.Tests.ps1
BeforeAll {
  . "$PSScriptRoot\..\src\Common\Logging.ps1"
  . "$PSScriptRoot\..\src\Common\Process.ps1"
  . "$PSScriptRoot\..\src\Common\Download.ps1"

  # Returns the ping.exe processes started by the tree-kill tests. The unique '-n <count>' marks them
  # (a stray ping from anywhere else will not carry it). CommandLine comes from CIM.
  function Get-MarkedPing([string]$Count) {
    @(Get-CimInstance Win32_Process -Filter "Name='ping.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "-n $Count " })
  }
  # Same for the cmd.exe that was started with 'ping -n <count>' on its command line.
  function Get-MarkedCmd([string]$Count) {
    @(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "ping -n $Count " })
  }
}

Describe 'Invoke-External' {
  It 'returns the exit code' { (Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c exit 3').ExitCode | Should -Be 3 }
  It 'runs a file in a path with spaces' {
    $d = Join-Path $TestDrive 'a b'; New-Item -ItemType Directory $d | Out-Null; '@echo hi& exit /b 7' | Set-Content "$d\t t.cmd" -Encoding ASCII
    $r = Invoke-External -FilePath "$d\t t.cmd" -CaptureOutput; $r.ExitCode | Should -Be 7; $r.Output | Should -Match 'hi'
  }
  It 'kills on timeout' { $r = Invoke-External -FilePath 'ping.exe' -ArgumentList '-n 30 127.0.0.1' -TimeoutMinutes 0.03; $r.TimedOut | Should -BeTrue; $r.ExitCode | Should -BeNullOrEmpty }

  It 'reports TimedOut=$false for a normal exit' {
    (Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c exit 0').TimedOut | Should -BeFalse
  }
  It 'returns an int exit code' {
    (Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c exit 5').ExitCode | Should -BeOfType [int]
  }
  It 'returns an empty string as Output when output is not captured' {
    $r = Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c echo visible& exit /b 0'
    ($r.Output -is [string]) | Should -BeTrue
    $r.Output.Length | Should -Be 0
  }
  It 'captures stdout' {
    $r = Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c echo out-line' -CaptureOutput
    $r.Output | Should -Match 'out-line'
  }
  It 'captures stderr, after stdout' {
    $r = Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c echo to-stdout& echo to-stderr 1>&2& exit /b 2' -CaptureOutput
    $r.ExitCode | Should -Be 2
    $r.Output | Should -Match 'to-stdout'
    $r.Output | Should -Match 'to-stderr'
    $r.Output.IndexOf('to-stdout') | Should -BeLessThan $r.Output.IndexOf('to-stderr')
  }
  It 'does not deadlock on large stdout and stderr output' {
    $script = '1..3000 | ForEach-Object { [Console]::Out.WriteLine(''o'' * 80); [Console]::Error.WriteLine(''e'' * 80) }'
    $r = Invoke-External -FilePath 'powershell.exe' -ArgumentList "-NoProfile -NonInteractive -Command `"$script`"" -CaptureOutput -TimeoutMinutes 2
    $r.TimedOut | Should -BeFalse
    $r.ExitCode | Should -Be 0
    $r.Output.Length | Should -BeGreaterThan 400000
  }
  It 'honours WorkingDirectory' {
    $d = Join-Path $TestDrive 'w d'; New-Item -ItemType Directory $d | Out-Null
    $r = Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c cd' -WorkingDirectory $d -CaptureOutput
    $r.Output | Should -Match 'w d'
  }
  It 'passes quoted arguments to a .cmd in a path with spaces' {
    $d = Join-Path $TestDrive 'q q'; New-Item -ItemType Directory $d | Out-Null
    '@echo arg=[%~1]& exit /b 4' | Set-Content "$d\a r.cmd" -Encoding ASCII
    $r = Invoke-External -FilePath "$d\a r.cmd" -ArgumentList '"x y"' -CaptureOutput
    $r.ExitCode | Should -Be 4
    $r.Output | Should -Match 'arg=\[x y\]'
  }
  It 'runs a .bat file' {
    $d = Join-Path $TestDrive 'bat dir'; New-Item -ItemType Directory $d | Out-Null
    '@exit /b 9' | Set-Content "$d\b.bat" -Encoding ASCII
    (Invoke-External -FilePath "$d\b.bat").ExitCode | Should -Be 9
  }
  It 'runs a file whose path contains Hebrew letters and spaces' {
    $d = Join-Path $TestDrive 'בן גולדנברג'; New-Item -ItemType Directory $d | Out-Null
    '@exit /b 6' | Set-Content "$d\run me.cmd" -Encoding ASCII
    (Invoke-External -FilePath "$d\run me.cmd").ExitCode | Should -Be 6
  }
  It 'throws for a missing executable' {
    { Invoke-External -FilePath "$TestDrive\no-such-program.exe" } | Should -Throw
  }
  It 'throws for a missing .cmd file instead of returning the exit code of cmd.exe' {
    { Invoke-External -FilePath "$TestDrive\no-such-script.cmd" } | Should -Throw
  }

  Context 'on timeout' {
    It 'kills the whole process tree, including a ping child of cmd.exe' {
      Get-MarkedPing '47' | Should -BeNullOrEmpty    # nothing stale from an earlier run
      $r = Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c ping -n 47 127.0.0.1' -TimeoutMinutes 0.03
      $r.TimedOut | Should -BeTrue
      $r.ExitCode | Should -BeNullOrEmpty
      # Give Windows a moment to finish tearing the processes down.
      $deadline = (Get-Date).AddSeconds(5)
      while ((Get-MarkedPing '47') -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
      Get-MarkedPing '47' | Should -BeNullOrEmpty
    }
    It 'returns the output captured before the timeout' {
      $r = Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c echo before-the-hang& ping -n 48 127.0.0.1' -CaptureOutput -TimeoutMinutes 0.05
      $r.TimedOut | Should -BeTrue
      $r.ExitCode | Should -BeNullOrEmpty
      $r.Output | Should -Match 'before-the-hang'
    }
    It 'also times out and kills a .cmd and the ping it started' {
      $d = Join-Path $TestDrive 'hang dir'; New-Item -ItemType Directory $d | Out-Null
      '@ping -n 49 127.0.0.1 >nul' | Set-Content "$d\hang.cmd" -Encoding ASCII
      $r = Invoke-External -FilePath "$d\hang.cmd" -TimeoutMinutes 0.03
      $r.TimedOut | Should -BeTrue
      $deadline = (Get-Date).AddSeconds(5)
      while ((Get-MarkedPing '49') -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
      Get-MarkedPing '49' | Should -BeNullOrEmpty
    }
    It 'still kills the root, and logs a WARN, when the process tree cannot be enumerated' {
      # A real WMI failure is a NON-terminating error. If the CIM call were made with
      # -ErrorAction SilentlyContinue it would be swallowed: no WARN, and the children would survive.
      # Pester has no fall-through to the real command, so forward every other call (Get-MarkedPing's).
      Mock Get-CimInstance { & (Get-Command Get-CimInstance -CommandType Cmdlet) @PesterBoundParameters }
      Mock Get-CimInstance { Write-Error 'WMI unavailable' } -ParameterFilter { $Filter -like 'ParentProcessId=*' }
      $d = Join-Path $TestDrive 'enumfail'
      Initialize-SetupLog -LogDirectory $d
      try {
        $r = Invoke-External -FilePath 'ping.exe' -ArgumentList '-n 51 127.0.0.1' -TimeoutMinutes 0.03
      } finally { $script:SetupLogPath = $null }
      $r.TimedOut | Should -BeTrue
      $r.ExitCode | Should -BeNullOrEmpty
      $deadline = (Get-Date).AddSeconds(5)
      while ((Get-MarkedPing '51') -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
      Get-MarkedPing '51' | Should -BeNullOrEmpty    # the root (ping.exe itself) was still killed
      $log = Get-Content "$d\setup.log" -Raw
      $log | Should -Match '\[WARN\] Could not enumerate children of \d+: .*WMI unavailable'
    }
    It 'keeps the partial tree when a child''s own query fails: the root and that child are both killed' {
      # cmd.exe (root) -> ping.exe (child). The root's query returns the real ping; the ping's query fails.
      Mock Get-CimInstance { & (Get-Command Get-CimInstance -CommandType Cmdlet) @PesterBoundParameters }
      Mock Get-CimInstance {
        $real = @(& (Get-Command Get-CimInstance -CommandType Cmdlet) @PesterBoundParameters)
        if ($real.Count -eq 0) { Write-Error 'WMI unavailable for the child'; return }
        $real
      } -ParameterFilter { $Filter -like 'ParentProcessId=*' }
      $d = Join-Path $TestDrive 'partialtree'
      Initialize-SetupLog -LogDirectory $d
      try {
        $r = Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c ping -n 53 127.0.0.1' -TimeoutMinutes 0.03
        $r.TimedOut | Should -BeTrue
        $deadline = (Get-Date).AddSeconds(5)
        while (((Get-MarkedPing '53') -or (Get-MarkedCmd '53')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Get-MarkedCmd '53' | Should -BeNullOrEmpty    # the root
        Get-MarkedPing '53' | Should -BeNullOrEmpty   # the child found by the root's query
      } finally {
        $script:SetupLogPath = $null
        Get-MarkedPing '53' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Get-MarkedCmd '53' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      }
      $log = Get-Content "$d\setup.log" -Raw
      $log | Should -Match '\[WARN\] Could not enumerate children of \d+: .*WMI unavailable for the child'
      # The walk went past the root: at least the root query plus one failing child query (cmd.exe
      # also has a conhost.exe child, so there can be more than two).
      Should -Invoke Get-CimInstance -Times 2 -ParameterFilter { $Filter -like 'ParentProcessId=*' }
    }
    It 'bounds the process-tree CIM query with an operation timeout' {
      Mock Get-CimInstance { } -ParameterFilter { $Filter -like 'ParentProcessId=*' }
      Invoke-External -FilePath 'ping.exe' -ArgumentList '-n 52 127.0.0.1' -TimeoutMinutes 0.02 | Out-Null
      Should -Invoke Get-CimInstance -ParameterFilter { $Filter -like 'ParentProcessId=*' -and $OperationTimeoutSec -eq 10 }
    }
    It 'does not stall when a detached grandchild keeps the output pipe open after the parent exits' {
      # cmd.exe starts a long-lived ping that inherits the redirected handles, then exits at once.
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $r = Invoke-External -FilePath 'cmd.exe' -ArgumentList '/c start "" /b ping -n 50 127.0.0.1 & echo parent-done' -CaptureOutput -TimeoutMinutes 1
      $sw.Stop()
      try {
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'parent-done'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
      } finally {
        Get-MarkedPing '50' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      }
    }
  }

  Context 'logging' {
    It 'logs start and end with the exit code, and never the captured output' {
      $d = Join-Path $TestDrive 'logtest'; New-Item -ItemType Directory $d | Out-Null
      '@echo TOPSECRET123& exit /b 5' | Set-Content "$d\s.cmd" -Encoding ASCII
      Initialize-SetupLog -LogDirectory "$d\logs"
      try {
        $r = Invoke-External -FilePath "$d\s.cmd" -CaptureOutput
        $r.Output | Should -Match 'TOPSECRET123'
      } finally { $script:SetupLogPath = $null }
      $log = Get-Content "$d\logs\setup.log" -Raw
      $log | Should -Match 's\.cmd'
      $log | Should -Match '"exitCode":5'
      $log | Should -Match 'elapsedMs'
      $log | Should -Not -Match 'TOPSECRET123'
    }
    It 'logs a timeout' {
      $d = Join-Path $TestDrive 'logtimeout'; New-Item -ItemType Directory $d | Out-Null
      Initialize-SetupLog -LogDirectory "$d\logs"
      try { Invoke-External -FilePath 'ping.exe' -ArgumentList '-n 31 127.0.0.1' -TimeoutMinutes 0.02 | Out-Null } finally { $script:SetupLogPath = $null }
      $log = Get-Content "$d\logs\setup.log" -Raw
      $log | Should -Match '"timedOut":true'
    }
  }
}

Describe 'Convert-MsiExitCode' {
  It '<c> -> <r>' -ForEach @(@{c=0;r='Done'},@{c=3010;r='DoneReboot'},@{c=1641;r='DoneReboot'},@{c=1618;r='Retry'},@{c=1603;r='Failed'}) { Convert-MsiExitCode -ExitCode $c | Should -Be $r }
  It 'treats a null exit code (a timed-out run) as Failed, never Done' { Convert-MsiExitCode -ExitCode $null | Should -Be 'Failed' }
  It 'treats a negative exit code as Failed' { Convert-MsiExitCode -ExitCode -1073741819 | Should -Be 'Failed' }
}
