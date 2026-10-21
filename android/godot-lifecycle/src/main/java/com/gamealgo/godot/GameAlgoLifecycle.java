package com.gamealgo.godot;

import android.app.Activity;
import android.app.Application;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import java.util.UUID;

/** Sends lifecycle changes straight to Rust, even while Godot has no frames. */
public final class GameAlgoLifecycle implements Application.ActivityLifecycleCallbacks {
    private static GameAlgoLifecycle instance;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ProcessVisibility visibility;
    private boolean nativeReady;
    private final Runnable retry = new Runnable() {
        @Override public void run() { update(visibility.isForeground()); }
    };
    private final Runnable heartbeat = new Runnable() {
        @Override public void run() {
            if (nativeReady && visibility.isForeground()) {
                update(true);
                main.postDelayed(this, 10_000L);
            }
        }
    };

    private GameAlgoLifecycle(Application application) {
        visibility = new ProcessVisibility(new ProcessVisibility.Scheduler() {
            public void postDelayed(Runnable task, long delayMs) { main.postDelayed(task, delayMs); }
            public void cancel(Runnable task) { main.removeCallbacks(task); }
        }, foreground -> {
            if (!nativeReady) return;
            main.removeCallbacks(heartbeat);
            update(foreground);
            if (foreground) main.postDelayed(heartbeat, 10_000L);
        });
        application.registerActivityLifecycleCallbacks(this);
    }

    static synchronized void initialize(Application application) {
        if (instance == null) instance = new GameAlgoLifecycle(application);
    }

    /** Called through JavaClassWrapper after the GDExtension has configured. */
    public static boolean install(Activity activity) {
        if (activity == null) return false;
        try {
            System.loadLibrary("gamealgo_godot_runtime");
        } catch (LinkageError error) {
            Log.e("GameAlgoSDK", "Android lifecycle runtime unavailable", error);
            return false;
        }
        initialize(activity.getApplication());
        instance.main.post(() -> {
            instance.nativeReady = true;
            instance.main.removeCallbacks(instance.heartbeat);
            instance.update(instance.visibility.isForeground());
            if (instance.visibility.isForeground()) {
                instance.main.postDelayed(instance.heartbeat, 10_000L);
            }
        });
        return true;
    }

    private void update(boolean foreground) {
        main.removeCallbacks(retry);
        long now = System.currentTimeMillis();
        SimpleDateFormat utc = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        utc.setTimeZone(TimeZone.getTimeZone("UTC"));
        SimpleDateFormat local = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US);
        Date date = new Date(now);
        try {
            if (!nativeUpdate(foreground, now, utc.format(date), local.format(date), UUID.randomUUID().toString())) {
                Log.e("GameAlgoSDK", "Lifecycle persistence failed; will retry");
                main.postDelayed(retry, 100L);
            }
        } catch (LinkageError error) {
            nativeReady = false;
            main.removeCallbacks(heartbeat);
            Log.e("GameAlgoSDK", "Lifecycle bridge and GDExtension versions do not match", error);
        }
    }

    private static native boolean nativeUpdate(
            boolean foreground, long nowMs, String timestamp, String createdLocalAt, String nextEventId);

    @Override public void onActivityStarted(Activity activity) { visibility.started(activity); }
    @Override public void onActivityStopped(Activity activity) {
        visibility.stopped(activity, activity.isChangingConfigurations());
    }
    @Override public void onActivityCreated(Activity activity, Bundle state) {}
    @Override public void onActivityResumed(Activity activity) {}
    @Override public void onActivityPaused(Activity activity) {}
    @Override public void onActivitySaveInstanceState(Activity activity, Bundle state) {}
    @Override public void onActivityDestroyed(Activity activity) {}
}
