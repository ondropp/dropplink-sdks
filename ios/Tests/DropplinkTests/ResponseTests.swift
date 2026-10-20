import XCTest
@testable import Dropplink

/// Spec §10.3: parse every response fixture; and what the SDK does with each.
final class ResponseTests: XCTestCase {
    func testDecodesAttributedInitResponse() throws {
        let response = try JSONDecoder().decode(InitResponse.self, from: Contract.data("init/response.attributed.json"))
        XCTAssertEqual(response.attribution, Attribution(
            type: "attributed", method: "install_referrer", clickId: "c_8b1f0e7d2a4c4f6e",
            linkId: "6711a0c2f1e4b8a9c3d2e1f0", campaignId: "6711a0c2f1e4b8a9c3d2e1f1",
            creatorId: "6711a0c2f1e4b8a9c3d2e1f2", source: "instagram", confidence: 1,
            attributedAt: "2026-10-17T10:00:42.000Z"))
        XCTAssertEqual(response.deepLink, WireDeepLink(path: "/product/123", params: ["ref": "creator", "variant": "red"]))
    }

    func testDecodesOrganicInitResponse() throws {
        let response = try JSONDecoder().decode(InitResponse.self, from: Contract.data("init/response.organic.json"))
        XCTAssertEqual(response.attribution, Attribution(type: "organic", method: "none"))
        XCTAssertNil(response.deepLink)
    }

    func testDecodesDeeplinkResponses() throws {
        let matched = try JSONDecoder().decode(DeepLinkResponse.self, from: Contract.data("deeplink/response.matched.json"))
        XCTAssertEqual(matched.clickId, "c_3d9a0b1c2e4f6a8b")
        XCTAssertEqual(matched.deepLink, WireDeepLink(path: "/product/123", params: ["variant": "red", "ref": "story"]))

        let none = try JSONDecoder().decode(DeepLinkResponse.self, from: Contract.data("deeplink/response.none.json"))
        XCTAssertNil(none.clickId)
        XCTAssertNil(none.deepLink)
    }

    func testIgnoresUnknownFields() throws {
        let json = #"{"installId":"x","attribution":{"type":"organic","method":"none","future":1},"deepLink":null,"new":true}"#
        XCTAssertNoThrow(try JSONDecoder().decode(InitResponse.self, from: Data(json.utf8)))
    }

    func testDecodesErrorResponse() {
        let error = ServerError(data: Data(#"{"error":{"code":"validation_failed","message":"bad","details":[{"path":"url","message":"too long"}]}}"#.utf8))
        XCTAssertEqual(error?.code, "validation_failed")
        XCTAssertEqual(error?.message, "bad")
        XCTAssertTrue(error?.details?.contains(#""message":"too long""#) == true)
        XCTAssertNil(ServerError(data: Data("<html>".utf8)))
    }

    func testAttributedInitStoresAttributionAndDeliversDeferredLinkOnce() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initAttributed()))
        let delivered = Recorder<DeepLink>()
        harness.core.dispatcher.setListener { delivered.append($0) }

        XCTAssertNil(harness.core.attribution)
        await harness.initialize()
        harness.drainDeliveries()

        XCTAssertEqual(harness.core.attribution?.method, "install_referrer")
        XCTAssertEqual(harness.storage.attribution, harness.core.attribution, "cached on disk")
        XCTAssertTrue(harness.storage.attributed)
        XCTAssertEqual(delivered.values, [DeepLink(path: "/product/123", params: ["ref": "creator", "variant": "red"],
                                                   url: nil, isDeferred: true)])
        XCTAssertTrue(harness.logs.values.contains("Dropplink: init 200 attributed via install_referrer, link 6711a0c2f1e4b8a9c3d2e1f0, deep link /product/123"))
        XCTAssertTrue(harness.logs.values.contains { $0.contains("paste into Dropplink → Install debugger") })
        XCTAssertFalse(harness.logs.values.contains { $0.contains("test-secret") }, "never log the secret")
    }

    func testOrganicInitDeliversNothing() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        let delivered = Recorder<DeepLink>()
        harness.core.dispatcher.setListener { delivered.append($0) }
        await harness.initialize()
        harness.drainDeliveries()

        XCTAssertEqual(harness.core.attribution?.type, "organic")
        XCTAssertFalse(harness.storage.attributed)
        XCTAssertTrue(delivered.values.isEmpty)
    }

    func testAttributionSurvivesRestart() async throws {
        let first = TestHarness()
        first.http.script("/v1/init", .status(200, try Fixtures.initAttributed()))
        await first.initialize()

        let second = TestHarness(defaults: first.defaults)
        XCTAssertEqual(second.core.attribution?.linkId, "6711a0c2f1e4b8a9c3d2e1f0")
    }

    func testDictionaries() {
        let link = DeepLink(path: "/p", params: ["a": "1"], url: URL(string: "https://go.brand.com/x"), isDeferred: false)
        XCTAssertEqual(link.dictionary["path"] as? String, "/p")
        XCTAssertEqual(link.dictionary["params"] as? [String: String], ["a": "1"])
        XCTAssertEqual(link.dictionary["url"] as? String, "https://go.brand.com/x")
        XCTAssertEqual(link.dictionary["isDeferred"] as? Bool, false)
        XCTAssertNil(DeepLink(path: "/p", params: [:], url: nil, isDeferred: true).dictionary["url"])

        let attribution = Attribution(type: "attributed", method: "fingerprint", linkId: "l", confidence: 0.8)
        XCTAssertEqual(attribution.dictionary as NSDictionary,
                       ["type": "attributed", "method": "fingerprint", "linkId": "l", "confidence": 0.8] as NSDictionary)
    }
}
