import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import { THEME, defaultLang, languages } from "@excalidraw/excalidraw";

import { Dashboard } from "./dashboard/Dashboard";
import { Editor } from "./editor/Editor";
import { importSceneFile } from "./data/importExport";
import { flushPendingNativeEvents, onNativeEvent } from "./data/native";
import { createScene, loadIndex, loadPrefs, savePrefs } from "./data/store";
import { installMCP } from "./mcp/mcp";

import type { Prefs } from "./data/store";
import type { Theme } from "@excalidraw/element/types";

// ---------------------------------------------------------------------------
// routing: "/" is the dashboard, "/scene/<id>" an open scene. Paths, not
// hashes, so that excalidraw's `#addLibrary=` links keep working anywhere.
// ---------------------------------------------------------------------------

export type Route = { view: "dashboard" } | { view: "scene"; id: string };

const parseRoute = (): Route => {
  const match = location.pathname.match(/^\/scene\/([\w-]+)/);
  return match ? { view: "scene", id: match[1] } : { view: "dashboard" };
};

const routeListeners = new Set<(r: Route) => void>();

export const navigate = (route: Route) => {
  const path = route.view === "scene" ? `/scene/${route.id}` : "/";
  if (location.pathname !== path) {
    history.pushState(null, "", path + location.search);
  }
  routeListeners.forEach((fn) => fn(route));
};

const useRoute = () => {
  const [route, setRoute] = useState<Route>(parseRoute);
  useEffect(() => {
    const onPop = () => setRoute(parseRoute());
    routeListeners.add(setRoute);
    window.addEventListener("popstate", onPop);
    return () => {
      routeListeners.delete(setRoute);
      window.removeEventListener("popstate", onPop);
    };
  }, []);
  return route;
};

// ---------------------------------------------------------------------------
// theme & language
// ---------------------------------------------------------------------------

const systemDark = () =>
  window.matchMedia?.("(prefers-color-scheme: dark)").matches;

const detectLang = () => {
  const nav = navigator.language || "en";
  return (
    languages.find((l) => l.code === nav)?.code ||
    languages.find((l) => l.code.startsWith(nav.split("-")[0]))?.code ||
    defaultLang.code
  );
};

export type AppSettings = {
  appTheme: Theme | "system";
  editorTheme: Theme;
  setAppTheme: (theme: Theme | "system") => void;
  langCode: string;
  setLangCode: (code: string) => void;
};

const useSettings = (prefs: Prefs | null): AppSettings => {
  const [appTheme, setAppThemeState] = useState<Theme | "system">(
    () => (localStorage.getItem("canvas-theme") as any) || "system",
  );
  const [langCode, setLangCodeState] = useState(detectLang);
  const [dark, setDark] = useState(systemDark);

  useEffect(() => {
    if (prefs?.theme) {
      setAppThemeState(prefs.theme);
    }
    if (prefs?.langCode) {
      setLangCodeState(prefs.langCode);
    }
  }, [prefs]);

  useEffect(() => {
    const mq = window.matchMedia?.("(prefers-color-scheme: dark)");
    const onChange = (e: MediaQueryListEvent) => setDark(e.matches);
    mq?.addEventListener("change", onChange);
    return () => mq?.removeEventListener("change", onChange);
  }, []);

  const editorTheme: Theme =
    appTheme === "system" ? (dark ? THEME.DARK : THEME.LIGHT) : appTheme;

  useLayoutEffect(() => {
    document.documentElement.classList.toggle("dark", editorTheme === "dark");
  }, [editorTheme]);

  const persist = useCallback(
    (patch: Prefs) => {
      loadPrefs()
        .then((current) => savePrefs({ ...current, ...patch }))
        .catch(console.error);
    },
    [],
  );

  return {
    appTheme,
    editorTheme,
    langCode,
    setAppTheme: (theme) => {
      setAppThemeState(theme);
      try {
        localStorage.setItem("canvas-theme", theme);
      } catch {}
      persist({ theme });
    },
    setLangCode: (code) => {
      setLangCodeState(code);
      persist({ langCode: code });
    },
  };
};

// ---------------------------------------------------------------------------

export const App = () => {
  const route = useRoute();
  const [ready, setReady] = useState(false);
  const [prefs, setPrefs] = useState<Prefs | null>(null);
  const settings = useSettings(prefs);

  useEffect(() => {
    Promise.all([loadIndex(), loadPrefs()])
      .then(([, p]) => setPrefs(p))
      .catch((error) => console.error("failed to load workspace", error))
      .finally(() => setReady(true));
    installMCP();
  }, []);

  // menu bar items and files opened from Finder
  useEffect(() => {
    if (!ready) {
      return;
    }
    const off = onNativeEvent(async (event) => {
      if (event.type === "open-file") {
        const meta = await importSceneFile(event.name, event.contents);
        if (meta) {
          navigate({ view: "scene", id: meta.id });
        }
      } else if (event.type === "menu") {
        if (event.action === "new-scene") {
          const meta = await createScene();
          navigate({ view: "scene", id: meta.id });
        } else if (event.action === "dashboard") {
          navigate({ view: "dashboard" });
        }
      }
    });
    flushPendingNativeEvents();
    return off;
  }, [ready]);

  if (!ready) {
    return null;
  }

  return route.view === "scene" ? (
    <Editor key={route.id} sceneId={route.id} settings={settings} />
  ) : (
    <Dashboard settings={settings} />
  );
};
