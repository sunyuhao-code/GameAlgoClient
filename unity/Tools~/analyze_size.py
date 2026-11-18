#!/usr/bin/env python3
"""Controlled Android IL2CPP size experiments; never edits the shipped SDK.

Builds independent JSON DOM/generic-conversion probes or the current SDK.
The JSON probes reproduce the cost of an optional third-party dependency.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--editor', type=Path, required=True)
parser.add_argument('--case', choices=['json_dom', 'json_generic', 'sdk'], required=True)
args = parser.parse_args()
package = Path(__file__).resolve().parents[1]
root = package / 'build/size-analysis'
work = root / args.case
project = work / 'project'
work.mkdir(parents=True, exist_ok=True)
settings = package / 'build/player-validation/android/baseline-project/ProjectSettings'
shutil.copytree(settings, project / 'ProjectSettings', dirs_exist_ok=True)
(project / 'Assets/Editor').mkdir(parents=True, exist_ok=True)
(project / 'Packages').mkdir(exist_ok=True)
shutil.copy2(package / 'Tools~/PlayerValidation/Build.cs', project / 'Assets/Editor/Build.cs')
deps = {f'com.unity.modules.{name}': '1.0.0' for name in ['androidjni', 'imgui', 'jsonserialize']}
if args.case.startswith('json_'):
    deps['com.unity.nuget.newtonsoft-json'] = '3.2.1'
    source = (package / 'Tools~/PlayerValidation/Baseline.cs').read_text()
    source = source.replace('using UnityEngine;', 'using UnityEngine;\nusing Newtonsoft.Json;\nusing Newtonsoft.Json.Linq;')
    extra = '''
        var node = JObject.Parse("{\\"value\\":7}");
        var result = node.Value<int>("value");
        Debug.Log(node.ToString(Formatting.None) + result);
'''
    if args.case == 'json_generic':
        extra += '''
        object fallback = 7;
        var converted = JToken.FromObject(fallback).ToObject<int>();
        Debug.Log(converted);
'''
    source = source.replace('        await Task.Delay(1500);', extra + '\n        await Task.Delay(1500);')
    (project / 'Assets/GamePropelUnityBaseline.cs').write_text(source)
else:
    deps['com.gamepropel.sdk'] = 'file:' + str(package / 'build/com.gamepropel.sdk-1.0.0.tgz')
    (project / 'Assets/Resources').mkdir(exist_ok=True)
    shutil.copy2(package / 'Tools~/PlayerValidation/Probe.cs', project / 'Assets/GamePropelUnityPlayerProbe.cs')
    (project / 'Assets/Resources/gamepropel-validation.json').write_text(json.dumps({'runId': 'size-diagnostic', 'baseUrl': 'http://10.0.2.2:18741'}))
(project / 'Packages/manifest.json').write_text(json.dumps({'dependencies': deps}, indent=2))
env = os.environ.copy()
env['GP_TEST_OUTPUT'] = str(work / 'player.apk')
env['GP_TEST_BUNDLE'] = 'com.gamepropel.size' + args.case.replace('_', '')
command = [str(args.editor), '-batchmode', '-quit', '-nographics', '-projectPath', str(project), '-buildTarget', 'Android',
           '-executeMethod', 'GamePropelPlayerValidationBuild.Android', '-logFile', str(work / 'editor.log')]
with (work / 'process.log').open('w') as output:
    subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)
with zipfile.ZipFile(work / 'player.apk') as archive:
    result = {'case': args.case, 'apkBytes': (work / 'player.apk').stat().st_size,
              'uncompressedBytes': sum(f.file_size for f in archive.infolist()),
              'files': {f.filename: {'raw': f.file_size, 'compressed': f.compress_size} for f in archive.infolist()
                        if f.filename.endswith(('libil2cpp.so', 'libgamealgo_script_runtime.so', 'global-metadata.dat', 'classes.dex'))}}
(work / 'result.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
