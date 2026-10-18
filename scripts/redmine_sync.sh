#!/usr/bin/env bash
# scripts/redmine_sync.sh
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${REDMINE_URL:?Set REDMINE_URL}"
: "${REDMINE_API_KEY:?Set REDMINE_API_KEY}"
: "${REDMINE_PROJECT_ID:?Set REDMINE_PROJECT_ID}"
: "${REDMINE_TRACKER_ID:?Set REDMINE_TRACKER_ID}"
: "${REDMINE_STATUS_ID:?Set REDMINE_STATUS_ID}"
: "${REDMINE_PRIORITY_ID:?Set REDMINE_PRIORITY_ID}"

PAGE_SIZE="${PAGE_SIZE:-100}"

# Closed-ticket behavior is opt-in.
REDMINE_REOPEN_CLOSED="${REDMINE_REOPEN_CLOSED:-false}"
REDMINE_REOPEN_STATUS_ID="${REDMINE_REOPEN_STATUS_ID:-}"
REDMINE_CLOSED_STATUS_IDS="${REDMINE_CLOSED_STATUS_IDS:-}"

command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl is required." >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required." >&2
    exit 1

}

for var in REDMINE_PROJECT_ID REDMINE_TRACKER_ID REDMINE_STATUS_ID REDMINE_PRIORITY_ID; do
    value="${!var}"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $var must be a positive integer without leading zeros." >&2
        exit 1
    fi
done

if [[ ! "$PAGE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: PAGE_SIZE must be a positive integer." >&2
    exit 1
fi

case "$REDMINE_REOPEN_CLOSED" in
    true|false)
        ;;
    *)
        echo "ERROR: REDMINE_REOPEN_CLOSED must be true or false." >&2
        exit 1
        ;;
esac

