using System.Threading.Tasks;
using UnityEngine;

// Same small Unity host/UI as the SDK probe, without any GamePropel dependency.
public sealed class GamePropelUnityBaseline : MonoBehaviour
{
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void Boot()
    {
        var host = new GameObject("Baseline");
        DontDestroyOnLoad(host); host.AddComponent<GamePropelUnityBaseline>();
    }
    private async void Start()
    {
        Application.targetFrameRate = 30;
        await Task.Delay(1500);
        Debug.Log("GP_UNITY_BASELINE_PASS");
    }
    private void OnGUI() { GUILayout.Label("GamePropel Unity baseline"); }
}
