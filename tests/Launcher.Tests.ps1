# tests/Launcher.Tests.ps1
# Task 18: the signed launcher (launcher\BenTechSetup.template.cmd, built by tools\Build-Launcher.ps1) and
# tools\Publish.ps1.
#
# SAFETY:
# - Every signature here uses a throwaway RSA key made in this file, never Ben's real signing key.
# - Launchers are built into $TestDrive, read their "release" from a file:/// folder in $TestDrive and
#   install into $TestDrive, with -SkipAcl. Nothing touches C:\BenTech. The exceptions all stay inside
#   $TestDrive: the two exit-5 tests (a plain folder refused before any icacls; a new folder whose real,
#   non-recursive "icacls /setowner" is refused when not elevated - skipped when elevated) and the real
#   locked-create test. Each gives access back in a finally. The lockdown logic itself is tested with mocks.
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
    $kept = @($lines | Where-Object { $_ -notmatch 'fltmc\.exe' })
    $kept.Count | Should -Be ($lines.Count - 1)
    [IO.File]::WriteAllText($cmdPath, ($kept -join "`r`n"), (New-Object Text.ASCIIEncoding))
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
  It 'starts with the fixed polyglot header (R30: full paths, so nothing planted next to the .cmd can run)' {
    $expected = @(
      '@echo off'
      'setlocal'
      '"%SystemRoot%\System32\fltmc.exe" >nul 2>&1 || ( "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs" & exit /b )'
      '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText(''%~f0''); & ([ScriptBlock]::Create($t.Substring($t.LastIndexOf(''#__PS__'')))) %*"'
      'exit /b %errorlevel%'
      '#__PS__'
    )
    @($built -split "`r`n")[0..5] | Should -Be $expected
  }
  It 'never starts a bare program name in the cmd part (cmd looks in the .cmd''s own folder first)' {
    $cmdPart = $built.Substring(0, $built.IndexOf("`r`n#__PS__`r`n"))
    $cmdPart | Should -Not -Match '(?m)(^|[\s(|&])(powershell|fltmc|cmd|icacls)(\.exe)?\s'
    $cmdPart | Should -Match '"%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe" -NoProfile'
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
      if ($fn.Name -in 'Test-ReleaseSignature', 'Test-SetupLockHeld', 'Get-LauncherAclCommands') { . ([ScriptBlock]::Create($fn.Extent.Text)) }
    }
  }
  It 'builds the same two icacls commands as Get-SetupFolderAclCommands (src/Steps/Prepare.ps1), and refuses the same bad paths' {
    . "$PSScriptRoot\..\src\Steps\Prepare.ps1"
    foreach ($p in 'C:\BenTech', 'C:\BenTech\', 'D:\Some Dir\x') {
      $mine = @(Get-LauncherAclCommands -Parent $p)
      $mine.Count | Should -Be 2
      $mine | Should -Be @(Get-SetupFolderAclCommands -Parent $p)
    }
    foreach ($bad in 'C:\', 'C:', 'BenTech', '.\BenTech', '\BenTech', ' ', 'C:\x\..', 'C:\.\BenTech') {
      { Get-LauncherAclCommands -Parent $bad } | Should -Throw
      { Get-SetupFolderAclCommands -Parent $bad } | Should -Throw
    }
  }
  It 'creates a folder admin-only from the start, exactly like New-SetupLockedDirectory (real folders in TestDrive)' {
    . "$PSScriptRoot\..\src\Steps\Prepare.ps1"
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText("$TestDrive\launcher.ps1"), [ref]$tok, [ref]$err)
    $fn = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'New-LauncherLockedDirectory' }, $false))
    $fn.Count | Should -Be 1
    . ([ScriptBlock]::Create($fn[0].Extent.Text))
    $a = Join-Path $TestDrive 'locked-launcher'; $b = Join-Path $TestDrive 'locked-prepare'
    try {
      New-LauncherLockedDirectory -Path $a
      New-SetupLockedDirectory -Path $b
      foreach ($p in $a, $b) {
        $acl = Get-Acl -LiteralPath $p
        $acl.AreAccessRulesProtected | Should -BeTrue
        @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) |
          Should -Be @('S-1-5-18', 'S-1-5-32-544')
        @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IsInherited }) | Should -BeNullOrEmpty
      }
      (Get-Acl -LiteralPath $a).GetSecurityDescriptorSddlForm('Access') | Should -Be (Get-Acl -LiteralPath $b).GetSecurityDescriptorSddlForm('Access')
    } finally {
      # Not elevated, this user owns them but cannot open them: give access back so Pester can delete them.
      foreach ($p in $a, $b) { if (Test-Path -LiteralPath $p) { & "$env:windir\System32\icacls.exe" $p /reset 2>&1 | Out-Null } }
    }
  }
  It 'holds no recursive or repairing icacls switch anywhere in the launcher (R28b)' {
    $text = [IO.File]::ReadAllText("$PSScriptRoot\..\launcher\BenTechSetup.template.cmd")
    $text | Should -Not -Match '/T\b'
    $text | Should -Not -Match '/reset'
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

Describe 'launcher folder lockdown (R28b)' {
  # Protect-LauncherFolder runs here in this process with Start-Process, Get-Item, Get-Acl, New-Item and
  # New-LauncherLockedDirectory mocked: no real icacls, no real junction, nothing under C:\BenTech is read
  # or changed. Get-Acl answers real in-memory DirectorySecurity objects (never applied to disk).
  BeforeAll {
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText("$TestDrive\launcher.ps1"), [ref]$tok, [ref]$err)
    foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
      if ($fn.Name -in 'Get-LauncherAclCommands', 'Test-LauncherReparsePoint', 'Test-LauncherFolderAdminOnly', 'New-LauncherLockedDirectory', 'Protect-LauncherFolder') {
        . ([ScriptBlock]::Create($fn.Extent.Text))
      }
    }
    $script:icaclsExe = "$env:windir\System32\icacls.exe"
    function New-TestAcl {
      param([string]$Owner = 'S-1-5-32-544', [bool]$Protected = $true, [string[]]$Sids = @('S-1-5-32-544', 'S-1-5-18'))
      $s = New-Object Security.AccessControl.DirectorySecurity
      $s.SetOwner((New-Object Security.Principal.SecurityIdentifier $Owner))
      $s.SetAccessRuleProtection($Protected, $false)
      foreach ($sid in $Sids) {
        $s.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList (New-Object Security.Principal.SecurityIdentifier $sid),
            ([Security.AccessControl.FileSystemRights]::FullControl), ([Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'),
            ([Security.AccessControl.PropagationFlags]::None), ([Security.AccessControl.AccessControlType]::Allow)))
      }
      return $s
    }
    $script:userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:notAdminOnly = 'C:\BenTech already exists and is not admin-only. Delete it (as administrator) and run again. Nothing was run.'
  }
  BeforeEach {
    $script:icacls = New-Object System.Collections.ArrayList   # one hashtable per Start-Process call
    $script:steps = New-Object System.Collections.ArrayList    # ordered: 'icacls', 'acl <path>', 'mkdir <path>', 'mkdir-locked <path>'
    $script:failIcaclsAt = 0                                   # 1-based icacls call that exits 1307; 0 = none
    $script:folders = @('C:\BenTech', 'C:\BenTech\Setup')
    $script:reparse = @()
    $script:aclByPath = @{ 'C:\BenTech' = (New-TestAcl) }
    $script:aclAfterIcacls = @{}
    Mock Start-Process {
      [void]$script:icacls.Add(@{ File = $FilePath; Args = (@($ArgumentList) -join ' '); Wait = [bool]$Wait; PassThru = [bool]$PassThru; Window = [string]$WindowStyle })
      [void]$script:steps.Add('icacls')
      [pscustomobject]@{ ExitCode = $(if ($script:icacls.Count -eq $script:failIcaclsAt) { 1307 } else { 0 }) }
    }
    Mock Get-Item {
      if ($script:folders -notcontains $LiteralPath) { return $null }
      $attributes = [IO.FileAttributes]::Directory
      if ($script:reparse -contains $LiteralPath) { $attributes = $attributes -bor [IO.FileAttributes]::ReparsePoint }
      [pscustomobject]@{ FullName = $LiteralPath; Attributes = $attributes }
    }
    Mock Get-Acl {
      [void]$script:steps.Add("acl $LiteralPath")
      if ($script:icacls.Count -ge 2 -and $script:aclAfterIcacls.ContainsKey([string]$LiteralPath)) { return $script:aclAfterIcacls[[string]$LiteralPath] }
      if ($script:aclByPath.ContainsKey([string]$LiteralPath)) { return $script:aclByPath[[string]$LiteralPath] }
      throw "Cannot find path '$LiteralPath'"
    }
    Mock New-Item { [void]$script:steps.Add("mkdir $Path") }
    Mock New-LauncherLockedDirectory { [void]$script:steps.Add("mkdir-locked $Path") }
  }

  It 'accepts an existing, locked C:\BenTech without running icacls or creating anything' {
    $r = Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup'
    $r.Ok | Should -BeTrue
    @($script:steps) | Should -Be @('acl C:\BenTech')
  }
  It 'creates a missing working folder inside a locked C:\BenTech (it inherits), still without icacls' {
    $script:folders = @('C:\BenTech')
    (Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup').Ok | Should -BeTrue
    @($script:steps) | Should -Be @('acl C:\BenTech', 'mkdir C:\BenTech\Setup')
  }
  It 'refuses an existing C:\BenTech <Case>, with the delete-it message and no icacls' -ForEach @(
    @{ Case = 'owned by a user'; Acl = @{ Owner = 'USER' } }
    @{ Case = 'that inherits (not protected)'; Acl = @{ Protected = $false } }
    @{ Case = 'with an extra Authenticated Users (S-1-5-11) rule'; Acl = @{ Sids = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-11') } }
  ) {
    if ($Acl.Owner -eq 'USER') { $Acl = @{ Owner = $userSid } }
    $script:aclByPath['C:\BenTech'] = New-TestAcl @Acl
    $r = Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup'
    $r.Ok | Should -BeFalse
    $r.Message | Should -Be $notAdminOnly
    $script:icacls.Count | Should -Be 0
    @($script:steps | Where-Object { $_ -like 'mkdir*' }) | Should -BeNullOrEmpty
  }
  It 'creates a missing C:\BenTech already locked, runs the two icacls commands, verifies it, then creates Setup' {
    $script:folders = @()
    $script:aclByPath = @{}
    $script:aclAfterIcacls = @{ 'C:\BenTech' = (New-TestAcl) }
    (Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup').Ok | Should -BeTrue
    @($script:steps) | Should -Be @('mkdir-locked C:\BenTech', 'icacls', 'icacls', 'acl C:\BenTech', 'mkdir C:\BenTech\Setup')
    @($script:icacls | ForEach-Object { $_.Args }) | Should -Be @(
      '"C:\BenTech" /setowner *S-1-5-32-544'
      '"C:\BenTech" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F'
    )
    foreach ($c in $script:icacls) { $c.File | Should -Be $icaclsExe; $c.Wait | Should -BeTrue; $c.PassThru | Should -BeTrue; $c.Window | Should -Be 'Hidden' }
  }
  It 'refuses when the new C:\BenTech is still not admin-only after icacls (post-verify)' {
    $script:folders = @()
    $script:aclByPath = @{}
    $script:aclAfterIcacls = @{ 'C:\BenTech' = (New-TestAcl -Sids @('S-1-5-32-544', 'S-1-5-11')) }
    $r = Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup'
    $r.Ok | Should -BeFalse
    $r.Message | Should -Be 'Cannot secure C:\BenTech - nothing was run.'
    @($script:steps | Where-Object { $_ -eq 'mkdir C:\BenTech\Setup' }) | Should -BeNullOrEmpty
  }
  It 'stops at the icacls command that fails (call <At>) and refuses' -ForEach @(@{ At = 1 }, @{ At = 2 }) {
    $script:folders = @()
    $script:aclByPath = @{}
    $script:aclAfterIcacls = @{ 'C:\BenTech' = (New-TestAcl) }
    $script:failIcaclsAt = $At
    $r = Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup'
    $r.Ok | Should -BeFalse
    $r.Message | Should -Be 'Cannot secure C:\BenTech - nothing was run.'
    $script:icacls.Count | Should -Be $At
    @($script:steps | Where-Object { $_ -like 'acl *' -or $_ -eq 'mkdir C:\BenTech\Setup' }) | Should -BeNullOrEmpty
  }
  It 'treats an icacls without an exit code as a failure' {
    $script:folders = @()
    Mock Start-Process { [void]$script:icacls.Add(@{}); [pscustomobject]@{ ExitCode = $null } }
    (Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup').Ok | Should -BeFalse
  }
  It 'refuses a C:\BenTech that is a junction or symlink before reading or running anything' {
    $script:reparse = @('C:\BenTech')
    $r = Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup'
    $r.Ok | Should -BeFalse
    $r.Message | Should -Be $notAdminOnly
    @($script:steps) | Should -BeNullOrEmpty
  }
  It 'refuses a working folder that is a junction or symlink' {
    $script:reparse = @('C:\BenTech\Setup')
    $r = Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup'
    $r.Ok | Should -BeFalse
    $script:icacls.Count | Should -Be 0
  }
  It 'normalizes first: <Target> is refused by the root guard without touching anything' -ForEach @(
    @{ Target = 'C:\Setup' }, @{ Target = 'C:\x\..\Setup' }, @{ Target = 'C:\BenTech\..\Setup' }, @{ Target = 'C:\' }
  ) {
    $r = Protect-LauncherFolder -TargetDir $Target
    $r.Ok | Should -BeFalse
    @($script:steps) | Should -BeNullOrEmpty
  }
  It 'never throws (an icacls that cannot be started is a refusal)' {
    $script:folders = @()
    Mock Start-Process { throw 'cannot start icacls' }
    { Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup' } | Should -Not -Throw
    (Protect-LauncherFolder -TargetDir 'C:\BenTech\Setup').Ok | Should -BeFalse
  }
}

Describe 'launcher exit 5 (R28b)' {
  It 'exits 5 with the delete-it message and writes nothing when the parent exists and is not admin-only (real)' {
    # A plain folder made here inherits from TestDrive: not protected, so it is refused before any icacls.
    SignAll; $parent = Join-Path $TestDrive 's6'; New-Item -ItemType Directory $parent | Out-Null; $d = Join-Path $parent 'Setup'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\launcher.ps1" -TargetDir $d -NoPause 2>&1 | Out-String
    $LASTEXITCODE | Should -Be 5
    $out | Should -Match ([regex]::Escape("$parent already exists and is not admin-only. Delete it (as administrator) and run again. Nothing was run."))
    $d | Should -Not -Exist
  }
  It 'exits 5 and writes nothing when a new parent cannot be locked down (real icacls, refused when not elevated)' {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      Set-ItResult -Skipped -Because 'elevated: icacls /setowner would succeed here, so it cannot be the failure under test'
      return
    }
    # Not elevated, "icacls <new folder> /setowner *S-1-5-32-544" is refused (exit 1307).
    SignAll; $parent = Join-Path $TestDrive 's5'; $d = Join-Path $parent 'Setup'
    try {
      $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\launcher.ps1" -TargetDir $d -NoPause 2>&1 | Out-String
      $LASTEXITCODE | Should -Be 5
      $out | Should -Match ([regex]::Escape("Cannot secure $parent - nothing was run."))
      Test-Path -LiteralPath $parent | Should -BeTrue             # created locked, then refused
      (Get-Acl -LiteralPath $parent).AreAccessRulesProtected | Should -BeTrue
    } finally {
      # The new folder is admin-only and this (non-admin) user only owns it: give access back so Pester
      # can delete $TestDrive. Not recursive: the folder is empty.
      if (Test-Path -LiteralPath $parent) { & "$env:windir\System32\icacls.exe" $parent /reset 2>&1 | Out-Null }
    }
    Test-Path -LiteralPath $d | Should -BeFalse
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

  It 'uploads exactly the four signed files, never the launcher (R29), and targets HEAD' {
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\tools\Publish.ps1", [ref]$tok, [ref]$err)
    $assign = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$releaseNames' }, $true))
    $assign.Count | Should -Be 1
    $names = @($assign[0].Right.FindAll({ $args[0] -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
    $names | Should -Be @('setup.ps1', 'setup.ps1.sig', 'config.json', 'config.json.sig')
    $ghArgs = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$ghArgs' }, $true))
    $ghArgs.Count | Should -Be 1
    $ghArgs[0].Right.Extent.Text | Should -Match '\$releaseAssets'
    $ghArgs[0].Right.Extent.Text | Should -Match "'--target', \`$source\.Head"
    $ghArgs[0].Right.Extent.Text | Should -Not -Match 'BenTechSetup|launcher'
  }

  It 'refuses a dirty or unpushed tree unless -DryRun, which only warns' {
    $text = Get-Content -LiteralPath "$PSScriptRoot\..\tools\Publish.ps1" -Raw
    $text | Should -Match 'if \(\$source\.Problems\.Count -gt 0 -and -not \$DryRun\) \{\s*throw'
  }

  Context 'Get-PublishSource (git mocked)' {
    BeforeAll {
      $tok = $null; $err = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\tools\Publish.ps1", [ref]$tok, [ref]$err)
      $fn = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-PublishSource' }, $true))
      $fn.Count | Should -Be 1
      . ([ScriptBlock]::Create($fn[0].Extent.Text))
    }
    BeforeEach {
      $script:git = @{ StatusCode = 0; Status = @(); Head = 'aaaa1111'; UpCode = 0; Up = 'aaaa1111' }
      $script:gitCalls = New-Object System.Collections.ArrayList
      Mock git {
        $line = $args -join ' '
        [void]$script:gitCalls.Add($line)
        if ($line -match 'status --porcelain$') { $global:LASTEXITCODE = $script:git.StatusCode; return $script:git.Status }
        if ($line -match 'rev-parse HEAD$') { $global:LASTEXITCODE = 0; return $script:git.Head }
        if ($line -match 'rev-parse @\{u\}$') { $global:LASTEXITCODE = $script:git.UpCode; return $script:git.Up }
        $global:LASTEXITCODE = 99
      }
    }
    It 'has no problems for a clean tree whose HEAD is pushed, and returns HEAD' {
      $s = Get-PublishSource -RepoRoot 'C:\repo'
      @($s.Problems) | Should -BeNullOrEmpty
      $s.Head | Should -Be 'aaaa1111'
      @($script:gitCalls | Where-Object { $_ -notmatch '^-C C:\\repo ' }) | Should -BeNullOrEmpty
    }
    It 'reports uncommitted or untracked changes' {
      $script:git.Status = @(' M src/x.ps1', '?? new.ps1')
      @((Get-PublishSource -RepoRoot 'C:\repo').Problems | Where-Object { $_ -match 'uncommitted' }).Count | Should -Be 1
    }
    It 'reports a HEAD that is not pushed' {
      $script:git.Up = 'bbbb2222'
      @((Get-PublishSource -RepoRoot 'C:\repo').Problems | Where-Object { $_ -match 'not pushed' }).Count | Should -Be 1
    }
    It 'reports a branch with no upstream' {
      $script:git.UpCode = 128; $script:git.Up = @()
      @((Get-PublishSource -RepoRoot 'C:\repo').Problems | Where-Object { $_ -match 'no upstream' }).Count | Should -Be 1
    }
    It 'reports a folder that is not a git repository' {
      $script:git.StatusCode = 128
      $s = Get-PublishSource -RepoRoot 'C:\repo'
      @($s.Problems).Count | Should -Be 1
      $s.Head | Should -BeNullOrEmpty
    }
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
        $oldPath = $env:PATH; $oldToken = $env:GH_TOKEN; $oldCeiling = $env:GIT_CEILING_DIRECTORIES
        try {
          # The stub repo is not a git repository; the ceiling stops git from finding one above $TestDrive.
          $env:PATH = "$ghDir;$oldPath"; $env:GH_TOKEN = 'invalid-test-token'; $env:GIT_CEILING_DIRECTORIES = $TestDrive
          $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$pr\tools\Publish.ps1" -Version 2026.10.18.7 -DryRun 2>&1 | Out-String
          @{ Code = $LASTEXITCODE; Out = $out }
        } finally { $env:PATH = $oldPath; $env:GH_TOKEN = $oldToken; $env:GIT_CEILING_DIRECTORIES = $oldCeiling }
      }
      $script:hashFile = Join-Path $pr 'keys\launcher.sha256'
    }
    AfterEach { "$ghDir\gh-called.txt" | Should -Not -Exist }

    It 'builds the four signed files plus the launcher, never calls gh, and would upload only the four' {
      $r = RunPublish
      $r.Code | Should -Be 0
      @(Get-ChildItem -LiteralPath "$pr\dist" -File | ForEach-Object { $_.Name } | Sort-Object) |
        Should -Be @('BenTechSetup.cmd', 'config.json', 'config.json.sig', 'setup.ps1', 'setup.ps1.sig')
      [IO.File]::ReadAllText("$pr\dist\BenTechSetup.cmd") | Should -Match ([regex]::Escape("'https://github.com/example-invalid/not-a-real-repo/releases/latest/download'"))
      $line = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^DRY RUN - not run: gh ' })
      $line.Count | Should -Be 1
      $tokens = @(($line[0] -replace '^DRY RUN - not run: gh ', '') -split ' ')
      $tokens[0..2] | Should -Be @('release', 'create', 'v2026.10.18.7')
      $tokens[3..6] | Should -Be @("$pr\dist\setup.ps1", "$pr\dist\setup.ps1.sig", "$pr\dist\config.json", "$pr\dist\config.json.sig")
      $tokens[7] | Should -Be '--repo'
      $line[0] | Should -Match ' --target \S+ '
      $line[0] | Should -Not -Match 'BenTechSetup\.cmd'
    }
    It 'warns, but goes on, when the source cannot be verified under -DryRun (no git repository here)' {
      $r = RunPublish
      $r.Code | Should -Be 0
      $r.Out | Should -Match 'WARNING: .*git'
    }
    It 'prints the launcher SHA-256 and records it in keys\launcher.sha256' {
      Remove-Item -LiteralPath $hashFile -ErrorAction SilentlyContinue
      $r = RunPublish
      $r.Code | Should -Be 0
      $hash = (Get-FileHash -LiteralPath "$pr\dist\BenTechSetup.cmd" -Algorithm SHA256).Hash.ToLowerInvariant()
      $r.Out | Should -Match "Launcher SHA-256: $hash"
      (([IO.File]::ReadAllText($hashFile).Trim()) -split '\s+')[0] | Should -Be $hash
      $r.Out | Should -Not -Match 'WARNING: the launcher changed'
    }
    It 'warns when the launcher differs from keys\launcher.sha256, then records the new hash' {
      [IO.File]::WriteAllText($hashFile, ('0' * 64) + "  BenTechSetup.cmd`r`n")
      $r = RunPublish
      $r.Code | Should -Be 0
      $r.Out | Should -Match 'WARNING: the launcher changed'
      $hash = (Get-FileHash -LiteralPath "$pr\dist\BenTechSetup.cmd" -Algorithm SHA256).Hash.ToLowerInvariant()
      (([IO.File]::ReadAllText($hashFile).Trim()) -split '\s+')[0] | Should -Be $hash
    }
    It 'does not warn when the launcher is unchanged' {
      RunPublish | Out-Null
      $r = RunPublish
      $r.Code | Should -Be 0
      $r.Out | Should -Not -Match 'WARNING: the launcher changed'
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
