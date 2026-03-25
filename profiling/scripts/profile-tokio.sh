#!/usr/bin/env bash
# =============================================================================
# profile-tokio.sh -- Port-forward tokio-console for async runtime introspection
#
# Starts a port-forward to the tokio-console gRPC endpoint on the specified
# Vector component and launches tokio-console.
#
# Usage: profile-tokio.sh [aggregator|daemonset]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

TARGET="${1:-aggregator}"
TOKIO_CONSOLE_PORT="${TOKIO_CONSOLE_PORT:-6669}"
LOCAL_PORT="${LOCAL_PORT:-6669}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
    POD_PREFIX="vector-aggregator"
else
    LABEL="${LABEL_DS}"
    POD_PREFIX="vector-daemonset"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
log_info "Setting up tokio-console for ${POD}..."

# Check if tokio-console is installed
if ! command -v tokio-console &>/dev/null; then
    log_error "tokio-console is not installed. Install it with:"
    log_error "  cargo install tokio-console"
    exit 1
fi

# Start port-forward
log_info "Port-forwarding ${POD}:${TOKIO_CONSOLE_PORT} -> localhost:${LOCAL_PORT}..."
kube port-forward "${POD}" "${LOCAL_PORT}:${TOKIO_CONSOLE_PORT}" &
PF_PID=$!
PORT_FORWARD_PIDS+=("${PF_PID}")

sleep 2

# Verify the port-forward is working
if ! kill -0 "${PF_PID}" 2>/dev/null; then
    log_error "Port-forward failed. Is tokio-console enabled in the Vector build?"
    log_error "Ensure the 'tokio-console' feature is compiled in and TOKIO_CONSOLE_BIND is set."
    exit 1
fi

log_info "Launching tokio-console connected to localhost:${LOCAL_PORT}..."
log_info "Press Ctrl+C to exit."

# Launch tokio-console (blocks until user exits)
tokio-console "http://localhost:${LOCAL_PORT}" || true

log_info "tokio-console session ended."
