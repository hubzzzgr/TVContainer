#!/bin/bash
set -euo pipefail
device=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v[0]["udid"] for k,v in d["devices"].items() if "tvOS" in k and v))')
set -o pipefail
xcodebuild test -project TVContainer.xcodeproj -scheme TVContainerIconTests \
  -destination "platform=tvOS Simulator,id=$device" \
  -resultBundlePath build/IconTests.xcresult CODE_SIGNING_ALLOWED=NO | tee icon-tests.log
