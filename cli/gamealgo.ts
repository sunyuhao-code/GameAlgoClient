#!/usr/bin/env node
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, basename } from "node:path";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
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

type DocsTopic = {
  id: string;
  title: string;
  summary: string;
  group: string;
  file: string;
  hidden: boolean;
};

type DocsManifest = {
  schemaVersion: number;
  version: string;
  updatedAt: string;
  defaultTopic: string;
  topics: DocsTopic[];
};

type DocsApiPlatform = "lua" | "ios" | "android" | "rest";

type DocsApiEntry = {
  name: string;
  symbols: string[];
  platforms: DocsApiPlatform[];
  summary: string;
  content: string;
};

type CliHelpOption = {
  name: string;
  description: string;
};

type CliHelpCommand = {
  path: string;
  group: string;
  summary: string;
  usage: string;
  description?: string;
  aliases?: string[];
  options?: CliHelpOption[];
  notes?: string[];
  examples?: string[];
  sinceVersion?: string;
  internal?: boolean;
};

type CliHelpCatalog = {
  schemaVersion: 1;
  version: string;
  updatedAt: string;
  cliPackage: string;
  groups: Array<{ id: string; title: string; description?: string }>;
  commonOptions: CliHelpOption[];
  commands: CliHelpCommand[];
};

