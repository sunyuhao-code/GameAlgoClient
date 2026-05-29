package com.gamealgo.sdk;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

public final class GameAlgoFileCacheStorage implements GameAlgoCacheStorage {
    private final File directory;

    public GameAlgoFileCacheStorage(File directory) {
        this.directory = directory;
    }

    @Override
    public String getItem(String key) throws GameAlgoException {
        File file = fileForKey(key);
        if (!file.exists()) {
            return null;
        }
        try {
            return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new GameAlgoException("Failed to read cache: " + error.getMessage(), error);
        }
    }

    @Override
    public void setItem(String key, String value) throws GameAlgoException {
        if (!directory.exists() && !directory.mkdirs()) {
            throw new GameAlgoException("Failed to create cache directory");
        }
        try {
            Files.write(fileForKey(key).toPath(), value.getBytes(StandardCharsets.UTF_8));
        } catch (IOException error) {
            throw new GameAlgoException("Failed to write cache: " + error.getMessage(), error);
        }
    }

    @Override
    public void removeItem(String key) throws GameAlgoException {
        File file = fileForKey(key);
        if (file.exists() && !file.delete()) {
            throw new GameAlgoException("Failed to delete cache");
        }
    }

    private File fileForKey(String key) {
        return new File(directory, Integer.toHexString(key.hashCode()) + ".json");
    }
}
