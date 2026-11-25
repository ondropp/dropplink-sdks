import Dropplink
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ExampleModel
    @State private var installId = Dropplink.installId
    @State private var attribution = Dropplink.attribution
    @State private var trackingEnabled = Dropplink.isTrackingEnabled

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Install id"), footer: Text("Paste into Dropplink dashboard → Install debugger.")) {
                    Text(installId ?? "not initialized")
                        .font(.system(.footnote, design: .monospaced))
                        .contextMenu {
                            Button("Copy") { UIPasteboard.general.string = installId }
                        }
                }

                Section(header: Text("Attribution")) {
                    if let attribution {
                        row("type", attribution.type)
                        row("method", attribution.method)
                        row("source", attribution.source)
                        row("linkId", attribution.linkId)
                        row("confidence", attribution.confidence.map { String(format: "%.2f", $0) })
                    } else {
                        Text("None yet").foregroundColor(.secondary)
                    }
                    Button("Refresh") {
                        installId = Dropplink.installId
                        attribution = Dropplink.attribution
                    }
                }

                Section(header: Text("Events"), footer: Text("With debug on, Console shows each event queued and sent.")) {
                    Button("Track add_to_cart") {
                        Dropplink.track("add_to_cart", props: ["sku": "TSHIRT-M", "qty": 1])
                    }
                    // App-reported only: purchases that pay creators come from the brand's server.
                    Button("Track purchase (₹499)") {
                        Dropplink.track("purchase", revenue: Revenue(amount: 499, currency: "INR", orderId: UUID().uuidString))
                    }
                    Button("Identify demo_user_1") { Dropplink.identify(userId: "demo_user_1") }
                    Button("Logout") { Dropplink.logout() }
                    Toggle("Tracking enabled", isOn: Binding(
                        get: { trackingEnabled },
                        set: { Dropplink.setTrackingEnabled($0); trackingEnabled = $0 }
                    ))
                }

                Section(header: Text("Last deep link")) {
                    if let link = model.lastLink {
                        row("path", link.path)
                        row("params", link.params.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&"))
                        row("deferred", link.isDeferred ? "yes" : "no")
                        row("url", link.url?.absoluteString)
                    } else {
                        Text("Open a Dropplink link to see it here").foregroundColor(.secondary)
                    }
                }
            }
            .navigationBarTitle("Dropplink")
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value ?? "—").multilineTextAlignment(.trailing)
        }
    }
}
