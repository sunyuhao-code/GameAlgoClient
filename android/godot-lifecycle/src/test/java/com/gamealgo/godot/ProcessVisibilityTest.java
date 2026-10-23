package com.gamealgo.godot;

import org.junit.Test;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import static org.junit.Assert.*;

public class ProcessVisibilityTest {
    private static final class Clock implements ProcessVisibility.Scheduler {
        Runnable pending;
        long delay;
        public void postDelayed(Runnable task, long delayMs) { pending = task; delay = delayMs; }
        public void cancel(Runnable task) { if (pending == task) pending = null; }
        void advance() {
            Runnable task = pending;
            pending = null;
            if (task != null) task.run();
        }
    }

    @Test public void adActivityStaysForegroundAndHomeEndsAfter100ms() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object(), ad = new Object();
        state.started(game);
        state.started(ad);
        state.stopped(game, false);
        clock.advance();
        assertEquals(Arrays.asList(true), changes);
        state.stopped(ad, false);
        assertEquals(100L, clock.delay);
        assertTrue(state.isForeground());
        clock.advance();
        assertEquals(Arrays.asList(true, false), changes);
    }

    @Test public void shortActivityGapAndRotationDoNotEndSession() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object(), ad = new Object(), rotated = new Object();
        state.started(game);
        state.stopped(game, false);
        state.started(ad);
        clock.advance();
        state.stopped(ad, true);
        clock.advance();
        state.started(rotated);
        assertEquals(Arrays.asList(true), changes);
        state.stopped(rotated, false);
        clock.advance();
        assertEquals(Arrays.asList(true, false), changes);
    }

    @Test public void everyRealBackgroundTransitionCanReportAgain() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object();
        for (int i = 0; i < 2; i++) {
            state.started(game);
            state.started(game);
            state.stopped(new Object(), false);
            assertNull(clock.pending);
            state.stopped(game, false);
            clock.advance();
        }
        assertEquals(Arrays.asList(true, false, true, false), changes);
    }

    @Test public void uiHiddenEndsImmediatelyWithoutWaitingForActivityStop() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object();
        state.started(game);
        state.resumed(game, true);
        state.uiHidden();
        assertFalse(state.isForeground());
        assertNull(clock.pending);
        state.uiHidden();
        state.screenOff();
        state.stopped(game, false);
        clock.advance();
        assertEquals(Arrays.asList(true, false), changes);
    }

    @Test public void resumeRecoversFromUiHiddenWithoutAnotherStartedCallback() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object();
        state.started(game);
        state.resumed(game, true);
        state.uiHidden();
        state.started(new Object());
        state.screenOn(true);
        assertFalse(state.isForeground());
        state.resumed(game, true);
        state.uiHidden();
        assertEquals(Arrays.asList(true, false, true, false), changes);
    }

    @Test public void screenOffCancelsPendingStopAndBlocksForegroundWhileNonInteractive() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object(), ad = new Object();
        state.started(game);
        state.resumed(game, true);
        state.paused(game);
        state.stopped(game, false);
        assertNotNull(clock.pending);
        state.screenOff();
        assertNull(clock.pending);
        assertFalse(state.isForeground());
        state.started(ad);
        state.resumed(ad, false);
        clock.advance();
        assertEquals(Arrays.asList(true, false), changes);
        state.resumed(ad, true);
        state.screenOff();
        assertEquals(Arrays.asList(true, false, true, false), changes);
    }

    @Test public void wakingToLockScreenDoesNotForegroundPausedApp() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object();
        state.started(game);
        state.resumed(game, true);
        state.paused(game);
        state.screenOff();
        state.screenOn(true);
        assertFalse(state.isForeground());
        state.resumed(game, true);
        assertEquals(Arrays.asList(true, false, true), changes);
    }

    @Test public void screenOnRecoversActivityThatStayedResumed() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object();
        state.started(game);
        state.resumed(game, true);
        state.screenOff();
        state.screenOn(false);
        assertFalse(state.isForeground());
        state.screenOn(true);
        state.screenOn(true);
        assertEquals(Arrays.asList(true, false, true), changes);
    }

    @Test public void normalAdPauseAndResumeStillKeepWholeProcessForeground() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object(), ad = new Object();
        state.started(game);
        state.resumed(game, true);
        state.paused(game);
        state.stopped(game, false);
        state.started(ad);
        state.resumed(ad, true);
        clock.advance();
        state.paused(ad);
        state.stopped(ad, false);
        state.started(game);
        state.resumed(game, true);
        clock.advance();
        assertEquals(Arrays.asList(true), changes);
    }

    @Test public void sdkInitializedWhileScreenOffWaitsForInteractiveResume() {
        Clock clock = new Clock();
        List<Boolean> changes = new ArrayList<>();
        ProcessVisibility state = new ProcessVisibility(clock, changes::add);
        Object game = new Object();
        state.screenOff();
        state.started(game);
        state.resumed(game, false);
        state.paused(game);
        state.screenOn(true);
        assertTrue(changes.isEmpty());
        state.resumed(game, true);
        assertEquals(Arrays.asList(true), changes);
    }
}
