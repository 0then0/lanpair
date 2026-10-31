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

/// A local network interface as the controller sees it. Production code maps
/// [NetworkInterface]; tests inject their own list.
class LocalInterface {
  const LocalInterface({
    required this.name,
    required this.index,
    required this.addresses,
  });
  factory LocalInterface.from(NetworkInterface value) => LocalInterface(
    name: value.name,
    index: value.index,
    addresses: value.addresses,
  );
  final String name;
  final int index;
  final List<InternetAddress> addresses;
}

/// Virtual and tunnel adapters are never picked by list order when the user
/// has not chosen one. An explicit choice is always honored.
bool _isTunnel(String name) => RegExp(
  r'^(utun|ipsec|tun|tap|ppp|wg|gif|stf)\d*$',
  caseSensitive: false,
).hasMatch(name);

/// Attempts of one endpoint exchange. Only transport failures are retried.
const _syncAttempts = 2;

class AppController extends LanPairController with WidgetsBindingObserver {
  AppController({
    PlatformBridge? platform,
    this._store,
    @visibleForTesting this.interfaceLister,
    @visibleForTesting this.controlPort,
  }) : _platform = platform ?? PlatformBridge();
  final PlatformBridge _platform;

  /// Test seams: a fixed interface list (which may include loopback) and a
  /// control port other than the default.
  final Future<List<LocalInterface>> Function()? interfaceLister;
  final int? controlPort;
  ReportStore? _store;
  Session? _session;
  ControlLink? _control;
  ProbeEngine? _engine;
  RunReport? _report, _peerReport;
  List<RunReport> _history = [];
  List<LocalInterface> _interfaces = [];
  Map<String, dynamic> _capabilities = {};

  /// The interface in effect, and the one the user chose explicitly. An
  /// explicit choice is never replaced by another interface when it
  /// disappears; it is restored when it returns.
  String? _selected, _preferred;

  // Endpoint synchronization. Every participant numbers its own endpoint from
  // 1 and increases the number with each change. A peer confirms a revision
  // only by acknowledging it through the authenticated control channel.
  int _localRevision = 1, _peerRevision = 0, _ackedRevision = 0;
  int _generation = 0, _peerGeneration = 0;
  int _epoch = 0, _receiptPushRevision = 0;
  int? _syncingEpoch;
  String? _syncFailure;
  bool _startVerified = false;
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

  // Returns to the foreground are handled one after another.
  Future<void> _resumeChain = Future<void>.value();

  /// Completes when queued lifecycle work and control listener changes ended.
  @visibleForTesting
  Future<void> get settled async {
    Future<void> resumes, controls, syncs;
    do {
      resumes = _resumeChain;
      controls = _controlQueue;
      syncs = _syncChain;
      await resumes;
      await controls;
      await syncs;
    } while (!identical(resumes, _resumeChain) ||
        !identical(controls, _controlQueue) ||
        !identical(syncs, _syncChain));
  }

  /// The session and listener state the tests assert on.
  @visibleForTesting
  Session? get debugSession => _session;
  @visibleForTesting
  ControlLink? get debugControl => _control;
  @visibleForTesting
  int get debugLocalRevision => _localRevision;
  @visibleForTesting
  int get debugPeerRevision => _peerRevision;
  @visibleForTesting
  RunReport? get debugReport => _report;
  @visibleForTesting
  int get debugGeneration => _generation;

  /// Runs one network poll now, after any poll already in progress.
  @visibleForTesting
  Future<void> debugCheckNetwork() async {
    while (_checkingNetwork) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await _checkNetwork();
  }

