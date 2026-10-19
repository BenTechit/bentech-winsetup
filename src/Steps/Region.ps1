# src/Steps/Region.ps1
# Step 2, "Time zone + Hebrew keyboard" (spec 8.3, Q10). Needs StepResult.ps1, Logging.ps1 and Process.ps1.
#
# Region problems are cosmetic: a wrong clock or a missing keyboard is something to tell the technician
# about (a Note), never a reason to fail the run. Nothing here reads command output.

$script:IsraelTimeZoneId = 'Israel Standard Time'

# w32tm /resync is quick; two minutes only bounds a wedged time service.
$script:TimeSyncTimeoutMinutes = 2

function Merge-LanguageTags {
  <#
  .SYNOPSIS
    Returns the language tags with English and Hebrew added when the list has neither.
  .DESCRIPTION
    The existing tags keep their order (the first one is the display language). en-US is appended when
    no tag is English, then he-IL when no tag is Hebrew. "English" is any tag whose language part is
    en (en-US, en-GB, en), "Hebrew" any tag whose language part is he; case does not matter.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param([AllowNull()][string[]]$Existing)

  $tags = New-Object 'System.Collections.Generic.List[string]'
  foreach ($tag in @($Existing | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { $tags.Add([string]$tag) }

  # Anchored on the language part: 'en' or 'en-<region>', never another language that merely starts with e-n.
  if (-not @($tags | Where-Object { $_ -match '^en(-|$)' }).Count) { $tags.Add('en-US') }
  if (-not @($tags | Where-Object { $_ -match '^he(-|$)' }).Count) { $tags.Add('he-IL') }
  return $tags.ToArray()
}

function Set-IsraelClock {
  # Private. Time zone, then the clock: starts the time service if it is stopped and forces a resync.
  # Returns $false only when the time zone could not be set. A time sync that does not work is
  # logged and nothing else (the clock corrects itself later, and the exit code text is localized).
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $zoneOk = $true
  try {
    Set-TimeZone -Id $script:IsraelTimeZoneId -ErrorAction Stop
  } catch {
    Write-SetupLog -Message 'Time zone could not be set' -Level WARN -Data @{ id = $script:IsraelTimeZoneId; error = $_.Exception.Message }
    $zoneOk = $false
  }

  try {
    $service = Get-Service -Name w32time -ErrorAction Stop
    if ([string]$service.Status -ne 'Running') { Start-Service -Name w32time -ErrorAction Stop }
    $run = Invoke-External -FilePath "$env:windir\System32\w32tm.exe" -ArgumentList '/resync /force' -TimeoutMinutes $script:TimeSyncTimeoutMinutes -CaptureOutput
    if ($run.TimedOut -or $run.ExitCode -ne 0) {
      Write-SetupLog -Message 'Time resync did not succeed' -Level WARN -Data @{ exitCode = $run.ExitCode; timedOut = [bool]$run.TimedOut }
    }
  } catch {
    Write-SetupLog -Message 'Time service could not be used' -Level WARN -Data @{ error = $_.Exception.Message }
  }
  return $zoneOk
}

function Add-MissingLanguage {
  # Private. Adds the tags that Merge-LanguageTags says are missing to the user's language list, one
  # tag per Set-WinUserLanguageList call, each time onto a freshly read list. The list is never
  # rebuilt from scratch, so the user's own languages, their order and their keyboards stay as they are.
  # Returns the notes to show; none when nothing was missing or everything was added.
  [CmdletBinding()]
  [OutputType([string[]])]
  param()

  $notes = New-Object 'System.Collections.Generic.List[string]'
  try {
    # Get-WinUserLanguageList emits the List itself as ONE object, so `| ForEach-Object` would see the
    # whole list; foreach enumerates it.
    $current = Get-WinUserLanguageList
    $existing = @(foreach ($language in $current) { [string]$language.LanguageTag })
    $missing = @(Merge-LanguageTags -Existing $existing | Where-Object { $_ -notin $existing })
  } catch {
    Write-SetupLog -Message 'Language list could not be read' -Level WARN -Data @{ error = $_.Exception.Message }
    return @('Hebrew keyboard could not be added')
  }

  foreach ($tag in $missing) {
    try {
      $list = Get-WinUserLanguageList
      $list.Add([Microsoft.InternationalSettings.Commands.WinUserLanguage]::new($tag))
      Set-WinUserLanguageList $list -Force -ErrorAction Stop
      Write-SetupLog -Message 'Language added' -Data @{ tag = $tag }
    } catch {
      Write-SetupLog -Message 'Language could not be added' -Level WARN -Data @{ tag = $tag; error = $_.Exception.Message }
      $notes.Add($(if ($tag -like 'he*') { 'Hebrew keyboard could not be added' } else { 'English keyboard could not be added' }))
    }
  }
  return $notes.ToArray()
}

function Invoke-StepRegion {
  <#
  .SYNOPSIS
    Step 2: Israel time zone, a forced clock sync, and Hebrew + English in the language list.
  .DESCRIPTION
    Always Done. A time zone that cannot be set gives the Note 'Time zone could not be set'; a keyboard
    that cannot be added gives 'Hebrew keyboard could not be added' (or the English equivalent). The
    language list is only written when Merge-LanguageTags adds something.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $notes = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Set-IsraelClock)) { $notes.Add('Time zone could not be set') }
  foreach ($note in @(Add-MissingLanguage)) { if (-not [string]::IsNullOrEmpty($note) -and -not $notes.Contains($note)) { $notes.Add($note) } }
  return New-StepResult -Status Done -Message 'Region settings applied' -Notes $notes.ToArray()
}
