# src/Repair/ToolPrivacy.ps1
# Repair & diagnostics, the privacy-safe (SAFE) copy of a report (repair spec 6.8, decision Q33; repair Task 9): the
# personal values a report holds (Get-ReportIdentifiers) and a masker (New-SafeMasker, ConvertTo-SafeText) that turns
# them, and every e-mail address, SID, MAC address, IP address, profile folder and phone number it finds, into stable
# tokens. Save-ToolSafeCopy writes a SAFE file through one masker.
#
# The full report stays on Ben's stick; the SAFE copy (REPORT_SAFE_<stamp>.txt, COMPARE_SAFE_<stamp>.txt: no PC name
# in the file name, ruling RD-R4) is the one to paste into an AI chat. The masker reads parsed values and report text,
# never raw JSON text (an escape would hide a match). It fails closed: a masker that throws means no SAFE file at all.
#
# Tokens, one masker per report (the same value always gets the same token, in every spelling):
#   user1  PC-1  DOMAIN-1  SERIAL-1  MAC-1  IP-1  IP6-1  SSID-1  EMAIL-1  PHONE-1  SID-1
# Known values are numbered in the order of the -Known lists, pattern finds in order of appearance. A MAC address is
# keyed by its 12 hex digits in upper case, an IP address by its parsed form, an e-mail address in lower case, a phone
# number by its digits (+972 as 0), a SID in upper case; every other value case-insensitively.
#
# Plan calls (and ruling RD-R25, the Task 9 review):
#   - known values under 3 characters are never masked;
#   - generic values are never masked (Test-SafeGenericValue): the stop-list $script:SafeStopWords (User, Admin,
#     Owner, Home, Office, Network, Temp, Windows, the brand names, ...), the built-in account and profile names
#     (Administrator, Guest, Public, Default, ...), and Windows' own names of a network without one ("Network",
#     "Network 2", "Unidentified network", and the Hebrew ones). So the PC's own Guest, DefaultAccount and
#     WDAGUtilityAccount stay whatever their (localized) names, found by SID (section 11's BuiltinUsers); a built-in
#     Administrator under another name is masked (it may have been renamed after a person);
#   - a numeric value (a battery's serial "1234") under 6 digits is never masked, and from 6 digits on only as a whole
#     number (no digit beside it);
#   - a user or network name, a computer or domain name made of letters only, and any value under 6 characters is
#     masked only as a whole word (no letter or digit beside it: "Ben" never turns "Bench" into "user1ch", a PC named
#     COHENPC never cuts "cohenpcx"). A whole word may carry up to three of the Hebrew prefix letters (b, h, v, k, l,
#     m, sh: "to Dana" is one word in Hebrew), which stay outside the token, a Latin name too ("lDana", ruling RD-R26);
#   - a known SID only where no digit follows (S-1-...-1001 never masks the start of S-1-...-10012, RD-R26);
#   - a line that ends inside a known value of two or more words (the event-message cut, Limit-ReportMessage, or a
#     line that ends with a first name) gets that value's token: "Moshe ..." and "Moshe Le" at the end of a line are
#     "Moshe Levi" (review M3, RD-R26). A leading part that is generic ("Home" of "Home Cohen 5G") or a known value of
#     its own is left to its own rule;
#   - every other known value is masked wherever it appears, longest first (a serial inside the PC name is masked as
#     the PC name, then everywhere else as the serial);
#   - a token that a letter or a digit follows gets an underscore after it ("SERIAL-2_99", never "SERIAL-299", which
#     would read as another token).
# A SAFE copy says on its second line what the tokens are.
#
# Needs ToolEngine (ConvertTo-ToolDisplayText), ToolReport (Get-ReportEntry, ConvertTo-ReportList, Save-ToolReportText,
# ConvertTo-ReportReason), PcName (Test-PlaceholderSerial, Test-UsableBiosUuid, New-PcName), Cleanup
# (Test-StickReparsePoint), Logging and StartScreen (ConvertTo-ScreenText). The bundle holds every file.

# The token of each category ({0} is its number).
$script:SafeTokenFormats = [ordered]@{
  User = 'user{0}'; Computer = 'PC-{0}'; Domain = 'DOMAIN-{0}'; Serial = 'SERIAL-{0}'; Mac = 'MAC-{0}'; Ip = 'IP-{0}'; Ip6 = 'IP6-{0}'
  Ssid = 'SSID-{0}'; Email = 'EMAIL-{0}'; Phone = 'PHONE-{0}'; Sid = 'SID-{0}'
}
# The categories masked as text (a value known in two of them takes the first one's token); Mac and Ip are masked by
# their patterns, the known ones numbered first.
$script:SafeLiteralCategories = @('Email', 'Sid', 'Computer', 'Domain', 'User', 'Serial', 'Ssid')
# Names that may be common words: masked only as a whole word.
$script:SafeWordCategories = @('User', 'Ssid')
$script:SafeMinLength = 3
$script:SafeWordBelow = 6
# Every regex of the masker gives up after this (a SAFE copy that cannot be made is not written).
$script:SafeRegexTimeout = [TimeSpan]::FromSeconds(10)
# Every token, so a profile folder already masked is not masked again.
$script:SafeTokenPattern = '^(user|PC-|DOMAIN-|SERIAL-|MAC-|IP-|IP6-|SSID-|EMAIL-|PHONE-|SID-)[0-9]+\z'
# A text that starts with a token: a profile name a known value already masked ("user1 was ...", ruling RD-R26).
$script:SafeTokenStartPattern = '\A(?:user|PC-|DOMAIN-|SERIAL-|MAC-|IP-|IP6-|SSID-|EMAIL-|PHONE-|SID-)[0-9]+(?![0-9])'
# Where a cut form of a known value may end (review M3, RD-R26): at the end of a line, with the cut marker " ..." or not.
$script:SafeCutEnd = '(?=(?:[ \t]*\.\.\.)?[ \t]*(?:\r?\n|\z))'

