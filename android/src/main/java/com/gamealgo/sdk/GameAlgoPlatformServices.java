package com.gamealgo.sdk;

/** Keeps the core usable in plain JVM programs; Android hooks live in the AAR. */
final class GameAlgoPlatformServices {
    static GameAlgoCacheStorage defaultStorage() {
        try {
            return (GameAlgoCacheStorage) Class.forName("com.gamealgo.sdk.GameAlgoAndroidLifecycle")
                    .getMethod("defaultStorage").invoke(null);
        } catch (ReflectiveOperationException | LinkageError ignored) { return null; }
    }

    static void attach(GameAlgoEventTracker tracker) {
        try {
            AutoCloseable registration = (AutoCloseable) Class.forName("com.gamealgo.sdk.GameAlgoAndroidLifecycle")
                    .getMethod("install", GameAlgoEventTracker.class).invoke(null, tracker);
            tracker.setLifecycleRegistration(registration);
        } catch (ReflectiveOperationException | LinkageError ignored) { /* No Android runtime. */ }
    }
}
