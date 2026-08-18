#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root_dir"

./gradlew --no-daemon :assembleRelease

aar="$root_dir/build/outputs/aar/gamealgo-android-release.aar"
test -s "$aar"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/gamealgo-aar-integration.XXXXXX")"
classes_jar="$temp_dir/classes.jar"
unzip -p "$aar" classes.jar > "$classes_jar"
jar tf "$classes_jar" | grep -q 'com/gamealgo/sdk/GameAlgoClient.class'
jar tf "$classes_jar" | grep -q 'com/gamealgo/sdk/RustGameAlgoScriptRuntime.class'
if jar tf "$classes_jar" | grep -q 'JavaxScriptGameAlgoRuntime'; then
    echo "Desktop-only JavaxScriptGameAlgoRuntime must not be packaged in the AAR" >&2
    exit 1
fi

"$root_dir/verify-native-runtime.sh" "$aar"

./gradlew --no-daemon \
    :demo:assembleDebug \
    -PgameAlgoAar="$aar"

zipalign="${ANDROID_HOME:?ANDROID_HOME is required}/build-tools/35.0.0/zipalign"
"$zipalign" -c -P 16 -v 4 "$root_dir/demo/build/outputs/apk/debug/demo-debug.apk"

echo "AAR integration passed"
echo "AAR: $aar"
echo "Demo APK: $root_dir/demo/build/outputs/apk/debug/demo-debug.apk"
