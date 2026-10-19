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
Describe 'Spike-DriverListCapture.ps1 never deletes recursively' {
  # It runs elevated, so a recursive delete in a user-writable folder (%TEMP%) could follow a planted junction.
  It 'has no Remove-Item (or alias) with -Recurse' {
    $cmds = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and (@('Remove-Item', 'rm', 'ri', 'del', 'erase', 'rd', 'rmdir') -contains $n.GetCommandName()) }, $true))
    $bad = @()
    foreach ($c in $cmds) {
      foreach ($el in $c.CommandElements) {
        if ($el -is [Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -like 'r*') { $bad += $c.Extent.Text }
      }
    }
    $bad | Should -BeNullOrEmpty
  }
}
Describe 'Spike-DriverListCapture.ps1 inventory matching' {
  BeforeAll {
    # Get-InventoryPattern is a pure function (it only returns a regex string), so it is safe to run here.
    $fn = $script:ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InventoryPattern' }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
  }
  It 'matches an HP name that merely contains HP (myHP, HPSupportAssistant, hp in lower case)' {
    $p = Get-InventoryPattern -Brand 'HP'
    foreach ($name in 'AD2F1837.myHP', 'AD2F1837.HPSupportAssistant', 'HP Support Assistant', 'HpTouchpointAnalyticsService', 'Hewlett-Packard Printer') {
      [regex]::IsMatch($name, $p) | Should -BeTrue -Because $name
    }
  }
  It 'matches a Dell name that contains Dell or SupportAssist' {
    $p = Get-InventoryPattern -Brand 'DELL'
    foreach ($name in 'Dell Command | Update', 'DellInc.DellSupportAssistforPCs', 'SupportAssistAgent', 'dellclientmanagementservice') {
      [regex]::IsMatch($name, $p) | Should -BeTrue -Because $name
    }
  }
  It 'does not match unrelated names' {
    foreach ($brand in 'DELL', 'HP') {
      $p = Get-InventoryPattern -Brand $brand
      foreach ($name in 'Spooler', 'Microsoft.WindowsCalculator', 'wuauserv') { [regex]::IsMatch($name, $p) | Should -BeFalse -Because ($brand + ' ' + $name) }
    }
  }
}
