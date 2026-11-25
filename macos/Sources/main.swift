import AppKit
import Security

let PORT: UInt16 = {
    if let raw = ProcessInfo.processInfo.environment["CANVAS_PORT"], let p = UInt16(raw) { return p }
    return 41873
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: HTTPServer?
    private var routes: Routes?
    private var web: WebController?
    private var token = ""
    private var pendingOpen: [URL] = []
    private var terminating = false

    private var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canvas")
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// A per-install secret guarding the local API and MCP endpoint. Stable
    /// across launches so `claude mcp add` only has to run once.
    private func loadToken() -> String {
        let url = supportDir.appendingPathComponent("token")
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        token = loadToken()

        let webRoot: URL
        if let dev = ProcessInfo.processInfo.environment["CANVAS_WEB_ROOT"] {
            webRoot = URL(fileURLWithPath: dev)
        } else {
            webRoot = Bundle.main.resourceURL!.appendingPathComponent("web")
        }
        let appURL = URL(string: "http://127.0.0.1:\(PORT)/")!
        let store = Store(root: supportDir.appendingPathComponent("data"))
        let claude = ClaudeRunner(
            workDir: supportDir.appendingPathComponent("claude"),
            mcpURL: "http://127.0.0.1:\(PORT)/mcp",
            token: token
        )
        let routes = Routes(port: PORT, token: token, webRoot: webRoot, store: store, claude: claude)
        self.routes = routes

        let server = HTTPServer(port: PORT) { req, res in routes.handle(req, res) }
        do {
            try server.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Canvas couldn't start"
            alert.informativeText = "Port \(PORT) on this Mac is in use (is another copy of Canvas running?).\n\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.server = server

        let web = WebController(appURL: appURL, token: token, port: PORT, version: version)
        routes.web = web
        self.web = web
        web.window.makeKeyAndOrderFront(nil)
        if !pendingOpen.isEmpty {
            web.openFiles(pendingOpen)
            pendingOpen = []
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let web {
            web.openFiles(urls)
            web.window.makeKeyAndOrderFront(nil)
        } else {
            pendingOpen.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let web, !terminating else { return .terminateNow }
        terminating = true
        web.flush { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { web?.window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: menu actions

    @objc func newScene(_ sender: Any?) { web?.menu("new-scene") }
    @objc func showDashboard(_ sender: Any?) { web?.menu("dashboard") }
    @objc func present(_ sender: Any?) { web?.menu("present") }
    @objc func showHistory(_ sender: Any?) { web?.menu("history") }
    @objc func showClaude(_ sender: Any?) { web?.menu("claude") }
    @objc func saveVersion(_ sender: Any?) { web?.menu("save-version") }
    @objc func reloadPage(_ sender: Any?) { web?.webView.reload() }

    @objc func importFiles(_ sender: Any?) {
        guard let web else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: web.window) { response in
            if response == .OK { web.openFiles(panel.urls) }
        }
    }

    @objc func connectClaudeCode(_ sender: Any?) {
        let command = "claude mcp add --scope user --transport http canvas http://127.0.0.1:\(PORT)/mcp --header \"Authorization: Bearer \(token)\""
        let alert = NSAlert()
        alert.messageText = "Connect Claude Code"
        alert.informativeText = "Run this once in a terminal. Claude Code can then draw in the scene open in Canvas while the app is running.\n\n\(command)"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Close")
        let handle = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        if let window = web?.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    @objc func openDataFolder(_ sender: Any?) {
        NSWorkspace.shared.open(supportDir.appendingPathComponent("data"))
    }

    // MARK: menu bar

    private func buildMenu() {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if let target { i.target = target }
            return i
        }
        @discardableResult func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            top.submenu = menu
            main.addItem(top)
            return top
        }

        submenu("Canvas", [
            item("About Canvas", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Connect Claude Code…", #selector(connectClaudeCode(_:)), target: self),
            item("Show Data Folder", #selector(openDataFolder(_:)), target: self),
            .separator(),
            item("Hide Canvas", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Canvas", #selector(NSApplication.terminate(_:)), "q"),
        ])

        submenu("File", [
            item("New Scene", #selector(newScene(_:)), "n", target: self),
            item("All Scenes", #selector(showDashboard(_:)), "h", [.command, .shift], target: self),
            .separator(),
            item("Import…", #selector(importFiles(_:)), target: self),
            item("Save Version", #selector(saveVersion(_:)), target: self),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])

        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])

        submenu("View", [
            item("Present", #selector(present(_:)), "p", [.command, .option], target: self),
            item("Version History", #selector(showHistory(_:)), target: self),
            item("Claude", #selector(showClaude(_:)), target: self),
            .separator(),
            item("Reload", #selector(reloadPage(_:)), "r", [.command, .option], target: self),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu.submenu

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
