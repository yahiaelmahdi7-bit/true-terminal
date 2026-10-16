#!/usr/bin/env bash
# One-time: make the Ed25519 key that signs True updates. The private half goes into the login Keychain
# (service true-update-signing, account release) and is never written to disk or printed. Refuses if one exists.
# Prints the public key and the exact `gh variable set` command; run that command yourself once.
set -euo pipefail
cd "$(dirname "$0")/.."
PUB="$(swift scripts/update-sign.swift genkey)"
echo "Key created. Private key is in your login Keychain (true-update-signing / release)."
echo "Public key: $PUB"
echo
echo "Now publish the PUBLIC key as a (non-secret) Actions variable:"
echo "  gh variable set TRUE_UPDATE_PUBKEY --repo yahiaelmahdi7-bit/true-terminal --body '$PUB'"
