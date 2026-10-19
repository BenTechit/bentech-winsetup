# src/Steps/DefaultBrowser.ps1
# Step 11 (spec 8.3 and 12): makes Chrome the default browser through the DefaultAssociationsConfiguration
# policy, plus the readers Finalize and the final screen use to check the result. Needs StepResult.ps1,
# Logging.ps1 and Apps.ps1 (Test-ChromeInstalled, Write-TextFileUtf8NoBom); the bundle holds every file.
#
# Windows 11 has no reliable zero-click way to set the default browser (spec 12). This step writes a
# default-associations file and points the policy at it; it applies at the next sign-in with
# Suggested="true", so the customer can still change browsers later. Whether it works on a PC that
# is not domain-joined is spike #1; Finalize verifies and falls back to a manual hint.

$script:DefaultAssociationsPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$script:DefaultAssociationsPolicyName = 'DefaultAssociationsConfiguration'
$script:UrlAssociationsHttps = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https'
$script:RegisteredApplicationsKey = 'HKLM:\SOFTWARE\RegisteredApplications'

# The type that wraps shlwapi!AssocQueryString is compiled once per process, on first use, under a
# name that cannot clash with an earlier compile in the same process.
$script:ShellAssocType = $null

function New-DefaultAssociationsXml {
  <#
  .SYNOPSIS
    The default-associations XML: .htm, .html, http and https (in that order) all open with ProgId,
    Version="1" and Suggested="true" (offered once, never forced). Values are XML-escaped; CRLF breaks.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$ProgId,
    [Parameter(Mandatory)][string]$ApplicationName
  )

  $progIdText = [Security.SecurityElement]::Escape($ProgId)
  $nameText = [Security.SecurityElement]::Escape($ApplicationName)
  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add('<?xml version="1.0" encoding="UTF-8"?>')
  $lines.Add('<DefaultAssociations>')
  foreach ($identifier in '.htm', '.html', 'http', 'https') {
    $lines.Add(('  <Association Identifier="{0}" ProgId="{1}" ApplicationName="{2}" Version="1" Suggested="true" />' -f $identifier, $progIdText, $nameText))
  }
  $lines.Add('</DefaultAssociations>')
  return ($lines.ToArray() -join "`r`n")
}

function Get-DefaultAssociationsPath {
  <#
  .SYNOPSIS
    Where the default-associations XML lives: %ProgramData%\BenTech\DefaultAssociations.xml.
  .DESCRIPTION
    Windows reads the DefaultAssociationsConfiguration file at sign-in, in the signed-in user's own
    session. The working folder (C:\BenTech\Setup) is locked to Administrators and SYSTEM, and a
    UAC-filtered administrator token (Administrators is deny-only) or a standard user cannot read
    it, so the policy would silently do nothing. A subfolder of ProgramData inherits read access for
    Users (ruling R18). Finalize uses this function to delete the file again.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  return (Join-Path $env:ProgramData 'BenTech\DefaultAssociations.xml')
}

function Invoke-StepDefaultBrowser {
  <#
  .SYNOPSIS
    Step 11: writes the associations XML (Get-DefaultAssociationsPath) and points the
    DefaultAssociationsConfiguration policy at it. Done('Applies at next sign-in') / Skipped.
  .DESCRIPTION
    The XML goes under %ProgramData%\BenTech, NOT into the admin-only working folder, so the signed-in
    user can read it (ruling R18). The BenTech folder is created when it is missing and its ACL is left
    as inherited. The XML is UTF-8 without a BOM. The policy value is a REG_SZ holding the file's path;
    its key is created first when it is missing (an existing key is never recreated). The default browser is
    best effort (spec 12, ruling R17b): Chrome missing is Skipped('Chrome not installed'), and a file
    or registry write that fails is Skipped('Default browser policy could not be set: <short reason>'),
    logged at WARN. The report shows it yellow and the final screen's "press B" hint covers the
    customer. The short reason is the first line of the error, cut to 120 characters.
    The Done result carries Data.RebootCountAtSet (State.RebootCount) and Data.SetAtUtc (ISO 8601,
    UTC), which Finalize uses to decide whether anybody has signed in since the policy was set
    (ruling R16).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  if (-not (Test-ChromeInstalled)) { return New-StepResult -Status Skipped -Message 'Chrome not installed' }

  $xmlPath = $null
  try {
    $xmlPath = Get-DefaultAssociationsPath
    Write-TextFileUtf8NoBom -Path $xmlPath -Text (New-DefaultAssociationsXml -ProgId 'ChromeHTML' -ApplicationName 'Google Chrome')
    # -ErrorAction Stop: a refused registry write is a non-terminating error, which would skip the catch
    # and report Done for a policy that was never set (final review I1).
    if (-not (Test-Path -LiteralPath $script:DefaultAssociationsPolicyKey)) {
      New-Item -Path $script:DefaultAssociationsPolicyKey -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -LiteralPath $script:DefaultAssociationsPolicyKey -Name $script:DefaultAssociationsPolicyName -Value $xmlPath -PropertyType String -Force -ErrorAction Stop | Out-Null
  } catch {
    Write-SetupLog -Message 'Default browser policy could not be set' -Level WARN -Data @{ file = $xmlPath; error = $_.Exception.Message }
    $reason = ([string]$_.Exception.Message -split "`r`n|`r|`n")[0].Trim()
    if ([string]::IsNullOrEmpty($reason)) { $reason = 'unknown error' }
    if ($reason.Length -gt 120) { $reason = $reason.Substring(0, 117) + '...' }
    return New-StepResult -Status Skipped -Message "Default browser policy could not be set: $reason"
  }

  return New-StepResult -Status Done -Message 'Applies at next sign-in' -Data @{
    RebootCountAtSet = [int]$Context.State.RebootCount
    SetAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
  }
}

function Resolve-DefaultBrowserProgId {
  <#
  .SYNOPSIS
    The first non-empty of the UserChoiceLatest ProgId and the legacy UserChoice ProgId, or $null.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()][AllowEmptyString()][string]$LatestProgId,
    [AllowNull()][AllowEmptyString()][string]$LegacyProgId
  )

  foreach ($candidate in $LatestProgId, $LegacyProgId) {
    if (-not [string]::IsNullOrEmpty($candidate)) { return $candidate }
  }
  return $null
}

