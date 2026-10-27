#!/usr/bin/env bash
# defectdojo_policy_gate.sh: scoped security gate.
#
# Evaluates only the DefectDojo tests named in GATE_TEST_TITLES.
# Fails closed when a required test is missing or was not updated by this build.
#
# Required environment:
#   DEFECTDOJO_URL, DEFECTDOJO_API_TOKEN, DEFECTDOJO_ENGAGEMENT_ID
#   DEFECTDOJO_LOW_BASELINE_FILE  base path; "-<GATE_NAME>" is inserted before ".json"
#   GATE_NAME                     e.g. gate-1
#   GATE_TEST_TITLES              comma-separated exact test titles
#   GATE_BUILD_START_EPOCH        build start time in Unix seconds (UTC)
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${DEFECTDOJO_ENGAGEMENT_ID:?Set DEFECTDOJO_ENGAGEMENT_ID}"
: "${DEFECTDOJO_LOW_BASELINE_FILE:?Set DEFECTDOJO_LOW_BASELINE_FILE}"
: "${GATE_NAME:?Set GATE_NAME}"
: "${GATE_TEST_TITLES:?Set GATE_TEST_TITLES}"
: "${GATE_BUILD_START_EPOCH:?Set GATE_BUILD_START_EPOCH}"

[[ "$DEFECTDOJO_ENGAGEMENT_ID" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: Invalid engagement ID." >&2; exit 1; }
[[ "$GATE_NAME" =~ ^[a-z0-9-]+$ ]] || { echo "ERROR: GATE_NAME must be lowercase letters, digits, or hyphens." >&2; exit 1; }
[[ "$GATE_BUILD_START_EPOCH" =~ ^[0-9]+$ ]] || { echo "ERROR: GATE_BUILD_START_EPOCH must be Unix seconds." >&2; exit 1; }

for cmd in curl jq sha256sum flock date; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd is required." >&2; exit 1; }
done

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
BASELINE="${DEFECTDOJO_LOW_BASELINE_FILE%.json}-${GATE_NAME}.json"
BUILD_START="$(date -u -d "@${GATE_BUILD_START_EPOCH}" +%Y-%m-%dT%H:%M:%S)"

mkdir -p "$(dirname "$BASELINE")"

# Prevent two builds from changing the same baseline at once.
exec 9>"${BASELINE}.lock"
flock -x 9

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# fetch_all <api-path> <output-file> [extra --data-urlencode arguments...]
# Pages through a DefectDojo list endpoint and writes a JSON array.
fetch_all() {
    local path="$1" out="$2" offset=0 code fetched count
    shift 2
    : > "$tmpdir/rows.ndjson"

    while :; do
        code="$(
            curl --silent --show-error \
                --connect-timeout 15 --max-time 120 \
                --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
                --header "Accept: application/json" \
                --get "$@" \
                --data-urlencode "limit=100" \
                --data-urlencode "offset=${offset}" \
                --output "$tmpdir/page.json" \
                --write-out '%{http_code}' \
                "${DEFECTDOJO_URL}${path}"
        )" || code="000"

        if [[ "$code" != "200" ]]; then
            echo "ERROR: DefectDojo ${path} returned HTTP ${code}." >&2
            cat "$tmpdir/page.json" >&2 2>/dev/null || true
            exit 1
        fi

        jq -e '(.results | type == "array") and (.count | type == "number")' \
            "$tmpdir/page.json" >/dev/null || {
            echo "ERROR: Invalid response from ${path}; refusing to pass." >&2
            exit 1
        }

        count="$(jq -r '.count' "$tmpdir/page.json")"
        fetched="$(jq '.results | length' "$tmpdir/page.json")"
        jq -c '.results[]' "$tmpdir/page.json" >> "$tmpdir/rows.ndjson"

        (( fetched > 0 )) || break
        offset=$((offset + fetched))
        (( offset < count )) || break
    done

    jq -s '.' "$tmpdir/rows.ndjson" > "$out"
}

# ---------------------------------------------------------------------------
# 1. Resolve required test titles to test IDs and verify each was imported
#    during this build.
# ---------------------------------------------------------------------------
fetch_all "/api/v2/tests/" "$tmpdir/tests.json" \
    --data-urlencode "engagement=${DEFECTDOJO_ENGAGEMENT_ID}"

required_json="$(
    printf '%s' "$GATE_TEST_TITLES" |
    jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
)"

if [[ "$(jq 'length' <<< "$required_json")" -eq 0 ]]; then
    echo "ERROR: GATE_TEST_TITLES is empty." >&2
    exit 1
fi

