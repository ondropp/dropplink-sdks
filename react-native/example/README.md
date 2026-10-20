# Dropplink React Native example

A single screen showing the install id, the attribution and the last deep link. Only the JS is
kept here (`App.tsx`, `index.js`); drop it into a fresh React Native app rather than carrying a
generated Android/iOS project in this repo.

## Run it

```sh
npx @react-native-community/cli init DropplinkExample
cd DropplinkExample

# The package from this repo (or from npm once published) plus react-native-config for keys.
npm install ../dropplink-sdks/react-native react-native-config
# If installing from the local folder, build it first: (cd ../dropplink-sdks/react-native && npm install)

# Replace the generated JS with this example's.
cp ../dropplink-sdks/react-native/example/{App.tsx,index.js,.env.example} .
cp .env.example .env   # then fill in your keys; .env must stay git-ignored

cd ios && pod install && cd ..
npx react-native run-android   # or run-ios
```

`react-native-config` needs one line of Android setup (`apply from: project(':react-native-config').projectDir.getPath() + "/dotenv.gradle"`
in `android/app/build.gradle`); see its README.

Until the native SDKs are on Maven Central / CocoaPods trunk, point the app at local builds:
`mavenLocal()` in `android/build.gradle` after `./gradlew publishToMavenLocal` in `../android`, and
`pod 'Dropplink', :path => '../../dropplink-sdks/ios'` in the Podfile.

## Try it

1. Launch the app with `debug: true` (the default in `__DEV__`). Logcat / Xcode console shows
   `Dropplink: install id …`.
2. Paste the install id into Dropplink → **Install debugger** to see what the server received.
3. Open a Dropplink link for your app (App Link / Universal Link). "Last deep link" updates with
   `isDeferred: false`. Uninstall, tap a link, install and launch to see the deferred one
   (`isDeferred: true`, `url: null`).
