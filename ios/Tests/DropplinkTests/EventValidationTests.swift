import XCTest
@testable import Dropplink

/// Spec §10.8 and the §11 validation table.
final class EventValidationTests: XCTestCase {
    private func validate(_ name: String, props: [String: Any]? = nil, revenue: Revenue? = nil)
        -> (EventValidation.Outcome<QueuedEvent>, [String]) {
        var notes: [String] = []
        let outcome = EventValidation.event(name: name, props: props, revenue: revenue,
                                            eventId: "3f2b8c1d-5e6a-4b7c-9d8e-0f1a2b3c4d5e", ts: 1_760_700_100, notes: &notes)
        return (outcome, notes)
    }

    private func event(_ name: String, props: [String: Any]? = nil, revenue: Revenue? = nil,
                       file: StaticString = #filePath, line: UInt = #line) -> QueuedEvent? {
        guard case .valid(let event) = validate(name, props: props, revenue: revenue).0 else {
            XCTFail("\(name) dropped", file: file, line: line)
            return nil
        }
        return event
    }

    private func isDropped(_ name: String, props: [String: Any]? = nil, revenue: Revenue? = nil) -> Bool {
        if case .dropped = validate(name, props: props, revenue: revenue).0 { return true }
        return false
    }

    /// Each file in `contract/events/invalid/` is an event the server rejects. Locally it is dropped, or
    /// (for currency case and extra decimals, which §11 says to fix) sent in a form the server accepts.
    /// `event-id-not-uuid` and `ts-not-integer` are skipped: the SDK creates both values itself.
    func testContractInvalidEventsNeverReachTheServerAsIs() throws {
        let directory = Contract.root.appendingPathComponent("events/invalid")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var checked: [String] = []
        for file in files where !["event-id-not-uuid.json", "ts-not-integer.json"].contains(file) {
            let json = try Contract.json("events/invalid/\(file)")
            let revenue = (json["revenue"] as? [String: Any]).map {
                Revenue(amount: ($0["amount"] as! NSNumber).doubleValue, currency: $0["currency"] as! String,
                        orderId: $0["orderId"] as? String)
            }
            let (outcome, _) = validate(json["name"] as! String, props: json["props"] as? [String: Any], revenue: revenue)
            switch outcome {
            case .dropped:
                break
            case .valid(let event):
                let sent = try XCTUnwrap(event.revenue, "\(file) should have been dropped")
                XCTAssertTrue(sent.currency.matches("[A-Z]{3}"), file)
                XCTAssertEqual((sent.amount * 100).rounded() / 100, sent.amount, "\(file): at most 2 decimals")
            }
            checked.append(file)
        }
        XCTAssertEqual(checked, ["currency-lower-case.json", "name-not-snake-case.json", "negative-revenue.json", "three-decimals.json"])

        XCTAssertTrue(isDropped("Add To Cart"), "name-not-snake-case")
        XCTAssertTrue(isDropped("purchase", revenue: Revenue(amount: -1, currency: "INR")), "negative-revenue")
        XCTAssertEqual(event("purchase", revenue: Revenue(amount: 1, currency: "inr"))?.revenue?.currency, "INR", "currency-lower-case")
        XCTAssertEqual(event("purchase", revenue: Revenue(amount: 1.005, currency: "INR"))?.revenue?.amount, 1.01, "three-decimals")
    }

    func testNames() {
        for valid in ["add_to_cart", "a", "purchase2", "x" + String(repeating: "y", count: 63)] {
            XCTAssertFalse(isDropped(valid), valid)
        }
        for invalid in ["", "Add", "2fast", "_x", "add-to-cart", "add to cart", "x" + String(repeating: "y", count: 64), "add\n", "café"] {
            XCTAssertTrue(isDropped(invalid), invalid.debugDescription)
        }
        var notes: [String] = []
        if case .dropped(let reason) = EventValidation.event(name: "Add To Cart", props: nil, revenue: nil, eventId: "x", ts: 1, notes: &notes) {
            XCTAssertEqual(reason, "name must be snake_case, e.g. add_to_cart")
        }
    }

