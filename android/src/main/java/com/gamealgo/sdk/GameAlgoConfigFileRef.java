package com.gamealgo.sdk;

public final class GameAlgoConfigFileRef {
    private final String versionId;
    private final String name;
    private final String url;
    private final String hash;
    private final String contentType;
    private final String updatedAt;

    GameAlgoConfigFileRef(String versionId, String name, String url, String hash, String contentType, String updatedAt) {
        this.versionId = versionId;
        this.name = name;
        this.url = url;
        this.hash = hash;
        this.contentType = contentType;
        this.updatedAt = updatedAt;
    }

    public String getVersionId() {
        return versionId;
    }

    public String getName() {
        return name;
    }

    public String getUrl() {
        return url;
    }

    public String getHash() {
        return hash;
    }

    public String getContentType() {
        return contentType;
    }

    public String getUpdatedAt() {
        return updatedAt;
    }
}
