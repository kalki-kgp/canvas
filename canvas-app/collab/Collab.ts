// A live connection between the open scene and its shared copy on the relay.
//
// Every copy of a shared scene is a full copy: people edit offline and their
// changes merge when they reconnect. Merging uses Excalidraw's own rule
// (`reconcileElements`): per element, the higher version wins; deletions are
// elements marked `isDeleted`, so they merge like any other change.
//
// The relay keeps the newest snapshot plus the updates sent after it, so the
// scene opens even while its owner's Mac is off. Editors upload a fresh
// snapshot now and then; the relay drops the updates it covers.

import {
  CaptureUpdateAction,
  reconcileElements,
  restoreElements,
} from "@excalidraw/excalidraw";

import type {
  ExcalidrawElement,
  OrderedExcalidrawElement,
} from "@excalidraw/element/types";

import type {
  AppState,
  Collaborator,
  ExcalidrawImperativeAPI,
  SocketId,
} from "@excalidraw/excalidraw/types";

import { RELAY, saveShare } from "./shares";
import { seal, unseal } from "./crypto";

import type { ShareInfo, ShareRole } from "./shares";

export type CollabState = "connecting" | "live" | "offline" | "ended";

export type CollabStatus = {
  state: CollabState;
  role: ShareRole;
  /** other people here right now */
  peers: number;
  ended?: ShareInfo["ended"];
};

type Payload = { elements: readonly ExcalidrawElement[]; name?: string };
type Presence = {
  pointer?: { x: number; y: number; tool: "pointer" | "laser" };
  button?: "up" | "down";
  name?: string;
  selected?: AppState["selectedElementIds"];
};

/** stay under Cloudflare's 1 MiB WebSocket message limit */
const MAX_SEALED = 900 * 1024;
const SEND_EVERY_MS = 60;
const PRESENCE_EVERY_MS = 50;
/** upload a snapshot this long after the last change… */
const SNAPSHOT_AFTER_MS = 8_000;
/** …but at least this often while changes keep coming */
const SNAPSHOT_AT_LEAST_MS = 60_000;

export class CollabSession {
  private ws: WebSocket | null = null;
  private stopped = false;
  private ready = false;
  private role: ShareRole;
  private retries = 0;
  private retryTimer = 0;
  private sendTimer = 0;
  private snapshotTimer = 0;
  private lastSnapshotAt = Date.now();
  private presenceAt = 0;
  private presenceTimer = 0;
  private pendingPresence: Presence | null = null;
  /** the newest version of each element the relay is known to have */
  private known = new Map<string, number>();
  /** the newest relay update this copy has taken in */
  private seq = 0;
  private peers = new Map<string, Collaborator>();
  private status: CollabStatus;

  constructor(
    private sceneId: string,
    private info: ShareInfo,
    private api: ExcalidrawImperativeAPI,
    private opts: {
      userName: string;
      sceneName: () => string;
      onStatus: (status: CollabStatus) => void;
      onRename?: (name: string) => void;
    },
  ) {
    this.role = info.role;
    this.status = { state: "connecting", role: info.role, peers: 0 };
    window.addEventListener("online", this.onOnline);
    this.connect();
  }

  get canEdit() {
    return this.role === "owner" || this.role === "edit";
  }

  stop() {
    this.stopped = true;
    window.removeEventListener("online", this.onOnline);
    clearTimeout(this.retryTimer);
    clearTimeout(this.sendTimer);
    clearTimeout(this.presenceTimer);
    // leave the relay a fresh picture on the way out
    if (this.ready && this.canEdit) {
      clearTimeout(this.snapshotTimer);
      this.sendSnapshot().finally(() => this.ws?.close(1000));
    } else {
      this.ws?.close(1000);
    }
    this.setPeers(new Map());
  }

  // MARK: connection

  private onOnline = () => {
    if (!this.ws && !this.stopped) {
      clearTimeout(this.retryTimer);
      this.connect();
    }
  };

  private setStatus(patch: Partial<CollabStatus>) {
    this.status = { ...this.status, ...patch, role: this.role };
    this.opts.onStatus(this.status);
  }

