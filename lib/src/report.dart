import 'dart:convert';

import 'model.dart';

class CheckResult {
  const CheckResult({
    required this.check,
    required this.family,
    required this.fromDeviceId,
    required this.toDeviceId,
    required this.outcome,
    required this.reason,
    required this.evidenceIds,
  });
  final CheckKind check;
  final IpFamily family;
  final String fromDeviceId;
  final String toDeviceId;
  final Outcome outcome;

  Map<String, Object?> toJson() => {
    'check': check.name,
    'family': family.name,
    'fromDeviceId': fromDeviceId,
    'toDeviceId': toDeviceId,
    'outcome': outcome.name,
    'reason': reason,
    'evidenceIds': evidenceIds,
  };

  /// Stable localization key. A reason describes observations, never a root cause.
  final String reason;
  final List<String> evidenceIds;
}

List<CheckResult> interpret(RunReport report) {
  if (report.devices.length != 2) {
    throw const FormatException('Two participants are required.');
  }
  final results = <CheckResult>[];
  for (var direction = 0; direction < 2; direction++) {
    final from = report.devices[direction];
    final to = report.devices[1 - direction];
    for (final check in CheckKind.values) {
      final families = check == CheckKind.dnsSd
          ? [IpFamily.system]
          : [IpFamily.ipv4, IpFamily.ipv6];
      for (final family in families) {
        final observations = report.observations
            .where(
              (o) =>
                  o.check == check &&
                  o.family == family &&
                  o.fromDeviceId == from.id &&
                  o.toDeviceId == to.id,
            )
            .toList();
        final timely = observations
            .where(
              (o) => o.elapsedMicros <= report.parameters.durationMs * 1000,
            )
            .toList();
        final success = timely
            .where(
              (o) => switch (check) {
                CheckKind.tcp =>
                  o.kind == ObservationKind.connected &&
                      o.reporterId == from.id,
                CheckKind.udp =>
                  o.kind == ObservationKind.received && o.reporterId == to.id ||
                      o.kind == ObservationKind.acknowledged &&
                          o.reporterId == from.id,
                CheckKind.multicast =>
                  o.kind == ObservationKind.received &&
                      o.reporterId == to.id &&
                      from.id != to.id,
                CheckKind.dnsSd =>
                  o.kind == ObservationKind.resolved && o.reporterId == to.id,
              },
            )
            .toList();
        Outcome outcome;
        String reason;
        List<Observation> evidence;
        if (success.isNotEmpty) {
          outcome = Outcome.passed;
          evidence = success;
          reason = switch (check) {
            CheckKind.tcp => 'tcp_connected',
            CheckKind.udp
                when success.any((o) => o.kind == ObservationKind.received) =>
              'peer_received',
            CheckKind.udp => 'acknowledgement_received',
            CheckKind.multicast => 'peer_received',
            CheckKind.dnsSd => 'service_resolved',
          };
        } else {
          final permission = observations
              .where((o) => o.kind == ObservationKind.permissionDenied)
              .toList();
          final unsupported = observations
              .where(
                (o) =>
                    o.kind == ObservationKind.unsupported &&
                    o.code != 'peer_address_unavailable',
              )
              .toList();
          final peerUnconfigured = observations
              .where(
                (o) =>
                    o.kind == ObservationKind.unsupported &&
                    o.code == 'peer_address_unavailable',
              )
              .toList();
          final interruption = observations
              .where(
                (o) =>
                    o.kind == ObservationKind.suspended ||
                    o.kind == ObservationKind.networkChanged,
              )
              .toList();
          final cancelled = observations
              .where((o) => o.kind == ObservationKind.cancelled)
              .toList();
          final errors = observations
              .where((o) => o.kind == ObservationKind.error)
              .toList();
          final timeouts = observations
              .where((o) => o.kind == ObservationKind.timedOut)
              .toList();
          final sends = timely
              .where((o) => o.kind == ObservationKind.sent)
              .toList();
          if (permission.isNotEmpty) {
            outcome = Outcome.permissionDenied;
            reason = 'permission_denied';
            evidence = permission;
          } else if (unsupported.isNotEmpty ||
              family == IpFamily.ipv6 &&
                  ((from.ipv6Address ?? '').isEmpty ||
                      (to.ipv6Address ?? '').isEmpty)) {
            outcome = Outcome.unsupported;
            reason = 'platform_unsupported';
            evidence = unsupported;
          } else if (interruption.isNotEmpty) {
            outcome = Outcome.inconclusive;
            reason = 'run_interrupted';
            evidence = interruption;
          } else if (cancelled.isNotEmpty) {
            outcome = Outcome.cancelled;
            reason = 'run_cancelled';
            evidence = cancelled;
          } else if (errors.isNotEmpty) {
            outcome = Outcome.failed;
            reason = 'probe_error';
            evidence = errors;
          } else if (peerUnconfigured.isNotEmpty) {
            outcome = Outcome.inconclusive;
            reason = 'missing_observations';
            evidence = peerUnconfigured;
          } else if (sends.isNotEmpty &&
              (check == CheckKind.udp || check == CheckKind.multicast)) {
            outcome = Outcome.inconclusive;
            reason = 'sent_delivery_unknown';
            evidence = [...sends, ...timeouts];
          } else if (timeouts.isNotEmpty) {
            outcome = check == CheckKind.tcp
                ? Outcome.failed
                : Outcome.inconclusive;
            reason = 'timeout_observed';
            evidence = timeouts;
          } else {
            outcome = Outcome.inconclusive;
            reason = report.sourceDeviceIds.contains(to.id)
                ? 'missing_observations'
                : 'peer_observation_missing';
            evidence = observations;
          }
        }
        results.add(
          CheckResult(
            check: check,
            family: family,
            fromDeviceId: from.id,
            toDeviceId: to.id,
            outcome: outcome,
            reason: reason,
            evidenceIds: List.unmodifiable(evidence.map((o) => o.id)),
          ),
        );
      }
    }
  }
  return List.unmodifiable(results);
}

