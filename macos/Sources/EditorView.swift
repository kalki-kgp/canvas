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
                    InspectorToggle(tab: tab, isOn: ws.inspector == tab,
                                    working: tab == .claude && ws.openSceneId.map(ws.claudeBusyScenes.contains) == true,
                                    needsYou: tab == .claude && ws.openSceneId.map(ws.claudeNeedsYou.contains) == true) {
                        ws.toggleInspector(tab)
                    }
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
    var working = false
    var needsYou = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if tab == .claude {
                    ClaudeMark(size: 15, working: working, tinted: isOn)
                } else {
                    Image(systemName: tab.symbol).font(Chrome.iconFont)
                }
            }
                .foregroundStyle(isOn ? Chrome.accent : Chrome.primaryText.opacity(isHovering ? 1 : 0.85))
                .frame(width: 30, height: Chrome.capsuleContentHeight)
                .background {
                    Capsule(style: .continuous).fill(isOn ? Chrome.overlay(0.12) : isHovering ? Chrome.overlay(0.06) : .clear)
                }
                .contentShape(Capsule(style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if needsYou {
                        Circle().fill(ClaudeMark.orange).frame(width: 7, height: 7)
                            .offset(x: -3, y: 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
        .help(needsYou ? "Claude is waiting for you" : tab.title)
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
                case .claude: ClaudePanel(ws: ws, chats: ws.chats(for: sceneId))
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
    @ObservedObject var chats: SceneChats

    var body: some View {
        let others = chats.others
        VStack(spacing: 0) {
            PanelHeader(title: "Claude") {
                ChromeCircleButton(symbol: "square.and.pencil", help: "New Chat") {
                    withAnimation(Chrome.panelSlide) { chats.newChat() }
                }
            }
            if !others.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(others) { chat in
                            ChatRow(chat: chat,
                                    open: { withAnimation(Chrome.panelSlide) { chats.open(chat) } },
                                    delete: { withAnimation(Chrome.panelSlide) { chats.delete(chat) } })
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: min(CGFloat(others.count) * 38 + 4, 156))
                .fixedSize(horizontal: false, vertical: true)
                Divider().padding(.horizontal, 14).padding(.vertical, 6)
            }
            ChatThreadView(ws: ws, chat: chats.active,
                           delete: others.isEmpty ? nil : { withAnimation(Chrome.panelSlide) { chats.delete(chats.active) } })
                .id(chats.activeId)
                .transition(.opacity)
        }
    }
}

/// A chat that isn't open, collapsed to one row.
private struct ChatRow: View {
    @ObservedObject var chat: ClaudeChat
    let open: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                ClaudeMark(size: 12, working: chat.running)
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: chat.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Group {
                        if !chat.pending.isEmpty {
                            Text("Waiting for you").foregroundStyle(ClaudeMark.orange)
                        } else if chat.running {
                            ShimmerText(text: "\(chat.activity)…", size: 10.5)
                        } else {
                            Text(chat.updatedAt, format: .relative(presentation: .named))
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Chrome.secondaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(Chrome.chevronFont)
                    .foregroundStyle(Chrome.secondaryText)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHovering ? Chrome.overlay(0.07) : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
        .contextMenu {
            Button("Open") { open() }
            Divider()
            Button("Delete Chat", role: .destructive) { delete() }
        }
        .help(chat.title)
    }
}

/// The open chat: transcript, working indicator and composer.
private struct ChatThreadView: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var chat: ClaudeChat
    let delete: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let delete, !chat.turns.isEmpty {
                HStack(spacing: 6) {
                    Text(verbatim: chat.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    Menu {
                        Button("Delete Chat", role: .destructive) { delete() }
                    } label: {
                        Image(systemName: "ellipsis").font(Chrome.inlineIconFont)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(Chrome.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.turns.isEmpty {
                            EmptyChat().padding(.top, 40)
                        }
                        ForEach(chat.turns) { turn in
                            TurnView(turn: turn)
                                .id(turn.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                        if chat.running && chat.pending.isEmpty {
                            WorkingIndicator(activity: chat.activity)
                                .id("working")
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                        }
                        // a permission or a question arrives as the newest
                        // item of the chat, which glides up to make room
                        if let card = chat.pending.first {
                            PendingCard(card: card)
                                .id(card.id)
                                .padding(.top, 2)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 10)),
                                    removal: .opacity))
                        }
                    }
                    .animation(Chrome.panelSlide, value: chat.turns.count)
                    .animation(Chrome.panelSlide, value: chat.running)
                    .animation(Chrome.panelSlide, value: chat.pending.first?.id)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                // keep the newest message in place when the space shrinks
                // (a card or a taller composer): the chat glides up with it
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onAppear { proxy.scrollTo(chat.turns.last?.id, anchor: .bottom) }
                .onChange(of: chat.turns.count) { _, _ in scrollDown(proxy) }
                .onChange(of: chat.activity) { _, _ in scrollDown(proxy) }
                .onChange(of: chat.pending.first?.id) { _, _ in
                    // once the card has its height, so it lands fully in view
                    DispatchQueue.main.async { scrollDown(proxy) }
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

    private func scrollDown(_ proxy: ScrollViewProxy) {
        let target: String? = chat.pending.first?.id ?? (chat.running ? "working" : chat.turns.last?.id)
        withAnimation(Chrome.panelSlide) { proxy.scrollTo(target, anchor: .bottom) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Ask Claude to draw…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { chat.send() }
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 6)
            HStack(spacing: 6) {
                OptionsMenu()
                Spacer(minLength: 0)
                ModelMenu()
                Button {
                    chat.running ? chat.stop() : chat.send()
                } label: {
                    Image(systemName: chat.running ? "stop.fill" : "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(canSend || chat.running ? ClaudeMark.orange : Chrome.overlay(0.16)))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !chat.running)
                .help(chat.running ? "Stop" : "Send")
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Chrome.overlay(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Chrome.overlay(0.09), lineWidth: 0.5))
        .overlay { if chat.running { WorkingGlow(cornerRadius: 18) } }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .padding(10)
    }

    private var canSend: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// "Sonnet Medium ⌄": model and effort for the next message.
private struct ModelMenu: View {
    @AppStorage(ChatSettings.modelKey) private var model = ChatSettings.defaultModel
    @AppStorage(ChatSettings.effortKey) private var effort = ChatSettings.defaultEffort
    @State private var isHovering = false
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 5) {
                ClaudeMark(size: 10).foregroundStyle(Chrome.secondaryText)
                Text(verbatim: name(ChatSettings.models, model, "Sonnet"))
                    .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 0.95 : 0.8))
                Text(verbatim: name(ChatSettings.efforts, effort, "Medium"))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.8))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule(style: .continuous).fill(isHovering || isPresented ? Chrome.overlay(0.08) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
        .help("Model and effort")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                PopoverSectionHeader("Model")
                ForEach(ChatSettings.models) { option in
                    ChoiceRow(title: option.name, note: option.note, isSelected: option.id == model) {
                        withAnimation(Chrome.hover) { model = option.id }
                    }
                }
                Divider().padding(.horizontal, 8).padding(.vertical, 6)
                PopoverSectionHeader("Effort")
                EffortPicker(selection: $effort)
                    .padding(.horizontal, 6)
                Text(verbatim: ChatSettings.efforts.first { $0.id == effort }?.note ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .contentTransition(.opacity)
            }
            .padding(8)
            .frame(width: 270)
        }
        .onAppear {
            if !ChatSettings.models.contains(where: { $0.id == model }) { model = ChatSettings.defaultModel }
            if !ChatSettings.efforts.contains(where: { $0.id == effort }) { effort = ChatSettings.defaultEffort }
        }
    }

    private func name(_ list: [ChatSettings.Choice], _ id: String, _ fallback: String) -> String {
        list.first { $0.id == id }?.name ?? fallback
    }
}

/// A row with a title, a quiet note and a check when chosen.
private struct ChoiceRow: View {
    let title: String
    let note: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(.system(size: 13, weight: .medium))
                    Text(verbatim: note).font(.system(size: 11)).foregroundStyle(Chrome.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ClaudeMark.orange)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Chrome.overlay(0.08) : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
}

/// Five effort levels as one segmented strip with a sliding highlight.
private struct EffortPicker: View {
    @Binding var selection: String
    @Namespace private var highlight
    @State private var hovered: String?

    private static let short = ["low": "Low", "medium": "Med", "high": "High", "xhigh": "XHigh", "max": "Max"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ChatSettings.efforts) { option in
                let isSelected = option.id == selection
                Button {
                    withAnimation(Chrome.panelSlide) { selection = option.id }
                } label: {
                    Text(verbatim: Self.short[option.id] ?? option.name)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 1 : 0.65))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Chrome.overlay(0.14))
                                    .matchedGeometryEffect(id: "effort", in: highlight)
                            } else if hovered == option.id {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Chrome.overlay(0.05))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(Chrome.hover) { hovered = h ? option.id : nil } }
                .help(option.name)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.05)))
    }
}

