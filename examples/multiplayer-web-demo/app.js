import { connectRoom, GameAlgoMatchmakingClient } from "../../web/dist/web/src/index.js";
import { DemoProtocol } from "./protocol.js";

const params = new URLSearchParams(location.search);
const controllerHttpUrl = params.get("controller") || "http://127.0.0.1:8795";
const playerId = params.get("player") || `player-${crypto.randomUUID().slice(0, 8)}`;
const sessionId = `session-${crypto.randomUUID()}`;
const elements = Object.fromEntries([...document.querySelectorAll("[id]")].map((element) => [element.id, element]));

let room;
let initialized = false;
let scores = [0, 0];
let tick = 0;
let winner = -1;
let lastInputSequence = [0, 0];

elements.player.textContent = playerId;
setStatus("获取对战凭证");
start().catch((error) => fail(error));

async function start() {
  const tokenResponse = await fetch(`${controllerHttpUrl}/dev/access-token`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ gameId: "counter-duel-demo", userId: playerId, sessionId }),
  });
  if (!tokenResponse.ok) throw new Error(`access token ${tokenResponse.status}`);
  const credentials = await tokenResponse.json();
  setStatus("匹配中");
  const matchmaking = new GameAlgoMatchmakingClient({
    apiBaseUrl: controllerHttpUrl,
    gameKey: "dev",
    controllerUrl: credentials.controllerUrl,
    fetchImpl: fetch.bind(globalThis),
    identity: async () => ({ userId: playerId, sessionId }),
  });
  const match = matchmaking.join({
    accessToken: credentials.accessToken,
    controllerUrl: credentials.controllerUrl,
    queueId: "casual_1v1",
    protocolHash: DemoProtocol.hash,
    canHost: true,
    foreground: true,
    rttMs: Number(params.get("rtt") || Math.floor(Math.random() * 40 + 10)),
    deviceScore: 50,
  });
  const matched = await match.waitForMatched();
  log(`matched room=${matched.roomId} seat=${matched.seat}`);
  setStatus("进入房间");
  room = await connectRoom(matched.relayUrl, matched.ticket, DemoProtocol);
  bindRoom(room);
  renderRole();
  elements.reconnect.disabled = false;
  if (room.isHost && room.phase === "initializing") initializeAsHost();
  window.__gameAlgoMultiplayerDemo = { ready: true, playerId, room, protocolHash: DemoProtocol.hash };
}

function bindRoom(value) {
  value.onInitialized((init) => {
    initialized = true;
    log(`initialized seed=${init.seed} maxScore=${init.maxScore}`);
    value.ready().catch?.((error) => fail(error));
  });
  value.onInput(({ seat, input, sequence }) => {
    if (!value.isHost || winner >= 0) return;
    scores[seat] = Math.min(65535, scores[seat] + Number(input.taps));
    lastInputSequence[seat] = sequence;
    tick += 1;
    if (scores[seat] >= 20) winner = seat;
    publishAuthoritativeState();
    if (winner >= 0) value.sendEvent("winner", { seat: winner });
  });
  value.onState((state) => {
    if (state.sharedState) {
      scores = [...state.sharedState.scores];
      tick = Number(state.sharedState.tick);
      winner = Number(state.sharedState.winner);
      renderScores();
    }
  });
  value.onEvent((event) => {
    if (event.type === "winner") setStatus(`Seat ${event.payload.seat} 获胜`);
  });
  value.onPeerChanged((event) => {
    log(`${event.type} seat=${event.seat}`);
  });
  value.onPhase(({ phase }) => {
    log(`phase=${phase}`);
    if (phase === "initializing" && value.isHost) initializeAsHost();
    if (phase === "active") {
      elements.tap.disabled = false;
      setStatus("对战中");
      if (value.isHost) publishAuthoritativeState();
    }
    if (phase === "host_grace" || phase === "migrating") elements.tap.disabled = true;
  });
  value.onPaused(({ reason }) => { elements.tap.disabled = true; setStatus("房间暂停"); log(`paused: ${reason}`); });
  value.onResumed(() => { elements.tap.disabled = false; setStatus("对战中"); log("room resumed"); renderRole(); });
  value.onBecomeHost((hostState) => {
    log("became host");
    if (hostState) {
      scores = [...hostState.scores];
      tick = Number(hostState.tick);
      winner = Number(hostState.winner);
      publishAuthoritativeState();
    } else {
      initializeAsHost();
    }
    renderRole();
  });
  value.onClosed(({ reason }) => { elements.tap.disabled = true; setStatus("房间已关闭"); log(`closed: ${reason}`); });
  value.onError((error) => log(`error: ${error.message}`));

  const input = value.createInputQueue({
    intervalMs: 50,
    aggregate(values) {
      return { taps: Math.min(255, values.reduce((sum, item) => sum + Number(item.taps || 0), 0)) };
    },
    onError: (error) => log(`input error: ${error.message}`),
  });
  elements.tap.addEventListener("click", () => input.push({ taps: 1 }));
  elements.migrate.addEventListener("click", () => value.yieldHost());
  elements.reconnect.addEventListener("click", () => {
    log("forcing reconnect");
    value.disconnect({ reconnect: true, reason: "demo_reconnect" });
  });
}

function initializeAsHost() {
  if (!room?.isHost || initialized) return;
  initialized = true;
  room.initialize({ seed: Math.floor(Math.random() * 0xffffffff), maxScore: 20 }).catch((error) => {
    initialized = false;
    log(`initialize retry: ${error.message}`);
    setTimeout(initializeAsHost, 100);
  });
}

function publishAuthoritativeState() {
  if (!room?.isHost) return;
  const sharedState = { tick, scores, winner };
  room.publishState({
    sharedState,
    seatStates: {
      0: { ownScore: scores[0], lastProcessedInputSeq: lastInputSequence[0] },
      1: { ownScore: scores[1], lastProcessedInputSeq: lastInputSequence[1] },
    },
  });
  room.commitHostState(sharedState);
  renderScores();
}

function renderRole() {
  if (!room) return;
  elements.seat.textContent = String(room.seat);
  elements.role.textContent = room.isHost ? "房主" : "玩家";
  elements.epoch.textContent = String(room.hostEpoch);
  elements.migrate.disabled = !room.isHost;
  document.querySelector(`#player-${room.seat}`)?.classList.add("mine");
  setStatus(room.phase === "active" ? "对战中" : "等待房间就绪");
}

function renderScores() {
  elements["score-0"].textContent = String(scores[0]);
  elements["score-1"].textContent = String(scores[1]);
  if (winner >= 0) setStatus(`Seat ${winner} 获胜`);
}

function setStatus(value) { elements.status.textContent = value; }
function log(value) {
  elements.log.textContent = `${new Date().toLocaleTimeString()} ${value}\n${elements.log.textContent}`.slice(0, 5000);
}
function fail(error) {
  const message = error instanceof Error ? error.message : String(error);
  setStatus("连接失败");
  log(message);
  window.__gameAlgoMultiplayerDemo = { ready: false, error: message };
}
