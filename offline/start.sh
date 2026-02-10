#!/bin/bash
# OpenCode Offline Mode Startup Script
#
# This script starts the OpenCode server in offline (air-gapped) mode.
# All external network requests are disabled.
#
# Usage:
#   ./start.sh                    # Start with defaults (0.0.0.0:4096)
#   ./start.sh --port 8080        # Custom port
#   ./start.sh --hostname 127.0.0.1  # Localhost only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export OPENCODE_OFFLINE=true
export OPENCODE_MODELS_PATH="${OPENCODE_MODELS_PATH:-${SCRIPT_DIR}/models.json}"

# Optional: Set a password for server authentication
# export OPENCODE_SERVER_PASSWORD=your-password

exec opencode serve --hostname 0.0.0.0 --port 4096 "$@"
