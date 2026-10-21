# Dropplink for Flutter

`dropplink_flutter` attributes installs to the Dropplink link, channel and creator that brought them,
delivers deep links (the deferred one after a fresh install, and App Link / Universal Link opens), and
records in-app events and the signed-in user.

It is a thin bridge over the native SDKs ([`app.ondropp:dropplink-android`](../android) and the
[`Dropplink`](../ios) pod). Install ids, the Play Install Referrer, request signing, storage, retries and
pending-link buffering and the event queue all happen natively; the Dart code only forwards calls and converts results.
Behaviour is defined in [docs/sdk-spec.md](../docs/sdk-spec.md).

Flutter 3.38+, Android 5.0 (API 21)+, iOS 13+. Full guide: https://docs.ondropp.app/sdk/flutter

## Install

```sh
flutter pub add dropplink_flutter
cd ios && pod install
```

## Keys

Each app has two SDK keys in the Dropplink dashboard (**Settings → SDK keys**): one for Android and one for
iOS. Pass them at build time so they're never in your Dart source:

```sh
flutter run \
  --dart-define=DROPPLINK_ANDROID_KEY_ID=ak_... \
  --dart-define=DROPPLINK_ANDROID_SECRET=... \
  --dart-define=DROPPLINK_IOS_KEY_ID=ak_... \
  --dart-define=DROPPLINK_IOS_SECRET=...
```

Or keep them in a git-ignored JSON file and pass `--dart-define-from-file=dropplink.json`.

## Initialize

```dart
import 'dart:io';

import 'package:dropplink_flutter/dropplink_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Dropplink.initialize(
    keyId: Platform.isIOS
        ? const String.fromEnvironment('DROPPLINK_IOS_KEY_ID')
        : const String.fromEnvironment('DROPPLINK_ANDROID_KEY_ID'),
    secret: Platform.isIOS
        ? const String.fromEnvironment('DROPPLINK_IOS_SECRET')
        : const String.fromEnvironment('DROPPLINK_ANDROID_SECRET'),
    debug: kDebugMode, // native logs, tag "Dropplink". Never ship true.
  );
  runApp(const MyApp());
}
```

`initialize` returns once the native SDK has started; `/v1/init` runs in the background. It throws a
`PlatformException` with code `invalid_config` if a key id or secret is empty or malformed, which usually
means a `--dart-define` is missing.

## Deep links

Subscribe where you can navigate, e.g. in your root widget's `initState`:

```dart
_links = Dropplink.onDeepLink.listen((link) {
  // link.path = "/product/123", link.params = {"variant": "red"}
  router.go(link.path, extra: link.params);
});
```

`onDeepLink` is a broadcast stream of both kinds of link (`isDeferred` true for the link after a fresh
install, false for App Link / Universal Link opens). A link that arrives before anything listens is held
natively and delivered on the first listen.

### App Links and Universal Links

Set up your link domain's App Links intent filter (`android:autoVerify="true"`) and the Associated Domains
capability (`applinks:go.yourbrand.com`). The plugin forwards the links the app is opened with to the
native SDK by itself: the launch intent and `onNewIntent` on Android, and
`application(_:continue:restorationHandler:)` / the scene delegate on iOS.

Turn off Flutter's own deep linking, or it will also try to route the link's code (e.g. `/diwali`):

```xml
<!-- android/app/src/main/AndroidManifest.xml, inside <activity> -->
<meta-data android:name="flutter_deeplinking_enabled" android:value="false" />
```

```xml
<!-- ios/Runner/Info.plist -->
<key>FlutterDeepLinkingEnabled</key>
<false/>
```

If you already receive links through a package like `app_links`, turn off the plugin's forwarding and call
`Dropplink.handleDeepLink(url)` yourself, so each open is reported once:

```xml
<!-- android/app/src/main/AndroidManifest.xml, inside <application> -->
<meta-data android:name="app.ondropp.dropplink.auto_handle_links" android:value="false" />
```

```xml
<!-- ios/Runner/Info.plist -->
<key>DropplinkAutoHandleLinks</key>
<false/>
```

## Events, revenue and users

```dart
// Funnel events. Names are snake_case; props are String, num, bool or null (up to 20).
Dropplink.track('add_to_cart', props: {'sku': 'A1', 'qty': 2});

// After sign-up or login. Pass your own opaque id; email / phone are optional and hashed on the device.
Dropplink.identify(user.id, email: user.email);

// On logout. Later events carry no user.
Dropplink.logout();

// Consent: false clears queued events and stops tracking until set back to true. Persisted.
Dropplink.setTrackingEnabled(userConsented);
final enabled = await Dropplink.isTrackingEnabled();
```

Events are queued on disk by the native SDK and sent in the background, so these calls never throw and
don't need to be awaited. Calling `identify` with the same id again is a no-op, so it's fine on every launch.
Invalid events are dropped with a log in debug mode (see [sdk-spec.md §11](../docs/sdk-spec.md#11-events-revenue-and-users)).

**Revenue.** Send purchases that pay creators from your server, through `/v1/s2s/events`, so they can't be
forged from a device. Revenue sent from the app is shown in the dashboard as **app-reported**:

```dart
Dropplink.track('purchase', revenue: const Revenue(amount: 1299.0, currency: 'INR', orderId: 'ord_123'));
```

## API

```dart
abstract final class Dropplink {
  static Future<void> initialize({required String keyId, required String secret, bool debug = false, String? baseUrl});
  static Stream<DropplinkDeepLink> get onDeepLink;
  static Future<void> handleDeepLink(String url);
  static Future<DropplinkAttribution?> getAttribution(); // null before the first successful init
  static Future<String?> getInstallId();
  static Future<void> track(String name, {Map<String, Object?>? props, Revenue? revenue});
  static Future<void> identify(String userId, {String? email, String? phone});
  static Future<void> logout();
  static Future<void> setTrackingEnabled(bool enabled);
  static Future<bool> isTrackingEnabled();
}
```

`DropplinkDeepLink` has `path`, `params`, `url` (null for the deferred link) and `isDeferred`.
`DropplinkAttribution` has `type`, `method`, `clickId`, `linkId`, `campaignId`, `creatorId`, `source`,
`confidence`, `attributedAt` and `isAttributed`. `Revenue` has `amount`, `currency` (ISO 4217) and `orderId`. `baseUrl` is only for local testing, e.g.
`http://10.0.2.2:4100` from the Android emulator.

## Test your integration

Run with `debug: true`, copy the install id from the log (or show `await Dropplink.getInstallId()`), and
paste it into the dashboard's **Install debugger**. See https://docs.ondropp.app/sdk/testing.

## Development

```sh
flutter pub get
flutter analyze
flutter test                                   # Dart tests, method channel mocked

cd example
flutter test integration_test -d <device>      # real native SDKs on a device or simulator
flutter build apk --debug                      # Android, built against ../../android from source
```

The example builds the native SDKs from this repo: `example/ios/Podfile` points `Dropplink` at
`../../../ios`, and `example/android/settings.gradle.kts` substitutes `app.ondropp:dropplink-android`
with the `../../../android` build (turn off with `dropplink.useLocalSdk=false`).

### Why the package isn't called `dropplink`

A Flutter plugin's iOS pod and module are named after the package. A package named `dropplink` would
produce a `dropplink` framework next to the native `Dropplink` framework it depends on, and CocoaPods
rejects the two names as conflicting (`frameworks with conflicting names: dropplink`), which breaks every
iOS build. Hence `dropplink_flutter`.
