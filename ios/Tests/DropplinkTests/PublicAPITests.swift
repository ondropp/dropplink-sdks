import XCTest
import Dropplink // deliberately not @testable: this file only sees the public API

/// Pins the public surface the Flutter and React Native bridges compile against.
/// If this file stops compiling, the change breaks the wrappers.
final class PublicAPITests: XCTestCase {
    func testPublicSurfaceCompiles() {
        XCTAssertEqual(Dropplink.version, "0.2.1")

        let config = DropplinkConfig(keyId: "ak_x", secret: "s", debug: false,
                                     baseURL: URL(string: "https://attribution.ondropp.app")!,
                                     platformWrapper: "flutter")
        XCTAssertEqual(config.keyId, "ak_x")

        let listener: ((DeepLink) -> Void)? = { link in
            _ = (link.path, link.params, link.url, link.isDeferred, link.dictionary)
        }
        let _: (DropplinkConfig) -> Void = Dropplink.initialize(config:)
        let _: (((DeepLink) -> Void)?) -> Void = Dropplink.setDeepLinkListener
        let _: (URL) -> Void = Dropplink.handleDeepLink
        let _: (NSUserActivity) -> Bool = Dropplink.handleUserActivity
        _ = listener

        let attribution: Attribution? = Dropplink.attribution
        let installId: String? = Dropplink.installId
        _ = (attribution, installId)

        let _: (String, [String: Any]?, Revenue?) -> Void = Dropplink.track(_:props:revenue:)
        let _: (String, String?, String?) -> Void = Dropplink.identify(userId:email:phone:)
        let _: () -> Void = Dropplink.logout
        let _: (Bool) -> Void = Dropplink.setTrackingEnabled
        let isTrackingEnabled: Bool = Dropplink.isTrackingEnabled
        _ = isTrackingEnabled

        let revenue = Revenue(amount: 499, currency: "INR")
        XCTAssertNil(revenue.orderId, "orderId defaults to nil")
        let withOrder = Revenue(amount: 499, currency: "INR", orderId: "A1023")
        _ = (withOrder.amount, withOrder.currency, withOrder.orderId)

        let a = Attribution(type: "organic", method: "none")
        _ = (a.type, a.method, a.clickId, a.linkId, a.campaignId, a.creatorId, a.source, a.attributedAt, a.confidence, a.dictionary)
    }
}
