import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/l10n/generated/app_localizations.dart';
import 'package:lanpair/src/app.dart';
import 'package:lanpair/src/ui_contract.dart';

class FakeController extends LanPairController {
  bool session = false;
  bool isRunning = false;
  bool merged = false;
  String? error;
  String? joined;
  String? manualHost;
  int? manualPort;
  int starts = 0;
  int cancels = 0;
  bool? exportedRedacted;
  bool? exportedReadable;
  String? humanText;
  ReportExportView? exportView;
  List<ResultView> checkResults = [];

  @override
  bool get busy => false;
  @override
  bool get running => isRunning;
  @override
  bool get hasSession => session;
  @override
  bool get canScan => false;
  @override
  String? get sessionId => session ? 'session-abcdef123456' : null;
  @override
  String? get runId => session ? 'run-abcdef123456' : null;
  @override
  String get localRole => 'A';
  @override
  String? get invitation => session ? 'LANPair invitation fixture' : null;
  @override
  String? get errorCode => error;
  @override
  String? get errorDetail => null;
  @override
  double get progress => .5;
  @override
  String? get selectedInterface => 'Ethernet 6 (test adapter)';
  @override
  List<InterfaceView> get interfaces => const [
    InterfaceView(
      name: 'Ethernet 6 (test adapter)',
      addresses: ['192.0.2.10', 'fe80::1%en0'],
    ),
  ];
  @override
  List<ReadinessView> get readiness => const [
    ReadinessView(
      code: 'networkPermission',
      status: 'inconclusive',
      detail: 'permission_unknown',
    ),
    ReadinessView(
      code: 'multicast',
      status: 'unsupported',
      detail: 'multicast_entitlement_missing',
    ),
    ReadinessView(code: 'discovery', status: 'passed'),
  ];
  @override
  List<ResultView> get results => checkResults;
  @override
  List<HistoryView> get history => session
      ? [
          HistoryView(
            id: 'saved-run',
            sessionId: sessionId!,
            runId: runId!,
            savedAt: DateTime(2026, 10, 29, 12),
            observationCount: 12,
            merged: merged,
          ),
        ]
      : [];
  @override
  List<String> get exportAddresses => [
    '192.0.2.10',
    '192.0.2.20',
    'fe80::1%en0',
  ];
  @override
  bool get peerJournalPresent => merged;

  @override
  Future<void> createSession() async {
    session = true;
    checkResults = [];
    notifyListeners();
  }

  @override
  Future<void> joinSession(String invitation) async {
    joined = invitation;
    session = true;
    notifyListeners();
  }

  @override
  Future<void> importInvitation() async {
    joined = 'file';
    session = true;
    notifyListeners();
  }

  @override
  Future<void> saveInvitation() async {}
  @override
  Future<void> setManualPeer(String host, int port) async {
    manualHost = host;
    manualPort = port;
  }

  @override
  Future<void> selectInterface(String name) async {}
  @override
  Future<void> refreshReadiness() async {}
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> startRun() async {
    starts++;
    isRunning = true;
    notifyListeners();
  }

  @override
  Future<void> cancelRun() async {
    cancels++;
    isRunning = false;
    notifyListeners();
  }

  @override
  Future<void> importReport() async {
    merged = true;
    notifyListeners();
  }

  @override
  Future<void> exportReport({
    required bool redact,
    required bool humanReadable,
    String Function(ReportExportView report)? formatReadableReport,
  }) async {
    exportedRedacted = redact;
    exportedReadable = humanReadable;
    humanText = formatReadableReport?.call(
      exportView ??
          ReportExportView(
            fields: const [],
            addresses: exportAddresses,
            results: results,
            redacted: redact,
          ),
    );
  }

  @override
  Future<void> openHistory(String id) async {
    complete();
  }

  @override
  void clearError() {
    error = null;
    notifyListeners();
  }

  void complete() {
    session = true;
    isRunning = false;
    checkResults = const [
      ResultView(
        id: 'tcp4a',
        kind: 'tcp',
        family: 'ipv4',
        direction: 'A → B',
        status: 'passed',
        reason: 'peer_confirmed',
        observations: [
          ObservationView(code: 'connected', device: 'A', elapsedMs: 22),
        ],
      ),
      ResultView(
        id: 'udp4a',
        kind: 'udp',
        family: 'ipv4',
        direction: 'A → B',
        status: 'passed',
        reason: 'peer_received',
        observations: [
          ObservationView(
            code: 'sent',
            device: 'A',
            elapsedMs: 50,
            sequence: 1,
          ),
          ObservationView(
            code: 'received',
            device: 'B',
            elapsedMs: 45,
            sequence: 1,
          ),
        ],
      ),
      ResultView(
        id: 'tcp4b',
        kind: 'tcp',
        family: 'ipv4',
        direction: 'B → A',
        status: 'failed',
        reason: 'timeout_observed',
      ),
      ResultView(
        id: 'udp4b',
        kind: 'udp',
        family: 'ipv4',
        direction: 'B → A',
        status: 'inconclusive',
        reason: 'sent_delivery_unknown',
      ),
      ResultView(
        id: 'mc6a',
        kind: 'multicast',
        family: 'ipv6',
        direction: 'A → B',
        status: 'unsupported',
        reason: 'platform_unsupported',
      ),
      ResultView(
        id: 'dnsb',
        kind: 'dnssd',
        family: 'system',
        direction: 'B → A',
        status: 'permissionDenied',
        reason: 'permission_denied',
      ),
      ResultView(
        id: 'mc4a',
        kind: 'multicast',
        family: 'ipv4',
        direction: 'A → B',
        status: 'cancelled',
        reason: 'run_cancelled',
      ),
    ];
    notifyListeners();
  }
}

