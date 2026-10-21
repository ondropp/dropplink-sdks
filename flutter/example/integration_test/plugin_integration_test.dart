// Runs against the real native SDKs on a device or simulator:
//   flutter test integration_test
import 'package:dropplink_flutter/dropplink_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('initialize creates an install id', (tester) async {
    // A well-formed but unknown key: init gets 401 from the server, but the
    // install id is created locally either way.
    await Dropplink.initialize(keyId: 'ak_integration_test', secret: 'secret');

    String? installId;
    for (var i = 0; i < 50 && installId == null; i++) {
      installId = await Dropplink.getInstallId();
      if (installId == null) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    expect(
      installId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });

  testWidgets('getAttribution completes', (tester) async {
    // null on a fresh install with an unknown key; must not throw.
    await expectLater(Dropplink.getAttribution(), completes);
  });

  testWidgets('setTrackingEnabled round-trips through the native SDK', (
    tester,
  ) async {
    // The Dart calls swallow native failures, so check the value really
    // reached the native SDK and came back.
    await Dropplink.setTrackingEnabled(false);
    expect(await Dropplink.isTrackingEnabled(), isFalse);
    await Dropplink.setTrackingEnabled(true);
    expect(await Dropplink.isTrackingEnabled(), isTrue);

    await expectLater(
      Dropplink.track(
        'integration_test',
        props: <String, Object?>{'ok': true, 'n': 1, 'x': 1.5, 'none': null},
        revenue: const Revenue(amount: 1, currency: 'INR'),
      ),
      completes,
    );
    await expectLater(Dropplink.identify('integration_user'), completes);
    await expectLater(Dropplink.logout(), completes);
  });
}
