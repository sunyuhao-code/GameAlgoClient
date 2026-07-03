#!/usr/bin/env node
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, basename } from "node:path";
import { homedir } from "node:os";
import YAML from "yaml";

type CliConfig = {
  host: string;
  adminKey: string;
};

type SessionPayload = {
  principal: {
    type: string;
    role: string;
    gameId?: string;
    keyId?: string;
    keyName?: string;
  };
};

type ExperimentConfigFile = {
  gameId?: string;
  latestCommitId?: string | null;
  strategies: unknown[];
};

type ManagedExperimentTaskFile = {
  strategyName?: string;
  strategy?: string;
  cycleDays?: unknown;
  maxVariantsPerRound?: unknown;
  objective?: string;
  autoApplyWinner?: boolean;
  candidates?: unknown[];
};

type CliGameKey = {
  id: string;
  name: string;
  keyPrefix: string;
  rawKey?: string | null;
  status: string;
  createdAt?: string;
};

type KeySelector = {
  id?: string;
  name?: string;
  prefix?: string;
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
    if (command === "whoami") {
      const client = await createClient(global);
      await printResult(await client.session(), global);
      return;
    }
    if (command === "admin-key") {
      await handleAdminKey(args, global);
      return;
    }

    const client = await createClient(global);
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
    if (command === "key") {
      await handleGameKey(client, args, global);
      return;
    }
    if (command === "events") {
      await handleEvents(client, args, global);
      return;
    }
    if (command === "marketing") {
      await handleMarketing(client, args, global);
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
    adminToken: process.env.GAMEALGO_ADMIN_TOKEN || "",
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
    if (arg === "--admin-token") {
      global.adminToken = requireFlagValue(args, index, "--admin-token");
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
    throw new Error("run `gamealgo login --host <url> --admin-key <key>` first");
  }
  return new GameAlgoAdminClient({ host, adminKey });
}

async function handleAdminKey(args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub !== "create") throw new Error("usage: gamealgo admin-key create --host <url> --admin-token <token> --game <gameId> --name <name>");
  const flags = parseFlags(args);
  const host = normalizeHost(String(flags.host || global.host || ""));
  const adminToken = String(flags["admin-token"] || global.adminToken || "");
  const gameId = String(flags.game || "");
  const name = String(flags.name || "");
  if (!host) throw new Error("--host is required");
  if (!adminToken) throw new Error("--admin-token is required");
  if (!gameId) throw new Error("--game is required");
  if (!name) throw new Error("--name is required");
  const response = await requestJson(host, `/admin/v1/games/${encodeURIComponent(gameId)}/admin-keys`, {
    method: "POST",
    headers: {
      "X-GameAlgo-Admin-Token": adminToken,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ name }),
  });
  await printResult(response, global);
}

async function handleExperiment(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "managed") {
    await handleManagedExperiment(client, args, global);
    return;
  }
  if (sub === "pull") {
    const flags = parseFlags(args);
    const config = await client.experimentConfig();
    const file = {
      gameId: config.gameId,
      latestCommitId: config.latestCommitId,
      strategies: config.strategies,
    };
    const text = YAML.stringify(file);
    if (flags.out) {
      await writeTextFile(String(flags.out), text);
      await printResult({ ok: true, out: String(flags.out), latestCommitId: config.latestCommitId }, global);
    } else {
      process.stdout.write(text);
    }
    return;
  }
  if (sub === "diff") {
    const filePath = args.shift();
    if (!filePath) throw new Error("usage: gamealgo experiment diff <experiment.yaml>");
    const current = await client.experimentConfig();
    const next = await readExperimentConfigFile(filePath);
    const diff = diffText(
      YAML.stringify({ gameId: current.gameId, latestCommitId: current.latestCommitId, strategies: current.strategies }).trimEnd(),
      YAML.stringify(normalizeExperimentConfigForPublish(next)).trimEnd(),
    );
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
    const diff = diffText(
      YAML.stringify({ gameId: current.gameId, latestCommitId: current.latestCommitId, strategies: current.strategies }).trimEnd(),
      YAML.stringify(normalizeExperimentConfigForPublish(next)).trimEnd(),
    );
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
  throw new Error("usage: gamealgo experiment <pull|diff|publish|commits|rollback|managed>");
}

