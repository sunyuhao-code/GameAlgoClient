package com.gamealgo.sdk;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;

/** Matches the Godot bridge's process-wide visibility rules, including ads. */
final class GameAlgoProcessVisibility {
    interface Scheduler { void later(Runnable task, long delay); void cancel(Runnable task); }
    interface Listener { void changed(boolean foreground); }
    private final Set<Object> started = Collections.newSetFromMap(new IdentityHashMap<>());
    private final Set<Object> resumed = Collections.newSetFromMap(new IdentityHashMap<>());
    private final Scheduler scheduler;
    private final Listener listener;
    private volatile boolean foreground;
    private boolean uiHidden;
    private boolean interactive = true;
    private final Runnable confirmBackground;

    GameAlgoProcessVisibility(Scheduler scheduler, Listener listener) {
        this.scheduler = scheduler; this.listener = listener;
        confirmBackground = () -> { if (started.isEmpty()) hide(); };
    }
    void started(Object activity) {
        scheduler.cancel(confirmBackground); started.add(activity);
        if (interactive && !uiHidden) show();
    }
    void resumed(Object activity, boolean interactive) {
        resumed.add(activity); this.interactive = interactive;
        if (!interactive) { hide(); return; }
        uiHidden = false; scheduler.cancel(confirmBackground); show();
    }
    void paused(Object activity) { resumed.remove(activity); }
    void stopped(Object activity, boolean changing) {
        resumed.remove(activity);
        if (started.remove(activity) && foreground && started.isEmpty() && !changing) {
            scheduler.cancel(confirmBackground); scheduler.later(confirmBackground, 100L);
        }
    }
    void uiHidden() { uiHidden = true; hide(); }
    void screenOff() { interactive = false; hide(); }
    void screenOn(boolean interactive) {
        this.interactive = interactive;
        if (interactive && !uiHidden && !resumed.isEmpty()) show();
    }
    boolean isForeground() { return foreground; }
    private void show() { if (!foreground) { foreground = true; listener.changed(true); } }
    private void hide() { scheduler.cancel(confirmBackground); if (foreground) { foreground = false; listener.changed(false); } }
}
