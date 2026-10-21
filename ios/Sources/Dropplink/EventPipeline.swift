import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Spec §11: `track`, `identify`, `logout` and `setTrackingEnabled`, the on-disk queue behind them and
/// the flushes that empty it.
///
/// Public calls validate on the caller's thread (cheap, and `props` isn't Sendable), then hand the entry
/// to `workQueue`, so the caller never waits on disk. Flushes run on a detached task, one at a time.
final class EventPipeline: @unchecked Sendable {
    // @unchecked: every mutable property below is read and written only while holding `lock`.

    enum Trigger {
        /// 1 s after the last `track` / `identify` / `logout`. Waits for a pending backoff.
        case debounce
        /// The app went to the background: last chance before a possible kill, so it skips the backoff.
        case background
        /// A `/v1/init` just succeeded.
        case initialized
        /// A backoff timer fired.
        case retry
    }

    static let debounceDelay: TimeInterval = 1

    private let storage: Storage
    private let store: QueueFileStore
    private let scheduler: Scheduler
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    /// Serial: applies queued entries and writes the file, in call order.
    private let workQueue = DispatchQueue(label: "app.ondropp.dropplink.events", qos: .utility)
    private let lock = NSLock()

    private var log: Log
    /// Loaded from disk on first use (`loadQueueIfNeeded`), off the caller's thread.
    private var queue = EventQueue()
    private var queueLoaded = false
    private var api: APIClient?
    private var installId: String?
    private var reinitialize: (@Sendable () async -> Bool)?
    /// Nothing is sent before this launch's init has succeeded: the server must know the install.
    private var initSucceeded = false
    /// A `401` (other than `stale_timestamp`) or another unexpected `4xx`: nothing more is sent this launch.
    private var stoppedUntilNextLaunch = false
    private var flushTask: Task<Void, Never>?
    private var debounceWork: ScheduledWork?
    private var retryWork: ScheduledWork?
    /// Failed attempts since the last `200`, for the backoff.
    private var retryCount = 0
    private var writeScheduled = false
    private var backgroundObserver: NSObjectProtocol?

    init(storage: Storage, store: QueueFileStore, scheduler: Scheduler,
         now: @escaping @Sendable () -> Date, random: @escaping @Sendable () -> Double,
         logSink: (@Sendable (Log.Level, String) -> Void)?) {
        self.storage = storage
        self.store = store
        self.scheduler = scheduler
        self.now = now
        self.random = random
        self.log = Log(enabled: false, sink: logSink)
    }

    /// Called once by `DropplinkCore.initialize`, before `/v1/init` is sent.
    func configure(api: APIClient, installId: String, reinitialize: @escaping @Sendable () async -> Bool) {
        lock.locked {
            self.api = api
            self.installId = installId
            self.log = api.log
            self.reinitialize = reinitialize
        }
        // Load the queue now, on the work queue, so the first `track` on the main thread doesn't.
        workQueue.async { [self] in lock.locked { loadQueueIfNeeded() } }
        observeAppLifecycle()
    }

    /// Returns the flush task (the init task awaits it), or `nil` when there's nothing to do.
    @discardableResult
    func initDidSucceed() -> Task<Void, Never>? {
        lock.locked { initSucceeded = true }
        return flush(.initialized)
    }

    /// The key is unusable (`invalid_key`, `platform_mismatch`): send nothing more this launch.
    func stopUntilNextLaunch() {
        lock.locked {
            stoppedUntilNextLaunch = true
            retryWork?.cancel()
            retryWork = nil
        }
    }

    private var currentLog: Log { lock.locked { log } }

    // MARK: Public calls

    var isTrackingEnabled: Bool { storage.trackingEnabled }

    func setTrackingEnabled(_ enabled: Bool) {
        storage.trackingEnabled = enabled
        currentLog.info(enabled ? "tracking enabled" : "tracking disabled; event queue cleared")
        guard !enabled else { return }
        // On the work queue, after any entry handed over before this call, so those are cleared too.
        workQueue.async { [self] in
            lock.locked {
                loadQueueIfNeeded()
                queue.removeAll()
                debounceWork?.cancel()
                debounceWork = nil
                retryWork?.cancel()
                retryWork = nil
                persist()
            }
        }
    }

