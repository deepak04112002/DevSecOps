#!/usr/bin/env bash
# tests/integration/test_qualys.sh
# Validates Qualys API credentials and that the target report ID is accessible.
set -Eeuo pipefail

: "${QUALYS_USERNAME:?Set QUALYS_USERNAME}"
: "${QUALYS_PASSWORD:?Set QUALYS_PASSWORD}"
: "${QUALYS_REPORT_ID:?Set QUALYS_REPORT_ID}"
QUALYS_BASE_URL="${QUALYS_BASE_URL:-https://qualysapi.qualys.com}"

PASS=0
FAIL=0

echo "=== Qualys Integration Tests ==="

# 1. API connectivity — list reports endpoint
echo "  Checking Qualys API connectivity..."
code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 20 \
    --user "${QUALYS_USERNAME}:${QUALYS_PASSWORD}" \
    --header "X-Requested-With: DevSecOps-Pipeline" \
    --get \
    --data-urlencode "action=list" \
    "${QUALYS_BASE_URL}/api/2.0/fo/report/")"

if [[ "$code" == "200" ]]; then
    echo "  PASS  Qualys API reachable (HTTP $code)"
    (( PASS++ )) || true
else
    echo "  FAIL  Qualys API returned HTTP $code (check credentials and QUALYS_BASE_URL)"
    (( FAIL++ )) || true
fi

# 2. Target report ID is listed
echo "  Checking report ID ${QUALYS_REPORT_ID} exists..."
body="$(curl --silent --show-error --max-time 20 \
    --user "${QUALYS_USERNAME}:${QUALYS_PASSWORD}" \
    --header "X-Requested-With: DevSecOps-Pipeline" \
    --get \
    --data-urlencode "action=list" \
    "${QUALYS_BASE_URL}/api/2.0/fo/report/")"

if echo "$body" | grep -q "<ID>${QUALYS_REPORT_ID}</ID>"; then
    echo "  PASS  Report ID ${QUALYS_REPORT_ID} found"
    (( PASS++ )) || true
else
    echo "  FAIL  Report ID ${QUALYS_REPORT_ID} not found in report list"
    (( FAIL++ )) || true
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ "$FAIL" -eq 0 ]]
