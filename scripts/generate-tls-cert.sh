#!/bin/bash
set -e

# General-purpose self-signed TLS certificate generator.
#
# Usage:
#   ./scripts/generate-tls-cert.sh [OPTIONS]
#
# Options:
#   -n, --name       Service name / CN (default: service)
#   -d, --dir        Output directory (default: ./storage/<name>/certs)
#   -s, --sans       Comma-separated SANs: DNS names and/or IPs
#                    e.g. "DNS:minio,DNS:localhost,IP:127.0.0.1"
#   -b, --bits       RSA key size in bits (default: 2048)
#   -e, --days       Certificate validity in days (default: 3650)
#   -o, --org        Organization name (default: LocalDev)
#   -h, --help       Show this help
#
# Examples:
#   # MinIO (same as before)
#   ./scripts/generate-tls-cert.sh --name minio --dir storage/minio/certs \
#     --sans "DNS:minio,DNS:localhost,IP:127.0.0.1"
#
#   # Vault
#   ./scripts/generate-tls-cert.sh --name vault --dir storage/vault/certs \
#     --sans "DNS:vault,DNS:localhost,IP:127.0.0.1"
#
#   # pgBackRest dedicated cert
#   ./scripts/generate-tls-cert.sh --name pgbackrest --dir storage/pgbackrest/certs \
#     --sans "DNS:postgres-one,DNS:postgres-two,DNS:localhost"

# ── Defaults ────────────────────────────────────────────────────────────────
NAME="service"
DIR=""
SANS=""
BITS=2048
DAYS=3650
ORG="LocalDev"

# ── Argument parsing ─────────────────────────────────────────────────────────
usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)   NAME="$2";  shift 2 ;;
    -d|--dir)    DIR="$2";   shift 2 ;;
    -s|--sans)   SANS="$2";  shift 2 ;;
    -b|--bits)   BITS="$2";  shift 2 ;;
    -e|--days)   DAYS="$2";  shift 2 ;;
    -o|--org)    ORG="$2";   shift 2 ;;
    -h|--help)   usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Default output dir based on name if not specified
DIR="${DIR:-./storage/${NAME}/certs}"

mkdir -p "$DIR"

KEY_FILE="${DIR}/private.key"
CERT_FILE="${DIR}/public.crt"
EXT_FILE=$(mktemp /tmp/cert-ext-XXXXXX.cnf)

echo "=============================================="
echo "  TLS Certificate Generator"
echo "=============================================="
echo "  Name (CN):   $NAME"
echo "  Output dir:  $DIR"
echo "  Key bits:    $BITS"
echo "  Valid days:  $DAYS"
echo "  Org:         $ORG"
echo "  SANs:        ${SANS:-"(none — CN only)"}"
echo "=============================================="
echo ""

# ── Build OpenSSL extension config for SANs ──────────────────────────────────
cat > "$EXT_FILE" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions    = v3_req
prompt             = no

[req_distinguished_name]
C  = US
ST = State
L  = City
O  = ${ORG}
CN = ${NAME}

[v3_req]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

# Add SANs if provided
if [ -n "$SANS" ]; then
  echo "subjectAltName = ${SANS}" >> "$EXT_FILE"
else
  # Always include CN as a SAN (required by modern TLS clients)
  echo "subjectAltName = DNS:${NAME}" >> "$EXT_FILE"
fi

# ── Generate private key ─────────────────────────────────────────────────────
echo "Generating ${BITS}-bit RSA private key..."
openssl genrsa -out "$KEY_FILE" "$BITS" 2>/dev/null

# ── Generate self-signed certificate ────────────────────────────────────────
echo "Generating self-signed certificate (valid ${DAYS} days)..."
openssl req -new -x509 \
  -days "$DAYS" \
  -key "$KEY_FILE" \
  -out "$CERT_FILE" \
  -config "$EXT_FILE" \
  -extensions v3_req 2>/dev/null

# ── Set permissions ──────────────────────────────────────────────────────────
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "$EXT_FILE"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Done! Certificates written to: $DIR"
echo "  private.key  (mode 600)"
echo "  public.crt   (mode 644)"
echo ""
echo "Certificate details:"
openssl x509 -noout -subject -issuer -dates -ext subjectAltName -in "$CERT_FILE" 2>/dev/null \
  | sed 's/^/  /'
