import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/l10n/generated/app_localizations.dart';
import 'package:lanpair/src/app.dart';

import 'widget_test.dart' show FakeController;

void main() {
  for (final scenario in [
    (
      name: 'unsupported system language falls back to English',
      preferred: [const Locale('it')],
      expected: const Locale('en'),
    ),
    (
      name: 'supported system language is preserved',
      preferred: [const Locale('de')],
      expected: const Locale('de'),
    ),
    (
      name: 'a supported secondary preference takes priority over fallback',
      preferred: [const Locale('it'), const Locale('ru')],
      expected: const Locale('ru'),
    ),
  ]) {
    testWidgets(scenario.name, (tester) async {
      tester.platformDispatcher.localesTestValue = scenario.preferred;
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final controller = FakeController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(LanPairApp(controller: controller));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold).first);
      expect(Localizations.localeOf(context), scenario.expected);
      expect(
        AppLocalizations.of(context).localeName,
        scenario.expected.toString(),
      );
      expect(
        find.text(AppLocalizations.of(context).appSubtitle),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
