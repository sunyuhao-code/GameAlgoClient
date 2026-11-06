package com.gamealgo.sdk;

public interface GameAlgoCacheStorage {
    String getItem(String key) throws GameAlgoException;
    void setItem(String key, String value) throws GameAlgoException;
    void removeItem(String key) throws GameAlgoException;
}

/** Optional internal capability: atomically committed incremental records. */
interface GameAlgoJournalStorage extends GameAlgoCacheStorage {
    java.util.List<String> readJournalRecords(String key) throws GameAlgoException;
    void appendJournalRecord(String key, long sequence, String value) throws GameAlgoException;
    void compactJournal(String key, String value) throws GameAlgoException;
}
