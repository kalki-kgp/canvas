import { useEffect, useRef, useState } from "react";
import { Sidebar } from "@excalidraw/excalidraw";

import { runClaude } from "../data/claude";
import { getSceneMeta } from "../data/store";

import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";

type Turn =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string }
  | { kind: "tool"; id: string; name: string; summary: string; status: "running" | "ok" | "error"; detail?: string }
  | { kind: "error"; text: string };

type Chat = { turns: Turn[]; sessionId: string | null };

// chats survive closing the sidebar, per scene, for this app session
const chats = new Map<string, Chat>();

const AGENT_SYSTEM = `You are the drawing assistant inside Canvas, the user's Excalidraw app on their Mac.
You work on the scene that is open in the app, using the canvas MCP tools; the user watches the canvas update live.
Always: get_scene first, draw with add_elements or add_mermaid, then screenshot to check the result and fix problems (overlaps, cramped or cut-off labels, crossing arrows) before finishing.
Make diagrams clean and readable: consistent sizes, aligned grid, 40–80px gaps, labels inside shapes, arrows bound to shapes, a few soft fill colors.
Keep your text replies short: one or two sentences about what you did.`;

const summarize = (name: string, input: any): string => {
  switch (name) {
    case "add_elements":
      return `add ${input?.elements?.length ?? 0} elements`;
    case "update_elements":
      return `update ${input?.updates?.length ?? 0} elements`;
    case "delete_elements":
      return `delete ${input?.ids?.length ?? 0} elements`;
    case "add_mermaid":
      return `mermaid: ${String(input?.definition ?? "").split("\n")[0].slice(0, 40)}`;
    case "screenshot":
      return input?.frameId ? "look at frame" : "look at canvas";
    case "get_scene":
      return "read scene";
    default:
      return name.replace(/_/g, " ");
  }
};

export const ClaudePanel = ({
  api,
  sceneId,
}: {
  api: ExcalidrawImperativeAPI;
  sceneId: string;
}) => {
  const [chat, setChat] = useState<Chat>(
    () => chats.get(sceneId) ?? { turns: [], sessionId: null },
  );
  const [prompt, setPrompt] = useState("");
  const [running, setRunning] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    chats.set(sceneId, chat);
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight });
  }, [chat, sceneId]);

  useEffect(() => () => abortRef.current?.abort(), []);

  const send = async () => {
    const text = prompt.trim();
    if (!text || running) {
      return;
    }
    setPrompt("");
    setRunning(true);
    const controller = new AbortController();
    abortRef.current = controller;

    const selected = Object.keys(api.getAppState().selectedElementIds);
    const context = [
      `Open scene: “${getSceneMeta(sceneId)?.name ?? "Untitled"}”.`,
      selected.length
        ? `The user has selected element ids: ${selected.join(", ")}.`
        : "",
    ]
      .filter(Boolean)
      .join(" ");

    const push = (turn: Turn) =>
      setChat((c) => ({ ...c, turns: [...c.turns, turn] }));
    push({ kind: "user", text });

    let assistantOpen = false;
    try {
      const { sessionId } = await runClaude({
        mode: "agent",
        system: AGENT_SYSTEM,
        prompt: `${context}\n\n${text}`,
        sessionId: chat.sessionId ?? undefined,
        signal: controller.signal,
        onEvent: (event) => {
          if (event.type === "session") {
            setChat((c) => ({ ...c, sessionId: event.id }));
          } else if (event.type === "text") {
            setChat((c) => {
              const turns = [...c.turns];
              const last = turns[turns.length - 1];
              if (assistantOpen && last?.kind === "assistant") {
                turns[turns.length - 1] = { ...last, text: last.text + event.delta };
              } else {
                turns.push({ kind: "assistant", text: event.delta });
                assistantOpen = true;
              }
              return { ...c, turns };
            });
          } else if (event.type === "tool") {
            assistantOpen = false;
            push({
              kind: "tool",
              id: event.id,
              name: event.name,
              summary: summarize(event.name, event.input),
              status: "running",
            });
          } else if (event.type === "tool_result") {
            setChat((c) => ({
              ...c,
              turns: c.turns.map((t) =>
                t.kind === "tool" && t.id === event.id
                  ? {
                      ...t,
                      status: event.isError ? "error" : "ok",
                      detail: event.isError ? event.text : undefined,
                    }
                  : t,
              ),
            }));
          }
        },
      });
      if (sessionId) {
        setChat((c) => ({ ...c, sessionId }));
      }
    } catch (error: any) {
      if (error?.name !== "AbortError") {
        push({ kind: "error", text: error?.message || String(error) });
      }
    } finally {
      setRunning(false);
      abortRef.current = null;
      // tools still running when stopped won't report back
      setChat((c) => ({
        ...c,
        turns: c.turns.map((t) =>
          t.kind === "tool" && t.status === "running" ? { ...t, status: "error" } : t,
        ),
      }));
    }
  };

  return (
    <div className="canvas-panel canvas-claude">
      <Sidebar.Header>
        <div className="canvas-panel__title">Claude</div>
        {chat.turns.length > 0 && !running && (
          <button
            className="canvas-link"
            onClick={() => setChat({ turns: [], sessionId: null })}
          >
            New chat
          </button>
        )}
      </Sidebar.Header>

      <div className="canvas-claude__turns" ref={listRef}>
        {chat.turns.map((turn, i) => {
          switch (turn.kind) {
            case "user":
              return (
                <div key={i} className="canvas-claude__user">
                  {turn.text}
                </div>
              );
            case "assistant":
              return (
                <div key={i} className="canvas-claude__assistant">
                  {turn.text}
                </div>
              );
            case "tool":
              return (
                <div
                  key={i}
                  className={`canvas-claude__tool is-${turn.status}`}
                  title={turn.detail}
                >
                  {turn.summary}
                  {turn.status === "running" ? "…" : ""}
                  {turn.detail && (
                    <div className="canvas-claude__tool-detail">{turn.detail}</div>
                  )}
                </div>
              );
            case "error":
              return (
                <div key={i} className="canvas-claude__error">
                  {turn.text}
                </div>
              );
          }
          return null;
        })}
        {running && <div className="canvas-claude__working">Working…</div>}
      </div>

      <div className="canvas-claude__composer">
        <textarea
          className="canvas-input"
          rows={3}
          placeholder="What should Claude draw?"
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          onKeyDown={(e) => {
            e.stopPropagation();
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              send();
            }
          }}
        />
        {running ? (
          <button className="canvas-btn" onClick={() => abortRef.current?.abort()}>
            Stop
          </button>
        ) : (
          <button
            className="canvas-btn canvas-btn--primary"
            disabled={!prompt.trim()}
            onClick={send}
          >
            Send
          </button>
        )}
      </div>
    </div>
  );
};
