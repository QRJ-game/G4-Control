param(
  [string]$Adb = "C:\platform-tools\adb.exe"
)

$Script = Join-Path $PSScriptRoot "enable-ui.ps1"
& $Script -Adb $Adb
