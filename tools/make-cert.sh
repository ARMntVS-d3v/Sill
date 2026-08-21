#!/bin/zsh
# Self-signed certificate for signing Sill.
# Needed so the app's signature stops changing on every rebuild — that change was
# resetting permissions (Calendar) and making Keychain ask for a password each time.
set -e
NAME="Sill Dev"
DIR=$(mktemp -d)
cd "$DIR"

cat > ext.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Sill Dev
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config ext.cnf -keyout key.pem -out cert.pem >/dev/null 2>&1
openssl pkcs12 -export -legacy -macalg sha1 -inkey key.pem -in cert.pem -out cert.p12 -name "$NAME" -passout pass:sill >/dev/null 2>&1

# Import into the login keychain and let codesign use the key without prompting
security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P sill -T /usr/bin/codesign -A
# Trust the certificate for code signing (will ask for a password — that's expected)
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem

echo "Done. Certificate \"$NAME\" is in the keychain."
security find-identity -v -p codesigning | grep "$NAME" || true
