# bentech-winsetup

Zero-touch Windows post-install setup tool by BENTECH IT. A single double-click launcher runs a PowerShell 5.1 script bundle that renames the PC, installs the standard apps, applies vendor drivers and Windows Updates, and prints a final report. Design spec and implementation plan are in `docs/`.

Run the tests with `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 -Path tests` (requires Pester 5.5+ on the dev machine only).
