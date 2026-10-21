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
    private final Scheduler scheduler;
    private final Listener listener;
    private boolean foreground;
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
        if (!foreground) {
            foreground = true;
            listener.changed(true);
        }
    }

    void stopped(Object activity, boolean changingConfigurations) {
        if (!started.remove(activity)) return;
        if (started.isEmpty() && !changingConfigurations) {
            scheduler.cancel(confirmBackground);
            scheduler.postDelayed(confirmBackground, BACKGROUND_DELAY_MS);
        }
    }

    boolean isForeground() {
        return foreground;
    }
}
