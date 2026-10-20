# src/Steps/CraftApps.ps1
# The Craft apps (craft spec 3.3): ArtCraft's free office suite (WordCraft, GridCraft, DeckCraft, PdfCraft)
# and the ArtCraft Launcher, each installed from the MSI of the latest release of its GitHub repo. The list
# of items, their repos and the trusted signer live in config.json (apps.craft, signers.craft).
# This file holds the pure helpers and the release lookup:
#   ConvertTo-CraftArch       processor name -> the x64 / arm64 / x86 of the release asset names
#   Select-CraftAsset         the one MSI of that processor in a release, its version and its checksum list
#   Get-Sha256FromSums        the SHA-256 of one file in a SHA256SUMS.txt
#   ConvertTo-CraftVersion    version text -> [version], and Test-CraftVersionCurrent (installed >= release)
#   Get-WebStatusCode         the HTTP status behind a failed download
#   Get-CraftRelease          GET releases/latest, one retry when GitHub answers 403 or 429
# Needs StepResult.ps1, Logging.ps1, Activity.ps1, Process.ps1, Download.ps1, Config.ps1 and Report.ps1; the
# bundle holds every file.
#
# Nothing here is localized: GitHub's JSON and the checksum file are read as data, and a download problem is
# told apart by its HTTP status, never by its message.

function ConvertTo-CraftArch {
  <#
  .SYNOPSIS
    The processor as the release asset names spell it: 'ARM64' is 'arm64', 'x86' is 'x86', anything
    else (x64, AMD64, empty) is 'x64'. Case-insensitive. Never throws.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Arch)

  if ($Arch -ieq 'ARM64') { return 'arm64' }
  if ($Arch -ieq 'x86') { return 'x86' }
  return 'x64'
}

function Select-CraftAsset {
  <#
  .SYNOPSIS
    The installer of one app in a release, or $null: @{ Name; Url; Version; SumsUrl }.
  .DESCRIPTION
    Release is the parsed answer of releases/latest; only assets[].name and assets[].browser_download_url
    are read, and an asset lacking either is ignored. The asset name must match
    ^<Prefix>-<version>-windows-<Arch>.msi, case-insensitive, with Prefix and Arch taken literally and
    <version> = [0-9][0-9A-Za-z.+-]*. Exactly one asset must match: none gives $null, and so do two or
    more (logged at WARN), because a guess between installers is worse than no install. Version is the
    <version> part of the name. SumsUrl is the link of the asset named exactly SHA256SUMS.txt
    (case-sensitive), $null when there is none. Never throws.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][AllowNull()]$Release,
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory)][string]$Arch
  )

  $assets = @($Release.assets | Where-Object {
    $null -ne $_ -and -not [string]::IsNullOrEmpty([string]$_.name) -and -not [string]::IsNullOrEmpty([string]$_.browser_download_url)
  })

  # \z, not $: a name that ends in a line break is not an installer name.
  $pattern = '^' + [regex]::Escape($Prefix) + '-([0-9][0-9A-Za-z.+-]*)-windows-' + [regex]::Escape($Arch) + '\.msi\z'
  $found = New-Object 'System.Collections.Generic.List[hashtable]'
  foreach ($asset in $assets) {
    $match = [regex]::Match([string]$asset.name, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
      $found.Add(@{ Name = [string]$asset.name; Url = [string]$asset.browser_download_url; Version = $match.Groups[1].Value })
    }
  }
  if ($found.Count -eq 0) { return $null }
  if ($found.Count -gt 1) {
    Write-SetupLog -Message 'More than one installer matches in the release; none chosen' -Level WARN -Data @{ prefix = $Prefix; arch = $Arch; names = @($found | ForEach-Object { $_['Name'] }) }
    return $null
  }

  $sumsUrl = $null
  foreach ($asset in $assets) {
    if ([string]$asset.name -ceq 'SHA256SUMS.txt') { $sumsUrl = [string]$asset.browser_download_url; break }
  }
  return @{ Name = $found[0]['Name']; Url = $found[0]['Url']; Version = $found[0]['Version']; SumsUrl = $sumsUrl }
}

function Get-Sha256FromSums {
  <#
  .SYNOPSIS
    The SHA-256 (lower case) of FileName in the text of a SHA256SUMS.txt, or $null. Never throws.
  .DESCRIPTION
    Lines end in LF or CRLF. A line is '<64 hex digits>' + a space + a space or '*' + '<file name>'. The
    name is compared exactly (case-sensitive), so a longer or differently spelled name is another file.
    The answer is the hash only when every line that names the file carries the same one; no line, or
    two different hashes, give $null.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory)][string]$FileName
  )

  if ([string]::IsNullOrEmpty($Text)) { return $null }
  $hashes = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in ($Text -split '\r?\n')) {
    $match = [regex]::Match($line, '^([0-9A-Fa-f]{64}) [ *](.+?)\s*$')
    if (-not $match.Success -or $match.Groups[2].Value -cne $FileName) { continue }
    $hash = $match.Groups[1].Value.ToLowerInvariant()
    if (-not $hashes.Contains($hash)) { $hashes.Add($hash) }
  }
  if ($hashes.Count -ne 1) { return $null }
  return $hashes[0]
}

