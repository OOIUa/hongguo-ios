#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-network-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
xcrun swiftc -swift-version 5 \
  "$project_dir/Sources/Core/Models.swift" "$project_dir/Sources/Core/HGCrypto.swift" \
  "$project_dir/Sources/Media/MP4Processor.swift" "$project_dir"/Sources/Networking/*.swift \
  "$project_dir/Tests/NetworkSelfTest.swift" -o "$work_dir/network-test" -lz -framework JavaScriptCore
"$work_dir/network-test" "$project_dir"
if command -v node >/dev/null 2>&1; then
  node "$project_dir/Tests/signing-oracle.cjs"
fi
