import 'dart:convert';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import 'model.dart';

/// Certificate/key generation uses Pointy Castle through basic_utils. TLS is
/// implemented by the platform-backed Dart runtime, never by this application.
Future<TlsIdentity> createIdentity() => Isolate.run(() {
  final pair = CryptoUtils.generateEcKeyPair();
  final privateKey = pair.privateKey as ECPrivateKey;
  final publicKey = pair.publicKey as ECPublicKey;
  final csr = X509Utils.generateEccCsrPem(
    {'CN': 'LANPair ephemeral session'},
    privateKey,
    publicKey,
  );
  final certificate = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csr,
    7305,
    notBefore: DateTime.utc(2020),
  );
  return TlsIdentity(
    certificatePem: certificate,
    privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
    fingerprint: certificateFingerprint(certificate),
  );
});

String certificateFingerprint(String pem) => sha256
    .convert(base64Decode(pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), '')))
    .toString();

bool constantTimeEqual(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var difference = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    difference |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return difference == 0;
}
