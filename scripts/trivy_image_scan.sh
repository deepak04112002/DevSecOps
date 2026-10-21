#!/usr/bin/env bash
# scripts/trivy_image_scan.sh
#
# Scans a built Docker image with Trivy and generates an SBOM with syft.
# Both artifacts are imported into DefectDojo.
#
# Environment variables:
#   IMAGE_NAME           Required. The Docker image name:tag to scan.
#   DEFECTDOJO_API_TOKEN Required by defectdojo_import.sh
#   TRIVY_IMAGE_SCAN     Optional. Set to "true" to run (default: true).
# ---------------------------------------------------------------------------
set -Eeuo pipefail

: "${IMAGE_NAME:?Set IMAGE_NAME to the image name:tag to scan}"
: "${DEFECTDOJO_API_TOKEN:?Set DEFECTDOJO_API_TOKEN}"

REPORT_DIR="artifacts/trivy-image"
SBOM_DIR="artifacts/sbom"
mkdir -p "$REPORT_DIR" "$SBOM_DIR"

IMAGE_REPORT="$REPORT_DIR/trivy-image-report.json"
SBOM_FILE="$SBOM_DIR/sbom.json"

log() { printf '[trivy-image] %s\n' "$*"; }
die() { printf '[trivy-image] ERROR: %s\n' "$*" >&2; exit 1; }

command -v trivy  >/dev/null 2>&1 || die "trivy is not installed."
command -v syft   >/dev/null 2>&1 || die "syft is not installed."
command -v jq     >/dev/null 2>&1 || die "jq is not installed."
command -v docker >/dev/null 2>&1 || die "docker is not installed."

# ---- 1. Scan the image with Trivy -----------------------------------------
log "Scanning image: ${IMAGE_NAME}"

trivy image \
    --exit-code 0 \
    --format json \
    --output "$IMAGE_REPORT" \
    --scanners vuln,secret \
    --ignore-unfixed \
    "${IMAGE_NAME}"

log "Trivy image scan complete: $(jq '.Results | length' "$IMAGE_REPORT") result blocks."

# ---- 2. Generate SBOM with syft -------------------------------------------
log "Generating SBOM with syft..."

syft "${IMAGE_NAME}" \
    --output "json=${SBOM_FILE}" \
    --quiet

log "SBOM generated: $(jq '.artifacts | length' "$SBOM_FILE") packages."

# ---- 3. Import Trivy image scan into DefectDojo ---------------------------
log "Importing Trivy image scan into DefectDojo..."

export DEFECTDOJO_SCAN_FILE="$IMAGE_REPORT"
export DEFECTDOJO_SCAN_TYPE="Trivy Scan"
export DEFECTDOJO_TEST_TITLE="Trivy Image Scan"

bash /opt/devsecops/scripts/defectdojo_import.sh

log "Done."