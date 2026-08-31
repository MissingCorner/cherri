#!/bin/bash
#
# Creates a self-signed code-signing certificate ("Cherri Dev") in your login
# keychain and trusts it for code signing. After this, `make app` signs with
# a STABLE identity, so the keychain asks about API-key access once ("Always
# Allow") and never again — even across rebuilds.
#
# macOS will show one or two password prompts while this runs; they are the
# system asking YOU to approve the trust change. Safe to re-run.

set -euo pipefail

NAME="Cherri Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate \"$NAME\" already exists in your login keychain."
    echo "Rebuild with: make app"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
CONF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:cherri -name "$NAME"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P cherri -T /usr/bin/codesign

# Trust it for code signing (this is the step that prompts for your password).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo ""
echo "Done. \"$NAME\" is ready. Now rebuild and relaunch:"
echo "  make run"
echo ""
echo "Expect exactly these one-time prompts afterwards:"
echo "  1. 'codesign wants to sign using key …' → Always Allow (during build)"
echo "  2. 'Cherri wants to use your confidential information …' per stored"
echo "     API key → Always Allow. Then never again."
