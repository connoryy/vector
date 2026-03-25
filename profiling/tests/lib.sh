#!/usr/bin/env bash
# =============================================================================
# lib.sh -- Shared test library for Vector profiling tests
#
# Provides constants, helpers, test lifecycle, snapshot/delta assertions,
# producer management, memory and throughput measurement, and result writing.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Label constants -- match k8s manifests, NEVER hardcode app=vector-*
# ---------------------------------------------------------------------------
LABEL_DS="app.kubernetes.io/name=vector-daemonset"
LABEL_AGG="app.kubernetes.io/name=vector-aggregator"
LABEL_LOKI="app.kubernetes.io/name=mock-loki"
LABEL_MINIO="app.kubernetes.io/name=minio"
LABEL_PROMETHEUS="app.kubernetes.io/name=prometheus"
LABEL_PRODUCER="app.kubernetes.io/name=test-log-producer"

NAMESPACE="${NAMESPACE:-profiling}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../results" && pwd)}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
PORT_FORWARD_PIDS=()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    printf "[%s] [%-5s] %s\n" "$(date '+%Y-%m-%dT%H:%M:%S')" "$level" "$*" >&2
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

# ---------------------------------------------------------------------------
# Kubernetes helpers
# ---------------------------------------------------------------------------
kube() { kubectl -n "${NAMESPACE}" "$@"; }

kube_wait_ready() {
    local label="$1" timeout="${2:-120s}"
    log_info "Waiting for pods label=${label} ready (timeout ${timeout})"
    kube wait --for=condition=Ready pod -l "${label}" --timeout="${timeout}"
}

wait_vector_healthy() {
    local timeout="${1:-180s}"
    kube_wait_ready "${LABEL_DS}" "${timeout}"
    kube_wait_ready "${LABEL_AGG}" "${timeout}"
    kube_wait_ready "${LABEL_LOKI}" "${timeout}"
    log_info "Vector pipeline healthy"
}

# ---------------------------------------------------------------------------
# Test lifecycle
# ---------------------------------------------------------------------------
_CURRENT_TEST=""
_CURRENT_TEST_START=""

begin_test() {
    _CURRENT_TEST="${1:?test name required}"
    _CURRENT_TEST_START="$(date +%s)"
    log_info "===== BEGIN ${_CURRENT_TEST} ====="
}

end_test() {
    local status="${1:?pass or fail}"
    local elapsed=$(( $(date +%s) - _CURRENT_TEST_START ))
    log_info "===== END ${_CURRENT_TEST}: ${status^^} (${elapsed}s) ====="
    [[ "${status,,}" == "pass" ]] && exit 0 || exit 1
}

# ---------------------------------------------------------------------------
# Prometheus query
# ---------------------------------------------------------------------------
prom_query() {
    local query="$1"
    local encoded
    encoded="$(python3 -c "import urllib.parse as u; print(u.quote('${query}'))" 2>/dev/null || echo "${query}")"
    curl -sf "${PROMETHEUS_URL}/api/v1/query?query=${encoded}" \
      | python3 -c "
import json,sys
r=json.load(sys.stdin)
res=r.get('data',{}).get('result',[])
print(res[0]['value'][1] if res else '0')
" 2>/dev/null || echo "0"
}

prom_query_float() {
    python3 -c "print(float('$(prom_query "$1")'))" 2>/dev/null || echo "0.0"
}

# ---------------------------------------------------------------------------
# Pipeline snapshots -- return "ds_sent agg_received agg_sent loki_received"
# ---------------------------------------------------------------------------
snapshot_pipeline() {
    local ds_sent agg_recv agg_sent loki_recv
    ds_sent="$(prom_query_float 'sum(vector_component_sent_events_total{pod=~"vector-daemonset.*"})')"
    agg_recv="$(prom_query_float 'sum(vector_component_received_events_total{pod=~"vector-aggregator.*"})')"
    agg_sent="$(prom_query_float 'sum(vector_component_sent_events_total{pod=~"vector-aggregator.*"})')"
    loki_recv="$(prom_query_float 'mock_loki_events_received_total')"
    echo "${ds_sent} ${agg_recv} ${agg_sent} ${loki_recv}"
}

