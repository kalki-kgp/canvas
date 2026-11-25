import Foundation
import SwiftUI

/// All of one scene's chats with Claude, newest first, saved beside the
/// store in `chats/<sceneId>.json`.
@MainActor
final class SceneChats: ObservableObject {
    @Published private(set) var threads: [ClaudeChat] = []
    @Published private(set) var activeId: String

    let sceneId: String
    private weak var workspace: Workspace?
    private let file: URL

    private struct SavedFile: Codable {
        var activeId: String?
        var threads: [ClaudeChat.Saved]
    }

    init(sceneId: String, workspace: Workspace) {
        self.sceneId = sceneId
        self.workspace = workspace
        file = workspace.dataDir.appendingPathComponent("chats/\(sceneId).json")
        activeId = ""
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(SavedFile.self, from: data) {
            threads = saved.threads.map { ClaudeChat(saved: $0, owner: self, workspace: workspace) }
            activeId = saved.activeId.flatMap { id in threads.first { $0.id == id }?.id } ?? threads.first?.id ?? ""
        }
        if threads.isEmpty { newChat() }
    }

    var active: ClaudeChat { threads.first { $0.id == activeId } ?? threads[0] }

    /// Chats other than the open one, most recently used first.
    var others: [ClaudeChat] {
        threads.filter { $0.id != activeId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Opens a fresh chat; an empty open chat is reused instead.
    func newChat() {
        if let current = threads.first(where: { $0.id == activeId }), current.turns.isEmpty { return }
        guard let workspace else { return }
        threads.removeAll { $0.turns.isEmpty && !$0.running }
        let chat = ClaudeChat(owner: self, workspace: workspace)
        threads.insert(chat, at: 0)
        activeId = chat.id
        save()
    }

    func open(_ chat: ClaudeChat) {
        guard chat.id != activeId else { return }
        let leaving = active
        activeId = chat.id
        if leaving.turns.isEmpty && !leaving.running { threads.removeAll { $0.id == leaving.id } }
        save()
    }

    func delete(_ chat: ClaudeChat) {
        chat.stop()
        threads.removeAll { $0.id == chat.id }
        if threads.isEmpty {
            newChat()
        } else if chat.id == activeId {
            activeId = threads.max { $0.updatedAt < $1.updatedAt }!.id
        }
        save()
    }

    func save() {
        let saved = SavedFile(activeId: activeId, threads: threads.filter { !$0.turns.isEmpty }.map(\.saved))
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if saved.threads.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else {
                try JSONEncoder().encode(saved).write(to: file, options: .atomic)
            }
        } catch {
            NSLog("Canvas: couldn't save chats: \(error)")
        }
    }
}

/// One chat with Claude Code about a scene. Each message is a `claude -p`
/// run with the canvas MCP tools, resuming the previous run's session.
extension AgentAccess.Prompt.Kind {
    var isLibrary: Bool { if case .library = self { return true } else { return false } }
}

@MainActor
final class ClaudeChat: ObservableObject, Identifiable {
    enum ToolStatus: String, Codable { case running, done, failed }

    struct Turn: Identifiable, Codable {
        enum Kind: Codable {
            case user(String)
            case assistant(String)
            case tool(name: String, summary: String, status: ToolStatus)
            case error(String)
            /// a permission given or a question answered
            case note(symbol: String, text: String)
        }
        let id: String
        var kind: Kind
    }

    /// what the user allowed for this chat only
    struct Grants: Codable {
        var folders: [String] = []
        var library = false
    }

    struct Saved: Codable {
        let id: String
        var createdAt: Date
        var updatedAt: Date
        var sessionId: String?
        var turns: [Turn]
        var grants: Grants?
    }

    struct Question {
        struct Option: Hashable { let label: String; let description: String? }
        let text: String
        let options: [Option]
        let multiSelect: Bool
    }

    enum Answer {
        case allowOnce, allowChat, allowAlways, deny
        case choices([String])
        case other(String)
        case cancelled
    }

    /// a card waiting for the user above the composer
    struct Pending: Identifiable {
        enum Body {
            case permission(AgentAccess.Prompt)
            case question(Question)
        }
        let id: String
        let body: Body
        let respond: (Answer) -> Void
    }

