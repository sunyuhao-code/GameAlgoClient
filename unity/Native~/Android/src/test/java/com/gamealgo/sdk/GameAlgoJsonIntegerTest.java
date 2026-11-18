package com.gamealgo.sdk;

import java.util.Map;

/** Regression for JNI pointer bits and large integer payloads. */
public final class GameAlgoJsonIntegerTest {
    public static void main(String[] args) throws Exception {
        for (long value : new long[] {0, 1, (1L << 53) + 1, Long.MIN_VALUE, Long.MAX_VALUE}) {
            Object parsed = GameAlgoJson.parse(Long.toString(value));
            if (!(parsed instanceof Long) || ((Long) parsed) != value)
                throw new AssertionError("Integer bits were lost");
            if (!GameAlgoJson.stringify(parsed).equals(Long.toString(value)))
                throw new AssertionError("Integer did not round-trip");
        }
        Object decimal = GameAlgoJson.parse("1.5");
        if (!(decimal instanceof Double) || ((Double) decimal) != 1.5)
            throw new AssertionError("Fractional values must remain Double");
        Map<?, ?> object = (Map<?, ?>)GameAlgoJson.parse("{\"sequence\":9007199254740993}");
        if (((Number)object.get("sequence")).longValue() != 9007199254740993L)
            throw new AssertionError("Nested payload lost precision");
        System.out.println("Integer JSON / JNI handle checks passed");
    }
}
