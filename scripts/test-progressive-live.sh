#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "--live" ]]; then
  echo "Run with --live to read one anonymous episode and verify progressive decoding."
  exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-progressive-live.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -O -suppress-warnings \
  Sources/Core/Models.swift Sources/Core/HGCrypto.swift Sources/Networking/*.swift Sources/Media/*.swift \
  Tests/LiveProgressiveSmoke.swift -lz -o "$test_dir/progressive-live"
"$test_dir/progressive-live" --live "$project_dir/Sources/Networking"
