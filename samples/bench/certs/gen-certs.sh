#!/usr/bin/env bash
#
# Generate the self-signed TLS fixture set used by every provider's TLS test.
# Produces a tiny PKI:
#
#   ca.crt / ca.key          — test Certificate Authority (signs the two below)
#   server.crt / server.key  — server cert, CN/SAN = localhost (one-way TLS)
#   client.crt / client.key  — client cert, signed by the CA (mutual TLS)
#
# These are TEST-ONLY, throwaway credentials. Never reuse them anywhere real.
# Re-run to regenerate; the committed PEMs are produced by this exact script so
# the Windows/Delphi build machine does not need openssl installed.
#
# Usage:  ./gen-certs.sh [output-dir]   (default: current directory)
set -euo pipefail

OUT="${1:-.}"
DAYS=3650                      # 10 years — fixtures should outlive the project
SUBJ_CA="/C=US/O=Horse-TLS-Test/CN=Horse Test CA"
SUBJ_SRV="/C=US/O=Horse-TLS-Test/CN=localhost"
SUBJ_CLI="/C=US/O=Horse-TLS-Test/CN=horse-test-client"

mkdir -p "$OUT"
cd "$OUT"

echo "==> CA"
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -sha256 -days "$DAYS" \
  -subj "$SUBJ_CA" -out ca.crt

echo "==> server (SAN: localhost, 127.0.0.1, ::1)"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "$SUBJ_SRV" -out server.csr
cat > server.ext <<'EOF'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
DNS.1 = localhost
IP.1  = 127.0.0.1
IP.2  = ::1
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days "$DAYS" -sha256 -extfile server.ext -out server.crt

echo "==> client (for mutual TLS)"
openssl genrsa -out client.key 2048
openssl req -new -key client.key -subj "$SUBJ_CLI" -out client.csr
cat > client.ext <<'EOF'
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days "$DAYS" -sha256 -extfile client.ext -out client.crt

# Tidy intermediates — keep only the PEMs the tests consume.
rm -f server.csr server.ext client.csr client.ext ca.srl

echo
echo "Done. Fixtures in $(pwd):"
ls -1 ca.crt ca.key server.crt server.key client.crt client.key
