import 'dart:typed_data';

import 'package:card_scan/warp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;

void main() {
  test('perspective warp of an axis-aligned card-sized rect', () {
    final src = im.Image(width: 200, height: 200);
    im.fill(src, color: im.ColorRgb8(255, 255, 255));
    im.fillRect(
      src,
      x1: 50,
      y1: 20,
      x2: 149,
      y2: 159,
      color: im.ColorRgb8(200, 10, 10),
    );
    final quad = Quad(
      im.Point(50, 20),
      im.Point(149, 20),
      im.Point(149, 159),
      im.Point(50, 159),
    );
    final out = warpPerspective(src, quad, 100, 140);
    expect(out.width, 100);
    expect(out.height, 140);
    final mid = out.getPixel(50, 70);
    expect(mid.r.toInt(), greaterThan(150));
    expect(mid.g.toInt(), lessThan(40));
  });

  test('cropToFrame maps a full-view rect to 1000x1400', () {
    final src = im.Image(width: 200, height: 400);
    im.fill(src, color: im.ColorRgb8(20, 180, 40));
    final jpeg = Uint8List.fromList(im.encodeJpg(src, quality: 92));
    final out = cropToFrameIsolate({
      'jpeg': jpeg,
      'left': 0.0,
      'top': 0.0,
      'right': 1.0,
      'bottom': 1.0,
      'viewW': 100.0,
      'viewH': 200.0,
      'portrait': true,
    });
    expect(out[1], isTrue);
    final img = im.decodeJpg(out[0] as Uint8List)!;
    expect(img.width, 1000);
    expect(img.height, 1400);
    expect(img.getPixel(500, 700).g.toInt(), greaterThan(100));
  });
}
