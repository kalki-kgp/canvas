// Runs Claude Code headless (`claude -p`) through the native shell, on the
// user's own Claude Code login. The shell streams the CLI's stream-json lines
// back as server-sent events; this turns them into simple events.

import { parseSSEStream } from "@excalidraw/excalidraw";

import { api } from "./native";

export type ClaudeMode =
  /** no tools: pure text generation */
  | "text"
  /** may read the attached image only */
  | "vision"
  /** drives the open canvas through the Canvas MCP tools */
  | "agent";

export type ClaudeEvent =
  | { type: "session"; id: string }
  | { type: "text"; delta: string }
  | { type: "tool"; id: string; name: string; input: unknown }
  | { type: "tool_result"; id: string; isError: boolean; text: string }
  | { type: "result"; text: string; isError: boolean }
  | { type: "error"; message: string };

export type ClaudeRequest = {
  prompt: string;
  system?: string;
  mode: ClaudeMode;
  /** data URL; saved to a temp file the model is told to read */
  image?: string;
  /** continue an earlier conversation */
  sessionId?: string;
  model?: string;
  signal?: AbortSignal;
  onEvent?: (event: ClaudeEvent) => void;
};

const toText = (content: unknown): string => {
  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .map((c: any) => (c?.type === "text" ? c.text : c?.type ? `[${c.type}]` : ""))
      .join("");
  }
  return "";
};

/** Resolves with the final text (or throws on failure) */
export const runClaude = async (req: ClaudeRequest): Promise<{
  text: string;
  sessionId: string | null;
}> => {
  const { signal, onEvent, ...body } = req;
  const res = await api("claude", {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "text/event-stream" },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok || !res.body) {
    throw new Error((await res.text()) || `Claude failed (${res.status})`);
  }

  let sessionId: string | null = null;
  let streamed = "";
  let final: { text: string; isError: boolean } | null = null;
  const errors: string[] = [];
  const emit = (event: ClaudeEvent) => onEvent?.(event);

  for await (const data of parseSSEStream(res.body.getReader())) {
    if (data === "[DONE]") {
      break;
    }
    let msg: any;
    try {
      msg = JSON.parse(data);
    } catch {
      continue;
    }

    switch (msg.type) {
      case "canvas_error":
        errors.push(msg.message);
        emit({ type: "error", message: msg.message });
        break;
      case "system":
        if (msg.subtype === "init" && msg.session_id) {
          sessionId = msg.session_id;
          emit({ type: "session", id: msg.session_id });
        }
        break;
      case "stream_event": {
        const ev = msg.event;
        if (ev?.type === "content_block_delta" && ev.delta?.type === "text_delta") {
          streamed += ev.delta.text;
          emit({ type: "text", delta: ev.delta.text });
        }
        break;
      }
      case "assistant":
        for (const block of msg.message?.content ?? []) {
          if (block.type === "tool_use") {
            emit({
              type: "tool",
              id: block.id,
              name: String(block.name).replace(/^mcp__canvas__/, ""),
              input: block.input,
            });
          }
        }
        break;
      case "user":
        for (const block of msg.message?.content ?? []) {
          if (block.type === "tool_result") {
            emit({
              type: "tool_result",
              id: block.tool_use_id,
              isError: !!block.is_error,
              text: toText(block.content).slice(0, 500),
            });
          }
        }
        break;
      case "result":
        final = {
          text: typeof msg.result === "string" ? msg.result : streamed,
          isError: !!msg.is_error || msg.subtype !== "success",
        };
        emit({ type: "result", ...final });
        break;
    }
  }

  if (final?.isError) {
    throw new Error(final.text || errors.join("\n") || "Claude failed");
  }
  if (!final) {
    throw new Error(errors.join("\n") || "Claude stopped without a result");
  }
  return { text: final.text, sessionId };
};
