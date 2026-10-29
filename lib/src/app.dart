import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'qr_decode.dart';

import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/generated/app_localizations.dart';
import 'ui_contract.dart';
import 'ui_theme.dart';

/// The same diagnostic model is presented with platform-specific navigation,
/// input conventions and controls. No network assertion is inferred by the UI.
class LanPairApp extends StatefulWidget {
  const LanPairApp({super.key, required this.controller});

  final LanPairController controller;

  @override
  State<LanPairApp> createState() => _LanPairAppState();
}

class _LanPairAppState extends State<LanPairApp> {
  ThemeMode _theme = ThemeMode.system;
  Locale? _locale;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LANPair',
    debugShowCheckedModeBanner: false,
    locale: _locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    themeMode: _theme,
    theme: lanPairTheme(Brightness.light),
    darkTheme: lanPairTheme(Brightness.dark),
    builder: (context, child) => CupertinoTheme(
      data: CupertinoThemeData(
        brightness: Theme.of(context).brightness,
        primaryColor: Theme.of(context).colorScheme.primary,
        primaryContrastingColor: Theme.of(context).colorScheme.onPrimary,
      ),
      child: child!,
    ),
    home: _Workspace(
      controller: widget.controller,
      theme: _theme,
      locale: _locale,
      onThemeChanged: (value) => setState(() => _theme = value),
      onLocaleChanged: (value) => setState(() => _locale = value),
    ),
  );
}

class _NewSessionIntent extends Intent {
  const _NewSessionIntent();
}

class _ImportIntent extends Intent {
  const _ImportIntent();
}

class _ExportIntent extends Intent {
  const _ExportIntent();
}

class _CancelIntent extends Intent {
  const _CancelIntent();
}

class _Workspace extends StatefulWidget {
  const _Workspace({
    required this.controller,
    required this.theme,
    required this.locale,
    required this.onThemeChanged,
    required this.onLocaleChanged,
  });

