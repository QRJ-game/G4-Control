param(
  [string]$Adb = "C:\platform-tools\adb.exe"
)

$ErrorActionPreference = "Stop"
$script:ExpectedVersion = "0.9.2"
$script:ExpectedBuild = "0902"

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
$NewUiFile = Join-Path $Root "..\payload\g4-control-frame.html"
$InjectionFile = Join-Path $Root "stock-host-injection.html"
$BootFile = Join-Path $Root "..\payload\g4-boot.sh"
$DropInFile = Join-Path $Root "..\payload\S99g4ui"
$StartupPatcherFile = Join-Path $Root "..\payload\g4-patch-startup.sh"
$StartupHookFile = Join-Path $Root "..\payload\g4-startup-hook.block"
$CustomerHookInstaller = Join-Path $Root "..\payload\g4-install-customer-hook.sh"
$CustomerHookBlock = Join-Path $Root "..\payload\g4-customer-hook.block"
$RuntimeHelperFile = Join-Path $Root "..\payload\g4-helper"
$RuntimeActionsFile = Join-Path $Root "..\payload\g4-actions.sh"

function Get-RootFreeKb {
  $text = ((& $Adb shell "df -k / | awk 'NR==2 {print `$4}'") -join "").Trim()
  if ($text -match '^\d+$') {
    return [int64]$text
  }
  return -1
}

function Invoke-RemoteProbe {
  param([Parameter(Mandatory=$true)][string]$Command)

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    $output = @(& $Adb shell $Command 2>&1)
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }

  $clean = New-Object System.Collections.Generic.List[string]

  foreach ($item in $output) {
    $line = [string]$item

    if ($line -match '^\* daemon not running; starting now at tcp:\d+\s*$') {
      continue
    }

    if ($line -match '^\* daemon started successfully\s*$') {
      continue
    }

    if (-not [string]::IsNullOrWhiteSpace($line)) {
      $clean.Add($line)
    }
  }

  if ($exitCode -ne 0 -and $clean.Count -eq 0) {
    throw "ADB shell command failed with exit code $exitCode`: $Command"
  }

  return ($clean -join "`n").Trim()
}

function Invoke-RawHttpGet {
  param(
    [Parameter(Mandatory=$true)][string]$HostName,
    [Parameter(Mandatory=$true)][int]$Port,
    [Parameter(Mandatory=$true)][string]$Path,
    [int]$TimeoutMilliseconds = 6000
  )

  $client = New-Object System.Net.Sockets.TcpClient

  try {
    $connect = $client.BeginConnect($HostName, $Port, $null, $null)

    if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
      $client.Close()
      return ""
    }

    $client.EndConnect($connect)

    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMilliseconds
    $stream.WriteTimeout = $TimeoutMilliseconds

    $request = [Text.Encoding]::ASCII.GetBytes(
      "GET $Path HTTP/1.0`r`n" +
      "Host: $HostName`r`n" +
      "Connection: close`r`n" +
      "Cache-Control: no-cache`r`n`r`n"
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
  catch {
    return ""
  }
  finally {
    $client.Close()
  }
}

function Test-RouterUiHttp {
  param(
    [string]$RouterHost = "192.168.0.1",
    [int]$TimeoutMilliseconds = 6000
  )

  $path = (
    "/index.html?g4probe=" +
    [Uri]::EscapeDataString($script:ExpectedBuild) +
    "&_=" +
    [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  )

  $response = Invoke-RawHttpGet `
    -HostName $RouterHost `
    -Port 80 `
    -Path $path `
    -TimeoutMilliseconds $TimeoutMilliseconds

  return (
    $response -match 'HTTP/1\.[01] 200' -and
    $response -match 'id="g4-host-controller"' -and
    $response -match 'id="g4-control-frame-b64"'
  )
}

function Test-RuntimeHelperHttp {
  param(
    [string]$RouterHost = "192.168.0.1",
    [int]$TimeoutMilliseconds = 6000
  )

  $response = Invoke-RawHttpGet `
    -HostName $RouterHost `
    -Port 18081 `
    -Path "/api/ping" `
    -TimeoutMilliseconds $TimeoutMilliseconds

  $expectedApiVersion = (
    '"version":"' +
    [regex]::Escape($script:ExpectedVersion) +
    '"'
  )

  return (
    $response -match 'HTTP/1\.[01] 200' -and
    $response -match '"ok":true' -and
    $response -match $expectedApiVersion
  )
}

function Test-AdbTransportOnce {
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    $state = ((& $Adb get-state 2>$null) -join "").Trim()

    if ($LASTEXITCODE -ne 0 -or $state -ne "device") {
      return $false
    }

    $probe = ((& $Adb shell "echo G4_ADB_READY" 2>$null) -join "").Trim()
    return ($LASTEXITCODE -eq 0 -and $probe -eq "G4_ADB_READY")
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }
}

function Recover-AdbTransport {
  param([int]$Attempts = 3)

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    if (Test-AdbTransportOnce) {
      return $true
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
      & $Adb start-server 2>$null | Out-Null
    }
    finally {
      $ErrorActionPreference = $oldPreference
    }

    Start-Sleep -Seconds 2

    if (Test-AdbTransportOnce) {
      return $true
    }

    Get-Process adb -ErrorAction SilentlyContinue |
      Stop-Process -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 1
  }

  return $false
}

