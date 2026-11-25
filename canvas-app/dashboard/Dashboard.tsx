import { useEffect, useMemo, useRef, useState } from "react";
import {
  DotsIcon,
  LoadIcon,
  MoonIcon,
  PlusIcon,
  SunIcon,
  searchIcon,
} from "@excalidraw/excalidraw/components/icons";

import { navigate } from "../App";
import { exportSceneFile, importSceneFile } from "../data/importExport";
import { blobURL } from "../data/native";
import {
  createCollection,
  createScene,
  deleteCollection,
  deleteScene,
  duplicateScene,
  moveScene,
  renameCollection,
  renameScene,
  toggleStar,
  useIndex,
} from "../data/store";

import type { AppSettings } from "../App";
import type { Collection, SceneMeta } from "../data/store";

type Filter = { kind: "all" } | { kind: "starred" } | { kind: "collection"; id: string };
type Sort = "updated" | "name" | "created";

const relativeTime = (ts: number) => {
  const diff = Date.now() - ts;
  const min = Math.round(diff / 60_000);
  if (min < 1) {
    return "just now";
  }
  if (min < 60) {
    return `${min} min ago`;
  }
  const hours = Math.round(min / 60);
  if (hours < 24) {
    return `${hours} h ago`;
  }
  const days = Math.round(hours / 24);
  if (days < 7) {
    return `${days} d ago`;
  }
  return new Date(ts).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: days > 300 ? "numeric" : undefined,
  });
};

const InlineInput = ({
  initial,
  onDone,
}: {
  initial: string;
  onDone: (value: string | null) => void;
}) => {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    ref.current?.focus();
    ref.current?.select();
  }, []);
  return (
    <input
      ref={ref}
      className="canvas-input canvas-inline-input"
      defaultValue={initial}
      onClick={(e) => e.stopPropagation()}
      onBlur={(e) => onDone(e.target.value)}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          onDone((e.target as HTMLInputElement).value);
        } else if (e.key === "Escape") {
          onDone(null);
        }
      }}
    />
  );
};

type MenuItem = { label: string; onSelect: () => void; danger?: boolean } | "sep";

const Menu = ({
  items,
  anchor,
  onClose,
}: {
  items: MenuItem[];
  anchor: { x: number; y: number };
  onClose: () => void;
}) => {
  useEffect(() => {
    const close = () => onClose();
    window.addEventListener("pointerdown", close);
    window.addEventListener("blur", close);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("blur", close);
    };
  }, [onClose]);
  const left = Math.min(anchor.x, window.innerWidth - 220);
  const top = Math.min(anchor.y, window.innerHeight - items.length * 34 - 16);
  return (
    <div
      className="canvas-menu"
      style={{ left, top }}
      onPointerDown={(e) => e.stopPropagation()}
    >
      {items.map((item, i) =>
        item === "sep" ? (
          <div key={i} className="canvas-menu__sep" />
        ) : (
          <button
            key={i}
            className={`canvas-menu__item${item.danger ? " is-danger" : ""}`}
            onClick={() => {
              onClose();
              item.onSelect();
            }}
          >
            {item.label}
          </button>
        ),
      )}
    </div>
  );
};

const SceneCard = ({
  scene,
  collections,
  renaming,
  setRenaming,
  openMenu,
}: {
  scene: SceneMeta;
  collections: Collection[];
  renaming: boolean;
  setRenaming: (id: string | null) => void;
  openMenu: (scene: SceneMeta, anchor: { x: number; y: number }) => void;
}) => {
  const collection = collections.find((c) => c.id === scene.collectionId);
  return (
    <div
      className="canvas-card"
      draggable={!renaming}
      onDragStart={(e) => {
        e.dataTransfer.setData("text/x-canvas-scene", scene.id);
        e.dataTransfer.effectAllowed = "move";
      }}
      onClick={() => navigate({ view: "scene", id: scene.id })}
      onContextMenu={(e) => {
        e.preventDefault();
        openMenu(scene, { x: e.clientX, y: e.clientY });
      }}
    >
      <div className="canvas-card__thumb">
        {scene.thumbAt ? (
          <img
            src={blobURL(`thumbs/${scene.id}.png`, scene.thumbAt)}
            alt=""
            draggable={false}
            loading="lazy"
          />
        ) : (
          <span className="canvas-card__blank">Empty</span>
        )}
        {scene.starred && <span className="canvas-card__star">★</span>}
      </div>
      <div className="canvas-card__meta">
        <div className="canvas-card__text">
          {renaming ? (
            <InlineInput
              initial={scene.name}
              onDone={(value) => {
                if (value !== null) {
                  renameScene(scene.id, value);
                }
                setRenaming(null);
              }}
            />
          ) : (
            <div className="canvas-card__name" title={scene.name}>
              {scene.name}
            </div>
          )}
          <div className="canvas-card__sub">
            {relativeTime(scene.updatedAt)}
            {collection ? ` · ${collection.name}` : ""}
          </div>
        </div>
        <button
          className="canvas-icon-btn"
          title="More"
          onClick={(e) => {
            e.stopPropagation();
            const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
            openMenu(scene, { x: r.left, y: r.bottom + 4 });
          }}
        >
          {DotsIcon}
        </button>
      </div>
    </div>
  );
};

