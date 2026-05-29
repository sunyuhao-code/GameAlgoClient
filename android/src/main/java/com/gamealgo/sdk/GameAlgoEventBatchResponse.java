package com.gamealgo.sdk;

public final class GameAlgoEventBatchResponse {
    private final boolean ok;
    private final int accepted;

    GameAlgoEventBatchResponse(boolean ok, int accepted) {
        this.ok = ok;
        this.accepted = accepted;
    }

    public boolean isOk() {
        return ok;
    }

    public int getAccepted() {
        return accepted;
    }
}
