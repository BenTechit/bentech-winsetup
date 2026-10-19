# tests/Colors.Tests.ps1 - static, parses files only.
# Spec 9.1: the powershell.exe console profile remaps DarkYellow (to near white) and DarkMagenta (to
# PowerShell blue), so no screen may use either, and every Write-Host names both its colours so no
# line depends on whatever palette the console happens to have.
BeforeAll { $script:files = @(Get-ChildItem (Resolve-Path "$PSScriptRoot\..\src").Path -Recurse -Filter *.ps1) }
Describe 'screen colours (spec 9.1)' {
  It 'no DarkYellow or DarkMagenta in src (comments aside) or in the launcher' {
    foreach ($f in $files) {
      $tokens = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$null)
      @($tokens | Where-Object { $_.Kind -ne 'Comment' -and $_.Text -match '(?i)Dark(Yellow|Magenta)' }).Count | Should -Be 0 -Because $f.Name
    }
    [IO.File]::ReadAllText("$PSScriptRoot\..\launcher\BenTechSetup.template.cmd") | Should -Not -Match '(?i)Dark(Yellow|Magenta)'
  }
  It 'every Write-Host in src sets its foreground and its background' {
    foreach ($f in $files) {
      $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
      foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host' }, $true)) {
        $names = @($c.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        ($names -contains 'ForegroundColor' -and $names -contains 'BackgroundColor') | Should -BeTrue -Because ('{0} line {1}' -f $f.Name, $c.Extent.StartLineNumber)
      }
    }
  }
}
