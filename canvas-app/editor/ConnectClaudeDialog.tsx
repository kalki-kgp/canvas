import { useState } from "react";

import { PORT, TOKEN } from "../data/native";

export const mcpAddCommand = () =>
  `claude mcp add --scope user --transport http canvas http://127.0.0.1:${PORT}/mcp --header "Authorization: Bearer ${TOKEN}"`;

export const ConnectClaudeDialog = ({ onClose }: { onClose: () => void }) => {
  const [copied, setCopied] = useState(false);
  const command = mcpAddCommand();

  return (
    <div className="canvas-modal" onClick={onClose}>
      <div
        className="canvas-modal__box"
        role="dialog"
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key === "Escape") {
            onClose();
          }
        }}
      >
        <h2>Connect Claude Code</h2>
        <p>
          Run this once in a terminal. Claude Code sessions can then draw in
          the scene that's open here, while Canvas is running.
        </p>
        <pre className="canvas-modal__code">{command}</pre>
        <div className="canvas-modal__actions">
          <button className="canvas-btn" onClick={onClose}>
            Close
          </button>
          <button
            className="canvas-btn canvas-btn--primary"
            onClick={async () => {
              await navigator.clipboard.writeText(command);
              setCopied(true);
            }}
          >
            {copied ? "Copied" : "Copy command"}
          </button>
        </div>
      </div>
    </div>
  );
};
