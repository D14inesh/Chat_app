# One-time setup on a Windows server. Run in PowerShell **as Administrator**
# from the chat-application folder:
#
#   powershell -ExecutionPolicy Bypass -File scripts\setup-server.ps1 -PgPassword "<your postgres password>"
#
# Needs Python 3.11+ and PostgreSQL already installed. Safe to re-run.
# It: installs the Python packages, writes backend\.env and frontend\.env,
# creates the database, makes an HTTPS certificate for the public IP, opens
# the firewall ports, and starts backend + frontend now and at every boot.
#
# Ports (change with -ApiPort etc. if another program already uses one):
#   website  http 5800 / https 5843      API  http 4800 / https 4843
# The mobile app is built for https://<PublicIp>:4843 — if you change
# -ApiHttpsPort, the APK has to be rebuilt for the new port.
param(
    [string]$PublicIp = '103.207.3.66',
    [Parameter(Mandatory = $true)][string]$PgPassword,
    [string]$PgUser = 'postgres',
    [int]$ApiPort = 4800,
    [int]$ApiHttpsPort = 4843,
    [int]$WebPort = 5800,
    [int]$WebHttpsPort = 5843
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root 'backend'
$frontend = Join-Path $root 'frontend'
$py = Join-Path $backend 'venv\Scripts\python.exe'
$utf8 = New-Object Text.UTF8Encoding $false
$ports = @($ApiPort, $ApiHttpsPort, $WebPort, $WebHttpsPort)

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

function Stop-ChatApp {
    # Only this app's processes: the start-*.ps1 loops and everything they
    # launched (cmd -> venv python -> the real python it hands off to).
    $all = @(Get-CimInstance Win32_Process)
    $ids = @($all | Where-Object {
            $_.CommandLine -and ($_.CommandLine -like "*$root\scripts\start-backend.ps1*" -or $_.CommandLine -like "*$root\scripts\start-frontend.ps1*")
        } | ForEach-Object { $_.ProcessId })
    $before = -1
    while ($ids.Count -ne $before) {
        $before = $ids.Count
        $ids = @($ids + @($all | Where-Object { $ids -contains $_.ParentProcessId -and $ids -notcontains $_.ProcessId } | ForEach-Object { $_.ProcessId }))
    }
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

Step 'Ports'
Stop-ChatApp   # a re-run must not see our own old copy as "port in use"
Start-Sleep -Seconds 2
$busy = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ports -contains $_.LocalPort }
if ($busy) {
    foreach ($b in $busy) {
        $proc = (Get-Process -Id $b.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Write-Host "  port $($b.LocalPort) is already used by '$proc'" -ForegroundColor Red
    }
    throw 'Pick free ports, e.g.:  -ApiPort 4900 -ApiHttpsPort 4943 -WebPort 5900 -WebHttpsPort 5943'
}
Write-Host "  free: $($ports -join ', ')"

Step 'Python packages'
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw 'Python is not installed (https://www.python.org/downloads/ - tick "Add python.exe to PATH").' }
if (-not (Test-Path $py)) { python -m venv (Join-Path $backend 'venv') }
& $py -m pip install --upgrade pip -q
& $py -m pip install -r (Join-Path $backend 'requirements.txt') -q
if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }

Step 'backend\.env'
$envFile = Join-Path $backend '.env'
if (Test-Path $envFile) {
    $text = [IO.File]::ReadAllText($envFile)
    Write-Host '  exists - keeping its passwords/keys, updating ports and allowed origins.'
} else {
    $bytes = New-Object byte[] 48
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $jwt = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $text = [IO.File]::ReadAllText((Join-Path $backend '.env.example'))
    $text = $text -replace '(?m)^PGUSER=.*', "PGUSER=$PgUser"
    $text = $text -replace '(?m)^PGPASSWORD=.*', "PGPASSWORD=$PgPassword"
    $text = $text -replace '(?m)^JWT_SECRET=.*', "JWT_SECRET=$jwt"
    Write-Host '  created. For reminders (web push), copy VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY from your PC''s .env into it.'
}
$text = $text -replace '(?m)^PORT=.*', "PORT=$ApiPort"
$text = $text -replace '(?m)^HTTPS_PORT=.*', "HTTPS_PORT=$ApiHttpsPort"
$text = $text -replace '(?m)^SESSION_TTL=.*', 'SESSION_TTL=365d'
$text = $text -replace '(?m)^CORS_ORIGINS=.*', "CORS_ORIGINS=https://${PublicIp}:$WebHttpsPort,http://${PublicIp}:$WebPort,http://localhost:$WebPort,https://localhost:$WebHttpsPort"
[IO.File]::WriteAllText($envFile, $text, $utf8)

Step 'frontend\.env'
[IO.File]::WriteAllText((Join-Path $frontend '.env'), @"
# Written by scripts\setup-server.ps1 - read by serve.py.
FRONTEND_PORT=$WebPort
FRONTEND_HTTPS_PORT=$WebHttpsPort
API_HTTP_PORT=$ApiPort
API_HTTPS_PORT=$ApiHttpsPort
"@, $utf8)
Write-Host '  written.'

Step 'Database'
Push-Location $backend
try {
    & $py setup_db.py
    if ($LASTEXITCODE -ne 0) { throw 'Database setup failed - check PGUSER/PGPASSWORD in backend\.env' }

    Step "HTTPS certificate for $PublicIp"
    & $py gen_cert.py $PublicIp
    if ($LASTEXITCODE -ne 0) { throw 'Certificate generation failed' }
} finally { Pop-Location }

Step 'Firewall'
foreach ($port in $ports) {
    $name = "Chat application $port"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
    }
    Write-Host "  port $port open"
}

Step 'Start now and at every boot'
$vbs = Join-Path $root 'scripts\start-all.vbs'
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries
Register-ScheduledTask -TaskName 'Chat application' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'Chat application'

Step 'Check'
Start-Sleep -Seconds 12
foreach ($port in $ports) {
    $up = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($up) { Write-Host "  $port listening" -ForegroundColor Green }
    else { Write-Host "  $port NOT listening yet - see $root\logs" -ForegroundColor Yellow }
}

Write-Host "`nDone." -ForegroundColor Green
Write-Host "  Website:  https://${PublicIp}:$WebHttpsPort"
Write-Host "  API:      https://${PublicIp}:$ApiHttpsPort   (open this once in each browser and accept the warning)"
Write-Host "  Logs:     $root\logs"
