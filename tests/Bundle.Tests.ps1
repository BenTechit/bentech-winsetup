# tests/Bundle.Tests.ps1
# Task 17: tools\Build-Bundle.ps1 concatenates every src file into one setup.ps1 (UTF-8 with BOM, CRLF)
# and copies config.json next to it.
#
# SAFETY: the bundle is built into $TestDrive (never into the repo's dist\ or C:\BenTech\Setup) and is
# only parsed, never run.
BeforeAll { $script:out = Join-Path $TestDrive 'dist'; & "$PSScriptRoot\..\tools\Build-Bundle.ps1" -Version '2026.10.18.9' -OutDir $out
  $script:b = [IO.File]::ReadAllBytes("$out\setup.ps1"); $script:tok = $null; $script:err = $null
  $script:ast = [Management.Automation.Language.Parser]::ParseFile("$out\setup.ps1", [ref]$tok, [ref]$err) }
Describe 'bundle' {
  It 'is UTF-8 with BOM' { $b[0..2] | Should -Be @(0xEF,0xBB,0xBF) }
  It 'parses without errors' { $err | Should -BeNullOrEmpty }
  It 'has the param block first' { $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Be @('Resume','WuRound','SearchOnly','ResultPath','WuUnhide','UpdateIds','ToolAction','ToolArgs') }
  It 'stamps the version' { [Text.Encoding]::UTF8.GetString($b) | Should -Match "\`$script:SetupVersion = '2026\.10\.18\.9'" }
  It 'includes every src file' { $order = (Get-Content "$PSScriptRoot\..\tools\Build-Bundle.ps1" -Raw)
    Get-ChildItem "$PSScriptRoot\..\src" -Recurse -Filter *.ps1 | ForEach-Object { $order | Should -Match ([regex]::Escape($_.Name)) } }
  It 'defines every catalog function' { . "$PSScriptRoot\..\src\Engine\Catalog.ps1"; $names = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
    foreach ($s in $script:StepCatalog) { $names | Should -Contain $s.Function } }
  # Repair Task 1: every step of every tool action has its row in $script:ToolSteps and its function in the bundle.
  It 'defines every tool action''s step functions' { . "$PSScriptRoot\..\src\Repair\ToolEngine.ps1"; $names = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
    foreach ($a in $script:ToolActionCatalog.Values) { foreach ($s in $a.Steps) { $script:ToolSteps.Keys | Should -Contain $s; $names | Should -Contain $script:ToolSteps[$s].Function } } }
  It 'copies config byte-for-byte' { (Get-FileHash "$out\config.json").Hash | Should -Be (Get-FileHash "$PSScriptRoot\..\config\config.json").Hash }
}

Describe 'bundle layout' {
  BeforeAll {
    # The text after the BOM, and its lines (CRLF is checked on its own below).
    $script:text = [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3)
    $script:lines = @($text -split "`r`n")
    $script:codeLines = @($lines | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
    $script:srcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
  }
  It 'uses CRLF line endings only' {
    $text | Should -Not -Match "(?<!`r)`n"
    $text | Should -Not -Match "`r(?!`n)"
  }
  It 'has no byte order mark inside (each source file''s BOM is stripped)' {
    $text.IndexOf([char]0xFEFF) | Should -Be -1
  }
  It 'starts with the header comment, then the param block, then the version' {
    $lines[0] | Should -Be '# BenTech Windows Setup 2026.10.18.9'
    $codeLines[0] | Should -Be 'param([switch]$Resume, [switch]$WuRound, [switch]$SearchOnly, [string]$ResultPath, [switch]$WuUnhide, [string]$UpdateIds, [string]$ToolAction, [string]$ToolArgs)'
    $codeLines[1] | Should -Be "`$script:SetupVersion = '2026.10.18.9'"
  }
  It 'ends with the entry call as its last non-empty line and last statement' {
    $call = 'exit (Start-BenTechSetup -Resume:$Resume -WuRound:$WuRound -SearchOnly:$SearchOnly -ResultPath $ResultPath -WuUnhide:$WuUnhide -UpdateIds $UpdateIds -ToolAction $ToolAction -ToolArgs $ToolArgs)'
    @($lines | Where-Object { $_.Trim() })[-1] | Should -Be $call
    $ast.EndBlock.Statements[-1].Extent.Text | Should -Be $call
    @($lines | Where-Object { $_ -match 'Start-BenTechSetup -Resume' }).Count | Should -Be 1
  }
  It 'has no dot-source lines of src files' {
    @($lines | Where-Object { $_ -match '^\s*\.\s+["'']?\$PSScriptRoot' }) | Should -BeNullOrEmpty
  }
  It 'marks every src file except Entry\Param.ps1 once, with Entry\Main.ps1 and Entry\Run.ps1 last' {
    $markers = @($lines | Where-Object { $_ -match '^# ---- (.+) ----$' } | ForEach-Object { $Matches[1] })
    $expected = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter *.ps1 |
      ForEach-Object { $_.FullName.Substring($srcRoot.Length + 1) } | Where-Object { $_ -ne 'Entry\Param.ps1' })
    ($markers | Sort-Object) | Should -Be ($expected | Sort-Object)
    $markers[-2] | Should -Be 'Entry\Main.ps1'
    $markers[-1] | Should -Be 'Entry\Run.ps1'
  }
  It 'defines no function twice (a later copy would silently replace the earlier one)' {
    $names = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
    @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
  }
  It 'initializes no script variable in two files (one file would overwrite the other''s value)' {
    $owners = @{}
    $dupes = foreach ($file in Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter *.ps1) {
      $t = $null; $e = $null
      $fileAst = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$t, [ref]$e)
      foreach ($statement in $fileAst.EndBlock.Statements) {
        if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left -is [Management.Automation.Language.VariableExpressionAst]) {
          $name = $statement.Left.VariablePath.UserPath
          if ($owners.ContainsKey($name) -and $owners[$name] -ne $file.Name) { '{0} ({1}, {2})' -f $name, $owners[$name], $file.Name }
          $owners[$name] = $file.Name
        }
      }
    }
    @($dupes) | Should -BeNullOrEmpty
  }
}

