package com.gamealgo.sdk;

public final class GameAlgoDDADecision {
    private final GameAlgoDDAAdjustment adjustment;
    private final Object payload;
    private final Object diagnostics;
    private final GameAlgoExperimentAssignment assignment;
    private final boolean fallback;

    GameAlgoDDADecision(
            GameAlgoDDAAdjustment adjustment,
            Object payload,
            Object diagnostics,
            GameAlgoExperimentAssignment assignment,
            boolean fallback) {
        this.adjustment = adjustment;
        this.payload = payload;
        this.diagnostics = diagnostics;
        this.assignment = assignment;
        this.fallback = fallback;
    }

    public GameAlgoDDAAdjustment getAdjustment() { return adjustment; }
    public Object getPayload() { return payload; }
    public Object getDiagnostics() { return diagnostics; }
    public GameAlgoExperimentAssignment getAssignment() { return assignment; }
    public boolean isFallback() { return fallback; }
}
