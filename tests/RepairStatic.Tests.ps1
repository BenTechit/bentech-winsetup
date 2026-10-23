# tests/RepairStatic.Tests.ps1 - static guards for src\Repair (Repair & diagnostics); parses files only, nothing is run.
# Grown by later tasks.
#   - Decisions never come from localized tool output (Global Constraints), so the repair code never captures a tool's
#     output (no -CaptureOutput parameter anywhere) and reads files only inside the functions on $allowedReads: DISM's
#     display-only percent from its redirected output (Update-ToolTick), the JSON files of a run (Read-ToolJsonFile,
#     Read-ToolArgs), and the CBS.log / ReAgent.xml / log readers later tasks add (Review Focus 4).
#   - No download through Invoke-WebRequest, no sleep (child code calls Wait-SetupDelay), no prompt and no console text.
#   - Spec 6.3, 6.6 and the BitLocker chip: no IP release or renew, no component-store base reset, no recovery password.
#   - Ruling RD-R1: no src file calls the boot-time disk-check exclusion tool (its name is assembled below, so this file
#     does not hold it either).
BeforeAll {
  $script:srcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
  $script:repairFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:srcRoot 'Repair') -Recurse -File -Filter *.ps1)
  # Task 2 adds the CBS.log reader (SFC's verdict, always English) and the ReAgent.xml reader (WinRE's supporting
  # evidence, read by attribute); Task 7 the ghost CSV's own read-back (Invoke-ToolStepGhostCsv) and the network
  # backup's reader, which hashes and parses the same bytes (Read-ToolNetBackupFile); Task 8 the English servicing logs
  # condensed for the report (Read-ToolLogErrors: CBS.log, dism.log, setupapi.dev.log) and the hosts file (Get-ReportData09).
  $script:allowedReads = @('Update-ToolTick', 'Read-ToolJsonFile', 'Read-ToolArgs', 'Read-ToolCbsLog', 'Get-ToolReAgentState', 'Invoke-ToolStepGhostCsv',
                           'Read-ToolNetBackupFile', 'Read-ToolLogErrors', 'Get-ReportData09')
  # Tools whose answer is localized text (Task 8, spec 6.8: every report source is language-independent). Matched in the
  # code only (every token but comments, so a command inside a grandchild's here-string counts), a tool's name and its
  # switch within one line.
  $script:localizedTools = @(
    '(?i)\bnetstat(\.exe)?\b', '(?i)\bipconfig(\.exe)?\b[^\n]{0,80}?/all\b', '(?i)\bpnputil(\.exe)?\b[^\n]{0,80}?/enum', '(?i)\bdriverquery(\.exe)?\b',
    '(?i)\bnet1?(\.exe)?[''"]?\s+[''"]?(localgroup|user)\b', '(?i)\bnetsh(\.exe)?\b[^\n]{0,80}?\bwlan\b[^\n]{0,40}?\bshow\b', '(?i)manage-bde',
    '(?i)\bslmgr(\.vbs)?\b', '(?i)\bbcdedit(\.exe)?\b', '(?i)\breagentc(\.exe)?\b[^\n]{0,80}?/info\b')
  # The text of every token that is not a comment, in order, one space apart (new lines kept).
  function Get-CodeText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    (@(foreach ($t in $tokens) { if ($t.Kind -eq 'NewLine') { "`n" } elseif ($t.Kind -ne 'Comment') { $t.Text } }) -join ' ')
  }
  function Get-LocalizedToolViolation {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Name)
    $code = Get-CodeText -Text $Text
    foreach ($p in $script:localizedTools) { foreach ($m in [regex]::Matches($code, $p)) { '{0}: {1}' -f $Name, $m.Value } }
  }
  # A key protector's password (review M3). No repair file names the WMI method that returns it, the BitLocker
  # module's cmdlet whose protector objects carry it, or manage-bde; and the word RecoveryPassword appears only as the
  # one string constant 'RecoveryPassword' inside $script:ToolKeyProtectorTypes (the protector TYPE's name, which the
  # BitLocker chip lists). Anywhere else (a property, an index, a bare word, a comment, a here-string) it is flagged.
  $script:bannedSecretPattern = '(?i)GetKeyProtectorNumericalPassword|manage-bde|Get-BitLockerVolume'
  function Get-SecretViolation {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Name)
    foreach ($m in [regex]::Matches($Text, $script:bannedSecretPattern)) { '{0} offset {1}: {2}' -f $Name, $m.Index, $m.Value }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $table = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ToolKeyProtectorTypes' }, $true)
    foreach ($t in $tokens) {
      if ($t.Text -notmatch '(?i)RecoveryPassword') { continue }
      $allowed = ($null -ne $table) -and ($t.Kind -eq 'StringLiteral') -and ($t.Value -ceq 'RecoveryPassword') -and
        ($t.Extent.StartOffset -ge $table.Extent.StartOffset) -and ($t.Extent.EndOffset -le $table.Extent.EndOffset)
      if (-not $allowed) { '{0} line {1}: RecoveryPassword ({2})' -f $Name, $t.Extent.StartLineNumber, $t.Kind }
    }
  }

  function Get-EnclosingFunction {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $p = $Node.Parent
    while ($null -ne $p -and $p -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
    if ($null -ne $p) { $p.Name } else { '<top>' }
  }

  # The innermost function whose text holds the character at -Offset, or '<top>'.
  function Get-FunctionAtOffset {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast, [Parameter(Mandatory)][int]$Offset)
    $hits = @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Extent.StartOffset -le $Offset -and $n.Extent.EndOffset -gt $Offset }, $true) |
      Sort-Object { $_.Extent.StartOffset } -Descending)
    if ($hits.Count -gt 0) { $hits[0].Name } else { '<top>' }
  }

  # Every way the text captures tool output or reads a file outside the allow-list: '<name> line <n>: <what> in <function>'.
  function Get-ReadViolation {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    foreach ($p in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'CaptureOutput' }, $true)) {
      '{0} line {1}: -CaptureOutput' -f $Name, $p.Extent.StartLineNumber
    }
    foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Read-FileTail', 'Get-Content', 'gc', 'cat', 'type' }, $true)) {
      $fn = Get-EnclosingFunction -Node $c
      if ($script:allowedReads -notcontains $fn) { '{0} line {1}: {2} in {3}' -f $Name, $c.Extent.StartLineNumber, $c.GetCommandName(), $fn }
    }
    foreach ($m in [regex]::Matches($Text, 'ReadAllText|ReadAllLines|ReadAllBytes|StreamReader|ReadLines')) {
      $fn = Get-FunctionAtOffset -Ast $ast -Offset $m.Index
      if ($script:allowedReads -notcontains $fn) { '{0} offset {1}: {2} in {3}' -f $Name, $m.Index, $m.Value, $fn }
    }
  }
}

