package com.gamepropel.unity;

import android.app.Activity;
import com.gamealgo.sdk.*;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Thin adapter: native SDK owns identity, durable events and application lifecycle. */
public final class GamePropelUnityBridge {
    private static final ExecutorService network = Executors.newFixedThreadPool(2, r -> {
        Thread thread = new Thread(r, "GamePropel-Unity"); thread.setDaemon(true); return thread;
    });
    private static volatile GameAlgoClient sdk;
    private static volatile String userId = "";
    private static Map<String, Object> device;
    private static boolean debug;
    private static int integrationVersion;
    private static String accountUserId, accountUserCreatedAt;
    private GamePropelUnityBridge() {}

    public static synchronized String initialize(String input, Activity activity) {
        try {
            if (sdk != null) throw new IllegalStateException("GamePropel is already initialized");
            if (activity == null) throw new IllegalArgumentException("Unity Activity is unavailable");
            JSONObject options = new JSONObject(input);
            String key = required(options, "gameKey");
            if (!key.startsWith("ga_live_")) throw new IllegalArgumentException("A client key is required");
            device = object(options.optJSONObject("device"));
            device.put("runtime", "unity");
            debug = options.optBoolean("isDebug");
            integrationVersion = options.optInt("experimentIntegrationVersion");
            accountUserId = optional(options, "accountUserId");
            accountUserCreatedAt = optional(options, "accountUserCreatedAt");
            GameAlgoCacheStorage storage = new GameAlgoFileCacheStorage(new File(activity.getApplicationContext().getNoBackupFilesDir(), "gamealgo-sdk"));
            GameAlgoClient client = new GameAlgoClient(key, required(options, "baseUrl"), GameAlgoClient.DEFAULT_SDK_VERSION,
                    options.optString("appVersion", ""), "android", new UrlConnectionGameAlgoHttpClient(),
                    new RustGameAlgoScriptRuntime(), storage, null,
                    options.optBoolean("enableLogging") ? GameAlgoLogger.console() : null, request(false));
            client.tracker().setDebug(debug);
            sdk = client;
            client.ready().whenComplete((unused, failure) -> {
                try { userId = client.userId(); } catch (Exception ignored) { /* Identity may not be available yet. */ }
            });
            return ok(null, identity(client));
        } catch (Exception error) { return failure(null, error); }
    }

    public static String read(String input) {
        try {
            JSONObject request = new JSONObject(input), args = request.getJSONObject("args");
            GameAlgoClient client = client();
            Object value;
            switch (required(request, "method")) {
                case "identity": value = identity(client); break;
                case "config": value = client.config().value(args.optString("path"), value(args.opt("fallback")), optional(args, "fileName")); break;
                case "strategyConfig": value = client.executor(required(args, "strategy")).value(args.optString("path"), value(args.opt("fallback"))); break;
                case "assignment": value = assignment(client.executor(required(args, "strategy")).assignment()); break;
                default: throw new IllegalArgumentException("Unsupported read operation");
            }
            return ok(null, value);
        } catch (Exception error) { return failure(null, error); }
    }

    public static long getForegroundTimeMs() { return client().getForegroundTimeMs(); }

    public static void send(String input, GamePropelCallback callback) {
        String id = null;
        try {
            JSONObject request = new JSONObject(input), args = request.getJSONObject("args");
            id = required(request, "id");
            String method = required(request, "method");
            GameAlgoClient client = client();
            // Enqueue telemetry immediately on the caller's thread. Network
            // waits never occupy the same lane as event enqueueing.
            if (isLocal(method)) callback.onResult(ok(id, local(client, method, args)));
            else {
                final String requestId = id;
                network.execute(() -> {
                    try { callback.onResult(ok(requestId, remote(client, method, args))); }
                    catch (Exception error) { callback.onResult(failure(requestId, error)); }
                });
            }
        } catch (Exception error) { callback.onResult(failure(id, error)); }
    }

    private static boolean isLocal(String method) {
        return method.equals("event") || method.equals("levelStart") || method.equals("levelEnd") || method.equals("sessionEnd")
                || method.equals("milestone") || method.equals("ad") || method.equals("purchase");
    }

    private static Object local(GameAlgoClient client, String method, JSONObject args) throws Exception {
        Map<String, Object> payload = object(args.optJSONObject("payload"));
        switch (method) {
            case "event": return client.tracker().trackEvent(required(args, "name"), payload);
            case "levelStart": return client.tracker().trackLevelStart(payload);
            case "levelEnd": return client.tracker().trackLevelEnd(payload);
            case "sessionEnd": return client.tracker().trackSessionEnd(payload);
            case "milestone": return client.tracker().trackMilestone(required(args, "type"), required(args, "point"), payload);
            case "ad": return client.tracker().trackAdPlacement(required(args, "adPlacementId"), args.getDouble("revenue"), optional(args, "network"), payload);
            case "purchase": return client.tracker().trackPurchase(required(args, "productId"), args.getDouble("revenue"), required(args, "currency"), payload);
            case "ddaRecord": client.dda(required(args, "strategy")).recordBehavior(required(args, "behavior"), args.getDouble("amount")); return null;
            case "ddaComplete": client.dda(required(args, "strategy")).completeStep(optional(args, "stepId")); return null;
            case "ddaReset": client.dda(required(args, "strategy")).reset(args.optString("scope", "all")); return null;
            default: throw new IllegalArgumentException("Unsupported local operation");
        }
    }

