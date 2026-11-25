// The scene workspace: an index of scenes and collections, scene documents,
// image files, thumbnails and version history — all kept by the native store
// under ~/Library/Application Support/Canvas.

import { useSyncExternalStore } from "react";

import { blobs } from "./native";

import type { ExcalidrawElement, FileId } from "@excalidraw/element/types";
import type {
  AppState,
  BinaryFileData,
  BinaryFiles,
} from "@excalidraw/excalidraw/types";

export type SceneMeta = {
  id: string;
  name: string;
  collectionId: string | null;
  createdAt: number;
  updatedAt: number;
  /** bumps whenever the thumbnail is rewritten */
  thumbAt?: number;
  starred?: boolean;
};

export type Collection = { id: string; name: string; createdAt: number };

type Index = {
  version: 1;
  scenes: SceneMeta[];
  collections: Collection[];
};

/** What a scene document stores, besides the standard excalidraw fields */
export type CanvasSceneExtras = {
  /** frame ids in slide order */
  slides?: string[];
};

export type SceneDoc = {
  type: "excalidraw";
  version: 2;
  source: string;
  elements: readonly ExcalidrawElement[];
  appState: Partial<AppState>;
  canvas?: CanvasSceneExtras;
};

export type Snapshot = SceneDoc & {
  savedAt: number;
  label?: string;
};

export const newId = () =>
  Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

// ---------------------------------------------------------------------------
// index (in memory, mirrored to index.json; writes are serialized)
// ---------------------------------------------------------------------------

let index: Index = { version: 1, scenes: [], collections: [] };
let loaded = false;
const subscribers = new Set<() => void>();
let writeChain: Promise<unknown> = Promise.resolve();

const emit = () => subscribers.forEach((fn) => fn());

const persistIndex = () => {
  const snapshot = index;
  writeChain = writeChain
    .then(() => blobs.putJSON("index.json", snapshot))
    .catch((error) => console.error("index save failed", error));
  return writeChain;
};

const setIndex = (next: Index) => {
  index = next;
  emit();
  return persistIndex();
};

export const loadIndex = async () => {
  if (!loaded) {
    const data = await blobs.getJSON<Index>("index.json");
    if (data) {
      index = data;
    }
    loaded = true;
    emit();
  }
  return index;
};

export const getIndex = () => index;

export const subscribeIndex = (fn: () => void) => {
  subscribers.add(fn);
  return () => {
    subscribers.delete(fn);
  };
};

export const useIndex = () =>
  useSyncExternalStore(
    (fn) => {
      subscribers.add(fn);
      return () => {
        subscribers.delete(fn);
      };
    },
    () => index,
  );

export const getSceneMeta = (id: string) =>
  index.scenes.find((s) => s.id === id) ?? null;

export const updateSceneMeta = (id: string, patch: Partial<SceneMeta>) =>
  setIndex({
    ...index,
    scenes: index.scenes.map((s) => (s.id === id ? { ...s, ...patch } : s)),
  });

// ---------------------------------------------------------------------------
// scenes
// ---------------------------------------------------------------------------

const sceneDocPath = (id: string) => `scenes/${id}.json`;

export const emptySceneDoc = (): SceneDoc => ({
  type: "excalidraw",
  version: 2,
  source: "canvas",
  elements: [],
  appState: {},
});

export const createScene = async (
  opts: {
    name?: string;
    collectionId?: string | null;
    doc?: SceneDoc;
  } = {},
) => {
  const now = Date.now();
  const meta: SceneMeta = {
    id: newId(),
    name: opts.name?.trim() || "Untitled",
    collectionId: opts.collectionId ?? null,
    createdAt: now,
    updatedAt: now,
  };
  await blobs.putJSON(sceneDocPath(meta.id), opts.doc ?? emptySceneDoc());
  await setIndex({ ...index, scenes: [meta, ...index.scenes] });
  return meta;
};

export const loadSceneDoc = (id: string) =>
  blobs.getJSON<SceneDoc>(sceneDocPath(id));

export const saveSceneDoc = async (id: string, doc: SceneDoc) => {
  await blobs.putJSON(sceneDocPath(id), doc);
  await updateSceneMeta(id, { updatedAt: Date.now() });
};

export const renameScene = (id: string, name: string) =>
  updateSceneMeta(id, { name: name.trim() || "Untitled" });

export const moveScene = (id: string, collectionId: string | null) =>
  updateSceneMeta(id, { collectionId });

export const toggleStar = (id: string) =>
  updateSceneMeta(id, { starred: !getSceneMeta(id)?.starred });

export const duplicateScene = async (id: string) => {
  const meta = getSceneMeta(id);
  const doc = await loadSceneDoc(id);
  if (!meta || !doc) {
    return null;
  }
  return createScene({
    name: `${meta.name} (copy)`,
    collectionId: meta.collectionId,
    doc,
  });
};

export const deleteScene = async (id: string) => {
  await setIndex({
    ...index,
    scenes: index.scenes.filter((s) => s.id !== id),
  });
  await blobs.delete(sceneDocPath(id));
  await blobs.delete(`thumbs/${id}.png`);
  const snaps = await blobs.list(`history/${id}`);
  await Promise.all(snaps.map((s) => blobs.delete(`history/${id}/${s.name}`)));
};

// ---------------------------------------------------------------------------
// collections
// ---------------------------------------------------------------------------

