package com.gamealgo.sdk;

/** Default runtime for Android builds until the app injects its JavaScript runtime. */
public final class UnavailableGameAlgoScriptRuntime implements GameAlgoScriptRuntime {
    @Override
    public Object execute(String script, GameAlgoScriptInput input) throws GameAlgoException {
        throw new GameAlgoException("No JavaScript runtime is configured; inject a GameAlgoScriptRuntime");
    }
}
