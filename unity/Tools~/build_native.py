#!/usr/bin/env python3
"""Build pinned native sources in this checkout; no game credentials are needed."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parent
BUILD = PACKAGE / "build"


def run(command, cwd=REPO):
    env = os.environ.copy()
    env.setdefault("CARGO_TARGET_DIR", str(BUILD / "rust"))
    subprocess.run([str(x) for x in command], cwd=cwd, env=env, check=True)


def android():
    output = PACKAGE / "Runtime/Plugins/Android"
    output.mkdir(parents=True, exist_ok=True)
    run([REPO / "android/gradlew", "--init-script", PACKAGE / "Tools~/native-build.init.gradle",
         "-Dgamepropel.unity.buildRoot=" + str(BUILD), "-PsdkVersion=2.1.5", ":assembleRelease", "--console=plain"], REPO / "android")
    native = BUILD / "android/outputs/aar/gamealgo-android-release.aar"
    if not native.exists():
        raise RuntimeError("Native Android AAR was not produced")
    run([REPO / "android/gradlew", "-p", PACKAGE / "Native~/Android", "-PnativeSdkAar=" + str(native), ":assembleRelease", "--console=plain"])
    shutil.copy2(native, output / "gamealgo-android.aar")
    shutil.copy2(PACKAGE / "Native~/Android/build/outputs/aar/gamepropel-unity-release.aar", output / "gamepropel-unity.aar")


def ios():
    output = PACKAGE / "Binaries~/iOS"
    output.mkdir(parents=True, exist_ok=True)
    archives = []
    for name, destination in [("device", "generic/platform=iOS"), ("simulator", "generic/platform=iOS Simulator")]:
        archive = BUILD / (name + ".xcarchive")
        run(["xcodebuild", "archive", "-scheme", "GamePropelUnity", "-destination", destination,
             "-archivePath", archive, "-derivedDataPath", BUILD / ("derived-" + name),
             "SKIP_INSTALL=NO", "BUILD_LIBRARY_FOR_DISTRIBUTION=NO",
             "SWIFT_EMIT_MODULE_INTERFACE=NO", "CODE_SIGNING_ALLOWED=NO",
             "IPHONEOS_DEPLOYMENT_TARGET=15.0", "SWIFT_OPTIMIZATION_LEVEL=-Osize",
             "DEAD_CODE_STRIPPING=YES", "STRIP_INSTALLED_PRODUCT=YES", "STRIP_STYLE=non-global",
             'OTHER_LDFLAGS=$(inherited) -Xlinker -exported_symbols_list -Xlinker "' + str(PACKAGE / "Native~/iOS/UnityExports.txt") + '"'], PACKAGE / "Native~/iOS")
        matches = list((archive / "Products").rglob("GamePropelUnity.framework"))
        if len(matches) != 1:
            raise RuntimeError("Expected one archived GamePropelUnity.framework")
        # Unity imports only GPUnity_* C symbols. Do not distribute compiler-
        # specific Swift modules or emit interfaces for the internal SDK whose
        # module and actor share a name (Swift issue #56573).
        for module in (matches[0] / "Modules").glob("*.swiftmodule"):
            shutil.rmtree(module)
        exports = subprocess.check_output(["nm", "-gU", str(matches[0] / "GamePropelUnity")], text=True)
        for symbol in (PACKAGE / "Native~/iOS/UnityExports.txt").read_text().splitlines():
            if symbol and symbol not in exports:
                raise RuntimeError("Missing Unity C export: " + symbol)
        archives.append(matches[0])
    framework = output / "GamePropelUnity.xcframework"
    if framework.exists(): shutil.rmtree(framework)
    command = ["xcodebuild", "-create-xcframework"]
    for archive in archives: command += ["-framework", archive]
    run(command + ["-output", framework])
    dependency = output / "GameAlgoScriptRuntime.xcframework"
    if dependency.exists(): shutil.rmtree(dependency)
    shutil.copytree(REPO / "ios/GameAlgoScriptRuntime.xcframework", dependency)
    # Unity only exports iOS from this package. Keep desktop binaries in the
    # native Swift package rather than shipping them to every Unity consumer.
    manifest = dependency / "Info.plist"
    contents = plistlib.loads(manifest.read_bytes())
    libraries = contents["AvailableLibraries"]
    contents["AvailableLibraries"] = [library for library in libraries if library["SupportedPlatform"] == "ios"]
    for library in libraries:
        if library["SupportedPlatform"] != "ios":
            shutil.rmtree(dependency / library["LibraryIdentifier"])
    manifest.write_bytes(plistlib.dumps(contents))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--android", action="store_true")
    parser.add_argument("--ios", action="store_true")
    args = parser.parse_args()
    if not args.android and not args.ios: parser.error("select --android and/or --ios")
    BUILD.mkdir(parents=True, exist_ok=True)
    if args.android: android()
    if args.ios: ios()
