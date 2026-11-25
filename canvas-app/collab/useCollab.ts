// Keeps the open scene connected to its shared copy while it's shared.

import { useCallback, useEffect, useRef, useState } from "react";

import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";

import { postNative } from "../data/native";
import { getSceneMeta, renameScene } from "../data/store";

import { CollabSession } from "./Collab";
import { loadShare, onShareChange } from "./shares";

import type { CollabStatus } from "./Collab";

/** the open scene's live session, for the bridge */
let active: { sceneId: string; status: CollabStatus | null } | null = null;
export const activeCollab = () => active;

const userName = () =>
  (window as any).__CANVAS__?.userName ||
  localStorage.getItem("canvas-name") ||
  "Guest";

export const useCollab = (
  sceneId: string,
  api: ExcalidrawImperativeAPI | null,
) => {
  const sessionRef = useRef<CollabSession | null>(null);
  const [status, setStatus] = useState<CollabStatus | null>(null);
  const [generation, setGeneration] = useState(0);

  // share started, joined, left or stopped from the native side: reconnect
  useEffect(
    () =>
      onShareChange((changed) => {
        if (changed === sceneId) {
          setGeneration((g) => g + 1);
        }
      }),
    [sceneId],
  );

  useEffect(() => {
    if (!api) {
      return;
    }
    let cancelled = false;
    const report = (next: CollabStatus | null) => {
      active = { sceneId, status: next };
      setStatus(next);
      postNative("collab", { sceneId, ...(next ?? { state: "off" }) });
    };
    loadShare(sceneId).then((info) => {
      if (cancelled) {
        return;
      }
      if (!info) {
        report(null);
        return;
      }
      if (info.ended) {
        report({
          state: "ended",
          role: info.role,
          peers: 0,
          ended: info.ended,
        });
        return;
      }
      sessionRef.current = new CollabSession(sceneId, info, api, {
        userName: userName(),
        sceneName: () => getSceneMeta(sceneId)?.name ?? "Untitled",
        onRename: (name) => {
          if (getSceneMeta(sceneId)?.name !== name) {
            renameScene(sceneId, name);
          }
        },
        onStatus: (next) => !cancelled && report(next),
      });
    });
    return () => {
      cancelled = true;
      sessionRef.current?.stop();
      sessionRef.current = null;
      if (active?.sceneId === sceneId) {
        active = null;
      }
    };
  }, [api, sceneId, generation]);

  const localChanged = useCallback(
    () => sessionRef.current?.localChanged(),
    [],
  );
  const pointer = useCallback(
    (payload: Parameters<CollabSession["pointer"]>[0]) =>
      sessionRef.current?.pointer(payload),
    [],
  );

  const live = !!status && status.state !== "ended";
  return {
    status,
    localChanged,
    pointer,
    isCollaborating: live,
    viewOnly: live && status!.role === "view",
  };
};