    func track(_ name: String, props: [String: Any]?, revenue: Revenue?) {
        let log = currentLog
        guard isTrackingEnabled else {
            log.info("tracking is disabled; event \"\(name.truncated(to: 64))\" not tracked")
            return
        }
        var notes: [String] = []
        let outcome = EventValidation.event(
            name: name, props: props, revenue: revenue,
            eventId: UUID().uuidString.lowercased(), ts: Int64(now().timeIntervalSince1970), notes: &notes
        )
        guard case .valid(let event) = outcome else {
            if case .dropped(let reason) = outcome { log.info("event \"\(name.truncated(to: 64))\" dropped: \(reason)") }
            return
        }
        for note in notes { log.info("event \(name): \(note)") }

        workQueue.async { [self] in
            let (result, waiting) = lock.locked { () -> (EventQueue.AppendResult, Int) in
                loadQueueIfNeeded()
                let result = queue.append(event)
                if case .added = result { persist() }
                return (result, queue.count)
            }
            switch result {
            case .added(let evicted):
                if evicted > 0 { log.info("event queue full; dropped the \(evicted) oldest event(s)") }
                log.info("track \(event.name) (queued, \(waiting) waiting)")
                scheduleDebouncedFlush()
            case .rejected:
                log.info("event queue full of revenue events; \(event.name) dropped")
            }
        }
    }

    func identify(userId: String, email: String?, phone: String?) {
        let log = currentLog
        guard isTrackingEnabled else {
            log.info("tracking is disabled; identify ignored")
            return
        }
        var notes: [String] = []
        let outcome = EventValidation.identify(userId: userId, email: email, phone: phone, notes: &notes)
        guard case .valid(let identify) = outcome else {
            if case .dropped(let reason) = outcome { log.info("identify dropped: \(reason)") }
            return
        }
        for note in notes { log.info("identify: \(note)") }
        enqueue(identify, log: log)
    }

    func logout() {
        let log = currentLog
        guard isTrackingEnabled else {
            log.info("tracking is disabled; logout ignored")
            return
        }
        enqueue(QueuedIdentify(userId: nil, traits: nil), log: log)
    }

    private func enqueue(_ identify: QueuedIdentify, log: Log) {
        workQueue.async { [self] in
            let queued: Bool = lock.locked {
                loadQueueIfNeeded()
                // Same user as last time (traits included): a no-op, so apps can call it on every launch.
                if let userId = identify.userId, userId == queue.lastUserId { return false }
                queue.append(identify)
                queue.lastUserId = identify.userId
                persist()
                return true
            }
            guard queued else {
                log.info("identify \(identify.userId ?? "") already sent; ignored")
                return
            }
            log.info(identify.userId.map { "identify \($0) queued" } ?? "logout queued")
            scheduleDebouncedFlush()
        }
    }

    // MARK: Flushing

    /// Starts a flush unless one is running or sending isn't allowed yet. Returns its task (tests await it).
    @discardableResult
    func flush(_ trigger: Trigger) -> Task<Void, Never>? {
        lock.locked {
            guard flushTask == nil, canSend else { return nil }
            if retryWork != nil {
                guard trigger != .debounce else { return nil }
                retryWork?.cancel()
                retryWork = nil
            }
            let task = Task.detached(priority: .utility) { [self] in await runFlush() }
            flushTask = task
            return task
        }
    }

    /// Waits for the running flush, if any. For tests.
    func waitUntilIdle() async {
        while let task = lock.locked({ flushTask }) { await task.value }
    }

    /// Waits until entries handed to the work queue are applied and written. For tests.
    func drain() {
        workQueue.sync {}
        workQueue.sync {} // the write each entry schedules
    }

    /// The queue as it is now. For tests.
    var snapshot: EventQueue {
        lock.locked {
            loadQueueIfNeeded()
            return queue
        }
    }

    /// Call with `lock` held.
    private var canSend: Bool {
        initSucceeded && !stoppedUntilNextLaunch && api != nil && installId != nil && storage.trackingEnabled
    }

