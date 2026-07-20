package com.gamealgo.sdk;

public final class GameAlgoUserIdentity {
    private final String userId;
    private final String userCreatedAt;
    private final String userCreatedLocalAt;

    GameAlgoUserIdentity(String userId, String userCreatedAt) {
        this(userId, userCreatedAt, "");
    }

    GameAlgoUserIdentity(String userId, String userCreatedAt, String userCreatedLocalAt) {
        this.userId = userId;
        this.userCreatedAt = userCreatedAt == null ? "" : userCreatedAt;
        this.userCreatedLocalAt = userCreatedLocalAt == null ? "" : userCreatedLocalAt;
    }

    public String getUserId() {
        return userId;
    }

    public String getUserCreatedAt() {
        return userCreatedAt;
    }

    public String getUserCreatedLocalAt() {
        return userCreatedLocalAt;
    }
}
