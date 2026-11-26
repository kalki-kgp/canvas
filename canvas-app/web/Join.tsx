// /s/<room>#k=…&t=… in a browser: ask for a name for the cursor, then open
// the scene (an existing copy in this browser, or a new one that fills in).

import { useState } from "react";

import { navigate } from "../App";
import { joinSharedLink } from "../collab/join";
import { parseLink } from "../collab/shares";

export const NAME_KEY = "canvas-name";

export const savedName = () => {
  try {
    return localStorage.getItem(NAME_KEY) ?? "";
  } catch {
    return "";
  }
};

export const WebJoin = () => {
  const [name, setName] = useState(savedName);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(
    parseLink(location.href)
      ? null
      : "This link is incomplete. Ask for the whole link, including the part after #.",
  );

  const join = async () => {
    const trimmed = name.trim();
    if (!trimmed) {
      return;
    }
    setBusy(true);
    try {
      localStorage.setItem(NAME_KEY, trimmed);
    } catch {}
    try {
      const id = await joinSharedLink(location.href);
      // the key stays out of the address bar and history from here on
      history.replaceState(null, "", "/");
      navigate({ view: "scene", id });
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setBusy(false);
    }
  };

  return (
    <div className="web-page web-page--center">
      <form
        className="web-dialog"
        onSubmit={(e) => {
          e.preventDefault();
          join();
        }}
      >
        <img src="/icon.png" alt="" width={44} height={44} />
        <h1>You're invited to a scene</h1>
        <p>
          It opens here and stays in sync with everyone on it. Scenes are
          encrypted, so the server in between can't read them.
        </p>
        <label className="web-field">
          <span>Your name, shown on your cursor</span>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Name"
            autoFocus
            maxLength={40}
          />
        </label>
        {error && <p className="web-error">{error}</p>}
        <button
          className="web-button web-button--primary web-button--wide"
          disabled={!name.trim() || busy || !parseLink(location.href)}
        >
          {busy ? "Opening…" : "Open scene"}
        </button>
        <p className="web-small">
          Have Canvas for Mac? Use File → Open Shared Link… there instead.
        </p>
      </form>
    </div>
  );
};
