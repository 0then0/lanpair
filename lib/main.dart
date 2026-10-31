import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/controller.dart';
import 'src/preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppPreferences? preferences;
  try {
    preferences = await AppPreferences.open();
  } catch (_) {
    /* Without storage the choices last until the app closes. */
  }
  final controller = AppController();
  runApp(LanPairApp(controller: controller, preferences: preferences));
  controller.initialize();
}
