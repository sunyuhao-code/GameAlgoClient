package com.gamealgo.sdk;

public final class GameAlgo {
    private static volatile GameAlgoClient client;

    private GameAlgo() {}

    public static synchronized GameAlgoClient init(String gameKey, String baseUrl) {
        client = new GameAlgoClient(gameKey, baseUrl);
        return client;
    }

    public static synchronized GameAlgoClient init(
            String gameKey,
            String baseUrl,
            String sdkVersion,
            String appVersion) {
        return init(gameKey, baseUrl, sdkVersion, appVersion, null);
    }

    public static synchronized GameAlgoClient init(
            String gameKey,
            String baseUrl,
            String sdkVersion,
            String appVersion,
            GameAlgoCacheStorage cacheStorage) {
        client = new GameAlgoClient(
                gameKey,
                baseUrl,
                sdkVersion,
                appVersion,
                "android",
                new UrlConnectionGameAlgoHttpClient(),
                new JavaxScriptGameAlgoRuntime(),
                cacheStorage,
                null
        );
        return client;
    }

    public static GameAlgoClient client() {
        GameAlgoClient current = client;
        if (current == null) {
            throw new IllegalStateException("GameAlgo.init must be called before GameAlgo.client");
        }
        return current;
    }
}
