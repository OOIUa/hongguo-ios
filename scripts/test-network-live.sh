#!/bin/zsh
# Explicitly opt-in: performs anonymous read-only upstream catalogue requests.
set -euo pipefail
if [[ "${1:-}" != "--live" ]]; then
  echo "Run with --live to perform anonymous upstream catalogue requests."
  exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-network-live.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
xcrun swiftc -swift-version 5 \
  "$project_dir/Sources/Core/Models.swift" "$project_dir/Sources/Core/HGCrypto.swift" \
  "$project_dir/Sources/Media/MP4Processor.swift" "$project_dir"/Sources/Networking/*.swift \
  "$project_dir/Tests/LiveProtocolSmoke.swift" -o "$work_dir/network-live" -lz -framework JavaScriptCore
"$work_dir/network-live" "$project_dir"
