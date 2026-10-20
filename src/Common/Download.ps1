function New-SetupWebClient {
  <#
  .SYNOPSIS
    A WebClient with TLS 1.2 forced and a User-Agent set (some vendor sites reject an empty one).
  .DESCRIPTION
    The protocol is set on every call, not once: another script in the same process may have changed
    it. Invoke-WebRequest is never used (Windows PowerShell 5.1 prompts without -UseBasicParsing).
  #>
  [CmdletBinding()]
  [OutputType([Net.WebClient])]
  param()

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $client = New-Object Net.WebClient
  $client.Headers.Add('User-Agent', 'BenTechSetup/1.0')
  return $client
}

function Invoke-DownloadAttempt {
  <#
  .SYNOPSIS
    Runs $Action (given a fresh WebClient) up to $Retries times, until one run does not throw.
  .DESCRIPTION
    Returns nothing: $Action is a script block that reads its caller's variables (dynamic scoping)
    and hands any result back through one of them, so a byte array is never pushed through the
    pipeline. Waits BackoffSeconds * attempt between tries, and not after the last one. After the
    final failure it throws "download failed after <n> attempts: <url>"; the last error is the
    inner exception.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][scriptblock]$Action,
    [Parameter(Mandatory)][int]$Retries,
    [Parameter(Mandatory)][double]$BackoffSeconds
  )

  $lastError = $null
  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    $client = $null
    try {
      $client = New-SetupWebClient
      & $Action $client | Out-Null
      return
    } catch {
      $lastError = $_.Exception
      Write-SetupLog -Message 'Download attempt failed' -Level WARN -Data @{ url = $Url; attempt = $attempt; of = $Retries; error = $_.Exception.Message }
    } finally {
      if ($client) { $client.Dispose() }
    }
    if ($attempt -lt $Retries -and $BackoffSeconds -gt 0) {
      Wait-SetupDelay -Milliseconds ([int]($BackoffSeconds * $attempt * 1000))
    }
  }
  $message = "download failed after $Retries attempts: $Url"
  Write-SetupLog -Message $message -Level ERROR
  throw (New-Object System.Exception ($message, $lastError))
}

function Receive-RemoteFile {
  <#
  .SYNOPSIS
    Private. One attempt of Get-RemoteFile: downloads Url to Path with Client, waiting at most
    TimeoutMinutes. Throws when the download fails or times out.
  .DESCRIPTION
    DownloadFileTaskAsync, waited for in slices of at most 250 ms with the tick after each, so the
    progress screen stays alive; TimeoutMinutes is the published wait limit meanwhile. At the
    deadline the download is cancelled (CancelAsync), given at most 2 s to stop, and a
    TimeoutException "download timed out after <n> min: <url>" is thrown. A finished download is
    completed with GetAwaiter().GetResult(), which rethrows its WebException.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Client,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][double]$TimeoutMinutes
  )

  $timeoutMs = [long][Math]::Ceiling($TimeoutMinutes * 60000)
  $clock = [Diagnostics.Stopwatch]::StartNew()
  Enter-SetupWait -LimitMinutes $TimeoutMinutes
  try {
    $task = $Client.DownloadFileTaskAsync([uri]$Url, $Path)
    while (-not $task.IsCompleted) {
      $remaining = $timeoutMs - $clock.ElapsedMilliseconds
      if ($remaining -le 0) {
        $Client.CancelAsync()
        [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($task), 2000)
        throw (New-Object TimeoutException ("download timed out after $TimeoutMinutes min: $Url"))
      }
      [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($task), [int][Math]::Min(250, $remaining))
      Invoke-SetupTick
    }
    $null = $task.GetAwaiter().GetResult()
  } finally {
    Exit-SetupWait
  }
}