async function handleManagedExperiment(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "create") {
    const flags = parseFlags(args);
    const filePath = optionalString(flags.file || flags.input) || optionalString(args.shift());
    if (!filePath) throw new Error("usage: gamealgo experiment managed create <managed-experiment.yaml> --yes");
    if (!flags.yes && global.json) {
      throw new Error("experiment managed create requires --yes in --json mode");
    }
    if (!flags.yes && !isInteractive()) {
      throw new Error("experiment managed create requires --yes in non-interactive mode");
    }
    const file = await readManagedExperimentTaskFile(filePath);
    const body = normalizeManagedExperimentTaskForCreate(file, flags);
    if (!flags.yes) {
      const ok = await confirm(`Create managed experiment for ${body.strategyName}?`);
      if (!ok) throw new Error("managed experiment create cancelled");
    }
    const response = await client.createManagedExperimentTask(body);
    await printResult(managedExperimentStatusOutput(response, { ok: true, created: true }), global);
    return;
  }
  if (sub === "list") {
    const response = await client.listManagedExperimentTasks();
    await printResult(response, global);
    return;
  }
  if (sub === "status" || sub === "show") {
    const flags = parseFlags(args);
    const taskId = optionalString(flags.task || flags["task-id"] || flags.id) || optionalString(args.shift());
    if (!taskId) throw new Error("usage: gamealgo experiment managed status <taskId>");
    const response = await client.getManagedExperimentTask(taskId);
    await printResult(managedExperimentStatusOutput(response), global);
    return;
  }
  if (sub === "report") {
    const flags = parseFlags(args);
    const taskId = optionalString(flags.task || flags["task-id"] || flags.id) || optionalString(args.shift());
    if (!taskId) throw new Error("usage: gamealgo experiment managed report <taskId> --round <roundNumber>");
    const response = await client.getManagedExperimentTask(taskId);
    await printResult(managedExperimentRoundReportOutput(response, flags), global);
    return;
  }
  if (sub === "cancel") {
    const flags = parseFlags(args);
    const taskId = optionalString(flags.task || flags["task-id"] || flags.id) || optionalString(args.shift());
    if (!taskId) throw new Error("usage: gamealgo experiment managed cancel <taskId> --yes");
    if (!flags.yes && global.json) {
      throw new Error("experiment managed cancel requires --yes in --json mode");
    }
    if (!flags.yes && !isInteractive()) {
      throw new Error("experiment managed cancel requires --yes in non-interactive mode");
    }
    if (!flags.yes) {
      const ok = await confirm(`Cancel managed experiment ${taskId}?`);
      if (!ok) throw new Error("managed experiment cancel cancelled");
    }
    const response = await client.cancelManagedExperimentTask(taskId);
    await printResult(managedExperimentStatusOutput(response, { ok: true, cancelled: true }), global);
    return;
  }
  throw new Error("usage: gamealgo experiment managed <create|list|status|report|cancel>");
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

async function handleEvents(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub !== "count") throw new Error("usage: gamealgo events count [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--event-type level_end]");
  const flags = parseFlags(args);
  const timeoutMs = reportTimeoutMs(flags);
  const startedAt = Date.now();
  const stopProgress = startProgress("Querying event counts", timeoutMs);
  let response: unknown;
  try {
    response = await client.countEvents({
      startDate: optionalString(flags.from || flags.start || flags.startDate),
      endDate: optionalString(flags.to || flags.end || flags.endDate),
      eventType: optionalString(flags["event-type"] || flags.eventType),
    }, { timeoutMs });
  } finally {
    stopProgress();
  }
  const elapsedMs = Date.now() - startedAt;
  const outputValue = withCliMeta(response, { elapsedMs, timeoutMs });
  process.stderr.write(`Event count query finished in ${formatDuration(elapsedMs)}.\n`);
  if (flags.out) {
    await writeTextFile(String(flags.out), JSON.stringify(outputValue, null, 2) + "\n");
    await printResult({ ok: true, out: String(flags.out), elapsedMs }, global);
    return;
  }
  await printResult(outputValue, global);
}

