package com.gamealgo.sdk;

import java.util.Map;

/** Built-in sandboxed strategy runtime backed by the packaged native engine. */
public final class RustGameAlgoScriptRuntime implements GameAlgoScriptRuntime {
    private static boolean nativeLibraryLoaded;

    private long preparedHandle;
    private String preparedScript;

    @Override
    public synchronized void prepare(String script) throws GameAlgoException {
        if (script.equals(preparedScript) && preparedHandle != 0) {
            return;
        }
        ensureNativeLibraryLoaded();
        Map<String, Object> response = parseResponse(nativePrepare(script), "script prepare response");
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
        prepare(script);
        Map<String, Object> response = parseResponse(
                nativeExecutePrepared(preparedHandle, GameAlgoJson.stringify(input.toJson())),
                "runtime response"
        );
        return response.get("result");
    }

    private static synchronized void ensureNativeLibraryLoaded() throws GameAlgoException {
        if (nativeLibraryLoaded) return;
        try {
            System.loadLibrary("gamealgo_script_runtime");
            nativeLibraryLoaded = true;
        } catch (UnsatisfiedLinkError error) {
            throw new GameAlgoException("Packaged GameAlgo script runtime could not be loaded", error);
        }
    }

    private static Map<String, Object> parseResponse(String json, String field) throws GameAlgoException {
        Map<String, Object> response = GameAlgoJson.asObject(GameAlgoJson.parse(json), field);
        if (!"ok".equals(GameAlgoJson.stringValue(response, "status", true))) {
            String message = GameAlgoJson.stringValue(response, "message", false);
            throw new GameAlgoException(message == null ? "Script runtime operation failed" : message);
        }
        return response;
    }

    private void releasePrepared() {
        if (preparedHandle == 0) return;
        nativeRelease(preparedHandle);
        preparedHandle = 0;
        preparedScript = null;
    }

    private static native String nativePrepare(String script);
    private static native String nativeExecutePrepared(long handle, String inputJson);
    private static native void nativeRelease(long handle);
}
