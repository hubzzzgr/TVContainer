#!/bin/bash
set -euo pipefail
mkdir -p build
test "$(uname -m)" = arm64
includes=(-Ilitehook/src -Ilitehook/external/include)
for phase in Before After; do
  xcrun clang -fobjc-arc -framework Foundation -dynamiclib tests/bundle_probe.m \
    -install_name "@rpath/Probe$phase.dylib" -o "build/Probe$phase.dylib"
done
for mode in fallback cache; do
  definitions=()
  if [ "$mode" = fallback ]; then definitions=(-DTV_BUNDLE_TEST_NO_CACHE=1); fi
  xcrun clang -fobjc-arc -framework Foundation "${includes[@]}" "${definitions[@]}" \
    tests/bundle_harness.m TVContainer/Runtime/TVGuestBundle.m litehook/src/litehook.c \
    -o "build/bundle-test-$mode"
  "build/bundle-test-$mode" "$PWD/build/ProbeBefore.dylib" "$PWD/build/ProbeAfter.dylib"
done