/// What Claude may do: files & web, questions, screenshots, and access granted for good.
private struct OptionsMenu: View {
    @AppStorage(ChatSettings.filesKey) private var filesAndWeb = true
    @AppStorage(ChatSettings.askKey) private var askWhenUnsure = true
    @AppStorage(ChatSettings.verifyKey) private var verify = true
    @AppStorage(AgentAccess.alwaysLibraryKey) private var library = false
    @State private var folders: [String] = []
    @State private var isHovering = false
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 0.9 : 0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(isHovering || isPresented ? Chrome.overlay(0.08) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
        .help("Chat options")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                PopoverSectionHeader("Claude can")
                SwitchRow(symbol: "folder", title: "Read files & web",
                          note: "Read-only, asks per folder.", isOn: $filesAndWeb)
                SwitchRow(symbol: "questionmark.bubble", title: "Ask when unsure",
                          note: "Offers choices, never guesses.", isOn: $askWhenUnsure)
                SwitchRow(symbol: "eye", title: "Check with screenshots",
                          note: "Catches overlaps, a bit slower.", isOn: $verify)
                SwitchRow(symbol: "books.vertical", title: "Library without asking",
                          note: "Skips the library question.", isOn: $library)
                if !folders.isEmpty {
                    Divider().padding(.horizontal, 8).padding(.vertical, 6)
                    PopoverSectionHeader("Always allowed")
                    ForEach(folders, id: \.self) { folder in
                        FolderRow(path: AgentAccess.pretty(folder)) {
                            withAnimation(Chrome.panelSlide) {
                                AgentAccess.alwaysFolders = folders.filter { $0 != folder }
                                folders = AgentAccess.alwaysFolders
                            }
                        }
                    }
                }
            }
            .padding(8)
            .frame(width: 300)
            .onAppear { folders = AgentAccess.alwaysFolders }
        }
    }
}

