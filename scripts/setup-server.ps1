# One-time setup on a Windows server. Run in PowerShell **as Administrator**
# from the chat-application folder:
#
#   powershell -ExecutionPolicy Bypass -File scripts\setup-server.ps1 -PgPassword "<your postgres password>"
#
# Needs Python 3.11+ and PostgreSQL already installed. Safe to re-run.
# It: installs the Python packages, creates backend\.env (if missing), creates
# the database, makes an HTTPS certificate for the public IP, opens the
# firewall ports, and starts backend + frontend now and at every boot.
param(
    [string]$PublicIp = '103.207.3.66',
    [Parameter(Mandatory = $true)][string]$PgPassword,
    [string]$PgUser = 'postgres'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root 'backend'
$py = Join-Path $backend 'venv\Scripts\python.exe'

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

Step 'Python packages'
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw 'Python is not installed (https://www.python.org/downloads/ - tick "Add python.exe to PATH").' }
if (-not (Test-Path $py)) { python -m venv (Join-Path $backend 'venv') }
& $py -m pip install --upgrade pip -q
& $py -m pip install -r (Join-Path $backend 'requirements.txt') -q
if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }

Step 'backend\.env'
$envFile = Join-Path $backend '.env'
if (Test-Path $envFile) {
    Write-Host '  .env already exists - left as is.'
} else {
    $bytes = New-Object byte[] 48
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $jwt = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $text = Get-Content (Join-Path $backend '.env.example') -Raw
    # Ports 4100/4543 match frontend\public\config.js.
    $text = $text -replace '(?m)^PORT=.*', 'PORT=4100'
    $text = $text -replace '(?m)^HTTPS_PORT=.*', 'HTTPS_PORT=4543'
    $text = $text -replace '(?m)^PGUSER=.*', "PGUSER=$PgUser"
    $text = $text -replace '(?m)^PGPASSWORD=.*', "PGPASSWORD=$PgPassword"
    $text = $text -replace '(?m)^JWT_SECRET=.*', "JWT_SECRET=$jwt"
    $text = $text -replace '(?m)^SESSION_TTL=.*', 'SESSION_TTL=365d'
    $text = $text -replace '(?m)^CORS_ORIGINS=.*', "CORS_ORIGINS=https://${PublicIp}:5443,http://${PublicIp}:5173,http://localhost:5173,https://localhost:5443"
    [IO.File]::WriteAllText($envFile, $text, (New-Object Text.UTF8Encoding $false))
    Write-Host '  Created. For reminders (web push), copy VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY from your PC''s .env into it.'
}

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
foreach ($port in 5173, 5443, 4100, 4543) {
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

Write-Host "`nDone." -ForegroundColor Green
Write-Host "  Website:  https://${PublicIp}:5443"
Write-Host "  API:      https://${PublicIp}:4543   (open this once in each browser and accept the warning)"
Write-Host "  Logs:     $root\logs"
