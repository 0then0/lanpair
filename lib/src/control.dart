import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'model.dart';

/// Authenticated, certificate-pinned HTTPS; discovery is never required.
/// Credentials exist only in invitations and Authorization headers.
class ControlLink {
  ControlLink({
    required this.session,
    required this.onHello,
    required this.onStart,
    required this.onReport,
  });
  Session session;
  final Future<void> Function(DeviceEndpoint endpoint) onHello;
  final Future<void> Function() onStart;
  final Future<void> Function(String report) onReport;
  HttpServer? _server;
  int _requests = 0;
  int _inflight = 0;

  Future<void> open() async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(
        utf8.encode(session.localIdentity.certificatePem),
      )
      ..usePrivateKeyBytes(utf8.encode(session.localIdentity.privateKeyPem));
    _server = await HttpServer.bindSecure(
      session.local.address,
      session.local.controlPort,
      context,
    );
    _server!.idleTimeout = const Duration(seconds: 2);
    _server!.listen((request) => unawaited(_handle(request)));
  }

  Future<void> _handle(HttpRequest request) async {
    _inflight++;
    try {
      if (_inflight > 4 ||
          request.method != 'POST' ||
          !constantTimeEqual(
            request.headers.value(HttpHeaders.authorizationHeader) ?? '',
            'Bearer ${session.secret}',
          ) ||
          ++_requests > 64) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      final content = await readBounded(
        request,
        limit: maxImportBytes,
        timeout: const Duration(seconds: 2),
      );
      final value = jsonObject(boundedJsonDecode(content), 'control message');
      if (value['sessionId'] != session.sessionId ||
          value['runId'] != session.runId ||
          value['protocolVersion'] != protocolVersion) {
        request.response.statusCode = HttpStatus.conflict;
        return;
      }
      switch (request.uri.path) {
        case '/hello':
          final endpoint = DeviceEndpoint.fromJson(value['endpoint']);
          if (endpoint.id != session.peer.id) {
            throw const FormatException('Wrong participant.');
          }
          await onHello(endpoint);
          request.response.write(jsonEncode(session.local.toJson()));
        case '/start':
          // Joining explicitly accepts this one bounded run. Duplicate starts
          // are rejected by the controller and never allocate a second run.
          await onStart().timeout(const Duration(seconds: 2));
          request.response.write('{}');
        case '/report':
          await onReport(jsonEncode(value['report']));
          request.response.write('{}');
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      _inflight--;
      try {
        await request.response.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        /* Peer closed. */
      }
    }
  }

  Future<String> post(
    String path, {
    Map<String, Object?> fields = const {},
  }) async {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 2)
      ..idleTimeout = const Duration(seconds: 2)
      ..maxConnectionsPerHost = 1;
    // This callback belongs only to this session's client. System TLS settings
    // and other clients are never modified. Empty trust roots require this pin.
    client.badCertificateCallback = (certificate, host, port) =>
        constantTimeEqual(
          sha256.convert(certificate.der).toString(),
          session.peerFingerprint,
        );
    try {
      var host = session.peer.address.split('%').first;
      if (host.toLowerCase().startsWith('fe80:')) {
        host = '$host%${session.local.interfaceIndex}';
      }
      final uri = Uri(
        scheme: 'https',
        host: host,
        port: session.peer.controlPort,
        path: path,
      );
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 2));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${session.secret}',
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'protocolVersion': protocolVersion,
          'sessionId': session.sessionId,
          'runId': session.runId,
          ...fields,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('control_rejected');
      }
      return await readBounded(
        response,
        limit: maxImportBytes,
        timeout: const Duration(seconds: 2),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }
}

Future<String> readBounded(
  Stream<List<int>> stream, {
  required int limit,
  required Duration timeout,
}) async {
  final bytes = <int>[];
  final iterator = StreamIterator<List<int>>(stream);
  final clock = Stopwatch()..start();
  try {
    while (true) {
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Message deadline exceeded.');
      }
      if (!await iterator.moveNext().timeout(remaining)) break;
      final chunk = iterator.current;
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('Message too large.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  } finally {
    await iterator.cancel();
  }
}