class ReportCodec {
  static String encode(RunReport report, {bool pretty = true}) {
    final text =
        (pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder())
            .convert({...report.toJson(), 'interpretation': _analysis(report)});
    if (utf8.encode(text).length > maxImportBytes) {
      throw const FormatException('Report exceeds the export size limit.');
    }
    return text;
  }

  static Map<String, Object?> _analysis(RunReport report) => {
    'version': 1,
    'results': interpret(report).map((r) => r.toJson()).toList(),
  };

  static RunReport decode(String text) {
    final data = jsonObject(boundedJsonDecode(text), 'report');
    final hasAnalysis = data.containsKey('interpretation');
    final analysis = data.remove('interpretation');
    final report = RunReport.fromJson(data);
    if (hasAnalysis) {
      final envelope = jsonObject(analysis, 'interpretation');
      onlyKeys(envelope, {'version', 'results'});
      if (envelope['version'] != 1) {
        throw const FormatException('Unsupported interpretation version.');
      }
      final normalized =
          boundedList(envelope['results'], 'interpretations', max: 14).map((
            value,
          ) {
            final entry = jsonObject(value, 'interpretation result');
            onlyKeys(entry, {
              'check',
              'family',
              'fromDeviceId',
              'toDeviceId',
              'outcome',
              'reason',
              'evidenceIds',
            });
            return {
              'check': enumValue(
                CheckKind.values,
                entry['check'],
                'check',
              ).name,
              'family': enumValue(
                IpFamily.values,
                entry['family'],
                'family',
              ).name,
              'fromDeviceId': identifier(entry['fromDeviceId'], 'sender'),
              'toDeviceId': identifier(entry['toDeviceId'], 'receiver'),
              'outcome': enumValue(
                Outcome.values,
                entry['outcome'],
                'outcome',
              ).name,
              'reason': machineCode(entry['reason']),
              'evidenceIds': boundedList(
                entry['evidenceIds'],
                'evidence',
                max: maxObservations,
              ).map((id) => identifier(id, 'evidence id')).toList(),
            };
          }).toList();
      if (jsonEncode({'version': 1, 'results': normalized}) !=
          jsonEncode(_analysis(report))) {
        throw const FormatException(
          'Interpretation does not match the supplied observations.',
        );
      }
    }
    return report;
  }

