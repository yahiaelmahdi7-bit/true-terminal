#!/usr/bin/env bash
# Sign and publish a release: finds the DRAFT release vX that the release workflow made, checks the zip against its
# .sha256 and that the app inside carries the public key matching your Keychain key, signs the exact zip bytes,
# uploads True-macOS.zip.sig, publishes it as Latest, then re-downloads the PUBLISHED files and verifies the signature.
# Usage: scripts/sign-release.sh 1.1.3      (waits up to 15 min for the draft to appear)
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:?usage: scripts/sign-release.sh <version, e.g. 1.1.3>}"
TAG="v${VER#v}"
REPO="${TRUE_REPO:-yahiaelmahdi7-bit/true-terminal}"
ZIP=True-macOS.zip; SUM=True-macOS.zip.sha256; SIG=True-macOS.zip.sig
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "==> waiting for draft release $TAG ..."
for i in $(seq 1 90); do
  gh release view "$TAG" --repo "$REPO" --json isDraft,assets -q '.isDraft and ([.assets[].name] | index("'$ZIP'") != null) and ([.assets[].name] | index("'$SUM'") != null)' 2>/dev/null | grep -q true && break
  [ "$i" = 90 ] && { echo "ERROR: no draft $TAG with $ZIP + $SUM after 15 min (is it already published, or did the workflow fail?)"; exit 1; }
  sleep 10
done

mkdir "$WORK/dl" "$WORK/app"
gh release download "$TAG" --repo "$REPO" --dir "$WORK/dl" -p "$ZIP" -p "$SUM"
echo "==> checksum"
(cd "$WORK/dl" && shasum -a 256 -c "$SUM")
ditto -x -k "$WORK/dl/$ZIP" "$WORK/app"
APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :TrueUpdatePublicKey' "$WORK/app/True.app/Contents/Info.plist" 2>/dev/null || true)"
MY_KEY="$(swift scripts/update-sign.swift pubkey)"
[ -n "$APP_KEY" ] || { echo "ERROR: the app has no TrueUpdatePublicKey; TRUE_UPDATE_PUBKEY was empty at build time"; exit 1; }
[ "$APP_KEY" = "$MY_KEY" ] || { echo "ERROR: the app's embedded public key does not match your Keychain key. Signing would brick updates for this build."; echo "  app:      $APP_KEY"; echo "  keychain: $MY_KEY"; exit 1; }
echo "==> app key matches Keychain key"

swift scripts/update-sign.swift sign "$WORK/dl/$ZIP" > "$WORK/dl/$SIG"
swift scripts/update-sign.swift verify "$WORK/dl/$ZIP" "$WORK/dl/$SIG" "$MY_KEY"
gh release upload "$TAG" "$WORK/dl/$SIG" --repo "$REPO" --clobber
gh release edit "$TAG" --repo "$REPO" --draft=false --latest

echo "==> re-downloading the published release to verify"
mkdir "$WORK/pub"
gh release download "$TAG" --repo "$REPO" --dir "$WORK/pub" -p "$ZIP" -p "$SUM" -p "$SIG"
(cd "$WORK/pub" && shasum -a 256 -c "$SUM")
swift scripts/update-sign.swift verify "$WORK/pub/$ZIP" "$WORK/pub/$SIG" "$MY_KEY"
LATEST="$(gh release view --repo "$REPO" --json tagName -q .tagName)"
[ "$LATEST" = "$TAG" ] || { echo "ERROR: Latest is $LATEST, not $TAG"; exit 1; }
echo "OK: $TAG is published, signed and Latest: https://github.com/$REPO/releases/tag/$TAG"