Describe 'src\Repair static guards' {
  It 'finds the repair code' {
    $script:repairFiles.Count | Should -BeGreaterThan 0
    @($script:repairFiles.Name) | Should -Contain 'ToolEngine.ps1'
  }
  It 'the repair code captures no tool output and reads only the files on its allow-list (Review Focus 4)' {
    $bad = @(foreach ($f in $script:repairFiles) { Get-ReadViolation -Text ([IO.File]::ReadAllText($f.FullName)) -Name $f.Name })
    $bad -join "`n" | Should -BeNullOrEmpty
  }
  It 'the detector flags a capture, a read outside the allow-list and a .NET read at the top, and accepts an allowed one' {
    $snippet = @'
function Update-ToolTick { $t = Read-FileTail -Path 'x' }
function Read-ToolJsonFile { $r = New-Object IO.StreamReader('x') }
function Invoke-ToolStepBad { $t = Get-Content -LiteralPath 'C:\Windows\Logs\CBS\CBS.log'; $r = Invoke-External -FilePath 'x' -CaptureOutput }
$top = [IO.File]::ReadAllText('x')
'@
    $found = @(Get-ReadViolation -Text $snippet -Name 'snippet')
    $found.Count | Should -Be 3
    ($found -join '|') | Should -Match '-CaptureOutput'; ($found -join '|') | Should -Match 'Get-Content in Invoke-ToolStepBad'; ($found -join '|') | Should -Match 'ReadAllText in <top>'
  }
  It 'no Invoke-WebRequest, Start-Sleep, Read-Host or Write-Host in src\Repair' {
    foreach ($f in $script:repairFiles) {
      $tokens = $null; $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
      $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -in 'Invoke-WebRequest', 'iwr', 'curl', 'wget', 'Start-Sleep', 'sleep', 'Read-Host', 'Write-Host' })
      $commands | Should -BeNullOrEmpty -Because $f.Name
      # Also inside strings (the grandchild commands are text): every token that is not a comment.
      @($tokens | Where-Object { $_.Kind -ne 'Comment' -and $_.Text -match '(?i)\b(Invoke-WebRequest|Start-Sleep|Read-Host|Write-Host)\b' }) | Should -BeNullOrEmpty -Because $f.Name
    }
  }
  It 'no repair file runs /release, /renew, /ResetBase or reads a key protector''s password' {
    foreach ($f in $script:repairFiles) {
      $text = [IO.File]::ReadAllText($f.FullName)
      $text | Should -Not -Match '(?i)/release|/renew|ResetBase' -Because $f.Name
      @(Get-SecretViolation -Text $text -Name $f.Name) -join "`n" | Should -BeNullOrEmpty
    }
  }
  It 'the password guard flags every way of reaching a password and passes only the protector type table''s constant (review M3)' {
    $snippet = @'
$script:ToolKeyProtectorTypes = @{ 1 = 'Tpm'; 3 = 'RecoveryPassword' }
$a = $kp.RecoveryPassword
$b = $kp['RecoveryPassword']
$c = $x | Select-Object -ExpandProperty RecoveryPassword
# keeps the RecoveryPassword
$d = "the $($kp.RecoveryPassword)"
manage-bde -protectors -get C:
Get-BitLockerVolume -MountPoint C:
$e = Invoke-CimMethod -InputObject $v -MethodName 'GetKeyProtectorNumericalPassword'
'@
    $found = @(Get-SecretViolation -Text $snippet -Name 'snippet')
    $found.Count | Should -Be 8
    ($found -join '|') | Should -Not -Match 'line 1:'
    foreach ($line in 2, 3, 4, 5, 6) { ($found -join '|') | Should -Match ('line {0}:' -f $line) }
    foreach ($word in 'manage-bde', 'Get-BitLockerVolume', 'GetKeyProtectorNumericalPassword') { ($found -join '|') | Should -Match $word }
    @(Get-SecretViolation -Text "`$other = @{ 3 = 'RecoveryPassword' }" -Name 'x').Count | Should -Be 1
  }
  It 'the CBS.log and ReAgent.xml readers exist in src\Repair (the allow-list names real functions)' {
    $names = @(foreach ($f in $script:repairFiles) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name } })
    foreach ($n in $script:allowedReads) { $names | Should -Contain $n }
  }
  It 'the window''s files call no hang-prone cmdlet and never wait on a process (Review Focus 1)' {
    # The window's thread polls; it never blocks: a hung disk, spooler or WMI may only ever hang a child (repair Task 4).
    $banned = 'Get-PhysicalDisk','Get-StorageReliabilityCounter','Repair-Volume','Repair-WindowsImage','Get-Printer','Get-WindowsDriver','Get-PnpDevice','Get-NetAdapter','Get-NetIPAddress',
              'Get-NetIPConfiguration','Get-BitLockerVolume','Get-WinEvent','Invoke-External','Invoke-PowerShellChild','Invoke-ToolJsonChild','Wait-Process','Start-Sleep','Wait-SetupDelay'
    $files = @(Get-ChildItem "$PSScriptRoot\..\src\Toolbox" -Filter *.ps1)
    @($files.Name) | Should -Contain 'RepairPage.ps1'
    foreach ($f in $files) {
      $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
      $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $banned -contains $_ })
      $calls | Should -BeNullOrEmpty -Because $f.Name
      [IO.File]::ReadAllText($f.FullName) | Should -Not -Match '\.WaitForExit\(|\.WaitOne\(' -Because $f.Name
    }
    # The guard itself finds a banned call and a wait.
    $probe = [Management.Automation.Language.Parser]::ParseInput('function F { Get-PhysicalDisk; $p.WaitForExit() }', [ref]$null, [ref]$null)
    @($probe.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $banned -contains $_ }) | Should -Be @('Get-PhysicalDisk')
  }
  It 'the ghost exclusion lists hold every enumerator of spec 6.7 (repair Task 7)' {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:srcRoot 'Repair\ToolAdvanced.ps1'), [ref]$null, [ref]$null)
    $values = @{}
    foreach ($name in '$script:GhostExcludedPrefixes', '$script:GhostExcludedClasses') {
      $assignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $name }, $true)
      $assignment | Should -Not -BeNullOrEmpty -Because $name
      $values[$name] = @($assignment.Right.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
    }
    $values['$script:GhostExcludedPrefixes'] | Should -Be @('BTHENUM\', 'BTHLE\', 'BTHLEDEVICE\', 'BTHHFENUM\', 'SWD\MMDEVAPI\', 'SWD\PRINTENUM\', 'WSDPRINT\')
    $values['$script:GhostExcludedClasses'] | Should -Be @('Bluetooth', 'Printer', 'PrintQueue', 'AudioEndpoint')
  }
  It 'the report collectors call no localized-output tool (repair Task 8, spec 6.8)' {
    $bad = @(foreach ($f in $script:repairFiles) { Get-LocalizedToolViolation -Text ([IO.File]::ReadAllText($f.FullName)) -Name $f.Name })
    $bad -join "`n" | Should -BeNullOrEmpty
    @($script:repairFiles.Name) | Should -Contain 'ToolCollect.ps1'
  }
  It 'the localized-tool detector finds each tool in code and in a grandchild''s text, and skips comments and look-alike names' {
    $snippet = @'
# netstat -ano and bcdedit /enum in a comment are fine
$a = Invoke-ToolNative -Run $Run -FilePath (Get-ToolSystemTool -Name 'pnputil.exe') -ArgumentList '/enum-drivers'
$b = Invoke-ToolNative -Run $Run -FilePath 'ipconfig.exe' -ArgumentList '/all'
$c = @"
netsh wlan show profiles
net localgroup administrators
"@
& netstat.exe -ano
& driverquery /v
& net user
& bcdedit /enum
& reagentc.exe /info
cscript slmgr.vbs /dli
manage-bde -status
function Test-ToolNetStatic { $x = 'user' }
$ok = Invoke-ToolNative -Run $Run -FilePath 'pnputil.exe' -ArgumentList '/scan-devices'
'@
    $found = @(Get-LocalizedToolViolation -Text $snippet -Name 'snippet')
    $found.Count | Should -Be 11
    ($found -join '|') | Should -Not -Match 'NetStatic|scan-devices'
  }
  It 'every grandchild command of the report parses (review M7: a syntax slip would make its source "not collected" on every PC)' {
    $commands = [ordered]@{}
    foreach ($file in 'ToolCollect.ps1', 'ToolReport.ps1') {
      $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:srcRoot "Repair\$file"), [ref]$null, [ref]$null)
      foreach ($a in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$script:Report[A-Za-z0-9]+Command\z' }, $false)) {
        $commands[$a.Left.Extent.Text] = $a.Right.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true).Value
      }
    }
    # The 16 of Task 8, the Administrators (review M4) and the zip (review M5).
    $commands.Count | Should -Be 18
    @($commands.Keys) | Should -Contain '$script:ReportAdminsCommand'; @($commands.Keys) | Should -Contain '$script:ReportZipCommand'
    foreach ($name in $commands.Keys) {
      # The placeholders the callers replace (<L>, <SPECS>, <DAYS>, <P>, <FROM>, <TO>) as a value, inside the block
      # Invoke-ToolJsonChild wraps every command in.
      $text = [regex]::Replace([string]$commands[$name], '<[A-Z]+>', '1')
      $errors = $null
      $null = [Management.Automation.Language.Parser]::ParseInput(("`$value = & {`r`n" + $text + "`r`n}"), [ref]$null, [ref]$errors)
      @($errors).Count | Should -Be 0 -Because $name
    }
    # The check catches a slip.
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput('$value = & { @{ Items = @(Get-Printer | ForEach-Object { @{ Name = $_.Name } ) } }', [ref]$null, [ref]$errors)
    @($errors).Count | Should -BeGreaterThan 0
  }
  It 'no src file calls the disk-check exclusion tool (ruling RD-R1)' {
    $tool = 'chk' + 'ntfs'
    foreach ($f in Get-ChildItem -LiteralPath $script:srcRoot -Recurse -File -Filter *.ps1) {
      [IO.File]::ReadAllText($f.FullName) | Should -Not -Match "(?i)$tool" -Because $f.Name
    }
  }
}
