# Dropplink SDKs

The SDKs brands add to their apps so Dropplink can attribute installs to the link, channel and creator
that brought them, and open deep links.

| Platform | Folder | Install | Docs |
| --- | --- | --- | --- |
| Android (Kotlin/Java) | [`android/`](./android) | `implementation("app.ondropp:dropplink-android:0.1.0")` | [README](./android/README.md) |
| iOS (Swift) | [`ios/`](./ios) | SPM or `pod 'Dropplink', '~> 0.1.0'` | [README](./ios/README.md) |
| Flutter | [`flutter/`](./flutter) | `flutter pub add dropplink_flutter` | [README](./flutter/README.md) |
| React Native | [`react-native/`](./react-native) | `npm install @ondropp/dropplink-react-native` | [README](./react-native/README.md) |

## How it fits together

```
 Brand's app ──► Dropplink SDK ── signed HTTPS ──► dropp-attribution  /v1/init, /v1/deeplink
                     │                                  (attribution.ondropp.app)
   Flutter / React Native packages are thin bridges
   to the native Android and iOS SDKs.
```

- **Native SDKs hold all the logic**: install id, Play Install Referrer, request signing, retries,
  deep-link delivery. The Flutter and React Native packages only forward calls, so a fix lands once.
- **One spec, four SDKs.** [`docs/sdk-spec.md`](./docs/sdk-spec.md) defines the public API and every
  behaviour. Change the spec first, then the code, in the same commit.
- **The server owns the wire contract.** [`contract/`](./contract) is a copy of
  `dropp-attribution`'s generated fixtures (JSON schemas, sample requests and responses, HMAC test
  vectors). Every native SDK's tests run against it. Refresh it with `scripts/sync-contract.sh`.

## Repository layout

```
contract/           wire fixtures from dropp-attribution (don't edit by hand)
docs/
  sdk-spec.md       public API and behaviour, shared by every SDK
  releasing.md      versioning and publishing
android/            Gradle project: :dropplink library + :sample app
ios/                Swift package + Dropplink.podspec
flutter/            Flutter plugin wrapping android/ and ios/
react-native/       React Native module wrapping android/ and ios/
scripts/            sync-contract.sh
.github/workflows/  one CI workflow per platform
```

## Working on an SDK

Each folder is self-contained and has its own README with build and test commands. Common rules are in
[CONTRIBUTING.md](./CONTRIBUTING.md).

| | Test command |
| --- | --- |
| Android | `cd android && ./gradlew :dropplink:testDebugUnitTest` |
| iOS | `cd ios && swift test` |
| Flutter | `cd flutter && flutter test` |
| React Native | `cd react-native && npm test` |

## For brands

The integration steps, with the app's key IDs filled in, are in the Dropplink dashboard under **SDK
setup**. After integrating, tap a link on a test phone, install, and paste the install ID from the SDK's
debug log into **Install debugger** to see how it was attributed.
