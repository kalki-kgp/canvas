// Bridge to the Swift shell: a token-guarded REST store on the same origin,
// plus a WKScriptMessageHandler for window-level actions (title, fullscreen).

type Boot = { token: string; port: number; version: string };

declare global {
  interface Window {
    __CANVAS__?: Boot;
    webkit?: {
      messageHandlers?: Record<string, { postMessage: (msg: unknown) => void }>;
    };
  }
}

const boot: Boot | undefined = window.__CANVAS__;

export const isNative = !!boot;

export const TOKEN: string =
  boot?.token ??
  new URLSearchParams(location.search).get("t") ??
  sessionStorage.getItem("canvas-token") ??
  "";

try {
  if (TOKEN) {
    sessionStorage.setItem("canvas-token", TOKEN);
  }
} catch {}

export const PORT = boot?.port ?? Number(location.port || 41873);

export const api = (path: string, init: RequestInit = {}) =>
  fetch(`/api/${path}`, {
    ...init,
    headers: { ...(init.headers || {}), "X-Canvas-Token": TOKEN },
  });

/** URL usable from <img src> and similar, where headers can't be set */
export const blobURL = (path: string, bust?: number | string) =>
  `/api/blob/${path}?t=${encodeURIComponent(TOKEN)}${
    bust !== undefined ? `&v=${bust}` : ""
  }`;

const check = async (res: Response) => {
  if (!res.ok) {
    throw new Error(`${res.status} ${await res.text()}`);
  }
  return res;
};

/** the Mac app's store, over its local HTTP server */
const nativeBlobs = {
  async getJSON<T>(path: string): Promise<T | null> {
    const res = await api(`blob/${path}`);
    if (res.status === 404) {
      return null;
    }
    await check(res);
    return res.json();
  },
  async putJSON(path: string, data: unknown) {
    await check(
      await api(`blob/${path}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data),
      }),
    );
  },
  async putBlob(path: string, data: Blob) {
    await check(
      await api(`blob/${path}`, {
        method: "PUT",
        headers: { "Content-Type": data.type || "application/octet-stream" },
        body: data,
      }),
    );
  },
  async delete(path: string) {
    const res = await api(`blob/${path}`, { method: "DELETE" });
    if (res.status !== 404) {
      await check(res);
    }
  },
  /** files directly inside `dir`, newest first */
  async list(
    dir: string,
  ): Promise<{ name: string; size: number; mtime: number }[]> {
    const res = await api(`list/${dir}`);
    if (res.status === 404) {
      return [];
    }
    await check(res);
    return res.json();
  },
};

// In a plain browser (canvas.paperknife.app) there is no native store:
// the same paths live in IndexedDB instead.

type Stored = { data: unknown; size: number; mtime: number };

let dbPromise: Promise<IDBDatabase> | null = null;
const db = () =>
  (dbPromise ??= new Promise<IDBDatabase>((resolve, reject) => {
    const req = indexedDB.open("canvas", 1);
    req.onupgradeneeded = () => req.result.createObjectStore("blobs");
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  }));

const tx = async <T>(
  mode: IDBTransactionMode,
  run: (store: IDBObjectStore) => IDBRequest<T>,
) => {
  const store = (await db()).transaction("blobs", mode).objectStore("blobs");
  return new Promise<T>((resolve, reject) => {
    const req = run(store);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
};

const browserBlobs: typeof nativeBlobs & {
  getBlob(path: string): Promise<Blob | null>;
} = {
  async getJSON<T>(path: string): Promise<T | null> {
    const row = await tx<Stored | undefined>("readonly", (s) => s.get(path));
    return row ? (row.data as T) : null;
  },
  async putJSON(path: string, data: unknown) {
    // stored as a structured clone; size is only for listings
    const size = JSON.stringify(data)?.length ?? 0;
    await tx("readwrite", (s) =>
      s.put(
        { data: JSON.parse(JSON.stringify(data)), size, mtime: Date.now() },
        path,
      ),
    );
  },
  async putBlob(path: string, data: Blob) {
    await tx("readwrite", (s) =>
      s.put({ data, size: data.size, mtime: Date.now() }, path),
    );
  },
  async getBlob(path: string) {
    const row = await tx<Stored | undefined>("readonly", (s) => s.get(path));
    return row?.data instanceof Blob ? row.data : null;
  },
  async delete(path: string) {
    await tx("readwrite", (s) => s.delete(path));
  },
  async list(dir: string) {
    const prefix = `${dir.replace(/\/$/, "")}/`;
    const range = IDBKeyRange.bound(prefix, `${prefix}\uffff`);
    const keys = await tx<IDBValidKey[]>("readonly", (s) =>
      s.getAllKeys(range),
    );
    const rows = await tx<Stored[]>("readonly", (s) => s.getAll(range));
    return keys
      .map((key, i) => ({
        name: String(key).slice(prefix.length),
        size: rows[i].size,
        mtime: rows[i].mtime,
      }))
      .filter((entry) => !entry.name.includes("/"))
      .sort((a, b) => b.mtime - a.mtime);
  },
};

/** the Mac app (or a browser it opened with its token) uses its own store */
export const usesNativeStore = isNative || !!TOKEN;

export const blobs = usesNativeStore ? nativeBlobs : browserBlobs;

/** a stored image as a Blob (browser store only; the Mac app uses blobURL) */
export const getStoredBlob = (path: string) =>
  usesNativeStore ? Promise.resolve(null) : browserBlobs.getBlob(path);

export const postNative = (
  type: string,
  payload: Record<string, unknown> = {},
) => {
  window.webkit?.messageHandlers?.canvas?.postMessage({ type, ...payload });
};

export const setWindowFullscreen = (on: boolean) => {
  if (isNative) {
    postNative("fullscreen", { on });
  } else if (on) {
    document.documentElement.requestFullscreen?.().catch(() => {});
  } else if (document.fullscreenElement) {
    document.exitFullscreen?.().catch(() => {});
  }
};

/**
 * Builds a PDF natively from page images (data URLs) and asks where to save
 * it. Resolves false if the user cancelled.
 */
export const savePDF = async (name: string, pages: string[]) => {
  const res = await check(
    await api("pdf", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, pages }),
    }),
  );
  const { saved } = await res.json();
  return !!saved;
};

// Native → web events (menu items, files opened from Finder)
type NativeEvent =
  | { type: "menu"; action: string }
  | { type: "open-file"; name: string; contents: string }
  | { type: "add-library-hash"; hash: string };

const listeners = new Set<(e: NativeEvent) => void>();

export const onNativeEvent = (fn: (e: NativeEvent) => void) => {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
};

// events that arrive before anyone listens (e.g. a file opened at launch)
const pending: NativeEvent[] = [];

(window as any).canvasNative = {
  dispatch(event: NativeEvent) {
    if (!listeners.size) {
      pending.push(event);
      return;
    }
    listeners.forEach((fn) => fn(event));
  },
};

export const flushPendingNativeEvents = () => {
  const events = pending.splice(0);
  events.forEach((e) => listeners.forEach((fn) => fn(e)));
};
