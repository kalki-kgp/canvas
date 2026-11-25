import Foundation

/// What Claude may do from the chat panel. Canvas never lets it write files:
/// reading and web search run freely inside folders the user allowed,
/// read-only shell commands run without asking, anything else asks first.
@MainActor
enum AgentAccess {
    static let alwaysFoldersKey = "claudeAlwaysFolders"
    static let alwaysLibraryKey = "claudeAlwaysLibrary"

    static var alwaysFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: alwaysFoldersKey) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: alwaysFoldersKey) }
    }

    static var alwaysLibrary: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysLibraryKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysLibraryKey) }
    }

    /// canvas tools that run without asking; the library ones ask first
    nonisolated static let canvasToolNames = [
        "list_scenes", "open_scene", "create_scene", "rename_scene", "get_scene", "add_elements",
        "update_elements", "delete_elements", "clear_canvas", "add_mermaid", "screenshot", "zoom_to",
        "list_slides", "set_slide_order", "present",
    ]
    static let libraryTools: Set<String> = ["list_library", "insert_library_item"]

    enum Decision {
        case allow
        case deny(String)
        case ask(Prompt)
    }

    struct Prompt {
        enum Kind { case folder(String), command, library }
        let kind: Kind
        let title: String
        let detail: String
        /// allow, then re-check (folder grants unlock the rest of a command)
        var thenCommand: String?
    }

    // MARK: decisions

    static func decide(tool: String, input: [String: Any], chat: ClaudeChat) -> Decision {
        if tool.hasPrefix("mcp__canvas__") {
            let name = String(tool.dropFirst("mcp__canvas__".count))
            if libraryTools.contains(name) {
                if alwaysLibrary || chat.grants.library { return .allow }
                return .ask(Prompt(kind: .library, title: "Use shapes from your library?",
                                   detail: "Claude wants to look through your library and place items from it in this scene."))
            }
            return .allow
        }
        switch tool {
        case "WebSearch", "WebFetch", "mcp__agent__ask_user":
            return .allow
        case "Read", "Glob", "Grep", "LS":
            let raw = (input["file_path"] ?? input["path"]) as? String
            guard let raw, !raw.isEmpty else { return .allow }   // the app's own work folder
            return decidePath(expand(raw), chat: chat)
        case "Bash":
            return decideCommand(input["command"] as? String ?? "", chat: chat)
        default:
            return .deny("Canvas only lets Claude read: \(tool) isn't available here.")
        }
    }

    private static func decidePath(_ path: String, chat: ClaudeChat) -> Decision {
        if let reason = blocked(path) { return .deny(reason) }
        if isAllowed(path, chat: chat) { return .allow }
        let scope = scopeFolder(for: path)
        return .ask(Prompt(kind: .folder(scope), title: "Let Claude read \(pretty(scope))?",
                           detail: "Claude can only read here, never change anything."))
    }

    private static func decideCommand(_ command: String, chat: ClaudeChat) -> Decision {
        let analysis = ShellCheck.analyze(command)
        for path in analysis.paths {
            if let reason = blocked(path) { return .deny(reason) }
        }
        let outside = analysis.paths.first { !isAllowed($0, chat: chat) && !harmless($0) }
        if analysis.readOnly {
            guard let outside else { return .allow }
            let scope = scopeFolder(for: outside)
            return .ask(Prompt(kind: .folder(scope), title: "Let Claude read \(pretty(scope))?",
                               detail: command, thenCommand: command))
        }
        return .ask(Prompt(kind: .command, title: "Run this command?", detail: command))
    }

    // MARK: paths

    static func expand(_ raw: String) -> String { expandOnMain(raw) }

    static func pretty(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func isAllowed(_ path: String, chat: ClaudeChat) -> Bool {
        (alwaysFolders + chat.grants.folders).contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    private static func harmless(_ path: String) -> Bool {
        path == "/dev/null" || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/opt/homebrew/")
    }

    /// The folder to offer: the project (git root) holding the path, or its folder.
    static func scopeFolder(for path: String) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var isDir: ObjCBool = false
        var dir = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            ? path : (path as NSString).deletingLastPathComponent
        let start = dir
        while dir.count > 1 && dir != home {
            if fm.fileExists(atPath: dir + "/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return start.isEmpty ? "/" : start
    }

    /// Secrets stay unreadable even inside an allowed folder.
    static func blocked(_ path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config/gh", "Library/Keychains", "Library/Cookies",
                    "Library/Messages", "Library/Mail", "Library/Safari", "Library/Application Support/Google/Chrome",
                    "Library/Application Support/Firefox", "Library/Application Support/Arc",
                    "Library/Application Support/BraveSoftware", "Library/Application Support/Canvas/token"]
        for dir in dirs {
            let full = "\(home)/\(dir)"
            if path == full || path.hasPrefix(full + "/") { return "\(pretty(full)) holds private data, so Canvas never lets Claude read it." }
        }
        let name = (path as NSString).lastPathComponent.lowercased()
        let secretNames = [".netrc", ".npmrc", ".pypirc", "credentials", "credentials.json"]
        if name == ".env" || name.hasPrefix(".env.") || secretNames.contains(name)
            || name.hasSuffix(".pem") || name.hasSuffix(".key") || name.hasSuffix(".p12")
            || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") {
            return "\(name) may hold secrets, so Canvas never lets Claude read it."
        }
        return nil
    }
}

