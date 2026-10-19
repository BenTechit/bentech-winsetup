# src/Detect/PcName.ps1
# Builds the new computer name: <brand code>-<serial>, never longer than 15 characters (NetBIOS limit).

function New-PcName {
  <#
  .SYNOPSIS
    Returns the new PC name for a machine, e.g. DELL-7HX2K93.
  .DESCRIPTION
    The serial is upper-cased and stripped to [A-Z0-9]. When it is longer than the room left after
    "<code>-", the RIGHT-most characters are kept (the left part of a serial is usually the model
    or plant prefix, the right part is what differs between units).

    A junk serial, and every virtual machine, get PC-<last 6 hex chars of the BIOS UUID> instead.
    Junk (triage 119: white-box boards ship placeholders, and identical names clash on one LAN) is,
    after upper-casing and keeping only [A-Z0-9] (so spaces and dashes never matter): empty; one
    character repeated (all zeros, "XXXXXXXX"); or an OEM placeholder such as "To be filled by
    O.E.M.", "Default string", "System Serial Number", "Chassis Serial Number", "Serial Number",
    "Not Applicable", "Not Specified", "Unknown", "None", "N/A", "0123456789" or "123456789".
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
  $isJunk = ($clean.Length -eq 0) -or
            ($clean -match '^(.)\1*$') -or
            ($clean -match '^(TOBEFILLED.*|DEFAULTSTRING|(SYSTEM|CHASSIS)?SERIALNUMBER|NOTAPPLICABLE|NOTSPECIFIED|UNKNOWN|NONE|NA|0?123456789)$')

  if ($isJunk -or $Brand -eq 'VM') {
    $uuid = ("$BiosUuid").ToUpperInvariant() -replace '[^0-9A-F]', ''
    $tail = $uuid
    if ($tail.Length -gt 6) { $tail = $tail.Substring($tail.Length - 6) }
    # A UUID that is missing, short, one character repeated (all 0 / all F: some boards ship it unset),
    # or the AMI firmware default 03000200-0400-0500-0006-000700080009 would give "PC-" or a name shared
    # by every such PC, so use random hex instead. The name is computed once and kept in the run state,
    # so it does not change between resumes.
    if ($tail.Length -lt 6 -or $tail -match '^(0+|F+)$' -or $uuid -match '^(.)\1*$' -or $uuid -eq '03000200040005000006000700080009') {
      $tail = [guid]::NewGuid().ToString('N').Substring(0, 6).ToUpperInvariant()
    }
    return "PC-$tail"
  }

  $room = 15 - $code.Length - 1
  if ($clean.Length -gt $room) { $clean = $clean.Substring($clean.Length - $room) }
  return "$code-$clean"
}
