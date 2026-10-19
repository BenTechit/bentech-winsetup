# tests/Launcher.Tests.ps1
# Task 18: the signed launcher (launcher\BenTechSetup.template.cmd, built by tools\Build-Launcher.ps1) and
# tools\Publish.ps1.
#
# SAFETY:
# - Every signature here uses a throwaway RSA key made in this file, never Ben's real signing key.
# - Launchers are built into $TestDrive, read their "release" from a file:/// folder in $TestDrive and
#   install into $TestDrive, always with -SkipAcl. Nothing touches C:\BenTech\Setup.
# - Publish.ps1 only runs as a -DryRun in a stubbed copy under $TestDrive, with a fake gh first on PATH,
#   an invalid GH_TOKEN and a repo that does not exist.
BeforeAll {
  . "$PSScriptRoot\..\tools\Signing.ps1"
  $script:rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
  $script:rel = Join-Path $TestDrive 'release'; New-Item -ItemType Directory $rel | Out-Null
  $rsa.ToXmlString($false) | Set-Content "$TestDrive\pub.xml" -Encoding ASCII
  "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'ran.txt') -Value ok" | Set-Content "$rel\setup.ps1" -Encoding UTF8
  '{"x":1}' | Set-Content "$rel\config.json" -Encoding ASCII
  function SignAll { foreach ($f in 'setup.ps1','config.json') { [IO.File]::WriteAllBytes("$rel\$f.sig", (New-DetachedSignature -Data ([IO.File]::ReadAllBytes("$rel\$f")) -PrivateKeyXml $rsa.ToXmlString($true))) } }
  & "$PSScriptRoot\..\tools\Build-Launcher.ps1" -BaseUrl ([uri]$rel).AbsoluteUri -PublicKeyPath "$TestDrive\pub.xml" -OutPath "$TestDrive\BenTechSetup.cmd"
  $t = [IO.File]::ReadAllText("$TestDrive\BenTechSetup.cmd"); $t.Substring($t.LastIndexOf('#__PS__')) | Set-Content "$TestDrive\launcher.ps1" -Encoding UTF8
  function RunL($target) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\launcher.ps1" -TargetDir $target -SkipAcl -NoPause | Out-Null; $LASTEXITCODE }
}
Describe 'launcher' {
  It 'is ASCII with CRLF' { $b = [IO.File]::ReadAllBytes("$TestDrive\BenTechSetup.cmd"); ($b | ? { $_ -gt 0x7F }) | Should -BeNullOrEmpty; [Text.Encoding]::ASCII.GetString($b) | Should -Match "\r\n" }
  It 'verifies and runs a correctly signed release' { SignAll; $d = Join-Path $TestDrive 't1'; RunL $d | Should -Be 0; "$d\ran.txt" | Should -Exist }
  It 'refuses a tampered script and writes nothing' {
    SignAll; Add-Content "$rel\setup.ps1" ' '; $d = Join-Path $TestDrive 't2'
    RunL $d | Should -Be 3; "$d\setup.ps1" | Should -Not -Exist; "$d\ran.txt" | Should -Not -Exist
  }
  It 'refuses while a run holds the lock' { $d = Join-Path $TestDrive 't3'; New-Item -ItemType Directory $d | Out-Null; "$PID" | Set-Content "$d\run.lock"; RunL $d | Should -Be 2 }
}

