// What the Swift shell calls into. The native window draws the scenes
// library, the slides / history / Claude panels and the toolbar; the page
// keeps the editor and is the only writer of the store, so every change the
// shell makes goes through here.

import { THEME, exportScene, getNonDeletedElements } from "@excalidraw/excalidraw";
import { getDataURL } from "@excalidraw/excalidraw/data/blob";

import { navigate } from "./App";
import { exportSceneFile } from "./data/importExport";
import { postNative, savePDF } from "./data/native";
import {
  createCollection,
  createScene,
  deleteCollection,
  deleteScene,
  duplicateScene,
  fileIdsOf,
  getIndex,
  getSceneMeta,
  listSnapshots,
  loadFiles,
  loadSnapshot,
  moveScene,
  renameCollection,
  renameScene,
  snapshotLabel,
  subscribeIndex,
  toggleStar,
} from "./data/store";
import { getSession } from "./editor/session";
import { getSlides, renderSlideDataURL, slideName } from "./editor/slides";

import type { Theme } from "@excalidraw/element/types";

let setTheme: ((theme: Theme | "system") => void) | null = null;
export const setBridgeThemeSetter = (fn: typeof setTheme) => {
  setTheme = fn;
};

const session = () => {
  const s = getSession();
  if (!s) {
    throw new Error("No scene is open");
  }
  return s;
};

const handlers: Record<string, (...args: any[]) => unknown> = {
  open: (id: string) => navigate({ view: "scene", id }),
  home: () => navigate({ view: "dashboard" }),
  async newScene(collectionId?: string | null) {
    const meta = await createScene({ collectionId: collectionId ?? null });
    navigate({ view: "scene", id: meta.id });
    return meta.id;
  },
  rename: (id: string, name: string) => renameScene(id, name),
  async duplicate(id: string) {
    return (await duplicateScene(id))?.id ?? null;
  },
  star: (id: string) => toggleStar(id),
  move: (id: string, collectionId: string | null) => moveScene(id, collectionId),
  async remove(id: string) {
    if (getSession()?.sceneId === id) {
      navigate({ view: "dashboard" });
    }
    await deleteScene(id);
  },
  async newCollection(name: string) {
    return (await createCollection(name)).id;
  },
  renameCollection: (id: string, name: string) => renameCollection(id, name),
  deleteCollection: (id: string) => deleteCollection(id),
  exportFile: (id: string) => exportSceneFile(id),

  setTheme: (theme: Theme | "system") => setTheme?.(theme),

  // the open scene ------------------------------------------------------------

  context() {
    const s = getSession();
    if (!s) {
      return null;
    }
    return {
      sceneId: s.sceneId,
      name: getSceneMeta(s.sceneId)?.name ?? "Untitled",
      selected: Object.keys(s.api.getAppState().selectedElementIds),
    };
  },
  exportImage() {
    session().api.updateScene({
      appState: { openDialog: { name: "imageExport" } },
    });
  },

  async slides(size = 360) {
    const s = session();
    const frames = getSlides(s.api, s.getExtras().slides);
    const out = [];
    for (let i = 0; i < frames.length; i++) {
      out.push({
        id: frames[i].id,
        name: slideName(frames[i], i),
        thumb: await renderSlideDataURL(s.api, frames[i], {
          maxWidthOrHeight: size,
        }),
      });
    }
    return out;
  },
  setSlideOrder: (ids: string[]) => session().setExtras({ slides: ids }),
  present: (from = 0) => session().startPresenting(from),
  stopPresenting: () => getSession()?.stopPresenting(),
  addFrame() {
    session().api.setActiveTool({ type: "frame" });
  },
  async exportPDF() {
    const s = session();
    const frames = getSlides(s.api, s.getExtras().slides);
    if (!frames.length) {
      return false;
    }
    const pages: string[] = [];
    for (const frame of frames) {
      pages.push(await renderSlideDataURL(s.api, frame, { scale: 2 }));
    }
    return savePDF(getSceneMeta(s.sceneId)?.name || "Slides", pages);
  },

  async snapshots() {
    const s = session();
    return (await listSnapshots(s.sceneId)).map((snap) => ({
      name: snap.name,
      savedAt: snap.savedAt,
      label: snapshotLabel(snap) ?? null,
    }));
  },
  async previewSnapshot(name: string, size = 720) {
    const s = session();
    const doc = await loadSnapshot(s.sceneId, name);
    if (!doc) {
      return null;
    }
    const elements = getNonDeletedElements(doc.elements);
    if (!elements.length) {
      return "";
    }
    const dark = s.api.getAppState().theme === THEME.DARK;
    const blob = await exportScene({
      type: "png",
      data: {
        elements,
        appState: {
          ...doc.appState,
          viewBackgroundColor: doc.appState.viewBackgroundColor ?? "#ffffff",
        },
        files: await loadFiles(fileIdsOf(doc.elements)),
      },
      config: {
        theme: dark ? THEME.DARK : THEME.LIGHT,
        maxWidthOrHeight: size,
        padding: 24,
      },
    });
    return getDataURL(blob);
  },
  async restoreSnapshot(name: string) {
    const s = session();
    const doc = await loadSnapshot(s.sceneId, name);
    if (!doc) {
      throw new Error("That version is gone");
    }
    await s.restore(doc);
  },
  saveVersion: (label?: string) => session().saveVersion(label || undefined),
};

export const installBridge = () => {
  (window as any).canvasBridge = {
    async call(fn: string, args: unknown[]) {
      const handler = handlers[fn];
      if (!handler) {
        throw new Error(`unknown bridge call ${fn}`);
      }
      const result = await handler(...(args ?? []));
      return JSON.stringify(result ?? null);
    },
  };
  const pushIndex = () => postNative("index", { index: getIndex() });
  subscribeIndex(pushIndex);
  pushIndex();
};
