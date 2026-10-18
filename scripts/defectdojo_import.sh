#!/usr/bin/env bash
# scripts/defectdojo_import.sh
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${DEFECTDOJO_PRODUCT_NAME:?Set DEFECTDOJO_PRODUCT_NAME}"
: "${DEFECTDOJO_ENGAGEMENT_NAME:?Set DEFECTDOJO_ENGAGEMENT_NAME}"
: "${DEFECTDOJO_SCAN_TYPE:?Set DEFECTDOJO_SCAN_TYPE}"
: "${DEFECTDOJO_SCAN_FILE:?Set DEFECTDOJO_SCAN_FILE}"

POLL_INTERVAL_SECONDS="${DEFECTDOJO_POLL_INTERVAL_SECONDS:-5}"
POLL_TIMEOUT_SECONDS="${DEFECTDOJO_POLL_TIMEOUT_SECONDS:-1800}"

command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl is required." >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required." >&2
    exit 1
}

for name in POLL_INTERVAL_SECONDS POLL_TIMEOUT_SECONDS; do
    value="${!name}"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $name must be a positive integer." >&2
        exit 1
    fi
done

[[ -n "$DEFECTDOJO_PRODUCT_NAME" ]] || {
    echo "ERROR: DEFECTDOJO_PRODUCT_NAME is empty." >&2
    exit 1
}

[[ -n "$DEFECTDOJO_ENGAGEMENT_NAME" ]] || {
    echo "ERROR: DEFECTDOJO_ENGAGEMENT_NAME is empty." >&2
    exit 1
}

[[ -f "$DEFECTDOJO_SCAN_FILE" && -s "$DEFECTDOJO_SCAN_FILE" ]] || {
    echo "ERROR: Scan file is missing, not a regular file, or empty." >&2
    exit 1
}

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
TITLE="${DEFECTDOJO_TEST_TITLE:-CI security scan}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

response_file="$tmpdir/response.json"
test_file="$tmpdir/test.json"

echo "Importing scan into DefectDojo..."
echo "Scan type: $DEFECTDOJO_SCAN_TYPE"
echo "Product: $DEFECTDOJO_PRODUCT_NAME"
echo "Engagement: $DEFECTDOJO_ENGAGEMENT_NAME"
echo "Test title: $TITLE"

if ! http_code="$(
    curl --silent --show-error \
        --connect-timeout 15 \
        --max-time 300 \
        --request POST \
        --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
        --header "Accept: application/json" \
        --form-string "scan_type=${DEFECTDOJO_SCAN_TYPE}" \
        --form-string "product_name=${DEFECTDOJO_PRODUCT_NAME}" \
        --form-string "engagement_name=${DEFECTDOJO_ENGAGEMENT_NAME}" \
        --form-string "close_old_findings=false" \
        --form-string "minimum_severity=Info" \
        --form-string "deduplication_execution_mode=async_wait" \
        --form-string "test_title=${TITLE}" \
        --form "file=@${DEFECTDOJO_SCAN_FILE}" \
        --output "$response_file" \
        --write-out '%{http_code}' \
        "${DEFECTDOJO_URL}/api/v2/reimport-scan/"
)"; then
    echo "ERROR: DefectDojo API request failed at the transport level." >&2
    if [[ -s "$response_file" ]]; then
        cat "$response_file" >&2
    fi
    exit 1
fi

case "$http_code" in
    200|201|202)
        ;;
    *)
        echo "ERROR: DefectDojo import failed (HTTP $http_code)." >&2
        cat "$response_file" >&2
        exit 1
        ;;
esac

jq -e 'type == "object"' "$response_file" >/dev/null 2>&1 || {
    echo "ERROR: DefectDojo returned a non-JSON or unexpected response." >&2
    cat "$response_file" >&2
    exit 1
}

background_import="$(jq -r '.background_import // false' "$response_file")"

if [[ "$background_import" == "true" ]]; then
    test_id="$(jq -r '.test_id // empty' "$response_file")"

    if [[ ! "$test_id" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Background import response has no valid test_id." >&2
        jq . "$response_file" >&2
        exit 1
    fi

    echo "Background import accepted for test ${test_id}; waiting for completion..."
    deadline=$(( $(date +%s) + POLL_TIMEOUT_SECONDS ))

    while :; do
        if ! poll_code="$(
            curl --silent --show-error \
                --connect-timeout 15 \
                --max-time 60 \
                --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
                --header "Accept: application/json" \
                --output "$test_file" \
                --write-out '%{http_code}' \
                "${DEFECTDOJO_URL}/api/v2/tests/${test_id}/"
        )"; then
            echo "ERROR: Failed to poll DefectDojo test ${test_id}." >&2
            exit 1
        fi

        if [[ "$poll_code" != "200" ]]; then
            echo "ERROR: Test status request returned HTTP ${poll_code}." >&2
            [[ ! -s "$test_file" ]] || cat "$test_file" >&2
            exit 1
        fi

        jq -e 'type == "object"' "$test_file" >/dev/null 2>&1 || {
            echo "ERROR: Invalid DefectDojo test-status response." >&2
            cat "$test_file" >&2
            exit 1
        }

        status="$(jq -r '.status // empty' "$test_file")"
        processing="$(jq -r '.processing // false' "$test_file")"

        case "$status" in
            Processed)
                if [[ "$processing" == "true" ]]; then
                    echo "Test reports Processed but is still marked processing; continuing to poll."
                else
                    echo "DefectDojo background import completed."
                    break
                fi
                ;;
            Failed)
                echo "ERROR: DefectDojo reports that test ${test_id} failed." >&2
                jq . "$test_file" >&2
                exit 1
                ;;
            *)
                echo "DefectDojo test status: ${status:-unknown}; waiting..."
                ;;
        esac

        if (( $(date +%s) >= deadline )); then
            echo "ERROR: Timed out waiting for DefectDojo test ${test_id}." >&2
            jq . "$test_file" >&2
            exit 1
        fi

        sleep "$POLL_INTERVAL_SECONDS"
    done

    echo "DefectDojo response summary:"
    jq '{test_id, status, processing}' "$test_file"
else
    if ! jq -e '.deduplication_complete == true' \
        "$response_file" >/dev/null 2>&1; then
        echo "ERROR: Import returned, but deduplication completion was not confirmed." >&2
        jq . "$response_file" >&2
        exit 1
    fi

    echo "DefectDojo import and deduplication completed."

    jq '{
        test,
        test_id,
        scan_date,
        findings,
        statistics,
        deduplication_complete,
        message,
        detail
    }' "$response_file"
fi

echo "DefectDojo import stage completed successfully."