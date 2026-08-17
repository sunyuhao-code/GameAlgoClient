#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
manifest="$repo_root/runtime/rust/Cargo.toml"
output="${GAMEALGO_XCFRAMEWORK_OUTPUT:-$repo_root/ios/GameAlgoScriptRuntime.xcframework}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/gamealgo-xcframework.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

targets=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
  aarch64-apple-darwin
  x86_64-apple-darwin
)

build_static_library() {
  local target="$1"
  rustup target add "$target"
  case "$target" in
    aarch64-apple-ios)
      env IPHONEOS_DEPLOYMENT_TARGET=13.0 \
        CFLAGS_aarch64_apple_ios=-miphoneos-version-min=13.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- --crate-type staticlib
      ;;
    aarch64-apple-ios-sim)
      env IPHONEOS_DEPLOYMENT_TARGET=13.0 \
        CFLAGS_aarch64_apple_ios_sim=-mios-simulator-version-min=13.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- --crate-type staticlib
      ;;
    x86_64-apple-ios)
      env IPHONEOS_DEPLOYMENT_TARGET=13.0 \
        CFLAGS_x86_64_apple_ios=-mios-simulator-version-min=13.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- --crate-type staticlib
      ;;
    *-apple-darwin)
      env MACOSX_DEPLOYMENT_TARGET=12.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- --crate-type staticlib
      ;;
  esac
}

for target in "${targets[@]}"; do
  build_static_library "$target"
  cp \
    "$repo_root/runtime/rust/target/$target/release/libgamealgo_script_runtime.a" \
    "$build_dir/libgamealgo_script_runtime_$target.a"
  xcrun strip -S "$build_dir/libgamealgo_script_runtime_$target.a"
done

lipo -create \
  "$build_dir/libgamealgo_script_runtime_aarch64-apple-ios-sim.a" \
  "$build_dir/libgamealgo_script_runtime_x86_64-apple-ios.a" \
  -output "$build_dir/libgamealgo_script_runtime_ios_simulator.a"

lipo -create \
  "$build_dir/libgamealgo_script_runtime_aarch64-apple-darwin.a" \
  "$build_dir/libgamealgo_script_runtime_x86_64-apple-darwin.a" \
  -output "$build_dir/libgamealgo_script_runtime_macos.a"

rm -rf "$output"
xcodebuild -create-xcframework \
  -library "$build_dir/libgamealgo_script_runtime_aarch64-apple-ios.a" \
  -headers "$repo_root/runtime/rust/include" \
  -library "$build_dir/libgamealgo_script_runtime_ios_simulator.a" \
  -headers "$repo_root/runtime/rust/include" \
  -library "$build_dir/libgamealgo_script_runtime_macos.a" \
  -headers "$repo_root/runtime/rust/include" \
  -output "$output"

echo "Created $output"
