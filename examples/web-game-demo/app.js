const SDK_VERSION = "web-demo-1.0.0";
const APP_VERSION = "0.1.0";
const BOARD_SIZE = 25;
const LEVEL_SECONDS = 30;
const TARGET_SCORE = 100;
const STORAGE_PREFIX = "gamealgo.webDemo.";

const elements = {
  baseUrlInput: document.getElementById("baseUrlInput"),
  gameKeyInput: document.getElementById("gameKeyInput"),
  userIdInput: document.getElementById("userIdInput"),
  timezoneInput: document.getElementById("timezoneInput"),
  connectionText: document.getElementById("connectionText"),
  gameIdText: document.getElementById("gameIdText"),
  contextIdText: document.getElementById("contextIdText"),
  userCreatedAtText: document.getElementById("userCreatedAtText"),
  levelText: document.getElementById("levelText"),
  scoreText: document.getElementById("scoreText"),
  timeText: document.getElementById("timeText"),
  board: document.getElementById("board"),
  eventLog: document.getElementById("eventLog"),
  connectButton: document.getElementById("connectButton"),
  startButton: document.getElementById("startButton"),
  adButton: document.getElementById("adButton"),
  purchaseButton: document.getElementById("purchaseButton"),
  sessionEndButton: document.getElementById("sessionEndButton"),
  flushButton: document.getElementById("flushButton"),
};

const state = {
  baseUrl: localStorage.getItem(`${STORAGE_PREFIX}baseUrl`) || "https://game-algo-sdk.dictapis.cn",
  gameKey: localStorage.getItem(`${STORAGE_PREFIX}gameKey`) || "",
  userId: localStorage.getItem(`${STORAGE_PREFIX}userId`) || `web-demo-user-${crypto.randomUUID()}`,
  userCreatedAt: localStorage.getItem(`${STORAGE_PREFIX}userCreatedAt`) || new Date().toISOString(),
  sessionId: `web-demo-session-${crypto.randomUUID()}`,
  timezone: localStorage.getItem(`${STORAGE_PREFIX}timezone`) || Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
  contextId: "",
  gameId: "",
  configVersion: "",
  eventQueue: [],
  sessionStartedAt: Date.now(),
  sessionEnded: false,
  levelNo: 1,
  score: 0,
  moves: 0,
  activeTile: -1,
  bonusTile: -1,
  levelStartedAt: 0,
  remainingSeconds: LEVEL_SECONDS,
  timer: undefined,
  running: false,
};

function init() {
  elements.baseUrlInput.value = state.baseUrl;
  elements.gameKeyInput.value = state.gameKey;
  elements.userIdInput.value = state.userId;
  elements.timezoneInput.value = state.timezone;
  localStorage.setItem(`${STORAGE_PREFIX}userId`, state.userId);
  localStorage.setItem(`${STORAGE_PREFIX}userCreatedAt`, state.userCreatedAt);

  buildBoard();
  render();

  elements.connectButton.addEventListener("click", () => connectSdk());
  elements.startButton.addEventListener("click", () => startLevel());
  elements.adButton.addEventListener("click", () => rewardAd());
  elements.purchaseButton.addEventListener("click", () => purchasePack());
  elements.sessionEndButton.addEventListener("click", () => endSession("manual_button"));
  elements.flushButton.addEventListener("click", () => flushEvents());
  window.addEventListener("beforeunload", () => {
    if (state.contextId && !state.sessionEnded) {
      void endSession("page_close", true);
    }
  });
}

function buildBoard() {
  elements.board.textContent = "";
  for (let index = 0; index < BOARD_SIZE; index += 1) {
    const tile = document.createElement("button");
    tile.type = "button";
    tile.className = "tile";
    tile.setAttribute("aria-label", `Tile ${index + 1}`);
    tile.addEventListener("click", () => tapTile(index));
    elements.board.append(tile);
  }
}

