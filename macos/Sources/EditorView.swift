import AppKit
import SwiftUI
import WebKit

/// Hosts the one WKWebView; it stays in the window the whole time so the
/// page (and MCP) keep running while the library is showing.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct EditorView: View {
    @ObservedObject var ws: Workspace
    let webView: WKWebView

    var body: some View {
        let presenting = ws.presenting
        VStack(spacing: 0) {
            if !presenting {
                EditorBar(ws: ws)
            }
            HStack(spacing: 10) {
                WebViewHost(webView: webView)
                    .clipShape(RoundedRectangle(cornerRadius: presenting ? 0 : 14, style: .continuous))
                    .overlay {
                        if !presenting {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Chrome.overlay(0.08), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                    }
                if let tab = ws.inspector, !presenting, let sceneId = ws.openSceneId {
                    InspectorPanel(ws: ws, tab: tab, sceneId: sceneId)
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, presenting ? 0 : 10)
            .padding(.bottom, presenting ? 0 : 10)
        }
    }
}

private struct EditorBar: View {
    @ObservedObject var ws: Workspace

    var body: some View {
        HStack(spacing: 8) {
            if !ws.isFullScreen {
                Color.clear.frame(width: 70)   // traffic lights
            }
            ChromeCircleButton(symbol: "chevron.left", help: "All Scenes (⇧⌘H)") { ws.goHome() }
            Text(verbatim: ws.openScene?.name ?? "")
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .padding(.leading, 4)
                .onTapGesture(count: 2) { if let scene = ws.openScene { ws.rename(scene) } }
                .help("Double-click to rename")
            Spacer(minLength: 12)
            ChromeTextButton(symbol: "play.fill", title: "Present", help: "Present frames as slides (⌥⌘P)") {
                ws.run("present", 0)
            }
            ChromeTextMenu(symbol: "square.and.arrow.up", title: "Export", help: "Export") {
                PopoverItem("Image…") { ws.run("exportImage") }
                PopoverItem("Excalidraw File…") { if let id = ws.openSceneId { ws.run("exportFile", id) } }
                PopoverItem("Slides as PDF…") { exportPDF() }
            }
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases) { tab in
                    InspectorToggle(tab: tab, isOn: ws.inspector == tab) { ws.toggleInspector(tab) }
                }
            }
            .padding(2)
            .chromeGlassCapsule()
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    private func exportPDF() {
        Task {
            do {
                let saved = try await ws.call("exportPDF") as? Bool
                if saved == false, ws.inspector != .slides {
                    // nothing to export without frames: show where slides come from
                    withAnimation(Chrome.panelSlide) { ws.inspector = .slides }
                }
            } catch {
                Workspace.alert(error.localizedDescription)
            }
        }
    }
}

private struct InspectorToggle: View {
    let tab: InspectorTab
    let isOn: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(Chrome.iconFont)
                .foregroundStyle(isOn ? Chrome.accent : Chrome.primaryText.opacity(isHovering ? 1 : 0.85))
                .frame(width: 30, height: Chrome.capsuleContentHeight)
                .background {
                    Capsule(style: .continuous).fill(isOn ? Chrome.overlay(0.12) : isHovering ? Chrome.overlay(0.06) : .clear)
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
        .help(tab.title)
    }
}

// MARK: - Inspector

private struct InspectorPanel: View {
    @ObservedObject var ws: Workspace
    let tab: InspectorTab
    let sceneId: String

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch tab {
                case .slides: SlidesPanel(ws: ws)
                case .history: HistoryPanel(ws: ws)
                case .claude: ClaudePanel(ws: ws, chat: ws.chat(for: sceneId))
                }
            }
            .id("\(tab.rawValue)-\(sceneId)")
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.22))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(verbatim: title).font(.system(size: 15, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }
}

