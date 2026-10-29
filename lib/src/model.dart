import 'dart:convert';
import 'dart:math';

const protocolVersion = 1;
const reportVersion = 1;
const appVersion = '0.1.1';

/// Version of the interpretation rules exported with a report. Version 1
/// (LANPair 0.1.0) treated a bare TCP connect as success; version 2 requires
/// an authenticated exchange.
const interpretationVersion = 2;
const maxImportBytes = 1024 * 1024;
const maxObservations = 4096;
const _currentAppVersion = appVersion;

/// Codes of single TCP attempts that failed without proving anything about the
/// peer. They are non-terminal observations: a later attempt may still succeed.
const tcpAttemptCodes = {
  'connection_refused',
  'connect_timeout',
  'host_unreachable',
};

/// The connection was established, but no valid authenticated reply followed.
const tcpReplyProblemCodes = {'tcp_reply_missing', 'tcp_reply_invalid'};

enum DeviceRole { a, b }

enum CheckKind { tcp, udp, multicast, dnsSd }

enum IpFamily { ipv4, ipv6, system }

enum Outcome {
  passed,
  failed,
  inconclusive,
  unsupported,
  permissionDenied,
  cancelled,
}

enum ObservationKind {
  sent,
  received,
  acknowledged,
  connected,
  timedOut,
  error,
  unsupported,
  permissionDenied,
  cancelled,
  suspended,
  networkChanged,
  published,
  discovered,
  resolved,
}

