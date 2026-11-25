import { useCallback, useEffect, useState } from "react";
import { Sidebar, THEME, exportScene } from "@excalidraw/excalidraw";
import { historyIcon } from "@excalidraw/excalidraw/components/icons";

import {
  fileIdsOf,
  listSnapshots,
  loadFiles,
  loadSnapshot,
  snapshotLabel,
} from "../data/store";

import type { SceneDoc, SnapshotEntry } from "../data/store";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";

const dayFormat = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  month: "short",
  day: "numeric",
});
const timeFormat = new Intl.DateTimeFormat(undefined, {
  hour: "numeric",
  minute: "2-digit",
});

const dayLabel = (ts: number) => {
  const d = new Date(ts);
  const today = new Date();
  const yesterday = new Date(Date.now() - 86_400_000);
  if (d.toDateString() === today.toDateString()) {
    return "Today";
  }
  if (d.toDateString() === yesterday.toDateString()) {
    return "Yesterday";
  }
  return dayFormat.format(d);
};

export const HistoryPanel = ({
  api,
  sceneId,
  saveVersion,
  restore,
}: {
  api: ExcalidrawImperativeAPI;
  sceneId: string;
  saveVersion: (label?: string) => Promise<void>;
  restore: (doc: SceneDoc) => Promise<void>;
}) => {
  const [snapshots, setSnapshots] = useState<SnapshotEntry[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [preview, setPreview] = useState<string | null>(null);
  const [label, setLabel] = useState("");
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(async () => {
    setSnapshots(await listSnapshots(sceneId));
  }, [sceneId]);

  useEffect(() => {
    refresh();
    const timer = window.setInterval(refresh, 60_000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  useEffect(() => {
    let url: string | null = null;
    let cancelled = false;
    setPreview(null);
    if (!selected) {
      return;
    }
    (async () => {
      const snap = await loadSnapshot(sceneId, selected);
      if (!snap || cancelled) {
        return;
      }
      if (!snap.elements.length) {
        setPreview("empty");
        return;
      }
      const files = await loadFiles(fileIdsOf(snap.elements));
      const blob = await exportScene({
        type: "png",
        data: { elements: snap.elements as any, appState: snap.appState, files },
        config: {
          theme:
            api.getAppState().theme === THEME.DARK ? THEME.DARK : THEME.LIGHT,
          maxWidthOrHeight: 560,
          padding: 16,
        },
      });
      if (!cancelled) {
        url = URL.createObjectURL(blob);
        setPreview(url);
      }
    })().catch(console.error);
    return () => {
      cancelled = true;
      if (url) {
        URL.revokeObjectURL(url);
      }
    };
  }, [api, sceneId, selected]);

  const onSave = async () => {
    setBusy(true);
    try {
      await saveVersion(label.trim() || undefined);
      setLabel("");
      await refresh();
      api.setToast({ message: "Version saved", duration: 1500 });
    } finally {
      setBusy(false);
    }
  };

  const onRestore = async () => {
    if (!selected) {
      return;
    }
    setBusy(true);
    try {
      const snap = await loadSnapshot(sceneId, selected);
      if (snap) {
        await restore(snap);
        await refresh();
        setSelected(null);
        api.setToast({
          message: "Version restored (undo with ⌘Z)",
          duration: 2500,
        });
      }
    } finally {
      setBusy(false);
    }
  };

  let lastDay = "";

  return (
    <div className="canvas-panel">
      <Sidebar.Header>
        <div className="canvas-panel__title">Version history</div>
      </Sidebar.Header>

      <div className="canvas-history__save">
        <input
          className="canvas-input"
          placeholder="Name this version (optional)"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
          onKeyDown={(e) => {
            e.stopPropagation();
            if (e.key === "Enter") {
              onSave();
            }
          }}
        />
        <button className="canvas-btn" disabled={busy} onClick={onSave}>
          Save version
        </button>
      </div>

      {snapshots && !snapshots.length && (
        <div className="canvas-panel__empty">
          <div className="canvas-panel__empty-icon">{historyIcon}</div>
          <p>No versions yet.</p>
        </div>
      )}

      <div className="canvas-history__list">
        {snapshots?.map((snap) => {
          const day = dayLabel(snap.savedAt);
          const header = day !== lastDay ? day : null;
          lastDay = day;
          const isSelected = selected === snap.name;
          const name = snapshotLabel(snap);
          return (
            <div key={snap.name}>
              {header && <div className="canvas-history__day">{header}</div>}
              <button
                className={`canvas-history__item${isSelected ? " is-selected" : ""}`}
                onClick={() => setSelected(isSelected ? null : snap.name)}
              >
                <span className="canvas-history__time">
                  {timeFormat.format(snap.savedAt)}
                </span>
                {name && <span className="canvas-history__label">{name}</span>}
              </button>
              {isSelected && (
                <div className="canvas-history__preview">
                  {preview === "empty" ? (
                    <div className="canvas-history__blank">Empty canvas</div>
                  ) : preview ? (
                    <img src={preview} alt="" />
                  ) : (
                    <div className="canvas-history__blank">Loading…</div>
                  )}
                  <button
                    className="canvas-btn canvas-btn--primary"
                    disabled={busy}
                    onClick={onRestore}
                  >
                    Restore this version
                  </button>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
};