async function handleMarketing(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const provider = args.shift();
  if (provider !== "adjust") throw new Error("usage: gamealgo marketing adjust <get|configure|sync>");
  const sub = args.shift();
  if (sub === "get" || sub === "status") {
    await printResult(await client.getAdjustMarketing(), global);
    return;
  }
  if (sub === "configure" || sub === "set") {
    const flags = parseFlags(args);
    const current = await client.getAdjustMarketing() as { integration?: Record<string, unknown> | null };
    const existing = current.integration || {};
    const appToken = optionalString(flags["app-token"] || flags.appToken || existing.appToken);
    const platform = optionalString(flags.platform || existing.platform) || "ios";
    if (!appToken) throw new Error("--app-token is required");
    if (platform !== "ios" && platform !== "android") throw new Error("--platform must be ios or android");
    const body: Record<string, unknown> = {
      appToken,
      appName: optionalString(flags["app-name"] || flags.appName || existing.appName) || "",
      platform,
      currency: optionalString(flags.currency || existing.currency) || "USD",
      status: optionalString(flags.status || existing.status) || "active",
    };
    const apiToken = optionalString(flags["api-token"] || flags.apiToken);
    if (apiToken) body.apiToken = apiToken;
    await printResult({ ok: true, ...(await client.putAdjustMarketing(body)) }, global);
    return;
  }
  if (sub === "sync") {
    const flags = parseFlags(args);
    const timeoutMs = reportTimeoutMs(flags);
    const startedAt = Date.now();
    const stopProgress = startProgress("Syncing Adjust marketing spend", timeoutMs);
    let response: unknown;
    try {
      response = await client.syncAdjustMarketing({
        startDate: optionalString(flags.from || flags.start || flags.startDate),
        endDate: optionalString(flags.to || flags.end || flags.endDate),
      }, { timeoutMs });
    } finally {
      stopProgress();
    }
    const elapsedMs = Date.now() - startedAt;
    process.stderr.write(`Adjust sync finished in ${formatDuration(elapsedMs)}.\n`);
    await printResult(withCliMeta(response, { elapsedMs, timeoutMs }), global);
    return;
  }
  throw new Error("usage: gamealgo marketing adjust <get|configure|sync>");
}

async function handleGameKey(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "list") {
    const keys = (await client.listGameKeys()).keys
      .filter((key) => key.status === "active")
      .map(publicGameKeyForCli);
    await printResult({ keys }, global);
    return;
  }
  if (sub === "create") {
    const flags = parseFlags(args);
    const name = optionalString(flags.name) || optionalString(args.shift());
    if (!name) throw new Error("usage: gamealgo key create --name <key-name>");
    const response = await client.createGameKey(name);
    await printResult({
      ok: true,
      created: response.created !== false,
      name: response.key.name,
      key: response.rawKey,
      prefix: response.key.keyPrefix,
      keyPrefix: response.key.keyPrefix,
      status: response.key.status,
      createdAt: response.key.createdAt,
    }, global);
    return;
  }
  if (sub === "reveal") {
    const selector = keySelectorFromArgs(args, "gamealgo key reveal --name <key-name>");
    const response = await client.revealGameKey(selector);
    await printResult({
      ok: true,
      name: response.key.name,
      key: response.rawKey,
      prefix: response.key.keyPrefix,
      keyPrefix: response.key.keyPrefix,
      status: response.key.status,
      createdAt: response.key.createdAt,
    }, global);
    return;
  }
  if (sub === "revoke") {
    const flags = parseFlags(args);
    if (!flags.yes && global.json) {
      throw new Error("key revoke requires --yes in --json mode");
    }
    if (!flags.yes && !isInteractive()) {
      throw new Error("key revoke requires --yes in non-interactive mode");
    }
    const selector = keySelectorFromFlags(flags, args, "gamealgo key revoke --name <key-name> --yes");
    const key = await resolveGameKey(client, selector);
    if (!flags.yes) {
      const ok = await confirm(`Revoke client game key ${key.name} (${key.keyPrefix})?`);
      if (!ok) throw new Error("revoke cancelled");
    }
    const response = await client.revokeGameKey(key.id);
    await printResult({ ok: true, key: publicGameKeyForCli(response.key) }, global);
    return;
  }
  throw new Error("usage: gamealgo key <list|create|reveal|revoke>");
}

