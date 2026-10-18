param([string]$Path = "$PSScriptRoot\..\tests")

Import-Module Pester -MinimumVersion 5.5.0
$r = Invoke-Pester -Path $Path -Output Detailed -PassThru
"Failed: $($r.FailedCount)"
exit $r.FailedCount
