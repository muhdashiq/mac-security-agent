#!/usr/bin/env bash
# Builds MacSecurityAgent.app (Release, arm64) with Xcode and packages it.
#
#   scripts/build-app.sh            # ad-hoc signed ("Sign to Run Locally")
#   TEAM_ID=ABCDE12345 scripts/build-app.sh   # signed with your Apple team
#
# Output: build/MacSecurityAgent.app and build/MacSecurityAgent.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIGNING=(CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="")
if [[ -n "${TEAM_ID:-}" ]]; then
  SIGNING=(CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic)
fi

xcodebuild \
  -project MacSecurityAgent.xcodeproj \
  -scheme MacSecurityAgent \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedData \
  "${SIGNING[@]}" \
  build

APP="build/DerivedData/Build/Products/Release/MacSecurityAgent.app"
rm -rf build/MacSecurityAgent.app build/MacSecurityAgent.zip
cp -R "$APP" build/MacSecurityAgent.app
codesign --verify --deep --strict build/MacSecurityAgent.app
codesign -d --entitlements - build/MacSecurityAgent.app 2>/dev/null | grep -E "camera|network|sandbox|audio" || true
ditto -c -k --keepParent build/MacSecurityAgent.app build/MacSecurityAgent.zip
echo "Built build/MacSecurityAgent.app"
