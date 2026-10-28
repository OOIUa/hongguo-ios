#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-library.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -suppress-warnings \
  Sources/Core/Models.swift Sources/Core/HGCrypto.swift Sources/Core/LibraryStore.swift \
  Tests/LibrarySelfTest.swift -lz -o "$test_dir/library-self-test"
"$test_dir/library-self-test"
