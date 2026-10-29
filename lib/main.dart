import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  runApp(LanPairApp(controller: controller));
  controller.initialize();
}