class _ArchivedController extends FakeController {
  @override
  bool get hasSession => false;
  @override
  String get localRole => 'B';
}

void main() {
  test('every supported ARB contains every English key with a translation', () {
    final template = jsonDecode(
      File('lib/l10n/app_en.arb').readAsStringSync(),
    ) as Map<String, dynamic>;
    final keys = template.keys.where((key) => !key.startsWith('@')).toSet();
    for (final locale in ['en', 'ru', 'es', 'de', 'fr', 'ja', 'pt_BR']) {
      final translated = jsonDecode(
        File('lib/l10n/app_$locale.arb').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(
        translated.keys.where((key) => !key.startsWith('@')).toSet(),
        keys,
        reason: locale,
      );
      for (final key in keys) {
        expect(translated[key], isA<String>(), reason: '$locale/$key');
        expect(
          (translated[key] as String).trim(),
          isNotEmpty,
          reason: '$locale/$key',
        );
      }
    }
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    for (final locale in AppLocalizations.supportedLocales.where(
      (l) => l.toString() != 'pt',
    )) {
      for (final viewport in [const Size(320, 720), const Size(1200, 850)]) {
        testWidgets(
          '$platform $locale fits $viewport at enlarged text, all key screens',
          (tester) async {
            tester.view.physicalSize = viewport;
            tester.view.devicePixelRatio = 1;
            tester.binding.platformDispatcher.localesTestValue = [locale];
            tester.binding.platformDispatcher.textScaleFactorTestValue = 1.8;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(
              tester.binding.platformDispatcher.clearLocalesTestValue,
            );
            addTearDown(
              tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final controller = FakeController();
            await tester.pumpWidget(LanPairApp(controller: controller));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              Localizations.localeOf(
                tester.element(find.byType(Scaffold).first),
              ),
              locale,
            );
            final s = AppLocalizations.of(
              tester.element(find.byType(Scaffold).first),
            );
            await tester.scrollUntilVisible(
              find.text(s.joinSession).last,
              250,
              scrollable: find.byType(Scrollable).first,
            );
            expect(tester.takeException(), isNull);
            controller.session = true;
            controller.notifyListeners();
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(
              find.text(s.startRun),
              250,
              scrollable: find.byType(Scrollable).first,
            );
            expect(tester.takeException(), isNull);
            controller.complete();
            await tester.pumpAndSettle();
            await tester.tap(find.text(s.resultsTab).hitTestable().first);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.scrollUntilVisible(
              find.text(s.cancelled).last,
              250,
              scrollable: find.byType(Scrollable).first,
            );
            expect(tester.takeException(), isNull);
            await tester.tap(find.text(s.historyTab).hitTestable().first);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant({platform}),
        );
      }
    }
  }

  testWidgets(
    'paste invitation, manual peer, cancellation and keyboard actions',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FakeController();
      await tester.pumpWidget(LanPairApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('invitation-input')),
        'manual invitation',
      );
      await tester.tap(find.text('Join session').last);
      await tester.pumpAndSettle();
      expect(controller.joined, 'manual invitation');
      await tester.scrollUntilVisible(
        find.text('Manual peer address'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Manual peer address'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'IP address (IPv6 may include %scope)',
        ),
        'fe80::1%en0',
      );
      await tester.scrollUntilVisible(
        find.text('Use address'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Use address'));
      await tester.pumpAndSettle();
      expect(controller.manualHost, 'fe80::1%en0');
      expect(controller.manualPort, 45871);
      await tester.scrollUntilVisible(
        find.text('Start bounded checks'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Start bounded checks'));
      await tester.pump();
      expect(controller.starts, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.cancels, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'export previews private addresses and defaults to redacted JSON',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FakeController()..complete();
      await tester.pumpWidget(LanPairApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Results').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export report'));
      await tester.pumpAndSettle();
      expect(find.text('192.0.2.10'), findsOneWidget);
      expect(find.text('192.0.2.20'), findsOneWidget);
      expect(
        find.text('Replace private details with consistent aliases'),
        findsOneWidget,
      );
      await tester.tap(find.text('Export report').last);
      await tester.pumpAndSettle();
      expect(controller.exportedRedacted, isTrue);
      expect(controller.exportedReadable, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('archived results identify the journal source', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _ArchivedController()..complete();
    await tester.pumpWidget(LanPairApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Results').first);
    await tester.pumpAndSettle();
    expect(find.text('Journal source: B'), findsOneWidget);
    expect(find.text('This device: A'), findsNothing);
    expect(find.text('This device: B'), findsNothing);
  });

  testWidgets('readable formatter uses the prepared redacted export view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeController()..complete();
    controller.exportView = const ReportExportView(
      fields: [
        ReportFieldView(
          label: 'capabilities',
          value: '{"a.gateway":"redacted"}',
        ),
      ],
      addresses: ['device-a-ipv4', 'device-b-ipv4'],
      results: [],
      redacted: true,
    );
    await tester.pumpWidget(LanPairApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Results').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export report'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<bool>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Readable report').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export report').last);
    await tester.pumpAndSettle();
    expect(controller.exportedReadable, isTrue);
    expect(controller.exportedRedacted, isTrue);
    expect(controller.humanText, contains('redacted'));
    expect(controller.humanText, contains('device-a-ipv4'));
    expect(controller.humanText, isNot(contains('192.0.2.10')));
  });

  testWidgets('important controls expose labels and sufficient tap targets', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(LanPairApp(controller: FakeController()));
    await tester.pumpAndSettle();
    expect(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });
}
