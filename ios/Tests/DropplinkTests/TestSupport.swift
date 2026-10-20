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

/// A core wired to fakes: no real network, no real waiting, its own UserDefaults suite.
struct TestHarness {
    let http = FakeHTTPClient()
    let sleeps = Recorder<TimeInterval>()
    let logs = Recorder<String>()
    let defaults: UserDefaults
    let storage: Storage
    let core: DropplinkCore
    let queue = DispatchQueue(label: "dropplink.tests.delivery")

    static let device = DeviceInfo(model: "iPhone15,2", osVersion: "18.1", locale: "en-IN",
                                   timezone: "Asia/Kolkata", screen: .init(w: 1179, h: 2556, dpr: 3))
    static let config = DropplinkConfig(keyId: "ak_3f9c1e2a7b6d4c80", secret: "test-secret", debug: true,
                                        baseURL: URL(string: "https://attribution.test")!)

    init(defaults: UserDefaults? = nil) {
        let suite = "dropplink.tests.\(UUID().uuidString)"
        self.defaults = defaults ?? UserDefaults(suiteName: suite)!
        self.storage = Storage(defaults: self.defaults)
        let sleeps = sleeps
        let logs = logs
        core = DropplinkCore(environment: .init(
            http: http,
            storage: storage,
            deviceInfo: { TestHarness.device },
            appVersion: { "3.2.1" },
            now: { Date(timeIntervalSince1970: 1_760_700_000) },
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
}

enum Fixtures {
    static func initAttributed() throws -> String { try String(decoding: Contract.data("init/response.attributed.json"), as: UTF8.self) }
    static func initOrganic() throws -> String { try String(decoding: Contract.data("init/response.organic.json"), as: UTF8.self) }
    static func deeplinkMatched() throws -> String { try String(decoding: Contract.data("deeplink/response.matched.json"), as: UTF8.self) }
    static func deeplinkNone() throws -> String { try String(decoding: Contract.data("deeplink/response.none.json"), as: UTF8.self) }

    static func error(_ code: String, _ message: String = "message") -> String {
        #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
    }
}
