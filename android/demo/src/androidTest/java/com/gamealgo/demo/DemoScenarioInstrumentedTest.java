package com.gamealgo.demo;

import androidx.test.ext.junit.runners.AndroidJUnit4;

import org.junit.Test;
import org.junit.runner.RunWith;

import static org.junit.Assert.assertTrue;

@RunWith(AndroidJUnit4.class)
public final class DemoScenarioInstrumentedTest {
    @Test
    public void packagedAarRunsOnMinimumSupportedAndroidVersion() throws Exception {
        assertTrue(DemoScenario.run().startsWith("PASSED"));
    }
}
