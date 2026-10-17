#!/usr/bin/env bash
# scripts/qualys_export.sh
set -Eeuo pipefail
umask 077

: "${QUALYS_BASE_URL:?Set QUALYS_BASE_URL}"
: "${QUALYS_USERNAME:?Set QUALYS_USERNAME}"
: "${QUALYS_PASSWORD:?Set QUALYS_PASSWORD}"
: "${QUALYS_REPORT_ID:?Set QUALYS_REPORT_ID}"

OUT_DIR="${ARTIFACTS_DIR:-artifacts/qualys}"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/qualys-report.xml"

QUALYS_BASE_URL="${QUALYS_BASE_URL%/}"

http_code="$(
  curl --silent --show-error \
    --connect-timeout 15 --max-time 300 \
    --user "${QUALYS_USERNAME}:${QUALYS_PASSWORD}" \
    --header "X-Requested-With: DevSecOps-Pipeline" \
    --get \
    --data-urlencode "action=fetch" \
    --data-urlencode "id=${QUALYS_REPORT_ID}" \
    --output "$OUT_FILE" \
    --write-out '%{http_code}' \
    "${QUALYS_BASE_URL}/api/2.0/fo/report/"
)"

if [[ "$http_code" != "200" ]]; then
  echo "Qualys report export failed (HTTP $http_code)." >&2
  rm -f "$OUT_FILE"
  exit 1
fi

if [[ ! -s "$OUT_FILE" ]]; then
  echo "Qualys returned an empty report." >&2
  exit 1
fi

if grep -Eiq '<(html|!DOCTYPE html)' "$OUT_FILE"; then
  echo "Qualys returned HTML, not a report file. Check the API response." >&2
  rm -f "$OUT_FILE"
  exit 1
fi

echo "Qualys report saved to: $OUT_FILE"
