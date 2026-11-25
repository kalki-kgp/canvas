import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  DefaultSidebar,
  Excalidraw,
  MainMenu,
  Sidebar,
  THEME,
  TTDDialogTrigger,
  WelcomeScreen,
  exportScene,
  getNonDeletedElements,
  hashElementsVersion,
  languages,
  useHandleLibrary,
} from "@excalidraw/excalidraw";
import { clearAppStateForLocalStorage } from "@excalidraw/excalidraw/appState";
import {
  CommandPalette,
  DEFAULT_CATEGORIES,
} from "@excalidraw/excalidraw/components/CommandPalette/CommandPalette";
import { OverwriteConfirmDialog } from "@excalidraw/excalidraw/components/OverwriteConfirm/OverwriteConfirm";
import {
  MagicIcon,
  PlusIcon,
  brainIcon,
  chevronLeftIcon,
  historyIcon,
  playerPlayIcon,
  presentationIcon,
} from "@excalidraw/excalidraw/components/icons";
import { useI18n } from "@excalidraw/excalidraw/i18n";
import { isElementLink } from "@excalidraw/element";

import { navigate } from "../App";
import { libraryAdapter } from "../data/importExport";
import {
  createScene,
  fileIdsOf,
  getSceneMeta,
  listSnapshots,
  loadFiles,
  loadSceneDoc,
  renameScene,
  saveFiles,
  saveSceneDoc,
  saveSnapshot,
  saveThumbnail,
  updateSceneMeta,
  useIndex,
} from "../data/store";
import { onNativeEvent } from "../data/native";

import { AIComponents } from "./AI";
import { ClaudePanel } from "./ClaudePanel";
import { ConnectClaudeDialog } from "./ConnectClaudeDialog";
import { HistoryPanel } from "./HistoryPanel";
import { Presenter } from "./Presenter";
import { SlidesPanel } from "./SlidesPanel";
import { setSession } from "./session";

import type { AppSettings } from "../App";
import type { CanvasSceneExtras, SceneDoc } from "../data/store";
import type { ExcalidrawElement } from "@excalidraw/element/types";
import type {
  AppState,
  BinaryFiles,
  ExcalidrawImperativeAPI,
  ExcalidrawInitialDataState,
} from "@excalidraw/excalidraw/types";

const SAVE_DEBOUNCE_MS = 400;
const THUMB_DEBOUNCE_MS = 2500;
const SNAPSHOT_EVERY_MS = 5 * 60 * 1000;

export const SIDEBAR_TABS = {
  slides: "canvas-slides",
  history: "canvas-history",
  claude: "canvas-claude",
} as const;

const buildDoc = (
  elements: readonly ExcalidrawElement[],
  appState: AppState,
  extras: CanvasSceneExtras,
): SceneDoc => {
  const { theme, name, openSidebar, ...rest } =
    clearAppStateForLocalStorage(appState) as Partial<AppState>;
  return {
    type: "excalidraw",
    version: 2,
    source: "canvas",
    elements: getNonDeletedElements(elements),
    appState: rest,
    canvas: extras,
  };
};

const LanguageList = ({
  langCode,
  onChange,
}: {
  langCode: string;
  onChange: (code: string) => void;
}) => {
  const { t } = useI18n();
  return (
    <select
      className="dropdown-select dropdown-select__language"
      onChange={({ target }) => onChange(target.value)}
      value={langCode}
      aria-label={t("buttons.selectLanguage")}
      style={{ width: "100%" }}
    >
      {languages.map((lang) => (
        <option key={lang.code} value={lang.code}>
          {lang.label}
        </option>
      ))}
    </select>
  );
};

