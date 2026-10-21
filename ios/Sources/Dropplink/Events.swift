import Foundation

/// Revenue attached to an event by `Dropplink.track(_:props:revenue:)`.
///
/// Revenue the app reports is shown as **app-reported**. Purchases that pay creators must be sent from
/// the brand's server (`/v1/s2s/events`).
public struct Revenue: Equatable, Sendable {
    /// ≥ 0. Rounded half-up to 2 decimals.
    public let amount: Double
    /// ISO 4217, e.g. `"INR"`. Trimmed and upper-cased.
    public let currency: String
    /// The brand's order id, 1–128 characters. An empty string is treated as `nil`.
    public let orderId: String?

    public init(amount: Double, currency: String, orderId: String? = nil) {
        self.amount = amount
        self.currency = currency
        self.orderId = orderId
    }
}

// MARK: - Queue entries (internal)
// Spec §11: the queue file is `{ "v": 1, "lastUserId", "items": [ { "kind": "event" | "identify", … } ] }`.
// Events are stored exactly as they are sent, so a retry sends the same `eventId` and `ts`.

/// A prop value after validation: the JSON types the server accepts.
enum PropValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct WireRevenue: Codable, Equatable, Sendable {
    let amount: Double
    let currency: String
    let orderId: String?
}

/// One event, in the shape `/v1/events` takes it.
struct QueuedEvent: Codable, Equatable, Sendable {
    let eventId: String
    let name: String
    /// Unix seconds, device clock, taken when `track` was called.
    let ts: Int64
    let props: [String: PropValue]?
    let revenue: WireRevenue?
}

/// One `/v1/identify` call. `userId == nil` is a logout.
struct QueuedIdentify: Codable, Equatable, Sendable {
    struct Traits: Codable, Equatable, Sendable {
        let emailHash: String?
        let phoneHash: String?
    }

    let userId: String?
    let traits: Traits?

    private enum CodingKeys: String, CodingKey { case userId, traits }

    init(userId: String?, traits: Traits?) {
        self.userId = userId
        self.traits = traits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        traits = try container.decodeIfPresent(Traits.self, forKey: .traits)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Always present: `"userId": null` is how the server is told about a logout.
        try container.encode(userId, forKey: .userId)
        try container.encodeIfPresent(traits, forKey: .traits)
    }
}

enum QueueItem: Codable, Equatable, Sendable {
    case event(QueuedEvent)
    case identify(QueuedIdentify)

    private enum CodingKeys: String, CodingKey { case kind }

    var event: QueuedEvent? {
        if case .event(let event) = self { return event }
        return nil
    }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .kind)
        switch kind {
        case "event": self = .event(try QueuedEvent(from: decoder))
        case "identify": self = .identify(try QueuedIdentify(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.kind], debugDescription: "unknown kind \(kind)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let event):
            try container.encode("event", forKey: .kind)
            try event.encode(to: encoder)
        case .identify(let identify):
            try container.encode("identify", forKey: .kind)
            try identify.encode(to: encoder)
        }
    }
}

/// The on-disk queue file.
struct QueueFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var v: Int = QueueFile.currentVersion
    /// The last user id queued or sent, so repeated `identify` calls with it are no-ops.
    var lastUserId: String?
    var items: [QueueItem] = []

    private enum CodingKeys: String, CodingKey { case v, lastUserId, items }

    init(lastUserId: String? = nil, items: [QueueItem] = []) {
        self.lastUserId = lastUserId
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        lastUserId = try container.decodeIfPresent(String.self, forKey: .lastUserId)
        items = try container.decode([QueueItem].self, forKey: .items)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(lastUserId, forKey: .lastUserId)
        try container.encode(items, forKey: .items)
    }
}

// MARK: - Wire types (internal)

struct EventsRequest: Encodable {
    let installId: String
    let events: [QueuedEvent]
}

struct IdentifyRequest: Encodable {
    let installId: String
    let identify: QueuedIdentify

    private enum CodingKeys: String, CodingKey { case installId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(installId, forKey: .installId)
        try identify.encode(to: encoder)
    }
}

/// `/v1/events` 200. Missing arrays decode as empty, so a leaner server reply still parses.
struct EventsResponse: Decodable, Equatable {
    struct Rejected: Decodable, Equatable {
        let index: Int
        let eventId: String?
        let code: String
        let message: String
    }

    struct Warning: Decodable, Equatable {
        let eventId: String
        let code: String
        let props: [String]
    }

    let accepted: Int
    let duplicates: Int
    let rejected: [Rejected]
    let warnings: [Warning]

    private enum CodingKeys: String, CodingKey { case accepted, duplicates, rejected, warnings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
        duplicates = try container.decodeIfPresent(Int.self, forKey: .duplicates) ?? 0
        rejected = try container.decodeIfPresent([Rejected].self, forKey: .rejected) ?? []
        warnings = try container.decodeIfPresent([Warning].self, forKey: .warnings) ?? []
    }
}
