import Foundation
import Network
import Synchronization

/// A parsed HTTP/1.1 request received by `LoopbackHTTPServer`.
struct HTTPServerRequest: Sendable {
    var method: String
    /// Path without the query, e.g. "/callback".
    var path: String
    var query: [URLQueryItem]
    /// Header names lower-cased.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    func queryValue(_ name: String) -> String? { query.first { $0.name == name }?.value }
}

struct HTTPServerResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
    static func json(_ object: Any, status: Int = 200) -> HTTPServerResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPServerResponse(status: status, headers: [("Content-Type", "application/json; charset=UTF-8")], body: data)
    }
    static func html(_ text: String, status: Int = 200) -> HTTPServerResponse {
        HTTPServerResponse(status: status, headers: [("Content-Type", "text/html; charset=utf-8")], body: Data(text.utf8))
    }
}

/// A minimal HTTP/1.1 server bound to 127.0.0.1 on an ephemeral port (Network.framework). One request per connection
/// (`Connection: close`), bodies by `Content-Length` only. Used for the OAuth loopback redirect and, in tests, as the mock
/// for the platform APIs. Never listens on a public interface.
final class LoopbackHTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPServerRequest) async -> HTTPServerResponse

    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.yashjain.clipper.publish.loopback")
    private let state = Mutex<(listener: NWListener?, connections: [ObjectIdentifier: NWConnection])>((nil, [:]))
    /// Bodies above this are rejected (413); the largest legitimate body is one upload chunk.
    let maxBodySize: Int

    init(maxBodySize: Int = 256 << 20, handler: @escaping Handler) {
        self.handler = handler
        self.maxBodySize = maxBodySize
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        state.withLock { $0.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let resumed = Mutex(false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { newState in
                let result: Result<UInt16, Error>?
                switch newState {
                case .ready:
                    if let port = listener.port?.rawValue { result = .success(port) }
                    else { result = .failure(LoopbackServerError.noPort) }
                case .failed(let error): result = .failure(error)
                case .cancelled: result = .failure(LoopbackServerError.cancelled)
                default: result = nil
                }
                guard let result, resumed.withLock({ old in defer { old = true }; return !old }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
    }

    /// Stops accepting connections. Open connections get a short grace period so a response being written (e.g. the
    /// "you can close this window" page) still reaches the browser; idle ones (browser pre-connects) are then closed.
    func stop() {
        let (listener, connections) = state.withLock { s in
            defer { s.listener = nil; s.connections = [:] }
            return (s.listener, Array(s.connections.values))
        }
        listener?.cancel()
        guard !connections.isEmpty else { return }
        queue.asyncAfter(deadline: .now() + 2) { connections.forEach { $0.cancel() } }
    }

    deinit { stop() }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        state.withLock { $0.connections[id] = connection }
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled: self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let content { buffer.append(content) }
            switch Self.parse(buffer, maxBodySize: self.maxBodySize) {
            case .complete(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    Self.send(response, on: connection)
                }
            case .invalid(let status):
                Self.send(HTTPServerResponse(status: status), on: connection)
            case .needMore:
                if error != nil || isComplete { connection.cancel(); return }
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private static func send(_ response: HTTPServerResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        var headers = response.headers
        if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
            headers.append(("Content-Length", String(response.body.count)))
        }
        headers.append(("Connection", "close"))
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Parsing

    enum ParseResult { case needMore, complete(HTTPServerRequest), invalid(Int) }

    static func parse(_ buffer: Data, maxBodySize: Int) -> ParseResult {
        // Headers must fit in the first 64 KiB; only that much is scanned per call, so large bodies stay linear.
        guard let headerEnd = buffer.prefix(64 << 10).firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 << 10 ? .invalid(431) : .needMore
        }
        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(411) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(400) }
        guard length <= maxBodySize else { return .invalid(413) }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .needMore }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        let components = URLComponents(string: "http://127.0.0.1" + (target.hasPrefix("/") ? target : "/" + target))
        return .complete(HTTPServerRequest(method: String(requestLine[0]), path: components?.path ?? target,
                                           query: components?.queryItems ?? [], headers: headers, body: body))
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 206: "Partial Content"
        case 302: "Found"
        case 308: "Resume Incomplete"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

enum LoopbackServerError: Error, Sendable { case noPort, cancelled }
