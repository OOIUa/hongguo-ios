#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "--live" || "$#" -gt 2 ]]; then
  echo "Usage: $0 --live [booted-iOS-simulator-UDID]"
  exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-guest-live.XXXXXX")"
trap 'if [[ -e "$test_dir/probe" ]]; then unlink "$test_dir/probe"; fi; rmdir "$test_dir"' EXIT
cd "$project_dir"
sdk=macosx
compile_args=(-swift-version 5 -O -suppress-warnings)
if [[ "$#" -eq 2 ]]; then
  sdk=iphonesimulator
  compile_args+=(-sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" -target "$(uname -m)-apple-ios17.0-simulator")
fi
xcrun --sdk "$sdk" swiftc "${compile_args[@]}" \
  Sources/Core/Models.swift Sources/Core/HGCrypto.swift Sources/Networking/*.swift Sources/Media/*.swift \
  Tests/PublicEpisodePlaybackLive.swift -lz -o "$test_dir/probe"
if [[ "$#" -eq 2 ]]; then
  xcrun simctl spawn "$2" "$test_dir/probe" --live "$project_dir/Sources/Networking"
else
  "$test_dir/probe" --live "$project_dir/Sources/Networking"
fi
