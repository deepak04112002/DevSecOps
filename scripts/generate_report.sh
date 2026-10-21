#!/usr/bin/env bash
# scripts/generate_report.sh
# Thin wrapper. Report logic lives in generate_report.py.
set -Eeuo pipefail

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required." >&2; exit 1; }

exec python3 "$(dirname "$0")/generate_report.py"