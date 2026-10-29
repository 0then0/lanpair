import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/engine.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/report.dart';

import 'support.dart';

List<Observation> seen(
  RunReport report,
  CheckKind check,
  String from, {
  ObservationKind? kind,
  String? code,
}) => report.observations
    .where(
      (o) =>
          o.check == check &&
          o.family == IpFamily.ipv4 &&
          o.fromDeviceId == from &&
          (kind == null || o.kind == kind) &&
          (code == null || o.code == code),
    )
    .toList();

void main() {
  group('attempt schedule', () {
    const plan = RunPlan(durationMs: 6000, intervalMs: 250);

    test('a ready peer is probed at once; the interval stays small', () {
      expect(
        attemptOffsets(plan, peerReady: true).map((d) => d.inMilliseconds),
        [0, 250, 500],
      );
      expect(
        attemptOffsets(
          plan,
          peerReady: true,
          leadIn: true,
        ).map((d) => d.inMilliseconds),
        [250, 500, 750],
      );
    });

    test('an unknown peer is probed across the window within the budget', () {
      final offsets = attemptOffsets(plan, peerReady: false);
      expect(offsets, hasLength(plan.packetCount));
      expect(offsets.first, Duration.zero);
      // Room remains after the last attempt for it to finish in the window.
      expect(offsets.last.inMilliseconds, lessThanOrEqualTo(5000));
      expect(offsets.last.inMilliseconds, greaterThan(plan.durationMs ~/ 2));
      for (var i = 1; i < offsets.length; i++) {
        expect(
          (offsets[i] - offsets[i - 1]).inMilliseconds,
          greaterThanOrEqualTo(plan.intervalMs),
        );
      }
    });

    test('a listener open for one spacing is met by an attempt', () {
      for (final p in const [
        RunPlan(),
        RunPlan(durationMs: 1000, intervalMs: 100),
        RunPlan(durationMs: 15000, intervalMs: 1000, packetCount: 2),
      ]) {
        final offsets = attemptOffsets(p, peerReady: false);
        final spacing = offsets.length > 1
            ? (offsets[1] - offsets[0]).inMilliseconds
            : 0;
        final last = offsets.last.inMilliseconds;
        for (var open = 0; open <= last - spacing; open += 7) {
          expect(
            offsets.any(
              (o) =>
                  o.inMilliseconds >= open &&
                  o.inMilliseconds <= open + spacing,
            ),
            isTrue,
            reason: 'listener opening at $open ms, plan ${p.toJson()}',
          );
        }
      }
    });

    test('a single attempt goes to the middle of the usable window', () {
      final offsets = attemptOffsets(
        const RunPlan(packetCount: 1),
        peerReady: false,
      );
      expect(offsets.single.inMilliseconds, inInclusiveRange(2000, 3500));
    });

    test('connect failures get stable platform independent codes', () {
      SocketException error(int? errno, [String message = 'x']) =>
          SocketException(
            message,
            osError: errno == null ? null : OSError('', errno),
          );
      for (final errno in [111, 61, 10061]) {
        expect(connectErrorCode(error(errno)), 'connection_refused');
      }
      for (final errno in [110, 60, 10060]) {
        expect(connectErrorCode(error(errno)), 'connect_timeout');
      }
      expect(connectErrorCode(error(65)), 'host_unreachable');
      expect(connectErrorCode(error(51)), 'network_unreachable');
      expect(
        connectErrorCode(error(null, 'Connection timed out')),
        'connect_timeout',
      );
      expect(connectErrorCode(TimeoutException('t')), 'connect_timeout');
      expect(connectErrorCode(error(98)), 'socket_error_98');
    });
  });

  group('independent starts', () {
    test('a second device started later still gets both directions', () async {
      final a = await pair();
      final b = Session.fromInvitation(a.invitation());
      final first = engine(a).run();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final second = engine(b).run();
      final merged = ReportCodec.merge(await first, await second);
      for (final id in [a.a.id, a.b.id]) {
        expect(result(merged, CheckKind.tcp, id).outcome, Outcome.passed);
        expect(result(merged, CheckKind.udp, id).outcome, Outcome.passed);
      }
      // The early attempts were refused; the sequence is kept, not collapsed.
      final early = result(merged, CheckKind.tcp, a.a.id);
      expect(early.reason, 'peer_confirmed_after_retry');
      expect(
        seen(
          merged,
          CheckKind.tcp,
          a.a.id,
          kind: ObservationKind.error,
          code: 'connection_refused',
        ),
        isNotEmpty,
      );
      expect(
        merged.capabilities['${a.a.id}.peerReadiness'],
        'unconfirmed',
        reason: 'no control channel confirmed readiness',
      );
    });

    test('a start after the early attempts ended proves nothing', () async {
      final a = await pair();
      final b = Session.fromInvitation(a.invitation());
      final first = engine(a);
      final firstReport = first.run();
      // Start B only after all of A's attempts were refused. The windows still
      // overlap, but A will not try again.
      await eventually(
        () =>
            first.observations
                .where((o) => o.code == 'connection_refused')
                .length >=
            a.plan.packetCount,
      );
      final secondReport = engine(b).run();
      final merged = ReportCodec.merge(await firstReport, await secondReport);

      final late = result(merged, CheckKind.tcp, a.a.id);
      expect(late.outcome, isNot(Outcome.failed));
      expect(late.outcome, isNot(Outcome.passed));
      expect(late.reason, 'peer_not_listening');
      expect(
        result(merged, CheckKind.udp, a.a.id).outcome,
        Outcome.inconclusive,
      );
      // The device that started second is not penalised for the first one.
      expect(result(merged, CheckKind.tcp, a.b.id).outcome, Outcome.passed);
    });

    test('every refused attempt keeps its own cause and sequence', () async {
      final a = await pair();
      final report = await engine(a).run();
      final refused = seen(
        report,
        CheckKind.tcp,
        a.a.id,
        kind: ObservationKind.error,
        code: 'connection_refused',
      );
      expect(refused.map((o) => o.sequence), [0, 1, 2]);
      // The window summary is still written after the attempts.
      expect(
        seen(report, CheckKind.tcp, a.a.id, kind: ObservationKind.timedOut),
        hasLength(1),
      );
      final single = result(report, CheckKind.tcp, a.a.id);
      expect(single.outcome, Outcome.inconclusive);
      expect(single.reason, 'peer_not_listening');
      expect(single.evidenceIds, containsAll(refused.map((o) => o.id)));
    });

    test(
      'attempts are spread without a control channel, close with one',
      () async {
        Future<int> gap({required bool ready}) async {
          final a = await pair();
          final report = await ProbeEngine(
            session: a,
            platform: LocalPlatform(),
            capabilities: caps,
          ).run(onReady: ready ? () async => true : null);
          final sent = seen(
            report,
            CheckKind.udp,
            a.a.id,
            kind: ObservationKind.sent,
          ).toList()..sort((x, y) => x.sequence!.compareTo(y.sequence!));
          expect(sent, hasLength(3));
          expect(
            report.capabilities['${a.a.id}.peerReadiness'],
            ready ? 'confirmed' : 'unconfirmed',
          );
          return (sent[1].elapsedMicros - sent[0].elapsedMicros) ~/ 1000;
        }

        final results = await Future.wait([
          gap(ready: true),
          gap(ready: false),
        ]);
        expect(results[0], lessThan(250));
        expect(results[1], greaterThan(350));
      },
    );

    test('a confirmed ready peer that refuses is reported as failed', () async {
      final a = await pair();
      final report = await ProbeEngine(
        session: a,
        platform: LocalPlatform(),
        capabilities: caps,
      ).run(onReady: () async => true);
      final refused = result(report, CheckKind.tcp, a.a.id);
      expect(refused.outcome, Outcome.failed);
      expect(refused.reason, 'connection_refused');
    });

    test(
      'a failing readiness callback degrades to an independent start',
      () async {
        final a = await pair();
        final report = await ProbeEngine(
          session: a,
          platform: LocalPlatform(),
          capabilities: caps,
        ).run(onReady: () async => throw StateError('control channel down'));
        expect(report.capabilities['${a.a.id}.peerReadiness'], 'unconfirmed');
        expect(
          result(report, CheckKind.tcp, a.a.id).outcome,
          Outcome.inconclusive,
        );
      },
    );

    test('cancelling does not wait for the next scheduled attempt', () async {
      final a = await pair();
      final e = engine(a);
      final running = e.run();
      await eventually(() => e.observations.isNotEmpty);
      final cancelled = Stopwatch()..start();
      e.cancel();
      final report = await running;
      expect(cancelled.elapsedMilliseconds, lessThan(350));
      expect(
        report.observations.any((o) => o.kind == ObservationKind.cancelled),
        isTrue,
      );
      final tcp = await ServerSocket.bind('127.0.0.1', a.a.tcpPort);
      await tcp.close();
      final udp = await RawDatagramSocket.bind('127.0.0.1', a.a.udpPort);
      udp.close();
    });
  });

  group('TCP participant proof', () {
    Future<(ServerSocket, Session)> stranger(
      Future<void> Function(Socket socket, Session session) behave,
    ) async {
      final a = await pair();
      final listener = await ServerSocket.bind('127.0.0.1', a.b.tcpPort);
      listener.listen((socket) {
        unawaited(
          behave(
            socket,
            a,
          ).catchError((Object _) {}).whenComplete(socket.destroy),
        );
      });
      addTearDown(listener.close);
      return (listener, a);
    }

    test('a listener that accepts and stays silent is not the peer', () async {
      final (_, a) = await stranger((socket, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      });
      final report = await engine(a).run();
      final tcp = result(report, CheckKind.tcp, a.a.id);
      expect(tcp.outcome, Outcome.inconclusive);
      expect(tcp.reason, 'tcp_connected_peer_unconfirmed');
      expect(
        seen(report, CheckKind.tcp, a.a.id, kind: ObservationKind.connected),
        isNotEmpty,
        reason: 'the transport connection stays recorded',
      );
      expect(
        seen(report, CheckKind.tcp, a.a.id, code: 'tcp_reply_missing'),
        isNotEmpty,
      );
      expect(
        seen(report, CheckKind.tcp, a.a.id, kind: ObservationKind.acknowledged),
        isEmpty,
      );
    });

    test('garbage, a forged mac and an echo are rejected', () async {
      for (final reply in <List<int> Function(Session, List<int>)>[
        (session, probe) => utf8.encode('HTTP/1.1 400 Bad Request\n'),
        (session, probe) => [...probe, 10],
        (session, probe) => utf8.encode(
          '${jsonEncode({'p': jsonDecode(utf8.decode(probe))['p'], 'h': '0' * 64})}\n',
        ),
      ]) {
        final (listener, a) = await stranger((socket, session) async {
          final line = <int>[];
          await for (final chunk in socket) {
            line.addAll(chunk);
            if (line.contains(10)) break;
          }
          socket.add(reply(session, line.sublist(0, line.length - 1)));
          await socket.flush();
        });
        final report = await engine(a).run();
        await listener.close();
        final tcp = result(report, CheckKind.tcp, a.a.id);
        expect(tcp.outcome, Outcome.inconclusive);
        expect(tcp.reason, 'tcp_connected_peer_unconfirmed');
        expect(
          seen(report, CheckKind.tcp, a.a.id, code: 'tcp_reply_invalid'),
          isNotEmpty,
        );
      }
    });

    test('a reply must match the probe sequence, check and family', () async {
      for (final mismatch in <ProbePacket Function(Session, int)>[
        (s, seq) => ProbePacket(
          sessionId: s.sessionId,
          runId: s.runId,
          from: s.local.id,
          to: s.peer.id,
          check: CheckKind.tcp,
          family: IpFamily.ipv4,
          sequence: (seq + 1) % 3,
          ack: true,
        ),
        (s, seq) => ProbePacket(
          sessionId: s.sessionId,
          runId: s.runId,
          from: s.local.id,
          to: s.peer.id,
          check: CheckKind.udp,
          family: IpFamily.ipv4,
          sequence: seq,
          ack: true,
        ),
        (s, seq) => ProbePacket(
          sessionId: s.sessionId,
          runId: s.runId,
          from: s.local.id,
          to: s.peer.id,
          check: CheckKind.tcp,
          family: IpFamily.ipv6,
          sequence: seq,
          ack: true,
        ),
      ]) {
        final a = await pair();
        // The stranger holds the session secret (as the peer does) but answers
        // with a reply that belongs to another probe.
        final peerView = Session.fromInvitation(a.invitation());
        final listener = await ServerSocket.bind('127.0.0.1', a.b.tcpPort);
        addTearDown(listener.close);
        listener.listen((socket) async {
          final line = <int>[];
          await for (final chunk in socket) {
            line.addAll(chunk);
            if (line.contains(10)) break;
          }
          final probe = ProbePacket.decode(
            line.sublist(0, line.length - 1),
            peerView,
          )!;
          socket.add([
            ...mismatch(peerView, probe.sequence).encode(a.secret),
            10,
          ]);
          await socket.flush();
          socket.destroy();
        });
        final report = await engine(a).run();
        final tcp = result(report, CheckKind.tcp, a.a.id);
        expect(tcp.outcome, Outcome.inconclusive, reason: '$mismatch');
        expect(tcp.reason, 'tcp_connected_peer_unconfirmed');
      }
    });

    test(
      'with a peer reported ready, a stranger on the port is a failure',
      () async {
        final (_, a) = await stranger((socket, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        });
        final report = await ProbeEngine(
          session: a,
          platform: LocalPlatform(),
          capabilities: caps,
        ).run(onReady: () async => true);
        final tcp = result(report, CheckKind.tcp, a.a.id);
        expect(tcp.outcome, Outcome.failed);
        expect(tcp.reason, 'peer_not_confirmed');
      },
    );

    test(
      'the peer journal establishes arrival when the reply is lost',
      () async {
        final a = await pair();
        final b = Session.fromInvitation(a.invitation());
        final reports = await Future.wait([
          engine(a).run(),
          engine(b, loseAck: true).run(),
        ]);
        // A reached B, but B's reply never arrived.
        expect(
          seen(
            reports[0],
            CheckKind.tcp,
            a.a.id,
            kind: ObservationKind.connected,
          ),
          isNotEmpty,
        );
        final alone = result(reports[0], CheckKind.tcp, a.a.id);
        expect(alone.outcome, Outcome.inconclusive);
        expect(alone.reason, 'tcp_connected_peer_unconfirmed');
        final merged = ReportCodec.merge(reports[0], reports[1]);
        final joined = result(merged, CheckKind.tcp, a.a.id);
        expect(joined.outcome, Outcome.passed);
        expect(
          joined.reason,
          anyOf('peer_confirmed', 'peer_confirmed_after_retry'),
        );
      },
    );

    test('connecting to this device is never attempted or counted', () async {
      final a = await pair();
      final self = a.withEndpoint(
        DeviceRole.b,
        a.b.copyWith(
          address: a.a.address,
          tcpPort: a.a.tcpPort,
          udpPort: a.a.udpPort,
        ),
      );
      final report = await engine(self).run();
      final tcp = result(report, CheckKind.tcp, a.a.id);
      expect(tcp.outcome, Outcome.inconclusive);
      expect(tcp.reason, 'peer_address_is_local');
      expect(
        seen(report, CheckKind.tcp, a.a.id, kind: ObservationKind.connected),
        isEmpty,
      );
      final udp = result(report, CheckKind.udp, a.a.id);
      expect(udp.reason, 'peer_address_is_local');
      expect(
        report.observations.where((o) => o.kind == ObservationKind.sent),
        isEmpty,
      );
    });

    test('the same address with different ports is another device', () async {
      // Loopback tests rely on this: both participants use 127.0.0.1.
      final a = await pair();
      expect(a.a.address, a.b.address);
      final b = Session.fromInvitation(a.invitation());
      final reports = await Future.wait([engine(a).run(), engine(b).run()]);
      final merged = ReportCodec.merge(reports[0], reports[1]);
      expect(result(merged, CheckKind.tcp, a.a.id).outcome, Outcome.passed);
    });
  });

  group('discovery errors', () {
    Future<List<CheckResult>> run(
      void Function(Session session, void Function(Map<String, dynamic>) emit)
      script,
    ) async {
      final a = await pair();
      final report = await ProbeEngine(
        session: a,
        platform: ScriptedPlatform((emit) => script(a, emit)),
        capabilities: {...caps, 'discovery': true},
      ).run();
      return interpret(report)
          .where((r) => r.check == CheckKind.dnsSd)
          .toList();
    }

    CheckResult direction(
      List<CheckResult> all,
      Session s, {
      required bool outgoing,
    }) => all.singleWhere(
      (r) => outgoing ? r.fromDeviceId == s.a.id : r.fromDeviceId == s.b.id,
    );

    test('a publish failure belongs to this device as the source', () async {
      late Session session;
      final all = await run((s, emit) {
        session = s;
        emit({'type': 'error', 'code': 'dns_sd_publish', 'nativeCode': -1});
      });
      final out = direction(all, session, outgoing: true);
      expect(out.outcome, Outcome.failed);
      expect(out.reason, 'discovery_publish_failed');
      expect(
        direction(all, session, outgoing: false).outcome,
        Outcome.inconclusive,
      );
    });

    test(
      'a browse failure belongs to the peer to this device direction',
      () async {
        late Session session;
        final all = await run((s, emit) {
          session = s;
          emit({'type': 'error', 'code': 'dns_sd_browse'});
        });
        final incoming = direction(all, session, outgoing: false);
        expect(incoming.outcome, Outcome.failed);
        expect(incoming.reason, 'discovery_browse_failed');
        expect(
          direction(all, session, outgoing: true).outcome,
          Outcome.inconclusive,
        );
      },
    );

    test('a resolve failure is attributed only to the peer service', () async {
      late Session session;
      final all = await run((s, emit) {
        session = s;
        final prefix = 'LP-${s.sessionId.substring(0, 16)}-';
        emit({
          'type': 'error',
          'code': 'dns_sd_resolve',
          'name': '$prefix${s.peer.id.substring(0, 16)}',
        });
      });
      final incoming = direction(all, session, outgoing: false);
      expect(incoming.outcome, Outcome.failed);
      expect(incoming.reason, 'discovery_resolve_failed');
      expect(
        direction(all, session, outgoing: true).outcome,
        Outcome.inconclusive,
      );
    });

    test(
      'a resolve failure of an unknown service names no direction',
      () async {
        for (final name in <String?>[
          null,
          'LP-0000000000000000-ffffffffffffffff',
          'unrelated',
        ]) {
          final all = await run((s, emit) {
            emit({'type': 'error', 'code': 'dns_sd_resolve', 'name': ?name});
            emit({'type': 'error', 'code': 'something_else'});
          });
          expect(all.map((r) => r.outcome), everyElement(Outcome.inconclusive));
        }
      },
    );

    test('resolution that succeeds after an earlier error wins', () async {
      late Session session;
      final all = await run((s, emit) {
        session = s;
        emit({'type': 'error', 'code': 'dns_sd_browse'});
        emit({
          'type': 'resolved',
          'sessionId': s.sessionId,
          'deviceId': s.peer.id,
        });
      });
      expect(direction(all, session, outgoing: false).outcome, Outcome.passed);
    });

    test(
      'a denied permission affects both directions of this device',
      () async {
        final all = await run((s, emit) {
          emit({'type': 'error', 'code': 'permission_denied'});
        });
        expect(
          all.map((r) => r.outcome),
          everyElement(Outcome.permissionDenied),
        );
      },
    );
  });
}