# Account and profile folder names that are the same on every PC (never a person's): kept as they are.
$script:SafeGenericAccounts = @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount', 'defaultuser0', 'defaultuser100000', 'Public', 'Default',
  'Default User', 'All Users', 'SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'LocalService', 'NetworkService', 'Administrators', 'Users',
  'Authenticated Users', 'INTERACTIVE', 'Domain Admins', 'Domain Users', 'Enterprise Admins')
# Words that are never a personal value, whatever the report read them as (ruling RD-R25, review I2): common account
# names, Windows' and a home router's generic names, and the brand names. Compared whole, case-insensitively.
$script:SafeStopWords = @('user', 'users', 'admin', 'administrator', 'owner', 'guest', 'home', 'office', 'network', 'temp', 'tmp', 'test', 'pc', 'laptop',
  'desktop', 'computer', 'windows', 'microsoft', 'workgroup', 'mshome', 'lan', 'local', 'localdomain', 'home.arpa', 'wifi', 'wi-fi', 'internet', 'default',
  'public', 'system', 'service', 'server', 'client', 'unknown', 'none', 'dell', 'hp', 'lenovo', 'asus', 'acer', 'msi', 'surface', 'samsung', 'toshiba',
  'apple', 'intel', 'huawei', 'xiaomi', 'gigabyte')
# Windows' own names of a network that has no name of its own (the Hebrew network and unidentified network built
# from code points: this file stays ASCII), with an optional number (Network 2).
$script:SafeHebrewNetwork = [string]::new([char[]]@(0x05E8, 0x05E9, 0x05EA))
$script:SafeHebrewUnidentified = [string]::new([char[]]@(0x05DC, 0x05D0, 0x20, 0x05DE, 0x05D6, 0x05D5, 0x05D4, 0x05D4))
$script:SafeGenericNetworkPattern = '\A(?:Network|Unidentified network|' + $script:SafeHebrewNetwork + '(?: ' + $script:SafeHebrewUnidentified + ')?)(?: [0-9]+)?\z'
# The Hebrew prefix letters a word may carry (b, h, v, k, l, m, sh), up to three of them, before a known name (a
# Latin one too, RD-R26), and no letter or digit before them.
$script:SafeHebrewPrefixBoundary = '(?<=(?:^|[^\p{L}\p{Nd}])[' + [string]::new([char[]]@(0x05D1, 0x05D4, 0x05D5, 0x05DB, 0x05DC, 0x05DE, 0x05E9)) + ']{0,3})'
# The part before '\' of an account that names no domain of the customer's.
$script:SafeGenericAuthorities = @('NT AUTHORITY', 'BUILTIN', 'AzureAD', 'MicrosoftAccount', 'NT SERVICE', 'Window Manager', 'Font Driver Host',
  'IIS APPPOOL', 'NT VIRTUAL MACHINE')

# The patterns, in the order they run (after the known values). Spec 6.8, the Task 8 review and ruling RD-R25:
#   e-mail (also URL-encoded, %40);
#   SID (S-1-5-21-..., S-1-12-1-...) wherever it is, after a letter, a digit or a dash too (a per-user task's name
#     holds one),
#     before the phone numbers (a SID holds long digit runs); well-known SIDs (S-1-5-18, S-1-5-32-544) stay;
#   MAC with ':' or '-'; MAC as aaaa.bbbb.cccc; MAC as 12 hex digits (only beside no letter, digit or '-', so a GUID's
#     last group and a 0x number stay); the last two only with a hex letter in them unless the MAC is known, so plain
#     numbers stay;
#   IPv4 (a sentence's full stop after it does not hide it; five-part versions stay); IPv6 (also right after a colon:
#     "Address:2a00::1");
#   a profile folder: <drive>:\Users\<name>, c$\Users\<name>, %SystemDrive%\Users\<name>, with '\', '/' or a JSON-
#     doubled '\\' (the name up to the next separator; else, when the line ends within two words, those words (a
#     spaced name); else one word: the words after a name stay and go through every pass, RD-R26). A name that starts
#     with a token was masked as a known value already and stays;
#   an Israeli phone number: the spec's pinned pattern widened (review M1) to 972 / 00972 / +972 (with an optional
#     "(0)"), an area code in parentheses, '.' or ' - ' as separators, and the 3-4 and 3-2-2 groupings of the last
#     seven digits; RD-R26 adds parentheses around the country or area code ("(+972) 50", "+972 (50)") and the 4-3 and
#     2-2-3 groupings. Every number the pinned pattern finds, this one finds, except one right after a letter or a "0x"
#     (a hex value, a KB or product id). No digit, '+' or letter before it, and no digit (or '-'/'.' and a digit,
#     a GUID's or a version's next part) after it.
$script:SafeEmailPattern = '[A-Za-z0-9._%+-]+(?:@|%40)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
$script:SafeSidPattern = 'S-1-(?:5-21|12-1)(?:-[0-9]{1,10}){1,14}(?![0-9])'
$script:SafeMacPattern = '(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])'
$script:SafeMacDottedPattern = '(?<![0-9A-Za-z.])[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}(?![0-9A-Za-z]|\.[0-9A-Za-z])'
$script:SafeMacCompactPattern = '(?<![0-9A-Za-z-])[0-9A-Fa-f]{12}(?![0-9A-Za-z-])'
$script:SafeIpv4Pattern = '(?<!\d)(?<!\d\.)(?:\d{1,3}\.){3}\d{1,3}(?!\.?\d)'
$script:SafeIpv6Pattern = '(?<![0-9A-Za-z.%])(?:[0-9A-Fa-f]{0,4}:){2,7}(?:[0-9A-Fa-f]{1,4}|(?:\d{1,3}\.){3}\d{1,3})?(?:%[0-9A-Za-z]+)?(?![0-9A-Za-z:%]|\.\d)'
$script:SafeProfilePattern = '(?<drive>(?:[A-Za-z]:|[A-Za-z]\$|%SystemDrive%)[\\/]{1,2}Users[\\/]{1,2})(?:(?<name>[^\\/:*?"<>|\r\n]+)(?=[\\/])|(?<name>[^\\/:*?"<>|\r\n\s]+(?: [^\\/:*?"<>|\r\n\s]+)?)(?=[ \t]*(?:\r?\n|\z))|(?<name>[^\\/:*?"<>|\r\n\s,;''()\[\]]*[^\\/:*?"<>|\r\n\s,;''()\[\].]))'
$script:SafePhonePattern = '(?<![\dA-Za-z+])(?:(?:\(?(?:\+|00)972\)?|972)[-. ]{0,3}(?:\(0\)[-. ]{0,2})?\(?(?:[23489]|5\d|7\d)\)?|\(?0(?:[23489]|5\d|7\d)\)?)[-. ]{0,3}(?:\d{3}[-. ]{0,3}\d{4}|\d{3}[-. ]{1,3}\d{2}[-. ]{1,3}\d{2}|\d{4}[-. ]{1,3}\d{3}|\d{2}[-. ]{1,3}\d{2}[-. ]{1,3}\d{3})(?!\d|[-.]\d)'

