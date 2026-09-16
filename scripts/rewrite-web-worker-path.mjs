import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "..");
const output = resolve(repositoryRoot, "web/dist/web/src/script-runtime.js");
const source = await readFile(output, "utf8");
const rewritten = source.replaceAll('"./script-worker.ts"', '"./script-worker.js"');
if (rewritten === source) {
  throw new Error(`Expected TypeScript worker URL was not found in ${output}`);
}
await writeFile(output, rewritten);
