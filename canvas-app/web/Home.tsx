// The website's home (canvas.paperknife.app): the scenes kept in this
// browser, a new scene, and a way in from a share link. The Mac app draws
// its own library natively and never shows this.

import { useEffect, useMemo, useState } from "react";

import { navigate } from "../App";
import { loadShare, parseLink } from "../collab/shares";
import { getStoredBlob } from "../data/native";
import { createScene, deleteScene, useIndex } from "../data/store";

import type { ShareRole } from "../collab/shares";
import type { SceneMeta } from "../data/store";

const RELEASES = "https://github.com/kalki-kgp/canvas/releases/latest";

const ago = (time: number) => {
  const s = Math.round((Date.now() - time) / 1000);
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  if (s < 60) {
    return "just now";
  }
  if (s < 3600) {
    return rtf.format(-Math.round(s / 60), "minute");
  }
  if (s < 86400) {
    return rtf.format(-Math.round(s / 3600), "hour");
  }
  if (s < 86400 * 30) {
    return rtf.format(-Math.round(s / 86400), "day");
  }
  return new Date(time).toLocaleDateString();
};

const Thumb = ({ scene }: { scene: SceneMeta }) => {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let made: string | null = null;
    getStoredBlob(`thumbs/${scene.id}.png`).then((blob) => {
      if (blob) {
        made = URL.createObjectURL(blob);
        setUrl(made);
      }
    });
    return () => {
      if (made) {
        URL.revokeObjectURL(made);
      }
    };
  }, [scene.id, scene.thumbAt]);
  return (
    <div className="web-card__thumb">
      {url ? <img src={url} alt="" draggable={false} /> : <span>Empty</span>}
    </div>
  );
};

const RoleBadge = ({ role }: { role: ShareRole }) => (
  <span className={`web-badge web-badge--${role}`}>
    {role === "owner" ? "Shared" : role === "edit" ? "Can edit" : "View only"}
  </span>
);

export const WebHome = () => {
  const index = useIndex();
  const scenes = useMemo(
    () => [...index.scenes].sort((a, b) => b.updatedAt - a.updatedAt),
    [index.scenes],
  );
  const [roles, setRoles] = useState<Record<string, ShareRole>>({});
  const [link, setLink] = useState("");
  const [linkError, setLinkError] = useState<string | null>(null);

  useEffect(() => {
    document.title = "Canvas";
    Promise.all(
      scenes.map(async (s) => [s.id, (await loadShare(s.id))?.role] as const),
    ).then((pairs) =>
      setRoles(
        Object.fromEntries(pairs.filter(([, role]) => role)) as Record<
          string,
          ShareRole
        >,
      ),
    );
  }, [scenes]);

  const newScene = async () => {
    const meta = await createScene();
    navigate({ view: "scene", id: meta.id });
  };

  const openLink = () => {
    const parsed = parseLink(link);
    if (!parsed) {
      setLinkError("That doesn't look like a Canvas share link.");
      return;
    }
    // the join page asks for a name, then opens it
    location.href = link.trim();
  };

  const remove = async (scene: SceneMeta) => {
    if (
      confirm(
        `Delete “${scene.name}” from this browser? People you shared it with keep their copies.`,
      )
    ) {
      await deleteScene(scene.id);
    }
  };

  return (
    <div className="web-page">
      <header className="web-header">
        <a className="web-brand" href="/" onClick={(e) => e.preventDefault()}>
          <img src="/icon.png" alt="" width={28} height={28} />
          Canvas
        </a>
        <a className="web-link" href={RELEASES} target="_blank" rel="noopener">
          Get the Mac app
        </a>
      </header>

      <main className="web-main">
        <section className="web-hero">
          <h1>Your scenes</h1>
          <p>
            Saved in this browser. Nothing leaves it unless you share a scene,
            and shared scenes are encrypted before they do.
          </p>
          <div className="web-actions">
            <button
              className="web-button web-button--primary"
              onClick={newScene}
            >
              New scene
            </button>
            <form
              className="web-join"
              onSubmit={(e) => {
                e.preventDefault();
                openLink();
              }}
            >
              <input
                value={link}
                onChange={(e) => {
                  setLink(e.target.value);
                  setLinkError(null);
                }}
                placeholder="Paste a share link to open it"
                spellCheck={false}
                aria-label="Share link"
              />
              <button className="web-button" disabled={!link.trim()}>
                Open
              </button>
            </form>
          </div>
          {linkError && <p className="web-error">{linkError}</p>}
        </section>

        {scenes.length ? (
          <ul className="web-grid">
            {scenes.map((scene) => (
              <li key={scene.id} className="web-card">
                <button
                  className="web-card__open"
                  onClick={() => navigate({ view: "scene", id: scene.id })}
                >
                  <Thumb scene={scene} />
                  <span className="web-card__meta">
                    <span className="web-card__name">{scene.name}</span>
                    <span className="web-card__sub">
                      {ago(scene.updatedAt)}
                      {roles[scene.id] && <RoleBadge role={roles[scene.id]} />}
                    </span>
                  </span>
                </button>
                <button
                  className="web-card__delete"
                  onClick={() => remove(scene)}
                  title="Delete from this browser"
                  aria-label={`Delete ${scene.name}`}
                >
                  ×
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <div className="web-empty">
            <p>No scenes yet. Start one, or open a link someone sent you.</p>
          </div>
        )}
      </main>

      <footer className="web-footer">
        Built on{" "}
        <a
          href="https://github.com/excalidraw/excalidraw"
          target="_blank"
          rel="noopener"
        >
          Excalidraw
        </a>
        . Free and open source.
      </footer>
    </div>
  );
};