function publicGameKeyForCli(key: CliGameKey) {
  return {
    id: key.id,
    name: key.name,
    prefix: key.keyPrefix,
    keyPrefix: key.keyPrefix,
    status: key.status,
    createdAt: key.createdAt,
  };
}

function keySelectorFromArgs(args: string[], usage: string): KeySelector {
  const flags = parseFlags(args);
  return keySelectorFromFlags(flags, args, usage);
}

function keySelectorFromFlags(flags: Record<string, string | boolean>, args: string[], usage: string): KeySelector {
  const id = optionalString(flags.id);
  const name = optionalString(flags.name);
  const prefix = optionalString(flags.prefix) || optionalString(flags["key-prefix"]);
  const positionalName = !id && !name && !prefix ? optionalString(args.find((arg) => !arg.startsWith("--"))) : undefined;
  const selector = {
    id,
    name: name || positionalName,
    prefix,
  };
  if (!selector.id && !selector.name && !selector.prefix) throw new Error(`usage: ${usage}`);
  return selector;
}

async function resolveGameKey(client: GameAlgoAdminClient, selector: KeySelector): Promise<CliGameKey> {
  if (selector.id) {
    const key = (await client.listGameKeys()).keys.find((item) => item.status === "active" && item.id === selector.id);
    if (!key) throw new Error(`client game key not found: ${selector.id}`);
    return key;
  }
  if (selector.name) {
    const key = (await client.listGameKeys()).keys.find((item) => item.status === "active" && item.name === selector.name);
    if (!key) throw new Error(`client game key not found: ${selector.name}`);
    return key;
  }
  const key = (await client.listGameKeys()).keys.find((item) => item.status === "active" && item.keyPrefix === selector.prefix);
  if (!key) throw new Error(`client game key not found: ${selector.prefix}`);
  return key;
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

  async listManagedExperimentTasks() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/managed-experiments`);
  }

  async getManagedExperimentTask(taskId: string) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/managed-experiments/${encodeURIComponent(taskId)}`);
  }

  async createManagedExperimentTask(body: Record<string, unknown>) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/managed-experiments`, body);
  }

  async cancelManagedExperimentTask(taskId: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/managed-experiments/${encodeURIComponent(taskId)}/cancel`, {});
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

  async countEvents(body: Record<string, unknown>, options: { timeoutMs?: number } = {}) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/events/count`, body, options);
  }

  async getAdjustMarketing() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/marketing/adjust`);
  }

  async putAdjustMarketing(body: Record<string, unknown>) {
    return await this.put(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/marketing/adjust`, body);
  }

  async syncAdjustMarketing(body: Record<string, unknown>, options: { timeoutMs?: number } = {}) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/marketing/adjust/sync`, body, options);
  }

  async listGameKeys() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/keys`) as { keys: CliGameKey[] };
  }

  async createGameKey(name: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/keys`, { name }) as {
      created?: boolean;
      rawKey: string;
      key: CliGameKey;
    };
  }

  async revealGameKey(selector: KeySelector) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/keys/reveal`, selector) as {
      rawKey: string;
      key: CliGameKey;
    };
  }

  async revokeGameKey(id: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/keys/${encodeURIComponent(id)}/revoke`, {}) as {
      key: CliGameKey;
    };
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
  const parsed = filePath.endsWith(".json") ? JSON.parse(text) : YAML.parse(text);
  if (!parsed || typeof parsed !== "object" || !Array.isArray((parsed as ExperimentConfigFile).strategies)) {
    throw new Error("experiment config file must contain strategies[]");
  }
  return parsed as ExperimentConfigFile;
}

