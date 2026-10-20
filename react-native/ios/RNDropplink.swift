import Foundation
import React
import Dropplink

/// Thin bridge to the native Dropplink SDK. All behaviour (storage, signing, retries, pending-link
/// buffering) lives in the `Dropplink` pod; this class only converts arguments.
///
/// A classic `RCTEventEmitter` module (exported in `RNDropplink.m`): React Native 0.76+ serves it
/// to JS through the TurboModule interop layer under the New Architecture.
@objc(RNDropplink)
final class RNDropplink: RCTEventEmitter {
    private static let deepLinkEvent = "DropplinkDeepLink"
    private static let platformWrapper = "rn"

    override static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String]! { [Self.deepLinkEvent] }

    @objc(initializeSdk:resolver:rejecter:)
    func initializeSdk(
        _ config: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        let keyId = config["keyId"] as? String ?? ""
        let secret = config["secret"] as? String ?? ""
        let debug = config["debug"] as? Bool ?? false

        let sdkConfig: DropplinkConfig
        if let baseUrl = config["baseUrl"] as? String {
            guard let url = URL(string: baseUrl) else {
                reject("dropplink_initialize_failed", "baseUrl is not a valid URL: \(baseUrl)", nil)
                return
            }
            sdkConfig = DropplinkConfig(
                keyId: keyId, secret: secret, debug: debug, baseURL: url,
                platformWrapper: Self.platformWrapper)
        } else {
            // Leave the SDK's default baseURL in place.
            sdkConfig = DropplinkConfig(
                keyId: keyId, secret: secret, debug: debug, platformWrapper: Self.platformWrapper)
        }
        Dropplink.initialize(config: sdkConfig)
        resolve(nil)
    }

    @objc(handleDeepLink:resolver:rejecter:)
    func handleDeepLink(
        _ url: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        // Unparseable strings are dropped, like non-http(s) URLs are by the SDK.
        if let parsed = URL(string: url) {
            Dropplink.handleDeepLink(parsed)
        }
        resolve(nil)
    }

    @objc(getAttribution:rejecter:)
    func getAttribution(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolve(Dropplink.attribution?.dictionary)
    }

    @objc(getInstallId:rejecter:)
    func getInstallId(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolve(Dropplink.installId)
    }

    /// JS calls this with `true` when its first deep-link listener is added (the SDK then delivers
    /// any link it buffered) and `false` when the last one is removed (the SDK buffers again).
    @objc(setDeepLinkListenerEnabled:)
    func setDeepLinkListenerEnabled(_ enabled: Bool) {
        guard enabled else {
            Dropplink.setDeepLinkListener(nil)
            return
        }
        Dropplink.setDeepLinkListener { [weak self] link in
            self?.sendEvent(withName: Self.deepLinkEvent, body: link.dictionary)
        }
    }

    override func invalidate() {
        // JS context is going away (reload/teardown): let the SDK buffer links again.
        Dropplink.setDeepLinkListener(nil)
        super.invalidate()
    }
}
