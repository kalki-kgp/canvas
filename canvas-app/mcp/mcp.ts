// The Canvas MCP server's logic. The native shell exposes it over HTTP at
// /mcp (streamable HTTP, JSON responses) and hands each JSON-RPC message to
// `window.canvasMCP.handle()`, so tools act on the live editor.

import {
  CaptureUpdateAction,
  THEME,
  convertToExcalidrawElements,
  exportScene,
  getCommonBounds,
  getNonDeletedElements,
  newElementWith,
} from "@excalidraw/excalidraw";
import { getDataURL } from "@excalidraw/excalidraw/data/blob";
import { MERMAID_TO_EXCALIDRAW_CONFIG } from "@excalidraw/excalidraw/mermaid";

import { navigate } from "../App";
import { createScene, getIndex, getSceneMeta, renameScene } from "../data/store";
import { getSession, waitForSession } from "../editor/session";
import { getSlides, slideName } from "../editor/slides";

import type { EditorSession } from "../editor/session";
import type { ExcalidrawElementSkeleton } from "@excalidraw/element/transform";
import type {
  ExcalidrawElement,
  ExcalidrawTextElement,
  NonDeletedExcalidrawElement,
} from "@excalidraw/element/types";

type Content =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string };

type Tool = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  run: (args: any) => Promise<Content[] | string | object>;
};

const obj = (
  properties: Record<string, unknown>,
  required: string[] = [],
) => ({ type: "object", properties, required, additionalProperties: false });

const requireSession = (): EditorSession => {
  const session = getSession();
  if (!session) {
    throw new Error(
      "No scene is open. Use list_scenes + open_scene, or create_scene first.",
    );
  }
  return session;
};

const live = (session: EditorSession) =>
  getNonDeletedElements(session.api.getSceneElements());

const round = (n: number) => Math.round(n * 10) / 10;

/** compact, LLM-friendly view of an element */
const describe = (
  el: NonDeletedExcalidrawElement,
  byId: Map<string, NonDeletedExcalidrawElement>,
) => {
  const out: Record<string, unknown> = {
    id: el.id,
    type: el.type,
    x: round(el.x),
    y: round(el.y),
    width: round(el.width),
    height: round(el.height),
  };
  if (el.angle) {
    out.angle = round(el.angle);
  }
  if (el.strokeColor !== "#1e1e1e") {
    out.strokeColor = el.strokeColor;
  }
  if (el.backgroundColor !== "transparent") {
    out.backgroundColor = el.backgroundColor;
  }
  if (el.frameId) {
    out.frameId = el.frameId;
  }
  if (el.groupIds.length) {
    out.groupIds = el.groupIds;
  }
  if (el.link) {
    out.link = el.link;
  }
  if (el.locked) {
    out.locked = true;
  }
  if (el.type === "text") {
    out.text = el.text;
    out.fontSize = el.fontSize;
    if (el.containerId) {
      out.containerId = el.containerId;
    }
  }
  const label = el.boundElements?.find((b) => b.type === "text");
  if (label) {
    const text = byId.get(label.id) as ExcalidrawTextElement | undefined;
    if (text) {
      out.label = text.text;
    }
  }
  if (el.type === "frame" || el.type === "magicframe") {
    out.name = el.name;
  }
  if (el.type === "arrow" || el.type === "line") {
    out.points = el.points.map(([px, py]) => [round(px), round(py)]);
    if (el.type === "arrow") {
      if (el.startBinding) {
        out.startId = el.startBinding.elementId;
      }
      if (el.endBinding) {
        out.endId = el.endBinding.elementId;
      }
    }
  }
  return out;
};

