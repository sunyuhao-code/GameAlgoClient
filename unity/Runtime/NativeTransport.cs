using System;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.Scripting;

namespace GamePropel
{
    internal interface INativeTransport
    {
        string Initialize(string options);
        string Read(string request);
        void Send(string request);
        long GetForegroundTimeMs();
    }

    internal static class NativeTransport
    {
        internal static INativeTransport Create(Action<string> receive)
        {
#if UNITY_EDITOR
            throw new PlatformNotSupportedException("GamePropel uses the native Android/iOS SDKs. Run a mobile player to initialize and send events.");
#elif UNITY_ANDROID
            return new AndroidTransport(receive);
#elif UNITY_IOS
            return new IosTransport(receive);
#else
            throw new PlatformNotSupportedException("GamePropel Unity supports Android/iOS players.");
#endif
        }
    }

#if UNITY_ANDROID && !UNITY_EDITOR
    internal sealed class AndroidTransport : INativeTransport
    {
        private readonly AndroidJavaClass bridge = new AndroidJavaClass("com.gamepropel.unity.GamePropelUnityBridge");
        private readonly Callback callback;
        internal AndroidTransport(Action<string> receive) { callback = new Callback(receive); }
        public string Initialize(string options)
        {
            using (var player = new AndroidJavaClass("com.unity3d.player.UnityPlayer"))
            using (var activity = player.GetStatic<AndroidJavaObject>("currentActivity"))
                return bridge.CallStatic<string>("initialize", options, activity);
        }
        public string Read(string request) => bridge.CallStatic<string>("read", request);
        public void Send(string request) => bridge.CallStatic("send", request, callback);
        public long GetForegroundTimeMs() => bridge.CallStatic<long>("getForegroundTimeMs");
        [Preserve]
        private sealed class Callback : AndroidJavaProxy
        {
            private readonly Action<string> receive;
            internal Callback(Action<string> receive) : base("com.gamepropel.unity.GamePropelCallback") { this.receive = receive; }
            [Preserve] public void onResult(string json) { receive(json); }
        }
    }
#endif

#if UNITY_IOS && !UNITY_EDITOR
    [Preserve]
    internal sealed class IosTransport : INativeTransport
    {
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Reply(IntPtr json);
        private static readonly Reply NativeReply = OnReply;
        private static Action<string> receiver;
        internal IosTransport(Action<string> receive) { receiver = receive; }
        [DllImport("__Internal", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr GPUnity_Initialize([MarshalAs(UnmanagedType.LPUTF8Str)] string options);
        [DllImport("__Internal", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr GPUnity_Read([MarshalAs(UnmanagedType.LPUTF8Str)] string request);
        [DllImport("__Internal", CallingConvention = CallingConvention.Cdecl)] private static extern void GPUnity_Send([MarshalAs(UnmanagedType.LPUTF8Str)] string request, Reply reply);
        [DllImport("__Internal", CallingConvention = CallingConvention.Cdecl)] private static extern void GPUnity_Free(IntPtr text);
        [DllImport("__Internal", CallingConvention = CallingConvention.Cdecl)] private static extern long GPUnity_GetForegroundTimeMs();
        public string Initialize(string options) => Take(GPUnity_Initialize(options));
        public string Read(string request) => Take(GPUnity_Read(request));
        public void Send(string request) => GPUnity_Send(request, NativeReply);
        public long GetForegroundTimeMs() => GPUnity_GetForegroundTimeMs();
        private static string Take(IntPtr value)
        {
            try { return Utf8(value); } finally { if (value != IntPtr.Zero) GPUnity_Free(value); }
        }
        private static string Utf8(IntPtr value)
        {
            if (value == IntPtr.Zero) throw new InvalidOperationException("Native bridge returned a null response.");
            var length = 0;
            while (Marshal.ReadByte(value, length) != 0) length++;
            var bytes = new byte[length];
            Marshal.Copy(value, bytes, 0, length);
            return System.Text.Encoding.UTF8.GetString(bytes);
        }
        [AOT.MonoPInvokeCallback(typeof(Reply))]
        [Preserve]
        private static void OnReply(IntPtr json)
        {
            // Never unwind a managed exception through a native callback.
            if (json == IntPtr.Zero) return;
            try { receiver?.Invoke(Utf8(json)); } catch { /* Never unwind through the C ABI. */ }
        }
    }
#endif
}
