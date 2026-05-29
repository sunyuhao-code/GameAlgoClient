package com.gamealgo.sdk;

import java.net.URL;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoHttpRequest {
    private final URL url;
    private final GameAlgoHttpMethod method;
    private final Map<String, String> headers;
    private final byte[] body;

    public GameAlgoHttpRequest(URL url, GameAlgoHttpMethod method, Map<String, String> headers, byte[] body) {
        this.url = url;
        this.method = method;
        this.headers = Collections.unmodifiableMap(new LinkedHashMap<>(headers));
        this.body = body == null ? null : body.clone();
    }

    public URL getUrl() {
        return url;
    }

    public GameAlgoHttpMethod getMethod() {
        return method;
    }

    public Map<String, String> getHeaders() {
        return headers;
    }

    public byte[] getBody() {
        return body == null ? null : body.clone();
    }
}
