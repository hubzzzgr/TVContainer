#!/bin/bash
set -euo pipefail
mkdir -p build
python3 tests/download_server.py build/download-port &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for attempt in $(seq 1 40); do
  if [ -f build/download-port ]; then break; fi
  sleep 0.1
done
swiftc -parse-as-library TVContainer/UI/TVDownload.swift TVContainer/UI/TVDownloadProgress.swift \
  tests/download_harness.swift -o build/download-tests
build/download-tests "http://127.0.0.1:$(cat build/download-port)"
