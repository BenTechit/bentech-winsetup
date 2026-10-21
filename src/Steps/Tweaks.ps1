# src/Steps/Tweaks.ps1
# The "System tweaks" step (toolbox spec 5.3, 6.3): the curated registry tweaks of config.tweaks that the run's
# choices name, after desktop-icons and before the first restart. Registry values only, REG_DWORD and REG_SZ,
# through Set-RegistryDword and Set-RegistryString; never a \Policies\ path (Get-TweakCatalog refuses one).
# For each value: the original is read, the value is written (unless it already is the target), and it is read
# back. The originals go to setup.log, never into step Data, so a tweak can be reversed by hand.
#
# A tweak Windows refuses is a yellow Note, never red: Windows works without it. When Windows Administrator
# protection runs setup as a hidden account (Test-AdminProtection On), HKCU is that account, so every HKCU value
# is skipped with one Note; the HKU\.DEFAULT NumLock value still applies.
#
# Needs Prepare.ps1 (Set-RegistryDword, Set-RegistryString, Get-RegistryValue), Catalog.ps1 (Get-TweakCatalog,
# Get-EffectiveTweaks), Detection.ps1 (Test-AdminProtection), StepResult.ps1, Logging.ps1, Activity.ps1 and
# StartScreen.ps1 (ConvertTo-ScreenText); the bundle holds every file. The step takes about a second, so it
# sets no NOW sub-title and never waits.

function Get-ClearBitValue {
  <#
  .SYNOPSIS
    The clearBit operation (toolbox spec 6.3): Current with the Bit mask cleared, as decimal text. Pure.
  .DESCRIPTION
    Current must be digits only and fit a [uint32] (invariant culture), as the accessibility Flags REG_SZ
    numbers do ('510' becomes '506'). Anything else (missing, empty, not a number, negative, too big) gives
    Fresh, the card's fresh-install value.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()][AllowEmptyString()][string]$Current,
    [Parameter(Mandatory)][long]$Bit,
    [Parameter(Mandatory)][string]$Fresh
  )

  $number = [uint32]0
  if ($Current -cnotmatch '^[0-9]+\z' -or
      -not [uint32]::TryParse($Current, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
    return $Fresh
  }
  $cleared = [long]$number -band ([long]4294967295 -bxor $Bit)
  return $cleared.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-TweakValue {
  <#
  .SYNOPSIS
    Applies one value of a tweak. Returns 'applied', 'unchanged', 'refused' or 'differs'. Never throws.
  .DESCRIPTION
    Reads the original (Get-RegistryValue) and works out the target: Value for a set (an [int] for a DWord, a
    [string] for a String), Get-ClearBitValue of the original for a clearBit. An original that already equals
    the target with the same kind is not written ('unchanged'), which keeps UCPD out of the way on a re-run.
    Otherwise the value is written (Set-RegistryDword or Set-RegistryString): a refused write is 'refused';
    then it is read back, which must exist with the same kind and equal the target ('applied'), else
    'differs'. Any exception is 'refused' (a WARN). Every call logs one INFO 'Tweak value' line with
    @{ tweak; path; name; type; original; new; readBack; result }, original and readBack being the value as
    text or 'absent'. Only ASCII reaches the log.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$TweakId,
    [Parameter(Mandatory)][hashtable]$Value
  )

  $line = @{ tweak = $TweakId; path = (ConvertTo-ScreenText $Value.Path); name = (ConvertTo-ScreenText $Value.Name); type = [string]$Value.Type
             original = 'absent'; new = ''; readBack = ''; result = 'refused' }
  try {
    $original = Get-RegistryValue -Path $Value.Path -Name $Value.Name
    if ($original.Exists) { $line.original = ConvertTo-ScreenText ([string]$original.Value) }

    if ($Value.Op -ceq 'clearBit') {
      $current = if ($original.Exists) { [string]$original.Value } else { $null }
      $target = Get-ClearBitValue -Current $current -Bit $Value.Bit -Fresh ([string]$Value.Value)
    } elseif ($Value.Type -ceq 'DWord') {
      $target = [int]$Value.Value
    } else {
      $target = [string]$Value.Value
    }
    $line.new = ConvertTo-ScreenText ([string]$target)

    if ($original.Exists -and $original.Kind -ceq $Value.Type -and [string]$original.Value -ceq [string]$target) {
      $line.readBack = $line.original
      $line.result = 'unchanged'
    } else {
      $written = if ($Value.Type -ceq 'DWord') {
        Set-RegistryDword -Path $Value.Path -Name $Value.Name -Value $target
      } else {
        Set-RegistryString -Path $Value.Path -Name $Value.Name -Value $target
      }
      if ($written -eq $true) {
        $after = Get-RegistryValue -Path $Value.Path -Name $Value.Name
        $line.readBack = if ($after.Exists) { ConvertTo-ScreenText ([string]$after.Value) } else { 'absent' }
        $same = $after.Exists -and $after.Kind -ceq $Value.Type -and [string]$after.Value -ceq [string]$target
        $line.result = if ($same) { 'applied' } else { 'differs' }
      }
    }
  } catch {
    $line.result = 'refused'
    Write-SetupLog -Message 'Tweak value could not be applied' -Level WARN -Data @{ tweak = $TweakId; path = $line.path; name = $line.name; error = (ConvertTo-ScreenText $_.Exception.Message) }
  }
  Write-SetupLog -Message 'Tweak value' -Data $line
  return $line.result
}

