.PHONY: setup profile profile-realistic clean

# Run once to export your macOS keychain certs for the Docker image build
corp-ca-bundle.pem:
	./setup.sh

# Build image + run profiling (generates profiling/output/flamegraph.svg)
profile: corp-ca-bundle.pem
	docker compose up --build

# Like profile, but uses test-log-producer to generate realistic SLS log bytes
# (service.1, audit.2, event.2 envelopes) instead of synthetic demo_logs text.
#
# Prerequisites — run once before this target:
#   cd /path/to/test-log-producer
#   ./godelw build --os-arch linux-amd64
#   mkdir -p /path/to/vector/profiling/test-log-producer-bin
#   cp out/build/test-log-producer/linux-amd64/test-log-producer \
#      /path/to/vector/profiling/test-log-producer-bin/
profile-realistic: corp-ca-bundle.pem test-log-producer-bin/test-log-producer
	USE_TEST_LOG_PRODUCER=true docker compose --profile test-log-producer up --build

test-log-producer-bin/test-log-producer:
	@echo "ERROR: test-log-producer binary not found."
	@echo "Build it first:"
	@echo "  cd /path/to/test-log-producer && ./godelw build --os-arch linux-amd64"
	@echo "  mkdir -p profiling/test-log-producer-bin"
	@echo "  cp out/build/test-log-producer/linux-amd64/test-log-producer profiling/test-log-producer-bin/"
	@exit 1

clean:
	docker compose down --volumes
	rm -rf output corp-ca-bundle.pem
