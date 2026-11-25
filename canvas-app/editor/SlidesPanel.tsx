import { useEffect, useState } from "react";
import { Sidebar, hashElementsVersion } from "@excalidraw/excalidraw";
import {
  ExportIcon,
  frameToolIcon,
  playerPlayIcon,
} from "@excalidraw/excalidraw/components/icons";

import { savePDF } from "../data/native";

import { getSlides, renderSlide, renderSlideDataURL, slideName } from "./slides";

import type { CanvasSceneExtras } from "../data/store";
import type { ExcalidrawFrameLikeElement } from "./slides";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";

export const SlidesPanel = ({
  api,
  getExtras,
  setSlides,
  sceneName,
  onPresent,
}: {
  api: ExcalidrawImperativeAPI;
  getExtras: () => CanvasSceneExtras;
  setSlides: (ids: string[]) => void;
  sceneName: string;
  onPresent: (from: number) => void;
}) => {
  const [slides, setSlideList] = useState<ExcalidrawFrameLikeElement[]>(() =>
    getSlides(api, getExtras().slides),
  );
  const [thumbs, setThumbs] = useState<Record<string, string>>({});
  const [exporting, setExporting] = useState<string | null>(null);
  const [dragId, setDragId] = useState<string | null>(null);

  // follow scene changes (frames added, renamed, edited)
  useEffect(() => {
    let lastHash = -1;
    let timer: number | undefined;
    const refresh = () => {
      const next = getSlides(api, getExtras().slides);
      setSlideList(next);
      window.clearTimeout(timer);
      timer = window.setTimeout(async () => {
        const entries = await Promise.all(
          next.map(async (frame) => {
            const blob = await renderSlide(api, frame, {
              maxWidthOrHeight: 320,
            });
            return [frame.id, URL.createObjectURL(blob)] as const;
          }),
        );
        setThumbs((prev) => {
          Object.values(prev).forEach((url) => URL.revokeObjectURL(url));
          return Object.fromEntries(entries);
        });
      }, 300);
    };
    refresh();
    const off = api.onChange((elements) => {
      const hash = hashElementsVersion(elements);
      if (hash !== lastHash) {
        lastHash = hash;
        refresh();
      }
    });
    return () => {
      off();
      window.clearTimeout(timer);
    };
  }, [api, getExtras]);

  const reorder = (fromId: string, toIndex: number) => {
    const ids = slides.map((s) => s.id).filter((id) => id !== fromId);
    ids.splice(toIndex, 0, fromId);
    setSlides(ids);
    setSlideList(getSlides(api, ids));
  };

  const exportPDF = async () => {
    if (!slides.length) {
      return;
    }
    try {
      const pages: string[] = [];
      for (let i = 0; i < slides.length; i++) {
        setExporting(`Rendering ${i + 1}/${slides.length}…`);
        pages.push(await renderSlideDataURL(api, slides[i], { scale: 2 }));
      }
      setExporting("Saving…");
      await savePDF(sceneName, pages);
    } catch (error: any) {
      api.setToast({ message: `PDF export failed: ${error.message}` });
    } finally {
      setExporting(null);
    }
  };

  return (
    <div className="canvas-panel">
      <Sidebar.Header>
        <div className="canvas-panel__title">Slides</div>
      </Sidebar.Header>
      {!slides.length ? (
        <div className="canvas-panel__empty">
          <div className="canvas-panel__empty-icon">{frameToolIcon}</div>
          <p>No frames yet. Each frame is a slide.</p>
          <button
            className="canvas-btn"
            onClick={() => api.setActiveTool({ type: "frame" })}
          >
            Add a frame
          </button>
        </div>
      ) : (
        <>
          <div className="canvas-panel__actions">
            <button
              className="canvas-btn canvas-btn--primary"
              onClick={() => onPresent(0)}
            >
              {playerPlayIcon} Present
            </button>
            <button
              className="canvas-btn"
              onClick={exportPDF}
              disabled={!!exporting}
            >
              {ExportIcon} {exporting ?? "PDF"}
            </button>
          </div>
          <ol className="canvas-slides">
            {slides.map((frame, index) => (
              <li
                key={frame.id}
                className={`canvas-slide${dragId === frame.id ? " is-dragging" : ""}`}
                draggable
                onDragStart={(e) => {
                  setDragId(frame.id);
                  e.dataTransfer.effectAllowed = "move";
                }}
                onDragEnd={() => setDragId(null)}
                onDragOver={(e) => e.preventDefault()}
                onDrop={(e) => {
                  e.preventDefault();
                  if (dragId && dragId !== frame.id) {
                    reorder(dragId, index);
                  }
                  setDragId(null);
                }}
              >
                <span className="canvas-slide__num">{index + 1}</span>
                <button
                  className="canvas-slide__thumb"
                  title="Go to slide"
                  onClick={() =>
                    api.setViewport({
                      target: frame,
                      fit: "contain",
                      animation: true,
                    })
                  }
                  onDoubleClick={() => onPresent(index)}
                >
                  {thumbs[frame.id] ? (
                    <img src={thumbs[frame.id]} alt="" draggable={false} />
                  ) : null}
                </button>
                <div className="canvas-slide__meta">
                  <span className="canvas-slide__name">
                    {slideName(frame, index)}
                  </span>
                  <span className="canvas-slide__moves">
                    <button
                      title="Move up"
                      disabled={index === 0}
                      onClick={() => reorder(frame.id, index - 1)}
                    >
                      ↑
                    </button>
                    <button
                      title="Move down"
                      disabled={index === slides.length - 1}
                      onClick={() => reorder(frame.id, index + 1)}
                    >
                      ↓
                    </button>
                    <button title="Present from here" onClick={() => onPresent(index)}>
                      {playerPlayIcon}
                    </button>
                  </span>
                </div>
              </li>
            ))}
          </ol>
        </>
      )}
    </div>
  );
};
