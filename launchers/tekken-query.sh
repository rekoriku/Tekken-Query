#!/usr/bin/env bash
# Launch Tekken Query in interactive mode.
# Place this script in the same directory as tekken-cli and tekken_query.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/tekken-cli" -d "$SCRIPT_DIR/data" interactive "$@"
