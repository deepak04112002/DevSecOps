#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gitleaks_scan.sh
#
# Runs gitleaks against the checked-out repository, writes a JSON report, and
# imports it into DefectDojo as a "Gitleaks Scan".
#
# This script does NOT decide pass/fail on findings. Every leak becomes an
# active DefectDojo finding, and the Security Policy Gate fails the build on
# any detected secret. This script fails only when:
#   - gitleaks or jq is missing, or the config is missing
#   - gitleaks itself errors (exit code other than 0 or 1)
#   - the DefectDojo import fails
#
# Environment variables (optional unless noted):
#   GITLEAKS_CONFIG       Config file. Default:
#                         /opt/devsecops/infra/security/gitleaks/gitleaks.toml
#   GITLEAKS_SOURCE       Directory to scan. Default: .
#   GITLEAKS_REPORT_DIR   Report output directory. Default: artifacts/gitleaks
#   GITLEAKS_LOG_OPTS     Git log options. Default: empty (full history).
#                         Example: "--since=30.days.ago" or "HEAD~100..HEAD"
#   DEFECTDOJO_API_TOKEN  Required by defectdojo_import.sh
# ---------------------------------------------------------------------------
set -euo pipefail

CONFIG="${GITLEAKS_CONFIG:-/opt/devsecops/infra/security/gitleaks/gitleaks.toml}"
SOURCE="${GITLEAKS_SOURCE:-.}"
REPORT_DIR="${GITLEAKS_REPORT_DIR:-artifacts/gitleaks}"
REPORT="${REPORT_DIR}/gitleaks-report.json"
IMPORT_SCRIPT="/opt/devsecops/scripts/defectdojo_import.sh"

log() { printf '[gitleaks] %s\n' "$*"; }
die() { printf '[gitleaks] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- Preflight -------------------------------------------------------------
command -v gitleaks >/dev/null 2>&1 || die "gitleaks is not installed on this agent."
command -v jq       >/dev/null 2>&1 || die "jq is required but not installed."
[ -f "$CONFIG" ]        || die "Config file not found: $CONFIG"
[ -f "$IMPORT_SCRIPT" ] || die "Import script not found: $IMPORT_SCRIPT"

mkdir -p "$REPORT_DIR"
rm -f "$REPORT"

log "Version: $(gitleaks version)"
log "Source:  ${SOURCE}"
log "Config:  ${CONFIG}"

# ---- Scan ------------------------------------------------------------------
scan_args=(
    detect
    --source "$SOURCE"
    --config "$CONFIG"
    --report-format json
    --report-path "$REPORT"
    --redact
    --no-banner
)

if [ -n "${GITLEAKS_LOG_OPTS:-}" ]; then
    scan_args+=(--log-opts="$GITLEAKS_LOG_OPTS")
fi

# gitleaks exit codes (default behavior):
#   0 = no leaks found
#   1 = leaks found (report is still written)
#   other = scanner error
set +e
gitleaks "${scan_args[@]}"
rc=$?
set -e

case "$rc" in
    0) log "Scan complete: no leaks found." ;;
    1) log "Scan complete: leaks found. The report is written; the Policy Gate will decide." ;;
    *) die "gitleaks failed with exit code ${rc}." ;;
esac

# ---- Normalize the report --------------------------------------------------
# Some gitleaks versions skip the file or write null when nothing is found.
# DefectDojo expects a JSON array, so normalize to [] in those cases.
if [ ! -s "$REPORT" ]; then
    printf '[]\n' > "$REPORT"
fi

report_type="$(jq -r 'type' "$REPORT")"
if [ "$report_type" = "null" ]; then
    printf '[]\n' > "$REPORT"
elif [ "$report_type" != "array" ]; then
    die "Report is not a JSON array (type: ${report_type}): $REPORT"
fi

count="$(jq 'length' "$REPORT")"
log "Findings in report: ${count}"

# Print locations only. Secret values are redacted by --redact.
if [ "$count" -gt 0 ]; then
    log "Locations (first 50):"
    jq -r '.[:50][] | "  - [\(.RuleID)] \(.File):\(.StartLine)"' "$REPORT"
fi

# ---- Import into DefectDojo ------------------------------------------------
export DEFECTDOJO_SCAN_FILE="$REPORT"
export DEFECTDOJO_SCAN_TYPE="Gitleaks Scan"
export DEFECTDOJO_TEST_TITLE="${DEFECTDOJO_TEST_TITLE:-Gitleaks Secret Scan}"

log "Importing report into DefectDojo..."
bash "$IMPORT_SCRIPT" || die "DefectDojo import failed."

log "Done."