package com.gamealgo.sdk;

import java.io.IOException;

public interface GameAlgoHttpClient {
    GameAlgoHttpResponse send(GameAlgoHttpRequest request) throws IOException;
}