# The second line of a SAFE copy (ASCII), for the AI and for Ben.
$script:SafeCopyNote = 'PRIVACY-SAFE COPY: names, e-mail addresses, serial numbers, MAC and IP addresses, network names, SIDs and phone numbers are replaced by tokens (user1, PC-1, SERIAL-1, MAC-1, IP-1, SSID-1, EMAIL-1, PHONE-1, SID-1, ...); one token is always the same value.'

# --- The personal values of a report -------------------------------------------------------------------------------

function Add-SafeIdentifier {
  # Private. Adds each text of -Value (a string or a list) to -Lists.<Category>, trimmed, once (case-insensitive).
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$Lists,
    [Parameter(Mandatory)][string]$Category,
    [AllowNull()]$Value
  )

  foreach ($v in (ConvertTo-ReportList -Value $Value)) {
    if ($null -eq $v -or $v -is [System.Collections.IDictionary]) { continue }
    $text = ([string]$v).Trim()
    if ($text -eq '') { continue }
    if ($Category -cin $script:SafeLiteralCategories -and (Test-SafeGenericValue -Value $text)) { continue }
    $list = $Lists[$Category]
    $known = $false
    foreach ($x in $list) { if ([string]::Equals($x, $text, [StringComparison]::OrdinalIgnoreCase)) { $known = $true; break } }
    if (-not $known) { $list.Add($text) }
  }
}

