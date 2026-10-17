#!/usr/bin/env bash
# scripts/joern_import.sh
# Converts Joern query results (SARIF or plain text) to Generic Findings Import
# format and pushes them to DefectDojo.
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${DEFECTDOJO_PRODUCT_ID:?Set DEFECTDOJO_PRODUCT_ID}"
: "${DEFECTDOJO_ENGAGEMENT_ID:?Set DEFECTDOJO_ENGAGEMENT_ID}"

JOERN_RESULTS_DIR="${JOERN_RESULTS_DIR:-artifacts/joern}"
OUT_FILE="${JOERN_RESULTS_DIR}/joern-findings.json"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# Collect all .txt result files produced by joern queries (not file lists).
# joern-parse produces .bin files; actual query output is written as .txt or
# .json by the query script. We look for any non-empty .json result files
# first, then fall back to .txt files.
mapfile -t result_files < <(
    find "$JOERN_RESULTS_DIR" -maxdepth 1 \
        \( -name "*.sarif" -o -name "*-results.json" -o -name "*-findings.txt" \) \
        -not -empty 2>/dev/null || true
)

if [[ ${#result_files[@]} -eq 0 ]]; then
    echo "No Joern query result files found in ${JOERN_RESULTS_DIR} — skipping import."
    exit 0
fi

# Build a Generic Findings Import JSON from all result files.
# Each line in a findings .txt file becomes one finding.
findings_json="[]"

for result_file in "${result_files[@]}"; do
    ext="${result_file##*.}"

    if [[ "$ext" == "sarif" ]]; then
        # SARIF format — extract results array directly
        sarif_findings="$(
            jq '[
                .runs[].results[] |
                {
                    title: (.ruleId // "Joern Finding"),
                    severity: "Medium",
                    description: (.message.text // ""),
                    file_path: (.locations[0].physicalLocation.artifactLocation.uri // ""),
                    line: (.locations[0].physicalLocation.region.startLine // 1)
                }
            ]' "$result_file" 2>/dev/null || echo "[]"
        )"
        findings_json="$(jq -n --argjson a "$findings_json" --argjson b "$sarif_findings" '$a + $b')"

    elif [[ "$ext" == "json" ]]; then
        # Generic JSON array of findings
        json_findings="$(
            jq '[.[] | {
                title: (.title // .name // "Joern Finding"),
                severity: (.severity // "Medium"),
                description: (.description // .detail // ""),
                file_path: (.file // .filePath // ""),
                line: (.line // .lineNumber // 1)
            }]' "$result_file" 2>/dev/null || echo "[]"
        )"
        findings_json="$(jq -n --argjson a "$findings_json" --argjson b "$json_findings" '$a + $b')"

    else
        # Plain text — each non-empty line is a finding title
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            findings_json="$(
                jq -n \
                    --argjson existing "$findings_json" \
                    --arg title "$line" \
                    '$existing + [{"title": $title, "severity": "Medium", "description": $title, "file_path": "", "line": 1}]'
            )"
        done < "$result_file"
    fi
done

finding_count="$(jq 'length' <<< "$findings_json")"
if [[ "$finding_count" -eq 0 ]]; then
    echo "Joern produced no findings to import."
    exit 0
fi

# Wrap into Generic Findings Import envelope
jq -n --argjson findings "$findings_json" \
    '{"findings": $findings}' > "$OUT_FILE"

echo "Importing ${finding_count} Joern finding(s) into DefectDojo..."

export DEFECTDOJO_SCAN_FILE="$OUT_FILE"
export DEFECTDOJO_SCAN_TYPE="Generic Findings Import"
export DEFECTDOJO_TEST_TITLE="Joern CPG Analysis"
/opt/devsecops/scripts/defectdojo_import.sh
