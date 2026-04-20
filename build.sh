#!/bin/bash
set -euo pipefail

# Repository root = directory of this script (works when cwd is not the monorepo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER_USER="${DOCKER_USER:-imkolganov}"
# Image: ${DOCKER_USER}/${IMAGE_PREFIX}-<service>. Default matches docker-compose*.yml; override when retagging.
IMAGE_PREFIX="${IMAGE_PREFIX:-datagate-monitor}"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"
BUILDER_NAME="${BUILDER_NAME:-multiarch-builder}"
FRONT_TAG="${FRONT_TAG:-latest}"
# Frontend: multi-arch is slow on x86 (QEMU for arm64). For a fast local push use:
#   FRONTEND_PLATFORMS=linux/amd64 ./build.sh frontend
FRONTEND_PLATFORMS="${FRONTEND_PLATFORMS:-linux/amd64,linux/arm64}"

ALL_SERVICES=("backend" "telegrambot" "openvpn" "frontend")

docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1 || {
  echo "🧱 Creating buildx builder '${BUILDER_NAME}'..."
  docker buildx create --name "${BUILDER_NAME}" --use
  docker buildx inspect --bootstrap
}

build_and_push_dotnet() {
  local SERVICE=$1
  local CONTEXT="${REPO_ROOT}/${SERVICE}"
  local DOCKERFILE="${CONTEXT}/Dockerfile"
  local IMAGE_NAME="${DOCKER_USER}/${IMAGE_PREFIX}-${SERVICE}"

  if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "❌ Missing Dockerfile: ${DOCKERFILE}"
    exit 1
  fi

  for ARCH in amd64 arm64; do
    local TARGETARCH
    [[ "$ARCH" == "amd64" ]] && TARGETARCH=x64 || TARGETARCH=arm64

    echo "🚀 Building ${SERVICE} for ${ARCH}..."
    docker buildx build \
      --platform "linux/${ARCH}" \
      --build-arg "TARGETARCH=${TARGETARCH}" \
      --build-arg "BUILD_CONFIGURATION=${BUILD_CONFIG}" \
      -f "${DOCKERFILE}" \
      -t "${IMAGE_NAME}:${ARCH}" \
      --push \
      "${CONTEXT}"
  done

  echo "🔗 Creating multi-arch manifest for ${SERVICE}..."
  docker buildx imagetools create \
    --tag "${IMAGE_NAME}:latest" \
    "${IMAGE_NAME}:amd64" \
    "${IMAGE_NAME}:arm64"

  echo "✅ ${SERVICE} built and pushed as: ${IMAGE_NAME}:latest"
}

build_and_push_frontend() {
  local CONTEXT="${REPO_ROOT}/frontend"
  local DOCKERFILE="${CONTEXT}/Dockerfile"
  local IMAGE_NAME="${DOCKER_USER}/${IMAGE_PREFIX}-frontend"

  if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "❌ Missing Dockerfile: ${DOCKERFILE}"
    exit 1
  fi

  echo "🎨 Building frontend for: ${FRONTEND_PLATFORMS}"
  docker buildx build \
    --platform "${FRONTEND_PLATFORMS}" \
    -f "${DOCKERFILE}" \
    -t "${IMAGE_NAME}:${FRONT_TAG}" \
    --push \
    "${CONTEXT}"
  echo "✅ Frontend built and pushed as: ${IMAGE_NAME}:${FRONT_TAG}"
}

# If no args -> build all
if [[ $# -eq 0 ]]; then
  SERVICES=("${ALL_SERVICES[@]}")
else
  SERVICES=("$@")
fi

for SVC in "${SERVICES[@]}"; do
  case "$SVC" in
    backend|telegrambot|openvpn) build_and_push_dotnet "$SVC" ;;
    frontend) build_and_push_frontend ;;
    *)
      echo "❌ Unknown service: $SVC"
      echo "Allowed: ${ALL_SERVICES[*]}"
      exit 1
      ;;
  esac
done