function Test-SafeGenericName {
  # Private, pure. $true when -Name is a built-in account or profile folder name (the same on every PC).
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()][AllowEmptyString()][string]$Name)

  foreach ($g in $script:SafeGenericAccounts) { if ([string]::Equals($g, ([string]$Name).Trim(), [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  return $false
}

function Test-SafeGenericValue {
  <#
  .SYNOPSIS
    Private, pure. $true when -Value is never a personal value (ruling RD-R25, review I2): a built-in account or profile
    name (Test-SafeGenericName), a word of $script:SafeStopWords, Windows' own name of a network without one
    ($script:SafeGenericNetworkPattern: "Network", "Network 2", "Unidentified network", the Hebrew ones), or a number
    under 6 digits (a battery's "1234" would mask every "1234" of the report). Compared whole, case-insensitively.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([AllowNull()][AllowEmptyString()][string]$Value)

  $text = ([string]$Value).Trim()
  if (Test-SafeGenericName -Name $text) { return $true }
  foreach ($w in $script:SafeStopWords) { if ([string]::Equals($w, $text, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  if ($text -match $script:SafeGenericNetworkPattern) { return $true }
  if ($text -match '\A[0-9]{1,5}\z') { return $true }
  return $false
}

function Get-SafeTokenText {
  # Private, pure. -Token as written into -Source in place of the text that ends at -End: with an underscore after it
  # when a letter or a digit follows (review M4: "SERIAL-2_99", never "SERIAL-299").
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Token, [AllowNull()][AllowEmptyString()][string]$Source, [int]$End)

  if ($null -ne $Source -and $End -ge 0 -and $End -lt $Source.Length -and [char]::IsLetterOrDigit($Source[$End])) { return $Token + '_' }
  return $Token
}

function Add-SafeAccount {
  # Private. An account name ('NAME', 'AUTHORITY\NAME'): its authority to Domain unless it is generic or one of the
  # computer names already listed, its name to User (to Email when it is an e-mail address) unless it is built in
  # (Test-SafeGenericName, or one of -Builtin: the PC's own Guest, DefaultAccount and WDAGUtilityAccount, by SID).
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Collections.IDictionary]$Lists, [AllowNull()]$Account, [AllowNull()][string[]]$Builtin)

  $text = ([string]$Account).Trim()
  if ($text -eq '') { return }
  $name = $text
  $cut = $text.IndexOf('\')
  if ($cut -ge 0) {
    $authority = $text.Substring(0, $cut).Trim()
    $name = $text.Substring($cut + 1).Trim()
    $generic = $false
    foreach ($g in $script:SafeGenericAuthorities) { if ([string]::Equals($g, $authority, [StringComparison]::OrdinalIgnoreCase)) { $generic = $true } }
    foreach ($c in $Lists['Computer']) { if ([string]::Equals($c, $authority, [StringComparison]::OrdinalIgnoreCase)) { $generic = $true } }
    if (-not $generic) { Add-SafeIdentifier -Lists $Lists -Category 'Domain' -Value $authority }
  }
  if ($name -eq '' -or (Test-SafeGenericValue -Value $name)) { return }
  foreach ($b in @($Builtin)) { if ([string]::Equals([string]$b, $name, [StringComparison]::OrdinalIgnoreCase)) { return } }
  if ($name -match ('\A' + $script:SafeEmailPattern + '\z')) { Add-SafeIdentifier -Lists $Lists -Category 'Email' -Value $name; return }
  Add-SafeIdentifier -Lists $Lists -Category 'User' -Value $name
}

function Add-SafeSerial {
  # Private. A serial number, unless it is a placeholder (Test-PlaceholderSerial: "To Be Filled By O.E.M.", one
  # character repeated): masking "00000000" would wreck every hex code.
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Collections.IDictionary]$Lists, [AllowNull()]$Value)

  foreach ($v in (ConvertTo-ReportList -Value $Value)) {
    if ($null -eq $v -or $v -is [System.Collections.IDictionary]) { continue }
    if (-not (Test-PlaceholderSerial -Serial ([string]$v))) { Add-SafeIdentifier -Lists $Lists -Category 'Serial' -Value ([string]$v) }
  }
}

function Get-ReportIdentifiers {
  <#
  .SYNOPSIS
    The personal values -Report holds (New-ToolReport's report: its Identity and Items, ToolReport.ps1's list of personal
    Items), as @{ User; Computer; Serial; Mac; Ip; Ssid; Email; Sid; Domain }, each a [string[]] in a fixed order. Pure.
  .DESCRIPTION
    User: the local users, the signed-in user, the Administrators' names and the profile folders (built-in names such as
      Administrator and Guest left out; DOMAIN\name gives its domain too).
    Computer: the computer name (Identity and Items) and the name the setup would give it (New-PcName).
    Serial: the BIOS serial and UUID, the board, RAM, monitor, battery and disk serials, a USB device's serial in its
      instance ID, and -Earlier's disk serials (a disk that is gone shows in "since last visit"); placeholders left out.
    Mac: the adapters' MAC addresses. Ip: their addresses, gateways and DNS servers, and the current ones.
    Ssid: the Wi-Fi networks and every known network's name. Email: the OneDrive e-mail addresses and an account that is
      one. Sid: the signed-in user's and the Administrators' SIDs (S-1-5-21-..., S-1-12-1-...).
    Domain: the AD domain, the domain part of an account, a workgroup other than WORKGROUP and the user proxy's host.
    -Earlier (a data JSON read by Find-ToolEarlierReport) adds its computer name, serials and disk serials.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]$Report,
    [AllowNull()]$Earlier
  )

  $lists = [ordered]@{}
  foreach ($c in 'User', 'Computer', 'Serial', 'Mac', 'Ip', 'Ssid', 'Email', 'Sid', 'Domain') { $lists[$c] = New-Object System.Collections.Generic.List[string] }
  $identity = Get-ReportEntry -From $Report -Name 'Identity'
  $items = Get-ReportEntry -From $Report -Name 'Items'
  $item = { param($name) Get-ReportEntry -From $items -Name $name }
  $earlierIdentity = Get-ReportEntry -From $Earlier -Name 'Identity'

  # The computer: its name now and before, and the name the setup gives it (DELL-<serial>).
  Add-SafeIdentifier -Lists $lists -Category 'Computer' -Value (Get-ReportEntry -From $identity -Name 'ComputerName')
  Add-SafeIdentifier -Lists $lists -Category 'Computer' -Value (& $item 'ComputerName')
  Add-SafeIdentifier -Lists $lists -Category 'Computer' -Value (Get-ReportEntry -From $earlierIdentity -Name 'ComputerName')
  $serial = [string](Get-ReportEntry -From $identity -Name 'Serial')
  $brand = [string](Get-ReportEntry -From $identity -Name 'Brand')
  if ($brand -ne '' -and -not (Test-PlaceholderSerial -Serial $serial)) {
    try { Add-SafeIdentifier -Lists $lists -Category 'Computer' -Value (New-PcName -Brand $brand -Serial $serial -BiosUuid ([string](Get-ReportEntry -From $identity -Name 'BiosUuid'))) } catch { $null = $_ }
  }

  # Accounts and profile folders (the PC's own built-in accounts, found by SID, stay: section 11's BuiltinUsers).
  $builtin = [string[]]@(foreach ($b in (ConvertTo-ReportList -Value (& $item 'BuiltinUsers'))) { [string]$b })
  Add-SafeAccount -Lists $lists -Account (& $item 'SignedInUser') -Builtin $builtin
  foreach ($a in (ConvertTo-ReportList -Value (& $item 'Admins'))) { Add-SafeAccount -Lists $lists -Account (Get-ReportEntry -From $a -Name 'Name') -Builtin $builtin }
  foreach ($u in (ConvertTo-ReportList -Value (& $item 'Users'))) { Add-SafeAccount -Lists $lists -Account $u -Builtin $builtin }
  foreach ($p in (ConvertTo-ReportList -Value (& $item 'Profiles'))) {
    $leaf = ''
    try { $leaf = [IO.Path]::GetFileName(([string]$p).TrimEnd('\')) } catch { $leaf = '' }
    if ($leaf -ne '' -and -not (Test-SafeGenericName -Name $leaf)) { Add-SafeIdentifier -Lists $lists -Category 'User' -Value $leaf }
  }
  Add-SafeIdentifier -Lists $lists -Category 'Email' -Value (& $item 'OneDriveEmails')
  foreach ($sid in @(& $item 'SignedInSid') + @(foreach ($a in (ConvertTo-ReportList -Value (& $item 'Admins'))) { Get-ReportEntry -From $a -Name 'Sid' })) {
    if ([string]$sid -match '\AS-1-(5-21|12-1)-') { Add-SafeIdentifier -Lists $lists -Category 'Sid' -Value ([string]$sid) }
  }

  # Serials: the machine's, its parts' and its disks' (and the earlier visit's disks).
  Add-SafeSerial -Lists $lists -Value $serial
  Add-SafeSerial -Lists $lists -Value (& $item 'Serial')
  Add-SafeSerial -Lists $lists -Value (Get-ReportEntry -From $earlierIdentity -Name 'Serial')
  foreach ($uuid in (Get-ReportEntry -From $identity -Name 'BiosUuid'), (& $item 'BiosUuid')) {
    if (Test-UsableBiosUuid -BiosUuid ([string]$uuid)) { Add-SafeIdentifier -Lists $lists -Category 'Serial' -Value ([string]$uuid) }
  }
  foreach ($name in 'BoardSerial', 'RamSerials', 'MonitorSerials', 'BatterySerials') { Add-SafeSerial -Lists $lists -Value (& $item $name) }
  foreach ($d in (ConvertTo-ReportList -Value (& $item 'Disks'))) { Add-SafeSerial -Lists $lists -Value (Get-ReportEntry -From $d -Name 'Serial') }
  $earlierDisks = Get-ReportEntry -From $Earlier -Name 'Disks'
  if ($earlierDisks -is [System.Collections.IDictionary]) {
    foreach ($k in @($earlierDisks.Keys)) { if ([string]$k -notmatch '\ADisk [0-9]+\z') { Add-SafeSerial -Lists $lists -Value ([string]$k) } }
  }
  # A USB device's instance ID ends in its serial when it has one (no '&' in the last part).
  foreach ($dev in (ConvertTo-ReportList -Value (& $item 'ProblemDevices'))) {
    $id = [string](Get-ReportEntry -From $dev -Name 'Id')
    if ($id -match '\A(USB|USBSTOR)\\' -and $id.LastIndexOf('\') -lt $id.Length - 1) {
      $last = $id.Substring($id.LastIndexOf('\') + 1)
      if ($last -notmatch '&') { Add-SafeSerial -Lists $lists -Value $last }
    }
  }

  # The network: MACs, addresses, network names, the domain, a custom workgroup and the proxy's host.
  foreach ($adapter in (ConvertTo-ReportList -Value (& $item 'Adapters'))) {
    Add-SafeIdentifier -Lists $lists -Category 'Mac' -Value (Get-ReportEntry -From $adapter -Name 'Mac')
    foreach ($address in (ConvertTo-ReportList -Value (Get-ReportEntry -From $adapter -Name 'Addresses'))) {
      if ($address -is [System.Collections.IDictionary] -or $address -is [System.Management.Automation.PSCustomObject]) { $address = Get-ReportEntry -From $address -Name 'Ip' }
      Add-SafeIdentifier -Lists $lists -Category 'Ip' -Value $address
    }
    Add-SafeIdentifier -Lists $lists -Category 'Ip' -Value (Get-ReportEntry -From $adapter -Name 'Gateways')
    Add-SafeIdentifier -Lists $lists -Category 'Ip' -Value (Get-ReportEntry -From $adapter -Name 'Dns')
  }
  foreach ($name in 'CurrentAddresses', 'Gateways', 'DnsServers') { Add-SafeIdentifier -Lists $lists -Category 'Ip' -Value (& $item $name) }
  Add-SafeIdentifier -Lists $lists -Category 'Ssid' -Value (& $item 'Ssids')
  foreach ($n in (ConvertTo-ReportList -Value (& $item 'NetworkProfiles'))) { Add-SafeIdentifier -Lists $lists -Category 'Ssid' -Value (Get-ReportEntry -From $n -Name 'Name') }
  Add-SafeIdentifier -Lists $lists -Category 'Domain' -Value (& $item 'Domain')
  $workgroup = ([string](& $item 'Workgroup')).Trim()
  if ($workgroup -ne '' -and -not [string]::Equals($workgroup, 'WORKGROUP', [StringComparison]::OrdinalIgnoreCase)) { Add-SafeIdentifier -Lists $lists -Category 'Domain' -Value $workgroup }
  foreach ($part in ([string](& $item 'UserProxy')) -split ';') {
    $hostName = $part
    if ($hostName.Contains('=')) { $hostName = $hostName.Substring($hostName.IndexOf('=') + 1) }
    $hostName = ($hostName -replace '\A[A-Za-z]+://', '') -replace '[:/].*\z', ''
    $parsed = $null
    if ($hostName.Trim().Length -ge $script:SafeMinLength -and -not [ipaddress]::TryParse($hostName.Trim(), [ref]$parsed)) { Add-SafeIdentifier -Lists $lists -Category 'Domain' -Value $hostName }
  }

  $result = @{}
  foreach ($c in @($lists.Keys)) { $result[$c] = [string[]]$lists[$c].ToArray() }
  return $result
}

# --- The masker ----------------------------------------------------------------------------------------------------

function New-SafeRegex {
  # Private. A compiled regex of -Pattern (case-insensitive unless -CaseSensitive), with the masker's time limit.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Pattern, [switch]$CaseSensitive)

  $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
  if (-not $CaseSensitive) { $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
  return (New-Object Text.RegularExpressions.Regex($Pattern, $options, $script:SafeRegexTimeout))
}

function Get-SafeToken {
  # Private. The token of -Key in -Category: the one it already has, else the category's next number.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Masker,
    [Parameter(Mandatory)][string]$Category,
    [Parameter(Mandatory)][string]$Key
  )

  $map = $Masker['Tokens'][$Category]
  $token = $null
  if ($map.TryGetValue($Key, [ref]$token)) { return $token }
  $Masker['Counts'][$Category]++
  $token = $script:SafeTokenFormats[$Category] -f $Masker['Counts'][$Category]
  $map[$Key] = $token
  return $token
}

function ConvertTo-SafeAddress {
  # Private, pure. -Text as an [ipaddress] when it is an IPv4 address of four parts or an IPv6 address (a zone '%7',
  # a prefix '/24' and brackets ignored), else $null.
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyString()][string]$Text)

  $value = ([string]$Text).Trim().Trim('[', ']') -replace '/[0-9]{1,3}\z', ''
  if ($value -notmatch '\A(?:\d{1,3}\.){3}\d{1,3}\z' -and $value -notmatch ':') { return $null }
  $parsed = $null
  if (-not [ipaddress]::TryParse($value, [ref]$parsed)) { return $null }
  return $parsed
}

function Get-SafeAddressKey {
  # Private, pure. @{ Category = 'Ip'|'Ip6'; Key } of an address, or $null for the ones that stay: 0.0.0.0, 127.0.0.1,
  # 255.255.255.255, a mask (255.x.x.x), :: and ::1 (spec 6.8: the AI can still read them).
  [CmdletBinding()]
  param([Parameter(Mandatory)][ipaddress]$Address)

  if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
    $key = $Address.ToString()
    if ($key -in '0.0.0.0', '127.0.0.1' -or $key.StartsWith('255.', [StringComparison]::Ordinal)) { return $null }
    return @{ Category = 'Ip'; Key = $key }
  }
  # The address without its zone (fe80::1%7 is fe80::1).
  $key = (New-Object Net.IPAddress (, $Address.GetAddressBytes())).ToString()
  if ($key -in '::', '::1') { return $null }
  return @{ Category = 'Ip6'; Key = $key }
}

function New-SafeMasker {
  <#
  .SYNOPSIS
    A masker for one report: the known values of -Known (@{ User; Computer; Serial; Mac; Ip; Ssid; Email; Sid; Domain },
    Get-ReportIdentifiers' shape; a missing list is none) numbered in their lists' order, and the state the patterns
    add to (ConvertTo-SafeText). Use one masker per report, so a value has one token in the whole file.
  .DESCRIPTION
    Known values under 3 characters and generic values (Test-SafeGenericValue: stop words, built-in names, Windows' own
    network names, numbers under 6 digits) are ignored. A known e-mail, SID, computer, domain, user, serial or network
    name is masked as text (its display form too, ConvertTo-ToolDisplayText), in one of three modes:
      - Number (a value of digits only, 6 or more): only where no digit is beside it;
      - Word (a user or network name, a computer or domain name of letters only, any value under 6 characters): only
        where no letter or digit is beside it; one that starts with a Hebrew letter may carry up to three Hebrew prefix
        letters before it ($script:SafeHebrewPrefixBoundary), which stay;
      - anywhere (every other value).
    Known MACs and IP addresses take the first numbers of their categories; the patterns mask every spelling of them.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Known)

  $masker = @{ Tokens = @{}; Counts = @{}; Literals = $null; Cuts = $null; CutTokens = @(); LiteralTokens = (New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)) }
  foreach ($c in @($script:SafeTokenFormats.Keys)) {
    $masker['Tokens'][$c] = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $masker['Counts'][$c] = 0
  }
  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($category in $script:SafeLiteralCategories) {
    foreach ($v in (ConvertTo-ReportList -Value (Get-ReportEntry -From $Known -Name $category))) {
      if ($null -eq $v -or $v -is [System.Collections.IDictionary]) { continue }
      $value = ([string]$v).Trim()
      if ($value.Length -lt $script:SafeMinLength -or (Test-SafeGenericValue -Value $value)) { continue }
      $key = $value
      if ($category -ceq 'Email') { $key = $value.ToLowerInvariant() } elseif ($category -ceq 'Sid') { $key = $value.ToUpperInvariant() }
      $token = Get-SafeToken -Masker $masker -Category $category -Key $key
      foreach ($form in $value, (ConvertTo-ToolDisplayText -Text $value -MaxLength 4096)) {
        if ($form.Length -lt $script:SafeMinLength -or $masker['LiteralTokens'].ContainsKey($form)) { continue }
        $masker['LiteralTokens'][$form] = $token
        $mode = 'Anywhere'
        if ($category -ceq 'Sid') { $mode = 'Sid' }
        elseif ($form -match '\A[0-9]+\z') { $mode = 'Number' }
        elseif (($script:SafeWordCategories -ccontains $category) -or $form.Length -lt $script:SafeWordBelow -or
                ($category -cin 'Computer', 'Domain' -and $form -match '\A\p{L}+\z')) { $mode = 'Word' }
        $entries.Add(@{ Value = $form; Mode = $mode; Token = $token })
      }
    }
  }
  foreach ($v in (ConvertTo-ReportList -Value (Get-ReportEntry -From $Known -Name 'Mac'))) {
    $hex = ([string]$v) -replace '[^0-9A-Fa-f]', ''
    if ($hex.Length -eq 12) { $null = Get-SafeToken -Masker $masker -Category 'Mac' -Key $hex.ToUpperInvariant() }
  }
  foreach ($v in (ConvertTo-ReportList -Value (Get-ReportEntry -From $Known -Name 'Ip'))) {
    $address = ConvertTo-SafeAddress -Text ([string]$v)
    if ($null -eq $address) { continue }
    $where = Get-SafeAddressKey -Address $address
    if ($null -ne $where) { $null = Get-SafeToken -Masker $masker -Category $where.Category -Key $where.Key }
  }
  if ($entries.Count -gt 0) {
    # Longest first, so at any place the longest known value wins (a serial inside the PC name is the PC name there).
    $sorted = @($entries.ToArray() | Sort-Object -Property @{ Expression = { $_.Value.Length }; Descending = $true }, @{ Expression = { $_.Value }; Descending = $false })
    $parts = foreach ($e in $sorted) {
      $escaped = [regex]::Escape($e.Value)
      switch -CaseSensitive ($e.Mode) {
        'Number' { '(?<![0-9])' + $escaped + '(?![0-9])' }
        'Sid' { $escaped + '(?![0-9])' }   # never the start of a longer SID (RD-R26)
        'Word' {
          # A name may carry up to three Hebrew prefix letters ("to Dana" is one Hebrew word; review I3), a Latin one
          # too (RD-R26); a letter or a digit before them is no word start.
          $left = $script:SafeHebrewPrefixBoundary
          $left + $escaped + '(?![\p{L}\p{Nd}])'
        }
        default { $escaped }
      }
    }
    $masker['Literals'] = New-SafeRegex -Pattern (@($parts) -join '|')
    # The cut forms (review M3, RD-R26): a line that ends after the first words of a known value of two or more words,
    # and maybe the start of the next word ("Moshe", "Moshe Le" of "Moshe Levi"), gets that value's token. A leading
    # part that is generic or a known value of its own is left to its own rule. One regex for all of them: group c<n>
    # is value n (longest first), CutTokens[n] its token.
    $groups = New-Object System.Collections.Generic.List[string]
    $cutTokens = New-Object System.Collections.Generic.List[string]
    foreach ($e in $sorted) {
      $words = @([regex]::Split($e.Value, '\s+'))
      if ($words.Count -lt 2) { continue }
      $alts = New-Object System.Collections.Generic.List[string]
      for ($k = $words.Count - 1; $k -ge 1; $k--) {
        $lead = $words[0..($k - 1)] -join ' '
        if ($lead.Length -lt $script:SafeMinLength -or (Test-SafeGenericValue -Value $lead) -or $masker['LiteralTokens'].ContainsKey($lead)) { continue }
        $next = $words[$k]
        $partial = ''
        if ($next.Length -ge 2) {
          $inner = ''
          for ($i = $next.Length - 2; $i -ge 1; $i--) { $inner = '(?:' + [regex]::Escape([string]$next[$i]) + $inner + ')?' }
          $partial = '(?:[ \t]+' + [regex]::Escape([string]$next[0]) + $inner + ')?'
        }
        $alts.Add(((@(foreach ($w in $words[0..($k - 1)]) { [regex]::Escape($w) }) -join '[ \t]+') + $partial))
      }
      if ($alts.Count -eq 0) { continue }
      $groups.Add(('(?<c{0}>{1})' -f $cutTokens.Count, ($alts.ToArray() -join '|')))
      $cutTokens.Add([string]$e.Token)
    }
    if ($groups.Count -gt 0) {
      $masker['Cuts'] = New-SafeRegex -Pattern ($script:SafeHebrewPrefixBoundary + '(?:' + ($groups.ToArray() -join '|') + ')' + $script:SafeCutEnd)
      $masker['CutTokens'] = $cutTokens.ToArray()
    }
  }
  return $masker
}

function ConvertTo-SafeText {
  <#
  .SYNOPSIS
    -Text with every personal value turned into its token (see the top of this file), through -Masker (New-SafeMasker),
    whose tokens it extends. Throws when a regex runs out of time: the caller writes no SAFE copy then.
  .DESCRIPTION
    First the known values (longest first, case-insensitive), then their cut forms at the end of a line (RD-R26), then
    the patterns (see the top of this file): e-mail
    (also %40); SID (S-1-5-21-..., S-1-12-1-..., after a letter too; well-known SIDs such as S-1-5-18 stay); MAC
    (aa:bb:..., aa-bb-..., aaaa.bbbb.cccc and 12 hex digits); IPv4 and IPv6 (each confirmed with [ipaddress]::TryParse,
    so times and versions stay; 0.0.0.0, 127.0.0.1, 255.255.255.255, masks, :: and ::1 stay); a profile folder (C:\Users\,
    c$\Users\, %SystemDrive%\Users\, with \, / or \\: the name as a user token; generic and built-in folders stay); an
    Israeli phone number. A token that a letter or digit follows gets an underscore after it.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][hashtable]$Masker,
    [AllowNull()][AllowEmptyString()][string]$Text
  )

  if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
  # Each pass reads $source (the text before it) and writes $value. A token that a letter or a digit follows gets an
  # underscore after it (Get-SafeTokenText; review M4).
  $value = $Text
  if ($null -ne $Masker['Literals']) {
    $source = $value
    $value = $Masker['Literals'].Replace($source, [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $token = $null
        if (-not $Masker['LiteralTokens'].TryGetValue($m.Value, [ref]$token)) { $token = '[masked]' }
        Get-SafeTokenText -Token $token -Source $source -End ($m.Index + $m.Length) })
  }
  if ($null -ne $Masker['Cuts']) {
    $source = $value
    $value = $Masker['Cuts'].Replace($source, [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $token = '[masked]'
        for ($n = 0; $n -lt $Masker['CutTokens'].Count; $n++) { if ($m.Groups[('c' + $n)].Success) { $token = $Masker['CutTokens'][$n]; break } }
        Get-SafeTokenText -Token $token -Source $source -End ($m.Index + $m.Length) })
  }
  $source = $value
  $value = (New-SafeRegex -Pattern $script:SafeEmailPattern).Replace($source, [Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $token = Get-SafeToken -Masker $Masker -Category 'Email' -Key ($m.Value.ToLowerInvariant() -replace '%40', '@')
      Get-SafeTokenText -Token $token -Source $source -End ($m.Index + $m.Length) })
  $source = $value
  $value = (New-SafeRegex -Pattern $script:SafeSidPattern).Replace($source, [Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $token = Get-SafeToken -Masker $Masker -Category 'Sid' -Key $m.Value.ToUpperInvariant()
      Get-SafeTokenText -Token $token -Source $source -End ($m.Index + $m.Length) })
  $source = $value
  $value = (New-SafeRegex -Pattern $script:SafeMacPattern).Replace($source, [Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $token = Get-SafeToken -Masker $Masker -Category 'Mac' -Key (($m.Value -replace '[:-]', '').ToUpperInvariant())
      Get-SafeTokenText -Token $token -Source $source -End ($m.Index + $m.Length) })
  foreach ($pattern in $script:SafeMacDottedPattern, $script:SafeMacCompactPattern) {
    $source = $value
    $value = (New-SafeRegex -Pattern $pattern).Replace($source, [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $key = ($m.Value -replace '\.', '').ToUpperInvariant()
        if ($Masker['Tokens']['Mac'].ContainsKey($key) -or $key -match '[A-F]') {
          Get-SafeTokenText -Token (Get-SafeToken -Masker $Masker -Category 'Mac' -Key $key) -Source $source -End ($m.Index + $m.Length)
        } else { $m.Value } })
  }
  foreach ($pattern in $script:SafeIpv4Pattern, $script:SafeIpv6Pattern) {
    $source = $value
    $value = (New-SafeRegex -Pattern $pattern).Replace($source, [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $address = ConvertTo-SafeAddress -Text $m.Value
        $where = $null
        if ($null -ne $address) { $where = Get-SafeAddressKey -Address $address }
        if ($null -eq $where) { $m.Value }
        else { Get-SafeTokenText -Token (Get-SafeToken -Masker $Masker -Category $where.Category -Key $where.Key) -Source $source -End ($m.Index + $m.Length) } })
  }
  $source = $value
  $value = (New-SafeRegex -Pattern $script:SafeProfilePattern).Replace($source, [Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $name = $m.Groups['name'].Value
      $core = $name.TrimEnd('.', ' ', "`t")
      if ($core -eq '' -or $core -match $script:SafeTokenStartPattern -or (Test-SafeGenericValue -Value $core)) { $m.Value }
      else {
        $token = Get-SafeTokenText -Token (Get-SafeToken -Masker $Masker -Category 'User' -Key $core.Trim()) -Source $source -End ($m.Index + $m.Length)
        $m.Groups['drive'].Value + $token + $name.Substring($core.Length)
      } })
  $source = $value
  $value = (New-SafeRegex -Pattern $script:SafePhonePattern).Replace($source, [Text.RegularExpressions.MatchEvaluator] {
      param($m)
      # One number, one key: 00972 / 972 (and a "(0)" after it) as 0, so every spelling of it gets one token.
      $digits = $m.Value -replace '[^0-9]', ''
      if ($digits.StartsWith('00972', [StringComparison]::Ordinal)) { $digits = $digits.Substring(2) }
      if ($digits.StartsWith('972', [StringComparison]::Ordinal)) {
        $digits = $digits.Substring(3)
        if (-not $digits.StartsWith('0', [StringComparison]::Ordinal)) { $digits = '0' + $digits }
      }
      Get-SafeTokenText -Token (Get-SafeToken -Masker $Masker -Category 'Phone' -Key $digits) -Source $source -End ($m.Index + $m.Length) })
  return $value
}

