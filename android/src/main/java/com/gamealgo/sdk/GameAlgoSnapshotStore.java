package com.gamealgo.sdk;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

final class GameAlgoSnapshotStore {
    private final AtomicReference<GameAlgoSnapshot> current = new AtomicReference<>(new GameAlgoSnapshot());

    GameAlgoSnapshot snapshot() {
        return current.get();
    }

    void replace(GameAlgoSnapshot snapshot) {
        current.set(snapshot);
    }

    void updateConfig(GameAlgoConfigResponse config, long updatedAtMillis, String userId) {
        GameAlgoSnapshot previous = current.get();
        current.set(new GameAlgoSnapshot(config, previous.getConfigFiles(), updatedAtMillis, userId));
    }

    void updateConfigFile(GameAlgoConfigFile file, long updatedAtMillis) {
        GameAlgoSnapshot previous = current.get();
        Map<String, GameAlgoConfigFile> files = new LinkedHashMap<>(previous.getConfigFiles());
        files.put(file.getName(), file);
        current.set(new GameAlgoSnapshot(previous.getConfig(), files, updatedAtMillis, previous.getUserId()));
    }
}
