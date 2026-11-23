import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The console is served by the CineLounge server itself (`web/main.py`), so the
// build lands in the Python package. In development Vite serves the page and
// forwards every API path to a local server on 8199.
const API = "^/(household|network|login|setup|logout|redeem|health|portals|join|p|search|play|stream|state|\\.well-known)(/|$|\\?)";

// `cl-extension` is the one extension module (see `src/extension/types.ts`):
// `src/extension/local/index.ts` when that folder exists, otherwise `none.ts`.
// `preserveSymlinks`, so that a linked `local/` resolves `react` and the
// console's own modules from where it is linked, not from where it lies.
const here = path.dirname(fileURLToPath(import.meta.url));
const local = path.resolve(here, "src/extension/local/index.ts");
const extension = fs.existsSync(local) ? local : path.resolve(here, "src/extension/none.ts");

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "cl-extension": extension },
    preserveSymlinks: true,
  },
  build: {
    outDir: "../cinelounge/web/console",
    emptyOutDir: true,
    assetsDir: "assets",
    chunkSizeWarningLimit: 900,
  },
  server: {
    port: 5199,
    proxy: { [API]: { target: "http://127.0.0.1:8199", changeOrigin: false } },
  },
});
