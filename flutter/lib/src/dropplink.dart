import 'package:flutter/foundation.dart';

import 'channel.dart';
import 'models.dart';

/// Dropplink install attribution and deep linking for Flutter apps.
///
/// A thin bridge to the native Dropplink SDKs for Android and iOS, which do
/// all the work (signing, storage, retries). Every call here forwards to the
/// native SDK.
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Dropplink.initialize(
///     keyId: const String.fromEnvironment('DROPPLINK_KEY_ID'),
///     secret: const String.fromEnvironment('DROPPLINK_SECRET'),
///   );
///   Dropplink.onDeepLink.listen((link) => router.go(link.path));
///   runApp(const MyApp());
/// }
/// ```
abstract final class Dropplink {
  static DropplinkChannel _channel = DropplinkChannel();

  /// Replaces the platform bridge. For tests only.
  @visibleForTesting
  static set channel(DropplinkChannel channel) => _channel = channel;

  /// Starts the SDK. Call once, as early as possible (in `main()`, before
  /// `runApp`). Later calls are ignored by the native SDK.
  ///
  /// [keyId] (`ak_…`) and [secret] come from the Dropplink dashboard, one pair
  /// per platform. Pass them with `--dart-define` rather than committing them.
  /// [debug] turns on native logging, including the install id to paste into
  /// the dashboard's Install debugger. Never ship `debug: true`.
  /// [baseUrl] overrides the server, e.g. `http://10.0.2.2:4100` for local
  /// testing.
  ///
  /// Throws a `PlatformException` with code `invalid_config` if the native SDK
  /// rejects the config (empty key id or secret, key id not starting with
  /// `ak_`). Network errors never surface here.
  static Future<void> initialize({
    required String keyId,
    required String secret,
    bool debug = false,
    String? baseUrl,
  }) {
    return _channel.initialize(
      keyId: keyId,
      secret: secret,
      debug: debug,
      baseUrl: baseUrl,
    );
  }

  /// Every deep link: the deferred one after a fresh install, and App Link /
  /// Universal Link opens.
  ///
  /// A broadcast stream. A link that arrives before anything listens is held
  /// by the native SDK (the latest one only, in memory) and delivered on the
  /// first listen, so it is safe to subscribe after `runApp`.
  static Stream<DropplinkDeepLink> get onDeepLink => _channel.deepLinks;

  /// Reports an App Link / Universal Link the app was opened with, and
  /// delivers the resolved link on [onDeepLink].
  ///
  /// The plugin already forwards the links Android and iOS open the app with,
  /// so most apps never call this. Use it when you receive links some other
  /// way and have turned automatic forwarding off (see the README). URLs that
  /// aren't `http(s)` are ignored.
  static Future<void> handleDeepLink(String url) =>
      _channel.handleDeepLink(url);

  /// The last attribution the server returned, or `null` before the first
  /// successful init. Cached on disk by the native SDK.
  static Future<DropplinkAttribution?> getAttribution() =>
      _channel.getAttribution();

  /// This install's id, for the dashboard's Install debugger. May be `null`
  /// very early, before the native SDK has loaded or created it.
  static Future<String?> getInstallId() => _channel.getInstallId();
}
