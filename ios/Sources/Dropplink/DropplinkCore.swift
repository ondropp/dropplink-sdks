import Foundation

/// Everything behind the `Dropplink` facade: lifecycle (spec §3), deep link resolution (§7) and state.
/// Events and identify (§11) live in `events`, which this type starts and re-inits for.
///
/// One instance per process in the app (`Dropplink.core`); tests create their own with fakes.
final class DropplinkCore: @unchecked Sendable {
    // @unchecked: every mutable property below is read and written only while holding `lock`.
    // A lock (not an actor) because `installId` and `attribution` are synchronous public getters.

    /// The outside world, injectable for tests.
    struct Environment: Sendable {
        var http: HTTPClient
        var storage: Storage
        var queueStore: QueueFileStore
        /// Debounce and backoff timers of the event queue.
        var scheduler: Scheduler
        var deviceInfo: @Sendable () async -> DeviceInfo
        var appVersion: @Sendable () -> String
        /// The Keychain reinstall key, or `nil` when the Keychain isn't available.
        var reinstallKey: @Sendable () -> String?
        var now: @Sendable () -> Date
        var sleep: @Sendable (TimeInterval) async -> Void
        var random: @Sendable () -> Double
        var deliveryQueue: DispatchQueue
        var logSink: (@Sendable (Log.Level, String) -> Void)?

        static func live() -> Environment {
            Environment(
                http: URLSessionHTTPClient(),
                storage: .live(),
                queueStore: .live(),
                scheduler: DispatchScheduler(),
                deviceInfo: { await DeviceInfo.current() },
                appVersion: { currentAppVersion() },
                reinstallKey: { ReinstallKey.loadOrCreate() },
                now: { Date() },
                sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                random: { Double.random(in: 0...1) },
                deliveryQueue: .main,
                logSink: nil
            )
        }
    }

    private enum State {
        case notStarted
        case initializing
        case ready
        /// Bad config, or the server rejected the key. Nothing more is sent this launch.
        case disabled
    }

    /// Deep links reported before init finishes. Bounded so a misbehaving caller can't grow it forever.
    private static let maxQueuedURLs = 10

    let dispatcher: DeepLinkDispatcher
    let events: EventPipeline
    private let environment: Environment
    private let lock = NSLock()

    private var state = State.notStarted
    private var api: APIClient?
    private var log: Log
    private var currentInstallId: String?
    /// Loaded from storage on first read, so merely referencing `Dropplink` doesn't touch disk.
    private var cachedAttribution: Attribution?
    private var queuedURLs: [URL] = []

    init(environment: Environment) {
        self.environment = environment
        self.dispatcher = DeepLinkDispatcher(deliveryQueue: environment.deliveryQueue)
        self.events = EventPipeline(
            storage: environment.storage, store: environment.queueStore, scheduler: environment.scheduler,
            now: environment.now, random: environment.random, logSink: environment.logSink
        )
        self.log = Log(enabled: false, sink: environment.logSink)
    }

    // MARK: Public surface

    var installId: String? {
        lock.locked { currentInstallId }
    }

    var attribution: Attribution? {
        lock.locked {
            if cachedAttribution == nil { cachedAttribution = environment.storage.attribution }
            return cachedAttribution
        }
    }

    /// Returns the background init task (tests await it), or `nil` when the call was ignored.
    @discardableResult
    func initialize(config: DropplinkConfig) -> Task<Void, Never>? {
        let log = Log(enabled: config.debug, sink: environment.logSink)

        let accepted: APIClient? = lock.locked {
            guard state == .notStarted else { return nil }
            self.log = log
            if let problem = config.validationError {
                state = .disabled
                queuedURLs = []
                log.configError("invalid config, SDK disabled: \(problem)")
                return nil
            }
            state = .initializing
            let api = APIClient(
                config: config, http: environment.http, retryPolicy: RetryPolicy(), log: log,
                now: environment.now, sleep: environment.sleep, random: environment.random
            )
            self.api = api
            // UserDefaults is an in-memory cache after first access, so this is cheap enough to do on
            // the caller's thread, and it makes `installId` available as soon as `initialize` returns.
            currentInstallId = environment.storage.loadOrCreateInstallId()
            return api
        }
        guard let api = accepted, let installId else {
            if config.validationError == nil { log.info("initialize called again; ignored") }
            return nil
        }
        events.configure(api: api, installId: installId) { [weak self] in
            await self?.reinitialize() ?? false
        }
        return Task.detached(priority: .utility) { [self] in
            await runInit(config: config)
        }
    }

