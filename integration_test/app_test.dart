import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lanpair/src/app.dart';
import 'package:lanpair/src/controller.dart';
import 'package:lanpair/src/platform_bridge.dart';

/// Run on each installed native runner. This proves channel registration and
/// file-support startup, not physical LAN connectivity or OS permission denial.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native capabilities and application startup', (tester) async {
    final bridge = PlatformBridge();
    final capabilities = await bridge.capabilities();
    expect(capabilities['platform'], Platform.operatingSystem);
    expect(capabilities['rawMulticast'], isA<bool>());
    expect(capabilities['discovery'], isA<bool>());
    expect(
      capabilities['limitationCodes'],
      isNot(contains('nativeUnavailable')),
    );
    final controller = AppController(platform: bridge);
    await controller.initialize();
    await tester.pumpWidget(LanPairApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('LANPair'), findsWidgets);
    expect(controller.running, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
