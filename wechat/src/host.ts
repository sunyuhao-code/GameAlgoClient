import type { RewardVideoHost } from "../../rest-api/src/reward-video-ad.ts";

export type WechatRequestResult = { statusCode: number; data: unknown; header?: Record<string, unknown> };
export type WechatNetworkStatus = { isConnected: boolean; networkType?: string };
export type WechatHost = {
  request(options: {
    url: string;
    method: "GET" | "POST";
    data?: string;
    header?: Record<string, string>;
    timeout: number;
    dataType: "text";
    responseType: "text";
    success(result: WechatRequestResult): void;
    fail(error: unknown): void;
  }): { abort?: () => void } | void;
  getStorageSync(key: string): unknown;
  setStorageSync(key: string, value: string): void;
  removeStorageSync(key: string): void;
  getDeviceInfo?: () => { platform?: string; system?: string; brand?: string; model?: string };
  getAppBaseInfo?: () => { version?: string; SDKVersion?: string; language?: string };
  getAccountInfoSync?: () => { miniProgram?: { appId?: string; version?: string; envVersion?: string } };
  onHide?: (callback: () => void) => void;
  offHide?: (callback: () => void) => void;
  onShow?: (callback: () => void) => void;
  offShow?: (callback: () => void) => void;
  onNetworkStatusChange?: (callback: (result: WechatNetworkStatus) => void) => void;
  offNetworkStatusChange?: (callback: (result: WechatNetworkStatus) => void) => void;
  createRewardedVideoAd?: RewardVideoHost["createRewardedVideoAd"];
};

export function getWechatHost(explicit?: WechatHost): WechatHost {
  const host = explicit ?? (globalThis as { wx?: WechatHost }).wx;
  if (!host || typeof host.request !== "function" || typeof host.getStorageSync !== "function"
    || typeof host.setStorageSync !== "function" || typeof host.removeStorageSync !== "function") {
    throw new Error("GameAlgo WeChat SDK requires the wx request and local-storage APIs");
  }
  return host;
}
