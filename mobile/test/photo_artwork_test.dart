import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/widgets/khotwa_backdrop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the actual decorative photos are bundled, decodable and lightweight',
    () async {
      var totalBytes = 0;
      for (final asset in [KhotwaArtwork.room, KhotwaArtwork.desk]) {
        final data = await rootBundle.load(asset);
        totalBytes += data.lengthInBytes;
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        try {
          final frame = await codec.getNextFrame();
          expect(frame.image.width, inInclusiveRange(640, 1280));
          expect(frame.image.height, inInclusiveRange(640, 1440));
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      }
      // Protect offline delivery and slow connections from accidental full-size
      // master PNGs being bundled instead of the optimized photos.
      expect(totalBytes, lessThan(256 * 1024));
    },
  );
}
