#!/usr/bin/env bash
# Creates a free, self-signed code-signing identity in your login keychain and tells build-app.sh to use it.
# Why: macOS ties the Screen Recording permission to the app's signature. Ad-hoc builds get a new
# signature every time, so the permission resets on each rebuild; a stable identity keeps it.
# Usage: scripts/make-signing-cert.sh ["Certificate Name"]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-PrimeSnap Local Signing}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists in your keychain."
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  PASS="$(uuidgen)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  # OpenSSL 3 defaults to a PKCS#12 encryption macOS can't import; ask for the legacy one.
  LEGACY=()
  if openssl version | grep -q "^OpenSSL 3"; then
    LEGACY=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
  fi
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/id.p12" -passout "pass:$PASS" "${LEGACY[@]}"
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
  echo "Created \"$NAME\" in your login keychain."
fi

echo "$NAME" > scripts/.signing-identity
echo "build-app.sh will now sign with \"$NAME\". Grant Screen Recording once more after the next build."
