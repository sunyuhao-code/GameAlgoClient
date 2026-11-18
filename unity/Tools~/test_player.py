#!/usr/bin/env python3
"""Build real IL2CPP players and compare a disposable empty project with the SDK.

Requires a licensed Unity Editor, Android/iOS build modules and local simulators.
All SDK traffic goes to an in-process localhost stub, never a production game.
"""
import argparse
import datetime
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import threading
import time
import uuid
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--editor', type=Path)
parser.add_argument('--platform', choices=['android', 'ios'], default='android')
parser.add_argument('--serial', default='emulator-5554')
parser.add_argument('--simulator', default='booted')
parser.add_argument('--prepare-only', action='store_true')
parser.add_argument('--editor-play', action='store_true')
parser.add_argument('--reuse-build', action='store_true')
parser.add_argument('--variant', choices=['baseline', 'sdk', 'both'], default='both')
parser.add_argument('--ios-device-size', action='store_true', help='Build unsigned Release device apps and compare compressed IPA payloads; no device execution')
parser.add_argument('--max-increment-bytes', type=int, default=1000000, help='Compressed package increment must be below this limit (default: 1000000)')
options = parser.parse_args()
if options.ios_device_size and options.platform != 'ios':
    parser.error('--ios-device-size requires --platform ios')
if options.max_increment_bytes <= 0:
    parser.error('--max-increment-bytes must be positive')
package = Path(__file__).resolve().parents[1]
work = package / 'build/player-validation' / ('ios-device' if options.ios_device_size else options.platform)
work.mkdir(parents=True, exist_ok=True)
if not options.prepare_only:
    # A failed new run must not leave an old successful result looking current.
    (work / (options.variant + '-result.json')).unlink(missing_ok=True)
port = 18741 if options.platform == 'android' else 18742
endpoint = f'http://10.0.2.2:{port}' if options.platform == 'android' else f'http://127.0.0.1:{port}'
run_id = uuid.uuid4().hex
sdk_project = work / 'sdk-project'
if options.reuse_build:
    run_id = json.loads((sdk_project / 'Assets/Resources/gamepropel-validation.json').read_text())['runId']
receipts = []
script = 'function execute(input) { return { payload: input.state, diagnostics: { unityPlayerProbe: true } }; }'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass

    def respond(self, value, content_type='application/json'):
        data = value.encode() if isinstance(value, str) else json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.respond(script, 'application/javascript')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        receipts.append({'path': self.path, 'body': body})
        if self.path == '/v1/config':
            self.respond({'contextId': 'ctx-' + body['sessionId'], 'gameId': 'offline-unity-player',
                          'environment': 'live', 'configVersion': '1', 'ttlSeconds': 300,
                          'serverTime': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                          'experiments': [{'key': 'probe', 'experimentId': 'exp-unity', 'variant': 'control', 'config': {'value': 7},
                                           'script': {'name': 'probe.js', 'versionId': 'v1', 'url': endpoint + '/script.js',
                                                      'hash': 'sha256:' + hashlib.sha256(script.encode()).hexdigest()}}], 'configFiles': []})
        elif self.path == '/v1/context-identifiers':
            self.respond({'ok': True, 'accepted': 1, 'identifierHash': 'offline-unity'})
        else:
            self.respond({'ok': True, 'accepted': len(body.get('events', [])), 'stored': len(body.get('events', [])), 'rejected': []})


