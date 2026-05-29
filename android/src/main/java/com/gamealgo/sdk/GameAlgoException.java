package com.gamealgo.sdk;

public class GameAlgoException extends Exception {
    private final Integer statusCode;
    private final String code;

    public GameAlgoException(String message) {
        super(message);
        this.statusCode = null;
        this.code = null;
    }

    public GameAlgoException(String message, Throwable cause) {
        super(message, cause);
        this.statusCode = null;
        this.code = null;
    }

    public GameAlgoException(int statusCode, String code, String message) {
        super(message);
        this.statusCode = statusCode;
        this.code = code;
    }

    public Integer getStatusCode() {
        return statusCode;
    }

    public String getCode() {
        return code;
    }
}