String randomId([int bytes = 16]) {
  final random = Random.secure();
  return List.generate(
    bytes,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class DeviceEndpoint {
  const DeviceEndpoint({
    required this.id,
    required this.address,
    this.ipv6Address,
    this.interfaceName = '',
    this.interfaceIndex = 0,
    this.tcpPort = 45831,
    this.udpPort = 45832,
    this.controlPort = 45833,
  });

  final String id;
  final String address;
  final String? ipv6Address;
  final String interfaceName;
  final int interfaceIndex;
  final int tcpPort;
  final int udpPort;
  final int controlPort;

  DeviceEndpoint copyWith({
    String? address,
    String? ipv6Address,
    String? interfaceName,
    int? interfaceIndex,
    int? tcpPort,
    int? udpPort,
    int? controlPort,
  }) => DeviceEndpoint(
    id: id,
    address: address ?? this.address,
    ipv6Address: ipv6Address ?? this.ipv6Address,
    interfaceName: interfaceName ?? this.interfaceName,
    interfaceIndex: interfaceIndex ?? this.interfaceIndex,
    tcpPort: tcpPort ?? this.tcpPort,
    udpPort: udpPort ?? this.udpPort,
    controlPort: controlPort ?? this.controlPort,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'address': address,
    'ipv6Address': ipv6Address,
    'interfaceName': interfaceName,
    'interfaceIndex': interfaceIndex,
    'tcpPort': tcpPort,
    'udpPort': udpPort,
    'controlPort': controlPort,
  };

  factory DeviceEndpoint.fromJson(Object? value) {
    final map = jsonObject(value, 'endpoint');
    onlyKeys(map, const {
      'id',
      'address',
      'ipv6Address',
      'interfaceName',
      'interfaceIndex',
      'tcpPort',
      'udpPort',
      'controlPort',
    });
    return DeviceEndpoint(
      id: identifier(map['id'], 'device id'),
      address: boundedString(
        map['address'],
        'address',
        max: 128,
        allowEmpty: true,
      ),
      ipv6Address: map['ipv6Address'] == null
          ? null
          : boundedString(
              map['ipv6Address'],
              'IPv6 address',
              max: 128,
              allowEmpty: true,
            ),
      interfaceName: boundedString(
        map['interfaceName'],
        'interface name',
        max: 128,
        allowEmpty: true,
      ),
      interfaceIndex: boundedInt(
        map['interfaceIndex'],
        'interface index',
        min: 0,
        max: 0x7fffffff,
      ),
      tcpPort: boundedInt(map['tcpPort'], 'TCP port', min: 1024, max: 65535),
      udpPort: boundedInt(map['udpPort'], 'UDP port', min: 1024, max: 65535),
      controlPort: boundedInt(
        map['controlPort'],
        'control port',
        min: 1024,
        max: 65535,
      ),
    );
  }
}

class TlsIdentity {
  const TlsIdentity({
    required this.certificatePem,
    required this.privateKeyPem,
    required this.fingerprint,
  });
  final String certificatePem;
  final String privateKeyPem;
  final String fingerprint;

  Map<String, Object?> toJson({bool includePrivate = false}) => {
    'certificatePem': certificatePem,
    'fingerprint': fingerprint,
    if (includePrivate) 'privateKeyPem': privateKeyPem,
  };

  factory TlsIdentity.fromJson(Object? value, {required bool withPrivate}) {
    final map = jsonObject(value, 'TLS identity');
    onlyKeys(map, {
      'certificatePem',
      'fingerprint',
      if (withPrivate) 'privateKeyPem',
    });
    final certificate = boundedString(
      map['certificatePem'],
      'certificate',
      max: 8192,
      allowControls: true,
    );
    final key = withPrivate
        ? boundedString(
            map['privateKeyPem'],
            'private key',
            max: 8192,
            allowControls: true,
          )
        : '';
    final pin = boundedString(
      map['fingerprint'],
      'certificate fingerprint',
      max: 64,
    );
    if (!certificate.startsWith('-----BEGIN CERTIFICATE-----') ||
        !certificate.endsWith('-----END CERTIFICATE-----\n') &&
            !certificate.endsWith('-----END CERTIFICATE-----') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(pin) ||
        withPrivate && !key.startsWith('-----BEGIN ')) {
      throw const FormatException('Invalid TLS identity.');
    }
    return TlsIdentity(
      certificatePem: certificate,
      privateKeyPem: key,
      fingerprint: pin,
    );
  }
}

class Session {
  Session._({
    required this.sessionId,
    required this.runId,
    required this.secret,
    required this.localRole,
    required this.a,
    required this.b,
    required this.localIdentity,
    required this.peerCertificatePem,
    required this.peerFingerprint,
    required this.plan,
    this._joiningIdentity,
  });

  factory Session.create({
    required DeviceEndpoint a,
    required DeviceEndpoint b,
    required TlsIdentity aIdentity,
    required TlsIdentity bIdentity,
    RunPlan plan = const RunPlan(),
  }) {
    if (a.id == b.id) {
      throw ArgumentError('Participants must have different identifiers.');
    }
    DeviceEndpoint.fromJson(a.toJson());
    DeviceEndpoint.fromJson(b.toJson());
    TlsIdentity.fromJson(
      aIdentity.toJson(includePrivate: true),
      withPrivate: true,
    );
    TlsIdentity.fromJson(
      bIdentity.toJson(includePrivate: true),
      withPrivate: true,
    );
    RunPlan.fromJson(plan.toJson());
    return Session._(
      sessionId: randomId(),
      runId: randomId(),
      secret: randomId(32),
      localRole: DeviceRole.a,
      a: a,
      b: b,
      localIdentity: aIdentity,
      peerCertificatePem: bIdentity.certificatePem,
      peerFingerprint: bIdentity.fingerprint,
      plan: plan,
      joiningIdentity: bIdentity,
    );
  }

  final String sessionId;
  final String runId;

  /// Invitation credentials. Never include this field in reports or logs.
  final String secret;
  final DeviceRole localRole;
  final DeviceEndpoint a;
  final DeviceEndpoint b;
  final TlsIdentity localIdentity;
  final String peerCertificatePem;
  final String peerFingerprint;
  final RunPlan plan;
  final TlsIdentity? _joiningIdentity;

  DeviceEndpoint get local => localRole == DeviceRole.a ? a : b;
  DeviceEndpoint get peer => localRole == DeviceRole.a ? b : a;
  DeviceEndpoint endpoint(DeviceRole role) => role == DeviceRole.a ? a : b;

  Session withEndpoint(DeviceRole role, DeviceEndpoint endpoint) {
    if (endpoint.id != this.endpoint(role).id) {
      throw ArgumentError(
        'An endpoint update cannot change the participant identity.',
      );
    }
    return Session._(
      sessionId: sessionId,
      runId: runId,
      secret: secret,
      localRole: localRole,
      a: role == DeviceRole.a ? endpoint : a,
      b: role == DeviceRole.b ? endpoint : b,
      localIdentity: localIdentity,
      peerCertificatePem: peerCertificatePem,
      peerFingerprint: peerFingerprint,
      plan: plan,
      joiningIdentity: _joiningIdentity,
    );
  }

  Session withRunId(String id) => Session._(
    sessionId: sessionId,
    runId: identifier(id, 'run id'),
    secret: secret,
    localRole: localRole,
    a: a,
    b: b,
    localIdentity: localIdentity,
    peerCertificatePem: peerCertificatePem,
    peerFingerprint: peerFingerprint,
    plan: plan,
    joiningIdentity: _joiningIdentity,
  );

  Session withoutJoinCredential() => Session._(
    sessionId: sessionId,
    runId: runId,
    secret: secret,
    localRole: localRole,
    a: a,
    b: b,
    localIdentity: localIdentity,
    peerCertificatePem: peerCertificatePem,
    peerFingerprint: peerFingerprint,
    plan: plan,
  );

  /// Carries B's ephemeral identity, both public certificates, and a bearer secret.
  /// Treat the invitation like a password. It deliberately never carries A's key.
  String invitation() {
    if (localRole != DeviceRole.a || _joiningIdentity == null) {
      throw StateError('A joining credential is not available.');
    }
    return 'lp1:${jsonEncode({'format': 'lanpair-invitation', 'protocolVersion': protocolVersion, 'sessionId': sessionId, 'runId': runId, 'secret': secret, 'a': a.toJson(), 'b': b.toJson(), 'aIdentity': localIdentity.toJson(), 'bIdentity': _joiningIdentity.toJson(includePrivate: true), 'plan': plan.toJson()})}';
  }

  factory Session.fromInvitation(String text) {
    if (!text.startsWith('lp1:')) {
      throw const FormatException('Unsupported invitation version.');
    }
    final map = jsonObject(
      boundedJsonDecode(text.substring(4), maxBytes: 24576),
      'invitation',
    );
    onlyKeys(map, const {
      'format',
      'protocolVersion',
      'sessionId',
      'runId',
      'secret',
      'a',
      'b',
      'aIdentity',
      'bIdentity',
      'plan',
    });
    if (map['format'] != 'lanpair-invitation' ||
        map['protocolVersion'] != protocolVersion) {
      throw const FormatException('Unsupported invitation version.');
    }
    final aIdentity = TlsIdentity.fromJson(
      map['aIdentity'],
      withPrivate: false,
    );
    final bIdentity = TlsIdentity.fromJson(map['bIdentity'], withPrivate: true);
    final a = DeviceEndpoint.fromJson(map['a']);
    final b = DeviceEndpoint.fromJson(map['b']);
    if (a.id == b.id) throw const FormatException('Participants must differ.');
    return Session._(
      sessionId: identifier(map['sessionId'], 'session id'),
      runId: identifier(map['runId'], 'run id'),
      secret: _secret(map['secret']),
      localRole: DeviceRole.b,
      a: a,
      b: b,
      localIdentity: bIdentity,
      peerCertificatePem: aIdentity.certificatePem,
      peerFingerprint: aIdentity.fingerprint,
      plan: RunPlan.fromJson(map['plan']),
    );
  }

  Map<String, Object?> toLocalJson() => {
    'format': 'lanpair-session-local',
    'protocolVersion': protocolVersion,
    'sessionId': sessionId,
    'runId': runId,
    'secret': secret,
    'localRole': localRole.name,
    'a': a.toJson(),
    'b': b.toJson(),
    'localIdentity': localIdentity.toJson(includePrivate: true),
    'peerIdentity': TlsIdentity(
      certificatePem: peerCertificatePem,
      privateKeyPem: '',
      fingerprint: peerFingerprint,
    ).toJson(),
    'joiningIdentity': _joiningIdentity?.toJson(includePrivate: true),
    'plan': plan.toJson(),
  };

  factory Session.fromLocalJson(Object? value) {
    final map = jsonObject(value, 'local session');
    onlyKeys(map, const {
      'format',
      'protocolVersion',
      'sessionId',
      'runId',
      'secret',
      'localRole',
      'a',
      'b',
      'localIdentity',
      'peerIdentity',
      'joiningIdentity',
      'plan',
    });
    if (map['format'] != 'lanpair-session-local' ||
        map['protocolVersion'] != protocolVersion) {
      throw const FormatException('Unsupported local session version.');
    }
    final peer = TlsIdentity.fromJson(map['peerIdentity'], withPrivate: false);
    final a = DeviceEndpoint.fromJson(map['a']);
    final b = DeviceEndpoint.fromJson(map['b']);
    if (a.id == b.id) throw const FormatException('Participants must differ.');
    return Session._(
      sessionId: identifier(map['sessionId'], 'session id'),
      runId: identifier(map['runId'], 'run id'),
      secret: _secret(map['secret']),
      localRole: enumValue(DeviceRole.values, map['localRole'], 'local role'),
      a: a,
      b: b,
      localIdentity: TlsIdentity.fromJson(
        map['localIdentity'],
        withPrivate: true,
      ),
      peerCertificatePem: peer.certificatePem,
      peerFingerprint: peer.fingerprint,
      plan: RunPlan.fromJson(map['plan']),
      joiningIdentity: map['joiningIdentity'] == null
          ? null
          : TlsIdentity.fromJson(map['joiningIdentity'], withPrivate: true),
    );
  }

  static String _secret(Object? value) {
    if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const FormatException('Invalid invitation credential.');
    }
    return value;
  }
}

class RunPlan {
  const RunPlan({
    this.durationMs = 6000,
    this.packetCount = 3,
    this.intervalMs = 250,
  });
  final int durationMs;
  final int packetCount;
  final int intervalMs;

  Map<String, Object?> toJson() => {
    'durationMs': durationMs,
    'packetCount': packetCount,
    'intervalMs': intervalMs,
  };

  factory RunPlan.fromJson(Object? value) {
    final map = jsonObject(value, 'run parameters');
    onlyKeys(map, const {'durationMs', 'packetCount', 'intervalMs'});
    final plan = RunPlan(
      durationMs: boundedInt(
        map['durationMs'],
        'duration',
        min: 1000,
        max: 15000,
      ),
      packetCount: boundedInt(
        map['packetCount'],
        'packet count',
        min: 1,
        max: 3,
      ),
      intervalMs: boundedInt(
        map['intervalMs'],
        'packet interval',
        min: 100,
        max: 1000,
      ),
    );
    if (plan.intervalMs * plan.packetCount >= plan.durationMs) {
      throw const FormatException('Packet budget does not fit within the run.');
    }
    return plan;
  }

  bool sameAs(RunPlan other) =>
      durationMs == other.durationMs &&
      packetCount == other.packetCount &&
      intervalMs == other.intervalMs;
}

class Observation {
  const Observation({
    required this.id,
    required this.reporterId,
    required this.kind,
    required this.check,
    required this.fromDeviceId,
    required this.toDeviceId,
    required this.family,
    required this.elapsedMicros,
    required this.wallTime,
    this.sequence,
    this.code,
    this.interfaceName,
  });

  final String id;
  final String reporterId;
  final ObservationKind kind;
  final CheckKind check;
  final String fromDeviceId;
  final String toDeviceId;
  final IpFamily family;
  final int? sequence;
  final int elapsedMicros;
  final DateTime wallTime;
  final String? code;
  final String? interfaceName;

  Map<String, Object?> toJson() => {
    'id': id,
    'reporterId': reporterId,
    'kind': kind.name,
    'check': check.name,
    'fromDeviceId': fromDeviceId,
    'toDeviceId': toDeviceId,
    'family': family.name,
    'sequence': sequence,
    'elapsedMicros': elapsedMicros,
    'wallTime': wallTime.toUtc().toIso8601String(),
    'code': code,
    'interfaceName': interfaceName,
  };

  factory Observation.fromJson(Object? value) {
    final map = jsonObject(value, 'observation');
    onlyKeys(map, const {
      'id',
      'reporterId',
      'kind',
      'check',
      'fromDeviceId',
      'toDeviceId',
      'family',
      'sequence',
      'elapsedMicros',
      'wallTime',
      'code',
      'interfaceName',
    });
    return Observation(
      id: identifier(map['id'], 'observation id'),
      reporterId: identifier(map['reporterId'], 'reporter id'),
      kind: enumValue(ObservationKind.values, map['kind'], 'observation kind'),
      check: enumValue(CheckKind.values, map['check'], 'check'),
      fromDeviceId: identifier(map['fromDeviceId'], 'source device id'),
      toDeviceId: identifier(map['toDeviceId'], 'target device id'),
      family: enumValue(IpFamily.values, map['family'], 'address family'),
      sequence: map['sequence'] == null
          ? null
          : boundedInt(map['sequence'], 'packet sequence', min: 0, max: 2),
      elapsedMicros: boundedInt(
        map['elapsedMicros'],
        'monotonic duration',
        min: 0,
        max: 120000000,
      ),
      wallTime: utcDate(map['wallTime']),
      code: map['code'] == null ? null : machineCode(map['code']),
      interfaceName: map['interfaceName'] == null
          ? null
          : boundedString(
              map['interfaceName'],
              'interface name',
              max: 128,
              allowEmpty: true,
            ),
    );
  }
}

class SourceRun {
  const SourceRun({
    required this.deviceId,
    required this.platform,
    required this.appVersion,
    required this.startedAt,
    required this.durationMicros,
  });
  final String deviceId;
  final String platform;
  final String appVersion;
  final DateTime startedAt;
  final int durationMicros;

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'platform': platform,
    'appVersion': appVersion,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'durationMicros': durationMicros,
  };

  factory SourceRun.fromJson(Object? value) {
    final map = jsonObject(value, 'source run');
    onlyKeys(map, const {
      'deviceId',
      'platform',
      'appVersion',
      'startedAt',
      'durationMicros',
    });
    return SourceRun(
      deviceId: identifier(map['deviceId'], 'source device id'),
      platform: boundedString(map['platform'], 'platform', max: 80),
      appVersion: boundedString(map['appVersion'], 'app version', max: 32),
      startedAt: utcDate(map['startedAt']),
      durationMicros: boundedInt(
        map['durationMicros'],
        'source duration',
        min: 0,
        max: 120000000,
      ),
    );
  }
}

