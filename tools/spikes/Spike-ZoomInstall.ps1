# Zoom VM check (Q54). Run ONLY on a test VM, in an elevated Windows PowerShell. Never on the dev PC.
# It installs Zoom per-machine through winget exactly as the setup tool would, then prints what Ben reports back.
$ErrorActionPreference = 'Continue'
$start = Get-Date
winget install --id Zoom.Zoom -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --custom "ZConfig=AU2_EnableAutoUpdate=true;AU2_SetUpdateChannel=0"
$code = $LASTEXITCODE
'--- 1. winget exit code: {0} (0x{1:X8}), {2:N0} s' -f $code, $code, ((Get-Date) - $start).TotalSeconds
'--- 2. Zoom processes running now (did it open by itself?):'
Get-Process -Name 'Zoom*' -ErrorAction SilentlyContinue | Select-Object Name, Id, StartTime | Format-Table -AutoSize | Out-String
'--- 3. Uninstall entries (DisplayName / version / scope):'
foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
  Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*Zoom*' } |
    ForEach-Object { '{0} | {1} | {2}' -f $_.DisplayName, $_.DisplayVersion, $key }
}
'--- 4. Desktop icons:'
Get-ChildItem -Path "$env:PUBLIC\Desktop", ([Environment]::GetFolderPath('Desktop')) -Filter '*Zoom*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
'--- 5. Start at sign-in (Run keys):'
foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
  $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
  if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and "$($_.Value)" -like '*zoom*' } | ForEach-Object { '{0}: {1} = {2}' -f $key, $_.Name, $_.Value } }
}
'--- 6. Now open Zoom > Settings > General and look at the automatic-update option (on? greyed out?). Report it with this output.'
