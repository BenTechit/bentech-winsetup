# tests/PlainCode.Tests.ps1
# CLAUDE.md "Plain code only": setup.ps1 is scanned whole by Microsoft Defender (AMSI) before it runs, and
# v2026.10.23.1 was blocked as Trojan:PowerShell/DownloadObfus.A!MTB: a script that downloads files AND holds
# code that looks packed or assembled is read as a downloader hiding its payload. Nothing under src\ (the bundle)
# may run code built from text or packed for the command line, or spell text out as code points.
BeforeDiscovery {
  $root = Split-Path -Parent $PSScriptRoot
  $script:srcFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter *.ps1 |
    ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); FullName = $_.FullName } })
}
Describe 'Plain code only (CLAUDE.md)' {
  BeforeAll {
    # Each entry: what it is, and a case-insensitive pattern. Comments count too: AMSI reads the whole file.
    $script:forbidden = @(
      @{ What = 'an encoded command line (-EncodedCommand)'; Pattern = 'EncodedCommand' }
      @{ What = 'Base64 conversion'; Pattern = 'Base64(String|CharArray)' }
      @{ What = 'Invoke-Expression or iex'; Pattern = '\bInvoke-Expression\b|\biex\b' }
      @{ What = 'a script block built from text'; Pattern = 'ScriptBlock\]::Create|NewScriptBlock|\.InvokeScript\(' }
      @{ What = 'a string downloaded to run'; Pattern = '\.DownloadString\(|DownloadString\b' }
      @{ What = 'a char array of code points'; Pattern = '\[char\[\]\]\s*\(?\s*@?\(\s*0x' }
      @{ What = 'a list of [char] code points'; Pattern = '\[char\]\s*0x[0-9A-F]+\s*,' }
      @{ What = '[char] code points added together'; Pattern = '\[char\]\s*0x[0-9A-F]+\s*\+\s*(\[string\]\s*)?\[char\]' }
      @{ What = 'code points joined into text'; Pattern = '-join\s*\(\s*@?\(?\s*0x[0-9A-F]+' }
    )
  }
  It '<Name> uses none of the packed or assembled-code patterns' -ForEach $script:srcFiles {
    $lines = [IO.File]::ReadAllLines($FullName)
    $hits = foreach ($rule in $script:forbidden) {
      for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match $rule.Pattern) { '{0}:{1} {2}' -f $Name, ($i + 1), $rule.What }
      }
    }
    @($hits) | Should -BeNullOrEmpty
  }
}
