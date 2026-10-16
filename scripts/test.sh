#!/usr/bin/env bash
# Runs the unit tests on an iPhone simulator. Needs a Mac with Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen --quiet

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
for runtime in sorted(devices, reverse=True):
    for d in devices[runtime]:
        if 'iPhone' in d['name'] and d['isAvailable']:
            print(d['udid']); sys.exit()
")
mkdir -p build
STATUS=0
xcodebuild test -project Phantom.xcodeproj -scheme Phantom -destination "id=$UDID" \
  -derivedDataPath build/derived-tests CODE_SIGNING_ALLOWED=NO > build/test.log 2>&1 || STATUS=$?
grep -E "error:|Test Case .*failed|Executed|TEST (SUCCEEDED|FAILED)" build/test.log | cut -c1-300
exit $STATUS
