package com.gamealgo.sdk;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

public final class GameAlgoFileCacheStorage implements GameAlgoJournalStorage {
    private final File directory;

    public GameAlgoFileCacheStorage(File directory) {
        this.directory = directory;
    }

    @Override
    public synchronized String getItem(String key) throws GameAlgoException {
        File file = fileForKey(key);
        if (!file.exists()) {
            return null;
        }
        return readFile(file);
    }

    private String readFile(File file) throws GameAlgoException {
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
    public synchronized void setItem(String key, String value) throws GameAlgoException {
        writeFile(fileForKey(key), value);
    }

    private void writeFile(File target, String value) throws GameAlgoException {
        File parent = target.getParentFile();
        if (!parent.exists() && !parent.mkdirs()) {
            throw new GameAlgoException("Failed to create cache directory");
        }
        File temporary = new File(parent, target.getName() + ".tmp." + java.util.UUID.randomUUID());
        try (FileOutputStream output = new FileOutputStream(temporary)) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
            // Android's same-filesystem rename replaces the destination atomically.
            // Never delete the last committed file before its replacement exists.
            if (!temporary.renameTo(target)) {
                throw new IOException("Failed to commit cache file");
            }
        } catch (IOException error) {
            if (temporary.exists()) {
                temporary.delete();
            }
            throw new GameAlgoException("Failed to write cache: " + error.getMessage(), error);
        }
    }

    private File journalDirectory(String key) { return new File(directory, fileForKey(key).getName() + ".journal"); }

    @Override public synchronized java.util.List<String> readJournalRecords(String key) throws GameAlgoException {
        File journal = journalDirectory(key);
        File[] files = journal.listFiles((dir, name) -> name.endsWith(".json"));
        java.util.List<String> records = new java.util.ArrayList<>();
        if (files == null) {
            if (journal.exists()) throw new GameAlgoException("Failed to list journal");
            return records;
        }
        java.util.Arrays.sort(files, java.util.Comparator.comparing(File::getName));
        for (File file : files) records.add(readFile(file));
        return records;
    }

    @Override public synchronized void appendJournalRecord(String key, long sequence, String value) throws GameAlgoException {
        writeFile(new File(journalDirectory(key), String.format(java.util.Locale.US, "%020d.json", sequence)), value);
    }

    @Override public synchronized void compactJournal(String key, String value) throws GameAlgoException {
        setItem(key, value);
        File directory = journalDirectory(key);
        File retired = new File(this.directory, directory.getName() + ".retired." + java.util.UUID.randomUUID());
        if (directory.renameTo(retired)) {
            Thread cleanup = new Thread(() -> deleteTree(retired), "GameAlgoJournalCleanup");
            cleanup.setDaemon(true);
            cleanup.start();
        }
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }

    @Override
    public synchronized void removeItem(String key) throws GameAlgoException {
        File file = fileForKey(key);
        if (file.exists() && !file.delete()) {
            throw new GameAlgoException("Failed to delete cache");
        }
        File journal = journalDirectory(key);
        deleteTree(journal);
        if (journal.exists()) throw new GameAlgoException("Failed to delete journal");
        File[] retired = directory.listFiles((dir, name) -> name.startsWith(journal.getName() + ".retired."));
        if (retired != null) for (File old : retired) {
            deleteTree(old);
            if (old.exists()) throw new GameAlgoException("Failed to delete retired journal");
        }
    }

    private File fileForKey(String key) {
        return new File(directory, Integer.toHexString(key.hashCode()) + ".json");
    }
}
