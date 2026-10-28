#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-progressive-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -O -suppress-warnings \
  Sources/Core/Models.swift Sources/Core/HGCrypto.swift Sources/Media/*.swift \
  Tests/ProgressiveFixture.swift Tests/ProgressiveTransportChecks.swift Tests/ProgressiveSelfTest.swift -lz -o "$test_dir/progressive-test"
"$test_dir/progressive-test"
