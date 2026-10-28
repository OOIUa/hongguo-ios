#!/bin/bash
# Explicit network smoke test; downloads one public, anonymous episode.
set -euo pipefail
if [[ "${1:-}" != "--live" ]]; then
  echo "Run with --live to register an anonymous playback identity and download one episode."
  exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-media-live.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -suppress-warnings \
  Sources/Core/Models.swift Sources/Core/HGCrypto.swift \
  Sources/Networking/*.swift Sources/Media/*.swift Tests/LiveMediaSmoke.swift \
  -lz -o "$test_dir/live-media-smoke"
"$test_dir/live-media-smoke" --live "$project_dir/Sources/Networking"
