import AppKit
import SwiftUI

// The toolbar's Share button and its popover: start sharing, make view or
// edit links, copy and revoke them, stop sharing; for a scene someone
// shared with you, what you can do and a way to leave.

struct ShareButton: View {
    @ObservedObject var ws: Workspace
    @State private var isPresented = false
    @State private var isHovering = false

    private var info: CollabInfo? { ws.openSceneId.flatMap { ws.collab[$0] } }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                if let info {
                    LiveDot(state: info.state)
                    Text(verbatim: info.peers > 0 ? "Shared · \(info.peers + 1)" : "Shared")
                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        .contentTransition(.numericText())
                } else {
                    Image(systemName: "person.2").font(Chrome.inlineIconFont)
                    Text("Share").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .help("Share this scene")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SharePopover(ws: ws)
        }
    }
}

private struct LiveDot: View {
    let state: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(state == "live" ? 0.22 : 0)).frame(width: 13, height: 13))
            .frame(width: 13, height: 13)
    }

    private var color: Color {
        switch state {
        case "live": Color(nsColor: .systemGreen)
        case "ended": ClaudeMark.orange
        default: Chrome.secondaryText
        }
    }
}

/// What the page reports about the open scene's sharing.
private struct ShareStatus {
    struct Link: Identifiable {
        let id: String
        let mode: String
        let url: String
        let online: Int
    }

    var shared = false
    var role = "view"
    var state = "connecting"
    var peers = 0
    var ended: String?
    var links: [Link] = []

    init() {}

    init(_ json: [String: Any]) {
        shared = json["shared"] as? Bool ?? false
        role = json["role"] as? String ?? "view"
        state = json["state"] as? String ?? "connecting"
        peers = json["peers"] as? Int ?? 0
        ended = json["ended"] as? String
        links = (json["links"] as? [[String: Any]] ?? []).compactMap { link in
            guard let id = link["id"] as? String, let url = link["url"] as? String else { return nil }
            return Link(id: id, mode: link["mode"] as? String ?? "view", url: url, online: link["online"] as? Int ?? 0)
        }
    }
}

