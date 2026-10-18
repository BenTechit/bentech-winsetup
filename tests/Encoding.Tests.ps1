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
