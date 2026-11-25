import { THEME, exportScene, getNonDeletedElements } from "@excalidraw/excalidraw";
import { getDataURL } from "@excalidraw/excalidraw/data/blob";

import type {
  ExcalidrawFrameLikeElement as FrameLike,
  NonDeleted,
} from "@excalidraw/element/types";

export type ExcalidrawFrameLikeElement = NonDeleted<FrameLike>;
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";

export const isFrameLike = (el: { type: string }) =>
  el.type === "frame" || el.type === "magicframe";

/**
 * Frames in slide order: the saved order first, then frames that aren't in it
 * yet, in the order they were created.
 */
export const getSlides = (
  api: ExcalidrawImperativeAPI,
  order: readonly string[] | undefined,
): ExcalidrawFrameLikeElement[] => {
  const frames = getNonDeletedElements(api.getSceneElements()).filter(
    isFrameLike,
  ) as ExcalidrawFrameLikeElement[];
  const byId = new Map(frames.map((f) => [f.id, f]));
  const ordered: ExcalidrawFrameLikeElement[] = [];
  for (const id of order ?? []) {
    const frame = byId.get(id);
    if (frame) {
      ordered.push(frame);
      byId.delete(id);
    }
  }
  return [...ordered, ...byId.values()];
};

export const slideName = (frame: ExcalidrawFrameLikeElement, index: number) =>
  frame.name?.trim() || `Slide ${index + 1}`;

export const renderSlide = async (
  api: ExcalidrawImperativeAPI,
  frame: ExcalidrawFrameLikeElement,
  opts: { maxWidthOrHeight?: number; scale?: number; type?: "png" | "jpeg" } = {},
) => {
  const appState = api.getAppState();
  const blob = await exportScene({
    type: opts.type ?? "png",
    data: {
      elements: getNonDeletedElements(api.getSceneElements()),
      appState,
      files: api.getFiles(),
    },
    config: {
      exportingFrame: frame,
      theme: appState.theme === THEME.DARK ? THEME.DARK : THEME.LIGHT,
      ...(opts.maxWidthOrHeight
        ? { maxWidthOrHeight: opts.maxWidthOrHeight }
        : { scale: opts.scale ?? 2 }),
    },
  });
  return blob;
};

export const renderSlideDataURL = async (
  ...args: Parameters<typeof renderSlide>
) => getDataURL(await renderSlide(...args));
