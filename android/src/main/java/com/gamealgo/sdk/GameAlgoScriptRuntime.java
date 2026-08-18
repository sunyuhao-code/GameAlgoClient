package com.gamealgo.sdk;

public interface GameAlgoScriptRuntime {
    Object execute(String script, GameAlgoScriptInput input) throws GameAlgoException;

    default void prepare(String script) throws GameAlgoException {
        // Optional for custom runtimes. The Rust runtime prepares scripts eagerly.
    }
}
