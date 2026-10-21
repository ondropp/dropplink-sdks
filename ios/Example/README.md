# Dropplink example app

A minimal SwiftUI app: initializes the SDK in `App.init`, forwards Universal Links, shows the install id,
the attribution and the last deep link, and has buttons for `track`, `identify`, `logout` and
`setTrackingEnabled`. Just the source files are checked in, so there's no Xcode project
to keep in sync.

## Run it

1. Xcode → **File → New → Project → iOS App**, interface **SwiftUI**, name `DropplinkExample`, iOS 15+.
2. Delete the generated `*App.swift` and `ContentView.swift`; drag in the two `.swift` files from
   `DropplinkExample/`.
3. **File → Add Package Dependencies… → Add Local…** and pick this repo's `ios/` folder. Add the
   `Dropplink` library to the app target.
4. Keys: copy `Dropplink.xcconfig.example` to `Dropplink.xcconfig`, fill in the **iOS** key from the Dropp
   dashboard, set it as the base configuration for Debug and Release (Project → Info → Configurations),
   and add the two keys from `Info.plist.snippet.xml` to the target's Info.
5. Universal Links: target → **Signing & Capabilities → + Associated Domains** →
   `applinks:go.yourbrand.com` (your Dropp link domain). Needs a real team id and the domain registered in
   the Dropp dashboard.
6. Run. With `debug: true`, Console.app (filter `subsystem:app.ondropp.dropplink`) shows the install id
   and the init result. Paste the install id into **Dropp dashboard → Install debugger**.

To test against a local server, pass `baseURL: URL(string: "http://localhost:4100")!` in
`DropplinkExampleApp.swift`. The simulator reaches the Mac's `localhost` directly; plain `http` needs an
App Transport Security exception (`NSAllowsLocalNetworking`) in the Info.plist.
