import Foundation

/// Spec §11: the server's PII rules (`src/lib/pii.ts`), ported exactly. They catch mistakes, not
/// determined misuse.
enum PII {
    /// An email anywhere in the value.
    static func looksLikeEmail(_ value: String) -> Bool {
        // The `@` check first: without it the regex backtracks quadratically over long props.
        value.contains("@") && value.range(of: #"[^\s@]+@[^\s@]+\.[^\s@]{2,}"#, options: .regularExpression) != nil
    }

    /// The whole value is a phone number: international (+ and 10–15 digits) or an Indian mobile
    /// (10 digits starting 6–9, optionally after 0 or 91).
    static func looksLikePhone(_ value: String) -> Bool {
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\s().-]"#, with: "", options: .regularExpression)
        return compact.matches(#"\+[0-9]{10,15}"#) || compact.matches(#"(?:0|91)?[6-9][0-9]{9}"#)
    }

    static func isPersonal(_ value: String) -> Bool {
        looksLikeEmail(value) || looksLikePhone(value)
    }
}

/// Spec §11 local validation. Pure functions, so they're tested without a queue.
enum EventValidation {
    static let maxProps = 20
    static let maxStringLength = 256
    static let maxOrderIdLength = 128
    static let maxUserIdLength = 128

    enum Outcome<Value> {
        case valid(Value)
        /// Why the call was dropped, for the debug log. Never contains prop values or traits.
        case dropped(String)
    }

    /// Builds the queued event, or says why it was dropped. Dropped props are listed in `notes`
    /// (by key only) so the caller can log them.
    static func event(
        name: String, props: [String: Any]?, revenue: Revenue?, eventId: String, ts: Int64,
        notes: inout [String]
    ) -> Outcome<QueuedEvent> {
        guard name.matches("[a-z][a-z0-9_]{0,63}") else {
            return .dropped("name must be snake_case, e.g. add_to_cart")
        }

        var wireRevenue: WireRevenue?
        if let revenue {
            switch validRevenue(revenue) {
            case .valid(let value): wireRevenue = value
            case .dropped(let reason): return .dropped(reason)
            }
        }

        let cleanProps = props.map { validProps($0, notes: &notes) }
        return .valid(QueuedEvent(
            eventId: eventId, name: name, ts: ts,
            props: cleanProps?.isEmpty == false ? cleanProps : nil,
            revenue: wireRevenue
        ))
    }

    static func validRevenue(_ revenue: Revenue) -> Outcome<WireRevenue> {
        guard revenue.amount.isFinite, revenue.amount >= 0 else {
            return .dropped("revenue.amount must be a finite number ≥ 0 (refunds come from the brand's server)")
        }
        let currency = revenue.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard currency.matches("[A-Z]{3}") else {
            return .dropped("revenue.currency must be an ISO 4217 code, e.g. INR")
        }
        var orderId = revenue.orderId
        if orderId?.isEmpty == true { orderId = nil }
        if let orderId, orderId.utf16.count > maxOrderIdLength {
            return .dropped("revenue.orderId is longer than \(maxOrderIdLength) characters")
        }
        return .valid(WireRevenue(amount: roundedToCents(revenue.amount), currency: currency, orderId: orderId))
    }

    /// Half-up to 2 decimals, in decimal rather than binary: `1.005` (really 1.00499999…) becomes
    /// `1.01`, as a person reading the number expects.
    static func roundedToCents(_ amount: Double) -> Double {
        guard var decimal = Decimal(string: "\(amount)", locale: Locale(identifier: "en_US_POSIX")) else {
            return amount
        }
        guard decimal.exponent < -2 else { return amount }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 2, .plain)
        return NSDecimalNumber(decimal: rounded).doubleValue
    }

    /// Keeps the first 20 valid props. Swift dictionaries have no insertion order, so keys are taken in
    /// sorted order, which at least makes the choice the same on every call.
    static func validProps(_ props: [String: Any], notes: inout [String]) -> [String: PropValue] {
        var result: [String: PropValue] = [:]
        for key in props.keys.sorted() {
            guard key.matches("[A-Za-z0-9_]{1,40}") else {
                notes.append("prop key \"\(key.truncated(to: 64))\" dropped: keys are 1–40 of A-Z a-z 0-9 _")
                continue
            }
            guard var value = propValue(props[key] as Any) else {
                notes.append("prop \(key) dropped: values are strings, numbers, booleans or null")
                continue
            }
            if case .string(let string) = value {
                // Truncated first: that's what the server would see, and it bounds the regex work.
                let truncated = string.truncated(to: maxStringLength)
                if PII.isPersonal(truncated) {
                    notes.append("prop \(key) dropped: looks like an email or phone number")
                    continue
                }
                value = .string(truncated)
            }
            guard result.count < maxProps else {
                notes.append("prop \(key) dropped: at most \(maxProps) props")
                continue
            }
            result[key] = value
        }
        return result
    }

    /// Maps what Swift / Objective-C / the bridges hand us onto JSON types. Bool is checked on the
    /// NSNumber's CF type: `NSNumber(value: 1) as? Bool` succeeds, so a plain cast would send `qty: 1`
    /// as `true`.
    static func propValue(_ value: Any) -> PropValue? {
        // `Optional<Any>` boxed in an `Any`, e.g. `["coupon": nil as String?]`.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first?.value else { return .null }
            return propValue(inner)
        }
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            switch String(cString: number.objCType) {
            case "f", "d":
                let double = number.doubleValue
                return double.isFinite ? .double(double) : nil
            case "Q", "L", "I", "S", "C":
                let unsigned = number.uint64Value
                return unsigned <= UInt64(Int64.max) ? .int(Int64(unsigned)) : .double(Double(unsigned))
            default:
                return .int(number.int64Value)
            }
        default:
            return nil
        }
    }

    // MARK: identify

    static func identify(userId: String, email: String?, phone: String?, notes: inout [String]) -> Outcome<QueuedIdentify> {
        let userId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userId.isEmpty, userId.utf16.count <= maxUserIdLength else {
            return .dropped("userId must be 1–\(maxUserIdLength) characters")
        }
        guard !PII.isPersonal(userId) else {
            return .dropped("userId looks like an email or phone number; pass an opaque id")
        }

        var emailHash: String?
        if let email {
            let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains("@") {
                emailHash = Signer.sha256Hex(Data(normalized.utf8))
            } else {
                notes.append("email trait dropped: not an email address")
            }
        }

        var phoneHash: String?
        if let phone {
            let normalized = phone.replacingOccurrences(of: #"[\s().-]"#, with: "", options: .regularExpression)
            if normalized.matches(#"\+[1-9][0-9]{7,14}"#) {
                phoneHash = Signer.sha256Hex(Data(normalized.utf8))
            } else {
                notes.append("phone trait dropped: must be E.164, e.g. +919876543210")
            }
        }

        let traits = emailHash == nil && phoneHash == nil
            ? nil : QueuedIdentify.Traits(emailHash: emailHash, phoneHash: phoneHash)
        return .valid(QueuedIdentify(userId: userId, traits: traits))
    }
}

extension String {
    /// The whole string matches `pattern`. `\z` rather than `$`, which in ICU also matches before a
    /// trailing newline (JavaScript's doesn't).
    func matches(_ pattern: String) -> Bool {
        range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
}
