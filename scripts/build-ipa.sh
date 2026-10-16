#!/usr/bin/env bash
# Builds an unsigned IPA for sideloading with Sideloadly.
#
# Needs a Mac with Xcode (Xcode 26 for Liquid Glass) and Homebrew.
# Usage:  ./scripts/build-ipa.sh            (build number from the date)
#         BUILD=7 ./scripts/build-ipa.sh    (build number 07)
# Output: "build/ipa/Phantom Screens v<version> build <NN>.ipa"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(printf "%02d" "${BUILD:-$(date +%y%m%d%H%M)}")
echo "Phantom Screens $VERSION build $BUILD"

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen --quiet

mkdir -p build
if ! xcodebuild build \
    -project Phantom.xcodeproj \
    -scheme Phantom \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath build/derived \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    > build/build.log 2>&1; then
  grep -E "error:" build/build.log | cut -c1-300 | head -40
  echo "BUILD FAILED (full log: build/build.log)"
  exit 1
fi

APP=build/derived/Build/Products/Release-iphoneos/Phantom.app
test -x "$APP/Phantom" || { echo "App executable missing"; exit 1; }
ls "$APP" | grep -q "Assets.car" || { echo "App icon assets missing"; exit 1; }
for icon in AppIcon-Pattern AppIcon-Light AppIcon-Cyan; do
  plutil -p "$APP/Info.plist" | grep -q "$icon" || { echo "Alternate icon $icon missing"; exit 1; }
done

rm -rf build/Payload && mkdir -p build/Payload build/ipa
cp -R "$APP" build/Payload/
IPA="build/ipa/Phantom Screens v$VERSION build $BUILD.ipa"
(cd build && zip -qr "../$IPA" Payload)
echo "Built $IPA"
