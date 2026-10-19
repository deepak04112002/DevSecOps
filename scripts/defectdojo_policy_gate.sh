#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${DEFECTDOJO_ENGAGEMENT_ID:?Set DEFECTDOJO_ENGAGEMENT_ID}"

# IMPORTANT: this path must be on persistent storage shared by
# builds of this Jenkins job, not in the cleaned workspace.
BASELINE="${DEFECTDOJO_LOW_BASELINE_FILE:?Set DEFECTDOJO_LOW_BASELINE_FILE}"

[[ "$DEFECTDOJO_ENGAGEMENT_ID" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: Invalid engagement ID." >&2
    exit 1
}

command -v curl >/dev/null
command -v jq >/dev/null
command -v sha256sum >/dev/null
command -v flock >/dev/null

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
mkdir -p "$(dirname "$BASELINE")"

# Prevent two builds from changing the baseline simultaneously.
exec 9>"${BASELINE}.lock"
flock -x 9

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

ndjson="$tmpdir/findings.ndjson"
findings="$tmpdir/findings.json"
: > "$ndjson"

offset=0
page_size=100

echo "Fetching active DefectDojo findings for engagement ${DEFECTDOJO_ENGAGEMENT_ID}..."

while :; do
    code="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 120 \
            --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
            --header "Accept: application/json" \
            --get \
            --data-urlencode "active=true" \
            --data-urlencode "test__engagement=${DEFECTDOJO_ENGAGEMENT_ID}" \
            --data-urlencode "limit=${page_size}" \
            --data-urlencode "offset=${offset}" \
            --output "$tmpdir/page.json" \
            --write-out '%{http_code}' \
            "${DEFECTDOJO_URL}/api/v2/findings/"
    )"

    if [[ "$code" != "200" ]]; then
        echo "ERROR: DefectDojo findings API returned HTTP $code." >&2
        cat "$tmpdir/page.json" >&2
        exit 1
    fi

    jq -e '(.results | type == "array") and (.count | type == "number")' \
        "$tmpdir/page.json" >/dev/null || {
        echo "ERROR: Invalid DefectDojo response; refusing to pass." >&2
        exit 1
    }

    count="$(jq -r '.count' "$tmpdir/page.json")"
    fetched="$(jq '.results | length' "$tmpdir/page.json")"

    jq -c '.results[]' "$tmpdir/page.json" >> "$ndjson"

    (( fetched > 0 )) || break

    offset=$((offset + fetched))
    (( offset < count )) || break
done

jq -s '.' "$ndjson" > "$findings"

# Initialize the persistent baseline on the first run.
if [[ ! -e "$BASELINE" ]]; then
    printf '[]\n' > "$BASELINE"
fi

jq -e 'type == "array" and all(.[]; type == "string")' \
    "$BASELINE" >/dev/null || {
    echo "ERROR: LOW baseline is invalid; refusing to pass." >&2
    exit 1
}

# Fail on MEDIUM, HIGH, or CRITICAL active findings.
# This intentionally applies to findings from all scanners.
jq -e '
    [
        .[]
        | select(
            ((.severity // "") | ascii_upcase)
            as $s
            | ["MEDIUM", "HIGH", "CRITICAL"] | index($s) != null
        )
    ] | length == 0
' "$findings" >/dev/null || {
    echo "ERROR: MEDIUM/HIGH/CRITICAL active findings detected."
    jq -r '
        .[]
        | select(
            ((.severity // "") | ascii_upcase)
            | . == "MEDIUM" or . == "HIGH" or . == "CRITICAL"
        )
        | "\(.severity): \(.title // .name // "Finding") [ID \(.id // "?")]"
    ' "$findings"
    exit 1
}

# Secret classification depends on the fields populated by your
# DefectDojo version and scan importer. Review this mapping against
# actual findings in your instance.
if jq -e '
    [
        .[]
        | [
            (.finding_type // ""),
            (.title // ""),
            (.name // ""),
            (.found_by // [] | if type == "array" then map(tostring) | join(" ") else tostring end),
            (.tags // [] | if type == "array" then map(tostring) | join(" ") else tostring end)
          ]
        | join(" ")
        | select(test(
            "secret|credential|private.key|api.key|access.key|hardcoded.password";
            "i"
          ))
    ] | length > 0
' "$findings" >/dev/null; then
    echo "ERROR: Secret-related active findings detected."
    exit 1
fi

# Build stable fingerprints for LOW findings.
# Exclude finding IDs and line numbers because they can change.
jq -c '
    .[]
    | select((.severity // "" | ascii_upcase) == "LOW")
    | {
        title: (.title // .name // ""),
        cwe: (.cwe // ""),
        vulnerability_ids: (
            (.vulnerability_ids // [])
            | if type == "array" then
                map(
                    if type == "object" then
                        (.vulnerability_id // .name // .value // "")
                    else tostring end
                )
                | sort
              else [] end
        ),
        file_path: (.file_path // ""),
        component_name: (.component_name // ""),
        component_version: (.component_version // "")
      }
' "$findings" |
while IFS= read -r item; do
    printf '%s' "$item" | sha256sum | awk '{print $1}'
done | sort -u > "$tmpdir/current-low.txt"

jq -r '.[]' "$BASELINE" | sort -u > "$tmpdir/previous-low.txt"

# Any LOW fingerprint already in the baseline is recurring.
comm -12 "$tmpdir/current-low.txt" "$tmpdir/previous-low.txt" \
    > "$tmpdir/recurring-low.txt"

if [[ -s "$tmpdir/recurring-low.txt" ]]; then
    echo "ERROR: Previously observed LOW findings have reappeared."
    echo "Recurring fingerprint(s):"
    cat "$tmpdir/recurring-low.txt"
    exit 1
fi

# Record first-seen LOW findings atomically. Keep historical fingerprints
# even when they disappear from a later scan.
cat "$tmpdir/previous-low.txt" "$tmpdir/current-low.txt" |
    sort -u |
    jq -Rsc 'split("\n") | map(select(length > 0))' \
    > "${BASELINE}.tmp"

mv "${BASELINE}.tmp" "$BASELINE"

echo "Security policy passed: no MEDIUM/HIGH/CRITICAL or classified secret findings."
echo "LOW findings checked: $(wc -l < "$tmpdir/current-low.txt")"
