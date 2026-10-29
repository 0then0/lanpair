import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'model.dart';

/// Thrown by the start handler when this device did not begin a run for the
/// request (already running, finished or busy). The peer then gets 409 and
/// must not treat this device as ready.
class StartDeclined implements Exception {
  const StartDeclined();
}

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
  Future<void>? _opening;
  bool _closed = false;
  int _requests = 0;
  int _inflight = 0;

  /// A link has one lifecycle: created, opened at most once, closed for good.
  /// The owner creates a new link for every listener it needs.
  bool get isOpen => _server != null && !_closed;
  bool get isClosed => _closed;
  String? _boundAddress;
  int? _boundPort;

  /// Whether the open listener serves [session]'s local endpoint.
  bool serves(Session session) =>
      isOpen &&
      this.session.sessionId == session.sessionId &&
      _boundAddress == session.local.address &&
      _boundPort == session.local.controlPort;

  Future<void> open() {
    if (_closed) return Future.error(StateError('Control link is closed.'));
    return _opening ??= _bind();
  }

  Future<void> _bind() async {
    final address = session.local.address;
    final port = session.local.controlPort;
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(
        utf8.encode(session.localIdentity.certificatePem),
      )
      ..usePrivateKeyBytes(utf8.encode(session.localIdentity.privateKeyPem));
    final server = await HttpServer.bindSecure(address, port, context);
    if (_closed) {
      // close() was requested while the bind was pending: never publish it.
      await server.close(force: true);
      return;
    }
    _server = server;
    _boundAddress = address;
    _boundPort = port;
    server.idleTimeout = const Duration(seconds: 2);
    server.listen((request) => unawaited(_handle(request)));
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
          try {
            await onStart().timeout(const Duration(seconds: 2));
            request.response.write('{}');
          } on StartDeclined {
            request.response.statusCode = HttpStatus.conflict;
          }
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

  /// Releases the listener. Safe to call repeatedly and while [open] is
  /// still pending; in that case the late bind is closed as soon as it ends.
  Future<void> close() async {
    _closed = true;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    try {
      await _opening;
    } catch (_) {
      /* A failed bind leaves nothing to release. */
    }
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
