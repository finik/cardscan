// Re-crop a deck from its _debug originals, in place.
//
// The archive holds each card's full still and the guide geometry, so a change
// to the detection can be applied to everything already shot instead of
// re-shooting it. Set CARDSCAN_DECK to the deck folder.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:card_scan/warp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;

void main() {
  final deckPath = Platform.environment['CARDSCAN_DECK'];
  if (deckPath == null) {
    test('no deck given - skipped', () {}, skip: 'set CARDSCAN_DECK');
    return;
  }
  test('reprocess deck from _debug originals', () {
    final deck = Directory(deckPath);
    final debug = Directory('${deck.path}/_debug');
    expect(debug.existsSync(), isTrue, reason: 'no _debug in ${deck.path}');

    final stills = debug
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.src.jpg'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final f in stills) {
      final code = f.uri.pathSegments.last.replaceAll('.src.jpg', '');
      final meta = File('${debug.path}/$code.json');
      if (!meta.existsSync()) {
        // ignore: avoid_print
        print('$code  SKIPPED (no geometry)');
        continue;
      }
      final g = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      final res = cropToFrameIsolate({
        'jpeg': Uint8List.fromList(f.readAsBytesSync()),
        ...g,
      });
      final outPath = '${deck.path}/$code.jpg';
      File(outPath).writeAsBytesSync(res[0] as Uint8List);

      // Report how straight and how tight the result is.
      final img = im.grayscale(im.decodeJpg(res[0] as Uint8List)!);
      // ignore: avoid_print
      print('$code  rewritten  ${img.width}x${img.height}');
    }
  });
}
