#!/usr/bin/env node
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import { homedir } from "node:os";

type CliConfig = {
  host: string;
  adminKey: string;
};

type SessionPayload = {
  principal: {
    type: string;
    role: string;
    gameId?: string;
    keyName?: string;
  };
};

type ExperimentConfigFile = {
  gameId?: string;
  latestCommitId?: string | null;
  strategies: unknown[];
};

const CONFIG_PATH = join(homedir(), ".gamealgo", "cli.json");
const SCRIPT_EXTENSIONS = new Set([".js", ".lua"]);
const FILE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const global = parseGlobalFlags(args);
  const command = args.shift();
  if (!command || command === "help" || command === "--help" || command === "-h") {
    printHelp();
    return;
  }

  try {
    if (command === "login") {
      await login(args, global);
      return;
    }

    const client = await createClient(global);
    if (command === "whoami") {
      await printResult(await client.session(), global);
      return;
    }
    if (command === "experiment") {
      await handleExperiment(client, args, global);
      return;
    }
    if (command === "script") {
      await handleFileResource(client, args, global, "script");
      return;
    }
    if (command === "config") {
      await handleFileResource(client, args, global, "config");
      return;
    }
    if (command === "report") {
      await handleReport(client, args, global);
      return;
    }
    throw new Error(`Unknown command: ${command}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (global.json) {
      console.log(JSON.stringify({ ok: false, error: message }, null, 2));
    } else {
      console.error(`Error: ${message}`);
    }
    process.exitCode = 1;
  }
}

function parseGlobalFlags(args: string[]) {
  const global = {
    json: false,
    host: process.env.GAMEALGO_ADMIN_HOST || process.env.GAMEALGO_HOST || "",
    adminKey: process.env.GAMEALGO_GAME_ADMIN_KEY || "",
  };
  for (let index = 0; index < args.length;) {
    const arg = args[index];
    if (arg === "--json") {
      global.json = true;
      args.splice(index, 1);
      continue;
    }
    if (arg === "--host") {
      global.host = requireFlagValue(args, index, "--host");
      args.splice(index, 2);
      continue;
    }
    if (arg === "--admin-key") {
      global.adminKey = requireFlagValue(args, index, "--admin-key");
      args.splice(index, 2);
      continue;
    }
    index += 1;
  }
  return global;
}

async function login(args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const flags = parseFlags(args);
  const host = normalizeHost(String(flags.host || global.host || ""));
  const adminKey = String(flags["admin-key"] || global.adminKey || "");
  if (!host) throw new Error("--host is required");
  if (!adminKey) throw new Error("--admin-key is required");
  const client = new GameAlgoAdminClient({ host, adminKey });
  const session = await client.session();
  if (session.principal.type !== "game_admin" || !session.principal.gameId) {
    throw new Error("admin key is not scoped to a game");
  }
  await saveConfig({ host, adminKey });
  await printResult({
    ok: true,
    host,
    gameId: session.principal.gameId,
    keyName: session.principal.keyName,
  }, global);
}

async function createClient(global: ReturnType<typeof parseGlobalFlags>): Promise<GameAlgoAdminClient> {
  const saved = await loadConfig();
  const host = normalizeHost(global.host || saved?.host || "");
  const adminKey = global.adminKey || saved?.adminKey || "";
  if (!host || !adminKey) {
    throw new Error("run `gamealgo login --host <url> --admin-key <game-admin-key>` first");
  }
  return new GameAlgoAdminClient({ host, adminKey });
}

async function handleExperiment(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "pull") {
    const flags = parseFlags(args);
    const config = await client.experimentConfig();
    const out = String(flags.out || "experiment.yaml");
    const file = {
      gameId: config.gameId,
      latestCommitId: config.latestCommitId,
      strategies: config.strategies,
    };
    await writeTextFile(out, await stringifyConfigFile(file, out));
    await printResult({ ok: true, out, latestCommitId: config.latestCommitId }, global);
    return;
  }
  if (sub === "diff") {
    const filePath = args.shift();
    if (!filePath) throw new Error("usage: gamealgo experiment diff <experiment.yaml>");
    const current = await client.experimentConfig();
    const next = await readExperimentConfigFile(filePath);
    const before = await stringifyConfigFile({ gameId: current.gameId, latestCommitId: current.latestCommitId, strategies: current.strategies }, filePath);
    const after = await stringifyConfigFile(normalizeExperimentConfigForPublish(next), filePath);
    const diff = diffText(before.trimEnd(), after.trimEnd());
    if (global.json) {
      await printResult({ ok: true, diff }, global);
    } else {
      console.log(diff || "No changes.");
    }
    return;
  }
  if (sub === "publish") {
    const filePath = args.shift();
    if (!filePath) throw new Error("usage: gamealgo experiment publish <experiment.yaml> --message <message>");
    const flags = parseFlags(args);
    const next = await readExperimentConfigFile(filePath);
    const current = await client.experimentConfig();
    const before = await stringifyConfigFile({ gameId: current.gameId, latestCommitId: current.latestCommitId, strategies: current.strategies }, filePath);
    const after = await stringifyConfigFile(normalizeExperimentConfigForPublish(next), filePath);
    const diff = diffText(before.trimEnd(), after.trimEnd());
    if (!flags.yes && global.json) {
      throw new Error("experiment publish requires --yes in --json mode");
    }
    if (!flags.yes && !isInteractive()) {
      throw new Error("experiment publish requires --yes in non-interactive mode");
    }
    if (!flags.yes) {
      console.log(diff || "No changes.");
      const ok = await confirm("Publish this experiment config?");
      if (!ok) throw new Error("publish cancelled");
    }
    const response = await client.publishExperimentConfig({
      latestCommitId: next.latestCommitId ?? null,
      strategies: next.strategies,
      message: optionalString(flags.message),
      force: Boolean(flags.force),
    });
    await printResult({ ok: true, latestCommitId: response.latestCommitId, configHash: response.configHash }, global);
    return;
  }
  if (sub === "commits") {
    const flags = parseFlags(args);
    await printResult(await client.experimentCommits(Number(flags.limit || 20)), global);
    return;
  }
  if (sub === "rollback") {
    const flags = parseFlags(args);
    const commitId = String(flags.commit || args.shift() || "");
    if (!commitId) throw new Error("usage: gamealgo experiment rollback --commit <commitId>");
    if (!flags.yes && global.json) {
      throw new Error("experiment rollback requires --yes in --json mode");
    }
    if (!flags.yes && !isInteractive()) {
      throw new Error("experiment rollback requires --yes in non-interactive mode");
    }
    if (!flags.yes) {
      const ok = await confirm(`Rollback experiment config to commit ${commitId}?`);
      if (!ok) throw new Error("rollback cancelled");
    }
    const response = await client.rollbackExperiment(commitId, optionalString(flags.message));
    await printResult({ ok: true, latestCommitId: response.latestCommitId, configHash: response.configHash }, global);
    return;
  }
  throw new Error("usage: gamealgo experiment <pull|diff|publish|commits|rollback>");
}

async function handleFileResource(
  client: GameAlgoAdminClient,
  args: string[],
  global: ReturnType<typeof parseGlobalFlags>,
  resource: "script" | "config",
): Promise<void> {
  const sub = args.shift();
  const isScript = resource === "script";
  if (sub === "list") {
    const files = (await client.listConfigFiles()).configFiles.filter((file: { name: string }) => isScriptFileName(file.name) === isScript);
    await printResult({ files }, global);
    return;
  }
  if (sub === "pull") {
    const flags = parseFlags(args);
    const outDir = String(flags.out || (isScript ? "scripts" : "configs"));
    const all = Boolean(flags.all);
    const names = args;
    if (!all && names.length === 0) throw new Error(`usage: gamealgo ${resource} pull <name> [--out dir]`);
    const list = all
      ? (await client.listConfigFiles()).configFiles.filter((file: { name: string }) => isScriptFileName(file.name) === isScript).map((file: { name: string }) => file.name)
      : names;
    const pulled: string[] = [];
    for (const name of list) {
      const file = await client.getConfigFile(sanitizeRemoteFileName(name));
      const fileName = sanitizeRemoteFileName(file.configFile.name);
      const target = join(outDir, fileName);
      await writeTextFile(target, file.configFile.content);
      pulled.push(target);
    }
    await printResult({ ok: true, files: pulled }, global);
    return;
  }
  if (sub === "publish") {
    const flags = parseFlags(args);
    const files = args;
    if (files.length === 0) throw new Error(`usage: gamealgo ${resource} publish <file...>`);
    if (flags.name && files.length > 1) {
      throw new Error("--name can only be used when publishing one file");
    }
    const published = [];
    for (const filePath of files) {
      const name = sanitizeRemoteFileName(String(flags.name || basename(filePath)));
      const content = await readFile(filePath, "utf8");
      if (!isScript && (name.toLowerCase().endsWith(".json") || filePath.toLowerCase().endsWith(".json"))) {
        validateJsonText(content, filePath);
      }
      const result = await client.putConfigFile(name, content, contentTypeForFileName(name));
      published.push(result.configFile);
    }
    await printResult({ ok: true, files: published }, global);
    return;
  }
  throw new Error(`usage: gamealgo ${resource} <list|pull|publish>`);
}

async function handleReport(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "pull") {
    const flags = parseFlags(args);
    const packs = await client.listReportPacks();
    const version = String(flags.version || packs.reportPacks.find((pack: { status: string }) => pack.status === "active")?.version || packs.reportPacks[0]?.version || "");
    if (!version) throw new Error("no report pack found");
    const pack = await client.getReportPack(version);
    const out = String(flags.out || "gamealgo-report-pack-v1.json");
    await writeTextFile(out, JSON.stringify(pack.reportPack.content, null, 2) + "\n");
    await printResult({ ok: true, out, version }, global);
    return;
  }
  if (sub === "validate") {
    const filePath = args.shift();
    if (!filePath) throw new Error("usage: gamealgo report validate <report-pack.json>");
    const content = await readJsonFile(filePath);
    await printResult(await client.previewReportPack(content), global);
    return;
  }
  if (sub === "publish") {
    const filePath = args.shift();
    if (!filePath) throw new Error("usage: gamealgo report publish <report-pack.json>");
    const flags = parseFlags(args);
    const content = await readJsonFile(filePath);
    const version = String(flags.version || (content && typeof content === "object" && "version" in content ? (content as { version?: unknown }).version : "") || "");
    if (!version) throw new Error("--version is required when content.version is missing");
    const response = await client.putReportPack(version, content);
    await printResult({ ok: true, version, validation: response.reportPack.validation }, global);
    return;
  }
  if (sub === "manifest" || sub === "list") {
    const flags = parseFlags(args);
    await printResult(await client.reportManifest(optionalString(flags.version)), global);
    return;
  }
  if (sub === "result") {
    const selectors = parseSelectorFlags(args);
    const flags = parseFlags(args);
    const startDate = String(flags.from || flags.start || flags.startDate || "");
    const endDate = String(flags.to || flags.end || flags.endDate || "");
    if (!startDate || !endDate) throw new Error("usage: gamealgo report result --from YYYY-MM-DD --to YYYY-MM-DD [--tab name] [--group name] [--chart name] [--selector k=v]");
    const timeoutMs = reportTimeoutMs(flags);
    const startedAt = Date.now();
    const stopProgress = startProgress("Querying report results", timeoutMs);
    let response: unknown;
    try {
      response = await client.queryReportDashboard({
        version: optionalString(flags.version),
        startDate,
        endDate,
        tab: optionalString(flags.tab),
        tabId: optionalString(flags["tab-id"]),
        group: optionalString(flags.group),
        groupId: optionalString(flags["group-id"]),
        chart: optionalString(flags.chart),
        chartId: optionalString(flags["chart-id"]),
        selectors,
        refresh: Boolean(flags.refresh),
      }, { timeoutMs });
    } finally {
      stopProgress();
    }
    const elapsedMs = Date.now() - startedAt;
    const outputValue = withCliMeta(response, { elapsedMs, timeoutMs });
    process.stderr.write(`Report query finished in ${formatDuration(elapsedMs)}.\n`);
    if (flags.out) {
      await writeTextFile(String(flags.out), JSON.stringify(outputValue, null, 2) + "\n");
      await printResult({
        ok: true,
        out: String(flags.out),
        results: Array.isArray((outputValue as { results?: unknown[] }).results) ? (outputValue as { results: unknown[] }).results.length : 0,
        elapsedMs,
      }, global);
      return;
    }
    await printResult(outputValue, global);
    return;
  }
  if (sub === "preview") {
    const selectors = parseSelectorFlags(args);
    const flags = parseFlags(args);
    const filePath = String(flags.pack || flags.file || args.shift() || "");
    const startDate = String(flags.from || flags.start || flags.startDate || "");
    const endDate = String(flags.to || flags.end || flags.endDate || "");
    if (!filePath || !startDate || !endDate) {
      throw new Error("usage: gamealgo report preview --pack report-pack.json --from YYYY-MM-DD --to YYYY-MM-DD [--tab name] [--group name] [--chart name] [--selector k=v]");
    }
    const content = await readJsonFile(filePath);
    const timeoutMs = reportTimeoutMs(flags);
    const startedAt = Date.now();
    const stopProgress = startProgress("Previewing report results", timeoutMs);
    let response: unknown;
    try {
      response = await client.previewReportDashboard({
        content,
        version: optionalString(flags.version),
        startDate,
        endDate,
        tab: optionalString(flags.tab),
        tabId: optionalString(flags["tab-id"]),
        group: optionalString(flags.group),
        groupId: optionalString(flags["group-id"]),
        chart: optionalString(flags.chart),
        chartId: optionalString(flags["chart-id"]),
        selectors,
      }, { timeoutMs });
    } finally {
      stopProgress();
    }
    const elapsedMs = Date.now() - startedAt;
    const outputValue = withCliMeta(response, { elapsedMs, timeoutMs });
    process.stderr.write(`Report preview finished in ${formatDuration(elapsedMs)}.\n`);
    if (flags.out) {
      await writeTextFile(String(flags.out), JSON.stringify(outputValue, null, 2) + "\n");
      await printResult({
        ok: true,
        out: String(flags.out),
        results: Array.isArray((outputValue as { results?: unknown[] }).results) ? (outputValue as { results: unknown[] }).results.length : 0,
        elapsedMs,
      }, global);
      return;
    }
    await printResult(outputValue, global);
    return;
  }
  throw new Error("usage: gamealgo report <pull|validate|publish|manifest|result|preview>");
}

class GameAlgoAdminClient {
  readonly host: string;
  readonly adminKey: string;
  private sessionCache?: SessionPayload;

  constructor(config: CliConfig) {
    this.host = normalizeHost(config.host);
    this.adminKey = config.adminKey;
  }

  async session(): Promise<SessionPayload> {
    this.sessionCache ??= await this.get("/admin/v1/session") as SessionPayload;
    return this.sessionCache;
  }

  async gameId(): Promise<string> {
    const session = await this.session();
    const gameId = session.principal.gameId;
    if (!gameId) throw new Error("current credential is not scoped to a game");
    return gameId;
  }

  async experimentConfig() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-config`) as {
      gameId: string;
      latestCommitId: string | null;
      strategies: unknown[];
    };
  }

  async publishExperimentConfig(body: Record<string, unknown>) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-config/publish`, body) as {
      latestCommitId: string;
      configHash: string;
    };
  }

  async experimentCommits(limit: number) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-commits?limit=${encodeURIComponent(String(limit))}`);
  }

  async rollbackExperiment(commitId: string, message?: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-commits/${encodeURIComponent(commitId)}/rollback`, { message }) as {
      latestCommitId: string;
      configHash: string;
    };
  }

  async listConfigFiles() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/config-files`) as { configFiles: Array<{ name: string }> };
  }

  async getConfigFile(name: string) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/config-files/${encodeURIComponent(name)}`) as {
      configFile: { name: string; content: string };
    };
  }

  async putConfigFile(name: string, content: string, contentType: string) {
    return await this.put(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/config-files/${encodeURIComponent(name)}`, { content, contentType }) as {
      configFile: unknown;
    };
  }

  async listReportPacks() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/report-packs`) as {
      reportPacks: Array<{ version: string; status: string }>;
    };
  }

  async getReportPack(version: string) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/report-packs/${encodeURIComponent(version)}`) as {
      reportPack: { content: unknown };
    };
  }

  async previewReportPack(content: unknown) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/report-packs/preview`, { content });
  }

  async putReportPack(version: string, content: unknown) {
    return await this.put(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/report-packs/${encodeURIComponent(version)}`, { content, status: "active" }) as {
      reportPack: { validation: unknown };
    };
  }

  async reportManifest(version?: string) {
    const query = version ? `?version=${encodeURIComponent(version)}` : "";
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/reports/manifest${query}`);
  }

  async queryReportDashboard(body: Record<string, unknown>, options: { timeoutMs?: number } = {}) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/reports/query`, body, options);
  }

  async previewReportDashboard(body: Record<string, unknown>, options: { timeoutMs?: number } = {}) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/reports/preview`, body, options);
  }

  async get(path: string) {
    return await requestJson(this.host, path, { headers: this.headers() });
  }

  async post(path: string, body: unknown, options: { timeoutMs?: number } = {}) {
    return await requestJson(this.host, path, {
      method: "POST",
      headers: this.headers({ "Content-Type": "application/json" }),
      body: JSON.stringify(body),
      timeoutMs: options.timeoutMs,
    });
  }

  async put(path: string, body: unknown) {
    return await requestJson(this.host, path, {
      method: "PUT",
      headers: this.headers({ "Content-Type": "application/json" }),
      body: JSON.stringify(body),
    });
  }

  private headers(extra: Record<string, string> = {}) {
    return {
      "X-GameAlgo-Game-Admin-Key": this.adminKey,
      ...extra,
    };
  }
}

type CliRequestInit = RequestInit & { timeoutMs?: number };

async function requestJson(host: string, path: string, init: CliRequestInit): Promise<unknown> {
  const { timeoutMs, ...requestInit } = init;
  let response: Response;
  try {
    response = await fetch(`${normalizeHost(host)}${path}`, {
      ...requestInit,
      signal: timeoutMs ? AbortSignal.timeout(timeoutMs) : requestInit.signal,
    });
  } catch (error) {
    if (isTimeoutError(error)) {
      throw new Error(`HTTP request timed out after ${formatDuration(timeoutMs ?? 0)}`);
    }
    throw error;
  }
  const text = await response.text();
  const json = parseJsonResponse(text);
  if (!response.ok) {
    throw new Error(formatHttpError(response.status, response.statusText, text, json));
  }
  if (text && json === undefined) {
    throw new Error(`Invalid JSON response from ${path}: ${truncateBody(text)}`);
  }
  return json ?? null;
}

function parseFlags(args: string[]): Record<string, string | boolean> {
  const flags: Record<string, string | boolean> = {};
  for (let index = 0; index < args.length;) {
    const arg = args[index];
    if (!arg.startsWith("--")) {
      index += 1;
      continue;
    }
    const key = arg.slice(2);
    const next = args[index + 1];
    if (!next || next.startsWith("--")) {
      flags[key] = true;
      args.splice(index, 1);
    } else {
      flags[key] = next;
      args.splice(index, 2);
    }
  }
  return flags;
}

function parseSelectorFlags(args: string[]): Record<string, string> {
  const selectors: Record<string, string> = {};
  for (let index = 0; index < args.length;) {
    if (args[index] !== "--selector") {
      index += 1;
      continue;
    }
    const value = requireFlagValue(args, index, "--selector");
    const separator = value.indexOf("=");
    if (separator <= 0) throw new Error("--selector must use key=value");
    const key = value.slice(0, separator).trim();
    const selectorValue = value.slice(separator + 1).trim();
    if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(key)) throw new Error(`invalid selector id: ${key}`);
    selectors[key] = selectorValue;
    args.splice(index, 2);
  }
  return selectors;
}

function requireFlagValue(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

async function loadConfig(): Promise<CliConfig | null> {
  try {
    return JSON.parse(await readFile(CONFIG_PATH, "utf8")) as CliConfig;
  } catch {
    return null;
  }
}

async function saveConfig(config: CliConfig): Promise<void> {
  await mkdir(dirname(CONFIG_PATH), { recursive: true, mode: 0o700 });
  await chmod(dirname(CONFIG_PATH), 0o700).catch(() => undefined);
  await writeFile(CONFIG_PATH, JSON.stringify(config, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  await chmod(CONFIG_PATH, 0o600).catch(() => undefined);
}

async function readExperimentConfigFile(filePath: string): Promise<ExperimentConfigFile> {
  const text = await readFile(filePath, "utf8");
  const parsed = isYamlFile(filePath) ? await parseYaml(text) : JSON.parse(text);
  if (!parsed || typeof parsed !== "object" || !Array.isArray((parsed as ExperimentConfigFile).strategies)) {
    throw new Error("experiment config file must contain strategies[]");
  }
  return parsed as ExperimentConfigFile;
}

function normalizeExperimentConfigForPublish(file: ExperimentConfigFile) {
  return {
    gameId: file.gameId,
    latestCommitId: file.latestCommitId ?? null,
    strategies: file.strategies,
  };
}

async function stringifyConfigFile(value: unknown, filePath: string): Promise<string> {
  if (!isYamlFile(filePath)) return JSON.stringify(value, null, 2) + "\n";
  return await stringifyYaml(value);
}

async function parseYaml(text: string): Promise<unknown> {
  const yaml = await import("yaml");
  return yaml.parse(text);
}

async function stringifyYaml(value: unknown): Promise<string> {
  const yaml = await import("yaml");
  return yaml.stringify(value);
}

function isYamlFile(filePath: string): boolean {
  const ext = extname(filePath).toLowerCase();
  return ext === ".yaml" || ext === ".yml";
}

async function readJsonFile(filePath: string): Promise<unknown> {
  return JSON.parse(await readFile(filePath, "utf8"));
}

async function writeTextFile(path: string, content: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content, "utf8");
}

function sanitizeRemoteFileName(name: string): string {
  const trimmed = name.trim();
  if (!trimmed || trimmed !== basename(trimmed) || trimmed.includes("/") || trimmed.includes("\\") || trimmed.includes("..")) {
    throw new Error(`invalid remote file name: ${name}`);
  }
  if (!FILE_NAME_PATTERN.test(trimmed)) {
    throw new Error(`invalid remote file name: ${name}`);
  }
  return trimmed;
}

function validateJsonText(content: string, filePath: string): void {
  try {
    JSON.parse(content);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`invalid JSON in ${filePath}: ${message}`);
  }
}

function parseJsonResponse(text: string): unknown | undefined {
  if (!text) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

function formatHttpError(status: number, statusText: string, text: string, json: unknown): string {
  if (json && typeof json === "object") {
    const body = json as Record<string, unknown>;
    const message = body.message || body.error;
    if (message) return `HTTP ${status}: ${String(message)}`;
  }
  const bodyText = truncateBody(text);
  return bodyText ? `HTTP ${status} ${statusText}: ${bodyText}` : `HTTP ${status} ${statusText}`;
}

function truncateBody(text: string): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  return normalized.length > 500 ? `${normalized.slice(0, 500)}...` : normalized;
}

function isTimeoutError(error: unknown): boolean {
  return error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError");
}

function isInteractive(): boolean {
  return Boolean(input.isTTY && output.isTTY);
}

function reportTimeoutMs(flags: Record<string, string | boolean>): number | undefined {
  if (flags["timeout-ms"] !== undefined) return Math.ceil(positiveNumberFlag(flags["timeout-ms"], "--timeout-ms"));
  if (flags.timeout !== undefined) return Math.ceil(positiveNumberFlag(flags.timeout, "--timeout") * 1000);
  return undefined;
}

function positiveNumberFlag(value: string | boolean, flag: string): number {
  if (typeof value === "boolean") throw new Error(`${flag} requires a value`);
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error(`${flag} must be a positive number`);
  return parsed;
}

function startProgress(label: string, timeoutMs?: number): () => void {
  const startedAt = Date.now();
  process.stderr.write(`${label}${timeoutMs ? `, timeout ${formatDuration(timeoutMs)}` : ""}...\n`);
  const timer = setInterval(() => {
    process.stderr.write(`${label} still running, elapsed ${formatDuration(Date.now() - startedAt)}...\n`);
  }, 5000);
  return () => clearInterval(timer);
}

function withCliMeta(value: unknown, meta: { elapsedMs: number; timeoutMs?: number }): unknown {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  return {
    ...(value as Record<string, unknown>),
    cli: {
      elapsedMs: meta.elapsedMs,
      ...(meta.timeoutMs ? { timeoutMs: meta.timeoutMs } : {}),
    },
  };
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

async function printResult(value: unknown, global: { json: boolean }): Promise<void> {
  if (global.json) {
    console.log(JSON.stringify(value, null, 2));
    return;
  }
  if (typeof value === "string") {
    console.log(value);
    return;
  }
  console.log(JSON.stringify(value, null, 2));
}

async function confirm(question: string): Promise<boolean> {
  const rl = createInterface({ input, output });
  try {
    const answer = await rl.question(`${question} [y/N] `);
    return answer.trim().toLowerCase() === "y" || answer.trim().toLowerCase() === "yes";
  } finally {
    rl.close();
  }
}

function normalizeHost(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function isScriptFileName(name: string): boolean {
  const dot = name.lastIndexOf(".");
  return dot >= 0 && SCRIPT_EXTENSIONS.has(name.slice(dot).toLowerCase());
}

function contentTypeForFileName(name: string): string {
  if (name.endsWith(".json")) return "application/json; charset=utf-8";
  return "text/plain; charset=utf-8";
}

function diffText(before: string, after: string): string {
  if (before === after) return "";
  const a = before.split("\n");
  const b = after.split("\n");
  const table = Array.from({ length: a.length + 1 }, () => Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i -= 1) {
    for (let j = b.length - 1; j >= 0; j -= 1) {
      table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
    }
  }
  const lines = ["--- current", "+++ next"];
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      lines.push(` ${a[i]}`);
      i += 1;
      j += 1;
    } else if (table[i + 1][j] >= table[i][j + 1]) {
      lines.push(`-${a[i]}`);
      i += 1;
    } else {
      lines.push(`+${b[j]}`);
      j += 1;
    }
  }
  while (i < a.length) {
    lines.push(`-${a[i]}`);
    i += 1;
  }
  while (j < b.length) {
    lines.push(`+${b[j]}`);
    j += 1;
  }
  return lines.join("\n");
}

function printHelp(): void {
  console.log(`