const GLOBAL_CONFIG_PATH = join(homedir(), ".gamealgo", "cli.json");
const PROJECT_CONFIG_DIR = ".gamealgo";
const PROJECT_CONFIG_FILE = "cli.json";
const DOCS_CACHE_ROOT = join(homedir(), ".gamealgo", "docs");
const DEFAULT_CLI_HELP_HOSTS = [
  "https://game-algo-admin.dictapis.cn",
  "https://dirichlet.ai/algo_admin",
];
const SCRIPT_EXTENSIONS = new Set([".js", ".lua"]);
const FILE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const global = parseGlobalFlags(args);
  const command = args.shift();
  if (command === "version" || command === "--version" || command === "-V") {
    const metadata = await loadPackageMetadata();
    if (global.json) {
      await printResult({ ok: true, name: metadata.name, version: metadata.version }, global);
    } else {
      console.log(metadata.version);
    }
    return;
  }

  try {
    if (!command || command === "help" || command === "--help" || command === "-h") {
      await handleHelp(args, global);
      return;
    }
    const helpFlagIndex = args.findIndex((arg) => arg === "--help" || arg === "-h");
    if (helpFlagIndex >= 0) {
      args.splice(helpFlagIndex, 1);
      await handleHelp([command, ...args], global);
      return;
    }
    if (command === "login") {
      await login(args, global);
      return;
    }
    if (command === "whoami") {
      const client = await createClient(global);
      await printResult(await client.session(), global);
      return;
    }
    if (command === "docs") {
      await handleDocs(args, global);
      return;
    }
    if (command === "listapi") {
      await handleDocs(["api", "list", ...args], global);
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
    if (command === "integration") {
      await handleIntegration(client, args, global);
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

async function handleHelp(args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const flags = parseFlags(args);
  const query = normalizeCliHelpQuery(args.join(" "));
  const saved = await loadConfig();
  const configuredHost = normalizeHost(global.host || saved?.host || "");
  const loaded = await loadCliHelpCatalog(configuredHost ? [configuredHost] : DEFAULT_CLI_HELP_HOSTS);
  const packageMetadata = await loadPackageMetadata();
  const visibleCommands = loaded.catalog.commands.filter((command) => !command.internal);
  const selection = selectCliHelpCommands(visibleCommands, query);
  if (!selection.length) {
    const suggestions = suggestCliHelpCommands(visibleCommands, query);
    const suffix = suggestions.length ? ` Did you mean: ${suggestions.join(", ")}` : "";
    throw new Error(`Unknown CLI command: ${query}.${suffix}`);
  }

  const detail = query && selection.length === 1 && cliHelpCommandMatchesInvocation(selection[0], query)
    ? selection[0]
    : undefined;
  const markdown = detail
    ? formatCliHelpCommand(detail, loaded.catalog.commonOptions)
    : formatCliHelpIndex(loaded.catalog, selection, query);
  const out = optionalString(flags.out);
  if (flags.out === true) throw new Error("--out requires a file path");
  if (out) {
    const payload = out.toLowerCase().endsWith(".json")
      ? `${JSON.stringify(cliHelpResult(loaded, packageMetadata.version, query, selection, detail), null, 2)}\n`
      : `${markdown.trimEnd()}\n`;
    await writeTextFile(out, payload);
    await printResult({ ok: true, out, source: loaded.url, version: loaded.catalog.version }, global);
    return;
  }
  if (global.json) {
    await printResult(cliHelpResult(loaded, packageMetadata.version, query, selection, detail), global);
    return;
  }
  console.log(markdown.trimEnd());
}

async function loadCliHelpCatalog(hosts: string[]): Promise<{ catalog: CliHelpCatalog; host: string; url: string }> {
  const failures: string[] = [];
  for (const candidate of hosts) {
    const host = normalizeHost(candidate);
    const url = `${docsContentBaseUrl(host)}cli-commands.json`;
    try {
      return { catalog: parseCliHelpCatalog(await requestLiveTextUrl(url)), host, url };
    } catch (error) {
      failures.push(`${host}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  throw new Error(`Unable to load the current CLI help from the Server. ${failures.join(" | ")}`);
}

async function requestLiveTextUrl(url: string): Promise<string> {
  let response: Response;
  try {
    response = await fetch(url, {
      cache: "no-store",
      headers: { "Cache-Control": "no-cache" },
      signal: AbortSignal.timeout(10_000),
    });
  } catch (error) {
    if (isTimeoutError(error)) throw new Error(`Help request timed out: ${url}`);
    throw new Error(`Help request failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  const text = await response.text();
  if (!response.ok) throw new Error(`Help request returned ${response.status}: ${truncateBody(text)}`);
  return text;
}

function parseCliHelpCatalog(text: string): CliHelpCatalog {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error("CLI command catalog is not valid JSON");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("CLI command catalog must be an object");
  }
  const body = value as Record<string, unknown>;
  if (body.schemaVersion !== 1 || !Array.isArray(body.groups) || !Array.isArray(body.commands)) {
    throw new Error("CLI command catalog schema is invalid");
  }
  const groups = body.groups.map((item) => {
    const group = objectValue(item);
    const id = optionalString(group?.id);
    const title = optionalString(group?.title);
    if (!id || !title) throw new Error("CLI command catalog contains an invalid group");
    return { id, title, description: optionalString(group?.description) };
  });
  const groupIds = new Set(groups.map((group) => group.id));
  const commands = body.commands.map((item) => parseCliHelpCommand(item, groupIds));
  const paths = new Set(commands.map((command) => normalizeCliHelpQuery(command.path)));
  if (paths.size !== commands.length) throw new Error("CLI command catalog contains duplicate command paths");
  const commonOptions = Array.isArray(body.commonOptions)
    ? body.commonOptions.map((item) => parseCliHelpOption(item, "common option"))
    : [];
  return {
    schemaVersion: 1,
    version: String(body.version || "current"),
    updatedAt: String(body.updatedAt || ""),
    cliPackage: String(body.cliPackage || "gamealgo-cli"),
    groups,
    commonOptions,
    commands,
  };
}

function parseCliHelpCommand(value: unknown, groupIds: Set<string>): CliHelpCommand {
  const command = objectValue(value);
  const path = optionalString(command?.path);
  const group = optionalString(command?.group);
  const summary = optionalString(command?.summary);
  const usage = optionalString(command?.usage);
  if (!path || !group || !summary || !usage || !groupIds.has(group)) {
    throw new Error(`CLI command catalog contains an invalid command: ${path || "unknown"}`);
  }
  const options = Array.isArray(command?.options)
    ? command.options.map((item) => parseCliHelpOption(item, path))
    : undefined;
  return {
    path,
    group,
    summary,
    usage,
    description: optionalString(command?.description),
    aliases: stringArray(command?.aliases),
    options,
    notes: stringArray(command?.notes),
    examples: stringArray(command?.examples),
    sinceVersion: optionalString(command?.sinceVersion),
    internal: command?.internal === true,
  };
}

function parseCliHelpOption(value: unknown, owner: string): CliHelpOption {
  const option = objectValue(value);
  const name = optionalString(option?.name);
  const description = optionalString(option?.description);
  if (!name || !description) throw new Error(`CLI command catalog contains an invalid option for ${owner}`);
  return { name, description };
}

function stringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const result = value.map(optionalString).filter((item): item is string => Boolean(item));
  return result.length ? result : undefined;
}

function normalizeCliHelpQuery(value: string): string {
  return value.trim().replace(/^gamealgo\s+/i, "").replace(/\s+/g, " ").toLowerCase();
}

function selectCliHelpCommands(commands: CliHelpCommand[], query: string): CliHelpCommand[] {
  if (!query) return commands;
  const exact = commands.filter((command) => (
    normalizeCliHelpQuery(command.path) === query
    || command.aliases?.some((alias) => normalizeCliHelpQuery(alias) === query)
  ));
  if (exact.length) return exact;

  const invocationMatches = commands
    .filter((command) => cliHelpCommandMatchesInvocation(command, query))
    .sort((left, right) => normalizeCliHelpQuery(right.path).length - normalizeCliHelpQuery(left.path).length);
  if (invocationMatches.length) return [invocationMatches[0]];

  return commands.filter((command) => (
    normalizeCliHelpQuery(command.path).startsWith(`${query} `)
    || command.aliases?.some((alias) => normalizeCliHelpQuery(alias).startsWith(`${query} `))
  ));
}

function cliHelpCommandMatchesInvocation(command: CliHelpCommand, query: string): boolean {
  const paths = [command.path, ...(command.aliases || [])].map(normalizeCliHelpQuery);
  return paths.some((path) => query === path || query.startsWith(`${path} `));
}

function suggestCliHelpCommands(commands: CliHelpCommand[], query: string): string[] {
  return commands
    .map((command) => ({ command, score: docsApiSimilarity(query, normalizeCliHelpQuery(command.path)) }))
    .filter((item) => item.score >= 0.35)
    .sort((left, right) => right.score - left.score)
    .slice(0, 5)
    .map((item) => item.command.path);
}

function formatCliHelpIndex(catalog: CliHelpCatalog, commands: CliHelpCommand[], query: string): string {
  const lines = [`# GameAlgo CLI 命令`, "", `目录版本：${catalog.version} · 更新于 ${catalog.updatedAt}`, ""];
  for (const group of catalog.groups) {
    const grouped = commands.filter((command) => command.group === group.id);
    if (!grouped.length) continue;
    lines.push(`## ${group.title}`, "");
    if (group.description) lines.push(group.description, "");
    for (const command of grouped) lines.push(`- \`gamealgo ${command.path}\`：${command.summary}`);
    lines.push("");
  }
  if (query) lines.push(`继续查询：\`gamealgo help <完整命令>\``);
  else lines.push("查询单条命令：`gamealgo help <命令路径>`");
  lines.push("显式保存当次最新文档：`gamealgo help --out gamealgo-cli-help.md`");
  return lines.join("\n");
}

function formatCliHelpCommand(command: CliHelpCommand, commonOptions: CliHelpOption[]): string {
  const lines = [
    `# gamealgo ${command.path}`,
    "",
    command.summary,
    "",
    "## 用法",
    "",
    "```bash",
    command.usage,
    "```",
  ];
  if (command.description) lines.push("", "## 说明", "", command.description);
  const options = [...(command.options || []), ...commonOptions];
  if (options.length) {
    lines.push("", "## 参数与选项", "");
    for (const option of options) lines.push(`- \`${option.name}\`：${option.description}`);
  }
  if (command.notes?.length) {
    lines.push("", "## 约束", "");
    for (const note of command.notes) lines.push(`- ${note}`);
  }
  if (command.examples?.length) {
    lines.push("", "## 示例", "");
    for (const example of command.examples) lines.push("```bash", example, "```");
  }
  return lines.join("\n");
}

function cliHelpResult(
  loaded: { catalog: CliHelpCatalog; host: string; url: string },
  cliVersion: string,
  query: string,
  commands: CliHelpCommand[],
  detail?: CliHelpCommand,
) {
  return {
    ok: true,
    cliVersion,
    catalogVersion: loaded.catalog.version,
    updatedAt: loaded.catalog.updatedAt,
    source: loaded.url,
    query: query || null,
    ...(detail ? { command: detail, commonOptions: loaded.catalog.commonOptions } : { commands }),
  };
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
  const configPath = await saveConfig({ host, adminKey });
  await printResult({
    ok: true,
    host,
    gameId: session.principal.gameId,
    keyName: session.principal.keyName,
    configPath,
  }, global);
}

async function handleDocs(args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const flags = parseFlags(args);
  const topicId = String(args.shift() || "").trim();
  const apiQuery = topicId === "api" ? args.join(" ").trim() : "";
  if (topicId !== "api" && args.length) {
    throw new Error("usage: gamealgo docs [topic] [--open] [--json] [--host <admin-url>]");
  }

  const saved = await loadConfig();
  const host = normalizeHost(global.host || saved?.host || "");
  if (!host) throw new Error("--host is required before login; after login the saved Admin host is used");

  const loaded = await loadDocsManifest(host);
  const manifest = loaded.manifest;
  const visibleTopics = manifest.topics.filter((item) => !item.hidden);
  const resolvedTopicId = topicId === "api" ? "public-sdk-api" : topicId;
  const topic = resolvedTopicId
    ? manifest.topics.find((item) => item.id === resolvedTopicId && (topicId === "api" || !item.hidden))
    : null;
  if (topicId && !topic) {
    if (topicId === "api") {
      throw new Error("The Admin host does not publish the public SDK API index yet");
    }
    throw new Error(`Unknown docs topic: ${topicId}. Available topics: ${visibleTopics.map((item) => item.id).join(", ")}`);
  }

  const webUrl = docsWebUrl(host, topic?.id);
  if (flags.open) {
    openExternalUrl(webUrl);
    await printResult({
      ok: true,
      opened: webUrl,
      version: manifest.version,
      ...(topic ? { topic: topic.id, title: topic.title } : {}),
      cachedManifest: loaded.cached,
    }, global);
    return;
  }

  if (!topic) {
    if (global.json) {
      await printResult({
        ok: true,
        version: manifest.version,
        updatedAt: manifest.updatedAt,
        defaultTopic: manifest.defaultTopic,
        cached: loaded.cached,
        webUrl,
        topics: visibleTopics,
      }, global);
      return;
    }
    printDocsIndex(manifest, webUrl);
    if (loaded.cached) console.error("Warning: using cached documentation index because the Admin host could not be reached");
    return;
  }

  const document = await loadDocsDocument(host, manifest, topic, loaded.cached);
  if (topicId === "api") {
    await printDocsApiResult({
      query: apiQuery,
      platform: parseDocsApiPlatform(flags.platform),
      manifest,
      topic,
      document,
      webUrl,
      host,
      global,
    });
    return;
  }
  if (global.json) {
    await printResult({
      ok: true,
      version: manifest.version,
      updatedAt: manifest.updatedAt,
      topic: topic.id,
      title: topic.title,
      summary: topic.summary,
      cached: document.cached,
      webUrl,
      rawUrl: docsRawUrl(host, topic.file),
      content: document.content,
    }, global);
    return;
  }
  console.log(document.content.trimEnd());
  if (document.cached) console.error("Warning: using cached documentation because the Admin host could not be reached");
}

function parseDocsApiPlatform(value: string | boolean | undefined): DocsApiPlatform | undefined {
  if (value === undefined || value === false || value === "") return undefined;
  const platform = String(value).trim().toLowerCase();
  if (platform === "maker") return "lua";
  if (platform === "lua" || platform === "ios" || platform === "android" || platform === "rest") {
    return platform;
  }
  throw new Error("--platform must be lua, maker, ios, android, or rest");
}

async function printDocsApiResult(options: {
  query: string;
  platform?: DocsApiPlatform;
  manifest: DocsManifest;
  topic: DocsTopic;
  document: { content: string; cached: boolean };
  webUrl: string;
  host: string;
  global: ReturnType<typeof parseGlobalFlags>;
}): Promise<void> {
  const { query, platform, manifest, topic, document, webUrl, host, global } = options;
  const entries = parseDocsApiEntries(document.content).filter((entry) => !platform || entry.platforms.includes(platform));
  if (!entries.length) {
    throw new Error(platform ? `No public SDK APIs are documented for platform: ${platform}` : "Public SDK API document has no indexed entries");
  }

  const normalizedQuery = normalizeDocsApiQuery(query);
  const listMode = !normalizedQuery || normalizedQuery === "list" || normalizedQuery === "ls";
  if (listMode) {
    if (global.json) {
      await printResult({
        ok: true,
        version: manifest.version,
        updatedAt: manifest.updatedAt,
        topic: topic.id,
        cached: document.cached,
        webUrl,
        rawUrl: docsRawUrl(host, topic.file),
        ...(platform ? { platform } : {}),
        apis: entries.map(({ name, symbols, platforms, summary }) => ({ name, symbols, platforms, summary })),
      }, global);
      return;
    }
    console.log(`GameAlgo 公开 SDK API ${manifest.version}${platform ? ` · ${platform}` : ""}`);
    for (const entry of entries) {
      console.log(`\n${entry.name}  [${entry.platforms.join(", ")}]`);
      console.log(`  ${entry.symbols.join(" / ")}`);
      console.log(`  ${entry.summary}`);
    }
    console.log(`\n查询函数: gamealgo docs api <函数名>${platform ? ` --platform ${platform}` : ""}`);
    if (document.cached) console.error("Warning: using cached documentation because the Admin host could not be reached");
    return;
  }

  const matches = findDocsApiEntries(entries, query);
  if (!matches.length) {
    const suggestions = suggestDocsApiEntries(entries, query);
    const suffix = suggestions.length ? ` Did you mean: ${suggestions.join(", ")}` : "";
    throw new Error(`Unknown public SDK API: ${query}.${suffix}`);
  }
  if (global.json) {
    await printResult({
      ok: true,
      version: manifest.version,
      updatedAt: manifest.updatedAt,
      topic: topic.id,
      query,
      cached: document.cached,
      webUrl,
      rawUrl: docsRawUrl(host, topic.file),
      ...(platform ? { platform } : {}),
      matches,
    }, global);
    return;
  }
  console.log(matches.map((entry) => entry.content.trim()).join("\n\n"));
  if (document.cached) console.error("Warning: using cached documentation because the Admin host could not be reached");
}

function parseDocsApiEntries(content: string): DocsApiEntry[] {
  const headings = [...content.matchAll(/^###\s+(.+)$/gm)];
  const entries: DocsApiEntry[] = [];
  for (let index = 0; index < headings.length; index += 1) {
    const heading = headings[index];
    const start = heading.index ?? 0;
    const end = headings[index + 1]?.index ?? content.length;
    const section = content.slice(start, end).trim();
    const symbols = parseDocsApiMetadataList(section, "API");
    if (!symbols.length) continue;
    const platforms = parseDocsApiMetadataList(section, "平台")
      .map((item) => item.toLowerCase())
      .filter((item): item is DocsApiPlatform => item === "lua" || item === "ios" || item === "android" || item === "rest");
    const summaryMatch = section.match(/^-\s*用途[：:]\s*(.+)$/m);
    entries.push({
      name: stripInlineMarkdown(heading[1]),
      symbols,
      platforms: [...new Set(platforms)],
      summary: stripInlineMarkdown(summaryMatch?.[1] || ""),
      content: section,
    });
  }
  return entries;
}

function parseDocsApiMetadataList(section: string, key: string): string[] {
  const match = section.match(new RegExp(`^-\\s*${key}[：:]\\s*(.+)$`, "m"));
  if (!match) return [];
  const inlineCode = [...match[1].matchAll(/`([^`]+)`/g)].map((item) => item[1].trim()).filter(Boolean);
  if (inlineCode.length) return inlineCode;
  return match[1].split(/[,，]/).map((item) => stripInlineMarkdown(item)).filter(Boolean);
}

function stripInlineMarkdown(value: string): string {
  return value.replace(/[`*]/g, "").trim();
}

function normalizeDocsApiQuery(value: string): string {
  return stripInlineMarkdown(value)
    .replace(/\(.*\)$/, "")
    .replace(/\s+/g, "")
    .toLowerCase();
}

function docsApiSearchTerms(entry: DocsApiEntry): string[] {
  return [entry.name, ...entry.symbols, ...entry.symbols.map((symbol) => symbol.split(/[.#]/).pop() || symbol)]
    .map(normalizeDocsApiQuery)
    .filter(Boolean);
}

function findDocsApiEntries(entries: DocsApiEntry[], query: string): DocsApiEntry[] {
  const needle = normalizeDocsApiQuery(query);
  const exact = entries.filter((entry) => docsApiSearchTerms(entry).includes(needle));
  if (exact.length) return exact;
  return entries.filter((entry) => (
    docsApiSearchTerms(entry).some((term) => term.includes(needle))
    || normalizeDocsApiQuery(entry.summary).includes(needle)
  ));
}

function suggestDocsApiEntries(entries: DocsApiEntry[], query: string): string[] {
  const needle = normalizeDocsApiQuery(query);
  return entries
    .map((entry) => {
      const terms = docsApiSearchTerms(entry);
      const score = Math.max(...terms.map((term) => docsApiSimilarity(needle, term)));
      return { entry, score };
    })
    .filter((item) => item.score >= 0.35)
    .sort((left, right) => right.score - left.score)
    .slice(0, 5)
    .map(({ entry }) => entry.symbols[0] || entry.name);
}

function docsApiSimilarity(left: string, right: string): number {
  if (!left || !right) return 0;
  if (left.includes(right) || right.includes(left)) {
    return Math.min(left.length, right.length) / Math.max(left.length, right.length) + 0.5;
  }
  const previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let leftIndex = 1; leftIndex <= left.length; leftIndex += 1) {
    const current = [leftIndex];
    for (let rightIndex = 1; rightIndex <= right.length; rightIndex += 1) {
      const substitution = previous[rightIndex - 1] + (left[leftIndex - 1] === right[rightIndex - 1] ? 0 : 1);
      current[rightIndex] = Math.min(previous[rightIndex] + 1, current[rightIndex - 1] + 1, substitution);
    }
    previous.splice(0, previous.length, ...current);
  }
  return 1 - previous[right.length] / Math.max(left.length, right.length);
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
  if (sub === "strategies" || sub === "list") {
    const flags = parseFlags(args);
    await printResult(await client.listExperimentV2Strategies(Boolean(flags["include-archived"] || flags.archived)), global);
    return;
  }
  if (sub === "strategy") {
    await handleExperimentStrategy(client, args, global);
    return;
  }
  if (sub === "run") {
    await handleExperimentRun(client, args, global);
    return;
  }
  if (sub === "override") {
    await handleExperimentOverride(client, args, global);
    return;
  }
  if (sub === "integration-version") {
    await handleExperimentIntegrationVersion(client, args, global);
    return;
  }
  throw new Error("usage: gamealgo experiment <strategies|strategy|run|override|integration-version>");
}

async function handleExperimentIntegrationVersion(
  client: GameAlgoAdminClient,
  args: string[],
  global: ReturnType<typeof parseGlobalFlags>,
): Promise<void> {
  const sub = args.shift();
  const flags = parseFlags(args);
  if (sub === "latest") {
    await printResult(await client.getLatestExperimentIntegrationVersion(), global);
    return;
  }
  if (sub === "list") {
    const limit = optionalNonNegativeInteger(flags.limit, "--limit") ?? 100;
    await printResult(await client.listExperimentIntegrationVersions(limit), global);
    return;
  }
  if (sub === "get" || sub === "show") {
    const version = positiveInteger(flags.version || args.shift(), "version");
    await printResult(await client.getExperimentIntegrationVersion(version), global);
    return;
  }
  if (sub === "create") {
    const title = optionalString(flags.title);
    const message = optionalString(flags.message);
    if (!title || !message) {
      throw new Error("usage: gamealgo experiment integration-version create --title <title> --message <message>");
    }
    await printResult(await client.createExperimentIntegrationVersion(title, message), global);
    return;
  }
  if (sub === "update") {
    const version = positiveInteger(flags.version || args.shift(), "version");
    const message = optionalString(flags.message);
    if (!message) {
      throw new Error("usage: gamealgo experiment integration-version update --version <version> --message <message>");
    }
    await printResult(await client.updateExperimentIntegrationVersion(version, message), global);
    return;
  }
  throw new Error("usage: gamealgo experiment integration-version <latest|list|get|create|update>");
}

async function handleExperimentStrategy(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "show" || sub === "get") {
    const flags = parseFlags(args);
    const strategyKey = optionalString(flags.strategy || flags.key) || optionalString(args.shift());
    if (!strategyKey) throw new Error("usage: gamealgo experiment strategy show <strategyKey>");
    const response = await client.getExperimentV2Strategy(strategyKey);
    if (flags.out) {
      await writeTextFile(String(flags.out), YAML.stringify(response));
      await printResult({ ok: true, out: String(flags.out), strategyKey }, global);
      return;
    }
    await printResult(response, global);
    return;
  }
  if (sub === "publish" || sub === "upsert") {
    const flags = parseFlags(args);
    const filePath = optionalString(flags.file || flags.input) || optionalString(args.shift());
    if (!filePath) throw new Error("usage: gamealgo experiment strategy publish <strategy.yaml> --yes");
    await requireYes(flags, global, "experiment strategy publish");
    const body = await readObjectFile(filePath, "experiment strategy");
    if (!optionalString(body.displayName)) {
      throw new Error("experiment strategy requires displayName");
    }
    if (!optionalString(body.strategyKey || body.key)) {
      throw new Error("experiment strategy requires strategyKey");
    }
    const requiredIntegrationVersion = optionalNonNegativeInteger(body.requiredIntegrationVersion, "requiredIntegrationVersion");
    if (requiredIntegrationVersion === undefined) {
      throw new Error("experiment strategy requires explicit requiredIntegrationVersion; use 0 when no client integration version is required");
    }
    const response = await client.upsertExperimentV2Strategy(body);
    await printResult(response, global);
    return;
  }
  if (sub === "default") {
    const flags = parseFlags(args);
    const strategyKey = optionalString(flags.strategy || flags.key) || optionalString(args.shift());
    const filePath = optionalString(flags.file || flags.input) || optionalString(args.shift());
    if (!strategyKey || !filePath) throw new Error("usage: gamealgo experiment strategy default <strategyKey> <strategy.yaml> --yes");
    await requireYes(flags, global, "experiment strategy default");
    const response = await client.updateExperimentV2StrategyDefault(strategyKey, await readObjectFile(filePath, "experiment strategy default"));
    await printResult(response, global);
    return;
  }
  if (sub === "archive" || sub === "restore") {
    const flags = parseFlags(args);
    const strategyKey = optionalString(flags.strategy || flags.key) || optionalString(args.shift());
    if (!strategyKey) throw new Error(`usage: gamealgo experiment strategy ${sub} <strategyKey> --yes`);
    await requireYes(flags, global, `experiment strategy ${sub}`);
    await printResult(await client.archiveExperimentV2Strategy(strategyKey, sub === "archive"), global);
    return;
  }
  if (sub === "rollback") {
    const flags = parseFlags(args);
    const strategyKey = optionalString(flags.strategy || flags.key) || optionalString(args.shift());
    const versionId = optionalString(flags.version || flags["version-id"]);
    const message = requiredMessage(flags, "experiment strategy rollback");
    if (!strategyKey || !versionId) {
      throw new Error("usage: gamealgo experiment strategy rollback <strategyKey> --version-id <versionId> --message <reason> --yes");
    }
    await requireYes(flags, global, "experiment strategy rollback");
    await printResult(await client.rollbackExperimentV2Strategy(strategyKey, versionId, message), global);
    return;
  }
  throw new Error("usage: gamealgo experiment strategy <show|publish|default|archive|restore|rollback>");
}

async function handleExperimentRun(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "create") {
    const flags = parseFlags(args);
    const strategyKey = optionalString(flags.strategy || flags.key) || optionalString(args.shift());
    const filePath = optionalString(flags.file || flags.input) || optionalString(args.shift());
    if (!strategyKey || !filePath) throw new Error("usage: gamealgo experiment run create <strategyKey> <run.yaml> [--manual] --yes");
    await requireYes(flags, global, "experiment run create");
    const body = await readObjectFile(filePath, "experiment run");
    if (!optionalString(body.displayName)) throw new Error("experiment run requires displayName");
    const objectiveTemplate = optionalString(body.objectiveTemplate);
    if (!objectiveTemplate || !["ltv_proxy@1", "active_days@1"].includes(objectiveTemplate)) {
      throw new Error("experiment run requires objectiveTemplate: ltv_proxy@1 or active_days@1");
    }
    if (!optionalString(body.baselineVariantId)) {
      throw new Error("experiment run requires explicit baselineVariantId");
    }
    validateExperimentRunVariantScripts(body.variants);
    const fileRunType = optionalString(body.type);
    const flagRunType = optionalString(flags.type);
    const manualFlag = flags.manual === true;
    if (fileRunType && fileRunType !== "managed" && fileRunType !== "manual") {
      throw new Error("experiment run type must be managed or manual");
    }
    if (flagRunType && flagRunType !== "managed" && flagRunType !== "manual") {
      throw new Error("--type must be managed or manual");
    }
    if (manualFlag && flagRunType && flagRunType !== "manual") {
      throw new Error("--manual conflicts with --type managed");
    }
    const requestedRunType = manualFlag ? "manual" : flagRunType;
    if (requestedRunType && fileRunType && requestedRunType !== fileRunType) {
      throw new Error(`experiment run type conflict: file uses ${fileRunType}, CLI requests ${requestedRunType}`);
    }
    const runType = requestedRunType || fileRunType || "managed";
    body.type = runType;
    if (runType !== "managed" && body.startCondition !== undefined) {
      throw new Error("experiment run startCondition is supported only when type is managed");
    }
    if (runType === "managed") {
      const minWindowDays = Number(body.minWindowDays);
      const maxWindowDays = Number(body.maxWindowDays);
      if (!Number.isInteger(minWindowDays) || minWindowDays < 1 || minWindowDays > 30) {
        throw new Error("managed experiment run requires minWindowDays between 1 and 30");
      }
      if (!Number.isInteger(maxWindowDays) || maxWindowDays < minWindowDays || maxWindowDays > 60) {
        throw new Error("managed experiment run requires maxWindowDays between minWindowDays and 60");
      }
    } else {
      process.stderr.write("Warning: creating a manual experiment. The platform will not automatically extend, conclude, or promote it; use manual mode only when the developer will manage the experiment decision.\n");
    }
    const result = await client.createExperimentV2Run(strategyKey, body);
    await printResult(result, global);
    if (!global.json) printExperimentRunVariantScripts(result);
    return;
  }
  if (sub === "show" || sub === "get") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    if (!runId) throw new Error("usage: gamealgo experiment run show <runId>");
    const response = await client.getExperimentV2Run(runId);
    if (flags.out) {
      await writeTextFile(String(flags.out), YAML.stringify(response));
      await printResult({ ok: true, out: String(flags.out), runId }, global);
      return;
    }
    await printResult(response, global);
    return;
  }
  if (sub === "status") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    if (!runId) throw new Error("usage: gamealgo experiment run status <runId>");
    const response = await client.getExperimentV2Run(runId) as { run?: Record<string, unknown> };
    const run = response.run;
    if (!run) throw new Error(`experiment run not found: ${runId}`);
    await printResult({
      run: {
        id: run.id,
        strategyKey: run.strategyKey,
        displayName: run.displayName,
        type: run.type,
        status: run.status,
        objective: run.objective,
        baselineVariantId: run.baselineVariantId,
        requiredIntegrationVersion: run.requiredIntegrationVersion,
        startedAt: run.startedAt,
        endedAt: run.endedAt,
        promotedVariantId: run.promotedVariantId,
        currentAssessment: run.currentAssessment ?? null,
      },
    }, global);
    return;
  }
  if (sub === "evaluate") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    if (!runId) throw new Error("usage: gamealgo experiment run evaluate <runId> --from YYYY-MM-DD --to YYYY-MM-DD --yes");
    await requireYes(flags, global, "experiment run evaluate");
    await printResult(await client.evaluateExperimentV2Run(runId, {
      from: optionalString(flags.from || flags.start || flags.startDate),
      to: optionalString(flags.to || flags.end || flags.endDate),
      days: optionalString(flags.days),
    }), global);
    return;
  }
  if (sub === "report") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    if (!runId) throw new Error("usage: gamealgo experiment run report <runId> [--round <number> | --report-id <id>]");
    const response = await client.getExperimentV2Run(runId) as { run?: { reports?: unknown[] } };
    const reports = Array.isArray(response.run?.reports) ? response.run.reports : [];
    const reportId = optionalString(flags.report || flags["report-id"] || flags.id);
    const round = flags.round === undefined ? undefined : positiveInteger(flags.round, "round");
    const latestReport = objectValue(reports[reports.length - 1]);
    const report = reports
      .map((item) => objectValue(item))
      .find((item) => {
        if (!item) return false;
        if (reportId) return item.id === reportId || item.evaluationId === reportId;
        if (round !== undefined) {
          const managed = objectValue(objectValue(item.report)?.managed);
          return Number(managed?.roundNumber ?? Number(managed?.roundIndex) + 1) === round;
        }
        return item === latestReport;
      });
    if (!report) {
      const selector = reportId ? `: ${reportId}` : round !== undefined ? ` for round ${round}` : "";
      throw new Error(`experiment run report not found${selector}`);
    }
    await printResult({ runId, report }, global);
    return;
  }
  if (sub === "objective") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    const objectiveTemplate = optionalString(flags.objective || flags["objective-template"]);
    if (!runId || !objectiveTemplate) {
      throw new Error("usage: gamealgo experiment run objective <runId> --objective <ltv_proxy@1|active_days@1> --message <reason> --yes");
    }
    if (!["ltv_proxy@1", "active_days@1"].includes(objectiveTemplate)) {
      throw new Error("experiment objective must be ltv_proxy@1 or active_days@1");
    }
    const message = requiredMessage(flags, "experiment run objective");
    await requireYes(flags, global, "experiment run objective");
    await printResult(await client.updateExperimentV2RunObjective(runId, objectiveTemplate, message), global);
    return;
  }
  if (sub === "promote") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    const variantId = optionalString(flags.variant || flags["variant-id"]) || optionalString(args.shift());
    if (!runId || !variantId) throw new Error("usage: gamealgo experiment run promote <runId> --variant <variantId> --message <reason> --yes");
    const message = requiredMessage(flags, "experiment run promote");
    await requireYes(flags, global, "experiment run promote");
    await printResult(await client.promoteExperimentV2Run(runId, variantId, message), global);
    return;
  }
  if (sub === "cancel") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    if (!runId) throw new Error("usage: gamealgo experiment run cancel <runId> --message <reason> --yes");
    const message = requiredMessage(flags, "experiment run cancel");
    await requireYes(flags, global, "experiment run cancel");
    await printResult(await client.cancelExperimentV2Run(runId, message), global);
    return;
  }
  throw new Error("usage: gamealgo experiment run <create|show|status|evaluate|report|objective|promote|cancel>");
}

