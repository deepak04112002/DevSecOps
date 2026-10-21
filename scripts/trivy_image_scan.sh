#!/usr/bin/env bash
# scripts/trivy_image_scan.sh
#
# Scans a container image with Trivy, generates an SBOM with Syft, and imports
# the Trivy results into DefectDojo. The Security Policy Gate makes the
# pass/fail decision, so Trivy runs with --exit-code 0.
#
# Required environment:
#   IMAGE_REF             Image to scan.
#                         IMAGE_SRC=remote: digest reference (repo@sha256:...)
#                         IMAGE_SRC=docker: local image ID (sha256:...)
#   DEFECTDOJO_API_TOKEN  Used by defectdojo_import.sh
#
# Optional environment:
#   IMAGE_SRC              remote | docker            default: remote
#   TRIVY_IGNORE_UNFIXED   true | false               default: true
#   TRIVY_CACHE_DIR        Trivy DB cache directory   default: .trivy-cache
#   REPORT_DIR             default: artifacts/trivy-image
#   SBOM_DIR               default: artifacts/sbom
#   DEFECTDOJO_TEST_TITLE  default: Trivy Image Scan
#   TRIVY_USERNAME / TRIVY_PASSWORD   registry credentials for private images
#
# Outputs:
#   $REPORT_DIR/trivy-image-report.json
#   $SBOM_DIR/sbom.json
# ---------------------------------------------------------------------------
set -Eeuo pipefail

IMAGE_REF="${IMAGE_REF:-}"
IMAGE_SRC="${IMAGE_SRC:-remote}"
TRIVY_IGNORE_UNFIXED="${TRIVY_IGNORE_UNFIXED:-true}"
TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-.trivy-cache}"
REPORT_DIR="${REPORT_DIR:-artifacts/trivy-image}"
SBOM_DIR="${SBOM_DIR:-artifacts/sbom}"
DEFECTDOJO_TEST_TITLE="${DEFECTDOJO_TEST_TITLE:-Trivy Image Scan}"
IMPORT_SCRIPT="/opt/devsecops/scripts/defectdojo_import.sh"

IMAGE_REPORT="$REPORT_DIR/trivy-image-report.json"
SBOM_FILE="$SBOM_DIR/sbom.json"

log() { printf '[trivy-image] %s\n' "$*"; }
die() { printf '[trivy-image] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- Preflight -------------------------------------------------------------
[ -n "$IMAGE_REF" ] || die "IMAGE_REF is not set."
[ -n "${DEFECTDOJO_API_TOKEN:-}" ] || die "DEFECTDOJO_API_TOKEN is not set."

case "$IMAGE_SRC" in
    remote)
        [[ "$IMAGE_REF" =~ @sha256:[a-f0-9]{64}$ ]] ||
            die "IMAGE_SRC=remote requires a digest reference (repo@sha256:...). Got: $IMAGE_REF"
        ;;
    docker)
        ;;
    *)
        die "IMAGE_SRC must be 'remote' or 'docker'. Got: $IMAGE_SRC"
        ;;
esac

case "$TRIVY_IGNORE_UNFIXED" in
    true|false) ;;
    *) die "TRIVY_IGNORE_UNFIXED must be 'true' or 'false'." ;;
esac

for tool in trivy syft jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed."
done
[ -f "$IMPORT_SCRIPT" ] || die "Import script not found: $IMPORT_SCRIPT"

mkdir -p "$REPORT_DIR" "$SBOM_DIR" "$TRIVY_CACHE_DIR"
rm -f "$IMAGE_REPORT" "$SBOM_FILE"

# ---- 1. Trivy image scan ---------------------------------------------------
trivy_args=(
    image
    --image-src "$IMAGE_SRC"
    --scanners vuln,secret
    --exit-code 0
    --format json
    --output "$IMAGE_REPORT"
    --cache-dir "$TRIVY_CACHE_DIR"
)
if [ "$TRIVY_IGNORE_UNFIXED" = "true" ]; then
    trivy_args+=(--ignore-unfixed)
fi

log "Scanning $IMAGE_REF (source: $IMAGE_SRC)..."
trivy "${trivy_args[@]}" "$IMAGE_REF"

jq -e 'type == "object"' "$IMAGE_REPORT" >/dev/null || die "Trivy produced invalid JSON."

vuln_count="$(jq '[.Results[]? | .Vulnerabilities[]?] | length' "$IMAGE_REPORT")"
secret_count="$(jq '[.Results[]? | .Secrets[]?] | length' "$IMAGE_REPORT")"
log "Trivy complete: ${vuln_count} vulnerability finding(s), ${secret_count} secret finding(s)."

# ---- 2. SBOM with Syft -----------------------------------------------------
if [ "$IMAGE_SRC" = "remote" ]; then
    syft_source="registry:${IMAGE_REF}"
else
    syft_source="docker:${IMAGE_REF}"
fi

log "Generating SBOM..."
syft "$syft_source" --output "json=${SBOM_FILE}" --quiet

jq -e '.artifacts | type == "array"' "$SBOM_FILE" >/dev/null || die "Syft produced invalid SBOM JSON."
pkg_count="$(jq '.artifacts | length' "$SBOM_FILE")"
log "SBOM complete: ${pkg_count} package(s)."

# ---- 3. Import Trivy results into DefectDojo -------------------------------
log "Importing Trivy results into DefectDojo..."
DEFECTDOJO_SCAN_FILE="$IMAGE_REPORT" \
DEFECTDOJO_SCAN_TYPE="Trivy Scan" \
DEFECTDOJO_TEST_TITLE="$DEFECTDOJO_TEST_TITLE" \
    bash "$IMPORT_SCRIPT" || die "DefectDojo import failed."

log "Done. Report: ${IMAGE_REPORT}  SBOM: ${SBOM_FILE}"