private struct SharePopover: View {
    @ObservedObject var ws: Workspace
    @State private var status: ShareStatus?
    @State private var busy = false
    @State private var error: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status {
                if !status.shared {
                    notShared
                } else if status.role == "owner" {
                    owner(status)
                } else {
                    guest(status)
                }
            } else {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .frame(height: 60)
            }
            if let error {
                Text(verbatim: error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Chrome.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .animation(Chrome.panelSlide, value: status?.links.map(\.id))
        .task { await refresh() }
        .onChange(of: ws.openSceneId.flatMap { ws.collab[$0] }) { _, _ in Task { await refresh() } }
    }

    // MARK: states

    private var notShared: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(symbol: "person.2.fill", title: "Share this scene",
                   detail: "People with the link open it in Canvas and see changes live, even when your Mac is off.")
            Label {
                Text("Encrypted on your Mac. The sharing server can't read it.")
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                ShareActionButton(title: busy ? "Starting…" : "Start Sharing", primary: true) {
                    perform("shareStart")
                }
                .disabled(busy)
            }
        }
    }

    private func owner(_ status: ShareStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusLine(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text("Links")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.bottom, 2)
                if status.links.isEmpty {
                    Text("No links. Anyone you shared with before can't get in.")
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.vertical, 4)
                }
                ForEach(status.links) { link in
                    LinkRow(link: link, copied: copied == link.id) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.url, forType: .string)
                        withAnimation(Chrome.hover) { copied = link.id }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation(Chrome.hover) { if copied == link.id { copied = nil } }
                        }
                    } revoke: {
                        perform("shareRevoke", link.id)
                    }
                    .transition(.opacity)
                }
            }
            HStack(spacing: 6) {
                Text("New link")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.secondaryText)
                Spacer()
                ShareActionButton(title: "Can Edit") { perform("shareNewLink", "edit") }
                ShareActionButton(title: "View Only") { perform("shareNewLink", "view") }
            }
            .disabled(busy)
            Divider().padding(.vertical, 2)
            HStack {
                Text("Stopping deletes the shared copy and every link. The scene stays on your Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                ShareActionButton(title: "Stop Sharing", destructive: true) { confirmStop() }
            }
        }
    }

    private func guest(_ status: ShareStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let ended = status.ended {
                Header(symbol: "link.badge.plus", title: ended == "revoked" ? "Link turned off" : "Sharing stopped",
                       detail: ended == "revoked"
                           ? "The owner turned off the link you joined with. Your copy stays here."
                           : "The owner stopped sharing this scene. Your copy stays here.")
            } else {
                Header(symbol: status.role == "edit" ? "pencil" : "eye",
                       title: status.role == "edit" ? "Shared with you · Can edit" : "Shared with you · View only",
                       detail: "Changes sync with everyone on this scene.")
                StatusLine(status: status)
            }
            HStack {
                Spacer()
                ShareActionButton(title: status.ended == nil ? "Leave" : "Remove Link") { perform("shareLeave") }
            }
        }
    }

    // MARK: actions

    private func refresh() async {
        do {
            let json = try await ws.call("shareStatus") as? [String: Any] ?? [:]
            withAnimation(Chrome.panelSlide) { status = ShareStatus(json) }
        } catch {
            self.error = error.localizedDescription
            if status == nil { status = ShareStatus() }
        }
    }

    private func perform(_ fn: String, _ args: Any...) {
        busy = true
        error = nil
        Task {
            do {
                _ = try await ws.web?.bridge(fn, args)
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
            busy = false
        }
    }

    private func confirmStop() {
        let alert = NSAlert()
        alert.messageText = "Stop sharing this scene?"
        alert.informativeText = "Everyone you shared it with loses access, and the shared copy is deleted. Your scene stays on this Mac."
        alert.addButton(withTitle: "Stop Sharing")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = ws.web?.webView.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { perform("shareStop") }
        }
    }
}

// MARK: pieces

private struct Header: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Chrome.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Chrome.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StatusLine: View {
    let status: ShareStatus

    var body: some View {
        HStack(spacing: 8) {
            LiveDot(state: status.state)
            Text(verbatim: text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Chrome.primaryText.opacity(0.9))
        }
    }

    private var text: String {
        switch status.state {
        case "live":
            status.peers == 0 ? "Live · Only you here" : "Live · \(status.peers) other\(status.peers == 1 ? "" : "s") here"
        case "offline": "Offline · Changes sync when you're back"
        default: "Connecting…"
        }
    }
}

private struct LinkRow: View {
    let link: ShareStatus.Link
    let copied: Bool
    let copy: () -> Void
    let revoke: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: link.mode == "edit" ? "pencil" : "eye")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.mode == "edit" ? "Can edit" : "View only")
                    .font(.system(size: 12.5, weight: .medium))
                Text(verbatim: link.online > 0 ? "\(link.online) here now" : "Copy and send it to share")
                    .font(.system(size: 10.5))
                    .foregroundStyle(link.online > 0 ? Color(nsColor: .systemGreen) : Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy link", tint: copied ? Color(nsColor: .systemGreen) : nil, action: copy)
            IconButton(symbol: "xmark", help: "Turn off this link", action: revoke)
                .opacity(isHovering ? 1 : 0.55)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Chrome.overlay(isHovering ? 0.07 : 0.04)))
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? Chrome.primaryText.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Chrome.overlay(isHovering ? 0.12 : 0)))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
}

private struct ShareActionButton: View {
    let title: String
    var primary = false
    var destructive = false
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? Color.white : destructive ? Chrome.danger : Chrome.primaryText)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule(style: .continuous).fill(
                    primary ? Chrome.accent.opacity(isHovering ? 1 : 0.9) : Chrome.overlay(isHovering ? 0.14 : 0.08)))
                .contentShape(Capsule())
                .fixedSize()
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }
}
