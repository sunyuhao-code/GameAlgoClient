using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using UnityEngine;
using UnityEngine.Scripting;

namespace GamePropel
{
    [Preserve]
    internal sealed class BridgeDispatcher : MonoBehaviour
    {
        private readonly Dictionary<string, TaskCompletionSource<JsonValue>> pending = new Dictionary<string, TaskCompletionSource<JsonValue>>();
        private INativeTransport transport;
        private SynchronizationContext unityContext;
        private SendOrPostCallback completeOnMain;
        private int ownerThread;
        private long sequence;
        private volatile bool stopped;

        internal void Configure(INativeTransport value)
        {
            ownerThread = Thread.CurrentThread.ManagedThreadId;
            unityContext = SynchronizationContext.Current
                ?? throw new InvalidOperationException("Initialize GamePropel from the Unity main thread.");
            completeOnMain = Complete;
            transport = value;
        }
        internal void Receive(string reply)
        {
            if (!stopped) unityContext.Post(completeOnMain, reply);
        }
        internal void RequireOwner()
        {
            if (stopped) throw new ObjectDisposedException("GamePropel dispatcher");
            if (Thread.CurrentThread.ManagedThreadId != ownerThread)
                throw new InvalidOperationException("Call the Unity API on the Unity main thread. Native callbacks are marshalled back automatically.");
        }
        internal JsonValue Initialize(JsonObject options)
        {
            RequireOwner();
            return Result(transport.Initialize(options.ToString()));
        }
        internal JsonValue Read(string method, JsonObject args = null)
        {
            RequireOwner();
            return Result(transport.Read(Request(method, args).ToString()));
        }
        internal long GetForegroundTimeMs() { RequireOwner(); return transport.GetForegroundTimeMs(); }
        internal Task<JsonValue> Send(string method, JsonObject args = null)
        {
            RequireOwner();
            var request = Request(method, args);
            var id = (++sequence).ToString(System.Globalization.CultureInfo.InvariantCulture);
            request["id"] = id;
            var completion = new TaskCompletionSource<JsonValue>(TaskCreationOptions.RunContinuationsAsynchronously);
            pending.Add(id, completion);
            try { transport.Send(request.ToString()); }
            catch (Exception error) { pending.Remove(id); completion.TrySetException(error); }
            return completion.Task;
        }
        private static JsonObject Request(string method, JsonObject args) => new JsonObject {
            ["method"] = method, ["args"] = args ?? new JsonObject()
        };
        internal static JsonValue Result(string json)
        {
            var response = JsonObject.Parse(json);
            if (response.Value<bool?>("ok") != true)
                throw new InvalidOperationException(response.Value<string>("error") ?? "Native bridge failed.");
            return response["result"] ?? JsonValue.Null;
        }
        private void Complete(object message)
        {
            if (stopped) return;
            RequireOwner();
            try
            {
                var response = JsonObject.Parse((string)message);
                var id = response.Value<string>("id");
                if (id == null || !pending.TryGetValue(id, out var completion)) return;
                pending.Remove(id);
                if (response.Value<bool?>("ok") == true)
                    completion.TrySetResult(response["result"] ?? JsonValue.Null);
                else completion.TrySetException(new InvalidOperationException(response.Value<string>("error") ?? "Native bridge failed."));
            }
            catch (FormatException error) { Debug.LogException(error); }
        }
        private void OnDestroy()
        {
            stopped = true;
            foreach (var operation in pending.Values)
                operation.TrySetException(new ObjectDisposedException("GamePropel dispatcher"));
            pending.Clear();
        }
    }
}
