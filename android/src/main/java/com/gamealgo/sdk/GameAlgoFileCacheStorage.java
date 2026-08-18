package com.gamealgo.sdk;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

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
        try (InputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            return new String(output.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new GameAlgoException("Failed to read cache: " + error.getMessage(), error);
        }
    }

    @Override
    public void setItem(String key, String value) throws GameAlgoException {
        if (!directory.exists() && !directory.mkdirs()) {
            throw new GameAlgoException("Failed to create cache directory");
        }
        try (OutputStream output = new FileOutputStream(fileForKey(key))) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
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
