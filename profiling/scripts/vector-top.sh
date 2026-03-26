#!/usr/bin/env bash
# =============================================================================
# vector-top.sh -- Port-forward Vector API and launch `vector top`
#
# Connects to the Vector gRPC API and launches the `vector top` command for
# real-time component-level metrics.
#
# Usage: vector-top.sh [aggregator|daemonset]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

TARGET="${1:-aggregator}"
API_PORT="${API_PORT:-8686}"
LOCAL_PORT="${LOCAL_PORT:-8686}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
else
    LABEL="${LABEL_DS}"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
log_info "Connecting to Vector API on pod ${POD}..."

# Check if vector CLI is available
if ! command -v vector &>/dev/null; then
    log_error "'vector' CLI not found in PATH."
    log_error "Install it or build it with: cargo build --release"
    exit 1
fi

# Start port-forward to the Vector API port
log_info "Port-forwarding ${POD}:${API_PORT} -> localhost:${LOCAL_PORT}..."
kube port-forward "${POD}" "${LOCAL_PORT}:${API_PORT}" &>/dev/null &
PF_PID=$!
PORT_FORWARD_PIDS+=("${PF_PID}")

sleep 2

if ! kill -0 "${PF_PID}" 2>/dev/null; then
    log_error "Port-forward failed. Is the API enabled on port ${API_PORT}?"
    exit 1
fi

log_info "Launching 'vector top' connected to localhost:${LOCAL_PORT}..."
log_info "Press 'q' to exit."

vector top --url "http://localhost:${LOCAL_PORT}/graphql" 2>/dev/null || \
vector top --url "http://localhost:${LOCAL_PORT}" 2>/dev/null || {
    log_error "vector top failed. The API may use gRPC instead of GraphQL."
    log_error "Try: vector top --url http://localhost:${LOCAL_PORT}"
}

log_info "vector top session ended."