class RunReport {
  RunReport({
    required this.sessionId,
    required this.runId,
    required this.reportingDeviceId,
    required this.devices,
    required this.parameters,
    required this.capabilities,
    required this.observations,
    required this.startedAt,
    required this.durationMicros,
    this.platform = 'unknown',
    this.appVersion = _currentAppVersion,
    List<String> sourceDeviceIds = const [],
    List<SourceRun> sourceRuns = const [],
    this.redacted = false,
  }) : sourceDeviceIds = sourceDeviceIds.isEmpty
           ? [reportingDeviceId]
           : List.unmodifiable(sourceDeviceIds),
       sourceRuns = sourceRuns.isEmpty
           ? [
               SourceRun(
                 deviceId: reportingDeviceId,
                 platform: platform,
                 appVersion: appVersion,
                 startedAt: startedAt,
                 durationMicros: durationMicros,
               ),
             ]
           : List.unmodifiable(sourceRuns);

  final String sessionId;
  final String runId;
  final String reportingDeviceId;

  /// Ordered A, B. Session-scoped identities remain stable when addresses change.
  final List<DeviceEndpoint> devices;
  final RunPlan parameters;
  final Map<String, String> capabilities;
  final List<Observation> observations;
  final DateTime startedAt;

  /// Local stopwatch duration, never inferred by subtracting peer wall clocks.
  final int durationMicros;
  final String platform;
  final String appVersion;
  final List<String> sourceDeviceIds;
  final List<SourceRun> sourceRuns;
  final bool redacted;

