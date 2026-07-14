import type {
  GameAlgoDDAAdjustment,
  GameAlgoDDADecision,
  GameAlgoDDAOptions,
  GameAlgoDDAScriptState,
  GameAlgoExecutionResult,
  GameAlgoStorage,
  JsonValue,
} from "./types.ts";

type BehaviorCounts = Record<string, number>;

type StoredStep = {
  stepId?: string;
  behaviors: BehaviorCounts;
};

type StoredState = {
  schemaVersion: 1;
  current: BehaviorCounts;
  lifetime: BehaviorCounts;
  recentSteps: StoredStep[];
  completedSteps: number;
};

type DDAExecutor = {
  execute(state: JsonValue): Promise<GameAlgoExecutionResult | undefined>;
};

const DEFAULT_WINDOW_SIZE = 10;

export class GameAlgoDDAController {
  private readonly executor: DDAExecutor;
  private readonly storage?: GameAlgoStorage;
  private readonly storageKey: string;
  private readonly recentWindowSize: number;
  private readonly logger?: (message: string) => void;
  private readonly statePromise: Promise<StoredState>;
  private writeTail: Promise<void> = Promise.resolve();

  constructor(
    executor: DDAExecutor,
    storage: GameAlgoStorage | undefined,
    storageKey: string,
    options: GameAlgoDDAOptions = {},
    logger?: (message: string) => void,
  ) {
    this.executor = executor;
    this.storage = storage;
    this.storageKey = options.storageKey ?? storageKey;
    this.recentWindowSize = normalizeWindowSize(options.recentWindowSize);
    this.logger = logger;
    this.statePromise = this.loadState();
  }

  async recordBehavior(type: string, amount = 1): Promise<void> {
    const behaviorType = normalizeBehaviorType(type);
    if (!Number.isFinite(amount) || amount <= 0) throw new Error("DDA behavior amount must be greater than 0");
    await this.mutate((state) => {
      state.current[behaviorType] = (state.current[behaviorType] ?? 0) + amount;
      state.lifetime[behaviorType] = (state.lifetime[behaviorType] ?? 0) + amount;
    });
  }

  async completeStep(stepId?: string): Promise<void> {
    await this.mutate((state) => {
      state.recentSteps.push({
        ...(clean(stepId) ? { stepId: clean(stepId) } : {}),
        behaviors: { ...state.current },
      });
      if (state.recentSteps.length > this.recentWindowSize) {
        state.recentSteps.splice(0, state.recentSteps.length - this.recentWindowSize);
      }
      state.current = {};
      state.completedSteps += 1;
    });
  }

  async reset(scope: "all" | "current" | "recent" = "all"): Promise<void> {
    await this.mutate((state) => {
      if (scope === "all") {
        Object.assign(state, emptyState());
      } else if (scope === "current") {
        state.current = {};
      } else if (scope === "recent") {
        state.recentSteps = [];
      } else {
        throw new Error(`Unsupported DDA reset scope: ${scope}`);
      }
    });
  }

  async snapshot(context: JsonValue = {}): Promise<GameAlgoDDAScriptState> {
    await this.writeTail;
    const state = await this.statePromise;
    const recent = aggregateRecent(state.recentSteps);
    return {
      context,
      behavior: {
        current: { ...state.current },
        recent,
        lifetime: { ...state.lifetime },
        recentSteps: state.recentSteps.map((step) => ({
          ...(step.stepId ? { stepId: step.stepId } : {}),
          behaviors: { ...step.behaviors },
        })),
        completedSteps: state.completedSteps,
        windowSize: this.recentWindowSize,
      },
    };
  }

  async decide(context: JsonValue = {}): Promise<GameAlgoDDADecision> {
    try {
      const execution = await this.executor.execute(await this.snapshot(context));
      if (!execution) return fallbackDecision("executor_not_ready");
      const adjustment = readAdjustment(execution.payload);
      if (!adjustment) return fallbackDecision("invalid_adjustment", execution);
      return {
        adjustment,
        payload: execution.payload,
        diagnostics: execution.diagnostics,
        assignment: execution.assignment,
        isFallback: false,
      };
    } catch (error) {
      this.logger?.(`[GameAlgoSDK] DDA decision failed: ${error instanceof Error ? error.message : String(error)}`);
      return fallbackDecision("execution_failed");
    }
  }

