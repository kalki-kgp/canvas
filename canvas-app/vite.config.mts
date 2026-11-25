import path from "path";

import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import svgrPlugin from "vite-plugin-svgr";

const pkg = (p: string) => path.resolve(__dirname, "../packages", p);

// The Mac app serves the build on this port. In dev, /api and /mcp are proxied
// to the running app so the editor talks to the real native store.
const NATIVE_PORT = Number(process.env.CANVAS_PORT || 41873);

export default defineConfig({
  envDir: "../",
  base: "/",
  server: {
    port: 3100,
    proxy: {
      "/api": `http://127.0.0.1:${NATIVE_PORT}`,
      "/mcp": `http://127.0.0.1:${NATIVE_PORT}`,
    },
  },
  resolve: {
    alias: [
      { find: /^@excalidraw\/common$/, replacement: pkg("common/src/index.ts") },
      { find: /^@excalidraw\/common\/(.*?)/, replacement: pkg("common/src/$1") },
      { find: /^@excalidraw\/element$/, replacement: pkg("element/src/index.ts") },
      { find: /^@excalidraw\/element\/(.*?)/, replacement: pkg("element/src/$1") },
      { find: /^@excalidraw\/excalidraw$/, replacement: pkg("excalidraw/index.tsx") },
      { find: /^@excalidraw\/excalidraw\/(.*?)/, replacement: pkg("excalidraw/$1") },
      { find: /^@excalidraw\/math$/, replacement: pkg("math/src/index.ts") },
      { find: /^@excalidraw\/math\/(.*?)/, replacement: pkg("math/src/$1") },
      { find: /^@excalidraw\/utils$/, replacement: pkg("utils/src/index.ts") },
      { find: /^@excalidraw\/utils\/(.*?)/, replacement: pkg("utils/src/$1") },
      {
        find: /^@excalidraw\/fractional-indexing$/,
        replacement: pkg("fractional-indexing/src/index.ts"),
      },
      {
        find: /^@excalidraw\/laser-pointer$/,
        replacement: pkg("laser-pointer/src/index.ts"),
      },
    ],
  },
  build: {
    outDir: "build",
    emptyOutDir: true,
    sourcemap: false,
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 4096,
    rollupOptions: {
      onwarn(warning, warn) {
        // React libs ship "use client" directives, irrelevant here
        if (warning.code === "MODULE_LEVEL_DIRECTIVE") {
          return;
        }
        warn(warning);
      },
      output: {
        assetFileNames(chunkInfo) {
          if (chunkInfo?.name?.endsWith(".woff2")) {
            const family = chunkInfo.name.split("-")[0];
            return `fonts/${family}/[name][extname]`;
          }
          return "assets/[name]-[hash][extname]";
        },
        manualChunks(id) {
          if (
            id.includes("packages/excalidraw/locales") &&
            id.match(/en.json|percentages.json/) === null
          ) {
            const index = id.indexOf("locales/");
            return `locales/${id.substring(index + 8)}`;
          }
          if (id.includes("@codemirror/") || id.includes("@lezer/")) {
            return "codemirror.chunk";
          }
        },
      },
    },
  },
  plugins: [react(), svgrPlugin()],
  publicDir: "public",
});
