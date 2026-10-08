$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'stack.ps1')
$p = Get-StackPaths $root
New-Item -ItemType Directory -Force -Path $p.Logs | Out-Null
$logFile = Join-Path $p.Logs 'nginx.log'
$prefix = $p.Nginx.Replace('\', '/') + '/'

# Nginx in front of everything (config in runtime\nginx-*\conf, written by
# setup-server.ps1; its own logs in runtime\nginx-*\logs). Runs forever so it
# comes back after a crash.
while ($true) {
    # A crashed master can leave its worker holding the ports.
    Get-CimInstance Win32_Process -Filter "Name = 'nginx.exe'" |
        Where-Object { $_.ExecutablePath -like "$($p.Nginx)\*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Add-Content -Path $logFile -Value "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] starting nginx" -Encoding UTF8
    cmd /c "cd /d `"$($p.Nginx)`" && .\nginx.exe -p `"$prefix`" >> `"$logFile`" 2>&1"
    Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] nginx exited, restarting in 3s" -Encoding UTF8
    Start-Sleep -Seconds 3
}
