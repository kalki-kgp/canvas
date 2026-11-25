import {
  mergeLibraryItems,
  restoreLibraryItems,
  serializeAsJSON,
} from "@excalidraw/excalidraw";

import { blobs } from "./native";
import {
  createScene,
  fileIdsOf,
  getSceneMeta,
  loadFiles,
  loadSceneDoc,
  saveFiles,
} from "./store";

import type { SceneDoc } from "./store";
import type { LibraryPersistenceAdapter } from "@excalidraw/excalidraw/data/library";
import type { BinaryFiles, LibraryItems } from "@excalidraw/excalidraw/types";

const baseName = (name: string) =>
  name.replace(/\.(excalidraw|excalidrawlib|json|png|svg)$/i, "") || "Untitled";

/**
 * Imports a `.excalidraw` (scene) or `.excalidrawlib` (library) file's text.
 * Scenes become a new scene in the workspace, returned so it can be opened.
 */
export const importSceneFile = async (name: string, contents: string) => {
  let data: any;
  try {
    data = JSON.parse(contents);
  } catch {
    alert(`“${name}” isn't a valid Excalidraw file.`);
    return null;
  }

  if (data?.type === "excalidrawlib") {
    await addToLibrary(
      restoreLibraryItems(data.libraryItems ?? data.library ?? [], "unpublished"),
    );
    alert(`Added “${baseName(name)}” to your library.`);
    return null;
  }

  if (data?.type !== "excalidraw" || !Array.isArray(data.elements)) {
    alert(`“${name}” isn't an Excalidraw scene.`);
    return null;
  }

  if (data.files) {
    await saveFiles(data.files as BinaryFiles);
  }

  const doc: SceneDoc = {
    type: "excalidraw",
    version: 2,
    source: "canvas",
    elements: data.elements,
    appState: data.appState ?? {},
    canvas: data.canvas,
  };
  return createScene({ name: baseName(name), doc });
};

const download = (filename: string, blob: Blob) => {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
};

/** Downloads a stored scene as a standalone `.excalidraw` file (with images) */
export const exportSceneFile = async (id: string) => {
  const meta = getSceneMeta(id);
  const doc = await loadSceneDoc(id);
  if (!meta || !doc) {
    return;
  }
  const files = await loadFiles(fileIdsOf(doc.elements));
  const json = serializeAsJSON(
    doc.elements,
    { ...doc.appState, name: meta.name },
    files,
    "local",
  );
  download(
    `${meta.name}.excalidraw`,
    new Blob([json], { type: "application/vnd.excalidraw+json" }),
  );
};

// ---------------------------------------------------------------------------
// library
// ---------------------------------------------------------------------------

const LIBRARY_PATH = "library.json";

export const libraryAdapter: LibraryPersistenceAdapter = {
  async load() {
    const data = await blobs.getJSON<{ libraryItems: LibraryItems }>(
      LIBRARY_PATH,
    );
    return { libraryItems: data?.libraryItems ?? [] };
  },
  async save({ libraryItems }) {
    await blobs.putJSON(LIBRARY_PATH, { libraryItems });
  },
};

const addToLibrary = async (items: LibraryItems) => {
  const { libraryItems } = (await libraryAdapter.load({
    source: "load",
  })) ?? { libraryItems: [] };
  await libraryAdapter.save({
    libraryItems: mergeLibraryItems(libraryItems as LibraryItems, items),
  });
};
