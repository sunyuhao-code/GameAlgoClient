"""Bundle exact current SDK and a pinned pre-fix SDK; never bundle real game keys."""
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BASELINE = "417a619"
MODULES = ["GameAlgo", "HttpTransport", "MakerAutoStorage", "LuaScriptRuntime", "Sha256", "DDA"]
for variant in ["baseline", "fixed"]:
    dest = HERE / "build" / "probe-assets" / variant / "sdk"
    dest.mkdir(parents=True, exist_ok=True)
    for module in MODULES:
        relative = "lua/" + module + ".lua"
        source = (ROOT / relative).read_bytes() if variant == "fixed" else subprocess.check_output(
            ["git", "show", BASELINE + ":" + relative], cwd=ROOT)
        (dest / (module + ".lua")).write_bytes(source)
print("Prepared unchanged current SDK and pinned 2.1.3-lua assets")
