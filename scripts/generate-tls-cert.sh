#!/bin/bash
set -e

# General-purpose TLS certificate generator using a Root CA.
#
# Usage:
#   ./scripts/generate-tls-cert.sh [OPTIONS]
#
# Options:
#   -n, --name       Service name / CN (default: service)
#   -d, --dir        Output directory (default: ./storage/<name>/certs)
#   -c, --ca-dir     CA directory (default: ./storage/ca)
#   --ca-only        Only generate the Root CA (skip service cert)
#   -s, --sans       Comma-separated SANs: DNS names and/or IPs
#                    e.g. "DNS:minio,DNS:localhost,IP:127.0.0.1"
#   -b, --bits       RSA key size in bits (default: 2048)
#   -e, --days       Certificate validity in days (default: 3650)
#   -o, --org        Organization name (default: LocalDev)
#   -h, --help       Show this help
#
# Examples:
#   # Generate only the Root CA
#   ./scripts/generate-tls-cert.sh --ca-only
#
#   # Generate Root CA and MinIO certificate
#   ./scripts/generate-tls-cert.sh --name minio --dir storage/minio/certs \
#     --sans "DNS:minio,DNS:localhost,IP:127.0.0.1"

# ── Defaults ────────────────────────────────────────────────────────────────
NAME="service"
DIR=""
CA_DIR="./storage/ca"
CA_ONLY=false
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
    -n|--name)   NAME="$2";   shift 2 ;;
    -d|--dir)    DIR="$2";    shift 2 ;;
    -c|--ca-dir) CA_DIR="$2"; shift 2 ;;
    --ca-only)   CA_ONLY=true; shift ;;
    -s|--sans)   SANS="$2";   shift 2 ;;
    -b|--bits)   BITS="$2";   shift 2 ;;
    -e|--days)   DAYS="$2";   shift 2 ;;
    -o|--org)    ORG="$2";    shift 2 ;;
    -h|--help)   usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Default output dir based on name if not specified
DIR="${DIR:-./storage/${NAME}/certs}"

mkdir -p "$CA_DIR"

echo "=============================================="
echo "  TLS Certificate Generator (CA-signed)"
echo "=============================================="
if [ "$CA_ONLY" = true ]; then
  echo "  Mode:        Root CA Only"
else
  echo "  Name (CN):   $NAME"
  echo "  Output dir:  $DIR"
fi
echo "  CA dir:      $CA_DIR"
echo "  Key bits:    $BITS"
echo "  Valid days:  $DAYS"
echo "  Org:         $ORG"
if [ "$CA_ONLY" = false ]; then
  echo "  SANs:        ${SANS:-"(none — CN only)"}"
fi
echo "=============================================="
echo ""

# ── Ensure Root CA exists ───────────────────────────────────────────────────
CA_KEY="${CA_DIR}/ca.key"
CA_CRT="${CA_DIR}/ca.crt"

if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  echo "Generating new Root CA in $CA_DIR..."
  openssl genrsa -out "$CA_KEY" "$BITS"
  openssl req -x509 -new -nodes -key "$CA_KEY" \
    -sha256 -days "$DAYS" -out "$CA_CRT" \
    -subj "/CN=${ORG} Root CA/O=${ORG}/C=US"
  chmod 600 "$CA_KEY"
  chmod 644 "$CA_CRT"
  echo "Root CA created successfully."
else
  echo "Using existing Root CA from $CA_DIR"
fi

# Exit early if only CA generation was requested
if [ "$CA_ONLY" = true ]; then
  echo ""
  echo "Done! Root CA is ready at: $CA_DIR"
  exit 0
fi

# ── Build service certificate ───────────────────────────────────────────────
mkdir -p "$DIR"
KEY_FILE="${DIR}/private.key"
CERT_FILE="${DIR}/public.crt"
DEST_CA_FILE="${DIR}/ca.crt"
EXT_FILE=$(mktemp -t cert-ext)
CSR_FILE=$(mktemp -t cert-csr)

# ── Build OpenSSL extension config ──────────────────────────────────────────
cat > "$EXT_FILE" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[req_distinguished_name]
C  = US
ST = State
L  = City
O  = ${ORG}
CN = ${NAME}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = ${SANS:-DNS:${NAME}}

[v3_sign]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = ${SANS:-DNS:${NAME}}
EOF

# ── Generate private key ─────────────────────────────────────────────────────
echo "Generating ${BITS}-bit RSA private key..."
openssl genrsa -out "$KEY_FILE" "$BITS"

# ── Generate CSR ─────────────────────────────────────────────────────────────
echo "Generating Certificate Signing Request..."
openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" -config "$EXT_FILE" -extensions v3_req

# ── Sign certificate with Root CA ───────────────────────────────────────────
echo "Signing certificate with Root CA (valid ${DAYS} days)..."
openssl x509 -req -in "$CSR_FILE" \
  -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$CERT_FILE" -days "$DAYS" -sha256 \
  -extfile "$EXT_FILE" -extensions v3_sign

# Copy CA certificate to service directory
cp "$CA_CRT" "$DEST_CA_FILE"

# ── Set permissions ──────────────────────────────────────────────────────────
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"
chmod 644 "$DEST_CA_FILE"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "$EXT_FILE" "$CSR_FILE"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Done! Certificates written to: $DIR"
echo "  private.key  (mode 600)"
echo "  public.crt   (mode 644)"
echo "  ca.crt       (mode 644) - Root CA certificate"
echo ""
echo "Certificate details:"
openssl x509 -noout -subject -issuer -dates -ext subjectAltName -in "$CERT_FILE" 2>/dev/null \
  | sed 's/^/  /'

