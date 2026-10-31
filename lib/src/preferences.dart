import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Languages the interface offers; the stored tag is the dropdown value.
const supportedLocaleTags = {'en', 'ru', 'es', 'de', 'fr', 'ja', 'pt_BR'};

Locale? localeFromTag(String? tag) => switch (tag) {
  null => null,
  'pt_BR' => const Locale('pt', 'BR'),
  _ => Locale(tag),
};

/// Appearance and language, kept in the application support directory next to
/// the report history. Nothing else is stored, and a missing or damaged file
/// means the defaults (system theme, system language).
class AppPreferences {
  AppPreferences(this._file, {this.theme = ThemeMode.system, this.localeTag});

  final File _file;
  ThemeMode theme;

  /// `null` follows the system language.
  String? localeTag;

  static Future<AppPreferences> open() async {
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    return AppPreferences.load(File('${support.path}/preferences.json'));
  }

  factory AppPreferences.load(File file) {
    final preferences = AppPreferences(file);
    try {
      final value = jsonDecode(file.readAsStringSync());
      if (value is Map) {
        final theme = value['theme'];
        preferences.theme = ThemeMode.values.firstWhere(
          (mode) => mode.name == theme,
          orElse: () => ThemeMode.system,
        );
        final locale = value['locale'];
        preferences.localeTag =
            locale is String && supportedLocaleTags.contains(locale)
            ? locale
            : null;
      }
    } on FileSystemException {
      /* First start. */
    } on FormatException {
      /* A damaged file is replaced by the next save. */
    }
    return preferences;
  }

  /// Writes through a temporary file so an interrupted save keeps the old one.
  void save() {
    try {
      final temporary = File('${_file.path}.tmp');
      temporary.writeAsStringSync(
        jsonEncode({'theme': theme.name, 'locale': localeTag}),
        flush: true,
      );
      temporary.renameSync(_file.path);
    } on FileSystemException {
      /* The choice still applies until the app closes. */
    }
  }
}
