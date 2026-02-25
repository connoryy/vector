# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
cargo build                          # dev build
make build-dev                       # dev build via make
make build                           # release build

# Check / lint (CI enforces these)
cargo fmt                            # format
cargo check                          # fast type-check
cargo vdev check rust                # clippy + fmt + deny
make check-all                       # everything (slow)

# Test
cargo nextest run                    # unit tests (preferred runner)
cargo nextest run sources::file      # single component
make test SCOPE="transforms::remap"  # via make with scope filter
make test-integration SCOPE="kafka"  # integration tests (spawns Docker services)
make test-vrl                        # VRL language tests

# Profiling
cd profiling && make profile         # docker+perf flamegraph (see profiling/)
```

`cargo vdev` is an alias for `cargo run --quiet --package vdev --` (defined in `.cargo/config.toml`). The `vdev` tool wraps most CI tasks — run `cargo vdev --help` for the full list.

Forbidden in source: `print!`, `println!`, `eprint!`, `eprintln!`, `dbg!` — all denied by clippy flags in `.cargo/config.toml`. Use `tracing::` instead.

## Architecture

Vector is a pipeline engine: **sources** ingest events → **transforms** process them → **sinks** emit them. The topology is built at startup from config and runs entirely on Tokio.

### Key crates

The workspace has ~30 crates. The most important:

| Crate | Path | Role |
|---|---|---|
| `vector` | `.` | Binary, topology wiring, CLI |
| `vector-core` | `lib/vector-core` | `Event`, `Value`, core traits (`SourceSender`, `Sink`) |
| `vector-lib` | `lib/vector-lib` | Re-exports + shared utilities used across components |
| `vector-config` | `lib/vector-config` | Derive macros + schema for component config structs |
| `vector-buffers` | `lib/vector-buffers` | Disk/memory buffers between topology nodes |
| `vector-vrl` | `lib/vector-vrl` | VRL runtime and stdlib |
| `vdev` | `vdev/` | Dev tooling (CI tasks, integration test orchestration) |

### Component structure

Every source/transform/sink lives under `src/{sources,transforms,sinks}/<name>/`. Each component must:
- Be behind a feature flag (e.g., `sources-kafka`) declared in root `Cargo.toml`
- Emit `InternalEvent` types defined in `src/internal_events/<name>.rs`
- Be registered via the inventory/component registry (`src/components/`)

Config structs use `#[configurable_component]` from `vector-config` which auto-generates schema and docs.

### Event model

`Event` (in `vector-core`) is the unit of data. It's an enum: `LogEvent`, `MetricEvent`, or `TraceEvent`. `LogEvent` wraps a `Value` (a recursive enum similar to `serde_json::Value`). VRL operates on `Value`.

### Config loading

`src/config/` handles loading → validation → topology building. Configs are TOML/YAML. The `src/topology/` module converts a validated config into a running Tokio task graph.

### Profiling setup

`profiling/` contains a Docker+perf setup for flamegraph profiling. See `profiling/Makefile`. Run `make setup` once (exports macOS CA certs) then `make profile`. The aggregator config is extracted from the Kubernetes ConfigMap at `profiling/config/cm.yaml`. The generator sends synthetic `service.1` SLS log events to exercise the full transform pipeline.

## Working Conventions

After every correction, update CLAUDE.md so the same mistake isn't repeated.

Parallelize work using subagents. Proactively use subagents to protect context window.

### Shell scripting pitfalls

