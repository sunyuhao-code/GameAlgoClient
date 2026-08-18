package com.gamealgo.demo;

import org.junit.Test;

import static org.junit.Assert.assertNotNull;

import com.gamealgo.sdk.RustGameAlgoScriptRuntime;

public final class DemoScenarioTest {
    @Test
    public void packagedAarExposesTheNativeRuntimeAdapter() {
        assertNotNull(RustGameAlgoScriptRuntime.class);
    }
}
