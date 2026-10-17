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

REDMINE_LIMIT="${REDMINE_LIMIT:-100}"

command -v curl >/dev/null || {
    echo "ERROR: curl is required" >&2
    exit 1
}

command -v jq >/dev/null || {
    echo "ERROR: jq is required" >&2
    exit 1
}

# Validate positive numeric Redmine IDs.
for var in REDMINE_PROJECT_ID REDMINE_TRACKER_ID REDMINE_STATUS_ID REDMINE_PRIORITY_ID; do
    value="${!var}"

    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( 10#$value < 1 )); then
        echo "ERROR: $var must be a positive numeric ID." >&2
        exit 1
    fi
done

if [[ ! "$REDMINE_LIMIT" =~ ^[0-9]+$ ]] || (( REDMINE_LIMIT < 1 )); then
    echo "ERROR: REDMINE_LIMIT must be a positive integer." >&2
    exit 1
fi

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
REDMINE_URL="${REDMINE_URL%/}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching active DefectDojo findings..."

findings_url="${DEFECTDOJO_URL}/api/v2/findings/"

# IMPORTANT: Each continued command line ends with a backslash.
curl --fail --silent --show-error \
    --connect-timeout 15 \
    --max-time 120 \
    --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
    --header "Accept: application/json" \
    --get \
    --data-urlencode "active=true" \
    --data-urlencode "limit=${REDMINE_LIMIT}" \
    --output "$tmpdir/findings.json" \
    "$findings_url"

jq -e '.results | type == "array"' "$tmpdir/findings.json" >/dev/null || {
    echo "ERROR: Unexpected DefectDojo response; expected a .results array." >&2
    exit 1
}

jq -c '.results[]' "$tmpdir/findings.json" > "$tmpdir/findings.ndjson"

while IFS= read -r finding; do
    finding_id="$(jq -r '.id // empty' <<<"$finding")"
    title="$(jq -r '.title // .name // "Security finding"' <<<"$finding")"
    severity="$(jq -r '.severity // "Unknown"' <<<"$finding")"
    description="$(jq -r '.description // "No description provided."' <<<"$finding")"
    finding_url="$(jq -r '.url // empty' <<<"$finding")"

    [[ -n "$finding_id" ]] || continue

    subject="DD-${finding_id}: ${title}"

    # Search for an existing issue with this finding marker.
    curl --fail --silent --show-error \
        --connect-timeout 15 \
        --max-time 60 \
        --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
        --get \
        --data-urlencode "project_id=${REDMINE_PROJECT_ID}" \
        --data-urlencode "subject=${subject}" \
        --output "$tmpdir/issues.json" \
        "${REDMINE_URL}/issues.json"

    existing_count="$(jq -r '.total_count // (.issues | length) // 0' "$tmpdir/issues.json")"

    if [[ "$existing_count" != "0" ]]; then
        echo "Skipping existing issue for finding ${finding_id}."
        continue
    fi

    issue_description="$(
        printf 'Imported from DefectDojo finding #%s\nSeverity: %s\n\n%s' \
            "$finding_id" "$severity" "$description"
    )"

    if [[ -n "$finding_url" ]]; then
        issue_description+=$'\n\nDefectDojo: '
        issue_description+="$finding_url"
    fi

    # Construct the issue payload with numeric IDs.
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

    # Validate the generated JSON before sending it.
    jq -e '
        .issue
        | (.project_id | numbers)
        and (.tracker_id | numbers)
        and (.status_id | numbers)
        and (.priority_id | numbers)
        and (.subject | strings | length > 0)
    ' "$tmpdir/new-issue.json" >/dev/null || {
        echo "ERROR: Generated Redmine issue payload is invalid." >&2
        exit 1
    }

    echo "Creating Redmine issue for finding ${finding_id}..."

    http_code="$(
        curl --silent --show-error \
            --connect-timeout 15 \
            --max-time 60 \
            --request POST \
            --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
            --header "Content-Type: application/json" \
            --data @"$tmpdir/new-issue.json" \
            --output "$tmpdir/create-response.json" \
            --write-out '%{http_code}' \
            "${REDMINE_URL}/issues.json"
    )"

    if [[ "$http_code" == "201" ]]; then
        issue_number="$(jq -r '.issue.id // "unknown"' "$tmpdir/create-response.json")"
        echo "Created Redmine issue #${issue_number} for finding ${finding_id}."
    else
        echo "ERROR: Failed to create Redmine issue for finding ${finding_id} (HTTP ${http_code})." >&2
        echo "Redmine response:" >&2
        jq . "$tmpdir/create-response.json" >&2 2>/dev/null \
            || cat "$tmpdir/create-response.json" >&2

        echo "Request field summary:" >&2
        jq '{
            project_id: .issue.project_id,
            tracker_id: .issue.tracker_id,
            status_id: .issue.status_id,
            priority_id: .issue.priority_id,
            subject: .issue.subject
        }' "$tmpdir/new-issue.json" >&2

        exit 1
    fi
done < "$tmpdir/findings.ndjson"

echo "Redmine synchronization finished."
