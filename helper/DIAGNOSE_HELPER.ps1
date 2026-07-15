param(
  [string]$RouterHost = "192.168.0.1",
  [string]$Adb = "C:\platform-tools\adb.exe"
)

$ErrorActionPreference = "Continue"

function RawGet {
  param([int]$Port, [string]$Path, [int]$Timeout = 12000)

  $client = New-Object Net.Sockets.TcpClient

  try {
    $async = $client.BeginConnect($RouterHost, $Port, $null, $null)

    if (-not $async.AsyncWaitHandle.WaitOne($Timeout)) {
      return "CONNECT_TIMEOUT"
    }

    $client.EndConnect($async)
    $stream = $client.GetStream()
    $stream.ReadTimeout = $Timeout
    $stream.WriteTimeout = $Timeout

    $request = [Text.Encoding]::ASCII.GetBytes(
      "GET $Path HTTP/1.0`r`nHost: $RouterHost`r`nConnection: close`r`n`r`n"
    )

    $stream.Write($request, 0, $request.Length)

    $buffer = New-Object byte[] 16384
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

    return $builder.ToString()
  }
  catch {
    return "ERROR: $($_.Exception.Message)"
  }
  finally {
    $client.Close()
  }
}

Write-Host "=== /api/ping ==="
Write-Host (RawGet 18081 "/api/ping")

Write-Host ""
Write-Host "=== /api/status ==="
Write-Host (RawGet 18081 "/api/status")

Write-Host ""
Write-Host "=== /api/cells ==="
Write-Host (RawGet 18081 "/api/cells" 15000)

Write-Host ""
Write-Host "=== Router processes/listeners ==="

if (Test-Path $Adb) {
  & $Adb start-server 2>$null | Out-Null
  & $Adb shell "echo ---status---; /mnt/userdata/g4ui/g4-boot.sh status 2>&1; echo ---listeners---; netstat -lnpt 2>&1 | grep -E '18081|17820'; echo ---processes---; ps | grep -E '[g]4-helper|[t]w_socket_tool'; echo ---logs---; tail -n 50 /tmp/g4ui-boot.log 2>&1"
}
else {
  Write-Host "ADB not found: $Adb"
}
