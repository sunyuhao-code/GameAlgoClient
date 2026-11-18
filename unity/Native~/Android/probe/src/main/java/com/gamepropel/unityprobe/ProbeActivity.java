package com.gamepropel.unityprobe;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;
import com.gamepropel.unity.GamePropelUnityBridge;
import org.json.JSONObject;

/** Local-emulator native API test, not a Unity player or production game. */
public final class ProbeActivity extends Activity {
    private final String[] methods = {"ready", "levelStart", "levelEnd", "milestone", "event", "sessionEnd", "flush", "identifier", "execute", "newSession", "newSession", "refresh", "refresh", "levelStart", "flush"};
    private int index;
    private int refreshAttempt;
    private String runId;
    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        runId = getIntent().getStringExtra("run_id");
        TextView view = new TextView(this); view.setText("GamePropel native bridge probe"); setContentView(view);
        String base = getIntent().getStringExtra("base_url");
        if (base == null || !base.matches("http://10\\.0\\.2\\.2:[0-9]+")) { fail("A local emulator HTTP endpoint is required"); return; }
        try {
            JSONObject options = new JSONObject().put("gameKey", "ga_live_unity_offline_probe").put("baseUrl", base)
                    .put("appVersion", "native-probe").put("isDebug", true).put("enableLogging", true)
                    .put("device", new JSONObject().put("runtime", "unity").put("unityVersion", "native-probe"));
            JSONObject result = new JSONObject(GamePropelUnityBridge.initialize(options.toString(), this));
            if (!result.optBoolean("ok")) { fail(result.toString()); return; }
            next();
        } catch (Exception error) { fail(error.toString()); }
    }
    private void next() {
        if (index == methods.length) {
            Log.i("GamePropelUnityProbe", runId + " PASS " + GamePropelUnityBridge.read("{\"method\":\"identity\",\"args\":{}}")); return;
        }
        try {
            String method = methods[index++];
            JSONObject args = new JSONObject().put("timeoutMs", 5000).put("payload", new JSONObject().put("level_id", "第一关").put("level_attempt_id", "attempt-1"))
                    .put("type", "new_user").put("point", "probe_start").put("name", "probe_custom")
                    .put("type", method.equals("identifier") ? "Oaid" : "new_user").put("value", "offline-oaid")
                    .put("strategy", "probe").put("state", new JSONObject().put("value", 7)).put("sessionId", "probe-new-session");
            if (method.equals("refresh")) args.put("forceRefresh", ++refreshAttempt == 2);
            JSONObject request = new JSONObject().put("id", Integer.toString(index)).put("method", method).put("args", args);
            GamePropelUnityBridge.send(request.toString(), reply -> runOnUiThread(() -> {
                try {
                    JSONObject response = new JSONObject(reply);
                    if (!response.optBoolean("ok")) { fail(reply); return; }
                    if (method.equals("ready") && !response.getBoolean("result")) { fail("Native readiness failed"); return; }
                    if (method.equals("execute")) {
                        JSONObject payload = response.getJSONObject("result").getJSONObject("payload");
                        if (payload.getInt("value") != 7) { fail("Native Rust strategy result mismatch"); return; }
                    }
                    next();
                } catch (Exception error) { fail(error.toString()); }
            }));
        } catch (Exception error) { fail(error.toString()); }
    }
    @Override public void onResume() {
        super.onResume();
        Log.i("GamePropelUnityProbe", runId + " RESUME " + GamePropelUnityBridge.read("{\"method\":\"identity\",\"args\":{}}"));
    }
    private void fail(String message) { Log.e("GamePropelUnityProbe", runId + " FAIL " + message); }
}
