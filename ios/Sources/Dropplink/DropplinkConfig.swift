import Foundation

/// Settings passed to `Dropplink.initialize(config:)`.
public struct DropplinkConfig: Sendable {
    /// The iOS SDK key id (`ak_…`) from the Dropp dashboard.
    public let keyId: String
    /// The key's secret. Kept out of `description` so it never ends up in logs.
    let secret: String
    /// Turns on logging. Never ship `true`.
    public let debug: Bool
    /// The attribution API host. Override only for local testing.
    public let baseURL: URL
    /// Set by the Flutter (`"flutter"`) and React Native (`"rn"`) packages, never by apps.
    public let platformWrapper: String?

    public init(
        keyId: String,
        secret: String,
        debug: Bool = false,
        baseURL: URL = URL(string: "https://attribution.ondropp.app")!,
        platformWrapper: String? = nil
    ) {
        self.keyId = keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret
        self.debug = debug
        self.baseURL = baseURL
        self.platformWrapper = platformWrapper?.isEmpty == true ? nil : platformWrapper
    }

    /// `0.2.1` for native apps, `0.2.1-flutter` / `0.2.1-rn` through a wrapper.
    var sdkVersion: String {
        platformWrapper.map { "\(Dropplink.version)-\($0)" } ?? Dropplink.version
    }

    /// Why this config can't be used, or `nil` when it's fine.
    var validationError: String? {
        if keyId.isEmpty { return "keyId is empty" }
        if !keyId.hasPrefix("ak_") { return "keyId must start with \"ak_\" (got \"\(keyId)\")" }
        if secret.isEmpty { return "secret is empty" }
        return nil
    }
}

extension DropplinkConfig: CustomStringConvertible {
    public var description: String {
        "DropplinkConfig(keyId: \(keyId), secret: <redacted>, debug: \(debug), baseURL: \(baseURL)"
            + (platformWrapper.map { ", platformWrapper: \($0)" } ?? "") + ")"
    }
}