function Test-RemoteDirectoryWritable {

  param([Parameter(Mandatory=$true)][string]$Path)

  $probe = "$Path/.g4-write-test"
  $result = Invoke-RemoteProbe "if touch '$probe' 2>/dev/null; then rm -f '$probe'; echo G4_YES; else echo G4_NO; fi"
  return $result -eq "G4_YES"
}

function Test-RemoteFileWritable {
  param([Parameter(Mandatory=$true)][string]$Path)

  $result = Invoke-RemoteProbe "if [ -w '$Path' ]; then echo G4_YES; else echo G4_NO; fi"
  return $result -eq "G4_YES"
}

function Get-RemoteDirName {
  param([Parameter(Mandatory=$true)][string]$Path)

  $index = $Path.LastIndexOf("/")
  if ($index -le 0) {
    return "/"
  }

  return $Path.Substring(0, $index)
}

function Get-StartupCandidates {
  $ordered = New-Object System.Collections.Generic.List[string]

  function Add-Candidate {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
      return
    }

    $clean = $Path.Trim().Trim('"', "'")

    if (-not $clean.StartsWith("/")) {
      return
    }

    if ($clean -match '[\r\n]') {
      return
    }

    if (-not $ordered.Contains($clean)) {
      $ordered.Add($clean)
    }
  }

  # BusyBox init declares the real startup command in inittab.
  # This firmware uses:
  #   ::sysinit:/etc/rc
  $inittabSources = @(
    "/etc/inittab",
    "/etc_ro/inittab",
    "/etc_rw/inittab"
  )

  foreach ($source in $inittabSources) {
    if (-not (Test-RemoteFile $source)) {
      continue
    }

    $content = Invoke-RemoteProbe "cat '$source' 2>/dev/null"

    foreach ($line in ($content -split "`r?`n")) {
      if ($line -notmatch '^[^#]*::(?:sysinit|once|wait):\s*(.+)$') {
        continue
      }

      $command = $matches[1].Trim()

      # Accept rc, rcS, and rc.local paths. If init launches
      # "/bin/sh /etc/rc", this correctly selects /etc/rc, not /bin/sh.
      foreach ($tokenMatch in [regex]::Matches(
        $command,
        '/[^\s;]+'
      )) {
        $token = $tokenMatch.Value.Trim('"', "'")
        $leaf = [IO.Path]::GetFileName($token)

        if ($leaf -match '^rc(?:S|\.local)?$') {
          Add-Candidate $token
        }
      }
    }
  }

  # Known layouts used by small BusyBox/router firmware.
  @(
    "/etc/rc",
    "/etc_ro/rc",
    "/etc_rw/rc",
    "/etc_ro/init.d/rcS",
    "/etc_ro/rcS",
    "/etc/init.d/rcS",
    "/etc/rcS",
    "/etc_rw/init.d/rcS",
    "/etc_rw/rcS",
    "/sbin/rcS",
    "/etc/rc.local",
    "/etc_rw/rc.local"
  ) | ForEach-Object { Add-Candidate $_ }

  # Bounded read-only discovery. Each remote command is one line,
  # so Windows CRLF cannot break a BusyBox "for ... do" loop.
  foreach ($root in @("/etc", "/etc_ro", "/etc_rw", "/sbin")) {
    foreach ($pattern in @("rc", "rcS*", "rc.local")) {
      $found = Invoke-RemoteProbe (
        "find '$root' -type f -name '$pattern' 2>/dev/null | head -n 32"
      )

      foreach ($path in ($found -split "`r?`n")) {
        if ($path.StartsWith("/")) {
          Add-Candidate $path
        }
      }
    }
  }

  return $ordered
}