private struct SwitchRow: View {
    let symbol: String
    let title: String
    let note: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(ClaudeMark.orange)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { withAnimation(Chrome.hover) { isOn.toggle() } }
    }
}

private struct FolderRow: View {
    let path: String
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 18)
            Text(verbatim: path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Chrome.overlay(0.08)))
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.5)
            .help("Stop always allowing this folder")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? Chrome.overlay(0.06) : .clear))
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
}

private struct EmptyChat: View {
    var body: some View {
        VStack(spacing: 10) {
            ClaudeMark(size: 28, tinted: true)
            Text("Ask Claude to draw a diagram, tidy this scene or turn a sketch into something clean.")
                .font(.system(size: 12))
                .foregroundStyle(Chrome.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

/// Claude's mark turning beside a shimmering line about what it's doing.
private struct WorkingIndicator: View {
    let activity: String

    var body: some View {
        HStack(spacing: 8) {
            ClaudeMark(size: 16, working: true)
            ShimmerText(text: "\(activity)…", size: 12.5, weight: .medium)
        }
        .padding(.leading, 2)
        .padding(.vertical, 2)
    }
}

/// Text with a light band sweeping across it (Core Animation, so it costs
/// the app nothing per frame).
private struct ShimmerText: View {
    let text: String
    var size: CGFloat
    var weight: NSFont.Weight = .regular

    var body: some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Text(verbatim: text)
                .font(.system(size: size, weight: Font.Weight(weight)))
                .foregroundStyle(Chrome.secondaryText)
        } else {
            ShimmerLabel(text: text, font: .systemFont(ofSize: size, weight: weight))
        }
    }
}

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        self = weight == .medium ? .medium : weight == .semibold ? .semibold : .regular
    }
}

/// A soft orange light running around the composer while Claude works.
private struct WorkingGlow: View {
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ClaudeMark.orange.opacity(0.6), lineWidth: 1.5)
            } else {
                RunningGlow(cornerRadius: cornerRadius)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}


// MARK: Claude: cards & access

