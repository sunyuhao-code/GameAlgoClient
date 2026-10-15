package com.gamealgo.sdk;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class GameAlgoEventQuotaConfig {
    private final String mode;
    private final int policyVersion;
    private final int ordinaryEventLimit;
    private final String quotaDate;
    private final String resetAt;
    private final List<String> exemptEventTypes;

    GameAlgoEventQuotaConfig(
            String mode,
            int policyVersion,
            int ordinaryEventLimit,
            String quotaDate,
            String resetAt,
            List<String> exemptEventTypes) {
        this.mode = mode;
        this.policyVersion = policyVersion;
        this.ordinaryEventLimit = ordinaryEventLimit;
        this.quotaDate = quotaDate;
        this.resetAt = resetAt;
        this.exemptEventTypes = Collections.unmodifiableList(new ArrayList<>(exemptEventTypes));
    }

    public String getMode() { return mode; }
    public int getPolicyVersion() { return policyVersion; }
    public int getOrdinaryEventLimit() { return ordinaryEventLimit; }
    public String getQuotaDate() { return quotaDate; }
    public String getResetAt() { return resetAt; }
    public List<String> getExemptEventTypes() { return exemptEventTypes; }
}
