$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'stack.ps1')
$p = Get-StackPaths $root
New-Item -ItemType Directory -Force -Path $p.Logs | Out-Null
$logFile = Join-Path $p.Logs 'redis.log'

# Redis for the API workers (127.0.0.1 only, settings in runtime\redis-*\veyon.conf).
# Runs forever so it comes back after a crash.
while ($true) {
    Add-Content -Path $logFile -Value "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] starting redis" -Encoding UTF8
    cmd /c "cd /d `"$($p.Redis)`" && .\redis-server.exe veyon.conf >> `"$logFile`" 2>&1"
    Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] redis exited, restarting in 3s" -Encoding UTF8
    Start-Sleep -Seconds 3
}
