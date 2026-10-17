#!/usr/bin/env bash
# scripts/redmine_sync.sh
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${REDMINE_URL:?Set REDMINE_URL}"
: "${REDMINE_API_KEY:?Set REDMINE_API_KEY}"
: "${REDMINE_PROJECT_ID:?Set REDMINE_PROJECT_ID}"

REDMINE_TRACKER_ID="${REDMINE_TRACKER_ID:-1}"
REDMINE_STATUS_ID="${REDMINE_STATUS_ID:-1}"
REDMINE_PRIORITY_ID="${REDMINE_PRIORITY_ID:-2}"
REDMINE_LIMIT="${REDMINE_LIMIT:-100}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
REDMINE_URL="${REDMINE_URL%/}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching active DefectDojo findings..."

curl --fail --silent --show-error \
  --connect-timeout 15 --max-time 120 \
  --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
  --header "Accept: application/json" \
  --get \
  --data-urlencode "active=true" \
  --data-urlencode "limit=${REDMINE_LIMIT}" \
  "${DEFECTDOJO_URL}/api/v2/findings/" \
  --output "$tmpdir/findings.json"

jq -e '.results | type == "array"' "$tmpdir/findings.json" >/dev/null || {
  echo "Unexpected DefectDojo findings response; expected .results array." >&2
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

  # Check existing Redmine issues for this finding marker.
  curl --fail --silent --show-error \
    --connect-timeout 15 --max-time 60 \
    --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
    --get \
    --data-urlencode "project_id=${REDMINE_PROJECT_ID}" \
    --data-urlencode "subject=${subject}" \
    "${REDMINE_URL}/issues.json" \
    --output "$tmpdir/issues.json"

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

  jq -n \
    --arg project_id "$REDMINE_PROJECT_ID" \
    --arg subject "$subject" \
    --arg description "$issue_description" \
    --argjson tracker_id "$REDMINE_TRACKER_ID" \
    --argjson status_id "$REDMINE_STATUS_ID" \
    --argjson priority_id "$REDMINE_PRIORITY_ID" \
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

  http_code="$(
    curl --silent --show-error \
      --connect-timeout 15 --max-time 60 \
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
    echo "Failed to create Redmine issue for finding ${finding_id} (HTTP ${http_code})." >&2
    cat "$tmpdir/create-response.json" >&2
    exit 1
  fi
done < "$tmpdir/findings.ndjson"

echo "Redmine synchronization finished."