export const Editor = ({
  sceneId,
  settings,
}: {
  sceneId: string;
  settings: AppSettings;
}) => {
  const [initialData, setInitialData] =
    useState<ExcalidrawInitialDataState | null>(null);
  const [missing, setMissing] = useState(false);
  const [api, setApi] = useState<ExcalidrawImperativeAPI | null>(null);
  const [presenting, setPresenting] = useState<{ from: number } | null>(null);
  const [connectOpen, setConnectOpen] = useState(false);
  const meta = useIndex().scenes.find((s) => s.id === sceneId);

  const extrasRef = useRef<CanvasSceneExtras>({});
  const lastKeyRef = useRef<string | null>(null);
  const lastSnapshotAtRef = useRef(0);
  const dirtySinceSnapshotRef = useRef(false);
  const saveTimerRef = useRef<number | undefined>(undefined);
  const thumbTimerRef = useRef<number | undefined>(undefined);
  const pendingRef = useRef<{
    elements: readonly ExcalidrawElement[];
    appState: AppState;
    files: BinaryFiles;
  } | null>(null);
  const savingRef = useRef<Promise<void>>(Promise.resolve());

  // load ----------------------------------------------------------------------

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const doc = await loadSceneDoc(sceneId);
      const sceneMeta = getSceneMeta(sceneId);
      if (!doc || !sceneMeta) {
        if (!cancelled) {
          setMissing(true);
        }
        return;
      }
      const files = await loadFiles(fileIdsOf(doc.elements));
      extrasRef.current = doc.canvas ?? {};

      // a baseline snapshot, so the state the scene was opened in can always
      // be restored
      const snaps = await listSnapshots(sceneId);
      lastSnapshotAtRef.current = snaps[0]?.savedAt ?? 0;
      if (
        doc.elements.length &&
        (!snaps.length || snaps[0].savedAt < sceneMeta.updatedAt - 1000)
      ) {
        await saveSnapshot(sceneId, doc);
        lastSnapshotAtRef.current = Date.now();
      }

      if (!cancelled) {
        setInitialData({
          elements: doc.elements,
          appState: { ...doc.appState, name: sceneMeta.name },
          files,
          scrollToContent: !doc.appState.scrollX && !doc.appState.scrollY,
        });
      }
    })().catch((error) => {
      console.error(error);
      setMissing(true);
    });
    return () => {
      cancelled = true;
    };
  }, [sceneId]);

  useEffect(() => {
    document.title = meta?.name || "Canvas";
  }, [meta?.name]);

  // save ----------------------------------------------------------------------

  const writeThumbnail = useCallback(async () => {
    if (!api) {
      return;
    }
    const elements = getNonDeletedElements(api.getSceneElements());
    if (!elements.length) {
      await updateSceneMeta(sceneId, { thumbAt: undefined });
      return;
    }
    const blob = await exportScene({
      type: "png",
      data: {
        elements,
        appState: api.getAppState(),
        files: api.getFiles(),
      },
      config: { theme: THEME.LIGHT, maxWidthOrHeight: 640, padding: 24 },
    });
    await saveThumbnail(sceneId, blob);
  }, [api, sceneId]);

  const persist = useCallback(
    async (opts: { forceSnapshot?: boolean } = {}) => {
      const pending = pendingRef.current;
      pendingRef.current = null;
      if (!pending) {
        if (opts.forceSnapshot && dirtySinceSnapshotRef.current && api) {
          const doc = buildDoc(
            api.getSceneElements(),
            api.getAppState(),
            extrasRef.current,
          );
          await saveSnapshot(sceneId, doc);
          lastSnapshotAtRef.current = Date.now();
          dirtySinceSnapshotRef.current = false;
        }
        return;
      }
      const doc = buildDoc(pending.elements, pending.appState, extrasRef.current);
      await saveFiles(pending.files);
      await saveSceneDoc(sceneId, doc);
      dirtySinceSnapshotRef.current = true;

      if (
        opts.forceSnapshot ||
        Date.now() - lastSnapshotAtRef.current > SNAPSHOT_EVERY_MS
      ) {
        await saveSnapshot(sceneId, doc);
        lastSnapshotAtRef.current = Date.now();
        dirtySinceSnapshotRef.current = false;
      }

      window.clearTimeout(thumbTimerRef.current);
      thumbTimerRef.current = window.setTimeout(() => {
        writeThumbnail().catch(console.error);
      }, THUMB_DEBOUNCE_MS);
    },
    [api, sceneId, writeThumbnail],
  );

  const flush = useCallback(
    (opts: { forceSnapshot?: boolean } = {}) => {
      window.clearTimeout(saveTimerRef.current);
      savingRef.current = savingRef.current
        .then(() => persist(opts))
        .catch((error) => console.error("save failed", error));
      return savingRef.current;
    },
    [persist],
  );

  const scheduleSave = useCallback(() => {
    window.clearTimeout(saveTimerRef.current);
    saveTimerRef.current = window.setTimeout(() => flush(), SAVE_DEBOUNCE_MS);
  }, [flush]);

  const onChange = useCallback(
    (
      elements: readonly ExcalidrawElement[],
      appState: AppState,
      files: BinaryFiles,
    ) => {
      if (!initialData) {
        return;
      }
      const key = [
        hashElementsVersion(elements),
        appState.viewBackgroundColor,
        appState.gridModeEnabled,
        Object.keys(files).length,
      ].join("|");
      if (lastKeyRef.current === null) {
        // first change event reflects the loaded scene
        lastKeyRef.current = key;
      } else if (key !== lastKeyRef.current) {
        lastKeyRef.current = key;
        pendingRef.current = { elements, appState, files };
        scheduleSave();
      }
      // the export dialog lets you rename the scene
      const current = getSceneMeta(sceneId);
      if (appState.name && current && appState.name !== current.name) {
        renameScene(sceneId, appState.name);
      }
    },
    [initialData, scheduleSave, sceneId],
  );

  // keep the scene name in the editor in sync with renames elsewhere
  useEffect(() => {
    if (api && meta && api.getAppState().name !== meta.name) {
      api.updateScene({ appState: { name: meta.name } });
    }
  }, [api, meta?.name]); // eslint-disable-line react-hooks/exhaustive-deps

  // save on leave
  useEffect(() => {
    return () => {
      flush({ forceSnapshot: true });
    };
  }, [flush]);

  // session for MCP & menus --------------------------------------------------

  const startPresenting = useCallback((from = 0) => {
    setPresenting({ from });
  }, []);

  useEffect(() => {
    if (!api) {
      return;
    }
    setSession({
      sceneId,
      api,
      flush: () => flush(),
      getExtras: () => extrasRef.current,
      setExtras: (patch) => {
        extrasRef.current = { ...extrasRef.current, ...patch };
        pendingRef.current = {
          elements: api.getSceneElements(),
          appState: api.getAppState(),
          files: api.getFiles(),
        };
        scheduleSave();
      },
      startPresenting,
    });
    return () => setSession(null);
  }, [api, sceneId, flush, scheduleSave, startPresenting]);

  useHandleLibrary({ excalidrawAPI: api, adapter: libraryAdapter });

  const newScene = useCallback(async () => {
    const created = await createScene({ collectionId: meta?.collectionId });
    navigate({ view: "scene", id: created.id });
  }, [meta?.collectionId]);

  const openTab = useCallback(
    (tab: string) => {
      api?.toggleSidebar({ name: "default", tab, force: true });
    },
    [api],
  );

  useEffect(
    () =>
      onNativeEvent((event) => {
        if (event.type !== "menu") {
          return;
        }
        switch (event.action) {
          case "present":
            startPresenting(0);
            break;
          case "history":
            openTab(SIDEBAR_TABS.history);
            break;
          case "claude":
            openTab(SIDEBAR_TABS.claude);
            break;
          case "save-version":
            flush({ forceSnapshot: true });
            api?.setToast({ message: "Version saved", duration: 1500 });
            break;
        }
      }),
    [api, flush, openTab, startPresenting],
  );

  const commandItems = useMemo(
    () => [
      {
        label: "All scenes",
        category: DEFAULT_CATEGORIES.app,
        icon: chevronLeftIcon,
        keywords: ["dashboard", "home", "scenes", "back"],
        perform: () => navigate({ view: "dashboard" }),
      },
      {
        label: "New scene",
        category: DEFAULT_CATEGORIES.app,
        icon: PlusIcon,
        keywords: ["create", "blank"],
        perform: () => newScene(),
      },
      {
        label: "Present",
        category: DEFAULT_CATEGORIES.app,
        icon: playerPlayIcon,
        keywords: ["slides", "presentation", "frames", "slideshow"],
        perform: () => startPresenting(0),
      },
      {
        label: "Slides",
        category: DEFAULT_CATEGORIES.app,
        icon: presentationIcon,
        keywords: ["presentation", "frames", "order", "pdf"],
        perform: () => openTab(SIDEBAR_TABS.slides),
      },
      {
        label: "Version history",
        category: DEFAULT_CATEGORIES.app,
        icon: historyIcon,
        keywords: ["versions", "snapshots", "restore", "revert"],
        perform: () => openTab(SIDEBAR_TABS.history),
      },
      {
        label: "Ask Claude",
        category: DEFAULT_CATEGORIES.app,
        icon: brainIcon,
        keywords: ["ai", "agent", "claude", "generate"],
        perform: () => openTab(SIDEBAR_TABS.claude),
      },
    ],
    [newScene, openTab, startPresenting],
  );

  if (missing) {
    return (
      <div className="canvas-missing excalidraw">
        <p>This scene doesn't exist anymore.</p>
        <button onClick={() => navigate({ view: "dashboard" })}>
          Back to all scenes
        </button>
      </div>
    );
  }

  if (!initialData) {
    return null;
  }

  return (
    <div className="canvas-editor" style={{ height: "100%" }}>
      <Excalidraw
        onExcalidrawAPI={setApi}
        initialData={initialData}
        onChange={onChange}
        theme={settings.editorTheme}
        onThemeChange={settings.setAppTheme}
        langCode={settings.langCode}
        handleKeyboardGlobally={true}
        autoFocus={true}
        detectScroll={false}
        UIOptions={{ canvasActions: { toggleTheme: true } }}
        onLinkOpen={(element, event) => {
          if (element.link && isElementLink(element.link)) {
            event.preventDefault();
            api?.setViewport({
              target: element.link,
              fit: "scale-down",
              animation: true,
            });
          }
        }}
        renderTopRightUI={(isMobile) =>
          isMobile ? null : (
            <button
              className="canvas-present-button"
              title="Present (frames as slides)"
              onClick={() => startPresenting(0)}
            >
              {playerPlayIcon}
              <span>Present</span>
            </button>
          )
        }
      >
        <MainMenu>
          <MainMenu.Item
            icon={chevronLeftIcon}
            onSelect={() => navigate({ view: "dashboard" })}
          >
            All scenes
          </MainMenu.Item>
          <MainMenu.Item icon={PlusIcon} onSelect={newScene}>
            New scene
          </MainMenu.Item>
          <MainMenu.Separator />
          <MainMenu.DefaultItems.LoadScene />
          <MainMenu.DefaultItems.SaveToActiveFile />
          <MainMenu.DefaultItems.Export />
          <MainMenu.DefaultItems.SaveAsImage />
          <MainMenu.DefaultItems.CommandPalette className="highlighted" />
          <MainMenu.DefaultItems.SearchMenu />
          <MainMenu.DefaultItems.Help />
          <MainMenu.DefaultItems.ClearCanvas />
          <MainMenu.Separator />
          <MainMenu.Item
            icon={playerPlayIcon}
            onSelect={() => startPresenting(0)}
          >
            Present
          </MainMenu.Item>
          <MainMenu.Item
            icon={historyIcon}
            onSelect={() => openTab(SIDEBAR_TABS.history)}
          >
            Version history
          </MainMenu.Item>
          <MainMenu.Item
            icon={brainIcon}
            onSelect={() => openTab(SIDEBAR_TABS.claude)}
          >
            Ask Claude
          </MainMenu.Item>
          <MainMenu.Item icon={MagicIcon} onSelect={() => setConnectOpen(true)}>
            Connect Claude Code…
          </MainMenu.Item>
          <MainMenu.Separator />
          <MainMenu.DefaultItems.Preferences />
          <MainMenu.DefaultItems.ToggleTheme
            allowSystemTheme
            theme={settings.appTheme}
          />
          <MainMenu.ItemCustom>
            <LanguageList
              langCode={settings.langCode}
              onChange={settings.setLangCode}
            />
          </MainMenu.ItemCustom>
          <MainMenu.DefaultItems.ChangeCanvasBackground />
        </MainMenu>

        <WelcomeScreen>
          <WelcomeScreen.Hints.MenuHint />
          <WelcomeScreen.Hints.ToolbarHint />
          <WelcomeScreen.Hints.HelpHint />
          <WelcomeScreen.Center>
            <WelcomeScreen.Center.Heading>
              {meta?.name || "Untitled"}
            </WelcomeScreen.Center.Heading>
            <WelcomeScreen.Center.Menu>
              <WelcomeScreen.Center.MenuItemLoadScene />
              <WelcomeScreen.Center.MenuItem
                icon={brainIcon}
                onSelect={() => openTab(SIDEBAR_TABS.claude)}
              >
                Ask Claude to draw
              </WelcomeScreen.Center.MenuItem>
              <WelcomeScreen.Center.MenuItem
                icon={chevronLeftIcon}
                onSelect={() => navigate({ view: "dashboard" })}
              >
                All scenes
              </WelcomeScreen.Center.MenuItem>
              <WelcomeScreen.Center.MenuItemHelp />
            </WelcomeScreen.Center.Menu>
          </WelcomeScreen.Center>
        </WelcomeScreen>

        <OverwriteConfirmDialog>
          <OverwriteConfirmDialog.Actions.ExportToImage />
          <OverwriteConfirmDialog.Actions.SaveToDisk />
        </OverwriteConfirmDialog>

        <DefaultSidebar>
          <DefaultSidebar.TabTriggers>
            <Sidebar.TabTrigger tab={SIDEBAR_TABS.slides} title="Slides">
              {presentationIcon}
            </Sidebar.TabTrigger>
            <Sidebar.TabTrigger tab={SIDEBAR_TABS.history} title="Version history">
              {historyIcon}
            </Sidebar.TabTrigger>
            <Sidebar.TabTrigger tab={SIDEBAR_TABS.claude} title="Claude">
              {brainIcon}
            </Sidebar.TabTrigger>
          </DefaultSidebar.TabTriggers>
          <Sidebar.Tab tab={SIDEBAR_TABS.slides}>
            {api && (
              <SlidesPanel
                api={api}
                getExtras={() => extrasRef.current}
                setSlides={(slides) => {
                  extrasRef.current = { ...extrasRef.current, slides };
                  pendingRef.current = {
                    elements: api.getSceneElements(),
                    appState: api.getAppState(),
                    files: api.getFiles(),
                  };
                  scheduleSave();
                }}
                sceneName={meta?.name || "Untitled"}
                onPresent={startPresenting}
              />
            )}
          </Sidebar.Tab>
          <Sidebar.Tab tab={SIDEBAR_TABS.history}>
            {api && (
              <HistoryPanel
                api={api}
                sceneId={sceneId}
                saveVersion={(label) => {
                  // make the current state the newest snapshot first
                  pendingRef.current = {
                    elements: api.getSceneElements(),
                    appState: api.getAppState(),
                    files: api.getFiles(),
                  };
                  window.clearTimeout(saveTimerRef.current);
                  savingRef.current = savingRef.current.then(async () => {
                    const pending = pendingRef.current!;
                    pendingRef.current = null;
                    const doc = buildDoc(
                      pending.elements,
                      pending.appState,
                      extrasRef.current,
                    );
                    await saveFiles(pending.files);
                    await saveSceneDoc(sceneId, doc);
                    await saveSnapshot(sceneId, doc, label);
                    lastSnapshotAtRef.current = Date.now();
                    dirtySinceSnapshotRef.current = false;
                  });
                  return savingRef.current;
                }}
                restore={async (doc) => {
                  await flush({ forceSnapshot: true });
                  const files = await loadFiles(fileIdsOf(doc.elements));
                  api.addFiles(Object.values(files));
                  extrasRef.current = doc.canvas ?? {};
                  api.updateScene({
                    elements: doc.elements,
                    appState: {
                      viewBackgroundColor:
                        doc.appState.viewBackgroundColor ??
                        api.getAppState().viewBackgroundColor,
                    },
                    captureUpdate: "IMMEDIATELY",
                  });
                }}
              />
            )}
          </Sidebar.Tab>
          <Sidebar.Tab tab={SIDEBAR_TABS.claude}>
            {api && <ClaudePanel api={api} sceneId={sceneId} />}
          </Sidebar.Tab>
        </DefaultSidebar>

        {api && <AIComponents excalidrawAPI={api} />}
        <TTDDialogTrigger />

        <CommandPalette customCommandPaletteItems={commandItems} />
      </Excalidraw>

      {presenting && api && (
        <Presenter
          api={api}
          slideOrder={extrasRef.current.slides}
          startAt={presenting.from}
          onExit={() => setPresenting(null)}
        />
      )}

      {connectOpen && (
        <ConnectClaudeDialog onClose={() => setConnectOpen(false)} />
      )}
    </div>
  );
};