    /// chats by id, so the agent MCP endpoint can find the one asking
    private static var live: [String: WeakChat] = [:]
    private struct WeakChat { weak var chat: ClaudeChat? }
    static func find(_ id: String) -> ClaudeChat? { live[id]?.chat }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var running = false
    /// what Claude is doing right now, for the working indicator
    @Published private(set) var activity = "Thinking"
    @Published var draft = ""
    @Published private(set) var pending: [Pending] = []
    private(set) var grants = Grants()

    let id: String
    let createdAt: Date
    private(set) var updatedAt: Date
    private weak var owner: SceneChats?
    private weak var workspace: Workspace?
    private var sessionId: String?
    private var process: Process?
    private var openAssistant: String?
    private var sawResult = false

    static func system(_ settings: ChatSettings.Snapshot) -> String {
        var lines = [
            "You are the drawing assistant inside Canvas, the user's Excalidraw app on their Mac.",
            "You work on the scene that is open in the app, using the canvas MCP tools; the user watches the canvas update live.",
            settings.verify
                ? "Always: get_scene first, draw with add_elements or add_mermaid, then screenshot to check the result and fix problems (overlaps, cramped or cut-off labels, crossing arrows) before finishing."
                : "Always: get_scene first, then draw with add_elements or add_mermaid. Don't take screenshots unless the user asks; check layout from get_scene coordinates instead.",
            "Make diagrams clean and readable: consistent sizes, aligned grid, 40–80px gaps, labels inside shapes, arrows bound to shapes, a few soft fill colors.",
            "Keep your text replies short: one or two sentences about what you did.",
        ]
        if settings.filesAndWeb {
            lines += [
                "",
                "You can read the user's files and search the web to understand what to draw: Read, Glob, Grep, and read-only shell commands (ls, cat, find, grep, git log/show/diff…). You can never change files. Always use absolute paths.",
                "The first time you touch a folder, Canvas asks the user; if they say no, don't try again, carry on without it or ask what they'd prefer.",
            ]
        } else {
            lines += ["", "You can't read the user's files or the web in this chat (they turned it off); work from what they tell you."]
        }
        lines.append(settings.ask
            ? "When you're unsure what the user wants (scope, level of detail, style, which parts to include), call ask_user with 2–4 concrete options, your recommended one first with \"(Recommended)\" in its label. Don't ask about things you can decide sensibly yourself."
            : "Don't ask the user questions; make sensible choices yourself and mention them briefly.")
        lines.append("If shapes from the user's library could fit (servers, databases, cloud services, devices, UI parts), call list_library: Canvas asks the user whether to use the library, and if they decline, draw plain shapes.")
        return lines.joined(separator: "\n")
    }

    init(owner: SceneChats, workspace: Workspace) {
        id = UUID().uuidString
        createdAt = Date()
        updatedAt = createdAt
        self.owner = owner
        self.workspace = workspace
        Self.live[id] = WeakChat(chat: self)
    }

    init(saved: Saved, owner: SceneChats, workspace: Workspace) {
        id = saved.id
        createdAt = saved.createdAt
        updatedAt = saved.updatedAt
        sessionId = saved.sessionId
        // a run cut off by quitting never finished its tools
        turns = saved.turns.map { turn in
            guard case .tool(let name, let summary, .running) = turn.kind else { return turn }
            return Turn(id: turn.id, kind: .tool(name: name, summary: summary, status: .failed))
        }
        grants = saved.grants ?? Grants()
        self.owner = owner
        self.workspace = workspace
        Self.live[id] = WeakChat(chat: self)
    }

    var saved: Saved {
        Saved(id: id, createdAt: createdAt, updatedAt: updatedAt, sessionId: sessionId, turns: turns, grants: grants)
    }

    /// The first thing the user asked, as the chat's name.
    var title: String {
        for turn in turns {
            if case .user(let text) = turn.kind {
                return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            }
        }
        return "New chat"
    }

    var toolCount: Int {
        turns.reduce(0) { count, turn in
            if case .tool = turn.kind { return count + 1 }
            return count
        }
    }

