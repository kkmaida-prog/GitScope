#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_root="${GITSCOPE_BUILD_DIR:-$PWD/.build-verification}"
mkdir -p "$build_root/clang-cache" "$build_root/cache"
export CLANG_MODULE_CACHE_PATH="$build_root/clang-cache"
# Build the tests, then invoke XCTest explicitly so execution is visible on both
# classic SwiftPM and Xcode's newer Swift build engine.
swift build --disable-sandbox --cache-path "$build_root/cache" --scratch-path "$build_root/swift" --build-tests --enable-code-coverage
bin_path="$(swift build --disable-sandbox --cache-path "$build_root/cache" --scratch-path "$build_root/swift" --show-bin-path)"
LLVM_PROFILE_FILE="$build_root/tests-%p.profraw" xcrun xctest "$bin_path/GitScopeCoreTests.xctest"
# Macro plugins need this compiler option inside restricted agent environments.
# It affects compiler plugin execution, not the built application's App Sandbox.
xcodebuild -project GitScope.xcodeproj -scheme GitScope -configuration Debug -derivedDataPath "$build_root/Xcode" CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build