# ---------------------------------------------------------------------------
# Delta assertion -- before/after snapshots + tolerance percentage
# Usage: assert_no_drops_delta "${before}" "${after}" "TOLERANCE"
# ---------------------------------------------------------------------------
assert_no_drops_delta() {
    local before="$1" after="$2" tolerance="${3:-0}"
    python3 <<PYEOF
import sys
b = [float(x) for x in "${before}".split()]
a = [float(x) for x in "${after}".split()]
ds_sent  = a[0] - b[0]
loki_recv = a[3] - b[3]
tol = float(${tolerance})

if ds_sent <= 0:
    print("WARN: no events sent during test window", file=sys.stderr)
    sys.exit(1)

drop_pct = ((ds_sent - loki_recv) / ds_sent) * 100.0
print(f"Delta: sent={ds_sent:.0f} received={loki_recv:.0f} drop={drop_pct:.4f}% tolerance={tol}%")

if drop_pct > tol:
    print(f"FAIL: drop rate {drop_pct:.4f}% exceeds tolerance {tol}%", file=sys.stderr)
    sys.exit(1)
print("PASS: drop rate within tolerance")
PYEOF
}

# ---------------------------------------------------------------------------
# Producer management
# ---------------------------------------------------------------------------
deploy_producer() {
    local name="${1:-test-log-producer}" replicas="${2:-1}" rate="${3:-100}"
    local message="${4:-{\"level\":\"INFO\",\"message\":\"test event\",\"v\":1}}"
    cat <<EOYAML | kube apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/name: test-log-producer
    profiling.test/producer: "${name}"
  annotations:
    com.palantir.rubix.pod/sls-service-info-v2: '{"service":"${name}","product":"test-producer","productVersion":"1.0.0","stack":"profiling","entity":"${name}"}'
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      profiling.test/producer: "${name}"
  template:
    metadata:
      labels:
        app.kubernetes.io/name: test-log-producer
        profiling.test/producer: "${name}"
      annotations:
        com.palantir.rubix.pod/sls-service-info-v2: '{"service":"${name}","product":"test-producer","productVersion":"1.0.0","stack":"profiling","entity":"${name}"}'
    spec:
      containers:
        - name: producer
          image: busybox:1.36
          command: ["/bin/sh","-c"]
          args:
            - |
              while true; do
                echo '${message}'
                sleep \$(awk "BEGIN{printf \"%.6f\", 1/${rate}}")
              done
          resources:
            requests: {memory: 16Mi, cpu: 10m}
            limits:   {memory: 64Mi, cpu: 100m}
EOYAML
    log_info "Deployed ${name} replicas=${replicas} rate=${rate}/s"
}

cleanup_producers() {
    log_info "Cleaning up test-log-producer deployments"
    kube delete deploy -l app.kubernetes.io/name=test-log-producer --ignore-not-found --wait=false 2>/dev/null || true
}

scale_producer() {
    local name="${1:-test-log-producer}" replicas="${2:-1}"
    kube scale "deploy/${name}" --replicas="${replicas}"
    log_info "Scaled ${name} to ${replicas}"
}

# ---------------------------------------------------------------------------
# Memory helpers
# ---------------------------------------------------------------------------
get_pod_rss_kb() {
    local label="$1"
    local pod
    pod="$(kube get pods -l "${label}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    kube exec "${pod}" -- cat /proc/1/status 2>/dev/null | grep VmRSS | awk '{print $2}' || echo "0"
}

