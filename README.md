# Canvas

Excalidraw as a native Mac app: free, local-first, with live sharing and Claude built in.

- **Native and light.** A SwiftUI/AppKit window in Liquid Glass with Excalidraw's canvas in the system WebKit. No Electron: the app is about 25 MB and sits at roughly 250 MB of memory and near-zero CPU when idle. It works offline, opens `.excalidraw` files from Finder, and has native panels, popovers and a menu bar.
- **Scenes library.** Unlimited scenes with collections (drag a scene onto one), stars, search, thumbnails, duplicate and export. Everything lives in `~/Library/Application Support/Canvas`.
- **Version history.** Snapshots every 5 minutes and when you leave a scene, plus named versions. Preview any snapshot and restore it (restoring can be undone).
- **Slides.** Frames are slides: reorder them, present full screen with the laser pointer, or export a PDF.
- **Live sharing.** Share a scene with a link that can edit or only view. Changes and cursors show up live, everyone keeps a full copy and can keep drawing offline, and the scene stays reachable while your Mac is off. Links can be turned off at any time. Scenes are encrypted on your Mac with a key that only lives in the link, so the relay can't read them.
- **Claude in the app.** A Claude panel per scene with saved chats, a model and effort picker, and an agent that can read files you allow, run read-only commands, search the web and use your library, asking with Allow / Deny cards before it does anything outside the scene. It can never write files, and common secret paths are always blocked. Runs on your Claude Code login: no API key, no per-call billing.
- **MCP server.** Any Claude Code session can draw in the open scene. _Canvas → Connect Claude Code…_ copies the command with your token filled in.

Everything from the open-source editor comes along: frames, sticky notes, Mermaid, libraries, embeds, the laser pointer, the command palette, search and all the export options.

## On the web

[canvas.paperknife.app](https://canvas.paperknife.app) is the same editor in any browser, for people without the Mac app: open a share link there (you'll be asked for a name for your cursor), or start scenes of your own. Scenes on the web are saved in that browser, and sharing works the same way as on the Mac. Claude, slides and version history are Mac-only.

## Install

Download the DMG from [Releases](https://github.com/kalki-kgp/canvas/releases), open it and drag Canvas to Applications. The app isn't notarized, so the first time, right-click Canvas → Open, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Canvas.app
```

Needs macOS 26 on Apple silicon. The Claude features need [Claude Code](https://claude.com/claude-code) installed and signed in.

## Sharing

1. Open a scene and click **Share → Start Sharing**. The first link can edit; add a **View Only** link from the same popover.
2. Copy a link and send it. It opens in any browser at canvas.paperknife.app; in the Mac app, use **File → Open Shared Link…** (⇧⌘O).
3. The toolbar shows **Shared · N** while people are in. Turn a link off with ✕, or **Stop Sharing** to delete the shared copy; everyone keeps the copy they have.

How it works: each copy of a shared scene is complete, and edits merge per element (the newer version of a shape wins, deletions included), so offline work merges when you reconnect. A small Cloudflare Worker at `canvas.paperknife.app` serves the website and passes edits between people and keeps the latest encrypted copy for whoever opens the scene next. It runs on Cloudflare's free plan. Images in shared scenes don't sync yet.

## Build

```sh
yarn install --frozen-lockfile   # once
yarn app:install                 # builds the web layer and the Swift app, installs /Applications/Canvas.app
```

You need macOS 26, Node 18+ and the Xcode command line tools.

| Command | What |
| --- | --- |
| `yarn app` | Build `macos/build/Canvas.app` without installing |
| `yarn test:update` | Run the tests (run before every commit) |
| `yarn test:typecheck` | Typecheck the packages and `canvas-app` |
| `cd relay && npm test` | Run the relay's end-to-end test against a local `wrangler dev` |
| `cd canvas-app && npx vite build && cd ../relay && npm run deploy` | Build the website and deploy it with the relay |

## Layout

| Path | What |
| --- | --- |
| `canvas-app/` | The editor for both the Mac app and the website: store (native or IndexedDB), presenter, AI dialogs, MCP tools, sharing (`collab/`), web pages (`web/`) and the bridge the window calls |
| `macos/` | Swift app: the window (library, toolbar, Share popover, Slides / History / Claude panels), local HTTP server, Claude runner and its permission checks, build script |
| `relay/` | Cloudflare Worker that serves the website (`canvas-app`'s build) and relays and stores encrypted shared scenes in a Durable Object |
| `packages/` | The Excalidraw editor packages, kept close to upstream so merges stay easy |

## Credits

Canvas is built on [Excalidraw](https://github.com/excalidraw/excalidraw) (MIT). See [LICENSE](LICENSE).
