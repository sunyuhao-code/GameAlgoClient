// Compiler/test harness only. These classes are not shipped or used in Unity.
using System;
namespace UnityEngine
{
    public class Object { public static void DontDestroyOnLoad(Object value) {} public static void Destroy(Object value) {} }
    public class MonoBehaviour : Object {}
    public class GameObject : Object
    {
        public GameObject(string name) {}
        public T AddComponent<T>() where T : new() => new T();
    }
    public static class Application { public static string unityVersion = "test-editor"; public static string version = "test-app"; }
    public static class Time { public static double realtimeSinceStartupAsDouble; }
    public static class Debug { public static void Log(object value) {} public static void LogException(Exception value) {} }
    public enum RuntimeInitializeLoadType { SubsystemRegistration }
    public class RuntimeInitializeOnLoadMethodAttribute : Attribute { public RuntimeInitializeOnLoadMethodAttribute(RuntimeInitializeLoadType type) {} }
    public class AndroidJavaObject : IDisposable { public void Dispose() {} }
    public class AndroidJavaClass : AndroidJavaObject
    {
        public AndroidJavaClass(string name) {}
        public T GetStatic<T>(string name) => default;
        public T CallStatic<T>(string name, params object[] args) => default;
        public void CallStatic(string name, params object[] args) {}
    }
    public class AndroidJavaProxy { public AndroidJavaProxy(string name) {} }
}
namespace UnityEngine.Scripting { public class PreserveAttribute : Attribute {} }
namespace AOT { public class MonoPInvokeCallbackAttribute : Attribute { public MonoPInvokeCallbackAttribute(Type type) {} } }
