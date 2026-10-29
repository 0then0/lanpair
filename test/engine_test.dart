import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/control.dart';
import 'package:lanpair/src/engine.dart';
import 'package:lanpair/src/identity.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/platform_bridge.dart';
import 'package:lanpair/src/report.dart';

class LocalPlatform extends PlatformBridge {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> acquireMulticast() async {}
  @override
  Future<void> releaseMulticast() async {}
}

const caps = <String, dynamic>{
  'permission': 'notRequired',
  'rawMulticast': false,
  'discovery': false,
};
Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<Session> pair() async {
  final ports = <int>{};
  while (ports.length < 6) {
    ports.add(await freePort());
  }
  final p = ports.toList();
  final identities = await Future.wait([createIdentity(), createIdentity()]);
  return Session.create(
    a: DeviceEndpoint(
      id: randomId(),
      address: '127.0.0.1',
      tcpPort: p[0],
      udpPort: p[1],
      controlPort: p[2],
    ),
    b: DeviceEndpoint(
      id: randomId(),
      address: '127.0.0.1',
      tcpPort: p[3],
      udpPort: p[4],
      controlPort: p[5],
    ),
    aIdentity: identities[0],
    bIdentity: identities[1],
    plan: const RunPlan(durationMs: 1200, intervalMs: 100),
  );
}

ProbeEngine engine(
  Session session, {
  bool loseAck = false,
  Map<String, dynamic> capabilities = caps,
}) => ProbeEngine(
  session: session,
  platform: LocalPlatform(),
  capabilities: capabilities,
  dropAcknowledgements: loseAck,
);
CheckResult result(RunReport report, CheckKind kind, String from) =>
    interpret(report).firstWhere(
      (r) =>
          r.check == kind &&
          r.family == IpFamily.ipv4 &&
          r.fromDeviceId == from,
    );