    /// Returns the task resolving `url` (tests await it), or `nil` when the URL was queued or ignored.
    @discardableResult
    func handleDeepLink(_ url: URL) -> Task<Void, Never>? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            currentLog.info("ignoring non-http(s) URL \(url.absoluteString)")
            return nil
        }
        let sendNow: Bool = lock.locked {
            switch state {
            case .notStarted, .initializing:
                // The install must exist on the server before its deep link opens are reported.
                queuedURLs.append(url)
                if queuedURLs.count > Self.maxQueuedURLs { queuedURLs.removeFirst() }
                return false
            case .ready:
                return true
            case .disabled:
                return false
            }
        }
        guard sendNow else { return nil }
        return Task.detached(priority: .userInitiated) { [self] in
            await resolveDeepLink(url)
        }
    }

    // MARK: Lifecycle

    private var currentLog: Log { lock.locked { log } }

    private func runInit(config: DropplinkConfig) async {
        guard let api = lock.locked({ api }), let installId = installId else { return }
        let log = api.log
        log.info("install id \(installId) (paste into Dropplink → Install debugger)")

        guard let bytes = await initBody(installId: installId, config: config) else {
            log.error("could not encode the init body")
            await finishInit(disable: false)
            return
        }

        switch await api.post("v1/init", body: bytes) {
        case .success(let data):
            handleInitResponse(data, log: log)
            await finishInit(disable: false)
            // After the deep links, which the user is waiting for; events can wait a moment.
            await events.initDidSucceed()?.value
        case .failed(let disable):
            await finishInit(disable: disable)
        }
    }

    private func initBody(installId: String, config: DropplinkConfig) async -> Data? {
        let body = InitBody(
            installId: installId,
            appVersion: environment.appVersion(),
            sdkVersion: config.sdkVersion,
            device: await environment.deviceInfo(),
            reinstallKey: environment.reinstallKey()
        )
        return try? APIClient.makeEncoder().encode(body)
    }

    /// `/v1/events` or `/v1/identify` said `404 unknown_install`: sends `/v1/init` again (with the
    /// usual §5 retries) so the server knows the install. Returns whether it succeeded.
    private func reinitialize() async -> Bool {
        guard let (api, installId) = lock.locked({ () -> (APIClient, String)? in
            guard state == .ready, let api, let currentInstallId else { return nil }
            return (api, currentInstallId)
        }), let bytes = await initBody(installId: installId, config: api.config) else { return false }

        switch await api.post("v1/init", body: bytes) {
        case .success(let data):
            handleInitResponse(data, log: api.log)
            return true
        case .failed(let disable):
            if disable { disableAfterInvalidKey() }
            return false
        }
    }

    /// The key is unusable: nothing more is sent this launch, deep links or events.
    private func disableAfterInvalidKey() {
        lock.locked { state = .disabled }
        events.stopUntilNextLaunch()
    }

    private func handleInitResponse(_ data: Data, log: Log) {
        guard let response = try? JSONDecoder().decode(InitResponse.self, from: data) else {
            log.error("init 200 with a response this SDK can't read")
            return
        }
        let attribution = response.attribution
        let storage = environment.storage
        lock.locked {
            cachedAttribution = attribution
            storage.attribution = attribution
            if attribution.isAttributed { storage.attributed = true }
        }

        var summary = "init 200 \(attribution.type)"
        if attribution.isAttributed { summary += " via \(attribution.method)" }
        if let linkId = attribution.linkId { summary += ", link \(linkId)" }
        if let path = response.deepLink?.path { summary += ", deep link \(path)" }
        log.info(summary)

        // Delivered once and never stored: the server sends it at most once per install.
        if let link = response.deepLink {
            dispatcher.dispatch(DeepLink(path: link.path, params: link.params ?? [:], url: nil, isDeferred: true))
        }
    }

    /// Moves to `ready` (or `disabled`) and sends the deep links that were waiting for init.
    /// Sent in order, on the init task, so they reach the server after the install exists.
    private func finishInit(disable: Bool) async {
        let queued: [URL] = lock.locked {
            state = disable ? .disabled : .ready
            defer { queuedURLs = [] }
            return disable ? [] : queuedURLs
        }
        if disable { events.stopUntilNextLaunch() }
        for url in queued { await resolveDeepLink(url) }
    }

    // MARK: Deep links

    private func resolveDeepLink(_ url: URL) async {
        guard let (api, installId) = lock.locked({ () -> (APIClient, String)? in
            guard state == .ready, let api, let currentInstallId else { return nil }
            return (api, currentInstallId)
        }) else { return }
        let log = api.log

        let urlString = url.absoluteString
        guard urlString.utf16.count <= 2048 else {
            log.error("deep link URL longer than 2048 characters; ignored")
            return
        }
        guard let bytes = try? APIClient.makeEncoder().encode(DeepLinkRequest(installId: installId, url: urlString)) else {
            return
        }

        switch await api.post("v1/deeplink", body: bytes) {
        case .success(let data):
            guard let response = try? JSONDecoder().decode(DeepLinkResponse.self, from: data) else {
                log.error("deeplink 200 with a response this SDK can't read")
                return
            }
            guard let link = response.deepLink else {
                log.info(response.clickId == nil
                    ? "\(urlString) is not a Dropplink link for this app"
                    : "\(urlString) has no deep link path (click \(response.clickId ?? "") recorded)")
                return
            }
            log.info("deep link \(link.path) from \(urlString)")
            dispatcher.dispatch(DeepLink(path: link.path, params: link.params ?? [:], url: url, isDeferred: false))
        case .failed(disable: true):
            disableAfterInvalidKey()
        case .failed(disable: false):
            break
        }
    }
}
