import { GameAlgoBrowserStorage, type GameAlgoBrowserStorageOptions } from "../../rest-api/src/browser-storage.ts";

export type GamePropelCrazyGamesStorageOptions = Pick<GameAlgoBrowserStorageOptions, "indexedDB" | "logger">;

/** Device-local telemetry, isolated from the portal's game-progress Data Module. */
export class GamePropelCrazyGamesStorage {
  private readonly storage: GameAlgoBrowserStorage;
  constructor(options: GamePropelCrazyGamesStorageOptions = {}) {
    this.storage = new GameAlgoBrowserStorage({ ...options,
      databaseName: "gamepropel-crazygames", storeName: "telemetry", localStorage: null });
  }
  getItem(key: string): Promise<string | undefined> { return this.storage.getItemDurably(key); }
  setItem(key: string, value: string): Promise<void> { return this.storage.setItemDurably(key, value); }
  removeItem(key: string): Promise<void> { return this.storage.removeItemDurably(key); }
}
