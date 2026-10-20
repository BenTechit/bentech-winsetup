# src/Steps/Office.ps1
# Microsoft 365 through the Office Deployment Tool (ODT), in two catalog steps (v2 spec 4.6):
#   office         (after vendor-pass1) prepares as v1 did, then STARTS setup.exe /configure in the
#                  background and records the process in its Data;
#   office-finish  (after windows-update) waits for it, reports its result, installs once in the
#                  foreground when the background run left nothing behind, and puts the Word, Excel,
#                  PowerPoint and Outlook shortcuts on the public desktop (v2 spec 4.7).
# Every controlled restart, and Finalize, first waits for a background setup that is still running
# (Wait-OfficeBackground), up to its deadline (start + timeoutsMinutes.office).
# Needs StepResult.ps1, Logging.ps1, Activity.ps1, Process.ps1, Download.ps1, State.ps1 (Save-RunState),
# Config.ps1 (Get-Signers), Winget.ps1 (Invoke-WingetInstall) and Apps.ps1 (Write-TextFileUtf8NoBom); the
# bundle holds every file.
#
# The ODT comes from winget (Microsoft.OfficeDeploymentTool); when winget cannot provide it, the
# self-extracting ODT is scraped from Microsoft's download page. Either way the setup.exe is
# signature-checked against the Microsoft signer before it runs.
#
# office step Data: @{ Background = $true; ProcessId; ProcessStartUtc ('o'); StartedAt; DeadlineAt ('s',
# local) }, plus, once the process is known to have ended: Finished = $true and ExitCode or
# KilledAtDeadline = $true (or neither: ended, code unknown). office-finish Data: ForegroundTried.

$script:OfficeReleaseKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'

# The desktop shortcuts office-finish makes: shortcut name -> executable under <InstallationPath>\root\Office16.
$script:OfficeShortcutApps = [ordered]@{ Word = 'WINWORD.EXE'; Excel = 'EXCEL.EXE'; PowerPoint = 'POWERPNT.EXE'; Outlook = 'OUTLOOK.EXE' }

# The setup.exe the office step started, kept for this process's lifetime: its ExitCode is readable after
# it ends. After a restart it is $null and Get-OfficeBackgroundProcess finds the process by id + start time.
$script:OfficeBackgroundProcess = $null

function New-OfficeConfigXml {
  <#
  .SYNOPSIS
    The ODT configuration XML: one product, the languages in the order given (Hebrew first), one
    ExcludeApp per app, RemoveMSI, FORCEAPPSHUTDOWN, automatic updates, no UI and the EULA accepted.
  .DESCRIPTION
    Two-space indentation, CRLF line breaks, no trailing line break. Values are XML-escaped.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProductId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Languages,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExcludeApps,
    [Parameter(Mandatory)][string]$Channel,
    [Parameter(Mandatory)][string]$Edition
  )

  $esc = { param($text) [Security.SecurityElement]::Escape([string]$text) }
  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add('<Configuration>')
  $lines.Add(('  <Add OfficeClientEdition="{0}" Channel="{1}">' -f (& $esc $Edition), (& $esc $Channel)))
  $lines.Add(('    <Product ID="{0}">' -f (& $esc $ProductId)))
  foreach ($language in $Languages) { $lines.Add(('      <Language ID="{0}" />' -f (& $esc $language))) }
  foreach ($app in $ExcludeApps) { $lines.Add(('      <ExcludeApp ID="{0}" />' -f (& $esc $app))) }
  $lines.Add('    </Product>')
  $lines.Add('  </Add>')
  $lines.Add('  <RemoveMSI />')
  $lines.Add('  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />')
  $lines.Add('  <Updates Enabled="TRUE" />')
  $lines.Add('  <Display Level="None" AcceptEULA="TRUE" />')
  $lines.Add('</Configuration>')
  return ($lines.ToArray() -join "`r`n")
}

function Test-OfficeInstalled {
  <#
  .SYNOPSIS
    $true when ProductId is one of the comma-separated ids in ProductReleaseIds (the Click-to-Run
    registry value). Whole ids only, case and spaces around the commas ignored.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [AllowNull()][AllowEmptyString()][string]$ProductReleaseIds,
    [Parameter(Mandatory)][string]$ProductId
  )

  foreach ($id in ([string]$ProductReleaseIds -split ',')) {
    if ($id.Trim() -eq $ProductId) { return $true }
  }
  return $false
}

