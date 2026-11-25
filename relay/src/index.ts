// Canvas relay: connects people editing a shared scene and keeps the latest
// copy for whoever opens it next. Everything about the scene arrives
// encrypted with a key that only lives in share links (after the `#`), so
// the relay stores and forwards bytes it cannot read.
//
// One Durable Object per shared scene ("room"). It holds:
//   - the owner secret's hash (the owner's Mac manages links with it)
//   - share links: token hash → view | edit, revoked or not
//   - the latest encrypted snapshot, plus encrypted updates sent after it
// and fans live messages out over hibernating WebSockets.

import { DurableObject } from "cloudflare:workers";

export interface Env {
  ROOMS: DurableObjectNamespace<Room>;
  ASSETS?: Fetcher;
}

type Mode = "view" | "edit" | "owner";

/** what each socket remembers across hibernation */
type Attachment = { peer: string; link: string; mode: Mode };

const MAX_MESSAGE = 1024 * 1024; // Cloudflare's WebSocket message limit
const MAX_UPDATES = 400; // after this many, an editor is asked for a snapshot
const ROOM_ID = /^[A-Za-z0-9_-]{16,40}$/;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": "*",
    },
  });

const cors = () =>
  new Response(null, {
    headers: {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
      "access-control-allow-headers": "authorization, content-type",
      "access-control-max-age": "86400",
    },
  });

const randomId = (bytes = 16) => {
  const raw = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...raw))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
};

const sha256 = async (text: string) => {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(text),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
};

const bearer = (request: Request) =>
  request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/relay/")) {
      return env.ASSETS
        ? env.ASSETS.fetch(request)
        : new Response("Not found", { status: 404 });
    }
    if (request.method === "OPTIONS") {
      return cors();
    }

    // POST /relay/rooms → a new room and the secret that owns it
    if (url.pathname === "/relay/rooms" && request.method === "POST") {
      const roomId = randomId(15);
      const ownerSecret = randomId(32);
      const stub = env.ROOMS.get(env.ROOMS.idFromName(roomId));
      await stub.create(await sha256(ownerSecret));
      return json({ roomId, ownerSecret }, 201);
    }

    // /relay/rooms/:id[/…]
    const match = url.pathname.match(/^\/relay\/rooms\/([^/]+)(\/.*)?$/);
    if (!match || !ROOM_ID.test(match[1])) {
      return json({ error: "not found" }, 404);
    }
    const stub = env.ROOMS.get(env.ROOMS.idFromName(match[1]));
    return stub.fetch(
      new Request(
        new URL(`https://room${match[2] ?? "/"}${url.search}`),
        request,
      ),
    );
  },
} satisfies ExportedHandler<Env>;

