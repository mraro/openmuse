#!/usr/bin/env bash
# Runs on the VPS. Pulls the images for IMAGE_TAG and restarts the stack.
#   ./deploy.sh              redeploy the tag recorded in .deploy.env
#   ./deploy.sh <tag>        deploy (or roll back to) another pushed tag
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "Missing $(pwd)/.env. Copy .env.production.example and fill it in." >&2
  exit 1
fi
touch .deploy.env
if [ -n "${1:-}" ]; then
  sed -i '/^IMAGE_TAG=/d' .deploy.env
  echo "IMAGE_TAG=$1" >> .deploy.env
fi

compose() { docker compose --env-file .env --env-file .deploy.env -f compose.prod.yaml "$@"; }
# Tolerate a failed pull so a rollback can use an image already on the VPS.
compose pull --ignore-pull-failures
compose up -d --remove-orphans --wait --wait-timeout 180
# Keep a week of old images for quick rollbacks.
docker image prune -af --filter until=168h >/dev/null
compose ps
