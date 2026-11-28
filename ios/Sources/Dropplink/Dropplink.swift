import Foundation

/// Entry point of the Dropplink SDK.
///
/// ```swift
/// Dropplink.initialize(config: DropplinkConfig(keyId: "ak_…", secret: "…"))
/// Dropplink.setDeepLinkListener { link in router.open(link.path, link.params) }
/// Dropplink.track("add_to_cart", props: ["sku": "TSHIRT-M", "qty": 1])
/// ```
///
/// Every call is safe from any thread, never throws and never blocks on the network.
public enum Dropplink {
    /// The SDK version. Wrappers append a suffix to what is sent to the server (`0.2.1-flutter`).
    public static let version = "0.2.1"

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

    // MARK: Events, revenue and users

    /// Records an in-app event. It's checked on the device (invalid events and props are dropped, with
    /// a debug log), written to an on-disk queue and sent in the background, so it survives being
    /// offline or killed.
    ///
    /// - Parameters:
    ///   - name: `snake_case`, e.g. `"add_to_cart"`: a lower-case letter, then up to 63 of `a-z 0-9 _`.
    ///   - props: Up to 20 values: `String` (≤ 256 characters), numbers, `Bool` or `NSNull`. No personal
    ///     data: a value containing an email or that is a phone number is dropped.
    ///   - revenue: Shown as **app-reported**. Purchases that pay creators must be sent from your server
    ///     (`/v1/s2s/events`); use `track` for the funnel.
    public static func track(_ name: String, props: [String: Any]? = nil, revenue: Revenue? = nil) {
        core.events.track(name, props: props, revenue: revenue)
    }

    /// Links your own user id to this install when the user signs up or logs in. Use an opaque id, not
    /// an email or phone number. `email` and `phone` (E.164, e.g. `+919876543210`) are hashed with
    /// SHA-256 on the device; the plain values never leave it. Calling it again with the same user id
    /// does nothing, so it's fine to call on every launch.
    public static func identify(userId: String, email: String? = nil, phone: String? = nil) {
        core.events.identify(userId: userId, email: email, phone: phone)
    }

    /// Unlinks the user. Events tracked after it carry no user.
    public static func logout() {
        core.events.logout()
    }

    /// `false` clears the event queue and stops `track`, `identify` and `logout` until it's set back to
    /// `true`, across launches (for consent). Install attribution and deep links keep working.
    public static func setTrackingEnabled(_ enabled: Bool) {
        core.events.setTrackingEnabled(enabled)
    }

    /// The current `setTrackingEnabled(_:)` setting. `true` by default.
    public static var isTrackingEnabled: Bool { core.events.isTrackingEnabled }
}
