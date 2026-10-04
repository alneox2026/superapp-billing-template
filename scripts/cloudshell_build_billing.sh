#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SuperApp Central Billing API — Cloud Shell Build Script
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-ceo-agent-repo}"
IMAGE_NAME="${IMAGE_NAME:-superapp-billing-api}"
TAG="${TAG:-latest}"

if [ -z "${PROJECT_ID}" ]; then
  echo "ERROR: PROJECT_ID is not set and could not be detected from gcloud config." >&2
  exit 1
fi

echo "================================================================="
echo " Building SuperApp Central Billing API"
echo " Project:    ${PROJECT_ID}"
echo " Region:     ${REGION}"
echo " Repository: ${REPOSITORY}"
echo " Image:      ${IMAGE_NAME}:${TAG}"
echo "================================================================="

# Ensure Artifact Registry repo exists
gcloud artifacts repositories describe "${REPOSITORY}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" >/dev/null 2>&1 || {
    echo "Creating Artifact Registry repository: ${REPOSITORY}..."
    gcloud artifacts repositories create "${REPOSITORY}" \
      --project="${PROJECT_ID}" \
      --repository-format=docker \
      --location="${REGION}" \
      --description="SuperApp Docker repository"
}

IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:${TAG}"

echo "--> Submitting Cloud Build for Billing API..."
gcloud builds submit "${ROOT_DIR}" \
  --project="${PROJECT_ID}" \
  --config=- <<EOF
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', '${IMAGE_TAG}', '-f', 'services/billing_api_v3/Dockerfile', '.']
images:
- '${IMAGE_TAG}'
EOF

echo "================================================================="
echo " Build Completed Successfully!"
echo " Image: ${IMAGE_TAG}"
echo "================================================================="