function requiredMessage(flags: Record<string, string | boolean>, action: string): string {
  const message = optionalString(flags.message);
  if (!message) throw new Error(`${action} requires --message <reason>`);
  return message;
}

async function handleExperimentOverride(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "list") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    if (!runId) throw new Error("usage: gamealgo experiment override list <runId>");
    await printResult(await client.listExperimentV2Overrides(runId), global);
    return;
  }
  if (sub === "set") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    const userId = optionalString(flags.user || flags["user-id"] || flags.device || flags["device-id"]);
    const variantId = optionalString(flags.variant || flags["variant-id"]);
    if (!runId || !userId || !variantId) throw new Error("usage: gamealgo experiment override set <runId> --user <userId> --variant <variantId> --yes");
    await requireYes(flags, global, "experiment override set");
    await printResult(await client.upsertExperimentV2Override(runId, userId, variantId), global);
    return;
  }
  if (sub === "delete" || sub === "remove") {
    const flags = parseFlags(args);
    const runId = optionalString(flags.run || flags["run-id"] || flags.id) || optionalString(args.shift());
    const userId = optionalString(flags.user || flags["user-id"] || flags.device || flags["device-id"]);
    if (!runId || !userId) throw new Error(`usage: gamealgo experiment override ${sub} <runId> --user <userId> --yes`);
    await requireYes(flags, global, `experiment override ${sub}`);
    await printResult(await client.deleteExperimentV2Override(runId, userId), global);
    return;
  }
  throw new Error("usage: gamealgo experiment override <list|set|delete>");
}