function Save-PersistenceMetadata {
  param(
    [Parameter(Mandatory=$true)][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Hook,
    [Parameter(Mandatory=$true)][string]$Rc
  )

  $metaPath = Join-Path $env:TEMP "g4-install.meta"

  @(
    "VERSION=0.9.2"
    "MODE=$Mode"
    "HOOK=$Hook"
    "RC=$Rc"
  ) -join "`n" |
    Set-Content -Path $metaPath -Encoding ASCII

  & $Adb push $metaPath "/mnt/userdata/g4ui/install.meta"
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to save persistence metadata."
  }
}

function Install-DropInHook {
  param(
    [Parameter(Mandatory=$true)][string]$Directory,
    [Parameter(Mandatory=$true)][string]$RcPath
  )

  if (-not (Test-RemoteDirectoryWritable $Directory)) {
    return $null
  }

  $remoteHook = "$Directory/S99g4ui"

  & $Adb push $DropInFile $remoteHook
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload $remoteHook."
  }

  Adb-Shell "chmod 755 '$remoteHook'"
  Save-PersistenceMetadata -Mode "dropin" -Hook $remoteHook -Rc $RcPath
  return "drop-in hook $remoteHook"
}

function Install-RcLocalHook {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$RcPath
  )

  $directory = Get-RemoteDirName $Path
  if (-not (Test-RemoteDirectoryWritable $directory)) {
    return $null
  }

  $local = Join-Path $env:TEMP "g4-rc-local-v0902"
  $existing = ""

  if (Test-RemoteFile $Path) {
    & $Adb pull $Path $local | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to download $Path."
    }

    $existing = [IO.File]::ReadAllText($local)
  }

  if ($existing -notmatch '# BEGIN G4UI') {
    $block = @'

# BEGIN G4UI
if [ -x /mnt/userdata/g4ui/g4-boot.sh ]; then
    /mnt/userdata/g4ui/g4-boot.sh start >/dev/null 2>&1
fi
# END G4UI
'@

    $patched = $existing.TrimEnd("`r", "`n") + $block + "`n"
    [IO.File]::WriteAllText(
      $local,
      $patched,
      (New-Object System.Text.UTF8Encoding($false))
    )

    & $Adb push $local "/tmp/g4-rc-local.new"
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to upload the rc.local hook."
    }

    Adb-Shell "cp /tmp/g4-rc-local.new '$Path' && chmod 755 '$Path' && rm -f /tmp/g4-rc-local.new"
  }

  Save-PersistenceMetadata -Mode "rc-local" -Hook $Path -Rc $RcPath
  return "rc.local hook $Path"
}

function Patch-StartupScript {
  param([Parameter(Mandatory=$true)][string]$RcPath)

  if (-not (Test-RemoteFile $RcPath)) {
    return $null
  }

  if (-not (Test-RemoteFileWritable $RcPath)) {
    return $null
  }

  $safeName = ($RcPath.TrimStart("/") -replace '[^A-Za-z0-9_.-]', '-')
  $backupPath = "/mnt/userdata/g4ui/backup/$safeName.original"

  Adb-Shell "mkdir -p /mnt/userdata/g4ui/backup"

  & $Adb push $StartupPatcherFile "/tmp/g4-patch-startup.sh" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload the on-device startup patcher."
  }

  & $Adb push $StartupHookFile "/tmp/g4-startup-hook.block" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload the startup hook block."
  }

  Adb-Shell "chmod 755 /tmp/g4-patch-startup.sh"

  $result = Invoke-RemoteProbe (
    "/bin/sh /tmp/g4-patch-startup.sh " +
    "'$RcPath' " +
    "'/tmp/g4-startup-hook.block' " +
    "'$backupPath'"
  )

  & $Adb shell "rm -f /tmp/g4-patch-startup.sh /tmp/g4-startup-hook.block" 2>$null | Out-Null

  if (
    $result -notmatch '(?m)^G4_OK$' -and
    $result -notmatch '(?m)^G4_ALREADY$'
  ) {
    throw "On-device startup patch failed for $RcPath`: $result"
  }

  Save-PersistenceMetadata -Mode "patched-remote" -Hook $RcPath -Rc $RcPath
  return "patched startup script on-device: $RcPath"
}