get_restart_count() {
    local label="$1"
    kube get pods -l "${label}" \
      -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# Throughput measurement -- returns events/sec float
# ---------------------------------------------------------------------------
measure_throughput_eps() {
    local duration="${1:-60}"
    local snap1 snap2
    snap1="$(prom_query_float 'mock_loki_events_received_total')"
    sleep "${duration}"
    snap2="$(prom_query_float 'mock_loki_events_received_total')"
    python3 -c "print((${snap2} - ${snap1}) / ${duration})"
}

# ---------------------------------------------------------------------------
# Sink fault injection
# ---------------------------------------------------------------------------
inject_sink_latency() {
    local ms="${1:-500}"
    kube patch configmap mock-loki-config --type=merge \
        -p "{\"data\":{\"RESPONSE_LATENCY_MS\":\"${ms}\"}}"
    kube rollout restart deployment/mock-loki
    kube rollout status deployment/mock-loki --timeout=60s
    log_info "mock-loki latency set to ${ms}ms"
}

reset_sink_config() {
    kube patch configmap mock-loki-config --type=merge \
        -p '{"data":{"RESPONSE_LATENCY_MS":"0","ERROR_RATE":"0.0"}}'
    kube rollout restart deployment/mock-loki
    kube rollout status deployment/mock-loki --timeout=60s
    log_info "mock-loki config reset"
}

# ---------------------------------------------------------------------------
# Result writing
# ---------------------------------------------------------------------------
write_result() {
    local test_name="$1" status="$2"
    local metric_name="${3:-}" metric_value="${4:-0}"
    local elapsed=$(( $(date +%s) - _CURRENT_TEST_START ))
    mkdir -p "${RESULTS_DIR}"
    python3 -c "
import json, datetime
r = {'test':'${test_name}','status':'${status}','elapsed_seconds':${elapsed},
     'timestamp':datetime.datetime.utcnow().isoformat()+'Z'}
if '${metric_name}':
    r['metric']='${metric_name}'; r['value']=${metric_value}
print(json.dumps(r,indent=2))
" > "${RESULTS_DIR}/${test_name}.json"
    log_info "Result: ${RESULTS_DIR}/${test_name}.json"
}

# ---------------------------------------------------------------------------
# Port-forward helpers
# ---------------------------------------------------------------------------
start_port_forward() {
    local resource="$1" local_port="$2" remote_port="$3"
    kube port-forward "${resource}" "${local_port}:${remote_port}" &>/dev/null &
    PORT_FORWARD_PIDS+=("$!")
    sleep 2
}

cleanup_port_forwards() {
    for pid in "${PORT_FORWARD_PIDS[@]:-}"; do
        kill "${pid}" 2>/dev/null || true
    done
    PORT_FORWARD_PIDS=()
}

trap cleanup_port_forwards EXIT

# ---------------------------------------------------------------------------
# Collect pipeline counts (JSON) -- backward compat alias for snapshot_pipeline
# ---------------------------------------------------------------------------
collect_pipeline_counts() {
    local ds_sent agg_recv agg_sent loki_recv
    ds_sent="$(prom_query_float 'sum(vector_component_sent_events_total{pod=~"vector-daemonset.*"})')"
    agg_recv="$(prom_query_float 'sum(vector_component_received_events_total{pod=~"vector-aggregator.*"})')"
    agg_sent="$(prom_query_float 'sum(vector_component_sent_events_total{pod=~"vector-aggregator.*"})')"
    loki_recv="$(prom_query_float 'mock_loki_events_received_total')"
    python3 -c "
import json
print(json.dumps({
    'ds_events_out': ${ds_sent},
    'agg_events_in': ${agg_recv},
    'agg_events_out': ${agg_sent},
    'loki_events': ${loki_recv}
}))
"
}

# ---------------------------------------------------------------------------
# assert_no_drops -- single-snapshot assertion
# Usage: assert_no_drops [THRESHOLD]  (default 0.99)
# ---------------------------------------------------------------------------
assert_no_drops() {
    local threshold="${1:-0.99}"
    local snap
    snap="$(snapshot_pipeline)"
    python3 <<PYEOF
import sys
vals = [float(x) for x in "${snap}".split()]
ds_sent, agg_recv, agg_sent, loki_recv = vals
threshold = float(${threshold})

ok = True
if ds_sent > 0 and agg_recv / ds_sent < threshold:
    print(f"FAIL: DS->AGG ratio {agg_recv/ds_sent:.4f} < {threshold}", file=sys.stderr)
    ok = False
if agg_recv > 0 and agg_sent / agg_recv < threshold:
    print(f"FAIL: AGG through ratio {agg_sent/agg_recv:.4f} < {threshold}", file=sys.stderr)
    ok = False
if not ok:
    sys.exit(1)
print("assert_no_drops: PASS")
PYEOF
}

# ---------------------------------------------------------------------------
# assert_memory_stable -- checks RSS growth stays within percent over duration
# Usage: assert_memory_stable LABEL DURATION [MAX_GROWTH_PERCENT]
# ---------------------------------------------------------------------------
assert_memory_stable() {
    local label="$1" duration="$2" max_growth="${3:-20}"
    log_info "Checking memory stability for ${label} over ${duration}s (max ${max_growth}%)"
    local start_rss end_rss
    start_rss="$(get_pod_rss_kb "${label}")"
    sleep "${duration}"
    end_rss="$(get_pod_rss_kb "${label}")"
    log_info "RSS: start=${start_rss}kB end=${end_rss}kB"
    python3 -c "
import sys
s, e, m = int(${start_rss}), int(${end_rss}), float(${max_growth})
if s == 0:
    print('WARN: could not read start RSS', file=sys.stderr); sys.exit(0)
g = ((e - s) / s) * 100
if g > m:
    print(f'FAIL: memory grew {g:.1f}% (limit {m}%)', file=sys.stderr); sys.exit(1)
print(f'assert_memory_stable: PASS (growth={g:.1f}%)')
"
}

# Alias for backward compatibility with profiling scripts
measure_throughput() { measure_throughput_eps "$@"; }

# ---------------------------------------------------------------------------
# inject_sink_errors -- sets error rate on mock-loki
# ---------------------------------------------------------------------------
inject_sink_errors() {
    local error_rate="${1:-0.1}"
    kube patch configmap mock-loki-config --type=merge \
        -p "{\"data\":{\"ERROR_RATE\":\"${error_rate}\"}}"
    kube rollout restart deployment/mock-loki
    kube rollout status deployment/mock-loki --timeout=60s
    log_info "mock-loki error rate set to ${error_rate}"
}

# ---------------------------------------------------------------------------
# Allocation tracing helpers
# ---------------------------------------------------------------------------
enable_allocation_tracing() {
    local target="${1:-aggregator}"
    log_info "Enabling allocation tracing on ${target}"
    if [[ "${target}" == "aggregator" ]]; then
        kube patch statefulset vector-aggregator --type=json \
            -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--allocation-tracing"}]'
        kube rollout status statefulset/vector-aggregator --timeout=120s
    else
        kube patch daemonset vector-daemonset --type=json \
            -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--allocation-tracing"}]'
        kube rollout status daemonset/vector-daemonset --timeout=120s
    fi
}

disable_allocation_tracing() {
    local target="${1:-aggregator}"
    log_info "Disabling allocation tracing on ${target}"
    local workload_type workload_name
    if [[ "${target}" == "aggregator" ]]; then
        workload_type="statefulset"; workload_name="vector-aggregator"
    else
        workload_type="daemonset"; workload_name="vector-daemonset"
    fi
    local current_args idx
    current_args=$(kube get "${workload_type}" "${workload_name}" -o jsonpath='{.spec.template.spec.containers[0].args}')
    idx=$(echo "${current_args}" | python3 -c "import json,sys; args=json.load(sys.stdin); print(args.index('--allocation-tracing'))" 2>/dev/null || echo "-1")
    if [[ "${idx}" != "-1" ]]; then
        kube patch "${workload_type}" "${workload_name}" --type=json \
            -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/args/${idx}\"}]"
        kube rollout status "${workload_type}/${workload_name}" --timeout=120s
    fi
}

# ---------------------------------------------------------------------------
# Component metric helpers
# ---------------------------------------------------------------------------
get_component_metric() {
    local metric="$1" filter="${2:-}"
    if [[ -n "${filter}" ]]; then
        prom_query "${metric}{${filter}}"
    else
        prom_query "${metric}"
    fi
}

assert_transform_active() {
    local component_id="$1" min_events="${2:-1}"
    local count
    count=$(get_component_metric "vector_component_received_events_total" "component_id=\"${component_id}\"")
    python3 -c "
import sys
c, m = float(${count}), float(${min_events})
if c < m:
    print(f'FAIL: transform ${component_id} has {c} events (need >= {m})', file=sys.stderr); sys.exit(1)
print(f'assert_transform_active: PASS (${component_id} has {c} events)')
"
}

# ---------------------------------------------------------------------------
# Aggregator config helpers
# ---------------------------------------------------------------------------
_AGG_CONFIG_BACKUP=""

patch_aggregator_config() {
    local config_file="$1"
    if [[ -z "${_AGG_CONFIG_BACKUP}" ]]; then
        _AGG_CONFIG_BACKUP=$(kube get configmap vector-aggregator-config -o yaml)
    fi
    log_info "Patching aggregator config from ${config_file}"
    kube create configmap vector-aggregator-config --from-file=vector.yaml="${config_file}" \
        --dry-run=client -o yaml | kube apply -f -
    kube rollout restart statefulset/vector-aggregator
    kube rollout status statefulset/vector-aggregator --timeout=120s
}

restore_aggregator_config() {
    if [[ -n "${_AGG_CONFIG_BACKUP}" ]]; then
        log_info "Restoring original aggregator config"
        echo "${_AGG_CONFIG_BACKUP}" | kube apply -f -
        kube rollout restart statefulset/vector-aggregator
        kube rollout status statefulset/vector-aggregator --timeout=120s
        _AGG_CONFIG_BACKUP=""
    else
        log_warn "No aggregator config backup found; skipping restore"
    fi
}

# ---------------------------------------------------------------------------
# configure_producer -- legacy helper, wraps deploy_producer
# Usage: configure_producer RATE [MSG_SIZE]
# ---------------------------------------------------------------------------
configure_producer() {
    local rate="$1" msg_size="${2:-256}"
    local msg
    msg=$(python3 -c "print('{\"level\":\"INFO\",\"msg\":\"' + 'x'*int(${msg_size}) + '\"}')" 2>/dev/null \
        || echo '{"level":"INFO","msg":"test"}')
    deploy_producer "test-log-producer" 1 "${rate}" "${msg}"
}
