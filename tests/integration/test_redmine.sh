#!/usr/bin/env bash
# tests/integration/test_redmine.sh
# Verifies Redmine is reachable, the API key is valid, the target project
# exists, and issue creation + deletion works end-to-end.
set -Eeuo pipefail

: "${REDMINE_API_KEY:?Set REDMINE_API_KEY}"
REDMINE_URL="${REDMINE_URL:-http://localhost:3000}"
REDMINE_PROJECT_ID="${REDMINE_PROJECT_ID:-1}"
REDMINE_TRACKER_ID="${REDMINE_TRACKER_ID:-1}"

REDMINE_URL="${REDMINE_URL%/}"
PASS=0
FAIL=0
CREATED_ISSUE_ID=""

cleanup() {
    if [[ -n "$CREATED_ISSUE_ID" ]]; then
        curl --silent --output /dev/null \
            --request DELETE \
            --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
            "${REDMINE_URL}/issues/${CREATED_ISSUE_ID}.json" || true
        echo "  (cleaned up test issue #${CREATED_ISSUE_ID})"
    fi
}
trap cleanup EXIT

echo "=== Redmine Integration Tests ==="

# 1. API key is valid
echo "  Checking API key..."
code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 10 \
    --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
    "${REDMINE_URL}/users/current.json")"
if [[ "$code" == "200" ]]; then
    echo "  PASS  API key valid"
    (( PASS++ )) || true
else
    echo "  FAIL  API key check returned HTTP $code"
    (( FAIL++ )) || true
fi

# 2. Project exists
echo "  Checking project ID ${REDMINE_PROJECT_ID}..."
code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 10 \
    --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
    "${REDMINE_URL}/projects/${REDMINE_PROJECT_ID}.json")"
if [[ "$code" == "200" ]]; then
    echo "  PASS  Project ${REDMINE_PROJECT_ID} exists"
    (( PASS++ )) || true
else
    echo "  FAIL  Project ${REDMINE_PROJECT_ID} returned HTTP $code"
    (( FAIL++ )) || true
fi

# 3. Issue creation round-trip
echo "  Testing issue creation..."
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"; cleanup' EXIT

cat > "$tmpfile" <<EOF
{
  "issue": {
    "project_id": "${REDMINE_PROJECT_ID}",
    "tracker_id": ${REDMINE_TRACKER_ID},
    "subject": "[integration-test] DevSecOps pipeline test issue — safe to delete",
    "description": "Created by tests/integration/test_redmine.sh. Will be deleted automatically."
  }
}
EOF

response="$(curl --silent --show-error --max-time 15 \
    --request POST \
    --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
    --header "Content-Type: application/json" \
    --data @"$tmpfile" \
    --write-out '\n%{http_code}' \
    "${REDMINE_URL}/issues.json")"

code="$(tail -n1 <<< "$response")"
body="$(head -n -1 <<< "$response")"

if [[ "$code" == "201" ]]; then
    CREATED_ISSUE_ID="$(echo "$body" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)"
    echo "  PASS  Issue created (ID: ${CREATED_ISSUE_ID})"
    (( PASS++ )) || true
else
    echo "  FAIL  Issue creation returned HTTP $code"
    (( FAIL++ )) || true
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ "$FAIL" -eq 0 ]]