Describe 'launcher trust gate' {
  BeforeAll {
    # RunL with extra launcher arguments (the brief's RunL is kept verbatim above).
    function RunLArgs([string]$target, [string[]]$extra) {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\launcher.ps1" -TargetDir $target -SkipAcl -NoPause @extra | Out-Null
      $LASTEXITCODE
    }
    $script:fastFail = @('-Retries', '2', '-RetrySeconds', '0')
  }

  It 'refuses a release signed with another key and creates nothing' {
    $other = (New-Object Security.Cryptography.RSACryptoServiceProvider 3072).ToXmlString($true)
    foreach ($f in 'setup.ps1', 'config.json') {
      [IO.File]::WriteAllBytes("$rel\$f.sig", (New-DetachedSignature -Data ([IO.File]::ReadAllBytes("$rel\$f")) -PrivateKeyXml $other))
    }
    $d = Join-Path $TestDrive 'g1'
    RunL $d | Should -Be 3
    $d | Should -Not -Exist
  }

  It 'refuses a tampered config.json even when setup.ps1 is valid' {
    SignAll; Add-Content "$rel\config.json" ' '; $d = Join-Path $TestDrive 'g2'
    RunL $d | Should -Be 3
    $d | Should -Not -Exist
  }

  It 'refuses an empty signature file' {
    SignAll; [IO.File]::WriteAllBytes("$rel\setup.ps1.sig", [byte[]]@()); $d = Join-Path $TestDrive 'g3'
    RunL $d | Should -Be 3
    $d | Should -Not -Exist
  }

  It 'treats a missing .sig as a failed download: retries, then exit 4, and creates nothing' {
    # A missing asset and an unreachable server look the same to WebClient (both throw), so both are a
    # download failure. Either way nothing is written or run.
    SignAll; Remove-Item -LiteralPath "$rel\config.json.sig"; $d = Join-Path $TestDrive 'g4'
    RunLArgs $d $fastFail | Should -Be 4
    $d | Should -Not -Exist
  }

  It 'gives up with exit 4 on an unreachable base URL, showing the retry message between attempts' {
    SignAll; $d = Join-Path $TestDrive 'g5'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\launcher.ps1" -TargetDir $d -SkipAcl -NoPause `
      -BaseUrl 'http://127.0.0.1:9' @fastFail 2>&1 | Out-String
    $LASTEXITCODE | Should -Be 4
    # 2 attempts = 1 retry message (none after the last attempt)
    ([regex]::Matches($out, [regex]::Escape('Cannot reach GitHub - retrying in 0s (close this window to stop)'))).Count | Should -Be 1
    $d | Should -Not -Exist
  }

  It 'shows the security message when a signature fails' {
    SignAll; Add-Content "$rel\setup.ps1" ' '; $d = Join-Path $TestDrive 'g6'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\launcher.ps1" -TargetDir $d -SkipAcl -NoPause 2>&1 | Out-String
    $LASTEXITCODE | Should -Be 3
    $out | Should -Match ([regex]::Escape('SECURITY CHECK FAILED - files are not signed by BenTech. Nothing was run.'))
  }

  It 'shows the lock message when a run holds the lock' {
    $d = Join-Path $TestDrive 'g7'; New-Item -ItemType Directory $d | Out-Null; "$PID" | Set-Content "$d\run.lock"
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\launcher.ps1" -TargetDir $d -SkipAcl -NoPause 2>&1 | Out-String
    $LASTEXITCODE | Should -Be 2
    $out | Should -Match 'Setup is already running on this machine'
    "$d\setup.ps1" | Should -Not -Exist
  }

  It 'ignores a stale lock (dead pid) and runs' {
    $p = Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile', '-Command', 'exit 0' -WindowStyle Hidden -PassThru
    $p.WaitForExit()   # $p keeps a handle open, so Windows cannot hand this pid to a new process meanwhile
    Get-Process -Id $p.Id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    SignAll; $d = Join-Path $TestDrive 'g8'; New-Item -ItemType Directory $d | Out-Null; "$($p.Id)" | Set-Content "$d\run.lock"
    RunL $d | Should -Be 0
    "$d\ran.txt" | Should -Exist
  }

  It 'ignores a lock whose pid is a live process that is not PowerShell, and runs' {
    $p = Start-Process -FilePath "$env:windir\System32\PING.EXE" -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
      SignAll; $d = Join-Path $TestDrive 'g9'; New-Item -ItemType Directory $d | Out-Null; "$($p.Id)" | Set-Content "$d\run.lock"
      RunL $d | Should -Be 0
      "$d\ran.txt" | Should -Exist
    } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }

  It 'writes the verified bytes unchanged and no .sig files' {
    SignAll; $d = Join-Path $TestDrive 'g10'
    RunL $d | Should -Be 0
    (Get-FileHash "$d\setup.ps1").Hash | Should -Be (Get-FileHash "$rel\setup.ps1").Hash
    (Get-FileHash "$d\config.json").Hash | Should -Be (Get-FileHash "$rel\config.json").Hash
    @(Get-ChildItem -LiteralPath $d -Filter *.sig) | Should -BeNullOrEmpty
  }

  It 'passes setup.ps1''s exit code through' {
    $saved = [IO.File]::ReadAllBytes("$rel\setup.ps1")
    try {
      'exit 7' | Set-Content "$rel\setup.ps1" -Encoding UTF8
      SignAll; $d = Join-Path $TestDrive 'g11'
      RunL $d | Should -Be 7
    } finally { [IO.File]::WriteAllBytes("$rel\setup.ps1", $saved) }
  }
}