    private func scheduleDebouncedFlush() {
        lock.locked {
            debounceWork?.cancel()
            debounceWork = scheduler.schedule(after: Self.debounceDelay) { [weak self] in
                self?.flush(.debounce)
            }
        }
    }

    private enum Next {
        /// Sent; carry on with the rest of the queue.
        case next
        case backoff(retryAfter: TimeInterval?)
        case reinitialize
        case stop
    }

    private func runFlush() async {
        var reinitialized = false
        while let (api, installId, batch) = takeBatch() {
            guard let body = Self.encode(batch, installId: installId) else {
                // Can't happen with validated values; dropping beats retrying the same failure forever.
                api.log.error("couldn't encode an event batch; dropped")
                remove(batch)
                continue
            }
            let path = batch.isIdentify ? "v1/identify" : "v1/events"
            let attempt = await api.send(path, body: body)
            switch handle(attempt, batch: batch, log: api.log) {
            case .next:
                reinitialized = false
            case .reinitialize:
                if !reinitialized, let reinitialize = lock.locked({ self.reinitialize }), await reinitialize() {
                    reinitialized = true
                    continue
                }
                finishFlush(backoff: true, retryAfter: nil)
                return
            case .backoff(let retryAfter):
                finishFlush(backoff: true, retryAfter: retryAfter)
                return
            case .stop:
                finishFlush(backoff: false, retryAfter: nil)
                return
            }
        }
    }

    /// The head batch, after dropping events too old to send; `nil` (and the flush ends) when there's
    /// nothing to send or sending stopped meanwhile.
    private func takeBatch() -> (APIClient, String, EventQueue.Batch)? {
        let (result, pruned, log): ((APIClient, String, EventQueue.Batch)?, Int, Log) = lock.locked {
            loadQueueIfNeeded()
            let pruned = queue.prune(now: now())
            if pruned > 0 { persist() }
            guard canSend, let api, let installId, let batch = queue.nextBatch() else {
                flushTask = nil
                return (nil, pruned, self.log)
            }
            return ((api, installId, batch), pruned, self.log)
        }
        if pruned > 0 { log.info("dropped \(pruned) event(s) older than 7 days") }
        return result
    }

    private func finishFlush(backoff: Bool, retryAfter: TimeInterval?) {
        let (delay, log): (TimeInterval?, Log) = lock.locked {
            flushTask = nil
            guard backoff, canSend else { return (nil, self.log) }
            let delay = RetryPolicy.queueDelay(beforeRetry: retryCount, random: random(), retryAfter: retryAfter)
            retryCount += 1
            retryWork?.cancel()
            retryWork = scheduler.schedule(after: delay) { [weak self] in
                guard let self else { return }
                self.lock.locked { self.retryWork = nil }
                self.flush(.retry)
            }
            return (delay, self.log)
        }
        if let delay { log.info("events will be retried in \(String(format: "%.1f", delay)) s") }
    }

    /// Spec §11 response table.
    private func handle(_ attempt: APIClient.Attempt, batch: EventQueue.Batch, log: Log) -> Next {
        if attempt.isSuccess {
            lock.locked { retryCount = 0 }
            remove(batch)
            switch batch {
            case .identify(let identify):
                log.info(identify.userId.map { "identify \($0) sent" } ?? "logout sent")
            case .events:
                logEventsResponse(attempt.body, log: log)
            }
            return .next
        }

        let code = attempt.serverError?.code
        guard let statusCode = attempt.statusCode else { return .backoff(retryAfter: nil) }
        switch statusCode {
        case 429, 500...599:
            return .backoff(retryAfter: attempt.retryAfter)
        case 401 where code == "stale_timestamp":
            return .backoff(retryAfter: attempt.retryAfter) // the clock warning is logged by APIClient
        case 404 where code == "unknown_install":
            log.info("server doesn't know this install; sending init again")
            return .reinitialize
        case 401:
            // Bad key or signature: retrying won't help, but the entries may be fine, so keep them for
            // the next launch.
            lock.locked { stoppedUntilNextLaunch = true }
            log.error("⚠️ events and identify paused until next launch (\(statusCode) \(code ?? "unknown")); \(batch.summary) kept")
            return .stop
        case 400...499:
            // 400 and any other 4xx (413, 403, …): this batch will never be accepted. Keeping it would
            // block every entry behind it, so drop it, as Android does.
            remove(batch)
            log.error("\(batch.summary) dropped after \(statusCode) \(code ?? "unknown")")
            return .next
        default:
            return .backoff(retryAfter: attempt.retryAfter)
        }
    }

