#!/bin/bash
# Offline only: validates update trust/schema/version rules, without contacting GitHub or proxies.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-update-rules.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 "$project_dir/Sources/Updates/UpdateRules.swift" \
  "$project_dir/Sources/Updates/UpdateTransfer.swift" "$project_dir/Tests/UpdateRulesProbe.swift" -o "$test_dir/update-rules"
"$test_dir/update-rules"