Describe 'launcher polyglot through cmd' {
  BeforeAll {
    # The real built .cmd minus its elevation line (fltmc), which would raise a UAC prompt in a
    # non-elevated test run. Everything else, including the cmd -> PowerShell hand-off, is unchanged.
    $lines = [IO.File]::ReadAllText("$TestDrive\BenTechSetup.cmd") -split "`r`n"
    $script:cmdPath = Join-Path $TestDrive 'NoElevate.cmd'
    [IO.File]::WriteAllText($cmdPath, (@($lines | Where-Object { $_ -notmatch '^fltmc ' }) -join "`r`n"), (New-Object Text.ASCIIEncoding))
  }
  It 'passes the arguments through cmd and returns the PowerShell exit code (lock held -> 2)' {
    $d = Join-Path $TestDrive 'c1'; New-Item -ItemType Directory $d | Out-Null; "$PID" | Set-Content "$d\run.lock"
    & cmd.exe /c $cmdPath -TargetDir $d -SkipAcl -NoPause | Out-Null
    $LASTEXITCODE | Should -Be 2
  }
  It 'runs a correctly signed release end to end through cmd (exit 0)' {
    SignAll; $d = Join-Path $TestDrive 'c2'
    & cmd.exe /c $cmdPath -TargetDir $d -SkipAcl -NoPause | Out-Null
    $LASTEXITCODE | Should -Be 0
    "$d\ran.txt" | Should -Exist
  }
}

Describe 'launcher file layout' {
  BeforeAll {
    $script:templatePath = "$PSScriptRoot\..\launcher\BenTechSetup.template.cmd"
    $script:built = [IO.File]::ReadAllText("$TestDrive\BenTechSetup.cmd")
    $script:psSection = $built.Substring($built.LastIndexOf('#__PS__'))
  }
  It 'the template is ASCII with CRLF line endings only (no BOM)' {
    $b = [IO.File]::ReadAllBytes($templatePath)
    ($b | Where-Object { $_ -gt 0x7F }) | Should -BeNullOrEmpty
    $text = [Text.Encoding]::ASCII.GetString($b)
    $text | Should -Match "`r`n"
    $text | Should -Not -Match "(?<!`r)`n"
    $text | Should -Not -Match "`r(?!`n)"
  }
  It 'the built launcher has CRLF line endings only' {
    $built | Should -Not -Match "(?<!`r)`n"
    $built | Should -Not -Match "`r(?!`n)"
  }
  It 'starts with the fixed polyglot header' {
    $expected = @(
      '@echo off'
      'setlocal'
      'fltmc >nul 2>&1 || ( powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs" & exit /b )'
      'powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText(''%~f0''); & ([ScriptBlock]::Create($t.Substring($t.LastIndexOf(''#__PS__'')))) %*"'
      'exit /b %errorlevel%'
      '#__PS__'
    )
    @($built -split "`r`n")[0..5] | Should -Be $expected
  }
  It 'has the marker once on its own line, and the PowerShell section never repeats it' {
    ([regex]::Matches($built, '(?m)^#__PS__\r?$')).Count | Should -Be 1
    $psSection.IndexOf('#__PS__', 1) | Should -Be -1
  }
  It 'embeds the base URL and the one-line public key, with no placeholder left' {
    $built | Should -Not -Match '\{\{'
    $built | Should -Match ([regex]::Escape("'$(([uri]$rel).AbsoluteUri)'"))
    $built | Should -Match ([regex]::Escape("'$($rsa.ToXmlString($false))'"))
  }
  It 'has a PowerShell section that parses, with the documented parameters' {
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($psSection, [ref]$tok, [ref]$err)
    $err | Should -BeNullOrEmpty
    $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Be @('BaseUrl', 'TargetDir', 'SkipAcl', 'NoPause', 'Retries', 'RetrySeconds')
    ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TargetDir' }).DefaultValue.Value | Should -Be 'C:\BenTech\Setup'
    ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Retries' }).DefaultValue.Value | Should -Be 20
    ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RetrySeconds' }).DefaultValue.Value | Should -Be 30
  }
  It 'uses WebClient and never Invoke-WebRequest' {
    $psSection | Should -Match 'System\.Net\.WebClient'
    $psSection | Should -Match '\.DownloadData\('
    $psSection | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod|\biwr\b|\birm\b'
  }
}

