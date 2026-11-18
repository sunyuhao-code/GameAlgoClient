using System;
using System.Threading;
using System.Threading.Tasks;
using GamePropel;
using UnityEngine;

public sealed class GamePropelUnityPlayerProbe : MonoBehaviour
{
    private GamePropelClient sdk;
    private string runId;
    private bool finished;
    private string status = "Starting";
    private double nextHeartbeat;
    private bool heartbeatPending;

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void Boot()
    {
        var host = new GameObject("GamePropel player validation");
        DontDestroyOnLoad(host); host.AddComponent<GamePropelUnityPlayerProbe>();
    }

    private async void Start()
    {
        try
        {
            Application.targetFrameRate = 30;
            var settings = JsonObject.Parse(Resources.Load<TextAsset>("gamepropel-validation").text);
            runId = settings.Value<string>("runId");
            var owner = Thread.CurrentThread.ManagedThreadId;
            var endpoint = settings.Value<string>("baseUrl");
            if (!(endpoint.StartsWith("http://10.0.2.2:") || endpoint.StartsWith("http://127.0.0.1:")))
                throw new Exception("The test must use a local HTTP stub");
#if UNITY_EDITOR
            bool rejected = false;
            try { GamePropelSDK.Initialize(new GamePropelOptions { GameKey = "ga_live_unity_offline_probe" }); }
            catch (PlatformNotSupportedException) { rejected = true; }
            Check(rejected && !GamePropelSDK.IsInitialized, "Editor does not fake native initialization");
            Log("EDITOR_PASS");
            UnityEditor.EditorApplication.Exit(0);
            return;
#endif
            sdk = GamePropelSDK.Initialize(new GamePropelOptions {
                GameKey = "ga_live_unity_offline_probe", BaseUrl = endpoint,
                AppVersion = "unity-player-validation", IsDebug = true, EnableLogging = true,
                Device = new JsonObject { ["probeRunId"] = runId }
            });
            Check(await sdk.WaitForReadyAsync(15000), "native readiness");
            Check(Thread.CurrentThread.ManagedThreadId == owner, "Unity main-thread continuation");
            Check(sdk.GetStrategyConfig("probe", "value", 0) == 7, "native configuration read");
            var payload = new JsonObject { ["level_id"] = "第一关", ["level_attempt_id"] = runId, ["probeRunId"] = runId };
            Check(await sdk.TrackLevelStartAsync(payload), "level start");
            Check(await sdk.TrackEventAsync("unity_probe", payload), "custom event");
            Check(await sdk.TrackMilestoneAsync("new_user", "unity_probe", payload), "milestone");
            Check(await sdk.TrackLevelEndAsync(payload), "level end");
            Check(await sdk.TrackSessionEndAsync(payload), "manual end");
            await sdk.FlushAsync();
#if UNITY_ANDROID
            await sdk.SetIdentifierAsync(AdvertisingIdentifier.Oaid, "offline-unity-probe");
#elif UNITY_IOS
            await sdk.SetCaidAsync(new[] { new CaidValue("offline-unity-probe", "test") });
#endif
            var execution = await sdk.ExecuteAsync("probe", new JsonObject { ["value"] = 7 });
            Check(execution?["payload"]?.Value<int>("value") == 7, "native Rust execution");
            await sdk.RecordBehaviorAsync("probe", "failure");
            await sdk.CompleteStepAsync("probe", "step-1");
            await sdk.ResetDdaAsync("probe");
            await sdk.NewSessionAsync("unity-" + runId);
            Check(sdk.Identity.Value<string>("sessionId") == "unity-" + runId, "explicit session boundary");
            Check(await sdk.TrackLevelStartAsync(payload), "new session event");
            await sdk.FlushAsync();
            var before = sdk.GetForegroundTimeMs();
            await Task.Delay(2200);
            Check(sdk.GetForegroundTimeMs() > before, "native foreground clock advances while active");
            finished = true; status = "PASS";
            Log("PASS " + sdk.Identity.ToString());
        }
        catch (Exception error)
        {
            status = "FAIL " + error; Log(status);
#if UNITY_EDITOR
            UnityEditor.EditorApplication.Exit(1);
#endif
        }
    }

    private void OnApplicationPause(bool paused)
    {
        if (!finished) return;
        Log((paused ? "PAUSE " : "RESUME ") + sdk.Identity.ToString() + " foregroundMs=" + sdk.GetForegroundTimeMs());
    }
    private void OnGUI() { GUILayout.Label("GamePropel Unity player validation: " + status); }
    private void Update()
    {
        if (!finished || Time.realtimeSinceStartupAsDouble < nextHeartbeat) return;
        nextHeartbeat = Time.realtimeSinceStartupAsDouble + 1;
        Log("ALIVE " + sdk.Identity.ToString() + " foregroundMs=" + sdk.GetForegroundTimeMs());
        if (!heartbeatPending) SendProbeHeartbeat();
    }
    private async void SendProbeHeartbeat()
    {
        heartbeatPending = true;
        try
        {
            await sdk.TrackEventAsync("unity_probe_heartbeat", new JsonObject { ["probeRunId"] = runId, ["foregroundMs"] = sdk.GetForegroundTimeMs() });
            await sdk.FlushAsync();
        }
        catch (Exception error) { Log("FAIL " + error); }
        finally { heartbeatPending = false; }
    }
    private void Log(string message) { Debug.Log("GP_UNITY_PLAYER " + runId + " " + message); }
    private static void Check(bool condition, string name) { if (!condition) throw new Exception(name + " failed"); }
}
