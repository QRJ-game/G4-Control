param(
  [string]$Adb = "C:\platform-tools\adb.exe",
  [switch]$Purge
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

$CustomerHookRollback = Join-Path $Root "..\payload\g4-rollback-customer-hook.sh"

Ensure-Adb

Write-Host "1/5 Disabling and unmounting G4 Control..."
& $Adb shell "rm -f /etc_rw/g4ui.enable"

if (Test-RemoteFile "/mnt/userdata/g4ui/g4-boot.sh") {
  & $Adb shell "/mnt/userdata/g4ui/g4-boot.sh stop"
}

Clear-RemoteMount "/etc_ro/web/index.html"

Write-Host "2/5 Reading persistence metadata..."
$metaLocal = Join-Path $env:TEMP "g4-install.meta"

if (Test-RemoteFile "/mnt/userdata/g4ui/install.meta") {
  & $Adb pull "/mnt/userdata/g4ui/install.meta" $metaLocal | Out-Null
  $meta = @{}

  foreach ($line in Get-Content $metaLocal) {
    if ($line -match '^([^=]+)=(.*)$') {
      $meta[$matches[1]] = $matches[2]
    }
  }

  $mode = $meta["MODE"]
  $hook = $meta["HOOK"]

  Write-Host "Installed mode: $mode"

  if ($mode -eq "dropin" -and $hook) {
    $hookText = ((& $Adb shell "cat '$hook' 2>/dev/null") -join "`n")

    if ($hookText -match "G4UI_STARTUP_HOOK") {
      Adb-Shell "rm -f '$hook'"
      Write-Host "Removed startup hook: $hook"
    }
  }
  elseif ($mode -eq "rc-local" -and $hook) {
    $hookLocal = Join-Path $env:TEMP "g4-rc-local-current"
    $hookClean = Join-Path $env:TEMP "g4-rc-local-rollback"

    & $Adb pull $hook $hookLocal | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to download rc.local hook."
    }

    $text = [IO.File]::ReadAllText($hookLocal)
    $clean = [regex]::Replace(
      $text,
      '(?ms)\r?\n?# BEGIN G4UI.*?# END G4UI\r?\n?',
      "`n"
    )

    [IO.File]::WriteAllText(
      $hookClean,
      $clean,
      (New-Object System.Text.UTF8Encoding($false))
    )

    & $Adb push $hookClean "/tmp/g4-rc-local.rollback" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to upload cleaned rc.local."
    }

    Adb-Shell "cp /tmp/g4-rc-local.rollback '$hook' && chmod 755 '$hook' && rm -f /tmp/g4-rc-local.rollback"
    Write-Host "Removed G4UI block from: $hook"
  }
  elseif ($mode -eq "customer-hook" -and $hook) {
    & $Adb push $CustomerHookRollback "/tmp/g4-rollback-customer-hook.sh" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to upload the customer-hook rollback script."
    }

    & $Adb shell "chmod 755 /tmp/g4-rollback-customer-hook.sh" | Out-Null

    $rollbackResult = ((& $Adb shell "/bin/sh /tmp/g4-rollback-customer-hook.sh" 2>&1) -join "`n").Trim()
    & $Adb shell "rm -f /tmp/g4-rollback-customer-hook.sh" 2>$null | Out-Null

    if (
      $rollbackResult -notmatch '(?m)^G4_RESTORED$' -and
      $rollbackResult -notmatch '(?m)^G4_REMOVED$'
    ) {
      throw "Customer-hook rollback failed: $rollbackResult"
    }

    Write-Host "Removed the persistent customer hook."
  }
  elseif ($mode -eq "patched-remote" -and $hook) {
    $safeName = ($hook.TrimStart("/") -replace '[^A-Za-z0-9_.-]', '-')
    $backupPath = "/mnt/userdata/g4ui/backup/$safeName.original"

    if (-not (Test-RemoteFile $backupPath)) {
      throw "Exact startup backup is missing: $backupPath"
    }

    $restoreResult = ((& $Adb shell "if cat '$backupPath' > '$hook' && chmod 755 '$hook' && /bin/sh -n '$hook'; then echo G4_OK; else echo G4_BAD; fi" 2>$null) -join "").Trim()

    if ($restoreResult -ne "G4_OK") {
      throw "Failed to restore exact startup backup: $hook"
    }

    Write-Host "Restored exact startup backup: $hook"
  }
  elseif (($mode -eq "patched" -or $mode -eq "patched-inplace") -and $hook) {
    $rcLocal = Join-Path $env:TEMP "g4-rcS-current"
    $rcPatched = Join-Path $env:TEMP "g4-rcS-rollback"

    & $Adb pull $hook $rcLocal | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to download patched startup script."
    }

    $text = [IO.File]::ReadAllText($rcLocal)
    $clean = [regex]::Replace(
      $text,
      '(?ms)\r?\n?# BEGIN G4UI.*?# END G4UI\r?\n?',
      "`n"
    )

    [IO.File]::WriteAllText(
      $rcPatched,
      $clean,
      (New-Object System.Text.UTF8Encoding($false))
    )

    & $Adb push $rcPatched "/tmp/g4-rcS.rollback" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to upload cleaned startup script."
    }

    $restoreResult = ((& $Adb shell "if cat /tmp/g4-rcS.rollback > '$hook' && chmod 755 '$hook'; then echo G4_OK; else echo G4_BAD; fi") -join "").Trim()
    & $Adb shell "rm -f /tmp/g4-rcS.rollback" | Out-Null

    if ($restoreResult -ne "G4_OK") {
      throw "Failed to restore startup script in place: $hook"
    }

    Write-Host "Removed G4UI block from: $hook"
  }
} else {
  Write-Warning "Persistence metadata is missing; runtime UI was still disabled."
}

Write-Host "3/5 Verifying factory UI..."
if (Test-RemoteMount "/etc_ro/web/index.html") {
  throw "The custom UI mount is still active."
}

Write-Host "4/5 Handling stored files..."
if ($Purge) {
  Adb-Shell "rm -rf /mnt/userdata/g4ui"
  Write-Host "Stored G4 files were removed."
} else {
  Write-Host "Stored files were preserved. Use -Purge to remove them."
}

Write-Host "5/5 Rollback complete."
Write-Host "The genuine factory UI is active now and after future reboots."