async function readManagedExperimentTaskFile(filePath: string): Promise<ManagedExperimentTaskFile> {
  const text = await readFile(filePath, "utf8");
  const parsed = filePath.endsWith(".json") ? JSON.parse(text) : YAML.parse(text);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("managed experiment file must be a JSON/YAML object");
  }
  return parsed as ManagedExperimentTaskFile;
}

function normalizeManagedExperimentTaskForCreate(file: ManagedExperimentTaskFile, flags: Record<string, string | boolean>): Record<string, unknown> {
  const strategyName = optionalString(flags.strategy || flags["strategy-name"]) || optionalString(file.strategyName || file.strategy);
  if (!strategyName) throw new Error("managed experiment requires strategyName");
  const candidates = file.candidates;
  if (!Array.isArray(candidates) || candidates.length < 2) {
    throw new Error("managed experiment requires candidates[] with at least two variants");
  }
  const cycleDays = optionalPositiveInteger(flags["cycle-days"] ?? flags.cycleDays ?? file.cycleDays, "cycleDays");
  const maxVariantsPerRound = optionalPositiveInteger(flags["max-variants-per-round"] ?? flags.maxVariantsPerRound, "maxVariantsPerRound")
    ?? optionalPositiveInteger(file.maxVariantsPerRound, "maxVariantsPerRound");
  const objective = optionalString(flags.objective) || optionalString(file.objective);
  const autoApplyWinner = flags["no-auto-apply"] ? false : file.autoApplyWinner;
  return {
    strategyName,
    ...(cycleDays ? { cycleDays } : {}),
    ...(maxVariantsPerRound ? { maxVariantsPerRound } : {}),
    ...(objective ? { objective } : {}),
    ...(autoApplyWinner !== undefined ? { autoApplyWinner } : {}),
    candidates: candidates.map((candidate, index) => normalizeManagedExperimentCandidate(candidate, index)),
  };
}

function normalizeManagedExperimentCandidate(candidate: unknown, index: number): Record<string, unknown> {
  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    throw new Error(`candidates[${index}] must be an object`);
  }
  const body = candidate as Record<string, unknown>;
  const candidateId = optionalString(body.candidateId || body.id);
  if (!candidateId) throw new Error(`candidates[${index}].candidateId is required`);
  return {
    candidateId,
    config: body.config ?? {},
    ...(body.script !== undefined ? { script: normalizeManagedCandidateScript(body.script, index) } : {}),
  };
}

function normalizeManagedCandidateScript(script: unknown, index: number): unknown {
  if (typeof script === "string") return { name: script };
  if (!script || typeof script !== "object" || Array.isArray(script)) {
    throw new Error(`candidates[${index}].script must be a string or object`);
  }
  return script;
}

function managedExperimentStatusOutput(payload: unknown, extra: Record<string, unknown> = {}) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return payload;
  const body = payload as Record<string, unknown>;
  return {
    ...extra,
    summary: managedExperimentTaskSummary(body),
    task: managedExperimentLightTask(body.task),
    estimate: body.estimate,
    candidates: managedExperimentLightCandidates(body.candidates),
    rounds: managedExperimentLightRounds(body.rounds),
  };
}

