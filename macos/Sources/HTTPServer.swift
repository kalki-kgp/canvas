import Foundation
import Network

/// A small HTTP/1.1 server on 127.0.0.1. One request per connection
/// (`Connection: close`), which keeps streaming responses simple.
final class HTTPServer {
    struct Request {
        let method: String
        let path: String            // percent-decoded, without the query
        let query: [String: String]
        let headers: [String: String] // lowercased names
        let body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    final class Responder {
        private let connection: NWConnection
        private var headSent = false
        private var finished = false
        private let lock = NSLock()
        /// called once if the client goes away before the response is finished
        var onDisconnect: (() -> Void)?

        init(connection: NWConnection) {
            self.connection = connection
        }

        private static func reason(_ status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 202: return "Accepted"
            case 204: return "No Content"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 409: return "Conflict"
            case 413: return "Payload Too Large"
            case 500: return "Internal Server Error"
            case 503: return "Service Unavailable"
            default: return "Status"
            }
        }

        private func head(_ status: Int, _ headers: [String: String], contentLength: Int?) -> Data {
            var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
            var all = headers
            all["Connection"] = "close"
            all["X-Content-Type-Options"] = "nosniff"
            if let contentLength { all["Content-Length"] = String(contentLength) }
            for (k, v) in all { lines.append("\(k): \(v)") }
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }

        func send(_ status: Int, _ body: Data = Data(), headers: [String: String] = [:]) {
            lock.lock()
            guard !headSent else { lock.unlock(); return }
            headSent = true
            finished = true
            lock.unlock()
            var data = head(status, headers, contentLength: body.count)
            data.append(body)
            connection.send(content: data, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }

        func json(_ status: Int, _ object: Any) {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            send(status, data, headers: ["Content-Type": "application/json"])
        }

        func text(_ status: Int, _ message: String) {
            send(status, Data(message.utf8), headers: ["Content-Type": "text/plain; charset=utf-8"])
        }

        /// Starts a response without a length; write chunks, then `finish()`.
        func startStream(_ status: Int, headers: [String: String]) {
            lock.lock()
            guard !headSent else { lock.unlock(); return }
            headSent = true
            lock.unlock()
            connection.send(content: head(status, headers, contentLength: nil), completion: .contentProcessed { _ in })
        }

        func write(_ data: Data) {
            lock.lock()
            let done = finished
            lock.unlock()
            guard !done else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }

        fileprivate func clientWentAway() {
            lock.lock()
            let wasFinished = finished
            finished = true
            let callback = onDisconnect
            onDisconnect = nil
            lock.unlock()
            if !wasFinished { callback?() }
        }
    }

    typealias Handler = (Request, Responder) -> Void

    let port: UInt16
    private var listener: NWListener?
    private let handler: Handler
    private let queue = DispatchQueue(label: "canvas.http", attributes: .concurrent)
    static let maxBody = 200 * 1024 * 1024

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        if let failure { throw failure }
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        let responder = Responder(connection: connection)
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: responder.clientWentAway()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, responder: responder, buffer: Data())
    }

    private func receive(_ connection: NWConnection, responder: Responder, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = self.parse(buffer) {
                switch request {
                case .complete(let req):
                    // after the request, any further read signals the client hanging up
                    self.watchForHangup(connection, responder: responder)
                    self.handler(req, responder)
                    return
                case .tooLarge:
                    responder.text(413, "Too large")
                    return
                case .bad:
                    responder.text(400, "Bad request")
                    return
                case .incomplete:
                    break
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, responder: responder, buffer: buffer)
        }
    }

    private func watchForHangup(_ connection: NWConnection, responder: Responder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil {
                responder.clientWentAway()
            } else if data != nil {
                self?.watchForHangup(connection, responder: responder)
            }
        }
    }

    private enum ParseResult {
        case complete(Request)
        case incomplete
        case tooLarge
        case bad
    }

    private func parse(_ buffer: Data) -> ParseResult? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .bad : .incomplete
        }
        guard let headText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .bad
        }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .bad }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        if length > Self.maxBody { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1
                    ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
                    : ""
                query[key] = value
            }
        }

        return .complete(Request(
            method: String(requestLine[0]).uppercased(),
            path: rawPath.removingPercentEncoding ?? rawPath,
            query: query,
            headers: headers,
            body: Data(body)
        ))
    }
}
