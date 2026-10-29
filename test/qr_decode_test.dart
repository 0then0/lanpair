import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:lanpair/src/identity.dart';
import 'package:lanpair/src/model.dart';
import 'package:lanpair/src/qr_decode.dart';

Future<({int width, int height, Uint8List bytes})> frame(
  String value, {
  int turns = 0,
}) async {
  final code = QrValidator.validate(
    data: value,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.L,
  ).qrCode!;
  final contentSize = code.moduleCount * 6.0;
  final imageSize = (contentSize + 96).toInt();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, imageSize.toDouble(), imageSize.toDouble()),
    ui.Paint()..color = const ui.Color(0xffffffff),
  );
  canvas.translate(imageSize / 2, imageSize / 2);
  canvas.rotate(math.pi / 2 * turns);
  canvas.translate(-imageSize / 2, -imageSize / 2);
  canvas.translate(48, 48);
  QrPainter(
    data: value,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.L,
    gapless: true,
    eyeStyle: const QrEyeStyle(
      eyeShape: QrEyeShape.square,
      color: ui.Color(0xff000000),
    ),
    dataModuleStyle: const QrDataModuleStyle(
      dataModuleShape: QrDataModuleShape.square,
      color: ui.Color(0xff000000),
    ),
  ).paint(canvas, ui.Size(contentSize, contentSize));
  final picture = recorder.endRecording();
  final image = await picture.toImage(imageSize, imageSize);
  picture.dispose();
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  final gray = Uint8List(image.width * image.height);
  for (var i = 0; i < gray.length; i++) {
    gray[i] = rgba[i * 4];
  }
  final result = (width: image.width, height: image.height, bytes: gray);
  image.dispose();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('QR roundtrip includes twelve real ephemeral ECC invitations', () async {
    for (var sample = 0; sample < 12; sample++) {
      final identities = await Future.wait([
        createIdentity(),
        createIdentity(),
      ]);
      final session = Session.create(
        a: DeviceEndpoint(id: randomId(), address: '192.0.2.1'),
        b: DeviceEndpoint(id: randomId(), address: ''),
        aIdentity: identities[0],
        bIdentity: identities[1],
      );
      final invitation = session.invitation();
      expect(
        decodeQrLuminance(await frame(invitation, turns: sample % 4)) ==
            invitation,
        isTrue,
        reason: 'Rendered invitation must be decodable without printing its credentials.',
      );
    }
  });
  test(
    'scanner ignores unrelated QR and malformed or oversized luminance buffers',
    () async {
      expect(decodeQrLuminance(await frame('unrelated QR payload')), isNull);
      final left = await frame('lp1:first');
      final right = await frame('lp1:second');
      final combinedWidth = left.width + right.width;
      final combined = Uint8List(combinedWidth * left.height)
        ..fillRange(0, combinedWidth * left.height, 255);
      for (var y = 0; y < left.height; y++) {
        combined.setRange(
          y * combinedWidth,
          y * combinedWidth + left.width,
          left.bytes,
          y * left.width,
        );
        combined.setRange(
          y * combinedWidth + left.width,
          (y + 1) * combinedWidth,
          right.bytes,
          y * right.width,
        );
      }
      expect(
        decodeQrLuminance((
          width: combinedWidth,
          height: left.height,
          bytes: combined,
        )),
        isNull,
      );

      expect(
        decodeQrLuminance((width: 3000, height: 1, bytes: Uint8List(3000))),
        isNull,
      );
      expect(
        decodeQrLuminance((width: 100, height: 100, bytes: Uint8List(5))),
        isNull,
      );
      expect(
        decodeQrLuminance((width: 100, height: 100, bytes: Uint8List(10000))),
        isNull,
      );
    },
  );
}