function managedExperimentRoundReportOutput(payload: unknown, flags: Record<string, string | boolean>) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return payload;
  const body = payload as Record<string, unknown>;
  const round = selectManagedExperimentRound(body.rounds, flags);
  const task = objectValue(body.task);
  return {
    task: task ? {
      id: task.id,
      strategyName: task.strategyName,
      status: task.status,
    } : null,
    round: {
      id: round.id,
      roundIndex: round.roundIndex,
      roundNumber: Number(round.roundIndex ?? 0) + 1,
      status: round.status,
      assignmentStartDt: round.assignmentStartDt,
      assignmentEndDt: round.assignmentEndDt,
      experimentCompletedAt: round.experimentCompletedAt,
      reportGeneratedAt: round.reportGeneratedAt,
      endedAt: round.endedAt,
      evaluatedAt: round.evaluatedAt,
      winnerCandidateId: round.winnerCandidateId,
      variants: round.variants,
    },
    report: round.report ?? null,
    scoreReport: round.scoreReport ?? null,
  };
}

function selectManagedExperimentRound(roundsValue: unknown, flags: Record<string, string | boolean>): Record<string, unknown> {
  const rounds = Array.isArray(roundsValue)
    ? roundsValue.map((round) => objectValue(round)).filter((round): round is Record<string, unknown> => Boolean(round))
    : [];
  if (!rounds.length) throw new Error("managed experiment task has no rounds");
  const roundId = optionalString(flags["round-id"] || flags.roundId);
  const roundIndexValue = flags["round-index"] ?? flags.roundIndex;
  const roundValue = flags.round;
  let round: Record<string, unknown> | undefined;
  if (roundId) {
    round = rounds.find((item) => item.id === roundId);
  } else if (roundIndexValue !== undefined) {
    const roundIndex = optionalNonNegativeInteger(roundIndexValue, "roundIndex");
    round = rounds.find((item) => Number(item.roundIndex) === roundIndex);
  } else if (roundValue !== undefined) {
    if (typeof roundValue === "string" && roundValue.startsWith("mxr_")) {
      round = rounds.find((item) => item.id === roundValue);
    } else {
      const roundNumber = optionalPositiveInteger(roundValue, "round");
      round = rounds.find((item) => Number(item.roundIndex) + 1 === roundNumber);
    }
  } else {
    throw new Error("usage: gamealgo experiment managed report <taskId> --round <roundNumber>");
  }
  if (!round) {
    const available = rounds.map((item) => `#${Number(item.roundIndex ?? 0) + 1}:${String(item.id || "")}`).join(", ");
    throw new Error(`managed experiment round not found. available rounds: ${available}`);
  }
  return round;
}

function managedExperimentLightTask(value: unknown) {
  const task = objectValue(value);
  if (!task) return null;
  return {
    id: task.id,
    strategyName: task.strategyName,
    status: task.status,
    cycleDays: task.cycleDays,
    maxVariantsPerRound: task.maxVariantsPerRound,
    objective: task.objective,
    autoApplyWinner: task.autoApplyWinner,
    currentRoundId: task.currentRoundId,
    winnerCandidateId: task.winnerCandidateId,
    createdAt: task.createdAt,
    updatedAt: task.updatedAt,
  };
}

function managedExperimentLightCandidates(value: unknown) {
  if (!Array.isArray(value)) return [];
  return value.map((candidate) => {
    const item = objectValue(candidate);
    if (!item) return null;
    const config = objectValue(item.config);
    return {
      candidateId: item.candidateId,
      status: item.status,
      sortOrder: item.sortOrder,
      configKeys: config ? Object.keys(config) : [],
      script: item.script,
      createdAt: item.createdAt,
      updatedAt: item.updatedAt,
    };
  }).filter(Boolean);
}

function managedExperimentLightRounds(value: unknown) {
  if (!Array.isArray(value)) return [];
  return value.map((round) => {
    const item = objectValue(round);
    if (!item) return null;
    return {
      id: item.id,
      roundIndex: item.roundIndex,
      roundNumber: Number(item.roundIndex ?? 0) + 1,
      status: item.status,
      assignmentStartDt: item.assignmentStartDt,
      assignmentEndDt: item.assignmentEndDt,
      experimentCompletedAt: item.experimentCompletedAt,
      reportGeneratedAt: item.reportGeneratedAt,
      endedAt: item.endedAt,
      evaluatedAt: item.evaluatedAt,
      winnerCandidateId: item.winnerCandidateId,
      hasReport: item.report !== undefined && item.report !== null,
      hasScoreReport: item.scoreReport !== undefined && item.scoreReport !== null,
      variants: Array.isArray(item.variants) ? item.variants.map((variant) => {
        const body = objectValue(variant);
        if (!body) return null;
        return {
          candidateId: body.candidateId,
          variant: body.variant,
          enabled: body.enabled,
          weight: body.weight,
        };
      }).filter(Boolean) : [],
    };
  }).filter(Boolean);
}