export const Dashboard = ({ settings }: { settings: AppSettings }) => {
  const { scenes, collections } = useIndex();
  const [filter, setFilter] = useState<Filter>(() => {
    try {
      return JSON.parse(localStorage.getItem("canvas-filter") || "") as Filter;
    } catch {
      return { kind: "all" };
    }
  });
  const [sort, setSort] = useState<Sort>("updated");
  const [query, setQuery] = useState("");
  const [renamingScene, setRenamingScene] = useState<string | null>(null);
  const [renamingCollection, setRenamingCollection] = useState<string | null>(null);
  const [addingCollection, setAddingCollection] = useState(false);
  const [dropTarget, setDropTarget] = useState<string | null>(null);
  const [menu, setMenu] = useState<{
    items: MenuItem[];
    anchor: { x: number; y: number };
  } | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    document.title = "Canvas";
  }, []);

  useEffect(() => {
    try {
      localStorage.setItem("canvas-filter", JSON.stringify(filter));
    } catch {}
  }, [filter]);

  // a deleted collection can't stay selected
  const activeFilter: Filter =
    filter.kind === "collection" && !collections.some((c) => c.id === filter.id)
      ? { kind: "all" }
      : filter;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "f") {
        e.preventDefault();
        searchRef.current?.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return scenes
      .filter((s) =>
        activeFilter.kind === "starred"
          ? s.starred
          : activeFilter.kind === "collection"
          ? s.collectionId === activeFilter.id
          : true,
      )
      .filter((s) => !q || s.name.toLowerCase().includes(q))
      .sort((a, b) =>
        sort === "name"
          ? a.name.localeCompare(b.name, undefined, { numeric: true })
          : sort === "created"
          ? b.createdAt - a.createdAt
          : b.updatedAt - a.updatedAt,
      );
  }, [scenes, activeFilter, query, sort]);

  const newScene = async () => {
    const meta = await createScene({
      collectionId: activeFilter.kind === "collection" ? activeFilter.id : null,
    });
    navigate({ view: "scene", id: meta.id });
  };

  const sceneMenu = (scene: SceneMeta, anchor: { x: number; y: number }) =>
    setMenu({
      anchor,
      items: [
        { label: "Open", onSelect: () => navigate({ view: "scene", id: scene.id }) },
        { label: "Rename", onSelect: () => setRenamingScene(scene.id) },
        { label: "Duplicate", onSelect: () => duplicateScene(scene.id) },
        {
          label: scene.starred ? "Unstar" : "Star",
          onSelect: () => toggleStar(scene.id),
        },
        "sep",
        ...collections
          .filter((c) => c.id !== scene.collectionId)
          .map((c) => ({
            label: `Move to ${c.name}`,
            onSelect: () => moveScene(scene.id, c.id),
          })),
        ...(scene.collectionId
          ? [
              {
                label: "Remove from collection",
                onSelect: () => moveScene(scene.id, null),
              },
            ]
          : []),
        ...(collections.length || scene.collectionId ? (["sep"] as const) : []),
        {
          label: "Export .excalidraw…",
          onSelect: () => exportSceneFile(scene.id),
        },
        {
          label: "Delete",
          danger: true,
          onSelect: () => {
            if (confirm(`Delete “${scene.name}”? Its version history goes too.`)) {
              deleteScene(scene.id);
            }
          },
        },
      ],
    });

  const collectionMenu = (c: Collection, anchor: { x: number; y: number }) =>
    setMenu({
      anchor,
      items: [
        { label: "Rename", onSelect: () => setRenamingCollection(c.id) },
        {
          label: "Delete collection",
          danger: true,
          onSelect: () => {
            if (
              confirm(
                `Delete the collection “${c.name}”? Its scenes stay in All scenes.`,
              )
            ) {
              deleteCollection(c.id);
            }
          },
        },
      ],
    });

  const dropProps = (collectionId: string | null, key: string) => ({
    onDragOver: (e: React.DragEvent) => {
      if (e.dataTransfer.types.includes("text/x-canvas-scene")) {
        e.preventDefault();
        setDropTarget(key);
      }
    },
    onDragLeave: () => setDropTarget((t) => (t === key ? null : t)),
    onDrop: (e: React.DragEvent) => {
      const id = e.dataTransfer.getData("text/x-canvas-scene");
      setDropTarget(null);
      if (id) {
        e.preventDefault();
        moveScene(id, collectionId);
      }
    },
  });

  const title =
    activeFilter.kind === "starred"
      ? "Starred"
      : activeFilter.kind === "collection"
      ? collections.find((c) => c.id === activeFilter.id)?.name ?? "Collection"
      : "All scenes";

  const isActive = (f: Filter) =>
    f.kind === activeFilter.kind &&
    (f.kind !== "collection" ||
      (activeFilter.kind === "collection" && f.id === activeFilter.id));

  return (
    <div
      className={`excalidraw canvas-dashboard${
        settings.editorTheme === "dark" ? " theme--dark" : ""
      }`}
    >
      <aside className="canvas-dashboard__side">
        <div className="canvas-dashboard__brand">Canvas</div>
        <button className="canvas-btn canvas-btn--primary canvas-btn--wide" onClick={newScene}>
          {PlusIcon} New scene
        </button>

        <nav className="canvas-nav">
          <button
            className={`canvas-nav__item${isActive({ kind: "all" }) ? " is-active" : ""}${
              dropTarget === "all" ? " is-drop" : ""
            }`}
            onClick={() => setFilter({ kind: "all" })}
            {...dropProps(null, "all")}
          >
            <span>All scenes</span>
            <span className="canvas-nav__count">{scenes.length}</span>
          </button>
          <button
            className={`canvas-nav__item${isActive({ kind: "starred" }) ? " is-active" : ""}`}
            onClick={() => setFilter({ kind: "starred" })}
          >
            <span>Starred</span>
            <span className="canvas-nav__count">
              {scenes.filter((s) => s.starred).length || ""}
            </span>
          </button>
        </nav>

        <div className="canvas-nav__heading">
          <span>Collections</span>
          <button
            className="canvas-icon-btn"
            title="New collection"
            onClick={() => setAddingCollection(true)}
          >
            {PlusIcon}
          </button>
        </div>
        <nav className="canvas-nav canvas-nav--scroll">
          {collections.map((c) => {
            const f: Filter = { kind: "collection", id: c.id };
            return renamingCollection === c.id ? (
              <InlineInput
                key={c.id}
                initial={c.name}
                onDone={(value) => {
                  if (value !== null) {
                    renameCollection(c.id, value);
                  }
                  setRenamingCollection(null);
                }}
              />
            ) : (
              <button
                key={c.id}
                className={`canvas-nav__item${isActive(f) ? " is-active" : ""}${
                  dropTarget === c.id ? " is-drop" : ""
                }`}
                onClick={() => setFilter(f)}
                onDoubleClick={() => setRenamingCollection(c.id)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  collectionMenu(c, { x: e.clientX, y: e.clientY });
                }}
                {...dropProps(c.id, c.id)}
              >
                <span>{c.name}</span>
                <span className="canvas-nav__count">
                  {scenes.filter((s) => s.collectionId === c.id).length}
                </span>
              </button>
            );
          })}
          {addingCollection && (
            <InlineInput
              initial=""
              onDone={async (value) => {
                setAddingCollection(false);
                if (value?.trim()) {
                  const c = await createCollection(value);
                  setFilter({ kind: "collection", id: c.id });
                }
              }}
            />
          )}
        </nav>

        <div className="canvas-dashboard__foot">
          <button
            className="canvas-icon-btn"
            title="Toggle theme"
            onClick={() =>
              settings.setAppTheme(settings.editorTheme === "dark" ? "light" : "dark")
            }
          >
            {settings.editorTheme === "dark" ? SunIcon : MoonIcon}
          </button>
        </div>
      </aside>

      <main className="canvas-dashboard__main">
        <header className="canvas-dashboard__top">
          <h1>{title}</h1>
          <div className="canvas-search">
            {searchIcon}
            <input
              ref={searchRef}
              placeholder="Search scenes"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Escape") {
                  setQuery("");
                  (e.target as HTMLInputElement).blur();
                }
              }}
            />
          </div>
          <select
            className="canvas-select"
            value={sort}
            onChange={(e) => setSort(e.target.value as Sort)}
            aria-label="Sort"
          >
            <option value="updated">Last edited</option>
            <option value="created">Created</option>
            <option value="name">Name</option>
          </select>
          <button className="canvas-btn" onClick={() => fileInput.current?.click()}>
            {LoadIcon} Import
          </button>
          <input
            ref={fileInput}
            type="file"
            accept=".excalidraw,.excalidrawlib,.json,application/json"
            multiple
            hidden
            onChange={async (e) => {
              const files = [...(e.target.files ?? [])];
              e.target.value = "";
              let last: SceneMeta | null = null;
              for (const file of files) {
                last = (await importSceneFile(file.name, await file.text())) ?? last;
              }
              if (last && files.length === 1) {
                navigate({ view: "scene", id: last.id });
              }
            }}
          />
        </header>

        {visible.length ? (
          <div className="canvas-grid">
            {visible.map((scene) => (
              <SceneCard
                key={scene.id}
                scene={scene}
                collections={collections}
                renaming={renamingScene === scene.id}
                setRenaming={setRenamingScene}
                openMenu={sceneMenu}
              />
            ))}
          </div>
        ) : (
          <div className="canvas-dashboard__empty">
            {query ? (
              <p>No scenes match “{query}”.</p>
            ) : (
              <>
                <p>No scenes here yet.</p>
                <button className="canvas-btn canvas-btn--primary" onClick={newScene}>
                  {PlusIcon} New scene
                </button>
              </>
            )}
          </div>
        )}
      </main>

      {menu && (
        <Menu items={menu.items} anchor={menu.anchor} onClose={() => setMenu(null)} />
      )}
    </div>
  );
};
