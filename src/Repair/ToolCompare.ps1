# src/Repair/ToolCompare.ps1
# Repair & diagnostics, Compare with last visit (repair spec 6.8; repair Task 9): this PC's newest earlier report on the
# stick (Find-ToolEarlierReport), what changed since (Compare-ToolReportData, pure), the "since last visit" section
# (Format-ToolSinceLastVisit), which Quick and Full reports put right after section 00, and the compare action's own
# step (Invoke-ToolStepCompare).
#
# "The same PC" is the identity key (Get-MachineIdentity: its serial, or its BIOS UUID when the serial is a
# placeholder), compared for equality: an empty key never matches, so different white boxes are never merged. Only the
# visit folders of this PC are read (<PC>_<folder part>_<stamp>, the folder part of the key; the window names them so):
# a stick full of other customers' reports costs nothing. A report data file of this PC that cannot be read (too big,
# not JSON, a link) is named (ruling RD-R23: never a silent comparison with nothing); one of another PC is passed over.
# Report data files are plain UTF-8 and read with $script:ToolReportDataMaxBytes (16 MB), never the 1 MB of the
# exchange files. Nothing on the stick is read or written through a link (V2-R13).
#
# Plan calls: Compare writes its own files (COMPARE_<PC>_<stamp>.txt: the header, the complaint and the section;
# COMPARE_SAFE_<stamp>.txt; and COMPARE_<PC>_<stamp>_data.json), so it is a visit too: the next Compare reads it. A
# finding is "new" or "resolved" only when the report that lacks it collected its section in full (a source that was not
# collected is no evidence); a list that one report lacks entirely (programs, disks) is not compared. A stopped compare
# writes nothing (no AlwaysRun): a part of a report is never compared.
#
# Needs ToolEngine (Add-ToolFinding, Add-ToolLog, Get-ToolText, Write-ToolJsonFile, ConvertTo-ToolDisplayText,
# Read-ToolJsonFile, $script:ToolReportDataMaxBytes), ToolReport (New-ToolReport, ConvertTo-ReportData,
# Format-ReportHead, Get-ReportEntry, ConvertTo-ReportList, ConvertTo-ReportDateTime, ConvertTo-ReportNumber,
# Format-ReportNumber, Format-ReportShortList, Get-ToolReportPcName, Get-ToolReportStamp, Get-ToolReportFolder,
# Save-ToolReportText), ToolPrivacy (Save-ToolSafeCopy), ToolCollect (ConvertTo-ReportReason), Report
# (Format-ReportDate), Cleanup (Test-StickReparsePoint), Logging and StartScreen (ConvertTo-ScreenText).

# A visit folder (Get-ToolboxSessionDir: <PC>_<folder part>_<yyyy-MM-dd_HHmm>, each part [A-Za-z0-9-]) and a report's
# data file in it (REPORT_ or COMPARE_<PC>_<stamp>[_<n>]_data.json).
$script:ToolVisitFolderPattern = '\A[A-Za-z0-9-]+_(?<part>[A-Za-z0-9-]+)_(?<stamp>[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4})\z'
$script:ToolReportDataPattern = '\A(?:REPORT|COMPARE)_[A-Za-z0-9-]+_(?<stamp>[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4})(?:_(?<n>[0-9]{1,2}))?_data\.json\z'
# At most this many data files, and this many bytes of them, are read in one search, newest first (review M7: a report
# past its deadline must not spend minutes parsing old files).
$script:ToolEarlierMaxReads = 32
$script:ToolEarlierMaxBytes = 64MB
# At most this many lines of one kind (installed, updated, removed programs) in the section; the rest are counted.
$script:CompareListMax = 40

# --- Finding the earlier report ------------------------------------------------------------------------------------

function Get-ToolIdentityFolderPart {
  <#
  .SYNOPSIS
    The folder part of an identity key, as Get-MachineIdentity makes it (Detect\PcName.ps1): 'SN-<serial>' gives the
    serial's right-most 20 characters, 'UUID-<32 hex>' gives 'UUID-<last 12 hex>'; anything else ''. Pure.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$IdentityKey)

  if ($IdentityKey -cmatch '\ASN-([A-Z0-9]+)\z') {
    $serial = $Matches[1]
    if ($serial.Length -gt 20) { $serial = $serial.Substring($serial.Length - 20) }
    return $serial
  }
  if ($IdentityKey -cmatch '\AUUID-([0-9A-F]{32})\z') { return 'UUID-' + $Matches[1].Substring(20) }
  return ''
}

