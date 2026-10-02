#!/usr/bin/env bash
# Rebuild the README diagrams.
# Usage: docs/diagrams/build.sh
# Archify specs in src/ become <name>-light.svg and <name>-dark.svg.
# charts.py draws the four charts from the figures in the receipts.
# Needs: node, python3, Chrome, the Archify skill, and the Quoin token file and skin.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARCHIFY="${ARCHIFY:-$HOME/.claude/skills/archify/bin/archify.mjs}"
QUOIN="${QUOIN:-$HOME/Documents/promptkits/quoin}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for spec in "$HERE"/src/*.json; do
  base="$(basename "$spec" .json)"; name="${base%%.*}"; type="${base##*.}"
  node "$ARCHIFY" deliver "$type" "$spec" "$TMP/$name.html" --quality showcase --json >"$TMP/$name.receipt.json"
  python3 "$QUOIN/archify-skin.py" "$TMP/$name.html" "$QUOIN/tokens.json" classic "$TMP/$name-skin.html" >/dev/null
  for theme in light dark; do
    python3 "$HERE/export_svg.py" "$TMP/$name-skin.html" "$theme" "$HERE/$name-$theme.svg"
  done
done
python3 "$HERE/charts.py"
