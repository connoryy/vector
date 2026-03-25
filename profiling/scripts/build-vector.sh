#!/usr/bin/env bash
# =============================================================================
# build-vector.sh -- Build Vector Docker image using minikube's Docker daemon
#
# Expects the shell to be pointed at minikube's Docker daemon
# (via `eval $(minikube docker-env)`).
#
# Environment variables:
#   MINIKUBE_PROFILE    Minikube profile name (default: vector-profiling)
#   VECTOR_IMAGE_TAG    Docker image tag (default: vector:profiling)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROFILING_DIR="${SCRIPT_DIR}/.."

source "${SCRIPT_DIR}/../tests/lib.sh"

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-vector-profiling}"
VECTOR_IMAGE_TAG="${VECTOR_IMAGE_TAG:-vector:profiling}"

# Ensure we're using minikube's Docker daemon
if ! docker info 2>/dev/null | grep -q "minikube\|${MINIKUBE_PROFILE}"; then
    log_info "Switching to minikube Docker daemon for profile '${MINIKUBE_PROFILE}'..."
    eval "$(minikube -p "${MINIKUBE_PROFILE}" docker-env)"
fi

log_info "Building Vector image '${VECTOR_IMAGE_TAG}' from ${REPO_ROOT}..."
log_info "This may take several minutes on first build..."

docker build \
    -t "${VECTOR_IMAGE_TAG}" \
    -f "${PROFILING_DIR}/Dockerfile.vector" \
    "${REPO_ROOT}"

log_info "Vector image built successfully: ${VECTOR_IMAGE_TAG}"
docker images "${VECTOR_IMAGE_TAG%%:*}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
