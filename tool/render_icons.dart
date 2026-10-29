// Regenerate native icons from the same geometry as assets/icon.svg:
// flutter test tool/render_icons.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> renderIcon(int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(size / 128);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 128, 128),
    ui.Paint()..color = const ui.Color(0xff153e49),
  );
  final stroke = ui.Paint()
    ..color = const ui.Color(0xffffffff)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 5
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round;
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(
      const ui.Rect.fromLTWH(12, 36, 54, 36),
      const ui.Radius.circular(4),
    ),
    stroke,
  );
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(
      const ui.Rect.fromLTWH(92, 34, 24, 56),
      const ui.Radius.circular(5),
    ),
    stroke,
  );
  final path = ui.Path()
    ..moveTo(39, 72)
    ..lineTo(39, 86)
    ..moveTo(27, 86)
    ..lineTo(51, 86)
    ..moveTo(101, 81)
    ..lineTo(107, 81)
    ..moveTo(74, 50)
    ..lineTo(84, 50)
    ..lineTo(79, 45)
    ..moveTo(84, 50)
    ..lineTo(79, 55)
    ..moveTo(84, 70)
    ..lineTo(74, 70)
    ..lineTo(79, 65)
    ..moveTo(74, 70)
    ..lineTo(79, 75);
  canvas.drawPath(path, stroke);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  test('generate native LANPair artwork', () async {
    for (final platform in ['ios', 'macos']) {
      final directory = Directory(
        '$platform/Runner/Assets.xcassets/AppIcon.appiconset',
      );
      final manifest = jsonDecode(
        File('${directory.path}/Contents.json').readAsStringSync(),
      ) as Map;
      for (final item in (manifest['images'] as List).cast<Map>()) {
        if (item['filename'] == null) continue;
        final points = double.parse((item['size'] as String).split('x').first);
        final scale = double.parse(
          (item['scale'] as String).replaceAll('x', ''),
        );
        await File('${directory.path}/${item['filename']}')
            .writeAsBytes(await renderIcon((points * scale).round()));
      }
    }
    if (Platform.isMacOS) {
      Directory('.tool/swift-module-cache').createSync(recursive: true);
      final result = await Process.run('swift', [
        '-module-cache-path',
        '${Directory.current.path}/.tool/swift-module-cache',
        'tool/strip_icon_alpha.swift',
        ...Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.png'))
            .map((f) => f.path),
      ]);
      if (result.exitCode != 0) {
        throw StateError('Could not remove iOS icon alpha channel.');
      }
    }
    for (final entry in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      await File('android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png')
          .writeAsBytes(await renderIcon(entry.value));
    }
    final sizes = [16, 32, 48, 256];
    final images = await Future.wait(sizes.map(renderIcon));
    final header = ByteData(6 + sizes.length * 16)
      ..setUint16(2, 1, Endian.little)
      ..setUint16(4, sizes.length, Endian.little);
    var offset = header.lengthInBytes;
    for (var i = 0; i < sizes.length; i++) {
      final pos = 6 + i * 16;
      header.setUint8(pos, sizes[i] % 256);
      header.setUint8(pos + 1, sizes[i] % 256);
      header.setUint16(pos + 4, 1, Endian.little);
      header.setUint16(pos + 6, 32, Endian.little);
      header.setUint32(pos + 8, images[i].length, Endian.little);
      header.setUint32(pos + 12, offset, Endian.little);
      offset += images[i].length;
    }
    await File('windows/runner/resources/app_icon.ico').writeAsBytes([
      ...header.buffer.asUint8List(),
      ...images.expand((bytes) => bytes),
    ]);
  });
}
