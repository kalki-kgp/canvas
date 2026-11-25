import AppKit
import Foundation
import PDFKit
import WebKit

/// Request routing: the built web app, the store API, Claude runs, PDF export
/// and the MCP endpoint.
final class Routes {
    let port: UInt16
    let token: String
    let webRoot: URL
    let store: Store
    let claude: ClaudeRunner
    /// set once the window exists; MCP calls are forwarded to the page
    weak var web: WebBridge?

    init(port: UInt16, token: String, webRoot: URL, store: Store, claude: ClaudeRunner) {
        self.port = port
        self.token = token
        self.webRoot = webRoot
        self.store = store
        self.claude = claude
    }

    private var origin: String { "http://127.0.0.1:\(port)" }

    func handle(_ req: HTTPServer.Request, _ res: HTTPServer.Responder) {
        // only this machine, by this name (stops DNS rebinding)
        let host = req.header("host") ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return res.text(403, "Forbidden host")
        }

        if req.path == "/mcp" || req.path.hasPrefix("/api/") {
            // browsers on other sites can't call in
            if let o = req.header("origin"), o != origin, o != "http://localhost:\(port)" {
                return res.text(403, "Forbidden origin")
            }
            guard authorized(req) else { return res.text(401, "Missing or wrong token") }
            if req.path == "/mcp" { return mcp(req, res) }
            return api(req, res, path: String(req.path.dropFirst("/api/".count)))
        }

