package com.gamepropel.unity;

/** JNI callback. Unity retains the proxy and dispatches replies on its main thread. */
public interface GamePropelCallback {
    void onResult(String json);
}
