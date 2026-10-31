import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:lanpair/l10n/generated/app_localizations.dart';
import 'package:lanpair/src/app.dart';
import 'package:lanpair/src/preferences.dart';
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
  String sync = 'none';
  String? syncReason;

  @override
  String get peerSync => sync;
  @override
  String? get peerSyncReason => syncReason;
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

/// The settings button of the wide layout or of the Apple navigation bar.
final _settingsButton = find.byWidgetPredicate(
  (widget) =>
      widget is Icon &&
      (widget.icon == Icons.tune_rounded ||
          widget.icon == CupertinoIcons.slider_horizontal_3),
);

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

  testWidgets('the QR code is large on desktop screens and fits small ones', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    // A 13 inch laptop window, then a narrow (tall, to avoid scrolling) phone.
    for (final (size, atLeast, atMost) in [
      (const Size(1440, 900), 400.0, 640.0),
      (const Size(390, 2400), 190.0, 250.0),
    ]) {
      tester.view.physicalSize = size;
      final controller = FakeController()..complete();
      await tester.pumpWidget(LanPairApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show QR code'));
      await tester.pumpAndSettle();
      final side = tester.getSize(find.byType(QrImageView)).width;
      expect(side, inInclusiveRange(atLeast, atMost), reason: '$size');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the QR dialog closes with Escape and with a click outside', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      LanPairApp(controller: FakeController()..complete()),
    );
    await tester.pumpAndSettle();
    for (final close in <Future<void> Function()>[
      () => tester.sendKeyEvent(LogicalKeyboardKey.escape),
      () => tester.tapAt(const Offset(10, 10)),
    ]) {
      await tester.tap(find.text('Show QR code'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      await close();
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
    }
  });

  group('dialogs on laptop screens', () {
    // The platform alert is a narrow fixed box on Apple platforms; the shared
    // dialog must use the window it has and keep its actions on screen.
    for (final (size, minWidth) in [
      (const Size(1440, 900), 500.0),
      (const Size(1280, 720), 500.0),
      (const Size(1000, 420), 500.0),
      (const Size(360, 640), 300.0),
    ]) {
      testWidgets('settings, details and export fit $size', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = FakeController()..complete();
        await tester.pumpWidget(LanPairApp(controller: controller));
        await tester.pumpAndSettle();

        void expectFits(Finder action) {
          final dialog = find.byType(Dialog);
          expect(dialog, findsOneWidget);
          final rect = tester.getRect(dialog);
          expect(rect.width, greaterThanOrEqualTo(minWidth));
          expect(rect.height, lessThanOrEqualTo(size.height));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          // The actions stay visible whatever the height of the content.
          expect(tester.getRect(action).bottom, lessThanOrEqualTo(size.height));
          expect(tester.takeException(), isNull);
        }

        await tester.tap(_settingsButton.first);
        await tester.pumpAndSettle();
        expectFits(find.text('Close'));
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Results').hitTestable().first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Export report'));
        await tester.tap(find.text('Export report'));
        await tester.pumpAndSettle();
        expectFits(find.text('Export report').last);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);

        await tester.ensureVisible(find.textContaining('TCP').first);
        await tester.tap(find.textContaining('TCP').first);
        await tester.pumpAndSettle();
        expectFits(find.text('Close'));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
    }
  });

  group('persisted settings', () {
    late Directory directory;
    setUp(
      () => directory = Directory.systemTemp.createTempSync('lanpair-pref'),
    );
    tearDown(() => directory.deleteSync(recursive: true));

    test('theme and language survive a restart', () {
      final file = File('${directory.path}/preferences.json');
      AppPreferences.load(file)
        ..theme = ThemeMode.dark
        ..localeTag = 'pt_BR'
        ..save();
      final restored = AppPreferences.load(file);
      expect(restored.theme, ThemeMode.dark);
      expect(restored.localeTag, 'pt_BR');
      expect(localeFromTag(restored.localeTag), const Locale('pt', 'BR'));
    });

    test('a missing, damaged or foreign file means the defaults', () {
      final file = File('${directory.path}/preferences.json');
      expect(AppPreferences.load(file).theme, ThemeMode.system);
      file.writeAsStringSync('{broken');
      expect(AppPreferences.load(file).localeTag, isNull);
      file.writeAsStringSync('{"theme":"neon","locale":"xx"}');
      final restored = AppPreferences.load(file);
      expect(restored.theme, ThemeMode.system);
      expect(restored.localeTag, isNull);
    });

    testWidgets('choices made in the dialog are written and reapplied', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final file = File('${directory.path}/preferences.json');
      await tester.pumpWidget(
        LanPairApp(
          controller: FakeController(),
          preferences: AppPreferences.load(file),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_settingsButton.first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<ThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Русский').last);
      await tester.pumpAndSettle();
      final saved = AppPreferences.load(file);
      expect(saved.theme, ThemeMode.dark);
      expect(saved.localeTag, 'ru');

      // A new launch starts with the saved choices.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        LanPairApp(controller: FakeController(), preferences: saved),
      );
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.dark);
      expect(app.locale, const Locale('ru'));
    });
  });

  testWidgets('the run panel warns when the peer has not confirmed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeController()..session = true;
    for (final (state, reason, warns) in [
      ('confirmed', 'confirmed', false),
      ('unconfirmed', 'control_unreachable', true),
      ('pending', 'syncing', true),
    ]) {
      controller
        ..sync = state
        ..syncReason = reason;
      await tester.pumpWidget(LanPairApp(controller: controller));
      await tester.pumpAndSettle();
      final warning = find.textContaining('start independently');
      expect(warning, warns ? findsOneWidget : findsNothing, reason: state);
      expect(tester.takeException(), isNull);
    }
  });

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
