package com.gamealgo.sdk;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public final class GameAlgoAarInstrumentedTest {
    @Test
    public void publicApiLoadsFromAar() {
        assertNotNull(GameAlgoClient.class);
        assertNotNull(GameAlgoEventTracker.class);
    }


    @Test
    public void rustRuntimeExecutesSharedFixture() throws Exception {
        String script = readAsset("script-fixture.js");
        Map<String, Object> config = new LinkedHashMap<>();
        config.put("level", 2);
        GameAlgoScriptInput input = new GameAlgoScriptInput(
                Collections.<String, Object>emptyMap(),
                config,
                Collections.<String, Object>emptyMap()
        );

        Object result = new RustGameAlgoScriptRuntime().execute(script, input);
        Map<String, Object> resultObject = GameAlgoJson.asObject(result, "result");
        Map<String, Object> payload = GameAlgoJson.asObject(resultObject.get("payload"), "payload");
        assertEquals(2, ((Number) payload.get("level")).intValue());
    }


    @Test
    public void rustRuntimeInterruptsUnboundedScripts() {
        GameAlgoScriptInput input = new GameAlgoScriptInput(
                Collections.<String, Object>emptyMap(),
                Collections.<String, Object>emptyMap(),
                Collections.<String, Object>emptyMap()
        );
        assertThrows(
                GameAlgoException.class,
                () -> new RustGameAlgoScriptRuntime().execute("function execute() { while (true) {} }", input)
        );
    }


    @Test
    public void rustRuntimeBlocksIndirectFunctionConstructors() {
        GameAlgoScriptInput input = new GameAlgoScriptInput(
                Collections.<String, Object>emptyMap(),
                Collections.<String, Object>emptyMap(),
                Collections.<String, Object>emptyMap()
        );
        assertThrows(
                GameAlgoException.class,
                () -> new RustGameAlgoScriptRuntime().execute(
                        "function execute() { return { payload: (function() {}).constructor('return 7')() }; }",
                        input
                )
        );
    }


    private static String readAsset(String name) throws Exception {
        try (InputStream stream = InstrumentationRegistry.getInstrumentation().getContext().getAssets().open(name);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int read;
            while ((read = stream.read(buffer)) >= 0) {
                output.write(buffer, 0, read);
            }
            return output.toString(StandardCharsets.UTF_8.name());
        }
    }
}