  Map<String, Object?> toJson() => {
    'format': 'lanpair-report',
    'reportVersion': reportVersion,
    'protocolVersion': protocolVersion,
    'appVersion': appVersion,
    'sessionId': sessionId,
    'runId': runId,
    'reportingDeviceId': reportingDeviceId,
    'sourceDeviceIds': sourceDeviceIds,
    'sourceRuns': sourceRuns.map((s) => s.toJson()).toList(),
    'devices': devices.map((d) => d.toJson()).toList(),
    'parameters': parameters.toJson(),
    'capabilities': capabilities,
    'observations': observations.map((o) => o.toJson()).toList(),
    'startedAt': startedAt.toUtc().toIso8601String(),
    'durationMicros': durationMicros,
    'platform': platform,
    'redacted': redacted,
    'provenance': 'participant_statement',
  };

  factory RunReport.fromJson(Object? value) {
    final map = jsonObject(value, 'report');
    onlyKeys(map, const {
      'format',
      'reportVersion',
      'protocolVersion',
      'appVersion',
      'sessionId',
      'runId',
      'reportingDeviceId',
      'sourceDeviceIds',
      'sourceRuns',
      'devices',
      'parameters',
      'capabilities',
      'observations',
      'startedAt',
      'durationMicros',
      'platform',
      'redacted',
      'provenance',
    });
    if (map['format'] != 'lanpair-report' ||
        map['reportVersion'] != reportVersion ||
        map['protocolVersion'] != protocolVersion ||
        map['provenance'] != 'participant_statement') {
      throw const FormatException(
        'Unsupported LANPair report or protocol version.',
      );
    }
    final devices = boundedList(
      map['devices'],
      'devices',
      max: 2,
    ).map(DeviceEndpoint.fromJson).toList();
    if (devices.length != 2 || devices[0].id == devices[1].id) {
      throw const FormatException(
        'A report must identify two different participants.',
      );
    }
    final ids = devices.map((d) => d.id).toSet();
    final reporter = identifier(map['reportingDeviceId'], 'reporter');
    final sources = boundedList(
      map['sourceDeviceIds'],
      'source devices',
      max: 2,
    ).map((v) => identifier(v, 'source device')).toList();
    if (!ids.contains(reporter) ||
        sources.isEmpty ||
        sources.toSet().length != sources.length ||
        !sources.every(ids.contains) ||
        !sources.contains(reporter)) {
      throw const FormatException(
        'Report source is not a session participant.',
      );
    }
    final sourceRuns = boundedList(
      map['sourceRuns'],
      'source runs',
      max: 2,
    ).map(SourceRun.fromJson).toList();
    if (sourceRuns.length != sources.length ||
        sourceRuns.map((s) => s.deviceId).toSet().length != sourceRuns.length ||
        !sourceRuns.every((s) => sources.contains(s.deviceId))) {
      throw const FormatException(
        'Source timing metadata does not match the participants.',
      );
    }
    final rawObservations = boundedList(
      map['observations'],
      'observations',
      max: maxObservations,
    ).map(Observation.fromJson).toList();
    final seen = <String, Observation>{};
    for (final observation in rawObservations) {
      if (!sources.contains(observation.reporterId) ||
          !ids.contains(observation.fromDeviceId) ||
          !ids.contains(observation.toDeviceId)) {
        throw const FormatException(
          'Observation identity or participant is invalid.',
        );
      }
      final old = seen[observation.id];
      if (old != null &&
          jsonEncode(old.toJson()) != jsonEncode(observation.toJson())) {
        throw const FormatException('Conflicting duplicate observation.');
      }
      seen[observation.id] = observation;
    }
    final observations = seen.values.toList();
    final capabilities = <String, String>{};
    final rawCapabilities = jsonObject(map['capabilities'], 'capabilities');
    if (rawCapabilities.length > 64) {
      throw const FormatException('Too many capabilities.');
    }
    for (final entry in rawCapabilities.entries) {
      final key = boundedString(entry.key, 'capability key', max: 128);
      final separator = key.indexOf('.');
      if (separator < 1 ||
          !sources.contains(key.substring(0, separator)) ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$')
              .hasMatch(key.substring(separator + 1))) {
        throw const FormatException(
          'Capability keys must identify their reporting participant.',
        );
      }
      if (RegExp(
        'secret|private|token|certificate',
        caseSensitive: false,
      ).hasMatch(key)) {
        throw const FormatException('Credentials are not report fields.');
      }
      capabilities[key] = boundedString(
        entry.value,
        'capability value',
        max: 80,
      );
    }
    if (map['redacted'] is! bool) {
      throw const FormatException('Invalid redaction marker.');
    }
    return RunReport(
      sessionId: identifier(map['sessionId'], 'session id'),
      runId: identifier(map['runId'], 'run id'),
      reportingDeviceId: reporter,
      devices: List.unmodifiable(devices),
      parameters: RunPlan.fromJson(map['parameters']),
      capabilities: Map.unmodifiable(capabilities),
      observations: List.unmodifiable(observations),
      startedAt: utcDate(map['startedAt']),
      durationMicros: boundedInt(
        map['durationMicros'],
        'duration',
        min: 0,
        max: 120000000,
      ),
      platform: boundedString(map['platform'], 'platform', max: 80),
      appVersion: boundedString(map['appVersion'], 'app version', max: 32),
      sourceDeviceIds: sources,
      sourceRuns: sourceRuns,
      redacted: map['redacted'] as bool,
    );
  }
}

