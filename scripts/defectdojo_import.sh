#!/usr/bin/env bash
# scripts/defectdojo_import.sh
#
# Imports one scan into DefectDojo. Works for the first run (creates a test)
# and for later runs (reimports into the same test).
#
# Choosing the target test:
#   DEFECTDOJO_TEST_ID is set   -> use that test. It must exist and have the
#                                  requested scan type, or the script fails.
#   otherwise                   -> use the oldest test in the engagement with
#                                  the same title and scan type.
#   no test found               -> create one with import-scan.
#
# When a test is known, the scan goes to reimport-scan with test=<id>, so the
# existing test is updated and no new test is created. Set
# REQUIRE_DEFECTDOJO_TEST_ID=true to fail instead of creating a test.
#
# Required environment:
#   DEFECTDOJO_URL, DEFECTDOJO_API_TOKEN, DEFECTDOJO_ENGAGEMENT_ID,
#   DEFECTDOJO_SCAN_TYPE, DEFECTDOJO_SCAN_FILE, DEFECTDOJO_TEST_TITLE
#
# Optional environment:
#   DEFECTDOJO_TEST_ID              pin the stage to one test
#   REQUIRE_DEFECTDOJO_TEST_ID      true | false              default: false
#   DEFECTDOJO_POLL_INTERVAL_SECONDS                          default: 5
#   DEFECTDOJO_POLL_TIMEOUT_SECONDS                           default: 1800
# ---------------------------------------------------------------------------
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${DEFECTDOJO_ENGAGEMENT_ID:?Set DEFECTDOJO_ENGAGEMENT_ID}"
: "${DEFECTDOJO_SCAN_TYPE:?Set DEFECTDOJO_SCAN_TYPE}"
: "${DEFECTDOJO_SCAN_FILE:?Set DEFECTDOJO_SCAN_FILE}"
: "${DEFECTDOJO_TEST_TITLE:?Set DEFECTDOJO_TEST_TITLE}"

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
POLL_INTERVAL_SECONDS="${DEFECTDOJO_POLL_INTERVAL_SECONDS:-5}"
POLL_TIMEOUT_SECONDS="${DEFECTDOJO_POLL_TIMEOUT_SECONDS:-1800}"
REQUIRE_TEST_ID="${REQUIRE_DEFECTDOJO_TEST_ID:-false}"
PINNED_TEST_ID="${DEFECTDOJO_TEST_ID:-}"
TITLE="$DEFECTDOJO_TEST_TITLE"

TEST_ID=""          # test to reimport into; empty means create one
RESULT_TEST_ID=""   # test that DefectDojo reports it imported into

log() { printf '[defectdojo] %s\n' "$*"; }
die() { printf '[defectdojo] ERROR: %s\n' "$*" >&2; exit 1; }
is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

command -v curl >/dev/null 2>&1 || die "curl is required."
command -v jq   >/dev/null 2>&1 || die "jq is required."

is_pos_int "$DEFECTDOJO_ENGAGEMENT_ID" || die "DEFECTDOJO_ENGAGEMENT_ID must be a positive integer."
is_pos_int "$POLL_INTERVAL_SECONDS"    || die "DEFECTDOJO_POLL_INTERVAL_SECONDS must be a positive integer."
is_pos_int "$POLL_TIMEOUT_SECONDS"     || die "DEFECTDOJO_POLL_TIMEOUT_SECONDS must be a positive integer."

case "$REQUIRE_TEST_ID" in
    true|false) ;;
    *) die "REQUIRE_DEFECTDOJO_TEST_ID must be 'true' or 'false'." ;;
esac

if [[ -n "$PINNED_TEST_ID" ]]; then
    is_pos_int "$PINNED_TEST_ID" || die "DEFECTDOJO_TEST_ID must be a positive integer."
fi

if [[ "$REQUIRE_TEST_ID" == "true" && -z "$PINNED_TEST_ID" ]]; then
    die "REQUIRE_DEFECTDOJO_TEST_ID=true requires DEFECTDOJO_TEST_ID."
fi

[[ -s "$DEFECTDOJO_SCAN_FILE" ]] || die "Scan file is missing or empty: $DEFECTDOJO_SCAN_FILE"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# api_get <path> <output-file> [extra curl args]
# Prints the HTTP status code.
api_get() {
    local path="$1" out="$2"
    shift 2
    curl --silent --show-error \
        --connect-timeout 15 --max-time 60 \
        --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
        --header "Accept: application/json" \
        --output "$out" \
        --write-out '%{http_code}' \
        "$@" \
        "${DEFECTDOJO_URL}${path}"
}