/// Claude is waiting: a permission to give or a question to answer.
private struct PendingCard: View {
    let card: ClaudeChat.Pending
    @State private var picked: Set<String> = []
    @State private var other = ""
    @FocusState private var otherFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch card.body {
            case .permission(let prompt): permission(prompt)
            case .question(let question): self.question(question)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Chrome.overlay(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ClaudeMark.orange.opacity(0.55), lineWidth: 1))
    }

    @ViewBuilder
    private func permission(_ prompt: AgentAccess.Prompt) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(prompt.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ClaudeMark.orange)
            Text(verbatim: prompt.title).font(.system(size: 13, weight: .semibold))
        }
        if case .command = prompt.kind {
            ScrollView {
                Text(verbatim: prompt.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
            Text("This command might change something, so Canvas asks each time.")
                .font(.system(size: 11)).foregroundStyle(Chrome.secondaryText)
        } else if prompt.thenCommand != nil {
            Text(verbatim: prompt.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(2)
        } else {
            Text(verbatim: prompt.detail).font(.system(size: 11.5)).foregroundStyle(Chrome.secondaryText)
        }
        HStack(spacing: 6) {
            if case .command = prompt.kind {
                CardButton(title: "Allow once", primary: true) { card.respond(.allowOnce) }
            } else {
                CardButton(title: "Allow in this chat", primary: true) { card.respond(.allowChat) }
                CardButton(title: "Always") { card.respond(.allowAlways) }
            }
            Spacer(minLength: 0)
            CardButton(title: prompt.kind.isLibrary ? "No, plain shapes" : "Deny") { card.respond(.deny) }
        }
    }

    @ViewBuilder
    private func question(_ q: ClaudeChat.Question) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ClaudeMark(size: 13, tinted: true).padding(.top, 1)
            Text(verbatim: q.text).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        VStack(spacing: 4) {
            ForEach(q.options, id: \.self) { option in
                OptionRow(option: option, selected: picked.contains(option.label), multi: q.multiSelect) {
                    if q.multiSelect {
                        if picked.contains(option.label) { picked.remove(option.label) } else { picked.insert(option.label) }
                    } else {
                        card.respond(.choices([option.label]))
                    }
                }
            }
        }
        HStack(spacing: 6) {
            TextField("Something else…", text: $other)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($otherFocused)
                .onSubmit(sendOther)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Chrome.overlay(0.06)))
            if q.multiSelect && other.isEmpty {
                CardButton(title: "Done", primary: true) {
                    card.respond(picked.isEmpty ? .deny : .choices(q.options.map(\.label).filter(picked.contains)))
                }
            } else if !other.trimmingCharacters(in: .whitespaces).isEmpty {
                CardButton(title: "Send", primary: true, action: sendOther)
            }
            CardButton(title: "Skip") { card.respond(.deny) }
        }
    }

    private func sendOther() {
        let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        card.respond(.other(text))
    }

    private func symbol(_ kind: AgentAccess.Prompt.Kind) -> String {
        switch kind {
        case .folder: "folder"
        case .command: "terminal"
        case .library: "books.vertical"
        }
    }
}

private struct OptionRow: View {
    let option: ClaudeChat.Question.Option
    let selected: Bool
    let multi: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let recommended = option.label.localizedCaseInsensitiveContains("(recommended)")
        let label = option.label.replacingOccurrences(of: "(Recommended)", with: "")
            .replacingOccurrences(of: "(recommended)", with: "").trimmingCharacters(in: .whitespaces)
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                if multi {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? ClaudeMark.orange : Chrome.secondaryText)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: label).font(.system(size: 12.5, weight: .medium))
                        if recommended {
                            Text("Recommended")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(ClaudeMark.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(ClaudeMark.orange.opacity(0.15)))
                        }
                    }
                    if let description = option.description, !description.isEmpty {
                        Text(verbatim: description)
                            .font(.system(size: 11))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? ClaudeMark.orange.opacity(0.14) : isHovering ? Chrome.overlay(0.1) : Chrome.overlay(0.05)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
}

private struct CardButton: View {
    let title: String
    var primary = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? Color.white : Chrome.primaryText)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule(style: .continuous).fill(
                    primary ? ClaudeMark.orange.opacity(isHovering ? 1 : 0.9) : Chrome.overlay(isHovering ? 0.14 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
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
                    case .running: ClaudeMark(size: 11, working: true)
                    case .done: Image(systemName: "checkmark").foregroundStyle(Chrome.secondaryText)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Chrome.warning)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                if status == .running {
                    ShimmerText(text: summary, size: 12)
                } else {
                    Text(verbatim: summary).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
                }
            }
        case .error(let text):
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(Chrome.danger)
                .textSelection(.enabled)
        case .note(let symbol, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ClaudeMark.orange)
                    .frame(width: 14)
                Text(verbatim: text)
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(3)
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