  private connect() {
    if (this.stopped) {
      return;
    }
    this.setStatus({ state: this.retries ? "offline" : "connecting" });
    const ws = new WebSocket(
      `${RELAY.replace(/^http/, "ws")}/relay/rooms/${this.info.roomId}/ws`,
    );
    this.ws = ws;
    ws.onopen = () => {
      const token =
        this.info.role === "owner" ? this.info.ownerSecret : this.info.token;
      ws.send(JSON.stringify({ type: "hello", token }));
    };
    ws.onmessage = (event) => {
      this.receive(JSON.parse(event.data)).catch((error) =>
        console.error("collab: couldn't apply a message", error),
      );
    };
    ws.onclose = (event) => {
      if (this.ws !== ws) {
        return;
      }
      this.ws = null;
      this.ready = false;
      this.setPeers(new Map());
      if (this.stopped) {
        return;
      }
      if (event.code === 4003 || event.code === 4004) {
        const ended = event.code === 4003 ? "revoked" : "stopped";
        this.stopped = true;
        if (this.info.role !== "owner") {
          this.info = { ...this.info, ended };
          saveShare(this.sceneId, this.info, { quiet: true }).catch(
            console.error,
          );
        }
        this.setStatus({ state: "ended", ended });
        return;
      }
      // offline, asleep or the relay restarted: try again, backing off
      this.retries++;
      this.setStatus({ state: "offline" });
      const delay = Math.min(30_000, 1000 * 2 ** Math.min(this.retries - 1, 5));
      this.retryTimer = window.setTimeout(() => this.connect(), delay);
    };
  }

