package com.gamealgo.sdk;

import java.io.IOException;
import java.io.UnsupportedEncodingException;
import java.net.MalformedURLException;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;

public final class GameAlgoClient {
    public static final String DEFAULT_SDK_VERSION = "1.0.0";
    private static final String USER_ID_KEY = "gamealgo_user_id";
    private static final String USER_CREATED_AT_KEY = "gamealgo_user_created_at";

    private final String gameKey;
    private final String baseUrl;
    private final String defaultPlatform;
    private final String defaultSDKVersion;
    private final String defaultAppVersion;
    private final GameAlgoHttpClient httpClient;
    private final GameAlgoScriptRuntime scriptRuntime;
    private final GameAlgoCacheStorage cacheStorage;
    private final String snapshotCacheKey;
    private final GameAlgoLogger logger;
    private final GameAlgoSnapshotStore snapshotStore;
    private final GameAlgoConfigReader configReader;
    private final GameAlgoEventTracker tracker;
    private CachedConfig cachedConfig;
    private GameAlgoUserIdentity userIdentity;
    private boolean didLogUserId;

    public GameAlgoClient(String gameKey, String baseUrl) {
        this(gameKey, baseUrl, DEFAULT_SDK_VERSION, null, "android", new UrlConnectionGameAlgoHttpClient());
    }

    public GameAlgoClient(
            String gameKey,
            String baseUrl,
            String sdkVersion,
            String appVersion,
            String platform,
            GameAlgoHttpClient httpClient) {
        this(gameKey, baseUrl, sdkVersion, appVersion, platform, httpClient, new JavaxScriptGameAlgoRuntime(), null, null);
    }

    public GameAlgoClient(
            String gameKey,
            String baseUrl,
            String sdkVersion,
            String appVersion,
            String platform,
            GameAlgoHttpClient httpClient,
            GameAlgoScriptRuntime scriptRuntime,
            GameAlgoCacheStorage cacheStorage,
            String cacheKey) {
        this(gameKey, baseUrl, sdkVersion, appVersion, platform, httpClient, scriptRuntime, cacheStorage, cacheKey, GameAlgoLogger.console());
    }

    public GameAlgoClient(
            String gameKey,
            String baseUrl,
            String sdkVersion,
            String appVersion,
            String platform,
            GameAlgoHttpClient httpClient,
            GameAlgoScriptRuntime scriptRuntime,
            GameAlgoCacheStorage cacheStorage,
            String cacheKey,
            GameAlgoLogger logger) {
        if (isBlank(gameKey)) {
            throw new IllegalArgumentException("gameKey is required");
        }
        if (isBlank(baseUrl)) {
            throw new IllegalArgumentException("baseUrl is required");
        }
        this.gameKey = gameKey;
        this.baseUrl = trimTrailingSlash(baseUrl);
        this.defaultSDKVersion = isBlank(sdkVersion) ? DEFAULT_SDK_VERSION : sdkVersion;
        this.defaultAppVersion = appVersion;
        this.defaultPlatform = isBlank(platform) ? "android" : platform;
        this.httpClient = httpClient == null ? new UrlConnectionGameAlgoHttpClient() : httpClient;
        this.scriptRuntime = scriptRuntime == null ? new JavaxScriptGameAlgoRuntime() : scriptRuntime;
        this.cacheStorage = cacheStorage;
        this.snapshotCacheKey = cacheKey == null ? "gamealgo:v1:snapshot:" + this.baseUrl + ":" + gameKey.substring(0, Math.min(16, gameKey.length())) : cacheKey;
        this.logger = logger;
        this.snapshotStore = new GameAlgoSnapshotStore();
        this.configReader = new GameAlgoConfigReader(snapshotStore);
        this.tracker = new GameAlgoEventTracker(this);
    }

    public CompletableFuture<Void> startAsync() {
        return startAsync(new GameAlgoFetchConfigRequest(null));
    }

    public CompletableFuture<Void> startAsync(String userId) {
        return startAsync(new GameAlgoFetchConfigRequest(userId));
    }

