package com.gamealgo.sdk;

import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoFetchConfigRequest {
    private final String userId;
    private String sessionId;
    private String platform;
    private String sdkVersion;
    private String appVersion;
    private String deviceId;
    private String timezone;
    private Map<String, Object> device = new LinkedHashMap<>();
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

    public GameAlgoFetchConfigRequest sdkVersion(String sdkVersion) {
        this.sdkVersion = sdkVersion;
        return this;
    }

    public GameAlgoFetchConfigRequest appVersion(String appVersion) {
        this.appVersion = appVersion;
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

    public String getPlatform() {
        return platform;
    }

    public String getSdkVersion() {
        return sdkVersion;
    }

    public String getAppVersion() {
        return appVersion;
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

    public boolean isForceRefresh() {
        return forceRefresh;
    }
}
