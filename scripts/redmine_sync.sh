#!/usr/bin/env bash
# scripts/redmine_sync.sh
#
# Consolidates every active DefectDojo finding for the engagement into a
# SINGLE Redmine ticket per pipeline job, so the team follows one living
# ticket instead of one ticket per finding (or per failing stage).
#
# Each pipeline run:
#   * pulls every active finding from DefectDojo,
#   * groups them by scanner/test and severity into a consolidated report,
#   * creates the ticket the first time, then on every later run updates
#     the SAME ticket: the description is replaced with the latest full
#     report, and a short per-build summary is appended as a note so the
#     ticket becomes a running history.
#
# DefectDojo stays the per-finding source of truth; this ticket is the
# rollup the team watches.
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
REDMINE_REOPEN_CLOSED="${REDMINE_REOPEN_CLOSED:-false}"
REDMINE_REOPEN_STATUS_ID="${REDMINE_REOPEN_STATUS_ID:-}"
REDMINE_CLOSED_STATUS_IDS="${REDMINE_CLOSED_STATUS_IDS:-}"

# Optional: used to map each finding to the scanner/test that produced it
# (test_id -> test_title) and to link the DefectDojo engagement.
DEFECTDOJO_ENGAGEMENT_ID="${DEFECTDOJO_ENGAGEMENT_ID:-}"

command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl is required." >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required." >&2
    exit 1
}

for var in REDMINE_PROJECT_ID REDMINE_TRACKER_ID \
           REDMINE_STATUS_ID REDMINE_PRIORITY_ID; do
    value="${!var}"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $var must be a positive integer." >&2
        exit 1
    fi
done

if [[ ! "$PAGE_SIZE" =~ ^[1-9][0-9]*$ ]] ||
   (( PAGE_SIZE > 1000 )); then
    echo "ERROR: PAGE_SIZE must be between 1 and 1000." >&2
    exit 1
fi

case "$REDMINE_REOPEN_CLOSED" in
    true|false) ;;
    *)
        echo "ERROR: REDMINE_REOPEN_CLOSED must be true or false." >&2
        exit 1
        ;;
esac

closed_ids=()

