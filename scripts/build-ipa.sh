#!/usr/bin/env bash
# Builds an unsigned IPA for sideloading with Sideloadly.
#
# Needs a Mac with Xcode (Xcode 26 for Liquid Glass) and Homebrew.
# Usage:  ./scripts/build-ipa.sh            (build number from the date)
#         BUILD=7 ./scripts/build-ipa.sh    (build number 07)
#         VARIANT=preview ./scripts/build-ipa.sh
#             a separate "Phantom Preview" app (its own bundle ID), to install
#             next to the regular one and compare
# Output: "build/ipa/Phantom Screens v<version> build <NN>.ipa"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(printf "%02d" "${BUILD:-$(date +%y%m%d%H%M)}")
NAME="Phantom Screens"
VARIANT_SETTINGS=()
if [ "${VARIANT:-}" = "preview" ]; then
  NAME="Phantom Preview"
  VARIANT_SETTINGS=(PRODUCT_BUNDLE_IDENTIFIER=com.phantomscreens.visualizer.preview "APP_DISPLAY_NAME=$NAME")
fi
echo "$NAME $VERSION build $BUILD"

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
    ${VARIANT_SETTINGS[@]+"${VARIANT_SETTINGS[@]}"} \
    > build/build.log 2>&1; then
  grep -E "error:" build/build.log | cut -c1-300 | head -40
  echo "BUILD FAILED (full log: build/build.log)"
  exit 1
fi
# Slow-to-compile code (see OTHER_SWIFT_FLAGS in project.yml): worth fixing
# before it becomes an error.
grep -E "warning: .* took [0-9]+ms to type-check" build/build.log \
  | sort -u | cut -c1-300 | head -20 || true

APP=build/derived/Build/Products/Release-iphoneos/Phantom.app
test -x "$APP/Phantom" || { echo "App executable missing"; exit 1; }
ls "$APP" | grep -q "Assets.car" || { echo "App icon assets missing"; exit 1; }
for icon in AppIcon-Pattern AppIcon-Light AppIcon-Cyan; do
  plutil -p "$APP/Info.plist" | grep -q "$icon" || { echo "Alternate icon $icon missing"; exit 1; }
done

rm -rf build/Payload && mkdir -p build/Payload build/ipa
cp -R "$APP" build/Payload/
IPA="build/ipa/$NAME v$VERSION build $BUILD.ipa"
(cd build && zip -qr "../$IPA" Payload)
echo "Built $IPA"
