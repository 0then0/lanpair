import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/controller.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/platform_bridge.dart';
import 'package:lanpair/src/report.dart';
import 'package:lanpair/src/storage.dart';
import 'package:lanpair/src/ui_contract.dart';

class _Platform extends PlatformBridge {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<Map<String, dynamic>> capabilities({bool request = false}) async => {
    'platform': 'test',
    'permission': 'unknown',
    'rawMulticast': false,
    'discovery': false,
  };
}

RunReport _journal() => RunReport(
  sessionId: 'session',
  runId: 'run',
  reportingDeviceId: 'a',
  devices: const [
    DeviceEndpoint(
      id: 'a',
      address: '192.0.2.1',
      interfaceName: 'Ethernet "Office"',
    ),
    DeviceEndpoint(id: 'b', address: '192.0.2.10', interfaceName: 'Wi-Fi'),
  ],
  parameters: const RunPlan(),
  capabilities: const {'a.gateway': '192.168.42.99'},
  observations: [
    Observation(
      id: 'event',
      reporterId: 'a',
      kind: ObservationKind.sent,
      check: CheckKind.udp,
      fromDeviceId: 'a',
      toDeviceId: 'b',
      family: IpFamily.ipv4,
      sequence: 0,
      elapsedMicros: 500,
      wallTime: DateTime.utc(2026, 10, 29),
      interfaceName: 'Ethernet "Office"',
    ),
  ],
  startedAt: DateTime.utc(2026, 10, 29),
  durationMicros: 1000,
);

String _format(ReportExportView view) => jsonEncode({
  'fields': {for (final f in view.fields) f.label: f.value},
  'addresses': view.addresses,
  'interfaces': [
    for (final r in view.results)
      for (final o in r.observations) o.interfaceName,
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/file_selector');
  late Directory temporary;
  late AppController controller;
  late File exported;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lanpair-export-');
    exported = File('${temporary.path}/export');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getSavePath');
          return exported.path;
        });
    controller = AppController(
      platform: _Platform(),
      store: ReportStore(temporary),
    );
    await controller.initialize();
    await controller.importJournal(ReportCodec.encode(_journal()));
    expect(controller.errorCode, isNull);
  });
  tearDown(() async {
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  for (final readable in [false, true]) {
    test(
      'redacted ${readable ? 'readable' : 'JSON'} export hides private fields',
      () async {
        await controller.exportReport(
          redact: true,
          humanReadable: readable,
          formatReadableReport: _format,
        );
        expect(controller.errorCode, isNull);
        final text = await exported.readAsString();
        for (final original in [
          '192.168.42.99',
          '192.0.2.1',
          '192.0.2.10',
          'Ethernet',
          'Wi-Fi',
        ]) {
          expect(text, isNot(contains(original)), reason: original);
        }
        expect(text, contains('device-a-ipv4'));
        expect(text, contains('device-b-ipv4'));
        expect(text, contains('interface-a'));
        expect(text, contains('redacted'));
        // Export must not replace the original journal kept for private merging.
        expect(controller.exportAddresses, contains('192.0.2.1'));
      },
    );
  }
  test(
    'unredacted readable export retains original metadata and observations',
    () async {
      await controller.exportReport(
        redact: false,
        humanReadable: true,
        formatReadableReport: _format,
      );
      expect(controller.errorCode, isNull);
      final text = await exported.readAsString();
      expect(text, contains('192.168.42.99'));
      expect(text, contains('192.0.2.10'));
      expect(text, contains('Ethernet'));
      expect(text, contains('2026-10-29'));
    },
  );
  test(
    'an imported redaction marker cannot bypass export sanitization',
    () async {
      final claimed = _journal().toJson()
        ..['runId'] = 'claimed-redacted'
        ..['redacted'] = true;
      await controller.importJournal(jsonEncode(claimed));
      expect(controller.errorCode, isNull);
      await controller.exportReport(
        redact: true,
        humanReadable: true,
        formatReadableReport: _format,
      );
      expect(controller.errorCode, isNull);
      final text = await exported.readAsString();
      expect(text, isNot(contains('192.168.42.99')));
      expect(text, isNot(contains('192.0.2.1')));
      expect(text, isNot(contains('Ethernet')));
      expect(text, contains('device-a-ipv4'));
    },
  );
}
