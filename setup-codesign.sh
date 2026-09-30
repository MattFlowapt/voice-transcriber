#!/bin/bash
# ONE-TIME: creates a stable local code-signing certificate so macOS keeps its
# Accessibility grant across rebuilds.
#
# Why: an ad-hoc signature (`codesign -s -`) changes identity every time the app
# is recompiled, so macOS treats each build as a different app and silently drops
# the Accessibility permission — auto-paste breaks and has to be re-granted by
# hand. A real certificate keeps the identity stable, so the grant sticks forever.
#
# Run once:  ./setup-codesign.sh     then re-grant Accessibility one final time.
set -euo pipefail

CERT_NAME="Flowapt Local Codesign"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# NOTE: `-v` (valid identities) hides self-signed certs because they evaluate as
# CSSMERR_TP_NOT_TRUSTED — they still sign fine, so check the unfiltered list or
# this script creates a duplicate cert every run.
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "==> '$CERT_NAME' already exists — nothing to do."
  echo "    (build.sh picks it up by hash automatically.)"
  exit 0
fi

echo "==> Creating self-signed code-signing certificate '$CERT_NAME'"
cat > "$WORK/cs.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cs.conf" 2>/dev/null

openssl pkcs12 -export -out "$WORK/cs.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CERT_NAME" -passout pass:local

echo "==> Importing into your login keychain (may ask for your password)"
security import "$WORK/cs.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P local -A -T /usr/bin/codesign

echo
if security find-identity -p codesigning | grep -q "$CERT_NAME"; then
  echo "==> Done. '$CERT_NAME' is installed."
  echo "    ('not trusted' in the keychain is expected and harmless — it signs fine,"
  echo "     and that is all macOS needs to keep the Accessibility grant stable.)"
  echo
  echo "    Now run ./build.sh — it will use this identity automatically."
  echo "    Then re-grant Accessibility ONE more time; it will stick after that."
else
  echo "!! Certificate import failed — no '$CERT_NAME' identity found."
  echo "   Open Keychain Access > login > Certificates and check for it manually."
fi
