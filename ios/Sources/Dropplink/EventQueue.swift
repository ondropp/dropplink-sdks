import Foundation

/// Spec §11 queue rules as a value type: caps and drop order, 7-day pruning and batching. No I/O and
/// no locking; `EventPipeline` owns one and persists it with `QueueFileStore`.
struct EventQueue: Equatable {
    static let maxEvents = 1_000
    static let maxBytes = 1_048_576
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let maxBatchEvents = 100
    /// Below the server's 64 KB body cap, leaving room for the envelope.
    static let maxBatchBytes = 60 * 1_024

    enum Batch: Equatable {
        case events([QueuedEvent])
        case identify(QueuedIdentify)
    }

    enum AppendResult: Equatable {
        /// Added; `evicted` older events were dropped to make room.
        case added(evicted: Int)
        /// The queue is full of revenue events and the new event has none.
        case rejected
    }

    private(set) var file: QueueFile
    /// Encoded size of each item, parallel to `file.items`, and running totals, so a `track` doesn't
    /// re-scan the queue. Derived, never persisted.
    private var sizes: [Int]
    private var itemBytes: Int
    private(set) var eventCount: Int

    init(file: QueueFile = QueueFile()) {
        self.file = file
        self.sizes = file.items.map(Self.encodedSize)
        self.itemBytes = sizes.reduce(0) { $0 + $1 + 1 }
        self.eventCount = file.items.reduce(0) { $0 + ($1.event == nil ? 0 : 1) }
    }

    var items: [QueueItem] { file.items }
    var count: Int { file.items.count }
    var isEmpty: Bool { file.items.isEmpty }

    var lastUserId: String? {
        get { file.lastUserId }
        set { file.lastUserId = newValue }
    }

    /// Approximate size of the file: items plus separators and the envelope.
    var byteCount: Int {
        64 + (file.lastUserId?.utf8.count ?? 0) + itemBytes
    }

    /// Adds an event, dropping the oldest non-revenue event (then the oldest revenue event, but only
    /// to make room for another revenue event) while either cap would be exceeded.
    mutating func append(_ event: QueuedEvent) -> AppendResult {
        let item = QueueItem.event(event)
        let size = Self.encodedSize(item)
        var evicted = 0
        while eventCount + 1 > Self.maxEvents || byteCount + size + 1 > Self.maxBytes {
            if let index = file.items.firstIndex(where: { $0.event != nil && $0.event?.revenue == nil }) {
                remove(at: index)
            } else if event.revenue == nil {
                return .rejected
            } else if let index = file.items.firstIndex(where: { $0.event != nil }) {
                remove(at: index)
            } else {
                break // only identify entries left, and those are never dropped
            }
            evicted += 1
        }
        insert(item, size: size)
        return .added(evicted: evicted)
    }

    /// Identify entries are never dropped by the caps.
    mutating func append(_ identify: QueuedIdentify) {
        let item = QueueItem.identify(identify)
        insert(item, size: Self.encodedSize(item))
    }

    /// Drops events more than 7 days old, which the server rejects. Returns how many.
    mutating func prune(now: Date) -> Int {
        let oldest = Int64(now.timeIntervalSince1970 - Self.maxAge)
        let before = count
        var index = 0
        while index < file.items.count {
            if let event = file.items[index].event, event.ts < oldest {
                remove(at: index)
            } else {
                index += 1
            }
        }
        return before - count
    }

    /// What to send next: an identify alone, or the run of events at the head (up to 100 and 60 KB,
    /// stopping before the next identify).
    func nextBatch() -> Batch? {
        guard let first = file.items.first else { return nil }
        if case .identify(let identify) = first { return .identify(identify) }
        var events: [QueuedEvent] = []
        var bytes = 64
        for (item, size) in zip(file.items, sizes) {
            guard let event = item.event, events.count < Self.maxBatchEvents else { break }
            if !events.isEmpty, bytes + size + 1 > Self.maxBatchBytes { break }
            events.append(event)
            bytes += size + 1
        }
        return .events(events)
    }

    /// Removes these events wherever they are now (the queue may have changed while they were in flight).
    mutating func removeEvents(_ eventIds: Set<String>) {
        var index = 0
        while index < file.items.count {
            if let event = file.items[index].event, eventIds.contains(event.eventId) {
                remove(at: index)
            } else {
                index += 1
            }
        }
    }

    /// Removes the identify that was sent, if it's still at the head.
    mutating func removeIdentify(_ identify: QueuedIdentify) {
        guard file.items.first == .identify(identify) else { return }
        remove(at: 0)
    }

    mutating func removeAll() {
        self = EventQueue()
    }

    private mutating func insert(_ item: QueueItem, size: Int) {
        file.items.append(item)
        sizes.append(size)
        itemBytes += size + 1
        if item.event != nil { eventCount += 1 }
    }

    private mutating func remove(at index: Int) {
        let item = file.items.remove(at: index)
        itemBytes -= sizes.remove(at: index) + 1
        if item.event != nil { eventCount -= 1 }
    }

    private static func encodedSize(_ item: QueueItem) -> Int {
        (try? APIClient.makeEncoder().encode(item).count) ?? 0
    }
}

/// Spec §6: `Application Support/Dropplink/dropplink-queue.json`, excluded from backup, rewritten
/// atomically on every change. A file that doesn't parse is discarded, never a crash.
struct QueueFileStore: Sendable {
    static let fileName = "dropplink-queue.json"

    /// `nil` keeps the queue in memory only (no Application Support directory).
    let url: URL?

    static func live() -> QueueFileStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return QueueFileStore(url: directory?
            .appendingPathComponent("Dropplink", isDirectory: true)
            .appendingPathComponent(fileName))
    }

    func load(log: Log) -> QueueFile {
        guard let url, let data = try? Data(contentsOf: url) else { return QueueFile() }
        guard let file = try? JSONDecoder().decode(QueueFile.self, from: data), file.v == QueueFile.currentVersion else {
            log.error("event queue file couldn't be read; discarded")
            try? FileManager.default.removeItem(at: url)
            return QueueFile()
        }
        return file
    }

    func save(_ file: QueueFile, log: Log) {
        guard let url else { return }
        do {
            let data = try APIClient.makeEncoder().encode(file)
            var directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Like Android's noBackupFilesDir: a restored backup must not resend another device's events.
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? directory.setResourceValues(values)
            }
            // `.atomic` writes a temporary file and renames it, so a kill mid-write never corrupts the queue.
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("couldn't write the event queue: \(error.localizedDescription)")
        }
    }
}
