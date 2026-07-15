param(
  [string]$Adb = "C:\platform-tools\adb.exe"
)

$ErrorActionPreference = "Stop"

function Restart-Adb {
  Get-Process adb -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

  Start-Sleep -Seconds 1

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    & $Adb start-server 2>$null | Out-Null
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }
}

function Wait-AdbDevice {
  param([int]$TimeoutSeconds = 60)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

  do {
    $lines = & $Adb devices 2>$null

    foreach ($line in $lines) {
      if ($line -match "^\S+\s+device$") {
        & $Adb shell "echo ready" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
          return $true
        }
      }
    }

    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)

  return $false
}

function Ensure-Adb {
  Restart-Adb

  if (-not (Wait-AdbDevice)) {
    throw "Router was not found through ADB within 60 seconds."
  }
}

function Adb-Shell {
  param([Parameter(Mandatory=$true)][string]$Command)

  & $Adb shell $Command

  if ($LASTEXITCODE -ne 0) {
    throw "ADB shell command failed: $Command"
  }
}

function Test-RemoteFile {
  param([Parameter(Mandatory=$true)][string]$Path)

  $result = ((& $Adb shell "if [ -e '$Path' ]; then echo G4_YES; else echo G4_NO; fi") -join "").Trim()
  return $result -eq "G4_YES"
}

function Test-RemoteMount {
  param([Parameter(Mandatory=$true)][string]$Target)

  $mounts = (& $Adb shell "cat /proc/mounts") -join "`n"
  return $mounts -match [regex]::Escape(" $Target ")
}

function Clear-RemoteMount {
  param([Parameter(Mandatory=$true)][string]$Target)

  for ($attempt = 1; $attempt -le 32; $attempt++) {
    if (-not (Test-RemoteMount $Target)) {
      return
    }

    & $Adb shell "umount '$Target'" | Out-Null

    if ($LASTEXITCODE -ne 0) {
      throw "Failed to unmount $Target on attempt $attempt."
    }

    Start-Sleep -Milliseconds 150
  }

  if (Test-RemoteMount $Target) {
    throw "Too many stacked bind mounts remain on $Target."
  }
}


Ensure-Adb

Write-Host "=== G4 persistent UI status ==="

if (Test-RemoteFile "/mnt/userdata/g4ui/g4-boot.sh") {
  & $Adb shell "/mnt/userdata/g4ui/g4-boot.sh status"
} else {
  Write-Host "boot_service=missing"
}

Write-Host ""
Write-Host "=== Startup metadata ==="
if (Test-RemoteFile "/mnt/userdata/g4ui/install.meta") {
  & $Adb shell "cat /mnt/userdata/g4ui/install.meta"
} else {
  Write-Host "install.meta is missing"
}

Write-Host ""
Write-Host "=== Relevant mounts ==="
& $Adb shell "cat /proc/mounts | grep '/etc_ro/web'"

Write-Host ""
Write-Host "=== Persistent storage ==="
& $Adb shell "df -k /mnt/userdata"

Write-Host ""
Write-Host "Expected physical Reset behavior:"
Write-Host "If factory reset clears /etc_rw, /etc_rw/g4ui.enable disappears and the factory UI opens."
Write-Host "Use prepare-reset-test.ps1 before a reset to verify the exact behavior of this firmware."


Write-Host ""
Write-Host "=== Factory customer hook ==="
& $Adb shell "ls -ld /etc/custom /etc/custom/customer.sh 2>&1"
& $Adb shell "grep -n 'BEGIN G4UI' /etc/custom/customer.sh 2>&1"
& $Adb shell "awk '`$1 == \"/dev/root\" && `$2 == \"/\" { print \"root_options=\" `$4 }' /proc/mounts"

Write-Host ""
Write-Host "=== Runtime helper ==="
& $Adb shell "ps | grep '[g]4-helper'; netstat -lnt 2>/dev/null | grep ':18081'; /mnt/userdata/g4ui/g4-actions.sh status 2>/dev/null"
