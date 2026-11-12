export type CrazyGamesAdType = "rewarded" | "midgame";
export type CrazyGamesAdError = { code: string; message: string };
export type CrazyGamesAdCallbacks = {
  adStarted: () => void;
  adFinished: () => void;
  adError: (error: CrazyGamesAdError) => void;
};

/** Documented HTML5 v3 surface; no login prompts or private bridge methods. */
export type CrazyGamesHost = {
  init(): Promise<void>;
  readonly environment: "local" | "crazygames" | "disabled";
  readonly ad: { requestAd(type: CrazyGamesAdType, callbacks: CrazyGamesAdCallbacks): void | Promise<void> };
  readonly user?: { readonly systemInfo?: {
    countryCode?: string;
    locale?: string;
    device?: { type?: string };
    os?: { name?: string; version?: string };
    browser?: { name?: string; version?: string };
    applicationType?: string;
  } };
};

export function getCrazyGamesHost(value?: CrazyGamesHost): CrazyGamesHost {
  const host = value ?? (globalThis as { CrazyGames?: { SDK?: CrazyGamesHost } }).CrazyGames?.SDK;
  if (!host || typeof host.init !== "function") {
    throw new Error("Load https://sdk.crazygames.com/crazygames-sdk-v3.js before initializing GamePropel");
  }
  return host;
}
