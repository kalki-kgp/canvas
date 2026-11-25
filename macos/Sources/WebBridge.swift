import AppKit
import UniformTypeIdentifiers
import WebKit

/// The editor page: a WKWebView on the local server, with native file
/// panels, downloads, external links, and the bridge the window, menus and
/// MCP talk to the page through.
@MainActor
final class WebBridge: NSObject, WKNavigationDelegate, WKUIDelegate,
    WKDownloadDelegate, WKScriptMessageHandler {

    let webView: WKWebView
    private let appURL: URL
    private weak var workspace: Workspace?
    private var loaded = false
    private var pendingEvents: [[String: Any]] = []
    private var popups: [NSWindow] = []

    private var window: NSWindow? { webView.window ?? NSApp.mainWindow }

    init(appURL: URL, token: String, port: UInt16, version: String, workspace: Workspace) {
        self.appURL = appURL
        self.workspace = workspace

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let boot = "window.__CANVAS__ = {token: \(Self.jsString(token)), port: \(port), version: \(Self.jsString(version))};"
        config.userContentController.addUserScript(
            WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.isElementFullscreenEnabled = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.isInspectable = true
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        super.init()
        config.userContentController.add(self, name: "canvas")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: appURL))
    }

    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    // MARK: talking to the page

    func dispatch(_ event: [String: Any]) {
        guard loaded else {
            pendingEvents.append(event)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.canvasNative && window.canvasNative.dispatch(\(json))")
    }

    func menu(_ action: String) { dispatch(["type": "menu", "action": action]) }

    /// Calls `window.canvasBridge.call(fn, args)`; the page answers in JSON.
    @discardableResult
    func bridge(_ fn: String, _ args: [Any]) async throws -> Any? {
        let result = try await webView.callAsyncJavaScript(
            "if (!window.canvasBridge) throw new Error('Canvas is still loading'); return await window.canvasBridge.call(fn, args);",
            arguments: ["fn": fn, "args": args.map { $0 is NSNull ? NSNull() : $0 }],
            contentWorld: .page
        )
        guard let text = result as? String, let data = text.data(using: .utf8) else { return nil }
        let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return value is NSNull ? nil : value
    }

    func callMCP(_ body: String, completion: @escaping (Result<String, Error>) -> Void) {
        webView.callAsyncJavaScript(
            "return window.canvasMCP ? await window.canvasMCP.handle(body) : null;",
            arguments: ["body": body],
            in: nil,
            in: .page
        ) { result in
            switch result {
            case .success(let value):
                if let text = value as? String {
                    completion(.success(text))
                } else {
                    completion(.failure(NSError(domain: "Canvas", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "Canvas is still loading",
                    ])))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Lets the page write unsaved changes; calls back within ~3s regardless.
    func flush(_ done: @escaping () -> Void) {
        var called = false
        let finish = {
            guard !called else { return }
            called = true
            done()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
        webView.callAsyncJavaScript(
            "if (window.canvasFlush) { await window.canvasFlush(); } return true;",
            arguments: [:], in: nil, in: .page
        ) { _ in finish() }
    }

    func openFiles(_ urls: [URL]) {
        for url in urls {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            dispatch(["type": "open-file", "name": url.lastPathComponent, "contents": contents])
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "fullscreen":
            let on = body["on"] as? Bool ?? false
            if let window, window.styleMask.contains(.fullScreen) != on { window.toggleFullScreen(nil) }
        default:
            workspace?.receive(body)
        }
    }

    // MARK: WKNavigationDelegate

    private func isApp(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == appURL.scheme && url.host == appURL.host && url.port == appURL.port
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        let url = action.request.url
        if webView !== self.webView {
            if let url, handlePopupNavigation(webView, url: url) { return decisionHandler(.cancel) }
            return decisionHandler(.allow)
        }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if mainFrame, let url, !isApp(url), url.scheme != "about", url.scheme != "blob", url.scheme != "data" {
            // links out of the app open in the default browser
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        loaded = true
        let queued = pendingEvents
        pendingEvents = []
        queued.forEach(dispatch)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.reload()
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return completionHandler(nil) }
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("download failed: \(error)")
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window!) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// target=_blank: the excalidraw libraries site opens in an in-app window
    /// so its "Add to Excalidraw" redirect can land back here; anything else
    /// goes to the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if url.host?.hasSuffix("libraries.excalidraw.com") == true {
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            win.title = "Excalidraw Libraries"
            win.contentView = popup
            win.isReleasedWhenClosed = false
            win.center()
            win.makeKeyAndOrderFront(nil)
            popups.append(win)
            return popup
        }
        NSWorkspace.shared.open(url)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeAll { win in
            if win.contentView === webView { win.close(); return true }
            return false
        }
    }
}

/// Navigation inside the libraries popup: when it redirects back to the app
/// (`…#addLibrary=…`), hand the hash to the main view and close the popup.
extension WebBridge {
    func handlePopupNavigation(_ webView: WKWebView, url: URL) -> Bool {
        guard webView !== self.webView, isApp(url), let fragment = url.fragment else { return false }
        self.webView.evaluateJavaScript("location.hash = \(Self.jsString(fragment))")
        if let win = popups.first(where: { $0.contentView === webView }) {
            win.close()
            popups.removeAll { $0 === win }
        }
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}
