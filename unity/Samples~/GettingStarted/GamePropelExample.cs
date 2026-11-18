using System;
using GamePropel;
using UnityEngine;

public sealed class GamePropelExample : MonoBehaviour
{
    [Tooltip("Client ga_live_* key. Never put a management key here.")]
    public string GameKey;
    private GamePropel.GamePropelClient sdk;
    private string status = "Starting";

    private async void Start()
    {
        try
        {
            sdk = GamePropel.GamePropelSDK.IsInitialized ? GamePropel.GamePropelSDK.Client : GamePropel.GamePropelSDK.Initialize(new GamePropel.GamePropelOptions {
                GameKey = GameKey, IsDebug = true
            });
            // Awaiting this task yields to Unity; it never blocks rendering.
            var ready = await sdk.WaitForReadyAsync();
            status = ready ? "Native SDK ready" : "Using local defaults; retry readiness later";
        }
        catch (Exception error) { status = error.Message; Debug.LogException(error); }
    }

    private void OnGUI()
    {
        GUILayout.Label(status);
        if (sdk == null) return;
        GUILayout.Label("Foreground: " + sdk.GetForegroundTimeMs() + " ms");
        GUILayout.Label("Difficulty: " + sdk.GetConfig("difficulty", 1));
        if (GUILayout.Button("Report level start/end")) ReportLevel();
    }

    private async void ReportLevel()
    {
        try
        {
            var attempt = Guid.NewGuid().ToString();
            var payload = new JsonObject { ["level_id"] = "demo-1", ["level_attempt_id"] = attempt };
            await sdk.TrackLevelStartAsync(payload);
            var end = (JsonObject)payload.DeepClone(); end["result"] = "win";
            var queued = await sdk.TrackLevelEndAsync(end);
            await sdk.FlushAsync();
            status = queued ? "Native enqueue succeeded; verify real receipt on the server" : "Event was not enqueued";
        }
        catch (Exception error) { status = error.Message; Debug.LogException(error); }
    }
    // Lifecycle is handled by the native SDK. No duplicate OnApplicationPause
    // or OnApplicationQuit reporting is installed by this component.
}
