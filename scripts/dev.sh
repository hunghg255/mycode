#!/usr/bin/env bash
# Runs Mayoi Dev with live reload (go tool mygo dev) beside the everyday
# Mayoi. MyGo gives it the identifier dev.mayoi.editor.dev, so its own
# instance lock; MAYOI_DATA_DIR gives it its own settings and window state.
# Usage: scripts/dev.sh
# MAYOI_DATA_DIR picks another data folder (default: Mayoi-dev beside Mayoi's).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MAYOI_DATA_DIR="${MAYOI_DATA_DIR:-$HOME/Library/Application Support/Mayoi-dev}"

# MyGo creates its own data folder, but not one set with SetPath.
mkdir -p "$MAYOI_DATA_DIR"

echo "==> mygo dev (data in $MAYOI_DATA_DIR)"
cd "$ROOT"
exec go tool mygo dev
