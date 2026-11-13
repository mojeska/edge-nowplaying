#!/bin/sh
# Creates the self-signed "Edge Now Playing Local Signing" certificate in the login keychain (once per Mac),
# so build.sh signs with a stable identity and macOS keeps the app's permissions across rebuilds.
set -e
ID="Edge Now Playing Local Signing"
if security find-identity -p codesigning | grep -q "\"$ID\""; then echo "Already there: $ID"; exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $ID
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$D/key.pem" -out "$D/cert.pem" -config "$D/cert.cnf" 2>/dev/null
P=$(/usr/bin/openssl rand -hex 12)
/usr/bin/openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "$ID" -out "$D/sign.p12" -passout pass:"$P"
security import "$D/sign.p12" -k ~/Library/Keychains/login.keychain-db -P "$P" -T /usr/bin/codesign
echo "Created: $ID"
