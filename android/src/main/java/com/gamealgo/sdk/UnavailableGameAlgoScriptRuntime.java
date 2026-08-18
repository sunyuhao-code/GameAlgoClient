package com.gamealgo.sdk;

/** Explicit opt-out runtime for apps that never execute script-backed strategies. */
public final class UnavailableGameAlgoScriptRuntime implements GameAlgoScriptRuntime {
    @Override
    public Object execute(String script, GameAlgoScriptInput input) throws GameAlgoException {
        throw new GameAlgoException("JavaScript execution is disabled for this GameAlgo client");
    }
}
