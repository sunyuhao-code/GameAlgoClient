#!/usr/bin/env python3
"""Create the UPM tarball without caches, credentials or intermediate builds."""
import hashlib
import json
from pathlib import Path
import tarfile

root = Path(__file__).resolve().parents[1]
version = json.loads((root / "package.json").read_text())["version"]
required = ["Runtime/Plugins/Android/gamealgo-android.aar", "Runtime/Plugins/Android/gamepropel-unity.aar",
            "Binaries~/iOS/GamePropelUnity.xcframework/Info.plist", "Binaries~/iOS/GameAlgoScriptRuntime.xcframework/Info.plist"]
for relative in required:
    if not (root / relative).is_file(): raise SystemExit("Build native artifacts first: " + relative)

# Stable Unity asset GUIDs keep package upgrades and imported samples consistent.
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root)
    if any((part.endswith("~") and part != "Samples~") or part in {"build", ".git"} for part in relative.parts) or path.name.startswith(".") or path.suffix == ".meta": continue
    if path.is_dir() and path.name.endswith("~"): continue
    guid = hashlib.sha256(("gamepropel-unity/" + relative.as_posix()).encode()).hexdigest()[:32]
    if path.is_dir(): body = "folderAsset: yes\nDefaultImporter:\n  externalObjects: {}\n"
    elif path.suffix == ".aar": body = """PluginImporter:
  externalObjects: {}
  serializedVersion: 2
  isPreloaded: 0
  isOverridable: 0
  validateReferences: 1
  platformData:
  - first:
      Any:
    second:
      enabled: 0
      settings: {}
  - first:
      Android: Android
    second:
      enabled: 1
      settings:
        CPU: AnyCPU
"""
    elif path.suffix == ".cs": body = "MonoImporter:\n  externalObjects: {}\n  serializedVersion: 2\n  defaultReferences: []\n  executionOrder: 0\n  icon: {instanceID: 0}\n"
    elif path.suffix == ".asmdef": body = "AssemblyDefinitionImporter:\n  externalObjects: {}\n"
    elif path.suffix in {".json", ".md", ".xml"}: body = "TextScriptImporter:\n  externalObjects: {}\n"
    else: body = "DefaultImporter:\n  externalObjects: {}\n"
    Path(str(path) + ".meta").write_text("fileFormatVersion: 2\nguid: " + guid + "\n" + body)

output = root / "build" / ("com.gamepropel.sdk-" + version + ".tgz")
output.parent.mkdir(exist_ok=True)
def include(path):
    parts = path.relative_to(root).parts
    return not any(part in {"build", ".build", ".swiftpm", ".gradle", "bin", "obj", "__pycache__"} or part.startswith(".") for part in parts)
with tarfile.open(output, "w:gz") as archive:
    for path in sorted(root.rglob("*")):
        if path.is_file() and include(path): archive.add(path, "package/" + path.relative_to(root).as_posix(), recursive=False)
print(output)
print("sha256 " + hashlib.sha256(output.read_bytes()).hexdigest())
