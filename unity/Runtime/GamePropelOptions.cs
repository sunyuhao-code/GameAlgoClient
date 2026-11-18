using System;
using UnityEngine;

namespace GamePropel
{
    public sealed class GamePropelOptions
    {
        public string GameKey { get; set; }
        public string BaseUrl { get; set; } = "https://game-algo-sdk.dictapis.cn";
        public string AppVersion { get; set; }
        public string AccountUserId { get; set; }
        public string AccountUserCreatedAt { get; set; }
        public int ExperimentIntegrationVersion { get; set; }
        public bool IsDebug { get; set; }
        public bool EnableLogging { get; set; }
        public JsonObject Device { get; set; } = new JsonObject();
        internal JsonObject ToJson()
        {
            if (string.IsNullOrWhiteSpace(GameKey) || !GameKey.StartsWith("ga_live_", StringComparison.Ordinal))
                throw new ArgumentException("A client ga_live_* key is required. Management keys must not be embedded in a player.");
            if (!Uri.TryCreate(BaseUrl, UriKind.Absolute, out var url) ||
                (url.Scheme != "https" && url.Scheme != "http") ||
                !string.IsNullOrEmpty(url.UserInfo) || !string.IsNullOrEmpty(url.Query) || !string.IsNullOrEmpty(url.Fragment))
                throw new ArgumentException("BaseUrl must be an absolute HTTP(S) URL without credentials, query or fragment.");
            if (ExperimentIntegrationVersion < 0) throw new ArgumentOutOfRangeException(nameof(ExperimentIntegrationVersion));
            var device = Device == null ? new JsonObject() : (JsonObject)Device.DeepClone();
            device["runtime"] = "unity";
            device["unityVersion"] = Application.unityVersion;
            device["unitySdkVersion"] = GamePropelClient.Version;
            return new JsonObject {
                ["gameKey"] = GameKey, ["baseUrl"] = BaseUrl,
                ["appVersion"] = AppVersion ?? Application.version,
                ["accountUserId"] = AccountUserId, ["accountUserCreatedAt"] = AccountUserCreatedAt,
                ["experimentIntegrationVersion"] = ExperimentIntegrationVersion,
                ["isDebug"] = IsDebug, ["enableLogging"] = EnableLogging,
                ["device"] = device
            };
        }
    }

    public enum AdvertisingIdentifier { AdjustAdid, FirebaseAppInstanceId, GoogleAdvertisingId, Oaid, Idfa, Idfv }

    public sealed class CaidValue
    {
        public string Caid { get; }
        public string Version { get; }
        public CaidValue(string caid, string version)
        {
            if (string.IsNullOrWhiteSpace(caid) || string.IsNullOrWhiteSpace(version))
                throw new ArgumentException("CAID and version are required.");
            Caid = caid;
            Version = version;
        }
    }
}