Describe 'launcher mirrors stay in step with src' {
  BeforeAll {
    # Load the launcher's helper functions (not its main flow) into this scope.
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText("$TestDrive\launcher.ps1"), [ref]$tok, [ref]$err)
    foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
      if ($fn.Name -in 'Test-ReleaseSignature', 'Test-SetupLockHeld', 'Get-LauncherAclArgs') { . ([ScriptBlock]::Create($fn.Extent.Text)) }
    }
  }
  It 'builds the same icacls arguments as Get-SetupFolderAclArgs (src/Steps/Prepare.ps1)' {
    . "$PSScriptRoot\..\src\Steps\Prepare.ps1"
    foreach ($p in 'C:\BenTech\Setup', 'C:\BenTech\Setup\', 'D:\Some Dir\x') {
      Get-LauncherAclArgs -Path $p | Should -Be (Get-SetupFolderAclArgs -Path $p)
    }
  }
  It 'accepts a valid signature and returns a real $false for anything else (like Test-DetachedSignature)' {
    $data = [Text.Encoding]::UTF8.GetBytes('payload'); $pub = $rsa.ToXmlString($false)
    $sig = New-DetachedSignature -Data $data -PrivateKeyXml $rsa.ToXmlString($true)
    $ok = Test-ReleaseSignature -Data $data -Signature $sig -KeyXml $pub
    $ok | Should -BeOfType [bool]; $ok | Should -BeTrue
    $bad = @(
      @{ Data = $null }, @{ Signature = $null }, @{ KeyXml = $null }, @{ KeyXml = 'nope' },
      @{ Data = 'abc' }, @{ Data = @{ a = 1 } }, @{ Signature = @('x', 'y') }, @{ KeyXml = @{ a = 1 } },
      @{ Data = [byte[]]@() }, @{ Signature = [byte[]]@() }, @{ Signature = $sig[0..99] },
      @{ Data = [Text.Encoding]::UTF8.GetBytes('payload!') }
    )
    foreach ($case in $bad) {
      $a = @{ Data = $data; Signature = $sig; KeyXml = $pub }
      foreach ($k in $case.Keys) { $a[$k] = $case[$k] }
      $r = Test-ReleaseSignature @a
      $r | Should -BeOfType [bool]
      $r | Should -BeFalse
    }
  }
  It 'treats the lock like Test-RunLockHeld: live powershell pid held; missing, garbage, dead or other process not' {
    $d = Join-Path $TestDrive 'm1'; New-Item -ItemType Directory $d | Out-Null
    Test-SetupLockHeld -Root $d | Should -BeFalse
    'garbage' | Set-Content "$d\run.lock"; Test-SetupLockHeld -Root $d | Should -BeFalse
    '-4' | Set-Content "$d\run.lock"; Test-SetupLockHeld -Root $d | Should -BeFalse
    "$PID" | Set-Content "$d\run.lock"; Test-SetupLockHeld -Root $d | Should -BeTrue
    # A powershell that started more than 5 s after the lock was written cannot own it (pid reuse).
    (Get-Item "$d\run.lock").LastWriteTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().AddMinutes(-1)
    Test-SetupLockHeld -Root $d | Should -BeFalse
  }
}

