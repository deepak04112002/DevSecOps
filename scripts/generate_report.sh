#!/usr/bin/env bash
# scripts/generate_report.sh
#
# Fetches all active findings from DefectDojo and generates a PDF security
# report using a plain-HTML intermediate that is converted by weasyprint.
#
# Requirements (inside Jenkins container):
#   pip3 install weasyprint   (or add to Dockerfile)
#   jq, curl
#
# Environment variables (all inherited from Jenkins pipeline env):
#   DEFECTDOJO_URL          e.g. http://defectdojo-nginx:8080
#   DEFECTDOJO_API_TOKEN    DefectDojo API token
#   DEFECTDOJO_ENGAGEMENT_ID
#   DEFECTDOJO_ENGAGEMENT_NAME
#   DEFECTDOJO_PRODUCT_NAME
#   JOB_NAME, BUILD_NUMBER, BUILD_URL, GIT_COMMIT
#
# Outputs:
#   artifacts/report/security-report.html
#   artifacts/report/security-report.pdf
set -Eeuo pipefail
umask 077

: "${DEFECTDOJO_URL:?}"
: "${DEFECTDOJO_API_TOKEN:?}"

command -v jq       >/dev/null 2>&1 || { echo "ERROR: jq is required."       >&2; exit 1; }
command -v curl     >/dev/null 2>&1 || { echo "ERROR: curl is required."     >&2; exit 1; }
command -v python3  >/dev/null 2>&1 || { echo "ERROR: python3 is required."  >&2; exit 1; }

python3 -c "import weasyprint" 2>/dev/null || {
    echo "weasyprint not found — installing..."
    pip3 install --quiet weasyprint
}

DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
PAGE_SIZE="${PAGE_SIZE:-100}"
OUT_DIR="artifacts/report"
mkdir -p "$OUT_DIR"

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# ---------------------------------------------------------------------------
# 1. Fetch all active findings
# ---------------------------------------------------------------------------
echo "Fetching active findings from DefectDojo..."
ndjson="$TMPDIR_LOCAL/findings.ndjson"
: > "$ndjson"
offset=0

while :; do
    code="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 120 \
            --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
            --header "Accept: application/json" \
            --get \
            --data-urlencode "active=true" \
            --data-urlencode "limit=${PAGE_SIZE}" \
            --data-urlencode "offset=${offset}" \
            --output "$TMPDIR_LOCAL/page.json" \
            --write-out '%{http_code}' \
            "${DEFECTDOJO_URL}/api/v2/findings/"
    )"
    [ "$code" = "200" ] || { echo "ERROR: DefectDojo returned HTTP $code." >&2; exit 1; }
    count="$(jq -r '.count' "$TMPDIR_LOCAL/page.json")"
    jq -c '.results[]' "$TMPDIR_LOCAL/page.json" >> "$ndjson"
    fetched="$(jq '.results | length' "$TMPDIR_LOCAL/page.json")"
    [ "$fetched" -gt 0 ] || break
    offset=$((offset + fetched))
    [ "$offset" -lt "$count" ] || break
done

total="$(wc -l < "$ndjson")"
echo "Retrieved $total active finding(s)."