  /// Endpoint requests sent so far, to check that an exchange is bounded.
  @visibleForTesting
  int debugPushes = 0;

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
      detail:
          _selected ?? (_preferred == null ? null : 'interface_unavailable'),
    ),
    if (_syncView.status != 'none')
      ReadinessView(
        code: 'peerEndpoint',
        status: switch (_syncView.status) {
          'confirmed' => 'passed',
          'pending' => 'pending',
          _ => 'inconclusive',
        },
        detail: _syncView.reason,
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

  /// Whether the participants' journals agree on each other's endpoint:
  /// `differs` when either one used parameters the other did not, `matches`
  /// when every comparison agrees, `not_compared` for a single journal or
  /// journals that cannot be compared.
  String _endpointComparison(RunReport report) {
    final views = report.capabilities.entries
        .where((e) => e.key.endsWith('.peerEndpoint'))
        .map((e) => e.value)
        .toSet();
    if (views.contains('differs')) return 'differs';
    return views.contains('matches') ? 'matches' : 'not_compared';
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
      ReportFieldView(
        label: 'endpointParameters',
        value: _endpointComparison(report),
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
  @override
  String get peerSync => _syncView.status;
  @override
  String? get peerSyncReason => _syncView.reason;
  @override
  bool get endpointMismatch =>
      _report?.capabilities.entries.any(
        (e) => e.key.endsWith('.peerEndpoint') && e.value == 'differs',
      ) ??
      false;

  /// What this device can say about the peer's knowledge of the current
  /// endpoints. `confirmed` needs the peer's acknowledgement of this device's
  /// current revision, a received peer endpoint and an open listener.
  ({String status, String? reason}) get _syncView {
    final session = _session;
    if (session == null || _completed) return (status: 'none', reason: null);
    if (_selected == null) {
      return (status: 'unconfirmed', reason: 'interface_unavailable');
    }
    if (_control?.isOpen != true) {
      return (status: 'unconfirmed', reason: 'control_unavailable');
    }
    if (_ackedRevision == _localRevision && _peerRevision > 0) {
      return (status: 'confirmed', reason: 'confirmed');
    }
    if (_syncingEpoch == _epoch) return (status: 'pending', reason: 'syncing');
    if (_syncFailure != null) {
      return (status: 'unconfirmed', reason: _syncFailure);
    }
    if (_peerRevision == 0 && session.peer.address.isEmpty) {
      return (status: 'pending', reason: 'awaiting_peer');
    }
    return (status: 'pending', reason: 'endpoint_pending');
  }

  Future<void> _refresh({required bool request}) async {
    _capabilities = await _platform.capabilities(request: request);
    _interfaces = await _listInterfaces();
    _selected = _chooseInterface();
    _networkSignature = _signature(_interfaces);
  }

  /// The explicit choice while it exists, else nothing: another interface is
  /// never substituted silently. Without a choice, the current automatic
  /// selection stays while available, otherwise the first non-tunnel one.
  String? _chooseInterface() {
    bool exists(String? name) => _interfaces.any((i) => i.name == name);
    final preferred = _preferred;
    if (preferred != null) return exists(preferred) ? preferred : null;
    if (exists(_selected)) return _selected;
    return (_interfaces.where((i) => !_isTunnel(i.name)).firstOrNull ??
            _interfaces.firstOrNull)
        ?.name;
  }

  Future<List<LocalInterface>> _listInterfaces() async {
    if (interfaceLister != null) return interfaceLister!();
    final networks = await NetworkInterface.list(includeLinkLocal: true);
    networks.removeWhere((i) => i.addresses.every((a) => a.isLoopback));
    return networks.map(LocalInterface.from).toList();
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
      controlPort: controlPort ?? 45833,
    );
  }

  @override
  Future<void> createSession() => _guard(() async {
    await _stopSession();
    await _refresh(request: true);
    if (_selected == null) {
      _error = _noInterfaceCode;
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
    _resetSync();
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
      _error = _noInterfaceCode;
      return;
    }
    _session = session.withEndpoint(DeviceRole.b, _localEndpoint(session.b.id));
    _resetSync();
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
    // The invitation carries A's endpoint as of its creation; A's answer says
    // which revision is current and whether A now holds this device's one.
    await _syncEndpoint();
    if (_syncFailure == 'control_unreachable' && _error == null) {
      _error = 'controlUnavailable';
    }
  }, code: 'invalidInvitation');

  String get _noInterfaceCode =>
      _preferred == null ? 'noInterface' : 'interfaceUnavailable';

  /// A new session starts from revision 1 with no endpoint from the peer.
  /// Answers still in flight for an earlier session see another epoch.
  void _resetSync() {
    _epoch++;
    final now = DateTime.now().microsecondsSinceEpoch;
    _generation = now > _generation ? now : _generation + 1;
    _peerGeneration = 0;
    _localRevision = 1;
    _peerRevision = 0;
    _ackedRevision = 0;
    _receiptPushRevision = 0;
    _syncFailure = null;
    _startVerified = false;
  }

  // Control listeners are opened and closed strictly one at a time. Lifecycle
  // callbacks, interface changes and new sessions can overlap; each queued
  // operation decides from the state at the moment it runs.
  Future<void> _controlQueue = Future<void>.value();

  Future<void> _serializeControl(Future<void> Function() operation) {
    final result = _controlQueue.then((_) => operation());
    _controlQueue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// Replaces the listener with a fresh one for the current session.
  Future<void> _openControl() => _serializeControl(_replaceControl);

  /// Opens the listener only when the current one does not already serve the
  /// current session, for example after `inactive` to `resumed`.
  Future<void> _ensureControl() => _serializeControl(() async {
    final session = _session;
    if (session != null && _control?.serves(session) == true) return;
    await _replaceControl();
  });

  Future<void> _closeControl({bool forget = false}) =>
      _serializeControl(() async {
        final link = _control;
        if (forget) _control = null;
        await link?.close();
      });

  Future<void> _replaceControl() async {
    await _control?.close();
    final session = _session;
    if (_disposed || session == null) {
      _control = null;
      return;
    }
    // Callbacks of a replaced listener may still be running. Each checks that
    // its link is the current one before it touches any state.
    late final ControlLink link;
    link = ControlLink(
      session: session,
      onHello: (endpoint) async => _onHello(link, endpoint),
      onEndpoint: (update) async => _onEndpoint(link, update),
      startVerdict: (stamp) => _startVerdict(link, stamp),
      onStart: () async {
        _requireCurrent(link);
        if (_running || _completed || _busy) throw const StartDeclined();
        final ready = Completer<void>();
        unawaited(_run(notifyPeer: false, ready: ready));
        await ready.future.timeout(const Duration(seconds: 2));
      },
      onReport: (text) async {
        _requireCurrent(link);
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
    _control = link;
    try {
      if (_capabilities['permission'] != 'denied') {
        await link.open();
        // The earlier failure no longer describes the current state.
        if (identical(_control, link) && _error == 'controlUnavailable') {
          _error = null;
          _notify();
        }
      }
    } catch (_) {
      if (identical(_control, link)) {
        _error = 'controlUnavailable';
        _notify();
      }
    }
  }

  void _requireCurrent(ControlLink link) {
    final session = _session;
    if (_disposed ||
        !identical(_control, link) ||
        session == null ||
        session.sessionId != link.session.sessionId) {
      throw StateError('Superseded control link.');
    }
  }

  DeviceRole get _peerRole =>
      _session!.localRole == DeviceRole.a ? DeviceRole.b : DeviceRole.a;

  /// Stores the peer's endpoint. [revision] 0 marks an endpoint whose
  /// currency nobody confirmed (0.1.1 peer, manual entry).
  void _adoptPeer(DeviceEndpoint endpoint, int revision) {
    _session = _session!.withEndpoint(_peerRole, endpoint);
    _peerRevision = revision;
    _control?.session = _session!;
  }

  bool _sameEndpoint(DeviceEndpoint a, DeviceEndpoint b) =>
      jsonEncode(a.toJson()) == jsonEncode(b.toJson());

  /// 0.1.1 handshake. Such a peer cannot number endpoints, so what it sends is
  /// used but never counts as confirmed.
  void _onHello(ControlLink link, DeviceEndpoint endpoint) {
    _requireCurrent(link);
    if (_running || _completed) return;
    _adoptPeer(endpoint, 0);
    _ackedRevision = 0;
    _syncFailure = 'peer_legacy';
    _notify();
  }

  /// The peer announces its current endpoint. The answer carries this device's
  /// own, so one exchange updates both sides.
  EndpointReply _onEndpoint(ControlLink link, EndpointUpdate update) {
    _requireCurrent(link);
    EndpointReply reply(bool applied, [String? reason]) => EndpointReply(
      endpoint: _session!.local,
      revision: _localRevision,
      generation: _generation,
      applied: applied,
      appliedRevision: _peerRevision,
      reason: reason,
    );
    if (_running) return reply(false, 'peer_running');
    if (_completed) return reply(false, 'peer_completed');
    final stamp = update.stamp;
    // A larger generation is a later join of the sender: its numbering starts
    // over and whatever it acknowledged before is void. A smaller one is a
    // late message of an earlier join.
    if (update.generation < _peerGeneration) {
      return reply(false, 'stale_revision');
    }
    final restarted = update.generation > _peerGeneration;
    if (!restarted) {
      if (stamp.revision < _peerRevision) return reply(false, 'stale_revision');
      if (stamp.revision == _peerRevision &&
          !_sameEndpoint(update.endpoint, _session!.peer)) {
        return reply(false, 'revision_conflict');
      }
    }
    // An identical resend of the held revision changes nothing (idempotent).
    if (restarted || stamp.revision > _peerRevision) {
      _adoptPeer(update.endpoint, stamp.revision);
    }
    if (restarted) {
      _peerGeneration = update.generation;
      _ackedRevision = 0;
      _receiptPushRevision = 0;
    }
    if (stamp.peerRevision == _localRevision) {
      _ackedRevision = _localRevision;
      _syncFailure = null;
    } else if (_receiptPushRevision != _localRevision) {
      // The peer does not hold this device's current endpoint. One push per
      // revision answers it; the peer's answer cannot trigger another.
      _receiptPushRevision = _localRevision;
      unawaited(Future(() => _syncEndpoint(force: true)));
    }
    _notify();
    return reply(true);
  }

  /// A `/start` may use the single run only when both sides hold each
  /// other's current endpoint.
  StartVerdict _startVerdict(ControlLink link, EndpointStamp? stamp) {
    _startVerified = false;
    if (!identical(_control, link)) return StartVerdict.declined;
    if (stamp == null) return StartVerdict.unverified;
    if (_peerRevision > 0 &&
        stamp.revision == _peerRevision &&
        stamp.peerRevision == _localRevision) {
      _startVerified = true;
      return StartVerdict.verified;
    }
    return StartVerdict.declined;
  }

  // Endpoint exchanges run one at a time, in the order they were requested.
  Future<void> _syncChain = Future<void>.value();

  /// Sends this device's endpoint to the peer and adopts the peer's answer.
  /// Skipped when the peer already acknowledged the current revision, unless
  /// [force]. Bounded: [_syncAttempts] attempts with a deadline each, no
  /// background retries; the user's refresh starts another exchange.
  Future<void> _syncEndpoint({bool force = false}) {
    final result = _syncChain.then((_) => _pushEndpoint(force: force));
    _syncChain = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _pushEndpoint({required bool force}) async {
    final link = _control;
    final session = _session;
    if (_disposed || link == null || session == null) return;
    if (_running || _completed || link.isClosed) return;
    final revision = _localRevision;
    final epoch = _epoch;
    if (!force && _ackedRevision == revision && _peerRevision > 0) return;
    // Before the second device joined there is nobody to tell.
    if (_peerRevision == 0 && session.peer.address.isEmpty) return;
    bool current() =>
        !_disposed &&
        epoch == _epoch &&
        identical(_control, link) &&
        _localRevision == revision &&
        !_running &&
        !_completed;

    _syncingEpoch = epoch;
    _syncFailure = null;
    _notify();
    String? failure;
    try {
      for (var attempt = 0; attempt < _syncAttempts; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        if (!current()) return;
        try {
          debugPushes++;
          final text = await link
              .post(
                '/endpoint',
                fields: {
                  'endpoint': session.local.toJson(),
                  'generation': _generation,
                  ...EndpointStamp(
                    revision: revision,
                    peerRevision: _peerRevision,
                  ).toJson(),
                },
              )
              .timeout(const Duration(seconds: 4));
          // An answer to a superseded state describes nothing current.
          if (!current()) return;
          final reply = EndpointReply.fromJson(jsonDecode(text));
          if (reply.endpoint.id != session.peer.id) {
            throw const FormatException('Wrong participant.');
          }
          if (reply.generation > _peerGeneration ||
              reply.generation == _peerGeneration &&
                  reply.revision > _peerRevision) {
            _adoptPeer(reply.endpoint, reply.revision);
            _peerGeneration = reply.generation;
          }
          if (reply.applied && reply.appliedRevision == revision) {
            _ackedRevision = revision;
          } else {
            failure = reply.reason ?? 'peer_rejected';
          }
          break;
        } on ControlRejected catch (e) {
          if (e.statusCode == HttpStatus.notFound) {
            failure = await _legacyHello(link, session, current);
          } else {
            failure = 'peer_rejected';
          }
          break;
        } on FormatException {
          failure = 'peer_rejected';
          break;
        } catch (_) {
          failure = 'control_unreachable';
        }
      }
      if (!current()) return;
      _syncFailure = failure;
    } finally {
      if (_syncingEpoch == epoch) _syncingEpoch = null;
      _notify();
    }
  }

  /// A 0.1.1 peer has no `/endpoint`. Its `/hello` still delivers this
  /// device's endpoint and returns the peer's, but nothing confirms that
  /// the peer applied it.
  Future<String> _legacyHello(
    ControlLink link,
    Session session,
    bool Function() current,
  ) async {
    try {
      final peer = DeviceEndpoint.fromJson(
        jsonDecode(
          await link
              .post('/hello', fields: {'endpoint': session.local.toJson()})
              .timeout(const Duration(seconds: 4)),
        ),
      );
      if (current() && peer.id == session.peer.id) _adoptPeer(peer, 0);
      return 'peer_legacy';
    } catch (_) {
      return 'control_unreachable';
    }
  }

  /// Makes the session's local endpoint describe the selected interface now.
  /// A changed endpoint gets a new revision, a new listener and a new
  /// exchange. Nothing is confirmed here: that takes the peer's answer.
  Future<void> _reconcileEndpoint({bool force = false}) async {
    final session = _session;
    if (session == null || _completed || _running) return;
    if (_selected == null) {
      // No stale endpoint stays in effect: the listener closes and the state
      // says why the peer cannot be confirmed.
      await _closeControl();
      _error = 'interfaceUnavailable';
      _notify();
      return;
    }
    final next = _localEndpoint(session.local.id);
    var changed = false;
    if (!_sameEndpoint(next, session.local)) {
      _session = session.withEndpoint(session.localRole, next);
      _localRevision++;
      _syncFailure = null;
      changed = true;
    }
    if (_error == 'interfaceUnavailable') _error = null;
    // A listener that had to be opened again missed whatever the peer sent
    // meanwhile, so the exchange is repeated even for an unchanged endpoint.
    final reopened = changed || _control?.serves(_session!) != true;
    if (changed) {
      await _openControl();
    } else {
      await _ensureControl();
    }
    await _syncEndpoint(force: force || reopened);
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
    final local = _session!.local;
    final own = [local.address, local.ipv6Address]
        .whereType<String>()
        .map((a) => InternetAddress.tryParse(a.split('%').first))
        .whereType<InternetAddress>();
    if (port == local.tcpPort &&
        own.any(
          (a) =>
              a.type == parsed.type &&
              a.rawAddress.length == parsed.rawAddress.length &&
              Iterable.generate(a.rawAddress.length)
                  .every((i) => a.rawAddress[i] == parsed.rawAddress[i]),
        )) {
      // This device's own TCP listener would answer, not the peer.
      _error = 'peerAddressIsLocal';
      return;
    }
    final peer = _session!.peer.copyWith(
      address: address,
      ipv6Address: parsed.type == InternetAddressType.IPv6 ? address : null,
      tcpPort: port,
    );
    // Typed by the user, not announced by the peer: usable, never confirmed.
    _adoptPeer(peer, 0);
    _ackedRevision = 0;
    _syncFailure = 'manual_peer';
  }, code: 'invalidAddress');
  @override
  Future<void> selectInterface(String name) => _guard(() async {
    if (_running || !_interfaces.any((i) => i.name == name)) return;
    // A choice is remembered for later sessions even when the current one
    // has finished and keeps its journal's endpoints.
    _preferred = name;
    _selected = name;
    await _reconcileEndpoint();
  });
  @override
  Future<void> refreshReadiness() => _guard(() async {
    await _refresh(request: true);
    await _reconcileEndpoint(force: true);
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
      // Probes use these endpoints and these revisions for the whole run;
      // changes that arrive later describe a different configuration.
      final stamp = EndpointStamp(
        revision: _localRevision,
        peerRevision: _peerRevision,
      );
      final confirmed = _syncView.status == 'confirmed';
      final startedVerified = _startVerified;
      final engine = ProbeEngine(
        session: _session!,
        platform: _platform,
        capabilities: _capabilities,
        endpointRevisions: stamp,
        onProgress: (p) {
          _progress = p;
          _notify();
        },
      );
      _engine = engine;
      _report = await engine.run(
        onReady: () async {
          if (ready != null && !ready.isCompleted) ready.complete();
          // A peer that started this run had its listeners open first, and
          // verified that both sides hold each other's current endpoint.
          if (!notifyPeer) return startedVerified;
          try {
            final answer = await _control!.post(
              '/start',
              fields: stamp.toJson(),
            );
            // A peer that accepts without verifying (0.1.1) started, but
            // nothing says it probes this device's current endpoint.
            return confirmed && _verifiedAnswer(answer);
          } catch (_) {
            // Independent run remains useful, but the peer's readiness is
            // unknown and the engine spreads its attempts over the window.
            return false;
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

  bool _verifiedAnswer(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map && value['verified'] == true;
    } catch (_) {
      return false;
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
      unawaited(_closeControl());
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _resumeChain = _resumeChain.then((_) => _resume());
    }
  }

  Future<void> _resume() async {
    try {
      // A refresh during a run or another operation would replace the state
      // those depend on and hide a network change from the poll.
      if (!_busy && !_running) await _refresh(request: false);
      if (_disposed || !_foreground) return;
      if (_session != null && !_running && !_completed) {
        // The peer's pushes could not reach this device while it was away,
        // and the network may have changed: exchange the endpoints once.
        await _reconcileEndpoint(force: true);
      }
      _notify();
    } catch (_) {
      _error = 'operationFailed';
      _notify();
    }
  }

  Future<void> _checkNetwork() async {
    if (_checkingNetwork || _disposed) return;
    _checkingNetwork = true;
    try {
      final networks = await _listInterfaces();
      if (_signature(networks) == _networkSignature) return;
      // Another operation owns the state; the next poll sees the change again.
      if (_busy && !_running) return;
      final interrupted = _engine != null;
      _engine?.cancel(reason: ObservationKind.networkChanged);
      _checkpoint();
      _interfaces = networks;
      _networkSignature = _signature(networks);
      _selected = _chooseInterface();
      if (_session == null) {
        _notify();
      } else if (interrupted || _running || _completed) {
        // The run is single use: collected observations are kept and marked
        // as interrupted, and further checks need a new session.
        await _closeControl();
        _error = 'networkChanged';
        _notify();
      } else {
        await _reconcileEndpoint();
      }
    } catch (_) {
      /* Retry on next bounded poll. */
    } finally {
      _checkingNetwork = false;
    }
  }

  String _signature(List<LocalInterface> networks) {
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
    await _closeControl(forget: true);
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