    public CompletableFuture<Void> startAsync(GameAlgoFetchConfigRequest request) {
        return CompletableFuture.runAsync(() -> {
            try {
                GameAlgoFetchConfigRequest resolvedRequest = requestWithResolvedUser(request);
                loadCachedSnapshot();
                try {
                    refresh(resolvedRequest);
                } catch (GameAlgoException error) {
                    if (snapshotStore.snapshot().getConfig() == null) {
                        log("config fetch failed: " + error.getMessage());
                        throw error;
                    }
                    log("config fetch failed, using cached snapshot: " + error.getMessage());
                }
            } catch (GameAlgoException error) {
                throw new CompletionException(error);
            }
        });
    }

    public GameAlgoExperimentExecutor executor(String key) {
        return new GameAlgoExperimentExecutor(key, snapshotStore, scriptRuntime, logger);
    }

    public GameAlgoConfigReader config() {
        return configReader;
    }

    public GameAlgoEventTracker tracker() {
        return tracker;
    }

    public GameAlgoSnapshot snapshot() {
        return snapshotStore.snapshot();
    }

    public synchronized String userId() throws GameAlgoException {
        return userIdentity(null).getUserId();
    }

    public synchronized GameAlgoUserIdentity userIdentity() throws GameAlgoException {
        return userIdentity(null);
    }

    public synchronized GameAlgoConfigResponse fetchConfig() throws GameAlgoException {
        return fetchConfig(new GameAlgoFetchConfigRequest(null));
    }

    public synchronized GameAlgoConfigResponse fetchConfig(String userId) throws GameAlgoException {
        return fetchConfig(new GameAlgoFetchConfigRequest(userId));
    }

    public synchronized GameAlgoConfigResponse fetchConfig(GameAlgoFetchConfigRequest request) throws GameAlgoException {
        GameAlgoFetchConfigRequest resolvedRequest = requestWithResolvedUser(request);
        String platform = isBlank(request.getPlatform()) ? defaultPlatform : request.getPlatform();
        String sdkVersion = isBlank(request.getSdkVersion()) ? defaultSDKVersion : request.getSdkVersion();
        String appVersion = request.getAppVersion() == null ? defaultAppVersion : request.getAppVersion();
        ConfigCacheKey cacheKey = new ConfigCacheKey(
                resolvedRequest.getUserId(),
                platform,
                sdkVersion,
                appVersion,
                request.getDeviceId()
        );

        long nowMillis = System.currentTimeMillis();
        if (!request.isForceRefresh()
                && cachedConfig != null
                && cachedConfig.key.equals(cacheKey)
                && cachedConfig.expiresAtMillis > nowMillis) {
            log("config cache hit: " + cachedConfig.value.getConfigVersion());
            return cachedConfig.value;
        }

        try {
            log("fetching config: userId=" + resolvedRequest.getUserId() + ", platform=" + platform);
            Map<String, String> query = new LinkedHashMap<>();
            query.put("userId", resolvedRequest.getUserId());
            query.put("platform", platform);
            query.put("sdkVersion", sdkVersion);
            if (appVersion != null) {
                query.put("appVersion", appVersion);
            }
            if (request.getDeviceId() != null) {
                query.put("deviceId", request.getDeviceId());
            }

            GameAlgoConfigResponse response = parseConfigResponse(
                    requestJson(endpoint("/v1/config", query), GameAlgoHttpMethod.GET, null)
            );
            cachedConfig = new CachedConfig(
                    cacheKey,
                    response,
                    System.currentTimeMillis() + Math.max(response.getTtlSeconds(), 0) * 1000L
            );
            snapshotStore.updateConfig(response, System.currentTimeMillis(), resolvedRequest.getUserId());
            tracker.setAssignments(response.getExperiments());
            persistSnapshot();
            log("config fetched: version=" + response.getConfigVersion()
                    + ", experiments=" + response.getExperiments().size()
                    + ", configFiles=" + response.getConfigFiles().size()
                    + ", ttl=" + response.getTtlSeconds() + "s");
            logAssignments(response.getExperiments(), "config ready");
            return response;
        } catch (GameAlgoException error) {
            if (cachedConfig != null && cachedConfig.key.equals(cacheKey)) {
                log("config fetch failed, using cached config: " + error.getMessage());
                return cachedConfig.value;
            }
            log("config fetch failed: " + error.getMessage());
            throw error;
        }
    }

