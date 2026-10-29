import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/controller.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/platform_bridge.dart';
import 'package:lanpair/src/report.dart';
import 'package:lanpair/src/storage.dart';

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

RunReport journal(
  String eventId, {
  String run = 'run',
  String reporter = 'a',
}) => RunReport(
  sessionId: 'session',
  runId: run,
  reportingDeviceId: reporter,
  devices: const [
    DeviceEndpoint(id: 'a', address: '192.0.2.1'),
    DeviceEndpoint(id: 'b', address: '192.0.2.2'),
  ],
  parameters: const RunPlan(),
  capabilities: {},
  startedAt: DateTime.utc(2026),
  durationMicros: 1000,
  observations: [
    Observation(
      id: eventId,
      reporterId: reporter,
      kind: ObservationKind.sent,
      check: CheckKind.udp,
      fromDeviceId: reporter,
      toDeviceId: reporter == 'a' ? 'b' : 'a',
      family: IpFamily.ipv4,
      sequence: 0,
      elapsedMicros: 500,
      wallTime: DateTime.utc(2026),
    ),
  ],
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late ReportStore store;
  late AppController controller;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lanpair-controller-');
    store = ReportStore(temporary);
    store.save(journal('old'));
    controller = AppController(platform: _Platform(), store: store);
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });
  test('first import after restart merges into stored history instead of replacing it', () async {
    expect(controller.results, isEmpty);
    await controller.importJournal(ReportCodec.encode(journal('new')));
    expect(controller.errorCode, isNull);
    expect(store.list().single.observations.map((o) => o.id).toSet(), {
      'old',
      'new',
    });
    expect(controller.history.single.observationCount, 2);
  });
  test(
    'redacted import cannot replace an existing original journal after restart',
    () async {
      await controller.importJournal(
        ReportCodec.encode(ReportCodec.redact(journal('new'))),
      );
      expect(controller.errorCode, 'importFailed');
      final saved = store.list().single;
      expect(saved.redacted, isFalse);
      expect(saved.observations.single.id, 'old');
    },
  );
  test('different runs can be imported and merged independently', () async {
    await controller.importJournal(ReportCodec.encode(journal('first')));
    await controller.importJournal(
      ReportCodec.encode(journal('second', run: 'another-run')),
    );
    expect(controller.errorCode, isNull);
    expect(controller.hasSession, isFalse);
    expect(controller.runId, 'another-run');
    expect(controller.history, hasLength(2));

    await controller.importJournal(ReportCodec.encode(journal('third')));
    expect(controller.errorCode, isNull);
    final saved = store.list();
    expect(saved, hasLength(2));
    expect(
      saved.singleWhere((r) => r.runId == 'run').observations.map((o) => o.id),
      unorderedEquals(['old', 'first', 'third']),
    );
    expect(
      saved.singleWhere((r) => r.runId == 'another-run').observations.single.id,
      'second',
    );
  });

  test(
    'history retains the reporting role of device B after restart',
    () async {
      final bReport = journal('b-event', run: 'b-run', reporter: 'b');
      store.save(bReport);
      controller.dispose();
      controller = AppController(platform: _Platform(), store: store);
      await controller.initialize();
      await controller.openHistory(reportStorageKey(bReport));
      expect(controller.errorCode, isNull);
      expect(controller.hasSession, isFalse);
      expect(controller.localRole, 'B');
      expect(controller.runId, 'b-run');
      expect(controller.results.any((r) => r.direction == 'B → A'), isTrue);
    },
  );
}
