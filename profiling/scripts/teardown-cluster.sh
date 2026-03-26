#!/usr/bin/env bash
# =============================================================================
# teardown-cluster.sh -- Tear down the Vector profiling minikube cluster
#
# Interactive: prompts for confirmation before deleting.
#
# Environment variables:
#   MINIKUBE_PROFILE    Minikube profile name (default: vector-profiling)
#   FORCE               Set to "1" to skip confirmation prompt
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-vector-profiling}"
FORCE="${FORCE:-0}"

if ! minikube status -p "${MINIKUBE_PROFILE}" &>/dev/null; then
    log_info "Minikube profile '${MINIKUBE_PROFILE}' is not running. Nothing to tear down."
    exit 0
fi

log_warn "This will DELETE the minikube profile '${MINIKUBE_PROFILE}' and ALL its data."

if [[ "${FORCE}" != "1" ]]; then
    read -r -p "Are you sure you want to proceed? [y/N] " response
    case "${response}" in
        [yY][eE][sS]|[yY])
            log_info "Proceeding with teardown..."
            ;;
        *)
            log_info "Aborted."
            exit 0
            ;;
    esac
fi

log_info "Deleting minikube profile '${MINIKUBE_PROFILE}'..."
minikube delete -p "${MINIKUBE_PROFILE}"

log_info "Minikube profile '${MINIKUBE_PROFILE}' has been deleted."
