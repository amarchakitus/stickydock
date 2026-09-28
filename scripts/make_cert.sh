#!/bin/zsh
# Sets up the code signing certificate used by build.sh, in your login keychain.
#
# Signing every build with the same certificate lets macOS keep StickyDock's
# Accessibility permission across updates. It does NOT remove Gatekeeper's
# "unverified developer" warning (that needs a paid Apple Developer ID).
#
# If ~/.stickydock-signing/signing.p12 exists (from an earlier run), it's reused so
# the signature stays the same; otherwise a new self-signed certificate is created
# there. Run once.
set -euo pipefail

NAME="StickyDock Local Signing"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
OUT="$HOME/.stickydock-signing"

if security find-identity -p codesigning "$LOGIN_KC" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already in your login keychain."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

if [[ -f "$OUT/signing.p12" && -f "$OUT/password.txt" ]]; then
    echo "Reusing existing certificate from $OUT"
    P12PASS=$(<"$OUT/password.txt")
    CREATED=0
else
    mkdir -p "$OUT"
    chmod 700 "$OUT"
    export P12PASS=$(openssl rand -hex 16)

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
        -name "$NAME" -out "$OUT/signing.p12" -passout env:P12PASS
    print -rn -- "$P12PASS" > "$OUT/password.txt"
    chmod 600 "$OUT/signing.p12" "$OUT/password.txt"
    CREATED=1
fi

# -T lets codesign use the key without a keychain prompt on every build.
security import "$OUT/signing.p12" -k "$LOGIN_KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
echo "Added \"$NAME\" to your login keychain."

if [[ $CREATED == 1 ]]; then
    cat <<EOF

To sign GitHub release builds with the same certificate, run from the repo:
  base64 -i "$OUT/signing.p12" | gh secret set SIGNING_CERT_P12
  gh secret set SIGNING_CERT_PASSWORD < "$OUT/password.txt"
EOF
fi
cat <<EOF

$OUT is a backup of the key. Keep it private, or move it into a password manager.
EOF
