@testable import ClipperAnalysis
import ClipperCore
import Foundation
import Synchronization
import Testing

// MARK: - Fake worker

/// A tiny JSON-RPC worker in plain Python (stdlib only), run with `/usr/bin/env python3`.
private let fakeWorkerSource = #"""
import json, os, sys, threading, time

out_lock = threading.Lock()
cancelled = set()

def send(msg):
    with out_lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

def handle(msg):
    id, method, params = msg.get("id"), msg["method"], msg.get("params") or {}
    if method == "echo":
        time.sleep(params.get("delay", 0))
        send({"jsonrpc": "2.0", "id": id, "result": params})
    elif method == "pid":
        send({"jsonrpc": "2.0", "id": id, "result": {"pid": os.getpid()}})
    elif method == "progress":
        for i in range(1, 6):
            send({"jsonrpc": "2.0", "method": "progress", "params": {"id": id, "fraction": i / 5, "message": f"step {i}"}})
            time.sleep(0.01)
        send({"jsonrpc": "2.0", "id": id, "result": "done"})
    elif method == "heartbeat":
        for i in range(10):
            time.sleep(0.1)
            send({"jsonrpc": "2.0", "method": "progress", "params": {"id": id, "fraction": i / 10}})
        send({"jsonrpc": "2.0", "id": id, "result": "alive"})
    elif method == "fail":
        send({"jsonrpc": "2.0", "id": id, "error": {"code": -32001, "message": "Music isn't installed",
                                                    "data": {"extra": "music"}}})
    elif method == "sleep":
        end = time.time() + params.get("seconds", 10)
        while time.time() < end:
            if id in cancelled:
                send({"jsonrpc": "2.0", "id": id, "error": {"code": -32800, "message": "Request cancelled"}})
                return
            time.sleep(0.01)
        send({"jsonrpc": "2.0", "id": id, "result": "slept"})
    elif method == "stubborn":
        time.sleep(3600)
    elif method == "cancelled":
        send({"jsonrpc": "2.0", "id": id, "result": sorted(cancelled)})
    elif method == "noise":
        with out_lock:
            sys.stdout.write("this is not json\n")
            sys.stdout.flush()
        send({"jsonrpc": "2.0", "id": id, "result": "ok"})
    elif method == "crash":
        sys.stderr.write("about to crash\n")
        sys.stderr.flush()
        os._exit(3)
    else:
        send({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": f"Method not found: {method}"}})

for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("method") == "$/cancel":
        cancelled.add(msg["params"]["id"])
        sys.stderr.write(f"cancelled {msg['params']['id']}\n")
        sys.stderr.flush()
        continue
    threading.Thread(target=handle, args=(msg,), daemon=True).start()
"""#

private func makeFakeWorker(timeout: Duration = .seconds(20), cancelGrace: Duration = .seconds(5),
                            log: (@Sendable (String) -> Void)? = nil) throws -> PythonWorker {
    let dir = FileManager.default.temporaryDirectory.appending(path: "clipper-fake-worker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appending(path: "fake_worker.py")
    try fakeWorkerSource.write(to: script, atomically: true, encoding: .utf8)
    let launch = PythonWorker.Launch(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                     arguments: ["python3", "-u", script.path], currentDirectory: dir)
    return PythonWorker(launch: launch, defaultTimeout: timeout, cancelGrace: cancelGrace, logHandler: log)
}

private func remoteCode(_ error: any Error) -> Int? {
    if case .remote(let code, _, _) = error as? WorkerError { code } else { nil }
}

// MARK: - JSON-RPC client

@Suite("PythonWorker JSON-RPC client")
struct WorkerTests {
    @Test func matchesConcurrentResponsesToRequests() async throws {
        let worker = try makeFakeWorker()
        // Replies arrive out of order: the first request is the slowest.
        let results = try await withThrowingTaskGroup(of: (Int, JSONValue).self) { group in
            for i in 0..<12 {
                group.addTask {
                    let delay = i == 0 ? 0.3 : 0.01 * Double(i % 3)
                    return (i, try await worker.call("echo", params: ["n": .number(Double(i)), "delay": .number(delay)]))
                }
            }
            var out: [Int: JSONValue] = [:]
            for try await (i, value) in group { out[i] = value }
            return out
        }
        #expect(results.count == 12)
        for (i, value) in results { #expect(value["n"]?.intValue == i) }
        #expect(await worker.launchCount == 1)
        await worker.shutdown()
    }

    @Test func routesProgressNotifications() async throws {
        let worker = try makeFakeWorker()
        let seen = Mutex<[WorkerProgress]>([])
        let result = try await worker.call("progress") { p in seen.withLock { $0.append(p) } }
        #expect(result == "done")
        let fractions = seen.withLock { $0.map(\.fraction) }
        #expect(fractions == [0.2, 0.4, 0.6, 0.8, 1.0])
        #expect(seen.withLock { $0.last?.message } == "step 5")
        await worker.shutdown()
    }

    @Test func surfacesErrorObjects() async throws {
        let worker = try makeFakeWorker()
        do {
            _ = try await worker.call("fail")
            Issue.record("expected an error")
        } catch let error as WorkerError {
            #expect(error.isFeatureNotInstalled)
            guard case let .remote(_, message, data) = error else { Issue.record("wrong error \(error)"); return }
            #expect(message == "Music isn't installed")
            #expect(data?["extra"] == "music")
        }
        await #expect { _ = try await worker.call("nope") } throws: { remoteCode($0) == -32601 }
        // Garbage on stdout is skipped, not fatal.
        #expect(try await worker.call("noise") == "ok")
        #expect(try await worker.call("echo", params: ["x": true])["x"] == true)
        await worker.shutdown()
    }

    @Test func restartsAfterCrash() async throws {
        let worker = try makeFakeWorker()
        let pid1 = try #require(try await worker.call("pid")["pid"]?.intValue)
        do {
            _ = try await worker.call("crash")
            Issue.record("expected a crash error")
        } catch let WorkerError.crashed(status, stderr) {
            #expect(status == 3)
            #expect(stderr.contains("about to crash"))
        }
        let pid2 = try #require(try await worker.call("pid")["pid"]?.intValue)
        #expect(pid1 != pid2)
        #expect(await worker.launchCount == 2)
        await worker.shutdown()
    }

    @Test func timesOutAndSendsCancel() async throws {
        let worker = try makeFakeWorker()
        let pid1 = try await worker.call("pid")["pid"]?.intValue
        let started = ContinuousClock.now
        await #expect(throws: WorkerError.timedOut(method: "sleep", seconds: 0.3)) {
            _ = try await worker.call("sleep", params: ["seconds": 30], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        // The worker got `$/cancel` for request 2 and stays usable (no restart).
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await worker.call("cancelled") == [2])
        #expect(try await worker.call("pid")["pid"]?.intValue == pid1)
        #expect(await worker.launchCount == 1)
        await worker.shutdown()
    }

    @Test func progressKeepsALongRequestAlive() async throws {
        let worker = try makeFakeWorker()
        // 1 s of work, reporting every 100 ms, against a 400 ms silence timeout.
        #expect(try await worker.call("heartbeat", timeout: .milliseconds(400)) == "alive")
        await #expect(throws: WorkerError.timedOut(method: "sleep", seconds: 0.4)) {
            _ = try await worker.call("sleep", params: ["seconds": 30], timeout: .milliseconds(400))
        }
        await worker.shutdown()
    }

    @Test func cancellingTheTaskCancelsTheRequest() async throws {
        let worker = try makeFakeWorker()
        let task = Task { try await worker.call("sleep", params: ["seconds": 30]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await worker.call("cancelled") == [1])
        #expect(await worker.launchCount == 1)
        await worker.shutdown()
    }

    @Test func killsAWorkerThatIgnoresCancel() async throws {
        let worker = try makeFakeWorker(cancelGrace: .milliseconds(300))
        let pid1 = try await worker.call("pid")["pid"]?.intValue
        let task = Task { try await worker.call("stubborn") }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // After the grace period the stuck process is stopped; the next call starts a fresh one.
        try await Task.sleep(for: .milliseconds(800))
        #expect(await worker.isRunning == false)
        let pid2 = try await worker.call("pid")["pid"]?.intValue
        #expect(pid2 != nil && pid2 != pid1)
        #expect(await worker.launchCount == 2)
        await worker.shutdown()
    }

    @Test func shutdownFailsInFlightCallsAndRelaunchesLazily() async throws {
        let logs = Mutex<[String]>([])
        let worker = try makeFakeWorker { line in logs.withLock { $0.append(line) } }
        #expect(await worker.isRunning == false)  // lazy: nothing started yet
        let pid1 = try await worker.call("pid")["pid"]?.intValue
        let task = Task { try await worker.call("stubborn") }
        try await Task.sleep(for: .milliseconds(200))
        await worker.shutdown(grace: .milliseconds(300))
        await #expect(throws: WorkerError.stopped(reason: "shut down")) { _ = try await task.value }
        #expect(await worker.isRunning == false)
        #expect(logs.withLock { $0 }.contains("cancelled 2"))  // in-flight work was told to stop first
        let pid2 = try await worker.call("pid")["pid"]?.intValue
        #expect(pid2 != pid1)
        await worker.shutdown()
    }

    @Test func reportsMissingProjectAndLaunchFailures() async throws {
        let missing = PythonWorker(projectDirectory: URL(fileURLWithPath: "/nonexistent/worker"))
        await #expect(throws: WorkerError.projectNotFound("/nonexistent/worker")) { _ = try await missing.call("ping") }
        let bad = PythonWorker(launch: .init(executable: URL(fileURLWithPath: "/nonexistent/python"), arguments: []))
        await #expect { _ = try await bad.call("ping") } throws: {
            if case .launchFailed = $0 as? WorkerError { true } else { false }
        }
    }

    @Test func findsTheRepoWorkerProject() throws {
        let dir = try #require(PythonWorker.defaultProjectDirectory())
        #expect(dir.lastPathComponent == "worker")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "clipper_worker/__main__.py").path))
    }

    /// The real worker through `uv run`, when it has been set up (`uv sync` in worker/). No model is loaded.
    @Test(.enabled(if: PythonWorker.isUVAvailable()
                   && PythonWorker.defaultProjectDirectory().map {
                       FileManager.default.fileExists(atPath: $0.appending(path: ".venv").path)
                   } == true))
    func realWorkerAnswersPingAndCapabilities() async throws {
        let worker = PythonWorker(projectDirectory: try #require(PythonWorker.defaultProjectDirectory()))
        let ping = try await worker.call("ping", timeout: .seconds(120))
        #expect(ping["version"]?.stringValue != nil)
        #expect(ping["python"]?.stringValue?.hasPrefix("3.") == true)
        let caps = try await worker.call("capabilities")
        #expect(caps["music_generation"]?.boolValue != nil)
        // Bad params are rejected before anything heavy is imported (or the feature is reported missing).
        await #expect {
            _ = try await worker.call("generate_music", params: ["prompt": "x", "duration_s": 1, "out_path": "/tmp/x.wav"])
        } throws: { remoteCode($0) == -32602 || ($0 as? WorkerError)?.isFeatureNotInstalled == true }
        await worker.shutdown()
        #expect(await worker.isRunning == false)
    }
}

// MARK: - Pure helpers

@Suite struct WorkerTestsHelpers {
    @Test func jsonValueRoundTripsBoolsAndNumbers() throws {
        let value: JSONValue = ["a": true, "b": 1, "c": 2.5, "d": nil, "e": ["x", false], "f": "line\nbreak"]
        let data = try value.serialized()
        #expect(!data.contains(0x0A))  // one protocol line
        #expect(try JSONValue.parse(data) == value)
        #expect(value["b"]?.intValue == 1 && value["b"]?.boolValue == nil)
        #expect(value["a"]?.boolValue == true && value["a"]?.intValue == nil)
    }

    @Test func infersMoodsAndGenresFromPrompt() {
        let prompt = "upbeat lo-fi hip hop, warm keys, 90 bpm"
        #expect(MusicMoods.infer(from: prompt) == ["upbeat", "chill"])
        #expect(MusicMoods.genres(in: prompt) == ["lo-fi", "hip hop"])
        #expect(MusicMoods.infer(from: "Dark, ominous orchestral trailer") == ["dark", "mysterious", "cinematic", "intense"])
        #expect(MusicMoods.infer(from: "something") == [])
    }

    @Test func trackIDAndTitleAreStable() {
        let a = MusicGenerator.trackID(prompt: "Lo-fi beat", duration: 30, bpm: 90, seed: 1)
        #expect(a == MusicGenerator.trackID(prompt: "lo-fi beat", duration: 30, bpm: 90.2, seed: 1))
        #expect(a != MusicGenerator.trackID(prompt: "lo-fi beat", duration: 30, bpm: 90, seed: 2))
        #expect(MusicGenerator.title(for: "upbeat lo-fi hip hop, warm keys") == "Upbeat lo-fi hip hop")
    }
}

// MARK: - Live (opt-in)

@Suite struct WorkerTestsLiveMusic {
    /// `CLIPPER_LIVE_MUSIC=1 swift test --filter WorkerTestsLiveMusic` — runs ACE-Step through the real worker
    /// (needs `uv sync --extra music` in worker/; the first run downloads ~10 GB of weights).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_LIVE_MUSIC"] == "1"), .timeLimit(.minutes(60)))
    func generatesTenSecondsOfMusic() async throws {
        let generator = try #require(MusicGenerator.makeDefault(), "uv or worker/ not found")
        let out = FileManager.default.temporaryDirectory.appending(path: "clipper-live-music")
        let last = Mutex<WorkerProgress?>(nil)
        let track = try await generator.generate(prompt: "upbeat lo-fi hip hop, warm keys, 90 bpm", duration: 10, bpm: 90,
                                                 seed: 7, outputDirectory: out) { p in last.withLock { $0 = p } }
        await generator.worker.shutdown()
        #expect(abs(track.duration - 10) <= 1)
        #expect((track.bpm ?? 0) > 0)
        #expect(track.moods == ["upbeat", "chill"])
        guard case .generated(let model) = track.license else { Issue.record("license \(track.license)"); return }
        #expect(model.hasPrefix("ACE-Step 1.5"))
        #expect(FileManager.default.fileExists(atPath: track.url.path))
        #expect(last.withLock { $0?.fraction } == 1)
        print("live music: \(track.title) \(track.duration)s bpm \(track.bpm ?? 0) energy \(track.energy ?? 0) model \(model)")
    }
}
