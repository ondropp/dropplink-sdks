import Foundation
import XCTest
@testable import Dropplink

/// The repo's single copy of the wire contract: `<repo>/contract`, found relative to this file.
enum Contract {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DropplinkTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repo
        .appendingPathComponent("contract")

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    static func json(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data(path)) as? [String: Any], path)
    }
}

/// Scripted HTTP layer. Each call to `send` pops the next scripted reply for the request's path;
/// the last reply repeats once the script runs out.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    // @unchecked: all state is guarded by `lock`.
    enum Reply {
        case status(Int, String)
        case retryAfter(Int, String, TimeInterval)
        case networkError
    }

    private let lock = NSLock()
    private var scripts: [String: [Reply]] = [:]
    private var recorded: [URLRequest] = []

    func script(_ path: String, _ replies: Reply...) {
        lock.lock(); defer { lock.unlock() }
        scripts[path] = replies
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let reply: Reply = {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            let path = request.url?.path ?? ""
            var script = scripts[path] ?? [.status(404, #"{"error":{"code":"not_found","message":"no script"}}"#)]
            let next = script.count > 1 ? script.removeFirst() : script[0]
            scripts[path] = script
            return next
        }()
        switch reply {
        case .networkError:
            throw URLError(.notConnectedToInternet)
        case .status(let code, let body):
            return HTTPResponse(statusCode: code, body: Data(body.utf8))
        case .retryAfter(let code, let body, let seconds):
            return HTTPResponse(statusCode: code, body: Data(body.utf8), retryAfter: seconds)
        }
    }
}

/// Thread-safe recorder for values produced on background threads (sleeps, log lines).
final class Recorder<Value>: @unchecked Sendable {
    // @unchecked: all state is guarded by `lock`.
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    // @unchecked: all state is guarded by `lock`.
    private let lock = NSLock()
    private var current: Date

    init(_ seconds: TimeInterval = 1_760_700_000) {
        current = Date(timeIntervalSince1970: seconds)
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current += seconds
    }
}

/// Holds scheduled work until a test runs it, so debounce and backoff timers are deterministic.
final class ManualScheduler: Scheduler, @unchecked Sendable {
    // @unchecked: all state is guarded by `lock`.
    final class Work: ScheduledWork, @unchecked Sendable {
        let delay: TimeInterval
        let run: @Sendable () -> Void
        private let lock = NSLock()
        private var cancelled = false

        init(delay: TimeInterval, run: @escaping @Sendable () -> Void) {
            self.delay = delay
            self.run = run
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }
    }

    private let lock = NSLock()
    private var scheduled: [Work] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> ScheduledWork {
        let item = Work(delay: delay, run: work)
        lock.lock(); defer { lock.unlock() }
        scheduled.append(item)
        return item
    }

    /// Delays of the work that is still waiting (not run, not cancelled), oldest first.
    var pending: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return scheduled.filter { !$0.isCancelled }.map(\.delay)
    }

    /// Runs everything waiting now (not what that schedules). Returns how many ran.
    @discardableResult
    func runPending() -> Int {
        let due: [Work] = {
            lock.lock(); defer { lock.unlock() }
            defer { scheduled = [] }
            return scheduled.filter { !$0.isCancelled }
        }()
        due.forEach { $0.run() }
        return due.count
    }
}

/// A core wired to fakes: no real network, no real waiting, its own UserDefaults suite and queue file.
struct TestHarness {
    let http = FakeHTTPClient()
    let sleeps = Recorder<TimeInterval>()
    let logs = Recorder<String>()
    let scheduler = ManualScheduler()
    let clock: TestClock
    let defaults: UserDefaults
    let storage: Storage
    let queueFile: URL
    let core: DropplinkCore
    let queue = DispatchQueue(label: "dropplink.tests.delivery")

    /// The contract fixture's key (`init/request.ios.json`); tests never touch the real Keychain.
    static let reinstallKey = "5f2c9a7e-1b3d-4e6f-8a0b-2c4d6e8f0a1b"
    static let device = DeviceInfo(model: "iPhone15,2", osVersion: "18.1", locale: "en-IN",
                                   timezone: "Asia/Kolkata", screen: .init(w: 1179, h: 2556, dpr: 3))
    static let config = DropplinkConfig(keyId: "ak_3f9c1e2a7b6d4c80", secret: "test-secret", debug: true,
                                        baseURL: URL(string: "https://attribution.test")!)

    /// Pass another harness's `defaults` and `queueFile` to simulate an app restart.
    init(defaults: UserDefaults? = nil, queueFile: URL? = nil, clock: TestClock = TestClock()) {
        let suite = "dropplink.tests.\(UUID().uuidString)"
        self.defaults = defaults ?? UserDefaults(suiteName: suite)!
        self.storage = Storage(defaults: self.defaults)
        self.queueFile = queueFile ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("dropplink-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(QueueFileStore.fileName)
        self.clock = clock
        let sleeps = sleeps
        let logs = logs
        core = DropplinkCore(environment: .init(
            http: http,
            storage: storage,
            queueStore: QueueFileStore(url: self.queueFile),
            scheduler: scheduler,
            deviceInfo: { TestHarness.device },
            appVersion: { "3.2.1" },
            reinstallKey: { TestHarness.reinstallKey },
            now: { clock.now },
            sleep: { sleeps.append($0) },
            random: { 0.5 }, // no jitter
            deliveryQueue: queue,
            logSink: { _, line in logs.append(line) }
        ))
    }

    /// Runs init and waits for it, including any queued deep links it sends afterwards.
    func initialize(_ config: DropplinkConfig = TestHarness.config) async {
        await core.initialize(config: config)?.value
    }

    /// Waits until everything already handed to the delivery queue has run.
    func drainDeliveries() {
        queue.sync {}
    }

    var events: EventPipeline { core.events }

    /// Applies queued `track` / `identify` calls and writes the file.
    func drainEvents() {
        events.drain()
    }

    /// Fires the waiting timers (debounce, backoff) and waits for the flush they start.
    func fireTimers() async {
        drainEvents()
        scheduler.runPending()
        await events.waitUntilIdle()
        drainEvents()
    }

    /// Paths of the requests sent so far, e.g. `["/v1/init", "/v1/events"]`.
    var paths: [String] { http.requests.compactMap { $0.url?.path } }

    func bodies(to path: String) -> [[String: Any]] {
        http.requests(to: path).compactMap { request in
            request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }
}

enum Fixtures {
    static func initAttributed() throws -> String { try String(decoding: Contract.data("init/response.attributed.json"), as: UTF8.self) }
    static func initOrganic() throws -> String { try String(decoding: Contract.data("init/response.organic.json"), as: UTF8.self) }
    static func deeplinkMatched() throws -> String { try String(decoding: Contract.data("deeplink/response.matched.json"), as: UTF8.self) }
    static func deeplinkNone() throws -> String { try String(decoding: Contract.data("deeplink/response.none.json"), as: UTF8.self) }

    static func eventsOK(accepted: Int) -> String {
        #"{"accepted":\#(accepted),"duplicates":0,"rejected":[],"warnings":[]}"#
    }

    static func identifyOK() throws -> String { try String(decoding: Contract.data("identify/response.json"), as: UTF8.self) }

    static func error(_ code: String, _ message: String = "message") -> String {
        #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
    }
}