function Find-ToolEarlierReport {
  <#
  .SYNOPSIS
    This PC's newest earlier report on the stick: the data JSON (a hashtable, plus File = its path) of the newest
    <StickRoot>BenTech-Reports\<visit>\REPORT_*_data.json or COMPARE_*_data.json whose Identity.Key equals -IdentityKey,
    outside -CurrentSessionDir; else $null. Never throws.
  .DESCRIPTION
    Only the visit folders of this PC are looked at (their folder part is the key's: Get-ToolIdentityFolderPart), newest
    first by the stamp in the file name, at most $script:ToolEarlierMaxReads files and $script:ToolEarlierMaxBytes bytes
    read. A file is read with Read-ToolJsonFile -MaxBytes $script:ToolReportDataMaxBytes (16 MB, ruling RD-R23). An empty
    or unknown key, no stick root or no BenTech-Reports: $null.
    -Skipped (optional) gets, newest first, everything of this PC that could not be read before the one returned
    (RD-R23: never a silent "nothing"; ruling RD-R25, review M5): '<file> (a link)', '<file> (too big)',
    '<file> (not a report data file)'; a visit folder that is a link is never listed ('<folder> (a link)'), one that
    cannot be listed is '<folder> (could not be listed)'; and 'BenTech-Reports (a link)' or 'BenTech-Reports (could not
    be listed)' when nothing on the stick could be looked at. A file of another PC that shares the folder part (two
    white boxes) is passed over.
  #>
  [CmdletBinding()]
  param(
    [AllowNull()][AllowEmptyString()][string]$StickRoot,
    [AllowNull()][AllowEmptyString()][string]$IdentityKey,
    [AllowNull()][AllowEmptyString()][string]$CurrentSessionDir,
    [AllowNull()][System.Collections.Generic.List[string]]$Skipped
  )

  $part = Get-ToolIdentityFolderPart -IdentityKey $IdentityKey
  if ([string]::IsNullOrEmpty($StickRoot) -or $part -eq '') { return $null }
  $say = {
    param($name, $why)
    $line = ConvertTo-ScreenText -Text ('{0} ({1})' -f $name, $why)
    if ($null -ne $Skipped) { $Skipped.Add($line) }
    Write-SetupLog -Level WARN -Message 'An earlier report of this PC could not be read' -Data @{ file = $line }
  }
  $reports = [IO.Path]::Combine($StickRoot, 'BenTech-Reports')
  $folders = @()
  try {
    if (-not [IO.Directory]::Exists($reports)) { return $null }
    if (Test-StickReparsePoint -Path $reports) { & $say 'BenTech-Reports' 'a link'; return $null }
    $folders = @([IO.Directory]::GetDirectories($reports))
  } catch {
    Write-SetupLog -Level WARN -Message 'Earlier reports could not be looked for' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    & $say 'BenTech-Reports' 'could not be listed'
    return $null
  }
  try {
    $current = ([string]$CurrentSessionDir).TrimEnd('\')
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($folder in $folders) {
      $name = [IO.Path]::GetFileName($folder)
      $visit = [regex]::Match($name, $script:ToolVisitFolderPattern)
      if (-not $visit.Success -or -not [string]::Equals($visit.Groups['part'].Value, $part, [StringComparison]::OrdinalIgnoreCase)) { continue }
      if ($current -ne '' -and [string]::Equals($folder.TrimEnd('\'), $current, [StringComparison]::OrdinalIgnoreCase)) { continue }
      $folderSort = $visit.Groups['stamp'].Value + '_00'
      try {
        if (Test-StickReparsePoint -Path $folder) {
          $candidates.Add(@{ Sort = $folderSort; Path = $folder; Name = $name; Why = 'a link' })
          continue
        }
        $files = @([IO.Directory]::GetFiles($folder, '*_data.json'))
      } catch {
        Write-SetupLog -Level WARN -Message 'A visit folder could not be listed' -Data @{ folder = (ConvertTo-ScreenText -Text $name); error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
        $candidates.Add(@{ Sort = $folderSort; Path = $folder; Name = $name; Why = 'could not be listed' })
        continue
      }
      foreach ($file in $files) {
        $fileName = [IO.Path]::GetFileName($file)
        $data = [regex]::Match($fileName, $script:ToolReportDataPattern)
        if (-not $data.Success) { continue }
        $n = 1
        if ($data.Groups['n'].Success) { $n = [int]$data.Groups['n'].Value }
        $candidates.Add(@{ Sort = ('{0}_{1:D2}' -f $data.Groups['stamp'].Value, $n); Path = $file; Name = $fileName; Why = '' })
      }
    }
    $newest = @($candidates.ToArray() | Sort-Object -Property @{ Expression = { [string]$_['Sort'] }; Descending = $true }, @{ Expression = { [string]$_['Path'] }; Descending = $true })
    $reads = 0
    [long]$bytes = 0
    foreach ($c in $newest) {
      if ($reads -ge $script:ToolEarlierMaxReads -or $bytes -ge $script:ToolEarlierMaxBytes) {
        Write-SetupLog -Level WARN -Message 'Earlier reports: stopped after the newest files' -Data @{ read = $reads; bytes = $bytes }
        break
      }
      $why = [string]$c['Why']
      if ($why -eq '') {
        $path = [string]$c['Path']
        $length = [long]0
        try {
          if (Test-StickReparsePoint -Path $path) { $why = 'a link' } else { $length = (New-Object IO.FileInfo $path).Length }
        } catch {
          $why = 'could not be read'
        }
        if ($why -eq '' -and $length -gt $script:ToolReportDataMaxBytes) { $why = 'too big' }
        if ($why -eq '') {
          $reads++
          $bytes += $length
          $value = Read-ToolJsonFile -Path $path -MaxBytes $script:ToolReportDataMaxBytes
          $key = Get-ReportEntry -From (Get-ReportEntry -From $value -Name 'Identity') -Name 'Key'
          if ($value -isnot [System.Collections.IDictionary] -or $key -isnot [string] -or $null -eq (ConvertTo-ReportDateTime -Value (Get-ReportEntry -From $value -Name 'CreatedAt'))) {
            $why = 'not a report data file'
          } elseif ([string]::Equals($key, $IdentityKey, [StringComparison]::Ordinal)) {
            $value['File'] = $path
            return $value
          } else {
            continue   # another PC whose folder part is this one's (two white boxes): never merged, nothing to say
          }
        }
      }
      & $say $c['Name'] $why
    }
  } catch {
    Write-SetupLog -Level WARN -Message 'Earlier reports could not be looked for' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    & $say 'BenTech-Reports' 'could not be listed'
  }
  return $null
}

function Find-ToolRunEarlierReport {
  # Private. -Run's earlier report (Find-ToolEarlierReport on Args.StickRoot, Args.Identity.Key and Args.SessionDir, the
  # visit's folder): @{ Earlier = <data or $null>; Skipped = [string[]] }. Never throws.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][hashtable]$Run)

  $skipped = New-Object System.Collections.Generic.List[string]
  $earlier = $null
  try {
    $key = [string](Get-ReportEntry -From $Run.Args['Identity'] -Name 'Key')
    $earlier = Find-ToolEarlierReport -StickRoot ([string]$Run.Args['StickRoot']) -IdentityKey $key -CurrentSessionDir ([string]$Run.Args['SessionDir']) -Skipped $skipped
  } catch {
    Write-SetupLog -Level WARN -Message 'Earlier reports could not be looked for' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
  }
  return @{ Earlier = $earlier; Skipped = [string[]]$skipped.ToArray() }
}

function Get-ToolRunSinceLastVisit {
  <#
  .SYNOPSIS
    Private. -Run's comparison with this PC's earlier report, for reportWrite and the compare step: @{ Earlier (the data
    compared with, or $null); Diff (Compare-ToolReportData, or $null); Skipped ([string[]], the files of this PC that
    could not be read); Lines (Get-ToolSinceLastVisitLines; -Always: also without an earlier report) }. Never throws: an
    earlier file the comparison cannot use is named in Skipped ('(not a report data file)') and nothing is compared, so
    a damaged file on the stick never costs the report itself.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][hashtable]$Run,
    [Parameter(Mandatory)]$Current,
    [switch]$Always
  )

  $found = Find-ToolRunEarlierReport -Run $Run
  $earlier = $found.Earlier
  $skipped = New-Object System.Collections.Generic.List[string]
  foreach ($s in @($found.Skipped)) { if ($null -ne $s) { $skipped.Add([string]$s) } }
  $diff = $null
  if ($null -ne $earlier) {
    try {
      $crashDays = [int](Get-ToolRepairNumber -Config $Run.Config -Path 'thresholds', 'crashDays' -Default 60)
      $diff = Compare-ToolReportData -Earlier $earlier -Current $Current -CrashDays $crashDays
    } catch {
      $name = ConvertTo-ScreenText -Text ('{0} (not a report data file)' -f [IO.Path]::GetFileName([string]$earlier['File']))
      Write-SetupLog -Level WARN -Message 'An earlier report of this PC could not be compared' -Data @{ file = $name; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
      $skipped.Add($name)
      $earlier = $null
      $diff = $null
    }
  }
  $lines = @()
  try {
    $lines = @(Get-ToolSinceLastVisitLines -Earlier $earlier -Diff $diff -Skipped $skipped.ToArray() -Always:$Always)
  } catch {
    Write-SetupLog -Level WARN -Message 'The since-last-visit section could not be written' -Data @{ error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    $lines = @()
    $earlier = $null
    $diff = $null
  }
  return @{ Earlier = $earlier; Diff = $diff; Skipped = [string[]]$skipped.ToArray(); Lines = [string[]]$lines }
}

# --- Comparing -----------------------------------------------------------------------------------------------------

function Get-CompareIncomplete {
  # Private, pure. The sections of a data JSON's findings that were not collected in full (a notCollected finding).
  [CmdletBinding()]
  [OutputType([string[]])]
  param([AllowNull()]$Data)

  $ids = @(foreach ($f in (ConvertTo-ReportList -Value (Get-ReportEntry -From $Data -Name 'Findings'))) {
      if ([string](Get-ReportEntry -From $f -Name 'Code') -ceq 'notCollected') { [string](Get-ReportEntry -From $f -Name 'Section') } })
  return [string[]]@($ids | Sort-Object -Unique)
}

function Get-CompareFindings {
  # Private, pure. A data JSON's findings other than notCollected, each code once: @{ Code; Level; Args; Section }.
  [CmdletBinding()]
  param([AllowNull()]$Data)

  $seen = @{}
  foreach ($f in (ConvertTo-ReportList -Value (Get-ReportEntry -From $Data -Name 'Findings'))) {
    $code = [string](Get-ReportEntry -From $f -Name 'Code')
    if ($code -eq '' -or $code -ceq 'notCollected' -or $seen.ContainsKey($code)) { continue }
    $seen[$code] = $true
    @{ Code = $code; Level = [string](Get-ReportEntry -From $f -Name 'Level'); Section = [string](Get-ReportEntry -From $f -Name 'Section')
       Args = [string[]]@(foreach ($a in (ConvertTo-ReportList -Value (Get-ReportEntry -From $f -Name 'Args'))) { [string]$a }) }
  }
}

function Get-CompareDisks {
  # Private, pure. A data JSON's disks as rows @{ Key; Number; Disk }, by their number (then key).
  [CmdletBinding()]
  param([AllowNull()]$Data)

  $disks = Get-ReportEntry -From $Data -Name 'Disks'
  if ($disks -isnot [System.Collections.IDictionary]) { return }
  $rows = @(foreach ($k in @($disks.Keys)) {
      $n = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $disks[$k] -Name 'Number')
      [pscustomobject]@{ Key = [string]$k; Number = $(if ($null -eq $n) { [double]::MaxValue } else { $n }); Disk = $disks[$k] } })
  foreach ($r in @($rows | Sort-Object -Property Number, Key)) { $r }
}

function Split-CompareProgram {
  # Private, pure. A program entry 'name|version' as @{ Name; Version } (the version after the last '|').
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyString()][string]$Entry)

  $cut = ([string]$Entry).LastIndexOf('|')
  if ($cut -lt 0) { return @{ Name = [string]$Entry; Version = '' } }
  return @{ Name = $Entry.Substring(0, $cut); Version = $Entry.Substring($cut + 1) }
}

function Compare-ToolReportData {
  <#
  .SYNOPSIS
    What changed between two report data JSONs (ConvertTo-ReportData's shape): -Earlier (the last visit's) and -Current.
    Pure.
  .DESCRIPTION
    @{ Since (the earlier CreatedAt, [datetime] or $null);
       Crashes = [ordered] BugCheck, KernelPower, Whea -> @{ Count; Newest } (the current events after Since);
       Disks = @( @{ Label; Kind = 'wear'|'errors'|'health'|'new'|'gone'; From; To; Model } ) (by disk serial);
       DisksCompared; Free = $null | @{ FromGB; ToGB; FromPercent; ToPercent } (a change of 1 GB or more);
       DevicesAdded, DevicesGone = @( @{ Name; Code } ) (by instance ID and code);
       ProgramsAdded, ProgramsRemoved = @( @{ Name; Version } ), ProgramsUpdated = @( @{ Name; From; To } ) ('name|version';
       one name removed and added is an update); ProgramsCompared;
       FindingsNew, FindingsResolved = @( @{ Code; Level; Args; Section } ) (by code; only when the report that lacks it
       collected that section in full); KindsDiffer; CrashWindowShort; CrashDays; Count (every change) }.
    A list one report lacks entirely (no programs, no disks) is not compared (DisksCompared / ProgramsCompared $false).
    Ruling RD-R25 (review I1): when the two reports are not of the same Kind (a Quick and a Full one; Compare collects the
    Quick sections), the codes only a Full report gives ($script:ReportFullOnlyCodes, ToolReport.ps1) are neither new
    nor resolved: one of the two never checked them (KindsDiffer, and a note says so). Review M6: the crash events cover
    the current report's last -CrashDays (repair.thresholds.crashDays, 60); when the last visit is older than that,
    CrashWindowShort is $true (a note says so).
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]$Earlier,
    [Parameter(Mandatory)]$Current,
    [ValidateRange(1, 3650)][int]$CrashDays = 60
  )

  $since = ConvertTo-ReportDateTime -Value (Get-ReportEntry -From $Earlier -Name 'CreatedAt')
  $count = 0
  $kindBefore = ([string](Get-ReportEntry -From $Earlier -Name 'Kind')).Trim()
  $kindNow = ([string](Get-ReportEntry -From $Current -Name 'Kind')).Trim()
  $kindsDiffer = ($kindBefore -eq '' -or -not [string]::Equals($kindBefore, $kindNow, [StringComparison]::OrdinalIgnoreCase))
  $created = ConvertTo-ReportDateTime -Value (Get-ReportEntry -From $Current -Name 'CreatedAt')
  $crashWindowShort = ($null -ne $since -and $null -ne $created -and ($created - $since).TotalDays -gt $CrashDays)

  # New crashes: the current events after the earlier report.
  $crashes = [ordered]@{}
  foreach ($kind in 'BugCheck', 'KernelPower', 'Whea') {
    $times = @(foreach ($t in (ConvertTo-ReportList -Value (Get-ReportEntry -From (Get-ReportEntry -From $Current -Name 'Crashes') -Name $kind))) {
        $when = ConvertTo-ReportDateTime -Value ([string]$t)
        if ($null -ne $since -and $null -ne $when -and $when -gt $since) { $when } })
    $newest = $null
    foreach ($t in $times) { if ($null -eq $newest -or $t -gt $newest) { $newest = $t } }
    $crashes[$kind] = @{ Count = $times.Count; Newest = $newest }
    $count += $times.Count
  }

  # Disks, by serial.
  $disks = New-Object System.Collections.Generic.List[object]
  $before = @(Get-CompareDisks -Data $Earlier)
  $after = @(Get-CompareDisks -Data $Current)
  $disksCompared = ($before.Count -gt 0 -and $after.Count -gt 0)
  if ($disksCompared) {
    $label = { param($key) if ($key -match '\ADisk ') { $key.Substring(5) } else { $key } }
    $oldByKey = @{}
    foreach ($d in $before) { $oldByKey[$d.Key] = $d.Disk }
    $newKeys = @{}
    foreach ($d in $after) {
      $newKeys[$d.Key] = $true
      $model = ConvertTo-ToolDisplayText -Text (Get-ReportEntry -From $d.Disk -Name 'Model') -MaxLength 100
      if (-not $oldByKey.ContainsKey($d.Key)) { $disks.Add(@{ Label = (& $label $d.Key); Kind = 'new'; Model = $model }); continue }
      $old = $oldByKey[$d.Key]
      $w1 = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $old -Name 'Wear'); $w2 = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $d.Disk -Name 'Wear')
      if ($null -ne $w1 -and $null -ne $w2 -and [math]::Round($w1) -ne [math]::Round($w2)) { $disks.Add(@{ Label = (& $label $d.Key); Kind = 'wear'; From = $w1; To = $w2; Model = $model }) }
      $r1 = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $old -Name 'ReadErrors'); $x1 = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $old -Name 'WriteErrors')
      $r2 = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $d.Disk -Name 'ReadErrors'); $x2 = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $d.Disk -Name 'WriteErrors')
      if ($null -ne $r1 -and $null -ne $x1 -and $null -ne $r2 -and $null -ne $x2 -and ($r1 -ne $r2 -or $x1 -ne $x2)) {
        $disks.Add(@{ Label = (& $label $d.Key); Kind = 'errors'; From = ('{0}/{1}' -f (Format-ReportNumber -Value $r1 -Format '0'), (Format-ReportNumber -Value $x1 -Format '0'))
                      To = ('{0}/{1}' -f (Format-ReportNumber -Value $r2 -Format '0'), (Format-ReportNumber -Value $x2 -Format '0')); Model = $model })
      }
      $h1 = [string](Get-ReportEntry -From $old -Name 'Health'); $h2 = [string](Get-ReportEntry -From $d.Disk -Name 'Health')
      if ($h1 -ne '' -and $h2 -ne '' -and $h1 -cne $h2) { $disks.Add(@{ Label = (& $label $d.Key); Kind = 'health'; From = $h1; To = $h2; Model = $model }) }
    }
    foreach ($d in $before) {
      if (-not $newKeys.ContainsKey($d.Key)) {
        $disks.Add(@{ Label = (& $label $d.Key); Kind = 'gone'; Model = (ConvertTo-ToolDisplayText -Text (Get-ReportEntry -From $d.Disk -Name 'Model') -MaxLength 100) })
      }
    }
  }
  $count += $disks.Count

  # Free space: a change of 1 GB or more.
  $free = $null
  $gb1 = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $Earlier -Name 'FreeGB'); $gb2 = ConvertTo-ReportNumber -Value (Get-ReportEntry -From $Current -Name 'FreeGB')
  if ($null -ne $gb1 -and $null -ne $gb2 -and [math]::Abs($gb2 - $gb1) -ge 1) {
    $free = @{ FromGB = $gb1; ToGB = $gb2; FromPercent = (ConvertTo-ReportNumber -Value (Get-ReportEntry -From $Earlier -Name 'FreePercent'))
               ToPercent = (ConvertTo-ReportNumber -Value (Get-ReportEntry -From $Current -Name 'FreePercent')) }
    $count++
  }

  # Devices with a problem, by instance ID and code.
  $deviceRows = {
    param($data)
    foreach ($p in (ConvertTo-ReportList -Value (Get-ReportEntry -From $data -Name 'ProblemDevices'))) {
      $code = Format-ReportNumber -Value (Get-ReportEntry -From $p -Name 'Code') -Format '0'
      @{ Key = ('{0}|{1}' -f [string](Get-ReportEntry -From $p -Name 'Id'), $code); Name = (ConvertTo-ToolDisplayText -Text (Get-ReportEntry -From $p -Name 'Name') -MaxLength 200); Code = $code }
    }
  }
  $devicesBefore = @(& $deviceRows $Earlier)
  $devicesAfter = @(& $deviceRows $Current)
  $added = @(foreach ($d in $devicesAfter) { if (@($devicesBefore | Where-Object { $_.Key -ceq $d.Key }).Count -eq 0) { @{ Name = $d.Name; Code = $d.Code } } })
  $gone = @(foreach ($d in $devicesBefore) { if (@($devicesAfter | Where-Object { $_.Key -ceq $d.Key }).Count -eq 0) { @{ Name = $d.Name; Code = $d.Code } } })
  $count += $added.Count + $gone.Count

  # Programs ('name|version'): installed, removed, and one name removed and installed is an update.
  $programsBefore = @(foreach ($p in (ConvertTo-ReportList -Value (Get-ReportEntry -From $Earlier -Name 'Programs'))) { [string]$p })
  $programsAfter = @(foreach ($p in (ConvertTo-ReportList -Value (Get-ReportEntry -From $Current -Name 'Programs'))) { [string]$p })
  $programsCompared = ($programsBefore.Count -gt 0 -and $programsAfter.Count -gt 0)
  $installed = New-Object System.Collections.Generic.List[object]
  $removed = New-Object System.Collections.Generic.List[object]
  $updated = New-Object System.Collections.Generic.List[object]
  if ($programsCompared) {
    $setBefore = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $setAfter = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $programsBefore) { $null = $setBefore.Add($p) }
    foreach ($p in $programsAfter) { $null = $setAfter.Add($p) }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in $programsBefore) { if (-not $setAfter.Contains($p) -and @($out | Where-Object { $_.Entry -eq $p }).Count -eq 0) { $out.Add(@{ Entry = $p; Program = (Split-CompareProgram -Entry $p) }) } }
    $in = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $programsAfter) {
      if ($setBefore.Contains($p) -or -not $in.Add($p)) { continue }
      $program = Split-CompareProgram -Entry $p
      $match = $null
      foreach ($o in $out) { if ([string]::Equals($o.Program.Name, $program.Name, [StringComparison]::OrdinalIgnoreCase)) { $match = $o; break } }
      if ($null -ne $match) {
        $null = $out.Remove($match)
        $updated.Add(@{ Name = $program.Name; From = $match.Program.Version; To = $program.Version })
      } else {
        $installed.Add($program)
      }
    }
    foreach ($o in $out) { $removed.Add($o.Program) }
  }
  $count += $installed.Count + $removed.Count + $updated.Count

  # Findings, by code: new when the earlier report collected its section in full, resolved when this one did.
  $findingsBefore = @(Get-CompareFindings -Data $Earlier)
  $findingsAfter = @(Get-CompareFindings -Data $Current)
  $incompleteBefore = @(Get-CompareIncomplete -Data $Earlier)
  $incompleteAfter = @(Get-CompareIncomplete -Data $Current)
  $codesBefore = @(foreach ($f in $findingsBefore) { $f.Code })
  $codesAfter = @(foreach ($f in $findingsAfter) { $f.Code })
  # A Quick and a Full report: the Full-only codes were checked by one of them only (RD-R25, review I1).
  $notCompared = @()
  if ($kindsDiffer) { $notCompared = @($script:ReportFullOnlyCodes) }
  $new = @(foreach ($f in $findingsAfter) { if ($codesBefore -cnotcontains $f.Code -and $incompleteBefore -cnotcontains $f.Section -and $notCompared -cnotcontains $f.Code) { $f } })
  $resolved = @(foreach ($f in $findingsBefore) { if ($codesAfter -cnotcontains $f.Code -and $incompleteAfter -cnotcontains $f.Section -and $notCompared -cnotcontains $f.Code) { $f } })
  $count += $new.Count + $resolved.Count

  return @{
    Since = $since; Crashes = $crashes; Disks = $disks.ToArray(); DisksCompared = $disksCompared; Free = $free
    DevicesAdded = $added; DevicesGone = $gone
    ProgramsAdded = $installed.ToArray(); ProgramsRemoved = $removed.ToArray(); ProgramsUpdated = $updated.ToArray(); ProgramsCompared = $programsCompared
    FindingsNew = $new; FindingsResolved = $resolved; KindsDiffer = $kindsDiffer; CrashWindowShort = $crashWindowShort; CrashDays = $CrashDays
    Count = $count
  }
}

