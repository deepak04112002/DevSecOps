#!/usr/bin/env bash
# tests/integration/test_defectdojo.sh
# Verifies DefectDojo is reachable, the API token is valid, and the target
# product and engagement IDs exist.
set -Eeuo pipefail

: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
DEFECTDOJO_URL="${DEFECTDOJO_URL:-http://localhost:8081}"
DEFECTDOJO_PRODUCT_ID="${DEFECTDOJO_PRODUCT_ID:-1}"
DEFECTDOJO_ENGAGEMENT_ID="${DEFECTDOJO_ENGAGEMENT_ID:-1}"

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
PASS=0
FAIL=0

check_json() {
    local label="$1" url="$2" pattern="$3"
    local body code
    body="$(curl --silent --show-error --max-time 15 \
        --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
        --header "Accept: application/json" \
        --write-out '\n%{http_code}' \
        "$url")"
    code="$(tail -n1 <<< "$body")"
    body="$(head -n -1 <<< "$body")"

    if [[ "$code" =~ ^2 ]] && echo "$body" | grep -q "$pattern"; then
        echo "  PASS  $label"
        (( PASS++ )) || true
    else
        echo "  FAIL  $label — HTTP $code, pattern '$pattern' not found"
        (( FAIL++ )) || true
    fi
}

echo "=== DefectDojo Integration Tests ==="

# 1. API token is valid (user endpoint returns current user)
check_json "API token valid" \
    "${DEFECTDOJO_URL}/api/v2/users/?limit=1" \
    '"count":'

# 2. Product ID exists
check_json "Product ID ${DEFECTDOJO_PRODUCT_ID} exists" \
    "${DEFECTDOJO_URL}/api/v2/products/${DEFECTDOJO_PRODUCT_ID}/" \
    '"id":'

# 3. Engagement ID exists
check_json "Engagement ID ${DEFECTDOJO_ENGAGEMENT_ID} exists" \
    "${DEFECTDOJO_URL}/api/v2/engagements/${DEFECTDOJO_ENGAGEMENT_ID}/" \
    '"id":'

# 4. Import-scan endpoint is reachable (OPTIONS probe — no auth needed for method check)
echo "  Checking import-scan endpoint..."
code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 10 --request OPTIONS \
    "${DEFECTDOJO_URL}/api/v2/import-scan/")"
if [[ "$code" =~ ^(200|204|405)$ ]]; then
    echo "  PASS  import-scan endpoint reachable"
    (( PASS++ )) || true
else
    echo "  FAIL  import-scan endpoint returned HTTP $code"
    (( FAIL++ )) || true
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ "$FAIL" -eq 0 ]]
