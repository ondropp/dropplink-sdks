import XCTest
@testable import Dropplink

/// Spec §10.1: reproduce every signature in `contract/hmac/vectors.json`.
final class SignerTests: XCTestCase {
    func testReproducesEveryContractVector() throws {
        let vectors = try Contract.json("hmac/vectors.json")
        let secret = try XCTUnwrap(vectors["secret"] as? String)
        let cases = try XCTUnwrap(vectors["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)

        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let timestamp = try XCTUnwrap(vector["timestamp"] as? String, name)
            let body = Data(try XCTUnwrap(vector["body"] as? String, name).utf8)

            XCTAssertEqual(Signer.sha256Hex(body), vector["bodySha256"] as? String, "bodySha256 for \(name)")
            XCTAssertEqual(Signer.signature(secret: secret, timestamp: timestamp, body: body),
                           vector["signature"] as? String, "signature for \(name)")
        }
    }

    func testRequestsCarrySignedHeadersOverTheExactBodyBytes() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        await harness.initialize()

        let request = try XCTUnwrap(harness.http.requests(to: "/v1/init").first)
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Key-Id"), "ak_3f9c1e2a7b6d4c80")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Timestamp"), "1760700000", "seconds, not milliseconds")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Signature"),
                       Signer.signature(secret: "test-secret", timestamp: "1760700000", body: body))
    }
}