function ConvertTo-CraftVersion {
  <#
  .SYNOPSIS
    The leading number of a version text as a [version] of four parts, or $null. Never throws.
  .DESCRIPTION
    Reads v?<n>[.<n>[.<n>[.<n>]]] at the start (after trimming) and pads it to four parts with .0, so
    '0.8.0', 'v0.8.0' and '0.8.0.0' are the same version. Anything after it (-beta.2) is ignored. No
    leading number, or a number too big for a version part, gives $null.
  #>
  [CmdletBinding()]
  [OutputType([version])]
  param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $match = [regex]::Match($Text.Trim(), '^v?([0-9]+(\.[0-9]+){0,3})', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $match.Success) { return $null }
  $parts = @($match.Groups[1].Value -split '\.')
  while ($parts.Count -lt 4) { $parts += '0' }
  $version = $null
  if ([version]::TryParse(($parts -join '.'), [ref]$version)) { return $version }
  return $null
}

function Test-CraftVersionCurrent {
  <#
  .SYNOPSIS
    $true only when both versions can be read and Installed is the same as Available or newer
    (an installed app is never downgraded). Any doubt is $false, so the app is installed. Never throws.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Installed,
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Available
  )

  $installedVersion = ConvertTo-CraftVersion -Text $Installed
  $availableVersion = ConvertTo-CraftVersion -Text $Available
  if ($null -eq $installedVersion -or $null -eq $availableVersion) { return $false }
  return ($installedVersion -ge $availableVersion)
}

function Get-WebStatusCode {
  <#
  .SYNOPSIS
    The HTTP status code behind a failed download, or 0 when no HTTP answer is attached. Never throws.
  .DESCRIPTION
    Walks the exception and its InnerException chain (the download helpers wrap the WebException in a
    MethodInvocationException and that in their own "download failed after <n> attempts" exception) and
    takes the status of the first WebException that carries an HttpWebResponse. A name that did not
    resolve, a refused connection and a timeout have no response: 0.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param([Parameter(Mandatory)][AllowNull()][Exception]$Exception)

  $current = $Exception
  while ($null -ne $current) {
    if ($current -is [Net.WebException] -and $current.Response -is [Net.HttpWebResponse]) {
      return [int]$current.Response.StatusCode
    }
    $current = $current.InnerException
  }
  return 0
}

function Get-CraftRelease {
  <#
  .SYNOPSIS
    The latest release of a GitHub repo (owner/name) as the parsed JSON of releases/latest.
  .DESCRIPTION
    GitHub allows 60 lookups per hour per IP, and one laptop needs five. A 403 or 429 gets one retry
    after Wait-SetupDelay -Seconds 60 (the setup screen stays alive meanwhile); a second one throws
    'GitHub busy - try again later'. Any other failure, and an answer that is not a JSON object, throws
    'release lookup failed'. The detail of each failure is logged at WARN; the thrown message stays short
    because it ends up on the report.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$Repo)

  $url = "https://api.github.com/repos/$Repo/releases/latest"
  $text = $null
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      $text = Get-RemoteText -Url $url
      break
    } catch {
      $status = Get-WebStatusCode -Exception $_.Exception
      $detail = @{ repo = $Repo; attempt = $attempt; status = $status; error = $_.Exception.Message }
      if ($status -ne 403 -and $status -ne 429) {
        Write-SetupLog -Message 'Release lookup failed' -Level WARN -Data $detail
        throw 'release lookup failed'
      }
      if ($attempt -ge 2) {
        Write-SetupLog -Message 'GitHub is still rate limiting the release lookup; giving up' -Level WARN -Data $detail
        throw 'GitHub busy - try again later'
      }
      Write-SetupLog -Message 'GitHub is rate limiting the release lookup; trying once more in 60 s' -Level WARN -Data $detail
      Wait-SetupDelay -Seconds 60
    }
  }

  $release = $null
  $parseError = $null
  try {
    $release = ConvertFrom-Json -InputObject $text -ErrorAction Stop
  } catch {
    $parseError = $_.Exception.Message
  }
  # Not -is [pscustomobject]: that is true for a string and for an array too.
  if ($release -isnot [Management.Automation.PSCustomObject]) {
    Write-SetupLog -Message 'Release lookup answered something that is not a release' -Level WARN -Data @{ repo = $Repo; error = $parseError }
    throw 'release lookup failed'
  }
  return $release
}