function Invoke-StepTweaks {
  <#
  .SYNOPSIS
    The tweaks step (toolbox spec 5.3). Returns Skipped('No tweaks chosen') or Done('<n> tweaks applied');
    never Failed.
  .DESCRIPTION
    The effective list is Get-EffectiveTweaks of State.Choices, Config and State.Machine, so the step enforces
    desktopOnly, office365Only and minBuild itself, whatever the plan said. Empty: Skipped('No tweaks chosen').
    Test-AdminProtection is asked once: On is a WARN, and every value whose path starts with HKCU:\ is skipped
    (logged as 'skipped', not written); Unknown is treated as the same user, as the setup assumes, and is a
    WARN too. Each tweak's values then run in order (Invoke-TweakValue). A tweak is:
      - refused when any of its values is refused or differs: Note '<title> could not be applied';
      - applied when none is and at least one value was written or already set;
      - skipped when every value was skipped (all HKCU, Administrator protection On).
    Done('<n> tweaks applied', n = the applied ones; verbatim also for 1), with the Note 'Per-user tweaks
    skipped: Windows Administrator protection is on' once when any value was skipped. Data holds ids only, in
    catalog order: @{ Applied; Refused; Skipped }. Activity 'Tweaks: <n> applied', plus ', <m> refused by
    Windows' when m > 0.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $runState = $Context.State
  $choices = if ($runState -is [System.Collections.IDictionary]) { $runState['Choices'] } else { $null }
  $machine = if ($runState -is [System.Collections.IDictionary]) { $runState['Machine'] } else { $null }
  $effective = @(Get-EffectiveTweaks -Choices $choices -Config $Context.Config -Machine $machine)
  if ($effective.Count -eq 0) { return New-StepResult -Status Skipped -Message 'No tweaks chosen' }

  $protection = Test-AdminProtection
  if ($protection -eq 'On') {
    Write-SetupLog -Message 'Administrator protection is on: per-user tweak values are skipped' -Level WARN
  } elseif ($protection -eq 'Unknown') {
    Write-SetupLog -Message 'Administrator protection state unknown; treating the setup account as the signed-in user' -Level WARN
  }

  $applied = New-Object System.Collections.Generic.List[string]
  $refused = New-Object System.Collections.Generic.List[string]
  $skipped = New-Object System.Collections.Generic.List[string]
  $refusedNotes = New-Object System.Collections.Generic.List[string]
  $anyValueSkipped = $false

  foreach ($tweak in @(Get-TweakCatalog -Config $Context.Config)) {
    if ($effective -cnotcontains $tweak.Id) { continue }
    $done = 0
    $failed = $false
    foreach ($value in @($tweak.Values)) {
      if ($protection -eq 'On' -and $value.Path.StartsWith('HKCU:\', [StringComparison]::OrdinalIgnoreCase)) {
        $anyValueSkipped = $true
        Write-SetupLog -Message 'Tweak value' -Data @{ tweak = $tweak.Id; path = (ConvertTo-ScreenText $value.Path); name = (ConvertTo-ScreenText $value.Name)
          type = [string]$value.Type; original = ''; new = ''; readBack = ''; result = 'skipped' }
        continue
      }
      $result = Invoke-TweakValue -TweakId $tweak.Id -Value $value
      if ($result -in 'applied', 'unchanged') { $done++ } else { $failed = $true }
    }
    if ($failed) {
      $refused.Add($tweak.Id)
      $refusedNotes.Add(('{0} could not be applied' -f (ConvertTo-ScreenText $tweak.Title.en)))
    } elseif ($done -gt 0) {
      $applied.Add($tweak.Id)
    } else {
      $skipped.Add($tweak.Id)
    }
  }

  $notes = New-Object System.Collections.Generic.List[string]
  if ($anyValueSkipped) { $notes.Add('Per-user tweaks skipped: Windows Administrator protection is on') }
  $notes.AddRange($refusedNotes)

  $activity = 'Tweaks: {0} applied' -f $applied.Count
  if ($refused.Count -gt 0) { $activity += ', {0} refused by Windows' -f $refused.Count }
  Add-SetupActivity -Text $activity

  return New-StepResult -Status Done -Message ('{0} tweaks applied' -f $applied.Count) -Notes $notes.ToArray() -Data @{
    Applied = [string[]]$applied.ToArray(); Refused = [string[]]$refused.ToArray(); Skipped = [string[]]$skipped.ToArray() }
}
