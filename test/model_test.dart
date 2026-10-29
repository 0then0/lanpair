import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/model.dart';

const _pem = '-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n';
const _keyA = '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n';
const _keyB = '-----BEGIN PRIVATE KEY-----\nBBBB\n-----END PRIVATE KEY-----\n';

Session _session() => Session.create(
  a: const DeviceEndpoint(
    id: 'a',
    address: '192.0.2.10',
    ipv6Address: 'fe80::1%en0',
    interfaceName: 'en0',
    interfaceIndex: 4,
  ),
  b: const DeviceEndpoint(id: 'b', address: ''),
  aIdentity: TlsIdentity(
    certificatePem: _pem,
    privateKeyPem: _keyA,
    fingerprint: List.filled(64, 'a').join(),
  ),
  bIdentity: TlsIdentity(
    certificatePem: _pem,
    privateKeyPem: _keyB,
    fingerprint: List.filled(64, 'b').join(),
  ),
);

void main() {
  test(
    'invitation transfers only joining private key and stable offline plan',
    () {
      final host = _session();
      final invitation = host.invitation();
      expect(invitation, isNot(contains('AAAA')));
      expect(invitation, contains('BBBB'));
      final peer = Session.fromInvitation(invitation);
      expect(peer.localRole, DeviceRole.b);
      expect(peer.local.id, host.peer.id);
      expect(peer.secret, host.secret);
      expect(peer.sessionId, host.sessionId);
      expect(peer.runId, host.runId);
      expect(peer.plan.sameAs(host.plan), isTrue);
      expect(peer.localIdentity.privateKeyPem, _keyB);
      expect(peer.peerFingerprint, host.localIdentity.fingerprint);
      expect(peer.peer.ipv6Address, 'fe80::1%en0');
    },
  );

  test(
    'fresh session credentials have independent unpredictable identifiers',
    () {
      final a = _session();
      final b = _session();
      expect(a.sessionId, isNot(b.sessionId));
      expect(a.runId, isNot(b.runId));
      expect(a.secret, isNot(b.secret));
      expect(a.secret.length, 64);
      expect(a.secret, isNot(a.sessionId));
    },
  );

  test(
    'endpoint correction preserves run identity and rejects participant swap',
    () {
      final host = _session();
      final changed = host.withEndpoint(
        DeviceRole.b,
        host.b.copyWith(address: '192.0.2.20'),
      );
      expect(changed.runId, host.runId);
      expect(changed.secret, host.secret);
      expect(changed.b.address, '192.0.2.20');
      expect(
        () => host.withEndpoint(DeviceRole.b, host.a),
        throwsArgumentError,
      );
    },
  );

  test('local session restores role, scoped interface and credentials', () {
    final host = _session();
    final restored = Session.fromLocalJson(
      jsonDecode(jsonEncode(host.toLocalJson())),
    );
    expect(restored.invitation(), host.invitation());
    expect(restored.a.interfaceIndex, 4);
    expect(restored.a.ipv6Address, 'fe80::1%en0');
    final joined = Session.fromInvitation(host.invitation());
    final restoredPeer = Session.fromLocalJson(joined.toLocalJson());
    expect(restoredPeer.localRole, DeviceRole.b);
    expect(restoredPeer.localIdentity.privateKeyPem, _keyB);
  });

  test('joining credential can be discarded after pairing', () {
    final session = _session().withoutJoinCredential();
    expect(() => session.invitation(), throwsStateError);
    expect(session.localIdentity.privateKeyPem, _keyA);
    expect(jsonEncode(session.toLocalJson()), isNot(contains('BBBB')));
  });

  test('invitation rejects incompatible versions and oversize content', () {
    final invitation = _session().invitation();
    expect(
      () => Session.fromInvitation(invitation.replaceFirst('lp1:', 'lp2:')),
      throwsFormatException,
    );
    expect(
      () => Session.fromInvitation(
        invitation.replaceFirst('"protocolVersion":1', '"protocolVersion":2'),
      ),
      throwsFormatException,
    );
    expect(
      () => Session.fromInvitation('lp1:${' ' * 24577}'),
      throwsFormatException,
    );
  });

  test('invitation rejects unknown fields, malformed credential and duplicate participant', () {
    final data = jsonDecode(
      _session().invitation().substring(4),
    ) as Map<String, dynamic>;
    data['unexpected'] = true;
    expect(
      () => Session.fromInvitation('lp1:${jsonEncode(data)}'),
      throwsFormatException,
    );
    data.remove('unexpected');
    data['secret'] = 'guessable';
    expect(
      () => Session.fromInvitation('lp1:${jsonEncode(data)}'),
      throwsFormatException,
    );
    data['secret'] = '0' * 64;
    (data['b'] as Map<String, dynamic>)['id'] = 'a';
    expect(
      () => Session.fromInvitation('lp1:${jsonEncode(data)}'),
      throwsFormatException,
    );
  });

  test(
    'run plan bounds time and exchange budget with strict numeric types',
    () {
      for (final invalid in [
        {'durationMs': 16000, 'packetCount': 3, 'intervalMs': 250},
        {'durationMs': 6000, 'packetCount': 4, 'intervalMs': 250},
        {'durationMs': 6000, 'packetCount': 3.0, 'intervalMs': 250},
        {'durationMs': 1000, 'packetCount': 3, 'intervalMs': 500},
        {'durationMs': 6000, 'packetCount': 3, 'intervalMs': 0},
      ]) {
        expect(() => RunPlan.fromJson(invalid), throwsFormatException);
      }
    },
  );

  test(
    'bounded JSON handles malformed, non-UTF8-budget and deeply nested content',
    () {
      expect(() => boundedJsonDecode('{'), throwsFormatException);
      expect(
        () => boundedJsonDecode('"${'あ' * 10}"', maxBytes: 20),
        throwsFormatException,
      );
      expect(
        () => boundedJsonDecode('${'[' * 10000}${']' * 10000}'),
        anyOf(returnsNormally, throwsFormatException),
      );
    },
  );

  test('endpoint import retains IPv6 scope and rejects ports and control characters', () {
    final endpoint = _session().a.toJson();
    expect(DeviceEndpoint.fromJson(endpoint).ipv6Address, 'fe80::1%en0');
    endpoint['tcpPort'] = 0;
    expect(() => DeviceEndpoint.fromJson(endpoint), throwsFormatException);
    endpoint['tcpPort'] = 45831;
    endpoint['address'] = '192.0.2.1\n';
    expect(() => DeviceEndpoint.fromJson(endpoint), throwsFormatException);
  });
}
