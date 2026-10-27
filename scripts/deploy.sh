#!/usr/bin/env bash
# deploy.sh <staging|production> <image-ref>
#
# Registers a new ECS task definition revision that uses <image-ref>
# and points the service at it. <image-ref> must be a digest reference
# (repo@sha256:...) so the deployed image is exactly the one scanned.
set -Eeuo pipefail
umask 077

ENV_NAME="${1:?Usage: deploy.sh <staging|production> <image-ref>}"
IMAGE_REF="${2:?Usage: deploy.sh <staging|production> <image-ref>}"

: "${AWS_REGION:?Set AWS_REGION}"
: "${CONTAINER_NAME:?Set CONTAINER_NAME}"

case "$ENV_NAME" in
    staging)
        CLUSTER="${ECS_CLUSTER_STAGING:?Set ECS_CLUSTER_STAGING}"
        SERVICE="${ECS_SERVICE_STAGING:?Set ECS_SERVICE_STAGING}"
        ;;
    production)
        CLUSTER="${ECS_CLUSTER_PRODUCTION:?Set ECS_CLUSTER_PRODUCTION}"
        SERVICE="${ECS_SERVICE_PRODUCTION:?Set ECS_SERVICE_PRODUCTION}"
        ;;
    *)
        echo "ERROR: environment must be staging or production." >&2
        exit 1
        ;;
esac

if [[ "$IMAGE_REF" != *"@sha256:"* ]]; then
    echo "ERROR: deploy requires a digest reference (repo@sha256:...)." >&2
    exit 1
fi

command -v aws >/dev/null || { echo "ERROR: aws CLI is required." >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq is required." >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Deploying ${IMAGE_REF} to ${ENV_NAME} (service ${SERVICE})..."

current_td="$(aws ecs describe-services \
    --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].taskDefinition' --output text)"

aws ecs describe-task-definition \
    --region "$AWS_REGION" --task-definition "$current_td" \
    --query taskDefinition --output json > "$tmpdir/td.json"

jq --arg image "$IMAGE_REF" --arg name "$CONTAINER_NAME" '
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
        .compatibilities, .registeredAt, .registeredBy)
    | .containerDefinitions |= map(if .name == $name then .image = $image else . end)
    | if ([.containerDefinitions[] | select(.name == $name)] | length) == 1
      then . else error("container " + $name + " not found") end
' "$tmpdir/td.json" > "$tmpdir/new-td.json"

new_td="$(aws ecs register-task-definition \
    --region "$AWS_REGION" --cli-input-json "file://$tmpdir/new-td.json" \
    --query taskDefinition.taskDefinitionArn --output text)"

aws ecs update-service \
    --region "$AWS_REGION" --cluster "$CLUSTER" --service "$SERVICE" \
    --task-definition "$new_td" >/dev/null

aws ecs wait services-stable \
    --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE"

echo "Deployed ${IMAGE_REF} to ${ENV_NAME}: ${new_td}"