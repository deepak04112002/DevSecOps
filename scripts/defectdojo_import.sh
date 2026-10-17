#!/usr/bin/env bash
# scripts/defectdojo_import.sh
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${DEFECTDOJO_PRODUCT_ID:?Set DEFECTDOJO_PRODUCT_ID}"
: "${DEFECTDOJO_ENGAGEMENT_ID:?Set DEFECTDOJO_ENGAGEMENT_ID}"
: "${DEFECTDOJO_SCAN_TYPE:?Set DEFECTDOJO_SCAN_TYPE}"
: "${DEFECTDOJO_SCAN_FILE:?Set DEFECTDOJO_SCAN_FILE}"

[[ -s "$DEFECTDOJO_SCAN_FILE" ]] || {
  echo "Scan file is missing or empty: $DEFECTDOJO_SCAN_FILE" >&2
  exit 1
}

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
TITLE="${DEFECTDOJO_TEST_TITLE:-CI security scan}"

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

http_code="$(
  curl --silent --show-error \
    --connect-timeout 15 --max-time 300 \
    --request POST \
    --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
    --form-string "scan_type=${DEFECTDOJO_SCAN_TYPE}" \
    --form-string "product=${DEFECTDOJO_PRODUCT_ID}" \
    --form-string "engagement=${DEFECTDOJO_ENGAGEMENT_ID}" \
    --form-string "active=true" \
    --form-string "verified=false" \
    --form-string "close_old_findings=false" \
    --form-string "minimum_severity=Info" \
    --form-string "test_title=${TITLE}" \
    --form "file=@${DEFECTDOJO_SCAN_FILE}" \
    --output "$response_file" \
    --write-out '%{http_code}' \
    "${DEFECTDOJO_URL}/api/v2/import-scan/"
)"

case "$http_code" in
  200|201|202)
    echo "DefectDojo accepted the scan import (HTTP $http_code)."
    if command -v jq >/dev/null 2>&1 && jq empty "$response_file" >/dev/null 2>&1; then
      jq '{test, scan_date, findings, message, detail}' "$response_file" 2>/dev/null || cat "$response_file"
    else
      cat "$response_file"
    fi
    ;;
  *)
    echo "DefectDojo import failed (HTTP $http_code):" >&2
    cat "$response_file" >&2
    exit 1
    ;;
esac
