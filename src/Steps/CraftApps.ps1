# src/Steps/CraftApps.ps1
# The Craft apps (craft spec 3.3): ArtCraft's free office suite (WordCraft, GridCraft, DeckCraft, PdfCraft)
# and the ArtCraft Launcher, each installed from the MSI of the latest release of its GitHub repo. The list
# of items, their repos and the trusted signer live in config.json (apps.craft, signers.craft).
# The pure helpers and the release lookup:
#   ConvertTo-CraftArch       processor name -> the x64 / arm64 / x86 of the release asset names
#   Select-CraftAsset         the one MSI of that processor in a release, its version and its checksum list
#   Get-Sha256FromSums        the SHA-256 of one file in a SHA256SUMS.txt
#   ConvertTo-CraftVersion    version text -> [version], and Test-CraftVersionCurrent (installed >= release)
#   Get-WebStatusCode         the HTTP status behind a failed download
#   Get-CraftRelease          GET releases/latest, one retry when GitHub answers 403 or 429
# The step (catalog id craft-apps, only when Choices.Office is CRAFT):
#   Install-CraftItem         one item: look up, skip when current, download, checksum, signer, msiexec
#   Add-CraftShortcut         the item's desktop shortcut with its familiar name (Word, Excel, ...)
#   Invoke-StepCraftApps      every item in config order, one activity line each
# Needs StepResult.ps1, Logging.ps1, Activity.ps1, Process.ps1, Download.ps1, Config.ps1 and Report.ps1; the
# bundle holds every file.
#
# Nothing here is localized: GitHub's JSON and the checksum file are read as data, and a download problem is
# told apart by its HTTP status, never by its message. The step writes nothing to the console: the progress
# screen shows its NOW sub-titles and activity lines.

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

# --- the step --------------------------------------------------------------------------------------------

function New-CraftItemFailure {
  # Private. The Failed result of Install-CraftItem, logged at WARN with the item, its version and the reason.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
    [Parameter(Mandatory)][string]$Reason
  )

  Write-SetupLog -Message 'Craft item not installed' -Level WARN -Data @{ item = $Name; version = $Version; reason = $Reason }
  return @{ Status = 'Failed'; Version = $Version; Reason = $Reason }
}

