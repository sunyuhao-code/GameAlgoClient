package com.gamealgo.sdk;

import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoFetchConfigRequest {
    private final String userId;
    private String userCreatedAt;
    private String accountUserId;
    private String accountUserCreatedAt;
    private String sessionId;
    private String platform;
    private String sdkVersion;
    private String appVersion;
    private Integer experimentIntegrationVersion;
    private String deviceId;
    private String timezone;
    private Map<String, Object> device = new LinkedHashMap<>();
    private Boolean isDebug;
    private boolean forceRefresh;

    public GameAlgoFetchConfigRequest(String userId) {
        this.userId = userId;
    }

    public GameAlgoFetchConfigRequest platform(String platform) {
        this.platform = platform;
        return this;
    }

    public GameAlgoFetchConfigRequest sessionId(String sessionId) {
        this.sessionId = sessionId;
        return this;
    }

    GameAlgoFetchConfigRequest userCreatedAt(String userCreatedAt) {
        this.userCreatedAt = userCreatedAt;
        return this;
    }

    public GameAlgoFetchConfigRequest accountUserId(String accountUserId) {
        this.accountUserId = accountUserId;
        return this;
    }

    public GameAlgoFetchConfigRequest accountUserCreatedAt(String accountUserCreatedAt) {
        this.accountUserCreatedAt = accountUserCreatedAt;
        return this;
    }

    public GameAlgoFetchConfigRequest sdkVersion(String sdkVersion) {
        this.sdkVersion = sdkVersion;
        return this;
    }

    public GameAlgoFetchConfigRequest appVersion(String appVersion) {
        this.appVersion = appVersion;
        return this;
    }

    public GameAlgoFetchConfigRequest experimentIntegrationVersion(int experimentIntegrationVersion) {
        if (experimentIntegrationVersion < 0) {
            throw new IllegalArgumentException("experimentIntegrationVersion must be a non-negative integer");
        }
        this.experimentIntegrationVersion = experimentIntegrationVersion;
        return this;
    }

    public GameAlgoFetchConfigRequest deviceId(String deviceId) {
        this.deviceId = deviceId;
        return this;
    }

    public GameAlgoFetchConfigRequest timezone(String timezone) {
        this.timezone = timezone;
        return this;
    }

    public GameAlgoFetchConfigRequest device(Map<String, Object> device) {
        this.device = device == null ? new LinkedHashMap<String, Object>() : new LinkedHashMap<>(device);
        return this;
    }

    public GameAlgoFetchConfigRequest isDebug(Boolean isDebug) {
        this.isDebug = isDebug;
        return this;
    }

    public GameAlgoFetchConfigRequest forceRefresh(boolean forceRefresh) {
        this.forceRefresh = forceRefresh;
        return this;
    }

    public String getUserId() {
        return userId;
    }

    public String getSessionId() {
        return sessionId;
    }

    String getUserCreatedAt() {
        return userCreatedAt;
    }

    public String getAccountUserId() {
        return accountUserId;
    }

    public String getAccountUserCreatedAt() {
        return accountUserCreatedAt;
    }

    public String getPlatform() {
        return platform;
    }

    public String getSdkVersion() {
        return sdkVersion;
    }

    public String getAppVersion() {
        return appVersion;
    }

    public Integer getExperimentIntegrationVersion() {
        return experimentIntegrationVersion;
    }

    public String getDeviceId() {
        return deviceId;
    }

    public String getTimezone() {
        return timezone;
    }

    public Map<String, Object> getDevice() {
        return new LinkedHashMap<>(device);
    }

    public Boolean getIsDebug() {
        return isDebug;
    }

    public boolean isForceRefresh() {
        return forceRefresh;
    }
}
