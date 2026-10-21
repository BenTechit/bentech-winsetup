# tests/Encoding.Tests.ps1
# Every .ps1 in the repo must be UTF-8 with BOM (Windows PowerShell 5.1 misreads BOM-less UTF-8 as ANSI).
BeforeDiscovery {
  $root = Split-Path -Parent $PSScriptRoot
  $script:ps1Files = @(
    foreach ($dir in 'src', 'tests', 'tools') {
      $p = Join-Path $root $dir
      if (Test-Path -LiteralPath $p) {
        Get-ChildItem -LiteralPath $p -Recurse -File -Filter *.ps1 | ForEach-Object {
          @{ Name = $_.FullName.Substring($root.Length + 1); FullName = $_.FullName }
        }
      }
    }
  )
  # Toolbox spec 4.3: every src file except the toolbox string table is ASCII after its BOM.
  $script:asciiFiles = @($script:ps1Files | Where-Object { $_.Name -like 'src\*' -and $_.Name -ne 'src\Toolbox\Strings.ps1' })
}
Describe 'PowerShell source encoding' {
  It '<Name> starts with a UTF-8 BOM' -ForEach $script:ps1Files {
    $stream = [IO.File]::OpenRead($FullName)
    try {
      $head = New-Object byte[] 3
      $read = $stream.Read($head, 0, 3)
    } finally { $stream.Dispose() }
    $read | Should -Be 3
    $head[0] | Should -Be 0xEF
    $head[1] | Should -Be 0xBB
    $head[2] | Should -Be 0xBF
  }
}
Describe 'ASCII sources (toolbox spec 4.3)' {
  It '<Name> is ASCII after its BOM' -ForEach $script:asciiFiles {
    $b = [IO.File]::ReadAllBytes($FullName); [Text.Encoding]::GetEncoding(28591).GetString($b, 3, $b.Length - 3) | Should -Not -Match '[^\x00-\x7F]' }
  It 'Strings.ps1 is strict UTF-8 and holds Hebrew' {
    $b = [IO.File]::ReadAllBytes("$PSScriptRoot\..\src\Toolbox\Strings.ps1")
    (New-Object Text.UTF8Encoding $false, $true).GetString($b, 3, $b.Length - 3) | Should -Match '[א-ת]' }
}