  private send(message: Record<string, unknown>) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message));
      return true;
    }
    return false;
  }

  // MARK: incoming

  private async receive(message: any) {
    switch (message.type) {
      case "welcome": {
        this.role = message.mode;
        if (this.info.role !== message.mode && this.info.role !== "owner") {
          this.info = { ...this.info, role: message.mode };
          saveShare(this.sceneId, this.info, { quiet: true }).catch(
            console.error,
          );
        }
        // the relay's copy: its snapshot, then the updates after it
        const remote = new Map<string, ExcalidrawElement>();
        const take = (elements: readonly ExcalidrawElement[]) => {
          for (const el of elements) {
            const had = remote.get(el.id);
            if (!had || el.version > had.version) {
              remote.set(el.id, el);
            }
          }
        };
        if (message.snapshot) {
          const snapshot = await unseal<Payload>(
            this.info.key,
            message.snapshot,
          );
          take(snapshot.elements);
          if (snapshot.name && this.info.role !== "owner") {
            this.opts.onRename?.(snapshot.name);
          }
        }
        let name: string | undefined;
        for (const update of message.updates as {
          seq: number;
          data: string;
        }[]) {
          const payload = await unseal<Payload>(this.info.key, update.data);
          take(payload.elements);
          name = payload.name ?? name;
          this.seq = Math.max(this.seq, update.seq);
        }
        if (name && this.info.role !== "owner") {
          this.opts.onRename?.(name);
        }
        this.seq = Math.max(this.seq, message.snapshotSeq ?? 0);
        this.known = new Map(
          [...remote.values()].map((el) => [el.id, el.version]),
        );
        this.merge([...remote.values()]);

        this.ready = true;
        this.retries = 0;
        this.peers = new Map();
        this.setStatus({ state: "live", peers: message.peers.length - 1 });
        // whatever was drawn here while offline goes up now
        this.flushLocal();
        if (
          this.canEdit &&
          (!message.snapshot || message.updates.length > 50)
        ) {
          this.scheduleSnapshot(1500);
        }
        this.sendPresence({ name: this.opts.userName });
        return;
      }
      case "update": {
        const payload = await unseal<Payload>(this.info.key, message.data);
        this.seq = Math.max(this.seq, message.seq);
        if (payload.name && this.info.role !== "owner") {
          this.opts.onRename?.(payload.name);
        }
        for (const el of payload.elements) {
          if ((this.known.get(el.id) ?? -1) < el.version) {
            this.known.set(el.id, el.version);
          }
        }
        this.merge(payload.elements);
        this.scheduleSnapshot();
        return;
      }
      case "ack":
        this.seq = Math.max(this.seq, message.seq);
        return;
      case "need-snapshot":
        this.scheduleSnapshot(0);
        return;
      case "presence": {
        const presence = await unseal<Presence>(this.info.key, message.data);
        const peers = new Map(this.peers);
        const before = peers.get(message.peer);
        peers.set(message.peer, {
          ...before,
          id: message.peer,
          socketId: message.peer as SocketId,
          username: presence.name ?? before?.username ?? "Someone",
          pointer: presence.pointer ?? before?.pointer,
          button: presence.button ?? before?.button,
          selectedElementIds: presence.selected ?? before?.selectedElementIds,
        });
        this.setPeers(peers);
        return;
      }
      case "joined":
        this.setStatus({ peers: this.status.peers + 1 });
        // say hello so the newcomer sees this cursor's name right away
        this.sendPresence({ name: this.opts.userName });
        return;
      case "left": {
        const peers = new Map(this.peers);
        peers.delete(message.peer);
        this.setPeers(peers);
        this.setStatus({ peers: Math.max(0, this.status.peers - 1) });
      }
    }
  }

  /** folds remote elements into the scene without touching undo history */
  private merge(remote: readonly ExcalidrawElement[]) {
    if (!remote.length) {
      return;
    }
    const restored = restoreElements(remote, null);
    const merged = reconcileElements(
      this.api.getSceneElementsIncludingDeleted() as OrderedExcalidrawElement[],
      restored as any,
      this.api.getAppState(),
    );
    this.api.updateScene({
      elements: merged,
      captureUpdate: CaptureUpdateAction.NEVER,
    });
  }

  private setPeers(peers: Map<string, Collaborator>) {
    this.peers = peers;
    this.api.updateScene({
      collaborators: new Map(
        [...peers.entries()].map(([id, c]) => [id as SocketId, c]),
      ),
    });
  }

  // MARK: outgoing

  /** the scene changed here; send what's new soon */
  localChanged() {
    if (!this.sendTimer) {
      this.sendTimer = window.setTimeout(() => {
        this.sendTimer = 0;
        this.flushLocal();
      }, SEND_EVERY_MS);
    }
  }

  private flushLocal() {
    if (!this.ready || !this.canEdit) {
      return;
    }
    const changed = this.api
      .getSceneElementsIncludingDeleted()
      .filter((el) => (this.known.get(el.id) ?? -1) < el.version);
    if (!changed.length) {
      return;
    }
    // mark first so changes made while sealing aren't lost or doubled
    for (const el of changed) {
      this.known.set(el.id, el.version);
    }
    this.sendElements(changed).catch((error) => {
      console.error("collab: couldn't send changes", error);
      for (const el of changed) {
        this.known.delete(el.id);
      }
    });
    this.scheduleSnapshot();
  }

  /** seals and sends, splitting batches that would be too big */
  private async sendElements(elements: readonly ExcalidrawElement[]) {
    // the owner's scene name travels along, so renames reach everyone
    const data = await seal(this.info.key, {
      elements,
      name: this.info.role === "owner" ? this.opts.sceneName() : undefined,
    });
    if (data.length > MAX_SEALED && elements.length > 1) {
      const half = Math.ceil(elements.length / 2);
      await this.sendElements(elements.slice(0, half));
      await this.sendElements(elements.slice(half));
      return;
    }
    if (data.length > MAX_SEALED) {
      console.warn("collab: an element is too big to share", elements[0]?.id);
      return;
    }
    if (!this.send({ type: "update", data })) {
      throw new Error("not connected");
    }
  }

  private scheduleSnapshot(delay = SNAPSHOT_AFTER_MS) {
    if (!this.canEdit) {
      return;
    }
    clearTimeout(this.snapshotTimer);
    const overdue = Date.now() - this.lastSnapshotAt > SNAPSHOT_AT_LEAST_MS;
    this.snapshotTimer = window.setTimeout(
      () => this.sendSnapshot().catch(console.error),
      overdue ? Math.min(delay, 1000) : delay,
    );
  }

  private async sendSnapshot() {
    if (!this.ready || !this.canEdit) {
      return;
    }
    const seq = this.seq;
    const data = await seal(this.info.key, {
      elements: this.api.getSceneElementsIncludingDeleted(),
      name: this.opts.sceneName(),
    });
    if (data.length > MAX_SEALED) {
      // too big for one message: the relay keeps the updates instead
      return;
    }
    if (this.send({ type: "snapshot", seq, data })) {
      this.lastSnapshotAt = Date.now();
    }
  }

  /** cursor moves, throttled */
  pointer(payload: {
    pointer: { x: number; y: number; tool: "pointer" | "laser" };
    button: "up" | "down";
  }) {
    this.sendPresence({
      pointer: payload.pointer,
      button: payload.button,
      name: this.opts.userName,
      selected: this.api.getAppState().selectedElementIds,
    });
  }

  private sendPresence(presence: Presence) {
    this.pendingPresence = { ...this.pendingPresence, ...presence };
    const wait = PRESENCE_EVERY_MS - (Date.now() - this.presenceAt);
    if (this.presenceTimer) {
      return;
    }
    this.presenceTimer = window.setTimeout(async () => {
      this.presenceTimer = 0;
      const next = this.pendingPresence;
      this.pendingPresence = null;
      if (!next || !this.ready) {
        return;
      }
      this.presenceAt = Date.now();
      this.send({ type: "presence", data: await seal(this.info.key, next) });
    }, Math.max(0, wait));
  }
}
