// Opening a share link: an existing copy of that scene, or a new local scene
// that fills in from the relay.

import { createScene, getIndex } from "../data/store";

import { loadShare, parseLink, saveShare } from "./shares";

export const joinSharedLink = async (url: string) => {
  const link = parseLink(url);
  if (!link) {
    throw new Error("That doesn't look like a Canvas share link.");
  }
  for (const scene of getIndex().scenes) {
    const info = await loadShare(scene.id);
    if (info?.roomId === link.roomId) {
      if (info.role !== "owner") {
        await saveShare(scene.id, {
          ...info,
          key: link.key,
          token: link.token,
          ended: undefined,
        });
      }
      return scene.id;
    }
  }
  const meta = await createScene({ name: "Shared scene" });
  await saveShare(meta.id, {
    roomId: link.roomId,
    key: link.key,
    token: link.token,
    role: "view",
  });
  return meta.id;
};
