#!/usr/bin/env bash
# Shoots every feature in a dark and a light window, frames the shots on
# gradients, and refreshes the README's pictures in docs/screenshots.
# Needs Python with Pillow, pngquant and macOS (for sips and its fonts).
# Usage: scripts/screenshots/shoot.sh [out dir, build/screenshots by default]
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "${1:-build/screenshots}"
out=$(cd "${1:-build/screenshots}" && pwd)
rm -rf "$out/raw" "$out/framed"
mkdir -p "$out/raw" docs/screenshots

FSHOTS="$out/raw" go test -count=1 -run '^TestFeat' ./cmd/mayoi
python3 scripts/screenshots/compose.py "$out/raw" "$out/framed"

# readme <shot> <name> puts a shot, 1600 pixels wide, in docs/screenshots.
readme() {
	sips -Z 1600 "$1" --out "docs/screenshots/$2.png" >/dev/null
	pngquant --force --quality 70-90 --ext .png "docs/screenshots/$2.png"
}
readme "$out/framed/01-hero-dark.png" hero
for shot in 12-columns-dark 07-change-peek-dark \
	08-scm-diff-split-dark 09-commits-dark 11-markdown-preview-dark \
	13-terminal-tab-dark 14-command-palette-dark 16-search-dark \
	17-project-tabs-dark 21-theme-matrix-editor; do
	name=${shot#??-}
	name=${name%-dark}
	name=${name%-editor}
	readme "$out/raw/$shot.png" "$name"
done
echo "Shots in $out, the README's in docs/screenshots"