  static RunReport merge(RunReport a, RunReport b) {
    if (a.sessionId != b.sessionId ||
        a.runId != b.runId ||
        !a.parameters.sameAs(b.parameters) ||
        a.redacted != b.redacted) {
      throw const FormatException(
        'Reports do not describe the same compatible run.',
      );
    }
    if (a.devices.length != 2 ||
        b.devices.length != 2 ||
        a.devices[0].id != b.devices[0].id ||
        a.devices[1].id != b.devices[1].id) {
      throw const FormatException(
        'Reports do not identify the same ordered participants.',
      );
    }
    final events = <String, Observation>{};
    for (final event in [...a.observations, ...b.observations]) {
      final old = events[event.id];
      if (old != null &&
          jsonEncode(old.toJson()) != jsonEncode(event.toJson())) {
        throw const FormatException('Conflicting duplicate observation.');
      }
      events[event.id] = event;
    }
    if (events.length > maxObservations) {
      throw const FormatException('Merged report exceeds the event limit.');
    }
    final sources = <String, SourceRun>{};
    for (final source in [...a.sourceRuns, ...b.sourceRuns]) {
      final old = sources[source.deviceId];
      if (old != null &&
          (old.startedAt != source.startedAt ||
              old.platform != source.platform ||
              old.appVersion != source.appVersion)) {
        throw const FormatException(
          'Conflicting metadata for one participant run.',
        );
      }
      if (old == null || source.durationMicros > old.durationMicros) {
        sources[source.deviceId] = source;
      }
    }
    final capabilities = <String, String>{...a.capabilities};
    for (final entry in b.capabilities.entries) {
      if (capabilities.containsKey(entry.key) &&
          capabilities[entry.key] != entry.value) {
        throw const FormatException('Conflicting capability statements.');
      }
      capabilities[entry.key] = entry.value;
    }
    final devices = List<DeviceEndpoint>.generate(2, (index) {
      final left = a.devices[index];
      final right = b.devices[index];
      // Prefer each participant's own endpoint statement. Addresses are not run identity.
      if (b.reportingDeviceId == right.id) return right;
      if (a.reportingDeviceId == left.id) return left;
      return left.address.isEmpty ? right : left;
    });
    return RunReport(
      sessionId: a.sessionId,
      runId: a.runId,
      reportingDeviceId: a.reportingDeviceId,
      devices: devices,
      parameters: a.parameters,
      capabilities: capabilities,
      observations: events.values.toList(),
      startedAt: a.startedAt,
      durationMicros: a.durationMicros,
      platform: a.platform,
      appVersion: a.appVersion,
      sourceDeviceIds: sources.keys.toList()..sort(),
      sourceRuns: sources.values.toList(),
      redacted: a.redacted,
    );
  }

  /// Removes addresses, interface names and wall-clock timestamps. Stable IDs keep
  /// directions and sequence correlation usable without exposing device addresses.
  static RunReport redact(RunReport report) {
    final addresses = <String, String>{};
    final devices = <DeviceEndpoint>[];
    final interfaces = <String, String>{};
    for (var i = 0; i < report.devices.length; i++) {
      final device = report.devices[i];
      final label = i == 0 ? 'a' : 'b';
      final address = device.address.isEmpty
          ? ''
          : addresses.putIfAbsent(device.address, () => 'device-$label-ipv4');
      final v6 = (device.ipv6Address ?? '').isEmpty
          ? null
          : addresses.putIfAbsent(
              device.ipv6Address!,
              () => 'device-$label-ipv6',
            );
      interfaces[device.id] = 'interface-$label';
      devices.add(
        DeviceEndpoint(
          id: device.id,
          address: address,
          ipv6Address: v6,
          interfaceName: 'interface-$label',
          tcpPort: device.tcpPort,
          udpPort: device.udpPort,
          controlPort: device.controlPort,
        ),
      );
    }
    final epoch = DateTime.utc(1970);
    const categorical = {
      'granted',
      'denied',
      'notRequired',
      'unknown',
      'system_selected',
      'selected',
      'available',
      'unsupported',
      'notDetermined',
      'restricted',
      'redacted',
    };
    return RunReport(
      sessionId: report.sessionId,
      runId: report.runId,
      reportingDeviceId: report.reportingDeviceId,
      devices: devices,
      parameters: report.parameters,
      capabilities: report.capabilities.map(
        (key, value) =>
            MapEntry(key, categorical.contains(value) ? value : 'redacted'),
      ),
      observations: report.observations
          .map(
            (o) => Observation(
              id: o.id,
              reporterId: o.reporterId,
              kind: o.kind,
              check: o.check,
              fromDeviceId: o.fromDeviceId,
              toDeviceId: o.toDeviceId,
              family: o.family,
              elapsedMicros: o.elapsedMicros,
              wallTime: epoch,
              sequence: o.sequence,
              code: o.code,
              interfaceName: o.interfaceName == null
                  ? null
                  : interfaces[o.reporterId],
            ),
          )
          .toList(),
      startedAt: epoch,
      durationMicros: report.durationMicros,
      platform: report.platform,
      appVersion: report.appVersion,
      sourceDeviceIds: report.sourceDeviceIds,
      sourceRuns: report.sourceRuns
          .map(
            (s) => SourceRun(
              deviceId: s.deviceId,
              platform: s.platform,
              appVersion: s.appVersion,
              startedAt: epoch,
              durationMicros: s.durationMicros,
            ),
          )
          .toList(),
      redacted: true,
    );
  }
}

/// The first imported journal must match the accepted invitation even when no
/// local run has finished yet. Endpoint addresses may be corrected independently.
void validateSessionReport(Session session, RunReport report) {
  if (report.sessionId != session.sessionId ||
      report.runId != session.runId ||
      !report.parameters.sameAs(session.plan) ||
      report.devices.length != 2 ||
      report.devices[0].id != session.a.id ||
      report.devices[1].id != session.b.id) {
    throw const FormatException('Journal does not match the accepted run.');
  }
}
