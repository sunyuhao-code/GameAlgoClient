import { execFileSync } from "node:child_process";
import { rm } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
await rm(resolve(root, "taptap-h5/dist"), { recursive: true, force: true });
execFileSync(process.execPath, [resolve(root, "node_modules/typescript/bin/tsc"), "-p", resolve(root, "taptap-h5/tsconfig.json")], { stdio: "inherit" });
await import("./rewrite-web-worker-path.mjs");
