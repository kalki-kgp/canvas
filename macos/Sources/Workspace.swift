import AppKit
import SwiftUI

struct SceneMeta: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var collectionId: String?
    var createdAt: Double
    var updatedAt: Double
    var thumbAt: Double?
    var starred: Bool?

    var isStarred: Bool { starred ?? false }
    var updated: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

struct SceneCollection: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var createdAt: Double
}

private struct IndexFile: Codable {
    var scenes: [SceneMeta]
    var collections: [SceneCollection]
}

enum LibraryFilter: Hashable {
    case all, starred, collection(String)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case slides, history, claude
    var id: String { rawValue }

    var title: String {
        switch self { case .slides: "Slides"; case .history: "History"; case .claude: "Claude" }
    }
    var symbol: String {
        switch self { case .slides: "rectangle.stack"; case .history: "clock.arrow.circlepath"; case .claude: "sparkle" }
    }
}

enum SceneSort: String, CaseIterable {
    case edited, created, name
    var title: String {
        switch self { case .edited: "Last edited"; case .created: "Date created"; case .name: "Name" }
    }
}

enum AppTheme: String {
    case system, light, dark
}

/// The window's state. The page owns the store; this mirrors its index and
/// sends every change back through the page's bridge.
@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var scenes: [SceneMeta] = []
    @Published private(set) var collections: [SceneCollection] = []
    @Published var filter: LibraryFilter = .all
    @Published var search = ""
    @Published var sort: SceneSort = .edited
    @Published private(set) var openSceneId: String?
    @Published var inspector: InspectorTab?
    @Published private(set) var presenting = false
    /// full screen hides the traffic lights and the rounded glass edge
    @Published var isFullScreen = false
    @Published private(set) var appTheme: AppTheme = .system
    /// bumps (debounced) when the open scene's elements change
    @Published private(set) var editTick = 0
    @Published var renamingCollection: String?

    let dataDir: URL
    let claude: ClaudeRunner
    weak var web: WebBridge?
    private var chats: [String: SceneChats] = [:]
    /// scenes with a Claude run in progress, for the toolbar mark
    @Published private(set) var claudeBusyScenes: Set<String> = []
    private var thumbs: [String: (Double, NSImage)] = [:]

    init(dataDir: URL, claude: ClaudeRunner) {
        self.dataDir = dataDir
        self.claude = claude
        if let data = try? Data(contentsOf: dataDir.appendingPathComponent("index.json")),
           let index = try? JSONDecoder().decode(IndexFile.self, from: data) {
            scenes = index.scenes
            collections = index.collections
        }
    }

    var openScene: SceneMeta? { scenes.first { $0.id == openSceneId } }

    var visibleScenes: [SceneMeta] {
        var list = scenes
        switch filter {
        case .all: break
        case .starred: list = list.filter(\.isStarred)
        case .collection(let id): list = list.filter { $0.collectionId == id }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .edited: list.sort { $0.updatedAt > $1.updatedAt }
        case .created: list.sort { $0.createdAt > $1.createdAt }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var filterTitle: String {
        switch filter {
        case .all: "All Scenes"
        case .starred: "Starred"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "Collection"
        }
    }

    func count(_ filter: LibraryFilter) -> Int {
        switch filter {
        case .all: scenes.count
        case .starred: scenes.filter(\.isStarred).count
        case .collection(let id): scenes.filter { $0.collectionId == id }.count
        }
    }

    func thumbnail(for scene: SceneMeta) -> NSImage? {
        guard let stamp = scene.thumbAt else { return nil }
        if let cached = thumbs[scene.id], cached.0 == stamp { return cached.1 }
        let url = dataDir.appendingPathComponent("thumbs/\(scene.id).png")
        guard let image = NSImage(contentsOf: url) else { return nil }
        thumbs[scene.id] = (stamp, image)
        return image
    }

    func chats(for sceneId: String) -> SceneChats {
        if let chats = chats[sceneId] { return chats }
        let created = SceneChats(sceneId: sceneId, workspace: self)
        chats[sceneId] = created
        return created
    }

    /// scenes where a chat is waiting on the user
    @Published private(set) var claudeNeedsYou: Set<String> = []

    func claudeAttentionChanged(in sceneId: String, chat: ClaudeChat) {
        let waiting = chats[sceneId]?.threads.contains { !$0.pending.isEmpty } ?? false
        if waiting { claudeNeedsYou.insert(sceneId) } else { claudeNeedsYou.remove(sceneId) }
        // bring the card into view
        if !chat.pending.isEmpty, openSceneId == sceneId {
            withAnimation(Chrome.panelSlide) {
                if inspector != .claude { inspector = .claude; chats[sceneId]?.open(chat) }
            }
        }
    }

    func claudeRunChanged(in sceneId: String) {
        let busy = chats[sceneId]?.threads.contains(where: \.running) ?? false
        if busy { claudeBusyScenes.insert(sceneId) } else { claudeBusyScenes.remove(sceneId) }
    }

    // MARK: page → window

    func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "index":
            guard let index = message["index"],
                  let data = try? JSONSerialization.data(withJSONObject: index),
                  let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) else { return }
            scenes = decoded.scenes
            collections = decoded.collections
            if case .collection(let id) = filter, !collections.contains(where: { $0.id == id }) {
                filter = .all
            }
        case "route":
            let id = message["sceneId"] as? String
            withAnimation(Chrome.panelSlide) {
                openSceneId = id
                if id == nil { inspector = nil }
            }
        case "presenting":
            presenting = message["on"] as? Bool ?? false
        case "inspector":
            if let tab = (message["tab"] as? String).flatMap(InspectorTab.init(rawValue:)) {
                withAnimation(Chrome.panelSlide) { inspector = tab }
            }
        case "theme":
            appTheme = AppTheme(rawValue: message["appTheme"] as? String ?? "") ?? .system
            let editor = message["editorTheme"] as? String
            NSApp.appearance = appTheme == .system ? nil
                : NSAppearance(named: editor == "dark" ? .darkAqua : .aqua)
        case "changed":
            // the page sends this once an edit settles
            editTick += 1
        default:
            break
        }
    }

    // MARK: window → page

    /// Calls `fn` on the page's bridge; returns its JSON result.
    @discardableResult
    func call(_ fn: String, _ args: Any...) async throws -> Any? {
        guard let web else { throw CanvasError("Canvas is still loading") }
        return try await web.bridge(fn, args)
    }

    /// Fire-and-forget; failures show as an alert.
    func run(_ fn: String, _ args: Any...) {
        Task {
            do {
                guard let web else { return }
                try await web.bridge(fn, args)
            } catch {
                Self.alert(error.localizedDescription)
            }
        }
    }

    func open(_ scene: SceneMeta) { run("open", scene.id) }
    func goHome() { run("home") }

    func newScene() {
        if case .collection(let id) = filter, openSceneId == nil {
            run("newScene", id)
        } else {
            run("newScene", NSNull())
        }
    }

    func newCollection() {
        Task {
            if let id = try? await call("newCollection", "New Collection") as? String {
                filter = .collection(id)
                renamingCollection = id
            }
        }
    }

    func setTheme(_ theme: AppTheme) { run("setTheme", theme.rawValue) }

    func toggleInspector(_ tab: InspectorTab) {
        withAnimation(Chrome.panelSlide) { inspector = inspector == tab ? nil : tab }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "excalidraw"), .init(filenameExtension: "excalidrawlib"), .json]
            .compactMap { $0 }
        guard let window = web?.webView.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.web?.openFiles(panel.urls) }
        }
    }

    func confirmDelete(_ scene: SceneMeta) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(scene.name)”?"
        alert.informativeText = "The scene and its version history will be removed. This can’t be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let window = web?.webView.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.run("remove", scene.id) }
        }
    }

    func confirmDeleteCollection(_ collection: SceneCollection) {
        let alert = NSAlert()
        alert.messageText = "Delete the collection “\(collection.name)”?"
        alert.informativeText = "Its scenes stay in All Scenes."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let window = web?.webView.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.run("deleteCollection", collection.id) }
        }
    }

    static func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        if let window = NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

struct CanvasError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Workspace {
    /// A sheet asking for a name; calls back with the trimmed result.
    func askName(_ title: String, initial: String, confirm: String = "Rename", done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window = web?.webView.window else { return }
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !name.isEmpty { done(name) }
        }
    }

    func rename(_ scene: SceneMeta) {
        askName("Rename Scene", initial: scene.name) { [weak self] in self?.run("rename", scene.id, $0) }
    }
}
