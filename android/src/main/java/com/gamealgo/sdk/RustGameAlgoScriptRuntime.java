package com.gamealgo.sdk;

import java.util.Map;

/** Canonical sandboxed strategy runtime backed by the Rust QuickJS engine. */
public final class RustGameAlgoScriptRuntime implements GameAlgoScriptRuntime {
    static {
        System.loadLibrary("gamealgo_script_runtime");
    }

    private long preparedHandle;
    private String preparedScript;
    private boolean preparedRuntimeAvailable = true;

    @Override
    public synchronized void prepare(String script) throws GameAlgoException {
        if (!preparedRuntimeAvailable) return;
        if (script.equals(preparedScript) && preparedHandle != 0) {
            return;
        }
        final Map<String, Object> response;
        try {
            response = GameAlgoJson.asObject(
                    GameAlgoJson.parse(nativePrepare(script)),
                    "script prepare response"
            );
        } catch (UnsatisfiedLinkError error) {
            // Keep source compatibility with an older packaged .so. New
            // builds use prepared handles; old builds use the legacy call.
            preparedRuntimeAvailable = false;
            return;
        }
        String status = GameAlgoJson.stringValue(response, "status", true);
        if (!"ok".equals(status)) {
            throw new GameAlgoException(GameAlgoJson.stringValue(response, "message", false));
        }
        Object handleValue = response.get("handle");
        if (!(handleValue instanceof Number) || ((Number) handleValue).longValue() == 0) {
            throw new GameAlgoException("Script prepare response did not contain a handle");
        }
        long nextHandle = ((Number) handleValue).longValue();
        releasePrepared();
        preparedHandle = nextHandle;
        preparedScript = script;
    }

    @Override
    public synchronized Object execute(String script, GameAlgoScriptInput input) throws GameAlgoException {
        if (!preparedRuntimeAvailable) {
            return executeLegacy(script, input);
        }
        prepare(script);
        if (!preparedRuntimeAvailable) {
            return executeLegacy(script, input);
        }
        String inputJson = GameAlgoJson.stringify(input.toJson());
        Object decoded = GameAlgoJson.parse(nativeExecutePrepared(preparedHandle, inputJson));
        Map<String, Object> response = GameAlgoJson.asObject(decoded, "runtime response");
        String status = GameAlgoJson.stringValue(response, "status", true);
        if (!"ok".equals(status)) {
            String message = GameAlgoJson.stringValue(response, "message", false);
            throw new GameAlgoException(message == null ? "Script execution failed" : message);
        }
        return response.get("result");
    }

    private Object executeLegacy(String script, GameAlgoScriptInput input) throws GameAlgoException {
        Map<String, Object> request = new java.util.LinkedHashMap<>();
        request.put("script", script);
        request.put("input", input.toJson());
        Object decoded = GameAlgoJson.parse(nativeExecute(GameAlgoJson.stringify(request)));
        Map<String, Object> response = GameAlgoJson.asObject(decoded, "runtime response");
        String status = GameAlgoJson.stringValue(response, "status", true);
        if (!"ok".equals(status)) {
            String message = GameAlgoJson.stringValue(response, "message", false);
            throw new GameAlgoException(message == null ? "Script execution failed" : message);
        }
        return response.get("result");
    }

    private void releasePrepared() {
        if (preparedHandle != 0) {
            nativeRelease(preparedHandle);
            preparedHandle = 0;
            preparedScript = null;
        }
    }

    private static native String nativePrepare(String script);
    private static native String nativeExecute(String requestJson);
    private static native String nativeExecutePrepared(long handle, String inputJson);
    private static native void nativeRelease(long handle);
}
