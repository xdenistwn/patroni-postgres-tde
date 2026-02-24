#!/bin/bash
# Compatibility wrapper — delegates to the general-purpose cert generator.
# Use generate-tls-cert.sh directly for other services.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/generate-tls-cert.sh" \
  --name minio \
  --dir ./storage/minio/certs \
  --sans "DNS:minio,DNS:localhost,IP:127.0.0.1" \
  "$@"
