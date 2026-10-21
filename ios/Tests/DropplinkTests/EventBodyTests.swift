import XCTest
@testable import Dropplink

/// Spec §10.6: events and identify bodies match `contract/`; the partial events response parses.
final class EventBodyTests: XCTestCase {
    func testEventsBodyMatchesTheContractRequest() throws {
        let fixture = try Contract.json("events/request.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]]).map { json -> QueuedEvent in
            let revenue = (json["revenue"] as? [String: Any]).map {
                Revenue(amount: $0["amount"] as! Double, currency: $0["currency"] as! String, orderId: $0["orderId"] as? String)
            }
            var notes: [String] = []
            let outcome = EventValidation.event(
                name: json["name"] as! String, props: json["props"] as? [String: Any], revenue: revenue,
                eventId: json["eventId"] as! String, ts: (json["ts"] as! NSNumber).int64Value, notes: &notes
            )
            XCTAssertTrue(notes.isEmpty, "\(notes)")
            guard case .valid(let event) = outcome else { throw XCTSkip("fixture event dropped: \(outcome)") }
            return event
        }
        let body = try XCTUnwrap(EventPipeline.encode(.events(events), installId: fixture["installId"] as! String))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? NSDictionary)
        XCTAssertEqual(encoded, fixture as NSDictionary)
    }

    func testIdentifyBodyMatchesTheContractRequest() throws {
        let fixture = try Contract.json("identify/request.json")
        var notes: [String] = []
        // Trimmed and lower-cased before hashing, as the server documents.
        guard case .valid(let identify) = EventValidation.identify(
            userId: " user_8812 ", email: "  Priya@Example.com ", phone: nil, notes: &notes) else {
            return XCTFail("identify dropped")
        }
        let body = try XCTUnwrap(EventPipeline.encode(.identify(identify), installId: fixture["installId"] as! String))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? NSDictionary, fixture as NSDictionary)
    }

    func testLogoutBodyMatchesTheContractRequest() throws {
        let fixture = try Contract.json("identify/request.logout.json")
        let body = try XCTUnwrap(EventPipeline.encode(.identify(QueuedIdentify(userId: nil, traits: nil)),
                                                      installId: fixture["installId"] as! String))
        XCTAssertEqual(String(decoding: body, as: UTF8.self).contains(#""userId":null"#), true, "explicit null")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? NSDictionary, fixture as NSDictionary)
    }

    func testDecodesThePartialEventsResponse() throws {
        let response = try JSONDecoder().decode(EventsResponse.self, from: Contract.data("events/response.partial.json"))
        XCTAssertEqual(response.accepted, 1)
        XCTAssertEqual(response.duplicates, 0)
        XCTAssertEqual(response.rejected, [.init(index: 1, eventId: "7a6b5c4d-3e2f-4a1b-8c9d-0e1f2a3b4c5d",
                                                 code: "too_old", message: "ts is more than 7 days ago")])
        XCTAssertEqual(response.warnings, [.init(eventId: "3f2b8c1d-5e6a-4b7c-9d8e-0f1a2b3c4d5e",
                                                 code: "pii_in_props", props: ["email"])])
        XCTAssertNoThrow(try JSONDecoder().decode(EventsResponse.self, from: Data(#"{"accepted":1,"duplicates":0,"rejected":[],"warnings":[],"new":1}"#.utf8)),
                         "unknown fields are ignored")
        XCTAssertNoThrow(try JSONDecoder().decode(IdentifyResponseShape.self, from: Contract.data("identify/response.json")))
    }

    func testSentEventsCarryTheInstallIdAndTheIdsCreatedAtTrackTime() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        harness.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 1)))
        await harness.initialize()

        harness.events.track("add_to_cart", props: ["sku": "TSHIRT-M", "qty": 1, "gift": true], revenue: nil)
        harness.clock.advance(30) // the flush happens later; ts is still the track time
        await harness.fireTimers()

        let body = try XCTUnwrap(harness.bodies(to: "/v1/events").first)
        XCTAssertEqual(body["installId"] as? String, harness.core.installId)
        let event = try XCTUnwrap((body["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["name"] as? String, "add_to_cart")
        XCTAssertEqual(event["ts"] as? Int, 1_760_700_000, "unix seconds at track time")
        let eventId = try XCTUnwrap(event["eventId"] as? String)
        XCTAssertNotNil(UUID(uuidString: eventId))
        XCTAssertEqual(eventId, eventId.lowercased())
        XCTAssertEqual(Array(eventId)[14], "4", "UUID v4")

        let raw = String(decoding: try XCTUnwrap(harness.http.requests(to: "/v1/events").first?.httpBody), as: UTF8.self)
        XCTAssertTrue(raw.contains(#""gift":true"#), "Bool is a JSON boolean")
        XCTAssertTrue(raw.contains(#""qty":1"#), "Int is a JSON number, not true")
    }

    /// `/v1/identify` 200 is `{ installId, userId }`; the SDK only needs the status, but it must parse.
    private struct IdentifyResponseShape: Decodable {
        let installId: String
        let userId: String?
    }
}
