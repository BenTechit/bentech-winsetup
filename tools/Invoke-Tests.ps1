param([string]$Path = "$PSScriptRoot\..\tests")

Import-Module Pester -MinimumVersion 5.5.0
$r = Invoke-Pester -Path $Path -Output Detailed -PassThru

# FailedCount only counts tests that ran. A test file that cannot load (parse error, throwing
# BeforeDiscovery) is a failed container with zero tests, so count containers too. Never report
# 0 when Pester itself says the run failed, or when it returned no result at all (e.g. no test
# files at -Path: Invoke-Pester writes an error and returns nothing).
if ($null -eq $r) {
  $failed = 1
} else {
  $failed = [int]$r.FailedCount + [int]$r.FailedContainersCount
  if ($failed -eq 0 -and $r.Result -eq 'Failed') { $failed = 1 }
}
"Failed: $failed"
exit $failed