# ---------------------------------------------------------------------------
# 2. Fetch tests list to map test_id → scanner name
# ---------------------------------------------------------------------------
tests_json='{"results":[]}'
if [[ "${DEFECTDOJO_ENGAGEMENT_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
    tests_code="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 60 \
            --header "Authorization: Token ${DEFECTDOJO_API_TOKEN}" \
            --header "Accept: application/json" \
            --get \
            --data-urlencode "engagement=${DEFECTDOJO_ENGAGEMENT_ID}" \
            --data-urlencode "limit=200" \
            --output "$TMPDIR_LOCAL/tests.json" \
            --write-out '%{http_code}' \
            "${DEFECTDOJO_URL}/api/v2/tests/"
    )"
    [ "$tests_code" = "200" ] && tests_json="$(cat "$TMPDIR_LOCAL/tests.json")"
fi

# ---------------------------------------------------------------------------
# 3. Build severity-colour map and summary counters via jq + shell
# ---------------------------------------------------------------------------
sev_order="Critical High Medium Low Info"

all_findings="$(jq -s '.' "$ndjson")"

critical_count="$(echo "$all_findings" | jq '[.[] | select(.severity=="Critical")] | length')"
high_count="$(    echo "$all_findings" | jq '[.[] | select(.severity=="High")]     | length')"
medium_count="$(  echo "$all_findings" | jq '[.[] | select(.severity=="Medium")]   | length')"
low_count="$(     echo "$all_findings" | jq '[.[] | select(.severity=="Low")]      | length')"
info_count="$(    echo "$all_findings" | jq '[.[] | select(.severity=="Info")]     | length')"

# ---------------------------------------------------------------------------
# 4. Build the HTML report
# ---------------------------------------------------------------------------
job="${JOB_NAME:-Unknown}"
build="${BUILD_NUMBER:-Unknown}"
commit="${GIT_COMMIT:-Unknown}"
build_url="${BUILD_URL:-}"
product="${DEFECTDOJO_PRODUCT_NAME:-DevSecOps Pipeline}"
engagement="${DEFECTDOJO_ENGAGEMENT_NAME:-CI Pipeline}"
generated="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
engagement_url="${DEFECTDOJO_URL}/engagement/${DEFECTDOJO_ENGAGEMENT_ID:-}"

html_file="$OUT_DIR/security-report.html"

cat > "$html_file" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<title>Security Report — ${product} Build #${build}</title>
<style>
  @page { size: A4; margin: 18mm 15mm; }
  * { box-sizing: border-box; }
  body { font-family: 'Helvetica Neue', Arial, sans-serif; font-size: 10pt;
         color: #1a1a2e; background: #fff; margin: 0; padding: 0; }
  h1  { font-size: 18pt; color: #0f3460; margin-bottom: 2px; }
  h2  { font-size: 13pt; color: #16213e; border-bottom: 2px solid #0f3460;
         padding-bottom: 4px; margin-top: 24px; }
  h3  { font-size: 11pt; color: #0f3460; margin: 18px 0 4px; }
  .subtitle { color: #555; font-size: 10pt; margin-bottom: 16px; }
  .meta-table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
  .meta-table td { padding: 4px 8px; font-size: 9.5pt; vertical-align: top; }
  .meta-table td:first-child { font-weight: bold; width: 160px; color: #333; }
  .summary-grid { display: flex; gap: 12px; flex-wrap: wrap; margin: 16px 0 24px; }
  .sev-card { border-radius: 6px; padding: 10px 16px; color: #fff;
              min-width: 90px; text-align: center; flex: 1; }
  .sev-card .num  { font-size: 22pt; font-weight: 700; line-height: 1; }
  .sev-card .lbl  { font-size: 8.5pt; margin-top: 2px; opacity: .9; }
  .c-critical { background: #c0392b; }
  .c-high     { background: #e67e22; }
  .c-medium   { background: #f39c12; color: #333; }
  .c-low      { background: #27ae60; }
  .c-info     { background: #2980b9; }
  table.findings { border-collapse: collapse; width: 100%; font-size: 8.5pt;
                   margin-top: 8px; }
  table.findings th { background: #0f3460; color: #fff; padding: 5px 7px;
                       text-align: left; }
  table.findings td { border: 1px solid #dde; padding: 4px 7px;
                       vertical-align: top; }
  table.findings tr:nth-child(even) td { background: #f4f6fb; }
  .badge { display: inline-block; padding: 1px 6px; border-radius: 3px;
            font-size: 8pt; font-weight: 600; color: #fff; }
  .b-Critical { background:#c0392b; } .b-High    { background:#e67e22; }
  .b-Medium   { background:#f39c12; color:#333; }
  .b-Low      { background:#27ae60; } .b-Info    { background:#2980b9; }
  .description { max-width: 320px; word-break: break-word; }
  .footer { margin-top: 30px; font-size: 8pt; color: #888;
            border-top: 1px solid #dde; padding-top: 8px; }
  a { color: #0f3460; }
</style>
</head>
<body>

<h1>Security Report</h1>
<p class="subtitle">Generated by the DevSecOps CI/CD pipeline</p>

<table class="meta-table">
  <tr><td>Product</td><td>${product}</td></tr>
  <tr><td>Engagement</td><td>${engagement}</td></tr>
  <tr><td>Job</td><td>${job}</td></tr>
  <tr><td>Build</td><td>#${build}</td></tr>
  <tr><td>Git commit</td><td>${commit}</td></tr>
  <tr><td>Generated</td><td>${generated}</td></tr>
  <tr><td>Build URL</td><td><a href="${build_url}">${build_url}</a></td></tr>
  <tr><td>DefectDojo</td><td><a href="${engagement_url}">${engagement_url}</a></td></tr>
</table>

<h2>Executive Summary</h2>
<div class="summary-grid">
  <div class="sev-card c-critical"><div class="num">${critical_count}</div><div class="lbl">Critical</div></div>
  <div class="sev-card c-high">    <div class="num">${high_count}</div>    <div class="lbl">High</div></div>
  <div class="sev-card c-medium">  <div class="num">${medium_count}</div>  <div class="lbl">Medium</div></div>
  <div class="sev-card c-low">     <div class="num">${low_count}</div>     <div class="lbl">Low</div></div>
  <div class="sev-card c-info">    <div class="num">${info_count}</div>    <div class="lbl">Info</div></div>
</div>
<p>Total active findings: <strong>${total}</strong>.
All findings are tracked in DefectDojo; this report reflects the state at
build time.</p>

<h2>Findings by Severity</h2>
HTMLEOF

# ---- findings table -------------------------------------------------------
tmap="$(echo "$tests_json" | jq -r '.results | map({key:(.id|tostring), value:(.test_title//"Unknown")}) | from_entries')"

for sev in Critical High Medium Low Info; do
    count_var="${sev,,}_count"
    count_val="${!count_var}"
    [ "$count_val" -gt 0 ] || continue

    echo "<h3>${sev} (${count_val})</h3>" >> "$html_file"
    echo '<table class="findings"><thead><tr>' >> "$html_file"
    echo '<th>#</th><th>Title</th><th>Scanner</th><th>File / Component</th><th>Line</th><th>CWE</th><th>CVE</th><th>Description</th>' >> "$html_file"
    echo '</tr></thead><tbody>' >> "$html_file"

    echo "$all_findings" | jq -c --arg sev "$sev" '[.[] | select(.severity == $sev)] | .[]' \
    | while IFS= read -r f; do
        fid="$(    echo "$f" | jq -r '.id')"
        ftitle="$( echo "$f" | jq -r '.title // .name // "Finding"' | sed 's/</\&lt;/g;s/>/\&gt;/g')"
        fpath="$(  echo "$f" | jq -r '.file_path // .component_name // ""' | sed 's/</\&lt;/g;s/>/\&gt;/g')"
        fline="$(  echo "$f" | jq -r '.line // ""')"
        fcwe="$(   echo "$f" | jq -r 'if .cwe == null or .cwe == "" then "" else (.cwe|tostring) end')"
        fcves="$(  echo "$f" | jq -r '(.vulnerability_ids//[]) | map(.vulnerability_id//.name//"") | map(select(length>0)) | join(", ")')"
        fdesc="$(  echo "$f" | jq -r '.description // ""' | head -c 300 | sed 's/</\&lt;/g;s/>/\&gt;/g;s/\n/ /g')"
        ftest="$(  echo "$f" | jq -r '.test // ""')"
        fscanner="$(echo "$tmap" | jq -r --arg tid "$ftest" '.[$tid] // "Unknown"')"

        cat >> "$html_file" << ROWEOF
<tr>
  <td><a href="${DEFECTDOJO_URL}/finding/${fid}">${fid}</a></td>
  <td>${ftitle}</td>
  <td>${fscanner}</td>
  <td>${fpath}</td>
  <td>${fline}</td>
  <td>${fcwe}</td>
  <td>${fcves}</td>
  <td class="description">${fdesc}</td>
</tr>
ROWEOF
    done

    echo "</tbody></table>" >> "$html_file"
done

cat >> "$html_file" << HTMLEOF

<div class="footer">
  Generated by DevSecOps pipeline — ${generated} — Build #${build} &mdash;
  <a href="${engagement_url}">View in DefectDojo</a>
</div>
</body>
</html>
HTMLEOF

echo "HTML report written: $html_file"

# ---------------------------------------------------------------------------
# 5. Convert to PDF with weasyprint
# ---------------------------------------------------------------------------
pdf_file="$OUT_DIR/security-report.pdf"
echo "Converting to PDF..."
python3 -c "
from weasyprint import HTML
HTML(filename='${html_file}').write_pdf('${pdf_file}')
print('PDF written: ${pdf_file}')
"

echo "Report generation complete."
echo "  HTML: $html_file"
echo "  PDF:  $pdf_file"
