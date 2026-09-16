import { GameAlgoWebClient } from "../../dist/web/src/index.js";

declare global {
  interface Window {
    __gameAlgoE2E?: {
      ready: boolean;
      userId: string;
      execution?: unknown;
      ddaDecision?: unknown;
      error?: string;
    };
  }
}

async function run(): Promise<void> {
  const client = GameAlgoWebClient.init({
    baseUrl: location.origin,
    gameKey: "ga_live_browser_e2e",
    appVersion: "e2e",
    experimentIntegrationVersion: 1,
    eventFlushIntervalMs: 0,
    autoUrlAttribution: true,
  });
  try {
    const ready = await client.waitForReady(10_000);
    if (!ready) throw new Error("SDK did not become ready");
    const identity = await client.userIdentity();
    const execution = await client.executor("browser_strategy").execute({ level: 7 });
    const dda = client.dda("browser_strategy", { recentWindowSize: 3 });
    await dda.recordBehavior("fail", 2);
    await dda.completeStep("level-7");
    const ddaDecision = await dda.decide({ level: 8 });
    client.tracker.track("milestone", {
      milestoneType: "new_user",
      milestonePoint: "进入 H5",
    });
    client.tracker.trackAd("level_end", "reward", 0.01, "CNY", "web-test");
    await client.flush();
    window.dispatchEvent(new PageTransitionEvent("pagehide", { persisted: true }));
    await delay(100);
    window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }));
    await delay(100);
    window.__gameAlgoE2E = { ready, userId: identity.userId, execution, ddaDecision };
  } catch (error) {
    window.__gameAlgoE2E = {
      ready: false,
      userId: "",
      error: error instanceof Error ? error.stack ?? error.message : String(error),
    };
  } finally {
    client.close();
  }
  await reportWebViewResult();
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function reportWebViewResult(): Promise<void> {
  const params = new URLSearchParams(location.search);
  if (params.get("webview_e2e") !== "1" || !window.__gameAlgoE2E) return;
  await fetch("/__webview-result", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(window.__gameAlgoE2E),
  });
  if (sessionStorage.getItem("gamealgo.webviewE2E.reloaded") !== "1") {
    sessionStorage.setItem("gamealgo.webviewE2E.reloaded", "1");
    location.reload();
  }
}

void run();