    func testPropValueTypes() throws {
        let optionalNil: String? = nil
        let props: [String: Any] = [
            "s": "text", "i": 1, "d": 2.5, "f": Float(1.5), "b": true, "nsTrue": NSNumber(value: true),
            "nsOne": NSNumber(value: 1), "nsZero": NSNumber(value: 0), "u": UInt64.max, "big": Int64.max,
            "dec": Decimal(string: "9.99")!, "null": NSNull(), "nil": optionalNil as Any, "some": Optional("x") as Any,
            "list": [1, 2], "map": ["a": 1], "nan": Double.nan, "inf": Double.infinity, "date": Date(),
        ]
        let event = try XCTUnwrap(event("view", props: props))
        let p = try XCTUnwrap(event.props)
        XCTAssertEqual(p["s"], .string("text"))
        XCTAssertEqual(p["i"], .int(1))
        XCTAssertEqual(p["d"], .double(2.5))
        XCTAssertEqual(p["f"], .double(1.5))
        XCTAssertEqual(p["b"], .bool(true))
        XCTAssertEqual(p["nsTrue"], .bool(true))
        XCTAssertEqual(p["nsOne"], .int(1), "NSNumber 1 is a number, not true")
        XCTAssertEqual(p["nsZero"], .int(0))
        XCTAssertEqual(p["u"], .double(Double(UInt64.max)))
        XCTAssertEqual(p["big"], .int(Int64.max))
        XCTAssertEqual(p["dec"], .double(9.99))
        XCTAssertEqual(p["null"], .null)
        XCTAssertEqual(p["nil"], .null)
        XCTAssertEqual(p["some"], .string("x"))
        for dropped in ["list", "map", "nan", "inf", "date"] { XCTAssertNil(p[dropped], dropped) }

        // On the wire: booleans as true/false, integers without a decimal point.
        let json = String(decoding: try APIClient.makeEncoder().encode(event), as: UTF8.self)
        XCTAssertTrue(json.contains(#""b":true"#), json)
        XCTAssertTrue(json.contains(#""nsOne":1"#), json)
        XCTAssertTrue(json.contains(#""nsZero":0"#), json)
        XCTAssertTrue(json.contains(#""null":null"#), json)

        // JSON from the bridges (Flutter / React Native hand over NSNumber booleans).
        let bridged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"t":true,"f":false,"one":1,"half":0.5}"#.utf8)) as? [String: Any])
        let fromJSON = try XCTUnwrap(self.event("view", props: bridged)?.props)
        XCTAssertEqual(fromJSON, ["t": .bool(true), "f": .bool(false), "one": .int(1), "half": .double(0.5)])
    }

    func testPropKeysCountAndLength() throws {
        var props: [String: Any] = [:]
        for i in 0..<25 { props[String(format: "k%02d", i)] = i }
        props["bad key"] = 1
        props["way_too_long_" + String(repeating: "x", count: 40)] = 1
        props[""] = 1
        props["long"] = String(repeating: "é", count: 300)
        let (outcome, notes) = validate("view", props: props)
        guard case .valid(let event) = outcome, let p = event.props else { return XCTFail("dropped") }
        XCTAssertEqual(p.count, 20, "at most 20")
        XCTAssertNil(p["bad key"])
        XCTAssertNil(p[""])
        // Swift dictionaries are unordered, so "the first 20" is by sorted key.
        XCTAssertEqual(p.keys.sorted(), (0..<20).map { String(format: "k%02d", $0) })
        XCTAssertFalse(notes.isEmpty)
        XCTAssertFalse(notes.contains { $0.contains("éé") }, "notes never contain values")

        let truncated = try XCTUnwrap(self.event("view", props: ["long": String(repeating: "é", count: 300)])?.props?["long"])
        XCTAssertEqual(truncated, .string(String(repeating: "é", count: 256)))
        XCTAssertNil(self.event("view", props: [:])?.props, "no props key when none are left")
    }

    func testPersonalDataInPropsIsDropped() throws {
        let p = try XCTUnwrap(event("view", props: [
            "email": "mail me at a@b.co", "phone": "98765 43210", "orderId": "ORD-1792564800123",
            "ts": "1792564800", "n": 5, "intl": "+1 (415) 555-0100",
        ])?.props)
        XCTAssertEqual(p.keys.sorted(), ["n", "orderId", "ts"])
    }

    func testPIIRulesMatchTheServer() {
        // The server's own test vectors (test/lib.test.ts).
        for id in ["priya@example.com", "+919876543210", "+1 (415) 555-0100", "9876543210", "09876543210", "919876543210"] {
            XCTAssertTrue(PII.isPersonal(id), id)
        }
        for id in ["user_8812", "8812", "1792564800", "6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73", "1234567890"] {
            XCTAssertFalse(PII.isPersonal(id), id)
        }
        XCTAssertTrue(PII.looksLikeEmail("contact: x.y@shop.co.in please"))
        XCTAssertFalse(PII.looksLikeEmail("a@b.c"), "TLD of 2+ characters")
        XCTAssertTrue(PII.looksLikePhone(" 98765.43210 "))
        XCTAssertFalse(PII.looksLikePhone("Call 9876543210"))
    }

    func testRevenue() {
        XCTAssertEqual(event("purchase", revenue: Revenue(amount: 499, currency: " usd ", orderId: "A1023"))?.revenue,
                       WireRevenue(amount: 499, currency: "USD", orderId: "A1023"))
        XCTAssertEqual(event("purchase", revenue: Revenue(amount: 0, currency: "INR", orderId: ""))?.revenue,
                       WireRevenue(amount: 0, currency: "INR", orderId: nil), "empty orderId is omitted")
        XCTAssertEqual(event("purchase", revenue: Revenue(amount: 2.675, currency: "INR"))?.revenue?.amount, 2.68, "half-up")
        XCTAssertEqual(event("purchase", revenue: Revenue(amount: 0.1 + 0.2, currency: "INR"))?.revenue?.amount, 0.3)
        XCTAssertEqual(event("purchase", revenue: Revenue(amount: 19.99, currency: "INR"))?.revenue?.amount, 19.99)
        XCTAssertEqual(event("purchase", revenue: Revenue(amount: 0.004, currency: "INR"))?.revenue?.amount, 0)

        XCTAssertTrue(isDropped("purchase", revenue: Revenue(amount: -0.01, currency: "INR")))
        XCTAssertTrue(isDropped("purchase", revenue: Revenue(amount: .nan, currency: "INR")))
        XCTAssertTrue(isDropped("purchase", revenue: Revenue(amount: .infinity, currency: "INR")))
        XCTAssertTrue(isDropped("purchase", revenue: Revenue(amount: 1, currency: "RUPEES")))
        XCTAssertTrue(isDropped("purchase", revenue: Revenue(amount: 1, currency: "US")))
        XCTAssertTrue(isDropped("purchase", revenue: Revenue(amount: 1, currency: "INR", orderId: String(repeating: "o", count: 129))))
        XCTAssertFalse(isDropped("purchase", revenue: Revenue(amount: 1, currency: "INR", orderId: String(repeating: "o", count: 128))))
    }

    func testIdentify() throws {
        func identify(_ userId: String, email: String? = nil, phone: String? = nil) -> (QueuedIdentify?, [String]) {
            var notes: [String] = []
            guard case .valid(let value) = EventValidation.identify(userId: userId, email: email, phone: phone, notes: &notes) else {
                return (nil, notes)
            }
            return (value, notes)
        }
        XCTAssertEqual(identify("  user_8812\n").0, QueuedIdentify(userId: "user_8812", traits: nil))
        XCTAssertNil(identify("   ").0)
        XCTAssertNil(identify(String(repeating: "u", count: 129)).0)
        XCTAssertNotNil(identify(String(repeating: "u", count: 128)).0)
        XCTAssertNil(identify("priya@example.com").0, "user id that is an email")
        XCTAssertNil(identify("+91 98765 43210").0, "user id that is a phone number")

        let phoneHash = Signer.sha256Hex(Data("+919876543210".utf8))
        let (withPhone, _) = identify("u1", phone: "+91 (98765) 432-10")
        XCTAssertEqual(withPhone?.traits, .init(emailHash: nil, phoneHash: phoneHash))

        let (bad, notes) = identify("u1", email: "not-an-email", phone: "98765 43210")
        XCTAssertEqual(bad, QueuedIdentify(userId: "u1", traits: nil), "bad traits are dropped, the call isn't")
        XCTAssertEqual(notes.count, 2)
        XCTAssertFalse(notes.joined().contains("98765 43210"), "never log the phone")
        XCTAssertNil(identify("u1", phone: "+0123456789").0?.traits, "E.164 has no leading 0")
    }
}
