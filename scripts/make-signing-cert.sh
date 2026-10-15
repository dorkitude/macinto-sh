#!/bin/bash
# Creates a self-signed code signing certificate named "macinto local signing" in the login keychain.
# A stable signature keeps macOS privacy grants (Accessibility, Screen Recording) across rebuilds;
# ad-hoc signatures change on every build and macOS forgets the grants.
set -euo pipefail

NAME="${1:-macinto local signing}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "certificate \"$NAME\" already exists in $KEYCHAIN"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.cnf" 2>/dev/null
pass=$(openssl rand -hex 16)
# Legacy PBE/MAC algorithms: what security(1) can import.
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$tmp/cert.p12" -passout "pass:$pass"
security import "$tmp/cert.p12" -k "$KEYCHAIN" -P "$pass" -f pkcs12 -T /usr/bin/codesign
echo "imported \"$NAME\" into $KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME" || true
