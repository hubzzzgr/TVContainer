#!/bin/bash
set -euo pipefail
mkdir -p build
framework="$PWD/OpenSSL/Frameworks/OpenSSL.xcframework/macos-arm64_x86_64"
xcrun clang++ -std=c++17 -fobjc-arc -F"$framework" -c ZSign/TVReceiverIdentity.mm -o build/receiver-identity.o
swiftc -parse-as-library -swift-version 5 -import-objc-header tests/Receiver-Bridging.h \
  -F"$framework" -framework OpenSSL -framework Foundation -framework Security -framework Network -lc++ \
  -Xlinker -rpath -Xlinker "$framework" build/receiver-identity.o \
  TVContainer/UI/TVTransferProtocol.swift TVContainer/UI/TVReceiverSecurity.swift \
  TVContainer/UI/TVTCPReceiver.swift tests/receiver_harness.swift -o build/receiver-tests
build/receiver-tests
python3 tests/extract_signing_store.py
xcrun clang -fobjc-arc -framework Foundation -framework Security -ITVContainer/Runtime \
  build/signing_store.m tests/signing_store_harness.m -o build/signing-store-tests
build/signing-store-tests
