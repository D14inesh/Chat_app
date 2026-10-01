# Update the server to the latest code on GitHub and restart the app.
# Run in PowerShell **as Administrator** from the chat-application folder:
#
#   powershell -ExecutionPolicy Bypass -File scripts\update-server.ps1
#
# Any extra arguments are passed on to setup-server.ps1 (e.g. custom ports).
# Your .env, certificates and uploaded files are not touched by git.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "`n== Download the latest code from GitHub" -ForegroundColor Cyan
git pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'git pull failed - see the message above.' }

# setup-server.ps1 is safe to re-run: it stops the app, installs any new
# packages, adds any new database tables, and starts the app again.
& (Join-Path $PSScriptRoot 'setup-server.ps1') @args
