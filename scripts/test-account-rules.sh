#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p build/tests
/usr/bin/swiftc Sources/Core/Models.swift Sources/Networking/ProtocolJSON.swift Sources/Account/AccountRules.swift Tests/AccountRulesSelfTest.swift -o build/tests/account-rules
build/tests/account-rules
