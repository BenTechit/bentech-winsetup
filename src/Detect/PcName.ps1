# src/Detect/PcName.ps1
# Builds the new computer name: <brand code>-<serial>, never longer than 15 characters (NetBIOS limit).
# Also the machine identity of the repair page (repair spec 6.8, section 13 call 22: "the same PC" is its serial,
# or its BIOS UUID when the serial is a placeholder), which must use exactly New-PcName's placeholder rule: both
# call Test-PlaceholderSerial.

# The AMI firmware default UUID 03000200-0400-0500-0006-000700080009: every board that ships it unset has the same.
$script:AmiDefaultBiosUuid = '03000200040005000006000700080009'

function Test-PlaceholderSerial {
  <#
  .SYNOPSIS
    $true when a BIOS serial is junk: a placeholder that white-box boards ship, shared by many PCs (triage 119).
  .DESCRIPTION
    After upper-casing and keeping only [A-Z0-9] (so spaces and dashes never matter), junk is: empty; one
    character repeated (all zeros, "XXXXXXXX"); or an OEM placeholder such as "To be filled by O.E.M.",
    "Default string", "System Serial Number", "Chassis Serial Number", "Serial Number", "Not Applicable",
    "Not Specified", "Unknown", "None", "N/A", "0123456789" or "123456789". New-PcName and Get-MachineIdentity
    both use this rule.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()][AllowEmptyString()][string]$Serial)

  $clean = ("$Serial").ToUpperInvariant() -replace '[^A-Z0-9]', ''
  return (($clean.Length -eq 0) -or
          ($clean -match '^(.)\1*$') -or
          ($clean -match '^(TOBEFILLED.*|DEFAULTSTRING|(SYSTEM|CHASSIS)?SERIALNUMBER|NOTAPPLICABLE|NOTSPECIFIED|UNKNOWN|NONE|NA|0?123456789)$'))
}

function ConvertTo-BiosUuidHex {
  # Private. A BIOS UUID as upper-case hex without its dashes, braces and spaces ('' for none). Other characters
  # are kept, so a value that is not a UUID stays unusable.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$BiosUuid)

  return (("$BiosUuid").ToUpperInvariant() -replace '[\s{}-]', '')
}

function Test-UsableBiosUuid {
  <#
  .SYNOPSIS
    $true when a BIOS UUID can tell one PC from another: 32 hex digits (dashes, braces and case aside), not one
    character repeated (all 0 / all F: some boards ship it unset) and not the AMI firmware default
    03000200-0400-0500-0006-000700080009.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()][AllowEmptyString()][string]$BiosUuid)

  $hex = ConvertTo-BiosUuidHex -BiosUuid $BiosUuid
  return (($hex -cmatch '^[0-9A-F]{32}\z') -and ($hex -notmatch '^(.)\1*\z') -and ($hex -ne $script:AmiDefaultBiosUuid))
}

function Get-MachineIdentity {
  <#
  .SYNOPSIS
    The identity the repair page keys a PC by (repair plan, Shared shapes): @{ Key; FolderPart; Serial; BiosUuid }.
  .DESCRIPTION
    -Machine is Get-MachineInfo's hashtable (Serial and BiosUuid are read; a missing one is empty).
      - A real serial (not Test-PlaceholderSerial): Key = 'SN-<serial>' and FolderPart = the serial's right-most 20
        characters, the serial upper-cased and reduced to [A-Z0-9] (as New-PcName does).
      - A placeholder serial and a usable BIOS UUID (Test-UsableBiosUuid): Key = 'UUID-<32 hex>' and
        FolderPart = 'UUID-<last 12 hex>', so two white boxes with the same placeholder still differ.
      - Neither: Key = '' (never compared: Compare with last visit has nothing to go by) and FolderPart = 'NOSERIAL'.
    Serial and BiosUuid are the machine's own values, trimmed.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Machine)

  $serial = ([string]$Machine['Serial']).Trim()
  $uuid = ([string]$Machine['BiosUuid']).Trim()
  $key = ''
  $folder = 'NOSERIAL'
  if (-not (Test-PlaceholderSerial -Serial $serial)) {
    $clean = $serial.ToUpperInvariant() -replace '[^A-Z0-9]', ''
    $key = 'SN-' + $clean
    $folder = $clean
    if ($folder.Length -gt 20) { $folder = $folder.Substring($folder.Length - 20) }
  } elseif (Test-UsableBiosUuid -BiosUuid $uuid) {
    $hex = ConvertTo-BiosUuidHex -BiosUuid $uuid
    $key = 'UUID-' + $hex
    $folder = 'UUID-' + $hex.Substring($hex.Length - 12)
  }
  return @{ Key = $key; FolderPart = $folder; Serial = $serial; BiosUuid = $uuid }
}

function New-PcName {
  <#
  .SYNOPSIS
    Returns the new PC name for a machine, e.g. DELL-7HX2K93.
  .DESCRIPTION
    The serial is upper-cased and stripped to [A-Z0-9]. When it is longer than the room left after
    "<code>-", the RIGHT-most characters are kept (the left part of a serial is usually the model
    or plant prefix, the right part is what differs between units).

    A junk serial (Test-PlaceholderSerial: empty, one character repeated, or an OEM placeholder such as
    "To be filled by O.E.M."; triage 119: white-box boards ship placeholders, and identical names clash on
    one LAN), and every virtual machine, get PC-<last 6 hex chars of the BIOS UUID> instead.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Brand,
    [AllowNull()][AllowEmptyString()][string]$Serial,
    [AllowNull()][AllowEmptyString()][string]$BiosUuid
  )

  $codes = @{ DELL = 'DELL'; LENOVO = 'LEN'; HP = 'HP'; ASUS = 'ASUS'; ACER = 'ACER'; MSI = 'MSI'; SURFACE = 'SURF' }
  $code = if ($codes.ContainsKey($Brand)) { $codes[$Brand] } else { 'PC' }

  $clean = ("$Serial").ToUpperInvariant() -replace '[^A-Z0-9]', ''
  $isJunk = Test-PlaceholderSerial -Serial $Serial

  if ($isJunk -or $Brand -eq 'VM') {
    $uuid = ("$BiosUuid").ToUpperInvariant() -replace '[^0-9A-F]', ''
    $tail = $uuid
    if ($tail.Length -gt 6) { $tail = $tail.Substring($tail.Length - 6) }
    # A UUID that is missing, short, one character repeated (all 0 / all F: some boards ship it unset),
    # or the AMI firmware default 03000200-0400-0500-0006-000700080009 would give "PC-" or a name shared
    # by every such PC, so use random hex instead. The name is computed once and kept in the run state,
    # so it does not change between resumes.
    if ($tail.Length -lt 6 -or $tail -match '^(0+|F+)$' -or $uuid -match '^(.)\1*$' -or $uuid -eq $script:AmiDefaultBiosUuid) {
      $tail = [guid]::NewGuid().ToString('N').Substring(0, 6).ToUpperInvariant()
    }
    return "PC-$tail"
  }

  $room = 15 - $code.Length - 1
  if ($clean.Length -gt $room) { $clean = $clean.Substring($clean.Length - $room) }
  return "$code-$clean"
}
