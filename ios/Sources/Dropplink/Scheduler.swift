import Foundation

/// Runs work after a delay: the event queue's 1 s debounce and its backoff timers. Injected so tests
/// fire timers by hand instead of waiting.
protocol Scheduler: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> ScheduledWork
}

protocol ScheduledWork: Sendable {
    func cancel()
}

struct DispatchScheduler: Scheduler {
    var queue: DispatchQueue = .global(qos: .utility)

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchScheduledWork(item: item)
    }
}

private struct DispatchScheduledWork: ScheduledWork, @unchecked Sendable {
    // @unchecked: DispatchWorkItem is thread-safe, but not annotated Sendable in every SDK this builds with.
    let item: DispatchWorkItem

    func cancel() {
        item.cancel()
    }
}
