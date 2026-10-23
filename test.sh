#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/.build/swift-tests" \
    Sources/TimingService.swift Tests/TimingTests.swift -o .build/timing-tests
.build/timing-tests