- **`echo` inside command substitution is swallowed**: If a function emits diagnostics via `echo` and is called as `raw=$(fn)`, those echoes are captured into `raw`, not printed to the terminal. Use `echo "..." >&2` for any diagnostic/status output inside functions that are called via command substitution.
- **`curl | python3` exit code masking**: In a pipeline, exit code is the last command. If `curl` fails but `python3` succeeds on empty stdin, the `||` fallback never fires. Capture curl output to a variable first, check for empty, then pipe to python.
- **prometheus sink uses TLS**: The `prometheus-metrics` sink in cm.yaml has `tls.enabled: true`. Use `https://` + `--cacert /etc/ssl/rubix-ca/ca.pem` (profile.sh already generates this CA). Plain `http://` will always fail.
- **Allocation metrics are filtered out of prometheus**: `filtered-internal-metrics` has a hardcoded allowlist that does not include `component_allocated_bytes*`. profile.sh patches the config at startup. **Must parse the full YAML into a Python dict, modify the `condition.source` string directly, and re-serialize with `yaml.dump()`**. Raw string replacement on the YAML text silently fails because `yaml.safe_load()` normalizes whitespace/newlines so the extracted string never byte-matches the original.
- **`vector_` namespace prefix on prometheus metrics**: The `internal_metrics` source has `namespace: vector`, so all metrics in prometheus output are prefixed `vector_`. Match patterns must include this prefix (e.g. `vector_component_allocated_bytes`, not `component_allocated_bytes`).
- **DWARF vs frame-pointer unwinding**: `--call-graph dwarf,32768` is preferred over `--call-graph fp`. DWARF uses `.eh_frame` (present in all Rust release builds for panic handling) and can unwind through system libraries compiled without frame pointers, eliminating most `[unknown]` frames. The tradeoff is larger `perf.data` (~32KB per sample vs ~0 for fp). With DWARF, `-C force-frame-pointers=yes` is NOT needed and should be omitted (it only helps fp-based unwinding; keeping it wastes a register for nothing).
- **`perf script` output format without `[cpu]` brackets**: Some virtualized/Docker kernels emit `comm  tid  timestamp:  period  event:` instead of the standard `comm  pid  [cpu]  timestamp:` format. `collapse-labeled.py` has a `_HEADER_NO_CPU` regex fallback for this. Check the first lines of the perf script output if labeled stacks are unexpectedly empty.
- **`uretprobe` on function entry loses all arguments**: `uretprobe:binary:fn` fires when the function *returns* — registers holding arguments are clobbered by then. Must use `uprobe:binary:fn` to capture `arg0`, `arg1`, etc. Using `uretprobe` on `vector_component_enter` silently dropped the component name, so E events had only 3 fields and were skipped by the parser (which requires 4), leaving 100% "unknown" stacks.
- **BTF flexible arrays in bpftrace reject all index access**: `struct pid` has `struct upid numbers[]` (true flexible array since Linux 5.14); BTF exposes it as size 0, so bpftrace rejects `numbers[0]` and `numbers[1]` alike with "index N is out of bounds for array of size 0". Even wrapping in a conditional (`$level > 0 ? numbers[1].nr : tid`) doesn't help — the type checker runs before the condition. Use pointer arithmetic with hardcoded offsets: `sizeof(struct pid)` (== 112 on Linux 6.x ARM64) is exactly where `numbers[]` starts (flexible arrays don't contribute to sizeof), and `sizeof(struct upid)` (== 16) is the stride; so `numbers[1].nr` = `*(uint32 *)((uint64)$pid_ptr + 112 + sizeof(struct upid))`. `offsetof()` was added in bpftrace 0.18 — Debian Bookworm ships 0.16 and `offsetof()` fails with "Unknown function". Verify the 112 value for a new kernel with: `bpftrace -e 'BEGIN { printf("%d\n", sizeof(struct pid)); exit(); }'`.
- **`/proc/NSpid` from inside a container only shows the innermost level**: Reading `/proc/PID/status` from inside a Docker container shows `NSpid: 38` (container TID only), not `NSpid: 62103 38` (kernel + container). The outer kernel namespace TID is invisible from inside. Consequently bpftrace's `tid` builtin (kernel-namespace) never matches `perf script` output (container-namespace). Fix: in `label-profile.bt`, use `curtask->thread_pid->numbers[1].nr` (the level-1 container TID) instead of `tid`. Falls back to `tid` when `level == 0` (no PID namespace isolation).
- **Prometheus metric lines include an optional timestamp as the third field**: Format is `metric_name{labels} value [timestamp_ms]`. Always use `$2` (not `$NF`) in awk to get the value — `$NF` returns the timestamp (~1.7e12) when present, producing wildly wrong numbers. Similarly, sed patterns must not use `$` to anchor the value; use `[^}]*} \([0-9.eE+-]*\)` to match the value immediately after the closing `}`.

### vector-helm Dockerfile / Helm

- The Chainguard/Wolfi base image (`cgr.docker.palantir.build/palantir.com/vector`) uses `linux-tools` (not `perf` or `linux-perf`) for the Linux perf package.
- The Docker build is **CI-only** locally — the `virtualapk.cgr.dev` package registry requires corporate CA trust in the Docker daemon, which isn't configured on macOS by default. All packages fail locally; this is expected.
- The base image has `wget` and `pgrep` but NOT `curl`. Use `wget -q -O - --no-check-certificate --timeout=3 <url>` in `profile-k8s.sh` instead of `curl -sk`.
- Use `godelw helm template --mocks-to-test <mock>` to render charts locally, **not** `helm template -f mocks/foo.yaml` directly. The mocks alone are incomplete; `godelw` injects additional required Palantir values.

## Profiling (`profiling/`)

The `profiling/` directory contains a complete Docker+perf setup. Key files:
- `Makefile` — entry point: `make setup` (once, exports macOS CA certs) then `make profile` (synthetic) or `make profile-realistic` (test-log-producer)
- `Dockerfile` — Debian+Rust image with linux-perf, openssl, inferno; injects corp CA cert
- `Dockerfile.test-log-producer` — wraps the SLS scratch image in Debian so stdout can be redirected to the shared log volume
- `docker-compose.yml` — mounts `..:/vector` (source), named volumes for cargo/target cache, `--privileged` for perf; `test-log-producer` service behind Docker Compose profile
- `profile.sh` — extracts vector config from `config/cm.yaml` (K8s ConfigMap), generates TLS certs, builds vector if needed, runs aggregator + generator + perf, produces `output/flamegraph.svg`; set `USE_TEST_LOG_PRODUCER=true` to use test-log-producer instead of demo_logs
- `generator.yaml` — sends ~1000 synthetic `service.1` SLS events/sec (demo_logs mode)
- `test-log-producer-generator.yaml` — sends realistic `service.1`/`audit.2`/`event.2` SLS events from test-log-producer; enriches with `.sls.*` metadata that normally comes from the daemonset's `apollo-k8s-metadata` transform
- `test-log-producer-runtime.yml` — high-throughput config for test-log-producer (~1300 events/sec total, random content)
- `corp-ca-bundle.pem` — generated by `setup.sh` from macOS keychain; gitignored; needed for cargo to reach crates.io behind corporate SSL proxy

