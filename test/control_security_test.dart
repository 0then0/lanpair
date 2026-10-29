import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/control.dart';
import 'package:lanpair/src/identity.dart';
import 'package:lanpair/src/model.dart';

Future<Session> _session() async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = listener.port;
  await listener.close();
  final identities = await Future.wait([createIdentity(), createIdentity()]);
  return Session.create(
    a: DeviceEndpoint(id: 'a', address: '127.0.0.1', controlPort: port),
    b: const DeviceEndpoint(id: 'b', address: '127.0.0.1'),
    aIdentity: identities[0],
    bIdentity: identities[1],
  );
}

void main() {
  late Session host, peer;
  late ControlLink server, client;
  var accepted = 0;

  setUp(() async {
    host = await _session();
    peer = Session.fromInvitation(host.invitation());
    accepted = 0;
    server = ControlLink(
      session: host,
      onHello: (_) async => accepted++,
      onStart: () async {},
      onReport: (_) async {},
    );
    client = ControlLink(
      session: peer,
      onHello: (_) async {},
      onStart: () async {},
      onReport: (_) async {},
    );
    await server.open();
  });
  tearDown(() => server.close());

  Future<void> hello() async {
    final response = await client.post(
      '/hello',
      fields: {'endpoint': peer.local.toJson()},
    );
    expect(DeviceEndpoint.fromJson(jsonDecode(response)).id, host.local.id);
  }

  test(
    'unauthorized requests do not consume the accepted session budget',
    () async {
      await hello();
      final unauthenticated = HttpClient(
        context: SecurityContext(withTrustedRoots: false),
      );
      unauthenticated.badCertificateCallback = (certificate, _, _) =>
          sha256.convert(certificate.der).toString() ==
          host.localIdentity.fingerprint;
      addTearDown(() => unauthenticated.close(force: true));

      for (var i = 0; i < 64; i++) {
        final request = await unauthenticated.postUrl(
          Uri.parse('https://127.0.0.1:${host.local.controlPort}/hello'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.forbidden);
        await response.drain<void>();
      }

      expect(accepted, 1);
      await hello();
      expect(accepted, 2);
    },
  );

  test('authenticated requests remain limited to the session budget', () async {
    for (var i = 0; i < 64; i++) {
      await hello();
    }
    expect(accepted, 64);
    await expectLater(hello(), throwsA(isA<HttpException>()));
    expect(accepted, 64);
  });
}
