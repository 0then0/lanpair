import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/identity.dart';
import 'package:lanpair/src/report.dart';

final _time = DateTime.utc(2026, 10, 29);
const _devices = [
  DeviceEndpoint(
    id: 'a',
    address: '192.0.2.10',
    ipv6Address: 'fe80::10%en0',
    interfaceName: 'en0',
    interfaceIndex: 4,
  ),
  DeviceEndpoint(
    id: 'b',
    address: '192.0.2.20',
    ipv6Address: 'fe80::20%wlan0',
    interfaceName: 'wlan0',
    interfaceIndex: 7,
  ),
];

Observation _event(
  String id,
  ObservationKind kind, {
  CheckKind check = CheckKind.udp,
  String from = 'a',
  String to = 'b',
  String reporter = 'a',
  int elapsed = 1000,
  int? sequence,
  IpFamily family = IpFamily.ipv4,
}) => Observation(
  id: id,
  reporterId: reporter,
  kind: kind,
  check: check,
  fromDeviceId: from,
  toDeviceId: to,
  family: family,
  elapsedMicros: elapsed,
  wallTime: _time,
  sequence: sequence,
  interfaceName: reporter == 'a' ? 'en0' : 'wlan0',
);

RunReport _report({
  String reporter = 'a',
  List<Observation> events = const [],
  DateTime? time,
  List<DeviceEndpoint> devices = _devices,
  String run = 'run1',
  RunPlan plan = const RunPlan(),
  Map<String, String> capabilities = const {},
}) => RunReport(
  sessionId: 'session1',
  runId: run,
  reportingDeviceId: reporter,
  devices: devices,
  parameters: plan,
  capabilities: capabilities,
  observations: events,
  startedAt: time ?? _time,
  durationMicros: 6000000,
  platform: reporter == 'a' ? 'macos' : 'android',
);

CheckResult _result(
  RunReport report, {
  CheckKind check = CheckKind.udp,
  String from = 'a',
  IpFamily family = IpFamily.ipv4,
}) => interpret(report).singleWhere(
  (r) => r.check == check && r.fromDeviceId == from && r.family == family,
);

