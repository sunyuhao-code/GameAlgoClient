#!/usr/bin/env python3
"""Exercises the real JNI bridge/AAR in an emulator against a local HTTP stub."""
import argparse
import datetime
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import threading
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--serial", default="emulator-5554")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
receipts = []
run_id = uuid.uuid4().hex
script = "function execute(input) { return { payload: input.state, diagnostics: { nativeProbe: true } }; }"
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *unused): pass
    def respond(self, body, content_type="application/json"):
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", content_type); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path == "/script.js": self.respond(script, "application/javascript")
        else: self.respond({"ok": True})
    def do_POST(self):
        value = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        receipts.append({"path": self.path, "body": value})
        if self.path == "/v1/config":
            port = self.server.server_port
            self.respond({"contextId": "ctx-" + value["sessionId"], "gameId": "offline-probe", "environment": "live", "configVersion": "1", "ttlSeconds": 300,
                          "serverTime": datetime.datetime.now(datetime.timezone.utc).isoformat(), "experiments": [{"key": "probe", "experimentId": "exp-probe", "variant": "control", "config": {},
                          "script": {"name": "probe.js", "versionId": "version-1", "url": f"http://10.0.2.2:{port}/script.js", "hash": "sha256:" + hashlib.sha256(script.encode()).hexdigest()}}], "configFiles": []})
        elif self.path == "/v1/events/batch": self.respond({"ok": True, "accepted": len(value["events"]), "stored": len(value["events"]), "rejected": []})
        elif self.path == "/v1/context-identifiers": self.respond({"ok": True, "accepted": 1, "identifierHash": "offline-probe"})
        else: self.respond({"ok": True, "accepted": 1})

def adb(*command): return subprocess.check_output(["adb", "-s", args.serial, *command], text=True)
def logs(): return "\n".join(line for line in adb("logcat", "-d", "-v", "brief", "GamePropelUnityProbe:I", "*:S").splitlines() if run_id in line)
def until(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.15)
    raise AssertionError("Native probe timed out")

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
package = "com.gamepropel.unityprobe"
try:
    apk = root / "Native~/Android/probe/build/outputs/apk/debug/probe-debug.apk"
    adb("install", "-r", str(apk))
    adb("shell", "pm", "clear", package)
    # Clear only this test's app state; other apps and their logs are untouched.
    adb("shell", "am", "start", "-n", package + "/.ProbeActivity", "--es", "base_url", f"http://10.0.2.2:{server.server_port}", "--es", "run_id", run_id)
    until(lambda: "PASS " in logs() or "FAIL " in logs())
    log = logs(); assert "FAIL " not in log, log
    batches = [e for row in receipts if row["path"] == "/v1/events/batch" for e in row["body"]["events"]]
    assert {"level_start", "level_end", "milestone", "_probe_custom", "session_end"}.issubset({e["eventType"] for e in batches})
    assert all(e["isDebug"] for e in batches)
    assert any(e["payload"].get("level_id") == "第一关" for e in batches)
    configs = [row["body"] for row in receipts if row["path"] == "/v1/config"]
    assert all(c["platform"] == "android" and c["device"]["runtime"] == "unity" for c in configs)
    assert any(row["path"] == "/v1/context-identifiers" and row["body"]["identifierType"] == "oaid" for row in receipts)
    assert configs[-1]["sessionId"] == "probe-new-session"
    assert len(configs) == 3, "Same-session calls and default refresh must not force a new config request"
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    until(lambda: any(e["eventType"] == "session_end" and e["sessionId"] == "probe-new-session"
                     for row in receipts if row["path"] == "/v1/events/batch" for e in row["body"]["events"]))
    adb("shell", "am", "start", "-n", package + "/.ProbeActivity")
    until(lambda: logs().count("RESUME ") >= 2)
    assert len([row for row in receipts if row["path"] == "/v1/config"]) == len(configs), "Foreground restoration must not rotate the session"
    result = {"passed": True, "platform": "Android emulator, native bridge (not a Unity player)", "productionTraffic": False,
              "checks": ["native initialization", "event/context/Unicode envelopes", "custom prefix", "OAID", "native Rust execution", "explicit session switch", "automatic background end", "same session on resume"]}
    (root / "build/android-probe-result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
finally:
    (root / "build/android-probe-receipts.json").write_text(json.dumps(receipts, ensure_ascii=False, indent=2))
    adb("shell", "am", "force-stop", package)
    server.shutdown(); server.server_close()