function Get-OdtSetupPath {
  <#
  .SYNOPSIS
    Private. Makes the Office Deployment Tool available and returns @{ Path; Failure }: the path of its
    setup.exe, or Path = $null and the Failure message to report.
  .DESCRIPTION
    1. winget install of the ODT. A winget result that is not Done is only logged: what counts is
       whether config apps.office.odtSetupPath exists afterwards (it may also be left over from an
       earlier run).
    2. Otherwise the fallback: read odtFallbackPage, take the first link matching odtLinkPattern,
       download it to <Downloads>\officedeploymenttool.exe, check its signature (a bad file is deleted
       and never run) and let it extract itself with `/quiet /extract:"<Downloads>\ODT"`. The setup.exe
       it leaves in that folder is used.
    The setup.exe's own signature is checked by the caller.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $office = $Context.Config.apps.office
  $odtSetup = [string]$office.odtSetupPath

  $winget = Invoke-WingetInstall -Id ([string]$office.odtWingetId) -Source winget -Context $Context
  if ($winget.Status -ne 'Done') {
    Write-SetupLog -Message 'ODT was not installed by winget' -Level WARN -Data @{ status = [string]$winget.Status; message = [string]$winget.Message }
  }
  if (Test-Path -LiteralPath $odtSetup -PathType Leaf) { return @{ Path = $odtSetup; Failure = $null } }
  Write-SetupLog -Message 'ODT setup.exe not found where expected; using the download page' -Level WARN -Data @{ expected = $odtSetup }

  try {
    $html = Get-RemoteText -Url ([string]$office.odtFallbackPage)
  } catch {
    Write-SetupLog -Message 'ODT download page could not be read' -Level ERROR -Data @{ error = $_.Exception.Message }
    return @{ Path = $null; Failure = "Office Deployment Tool page could not be read: $($_.Exception.Message)" }
  }
  $link = Find-LatestLink -Html $html -Pattern ([string]$office.odtLinkPattern)
  if (-not $link) { return @{ Path = $null; Failure = 'Office Deployment Tool download link not found' } }

  try {
    $odtExe = [string](Get-RemoteFile -Url $link -Destination (Join-Path $Context.DownloadDir 'officedeploymenttool.exe'))
  } catch {
    Write-SetupLog -Message 'ODT download failed' -Level ERROR -Data @{ url = $link; error = $_.Exception.Message }
    return @{ Path = $null; Failure = "Office Deployment Tool download failed: $($_.Exception.Message)" }
  }

  $signers = Get-Signers -Config $Context.Config -Key ([string]$office.signer)
  if (-not (Test-FileSignature -Path $odtExe -AllowedSigners $signers)) {
    Remove-Item -LiteralPath $odtExe -Force -ErrorAction SilentlyContinue
    return @{ Path = $null; Failure = 'Office Deployment Tool signature check failed' }
  }

  $folder = Join-Path $Context.DownloadDir 'ODT'
  try {
    $run = Invoke-External -FilePath $odtExe -ArgumentList "/quiet /extract:`"$folder`"" -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.default)
  } catch {
    Write-SetupLog -Message 'ODT extractor could not be started' -Level ERROR -Data @{ error = $_.Exception.Message }
    return @{ Path = $null; Failure = 'Office Deployment Tool extract failed (could not be started)' }
  }
  if ($run.TimedOut) { return @{ Path = $null; Failure = 'Office Deployment Tool extract timed out' } }
  if ($run.ExitCode -ne 0) { return @{ Path = $null; Failure = "Office Deployment Tool extract failed ($($run.ExitCode))" } }

  $extracted = Join-Path $folder 'setup.exe'
  if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) {
    return @{ Path = $null; Failure = 'Office Deployment Tool setup.exe not found after extract' }
  }
  return @{ Path = $extracted; Failure = $null }
}

function Initialize-OfficeInstall {
  <#
  .SYNOPSIS
    The v1 preparation, in v1 order. Returns @{ Result; SetupPath; XmlPath; ProductId }: Result is a
    StepResult the caller returns as is, or $null when setup.exe is ready to run with the XML.
  .DESCRIPTION
    Choices.Office OFF is Skipped('Office not selected') (the plan leaves both Office steps out in that
    case; this is a safety net). A choice without a configured product is Failed. A product already
    listed in the Click-to-Run ProductReleaseIds is Done('Office already installed'). Otherwise
    Get-OdtSetupPath finds the ODT, setup.exe is signature-checked against the Microsoft signer and the
    configuration is written UTF-8 without a BOM to <Downloads>\office.xml.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $prepared = @{ Result = $null; SetupPath = $null; XmlPath = $null; ProductId = $null }

  $choice = [string]$Context.State.Choices.Office
  if ([string]::IsNullOrEmpty($choice) -or $choice -eq 'OFF') {
    $prepared.Result = New-StepResult -Status Skipped -Message 'Office not selected'
    return $prepared
  }

  $office = $Context.Config.apps.office
  $product = $office.products.PSObject.Properties[$choice]
  if (-not $product) {
    $prepared.Result = New-StepResult -Status Failed -Message "Office choice '$choice' has no product in the config"
    return $prepared
  }
  $prepared.ProductId = [string]$product.Value

  if (Test-OfficeProductInstalled -ProductId $prepared.ProductId) {
    $prepared.Result = New-StepResult -Status Done -Message 'Office already installed'
    return $prepared
  }

  $odt = Get-OdtSetupPath -Context $Context
  if (-not $odt.Path) {
    $prepared.Result = New-StepResult -Status Failed -Message $odt.Failure
    return $prepared
  }

  $signers = Get-Signers -Config $Context.Config -Key ([string]$office.signer)
  if (-not (Test-FileSignature -Path $odt.Path -AllowedSigners $signers)) {
    $prepared.Result = New-StepResult -Status Failed -Message 'Office setup.exe signature check failed'
    return $prepared
  }

  $xmlPath = Join-Path $Context.DownloadDir 'office.xml'
  try {
    $xml = New-OfficeConfigXml -ProductId $prepared.ProductId -Languages @($office.languages) -ExcludeApps @($office.excludeApps) -Channel ([string]$office.channel) -Edition ([string]$office.edition)
    Write-TextFileUtf8NoBom -Path $xmlPath -Text $xml
  } catch {
    Write-SetupLog -Message 'Office configuration XML could not be written' -Level ERROR -Data @{ path = $xmlPath; error = $_.Exception.Message }
    $prepared.Result = New-StepResult -Status Failed -Message 'Office configuration could not be written'
    return $prepared
  }

  $prepared.SetupPath = $odt.Path
  $prepared.XmlPath = $xmlPath
  return $prepared
}

function Test-OfficeProductInstalled {
  # Private. $true when ProductId is listed in the Click-to-Run ProductReleaseIds registry value.
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$ProductId)

  $installed = Get-ItemProperty -LiteralPath $script:OfficeReleaseKey -Name ProductReleaseIds -ErrorAction SilentlyContinue
  return ([bool]$installed -and (Test-OfficeInstalled -ProductReleaseIds ([string]$installed.ProductReleaseIds) -ProductId $ProductId))
}

function Invoke-OfficeForegroundInstall {
  <#
  .SYNOPSIS
    The v1 install: `setup.exe /configure "<xml>"` through Invoke-External with the configured office
    timeout. Prepared is Initialize-OfficeInstall's result with a null Result.
  .DESCRIPTION
    Exit 0 is Done('Office installed'). 3010 and 1641 (installed, restart pending) are
    Done('Office installed (restart pending)') with Reboot 'Now': this only runs inside office-finish,
    after windows-update, whose restarts ruling R17a relied on (amended by Task 13). Any other code is
    Failed('Office setup exit <code>'); a timeout is Failed('Office setup timed out').
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)][hashtable]$Prepared
  )

  try {
    $run = Invoke-External -FilePath $Prepared.SetupPath -ArgumentList "/configure `"$($Prepared.XmlPath)`"" -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.office)
  } catch {
    Write-SetupLog -Message 'Office setup could not be started' -Level ERROR -Data @{ error = $_.Exception.Message }
    return New-StepResult -Status Failed -Message 'Office setup could not be started'
  }
  if ($run.TimedOut) { return New-StepResult -Status Failed -Message 'Office setup timed out' }
  if ($null -ne $run.ExitCode -and $run.ExitCode -in 3010, 1641) { return New-StepResult -Status Done -Message 'Office installed (restart pending)' -Reboot Now }
  if ($null -eq $run.ExitCode -or $run.ExitCode -ne 0) { return New-StepResult -Status Failed -Message "Office setup exit $($run.ExitCode)" }
  return New-StepResult -Status Done -Message 'Office installed'
}