function Write-StartupReport {
  param(
    [string[]]$Candidates,
    [string]$Selected = ""
  )

  $report = Join-Path $env:TEMP "g4-startup-report-v0902.txt"
  $lines = New-Object System.Collections.Generic.List[string]

  $lines.Add("G4 Control startup discovery v0.9.2")
  $lines.Add("Selected=$Selected")
  $lines.Add("")
  $lines.Add("Candidates:")

  foreach ($candidate in $Candidates) {
    $exists = Test-RemoteFile $candidate
    $writable = $false

    if ($exists) {
      $writable = Test-RemoteFileWritable $candidate
    }

    $lines.Add("$candidate exists=$exists writable=$writable")
  }

  $lines.Add("")
  $lines.Add("inittab:")
  foreach ($source in @("/etc/inittab", "/etc_ro/inittab", "/etc_rw/inittab")) {
    if (Test-RemoteFile $source) {
      $lines.Add("--- $source")
      $lines.Add((Invoke-RemoteProbe "cat '$source' 2>/dev/null"))
    }
  }

  $lines.Add("")
  $lines.Add("Existing candidate contents:")
  foreach ($candidate in $Candidates) {
    if (Test-RemoteFile $candidate) {
      $lines.Add("--- $candidate")
      $lines.Add((Invoke-RemoteProbe "sed -n '1,240p' '$candidate' 2>/dev/null"))
    }
  }

  $lines | Set-Content -Path $report -Encoding UTF8
  return $report
}

function Install-StartupHook {
  $rcReference = Invoke-RemoteProbe (
    "if grep -q '/etc/custom/customer\.sh' /etc/rc 2>/dev/null; " +
    "then echo G4_YES; else echo G4_NO; fi"
  )

  if ($rcReference -ne "G4_YES") {
    throw "Factory /etc/rc does not expose /etc/custom/customer.sh."
  }

  & $Adb push $CustomerHookInstaller "/tmp/g4-install-customer-hook.sh" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload the customer-hook installer."
  }

  & $Adb push $CustomerHookBlock "/tmp/g4-customer-hook.block" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload the customer-hook block."
  }

  Adb-Shell "chmod 755 /tmp/g4-install-customer-hook.sh"

  $result = Invoke-RemoteProbe (
    "/bin/sh /tmp/g4-install-customer-hook.sh " +
    "'/tmp/g4-customer-hook.block'"
  )

  & $Adb shell "rm -f /tmp/g4-install-customer-hook.sh /tmp/g4-customer-hook.block" 2>$null | Out-Null

  if (
    $result -notmatch '(?m)^G4_OK$' -and
    $result -notmatch '(?m)^G4_ALREADY$'
  ) {
    throw "Customer startup hook installation failed: $result"
  }

  return "factory customer hook /etc/custom/customer.sh"
}

Write-Host "1/12 Checking ADB..."
Ensure-Adb

Write-Host "2/12 Removing previous runtime services and web mounts..."
if (Test-RemoteFile "/mnt/userdata/g4ui/g4-boot.sh") {
  & $Adb shell "/mnt/userdata/g4ui/g4-boot.sh stop" 2>$null | Out-Null
}
Clear-RemoteMount "/etc_ro/web/index.html"
Clear-RemoteMount "/etc_ro/web/js/main.js"
Clear-RemoteMount "/etc_ro/web/cgi-bin/tw_upload/upload.cgi"
Clear-RemoteMount "/etc_ro/web"

Write-Host "3/12 Reading the genuine factory index..."
$factoryIndex = Join-Path $env:TEMP "g4-factory-index-v0400.html"
$patchedIndex = Join-Path $env:TEMP "g4-stock-host-v0400.html"

& $Adb pull "/etc_ro/web/index.html" $factoryIndex
if ($LASTEXITCODE -ne 0) {
  throw "Failed to download the factory index.html."
}

$factoryText = [IO.File]::ReadAllText($factoryIndex)

if (
  $factoryText -match "G4 Control" -or
  $factoryText -match "g4ControlOverlay" -or
  $factoryText.Length -gt 30000
) {
  throw @"
The downloaded index.html is not the genuine factory page.

Reboot the router, wait until the normal factory UI opens, and run install.ps1 again.
"@
}

Write-Host "Factory index verified: $($factoryText.Length) characters."

Write-Host "4/12 Embedding G4 Control into the factory host..."
$newUiBytes = [IO.File]::ReadAllBytes($NewUiFile)
$newUiBase64 = [Convert]::ToBase64String($newUiBytes)

$injection = [IO.File]::ReadAllText($InjectionFile)
if (-not $injection.Contains("__G4_NEW_UI_B64__")) {
  throw "The new-UI payload marker is missing."
}

