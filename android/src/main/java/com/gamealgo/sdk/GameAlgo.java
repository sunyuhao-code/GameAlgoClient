package com.gamealgo.sdk;

public final class GameAlgo {
    private static volatile GameAlgoClient client;

    private GameAlgo() {}

    public static synchronized GameAlgoClient init(
            String gameKey,
            String baseUrl,
            int experimentIntegrationVersion) {
        return init(gameKey, baseUrl, GameAlgoClient.DEFAULT_SDK_VERSION, null, experimentIntegrationVersion, null, null);
    }

    public static synchronized GameAlgoClient init(
            String gameKey,
            String baseUrl,
            int experimentIntegrationVersion,
            Boolean isOldUser) {
        return init(gameKey, baseUrl, GameAlgoClient.DEFAULT_SDK_VERSION, null, experimentIntegrationVersion, null, isOldUser);
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
        return init(gameKey, baseUrl, sdkVersion, appVersion, experimentIntegrationVersion, cacheStorage, null);
    }

    public static synchronized GameAlgoClient init(
            String gameKey,
            String baseUrl,
            String sdkVersion,
            String appVersion,
            int experimentIntegrationVersion,
            GameAlgoCacheStorage cacheStorage,
            Boolean isOldUser) {
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
                new GameAlgoFetchConfigRequest(null).experimentIntegrationVersion(experimentIntegrationVersion).isOldUser(isOldUser)
        );
        return client;
    }

    public static long getForegroundTimeMs() { return client().getForegroundTimeMs(); }

    public static GameAlgoClient client() {
        GameAlgoClient current = client;
        if (current == null) {
            throw new IllegalStateException("GameAlgo.init must be called before GameAlgo.client");
        }
        return current;
    }
}
