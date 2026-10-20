import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dropplink/dropplink.dart';
import 'package:dropplink/src/channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads a fixture from the shared wire contract at the repo root.
Map<String, Object?> contract(String path) {
  final file = File('../contract/$path');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel(DropplinkChannel.methodChannelName);
  const events = EventChannel(DropplinkChannel.eventChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) reply;

  setUp(() {
    calls = <MethodCall>[];
    reply = (_) => null;
    // A fresh bridge per test, so the cached deep link stream is reset.
    Dropplink.channel = DropplinkChannel();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  group('initialize', () {
    test('sends keyId, secret and debug, omitting a null baseUrl', () async {
      await Dropplink.initialize(keyId: 'ak_test', secret: 's3cret');

      expect(calls, hasLength(1));
      expect(calls.single.method, 'initialize');
      expect(calls.single.arguments, <String, Object?>{
        'keyId': 'ak_test',
        'secret': 's3cret',
        'debug': false,
      });
    });

    test('sends debug and baseUrl when given', () async {
      await Dropplink.initialize(
        keyId: 'ak_test',
        secret: 's3cret',
        debug: true,
        baseUrl: 'http://10.0.2.2:4100',
      );

      expect(calls.single.arguments, <String, Object?>{
        'keyId': 'ak_test',
        'secret': 's3cret',
        'debug': true,
        'baseUrl': 'http://10.0.2.2:4100',
      });
    });

    test('surfaces a native config rejection as PlatformException', () {
      messenger.setMockMethodCallHandler(methods, (call) async {
        throw PlatformException(code: 'invalid_config', message: 'bad key');
      });

      expect(
        Dropplink.initialize(keyId: 'nope', secret: ''),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'invalid_config',
          ),
        ),
      );
    });
  });

  test('handleDeepLink sends the url', () async {
    await Dropplink.handleDeepLink('https://go.example.com/l/abc?x=1');

    expect(calls.single.method, 'handleDeepLink');
    expect(calls.single.arguments, <String, Object?>{
      'url': 'https://go.example.com/l/abc?x=1',
    });
  });

  group('getInstallId', () {
    test('returns the native id', () async {
      reply = (_) => '6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73';

      expect(
        await Dropplink.getInstallId(),
        '6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73',
      );
      expect(calls.single.method, 'getInstallId');
      expect(calls.single.arguments, isNull);
    });

    test('returns null before the native SDK has one', () async {
      expect(await Dropplink.getInstallId(), isNull);
    });
  });

  group('getAttribution', () {
    test('parses the attributed contract shape', () async {
      final fixture = contract('init/response.attributed.json');
      reply = (_) => fixture['attribution'];

      final attribution = await Dropplink.getAttribution();

      expect(calls.single.method, 'getAttribution');
      expect(
        attribution,
        const DropplinkAttribution(
          type: 'attributed',
          method: 'install_referrer',
          clickId: 'c_8b1f0e7d2a4c4f6e',
          linkId: '6711a0c2f1e4b8a9c3d2e1f0',
          campaignId: '6711a0c2f1e4b8a9c3d2e1f1',
          creatorId: '6711a0c2f1e4b8a9c3d2e1f2',
          source: 'instagram',
          confidence: 1.0,
          attributedAt: '2026-10-17T10:00:42.000Z',
        ),
      );
      expect(attribution!.isAttributed, isTrue);
      // The fixture has `"confidence": 1`; it must still come out a double.
      expect(attribution.confidence, isA<double>());
    });

    test('parses the organic contract shape', () async {
      final fixture = contract('init/response.organic.json');
      reply = (_) => fixture['attribution'];

      final attribution = await Dropplink.getAttribution();

      expect(attribution!.type, 'organic');
      expect(attribution.method, 'none');
      expect(attribution.isAttributed, isFalse);
      expect(attribution.linkId, isNull);
      expect(attribution.confidence, isNull);
    });

    test('returns null before the first successful init', () async {
      expect(await Dropplink.getAttribution(), isNull);
    });

    test('ignores unknown fields', () {
      final attribution = DropplinkAttribution.fromMap(<Object?, Object?>{
        'type': 'attributed',
        'method': 'fingerprint',
        'confidence': 0.82,
        'somethingNew': <String, Object?>{'a': 1},
      });

      expect(attribution.method, 'fingerprint');
      expect(attribution.confidence, 0.82);
    });
  });

  group('DropplinkDeepLink.fromMap', () {
    test('parses a deferred link from the init contract', () {
      final fixture = contract('init/response.attributed.json');
      final deepLink = fixture['deepLink']! as Map<String, Object?>;

      final link = DropplinkDeepLink.fromMap(<Object?, Object?>{
        ...deepLink,
        'url': null,
        'isDeferred': true,
      });

      expect(
        link,
        const DropplinkDeepLink(
          path: '/product/123',
          params: <String, String>{'ref': 'creator', 'variant': 'red'},
          isDeferred: true,
        ),
      );
    });

    test('parses an opened link from the deeplink contract', () {
      final fixture = contract('deeplink/response.matched.json');
      final deepLink = fixture['deepLink']! as Map<String, Object?>;

      final link = DropplinkDeepLink.fromMap(<Object?, Object?>{
        ...deepLink,
        'url': 'https://go.example.com/l/abc',
        'isDeferred': false,
      });

      expect(link.path, '/product/123');
      expect(link.params, <String, String>{'variant': 'red', 'ref': 'story'});
      expect(link.url, 'https://go.example.com/l/abc');
      expect(link.isDeferred, isFalse);
    });

    test('tolerates missing params and returns an unmodifiable map', () {
      final empty = DropplinkDeepLink.fromMap(<Object?, Object?>{'path': '/'});
      expect(empty.params, isEmpty);

      final link = DropplinkDeepLink.fromMap(<Object?, Object?>{
        'path': '/x',
        'params': <Object?, Object?>{'a': 'b'},
      });
      expect(() => link.params['c'] = 'd', throwsUnsupportedError);
    });
  });

  group('onDeepLink', () {
    test('delivers native events as DropplinkDeepLink', () async {
      var listens = 0;
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            listens++;
            sink.success(<Object?, Object?>{
              'path': '/product/123',
              'params': <Object?, Object?>{'ref': 'creator'},
              'url': null,
              'isDeferred': true,
            });
            sink.success(<Object?, Object?>{
              'path': '/sale',
              'params': <Object?, Object?>{},
              'url': 'https://go.example.com/l/sale',
              'isDeferred': false,
            });
          },
        ),
      );

      final links = await Dropplink.onDeepLink.take(2).toList();

      expect(listens, 1);
      expect(links[0].path, '/product/123');
      expect(links[0].params, <String, String>{'ref': 'creator'});
      expect(links[0].isDeferred, isTrue);
      expect(links[0].url, isNull);
      expect(links[1].path, '/sale');
      expect(links[1].url, 'https://go.example.com/l/sale');
      expect(links[1].isDeferred, isFalse);
    });

    test('is a broadcast stream sharing one native listener', () async {
      var listens = 0;
      var cancels = 0;
      late MockStreamHandlerEventSink nativeSink;
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            listens++;
            nativeSink = sink;
          },
          onCancel: (arguments) => cancels++,
        ),
      );

      expect(Dropplink.onDeepLink.isBroadcast, isTrue);
      final first = <DropplinkDeepLink>[];
      final second = <DropplinkDeepLink>[];
      final a = Dropplink.onDeepLink.listen(first.add);
      final b = Dropplink.onDeepLink.listen(second.add);
      await pumpEventQueue();

      nativeSink.success(<Object?, Object?>{'path': '/a', 'isDeferred': false});
      await pumpEventQueue();

      expect(listens, 1);
      expect(first.single.path, '/a');
      expect(second.single.path, '/a');

      await a.cancel();
      await b.cancel();
      await pumpEventQueue();
      expect(cancels, 1);
    });

    test('forwards native errors to the stream', () async {
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            sink.error(code: 'oops', message: 'native failure');
          },
        ),
      );

      final completer = Completer<Object>();
      final sub = Dropplink.onDeepLink.listen(
        (_) {},
        onError: completer.complete,
      );

      expect(await completer.future, isA<PlatformException>());
      await sub.cancel();
    });
  });
}
