#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${GAMEALGO_APPLE_DYNAMIC_XCFRAMEWORK_OUTPUT:-$repo_root/ios/GameAlgoScriptRuntime.xcframework}"

GAMEALGO_DYNAMIC_INCLUDE_MACOS=true \
GAMEALGO_IOS_DYNAMIC_XCFRAMEWORK_OUTPUT="$output" \
  exec "$repo_root/runtime/rust/build-ios-dynamic-xcframework.sh"