function Install-CraftItem {
  <#
  .SYNOPSIS
    Installs one item of apps.craft.items from the MSI of its repo's latest release, silently.
    Returns @{ Status = Installed | Current | Failed; Version; Reason }. Never throws.
  .DESCRIPTION
    Each phase shows its NOW sub-title first (the screen prints 'Craft apps - <sub-title>'):
      1. '<Name>: looking up the latest release': Get-CraftRelease of Item.repo. A failure is its message,
         'GitHub busy - try again later' or 'release lookup failed'.
      2. Select-CraftAsset for Item.assetPrefix and Arch; none is 'no <Arch> installer in the latest release'.
      3. InstalledVersion the same as the release or newer (Test-CraftVersionCurrent) is Current: nothing is
         downloaded or run.
      4. A release without SHA256SUMS.txt is 'no SHA256SUMS.txt in the release', before any download.
      5. '<Name> <ver>: downloading': the checksum list (Get-RemoteText; 'checksum list could not be read'),
         then the MSI to <DownloadDir>\<asset name> (Get-RemoteFile; 'download failed').
      6. '<Name> <ver>: checking': the MSI's SHA-256 must equal its line in the list ('no checksum for
         <file>', 'checksum mismatch'), then its Authenticode signer must be one of Signers ('signature
         check failed'). An MSI that fails either check is deleted and never run; nothing else is ever
         deleted (V2-R13).
      7. '<Name> <ver>: installing': msiexec /i "<msi>" /qn /norestart through Invoke-External with
         timeoutsMinutes.msi. 0, 3010 and 1641 are Installed, with no restart of its own (the Windows Update
         loop restarts). 1618 (another installation is running) waits 60 s and tries again, three tries in
         all. Anything else is 'msiexec <code>', 'msiexec timed out' or 'msiexec could not be started'.
    Version is the release version, '' while it is unknown. Anything unexpected is 'unexpected error'.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Context,
    [Parameter(Mandatory)]$Item,
    [Parameter(Mandatory)][string]$Arch,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Signers,
    [AllowNull()][AllowEmptyString()][string]$InstalledVersion = ''
  )

  $name = [string]$Item.name
  $version = ''
  try {
    Set-SetupNow -SubTitle ('{0}: looking up the latest release' -f $name)
    try {
      $release = Get-CraftRelease -Repo ([string]$Item.repo)
    } catch {
      # Get-CraftRelease throws one of two short texts; anything else (a config without a repo) is a lookup failure.
      $reason = $_.Exception.Message
      if ($reason -cne 'GitHub busy - try again later') { $reason = 'release lookup failed' }
      return (New-CraftItemFailure -Name $name -Version $version -Reason $reason)
    }

    $asset = Select-CraftAsset -Release $release -Prefix ([string]$Item.assetPrefix) -Arch $Arch
    if ($null -eq $asset) { return (New-CraftItemFailure -Name $name -Version $version -Reason "no $Arch installer in the latest release") }
    $version = [string]$asset.Version

    if (Test-CraftVersionCurrent -Installed $InstalledVersion -Available $version) {
      Write-SetupLog -Message 'Craft item already up to date' -Data @{ item = $name; installed = $InstalledVersion; release = $version }
      return @{ Status = 'Current'; Version = $version; Reason = '' }
    }
    if ([string]::IsNullOrEmpty([string]$asset.SumsUrl)) { return (New-CraftItemFailure -Name $name -Version $version -Reason 'no SHA256SUMS.txt in the release') }

    Set-SetupNow -SubTitle ('{0} {1}: downloading' -f $name, $version)
    try {
      $sums = Get-RemoteText -Url ([string]$asset.SumsUrl)
    } catch {
      Write-SetupLog -Message 'The checksum list could not be read' -Level WARN -Data @{ item = $name; url = [string]$asset.SumsUrl; error = $_.Exception.Message }
      return (New-CraftItemFailure -Name $name -Version $version -Reason 'checksum list could not be read')
    }
    try {
      $msi = [string](Get-RemoteFile -Url ([string]$asset.Url) -Destination (Join-Path $Context.DownloadDir ([string]$asset.Name)))
    } catch {
      Write-SetupLog -Message 'The installer download failed' -Level WARN -Data @{ item = $name; url = [string]$asset.Url; error = $_.Exception.Message }
      return (New-CraftItemFailure -Name $name -Version $version -Reason 'download failed')
    }

    Set-SetupNow -SubTitle ('{0} {1}: checking' -f $name, $version)
    $expected = Get-Sha256FromSums -Text $sums -FileName ([string]$asset.Name)
    if ([string]::IsNullOrEmpty($expected)) {
      Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
      return (New-CraftItemFailure -Name $name -Version $version -Reason "no checksum for $($asset.Name)")
    }
    $actual = (Get-FileHash -LiteralPath $msi -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actual -ine $expected) {
      Write-SetupLog -Message 'The installer does not match its checksum; deleted' -Level WARN -Data @{ item = $name; expected = $expected; actual = $actual }
      Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
      return (New-CraftItemFailure -Name $name -Version $version -Reason 'checksum mismatch')
    }
    if (-not (Test-FileSignature -Path $msi -AllowedSigners $Signers)) {
      Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
      return (New-CraftItemFailure -Name $name -Version $version -Reason 'signature check failed')
    }

    Set-SetupNow -SubTitle ('{0} {1}: installing' -f $name, $version)
    $msiexec = Join-Path $env:windir 'System32\msiexec.exe'
    $arguments = "/i `"$msi`" /qn /norestart"
    $timeout = [double]$Context.Config.timeoutsMinutes.msi
    $maxTries = 3
    for ($try = 1; $try -le $maxTries; $try++) {
      try {
        $run = Invoke-External -FilePath $msiexec -ArgumentList $arguments -TimeoutMinutes $timeout
      } catch {
        Write-SetupLog -Message 'msiexec could not be started' -Level ERROR -Data @{ item = $name; error = $_.Exception.Message }
        return (New-CraftItemFailure -Name $name -Version $version -Reason 'msiexec could not be started')
      }
      if ($run.TimedOut) { return (New-CraftItemFailure -Name $name -Version $version -Reason 'msiexec timed out') }

      $outcome = Convert-MsiExitCode -ExitCode $run.ExitCode
      if ($outcome -eq 'Done' -or $outcome -eq 'DoneReboot') {
        Write-SetupLog -Message 'Craft item installed' -Data @{ item = $name; version = $version; exitCode = $run.ExitCode }
        return @{ Status = 'Installed'; Version = $version; Reason = '' }
      }
      if ($outcome -eq 'Retry' -and $try -lt $maxTries) {
        Write-SetupLog -Message 'Another installation is running; waiting before trying again' -Level WARN -Data @{ item = $name; attempt = $try; of = $maxTries; waitSeconds = 60 }
        Wait-SetupDelay -Seconds 60
        continue
      }
      return (New-CraftItemFailure -Name $name -Version $version -Reason "msiexec $($run.ExitCode)")
    }
  } catch {
    Write-SetupLog -Message 'Craft item failed unexpectedly' -Level ERROR -Data @{ item = $name; error = $_.Exception.Message }
    return (New-CraftItemFailure -Name $name -Version $version -Reason 'unexpected error')
  }
}

function Find-CraftShortcutFile {
  <#
  .SYNOPSIS
    Private. The first .lnk file directly in Folders (in their order; with -Recurse also below them) whose
    BaseName -match Pattern, or $null. A folder that is empty, missing or partly unreadable is passed over.
  #>
  [CmdletBinding()]
  [OutputType([IO.FileInfo])]
  param(
    [AllowEmptyCollection()][string[]]$Folders,
    [Parameter(Mandatory)][string]$Pattern,
    [switch]$Recurse
  )

  foreach ($folder in @($Folders)) {
    if ([string]::IsNullOrWhiteSpace($folder)) { continue }
    # Extension too: on 8.3 names the *.lnk filter can also match a longer extension.
    $found = @(Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -Recurse:$Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_ -is [IO.FileInfo] -and $_.Extension -ieq '.lnk' -and $_.BaseName -match $Pattern } | Select-Object -First 1)
    if ($found.Count -gt 0) { return $found[0] }
  }
  return $null
}

function Add-CraftShortcut {
  <#
  .SYNOPSIS
    Gives one Craft item its desktop shortcut with the familiar name (Item.shortcut: Word, Excel, ...).
    Returns @{ Status = Created | Renamed | Exists | Failed; Path = <that .lnk> }. Never throws.
  .DESCRIPTION
    The shortcut is <PublicDesktop>\<Item.shortcut>.lnk, or <UserDesktop>\... for the launcher
    (Item.launcher). Empty folders are this PC's: CommonDesktopDirectory, DesktopDirectory and the
    CommonPrograms and Programs Start menus.
      1. It exists already (a real Microsoft Word shortcut, an earlier run): Exists, nothing touched.
      2. Else the MSI's own desktop shortcut, the first .lnk directly on the public then the user's desktop
         whose name matches Item.startMenuName, is moved to that name: Renamed (no duplicate icon).
      3. Else the first matching .lnk under the Start menus (in their sub-folders too) is copied: Created.
      4. Else, or on any error: Failed, logged at WARN.
    Nothing is ever overwritten or deleted (craft Review Focus 5). An empty startMenuName would match every
    shortcut, so it is Failed.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]$Item,
    [string]$PublicDesktop,
    [string]$UserDesktop,
    [string[]]$StartMenuFolders
  )

  $target = ''
  try {
    if ([string]::IsNullOrWhiteSpace($PublicDesktop)) { $PublicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory') }
    if ([string]::IsNullOrWhiteSpace($UserDesktop)) { $UserDesktop = [Environment]::GetFolderPath('DesktopDirectory') }
    if (@($StartMenuFolders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
      $StartMenuFolders = @([Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('Programs'))
    }

    $shortcut = [string]$Item.shortcut
    $pattern = [string]$Item.startMenuName
    $desktop = if ($Item.launcher -eq $true) { $UserDesktop } else { $PublicDesktop }
    if ([string]::IsNullOrWhiteSpace($shortcut) -or [string]::IsNullOrWhiteSpace($pattern) -or [string]::IsNullOrWhiteSpace($desktop)) {
      Write-SetupLog -Message 'A Craft desktop shortcut needs a name, a startMenuName and a desktop; one is missing' -Level WARN -Data @{ item = [string]$Item.name; shortcut = $shortcut; startMenuName = $pattern; desktop = $desktop }
      return @{ Status = 'Failed'; Path = $target }
    }
    [void][regex]::new($pattern)   # a bad pattern fails here, not half-way through a folder
    $target = Join-Path $desktop "$shortcut.lnk"

    if (Test-Path -LiteralPath $target) { return @{ Status = 'Exists'; Path = $target } }

    $own = Find-CraftShortcutFile -Folders @($PublicDesktop, $UserDesktop) -Pattern $pattern
    if ($null -ne $own) {
      Move-Item -LiteralPath $own.FullName -Destination $target -ErrorAction Stop
      Write-SetupLog -Message 'Craft desktop shortcut renamed' -Data @{ from = $own.FullName; to = $target }
      return @{ Status = 'Renamed'; Path = $target }
    }

    $start = Find-CraftShortcutFile -Folders $StartMenuFolders -Pattern $pattern -Recurse
    if ($null -ne $start) {
      Copy-Item -LiteralPath $start.FullName -Destination $target -ErrorAction Stop
      Write-SetupLog -Message 'Craft desktop shortcut created' -Data @{ from = $start.FullName; to = $target }
      return @{ Status = 'Created'; Path = $target }
    }

    Write-SetupLog -Message 'No Start-menu shortcut found for a Craft app' -Level WARN -Data @{ item = [string]$Item.name; startMenuName = $pattern; folders = @($StartMenuFolders) }
    return @{ Status = 'Failed'; Path = $target }
  } catch {
    Write-SetupLog -Message 'A Craft desktop shortcut could not be created' -Level WARN -Data @{ item = [string]$Item.name; path = $target; error = $_.Exception.Message }
    return @{ Status = 'Failed'; Path = $target }
  }
}

function Invoke-StepCraftApps {
  <#
  .SYNOPSIS
    The craft-apps step (craft spec 3.3): installs every item of apps.craft.items, in config order.
    Done / Failed, with yellow Notes; no Data and no Reboot.
  .DESCRIPTION
    No items, or a signer key that signers does not hold (or that holds no name), is Failed('Craft apps
    are not configured') and installs nothing. Otherwise the installed versions are read once
    (Get-InstalledAppVersions -Config) and each item goes through Install-CraftItem with the processor
    (ConvertTo-CraftArch of Machine.Arch) and the craft signer; one failing never stops the others.
    An item Installed or Current gets its desktop shortcut (Add-CraftShortcut); a shortcut that fails is
    the Note '<shortcut> desktop shortcut could not be created'. Every item writes one activity line:
      '<Name> <ver> installed' or '<Name> <ver> already up to date', plus ' - desktop shortcut: <shortcut>'
      when the shortcut was Created or Renamed now; the launcher's installed line ends ' - open it to check
      the apps and their updates' instead; a failure is '<Name> not installed - <reason>'.
    Any app failing is Failed('Not installed: <Name> (<reason>), ...') in config order. The launcher failing
    alone is only the Note '<Name> could not be installed': the apps work without it. Otherwise Done('Craft
    apps installed'), or Done('Craft apps already up to date') when every item was Current. The Notes come
    with Done and Failed alike.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $craft = $Context.Config.apps.craft
  $items = @($craft.items | Where-Object { $null -ne $_ })
  $signers = @()
  if ($items.Count -gt 0) {
    try {
      $signers = @(Get-Signers -Config $Context.Config -Key ([string]$craft.signer) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
      Write-SetupLog -Message 'The Craft signer is not configured' -Level ERROR -Data @{ signer = [string]$craft.signer; error = $_.Exception.Message }
    }
  }
  if ($items.Count -eq 0 -or $signers.Count -eq 0) {
    Write-SetupLog -Message 'Craft apps are not configured (apps.craft.items, signers)' -Level ERROR
    return New-StepResult -Status Failed -Message 'Craft apps are not configured'
  }

  $arch = ConvertTo-CraftArch -Arch ([string]$Context.State.Machine.Arch)
  $installed = Get-InstalledAppVersions -Config $Context.Config
  $notes = New-Object 'System.Collections.Generic.List[string]'
  $failures = New-Object 'System.Collections.Generic.List[string]'
  $allCurrent = $true

  foreach ($item in $items) {
    $name = [string]$item.name
    $isLauncher = ($item.launcher -eq $true)
    $installedVersion = ''
    if ($installed -is [System.Collections.IDictionary] -and $installed.Contains($name)) { $installedVersion = [string]$installed[$name] }

    $outcome = Install-CraftItem -Context $Context -Item $item -Arch $arch -Signers $signers -InstalledVersion $installedVersion
    $status = [string]$outcome.Status
    if ($status -ne 'Current') { $allCurrent = $false }

    if ($status -eq 'Installed' -or $status -eq 'Current') {
      $shortcut = Add-CraftShortcut -Item $item
      if ([string]$shortcut.Status -eq 'Failed') { $notes.Add(('{0} desktop shortcut could not be created' -f [string]$item.shortcut)) }
      $line = if ($status -eq 'Installed') { '{0} {1} installed' -f $name, [string]$outcome.Version } else { '{0} {1} already up to date' -f $name, [string]$outcome.Version }
      if ($isLauncher) {
        if ($status -eq 'Installed') { $line += ' - open it to check the apps and their updates' }
      } elseif ([string]$shortcut.Status -eq 'Created' -or [string]$shortcut.Status -eq 'Renamed') {
        $line += ' - desktop shortcut: ' + [string]$item.shortcut
      }
      Add-SetupActivity -Text $line
      continue
    }

    $reason = [string]$outcome.Reason
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'unexpected error' }
    Add-SetupActivity -Text ('{0} not installed - {1}' -f $name, $reason)
    if ($isLauncher) { $notes.Add(('{0} could not be installed' -f $name)) }
    else { $failures.Add(('{0} ({1})' -f $name, $reason)) }
  }

  if ($failures.Count -gt 0) {
    return New-StepResult -Status Failed -Message ('Not installed: ' + ($failures -join ', ')) -Notes $notes.ToArray()
  }
  $message = if ($allCurrent) { 'Craft apps already up to date' } else { 'Craft apps installed' }
  return New-StepResult -Status Done -Message $message -Notes $notes.ToArray()
}
