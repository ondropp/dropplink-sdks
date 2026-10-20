import Dropplink
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ExampleModel
    @State private var installId = Dropplink.installId
    @State private var attribution = Dropplink.attribution

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Install id"), footer: Text("Paste into Dropp dashboard → Install debugger.")) {
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

                Section(header: Text("Last deep link")) {
                    if let link = model.lastLink {
                        row("path", link.path)
                        row("params", link.params.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&"))
                        row("deferred", link.isDeferred ? "yes" : "no")
                        row("url", link.url?.absoluteString)
                    } else {
                        Text("Open a Dropp link to see it here").foregroundColor(.secondary)
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
