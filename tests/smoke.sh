#!/usr/bin/env bash

set -Eeuo pipefail

: "${STAGING_BASE_URL:?Set STAGING_BASE_URL first}"

URL="${STAGING_BASE_URL%/}/"

echo "Running staging smoke test: ${URL}"

HTTP_STATUS="$(
    curl \
      --silent \
      --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --max-time 15 \
      "$URL"
)"

case "$HTTP_STATUS" in
    2*|3*)
        echo "Smoke test passed. HTTP status: $HTTP_STATUS"
        ;;
    *)
        echo "Smoke test failed. HTTP status: $HTTP_STATUS"
        exit 1
        ;;
esac