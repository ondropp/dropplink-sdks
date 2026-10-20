import Foundation

/// Entry point of the Dropplink SDK.
///
/// ```swift
/// Dropplink.initialize(config: DropplinkConfig(keyId: "ak_…", secret: "…"))
/// Dropplink.setDeepLinkListener { link in router.open(link.path, link.params) }
/// ```
///
/// Every call is safe from any thread, never throws and never blocks on the network.
public enum Dropplink {
    /// The SDK version. Wrappers append a suffix to what is sent to the server (`0.1.0-flutter`).
    public static let version = "0.1.0"

    /// The process-wide SDK instance. Tests build their own `DropplinkCore` with fakes instead.
    static let core = DropplinkCore(environment: .live())

    /// Starts the SDK and sends `/v1/init` in the background. Call once, as early as possible
    /// (`App.init` or `application(_:didFinishLaunchingWithOptions:)`). Later calls are ignored.
    public static func initialize(config: DropplinkConfig) {
        core.initialize(config: config)
    }

    /// Receives every deep link: the deferred one after a fresh install and Universal Link opens.
    /// Called on the main thread. A link that arrives while no listener is set is held in memory
    /// (only the latest one) and delivered as soon as a listener is set. Pass `nil` to remove it.
    public static func setDeepLinkListener(_ listener: ((DeepLink) -> Void)?) {
        core.dispatcher.setListener(listener)
    }

    /// Reports a Universal Link the app was opened with. The link is resolved through the server and
    /// delivered to the listener. URLs that aren't `http(s)` are ignored.
    public static func handleDeepLink(_ url: URL) {
        core.handleDeepLink(url)
    }

    /// Convenience for `onContinueUserActivity` / `scene(_:continue:)`: forwards the activity's
    /// `webpageURL` to `handleDeepLink(_:)`. Returns `true` when the activity was a web link.
    @discardableResult
    public static func handleUserActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else {
            return false
        }
        core.handleDeepLink(url)
        return true
    }

    /// The last attribution the server returned, or `nil` before the first successful init. Cached on disk.
    public static var attribution: Attribution? { core.attribution }

    /// This install's id, for the dashboard's Install debugger. `nil` before `initialize`.
    public static var installId: String? { core.installId }
}