function managedExperimentTaskSummary(payload: Record<string, unknown>) {
  const task = objectValue(payload.task);
  const estimate = objectValue(payload.estimate);
  const rounds = Array.isArray(payload.rounds) ? payload.rounds.filter((round) => round && typeof round === "object") as Array<Record<string, unknown>> : [];
  const runningRound = rounds.find((round) => round.status === "running") || rounds[rounds.length - 1] || null;
  const variants = runningRound && Array.isArray(runningRound.variants)
    ? runningRound.variants.map((variant) => objectValue(variant)).filter(Boolean).map((variant) => ({
      candidateId: variant?.candidateId,
      variant: variant?.variant,
    }))
    : [];
  return {
    taskId: task?.id,
    strategyName: task?.strategyName,
    status: task?.status,
    estimate: {
      rounds: estimate?.estimatedRounds,
      cycleDays: estimate?.cycleDays,
      nominalDays: estimate?.nominalDays,
      calendarDays: estimate?.estimatedCalendarDays,
      maxVariantsPerRound: estimate?.maxVariantsPerRound,
      totalCandidates: estimate?.totalCandidates,
    },
    currentRound: runningRound ? {
      id: runningRound.id,
      index: runningRound.roundIndex,
      status: runningRound.status,
      assignmentStartDt: runningRound.assignmentStartDt,
      assignmentEndDt: runningRound.assignmentEndDt,
      experimentCompletedAt: runningRound.experimentCompletedAt,
      reportGeneratedAt: runningRound.reportGeneratedAt,
      variants,
    } : null,
  };
}

function objectValue(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function normalizeExperimentConfigForPublish(file: ExperimentConfigFile) {
  return {
    gameId: file.gameId,
    latestCommitId: file.latestCommitId ?? null,
    strategies: file.strategies,
  };
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

function optionalPositiveInteger(value: unknown, field: string): number | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value === "boolean") throw new Error(`${field} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) throw new Error(`${field} must be a positive integer`);
  return parsed;
}

function optionalNonNegativeInteger(value: unknown, field: string): number | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value === "boolean") throw new Error(`${field} must be a non-negative integer`);
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) throw new Error(`${field} must be a non-negative integer`);
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
  console.log(YAML.stringify(value).trimEnd());
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
  gamealgo experiment managed create managed-experiment.yaml --yes
  gamealgo experiment managed list
  gamealgo experiment managed status mxt_xxxxxxxxxxxxxxxx
  gamealgo experiment managed report mxt_xxxxxxxxxxxxxxxx --round 1
  gamealgo experiment managed cancel mxt_xxxxxxxxxxxxxxxx --yes

  gamealgo key list
  gamealgo key create --name tapmaker-proxy
  gamealgo key reveal --name tapmaker-proxy
  gamealgo key revoke --name tapmaker-proxy --yes

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

  gamealgo events count --from 2026-06-23 --to 2026-06-23
  gamealgo events count --from 2026-06-23 --to 2026-06-23 --event-type level_end

  gamealgo marketing adjust get
  gamealgo marketing adjust configure --api-token <token> --app-token <app-token> --platform ios --currency USD
  gamealgo marketing adjust sync --from 2026-06-01 --to 2026-06-07 --timeout 60

Internal bootstrap:
  gamealgo admin-key create --host <admin-url> --admin-token <root-token> --game Mahjong --name ai-agent
`.trim());
}

await main();
