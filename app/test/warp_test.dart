import 'dart:io';
import 'dart:math' as math;
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

  test('cropFileToFrame reads and writes files, leaving the source alone', () {
    final dir = Directory.systemTemp.createTempSync('warp_file_test');
    addTearDown(() => dir.deleteSync(recursive: true));

    final src = im.Image(width: 200, height: 400);
    im.fill(src, color: im.ColorRgb8(20, 180, 40));
    final srcPath = '${dir.path}/still.jpg';
    File(srcPath).writeAsBytesSync(im.encodeJpg(src, quality: 92));
    final outPath = '${dir.path}/warped.jpg';

    final out = cropFileToFrame({
      'srcPath': srcPath,
      'outPath': outPath,
      'left': 0.0,
      'top': 0.0,
      'right': 1.0,
      'bottom': 1.0,
      'viewW': 100.0,
      'viewH': 200.0,
      'portrait': true,
    });

    expect(out[0], outPath);
    expect(out[1], isTrue);
    expect(File(srcPath).existsSync(), isTrue);
    final img = im.decodeJpg(File(outPath).readAsBytesSync())!;
    expect(img.width, 1000);
    expect(img.height, 1400);
  });


  group('guide mapping across preview/still aspect mismatch', () {
    // A 1000x1400 output is irrelevant here; we only care where the guide
    // lands in the still. Use cropToFrameIsolate's overlay path indirectly by
    // checking the warped content, which is cheaper to reason about directly.
    Uint8List still(int w, int h, im.Color colour, im.Color patch) {
      final img = im.Image(width: w, height: h);
      im.fill(img, color: colour);
      // Mark the centre half so we can tell which region got warped.
      im.fillRect(img,
          x1: w ~/ 4, y1: h ~/ 4, x2: w * 3 ~/ 4, y2: h * 3 ~/ 4, color: patch);
      return Uint8List.fromList(im.encodeJpg(img, quality: 92));
    }

    test('a matched-aspect still maps the guide unchanged', () {
      // 16:9 preview, 16:9 still: the mapping must behave exactly as it did
      // before preview size was threaded through.
      final jpeg = still(1080, 1920, im.ColorRgb8(20, 180, 40), im.ColorRgb8(200, 20, 20));
      final withPreview = cropToFrameIsolate({
        'jpeg': jpeg,
        'left': 0.0, 'top': 0.0, 'right': 1.0, 'bottom': 1.0,
        'viewW': 1080.0, 'viewH': 1920.0,
        'previewW': 1080.0, 'previewH': 1920.0,
        'portrait': true,
      });
      final withoutPreview = cropToFrameIsolate({
        'jpeg': jpeg,
        'left': 0.0, 'top': 0.0, 'right': 1.0, 'bottom': 1.0,
        'viewW': 1080.0, 'viewH': 1920.0,
        'portrait': true,
      });
      expect(withPreview[0], withoutPreview[0]);
    });

    test('a 4:3 still against a 16:9 preview keeps the guide centred', () {
      // The failure this guards: a 4:3 still made the guide land on a narrow
      // sub-window, cropping to the card art instead of the card.
      // 4:3, but small: this checks the guide mapping, not detail.
      final jpeg = still(768, 1020, im.ColorRgb8(20, 180, 40), im.ColorRgb8(200, 20, 20));
      final out = cropToFrameIsolate({
        'jpeg': jpeg,
        'left': 0.25, 'top': 0.25, 'right': 0.75, 'bottom': 0.75,
        'viewW': 1080.0, 'viewH': 2410.0,
        'previewW': 1080.0, 'previewH': 1920.0,
        'portrait': true,
      });
      final img = im.decodeJpg(out[0] as Uint8List)!;
      // The guide is centred, so the centre of the output must be the centre
      // patch of the still, not some off-centre region.
      final mid = img.getPixel(500, 700);
      expect(mid.r.toInt(), greaterThan(150));
      expect(mid.g.toInt(), lessThan(80));
    });
  });

  group('framing consistency', () {
    /// A synthetic still: a light 5:7 card on a dark surface, at [angle]
    /// degrees and offset by [dx],[dy], sized [scale] of the frame.
    Uint8List syntheticStill({
      double angle = 0,
      double dx = 0,
      double dy = 0,
      double scale = 0.62,
    }) {
      const w = 1080, h = 1920;
      final img = im.Image(width: w, height: h);
      im.fill(img, color: im.ColorRgb8(45, 45, 48));
      final cw = w * scale;
      final ch = cw / (5 / 7);
      final cx = w / 2 + dx, cy = h / 2 + dy;
      final r = angle * math.pi / 180;
      final cos = math.cos(r), sin = math.sin(r);
      im.Point corner(double sx, double sy) {
        final x = sx * cw / 2, y = sy * ch / 2;
        return im.Point(cx + x * cos - y * sin, cy + x * sin + y * cos);
      }
      final pts = [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)];
      im.fillPolygon(img, vertices: pts, color: im.ColorRgb8(238, 235, 226));
      // Some interior detail so the card is not a flat blob.
      im.fillPolygon(img,
          vertices: [corner(-0.5, -0.5), corner(0.5, -0.5), corner(0.5, 0.5), corner(-0.5, 0.5)],
          color: im.ColorRgb8(120, 110, 90));
      return Uint8List.fromList(im.encodeJpg(img, quality: 92));
    }

    /// Background margin before the card edge, per side, in output pixels.
    List<int> margins(im.Image out) {
      int scan(int count, int Function(int i) at) {
        var streak = 0;
        for (var i = 0; i < count; i++) {
          if (at(i) > 140) {
            if (++streak >= 4) return i - 3;
          } else {
            streak = 0;
          }
        }
        return -1;
      }

      final w = out.width, h = out.height;
      return [
        scan(w, (i) => out.getPixel(i, h ~/ 2).r.toInt()),
        scan(w, (i) => out.getPixel(w - 1 - i, h ~/ 2).r.toInt()),
        scan(h, (i) => out.getPixel(w ~/ 2, i).r.toInt()),
        scan(h, (i) => out.getPixel(w ~/ 2, h - 1 - i).r.toInt()),
      ];
    }

    im.Image run(Uint8List jpeg) {
      final out = cropToFrameIsolate({
        'jpeg': jpeg,
        'left': 0.05, 'top': 0.15, 'right': 0.95, 'bottom': 0.85,
        'viewW': 1080.0, 'viewH': 1920.0,
        'previewW': 1080.0, 'previewH': 1920.0,
        'portrait': true,
      });
      return im.decodeJpg(out[0] as Uint8List)!;
    }

    test('every side gets the same margin, whatever the placement', () {
      final cases = <String, Uint8List>{
        'centred': syntheticStill(),
        'rotated 4deg': syntheticStill(angle: 4),
        'rotated -3deg': syntheticStill(angle: -3),
        'offset': syntheticStill(dx: 40, dy: -60),
        'smaller': syntheticStill(scale: 0.55),
        'larger': syntheticStill(scale: 0.68),
      };
      final all = <int>[];
      cases.forEach((name, jpeg) {
        final m = margins(run(jpeg));
        expect(m.every((v) => v >= 0), isTrue, reason: '$name: card edge not found in $m');
        // cardMargin is zero, so the card should reach every edge. A few
        // pixels of slack covers the rounded corners and sampling.
        expect(m.reduce(math.max), lessThan(12), reason: '$name not tight: $m');
        all.addAll(m);
      });
      // And the same, whatever the placement.
      final lo = all.reduce(math.min), hi = all.reduce(math.max);
      expect(hi - lo, lessThan(12), reason: 'margins ranged $lo..$hi across all cases');
    });
  });

}
