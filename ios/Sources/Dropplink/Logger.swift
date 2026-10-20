import Foundation
import os.log

/// Spec §8. Silent unless `debug: true`, except configuration errors, which are always logged
/// because they mean the SDK is switched off and the developer needs to know why.
///
/// Uses `OSLog` + `os_log` rather than `os.Logger`, which needs iOS 14.
/// Filter in Console.app with `subsystem:app.ondropp.dropplink`.
struct Log: @unchecked Sendable {
    // @unchecked: `OSLog` isn't annotated Sendable, but Apple documents the logging APIs as thread-safe.
    enum Level: Sendable { case info, error }

    static let subsystem = "app.ondropp.dropplink"

    let enabled: Bool
    /// Receives every message that is logged. Tests use it to assert on log output.
    let sink: (@Sendable (Level, String) -> Void)?
    private let osLog = OSLog(subsystem: Log.subsystem, category: "Dropplink")

    init(enabled: Bool, sink: (@Sendable (Level, String) -> Void)? = nil) {
        self.enabled = enabled
        self.sink = sink
    }

    func info(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        write(.info, message())
    }

    func error(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        write(.error, message())
    }

    /// Logged even when `debug` is off: see the type comment.
    func configError(_ message: String) {
        write(.error, message)
    }

    private func write(_ level: Level, _ message: String) {
        let line = "Dropplink: " + message
        // `.default` rather than `.debug`/`.info` so messages show in Console without extra settings.
        os_log("%{public}@", log: osLog, type: level == .error ? .error : .default, line)
        sink?(level, line)
    }
}
