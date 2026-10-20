import Flutter
import UIKit
import XCTest

@testable import dropplink

/// Bridge tests for the Swift side of the plugin. Run from Xcode (Runner scheme, Test).
class RunnerTests: XCTestCase {

    private func call(_ method: String, _ arguments: Any? = nil) -> Any? {
        let plugin = DropplinkPlugin()
        let done = expectation(description: "result called")
        var value: Any?
        plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { result in
            value = result
            done.fulfill()
        }
        waitForExpectations(timeout: 1)
        return value
    }

    func testUnknownMethodIsNotImplemented() {
        XCTAssertTrue(call("nope") as AnyObject === FlutterMethodNotImplemented as AnyObject)
    }

    func testHandleDeepLinkWithoutUrlIsAnError() {
        let error = call("handleDeepLink", [String: Any]()) as? FlutterError
        XCTAssertEqual(error?.code, "invalid_argument")
    }

    func testInitializeWithInvalidBaseUrlIsAnError() {
        let error = call("initialize", ["keyId": "ak_test", "secret": "s", "debug": false, "baseUrl": ""]) as? FlutterError
        XCTAssertEqual(error?.code, "invalid_config")
    }
}
