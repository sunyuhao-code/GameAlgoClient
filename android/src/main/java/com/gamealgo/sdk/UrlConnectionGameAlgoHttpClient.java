package com.gamealgo.sdk;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class UrlConnectionGameAlgoHttpClient implements GameAlgoHttpClient {
    private final int connectTimeoutMillis;
    private final int readTimeoutMillis;

    public UrlConnectionGameAlgoHttpClient() {
        this(5000, 10000);
    }

    public UrlConnectionGameAlgoHttpClient(int connectTimeoutMillis, int readTimeoutMillis) {
        this.connectTimeoutMillis = connectTimeoutMillis;
        this.readTimeoutMillis = readTimeoutMillis;
    }

    @Override
    public GameAlgoHttpResponse send(GameAlgoHttpRequest request) throws IOException {
        HttpURLConnection connection = (HttpURLConnection) request.getUrl().openConnection();
        connection.setConnectTimeout(connectTimeoutMillis);
        connection.setReadTimeout(readTimeoutMillis);
        connection.setRequestMethod(request.getMethod().name());
        for (Map.Entry<String, String> header : request.getHeaders().entrySet()) {
            connection.setRequestProperty(header.getKey(), header.getValue());
        }

        byte[] body = request.getBody();
        if (body != null) {
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(body.length);
            try (OutputStream outputStream = connection.getOutputStream()) {
                outputStream.write(body);
            }
        }

        int statusCode = connection.getResponseCode();
        InputStream stream = statusCode >= 400 ? connection.getErrorStream() : connection.getInputStream();
        byte[] responseBody = stream == null ? new byte[0] : readAll(stream);

        Map<String, String> headers = new LinkedHashMap<>();
        for (Map.Entry<String, List<String>> entry : connection.getHeaderFields().entrySet()) {
            if (entry.getKey() == null || entry.getValue() == null || entry.getValue().isEmpty()) {
                continue;
            }
            headers.put(entry.getKey(), entry.getValue().get(0));
        }
        connection.disconnect();

        return new GameAlgoHttpResponse(statusCode, headers, responseBody);
    }

    private static byte[] readAll(InputStream stream) throws IOException {
        try (InputStream inputStream = stream; ByteArrayOutputStream outputStream = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = inputStream.read(buffer)) != -1) {
                outputStream.write(buffer, 0, read);
            }
            return outputStream.toByteArray();
        }
    }
}
