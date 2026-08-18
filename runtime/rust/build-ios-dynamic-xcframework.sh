#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
manifest="$repo_root/runtime/rust/Cargo.toml"
output="${GAMEALGO_IOS_DYNAMIC_XCFRAMEWORK_OUTPUT:-$repo_root/ios/GameAlgoScriptRuntimeDynamic-iOS.xcframework}"
include_macos="${GAMEALGO_DYNAMIC_INCLUDE_MACOS:-false}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/gamealgo-ios-dynamic.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

targets=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)

if [[ "$include_macos" == "true" ]]; then
  targets+=(
    aarch64-apple-darwin
    x86_64-apple-darwin
  )
fi

build_dynamic_library() {
  local target="$1"
  case "$target" in
    aarch64-apple-ios)
      env IPHONEOS_DEPLOYMENT_TARGET=13.0 \
        CFLAGS_aarch64_apple_ios=-miphoneos-version-min=13.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- \
        --crate-type cdylib \
        -C link-arg=-install_name \
        -C link-arg=@rpath/GameAlgoScriptRuntime.framework/GameAlgoScriptRuntime
      ;;
    aarch64-apple-ios-sim)
      env IPHONEOS_DEPLOYMENT_TARGET=13.0 \
        CFLAGS_aarch64_apple_ios_sim=-mios-simulator-version-min=13.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- \
        --crate-type cdylib \
        -C link-arg=-install_name \
        -C link-arg=@rpath/GameAlgoScriptRuntime.framework/GameAlgoScriptRuntime
      ;;
    x86_64-apple-ios)
      env IPHONEOS_DEPLOYMENT_TARGET=13.0 \
        CFLAGS_x86_64_apple_ios=-mios-simulator-version-min=13.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- \
        --crate-type cdylib \
        -C link-arg=-install_name \
        -C link-arg=@rpath/GameAlgoScriptRuntime.framework/GameAlgoScriptRuntime
      ;;
    aarch64-apple-darwin)
      env MACOSX_DEPLOYMENT_TARGET=12.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- \
        --crate-type cdylib \
        -C link-arg=-install_name \
        -C link-arg=@rpath/GameAlgoScriptRuntime.framework/GameAlgoScriptRuntime
      ;;
    x86_64-apple-darwin)
      env MACOSX_DEPLOYMENT_TARGET=12.0 \
        cargo rustc --locked --release --manifest-path "$manifest" --target "$target" --lib -- \
        --crate-type cdylib \
        -C link-arg=-install_name \
        -C link-arg=@rpath/GameAlgoScriptRuntime.framework/GameAlgoScriptRuntime
      ;;
    *)
      echo "unsupported Apple target: $target" >&2
      exit 2
      ;;
  esac
}

for target in "${targets[@]}"; do
  rustup target add "$target"
  build_dynamic_library "$target"
  cp \
    "$repo_root/runtime/rust/target/$target/release/libgamealgo_script_runtime.dylib" \
    "$build_dir/libgamealgo_script_runtime_$target.dylib"
  xcrun strip -S "$build_dir/libgamealgo_script_runtime_$target.dylib"
done

lipo -create \
  "$build_dir/libgamealgo_script_runtime_aarch64-apple-ios-sim.dylib" \
  "$build_dir/libgamealgo_script_runtime_x86_64-apple-ios.dylib" \
  -output "$build_dir/libgamealgo_script_runtime_ios_simulator.dylib"

if [[ "$include_macos" == "true" ]]; then
  lipo -create \
    "$build_dir/libgamealgo_script_runtime_aarch64-apple-darwin.dylib" \
    "$build_dir/libgamealgo_script_runtime_x86_64-apple-darwin.dylib" \
    -output "$build_dir/libgamealgo_script_runtime_macos.dylib"
fi

make_framework() {
  local identifier="$1"
  local library="$2"
  local framework="$build_dir/$identifier/GameAlgoScriptRuntime.framework"
  mkdir -p "$framework/Headers" "$framework/Modules"
  cp "$library" "$framework/GameAlgoScriptRuntime"
  cp "$repo_root/runtime/rust/include/gamealgo_runtime.h" "$framework/Headers/"
  cp "$repo_root/runtime/rust/ios-framework/module.modulemap" "$framework/Modules/"
  cp "$repo_root/runtime/rust/ios-framework/Info.plist" "$framework/"
}

make_framework \
  ios-arm64 \
  "$build_dir/libgamealgo_script_runtime_aarch64-apple-ios.dylib"
make_framework \
  ios-arm64_x86_64-simulator \
  "$build_dir/libgamealgo_script_runtime_ios_simulator.dylib"

if [[ "$include_macos" == "true" ]]; then
  make_framework \
    macos-arm64_x86_64 \
    "$build_dir/libgamealgo_script_runtime_macos.dylib"
fi

rm -rf "$output"
frameworks=(
  -framework "$build_dir/ios-arm64/GameAlgoScriptRuntime.framework" \
  -framework "$build_dir/ios-arm64_x86_64-simulator/GameAlgoScriptRuntime.framework"
)
if [[ "$include_macos" == "true" ]]; then
  frameworks+=(
    -framework "$build_dir/macos-arm64_x86_64/GameAlgoScriptRuntime.framework"
  )
fi

xcodebuild -create-xcframework "${frameworks[@]}" \
  -output "$output"

echo "Created $output"
