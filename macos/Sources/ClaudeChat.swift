import Foundation
import SwiftUI

/// A chat with Claude Code about one scene. Each message is a `claude -p`
/// run with the canvas MCP tools, resuming the previous run's session.
@MainActor
final class ClaudeChat: ObservableObject {
    enum ToolStatus { case running, done, failed }

    struct Turn: Identifiable {
        enum Kind {
            case user(String)
            case assistant(String)
            case tool(name: String, summary: String, status: ToolStatus)
            case error(String)
        }
        let id: String
        var kind: Kind
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var running = false
    @Published var draft = ""

    let sceneId: String
    private weak var workspace: Workspace?
    private var sessionId: String?
    private var process: Process?
    private var openAssistant: String?
    private var sawResult = false

    static let system = """
    You are the drawing assistant inside Canvas, the user's Excalidraw app on their Mac.
    You work on the scene that is open in the app, using the canvas MCP tools; the user watches the canvas update live.
    Always: get_scene first, draw with add_elements or add_mermaid, then screenshot to check the result and fix problems (overlaps, cramped or cut-off labels, crossing arrows) before finishing.
    Make diagrams clean and readable: consistent sizes, aligned grid, 40–80px gaps, labels inside shapes, arrows bound to shapes, a few soft fill colors.
    Keep your text replies short: one or two sentences about what you did.
    """

    init(sceneId: String, workspace: Workspace) {
        self.sceneId = sceneId
        self.workspace = workspace
    }

    func reset() {
        guard !running else { return }
        turns = []
        sessionId = nil
    }

    func stop() {
        process?.terminate()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running, let workspace else { return }
        draft = ""
        running = true
        openAssistant = nil
        turns.append(Turn(id: UUID().uuidString, kind: .user(text)))

        Task {
            var context = ""
            if let ctx = try? await workspace.call("context") as? [String: Any] {
                context = "Open scene: “\(ctx["name"] as? String ?? "Untitled")”."
                if let selected = ctx["selected"] as? [String], !selected.isEmpty {
                    context += " The user has selected element ids: \(selected.joined(separator: ", "))."
                }
            }
            let request = ClaudeRunner.Request(
                prompt: context.isEmpty ? text : "\(context)\n\n\(text)",
                system: Self.system, mode: "agent", image: nil, sessionId: sessionId, model: nil
            )
            sawResult = false
            do {
                process = try workspace.claude.run(request, onLine: { line in
                    Task { @MainActor [weak self] in
                        if self?.handle(line) == true { self?.sawResult = true }
                    }
                }, onExit: { status, stderr in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !self.sawResult && status != 15 && status != 0 {
                            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.turns.append(Turn(id: UUID().uuidString, kind: .error(
                                detail.isEmpty ? "Claude stopped (exit \(status))" : String(detail.suffix(600)))))
                        }
                        self.finish()
                    }
                })
            } catch {
                turns.append(Turn(id: UUID().uuidString, kind: .error(error.localizedDescription)))
                finish()
            }
        }
    }

    private func finish() {
        running = false
        process = nil
        openAssistant = nil
        for i in turns.indices {
            if case .tool(let name, let summary, .running) = turns[i].kind {
                turns[i].kind = .tool(name: name, summary: summary, status: .failed)
            }
        }
    }

    /// Applies one stream-json line; true for the final result.
    private func handle(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        switch msg["type"] as? String {
        case "system":
            if let id = msg["session_id"] as? String { sessionId = id }
        case "stream_event":
            if let event = msg["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                appendText(text)
            }
        case "assistant":
            let content = (msg["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let name = (block["name"] as? String ?? "").replacingOccurrences(of: "mcp__canvas__", with: "")
                let id = block["id"] as? String ?? UUID().uuidString
                openAssistant = nil
                turns.append(Turn(id: id, kind: .tool(
                    name: name, summary: Self.summary(name, block["input"] as? [String: Any] ?? [:]), status: .running)))
            }
        case "user":
            let content = (msg["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String,
                      let index = turns.firstIndex(where: { $0.id == id }),
                      case .tool(let name, let summary, _) = turns[index].kind else { continue }
                turns[index].kind = .tool(name: name, summary: summary,
                                          status: block["is_error"] as? Bool == true ? .failed : .done)
            }
        case "result":
            if let id = msg["session_id"] as? String { sessionId = id }
            let failed = msg["is_error"] as? Bool == true || msg["subtype"] as? String != "success"
            if failed {
                let text = msg["result"] as? String ?? "Claude couldn’t finish"
                turns.append(Turn(id: UUID().uuidString, kind: .error(text)))
            }
            return true
        default:
            break
        }
        return false
    }

    private func appendText(_ text: String) {
        if let id = openAssistant, let index = turns.firstIndex(where: { $0.id == id }),
           case .assistant(let existing) = turns[index].kind {
            turns[index].kind = .assistant(existing + text)
        } else {
            let id = UUID().uuidString
            openAssistant = id
            turns.append(Turn(id: id, kind: .assistant(text)))
        }
    }

    static func summary(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "add_elements": return "Added \((input["elements"] as? [Any])?.count ?? 0) elements"
        case "update_elements": return "Updated \((input["updates"] as? [Any])?.count ?? 0) elements"
        case "delete_elements": return "Deleted \((input["ids"] as? [Any])?.count ?? 0) elements"
        case "add_mermaid": return "Drew a diagram"
        case "screenshot": return "Looked at the canvas"
        case "get_scene": return "Read the scene"
        case "clear_canvas": return "Cleared the canvas"
        case "zoom_to": return "Moved the view"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