async function requireYes(flags: Record<string, string | boolean>, global: ReturnType<typeof parseGlobalFlags>, action: string): Promise<void> {
  if (flags.yes) return;
  if (global.json) {
    throw new Error(`${action} requires --yes in --json mode`);
  }
  if (!isInteractive()) {
    throw new Error(`${action} requires --yes in non-interactive mode`);
  }
  const ok = await confirm(`Run ${action}?`);
  if (!ok) {
    throw new Error(`${action} cancelled`);
  }
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
    if (isScript) {
      const flags = parseFlags(args);
      await printResult(await client.listScriptVersions(optionalString(flags.name), Number(flags.limit || 50)), global);
      return;
    }
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
    if (isScript) {
      const list = all
        ? latestScriptVersionNames((await client.listScriptVersions(undefined, Number(flags.limit || 500))).scriptVersions)
        : names.map((name) => sanitizeRemoteFileName(name));
      const pulled: string[] = [];
      for (const name of list) {
        const versions = (await client.listScriptVersions(name, 1)).scriptVersions;
        const latest = versions[0];
        if (!latest) throw new Error(`script version not found: ${name}`);
        const file = await client.getScriptVersion(name, latest.versionId);
        const fileName = sanitizeRemoteFileName(file.scriptVersion.name);
        const target = join(outDir, fileName);
        await writeTextFile(target, file.scriptVersion.content);
        pulled.push(target);
      }
      await printResult({ ok: true, files: pulled }, global);
      return;
    }
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
      if (isScript) {
        const result = await client.createScriptVersion(name, content, contentTypeForFileName(name), optionalString(flags.message));
        published.push(result.scriptVersion);
        continue;
      }
      if (!isScript && (name.toLowerCase().endsWith(".json") || filePath.toLowerCase().endsWith(".json"))) {
        validateJsonText(content, filePath);
      }
      const result = await client.putConfigFile(name, content, contentTypeForFileName(name));
      published.push(result.configFile);
    }
    await printResult(isScript ? { ok: true, scriptVersions: published } : { ok: true, files: published }, global);
    return;
  }
  if (isScript && (sub === "versions" || sub === "version")) {
    const flags = parseFlags(args);
    const name = optionalString(flags.name) || optionalString(args.shift());
    if (!name) throw new Error("usage: gamealgo script versions <name> [--limit 20]");
    await printResult(await client.listScriptVersions(sanitizeRemoteFileName(name), Number(flags.limit || 50)), global);
    return;
  }
  throw new Error(`usage: gamealgo ${resource} <list|pull|publish>`);
}

