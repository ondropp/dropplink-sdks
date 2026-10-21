import 'dart:async';

import 'package:dropplink_flutter/dropplink_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Pass keys at build time, never commit them:
//   flutter run --dart-define=DROPPLINK_KEY_ID=ak_... --dart-define=DROPPLINK_SECRET=...
// Optionally --dart-define=DROPPLINK_BASE_URL=http://10.0.2.2:4100 for a local server.
const _keyId = String.fromEnvironment('DROPPLINK_KEY_ID');
const _secret = String.fromEnvironment('DROPPLINK_SECRET');
const _baseUrl = String.fromEnvironment('DROPPLINK_BASE_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? initError;
  try {
    await Dropplink.initialize(
      keyId: _keyId,
      secret: _secret,
      debug: true, // Example app only. Never ship debug: true.
      baseUrl: _baseUrl.isEmpty ? null : _baseUrl,
    );
  } on PlatformException catch (e) {
    // Only bad config gets here, e.g. no --dart-define keys.
    initError = '${e.code}: ${e.message}';
  }

  runApp(ExampleApp(initError: initError));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, this.initError});

  final String? initError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dropplink example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: HomePage(initError: initError),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initError});

  final String? initError;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<DropplinkDeepLink>? _links;
  String? _installId;
  DropplinkAttribution? _attribution;
  DropplinkDeepLink? _lastLink;

  @override
  void initState() {
    super.initState();
    // Listening late is fine: the native SDK holds a link that arrived earlier.
    _links = Dropplink.onDeepLink.listen((link) {
      setState(() => _lastLink = link);
      // A real app would route here, e.g. router.go(link.path).
    });
    _refresh();
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final installId = await Dropplink.getInstallId();
    final attribution = await Dropplink.getAttribution();
    if (!mounted) return;
    setState(() {
      _installId = installId;
      _attribution = attribution;
    });
  }

  void _show(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _trackEvent() async {
    await Dropplink.track(
      'add_to_cart',
      props: <String, Object?>{'sku': 'demo_sku', 'qty': 1, 'gift': false},
    );
    if (!mounted) return;
    _show('Tracked add_to_cart (see the native log)');
  }

  Future<void> _identify() async {
    // A real app passes its own opaque user id after sign-up or login.
    await Dropplink.identify('demo_user_1');
    if (!mounted) return;
    _show('Identified demo_user_1');
  }

  @override
  Widget build(BuildContext context) {
    final attribution = _attribution;
    final link = _lastLink;
    return Scaffold(
      appBar: AppBar(title: const Text('Dropplink example')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.initError != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  title: const Text('initialize failed'),
                  subtitle: Text(widget.initError!),
                ),
              ),
            _Section(
              title: 'Install id',
              trailing: IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: _installId == null
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: _installId!)),
              ),
              children: [
                SelectableText(
                  _installId ?? 'Not available yet (pull to refresh)',
                ),
                const SizedBox(height: 4),
                Text(
                  'Paste into Dropplink → Install debugger.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            _Section(
              title: 'Attribution',
              children: attribution == null
                  ? const [Text('None yet (pull to refresh after init)')]
                  : [
                      _Row('type', attribution.type),
                      _Row('method', attribution.method),
                      _Row('source', attribution.source),
                      _Row('linkId', attribution.linkId),
                      _Row('campaignId', attribution.campaignId),
                      _Row('creatorId', attribution.creatorId),
                      _Row('clickId', attribution.clickId),
                      _Row('confidence', attribution.confidence?.toString()),
                      _Row('attributedAt', attribution.attributedAt),
                    ],
            ),
            _Section(
              title: 'Last deep link',
              children: link == null
                  ? const [Text('None yet')]
                  : [
                      _Row('path', link.path),
                      _Row('params', link.params.toString()),
                      _Row('url', link.url),
                      _Row('isDeferred', link.isDeferred.toString()),
                    ],
            ),
            _Section(
              title: 'Events',
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _trackEvent,
                      child: const Text('Track add_to_cart'),
                    ),
                    OutlinedButton(
                      onPressed: _identify,
                      child: const Text('Identify demo_user_1'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: SelectableText(value ?? '–')),
        ],
      ),
    );
  }
}
