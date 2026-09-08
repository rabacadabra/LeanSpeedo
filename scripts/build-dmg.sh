#!/bin/bash
#
# Builds LeanSpeedo (Release), ad-hoc signs it, and packages it into a DMG.
# Requires: Xcode command line tools, and `create-dmg` (brew install create-dmg).
#
# Output:  build/LeanSpeedo.dmg  (+ its SHA-256, printed at the end)

set -euo pipefail

APP_NAME="LeanSpeedo"
BUILD_DIR="$PWD/build"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

rm -rf "$BUILD_DIR"

# Optional version overrides (used by CI from the git tag). GENERATE_INFOPLIST_FILE
# is on, so these settings land in the built Info.plist.
VERSION_ARGS=()
[ -n "${MARKETING_VERSION:-}" ] && VERSION_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION")
[ -n "${CURRENT_PROJECT_VERSION:-}" ] && VERSION_ARGS+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")

# Build unsigned — CI has no signing identity.
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  "${VERSION_ARGS[@]}"

# Ad-hoc signature: a stable code signature (no "damaged" error), but not
# notarized — users still clear Gatekeeper once on first launch.
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --verbose "$APP_PATH"

create-dmg \
  --volname "$APP_NAME" \
  --window-size 500 320 \
  --icon-size 110 \
  --icon "$APP_NAME.app" 130 150 \
  --app-drop-link 370 150 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_PATH"

echo
echo "Built: $DMG_PATH"
shasum -a 256 "$DMG_PATH"
