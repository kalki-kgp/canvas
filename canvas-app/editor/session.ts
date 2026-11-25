// The currently open editor, for things outside React (MCP tools, menus).

import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import type { CanvasSceneExtras } from "../data/store";

export type EditorSession = {
  sceneId: string;
  api: ExcalidrawImperativeAPI;
  /** persists pending changes right away */
  flush: () => Promise<void>;
  getExtras: () => CanvasSceneExtras;
  setExtras: (patch: Partial<CanvasSceneExtras>) => void;
  startPresenting: (fromSlide?: number) => void;
};

let current: EditorSession | null = null;
const waiters = new Set<(s: EditorSession) => void>();

export const setSession = (session: EditorSession | null) => {
  current = session;
  if (session) {
    [...waiters].forEach((fn) => fn(session));
  }
};

export const getSession = () => current;

/** resolves once an editor for `sceneId` is ready */
export const waitForSession = (sceneId: string, timeoutMs = 10_000) =>
  new Promise<EditorSession>((resolve, reject) => {
    if (current?.sceneId === sceneId) {
      return resolve(current);
    }
    const timer = setTimeout(() => {
      waiters.delete(onReady);
      reject(new Error(`scene ${sceneId} didn't open in time`));
    }, timeoutMs);
    const onReady = (s: EditorSession) => {
      if (s.sceneId === sceneId) {
        clearTimeout(timer);
        waiters.delete(onReady);
        resolve(s);
      }
    };
    waiters.add(onReady);
  });

(window as any).canvasFlush = () => current?.flush() ?? Promise.resolve();
