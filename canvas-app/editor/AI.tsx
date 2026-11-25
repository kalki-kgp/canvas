// The editor's built-in AI features (text-to-diagram chat and wireframe-to-
// code), backed by Claude Code instead of excalidraw's hosted AI backend.

import {
  DiagramToCodePlugin,
  THEME,
  TTDDialog,
  exportScene,
  getNonDeletedElements,
  getTextFromElements,
} from "@excalidraw/excalidraw";
import { getDataURL } from "@excalidraw/excalidraw/data/blob";
import { RequestError } from "@excalidraw/excalidraw/errors";

import { runClaude } from "../data/claude";
import { blobs } from "../data/native";

import type {
  SavedChats,
  TTDPersistenceAdapter,
} from "@excalidraw/excalidraw";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";

const TTD_SYSTEM = `You turn requests into diagrams for Excalidraw, which renders Mermaid.
Reply with ONLY a Mermaid definition: no code fences, no prose before or after.
Prefer flowchart (graph TD/LR), sequenceDiagram, classDiagram, erDiagram, stateDiagram-v2 or mindmap.
Keep labels short. Quote labels containing punctuation, e.g. A["Load (cached)"].
When the conversation already has a diagram, return the full updated diagram.`;

const D2C_SYSTEM = `You convert a hand-drawn wireframe into a working web page.
Reply with ONLY one complete HTML document (inline <style> and <script>), no code fences, no prose.
Match the wireframe's layout, components and text closely; make it look clean and modern.
Use realistic placeholder content where the wireframe is vague. No external assets except https images from placehold.co if needed.`;

const stripFences = (text: string) =>
  text
    .trim()
    .replace(/^```[a-z]*\s*\n?/i, "")
    .replace(/\n?```\s*$/, "")
    .trim();

const TTDChatsAdapter: TTDPersistenceAdapter = {
  async loadChats() {
    return (await blobs.getJSON<SavedChats>("ttd-chats.json")) ?? [];
  },
  async saveChats(chats) {
    await blobs.putJSON("ttd-chats.json", chats);
  },
};

export const AIComponents = ({
  excalidrawAPI,
}: {
  excalidrawAPI: ExcalidrawImperativeAPI;
}) => (
  <>
    <DiagramToCodePlugin
      generate={async ({ frame, children, onPartial }) => {
        const appState = excalidrawAPI.getAppState();
        const blob = await exportScene({
          type: "jpeg",
          data: {
            elements: getNonDeletedElements(children),
            appState,
            files: excalidrawAPI.getFiles(),
          },
          config: { exportingFrame: frame, theme: THEME.LIGHT },
        });
        const image = await getDataURL(blob);
        const texts = getTextFromElements(children);

        let html = "";
        const { text } = await runClaude({
          mode: "vision",
          system: D2C_SYSTEM,
          image,
          prompt: `Build this wireframe as a web page.${
            texts ? `\n\nText in the wireframe:\n${texts}` : ""
          }\nPreferred color scheme: ${appState.theme}.`,
          onEvent: (event) => {
            if (event.type === "text") {
              html += event.delta;
              onPartial?.(stripFences(html));
            }
          },
        });
        return { html: stripFences(text || html) };
      }}
    />

    <TTDDialog
      persistenceAdapter={TTDChatsAdapter}
      onTextSubmit={async ({ messages, onChunk, onStreamCreated, signal }) => {
        const transcript = messages
          .map(
            (m) =>
              `${m.role === "user" ? "User" : "Assistant (your earlier Mermaid)"}:\n${m.content}`,
          )
          .join("\n\n");
        let started = false;
        try {
          const { text } = await runClaude({
            mode: "text",
            system: TTD_SYSTEM,
            prompt:
              messages.length > 1
                ? `${transcript}\n\nReply to the last user message.`
                : messages[0]?.content ?? "",
            signal,
            onEvent: (event) => {
              if (event.type === "text") {
                if (!started) {
                  started = true;
                  onStreamCreated?.();
                }
                onChunk?.(event.delta);
              }
            },
          });
          return { generatedResponse: stripFences(text), error: null };
        } catch (error: any) {
          return {
            error: new RequestError({
              message:
                error?.name === "AbortError"
                  ? "Request aborted"
                  : error?.message || "Generation failed",
              status: error?.name === "AbortError" ? 499 : 500,
            }),
          };
        }
      }}
    />
  </>
);
