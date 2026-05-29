package com.gamealgo.sdk;

import javax.script.Invocable;
import javax.script.ScriptEngine;
import javax.script.ScriptEngineManager;
import javax.script.ScriptException;

public final class JavaxScriptGameAlgoRuntime implements GameAlgoScriptRuntime {
    @Override
    public Object execute(String script, GameAlgoScriptInput input) throws GameAlgoException {
        ScriptEngine engine = new ScriptEngineManager().getEngineByName("JavaScript");
        if (engine == null) {
            throw new GameAlgoException("No JavaScript runtime is available");
        }
        try {
            engine.eval(script);
            return ((Invocable) engine).invokeFunction("execute", input.toJson());
        } catch (NoSuchMethodException | ScriptException error) {
            throw new GameAlgoException("Script execution failed: " + error.getMessage(), error);
        }
    }
}
