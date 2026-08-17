package com.gamealgo.sdk;

import java.util.LinkedHashMap;
import java.util.Map;

/** Canonical sandboxed strategy runtime backed by the Rust QuickJS engine. */
public final class RustGameAlgoScriptRuntime implements GameAlgoScriptRuntime {
    static {
        System.loadLibrary("gamealgo_script_runtime");
    }

    @Override
    public Object execute(String script, GameAlgoScriptInput input) throws GameAlgoException {
        Map<String, Object> request = new LinkedHashMap<>();
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

    private static native String nativeExecute(String requestJson);
}
