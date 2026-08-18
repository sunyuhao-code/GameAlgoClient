#!/usr/bin/env bash
set -euo pipefail

aar="${1:?usage: verify-native-runtime.sh <aar>}"
test -s "$aar"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/gamealgo-native-runtime.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
unzip -q "$aar" -d "$temp_dir"
jar tf "$temp_dir/classes.jar" | grep -q 'com/gamealgo/sdk/RustGameAlgoScriptRuntime.class'

readelf_bin="${READELF:-}"
if [[ -z "$readelf_bin" && -n "${ANDROID_NDK_HOME:-}" ]]; then
    readelf_bin="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -path '*/bin/llvm-readelf' -print -quit)"
fi
if [[ -z "$readelf_bin" || ! -x "$readelf_bin" ]]; then
    echo "Set READELF or ANDROID_NDK_HOME to an NDK containing llvm-readelf" >&2
    exit 1
fi

for abi in armeabi-v7a arm64-v8a x86_64; do
    library="$temp_dir/jni/$abi/libgamealgo_script_runtime.so"
    test -s "$library"
    alignments="$($readelf_bin -lW "$library" | awk '$1 == "LOAD" { print $NF }')"
    if [[ -z "$alignments" ]]; then
        echo "$abi runtime has no ELF LOAD segments" >&2
        exit 1
    fi
    while read -r alignment; do
        if (( alignment < 0x4000 )); then
            echo "$abi runtime LOAD alignment $alignment is below 0x4000" >&2
            exit 1
        fi
    done <<< "$alignments"
    if LC_ALL=C grep -a -i -q 'quickjs' "$library"; then
        echo "$abi runtime exposes its underlying implementation name" >&2
        exit 1
    fi
    echo "$abi runtime is 16 KB aligned"
done