**Realistic profiling with test-log-producer**: `make profile-realistic` runs test-log-producer in a sidecar container (Docker Compose profile `test-log-producer`). Prerequisite: build the linux-amd64 binary once — `cd /path/to/test-log-producer && ./godelw build --os-arch linux-amd64 && cp out/build/test-log-producer/linux-amd64/test-log-producer profiling/test-log-producer-bin/` (directory is gitignored). test-log-producer writes `service.1`/`audit.2`/`event.2` JSON envelopes to stdout (witchcraft auto-detects Docker and writes to stdout), which is redirected to a shared volume at `/logs/sls.log`. Vector's `file` source reads this, an `enrich_for_aggregator` remap adds `.sls.*` metadata and `source_type="kubernetes_logs"`, then events flow to the aggregator — no message re-wrapping needed since the SLS envelope is already formed.

**Memory profiling**: Vector has built-in allocation tracking (`allocation-tracing` feature, compiled in with `unix`). Already enabled in `profile.sh` via `ALLOCATION_TRACING=true`. Emits `component_allocated_bytes_total` per component; flows through `filtered-internal-metrics → prometheus-metrics` sink at `:9598`. One env var, no rebuild needed.

**What the current workload tests**: Synthetic `service.1` SLS logs through `daemonset → in → sls-envelopes-unsafe → sls-redact-tokens → sls/sls-unsafe → sls-count-metric/sls-bytes-count-metric → prometheus-metrics`. Dead-end paths (Loki, infosec/Kafka sinks) are absent — their sinks live in other K8s resources not in `config/cm.yaml`. No back-pressure from sinks.

**What cm.yaml is**: The Palantir "timber-vector" production aggregator config. Processes SLS (Signals Logging Service) envelopes from daemonset agents. Key missing pieces vs production: `wrapped.1` logs (double JSON parse, more expensive), non-SLS path (3 extra remap transforms), `metric.1` path (15+ log_to_metric transforms), JWT regex hits (regex always misses on synthetic data), and actual Loki/Kafka sinks.

## vector-helm Integration Plan

The vector-helm repo (`/Volumes/git/vector-helm`) is a separate repo that packages the vector binary for k8s deployment.

**Key facts**:
- `docker/Dockerfile` uses a pre-built base image: `cgr.docker.palantir.build/palantir.com/vector:$VECTOR_VERSION-dev` — does NOT build vector from source
- The `-dev` variant build: `Cargo.toml` has `debug = false` in `[profile.release]`, so full DWARF debug info is NOT present. Function names are still readable (from `.symtab`) and stack unwinding works (via `.eh_frame` for Rust panic handling), but inlined functions are invisible in flamegraphs. CI may override this — check the build flags.
- The aggregator already runs `privileged: true` (`helm-charts/timber-vector-common/templates/aggregator/_deployment.tpl:248`) — perf works without security changes
- `MALLOC_CONF=background_thread:true` is already set in the deployment — add `prof:true` if jemalloc heap dumps ever needed

**CPU profiling in k8s (done)**:
- `docker/Dockerfile`: added `perf perl` to `apk add`; `profile-k8s.sh` copied to `/usr/local/bin/`
- `docker/profile-k8s.sh`: attaches perf to the running vector process (`pgrep -x vector`), saves `perf.data` + `stacks.txt` to `/tmp/profiling/`, generates `flamegraph.svg` if inferno is available
- Usage: `kubectl exec -it <pod> -n <ns> -- /usr/local/bin/profile-k8s.sh` then `kubectl cp <pod>:/tmp/profiling/stacks.txt ./stacks.txt -n <ns>` and generate flamegraph locally with `inferno-collapse-perf < stacks.txt | inferno-flamegraph > flamegraph.svg`
- `PROFILE_DURATION` env var controls duration (default 60s)

**Memory profiling in k8s (done)**:
- `helm-charts/timber-vector/values.yaml`: `aggregator.env` now sets `ALLOCATION_TRACING=true` and `ALLOCATION_TRACING_REPORTING_INTERVAL_MS=5000`
- Emits `component_allocated_bytes_total` per component; flows into the existing prometheus pipeline automatically

**NOT needed**: rebuilding vector from source in vector-helm's Dockerfile, changing VECTOR_VERSION, or moving the `profiling/` directory.
