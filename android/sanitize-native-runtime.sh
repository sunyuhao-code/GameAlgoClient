#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: sanitize-native-runtime.sh <raw-jni-dir> <output-jni-dir>" >&2
    exit 2
fi

raw_dir="$1"
output_dir="$2"

for abi in armeabi-v7a arm64-v8a x86_64; do
    source="$raw_dir/$abi/libgamealgo_script_runtime.so"
    binary="$output_dir/$abi/libgamealgo_script_runtime.so"
    test -f "$source"
    mkdir -p "$(dirname "$binary")"
    cp "$source" "$binary"
    # Replacements remain byte-for-byte equal so ELF offsets stay unchanged.
    LC_ALL=C perl -0pi -e '
      s/QuickJS/GAlgoVM/g;
      s/quickjs/galgovm/g;
      s/QUICKJS/GALGOVM/g;
    ' "$binary"
    if LC_ALL=C grep -a -i -q 'quickjs' "$binary"; then
        echo "runtime implementation identifier remains in $binary" >&2
        exit 1
    fi
done