function Format-ToolSinceLastVisit {
  <#
  .SYNOPSIS
    The "since last visit" section of -Diff (Compare-ToolReportData) as lines: 'SINCE LAST VISIT (dd/MM/yyyy HH:mm)', then
    one line per change (two spaces in), '  (no changes)' when there is none, then the notes on lists not compared.
    Names keep their real text (the report is UTF-8); headings and words are English. Pure.
  .DESCRIPTION
    In this order: new blue screens, Kernel-Power 41 events and WHEA errors (with the newest one's time); disk wear,
    uncorrected errors and health, new and gone disks; free space; device problems new and gone; programs installed,
    updated and removed (at most $script:CompareListMax lines each, then '  ... and <n> more <kind>'); findings new and
    resolved, with their level, English text and section.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param([Parameter(Mandatory)][hashtable]$Diff)

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add(('SINCE LAST VISIT ({0})' -f (Format-ReportDate -When $Diff['Since'])))
  $changes = New-Object System.Collections.Generic.List[string]
  $names = [ordered]@{ BugCheck = 'New blue screens'; KernelPower = 'New Kernel-Power 41 events'; Whea = 'New hardware errors (WHEA)' }
  foreach ($kind in @($names.Keys)) {
    $c = $Diff['Crashes'][$kind]
    if ($null -ne $c -and $c.Count -gt 0) { $changes.Add(('  {0}: {1} (the newest {2})' -f $names[$kind], $c.Count, (Format-ReportDate -When $c.Newest))) }
  }
  foreach ($d in @($Diff['Disks'])) {
    switch -CaseSensitive ([string]$d.Kind) {
      'wear' { $changes.Add(('  Disk {0}: wear {1}% -> {2}%' -f $d.Label, (Format-ReportNumber -Value $d.From -Format '0'), (Format-ReportNumber -Value $d.To -Format '0'))) }
      'errors' { $changes.Add(('  Disk {0}: uncorrected read/write errors {1} -> {2}' -f $d.Label, $d.From, $d.To)) }
      'health' { $changes.Add(('  Disk {0}: health {1} -> {2}' -f $d.Label, $d.From, $d.To)) }
      'new' { $changes.Add(('  Disk {0} ({1}): new' -f $d.Label, $d.Model)) }
      'gone' { $changes.Add(('  Disk {0} ({1}): not found this time' -f $d.Label, $d.Model)) }
    }
  }
  $free = $Diff['Free']
  if ($null -ne $free) {
    $side = { param($gb, $percent) $t = '{0} GB' -f (Format-ReportNumber -Value $gb -Format '0.0'); if ($null -ne $percent) { $t += ' ({0}%)' -f (Format-ReportNumber -Value $percent -Format '0') }; $t }
    $changes.Add(('  Free space: {0} -> {1}' -f (& $side $free.FromGB $free.FromPercent), (& $side $free.ToGB $free.ToPercent)))
  }
  foreach ($d in @($Diff['DevicesAdded'])) { if ($null -ne $d) { $changes.Add(('  New device problem: {0} (code {1})' -f $d.Name, $d.Code)) } }
  foreach ($d in @($Diff['DevicesGone'])) { if ($null -ne $d) { $changes.Add(('  Device problem gone: {0} (code {1})' -f $d.Name, $d.Code)) } }
  $program = { param($p) (('{0} {1}' -f (ConvertTo-ToolDisplayText -Text $p.Name -MaxLength 200), (ConvertTo-ToolDisplayText -Text $p.Version -MaxLength 60)).Trim()) }
  foreach ($list in @(
      @{ Items = @($Diff['ProgramsAdded']); Word = 'installed'; Line = { param($p) '  Installed: ' + (& $program $p) } }
      @{ Items = @($Diff['ProgramsUpdated']); Word = 'updated'; Line = { param($p) ('  Updated: {0} {1} -> {2}' -f (ConvertTo-ToolDisplayText -Text $p.Name -MaxLength 200),
                                                                                (ConvertTo-ToolDisplayText -Text $p.From -MaxLength 60), (ConvertTo-ToolDisplayText -Text $p.To -MaxLength 60)) } }
      @{ Items = @($Diff['ProgramsRemoved']); Word = 'removed'; Line = { param($p) '  Removed: ' + (& $program $p) } })) {
    $items = @($list.Items | Where-Object { $null -ne $_ })
    $shown = 0
    foreach ($p in $items) {
      if ($shown -ge $script:CompareListMax) { break }
      $changes.Add((& $list.Line $p))
      $shown++
    }
    if ($items.Count -gt $shown) { $changes.Add(('  ... and {0} more {1}' -f ($items.Count - $shown), $list.Word)) }
  }
  foreach ($pair in @(@{ Items = @($Diff['FindingsNew']); Word = 'New finding' }, @{ Items = @($Diff['FindingsResolved']); Word = 'Resolved' })) {
    foreach ($f in $pair.Items) {
      if ($null -eq $f) { continue }
      $changes.Add(('  {0}: [{1}] {2} (section {3})' -f $pair.Word, $f.Level, (Get-ToolText -Key ('finding.' + $f.Code) -Arguments $f.Args), $f.Section))
    }
  }
  if ($changes.Count -eq 0) { $lines.Add('  (no changes)') } else { foreach ($c in $changes) { $lines.Add($c) } }
  if ($Diff['KindsDiffer'] -eq $true) { $lines.Add('  Not compared: the checks only a Full report makes (one visit had a Quick report, the other a Full one)') }
  if ($Diff['CrashWindowShort'] -eq $true) {
    $lines.Add(('  Crashes are counted for the last {0} days only (the last visit was longer ago)' -f [int]$Diff['CrashDays']))
  }
  if ($Diff['DisksCompared'] -ne $true) { $lines.Add('  Disks: not compared (one of the two reports has no disk list)') }
  if ($Diff['ProgramsCompared'] -ne $true) { $lines.Add('  Programs: not compared (one of the two reports has no program list)') }
  return $lines.ToArray()
}

function Get-ToolSinceLastVisitLines {
  <#
  .SYNOPSIS
    The SINCE LAST VISIT lines of a report or a comparison (Private, pure): with -Earlier, Format-ToolSinceLastVisit of
    -Diff, and a line naming the newer files -Skipped; without one but with -Skipped, 'SINCE LAST VISIT' and the files
    that could not be read (never a silent comparison with nothing, RD-R23); without either, none, or with -Always
    'SINCE LAST VISIT' and '(no earlier report of this PC on the stick)'.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [AllowNull()]$Earlier,
    [AllowNull()]$Diff,
    [AllowNull()][AllowEmptyCollection()][string[]]$Skipped,
    [switch]$Always
  )

  $files = @($Skipped | Where-Object { $_ })
  $names = Format-ReportShortList -Values $files
  if ($null -ne $Earlier -and $Diff -is [hashtable]) {
    $lines = @(Format-ToolSinceLastVisit -Diff $Diff)
    if ($files.Count -gt 0) { $lines += ('  ({0} newer report files of this PC could not be read and were not compared: {1})' -f $files.Count, $names) }
    return [string[]]$lines
  }
  if ($files.Count -gt 0) { return [string[]]@('SINCE LAST VISIT', ('  (not compared: {0} earlier report files of this PC could not be read: {1})' -f $files.Count, $names)) }
  if ($Always) { return [string[]]@('SINCE LAST VISIT', '  (no earlier report of this PC on the stick)') }
  return [string[]]@()
}