Map<String, Object?> jsonObject(Object? value, String field) {
  if (value is! Map || !value.keys.every((key) => key is String)) {
    throw FormatException('Invalid $field object.');
  }
  return Map<String, Object?>.from(value);
}

void onlyKeys(Map<String, Object?> map, Set<String> keys) {
  if (map.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('Unexpected field.');
  }
}

String boundedString(
  Object? value,
  String field, {
  int max = 96,
  bool allowEmpty = false,
  bool allowControls = false,
}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.length > max ||
      !allowControls && value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw FormatException('Invalid $field.');
  }
  return value;
}

String identifier(Object? value, String field) {
  final id = boundedString(value, field);
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,96}$').hasMatch(id)) {
    throw FormatException('Invalid $field.');
  }
  return id;
}

String machineCode(Object? value) {
  final code = boundedString(value, 'observation code', max: 64);
  if (!RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(code)) {
    throw const FormatException('Invalid observation code.');
  }
  return code;
}

int boundedInt(
  Object? value,
  String field, {
  required int min,
  required int max,
}) {
  if (value is! int || value < min || value > max) {
    throw FormatException('Invalid $field.');
  }
  return value;
}

List<Object?> boundedList(Object? value, String field, {required int max}) {
  if (value is! List || value.length > max) {
    throw FormatException('Invalid $field.');
  }
  return List<Object?>.from(value);
}

T enumValue<T extends Enum>(List<T> values, Object? raw, String field) {
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw FormatException('Unknown $field.');
}

DateTime utcDate(Object? raw) {
  if (raw is! String || raw.length > 40 || !raw.endsWith('Z')) {
    throw const FormatException('Wall-clock time must be UTC.');
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw const FormatException('Invalid wall-clock time.');
  return parsed.toUtc();
}

Object? boundedJsonDecode(String text, {int maxBytes = maxImportBytes}) {
  // Check characters first, then UTF-8 bytes; both allocation and decoding are bounded.
  if (text.length > maxBytes || utf8.encode(text).length > maxBytes) {
    throw const FormatException('Import exceeds the size limit.');
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('Invalid JSON.');
  }
}
