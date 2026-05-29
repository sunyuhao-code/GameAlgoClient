package com.gamealgo.sdk;

public final class GameAlgoConfigFile {
    private final String name;
    private final String content;
    private final String contentType;
    private final String etag;

    GameAlgoConfigFile(String name, String content, String contentType, String etag) {
        this.name = name;
        this.content = content;
        this.contentType = contentType;
        this.etag = etag;
    }

    public String getName() {
        return name;
    }

    public String getContent() {
        return content;
    }

    public String getContentType() {
        return contentType;
    }

    public String getEtag() {
        return etag;
    }
}
