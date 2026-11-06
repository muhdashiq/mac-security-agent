#!/usr/bin/env bash
# Alternative build without the Xcode project: compiles the SwiftPM
# executable target and assembles a signed .app bundle by hand.
# Requires the Xcode command line tools (Swift 6) on Apple Silicon.
#
# Output: build/spm/MacSecurityAgent.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/MacSecurityAgent"
OUT="$ROOT/build/spm"
APP="$OUT/MacSecurityAgent.app"

swift build --package-path "$PKG" -c release --arch arm64 --product MacSecurityAgentSPM
BIN="$(swift build --package-path "$PKG" -c release --arch arm64 --show-bin-path)/MacSecurityAgentSPM"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacSecurityAgent"
sed -e 's/$(EXECUTABLE_NAME)/MacSecurityAgent/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.macsecurityagent.app/' \
    -e 's/$(PRODUCT_NAME)/MacSecurityAgent/' \
    -e 's/$(MARKETING_VERSION)/1.0.0/' \
    -e 's/$(CURRENT_PROJECT_VERSION)/1/' \
    -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
    "$PKG/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none \
  --entitlements "$PKG/Resources/MacSecurityAgent.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