    public synchronized GameAlgoConfigFile fetchConfigFile(String name) throws GameAlgoException {
        String safeName = normalizeFileName(name);
        GameAlgoHttpResponse response = request(
                endpoint("/v1/config-files/" + urlEncodePath(safeName), null),
                GameAlgoHttpMethod.GET,
                null
        );
        String content = new String(response.getBody(), StandardCharsets.UTF_8);
        String contentType = response.getHeader("content-type");
        GameAlgoConfigFile file = new GameAlgoConfigFile(
                safeName,
                content,
                contentType == null ? "application/octet-stream" : contentType,
                response.getHeader("etag")
        );
        snapshotStore.updateConfigFile(file, System.currentTimeMillis());
        persistSnapshot();
        log("config file loaded: " + file.getName() + " (" + file.getContentType() + ")");
        return file;
    }

    public synchronized GameAlgoEventBatchResponse uploadEvents(List<GameAlgoEvent> events) throws GameAlgoException {
        if (events == null || events.isEmpty()) {
            throw new GameAlgoException("events must be a non-empty array");
        }
        if (events.size() > 100) {
            throw new GameAlgoException("Maximum 100 events per batch");
        }

        String timestamp = isoTimestamp(new Date());
        List<Object> normalizedEvents = new ArrayList<>();
        for (GameAlgoEvent event : events) {
            normalizedEvents.add(event.toJson(defaultPlatform, defaultSDKVersion, defaultAppVersion, timestamp));
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("events", normalizedEvents);

        GameAlgoHttpResponse response = request(
                endpoint("/v1/events/batch", null),
                GameAlgoHttpMethod.POST,
                GameAlgoJson.stringify(body).getBytes(StandardCharsets.UTF_8)
        );
        return parseEventBatchResponse(parseJsonObject(response));
    }

    public synchronized void clearConfigCache() {
        cachedConfig = null;
    }

    private synchronized void refresh(GameAlgoFetchConfigRequest request) throws GameAlgoException {
        GameAlgoConfigResponse config = fetchConfig(request.forceRefresh(true));
        List<String> loadedNames = new ArrayList<>();
        int preloadCount = config.getConfigFiles().size();
        for (GameAlgoExperimentAssignment assignment : config.getExperiments()) {
            if (assignment.getScript() != null) {
                preloadCount += 1;
            }
        }
        if (preloadCount == 0) {
            log("no config files to preload");
        } else {
            log("preloading config files: " + preloadCount);
        }
        for (GameAlgoConfigFileRef file : config.getConfigFiles()) {
            fetchConfigFile(file.getName());
            loadedNames.add(file.getName());
        }
        for (GameAlgoExperimentAssignment assignment : config.getExperiments()) {
            if (assignment.getScript() != null) {
                fetchConfigFile(assignment.getScript().getName());
                loadedNames.add(assignment.getScript().getName());
            }
        }
        if (!loadedNames.isEmpty()) {
            log("all config files loaded");
        }
        for (GameAlgoExperimentAssignment assignment : config.getExperiments()) {
            if (assignment.getScript() != null && snapshotStore.snapshot().getConfigFiles().containsKey(assignment.getScript().getName())) {
                log("script loaded: " + assignment.getKey() + " -> " + assignment.getScript().getName());
            }
        }
        tracker.setAssignments(config.getExperiments());
        logAssignments(config.getExperiments(), "experiment");
        tracker.trackConfigLoaded();
        log("config_loaded queued");
    }

    private synchronized GameAlgoFetchConfigRequest requestWithResolvedUser(GameAlgoFetchConfigRequest request) throws GameAlgoException {
        GameAlgoUserIdentity identity = userIdentity(request.getUserId());
        logUserId(identity.getUserId());
        tracker.identify(identity.getUserId(), null, identity.getUserCreatedAt());
        GameAlgoFetchConfigRequest resolved = new GameAlgoFetchConfigRequest(identity.getUserId())
                .platform(request.getPlatform())
                .sdkVersion(request.getSdkVersion())
                .appVersion(request.getAppVersion())
                .deviceId(request.getDeviceId())
                .forceRefresh(request.isForceRefresh());
        return resolved;
    }

    private synchronized GameAlgoUserIdentity userIdentity(String explicitUserId) throws GameAlgoException {
        if (!isBlank(explicitUserId)) {
            if (userIdentity != null && explicitUserId.equals(userIdentity.getUserId())) {
                return userIdentity;
            }

            String createdAt = null;
            if (cacheStorage != null) {
                String existing = cacheStorage.getItem(USER_ID_KEY);
                if (explicitUserId.equals(existing)) {
                    createdAt = cacheStorage.getItem(USER_CREATED_AT_KEY);
                }
            }
            if (isBlank(createdAt)) {
                createdAt = isoTimestamp(new Date());
            }

            userIdentity = new GameAlgoUserIdentity(explicitUserId, createdAt);
            if (cacheStorage != null) {
                cacheStorage.setItem(USER_ID_KEY, userIdentity.getUserId());
                cacheStorage.setItem(USER_CREATED_AT_KEY, createdAt);
            }
            return userIdentity;
        }
        if (userIdentity != null) {
            return userIdentity;
        }

        if (cacheStorage != null) {
            String existing = cacheStorage.getItem(USER_ID_KEY);
            if (!isBlank(existing)) {
                String createdAt = cacheStorage.getItem(USER_CREATED_AT_KEY);
                userIdentity = new GameAlgoUserIdentity(existing, createdAt);
                return userIdentity;
            }
        }

        String createdAt = isoTimestamp(new Date());
        userIdentity = new GameAlgoUserIdentity(java.util.UUID.randomUUID().toString(), createdAt);
        if (cacheStorage != null) {
            cacheStorage.setItem(USER_ID_KEY, userIdentity.getUserId());
            cacheStorage.setItem(USER_CREATED_AT_KEY, createdAt);
        }
        return userIdentity;
    }

    private void loadCachedSnapshot() throws GameAlgoException {
        if (cacheStorage == null) {
            return;
        }
        String raw = cacheStorage.getItem(snapshotCacheKey);
        if (raw == null || raw.length() == 0) {
            return;
        }
        try {
            snapshotStore.replace(snapshotFromJson(GameAlgoJson.asObject(GameAlgoJson.parse(raw), "snapshot")));
            log("cached snapshot loaded");
        } catch (GameAlgoException error) {
            cacheStorage.removeItem(snapshotCacheKey);
        }
    }

    private void persistSnapshot() throws GameAlgoException {
        if (cacheStorage == null) {
            return;
        }
        cacheStorage.setItem(snapshotCacheKey, GameAlgoJson.stringify(snapshotToJson(snapshotStore.snapshot())));
    }

    private GameAlgoHttpResponse requestJson(URL url, GameAlgoHttpMethod method, byte[] body) throws GameAlgoException {
        return request(url, method, body);
    }

    private GameAlgoHttpResponse request(URL url, GameAlgoHttpMethod method, byte[] body) throws GameAlgoException {
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("X-GameAlgo-Key", gameKey);
        headers.put("Accept", "application/json");
        if (body != null) {
            headers.put("Content-Type", "application/json");
        }

        try {
            GameAlgoHttpResponse response = httpClient.send(new GameAlgoHttpRequest(url, method, headers, body));
            if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
                throw apiError(response);
            }
            return response;
        } catch (IOException error) {
            throw new GameAlgoException("Network request failed: " + error.getMessage(), error);
        }
    }