export const createCollection = async (name: string) => {
  const collection: Collection = {
    id: newId(),
    name: name.trim() || "Untitled collection",
    createdAt: Date.now(),
  };
  await setIndex({
    ...index,
    collections: [...index.collections, collection],
  });
  return collection;
};

export const renameCollection = (id: string, name: string) =>
  setIndex({
    ...index,
    collections: index.collections.map((c) =>
      c.id === id ? { ...c, name: name.trim() || c.name } : c,
    ),
  });

/** scenes in the collection move back to "no collection" */
export const deleteCollection = (id: string) =>
  setIndex({
    ...index,
    collections: index.collections.filter((c) => c.id !== id),
    scenes: index.scenes.map((s) =>
      s.collectionId === id ? { ...s, collectionId: null } : s,
    ),
  });

// ---------------------------------------------------------------------------
// files (images). Content-addressed by excalidraw's file id, shared by all
// scenes and snapshots, so they're never deleted.
// ---------------------------------------------------------------------------

const savedFileIds = new Set<string>();

export const saveFiles = async (files: BinaryFiles) => {
  const fresh = Object.values(files).filter((f) => !savedFileIds.has(f.id));
  await Promise.all(
    fresh.map(async (file) => {
      await blobs.putJSON(`files/${file.id}.json`, file);
      savedFileIds.add(file.id);
    }),
  );
};

export const loadFiles = async (ids: Iterable<FileId>) => {
  const files: BinaryFiles = {};
  await Promise.all(
    [...new Set(ids)].map(async (id) => {
      const file = await blobs.getJSON<BinaryFileData>(`files/${id}.json`);
      if (file) {
        files[id] = file;
        savedFileIds.add(id);
      }
    }),
  );
  return files;
};

export const fileIdsOf = (elements: readonly ExcalidrawElement[]) =>
  elements.flatMap((el) =>
    el.type === "image" && el.fileId ? [el.fileId] : [],
  );

// ---------------------------------------------------------------------------
// thumbnails
// ---------------------------------------------------------------------------

export const saveThumbnail = async (id: string, png: Blob) => {
  await blobs.putBlob(`thumbs/${id}.png`, png);
  await updateSceneMeta(id, { thumbAt: Date.now() });
};

// ---------------------------------------------------------------------------
// version history
// ---------------------------------------------------------------------------

export type SnapshotEntry = { name: string; savedAt: number; label?: string };

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/** `<savedAt>.json` or `<savedAt>--<label>.json` */
const parseSnapshotName = (name: string): SnapshotEntry | null => {
  const match = name.match(/^(\d+)(?:--(.+))?\.json$/);
  if (!match) {
    return null;
  }
  return {
    name,
    savedAt: Number(match[1]),
    label: match[2],
  };
};

export const listSnapshots = async (sceneId: string) =>
  (await blobs.list(`history/${sceneId}`))
    .map((f) => parseSnapshotName(f.name))
    .filter((s): s is SnapshotEntry => !!s)
    .sort((a, b) => b.savedAt - a.savedAt);

export const loadSnapshot = (sceneId: string, name: string) =>
  blobs.getJSON<Snapshot>(`history/${sceneId}/${name}`);

export const saveSnapshot = async (
  sceneId: string,
  doc: SceneDoc,
  label?: string,
) => {
  const savedAt = Date.now();
  // labels go in the file name so listing doesn't need to read every file
  // ("_" itself is escaped first so the mapping reverses cleanly)
  const safeLabel = label
    ? `--${encodeURIComponent(label.slice(0, 60))
        .replace(/_/g, "%5F")
        .replace(/%/g, "_")}`
    : "";
  const name = `${savedAt}${safeLabel}.json`;
  const snapshot: Snapshot = { ...doc, savedAt, label };
  await blobs.putJSON(`history/${sceneId}/${name}`, snapshot);
  await thinSnapshots(sceneId);
  return name;
};

/**
 * Keeps every snapshot from the last day, the newest per hour for a week,
 * then the newest per day. Labelled snapshots are always kept.
 */
const thinSnapshots = async (sceneId: string) => {
  const now = Date.now();
  const seen = new Set<string>();
  const doomed: string[] = [];
  for (const snap of await listSnapshots(sceneId)) {
    if (snap.label) {
      continue;
    }
    const age = now - snap.savedAt;
    if (age < DAY) {
      continue;
    }
    const bucket =
      age < 7 * DAY
        ? `h${Math.floor(snap.savedAt / HOUR)}`
        : `d${Math.floor(snap.savedAt / DAY)}`;
    if (seen.has(bucket)) {
      doomed.push(snap.name);
    } else {
      seen.add(bucket);
    }
  }
  await Promise.all(
    doomed.map((name) => blobs.delete(`history/${sceneId}/${name}`)),
  );
};

// snapshot labels were made filename-safe; turn them back for display
export const snapshotLabel = (s: SnapshotEntry) =>
  s.label
    ? (() => {
        try {
          return decodeURIComponent(s.label.replace(/_/g, "%"));
        } catch {
          return s.label;
        }
      })()
    : undefined;

// ---------------------------------------------------------------------------
// preferences & library
// ---------------------------------------------------------------------------

export type Prefs = {
  theme?: "light" | "dark" | "system";
  langCode?: string;
};

export const loadPrefs = async () =>
  (await blobs.getJSON<Prefs>("prefs.json")) ?? {};

export const savePrefs = (prefs: Prefs) => blobs.putJSON("prefs.json", prefs);
