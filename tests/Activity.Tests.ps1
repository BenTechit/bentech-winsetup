BeforeAll {
  . "$PSScriptRoot\..\src\Common\Logging.ps1"; . "$PSScriptRoot\..\src\Common\Activity.ps1"
  $script:Hebrew = -join [char[]](0x05E2, 0x05D3, 0x05DB, 0x05D5, 0x05DF)
  function New-LogDir { $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($d); $d }
}
Describe 'activity feed' {
  BeforeEach {
    $script:dir = New-LogDir; $script:logged = New-Object System.Collections.ArrayList
    Mock Write-SetupLog { [void]$script:logged.Add($Message) }
    Initialize-SetupActivity -LogDirectory $dir
  }
  It 'appends "yyyy-MM-dd HH:mm:ss, TAB, text" as UTF-8 without a BOM and logs it once' {
    Add-SetupActivity -Text 'Google Chrome 141.0 installed'
    ([IO.File]::ReadAllBytes("$dir\activity.txt"))[0] | Should -Not -Be 0xEF
    [IO.File]::ReadAllText("$dir\activity.txt") | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\tGoogle Chrome 141\.0 installed\r\n$'
    @($logged | Where-Object { $_ -eq 'Activity: Google Chrome 141.0 installed' }).Count | Should -Be 1
  }
  It 'keeps the AnyDesk ID out of setup.log' {
    Add-SetupActivity -Text 'AnyDesk 9.0 - ID 123456789' -LogText 'AnyDesk 9.0 - ID recorded'
    [IO.File]::ReadAllText("$dir\activity.txt") | Should -Match '123456789'
    (Get-SetupActivityLines -Count 1)[0].Text | Should -Be 'AnyDesk 9.0 - ID 123456789'
    @($logged | Where-Object { $_ -match '123456789' }).Count | Should -Be 0
    $logged | Should -Contain 'Activity: AnyDesk 9.0 - ID recorded'
  }
  It 'flattens line breaks and tabs' { Add-SetupActivity -Text "a`r`nb`tc"; (Get-SetupActivityLines -Count 1)[0].Text | Should -Be 'a b c' }
  It 'never throws when the file cannot be written, and still shows the line' {
    Initialize-SetupActivity -LogDirectory (Join-Path $dir 'gone\deeper')
    { Add-SetupActivity -Text 'x' } | Should -Not -Throw
    (Get-SetupActivityLines -Count 1)[0].Text | Should -Be 'x'
  }
  It 'returns the newest lines first, at most Count' {
    'one','two','three' | ForEach-Object { Add-SetupActivity -Text $_ }
    @(Get-SetupActivityLines -Count 2).Text | Should -Be @('three', 'two')
  }
  It 'brings the history back after a restart' {
    [IO.File]::WriteAllText("$dir\activity.txt", "2026-10-20 12:27:00`tAnyDesk installed`r`n2026-10-20 12:28:00`tRename PC done`r`n")
    Initialize-SetupActivity -LogDirectory $dir
    $l = @(Get-SetupActivityLines -Count 5)
    $l.Count | Should -Be 2; $l[0].Text | Should -Be 'Rename PC done'; $l[0].Time | Should -Be ([datetime]'2026-10-20T12:28:00')
  }
  It 'reads at most the last 64 KB of a big file and keeps at most 50 lines' {
    $sb = New-Object Text.StringBuilder; for ($i = 0; $i -lt 6000; $i++) { [void]$sb.Append("2026-10-20 12:00:00`tline $i`r`n") }
    [IO.File]::WriteAllText("$dir\activity.txt", $sb.ToString())
    Initialize-SetupActivity -LogDirectory $dir
    $l = @(Get-SetupActivityLines -Count 100); $l.Count | Should -Be 50; $l[0].Text | Should -Be 'line 5999'
  }
  It 'a new run archives the old file as activity-RunId.txt and starts empty; a second archive gets -2' {
    Add-SetupActivity -Text 'old run'
    Reset-SetupActivityLog -LogDirectory $dir -PreviousRunId '20261019-090000'
    "$dir\activity-20261019-090000.txt" | Should -Exist; "$dir\activity.txt" | Should -Not -Exist
    @(Get-SetupActivityLines -Count 5).Count | Should -Be 0
    Add-SetupActivity -Text 'again'; Reset-SetupActivityLog -LogDirectory $dir -PreviousRunId '20261019-090000'
    "$dir\activity-20261019-090000-2.txt" | Should -Exist
  }
  It 'a new run without an id archives the file under its LastWriteTime' {
    Add-SetupActivity -Text 'old run'
    [IO.File]::SetLastWriteTime("$dir\activity.txt", [datetime]'2026-10-19T09:30:15')
    Reset-SetupActivityLog -LogDirectory $dir
    "$dir\activity-20261019-093015.txt" | Should -Exist
  }
  It 'logs a file that cannot be written once, not for every line' {
    Initialize-SetupActivity -LogDirectory (Join-Path $dir 'gone\deeper')
    $script:warned = 0; Mock Write-SetupLog { if ($Level -eq 'WARN') { $script:warned++ } }
    Add-SetupActivity -Text 'a'; Add-SetupActivity -Text 'b'; Add-SetupActivity -Text 'c'
    $warned | Should -Be 1
  }
}
Describe 'Read-FileTail' {
  It 'decodes UTF-16LE with Hebrew' { $p = "$TestDrive\u16.log"; [IO.File]::WriteAllText($p, "a`r`n$Hebrew", [Text.Encoding]::Unicode); Read-FileTail -Path $p | Should -Match $Hebrew }
  It 'reads a file another process holds open for writing' {
    $p = "$TestDrive\held.log"; $w = [IO.File]::Open($p, 'Create', 'Write', 'ReadWrite')
    try { $b = [Text.Encoding]::UTF8.GetBytes("first`r`nlast line`r`n"); $w.Write($b, 0, $b.Length); $w.Flush(); Read-FileTail -Path $p | Should -Match 'last line' } finally { $w.Dispose() }
  }
  It 'reads at most MaxBytes and drops the cut first line' {
    $p = "$TestDrive\big.log"; [IO.File]::WriteAllText($p, ('x' * 70000) + "`r`ntail")
    $t = Read-FileTail -Path $p; $t.Length | Should -BeLessOrEqual 65536; $t | Should -Not -Match 'x'; $t | Should -Match 'tail'
  }
  It 'drops the BOM of a UTF-8 file' {
    $p = "$TestDrive\bom8.log"; [IO.File]::WriteAllText($p, "first`r`nsecond", (New-Object Text.UTF8Encoding $true))
    (Read-FileTail -Path $p).StartsWith('first') | Should -BeTrue
  }
  It 'decodes the tail of a big UTF-16 file from an even offset' {
    $p = "$TestDrive\big16.log"; [IO.File]::WriteAllText($p, ('y' * 40000) + "`r`n$Hebrew", [Text.Encoding]::Unicode)
    $t = Read-FileTail -Path $p -MaxBytes 65535; $t | Should -Be $Hebrew
  }
  It 'returns $null for a missing file' { Read-FileTail -Path "$TestDrive\none.log" | Should -BeNullOrEmpty }
}
Describe 'tick' {
  BeforeEach { Unregister-SetupTick; $script:ms = [long]0; $script:ctx = @{ Calls = 0 }; $script:warns = 0
    Mock Write-SetupLog { if ($Level -eq 'WARN') { $script:warns++ } } }
  It 'is a no-op with no handler' { { Invoke-SetupTick -Force } | Should -Not -Throw }
  It 'calls the handler with the context, at most once a second unless forced' {
    Register-SetupTick -Context $ctx -Handler { param($c) $c.Calls++ } -Clock { $script:ms }
    Invoke-SetupTick; $script:ms = 500; Invoke-SetupTick; $ctx.Calls | Should -Be 1
    $script:ms = 1000; Invoke-SetupTick; $ctx.Calls | Should -Be 2
    Invoke-SetupTick -Force; $ctx.Calls | Should -Be 3
  }
  It 'a throwing tick is logged once per minute and never escapes' {
    Register-SetupTick -Context $ctx -Handler { throw 'no console' } -Clock { $script:ms }
    foreach ($t in 0, 1000, 2000) { $script:ms = $t; { Invoke-SetupTick } | Should -Not -Throw }
    $warns | Should -Be 1
    $script:ms = 61000; Invoke-SetupTick; $warns | Should -Be 2
  }
  It 'does not re-enter itself' {
    Register-SetupTick -Context $ctx -Handler { param($c) $c.Calls++; Invoke-SetupTick -Force } -Clock { $script:ms }
    Invoke-SetupTick -Force; $ctx.Calls | Should -Be 1
  }
  It 'a handler using break cannot stop the caller''s loop' {
    Register-SetupTick -Context $ctx -Handler { break } -Clock { $script:ms }
    $after = 0; foreach ($i in 1..3) { Invoke-SetupTick -Force; $after++ }; $after | Should -Be 3
  }
  It 'logs a handler that used break (once) and goes on' {
    Register-SetupTick -Context $ctx -Handler { break } -Clock { $script:ms }
    foreach ($i in 1..3) { Invoke-SetupTick -Force }
    $warns | Should -Be 1
  }
  It 'a clock that goes backwards does not freeze the tick' {
    Register-SetupTick -Context $ctx -Handler { param($c) $c.Calls++ } -Clock { $script:ms }
    $script:ms = 90000; Invoke-SetupTick; $script:ms = 5000; Invoke-SetupTick
    $ctx.Calls | Should -Be 2
  }
}
Describe 'Wait-SetupDelay' {
  BeforeEach { Unregister-SetupTick; $script:sleeps = New-Object System.Collections.ArrayList; $script:ms = [long]0
    Mock Start-Sleep { [void]$script:sleeps.Add([pscustomobject]@{ S = $Seconds; M = $Milliseconds }); $script:ms += $Milliseconds } }
  It 'without a tick is exactly one Start-Sleep with the same argument' {
    Wait-SetupDelay -Seconds 120; Wait-SetupDelay -Milliseconds 5000
    $sleeps.Count | Should -Be 2; $sleeps[0].S | Should -Be 120; $sleeps[1].M | Should -Be 5000
  }
  It 'with a tick sleeps in slices of at most 250 ms and ticks between them' {
    $script:ticks = 0; Register-SetupTick -Context @{} -Handler { $script:ticks++ } -Clock { $script:ms }
    Wait-SetupDelay -Seconds 2
    @($sleeps | Where-Object { $_.M -gt 250 }).Count | Should -Be 0
    ($sleeps | Measure-Object -Property M -Sum).Sum | Should -Be 2000
    $ticks | Should -BeGreaterOrEqual 2
  }
  It 'still ends when the clock stands still' {
    Register-SetupTick -Context @{} -Handler { } -Clock { [long]0 }
    Wait-SetupDelay -Milliseconds 1000; ($sleeps | Measure-Object -Property M -Sum).Sum | Should -Be 1000
  }
  It 'honours a fraction of a second when ticking' {
    Register-SetupTick -Context @{} -Handler { } -Clock { $script:ms }
    Wait-SetupDelay -Seconds 0.3
    @($sleeps | ForEach-Object { $_.M }) | Should -Be @(250, 50)
  }
  It 'ends as soon as the clock reaches the total even when the sleeps ran long' {
    Mock Start-Sleep { [void]$script:sleeps.Add([pscustomobject]@{ S = $Seconds; M = $Milliseconds }); $script:ms += 3 * $Milliseconds }
    Register-SetupTick -Context @{} -Handler { } -Clock { $script:ms }
    Wait-SetupDelay -Milliseconds 1000
    $sleeps.Count | Should -Be 2
  }
}
Describe 'NOW state' {
  BeforeEach { Clear-SetupNow }
  It 'sets only what is given and clears everything' {
    Set-SetupNow -SubTitle 'Dell Command Update'; Set-SetupNow -Provider { 'x' } -ProviderArgument 'p'
    (Get-SetupNow).SubTitle | Should -Be 'Dell Command Update'; (Get-SetupNow).ProviderArgument | Should -Be 'p'
    Clear-SetupNow; (Get-SetupNow).SubTitle | Should -BeNullOrEmpty; (Get-SetupNow).Provider | Should -BeNullOrEmpty
  }
  It 'an empty title clears the title, and Clear-SetupNow also empties the wait stack' {
    Set-SetupNow -Title 'Waiting for Microsoft 365'; Set-SetupNow -Title ''
    (Get-SetupNow).Title | Should -BeNullOrEmpty
    Enter-SetupWait -LimitMinutes 3; Clear-SetupNow; (Get-SetupNow).Wait | Should -BeNullOrEmpty
  }
  It 'keeps a stack of waits; the top one is shown' {
    Enter-SetupWait -LimitMinutes 60; Enter-SetupWait -LimitMinutes 5
    (Get-SetupNow).Wait.LimitMinutes | Should -Be 5; Exit-SetupWait; (Get-SetupNow).Wait.LimitMinutes | Should -Be 60
    Exit-SetupWait; Exit-SetupWait; (Get-SetupNow).Wait | Should -BeNullOrEmpty
  }
}
