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


$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Report = Join-Path $Root "startup-report.txt"

Ensure-Adb

$commands = @(
  "echo ===== INITTAB =====; cat /etc/inittab 2>/dev/null"
  "echo ===== ETC INIT =====; ls -la /etc/init.d /etc 2>/dev/null"
  "echo ===== RCS =====; for f in /etc/init.d/rcS /etc/rcS; do echo --- `$f; cat `$f 2>/dev/null; done"
  "echo ===== MOUNTS =====; cat /proc/mounts"
  "echo ===== DF =====; df -k"
  "echo ===== G4 META =====; cat /mnt/userdata/g4ui/install.meta 2>/dev/null"
)

$output = @()
foreach ($command in $commands) {
  $output += (& $Adb shell $command)
  $output += ""
}

$output | Set-Content -Path $Report -Encoding UTF8
Write-Host "Saved: $Report"