  final LanPairController controller;
  final ThemeMode theme;
  final Locale? locale;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<Locale?> onLocaleChanged;

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> {
  final _invitation = TextEditingController();
  final _address = TextEditingController();
  final _port = TextEditingController(text: '45871');
  final _manualKey = GlobalKey<FormState>();
  int _tab = 0;

  LanPairController get c => widget.controller;
  AppLocalizations get s => AppLocalizations.of(context);
  bool get apple =>
      Theme.of(context).platform == TargetPlatform.iOS ||
      Theme.of(context).platform == TargetPlatform.macOS;

  @override
  void dispose() {
    _invitation.dispose();
    _address.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    await action();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => _withMenus(
      Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyN, control: true):
              _NewSessionIntent(),
          SingleActivator(LogicalKeyboardKey.keyN, meta: true):
              _NewSessionIntent(),
          SingleActivator(LogicalKeyboardKey.keyO, control: true):
              _ImportIntent(),
          SingleActivator(LogicalKeyboardKey.keyO, meta: true): _ImportIntent(),
          SingleActivator(LogicalKeyboardKey.keyE, control: true):
              _ExportIntent(),
          SingleActivator(LogicalKeyboardKey.keyE, meta: true): _ExportIntent(),
          SingleActivator(LogicalKeyboardKey.escape): _CancelIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _NewSessionIntent: CallbackAction<_NewSessionIntent>(
              onInvoke: (_) {
                if (!c.busy && !c.running) _perform(c.createSession);
                return null;
              },
            ),
            _ImportIntent: CallbackAction<_ImportIntent>(
              onInvoke: (_) {
                if (!c.busy && !c.running) _perform(c.importInvitation);
                return null;
              },
            ),
            _ExportIntent: CallbackAction<_ExportIntent>(
              onInvoke: (_) {
                if (c.results.isNotEmpty && !c.busy) _export();
                return null;
              },
            ),
            _CancelIntent: CallbackAction<_CancelIntent>(
              onInvoke: (_) {
                if (c.running) _perform(c.cancelRun);
                return null;
              },
            ),
          },
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final desktop = constraints.maxWidth >= 840;
                return Scaffold(
                  appBar: apple && !desktop
                      ? _appleBar()
                      : AppBar(
                          title: Row(
                            children: [
                              const _BrandMark(),
                              const SizedBox(width: 12),
                              Flexible(child: Text(s.appTitle)),
                            ],
                          ),
                          actions: [
                            IconButton(
                              tooltip: s.refresh,
                              onPressed: c.busy || c.running
                                  ? null
                                  : () => _perform(c.refreshReadiness),
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                            IconButton(
                              tooltip: s.settings,
                              onPressed: _settings,
                              icon: const Icon(Icons.tune_rounded),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ),
                  body: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (desktop) ...[
                        NavigationRail(
                          selectedIndex: _tab,
                          extended: constraints.maxWidth >= 1120,
                          labelType: constraints.maxWidth >= 1120
                              ? NavigationRailLabelType.none
                              : NavigationRailLabelType.all,
                          onDestinationSelected: (value) =>
                              setState(() => _tab = value),
                          destinations: [
                            NavigationRailDestination(
                              icon: const Icon(Icons.devices_outlined),
                              selectedIcon: const Icon(Icons.devices),
                              label: Text(s.sessionTab),
                            ),
                            NavigationRailDestination(
                              icon: const Icon(Icons.compare_arrows_rounded),
                              label: Text(s.resultsTab),
                            ),
                            NavigationRailDestination(
                              icon: const Icon(Icons.history_rounded),
                              label: Text(s.historyTab),
                            ),
                          ],
                        ),
                        const VerticalDivider(width: 1),
                      ],
                      Expanded(
                        child: SafeArea(
                          top: false,
                          child: Column(
                            children: [
                              if (c.busy)
                                LinearProgressIndicator(
                                  semanticsLabel: s.running,
                                ),
                              if (c.errorCode != null) _errorBanner(),
                              Expanded(
                                child: SingleChildScrollView(
                                  key: ValueKey(_tab),
                                  padding: EdgeInsets.all(desktop ? 40 : 20),
                                  child: Align(
                                    alignment: Alignment.topCenter,
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 1160,
                                      ),
                                      child: switch (_tab) {
                                        0 => _session(),
                                        1 => _results(),
                                        _ => _history(),
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  bottomNavigationBar: desktop
                      ? null
                      : apple
                      ? CupertinoTabBar(
                          currentIndex: _tab,
                          onTap: (value) => setState(() => _tab = value),
                          items: [
                            BottomNavigationBarItem(
                              icon: const Icon(CupertinoIcons.device_laptop),
                              label: s.sessionTab,
                            ),
                            BottomNavigationBarItem(
                              icon: const Icon(
                                CupertinoIcons.arrow_right_arrow_left,
                              ),
                              label: s.resultsTab,
                            ),
                            BottomNavigationBarItem(
                              icon: const Icon(CupertinoIcons.clock),
                              label: s.historyTab,
                            ),
                          ],
                        )
                      : NavigationBar(
                          selectedIndex: _tab,
                          onDestinationSelected: (value) =>
                              setState(() => _tab = value),
                          destinations: [
                            NavigationDestination(
                              icon: const Icon(Icons.devices_outlined),
                              selectedIcon: const Icon(Icons.devices),
                              label: s.sessionTab,
                            ),
                            NavigationDestination(
                              icon: const Icon(Icons.compare_arrows_rounded),
                              label: s.resultsTab,
                            ),
                            NavigationDestination(
                              icon: const Icon(Icons.history_rounded),
                              label: s.historyTab,
                            ),
                          ],
                        ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  Widget _withMenus(Widget child) {
    if (Theme.of(context).platform != TargetPlatform.macOS) return child;
    final material = MaterialLocalizations.of(context);
    void edit(Intent intent) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null) Actions.maybeInvoke(focused, intent);
    }

    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'LANPair',
          menus: [
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.about,
            ),
            PlatformMenuItem(
              label: s.settings,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                meta: true,
              ),
              onSelected: _settings,
            ),
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.servicesSubmenu,
            ),
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hide,
            ),
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hideOtherApplications,
            ),
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.quit,
            ),
          ],
        ),
        PlatformMenu(
          label: s.sessionTab,
          menus: [
            PlatformMenuItem(
              label: s.newSession,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                meta: true,
              ),
              onSelected: c.busy || c.running ? null : c.createSession,
            ),
            PlatformMenuItem(
              label: s.importInvitation,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyO,
                meta: true,
              ),
              onSelected: c.busy || c.running ? null : c.importInvitation,
            ),
            PlatformMenuItem(
              label: s.exportReport,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyE,
                meta: true,
              ),
              onSelected: c.results.isEmpty || c.busy ? null : _export,
            ),
          ],
        ),
        PlatformMenu(
          label: s.menuEdit,
          menus: [
            PlatformMenuItem(
              label: material.cutButtonLabel,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyX,
                meta: true,
              ),
              onSelected: () => edit(
                const CopySelectionTextIntent.cut(
                  SelectionChangedCause.keyboard,
                ),
              ),
            ),
            PlatformMenuItem(
              label: material.copyButtonLabel,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyC,
                meta: true,
              ),
              onSelected: () => edit(CopySelectionTextIntent.copy),
            ),
            PlatformMenuItem(
              label: material.pasteButtonLabel,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyV,
                meta: true,
              ),
              onSelected: () =>
                  edit(const PasteTextIntent(SelectionChangedCause.keyboard)),
            ),
            PlatformMenuItem(
              label: material.selectAllButtonLabel,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyA,
                meta: true,
              ),
              onSelected: () => edit(
                const SelectAllTextIntent(SelectionChangedCause.keyboard),
              ),
            ),
          ],
        ),
      ],
      child: child,
    );
  }

  PreferredSizeWidget _appleBar() => CupertinoNavigationBar(
    middle: Text(s.appTitle),
    leading: const Padding(
      padding: EdgeInsets.only(top: 5),
      child: _BrandMark(size: 28),
    ),
    trailing: CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: _settings,
      child: Semantics(
        label: s.settings,
        child: const Icon(CupertinoIcons.slider_horizontal_3),
      ),
    ),
  );

  Widget _session() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sessionIntro(),
      const SizedBox(height: 24),
      if (!c.hasSession) ...[
        _responsivePair(
          _panel(
            title: s.createTitle,
            icon: Icons.add_circle_outline_rounded,
            children: [
              Text(s.createDescription),
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: _button(
                  s.createSession,
                  Icons.add,
                  c.busy || c.running ? null : () => _perform(c.createSession),
                  primary: true,
                ),
              ),
            ],
          ),
          _panel(
            title: s.joinSession,
            icon: Icons.login_rounded,
            children: [
              Text(s.joinDescription),
              const SizedBox(height: 20),
              TextField(
                key: const Key('invitation-input'),
                controller: _invitation,
                minLines: 3,
                maxLines: 5,
                maxLength: 65536,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  labelText: s.invitationLabel,
                  hintText: s.invitationHint,
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _button(
                    s.joinSession,
                    Icons.login,
                    c.busy
                        ? null
                        : () => _perform(
                            () => c.joinSession(_invitation.text.trim()),
                          ),
                  ),
                  _button(
                    s.importInvitation,
                    Icons.file_open_outlined,
                    c.busy ? null : () => _perform(c.importInvitation),
                  ),
                  if (c.canScan)
                    _button(
                      s.scanQr,
                      Icons.qr_code_scanner,
                      c.busy ? null : _scan,
                    ),
                ],
              ),
            ],
          ),
        ),
      ] else ...[
        _sessionIdentity(),
        const SizedBox(height: 20),
        _responsivePair(_readiness(), _invitationPanel()),
        const SizedBox(height: 20),
        _manualPeer(),
        const SizedBox(height: 20),
        _runPanel(),
      ],
      const SizedBox(height: 24),
      _notice(Icons.shield_outlined, s.privacyDescription),
    ],
  );

  Widget _identityTag(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SelectableText(text, style: Theme.of(context).textTheme.bodySmall),
  );

  Widget _sessionIntro() {
    if (c.hasSession) return _pageHeading(s.sessionTab, s.appSubtitle);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 880;
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.compare_arrows_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  s.sessionTab,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              s.appSubtitle,
              style: Theme.of(context).textTheme.headlineSmall!
                  .copyWith(fontSize: wide ? 46 : 30, height: 1.12),
            ),
            const SizedBox(height: 24),
          ],
        );
        if (!wide) return heading;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            children: [
              Expanded(flex: 5, child: heading),
              const SizedBox(width: 40),
              const Expanded(flex: 4, child: _PairBlueprint()),
            ],
          ),
        );
      },
    );
  }

  Widget _sessionIdentity() => Wrap(
    spacing: 18,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _identityTag(s.sessionIdentifier(c.sessionId ?? '')),
      _identityTag(s.runIdentifier(c.runId ?? '')),
      _identityTag(
        c.hasSession
            ? s.localDevice(c.localRole)
            : s.journalDevice(c.localRole),
      ),
    ],
  );

  Widget _readiness() => _panel(
    title: s.readinessTitle,
    icon: Icons.fact_check_outlined,
    children: [
      Text(s.readinessDescription),
      const SizedBox(height: 20),
      if (c.interfaces.isEmpty)
        Text(s.noInterfaces)
      else
        DropdownButtonFormField<String>(
          key: ValueKey(c.selectedInterface),
          initialValue:
              c.interfaces.any((element) => element.name == c.selectedInterface)
              ? c.selectedInterface
              : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: s.networkInterface),
          items: c.interfaces
              .map(
                (value) => DropdownMenuItem(
                  value: value.name,
                  child: Text(value.name, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: c.busy || c.running
              ? null
              : (value) {
                  if (value != null) _perform(() => c.selectInterface(value));
                },
        ),
      if (c.selectedInterface != null) ...[
        const SizedBox(height: 8),
        for (final item in c.interfaces.where(
          (element) => element.name == c.selectedInterface,
        ))
          for (final address in item.addresses)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                address,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
      ],
      const SizedBox(height: 12),
      for (final item in c.readiness)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(_statusIcon(item.status), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _capability(item.code),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(_status(item.status)),
                    if (item.detail != null)
                      Text(
                        _readinessDetail(item.detail!),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _button(
            s.refresh,
            Icons.refresh,
            c.busy || c.running ? null : () => _perform(c.refreshReadiness),
          ),
          _button(
            s.openSettings,
            Icons.settings_outlined,
            c.busy ? null : () => _perform(c.openSettings),
          ),
        ],
      ),
    ],
  );

  Widget _invitationPanel() => _panel(
    title: s.shareInvitation,
    icon: Icons.qr_code_2,
    children: [
      Text(s.invitationPrivacy),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _button(
            s.copy,
            Icons.copy_outlined,
            c.invitation == null ? null : _copyInvitation,
          ),
          _button(
            s.saveInvitation,
            Icons.save_alt,
            c.invitation == null || c.busy
                ? null
                : () => _perform(c.saveInvitation),
          ),
          _button(
            s.showQr,
            Icons.qr_code,
            c.invitation == null ? null : _showQr,
          ),
        ],
      ),
      const SizedBox(height: 20),
      _notice(Icons.info_outline, s.runDescription, dense: true),
    ],
  );

  Widget _manualPeer() => Card(
    child: ExpansionTile(
      leading: const Icon(Icons.edit_location_alt_outlined),
      title: Text(s.manualAddress),
      childrenPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.manualDescription),
        const SizedBox(height: 20),
        Form(
          key: _manualKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _address,
                decoration: InputDecoration(labelText: s.address),
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 256,
                validator: (value) => value == null || value.trim().isEmpty
                    ? s.invalidAddress
                    : null,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 220,
                child: TextFormField(
                  controller: _port,
                  decoration: InputDecoration(labelText: s.port),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 5,
                  validator: (value) {
                    final port = int.tryParse(value ?? '');
                    return port == null || port < 1024 || port > 65535
                        ? s.invalidAddress
                        : null;
                  },
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: _button(
                  s.applyAddress,
                  Icons.check,
                  c.busy || c.running
                      ? null
                      : () {
                          if (_manualKey.currentState!.validate()) {
                            _perform(
                              () => c.setManualPeer(
                                _address.text.trim(),
                                int.parse(_port.text),
                              ),
                            );
                          }
                        },
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _runPanel() => _panel(
    title: c.running ? s.running : s.runTitle,
    icon: c.running ? Icons.pending_outlined : Icons.play_circle_outline,
    children: [
      if (c.running) ...[
        Semantics(
          liveRegion: true,
          label: s.running,
          child: LinearProgressIndicator(
            value: c.progress.clamp(0, 1),
            semanticsLabel: s.running,
          ),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: _button(s.cancelRun, Icons.stop, () => _perform(c.cancelRun)),
        ),
      ] else if (c.results.isNotEmpty) ...[
        Text(s.runOnce),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _button(
              s.resultsTab,
              Icons.compare_arrows,
              () => setState(() => _tab = 1),
              primary: true,
            ),
            _button(
              s.newSession,
              Icons.add,
              c.busy || c.running ? null : () => _perform(c.createSession),
            ),
          ],
        ),
      ] else ...[
        Text(s.runDescription),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: _button(
            s.startRun,
            Icons.play_arrow,
            c.busy ? null : () => _perform(c.startRun),
            primary: true,
          ),
        ),
      ],
    ],
  );

  Widget _results() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _pageHeading(s.resultsTitle, s.resultsDescription),
      const SizedBox(height: 24),
      if (c.results.isEmpty)
        _emptyState(Icons.compare_arrows, s.noResults, s.noResultsDescription)
      else ...[
        _sessionIdentity(),
        const SizedBox(height: 20),
        _notice(
          c.peerJournalPresent ? Icons.link : Icons.merge_type,
          c.peerJournalPresent ? s.peerMerged : s.peerMissing,
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _button(
              s.importReport,
              Icons.file_open_outlined,
              c.busy || c.running ? null : () => _perform(c.importReport),
            ),
            _button(
              s.exportReport,
              Icons.ios_share,
              c.busy || c.running ? null : _export,
              primary: true,
            ),
          ],
        ),
        const SizedBox(height: 24),
        for (final result in c.results) ...[
          _resultRow(result),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 14),
        _notice(Icons.info_outline, s.discoveryExplanation),
        const SizedBox(height: 12),
        _notice(Icons.info_outline, s.scopeDisclaimer),
      ],
    ],
  );

  Widget _resultRow(ResultView result) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _details(result),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_kind(result.kind)} · ${_family(result.family)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 5),
                Text(result.direction),
              ],
            );
            final status = _statusLabel(result.status);
            return Semantics(
              button: true,
              label: s.checkDetails,
              child: constraints.maxWidth < 500
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [title, const SizedBox(height: 14), status],
                    )
                  : Row(
                      children: [
                        Expanded(child: title),
                        const SizedBox(width: 18),
                        Flexible(child: status),
                        const SizedBox(width: 12),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
            );
          },
        ),
      ),
    ),
  );

  Widget _history() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _pageHeading(s.historyTitle, s.historyDescription),
      const SizedBox(height: 24),
      Align(
        alignment: Alignment.centerLeft,
        child: _button(
          s.importReport,
          Icons.file_open_outlined,
          c.busy || c.running ? null : () => _perform(c.importReport),
        ),
      ),
      const SizedBox(height: 24),
      if (c.history.isEmpty)
        _emptyState(Icons.history, s.historyEmpty, s.historyDescription)
      else
        for (final item in c.history) ...[
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: const Icon(Icons.description_outlined),
              title: Text(s.runIdentifier(item.runId)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6),
                  Text(_formatDate(item.savedAt)),
                  Text(s.observationCount(item.observationCount)),
                  Text(item.merged ? s.merged : s.localOnly),
                ],
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: c.busy || c.running
                  ? null
                  : () async {
                      await _perform(() => c.openHistory(item.id));
                      if (mounted) setState(() => _tab = 1);
                    },
            ),
          ),
          const SizedBox(height: 10),
        ],
    ],
  );

  Widget _errorBanner() => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Icon(Icons.error_outline),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.errorTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(_error(c.errorCode!)),
                  if (c.errorDetail != null)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(s.technicalDetails),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(c.errorDetail!),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: s.close,
            onPressed: c.clearError,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    ),
  );

  Widget _pageHeading(String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
      ),
      const SizedBox(height: 8),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Text(subtitle, style: Theme.of(context).textTheme.bodyLarge),
      ),
    ],
  );

  Widget _panel({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) => Card(
    child: Padding(
      padding: EdgeInsets.all(
        MediaQuery.sizeOf(context).width >= 840 ? 28 : 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 21,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    ),
  );

  Widget _responsivePair(Widget first, Widget second) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth >= 920
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: first),
              const SizedBox(width: 20),
              Expanded(child: second),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [first, const SizedBox(height: 20), second],
          ),
  );

  Widget _notice(IconData icon, String text, {bool dense = false}) => Container(
    padding: EdgeInsets.all(dense ? 12 : 18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    ),
  );

  Widget _emptyState(IconData icon, String title, String description) =>
      _panel(title: title, icon: icon, children: [Text(description)]);

  Widget _button(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    bool primary = false,
  }) {
    // Native Apple buttons use larger text wrapping and native feedback.
    if (apple) {
      final child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 8),
          Flexible(child: Text(label)),
        ],
      );
      return primary
          ? CupertinoButton.filled(
              borderRadius: BorderRadius.circular(12),
              onPressed: onPressed,
              child: child,
            )
          : CupertinoButton(
              borderRadius: BorderRadius.circular(12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onPressed: onPressed,
              child: child,
            );
    }
    return primary
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          );
  }

  Widget _statusLabel(String status) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(_statusIcon(status), size: 20, color: _statusColor(status)),
      const SizedBox(width: 8),
      Flexible(child: Text(_status(status))),
    ],
  );

  IconData _statusIcon(String value) => switch (value) {
    'passed' || 'ready' => Icons.check_circle_outline,
    'failed' => Icons.highlight_off,
    'permissionDenied' || 'permission_denied' => Icons.lock_outline,
    'unsupported' => Icons.block,
    'cancelled' => Icons.stop_circle_outlined,
    'inconclusive' || 'limited' => Icons.help_outline,
    _ => Icons.circle_outlined,
  };

  Color _statusColor(String value) => switch (value) {
    'passed' || 'ready' => Theme.of(context).colorScheme.primary,
    'failed' ||
    'permissionDenied' ||
    'permission_denied' => Theme.of(context).colorScheme.error,
    _ => Theme.of(context).colorScheme.onSurfaceVariant,
  };

  String _status(String value) => switch (value) {
    'passed' => s.passed,
    'failed' => s.failed,
    'inconclusive' => s.inconclusive,
    'unsupported' => s.unsupported,
    'permissionDenied' || 'permission_denied' => s.permissionDenied,
    'cancelled' => s.cancelled,
    'ready' => s.ready,
    'limited' => s.limited,
    'pending' => s.pending,
    _ => s.technicalCode(value),
  };

  String _capability(String value) => switch (value) {
    'networkPermission' => s.networkPermission,
    'multicast' => s.multicastCapability,
    'discovery' => s.discoveryCapability,
    'foreground' => s.foregroundCapability,
    'interface' => s.networkInterface,
    _ => s.technicalCode(value),
  };

  String _readinessDetail(String value) => switch (value) {
    'permission_unknown' => s.permissionUnknown,
    'multicast_entitlement_missing' ||
    'ios_multicast_entitlement_missing' => s.multicastEntitlement,
    'nativeUnavailable' => s.errorUnsupported,
    _ => s.technicalCode(value),
  };

  String _kind(String value) => switch (value) {
    'tcp' => s.tcp,
    'udp' => s.udp,
    'multicast' => s.multicast,
    'dnsSd' || 'dnssd' => s.dnssd,
    _ => s.technicalCode(value),
  };

  String _family(String value) => switch (value) {
    'ipv4' => s.ipv4,
    'ipv6' => s.ipv6,
    'system' => s.systemFamily,
    _ => s.technicalCode(value),
  };

  String _reason(String value) => switch (value) {
    'peer_confirmed' => s.reasonPeerConfirmed,
    'peer_confirmed_after_retry' => s.reasonPeerConfirmedAfterRetry,
    'tcp_connected_peer_unconfirmed' => s.reasonTcpConnectedUnconfirmed,
    'peer_not_confirmed' => s.reasonPeerNotConfirmed,
    'connection_refused' => s.reasonConnectionRefused,
    'peer_not_listening' => s.reasonPeerNotListening,
    'host_unreachable' => s.reasonHostUnreachable,
    'peer_address_is_local' => s.reasonPeerAddressIsLocal,
    'discovery_publish_failed' => s.reasonDiscoveryPublishFailed,
    'discovery_browse_failed' => s.reasonDiscoveryBrowseFailed,
    'discovery_resolve_failed' => s.reasonDiscoveryResolveFailed,
    'peer_received' => s.reasonPeerReceived,
    'acknowledgement_received' => s.reasonAcknowledgement,
    'service_resolved' => s.reasonServiceResolved,
    'permission_denied' => s.reasonPermissionDenied,
    'invalidAddress' => s.invalidAddress,
    'noInterface' => s.noInterfaces,
    'networkChanged' => s.networkChanged,
    'sessionRequired' => s.noResultsDescription,
    'runAlreadyCompleted' => s.runOnce,
    'platform_unsupported' => s.reasonUnsupported,
    'run_cancelled' => s.reasonCancelled,
    'run_interrupted' => s.reasonInterrupted,
    'probe_error' => s.reasonProbeError,
    'timeout_observed' => s.reasonTimeout,
    'missing_observations' => s.reasonMissingObservations,
    'sent_delivery_unknown' => s.reasonDeliveryUnknown,
    'peer_observation_missing' => s.reasonPeerMissing,
    _ => s.technicalCode(value),
  };

  /// Explains machine codes attached to observations; unknown codes stay raw.
  String _detail(String code) => switch (code) {
    'connection_refused' => s.detailConnectionRefused,
    'connect_timeout' => s.detailConnectTimeout,
    'host_unreachable' => s.detailHostUnreachable,
    'tcp_reply_missing' => s.detailReplyMissing,
    'tcp_reply_invalid' => s.detailReplyInvalid,
    'dns_sd_publish_failed' => s.detailDnsSdPublishFailed,
    'dns_sd_browse_failed' => s.detailDnsSdBrowseFailed,
    'dns_sd_resolve_failed' => s.detailDnsSdResolveFailed,
    'dns_sd_resolve_unattributed' ||
    'dns_sd_error_unattributed' => s.detailDnsSdUnattributed,
    'peer_address_is_local' => s.detailPeerAddressIsLocal,
    _ => s.technicalCode(code),
  };

  String _observation(String value) => switch (value) {
    'sent' => s.observationSent,
    'received' => s.observationReceived,
    'acknowledged' => s.observationAcknowledged,
    'connected' => s.observationConnected,
    'timedOut' || 'timed_out' => s.observationTimedOut,
    'error' => s.observationError,
    'unsupported' => s.observationUnsupported,
    'permissionDenied' || 'permission_denied' => s.observationPermissionDenied,
    'cancelled' => s.observationCancelled,
    'suspended' => s.observationSuspended,
    'networkChanged' || 'network_changed' => s.observationNetworkChanged,
    'published' => s.observationPublished,
    'discovered' => s.observationDiscovered,
    'resolved' => s.observationResolved,
    _ => s.technicalCode(value),
  };

  String _error(String code) => switch (code) {
    'invalid_invitation' ||
    'invalidInvitation' ||
    'invitation' => s.errorInvalidInvitation,
    'invalid_report' ||
    'importFailed' ||
    'report' ||
    'merge' => s.errorInvalidReport,
    'network' || 'controlUnavailable' || 'socket' || 'bind' => s.errorNetwork,
    'file' || 'exportFailed' || 'storage' => s.errorFile,
    'unsupported' => s.errorUnsupported,
    'permission_denied' => s.reasonPermissionDenied,
    'invalidAddress' => s.invalidAddress,
    'peerAddressIsLocal' => s.peerAddressIsLocal,
    'noInterface' => s.noInterfaces,
    'networkChanged' => s.networkChanged,
    'sessionRequired' => s.noResultsDescription,
    'runAlreadyCompleted' => s.runOnce,
    _ => s.errorGeneric,
  };

  String _reportLabel(String value) => switch (value) {
    'appVersion' => s.appVersion,
    'protocolVersion' => s.protocolVersion,
    'reportVersion' => s.reportVersion,
    'platform' => s.platform,
    'capabilities' => s.capabilities,
    'parameters' => s.parameters,
    'wallClock' => s.wallClock,
    'monotonicDuration' => s.monotonicDuration,
    'sourceDevice' => s.sourceDevice,
    _ => s.technicalCode(value),
  };

  String _formatDate(DateTime value) {
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(value.toLocal())} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value.toLocal()))}';
  }

  Future<void> _copyInvitation() async {
    await Clipboard.setData(ClipboardData(text: c.invitation!));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.copied)));
    }
  }

  Future<void> _showQr() async {
    final value = c.invitation!;
    final fits = utf8.encode(value).length <= 2800;
    await showAdaptiveDialog<void>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(s.showQr),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (fits)
              Semantics(
                label: s.invitationLabel,
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: 300,
                    height: 300,
                    child: QrImageView(
                      data: value,
                      backgroundColor: Colors.white,
                      errorCorrectionLevel: QrErrorCorrectLevel.L,
                    ),
                  ),
                ),
              )
            else
              Text(s.qrUnavailable),
            const SizedBox(height: 16),
            Text(s.invitationPrivacy),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.close),
          ),
        ],
      ),
    );
  }

  Future<void> _scan() async {
    final value = await Navigator.of(context).push<String>(
      apple
          ? CupertinoPageRoute(builder: (_) => const _ScanPage())
          : MaterialPageRoute(builder: (_) => const _ScanPage()),
    );
    if (value != null) await _perform(() => c.joinSession(value));
  }

  Future<void> _details(ResultView result) async {
    await showAdaptiveDialog<void>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(s.checkDetails),
        scrollable: true,
        content: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: 620,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${_kind(result.kind)} · ${_family(result.family)}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(result.direction),
                const SizedBox(height: 16),
                _statusLabel(result.status),
                const SizedBox(height: 24),
                Text(
                  s.interpretation,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(_reason(result.reason)),
                const SizedBox(height: 24),
                Text(
                  s.rawObservations,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (result.observations.isEmpty) Text(s.noEvidence),
                for (final observation in result.observations) ...[
                  const Divider(),
                  Text(_observation(observation.code)),
                  const SizedBox(height: 4),
                  Text('${s.sourceDevice}: ${observation.device}'),
                  Text(s.elapsed(observation.elapsedMs)),
                  if (observation.wallTime != null) ...[
                    Text(s.wallClock),
                    SelectableText(observation.wallTime!),
                  ],
                  if (observation.interfaceName != null) ...[
                    Text(s.networkInterface),
                    SelectableText(observation.interfaceName!),
                  ],
                  if (observation.id != null) ...[
                    Text(s.observationIdentifier),
                    SelectableText(observation.id!),
                  ],
                  if (observation.sequence != null)
                    Text(s.packetSequence(observation.sequence!)),
                  if (observation.detail != null) ...[
                    SelectableText(_detail(observation.detail!)),
                    if (_detail(observation.detail!) !=
                        s.technicalCode(observation.detail!))
                      SelectableText(s.technicalCode(observation.detail!)),
                  ],
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.close),
          ),
        ],
      ),
    );
  }

  String _humanReport(ReportExportView report) {
    final lines = <String>[
      s.appTitle,
      s.sessionIdentifier(c.sessionId ?? ''),
      s.runIdentifier(c.runId ?? ''),
      c.peerJournalPresent ? s.peerMerged : s.peerMissing,
      '',
      s.reportMetadata,
      for (final field in report.fields.where(
        (field) => !report.redacted || field.label != 'wallClock',
      ))
        '${_reportLabel(field.label)}: ${field.value}',
      '',
      s.addressesIncluded,
      ...report.addresses,
      '',
    ];
    for (final result in report.results) {
      lines.addAll([
        '${_kind(result.kind)} · ${_family(result.family)} · ${result.direction}',
        _status(result.status),
        _reason(result.reason),
        s.rawObservations,
        if (result.observations.isEmpty) s.noEvidence,
        for (final observation in result.observations)
          '${_observation(observation.code)}; '
              '${s.sourceDevice}: ${observation.device}; '
              '${s.elapsed(observation.elapsedMs)}'
              '${report.redacted || observation.wallTime == null ? '' : '; ${s.wallClock}: ${observation.wallTime}'}'
              '${observation.interfaceName == null ? '' : '; ${s.networkInterface}: ${observation.interfaceName}'}'
              '${observation.id == null ? '' : '; ${s.observationIdentifier}: ${observation.id}'}'
              '${observation.sequence == null ? '' : '; ${s.packetSequence(observation.sequence!)}'}'
              '${observation.detail == null ? '' : '; ${_detail(observation.detail!)}'}',
        '',
      ]);
    }
    lines.addAll([s.discoveryExplanation, '', s.scopeDisclaimer]);
    return lines.join('\n');
  }

  Future<void> _export() async {
    var redact = true;
    var readable = false;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog.adaptive(
          title: Text(s.exportTitle),
          scrollable: true,
          content: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: 600,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(s.exportDescription),
                  const SizedBox(height: 20),
                  Text(
                    s.addressesIncluded,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (c.exportAddresses.isEmpty) Text(s.noAddresses),
                  for (final address in c.exportAddresses)
                    SelectableText(address),
                  const SizedBox(height: 16),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.redact),
                    subtitle: Text(s.redactDescription),
                    value: redact,
                    onChanged: (value) => setDialogState(() => redact = value),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<bool>(
                    initialValue: readable,
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(value: false, child: Text(s.jsonReport)),
                      DropdownMenuItem(
                        value: true,
                        child: Text(s.readableReport),
                      ),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => readable = value!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (apple)
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.cancel),
              )
            else
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.cancel),
              ),
            if (apple)
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.exportReport),
              )
            else
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.exportReport),
              ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await _perform(
        () => c.exportReport(
          redact: redact,
          humanReadable: readable,
          formatReadableReport: readable ? _humanReport : null,
        ),
      );
    }
  }

  Future<void> _settings() async {
    await showAdaptiveDialog<void>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(s.settings),
        scrollable: true,
        content: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: 520,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<ThemeMode>(
                  initialValue: widget.theme,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: s.theme),
                  items: [
                    DropdownMenuItem(
                      value: ThemeMode.system,
                      child: Text(s.systemTheme),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.light,
                      child: Text(s.lightTheme),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.dark,
                      child: Text(s.darkTheme),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) widget.onThemeChanged(value);
                  },
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  initialValue: widget.locale?.toString() ?? 'system',
                  isExpanded: true,
                  decoration: InputDecoration(labelText: s.language),
                  items: [
                    DropdownMenuItem(
                      value: 'system',
                      child: Text(s.systemLanguage),
                    ),
                    const DropdownMenuItem(value: 'en', child: Text('English')),
                    const DropdownMenuItem(value: 'ru', child: Text('Русский')),
                    const DropdownMenuItem(value: 'es', child: Text('Español')),
                    const DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                    const DropdownMenuItem(
                      value: 'fr',
                      child: Text('Français'),
                    ),
                    const DropdownMenuItem(value: 'ja', child: Text('日本語')),
                    const DropdownMenuItem(
                      value: 'pt_BR',
                      child: Text('Português brasileiro'),
                    ),
                  ],
                  onChanged: (value) {
                    widget.onLocaleChanged(switch (value) {
                      'system' => null,
                      'pt_BR' => const Locale('pt', 'BR'),
                      _ => Locale(value!),
                    });
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  s.privacyTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(s.privacyDescription),
                const SizedBox(height: 20),
                Text(s.keyboardHelp),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.close),
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        Icons.compare_arrows_rounded,
        color: Theme.of(context).colorScheme.onPrimary,
        size: size * .7,
      ),
    ),
  );
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> with WidgetsBindingObserver {
  CameraController? _camera;
  bool _finished = false,
      _decoding = false,
      _unavailable = false,
      _opening = false;
  int _generation = 0;
  bool _foreground = true;
  Future<void> _closing = Future<void>.value();
  final _throttle = Stopwatch()..start();
  int _lastFrameMs = -500;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    if (_opening || _finished || !mounted) return;
    _opening = true;
    final generation = ++_generation;
    CameraController? camera;
    try {
      await _closing;
      if (!mounted || generation != _generation || !_foreground) return;
      final cameras = await availableCameras();
      final selected =
          cameras
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .firstOrNull ??
          cameras.first;
      camera = CameraController(
        selected,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      await camera.initialize();
      if (!mounted || generation != _generation) {
        await _disposeCamera(camera);
        return;
      }
      final owner = camera;
      await camera.startImageStream(
        (image) => _frame(image, owner, generation),
      );
      if (!mounted || generation != _generation || !_foreground) {
        await _disposeCamera(camera);
        return;
      }
      _camera = camera;
      if (mounted) setState(() => _unavailable = false);
    } catch (_) {
      await _disposeCamera(camera);
      if (mounted && generation == _generation) {
        setState(() => _unavailable = true);
      }
    } finally {
      _opening = false;
      if (mounted &&
          !_finished &&
          generation != _generation &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _open();
      }
    }
  }

  Future<void> _frame(
    CameraImage image,
    CameraController owner,
    int generation,
  ) async {
    if (_finished ||
        !_foreground ||
        generation != _generation ||
        !identical(owner, _camera) ||
        _decoding ||
        !mounted ||
        _throttle.elapsedMilliseconds - _lastFrameMs < 400) {
      return;
    }
    if (image.width > 2048 || image.height > 2048 || image.planes.isEmpty) {
      return;
    }
    _lastFrameMs = _throttle.elapsedMilliseconds;
    _decoding = true;
    try {
      final plane = image.planes.first;
      final bytes = Uint8List(image.width * image.height);
      final bgra = image.format.group == ImageFormatGroup.bgra8888;
      final pixelStride = plane.bytesPerPixel ?? (bgra ? 4 : 1);
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final index = y * plane.bytesPerRow + x * pixelStride;
          if (index + (bgra ? 2 : 0) >= plane.bytes.length) return;
          bytes[y * image.width + x] = bgra
              ? (plane.bytes[index + 2] +
                        2 * plane.bytes[index + 1] +
                        plane.bytes[index]) ~/
                    4
              : plane.bytes[index];
        }
      }
      final value = await compute(decodeQrLuminance, (
        width: image.width,
        height: image.height,
        bytes: bytes,
      ));
      if (value != null && mounted && generation == _generation && !_finished) {
        _finished = true;
        await _close();
        if (mounted) Navigator.pop(context, value);
      }
    } catch (_) {
      /* A partial camera frame is not a diagnostic error. */
    } finally {
      _decoding = false;
    }
  }

  Future<void> _close() async {
    _generation++;
    final camera = _camera;
    _camera = null;
    _closing = _closing.then((_) => _disposeCamera(camera));
    await _closing;
  }

  Future<void> _disposeCamera(CameraController? camera) async {
    if (camera == null) return;
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
    } catch (_) {
      /* Teardown must still dispose the device. */
    } finally {
      try {
        await camera.dispose();
      } catch (_) {
        /* Already released by the OS. */
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _open();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _close();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _close();
    _throttle.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(title: Text(s.scanQr)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(padding: const EdgeInsets.all(20), child: Text(s.scanHint)),
            Expanded(
              child: _unavailable
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(s.cameraUnavailable),
                      ),
                    )
                  : camera == null || !camera.value.isInitialized
                  ? const Center(child: CircularProgressIndicator())
                  : Center(child: CameraPreview(camera)),
            ),
          ],
        ),
      ),
    );
  }
}