async function handleReport(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  if (sub === "pull") {
    const flags = parseFlags(args);
    const pack = await client.getReportPack();
    const out = String(flags.out || "gamealgo-report-pack-v1.json");
    await writeTextFile(out, JSON.stringify(pack.reportPack.content, null, 2) + "\n");
    await printResult({ ok: true, out }, global);
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
    parseFlags(args);
    const content = await readJsonFile(filePath);
    const response = await client.putReportPack(content);
    await printResult({ ok: true, validation: response.reportPack.validation }, global);
    return;
  }
  if (sub === "manifest" || sub === "list") {
    parseFlags(args);
    await printResult(await client.reportManifest(), global);
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
  const flags = parseFlags(args);
  if (sub === "list") {
    if (args.length) throw new Error("usage: gamealgo events list [--days 30] [--no-diagnostics]");
    const days = Number(flags.days || 30);
    if (!Number.isInteger(days) || days < 1 || days > 90) throw new Error("--days must be an integer between 1 and 90");
    await writeEventCatalogOutput(
      await client.listEventCatalog(days, flags["no-diagnostics"] !== true),
      flags,
      global,
    );
    return;
  }
  if (sub === "get") {
    const eventType = args.shift();
    if (!eventType || args.length) throw new Error("usage: gamealgo events get <eventType>");
    await writeEventCatalogOutput(await client.getEventCatalog(eventType), flags, global);
    return;
  }
  if (sub === "apply") {
    const filePath = args.shift();
    if (!filePath || args.length) throw new Error("usage: gamealgo events apply <events.yaml>");
    const content = await readObjectFile(filePath, "event catalog");
    await writeEventCatalogOutput(await client.applyEventCatalog(content), flags, global);
    return;
  }
  if (sub === "deprecate") {
    const eventType = args.shift();
    if (!eventType || args.length) throw new Error("usage: gamealgo events deprecate <eventType> [--yes]");
    if (!flags.yes && !(await confirm(`Deprecate event ${eventType}?`))) throw new Error("Cancelled");
    await writeEventCatalogOutput(await client.deprecateEventCatalog(eventType), flags, global);
    return;
  }
  if (sub !== "count") throw new Error("usage: gamealgo events <list|get|apply|deprecate|count>");
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

async function writeEventCatalogOutput(
  value: unknown,
  flags: Record<string, string | boolean>,
  global: ReturnType<typeof parseGlobalFlags>,
): Promise<void> {
  if (flags.out) {
    const filePath = String(flags.out);
    const content = filePath.endsWith(".json") ? JSON.stringify(value, null, 2) + "\n" : YAML.stringify(value);
    await writeTextFile(filePath, content);
    await printResult({ ok: true, out: filePath }, global);
    return;
  }
  await printResult(value, global);
}

async function handleIntegration(client: GameAlgoAdminClient, args: string[], global: ReturnType<typeof parseGlobalFlags>): Promise<void> {
  const sub = args.shift();
  const flags = parseFlags(args);
  if (args.length) throw new Error("unexpected positional arguments for integration command");
  const environment = integrationEnvironment(flags.environment);
  const platform = integrationPlatform(flags.platform);

  if (sub === "get-plan" || sub === "plan") {
    const response = await client.getIntegrationPlan(environment, platform);
    await writeIntegrationOutput(response, flags, global);
    return;
  }

  throw new Error("usage: gamealgo integration get-plan --environment <domestic|overseas> --platform <ios|android|maker|rest>");
}

async function writeIntegrationOutput(
  value: unknown,
  flags: Record<string, string | boolean>,
  global: ReturnType<typeof parseGlobalFlags>,
): Promise<void> {
  if (flags.out) {
    if (typeof flags.out !== "string") throw new Error("--out requires a file path");
    await writeTextFile(flags.out, JSON.stringify(value, null, 2) + "\n");
    await printResult({ ok: true, out: flags.out }, global);
    return;
  }
  await printResult(value, global);
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
    const result = objectValue(await client.putAdjustMarketing(body));
    await printResult({ ok: true, ...(result || {}) }, global);
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

  async listExperimentV2Strategies(includeArchived = false) {
    const query = includeArchived ? "?includeArchived=1" : "";
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/strategies-v2${query}`);
  }

  async listExperimentIntegrationVersions(limit = 100) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-integration-versions?limit=${encodeURIComponent(String(limit))}`);
  }

  async getLatestExperimentIntegrationVersion() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-integration-versions/latest`);
  }

  async getExperimentIntegrationVersion(version: number) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-integration-versions/${version}`);
  }

  async createExperimentIntegrationVersion(title: string, message: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-integration-versions`, { title, message });
  }

  async updateExperimentIntegrationVersion(version: number, message: string) {
    return await this.patch(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-integration-versions/${version}`, { message });
  }

  async getExperimentV2Strategy(strategyKey: string) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/strategies-v2/${encodeURIComponent(strategyKey)}`);
  }

  async upsertExperimentV2Strategy(body: Record<string, unknown>) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/strategies-v2`, body);
  }

  async updateExperimentV2StrategyDefault(strategyKey: string, body: Record<string, unknown>) {
    return await this.put(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/strategies-v2/${encodeURIComponent(strategyKey)}/default`, body);
  }

  async archiveExperimentV2Strategy(strategyKey: string, archived: boolean) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/strategies-v2/${encodeURIComponent(strategyKey)}/archive`, { archived });
  }

  async rollbackExperimentV2Strategy(strategyKey: string, versionId: string, message: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/strategies-v2/${encodeURIComponent(strategyKey)}/rollback`, {
      versionId,
      message,
    });
  }

  async createExperimentV2Run(strategyKey: string, body: Record<string, unknown>) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/strategies-v2/${encodeURIComponent(strategyKey)}/runs`, body);
  }

  async getExperimentV2Run(runId: string) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-runs-v2/${encodeURIComponent(runId)}`);
  }

  async evaluateExperimentV2Run(runId: string, query: Record<string, string | undefined>) {
    const params = new URLSearchParams();
    if (query.from) params.set("from", query.from);
    if (query.to) params.set("to", query.to);
    if (query.days) params.set("days", query.days);
    if (query.platform) params.set("platform", query.platform);
    const suffix = params.toString() ? `?${params.toString()}` : "";
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-runs-v2/${encodeURIComponent(runId)}/evaluate${suffix}`, {});
  }

  async promoteExperimentV2Run(runId: string, variantId: string, message: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-runs-v2/${encodeURIComponent(runId)}/promote`, {
      variantId,
      message,
    });
  }

  async cancelExperimentV2Run(runId: string, message: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-runs-v2/${encodeURIComponent(runId)}/cancel`, { message });
  }

  async updateExperimentV2RunObjective(runId: string, objectiveTemplate: string, message: string) {
    return await this.patch(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-runs-v2/${encodeURIComponent(runId)}/objective`, {
      objectiveTemplate,
      message,
    });
  }

  async listExperimentV2Overrides(runId: string) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-runs-v2/${encodeURIComponent(runId)}/overrides`);
  }

  async upsertExperimentV2Override(runId: string, userId: string, variantId: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-runs-v2/${encodeURIComponent(runId)}/overrides`, { userId, variantId });
  }

  async deleteExperimentV2Override(runId: string, userId: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/experiment-runs-v2/${encodeURIComponent(runId)}/overrides/delete`, { userId });
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

  async listScriptVersions(name?: string, limit = 50) {
    const params = new URLSearchParams();
    if (name) params.set("name", name);
    params.set("limit", String(limit));
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/script-versions?${params.toString()}`) as {
      scriptVersions: Array<{ versionId: string; name: string; content?: string; createdAt?: string }>;
    };
  }

  async createScriptVersion(name: string, content: string, contentType: string, message?: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/scripts/${encodeURIComponent(name)}/versions`, {
      content,
      contentType,
      ...(message ? { message } : {}),
    }) as {
      scriptVersion: { versionId: string; name: string; hash: string; contentType: string; createdAt?: string };
    };
  }

  async getScriptVersion(name: string, versionId: string) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/scripts/${encodeURIComponent(name)}/versions/${encodeURIComponent(versionId)}`) as {
      scriptVersion: { versionId: string; name: string; content: string; hash: string; contentType: string; createdAt?: string };
    };
  }

  async getReportPack() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/report-pack`) as {
      reportPack: { content: unknown };
    };
  }

  async previewReportPack(content: unknown) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/report-pack/preview`, { content });
  }

  async putReportPack(content: unknown) {
    return await this.put(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/report-pack`, { content }) as {
      reportPack: { validation: unknown };
    };
  }

  async reportManifest() {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/reports/manifest`);
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

  async listEventCatalog(days = 30, diagnostics = true) {
    const params = new URLSearchParams({ days: String(days), diagnostics: diagnostics ? "1" : "0" });
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/events/catalog?${params.toString()}`);
  }

  async getEventCatalog(eventType: string) {
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/events/catalog/${encodeURIComponent(eventType)}`);
  }

  async applyEventCatalog(content: Record<string, unknown>) {
    return await this.put(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/events/catalog`, content);
  }

  async deprecateEventCatalog(eventType: string) {
    return await this.post(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/events/catalog/${encodeURIComponent(eventType)}/deprecate`, {});
  }

  async getIntegrationPlan(environment: string, platform: string) {
    const params = new URLSearchParams({ environment, platform });
    return await this.get(`/admin/v1/games/${encodeURIComponent(await this.gameId())}/integration/plan?${params.toString()}`);
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

  async patch(path: string, body: unknown) {
    return await requestJson(this.host, path, {
      method: "PATCH",
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

async function loadDocsManifest(host: string): Promise<{ manifest: DocsManifest; cached: boolean }> {
  const cachePath = join(docsCacheDir(host), "manifest.json");
  try {
    const text = await requestTextUrl(`${docsContentBaseUrl(host)}manifest.json`);
    const manifest = parseDocsManifest(text);
    await writePrivateFile(cachePath, `${JSON.stringify(manifest, null, 2)}\n`);
    return { manifest, cached: false };
  } catch (networkError) {
    try {
      const manifest = parseDocsManifest(await readFile(cachePath, "utf8"));
      return { manifest, cached: true };
    } catch {
      throw networkError;
    }
  }
}

async function loadDocsDocument(
  host: string,
  manifest: DocsManifest,
  topic: DocsTopic,
  preferCache: boolean,
): Promise<{ content: string; cached: boolean }> {
  const cachePath = join(docsCacheDir(host), manifest.version || "current", topic.file);
  if (!preferCache) {
    try {
      const content = await requestTextUrl(docsRawUrl(host, topic.file));
      await writePrivateFile(cachePath, content);
      return { content, cached: false };
    } catch {
      // Fall through to the most recent cached copy.
    }
  }
  try {
    return { content: await readFile(cachePath, "utf8"), cached: true };
  } catch {
    if (preferCache) {
      throw new Error(`Documentation topic is not cached and the Admin host is unavailable: ${topic.id}`);
    }
    throw new Error(`Unable to download documentation topic: ${topic.id}`);
  }
}

async function requestTextUrl(url: string): Promise<string> {
  let response: Response;
  try {
    response = await fetch(url, { signal: AbortSignal.timeout(10_000) });
  } catch (error) {
    if (isTimeoutError(error)) throw new Error(`Documentation request timed out: ${url}`);
    throw new Error(`Documentation request failed: ${url}: ${error instanceof Error ? error.message : String(error)}`);
  }
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`Documentation request returned ${response.status}: ${truncateBody(text)}`);
  }
  return text;
}

function parseDocsManifest(text: string): DocsManifest {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error("Documentation manifest is not valid JSON");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Documentation manifest must be an object");
  }
  const body = value as Record<string, unknown>;
  if (body.schemaVersion !== 1 || !Array.isArray(body.topics) || !body.topics.length) {
    throw new Error("Documentation manifest schema is invalid");
  }
  const topics = body.topics.map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new Error("Documentation manifest contains an invalid topic");
    }
    const topic = item as Record<string, unknown>;
    const id = String(topic.id || "");
    const file = String(topic.file || "");
    if (!/^[a-z][a-z0-9-]{0,63}$/.test(id) || !/^[a-z][a-z0-9-]{0,63}\.md$/.test(file)) {
      throw new Error(`Documentation manifest contains an unsafe topic: ${id || file}`);
    }
    return {
      id,
      title: String(topic.title || id),
      summary: String(topic.summary || ""),
      group: String(topic.group || "其他"),
      file,
      hidden: topic.hidden === true,
    };
  });
  const ids = new Set(topics.map((topic) => topic.id));
  if (ids.size !== topics.length) throw new Error("Documentation manifest contains duplicate topic ids");
  const defaultTopic = String(body.defaultTopic || topics[0].id);
  if (!ids.has(defaultTopic)) throw new Error("Documentation manifest defaultTopic does not exist");
  return {
    schemaVersion: 1,
    version: String(body.version || "current"),
    updatedAt: String(body.updatedAt || ""),
    defaultTopic,
    topics,
  };
}

function docsCacheDir(host: string): string {
  const key = createHash("sha256").update(normalizeHost(host)).digest("hex").slice(0, 16);
  return join(DOCS_CACHE_ROOT, key);
}

function docsWebUrl(host: string, topicId?: string): string {
  const url = new URL(`${normalizeHost(host)}/dashboard/docs/`);
  if (topicId) url.searchParams.set("topic", topicId);
  return url.toString();
}

function docsContentBaseUrl(host: string): string {
  return `${normalizeHost(host)}/dashboard/docs/content/`;
}

function docsRawUrl(host: string, file: string): string {
  return `${docsContentBaseUrl(host)}${encodeURIComponent(file)}`;
}

async function writePrivateFile(filePath: string, content: string): Promise<void> {
  await mkdir(dirname(filePath), { recursive: true, mode: 0o700 });
  await chmod(dirname(filePath), 0o700).catch(() => undefined);
  await writeFile(filePath, content, { encoding: "utf8", mode: 0o600 });
  await chmod(filePath, 0o600).catch(() => undefined);
}

function printDocsIndex(manifest: DocsManifest, webUrl: string): void {
  console.log(`GameAlgo AI 文档 ${manifest.version}${manifest.updatedAt ? ` (${manifest.updatedAt})` : ""}`);
  let currentGroup = "";
  for (const topic of manifest.topics.filter((item) => !item.hidden)) {
    if (topic.group !== currentGroup) {
      currentGroup = topic.group;
      console.log(`\n${currentGroup}`);
    }
    console.log(`  ${topic.id}\n    ${topic.title}：${topic.summary}`);
  }
  console.log(`\n读取文档: gamealgo docs <topic>`);
  console.log(`网页目录: ${webUrl}`);
}

function openExternalUrl(url: string): void {
  const command = process.platform === "darwin" ? "open" : process.platform === "win32" ? "cmd" : "xdg-open";
  const args = process.platform === "win32" ? ["/c", "start", "", url] : [url];
  const child = spawn(command, args, { detached: true, stdio: "ignore" });
  child.on("error", (error) => console.error(`Unable to open browser: ${error.message}`));
  child.unref();
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
  const localPath = await findProjectConfigPath(process.cwd());
  const paths = localPath && localPath !== GLOBAL_CONFIG_PATH
    ? [localPath, GLOBAL_CONFIG_PATH]
    : [GLOBAL_CONFIG_PATH];
  for (const configPath of paths) {
    try {
      return JSON.parse(await readFile(configPath, "utf8")) as CliConfig;
    } catch {
      // Try the next supported config location.
    }
  }
  return null;
}

async function findProjectConfigPath(startDir: string): Promise<string | null> {
  let currentDir = startDir;
  while (true) {
    const candidate = join(currentDir, PROJECT_CONFIG_DIR, PROJECT_CONFIG_FILE);
    try {
      await readFile(candidate, "utf8");
      return candidate;
    } catch {
      const parentDir = dirname(currentDir);
      if (parentDir === currentDir) return null;
      currentDir = parentDir;
    }
  }
}

async function saveConfig(config: CliConfig): Promise<string> {
  const configDir = join(process.cwd(), PROJECT_CONFIG_DIR);
  const configPath = join(configDir, PROJECT_CONFIG_FILE);
  await mkdir(configDir, { recursive: true, mode: 0o700 });
  await chmod(configDir, 0o700).catch(() => undefined);
  await ensureProjectConfigIgnored(configDir);
  await writeFile(configPath, JSON.stringify(config, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  await chmod(configPath, 0o600).catch(() => undefined);
  return configPath;
}

async function ensureProjectConfigIgnored(configDir: string): Promise<void> {
  const ignorePath = join(configDir, ".gitignore");
  try {
    const existing = await readFile(ignorePath, "utf8");
    const rules = existing.split(/\r?\n/).map((line) => line.trim());
    if (rules.includes("*") || rules.includes(PROJECT_CONFIG_FILE) || rules.includes(`/${PROJECT_CONFIG_FILE}`)) return;
    const separator = existing && !existing.endsWith("\n") ? "\n" : "";
    await writeFile(ignorePath, `${existing}${separator}${PROJECT_CONFIG_FILE}\n`, { encoding: "utf8", mode: 0o600 });
  } catch {
    await writeFile(ignorePath, "*\n", { encoding: "utf8", mode: 0o600 });
  }
}

async function readObjectFile(filePath: string, label: string): Promise<Record<string, unknown>> {
  const text = await readFile(filePath, "utf8");
  const parsed = filePath.endsWith(".json") ? JSON.parse(text) : YAML.parse(text);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${label} file must be a JSON/YAML object`);
  }
  return parsed as Record<string, unknown>;
}

