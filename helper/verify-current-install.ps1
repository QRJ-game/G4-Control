param(
  [string]$RouterHost = "192.168.0.1",
  [string]$Adb = "C:\platform-tools\adb.exe"
)

$ErrorActionPreference = "Stop"

function RawGet {
  param(
    [string]$HostName,
    [int]$Port,
    [string]$Path
  )

  $client = New-Object Net.Sockets.TcpClient

  try {
    $async = $client.BeginConnect($HostName, $Port, $null, $null)

    if (-not $async.AsyncWaitHandle.WaitOne(6000)) {
      return ""
    }

    $client.EndConnect($async)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 6000
    $stream.WriteTimeout = 6000

    $request = [Text.Encoding]::ASCII.GetBytes(
      "GET $Path HTTP/1.0`r`nHost: $HostName`r`nConnection: close`r`n`r`n"
    )
    $stream.Write($request, 0, $request.Length)

    $buffer = New-Object byte[] 8192
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
  finally {
    $client.Close()
  }
}

Write-Host "1/3 Checking injected G4 host..."
$ui = RawGet $RouterHost 80 "/index.html?verify=$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())"

if ($ui -match 'id="g4-host-controller"' -and $ui -match 'id="g4-control-frame-b64"') {
  Write-Host "G4 host: OK" -ForegroundColor Green
}
else {
  Write-Host "G4 host: NOT CONFIRMED" -ForegroundColor Yellow
}

Write-Host "2/3 Checking runtime helper..."
$helper = RawGet $RouterHost 18081 "/api/ping"

if ($helper -match '"ok":true') {
  $body = ($helper -split "`r?`n`r?`n", 2)[-1]
  Write-Host "Runtime helper: OK" -ForegroundColor Green
  Write-Host $body
}
else {
  Write-Host "Runtime helper: NOT CONFIRMED" -ForegroundColor Yellow
}

Write-Host "3/3 Recovering local ADB..."
$oldPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"

try {
  Get-Process adb -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

  Start-Sleep -Seconds 1
  & $Adb start-server
  Start-Sleep -Seconds 2
  & $Adb devices
}
finally {
  $ErrorActionPreference = $oldPreference
}

Write-Host ""
Write-Host "Open:"
Write-Host "http://$RouterHost/index.html?g4=new"
