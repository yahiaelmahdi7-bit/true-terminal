#!/usr/bin/env bash
# Make the stable code-signing identity "True Team Signing" in the LOGIN keychain (once). Releases signed with it keep their
# privacy grants (mic, Automation, ...) across updates on partner Macs. Self-signed, valid 10 years, never leaves this Mac
# unless you export the backup. Safe to run again: if the identity exists it only reports that.
# Usage: scripts/make-signing-identity.sh [backup.p12]     (asks for a backup password; the .p12 is your only recovery copy)
set -euo pipefail
NAME="True Team Signing"
KC="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then echo "OK: '$NAME' already exists in the login keychain. Nothing to do."; exit 0; fi
BACKUP="${1:-}"
if [ -z "$BACKUP" ]; then read -r -p "Where should the backup .p12 go? [$HOME/True-Team-Signing.p12] " BACKUP; BACKUP="${BACKUP:-$HOME/True-Team-Signing.p12}"; fi
[ ! -e "$BACKUP" ] || { echo "ERROR: $BACKUP already exists; pick another path"; exit 1; }
read -r -s -p "Backup password for the .p12 (you will need it to restore): " PASS; echo
[ -n "$PASS" ] || { echo "ERROR: empty password"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/ext.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = True Team Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/ext.cnf" 2>/dev/null
# -legacy keeps the p12 readable by macOS `security import` on OpenSSL 3
openssl pkcs12 -export -legacy -inkey "$T/key.pem" -in "$T/cert.pem" -name "$NAME" -out "$T/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$NAME" -out "$T/id.p12" -passout "pass:$PASS"
cp "$T/id.p12" "$BACKUP"; chmod 600 "$BACKUP"
security import "$T/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "OK: '$NAME' is in the login keychain. Backup: $BACKUP (keep it somewhere safe; losing it means partners re-grant permissions once)."
echo "Check:  security find-certificate -c '$NAME'"
echo "Note: codesign may ask once for your login password to use the key; choose Always Allow."