void main() {
  test('a first journal must match the active accepted invitation', () async {
    final identities = await Future.wait([createIdentity(), createIdentity()]);
    final session = Session.create(
      a: _devices[0],
      b: _devices[1],
      aIdentity: identities[0],
      bIdentity: identities[1],
    );
    RunReport journal({
      String? run,
      List<DeviceEndpoint>? devices,
      RunPlan? plan,
    }) => RunReport(
      sessionId: session.sessionId,
      runId: run ?? session.runId,
      reportingDeviceId: 'a',
      devices: devices ?? _devices,
      parameters: plan ?? session.plan,
      capabilities: {},
      observations: [],
      startedAt: _time,
      durationMicros: 0,
    );
    expect(() => validateSessionReport(session, journal()), returnsNormally);
    expect(
      () => validateSessionReport(session, journal(run: 'different-run')),
      throwsFormatException,
    );
    expect(
      () => validateSessionReport(
        session,
        journal(devices: _devices.reversed.toList()),
      ),
      throwsFormatException,
    );
    expect(
      () => validateSessionReport(
        session,
        journal(plan: const RunPlan(durationMs: 8000)),
      ),
      throwsFormatException,
    );
  });

  test(
    'export records interpretation grounds and rejects forged conclusions',
    () {
      final report = _report(events: [_event('s1', ObservationKind.sent)]);
      final encoded =
          jsonDecode(ReportCodec.encode(report)) as Map<String, dynamic>;
      final analysis = encoded['interpretation'] as Map<String, dynamic>;
      expect(analysis['version'], 1);
      final results = analysis['results'] as List;
      expect(results, hasLength(14));
      final delivery = results.cast<Map>().firstWhere(
        (r) =>
            r['check'] == 'udp' &&
            r['family'] == 'ipv4' &&
            r['fromDeviceId'] == 'a',
      );
      expect(delivery['evidenceIds'], ['s1']);
      delivery['outcome'] = 'passed';
      expect(
        () => ReportCodec.decode(jsonEncode(encoded)),
        throwsFormatException,
      );
    },
  );

  test('sender socket success alone does not establish UDP delivery', () {
    final result = _result(
      _report(
        events: [
          _event('s1', ObservationKind.sent),
          _event('timeout', ObservationKind.timedOut),
        ],
      ),
    );
    expect(result.outcome, Outcome.inconclusive);
    expect(result.reason, 'sent_delivery_unknown');
  });

  test(
    'an unconfigured peer address is inconclusive, not platform unsupported',
    () {
      final event = Observation(
        id: 'unconfigured',
        reporterId: 'a',
        kind: ObservationKind.unsupported,
        check: CheckKind.tcp,
        fromDeviceId: 'a',
        toDeviceId: 'b',
        family: IpFamily.ipv4,
        elapsedMicros: 1000,
        wallTime: _time,
        code: 'peer_address_unavailable',
      );
      final result = _result(_report(events: [event]), check: CheckKind.tcp);
      expect(result.outcome, Outcome.inconclusive);
      expect(result.reason, 'missing_observations');
    },
  );

  test(
    'merged peer reception establishes delivery when acknowledgement is lost',
    () {
      final sender = _report(
        events: [
          _event('s1', ObservationKind.sent, sequence: 0),
          _event('timeout', ObservationKind.timedOut),
        ],
      );
      final receiver = _report(
        reporter: 'b',
        events: [
          _event('r1', ObservationKind.received, reporter: 'b', sequence: 0),
        ],
      );
      expect(_result(sender).outcome, Outcome.inconclusive);
      final merged = ReportCodec.merge(sender, receiver);
      expect(_result(merged).outcome, Outcome.passed);
      expect(_result(merged).reason, 'peer_received');
      expect(_result(merged).evidenceIds, ['r1']);
    },
  );

  test('returned acknowledgement is independent evidence of peer receipt', () {
    final result = _result(
      _report(
        events: [_event('a1', ObservationKind.acknowledged, sequence: 0)],
      ),
    );
    expect(result.outcome, Outcome.passed);
    expect(result.reason, 'acknowledgement_received');
  });

  test('each TCP direction requires a separate outgoing connection', () {
    final report = _report(
      events: [
        _event('connected', ObservationKind.connected, check: CheckKind.tcp),
        _event(
          'reply',
          ObservationKind.received,
          check: CheckKind.tcp,
          from: 'b',
          to: 'a',
        ),
        _event(
          'reverse_timeout',
          ObservationKind.timedOut,
          check: CheckKind.tcp,
          from: 'b',
          to: 'a',
        ),
      ],
    );
    expect(_result(report, check: CheckKind.tcp).outcome, Outcome.passed);
    expect(
      _result(report, check: CheckKind.tcp, from: 'b').outcome,
      Outcome.failed,
    );
  });

  test('unicast can pass while multicast remains unobserved', () {
    final report = _report(
      events: [
        _event('tcp', ObservationKind.connected, check: CheckKind.tcp),
        _event('udp', ObservationKind.acknowledged),
        _event('multicast', ObservationKind.sent, check: CheckKind.multicast),
        _event('timeout', ObservationKind.timedOut, check: CheckKind.multicast),
      ],
    );
    expect(_result(report, check: CheckKind.tcp).outcome, Outcome.passed);
    expect(_result(report).outcome, Outcome.passed);
    expect(
      _result(report, check: CheckKind.multicast).outcome,
      Outcome.inconclusive,
    );
  });

  test(
    'multicast loopback and sender-authored receive events never pass delivery',
    () {
      final report = _report(
        events: [
          _event(
            'self',
            ObservationKind.received,
            check: CheckKind.multicast,
            to: 'a',
          ),
          _event(
            'wrong_reporter',
            ObservationKind.received,
            check: CheckKind.multicast,
          ),
        ],
      );
      expect(
        _result(report, check: CheckKind.multicast).outcome,
        isNot(Outcome.passed),
      );
    },
  );

  test(
    'IPv4 observations cannot establish IPv6 and no IPv6 is unsupported',
    () {
      final report = _report(
        events: [_event('ok', ObservationKind.acknowledged)],
      );
      expect(_result(report).outcome, Outcome.passed);
      expect(
        _result(report, family: IpFamily.ipv6).outcome,
        Outcome.inconclusive,
      );
      final noV6 = _report(
        devices: const [
          DeviceEndpoint(id: 'a', address: '192.0.2.10'),
          DeviceEndpoint(id: 'b', address: '192.0.2.20'),
        ],
      );
      expect(_result(noV6, family: IpFamily.ipv6).outcome, Outcome.unsupported);
    },
  );

  test('success after the local monotonic deadline cannot pass', () {
    final result = _result(
      _report(
        events: [
          _event('late_ack', ObservationKind.acknowledged, elapsed: 6000001),
        ],
      ),
    );
    expect(result.outcome, Outcome.inconclusive);
  });

  test('permission, cancellation and suspension remain distinct', () {
    expect(
      _result(
        _report(events: [_event('denied', ObservationKind.permissionDenied)]),
      ).outcome,
      Outcome.permissionDenied,
    );
    expect(
      _result(_report(events: [_event('cancel', ObservationKind.cancelled)]))
          .outcome,
      Outcome.cancelled,
    );
    final interrupted = _result(
      _report(events: [_event('network', ObservationKind.networkChanged)]),
    );
    expect(interrupted.outcome, Outcome.inconclusive);
    expect(interrupted.reason, 'run_interrupted');
    expect(
      _result(_report(events: [_event('suspend', ObservationKind.suspended)]))
          .reason,
      'run_interrupted',
    );
  });

  test('success survives later cancellation and preserves its evidence', () {
    final result = _result(
      _report(
        events: [
          _event('ok', ObservationKind.acknowledged),
          _event('cancel', ObservationKind.cancelled),
        ],
      ),
    );
    expect(result.outcome, Outcome.passed);
    expect(result.evidenceIds, ['ok']);
  });

  test('Bonjour resolution does not imply raw multicast success', () {
    final report = _report(
      reporter: 'b',
      events: [
        _event(
          'resolved',
          ObservationKind.resolved,
          check: CheckKind.dnsSd,
          reporter: 'b',
          family: IpFamily.system,
        ),
      ],
    );
    expect(
      _result(report, check: CheckKind.dnsSd, family: IpFamily.system).outcome,
      Outcome.passed,
    );
    expect(
      _result(report, check: CheckKind.multicast).outcome,
      isNot(Outcome.passed),
    );
  });

  test(
    'publication and discovery alone do not establish service resolution',
    () {
      final report = _report(
        events: [
          _event(
            'publish',
            ObservationKind.published,
            check: CheckKind.dnsSd,
            family: IpFamily.system,
          ),
          _event(
            'discover',
            ObservationKind.discovered,
            check: CheckKind.dnsSd,
            family: IpFamily.system,
          ),
        ],
      );
      expect(
        _result(
          report,
          check: CheckKind.dnsSd,
          family: IpFamily.system,
        ).outcome,
        Outcome.inconclusive,
      );
    },
  );

  test(
    'report round trip has stable machine identifiers and no session secrets',
    () {
      final report = _report(
        events: [_event('sent', ObservationKind.sent, sequence: 0)],
      );
      final text = ReportCodec.encode(report);
      final restored = ReportCodec.decode(text);
      expect(restored.toJson(), report.toJson());
      expect(text, isNot(contains('privateKey')));
      expect(text, isNot(contains('secret')));
      expect(restored.observations.single.kind, ObservationKind.sent);
    },
  );

  test('merge uses identities rather than wall-clock synchronization', () {
    final a = _report(events: [_event('a1', ObservationKind.sent)]);
    final b = _report(
      reporter: 'b',
      events: [_event('b1', ObservationKind.received, reporter: 'b')],
      time: DateTime.utc(2001),
    );
    final merged = ReportCodec.merge(a, b);
    expect(merged.sourceDeviceIds, ['a', 'b']);
    expect(
      merged.sourceRuns.map((s) => s.startedAt.year),
      containsAll([2001, 2026]),
    );
    expect(_result(merged).outcome, Outcome.passed);
    expect(ReportCodec.decode(ReportCodec.encode(merged)).sourceRuns.length, 2);
  });

  test(
    'merging duplicate imports is idempotent and conflicting duplicates fail',
    () {
      final a = _report(events: [_event('same', ObservationKind.sent)]);
      expect(ReportCodec.merge(a, a).observations.length, 1);
      final conflict = _report(events: [_event('same', ObservationKind.error)]);
      expect(() => ReportCodec.merge(a, conflict), throwsFormatException);
      final json = a.toJson();
      json['observations'] = [
        a.observations.single.toJson(),
        a.observations.single.toJson(),
      ];
      expect(RunReport.fromJson(json).observations.length, 1);
      (json['observations'] as List).add(conflict.observations.single.toJson());
      expect(() => RunReport.fromJson(json), throwsFormatException);
    },
  );

  test(
    'incomplete report remains usable and endpoint corrections can merge',
    () {
      final a = _report(
        devices: [
          _devices[0],
          const DeviceEndpoint(id: 'b', address: ''),
        ],
      );
      final b = _report(
        reporter: 'b',
        events: [_event('receipt', ObservationKind.received, reporter: 'b')],
      );
      final merged = ReportCodec.merge(a, b);
      expect(merged.devices[1].address, '192.0.2.20');
      expect(ReportCodec.decode(ReportCodec.encode(a)).observations, isEmpty);
      expect(_result(merged).outcome, Outcome.passed);
    },
  );

  test(
    'different run, participants, parameters and redaction state cannot merge',
    () {
      final base = _report();
      expect(
        () => ReportCodec.merge(base, _report(run: 'another_run')),
        throwsFormatException,
      );
      expect(
        () => ReportCodec.merge(
          base,
          _report(devices: [_devices[1], _devices[0]]),
        ),
        throwsFormatException,
      );
      expect(
        () => ReportCodec.merge(
          base,
          _report(plan: const RunPlan(durationMs: 8000)),
        ),
        throwsFormatException,
      );
      expect(
        () => ReportCodec.merge(base, ReportCodec.redact(base)),
        throwsFormatException,
      );
    },
  );

  test(
    'reports reject incompatible versions, corrupted files and credentials',
    () {
      final json = _report().toJson();
      json['protocolVersion'] = 2;
      expect(() => RunReport.fromJson(json), throwsFormatException);
      json['protocolVersion'] = 1;
      json['reportVersion'] = 2;
      expect(() => RunReport.fromJson(json), throwsFormatException);
      json['reportVersion'] = 1;
      json['secret'] = 'not_a_report_field';
      expect(() => RunReport.fromJson(json), throwsFormatException);
      expect(() => ReportCodec.decode('{invalid json'), throwsFormatException);
      expect(
        () => ReportCodec.decode(' ' * (maxImportBytes + 1)),
        throwsFormatException,
      );
    },
  );

  test(
    'foreign reporter, source and event participants cannot enter a report',
    () {
      final json = _report(events: [_event('one', ObservationKind.sent)])
          .toJson();
      (json['observations'] as List).first['reporterId'] = 'other';
      expect(() => RunReport.fromJson(json), throwsFormatException);
      (json['observations'] as List).first['reporterId'] = 'a';
      (json['observations'] as List).first['toDeviceId'] = 'other';
      expect(() => RunReport.fromJson(json), throwsFormatException);
      json['observations'] = [];
      json['sourceDeviceIds'] = ['a', 'other'];
      expect(() => RunReport.fromJson(json), throwsFormatException);
    },
  );

  test(
    'capability names cannot smuggle addresses or another participant identity',
    () {
      for (final key in [
        '192.0.2.10.permission',
        'other.permission',
        'a.192.0.2.10',
        'permission',
      ]) {
        final report = _report(capabilities: {key: 'granted'});
        expect(
          () => RunReport.fromJson(report.toJson()),
          throwsFormatException,
        );
      }
      expect(
        RunReport.fromJson(
          _report(capabilities: {'a.rawMulticast': 'available'}).toJson(),
        ).capabilities,
        {'a.rawMulticast': 'available'},
      );
    },
  );

  test(
    'redaction retains directions and monotonic evidence with stable aliases',
    () {
      final merged = ReportCodec.merge(
        _report(
          events: [_event('sent', ObservationKind.sent)],
          capabilities: {'a.permission': 'granted', 'a.custom': '192.0.2.10'},
        ),
        _report(
          reporter: 'b',
          events: [_event('received', ObservationKind.received, reporter: 'b')],
        ),
      );
      final redacted = ReportCodec.redact(merged);
      final text = ReportCodec.encode(redacted);
      for (final sensitive in [
        '192.0.2.10',
        '192.0.2.20',
        'fe80::',
        'en0',
        'wlan0',
        '2026-10-29',
      ]) {
        expect(text, isNot(contains(sensitive)));
      }
      expect(redacted.devices[0].address, 'device-a-ipv4');
      expect(redacted.devices[1].address, 'device-b-ipv4');
      expect(redacted.observations[1].interfaceName, 'interface-b');
      expect(redacted.observations[1].elapsedMicros, 1000);
      expect(_result(redacted).outcome, Outcome.passed);
      expect(ReportCodec.decode(text).redacted, isTrue);
      expect(
        jsonEncode(ReportCodec.redact(redacted).toJson()),
        jsonEncode(redacted.toJson()),
      );
    },
  );
}
