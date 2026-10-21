import Foundation

/// Spec §6. Persists the install id, the `attributed` flag, the last attribution and `trackingEnabled` in
/// `UserDefaults(suiteName: "app.ondropp.dropplink")`, apart from the app's own defaults.
/// The secret is never stored.
final class Storage: @unchecked Sendable {
    // @unchecked: the only state is a UserDefaults, which Apple documents as thread-safe.

    static let suiteName = "app.ondropp.dropplink"

    private enum Key {
        static let installId = "installId"
        static let attributed = "attributed"
        static let attribution = "attribution"
        static let trackingEnabled = "trackingEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func live() -> Storage {
        Storage(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    /// Returns the stored install id, creating a UUID v4 on first launch. Never regenerated once stored.
    func loadOrCreateInstallId() -> String {
        if let stored = defaults.string(forKey: Key.installId), UUID(uuidString: stored) != nil {
            return stored
        }
        // Lower-case to match the server's fixtures; UUID().uuidString is upper-case.
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Key.installId)
        return created
    }

    var attributed: Bool {
        get { defaults.bool(forKey: Key.attributed) }
        set { defaults.set(newValue, forKey: Key.attributed) }
    }

    /// Spec §11 consent switch. Absent means `true`.
    var trackingEnabled: Bool {
        get { defaults.object(forKey: Key.trackingEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.trackingEnabled) }
    }

    var attribution: Attribution? {
        get {
            guard let data = defaults.data(forKey: Key.attribution) else { return nil }
            return try? JSONDecoder().decode(Attribution.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.attribution)
            } else {
                defaults.removeObject(forKey: Key.attribution)
            }
        }
    }
}
