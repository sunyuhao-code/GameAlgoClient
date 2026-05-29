package com.gamealgo.sdk;

public interface GameAlgoScriptRuntime {
    Object execute(String script, GameAlgoScriptInput input) throws GameAlgoException;
}
