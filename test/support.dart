import 'dart:async';
import 'dart:io';

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

/// Platform whose discovery events are emitted by the test.
class ScriptedPlatform extends LocalPlatform {
  ScriptedPlatform(this.script);

  /// Called after the engine subscribed; emit events through the sink.
  final void Function(void Function(Map<String, dynamic>) emit) script;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<void> startDiscovery({
    required String sessionId,
    required String deviceId,
    required int port,
    required int interfaceIndex,
  }) async {
    scheduleMicrotask(() => script(_events.add));
  }
}

/// Waits until [condition] holds, failing instead of hanging.
Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
