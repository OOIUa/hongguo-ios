#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-media.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -suppress-warnings \
  Sources/Core/Models.swift Sources/Core/HGCrypto.swift \
  Sources/Media/MP4Processor.swift Tests/MediaSelfTest.swift \
  -lz -o "$test_dir/media-self-test"
"$test_dir/media-self-test"
