# src/Entry/Run.ps1
# The bundle's last statement: run the entry point and hand its result to the process as the exit code.
# Only tools\Build-Bundle.ps1 uses this file (appended last, after src/Entry/Main.ps1). It is kept out of
# Main.ps1 so the tests can dot-source Main.ps1 without the test process exiting. Never dot-source it.
exit (Start-BenTechSetup -Resume:$Resume -WuRound:$WuRound -SearchOnly:$SearchOnly -ResultPath $ResultPath -WuUnhide:$WuUnhide -UpdateIds $UpdateIds)
