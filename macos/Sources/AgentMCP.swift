import Foundation

/// The second MCP server a chat run gets: `approve` (Claude Code's
/// permission prompt tool) and `ask_user`. Both show a card in the chat
/// named by the X-Canvas-Chat header and wait for the user.
enum AgentMCP {
    static func handle(_ req: HTTPServer.Request, _ res: HTTPServer.Responder) {
        switch req.method {
        case "POST": break
        case "DELETE": return res.send(200)
        default: return res.send(405, headers: ["Allow": "POST, DELETE"])
        }
        guard let msg = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return res.text(400, "Bad body")
        }
        let id = msg["id"]
        guard let id, !(id is NSNull) else { return res.send(202) }   // notification
        let chatId = req.header("x-canvas-chat") ?? ""

        func reply(_ result: [String: Any]) { res.json(200, ["jsonrpc": "2.0", "id": id, "result": result]) }
        func text(_ string: String, error: Bool = false) {
            reply(["content": [["type": "text", "text": string]], "isError": error])
        }

        switch msg["method"] as? String {
        case "initialize":
            let asked = (msg["params"] as? [String: Any])?["protocolVersion"] as? String
            reply([
                "protocolVersion": asked ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "canvas-agent", "version": "0.1.0"],
            ])
        case "ping":
            reply([:])
        case "tools/list":
            reply(["tools": tools])
        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let args = params["arguments"] as? [String: Any] ?? [:]
            let name = params["name"] as? String
            Task { @MainActor in
                guard let chat = ClaudeChat.find(chatId) else {
                    if name == "approve" {
                        return text(json(["behavior": "deny", "message": "This chat is no longer open in Canvas."]))
                    }
                    return text("This chat is no longer open in Canvas.", error: true)
                }
                switch name {
                case "approve":
                    let decision = await chat.approve(tool: args["tool_name"] as? String ?? "",
                                                      input: args["input"] as? [String: Any] ?? [:])
                    text(json(decision))
                case "ask_user":
                    guard let question = parseQuestion(args) else {
                        return text("ask_user needs a question and 2–5 options with labels.", error: true)
                    }
                    text(await chat.ask(question))
                default:
                    res.json(200, ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool"]])
                }
            }
        default:
            res.json(200, ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    @MainActor
    private static func parseQuestion(_ args: [String: Any]) -> ClaudeChat.Question? {
        guard let text = args["question"] as? String, !text.isEmpty,
              let raw = args["options"] as? [Any] else { return nil }
        let options: [ClaudeChat.Question.Option] = raw.compactMap { item in
            if let label = item as? String { return .init(label: label, description: nil) }
            guard let dict = item as? [String: Any], let label = dict["label"] as? String else { return nil }
            return .init(label: label, description: dict["description"] as? String)
        }
        guard (2...5).contains(options.count) else { return nil }
        return .init(text: text, options: options, multiSelect: args["multiSelect"] as? Bool ?? false)
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "approve",
            "description": "Canvas's permission check (used by Claude Code itself).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tool_name": ["type": "string"],
                    "input": ["type": "object"],
                    "tool_use_id": ["type": "string"],
                ],
                "required": ["tool_name", "input"],
            ],
        ],
        [
            "name": "ask_user",
            "description": "Ask the user a multiple-choice question in the Canvas chat panel and wait for the answer. Give 2–5 concrete options, the recommended one first with \"(Recommended)\" in its label; the user can also type their own answer.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string"],
                    "options": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["label": ["type": "string"], "description": ["type": "string"]],
                            "required": ["label"],
                        ],
                    ],
                    "multiSelect": ["type": "boolean"],
                ],
                "required": ["question", "options"],
            ],
        ],
    ]
}
