package com.gamealgo.demo;

import org.junit.Test;

import static org.junit.Assert.assertTrue;

public final class DemoScenarioTest {
    @Test
    public void packagedAarSupportsAnAppIntegrationFlow() throws Exception {
        assertTrue(DemoScenario.run().startsWith("PASSED"));
    }
}
