import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'model.dart';
import 'platform_bridge.dart';

const multicastPort = 45834;
const maxPacketBytes = 1200;

/// An authenticated, bounded datagram. HMAC-SHA256 authenticates probe metadata;
/// it does not encrypt it. No invitation credentials are transmitted in probes.
class ProbePacket {
  const ProbePacket({
    required this.sessionId,
    required this.runId,
    required this.from,
    required this.to,
    required this.check,
    required this.family,
    required this.sequence,
    this.ack = false,
  });
  final String sessionId, runId, from, to;
  final CheckKind check;
  final IpFamily family;
  final int sequence;
  final bool ack;
  Map<String, Object?> get _body => {
    'v': protocolVersion,
    's': sessionId,
    'r': runId,
    'f': from,
    't': to,
    'c': check.name,
    'i': family.name,
    'n': sequence,
    'a': ack,
  };
  List<int> encode(String secret) {
    final body = jsonEncode(_body);
    return utf8.encode(
      jsonEncode({
        'p': body,
        'h': Hmac(
          sha256,
          utf8.encode(secret),
        ).convert(utf8.encode(body)).toString(),
      }),
    );
  }

  static ProbePacket? decode(List<int> bytes, Session session) {
    if (bytes.length > maxPacketBytes) return null;
    try {
      final envelope = jsonObject(jsonDecode(utf8.decode(bytes)), 'packet');
      final body = envelope['p'];
      if (body is! String || envelope['h'] is! String) return null;
      final mac = Hmac(
        sha256,
        utf8.encode(session.secret),
      ).convert(utf8.encode(body)).toString();
      if (!constantTimeEqual(mac, envelope['h'] as String)) return null;
      final p = jsonObject(jsonDecode(body), 'body');
      if (p['v'] != protocolVersion ||
          p['s'] != session.sessionId ||
          p['r'] != session.runId ||
          p['f'] != session.peer.id ||
          p['t'] != session.local.id ||
          p['n'] is! int ||
          p['a'] is! bool) {
        return null;
      }
      final sequence = p['n'] as int;
      if (sequence < 0 || sequence >= session.plan.packetCount) return null;
      final check = CheckKind.values.byName(p['c'] as String);
      final family = IpFamily.values.byName(p['i'] as String);
      if (check == CheckKind.dnsSd || family == IpFamily.system) return null;
      return ProbePacket(
        sessionId: session.sessionId,
        runId: session.runId,
        from: session.peer.id,
        to: session.local.id,
        check: check,
        family: family,
        sequence: sequence,
        ack: p['a'] as bool,
      );
    } catch (_) {
      return null;
    }
  }
}

class ProbeEngine {
  ProbeEngine({
    required this.session,
    required this.platform,
    required this.capabilities,
    this.onProgress,
    this.dropAcknowledgements = false,
  });
  final Session session;
  final PlatformBridge platform;
  final Map<String, dynamic> capabilities;
  final void Function(double progress)? onProgress;

  /// Test seam, never enabled by the application.
  final bool dropAcknowledgements;
  final _clock = Stopwatch();
  final _end = Completer<void>();
  final _observations = <Observation>[];
  final _tcp = <ServerSocket>[];
  final _udp = <RawDatagramSocket>[];
  final _connections = <Socket>{};
  final _seen = <String>{};
  final _terminal = <String>{};
  final _senders = <Future<void>>[];
  final _jobs = <Future<void> Function()>[];
  StreamSubscription<Map<String, dynamic>>? _discovery;
  Timer? _deadline, _progressTimer;
  bool _active = false;
  bool _used = false;
  final _acceptedTcp = <IpFamily, int>{};
  DateTime? _started;
  List<Observation> get observations => List.unmodifiable(_observations);
  bool get active => _active && !_end.isCompleted;

