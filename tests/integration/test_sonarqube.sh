#!/usr/bin/env bash
# tests/integration/test_sonarqube.sh
# Verifies SonarQube is healthy and the configured project key is reachable.
set -Eeuo pipefail

: "${SONAR_TOKEN:?Set SONAR_TOKEN}"
SONAR_URL="${SONAR_URL:-http://localhost:9000}"
SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY:-external-app}"

PASS=0
FAIL=0

check_http() {
    local label="$1" url="$2" expected_pattern="$3"
    local body code
    body="$(curl --silent --show-error --max-time 15 \
        --user "${SONAR_TOKEN}:" \
        --write-out '\n%{http_code}' \
        "$url")"
    code="$(tail -n1 <<< "$body")"
    body="$(head -n -1 <<< "$body")"

    if [[ "$code" =~ ^2 ]]; then
        if echo "$body" | grep -q "$expected_pattern"; then
            echo "  PASS  $label"
            (( PASS++ )) || true
        else
            echo "  FAIL  $label — pattern '$expected_pattern' not found in response"
            (( FAIL++ )) || true
        fi
    else
        echo "  FAIL  $label — HTTP $code"
        (( FAIL++ )) || true
    fi
}

echo "=== SonarQube Integration Tests ==="

# 1. System health
check_http "System status is UP" \
    "${SONAR_URL}/api/system/status" \
    '"status":"UP"'

# 2. Authentication works
check_http "Token authentication" \
    "${SONAR_URL}/api/authentication/validate" \
    '"valid":true'

# 3. Project exists
check_http "Project key exists: ${SONAR_PROJECT_KEY}" \
    "${SONAR_URL}/api/projects/search?projects=${SONAR_PROJECT_KEY}" \
    "\"key\":\"${SONAR_PROJECT_KEY}\""

# 4. Quality gate is assigned
check_http "Quality gate assigned to project" \
    "${SONAR_URL}/api/qualitygates/get_by_project?project=${SONAR_PROJECT_KEY}" \
    '"name":'

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ "$FAIL" -eq 0 ]]
