// Runs against the real native SDKs on a device or simulator:
//   flutter test integration_test
import 'package:dropplink/dropplink.dart';
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
}
