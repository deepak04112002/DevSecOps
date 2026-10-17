#!/usr/bin/env bash
# tests/integration/run_all.sh
# Runs all integration tests with credentials pre-set.
set -Eeuo pipefail

export SONAR_TOKEN="sqa_d3bac814e1cff4153501a36569aea26c5ff35c82"
export DEFECTDOJO_API_TOKEN="0aef7d5887a4d2cb1cb1cc55a46e3e60bb300188"
export REDMINE_API_KEY="37d0dca6800005594a667ee4c5f1c2e58134aabd"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0

run() {
    local script="$1"
    echo ""
    if bash "$SCRIPT_DIR/$script"; then
        (( TOTAL_PASS++ )) || true
    else
        (( TOTAL_FAIL++ )) || true
    fi
}

run test_pipeline.sh
run test_sonarqube.sh
run test_defectdojo.sh
run test_redmine.sh

echo ""
echo "=== Overall: ${TOTAL_PASS} suites passed, ${TOTAL_FAIL} suites failed ==="
[[ "$TOTAL_FAIL" -eq 0 ]]