    private func logEventsResponse(_ body: Data, log: Log) {
        guard let response = try? JSONDecoder().decode(EventsResponse.self, from: body) else {
            log.error("events 200 with a response this SDK can't read")
            return
        }
        log.info("events 200: \(response.accepted) accepted, \(response.duplicates) duplicates, \(response.rejected.count) rejected")
        for rejected in response.rejected {
            log.info("event \(rejected.eventId ?? "#\(rejected.index)") rejected: \(rejected.code) \(rejected.message)")
        }
        for warning in response.warnings {
            log.info("event \(warning.eventId) warning \(warning.code): \(warning.props.joined(separator: ", "))")
        }
    }

    private func remove(_ batch: EventQueue.Batch) {
        lock.locked {
            loadQueueIfNeeded()
            switch batch {
            case .events(let events): queue.removeEvents(Set(events.map(\.eventId)))
            case .identify(let identify): queue.removeIdentify(identify)
            }
            persist()
        }
    }

    static func encode(_ batch: EventQueue.Batch, installId: String) -> Data? {
        let encoder = APIClient.makeEncoder()
        switch batch {
        case .events(let events): return try? encoder.encode(EventsRequest(installId: installId, events: events))
        case .identify(let identify): return try? encoder.encode(IdentifyRequest(installId: installId, identify: identify))
        }
    }

    // MARK: Storage

    /// Reads the file the first time the queue is needed, dropping events too old to send. Call with
    /// `lock` held.
    private func loadQueueIfNeeded() {
        guard !queueLoaded else { return }
        queueLoaded = true
        queue = EventQueue(file: store.load(log: log))
        let pruned = queue.prune(now: now())
        if pruned > 0 {
            log.info("dropped \(pruned) queued event(s) older than 7 days")
            persist()
        }
    }

    /// Writes the queue on the work queue. Call with `lock` held. Coalesces: a write that hasn't started
    /// yet will pick up later changes too, since it snapshots the queue when it runs.
    private func persist() {
        guard !writeScheduled else { return }
        writeScheduled = true
        workQueue.async { [self] in
            let (file, log): (QueueFile, Log) = lock.locked {
                writeScheduled = false
                return (queue.file, self.log)
            }
            store.save(file, log: log)
        }
    }

    // MARK: App lifecycle

    private func observeAppLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        guard lock.locked({ backgroundObserver == nil }) else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // The notification's object is the application, which avoids `UIApplication.shared`
            // (unavailable in app extensions).
            guard let self, let application = notification.object as? UIApplication else { return }
            MainActor.assumeIsolated { self.flushInBackground(application) }
        }
        lock.locked { backgroundObserver = observer }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    @MainActor
    private func flushInBackground(_ application: UIApplication) {
        guard let task = flush(.background) else { return }
        // Asks iOS for time to finish the request after the app leaves the foreground.
        let backgroundTask = BackgroundTask()
        backgroundTask.id = application.beginBackgroundTask(withName: "Dropplink events") {
            MainActor.assumeIsolated { backgroundTask.end(application) }
        }
        Task { @MainActor in
            await task.value
            backgroundTask.end(application)
        }
    }
    #endif
}

#if canImport(UIKit) && !os(watchOS)
/// Ends a background task exactly once, whichever comes first: the flush or iOS's expiry.
@MainActor
private final class BackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid

    func end(_ application: UIApplication) {
        guard id != .invalid else { return }
        application.endBackgroundTask(id)
        id = .invalid
    }
}
#endif

extension EventQueue.Batch {
    var isIdentify: Bool {
        if case .identify = self { return true }
        return false
    }

    /// For logs: never prop values or traits.
    var summary: String {
        switch self {
        case .events(let events): return "batch of \(events.count) event(s)"
        case .identify(let identify): return identify.userId.map { "identify \($0)" } ?? "logout"
        }
    }
}
