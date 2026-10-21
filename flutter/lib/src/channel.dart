import 'package:flutter/services.dart';

import 'models.dart';

/// The platform-channel bridge to the native Dropplink SDKs.
///
/// Internal: not exported from `package:dropplink_flutter/dropplink_flutter.dart`. All logic
/// (signing, storage, retries, link buffering) lives in the native SDKs; this
/// class only forwards calls and converts results.
class DropplinkChannel {
  /// Creates the bridge. Tests can pass their own channels.
  DropplinkChannel({
    MethodChannel methods = const MethodChannel(methodChannelName),
    EventChannel deepLinks = const EventChannel(eventChannelName),
  }) : _methods = methods,
       _deepLinks = deepLinks;

  /// Name of the method channel shared with the native plugins.
  static const String methodChannelName = 'app.ondropp.dropplink/methods';

  /// Name of the event channel that streams deep links.
  static const String eventChannelName = 'app.ondropp.dropplink/deeplinks';

  final MethodChannel _methods;
  final EventChannel _deepLinks;
  Stream<DropplinkDeepLink>? _deepLinkStream;

  /// Calls the native `initialize`.
  Future<void> initialize({
    required String keyId,
    required String secret,
    required bool debug,
    String? baseUrl,
  }) {
    return _methods.invokeMethod<void>('initialize', <String, Object?>{
      'keyId': keyId,
      'secret': secret,
      'debug': debug,
      'baseUrl': ?baseUrl,
    });
  }

  /// Deep links from the native listener. Broadcast, created once.
  ///
  /// The native listener is attached when the first Dart subscriber listens
  /// and detached when the last one cancels; while detached, the native SDK
  /// holds the latest pending link and delivers it on the next listen.
  Stream<DropplinkDeepLink> get deepLinks => _deepLinkStream ??= _deepLinks
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map(
        (event) => DropplinkDeepLink.fromMap(event as Map<Object?, Object?>),
      );

  /// Calls the native `handleDeepLink`.
  Future<void> handleDeepLink(String url) {
    return _methods.invokeMethod<void>('handleDeepLink', <String, Object?>{
      'url': url,
    });
  }

  /// Calls the native `getAttribution`.
  Future<DropplinkAttribution?> getAttribution() async {
    final map = await _methods.invokeMapMethod<Object?, Object?>(
      'getAttribution',
    );
    return map == null ? null : DropplinkAttribution.fromMap(map);
  }

  /// Calls the native `getInstallId`.
  Future<String?> getInstallId() {
    return _methods.invokeMethod<String>('getInstallId');
  }

  /// Calls the native `track`. Null [props] and [revenue] are left out.
  Future<void> track(
    String name, {
    Map<String, Object?>? props,
    Revenue? revenue,
  }) {
    return _methods.invokeMethod<void>('track', <String, Object?>{
      'name': name,
      'props': ?props,
      'revenue': ?revenue?.toMap(),
    });
  }

  /// Calls the native `identify`. Null [email] and [phone] are left out.
  Future<void> identify(String userId, {String? email, String? phone}) {
    return _methods.invokeMethod<void>('identify', <String, Object?>{
      'userId': userId,
      'email': ?email,
      'phone': ?phone,
    });
  }

  /// Calls the native `logout`.
  Future<void> logout() => _methods.invokeMethod<void>('logout');

  /// Calls the native `setTrackingEnabled`.
  Future<void> setTrackingEnabled(bool enabled) {
    return _methods.invokeMethod<void>('setTrackingEnabled', <String, Object?>{
      'enabled': enabled,
    });
  }

  /// Calls the native `isTrackingEnabled`. `null` (no answer) reads as the
  /// native default, `true`.
  Future<bool> isTrackingEnabled() async {
    return await _methods.invokeMethod<bool>('isTrackingEnabled') ?? true;
  }
}
