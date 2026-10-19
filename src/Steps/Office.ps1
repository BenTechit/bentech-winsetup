# src/Steps/Office.ps1
# Step 10 (spec 8.3): Microsoft Office through the Office Deployment Tool (ODT). Needs StepResult.ps1,
# Logging.ps1, Process.ps1, Download.ps1, Config.ps1 (Get-Signers), Winget.ps1 (Invoke-WingetInstall) and
# Apps.ps1 (Write-TextFileUtf8NoBom); the bundle holds every file.
#
# The ODT comes from winget (Microsoft.OfficeDeploymentTool); when winget cannot provide it, the
# self-extracting ODT is scraped from Microsoft's download page. Either way the setup.exe is
# signature-checked against the Microsoft signer before it runs.

$script:OfficeReleaseKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'

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

function Invoke-StepOffice {
  <#
  .SYNOPSIS
    Step 10: installs Office (BUSINESS = O365BusinessRetail, HOME = O365HomePremRetail) with the ODT.
  .DESCRIPTION
    Choices.Office OFF is Skipped('Office not selected') (the plan leaves the step out in that case;
    this is a safety net). A product already listed in the Click-to-Run ProductReleaseIds is
    Done('Office already installed'). Otherwise Get-OdtSetupPath finds the ODT, setup.exe is
    signature-checked against the Microsoft signer, the configuration is written UTF-8 without a BOM to
    <Downloads>\office.xml and `setup.exe /configure "<xml>"` runs with the configured office timeout.
    Exit code 0 is Done; any other is Failed('Office setup exit <code>'); a timeout is
    Failed('Office setup timed out').
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $choice = [string]$Context.State.Choices.Office
  if ([string]::IsNullOrEmpty($choice) -or $choice -eq 'OFF') { return New-StepResult -Status Skipped -Message 'Office not selected' }

  $office = $Context.Config.apps.office
  $product = $office.products.PSObject.Properties[$choice]
  if (-not $product) { return New-StepResult -Status Failed -Message "Office choice '$choice' has no product in the config" }
  $productId = [string]$product.Value

  $installed = Get-ItemProperty -LiteralPath $script:OfficeReleaseKey -Name ProductReleaseIds -ErrorAction SilentlyContinue
  if ($installed -and (Test-OfficeInstalled -ProductReleaseIds ([string]$installed.ProductReleaseIds) -ProductId $productId)) {
    return New-StepResult -Status Done -Message 'Office already installed'
  }

  $odt = Get-OdtSetupPath -Context $Context
  if (-not $odt.Path) { return New-StepResult -Status Failed -Message $odt.Failure }

  $signers = Get-Signers -Config $Context.Config -Key ([string]$office.signer)
  if (-not (Test-FileSignature -Path $odt.Path -AllowedSigners $signers)) {
    return New-StepResult -Status Failed -Message 'Office setup.exe signature check failed'
  }

  $xmlPath = Join-Path $Context.DownloadDir 'office.xml'
  try {
    $xml = New-OfficeConfigXml -ProductId $productId -Languages @($office.languages) -ExcludeApps @($office.excludeApps) -Channel ([string]$office.channel) -Edition ([string]$office.edition)
    Write-TextFileUtf8NoBom -Path $xmlPath -Text $xml
  } catch {
    Write-SetupLog -Message 'Office configuration XML could not be written' -Level ERROR -Data @{ path = $xmlPath; error = $_.Exception.Message }
    return New-StepResult -Status Failed -Message 'Office configuration could not be written'
  }

  try {
    $run = Invoke-External -FilePath $odt.Path -ArgumentList "/configure `"$xmlPath`"" -TimeoutMinutes ([double]$Context.Config.timeoutsMinutes.office)
  } catch {
    Write-SetupLog -Message 'Office setup could not be started' -Level ERROR -Data @{ error = $_.Exception.Message }
    return New-StepResult -Status Failed -Message 'Office setup could not be started'
  }
  if ($run.TimedOut) { return New-StepResult -Status Failed -Message 'Office setup timed out' }
  if ($run.ExitCode -ne 0) { return New-StepResult -Status Failed -Message "Office setup exit $($run.ExitCode)" }
  return New-StepResult -Status Done -Message 'Office installed'
}
