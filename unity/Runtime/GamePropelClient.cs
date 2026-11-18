using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using UnityEngine;

namespace GamePropel
{
    public static class GamePropelSDK
    {
        public static GamePropelClient Client { get; private set; }
        public static bool IsInitialized => Client != null;
        public static GamePropelClient Initialize(GamePropelOptions options)
        {
            if (Client != null) throw new InvalidOperationException("GamePropel is already initialized. Use the existing client across scenes.");
            if (options == null) throw new ArgumentNullException(nameof(options));
            var host = new GameObject("GamePropel");
            UnityEngine.Object.DontDestroyOnLoad(host);
            var dispatcher = host.AddComponent<BridgeDispatcher>();
            try
            {
                dispatcher.Configure(NativeTransport.Create(dispatcher.Receive));
                dispatcher.Initialize(options.ToJson());
                Client = new GamePropelClient(dispatcher);
                return Client;
            }
            catch { UnityEngine.Object.Destroy(host); throw; }
        }
    }

    public sealed class GamePropelClient
    {
        public const string Version = "1.0.0";
        private readonly BridgeDispatcher bridge;
        internal GamePropelClient(BridgeDispatcher bridge) { this.bridge = bridge; }
        public JsonObject Identity => (JsonObject)bridge.Read("identity");
        public long GetForegroundTimeMs() => bridge.GetForegroundTimeMs();
        public async Task<bool> WaitForReadyAsync(int timeoutMs = 5000)
        {
            if (timeoutMs < 0) throw new ArgumentOutOfRangeException(nameof(timeoutMs));
            return (await bridge.Send("ready", new JsonObject { ["timeoutMs"] = timeoutMs })).Value<bool>();
        }
        /// <summary>Reads the current local snapshot; never requests the network.</summary>
        public T GetConfig<T>(string path, T fallback, string fileName = null) => ReadValue<T>("config", new JsonObject {
            ["path"] = path ?? "", ["fallback"] = Token(fallback), ["fileName"] = fileName
        });
        public T GetStrategyConfig<T>(string strategy, string path, T fallback) => ReadValue<T>("strategyConfig", new JsonObject {
            ["strategy"] = Required(strategy, nameof(strategy)), ["path"] = path ?? "", ["fallback"] = Token(fallback)
        });
        /// <summary>Assignment metadata for diagnostics; gameplay uses configuration or script results.</summary>
        public JsonObject GetAssignment(string strategy) => bridge.Read("assignment", new JsonObject { ["strategy"] = Required(strategy, nameof(strategy)) }) as JsonObject;
        private T ReadValue<T>(string method, JsonObject args)
        {
            var result = bridge.Read(method, args);
            return result.Type == JsonType.Null ? default : result.Value<T>();
        }
        public Task RefreshConfigAsync(bool forceRefresh = false) => bridge.Send("refresh", new JsonObject { ["forceRefresh"] = forceRefresh });
        public Task NewSessionAsync(string sessionId = null) => bridge.Send("newSession", new JsonObject { ["sessionId"] = sessionId });
        /// <summary>Completes a native flush attempt; verify server receipt separately.</summary>
        public Task FlushAsync() => bridge.Send("flush");
        public Task<bool> TrackEventAsync(string name, JsonObject payload = null) => Track("event", new JsonObject { ["name"] = Required(name, nameof(name)), ["payload"] = Payload(payload) });
        public Task<bool> TrackLevelStartAsync(JsonObject payload = null) => Track("levelStart", new JsonObject { ["payload"] = Payload(payload) });
        public Task<bool> TrackLevelEndAsync(JsonObject payload = null) => Track("levelEnd", new JsonObject { ["payload"] = Payload(payload) });
        public Task<bool> TrackSessionEndAsync(JsonObject payload = null) => Track("sessionEnd", new JsonObject { ["payload"] = Payload(payload) });
        public Task<bool> TrackMilestoneAsync(string type, string point, JsonObject payload = null) => Track("milestone", new JsonObject {
            ["type"] = Required(type, nameof(type)), ["point"] = Required(point, nameof(point)), ["payload"] = Payload(payload)
        });
        public Task<bool> TrackAdAsync(string adPlacementId, double revenue, string network = null, JsonObject payload = null)
        {
            if (double.IsNaN(revenue) || double.IsInfinity(revenue)) throw new ArgumentOutOfRangeException(nameof(revenue));
            return Track("ad", new JsonObject { ["adPlacementId"] = Required(adPlacementId, nameof(adPlacementId)), ["revenue"] = revenue,
                ["network"] = network, ["payload"] = Payload(payload) });
        }
        public Task<bool> TrackPurchaseAsync(string productId, double revenue, string currency, JsonObject payload = null)
        {
            if (double.IsNaN(revenue) || double.IsInfinity(revenue)) throw new ArgumentOutOfRangeException(nameof(revenue));
            return Track("purchase", new JsonObject { ["productId"] = Required(productId, nameof(productId)), ["revenue"] = revenue,
                ["currency"] = Required(currency, nameof(currency)), ["payload"] = Payload(payload) });
        }
        private async Task<bool> Track(string method, JsonObject args) => (await bridge.Send(method, args)).Value<bool>();
        public Task<JsonValue> SetAttributionAsync(string provider, JsonObject attribution) => bridge.Send("attribution", new JsonObject {
            ["provider"] = Required(provider, nameof(provider)), ["attribution"] = Payload(attribution)
        });
        public async Task ConfigureAdjustCallbackParamsAsync(Action<string, string> setter)
        {
            if (setter == null) throw new ArgumentNullException(nameof(setter));
            var parameters = (JsonObject)await bridge.Send("adjustParams");
            foreach (var parameter in parameters) setter(parameter.Key, parameter.Value.Value<string>());
        }
        public Task<JsonValue> SetIdentifierAsync(AdvertisingIdentifier type, string value, string observedAt = null) => bridge.Send("identifier", new JsonObject {
            ["type"] = type.ToString(), ["value"] = Required(value, nameof(value)), ["observedAt"] = observedAt
        });
        /// <summary>Supplies externally obtained CAID/version pairs; the native SDK serializes them.</summary>
        public Task<JsonValue> SetCaidAsync(IEnumerable<CaidValue> values, string observedAt = null)
        {
            if (values == null) throw new ArgumentNullException(nameof(values));
            var array = new JsonArray();
            foreach (var value in values)
            {
                if (value == null) throw new ArgumentException("CAID entries cannot be null.");
                array.Add(new JsonObject { ["caid"] = value.Caid, ["version"] = value.Version });
            }
            return bridge.Send("caid", new JsonObject { ["values"] = array, ["observedAt"] = observedAt });
        }
        public Task<JsonValue> ExecuteAsync(string strategy, JsonValue state) => bridge.Send("execute", new JsonObject {
            ["strategy"] = Required(strategy, nameof(strategy)), ["state"] = Token(state)
        });
        public Task RecordBehaviorAsync(string strategy, string behavior, double amount = 1)
        {
            if (amount <= 0 || double.IsNaN(amount) || double.IsInfinity(amount)) throw new ArgumentOutOfRangeException(nameof(amount));
            return bridge.Send("ddaRecord", new JsonObject {
                ["strategy"] = Required(strategy, nameof(strategy)), ["behavior"] = Required(behavior, nameof(behavior)), ["amount"] = amount
            });
        }
        public Task CompleteStepAsync(string strategy, string stepId = null) => bridge.Send("ddaComplete", new JsonObject {
            ["strategy"] = Required(strategy, nameof(strategy)), ["stepId"] = stepId
        });
        public Task ResetDdaAsync(string strategy, string scope = "all") => bridge.Send("ddaReset", new JsonObject {
            ["strategy"] = Required(strategy, nameof(strategy)), ["scope"] = scope
        });
        public Task<JsonValue> DecideAsync(string strategy, JsonValue context = null) => bridge.Send("ddaDecide", new JsonObject {
            ["strategy"] = Required(strategy, nameof(strategy)), ["context"] = Token(context)
        });
        private static JsonValue Token(object value) => value == null ? JsonValue.Null : value is JsonValue token ? token.DeepClone() : JsonValue.From(value);
        private static JsonObject Payload(JsonObject value) => value == null ? new JsonObject() : (JsonObject)value.DeepClone();
        private static string Required(string value, string name) => !string.IsNullOrWhiteSpace(value) ? value : throw new ArgumentException("A non-empty value is required.", name);
    }
}