async function connectSdk() {
  state.baseUrl = normalizeBaseUrl(elements.baseUrlInput.value);
  state.gameKey = elements.gameKeyInput.value.trim();
  state.userId = elements.userIdInput.value.trim() || state.userId;
  state.timezone = elements.timezoneInput.value.trim() || state.timezone;
  if (state.sessionEnded) {
    state.sessionId = `web-demo-session-${crypto.randomUUID()}`;
  }
  localStorage.setItem(`${STORAGE_PREFIX}baseUrl`, state.baseUrl);
  localStorage.setItem(`${STORAGE_PREFIX}gameKey`, state.gameKey);
  localStorage.setItem(`${STORAGE_PREFIX}userId`, state.userId);
  localStorage.setItem(`${STORAGE_PREFIX}timezone`, state.timezone);

  if (!state.gameKey) {
    logEvent("config", "game key is required");
    return;
  }

  setConnection("Connecting");
  try {
    const response = await sdkFetch("/v1/config", {
      method: "POST",
      body: JSON.stringify({
        userId: state.userId,
        userCreatedAt: state.userCreatedAt,
        sessionId: state.sessionId,
        platform: "rest",
        sdkVersion: SDK_VERSION,
        appVersion: APP_VERSION,
        timezone: state.timezone,
        device: {
          demo: "web-game-demo",
          locale: navigator.language || "",
          userAgent: navigator.userAgent,
          viewport: `${window.innerWidth}x${window.innerHeight}`,
        },
      }),
    });
    state.contextId = response.contextId;
    state.gameId = response.gameId;
    state.configVersion = response.configVersion;
    state.sessionStartedAt = Date.now();
    state.sessionEnded = false;
    setConnection(`Connected ${response.gameId}`);
    logEvent("config", `context ${shortId(response.contextId)}, version ${response.configVersion}`);
    logExperiments(response.experiments);
    queueEvent("_demo_open", {
      configVersion: response.configVersion,
      experimentCount: Array.isArray(response.experiments) ? response.experiments.length : 0,
      configFileCount: Array.isArray(response.configFiles) ? response.configFiles.length : 0,
    });
    await flushEvents();
  } catch (error) {
    setConnection("Connection failed");
    logEvent("config", error.message || String(error));
  } finally {
    render();
  }
}

function startLevel() {
  if (!state.contextId || state.running || state.sessionEnded) return;
  state.running = true;
  state.score = 0;
  state.moves = 0;
  state.remainingSeconds = LEVEL_SECONDS;
  state.levelStartedAt = Date.now();
  pickTiles();
  queueEvent("level_start", {
    levelId: `demo-level-${state.levelNo}`,
    levelNo: state.levelNo,
    targetScore: TARGET_SCORE,
    timeLimitSec: LEVEL_SECONDS,
  });
  logEvent("level_start", `level ${state.levelNo}`);
  state.timer = window.setInterval(tick, 1000);
  render();
}

function tick() {
  state.remainingSeconds -= 1;
  if (state.remainingSeconds <= 0) {
    endLevel(false, "timeout");
    return;
  }
  render();
}

function tapTile(index) {
  if (!state.running) return;
  state.moves += 1;
  let delta = -2;
  let hit = "miss";
  if (index === state.activeTile) {
    delta = 10;
    hit = "target";
  } else if (index === state.bonusTile) {
    delta = 20;
    hit = "bonus";
  }
  state.score = Math.max(0, state.score + delta);
  queueEvent("_tile_tap", {
    levelNo: state.levelNo,
    tileIndex: index,
    hit,
    score: state.score,
    moveNo: state.moves,
  });
  pickTiles(index);
  if (state.score >= TARGET_SCORE) {
    endLevel(true, "target_score");
    return;
  }
  render();
}

function pickTiles(previous = -1) {
  state.activeTile = randomTile(previous);
  state.bonusTile = Math.random() < 0.28 ? randomTile(state.activeTile) : -1;
}

function randomTile(excluded) {
  let value = Math.floor(Math.random() * BOARD_SIZE);
  while (value === excluded) value = Math.floor(Math.random() * BOARD_SIZE);
  return value;
}

function endLevel(success, reason) {
  if (!state.running) return;
  state.running = false;
  if (state.timer) window.clearInterval(state.timer);
  state.timer = undefined;
  const durationMs = Date.now() - state.levelStartedAt;
  queueEvent("level_end", {
    levelId: `demo-level-${state.levelNo}`,
    levelNo: state.levelNo,
    success,
    reason,
    score: state.score,
    moves: state.moves,
    durationMs,
    targetScore: TARGET_SCORE,
    remainingSec: state.remainingSeconds,
  });
  logEvent("level_end", `level ${state.levelNo}, score ${state.score}`);
  if (success) state.levelNo += 1;
  state.activeTile = -1;
  state.bonusTile = -1;
  void flushEvents();
  render();
}

async function rewardAd() {
  if (!state.contextId || state.sessionEnded) return;
  queueEvent("ad_view", {
    placement: "rewarded_after_level",
    adType: "reward",
    revenue: 0.018,
    currency: "USD",
    network: "demo_network",
    levelNo: state.levelNo,
  });
  logEvent("ad_view", "rewarded_after_level");
  await flushEvents();
}

async function purchasePack() {
  if (!state.contextId || state.sessionEnded) return;
  queueEvent("purchase", {
    productId: "demo_starter_pack",
    revenue: 4.99,
    currency: "USD",
    levelNo: state.levelNo,
  });
  logEvent("purchase", "demo_starter_pack");
  await flushEvents();
}

async function endSession(reason, keepalive = false) {
  if (!state.contextId || state.sessionEnded) return;
  if (state.running) {
    queueCurrentLevelEnd(false, "session_end");
  }
  state.sessionEnded = true;
  queueEvent("session_end", {
    sessionDurationMs: Date.now() - state.sessionStartedAt,
    reason,
    levelNo: state.levelNo,
    score: state.score,
  });
  logEvent("session_end", `${reason}, duration ${Date.now() - state.sessionStartedAt}ms`);
  await flushEvents(keepalive);
}