Describe 'Build-Launcher.ps1 checks' {
  BeforeAll {
    $script:builder = "$PSScriptRoot\..\tools\Build-Launcher.ps1"
    $script:template = [IO.File]::ReadAllText("$PSScriptRoot\..\launcher\BenTechSetup.template.cmd")
    $script:failOut = Join-Path $TestDrive 'fail\BenTechSetup.cmd'
    function Build([hashtable]$Extra) {
      $a = @{ BaseUrl = 'https://example.invalid/download'; PublicKeyPath = "$TestDrive\pub.xml"; OutPath = $failOut }
      foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
      & $builder @a
    }
  }
  AfterEach { $failOut | Should -Not -Exist }

  It 'throws on a placeholder left in the template' {
    [IO.File]::WriteAllText("$TestDrive\leftover.cmd", $template + "# {{VERSION}}`r`n", (New-Object Text.ASCIIEncoding))
    { Build @{ TemplatePath = "$TestDrive\leftover.cmd" } } | Should -Throw '*placeholder*'
  }
  It 'throws on a template missing a placeholder' {
    [IO.File]::WriteAllText("$TestDrive\nokey.cmd", $template.Replace('{{PUBLIC_KEY_XML}}', 'x'), (New-Object Text.ASCIIEncoding))
    { Build @{ TemplatePath = "$TestDrive\nokey.cmd" } } | Should -Throw '*PUBLIC_KEY_XML*'
  }
  It 'throws on a non-ASCII template' {
    [IO.File]::WriteAllText("$TestDrive\nonascii.cmd", $template + "# caf$([char]0xE9)`r`n", (New-Object Text.UTF8Encoding $false))
    { Build @{ TemplatePath = "$TestDrive\nonascii.cmd" } } | Should -Throw '*ASCII*'
  }
  It 'throws on a template saved with a BOM' {
    [IO.File]::WriteAllText("$TestDrive\bom.cmd", $template, (New-Object Text.UTF8Encoding $true))
    { Build @{ TemplatePath = "$TestDrive\bom.cmd" } } | Should -Throw '*ASCII*'
  }
  It 'throws when the PowerShell section repeats the marker' {
    [IO.File]::WriteAllText("$TestDrive\marker.cmd", $template + "# #__PS__`r`n", (New-Object Text.ASCIIEncoding))
    { Build @{ TemplatePath = "$TestDrive\marker.cmd" } } | Should -Throw '*#__PS__*'
  }
  It 'throws on a single quote in the key' {
    $rsa.ToXmlString($false).Replace('<Exponent>', "<Exponent>'") | Set-Content "$TestDrive\quote.xml" -Encoding ASCII
    { Build @{ PublicKeyPath = "$TestDrive\quote.xml" } } | Should -Throw '*single quote*'
  }
  It 'refuses to embed a private key' {
    $rsa.ToXmlString($true) | Set-Content "$TestDrive\private.xml" -Encoding ASCII
    { Build @{ PublicKeyPath = "$TestDrive\private.xml" } } | Should -Throw '*private*'
  }
  It 'throws on a base URL with a single quote, or one that is not https or file' {
    { Build @{ BaseUrl = "https://example.invalid/a'b" } } | Should -Throw '*BaseUrl*'
    { Build @{ BaseUrl = 'http://example.invalid/download' } } | Should -Throw '*BaseUrl*'
    { Build @{ BaseUrl = 'not a url' } } | Should -Throw '*BaseUrl*'
  }
  It 'collapses a multi-line key to one line' {
    $multi = $rsa.ToXmlString($false).Replace('><', ">`r`n  <")
    $multi | Set-Content "$TestDrive\multi.xml" -Encoding ASCII
    $okOut = Join-Path $TestDrive 'multi\BenTechSetup.cmd'
    & $builder -BaseUrl 'https://example.invalid/download' -PublicKeyPath "$TestDrive\multi.xml" -OutPath $okOut
    [IO.File]::ReadAllText($okOut) | Should -Match ([regex]::Escape("'$($rsa.ToXmlString($false))'"))
    Remove-Item -LiteralPath $okOut
  }
}

