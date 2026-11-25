import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { sceneCoordsToViewportCoords } from "@excalidraw/excalidraw";

import { setWindowFullscreen } from "../data/native";

import { getSlides, slideName } from "./slides";

import type { ExcalidrawFrameLikeElement } from "./slides";
import type {
  AppState,
  ExcalidrawImperativeAPI,
} from "@excalidraw/excalidraw/types";

type Rect = { left: number; top: number; width: number; height: number };

/**
 * Presentation mode: frames are slides. Full screen, editor UI hidden, the
 * viewport locked to the current frame with everything outside it masked,
 * and the laser pointer active.
 */
export const Presenter = ({
  api,
  slideOrder,
  startAt,
  onExit,
}: {
  api: ExcalidrawImperativeAPI;
  slideOrder: string[] | undefined;
  startAt: number;
  onExit: () => void;
}) => {
  const [slides] = useState(() => getSlides(api, slideOrder));
  const [index, setIndex] = useState(() =>
    Math.min(Math.max(startAt, 0), Math.max(slides.length - 1, 0)),
  );
  const [rect, setRect] = useState<Rect | null>(null);
  const [hudVisible, setHudVisible] = useState(true);
  const hudTimer = useRef<number | undefined>(undefined);
  const prevState = useRef<Partial<AppState> | null>(null);

  const frame: ExcalidrawFrameLikeElement | undefined = slides[index];

  const measure = useCallback(() => {
    if (!frame) {
      return;
    }
    const appState = api.getAppState();
    const live =
      api.getSceneElements().find((el) => el.id === frame.id) ?? frame;
    const topLeft = sceneCoordsToViewportCoords(
      { sceneX: live.x, sceneY: live.y },
      appState,
    );
    setRect({
      left: topLeft.x,
      top: topLeft.y,
      width: live.width * appState.zoom.value,
      height: live.height * appState.zoom.value,
    });
  }, [api, frame]);

  const show = useCallback(
    (target: ExcalidrawFrameLikeElement, animate: boolean) => {
      api.setViewport({
        target,
        fit: "contain",
        animation: animate,
        lock: { scroll: true, zoom: true, overscroll: false },
        offsets: { top: 0, right: 0, bottom: 0, left: 0 },
      });
    },
    [api],
  );

  // enter / leave
  useLayoutEffect(() => {
    if (!slides.length) {
      api.setToast({
        message: "No slides yet. Add frames (F) to present them.",
        duration: 3000,
      });
      onExit();
      return;
    }
    const s = api.getAppState();
    prevState.current = {
      viewModeEnabled: s.viewModeEnabled,
      zenModeEnabled: s.zenModeEnabled,
      frameRendering: s.frameRendering,
      scrollX: s.scrollX,
      scrollY: s.scrollY,
      zoom: s.zoom,
    };
    document.body.classList.add("canvas-presenting");
    setWindowFullscreen(true);
    api.updateScene({
      appState: {
        viewModeEnabled: true,
        zenModeEnabled: true,
        openSidebar: null,
        openDialog: null,
        frameRendering: { enabled: true, clip: true, name: false, outline: false },
      },
    });
    api.setActiveTool({ type: "laser" });

    return () => {
      document.body.classList.remove("canvas-presenting");
      setWindowFullscreen(false);
      api.setViewport(null);
      if (prevState.current) {
        api.updateScene({ appState: prevState.current as AppState });
      }
      api.setActiveTool({ type: "selection" });
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (frame) {
      show(frame, true);
    }
  }, [frame, show]);

  // keep the mask on the frame while the viewport animates or the window resizes
  useEffect(() => {
    measure();
    const offScroll = api.onScrollChange(() => measure());
    let resizeTimer: number | undefined;
    const onResize = () => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        if (frame) {
          show(frame, false);
        }
        measure();
      }, 120);
    };
    window.addEventListener("resize", onResize);
    return () => {
      offScroll();
      window.removeEventListener("resize", onResize);
      window.clearTimeout(resizeTimer);
    };
  }, [api, frame, measure, show]);

  const go = useCallback(
    (delta: number) =>
      setIndex((i) => Math.min(Math.max(i + delta, 0), slides.length - 1)),
    [slides.length],
  );

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      let handled = true;
      switch (e.key) {
        case "ArrowRight":
        case "ArrowDown":
        case "PageDown":
        case " ":
        case "Enter":
          go(1);
          break;
        case "ArrowLeft":
        case "ArrowUp":
        case "PageUp":
        case "Backspace":
          go(-1);
          break;
        case "Home":
          setIndex(0);
          break;
        case "End":
          setIndex(slides.length - 1);
          break;
        case "Escape":
          onExit();
          break;
        default:
          handled = false;
      }
      if (handled) {
        e.preventDefault();
        e.stopPropagation();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [go, onExit, slides.length]);

  useEffect(() => {
    const onMove = () => {
      setHudVisible(true);
      window.clearTimeout(hudTimer.current);
      hudTimer.current = window.setTimeout(() => setHudVisible(false), 2200);
    };
    onMove();
    window.addEventListener("pointermove", onMove);
    return () => {
      window.removeEventListener("pointermove", onMove);
      window.clearTimeout(hudTimer.current);
    };
  }, []);

  if (!frame) {
    return null;
  }

  return (
    <>
      {rect && (
        <div
          className="canvas-presenter__mask"
          style={{
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
          }}
        />
      )}
      <div className={`canvas-presenter__hud${hudVisible ? "" : " is-hidden"}`}>
        <button onClick={() => go(-1)} disabled={index === 0} title="Previous">
          ‹
        </button>
        <span title={slideName(frame, index)}>
          {index + 1} / {slides.length}
        </span>
        <button
          onClick={() => go(1)}
          disabled={index === slides.length - 1}
          title="Next"
        >
          ›
        </button>
        <span className="canvas-presenter__sep" />
        <button onClick={onExit} title="Exit (Esc)">
          ✕
        </button>
      </div>
    </>
  );
};
