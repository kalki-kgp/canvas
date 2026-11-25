import SwiftUI
import UniformTypeIdentifiers

/// The scenes library: collections on the left, scene cards on the right.
struct LibraryView: View {
    @ObservedObject var ws: Workspace

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(ws: ws)
            LibraryGrid(ws: ws)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.22))
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(10)
        }
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @ObservedObject var ws: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 34)   // traffic lights
            VStack(spacing: 2) {
                SidebarRow(title: "All Scenes", symbol: "square.grid.2x2.fill", hue: 5,
                           count: ws.count(.all), isSelected: ws.filter == .all) { ws.filter = .all }
                SidebarRow(title: "Starred", symbol: "star.fill", hue: 1,
                           count: ws.count(.starred), isSelected: ws.filter == .starred) { ws.filter = .starred }
            }

            HStack {
                Text(verbatim: "Collections")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                Spacer()
                Button(action: ws.newCollection) {
                    Image(systemName: "plus").font(Chrome.inlineIconFont).frame(width: 20, height: 20).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Chrome.secondaryText)
                .help("New Collection")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(ws.collections.enumerated()), id: \.element.id) { index, collection in
                        CollectionRow(ws: ws, collection: collection, hue: [3, 2, 4, 6, 7, 0][index % 6])
                    }
                }
            }
            .scrollIndicators(.never)

            HStack {
                ChromeCircleButton(symbol: themeSymbol, help: "Appearance: \(ws.appTheme.rawValue.capitalized)") {
                    ws.setTheme(nextTheme)
                }
                Spacer()
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
    }

    private var themeSymbol: String {
        switch ws.appTheme { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" }
    }

    private var nextTheme: AppTheme {
        switch ws.appTheme { case .system: .light; case .light: .dark; case .dark: .system }
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let hue: Int
    var count: Int?
    let isSelected: Bool
    var isTargeted = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: symbol, hue: hue, size: 20)
                Text(verbatim: title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 1 : 0.9))
                    .lineLimit(1)
                Spacer()
                if let count, count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isTargeted ? Chrome.accent.opacity(0.25)
                          : isSelected ? Chrome.overlay(0.12) : isHovering ? Chrome.overlay(0.06) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
}

private struct CollectionRow: View {
    @ObservedObject var ws: Workspace
    let collection: SceneCollection
    let hue: Int
    @State private var isTargeted = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if ws.renamingCollection == collection.id {
                HStack(spacing: 9) {
                    IconTile(symbol: "folder.fill", hue: hue, size: 20)
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { ws.renamingCollection = nil }
                }
                .padding(.horizontal, 7)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Chrome.overlay(0.12)))
                .onAppear {
                    name = collection.name
                    DispatchQueue.main.async { focused = true }
                }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            } else {
                SidebarRow(title: collection.name, symbol: "folder.fill", hue: hue,
                           count: ws.count(.collection(collection.id)),
                           isSelected: ws.filter == .collection(collection.id),
                           isTargeted: isTargeted) { ws.filter = .collection(collection.id) }
                    .contextMenu {
                        Button("Rename") { ws.renamingCollection = collection.id }
                        Button("Delete Collection…") { ws.confirmDeleteCollection(collection) }
                    }
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { ws.run("move", id, collection.id) }
            return !ids.isEmpty
        } isTargeted: { isTargeted = $0 }
    }

    private func commit() {
        guard ws.renamingCollection == collection.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != collection.name { ws.run("renameCollection", collection.id, trimmed) }
        ws.renamingCollection = nil
    }
}

// MARK: - Grid

private struct LibraryGrid: View {
    @ObservedObject var ws: Workspace
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(verbatim: ws.filterTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                searchField
                GlassPickerButton(options: SceneSort.allCases.map { ($0, $0.title) }, selection: $ws.sort)
                ChromeTextButton(symbol: "square.and.arrow.down", title: "Import", help: "Import .excalidraw files") {
                    ws.importFiles()
                }
                ChromeTextButton(symbol: "plus", title: "New Scene", help: "New Scene (⌘N)") { ws.newScene() }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            let scenes = ws.visibleScenes
            if scenes.isEmpty {
                VStack(spacing: 12) {
                    Text(verbatim: ws.search.isEmpty ? (ws.filter == .starred ? "No starred scenes" : "No scenes") : "No matches")
                        .font(.system(size: 13))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 14)], spacing: 14) {
                        ForEach(scenes) { scene in
                            SceneCard(ws: ws, scene: scene)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(Chrome.inlineIconFont).foregroundStyle(Chrome.secondaryText)
            TextField("Search", text: $ws.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
                .onExitCommand { ws.search = ""; searchFocused = false }
            if !ws.search.isEmpty {
                Button { ws.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Chrome.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: Chrome.capsuleContentHeight)
        .padding(.vertical, Chrome.capsuleVerticalPadding)
        .chromeGlassCapsule()
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }
}

private struct SceneCard: View {
    @ObservedObject var ws: Workspace
    let scene: SceneMeta
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: scene.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(scene.updated, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Spacer(minLength: 4)
                if scene.isStarred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Chrome.warning)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHovering ? Chrome.overlay(0.07) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
        .onTapGesture { ws.open(scene) }
        .draggable(scene.id) {
            Text(verbatim: scene.name).font(.system(size: 12, weight: .medium)).padding(8)
        }
        .contextMenu { menu }
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return ZStack {
            shape.fill(colorScheme == .dark ? Color(white: 0.07) : .white)
            if let image = ws.thumbnail(for: scene) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
                    // thumbnails are drawn light; dark mode flips them the way the editor does
                    .modifier(DarkCanvasFilter(active: colorScheme == .dark))
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Chrome.overlay(0.08), lineWidth: 0.5) }
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { ws.open(scene) }
        Button("Rename…") { ws.rename(scene) }
        Button("Duplicate") { ws.run("duplicate", scene.id) }
        Button(scene.isStarred ? "Remove Star" : "Star") { ws.run("star", scene.id) }
        Menu("Move to") {
            Button("No Collection") { ws.run("move", scene.id, NSNull()) }
                .disabled(scene.collectionId == nil)
            if !ws.collections.isEmpty { Divider() }
            ForEach(ws.collections) { collection in
                Button(collection.name) { ws.run("move", scene.id, collection.id) }
                    .disabled(scene.collectionId == collection.id)
            }
        }
        Divider()
        Button("Export…") { ws.run("exportFile", scene.id) }
        Divider()
        Button("Delete…", role: .destructive) { ws.confirmDelete(scene) }
    }
}

struct DarkCanvasFilter: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            // white becomes the editor's #121212 dark canvas
            content.colorInvert().hueRotation(.degrees(180)).brightness(0.07)
        } else {
            content
        }
    }
}