def run(command, log=None, env=None, cwd=None):
    print('Running', command[0], ' '.join(str(x) for x in command[1:5]), flush=True)
    if log:
        with Path(log).open('w') as output:
            subprocess.run([str(x) for x in command], stdout=output, stderr=subprocess.STDOUT, env=env, cwd=cwd, check=True)
    else:
        try:
            return subprocess.check_output([str(x) for x in command], text=True, env=env, cwd=cwd, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError as error:
            print(error.output, flush=True)
            raise


def prepare(variant):
    project = work / (variant + '-project')
    settings = project / 'ProjectSettings'
    initialized = package / 'build/player-validation/android/sdk-project/ProjectSettings'
    if not (settings / 'ProjectVersion.txt').exists() and (initialized / 'ProjectVersion.txt').exists() and settings != initialized:
        shutil.copytree(initialized, settings, dirs_exist_ok=True)
    (project / 'Assets/Editor').mkdir(parents=True, exist_ok=True)
    (project / 'Assets/Resources').mkdir(exist_ok=True)
    (project / 'Packages').mkdir(exist_ok=True)
    (project / 'ProjectSettings').mkdir(exist_ok=True)
    shutil.copy2(package / 'Tools~/PlayerValidation/Build.cs', project / 'Assets/Editor/Build.cs')
    dependencies = {f'com.unity.modules.{name}': '1.0.0' for name in ['androidjni', 'imgui', 'jsonserialize']}
    if variant == 'sdk':
        archive = package / 'build/com.gamepropel.sdk-1.0.0.tgz'
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        imported = work / ('sdk-' + digest[:12] + '.tgz')
        if not imported.exists(): shutil.copy2(archive, imported)
        dependencies['com.gamepropel.sdk'] = 'file:' + str(imported)
        shutil.copy2(package / 'Tools~/PlayerValidation/Probe.cs', project / 'Assets/GamePropelUnityPlayerProbe.cs')
        (project / 'Assets/Resources/gamepropel-validation.json').write_text(json.dumps({'runId': run_id, 'baseUrl': endpoint}))
    else:
        shutil.copy2(package / 'Tools~/PlayerValidation/Baseline.cs', project / 'Assets/GamePropelUnityBaseline.cs')
    (project / 'Assets/Probe.cs').unlink(missing_ok=True)
    (project / 'Assets/Probe.cs.meta').unlink(missing_ok=True)
    (project / 'Packages/manifest.json').write_text(json.dumps({'dependencies': dependencies}, indent=2))
    return project


def build(variant):
    project = prepare(variant)
    output = work / variant / ('player.apk' if options.platform == 'android' else 'xcode')
    output.parent.mkdir(exist_ok=True)
    env = os.environ.copy()
    env['GP_TEST_OUTPUT'] = str(output)
    env['GP_TEST_BUNDLE'] = 'com.gamepropel.unityplayer' + variant
    run([options.editor, '-batchmode', '-quit', '-nographics', '-projectPath', project,
         '-buildTarget', 'Android' if options.platform == 'android' else 'iOS',
         '-executeMethod', 'GamePropelPlayerValidationBuild.Android' if options.platform == 'android' else ('GamePropelPlayerValidationBuild.IosDevice' if options.ios_device_size else 'GamePropelPlayerValidationBuild.Ios'),
         '-logFile', work / (variant + '-editor.log')], work / (variant + '-process.log'), env=env)


def wait_for(predicate, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.3)
    raise AssertionError('Unity player validation timed out')


def events():
    return [e for row in receipts if row['path'] == '/v1/events/batch' for e in row['body']['events']]


def test_android():
    def adb(*command):
        return run(['adb', '-s', options.serial, *command])

    def logs():
        return '\n'.join(line for line in adb('logcat', '-d', '-v', 'brief', 'Unity:I', '*:S').splitlines() if 'GP_UNITY_PLAYER ' + run_id in line)

    bundle = 'com.gamepropel.unityplayersdk'
    try:
        adb('wait-for-device')
        adb('install', '-r', str(work / 'sdk/player.apk'))
        adb('shell', 'pm', 'clear', bundle)  # Disposable probe only.
        component = adb('shell', 'cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', bundle).strip().splitlines()[-1]
        assert '/' in component, component
        adb('shell', 'am', 'start', '-W', '-n', component)
        wait_for(lambda: ' PASS ' in logs() or ' FAIL ' in logs(), 90)
        assert ' FAIL ' not in logs(), logs()
        validate_receipts()
        count = len([r for r in receipts if r['path'] == '/v1/config'])
        adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        wait_for(lambda: any(e['eventType'] == 'session_end' and e['sessionId'] == 'unity-' + run_id for e in events()))
        time.sleep(5)
        heartbeat_count = len([e for e in events() if e['eventType'] == '_unity_probe_heartbeat'])
        adb('shell', 'am', 'start', '-W', '-n', component)
        wait_for(lambda: len([e for e in events() if e['eventType'] == '_unity_probe_heartbeat']) > heartbeat_count)
        assert count == len([r for r in receipts if r['path'] == '/v1/config']), 'Resume rotated the session'
        (work / 'sdk-runtime.log').write_text(logs())
    finally:
        adb('shell', 'am', 'force-stop', bundle)


def test_ios():
    # Export/link validation is useful even when no physical iOS device is attached.
    for variant in (['baseline', 'sdk'] if options.variant == 'both' else [options.variant]):
        export = work / variant / 'xcode'
        plist_path = export / 'Info.plist'
        plist = plistlib.loads(plist_path.read_bytes())
        plist['CFBundleURLTypes'] = [{'CFBundleURLName': 'GamePropel disposable probe', 'CFBundleURLSchemes': ['gamepropel-unity-probe']}]
        plist_path.write_bytes(plistlib.dumps(plist))
        run(['xcodebuild', '-project', export / 'Unity-iPhone.xcodeproj', '-scheme', 'Unity-iPhone',
             '-sdk', 'iphoneos' if options.ios_device_size else 'iphonesimulator', '-configuration', 'Release',
             '-destination', 'generic/platform=iOS' if options.ios_device_size else 'generic/platform=iOS Simulator',
             '-derivedDataPath', work / variant / 'derived', 'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES'],
            work / (variant + '-xcode.log'))
    if options.variant == 'baseline' or options.ios_device_size:
        return
    products = work / 'sdk/derived/Build/Products/Release-iphonesimulator'
    apps = list(products.glob('*.app'))
    assert len(apps) == 1, 'Expected one simulator application: ' + str(apps)
    app = apps[0]
    bundle = 'com.gamepropel.unityplayersdk'
    # Reset only this disposable probe's data, including durable milestones.
    subprocess.run(['xcrun', 'simctl', 'uninstall', options.simulator, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run(['xcrun', 'simctl', 'install', options.simulator, app])
    with (work / 'sdk-runtime.log').open('w') as log:
        process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console-pty', '--terminate-running-process', options.simulator, bundle], stdout=log, stderr=subprocess.STDOUT)
        try:
            def output():
                return (work / 'sdk-runtime.log').read_text(errors='replace')
            wait_for(lambda: ' PASS ' in output() or ' FAIL ' in output(), 90)
            assert ' FAIL ' not in output(), output()[-6000:]
            validate_receipts()
            config_count = len([r for r in receipts if r['path'] == '/v1/config'])
            run(['xcrun', 'simctl', 'launch', options.simulator, 'com.apple.Preferences'])
            wait_for(lambda: any(e['eventType'] == 'session_end' and e['sessionId'] == 'unity-' + run_id for e in events()))
            time.sleep(5)
            heartbeat_count = len([e for e in events() if e['eventType'] == '_unity_probe_heartbeat'])
            activation = work / 'activation'
            run(['ruby', package / 'Tools~/PlayerValidation/create_activation_project.rb', activation])
            simulator = options.simulator
            if simulator == 'booted':
                devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'booted', '--json']))
                booted = [d['udid'] for rows in devices['devices'].values() for d in rows if d['state'] == 'Booted']
                assert len(booted) == 1, 'Specify --simulator when several devices are booted'
                simulator = booted[0]
            run(['xcodebuild', 'test', '-project', activation / 'Activate.xcodeproj', '-scheme', 'Activate',
                 '-destination', 'id=' + simulator, '-derivedDataPath', activation / 'derived',
                 'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES'], work / 'activate-ios.log')
            wait_for(lambda: len([e for e in events() if e['eventType'] == '_unity_probe_heartbeat']) > heartbeat_count)
            assert config_count == len([r for r in receipts if r['path'] == '/v1/config']), 'Resume rotated the session'
        finally:
            run(['xcrun', 'simctl', 'terminate', options.simulator, bundle])
            process.wait(timeout=15)


