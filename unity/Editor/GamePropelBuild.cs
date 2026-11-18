using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
#if UNITY_IOS
using UnityEditor.iOS.Xcode;
using UnityEditor.iOS.Xcode.Extensions;
#endif

namespace GamePropel.Editor
{
    public sealed class GamePropelBuild : IPreprocessBuildWithReport, IPostprocessBuildWithReport
    {
        public int callbackOrder => 1000;
        private static string Root => UnityEditor.PackageManager.PackageInfo.FindForAssembly(typeof(GamePropelBuild).Assembly)?.resolvedPath
            ?? throw new BuildFailedException("Cannot locate com.gamepropel.sdk.");

        public void OnPreprocessBuild(BuildReport report)
        {
            switch (report.summary.platform)
            {
                case BuildTarget.Android:
                    if ((int)PlayerSettings.Android.minSdkVersion < 24)
                        throw new BuildFailedException("GamePropel requires Android API 24 or later.");
                    Require("Runtime/Plugins/Android/gamealgo-android.aar");
                    Require("Runtime/Plugins/Android/gamepropel-unity.aar");
                    break;
                case BuildTarget.iOS:
                    if (!Version.TryParse(PlayerSettings.iOS.targetOSVersionString, out var version) || version < new Version(15, 0))
                        throw new BuildFailedException("This GamePropel binary package requires iOS 15 or later.");
                    Require("Binaries~/iOS/GamePropelUnity.xcframework/Info.plist");
                    Require("Binaries~/iOS/GameAlgoScriptRuntime.xcframework/Info.plist");
                    break;
                default:
                    throw new BuildFailedException("GamePropel supports Android/iOS builds.");
            }
        }

        public void OnPostprocessBuild(BuildReport report)
        {
#if UNITY_IOS
            if (report.summary.platform != BuildTarget.iOS) return;
            var output = report.summary.outputPath;
            var projectFile = PBXProject.GetPBXProjectPath(output);
            var project = new PBXProject(); project.ReadFromFile(projectFile);
            var main = project.GetUnityMainTargetGuid();
            var framework = project.GetUnityFrameworkTargetGuid();
            var simulator = PlayerSettings.iOS.sdkVersion == iOSSdkVersion.SimulatorSDK;
            foreach (var name in new[] { "GamePropelUnity", "GameAlgoScriptRuntime" })
            {
                var source = SelectFramework(Path.Combine(Root, "Binaries~/iOS", name + ".xcframework"), simulator);
                var relative = "Frameworks/GamePropel/" + name + ".framework";
                CopyDirectory(source, Path.Combine(output, relative));
                var guid = project.FindFileGuidByProjectPath(relative);
                if (string.IsNullOrEmpty(guid)) guid = project.AddFile(relative, relative, PBXSourceTree.Source);
                project.AddFileToBuild(framework, guid);
                project.AddFileToEmbedFrameworks(main, guid);
            }
            project.AddBuildProperty(framework, "FRAMEWORK_SEARCH_PATHS", "$(PROJECT_DIR)/Frameworks/GamePropel");
            project.AddBuildProperty(framework, "LD_RUNPATH_SEARCH_PATHS", "@executable_path/Frameworks");
            project.AddBuildProperty(main, "LD_RUNPATH_SEARCH_PATHS", "@executable_path/Frameworks");
            project.SetBuildProperty(main, "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES", "YES");
            // Runtime AAAttribution discovery still needs AdServices loaded.
            project.AddFrameworkToProject(framework, "AdServices.framework", true);
            project.WriteToFile(projectFile);
#endif
        }

        private static void Require(string relative)
        {
            if (!File.Exists(Path.Combine(Root, relative)))
                throw new BuildFailedException("Missing GamePropel native artifact: " + relative + ". Use the prepared Unity release package, or run Tools~/build_native.py in a source checkout.");
        }

#if UNITY_IOS
        private static string SelectFramework(string root, bool simulator)
        {
            var plist = new PlistDocument(); plist.ReadFromFile(Path.Combine(root, "Info.plist"));
            foreach (var entry in plist.root["AvailableLibraries"].AsArray().values)
            {
                var library = entry.AsDict();
                if (library["SupportedPlatform"].AsString() != "ios") continue;
                var isSimulator = library.values.TryGetValue("SupportedPlatformVariant", out var variant) && variant.AsString() == "simulator";
                if (isSimulator == simulator)
                    return Path.Combine(root, library["LibraryIdentifier"].AsString(), library["LibraryPath"].AsString());
            }
            throw new BuildFailedException("GamePropel XCFramework lacks the selected device/simulator slice.");
        }
        private static void CopyDirectory(string source, string destination)
        {
            if (Directory.Exists(destination)) Directory.Delete(destination, true);
            Directory.CreateDirectory(destination);
            foreach (var path in Directory.GetFiles(source)) File.Copy(path, Path.Combine(destination, Path.GetFileName(path)), true);
            foreach (var path in Directory.GetDirectories(source)) CopyDirectory(path, Path.Combine(destination, Path.GetFileName(path)));
        }
#endif
    }
}