  private async loadState(): Promise<StoredState> {
    try {
      const encoded = await this.storage?.getItem(this.storageKey);
      if (!encoded) return emptyState();
      const state = normalizeStoredState(JSON.parse(encoded));
      if (state.recentSteps.length > this.recentWindowSize) {
        state.recentSteps.splice(0, state.recentSteps.length - this.recentWindowSize);
      }
      return state;
    } catch (error) {
      this.logger?.(`[GameAlgoSDK] DDA state load failed; using empty state: ${error instanceof Error ? error.message : String(error)}`);
      return emptyState();
    }
  }

  private async mutate(update: (state: StoredState) => void): Promise<void> {
    const operation = this.writeTail.then(async () => {
      const state = await this.statePromise;
      update(state);
      await this.storage?.setItem(this.storageKey, JSON.stringify(state));
    });
    this.writeTail = operation.catch(() => undefined);
    return operation;
  }
}

function emptyState(): StoredState {
  return { schemaVersion: 1, current: {}, lifetime: {}, recentSteps: [], completedSteps: 0 };
}

function normalizeStoredState(value: unknown): StoredState {
  if (!value || typeof value !== "object" || Array.isArray(value)) return emptyState();
  const object = value as Record<string, unknown>;
  const recentSteps = Array.isArray(object.recentSteps)
    ? object.recentSteps.flatMap((entry) => {
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) return [];
        const step = entry as Record<string, unknown>;
        return [{
          ...(clean(step.stepId) ? { stepId: clean(step.stepId) } : {}),
          behaviors: normalizeCounts(step.behaviors),
        }];
      })
    : [];
  return {
    schemaVersion: 1,
    current: normalizeCounts(object.current),
    lifetime: normalizeCounts(object.lifetime),
    recentSteps,
    completedSteps: typeof object.completedSteps === "number" && Number.isFinite(object.completedSteps) && object.completedSteps >= 0
      ? Math.floor(object.completedSteps)
      : 0,
  };
}

function normalizeCounts(value: unknown): BehaviorCounts {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const counts: BehaviorCounts = {};
  for (const [key, amount] of Object.entries(value)) {
    if (key && typeof amount === "number" && Number.isFinite(amount) && amount > 0) counts[key] = amount;
  }
  return counts;
}

function aggregateRecent(steps: StoredStep[]): BehaviorCounts {
  const counts: BehaviorCounts = {};
  for (const step of steps) {
    for (const [type, amount] of Object.entries(step.behaviors)) counts[type] = (counts[type] ?? 0) + amount;
  }
  return counts;
}

function normalizeBehaviorType(value: string): string {
  const type = clean(value);
  if (!type) throw new Error("DDA behavior type is required");
  if (type.length > 128) throw new Error("DDA behavior type must be at most 128 characters");
  return type;
}

function normalizeWindowSize(value?: number): number {
  if (value === undefined) return DEFAULT_WINDOW_SIZE;
  if (!Number.isInteger(value) || value < 1 || value > 100) {
    throw new Error("DDA recentWindowSize must be an integer between 1 and 100");
  }
  return value;
}

function readAdjustment(payload: JsonValue): GameAlgoDDAAdjustment | undefined {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return undefined;
  const value = payload.adjustment;
  return value === "increase" || value === "keep" || value === "decrease" ? value : undefined;
}

function fallbackDecision(reason: string, execution?: GameAlgoExecutionResult): GameAlgoDDADecision {
  return {
    adjustment: "keep",
    payload: { adjustment: "keep" },
    diagnostics: { fallback: true, reason },
    ...(execution ? { assignment: execution.assignment } : {}),
    isFallback: true,
  };
}

function clean(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
