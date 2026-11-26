import { parseHttpBaseUrl } from "../../rest-api/src/http-url.ts";
import { sha256HexSync } from "../../rest-api/src/sha256.ts";
import type { GameAlgoWechatStorage } from "./storage.ts";

/** Inspect before the core persists a first-install anonymous candidate. */
export function isNewWechatIdentity(storage: GameAlgoWechatStorage, baseUrl: string, gameKey: string, explicitUserId?: string): boolean {
  if (explicitUserId?.trim()) return false;
  const base = parseHttpBaseUrl(baseUrl);
  const key = `gamealgo:v1:identity:${base.origin}${base.pathname.replace(/\/+$/, "")}:${sha256HexSync(gameKey)}:user-id`;
  try {
    return !storage.getItem(key)?.trim() && !storage.getItem("gamealgo_user_id")?.trim();
  } catch {
    // An unreadable existing identity must never be treated as a new player.
    // The core restore will surface the actual I/O failure.
    return false;
  }
}
