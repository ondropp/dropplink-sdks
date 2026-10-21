import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'channel.dart';
import 'models.dart';

/// Dropplink install attribution, deep linking and in-app events for Flutter
/// apps.
///
/// A thin bridge to the native Dropplink SDKs for Android and iOS, which do
/// all the work (signing, storage, the event queue, retries). Every call here
/// forwards to the native SDK.
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

  /// Records an in-app event, e.g. `track('add_to_cart', props: {'sku': 'A1'})`.
  ///
  /// The native SDK checks the event, writes it to its on-disk queue and
  /// sends it in the background, so this returns quickly and never throws.
  /// [name] must be snake_case (`^[a-z][a-z0-9_]{0,63}$`), or the event is
  /// dropped. Up to 20 [props], with String, num, bool or null values; other
  /// values, and values that look like an email or phone number, are dropped.
  ///
  /// [revenue] is shown as app-reported. Send purchases that pay creators
  /// from your server (`/v1/s2s/events`) and use `track` for the funnel.
  static Future<void> track(
    String name, {
    Map<String, Object?>? props,
    Revenue? revenue,
  }) => _quietly(() => _channel.track(name, props: props, revenue: revenue));

  /// Links your own user id to this install. Call it when the user signs up
  /// or logs in; calling it again with the same id is a no-op, so calling it
  /// on every launch is fine.
  ///
  /// Pass an opaque id, not an email or phone number. [email] and [phone]
  /// (E.164, e.g. `+919812345678`) are optional and hashed on the device
  /// before they leave it.
  static Future<void> identify(String userId, {String? email, String? phone}) =>
      _quietly(() => _channel.identify(userId, email: email, phone: phone));

  /// Unlinks the user, e.g. when they log out. Events after it carry no user.
  static Future<void> logout() => _quietly(_channel.logout);

  /// `false` clears the queued events and stops [track], [identify] and
  /// [logout], until it is set back to `true`. Persisted across launches by
  /// the native SDK, so it can hold the user's consent choice. Install
  /// attribution and deep links keep working. Default `true`.
  static Future<void> setTrackingEnabled(bool enabled) =>
      _quietly(() => _channel.setTrackingEnabled(enabled));

  /// The current [setTrackingEnabled] setting. `false` if the native SDK
  /// can't be reached, since nothing is tracked then (as in React Native).
  static Future<bool> isTrackingEnabled() async {
    try {
      return await _channel.isTrackingEnabled();
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // Event and user calls never throw (spec section 2): the native SDK logs
  // its own failures in debug mode, and an analytics call must not take the
  // app down with it.
  static Future<void> _quietly(Future<void> Function() call) async {
    try {
      await call();
    } on PlatformException {
      // Swallowed, see above.
    } on MissingPluginException {
      // No native plugin, e.g. an unsupported platform or a widget test.
    } on ArgumentError catch (error) {
      // A prop value the platform channel can't encode, e.g. a DateTime.
      assert(() {
        debugPrint('Dropplink: call dropped: $error');
        return true;
      }());
    }
  }
}
