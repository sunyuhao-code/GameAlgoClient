package com.gamealgo.sdk;

public final class GameAlgoFetchConfigRequest {
    private final String userId;
    private String platform;
    private String sdkVersion;
    private String appVersion;
    private String deviceId;
    private boolean forceRefresh;

    public GameAlgoFetchConfigRequest(String userId) {
        this.userId = userId;
    }

    public GameAlgoFetchConfigRequest platform(String platform) {
        this.platform = platform;
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

    public GameAlgoFetchConfigRequest forceRefresh(boolean forceRefresh) {
        this.forceRefresh = forceRefresh;
        return this;
    }

    public String getUserId() {
        return userId;
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

    public boolean isForceRefresh() {
        return forceRefresh;
    }
}
