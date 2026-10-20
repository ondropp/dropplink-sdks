import 'package:flutter/foundation.dart';

/// A deep link delivered by Dropplink.
///
/// Either the deferred link the server returns after a fresh install
/// ([isDeferred] is `true`, [url] is `null`), or an App Link / Universal Link
/// the app was opened with ([isDeferred] is `false`, [url] is the opened URL).
@immutable
class DropplinkDeepLink {
  /// Creates a deep link. Apps normally receive these from
  /// `Dropplink.onDeepLink` rather than building them.
  const DropplinkDeepLink({
    required this.path,
    this.params = const <String, String>{},
    this.url,
    this.isDeferred = false,
  });

  /// Builds a deep link from the map the native SDK sends over the platform
  /// channel. Unknown keys are ignored.
  factory DropplinkDeepLink.fromMap(Map<Object?, Object?> map) {
    final rawParams = map['params'];
    return DropplinkDeepLink(
      path: map['path'] as String? ?? '/',
      params: rawParams is Map
          ? Map<String, String>.unmodifiable(<String, String>{
              for (final entry in rawParams.entries)
                if (entry.key != null && entry.value != null)
                  entry.key.toString(): entry.value.toString(),
            })
          : const <String, String>{},
      url: map['url'] as String?,
      isDeferred: map['isDeferred'] as bool? ?? false,
    );
  }

  /// The in-app path to open, e.g. `/product/123`.
  final String path;

  /// Query parameters configured on the link, e.g. `{ref: creator}`.
  final Map<String, String> params;

  /// The URL the app was opened with, or `null` for a deferred link.
  final String? url;

  /// `true` only for the link delivered after a fresh install.
  final bool isDeferred;

  @override
  bool operator ==(Object other) =>
      other is DropplinkDeepLink &&
      other.path == path &&
      mapEquals(other.params, params) &&
      other.url == url &&
      other.isDeferred == isDeferred;

  @override
  int get hashCode => Object.hash(
    path,
    Object.hashAllUnordered(
      params.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    url,
    isDeferred,
  );

  @override
  String toString() =>
      'DropplinkDeepLink(path: $path, params: $params, url: $url, '
      'isDeferred: $isDeferred)';
}

/// How this install was attributed, as last returned by the server.
@immutable
class DropplinkAttribution {
  /// Creates an attribution. Apps normally get one from
  /// `Dropplink.getAttribution` rather than building it.
  const DropplinkAttribution({
    required this.type,
    required this.method,
    this.clickId,
    this.linkId,
    this.campaignId,
    this.creatorId,
    this.source,
    this.confidence,
    this.attributedAt,
  });

  /// Builds an attribution from the map the native SDK sends over the
  /// platform channel (the same shape as the server's `attribution` object).
  /// Unknown keys are ignored.
  factory DropplinkAttribution.fromMap(Map<Object?, Object?> map) {
    return DropplinkAttribution(
      type: map['type'] as String? ?? 'organic',
      method: map['method'] as String? ?? 'none',
      clickId: map['clickId'] as String?,
      linkId: map['linkId'] as String?,
      campaignId: map['campaignId'] as String?,
      creatorId: map['creatorId'] as String?,
      source: map['source'] as String?,
      confidence: (map['confidence'] as num?)?.toDouble(),
      attributedAt: map['attributedAt'] as String?,
    );
  }

  /// `attributed` or `organic`.
  final String type;

  /// `install_referrer`, `fingerprint` or `none`.
  final String method;

  /// The click this install was matched to.
  final String? clickId;

  /// The Dropplink link that was clicked.
  final String? linkId;

  /// The campaign the link belongs to.
  final String? campaignId;

  /// The creator the link belongs to.
  final String? creatorId;

  /// Where the click came from, e.g. `instagram`.
  final String? source;

  /// Match confidence from 0 to 1 (`1` for install referrer matches).
  final double? confidence;

  /// When the install was attributed, as an ISO 8601 string.
  final String? attributedAt;

  /// Whether [type] is `attributed`.
  bool get isAttributed => type == 'attributed';

  @override
  bool operator ==(Object other) =>
      other is DropplinkAttribution &&
      other.type == type &&
      other.method == method &&
      other.clickId == clickId &&
      other.linkId == linkId &&
      other.campaignId == campaignId &&
      other.creatorId == creatorId &&
      other.source == source &&
      other.confidence == confidence &&
      other.attributedAt == attributedAt;

  @override
  int get hashCode => Object.hash(
    type,
    method,
    clickId,
    linkId,
    campaignId,
    creatorId,
    source,
    confidence,
    attributedAt,
  );

  @override
  String toString() =>
      'DropplinkAttribution(type: $type, method: $method, clickId: $clickId, '
      'linkId: $linkId, campaignId: $campaignId, creatorId: $creatorId, '
      'source: $source, confidence: $confidence, attributedAt: $attributedAt)';
}
