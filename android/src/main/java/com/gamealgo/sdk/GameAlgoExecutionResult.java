package com.gamealgo.sdk;

public final class GameAlgoExecutionResult {
    private final Object payload;
    private final Object diagnostics;
    private final GameAlgoExperimentAssignment assignment;

    GameAlgoExecutionResult(Object payload, Object diagnostics, GameAlgoExperimentAssignment assignment) {
        this.payload = payload;
        this.diagnostics = diagnostics;
        this.assignment = assignment;
    }

    public Object getPayload() {
        return payload;
    }

    public Object getDiagnostics() {
        return diagnostics;
    }

    public GameAlgoExperimentAssignment getAssignment() {
        return assignment;
    }
}
