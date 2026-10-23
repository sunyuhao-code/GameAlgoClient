package com.gamealgo.godot;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;

/** UI-thread-only state machine; the key includes ad SDK Activities. */
final class ProcessVisibility {
    static final long BACKGROUND_DELAY_MS = 100L;

    interface Scheduler {
        void postDelayed(Runnable runnable, long delayMs);
        void cancel(Runnable runnable);
    }

    interface Listener {
        void changed(boolean foreground);
    }

    private final Set<Object> started = Collections.newSetFromMap(new IdentityHashMap<>());
    private final Set<Object> resumed = Collections.newSetFromMap(new IdentityHashMap<>());
    private final Scheduler scheduler;
    private final Listener listener;
    private boolean foreground;
    private boolean interactive = true;
    private boolean uiHidden;
    private final Runnable confirmBackground;

    ProcessVisibility(Scheduler scheduler, Listener listener) {
        this.scheduler = scheduler;
        this.listener = listener;
        confirmBackground = () -> {
            if (started.isEmpty() && foreground) {
                foreground = false;
                listener.changed(false);
            }
        };
    }

    void started(Object activity) {
        scheduler.cancel(confirmBackground);
        started.add(activity);
        if (interactive && !uiHidden) show();
    }

    void resumed(Object activity, boolean deviceInteractive) {
        resumed.add(activity);
        interactive = deviceInteractive;
        if (!interactive) {
            hide();
            return;
        }
        uiHidden = false;
        scheduler.cancel(confirmBackground);
        show();
    }

    void paused(Object activity) {
        // Pausing the game for an ad does not hide the whole process.
        resumed.remove(activity);
    }

    void uiHidden() {
        uiHidden = true;
        hide();
    }

    void screenOff() {
        interactive = false;
        hide();
    }

    void screenOn(boolean deviceInteractive) {
        interactive = deviceInteractive;
        // Waking to the lock screen or launcher does not foreground the app.
        if (interactive && !uiHidden && !resumed.isEmpty()) show();
    }

    private void show() {
        if (foreground) return;
        foreground = true;
        listener.changed(true);
    }

    private void hide() {
        scheduler.cancel(confirmBackground);
        if (!foreground) return;
        foreground = false;
        listener.changed(false);
    }

    void stopped(Object activity, boolean changingConfigurations) {
        resumed.remove(activity);
        if (!started.remove(activity)) return;
        if (foreground && started.isEmpty() && !changingConfigurations) {
            scheduler.cancel(confirmBackground);
            scheduler.postDelayed(confirmBackground, BACKGROUND_DELAY_MS);
        }
    }

    boolean isForeground() {
        return foreground;
    }
}
