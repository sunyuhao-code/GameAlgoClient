package com.gamealgo.sdk;

public final class GameAlgoUserAttributionResponse {
    private final boolean ok;
    private final int accepted;
    private final String attributionHash;

    GameAlgoUserAttributionResponse(boolean ok, int accepted, String attributionHash) {
        this.ok = ok;
        this.accepted = accepted;
        this.attributionHash = attributionHash;
    }

    public boolean isOk() {
        return ok;
    }

    public int getAccepted() {
        return accepted;
    }

    public String getAttributionHash() {
        return attributionHash;
    }
}