function latestScriptVersionNames(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const names = new Set<string>();
  for (const item of value) {
    const body = objectValue(item);
    const name = optionalString(body?.name);
    if (name && !names.has(name)) names.add(sanitizeRemoteFileName(name));
  }
  return [...names];
}

function objectValue(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function validateExperimentRunVariantScripts(value: unknown): void {
  if (!Array.isArray(value)) throw new Error("experiment run requires variants array");
  for (let index = 0; index < value.length; index += 1) {
    const variant = objectValue(value[index]);
    if (!variant) throw new Error(`variants[${index}] must be an object`);
    if (!Object.prototype.hasOwnProperty.call(variant, "script")) continue;
    const script = objectValue(variant.script);
    if (!script || !optionalString(script.versionId)) {
      throw new Error(`variants[${index}].script requires versionId; omit script for a config-only variant`);
    }
  }
}

function printExperimentRunVariantScripts(value: unknown): void {
  const run = objectValue(objectValue(value)?.run);
  if (!run || !Array.isArray(run.variants)) return;
  console.log("\nVariant execution:");
  for (const item of run.variants) {
    const variant = objectValue(item);
    if (!variant) continue;
    const variantId = optionalString(variant.variantId) ?? "(unknown)";
    const versionId = optionalString(objectValue(variant.script)?.versionId);
    console.log(`  ${variantId}: ${versionId ? `script ${versionId}` : "config-only"}`);
  }
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

function optionalNonNegativeInteger(value: unknown, field: string): number | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value === "boolean") throw new Error(`${field} must be a non-negative integer`);
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) throw new Error(`${field} must be a non-negative integer`);
  return parsed;
}