def validate_receipts():
    rows = events()
    assert {'level_start', 'level_end', 'milestone', '_unity_probe', 'session_end'}.issubset({e['eventType'] for e in rows})
    assert all(e['isDebug'] for e in rows)
    configs = [r['body'] for r in receipts if r['path'] == '/v1/config']
    assert configs and all(c['platform'] == options.platform and c['device']['runtime'] == 'unity' for c in configs)
    assert all(c['device']['unityVersion'] for c in configs)
    assert configs[-1]['sessionId'] == 'unity-' + run_id
    assert any(e['payload'].get('level_id') == '第一关' for e in rows)
    assert any(r['path'] == '/v1/context-identifiers' for r in receipts)


def compare_sizes():
    result = {}
    for variant in ['baseline', 'sdk']:
        if options.platform == 'android':
            path = work / variant / 'player.apk'
            if path.exists():
                with zipfile.ZipFile(path) as archive:
                    result[variant] = {'apkBytes': path.stat().st_size, 'uncompressedBytes': sum(f.file_size for f in archive.infolist()),
                                       'nativeLibraries': {f.filename: f.file_size for f in archive.infolist() if f.filename.endswith('.so')}}
        else:
            products = work / variant / 'derived/Build/Products' / ('Release-iphoneos' if options.ios_device_size else 'Release-iphonesimulator')
            if products.exists():
                apps = list(products.glob('*.app'))
                if len(apps) == 1:
                    raw_bytes = sum(p.stat().st_size for p in apps[0].rglob('*') if p.is_file())
                    if options.ios_device_size:
                        ipa = work / variant / 'unsigned-size-only.ipa'
                        with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
                            for item in sorted(apps[0].rglob('*')):
                                if item.is_file(): archive.write(item, 'Payload/' + apps[0].name + '/' + str(item.relative_to(apps[0])))
                        result[variant] = {'deviceAppBytes': raw_bytes, 'compressedIpaBytes': ipa.stat().st_size}
                    else:
                        result[variant] = {'simulatorAppBytes': raw_bytes}
    if 'baseline' in result and 'sdk' in result:
        key = 'apkBytes' if options.platform == 'android' else ('compressedIpaBytes' if options.ios_device_size else 'simulatorAppBytes')
        result['differenceBytes'] = result['sdk'][key] - result['baseline'][key]
        if options.platform == 'android' or options.ios_device_size:
            result['maximumIncrementBytes'] = options.max_increment_bytes
            result['withinBudget'] = result['differenceBytes'] < options.max_increment_bytes
            if not result['withinBudget']:
                (work / 'size-budget-failure.json').write_text(json.dumps(result, indent=2))
                raise AssertionError('SDK package increment exceeds the size budget: ' + str(result))
            (work / 'size-budget-failure.json').unlink(missing_ok=True)
    elif options.variant != 'baseline' and (options.platform == 'android' or options.ios_device_size):
        raise AssertionError('A matching baseline package is required for the SDK size check. Run --variant both first.')
    return result


