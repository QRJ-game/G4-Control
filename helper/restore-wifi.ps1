param(
  [string]$RouterHost = "192.168.0.1",
  [string]$Adb = "C:\platform-tools\adb.exe"
)

$ErrorActionPreference = "Stop"
$CookieJar = Join-Path $env:TEMP "g4-restore-wifi.cookies"

function Find-Adb {
  param([string]$Preferred)

  $candidates = @(
    $Preferred,
    (Join-Path $PSScriptRoot "..\platform-tools\adb.exe"),
    (Join-Path $PSScriptRoot "platform-tools\adb.exe"),
    (Join-Path $PSScriptRoot "adb.exe")
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      return (Resolve-Path $candidate).Path
    }
  }

  $fromPath = Get-Command adb.exe -ErrorAction SilentlyContinue
  if ($fromPath) {
    return $fromPath.Source
  }

  throw "adb.exe не найден."
}

function Find-Curl {
  $fromPath = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($fromPath) {
    return $fromPath.Source
  }

  $systemCurl = "$env:SystemRoot\System32\curl.exe"
  if (Test-Path $systemCurl) {
    return $systemCurl
  }

  throw "curl.exe не найден."
}

function Run-Adb {
  param([string[]]$Arguments, [switch]$AllowFailure)

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    $raw = @(& $script:AdbExe @Arguments 2>&1)
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }

  $text = (
    $raw |
      ForEach-Object { [string]$_ } |
      Where-Object {
        $_ -notmatch '^\* daemon not running; starting now at tcp:\d+\s*$' -and
        $_ -notmatch '^\* daemon started successfully\s*$'
      }
  ) -join "`n"

  if ($code -ne 0 -and -not $AllowFailure) {
    throw "ADB error $code`n$text"
  }

  return [pscustomobject]@{ExitCode=$code; Text=$text.Trim()}
}

function Run-Curl {
  param(
    [string[]]$Arguments,
    [int]$MaxTime = 20,
    [switch]$AllowFailure
  )

  $common = @(
    "--silent",
    "--show-error",
    "--http1.0",
    "--connect-timeout", "5",
    "--max-time", [string]$MaxTime,
    "--cookie", $CookieJar,
    "--cookie-jar", $CookieJar
  )

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    $raw = @(& $script:CurlExe @common @Arguments 2>&1)
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }

  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"

  if ($code -ne 0 -and -not $AllowFailure) {
    throw "curl.exe error $code`n$text"
  }

  return [pscustomobject]@{ExitCode=$code; Text=$text.Trim()}
}

function Encode([AllowNull()][string]$Value) {
  if ($null -eq $Value) { return "" }
  return [Uri]::EscapeDataString($Value)
}

function Read-Json {
  param([string]$Text, [string]$Context)

  try {
    return $Text | ConvertFrom-Json
  }
  catch {
    throw "Некорректный JSON ($Context): $Text"
  }
}

function Router-Get {
  param([string]$Commands)

  $url = (
    "$script:BaseUrl/goform/goform_get_cmd_process" +
    "?isTest=false&multi_data=1&cmd=$(Encode $Commands)" +
    "&_=$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())"
  )

  $response = Run-Curl @($url)
  return Read-Json $response.Text "GET $Commands"
}

function Router-Post {
  param(
    [hashtable]$Parameters,
    [int]$MaxTime = 20,
    [switch]$AllowFailure
  )

  $pairs = foreach ($key in $Parameters.Keys) {
    "$(Encode ([string]$key))=$(Encode ([string]$Parameters[$key]))"
  }

  $response = Run-Curl @(
    "--header", "Content-Type: application/x-www-form-urlencoded; charset=UTF-8",
    "--data-raw", ($pairs -join "&"),
    "$script:BaseUrl/goform/goform_set_cmd_process"
  ) -MaxTime $MaxTime -AllowFailure:$AllowFailure

  if ($response.ExitCode -ne 0 -and $AllowFailure) {
    return [pscustomobject]@{
      result = "connection_interrupted"
      detail = $response.Text
    }
  }

  return Read-Json $response.Text "POST $($Parameters.goformId)"
}

function Secure-To-Plain {
  param([Security.SecureString]$Secure)

  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)

  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

function Read-NewPassword {
  while ($true) {
    $secure = Read-Host "Введите новый пароль Wi-Fi (ASCII, 8-63 символа)" -AsSecureString
    $plain = Secure-To-Plain $secure

    if ($plain.Length -lt 8 -or $plain.Length -gt 63) {
      Write-Host "Длина должна быть от 8 до 63 символов." -ForegroundColor Yellow
      continue
    }

    if ($plain -notmatch '^[\x20-\x7E]+$') {
      Write-Host "Допустимы только печатные ASCII-символы." -ForegroundColor Yellow
      continue
    }

    $repeatSecure = Read-Host "Повторите пароль" -AsSecureString
    $repeat = Secure-To-Plain $repeatSecure

    if ($plain -ne $repeat) {
      Write-Host "Пароли не совпадают." -ForegroundColor Yellow
      continue
    }

    return $plain
  }
}

$script:AdbExe = Find-Adb $Adb
$script:CurlExe = Find-Curl
$script:BaseUrl = "http://$RouterHost"

