"""Run controlled native Android HTTP/File regressions; never contact GamePropel.

The container dispatches Maker-shaped lifecycle callbacks and intentionally
defers Lua HTTP callbacks while backgrounded. It is not the real TapTap host.
"""
import argparse
import datetime as dt
import http.server
import hashlib
import json
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
PACKAGE = "com.gamepropel.makerprobe"
LOCK = threading.Lock()
RECORDS = []
FAILURES = set()
PORT = 18765


class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        case = self.headers.get("X-Probe-Case", "")
        variant = self.headers.get("X-Probe-Variant", "")
        record = dict(at=time.time(), path=self.path, case=case, variant=variant, body=body)
        with LOCK:
            RECORDS.append(record)
        status = 200
        if self.path == "/v1/config":
            reply = dict(contextId=str(uuid.uuid4()), gameId="isolated-android-probe",
                         configVersion="probe", experiments=[], configFiles=[])
            record["contextId"] = reply["contextId"]
        else:
            events = body.get("events", [])
            key = (variant, case)
            if (case.startswith("priority_failure_") and len(events) == 1
                    and events[0]["eventType"] == "session_end" and key not in FAILURES):
                FAILURES.add(key)
                status = 503
            reply = dict(ok=status == 200, accepted=len(events) if status == 200 else 0,
                         rejected=[])
            record["status"] = status
            # Record receipt before holding the response. A separate request
            # can still deliver the end snapshot on the server's other thread.
            wait = max((e.get("payload", {}).get("holdResponseMs", 0) for e in events), default=0)
            if wait:
                time.sleep(min(8000, wait) / 1000)
        record["status"] = status
        encoded = json.dumps(reply).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The test deliberately destroys clients before held ACKs.


def run(serial, *args, timeout=20):
    return subprocess.check_output(["adb", "-s", serial, *args], timeout=timeout).decode().strip()


def records(case, variant):
    with LOCK:
        return [r for r in RECORDS if r["case"] == case and r["variant"] == variant]


def ends(case, variant, context=None):
    out = []
    for row in records(case, variant):
        for event in row["body"].get("events", []):
            if event["eventType"] == "session_end" and (context is None or event["contextId"] == context):
                out.append((row, event))
    return out