if options.prepare_only:
    for variant in ['baseline', 'sdk']:
        prepare(variant)
    print('Prepared', work)
    raise SystemExit(0)
if not options.reuse_build and (not options.editor or not options.editor.is_file()):
    parser.error('--editor must point to the licensed Unity Editor executable')
if options.editor_play:
    project = prepare('sdk')
    run([options.editor, '-batchmode', '-nographics', '-projectPath', project,
         '-executeMethod', 'GamePropelPlayerValidationBuild.EditorPlay',
         '-logFile', work / 'editor-play.log'], work / 'editor-play-process.log')
    assert ' EDITOR_PASS' in (work / 'editor-play.log').read_text(errors='replace')
    print('Real Unity Editor play mode passed (unsupported platform is explicit)')
    raise SystemExit(0)
server = None
if options.variant != 'baseline' and not options.ios_device_size:
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    if not options.reuse_build:
        for variant in (['baseline', 'sdk'] if options.variant == 'both' else [options.variant]):
            build(variant)
    if options.platform == 'android' and options.variant != 'baseline':
        test_android()
    elif options.platform == 'ios':
        test_ios()
    result = {'passed': True, 'platform': options.platform, 'variant': options.variant,
              'runtimeTested': options.variant != 'baseline' and not options.ios_device_size, 'runId': run_id,
              'productionTraffic': False, 'sizes': compare_sizes()}
    (work / (options.variant + '-result.json')).write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
finally:
    (work / (options.variant + '-receipts.json')).write_text(json.dumps(receipts, ensure_ascii=False, indent=2))
    if server is not None:
        server.shutdown()
        server.server_close()
