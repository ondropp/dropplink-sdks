import Dropplink
import Flutter
import UIKit

/// Flutter bridge to the native Dropplink iOS SDK (pod `Dropplink`).
///
/// Holds no logic of its own: it forwards Dart calls to `Dropplink`, streams the SDK's deep links to
/// Dart, and forwards the Universal Links the app is opened with to `Dropplink.handleUserActivity`,
/// through both the application delegate and (for apps using the UIScene lifecycle) the scene
/// delegate, so apps get Universal Links without writing native code.
///
/// Automatic forwarding can be turned off by setting `DropplinkAutoHandleLinks` to `NO` in
/// Info.plist, for apps that call `Dropplink.handleDeepLink` from Dart themselves.
public final class DropplinkPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterSceneLifeCycleDelegate {
    static let methodChannelName = "app.ondropp.dropplink/methods"
    static let eventChannelName = "app.ondropp.dropplink/deeplinks"
    static let platformWrapper = "flutter"
    static let autoHandleLinksKey = "DropplinkAutoHandleLinks"

    /// Process-wide, like the native SDK.
    private static var initialized = false

    /// Universal Links the app was opened with before Dart called `initialize()`. The native SDK
    /// needs a config before it can resolve them, so they wait here (in memory only) until then.
    private var activitiesBeforeInit: [NSUserActivity] = []

    private let autoHandleLinks: Bool

    init(bundle: Bundle = .main) {
        autoHandleLinks = bundle.object(forInfoDictionaryKey: Self.autoHandleLinksKey) as? Bool ?? true
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = DropplinkPlugin()
        let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
        registrar.addApplicationDelegate(instance)
        registrar.addSceneDelegate(instance)
    }

    // MARK: - Method channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "initialize":
            initialize(args, result: result)
        case "handleDeepLink":
            guard let string = args["url"] as? String, let url = URL(string: string) else {
                result(FlutterError(code: "invalid_argument", message: "url is not a valid URL", details: nil))
                return
            }
            Dropplink.handleDeepLink(url)
            result(nil)
        case "getAttribution":
            result(Dropplink.attribution?.dictionary)
        case "getInstallId":
            result(Dropplink.installId)
        case "track":
            track(args, result: result)
        case "identify":
            guard let userId = args["userId"] as? String else {
                result(FlutterError(code: "invalid_argument", message: "userId is required", details: nil))
                return
            }
            Dropplink.identify(userId: userId, email: args["email"] as? String, phone: args["phone"] as? String)
            result(nil)
        case "logout":
            Dropplink.logout()
            result(nil)
        case "setTrackingEnabled":
            guard let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "invalid_argument", message: "enabled is required", details: nil))
                return
            }
            Dropplink.setTrackingEnabled(enabled)
            result(nil)
        case "isTrackingEnabled":
            result(Dropplink.isTrackingEnabled)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func track(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let name = args["name"] as? String else {
            result(FlutterError(code: "invalid_argument", message: "name is required", details: nil))
            return
        }
        var revenue: Revenue?
        if let raw = args["revenue"] as? [String: Any] {
            guard let amount = (raw["amount"] as? NSNumber)?.doubleValue, let currency = raw["currency"] as? String
            else {
                result(FlutterError(code: "invalid_argument", message: "revenue needs amount and currency", details: nil))
                return
            }
            revenue = Revenue(amount: amount, currency: currency, orderId: raw["orderId"] as? String)
        }
        let props = (args["props"] as? [String: Any])?.mapValues(Self.propValue)
        Dropplink.track(name, props: props, revenue: revenue)
        result(nil)
    }

    /// Unboxes a prop value from the Flutter codec into a Swift value. Dart bools and numbers both
    /// arrive as `NSNumber`, and `NSNumber(1) as? Bool` succeeds, so without this the native SDK
    /// couldn't tell `true` from `1`. Null stays `NSNull`; other values are passed on for the native
    /// SDK to drop (spec section 11).
    static func propValue(_ value: Any) -> Any {
        guard let number = value as? NSNumber else { return value }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if CFNumberIsFloatType(number) { return number.doubleValue }
        return number.intValue
    }

    private func initialize(_ args: [String: Any], result: @escaping FlutterResult) {
        let keyId = args["keyId"] as? String ?? ""
        let secret = args["secret"] as? String ?? ""
        let debug = args["debug"] as? Bool ?? false
        let config: DropplinkConfig
        if let baseUrl = args["baseUrl"] as? String {
            guard let baseURL = URL(string: baseUrl) else {
                result(FlutterError(code: "invalid_config", message: "baseUrl is not a valid URL", details: nil))
                return
            }
            config = DropplinkConfig(
                keyId: keyId, secret: secret, debug: debug, baseURL: baseURL, platformWrapper: Self.platformWrapper
            )
        } else {
            config = DropplinkConfig(keyId: keyId, secret: secret, debug: debug, platformWrapper: Self.platformWrapper)
        }
        Dropplink.initialize(config: config)
        Self.initialized = true
        let pending = activitiesBeforeInit
        activitiesBeforeInit.removeAll()
        pending.forEach { _ = Dropplink.handleUserActivity($0) }
        result(nil)
    }

    // MARK: - Event channel

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        // Setting the listener makes the native SDK deliver any link it was holding.
        Dropplink.setDeepLinkListener { link in
            let map = link.dictionary
            if Thread.isMainThread {
                events(map)
            } else {
                DispatchQueue.main.async { events(map) }
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Dropplink.setDeepLinkListener(nil)
        return nil
    }

    // MARK: - Universal Links

    // Apps without scenes: cold and warm starts both arrive here.
    public func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([Any]) -> Void
    ) -> Bool {
        forward(userActivity)
        return false
    }

    // Apps with scenes, cold start.
    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions?
    ) -> Bool {
        connectionOptions?.userActivities.forEach(forward)
        return false
    }

    // Apps with scenes, warm start.
    public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
        forward(userActivity)
        return false
    }

    // Returning false everywhere above leaves the activity for other plugins (app_links, …) too.
    private func forward(_ activity: NSUserActivity) {
        guard autoHandleLinks, activity.activityType == NSUserActivityTypeBrowsingWeb, activity.webpageURL != nil
        else { return }
        if Self.initialized {
            _ = Dropplink.handleUserActivity(activity)
        } else {
            activitiesBeforeInit.append(activity)
        }
    }
}
