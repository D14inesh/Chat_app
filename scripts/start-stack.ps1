# Starts the whole server in the background — run at boot by start-all.vbs:
#
#   Redis ─► the API workers (one per port in runtime\stack.json) ─► Nginx
#
# Each piece runs in its own restart loop (start-redis/backend/nginx.ps1),
# so a crash comes back by itself. Without runtime\stack.json (setup-server.ps1
# not run with Nginx yet, or a development PC) it starts the old way: one
# backend that serves HTTPS itself, plus frontend\serve.py.
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'stack.ps1')
$p = Get-StackPaths $root

function Start-Loop([string]$Script, [string]$Arguments = '') {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\$Script`" $Arguments"
}

if (-not (Test-Path $p.Stack)) {
    Start-Loop 'start-backend.ps1'
    Start-Loop 'start-frontend.ps1'
    return
}

$stack = Get-Content $p.Stack -Raw | ConvertFrom-Json
Start-Loop 'start-redis.ps1'
Start-Sleep -Seconds 2   # workers refuse to start without Redis
foreach ($port in $stack.workerPorts) { Start-Loop 'start-backend.ps1' "-Port $port" }
Start-Loop 'start-nginx.ps1'
