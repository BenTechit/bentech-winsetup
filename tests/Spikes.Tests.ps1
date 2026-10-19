# tests/Spikes.Tests.ps1 - static checks only; the spike scripts are never run here.
BeforeAll {
  $script:spikeDir = (Resolve-Path "$PSScriptRoot\..\tools\spikes").Path
  $script:capture = Join-Path $script:spikeDir 'Spike-DriverListCapture.ps1'
  $script:text = [IO.File]::ReadAllText($script:capture)
  $script:ast = [Management.Automation.Language.Parser]::ParseFile($script:capture, [ref]$null, [ref]$null)
}
Describe 'spike scripts' {
  It 'every spike script parses' {
    foreach ($f in Get-ChildItem $script:spikeDir -Filter *.ps1) {
      $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
      $e | Should -BeNullOrEmpty -Because $f.Name
    }
  }
}
Describe 'Spike-DriverListCapture.ps1 is list-only' {
  It 'uses the list modes of both tools' { $text | Should -Match '/scan'; $text | Should -Match '/Action:List' }
  It 'never applies, downloads or installs updates' { $text | Should -Not -Match '(?i)/applyUpdates|/configure|/Action:(Install|Download)|autoSuspendBitLocker' }
  It 'never restarts and never writes the registry' { $text | Should -Not -Match '(?i)Restart-Computer|shutdown|bcdedit|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty' }
  It 'has the -InstallTool switch and installs a tool only inside if ($InstallTool)' {
    $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'InstallTool'
    $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'InventoryOnly'
    $hits = @($ast.FindAll({ param($n) ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Extent.Text -match 'install --id' }, $true))
    $hits.Count | Should -BeGreaterThan 0
    foreach ($h in $hits) {
      $p = $h.Parent
      while ($null -ne $p -and -not ($p -is [Management.Automation.Language.IfStatementAst] -and $p.Clauses[0].Item1.Extent.Text -eq '$InstallTool')) { $p = $p.Parent }
      $p | Should -Not -BeNullOrEmpty
    }
  }
}
