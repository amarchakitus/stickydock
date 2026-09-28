#!/bin/zsh
# Creates a self-signed code signing certificate and imports it into the login keychain.
#
# Signing every build with the same certificate lets macOS keep StickyDock's
# Accessibility permission across updates. It does NOT remove Gatekeeper's
# "unverified developer" warning (that needs a paid Apple Developer ID).
#
# A copy is saved to ~/.stickydock-signing/ so the same certificate can be added to
# GitHub Actions secrets for release builds. Keep that folder private. Run once.
set -euo pipefail

NAME="StickyDock Local Signing"
OUT="$HOME/.stickydock-signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Certificate \"$NAME\" already exists in your keychain."
    [[ -f "$OUT/signing.p12" ]] && echo "Exported copy: $OUT/signing.p12"
    exit 0
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(openssl rand -hex 16)

cat > "$TMP/cert.cnf" <<EOF
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
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

# -legacy: macOS's keychain can't read OpenSSL 3's default PKCS#12 encryption.
LEGACY=()
openssl version | grep -q "^OpenSSL 3" && LEGACY=(-legacy)
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$OUT/signing.p12" -passout "pass:$PASS"
print -rn -- "$PASS" > "$OUT/password.txt"
chmod 600 "$OUT/signing.p12" "$OUT/password.txt"

# -T lets codesign use the key without a keychain prompt on every build.
security import "$OUT/signing.p12" -k ~/Library/Keychains/login.keychain-db \
    -P "$PASS" -T /usr/bin/codesign

cat <<EOF
Created "$NAME" in your login keychain.
Saved a copy to $OUT (keep it private).

To sign GitHub release builds with the same certificate, run from the repo:
  base64 -i "$OUT/signing.p12" | gh secret set SIGNING_CERT_P12
  gh secret set SIGNING_CERT_PASSWORD < "$OUT/password.txt"
EOF
