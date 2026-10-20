# tests/Waits.Tests.ps1 - static guard, parses files only.
# Step code never calls Start-Sleep: it calls Wait-SetupDelay, which keeps the progress screen alive
# (Task 6). Start-Sleep is left only where no tick may run.
BeforeAll {
  $script:srcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
  $script:sleepers = @(foreach ($f in Get-ChildItem $srcRoot -Recurse -Filter *.ps1) {
    $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Sleep' }, $true)) {
      $fn = $c.Parent; while ($null -ne $fn -and $fn -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
      '{0}|{1}' -f $f.FullName.Substring($srcRoot.Length + 1), $(if ($fn) { $fn.Name } else { '<top>' })
    } })
}
Describe 'every long wait ticks' {
  It 'Start-Sleep is left only where no tick may run' {
    ($sleepers | Sort-Object -Unique) | Should -Be @(
      'Common\Activity.ps1|Wait-SetupDelay', 'Common\Logging.ps1|Write-SetupLog', 'Engine\Reboot.ps1|Invoke-ControlledReboot',
      'State\State.ps1|Save-RunState', 'UI\FinalScreen.ps1|Show-FinalScreen', 'UI\StartScreen.ps1|Show-StartScreen')
  }
}
