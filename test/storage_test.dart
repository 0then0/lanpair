import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/storage.dart';

RunReport _report({
  String session = 'imported_session',
  String run = 'imported-run',
  List<Observation> observations = const [],
}) => RunReport(
  sessionId: session,
  runId: run,
  reportingDeviceId: 'a',
  devices: const [
    DeviceEndpoint(id: 'a', address: '192.0.2.10'),
    DeviceEndpoint(id: 'b', address: '192.0.2.20'),
  ],
  parameters: const RunPlan(),
  capabilities: const {'a.permission': 'granted'},
  observations: observations,
  startedAt: DateTime.utc(2026, 10, 29),
  durationMicros: 6000000,
  platform: 'macos',
);

void main() {
  late Directory directory;
  late ReportStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lanpair-storage-test-');
    store = ReportStore(directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('save and history accept every valid identifier shape', () {
    final report = _report(session: 'A_b-9', run: 'imported_run-with-hyphens');
    store.save(report);
    final restored = store.list().single;
    expect(restored.sessionId, report.sessionId);
    expect(restored.runId, report.runId);
    expect(restored.toJson(), report.toJson());
    final file = directory.listSync().single as File;
    expect(
      file.uri.pathSegments.last,
      matches(RegExp(r'^[a-f0-9]{64}\.json$')),
    );
  });

  test(
    'underscore-containing identifier pairs cannot overwrite each other',
    () {
      final first = _report(session: 'a_b', run: 'c');
      final second = _report(session: 'a', run: 'b_c');
      expect(
        '${first.sessionId}_${first.runId}',
        '${second.sessionId}_${second.runId}',
      );
      expect(reportStorageKey(first), isNot(reportStorageKey(second)));
      store.save(first);
      store.save(second);
      expect(
        store.list().map((r) => [r.sessionId, r.runId]).toList(),
        unorderedEquals([
          ['a_b', 'c'],
          ['a', 'b_c'],
        ]),
      );
      expect(directory.listSync(), hasLength(2));
    },
  );

  test(
    'saving an updated checkpoint replaces only its own report atomically',
    () {
      final first = _report();
      final event = Observation(
        id: 'event1',
        reporterId: 'a',
        kind: ObservationKind.sent,
        check: CheckKind.udp,
        fromDeviceId: 'a',
        toDeviceId: 'b',
        family: IpFamily.ipv4,
        elapsedMicros: 1000,
        wallTime: first.startedAt,
        sequence: 0,
      );
      store.save(first);
      store.save(_report(observations: [event]));
      expect(store.list().single.observations.single.id, event.id);
      expect(directory.listSync(), hasLength(1));
      expect(directory.listSync().any((f) => f.path.endsWith('.tmp')), isFalse);
    },
  );

  test('stored public reports contain no credential fields', () {
    store.save(_report());
    final text = (directory.listSync().single as File).readAsStringSync();
    final json = jsonDecode(text) as Map<String, dynamic>;
    expect(json['format'], 'lanpair-report');
    for (final credential in [
      'secret',
      'privateKeyPem',
      'certificatePem',
      'Authorization',
      'joiningIdentity',
      'localIdentity',
    ]) {
      expect(text, isNot(contains(credential)));
    }
  });

  test('corrupt, incompatible, oversized and unfinished files are skipped and preserved', () {
    final valid = _report();
    store.save(valid);
    final corrupt = File('${directory.path}/corrupted.json')
      ..writeAsStringSync('{');
    final incompatible = File('${directory.path}/future.json')
      ..writeAsStringSync(
        jsonEncode({...valid.toJson(), 'protocolVersion': 99}),
      );
    final oversized = File('${directory.path}/oversized.json')
      ..writeAsStringSync(' ' * (maxImportBytes + 1));
    final unfinished = File('${directory.path}/unfinished.tmp')
      ..writeAsStringSync('{');
    Directory('${directory.path}/folder.json').createSync();
    expect(store.list().single.runId, valid.runId);
    expect(
      [
        corrupt,
        incompatible,
        oversized,
        unfinished,
      ].every((file) => file.existsSync()),
      isTrue,
    );
  });
}
