// The web editor's Share button and dialog: the browser counterpart of the
// Mac app's Share popover.

import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { LiveCollaborationTrigger } from "@excalidraw/excalidraw";

import { getSession } from "../editor/session";
import {
  createLink,
  listLinks,
  loadShare,
  revokeLink,
  saveShare,
  startSharing,
  stopSharing,
} from "../collab/shares";

import { NAME_KEY, savedName } from "./Join";

import type { CollabStatus } from "../collab/Collab";
import type { ShareInfo } from "../collab/shares";

type Link = Awaited<ReturnType<typeof listLinks>>[number];

const statusText = (status: CollabStatus | null) => {
  if (!status) {
    return null;
  }
  switch (status.state) {
    case "live":
      return status.peers
        ? `Live · ${status.peers} other${status.peers === 1 ? "" : "s"} here`
        : "Live · Only you here";
    case "offline":
      return "Offline · Changes sync when you're back";
    case "ended":
      return null;
    default:
      return "Connecting…";
  }
};

export const WebShare = ({
  sceneId,
  status,
}: {
  sceneId: string;
  status: CollabStatus | null;
}) => {
  const [open, setOpen] = useState(false);
  return (
    <>
      <LiveCollaborationTrigger
        isCollaborating={!!status && status.state !== "ended"}
        onSelect={() => setOpen(true)}
      />
      {/* above the editor's own layers, which would clip it */}
      {open &&
        createPortal(
          <ShareDialog
            sceneId={sceneId}
            status={status}
            onClose={() => setOpen(false)}
          />,
          document.body,
        )}
    </>
  );
};

const ShareDialog = ({
  sceneId,
  status,
  onClose,
}: {
  sceneId: string;
  status: CollabStatus | null;
  onClose: () => void;
}) => {
  const [info, setInfo] = useState<ShareInfo | null | undefined>(undefined);
  const [links, setLinks] = useState<Link[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [name, setName] = useState(savedName);

  const refresh = useCallback(async () => {
    const next = await loadShare(sceneId);
    setInfo(next);
    setLinks(next?.role === "owner" ? await listLinks(sceneId) : []);
  }, [sceneId]);

  useEffect(() => {
    refresh().catch((e) => setError(String(e?.message ?? e)));
  }, [refresh, status?.state, status?.peers]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const act = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      await refresh();
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setBusy(false);
    }
  };

  const copy = async (link: Link) => {
    await navigator.clipboard.writeText(link.url);
    setCopied(link.id);
    setTimeout(() => setCopied((c) => (c === link.id ? null : c)), 1600);
  };

  const start = () =>
    act(async () => {
      try {
        localStorage.setItem(NAME_KEY, name.trim());
      } catch {}
      await getSession()?.flush();
      await startSharing(sceneId);
      await createLink(sceneId, "edit");
    });

  const line = statusText(status);

  return (
    <div className="web-modal" onMouseDown={onClose}>
      <div
        className="web-dialog web-dialog--share"
        onMouseDown={(e) => e.stopPropagation()}
        role="dialog"
        aria-label="Share"
      >
        <button className="web-close" onClick={onClose} aria-label="Close">
          ×
        </button>

        {info === undefined ? (
          <p className="web-small">Loading…</p>
        ) : !info ? (
          <>
            <h2>Share this scene</h2>
            <p>
              People with the link see changes live and can keep the scene open
              even when this browser is closed.
            </p>
            <label className="web-field">
              <span>Your name, shown on your cursor</span>
              <input
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Name"
                maxLength={40}
              />
            </label>
            <p className="web-small">
              🔒 Encrypted in this browser. The sharing server can't read it.
            </p>
            <button
              className="web-button web-button--primary web-button--wide"
              disabled={busy || !name.trim()}
              onClick={start}
            >
              {busy ? "Starting…" : "Start sharing"}
            </button>
          </>
        ) : info.role === "owner" ? (
          <>
            <h2>Shared</h2>
            {line && (
              <p className="web-status">
                <i className={`web-dot web-dot--${status?.state}`} />
                {line}
              </p>
            )}
            <div className="web-links">
              {links.length === 0 && (
                <p className="web-small">
                  No links. Anyone you shared with before can't get in.
                </p>
              )}
              {links.map((link) => (
                <div key={link.id} className="web-linkrow">
                  <span className="web-linkrow__text">
                    <b>{link.mode === "edit" ? "Can edit" : "View only"}</b>
                    <small className={link.online ? "is-online" : ""}>
                      {link.online
                        ? `${link.online} here now`
                        : "Copy and send it to share"}
                    </small>
                  </span>
                  <button className="web-button" onClick={() => copy(link)}>
                    {copied === link.id ? "Copied" : "Copy"}
                  </button>
                  <button
                    className="web-icon"
                    title="Turn off this link"
                    aria-label="Turn off this link"
                    onClick={() => act(() => revokeLink(sceneId, link.id))}
                  >
                    ×
                  </button>
                </div>
              ))}
            </div>
            <div className="web-row">
              <span className="web-small">New link</span>
              <button
                className="web-button"
                disabled={busy}
                onClick={() => act(() => createLink(sceneId, "edit"))}
              >
                Can edit
              </button>
              <button
                className="web-button"
                disabled={busy}
                onClick={() => act(() => createLink(sceneId, "view"))}
              >
                View only
              </button>
            </div>
            <hr />
            <div className="web-row">
              <span className="web-small">
                Stopping deletes the shared copy and every link. The scene stays
                in this browser.
              </span>
              <button
                className="web-button web-button--danger"
                disabled={busy}
                onClick={() =>
                  confirm(
                    "Stop sharing? Everyone loses access and the shared copy is deleted.",
                  ) && act(() => stopSharing(sceneId))
                }
              >
                Stop sharing
              </button>
            </div>
          </>
        ) : (
          <>
            <h2>
              {info.ended
                ? info.ended === "revoked"
                  ? "Link turned off"
                  : "Sharing stopped"
                : info.role === "edit"
                ? "Shared with you · Can edit"
                : "Shared with you · View only"}
            </h2>
            <p>
              {info.ended
                ? "The owner ended your access. Your copy stays in this browser."
                : "Changes sync with everyone on this scene."}
            </p>
            {line && (
              <p className="web-status">
                <i className={`web-dot web-dot--${status?.state}`} />
                {line}
              </p>
            )}
            <button
              className="web-button web-button--wide"
              disabled={busy}
              onClick={() => act(() => saveShare(sceneId, null))}
            >
              {info.ended ? "Remove link" : "Leave, keep my copy"}
            </button>
          </>
        )}
        {error && <p className="web-error">{error}</p>}
      </div>
    </div>
  );
};