    private GameAlgoException apiError(GameAlgoHttpResponse response) {
        String fallback = "GameAlgo API returned " + response.getStatusCode();
        try {
            Map<String, Object> payload = parseJsonObject(response);
            String code = GameAlgoJson.stringValue(payload, "error", false);
            String message = GameAlgoJson.stringValue(payload, "message", false);
            return new GameAlgoException(response.getStatusCode(), code, message == null ? fallback : message);
        } catch (GameAlgoException ignored) {
            return new GameAlgoException(response.getStatusCode(), null, fallback);
        }
    }

    private Map<String, Object> parseJsonObject(GameAlgoHttpResponse response) throws GameAlgoException {
        String body = new String(response.getBody(), StandardCharsets.UTF_8);
        return GameAlgoJson.asObject(GameAlgoJson.parse(body), "response");
    }

    private GameAlgoConfigResponse parseConfigResponse(GameAlgoHttpResponse response) throws GameAlgoException {
        Map<String, Object> object = parseJsonObject(response);
        List<GameAlgoExperimentAssignment> experiments = new ArrayList<>();
        for (Object item : GameAlgoJson.asArray(object.get("experiments"), "experiments")) {
            Map<String, Object> experiment = GameAlgoJson.asObject(item, "experiments[]");
            experiments.add(new GameAlgoExperimentAssignment(
                    GameAlgoJson.stringValue(experiment, "key", true),
                    GameAlgoJson.stringValue(experiment, "experimentId", true),
                    GameAlgoJson.stringValue(experiment, "variant", true),
                    experiment.get("config"),
                    parseConfigFileRef(experiment.get("script"), "script", false)
            ));
        }

        List<GameAlgoConfigFileRef> configFiles = new ArrayList<>();
        for (Object item : GameAlgoJson.asArray(object.get("configFiles"), "configFiles")) {
            Map<String, Object> file = GameAlgoJson.asObject(item, "configFiles[]");
            configFiles.add(parseConfigFileRef(file, "configFiles[]", true));
        }

        return new GameAlgoConfigResponse(
                GameAlgoJson.stringValue(object, "gameId", true),
                GameAlgoJson.stringValue(object, "environment", true),
                GameAlgoJson.stringValue(object, "configVersion", true),
                GameAlgoJson.intValue(object, "ttlSeconds", true),
                GameAlgoJson.stringValue(object, "serverTime", true),
                experiments,
                configFiles
        );
    }

