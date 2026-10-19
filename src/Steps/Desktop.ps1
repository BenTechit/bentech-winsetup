# src/Steps/Desktop.ps1
# Step 3, "Desktop icons" (spec 8.3): This PC and the user's files folder on the desktop.
# Needs StepResult.ps1 and Logging.ps1, and Set-RegistryDword from Prepare.ps1 (the bundle holds every file).

# Current user (HKCU). A value of 0 means "do not hide this icon". The same two GUIDs are written under
# both keys: NewStartPanel is what Windows 11 reads, ClassicStartMenu is the older (Windows 10 classic) one.
$script:DesktopIconKeys = @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu'
)
$script:DesktopIconGuids = @(
  '{20D04FE0-3AEA-1069-A2D8-08002B30309D}',   # This PC
  '{59031a47-3f72-44a7-89c5-5595fe6b30ee}'    # the user's files folder
)

function Invoke-StepDesktopIcons {
  <#
  .SYNOPSIS
    Step 3: shows This PC and the user's files folder on the desktop. Always Done.
  .DESCRIPTION
    Explorer is NOT restarted: killing it while somebody (or this tool's own window) is using the
    desktop is disruptive, and the icons show up the next time Explorer starts (the next sign-in).
    Every value is tried even if one write is refused; any failure gives the Note
    'Desktop icons could not be set'.
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][hashtable]$Context)

  $allOk = $true
  foreach ($key in $script:DesktopIconKeys) {
    foreach ($guid in $script:DesktopIconGuids) {
      if (-not (Set-RegistryDword -Path $key -Name $guid -Value 0)) { $allOk = $false }
    }
  }
  if ($allOk) { return New-StepResult -Status Done -Message 'Desktop icons set' }
  return New-StepResult -Status Done -Message 'Desktop icons partly set' -Notes @('Desktop icons could not be set')
}
