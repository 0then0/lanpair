import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import 'control.dart';
import 'engine.dart';
import 'identity.dart';
import 'model.dart';
import 'platform_bridge.dart';
import 'report.dart';
import 'storage.dart';
import 'ui_contract.dart';

class AppController extends LanPairController with WidgetsBindingObserver {
  AppController({PlatformBridge? platform, this._store})
    : _platform = platform ?? PlatformBridge();
  final PlatformBridge _platform;
  ReportStore? _store;
  Session? _session;
  ControlLink? _control;
  ProbeEngine? _engine;
  RunReport? _report, _peerReport;
  List<RunReport> _history = [];
  List<NetworkInterface> _interfaces = [];
  Map<String, dynamic> _capabilities = {};
  String? _selected;
  String? _error;
  bool _busy = false, _running = false, _completed = false, _disposed = false;
  double _progress = 0;
  Timer? _networkPoll;
  StreamSubscription<Map<String, dynamic>>? _platformEvents;
  String _networkSignature = '';
  bool _checkingNetwork = false;
  bool _foreground = true;

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    _platformEvents = _platform.events.listen(
      (event) {
        if (event['type'] == 'permission') {
          final permission = event['permission'];
          if (permission is String) _capabilities['permission'] = permission;
          if (permission == 'denied') {
            _engine?.cancel(reason: ObservationKind.permissionDenied);
            _checkpoint();
          }
          _notify();
        } else if (event['type'] == 'networkChanged') {
          _engine?.cancel(reason: ObservationKind.networkChanged);
          _checkpoint();
          unawaited(_checkNetwork());
        }
      },
      onError: (Object _) {
        /* Native adapter is optional for direct probes. */
      },
    );
    await _guard(() async {
      _store ??= await ReportStore.open();
      _history = _store!.list();
      await _refresh(request: false);
    });
    _networkPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_checkNetwork()),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _guard(
    Future<void> Function() action, {
    String code = 'operationFailed',
  }) async {
    if (_busy || _running) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      await action();
    } catch (_) {
      _error = code;
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  bool get busy => _busy;
  @override
  bool get running => _running;
  @override
  bool get hasSession => _session != null;
  @override
  bool get canScan => Platform.isAndroid || Platform.isIOS;
  @override
  String? get sessionId => _session?.sessionId ?? _report?.sessionId;
  @override
  String? get runId => _session?.runId ?? _report?.runId;
  @override
  String get localRole {
    if (_session != null) return _session!.localRole.name.toUpperCase();
    final report = _report;
    return report == null || report.reportingDeviceId == report.devices.first.id
        ? 'A'
        : 'B';
  }

  @override
  String? get invitation =>
      _session?.localRole == DeviceRole.a ? _session!.invitation() : null;
  @override
  String? get errorCode => _error;
  @override
  String? get errorDetail => null;
  @override
  double get progress => _progress;
  @override
  String? get selectedInterface => _selected;
  @override
  List<InterfaceView> get interfaces => _interfaces
      .map(
        (i) => InterfaceView(
          name: i.name,
          addresses: i.addresses.map((a) => a.address).toList(),
        ),
      )
      .toList();
  @override
  List<ReadinessView> get readiness => [
    ReadinessView(
      code: 'networkPermission',
      status: switch (_capabilities['permission']) {
        'denied' => 'permissionDenied',
        'granted' || 'notRequired' => 'passed',
        _ => 'inconclusive',
      },
    ),
    ReadinessView(
      code: 'interface',
      status: _selected == null ? 'inconclusive' : 'passed',
      detail: _selected,
    ),
    ReadinessView(
      code: 'multicast',
      status: _capabilities['rawMulticast'] == true ? 'passed' : 'unsupported',
      detail: (_capabilities['limitationCodes'] as List?)
          ?.map(
            (c) => c == 'ios_multicast_entitlement_missing'
                ? 'multicast_entitlement_missing'
                : c,
          )
          .join(', '),
    ),
    ReadinessView(
      code: 'discovery',
      status: _capabilities['discovery'] == true ? 'passed' : 'unsupported',
    ),
    const ReadinessView(code: 'foreground', status: 'passed'),
  ];
  @override
  List<ResultView> get results {
    final report = _report;
    if (report == null) return [];
    return _resultViews(report);
  }

  List<ResultView> _resultViews(RunReport report) {
    String role(String id) => id == report.devices.first.id ? 'A' : 'B';
    return interpret(report)
        .map(
          (r) => ResultView(
            id: '${r.check.name}/${r.family.name}/${r.fromDeviceId}',
            kind: r.check == CheckKind.dnsSd ? 'dnssd' : r.check.name,
            family: r.family.name,
            direction: '${role(r.fromDeviceId)} → ${role(r.toDeviceId)}',
            status: r.outcome.name,
            reason: r.reason,
            observations: report.observations
                .where(
                  (o) =>
                      o.check == r.check &&
                      o.family == r.family &&
                      o.fromDeviceId == r.fromDeviceId &&
                      o.toDeviceId == r.toDeviceId,
                )
                .map(
                  (o) => ObservationView(
                    code: o.kind.name,
                    device: role(o.reporterId),
                    elapsedMs: o.elapsedMicros ~/ 1000,
                    sequence: o.sequence,
                    detail: o.code,
                    wallTime: o.wallTime.toIso8601String(),
                    interfaceName: o.interfaceName,
                    id: o.id,
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  List<ReportFieldView> _reportFields(RunReport report) {
    return [
      ReportFieldView(label: 'appVersion', value: report.appVersion),
      ReportFieldView(label: 'protocolVersion', value: '$protocolVersion'),
      ReportFieldView(label: 'reportVersion', value: '$reportVersion'),
      ReportFieldView(label: 'platform', value: report.platform),
      ReportFieldView(
        label: 'parameters',
        value: jsonEncode(report.parameters.toJson()),
      ),
      ReportFieldView(
        label: 'capabilities',
        value: jsonEncode(report.capabilities),
      ),
      for (final source in report.sourceRuns) ...[
        ReportFieldView(label: 'sourceDevice', value: source.deviceId),
        ReportFieldView(
          label: 'wallClock',
          value: source.startedAt.toIso8601String(),
        ),
        ReportFieldView(
          label: 'monotonicDuration',
          value: '${source.durationMicros} µs',
        ),
      ],
    ];
  }

  @override
  List<HistoryView> get history => _history
      .map(
        (r) => HistoryView(
          id: reportStorageKey(r),
          sessionId: r.sessionId,
          runId: r.runId,
          savedAt: r.startedAt.toLocal(),
          observationCount: r.observations.length,
          merged: r.sourceDeviceIds.length > 1,
        ),
      )
      .toList();
  @override
  List<String> get exportAddresses =>
      _report == null ? [] : _addresses(_report!);

  List<String> _addresses(RunReport report) => report.devices
      .expand(
        (d) => [
          d.address,
          if (d.ipv6Address != null) d.ipv6Address!,
          if (d.interfaceName.isNotEmpty) d.interfaceName,
        ],
      )
      .where((a) => a.isNotEmpty)
      .toSet()
      .toList();
  @override
  bool get peerJournalPresent => (_report?.sourceDeviceIds.length ?? 0) > 1;

  Future<void> _refresh({required bool request}) async {
    _capabilities = await _platform.capabilities(request: request);
    _interfaces = await NetworkInterface.list(includeLinkLocal: true);
    _interfaces.removeWhere((i) => i.addresses.every((a) => a.isLoopback));
    if (!_interfaces.any((i) => i.name == _selected)) {
      _selected = _interfaces.firstOrNull?.name;
    }
    _networkSignature = _signature(_interfaces);
  }

  DeviceEndpoint _localEndpoint(String id) {
    final network = _interfaces.where((i) => i.name == _selected).firstOrNull;
    if (network == null) throw StateError('noInterface');
    final v4 =
        network.addresses
            .where((a) => a.type == InternetAddressType.IPv4)
            .firstOrNull
            ?.address ??
        '';
    final v6 = network.addresses
        .where((a) => a.type == InternetAddressType.IPv6)
        .firstOrNull
        ?.address;
    return DeviceEndpoint(
      id: id,
      address: v4.isNotEmpty ? v4 : v6 ?? '',
      ipv6Address: v6,
      interfaceName: network.name,
      interfaceIndex: network.index,
    );
  }

  @override
  Future<void> createSession() => _guard(() async {
    await _stopSession();
    await _refresh(request: true);
    if (_selected == null) {
      _error = 'noInterface';
      return;
    }
    final a = _localEndpoint(randomId());
    final identities = await Future.wait([createIdentity(), createIdentity()]);
    _session = Session.create(
      a: a,
      b: DeviceEndpoint(id: randomId(), address: ''),
      aIdentity: identities[0],
      bIdentity: identities[1],
    );
    _report = null;
    _peerReport = null;
    _completed = false;
    _progress = 0;
    await _openControl();
  });
  @override
  Future<void> joinSession(String invitation) => _guard(() async {
    final session = Session.fromInvitation(invitation.trim());
    if (certificateFingerprint(session.peerCertificatePem) !=
            session.peerFingerprint ||
        certificateFingerprint(session.localIdentity.certificatePem) !=
            session.localIdentity.fingerprint) {
      throw const FormatException('Certificate pin mismatch.');
    }
    await _stopSession();
    await _refresh(request: true);
    if (_selected == null) {
      _error = 'noInterface';
      return;
    }
    _session = session.withEndpoint(DeviceRole.b, _localEndpoint(session.b.id));
    final recorded = _history
        .where(
          (r) => r.sessionId == session.sessionId && r.runId == session.runId,
        )
        .firstOrNull;
    _report = recorded;
    _peerReport = recorded;
    _completed = recorded?.sourceDeviceIds.contains(session.local.id) ?? false;
    _progress = 0;
    await _openControl();
    try {
      final peer = DeviceEndpoint.fromJson(
        jsonDecode(
          await _control!.post(
            '/hello',
            fields: {'endpoint': _session!.local.toJson()},
          ),
        ),
      );
      if (peer.id == _session!.peer.id) {
        _session = _session!.withEndpoint(DeviceRole.a, peer);
      }
      _control!.session = _session!;
    } catch (_) {
      _error = 'controlUnavailable';
    }
  }, code: 'invalidInvitation');

  Future<void> _openControl() async {
    final session = _session!;
    _control = ControlLink(
      session: session,
      onHello: (endpoint) async {
        if (_running || _completed) return;
        _session = _session!.withEndpoint(
          _session!.localRole == DeviceRole.a ? DeviceRole.b : DeviceRole.a,
          endpoint,
        );
        _control!.session = _session!;
        _notify();
      },
      onStart: () async {
        if (_running || _completed || _busy) return;
        final ready = Completer<void>();
        unawaited(_run(notifyPeer: false, ready: ready));
        await ready.future.timeout(const Duration(seconds: 2));
      },
      onReport: (text) async {
        final incoming = ReportCodec.decode(text);
        validateSessionReport(_session!, incoming);
        _peerReport = incoming;
        if (_report != null && !_running) {
          _report = ReportCodec.merge(_report!, incoming);
          _save();
          _notify();
        }
      },
    );
    try {
      if (_capabilities['permission'] != 'denied') await _control!.open();
    } catch (_) {
      _error = 'controlUnavailable';
    }
  }

  @override
  Future<void> setManualPeer(String host, int port) => _guard(() async {
    if (_session == null || _running || _completed) return;
    var address = host.trim();
    if (address.startsWith('[') && address.endsWith(']')) {
      address = address.substring(1, address.length - 1);
    }
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null ||
        parsed.isMulticast ||
        parsed.address == '0.0.0.0' ||
        parsed.address == '::' ||
        port < 1024 ||
        port > 65535) {
      throw const FormatException('Invalid peer address.');
    }
    final peer = _session!.peer.copyWith(
      address: address,
      ipv6Address: parsed.type == InternetAddressType.IPv6 ? address : null,
      tcpPort: port,
    );
    _session = _session!.withEndpoint(
      _session!.localRole == DeviceRole.a ? DeviceRole.b : DeviceRole.a,
      peer,
    );
    _control?.session = _session!;
  }, code: 'invalidAddress');
  @override
  Future<void> selectInterface(String name) => _guard(() async {
    if (_running || _completed || !_interfaces.any((i) => i.name == name)) {
      return;
    }
    _selected = name;
    if (_session != null) {
      await _control?.close();
      _session = _session!.withEndpoint(
        _session!.localRole,
        _localEndpoint(_session!.local.id),
      );
      await _openControl();
    }
  });
  @override
  Future<void> refreshReadiness() => _guard(() async {
    await _refresh(request: true);
    if (_session != null && !_completed) {
      await _control?.close();
      _session = _session!.withEndpoint(
        _session!.localRole,
        _localEndpoint(_session!.local.id),
      );
      await _openControl();
    }
  });
  @override
  Future<void> openSettings() => _guard(_platform.settings);
  @override
  Future<void> startRun() async {
    if (_session == null) {
      _error = 'sessionRequired';
      _notify();
      return;
    }
    if (_completed) {
      _error = 'runAlreadyCompleted';
      _notify();
      return;
    }
    if (_busy || _running) return;
    await _run(notifyPeer: true);
  }

  Future<void> _run({required bool notifyPeer, Completer<void>? ready}) async {
    if (_session == null || _running || _completed) return;
    _running = true;
    _error = null;
    _progress = 0;
    _notify();
    try {
      final engine = ProbeEngine(
        session: _session!,
        platform: _platform,
        capabilities: _capabilities,
        onProgress: (p) {
          _progress = p;
          _notify();
        },
      );
      _engine = engine;
      _report = await engine.run(
        onReady: () async {
          if (ready != null && !ready.isCompleted) ready.complete();
          if (notifyPeer) {
            try {
              await _control?.post('/start');
            } catch (_) {
              /* Independent run remains useful. */
            }
          }
        },
      );
      if (_peerReport != null) {
        _report = ReportCodec.merge(_report!, _peerReport!);
      }
      _save();
      try {
        if (_foreground) {
          await _control?.post(
            '/report',
            fields: {'report': _report!.toJson()},
          );
        }
      } catch (_) {
        /* Manual export/merge is always available. */
      }
    } catch (_) {
      _error = 'operationFailed';
    } finally {
      if (ready != null && !ready.isCompleted) ready.complete();
      _engine = null;
      _running = false;
      _completed = true;
      _notify();
    }
  }

  void _checkpoint() {
    final engine = _engine;
    if (engine == null) return;
    var snapshot = engine.snapshot;
    try {
      if (_peerReport != null) {
        snapshot = ReportCodec.merge(snapshot, _peerReport!);
      }
    } on FormatException {
      _error = 'importFailed';
    }
    _report = snapshot;
    _save();
  }

  void _save() {
    if (_report != null) {
      try {
        _store?.save(_report!);
        _history = _store?.list() ?? [];
      } on FileSystemException {
        // Keep the in-memory journal available for an explicit export.
        _error = 'operationFailed';
      } on FormatException {
        _error = 'operationFailed';
      }
    }
  }

  @override
  Future<void> cancelRun() async {
    _engine?.cancel();
  }

  @override
  Future<void> importInvitation() =>
      _importText(joinSession, 'invalidInvitation');
  @override
  Future<void> importReport() => _importText(importJournal, 'importFailed');

  Future<void> importJournal(String text) => _guard(() async {
    final incoming = ReportCodec.decode(text);
    if (_session != null) validateSessionReport(_session!, incoming);
    final stored = _history
        .where((r) => reportStorageKey(r) == reportStorageKey(incoming))
        .firstOrNull;
    final current = _report;
    final baseline =
        current != null &&
            reportStorageKey(current) == reportStorageKey(incoming)
        ? current
        : stored;
    final merged = baseline == null
        ? incoming
        : ReportCodec.merge(baseline, incoming);
    if (_session != null) {
      _peerReport = _peerReport == null
          ? merged
          : ReportCodec.merge(_peerReport!, merged);
      if (merged.sourceDeviceIds.contains(_session!.local.id)) {
        _completed = true;
      }
    }
    _report = merged;
    _save();
  }, code: 'importFailed');

  Future<void> _importText(
    Future<void> Function(String) consumer,
    String code,
  ) async {
    if (_busy || _running) return;
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'LANPair',
            extensions: ['json', 'lanpair', 'txt'],
            uniformTypeIdentifiers: ['public.data'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > maxImportBytes) {
        throw const FormatException('Import too large.');
      }
      await consumer(
        await readBounded(
          file.openRead(),
          limit: maxImportBytes,
          timeout: const Duration(seconds: 3),
        ),
      );
    } catch (_) {
      _error = code;
      _notify();
    }
  }

  @override
  Future<void> saveInvitation() => _guard(() async {
    if (invitation != null) {
      await _export(invitation!, 'lanpair-invitation.lanpair');
    }
  }, code: 'exportFailed');
  @override
  Future<void> exportReport({
    required bool redact,
    required bool humanReadable,
    String Function(ReportExportView report)? formatReadableReport,
  }) => _guard(() async {
    if (_report == null) return;
    final report = redact ? ReportCodec.redact(_report!) : _report!;
    if (humanReadable && formatReadableReport == null) {
      throw ArgumentError('A readable report formatter is required.');
    }
    final text = humanReadable
        ? formatReadableReport!(
            ReportExportView(
              fields: _reportFields(report),
              addresses: _addresses(report),
              results: _resultViews(report),
              redacted: report.redacted,
            ),
          )
        : ReportCodec.encode(report);
    await _export(
      text,
      'lanpair-${report.runId}.${humanReadable ? 'txt' : 'json'}',
    );
  }, code: 'exportFailed');
  Future<void> _export(String text, String name) async {
    final file = XFile.fromData(
      utf8.encode(text),
      mimeType: name.endsWith('.json') ? 'application/json' : 'text/plain',
      name: name,
    );
    if (Platform.isAndroid || Platform.isIOS) {
      await SharePlus.instance.share(
        ShareParams(files: [file], fileNameOverrides: [name]),
      );
    } else {
      final location = await getSaveLocation(suggestedName: name);
      if (location != null) await file.saveTo(location.path);
    }
  }

  @override
  Future<void> openHistory(String id) => _guard(() async {
    if (_running) return;
    await _stopSession();
    _session = null;
    _report = _history.where((r) => reportStorageKey(r) == id).firstOrNull;
  });
  @override
  void clearError() {
    _error = null;
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _foreground = false;
      _engine?.cancel(reason: ObservationKind.suspended);
      _checkpoint();
      unawaited(_control?.close());
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;
      unawaited(
        _guard(() async {
          await _refresh(request: false);
          if (_session != null && !_running && !_completed) {
            await _openControl();
          }
        }),
      );
    }
  }

  Future<void> _checkNetwork() async {
    if (_checkingNetwork || _disposed) return;
    _checkingNetwork = true;
    try {
      final networks = await NetworkInterface.list(includeLinkLocal: true);
      networks.removeWhere((i) => i.addresses.every((a) => a.isLoopback));
      if (_signature(networks) != _networkSignature) {
        _engine?.cancel(reason: ObservationKind.networkChanged);
        _checkpoint();
        await _control?.close();
        _interfaces = networks;
        _networkSignature = _signature(networks);
        _error = 'networkChanged';
        _notify();
      }
    } catch (_) {
      /* Retry on next bounded poll. */
    } finally {
      _checkingNetwork = false;
    }
  }

  String _signature(List<NetworkInterface> networks) {
    final values =
        networks
            .expand(
              (i) =>
                  i.addresses.map((a) => '${i.index}/${i.name}/${a.address}'),
            )
            .toList()
          ..sort();
    return values.join('|');
  }

  Future<void> _stopSession() async {
    _engine?.cancel();
    await _control?.close();
    _control = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _networkPoll?.cancel();
    unawaited(_platformEvents?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopSession());
    super.dispose();
  }
}