  String _key(CheckKind check, IpFamily family, {bool incoming = false}) =>
      '${check.name}/${family.name}/$incoming';
  void _record(
    ObservationKind kind,
    CheckKind check,
    IpFamily family, {
    bool incoming = false,
    int? sequence,
    String? code,
  }) {
    if (!_active || _observations.length >= maxObservations) return;
    if ([
      ObservationKind.error,
      ObservationKind.unsupported,
      ObservationKind.permissionDenied,
      ObservationKind.cancelled,
      ObservationKind.suspended,
      ObservationKind.networkChanged,
    ].contains(kind)) {
      _terminal.add(_key(check, family, incoming: incoming));
    }
    _observations.add(
      Observation(
        id: randomId(),
        reporterId: session.local.id,
        kind: kind,
        check: check,
        fromDeviceId: incoming ? session.peer.id : session.local.id,
        toDeviceId: incoming ? session.local.id : session.peer.id,
        family: family,
        sequence: sequence,
        elapsedMicros: _clock.elapsedMicroseconds,
        wallTime: DateTime.now().toUtc(),
        code: code,
        interfaceName: check == CheckKind.dnsSd && _systemSelectedDiscovery
            ? null
            : session.local.interfaceName,
      ),
    );
  }

  void _both(
    ObservationKind kind,
    CheckKind check,
    IpFamily family, {
    String? code,
  }) {
    _record(kind, check, family, code: code);
    _record(kind, check, family, incoming: true, code: code);
  }

  bool get _systemSelectedDiscovery =>
      (capabilities['limitationCodes'] as List?)?.contains(
        'discovery_interface_system_selected',
      ) ??
      false;

  RunReport get snapshot => RunReport(
    sessionId: session.sessionId,
    runId: session.runId,
    reportingDeviceId: session.local.id,
    devices: [session.a, session.b],
    parameters: session.plan,
    capabilities: {
      '${session.local.id}.permission':
          '${capabilities['permission'] ?? 'unknown'}',
      '${session.local.id}.rawMulticast': capabilities['rawMulticast'] == true
          ? 'available'
          : 'unsupported',
      '${session.local.id}.discoveryInterface': _systemSelectedDiscovery
          ? 'system_selected'
          : 'selected',
      '${session.local.id}.discovery': capabilities['discovery'] == true
          ? 'available'
          : 'unsupported',
    },
    observations: observations,
    startedAt: _started!,
    durationMicros: _clock.elapsedMicroseconds,
    platform: Platform.operatingSystem,
  );

  ProbePacket _packet(
    CheckKind check,
    IpFamily family,
    int sequence, {
    bool ack = false,
  }) => ProbePacket(
    sessionId: session.sessionId,
    runId: session.runId,
    from: session.local.id,
    to: session.peer.id,
    check: check,
    family: family,
    sequence: sequence,
    ack: ack,
  );

