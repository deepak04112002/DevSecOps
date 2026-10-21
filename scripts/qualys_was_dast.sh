#!/usr/bin/env bash
# scripts/qualys_was_dast.sh
#
# Runs a Qualys Web Application Scanning (WAS) DAST scan against a target URL.
# Imports the results into DefectDojo.
#
# This stage is gated by the RUN_QUALYS_WAS pipeline parameter.
# It requires:
#   - Qualys WAS subscription
#   - QUALYS_BASE_URL, QUALYS_USERNAME, QUALYS_PASSWORD env vars
#   - WAS_TARGET_URL — the URL of the running app to scan
#
# Environment variables:
#   WAS_TARGET_URL       Required. The web app URL to scan (e.g. http://app:3000).
#   DEFECTDOJO_API_TOKEN Required by defectdojo_import.sh
#   QUALYS_BASE_URL      Required. Qualys API hostname.
#   QUALYS_USERNAME      Required. Qualys API username.
#   QUALYS_PASSWORD      Required. Qualys API password.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"

REPORT_DIR="artifacts/qualys-was"
mkdir -p "$REPORT_DIR"

WAS_REPORT="$REPORT_DIR/qualys-was-report.xml"

log() { printf '[qualys-was] %s\n' "$*"; }

# ---- Preflight -------------------------------------------------------------
if [ -z "${WAS_TARGET_URL:-}" ]; then
    echo "[qualys-was] WAS_TARGET_URL is not set — skipping DAST scan."
    echo "[qualys-was] Set the WAS_TARGET_URL parameter or environment variable to the running app URL."
    exit 0
fi

if [ -z "${QUALYS_BASE_URL:-}" ] || [ -z "${QUALYS_USERNAME:-}" ] || [ -z "${QUALYS_PASSWORD:-}" ]; then
    echo "[qualys-was] Qualys credentials not configured — skipping DAST scan."
    exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "[qualys-was] curl is required." >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "[qualys-was] jq is required."   >&2; exit 1; }

QUALYS_BASE_URL="${QUALYS_BASE_URL%/}"

# ---- 1. Launch a WAS scan via the Qualys API -------------------------------
log "Launching WAS scan against: ${WAS_TARGET_URL}"

# Launch a new webapp scan
launch_response="$(
    curl --silent --show-error \
        --connect-timeout 15 --max-time 60 \
        --user "${QUALYS_USERNAME}:${QUALYS_PASSWORD}" \
        --header "X-Requested-With: DevSecOps-Pipeline" \
        --header "Content-Type: text/xml" \
        --request POST \
        --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<ServiceRequest>
  <data>
    <WebAppScan>
      <name>DevSecOps Pipeline DAST ${WAS_TARGET_URL}</name>
      <url>${WAS_TARGET_URL}</url>
      <auth>\${auth}</auth>
    </WebAppScan>
  </data>
</ServiceRequest>" \
        --output "$REPORT_DIR/launch-response.xml" \
        --write-out '%{http_code}' \
        "${QUALYS_BASE_URL}/qps/rest/3.0/create/was/wasscan"
)"

if [ "$launch_response" != "200" ] && [ "$launch_response" != "201" ]; then
    echo "[qualys-was] Failed to launch WAS scan (HTTP ${launch_response})." >&2
    cat "$REPORT_DIR/launch-response.xml" >&2
    echo "[qualys-was] Skipping DAST import — the scan may need to be launched manually from the Qualys portal."
    exit 0
fi

# Extract scan ID from the response
scan_id="$(xmllint --xpath '//*[local-name()="id"]/text()' "$REPORT_DIR/launch-response.xml" 2>/dev/null || true)"

if [ -z "$scan_id" ]; then
    echo "[qualys-was] Could not extract scan ID from launch response."
    echo "[qualys-was] The scan was launched but results need to be fetched manually."
    exit 0
fi

log "WAS scan launched: ID ${scan_id}"

# ---- 2. Poll for scan completion ------------------------------------------
log "Waiting for scan to complete (this can take 10-30 minutes)..."

max_wait=1800  # 30 minutes
wait_interval=30
elapsed=0

while [ "$elapsed" -lt "$max_wait" ]; do
    status_response="$(
        curl --silent --show-error \
            --connect-timeout 15 --max-time 60 \
            --user "${QUALYS_USERNAME}:${QUALYS_PASSWORD}" \
            --header "X-Requested-With: DevSecOps-Pipeline" \
            --get \
            --data-urlencode "action=list" \
            --data-urlencode "id=${scan_id}" \
            --output "$REPORT_DIR/status-response.xml" \
            --write-out '%{http_code}' \
            "${QUALYS_BASE_URL}/api/2.0/fo/was/scan/"
    )"

    scan_status="$(xmllint --xpath '//*[local-name()="status"]/text()' "$REPORT_DIR/status-response.xml" 2>/dev/null || echo "UNKNOWN")"

    log "Scan status: ${scan_status} (elapsed ${elapsed}s)"

    case "$scan_status" in
        FINISHED|FINISHED_ERRORS|ERROR) break ;;
        *) sleep "$wait_interval"; elapsed=$((elapsed + wait_interval)) ;;
    esac
done

if [ "$scan_status" != "FINISHED" ]; then
    echo "[qualys-was] Scan did not finish within ${max_wait}s (status: ${scan_status})."
    echo "[qualys-was] Download the report manually from the Qualys portal."
    exit 0
fi

# ---- 3. Download the scan report ------------------------------------------
log "Downloading WAS scan report..."

report_code="$(
    curl --silent --show-error \
        --connect-timeout 15 --max-time 300 \
        --user "${QUALYS_USERNAME}:${QUALYS_PASSWORD}" \
        --header "X-Requested-With: DevSecOps-Pipeline" \
        --get \
        --data-urlencode "action=fetch" \
        --data-urlencode "id=${scan_id}" \
        --output "$WAS_REPORT" \
        --write-out '%{http_code}' \
        "${QUALYS_BASE_URL}/api/2.0/fo/was/report/"
)"

if [ "$report_code" != "200" ] || [ ! -s "$WAS_REPORT" ]; then
    echo "[qualys-was] Failed to download WAS report (HTTP ${report_code})."
    exit 0
fi

log "WAS report saved: ${WAS_REPORT}"

# ---- 4. Import into DefectDojo --------------------------------------------
log "Importing WAS report into DefectDojo..."

export DEFECTDOJO_SCAN_FILE="$WAS_REPORT"
export DEFECTDOJO_SCAN_TYPE="Qualys Web Application Scan"
export DEFECTDOJO_TEST_TITLE="Qualys WAS DAST"

bash /opt/devsecops/scripts/defectdojo_import.sh

log "Done."
