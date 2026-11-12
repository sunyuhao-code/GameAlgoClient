import { execFileSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { build } from "vite";

const root = resolve(import.meta.dirname, "..");
await build({
  configFile: false,
  publicDir: false,
  logLevel: "warn",
  build: {
    outDir: resolve(root, "douyin/dist"), emptyOutDir: true, target: "es2019", sourcemap: true,
    lib: { entry: resolve(root, "douyin/src/index.ts"), formats: ["es", "cjs"], fileName: format => format === "cjs" ? "commonjs/index.js" : "index.js" },
    rollupOptions: { output: { exports: "named" } },
  },
});
execFileSync(process.execPath, [resolve(root, "node_modules/typescript/bin/tsc"), "-p", resolve(root, "douyin/tsconfig.json")], { stdio: "inherit" });

await mkdir(resolve(root, "douyin/dist/commonjs"), { recursive: true });
await writeFile(resolve(root, "douyin/dist/commonjs/package.json"), JSON.stringify({ type: "commonjs" }) + "\n");
