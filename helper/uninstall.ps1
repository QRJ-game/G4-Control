param(
  [string]$Adb = "C:\platform-tools\adb.exe",
  [switch]$Purge
)

$Script = Join-Path $PSScriptRoot "rollback.ps1"

if ($Purge) {
  & $Script -Adb $Adb -Purge
} else {
  & $Script -Adb $Adb
}