void main() {
  test('authenticated packet rejects corruption, foreign run, own multicast and bounds', () async {
    final a = await pair();
    final b = Session.fromInvitation(a.invitation());
    final packet = ProbePacket(
      sessionId: a.sessionId,
      runId: a.runId,
      from: a.local.id,
      to: a.peer.id,
      check: CheckKind.multicast,
      family: IpFamily.ipv4,
      sequence: 1,
    );
    final bytes = packet.encode(a.secret);
    expect(ProbePacket.decode(bytes, b)?.sequence, 1);
    expect(ProbePacket.decode(bytes, a), isNull);
    expect(ProbePacket.decode(bytes, b.withRunId(randomId())), isNull);
    expect(ProbePacket.decode([...bytes, 0], b), isNull);
    expect(ProbePacket.decode(List.filled(maxPacketBytes + 1, 0), b), isNull);
    expect(
      ProbePacket.decode(
        ProbePacket(
          sessionId: a.sessionId,
          runId: a.runId,
          from: a.local.id,
          to: a.peer.id,
          check: CheckKind.udp,
          family: IpFamily.ipv4,
          sequence: 3,
        ).encode(a.secret),
        b,
      ),
      isNull,
    );
  });
  test('real loopback TCP and UDP independently pass in both directions; IPv6 absence unsupported', () async {
    final a = await pair();
    final b = Session.fromInvitation(a.invitation());
    final reports = await Future.wait([engine(a).run(), engine(b).run()]);
    final merged = ReportCodec.merge(reports[0], reports[1]);
    for (final id in [a.a.id, a.b.id]) {
      expect(result(merged, CheckKind.tcp, id).outcome, Outcome.passed);
      expect(result(merged, CheckKind.udp, id).outcome, Outcome.passed);
    }
    expect(
      interpret(merged)
          .where((r) => r.family == IpFamily.ipv6)
          .every((r) => r.outcome == Outcome.unsupported),
      isTrue,
    );
    expect(
      ReportCodec.decode(ReportCodec.encode(merged)).sourceDeviceIds,
      hasLength(2),
    );
    expect(
      merged.observations
          .where(
            (o) => o.kind == ObservationKind.sent && o.check == CheckKind.udp,
          )
          .length,
      6,
    );
  });
  test('probe sending waits until peer listeners are ready', () async {
    final a = await pair();
    final b = Session.fromInvitation(a.invitation());
    final first = engine(a);
    Future<RunReport>? second;
    final reportA = await first.run(
      onReady: () async {
        expect(
          first.observations.where((o) => o.kind == ObservationKind.sent),
          isEmpty,
        );
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(
          first.observations.where((o) => o.kind == ObservationKind.sent),
          isEmpty,
        );
        second = engine(b).run();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      },
    );
    final merged = ReportCodec.merge(reportA, await second!);
    expect(result(merged, CheckKind.udp, a.a.id).outcome, Outcome.passed);
    expect(result(merged, CheckKind.udp, a.b.id).outcome, Outcome.passed);
  });

  test(
    'receiver journal establishes delivery when acknowledgements are lost',
    () async {
      final a = await pair();
      final b = Session.fromInvitation(a.invitation());
      final reports = await Future.wait([
        engine(a).run(),
        engine(b, loseAck: true).run(),
      ]);
      expect(
        result(reports[0], CheckKind.udp, a.a.id).outcome,
        Outcome.inconclusive,
      );
      final merged = ReportCodec.merge(reports[0], reports[1]);
      expect(result(merged, CheckKind.udp, a.a.id).outcome, Outcome.passed);
      expect(result(merged, CheckKind.udp, a.a.id).reason, 'peer_received');
    },
  );
  test(
    'one unavailable TCP destination preserves asymmetric evidence',
    () async {
      final a = await pair();
      final b = Session.fromInvitation(a.invitation())
          .withEndpoint(DeviceRole.a, a.a.copyWith(tcpPort: await freePort()));
      final reports = await Future.wait([engine(a).run(), engine(b).run()]);
      final merged = ReportCodec.merge(reports[0], reports[1]);
      expect(result(merged, CheckKind.tcp, a.a.id).outcome, Outcome.passed);
      expect(result(merged, CheckKind.tcp, a.b.id).outcome, Outcome.failed);
    },
  );
  test(
    'cancellation and network interruption roundtrip and release bound sockets',
    () async {
      final a = await pair();
      final e = engine(a);
      final running = e.run();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      e.cancel(reason: ObservationKind.networkChanged);
      final report = await running;
      expect(
        ReportCodec.decode(ReportCodec.encode(report)).observations
            .any((o) => o.kind == ObservationKind.networkChanged),
        isTrue,
      );
      expect(
        result(report, CheckKind.tcp, a.a.id).outcome,
        Outcome.inconclusive,
      );
      final tcp = await ServerSocket.bind('127.0.0.1', a.a.tcpPort);
      await tcp.close();
      final udp = await RawDatagramSocket.bind('127.0.0.1', a.a.udpPort);
      udp.close();
      expect(() => e.run(), throwsStateError);
    },
  );
  test('disconnected independent windows preserve exportable, mergeable journals', () async {
    final a = await pair();
    final b = Session.fromInvitation(a.invitation());
    // The peer never has a live listener during either local window. No control
    // channel is created, so this also cannot depend on clock synchronization.
    final localA = await engine(a).run();
    final localB = await engine(b).run();
    final exportedA = ReportCodec.decode(ReportCodec.encode(localA));
    final exportedB = ReportCodec.decode(ReportCodec.encode(localB));
    final merged = ReportCodec.merge(exportedA, exportedB);
    expect(merged.sourceDeviceIds, hasLength(2));
    for (final id in [a.a.id, a.b.id]) {
      expect(result(merged, CheckKind.tcp, id).outcome, Outcome.failed);
      expect(result(merged, CheckKind.udp, id).outcome, Outcome.inconclusive);
    }
    expect(
      ReportCodec.merge(merged, exportedB).observations.length,
      merged.observations.length,
    );
  });

  test('permission denial opens no probe listeners and is explicit', () async {
    final a = await pair();
    final report = await engine(
      a,
      capabilities: {...caps, 'permission': 'denied'},
    ).run();
    expect(
      result(report, CheckKind.tcp, a.a.id).outcome,
      Outcome.permissionDenied,
    );
    expect(
      report.observations.any((o) => o.kind == ObservationKind.sent),
      isFalse,
    );
    final tcp = await ServerSocket.bind('127.0.0.1', a.a.tcpPort);
    await tcp.close();
  });
  test(
    'pinned HTTPS hello succeeds; wrong pin and unauthenticated bearer fail',
    () async {
      final a = await pair();
      final b = Session.fromInvitation(a.invitation());
      var accepted = 0;
      final server = ControlLink(
        session: a,
        onHello: (_) async {
          accepted++;
        },
        onStart: () async {},
        onReport: (_) async {},
      );
      final client = ControlLink(
        session: b,
        onHello: (_) async {},
        onStart: () async {},
        onReport: (_) async {},
      );
      await server.open();
      addTearDown(server.close);
      final response = await client.post(
        '/hello',
        fields: {'endpoint': b.local.toJson()},
      );
      expect(DeviceEndpoint.fromJson(jsonDecode(response)).id, a.a.id);
      expect(accepted, 1);
      // A different session has a different pin and cannot trust this listener.
      final foreign = await pair();
      final foreignClient = ControlLink(
        session: Session.fromInvitation(
          foreign
              .withEndpoint(
                DeviceRole.a,
                foreign.a.copyWith(
                  address: '127.0.0.1',
                  controlPort: a.a.controlPort,
                ),
              )
              .invitation(),
        ),
        onHello: (_) async {},
        onStart: () async {},
        onReport: (_) async {},
      );
      await expectLater(
        foreignClient.post('/hello', fields: {'endpoint': foreign.b.toJson()}),
        throwsA(isA<HandshakeException>()),
      );
      final unauth = HttpClient(
        context: SecurityContext(withTrustedRoots: false),
      );
      unauth.badCertificateCallback = (cert, host, port) =>
          true; // Test adversary only.
      final req = await unauth.postUrl(
        Uri.parse('https://127.0.0.1:${a.a.controlPort}/hello'),
      );
      req.write('{}');
      expect((await req.close()).statusCode, HttpStatus.forbidden);
      unauth.close(force: true);
      expect(accepted, 1);
      expect(
        utf8.encode(a.invitation()).length,
        lessThan(2800),
        reason: 'ECC invitation must fit the QR pathway.',
      );
    },
  );
}
