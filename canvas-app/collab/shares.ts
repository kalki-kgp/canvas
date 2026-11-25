// Which scenes are shared, how, and talking to the relay about them.
//
// A share link looks like
//   https://canvas.paperknife.app/s/<roomId>#k=<key>&t=<token>
// Everything after `#` stays in the browser: the relay never sees the key.

import { generateEncryptionKey } from "@excalidraw/excalidraw/data/encryption";

import { blobs } from "../data/native";

export const RELAY = "https://canvas.paperknife.app";

export type ShareRole = "owner" | "edit" | "view";

export type ShareLink = {
  id: string;
  token: string;
  mode: "view" | "edit";
  label?: string;
  created: number;
};

/** what this Mac knows about a shared scene (stored next to the scene) */
export type ShareInfo = {
  roomId: string;
  key: string;
  role: ShareRole;
  /** owner: manages links with this */
  ownerSecret?: string;
  /** owner: the links made so far (the relay only keeps their hashes) */
  links?: ShareLink[];
  /** guest: the link they joined with */
  token?: string;
  /** set when the owner turned the link off or stopped sharing */
  ended?: "revoked" | "stopped";
};

const path = (sceneId: string) => `shares/${sceneId}.json`;

const cache = new Map<string, ShareInfo | null>();
const listeners = new Set<(sceneId: string) => void>();

export const onShareChange = (fn: (sceneId: string) => void) => {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
};

export const loadShare = async (sceneId: string) => {
  if (!cache.has(sceneId)) {
    cache.set(sceneId, await blobs.getJSON<ShareInfo>(path(sceneId)));
  }
  return cache.get(sceneId) ?? null;
};

/** `quiet`: the live session updating its own notes, no need to reconnect */
export const saveShare = async (
  sceneId: string,
  info: ShareInfo | null,
  opts: { quiet?: boolean } = {},
) => {
  cache.set(sceneId, info);
  if (info) {
    await blobs.putJSON(path(sceneId), info);
  } else {
    await blobs.delete(path(sceneId)).catch(() => {});
  }
  if (!opts.quiet) {
    listeners.forEach((fn) => fn(sceneId));
  }
};

export const linkURL = (
  info: Pick<ShareInfo, "roomId" | "key">,
  token: string,
) => `${RELAY}/s/${info.roomId}#k=${info.key}&t=${token}`;

/** reads a share link; null if it isn't one */
export const parseLink = (text: string) => {
  try {
    const url = new URL(text.trim());
    const room = url.pathname.match(/^\/s\/([A-Za-z0-9_-]{16,40})\/?$/)?.[1];
    const hash = new URLSearchParams(url.hash.slice(1));
    const key = hash.get("k");
    const token = hash.get("t");
    if (!room || !key || !token) {
      return null;
    }
    return { roomId: room, key, token };
  } catch {
    return null;
  }
};

const relay = async (
  method: string,
  path: string,
  secret?: string,
  body?: unknown,
) => {
  const res = await fetch(`${RELAY}/relay${path}`, {
    method,
    headers: {
      ...(secret ? { authorization: `Bearer ${secret}` } : {}),
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    throw new Error(
      res.status === 404
        ? "This shared scene doesn't exist anymore."
        : `The sharing server said ${res.status}.`,
    );
  }
  return res.json();
};

/** owner: turns sharing on for a scene; the first link can edit */
export const startSharing = async (sceneId: string) => {
  const { roomId, ownerSecret } = await relay("POST", "/rooms");
  const info: ShareInfo = {
    roomId,
    ownerSecret,
    key: await generateEncryptionKey(),
    role: "owner",
    links: [],
  };
  await saveShare(sceneId, info);
  return info;
};

export const createLink = async (
  sceneId: string,
  mode: "view" | "edit",
  label?: string,
) => {
  const info = await loadShare(sceneId);
  if (!info?.ownerSecret) {
    throw new Error("Only the scene's owner can make links.");
  }
  const made = await relay(
    "POST",
    `/rooms/${info.roomId}/links`,
    info.ownerSecret,
    {
      mode,
      label,
    },
  );
  const link: ShareLink = {
    id: made.id,
    token: made.token,
    mode: made.mode,
    label,
    created: Date.now(),
  };
  await saveShare(sceneId, { ...info, links: [...(info.links ?? []), link] });
  return link;
};

/** owner: the links with who's on them right now */
export const listLinks = async (sceneId: string) => {
  const info = await loadShare(sceneId);
  if (!info?.ownerSecret) {
    return [];
  }
  const { links } = (await relay(
    "GET",
    `/rooms/${info.roomId}/links`,
    info.ownerSecret,
  )) as {
    links: { id: string; revoked: boolean; online: number }[];
  };
  const live = new Map(links.map((l) => [l.id, l]));
  return (info.links ?? [])
    .filter((l) => live.has(l.id) && !live.get(l.id)!.revoked)
    .map((l) => ({
      ...l,
      url: linkURL(info, l.token),
      online: live.get(l.id)!.online,
    }));
};

export const revokeLink = async (sceneId: string, linkId: string) => {
  const info = await loadShare(sceneId);
  if (!info?.ownerSecret) {
    return;
  }
  await relay(
    "DELETE",
    `/rooms/${info.roomId}/links/${linkId}`,
    info.ownerSecret,
  );
  await saveShare(sceneId, {
    ...info,
    links: (info.links ?? []).filter((l) => l.id !== linkId),
  });
};

/** owner: deletes the shared copy and every link; the scene stays here */
export const stopSharing = async (sceneId: string) => {
  const info = await loadShare(sceneId);
  if (info?.ownerSecret) {
    await relay("DELETE", `/rooms/${info.roomId}`, info.ownerSecret).catch(
      () => {},
    );
  }
  await saveShare(sceneId, null);
};
