# CLAUDE.md

## Project Structure

Canvas is Excalidraw as a native Mac app. It's a Yarn workspaces monorepo:

- **`canvas-app/`** - Web layer loaded by the Mac app: editor, store (via the native HTTP server), MCP tools, sharing (`collab/`), bridge
- **`macos/`** - Swift/SwiftUI app: window, panels, local HTTP server, Claude runner, `build.sh`
- **`relay/`** - Cloudflare Worker for shared scenes (separate npm project, not a workspace)
- **`packages/`** - Excalidraw packages: `@excalidraw/excalidraw`, `common`, `element`, `math`, `utils`, …; keep changes small so upstream merges stay easy

## Development Workflow

1. **Editor features**: `packages/*`; **app features**: `canvas-app/` and `macos/`
2. **Testing**: Always run `yarn test:update` before committing
3. **Type Safety**: `yarn test:typecheck` (packages and canvas-app)
4. **Build and install**: `yarn app:install`

## Development Commands

```bash
yarn test:typecheck  # TypeScript type checking
yarn test:update     # Run all tests (with snapshot updates)
yarn fix             # Auto-fix formatting and linting issues
yarn app:install     # Build Canvas.app and install it to /Applications
```

## Architecture Notes

- `canvas-app` resolves `@excalidraw/*` straight to `packages/*` sources (see `canvas-app/vite.config.mts`); the packages aren't built separately
- Tests run with Vitest; internal packages use path aliases (see `vitest.config.mts`)
- TypeScript throughout with strict configuration