$injection = $injection.Replace("__G4_NEW_UI_B64__", $newUiBase64)

if ($factoryText -match "</body>") {
  $patchedText = $factoryText -replace "</body>", (
    $injection +
    [Environment]::NewLine +
    "</body>"
  )
} else {
  $patchedText = $factoryText + [Environment]::NewLine + $injection
}

[IO.File]::WriteAllText(
  $patchedIndex,
  $patchedText,
  (New-Object System.Text.UTF8Encoding($false))
)

Write-Host "5/12 Running target compatibility preflight..."
Adb-Shell "mkdir -p /mnt/userdata/g4ui/backup"

& $Adb push $BootFile "/tmp/g4-boot-v0902.sh" | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload the temporary boot-service preflight file."
}

& $Adb push $RuntimeActionsFile "/tmp/g4-actions-v0902.sh" | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload the temporary actions preflight file."
}

& $Adb push $RuntimeHelperFile "/tmp/g4-helper-v0902" | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload the temporary ARM-helper preflight file."
}

Adb-Shell "chmod 755 /tmp/g4-boot-v0902.sh /tmp/g4-actions-v0902.sh /tmp/g4-helper-v0902"

$targetShellPreflight = Invoke-RemoteProbe (
  "if /bin/sh -n /tmp/g4-boot-v0902.sh && /bin/sh -n /tmp/g4-actions-v0902.sh; " +
  "then echo G4_OK; else echo G4_BAD; fi"
)

if ($targetShellPreflight -notmatch '(?m)^G4_OK$') {
  throw "The target shell rejected the v0.9.2 runtime scripts: $targetShellPreflight"
}

$helperPreflight = Invoke-RemoteProbe (
  "rm -f /tmp/g4-helper-daemon-selftest; " +
  "if /tmp/g4-helper-v0902 --self-test >/tmp/g4-helper-preflight.log 2>&1; " +
  "then echo G4_SELFTEST_OK; else cat /tmp/g4-helper-preflight.log 2>/dev/null; " +
  "echo G4_SELFTEST_BAD; fi; " +
  "if /tmp/g4-helper-v0902 --daemon-self-test >/dev/null 2>&1; " +
  "then sleep 2; " +
  "if grep -q G4_OK /tmp/g4-helper-daemon-selftest 2>/dev/null; " +
  "then echo G4_DAEMON_OK; else echo G4_DAEMON_BAD; fi; " +
  "else echo G4_DAEMON_BAD; fi"
)

& $Adb shell "rm -f /tmp/g4-boot-v0902.sh /tmp/g4-actions-v0902.sh /tmp/g4-helper-v0902 /tmp/g4-helper-preflight.log /tmp/g4-helper-daemon-selftest" 2>$null | Out-Null

if (
  $helperPreflight -notmatch '(?m)^G4_SELFTEST_OK$' -or
  $helperPreflight -notmatch '(?m)^G4_DAEMON_OK$'
) {
  throw "ARM runtime helper is incompatible with this router: $helperPreflight"
}

Write-Host "Target shell and ARM helper preflight: OK"

Write-Host "6/12 Uploading and verifying UI/runtime files..."

& $Adb push $factoryIndex "/mnt/userdata/g4ui/factory-index-original.html"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to save the factory-index backup."
}

& $Adb push $patchedIndex "/mnt/userdata/g4ui/stock-host.html"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload the patched stock host."
}

& $Adb push $BootFile "/mnt/userdata/g4ui/g4-boot.sh"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload the persistent boot service."
}

& $Adb push $RuntimeHelperFile "/mnt/userdata/g4ui/g4-helper"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload the ARM runtime helper."
}

& $Adb push $RuntimeActionsFile "/mnt/userdata/g4ui/g4-actions.sh"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload the runtime actions script."
}

Adb-Shell "chmod 755 /mnt/userdata/g4ui/g4-boot.sh /mnt/userdata/g4ui/g4-helper /mnt/userdata/g4ui/g4-actions.sh"

$persistentHelperSelfTest = Invoke-RemoteProbe (
  "rm -f /tmp/g4-helper-daemon-selftest; " +
  "if /mnt/userdata/g4ui/g4-helper --self-test >/tmp/g4-helper-persistent-test.log 2>&1; " +
  "then echo G4_SELFTEST_OK; else cat /tmp/g4-helper-persistent-test.log 2>/dev/null; " +
  "echo G4_SELFTEST_BAD; fi; " +
  "if /mnt/userdata/g4ui/g4-helper --daemon-self-test >/dev/null 2>&1; " +
  "then sleep 2; " +
  "if grep -q G4_OK /tmp/g4-helper-daemon-selftest 2>/dev/null; " +
  "then echo G4_DAEMON_OK; else echo G4_DAEMON_BAD; fi; " +
  "else echo G4_DAEMON_BAD; fi"
)