try {
  Write-Host "G4 Restore Wi-Fi v0.3"
  Write-Host ""

  Write-Host "1/7 Проверка USB/ADB и штатного WebAPI..."
  Run-Adb @("start-server") -AllowFailure | Out-Null

  $devices = Run-Adb @("devices")
  $deviceLines = @(
    $devices.Text -split "`r?`n" |
      Where-Object { $_ -match '^\S+\s+device$' }
  )

  if ($deviceLines.Count -ne 1) {
    throw "Нужно ровно одно ADB-устройство. Найдено: $($deviceLines.Count)"
  }

  Run-Curl @("$script:BaseUrl/index.html") | Out-Null

  Write-Host "2/7 Автовход в штатный API..."
  $auth = Router-Get "admin_encrypsw"
  $loginPassword = [string]$auth.admin_encrypsw

  if ([string]::IsNullOrWhiteSpace($loginPassword)) {
    throw "Роутер не вернул admin_encrypsw."
  }

  $login = Router-Post @{
    goformId = "LOGIN"
    isTest = "false"
    username = "YWRtaW4="
    password = $loginPassword
  }

  if ([string]$login.result -notin @("0", "4", "success")) {
    throw "LOGIN result=$($login.result)"
  }

  Write-Host "3/7 Чтение текущей конфигурации..."
  $before = Router-Get (
    "wifi_cur_state,m_ssid_enable,SSID1,AuthMode,HideSSID," +
    "MAX_Access_num,NoForwarding,show_qrcode_flag,WPAPSK1_encode"
  )

  $ssid = [string]$before.SSID1
  if ([string]::IsNullOrWhiteSpace($ssid)) {
    throw "SSID1 пуст."
  }

  $maxClients = [string]$before.MAX_Access_num
  if ($maxClients -notmatch '^\d+$') { $maxClients = "32" }

  $hidden = [string]$before.HideSSID
  if ($hidden -notin @("0", "1")) { $hidden = "0" }

  $isolation = [string]$before.NoForwarding
  if ($isolation -notin @("0", "1")) { $isolation = "0" }

  $qr = [string]$before.show_qrcode_flag
  if ($qr -notin @("0", "1")) { $qr = "0" }

  $multiSsid = [string]$before.m_ssid_enable
  if ($multiSsid -notin @("0", "1")) { $multiSsid = "0" }

  Write-Host "SSID: $ssid"
  Write-Host "wifi_cur_state=$($before.wifi_cur_state)"
  Write-Host ""

  $newPassword = Read-NewPassword
  $encodedPassword = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes($newPassword)
  )

  Write-Host "4/7 Сохранение нового WPA2-пароля в Base64..."
  $save = Router-Post @{
    goformId = "SET_WIFI_SSID1_SETTINGS"
    isTest = "false"
    ssid = $ssid
    broadcastSsidEnabled = $hidden
    MAX_Access_num = $maxClients
    security_mode = "WPA2PSK"
    cipher = "1"
    security_shared_mode = "1"
    passphrase = $encodedPassword
    NoForwarding = $isolation
    show_qrcode_flag = $qr
  }

  if ([string]$save.result -notin @("success", "0")) {
    throw "SET_WIFI_SSID1_SETTINGS result=$($save.result)"
  }

  Write-Host "5/7 Проверка сохранённого значения..."
  Start-Sleep -Milliseconds 800
  $check = Router-Get "WPAPSK1_encode,SSID1,AuthMode"

  if (
    ([string]$check.WPAPSK1_encode).TrimEnd("=") -ne
    $encodedPassword.TrimEnd("=")
  ) {
    throw "Backend не подтвердил новый Base64-пароль."
  }

  if ([string]$check.SSID1 -ne $ssid) {
    throw "Backend изменил SSID."
  }

  Write-Host "Пароль сохранён и подтверждён." -ForegroundColor Green

  Write-Host "6/7 Отправка штатной команды включения Wi-Fi..."
  $enable = Router-Post @{
    goformId = "SET_WIFI_INFO"
    isTest = "false"
    wifiEnabled = "1"
    m_ssid_enable = $multiSsid
  } -MaxTime 8 -AllowFailure

  if ([string]$enable.result -eq "connection_interrupted") {
    Write-Host (
      "Соединение с backend прервалось во время запуска Wi-Fi. " +
      "Для этой прошивки это допустимо."
    ) -ForegroundColor Yellow
  }
  else {
    Write-Host "SET_WIFI_INFO result=$($enable.result)"
  }

  Write-Host "7/7 Готово."
  Write-Host ""
  Write-Host "Конфигурация Wi-Fi исправлена." -ForegroundColor Green
  Write-Host "Подождите 20 секунд и проверьте SSID."
  Write-Host (
    "Если сеть не появилась, полностью выключите роутер кнопкой питания, " +
    "подождите 5 секунд и включите снова."
  ) -ForegroundColor Yellow
  Write-Host ""
  Write-Host "adb reboot на этой модели может не выполнять перезагрузку."
}
finally {
  Remove-Item -Force $CookieJar -ErrorAction SilentlyContinue
}
