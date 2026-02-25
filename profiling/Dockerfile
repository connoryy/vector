FROM rust:bookworm

# System deps: vector build tools + perf + openssl + python3-yaml for config extraction
RUN apt-get update && apt-get install -y \
    bpftrace \
    cmake \
    libssl-dev \
    libsasl2-dev \
    pkg-config \
    protobuf-compiler \
    python3 \
    python3-yaml \
    perl \
    socat \
    openssl \
    linux-perf \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Inject corporate CA certs (exported from macOS keychain by setup.sh).
# This is needed when behind an SSL inspection proxy so that cargo can reach crates.io.
COPY corp-ca-bundle.pem /usr/local/share/ca-certificates/corp.crt
RUN update-ca-certificates
ENV CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt

# inferno for generating flamegraphs from perf output
RUN cargo install inferno

COPY profile.sh /profiling/profile.sh
COPY label-profile.bt /profiling/label-profile.bt
COPY scripts/ /profiling/scripts/
RUN chmod +x /profiling/profile.sh /profiling/scripts/*.py

WORKDIR /vector
