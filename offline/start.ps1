# OpenCode Offline Mode Startup Script (PowerShell)
#
# This script starts the OpenCode server in offline (air-gapped) mode.
# All external network requests are disabled.
#
# Usage:
#   .\start.ps1                         # Start with defaults (0.0.0.0:4096)
#   .\start.ps1 --port 8080             # Custom port
#   .\start.ps1 --hostname 127.0.0.1    # Localhost only

$env:OPENCODE_OFFLINE = "true"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $env:OPENCODE_MODELS_PATH) {
    $env:OPENCODE_MODELS_PATH = Join-Path $ScriptDir "models.json"
}

# Optional: Set a password for server authentication
# $env:OPENCODE_SERVER_PASSWORD = "your-password"

& "$ScriptDir\opencode.exe" serve --hostname 0.0.0.0 --port 4096 @args
