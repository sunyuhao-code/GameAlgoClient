package com.gamealgo.sdk;

import android.app.Activity;
import android.app.ActivityManager;
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
import java.io.File;
import java.lang.ref.WeakReference;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;

/** Application-owned monitor; a full-screen ad Activity is part of this process. */
public final class GameAlgoAndroidLifecycle implements Application.ActivityLifecycleCallbacks, ComponentCallbacks2 {
    private static GameAlgoAndroidLifecycle instance;
    private final Application application;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final CopyOnWriteArrayList<WeakReference<GameAlgoEventTracker>> trackers = new CopyOnWriteArrayList<>();
    private final PowerManager power;
    private final GameAlgoProcessVisibility visibility;
    private final ActivityManager.RunningAppProcessInfo process = new ActivityManager.RunningAppProcessInfo();
    private long lastCheckpoint = System.currentTimeMillis();
    private final Runnable heartbeat = new Runnable() {
        @Override public void run() {
            long now = System.currentTimeMillis();
            boolean foreground = currentForeground();
            for (WeakReference<GameAlgoEventTracker> reference : trackers) {
                GameAlgoEventTracker tracker = reference.get();
                if (tracker == null) trackers.remove(reference);
                else tracker.sampleSessionDuration(foreground, now);
            }
            if (now - lastCheckpoint >= 10_000L) {
                lastCheckpoint = now;
                report(foreground);
            }
            if (!trackers.isEmpty()) main.postDelayed(this, 1000L);
        }
    };

    static synchronized void initialize(Application application) {
        if (instance == null) instance = new GameAlgoAndroidLifecycle(application);
    }
    public static synchronized GameAlgoCacheStorage defaultStorage() {
        return instance == null ? null : new GameAlgoFileCacheStorage(new File(instance.application.getNoBackupFilesDir(), "gamealgo-sdk"));
    }
    public static synchronized AutoCloseable install(GameAlgoEventTracker tracker) {
        if (instance == null) return () -> {};
        GameAlgoAndroidLifecycle monitor = instance;
        WeakReference<GameAlgoEventTracker> reference = new WeakReference<>(tracker);
        AtomicBoolean detached = new AtomicBoolean();
        Runnable attach = () -> {
            if (detached.get()) return;
            tracker.enableLifecycle(monitor.currentForeground());
            monitor.trackers.add(reference);
            monitor.main.removeCallbacks(monitor.heartbeat);
            monitor.main.postDelayed(monitor.heartbeat, 1000L);
        };
        if (Looper.myLooper() == Looper.getMainLooper()) attach.run();
        else monitor.main.post(attach);
        return () -> { detached.set(true); monitor.trackers.remove(reference); };
    }
    private GameAlgoAndroidLifecycle(Application application) {
        this.application = application;
        power = (PowerManager) application.getSystemService(Context.POWER_SERVICE);
        visibility = new GameAlgoProcessVisibility(new GameAlgoProcessVisibility.Scheduler() {
            public void later(Runnable task, long delay) { main.postDelayed(task, delay); }
            public void cancel(Runnable task) { main.removeCallbacks(task); }
        }, foreground -> {
            report(foreground);
        });
        if (!interactive()) visibility.screenOff();
        application.registerActivityLifecycleCallbacks(this);
        application.registerComponentCallbacks(this);
        IntentFilter filter = new IntentFilter(Intent.ACTION_SCREEN_OFF);
        filter.addAction(Intent.ACTION_SCREEN_ON);
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction())) visibility.screenOff();
                else if (Intent.ACTION_SCREEN_ON.equals(intent.getAction())) visibility.screenOn(interactive());
            }
        };
        if (Build.VERSION.SDK_INT >= 33) application.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
        else application.registerReceiver(receiver, filter);
    }
    private boolean currentForeground() {
        ActivityManager.getMyMemoryState(process);
        return interactive() && (process.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
                || process.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE);
    }
    private boolean interactive() { return power == null || power.isInteractive(); }
    private void report(boolean foreground) {
        long now = System.currentTimeMillis();
        for (WeakReference<GameAlgoEventTracker> reference : trackers) {
            GameAlgoEventTracker tracker = reference.get();
            if (tracker == null) trackers.remove(reference);
            else tracker.observeLifecycle(foreground, now);
        }
    }
    @Override public void onActivityStarted(Activity activity) { visibility.started(activity); }
    @Override public void onActivityResumed(Activity activity) { visibility.resumed(activity, interactive()); }
    @Override public void onActivityPaused(Activity activity) { visibility.paused(activity); }
    @Override public void onActivityStopped(Activity activity) { visibility.stopped(activity, activity.isChangingConfigurations()); }
    @Override public void onActivityCreated(Activity activity, Bundle state) {}
    @Override public void onActivitySaveInstanceState(Activity activity, Bundle state) {}
    @Override public void onActivityDestroyed(Activity activity) {}
    @Override public void onTrimMemory(int level) { if (level == TRIM_MEMORY_UI_HIDDEN) visibility.uiHidden(); }
    @Override public void onConfigurationChanged(Configuration configuration) {}
    @Override public void onLowMemory() {}
}