/// A conservative look at a shell command: read-only only when every part is
/// a known reading command with no writing redirection or substitution.
enum ShellCheck {
    struct Result {
        var readOnly: Bool
        var paths: [String]
    }

    static let safe: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "tree", "file", "stat", "du", "df",
        "pwd", "echo", "printf", "sort", "uniq", "cut", "tr", "nl", "column", "jq", "basename", "dirname",
        "realpath", "readlink", "cd", "true", "which", "whence", "type", "date", "uname", "sw_vers", "find",
        "sed", "git", "less", "more", "diff", "cmp", "comm", "md5", "shasum", "xxd", "hexdump", "strings",
        "plutil", "mdls", "defaults", "test", "[", "fd", "awk",
    ]
    static let safeGit: Set<String> = [
        "log", "show", "diff", "status", "ls-files", "ls-tree", "blame", "rev-parse", "shortlog", "describe",
        "grep", "cat-file", "branch", "tag", "remote", "rev-list", "reflog", "config",
    ]

    static func analyze(_ command: String) -> Result {
        var readOnly = true
        if command.contains("$(") || command.contains("`") || command.contains("<(") || command.contains(">(") {
            readOnly = false
        }
        // allow output thrown away, nothing else that writes
        var stripped = command
        for harmless in ["2>&1", "1>&2", "2>/dev/null", "&>/dev/null", ">/dev/null", "2> /dev/null", "> /dev/null"] {
            stripped = stripped.replacingOccurrences(of: harmless, with: " ")
        }
        if stripped.contains(">") { readOnly = false }

        var paths: [String] = []
        for segment in segments(stripped) {
            let words = tokens(segment).drop { $0.contains("=") && !$0.hasPrefix("-") && !$0.hasPrefix("/") }
            guard let first = words.first else { continue }
            let name = (first as NSString).lastPathComponent
            let args = Array(words.dropFirst())
            if !safe.contains(name) || !argsReadOnly(name, args) { readOnly = false }
            for arg in args where arg.hasPrefix("/") || arg.hasPrefix("~") {
                paths.append(AgentAccess.expandOnMain(arg))
            }
        }
        return Result(readOnly: readOnly, paths: paths)
    }

    private static func argsReadOnly(_ name: String, _ args: [String]) -> Bool {
        switch name {
        case "git":
            var i = 0
            while i < args.count, args[i].hasPrefix("-") {
                i += (args[i] == "-C" || args[i] == "-c") ? 2 : 1
            }
            guard i < args.count, safeGit.contains(args[i]) else { return false }
            let rest = args[(i + 1)...]
            switch args[i] {
            case "branch", "tag": return !rest.contains { ["-d", "-D", "-m", "-M", "--delete", "--move", "-f", "--force"].contains($0) } && rest.allSatisfy { $0.hasPrefix("-") }
            case "remote": return rest.isEmpty || rest == ["-v"]
            case "config": return rest.contains { $0 == "--get" || $0 == "--list" || $0 == "-l" || $0 == "--get-all" }
            default: return true
            }
        case "find":
            return !args.contains { ["-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"].contains($0) }
        case "sed":
            return !args.contains { $0 == "-i" || $0.hasPrefix("-i") || $0.hasPrefix("--in-place") }
                && !args.contains { $0.range(of: #"(^|[;}\s])[wW]\s"#, options: .regularExpression) != nil }
        case "awk":
            return !args.contains { $0.contains("system") || $0.contains(">") || $0.contains("|") }
        case "defaults":
            return args.first == "read"
        case "plutil":
            return args.contains("-p") && !args.contains { $0.hasPrefix("-convert") || $0 == "-o" }
        case "rg", "fd":
            return !args.contains { $0 == "--pre" || $0.hasPrefix("--pre=") || $0 == "-x" || $0 == "--exec" || $0 == "-X" }
        default:
            return true
        }
    }

    /// Splits on |, ||, &&, ; and newlines outside quotes.
    private static func segments(_ s: String) -> [String] {
        var out: [String] = [], current = ""
        var quote: Character?
        var chars = Array(s)[...]
        while let c = chars.popFirst() {
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" { quote = c; current.append(c); continue }
            if c == "|" || c == ";" || c == "\n" || (c == "&" && chars.first == "&") {
                if c == "&" || (c == "|" && chars.first == "|") { chars.removeFirst() }
                out.append(current); current = ""
                continue
            }
            if c == "&" { out.append(current); current = ""; continue }   // background job
            current.append(c)
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Words with quotes removed (no expansion).
    private static func tokens(_ s: String) -> [String] {
        var out: [String] = [], current = "", inWord = false
        var quote: Character?
        var escaped = false
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "\\" { escaped = true; inWord = true; continue }
            if c == "'" || c == "\"" { quote = c; inWord = true; continue }
            if c == " " || c == "\t" {
                if inWord { out.append(current); current = ""; inWord = false }
                continue
            }
            current.append(c); inWord = true
        }
        if inWord { out.append(current) }
        return out
    }
}

extension AgentAccess {
    /// `expand` without main-actor isolation, for the shell check.
    nonisolated static func expandOnMain(_ raw: String) -> String {
        var path = raw
        if path == "~" || path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
        }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
