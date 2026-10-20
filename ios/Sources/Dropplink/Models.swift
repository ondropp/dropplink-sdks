import Foundation

/// A deep link delivered to the listener.
public struct DeepLink: Equatable, Sendable {
    /// The in-app path configured on the link, e.g. `/product/123`.
    public let path: String
    /// The link's params, overridden by the opened URL's query.
    public let params: [String: String]
    /// The opened URL for Universal Link opens; `nil` for the deferred link after a fresh install.
    public let url: URL?
    /// `true` only for the link delivered by `/v1/init` after a fresh install.
    public let isDeferred: Bool

    public init(path: String, params: [String: String], url: URL?, isDeferred: Bool) {
        self.path = path
        self.params = params
        self.url = url
        self.isDeferred = isDeferred
    }

    /// Plain-type form for the Flutter / React Native bridges. `url` is omitted when `nil`.
    public var dictionary: [String: Any] {
        var result: [String: Any] = ["path": path, "params": params, "isDeferred": isDeferred]
        if let url { result["url"] = url.absoluteString }
        return result
    }
}

/// How this install was attributed, as returned by `/v1/init`.
public struct Attribution: Codable, Equatable, Sendable {
    /// `"attributed"` or `"organic"`.
    public let type: String
    /// `"install_referrer"`, `"fingerprint"` or `"none"`. iOS installs are attributed by `"fingerprint"`.
    public let method: String
    public let clickId: String?
    public let linkId: String?
    public let campaignId: String?
    public let creatorId: String?
    public let source: String?
    /// 0…1. Set for fingerprint matches.
    public let confidence: Double?
    /// ISO 8601 timestamp.
    public let attributedAt: String?

    public init(
        type: String, method: String, clickId: String? = nil, linkId: String? = nil,
        campaignId: String? = nil, creatorId: String? = nil, source: String? = nil,
        confidence: Double? = nil, attributedAt: String? = nil
    ) {
        self.type = type
        self.method = method
        self.clickId = clickId
        self.linkId = linkId
        self.campaignId = campaignId
        self.creatorId = creatorId
        self.source = source
        self.confidence = confidence
        self.attributedAt = attributedAt
    }

    /// `true` when `type == "attributed"`.
    public var isAttributed: Bool { type == "attributed" }

    /// Plain-type form for the Flutter / React Native bridges. `nil` fields are omitted.
    public var dictionary: [String: Any] {
        var result: [String: Any] = ["type": type, "method": method]
        if let clickId { result["clickId"] = clickId }
        if let linkId { result["linkId"] = linkId }
        if let campaignId { result["campaignId"] = campaignId }
        if let creatorId { result["creatorId"] = creatorId }
        if let source { result["source"] = source }
        if let confidence { result["confidence"] = confidence }
        if let attributedAt { result["attributedAt"] = attributedAt }
        return result
    }
}

// MARK: - Wire types (internal)
// Decodable ignores unknown keys, so the server can add fields without breaking this SDK (spec §9.4).

struct WireDeepLink: Decodable, Equatable {
    let path: String
    let params: [String: String]?
}

struct InitResponse: Decodable {
    let installId: String?
    let attribution: Attribution
    let deepLink: WireDeepLink?
}

struct DeepLinkRequest: Encodable {
    let installId: String
    let url: String
}

struct DeepLinkResponse: Decodable {
    let clickId: String?
    let deepLink: WireDeepLink?
}

/// `{ "error": { "code", "message", "details"? } }`
struct ServerError: Equatable {
    let code: String
    let message: String
    /// `details` re-serialized as JSON text, for logging only.
    let details: String?

    init?(data: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? [String: Any],
            let code = error["code"] as? String
        else { return nil }
        self.code = code
        self.message = error["message"] as? String ?? ""
        if let details = error["details"], JSONSerialization.isValidJSONObject(details),
           let json = try? JSONSerialization.data(withJSONObject: details) {
            self.details = String(data: json, encoding: .utf8)
        } else {
            self.details = nil
        }
    }
}
