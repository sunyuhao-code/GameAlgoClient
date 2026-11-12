import { GamePropelCrazyGamesClient } from "/sdk.js";

const output = document.querySelector("#logs"), status = document.querySelector("#status");
const entries = [];
const log = (event, details = {}) => {
  const row = { utc: new Date().toISOString(), event, details };
  entries.push(row); if (entries.length > 100) entries.shift();
  output.textContent = [...entries].reverse().map(value => JSON.stringify(value)).join("\n");
  void fetch("/probe/log", { method: "POST", body: JSON.stringify(row) }).catch(() => undefined);
};
let offline = false;
try {
  offline = Boolean((await (await fetch("/probe/state")).json()).offline);
  document.querySelector("#offline").textContent = `模拟上报失败：${offline ? "开" : "关"}`;
  const client = await GamePropelCrazyGamesClient.init({ baseUrl: `${location.origin}/algo_sdk`, gameKey: "ga_live_local_probe_fixture",
    eventFlushIntervalMs: 5000, logger: message => log("sdk", { message }) });
  const ready = await client.waitForReady();
  const identity = await client.userIdentity();
  log("ready", { ready, userId: identity.userId, sessionId: client.tracker.currentSessionId(), environment: CrazyGames.SDK.environment,
    parameter: client.executor("difficulty").number("difficulty", 1), systemInfo: CrazyGames.SDK.user.systemInfo });
  status.textContent = `SDK ${ready ? "就绪" : "未就绪"} · 环境 ${CrazyGames.SDK.environment} · 当前 session ${client.tracker.currentSessionId()}`;
  setInterval(() => { document.querySelector("#clock").textContent = `累计前台：${client.getForegroundTimeMs()} ms · 页面：${document.visibilityState}`; }, 1000);
  const placement = "gap_0123456789abcdef0123456789abcdef";
  document.querySelector("#level").onclick = () => { log("level", { queued: client.tracker.trackLevelStart({ levelId: "local-probe" }) }); };
  for (const type of ["rewarded", "midgame"]) {
    const ad = client.createAdSpace({ adType: type });
    document.querySelector(`#${type}`).onclick = async () => {
      log("ad_request", { type });
      try { await ad.show(placement, { onStarted: () => log("ad_started", { type }), onFinished: () => log("ad_finished", { type }), onError: error => log("ad_error", { type, ...error }) }); }
      catch (error) { log("ad_rejected", { code: error.code, message: error.message }); }
    };
  }
  document.querySelector("#snapshot").onclick = async () => {
    client.tracker.trackSessionEndSnapshot({ reason: "probe_manual" });
    try { await client.flush(); log("session_snapshot"); }
    catch (error) { log("session_snapshot_pending", { message: error.message }); }
  };
  document.querySelector("#newSession").onclick = async () => {
    const old = client.tracker.currentSessionId(); client.tracker.newSession(); await client.refresh({ forceRefresh: true });
    status.textContent = `SDK 就绪 · 环境 ${CrazyGames.SDK.environment} · 当前 session ${client.tracker.currentSessionId()}`;
    log("new_session", { old, current: client.tracker.currentSessionId() });
  };
  document.querySelector("#offline").onclick = async event => {
    offline = !offline; await fetch("/probe/network", { method: "POST", body: JSON.stringify({ offline }) });
    event.target.textContent = `模拟上报失败：${offline ? "开" : "关"}`;
    log("upload_failure", { enabled: offline });
    if (!offline) { await client.flush(); log("recovered_flush"); }
  };
  for (const event of ["visibilitychange"]) document.addEventListener(event, () => log(event, { visibility: document.visibilityState, sessionId: client.tracker.currentSessionId() }));
  for (const event of ["pagehide", "pageshow"]) window.addEventListener(event, () => log(event, { sessionId: client.tracker.currentSessionId() }));
} catch (error) { status.textContent = "初始化失败"; log("error", { message: error.message, stack: error.stack }); }
document.querySelector("#reload").onclick = () => location.reload();
document.querySelector("#clear").onclick = () => { entries.length = 0; output.textContent = ""; };
