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
        return init(gameKey, baseUrl, sdkVersion, appVersion, 0, cacheStorage);
    }

    public static synchronized GameAlgoClient init(
            String gameKey,
            String baseUrl,
            String sdkVersion,
            String appVersion,
            int experimentIntegrationVersion) {
        return init(gameKey, baseUrl, sdkVersion, appVersion, experimentIntegrationVersion, null);
    }

    public static synchronized GameAlgoClient init(
            String gameKey,
            String baseUrl,
            String sdkVersion,
            String appVersion,
            int experimentIntegrationVersion,
            GameAlgoCacheStorage cacheStorage) {
        client = new GameAlgoClient(
                gameKey,
                baseUrl,
                sdkVersion,
                appVersion,
                "android",
                new UrlConnectionGameAlgoHttpClient(),
                new RustGameAlgoScriptRuntime(),
                cacheStorage,
                null,
                GameAlgoLogger.console(),
                new GameAlgoFetchConfigRequest(null).experimentIntegrationVersion(experimentIntegrationVersion)
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