const addToScene = (
  session: EditorSession,
  added: readonly ExcalidrawElement[],
  replaced: readonly ExcalidrawElement[] = [],
) => {
  const replacedById = new Map(replaced.map((e) => [e.id, e]));
  const existing = session.api
    .getSceneElements()
    .map((el) => replacedById.get(el.id) ?? el);
  session.api.updateScene({
    elements: [...existing, ...added],
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
};

const BINDABLE = new Set(["rectangle", "ellipse", "diamond", "stickynote"]);

type Box = { x: number; y: number; width: number; height: number };

/** where the ray from a box's centre towards `toward` leaves the box */
const edgePoint = (box: Box, toward: { x: number; y: number }, gap: number) => {
  const cx = box.x + box.width / 2;
  const cy = box.y + box.height / 2;
  const dx = toward.x - cx;
  const dy = toward.y - cy;
  if (!dx && !dy) {
    return { x: cx, y: cy };
  }
  const t = Math.min(
    dx ? box.width / 2 / Math.abs(dx) : Infinity,
    dy ? box.height / 2 / Math.abs(dy) : Infinity,
  );
  const len = Math.hypot(dx, dy);
  return {
    x: cx + dx * t + (dx / len) * gap,
    y: cy + dy * t + (dy / len) * gap,
  };
};

/**
 * The skeleton converter binds arrows but keeps the geometry it's given, so
 * an arrow that only names its start and end shapes would point nowhere.
 * Route those from edge to edge (straight, along the line between centres).
 */
const routeArrows = (
  skeletons: any[],
  scene: Map<string, NonDeletedExcalidrawElement>,
) => {
  const boxes = new Map<string, Box>();
  for (const [id, el] of scene) {
    boxes.set(id, el);
  }
  for (const s of skeletons) {
    if (s?.id && s.type !== "arrow" && s.type !== "line" && typeof s.x === "number") {
      boxes.set(s.id, {
        x: s.x,
        y: s.y,
        width: s.width ?? 100,
        height: s.height ?? 100,
      });
    }
  }
  for (const s of skeletons) {
    if (s?.type !== "arrow" || s.points || s.elbowed) {
      continue;
    }
    const from = s.start?.id && boxes.get(s.start.id);
    const to = s.end?.id && boxes.get(s.end.id);
    if (!from || !to) {
      continue;
    }
    const centre = (b: Box) => ({ x: b.x + b.width / 2, y: b.y + b.height / 2 });
    const a = edgePoint(from, centre(to), 6);
    const b = edgePoint(to, centre(from), 6);
    s.x = a.x;
    s.y = a.y;
    s.width = Math.abs(b.x - a.x);
    s.height = Math.abs(b.y - a.y);
    s.points = [
      [0, 0],
      [b.x - a.x, b.y - a.y],
    ];
  }
};

/**
 * Converts skeletons to elements. Arrows may bind to elements that already
 * exist in the scene: those are stood in for by placeholder copies during
 * conversion, then the originals get the new arrow bindings.
 */
const convertWithExistingBindings = (
  session: EditorSession,
  skeletons: any[],
) => {
  const scene = new Map(live(session).map((el) => [el.id, el]));
  const batchIds = new Set(skeletons.map((s) => s?.id).filter(Boolean));
  const placeholders = new Map<string, NonDeletedExcalidrawElement>();

  for (const s of skeletons) {
    if (s?.type !== "arrow") {
      continue;
    }
    for (const end of [s.start, s.end]) {
      const id = end?.id;
      if (id && !batchIds.has(id) && scene.has(id) && !placeholders.has(id)) {
        const el = scene.get(id)!;
        if (!BINDABLE.has(el.type)) {
          throw new Error(
            `Arrows can bind to rectangles, ellipses, diamonds and sticky notes; ${id} is a ${el.type}.`,
          );
        }
        placeholders.set(id, el);
      }
    }
  }

  routeArrows(skeletons, scene);

  const stand_ins = [...placeholders.values()].map((el) => ({
    type: el.type === "stickynote" ? "rectangle" : el.type,
    id: el.id,
    x: el.x,
    y: el.y,
    width: el.width,
    height: el.height,
    angle: el.angle,
  }));

  const converted = convertToExcalidrawElements(
    [...stand_ins, ...skeletons] as ExcalidrawElementSkeleton[],
    { regenerateIds: false },
  );

  const added = converted.filter((el) => !placeholders.has(el.id));
  const updatedOriginals = converted
    .filter((el) => placeholders.has(el.id))
    .map((copy) => {
      const original = placeholders.get(copy.id)!;
      const arrows = (copy.boundElements ?? []).filter(
        (b) => b.type === "arrow",
      );
      return newElementWith(original, {
        boundElements: [...(original.boundElements ?? []), ...arrows],
      });
    });

  return { added, updatedOriginals };
};

const screenshot = async (
  session: EditorSession,
  opts: { frameId?: string; ids?: string[]; maxSize?: number },
): Promise<Content[]> => {
  const all = live(session);
  let elements = all;
  let exportingFrame = null as any;
  if (opts.frameId) {
    exportingFrame = all.find((el) => el.id === opts.frameId);
    if (!exportingFrame) {
      throw new Error(`No frame ${opts.frameId}`);
    }
  } else if (opts.ids?.length) {
    const ids = new Set(opts.ids);
    elements = all.filter(
      (el) => ids.has(el.id) || (el.type === "text" && el.containerId && ids.has(el.containerId)),
    );
  }
  if (!elements.length) {
    return [{ type: "text", text: "The canvas is empty." }];
  }
  const appState = session.api.getAppState();
  const blob = await exportScene({
    type: "png",
    data: { elements, appState, files: session.api.getFiles() },
    config: {
      exportingFrame,
      theme: appState.theme === THEME.DARK ? THEME.DARK : THEME.LIGHT,
      maxWidthOrHeight: Math.min(Math.max(opts.maxSize ?? 1200, 200), 2000),
      padding: 20,
    },
  });
  const dataURL = await getDataURL(blob);
  const [minX, minY, maxX, maxY] = getCommonBounds(elements);
  return [
    { type: "image", data: dataURL.split(",")[1], mimeType: "image/png" },
    {
      type: "text",
      text: `Rendered ${elements.length} elements; scene bounds x ${round(minX)}..${round(maxX)}, y ${round(minY)}..${round(maxY)}.`,
    },
  ];
};

const SKELETON_DOC = `Each element is an Excalidraw element skeleton:
- Shapes: {"type":"rectangle"|"ellipse"|"diamond","x","y","width","height", "label":{"text":"..."}?, "id"?}
- Sticky note: {"type":"stickynote","x","y","width"?,"height"?,"label":{"text":"..."}}
- Text: {"type":"text","x","y","text","fontSize"? (16 small, 20 default, 28 large, 36 xl)}
- Arrow: {"type":"arrow","x","y","width"?,"height"?, "start":{"id":"<element id>"}?, "end":{"id":"<element id>"}?, "label":{"text"}?, "endArrowhead":"arrow"|"triangle"|"dot"|null?, "elbowed"?: true}
  start/end may reference ids created in the same call or existing scene elements (rectangle/ellipse/diamond/stickynote). With both set, leave out x/y/points: the arrow is routed edge to edge automatically.
  Without bindings, give x,y and "points":[[0,0],[dx,dy],...] relative to x,y.
- Line: {"type":"line","x","y","points":[[0,0],[dx,dy],...]}
- Frame (a slide): {"type":"frame","name"?,"children":["<ids of elements inside>"]} — sized to fit its children.
Common style props: strokeColor, backgroundColor (e.g. "#a5d8ff", "#b2f2bb", "#ffec99", "#ffc9c9", "#d0bfff", "transparent"), fillStyle ("solid"|"hachure"|"cross-hatch"), strokeWidth (1|2|4), strokeStyle ("solid"|"dashed"|"dotted"), roughness (0 architect, 1 artist, 2 cartoonist), roundness ({"type":3} for rounded corners), opacity (0-100), fontFamily (5 hand-drawn, 6 normal, 8 code).
Give elements your own short ids (e.g. "api", "db") so arrows and frames can reference them.`;

const UPDATABLE = new Set([
  "x",
  "y",
  "width",
  "height",
  "angle",
  "strokeColor",
  "backgroundColor",
  "fillStyle",
  "strokeWidth",
  "strokeStyle",
  "roughness",
  "opacity",
  "locked",
  "link",
  "name",
  "fontSize",
]);

const tools: Tool[] = [
  {
    name: "list_scenes",
    description:
      "List the scenes (drawings) in the Canvas workspace, newest first, with their collection and which one is open.",
    inputSchema: obj({
      query: { type: "string", description: "filter by name (optional)" },
    }),
    async run({ query }) {
      const { scenes, collections } = getIndex();
      const open = getSession()?.sceneId;
      const q = (query || "").toLowerCase();
      return [...scenes]
        .sort((a, b) => b.updatedAt - a.updatedAt)
        .filter((s) => !q || s.name.toLowerCase().includes(q))
        .map((s) => ({
          id: s.id,
          name: s.name,
          collection:
            collections.find((c) => c.id === s.collectionId)?.name ?? null,
          updatedAt: new Date(s.updatedAt).toISOString(),
          open: s.id === open,
        }));
    },
  },
  {
    name: "open_scene",
    description: "Open a scene in the editor (by id from list_scenes).",
    inputSchema: obj({ id: { type: "string" } }, ["id"]),
    async run({ id }) {
      if (!getSceneMeta(id)) {
        throw new Error(`No scene ${id}`);
      }
      navigate({ view: "scene", id });
      await waitForSession(id);
      return `Opened “${getSceneMeta(id)?.name}”.`;
    },
  },
  {
    name: "create_scene",
    description: "Create a new empty scene and open it.",
    inputSchema: obj(
      {
        name: { type: "string" },
        collection: {
          type: "string",
          description: "name of an existing collection (optional)",
        },
      },
      ["name"],
    ),
    async run({ name, collection }) {
      const collectionId = collection
        ? getIndex().collections.find(
            (c) => c.name.toLowerCase() === String(collection).toLowerCase(),
          )?.id ?? null
        : null;
      const meta = await createScene({ name, collectionId });
      navigate({ view: "scene", id: meta.id });
      await waitForSession(meta.id);
      return { id: meta.id, name: meta.name };
    },
  },
  {
    name: "rename_scene",
    description: "Rename the open scene.",
    inputSchema: obj({ name: { type: "string" } }, ["name"]),
    async run({ name }) {
      const session = requireSession();
      await renameScene(session.sceneId, name);
      return `Renamed to “${name}”.`;
    },
  },
  {
    name: "get_scene",
    description:
      "Describe the elements on the open scene (ids, types, positions, sizes, text, labels, arrow bindings) plus the overall bounds. Call before editing so you know what's there and where free space is.",
    inputSchema: obj({}),
    async run() {
      const session = requireSession();
      const elements = live(session);
      const byId = new Map(elements.map((el) => [el.id, el]));
      const top = elements.filter(
        (el) => !(el.type === "text" && el.containerId),
      );
      const bounds = elements.length ? getCommonBounds(elements) : null;
      return {
        scene: getSceneMeta(session.sceneId)?.name,
        bounds: bounds && {
          minX: round(bounds[0]),
          minY: round(bounds[1]),
          maxX: round(bounds[2]),
          maxY: round(bounds[3]),
        },
        count: top.length,
        elements: top.map((el) => describe(el, byId)),
      };
    },
  },
  {
    name: "add_elements",
    description: `Add elements to the open scene. ${SKELETON_DOC}`,
    inputSchema: obj(
      {
        elements: {
          type: "array",
          items: { type: "object" },
          description: "element skeletons",
        },
      },
      ["elements"],
    ),
    async run({ elements }) {
      const session = requireSession();
      if (!Array.isArray(elements) || !elements.length) {
        throw new Error("elements must be a non-empty array");
      }
      const existing = new Set(
        session.api.getSceneElements().map((el) => el.id),
      );
      const clash = elements.find((s: any) => s?.id && existing.has(s.id));
      if (clash) {
        throw new Error(
          `id “${clash.id}” is already used in the scene; pick another`,
        );
      }
      const { added, updatedOriginals } = convertWithExistingBindings(
        session,
        elements,
      );
      addToScene(session, added, updatedOriginals);
      return {
        added: added
          .filter((el) => !(el.type === "text" && el.containerId))
          .map((el) => ({ id: el.id, type: el.type })),
      };
    },
  },
  {
    name: "update_elements",
    description: `Change properties of existing elements: ${[...UPDATABLE].join(", ")}, and "text" for text elements or shape labels. Moving a shape moves its label too.`,
    inputSchema: obj(
      {
        updates: {
          type: "array",
          items: {
            type: "object",
            properties: { id: { type: "string" } },
            required: ["id"],
          },
        },
      },
      ["updates"],
    ),
    async run({ updates }) {
      const session = requireSession();
      const elements = session.api.getSceneElements();
      const byId = new Map(elements.map((el) => [el.id, el]));
      const changed = new Map<string, ExcalidrawElement>();
      const missing: string[] = [];

      for (const { id, text, ...props } of updates as any[]) {
        const el = byId.get(id);
        if (!el || el.isDeleted) {
          missing.push(id);
          continue;
        }
        const patch: Record<string, unknown> = {};
        for (const [key, value] of Object.entries(props)) {
          if (UPDATABLE.has(key)) {
            patch[key] = value;
          }
        }
        const next = newElementWith(el, patch as any);
        changed.set(id, next);

        // labels follow their container
        const dx = (patch.x as number | undefined) ?? el.x;
        const dy = (patch.y as number | undefined) ?? el.y;
        const labelRef = el.boundElements?.find((b) => b.type === "text");
        const label = labelRef && byId.get(labelRef.id);
        if (label && (dx !== el.x || dy !== el.y)) {
          changed.set(
            label.id,
            newElementWith(label, {
              x: label.x + (dx - el.x),
              y: label.y + (dy - el.y),
            }),
          );
        }
        if (typeof text === "string") {
          const target =
            el.type === "text" ? (changed.get(id) as ExcalidrawTextElement) : label;
          if (target && target.type === "text") {
            changed.set(
              target.id,
              newElementWith(target as ExcalidrawTextElement, {
                text,
                originalText: text,
              }),
            );
          }
        }
      }

      session.api.updateScene({
        elements: elements.map((el) => changed.get(el.id) ?? el),
        captureUpdate: CaptureUpdateAction.IMMEDIATELY,
      });
      return {
        updated: [...changed.keys()].length,
        ...(missing.length ? { missing } : {}),
      };
    },
  },
  {
    name: "delete_elements",
    description: "Delete elements by id (their labels go with them).",
    inputSchema: obj(
      { ids: { type: "array", items: { type: "string" } } },
      ["ids"],
    ),
    async run({ ids }) {
      const session = requireSession();
      const doomed = new Set<string>(ids);
      const elements = session.api.getSceneElements();
      for (const el of elements) {
        if (el.type === "text" && el.containerId && doomed.has(el.containerId)) {
          doomed.add(el.id);
        }
      }
      session.api.updateScene({
        elements: elements.map((el) =>
          doomed.has(el.id) ? newElementWith(el, { isDeleted: true } as any) : el,
        ),
        captureUpdate: CaptureUpdateAction.IMMEDIATELY,
      });
      return { deleted: doomed.size };
    },
  },
  {
    name: "clear_canvas",
    description: "Remove everything from the open scene (undoable by the user).",
    inputSchema: obj({}),
    async run() {
      const session = requireSession();
      session.api.updateScene({
        elements: session.api
          .getSceneElements()
          .map((el) => newElementWith(el, { isDeleted: true } as any)),
        captureUpdate: CaptureUpdateAction.IMMEDIATELY,
      });
      return "Cleared.";
    },
  },
  {
    name: "add_mermaid",
    description:
      "Add a diagram from a Mermaid definition (flowchart, sequence, class, ER, state, mindmap…), converted to editable Excalidraw elements and placed to the right of the existing content. Often the quickest way to draw a structured diagram.",
    inputSchema: obj(
      {
        definition: { type: "string" },
        x: { type: "number", description: "left edge (optional)" },
        y: { type: "number", description: "top edge (optional)" },
      },
      ["definition"],
    ),
    async run({ definition, x, y }) {
      const session = requireSession();
      const { parseMermaidToExcalidraw } = await import(
        "@excalidraw/mermaid-to-excalidraw"
      );
      const { elements, files } = await parseMermaidToExcalidraw(
        definition,
        MERMAID_TO_EXCALIDRAW_CONFIG,
      );
      let converted = convertToExcalidrawElements(elements as any, {
        regenerateIds: true,
      });
      const existing = live(session);
      const [minX, minY] = getCommonBounds(converted);
      const targetX =
        x ?? (existing.length ? getCommonBounds(existing)[2] + 120 : 0);
      const targetY = y ?? (existing.length ? getCommonBounds(existing)[1] : 0);
      converted = converted.map((el) =>
        newElementWith(el, { x: el.x - minX + targetX, y: el.y - minY + targetY }),
      );
      if (files) {
        session.api.addFiles(Object.values(files));
      }
      addToScene(session, converted);
      return {
        added: converted.length,
        bounds: getCommonBounds(converted).map(round),
      };
    },
  },
  {
    name: "screenshot",
    description:
      "Render the open scene (or one frame, or some elements) to a PNG so you can check how it looks. Use it after drawing to verify layout and fix overlaps.",
    inputSchema: obj({
      frameId: { type: "string" },
      ids: { type: "array", items: { type: "string" } },
      maxSize: { type: "number", description: "longest side in px, default 1200" },
    }),
    async run(args) {
      return screenshot(requireSession(), args);
    },
  },
  {
    name: "zoom_to",
    description:
      "Scroll and zoom the user's view to fit elements (all content when ids is omitted).",
    inputSchema: obj({ ids: { type: "array", items: { type: "string" } } }),
    async run({ ids }) {
      const session = requireSession();
      const all = live(session);
      const target = ids?.length
        ? all.filter((el) => ids.includes(el.id))
        : all;
      if (target.length) {
        session.api.setViewport({
          target,
          fit: "contain",
          animation: true,
        });
      }
      return "Done.";
    },
  },
  {
    name: "list_slides",
    description:
      "List the open scene's slides (frames) in presentation order.",
    inputSchema: obj({}),
    async run() {
      const session = requireSession();
      return getSlides(session.api, session.getExtras().slides).map(
        (frame, i) => ({
          id: frame.id,
          name: slideName(frame, i),
          x: round(frame.x),
          y: round(frame.y),
          width: round(frame.width),
          height: round(frame.height),
        }),
      );
    },
  },
  {
    name: "set_slide_order",
    description: "Set the presentation order of slides (frame ids).",
    inputSchema: obj(
      { ids: { type: "array", items: { type: "string" } } },
      ["ids"],
    ),
    async run({ ids }) {
      const session = requireSession();
      session.setExtras({ slides: ids });
      return "Slide order saved.";
    },
  },
  {
    name: "present",
    description: "Start presentation mode in the app, from a slide index (0-based).",
    inputSchema: obj({ from: { type: "number" } }),
    async run({ from }) {
      requireSession().startPresenting(from ?? 0);
      return "Presenting.";
    },
  },
];

const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS = `Canvas is the user's Excalidraw app on this Mac. Tools act on the scene open in the app, live, while the user watches.
Workflow: get_scene first (to see what's there and find free space), then add_elements / add_mermaid, then screenshot to check the result and fix overlaps or cramped text.
Layout tips: leave 40–80px between shapes; size boxes to fit labels (~10px per character at fontSize 20, min 140×60); align things on a grid; use color sparingly for grouping.
For presentations, make one frame per slide (e.g. 1280×720, side by side with 100px gaps) and put each slide's content inside it.`;

type RpcRequest = {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: any;
};

const toContent = (result: Content[] | string | object): Content[] => {
  if (typeof result === "string") {
    return [{ type: "text", text: result }];
  }
  if (
    Array.isArray(result) &&
    result.every((c) => c && (c.type === "text" || c.type === "image"))
  ) {
    return result as Content[];
  }
  return [{ type: "text", text: JSON.stringify(result, null, 1) }];
};

const handleOne = async (req: RpcRequest) => {
  const reply = (result: unknown) => ({ jsonrpc: "2.0", id: req.id, result });
  const fail = (code: number, message: string) => ({
    jsonrpc: "2.0",
    id: req.id,
    error: { code, message },
  });

  if (req.id === undefined || req.id === null) {
    return null; // notification
  }

  switch (req.method) {
    case "initialize": {
      const asked = req.params?.protocolVersion;
      return reply({
        protocolVersion: PROTOCOL_VERSIONS.includes(asked)
          ? asked
          : PROTOCOL_VERSIONS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "canvas", version: "0.1.0" },
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
      return reply({});
    case "tools/list":
      return reply({
        tools: tools.map(({ name, description, inputSchema }) => ({
          name,
          description,
          inputSchema,
        })),
      });
    case "tools/call": {
      const tool = tools.find((t) => t.name === req.params?.name);
      if (!tool) {
        return fail(-32602, `Unknown tool ${req.params?.name}`);
      }
      try {
        const result = await tool.run(req.params?.arguments ?? {});
        // let the editor settle and persist what the tool changed
        await getSession()?.flush();
        return reply({ content: toContent(result) });
      } catch (error: any) {
        return reply({
          content: [{ type: "text", text: `Error: ${error?.message || error}` }],
          isError: true,
        });
      }
    }
    default:
      return fail(-32601, `Method not found: ${req.method}`);
  }
};

export const installMCP = () => {
  (window as any).canvasMCP = {
    /** takes and returns JSON text; "" means no response (notifications) */
    async handle(body: string): Promise<string> {
      let parsed: RpcRequest | RpcRequest[];
      try {
        parsed = JSON.parse(body);
      } catch {
        return JSON.stringify({
          jsonrpc: "2.0",
          id: null,
          error: { code: -32700, message: "Parse error" },
        });
      }
      if (Array.isArray(parsed)) {
        const results = (await Promise.all(parsed.map(handleOne))).filter(
          Boolean,
        );
        return results.length ? JSON.stringify(results) : "";
      }
      const result = await handleOne(parsed);
      return result ? JSON.stringify(result) : "";
    },
  };
};