# ---- 1. Choose the target test ---------------------------------------------
resolve_test() {
    local code

    if [[ -n "$PINNED_TEST_ID" ]]; then
        code="$(api_get "/api/v2/tests/${PINNED_TEST_ID}/" "$tmpdir/pinned.json")" \
            || die "Could not reach DefectDojo."

        case "$code" in
            200) ;;
            404) die "DEFECTDOJO_TEST_ID=${PINNED_TEST_ID} does not exist. Fix the pin; not creating a new test." ;;
            *)   die "Reading test ${PINNED_TEST_ID} returned HTTP ${code}." ;;
        esac

        local actual_type actual_title
        actual_type="$(jq -r '.scan_type // empty' "$tmpdir/pinned.json")"
        actual_title="$(jq -r '.title // .test_title // "untitled"' "$tmpdir/pinned.json")"

        [[ "$actual_type" == "$DEFECTDOJO_SCAN_TYPE" ]] ||
            die "Test ${PINNED_TEST_ID} has scan type '${actual_type}', expected '${DEFECTDOJO_SCAN_TYPE}'."

        log "Pinned test ${PINNED_TEST_ID} ('${actual_title}', ${actual_type})."
        TEST_ID="$PINNED_TEST_ID"
        return
    fi

    code="$(api_get "/api/v2/tests/" "$tmpdir/tests.json" \
        --get \
        --data-urlencode "engagement=${DEFECTDOJO_ENGAGEMENT_ID}" \
        --data-urlencode "limit=500")" || die "Could not list DefectDojo tests."

    [[ "$code" == "200" ]] || die "Listing tests returned HTTP ${code}."
    jq -e '.results | type == "array"' "$tmpdir/tests.json" >/dev/null ||
        die "Unexpected response while listing tests."

    # Oldest test with the same title and scan type. The v2 API returns
    # "title"; accept "test_title" as well.
    TEST_ID="$(
        jq -r --arg title "$TITLE" --arg scan_type "$DEFECTDOJO_SCAN_TYPE" '
            [ .results[]
              | select(((.title // .test_title) == $title) and (.scan_type == $scan_type)) ]
            | sort_by(.id)
            | first
            | .id // empty
        ' "$tmpdir/tests.json"
    )"

    if [[ -n "$TEST_ID" ]]; then
        log "Found existing test '${TITLE}' (ID ${TEST_ID})."
    else
        log "No test titled '${TITLE}' with scan type '${DEFECTDOJO_SCAN_TYPE}' in this engagement."
    fi
}

# ---- 2. Submit the scan -----------------------------------------------------
submit_scan() {
    local endpoint code
    local -a common target

    common=(
        --form-string "scan_type=${DEFECTDOJO_SCAN_TYPE}"
        --form-string "close_old_findings=true"
        --form-string "minimum_severity=Info"
        --form-string "deduplication_execution_mode=async_wait"
        --form "file=@${DEFECTDOJO_SCAN_FILE}"
    )

    if [[ -n "$TEST_ID" ]]; then
        endpoint="reimport-scan"
        target=(--form-string "test=${TEST_ID}")
        log "Endpoint: reimport-scan (test ${TEST_ID})"
    else
        endpoint="import-scan"
        target=(
            --form-string "engagement=${DEFECTDOJO_ENGAGEMENT_ID}"
            --form-string "test_title=${TITLE}"
        )
        log "Endpoint: import-scan (new test '${TITLE}')"
    fi

    code="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 300 \
            --request POST \
            --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
            --header "Accept: application/json" \
            "${common[@]}" \
            "${target[@]}" \
            --output "$tmpdir/response.json" \
            --write-out '%{http_code}' \
            "${DEFECTDOJO_URL}/api/v2/${endpoint}/"
    )" || {
        [[ ! -s "$tmpdir/response.json" ]] || cat "$tmpdir/response.json" >&2
        die "DefectDojo request failed at the transport level."
    }

    case "$code" in
        200|201|202) ;;
        *)
            cat "$tmpdir/response.json" >&2
            die "DefectDojo ${endpoint} failed (HTTP ${code})."
            ;;
    esac

    jq -e 'type == "object"' "$tmpdir/response.json" >/dev/null ||
        die "DefectDojo returned a non-JSON response."

    RESULT_TEST_ID="$(jq -r '.test_id // empty' "$tmpdir/response.json")"
    [[ "$RESULT_TEST_ID" =~ ^[1-9][0-9]*$ ]] ||
        die "DefectDojo response has no valid test_id."

    if [[ -n "$TEST_ID" && "$RESULT_TEST_ID" != "$TEST_ID" ]]; then
        die "Import went to test ${RESULT_TEST_ID}, expected ${TEST_ID}. Stopping."
    fi
}

# ---- 3. Wait for processing ---------------------------------------------------
wait_for_import() {
    local deadline status processing code
    deadline=$(( $(date +%s) + POLL_TIMEOUT_SECONDS ))

    while :; do
        code="$(api_get "/api/v2/tests/${RESULT_TEST_ID}/" "$tmpdir/status.json")" \
            || die "Could not poll test ${RESULT_TEST_ID}."

        [[ "$code" == "200" ]] || {
            cat "$tmpdir/status.json" >&2
            die "Test status request returned HTTP ${code}."
        }

        status="$(jq -r '.status // empty' "$tmpdir/status.json")"
        processing="$(jq -r '.processing // false' "$tmpdir/status.json")"

        case "$status" in
            Processed)
                if [[ "$processing" != "true" ]]; then
                    log "Background import completed."
                    return
                fi
                log "Still processing; waiting..."
                ;;
            Failed)
                jq . "$tmpdir/status.json" >&2
                die "DefectDojo reports that test ${RESULT_TEST_ID} failed."
                ;;
            *)
                log "Status: ${status:-unknown}; waiting..."
                ;;
        esac

        (( $(date +%s) < deadline )) || die "Timed out waiting for test ${RESULT_TEST_ID}."
        sleep "$POLL_INTERVAL_SECONDS"
    done
}

# ---- Run ----------------------------------------------------------------------
echo "Scan type:  ${DEFECTDOJO_SCAN_TYPE}"
echo "Test title: ${TITLE}"

resolve_test
submit_scan

if [[ "$(jq -r '.background_import // false' "$tmpdir/response.json")" == "true" ]]; then
    wait_for_import
else
    jq -e '.deduplication_complete == true' "$tmpdir/response.json" >/dev/null ||
        die "Import returned, but deduplication was not confirmed."
    log "Import and deduplication completed."
fi

jq '{test, test_id, statistics}' "$tmpdir/response.json"
log "Test ID used: ${RESULT_TEST_ID}"

if [[ -z "$PINNED_TEST_ID" ]]; then
    log "To lock this stage to the same test, set DEFECTDOJO_TEST_ID=${RESULT_TEST_ID}."
fi
log "Done."