function Get-RemoteFile {
  <#
  .SYNOPSIS
    Downloads Url to Destination with retries; returns the destination path.
  .DESCRIPTION
    Downloads to <Destination>.part and moves it into place only when complete, so a partial or
    failed download never looks like a finished file. Creates the destination folder if needed. An
    existing destination is replaced only after a download succeeded. Each attempt may take at most
    TimeoutMinutes (Receive-RemoteFile: it ticks while it waits); a timed-out attempt is a failed
    one. Waits BackoffSeconds * attempt between tries. Throws "download failed after <n> attempts:
    <url>".
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Destination,
    [ValidateRange(1, 100)][int]$Retries = 3,
    [ValidateRange(0, 3600)][double]$BackoffSeconds = 5,
    [ValidateRange(0.001, 1440)][double]$TimeoutMinutes = 30
  )

  # Resolve against PowerShell's location, not the process's current directory (WebClient and
  # [IO.File] use the latter).
  $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
  $part = "$target.part"
  $folder = Split-Path -Parent $target
  if ($folder -and -not (Test-Path -LiteralPath $folder)) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
  }

  Write-SetupLog -Message 'Downloading file' -Data @{ url = $Url; destination = $target }
  Invoke-DownloadAttempt -Url $Url -Retries $Retries -BackoffSeconds $BackoffSeconds -Action {
    param($client)
    try {
      Receive-RemoteFile -Client $client -Url $Url -Path $part -TimeoutMinutes $TimeoutMinutes
      Move-Item -LiteralPath $part -Destination $target -Force -ErrorAction Stop
    } finally {
      # Gone after a successful move; after a failure this is the partial download.
      Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
  }
  return $target
}

function Get-RemoteText {
  <#
  .SYNOPSIS
    Downloads a URL and returns it as a UTF-8 string (a leading BOM is dropped), with retries.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Url,
    [ValidateRange(1, 100)][int]$Retries = 3,
    [ValidateRange(0, 3600)][double]$BackoffSeconds = 5
  )

  $result = @{ Bytes = $null }
  Invoke-DownloadAttempt -Url $Url -Retries $Retries -BackoffSeconds $BackoffSeconds -Action {
    param($client)
    $result.Bytes = $client.DownloadData($Url)
  }
  $bytes = [byte[]]$result.Bytes
  # GetString does not strip the BOM, and WebClient.DownloadString depends on the response headers.
  $skip = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $skip = 3 }
  return [Text.Encoding]::UTF8.GetString($bytes, $skip, $bytes.Length - $skip)
}

function Find-LatestLink {
  <#
  .SYNOPSIS
    Returns the first match of Pattern in Html, in document order, that ExcludePattern does not
    match; $null when there is none.
  .DESCRIPTION
    Both patterns are regular expressions and are case-insensitive, like PowerShell's -match.
    There is no version sorting: vendor download pages list the newest release first, so "first
    match" is "latest". The caller supplies a pattern specific enough for the page.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Html,
    [Parameter(Mandatory)][string]$Pattern,
    [string]$ExcludePattern
  )

  foreach ($match in [regex]::Matches($Html, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    if ($ExcludePattern -and $match.Value -match $ExcludePattern) { continue }
    return $match.Value
  }
  return $null
}

function Test-FileSignature {
  <#
  .SYNOPSIS
    $true when the file has a valid Authenticode signature whose signer certificate subject
    contains CN=<one of the allowed signers>.
  .DESCRIPTION
    "Valid" includes catalog-signed Windows binaries, which is how Get-AuthenticodeSignature
    reports them. A missing or unreadable file, a non-Valid status, or a signer that is not on
    the list returns $false; it never throws. When it returns $false for a file that exists, the
    actual status and subject are logged at WARN, so a vendor changing its signing identity is
    visible in the log.

    Each allowed signer is matched as literal text (wildcard characters are escaped) and an empty
    signer is ignored, so a bad config entry cannot allow everything.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$AllowedSigners
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-SetupLog -Message 'Signature check: file not found' -Level WARN -Data @{ path = $Path }
    return $false
  }

  try {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
  } catch {
    Write-SetupLog -Message 'Signature check: could not read the signature' -Level WARN -Data @{ path = $Path; error = $_.Exception.Message }
    return $false
  }

  $status = [string]$signature.Status
  $subject = ''
  if ($signature.SignerCertificate) { $subject = [string]$signature.SignerCertificate.Subject }

  if ($status -eq 'Valid' -and $subject) {
    foreach ($signer in $AllowedSigners) {
      if ([string]::IsNullOrWhiteSpace($signer)) { continue }
      if ($subject -like ('*CN=' + [Management.Automation.WildcardPattern]::Escape($signer) + '*')) { return $true }
    }
  }

  Write-SetupLog -Message 'Signature check: rejected' -Level WARN -Data @{ path = $Path; status = $status; subject = $subject; allowedSigners = @($AllowedSigners) }
  return $false
}