jq -r --argjson req "$required_json" --arg start "$BUILD_START" '
    $req[] as $t
    | [ .[] | select(.title == $t) ] as $matches
    | if ($matches | length) == 0 then
          "MISSING test: \($t)"
      elif ((any($matches[]; (.updated // "") >= $start)) | not) then
          "STALE test (no import in this build): \($t)"
      else empty end
' "$tmpdir/tests.json" > "$tmpdir/test-problems.txt"

if [[ -s "$tmpdir/test-problems.txt" ]]; then
    echo "ERROR: Gate ${GATE_NAME} cannot evaluate required tests:"
    cat "$tmpdir/test-problems.txt"
    exit 1
fi

jq -c --argjson req "$required_json" '
    [ $req[] as $t | .[] | select(.title == $t) | .id ] | unique
' "$tmpdir/tests.json" > "$tmpdir/scope-ids.json"

# ---------------------------------------------------------------------------
# 2. Fetch active findings and keep only those in the scoped tests.
# ---------------------------------------------------------------------------
fetch_all "/api/v2/findings/" "$tmpdir/findings-all.json" \
    --data-urlencode "active=true" \
    --data-urlencode "test__engagement=${DEFECTDOJO_ENGAGEMENT_ID}"

jq --argjson ids "$(cat "$tmpdir/scope-ids.json")" '
    [ .[] | select(.test as $t | $ids | any(. == $t)) ]
' "$tmpdir/findings-all.json" > "$tmpdir/findings.json"

echo "Gate ${GATE_NAME}: evaluating $(jq 'length' "$tmpdir/scope-ids.json") test(s) and $(jq 'length' "$tmpdir/findings.json") active finding(s)."

# ---------------------------------------------------------------------------
# 3. Blocking severities.
# ---------------------------------------------------------------------------
blocking="$(jq -r '
    .[]
    | select(((.severity // "") | ascii_upcase) as $s
             | ["MEDIUM", "HIGH", "CRITICAL"] | index($s) != null)
    | "\(.severity): \(.title // .name // "Finding") [ID \(.id // "?")]"
' "$tmpdir/findings.json")"

if [[ -n "$blocking" ]]; then
    echo "ERROR: MEDIUM/HIGH/CRITICAL active findings in gate ${GATE_NAME}:"
    echo "$blocking"
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Secrets. Every active finding from the Gitleaks test is a secret.
#    Other tests (Trivy secret scanning) are matched by keyword.
# ---------------------------------------------------------------------------
gitleaks_ids="$(jq -c '[.[] | select(.title == "Gitleaks Secret Scan") | .id]' "$tmpdir/tests.json")"

secrets="$(jq -r --argjson gl "$gitleaks_ids" '
    .[] as $f
    | select(
        ($gl | any(. == $f.test))
        or (
            [
                ($f.finding_type // ""),
                ($f.title // ""),
                ($f.name // ""),
                ($f.description // ""),
                (($f.tags // []) | map(tostring) | join(" "))
            ]
            | join(" ")
            | test("secret|credential|private.?key|api.?key|access.?key|hardcoded.?password|token"; "i")
        )
    )
    | "\($f.title // $f.name // "Finding") [ID \($f.id // "?")]"
' "$tmpdir/findings.json")"

if [[ -n "$secrets" ]]; then
    echo "ERROR: Secret findings in gate ${GATE_NAME}:"
    echo "$secrets"
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. LOW findings: fail if a previously recorded LOW fingerprint reappears.
# ---------------------------------------------------------------------------
if [[ ! -e "$BASELINE" ]]; then
    printf '[]\n' > "$BASELINE"
fi

jq -e 'type == "array" and all(.[]; type == "string")' "$BASELINE" >/dev/null || {
    echo "ERROR: LOW baseline ${BASELINE} is invalid; refusing to pass." >&2
    exit 1
}

# Stable fingerprints: no finding IDs or line numbers, since those change.
jq -c '
    .[]
    | select(((.severity // "") | ascii_upcase) == "LOW")
    | {
        title: (.title // .name // ""),
        cwe: (.cwe // ""),
        vulnerability_ids: (
            (.vulnerability_ids // [])
            | if type == "array" then
                map(if type == "object" then (.vulnerability_id // .name // .value // "") else tostring end)
                | sort
              else [] end
        ),
        file_path: (.file_path // ""),
        component_name: (.component_name // ""),
        component_version: (.component_version // "")
      }
' "$tmpdir/findings.json" |
while IFS= read -r item; do
    printf '%s' "$item" | sha256sum | awk '{print $1}'
done | sort -u > "$tmpdir/current-low.txt"

jq -r '.[]' "$BASELINE" | sort -u > "$tmpdir/previous-low.txt"

comm -12 "$tmpdir/current-low.txt" "$tmpdir/previous-low.txt" > "$tmpdir/recurring-low.txt"

if [[ -s "$tmpdir/recurring-low.txt" ]]; then
    echo "ERROR: Previously observed LOW findings reappeared in gate ${GATE_NAME}."
    echo "Recurring fingerprint(s):"
    cat "$tmpdir/recurring-low.txt"
    exit 1
fi

# Record first-seen LOW fingerprints only after every check has passed.
cat "$tmpdir/previous-low.txt" "$tmpdir/current-low.txt" |
    sort -u |
    jq -Rsc 'split("\n") | map(select(length > 0))' > "${BASELINE}.tmp"

mv "${BASELINE}.tmp" "$BASELINE"

echo "Gate ${GATE_NAME} passed: no MEDIUM/HIGH/CRITICAL or secret findings in scope."
echo "LOW findings recorded: $(wc -l < "$tmpdir/current-low.txt")"