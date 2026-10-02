#!/usr/bin/env bash
# Rebuild the README diagrams and charts.
# Usage: docs/diagrams/build.sh
# charts.py draws all six from the figures in the README and the receipts.
# Needs: python3.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 -B "$HERE/charts.py"