function Invoke-StepOffice {
  <#
  .SYNOPSIS
    The office step: prepares as v1 did, then starts setup.exe in the background (v2 spec 4.6).
  .DESCRIPTION
    Initialize-OfficeInstall's Result, when it has one, is returned as is (Skipped, already installed,
    or a failed preparation). Otherwise `setup.exe /configure "<xml>"` is started with
    Start-BackgroundExternal (the one exception to "every child goes through Invoke-External"; its
    deadline is enforced by Wait-OfficeBackground). A setup.exe that cannot start is
    Failed('Office setup could not be started'). The process stays in $script:OfficeBackgroundProcess
    and the step returns Done('Microsoft 365 installing in the background') with Data Background,
    ProcessId, ProcessStartUtc, StartedAt and DeadlineAt (StartedAt + timeoutsMinutes.office).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $prepared = Initialize-OfficeInstall -Context $Context
  if ($null -ne $prepared.Result) { return $prepared.Result }

  try {
    $process = Start-BackgroundExternal -FilePath $prepared.SetupPath -ArgumentList "/configure `"$($prepared.XmlPath)`""
  } catch {
    Write-SetupLog -Message 'Office setup could not be started' -Level ERROR -Data @{ error = $_.Exception.Message }
    return New-StepResult -Status Failed -Message 'Office setup could not be started'
  }
  $script:OfficeBackgroundProcess = $process

  # Without its start time the process cannot be told from a stranger with the same id after a
  # restart; Get-OfficeBackgroundProcess then treats it as gone (and office-finish takes over).
  $startUtc = $null
  try {
    $startUtc = ([datetime]$process.StartTime).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
  } catch {
    Write-SetupLog -Message 'The Office setup start time could not be read' -Level WARN -Data @{ processId = $process.Id; error = $_.Exception.Message }
  }

  $now = Get-Date
  $limit = [double]$Context.Config.timeoutsMinutes.office
  $languages = @($Context.Config.apps.office.languages) -join ', '
  Add-SetupActivity -Text "Microsoft 365 started installing in the background ($languages)"
  return New-StepResult -Status Done -Message 'Microsoft 365 installing in the background' -Data @{
    Background      = $true
    ProcessId       = [int]$process.Id
    ProcessStartUtc = $startUtc
    StartedAt       = $now.ToString('s', [Globalization.CultureInfo]::InvariantCulture)
    DeadlineAt      = $now.AddMinutes($limit).ToString('s', [Globalization.CultureInfo]::InvariantCulture)
  }
}

function ConvertTo-OfficeDateTime {
  # Private. A [datetime] from a Data value (a string in 's' or 'o' form, or already a datetime), or
  # $null when it is missing or does not parse. A trailing Z gives a UTC datetime.
  param([AllowNull()]$Value)

  if ($Value -is [datetime]) { return $Value }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $parsed = [datetime]::MinValue
  if ([datetime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $parsed }
  return $null
}

function Get-OfficeBackgroundProcess {
  <#
  .SYNOPSIS
    The background Office setup process recorded in the office step's Data, or $null. Never throws.
  .DESCRIPTION
    $script:OfficeBackgroundProcess when its Id equals Data.ProcessId (same process as the step that
    started it). Otherwise (after a restart or a crash) Get-Process -Id Data.ProcessId, accepted only
    when its start time is within 2 s of Data.ProcessStartUtc: Windows reuses process ids, and a
    stranger with Office's old id must never be waited on or killed. Its .Handle is touched so the
    ExitCode stays readable after it ends.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Data)

  try {
    if ($null -eq $Data['ProcessId']) { return $null }
    $wantedId = [int]$Data['ProcessId']
    $kept = $script:OfficeBackgroundProcess
    if ($null -ne $kept -and [int]$kept.Id -eq $wantedId) { return $kept }

    $recorded = ConvertTo-OfficeDateTime -Value $Data['ProcessStartUtc']
    if ($null -eq $recorded) { return $null }
    $found = @(Get-Process -Id $wantedId -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $found) { return $null }
    $gapSeconds = [math]::Abs((([datetime]$found.StartTime).ToUniversalTime() - $recorded.ToUniversalTime()).TotalSeconds)
    if ($gapSeconds -gt 2) {
      Write-SetupLog -Message 'A process has the old Office setup id but started at another time; not Office' -Data @{ processId = $wantedId }
      return $null
    }
    $null = $found.Handle
    return $found
  } catch {
    Write-SetupLog -Message 'The background Office setup process could not be checked' -Level WARN -Data @{ error = $_.Exception.Message }
    return $null
  }
}

function Save-OfficeWaitState {
  # Private. Saves the run state after a write to an Office step's Data; a failure is a WARN.
  param([Parameter(Mandatory)][hashtable]$Context)

  try {
    Save-RunState -State $Context.State -Root $Context.Root
  } catch {
    Write-SetupLog -Message 'The Microsoft 365 state could not be saved; continuing' -Level WARN -Data @{ error = $_.Exception.Message }
  }
}

function Wait-OfficeBackground {
  <#
  .SYNOPSIS
    Waits for a background Office setup that is still running, up to its deadline. Returns
    @{ Outcome = 'None' | 'Exited' | 'Killed' | 'Gone'; ExitCode = <int or $null> }. Never throws.
  .DESCRIPTION
    None: office is not in the plan, its Data has no Background, or Finished is already set; nothing is
    written. Otherwise the process (Get-OfficeBackgroundProcess):
      - not found: Data.Finished = $true, Outcome Gone (no code).
      - found: NOW shows 'Waiting for Microsoft 365 to finish before restarting' (Purpose Restart) or
        'Waiting for Microsoft 365 to finish' (Finish), with the wait timer (timeoutsMinutes.office since
        Data.StartedAt). It polls (Wait-SetupDelay, which ticks) until the process ends or the Clock
        reaches Data.DeadlineAt, then puts the NOW title back (the step's subtitle and provider stay).
        At the deadline HasExited is read once more: a setup that ended during the last poll is Ended,
        never killed.
        Ended: Data.ExitCode (when readable), Data.Finished, activity 'Microsoft 365 setup ended (exit
        <code>)', Outcome Exited. Deadline: Stop-ProcessTree, Data.KilledAtDeadline, Data.Finished,
        activity 'Microsoft 365 setup stopped at its <N> min limit', Outcome Killed.
    Every write goes to State.Steps['office'].Data and is saved (a failed save is a WARN).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)][ValidateSet('Restart', 'Finish')][string]$Purpose,
    [int]$PollMilliseconds = 1000,
    [scriptblock]$Clock = { Get-Date }
  )

  $none = @{ Outcome = 'None'; ExitCode = $null }
  $waiting = $false
  try {
    $runState = $Context.State
    if (@($runState.Plan) -notcontains 'office' -or $runState.Steps -isnot [System.Collections.IDictionary]) { return $none }
    $step = $runState.Steps['office']
    if ($step -isnot [System.Collections.IDictionary]) { return $none }
    $data = $step['Data']
    if ($data -isnot [System.Collections.IDictionary] -or $data['Background'] -ne $true -or $data['Finished'] -eq $true) { return $none }

    $process = Get-OfficeBackgroundProcess -Data $data
    if ($null -eq $process) {
      $data['Finished'] = $true
      Write-SetupLog -Message 'The background Office setup process is gone; its result is unknown' -Level WARN -Data @{ processId = $data['ProcessId']; purpose = $Purpose }
      Save-OfficeWaitState -Context $Context
      return @{ Outcome = 'Gone'; ExitCode = $null }
    }

    # Nothing may wait without a deadline: a missing DeadlineAt is rebuilt from StartedAt, else from now.
    $limit = [double]$Context.Config.timeoutsMinutes.office
    $startedAt = ConvertTo-OfficeDateTime -Value $data['StartedAt']
    $deadline = ConvertTo-OfficeDateTime -Value $data['DeadlineAt']
    if ($null -eq $deadline) {
      $from = if ($null -ne $startedAt) { $startedAt } else { [datetime](& $Clock) }
      $deadline = $from.AddMinutes($limit)
    }

    $title = if ($Purpose -eq 'Restart') { 'Waiting for Microsoft 365 to finish before restarting' } else { 'Waiting for Microsoft 365 to finish' }
    Set-SetupNow -Title $title
    if ($null -ne $startedAt) { Enter-SetupWait -LimitMinutes $limit -StartedAt $startedAt } else { Enter-SetupWait -LimitMinutes $limit }
    $waiting = $true
    Write-SetupLog -Message 'Waiting for the background Office setup' -Data @{ purpose = $Purpose; processId = $data['ProcessId']; deadline = $deadline.ToString('s', [Globalization.CultureInfo]::InvariantCulture) }

    $timedOut = $false
    while (-not $process.HasExited) {
      if ((& $Clock) -ge $deadline) {
        # It may have ended during the last poll: look once more, and never kill a setup that is done.
        $timedOut = -not $process.HasExited
        break
      }
      Wait-SetupDelay -Milliseconds $PollMilliseconds
    }

    if ($timedOut) {
      Stop-ProcessTree -ProcessId ([int]$data['ProcessId'])
      $data['KilledAtDeadline'] = $true
      $data['Finished'] = $true
      Write-SetupLog -Message 'The background Office setup reached its deadline; process tree stopped' -Level WARN -Data @{ processId = $data['ProcessId']; limitMinutes = $limit }
      Add-SetupActivity -Text ('Microsoft 365 setup stopped at its {0} min limit' -f $limit)
      Save-OfficeWaitState -Context $Context
      return @{ Outcome = 'Killed'; ExitCode = $null }
    }

    $code = $null
    try {
      $raw = $process.ExitCode
      if ($null -ne $raw) { $code = [int]$raw }
    } catch {
      Write-SetupLog -Message 'The Office setup exit code could not be read' -Level WARN -Data @{ processId = $data['ProcessId']; error = $_.Exception.Message }
    }
    if ($null -ne $code) { $data['ExitCode'] = $code }
    $data['Finished'] = $true
    $codeText = if ($null -ne $code) { [string]$code } else { 'unknown' }
    Write-SetupLog -Message 'The background Office setup ended' -Data @{ processId = $data['ProcessId']; exitCode = $codeText }
    Add-SetupActivity -Text "Microsoft 365 setup ended (exit $codeText)"
    Save-OfficeWaitState -Context $Context
    return @{ Outcome = 'Exited'; ExitCode = $code }
  } catch {
    Write-SetupLog -Message 'Waiting for the background Office setup failed; continuing' -Level WARN -Data @{ purpose = $Purpose; error = $_.Exception.Message }
    return $none
  } finally {
    if ($waiting) {
      Exit-SetupWait
      Set-SetupNow -Title $null
    }
  }
}

function Invoke-StepOfficeFinish {
  <#
  .SYNOPSIS
    The office-finish step (after windows-update): reports the background Office setup's result, then
    puts the Office desktop shortcuts on the public desktop.
  .DESCRIPTION
    Resolve-OfficeFinish decides the result:
    1. office not Done -> Done('Nothing to finish: Microsoft 365 was not started') (office's own result
       carries any failure).
    2. office Done without Data.Background (it was already installed) -> Done('Office already installed').
    3. Wait-OfficeBackground -Purpose Finish. Its Data.Finished must then be set (every ending the wait
       decides sets it); when it is not, the wait failed unexpectedly and the setup.exe may still be
       alive: Failed('Office setup did not complete'), and nothing is installed beside it. Otherwise,
       from the office Data: KilledAtDeadline -> Failed('Office setup timed out'); ExitCode 0 ->
       Done('Office installed'); 3010/1641 -> Done('Office installed (restart pending)'), with Reboot
       'Now' only when this wait saw the process end (a code stored by a restart wait was followed by that
       restart: no extra one, R17a); any other code -> Failed('Office setup exit <code>'), no retry.
    4. No code and no marker: the product in ProductReleaseIds -> Done('Office installed'). Otherwise ONE
       foreground install (Initialize-OfficeInstall + Invoke-OfficeForegroundInstall), recorded first as
       Data.ForegroundTried (saved), so a crash during it is never retried; with ForegroundTried already
       set -> Failed('Office setup did not complete').
    On every Done where Office is there (paths 2, 3 and 4, including 'Office already installed'; not path 1
    and not a Failed) Add-OfficeDesktopShortcuts runs: the names it made go to the activity feed
    ('Desktop shortcuts: Word, Excel'), a failure adds the Note 'Office desktop shortcuts could not be
    created'. The step stays Done either way.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $result = Resolve-OfficeFinish -Context $Context

  $office = $Context.State.Steps['office']
  if ($result.Status -eq 'Done' -and $null -ne $office -and [string]$office['Status'] -eq 'Done') {
    $shortcuts = Add-OfficeDesktopShortcuts
    if (@($shortcuts.Created).Count -gt 0) {
      Add-SetupActivity -Text ('Desktop shortcuts: ' + (@($shortcuts.Created) -join ', '))
    }
    if ($shortcuts.Failed) {
      $result.Notes = [string[]](@($result.Notes) + 'Office desktop shortcuts could not be created')
    }
  }
  return $result
}

function Resolve-OfficeFinish {
  # Private. The result of the office-finish step, paths 1-4 of Invoke-StepOfficeFinish (no shortcuts).
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $steps = $Context.State.Steps
  $office = $steps['office']
  if ($null -eq $office -or [string]$office['Status'] -ne 'Done') {
    return New-StepResult -Status Done -Message 'Nothing to finish: Microsoft 365 was not started'
  }
  $data = $office['Data']
  if ($data -isnot [System.Collections.IDictionary] -or $data['Background'] -ne $true) {
    return New-StepResult -Status Done -Message 'Office already installed'
  }

  $wait = Wait-OfficeBackground -Context $Context -Purpose Finish

  # Each ending the wait decides (Exited, Killed, Gone) sets Finished, and a result a restart wait stored
  # earlier has it set already. Without it the wait decided nothing (an unexpected error inside it, or a
  # lookup that failed): the background setup.exe may still be running, so no foreground install may
  # start beside it, and the result cannot be read from the Data.
  if ($data['Finished'] -ne $true) {
    Write-SetupLog -Message 'The background Office setup result is unknown and the setup may still be running; not installing again' -Level WARN -Data @{ outcome = [string]$wait.Outcome }
    return New-StepResult -Status Failed -Message 'Office setup did not complete'
  }
  if ($data['KilledAtDeadline'] -eq $true) { return New-StepResult -Status Failed -Message 'Office setup timed out' }
  if ($null -ne $data['ExitCode']) {
    $code = [int]$data['ExitCode']
    if ($code -eq 0) { return New-StepResult -Status Done -Message 'Office installed' }
    if ($code -in 3010, 1641) {
      $reboot = if ($wait.Outcome -eq 'Exited') { 'Now' } else { 'None' }
      return New-StepResult -Status Done -Message 'Office installed (restart pending)' -Reboot $reboot
    }
    return New-StepResult -Status Failed -Message "Office setup exit $code"
  }

  $choice = [string]$Context.State.Choices.Office
  $product = $Context.Config.apps.office.products.PSObject.Properties[$choice]
  if ($product -and (Test-OfficeProductInstalled -ProductId ([string]$product.Value))) {
    return New-StepResult -Status Done -Message 'Office installed'
  }

  $finish = $steps['office-finish']
  if ($null -ne $finish) {
    if ($finish['Data'] -isnot [System.Collections.IDictionary]) { $finish['Data'] = @{} }
    if ($finish['Data']['ForegroundTried'] -eq $true) { return New-StepResult -Status Failed -Message 'Office setup did not complete' }
    $finish['Data']['ForegroundTried'] = $true
  }
  Save-OfficeWaitState -Context $Context
  Write-SetupLog -Message 'The background Office setup left no result; installing once in the foreground' -Level WARN

  $prepared = Initialize-OfficeInstall -Context $Context
  if ($null -ne $prepared.Result) { return $prepared.Result }
  return Invoke-OfficeForegroundInstall -Context $Context -Prepared $prepared
}

# --- desktop shortcuts (v2 spec 4.7) -------------------------------------------------------------------

function Get-OfficeExeFolder {
  <#
  .SYNOPSIS
    Private. The folder of the Click-to-Run Office programs: InstallationPath from the Click-to-Run
    registry key plus root\Office16, or $null when the key or the value is missing.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $configuration = Get-ItemProperty -LiteralPath $script:OfficeReleaseKey -Name InstallationPath -ErrorAction SilentlyContinue
  $installPath = if ($configuration) { [string]$configuration.InstallationPath } else { '' }
  if ([string]::IsNullOrWhiteSpace($installPath)) { return $null }
  return (Join-Path $installPath.Trim() 'root\Office16')
}

function New-DesktopShortcut {
  <#
  .SYNOPSIS
    Private. Writes one .lnk file: Path -> TargetPath, with the target's folder as the working folder.
    Throws when the shortcut cannot be saved.
  .DESCRIPTION
    The only WScript.Shell touchpoint in the project. Tests always mock it, so no test ever writes a
    shortcut (the real one is checked by hand, docs\testing.md).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$TargetPath
  )

  $shell = $null
  $link = $null
  try {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $TargetPath
    $link.WorkingDirectory = Split-Path -Parent $TargetPath
    $link.Save()
  } finally {
    if ($null -ne $link) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
    if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
  }
}

function Add-OfficeDesktopShortcuts {
  <#
  .SYNOPSIS
    Puts Word, Excel, PowerPoint and Outlook shortcuts on the public desktop. Returns
    @{ Created = <names of the shortcuts made>; Failed = <bool> }. Never throws.
  .DESCRIPTION
    DesktopFolder defaults to the public desktop of all users (CommonDesktopDirectory) and ExeFolder to
    Get-OfficeExeFolder, both resolved here. Per app in $script:OfficeShortcutApps: a <Desktop>\<Name>.lnk
    that exists is left alone (idempotent); an executable missing from ExeFolder is skipped (logged:
    Outlook may be excluded); otherwise New-DesktopShortcut. A shortcut that cannot be made is a WARN and
    Failed = $true, and the others are still tried. No Office folder, or no desktop folder, is Failed.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [string]$DesktopFolder,
    [string]$ExeFolder
  )

  $created = New-Object 'System.Collections.Generic.List[string]'
  $failed = $false
  try {
    if ([string]::IsNullOrWhiteSpace($DesktopFolder)) { $DesktopFolder = [Environment]::GetFolderPath('CommonDesktopDirectory') }
    if ([string]::IsNullOrWhiteSpace($ExeFolder)) { $ExeFolder = Get-OfficeExeFolder }
    if ([string]::IsNullOrWhiteSpace($DesktopFolder) -or [string]::IsNullOrWhiteSpace($ExeFolder)) {
      Write-SetupLog -Message 'The Office desktop shortcuts need the public desktop and the Office folder; one is unknown' -Level WARN -Data @{ desktop = $DesktopFolder; office = $ExeFolder }
      return @{ Created = $created.ToArray(); Failed = $true }
    }

    foreach ($name in $script:OfficeShortcutApps.Keys) {
      $link = Join-Path $DesktopFolder "$name.lnk"
      $exe = Join-Path $ExeFolder ([string]$script:OfficeShortcutApps[$name])
      if (Test-Path -LiteralPath $link) { continue }
      if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-SetupLog -Message "No $name shortcut: its program is not installed" -Data @{ expected = $exe }
        continue
      }
      try {
        New-DesktopShortcut -Path $link -TargetPath $exe
        $created.Add([string]$name)
      } catch {
        $failed = $true
        Write-SetupLog -Message "The $name desktop shortcut could not be created" -Level WARN -Data @{ path = $link; error = $_.Exception.Message }
      }
    }
  } catch {
    $failed = $true
    Write-SetupLog -Message 'The Office desktop shortcuts could not be created' -Level WARN -Data @{ error = $_.Exception.Message }
  }
  return @{ Created = $created.ToArray(); Failed = $failed }
}
