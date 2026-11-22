#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "--live" ]]; then
  echo "Run with --live to read anonymous metadata and download/decode up to 12 posters."
  exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-account-metadata-live.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 \
  Sources/Core/Models.swift Sources/Core/HGCrypto.swift Sources/Media/MP4Processor.swift \
  Sources/Networking/*.swift Sources/Account/AccountRules.swift Tests/LiveAccountMetadataSmoke.swift \
  -lz -framework JavaScriptCore -framework ImageIO -o "$test_dir/live-account-metadata"
"$test_dir/live-account-metadata" --live "$project_dir"