def wait_for(fn, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for probe condition")


def launch(serial, variant, case, background="pair"):
    old_configs = sum(r["path"] == "/v1/config" for r in records(case, variant))
    run(serial, "shell", "am", "start", "-W", "-n", PACKAGE + "/.ProbeActivity",
        "--es", "variant", variant, "--es", "case", case, "--es", "background", background,
        "--es", "baseUrl", "http://10.0.2.2:" + str(PORT))
    configs = wait_for(lambda: [r for r in records(case, variant) if r["path"] == "/v1/config"]
                       if sum(r["path"] == "/v1/config" for r in records(case, variant)) > old_configs else None)
    time.sleep(0.4)  # Allow the native config callback to bind the Context.
    return configs[-1]["contextId"]


def command(serial, command, hold=6000):
    run(serial, "shell", "am", "broadcast", "-a", PACKAGE + ".COMMAND", "-p", PACKAGE,
        "--es", "command", command, "--ei", "holdMs", str(hold))


def saved_ends(serial, event_type="session_end"):
    names = run(serial, "shell", "run-as", PACKAGE, "ls", "files").splitlines()
    files, found = {}, {}
    for name in names:
        if name.endswith(".json") and re.fullmatch(r"[\w.-]+", name):
            data = run(serial, "exec-out", "run-as", PACKAGE, "cat", "files/" + name)
            try:
                files[name] = json.loads(data)
            except ValueError:
                pass
    # Read the committed banks, not obsolete bank files retained for recovery.
    # This mirrors tests/support/PersistedSnapshot.lua and PersistedEvents.lua.
    snapshots = [files[name] for name in ["gamealgo_sdk_storage_v1.json",
                 "gamealgo_sdk_storage_v1.backup.json"] if name in files]
    snapshot = max(snapshots, key=lambda x: x["revision"])
    for key, value in snapshot["data"].items():
        if not key.endswith(":events:jsonl"):
            continue
        entries = []
        if isinstance(value, str):
            entries = [json.loads(line) for line in value.splitlines() if line]
        elif value.get("format") == "event_chunks_v1":
            prefix = "gaq_" + hashlib.sha256(key.encode()).hexdigest()[:24]
            for block in range(1, int(value["blocks"]) + 1):
                banks = [files[n] for bank in [1, 2]
                         for n in [f"{prefix}_{block}_{bank}.json"] if n in files]
                if banks:
                    best = max(banks, key=lambda x: x["revision"])
                    entries.extend(json.loads(row["event"]) for row in best.get("entries", []))
        for event in entries:
            if event["eventType"] == event_type:
                found[event["eventId"]] = event
    return found


def cold_exit(serial, variant, case, *, busy=True, background="pair", failure=False):
    run(serial, "shell", "am", "force-stop", PACKAGE)
    run(serial, "shell", "pm", "clear", PACKAGE)
    context = launch(serial, variant, case, background)
    if busy:
        command(serial, "busy")
        wait_for(lambda: any(r["body"].get("events") for r in records(case, variant)))
    before_home = time.time()
    run(serial, "shell", "input", "keyevent", "KEYCODE_HOME")
    if variant == "fixed":
        wait_for(lambda: ends(case, variant, context), seconds=4)
    time.sleep(0.5)
    checkpoint = saved_ends(serial)
    assert len(checkpoint) == 1, (variant, case, "one durable background snapshot expected", checkpoint)
    event = next(iter(checkpoint.values()))
    initial = ends(case, variant, context)
    expected = variant == "fixed" or not busy
    assert bool(initial) == expected, (variant, case, "unexpected initial delivery")
    if expected:
        assert initial[0][1]["eventId"] == event["eventId"]
        assert initial[0][0]["at"] - before_home < 4
    if failure:
        assert initial[0][0]["status"] == 503
    run(serial, "shell", "am", "force-stop", PACKAGE)
    second_context = launch(serial, variant, case, background)
    assert second_context != context
    delivered = wait_for(lambda: [(row, e) for row, e in ends(case, variant, context)
                                  if row.get("status") == 200])
    assert {e["eventId"] for _, e in delivered} == {event["eventId"]}
    for _, restored in delivered:
        for key in ["eventId", "contextId", "sessionId", "timestamp"]:
            assert restored[key] == event[key], (variant, case, key)
    run(serial, "shell", "am", "force-stop", PACKAGE)
    return dict(case=case, variant=variant, passed=True, sentBeforeRestart=bool(initial),
                durableSnapshotCount=len(checkpoint), uniqueEndIds=1,
                firstDeliveryMs=round((initial[0][0]["at"] - before_home) * 1000) if initial else None,
                controlledFailure=failure)


def foreground_drain(serial, variant, case):
    run(serial, "shell", "am", "force-stop", PACKAGE)
    run(serial, "shell", "pm", "clear", PACKAGE)
    context = launch(serial, variant, case)
    command(serial, "busy", 2500)
    wait_for(lambda: any(r["body"].get("events") for r in records(case, variant)))
    command(serial, "will")
    wait_for(lambda: ends(case, variant, context))
    time.sleep(3)
    assert len(ends(case, variant, context)) == 1, "foreground ACK drain must not repeat the accepted end"
    assert not saved_ends(serial), "successful drain must clear the durable queue"
    run(serial, "shell", "am", "force-stop", PACKAGE)
    launch(serial, variant, case)
    assert len(ends(case, variant, context)) == 1, "cold start must not resurrect an acknowledged end"
    run(serial, "shell", "am", "force-stop", PACKAGE)
    return dict(case=case, variant=variant, passed=True, uniqueEndIds=1, queueDrained=True)


def warm_resume(serial, variant, case):
    run(serial, "shell", "am", "force-stop", PACKAGE)
    run(serial, "shell", "pm", "clear", PACKAGE)
    context = launch(serial, variant, case)
    command(serial, "busy", 1200)
    wait_for(lambda: any(r["body"].get("events") for r in records(case, variant)))
    run(serial, "shell", "input", "keyevent", "KEYCODE_HOME")
    wait_for(lambda: ends(case, variant, context))
    time.sleep(1.5)
    run(serial, "shell", "am", "start", "-W", "-n", PACKAGE + "/.ProbeActivity")
    wait_for(lambda: not saved_ends(serial))
    configs = [r for r in records(case, variant) if r["path"] == "/v1/config"]
    assert len(configs) == 1, "warm resume must retain the same Context/Session"
    assert len(ends(case, variant, context)) == 1, "resumed callbacks must not resend the end"
    run(serial, "shell", "am", "force-stop", PACKAGE)
    return dict(case=case, variant=variant, passed=True, sameContextOnResume=True, queueDrained=True)


def ad_priority(serial, variant, case):
    def ads():
        return [(row, event) for row in records(case, variant)
                for event in row["body"].get("events", []) if event["eventType"] == "ad_view"]

    run(serial, "shell", "am", "force-stop", PACKAGE)
    run(serial, "shell", "pm", "clear", PACKAGE)
    context = launch(serial, variant, case)
    command(serial, "busy")
    wait_for(lambda: any(r["body"].get("events") for r in records(case, variant)))
    before_ad = time.time()
    command(serial, "ad", hold=6000)
    if variant == "fixed":
        wait_for(ads, seconds=3)
    else:
        time.sleep(0.3)
    initial = list(ads())
    assert bool(initial) == (variant == "fixed"), "ad must bypass a held ordinary ACK only in the fixed SDK"
    run(serial, "shell", "input", "keyevent", "KEYCODE_HOME")
    if variant == "fixed":
        wait_for(lambda: ends(case, variant, context), seconds=3)
    checkpoint = saved_ends(serial, "ad_view")
    assert len(checkpoint) == 1, "unacknowledged ad must remain durable"
    event = next(iter(checkpoint.values()))
    if initial:
        assert initial[0][1]["eventId"] == event["eventId"]
    run(serial, "shell", "am", "force-stop", PACKAGE)
    launch(serial, variant, case)
    delivered = wait_for(lambda: ads() if len(ads()) > len(initial) else None)
    assert {value["eventId"] for _, value in delivered} == {event["eventId"]}
    for _, restored in delivered:
        assert restored == event, "ad restart replay must preserve the entire original envelope"
    run(serial, "shell", "am", "force-stop", PACKAGE)
    return dict(case=case, variant=variant, passed=True, adSentBeforeRestart=bool(initial),
                endBypassesHeldAd=variant == "fixed", durableAdCount=1, originalAdReplayed=True,
                firstAdDeliveryMs=round((initial[0][0]["at"] - before_ad) * 1000) if initial else None)


def main():
    global PORT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--output", type=Path, default=HERE / "results")
    args = parser.parse_args()
    PORT = args.port
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    args.output.mkdir(parents=True, exist_ok=True)
    suffix = str(int(time.time()))
    results = []
    try:
        for variant in ["baseline", "fixed"]:
            result = cold_exit(args.serial, variant, "busy_" + suffix)
            results.append(result); print(json.dumps(result), flush=True)
        for case, kwargs in [("idle", dict(busy=False)),
                             ("did_only", dict(busy=False, background="did_only")),
                             ("priority_failure", dict(failure=True))]:
            result = cold_exit(args.serial, "fixed", case + "_" + suffix, **kwargs)
            results.append(result); print(json.dumps(result), flush=True)
        result = warm_resume(args.serial, "fixed", "warm_" + suffix)
        results.append(result); print(json.dumps(result), flush=True)
        result = foreground_drain(args.serial, "fixed", "foreground_" + suffix)
        results.append(result); print(json.dumps(result), flush=True)
        for variant in ["baseline", "fixed"]:
            result = ad_priority(args.serial, variant, "ad_priority_" + suffix)
            results.append(result); print(json.dumps(result), flush=True)
    finally:
        run(args.serial, "shell", "am", "force-stop", PACKAGE)
        server.shutdown()
        (args.output / "server-receipts.json").write_text(json.dumps(RECORDS, ensure_ascii=False, indent=2))
        (args.output / "results.json").write_text(json.dumps(dict(
            generatedAt=dt.datetime.now(dt.timezone.utc).isoformat(),
            environment="Android native Lua54/HTTP/File controlled container, NOT TapTap/Maker host",
            serial=args.serial, complete=len(results) == 9, expectedCases=9,
            sdkSourceSha256={variant: hashlib.sha256((HERE / "build" / "probe-assets" /
                variant / "sdk" / "GameAlgo.lua").read_bytes()).hexdigest()
                for variant in ["baseline", "fixed"]},
            cases=results), ensure_ascii=False, indent=2))
        (args.output / "logcat.txt").write_text(run(args.serial, "logcat", "-d", "-s", "MakerLuaProbe:I", "*:S"))


if __name__ == "__main__":
    main()
