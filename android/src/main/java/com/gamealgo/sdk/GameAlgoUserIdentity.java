package com.gamealgo.sdk;

public final class GameAlgoUserIdentity {
    private final String userId;
    private final String userCreatedAt;

    GameAlgoUserIdentity(String userId, String userCreatedAt) {
        this.userId = userId;
        this.userCreatedAt = userCreatedAt == null ? "" : userCreatedAt;
    }

    public String getUserId() {
        return userId;
    }

    public String getUserCreatedAt() {
        return userCreatedAt;
    }
}
