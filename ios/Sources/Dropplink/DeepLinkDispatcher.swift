import Foundation

/// Spec §7: one listener; while none is set, the **latest** link waits in memory (never persisted).
final class DeepLinkDispatcher: @unchecked Sendable {
    // @unchecked: `listener` and `pending` are only touched while holding `lock`.

    typealias Listener = (DeepLink) -> Void

    /// Carries the app's listener onto the delivery queue. @unchecked because the public API takes a
    /// plain (non-@Sendable) closure for ease of use; it is only ever invoked on `deliveryQueue`,
    /// which is the main queue in the app.
    private struct ListenerBox: @unchecked Sendable {
        let call: Listener
    }

    private let lock = NSLock()
    private var listener: ListenerBox?
    private var pending: DeepLink?
    private let deliveryQueue: DispatchQueue

    init(deliveryQueue: DispatchQueue = .main) {
        self.deliveryQueue = deliveryQueue
    }

    func setListener(_ newListener: Listener?) {
        let box = newListener.map(ListenerBox.init)
        let toDeliver: DeepLink? = lock.locked {
            listener = box
            guard box != nil else { return nil }
            defer { pending = nil }
            return pending
        }
        if let box, let toDeliver { deliver(toDeliver, to: box) }
    }

    func dispatch(_ link: DeepLink) {
        let box: ListenerBox? = lock.locked {
            if listener == nil { pending = link }
            return listener
        }
        if let box { deliver(link, to: box) }
    }

    private func deliver(_ link: DeepLink, to box: ListenerBox) {
        deliveryQueue.async { box.call(link) }
    }
}

extension NSLock {
    /// Like `NSLocking.withLock`, which only exists from iOS 16 / macOS 13.
    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
