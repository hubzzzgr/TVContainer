#!/bin/bash
set -euo pipefail
mkdir -p build
xcrun clang -Wall -Wextra -Werror tests/reexec_harness.c TVContainer/Runtime/TVProcessReexec.c -o build/reexec-test
build/reexec-test preserved-argument
device=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v[0]["udid"] for k,v in d["devices"].items() if "tvOS" in k and v))')
set -o pipefail
xcodebuild test -project TVContainer.xcodeproj -scheme TVContainerSettingsTests \
  -destination "platform=tvOS Simulator,id=$device" \
  -resultBundlePath build/SettingsTests.xcresult CODE_SIGNING_ALLOWED=NO | tee settings-tests.log