        guard req.method == "GET" || req.method == "HEAD" else { return res.text(405, "Method not allowed") }
        serveStatic(req.path, res)
    }

    private func authorized(_ req: HTTPServer.Request) -> Bool {
        let presented = req.header("x-canvas-token")
            ?? req.header("authorization").map { $0.replacingOccurrences(of: "Bearer ", with: "") }
            ?? req.query["t"]
        guard let presented else { return false }
        // constant-time compare
        let a = Array(presented.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: static files

    private func serveStatic(_ path: String, _ res: HTTPServer.Responder) {
        var relative = String(path.drop(while: { $0 == "/" }))
        if relative.isEmpty { relative = "index.html" }
        let file = webRoot.appendingPathComponent(relative).standardizedFileURL
        var isDir: ObjCBool = false
        let inside = file.path.hasPrefix(webRoot.standardizedFileURL.path + "/")

        if inside, FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
           let data = try? Data(contentsOf: file) {
            let immutable = relative.hasPrefix("assets/") || relative.hasPrefix("fonts/")
            return res.send(200, data, headers: [
                "Content-Type": Store.contentType(for: relative),
                "Cache-Control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
            ])
        }
        // app routes (/scene/…) get the app shell; missing assets are 404s
        if (relative as NSString).pathExtension.isEmpty,
           let index = try? Data(contentsOf: webRoot.appendingPathComponent("index.html")) {
            return res.send(200, index, headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache"])
        }
        res.text(404, "Not found")
    }

    // MARK: api

    private func api(_ req: HTTPServer.Request, _ res: HTTPServer.Responder, path: String) {
        if path.hasPrefix("blob/") {
            let key = String(path.dropFirst("blob/".count))
            guard store.url(for: key) != nil else { return res.text(400, "Bad path") }
            switch req.method {
            case "GET":
                guard let data = store.read(key) else { return res.text(404, "Not found") }
                return res.send(200, data, headers: [
                    "Content-Type": Store.contentType(for: key),
                    "Cache-Control": "no-store",
                ])
            case "PUT":
                do {
                    try store.write(key, req.body)
                    return res.send(204)
                } catch {
                    return res.text(500, error.localizedDescription)
                }
            case "DELETE":
                do {
                    return res.send(try store.delete(key) ? 204 : 404)
                } catch {
                    return res.text(500, error.localizedDescription)
                }
            default:
                return res.text(405, "Method not allowed")
            }
        }

        if path.hasPrefix("list/") {
            guard let items = store.list(String(path.dropFirst("list/".count))) else {
                return res.text(400, "Bad path")
            }
            return res.json(200, items)
        }

        switch (req.method, path) {
        case ("POST", "claude"): return runClaude(req, res)
        case ("POST", "pdf"): return savePDF(req, res)
        default: return res.text(404, "Not found")
        }
    }

    // MARK: claude

    private func runClaude(_ req: HTTPServer.Request, _ res: HTTPServer.Responder) {
        let request: ClaudeRunner.Request
        do {
            request = try JSONDecoder().decode(ClaudeRunner.Request.self, from: req.body)
        } catch {
            return res.text(400, "Bad request: \(error.localizedDescription)")
        }

        res.startStream(200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        ])
        let event = { (json: String) in
            res.write(Data("data: \(json)\n\n".utf8))
        }
        let errorEvent = { (message: String) in
            let payload = (try? JSONSerialization.data(withJSONObject: ["type": "canvas_error", "message": message]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            event(payload)
        }

        do {
            var sawResult = false
            let process = try claude.run(request, onLine: { line in
                if line.contains("\"type\":\"result\"") { sawResult = true }
                event(line)
            }, onExit: { status, stderr in
                if !sawResult {
                    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    errorEvent(detail.isEmpty ? "Claude exited with status \(status)" : String(detail.suffix(1500)))
                }
                res.write(Data("data: [DONE]\n\n".utf8))
                res.finish()
            })
            res.onDisconnect = {
                if process.isRunning { process.terminate() }
            }
        } catch {
            errorEvent(error.localizedDescription)
            res.write(Data("data: [DONE]\n\n".utf8))
            res.finish()
        }
    }

    // MARK: pdf

    private func savePDF(_ req: HTTPServer.Request, _ res: HTTPServer.Responder) {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let pages = body["pages"] as? [String], !pages.isEmpty else {
            return res.text(400, "Expected {name, pages}")
        }
        let name = (body["name"] as? String) ?? "Slides"

        let document = PDFDocument()
        for (i, dataURL) in pages.enumerated() {
            guard let comma = dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            // pages are rendered at 2x; size the page in points
            let image = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2))
            image.addRepresentation(rep)
            if let page = PDFPage(image: image) {
                document.insert(page, at: i)
            }
        }
        guard let data = document.dataRepresentation() else { return res.text(500, "Couldn't build the PDF") }

        DispatchQueue.main.async { [weak self] in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(name).pdf"
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            let done = { (response: NSApplication.ModalResponse) in
                guard response == .OK, let url = panel.url else { return res.json(200, ["saved": false]) }
                do {
                    try data.write(to: url, options: .atomic)
                    res.json(200, ["saved": true, "path": url.path])
                } catch {
                    res.text(500, error.localizedDescription)
                }
            }
            if let window = self?.web?.webView.window {
                panel.beginSheetModal(for: window, completionHandler: done)
            } else {
                done(panel.runModal())
            }
        }
    }

    // MARK: mcp (streamable HTTP, JSON responses, stateless)

    private func mcp(_ req: HTTPServer.Request, _ res: HTTPServer.Responder) {
        switch req.method {
        case "POST": break
        case "DELETE": return res.send(200)
        default:
            return res.send(405, headers: ["Allow": "POST, DELETE"])
        }
        guard let body = String(data: req.body, encoding: .utf8) else { return res.text(400, "Bad body") }

        DispatchQueue.main.async { [weak self] in
            guard let web = self?.web else { return res.text(503, "Canvas window isn't ready") }
            web.callMCP(body) { result in
                switch result {
                case .success(let text) where text.isEmpty:
                    res.send(202)
                case .success(let text):
                    res.send(200, Data(text.utf8), headers: ["Content-Type": "application/json"])
                case .failure(let error):
                    let reply: [String: Any] = [
                        "jsonrpc": "2.0", "id": NSNull(),
                        "error": ["code": -32603, "message": error.localizedDescription],
                    ]
                    res.json(200, reply)
                }
            }
        }
    }
}
