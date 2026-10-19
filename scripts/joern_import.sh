
#!/usr/bin/env bash
# scripts/joern_import.sh
# Normalize Joern results and import them into DefectDojo.
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?Set DEFECTDOJO_URL}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"
: "${DEFECTDOJO_PRODUCT_ID:?Set DEFECTDOJO_PRODUCT_ID}"
: "${DEFECTDOJO_ENGAGEMENT_ID:?Set DEFECTDOJO_ENGAGEMENT_ID}"

JOERN_RESULTS_DIR="${JOERN_RESULTS_DIR:-artifacts/joern}"
OUT_FILE="${JOERN_RESULTS_DIR}/joern-findings.json"

command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required." >&2
    exit 1
}

[[ -d "$JOERN_RESULTS_DIR" ]] || {
    echo "ERROR: Results directory not found: $JOERN_RESULTS_DIR" >&2
    exit 1
}

mkdir -p "$(dirname "$OUT_FILE")"

# Find supported result files. Exclude our generated output.
mapfile -t result_files < <(
    find "$JOERN_RESULTS_DIR" -maxdepth 1 -type f \
        \( -name "*.sarif" \
        -o -name "*.json" \
        -o -name "*-findings.txt" \) \
        ! -path "$OUT_FILE" \
        ! -name "*.bin" \
        -size +0c -print |
    sort
)

if [[ ${#result_files[@]} -eq 0 ]]; then
    echo "ERROR: No non-empty Joern result files found in $JOERN_RESULTS_DIR" >&2
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Normalize one source file at a time.
for i in "${!result_files[@]}"; do
    result_file="${result_files[$i]}"
    normalized="$tmp_dir/$i.json"

    echo "Processing: $result_file" >&2

    case "$result_file" in
        *.sarif)
            jq -e '
                if (.runs | type) != "array" then
                    error("Invalid SARIF: missing runs array")
                else
                    [
                        .runs[]?.results[]? |
                        {
                            title: (
                                .message.text //
                                .ruleId //
                                "Joern Finding"
                            ),
                            rule_id: (.ruleId // ""),
                            severity: (
                                if .level == "error" then "High"
                                elif .level == "warning" then "Medium"
                                else "Low" end
                            ),
                            description: (.message.text // ""),
                            file_path: (
                                .locations[0].physicalLocation
                                    .artifactLocation.uri // ""
                            ),
                            line: (
                                .locations[0].physicalLocation
                                    .region.startLine // 1
                            ),
                            code: (
                                .locations[0].physicalLocation
                                    .region.snippet.text // ""
                            )
                        }
                    ]
                end
            ' "$result_file" > "$normalized"
            ;;

        *.json)
            # Supports:
            #   [...]
            #   {"findings": [...]}
            #   {"runs": [...]} (SARIF-like JSON)
            #   A single finding object.
            jq -e '
                def records:
                    if type == "array" then .
                    elif (.findings | type) == "array" then .findings
                    elif (.runs | type) == "array" then
                        [.runs[]?.results[]?]
                    elif (
                        has("title") or has("name") or
                        has("ruleId") or has("rule_id") or
                        has("description") or has("file_path")
                    ) then [.]
                    else error("Unsupported JSON finding structure")
                    end;

                records |
                map({
                    title: (
                        .title // .name // .ruleId //
                        .rule_id // "Joern Finding"
                    ),
                    rule_id: (.rule_id // .ruleId // ""),
                    severity: (
                        .severity //
                        (if .level == "error" then "High"
                         elif .level == "warning" then "Medium"
                         else "Low" end)
                    ),
                    description: (
                        .description //
                        .detail //
                        .message.text //
                        .message //
                        ""
                    ),
                    file_path: (
                        .file_path //
                        .filePath //
                        .file //
                        .locations[0].physicalLocation
                            .artifactLocation.uri //
                        ""
                    ),
                    line: (
                        .line //
                        .lineNumber //
                        .locations[0].physicalLocation
                            .region.startLine //
                        1
                    ),
                    code: (
                        .code //
                        .snippet //
                        .locations[0].physicalLocation
                            .region.snippet.text //
                        ""
                    )
                })
            ' "$result_file" > "$normalized"
            ;;

        *.txt)
            # One non-empty line per finding; text has no reliable location.
            jq -Rn '
                [
                    inputs |
                    select(test("\\S")) |
                    {
                        title: .,
                        rule_id: "",
                        severity: "Medium",
                        description: .,
                        file_path: "",
                        line: 1,
                        code: ""
                    }
                ]
            ' < "$result_file" > "$normalized"
            ;;

        *)
            continue
            ;;
    esac

    jq -e 'type == "array"' "$normalized" >/dev/null || {
        echo "ERROR: Invalid normalized results from $result_file" >&2
        exit 1
    }
done

# Combine all normalized result arrays.
jq -s 'add' "$tmp_dir"/*.json > "$tmp_dir/combined.json"

# Deduplicate identical rule/title/location findings.
jq '
    unique_by([
        .rule_id,
        .title,
        .file_path,
        (.line | tostring)
    ])
    | {findings: .}
' "$tmp_dir/combined.json" > "$OUT_FILE"

finding_count="$(jq '.findings | length' "$OUT_FILE")"

if [[ "$finding_count" -eq 0 ]]; then
    echo "No Joern findings to import."
    exit 0
fi

echo "Importing $finding_count Joern finding(s) into DefectDojo..."

export DEFECTDOJO_SCAN_FILE="$OUT_FILE"
export DEFECTDOJO_SCAN_TYPE="Generic Findings Import"
export DEFECTDOJO_TEST_TITLE="Joern CPG Analysis"

/opt/devsecops/scripts/defectdojo_import.sh