Describe 'Build-Bundle.ps1 checks' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
    # A throwaway copy of the repo (src, config and the builder) that a test can break.
    function New-RepoCopy {
      $copy = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
      New-Item -ItemType Directory -Path (Join-Path $copy 'tools') -Force | Out-Null
      Copy-Item -LiteralPath (Join-Path $script:repoRoot 'src') -Destination (Join-Path $copy 'src') -Recurse
      Copy-Item -LiteralPath (Join-Path $script:repoRoot 'config') -Destination (Join-Path $copy 'config') -Recurse
      Copy-Item -LiteralPath (Join-Path $script:repoRoot 'tools\Build-Bundle.ps1') -Destination (Join-Path $copy 'tools\Build-Bundle.ps1')
      $copy
    }
  }
  It 'rejects the version <Name>' -ForEach @(
    @{ Name = '2026.10.18'; Version = '2026.10.18' }, @{ Name = '2026-10-18.1'; Version = '2026-10-18.1' }
    @{ Name = '26.10.18.1'; Version = '26.10.18.1' }, @{ Name = '2026.10.18.1-rc'; Version = '2026.10.18.1-rc' }
    @{ Name = 'with a trailing space'; Version = '2026.10.18.1 ' }, @{ Name = 'with a leading space'; Version = ' 2026.10.18.1' }
    @{ Name = 'with a trailing newline'; Version = "2026.10.18.1`n" }
  ) {
    $dir = Join-Path $TestDrive ('bad-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    { & "$PSScriptRoot\..\tools\Build-Bundle.ps1" -Version $Version -OutDir $dir } | Should -Throw '*Version*'
    Test-Path -LiteralPath (Join-Path $dir 'setup.ps1') | Should -BeFalse
  }
  It 'builds into dist\ under the repo by default' {
    $copy = New-RepoCopy
    & (Join-Path $copy 'tools\Build-Bundle.ps1') -Version '2026.10.18.2'
    Test-Path -LiteralPath (Join-Path $copy 'dist\setup.ps1') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $copy 'dist\config.json') | Should -BeTrue
  }
  It 'fails when a src file is missing from $BundleOrder' {
    $copy = New-RepoCopy
    New-Item -ItemType Directory -Path (Join-Path $copy 'src\Extra') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $copy 'src\Extra\Stray.ps1') -Value 'function Get-Stray { 1 }' -Encoding UTF8
    $dir = Join-Path $copy 'out'
    { & (Join-Path $copy 'tools\Build-Bundle.ps1') -Version '2026.10.18.3' -OutDir $dir } | Should -Throw '*Extra\Stray.ps1*'
    Test-Path -LiteralPath (Join-Path $dir 'setup.ps1') | Should -BeFalse
  }
  It 'fails when $BundleOrder lists a file that does not exist' {
    $copy = New-RepoCopy
    Remove-Item -LiteralPath (Join-Path $copy 'src\Steps\Desktop.ps1')
    $dir = Join-Path $copy 'out'
    { & (Join-Path $copy 'tools\Build-Bundle.ps1') -Version '2026.10.18.4' -OutDir $dir } | Should -Throw '*Steps\Desktop.ps1*'
    Test-Path -LiteralPath (Join-Path $dir 'setup.ps1') | Should -BeFalse
  }
}
