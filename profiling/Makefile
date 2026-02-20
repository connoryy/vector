.PHONY: setup profile clean

# Run once to export your macOS keychain certs for the Docker image build
corp-ca-bundle.pem:
	./setup.sh

# Build image + run profiling (generates profiling/output/flamegraph.svg)
profile: corp-ca-bundle.pem
	docker compose up --build

clean:
	docker compose down --volumes
	rm -rf output corp-ca-bundle.pem