export class Room extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.createTables();
  }

  private createTables() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v);
      CREATE TABLE IF NOT EXISTS links (
        hash TEXT PRIMARY KEY, id TEXT UNIQUE, mode TEXT NOT NULL,
        label TEXT, created INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS updates (seq INTEGER PRIMARY KEY, data BLOB NOT NULL);
    `);
  }

  private meta(key: string): any {
    return this.sql.exec("SELECT v FROM meta WHERE k = ?", key).toArray()[0]
      ?.v;
  }

  private setMeta(key: string, value: unknown) {
    this.sql.exec(
      "INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
      key,
      value as any,
    );
  }

  /** RPC from the Worker when a room is made */
  async create(ownerHash: string) {
    if (this.meta("owner")) {
      throw new Error("room exists");
    }
    this.setMeta("owner", ownerHash);
    this.setMeta("created", Date.now());
    this.setMeta("seq", 0);
  }

  private async isOwner(secret: string) {
    const owner = this.meta("owner");
    return !!owner && !!secret && (await sha256(secret)) === owner;
  }

  /** the mode a secret (owner secret or link token) grants, if any */
  private async modeFor(secret: string): Promise<{ mode: Mode; link: string } | null> {
    if (!secret) {
      return null;
    }
    if (await this.isOwner(secret)) {
      return { mode: "owner", link: "owner" };
    }
    const row = this.sql
      .exec(
        "SELECT id, mode, revoked FROM links WHERE hash = ?",
        await sha256(secret),
      )
      .toArray()[0];
    if (!row || row.revoked) {
      return null;
    }
    return { mode: row.mode as Mode, link: row.id as string };
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (!this.meta("owner")) {
      return json({ error: "not found" }, 404);
    }

    if (url.pathname === "/ws") {
      if (request.headers.get("upgrade") !== "websocket") {
        return json({ error: "expected a WebSocket" }, 426);
      }
      const pair = new WebSocketPair();
      // until it says hello with a token, a socket has no rights
      this.ctx.acceptWebSocket(pair[1]);
      pair[1].serializeAttachment(null);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    // everything below is the owner managing the room
    if (!(await this.isOwner(bearer(request)))) {
      return json({ error: "forbidden" }, 403);
    }

    if (url.pathname === "/links" && request.method === "POST") {
      const body = (await request.json().catch(() => ({}))) as {
        mode?: string;
        label?: string;
      };
      const mode = body.mode === "edit" ? "edit" : "view";
      const token = randomId(24);
      const id = randomId(9);
      this.sql.exec(
        "INSERT INTO links (hash, id, mode, label, created) VALUES (?, ?, ?, ?, ?)",
        await sha256(token),
        id,
        mode,
        (body.label ?? "").slice(0, 80),
        Date.now(),
      );
      return json({ id, token, mode }, 201);
    }

    if (url.pathname === "/links" && request.method === "GET") {
      const links = this.sql
        .exec(
          "SELECT id, mode, label, created, revoked FROM links ORDER BY created",
        )
        .toArray()
        .map((row) => ({
          ...row,
          revoked: !!row.revoked,
          online: this.liveSockets().filter((ws) => this.attachmentOf(ws)?.link === row.id).length,
        }));
      return json({ links });
    }

    const revoke = url.pathname.match(/^\/links\/([^/]+)$/);
    if (revoke && request.method === "DELETE") {
      this.sql.exec("UPDATE links SET revoked = 1 WHERE id = ?", revoke[1]);
      for (const ws of this.liveSockets().filter((ws) => this.attachmentOf(ws)?.link === revoke[1])) {
        ws.close(4003, "This link was turned off");
      }
      return json({ ok: true });
    }

    // stop sharing: forget everything
    if (url.pathname === "/" && request.method === "DELETE") {
      for (const ws of this.ctx.getWebSockets()) {
        ws.close(4004, "Sharing stopped");
      }
      await this.ctx.storage.deleteAll();
      this.createTables();
      return json({ ok: true });
    }

    return json({ error: "not found" }, 404);
  }

  // MARK: live

  private send(ws: WebSocket, message: unknown) {
    try {
      ws.send(JSON.stringify(message));
    } catch {}
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    if (typeof raw !== "string" || raw.length > MAX_MESSAGE) {
      ws.close(1009, "Message too big");
      return;
    }
    let message: any;
    try {
      message = JSON.parse(raw);
    } catch {
      ws.close(1003, "Bad message");
      return;
    }
    const me = ws.deserializeAttachment() as Attachment | null;

    if (!me) {
      if (message.type !== "hello") {
        ws.close(4001, "Say hello first");
        return;
      }
      const grant = await this.modeFor(String(message.token ?? ""));
      if (!grant) {
        ws.close(4003, "This link doesn't work anymore");
        return;
      }
      const attachment: Attachment = {
        peer: randomId(6),
        link: grant.link,
        mode: grant.mode,
      };
      ws.serializeAttachment(attachment);
      this.tagged.set(ws, attachment);
      this.send(ws, {
        type: "welcome",
        peer: attachment.peer,
        mode: grant.mode,
        snapshot: this.meta("snapshot") ?? null,
        snapshotSeq: this.meta("snapshotSeq") ?? 0,
        updates: this.sql
          .exec("SELECT seq, data FROM updates ORDER BY seq")
          .toArray()
          .map((row) => ({ seq: row.seq, data: row.data })),
        peers: this.livePeers(),
      });
      this.broadcastLive(
        { type: "joined", peer: attachment.peer, mode: grant.mode },
        ws,
      );
      return;
    }

    const canEdit = me.mode === "edit" || me.mode === "owner";
    switch (message.type) {
      case "update": {
        // an encrypted batch of changed elements
        if (!canEdit || typeof message.data !== "string") {
          return;
        }
        const seq = (this.meta("seq") ?? 0) + 1;
        this.setMeta("seq", seq);
        this.sql.exec(
          "INSERT INTO updates (seq, data) VALUES (?, ?)",
          seq,
          message.data,
        );
        this.send(ws, { type: "ack", seq, ref: message.ref });
        this.broadcastLive(
          { type: "update", seq, data: message.data, from: me.peer },
          ws,
        );
        const count = this.sql
          .exec("SELECT COUNT(*) AS n FROM updates")
          .toArray()[0].n as number;
        if (count > MAX_UPDATES) {
          this.send(ws, { type: "need-snapshot" });
        }
        return;
      }
      case "snapshot": {
        // the whole scene, encrypted, as of update `seq`
        if (!canEdit || typeof message.data !== "string") {
          return;
        }
        const upTo = Math.min(Number(message.seq) || 0, this.meta("seq") ?? 0);
        if (upTo < (this.meta("snapshotSeq") ?? 0)) {
          return; // an older picture than the one already kept
        }
        this.setMeta("snapshot", message.data);
        this.setMeta("snapshotSeq", upTo);
        this.sql.exec("DELETE FROM updates WHERE seq <= ?", upTo);
        return;
      }
      case "presence": {
        // cursors and names: passed on, never kept
        if (typeof message.data === "string" && message.data.length < 4096) {
          this.broadcastLive(
            { type: "presence", peer: me.peer, data: message.data },
            ws,
          );
        }
        return;
      }
    }
  }

  async webSocketClose(ws: WebSocket) {
    const me = this.attachmentOf(ws);
    this.tagged.delete(ws);
    if (me) {
      this.broadcastLive({ type: "left", peer: me.peer }, ws);
    }
  }

  async webSocketError(ws: WebSocket) {
    await this.webSocketClose(ws);
  }

  // Tags can't change after acceptWebSocket, so live sockets are found by
  // their attachment instead (it survives hibernation).
  private tagged = new Map<WebSocket, Attachment>();

  private attachmentOf(ws: WebSocket): Attachment | null {
    return (
      this.tagged.get(ws) ??
      ((ws.deserializeAttachment() as Attachment | null) || null)
    );
  }

  private liveSockets() {
    return this.ctx
      .getWebSockets()
      .filter((ws) => this.attachmentOf(ws) && ws.readyState === 1);
  }

  private livePeers() {
    return this.liveSockets().map((ws) => {
      const { peer, mode } = this.attachmentOf(ws)!;
      return { peer, mode };
    });
  }

  private broadcastLive(message: unknown, except?: WebSocket) {
    const text = JSON.stringify(message);
    for (const ws of this.liveSockets()) {
      if (ws !== except) {
        try {
          ws.send(text);
        } catch {}
      }
    }
  }
}
