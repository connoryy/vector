#!/usr/bin/env bash
# =============================================================================
# setup-cluster.sh -- Stand up the full Vector profiling environment in minikube
#
# Creates a minikube cluster, builds Docker images, and deploys all components.
#
# Environment variables:
#   MINIKUBE_CPUS       CPU count for minikube (default: 4)
#   MINIKUBE_MEMORY     Memory in MB for minikube (default: 8192)
#   MINIKUBE_PROFILE    Minikube profile name (default: vector-profiling)
#   SKIP_VECTOR_BUILD   If set to "1", skip building the Vector image
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROFILING_DIR="${SCRIPT_DIR}/.."
K8S_DIR="${PROFILING_DIR}/k8s"

MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8192}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-vector-profiling}"
SKIP_VECTOR_BUILD="${SKIP_VECTOR_BUILD:-0}"

source "${SCRIPT_DIR}/../tests/lib.sh"

# ---------------------------------------------------------------------------
# 1. Start minikube
# ---------------------------------------------------------------------------
log_info "Starting minikube profile '${MINIKUBE_PROFILE}' (cpus=${MINIKUBE_CPUS}, memory=${MINIKUBE_MEMORY}MB)..."

if minikube status -p "${MINIKUBE_PROFILE}" &>/dev/null; then
    log_info "Minikube profile '${MINIKUBE_PROFILE}' is already running"
else
    minikube start \
        --profile="${MINIKUBE_PROFILE}" \
        --cpus="${MINIKUBE_CPUS}" \
        --memory="${MINIKUBE_MEMORY}" \
        --driver=docker \
        --kubernetes-version=stable

    log_info "Minikube started successfully"
fi

# Point shell to minikube's Docker daemon
eval "$(minikube -p "${MINIKUBE_PROFILE}" docker-env)"

# ---------------------------------------------------------------------------
# 2. Create namespace
# ---------------------------------------------------------------------------
log_info "Creating namespace..."
kubectl apply -f "${K8S_DIR}/namespace.yaml"

# ---------------------------------------------------------------------------
# 3. Build Docker images
# ---------------------------------------------------------------------------
if [[ "${SKIP_VECTOR_BUILD}" != "1" ]]; then
    log_info "Building Vector image..."
    "${SCRIPT_DIR}/build-vector.sh"
else
    log_info "Skipping Vector build (SKIP_VECTOR_BUILD=1)"
fi

log_info "Building mock-loki image..."
docker build -t mock-loki:latest "${PROFILING_DIR}/mock-loki/"

# ---------------------------------------------------------------------------
# 4. Deploy all components
# ---------------------------------------------------------------------------
log_info "Deploying MinIO..."
kubectl apply -f "${K8S_DIR}/minio/deployment.yaml"

log_info "Deploying mock-loki..."
kubectl apply -f "${K8S_DIR}/mock-loki/configmap.yaml"
kubectl apply -f "${K8S_DIR}/mock-loki/deployment.yaml"

log_info "Deploying Prometheus..."
kubectl apply -f "${K8S_DIR}/prometheus/configmap.yaml"
kubectl apply -f "${K8S_DIR}/prometheus/deployment.yaml"

log_info "Deploying Vector RBAC..."
kubectl apply -f "${K8S_DIR}/vector-daemonset/rbac.yaml"

log_info "Deploying Vector DaemonSet..."
if [[ -f "${K8S_DIR}/vector-daemonset/configmap.yaml" ]]; then
    kubectl apply -f "${K8S_DIR}/vector-daemonset/configmap.yaml"
fi
kubectl apply -f "${K8S_DIR}/vector-daemonset/service.yaml"
kubectl apply -f "${K8S_DIR}/vector-daemonset/daemonset.yaml"

log_info "Deploying Vector Aggregator..."
if [[ -f "${K8S_DIR}/vector-aggregator/configmap.yaml" ]]; then
    kubectl apply -f "${K8S_DIR}/vector-aggregator/configmap.yaml"
fi
kubectl apply -f "${K8S_DIR}/vector-aggregator/service.yaml"
kubectl apply -f "${K8S_DIR}/vector-aggregator/statefulset.yaml"

# Deploy test-log-producer if manifest exists
if [[ -d "${K8S_DIR}/test-log-producer" ]]; then
    log_info "Deploying test-log-producer..."
    for f in "${K8S_DIR}/test-log-producer"/*.yaml; do
        kubectl apply -f "$f"
    done
fi

# ---------------------------------------------------------------------------
# 5. Wait for all pods to be ready
# ---------------------------------------------------------------------------
log_info "Waiting for all components to become ready..."

kube_wait_ready "${LABEL_MINIO}" "120s" || log_warn "MinIO not ready within timeout"
kube_wait_ready "${LABEL_LOKI}" "120s" || log_warn "mock-loki not ready within timeout"
kube_wait_ready "app.kubernetes.io/name=prometheus" "120s" || log_warn "Prometheus not ready within timeout"
kube_wait_ready "${LABEL_DS}" "180s" || log_warn "Vector DaemonSet not ready within timeout"
kube_wait_ready "${LABEL_AGG}" "180s" || log_warn "Vector Aggregator not ready within timeout"

log_info "============================================="
log_info "  Vector profiling cluster is ready!"
log_info "  Profile: ${MINIKUBE_PROFILE}"
log_info "============================================="
log_info ""
log_info "Useful commands:"
log_info "  kubectl -n profiling get pods"
log_info "  minikube -p ${MINIKUBE_PROFILE} dashboard"
