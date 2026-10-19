# tests/ErrorAction.Tests.ps1
# Final review I1: CDXML cmdlets (Register-ScheduledTask) and the registry/file provider cmdlets (New-Item,
# New-ItemProperty, ...) report a failure as a NON-terminating error. The bundle never changes
# $ErrorActionPreference, so inside a try such a failure skips the catch and the code carries on as if it had
# worked. This static guard reads every src file's AST and fails for a guarded cmdlet called inside a try body
# without -ErrorAction Stop. It parses files only; nothing is run.
BeforeAll {
  $script:srcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
  $script:Guarded = @('New-Item', 'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty', 'Register-ScheduledTask', 'Unregister-ScheduledTask')

  # Explicit exemptions: '<path below src>|<function>|<cmdlet>' -> why. Keep this list small; every entry needs
  # a reason a failure there may pass unnoticed. Empty today: every guarded call inside a try carries
  # -ErrorAction Stop.
  $script:Exempt = @{
  }

  # The -ErrorAction value of a command ('Stop', ...), or $null when it has none. Handles both
  # "-ErrorAction Stop" and "-ErrorAction:Stop".
  function Get-ErrorActionValue {
    param([Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command)
    $elements = @($Command.CommandElements)
    for ($i = 0; $i -lt $elements.Count; $i++) {
      $e = $elements[$i]
      if ($e -isnot [Management.Automation.Language.CommandParameterAst] -or $e.ParameterName -ne 'ErrorAction') { continue }
      if ($null -ne $e.Argument) { return $e.Argument.Extent.Text.Trim("'", '"') }
      if ($i + 1 -lt $elements.Count) { return $elements[$i + 1].Extent.Text.Trim("'", '"') }
      return ''
    }
    return $null
  }

  # $true when the node sits in the Body of some enclosing try statement (a catch or finally block of a try
  # is not protected by that try).
  function Test-InTryBody {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $p = $Node
    while ($null -ne $p.Parent) {
      if ($p.Parent -is [Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($p.Parent.Body, $p)) { return $true }
      $p = $p.Parent
    }
    return $false
  }

  # Every call of a guarded cmdlet in the given script AST, with where it is and how it handles errors.
  function Get-GuardedCall {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast, [Parameter(Mandatory)][string]$File)
    foreach ($c in $Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
      $name = $c.GetCommandName()
      if ($script:Guarded -notcontains $name) { continue }
      $function = $c.Parent
      while ($null -ne $function -and $function -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
      [pscustomobject]@{
        File        = $File
        Line        = $c.Extent.StartLineNumber
        Function    = $(if ($null -ne $function) { $function.Name } else { '<top>' })
        Name        = $name
        InTry       = (Test-InTryBody -Node $c)
        ErrorAction = (Get-ErrorActionValue -Command $c)
      }
    }
  }

  $script:calls = @(
    foreach ($f in Get-ChildItem -LiteralPath $script:srcRoot -Recurse -File -Filter *.ps1) {
      $tokens = $null; $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
      Get-GuardedCall -Ast $ast -File $f.FullName.Substring($script:srcRoot.Length + 1)
    }
  )
  function Get-ExemptKey { param($Call) '{0}|{1}|{2}' -f $Call.File, $Call.Function, $Call.Name }
  function Format-Call { param($Call) '{0}:{1} {2} in {3} (-ErrorAction {4})' -f $Call.File, $Call.Line, $Call.Name, $Call.Function, $(if ($null -eq $Call.ErrorAction) { 'missing' } else { $Call.ErrorAction }) }
}

Describe 'state-changing cmdlets inside try carry -ErrorAction Stop (final review I1)' {
  It 'the scan finds the guarded calls, some of them inside a try' {
    $script:calls.Count | Should -BeGreaterThan 5
    @($script:calls | Where-Object { $_.InTry }).Count | Should -BeGreaterThan 3
  }
  It 'every guarded call inside a try body has -ErrorAction Stop (or an explained exemption)' {
    $bad = @($script:calls | Where-Object { $_.InTry -and $_.ErrorAction -ne 'Stop' -and -not $script:Exempt.ContainsKey((Get-ExemptKey $_)) } | ForEach-Object { Format-Call $_ })
    $bad -join "`n" | Should -BeNullOrEmpty
  }
  It 'Register-ScheduledTask and Unregister-ScheduledTask have -ErrorAction Stop wherever they are called (their callers catch one level up)' {
    $bad = @($script:calls | Where-Object { $_.Name -like '*-ScheduledTask' -and $_.ErrorAction -ne 'Stop' } | ForEach-Object { Format-Call $_ })
    $bad -join "`n" | Should -BeNullOrEmpty
  }
  It 'every exemption still matches a call (no stale entries)' {
    $keys = @($script:calls | ForEach-Object { Get-ExemptKey $_ })
    foreach ($k in $script:Exempt.Keys) { $keys | Should -Contain $k }
  }
  It 'the detector itself flags a call without -ErrorAction Stop, and accepts both spellings of Stop' {
    $snippet = @'
function Test-Snippet {
  try {
    New-Item -Path 'HKCU:\x' -Force | Out-Null
    New-ItemProperty -LiteralPath 'HKCU:\x' -Name n -Value 1 -ErrorAction Stop | Out-Null
    Set-ItemProperty -LiteralPath 'HKCU:\x' -Name n -Value 1 -ErrorAction:Stop
    Remove-ItemProperty -LiteralPath 'HKCU:\x' -Name n -ErrorAction SilentlyContinue
  } catch {
    New-Item -Path 'HKCU:\y'
  }
  New-Item -Path 'HKCU:\z'
}
'@
    $tokens = $null; $errors = $null
    $found = @(Get-GuardedCall -Ast ([Management.Automation.Language.Parser]::ParseInput($snippet, [ref]$tokens, [ref]$errors)) -File 'snippet')
    $found.Count | Should -Be 6
    @($found | Where-Object { $_.InTry }).Count | Should -Be 4
    @($found | Where-Object { $_.InTry -and $_.ErrorAction -ne 'Stop' } | ForEach-Object { $_.Name }) | Should -Be @('New-Item', 'Remove-ItemProperty')
    @($found | Where-Object { $_.Function -ne 'Test-Snippet' }).Count | Should -Be 0
  }
}