function positiveInteger(value: unknown, field: string): number {
  const parsed = optionalNonNegativeInteger(value, field);
  if (!parsed) throw new Error(`${field} must be a positive integer`);
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

function integrationEnvironment(value: unknown): "domestic" | "overseas" {
  const environment = optionalString(value);
  if (environment === "domestic" || environment === "overseas") return environment;
  throw new Error("--environment must be domestic or overseas");
}

function integrationPlatform(value: unknown): "ios" | "android" | "maker" | "rest" {
  const platform = optionalString(value);
  if (platform === "ios" || platform === "android" || platform === "maker" || platform === "rest") return platform;
  throw new Error("--platform must be ios, android, maker, or rest");
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
  if (name.endsWith(".lua")) return "application/lua; charset=utf-8";
  if (name.endsWith(".js")) return "text/javascript; charset=utf-8";
  return "text/plain; charset=utf-8";
}

async function loadPackageMetadata(): Promise<{ name: string; version: string }> {
  const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8")) as {
    name?: unknown;
    version?: unknown;
  };
  const name = typeof packageJson.name === "string" ? packageJson.name : "gamealgo-cli";
  if (typeof packageJson.version !== "string" || !packageJson.version) {
    throw new Error("CLI package version is missing");
  }
  return { name, version: packageJson.version };
}

await main();
