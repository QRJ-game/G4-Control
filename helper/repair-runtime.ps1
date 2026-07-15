param(
  [string]$Adb = "C:\platform-tools\adb.exe"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$BootFile = Join-Path $Root "..\payload\g4-boot.sh"
$HelperFile = Join-Path $Root "..\payload\g4-helper"
$ActionsFile = Join-Path $Root "..\payload\g4-actions.sh"

function Invoke-AdbSafe {
  param(
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    $raw = @(& $Adb @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }

  $clean = @(
    $raw |
      ForEach-Object { [string]$_ } |
      Where-Object {
        $_ -notmatch '^\* daemon not running; starting now at tcp:\d+\s*$' -and
        $_ -notmatch '^\* daemon started successfully\s*$'
      }
  )

  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "ADB failed ($exitCode): $($clean -join "`n")"
  }

  return ($clean -join "`n").Trim()
}

function Test-HelperHttp {
  $localPort = 28081

  Invoke-AdbSafe @("forward", "--remove", "tcp:$localPort") -AllowFailure | Out-Null
  Invoke-AdbSafe @("forward", "tcp:$localPort", "tcp:18081") | Out-Null

  try {
    $client = New-Object Net.Sockets.TcpClient
    $async = $client.BeginConnect("127.0.0.1", $localPort, $null, $null)

    if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
      $client.Close()
      return $false
    }

    $client.EndConnect($async)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 5000
    $stream.WriteTimeout = 5000

    $request = [Text.Encoding]::ASCII.GetBytes(
      "GET /api/ping HTTP/1.0`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"
    )
    $stream.Write($request, 0, $request.Length)

    $buffer = New-Object byte[] 4096
    $builder = New-Object Text.StringBuilder

    while ($true) {
      try {
        $read = $stream.Read($buffer, 0, $buffer.Length)
      }
      catch {
        break
      }

      if ($read -le 0) {
        break
      }

      [void]$builder.Append(
        [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
      )
    }

    $client.Close()
    $response = $builder.ToString()

    return (
      $response -match 'HTTP/1\.[01] 200' -and
      $response -match '"ok":true' -and
      $response -match '"version":"0\.9\.2"'
    )
  }
  finally {
    Invoke-AdbSafe @("forward", "--remove", "tcp:$localPort") -AllowFailure | Out-Null
  }
}

Write-Host "1/6 Checking ADB..."
Invoke-AdbSafe @("start-server") -AllowFailure | Out-Null

$devices = Invoke-AdbSafe @("devices")
if ($devices -notmatch '(?m)^\S+\s+device$') {
  throw "Router was not found through ADB."
}

Write-Host "2/6 Uploading runtime v0.9.2..."
Invoke-AdbSafe @("push", $BootFile, "/mnt/userdata/g4ui/g4-boot.sh") | Write-Host
Invoke-AdbSafe @("push", $HelperFile, "/mnt/userdata/g4ui/g4-helper") | Write-Host
Invoke-AdbSafe @("push", $ActionsFile, "/mnt/userdata/g4ui/g4-actions.sh") | Write-Host

Invoke-AdbSafe @(
  "shell",
  "chmod 755 /mnt/userdata/g4ui/g4-boot.sh /mnt/userdata/g4ui/g4-helper /mnt/userdata/g4ui/g4-actions.sh"
) | Out-Null

Write-Host "3/6 Running ARM and daemon self-tests..."
$selfTest = Invoke-AdbSafe @(
  "shell",
  "if /mnt/userdata/g4ui/g4-helper --self-test; " +
  "then echo G4_SELFTEST_OK; else echo G4_SELFTEST_BAD; fi"
)

if ($selfTest -notmatch '(?m)^G4_SELFTEST_OK$') {
  throw "ARM helper self-test failed: $selfTest"
}

$daemonTest = Invoke-AdbSafe @(
  "shell",
  "rm -f /tmp/g4-helper-daemon-selftest; " +
  "if /mnt/userdata/g4ui/g4-helper --daemon-self-test; " +
  "then sleep 2; " +
  "if grep -q G4_OK /tmp/g4-helper-daemon-selftest 2>/dev/null; " +
  "then echo G4_DAEMON_OK; else echo G4_DAEMON_BAD; fi; " +
  "else echo G4_DAEMON_BAD; fi"
)

Invoke-AdbSafe @(
  "shell",
  "rm -f /tmp/g4-helper-daemon-selftest"
) -AllowFailure | Out-Null

if ($daemonTest -notmatch '(?m)^G4_DAEMON_OK$') {
  throw "ARM helper daemon self-test failed: $daemonTest"
}

Write-Host "ARM helper self-test: OK"
Write-Host "ARM helper daemon self-test: OK"

Write-Host "4/6 Restarting runtime..."
Invoke-AdbSafe @(
  "shell",
  "/mnt/userdata/g4ui/g4-boot.sh restart"
) | Out-Null

Start-Sleep -Seconds 2

Write-Host "5/6 Verifying status..."
$status = Invoke-AdbSafe @(
  "shell",
  "/mnt/userdata/g4ui/g4-boot.sh status; echo ---listeners---; netstat -lnpt 2>/dev/null | grep 18081"
)
Write-Host $status

Write-Host "6/6 Verifying HTTP API..."
if (-not (Test-HelperHttp)) {
  throw "Runtime listener exists, but /api/ping v0.9.2 did not answer."
}

Write-Host ""
Write-Host "Runtime repair complete."
Write-Host "helper=running and /api/ping v0.9.2 confirmed."
Write-Host ""
Write-Host "For the full v0.9.2 UI update, run INSTALL_OR_UPDATE.cmd."
