#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) True.app, ad-hoc signed, and zip it for a GitHub Release.
# Output: dist/True-macOS.zip and dist/True-macOS.zip.sha256. Never launches or installs anything.
# The version comes from TRUE_VERSION, else from GITHUB_REF_NAME (a tag like v1.2.3), else 1.2.0.
# Usage: TRUE_VERSION=1.2.3 scripts/make-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

: "${TRUE_UPDATE_PUBKEY:?TRUE_UPDATE_PUBKEY is empty: a release without the update public key could never verify signatures. Run scripts/gen-update-key.sh once and set the Actions variable.}"
VERSION="${TRUE_VERSION:-}"
if [ -z "$VERSION" ] && [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then VERSION="${GITHUB_REF_NAME#v}"; fi
VERSION="${VERSION:-1.2.0}"
VERSION="${VERSION#v}"
export TRUE_VERSION="$VERSION"

OUT="$ROOT/dist"
rm -rf "$OUT"
mkdir -p "$OUT/.tmp"

for arch in arm64 x86_64; do
  case "$arch" in arm64) sp=arm;; x86_64) sp=x86;; esac
  echo "==> swift build release $arch (macOS 14.0)..."
  nice -n 10 swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path "$ROOT/.build-$sp" -j 4
done
lipo -create "$ROOT/.build-arm/arm64-apple-macosx/release/True" \
             "$ROOT/.build-x86/x86_64-apple-macosx/release/True" -output "$OUT/.tmp/True"
echo "    archs: $(lipo -archs "$OUT/.tmp/True")"

TRUE_PREBUILT_BIN="$OUT/.tmp/True" TRUE_APP_OUT="$OUT/True.app" scripts/package.sh release
rm -rf "$OUT/.tmp"

(cd "$OUT" && ditto -c -k --keepParent True.app True-macOS.zip && shasum -a 256 True-macOS.zip > True-macOS.zip.sha256)
echo "OK: $OUT/True-macOS.zip (version $VERSION)"
cat "$OUT/True-macOS.zip.sha256"
