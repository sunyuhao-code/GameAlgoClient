#!/usr/bin/env node
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outputArg = process.argv[2];
if (!outputArg) {
  throw new Error("usage: node scripts/export-web-docs.mjs <output-directory>");
}

const outputDir = resolve(process.cwd(), outputArg);
const manifest = JSON.parse(await readFile(join(projectRoot, "docs/manifest.json"), "utf8"));
if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.topics) || !manifest.topics.length) {
  throw new Error("docs/manifest.json is invalid");
}

const seen = new Set();
const topics = [];
for (const topic of manifest.topics) {
  const id = String(topic.id || "");
  const source = String(topic.source || "");
  if (!/^[a-z][a-z0-9-]{0,63}$/.test(id) || seen.has(id)) {
    throw new Error(`invalid or duplicate docs topic id: ${id}`);
  }
  seen.add(id);

  const sourcePath = resolve(projectRoot, source);
  const sourceRelative = relative(projectRoot, sourcePath);
  if (!source || isAbsolute(source) || sourceRelative.startsWith(`..${sep}`) || sourceRelative === "..") {
    throw new Error(`docs topic source escapes repository: ${source}`);
  }
  const content = await readFile(sourcePath, "utf8");
  const file = `${id}.md`;
  topics.push({
    id,
    title: String(topic.title || id),
    summary: String(topic.summary || ""),
    group: String(topic.group || "其他"),
    file,
  });
  await mkdir(outputDir, { recursive: true });
  await writeFile(join(outputDir, file), content, "utf8");
}

const existingFiles = await readdir(outputDir).catch(() => []);
for (const file of existingFiles) {
  if ((file.endsWith(".md") || file === "manifest.json") && !topics.some((topic) => topic.file === file)) {
    await rm(join(outputDir, file), { force: true });
  }
}

const publicManifest = {
  schemaVersion: 1,
  version: String(manifest.version || ""),
  updatedAt: String(manifest.updatedAt || ""),
  defaultTopic: String(manifest.defaultTopic || topics[0].id),
  topics,
};
await writeFile(join(outputDir, "manifest.json"), `${JSON.stringify(publicManifest, null, 2)}\n`, "utf8");
console.log(`Exported ${topics.length} GameAlgo docs to ${outputDir}`);
