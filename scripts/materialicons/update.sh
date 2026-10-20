#!/usr/bin/env bash
# Regenerates icons/material (the SVGs and the manifest of the
# Material Icon Theme, as VS Code maps them) from the theme's sources.
# Needs git, Node.js and npm; then run python icons/update.py.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(cd "$here/../.." && pwd)/icons/material"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone --depth 1 https://github.com/material-extensions/vscode-material-icon-theme "$tmp/mit"
cd "$tmp/mit"
npm install --ignore-scripts --no-audit --no-fund
npx tsx ./src/scripts/svg/generateOpenFolderIcons.ts
npx tsx ./src/scripts/icons/generateClones.ts
cp "$here/export.ts" ./export.ts
OUT="$out" npx tsx export.ts