    private GameAlgoConfigFileRef parseConfigFileRef(Object value, String fieldName, boolean required) throws GameAlgoException {
        if (value == null) {
            if (required) {
                throw new GameAlgoException("Missing required field: " + fieldName);
            }
            return null;
        }
        Map<String, Object> file = GameAlgoJson.asObject(value, fieldName);
        return new GameAlgoConfigFileRef(
                GameAlgoJson.stringValue(file, "name", true),
                GameAlgoJson.stringValue(file, "url", true),
                GameAlgoJson.stringValue(file, "hash", true),
                GameAlgoJson.stringValue(file, "contentType", false),
                GameAlgoJson.stringValue(file, "updatedAt", false)
        );
    }

    private GameAlgoEventBatchResponse parseEventBatchResponse(Map<String, Object> object) throws GameAlgoException {
        return new GameAlgoEventBatchResponse(
                GameAlgoJson.boolValue(object, "ok", false),
                GameAlgoJson.intValue(object, "accepted", true)
        );
    }

    private Map<String, Object> snapshotToJson(GameAlgoSnapshot snapshot) {
        Map<String, Object> object = new LinkedHashMap<>();
        object.put("updatedAt", snapshot.getUpdatedAtMillis());
        object.put("userId", snapshot.getUserId());
        if (snapshot.getConfig() != null) {
            object.put("config", configToJson(snapshot.getConfig()));
        }
        List<Object> files = new ArrayList<>();
        for (GameAlgoConfigFile file : snapshot.getConfigFiles().values()) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("name", file.getName());
            item.put("content", file.getContent());
            item.put("contentType", file.getContentType());
            item.put("etag", file.getEtag());
            files.add(item);
        }
        object.put("configFiles", files);
        return object;
    }

    private GameAlgoSnapshot snapshotFromJson(Map<String, Object> object) throws GameAlgoException {
        GameAlgoConfigResponse config = object.get("config") == null
                ? null
                : configFromJson(GameAlgoJson.asObject(object.get("config"), "config"));
        Map<String, GameAlgoConfigFile> files = new LinkedHashMap<>();
        Object rawFiles = object.get("configFiles");
        if (rawFiles != null) {
            for (Object item : GameAlgoJson.asArray(rawFiles, "configFiles")) {
                Map<String, Object> file = GameAlgoJson.asObject(item, "configFiles[]");
                GameAlgoConfigFile parsed = new GameAlgoConfigFile(
                        GameAlgoJson.stringValue(file, "name", true),
                        GameAlgoJson.stringValue(file, "content", true),
                        GameAlgoJson.stringValue(file, "contentType", true),
                        GameAlgoJson.stringValue(file, "etag", false)
                );
                files.put(parsed.getName(), parsed);
            }
        }
        Object updatedAt = object.get("updatedAt");
        long updatedAtMillis = updatedAt instanceof Number ? ((Number) updatedAt).longValue() : 0;
        return new GameAlgoSnapshot(config, files, updatedAtMillis, GameAlgoJson.stringValue(object, "userId", false));
    }

    private Map<String, Object> configToJson(GameAlgoConfigResponse config) {
        Map<String, Object> object = new LinkedHashMap<>();
        object.put("gameId", config.getGameId());
        object.put("environment", config.getEnvironment());
        object.put("configVersion", config.getConfigVersion());
        object.put("ttlSeconds", config.getTtlSeconds());
        object.put("serverTime", config.getServerTime());

        List<Object> experiments = new ArrayList<>();
        for (GameAlgoExperimentAssignment assignment : config.getExperiments()) {
            Map<String, Object> experiment = new LinkedHashMap<>();
            experiment.put("key", assignment.getKey());
            experiment.put("experimentId", assignment.getExperimentId());
            experiment.put("variant", assignment.getVariant());
            experiment.put("config", assignment.getConfig());
            if (assignment.getScript() != null) {
                experiment.put("script", configFileRefToJson(assignment.getScript()));
            }
            experiments.add(experiment);
        }
        object.put("experiments", experiments);

        List<Object> configFiles = new ArrayList<>();
        for (GameAlgoConfigFileRef file : config.getConfigFiles()) {
            configFiles.add(configFileRefToJson(file));
        }
        object.put("configFiles", configFiles);
        return object;
    }

    private GameAlgoConfigResponse configFromJson(Map<String, Object> object) throws GameAlgoException {
        List<GameAlgoExperimentAssignment> experiments = new ArrayList<>();
        for (Object item : GameAlgoJson.asArray(object.get("experiments"), "experiments")) {
            Map<String, Object> experiment = GameAlgoJson.asObject(item, "experiments[]");
            experiments.add(new GameAlgoExperimentAssignment(
                    GameAlgoJson.stringValue(experiment, "key", true),
                    GameAlgoJson.stringValue(experiment, "experimentId", true),
                    GameAlgoJson.stringValue(experiment, "variant", true),
                    experiment.get("config"),
                    parseConfigFileRef(experiment.get("script"), "script", false)
            ));
        }

        List<GameAlgoConfigFileRef> configFiles = new ArrayList<>();
        for (Object item : GameAlgoJson.asArray(object.get("configFiles"), "configFiles")) {
            configFiles.add(parseConfigFileRef(item, "configFiles[]", true));
        }

        return new GameAlgoConfigResponse(
                GameAlgoJson.stringValue(object, "gameId", true),
                GameAlgoJson.stringValue(object, "environment", true),
                GameAlgoJson.stringValue(object, "configVersion", true),
                GameAlgoJson.intValue(object, "ttlSeconds", true),
                GameAlgoJson.stringValue(object, "serverTime", true),
                experiments,
                configFiles
        );
    }

    private Map<String, Object> configFileRefToJson(GameAlgoConfigFileRef file) {
        Map<String, Object> object = new LinkedHashMap<>();
        object.put("name", file.getName());
        object.put("url", file.getUrl());
        object.put("hash", file.getHash());
        object.put("contentType", file.getContentType());
        object.put("updatedAt", file.getUpdatedAt());
        return object;
    }

    private URL endpoint(String path, Map<String, String> query) throws GameAlgoException {
        StringBuilder builder = new StringBuilder(baseUrl).append(path);
        if (query != null && !query.isEmpty()) {
            boolean first = true;
            for (Map.Entry<String, String> entry : query.entrySet()) {
                if (entry.getValue() == null) {
                    continue;
                }
                builder.append(first ? '?' : '&');
                builder.append(urlEncodeQuery(entry.getKey()));
                builder.append('=');
                builder.append(urlEncodeQuery(entry.getValue()));
                first = false;
            }
        }
        try {
            return new URL(builder.toString());
        } catch (MalformedURLException error) {
            throw new GameAlgoException("Invalid URL: " + builder, error);
        }
    }

    private String normalizeFileName(String name) throws GameAlgoException {
        String trimmed = name == null ? "" : name.trim();
        if (!trimmed.matches("^[A-Za-z0-9][A-Za-z0-9_.-]*$") || trimmed.contains("..")) {
            throw new GameAlgoException("Invalid config file name: " + name);
        }
        return trimmed;
    }

    private static String urlEncodePath(String value) throws GameAlgoException {
        return urlEncodeQuery(value).replace("+", "%20");
    }

    private static String urlEncodeQuery(String value) throws GameAlgoException {
        try {
            return URLEncoder.encode(value, "UTF-8");
        } catch (UnsupportedEncodingException error) {
            throw new GameAlgoException("UTF-8 encoding is unavailable", error);
        }
    }

    private static String isoTimestamp(Date date) {
        SimpleDateFormat formatter = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        formatter.setTimeZone(TimeZone.getTimeZone("UTC"));
        return formatter.format(date);
    }

    private static String trimTrailingSlash(String value) {
        String result = value;
        while (result.endsWith("/")) {
            result = result.substring(0, result.length() - 1);
        }
        return result;
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().length() == 0;
    }

    private void logUserId(String userId) {
        if (didLogUserId) {
            return;
        }
        didLogUserId = true;
        log("userId: " + userId);
    }

    private void logAssignments(List<GameAlgoExperimentAssignment> assignments, String prefix) {
        for (GameAlgoExperimentAssignment assignment : assignments) {
            log(prefix + ": " + assignment.getKey() + " -> " + assignment.getVariant());
        }
    }

    private void log(String message) {
        if (logger != null) {
            logger.log("[GameAlgoSDK] " + message);
        }
    }

    private static final class CachedConfig {
        private final ConfigCacheKey key;
        private final GameAlgoConfigResponse value;
        private final long expiresAtMillis;

        private CachedConfig(ConfigCacheKey key, GameAlgoConfigResponse value, long expiresAtMillis) {
            this.key = key;
            this.value = value;
            this.expiresAtMillis = expiresAtMillis;
        }
    }

    private static final class ConfigCacheKey {
        private final String userId;
        private final String platform;
        private final String sdkVersion;
        private final String appVersion;
        private final String deviceId;

        private ConfigCacheKey(String userId, String platform, String sdkVersion, String appVersion, String deviceId) {
            this.userId = userId;
            this.platform = platform;
            this.sdkVersion = sdkVersion;
            this.appVersion = appVersion;
            this.deviceId = deviceId;
        }

        @Override
        public boolean equals(Object other) {
            if (this == other) {
                return true;
            }
            if (!(other instanceof ConfigCacheKey)) {
                return false;
            }
            ConfigCacheKey that = (ConfigCacheKey) other;
            return equalsNullable(userId, that.userId)
                    && equalsNullable(platform, that.platform)
                    && equalsNullable(sdkVersion, that.sdkVersion)
                    && equalsNullable(appVersion, that.appVersion)
                    && equalsNullable(deviceId, that.deviceId);
        }

        @Override
        public int hashCode() {
            int result = hashNullable(userId);
            result = 31 * result + hashNullable(platform);
            result = 31 * result + hashNullable(sdkVersion);
            result = 31 * result + hashNullable(appVersion);
            result = 31 * result + hashNullable(deviceId);
            return result;
        }

        private static boolean equalsNullable(Object left, Object right) {
            return left == null ? right == null : left.equals(right);
        }

        private static int hashNullable(Object value) {
            return value == null ? 0 : value.hashCode();
        }
    }
}
