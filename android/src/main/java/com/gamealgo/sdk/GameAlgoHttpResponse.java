package com.gamealgo.sdk;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

public final class GameAlgoHttpResponse {
    private final int statusCode;
    private final Map<String, String> headers;
    private final byte[] body;

    public GameAlgoHttpResponse(int statusCode, Map<String, String> headers, byte[] body) {
        this.statusCode = statusCode;
        this.headers = Collections.unmodifiableMap(new LinkedHashMap<>(headers));
        this.body = body == null ? new byte[0] : body.clone();
    }

    public int getStatusCode() {
        return statusCode;
    }

    public Map<String, String> getHeaders() {
        return headers;
    }

    public String getHeader(String name) {
        String lowercased = name.toLowerCase(Locale.US);
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if (entry.getKey().toLowerCase(Locale.US).equals(lowercased)) {
                return entry.getValue();
            }
        }
        return null;
    }

    public byte[] getBody() {
        return body.clone();
    }
}