  Future<RunReport> run({Future<void> Function()? onReady}) async {
    if (_used) throw StateError('A run is single use.');
    _used = true;
    _active = true;
    _started = DateTime.now().toUtc();
    _clock.start();
    _deadline = Timer(Duration(milliseconds: session.plan.durationMs), () {
      if (!_end.isCompleted) _end.complete();
    });
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => onProgress?.call(
        (_clock.elapsedMilliseconds / session.plan.durationMs).clamp(0.0, 1.0),
      ),
    );
    try {
      if (capabilities['permission'] == 'denied') {
        for (final family in [IpFamily.ipv4, IpFamily.ipv6]) {
          for (final check in [
            CheckKind.tcp,
            CheckKind.udp,
            CheckKind.multicast,
          ]) {
            _both(
              ObservationKind.permissionDenied,
              check,
              family,
              code: 'local_network_denied',
            );
          }
        }
        _both(
          ObservationKind.permissionDenied,
          CheckKind.dnsSd,
          IpFamily.system,
          code: 'local_network_denied',
        );
        _end.complete();
      } else {
        for (final family in [IpFamily.ipv4, IpFamily.ipv6]) {
          if (!active) break;
          await _setupFamily(family);
        }
        if (active) await _setupDiscovery();
        if (active && onReady != null) {
          try {
            final remaining =
                Duration(milliseconds: session.plan.durationMs) -
                _clock.elapsed;
            if (remaining > Duration.zero) await onReady().timeout(remaining);
          } catch (_) {
            /* Offline operation still runs the local plan. */
          }
        }
        if (active) {
          _senders.addAll(_jobs.map((job) => job()));
        }
      }
      await _end.future;
      for (final family in [IpFamily.ipv4, IpFamily.ipv6]) {
        for (final check in [
          CheckKind.tcp,
          CheckKind.udp,
          CheckKind.multicast,
        ]) {
          if (!_terminal.contains(_key(check, family))) {
            _record(
              ObservationKind.timedOut,
              check,
              family,
              code: 'window_ended',
            );
          }
        }
      }
      if (!_terminal.contains(_key(CheckKind.dnsSd, IpFamily.system))) {
        _record(
          ObservationKind.timedOut,
          CheckKind.dnsSd,
          IpFamily.system,
          code: 'window_ended',
        );
      }
    } finally {
      _active = false;
      _clock.stop();
      _deadline?.cancel();
      _progressTimer?.cancel();
      for (final socket in _connections.toList()) {
        socket.destroy();
      }
      for (final socket in _tcp) {
        await socket.close();
      }
      for (final socket in _udp) {
        socket.close();
      }
      await _discovery?.cancel();
      try {
        await platform.stopDiscovery().timeout(const Duration(seconds: 1));
      } catch (_) {
        /* Unavailable service. */
      }
      try {
        await platform.releaseMulticast().timeout(const Duration(seconds: 1));
      } catch (_) {
        /* No acquired lock. */
      }
      await Future.wait(_senders);
    }
    onProgress?.call(1);
    return snapshot;
  }

  void cancel({ObservationKind reason = ObservationKind.cancelled}) {
    if (!_active || _end.isCompleted) return;
    for (final family in [IpFamily.ipv4, IpFamily.ipv6]) {
      for (final check in [CheckKind.tcp, CheckKind.udp, CheckKind.multicast]) {
        _both(reason, check, family, code: _reasonCode(reason));
      }
    }
    _both(reason, CheckKind.dnsSd, IpFamily.system, code: _reasonCode(reason));
    _end.complete();
  }

  InternetAddress? _address(
    DeviceEndpoint endpoint,
    IpFamily family, {
    bool local = false,
  }) {
    var value = family == IpFamily.ipv4
        ? endpoint.address
        : endpoint.ipv6Address;
    if (value == null || value.isEmpty) return null;
    // A peer's textual zone belongs to its OS. Scope link-local IPv6 using the
    // selected LOCAL interface index, never an imported remote zone name.
    if (family == IpFamily.ipv6) {
      value = value.split('%').first;
      if (value.toLowerCase().startsWith('fe80:')) {
        value = '$value%${session.local.interfaceIndex}';
      }
    }
    final result = InternetAddress.tryParse(value);
    if (result == null ||
        family == IpFamily.ipv4 && result.type != InternetAddressType.IPv4 ||
        family == IpFamily.ipv6 && result.type != InternetAddressType.IPv6) {
      return null;
    }
    return result;
  }

  Future<void> _setupFamily(IpFamily family) async {
    final local = _address(session.local, family, local: true);
    final peer = _address(session.peer, family);
    if (local == null) {
      for (final check in [CheckKind.tcp, CheckKind.udp, CheckKind.multicast]) {
        _both(
          ObservationKind.unsupported,
          check,
          family,
          code: 'address_family_unavailable',
        );
      }
      return;
    }
    try {
      final server = await ServerSocket.bind(
        local,
        session.local.tcpPort,
        v6Only: family == IpFamily.ipv6,
      );
      _tcp.add(server);
      server.listen(
        (socket) {
          if (!active ||
              (_acceptedTcp[family] ?? 0) >= session.plan.packetCount ||
              _connections.length >= 4) {
            socket.destroy();
            return;
          }
          _connections.add(socket);
          unawaited(_acceptTcp(socket, family));
        },
        onError: (Object e) {
          _record(
            _errorKind(e),
            CheckKind.tcp,
            family,
            incoming: true,
            code: _errorCode(e),
          );
        },
      );
    } catch (e) {
      _record(
        _errorKind(e),
        CheckKind.tcp,
        family,
        incoming: true,
        code: _errorCode(e),
      );
    }
    if (peer != null) {
      _jobs.add(() => _sendTcp(local, peer, family));
    } else {
      _record(
        ObservationKind.unsupported,
        CheckKind.tcp,
        family,
        code: 'peer_address_unavailable',
      );
    }
    try {
      final socket = await RawDatagramSocket.bind(local, session.local.udpPort);
      _udp.add(socket);
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read || !active) return;
          Datagram? data;
          var readBudget = 16;
          while (readBudget-- > 0 && (data = socket.receive()) != null) {
            final packet = ProbePacket.decode(data!.data, session);
            if (packet == null ||
                packet.check != CheckKind.udp ||
                packet.family != family ||
                data.port != session.peer.udpPort ||
                peer == null ||
                !_sameAddress(data.address, peer)) {
              continue;
            }
            final key = 'udp/${family.name}/${packet.ack}/${packet.sequence}';
            if (!_seen.add(key)) continue;
            _record(
              packet.ack
                  ? ObservationKind.acknowledged
                  : ObservationKind.received,
              CheckKind.udp,
              family,
              incoming: !packet.ack,
              sequence: packet.sequence,
            );
            if (!packet.ack && !dropAcknowledgements) {
              final reply = _packet(
                CheckKind.udp,
                family,
                packet.sequence,
                ack: true,
              ).encode(session.secret);
              // No amplification and only one reply per authenticated sequence.
              if (reply.length <= data.data.length) {
                socket.send(reply, data.address, data.port);
              }
            }
          }
        },
        onError: (Object e) {
          _both(_errorKind(e), CheckKind.udp, family, code: _errorCode(e));
        },
      );
      if (peer != null) {
        _jobs.add(
          () => _sendDatagrams(
            socket,
            peer,
            session.peer.udpPort,
            CheckKind.udp,
            family,
          ),
        );
      } else {
        _record(
          ObservationKind.unsupported,
          CheckKind.udp,
          family,
          code: 'peer_address_unavailable',
        );
      }
    } catch (e) {
      _both(_errorKind(e), CheckKind.udp, family, code: _errorCode(e));
    }
    if (capabilities['rawMulticast'] != true) {
      _both(
        ObservationKind.unsupported,
        CheckKind.multicast,
        family,
        code: 'multicast_entitlement_or_platform',
      );
      return;
    }
    try {
      await platform.acquireMulticast().timeout(const Duration(seconds: 1));
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: true,
        includeLoopback: true,
      );
      final selected = interfaces
          .where(
            (i) =>
                i.index == session.local.interfaceIndex ||
                i.name == session.local.interfaceName,
          )
          .firstOrNull;
      if (selected == null) {
        throw const SocketException('interface_unavailable');
      }
      final socket = await RawDatagramSocket.bind(
        family == IpFamily.ipv4
            ? InternetAddress.anyIPv4
            : InternetAddress.anyIPv6,
        multicastPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      _udp.add(socket);
      final group = InternetAddress(
        family == IpFamily.ipv4 ? '239.255.77.77' : 'ff02::114',
      );
      socket.multicastHops = 1;
      socket.multicastLoopback = false;
      if (family == IpFamily.ipv4) {
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            local.rawAddress,
          ),
        );
      } else {
        socket.setRawOption(
          RawSocketOption.fromInt(
            RawSocketOption.levelIPv6,
            RawSocketOption.IPv6MulticastInterface,
            selected.index,
          ),
        );
      }
      socket.joinMulticast(group, selected);
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read || !active) return;
          Datagram? data;
          var readBudget = 16;
          while (readBudget-- > 0 && (data = socket.receive()) != null) {
            final packet = ProbePacket.decode(data!.data, session);
            // decode rejects our own device id; multicast never sends an ACK.
            if (packet == null ||
                packet.check != CheckKind.multicast ||
                packet.family != family ||
                packet.ack) {
              continue;
            }
            if (_seen.add('multicast/${family.name}/${packet.sequence}')) {
              _record(
                ObservationKind.received,
                CheckKind.multicast,
                family,
                incoming: true,
                sequence: packet.sequence,
              );
            }
          }
        },
        onError: (Object e) {
          _record(
            _errorKind(e),
            CheckKind.multicast,
            family,
            code: _errorCode(e),
          );
        },
      );
      final destination = family == IpFamily.ipv6
          ? InternetAddress('ff02::114%${selected.index}')
          : group;
      _jobs.add(
        () => _sendDatagrams(
          socket,
          destination,
          multicastPort,
          CheckKind.multicast,
          family,
        ),
      );
    } catch (e) {
      _record(_errorKind(e), CheckKind.multicast, family, code: _errorCode(e));
    }
  }

  Future<void> _acceptTcp(Socket socket, IpFamily family) async {
    try {
      final data = await _readPacket(socket);
      final packet = ProbePacket.decode(data, session);
      if (active &&
          packet != null &&
          packet.check == CheckKind.tcp &&
          packet.family == family &&
          !packet.ack &&
          _seen.add('tcp/${family.name}/${packet.sequence}')) {
        _acceptedTcp[family] = (_acceptedTcp[family] ?? 0) + 1;
        _record(
          ObservationKind.received,
          CheckKind.tcp,
          family,
          incoming: true,
          sequence: packet.sequence,
        );
        socket.add([
          ..._packet(
            CheckKind.tcp,
            family,
            packet.sequence,
            ack: true,
          ).encode(session.secret),
          10,
        ]);
        await socket.flush().timeout(const Duration(seconds: 1));
      }
    } catch (_) {
      /* Unauthenticated or incomplete input is not evidence. */
    } finally {
      _connections.remove(socket);
      socket.destroy();
    }
  }

  Future<void> _sendTcp(
    InternetAddress local,
    InternetAddress peer,
    IpFamily family,
  ) async {
    // Small fixed retries allow the second device to prepare its listeners.
    for (
      var sequence = 0;
      sequence < session.plan.packetCount && active;
      sequence++
    ) {
      Socket? socket;
      try {
        socket = await Socket.connect(
          peer,
          session.peer.tcpPort,
          sourceAddress: local,
          timeout: const Duration(milliseconds: 800),
        );
        if (!active) {
          socket.destroy();
          return;
        }
        _connections.add(socket);
        _record(
          ObservationKind.connected,
          CheckKind.tcp,
          family,
          sequence: sequence,
        );
        socket.add([
          ..._packet(CheckKind.tcp, family, sequence).encode(session.secret),
          10,
        ]);
        await socket.flush().timeout(const Duration(milliseconds: 800));
        final reply = ProbePacket.decode(await _readPacket(socket), session);
        if (active && reply?.ack == true) {
          _record(
            ObservationKind.acknowledged,
            CheckKind.tcp,
            family,
            sequence: sequence,
          );
        }
        return;
      } catch (e) {
        if (e is SocketException &&
            [1, 13, 10013].contains(e.osError?.errorCode)) {
          _record(
            ObservationKind.permissionDenied,
            CheckKind.tcp,
            family,
            code: 'socket_permission_denied',
          );
          return;
        }
        // Connection refusal/timeouts describe only this attempt. Final
        // timeout is recorded at the end of the bounded observation window.
      } finally {
        if (socket != null) {
          _connections.remove(socket);
          socket.destroy();
        }
      }
      await Future<void>.delayed(
        Duration(milliseconds: session.plan.intervalMs),
      );
    }
  }

  Future<List<int>> _readPacket(Socket socket) async {
    final bytes = <int>[];
    final iterator = StreamIterator<List<int>>(socket);
    final clock = Stopwatch()..start();
    try {
      while (true) {
        final remaining = const Duration(milliseconds: 800) - clock.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Probe deadline exceeded.');
        }
        if (!await iterator.moveNext().timeout(remaining)) break;
        for (final byte in iterator.current) {
          if (byte == 10) return bytes;
          if (bytes.length >= maxPacketBytes) {
            throw const FormatException('Packet too large.');
          }
          bytes.add(byte);
        }
      }
      throw const FormatException('Incomplete packet.');
    } finally {
      await iterator.cancel();
    }
  }

  Future<void> _sendDatagrams(
    RawDatagramSocket socket,
    InternetAddress destination,
    int port,
    CheckKind check,
    IpFamily family,
  ) async {
    for (
      var sequence = 0;
      sequence < session.plan.packetCount && active;
      sequence++
    ) {
      await Future<void>.delayed(
        Duration(milliseconds: session.plan.intervalMs),
      );
      if (!active) break;
      try {
        final bytes = _packet(check, family, sequence).encode(session.secret);
        if (socket.send(bytes, destination, port) == bytes.length) {
          _record(ObservationKind.sent, check, family, sequence: sequence);
        } else {
          _record(
            ObservationKind.error,
            check,
            family,
            sequence: sequence,
            code: 'local_send_failed',
          );
        }
      } catch (e) {
        _record(
          _errorKind(e),
          check,
          family,
          sequence: sequence,
          code: _errorCode(e),
        );
        break;
      }
    }
  }

  Future<void> _setupDiscovery() async {
    if (capabilities['discovery'] != true) {
      _record(
        ObservationKind.unsupported,
        CheckKind.dnsSd,
        IpFamily.system,
        code: 'system_discovery_unavailable',
      );
      return;
    }
    try {
      _discovery = platform.events.listen(
        (event) {
          if (!active) return;
          if (event['type'] == 'networkChanged') {
            cancel(reason: ObservationKind.networkChanged);
            return;
          }
          if (event['type'] == 'error') {
            _record(
              (event['code'] == 'permissionDenied' ||
                      event['code'] == 'permission_denied')
                  ? ObservationKind.permissionDenied
                  : ObservationKind.error,
              CheckKind.dnsSd,
              IpFamily.system,
              code: 'discovery_operation_failed',
            );
            return;
          }
          if (event['type'] == 'published') {
            _record(
              ObservationKind.published,
              CheckKind.dnsSd,
              IpFamily.system,
            );
            return;
          }
          if (event['sessionId'] != session.sessionId ||
              event['deviceId'] != session.peer.id) {
            return;
          }
          if (event['type'] == 'discovered') {
            _record(
              ObservationKind.discovered,
              CheckKind.dnsSd,
              IpFamily.system,
              incoming: true,
            );
          }
          if (event['type'] == 'resolved') {
            _record(
              ObservationKind.resolved,
              CheckKind.dnsSd,
              IpFamily.system,
              incoming: true,
            );
          }
        },
        onError: (Object e) {
          _record(
            ObservationKind.error,
            CheckKind.dnsSd,
            IpFamily.system,
            code: 'discovery_channel_error',
          );
        },
      );
      await platform
          .startDiscovery(
            sessionId: session.sessionId,
            deviceId: session.local.id,
            port: session.local.controlPort,
            interfaceIndex: session.local.interfaceIndex,
          )
          .timeout(const Duration(seconds: 1));
    } catch (e) {
      _record(
        ObservationKind.unsupported,
        CheckKind.dnsSd,
        IpFamily.system,
        code: 'discovery_unavailable',
      );
    }
  }
}

bool _sameAddress(InternetAddress a, InternetAddress b) =>
    a.address.split('%').first == b.address.split('%').first;
ObservationKind _errorKind(Object error) =>
    error is SocketException &&
        [1, 13, 10013].contains(error.osError?.errorCode)
    ? ObservationKind.permissionDenied
    : ObservationKind.error;
String _errorCode(Object error) => error is SocketException
    ? 'socket_error_${error.osError?.errorCode.abs() ?? 'unknown'}'
    : 'operation_failed';

String _reasonCode(ObservationKind reason) => switch (reason) {
  ObservationKind.networkChanged => 'network_changed',
  ObservationKind.permissionDenied => 'permission_denied',
  _ => reason.name,
};