# --- The compare step ----------------------------------------------------------------------------------------------

function Invoke-ToolStepCompare {
  <#
  .SYNOPSIS
    Step compare (the compare action, after report01 ... report11 collected the Quick sections): this visit's report
    data against this PC's newest earlier report on the stick. Writes COMPARE_<PC>_<stamp>.txt (the header, the
    complaint and the SINCE LAST VISIT section; UTF-8 with a BOM), COMPARE_SAFE_<stamp>.txt (no PC name in its name, RD-R4)
    and COMPARE_<PC>_<stamp>_data.json (plain UTF-8, RD-R23: the next Compare reads it, so it is a visit too).
    $Run.Files.Compare, .CompareSafe, .Data.
  .DESCRIPTION
    The window's findings: INFO compareDone (the earlier visit's date, the number of changes) and every finding that is
    new since that visit, with its own code and level; WARN compareNoEarlier without an earlier report; WARN
    earlierUnreadable naming the files of this PC that could not be read ('warn' when nothing could be compared). A
    file that cannot be written: COMPARE_ (CRIT compareWriteFailed, 'failed'), the data or the SAFE copy (WARN
    compareWriteFailed, 'warn'). Nothing is written through a link (V2-R13).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][hashtable]$Run)

  try {
    $report = New-ToolReport -Run $Run
    $data = ConvertTo-ReportData -Report $report
    $found = Get-ToolRunSinceLastVisit -Run $Run -Current $data -Always
    $diff = $found.Diff
    $lines = [string[]](@(Format-ReportHead -Report $report -Title 'COMPARE') + @($found.Lines))

    $pc = Get-ToolReportPcName -Run $Run
    $stamp = Get-ToolReportStamp -Run $Run -Prefix 'COMPARE'
    $folder = Get-ToolReportFolder -Run $Run
    $path = [IO.Path]::Combine($folder, ('COMPARE_{0}_{1}.txt' -f $pc, $stamp))
    Save-ToolReportText -Path $path -Lines $lines
    $Run.Files['Compare'] = $path
    $status = 'done'

    $dataPath = [IO.Path]::Combine($folder, ('COMPARE_{0}_{1}_data.json' -f $pc, $stamp))
    if (Test-StickReparsePoint -Path $dataPath) {
      Add-ToolFinding -Run $Run -Level WARN -Code 'compareWriteFailed' -Arguments @('the data file is a link'); $status = 'warn'
    } elseif (Write-ToolJsonFile -Path $dataPath -InputObject $data -Depth 10 -Utf8) {
      $Run.Files['Data'] = $dataPath
    } else {
      Add-ToolFinding -Run $Run -Level WARN -Code 'compareWriteFailed' -Arguments @('the data file could not be written'); $status = 'warn'
    }
    $safePath = [IO.Path]::Combine($folder, ('COMPARE_SAFE_{0}.txt' -f $stamp))
    $why = Save-ToolSafeCopy -Path $safePath -Lines $lines -Report $report -Earlier $found.Earlier
    if ($why -eq '') { $Run.Files['CompareSafe'] = $safePath } else { Add-ToolFinding -Run $Run -Level WARN -Code 'compareWriteFailed' -Arguments @($why); $status = 'warn' }

    $skipped = @($found.Skipped)
    if ($skipped.Count -gt 0) { Add-ToolFinding -Run $Run -Level WARN -Code 'earlierUnreadable' -Arguments @($skipped.Count, (Format-ReportShortList -Values $skipped)) }
    if ($null -ne $diff) {
      Add-ToolFinding -Run $Run -Level INFO -Code 'compareDone' -Arguments @((Format-ReportDate -When $diff['Since']), $diff['Count'])
      foreach ($f in @($diff['FindingsNew'])) {
        if ($null -ne $f -and $f.Level -cin 'CRIT', 'WARN', 'INFO') { Add-ToolFinding -Run $Run -Level $f.Level -Code $f.Code -Arguments $f.Args }
      }
      Add-ToolLog -Run $Run -Text ('Compared with the visit of {0}: {1} changes ({2})' -f (Format-ReportDate -When $diff['Since']), $diff['Count'], [IO.Path]::GetFileName($path))
    } else {
      if ($skipped.Count -eq 0) { Add-ToolFinding -Run $Run -Level WARN -Code 'compareNoEarlier' }
      Add-ToolLog -Run $Run -Text 'Nothing compared: no earlier report of this PC could be read'
      $status = 'warn'
    }
    return $status
  } catch {
    $reason = ConvertTo-ReportReason -Exception $_.Exception
    Write-SetupLog -Level ERROR -Message 'The comparison could not be written' -Data @{ reason = $reason; error = (ConvertTo-ScreenText -Text $_.Exception.Message) }
    Add-ToolFinding -Run $Run -Level CRIT -Code 'compareWriteFailed' -Arguments @($reason)
    return 'failed'
  }
}