GameAlgo CLI

Usage:
  gamealgo login --host <admin-url> --admin-key <game-admin-key>
  gamealgo whoami

  gamealgo experiment pull --out experiment.yaml
  gamealgo experiment diff experiment.yaml
  gamealgo experiment publish experiment.yaml --message "..." --yes
  gamealgo experiment commits
  gamealgo experiment rollback --commit exp_c_xxxxxxxxxxxxxxxx --yes

  gamealgo script list
  gamealgo script pull level-generator.js --out scripts/
  gamealgo script pull --all --out scripts/
  gamealgo script publish scripts/level-generator.js

  gamealgo config list
  gamealgo config pull gameplay.json --out configs/
  gamealgo config pull --all --out configs/
  gamealgo config publish configs/gameplay.json

  gamealgo report pull --out gamealgo-report-pack-v1.json
  gamealgo report validate gamealgo-report-pack-v1.json
  gamealgo report publish gamealgo-report-pack-v1.json
  gamealgo report manifest
  gamealgo report result --from 2026-06-14 --to 2026-06-21 --tab Revenue --group "Daily ARPU" --selector experiment=ad_frequency --timeout 60 --out report-result.json
  gamealgo report preview --pack gamealgo-report-pack-v1.json --from 2026-06-14 --to 2026-06-21 --group "Daily ARPU" --timeout 60 --out preview-result.json
`.trim());
}

await main();