function Get-ShellDefaultBrowserProgId {
  <#
  .SYNOPSIS
    The ProgId Windows itself reports for the https protocol (shlwapi!AssocQueryString with
    ASSOCF_IS_PROTOCOL and ASSOCSTR_PROGID), or $null when the shell has no answer. Read-only.
  .DESCRIPTION
    This is the effective answer: it follows whatever Windows really uses, including the
    UserChoiceLatest hash scheme, instead of guessing registry layouts. Throws when the wrapper type
    cannot be compiled; Get-DefaultBrowserProgId catches that and uses the registry instead.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  if (-not $script:ShellAssocType) {
    $source = @'
[System.Runtime.InteropServices.DllImport("shlwapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
private static extern uint AssocQueryString(uint flags, uint str, string pszAssoc, string pszExtra, System.Text.StringBuilder pszOut, ref uint pcchOut);

public static string Query(string assoc)
{
    uint size = 512;
    System.Text.StringBuilder buffer = new System.Text.StringBuilder((int)size);
    // 0x1000 = ASSOCF_IS_PROTOCOL, 20 = ASSOCSTR_PROGID; 0 = S_OK.
    uint hr = AssocQueryString(0x1000, 20, assoc, null, buffer, ref size);
    return hr == 0 ? buffer.ToString() : null;
}
'@
    $script:ShellAssocType = Add-Type -MemberDefinition $source -Namespace 'BenTechSetup' -Name ('ShellAssoc' + [guid]::NewGuid().ToString('N')) -PassThru
  }
  $type = $script:ShellAssocType
  return [string]$type::Query('https')
}

function Read-RegistryStringValue {
  # Private. One registry value as a string, or $null when the key or value is missing or unreadable.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name
  )

  try {
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    if ($null -eq $item) { return $null }
    $value = $item.$Name
    if ($null -eq $value) { return $null }
    return [string]$value
  } catch {
    return $null
  }
}

function Get-DefaultBrowserProgId {
  <#
  .SYNOPSIS
    The ProgId of the current default browser for https (e.g. ChromeHTML, MSEdgeHTM), or $null.
    Read-only; never throws.
  .DESCRIPTION
    First the shell's own answer (Get-ShellDefaultBrowserProgId). When that fails or is empty, the
    registry under HKCU\...\UrlAssociations\https: the ProgId value of the UserChoiceLatest\ProgId
    key, then of the UserChoiceLatest key, then of the legacy UserChoice key.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  try {
    $shell = $null
    try {
      $shell = Get-ShellDefaultBrowserProgId
    } catch {
      Write-SetupLog -Message 'The shell could not report the default browser; reading the registry' -Level WARN -Data @{ error = $_.Exception.Message }
    }
    if (-not [string]::IsNullOrWhiteSpace($shell)) { return ([string]$shell).Trim() }

    $latest = Read-RegistryStringValue -Path "$($script:UrlAssociationsHttps)\UserChoiceLatest\ProgId" -Name 'ProgId'
    if ([string]::IsNullOrEmpty($latest)) { $latest = Read-RegistryStringValue -Path "$($script:UrlAssociationsHttps)\UserChoiceLatest" -Name 'ProgId' }
    $legacy = Read-RegistryStringValue -Path "$($script:UrlAssociationsHttps)\UserChoice" -Name 'ProgId'
    return (Resolve-DefaultBrowserProgId -LatestProgId $latest -LegacyProgId $legacy)
  } catch {
    Write-SetupLog -Message 'The default browser could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
    return $null
  }
}

function Get-ChromeRegisteredAppName {
  <#
  .SYNOPSIS
    The name Chrome registered itself under in HKLM\SOFTWARE\RegisteredApplications (the value name
    that starts with 'Google Chrome'), else 'Google Chrome'. Never throws.
  .DESCRIPTION
    The final screen opens ms-settings:defaultapps?registeredAppMachine=<this name>, which needs the
    exact registered name.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  try {
    $item = Get-ItemProperty -LiteralPath $script:RegisteredApplicationsKey -ErrorAction Stop
    $names = @($item.PSObject.Properties | Where-Object { $_.Name -like 'Google Chrome*' } | ForEach-Object { [string]$_.Name })
    if ($names -contains 'Google Chrome') { return 'Google Chrome' }
    if ($names.Count -gt 0) { return $names[0] }
  } catch {
    Write-SetupLog -Message 'RegisteredApplications could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
  }
  return 'Google Chrome'
}
