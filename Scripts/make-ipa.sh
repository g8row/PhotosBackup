#!/usr/bin/env bash
# Build an UNSIGNED .ipa for sideloading with SideStore / AltStore.
#
# The output is deliberately unsigned: SideStore re-signs it on device with the
# user's own Apple ID and applies whatever entitlements that account can
# provision. A free personal team cannot provision App Groups, so the extension
# -> app handoff falls back to the photosbackup:// URL channel; see
# docs/ADR-001-auth-route.md.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=/Applications/Xcode-26.6.0.app/Contents/Developer}"
export DEVELOPER_DIR

CONFIG="${1:-Release}"
BUILD_DIR="$(mktemp -d)"
OUT="$PWD/build/PhotosBackup.ipa"

command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
xcodegen generate

xcodebuild -project PhotosBackup.xcodeproj -scheme PhotosBackup \
  -sdk iphoneos -configuration "$CONFIG" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -derivedDataPath "$BUILD_DIR" build

APP="$BUILD_DIR/Build/Products/$CONFIG-iphoneos/PhotosBackup.app"
[ -d "$APP" ] || { echo "no .app at $APP" >&2; exit 1; }

STAGE="$BUILD_DIR/stage"
mkdir -p "$STAGE/Payload" "$PWD/build"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUT"
( cd "$STAGE" && zip -qry "$OUT" Payload )
rm -rf "$BUILD_DIR"

echo "Unsigned IPA: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install by opening it in SideStore; it signs with your Apple ID on device."
