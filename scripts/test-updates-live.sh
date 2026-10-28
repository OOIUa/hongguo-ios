#!/bin/bash
# Explicit opt-in: reads public update metadata and downloads one IPA, then removes all temporary files.
set -euo pipefail
if [[ "${1:-}" != "--live" ]]; then
  echo "Run with --live to check the public update manifest and download/verify one IPA."
  exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-update-live-build.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 "$project_dir/Sources/Updates/UpdateRules.swift" \
  "$project_dir/Sources/Updates/UpdateTransfer.swift" "$project_dir/Tests/LiveUpdateProbe.swift" \
  -o "$test_dir/live-updates"
"$test_dir/live-updates" --live