    func stop() {
        process?.terminate()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running, let workspace else { return }
        draft = ""
        running = true
        activity = "Thinking"
        openAssistant = nil
        updatedAt = Date()
        turns.append(Turn(id: UUID().uuidString, kind: .user(text)))
        owner?.save()
        if let owner { workspace.claudeRunChanged(in: owner.sceneId) }

        Task {
            var context = ""
            if let ctx = try? await workspace.call("context") as? [String: Any] {
                context = "Open scene: “\(ctx["name"] as? String ?? "Untitled")”."
                if let selected = ctx["selected"] as? [String], !selected.isEmpty {
                    context += " The user has selected element ids: \(selected.joined(separator: ", "))."
                }
            }
            let settings = ChatSettings.current
            var request = ClaudeRunner.Request(
                prompt: context.isEmpty ? text : "\(context)\n\n\(text)",
                system: Self.system(settings), mode: "agent", image: nil, sessionId: sessionId,
                model: settings.model, chatId: id
            )
            request.effort = settings.effort
            request.readFiles = settings.filesAndWeb
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

    // MARK: permission & questions (from the agent MCP endpoint)

    /// Decides a Claude Code permission request, asking the user when needed.
    /// Returns the permission tool's reply.
    func approve(tool: String, input: [String: Any]) async -> [String: Any] {
        while true {
            switch AgentAccess.decide(tool: tool, input: input, chat: self) {
            case .allow:
                return ["behavior": "allow", "updatedInput": input]
            case .deny(let reason):
                note("hand.raised", reason)
                return ["behavior": "deny", "message": reason]
            case .ask(let prompt):
                let answer = await waitForUser(.permission(prompt))
                switch (prompt.kind, answer) {
                case (.folder(let folder), .allowChat):
                    grants.folders.append(folder)
                    note("folder", "Allowed reading \(AgentAccess.pretty(folder)) in this chat")
                case (.folder(let folder), .allowAlways):
                    AgentAccess.alwaysFolders.append(folder)
                    note("folder", "Always allowed reading \(AgentAccess.pretty(folder))")
                case (.library, .allowChat):
                    grants.library = true
                    note("books.vertical", "Allowed your library in this chat")
                case (.library, .allowAlways):
                    AgentAccess.alwaysLibrary = true
                    note("books.vertical", "Always allowed your library")
                case (.command, .allowOnce), (.command, .allowChat):
                    note("terminal", "Allowed: \(prompt.detail)")
                    return ["behavior": "allow", "updatedInput": input]
                case (_, .cancelled):
                    return ["behavior": "deny", "message": "The run was stopped."]
                default:
                    let what: String
                    switch prompt.kind {
                    case .folder(let folder): what = "reading \(AgentAccess.pretty(folder))"
                    case .library: what = "using the library"
                    case .command: what = "running that command"
                    }
                    note("hand.raised", "Declined \(what)")
                    let hint = prompt.kind.isLibrary ? " Draw with plain shapes instead." : " Don't retry; continue without it or ask the user."
                    return ["behavior": "deny", "message": "The user declined \(what).\(hint)"]
                }
                owner?.save()
            }
        }
    }

    /// Shows a multiple-choice question; returns the answer as text for Claude.
    func ask(_ question: Question) async -> String {
        switch await waitForUser(.question(question)) {
        case .choices(let labels):
            note("checkmark.bubble", labels.joined(separator: ", "))
            return "The user chose: \(labels.joined(separator: "; "))"
        case .other(let text):
            note("checkmark.bubble", text)
            return "The user answered: \(text)"
        case .cancelled:
            return "The user stopped the run before answering."
        default:
            note("checkmark.bubble", "Skipped")
            return "The user skipped the question; use your best judgment."
        }
    }

    private func waitForUser(_ body: Pending.Body) async -> Answer {
        guard running else { return .cancelled }
        return await withCheckedContinuation { continuation in
            let cardId = UUID().uuidString
            var answered = false
            let card = Pending(id: cardId, body: body) { [weak self] answer in
                guard !answered else { return }   // a double click answers once
                answered = true
                continuation.resume(returning: answer)
                self?.pending.removeAll { $0.id == cardId }
                self?.attentionChanged()
            }
            withAnimation(Chrome.panelSlide) { pending.append(card) }
            attentionChanged()
        }
    }

    private func attentionChanged() {
        guard let owner else { return }
        workspace?.claudeAttentionChanged(in: owner.sceneId, chat: self)
    }

    private func note(_ symbol: String, _ text: String) {
        turns.append(Turn(id: UUID().uuidString, kind: .note(symbol: symbol, text: text)))
    }

    private func finish() {
        for card in pending { card.respond(.cancelled) }
        pending = []
        running = false
        process = nil
        openAssistant = nil
        updatedAt = Date()
        for i in turns.indices {
            if case .tool(let name, let summary, .running) = turns[i].kind {
                turns[i].kind = .tool(name: name, summary: summary, status: .failed)
            }
        }
        owner?.save()
        if let owner { workspace?.claudeRunChanged(in: owner.sceneId) }
    }

    /// Applies one stream-json line; true for the final result.
    private func handle(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        switch msg["type"] as? String {
        case "system":
            if let id = msg["session_id"] as? String { sessionId = id }
        case "stream_event":
            guard let event = msg["event"] as? [String: Any] else { break }
            if event["type"] as? String == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "thinking" {
                activity = "Thinking"
            }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                activity = "Writing"
                appendText(text)
            }
        case "assistant":
            let content = (msg["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let name = (block["name"] as? String ?? "").replacingOccurrences(of: "mcp__canvas__", with: "")
                let id = block["id"] as? String ?? UUID().uuidString
                openAssistant = nil
                activity = Self.activity(name)
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
            activity = "Thinking"
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

    static func activity(_ name: String) -> String {
        switch name {
        case "add_elements", "add_mermaid": return "Drawing"
        case "update_elements": return "Adjusting"
        case "delete_elements", "clear_canvas": return "Tidying up"
        case "screenshot": return "Looking at the canvas"
        case "get_scene": return "Reading the scene"
        case "zoom_to": return "Moving the view"
        default: return "Working"
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

/// The chat settings under the composer, kept in UserDefaults.
enum ChatSettings {
    static let modelKey = "claudeModel"
    static let effortKey = "claudeEffort"
    static let filesKey = "claudeFilesAndWeb"
    static let askKey = "claudeAskWhenUnsure"
    static let verifyKey = "claudeVerifyScreenshots"

    struct Choice: Identifiable { let id: String; let name: String; let note: String }

    static let models = [
        Choice(id: "sonnet", name: "Sonnet", note: "Fast and smart, for most drawings"),
        Choice(id: "opus", name: "Opus", note: "For big diagrams and system designs"),
        Choice(id: "fable", name: "Fable", note: "Most capable, takes longer"),
        Choice(id: "haiku", name: "Haiku", note: "Quickest, for small edits"),
    ]
    static let defaultModel = "sonnet"

    static let efforts = [
        Choice(id: "low", name: "Low", note: "Answers fast with little thinking."),
        Choice(id: "medium", name: "Medium", note: "Thinks enough for most drawings."),
        Choice(id: "high", name: "High", note: "Plans the layout more carefully."),
        Choice(id: "xhigh", name: "Extra High", note: "Careful and slower."),
        Choice(id: "max", name: "Max", note: "Thinks as long as it needs."),
    ]
    static let defaultEffort = "medium"

    struct Snapshot {
        let model: String
        let effort: String
        let filesAndWeb: Bool
        let ask: Bool
        let verify: Bool
    }

    static var current: Snapshot {
        let d = UserDefaults.standard
        let model = d.string(forKey: modelKey).flatMap { id in models.contains { $0.id == id } ? id : nil } ?? defaultModel
        let effort = d.string(forKey: effortKey).flatMap { id in efforts.contains { $0.id == id } ? id : nil } ?? defaultEffort
        return Snapshot(model: model, effort: effort,
                        filesAndWeb: d.object(forKey: filesKey) as? Bool ?? true,
                        ask: d.object(forKey: askKey) as? Bool ?? true,
                        verify: d.object(forKey: verifyKey) as? Bool ?? true)
    }
}