function Save-ToolSafeCopy {
  <#
  .SYNOPSIS
    Writes the privacy-safe copy of -Lines (a report's core, or a comparison) to -Path: one masker over the personal
    values of -Report (and -Earlier: Get-ReportIdentifiers) and the patterns, the note $script:SafeCopyNote as its second
    line, UTF-8 with a BOM (Save-ToolReportText). Returns '' when written, else the reason for the window ('the
    privacy-safe copy is a link', 'the privacy-safe copy could not be written'). Never throws.
  .DESCRIPTION
    Fails closed: when anything goes wrong (the masker, a regex out of time, the stick) nothing is written, so no file
    with a SAFE name ever holds unmasked text. Nothing is written through a link (V2-R13). The log names the reason in
    ASCII and never the text.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
    [Parameter(Mandatory)]$Report,
    [AllowNull()]$Earlier
  )

  try {
    if (Test-StickReparsePoint -Path $Path) {
      Write-SetupLog -Level WARN -Message 'The privacy-safe copy was not written: its file is a link' -Data @{ file = (ConvertTo-ScreenText -Text ([IO.Path]::GetFileName($Path))) }
      return 'the privacy-safe copy is a link'
    }
    $masker = New-SafeMasker -Known (Get-ReportIdentifiers -Report $Report -Earlier $Earlier)
    $masked = [regex]::Split((ConvertTo-SafeText -Masker $masker -Text ($Lines -join "`n")), "`n")
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $masked.Count; $i++) {
      $out.Add($masked[$i])
      if ($i -eq 0) { $out.Add($script:SafeCopyNote) }
    }
    Save-ToolReportText -Path $Path -Lines $out.ToArray()
    return ''
  } catch {
    Write-SetupLog -Level WARN -Message 'The privacy-safe copy was not written' -Data @{
      file = (ConvertTo-ScreenText -Text ([IO.Path]::GetFileName($Path))); reason = (ConvertTo-ReportReason -Exception $_.Exception)
      error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    return 'the privacy-safe copy could not be written'
  }
}
