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

function Show-Probe {
  param(
    [string]$Name,
    [string]$Path
  )

  if (Test-RemoteFile $Path) {
    Write-Host "$Name=survived"
  } else {
    Write-Host "$Name=removed"
  }
}

Write-Host "=== Factory reset probe result ==="
Show-Probe "etc_rw_probe" "/etc_rw/g4-reset-probe"
Show-Probe "userdata_probe" "/mnt/userdata/g4ui/reset-probe-userdata"
Show-Probe "tmp_probe" "/tmp/g4-reset-probe"
Show-Probe "g4_enable" "/etc_rw/g4ui.enable"
Show-Probe "g4_payload" "/mnt/userdata/g4ui/stock-host.html"

Write-Host ""
if (Test-RemoteMount "/etc_ro/web/index.html") {
  Write-Host "current_ui_mount=custom"
} else {
  Write-Host "current_ui_mount=factory"
}

Write-Host ""
Write-Host "Interpretation:"
Write-Host "- If etc_rw_probe and g4_enable were removed, physical Reset opens the factory UI."
Write-Host "- If userdata_probe survived, custom files remain stored but stay disabled without g4_enable."