if [[ "$REDMINE_REOPEN_CLOSED" == "true" ]]; then
    if [[ ! "$REDMINE_REOPEN_STATUS_ID" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Set REDMINE_REOPEN_STATUS_ID to a valid positive status ID." >&2
        exit 1
    fi

    if [[ -z "$REDMINE_CLOSED_STATUS_IDS" ]]; then
        echo "ERROR: Set REDMINE_CLOSED_STATUS_IDS when reopening is enabled." >&2
        exit 1
    fi

    IFS=',' read -r -a closed_ids <<< "$REDMINE_CLOSED_STATUS_IDS"

    for id in "${closed_ids[@]}"; do
        if [[ ! "$id" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: REDMINE_CLOSED_STATUS_IDS must contain positive IDs without spaces." >&2
            exit 1
        fi
    done
fi

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
REDMINE_URL="${REDMINE_URL%/}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---------------------------------------------------------------------------
# 1. Fetch every active DefectDojo finding (paginate).
# ---------------------------------------------------------------------------
echo "Fetching active DefectDojo findings..."

ndjson="$tmpdir/findings.ndjson"
: > "$ndjson"
offset=0

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
    jq -c '.results[]' "$tmpdir/dd-page.json" >> "$ndjson"

    fetched="$(jq '.results | length' "$tmpdir/dd-page.json")"
    (( fetched > 0 )) || break

    offset=$((offset + fetched))
    (( offset < count )) || break
done

findings_file="$tmpdir/findings.json"
jq -s '.' "$ndjson" > "$findings_file"
findings_count="$(jq 'length' "$findings_file")"
echo "Retrieved ${findings_count} active findings."

# ---------------------------------------------------------------------------
# 2. Fetch the engagement's tests so each finding can be grouped by the
#    scanner/test that produced it (test_id -> test_title).
# ---------------------------------------------------------------------------
tests_file="$tmpdir/tests.json"
echo '{"results":[]}' > "$tests_file"

if [[ "$DEFECTDOJO_ENGAGEMENT_ID" =~ ^[1-9][0-9]*$ ]]; then
    if tcode="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 60 \
            --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
            --header "Accept: application/json" \
            --get \
            --data-urlencode "engagement=${DEFECTDOJO_ENGAGEMENT_ID}" \
            --data-urlencode "limit=200" \
            --output "$tests_file" \
            --write-out '%{http_code}' \
            "${DEFECTDOJO_URL}/api/v2/tests/"
    )"; then
        if [[ "$tcode" != "200" ]]; then
            echo "WARNING: DefectDojo tests list returned HTTP ${tcode}; scanner names may fall back to test IDs." >&2
            echo '{"results":[]}' > "$tests_file"
        fi
    else
        echo "WARNING: Could not fetch DefectDojo tests list; scanner names may fall back to test IDs." >&2
        echo '{"results":[]}' > "$tests_file"
    fi
else
    echo "WARNING: DEFECTDOJO_ENGAGEMENT_ID is not set; scanner grouping will use 'found_by' or 'Unspecified'." >&2
fi

# ---------------------------------------------------------------------------
# 3. Build the consolidated report (description) and per-build summary (note).
# ---------------------------------------------------------------------------
job="${JOB_NAME:-Unknown}"
build="${BUILD_NUMBER:-Unknown}"
generated="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
if [[ "$DEFECTDOJO_ENGAGEMENT_ID" =~ ^[1-9][0-9]*$ ]]; then
    engagement_url="${DEFECTDOJO_URL}/engagement/${DEFECTDOJO_ENGAGEMENT_ID}"
else
    engagement_url="${DEFECTDOJO_URL}"
fi

report_file="$tmpdir/report.json"
jq -n \
    --slurpfile findings "$findings_file" \
    --slurpfile tests "$tests_file" \
    --arg job "$job" \
    --arg build "$build" \
    --arg generated "$generated" \
    --arg engagement_url "$engagement_url" \
    --arg defectdojo_url "$DEFECTDOJO_URL" \
    '
    ($findings[0]) as $fs
    | ($tests[0].results // []) as $tr
    | ( $tr
        | map({
            key: (.id | tostring),
            value: (
              if .test_title != null and .test_title != "" then .test_title
              elif .scan_type != null and .scan_type != "" then .scan_type
              else "Unknown"
              end
            )
          })
        | from_entries
      ) as $tmap
    | ( $fs | map(
        . as $f
        | ( $tmap[($f.test | tostring)] // "" ) as $map_test
        | ( if $map_test != "" then $map_test
            else (
              ($f.found_by // [])
              | map(if type == "object" then (.name // .display_name // (.id | tostring)) else tostring end)
              | join(", ")
            )
            end
          ) as $scanner_raw
        | {
            id: $f.id,
            title: ($f.title // $f.name // "Security finding"),
            severity: ($f.severity // "Unknown"),
            scanner: (if $scanner_raw == "" then "Unspecified" else $scanner_raw end),
            file_path: ($f.file_path // $f.component_name // "Not specified"),
            line_number: ($f.line // "Not specified"),
            component_version: ($f.component_version // "Not specified"),
            fixed_version: (
              ($f.mitigation // "") |
              if . == "" or . == null then "Not available" else . end
            ),
            cvss: (
              if $f.cvssv3_score != null and $f.cvssv3_score != "" then
                ($f.cvssv3_score | tostring)
              elif $f.cvssv3 != null and $f.cvssv3 != "" then
                ($f.cvssv3 | tostring)
              elif $f.cvssv2_score != null and $f.cvssv2_score != "" then
                ("v2:" + ($f.cvssv2_score | tostring))
              else "Not available"
              end
            ),
            cwe: (if $f.cwe == null or $f.cwe == "" then "Not specified" else ($f.cwe | tostring) end),
            cves: (
              ( ($f.vulnerability_ids // [])
                | map(if type == "object" then (.vulnerability_id // .name // .value // empty) else tostring end)
                | map(select(length > 0)) | unique | join(", ")
              ) | if . == "" then "Not specified" else . end
            ),
            description: (
              ($f.description // "") |
              if . == "" or . == null then ""
              else
                ( . | split("\n") | map(select(length > 0)) | .[0:3] | join(" ") |
                  if length > 300 then .[0:300] + "..." else . end )
              end
            ),
            finding_url: ($defectdojo_url + "/finding/" + ($f.id | tostring))
          }
      ) ) as $a
    | ( $a | length ) as $total
    | ( $a | group_by(.severity) | map({key: .[0].severity, value: length}) | from_entries ) as $by_sev
    | ( $a | group_by(.scanner) | map({key: .[0].scanner, value: length}) | from_entries ) as $by_sc
    | ( $a | group_by(.scanner) | map(.[0].scanner) ) as $scanners
    | {
        total: $total,
        report: (
          [ "CONSOLIDATED SECURITY REPORT\n",
            "=============================\n\n",
            ("Job: " + $job + "\n"),
            ("Build: #" + $build + "\n"),
            ("Generated: " + $generated + "\n"),
            ("DefectDojo engagement: " + $engagement_url + "\n"),
            ("Total active findings: " + ($total | tostring) + "\n\n")
          ]
          + ( if $total > 0 then
                [ "BY SEVERITY\n-----------\n",
                  ($by_sev | to_entries | sort_by(.key) | map("  " + .key + ": " + (.value | tostring) + "\n") | join("")),
                  "\nBY SCANNER\n----------\n",
                  ($by_sc | to_entries | sort_by(.key) | map("  " + .key + ": " + (.value | tostring) + "\n") | join("")),
                  "\n"
                ]
                + ( $scanners | sort_by(.)
                    | [ .[] | . as $s
                        | ( "\n[" + $s + "]\n"
                            + ( [ $a | map(select(.scanner == $s)) | sort_by(.severity) | .[]
                                  | ("  #" + (.id | tostring) + " [" + .severity + "] " + .title + "\n"
                                     + "    File/component: " + .file_path + ":" + (.line_number | tostring) + "\n"
                                     + "    Installed version: " + .component_version
                                       + (if .fixed_version == "Not available" then "" else " → Fixed in: " + .fixed_version end) + "\n"
                                     + "    CVSS: " + .cvss + "\n"
                                     + "    CWE: " + .cwe + "\n"
                                     + "    CVE / vulnerability IDs: " + .cves + "\n"
                                     + (if .description == "" then "" else "    Description: " + .description + "\n" end)
                                     + "    DefectDojo: " + .finding_url + "\n")
                                ] | join("")
                            )
                          )
                      ]
                  )
              else
                [ "No active findings. DefectDojo engagement is clean.\n" ]
              end
            )
          | join("")
        ),
        note: (
          if $total == 0 then
            ("Build #" + $build + " (" + $generated + "): 0 active findings - all clear.")
          else
            ( "Build #" + $build + " (" + $generated + "): " + ($total | tostring) + " active findings - "
              + ( $by_sev | to_entries | sort_by(.key) | map(.key + ":" + (.value | tostring)) | join(", ") )
              + ". "
              + ( $by_sc | to_entries | sort_by(.key) | map(.key + ":" + (.value | tostring)) | join(", ") )
              + "." )
          end
        )
      }
    ' > "$report_file"

report_total="$(jq -r '.total' "$report_file")"
report="$(jq -r '.report' "$report_file")"
note="$(jq -r '.note' "$report_file")"

# ---------------------------------------------------------------------------
# 4. Find the existing consolidated ticket for this job (stable marker).
# ---------------------------------------------------------------------------
marker="DD-CONSOLIDATED-REPORT: ${job}"
subject="${marker} - ${report_total} active findings (build #${build})"

existing_id=""
existing_status_id=""
issue_id=""
offset=0
rm_total=0

while :; do
    if ! rcode="$(
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
        exit 1
    fi

    if [[ "$rcode" != "200" ]]; then
        echo "ERROR: Redmine issue lookup returned HTTP $rcode." >&2
        cat "$tmpdir/issues.json" >&2
        exit 1
    fi

    jq -e '(.issues | type == "array") and (.total_count | type == "number")' \
        "$tmpdir/issues.json" >/dev/null || {
        echo "ERROR: Invalid Redmine issues response." >&2
        exit 1
    }

    rm_total="$(jq -r '.total_count' "$tmpdir/issues.json")"

    found="$(jq -r --arg marker "$marker" '
        [ .issues[]
          | select((.subject // "") | startswith($marker))
          | [(.id | tostring), (.status.id | tostring)]
        ] | first // empty | @tsv
    ' "$tmpdir/issues.json")"

    if [[ -n "$found" ]]; then
        IFS=$'\t' read -r existing_id existing_status_id <<< "$found"
        break
    fi

    fetched="$(jq '.issues | length' "$tmpdir/issues.json")"
    (( fetched > 0 )) || break
    offset=$((offset + fetched))
    (( offset < rm_total )) || break
done

# ---------------------------------------------------------------------------
# 5. Create (first time) or update (every later run) the single ticket.
# ---------------------------------------------------------------------------
if [[ -n "$existing_id" ]]; then
    echo "Updating consolidated Redmine ticket #${existing_id} for: ${job}"

    reopen=0
    if [[ "$REDMINE_REOPEN_CLOSED" == "true" ]]; then
        for cid in "${closed_ids[@]}"; do
            if [[ "$existing_status_id" == "$cid" ]]; then
                reopen=1
                break
            fi
        done
    fi

    if [[ "$reopen" == "1" ]]; then
        echo "Ticket #${existing_id} was closed; reopening and updating."
        jq -n \
            --argjson status_id "$REDMINE_REOPEN_STATUS_ID" \
            --arg subject "$subject" \
            --arg description "$report" \
            --arg notes "$note" \
            '{issue: {status_id: $status_id, subject: $subject, description: $description, notes: $notes}}' \
            > "$tmpdir/update.json"
    else
        jq -n \
            --arg subject "$subject" \
            --arg description "$report" \
            --arg notes "$note" \
            '{issue: {subject: $subject, description: $description, notes: $notes}}' \
            > "$tmpdir/update.json"
    fi

    if ! rcode="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 60 \
            --request PUT \
            --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
            --header "Content-Type: application/json" \
            --header "Accept: application/json" \
            --data @"$tmpdir/update.json" \
            --output "$tmpdir/update-response.json" \
            --write-out '%{http_code}' \
            "${REDMINE_URL}/issues/${existing_id}.json"
    )"; then
        echo "ERROR: Redmine update request failed." >&2
        exit 1
    fi

    if [[ "$rcode" == "200" || "$rcode" == "204" ]]; then
        echo "Consolidated Redmine ticket updated: #${existing_id} (${report_total} active findings)."
    else
        echo "ERROR: Redmine update failed (HTTP ${rcode})." >&2
        cat "$tmpdir/update-response.json" >&2
        exit 1
    fi
else
    echo "No existing consolidated ticket for: ${job}; creating one."

    jq -n \
        --argjson project_id "$REDMINE_PROJECT_ID" \
        --argjson tracker_id "$REDMINE_TRACKER_ID" \
        --argjson status_id "$REDMINE_STATUS_ID" \
        --argjson priority_id "$REDMINE_PRIORITY_ID" \
        --arg subject "$subject" \
        --arg description "$report" \
        '{issue: {
            project_id: $project_id,
            tracker_id: $tracker_id,
            status_id: $status_id,
            priority_id: $priority_id,
            subject: $subject,
            description: $description
        }}' > "$tmpdir/create.json"

    if ! rcode="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 60 \
            --request POST \
            --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
            --header "Content-Type: application/json" \
            --header "Accept: application/json" \
            --data @"$tmpdir/create.json" \
            --output "$tmpdir/create-response.json" \
            --write-out '%{http_code}' \
            "${REDMINE_URL}/issues.json"
    )"; then
        echo "ERROR: Redmine issue creation failed at the transport level." >&2
        exit 1
    fi

    if [[ "$rcode" == "201" ]] &&
       jq -e '.issue.id | numbers' "$tmpdir/create-response.json" >/dev/null 2>&1; then
        issue_id="$(jq -r '.issue.id' "$tmpdir/create-response.json")"
        echo "Consolidated Redmine ticket created: #${issue_id} (${report_total} active findings)."
    else
        echo "ERROR: Redmine issue creation failed (HTTP ${rcode})." >&2
        jq . "$tmpdir/create-response.json" >&2 2>/dev/null ||
            cat "$tmpdir/create-response.json" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 6. Attach the PDF security report to the ticket (if it exists).
#
# Redmine file attachment is a two-step process:
#   a) POST /uploads.json with raw file bytes  → receive an upload token
#   b) PUT  /issues/<id>.json with the token   → attach file to the ticket
#
# Failures here are non-fatal: we warn and continue so a missing PDF or
# a Redmine upload error never breaks the sync.
# ---------------------------------------------------------------------------

# Resolve the final ticket ID (created or updated path)
ticket_id="${existing_id:-${issue_id:-}}"

PDF_FILE="${PDF_REPORT_PATH:-artifacts/report/security-report.pdf}"

if [[ -z "$ticket_id" ]]; then
    echo "WARNING: Could not determine ticket ID — skipping PDF attachment." >&2
elif [[ ! -f "$PDF_FILE" || ! -s "$PDF_FILE" ]]; then
    echo "No PDF report found at ${PDF_FILE} — skipping attachment."
else
    echo "Uploading PDF report to Redmine (${PDF_FILE})..."

    # Step a: upload the raw bytes and get an upload token
    if ! upload_code="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 120 \
            --request POST \
            --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
            --header "Content-Type: application/octet-stream" \
            --header "Accept: application/json" \
            --data-binary "@${PDF_FILE}" \
            --output "$tmpdir/upload-response.json" \
            --write-out '%{http_code}' \
            "${REDMINE_URL}/uploads.json"
    )"; then
        echo "WARNING: PDF upload request failed at transport level — skipping attachment." >&2
    elif [[ "$upload_code" != "201" ]]; then
        echo "WARNING: PDF upload returned HTTP ${upload_code} — skipping attachment." >&2
        cat "$tmpdir/upload-response.json" >&2 || true
    else
        upload_token="$(jq -r '.upload.token // empty' "$tmpdir/upload-response.json")"

        if [[ -z "$upload_token" ]]; then
            echo "WARNING: No upload token in Redmine response — skipping attachment." >&2
        else
            echo "Upload token received. Attaching PDF to ticket #${ticket_id}..."

            # Step b: attach the uploaded file to the ticket
            filename="security-report-build-${BUILD_NUMBER:-unknown}.pdf"

            jq -n \
                --arg token    "$upload_token" \
                --arg filename "$filename" \
                '{issue: {uploads: [{token: $token, filename: $filename, content_type: "application/pdf"}]}}' \
                > "$tmpdir/attach.json"

            if ! attach_code="$(
                curl --silent --show-error \
                    --connect-timeout 15 --max-time 60 \
                    --request PUT \
                    --header "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
                    --header "Content-Type: application/json" \
                    --header "Accept: application/json" \
                    --data @"$tmpdir/attach.json" \
                    --output "$tmpdir/attach-response.json" \
                    --write-out '%{http_code}' \
                    "${REDMINE_URL}/issues/${ticket_id}.json"
            )"; then
                echo "WARNING: PDF attachment request failed at transport level." >&2
            elif [[ "$attach_code" == "200" || "$attach_code" == "204" ]]; then
                echo "PDF report attached to Redmine ticket #${ticket_id}: ${filename}"
            else
                echo "WARNING: PDF attachment returned HTTP ${attach_code}." >&2
                cat "$tmpdir/attach-response.json" >&2 || true
            fi
        fi
    fi
fi
