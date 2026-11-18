package com.gamepropel.makerprobe;

import android.app.Activity;
import android.content.Intent;
import android.content.Context;
import android.content.BroadcastReceiver;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Iterator;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;
import party.iroiro.luajava.Lua;
import party.iroiro.luajava.JFunction;
import party.iroiro.luajava.lua54.Lua54;

/** Native Lua/HTTP/File test host, deliberately NOT a TapTap/Maker runtime. */
public final class ProbeActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService network = Executors.newFixedThreadPool(4);
    private final ArrayDeque<Runnable> deferred = new ArrayDeque<>();
    private Lua lua;
    private TextView status;
    private boolean paused = true;
    private String variant;
    private String caseId;
    private BroadcastReceiver commands;

    private final Runnable frame = new Runnable() {
        @Override public void run() {
            if (lua == null || paused) return;
            invoke("ProbeFrame", 0.016);
            main.postDelayed(this, 16);
        }
    };

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        variant = getIntent().getStringExtra("variant");
        if (variant == null) variant = "fixed";
        caseId = getIntent().getStringExtra("case");
        if (caseId == null || !caseId.matches("[a-zA-Z0-9_-]+")) caseId = "manual";
        status = new TextView(this);
        status.setPadding(24, 40, 24, 24);
        status.setText("Android Lua SDK delivery probe\nNative Lua 5.4 / HTTP / private files\n"
            + "This is a test container, not the TapTap host.\n\n" + variant + " / " + caseId);
        setContentView(status);
        try {
            lua = new Lua54();
            lua.openLibraries();
            bind("HostReadAsset", l -> { l.push(readAsset(l.toString(1))); return 1; });
            bind("HostNowMs", l -> { l.push(SystemClock.elapsedRealtime()); return 1; });
            bind("HostLog", l -> { log(l.toString(1)); return 0; });
            bind("HostJsonEncode", l -> {
                Object value = toJson(l, 1, 0);
                l.push(value instanceof String ? JSONObject.quote((String) value) : value.toString());
                return 1;
            });
            bind("HostJsonDecode", l -> {
                pushJson(l, new JSONTokener(l.toString(1)).nextValue()); return 1;
            });
            bind("HostSend", l -> {
                send(l.toInteger(1), l.toString(2), l.toString(3), l.toString(4), l.toString(5));
                return 0;
            });
            lua.pushJavaObject(JSONObject.NULL); lua.setGlobal("HOST_JSON_NULL");
            lua.push(getFilesDir().getAbsolutePath()); lua.setGlobal("PROBE_FILES");
            lua.push(variant); lua.setGlobal("PROBE_VARIANT");
            lua.push(caseId); lua.setGlobal("PROBE_CASE");
            lua.push(getIntent().getStringExtra("baseUrl") == null ? "http://10.0.2.2:18765"
                : getIntent().getStringExtra("baseUrl")); lua.setGlobal("PROBE_URL");
            lua.run(readAsset("probe.lua"));
            commands = new BroadcastReceiver() {
                @Override public void onReceive(Context context, Intent intent) {
                    String command = intent.getStringExtra("command");
                    if (command != null) invoke("ProbeCommand", command, intent.getIntExtra("holdMs", 6000));
                }
            };
            IntentFilter filter = new IntentFilter("com.gamepropel.makerprobe.COMMAND");
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(commands, filter, Context.RECEIVER_EXPORTED);
            else registerReceiver(commands, filter);
            log("READY variant=" + variant + " case=" + caseId);
        } catch (Throwable error) {
            log("PROBE_ERROR " + error);
        }
    }

    private interface HostFunction { int call(Lua l) throws Exception; }
    private void bind(String name, HostFunction fn) {
        lua.push((JFunction) l -> {
            try { return fn.call(l); }
            catch (Throwable error) { l.error(error.toString()); return 0; }
        });
        lua.setGlobal(name);
    }

    private void invoke(String name, Object... args) {
        if (lua == null) return;
        try {
            lua.getGlobal(name);
            for (Object arg : args) {
                if (arg instanceof Number) lua.push((Number) arg);
                else if (arg instanceof Boolean) lua.push((Boolean) arg);
                else lua.push(String.valueOf(arg));
            }
            lua.pCall(args.length, 0);
        } catch (Throwable error) { log("PROBE_ERROR " + name + " " + error); }
    }

    @Override protected void onResume() {
        super.onResume(); paused = false;
        while (!deferred.isEmpty()) deferred.removeFirst().run();
        invoke("ProbeLifecycle", "AppWillEnterForeground");
        invoke("ProbeLifecycle", "AppDidEnterForebackground");
        main.post(frame);
    }

    @Override protected void onPause() {
        // Match an engine whose Update and Lua HTTP callbacks stop in background.
        // Native HTTP may still reach the server while Lua acknowledgements wait.
        paused = true;
        if ("did_only".equals(getIntent().getStringExtra("background"))) {
            invoke("ProbeLifecycle", "AppDidEnterBackground");
        } else {
            invoke("ProbeLifecycle", "AppWillEnterBackground");
            invoke("ProbeLifecycle", "AppDidEnterBackground");
        }
        main.removeCallbacks(frame);
        super.onPause();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String command = intent.getStringExtra("command");
        if (command != null) invoke("ProbeCommand", command,
            intent.getIntExtra("holdMs", 6000));
    }

    @Override protected void onDestroy() {
        main.removeCallbacks(frame);
        if (commands != null) unregisterReceiver(commands);
        network.shutdownNow();
        if (lua != null) { lua.close(); lua = null; }
        super.onDestroy();
    }

    private void log(String text) {
        Log.i("MakerLuaProbe", text);
        if (status != null) status.append("\n" + text);
    }

    private String readAsset(String name) throws Exception {
        try (InputStream in = getAssets().open(name)) { return read(in); }
    }

    private static String read(InputStream in) throws Exception {
        if (in == null) return "";
        try (InputStream src = in; ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int n;
            while ((n = src.read(buffer)) != -1) bytes.write(buffer, 0, n);
            return bytes.toString("UTF-8");
        }
    }

    private void send(long id, String url, String method, String body, String headers) {
        network.execute(() -> {
            int status = 0; String response = ""; String error = "";
            HttpURLConnection connection = null;
            try {
                connection = (HttpURLConnection) new URL(url).openConnection();
                connection.setConnectTimeout(10000); connection.setReadTimeout(10000);
                connection.setRequestMethod(method);
                JSONObject h = new JSONObject(headers);
                for (Iterator<String> keys = h.keys(); keys.hasNext();) {
                    String key = keys.next(); connection.setRequestProperty(key, h.getString(key));
                }
                connection.setRequestProperty("X-Probe-Variant", variant);
                connection.setRequestProperty("X-Probe-Case", caseId);
                if (!body.isEmpty()) {
                    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
                    connection.setDoOutput(true); connection.setFixedLengthStreamingMode(bytes.length);
                    try (java.io.OutputStream out = connection.getOutputStream()) { out.write(bytes); }
                }
                status = connection.getResponseCode();
                response = read(status >= 400 ? connection.getErrorStream() : connection.getInputStream());
            } catch (Throwable failure) { error = failure.toString(); }
            finally { if (connection != null) connection.disconnect(); }
            final int code = status; final String data = response; final String failure = error;
            main.post(() -> {
                Runnable callback = () -> invoke("ProbeHttpComplete", id, code, data, failure);
                if (paused) deferred.add(callback); else callback.run();
            });
        });
    }

    private static Object toJson(Lua l, int index, int depth) throws Exception {
        if (depth > 32) throw new IllegalArgumentException("JSON depth exceeded");
        if (index < 0) index += l.getTop() + 1;
        if (l.isNil(index)) return JSONObject.NULL;
        if (l.isBoolean(index)) return l.toBoolean(index);
        if (l.isNumber(index)) return l.isInteger(index) ? (Object) l.toInteger(index) : l.toNumber(index);
        if (l.isString(index)) return l.toString(index);
        if (l.isJavaObject(index) && l.toJavaObject(index) == JSONObject.NULL) return JSONObject.NULL;
        if (!l.isTable(index)) throw new IllegalArgumentException("Unsupported JSON value");
        int n = l.rawLength(index), count = 0; boolean array = n > 0;
        l.pushNil();
        while (l.next(index) != 0) {
            count++;
            if (!l.isInteger(-2) || l.toInteger(-2) < 1 || l.toInteger(-2) > n) array = false;
            l.pop(1);
        }
        if (array && count == n) {
            JSONArray result = new JSONArray();
            for (int i = 1; i <= n; i++) {
                l.rawGetI(index, i); result.put(toJson(l, -1, depth + 1)); l.pop(1);
            }
            return result;
        }
        JSONObject result = new JSONObject();
        l.pushNil();
        while (l.next(index) != 0) {
            result.put(l.toString(-2), toJson(l, -1, depth + 1)); l.pop(1);
        }
        return result;
    }

    private static void pushJson(Lua l, Object value) throws Exception {
        if (value == JSONObject.NULL) l.pushJavaObject(JSONObject.NULL);
        else if (value instanceof JSONObject) {
            JSONObject obj = (JSONObject) value; l.newTable();
            for (Iterator<String> keys = obj.keys(); keys.hasNext();) {
                String key = keys.next(); pushJson(l, obj.get(key)); l.setField(-2, key);
            }
        } else if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value; l.newTable();
            for (int i = 0; i < array.length(); i++) { pushJson(l, array.get(i)); l.rawSetI(-2, i + 1); }
        } else if (value instanceof Boolean) l.push((Boolean) value);
        else if (value instanceof Number) l.push((Number) value);
        else l.push(String.valueOf(value));
    }
}
