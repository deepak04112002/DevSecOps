
#!/usr/bin/env bash
# scripts/defectdojo_import.sh
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${DEFECTDOJO_PRODUCT_NAME:?Set DEFECTDOJO_PRODUCT_NAME}"
: "${DEFECTDOJO_ENGAGEMENT_NAME:?Set DEFECTDOJO_ENGAGEMENT_NAME}"
: "${DEFECTDOJO_ENGAGEMENT_ID:?Set DEFECTDOJO_ENGAGEMENT_ID}"
: "${DEFECTDOJO_SCAN_TYPE:?Set DEFECTDOJO_SCAN_TYPE}"
: "${DEFECTDOJO_SCAN_FILE:?Set DEFECTDOJO_SCAN_FILE}"

POLL_INTERVAL_SECONDS="${DEFECTDOJO_POLL_INTERVAL_SECONDS:-5}"
POLL_TIMEOUT_SECONDS="${DEFECTDOJO_POLL_TIMEOUT_SECONDS:-1800}"
TITLE="${DEFECTDOJO_TEST_TITLE:-CI security scan}"

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

[[ "$DEFECTDOJO_ENGAGEMENT_ID" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: DEFECTDOJO_ENGAGEMENT_ID must be a positive integer." >&2
    exit 1
}

[[ -n "$DEFECTDOJO_PRODUCT_NAME" && -n "$DEFECTDOJO_ENGAGEMENT_NAME" ]] || {
    echo "ERROR: Product and engagement names must not be empty." >&2
    exit 1
}

[[ -n "$TITLE" && -n "$DEFECTDOJO_SCAN_TYPE" ]] || {
    echo "ERROR: Test title and scan type must not be empty." >&2
    exit 1
}

[[ -f "$DEFECTDOJO_SCAN_FILE" && -s "$DEFECTDOJO_SCAN_FILE" ]] || {
    echo "ERROR: Scan file is missing, not a regular file, or empty." >&2
    exit 1
}

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

response_file="$tmpdir/response.json"
tests_file="$tmpdir/tests.json"
test_file="$tmpdir/test.json"

echo "Checking existing DefectDojo tests..."
echo "Product: $DEFECTDOJO_PRODUCT_NAME"
echo "Engagement: $DEFECTDOJO_ENGAGEMENT_NAME (ID $DEFECTDOJO_ENGAGEMENT_ID)"
echo "Requested title: $TITLE"
echo "Scan type: $DEFECTDOJO_SCAN_TYPE"

# Fetch tests belonging to this engagement.
if ! http_code="$(
    curl --silent --show-error \
        --connect-timeout 15 \
        --max-time 60 \
        --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
        --header "Accept: application/json" \
        --get \
        --data-urlencode "engagement=${DEFECTDOJO_ENGAGEMENT_ID}" \
        --data-urlencode "limit=200" \
        --output "$tests_file" \
        --write-out '%{http_code}' \
        "${DEFECTDOJO_URL}/api/v2/tests/"
)"; then
    echo "ERROR: Could not retrieve DefectDojo tests." >&2
    exit 1
fi

if [[ "$http_code" != "200" ]]; then
    echo "ERROR: Listing DefectDojo tests returned HTTP $http_code." >&2
    cat "$tests_file" >&2
    exit 1
fi

jq -e '.results | type == "array"' "$tests_file" >/dev/null 2>&1 || {
    echo "ERROR: Unexpected response while listing DefectDojo tests." >&2
    cat "$tests_file" >&2
    exit 1
}

# Prefer an exact title and scan-type match.
test_id="$(
    jq -r \
        --arg title "$TITLE" \
        --arg scan_type "$DEFECTDOJO_SCAN_TYPE" \
        '[
            .results[]
            | select(
                .test_title == $title
                and .scan_type == $scan_type
            )
        ]
        | sort_by(.id)
        | last
        | .id // empty' "$tests_file"
)"

