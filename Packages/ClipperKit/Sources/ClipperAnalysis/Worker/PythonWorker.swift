import ClipperCore
import Foundation
import Synchronization

// Client for Clipper's optional Python worker (`worker/` at the repo root, ADR 0005): a uv project spoken to with
// newline-delimited JSON-RPC 2.0 over stdio. The process starts lazily on the first call and is restarted on the next
// call after it exits or crashes. Nothing in the core app requires it.

/// Progress reported by the worker for one request.
public struct WorkerProgress: Sendable, Equatable {
    /// 0…1.
    public var fraction: Double
    public var message: String?

    public init(fraction: Double, message: String? = nil) { self.fraction = fraction; self.message = message }
}

public enum WorkerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `uv` isn't installed (or not where Clipper looks for it).
    case uvNotFound
    /// The worker project (`worker/pyproject.toml`) wasn't found.
    case projectNotFound(String)
    case launchFailed(String)
    /// The worker answered with a JSON-RPC error object.
    case remote(code: Int, message: String, data: JSONValue?)
    /// The worker exited while the request was in flight. `stderr` is the tail of its log.
    case crashed(status: Int32, stderr: String)
    /// Clipper stopped the worker (shutdown, or a request ignored `$/cancel`) while the request was in flight.
    case stopped(reason: String)
    case timedOut(method: String, seconds: Double)
    /// The worker's reply didn't have the expected shape.
    case badResponse(String)

    /// JSON-RPC code the worker uses when an optional feature (pip extra) isn't installed.
    public static let featureNotInstalledCode = -32001
    public static let cancelledCode = -32800

    public var isFeatureNotInstalled: Bool {
        if case .remote(let code, _, _) = self { code == Self.featureNotInstalledCode } else { false }
    }

    public var description: String {
        switch self {
        case .uvNotFound:
            "uv isn't installed. Install it with `brew install uv` (or see https://docs.astral.sh/uv/) to enable "
                + "Clipper's optional Python features."
        case .projectNotFound(let path):
            "Clipper's Python worker wasn't found (\(path)). Set CLIPPER_WORKER_DIR to the `worker` directory."
        case .launchFailed(let why): "Couldn't start the Python worker: \(why)"
        case let .remote(_, message, _): message
        case let .crashed(status, stderr):
            "The Python worker exited unexpectedly (status \(status))."
                + (stderr.isEmpty ? "" : " Last output:\n\(stderr)")
        case .stopped(let reason): "The Python worker was stopped: \(reason)."
        case let .timedOut(method, seconds): "The Python worker didn't answer `\(method)` within \(Int(seconds)) s."
        case .badResponse(let why): "Unexpected reply from the Python worker: \(why)"
        }
    }
}

