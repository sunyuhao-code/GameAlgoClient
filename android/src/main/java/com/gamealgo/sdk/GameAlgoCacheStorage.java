package com.gamealgo.sdk;

public interface GameAlgoCacheStorage {
    String getItem(String key) throws GameAlgoException;
    void setItem(String key, String value) throws GameAlgoException;
    void removeItem(String key) throws GameAlgoException;
}
