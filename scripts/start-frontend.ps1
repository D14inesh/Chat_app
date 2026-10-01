$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path "$root\logs" | Out-Null
$logFile = "$root\logs\frontend.log"
$env:PYTHONIOENCODING = 'utf-8'

# serve.py is standard-library only, so the backend's venv python works fine.
while ($true) {
    Add-Content -Path $logFile -Value "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] starting frontend (serve.py)" -Encoding UTF8
    cmd /c "cd /d `"$root\frontend`" && `"$root\backend\venv\Scripts\python.exe`" serve.py >> `"$logFile`" 2>&1"
    Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] frontend exited, restarting in 5s" -Encoding UTF8
    Start-Sleep -Seconds 5
}