public actor PythonWorker {
    /// How to start the worker process.
    public struct Launch: Sendable, Equatable {
        public var executable: URL
        public var arguments: [String]
        /// Added to (and overriding) the inherited environment.
        public var environment: [String: String]
        public var currentDirectory: URL?

        public init(executable: URL, arguments: [String], environment: [String: String] = [:], currentDirectory: URL? = nil) {
            self.executable = executable; self.arguments = arguments
            self.environment = environment; self.currentDirectory = currentDirectory
        }
    }

    public typealias ProgressHandler = @Sendable (WorkerProgress) -> Void

    private enum Source {
        case project(directory: URL, extras: [String], uv: URL?, environment: [String: String])
        case custom(Launch)
    }

    private struct Pending {
        var method: String
        var generation: Int
        var continuation: CheckedContinuation<JSONValue, any Error>
        var progress: ProgressHandler?
        /// Longest silence (no reply, no progress) allowed for this request.
        var limit: Duration
        var timer: Task<Void, Never>?
    }

    private struct Running {
        var process: Process
        var stdin: FileHandle
        var generation: Int
        var stdoutClosed = false
        var exitStatus: Int32?
        /// Why Clipper is stopping this process (nil while it's healthy).
        var stopReason: String?
    }

    private let source: Source
    /// Longest silence (no reply, no progress) allowed for a call that isn't given a timeout.
    public var defaultTimeout: Duration
    /// After `$/cancel` (task cancellation or timeout), how long the worker may take to acknowledge before Clipper
    /// kills it (it restarts on the next call).
    public var cancelGrace: Duration
    /// Receives each stderr line of the worker (its log).
    private let logHandler: (@Sendable (String) -> Void)?

    private var running: Running?
    private var generation = 0
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    /// Requests the caller gave up on (cancelled / timed out) that the worker hasn't answered yet.
    private var abandoned: [Int: Int] = [:]  // id → generation
    private let stderrTail = StderrTail()

    /// Number of processes launched so far (a restart after a crash increments it).
    public private(set) var launchCount = 0
    public var isRunning: Bool { running.map { $0.process.isRunning && $0.stopReason == nil } ?? false }
    public var processIdentifier: Int32? { running?.process.processIdentifier }

    /// Runs `uv run --project <projectDirectory> [--extra …] python -m clipper_worker`.
    /// - Parameters:
    ///   - extras: optional-dependency groups to install/enable (e.g. `["music"]`). uv installs missing ones on launch.
    ///   - uv: path to the `uv` binary; found on PATH and in the usual Homebrew / installer locations when nil.
    ///   - environment: extra environment for the worker (e.g. `CLIPPER_MODELS`).
    public init(projectDirectory: URL, extras: [String] = [], uv: URL? = nil, environment: [String: String] = [:],
                defaultTimeout: Duration = .seconds(120), cancelGrace: Duration = .seconds(5),
                logHandler: (@Sendable (String) -> Void)? = nil) {
        source = .project(directory: projectDirectory, extras: extras, uv: uv, environment: environment)
        self.defaultTimeout = defaultTimeout; self.cancelGrace = cancelGrace; self.logHandler = logHandler
    }

    /// Runs an arbitrary command that speaks the same protocol (tests, custom environments).
    public init(launch: Launch, defaultTimeout: Duration = .seconds(120), cancelGrace: Duration = .seconds(5),
                logHandler: (@Sendable (String) -> Void)? = nil) {
        source = .custom(launch)
        self.defaultTimeout = defaultTimeout; self.cancelGrace = cancelGrace; self.logHandler = logHandler
    }

    deinit {
        if let running, running.process.isRunning { running.process.terminate() }
    }

    // MARK: Discovery

    /// Where uv is commonly installed; GUI apps don't inherit the shell's PATH.
    static let uvSearchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.cargo/bin"]

    public static func findUV() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in path + uvSearchDirectories {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appending(path: "uv")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static func isUVAvailable() -> Bool { findUV() != nil }

    /// The `worker/` project: `$CLIPPER_WORKER_DIR`, else `Contents/Resources/worker` in the app bundle, else the
    /// first `worker/pyproject.toml` found walking up from the executable (or from this source file in dev builds).
    public static func defaultProjectDirectory() -> URL? {
        let fm = FileManager.default
        func isProject(_ url: URL) -> Bool { fm.fileExists(atPath: url.appending(path: "pyproject.toml").path) }

        if let env = ProcessInfo.processInfo.environment["CLIPPER_WORKER_DIR"], !env.isEmpty {
            let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            return isProject(url) ? url : nil
        }
        if let resources = Bundle.main.resourceURL?.appending(path: "worker"), isProject(resources) { return resources }
        let starts = [Bundle.main.executableURL?.resolvingSymlinksInPath(), URL(fileURLWithPath: #filePath)]
        for start in starts.compactMap(\.self) {
            var dir = start.deletingLastPathComponent()
            while dir.pathComponents.count > 1 {
                let candidate = dir.appending(path: "worker")
                if isProject(candidate) { return candidate }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    private func makeLaunch() throws -> Launch {
        switch source {
        case .custom(let launch): return launch
        case let .project(directory, extras, uv, environment):
            guard FileManager.default.fileExists(atPath: directory.appending(path: "pyproject.toml").path) else {
                throw WorkerError.projectNotFound(directory.path)
            }
            guard let uv = uv ?? Self.findUV() else { throw WorkerError.uvNotFound }
            // --frozen: run from uv.lock without re-resolving (no network unless an extra still needs installing).
            var args = ["run", "--project", directory.path, "--frozen", "--quiet"]
            for extra in extras { args += ["--extra", extra] }
            args += ["python", "-m", "clipper_worker"]
            return Launch(executable: uv, arguments: args, environment: environment, currentDirectory: directory)
        }
    }

    // MARK: Calls

    /// Sends a request and waits for its result.
    /// - Parameters:
    ///   - timeout: overrides `defaultTimeout`. It bounds *silence*, not total time: each `progress` notification for
    ///     this request restarts it, so long jobs that keep reporting never time out but a hung worker does. On timeout
    ///     the worker is sent `$/cancel` and the call throws `.timedOut`.
    ///   - progress: receives the worker's `progress` notifications for this request (on an arbitrary thread).
    /// - Throws: `WorkerError`, or `CancellationError` when the calling task is cancelled (the worker gets `$/cancel`).
    public func call(_ method: String, params: JSONValue = [:], timeout: Duration? = nil,
                     progress: ProgressHandler? = nil) async throws -> JSONValue {
        try Task.checkCancellation()
        try ensureRunning()
        guard let generation = running?.generation else { throw WorkerError.launchFailed("no process") }
        let id = nextID
        nextID += 1
        let limit = timeout ?? defaultTimeout
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, any Error>) in
                pending[id] = Pending(method: method, generation: generation, continuation: cont, progress: progress,
                                      limit: limit)
                armTimer(id)
                do {
                    try write(message)
                } catch {
                    finish(id, with: .failure(error))
                }
            }
        } onCancel: {
            Task { await self.abandon(id, error: CancellationError()) }
        }
    }

    /// Sends a notification (no reply expected).
    public func notify(_ method: String, params: JSONValue = [:]) throws {
        try write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    /// Stops the worker: cancels in-flight requests, closes its stdin, and escalates to SIGTERM / SIGKILL if it
    /// doesn't exit. A later `call` starts a new process.
    public func shutdown(grace: Duration = .seconds(3)) async {
        guard var current = running else { return }
        for (id, p) in pending where p.generation == current.generation {
            try? notify("$/cancel", params: ["id": .number(Double(id))])
        }
        current.stopReason = "shut down"
        running = current
        try? current.stdin.close()
        let process = current.process
        if await !Self.waitForExit(process, timeout: grace) {
            process.terminate()
            if await !Self.waitForExit(process, timeout: .seconds(2)) {
                kill(process.processIdentifier, SIGKILL)
                _ = await Self.waitForExit(process, timeout: .seconds(2))
            }
        }
        // Normally the termination handler does this; make sure pending calls never hang.
        failPending(generation: current.generation, error: WorkerError.stopped(reason: "shut down"))
        if running?.generation == current.generation { running = nil }
    }

    // MARK: Process lifecycle

    private func ensureRunning() throws {
        if let running, running.process.isRunning, running.stopReason == nil, running.exitStatus == nil { return }
        try start()
    }

    private func start() throws {
        let launch = try makeLaunch()
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // uv and Python live outside a GUI app's minimal PATH.
        env["PATH"] = ([launch.executable.deletingLastPathComponent().path] + (env["PATH"].map { [$0] } ?? [])
            + ["/usr/bin", "/bin"]).joined(separator: ":")
        env.merge(launch.environment) { _, new in new }
        process.environment = env
        if let dir = launch.currentDirectory { process.currentDirectoryURL = dir }

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Writing to a dead worker must fail with EPIPE, not kill Clipper with SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        generation += 1
        let gen = generation
        stderrTail.reset()

        let (lines, linesContinuation) = AsyncStream<Data>.makeStream()
        let stdoutSplitter = LineSplitter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                for line in stdoutSplitter.finish() { linesContinuation.yield(line) }
                linesContinuation.finish()
            } else {
                for line in stdoutSplitter.append(data) { linesContinuation.yield(line) }
            }
        }
        let stderrSplitter = LineSplitter()
        let tail = stderrTail, log = logHandler
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let chunk = data.isEmpty ? stderrSplitter.finish() : stderrSplitter.append(data)
            if data.isEmpty { handle.readabilityHandler = nil }
            for line in chunk {
                let text = String(decoding: line, as: UTF8.self)
                tail.append(text)
                log?(text)
            }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.processExited(generation: gen, status: status) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            linesContinuation.finish()
            throw WorkerError.launchFailed("\(launch.executable.path): \(error.localizedDescription)")
        }
        // Our copies of the child's ends must be closed so EOF is seen when the child exits.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        running = Running(process: process, stdin: stdinPipe.fileHandleForWriting, generation: gen)
        launchCount += 1

        Task { [weak self] in
            for await line in lines { await self?.receive(line) }
            await self?.stdoutClosed(generation: gen)
        }
    }

    private func write(_ message: JSONValue) throws {
        guard let running, running.stopReason == nil else { throw WorkerError.stopped(reason: "not running") }
        var data = try message.serialized()
        data.append(0x0A)
        do {
            try running.stdin.write(contentsOf: data)
        } catch {
            throw WorkerError.crashed(status: running.exitStatus ?? -1, stderr: stderrTail.text)
        }
    }

    private func processExited(generation gen: Int, status: Int32) {
        guard running?.generation == gen else { failPending(generation: gen, error: exitError(gen, status)); return }
        running?.exitStatus = status
        finalizeIfDone(gen)
    }

    private func stdoutClosed(generation gen: Int) {
        guard running?.generation == gen else { return }
        running?.stdoutClosed = true
        finalizeIfDone(gen)
    }

    /// The process is gone once it has exited *and* every reply it wrote has been read.
    private func finalizeIfDone(_ gen: Int) {
        guard let current = running, current.generation == gen, current.stdoutClosed,
              let status = current.exitStatus else { return }
        failPending(generation: gen, error: exitError(gen, status))
        abandoned = abandoned.filter { $0.value != gen }
        try? current.stdin.close()
        running = nil
    }

    private func exitError(_ gen: Int, _ status: Int32) -> WorkerError {
        if let reason = running?.generation == gen ? running?.stopReason : nil { return .stopped(reason: reason) }
        return .crashed(status: status, stderr: stderrTail.text)
    }

    private func failPending(generation gen: Int, error: any Error) {
        for (id, p) in pending where p.generation == gen { finish(id, with: .failure(error)) }
    }

    // MARK: Messages

    private func receive(_ line: Data) {
        guard let message = try? JSONValue.parse(line), message["jsonrpc"]?.stringValue == "2.0" else {
            // Something wrote to the protocol stream; the worker redirects library output, so this is a bug there.
            let text = String(decoding: line.prefix(300), as: UTF8.self)
            logHandler?("[stdout, not JSON-RPC] \(text)")
            return
        }
        if let method = message["method"]?.stringValue {
            if method == "progress", let params = message["params"], let id = params["id"]?.intValue, pending[id] != nil {
                armTimer(id)  // the request is alive: restart its silence timeout
                if let handler = pending[id]?.progress, let fraction = params["fraction"]?.doubleValue {
                    handler(WorkerProgress(fraction: min(max(fraction, 0), 1), message: params["message"]?.stringValue))
                }
            }
            return
        }
        guard let id = message["id"]?.intValue else {
            if let error = message["error"] { logHandler?("[worker error without id] \(error)") }
            return
        }
        if abandoned.removeValue(forKey: id) != nil { return }  // answered after the caller gave up: fine
        if let error = message["error"] {
            finish(id, with: .failure(WorkerError.remote(code: error["code"]?.intValue ?? -32603,
                                                         message: error["message"]?.stringValue ?? "\(error)",
                                                         data: error["data"])))
        } else {
            finish(id, with: .success(message["result"] ?? .null))
        }
    }

    /// (Re)starts the request's timeout: it fires after `limit` without a reply or a progress notification.
    private func armTimer(_ id: Int) {
        guard let p = pending[id] else { return }
        p.timer?.cancel()
        let limit = p.limit, method = p.method
        pending[id]?.timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            await self?.abandon(id, error: WorkerError.timedOut(method: method, seconds: limit.seconds))
        }
    }

    private func finish(_ id: Int, with result: Result<JSONValue, any Error>) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timer?.cancel()
        p.continuation.resume(with: result)
    }

    /// The caller stopped waiting (task cancelled or timed out): fail the call now, tell the worker to stop, and kill
    /// the worker if it hasn't acknowledged within `cancelGrace`.
    private func abandon(_ id: Int, error: any Error) {
        guard let p = pending[id] else { return }
        finish(id, with: .failure(error))
        guard let current = running, current.generation == p.generation, current.stopReason == nil else { return }
        abandoned[id] = p.generation
        try? notify("$/cancel", params: ["id": .number(Double(id))])
        let grace = cancelGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.graceExpired(id, generation: p.generation, method: p.method)
        }
    }

    private func graceExpired(_ id: Int, generation gen: Int, method: String) {
        guard abandoned.removeValue(forKey: id) != nil, var current = running, current.generation == gen,
              current.stopReason == nil else { return }
        current.stopReason = "`\(method)` didn't stop after cancellation; the worker will restart on the next call"
        running = current
        logHandler?("[client] \(current.stopReason!)")
        current.process.terminate()
        let pid = current.process.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(2))
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

// MARK: - Helpers

/// Splits a byte stream into lines (without the trailing newline). Called serially from one readability handler.
private final class LineSplitter: Sendable {
    private let buffer = Mutex(Data())

    func append(_ data: Data) -> [Data] {
        buffer.withLock { buffer in
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }

    func finish() -> [Data] {
        buffer.withLock { buffer in
            defer { buffer.removeAll() }
            return buffer.isEmpty ? [] : [buffer]
        }
    }
}

/// The last lines the worker wrote to stderr, for crash reports.
private final class StderrTail: Sendable {
    private static let limit = 40
    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock {
            $0.append(line)
            if $0.count > Self.limit { $0.removeFirst($0.count - Self.limit) }
        }
    }

    func reset() { lines.withLock { $0.removeAll() } }
    var text: String { lines.withLock { $0.joined(separator: "\n") } }
}
