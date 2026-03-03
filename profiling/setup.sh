#!/bin/bash
# Exports CA certs from the macOS keychain into corp-ca-bundle.pem so the
# Docker image can trust corporate SSL inspection proxies during cargo installs.
set -e

OUT="$(dirname "$0")/corp-ca-bundle.pem"

echo "Exporting CA certs from macOS keychains..."

security find-certificate -a -p /Library/Keychains/System.keychain > "$OUT" 2>/dev/null || true
security find-certificate -a -p ~/Library/Keychains/login.keychain-db >> "$OUT" 2>/dev/null || true

count=$(grep -c "BEGIN CERTIFICATE" "$OUT" 2>/dev/null || echo 0)
echo "Exported $count certificates to corp-ca-bundle.pem"
echo "Run 'make profile' (or 'docker compose up --build') to build the image."