private extension NSImage {
    static func fromDataURL(_ string: String?) -> NSImage? {
        guard let string, let comma = string.firstIndex(of: ","),
              let data = Data(base64Encoded: String(string[string.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: Slides

private struct SlidesPanel: View {
    @ObservedObject var ws: Workspace

    struct Slide: Identifiable, Equatable {
        let id: String
        let name: String
        let thumb: NSImage?
    }

    @State private var slides: [Slide] = []
    @State private var loaded = false
    @State private var exporting = false
    @State private var dragging: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Slides") {
                if !slides.isEmpty {
                    ChromeTextButton(symbol: exporting ? "hourglass" : "doc.richtext", title: "PDF",
                                     help: "Export the slides as a PDF", isEnabled: !exporting) { exportPDF() }
                }
            }
            if loaded && slides.isEmpty {
                VStack(spacing: 12) {
                    Text(verbatim: "No frames yet")
                        .font(.system(size: 13))
                        .foregroundStyle(Chrome.secondaryText)
                    ChromeTextButton(symbol: "rectangle.dashed", title: "Add Frame", help: "Draw a frame (F)") {
                        ws.run("addFrame")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                            SlideRow(index: index, slide: slide, count: slides.count,
                                     present: { ws.run("present", index) },
                                     move: { move(slide.id, to: $0) })
                                .opacity(dragging == slide.id ? 0.4 : 1)
                                .draggable(slide.id) {
                                    Text(verbatim: slide.name).padding(6).onAppear { dragging = slide.id }
                                }
                                .dropDestination(for: String.self) { ids, _ in
                                    dragging = nil
                                    guard let id = ids.first else { return false }
                                    move(id, to: index)
                                    return true
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            }
        }
        .task(id: ws.editTick) { await load() }
    }

    private func load() async {
        guard let list = try? await ws.call("slides", 360) as? [[String: Any]] else {
            loaded = true
            return
        }
        slides = list.map {
            Slide(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "",
                  thumb: NSImage.fromDataURL($0["thumb"] as? String))
        }
        loaded = true
    }

    private func move(_ id: String, to index: Int) {
        guard let from = slides.firstIndex(where: { $0.id == id }) else { return }
        var next = slides
        let item = next.remove(at: from)
        next.insert(item, at: min(max(index, 0), next.count))
        withAnimation(Chrome.panelSlide) { slides = next }
        ws.run("setSlideOrder", next.map(\.id))
    }

    private func exportPDF() {
        exporting = true
        Task {
            do { try await ws.call("exportPDF") } catch { Workspace.alert(error.localizedDescription) }
            exporting = false
        }
    }
}

private struct SlideRow: View {
    let index: Int
    let slide: SlidesPanel.Slide
    let count: Int
    let present: () -> Void
    let move: (Int) -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                shape.fill(colorScheme == .dark ? Color(white: 0.12) : .white)
                if let thumb = slide.thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(verbatim: "\(index + 1)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .padding(6)
                if isHovering {
                    ChromeCircleButton(symbol: "play.fill", help: "Present from this slide", action: present)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Chrome.overlay(0.08), lineWidth: 0.5) }
            Text(verbatim: slide.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isHovering ? Chrome.overlay(0.06) : .clear))
        .contentShape(.rect)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
        .onTapGesture(count: 2, perform: present)
        .contextMenu {
            Button("Present from Here", action: present)
            Divider()
            Button("Move Up") { move(index - 1) }.disabled(index == 0)
            Button("Move Down") { move(index + 1) }.disabled(index == count - 1)
        }
    }
}

// MARK: History

private struct HistoryPanel: View {
    @ObservedObject var ws: Workspace

    struct Version: Identifiable, Hashable {
        let name: String
        let savedAt: Date
        let label: String?
        var id: String { name }
    }

    @State private var versions: [Version] = []
    @State private var selected: Version?
    @State private var preview: NSImage?
    @State private var label = ""
    @State private var saving = false
    @State private var loaded = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "History") { EmptyView() }
            HStack(spacing: 8) {
                TextField("Version name", text: $label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 12)
                    .frame(height: Chrome.capsuleHeight)
                    .background(Capsule(style: .continuous).fill(Chrome.overlay(0.06)))
                    .onSubmit(save)
                ChromeTextButton(symbol: "checkmark", title: "Save", help: "Save this state as a version", isEnabled: !saving, action: save)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if let selected {
                previewCard(selected)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(days, id: \.0) { day, items in
                        Text(verbatim: day)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(items) { version in
                            VersionRow(version: version, isSelected: selected == version) { select(version) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .overlay {
                if loaded && versions.isEmpty {
                    Text(verbatim: "No versions yet").font(.system(size: 13)).foregroundStyle(Chrome.secondaryText)
                }
            }
        }
        .task(id: ws.editTick) { await load() }
    }

    private var days: [(String, [Version])] {
        let calendar = Calendar.current
        var out: [(String, [Version])] = []
        for version in versions {
            let title: String
            if calendar.isDateInToday(version.savedAt) { title = "Today" }
            else if calendar.isDateInYesterday(version.savedAt) { title = "Yesterday" }
            else { title = version.savedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if out.last?.0 == title { out[out.count - 1].1.append(version) } else { out.append((title, [version])) }
        }
        return out
    }

    private func previewCard(_ version: Version) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                shape.fill(colorScheme == .dark ? Color(white: 0.07) : .white)
                if let preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(shape)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: version.label ?? version.savedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(verbatim: version.savedAt.formatted(date: .abbreviated, time: version.label == nil ? .omitted : .shortened))
                        .font(.system(size: 11)).foregroundStyle(Chrome.secondaryText)
                }
                Spacer()
                ChromeTextButton(symbol: "arrow.uturn.backward", title: "Restore", help: "Make this the current state (undo with ⌘Z)") {
                    restore(version)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Chrome.overlay(0.05)))
        .padding(.horizontal, 12)
        .transition(.softAppear)
    }

    private func load() async {
        guard let list = try? await ws.call("snapshots") as? [[String: Any]] else { loaded = true; return }
        versions = list.map {
            Version(name: $0["name"] as? String ?? "",
                    savedAt: Date(timeIntervalSince1970: ($0["savedAt"] as? Double ?? 0) / 1000),
                    label: $0["label"] as? String)
        }
        if let selected, !versions.contains(selected) { self.selected = nil }
        loaded = true
    }

    private func select(_ version: Version) {
        withAnimation(Chrome.panelSlide) {
            if selected == version { selected = nil; return }
            selected = version
            preview = nil
        }
        Task {
            let url = try? await ws.call("previewSnapshot", version.name, 720) as? String
            if selected == version { preview = NSImage.fromDataURL(url) }
        }
    }

    private func save() {
        saving = true
        let name = label.trimmingCharacters(in: .whitespaces)
        Task {
            do { try await ws.call("saveVersion", name) } catch { Workspace.alert(error.localizedDescription) }
            label = ""
            saving = false
            await load()
        }
    }

    private func restore(_ version: Version) {
        Task {
            do {
                try await ws.call("restoreSnapshot", version.name)
                withAnimation(Chrome.panelSlide) { selected = nil }
                await load()
            } catch {
                Workspace.alert(error.localizedDescription)
            }
        }
    }
}

private struct VersionRow: View {
    let version: HistoryPanel.Version
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(version.savedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Chrome.primaryText.opacity(0.9))
                if let label = version.label {
                    Text(verbatim: label)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Chrome.overlay(0.12) : isHovering ? Chrome.overlay(0.06) : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
}

// MARK: Claude

private struct ClaudePanel: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var chat: ClaudeChat
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Claude") {
                if !chat.turns.isEmpty && !chat.running {
                    ChromeCircleButton(symbol: "square.and.pencil", help: "New Chat") { chat.reset() }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.turns) { turn in
                            TurnView(turn: turn).id(turn.id)
                        }
                        if chat.running, !(chat.turns.last.map(isStreamingText) ?? false) {
                            ProgressView().controlSize(.small).padding(.leading, 4).id("working")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .onChange(of: chat.turns.count) { _, _ in
                    withAnimation { proxy.scrollTo(chat.running ? "working" : chat.turns.last?.id, anchor: .bottom) }
                }
            }
            composer
        }
        .onAppear {
            // the web view holds keyboard focus; hand it to the composer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                ws.web?.webView.window?.makeFirstResponder(nil)
                focused = true
            }
        }
    }

    private func isStreamingText(_ turn: ClaudeChat.Turn) -> Bool {
        if case .assistant = turn.kind { return true }
        return false
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Claude to draw…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { chat.send() }
                .padding(.vertical, 8)
            Button {
                chat.running ? chat.stop() : chat.send()
            } label: {
                Image(systemName: chat.running ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(canSend || chat.running ? Chrome.accent : Chrome.overlay(0.2)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !chat.running)
            .padding(.bottom, 4)
            .help(chat.running ? "Stop" : "Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Chrome.overlay(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Chrome.overlay(0.08), lineWidth: 0.5))
        .padding(10)
    }

    private var canSend: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct TurnView: View {
    let turn: ClaudeChat.Turn

    var body: some View {
        switch turn.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Chrome.overlay(0.1)))
            }
        case .assistant(let text):
            Text(markdown(text))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .tool(_, let summary, let status):
            HStack(spacing: 7) {
                Group {
                    switch status {
                    case .running: ProgressView().controlSize(.mini)
                    case .done: Image(systemName: "checkmark").foregroundStyle(Chrome.secondaryText)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Chrome.warning)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                Text(verbatim: summary).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
            }
        case .error(let text):
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(Chrome.danger)
                .textSelection(.enabled)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
