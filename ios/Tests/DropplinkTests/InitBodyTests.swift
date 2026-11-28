import XCTest
@testable import Dropplink

/// Spec §10.2: the init body has the fields and types of `contract/init/request.ios.json`.
final class InitBodyTests: XCTestCase {
    func testFixtureValuesEncodeToTheContractRequest() throws {
        let fixture = try Contract.json("init/request.ios.json")
        let device = try XCTUnwrap(fixture["device"] as? [String: Any])
        let body = InitBody(
            installId: try XCTUnwrap(fixture["installId"] as? String),
            appVersion: try XCTUnwrap(fixture["appVersion"] as? String),
            sdkVersion: try XCTUnwrap(fixture["sdkVersion"] as? String),
            device: DeviceInfo(model: device["model"] as! String, osVersion: device["osVersion"] as! String,
                               locale: device["locale"] as! String, timezone: device["timezone"] as! String, screen: nil),
            reinstallKey: try XCTUnwrap(fixture["reinstallKey"] as? String)
        )
        let encoded = try JSONSerialization.jsonObject(with: APIClient.makeEncoder().encode(body)) as? NSDictionary
        XCTAssertEqual(encoded, fixture as NSDictionary)
    }

    func testSentBodyMatchesTheContractShape() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        await harness.initialize()

        let request = try XCTUnwrap(harness.http.requests(to: "/v1/init").first)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let fixture = try Contract.json("init/request.ios.json")

        assertSameShape(sent, fixture, path: "", optional: ["device.screen"])
        XCTAssertNil(sent["installReferrer"], "iOS never sends installReferrer")
        XCTAssertEqual(sent["platform"] as? String, "ios")
        XCTAssertEqual(sent["sdkVersion"] as? String, "0.2.1")
        XCTAssertEqual(sent["installId"] as? String, harness.core.installId)
        XCTAssertEqual(sent["reinstallKey"] as? String, TestHarness.reinstallKey)

        let screen = try XCTUnwrap((sent["device"] as? [String: Any])?["screen"] as? [String: Any])
        XCTAssertEqual(screen["w"] as? Int, 1179)
        XCTAssertEqual(screen["h"] as? Int, 2556)
        XCTAssertEqual(screen["dpr"] as? Double, 3)
    }

    func testReinstallKeyIsLeftOutWhenTheKeychainHasNone() throws {
        let body = InitBody(installId: "x", appVersion: "1", sdkVersion: "0.2.1", device: TestHarness.device)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.makeEncoder().encode(body)) as? [String: Any])
        XCTAssertNil(encoded["reinstallKey"])
    }

    func testWrapperSuffixesTheSDKVersion() {
        XCTAssertEqual(DropplinkConfig(keyId: "ak_x", secret: "s").sdkVersion, "0.2.1")
        XCTAssertEqual(DropplinkConfig(keyId: "ak_x", secret: "s", platformWrapper: "flutter").sdkVersion, "0.2.1-flutter")
        XCTAssertEqual(DropplinkConfig(keyId: "ak_x", secret: "s", platformWrapper: "rn").sdkVersion, "0.2.1-rn")
    }

    func testLongValuesAreTruncatedToContractLimits() {
        let device = DeviceInfo(model: String(repeating: "m", count: 150), osVersion: String(repeating: "1", count: 40),
                                locale: String(repeating: "l", count: 50), timezone: String(repeating: "t", count: 80), screen: nil)
        XCTAssertEqual(device.model.count, 100)
        XCTAssertEqual(device.osVersion.count, 32)
        XCTAssertEqual(device.locale.count, 35)
        XCTAssertEqual(device.timezone.count, 64)
        let body = InitBody(installId: "x", appVersion: String(repeating: "9", count: 70), sdkVersion: "0.2.1", device: device)
        XCTAssertEqual(body.appVersion.count, 64)
        // Never splits a character (measured in UTF-16 units, as the server does).
        XCTAssertEqual("ab🛒".truncated(to: 3), "ab")
    }

    func testDeviceInfoHelpers() async {
        XCTAssertEqual(DeviceInfo.bcp47(Locale(identifier: "en_IN@calendar=gregorian")), "en-IN")
        XCTAssertEqual(DeviceInfo.bcp47(Locale(identifier: "hi_IN")), "hi-IN")
        XCTAssertFalse(DeviceInfo.hardwareModel().isEmpty)
        XCTAssertTrue(DeviceInfo.osVersion().contains("."))
        let current = await DeviceInfo.current()
        XCTAssertEqual(current.timezone, TimeZone.current.identifier)
    }

    func testInstallIdIsAPersistedLowercaseUUIDv4() throws {
        let harness = TestHarness()
        let id = harness.storage.loadOrCreateInstallId()
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(Array(id)[14], "4", "version 4")
        XCTAssertEqual(harness.storage.loadOrCreateInstallId(), id, "never regenerated")
        XCTAssertEqual(Storage(defaults: harness.defaults).loadOrCreateInstallId(), id, "survives restarts")
    }

    /// Every key of `expected` exists in `actual` with the same JSON type, and `actual` has no keys
    /// beyond `expected` other than `optional` ones.
    private func assertSameShape(_ actual: [String: Any], _ expected: [String: Any], path: String,
                                 optional: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        for (key, value) in expected {
            let keyPath = path.isEmpty ? key : "\(path).\(key)"
            guard let actualValue = actual[key] else {
                XCTFail("missing \(keyPath)", file: file, line: line)
                continue
            }
            if let nested = value as? [String: Any] {
                guard let actualNested = actualValue as? [String: Any] else {
                    XCTFail("\(keyPath) should be an object", file: file, line: line)
                    continue
                }
                assertSameShape(actualNested, nested, path: keyPath, optional: optional, file: file, line: line)
            } else {
                XCTAssertEqual(jsonType(actualValue), jsonType(value), "type of \(keyPath)", file: file, line: line)
            }
        }
        for key in actual.keys where expected[key] == nil {
            let keyPath = path.isEmpty ? key : "\(path).\(key)"
            XCTAssertTrue(optional.contains(keyPath), "unexpected field \(keyPath)", file: file, line: line)
        }
    }

    private func jsonType(_ value: Any) -> String {
        switch value {
        case is String: return "string"
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return "boolean"
        case is NSNumber: return "number"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return "null"
        }
    }
}
