using System;
using System.IO;
using System.Xml.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
#if UNITY_ANDROID
using UnityEditor.Android;
#endif
#if UNITY_IOS
using UnityEditor.Callbacks;
using UnityEditor.iOS.Xcode;
#endif

// Copied into a disposable test project by test_player.py, never into a game.
public static class GamePropelPlayerValidationBuild
{
    public static void EditorPlay()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        EditorApplication.isPlaying = true;
    }

    public static void Android()
    {
#if UNITY_ANDROID
        AndroidExternalToolsSettings.jdkRootPath = Environment.GetEnvironmentVariable("JAVA_HOME");
        AndroidExternalToolsSettings.sdkRootPath = Environment.GetEnvironmentVariable("ANDROID_HOME");
        AndroidExternalToolsSettings.ndkRootPath = Environment.GetEnvironmentVariable("ANDROID_NDK_HOME");
        PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
        PlayerSettings.Android.minSdkVersion = AndroidSdkVersions.AndroidApiLevel24;
        PlayerSettings.Android.targetSdkVersion = AndroidSdkVersions.AndroidApiLevel35;
        PlayerSettings.Android.minifyRelease = true;
        EditorUserBuildSettings.buildAppBundle = false;
        Configure(NamedBuildTarget.Android);
        Build(BuildTarget.Android);
#else
        throw new Exception("Launch the Editor with -buildTarget Android");
#endif
    }

    public static void Ios()
    {
#if UNITY_IOS
        PlayerSettings.iOS.targetOSVersionString = "15.0";
        PlayerSettings.iOS.sdkVersion = iOSSdkVersion.SimulatorSDK;
#if UNITY_6000_0_OR_NEWER
        PlayerSettings.iOS.simulatorSdkArchitecture = AppleMobileArchitectureSimulator.ARM64;
#endif
        Configure(NamedBuildTarget.iOS);
        Build(BuildTarget.iOS);
#else
        throw new Exception("Launch the Editor with -buildTarget iOS");
#endif
    }

    public static void IosDevice()
    {
#if UNITY_IOS
        PlayerSettings.iOS.targetOSVersionString = "15.0";
        PlayerSettings.iOS.sdkVersion = iOSSdkVersion.DeviceSDK;
        Configure(NamedBuildTarget.iOS);
        Build(BuildTarget.iOS);
#else
        throw new Exception("Launch the Editor with -buildTarget iOS");
#endif
    }

    private static void Configure(NamedBuildTarget target)
    {
        PlayerSettings.companyName = "GamePropel";
        PlayerSettings.productName = "GamePropel Unity validation";
        PlayerSettings.bundleVersion = "1.0.0";
        PlayerSettings.SetApplicationIdentifier(target, Environment.GetEnvironmentVariable("GP_TEST_BUNDLE"));
        PlayerSettings.SetScriptingBackend(target, ScriptingImplementation.IL2CPP);
        PlayerSettings.SetManagedStrippingLevel(target, ManagedStrippingLevel.High);
        PlayerSettings.insecureHttpOption = InsecureHttpOption.AlwaysAllowed;
        PlayerSettings.stripEngineCode = true;
        EditorUserBuildSettings.development = false;
    }

    private static void Build(BuildTarget target)
    {
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        EditorSceneManager.SaveScene(scene, "Assets/Validation.unity");
        var output = Environment.GetEnvironmentVariable("GP_TEST_OUTPUT");
        if (string.IsNullOrEmpty(output)) throw new Exception("GP_TEST_OUTPUT is required");
        var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions {
            scenes = new[] { "Assets/Validation.unity" }, locationPathName = output,
            target = target, options = BuildOptions.None
        });
        File.WriteAllText(Path.Combine(Directory.GetParent(output).FullName, "build-summary.json"), JsonUtility.ToJson(new Summary {
            result = report.summary.result.ToString(), size = report.summary.totalSize,
            errors = report.summary.totalErrors, warnings = report.summary.totalWarnings
        }, true));
        if (report.summary.result != BuildResult.Succeeded) throw new Exception("Unity player build failed");
        Debug.Log("GP_PLAYER_BUILD_PASS " + output);
    }

    [Serializable] private class Summary { public string result; public ulong size; public long errors; public long warnings; }

#if UNITY_IOS
    [PostProcessBuild(2000)]
    private static void LocalHttpOnlyForDisposableProbe(BuildTarget target, string output)
    {
        if (target != BuildTarget.iOS) return;
        var path = Path.Combine(output, "Info.plist");
        var plist = new PlistDocument(); plist.ReadFromFile(path);
        plist.root.CreateDict("NSAppTransportSecurity").SetBoolean("NSAllowsArbitraryLoads", true);
        plist.WriteToFile(path);
    }
#endif
}

#if UNITY_ANDROID
// The disposable fixture uses localhost HTTP. Production SDK packages do not
// change application network security settings.
public sealed class GamePropelLocalProbeManifest : IPostGenerateGradleAndroidProject
{
    public int callbackOrder => 2000;
    public void OnPostGenerateGradleAndroidProject(string path)
    {
        XNamespace android = "http://schemas.android.com/apk/res/android";
        foreach (var project in new[] { path, Path.Combine(path, "../launcher") })
        {
            var manifest = Path.Combine(project, "src/main/AndroidManifest.xml");
            if (!File.Exists(manifest)) continue;
            var document = XDocument.Load(manifest);
            var application = document.Root.Element("application");
            if (application == null) continue;
            application.SetAttributeValue(android + "usesCleartextTraffic", "true");
            document.Save(manifest);
        }
    }
}
#endif
