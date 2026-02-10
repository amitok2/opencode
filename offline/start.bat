@echo off
REM OpenCode Offline Mode Startup Script (Windows)
REM
REM This script starts the OpenCode server in offline (air-gapped) mode.
REM All external network requests are disabled.
REM
REM Usage:
REM   start.bat                         Start with defaults (0.0.0.0:4096)
REM   start.bat --port 8080             Custom port
REM   start.bat --hostname 127.0.0.1    Localhost only

set OPENCODE_OFFLINE=true

REM Use OPENCODE_MODELS_PATH if already set, otherwise use models.json next to this script
if "%OPENCODE_MODELS_PATH%"=="" set OPENCODE_MODELS_PATH=%~dp0models.json

REM Optional: Set a password for server authentication
REM set OPENCODE_SERVER_PASSWORD=your-password

opencode.exe serve --hostname 0.0.0.0 --port 4096 %*
