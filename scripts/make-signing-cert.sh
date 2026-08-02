#!/bin/bash
# Create the self-signed certificate TalkType is signed with.
#
# Why this exists: macOS ties the Accessibility permission to the app's "designated
# requirement". An ad-hoc signed app's requirement is its cdhash, which changes with every
# build — so every update silently revokes the permission, while System Settings goes on
# showing the app switched on. Signing with a certificate, even a self-signed one, changes
# the requirement to `identifier "..." and certificate leaf = H"..."`, which is identical
# across builds. macOS does not need to trust the certificate for this; it only checks that
# it is the same one that was approved.
#
# This is not a substitute for a paid Apple Developer ID: Gatekeeper still asks for
# right-click ▸ Open on first launch, and the app still cannot be notarised.
#
# Run once. Everything after that is `scripts/build.sh`.

set -euo pipefail

NAME="TalkType Signing"
BACKUP_DIR="$HOME/Documents/TalkType-signing-backup"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists in your keychain. Nothing to do."
    security find-identity -p codesigning | grep "$NAME"
    exit 0
fi

PASS=$(openssl rand -base64 18)

cat > "$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = TalkType Signing
O  = TalkType
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

echo "Creating the certificate..."
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# -legacy and -macalg sha1: macOS's Security framework cannot read OpenSSL 3's default
# PKCS#12 encryption, and fails with a misleading "wrong password" error.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/talktype-signing.p12" -passout pass:"$PASS" -name "$NAME" \
    -legacy -macalg sha1 2>/dev/null

echo "Adding it to your login keychain (macOS may ask for your password)..."
security import "$WORK/talktype-signing.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign

mkdir -p "$BACKUP_DIR"
cp "$WORK/talktype-signing.p12" "$BACKUP_DIR/"
cat > "$BACKUP_DIR/README.txt" <<TXT
TalkType code-signing certificate — backup copy

This certificate is how macOS recognises TalkType as the same app across versions,
so the Accessibility permission survives an update.

Passphrase: $PASS

Move this folder into 1Password (or another encrypted store) and delete it from
Documents — the .p12 contains a private key.

To restore it on another Mac:

  security import talktype-signing.p12 \\
      -k ~/Library/Keychains/login.keychain-db -P '$PASS' -T /usr/bin/codesign

If it is ever lost, run scripts/make-signing-cert.sh again to make a new one.
Everyone who has already granted Accessibility will have to grant it once more,
and only once.
TXT

echo
security find-identity -p codesigning | grep "$NAME" || true
echo
echo "Backup written to: $BACKUP_DIR"
echo "Move it somewhere encrypted, then delete it from Documents."
echo
echo "Next: scripts/build.sh"
