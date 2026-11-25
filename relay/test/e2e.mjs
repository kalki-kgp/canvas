// End-to-end test of the relay against `wrangler dev` (local, nothing deployed).
//   npm test            starts wrangler dev on a spare port, runs, stops it
//   RELAY=http://… npm test   runs against a relay that is already up
import { spawn } from "node:child_process";
import assert from "node:assert/strict";

const PORT = 8790 + Math.floor(Math.random() * 100);
let base = process.env.RELAY;
let dev;

const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const startDev = async () => {
  dev = spawn("npx", ["wrangler", "dev", "--port", String(PORT), "--ip", "127.0.0.1"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  base = `http://127.0.0.1:${PORT}`;
  for (let i = 0; i < 60; i++) {
    try {
      await fetch(`${base}/relay/rooms/xxxxxxxxxxxxxxxxxxxx`);
      return;
    } catch {
      await sleep(500);
    }
  }
  throw new Error("wrangler dev did not start");
};

/** waits until a client's socket closes, then returns the close code */
const closeCode = async (client, ms = 5000) => {
  const t = Date.now();
  while (!client.closed && Date.now() - t < ms) await sleep(25);
  return client.closed?.code;
};

const api = async (method, path, { secret, body } = {}) => {
  const res = await fetch(`${base}/relay${path}`, {
    method,
    headers: {
      ...(secret ? { authorization: `Bearer ${secret}` } : {}),
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: await res.json().catch(() => null) };
};

/** a client socket that records what it receives */
const connect = (roomId, token) =>
  new Promise((resolve, reject) => {
    const ws = new WebSocket(`${base.replace("http", "ws")}/relay/rooms/${roomId}/ws`);
    const inbox = [];
    const client = {
      ws,
      inbox,
      closed: null,
      send: (m) => ws.send(JSON.stringify(m)),
      next: async (type, ms = 3000) => {
        const t = Date.now();
        while (Date.now() - t < ms) {
          const i = inbox.findIndex((m) => m.type === type);
          if (i >= 0) return inbox.splice(i, 1)[0];
          if (client.closed) return null;
          await sleep(20);
        }
        return null;
      },
    };
    ws.onmessage = (e) => inbox.push(JSON.parse(e.data));
    ws.onclose = (e) => (client.closed = { code: e.code, reason: e.reason });
    ws.onerror = () => {};
    ws.onopen = () => {
      client.send({ type: "hello", token });
      resolve(client);
    };
    setTimeout(() => reject(new Error("connect timeout")), 5000);
  });

const run = async () => {
  if (!base) await startDev();
  let n = 0;
  const step = (name) => log(`[${++n}] ${name}`);

  step("create a room");
  const room = await api("POST", "/rooms");
  assert.equal(room.status, 201);
  const { roomId, ownerSecret } = room.body;

  step("only the owner can make links");
  assert.equal((await api("POST", `/rooms/${roomId}/links`, { body: { mode: "edit" } })).status, 403);
  assert.equal((await api("POST", `/rooms/${roomId}/links`, { secret: "nope", body: { mode: "edit" } })).status, 403);
  const edit = (await api("POST", `/rooms/${roomId}/links`, { secret: ownerSecret, body: { mode: "edit", label: "team" } })).body;
  const view = (await api("POST", `/rooms/${roomId}/links`, { secret: ownerSecret, body: { mode: "view" } })).body;
  assert.equal(edit.mode, "edit");
  assert.equal(view.mode, "view");

  step("owner, editor and viewer join");
  const owner = await connect(roomId, ownerSecret);
  const welcomeOwner = await owner.next("welcome");
  assert.equal(welcomeOwner.mode, "owner");
  assert.equal(welcomeOwner.snapshot, null);
  const editor = await connect(roomId, edit.token);
  assert.equal((await editor.next("welcome")).mode, "edit");
  const viewer = await connect(roomId, view.token);
  const welcomeViewer = await viewer.next("welcome");
  assert.equal(welcomeViewer.mode, "view");
  assert.equal(welcomeViewer.peers.length, 3);

  step("a bad token is turned away");
  const stranger = await connect(roomId, "not-a-token");
  assert.equal(await closeCode(stranger), 4003);

  step("an editor's update reaches the others, with an ack");
  editor.send({ type: "update", data: "ENC(update-1)", ref: "r1" });
  assert.equal((await editor.next("ack")).seq, 1);
  assert.equal((await viewer.next("update")).data, "ENC(update-1)");
  assert.equal((await owner.next("update")).data, "ENC(update-1)");

  step("a viewer's update is ignored");
  viewer.send({ type: "update", data: "ENC(sneaky)" });
  assert.equal(await editor.next("update", 1500), null);

  step("presence is passed on");
  viewer.send({ type: "presence", data: "ENC(cursor)" });
  assert.equal((await editor.next("presence")).data, "ENC(cursor)");

  step("snapshot replaces the updates it covers");
  owner.send({ type: "update", data: "ENC(update-2)" });
  await owner.next("ack");
  owner.send({ type: "snapshot", seq: 1, data: "ENC(snapshot@1)" });
  await sleep(1000);
  const late = await connect(roomId, view.token);
  const welcomeLate = await late.next("welcome");
  assert.equal(welcomeLate.snapshot, "ENC(snapshot@1)");
  assert.equal(welcomeLate.snapshotSeq, 1);
  assert.deepEqual(welcomeLate.updates.map((u) => u.data), ["ENC(update-2)"]);

  step("an older snapshot can't replace a newer one");
  owner.send({ type: "snapshot", seq: 0, data: "ENC(stale)" });
  await sleep(1000);
  const late2 = await connect(roomId, view.token);
  assert.equal((await late2.next("welcome")).snapshot, "ENC(snapshot@1)");

  step("the owner lists links with who's online");
  const links = (await api("GET", `/rooms/${roomId}/links`, { secret: ownerSecret })).body.links;
  assert.equal(links.length, 2);
  assert.equal(links.find((l) => l.id === view.id).online, 3);

  step("revoking a link disconnects it and keeps it out");
  assert.equal((await api("DELETE", `/rooms/${roomId}/links/${view.id}`, { secret: ownerSecret })).status, 200);
  await sleep(300);
  assert.equal(await closeCode(viewer), 4003);
  assert.equal(await closeCode(late), 4003);
  assert.equal(editor.closed, null);
  const again = await connect(roomId, view.token);
  await sleep(300);
  assert.equal(await closeCode(again), 4003);

  step("stop sharing removes the room");
  assert.equal((await api("DELETE", `/rooms/${roomId}`, { secret: ownerSecret })).status, 200);
  await sleep(300);
  assert.equal(await closeCode(editor), 4004);
  assert.equal((await api("GET", `/rooms/${roomId}/links`, { secret: ownerSecret })).status, 404);

  for (const c of [owner, editor, viewer, stranger, late, late2, again]) {
    try { c.ws.close(); } catch {}
  }
  log(`all ${n} checks passed`);
};

run()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(() => dev?.kill());