& $Adb shell "rm -f /tmp/g4-helper-persistent-test.log /tmp/g4-helper-daemon-selftest" 2>$null | Out-Null

if (
  $persistentHelperSelfTest -notmatch '(?m)^G4_SELFTEST_OK$' -or
  $persistentHelperSelfTest -notmatch '(?m)^G4_DAEMON_OK$'
) {
  throw "The runtime helper cannot execute from /mnt/userdata: $persistentHelperSelfTest"
}

Adb-Shell "echo 256 > /mnt/userdata/g4ui/min-free-kb"
Adb-Shell "echo enabled > /etc_rw/g4ui.enable"

$remoteSize = (
  (& $Adb shell "wc -c < /mnt/userdata/g4ui/stock-host.html") -join ""
).Trim()

if ($remoteSize -notmatch '^\d+$' -or [int64]$remoteSize -lt 70000) {
  throw "Uploaded host is invalid or too small: $remoteSize bytes."
}

$bootPreflight = Invoke-RemoteProbe (
  "/bin/sh /mnt/userdata/g4ui/g4-boot.sh status"
)

$expectedBootVersionPattern = (
  "(?m)^version=" + [regex]::Escape($script:ExpectedVersion) + "$"
)

if ($bootPreflight -notmatch $expectedBootVersionPattern) {
  throw (
    "Boot service preflight version mismatch. " +
    "Expected $($script:ExpectedVersion):`n$bootPreflight"
  )
}

if ($bootPreflight -notmatch '(?m)^payload=ok$') {
  throw "Boot service rejected the uploaded UI payload: $bootPreflight"
}

Write-Host "Boot service preflight: OK"

Write-Host "7/12 Installing or updating the persistent startup hook..."
$hookDescription = Install-StartupHook
Write-Host "Persistence: $hookDescription"

Write-Host "8/12 Activating the persistent host..."
Adb-Shell "/mnt/userdata/g4ui/g4-boot.sh restart"

Write-Host "9/12 Verifying UI and runtime directly over the router LAN..."

$uiReady = $false
$helperReady = $false

for ($attempt = 1; $attempt -le 10; $attempt++) {
  if (-not $uiReady) {
    $uiReady = Test-RouterUiHttp
  }

  if (-not $helperReady) {
    $helperReady = Test-RuntimeHelperHttp
  }

  if ($uiReady -and $helperReady) {
    break
  }

  Start-Sleep -Seconds 1
}

if (-not $uiReady) {
  throw (
    "The router did not serve the injected G4 host on TCP 80. " +
    "The remote restart completed, but HTTP verification failed."
  )
}

if (-not $helperReady) {
  throw (
    "The G4 UI is active, but runtime helper /api/ping " +
    "v$($script:ExpectedVersion) is unavailable on TCP 18081."
  )
}

Write-Host "Injected G4 host: HTTP verification OK"
Write-Host "Runtime helper: HTTP API v$($script:ExpectedVersion) is running on TCP 18081"

Write-Host "10/12 Recovering optional ADB diagnostics..."
$adbRecovered = Recover-AdbTransport

if ($adbRecovered) {
  try {
    Adb-Shell "/mnt/userdata/g4ui/g4-boot.sh cleanup"
    Write-Host "Low-space cleanup check: OK"
  }
  catch {
    Write-Warning "Cleanup check was skipped: $($_.Exception.Message)"
  }
}
else {
  Write-Warning (
    "The local Windows ADB daemon is unavailable after activation. " +
    "The installation remains valid because both router HTTP checks passed."
  )
}

Write-Host "11/12 Reading final status..."
if ($adbRecovered) {
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    & $Adb shell "/mnt/userdata/g4ui/g4-boot.sh status"
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }
}
else {
  Write-Host "ADB status skipped; UI and helper were verified directly over LAN."
}

Write-Host "12/12 Done."
Write-Host "Open http://192.168.0.1/index.html?g4=new&build=$($script:ExpectedBuild)"
Write-Host ""
Write-Host "The UI will now activate automatically after a normal reboot."
Write-Host "Factory UI rescue: helper\factory-ui.ps1"
Write-Host "Full rollback: helper\rollback.ps1"
