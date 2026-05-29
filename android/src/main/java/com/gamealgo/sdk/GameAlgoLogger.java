package com.gamealgo.sdk;

public interface GameAlgoLogger {
    void log(String message);

    static GameAlgoLogger console() {
        return message -> System.out.println(message);
    }
}
