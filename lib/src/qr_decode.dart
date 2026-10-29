import 'dart:typed_data';

import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/multi.dart';
import 'package:zxing_lib/zxing.dart';

/// Local QR decoding. Multi-reader scans all finder candidates rather than
/// accepting an early false third finder inside a dense invitation. No images
/// are stored and no native ML SDK or network service is used.
String? decodeQrLuminance(({int width, int height, Uint8List bytes}) frame) {
  if (frame.width < 1 ||
      frame.height < 1 ||
      frame.width > 2048 ||
      frame.height > 2048 ||
      frame.bytes.length != frame.width * frame.height) {
    return null;
  }
  try {
    final source = _GraySource(frame.width, frame.height, frame.bytes);
    final results = QRCodeMultiReader().decodeMultiple(
      BinaryBitmap(HybridBinarizer(source)),
      const DecodeHint(tryHarder: true),
    );
    final invitations = results
        .map((r) => r.text)
        .where((s) => s.length <= 24576 && s.startsWith('lp1:'))
        .toSet();
    // Do not choose arbitrarily when two different invitations are visible.
    return invitations.length == 1 ? invitations.single : null;
  } on ReaderException {
    return null;
  }
}

class _GraySource extends LuminanceSource {
  _GraySource(super.width, super.height, this.bytes);
  final Uint8List bytes;
  @override
  Uint8List get matrix => bytes;
  @override
  Uint8List getRow(int y, Uint8List? row) {
    final output = row != null && row.length >= width ? row : Uint8List(width);
    output.setRange(0, width, bytes, y * width);
    return output;
  }
}
