using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using GamePropel;

internal static class ManagedTests
{
    private static int assertions;
    private static void Check(bool value, string message) { assertions++; if (!value) throw new Exception(message); }
    public static void Main()
    {
        JsonTests.Run();
        var context = new UnityContext();
        SynchronizationContext.SetSynchronizationContext(context);
        var bridge = new BridgeDispatcher();
        var native = new Fake(bridge.Receive);
        bridge.Configure(native);
        var client = new GamePropelClient(bridge);
        var options = new GamePropelOptions {
            GameKey = "ga_live_offline_test", BaseUrl = "https://offline-test.invalid/prefix",
            Device = new JsonObject { ["runtime"] = "override", ["custom"] = "你好" }
        };
        var serialized = options.ToJson();
        Check(serialized["device"].Value<string>("runtime") == "unity", "runtime is owned by the binding");
        Check(options.Device.Value<string>("runtime") == "override", "options are copied");
        Check(serialized["device"].Value<string>("custom") == "你好", "Unicode survives option serialization");
        Throws(() => new GamePropelOptions { GameKey = "ga_admin_not_a_client_key" }.ToJson(), "management keys rejected");
        Throws(() => new GamePropelOptions { GameKey = "ga_live_test", BaseUrl = "https://example.com/?secret=1" }.ToJson(), "query URLs rejected");

        var payload = new JsonObject { ["level_attempt_id"] = "attempt-1", ["name"] = "第一关" };
        var tracking = client.TrackLevelEndAsync(payload);
        payload["name"] = "changed";
        var request = native.Sent.Last();
        Check(request.Value<string>("method") == "levelEnd", "standard event maps to native standard API");
        Check(request["args"]["payload"].Value<string>("name") == "第一关", "payload is captured before returning");
        Task.Run(() => native.Reply(request, JsonValue.From(true))).GetAwaiter().GetResult();
        Check(!tracking.IsCompleted, "native thread cannot complete a Unity callback before pumping");
        context.Drain();
        Check(tracking.GetAwaiter().GetResult(), "native enqueue result is returned");

        var ready = client.WaitForReadyAsync(1000);
        native.Reply(native.Sent.Last(), JsonValue.From(false)); context.Drain();
        Check(!ready.GetAwaiter().GetResult(), "readiness failure is observable");
        var retry = client.WaitForReadyAsync(1000);
        native.Reply(native.Sent.Last(), JsonValue.From(true)); context.Drain();
        Check(retry.GetAwaiter().GetResult(), "readiness timeout is not permanently cached as failure");

        Check(client.GetConfig("difficulty", 2) == 2, "config fallback is read synchronously");
        Check(client.GetForegroundTimeMs() == 1234, "clock delegates to native without a second timer");
        Throws(() => client.RecordBehaviorAsync("strategy", "failure", double.NaN), "invalid behavior amounts rejected");
        Throws(() => client.TrackAdAsync("placement", double.PositiveInfinity), "nonfinite revenue rejected");

        var slow = bridge.Send("flush");
        var slowRequest = native.Sent.Last();
        context.Drain();
        Check(!slow.IsCompleted, "bridge does not invent a timeout for native operations");
        native.Reply(slowRequest, JsonValue.Null); context.Drain();
        Check(slow.IsCompletedSuccessfully, "native completion remains authoritative");

        var refresh = client.RefreshConfigAsync();
        Check(!native.Sent.Last()["args"].Value<bool>("forceRefresh"), "refresh defaults to native cache semantics");
        native.Reply(native.Sent.Last(), JsonValue.Null); context.Drain();
        refresh.GetAwaiter().GetResult();

        var operations = Enumerable.Range(0, 80).Select(_ => bridge.Send("event")).ToArray();
        foreach (var item in native.Sent.TakeLast(80)) native.Reply(item, JsonValue.From(true));
        context.Drain();
        Check(operations.All(t => t.IsCompletedSuccessfully), "native replies use the Unity synchronization context");
        var burst = Enumerable.Range(0, 300).Select(_ => bridge.Send("event")).ToArray();
        foreach (var item in native.Sent.TakeLast(300)) native.Reply(item, JsonValue.From(true));
        while (burst.Any(t => !t.IsCompleted)) context.Drain();
        Check(burst.All(t => t.IsCompletedSuccessfully), "bridge does not add an event quota before the native SDK");
        Exception threadError = null;
        Task.Run(() => { try { client.GetForegroundTimeMs(); } catch (Exception error) { threadError = error; } }).GetAwaiter().GetResult();
        Check(threadError is InvalidOperationException, "Unity API calls reject background-thread access");

#if UNITY_EDITOR
        try { NativeTransport.Create(bridge.Receive); throw new Exception("Editor must not report fake readiness"); }
        catch (PlatformNotSupportedException) { assertions++; }
#endif
        Console.WriteLine("Managed bridge checks passed: " + assertions);
    }
    private static void Throws(Action action, string message)
    {
        try { action(); } catch (ArgumentException) { assertions++; return; }
        throw new Exception(message);
    }
    private sealed class UnityContext : SynchronizationContext
    {
        private readonly ConcurrentQueue<Action> callbacks = new ConcurrentQueue<Action>();
        public override void Post(SendOrPostCallback callback, object state) { callbacks.Enqueue(() => callback(state)); }
        internal void Drain() { while (callbacks.TryDequeue(out var callback)) callback(); }
    }
    private sealed class Fake : INativeTransport
    {
        private readonly Action<string> receive;
        public readonly List<JsonObject> Sent = new List<JsonObject>();
        internal Fake(Action<string> receive) { this.receive = receive; }
        public string Initialize(string options) => "{\"ok\":true,\"result\":null}";
        public string Read(string request)
        {
            var input = JsonObject.Parse(request);
            return new JsonObject { ["ok"] = true, ["result"] = input["args"]?["fallback"] ?? JsonValue.Null }.ToString();
        }
        public void Send(string request) { Sent.Add(JsonObject.Parse(request)); }
        public long GetForegroundTimeMs() => 1234;
        internal void Reply(JsonObject request, JsonValue result) => receive(new JsonObject { ["id"] = request["id"], ["ok"] = true, ["result"] = result }.ToString());
    }
}
