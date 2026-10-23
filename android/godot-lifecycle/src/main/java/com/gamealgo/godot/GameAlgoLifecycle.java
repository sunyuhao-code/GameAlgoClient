package com.gamealgo.godot;

import android.app.Activity;
import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.ComponentCallbacks2;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.res.Configuration;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import java.util.UUID;

/** Sends lifecycle changes straight to Rust, even while Godot has no frames. */
public final class GameAlgoLifecycle implements Application.ActivityLifecycleCallbacks, ComponentCallbacks2 {
    private static GameAlgoLifecycle instance;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ProcessVisibility visibility;
    private final PowerManager powerManager;
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
        powerManager = (PowerManager) application.getSystemService(Context.POWER_SERVICE);
        visibility = new ProcessVisibility(new ProcessVisibility.Scheduler() {
            public void postDelayed(Runnable task, long delayMs) { main.postDelayed(task, delayMs); }
            public void cancel(Runnable task) { main.removeCallbacks(task); }
        }, foreground -> {
            if (!nativeReady) return;
            main.removeCallbacks(heartbeat);
            update(foreground);
            if (foreground) main.postDelayed(heartbeat, 10_000L);
        });
        if (!isInteractive()) visibility.screenOff();
        application.registerActivityLifecycleCallbacks(this);
        application.registerComponentCallbacks(this);
        IntentFilter screenFilter = new IntentFilter(Intent.ACTION_SCREEN_OFF);
        screenFilter.addAction(Intent.ACTION_SCREEN_ON);
        BroadcastReceiver screenReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction())) visibility.screenOff();
                else if (Intent.ACTION_SCREEN_ON.equals(intent.getAction())) visibility.screenOn(isInteractive());
            }
        };
        // The singleton and these Application registrations live for the process.
        if (Build.VERSION.SDK_INT >= 33) {
            application.registerReceiver(screenReceiver, screenFilter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            application.registerReceiver(screenReceiver, screenFilter);
        }
    }

    private boolean isInteractive() {
        return powerManager == null || powerManager.isInteractive();
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
    @Override public void onActivityResumed(Activity activity) { visibility.resumed(activity, isInteractive()); }
    @Override public void onActivityPaused(Activity activity) { visibility.paused(activity); }
    @Override public void onActivitySaveInstanceState(Activity activity, Bundle state) {}
    @Override public void onActivityDestroyed(Activity activity) {}
    @Override public void onTrimMemory(int level) {
        // Other trim levels describe memory pressure, not an explicit UI transition.
        if (level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) visibility.uiHidden();
    }
    @Override public void onConfigurationChanged(Configuration configuration) {}
    @Override public void onLowMemory() {}
}