    private static Object remote(GameAlgoClient client, String method, JSONObject args) throws Exception {
        switch (method) {
            case "ddaRecord": case "ddaComplete": case "ddaReset": return local(client, method, args);
            case "ready": return client.waitForReady(args.optLong("timeoutMs", 5000));
            case "refresh": client.fetchConfig(request(args.optBoolean("forceRefresh"))); return null;
            case "newSession":
                String session = optional(args, "sessionId");
                if (session != null && session.trim().equals(client.tracker().currentSessionId())) return null;
                if (session == null) client.tracker().newSession(); else client.tracker().newSession(session);
                client.fetchConfig(request(true)); return null;
            case "flush": client.tracker().flush(); return null;
            case "attribution":
                GameAlgoUserAttributionResponse attribution = client.setAttribution(required(args, "provider"), object(args.optJSONObject("attribution")));
                return new JSONObject().put("accepted", attribution.getAccepted()).put("attributionHash", attribution.getAttributionHash());
            case "adjustParams":
                Map<String, String> parameters = new LinkedHashMap<>();
                client.configureAdjustServerCallbackParams(parameters::put);
                return parameters;
            case "identifier":
                String type = required(args, "type"), input = required(args, "value"), at = optional(args, "observedAt");
                GameAlgoContextIdentifierResponse response;
                switch (type) {
                    case "AdjustAdid": response = client.setAdjustAdid(input, at); break;
                    case "FirebaseAppInstanceId": response = client.setFirebaseAppInstanceId(input, at); break;
                    case "GoogleAdvertisingId": response = client.setGoogleAdvertisingId(input, at); break;
                    case "Oaid": response = client.setOaid(input, at); break;
                    default: throw new UnsupportedOperationException("This identifier is unavailable on Android");
                }
                return new JSONObject().put("accepted", response.getAccepted()).put("identifierHash", response.getIdentifierHash());
            case "caid": throw new UnsupportedOperationException("CAID is supported by the iOS bridge");
            case "execute":
                GameAlgoExecutionResult execution = client.executor(required(args, "strategy")).execute(value(args.opt("state")));
                if (execution == null || execution.getAssignment() == null) return null;
                return new JSONObject().put("payload", json(execution.getPayload())).put("diagnostics", json(execution.getDiagnostics()))
                        .put("assignment", assignment(execution.getAssignment()));
            case "ddaDecide":
                GameAlgoDDADecision decision = client.dda(required(args, "strategy")).decide(value(args.opt("context")));
                return new JSONObject().put("adjustment", decision.getAdjustment().name().toLowerCase(Locale.ROOT))
                        .put("payload", json(decision.getPayload())).put("diagnostics", json(decision.getDiagnostics()))
                        .put("assignment", assignment(decision.getAssignment())).put("isFallback", decision.isFallback());
            default: throw new IllegalArgumentException("Unsupported operation");
        }
    }

    private static GameAlgoFetchConfigRequest request(boolean force) {
        return new GameAlgoFetchConfigRequest(null).device(device).isDebug(debug)
                .accountUserId(accountUserId).accountUserCreatedAt(accountUserCreatedAt)
                .experimentIntegrationVersion(integrationVersion).forceRefresh(force);
    }
    private static GameAlgoClient client() {
        GameAlgoClient current = sdk;
        if (current == null) throw new IllegalStateException("Initialize GamePropel first");
        return current;
    }
    private static JSONObject identity(GameAlgoClient client) throws Exception {
        return new JSONObject().put("userId", userId).put("sessionId", client.tracker().currentSessionId())
                .put("isReady", client.snapshot().getConfig() != null).put("nativeSdkVersion", GameAlgoClient.DEFAULT_SDK_VERSION);
    }
    private static Object assignment(GameAlgoExperimentAssignment assignment) throws Exception {
        if (assignment == null) return JSONObject.NULL;
        return new JSONObject().put("key", assignment.getKey()).put("experimentId", assignment.getExperimentId())
                .put("variant", assignment.getVariant()).put("config", json(assignment.getConfig()));
    }
    private static Object json(Object value) { return value == null ? JSONObject.NULL : JSONObject.wrap(value); }
    private static String ok(String id, Object result) {
        try { return new JSONObject().put("id", id == null ? JSONObject.NULL : id).put("ok", true).put("result", json(result)).toString(); }
        catch (Exception error) { return failure(id, error); }
    }
    private static String failure(String id, Exception error) {
        try { return new JSONObject().put("id", id == null ? JSONObject.NULL : id).put("ok", false)
                .put("error", error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage()).toString(); }
        catch (Exception ignored) { return "{\"ok\":false,\"error\":\"Native bridge error\"}"; }
    }
    private static String required(JSONObject object, String name) throws Exception {
        String value = optional(object, name);
        if (value == null) throw new IllegalArgumentException(name + " is required");
        return value;
    }
    private static String optional(JSONObject object, String name) {
        return object.isNull(name) ? null : object.optString(name, "").trim().isEmpty() ? null : object.optString(name);
    }
    private static Map<String, Object> object(JSONObject source) throws Exception {
        Map<String, Object> result = new LinkedHashMap<>();
        if (source != null) for (Iterator<String> keys = source.keys(); keys.hasNext();) {
            String key = keys.next(); result.put(key, value(source.get(key)));
        }
        return result;
    }
    private static Object value(Object source) throws Exception {
        if (source == null || source == JSONObject.NULL) return null;
        if (source instanceof JSONObject) return object((JSONObject) source);
        if (source instanceof JSONArray) {
            List<Object> array = new ArrayList<>();
            for (int index = 0; index < ((JSONArray) source).length(); index++) array.add(value(((JSONArray) source).get(index)));
            return array;
        }
        return source;
    }
}
