import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/control.dart';
import 'package:lanpair/src/controller.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/platform_bridge.dart';
import 'package:lanpair/src/report.dart';
import 'package:lanpair/src/storage.dart';
import 'package:lanpair/src/ui_contract.dart';

import 'support.dart';

class _Platform extends PlatformBridge {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<Map<String, dynamic>> capabilities({bool request = false}) async => {
    'platform': 'test',
    'permission': 'notRequired',
    'rawMulticast': false,
    'discovery': false,
  };
  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> acquireMulticast() async {}
  @override
  Future<void> releaseMulticast() async {}
}

// Synthetic interfaces. No real adapter names or addresses are needed: the
// control channel and probes use real loopback sockets, and the interfaces
// differ in name, index and address family so every change is visible.
const _wifiName = 'wifi0';
const _tunnelName = 'tun0';
final _wifi = LocalInterface(
  name: _wifiName,
  index: 1,
  addresses: [InternetAddress.loopbackIPv4],
);
final _tunnel = LocalInterface(
  name: _tunnelName,
  index: 2,
  addresses: [InternetAddress.loopbackIPv6],
);

Future<bool> _ipv6Available() async {
  try {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
    await server.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// True when nothing listens on [port] of the loopback addresses.
Future<bool> _portFree(int port) async {
  for (final address in [
    InternetAddress.loopbackIPv4,
    if (await _ipv6Available()) InternetAddress.loopbackIPv6,
  ]) {
    try {
      final server = await ServerSocket.bind(address, port);
      await server.close();
    } on SocketException {
      return false;
    }
  }
  return true;
}

class _Device {
  _Device._(this.interfaces, this.port, this.directory);
  List<LocalInterface> interfaces;
  final int port;
  final Directory directory;
  late final AppController controller;
  var _disposed = false;

  static Future<_Device> start(List<LocalInterface> interfaces) async {
    final device = _Device._(
      List.of(interfaces),
      await freePort(),
      await Directory.systemTemp.createTemp('lanpair-sync-'),
    );
    device.controller = AppController(
      platform: _Platform(),
      store: ReportStore(device.directory),
      interfaceLister: () async => List.of(device.interfaces),
      controlPort: device.port,
    );
    await device.controller.initialize();
    return device;
  }

  Session get session => controller.debugSession!;
  DeviceEndpoint get peer => session.peer;
  bool get confirmed => controller.peerSync == 'confirmed';

  void dispose() {
    if (!_disposed) controller.dispose();
    _disposed = true;
  }

  Future<void> stop() async {
    dispose();
    await controller.settled;
    await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  final devices = <_Device>[];
  Future<_Device> device(List<LocalInterface> interfaces) async {
    final created = await _Device.start(interfaces);
    devices.add(created);
    return created;
  }

  tearDown(() async {
    for (final d in devices) {
      await d.stop();
    }
    devices.clear();
  });

  Future<(_Device, _Device)> joined({
    List<LocalInterface>? a,
    List<LocalInterface>? b,
    String? bChoice,
  }) async {
    final first = await device(a ?? [_wifi, _tunnel]);
    final second = await device(b ?? [_tunnel, _wifi]);
    await first.controller.createSession();
    if (bChoice != null) await second.controller.selectInterface(bChoice);
    await second.controller.joinSession(first.controller.invitation!);
    await eventually(() => first.confirmed && second.confirmed);
    return (first, second);
  }

  /// Tests that move an endpoint between address families need ::1.
  void ipv6Test(String name, Future<void> Function() body) =>
      test(name, () async {
        if (!await _ipv6Available()) {
          markTestSkipped('IPv6 loopback unavailable');
          return;
        }
        await body();
      });

  group('endpoint updates after an interface choice', () {
    ipv6Test(
      'B joins on the tunnel, then selects Wi-Fi: A receives it',
      () async {
        final (a, b) = await joined(bChoice: _tunnelName);
        expect(a.peer.interfaceName, _tunnelName);
        expect(a.peer.address, '::1');
        expect(a.peer.interfaceIndex, 2);

        await b.controller.selectInterface(_wifiName);
        await eventually(
          () => a.peer.interfaceName == _wifiName && a.confirmed && b.confirmed,
        );
        expect(a.peer.address, '127.0.0.1');
        expect(a.peer.ipv6Address, isNull);
        expect(a.peer.interfaceIndex, 1);
        expect(a.controller.debugPeerRevision, 2);
        expect(b.controller.debugLocalRevision, 2);
        expect(b.session.local.interfaceName, _wifiName);
        expect(
          b.peer.interfaceName,
          a.session.local.interfaceName,
          reason: 'B still holds A\'s unchanged endpoint',
        );
      },
    );

    ipv6Test('A changes interface after B joined: B receives it', () async {
      final (a, b) = await joined(a: [_wifi, _tunnel], b: [_wifi]);
      expect(b.peer.interfaceName, _wifiName);

      await a.controller.selectInterface(_tunnelName);
      await eventually(
        () => b.peer.interfaceName == _tunnelName && a.confirmed && b.confirmed,
      );
      expect(b.peer.address, '::1');
      expect(b.controller.debugPeerRevision, 2);
      // The invitation is generated from the current endpoint.
      expect(
        Session.fromInvitation(a.controller.invitation!).a.interfaceName,
        _tunnelName,
      );
    });

    test('a choice made before joining survives a refresh', () async {
      final a = await device([_wifi]);
      final b = await device([_tunnel, _wifi]);
      await a.controller.createSession();
      await b.controller.selectInterface(_wifiName);
      await b.controller.refreshReadiness();
      expect(b.controller.selectedInterface, _wifiName);
      await b.controller.joinSession(a.controller.invitation!);
      expect(b.controller.selectedInterface, _wifiName);
      expect(b.session.local.interfaceName, _wifiName);
      await eventually(() => a.confirmed && b.confirmed);
      expect(a.peer.interfaceName, _wifiName);
    });

    test('an unchosen tunnel is not picked by list order', () async {
      final b = await device([_tunnel, _wifi]);
      expect(b.controller.selectedInterface, _wifiName);
      final onlyTunnel = await device([_tunnel]);
      expect(onlyTunnel.controller.selectedInterface, _tunnelName);
    });

    test('an explicit choice is not replaced when it disappears', () async {
      final b = await device([_tunnel, _wifi]);
      await b.controller.selectInterface(_tunnelName);
      b.interfaces = [_wifi];
      await b.controller.refreshReadiness();
      expect(b.controller.selectedInterface, isNull);
      await b.controller.createSession();
      expect(b.controller.errorCode, 'interfaceUnavailable');
      expect(b.controller.hasSession, isFalse);
      b.interfaces = [_tunnel, _wifi];
      await b.controller.refreshReadiness();
      expect(b.controller.selectedInterface, _tunnelName);
    });
  });

  group('confirmation belongs to the current endpoints', () {
    ipv6Test('a confirmed old endpoint does not confirm the new one', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi, _tunnel]);
      expect(b.controller.peerSync, 'confirmed');

      // A stops answering (suspended), then B changes its endpoint.
      a.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await a.controller.settled;
      await b.controller.selectInterface(_tunnelName);
      await b.controller.settled;

      expect(b.controller.peerSync, 'unconfirmed');
      expect(b.controller.peerSyncReason, 'control_unreachable');
      expect(
        b.controller.readiness.firstWhere((r) => r.code == 'peerEndpoint'),
        isA<ReadinessView>()
            .having((r) => r.status, 'status', 'inconclusive')
            .having((r) => r.detail, 'detail', 'control_unreachable'),
      );
      expect(a.peer.interfaceName, _wifiName, reason: 'A never heard of it');
    });

    ipv6Test('refresh repeats the exchange and recovers', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi, _tunnel]);
      a.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await a.controller.settled;
      await b.controller.selectInterface(_tunnelName);
      expect(b.controller.peerSync, 'unconfirmed');

      a.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await a.controller.settled;
      await b.controller.refreshReadiness();
      await eventually(() => a.confirmed && b.confirmed);
      expect(a.peer.interfaceName, _tunnelName);
    });

    test('a manually entered peer is never confirmed', () async {
      final (a, _) = await joined(a: [_wifi], b: [_wifi]);
      await a.controller.setManualPeer('192.0.2.7', 45831);
      expect(a.controller.peerSync, 'unconfirmed');
      expect(a.controller.peerSyncReason, 'manual_peer');
    });

    test('a start under other revisions is declined', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi]);
      final client = ControlLink(
        session: b.session,
        onHello: (_) async {},
        onStart: () async {},
        onReport: (_) async {},
      );
      for (final stamp in [
        {'revision': 1, 'peerRevision': 9},
        {'revision': 9, 'peerRevision': 1},
      ]) {
        await expectLater(
          client.post('/start', fields: stamp),
          throwsA(
            isA<ControlRejected>().having((e) => e.statusCode, 'status', 409),
          ),
        );
      }
      expect(a.controller.running, isFalse);
    });
  });

  group('superseded state', () {
    test('a late message of an earlier session changes nothing', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi]);
      final oldPeer = b.session; // B as of the first session
      final oldLink = a.controller.debugControl!;

      await a.controller.createSession();
      final current = a.session;
      expect(current.peer.address, isEmpty);

      final late = ControlLink(
        session: oldPeer,
        onHello: (_) async {},
        onStart: () async {},
        onReport: (_) async {},
      );
      final stale = oldPeer.local.copyWith(interfaceName: 'stale0');
      for (final path in ['/endpoint', '/hello']) {
        await expectLater(
          late.post(
            path,
            fields: {
              'endpoint': stale.toJson(),
              'revision': 7,
              'generation': 1,
              'peerRevision': 1,
            },
          ),
          // The new session has other certificates, so even the pin fails.
          throwsA(anyOf(isA<HttpException>(), isA<HandshakeException>())),
        );
      }
      // Even a callback of the closed listener cannot reach the new session.
      expect(
        () => oldLink.onEndpoint!(
          EndpointUpdate(
            endpoint: stale,
            stamp: const EndpointStamp(revision: 7, peerRevision: 1),
            generation: 1,
          ),
        ),
        throwsStateError,
      );
      await expectLater(oldLink.onHello(stale), throwsStateError);
      expect(a.session.peer.address, isEmpty);
      expect(a.controller.debugPeerRevision, 0);
      expect(a.session.sessionId, current.sessionId);
    });

    test('an older revision never replaces a newer one', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi]);
      final link = ControlLink(
        session: b.session,
        onHello: (_) async {},
        onStart: () async {},
        onReport: (_) async {},
      );
      var generation = b.controller.debugGeneration;
      Future<EndpointReply> send(int revision, String name) async =>
          EndpointReply.fromJson(
            boundedJsonDecode(
              await link.post(
                '/endpoint',
                fields: {
                  'endpoint': b.session.local
                      .copyWith(interfaceName: name)
                      .toJson(),
                  'revision': revision,
                  'generation': generation,
                  'peerRevision': 1,
                },
              ),
            ),
          );

      expect((await send(5, 'five0')).applied, isTrue);
      expect(a.peer.interfaceName, 'five0');
      final stale = await send(3, 'three0');
      expect(stale.applied, isFalse);
      expect(stale.reason, 'stale_revision');
      final conflict = await send(5, 'other0');
      expect(conflict.applied, isFalse);
      expect(conflict.reason, 'revision_conflict');
      expect((await send(5, 'five0')).applied, isTrue, reason: 'idempotent');
      expect(a.peer.interfaceName, 'five0');
      expect(a.controller.debugPeerRevision, 5);

      // A late message of an earlier join is refused whatever its revision;
      // a later join starts numbering again and is accepted.
      generation -= 1;
      final late = await send(9, 'late0');
      expect(late.applied, isFalse);
      expect(late.reason, 'stale_revision');
      generation += 2;
      expect((await send(1, 'rejoined0')).applied, isTrue);
      expect(a.peer.interfaceName, 'rejoined0');
      expect(a.controller.debugPeerRevision, 1);
    });
  });

  group('failures are visible', () {
    ipv6Test('a busy control port is reported and not confirmed', () async {
      final (a, b) = await joined(a: [_wifi], b: [_tunnel, _wifi]);
      await b.controller.selectInterface(_tunnelName);
      await eventually(() => a.confirmed && b.confirmed);

      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        b.port,
      );
      await b.controller.selectInterface(_wifiName);
      expect(b.controller.errorCode, 'controlUnavailable');
      expect(b.session.local.interfaceName, _wifiName);
      expect(b.controller.peerSync, 'unconfirmed');
      expect(b.controller.peerSyncReason, 'control_unavailable');

      await blocker.close();
      await b.controller.refreshReadiness();
      await eventually(() => a.confirmed && b.confirmed);
      expect(b.controller.errorCode, isNull);
    });

    test('a vanished interface closes the listener and says why', () async {
      final (_, b) = await joined(a: [_wifi], b: [_wifi]);
      b.interfaces = [];
      await b.controller.refreshReadiness();
      expect(b.controller.peerSync, 'unconfirmed');
      expect(b.controller.peerSyncReason, 'interface_unavailable');
      expect(b.controller.errorCode, 'interfaceUnavailable');
      expect(await _portFree(b.port), isTrue);
    });

    ipv6Test('an exchange with an unreachable peer is bounded', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi, _tunnel]);
      a.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await a.controller.settled;
      final before = b.controller.debugPushes;
      await b.controller.selectInterface(_tunnelName);
      await b.controller.settled;
      expect(b.controller.debugPushes - before, lessThanOrEqualTo(2));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(b.controller.debugPushes - before, lessThanOrEqualTo(2));
    });

    ipv6Test('simultaneous changes end without a handshake loop', () async {
      final (a, b) = await joined(a: [_wifi, _tunnel], b: [_wifi, _tunnel]);
      final before = a.controller.debugPushes + b.controller.debugPushes;

      await Future.wait([
        a.controller.selectInterface(_tunnelName),
        b.controller.selectInterface(_tunnelName),
      ]);
      await a.controller.settled;
      await b.controller.settled;
      final settled = a.controller.debugPushes + b.controller.debugPushes;
      // Two changes, at most two attempts each plus one answer per change.
      expect(settled - before, lessThanOrEqualTo(8));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(a.controller.debugPushes + b.controller.debugPushes, settled);

      // Each side holds a peer endpoint nobody could update: the state says
      // so instead of claiming readiness...
      for (final d in [a, b]) {
        expect(d.controller.peerSync, isNot('confirmed'));
        expect(d.controller.peerSync, isNot('pending'));
      }
      // ...and importing the current invitation again repairs it.
      await b.controller.joinSession(a.controller.invitation!);
      await eventually(() => a.confirmed && b.confirmed);
      expect(a.peer.interfaceName, _tunnelName);
      expect(b.peer.interfaceName, _tunnelName);
    });
  });

  group('0.1.1 peers', () {
    test('a peer without /endpoint is used but never confirmed', () async {
      final legacySession = await pair();
      final legacy = ControlLink(
        session: legacySession,
        onHello: (_) async {},
        onStart: () async {},
        onReport: (_) async {},
      );
      await legacy.open();
      addTearDown(legacy.close);

      final b = await device([_wifi]);
      await b.controller.joinSession(legacySession.invitation());
      expect(b.peer.address, legacySession.a.address);
      expect(b.controller.peerSync, 'unconfirmed');
      expect(b.controller.peerSyncReason, 'peer_legacy');
      expect(b.controller.debugPeerRevision, 0);
    });

    test('a 0.1.1 hello is accepted and not counted as confirmation', () async {
      final a = await device([_wifi]);
      await a.controller.createSession();
      final invitation = Session.fromInvitation(a.controller.invitation!);
      final client = ControlLink(
        session: invitation.withEndpoint(
          DeviceRole.a,
          invitation.a.copyWith(controlPort: a.port),
        ),
        onHello: (_) async {},
        onStart: () async {},
        onReport: (_) async {},
      );
      await client.post(
        '/hello',
        fields: {'endpoint': invitation.local.toJson()},
      );
      expect(a.controller.peerSync, 'unconfirmed');
      expect(a.controller.peerSyncReason, 'peer_legacy');
    });
  });

  group('runs', () {
    ipv6Test(
      'an independent run stays available and says it is unconfirmed',
      () async {
        final (a, b) = await joined(a: [_wifi], b: [_wifi, _tunnel]);
        a.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await a.controller.settled;
        await b.controller.selectInterface(_tunnelName);
        expect(b.controller.peerSync, 'unconfirmed');

        await b.controller.startRun();
        final report = b.controller.debugReport!;
        final id = b.session.local.id;
        expect(report.capabilities['$id.peerReadiness'], 'unconfirmed');
        // The journal records the endpoints and revisions the probes used.
        expect(report.capabilities['$id.endpointRevision'], '2');
        expect(report.capabilities['$id.peerEndpointRevision'], '1');
        expect(
          report.devices.firstWhere((d) => d.id == id).interfaceName,
          _tunnelName,
        );
        expect(
          report.devices.firstWhere((d) => d.id != id).interfaceName,
          _wifiName,
          reason: 'the peer endpoint the probes actually used',
        );
      },
    );

    test('a coordinated run needs both sides current', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi]);
      await b.controller.startRun();
      await eventually(() => a.controller.debugReport != null);
      final bId = b.session.local.id;
      expect(
        b.controller.debugReport!.capabilities['$bId.peerReadiness'],
        'confirmed',
      );
      final aId = a.session.local.id;
      expect(
        a.controller.debugReport!.capabilities['$aId.peerReadiness'],
        'confirmed',
      );
    });
  });

  group('listeners', () {
    test('cancelling, lifecycle changes and new sessions leave none', () async {
      final a = await device([_wifi, _tunnel]);
      await a.controller.createSession();
      await a.controller.selectInterface(_tunnelName);
      a.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      a.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await a.controller.selectInterface(_wifiName);
      await a.controller.createSession();
      await a.controller.cancelRun();
      await a.controller.settled;
      expect(a.controller.errorCode, anyOf(isNull, 'controlUnavailable'));

      a.dispose();
      await a.controller.settled;
      expect(await _portFree(a.port), isTrue);
    });

    test(
      'a new session before the old handshake ended does not leak',
      () async {
        final a = await device([_wifi]);
        final b = await device([_wifi]);
        await a.controller.createSession();
        final joining = b.controller.joinSession(a.controller.invitation!);
        final creating = a.controller.createSession();
        await Future.wait([joining, creating]);
        await a.controller.settled;
        await b.controller.settled;
        expect(a.controller.debugControl!.isOpen, isTrue);
        expect(a.session.peer.address, isEmpty);
        await b.stop();
        devices.remove(b);
        a.dispose();
        await a.controller.settled;
        expect(await _portFree(a.port), isTrue);
      },
    );
  });

  group('network changes', () {
    LocalInterface wifiAt(int index) => LocalInterface(
      name: _wifiName,
      index: index,
      addresses: _wifi.addresses,
    );

    test('a changed interface is re-sent without any user action', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi]);
      b.interfaces = [wifiAt(5)];
      await b.controller.debugCheckNetwork();
      await eventually(() => a.peer.interfaceIndex == 5 && a.confirmed);
      expect(b.confirmed, isTrue);
      expect(b.controller.debugLocalRevision, 2);
      expect(b.controller.errorCode, isNull);
    });

    test('a listener that had to reopen exchanges even if unchanged', () async {
      final (a, b) = await joined(a: [_wifi], b: [_wifi]);
      b.interfaces = [];
      await b.controller.debugCheckNetwork();
      expect(b.controller.peerSyncReason, 'interface_unavailable');
      expect(await _portFree(b.port), isTrue);

      // A changes while B is away: B's listener is not there to hear it.
      a.interfaces = [wifiAt(7)];
      await a.controller.debugCheckNetwork();
      await a.controller.settled;
      expect(b.peer.interfaceIndex, 1);

      b.interfaces = [_wifi];
      await b.controller.debugCheckNetwork();
      await eventually(() => b.peer.interfaceIndex == 7 && b.confirmed);
      expect(b.session.local.interfaceIndex, 1, reason: 'B did not change');
      await eventually(() => a.confirmed);
    });

    test(
      'a finished run keeps its journal and asks for a new session',
      () async {
        final (_, b) = await joined(a: [_wifi], b: [_wifi]);
        await b.controller.startRun();
        final journal = b.controller.debugReport!;
        b.interfaces = [wifiAt(5)];
        await b.controller.debugCheckNetwork();
        expect(b.controller.errorCode, 'networkChanged');
        expect(b.controller.debugReport, same(journal));
        expect(
          b.session.local.interfaceIndex,
          1,
          reason: 'endpoint not rewritten',
        );
      },
    );
  });

  group('control request budget', () {
    test(
      'endpoint exchanges do not use up the budget of other requests',
      () async {
        final (a, b) = await joined(a: [_wifi], b: [_wifi]);
        final link = ControlLink(
          session: b.session,
          onHello: (_) async {},
          onStart: () async {},
          onReport: (_) async {},
        );
        for (var i = 0; i < 70; i++) {
          await link.post(
            '/endpoint',
            fields: {
              'endpoint': b.session.local.toJson(),
              'generation': b.controller.debugGeneration,
              'revision': 1,
              'peerRevision': 1,
            },
          );
        }
        // A request of another kind is still served (rejected by the stamp,
        // not by the budget: 409, not 403).
        await expectLater(
          link.post('/start', fields: {'revision': 9, 'peerRevision': 9}),
          throwsA(isA<ControlRejected>().having((e) => e.statusCode, 's', 409)),
        );
        expect(a.confirmed, isTrue);
      },
    );
  });

  group('journals', () {
    RunReport journal(
      String reporter, {
      required String ownInterface,
      required String heldInterface,
      Map<String, String> capabilities = const {},
      bool redacted = false,
    }) {
      DeviceEndpoint endpoint(String id, String name) =>
          DeviceEndpoint(id: id, address: '192.0.2.1', interfaceName: name);
      final other = reporter == 'a' ? 'b' : 'a';
      final devices = {
        reporter: endpoint(reporter, ownInterface),
        other: endpoint(other, heldInterface),
      };
      final report = RunReport(
        sessionId: 'session',
        runId: 'run',
        reportingDeviceId: reporter,
        devices: [devices['a']!, devices['b']!],
        parameters: const RunPlan(),
        capabilities: capabilities,
        startedAt: DateTime.utc(2026),
        durationMicros: 1000,
        observations: const [],
      );
      return redacted ? ReportCodec.redact(report) : report;
    }

    test('differing endpoints are kept visible when journals merge', () {
      final a = journal('a', ownInterface: 'en0', heldInterface: 'ipsec0');
      final b = journal('b', ownInterface: 'wlan0', heldInterface: 'en0');
      final merged = ReportCodec.merge(a, b);
      expect(merged.capabilities['a.peerEndpoint'], 'differs');
      expect(merged.capabilities['b.peerEndpoint'], 'matches');
      expect(
        ReportCodec.merge(b, a).capabilities,
        merged.capabilities,
        reason: 'the order of the journals does not matter',
      );
      // The participant's own statement wins, never the other's view.
      expect(
        merged.devices.firstWhere((d) => d.id == 'b').interfaceName,
        'wlan0',
      );
      expect(
        ReportCodec.decode(ReportCodec.encode(merged)).capabilities,
        merged.capabilities,
      );
    });

    test('matching endpoints are recorded as matching', () {
      final merged = ReportCodec.merge(
        journal('a', ownInterface: 'en0', heldInterface: 'wlan0'),
        journal('b', ownInterface: 'wlan0', heldInterface: 'en0'),
      );
      expect(merged.capabilities['a.peerEndpoint'], 'matches');
      expect(merged.capabilities['b.peerEndpoint'], 'matches');
    });

    test('revisions decide when journals carry them, even redacted', () {
      final a = journal(
        'a',
        ownInterface: 'x',
        heldInterface: 'x',
        capabilities: {
          'a.endpointRevision': '1',
          'a.peerEndpointRevision': '1',
        },
        redacted: true,
      );
      final b = journal(
        'b',
        ownInterface: 'x',
        heldInterface: 'x',
        capabilities: {
          'b.endpointRevision': '2',
          'b.peerEndpointRevision': '1',
        },
        redacted: true,
      );
      expect(a.capabilities['a.endpointRevision'], '1');
      final merged = ReportCodec.merge(a, b);
      expect(merged.capabilities['a.peerEndpoint'], 'differs');
      expect(merged.capabilities['b.peerEndpoint'], 'matches');
    });

    test('redacted journals without revisions make no claim', () {
      final merged = ReportCodec.merge(
        journal('a', ownInterface: 'x', heldInterface: 'y', redacted: true),
        journal('b', ownInterface: 'z', heldInterface: 'x', redacted: true),
      );
      expect(
        merged.capabilities.keys.any((k) => k.endsWith('.peerEndpoint')),
        isFalse,
      );
    });
  });

  group('journals with a typed-in peer address', () {
    RunReport manual(String peerAddress, {int port = 45831}) => RunReport(
      sessionId: 'session',
      runId: 'run',
      reportingDeviceId: 'a',
      devices: [
        const DeviceEndpoint(
          id: 'a',
          address: '192.0.2.1',
          interfaceName: 'en0',
          interfaceIndex: 6,
        ),
        DeviceEndpoint(id: 'b', address: peerAddress, tcpPort: port),
      ],
      parameters: const RunPlan(),
      capabilities: {'a.endpointRevision': '1', 'a.peerEndpointRevision': '0'},
      startedAt: DateTime.utc(2026),
      durationMicros: 1000,
      observations: const [],
    );
    final other = RunReport(
      sessionId: 'session',
      runId: 'run',
      reportingDeviceId: 'b',
      devices: const [
        DeviceEndpoint(
          id: 'a',
          address: '192.0.2.1',
          interfaceName: 'en0',
          interfaceIndex: 6,
        ),
        DeviceEndpoint(
          id: 'b',
          address: '192.0.2.2',
          interfaceName: 'wlan0',
          interfaceIndex: 9,
        ),
      ],
      parameters: const RunPlan(),
      capabilities: {'b.endpointRevision': '1', 'b.peerEndpointRevision': '1'},
      startedAt: DateTime.utc(2026),
      durationMicros: 1000,
      observations: const [],
    );

    test('a correct typed-in address is not reported as a difference', () {
      final merged = ReportCodec.merge(manual('192.0.2.2'), other);
      expect(merged.capabilities['a.peerEndpoint'], 'matches');
      expect(merged.capabilities['b.peerEndpoint'], 'matches');
    });

    test('a wrong typed-in address or port is', () {
      expect(
        ReportCodec.merge(
          manual('192.0.2.99'),
          other,
        ).capabilities['a.peerEndpoint'],
        'differs',
      );
      expect(
        ReportCodec.merge(
          manual('192.0.2.2', port: 45899),
          other,
        ).capabilities['a.peerEndpoint'],
        'differs',
      );
    });
  });
}
