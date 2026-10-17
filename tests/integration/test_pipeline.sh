#!/usr/bin/env bash
# tests/integration/test_pipeline.sh
# Verifies every service the pipeline depends on is reachable before a run.
set -Eeuo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
SONAR_URL="${SONAR_URL:-http://localhost:9000}"
DEFECTDOJO_URL="${DEFECTDOJO_URL:-http://localhost:8081}"
REDMINE_URL="${REDMINE_URL:-http://localhost:3000}"

PASS=0
FAIL=0

check() {
    local label="$1" url="$2" expected="${3:-200}"
    local code
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 10 "$url")"
    if [[ "$code" == "$expected" || "$code" == 2* ]]; then
        echo "  PASS  $label ($code)"
        (( PASS++ )) || true
    else
        echo "  FAIL  $label — expected ~2xx, got $code"
        (( FAIL++ )) || true
    fi
}

echo "=== Pipeline Integration Pre-flight ==="

check "Jenkins UI"              "${JENKINS_URL}/" "403"
check "Jenkins login page"      "${JENKINS_URL}/login"
check "SonarQube status"        "${SONAR_URL}/api/system/status"
check "DefectDojo API"          "${DEFECTDOJO_URL}/api/v2/users/" "403"
check "Redmine UI"              "${REDMINE_URL}/"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ "$FAIL" -eq 0 ]]