Describe 'Publish.ps1' {
  It 'calls gh exactly once, and only inside an `if (-not $DryRun)` block' {
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\tools\Publish.ps1", [ref]$tok, [ref]$err)
    $err | Should -BeNullOrEmpty
    $gh = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -match '^gh(\.exe)?$' }, $true))
    $gh.Count | Should -Be 1
    $node = $gh[0].Parent
    while ($node -and $node -isnot [Management.Automation.Language.IfStatementAst]) { $node = $node.Parent }
    $node | Should -Not -BeNullOrEmpty
    $node.Clauses.Count | Should -Be 1
    $node.Clauses[0].Item1.Extent.Text | Should -Match '^-not\s+\$DryRun$'
    $body = $node.Clauses[0].Item2.Extent
    ($gh[0].Extent.StartOffset -ge $body.StartOffset -and $gh[0].Extent.EndOffset -le $body.EndOffset) | Should -BeTrue
    (Get-Content -LiteralPath "$PSScriptRoot\..\tools\Publish.ps1" -Raw) | Should -Not -Match 'Start-Process[^\r\n]*\bgh\b'
  }

  Context 'run as -DryRun in a stubbed copy of the repo' {
    BeforeAll {
      $script:pr = Join-Path $TestDrive 'pubrepo'
      $root = Split-Path -Parent $PSScriptRoot
      foreach ($dir in 'tools', 'keys', 'launcher', 'src\Common') { New-Item -ItemType Directory (Join-Path $pr $dir) -Force | Out-Null }
      Copy-Item "$root\tools\Publish.ps1", "$root\tools\Build-Launcher.ps1", "$root\tools\Signing.ps1" "$pr\tools"
      Copy-Item "$root\launcher\BenTechSetup.template.cmd" "$pr\launcher"
      Copy-Item "$root\src\Common\Signature.ps1" "$pr\src\Common"
      $rsa.ToXmlString($false) | Set-Content "$pr\keys\public-key.xml" -Encoding ASCII
      $script:stubKey = Join-Path $TestDrive 'stub-signing-key.xml'
      $rsa.ToXmlString($true) | Set-Content $stubKey -Encoding ASCII
      '{ "repo": "example-invalid/not-a-real-repo" }' | Set-Content "$pr\tools\publish.settings.json" -Encoding ASCII
      # Stubs for the slow or key-bound tools. Sign-File signs with the throwaway key, never the DPAPI one.
      'param([string]$Path) "stub tests"; "Failed: 0"; exit 0' | Set-Content "$pr\tools\Invoke-Tests.ps1" -Encoding UTF8
      'param([string]$Version, [string]$OutDir) New-Item -ItemType Directory -Path $OutDir -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $OutDir "setup.ps1"), "# stub $Version"); [IO.File]::WriteAllText((Join-Path $OutDir "config.json"), "{}")' |
        Set-Content "$pr\tools\Build-Bundle.ps1" -Encoding UTF8
      ("param([string]`$Path) . `"`$PSScriptRoot\Signing.ps1`"; [IO.File]::WriteAllBytes(`"`$Path.sig`", (New-DetachedSignature -Data ([IO.File]::ReadAllBytes(`$Path)) -PrivateKeyXml ([IO.File]::ReadAllText('$stubKey'))))") |
        Set-Content "$pr\tools\Sign-File.ps1" -Encoding UTF8
      # A fake gh first on PATH that records any call. Belt and braces if it were ever bypassed: an invalid
      # GH_TOKEN and a repo that does not exist.
      $script:ghDir = Join-Path $TestDrive 'ghstub'; New-Item -ItemType Directory $ghDir | Out-Null
      "@echo off`r`necho %*> `"%~dp0gh-called.txt`"`r`nexit /b 0`r`n" | Set-Content "$ghDir\gh.cmd" -Encoding ASCII -NoNewline
      function RunPublish {
        Remove-Item -LiteralPath "$pr\dist" -Recurse -Force -ErrorAction SilentlyContinue
        $oldPath = $env:PATH; $oldToken = $env:GH_TOKEN
        try {
          $env:PATH = "$ghDir;$oldPath"; $env:GH_TOKEN = 'invalid-test-token'
          $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$pr\tools\Publish.ps1" -Version 2026.10.18.7 -DryRun 2>&1 | Out-String
          @{ Code = $LASTEXITCODE; Out = $out }
        } finally { $env:PATH = $oldPath; $env:GH_TOKEN = $oldToken }
      }
    }
    AfterEach { "$ghDir\gh-called.txt" | Should -Not -Exist }

    It 'builds the five release files and never calls gh' {
      $r = RunPublish
      $r.Code | Should -Be 0
      @(Get-ChildItem -LiteralPath "$pr\dist" -File | ForEach-Object { $_.Name } | Sort-Object) |
        Should -Be @('BenTechSetup.cmd', 'config.json', 'config.json.sig', 'setup.ps1', 'setup.ps1.sig')
      [IO.File]::ReadAllText("$pr\dist\BenTechSetup.cmd") | Should -Match ([regex]::Escape("'https://github.com/example-invalid/not-a-real-repo/releases/latest/download'"))
      $r.Out | Should -Match 'DRY RUN'
    }
    It 'stops before building when the tests fail' {
      $stub = "$pr\tools\Invoke-Tests.ps1"; $saved = [IO.File]::ReadAllBytes($stub)
      try {
        'param([string]$Path) "Failed: 1"; exit 1' | Set-Content $stub -Encoding UTF8
        $r = RunPublish
        $r.Code | Should -Not -Be 0
        "$pr\dist\setup.ps1" | Should -Not -Exist
      } finally { [IO.File]::WriteAllBytes($stub, $saved) }
    }
    It 'stops before building the launcher when a signature does not verify against keys\public-key.xml' {
      $pubPath = "$pr\keys\public-key.xml"; $saved = [IO.File]::ReadAllBytes($pubPath)
      try {
        (New-Object Security.Cryptography.RSACryptoServiceProvider 3072).ToXmlString($false) | Set-Content $pubPath -Encoding ASCII
        $r = RunPublish
        $r.Code | Should -Not -Be 0
        "$pr\dist\setup.ps1.sig" | Should -Exist
        "$pr\dist\BenTechSetup.cmd" | Should -Not -Exist
      } finally { [IO.File]::WriteAllBytes($pubPath, $saved) }
    }
  }
}
