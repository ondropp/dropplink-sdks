import Foundation

/// Spec §6. Persists the install id, the `attributed` flag and the last attribution in
/// `UserDefaults(suiteName: "app.ondropp.dropplink")`, apart from the app's own defaults.
/// The secret is never stored.
final class Storage: @unchecked Sendable {
    // @unchecked: the only state is a UserDefaults, which Apple documents as thread-safe.

    static let suiteName = "app.ondropp.dropplink"

    private enum Key {
        static let installId = "installId"
        static let attributed = "attributed"
        static let attribution = "attribution"
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
