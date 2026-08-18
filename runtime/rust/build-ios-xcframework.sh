#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${GAMEALGO_IOS_XCFRAMEWORK_OUTPUT:-$repo_root/ios/GameAlgoScriptRuntime-iOS.xcframework}"

GAMEALGO_XCFRAMEWORK_INCLUDE_MACOS=false \
GAMEALGO_XCFRAMEWORK_OUTPUT="$output" \
  exec "$repo_root/runtime/rust/build-apple-xcframework.sh"
