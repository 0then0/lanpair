import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/control.dart';
import 'package:lanpair/src/controller.dart';
import 'package:lanpair/src/engine.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/platform_bridge.dart';
import 'package:lanpair/src/storage.dart';

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
}

Future<List<NetworkInterface>> _loopback() async =>
    (await NetworkInterface.list(
      includeLoopback: true,
      includeLinkLocal: true,
    )).where((i) => i.addresses.any((a) => a.isLoopback)).toList();

/// Succeeds only when nothing listens on [port] of the loopback address.
Future<bool> _portFree(int port) async {
  try {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await server.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// Performs an authenticated `/hello` as the joining device would.
Future<bool> _hello(String invitation, int port) async {
  final joined = Session.fromInvitation(invitation);
  final client = ControlLink(
    session: joined.withEndpoint(
      DeviceRole.a,
      joined.a.copyWith(controlPort: port),
    ),
    onHello: (_) async {},
    onStart: () async {},
    onReport: (_) async {},
  );
  try {
    await client.post('/hello', fields: {'endpoint': joined.local.toJson()});
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding stubs HTTP; the control channel talks to real loopback.
  setUpAll(() => HttpOverrides.global = null);

  group('control link ownership', () {
    late Session session;
    setUp(() async => session = await pair());

    ControlLink link(Session s) => ControlLink(
      session: s,
      onHello: (_) async {},
      onStart: () async {},
      onReport: (_) async {},
    );

    test('opening twice binds once; closing releases the port', () async {
      final control = link(session);
      addTearDown(control.close);
      await Future.wait([control.open(), control.open()]);
      expect(control.serves(session), isTrue);
      expect(await _portFree(session.local.controlPort), isFalse);
      await control.close();
      await control.close();
      expect(control.isOpen, isFalse);
      expect(await _portFree(session.local.controlPort), isTrue);
      await expectLater(control.open(), throwsStateError);
    });

    test('a bind that finishes after close never stays listening', () async {
      final control = link(session);
      final opening = control.open();
      final closing = control.close();
      await Future.wait([opening, closing]);
      expect(control.isOpen, isFalse);
      expect(await _portFree(session.local.controlPort), isTrue);
      // The next link owns the port without conflict.
      final next = link(session);
      addTearDown(next.close);
      await next.open();
      expect(next.serves(session), isTrue);
    });

    test('a failed bind is reported and leaves nothing open', () async {
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        session.local.controlPort,
      );
      addTearDown(blocker.close);
      final control = link(session);
      await expectLater(control.open(), throwsA(isA<SocketException>()));
      expect(control.isOpen, isFalse);
      await control.close();
    });
  });

  group('application lifecycle', () {
    late Directory temporary;
    late AppController controller;
    late int port;
    var disposed = false;

    setUp(() async {
      disposed = false;
      temporary = await Directory.systemTemp.createTemp('lanpair-lifecycle-');
      port = await freePort();
      controller = AppController(
        platform: _Platform(),
        store: ReportStore(temporary),
        interfaceLister: _loopback,
        controlPort: port,
      );
      await controller.initialize();
    });
    tearDown(() async {
      if (!disposed) controller.dispose();
      await controller.settled;
      await temporary.delete(recursive: true);
    });

    test('inactive then resumed keeps one working listener', () async {
      await controller.createSession();
      expect(controller.errorCode, isNull);
      final invitation = controller.invitation!;
      expect(await _hello(invitation, port), isTrue);

      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await controller.settled;

      expect(controller.errorCode, isNull);
      expect(await _hello(invitation, port), isTrue);
    });

    test('overlapping suspensions and resumes end with exactly one', () async {
      await controller.createSession();
      final invitation = controller.invitation!;
      for (final state in [
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
        AppLifecycleState.hidden,
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
        AppLifecycleState.resumed,
      ]) {
        controller.didChangeAppLifecycleState(state);
      }
      await controller.settled;
      expect(controller.errorCode, isNull);
      expect(await _hello(invitation, port), isTrue);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await controller.settled;
      expect(
        await _portFree(port),
        isTrue,
        reason: 'a suspended app holds no listener',
      );
    });

    test(
      'a new session replaces the old listener and its credentials',
      () async {
        await controller.createSession();
        final first = controller.invitation!;
        controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await controller.settled;

        await controller.createSession();
        expect(controller.errorCode, isNull);
        final second = controller.invitation!;
        expect(second, isNot(first));
        expect(await _hello(second, port), isTrue);
        expect(
          await _hello(first, port),
          isFalse,
          reason: 'the previous session must not be served any more',
        );

        // A third session after another lifecycle round trip still works.
        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await controller.settled;
        await controller.createSession();
        expect(controller.errorCode, isNull);
        expect(await _hello(controller.invitation!, port), isTrue);
      },
    );

    test(
      'a failed open is not the current state after a later success',
      () async {
        final blocker = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await controller.createSession();
        expect(controller.errorCode, 'controlUnavailable');
        await blocker.close();

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await controller.settled;
        expect(controller.errorCode, isNull);
        expect(await _hello(controller.invitation!, port), isTrue);
      },
    );

    test('returning while a create is pending does not duplicate it', () async {
      final creating = controller.createSession();
      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await creating;
      await controller.settled;
      expect(controller.errorCode, isNull);
      expect(await _hello(controller.invitation!, port), isTrue);
    });

    test('disposing releases the listener', () async {
      await controller.createSession();
      controller.dispose();
      disposed = true;
      await controller.settled;
      expect(await _portFree(port), isTrue);
    });

    test('opening history closes the session listener', () async {
      await controller.createSession();
      await controller.openHistory('missing');
      expect(await _portFree(port), isTrue);
    });
  });

  group('start request', () {
    Future<Object?> start(bool declines) async {
      final a = await pair();
      final b = Session.fromInvitation(a.invitation());
      final server = ControlLink(
        session: a,
        onHello: (_) async {},
        onStart: () async {
          if (declines) throw const StartDeclined();
        },
        onReport: (_) async {},
      );
      await server.open();
      addTearDown(server.close);
      final client = ControlLink(
        session: b,
        onHello: (_) async {},
        onStart: () async {},
        onReport: (_) async {},
      );
      try {
        return await client.post('/start');
      } catch (e) {
        return e;
      }
    }

    test('a started peer answers 200', () async {
      expect(await start(false), '{}');
    });

    test('a peer that did not start answers an error, not readiness', () async {
      expect(await start(true), isA<HttpException>());
    });

    test('the engine treats a declined start as an independent run', () async {
      final a = await pair();
      final report = await ProbeEngine(
        session: a,
        platform: LocalPlatform(),
        capabilities: caps,
      ).run(onReady: () async => throw const HttpException('control_rejected'));
      expect(report.capabilities['${a.a.id}.peerReadiness'], 'unconfirmed');
    });
  });

  group('manual peer entry', () {
    late Directory temporary;
    late AppController controller;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('lanpair-manual-');
      controller = AppController(
        platform: _Platform(),
        store: ReportStore(temporary),
        interfaceLister: _loopback,
        controlPort: await freePort(),
      );
      await controller.initialize();
      await controller.createSession();
    });
    tearDown(() async {
      controller.dispose();
      await controller.settled;
      await temporary.delete(recursive: true);
    });

    test(
      'this device\'s own address and port is rejected with an explanation',
      () async {
        await controller.setManualPeer('127.0.0.1', 45831);
        expect(controller.errorCode, 'peerAddressIsLocal');
      },
    );

    test(
      'the same address on another port is a legitimate loopback peer',
      () async {
        await controller.setManualPeer('127.0.0.1', 45841);
        expect(controller.errorCode, isNull);
      },
    );

    test('another device is accepted and an invalid address is not', () async {
      await controller.setManualPeer('192.0.2.7', 45831);
      expect(controller.errorCode, isNull);
      await controller.setManualPeer('not an address', 45831);
      expect(controller.errorCode, 'invalidAddress');
    });
  });
}