if [[ "$test_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "Found an existing matching test: ID $test_id."
    endpoint="reimport-scan"
else
    # Legacy tests may have a different title, such as "CI security scan".
    # Reuse the newest test of the same scan type rather than creating
    # another test unnecessarily. If the legacy test cannot be safely
    # reused (missing/invalid id or empty title), fall back to a fresh
    # import-scan with the requested title instead of aborting -- a
    # duplicate test is preferable to losing the findings and skipping
    # the rest of the pipeline (SonarQube import, Redmine sync).
    existing_test="$(
        jq -c \
            --arg scan_type "$DEFECTDOJO_SCAN_TYPE" \
            '[
                .results[]
                | select(.scan_type == $scan_type)
            ]
            | sort_by(.id)
            | last // empty' "$tests_file"
    )"

    if [[ -n "$existing_test" ]]; then
        test_id="$(jq -r '.id // empty' <<< "$existing_test")"
        existing_title="$(jq -r '.test_title // empty' <<< "$existing_test")"

        if [[ "$test_id" =~ ^[1-9][0-9]*$ && -n "$existing_title" ]]; then
            echo "No exact title match; reusing existing test ID $test_id."
            echo "Using existing title: $existing_title"
            TITLE="$existing_title"
            endpoint="reimport-scan"
        else
            echo "WARNING: Existing test for scan type '$DEFECTDOJO_SCAN_TYPE'" >&2
            echo "WARNING: has an invalid id ('$test_id') or empty title and" >&2
            echo "WARNING: cannot be safely reused. Falling back to a fresh" >&2
            echo "WARNING: import-scan with title '$TITLE'." >&2
            endpoint="import-scan"
        fi
    else
        echo "No existing test for this scan type was found."
        echo "Creating the first test in engagement $DEFECTDOJO_ENGAGEMENT_ID."
        endpoint="import-scan"
    fi
fi

echo "Import endpoint: $endpoint"
echo "Test title: $TITLE"

# Submit the scan. import-scan creates a test; reimport-scan updates one.
if [[ "$endpoint" == "reimport-scan" ]]; then
    request_url="${DEFECTDOJO_URL}/api/v2/reimport-scan/"
else
    request_url="${DEFECTDOJO_URL}/api/v2/import-scan/"
fi

if ! http_code="$(
    if [[ "$endpoint" == "reimport-scan" ]]; then
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
            "$request_url"
    else
        curl --silent --show-error \
            --connect-timeout 15 \
            --max-time 300 \
            --request POST \
            --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
            --header "Accept: application/json" \
            --form-string "scan_type=${DEFECTDOJO_SCAN_TYPE}" \
            --form-string "engagement=${DEFECTDOJO_ENGAGEMENT_ID}" \
            --form-string "close_old_findings=false" \
            --form-string "minimum_severity=Info" \
            --form-string "deduplication_execution_mode=async_wait" \
            --form-string "test_title=${TITLE}" \
            --form "file=@${DEFECTDOJO_SCAN_FILE}" \
            --output "$response_file" \
            --write-out '%{http_code}' \
            "$request_url"
    fi
)"; then
    echo "ERROR: DefectDojo API request failed at the transport level." >&2
    [[ ! -s "$response_file" ]] || cat "$response_file" >&2
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

    echo "Background import accepted for test $test_id; waiting..."
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
            echo "ERROR: Failed to poll DefectDojo test $test_id." >&2
            exit 1
        fi

        if [[ "$poll_code" != "200" ]]; then
            echo "ERROR: Test status request returned HTTP $poll_code." >&2
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
                    echo "Import is still processing; waiting..."
                else
                    echo "DefectDojo background import completed."
                    break
                fi
                ;;
            Failed)
                echo "ERROR: DefectDojo reports that test $test_id failed." >&2
                jq . "$test_file" >&2
                exit 1
                ;;
            *)
                echo "DefectDojo test status: ${status:-unknown}; waiting..."
                ;;
        esac

        if (( $(date +%s) >= deadline )); then
            echo "ERROR: Timed out waiting for test $test_id." >&2
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
