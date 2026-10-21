#!/usr/bin/env bash
# scripts/qualys_image_scan.sh
#
# Scans a built Docker image with Qualys QScanner and generates an SBOM.
# Both artifacts are imported into DefectDojo.
#
# This stage is gated by the RUN_QUALYS_IMAGE pipeline parameter.
# It requires:
#   - Qualys Container Security subscription
#   - QScanner binary installed at /usr/local/bin/qscanner (or in PATH)
#   - QUALYS_ACCESS_TOKEN env var (or --access-token)
#   - QUALYS_POD env var (e.g. IN1, US1, EU1)
#
# Environment variables:
#   IMAGE_NAME           Required. The Docker image name:tag to scan.
#   DEFECTDOJO_API_TOKEN Required by defectdojo_import.sh
#   QUALYS_ACCESS_TOKEN  Required. Qualys CS access token.
#   QUALYS_POD            Required. Qualys platform POD (e.g. IN1).
# ---------------------------------------------------------------------------
set -Eeuo pipefail

: "${IMAGE_NAME:?Set IMAGE_NAME}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"

REPORT_DIR="artifacts/qualys-image"
SBOM_DIR="artifacts/sbom"
mkdir -p "$REPORT_DIR" "$SBOM_DIR"

IMAGE_REPORT="$REPORT_DIR/qualys-image-report.json"
SBOM_FILE="$SBOM_DIR/qualys-sbom.json"

log() { printf '[qualys-image] %s\n' "$*"; }
die() { printf '[qualys-image] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- Preflight -------------------------------------------------------------
command -v qscanner >/dev/null 2>&1 || {
    echo "[qualys-image] QScanner is not installed — skipping Qualys image scan."
    echo "[qualys-image] Install QScanner from your Qualys portal and place it at /usr/local/bin/qscanner."
    exit 0
}

command -v jq    >/dev/null 2>&1 || die "jq is not installed."
command -v docker >/dev/null 2>&1 || die "docker is not installed."

if [ -z "${QUALYS_ACCESS_TOKEN:-}" ]; then
    echo "[qualys-image] QUALYS_ACCESS_TOKEN is not set — skipping Qualys image scan."
    exit 0
fi

if [ -z "${QUALYS_POD:-}" ]; then
    echo "[qualys-image] QUALYS_POD is not set — skipping Qualys image scan."
    exit 0
fi

# ---- 1. Scan the image with QScanner --------------------------------------
log "Scanning image: ${IMAGE_NAME}"

qscanner image "${IMAGE_NAME}" \
    --mode get-report \
    --scan-types pkg,secret \
    --report-format json \
    --access-token "${QUALYS_ACCESS_TOKEN}" \
    --pod "${QUALYS_POD}" \
    --output-dir "$REPORT_DIR" \
    --quiet

# QScanner writes the report to the output dir; find the JSON report.
if [ ! -f "$IMAGE_REPORT" ]; then
    # Try to find any JSON report in the output dir
    found_report="$(find "$REPORT_DIR" -name "*.json" -type f -size +0c | head -1)"
    if [ -n "$found_report" ]; then
        cp "$found_report" "$IMAGE_REPORT"
    else
        die "QScanner did not produce a JSON report."
    fi
fi

log "QScanner scan complete."

# ---- 2. Generate SBOM with QScanner ---------------------------------------
log "Generating SBOM with QScanner..."

qscanner image "${IMAGE_NAME}" \
    --mode inventory-only \
    --format spdx \
    --access-token "${QUALYS_ACCESS_TOKEN}" \
    --pod "${QUALYS_POD}" \
    --output-dir "$SBOM_DIR" \
    --quiet

log "SBOM generated."

# ---- 3. Import QScanner report into DefectDojo ----------------------------
log "Importing Qualys image scan into DefectDojo..."

export DEFECTDOJO_SCAN_FILE="$IMAGE_REPORT"
export DEFECTDOJO_SCAN_TYPE="Qualys Scan"
export DEFECTDOJO_TEST_TITLE="Qualys Image Scan"

bash /opt/devsecops/scripts/defectdojo_import.sh

log "Done."
