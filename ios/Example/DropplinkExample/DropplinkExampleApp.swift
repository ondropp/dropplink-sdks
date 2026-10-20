import Dropplink
import SwiftUI

@main
struct DropplinkExampleApp: App {
    @StateObject private var model = ExampleModel()

    init() {
        // Keys come from Dropplink.xcconfig through Info.plist, never hard-coded (see README.md).
        let info = Bundle.main.infoDictionary ?? [:]
        Dropplink.initialize(config: DropplinkConfig(
            keyId: info["DropplinkKeyId"] as? String ?? "",
            secret: info["DropplinkSecret"] as? String ?? "",
            debug: true // Example only. Never ship `true`.
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // Custom-scheme opens and, on iOS 14+, Universal Links in SwiftUI apps.
                // Non-http(s) URLs are ignored by the SDK, so forwarding everything is safe.
                .onOpenURL { url in Dropplink.handleDeepLink(url) }
                // Universal Links delivered as a browsing-web user activity.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    Dropplink.handleUserActivity(activity)
                }
        }
    }
}

/// Receives deep links and exposes them to the UI.
@MainActor
final class ExampleModel: ObservableObject {
    @Published var lastLink: DeepLink?

    init() {
        // Set early: a deferred deep link that arrives before this is held and delivered now.
        Dropplink.setDeepLinkListener { [weak self] link in
            // Called on the main thread. A real app would route here, e.g. router.open(link.path, link.params).
            MainActor.assumeIsolated { self?.lastLink = link }
        }
    }
}