/// An explanatory sketch, not a connectivity result or a status indicator.
class _PairBlueprint extends StatelessWidget {
  const _PairBlueprint();
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: 208,
      child: CustomPaint(
        painter: _BlueprintPainter(
          Theme.of(context).colorScheme,
          Theme.of(context).textTheme.bodyMedium!,
        ),
      ),
    ),
  );
}

class _BlueprintPainter extends CustomPainter {
  const _BlueprintPainter(this.colors, this.textStyle);
  final ColorScheme colors;
  final TextStyle textStyle;
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final ink = colors.onSurface;
    final blue = colors.primary;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20)),
    );
    final dot = Paint()..color = colors.outlineVariant.withValues(alpha: .6);
    for (double x = 12; x < w; x += 20) {
      for (double y = 12; y < size.height; y += 20) {
        canvas.drawCircle(Offset(x, y), .7, dot);
      }
    }
    final stroke = Paint()
      ..color = blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final upper = Path()
      ..moveTo(100, 76)
      ..cubicTo(w * .4, 76, w * .55, 47, w - 100, 66);
    final lower = Path()
      ..moveTo(w - 100, 112)
      ..cubicTo(w * .6, 112, w * .45, 141, 100, 120);
    canvas.drawPath(upper, stroke);
    canvas.drawPath(lower, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(w - 108, 58)
        ..lineTo(w - 100, 66)
        ..lineTo(w - 111, 71),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(108, 112)
        ..lineTo(100, 120)
        ..lineTo(111, 125),
      stroke,
    );
    void device(double x, String label, bool phone) {
      final rect = Rect.fromLTWH(x, 44, 64, 104);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(14)),
        Paint()..color = colors.surface,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(14)),
        Paint()
          ..color = colors.outlineVariant
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      final screen = Rect.fromLTWH(x + 12, 59, 40, phone ? 60 : 48);
      canvas.drawRRect(
        RRect.fromRectAndRadius(screen, const Radius.circular(5)),
        Paint()..color = blue.withValues(alpha: .06),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(screen, const Radius.circular(5)),
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
      canvas.drawLine(
        Offset(x + 25, phone ? 128 : 116),
        Offset(x + 39, phone ? 128 : 116),
        Paint()
          ..color = ink
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
      final text = TextPainter(
        text: TextSpan(
          text: label,
          style: textStyle.copyWith(
            color: ink,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(x + (64 - text.width) / 2, phone ? 78 : 72));
    }

    device(30, 'A', false);
    device(w - 94, 'B', true);
    final caption = TextPainter(
      text: TextSpan(
        text: 'TCP  /  UDP  /  DNS-SD',
        style: textStyle.copyWith(
          color: colors.onSurfaceVariant,
          fontSize: 11,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    caption.paint(canvas, Offset((w - caption.width) / 2, 174));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BlueprintPainter oldDelegate) =>
      oldDelegate.colors != colors || oldDelegate.textStyle != textStyle;
}
