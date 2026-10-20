# dropplink_example

Shows the install id, the last attribution and the last deep link.

```sh
flutter run --dart-define=DROPPLINK_KEY_ID=ak_... --dart-define=DROPPLINK_SECRET=...
# against a local server from the Android emulator:
flutter run --dart-define=DROPPLINK_KEY_ID=ak_... --dart-define=DROPPLINK_SECRET=... \
  --dart-define=DROPPLINK_BASE_URL=http://10.0.2.2:4100
```

Inside the dropplink-sdks repo the example builds the native SDKs from source:
`ios/Podfile` points `pod 'Dropplink'` at `../../../ios`, and `android/settings.gradle.kts`
includes `../../../android` as a composite build (turn off with `dropplink.useLocalSdk=false` in
`android/gradle.properties`). Gradle doesn't allow two Android Gradle plugin versions in one
composite build, so while the local SDK is used the example takes its AGP version from
`../../../android/gradle/libs.versions.toml`.

Replace `links.example.com` in `android/app/src/main/AndroidManifest.xml` with your link domain to
try App Links, and add the Associated Domains capability (`applinks:<your domain>`) to the Runner
target in Xcode to try Universal Links.
