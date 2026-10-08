# Shared helpers for the server layout:
#
#   Users ──► Nginx ──► API workers (FastAPI + WebSocket) ──► Redis / PostgreSQL
#
# Dot-sourced by setup-server.ps1 and start-stack.ps1. Everything generated
# lives in runtime\ (ignored by git): Nginx, Redis, their config, and the
# website's config.js / version.json.

$NginxVersion = '1.30.5'
$NginxZipUrl  = "https://nginx.org/download/nginx-$NginxVersion.zip"
# Redis doesn't ship Windows builds itself; this is the widely used build of
# the official Redis source for Windows (https://github.com/redis-windows/redis-windows).
$RedisVersion = '8.10.2'
$RedisZipUrl  = "https://github.com/redis-windows/redis-windows/releases/download/$RedisVersion/Redis-$RedisVersion-Windows-x64-msys2-with-Service.zip"

function Get-StackPaths([string]$Root) {
    $rt = Join-Path $Root 'runtime'
    [pscustomobject]@{
        Runtime = $rt
        Nginx   = Join-Path $rt "nginx-$NginxVersion"
        Redis   = Join-Path $rt "redis-$RedisVersion"
        Site    = Join-Path $rt 'site'
        Stack   = Join-Path $rt 'stack.json'
        Logs    = Join-Path $Root 'logs'
    }
}

function Install-StackBinaries([string]$Root) {
    # Downloads Nginx and Redis once into runtime\ (kept on later runs).
    $p = Get-StackPaths $Root
    New-Item -ItemType Directory -Force -Path $p.Runtime | Out-Null
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Test-Path (Join-Path $p.Nginx 'nginx.exe'))) {
            $zip = Join-Path $p.Runtime 'nginx.zip'
            Invoke-WebRequest $NginxZipUrl -OutFile $zip -UseBasicParsing
            Expand-Archive $zip -DestinationPath $p.Runtime -Force   # makes nginx-<version>\
            Remove-Item $zip
            Write-Host "  Nginx $NginxVersion installed."
        } else { Write-Host "  Nginx $NginxVersion already installed." }
        if (-not (Test-Path (Join-Path $p.Redis 'redis-server.exe'))) {
            $zip = Join-Path $p.Runtime 'redis.zip'
            $tmp = Join-Path $p.Runtime 'redis-unzip'
            Invoke-WebRequest $RedisZipUrl -OutFile $zip -UseBasicParsing
            Expand-Archive $zip -DestinationPath $tmp -Force
            $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
            Move-Item $inner.FullName $p.Redis
            Remove-Item $zip; Remove-Item $tmp -Recurse -Force
            Write-Host "  Redis $RedisVersion installed."
        } else { Write-Host "  Redis $RedisVersion already installed." }
    } finally { $ProgressPreference = $old }
}

function New-Secret([int]$Bytes = 24) {
    $b = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    -join ($b | ForEach-Object { $_.ToString('x2') })
}

