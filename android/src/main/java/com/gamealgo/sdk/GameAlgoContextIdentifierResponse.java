package com.gamealgo.sdk;

public final class GameAlgoContextIdentifierResponse {
    private final boolean ok;
    private final int accepted;
    private final String identifierHash;

    GameAlgoContextIdentifierResponse(boolean ok, int accepted, String identifierHash) {
        this.ok = ok;
        this.accepted = accepted;
        this.identifierHash = identifierHash;
    }

    public boolean isOk() {
        return ok;
    }

    public int getAccepted() {
        return accepted;
    }

    public String getIdentifierHash() {
        return identifierHash;
    }
}
