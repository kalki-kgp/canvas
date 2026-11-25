import Foundation

/// Runs Claude Code headless (`claude -p`) on the user's own login and streams
/// its stream-json output line by line.
final class ClaudeRunner {
    struct Request: Decodable {
        let prompt: String
        let system: String?
        let mode: String          // text | vision | agent
        let image: String?        // data URL
        let sessionId: String?
        let model: String?
    }

    let workDir: URL
    let mcpURL: String
    let token: String

    init(workDir: URL, mcpURL: String, token: String) {
        self.workDir = workDir
        self.mcpURL = mcpURL
        self.token = token
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    private static var cachedBinary: String?

    /// The claude binary: well-known locations first, then the login shell.
    static func findBinary() -> String? {
        if let cachedBinary { return cachedBinary }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            cachedBinary = found
            return found
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "whence -p claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        try? shell.run()
        shell.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cachedBinary = path.isEmpty ? nil : path
        return cachedBinary
    }

    private func saveImage(_ dataURL: String) -> URL? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[..<comma]
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        let ext = header.contains("png") ? "png" : "jpg"
        let dir = workDir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // old images aren't needed once a run is over
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in old {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if date < Date().addingTimeInterval(-3600) { try? FileManager.default.removeItem(at: file) }
            }
        }
        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// Starts a run. `onLine` gets each stdout JSON line; `onExit` the exit
    /// status and stderr. Returns the process so it can be stopped.
    func run(
        _ request: Request,
        onLine: @escaping (String) -> Void,
        onExit: @escaping (Int32, String) -> Void
    ) throws -> Process {
        guard let binary = Self.findBinary() else {
            throw NSError(domain: "Canvas", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Claude Code isn't installed (no `claude` on PATH). Install it and sign in, then try again.",
            ])
        }

        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        if let system = request.system, !system.isEmpty {
            args += ["--system-prompt", system]
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        var prompt = request.prompt

        switch request.mode {
        case "agent":
            let config: [String: Any] = ["mcpServers": ["canvas": [
                "type": "http",
                "url": mcpURL,
                "headers": ["Authorization": "Bearer \(token)"],
            ]]]
            let json = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
            args += ["--tools", "", "--mcp-config", json, "--strict-mcp-config", "--allowedTools", "mcp__canvas"]
            if let session = request.sessionId, !session.isEmpty {
                args += ["--resume", session]
            }
        case "vision":
            guard let image = request.image, let url = saveImage(image) else {
                throw NSError(domain: "Canvas", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing image"])
            }
            args += ["--tools", "Read", "--allowedTools", "Read", "--no-session-persistence"]
            prompt += "\n\nThe image is at \(url.path). Read it first."
        default:
            args += ["--tools", "", "--no-session-persistence"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = workDir

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""]
            .joined(separator: ":")
        // use the subscription login, never an API key or a router left in the env
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        env["CLAUDE_CODE_ENTRYPOINT"] = "canvas"
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var buffer = Data()
        let lineLock = NSLock()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lineLock.lock()
            defer { lineLock.unlock() }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                    onLine(text)
                }
            }
        }
        var errData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { errData.append(chunk) }
        }

        process.terminationHandler = { p in
            // drain what's left
            let rest = stdout.fileHandleForReading.readDataToEndOfFile()
            lineLock.lock()
            buffer.append(rest)
            let tail = buffer
            buffer = Data()
            lineLock.unlock()
            for line in tail.split(separator: 0x0A) {
                if let text = String(data: line, encoding: .utf8), !text.isEmpty { onLine(text) }
            }
            errData.append(stderr.fileHandleForReading.readDataToEndOfFile())
            onExit(p.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
        }

        try process.run()
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()
        return process
    }
}