function Get-SiteVersion([string]$PublicDir) {
    # Fingerprint of every website file — open apps poll /version.json and
    # update themselves when it changes (same idea as frontend/serve.py).
    $sha = [Security.Cryptography.SHA256]::Create()
    $text = (Get-ChildItem $PublicDir -Recurse -File | Sort-Object FullName | ForEach-Object {
            "$($_.FullName.Substring($PublicDir.Length))|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"
        }) -join "`n"
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
    (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
}

function Write-StackConfig {
    # Writes runtime\: nginx conf, redis conf, the website's config.js +
    # version.json, and stack.json (what start-stack.ps1 starts).
    param(
        [string]$Root,
        [int]$Workers, [int]$WorkerBasePort,
        [int]$WebHttp, [int]$WebHttps, [int]$ApiHttp, [int]$ApiHttps,
        [int]$RedisPort, [string]$RedisPassword,
        [string]$Cert, [string]$Key,
        [string]$MaxBody = '110m'
    )
    $utf8 = New-Object Text.UTF8Encoding $false
    $p = Get-StackPaths $Root
    $fwd = { param($x) $x.Replace('\', '/') }
    New-Item -ItemType Directory -Force -Path $p.Site, $p.Logs | Out-Null

    # Nginx
    $conf = Join-Path $p.Nginx 'conf'
    $tpl = Join-Path $Root 'deploy\nginx'
    $ports = @(0..($Workers - 1) | ForEach-Object { $WorkerBasePort + $_ })
    $upstreams = ($ports | ForEach-Object { "        server 127.0.0.1:$_ max_fails=2 fail_timeout=5s;" }) -join "`n"
    $main = [IO.File]::ReadAllText((Join-Path $tpl 'nginx.conf.template'))
    $main = $main.Replace('{{UPSTREAMS}}', $upstreams).Replace('{{MAX_BODY}}', $MaxBody)
    $main = $main.Replace('{{WEB_HTTP}}', "$WebHttp").Replace('{{WEB_HTTPS}}', "$WebHttps")
    $main = $main.Replace('{{API_HTTP}}', "$ApiHttp").Replace('{{API_HTTPS}}', "$ApiHttps")
    $main = $main.Replace('{{CERT}}', (& $fwd $Cert)).Replace('{{KEY}}', (& $fwd $Key))
    $main = $main.Replace('{{PUBLIC}}', (& $fwd (Join-Path $Root 'frontend\public')))
    [IO.File]::WriteAllText((Join-Path $conf 'nginx.conf'), $main, $utf8)
    $site = [IO.File]::ReadAllText((Join-Path $tpl 'veyon-site.conf.template')).Replace('{{SITE}}', (& $fwd $p.Site))
    [IO.File]::WriteAllText((Join-Path $conf 'veyon-site.conf'), $site, $utf8)
    Copy-Item (Join-Path $tpl 'veyon-api.conf'), (Join-Path $tpl 'veyon-proxy.conf') $conf -Force

    # Redis: memory only (it holds live state — who's online, ringing calls —
    # that is rebuilt as people reconnect), reachable from this machine only.
    [IO.File]::WriteAllText((Join-Path $p.Redis 'veyon.conf'), @"
# Written by scripts\setup-server.ps1
bind 127.0.0.1
port $RedisPort
protected-mode yes
requirepass $RedisPassword
save ""
appendonly no
maxmemory 256mb
maxmemory-policy noeviction
"@, $utf8)

    # Website: the API is on the same address (Nginx sends /api and /ws on).
    [IO.File]::WriteAllText((Join-Path $p.Site 'config.js'), @"
// Generated by scripts\setup-server.ps1 - the API is behind the same Nginx.
window.APP_CONFIG = { apiBase: '', sameOrigin: true };
"@, $utf8)
    $version = Get-SiteVersion (Join-Path $Root 'frontend\public')
    [IO.File]::WriteAllText((Join-Path $p.Site 'version.json'), "{`"version`":`"$version`"}", $utf8)

    [IO.File]::WriteAllText($p.Stack, (@{ workerPorts = $ports; redisPort = $RedisPort } | ConvertTo-Json), $utf8)
}

function Test-NginxConfig([string]$Root) {
    # Prints Nginx's verdict, returns $true when the config is good. Through
    # cmd: Nginx reports on stderr, which PowerShell 5.1 would turn into an
    # error. Forward slashes: a trailing backslash before the closing quote
    # would swallow the quote on the command line.
    $p = Get-StackPaths $Root
    $prefix = $p.Nginx.Replace('\', '/') + '/'
    $out = cmd /c "cd /d `"$($p.Nginx)`" && .\nginx.exe -t -p `"$prefix`" 2>&1"
    $ok = $LASTEXITCODE -eq 0
    $out | ForEach-Object { Write-Host "  $_" -ForegroundColor $(if ($ok) { 'Gray' } else { 'Red' }) }
    return $ok
}

function Stop-Stack([string]$Root) {
    # Only this app's processes: the start-*.ps1 loops and everything they
    # started (cmd -> python, nginx, redis-server), plus Nginx/Redis from runtime\.
    $p = Get-StackPaths $Root
    $all = @(Get-CimInstance Win32_Process)
    $ids = @($all | Where-Object {
            ($_.CommandLine -and $_.CommandLine -like "*$Root\scripts\start-*.ps1*") -or
            ($_.ExecutablePath -and $_.ExecutablePath -like "$($p.Runtime)\*")
        } | ForEach-Object { $_.ProcessId })
    $before = -1
    while ($ids.Count -ne $before) {
        $before = $ids.Count
        $ids = @($ids + @($all | Where-Object { $ids -contains $_.ParentProcessId -and $ids -notcontains $_.ProcessId } | ForEach-Object { $_.ProcessId }))
    }
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}
