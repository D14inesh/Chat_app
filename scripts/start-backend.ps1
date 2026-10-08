# One API worker. With -Port it's one of the workers behind Nginx
# (start-stack.ps1 starts one per port); without, the single all-in-one
# backend that serves HTTP/HTTPS itself (ports from backend\.env).
param([int]$Port = 0)
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path "$root\logs" | Out-Null
$logFile = if ($Port) { "$root\logs\backend-$Port.log" } else { "$root\logs\backend.log" }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUNBUFFERED = '1'   # log lines show up right away
if ($Port) {
    # Environment wins over backend\.env, so each worker gets its own port.
    $env:PORT = "$Port"
    $env:BEHIND_PROXY = '1'
}

# Runs forever so the API survives a crash without anyone having to restart
# it by hand — each attempt is timestamped in the log. Output goes through
# cmd's >> so the log stays plain UTF-8 (PowerShell 5.1's *>> writes UTF-16).
while ($true) {
    Add-Content -Path $logFile -Value "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] starting backend (run.py)" -Encoding UTF8
    cmd /c "cd /d `"$root\backend`" && venv\Scripts\python.exe run.py >> `"$logFile`" 2>&1"
    Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] backend exited, restarting in 5s" -Encoding UTF8
    Start-Sleep -Seconds 5
}
