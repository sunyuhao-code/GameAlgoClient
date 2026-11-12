import type { RewardVideoHost } from "../../rest-api/src/reward-video-ad.ts";

export type DouyinNetworkStatus = { isConnected: boolean; networkType?: string };
export type DouyinHost = {
  request(options: {
    url: string;
    method: "GET" | "POST";
    data: Record<string, unknown> | unknown[];
    header?: Record<string, string>;
    timeout: number;
    dataType: "string";
    success(result: { statusCode: number; data: unknown; header?: Record<string, unknown> }): void;
    fail(error: unknown): void;
  }): { abort?: () => void } | void;
  getStorageSync(key: string): unknown;
  setStorageSync(key: string, value: string): void;
  removeStorageSync(key: string): void;
  getSystemInfoSync?: () => { platform?: string; system?: string; brand?: string; model?: string;
    version?: string; appName?: string; SDKVersion?: string };
  getEnvInfoSync?: () => { microapp?: { appId?: string; mpVersion?: string; envType?: string } };
  onHide?: (callback: () => void) => void;
  offHide?: (callback: () => void) => void;
  onShow?: (callback: () => void) => void;
  offShow?: (callback: () => void) => void;
  onNetworkStatusChange?: (callback: (status: DouyinNetworkStatus) => void) => void;
  offNetworkStatusChange?: (callback: (status: DouyinNetworkStatus) => void) => void;
  createRewardedVideoAd?: RewardVideoHost["createRewardedVideoAd"];
};

export function getDouyinHost(explicit?: DouyinHost): DouyinHost {
  const host = explicit ?? (globalThis as { tt?: DouyinHost }).tt;
  if (!host || typeof host.request !== "function" || typeof host.getStorageSync !== "function"
    || typeof host.setStorageSync !== "function" || typeof host.removeStorageSync !== "function") {
    throw new Error("GamePropel Douyin SDK requires native tt request and local-storage APIs");
  }
  return host;
}