if [[ "$REDMINE_REOPEN_CLOSED" == "true" ]]; then
    if [[ ! "$REDMINE_REOPEN_STATUS_ID" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Set REDMINE_REOPEN_STATUS_ID to a valid positive status ID when reopening is enabled." >&2
        exit 1
    fi

    if [[ -z "$REDMINE_CLOSED_STATUS_IDS" ]]; then
        echo "ERROR: Set REDMINE_CLOSED_STATUS_IDS to the closed status IDs for your Redmine instance." >&2
        exit 1
    fi

    IFS=',' read -r -a closed_ids <<< "$REDMINE_CLOSED_STATUS_IDS"
    for id in "${closed_ids[@]}"; do
        if [[ ! "$id" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: REDMINE_CLOSED_STATUS_IDS must be comma-separated positive IDs without spaces." >&2
            exit 1
        fi
    done
fi

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
REDMINE_URL="${REDMINE_URL%/}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Fetch active DefectDojo findings with pagination.
echo "Fetching active DefectDojo findings..."
offset=0
: > "$tmpdir/findings.ndjson"

while :; do
    if ! code="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 120 \
            --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
            --header "Accept: application/json" \
            --get \
            --data-urlencode "active=true" \
            --data-urlencode "limit=${PAGE_SIZE}" \
            --data-urlencode "offset=${offset}" \
            --output "$tmpdir/dd-page.json" \
            --write-out '%{http_code}' \
            "${DEFECTDOJO_URL}/api/v2/findings/"
    )"; then
        echo "ERROR: Could not retrieve DefectDojo findings." >&2
        exit 1
    fi

    if [[ "$code" != "200" ]]; then
        echo "ERROR: DefectDojo returned HTTP $code." >&2
        cat "$tmpdir/dd-page.json" >&2
        exit 1
    fi

    jq -e '(.results | type == "array") and (.count | type == "number")' \
        "$tmpdir/dd-page.json" >/dev/null || {
        echo "ERROR: Invalid DefectDojo pagination response." >&2
        exit 1
    }

    count="$(jq -r '.count' "$tmpdir/dd-page.json")"
    jq -c '.results[]' "$tmpdir/dd-page.json" >> "$tmpdir/findings.ndjson"

    fetched="$(jq '.results | length' "$tmpdir/dd-page.json")"
    (( fetched > 0 )) || break

    offset=$((offset + fetched))
    (( offset < count )) || break
done

echo "Retrieved $(wc -l < "$tmpdir/findings.ndjson") active findings."

# Locate an existing Redmine issue by the stable DefectDojo finding marker.
# Output: issue_id<TAB>status_id
find_existing_issue() {
    local marker="$1"
    local offset=0
    local total=0
    local code
    local found

    while :; do
        if ! code="$(
            curl --silent --show-error \
                --connect-timeout 15 --max-time 60 \
                --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                --header "Accept: application/json" \
                --get \
                --data-urlencode "project_id=${REDMINE_PROJECT_ID}" \
                --data-urlencode "status_id=*" \
                --data-urlencode "limit=${PAGE_SIZE}" \
                --data-urlencode "offset=${offset}" \
                --output "$tmpdir/issues.json" \
                --write-out '%{http_code}' \
                "${REDMINE_URL}/issues.json"
        )"; then
            echo "ERROR: Redmine issue lookup failed at the transport level." >&2
            return 2
        fi

        if [[ "$code" != "200" ]]; then
            echo "ERROR: Redmine issue lookup returned HTTP $code." >&2
            cat "$tmpdir/issues.json" >&2
            return 2
        fi

        jq -e '(.issues | type == "array") and (.total_count | type == "number")' \
            "$tmpdir/issues.json" >/dev/null || {
            echo "ERROR: Invalid Redmine issues response." >&2
            return 2
        }

        total="$(jq -r '.total_count' "$tmpdir/issues.json")"

        found="$(
            jq -r --arg marker "$marker" '
                [
                    .issues[]
                    | select((.subject // "") | startswith($marker))
                    | [
                        (.id | tostring),
                        (.status.id | tostring)
                    ]
                ]
                | first // empty
                | @tsv
            ' "$tmpdir/issues.json"
        )"

        if [[ -n "$found" ]]; then
            printf '%s\n' "$found"
            return 0
        fi

        fetched="$(jq '.issues | length' "$tmpdir/issues.json")"
        (( fetched > 0 )) || break

        offset=$((offset + fetched))
        (( offset < total )) || break
    done

    return 1
}

# Reopen a matching issue only if its current status is configured as closed.
reopen_issue_if_configured() {
    local issue_id="$1"
    local current_status_id="$2"
    local marker="$3"
    local closed_match=false
    local closed_id
    local payload_file="$tmpdir/reopen-issue.json"
    local response_file="$tmpdir/reopen-response.json"
    local code

    [[ "$REDMINE_REOPEN_CLOSED" == "true" ]] || return 0

    for closed_id in "${closed_ids[@]}"; do
        if [[ "$current_status_id" == "$closed_id" ]]; then
            closed_match=true
            break
        fi
    done

    [[ "$closed_match" == "true" ]] || return 0

    jq -n \
        --argjson status_id "$REDMINE_REOPEN_STATUS_ID" \
        --arg notes "Reopened automatically because the associated active DefectDojo finding (${marker}) is present again." \
        '{issue: {status_id: $status_id, notes: $notes}}' \
        > "$payload_file"

    echo "Reopening closed Redmine issue #${issue_id} for ${marker}..."

    if ! code="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 60 \
            --request PUT \
            --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
            --header "Content-Type: application/json" \
            --header "Accept: application/json" \
            --data @"$payload_file" \
            --output "$response_file" \
            --write-out '%{http_code}' \
            "${REDMINE_URL}/issues/${issue_id}.json"
    )"; then
        echo "ERROR: Could not reopen Redmine issue #${issue_id}." >&2
        return 1
    fi

    if [[ "$code" != "200" && "$code" != "204" ]]; then
        echo "ERROR: Reopening issue #${issue_id} failed (HTTP ${code})." >&2
        cat "$response_file" >&2
        return 1
    fi

    echo "Reopened Redmine issue #${issue_id}."
}

created=0
reused=0
reopened=0
failed=0

while IFS= read -r finding; do
    finding_id="$(jq -r '.id // empty' <<<"$finding")"

    if [[ ! "$finding_id" =~ ^[0-9]+$ ]]; then
        echo "WARNING: Skipping finding with invalid ID." >&2
        continue
    fi

    title="$(jq -r '.title // .name // "Security finding"' <<<"$finding")"
    severity="$(jq -r '.severity // "Unknown"' <<<"$finding")"
    description="$(jq -r '.description // "No description provided."' <<<"$finding")"
    finding_url="$(jq -r '.url // empty' <<<"$finding")"

    marker="DD-${finding_id}:"
    subject="${marker} ${title}"

    existing_record=""
    if existing_record="$(find_existing_issue "$marker")"; then
        IFS=$'\t' read -r existing_id existing_status_id <<< "$existing_record"

        if [[ ! "$existing_id" =~ ^[1-9][0-9]*$ ||
              ! "$existing_status_id" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: Existing Redmine issue response has invalid IDs." >&2
            exit 1
        fi

        echo "Reusing Redmine issue #${existing_id} for finding ${finding_id}."

        # Check the configured closed statuses before attempting any update.
        was_closed=false
        if [[ "$REDMINE_REOPEN_CLOSED" == "true" ]]; then
            for closed_id in "${closed_ids[@]}"; do
                if [[ "$existing_status_id" == "$closed_id" ]]; then
                    was_closed=true
                    break
                fi
            done
        fi

        if ! reopen_issue_if_configured "$existing_id" "$existing_status_id" "$marker"; then
            failed=$((failed + 1))
            exit 1
        fi

        if [[ "$was_closed" == "true" ]]; then
            reopened=$((reopened + 1))
        fi

        reused=$((reused + 1))
        continue
    else
        lookup_status=$?
        if (( lookup_status == 2 )); then
            echo "ERROR: Could not safely check for an existing Redmine issue." >&2
            exit 1
        fi
    fi

    issue_description="$(
        printf 'Imported from DefectDojo finding #%s\nSeverity: %s\n\n%s' \
            "$finding_id" "$severity" "$description"
    )"

    if [[ -n "$finding_url" ]]; then
        issue_description+=$'\n\nDefectDojo: '
        issue_description+="$finding_url"
    fi

    jq -n \
        --argjson project_id "$REDMINE_PROJECT_ID" \
        --argjson tracker_id "$REDMINE_TRACKER_ID" \
        --argjson status_id "$REDMINE_STATUS_ID" \
        --argjson priority_id "$REDMINE_PRIORITY_ID" \
        --arg subject "$subject" \
        --arg description "$issue_description" \
        '{
            issue: {
                project_id: $project_id,
                tracker_id: $tracker_id,
                status_id: $status_id,
                priority_id: $priority_id,
                subject: $subject,
                description: $description
            }
        }' > "$tmpdir/new-issue.json"

    jq -e '
        .issue as $i |
        ($i.project_id | numbers) and
        ($i.tracker_id | numbers) and
        ($i.status_id | numbers) and
        ($i.priority_id | numbers) and
        ($i.subject | strings | length > 0)
    ' "$tmpdir/new-issue.json" >/dev/null || {
        echo "ERROR: Invalid generated Redmine payload." >&2
        exit 1
    }

    echo "Creating Redmine issue for finding ${finding_id}..."

    if ! code="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 60 \
            --request POST \
            --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
            --header "Content-Type: application/json" \
            --header "Accept: application/json" \
            --data @"$tmpdir/new-issue.json" \
            --output "$tmpdir/create-response.json" \
            --write-out '%{http_code}' \
            "${REDMINE_URL}/issues.json"
    )"; then
        echo "ERROR: Redmine issue creation failed at the transport level." >&2
        exit 1
    fi

    if [[ "$code" == "201" ]] &&
       jq -e '.issue.id | numbers' "$tmpdir/create-response.json" >/dev/null 2>&1; then
        issue_number="$(jq -r '.issue.id' "$tmpdir/create-response.json")"
        echo "Created Redmine issue #${issue_number} for finding ${finding_id}."
        created=$((created + 1))
    else
        echo "ERROR: Redmine issue creation failed (HTTP ${code})." >&2
        jq . "$tmpdir/create-response.json" >&2 2>/dev/null ||
            cat "$tmpdir/create-response.json" >&2
        failed=$((failed + 1))
        exit 1
    fi
done < "$tmpdir/findings.ndjson"

echo "Redmine sync complete: created=${created}, reused=${reused}, reopened=${reopened}, failed=${failed}."