function queueEvent(eventType, payload) {
  if (!state.contextId) return;
  state.eventQueue.push({
    eventId: crypto.randomUUID(),
    contextId: state.contextId,
    userId: state.userId,
    sessionId: state.sessionId,
    eventType,
    timestamp: new Date().toISOString(),
    payload,
  });
  render();
}

function queueCurrentLevelEnd(success, reason) {
  state.running = false;
  if (state.timer) window.clearInterval(state.timer);
  state.timer = undefined;
  const durationMs = state.levelStartedAt ? Date.now() - state.levelStartedAt : 0;
  queueEvent("level_end", {
    levelId: `demo-level-${state.levelNo}`,
    levelNo: state.levelNo,
    success,
    reason,
    score: state.score,
    moves: state.moves,
    durationMs,
    targetScore: TARGET_SCORE,
    remainingSec: state.remainingSeconds,
  });
  state.activeTile = -1;
  state.bonusTile = -1;
}

async function flushEvents(useBeacon = false) {
  if (!state.eventQueue.length || !state.contextId) return;
  const batch = state.eventQueue.splice(0, 100);
  const body = JSON.stringify({ events: batch });
  render();

  try {
    const response = await sdkFetch("/v1/events/batch", { method: "POST", body, keepalive: useBeacon });
    logEvent("flush", `accepted ${response.accepted}`);
  } catch (error) {
    state.eventQueue.unshift(...batch);
    logEvent("flush", error.message || String(error));
  } finally {
    render();
  }
}

async function sdkFetch(path, options = {}) {
  const response = await fetch(`${state.baseUrl}${path}`, {
    ...options,
    headers: {
      "content-type": "application/json",
      "x-gamealgo-key": state.gameKey,
      ...(options.headers || {}),
    },
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : {};
  if (!response.ok) {
    throw new Error(payload.message || payload.error || `HTTP ${response.status}`);
  }
  return payload;
}

function setConnection(text) {
  elements.connectionText.textContent = text;
}

function render() {
  elements.levelText.textContent = String(state.levelNo);
  elements.scoreText.textContent = String(state.score);
  elements.timeText.textContent = String(state.remainingSeconds);
  elements.gameIdText.textContent = state.gameId || "-";
  elements.contextIdText.textContent = state.contextId || "-";
  elements.userCreatedAtText.textContent = state.userCreatedAt || "-";

  elements.startButton.disabled = !state.contextId || state.running || state.sessionEnded;
  elements.adButton.disabled = !state.contextId || state.sessionEnded;
  elements.purchaseButton.disabled = !state.contextId || state.sessionEnded;
  elements.sessionEndButton.disabled = !state.contextId || state.sessionEnded;
  elements.flushButton.disabled = !state.contextId || !state.eventQueue.length;

  [...elements.board.children].forEach((tile, index) => {
    tile.className = "tile";
    if (index === state.activeTile) tile.classList.add("tile--active");
    if (index === state.bonusTile) tile.classList.add("tile--bonus");
    tile.disabled = !state.running;
  });
}

function logExperiments(experiments) {
  const assignments = Array.isArray(experiments) ? experiments.map(normalizeExperiment).filter(Boolean) : [];
  if (!assignments.length) {
    console.info("[GameAlgoDemo] experiments fetched", []);
    logEvent("experiments", "none");
    return;
  }

  console.info("[GameAlgoDemo] experiments fetched", assignments);
  logEvent("experiments", `${assignments.length} assignment(s)`);
  assignments.forEach((assignment) => {
    logEvent("experiment", `${assignment.strategyName}:${assignment.variantName}`);
  });
}

function normalizeExperiment(experiment) {
  if (!experiment || typeof experiment !== "object") return undefined;
  return {
    strategyName: experiment.strategyName || experiment.strategy_name || experiment.strategy || experiment.name || "-",
    variantName: experiment.variantName || experiment.variant_name || experiment.variant || experiment.value || "-",
  };
}

function logEvent(name, detail) {
  const row = document.createElement("div");
  row.innerHTML = `<strong>${escapeHtml(name)}</strong>${escapeHtml(detail)}`;
  elements.eventLog.prepend(row);
  while (elements.eventLog.children.length > 40) {
    elements.eventLog.lastElementChild?.remove();
  }
}

function normalizeBaseUrl(value) {
  const url = new URL(value.trim() || "https://game-algo-sdk.dictapis.cn");
  url.pathname = url.pathname.replace(/\/+$/, "");
  url.search = "";
  url.hash = "";
  return url.toString().replace(/\/+$/, "");
}

function shortId(value) {
  return value ? `${value.slice(0, 8)}...` : "-";
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  })[char]);
}

init();
